const std = @import("std");
const Entry = @import("shell_integration.zig").Entry;

pub fn isEnabled(_: std.mem.Allocator, _: Entry) bool {
    return false;
}

pub fn setEnabled(_: std.mem.Allocator, _: Entry, _: bool) !void {
    return error.Unsupported;
}
