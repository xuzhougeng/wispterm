//! Metal framebuffer readback is not wired in v1.
const std = @import("std");

pub fn readRgba(allocator: std.mem.Allocator, x: i32, y: i32, width: u32, height: u32) ![]u8 {
    _ = allocator;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    return error.UnsupportedReadback;
}

test "metal readback reports unsupported" {
    try std.testing.expectError(error.UnsupportedReadback, readRgba(std.testing.allocator, 0, 0, 1, 1));
}
