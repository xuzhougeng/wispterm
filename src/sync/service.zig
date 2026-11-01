//! Process-wide sync worker. One background thread runs sync/engine.zig: a
//! few seconds after launch, every `interval_minutes`, soon after the password
//! store / SSH hosts / AI profiles files change, and on demand ("Sync Now").
//! Windows read `snapshot()` for the Sync page and poll the revisions to
//! reload data a sync rewrote; the worker never touches UI state.
//!
//! The app wires it once (`start`) with the pieces that live in the
//! integration layer: the agent-history port, the profile file headers, and
//! the window wakeup.
const std = @import("std");
const engine = @import("engine.zig");
const kinds = @import("kinds.zig");
const merge = @import("merge.zig");
const sync_settings = @import("settings.zig");
const transport = @import("transport.zig");
const wiping_allocator = @import("wiping_allocator.zig");
const credential_store = @import("../credential/store.zig");
const platform_dirs = @import("../platform/dirs.zig");

pub const Kind = sync_settings.Kind;
pub const Problem = engine.Problem;

const STARTUP_DELAY_MS: i64 = 5 * std.time.ms_per_s;
/// How often the worker checks the small files' mtimes for local edits.
const CHANGE_POLL_MS: i64 = 30 * std.time.ms_per_s;
/// Never sync more often than this because of local edits alone.
const CHANGE_MIN_GAP_MS: i64 = 60 * std.time.ms_per_s;

pub const Config = struct {
    history: ?kinds.HistoryPort = null,
    ssh_header: []const u8 = "",
    ai_header: []const u8 = "",
    /// Size of the app's in-memory profile lists (see kinds.Snapshot.capped).
    ssh_cap: usize = 128,
    ai_cap: usize = 16,
    /// Wake every window after a run so pages repaint and caches reload.
    wake: ?*const fn () void = null,
};

pub const Status = struct {
    running: bool = false,
    has_run: bool = false,
    finished_at_ms: i64 = 0,
    /// The last run was a "Sync Now".
    manual: bool = false,
    problem: Problem = .none,
    /// Kind that failed, for a kind-level problem.
    problem_kind: ?Kind = null,
    http_status: u16 = 0,
    detail_buf: [48]u8 = undefined,
    detail_len: usize = 0,
    totals: merge.Counts = .{},
    items: [engine.KIND_COUNT]usize = @splat(0),
    /// Bumps whenever any field above changes.
    revision: u64 = 0,

    pub fn detail(self: *const Status) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }
};

const Service = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    /// Serializes settings.json read-modify-write between the page and the worker.
    settings_mutex: std.Thread.Mutex = .{},
    allocator: ?std.mem.Allocator = null,
    thread: ?std.Thread = null,
    config: Config = .{},
    stopping: bool = false,
    run_requested: bool = false,
    manual_requested: bool = false,
    passphrase: ?[]u8 = null,
    /// The running sync was given a passphrase (the page shows "Checking…").
    unlocking: bool = false,
    status: Status = .{},
    data_revision: [engine.KIND_COUNT]std.atomic.Value(u64) = @splat(.init(0)),
};

var g_service: Service = .{};

pub fn start(allocator: std.mem.Allocator, config: Config) void {
    const s = &g_service;
    s.mutex.lock();
    defer s.mutex.unlock();
    if (s.thread != null) return;
    s.allocator = allocator;
    s.config = config;
    s.stopping = false;
    s.thread = std.Thread.spawn(.{}, threadMain, .{s}) catch |err| {
        std.log.scoped(.sync).warn("sync worker failed to start: {}", .{err});
        return;
    };
}

/// Stop and join the worker (waits for an in-flight request to finish).
pub fn stop() void {
    const s = &g_service;
    s.mutex.lock();
    const thread = s.thread;
    s.thread = null;
    s.stopping = true;
    s.cond.broadcast();
    s.mutex.unlock();
    if (thread) |t| t.join();
    s.mutex.lock();
    defer s.mutex.unlock();
    if (s.passphrase) |p| wipeOwned(s, p);
    s.passphrase = null;
}

/// Run a sync as soon as possible. `manual` = the user asked (toast after).
pub fn requestSync(manual: bool) void {
    const s = &g_service;
    s.mutex.lock();
    defer s.mutex.unlock();
    s.run_requested = true;
    if (manual) s.manual_requested = true;
    s.cond.broadcast();
}

/// Hand a just-typed passphrase to the next run (unlocks or initializes the
/// drive), and run now. The copy is wiped after use.
pub fn submitPassphrase(text: []const u8) void {
    const s = &g_service;
    s.mutex.lock();
    defer s.mutex.unlock();
    const allocator = s.allocator orelse return;
    if (s.passphrase) |old| wipeOwned(s, old);
    s.passphrase = allocator.dupe(u8, text) catch null;
    s.run_requested = true;
    s.manual_requested = true;
    s.cond.broadcast();
}

/// Settings changed (interval, kinds): re-read them now.
pub fn reconfigure() void {
    const s = &g_service;
    s.mutex.lock();
    defer s.mutex.unlock();
    s.cond.broadcast();
}

/// A drive location and an unlocked key are saved on this computer.
pub fn isSetUp(allocator: std.mem.Allocator) bool {
    const dir = sync_settings.defaultDir(allocator) catch return false;
    defer allocator.free(dir);
    lockSettings();
    defer unlockSettings();
    var loaded = sync_settings.load(allocator, dir) catch return false;
    defer loaded.deinit();
    return loaded.value.hasLocation() and loaded.value.hasKey();
}

pub fn snapshot() Status {
    const s = &g_service;
    s.mutex.lock();
    defer s.mutex.unlock();
    return s.status;
}

pub fn passphrasePending() bool {
    const s = &g_service;
    s.mutex.lock();
    defer s.mutex.unlock();
    return s.passphrase != null or s.unlocking;
}

/// Bumps when a sync rewrote this kind's local data.
pub fn dataRevision(kind: Kind) u64 {
    return g_service.data_revision[@intFromEnum(kind)].load(.acquire);
}

pub fn lockSettings() void {
    g_service.settings_mutex.lock();
}

pub fn unlockSettings() void {
    g_service.settings_mutex.unlock();
}

/// Save the fields the Sync page edits, keeping the worker-owned key fields
/// from disk.
pub fn saveUserSettings(allocator: std.mem.Allocator, dir: []const u8, value: sync_settings.Settings) !void {
    lockSettings();
    defer unlockSettings();
    var disk = try sync_settings.load(allocator, dir);
    defer disk.deinit();
    var merged = value;
    merged.key_sealed = disk.value.key_sealed;
    merged.key_salt = disk.value.key_salt;
    try sync_settings.save(allocator, dir, merged);
}

/// Forget this computer's sync setup. Waits for a run in progress.
pub fn forget(dir: []const u8) void {
    lockSettings();
    defer unlockSettings();
    sync_settings.forget(dir);
    const s = &g_service;
    s.mutex.lock();
    defer s.mutex.unlock();
    s.status = .{ .revision = s.status.revision +% 1 };
}

fn wipeOwned(s: *Service, secret: []u8) void {
    std.crypto.secureZero(u8, secret);
    if (s.allocator) |a| a.free(secret);
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

const Watch = struct {
    mtimes: [3]i128 = @splat(0),
    changed_at: i64 = 0,
};

fn threadMain(s: *Service) void {
    var next_auto: i64 = std.time.milliTimestamp() + STARTUP_DELAY_MS;
    var last_run: i64 = 0;
    var watch: Watch = .{};
    var watch_primed = false;
    while (true) {
        s.mutex.lock();
        var manual = false;
        while (!s.stopping and !s.run_requested) {
            const now = std.time.milliTimestamp();
            const interval_ms = currentIntervalMs(s);
            if (interval_ms > 0 and now >= next_auto) break;
            if (interval_ms > 0 and watch.changed_at > 0 and now - last_run >= CHANGE_MIN_GAP_MS and now - watch.changed_at >= 10 * std.time.ms_per_s) break;
            var wait_ms: i64 = CHANGE_POLL_MS;
            if (interval_ms > 0) wait_ms = @min(wait_ms, @max(1, next_auto - now));
            s.cond.timedWait(&s.mutex, @intCast(wait_ms * std.time.ns_per_ms)) catch {};
            if (s.stopping or s.run_requested) break;
            s.mutex.unlock();
            if (localFilesChanged(s, &watch, watch_primed)) {
                if (watch.changed_at == 0) watch.changed_at = std.time.milliTimestamp();
            }
            watch_primed = true;
            s.mutex.lock();
        }
        if (s.stopping) {
            s.mutex.unlock();
            return;
        }
        manual = s.manual_requested;
        s.run_requested = false;
        s.manual_requested = false;
        const passphrase = s.passphrase;
        s.passphrase = null;
        s.unlocking = passphrase != null;
        s.status.running = true;
        s.status.revision +%= 1;
        s.mutex.unlock();
        if (s.config.wake) |wake| wake();

        var status = runOnce(s, passphrase);
        if (passphrase) |p| {
            s.mutex.lock();
            wipeOwned(s, p);
            s.mutex.unlock();
        }

        last_run = std.time.milliTimestamp();
        next_auto = last_run + @max(currentIntervalMs(s), CHANGE_POLL_MS);
        _ = localFilesChanged(s, &watch, false); // re-prime after our own writes
        watch.changed_at = 0;
        watch_primed = true;

        s.mutex.lock();
        status.manual = manual;
        status.running = false;
        status.has_run = true;
        status.finished_at_ms = last_run;
        status.revision = s.status.revision +% 1;
        s.status = status;
        s.unlocking = false;
        s.mutex.unlock();
        if (s.config.wake) |wake| wake();
    }
}

fn currentIntervalMs(s: *Service) i64 {
    const allocator = s.allocator orelse return 0;
    const dir = sync_settings.defaultDir(allocator) catch return 0;
    defer allocator.free(dir);
    var loaded = sync_settings.load(allocator, dir) catch return 0;
    defer loaded.deinit();
    if (!loaded.value.hasLocation() or !loaded.value.hasKey()) return 0;
    return @as(i64, loaded.value.interval_minutes) * std.time.ms_per_min;
}

/// Watch the small kinds' files for edits made outside a sync.
fn localFilesChanged(s: *Service, watch: *Watch, primed: bool) bool {
    const allocator = s.allocator orelse return false;
    const paths = [_]?[]const u8{
        credential_store.path(allocator) catch null,
        platform_dirs.sshHostsPath(allocator) catch null,
        platform_dirs.aiProfilesPath(allocator) catch null,
    };
    defer for (paths) |p| if (p) |path| allocator.free(path);
    var changed = false;
    for (paths, 0..) |maybe_path, i| {
        const path = maybe_path orelse continue;
        const mtime: i128 = if (std.fs.cwd().statFile(path)) |st| st.mtime else |_| 0;
        if (primed and mtime != watch.mtimes[i]) changed = true;
        watch.mtimes[i] = mtime;
    }
    return changed;
}

fn runOnce(s: *Service, passphrase: ?[]const u8) Status {
    var status: Status = .{};
    const allocator = s.allocator orelse return status;
    var wiping = wiping_allocator.WipingAllocator{ .child = allocator };
    var arena_state = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const dir = sync_settings.defaultDir(a) catch {
        status.problem = .other;
        return status;
    };
    lockSettings();
    var loaded = sync_settings.load(a, dir);
    unlockSettings();
    var settings_value = (if (loaded) |*l| l.value else |_| sync_settings.Settings{});
    if (!settings_value.hasLocation()) {
        status.problem = .not_configured;
        return status;
    }

    var webdav: ?transport.WebDav = null;
    var folder: transport.Folder = .{ .root = expandHome(a, std.mem.trim(u8, settings_value.folder, " \t")) catch settings_value.folder };
    const t: transport.Transport = switch (settings_value.target) {
        .folder => folder.transport(),
        .webdav => blk: {
            const password: []const u8 = if (settings_value.password_sealed.len > 0)
                sync_settings.openLocal(a, settings_value.password_sealed) catch {
                    status.problem = .keychain;
                    return status;
                }
            else
                "";
            webdav = transport.WebDav.init(a, settings_value.url, settings_value.remote_folder, settings_value.username, password) catch {
                status.problem = .not_configured;
                return status;
            };
            break :blk webdav.?.transport();
        },
    };

    var passwords = kinds.Passwords{ .path = credential_store.path(a) catch "" };
    defer passwords.deinit();
    var ssh = kinds.LineFile{ .path = platform_dirs.sshHostsPath(a) catch "", .header = s.config.ssh_header, .cap = s.config.ssh_cap };
    var ai = kinds.LineFile{ .path = platform_dirs.aiProfilesPath(a) catch "", .header = s.config.ai_header, .cap = s.config.ai_cap };
    var history: ?kinds.History = if (s.config.history) |port| .{ .port = port } else null;
    var adapters: [engine.KIND_COUNT]?kinds.Adapter = @splat(null);
    if (passwords.path.len > 0) adapters[@intFromEnum(Kind.passwords)] = passwords.adapter();
    if (ssh.path.len > 0) adapters[@intFromEnum(Kind.ssh_hosts)] = ssh.adapter();
    if (ai.path.len > 0) adapters[@intFromEnum(Kind.ai_profiles)] = ai.adapter();
    if (history) |*h| adapters[@intFromEnum(Kind.history)] = h.adapter();

    var ctx = engine.Context{
        .arena = a,
        .state_dir = dir,
        .settings = &settings_value,
        .transport = t,
        .adapters = adapters,
        .passphrase = passphrase,
        .now = std.time.milliTimestamp(),
    };
    const report = engine.run(&ctx);

    if (report.settings_changed) persistKey(a, dir, settings_value);
    for (report.kinds, 0..) |k, i| {
        if (k.local_changed) _ = s.data_revision[i].fetchAdd(1, .release);
    }

    status.problem = report.firstProblem();
    if (report.problem == .none) {
        for (report.kinds, 0..) |k, i| {
            if (k.problem != .none and status.problem_kind == null) status.problem_kind = @enumFromInt(i);
        }
    }
    if (webdav) |*w| {
        status.http_status = w.last_status;
        w.deinit();
    }
    status.detail_len = report.detail_len;
    @memcpy(status.detail_buf[0..report.detail_len], report.detail());
    status.totals = report.totals();
    for (report.kinds, 0..) |k, i| status.items[i] = k.counts.items;
    return status;
}

/// `~` and `~/…` in a typed folder path mean the home directory.
fn expandHome(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, path, "~") and !std.mem.startsWith(u8, path, "~/") and !std.mem.startsWith(u8, path, "~\\")) return path;
    const home = try platform_dirs.homeDir(allocator);
    return std.fs.path.join(allocator, &.{ home, path[@min(path.len, 2)..] });
}

/// Store a newly derived key without clobbering edits the page made meanwhile.
fn persistKey(allocator: std.mem.Allocator, dir: []const u8, value: sync_settings.Settings) void {
    lockSettings();
    defer unlockSettings();
    var disk = sync_settings.load(allocator, dir) catch return;
    defer disk.deinit();
    // Forgotten while the run was in flight: do not resurrect the setup.
    if (!disk.value.hasLocation()) return;
    var merged = disk.value;
    merged.key_sealed = value.key_sealed;
    merged.key_salt = value.key_salt;
    sync_settings.save(allocator, dir, merged) catch |err| std.log.scoped(.sync).warn("saving sync key failed: {}", .{err});
}

/// What a window should toast after a run, if anything: always for "Sync Now",
/// otherwise only when another computer's changes arrived or a working sync
/// started failing.
pub const Notice = enum { none, synced, received, failed };

pub fn noticeFor(previous: Status, current: Status) Notice {
    if (current.running or !current.has_run or current.finished_at_ms == previous.finished_at_ms) return .none;
    if (current.problem != .none) {
        if (current.manual) return .failed;
        return if (previous.has_run and previous.problem == .none) .failed else .none;
    }
    if (current.manual) return .synced;
    return if (current.totals.pulled + current.totals.deleted_local > 0) .received else .none;
}

test "sync service notices: manual runs always toast, auto runs only on news" {
    const idle = Status{ .has_run = true, .finished_at_ms = 1, .revision = 1 };
    var manual = Status{ .has_run = true, .finished_at_ms = 2, .revision = 3, .manual = true };
    try std.testing.expectEqual(Notice.synced, noticeFor(idle, manual));
    manual.problem = .network;
    try std.testing.expectEqual(Notice.failed, noticeFor(idle, manual));

    var auto = Status{ .has_run = true, .finished_at_ms = 2, .revision = 3 };
    try std.testing.expectEqual(Notice.none, noticeFor(idle, auto));
    auto.totals.pulled = 2;
    try std.testing.expectEqual(Notice.received, noticeFor(idle, auto));
    auto.totals.pulled = 0;
    auto.problem = .network;
    try std.testing.expectEqual(Notice.failed, noticeFor(idle, auto));
    // Already failing: stay quiet.
    var failing = idle;
    failing.problem = .network;
    try std.testing.expectEqual(Notice.none, noticeFor(failing, auto));
    const running = Status{ .running = true, .revision = 9 };
    try std.testing.expectEqual(Notice.none, noticeFor(idle, running));
    try std.testing.expectEqual(Notice.none, noticeFor(auto, auto));
}

test "sync service expands a leading ~ in folder paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/data/WispTerm", try expandHome(a, "/data/WispTerm"));
    const expanded = try expandHome(a, "~/WispTerm");
    try std.testing.expect(!std.mem.startsWith(u8, expanded, "~"));
    try std.testing.expect(std.mem.endsWith(u8, expanded, "WispTerm"));
}

test "sync service worker compiles" {
    std.testing.refAllDecls(@This());
}
