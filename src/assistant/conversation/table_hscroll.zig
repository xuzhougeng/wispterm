//! Horizontal pan for a markdown table that is wider than its message.
//!
//! Pure geometry so it can run in the fast test suite. The renderer measures
//! natural column widths; this module only clamps the pan offset and lays out
//! the overflow thumb.

const std = @import("std");

pub const TRACK_H: f32 = 4;
pub const TRACK_PAD: f32 = 4;
pub const MIN_THUMB: f32 = 24;

/// How far the table can pan. Zero when the content fits.
pub fn maxOffset(content_w: f32, clip_w: f32) f32 {
    return @max(0.0, content_w - clip_w);
}

pub fn clampOffset(offset: f32, content_w: f32, clip_w: f32) f32 {
    return std.math.clamp(offset, 0.0, maxOffset(content_w, clip_w));
}

pub fn applyDelta(offset: f32, delta: f32, content_w: f32, clip_w: f32) f32 {
    return clampOffset(offset + delta, content_w, clip_w);
}

pub const Thumb = struct {
    x: f32,
    w: f32,
    track_x: f32,
    track_w: f32,
    track_top_px: f32,
    track_h: f32,
};

/// Bottom-of-table overflow thumb. `table_top_px` / `table_h` are top-left.
/// Returns null when the table fits in `clip_w`.
pub fn thumb(clip_x: f32, clip_w: f32, content_w: f32, offset: f32, table_top_px: f32, table_h: f32) ?Thumb {
    if (content_w <= clip_w or clip_w <= 0) return null;
    const track_x = clip_x + TRACK_PAD;
    const track_w = @max(1.0, clip_w - TRACK_PAD * 2);
    const visible_ratio = clip_w / content_w;
    const thumb_w = @max(MIN_THUMB, @min(track_w, track_w * visible_ratio));
    const max_off = maxOffset(content_w, clip_w);
    const frac = if (max_off <= 0) 0.0 else std.math.clamp(offset / max_off, 0.0, 1.0);
    const thumb_x = track_x + frac * (track_w - thumb_w);
    return .{
        .x = thumb_x,
        .w = thumb_w,
        .track_x = track_x,
        .track_w = track_w,
        .track_top_px = table_top_px + table_h - TRACK_H - 2,
        .track_h = TRACK_H,
    };
}

/// Pan state for the table the pointer last scrolled. Offset is reused while
/// the same (message, table-start) pair stays selected; switching tables
/// resets it so a pan on one table does not leak into another.
pub const State = struct {
    message_index: usize = 0,
    table_start: usize = 0,
    offset: f32 = 0,

    pub fn offsetFor(self: *const State, message_index: usize, table_start: usize, content_w: f32, clip_w: f32) f32 {
        if (self.message_index != message_index or self.table_start != table_start) return 0;
        return clampOffset(self.offset, content_w, clip_w);
    }

    pub fn scroll(
        self: *State,
        message_index: usize,
        table_start: usize,
        delta: f32,
        content_w: f32,
        clip_w: f32,
    ) bool {
        const start = if (self.message_index == message_index and self.table_start == table_start)
            self.offset
        else
            0;
        const next = applyDelta(start, delta, content_w, clip_w);
        const changed = next != start or self.message_index != message_index or self.table_start != table_start;
        self.message_index = message_index;
        self.table_start = table_start;
        self.offset = next;
        return changed;
    }
};

test "maxOffset is zero when the table fits" {
    try std.testing.expectEqual(@as(f32, 0), maxOffset(200, 220));
    try std.testing.expectEqual(@as(f32, 80), maxOffset(300, 220));
}

test "clampOffset stays in range" {
    try std.testing.expectEqual(@as(f32, 0), clampOffset(-10, 300, 220));
    try std.testing.expectEqual(@as(f32, 80), clampOffset(999, 300, 220));
    try std.testing.expectEqual(@as(f32, 40), clampOffset(40, 300, 220));
}

test "applyDelta pans and clamps" {
    try std.testing.expectEqual(@as(f32, 50), applyDelta(20, 30, 300, 220));
    try std.testing.expectEqual(@as(f32, 0), applyDelta(10, -40, 300, 220));
}

test "thumb is absent when content fits and tracks pan when it does not" {
    try std.testing.expect(thumb(0, 220, 200, 0, 0, 40) == null);
    const t = thumb(10, 200, 400, 100, 50, 80).?;
    try std.testing.expect(t.w >= MIN_THUMB);
    try std.testing.expect(t.x > t.track_x);
    try std.testing.expect(t.x + t.w <= t.track_x + t.track_w + 0.01);
    try std.testing.expectEqual(@as(f32, 50 + 80 - TRACK_H - 2), t.track_top_px);
}

test "State reuses offset for the same table and resets on another" {
    var state: State = .{};
    try std.testing.expect(state.scroll(1, 10, 40, 300, 220));
    try std.testing.expectEqual(@as(f32, 40), state.offsetFor(1, 10, 300, 220));
    try std.testing.expectEqual(@as(f32, 0), state.offsetFor(2, 10, 300, 220));
    try std.testing.expect(state.scroll(2, 10, 15, 300, 220));
    try std.testing.expectEqual(@as(f32, 15), state.offsetFor(2, 10, 300, 220));
}
