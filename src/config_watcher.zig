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
pub fn hasChanged(self: *ConfigWatcher) bool {
    _ = self.watcher.hasChanged();
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

fn optionalMtimeEql(a: ?i128, b: ?i128) bool {
    if (a) |av| {
        if (b) |bv| return av == bv;
        return false;
    }
    return b == null;
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
