const std = @import("std");

pub const Panel = struct {
    pub const pad_x: f32 = 18;
    pub const pad_y: f32 = 16;
};

pub const Field = struct {
    pub const max_w: f32 = 4096;
    pub const pad_x: f32 = 12;
    pub const pad_top: f32 = 10;
    pub const pad_bottom: f32 = 10;
};

pub const input_min_h: f32 = 92;
pub const input_max_h: f32 = 260;

pub fn fieldWidth(panel_w: f32) f32 {
    return @min(Field.max_w, @max(1.0, panel_w - Panel.pad_x * 2));
}

pub fn fieldX(panel_x: f32, panel_w: f32) f32 {
    _ = panel_w;
    return panel_x + Panel.pad_x;
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

/// Label for the pending-image chip shown in the composer, or null when there
/// are no attachments. Writes into `buf` and returns the slice.
pub fn pendingImageBadgeLabel(count: usize, buf: []u8) ?[]const u8 {
    if (count == 0) return null;
    const suffix = if (count == 1) "image" else "images";
    return std.fmt.bufPrint(buf, "{d} {s}", .{ count, suffix }) catch null;
}

test "pendingImageBadgeLabel formats singular/plural and hides zero" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(pendingImageBadgeLabel(0, &buf) == null);
    try std.testing.expectEqualStrings("1 image", pendingImageBadgeLabel(1, &buf).?);
    try std.testing.expectEqualStrings("3 images", pendingImageBadgeLabel(3, &buf).?);
}

test "ai chat composer layout keeps original full-width field style" {
    const panel_w: f32 = 1580;
    try std.testing.expectApproxEqAbs(@as(f32, 1544), fieldWidth(panel_w), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 18), fieldX(0, panel_w), 0.01);
}

test "ai chat composer layout stays compact and grows for multiline input" {
    const line_h: f32 = 31;
    const single = inputHeightForRows(1, line_h);
    const eight = inputHeightForRows(8, line_h);
    const capped = inputHeightForRows(60, line_h);
    try std.testing.expectApproxEqAbs(@as(f32, 92), single, 0.01);
    try std.testing.expect(eight > single);
    try std.testing.expectApproxEqAbs(@as(f32, 260), capped, 0.01);
}
