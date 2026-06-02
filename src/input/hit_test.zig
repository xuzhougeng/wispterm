//! Pure sidebar hit-test geometry, extracted from input.zig. Callers gather the
//! current layout into a SidebarLayout and ask which region a point hits. No
//! globals here — the math is std-only and unit-testable.
const std = @import("std");

pub const SidebarLayout = struct {
    visible: bool,
    titlebar_h: f64,
    width: f64, // titlebar.sidebarWidth()
    header_h: f64, // titlebar.sidebarHeaderHeight()
    row_h: f64, // titlebar.sidebarRowHeight()
    tab_count: usize,
    resize_hit_width: f64, // titlebar.SIDEBAR_RESIZE_HIT_WIDTH
    close_btn_w: f64, // tab.TAB_CLOSE_BTN_W
};

pub const PANEL_HEADER_CLOSE_BTN_W: f64 = 32;
pub const PANEL_HEADER_CLOSE_MARGIN: f64 = 6;

pub const PanelHeaderLayout = struct {
    visible: bool,
    left: f64,
    right: f64,
    top: f64,
    height: f64,
    close_btn_w: f64 = PANEL_HEADER_CLOSE_BTN_W,
    close_margin: f64 = PANEL_HEADER_CLOSE_MARGIN,
};

pub const Rect = struct {
    left: f64,
    top: f64,
    width: f64,
    height: f64,
};

fn listTop(l: SidebarLayout) f64 {
    return l.titlebar_h + l.header_h + 6;
}

/// Which tab row a point falls on, or null if outside the tab list.
pub fn sidebarTabAt(l: SidebarLayout, x: f64, y: f64) ?usize {
    if (!l.visible) return null;
    if (x < 0 or x >= l.width) return null;
    const top = listTop(l);
    if (y < top) return null;
    const idx_f = (y - top) / l.row_h;
    const idx: usize = @intFromFloat(@floor(idx_f));
    if (idx >= l.tab_count) return null;
    return idx;
}

/// Drag-target row for a given y: clamps to [0, tab_count-1] instead of
/// returning null, so a drag above/below the list snaps to the ends.
pub fn sidebarTabIndexForDragY(l: SidebarLayout, y: f64) ?usize {
    if (!l.visible or l.tab_count == 0) return null;
    const top = listTop(l);
    if (y < top) return 0;
    const idx_f = (y - top) / l.row_h;
    const idx_raw: usize = @intFromFloat(@floor(idx_f));
    if (idx_raw >= l.tab_count) return l.tab_count - 1;
    return idx_raw;
}

/// True if (x, y) falls within the + (new-tab) button in the sidebar header.
pub fn sidebarPlusButton(l: SidebarLayout, x: f64, y: f64) bool {
    if (!l.visible) return false;
    const plus_w: f64 = 42;
    const plus_x = l.width - plus_w - 6;
    return x >= plus_x and x < plus_x + plus_w and
        y >= l.titlebar_h and y < l.titlebar_h + l.header_h;
}

/// True if (x, y) is over the close button of the given tab row, and the
/// sidebar has more than one tab (close is suppressed on the last tab).
pub fn sidebarTabCloseButton(l: SidebarLayout, x: f64, y: f64, tab_idx: usize) bool {
    if (!l.visible or tab_idx >= l.tab_count or l.tab_count <= 1) return false;
    const row = sidebarTabAt(l, x, y) orelse return false;
    if (row != tab_idx) return false;
    const close_x = l.width - l.close_btn_w - 4;
    return x >= close_x and x < close_x + l.close_btn_w;
}

/// True if (x, y) is within the horizontal resize-hit band around the sidebar
/// right edge and below the titlebar.
pub fn sidebarResizeHandle(l: SidebarLayout, x: f64, y: f64) bool {
    if (!l.visible) return false;
    if (y < l.titlebar_h) return false;
    const half_hit = l.resize_hit_width / 2;
    return x >= l.width - half_hit and x <= l.width + half_hit;
}

pub fn panelHeaderCloseButton(l: PanelHeaderLayout, x: f64, y: f64) bool {
    const rect = panelCloseButtonRect(l) orelse return false;
    return x >= rect.left and x < rect.left + rect.width and
        y >= rect.top and y < rect.top + rect.height;
}

pub fn panelCloseButtonRect(l: PanelHeaderLayout) ?Rect {
    if (!l.visible) return null;
    if (l.right <= l.left or l.height <= 0) return null;
    if (l.close_btn_w <= 0 or l.close_margin < 0) return null;
    if ((l.right - l.left) <= l.close_btn_w + l.close_margin) return null;

    return .{
        .left = l.right - l.close_margin - l.close_btn_w,
        .top = l.top,
        .width = l.close_btn_w,
        .height = l.height,
    };
}

const sample: SidebarLayout = .{
    .visible = true,
    .titlebar_h = 30,
    .width = 200,
    .header_h = 40,
    .row_h = 28,
    .tab_count = 3,
    .resize_hit_width = 8,
    .close_btn_w = 36,
};

test "sidebarTabAt: invisible sidebar never hits" {
    var l = sample;
    l.visible = false;
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(l, 10, 100));
}

test "sidebarTabAt: row math and bounds" {
    // list_top = 30 + 40 + 6 = 76; row_h = 28
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(sample, 10, 75)); // above list
    try std.testing.expectEqual(@as(?usize, 0), sidebarTabAt(sample, 10, 76)); // first row top
    try std.testing.expectEqual(@as(?usize, 0), sidebarTabAt(sample, 10, 103)); // still row 0
    try std.testing.expectEqual(@as(?usize, 1), sidebarTabAt(sample, 10, 104)); // row 1
    try std.testing.expectEqual(@as(?usize, 2), sidebarTabAt(sample, 10, 132)); // row 2 (last)
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(sample, 10, 160)); // past tab_count
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(sample, 200, 100)); // x == width (outside)
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(sample, -1, 100)); // x < 0
}

test "sidebarTabIndexForDragY: clamps to ends" {
    try std.testing.expectEqual(@as(?usize, 0), sidebarTabIndexForDragY(sample, 0)); // above -> 0
    try std.testing.expectEqual(@as(?usize, 2), sidebarTabIndexForDragY(sample, 9999)); // below -> last
    try std.testing.expectEqual(@as(?usize, 1), sidebarTabIndexForDragY(sample, 104));
    var empty = sample;
    empty.tab_count = 0;
    try std.testing.expectEqual(@as(?usize, null), sidebarTabIndexForDragY(empty, 100));
}

test "sidebarPlusButton: top-right header box" {
    // plus_x = 200 - 42 - 6 = 152; spans x in [152, 194); y in [30, 70)
    try std.testing.expect(sidebarPlusButton(sample, 160, 50));
    try std.testing.expect(!sidebarPlusButton(sample, 151, 50)); // left of box
    try std.testing.expect(!sidebarPlusButton(sample, 160, 70)); // y == header bottom (outside)
}

test "sidebarTabCloseButton: only on its own hovered row, needs >1 tab" {
    // close_x = 200 - 36 - 4 = 160; spans [160, 196); row 0 spans y in [76, 104)
    try std.testing.expect(sidebarTabCloseButton(sample, 170, 80, 0));
    try std.testing.expect(!sidebarTabCloseButton(sample, 100, 80, 0)); // left of close box
    try std.testing.expect(!sidebarTabCloseButton(sample, 170, 80, 1)); // hovering row 0, asking row 1
    var one = sample;
    one.tab_count = 1;
    try std.testing.expect(!sidebarTabCloseButton(one, 170, 80, 0)); // single tab: no close
}

test "sidebarResizeHandle: band around the right edge" {
    // half_hit = 4; band x in [196, 204]; needs y >= titlebar_h (30)
    try std.testing.expect(sidebarResizeHandle(sample, 200, 100));
    try std.testing.expect(sidebarResizeHandle(sample, 196, 100));
    try std.testing.expect(sidebarResizeHandle(sample, 204, 100));
    try std.testing.expect(!sidebarResizeHandle(sample, 195, 100)); // left of band
    try std.testing.expect(!sidebarResizeHandle(sample, 200, 20)); // above titlebar
}

const sample_panel: PanelHeaderLayout = .{
    .visible = true,
    .left = 220,
    .right = 420,
    .top = 40,
    .height = 38,
    .close_btn_w = 32,
    .close_margin = 6,
};

test "panelHeaderCloseButton: hits the right-aligned header close button" {
    // close_x = 420 - 6 - 32 = 382; spans [382, 414); y in [40, 78)
    try std.testing.expect(panelHeaderCloseButton(sample_panel, 390, 50));
    try std.testing.expect(panelHeaderCloseButton(sample_panel, 413, 77));
    try std.testing.expect(!panelHeaderCloseButton(sample_panel, 381, 50)); // left of button
    try std.testing.expect(!panelHeaderCloseButton(sample_panel, 414, 50)); // margin before resize edge
    try std.testing.expect(!panelHeaderCloseButton(sample_panel, 390, 78)); // below header
}

test "panelHeaderCloseButton: invisible or collapsed panels never hit" {
    var hidden = sample_panel;
    hidden.visible = false;
    try std.testing.expect(!panelHeaderCloseButton(hidden, 390, 50));

    var collapsed = sample_panel;
    collapsed.right = collapsed.left + collapsed.close_btn_w;
    try std.testing.expect(!panelHeaderCloseButton(collapsed, 390, 50));
}

test "panelCloseButtonRect: returns a reusable right-aligned rect" {
    const rect = panelCloseButtonRect(sample_panel).?;
    try std.testing.expectEqual(@as(f64, 382), rect.left);
    try std.testing.expectEqual(@as(f64, 40), rect.top);
    try std.testing.expectEqual(@as(f64, 32), rect.width);
    try std.testing.expectEqual(@as(f64, 38), rect.height);

    var collapsed = sample_panel;
    collapsed.right = collapsed.left + collapsed.close_btn_w;
    try std.testing.expectEqual(@as(?Rect, null), panelCloseButtonRect(collapsed));
}
