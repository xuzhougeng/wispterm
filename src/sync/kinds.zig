//! Local-side adapters: how each synced kind is read as keyed items, what its
//! canonical payload is, and how a merged result is written back.
//!
//! - passwords: the encrypted vault (credential/store.zig). Keyed by lowercase
//!   name; the payload carries the *plaintext* secret (the manifest it goes
//!   into is sealed with the sync key) and pulled secrets are re-sealed with
//!   this computer's vault key.
//! - ssh_hosts / ai_profiles: one hex-encoded line per profile, keyed by the
//!   decoded name. Lines are copied verbatim, so both files keep their format.
//! - history: agent-history sessions through `HistoryPort`, so the app's
//!   in-memory store (and its flush scheduler) stays the only writer.
//!
//! File kinds re-read their file before writing: if the app changed it during
//! the sync, the write is skipped (`error.LocalChangedDuringSync`) and the next
//! sync merges again.
const std = @import("std");
const builtin = @import("builtin");
const crypto = @import("crypto.zig");
const merge = @import("merge.zig");
const credential_store = @import("../credential/store.zig");
const platform_atomic_file = @import("../platform/atomic_file.zig");

const MAX_FILE_BYTES: usize = 16 * 1024 * 1024;

pub const Snapshot = struct {
    items: []merge.LocalItem,
    /// No local file at all: never read as "everything was deleted here".
    missing: bool = false,
    /// A capped consumer (the AI profile list holds 16) may have dropped items,
    /// so a missing item cannot be trusted to mean a deletion.
    capped: bool = false,
    /// Timestamp for items changed since the base: the file's mtime (ms).
    changed_at: i64,
};

/// Pulled payloads by key.
pub const Payloads = std.StringHashMap([]const u8);
/// New local tokens by key, for items `apply` wrote.
pub const Tokens = std.StringHashMap([]const u8);

pub const Adapter = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        snapshot: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, now: i64) anyerror!Snapshot,
        payload: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, key: []const u8) anyerror![]const u8,
        apply: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, decisions: []const merge.Decision, pulled: *const Payloads) anyerror!Tokens,
    };

    pub fn snapshot(self: Adapter, arena: std.mem.Allocator, now: i64) !Snapshot {
        return self.vtable.snapshot(self.ctx, arena, now);
    }
    pub fn payload(self: Adapter, arena: std.mem.Allocator, key: []const u8) ![]const u8 {
        return self.vtable.payload(self.ctx, arena, key);
    }
    pub fn apply(self: Adapter, arena: std.mem.Allocator, decisions: []const merge.Decision, pulled: *const Payloads) !Tokens {
        return self.vtable.apply(self.ctx, arena, decisions, pulled);
    }
};

fn decisionFor(decisions: []const merge.Decision, key: []const u8) ?merge.Decision {
    for (decisions) |d| if (std.mem.eql(u8, d.key, key)) return d;
    return null;
}

/// Read a file plus its mtime; null when it does not exist.
fn readWithMtime(arena: std.mem.Allocator, path: []const u8, now: i64) !?struct { bytes: []u8, mtime_ms: i64 } {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    const bytes = try file.readToEndAlloc(arena, MAX_FILE_BYTES);
    const mtime_ms: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));
    return .{ .bytes = bytes, .mtime_ms = if (mtime_ms > 0) @min(mtime_ms, now) else now };
}

fn readOrEmpty(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(arena, path, MAX_FILE_BYTES) catch |err| switch (err) {
        error.FileNotFound => "",
        else => err,
    };
}

fn hexToken(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const h = crypto.sha256Hex(bytes);
    return arena.dupe(u8, &h);
}

// ---------------------------------------------------------------------------
// Password store
// ---------------------------------------------------------------------------

/// The synced form of an entry: the secret in plaintext (inside the sealed
/// manifest only). Field order is fixed so every computer hashes alike.
const PortableEntry = struct {
    name: []const u8,
    username: []const u8 = "",
    secret: []const u8 = "",
    note: []const u8 = "",
    agent: bool = true,
};

pub const Passwords = struct {
    path: []const u8,
    /// Filled by `snapshot`.
    original: []const u8 = "",
    vault: ?credential_store.Vault = null,

    pub fn deinit(self: *Passwords) void {
        if (self.vault) |*v| v.deinit();
        self.vault = null;
    }

    pub fn adapter(self: *Passwords) Adapter {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn keyOf(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.ascii.allocLowerString(arena, name);
    }

    fn entryToken(arena: std.mem.Allocator, entry: credential_store.Entry) ![]const u8 {
        const json = try std.json.Stringify.valueAlloc(arena, entry, .{});
        return hexToken(arena, json);
    }

    fn snapshot(ctx: *anyopaque, arena: std.mem.Allocator, now: i64) anyerror!Snapshot {
        const self: *Passwords = @ptrCast(@alignCast(ctx));
        self.deinit();
        const read = (try readWithMtime(arena, self.path, now)) orelse {
            self.original = "";
            self.vault = credential_store.Vault.init(arena);
            return .{ .items = &.{}, .missing = true, .changed_at = now };
        };
        self.original = read.bytes;
        self.vault = try credential_store.parse(arena, read.bytes);
        const vault = &self.vault.?;
        if (vault.legacy_plaintext) {
            // Same upgrade the Password Store page does on first load.
            try credential_store.sealLegacy(vault);
            try writeVault(arena, self.path, vault.entries.items);
            self.original = try readOrEmpty(arena, self.path);
        }
        const items = try arena.alloc(merge.LocalItem, vault.entries.items.len);
        for (vault.entries.items, items) |entry, *item| {
            item.* = .{ .key = try keyOf(arena, entry.name), .token = try entryToken(arena, entry) };
        }
        return .{ .items = items, .changed_at = read.mtime_ms };
    }

    fn payload(ctx: *anyopaque, arena: std.mem.Allocator, key: []const u8) anyerror![]const u8 {
        const self: *Passwords = @ptrCast(@alignCast(ctx));
        const vault = &(self.vault orelse return error.ItemVanished);
        for (vault.entries.items) |*entry| {
            if (!std.ascii.eqlIgnoreCase(entry.name, key)) continue;
            // `arena` sits on the wiping allocator: the plaintext is zeroed
            // when the run ends.
            const secret = try credential_store.reveal(arena, entry);
            return std.json.Stringify.valueAlloc(arena, PortableEntry{
                .name = entry.name,
                .username = entry.username,
                .secret = secret,
                .note = entry.note,
                .agent = entry.agent,
            }, .{});
        }
        return error.ItemVanished;
    }

    fn apply(ctx: *anyopaque, arena: std.mem.Allocator, decisions: []const merge.Decision, pulled: *const Payloads) anyerror!Tokens {
        const self: *Passwords = @ptrCast(@alignCast(ctx));
        const vault = &(self.vault orelse return error.ItemVanished);
        if (!std.mem.eql(u8, try readOrEmpty(arena, self.path), self.original)) return error.LocalChangedDuringSync;

        var tokens = Tokens.init(arena);
        var out: std.ArrayListUnmanaged(credential_store.Entry) = .empty;
        var seen = std.StringHashMap(void).init(arena);
        for (vault.entries.items) |entry| {
            const key = try keyOf(arena, entry.name);
            try seen.put(key, {});
            const d = decisionFor(decisions, key) orelse {
                try out.append(arena, entry);
                continue;
            };
            if (d.drop_local or !d.keep) continue;
            if (d.pull) {
                const pulled_entry = try fromPayload(arena, vault, pulled.get(key) orelse return error.MissingPayload);
                try out.append(arena, pulled_entry);
                try tokens.put(key, try entryToken(arena, pulled_entry));
            } else {
                try out.append(arena, entry);
            }
        }
        for (decisions) |d| {
            if (!d.pull or seen.contains(d.key)) continue;
            const pulled_entry = try fromPayload(arena, vault, pulled.get(d.key) orelse return error.MissingPayload);
            try out.append(arena, pulled_entry);
            try tokens.put(d.key, try entryToken(arena, pulled_entry));
        }
        try writeVault(arena, self.path, out.items);
        return tokens;
    }

    fn fromPayload(arena: std.mem.Allocator, vault: *credential_store.Vault, json: []const u8) !credential_store.Entry {
        const portable = try std.json.parseFromSliceLeaky(PortableEntry, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (portable.name.len == 0) return error.CorruptSyncItem;
        return .{
            .name = try vault.dupe(portable.name),
            .username = try vault.dupe(portable.username),
            .secret = try vault.seal(portable.secret),
            .note = try vault.dupe(portable.note),
            .agent = portable.agent,
        };
    }

    fn writeVault(allocator: std.mem.Allocator, path: []const u8, entries: []const credential_store.Entry) !void {
        const json = try credential_store.serialize(allocator, entries);
        if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
        try platform_atomic_file.writeFileReplaceSafeWithOptions(path, json, .{
            .mode = if (builtin.os.tag == .windows) std.fs.File.default_mode else 0o600,
        });
    }

    const vtable: Adapter.VTable = .{ .snapshot = snapshot, .payload = payload, .apply = apply };
};

// ---------------------------------------------------------------------------
// Hex-encoded profile line files (ssh_hosts, ai_profiles)
// ---------------------------------------------------------------------------

pub const LineFile = struct {
    path: []const u8,
    /// Written at the top when the file is created by sync.
    header: []const u8,
    /// How many profiles the app's list holds; at the cap, missing items are
    /// not read as deletions.
    cap: usize,
    original: []const u8 = "",
    preamble: []const u8 = "",
    lines: []Line = &.{},

    const Line = struct { key: []const u8, text: []const u8 };

    pub fn adapter(self: *LineFile) Adapter {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn snapshot(ctx: *anyopaque, arena: std.mem.Allocator, now: i64) anyerror!Snapshot {
        const self: *LineFile = @ptrCast(@alignCast(ctx));
        const read = (try readWithMtime(arena, self.path, now)) orelse {
            self.original = "";
            self.preamble = "";
            self.lines = &.{};
            return .{ .items = &.{}, .missing = true, .changed_at = now };
        };
        self.original = read.bytes;
        try self.parse(arena, read.bytes);
        const items = try arena.alloc(merge.LocalItem, self.lines.len);
        for (self.lines, items) |line, *item| item.* = .{ .key = line.key, .token = try hexToken(arena, line.text) };
        return .{ .items = items, .capped = self.lines.len >= self.cap, .changed_at = read.mtime_ms };
    }

    fn parse(self: *LineFile, arena: std.mem.Allocator, content: []const u8) !void {
        var lines: std.ArrayListUnmanaged(Line) = .empty;
        var keys = std.StringHashMap(void).init(arena);
        var preamble_end: usize = 0;
        var in_preamble = true;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw| {
            const text = std.mem.trimRight(u8, raw, "\r");
            const is_data = text.len > 0 and text[0] != '#';
            if (!is_data) {
                if (in_preamble) preamble_end = @intFromPtr(raw.ptr) - @intFromPtr(content.ptr) + raw.len + @intFromBool(it.index != null);
                continue;
            }
            in_preamble = false;
            const name = try decodeHexField(arena, text[0 .. std.mem.indexOfScalar(u8, text, '\t') orelse text.len]);
            // A duplicated name keeps both profiles: the copy gets a suffix key.
            var key: []const u8 = name;
            var n: usize = 2;
            while (keys.contains(key)) : (n += 1) key = try std.fmt.allocPrint(arena, "{s}\x00#{d}", .{ name, n });
            try keys.put(key, {});
            try lines.append(arena, .{ .key = key, .text = text });
        }
        self.preamble = content[0..@min(preamble_end, content.len)];
        self.lines = lines.items;
    }

    fn payload(ctx: *anyopaque, _: std.mem.Allocator, key: []const u8) anyerror![]const u8 {
        const self: *LineFile = @ptrCast(@alignCast(ctx));
        for (self.lines) |line| if (std.mem.eql(u8, line.key, key)) return line.text;
        return error.ItemVanished;
    }

    fn apply(ctx: *anyopaque, arena: std.mem.Allocator, decisions: []const merge.Decision, pulled: *const Payloads) anyerror!Tokens {
        const self: *LineFile = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, try readOrEmpty(arena, self.path), self.original)) return error.LocalChangedDuringSync;

        var tokens = Tokens.init(arena);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(arena, if (self.preamble.len > 0) self.preamble else self.header);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
        var seen = std.StringHashMap(void).init(arena);
        for (self.lines) |line| {
            try seen.put(line.key, {});
            const d = decisionFor(decisions, line.key) orelse {
                try appendLine(arena, &out, line.text);
                continue;
            };
            if (d.drop_local or !d.keep) continue;
            if (d.pull) {
                const text = singleLine(pulled.get(line.key) orelse return error.MissingPayload);
                try appendLine(arena, &out, text);
                try tokens.put(line.key, try hexToken(arena, text));
            } else {
                try appendLine(arena, &out, line.text);
            }
        }
        for (decisions) |d| {
            if (!d.pull or seen.contains(d.key)) continue;
            const text = singleLine(pulled.get(d.key) orelse return error.MissingPayload);
            try appendLine(arena, &out, text);
            try tokens.put(d.key, try hexToken(arena, text));
        }
        if (std.fs.path.dirname(self.path)) |dir| try std.fs.cwd().makePath(dir);
        try platform_atomic_file.writeFileReplaceSafe(self.path, out.items);
        return tokens;
    }

    fn appendLine(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
        try out.appendSlice(arena, text);
        try out.append(arena, '\n');
    }

    fn singleLine(text: []const u8) []const u8 {
        const end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
        return text[0..end];
    }

    const vtable: Adapter.VTable = .{ .snapshot = snapshot, .payload = payload, .apply = apply };
};

/// Profile names are stored hex-encoded; a field that is not valid hex is
/// used as-is.
fn decodeHexField(arena: std.mem.Allocator, field: []const u8) ![]const u8 {
    if (field.len % 2 != 0) return field;
    const out = try arena.alloc(u8, field.len / 2);
    _ = std.fmt.hexToBytes(out, field) catch return field;
    return out;
}

// ---------------------------------------------------------------------------
// Agent history
// ---------------------------------------------------------------------------

pub const HistoryMeta = struct {
    session_id: []const u8,
    updated_at: i64,
};

/// Implemented by the app over its process-wide agent-history store; every
/// call takes the store's lock.
pub const HistoryPort = struct {
    ctx: ?*anyopaque = null,
    /// null = the store is not open.
    list: *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!?[]HistoryMeta,
    /// A session as record JSON; null when it no longer exists.
    exportRecord: *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, session_id: []const u8) anyerror!?[]const u8,
    /// Upsert a session from record JSON; returns its updated_at.
    importRecord: *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, json: []const u8) anyerror!i64,
    delete: *const fn (ctx: ?*anyopaque, session_id: []const u8) void,
};

pub const History = struct {
    port: HistoryPort,

    pub fn adapter(self: *History) Adapter {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn token(arena: std.mem.Allocator, updated_at: i64) ![]const u8 {
        return std.fmt.allocPrint(arena, "{d}", .{updated_at});
    }

    fn snapshot(ctx: *anyopaque, arena: std.mem.Allocator, now: i64) anyerror!Snapshot {
        const self: *History = @ptrCast(@alignCast(ctx));
        const metas = (try self.port.list(self.port.ctx, arena)) orelse return error.HistoryUnavailable;
        const items = try arena.alloc(merge.LocalItem, metas.len);
        for (metas, items) |m, *item| item.* = .{ .key = m.session_id, .token = try token(arena, m.updated_at), .updated_at = m.updated_at };
        return .{ .items = items, .changed_at = now };
    }

    fn payload(ctx: *anyopaque, arena: std.mem.Allocator, key: []const u8) anyerror![]const u8 {
        const self: *History = @ptrCast(@alignCast(ctx));
        return (try self.port.exportRecord(self.port.ctx, arena, key)) orelse error.ItemVanished;
    }

    fn apply(ctx: *anyopaque, arena: std.mem.Allocator, decisions: []const merge.Decision, pulled: *const Payloads) anyerror!Tokens {
        const self: *History = @ptrCast(@alignCast(ctx));
        var tokens = Tokens.init(arena);
        for (decisions) |d| {
            if (d.drop_local) self.port.delete(self.port.ctx, d.key);
            if (!d.pull) continue;
            const json = pulled.get(d.key) orelse return error.MissingPayload;
            const updated_at = try self.port.importRecord(self.port.ctx, arena, json);
            try tokens.put(d.key, try token(arena, updated_at));
        }
        return tokens;
    }

    const vtable: Adapter.VTable = .{ .snapshot = snapshot, .payload = payload, .apply = apply };
};

/// Blob file of a history session: a hash keeps ids out of file names.
pub fn historyBlobName(arena: std.mem.Allocator, session_id: []const u8) ![]const u8 {
    const h = crypto.sha256Hex(session_id);
    return std.fmt.allocPrint(arena, "history/{s}.wsync", .{h[0..32]});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn hexLine(arena: std.mem.Allocator, fields: []const []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (fields, 0..) |f, i| {
        if (i > 0) try out.append(arena, '\t');
        for (f) |ch| try out.writer(arena).print("{X:0>2}", .{ch});
    }
    return out.items;
}

test "sync kinds: line files key by decoded name, keep the header and dedupe names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const path = try std.fs.path.join(a, &.{ dir, "ssh_hosts" });

    const box = try hexLine(a, &.{ "box", "10.0.0.1" });
    const box2 = try hexLine(a, &.{ "box", "10.0.0.2" });
    const lab = try hexLine(a, &.{ "lab", "lab.example" });
    const content = try std.fmt.allocPrint(a, "# header\n{s}\n{s}\n{s}\n", .{ box, box2, lab });
    try tmp.dir.writeFile(.{ .sub_path = "ssh_hosts", .data = content });

    var file = LineFile{ .path = path, .header = "# new\n", .cap = 128 };
    const snap = try file.adapter().snapshot(a, 1000);
    try std.testing.expectEqual(@as(usize, 3), snap.items.len);
    try std.testing.expectEqualStrings("box", snap.items[0].key);
    try std.testing.expectEqualStrings("box\x00#2", snap.items[1].key);
    try std.testing.expectEqualStrings(lab, try file.adapter().payload(a, "lab"));

    // Drop "lab", pull a new "web" and an update of "box".
    const web = try hexLine(a, &.{ "web", "web.example" });
    const box_new = try hexLine(a, &.{ "box", "10.0.0.9" });
    var pulled = Payloads.init(a);
    try pulled.put("web", web);
    try pulled.put("box", box_new);
    const decisions = [_]merge.Decision{
        .{ .key = "box", .keep = true, .pull = true },
        .{ .key = "lab", .keep = false, .drop_local = true },
        .{ .key = "web", .keep = true, .pull = true },
    };
    const tokens = try file.adapter().apply(a, &decisions, &pulled);
    try std.testing.expect(tokens.contains("web") and tokens.contains("box"));
    const written = try tmp.dir.readFileAlloc(a, "ssh_hosts", 1 << 20);
    const expected = try std.fmt.allocPrint(a, "# header\n{s}\n{s}\n{s}\n", .{ box_new, box2, web });
    try std.testing.expectEqualStrings(expected, written);
}

test "sync kinds: a file changed during the sync is not overwritten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const path = try std.fs.path.join(a, &.{ dir, "ai_profiles" });
    try tmp.dir.writeFile(.{ .sub_path = "ai_profiles", .data = "# h\n" });
    var file = LineFile{ .path = path, .header = "# h\n", .cap = 16 };
    _ = try file.adapter().snapshot(a, 1);
    try tmp.dir.writeFile(.{ .sub_path = "ai_profiles", .data = "# h\n6869\n" });
    var pulled = Payloads.init(a);
    try std.testing.expectError(error.LocalChangedDuringSync, file.adapter().apply(a, &.{}, &pulled));
}

test "sync kinds: password payload carries the plaintext and pulls are re-sealed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const path = try std.fs.path.join(a, &.{ dir, "passwords" });

    var vault = credential_store.Vault.init(a);
    try vault.append(.{ .name = "Root", .username = "root", .secret = try vault.seal("s3cret"), .note = "lab" });
    try tmp.dir.writeFile(.{ .sub_path = "passwords", .data = try credential_store.serialize(a, vault.entries.items) });

    var pw = Passwords{ .path = path };
    defer pw.deinit();
    const snap = try pw.adapter().snapshot(a, 50);
    try std.testing.expectEqualStrings("root", snap.items[0].key);
    const payload_json = try pw.adapter().payload(a, "root");
    try std.testing.expect(std.mem.indexOf(u8, payload_json, "\"secret\":\"s3cret\"") != null);

    var pulled = Payloads.init(a);
    try pulled.put("mysql", "{\"name\":\"MySQL\",\"secret\":\"pa ss\",\"agent\":false}");
    const decisions = [_]merge.Decision{.{ .key = "mysql", .keep = true, .pull = true }};
    _ = try pw.adapter().apply(a, &decisions, &pulled);
    const written = try tmp.dir.readFileAlloc(a, "passwords", 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, written, "pa ss") == null);
    const back = try credential_store.parse(a, written);
    try std.testing.expectEqual(@as(usize, 2), back.entries.items.len);
    const mysql = credential_store.lookup(back.entries.items, "mysql").?;
    try std.testing.expect(!mysql.agent);
    const secret = try credential_store.reveal(a, mysql);
    try std.testing.expectEqualStrings("pa ss", secret);
}

test "sync kinds: a missing file reads as missing, not as an empty set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var pw = Passwords{ .path = try std.fs.path.join(a, &.{ dir, "passwords" }) };
    defer pw.deinit();
    try std.testing.expect((try pw.adapter().snapshot(a, 1)).missing);
    var lines = LineFile{ .path = try std.fs.path.join(a, &.{ dir, "ssh_hosts" }), .header = "", .cap = 1 };
    try std.testing.expect((try lines.adapter().snapshot(a, 1)).missing);
    const blob = try historyBlobName(a, "session-1");
    try std.testing.expect(std.mem.startsWith(u8, blob, "history/") and std.mem.endsWith(u8, blob, ".wsync"));
}

test "sync kinds declarations compile" {
    std.testing.refAllDecls(@This());
}
