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

pub const SIDEBAR_STATUS_CLOSE_GAP: f32 = 10;
pub const SIDEBAR_STATUS_LEADING_GAP: f32 = 6;

pub const SidebarStatusBadgeLayout = struct {
    x: f32,
    next_right_content_x: f32,
};

pub fn sidebarStatusBadgeLayout(close_btn_x: f32, badge_w: f32) SidebarStatusBadgeLayout {
    const x = close_btn_x - SIDEBAR_STATUS_CLOSE_GAP - badge_w;
    return .{
        .x = x,
        .next_right_content_x = x - SIDEBAR_STATUS_LEADING_GAP,
    };
}

/// Printable-ASCII passthrough, else '?'.
pub fn fallbackCodepoint(byte: u8) u32 {
    return if (byte >= 0x20 and byte <= 0x7e) byte else '?';
}

pub const TopBarLayout = struct {
    top_y: f32,
    toggle_x: f32,
    caption_button_w: f32,
    caption_start_x: f32,
    config_x: f32,
    help_x: f32,
    copilot_x: f32,
    title_text_x: f32,
    title_text_max_w: f32,
};

/// Window-top chrome geometry for the app-drawn titlebar.
///
/// The renderer consumes this in framebuffer coordinates, with Y=0 at the
/// bottom. Width arguments may be zero on platforms where those controls are
/// hosted outside WispTerm's titlebar.
pub fn topBarLayout(
    window_width: f32,
    window_height: f32,
    titlebar_h: f32,
    left_reserved: f32,
    toggle_w: f32,
    config_w: f32,
    help_w: f32,
    copilot_w: f32,
    caption_button_w: f32,
) TopBarLayout {
    const caption_area_w = caption_button_w * 3.0;
    const caption_start_x = window_width - caption_area_w;
    const config_x = caption_start_x - config_w;
    const help_x = config_x - help_w;
    const copilot_x = help_x - copilot_w;
    const title_text_x = left_reserved + toggle_w + 10.0;
    return .{
        .top_y = window_height - titlebar_h,
        .toggle_x = left_reserved,
        .caption_button_w = caption_button_w,
        .caption_start_x = caption_start_x,
        .config_x = config_x,
        .help_x = help_x,
        .copilot_x = copilot_x,
        .title_text_x = title_text_x,
        .title_text_max_w = @max(0.0, copilot_x - title_text_x - 12.0),
    };
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

test "sidebar status badge leaves readable gap before close button" {
    const close_btn_x: f32 = 184;
    const badge_w: f32 = 34;
    const layout = sidebarStatusBadgeLayout(close_btn_x, badge_w);

    try std.testing.expectEqual(@as(f32, 10), close_btn_x - (layout.x + badge_w));
    try std.testing.expectEqual(@as(f32, close_btn_x - 10 - badge_w - 6), layout.next_right_content_x);
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

test "topBarLayout computes titlebar chrome rectangles" {
    const l = topBarLayout(1200, 800, 34, 0, 46, 46, 46, 46, 46);

    try std.testing.expectEqual(@as(f32, 766), l.top_y);
    try std.testing.expectEqual(@as(f32, 0), l.toggle_x);
    try std.testing.expectEqual(@as(f32, 46), l.caption_button_w);
    try std.testing.expectEqual(@as(f32, 1062), l.caption_start_x);
    try std.testing.expectEqual(@as(f32, 1016), l.config_x);
    try std.testing.expectEqual(@as(f32, 970), l.help_x);
    try std.testing.expectEqual(@as(f32, 924), l.copilot_x);
    try std.testing.expectEqual(@as(f32, 56), l.title_text_x);
    try std.testing.expectEqual(@as(f32, 856), l.title_text_max_w);
}

test "topBarLayout collapses optional titlebar controls cleanly" {
    const l = topBarLayout(360, 240, 40, 160, 46, 0, 0, 0, 46);

    try std.testing.expectEqual(@as(f32, 200), l.top_y);
    try std.testing.expectEqual(@as(f32, 160), l.toggle_x);
    try std.testing.expectEqual(@as(f32, 222), l.caption_start_x);
    try std.testing.expectEqual(@as(f32, 222), l.config_x);
    try std.testing.expectEqual(@as(f32, 222), l.help_x);
    try std.testing.expectEqual(@as(f32, 222), l.copilot_x);
    try std.testing.expectEqual(@as(f32, 216), l.title_text_x);
    try std.testing.expectEqual(@as(f32, 0), l.title_text_max_w);
}
