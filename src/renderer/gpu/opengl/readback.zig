//! OpenGL framebuffer readback helpers.
const std = @import("std");
const Context = @import("Context.zig");
const c = @import("c.zig").c;

pub fn readRgba(allocator: std.mem.Allocator, x: i32, y: i32, width: u32, height: u32) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidReadbackRect;
    const gl_width = std.math.cast(c.GLsizei, width) orelse return error.InvalidReadbackRect;
    const gl_height = std.math.cast(c.GLsizei, height) orelse return error.InvalidReadbackRect;
    const pixels = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.InvalidReadbackRect;
    const len = std.math.mul(usize, pixels, 4) catch return error.InvalidReadbackRect;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    const gl = Context.gl;
    gl.PixelStorei.?(c.GL_PACK_ALIGNMENT, 1);
    gl.ReadPixels.?(
        x,
        y,
        gl_width,
        gl_height,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        out.ptr,
    );
    return out;
}

test "readRgba rejects invalid rectangles before GL access" {
    const max_glsizei = std.math.cast(u32, std.math.maxInt(c.GLsizei)) orelse return error.SkipZigTest;
    if (max_glsizei == std.math.maxInt(u32)) return error.SkipZigTest;
    const too_large = max_glsizei + 1;

    try std.testing.expectError(error.InvalidReadbackRect, readRgba(std.testing.allocator, 0, 0, 0, 1));
    try std.testing.expectError(error.InvalidReadbackRect, readRgba(std.testing.allocator, 0, 0, 1, 0));
    try std.testing.expectError(error.InvalidReadbackRect, readRgba(std.testing.allocator, 0, 0, too_large, 1));
    try std.testing.expectError(error.InvalidReadbackRect, readRgba(std.testing.allocator, 0, 0, 1, too_large));
}
