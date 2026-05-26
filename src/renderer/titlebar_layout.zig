//! Pure, std-only titlebar/sidebar geometry + measurement helpers extracted
//! from titlebar.zig. No AppWindow/font/GL imports — runs in the fast suite.
const std = @import("std");

/// Is point (px, py) inside the rect [left, left+width) x [top, top+height)?
pub fn pointInRect(px: f32, py: f32, left: f32, top: f32, width: f32, height: f32) bool {
    return px >= left and px < left + width and py >= top and py < top + height;
}

/// Linear blend of two RGB colors; t clamped to [0,1].
pub fn blend(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

/// Max sidebar width for a window: min(max_width, window_width - min_content_width),
/// but never below min_width (so a too-narrow window still yields min_width).
pub fn sidebarMaxWidthForWindow(window_width: f32, min_width: f32, max_width: f32, min_content_width: f32) f32 {
    return @max(min_width, @min(max_width, window_width - min_content_width));
}

/// Clamp a requested sidebar width to [min_width, max_for_window].
/// Args follow std.math.clamp order: (value, min, max).
pub fn clampSidebarWidth(width: f32, min_width: f32, max_for_window: f32) f32 {
    return @max(min_width, @min(max_for_window, width));
}

/// Printable-ASCII passthrough, else '?'.
pub fn fallbackCodepoint(byte: u8) u32 {
    return if (byte >= 0x20 and byte <= 0x7e) byte else '?';
}

test "pointInRect inside / edges / outside" {
    try std.testing.expect(pointInRect(5, 5, 0, 0, 10, 10));
    try std.testing.expect(pointInRect(0, 0, 0, 0, 10, 10)); // top-left inclusive
    try std.testing.expect(!pointInRect(10, 5, 0, 0, 10, 10)); // right exclusive
    try std.testing.expect(!pointInRect(5, 10, 0, 0, 10, 10)); // bottom exclusive
    try std.testing.expect(!pointInRect(-1, 5, 0, 0, 10, 10));
}

test "blend endpoints and midpoint" {
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 1, 1, 1 };
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, blend(a, b, 0));
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, blend(a, b, 1));
    try std.testing.expectEqual([3]f32{ 0.5, 0.5, 0.5 }, blend(a, b, 0.5));
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, blend(a, b, 2)); // t clamped
}

test "sidebarMaxWidthForWindow respects bounds" {
    try std.testing.expectEqual(@as(f32, 720), sidebarMaxWidthForWindow(2000, 160, 720, 240));
    try std.testing.expectEqual(@as(f32, 360), sidebarMaxWidthForWindow(600, 160, 720, 240));
    try std.testing.expectEqual(@as(f32, 160), sidebarMaxWidthForWindow(300, 160, 720, 240));
}

test "clampSidebarWidth bounds" {
    // args: (width, min_width, max_for_window)
    try std.testing.expectEqual(@as(f32, 160), clampSidebarWidth(50, 160, 720));
    try std.testing.expectEqual(@as(f32, 720), clampSidebarWidth(900, 160, 720));
    try std.testing.expectEqual(@as(f32, 300), clampSidebarWidth(300, 160, 720));
}

test "fallbackCodepoint maps printable ASCII, else '?'" {
    try std.testing.expectEqual(@as(u32, 'A'), fallbackCodepoint('A'));
    try std.testing.expectEqual(@as(u32, 0x20), fallbackCodepoint(0x20)); // space — inclusive low bound
    try std.testing.expectEqual(@as(u32, 0x7e), fallbackCodepoint(0x7e)); // '~' — inclusive high bound
    try std.testing.expectEqual(@as(u32, '?'), fallbackCodepoint(0x1f)); // just below
    try std.testing.expectEqual(@as(u32, '?'), fallbackCodepoint(0x7f)); // just above
    try std.testing.expectEqual(@as(u32, '?'), fallbackCodepoint(0x07));
    try std.testing.expectEqual(@as(u32, '?'), fallbackCodepoint(0xC3));
}
