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

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
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
    if (count == 1) return std.fmt.bufPrint(buf, "[Image #1]", .{}) catch null;
    return std.fmt.bufPrint(buf, "[Image #1] +{d}", .{count - 1}) catch null;
}

pub fn pendingImagePlaceholder(count: usize, buf: []u8) ?[]const u8 {
    if (count == 0) return null;
    return std.fmt.bufPrint(buf, "[image{d}]", .{count}) catch null;
}

pub fn pendingImageBadgeRect(field_x: f32, field_y: f32, field_h: f32, badge_w: f32, badge_h: f32) Rect {
    const margin_x: f32 = 8;
    const gap_y: f32 = 3;
    return .{
        .x = @round(field_x + margin_x),
        .y = @round(field_y + field_h + gap_y),
        .w = @max(1.0, badge_w),
        .h = @max(1.0, badge_h),
    };
}

test "pendingImageBadgeLabel formats singular/plural and hides zero" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(pendingImageBadgeLabel(0, &buf) == null);
    try std.testing.expectEqualStrings("[Image #1]", pendingImageBadgeLabel(1, &buf).?);
    try std.testing.expectEqualStrings("[Image #1] +2", pendingImageBadgeLabel(3, &buf).?);
}

test "pendingImagePlaceholder formats editable prompt token" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(pendingImagePlaceholder(0, &buf) == null);
    try std.testing.expectEqualStrings("[image1]", pendingImagePlaceholder(1, &buf).?);
    try std.testing.expectEqualStrings("[image2]", pendingImagePlaceholder(2, &buf).?);
}

test "pending image badge sits above the input field on the left" {
    const rect = pendingImageBadgeRect(18, 16, 60, 120, 26);
    try std.testing.expectApproxEqAbs(@as(f32, 26), rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 79), rect.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 26), rect.h, 0.01);
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
