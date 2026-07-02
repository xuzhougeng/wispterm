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
pub const SIDEBAR_TAB_LIST_TOP_GAP: f32 = 6;
pub const SIDEBAR_TAB_TITLE_GAP: f32 = 8;
pub const SIDEBAR_TAB_RIGHT_GAP: f32 = 8;
pub const SIDEBAR_TAB_BELL_W: f32 = 20;
pub const SIDEBAR_TAB_BELL_GAP: f32 = 4;
pub const SIDEBAR_TAB_CLOSE_MARGIN: f32 = 4;
pub const SIDEBAR_TAB_CLOSE_HOVER_INSET_X: f32 = 6;
pub const SIDEBAR_TAB_CLOSE_HOVER_TOP_PAD: f32 = 10;
pub const SIDEBAR_TAB_CLOSE_HOVER_SIZE: f32 = 20;
pub const SIDEBAR_ACTIVE_MARKER_W: f32 = 3;
pub const SIDEBAR_ACTIVE_MARKER_VPAD: f32 = 6;

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

pub const SidebarHeaderLayout = struct {
    top_px: f32,
    y: f32,
    h: f32,
    title_x: f32,
    title_y: f32,
    title_max_w: f32,
    plus_x: f32,
    plus_y: f32,
    plus_w: f32,
    plus_h: f32,
    rule_y: f32,
};

pub fn sidebarHeaderLayout(
    window_height: f32,
    titlebar_h: f32,
    sidebar_w: f32,
    header_h: f32,
    title_x: f32,
    plus_w: f32,
    plus_margin: f32,
    titlebar_cell_h: f32,
) SidebarHeaderLayout {
    const y = window_height - titlebar_h - header_h;
    const plus_x = sidebar_w - plus_w - plus_margin;
    return .{
        .top_px = titlebar_h,
        .y = y,
        .h = header_h,
        .title_x = title_x,
        .title_y = y + (header_h - titlebar_cell_h) / 2,
        .title_max_w = @max(0.0, sidebar_w - plus_w - title_x - 12.0),
        .plus_x = plus_x,
        .plus_y = y,
        .plus_w = plus_w,
        .plus_h = header_h,
        .rule_y = y,
    };
}

pub const SidebarTabRowLayout = struct {
    row_top_px: f32,
    row_y: f32,
    row_h: f32,
    number_x: f32,
    number_w: f32,
    title_x: f32,
    title_max_w: f32,
    text_y: f32,
    close_x: f32,
    right_content_x: f32,
    badge_x: f32,
    badge_w: f32,
    bell_x: f32,
    bell_w: f32,
    active_marker_x: f32,
    active_marker_y: f32,
    active_marker_w: f32,
    active_marker_h: f32,
    close_hover_x: f32,
    close_hover_y: f32,
    close_hover_w: f32,
    close_hover_h: f32,
};

pub fn sidebarTabRowLayout(
    window_height: f32,
    titlebar_h: f32,
    header_h: f32,
    row_h_full: f32,
    sidebar_w: f32,
    tab_idx: usize,
    number_x: f32,
    number_w: f32,
    close_btn_w: f32,
    titlebar_cell_h: f32,
    show_agent_badge: bool,
    agent_badge_w: f32,
    show_bell: bool,
) ?SidebarTabRowLayout {
    const list_top_px = titlebar_h + header_h + SIDEBAR_TAB_LIST_TOP_GAP;
    const row_top_px = list_top_px + @as(f32, @floatFromInt(tab_idx)) * row_h_full;
    if (row_top_px >= window_height) return null;

    const row_h = @min(row_h_full, window_height - row_top_px);
    if (row_h <= 0) return null;

    const row_y = window_height - row_top_px - row_h;
    const close_x = sidebar_w - close_btn_w - SIDEBAR_TAB_CLOSE_MARGIN;
    var right_content_x = close_x - SIDEBAR_STATUS_CLOSE_GAP;
    var badge_x: f32 = 0;
    const badge_w = if (show_agent_badge) @max(0.0, agent_badge_w) else 0.0;
    if (show_agent_badge) {
        const badge = sidebarStatusBadgeLayout(close_x, badge_w);
        badge_x = badge.x;
        right_content_x = badge.next_right_content_x;
    }

    var bell_x: f32 = 0;
    const bell_w = if (show_bell) SIDEBAR_TAB_BELL_W else 0.0;
    if (show_bell) {
        bell_x = right_content_x - SIDEBAR_TAB_BELL_W;
        right_content_x = bell_x - SIDEBAR_TAB_BELL_GAP;
    }

    const title_x = number_x + number_w + SIDEBAR_TAB_TITLE_GAP;
    const marker_h = @max(0.0, row_h - SIDEBAR_ACTIVE_MARKER_VPAD * 2.0);
    return .{
        .row_top_px = row_top_px,
        .row_y = row_y,
        .row_h = row_h,
        .number_x = number_x,
        .number_w = number_w,
        .title_x = title_x,
        .title_max_w = @max(0.0, right_content_x - title_x - SIDEBAR_TAB_RIGHT_GAP),
        .text_y = row_y + (row_h - titlebar_cell_h) / 2.0,
        .close_x = close_x,
        .right_content_x = right_content_x,
        .badge_x = badge_x,
        .badge_w = badge_w,
        .bell_x = bell_x,
        .bell_w = bell_w,
        .active_marker_x = 0,
        .active_marker_y = row_y + SIDEBAR_ACTIVE_MARKER_VPAD,
        .active_marker_w = SIDEBAR_ACTIVE_MARKER_W,
        .active_marker_h = marker_h,
        .close_hover_x = close_x + SIDEBAR_TAB_CLOSE_HOVER_INSET_X,
        .close_hover_y = row_y + SIDEBAR_TAB_CLOSE_HOVER_TOP_PAD,
        .close_hover_w = SIDEBAR_TAB_CLOSE_HOVER_SIZE,
        .close_hover_h = SIDEBAR_TAB_CLOSE_HOVER_SIZE,
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

test "sidebarHeaderLayout computes header title and plus button geometry" {
    const l = sidebarHeaderLayout(820, 57, 220, 46, 14, 42, 6, 23);

    try std.testing.expectEqual(@as(f32, 57), l.top_px);
    try std.testing.expectEqual(@as(f32, 717), l.y);
    try std.testing.expectEqual(@as(f32, 46), l.h);
    try std.testing.expectEqual(@as(f32, 14), l.title_x);
    try std.testing.expectEqual(@as(f32, 728.5), l.title_y);
    try std.testing.expectEqual(@as(f32, 172), l.plus_x);
    try std.testing.expectEqual(@as(f32, 717), l.plus_y);
    try std.testing.expectEqual(@as(f32, 152), l.title_max_w);
    try std.testing.expectEqual(@as(f32, 717), l.rule_y);
}

test "sidebarTabRowLayout computes tab text and affordance slots" {
    const l = sidebarTabRowLayout(820, 57, 46, 45, 220, 1, 14, 28, 36, 23, true, 34, true).?;

    try std.testing.expectEqual(@as(f32, 154), l.row_top_px);
    try std.testing.expectEqual(@as(f32, 621), l.row_y);
    try std.testing.expectEqual(@as(f32, 45), l.row_h);
    try std.testing.expectEqual(@as(f32, 14), l.number_x);
    try std.testing.expectEqual(@as(f32, 28), l.number_w);
    try std.testing.expectEqual(@as(f32, 50), l.title_x);
    try std.testing.expectEqual(@as(f32, 180), l.close_x);
    try std.testing.expectEqual(@as(f32, 136), l.badge_x);
    try std.testing.expectEqual(@as(f32, 110), l.bell_x);
    try std.testing.expectEqual(@as(f32, 106), l.right_content_x);
    try std.testing.expectEqual(@as(f32, 48), l.title_max_w);
    try std.testing.expectEqual(@as(f32, 632), l.text_y);
    try std.testing.expectEqual(@as(f32, 627), l.active_marker_y);
    try std.testing.expectEqual(@as(f32, 33), l.active_marker_h);
    try std.testing.expectEqual(@as(f32, 186), l.close_hover_x);
    try std.testing.expectEqual(@as(f32, 631), l.close_hover_y);
}

test "sidebarTabRowLayout clips bottom row and reports offscreen rows" {
    const clipped = sidebarTabRowLayout(160, 30, 40, 32, 200, 2, 14, 24, 36, 18, false, 0, false).?;

    try std.testing.expectEqual(@as(f32, 140), clipped.row_top_px);
    try std.testing.expectEqual(@as(f32, 20), clipped.row_h);
    try std.testing.expectEqual(@as(f32, 0), clipped.row_y);
    try std.testing.expectEqual(@as(f32, 8), clipped.active_marker_h);

    try std.testing.expectEqual(
        @as(?SidebarTabRowLayout, null),
        sidebarTabRowLayout(160, 30, 40, 32, 200, 3, 14, 24, 36, 18, false, 0, false),
    );
}

test "sidebarTabRowLayout clamps title width in narrow sidebars" {
    const l = sidebarTabRowLayout(400, 40, 46, 42, 96, 0, 14, 30, 36, 20, true, 32, true).?;

    try std.testing.expectEqual(@as(f32, 52), l.title_x);
    try std.testing.expectEqual(@as(f32, 56), l.close_x);
    try std.testing.expectEqual(@as(f32, 14), l.badge_x);
    try std.testing.expectEqual(@as(f32, -12), l.bell_x);
    try std.testing.expectEqual(@as(f32, 0), l.title_max_w);
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
