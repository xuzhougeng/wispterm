const std = @import("std");
const scan = @import("skill_scan.zig");
const inv = @import("skill_inventory.zig");
const pairing = @import("skill_pairing.zig");
const inv_cache = @import("skill_inventory_cache.zig");
const dirs = @import("platform/dirs.zig");

/// Source descriptor for a scan column. `id` is the stable column identity;
/// `name` is the display label.
pub const ScanSource = struct {
    id: []const u8,
    name: []const u8,
};

/// Seam that produces an `ExecHost` for a source (or errors -> unreachable
/// column). The integration layer supplies a real factory; tests use a fake.
pub const HostFactory = struct {
    ctx: *anyopaque,
    make: *const fn (*anyopaque, std.mem.Allocator, ScanSource) anyerror!scan.ExecHost,
};

/// Scan every source and return owned `[]inv.ServerScan` (free with
/// `inv_cache.freeServerScans` then free the slice). A source whose host cannot
/// be created, or whose scan reports unreachable, becomes an unreachable column
/// with no rows.
pub fn runScan(
    allocator: std.mem.Allocator,
    sources: []const ScanSource,
    factory: HostFactory,
) ![]inv.ServerScan {
    var out = try allocator.alloc(inv.ServerScan, sources.len);
    var built: usize = 0;
    errdefer {
        inv_cache.freeServerScans(allocator, out[0..built]);
        allocator.free(out);
    }

    for (sources, 0..) |src, i| {
        const id_copy = try allocator.dupe(u8, src.id);
        errdefer allocator.free(id_copy);

        const host = factory.make(factory.ctx, allocator, src) catch {
            out[i] = .{ .source_id = id_copy, .reachable = false, .rows = &.{} };
            built += 1;
            continue;
        };

        var outcome = scan.scanSource(allocator, scan.defaultTargets(), host) catch {
            out[i] = .{ .source_id = id_copy, .reachable = false, .rows = &.{} };
            built += 1;
            continue;
        };
        out[i] = .{ .source_id = id_copy, .reachable = outcome.reachable, .rows = outcome.rows };
        outcome.rows = &.{}; // ownership moved into the ServerScan
        built += 1;
    }

    return out;
}

/// Build a command that prints one skill's SKILL.md / prompt file from a
/// server, given its `rel_path` (relative to $HOME, as produced by the scan).
/// The path is single-quote-escaped so a hostile name from a remote listing
/// cannot inject shell; $HOME still expands via the surrounding double quotes.
pub fn previewCommand(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "cat \"$HOME\"/'");
    for (rel_path) |c| {
        if (c == '\'') {
            try buf.appendSlice(allocator, "'\\''");
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, '\'');
    return buf.toOwnedSlice(allocator);
}

// --- Tests ---

/// Panel state for the Skill Center UI: owns the current scan results,
/// the focused cell, scroll offset, and a stale flag. The background scan
/// worker (integration layer) calls `setServers` to swap in new results;
/// `seedFromCache` loads the last persisted scan for instant display.
pub const PanelModel = struct {
    allocator: std.mem.Allocator,
    servers: ?[]inv.ServerScan = null,
    /// Aligned local-vs-selected-server view (rows borrow from `servers`).
    pairing: ?[]pairing.PairRow = null,
    /// Index into the remote servers (everything except source_id == "local").
    sel_server: usize = 0,
    sel_row: usize = 0,
    scroll: usize = 0,
    stale: bool = false,

    pub fn init(allocator: std.mem.Allocator) PanelModel {
        return .{ .allocator = allocator };
    }

    /// Seed from the persisted cache so the panel renders immediately; mark stale.
    pub fn seedFromCache(self: *PanelModel) void {
        const cached = inv_cache.load(self.allocator) catch return;
        if (cached.len == 0) {
            self.allocator.free(cached);
            return;
        }
        self.setServers(cached);
        self.stale = true;
    }

    /// Take ownership of a fresh `[]inv.ServerScan`, rebuild the pairing, clear stale.
    pub fn setServers(self: *PanelModel, servers: []inv.ServerScan) void {
        self.freeServers();
        self.servers = servers;
        self.stale = false;
        self.rebuildPairing();
    }

    /// Index in `servers` of the local hub ("local"); null if none present.
    fn localIndex(self: *const PanelModel) ?usize {
        const servers = self.servers orelse return null;
        for (servers, 0..) |s, i| {
            if (std.mem.eql(u8, s.source_id, "local")) return i;
        }
        return null;
    }

    /// Count of selectable remote servers (all non-local columns).
    pub fn remoteCount(self: *const PanelModel) usize {
        const servers = self.servers orelse return 0;
        const li = self.localIndex();
        var n: usize = 0;
        for (servers, 0..) |_, i| {
            if (li != null and i == li.?) continue;
            n += 1;
        }
        return n;
    }

    /// Resolve `sel_server` (an index over remote servers) to an index in
    /// `servers`; null when there are no remote servers.
    pub fn selectedServerIndex(self: *const PanelModel) ?usize {
        const servers = self.servers orelse return null;
        const li = self.localIndex();
        var n: usize = 0;
        for (servers, 0..) |_, i| {
            if (li != null and i == li.?) continue;
            if (n == self.sel_server) return i;
            n += 1;
        }
        return null;
    }

    /// Rebuild `pairing` from the local hub vs the selected server. Frees any
    /// prior pairing slice (rows borrow from `servers`, so only the slice).
    pub fn rebuildPairing(self: *PanelModel) void {
        if (self.pairing) |p| {
            self.allocator.free(p);
            self.pairing = null;
        }
        const servers = self.servers orelse return;
        const local: inv.ServerScan = if (self.localIndex()) |li|
            servers[li]
        else
            .{ .source_id = "local", .reachable = false, .rows = &.{} };
        const remote_idx = self.selectedServerIndex() orelse {
            self.pairing = pairing.pair(self.allocator, local, .{ .source_id = "", .reachable = false, .rows = &.{} }, false) catch null;
            self.clampSelection();
            return;
        };
        const remote = servers[remote_idx];
        self.pairing = pairing.pair(self.allocator, local, remote, remote.reachable) catch null;
        self.clampSelection();
    }

    fn clampSelection(self: *PanelModel) void {
        const rows = if (self.pairing) |p| p.len else 0;
        if (rows == 0) {
            self.sel_row = 0;
        } else if (self.sel_row >= rows) {
            self.sel_row = rows - 1;
        }
        const rc = self.remoteCount();
        if (rc == 0) {
            self.sel_server = 0;
        } else if (self.sel_server >= rc) {
            self.sel_server = rc - 1;
        }
    }

    fn freeServers(self: *PanelModel) void {
        if (self.pairing) |p| {
            self.allocator.free(p);
            self.pairing = null;
        }
        if (self.servers) |s| {
            inv_cache.freeServerScans(self.allocator, s);
            self.allocator.free(s);
            self.servers = null;
        }
    }

    pub fn deinit(self: *PanelModel) void {
        self.freeServers();
        self.* = undefined;
    }
};

/// Owned unit of background scan work. `run` performs the blocking scan on the
/// worker thread and returns owned `[]inv.ServerScan` (free with
/// `inv_cache.freeServerScans` then free the slice). `destroy` frees `ctx`. Both
/// run on the worker thread; `ctx` must own everything `run` needs and hold no
/// pointers into threadlocal UI state. Mirrors `ai_history_session.ScanWork`.
pub const ScanWork = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, std.mem.Allocator) anyerror![]inv.ServerScan,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// Concurrency-safe holder for the Skill Center panel. Mirrors
/// `ai_history_session.Session`'s discipline: `mutex` guards the `model` and
/// `status`; the background scan worker runs host I/O without the lock and takes
/// it only to publish via `finishScan`; `closing` + join-on-deinit give UAF
/// safety. The renderer reads the model on the UI thread under `mutex`.
pub const Session = struct {
    allocator: std.mem.Allocator,
    model: PanelModel,
    mutex: std.Thread.Mutex = .{},
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_generation: u64 = 0,
    scan_thread: ?std.Thread = null,
    /// Owned status string ("Scanning…"/"Done"/"Failed"/""). Reset via setStatus.
    status: []u8 = &.{},

    pub fn create(allocator: std.mem.Allocator) !*Session {
        const self = try allocator.create(Session);
        self.* = .{ .allocator = allocator, .model = PanelModel.init(allocator) };
        return self;
    }

    pub fn destroy(self: *Session) void {
        const allocator = self.allocator;
        self.closing.store(true, .release);
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        self.model.deinit();
        if (self.status.len > 0) allocator.free(self.status);
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Seed from the persisted cache for instant display. UI thread, before any
    /// worker is spawned (no lock needed — single-threaded at this point).
    pub fn seedFromCache(self: *Session) void {
        self.model.seedFromCache();
    }

    /// Replace the owned status string. Callers must hold `mutex`.
    fn setStatusLocked(self: *Session, text: []const u8) void {
        const next = self.allocator.dupe(u8, text) catch return;
        if (self.status.len > 0) self.allocator.free(self.status);
        self.status = next;
    }

    /// Start a background scan. UI thread only. Joins any prior worker first (at
    /// most one in flight), bumps the generation, sets status "Scanning…", and
    /// spawns the worker. Returns immediately. On spawn failure marks "Failed"
    /// and destroys `work`.
    pub fn scanAsync(self: *Session, work: ScanWork) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        self.mutex.lock();
        self.scan_generation +%= 1;
        const generation = self.scan_generation;
        self.setStatusLocked("Scanning…");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, scanThreadMain, .{ self, work, generation }) catch {
            self.mutex.lock();
            if (generation == self.scan_generation) self.setStatusLocked("Failed");
            self.mutex.unlock();
            work.destroy(work.ctx, self.allocator);
            return;
        };
        self.scan_thread = thread;
    }

    /// Publish the scan result under the lock if `generation` is current and we
    /// are not closing; otherwise discard `servers` (free + free slice). Always
    /// consumes ownership of `servers`. Worker-thread only.
    pub fn finishScan(self: *Session, generation: u64, servers: []inv.ServerScan) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.scan_generation) {
            self.model.setServers(servers);
            self.setStatusLocked("");
        } else {
            inv_cache.freeServerScans(self.allocator, servers);
            self.allocator.free(servers);
        }
    }

    /// Mark the scan failed if `generation` is still current and not closing.
    pub fn publishScanFailure(self: *Session, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.scan_generation) {
            self.setStatusLocked("Failed");
        }
    }

    /// Test-only: wait for an in-flight worker so results can be asserted.
    pub fn joinForTest(self: *Session) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
    }
};

fn scanThreadMain(session: *Session, work: ScanWork, generation: u64) void {
    defer work.destroy(work.ctx, session.allocator);
    const servers = work.run(work.ctx, session.allocator) catch {
        session.publishScanFailure(generation);
        return;
    };
    session.finishScan(generation, servers);
}

test "skill_center: previewCommand single-quotes the rel path under HOME" {
    const allocator = std.testing.allocator;
    const cmd = try previewCommand(allocator, ".claude/skills/pdf/SKILL.md");
    defer allocator.free(cmd);
    try std.testing.expectEqualStrings("cat \"$HOME\"/'.claude/skills/pdf/SKILL.md'", cmd);
}

test "skill_center: previewCommand escapes single quotes" {
    const allocator = std.testing.allocator;
    const cmd = try previewCommand(allocator, "a'b/SKILL.md");
    defer allocator.free(cmd);
    try std.testing.expectEqualStrings("cat \"$HOME\"/'a'\\''b/SKILL.md'", cmd);
}

test "skill_center: seedFromCache loads persisted scan and marks stale" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    dirs.setTestConfigDirForCurrentThread(tmp_path);
    defer dirs.clearTestConfigDirForCurrentThread();

    // Persist a one-server scan.
    const rows = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const servers = [_]inv.ServerScan{
        .{ .source_id = "local", .reachable = true, .rows = &rows },
    };
    try inv_cache.save(allocator, &servers);

    var model = PanelModel.init(allocator);
    defer model.deinit();
    model.seedFromCache();

    try std.testing.expect(model.stale);
    try std.testing.expect(model.servers != null);
    try std.testing.expect(model.pairing != null);
    try std.testing.expectEqual(@as(usize, 1), model.pairing.?.len);
}

test "skill_center: PanelModel setServers rebuilds pairing and clamps selection" {
    const allocator = std.testing.allocator;
    var model = PanelModel.init(allocator);
    defer model.deinit();

    // First scan: 2 skills.
    const rows1 = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("h") },
        .{ .provider = .claude, .name = @constCast("b"), .rel_path = @constCast(".claude/skills/b/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const s1 = try allocator.alloc(inv.ServerScan, 1);
    s1[0] = .{ .source_id = try allocator.dupe(u8, "local"), .reachable = true, .rows = try dupRows(allocator, &rows1) };
    model.setServers(s1);
    model.sel_row = 1; // select the 2nd skill

    try std.testing.expect(model.pairing != null);
    try std.testing.expectEqual(@as(usize, 2), model.pairing.?.len);

    // Replace with a scan that has only 1 skill -> selection must clamp to 0.
    const rows2 = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const s2 = try allocator.alloc(inv.ServerScan, 1);
    s2[0] = .{ .source_id = try allocator.dupe(u8, "local"), .reachable = true, .rows = try dupRows(allocator, &rows2) };
    model.setServers(s2);

    try std.testing.expectEqual(@as(usize, 1), model.pairing.?.len);
    try std.testing.expectEqual(@as(usize, 0), model.sel_row); // clamped
}

// Helper: deep-dupe borrowed rows into owned rows the model/cache can free.
fn dupRows(allocator: std.mem.Allocator, src: []const scan.SkillRow) ![]scan.SkillRow {
    const out = try allocator.alloc(scan.SkillRow, src.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*r| r.deinit(allocator);
        allocator.free(out);
    }
    for (src, 0..) |r, i| {
        out[i] = .{
            .provider = r.provider,
            .name = try allocator.dupe(u8, r.name),
            .rel_path = try allocator.dupe(u8, r.rel_path),
            .agg_hash = if (r.agg_hash) |h| try allocator.dupe(u8, h) else null,
        };
        built += 1;
    }
    return out;
}

// Build an owned one-server scan the Session can take ownership of and free.
fn ownedServers(allocator: std.mem.Allocator) ![]inv.ServerScan {
    const rows = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const s = try allocator.alloc(inv.ServerScan, 1);
    s[0] = .{ .source_id = try allocator.dupe(u8, "local"), .reachable = true, .rows = try dupRows(allocator, &rows) };
    return s;
}

test "skill_center: Session.finishScan publishes a current-generation result" {
    const allocator = std.testing.allocator;
    const session = try Session.create(allocator);
    defer session.destroy();

    // No scan started yet -> generation is 0; bump it once to mirror scanAsync.
    session.scan_generation +%= 1;
    const gen = session.scan_generation;
    session.finishScan(gen, try ownedServers(allocator));

    try std.testing.expect(session.model.servers != null);
    try std.testing.expect(session.model.pairing != null);
    try std.testing.expectEqual(@as(usize, 1), session.model.pairing.?.len);
}

test "skill_center: Session.finishScan discards a stale-generation result (no leak)" {
    const allocator = std.testing.allocator;
    const session = try Session.create(allocator);
    defer session.destroy();

    session.scan_generation = 5; // current generation
    // A worker from an older generation finishes late: must be discarded + freed.
    session.finishScan(3, try ownedServers(allocator));

    try std.testing.expect(session.model.servers == null);
    try std.testing.expect(session.model.pairing == null);
}

test "skill_center: model builds pairing for the selected server" {
    const allocator = std.testing.allocator;
    var model = PanelModel.init(allocator);
    defer model.deinit();

    const local_rows = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const web_rows = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("DIFF") },
        .{ .provider = .claude, .name = @constCast("b"), .rel_path = @constCast(".claude/skills/b/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const s = try allocator.alloc(inv.ServerScan, 2);
    s[0] = .{ .source_id = try allocator.dupe(u8, "local"), .reachable = true, .rows = try dupRows(allocator, &local_rows) };
    s[1] = .{ .source_id = try allocator.dupe(u8, "ssh:web"), .reachable = true, .rows = try dupRows(allocator, &web_rows) };
    model.setServers(s);

    try std.testing.expect(model.pairing != null);
    // local 'a' differs from web 'a'; web 'b' is remote_only -> 2 rows.
    try std.testing.expectEqual(@as(usize, 2), model.pairing.?.len);
    try std.testing.expectEqual(@as(usize, 0), model.sel_server); // first (only) remote
}
