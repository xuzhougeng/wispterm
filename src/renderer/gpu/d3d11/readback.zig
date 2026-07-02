//! D3D11 readback is a Phase III item.

const std = @import("std");

pub fn readRgba(allocator: std.mem.Allocator, x: i32, y: i32, width: u32, height: u32) ![]u8 {
    _ = allocator;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    return error.D3D11ReadbackNotImplemented;
}
