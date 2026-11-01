/// Watches the config file directory for changes.
///
/// The app layer resolves WispTerm's config path. The platform layer owns the
/// OS-specific directory notification backend.
const std = @import("std");
const Config = @import("config.zig");
const platform_config_watcher = @import("platform/config_watcher.zig");

const ConfigWatcher = @This();

watcher: platform_config_watcher.DirectoryWatcher,
allocator: std.mem.Allocator,
config_path: []const u8,
last_mtime: ?i128,
/// Last time the config file was stat'ed (ms). See `hasChanged`.
last_stat_ms: i64 = 0,
/// Minimum spacing between mtime stats when the directory watcher reported
/// nothing. Tests set this to 0 to observe an in-place rewrite immediately.
stat_interval_ms: i64 = STAT_INTERVAL_MS,

/// The main loop calls `hasChanged` on every wake (>= 10 Hz while focused,
/// see `appwindow/render_gate.zig`). Stat'ing the config file that often is
/// pure idle CPU: the reload itself is debounced by `CONFIG_DEBOUNCE_MS`
/// anyway, so a one-second stat cadence adds at most a second of latency.
/// Ghostty has no auto-reload at all (`reload_config` keybind only).
pub const STAT_INTERVAL_MS: i64 = 1000;

/// Open the config directory and start watching for changes.
pub fn init(allocator: std.mem.Allocator) ?ConfigWatcher {
    const path = Config.configFilePath(allocator) catch |err| {
        std.debug.print("ConfigWatcher: failed to get config path: {}\n", .{err});
        return null;
    };
    return initForPath(allocator, path);
}

/// Watch the directory containing `config_path`. Takes ownership of `config_path`
/// (freed on failure or in `deinit`). Split out from `init` so tests can point the
/// watcher at a temporary file instead of the resolved user config path.
pub fn initForPath(allocator: std.mem.Allocator, config_path: []const u8) ?ConfigWatcher {
    const dir_path = std.fs.path.dirname(config_path) orelse {
        std.debug.print("ConfigWatcher: failed to get directory from path\n", .{});
        allocator.free(config_path);
        return null;
    };

    const watcher = platform_config_watcher.DirectoryWatcher.initPath(dir_path) orelse {
        allocator.free(config_path);
        return null;
    };
    std.debug.print("ConfigWatcher: watching {s}\n", .{dir_path});
    return .{
        .watcher = watcher,
        .allocator = allocator,
        .config_path = config_path,
        .last_mtime = configMtime(config_path),
    };
}

/// Non-blocking check: has the config file changed?
///
/// mtime is the source of truth. The platform directory watcher is only drained
/// to keep its event queue armed; its result is intentionally NOT used as a gate.
/// On macOS a kqueue registered on the *directory* vnode does not fire when an
/// existing file is rewritten in place (same inode) — which is exactly how the
/// Settings page (`Config.setConfigValue`) and most editors save the config. So
/// gating on the event would miss every in-place edit and force an app restart
/// to pick up changes (the Windows `ReadDirectoryChangesW` backend fires on
/// last-write/size, which is why this only manifested on macOS).
///
/// The stat is throttled to `stat_interval_ms` unless the directory watcher
/// did report an event (create / rename / delete land there and should be
/// picked up at once).
pub fn hasChanged(self: *ConfigWatcher) bool {
    const dir_event = self.watcher.hasChanged();
    const now = std.time.milliTimestamp();
    if (!shouldStat(dir_event, now, self.last_stat_ms, self.stat_interval_ms)) return false;
    self.last_stat_ms = now;
    const next_mtime = configMtime(self.config_path);
    if (optionalMtimeEql(self.last_mtime, next_mtime)) return false;
    self.last_mtime = next_mtime;
    return true;
}

pub fn deinit(self: *ConfigWatcher) void {
    self.watcher.deinit();
    self.allocator.free(self.config_path);
}

fn configMtime(path: []const u8) ?i128 {
    const stat = std.fs.cwd().statFile(path) catch return null;
    return stat.mtime;
}

/// Pure decision for `hasChanged`: stat on a directory event, or once the
/// throttle interval since the last stat has elapsed.
fn shouldStat(dir_event: bool, now_ms: i64, last_stat_ms: i64, interval_ms: i64) bool {
    if (dir_event) return true;
    return now_ms - last_stat_ms >= interval_ms;
}

fn optionalMtimeEql(a: ?i128, b: ?i128) bool {
    if (a) |av| {
        if (b) |bv| return av == bv;
        return false;
    }
    return b == null;
}

test "config watcher throttles the mtime stat unless the directory reported an event" {
    // Quiet directory: stat only once per interval.
    try std.testing.expect(!shouldStat(false, 999, 0, STAT_INTERVAL_MS));
    try std.testing.expect(shouldStat(false, 1000, 0, STAT_INTERVAL_MS));
    try std.testing.expect(shouldStat(false, 1500, 500, STAT_INTERVAL_MS));
    // A directory event (create/rename/delete) bypasses the throttle.
    try std.testing.expect(shouldStat(true, 1, 0, STAT_INTERVAL_MS));
    // Interval 0 (tests) stats every call.
    try std.testing.expect(shouldStat(false, 5, 5, 0));
}

test "config watcher wraps platform directory watcher" {
    try std.testing.expect(@hasDecl(ConfigWatcher, "init"));
    try std.testing.expect(@hasDecl(ConfigWatcher, "hasChanged"));
    try std.testing.expect(@hasDecl(ConfigWatcher, "deinit"));
}

// Regression for the macOS "config changes need a restart" bug: a kqueue on the
// directory vnode does not fire for an in-place truncate-rewrite of an existing
// file, so detection must fall back to mtime. This rewrites the SAME inode,
// exactly like `Config.setConfigValue`, and asserts the change is observed.
test "config watcher detects in-place rewrite of existing config file" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("config", .{});
        try f.writeAll("font-size = 16\n");
        f.close();
    }

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    // initForPath takes ownership of this slice (frees it on failure or in deinit).
    const file_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config" });

    var watcher = ConfigWatcher.initForPath(testing.allocator, file_path) orelse {
        // Platform without a directory-watch backend (e.g. Linux): nothing to test.
        return error.SkipZigTest;
    };
    defer watcher.deinit();
    // The stat throttle would otherwise hide a rewrite made within a second.
    watcher.stat_interval_ms = 0;

    try testing.expect(!watcher.hasChanged());

    // Advance mtime, then truncate-rewrite the SAME file in place.
    std.Thread.sleep(20 * std.time.ns_per_ms);
    {
        const f = try tmp.dir.createFile("config", .{ .truncate = true });
        try f.writeAll("font-size = 24\n");
        f.close();
    }

    try testing.expect(watcher.hasChanged());
    try testing.expect(!watcher.hasChanged());
}
