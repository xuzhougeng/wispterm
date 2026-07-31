//! Optional desktop-shell registration for portable builds.

const std = @import("std");
const builtin = @import("builtin");

pub const Entry = enum { start_menu, startup };

const impl = switch (builtin.os.tag) {
    .windows => @import("shell_integration_windows.zig"),
    else => @import("shell_integration_unsupported.zig"),
};

pub const supported = builtin.os.tag == .windows;

pub fn isEnabled(allocator: std.mem.Allocator, entry: Entry) bool {
    return impl.isEnabled(allocator, entry);
}

pub fn setEnabled(allocator: std.mem.Allocator, entry: Entry, enabled: bool) !void {
    return impl.setEnabled(allocator, entry, enabled);
}

test "shell integration is available only on Windows" {
    try std.testing.expectEqual(builtin.os.tag == .windows, supported);
}
