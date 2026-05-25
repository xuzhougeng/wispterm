const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("config_watcher_windows.zig"),
    .unsupported => @import("config_watcher_unsupported.zig"),
};

pub const DirectoryWatcher = impl.DirectoryWatcher;

test "platform config watcher exposes directory watcher API" {
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(@TypeOf(DirectoryWatcher.initPath)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(DirectoryWatcher.hasChanged)).@"fn".return_type.? == bool);
    try std.testing.expect(@hasDecl(DirectoryWatcher, "deinit"));
}

test "platform config watcher selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
