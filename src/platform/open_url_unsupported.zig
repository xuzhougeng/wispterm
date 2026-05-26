const std = @import("std");

pub fn open(allocator: std.mem.Allocator, request: anytype) bool {
    _ = allocator;
    _ = request;
    return false;
}

pub fn reveal(allocator: std.mem.Allocator, path: []const u8) bool {
    _ = allocator;
    _ = path;
    return false;
}
