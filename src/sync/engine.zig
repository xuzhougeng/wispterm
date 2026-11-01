//! One sync run: unlock the drive (sync key from the passphrase or this
//! computer's sealed copy), then for every enabled kind read the local items,
//! fetch and open the drive's manifest, plan the merge (sync/merge.zig), upload
//! pushes and the new manifest, write pulls locally, and save the new base.
//!
//! Drive layout under the sync root:
//!   wispterm-sync.json      plaintext: format, Argon2id params, salt, key check
//!   <kind>.wsync            sealed manifest (passwords/ssh/AI items inline)
//!   history/<hash>.wsync    one sealed agent-history session each
//!
//! A kind that fails is reported and skipped; the others still sync.
const std = @import("std");
const crypto = @import("crypto.zig");
const merge = @import("merge.zig");
const kinds = @import("kinds.zig");
const sync_settings = @import("settings.zig");
const transport_mod = @import("transport.zig");

pub const META_NAME = "wispterm-sync.json";
const META_FORMAT = "wispterm-sync";

pub const Kind = sync_settings.Kind;
pub const KIND_COUNT = std.enums.values(Kind).len;

pub const Problem = enum {
    none,
    not_configured,
    need_passphrase,
    wrong_passphrase,
    auth_failed,
    folder_missing,
    drive_full,
    server_error,
    network,
    unsupported_method,
    corrupt_remote,
    newer_format,
    local_busy,
    history_unavailable,
    keychain,
    other,
};

pub const KindResult = struct {
    ran: bool = false,
    problem: Problem = .none,
    counts: merge.Counts = .{},
    /// Local data was rewritten (the UI reloads what it caches).
    local_changed: bool = false,
};

pub const Report = struct {
    /// Run-level failure (drive unreachable, passphrase, …); kinds did not run.
    problem: Problem = .none,
    kinds: [KIND_COUNT]KindResult = @splat(.{}),
    /// `@errorName` of the first unexpected error, for the status line.
    detail_buf: [48]u8 = undefined,
    detail_len: usize = 0,
    /// The sealed key / salt in the settings changed and must be saved.
    settings_changed: bool = false,

    pub fn detail(self: *const Report) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    pub fn firstProblem(self: *const Report) Problem {
        if (self.problem != .none) return self.problem;
        for (self.kinds) |k| if (k.problem != .none) return k.problem;
        return .none;
    }

    pub fn totals(self: *const Report) merge.Counts {
        var c: merge.Counts = .{};
        for (self.kinds) |k| {
            c.items += k.counts.items;
            c.pulled += k.counts.pulled;
            c.pushed += k.counts.pushed;
            c.deleted_local += k.counts.deleted_local;
            c.deleted_remote += k.counts.deleted_remote;
        }
        return c;
    }

    fn noteError(self: *Report, err: anyerror) Problem {
        const problem = classify(err);
        if (problem == .other and self.detail_len == 0) {
            const name = @errorName(err);
            self.detail_len = @min(name.len, self.detail_buf.len);
            @memcpy(self.detail_buf[0..self.detail_len], name[0..self.detail_len]);
        }
        return problem;
    }
};

pub const Context = struct {
    /// Per-run arena; should sit on a wiping allocator (plaintext secrets).
    arena: std.mem.Allocator,
    /// `<config-dir>/sync`, for bases.
    state_dir: []const u8,
    /// Updated in place when a key is derived (`report.settings_changed`).
    settings: *sync_settings.Settings,
    transport: transport_mod.Transport,
    adapters: [KIND_COUNT]?kinds.Adapter,
    /// Just typed by the user; used once to unlock or create the drive.
    passphrase: ?[]const u8 = null,
    now: i64,
    kdf: crypto.KdfParams = crypto.KdfParams.default,
};

const MetaFile = struct {
    format: []const u8 = META_FORMAT,
    version: u32 = 1,
    kdf: []const u8 = "argon2id",
    t: u32,
    m: u32,
    p: u24,
    salt: []const u8,
    check: []const u8,
};

pub fn run(ctx: *Context) Report {
    var report: Report = .{};
    if (!ctx.settings.hasLocation()) {
        report.problem = .not_configured;
        return report;
    }
    const key = unlock(ctx, &report) catch |err| {
        report.problem = report.noteError(err);
        return report;
    };
    for (std.enums.values(Kind)) |kind| {
        if (!ctx.settings.kindEnabled(kind)) continue;
        const adapter = ctx.adapters[@intFromEnum(kind)] orelse continue;
        var result: KindResult = .{ .ran = true };
        syncKind(ctx, key, kind, adapter, &result) catch |err| {
            result.problem = report.noteError(err);
        };
        report.kinds[@intFromEnum(kind)] = result;
    }
    return report;
}

/// The sync key for this drive: this computer's sealed copy when it still
/// matches the drive, else derived from the passphrase. A drive without a
/// meta file is initialized with a new salt.
fn unlock(ctx: *Context, report: *Report) !crypto.Key {
    const a = ctx.arena;
    const stored: ?crypto.Key = sync_settings.openSyncKey(a, ctx.settings.*) catch |err| switch (err) {
        error.WrongKey, error.CorruptSyncKey, error.InvalidBase64, error.NotSyncFile => null,
        else => return err,
    };
    if (try ctx.transport.get(a, META_NAME)) |bytes| {
        const meta = std.json.parseFromSliceLeaky(MetaFile, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.CorruptSyncItem;
        if (!std.mem.eql(u8, meta.format, META_FORMAT)) return error.CorruptSyncItem;
        if (meta.version > 1) return error.NewerSyncFormat;
        const check = try crypto.unbase64Alloc(a, meta.check);
        if (stored) |k| {
            if (std.mem.eql(u8, ctx.settings.key_salt, meta.salt) and crypto.verifyCheck(a, k, check)) return k;
        }
        const passphrase = ctx.passphrase orelse return error.NeedPassphrase;
        const salt = try crypto.unbase64Alloc(a, meta.salt);
        const k = try crypto.deriveKey(a, passphrase, salt, .{ .t = meta.t, .m = meta.m, .p = meta.p });
        if (!crypto.verifyCheck(a, k, check)) return error.WrongPassphrase;
        try storeKey(ctx, report, k, meta.salt);
        return k;
    }
    // Empty drive folder: initialize it (needs the passphrase).
    const passphrase = ctx.passphrase orelse return error.NeedPassphrase;
    const salt = crypto.randomSalt();
    const k = try crypto.deriveKey(a, passphrase, &salt, ctx.kdf);
    const salt_b64 = try crypto.base64Alloc(a, &salt);
    const meta_json = try std.json.Stringify.valueAlloc(a, MetaFile{
        .t = ctx.kdf.t,
        .m = ctx.kdf.m,
        .p = ctx.kdf.p,
        .salt = salt_b64,
        .check = try crypto.base64Alloc(a, try crypto.checkValue(a, k)),
    }, .{ .whitespace = .indent_2 });
    try ctx.transport.put(a, META_NAME, meta_json);
    try storeKey(ctx, report, k, salt_b64);
    return k;
}

fn storeKey(ctx: *Context, report: *Report, key: crypto.Key, salt_b64: []const u8) !void {
    const a = ctx.arena;
    // Bases describe the previous drive; against a different drive their
    // "missing locally" would read as deletions.
    if (!std.mem.eql(u8, ctx.settings.key_salt, salt_b64)) sync_settings.clearBases(a, ctx.state_dir);
    ctx.settings.key_sealed = try sync_settings.sealLocal(a, &key);
    ctx.settings.key_salt = try a.dupe(u8, salt_b64);
    report.settings_changed = true;
}

fn usesBlobs(kind: Kind) bool {
    return kind == .history;
}

fn syncKind(ctx: *Context, key: crypto.Key, kind: Kind, adapter: kinds.Adapter, result: *KindResult) !void {
    const a = ctx.arena;
    const manifest_name = kind.manifestName();

    const snap = try adapter.snapshot(a, ctx.now);
    const base = sync_settings.loadBase(a, ctx.state_dir, kind);
    const metas = try merge.resolveLocal(a, snap.items, base.items, snap.changed_at);
    var local_payloads = kinds.Payloads.init(a);
    for (metas) |*m| {
        if (m.hash != null) continue;
        const payload = try adapter.payload(a, m.key);
        try local_payloads.put(m.key, payload);
        m.hash = try a.dupe(u8, &crypto.sha256Hex(payload));
    }

    const remote: merge.Manifest = if (try ctx.transport.get(a, manifest_name)) |sealed|
        try merge.parseManifest(a, try crypto.open(a, key, manifest_name, sealed))
    else
        .{ .kind = @tagName(kind) };
    var remote_items = std.StringHashMap(merge.Item).init(a);
    for (remote.items) |item| try remote_items.put(item.key, item);

    const plan = try merge.plan(a, metas, base.items, remote, .{
        .now = ctx.now,
        .allow_local_deletions = !snap.missing and !snap.capped,
    });
    var remote_dirty = plan.remote_dirty;

    // Pulls: payloads from the manifest or their blobs.
    var pulled = kinds.Payloads.init(a);
    for (plan.decisions) |*d| {
        if (!d.pull) continue;
        const item = remote_items.get(d.key) orelse return error.CorruptSyncItem;
        const payload: []const u8 = if (item.data) |data| data else if (item.blob) |blob| blk: {
            const sealed = (try ctx.transport.get(a, blob)) orelse {
                // Lost blob: drop it from the manifest (no tombstone); the
                // computer that still has it uploads it again.
                d.* = .{ .key = d.key, .keep = false };
                remote_dirty = true;
                continue;
            };
            break :blk try crypto.open(a, key, blob, sealed);
        } else return error.CorruptSyncItem;
        const actual = crypto.sha256Hex(payload);
        if (!std.mem.eql(u8, &actual, d.hash)) {
            // A newer upload replaced the blob after the manifest was written.
            d.hash = try a.dupe(u8, &actual);
            remote_dirty = true;
        }
        try pulled.put(d.key, payload);
    }

    // Pushes, then the manifest, so it never names a blob that is not there.
    var items: std.ArrayListUnmanaged(merge.Item) = .empty;
    for (plan.decisions) |d| {
        if (d.drop_remote and usesBlobs(kind)) {
            if (remote_items.get(d.key)) |item| {
                if (item.blob) |blob| ctx.transport.delete(a, blob) catch {};
            }
        }
        if (!d.keep) continue;
        if (d.push) {
            const payload = local_payloads.get(d.key) orelse try adapter.payload(a, d.key);
            if (usesBlobs(kind)) {
                const blob = try kinds.historyBlobName(a, d.key);
                try ctx.transport.put(a, blob, try crypto.seal(a, key, blob, payload));
                try items.append(a, .{ .key = d.key, .updated_at = d.updated_at, .hash = d.hash, .blob = blob });
            } else {
                try items.append(a, .{ .key = d.key, .updated_at = d.updated_at, .hash = d.hash, .data = payload });
            }
        } else {
            var item = remote_items.get(d.key) orelse return error.CorruptSyncItem;
            item.updated_at = d.updated_at;
            item.hash = d.hash;
            try items.append(a, item);
        }
    }
    std.mem.sort(merge.Item, items.items, {}, merge.itemLess);
    if (remote_dirty) {
        const json = try merge.serializeManifest(a, .{ .kind = @tagName(kind), .items = items.items, .tombstones = plan.tombstones });
        try ctx.transport.put(a, manifest_name, try crypto.seal(a, key, manifest_name, json));
    }

    var tokens = std.StringHashMap([]const u8).init(a);
    for (snap.items) |item| try tokens.put(item.key, item.token);
    const local_dirty = plan.local_dirty or anyDropLocal(plan.decisions);
    if (local_dirty) {
        var written = try adapter.apply(a, plan.decisions, &pulled);
        var it = written.iterator();
        while (it.next()) |entry| try tokens.put(entry.key_ptr.*, entry.value_ptr.*);
        result.local_changed = true;
    }

    var new_base: std.ArrayListUnmanaged(merge.BaseItem) = .empty;
    for (plan.decisions) |d| {
        if (!d.keep) continue;
        const token = tokens.get(d.key) orelse continue;
        try new_base.append(a, .{ .key = d.key, .updated_at = d.updated_at, .hash = d.hash, .token = token });
    }
    try sync_settings.saveBase(a, ctx.state_dir, kind, .{ .items = new_base.items });

    var counts: merge.Counts = .{};
    for (plan.decisions) |d| {
        if (d.keep) counts.items += 1;
        if (d.pull) counts.pulled += 1;
        if (d.push) counts.pushed += 1;
        if (d.drop_local) counts.deleted_local += 1;
        if (d.drop_remote) counts.deleted_remote += 1;
    }
    result.counts = counts;
}

fn anyDropLocal(decisions: []const merge.Decision) bool {
    for (decisions) |d| if (d.drop_local) return true;
    return false;
}

pub fn classify(err: anyerror) Problem {
    return switch (err) {
        error.NeedPassphrase => .need_passphrase,
        error.WrongPassphrase => .wrong_passphrase,
        error.SyncAuthFailed => .auth_failed,
        error.SyncFolderMissing => .folder_missing,
        error.SyncDriveFull => .drive_full,
        error.SyncServerError => .server_error,
        error.UnsupportedHttpMethod => .unsupported_method,
        error.WrongKey, error.NotSyncFile, error.NotSyncManifest, error.CorruptSyncItem, error.InvalidBase64, error.MissingPayload => .corrupt_remote,
        error.SyntaxError, error.UnexpectedToken, error.UnexpectedEndOfInput, error.InvalidCharacter, error.MissingField, error.InvalidNumber => .corrupt_remote,
        error.NewerSyncFormat => .newer_format,
        error.LocalChangedDuringSync => .local_busy,
        error.HistoryUnavailable => .history_unavailable,
        error.InvalidSyncUrl => .not_configured,
        error.ConnectionTimedOut,
        error.UnknownHostName,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        error.TlsInitializationFailed,
        error.ProxyConfigurationFailed,
        error.WinHttpRequestFailed,
        error.MacosHttpRequestFailed,
        error.UnsupportedUriScheme,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.HostLacksNetworkAddresses,
        error.ConnectionAborted,
        => .network,
        error.KeychainUnavailable, error.KeyFileCorrupt, error.KeySealFailed, error.KeyUnsealFailed => .keychain,
        else => .other,
    };
}

// ---------------------------------------------------------------------------
// Tests: two "computers" syncing through one in-memory drive.
// ---------------------------------------------------------------------------

const FakeHistory = struct {
    records: std.StringArrayHashMapUnmanaged(Rec) = .empty,
    const Rec = struct { updated_at: i64, json: []const u8 };

    fn port(self: *FakeHistory) kinds.HistoryPort {
        return .{ .ctx = self, .list = list, .exportRecord = exportRecord, .importRecord = importRecord, .delete = delete };
    }
    fn list(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!?[]kinds.HistoryMeta {
        const self: *FakeHistory = @ptrCast(@alignCast(ctx.?));
        const out = try arena.alloc(kinds.HistoryMeta, self.records.count());
        for (self.records.keys(), self.records.values(), out) |k, v, *m| m.* = .{ .session_id = k, .updated_at = v.updated_at };
        return out;
    }
    fn exportRecord(ctx: ?*anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!?[]const u8 {
        const self: *FakeHistory = @ptrCast(@alignCast(ctx.?));
        return if (self.records.get(id)) |r| r.json else null;
    }
    fn importRecord(ctx: ?*anyopaque, arena: std.mem.Allocator, json: []const u8) anyerror!i64 {
        const self: *FakeHistory = @ptrCast(@alignCast(ctx.?));
        const Shape = struct { session_id: []const u8, updated_at: i64 };
        const parsed = try std.json.parseFromSliceLeaky(Shape, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        try self.records.put(std.testing.allocator, parsed.session_id, .{ .updated_at = parsed.updated_at, .json = json });
        return parsed.updated_at;
    }
    fn delete(ctx: ?*anyopaque, id: []const u8) void {
        const self: *FakeHistory = @ptrCast(@alignCast(ctx.?));
        _ = self.records.orderedRemove(id);
    }
};

const Computer = struct {
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    settings: sync_settings.Settings = .{ .url = "https://dav.example/dav" },
    ssh: kinds.LineFile = undefined,
    history: FakeHistory = .{},
    history_adapter: kinds.History = undefined,

    fn init(tmp: std.fs.Dir, name: []const u8) !*Computer {
        const self = try std.testing.allocator.create(Computer);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .dir = undefined };
        const a = self.arena.allocator();
        try tmp.makePath(name);
        const root = try tmp.realpathAlloc(a, name);
        self.dir = try std.fs.path.join(a, &.{ root, "sync" });
        self.ssh = .{ .path = try std.fs.path.join(a, &.{ root, "ssh_hosts" }), .header = "# hosts\n", .cap = 128 };
        self.settings.passwords = false;
        self.settings.ai_profiles = false;
        return self;
    }
    fn deinit(self: *Computer) void {
        self.history.records.deinit(std.testing.allocator);
        self.arena.deinit();
        std.testing.allocator.destroy(self);
    }
    fn sync(self: *Computer, drive: *transport_mod.Memory, passphrase: ?[]const u8, now: i64) Report {
        const a = self.arena.allocator();
        self.history_adapter = .{ .port = self.history.port() };
        var adapters: [KIND_COUNT]?kinds.Adapter = @splat(null);
        adapters[@intFromEnum(Kind.ssh_hosts)] = self.ssh.adapter();
        adapters[@intFromEnum(Kind.history)] = self.history_adapter.adapter();
        var ctx = Context{
            .arena = a,
            .state_dir = self.dir,
            .settings = &self.settings,
            .transport = drive.transport(),
            .adapters = adapters,
            .passphrase = passphrase,
            .now = now,
            .kdf = crypto.KdfParams.testing,
        };
        return run(&ctx);
    }
    fn writeHosts(self: *Computer, text: []const u8) !void {
        try std.fs.cwd().writeFile(.{ .sub_path = self.ssh.path, .data = text });
    }
    fn readHosts(self: *Computer) ![]const u8 {
        return std.fs.cwd().readFileAlloc(self.arena.allocator(), self.ssh.path, 1 << 20);
    }
};

test "sync engine: a second computer receives, deletes, and the first follows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var drive = transport_mod.Memory.init(std.testing.allocator);
    defer drive.deinit();
    const laptop = try Computer.init(tmp.dir, "laptop");
    defer laptop.deinit();
    const desktop = try Computer.init(tmp.dir, "desktop");
    defer desktop.deinit();

    // "box" and "lab", hex-encoded.
    try laptop.writeHosts("# hosts\n626F78\t31\n6C6162\t32\n");
    try laptop.history.records.put(std.testing.allocator, "s1", .{ .updated_at = 5, .json = "{\"session_id\":\"s1\",\"updated_at\":5,\"secret\":\"api-key-xyz\"}" });

    try std.testing.expectEqual(Problem.need_passphrase, laptop.sync(&drive, null, 1000).problem);
    var r = laptop.sync(&drive, "open sesame", 1000);
    try std.testing.expectEqual(Problem.none, r.firstProblem());
    try std.testing.expect(r.settings_changed);
    try std.testing.expectEqual(@as(usize, 3), r.totals().pushed);

    // Nothing on the drive is readable.
    for (drive.files.keys(), drive.files.values()) |name, data| {
        if (std.mem.eql(u8, name, META_NAME)) continue;
        try std.testing.expect(std.mem.indexOf(u8, data, "626F78") == null);
        try std.testing.expect(std.mem.indexOf(u8, data, "api-key-xyz") == null);
    }

    try std.testing.expectEqual(Problem.wrong_passphrase, desktop.sync(&drive, "guess", 1100).problem);
    r = desktop.sync(&drive, "open sesame", 1100);
    try std.testing.expectEqual(Problem.none, r.firstProblem());
    try std.testing.expectEqualStrings("# hosts\n626F78\t31\n6C6162\t32\n", try desktop.readHosts());
    try std.testing.expect(desktop.history.records.contains("s1"));
    try std.testing.expect(r.kinds[@intFromEnum(Kind.ssh_hosts)].local_changed);

    // A second run with no changes rewrites nothing.
    const puts_before = drive.puts;
    r = desktop.sync(&drive, null, 1200);
    try std.testing.expectEqual(Problem.none, r.firstProblem());
    try std.testing.expectEqual(puts_before, drive.puts);

    // The desktop deletes "lab" and the session; the laptop follows.
    try desktop.writeHosts("# hosts\n626F78\t31\n");
    _ = desktop.history.records.orderedRemove("s1");
    r = desktop.sync(&drive, null, 1300);
    try std.testing.expectEqual(@as(usize, 2), r.totals().deleted_remote);
    r = laptop.sync(&drive, null, 1400);
    try std.testing.expectEqual(Problem.none, r.firstProblem());
    try std.testing.expectEqualStrings("# hosts\n626F78\t31\n", try laptop.readHosts());
    try std.testing.expect(!laptop.history.records.contains("s1"));
    try std.testing.expect(drive.files.count() == 3); // meta + two manifests; the blob is gone
}

test "sync engine: a computer whose hosts file vanished pulls instead of deleting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var drive = transport_mod.Memory.init(std.testing.allocator);
    defer drive.deinit();
    const pc = try Computer.init(tmp.dir, "pc");
    defer pc.deinit();
    pc.settings.history = false;
    try pc.writeHosts("# hosts\n626F78\t31\n");
    _ = pc.sync(&drive, "pw", 10);
    try std.fs.cwd().deleteFile(pc.ssh.path);
    const r = pc.sync(&drive, null, 20);
    try std.testing.expectEqual(Problem.none, r.firstProblem());
    try std.testing.expectEqualStrings("# hosts\n626F78\t31\n", try pc.readHosts());
}

test "sync engine: newer edits win and a missing location is reported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var drive = transport_mod.Memory.init(std.testing.allocator);
    defer drive.deinit();
    const a = try Computer.init(tmp.dir, "a");
    defer a.deinit();
    const b = try Computer.init(tmp.dir, "b");
    defer b.deinit();
    a.settings.history = false;
    b.settings.history = false;

    try a.writeHosts("# hosts\n626F78\t31\n");
    _ = a.sync(&drive, "pw", 10);
    _ = b.sync(&drive, "pw", 20);
    try b.writeHosts("# hosts\n626F78\t39\n");
    _ = b.sync(&drive, null, std.time.milliTimestamp() + 1000);
    const r = a.sync(&drive, null, std.time.milliTimestamp() + 2000);
    try std.testing.expectEqual(@as(usize, 1), r.totals().pulled);
    try std.testing.expectEqualStrings("# hosts\n626F78\t39\n", try a.readHosts());

    var unset = sync_settings.Settings{};
    var ctx = Context{ .arena = a.arena.allocator(), .state_dir = a.dir, .settings = &unset, .transport = drive.transport(), .adapters = @splat(null), .now = 1 };
    try std.testing.expectEqual(Problem.not_configured, run(&ctx).problem);
}

test "sync engine declarations compile" {
    std.testing.refAllDecls(@This());
}
