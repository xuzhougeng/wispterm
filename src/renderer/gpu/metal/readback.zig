//! Metal framebuffer readback.
//!
//! Metal has no `glReadPixels`-style read of the live back buffer, and by the
//! time the agent ui_screenshot path calls this the drawable is already
//! presented and released (see `bridge.m` frame_end). So the capture is done
//! inside frame_end on armed frames: the rendered drawable is blitted into a
//! shared CPU buffer and the GPU is waited on. `readRgba` then crops that buffer
//! to the requested rect, converts BGRA8 -> RGBA8, and flips rows into the GL
//! bottom-up order the OpenGL backend's `readRgba` returns (AppWindow flips it
//! back to top-down for PNG, so both backends look identical to the caller).
const std = @import("std");

extern fn wispterm_metal_capture_pixels() ?[*]const u8;
extern fn wispterm_metal_capture_width() c_int;
extern fn wispterm_metal_capture_height() c_int;
extern fn wispterm_metal_capture_stride() c_int;

pub fn readRgba(allocator: std.mem.Allocator, x: i32, y: i32, width: u32, height: u32) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidReadbackRect;

    const src_ptr = wispterm_metal_capture_pixels() orelse return error.UnsupportedReadback;
    const img_w = std.math.cast(u32, wispterm_metal_capture_width()) orelse return error.UnsupportedReadback;
    const img_h = std.math.cast(u32, wispterm_metal_capture_height()) orelse return error.UnsupportedReadback;
    const stride = std.math.cast(usize, wispterm_metal_capture_stride()) orelse return error.UnsupportedReadback;
    if (img_w == 0 or img_h == 0 or stride == 0) return error.UnsupportedReadback;

    const pixels = std.math.mul(usize, width, height) catch return error.InvalidReadbackRect;
    const len = std.math.mul(usize, pixels, 4) catch return error.InvalidReadbackRect;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);

    const src = src_ptr[0 .. stride * img_h];
    try extractRgbaBottomUp(src, stride, img_w, img_h, x, y, width, height, out);
    return out;
}

/// Crop `src` (BGRA8, top-down, `stride` bytes/row, `img_w`x`img_h`) to the
/// `w`x`h` rect whose lower-left is at GL coords (`x`, `gl_y`) measured from the
/// image bottom, writing RGBA8 in GL bottom-up order into `out`. Pure so the
/// row-flip + channel-swap is unit-testable without a Metal device.
fn extractRgbaBottomUp(
    src: []const u8,
    stride: usize,
    img_w: u32,
    img_h: u32,
    x: i32,
    gl_y: i32,
    w: u32,
    h: u32,
    out: []u8,
) !void {
    if (x < 0 or gl_y < 0) return error.InvalidReadbackRect;
    const xu: u32 = @intCast(x);
    const yu: u32 = @intCast(gl_y);
    if (xu + w > img_w or yu + h > img_h) return error.InvalidReadbackRect;
    std.debug.assert(out.len == @as(usize, w) * @as(usize, h) * 4);

    var row: u32 = 0;
    while (row < h) : (row += 1) {
        // GL bottom-up row `row` -> top-down image row (origin top-left).
        const img_row = img_h - 1 - (yu + row);
        const src_row = src[@as(usize, img_row) * stride ..];
        const dst_row = out[@as(usize, row) * w * 4 ..];
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const s = src_row[@as(usize, xu + col) * 4 ..][0..4]; // BGRA
            const d = dst_row[@as(usize, col) * 4 ..][0..4];
            d[0] = s[2]; // R
            d[1] = s[1]; // G
            d[2] = s[0]; // B
            d[3] = s[3]; // A
        }
    }
}

test "extractRgbaBottomUp swaps BGRA->RGBA and flips to bottom-up" {
    // 2x2 BGRA top-down image, stride padded past the 8 used bytes.
    const stride: usize = 16;
    var src = [_]u8{0} ** (stride * 2);
    // top row:    left = B,G,R,A = 10,20,30,40 ; right = 11,21,31,41
    src[0..4].* = .{ 10, 20, 30, 40 };
    src[4..8].* = .{ 11, 21, 31, 41 };
    // bottom row: left = 12,22,32,42 ; right = 13,23,33,43
    src[stride + 0 .. stride + 4].* = .{ 12, 22, 32, 42 };
    src[stride + 4 .. stride + 8].* = .{ 13, 23, 33, 43 };

    var out: [2 * 2 * 4]u8 = undefined;
    try extractRgbaBottomUp(&src, stride, 2, 2, 0, 0, 2, 2, &out);

    // out row 0 = GL bottom row = image bottom row, RGBA (R,G,B,A from BGRA).
    try std.testing.expectEqualSlices(u8, &.{ 32, 22, 12, 42, 33, 23, 13, 43 }, out[0..8]);
    // out row 1 = image top row.
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10, 40, 31, 21, 11, 41 }, out[8..16]);
}

test "extractRgbaBottomUp rejects out-of-bounds rect" {
    var src = [_]u8{0} ** 16;
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidReadbackRect, extractRgbaBottomUp(&src, 8, 2, 2, 2, 0, 1, 1, &out));
    try std.testing.expectError(error.InvalidReadbackRect, extractRgbaBottomUp(&src, 8, 2, 2, 0, 2, 1, 1, &out));
    try std.testing.expectError(error.InvalidReadbackRect, extractRgbaBottomUp(&src, 8, 2, 2, -1, 0, 1, 1, &out));
}
