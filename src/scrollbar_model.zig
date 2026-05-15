const std = @import("std");

pub const IDLE_OPACITY: f32 = 0.72;

pub const State = struct {
    total: usize,
    offset: usize,
    len: usize,
};

pub const Viewport = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub fn effectiveOpacity(stored_opacity: f32, has_scrollback: bool) f32 {
    if (!has_scrollback) return 0;
    const clamped = if (stored_opacity < 0)
        @as(f32, 0)
    else if (stored_opacity > 1)
        @as(f32, 1)
    else
        stored_opacity;
    return @max(IDLE_OPACITY, clamped);
}

pub fn canInteract(has_scrollback: bool) bool {
    return has_scrollback;
}

pub fn hitTest(viewport: Viewport, top_padding: f32, hover_width: f32, xpos: f32, ypos: f32) bool {
    if (viewport.width <= 0 or viewport.height <= 0) return false;
    const bar_right = viewport.x + viewport.width;
    const bar_left = bar_right - hover_width;
    const track_top = viewport.y + top_padding;
    const track_bottom = viewport.y + viewport.height;

    return xpos >= bar_left and xpos <= bar_right and
        ypos >= track_top and ypos <= track_bottom;
}

pub fn dragTargetOffset(
    state: State,
    local_ypos: f32,
    top_padding: f32,
    viewport_height: f32,
    drag_offset: f32,
    min_thumb_height: f32,
) ?usize {
    if (state.total <= state.len) return null;

    const track_h = viewport_height - top_padding;
    if (track_h <= 0) return null;

    const ratio = @as(f32, @floatFromInt(state.len)) / @as(f32, @floatFromInt(state.total));
    const thumb_h = @max(min_thumb_height, track_h * ratio);
    const scrollable_h = track_h - thumb_h;
    if (scrollable_h <= 0) return 0;

    const y_in_track = local_ypos - top_padding - drag_offset;
    const frac = std.math.clamp(y_in_track / scrollable_h, 0, 1);
    const max_offset = state.total - state.len;
    return @intFromFloat(frac * @as(f32, @floatFromInt(max_offset)));
}

test "scrollbar hit test uses viewport-local right edge" {
    const viewport = Viewport{ .x = 120, .y = 40, .width = 300, .height = 500 };

    try std.testing.expect(hitTest(viewport, 10, 18, 415, 80));
    try std.testing.expect(!hitTest(viewport, 10, 18, 790, 80));
}

test "scrollbar drag target reaches rendered bottom" {
    const state = State{ .total = 100, .len = 20, .offset = 0 };
    const target = dragTargetOffset(state, 500, 10, 500, 0, 16).?;

    try std.testing.expectEqual(@as(usize, 80), target);
}

test "scrollbar remains visible and interactive at idle when scrollback exists" {
    try std.testing.expect(effectiveOpacity(0, true) > 0.01);
    try std.testing.expect(canInteract(true));
}

test "scrollbar hides and ignores input without scrollback" {
    try std.testing.expectEqual(@as(f32, 0), effectiveOpacity(1, false));
    try std.testing.expect(!canInteract(false));
}
