//! Daily memory-digest scheduler (M2b, spec §12): decide once a local day
//! whether it's time to run the digest, then run it on a background thread
//! so the main loop never blocks on the LLM map/reduce network calls.
//!
//! `tick` is the only entry point the app main loop calls, every frame; it
//! self-throttles to a real check every 60s. All state here is module-level
//! and owned by this file alone (not part of session.zig's g_* guarded
//! group) since nothing else touches it.
const std = @import("std");
const atomic_file = @import("../platform/atomic_file.zig");
const ai_types = @import("../terminal_agents/sessions/types.zig");
const dirs = @import("../platform/dirs.zig");
const llm = @import("llm.zig");
const profile_codec = @import("../renderer/overlays/profile_codec.zig");
const profile_store = @import("../assistant/profile/store.zig");
const run_mod = @import("run.zig");
const sources_mod = @import("sources.zig");
const time_mod = @import("../terminal_agents/sessions/time.zig");
const window_backend = @import("../platform/window_backend.zig");

const TICK_INTERVAL_MS: i64 = 60_000;
const STARTUP_DELAY_MS: i64 = 5 * 60 * 1000;
const MAX_LAST_RUN_BYTES = 64 * 1024;
const UI_DETAIL_MAX = 96;

// ponytail: dev-only override so real-machine verification doesn't require
// waiting out the real 5-minute startup delay. Read once (cached) from
// WISPTERM_MEMORY_DIGEST_STARTUP_DELAY_MS; unset/invalid -> default 5min.
// Product default (STARTUP_DELAY_MS) is unchanged; do not rely on this for
// normal operation.
var g_startup_delay_ms: ?i64 = null;
fn startupDelayMs() i64 {
    if (g_startup_delay_ms) |v| return v;
    const v = readStartupDelayOverride();
    g_startup_delay_ms = v;
    return v;
}
fn readStartupDelayOverride() i64 {
    const env = std.process.getEnvVarOwned(std.heap.page_allocator, "WISPTERM_MEMORY_DIGEST_STARTUP_DELAY_MS") catch return STARTUP_DELAY_MS;
    defer std.heap.page_allocator.free(env);
    return std.fmt.parseInt(i64, env, 10) catch STARTUP_DELAY_MS;
}

pub const Settings = struct {
    enabled: bool = false,
    profile_name: []const u8 = "", // borrowed; updateSettings dupes it
    run_after: []const u8 = "04:00",
    scan_remote: bool = false,
    backfill_days: u32 = 7,
    max_chars: u32 = 2000,
};

pub const LastRun = struct {
    schema_version: u32 = 1,
    date_key: u32 = 0,
};

pub const ProgressStage = enum {
    idle,
    queued,
    scanning,
    summarizing,
    finalizing,
    success,
    failed,
    skipped,
};

pub const ProgressSnapshot = struct {
    seq: u64 = 0,
    visible: bool = false,
    stage: ProgressStage = .idle,
    sessions_total: u32 = 0,
    sessions_done: u32 = 0,
    sessions_failed: u32 = 0,
    days_written: u32 = 0,
    total_tokens: u64 = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    detail_len: usize = 0,
    detail_buf: [UI_DETAIL_MAX]u8 = [_]u8{0} ** UI_DETAIL_MAX,

    pub fn detail(self: *const ProgressSnapshot) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }
};

// ---- module state ----

var g_settings_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var g_settings: Settings = .{};
var g_thread: ?std.Thread = null;
var g_in_flight: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_last_tick_check_ms: i64 = 0;
var g_app_started_ms: ?i64 = null;
var g_shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_progress_mutex: std.Thread.Mutex = .{};
var g_progress: ProgressSnapshot = .{};
var g_progress_ctx: u8 = 0;

/// Loads a copy of `s`, duping the borrowed strings into the module's own
/// arena. Call on the main thread whenever config is loaded/hot-reloaded.
pub fn updateSettings(s: Settings) void {
    g_settings_arena.deinit();
    g_settings_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = g_settings_arena.allocator();
    g_settings = .{
        .enabled = s.enabled,
        .profile_name = alloc.dupe(u8, s.profile_name) catch "",
        .run_after = alloc.dupe(u8, s.run_after) catch "04:00",
        .scan_remote = s.scan_remote,
        .backfill_days = s.backfill_days,
        .max_chars = s.max_chars,
    };
    // tick() silently `orelse return`s on a malformed run_after every 60s;
    // warn once here (config-load time) instead of spamming that silence.
    if (s.run_after.len > 0 and parseRunAfterMinutes(s.run_after) == null) {
        std.log.warn("memory_digest: invalid run_after \"{s}\", scheduler will not run until it is fixed", .{s.run_after});
    }
}

/// Main-loop tick. Self-throttles: only actually checks once per
/// TICK_INTERVAL_MS. Cheap to call every frame.
pub fn tick(gpa: std.mem.Allocator) void {
    const now_ms = std.time.milliTimestamp();
    if (g_app_started_ms == null) g_app_started_ms = now_ms;

    if (!g_settings.enabled) return;
    if (now_ms - g_last_tick_check_ms < TICK_INTERVAL_MS) return;
    g_last_tick_check_ms = now_ms;

    if (g_in_flight.load(.acquire)) return;

    // Join a previous run's thread handle before possibly starting a new one.
    if (g_thread) |t| {
        t.join();
        g_thread = null;
    }

    const run_after_minutes = parseRunAfterMinutes(g_settings.run_after) orelse return;

    const memory_root = dirs.memoryDir(gpa) catch return;
    defer gpa.free(memory_root);
    const last_run_path = std.fs.path.join(gpa, &.{ memory_root, "state", "last_run.json" }) catch return;
    defer gpa.free(last_run_path);

    const last_run = loadLastRun(gpa, last_run_path);
    const tz_offset_seconds = time_mod.localOffsetSeconds();

    if (!shouldRun(now_ms, tz_offset_seconds, run_after_minutes, last_run.date_key, g_app_started_ms.?)) return;

    spawnRun(gpa, now_ms, tz_offset_seconds, false);
}

/// Manually trigger a digest run right now, bypassing the enabled/date/
/// time-of-day/startup-delay gates in `shouldRun` (a manual trigger is an
/// explicit user request, not a scheduled decision). Still respects the
/// in_flight guard: if a run is already in progress, this is a no-op.
pub fn runNow(gpa: std.mem.Allocator) void {
    if (g_in_flight.load(.acquire)) {
        std.log.info("memory_digest: runNow skipped, a run is already in progress", .{});
        setProgress(.skipped, true, .{ .detail = "Memory digest already running" });
        return;
    }

    if (g_thread) |t| {
        t.join();
        g_thread = null;
    }

    const now_ms = std.time.milliTimestamp();
    const tz_offset_seconds = time_mod.localOffsetSeconds();
    spawnRun(gpa, now_ms, tz_offset_seconds, true);
}

pub fn progressSnapshot() ProgressSnapshot {
    g_progress_mutex.lock();
    defer g_progress_mutex.unlock();
    return g_progress;
}

/// Shared spawn path for both the scheduled tick and the manual runNow
/// trigger: sets in_flight, builds thread params from current settings, and
/// spawns runThreadMain. Caller must already hold the in_flight/join guards.
/// `manual` distinguishes an explicit runNow from a scheduled tick: a manual
/// run with no profile configured must not consume today's scheduled slot.
fn spawnRun(gpa: std.mem.Allocator, now_ms: i64, tz_offset_seconds: i32, manual: bool) void {
    g_in_flight.store(true, .release);
    if (manual) setProgress(.queued, true, .{ .detail = "Queued" });
    const params = ThreadParams{
        .profile_name = gpa.dupe(u8, g_settings.profile_name) catch {
            g_in_flight.store(false, .release);
            return;
        },
        .backfill_days = g_settings.backfill_days,
        .max_chars = g_settings.max_chars,
        .now_ms = now_ms,
        .tz_offset_seconds = tz_offset_seconds,
        .scan_remote = g_settings.scan_remote,
        .manual = manual,
    };
    g_thread = std.Thread.spawn(.{}, runThreadMain, .{ gpa, params }) catch {
        gpa.free(params.profile_name);
        g_in_flight.store(false, .release);
        return;
    };
}

/// App shutdown: join the background thread if one is running. `fetch` has
/// no timeout, so a run can be stuck mid-request on a half-open connection;
/// joining unconditionally would hang app exit. If a run is still in flight,
/// detach instead of joining -- writes go through atomic_file, so the worst
/// case is losing the in-progress run's record, not a corrupt one. Proper
/// LLM-call timeouts are M5.
pub fn deinit() void {
    g_shutting_down.store(true, .release);
    if (g_thread) |t| {
        if (g_in_flight.load(.acquire)) {
            t.detach();
        } else {
            t.join();
        }
        g_thread = null;
    }
    g_settings_arena.deinit();
}

/// "HH:MM" (H:0-23, M:0-59, 1-2 digit fields) -> minutes since local midnight.
/// Anything else (empty, wrong shape, out-of-range, non-digits) -> null.
pub fn parseRunAfterMinutes(s: []const u8) ?u16 {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const hour_str = s[0..colon];
    const min_str = s[colon + 1 ..];
    if (hour_str.len == 0 or hour_str.len > 2) return null;
    if (min_str.len == 0 or min_str.len > 2) return null;
    if (std.mem.indexOfScalar(u8, min_str, ':') != null) return null;

    const hour = std.fmt.parseInt(u16, hour_str, 10) catch return null;
    const minute = std.fmt.parseInt(u16, min_str, 10) catch return null;
    if (hour > 23 or minute > 59) return null;
    return hour * 60 + minute;
}

/// Pure decision: run today's digest iff (a) we have not already run today
/// (local date), (b) local wall-clock has passed run_after, and (c) the app
/// has been up at least 5 minutes (avoid competing with startup I/O).
pub fn shouldRun(now_ms: i64, tz_offset_seconds: i32, run_after_minutes: u16, last_run_date_key: u32, app_started_ms: i64) bool {
    if (now_ms - app_started_ms < startupDelayMs()) return false;

    const today_key = ai_types.dateKeyFromMs(now_ms, tz_offset_seconds);
    if (today_key == last_run_date_key) return false;

    const local_secs = @divFloor(now_ms, 1000) + tz_offset_seconds;
    const secs_into_day = @mod(local_secs, 86_400);
    const minutes_into_day: u16 = @intCast(@divFloor(secs_into_day, 60));
    return minutes_into_day >= run_after_minutes;
}

pub fn loadLastRun(gpa: std.mem.Allocator, path: []const u8) LastRun {
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, MAX_LAST_RUN_BYTES) catch return .{};
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(LastRun, gpa, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return .{};
    defer parsed.deinit();
    return parsed.value;
}

pub fn saveLastRun(gpa: std.mem.Allocator, path: []const u8, v: LastRun) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, v, .{});
    defer gpa.free(json);
    try atomic_file.writeFileReplaceSafe(path, json);
}

// ---- background thread ----

const ThreadParams = struct {
    profile_name: []const u8, // gpa-owned; freed by runThreadMain
    backfill_days: u32,
    max_chars: u32,
    now_ms: i64,
    tz_offset_seconds: i32,
    scan_remote: bool = false,
    /// True for an explicit runNow trigger, false for a scheduled tick. A
    /// manual run with no profile configured must not consume today's
    /// scheduled slot (see runThreadMain's no-profile branch).
    manual: bool = false,
};

fn runThreadMain(gpa: std.mem.Allocator, params: ThreadParams) void {
    defer gpa.free(params.profile_name);
    defer {
        g_in_flight.store(false, .release);
        // If deinit() detached this thread on the way out, the window/backend
        // it would wake may already be torn down -- don't touch it.
        if (!g_shutting_down.load(.acquire)) window_backend.postWakeup();
    }

    // Profiles are large fixed-buffer records (~98KB each); heap-allocate
    // rather than putting them on a thread stack (mirrors scan_main.zig).
    const profiles = gpa.alloc(profile_codec.AiProfile, 16) catch return;
    defer gpa.free(profiles);
    const profile_count = profile_store.loadProfiles(gpa, profiles);

    const idx = llm.pickProfile(profiles, profile_count, params.profile_name) orelse {
        // No AI profile configured: an automatic background digest with no
        // LLM isn't useful (unlike the dev CLI's --raw fallback), so skip
        // the run entirely.
        if (params.manual) {
            // A manual runNow with no profile isn't "today's scheduled run" --
            // don't mark today done, or the real scheduled run would be
            // skipped later once a profile is configured.
            std.log.warn("memory_digest: runNow skipped, no AI profile configured", .{});
            setProgress(.skipped, true, .{ .detail = "Configure memory-digest-profile first" });
        } else {
            // Still record today as "done" so tick doesn't retry every 60s
            // and spam this warning until a profile is added.
            std.log.warn("memory_digest: scheduler skipping run, no AI profile configured", .{});
            markRanToday(gpa, params.now_ms, params.tz_offset_seconds);
        }
        return;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = llm.configFromProfile(arena, &profiles[idx]) catch |err| {
        std.log.warn("memory_digest: scheduler failed to build LLM config: {s}", .{@errorName(err)});
        if (params.manual) setProgress(.failed, true, .{ .detail = "Failed to load AI profile" });
        return;
    };
    var client: llm.Client = .{ .config = cfg };

    const local_roots = run_mod.defaultLocalRoots(gpa) catch |err| {
        std.log.warn("memory_digest: scheduler failed to resolve local roots: {s}", .{@errorName(err)});
        if (params.manual) setProgress(.failed, true, .{ .detail = "Failed to resolve local history roots" });
        return;
    };
    defer local_roots.deinit(gpa);

    const memory_root = dirs.memoryDir(gpa) catch |err| {
        std.log.warn("memory_digest: scheduler failed to resolve memory dir: {s}", .{@errorName(err)});
        if (params.manual) setProgress(.failed, true, .{ .detail = "Failed to resolve memory output dir" });
        return;
    };
    defer gpa.free(memory_root);

    var remote_sources: []const run_mod.RemoteSource = &.{};
    if (params.scan_remote) {
        const ssh_sources = sources_mod.loadSshSources(gpa, arena) catch |err| blk: {
            std.log.warn("memory_digest: scheduler failed to load ssh sources: {s}", .{@errorName(err)});
            break :blk &.{};
        };
        const wsl_sources = sources_mod.loadWslSources(arena) catch |err| blk: {
            std.log.warn("memory_digest: scheduler failed to load wsl sources: {s}", .{@errorName(err)});
            break :blk &.{};
        };
        remote_sources = std.mem.concat(arena, run_mod.RemoteSource, &.{ ssh_sources, wsl_sources }) catch &.{};
    }

    const progress_sink: ?run_mod.ProgressSink = if (params.manual)
        .{ .ctx = @ptrCast(&g_progress_ctx), .onProgressFn = onRunProgress }
    else
        null;

    const summary = run_mod.runOnce(gpa, .{
        .roots = local_roots.roots(),
        .memory_root = memory_root,
        .now_ms = params.now_ms,
        .tz_offset_seconds = params.tz_offset_seconds,
        .backfill_days = params.backfill_days,
        .max_chars_per_message = params.max_chars,
        .completer = client.completer(),
        .model_label = cfg.model,
        .remote_sources = remote_sources,
        .llm_usage = &client.total_usage,
        .progress_sink = progress_sink,
    }) catch |err| {
        // ponytail: no saveLastRun here — the 60s tick throttle naturally
        // retries later today. M3's runs.json will own richer retry/backoff
        // bookkeeping; until then "just try again next tick" is enough.
        std.log.warn("memory_digest: scheduler run failed: {s}", .{@errorName(err)});
        if (params.manual) setProgress(.failed, true, .{ .detail = "Digest run failed" });
        return;
    };

    std.log.info(
        "memory_digest: scheduler run ok, {d} sessions, {d} days, {d} summarized, {d} failed, {d} tokens ({d} prompt + {d} completion)",
        .{
            summary.sessions_collected,
            summary.days_written,
            summary.sessions_summarized,
            summary.sessions_failed,
            client.total_usage.total_tokens,
            client.total_usage.prompt_tokens,
            client.total_usage.completion_tokens,
        },
    );
    if (params.manual) {
        setProgress(.success, true, .{
            .sessions_total = @intCast(summary.sessions_collected),
            .sessions_done = @intCast(summary.sessions_summarized),
            .sessions_failed = @intCast(summary.sessions_failed),
            .days_written = @intCast(summary.days_written),
            .total_tokens = client.total_usage.total_tokens,
            .prompt_tokens = client.total_usage.prompt_tokens,
            .completion_tokens = client.total_usage.completion_tokens,
            .detail = "Complete",
        });
    }
    markRanToday(gpa, params.now_ms, params.tz_offset_seconds);
}

const ProgressUpdate = struct {
    detail: []const u8 = "",
    sessions_total: u32 = 0,
    sessions_done: u32 = 0,
    sessions_failed: u32 = 0,
    days_written: u32 = 0,
    total_tokens: u64 = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
};

fn setProgress(stage: ProgressStage, visible: bool, update: ProgressUpdate) void {
    g_progress_mutex.lock();
    defer g_progress_mutex.unlock();

    g_progress.seq +%= 1;
    g_progress.visible = visible;
    g_progress.stage = stage;
    g_progress.sessions_total = update.sessions_total;
    g_progress.sessions_done = update.sessions_done;
    g_progress.sessions_failed = update.sessions_failed;
    g_progress.days_written = update.days_written;
    g_progress.total_tokens = update.total_tokens;
    g_progress.prompt_tokens = update.prompt_tokens;
    g_progress.completion_tokens = update.completion_tokens;
    g_progress.detail_len = copyTruncated(&g_progress.detail_buf, update.detail);
}

fn copyTruncated(dst: []u8, src: []const u8) usize {
    const len = @min(dst.len, src.len);
    if (len > 0) @memcpy(dst[0..len], src[0..len]);
    return len;
}

fn onRunProgress(ctx: *anyopaque, progress: run_mod.Progress) void {
    _ = ctx;
    switch (progress) {
        .scanning => setProgress(.scanning, true, .{ .detail = "Scanning chat logs" }),
        .summarizing => |v| setProgress(.summarizing, true, .{
            .detail = if (v.detail.len != 0) v.detail else "Summarizing sessions",
            .sessions_total = @intCast(v.total),
            .sessions_done = @intCast(v.completed),
            .sessions_failed = @intCast(v.failed),
        }),
        .finalizing => setProgress(.finalizing, true, .{ .detail = "Writing digest files" }),
    }
}

fn markRanToday(gpa: std.mem.Allocator, now_ms: i64, tz_offset_seconds: i32) void {
    const memory_root = dirs.memoryDir(gpa) catch return;
    defer gpa.free(memory_root);
    const state_dir = std.fs.path.join(gpa, &.{ memory_root, "state" }) catch return;
    defer gpa.free(state_dir);
    std.fs.cwd().makePath(state_dir) catch {};
    const path = std.fs.path.join(gpa, &.{ state_dir, "last_run.json" }) catch return;
    defer gpa.free(path);

    const date_key = ai_types.dateKeyFromMs(now_ms, tz_offset_seconds);
    saveLastRun(gpa, path, .{ .date_key = date_key }) catch |err| {
        std.log.warn("memory_digest: scheduler failed to save last_run.json: {s}", .{@errorName(err)});
    };
}

// ---- tests: pure decision functions only; runThreadMain is not unit tested ----
//
// ponytail: no test calls tick/runNow/spawnRun themselves (same as the
// pre-existing tick, which no test here calls either). A `zig test` build
// eagerly codegens everything reachable from an executed test body, and that
// chain runs through std.Thread.spawn(runThreadMain) -> window_backend
// .postWakeup() -> the macOS window backend module, whose extern fns are
// only linked into the full app / macOS UI test binaries, not this fast
// cross-platform suite (see src/test_fast.zig's "no App.zig/AppWindow.zig"
// comment) -- verified locally: adding such a test breaks `zig build test`
// with 29 undefined _wispterm_macos_window_* linker errors, while the
// current in_flight-guard-first-line behavior for both tick and runNow is
// otherwise identical and already covered by reading the source directly.
// If this needs real coverage later, test it via test-full's macOS-only
// app test binary instead of the fast suite.

test "memory_digest_scheduler: parseRunAfterMinutes accepts HH:MM" {
    try std.testing.expectEqual(@as(?u16, 240), parseRunAfterMinutes("04:00"));
    try std.testing.expectEqual(@as(?u16, 0), parseRunAfterMinutes("00:00"));
    try std.testing.expectEqual(@as(?u16, 23 * 60 + 59), parseRunAfterMinutes("23:59"));
    try std.testing.expectEqual(@as(?u16, 5), parseRunAfterMinutes("0:5"));
    try std.testing.expectEqual(@as(?u16, 9 * 60 + 5), parseRunAfterMinutes("9:05"));
}

test "memory_digest_scheduler: parseRunAfterMinutes rejects malformed input" {
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes(""));
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes("25:00"));
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes("04:60"));
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes("aa:bb"));
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes("0400"));
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes("04:"));
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes(":00"));
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes("100:00"));
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes("04:00:00"));
    try std.testing.expectEqual(@as(?u16, null), parseRunAfterMinutes("-1:00"));
}

test "memory_digest_scheduler: shouldRun four quadrants" {
    // 2026-06-01 05:00:00 local (UTC, tz=0). Local midnight epoch: 1780272000.
    const local_0500_ms: i64 = 1780272000 * 1000 + 5 * 3600 * 1000;
    const app_started_long_ago = local_0500_ms - 10 * 60 * 1000; // 10 min uptime, past 5-min gate
    const app_started_recent = local_0500_ms - 1 * 60 * 1000; // 1 min uptime, before 5-min gate
    const run_after_0400: u16 = 240; // 04:00

    // Already ran today -> false regardless of time-of-day / uptime.
    try std.testing.expect(!shouldRun(local_0500_ms, 0, run_after_0400, 20260601, app_started_long_ago));

    // Not yet past run_after (it's 03:00 local, run_after is 04:00) -> false.
    const local_0300_ms: i64 = 1780272000 * 1000 + 3 * 3600 * 1000;
    try std.testing.expect(!shouldRun(local_0300_ms, 0, run_after_0400, 20260531, app_started_long_ago));

    // Past run_after, new day, but app started <5min ago -> false.
    try std.testing.expect(!shouldRun(local_0500_ms, 0, run_after_0400, 20260531, app_started_recent));

    // Past run_after, new day, app up >=5min -> true.
    try std.testing.expect(shouldRun(local_0500_ms, 0, run_after_0400, 20260531, app_started_long_ago));

    // Exactly at the 5-minute boundary counts as satisfied.
    const app_started_exact = local_0500_ms - 5 * 60 * 1000;
    try std.testing.expect(shouldRun(local_0500_ms, 0, run_after_0400, 20260531, app_started_exact));
}

test "memory_digest_scheduler: LastRun save/load roundtrip and corrupt-file fallback" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const path = try std.fs.path.join(allocator, &.{ dir_path, "last_run.json" });
    defer allocator.free(path);

    // Missing file -> zero value.
    const missing = loadLastRun(allocator, path);
    try std.testing.expectEqual(@as(u32, 0), missing.date_key);

    try saveLastRun(allocator, path, .{ .date_key = 20260601 });
    const loaded = loadLastRun(allocator, path);
    try std.testing.expectEqual(@as(u32, 1), loaded.schema_version);
    try std.testing.expectEqual(@as(u32, 20260601), loaded.date_key);

    // Corrupt file -> empty default, not an error.
    try tmp.dir.writeFile(.{ .sub_path = "last_run.json", .data = "{\"schema_version\":1,\"date_k" });
    const corrupt = loadLastRun(allocator, path);
    try std.testing.expectEqual(@as(u32, 0), corrupt.date_key);
}
