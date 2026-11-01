//! Pure sync data model and three-way merge planner. No I/O.
//!
//! Every synced kind is a set of keyed items (a password entry, an SSH host, an
//! AI profile, an agent-history session). The drive holds one manifest per kind:
//! the current items (key, modification time, content hash, payload or blob
//! name) plus tombstones for deletions. Each computer also keeps a *base*: the
//! item set it agreed on with the drive at its last successful sync.
//!
//! - An item present on both sides with different content: last writer wins
//!   (modification time, ties broken by hash so every computer picks the same).
//! - An item only on one side: copied to the other, unless a newer tombstone
//!   says it was deleted.
//! - An item in the base but gone locally was deleted on this computer: it
//!   becomes a tombstone, unless the drive's copy was edited since the base
//!   (an edit beats a concurrent delete).
//!
//! Tombstones (not "missing from the drive") are the only way a deletion
//! travels, so a manifest lost to a concurrent upload re-gains its items from
//! the next computer that syncs instead of deleting them everywhere.
const std = @import("std");

pub const MANIFEST_FORMAT = "wispterm-sync-manifest";
pub const MANIFEST_VERSION: u32 = 1;
/// Tombstones older than this are forgotten; a computer offline for longer
/// re-uploads what it still has.
pub const TOMBSTONE_TTL_MS: i64 = 180 * std.time.ms_per_day;

pub const Item = struct {
    key: []const u8,
    updated_at: i64,
    /// Lowercase hex SHA-256 of the item's canonical payload.
    hash: []const u8,
    /// Payload stored in the manifest itself (small kinds).
    data: ?[]const u8 = null,
    /// Payload stored in its own sealed file, relative to the sync root.
    blob: ?[]const u8 = null,
};

pub const Tombstone = struct {
    key: []const u8,
    deleted_at: i64,
};

pub const Manifest = struct {
    format: []const u8 = MANIFEST_FORMAT,
    version: u32 = MANIFEST_VERSION,
    kind: []const u8 = "",
    items: []const Item = &.{},
    tombstones: []const Tombstone = &.{},
};

/// One item of the base: what this computer and the drive agreed on, plus the
/// fingerprint of the local representation it was written as.
pub const BaseItem = struct {
    key: []const u8,
    updated_at: i64,
    hash: []const u8,
    /// Fingerprint of the local copy (e.g. hash of the sealed vault entry, or a
    /// history record's updated_at); unchanged token = unchanged since sync.
    token: []const u8,
};

pub const Base = struct {
    version: u32 = 1,
    items: []const BaseItem = &.{},
};

/// A local item as an adapter reads it, before comparing with the base.
pub const LocalItem = struct {
    key: []const u8,
    token: []const u8,
    /// Native modification time when the data has one (history records).
    updated_at: ?i64 = null,
};

/// A local item with its sync metadata. `hash == null` means it changed since
/// the base and the caller must hash its payload before planning.
pub const Meta = struct {
    key: []const u8,
    updated_at: i64,
    hash: ?[]const u8,
};

/// Attach base metadata to unchanged local items. Changed or new items get
/// their native time, or `changed_at` (the local file's mtime) without one.
pub fn resolveLocal(allocator: std.mem.Allocator, local: []const LocalItem, base: []const BaseItem, changed_at: i64) ![]Meta {
    var base_index = try indexBase(allocator, base);
    defer base_index.deinit();
    const out = try allocator.alloc(Meta, local.len);
    for (local, out) |item, *meta| {
        if (base_index.get(item.key)) |bi| {
            const b = base[bi];
            if (std.mem.eql(u8, b.token, item.token)) {
                meta.* = .{ .key = item.key, .updated_at = b.updated_at, .hash = b.hash };
                continue;
            }
        }
        meta.* = .{ .key = item.key, .updated_at = item.updated_at orelse changed_at, .hash = null };
    }
    return out;
}

pub const Options = struct {
    now: i64,
    /// False when the local data cannot be trusted to show deletions (its file
    /// is missing, or a capped list may have dropped items): items gone locally
    /// are then pulled back instead of being deleted everywhere.
    allow_local_deletions: bool = true,
    tombstone_ttl_ms: i64 = TOMBSTONE_TTL_MS,
};

pub const Decision = struct {
    key: []const u8,
    /// In the merged set; false = deleted.
    keep: bool,
    updated_at: i64 = 0,
    hash: []const u8 = "",
    /// The merged value is the drive's: write it locally.
    pull: bool = false,
    /// The merged value is the local one: upload it.
    push: bool = false,
    /// Remove the local copy.
    drop_local: bool = false,
    /// Remove the drive's copy (its blob, for blob kinds).
    drop_remote: bool = false,
};

pub const Plan = struct {
    decisions: []Decision,
    tombstones: []Tombstone,
    /// The manifest must be rewritten.
    remote_dirty: bool,
    /// Local data must be rewritten.
    local_dirty: bool,

    pub fn counts(self: Plan) Counts {
        var c: Counts = .{};
        for (self.decisions) |d| {
            if (d.keep) c.items += 1;
            if (d.pull) c.pulled += 1;
            if (d.push) c.pushed += 1;
            if (d.drop_local) c.deleted_local += 1;
            if (d.drop_remote) c.deleted_remote += 1;
        }
        return c;
    }
};

pub const Counts = struct {
    items: usize = 0,
    pulled: usize = 0,
    pushed: usize = 0,
    deleted_local: usize = 0,
    deleted_remote: usize = 0,
};

/// `local` must be fully hashed (no null `hash`).
pub fn plan(allocator: std.mem.Allocator, local: []const Meta, base: []const BaseItem, remote: Manifest, opts: Options) !Plan {
    var local_keys = std.StringHashMap(void).init(allocator);
    defer local_keys.deinit();
    for (local) |l| try local_keys.put(l.key, {});
    var base_index = try indexBase(allocator, base);
    defer base_index.deinit();
    var remote_index = std.StringHashMap(usize).init(allocator);
    defer remote_index.deinit();
    for (remote.items, 0..) |r, i| try remote_index.put(r.key, i);
    var tombs = std.StringArrayHashMap(i64).init(allocator);
    defer tombs.deinit();
    for (remote.tombstones) |t| {
        const slot = try tombs.getOrPut(t.key);
        if (!slot.found_existing or t.deleted_at > slot.value_ptr.*) slot.value_ptr.* = t.deleted_at;
    }

    var remote_dirty = false;
    var local_dirty = false;

    // Items deleted on this computer since the last sync.
    var locally_deleted = std.StringHashMap(void).init(allocator);
    defer locally_deleted.deinit();
    if (opts.allow_local_deletions) {
        for (base) |b| {
            if (local_keys.contains(b.key)) continue;
            const ri = remote_index.get(b.key) orelse continue; // already gone from the drive
            const r = remote.items[ri];
            if (!std.mem.eql(u8, r.hash, b.hash) and r.updated_at > b.updated_at) continue; // edited elsewhere: keep it
            try locally_deleted.put(b.key, {});
            const slot = try tombs.getOrPut(b.key);
            if (!slot.found_existing or slot.value_ptr.* < opts.now) slot.value_ptr.* = opts.now;
            remote_dirty = true;
        }
    }

    var decisions: std.ArrayListUnmanaged(Decision) = .empty;
    errdefer decisions.deinit(allocator);

    for (local) |l| {
        const lhash = l.hash orelse return error.UnhashedLocalItem;
        const tomb = tombs.get(l.key);
        var d: Decision = undefined;
        if (remote_index.get(l.key)) |ri| {
            const r = remote.items[ri];
            if (std.mem.eql(u8, lhash, r.hash)) {
                d = .{ .key = l.key, .keep = true, .updated_at = @max(l.updated_at, r.updated_at), .hash = lhash };
            } else if (newer(l.updated_at, lhash, r.updated_at, r.hash)) {
                d = .{ .key = l.key, .keep = true, .updated_at = l.updated_at, .hash = lhash, .push = true };
            } else {
                d = .{ .key = l.key, .keep = true, .updated_at = r.updated_at, .hash = r.hash, .pull = true };
            }
            if (tomb) |deleted_at| {
                if (deleted_at >= d.updated_at) {
                    d = .{ .key = l.key, .keep = false, .drop_local = true, .drop_remote = true };
                } else {
                    _ = tombs.orderedRemove(l.key);
                }
                remote_dirty = true;
            }
        } else if (tomb != null and tomb.? >= l.updated_at) {
            d = .{ .key = l.key, .keep = false, .drop_local = true };
        } else {
            d = .{ .key = l.key, .keep = true, .updated_at = l.updated_at, .hash = lhash, .push = true };
            if (tomb != null) _ = tombs.orderedRemove(l.key);
        }
        if (d.push) remote_dirty = true;
        if (d.pull or d.drop_local) local_dirty = true;
        try decisions.append(allocator, d);
    }

    for (remote.items) |r| {
        if (local_keys.contains(r.key)) continue;
        var d: Decision = undefined;
        if (locally_deleted.contains(r.key)) {
            d = .{ .key = r.key, .keep = false, .drop_remote = true };
        } else if (tombs.get(r.key)) |deleted_at| {
            if (deleted_at >= r.updated_at) {
                // A manifest carrying both: drop the stale item.
                d = .{ .key = r.key, .keep = false, .drop_remote = true };
                remote_dirty = true;
            } else {
                _ = tombs.orderedRemove(r.key);
                remote_dirty = true;
                d = .{ .key = r.key, .keep = true, .updated_at = r.updated_at, .hash = r.hash, .pull = true };
                local_dirty = true;
            }
        } else {
            d = .{ .key = r.key, .keep = true, .updated_at = r.updated_at, .hash = r.hash, .pull = true };
            local_dirty = true;
        }
        try decisions.append(allocator, d);
    }

    var kept_tombs: std.ArrayListUnmanaged(Tombstone) = .empty;
    errdefer kept_tombs.deinit(allocator);
    var it = tombs.iterator();
    while (it.next()) |entry| {
        if (opts.now - entry.value_ptr.* > opts.tombstone_ttl_ms) {
            remote_dirty = true;
            continue;
        }
        try kept_tombs.append(allocator, .{ .key = entry.key_ptr.*, .deleted_at = entry.value_ptr.* });
    }
    std.mem.sort(Tombstone, kept_tombs.items, {}, tombstoneLess);

    return .{
        .decisions = try decisions.toOwnedSlice(allocator),
        .tombstones = try kept_tombs.toOwnedSlice(allocator),
        .remote_dirty = remote_dirty,
        .local_dirty = local_dirty,
    };
}

pub fn freePlan(allocator: std.mem.Allocator, p: Plan) void {
    allocator.free(p.decisions);
    allocator.free(p.tombstones);
}

fn newer(a_time: i64, a_hash: []const u8, b_time: i64, b_hash: []const u8) bool {
    if (a_time != b_time) return a_time > b_time;
    return std.mem.order(u8, a_hash, b_hash) == .gt;
}

fn tombstoneLess(_: void, a: Tombstone, b: Tombstone) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

pub fn itemLess(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn indexBase(allocator: std.mem.Allocator, base: []const BaseItem) !std.StringHashMap(usize) {
    var map = std.StringHashMap(usize).init(allocator);
    errdefer map.deinit();
    for (base, 0..) |b, i| try map.put(b.key, i);
    return map;
}

pub fn parseManifest(arena: std.mem.Allocator, bytes: []const u8) !Manifest {
    const m = try std.json.parseFromSliceLeaky(Manifest, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (!std.mem.eql(u8, m.format, MANIFEST_FORMAT)) return error.NotSyncManifest;
    if (m.version > MANIFEST_VERSION) return error.NewerSyncFormat;
    return m;
}

pub fn serializeManifest(allocator: std.mem.Allocator, m: Manifest) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, m, .{ .emit_null_optional_fields = false });
}

pub fn parseBase(arena: std.mem.Allocator, bytes: []const u8) !Base {
    return std.json.parseFromSliceLeaky(Base, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn serializeBase(allocator: std.mem.Allocator, b: Base) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, b, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const T = struct {
    arena: std.heap.ArenaAllocator,

    fn init() T {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }
    fn deinit(self: *T) void {
        self.arena.deinit();
    }
    fn run(self: *T, local: []const Meta, base: []const BaseItem, remote: Manifest, opts: Options) !Plan {
        return plan(self.arena.allocator(), local, base, remote, opts);
    }
};

fn find(p: Plan, key: []const u8) ?Decision {
    for (p.decisions) |d| if (std.mem.eql(u8, d.key, key)) return d;
    return null;
}

test "sync merge: first sync unions both sides" {
    var t = T.init();
    defer t.deinit();
    const local = [_]Meta{.{ .key = "a", .updated_at = 10, .hash = "ha" }};
    const remote = Manifest{ .items = &.{.{ .key = "b", .updated_at = 5, .hash = "hb" }} };
    const p = try t.run(&local, &.{}, remote, .{ .now = 100 });
    try std.testing.expect(find(p, "a").?.push);
    try std.testing.expect(find(p, "b").?.pull);
    try std.testing.expect(p.remote_dirty and p.local_dirty);
    try std.testing.expectEqual(@as(usize, 2), p.counts().items);
}

test "sync merge: identical content is a no-op" {
    var t = T.init();
    defer t.deinit();
    const local = [_]Meta{.{ .key = "a", .updated_at = 10, .hash = "h" }};
    const base = [_]BaseItem{.{ .key = "a", .updated_at = 10, .hash = "h", .token = "t" }};
    const remote = Manifest{ .items = &.{.{ .key = "a", .updated_at = 10, .hash = "h" }} };
    const p = try t.run(&local, &base, remote, .{ .now = 100 });
    try std.testing.expect(!p.remote_dirty and !p.local_dirty);
    const d = find(p, "a").?;
    try std.testing.expect(d.keep and !d.push and !d.pull);
}

test "sync merge: last writer wins, ties break the same way on every computer" {
    var t = T.init();
    defer t.deinit();
    const remote = Manifest{ .items = &.{.{ .key = "a", .updated_at = 20, .hash = "h-remote" }} };
    const older = [_]Meta{.{ .key = "a", .updated_at = 10, .hash = "h-local" }};
    try std.testing.expect(find(try t.run(&older, &.{}, remote, .{ .now = 100 }), "a").?.pull);
    const newer_local = [_]Meta{.{ .key = "a", .updated_at = 30, .hash = "h-local" }};
    try std.testing.expect(find(try t.run(&newer_local, &.{}, remote, .{ .now = 100 }), "a").?.push);

    const tie_a = [_]Meta{.{ .key = "a", .updated_at = 20, .hash = "h-z" }};
    try std.testing.expect(find(try t.run(&tie_a, &.{}, remote, .{ .now = 100 }), "a").?.push);
    const tie_b = [_]Meta{.{ .key = "a", .updated_at = 20, .hash = "h-a" }};
    try std.testing.expect(find(try t.run(&tie_b, &.{}, remote, .{ .now = 100 }), "a").?.pull);
}

test "sync merge: a local delete becomes a tombstone and removes the drive copy" {
    var t = T.init();
    defer t.deinit();
    const base = [_]BaseItem{
        .{ .key = "a", .updated_at = 10, .hash = "ha", .token = "ta" },
        .{ .key = "b", .updated_at = 10, .hash = "hb", .token = "tb" },
    };
    const local = [_]Meta{.{ .key = "b", .updated_at = 10, .hash = "hb" }};
    const remote = Manifest{ .items = &.{
        .{ .key = "a", .updated_at = 10, .hash = "ha" },
        .{ .key = "b", .updated_at = 10, .hash = "hb" },
    } };
    const p = try t.run(&local, &base, remote, .{ .now = 500 });
    const a = find(p, "a").?;
    try std.testing.expect(!a.keep and a.drop_remote and !a.drop_local);
    try std.testing.expectEqual(@as(usize, 1), p.tombstones.len);
    try std.testing.expectEqualStrings("a", p.tombstones[0].key);
    try std.testing.expectEqual(@as(i64, 500), p.tombstones[0].deleted_at);
    try std.testing.expect(p.remote_dirty and !p.local_dirty);
}

test "sync merge: an edit on another computer beats a concurrent local delete" {
    var t = T.init();
    defer t.deinit();
    const base = [_]BaseItem{.{ .key = "a", .updated_at = 10, .hash = "ha", .token = "ta" }};
    const remote = Manifest{ .items = &.{.{ .key = "a", .updated_at = 20, .hash = "ha2" }} };
    const p = try t.run(&.{}, &base, remote, .{ .now = 500 });
    try std.testing.expect(find(p, "a").?.pull);
    try std.testing.expectEqual(@as(usize, 0), p.tombstones.len);
}

test "sync merge: a remote tombstone deletes an unchanged local copy, not a newer edit" {
    var t = T.init();
    defer t.deinit();
    const remote = Manifest{ .tombstones = &.{.{ .key = "a", .deleted_at = 50 }} };
    const stale = [_]Meta{.{ .key = "a", .updated_at = 10, .hash = "ha" }};
    const p1 = try t.run(&stale, &.{}, remote, .{ .now = 100 });
    try std.testing.expect(find(p1, "a").?.drop_local);
    try std.testing.expect(p1.local_dirty);
    try std.testing.expectEqual(@as(usize, 1), p1.tombstones.len);

    const edited = [_]Meta{.{ .key = "a", .updated_at = 60, .hash = "ha" }};
    const p2 = try t.run(&edited, &.{}, remote, .{ .now = 100 });
    try std.testing.expect(find(p2, "a").?.push);
    try std.testing.expectEqual(@as(usize, 0), p2.tombstones.len);
}

test "sync merge: an item lost from the drive is re-uploaded, not deleted" {
    var t = T.init();
    defer t.deinit();
    // The base lists "a" but a concurrent upload replaced the manifest without it.
    const base = [_]BaseItem{.{ .key = "a", .updated_at = 10, .hash = "ha", .token = "ta" }};
    const local = [_]Meta{.{ .key = "a", .updated_at = 10, .hash = "ha" }};
    const p = try t.run(&local, &base, .{}, .{ .now = 100 });
    try std.testing.expect(find(p, "a").?.push);
    try std.testing.expect(!find(p, "a").?.drop_local);
}

test "sync merge: missing local data pulls everything back instead of deleting" {
    var t = T.init();
    defer t.deinit();
    const base = [_]BaseItem{.{ .key = "a", .updated_at = 10, .hash = "ha", .token = "ta" }};
    const remote = Manifest{ .items = &.{.{ .key = "a", .updated_at = 10, .hash = "ha" }} };
    const p = try t.run(&.{}, &base, remote, .{ .now = 100, .allow_local_deletions = false });
    try std.testing.expect(find(p, "a").?.pull);
    try std.testing.expectEqual(@as(usize, 0), p.tombstones.len);
}

test "sync merge: old tombstones are forgotten" {
    var t = T.init();
    defer t.deinit();
    const remote = Manifest{ .tombstones = &.{
        .{ .key = "old", .deleted_at = 0 },
        .{ .key = "new", .deleted_at = TOMBSTONE_TTL_MS },
    } };
    const p = try t.run(&.{}, &.{}, remote, .{ .now = TOMBSTONE_TTL_MS + 1 });
    try std.testing.expectEqual(@as(usize, 1), p.tombstones.len);
    try std.testing.expectEqualStrings("new", p.tombstones[0].key);
    try std.testing.expect(p.remote_dirty);
}

test "sync merge: resolveLocal reuses base metadata for unchanged items" {
    var t = T.init();
    defer t.deinit();
    const base = [_]BaseItem{.{ .key = "a", .updated_at = 10, .hash = "ha", .token = "ta" }};
    const local = [_]LocalItem{
        .{ .key = "a", .token = "ta" },
        .{ .key = "b", .token = "tb" },
        .{ .key = "c", .token = "tc", .updated_at = 77 },
    };
    const metas = try resolveLocal(t.arena.allocator(), &local, &base, 42);
    try std.testing.expectEqualStrings("ha", metas[0].hash.?);
    try std.testing.expectEqual(@as(i64, 10), metas[0].updated_at);
    try std.testing.expect(metas[1].hash == null);
    try std.testing.expectEqual(@as(i64, 42), metas[1].updated_at);
    try std.testing.expectEqual(@as(i64, 77), metas[2].updated_at);
}

test "sync merge: manifest JSON round-trips and rejects foreign files" {
    var t = T.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const json = try serializeManifest(a, .{
        .kind = "passwords",
        .items = &.{.{ .key = "root", .updated_at = 1, .hash = "h", .data = "{\"x\":1}" }},
        .tombstones = &.{.{ .key = "old", .deleted_at = 2 }},
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "blob") == null);
    const back = try parseManifest(a, json);
    try std.testing.expectEqualStrings("{\"x\":1}", back.items[0].data.?);
    try std.testing.expect(back.items[0].blob == null);
    try std.testing.expectEqual(@as(i64, 2), back.tombstones[0].deleted_at);
    try std.testing.expectError(error.NotSyncManifest, parseManifest(a, "{\"format\":\"other\"}"));
    try std.testing.expectError(error.NewerSyncFormat, parseManifest(a, "{\"format\":\"wispterm-sync-manifest\",\"version\":99}"));
}

test "sync merge declarations compile" {
    std.testing.refAllDecls(@This());
}
