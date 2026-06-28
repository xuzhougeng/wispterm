//! Pure helpers for active-tab UI screenshot capture.
const std = @import("std");
const destination_policy = struct {
    const DEFAULT_DIR = "wispterm-files";

    fn isSafeDestinationName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
        for (name) |ch| {
            if (ch == '/' or ch == '\\' or ch == ':') return false;
        }
        return true;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const max_output_long_edge: u32 = 1920;

pub const RgbaImage = struct {
    width: u32,
    height: u32,
    rgba: []const u8,
    owned: bool = false,

    pub fn deinit(self: RgbaImage, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.rgba);
    }
};

fn rgbaLen(width: u32, height: u32) !usize {
    if (width == 0 or height == 0) return error.InvalidImageDimensions;
    const pixels = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.InvalidImageDimensions;
    return std.math.mul(usize, pixels, 4) catch return error.InvalidImageDimensions;
}

pub fn fitRgbaToMaxLongEdge(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
    max_long_edge: u32,
) !RgbaImage {
    if (rgba.len != try rgbaLen(width, height)) return error.InvalidImageBuffer;
    if (max_long_edge == 0) return error.InvalidImageDimensions;

    const long_edge = @max(width, height);
    if (long_edge <= max_long_edge) {
        return .{ .width = width, .height = height, .rgba = rgba };
    }

    var out_w = width;
    var out_h = height;
    if (width >= height) {
        out_w = max_long_edge;
        out_h = @max(1, @as(u32, @intCast((@as(u64, height) * max_long_edge + width / 2) / width)));
    } else {
        out_h = max_long_edge;
        out_w = @max(1, @as(u32, @intCast((@as(u64, width) * max_long_edge + height / 2) / height)));
    }

    const out = try allocator.alloc(u8, try rgbaLen(out_w, out_h));
    errdefer allocator.free(out);

    for (0..out_h) |dst_y| {
        const src_y = @as(u32, @intCast((@as(u64, dst_y) * height) / out_h));
        for (0..out_w) |dst_x| {
            const src_x = @as(u32, @intCast((@as(u64, dst_x) * width) / out_w));
            const src = (@as(usize, src_y) * width + src_x) * 4;
            const dst = (@as(usize, dst_y) * out_w + dst_x) * 4;
            @memcpy(out[dst .. dst + 4], rgba[src .. src + 4]);
        }
    }

    return .{ .width = out_w, .height = out_h, .rgba = out, .owned = true };
}

pub fn clampRect(rect: Rect, fb_width: u32, fb_height: u32) ?Rect {
    if (rect.width == 0 or rect.height == 0 or fb_width == 0 or fb_height == 0) return null;
    const x0 = @max(@as(i64, rect.x), 0);
    const y0 = @max(@as(i64, rect.y), 0);
    const x1 = @min(@as(i64, rect.x) + @as(i64, rect.width), @as(i64, fb_width));
    const y1 = @min(@as(i64, rect.y) + @as(i64, rect.height), @as(i64, fb_height));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .width = @intCast(x1 - x0),
        .height = @intCast(y1 - y0),
    };
}

/// Converts a clamped top-left rect to OpenGL readback Y.
pub fn glReadY(rect: Rect, fb_height: u32) i32 {
    const y = @as(i64, fb_height) - @as(i64, rect.y) - @as(i64, rect.height);
    return @intCast(std.math.clamp(y, 0, std.math.maxInt(i32)));
}

pub fn outputPath(allocator: std.mem.Allocator, working_dir: []const u8, now_ms: i64) ![]u8 {
    if (working_dir.len == 0) return error.MissingWorkingDir;
    const name = try std.fmt.allocPrint(allocator, "ui-screenshot-{d}.png", .{now_ms});
    defer allocator.free(name);
    if (!destination_policy.isSafeDestinationName(name)) return error.UnsafeDestinationName;
    const dir = try std.fs.path.join(allocator, &.{ working_dir, destination_policy.DEFAULT_DIR });
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, name });
}

test "ui_screenshot clamps rectangles to framebuffer bounds" {
    const r = clampRect(.{ .x = -5, .y = 10, .width = 20, .height = 20 }, 100, 100).?;
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 10), r.y);
    try std.testing.expectEqual(@as(u32, 15), r.width);
    try std.testing.expectEqual(@as(u32, 20), r.height);
    try std.testing.expect(clampRect(.{ .x = 200, .y = 0, .width = 10, .height = 10 }, 100, 100) == null);
}

test "ui_screenshot rejects empty framebuffer or rect" {
    try std.testing.expect(clampRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, 0, 1) == null);
    try std.testing.expect(clampRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, 1, 0) == null);
    try std.testing.expect(clampRect(.{ .x = 0, .y = 0, .width = 0, .height = 1 }, 1, 1) == null);
    try std.testing.expect(clampRect(.{ .x = 0, .y = 0, .width = 1, .height = 0 }, 1, 1) == null);
}

test "ui_screenshot clips right and bottom edges" {
    const r = clampRect(.{ .x = 80, .y = 70, .width = 50, .height = 50 }, 100, 100).?;
    try std.testing.expectEqual(@as(i32, 80), r.x);
    try std.testing.expectEqual(@as(i32, 70), r.y);
    try std.testing.expectEqual(@as(u32, 20), r.width);
    try std.testing.expectEqual(@as(u32, 30), r.height);
}

test "ui_screenshot rejects fully above or left rectangles" {
    try std.testing.expect(clampRect(.{ .x = -20, .y = 0, .width = 10, .height = 10 }, 100, 100) == null);
    try std.testing.expect(clampRect(.{ .x = 0, .y = -20, .width = 10, .height = 10 }, 100, 100) == null);
}

test "ui_screenshot handles very large bounds without trapping" {
    const clipped = clampRect(.{
        .x = std.math.maxInt(i32) - 1,
        .y = 0,
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
    }, std.math.maxInt(u32), std.math.maxInt(u32)).?;
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32) - 1), clipped.x);
    try std.testing.expectEqual(@as(i32, 0), clipped.y);
    try std.testing.expectEqual(@as(u32, 2_147_483_649), clipped.width);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), clipped.height);

    try std.testing.expect(clampRect(.{
        .x = std.math.maxInt(i32),
        .y = 0,
        .width = std.math.maxInt(u32),
        .height = 1,
    }, 1, 1) == null);
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), glReadY(.{ .x = 0, .y = -1, .width = 1, .height = 0 }, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(i32, 0), glReadY(.{ .x = 0, .y = 10, .width = 1, .height = std.math.maxInt(u32) }, 1));
}

test "ui_screenshot converts top-left rect y to OpenGL read y" {
    const r = Rect{ .x = 10, .y = 20, .width = 30, .height = 40 };
    try std.testing.expectEqual(@as(i32, 40), glReadY(r, 100));
}

test "ui_screenshot output path uses wispterm-files and a png basename" {
    const path = try outputPath(std.testing.allocator, "/work/project", 1234);
    defer std.testing.allocator.free(path);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ "/work/project", destination_policy.DEFAULT_DIR, "ui-screenshot-1234.png" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "ui_screenshot output path rejects empty working dir" {
    try std.testing.expectError(error.MissingWorkingDir, outputPath(std.testing.allocator, "", 1234));
}

test "ui_screenshot downscales 4k rgba to 1080p long-edge cap" {
    var rgba = [_]u8{
        1, 1, 1, 255, 2, 2, 2, 255, 3, 3, 3, 255, 4, 4, 4, 255,
        5, 5, 5, 255, 6, 6, 6, 255, 7, 7, 7, 255, 8, 8, 8, 255,
    };

    const image = try fitRgbaToMaxLongEdge(std.testing.allocator, &rgba, 4, 2, 2);
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        1, 1, 1, 255, 3, 3, 3, 255,
    }, image.rgba);
}
