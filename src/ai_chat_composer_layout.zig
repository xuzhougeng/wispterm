const std = @import("std");

pub const Panel = struct {
    pub const pad_x: f32 = 24;
    pub const pad_y: f32 = 14;
};

pub const Field = struct {
    pub const max_w: f32 = 1480;
    pub const pad_x: f32 = 24;
    pub const pad_top: f32 = 18;
    pub const pad_bottom: f32 = 20;
};

pub const input_min_h: f32 = 152;
pub const input_max_h: f32 = 360;

pub fn fieldWidth(panel_w: f32) f32 {
    return @min(Field.max_w, @max(1.0, panel_w - Panel.pad_x * 2));
}

pub fn fieldX(panel_x: f32, panel_w: f32) f32 {
    return panel_x + @round(@max(0.0, panel_w - fieldWidth(panel_w)) / 2);
}

pub fn textWidth(field_w: f32) f32 {
    return @max(1.0, field_w - Field.pad_x * 2);
}

pub fn inputHeightForRows(rows: usize, line_h: f32) f32 {
    const min_field_h = input_min_h - Panel.pad_y * 2;
    const max_field_h = input_max_h - Panel.pad_y * 2;
    const wanted_field_h = @as(f32, @floatFromInt(@max(rows, 1))) * line_h + Field.pad_top + Field.pad_bottom;
    return @min(max_field_h, @max(min_field_h, wanted_field_h)) + Panel.pad_y * 2;
}

pub fn visibleRows(field_h: f32, line_h: f32) usize {
    const rows_f = @max(1.0, @floor((field_h - Field.pad_top - Field.pad_bottom) / @max(1.0, line_h)));
    return @max(@as(usize, 1), @as(usize, @intFromFloat(rows_f)));
}

test "ai chat composer layout is centered and capped on wide panels" {
    const panel_w: f32 = 1580;
    try std.testing.expectApproxEqAbs(@as(f32, 1480), fieldWidth(panel_w), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), fieldX(0, panel_w), 0.01);
}

test "ai chat composer layout keeps a larger minimum and grows for multiline input" {
    const line_h: f32 = 31;
    const single = inputHeightForRows(1, line_h);
    const eight = inputHeightForRows(8, line_h);
    const capped = inputHeightForRows(60, line_h);
    try std.testing.expectApproxEqAbs(@as(f32, 152), single, 0.01);
    try std.testing.expect(eight > single);
    try std.testing.expectApproxEqAbs(@as(f32, 360), capped, 0.01);
}
