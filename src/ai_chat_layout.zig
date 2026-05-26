//! Pure rect geometry for the AI Chat renderer.
//!
//! No GL, font, or platform imports so it can be unit-tested in the fast test
//! build (mirrors ai_chat_composer_layout.zig / ai_chat_scrollbar_model.zig,
//! extracted for the same reason — src/renderer/ai_chat_renderer.zig @cImports
//! OpenGL historically and the font globals are not part of the test build).
//! Callers pass font-derived metrics (e.g. header_h) and layout constants as
//! params; this module owns none of them.

const std = @import("std");

/// Window-space rect with a top-left-origin `top_px` (matches the renderer's
/// existing Rect: hit-tests compare against top_px, draws convert to GL y).
pub const Rect = struct {
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
};

/// Horizontal placement of a message bubble: `x` is its left edge (which is
/// right-shifted for the right-aligned user bubble) and `w` its width.
pub const BubbleGeometry = struct {
    x: f32,
    w: f32,
};

pub fn pointInRect(px: f32, py: f32, rect: Rect) bool {
    return px >= rect.x and px <= rect.x + rect.w and py >= rect.top_px and py <= rect.top_px + rect.h;
}

pub fn bubbleGeometry(is_user: bool, x: f32, w: f32) BubbleGeometry {
    const bubble_w = @min(w, if (is_user) w * 0.82 else w);
    return .{
        .x = if (is_user) x + w - bubble_w else x,
        .w = bubble_w,
    };
}

pub fn copyButtonRectForBubble(
    bubble_x: f32,
    top_px: f32,
    bubble_w: f32,
    bubble_pad_x: f32,
    button_size: f32,
    button_pad: f32,
) Rect {
    return .{
        .x = bubble_x + bubble_w - bubble_pad_x - button_size,
        .top_px = top_px + button_pad,
        .w = button_size,
        .h = button_size,
    };
}

pub fn detailHeaderRect(x: f32, top_px: f32, w: f32, header_h: f32) Rect {
    return .{ .x = x, .top_px = top_px, .w = w, .h = header_h };
}

pub fn detailCopyButtonRect(
    x: f32,
    top_px: f32,
    w: f32,
    header_h: f32,
    detail_pad_x: f32,
    button_size: f32,
) Rect {
    return .{
        .x = x + w - detail_pad_x - button_size,
        .top_px = top_px + @round((header_h - button_size) / 2),
        .w = button_size,
        .h = button_size,
    };
}

pub fn permissionChipX(x: f32, w: f32, line_pad_x: f32, status_slot_w: f32, chip_gap: f32, chip_w: f32) f32 {
    return x + w - line_pad_x - status_slot_w - chip_gap - chip_w;
}

pub fn stopButtonRect(
    x: f32,
    w: f32,
    titlebar_offset: f32,
    line_pad_x: f32,
    stop_w: f32,
    stop_h: f32,
    header_h: f32,
) Rect {
    return .{
        .x = x + w - line_pad_x - stop_w,
        .top_px = titlebar_offset + @round((header_h - stop_h) / 2),
        .w = stop_w,
        .h = stop_h,
    };
}

test "pointInRect inside, edges, outside" {
    const r = Rect{ .x = 0, .top_px = 0, .w = 20, .h = 20 };
    try std.testing.expect(pointInRect(10, 10, r));
    try std.testing.expect(pointInRect(0, 0, r)); // top-left edge inclusive
    try std.testing.expect(pointInRect(20, 20, r)); // bottom-right edge inclusive
    try std.testing.expect(!pointInRect(21, 10, r));
    try std.testing.expect(!pointInRect(10, 21, r));
}

test "bubbleGeometry user vs assistant" {
    const u = bubbleGeometry(true, 100, 200); // 0.82 width, right-aligned
    try std.testing.expectApproxEqAbs(@as(f32, 164), u.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 136), u.x, 0.001);
    const a = bubbleGeometry(false, 100, 200); // full width, left
    try std.testing.expectApproxEqAbs(@as(f32, 200), a.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), a.x, 0.001);
}

test "copyButtonRectForBubble placement" {
    const r = copyButtonRectForBubble(100, 50, 200, 14, 24, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 262), r.x, 0.001); // 100+200-14-24
    try std.testing.expectApproxEqAbs(@as(f32, 58), r.top_px, 0.001); // 50+8
    try std.testing.expectApproxEqAbs(@as(f32, 24), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), r.h, 0.001);
}

test "detailHeaderRect passes header_h through" {
    const r = detailHeaderRect(10, 20, 300, 40);
    try std.testing.expectApproxEqAbs(@as(f32, 10), r.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), r.top_px, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 300), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), r.h, 0.001);
}

test "detailCopyButtonRect centers in header_h" {
    const r = detailCopyButtonRect(10, 20, 300, 40, 14, 24);
    try std.testing.expectApproxEqAbs(@as(f32, 272), r.x, 0.001); // 10+300-14-24
    try std.testing.expectApproxEqAbs(@as(f32, 28), r.top_px, 0.001); // 20+round((40-24)/2)
    try std.testing.expectApproxEqAbs(@as(f32, 24), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), r.h, 0.001);
}

test "permissionChipX" {
    const px = permissionChipX(0, 1000, 18, 280, 12, 104); // w - line_pad - status - gap - chip
    try std.testing.expectApproxEqAbs(@as(f32, 586), px, 0.001);
}

test "stopButtonRect centers in header_h" {
    const r = stopButtonRect(0, 1000, 5, 18, 104, 28, 54);
    try std.testing.expectApproxEqAbs(@as(f32, 878), r.x, 0.001); // 1000-18-104
    try std.testing.expectApproxEqAbs(@as(f32, 18), r.top_px, 0.001); // 5+round((54-28)/2)
    try std.testing.expectApproxEqAbs(@as(f32, 104), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 28), r.h, 0.001);
}
