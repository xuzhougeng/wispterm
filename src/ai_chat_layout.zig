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

/// Vertical placement of the approval card's contents, in the renderer's y-up
/// local space (origin at the card's *bottom* edge; text drawn at a `*_y`
/// occupies `*_y .. *_y + cell_h`). Every offset and the card `height` scale
/// with `cell_h`, so the three stacked text rows never collide as the UI font
/// grows. The previous renderer hard-coded a 24px pitch and a 128px card, which
/// overlapped once `cell_h` exceeded ~24 (i.e. a larger `font-size`).
pub const ApprovalLayout = struct {
    height: f32,
    title_y: f32,
    hint_y: f32,
    reason_y: f32, // only meaningful when `has_reason`
    has_reason: bool,
    box_y: f32,
    box_h: f32,
    box_text_y: f32,
};

pub fn approvalLayout(cell_h: f32, has_reason: bool) ApprovalLayout {
    const pad_top: f32 = 12;
    const line_gap: f32 = 8; // vertical gap between consecutive text rows
    const box_gap: f32 = 10; // gap between the command box and the lowest text row
    const box_y: f32 = 10;
    const box_h: f32 = @max(34.0, cell_h + 16.0);
    const box_text_y: f32 = box_y + @round((box_h - cell_h) / 2.0);

    const line_pitch: f32 = cell_h + line_gap;
    // Lowest text row sits `box_gap` above the command box; rows stack upward.
    const bottom_text_y: f32 = box_y + box_h + box_gap;
    const reason_y: f32 = if (has_reason) bottom_text_y else 0;
    const hint_y: f32 = if (has_reason) bottom_text_y + line_pitch else bottom_text_y;
    const title_y: f32 = hint_y + line_pitch;
    const height: f32 = title_y + cell_h + pad_top;

    return .{
        .height = height,
        .title_y = title_y,
        .hint_y = hint_y,
        .reason_y = reason_y,
        .has_reason = has_reason,
        .box_y = box_y,
        .box_h = box_h,
        .box_text_y = box_text_y,
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

test "approvalLayout rows never overlap as the UI font grows" {
    // A line drawn at y occupies y..y+cell_h, so non-overlap means each upper
    // row starts at least `cell_h` above the row beneath it. The old fixed 24px
    // pitch violated this for cell_h > 24; this asserts the invariant holds for
    // the full clamped font range (uiFontSize clamps to [9,24]pt → larger cells).
    const sizes = [_]f32{ 12, 14, 18, 24, 30, 36 };
    inline for (.{ true, false }) |has_reason| {
        for (sizes) |cell_h| {
            const l = approvalLayout(cell_h, has_reason);
            try std.testing.expect(l.title_y >= l.hint_y + cell_h);
            if (has_reason) {
                try std.testing.expect(l.hint_y >= l.reason_y + cell_h);
                try std.testing.expect(l.reason_y >= l.box_y + l.box_h);
            } else {
                try std.testing.expect(l.hint_y >= l.box_y + l.box_h);
            }
            // The command-box label stays inside the box.
            try std.testing.expect(l.box_text_y >= l.box_y);
            try std.testing.expect(l.box_text_y + cell_h <= l.box_y + l.box_h);
            // The card is tall enough to hold the top row plus its padding.
            try std.testing.expect(l.height >= l.title_y + cell_h);
        }
    }
}
