//! Pure layout math for the full-page Settings tab.
//!
//! The page uses the same two-column structure as Codex settings: a compact
//! category rail on the left and a centered settings card on the right.

const std = @import("std");
const ui_patterns = @import("../ui_patterns.zig");

pub const Input = struct {
    window_height: f32,
    top_offset: f32,
    content_x: f32,
    content_width: f32,
    cell_height: f32,
    focus_index: usize,
    row_count: usize,
    category_count: usize,
};

pub const Rect = struct {
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and x < self.x + self.w and
            y >= self.top_px and y < self.top_px + self.h;
    }
};

pub const FontControl = enum { minus, plus };

pub const VisibleRow = struct {
    visible_index: usize,
    top_px: f32,
    gl_y: f32,
};

pub const Layout = struct {
    page_x: f32,
    page_top_px: f32,
    page_w: f32,
    page_h: f32,
    nav_w: f32,
    nav_item_top_px: f32,
    nav_item_h: f32,
    category_count: usize,
    content_x: f32,
    content_w: f32,
    row_top_px: f32,
    row_h: f32,
    visible_rows: usize,
    scroll: usize,
    row_count: usize,

    pub fn categoryAt(self: Layout, x: f32, y: f32) ?usize {
        const rect = Rect{
            .x = self.page_x + 14,
            .top_px = self.nav_item_top_px,
            .w = @max(1, self.nav_w - 28),
            .h = self.nav_item_h * @as(f32, @floatFromInt(self.category_count)),
        };
        if (!rect.contains(x, y)) return null;
        const idx: usize = @intFromFloat(@floor((y - rect.top_px) / self.nav_item_h));
        return if (idx < self.category_count) idx else null;
    }

    pub fn rowAt(self: Layout, x: f32, y: f32) ?usize {
        if (x < self.content_x or x >= self.content_x + self.content_w) return null;
        if (y < self.row_top_px) return null;
        const visible_index: usize = @intFromFloat(@floor((y - self.row_top_px) / self.row_h));
        if (visible_index >= self.visible_rows) return null;
        const row_index = visible_index + self.scroll;
        return if (row_index < self.row_count) row_index else null;
    }

    pub fn visibleRow(self: Layout, window_height: f32, row_index: usize) ?VisibleRow {
        if (row_index < self.scroll) return null;
        const visible_index = row_index - self.scroll;
        if (visible_index >= self.visible_rows) return null;
        const row_y = @round(@as(f32, @floatFromInt(visible_index)) * self.row_h);
        const top_px = self.row_top_px + row_y;
        return .{
            .visible_index = visible_index,
            .top_px = top_px,
            .gl_y = @round(window_height - top_px - self.row_h),
        };
    }

    pub fn fontControlAt(self: Layout, x: f32) ?FontControl {
        const plus_x = self.content_x + self.content_w - 48;
        const minus_x = plus_x - 42;
        if (x >= minus_x and x < minus_x + 30) return .minus;
        if (x >= plus_x and x < plus_x + 30) return .plus;
        return null;
    }

    pub fn focusVisible(self: Layout, focus_index: usize) bool {
        return focus_index >= self.scroll and focus_index < self.scroll + self.visible_rows;
    }
};

fn textHeight(cell_height: f32) f32 {
    return @max(1.0, cell_height);
}

pub fn settingsRowHeight(cell_height: f32) f32 {
    // Two full text lines (title + description) plus breathing room. The UI
    // font follows the configured terminal size, so a fixed 58px row overlaps
    // badly at larger, perfectly valid font sizes.
    return @round(@max(82.0, textHeight(cell_height) * 2.0 + 32.0));
}

pub fn rowCapacity(content_height: f32, base_h: f32, row_h: f32, row_count: usize) usize {
    if (row_count == 0) return 0;
    const usable_h = @max(row_h, content_height - base_h);
    const count: usize = @intFromFloat(@max(1.0, @floor(usable_h / row_h)));
    return @min(count, row_count);
}

pub fn firstVisibleRow(focus_index: usize, visible_rows: usize, row_count: usize) usize {
    if (visible_rows == 0 or row_count <= visible_rows) return 0;
    const focus = @min(focus_index, row_count - 1);
    if (focus < visible_rows) return 0;
    return @min(focus - visible_rows + 1, row_count - visible_rows);
}

pub fn compute(input: Input) Layout {
    const page_w = @max(1.0, input.content_width);
    const page_h = @max(1.0, input.window_height - input.top_offset);
    const min_nav_w: f32 = if (page_w < 640) 148.0 else 190.0;
    const nav_w = @round(@min(250.0, @max(min_nav_w, page_w * 0.23)));
    const main_w = @max(1.0, page_w - nav_w);
    const side_pad: f32 = if (main_w < 560) 20 else 44;
    const content_w = @max(1.0, @min(900.0, main_w - side_pad * 2));
    const content_x = @round(input.content_x + nav_w + @max(side_pad, (main_w - content_w) / 2));
    const row_h = settingsRowHeight(input.cell_height);
    const header_h = @round(@max(104.0, textHeight(input.cell_height) * 2.0 + 56.0));
    const bottom_pad: f32 = 24;
    // The footer is a persistent part of the Settings workbench, rather than
    // an overlay on the last row. Reserve its band here so short windows
    // scroll content above it instead of hiding the final control.
    const footer_h = ui_patterns.workbenchFooterHeight(input.cell_height);
    const content_h = @max(1.0, page_h - footer_h);
    const visible_rows = rowCapacity(content_h, header_h + bottom_pad, row_h, input.row_count);
    const scroll = firstVisibleRow(input.focus_index, visible_rows, input.row_count);

    return .{
        .page_x = input.content_x,
        .page_top_px = input.top_offset,
        .page_w = page_w,
        .page_h = page_h,
        .nav_w = nav_w,
        .nav_item_top_px = input.top_offset + 98,
        .nav_item_h = 42,
        .category_count = input.category_count,
        .content_x = content_x,
        .content_w = content_w,
        .row_top_px = input.top_offset + header_h,
        .row_h = row_h,
        .visible_rows = visible_rows,
        .scroll = scroll,
        .row_count = input.row_count,
    };
}

test "settings tab layout reserves a category rail and centered content" {
    const layout = compute(.{
        .window_height = 900,
        .top_offset = 40,
        .content_x = 220,
        .content_width = 1180,
        .cell_height = 20,
        .focus_index = 0,
        .row_count = 5,
        .category_count = 4,
    });

    try std.testing.expect(layout.nav_w >= 190);
    try std.testing.expect(layout.content_x >= layout.page_x + layout.nav_w);
    try std.testing.expect(layout.content_w <= 900);
    try std.testing.expectEqual(@as(?usize, 1), layout.categoryAt(layout.page_x + 20, layout.nav_item_top_px + layout.nav_item_h + 2));
}

test "settings tab layout keeps focused rows visible in short windows" {
    const layout = compute(.{
        .window_height = 330,
        .top_offset = 40,
        .content_x = 0,
        .content_width = 800,
        .cell_height = 20,
        .focus_index = 4,
        .row_count = 5,
        .category_count = 3,
    });

    try std.testing.expect(layout.visible_rows >= 1);
    try std.testing.expect(layout.visible_rows < layout.row_count);
    try std.testing.expect(layout.focusVisible(4));
    const last = layout.visibleRow(330, layout.scroll + layout.visible_rows - 1).?;
    try std.testing.expect(last.top_px + layout.row_h <= 330 - ui_patterns.workbenchFooterHeight(20));
}

test "settings tab hit testing maps content rows and font buttons" {
    const layout = compute(.{
        .window_height = 700,
        .top_offset = 40,
        .content_x = 180,
        .content_width = 900,
        .cell_height = 20,
        .focus_index = 0,
        .row_count = 5,
        .category_count = 3,
    });

    try std.testing.expectEqual(@as(?usize, 0), layout.rowAt(layout.content_x + 8, layout.row_top_px + 2));
    const plus_x = layout.content_x + layout.content_w - 46;
    try std.testing.expectEqual(FontControl.plus, layout.fontControlAt(plus_x).?);
}
