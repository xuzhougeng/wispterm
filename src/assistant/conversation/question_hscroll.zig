//! Horizontal scrolling for the pending ask_user question and option rows.
//!
//! Geometry and state are platform-independent. Question generations keep a
//! drag that started on an answered question from panning its replacement.

const std = @import("std");
const table_hscroll = @import("table_hscroll.zig");

pub const TRACK_H: f32 = 4;
pub const TRACK_BAND_H: f32 = 12;
pub const TEXT_PAD: f32 = 20;

const TRACK_PAD: f32 = 4;
const MIN_THUMB: f32 = 24;

pub const Geometry = struct {
    track_x: f32,
    track_w: f32,
    track_top_px: f32,
    track_h: f32,
    thumb_x: f32,
    thumb_w: f32,
    max_offset: f32,

    /// Return the drag's pointer-to-thumb offset. Track clicks center the
    /// thumb, while pressing the thumb keeps its existing position.
    pub fn hit(self: Geometry, x: f32, y: f32) ?f32 {
        const hit_pad = (TRACK_BAND_H - self.track_h) / 2;
        if (x < self.track_x or x > self.track_x + self.track_w or
            y < self.track_top_px - hit_pad or y > self.track_top_px + self.track_h + hit_pad)
        {
            return null;
        }
        if (x >= self.thumb_x and x <= self.thumb_x + self.thumb_w) {
            return x - self.thumb_x;
        }
        return self.thumb_w / 2;
    }

    pub fn offsetAt(self: Geometry, pointer_x: f32, grab_offset: f32) f32 {
        const travel = self.track_w - self.thumb_w;
        if (travel <= 0) return 0;
        const fraction = std.math.clamp((pointer_x - grab_offset - self.track_x) / travel, 0.0, 1.0);
        return fraction * self.max_offset;
    }
};

/// Track placement uses top-left pixel coordinates and stays inside the clip
/// even when its width is smaller than the usual padding or minimum thumb.
pub fn geometry(clip_x: f32, clip_w: f32, content_w: f32, offset: f32, track_top_px: f32) ?Geometry {
    if (clip_w <= 0 or content_w <= clip_w) return null;
    const track_pad = @min(TRACK_PAD, clip_w / 4);
    const track_w = clip_w - track_pad * 2;
    const thumb_w = @min(track_w, @max(MIN_THUMB, track_w * clip_w / content_w));
    const max_offset = table_hscroll.maxOffset(content_w, clip_w);
    const fraction = table_hscroll.clampOffset(offset, content_w, clip_w) / max_offset;
    const track_x = clip_x + track_pad;
    return .{
        .track_x = track_x,
        .track_w = track_w,
        .track_top_px = track_top_px,
        .track_h = TRACK_H,
        .thumb_x = track_x + fraction * (track_w - thumb_w),
        .thumb_w = thumb_w,
        .max_offset = max_offset,
    };
}

pub const State = struct {
    offset: f32 = 0,
    generation: u64 = 0,

    pub fn reset(self: *State) void {
        self.offset = 0;
        self.generation +%= 1;
    }

    /// Return whether the stored offset changed. Stale drags are ignored.
    pub fn setOffset(self: *State, expected_generation: u64, offset: f32, content_w: f32, clip_w: f32) bool {
        if (self.generation != expected_generation) return false;
        const next = table_hscroll.clampOffset(offset, content_w, clip_w);
        if (next == self.offset) return false;
        self.offset = next;
        return true;
    }

    pub fn offsetFor(self: *const State, content_w: f32, clip_w: f32) f32 {
        return table_hscroll.clampOffset(self.offset, content_w, clip_w);
    }
};

test "question scrollbar is absent when all text fits or the clip has no width" {
    try std.testing.expect(geometry(10, 200, 180, 0, 80) == null);
    try std.testing.expect(geometry(10, 200, 200, 0, 80) == null);
    try std.testing.expect(geometry(10, 0, 200, 0, 80) == null);
    try std.testing.expect(geometry(10, -1, 200, 0, 80) == null);
}

test "question scrollbar remains bounded in tiny positive clips" {
    for ([_]f32{ 0.125, 1, 4, 8, 20, 25, 48 }) |clip_w| {
        for ([_]f32{ -10, 0, 100, 999 }) |offset| {
            const bar = geometry(10, clip_w, 300, offset, 80).?;
            try std.testing.expect(bar.track_w > 0);
            try std.testing.expect(bar.track_x >= 10);
            try std.testing.expect(bar.track_x + bar.track_w <= 10 + clip_w);
            try std.testing.expect(bar.thumb_w > 0);
            try std.testing.expect(bar.thumb_x >= bar.track_x);
            try std.testing.expect(bar.thumb_x + bar.thumb_w <= bar.track_x + bar.track_w);
            try std.testing.expectEqual(@as(f32, 0), bar.offsetAt(-100, 0));
        }
    }
}

test "thumb press keeps the existing pan and uses the wider hit band" {
    const bar = geometry(10, 200, 400, 70, 80).?;
    const pointer_x = bar.thumb_x + 7;
    const grab = bar.hit(pointer_x, 82).?;
    try std.testing.expectEqual(@as(f32, 7), grab);
    try std.testing.expectApproxEqAbs(@as(f32, 70), bar.offsetAt(pointer_x, grab), 0.001);
    try std.testing.expect(bar.hit(pointer_x, 76) != null);
    try std.testing.expect(bar.hit(pointer_x, 88) != null);
    try std.testing.expect(bar.hit(pointer_x, 75) == null);
    try std.testing.expect(bar.hit(pointer_x, 89) == null);
    try std.testing.expect(bar.hit(bar.track_x - 1, 82) == null);
    try std.testing.expect(bar.hit(bar.track_x + bar.track_w + 1, 82) == null);
}

test "track clicks center the thumb and dragging reaches both endpoints" {
    const bar = geometry(10, 200, 400, 100, 80).?;
    const left_grab = bar.hit(bar.track_x, 82).?;
    const right_grab = bar.hit(bar.track_x + bar.track_w, 82).?;
    try std.testing.expectEqual(bar.thumb_w / 2, left_grab);
    try std.testing.expectEqual(bar.thumb_w / 2, right_grab);
    try std.testing.expectEqual(@as(f32, 0), bar.offsetAt(bar.track_x, left_grab));
    try std.testing.expectEqual(bar.max_offset, bar.offsetAt(bar.track_x + bar.track_w, right_grab));
    try std.testing.expectEqual(@as(f32, 0), bar.offsetAt(-999, 7));
    try std.testing.expectEqual(bar.max_offset, bar.offsetAt(999, 7));
    const start = geometry(10, 200, 400, -100, 80).?;
    const end = geometry(10, 200, 400, 999, 80).?;
    try std.testing.expectEqual(start.track_x, start.thumb_x);
    try std.testing.expectEqual(end.track_x + end.track_w, end.thumb_x + end.thumb_w);
}

test "question pan clamps when the card is resized or the text becomes shorter" {
    var state: State = .{};
    try std.testing.expect(state.setOffset(0, 150, 400, 200));
    try std.testing.expectEqual(@as(f32, 150), state.offsetFor(400, 200));
    try std.testing.expectEqual(@as(f32, 80), state.offsetFor(400, 320));
    try std.testing.expectEqual(@as(f32, 0), state.offsetFor(180, 200));
    try std.testing.expect(state.setOffset(0, 999, 400, 320));
    try std.testing.expectEqual(@as(f32, 80), state.offset);
    try std.testing.expect(!state.setOffset(0, 999, 400, 320));
    try std.testing.expect(state.setOffset(0, -10, 400, 320));
    try std.testing.expectEqual(@as(f32, 0), state.offset);
}

test "new questions reset pan and reject an earlier question's drag" {
    var state: State = .{};
    const drag_generation = state.generation;
    try std.testing.expect(state.setOffset(drag_generation, 100, 400, 200));
    state.reset();
    try std.testing.expectEqual(@as(f32, 0), state.offset);
    try std.testing.expectEqual(drag_generation + 1, state.generation);
    try std.testing.expect(!state.setOffset(drag_generation, 150, 400, 200));
    try std.testing.expectEqual(@as(f32, 0), state.offset);
    try std.testing.expect(state.setOffset(state.generation, 40, 400, 200));
    state.reset();
    try std.testing.expectEqual(@as(f32, 0), state.offset);
}
