//! Pure layout math for the startup keyboard shortcuts overlay.
//!
//! The renderer owns text measurement and drawing; this module only decides
//! panel geometry, column count, and row placement from measured widths and
//! viewport dimensions.

const std = @import("std");

pub const MAX_COLUMNS: usize = 3;

pub const Input = struct {
    window_width: f32,
    window_height: f32,
    top_offset: f32,
    text_height: f32,
    line_height: f32,
    entry_count: usize,
    max_keys_width: f32,
    max_action_width: f32,
    heading_width: f32,
    hint_width: f32,
};

pub const Layout = struct {
    box_x: f32,
    box_y: f32,
    box_width: f32,
    box_height: f32,
    pad_x: f32,
    pad_y: f32,
    heading_y: f32,
    divider_y: f32,
    first_entry_y: f32,
    hint_x: f32,
    hint_y: f32,
    hint_max_width: f32,
    columns: usize,
    rows_per_column: usize,
    column_width: f32,
    column_gap: f32,
    pair_gap: f32,
    keys_width: f32,
    action_width: f32,
    line_height: f32,
    entry_count: usize,

    pub fn entry(self: Layout, idx: usize) ?Entry {
        if (idx >= self.entry_count or self.rows_per_column == 0) return null;

        const col = idx / self.rows_per_column;
        const row = idx % self.rows_per_column;
        if (col >= self.columns) return null;

        const col_x = @round(self.box_x + self.pad_x + @as(f32, @floatFromInt(col)) * (self.column_width + self.column_gap));
        return .{
            .keys_x = col_x,
            .action_x = @round(col_x + self.keys_width + self.pair_gap),
            .y = @round(self.first_entry_y - @as(f32, @floatFromInt(row)) * self.line_height),
            .keys_width = self.keys_width,
            .action_width = self.action_width,
        };
    }
};

pub const Entry = struct {
    keys_x: f32,
    action_x: f32,
    y: f32,
    keys_width: f32,
    action_width: f32,
};

pub fn compute(input: Input) Layout {
    const pad_x: f32 = 24;
    const pad_y: f32 = 18;
    const pair_gap_base: f32 = 48;
    const column_gap: f32 = 38;
    const heading_gap: f32 = 16;
    const hint_gap: f32 = 12;
    const content_height = @max(1.0, input.window_height - input.top_offset);
    const available_height = @max(input.line_height, content_height - 24.0);
    const fixed_height = pad_y * 2 + input.text_height + heading_gap + hint_gap + input.text_height;
    const available_entry_height = @max(input.line_height, available_height - fixed_height);
    const rows_fit: usize = @max(1, @as(usize, @intFromFloat(@floor(available_entry_height / input.line_height))));

    var columns: usize = (input.entry_count + rows_fit - 1) / rows_fit;
    columns = @min(@max(columns, 1), MAX_COLUMNS);
    const rows_per_column = (input.entry_count + columns - 1) / columns;
    const entries_height = input.line_height * @as(f32, @floatFromInt(rows_per_column));
    const pair_width = input.max_keys_width + pair_gap_base + input.max_action_width;
    const desired_box_width = @round(@max(
        input.heading_width + pad_x * 2,
        @max(input.hint_width + pad_x * 2, pair_width * @as(f32, @floatFromInt(columns)) + column_gap * @as(f32, @floatFromInt(columns - 1)) + pad_x * 2),
    ));
    const box_width = @round(@min(desired_box_width, @max(260.0, input.window_width - 24.0)));
    const box_height = @round(fixed_height + entries_height);

    const box_x = @round(@max(12.0, (input.window_width - box_width) / 2.0));
    const box_y = @round(@max(12.0, (content_height - box_height) / 2.0));
    const heading_y = @round(box_y + box_height - pad_y - input.text_height);
    const first_entry_y = @round(heading_y - heading_gap - input.line_height);
    const inner_w = @max(1.0, box_width - pad_x * 2);
    const total_column_gap = column_gap * @as(f32, @floatFromInt(columns - 1));
    const column_width = @max(1.0, (inner_w - total_column_gap) / @as(f32, @floatFromInt(columns)));
    const pair_gap = @min(pair_gap_base, @max(18.0, column_width * 0.08));
    const keys_width = @min(input.max_keys_width, column_width * 0.48);
    const action_width = @max(1.0, column_width - keys_width - pair_gap);
    const hint_max_width = box_width - pad_x * 2;

    return .{
        .box_x = box_x,
        .box_y = box_y,
        .box_width = box_width,
        .box_height = box_height,
        .pad_x = pad_x,
        .pad_y = pad_y,
        .heading_y = heading_y,
        .divider_y = heading_y - heading_gap / 2.0 - 1.0,
        .first_entry_y = first_entry_y,
        .hint_x = box_x + (box_width - @min(input.hint_width, hint_max_width)) / 2.0,
        .hint_y = box_y + pad_y,
        .hint_max_width = hint_max_width,
        .columns = columns,
        .rows_per_column = rows_per_column,
        .column_width = column_width,
        .column_gap = column_gap,
        .pair_gap = pair_gap,
        .keys_width = keys_width,
        .action_width = action_width,
        .line_height = input.line_height,
        .entry_count = input.entry_count,
    };
}

test "wide startup overlay uses three columns when height is constrained" {
    const layout = compute(.{
        .window_width = 1280,
        .window_height = 430,
        .top_offset = 40,
        .text_height = 22,
        .line_height = 30,
        .entry_count = 24,
        .max_keys_width = 190,
        .max_action_width = 220,
        .heading_width = 260,
        .hint_width = 300,
    });

    try std.testing.expectEqual(@as(usize, 3), layout.columns);
    try std.testing.expectEqual(@as(usize, 8), layout.rows_per_column);
    try std.testing.expect(layout.box_width <= 1280 - 24);
    try std.testing.expect(layout.box_x >= 12);
}

test "startup overlay falls back to one column when rows fit" {
    const layout = compute(.{
        .window_width = 900,
        .window_height = 1600,
        .top_offset = 40,
        .text_height = 20,
        .line_height = 28,
        .entry_count = 10,
        .max_keys_width = 150,
        .max_action_width = 180,
        .heading_width = 220,
        .hint_width = 260,
    });

    try std.testing.expectEqual(@as(usize, 1), layout.columns);
    try std.testing.expectEqual(@as(usize, 10), layout.rows_per_column);
}

test "entry placement advances down rows then across columns" {
    const layout = compute(.{
        .window_width = 1280,
        .window_height = 820,
        .top_offset = 40,
        .text_height = 22,
        .line_height = 30,
        .entry_count = 24,
        .max_keys_width = 190,
        .max_action_width = 220,
        .heading_width = 260,
        .hint_width = 300,
    });

    const first = layout.entry(0).?;
    const second = layout.entry(1).?;
    const next_column = layout.entry(layout.rows_per_column).?;

    try std.testing.expectEqual(first.keys_x, second.keys_x);
    try std.testing.expectEqual(first.y - layout.line_height, second.y);
    try std.testing.expect(next_column.keys_x > first.keys_x);
    try std.testing.expectEqual(first.y, next_column.y);
    try std.testing.expectEqual(@as(?Entry, null), layout.entry(24));
}

test "narrow startup overlay clamps width and preserves positive text bands" {
    const layout = compute(.{
        .window_width = 280,
        .window_height = 360,
        .top_offset = 36,
        .text_height = 18,
        .line_height = 26,
        .entry_count = 24,
        .max_keys_width = 220,
        .max_action_width = 240,
        .heading_width = 320,
        .hint_width = 260,
    });

    try std.testing.expectEqual(@as(f32, 260), layout.box_width);
    try std.testing.expect(layout.column_width > 0);
    try std.testing.expect(layout.keys_width > 0);
    try std.testing.expect(layout.action_width > 0);
    try std.testing.expect(layout.hint_max_width > 0);
}
