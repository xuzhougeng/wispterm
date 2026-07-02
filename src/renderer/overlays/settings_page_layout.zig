//! Pure layout math for the settings page overlay.
//!
//! The settings page state owns focus/config mutation and overlays.zig owns
//! drawing. This module only computes panel geometry, visible-row scroll, and
//! hit-test bands from viewport/font inputs.

const std = @import("std");

pub const Input = struct {
    window_width: f32,
    window_height: f32,
    top_offset: f32,
    cell_height: f32,
    focus: usize,
    row_count: usize,
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

pub const FontControl = enum {
    minus,
    plus,
};

pub const VisibleRow = struct {
    visible_index: usize,
    top_px: f32,
    gl_y: f32,
};

/// Computed geometry for the settings page, in top-down client pixels.
pub const Layout = struct {
    box_x: f32,
    box_top_px: f32,
    box_w: f32,
    box_h: f32,
    header_h: f32,
    footer_h: f32,
    row_top_px: f32,
    row_h: f32,
    /// Number of rows that fit in the box for the current window height.
    visible_rows: usize,
    /// Index of the first rendered row (scroll offset).
    scroll: usize,
    row_count: usize,

    pub fn containsPoint(self: Layout, x: f32, y: f32) bool {
        return x >= self.box_x and x <= self.box_x + self.box_w and
            y >= self.box_top_px and y <= self.box_top_px + self.box_h;
    }

    pub fn closeRect(self: Layout) Rect {
        return .{
            .x = self.box_x + self.box_w - 62,
            .top_px = self.box_top_px + 18,
            .w = 44,
            .h = 28,
        };
    }

    pub fn hitClose(self: Layout, x: f32, y: f32) bool {
        return self.closeRect().contains(x, y);
    }

    pub fn rowAt(self: Layout, x: f32, y: f32) ?usize {
        if (x < self.box_x + 18 or x > self.box_x + self.box_w - 18) return null;
        if (y < self.row_top_px) return null;
        const visible_index: usize = @intFromFloat(@floor((y - self.row_top_px) / self.row_h));
        if (visible_index >= self.visible_rows) return null;
        const row = visible_index + self.scroll;
        if (row >= self.row_count) return null;
        return row;
    }

    pub fn visibleRow(self: Layout, window_height: f32, row: usize) ?VisibleRow {
        if (row < self.scroll) return null;
        const visible_index = row - self.scroll;
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
        const plus_x = self.box_x + self.box_w - 70;
        const minus_x = plus_x - 42;
        if (x >= minus_x and x < minus_x + 30) return .minus;
        if (x >= plus_x and x < plus_x + 30) return .plus;
        return null;
    }

    pub fn focusVisible(self: Layout, focus: usize) bool {
        return focus >= self.scroll and focus < self.scroll + self.visible_rows;
    }
};

/// Text height for an overlay line, derived from the font cell height.
/// Mirrors overlays.overlayTextHeight().
fn textHeight(cell_height: f32) f32 {
    return @max(1.0, cell_height);
}

/// Mirrors overlays.overlayLineHeight().
fn lineHeight(cell_height: f32) f32 {
    return @round(@max(24.0, textHeight(cell_height) + 8.0));
}

/// Mirrors overlays.overlayRowHeight().
fn rowHeight(cell_height: f32, min_h: f32) f32 {
    return @round(@max(min_h, textHeight(cell_height) + 14.0));
}

/// Mirrors overlays.clampOverlayBoxHeight().
fn clampBoxHeight(box_h: f32, content_height: f32) f32 {
    return @max(1.0, @min(box_h, content_height - 32.0));
}

pub fn headerHeight(cell_height: f32) f32 {
    return @round(18.0 + lineHeight(cell_height) * 2.0 + 12.0);
}

pub fn footerHeight(cell_height: f32) f32 {
    return @round(@max(52.0, textHeight(cell_height) + 28.0));
}

pub fn settingsRowHeight(cell_height: f32) f32 {
    return rowHeight(cell_height, 42.0);
}

/// Number of settings rows that fit within the box for the given window height,
/// leaving room for the header and footer. Mirrors commandPaletteRowCapacity().
pub fn rowCapacity(content_height: f32, base_h: f32, row_h: f32, row_count: usize) usize {
    if (row_count == 0) return 0;
    const usable_h = @max(row_h, content_height - 32.0 - base_h);
    if (usable_h <= row_h) return 1;
    const count_f = @floor(usable_h / row_h);
    const count: usize = @intFromFloat(@max(1.0, count_f));
    return @min(count, row_count);
}

/// First row to render so the focused row stays visible (scroll offset).
pub fn firstVisibleRow(focus_in: usize, visible_rows: usize, row_count: usize) usize {
    if (visible_rows == 0 or row_count <= visible_rows) return 0;
    const focus = @min(focus_in, row_count - 1);
    if (focus < visible_rows) return 0;
    return @min(focus - visible_rows + 1, row_count - visible_rows);
}

pub fn compute(input: Input) Layout {
    const content_height = @max(1.0, input.window_height - input.top_offset);
    const box_w = @round(@min(@max(420.0, input.window_width - 48.0), 760.0));
    const row_h = settingsRowHeight(input.cell_height);
    const header_h = headerHeight(input.cell_height);
    const footer_h = footerHeight(input.cell_height);
    const visible_rows = rowCapacity(content_height, header_h + footer_h, row_h, input.row_count);
    const scroll = firstVisibleRow(input.focus, visible_rows, input.row_count);
    const box_h = @round(clampBoxHeight(header_h + row_h * @as(f32, @floatFromInt(visible_rows)) + footer_h, content_height));
    const box_x = @round(@max(16.0, (input.window_width - box_w) / 2.0));
    const box_top_px = @round(input.top_offset + @max(16.0, (content_height - box_h) / 2.0));
    const row_top_px = @round(box_top_px + header_h);

    return .{
        .box_x = box_x,
        .box_top_px = box_top_px,
        .box_w = box_w,
        .box_h = box_h,
        .header_h = header_h,
        .footer_h = footer_h,
        .row_top_px = row_top_px,
        .row_h = row_h,
        .visible_rows = visible_rows,
        .scroll = scroll,
        .row_count = input.row_count,
    };
}

test "settings page layout fits every row in tall windows" {
    const cell: f32 = 20;
    const row_count: usize = 14;
    const layout = compute(.{
        .window_width = 1200,
        .window_height = 2000,
        .top_offset = 0,
        .cell_height = cell,
        .focus = row_count - 1,
        .row_count = row_count,
    });

    try std.testing.expectEqual(row_count, layout.visible_rows);
    try std.testing.expectEqual(@as(usize, 0), layout.scroll);
}

test "settings page layout scrolls to keep focused row visible" {
    const cell: f32 = 20;
    const row_count: usize = 14;
    const layout = compute(.{
        .window_width = 900,
        .window_height = 522,
        .top_offset = 0,
        .cell_height = cell,
        .focus = row_count - 1,
        .row_count = row_count,
    });

    try std.testing.expect(layout.visible_rows >= 1);
    try std.testing.expect(layout.visible_rows < row_count);
    try std.testing.expectEqual(row_count - layout.visible_rows, layout.scroll);
    try std.testing.expect(layout.focusVisible(row_count - 1));
}

test "settings page hit testing maps close row and font buttons" {
    const layout = compute(.{
        .window_width = 900,
        .window_height = 700,
        .top_offset = 40,
        .cell_height = 20,
        .focus = 0,
        .row_count = 14,
    });

    const close = layout.closeRect();
    try std.testing.expect(layout.hitClose(close.x + 2, close.top_px + 2));

    const first_row_y = layout.row_top_px + 2;
    try std.testing.expectEqual(@as(?usize, 0), layout.rowAt(layout.box_x + 24, first_row_y));

    const plus_x = layout.box_x + layout.box_w - 68;
    const minus_x = plus_x - 42;
    try std.testing.expectEqual(FontControl.minus, layout.fontControlAt(minus_x).?);
    try std.testing.expectEqual(FontControl.plus, layout.fontControlAt(plus_x).?);
}

test "settings page short-window box stays inside content area" {
    const layout = compute(.{
        .window_width = 800,
        .window_height = 120,
        .top_offset = 0,
        .cell_height = 20,
        .focus = 0,
        .row_count = 14,
    });

    try std.testing.expect(layout.box_top_px + layout.box_h <= 120);
    try std.testing.expect(layout.row_h > 0);
}

test "first visible row handles degenerate row counts" {
    try std.testing.expectEqual(@as(usize, 0), firstVisibleRow(10, 4, 0));
    try std.testing.expectEqual(@as(usize, 0), rowCapacity(400, 100, 40, 0));
}
