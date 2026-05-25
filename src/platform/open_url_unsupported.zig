const std = @import("std");

pub fn open(allocator: std.mem.Allocator, request: anytype) bool {
    _ = allocator;
    _ = request;
    return false;
}
