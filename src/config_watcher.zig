/// Watches the config file directory for changes.
///
/// The app layer resolves Phantty's config path. The platform layer owns the
/// OS-specific directory notification backend.
const std = @import("std");
const Config = @import("config.zig");
const platform_config_watcher = @import("platform/config_watcher.zig");

const ConfigWatcher = @This();

watcher: platform_config_watcher.DirectoryWatcher,

/// Open the config directory and start watching for changes.
pub fn init(allocator: std.mem.Allocator) ?ConfigWatcher {
    const path = Config.configFilePath(allocator) catch |err| {
        std.debug.print("ConfigWatcher: failed to get config path: {}\n", .{err});
        return null;
    };
    defer allocator.free(path);

    const dir_path = std.fs.path.dirname(path) orelse {
        std.debug.print("ConfigWatcher: failed to get directory from path\n", .{});
        return null;
    };

    const watcher = platform_config_watcher.DirectoryWatcher.initPath(dir_path) orelse return null;
    std.debug.print("ConfigWatcher: watching {s}\n", .{dir_path});
    return .{ .watcher = watcher };
}

/// Non-blocking check: has the config directory changed?
pub fn hasChanged(self: *ConfigWatcher) bool {
    return self.watcher.hasChanged();
}

pub fn deinit(self: *ConfigWatcher) void {
    self.watcher.deinit();
}

test "config watcher wraps platform directory watcher" {
    try std.testing.expect(@hasDecl(ConfigWatcher, "init"));
    try std.testing.expect(@hasDecl(ConfigWatcher, "hasChanged"));
    try std.testing.expect(@hasDecl(ConfigWatcher, "deinit"));
}
