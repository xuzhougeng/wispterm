//! Pure layout math for the file explorer side panel.
//!
//! The file explorer renderer owns state lookup, hover checks, text drawing, and
//! colors. This module only computes panel geometry and list row placement.

const std = @import("std");

pub const Input = struct {
    window_height: f32,
    titlebar_height: f32,
    sidebar_width: f32,
    explorer_width: f32,
    header_height: f32,
    row_height: f32,
    text_height: f32,
};

pub const Layout = struct {
    window_height: f32,
    titlebar_height: f32,
    panel_x: f32,
    panel_right: f32,
    explorer_width: f32,
    side_height: f32,
    header_height: f32,
    header_y: f32,
    header_text_y: f32,
    list_top_px: f32,
    visible_height: f32,
    row_height: f32,
    text_height: f32,
    status_height: f32,

    pub fn row(self: Layout, index: usize, scroll: f32) RowState {
        const row_y_from_top = @as(f32, @floatFromInt(index)) * self.row_height - scroll;
        if (row_y_from_top + self.row_height < 0) return .before;
        if (row_y_from_top >= self.visible_height) return .after;

        const row_top_px = self.list_top_px + row_y_from_top;
        return .{ .visible = .{
            .top_px = row_top_px,
            .y = self.window_height - row_top_px - self.row_height,
        } };
    }

    pub fn operationRow(self: Layout, index: usize, scroll: f32) ?Row {
        const row_top_px = self.list_top_px + @as(f32, @floatFromInt(index)) * self.row_height - scroll;
        if (row_top_px < 0 or row_top_px >= self.visible_height) return null;
        return .{
            .top_px = row_top_px,
            .y = self.window_height - row_top_px - self.row_height,
        };
    }

    pub fn textY(self: Layout, row_y: f32) f32 {
        return row_y + (self.row_height - self.text_height) / 2.0;
    }
};

pub const Row = struct {
    top_px: f32,
    y: f32,
};

pub const RowState = union(enum) {
    before,
    visible: Row,
    after,
};

pub fn compute(input: Input) Layout {
    const side_height = input.window_height - input.titlebar_height;
    const panel_x = input.sidebar_width;
    const panel_right = panel_x + input.explorer_width;
    const header_y = input.window_height - input.titlebar_height - input.header_height;
    const list_top_px = input.titlebar_height + input.header_height;
    const visible_height = input.window_height - list_top_px;
    const status_height = @max(24.0, input.text_height + 8.0);

    return .{
        .window_height = input.window_height,
        .titlebar_height = input.titlebar_height,
        .panel_x = panel_x,
        .panel_right = panel_right,
        .explorer_width = input.explorer_width,
        .side_height = side_height,
        .header_height = input.header_height,
        .header_y = header_y,
        .header_text_y = header_y + (input.header_height - input.text_height) / 2.0,
        .list_top_px = list_top_px,
        .visible_height = visible_height,
        .row_height = input.row_height,
        .text_height = input.text_height,
        .status_height = status_height,
    };
}

test "file explorer layout computes panel and header bands" {
    const layout = compute(.{
        .window_height = 820,
        .titlebar_height = 44,
        .sidebar_width = 220,
        .explorer_width = 280,
        .header_height = 36,
        .row_height = 28,
        .text_height = 20,
    });

    try std.testing.expectEqual(@as(f32, 220), layout.panel_x);
    try std.testing.expectEqual(@as(f32, 500), layout.panel_right);
    try std.testing.expectEqual(@as(f32, 776), layout.side_height);
    try std.testing.expectEqual(@as(f32, 740), layout.header_y);
    try std.testing.expectEqual(@as(f32, 80), layout.list_top_px);
    try std.testing.expectEqual(@as(f32, 740), layout.visible_height);
}

test "file explorer rows report before visible and after states" {
    const layout = compute(.{
        .window_height = 400,
        .titlebar_height = 40,
        .sidebar_width = 180,
        .explorer_width = 260,
        .header_height = 40,
        .row_height = 30,
        .text_height = 20,
    });

    try std.testing.expectEqual(RowState.before, layout.row(0, 31));

    const first_visible = layout.row(0, 30);
    try std.testing.expectEqual(@as(f32, 50), first_visible.visible.top_px);
    try std.testing.expectEqual(@as(f32, 320), first_visible.visible.y);

    try std.testing.expectEqual(RowState.after, layout.row(11, 0));
}

test "file explorer text and status metrics follow font height" {
    const layout = compute(.{
        .window_height = 480,
        .titlebar_height = 42,
        .sidebar_width = 200,
        .explorer_width = 300,
        .header_height = 38,
        .row_height = 32,
        .text_height = 22,
    });

    const row = layout.row(2, 0).visible;
    try std.testing.expectEqual(row.y + 5, layout.textY(row.y));
    try std.testing.expectEqual(@as(f32, 30), layout.status_height);
}

test "operation row preserves append-row visibility math" {
    const layout = compute(.{
        .window_height = 400,
        .titlebar_height = 40,
        .sidebar_width = 180,
        .explorer_width = 260,
        .header_height = 40,
        .row_height = 30,
        .text_height = 20,
    });

    const row = layout.operationRow(0, 0).?;
    try std.testing.expectEqual(@as(f32, 80), row.top_px);
    try std.testing.expectEqual(@as(f32, 290), row.y);
    try std.testing.expect(layout.operationRow(20, 0) == null);
}
