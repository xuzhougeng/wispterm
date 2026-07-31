//! Pure geometry / drag / fade math for the AI Chat transcript scrollbar.
//!
//! No GL or platform imports so it can be unit-tested in test_main.zig
//! (mirrors src/scrollbar_model.zig, which the terminal scrollbar extracted
//! for the same reason — src/renderer/assistant/conversation.zig @cImports OpenGL
//! and is not part of the test build).

const std = @import("std");

pub const WIDTH: f32 = 12; // Track/thumb width in px
pub const MIN_THUMB: f32 = 20; // Minimum thumb height in px
pub const HIT_PAD: f32 = 4; // Extra hit area on each side of the track
pub const FADE_DELAY_MS: i64 = 800; // Fully visible before fading
pub const FADE_DURATION_MS: i64 = 400; // Fade-out animation length

/// Resolved scrollbar geometry. All `*_px` values use top-left origin.
pub const Geometry = struct {
    track_x: f32,
    track_top_px: f32,
    track_h: f32,
    thumb_top_px: f32,
    thumb_h: f32,
    max_scroll: f32,
};

/// Compute geometry for the transcript scrollbar.
/// `x`/`w` are the transcript panel's left edge and width; `transcript_top`
/// is the top of the transcript area (top-left px); `transcript_h` the visible
/// height; `content_h` the total content height; `scroll_px` the current scroll.
/// Returns null when the content fits (no overflow → no scrollbar).
pub fn geometry(x: f32, w: f32, transcript_top: f32, transcript_h: f32, content_h: f32, scroll_px: f32) ?Geometry {
    if (transcript_h <= 0 or content_h <= transcript_h) return null;
    const max_scroll = content_h - transcript_h;
    const track_x = @round(x + w - WIDTH);
    const track_top_px = @round(transcript_top);
    const track_h = @round(@max(1.0, transcript_h));
    const visible_ratio = transcript_h / content_h;
    const thumb_h = @round(@min(track_h, @max(MIN_THUMB, track_h * visible_ratio)));
    const frac = std.math.clamp(scroll_px / max_scroll, 0.0, 1.0);
    const thumb_top_px = @round(track_top_px + frac * (track_h - thumb_h));
    return .{
        .track_x = track_x,
        .track_top_px = track_top_px,
        .track_h = track_h,
        .thumb_top_px = thumb_top_px,
        .thumb_h = thumb_h,
        .max_scroll = max_scroll,
    };
}

/// True when a point (top-left px) is over the track (including HIT_PAD).
pub fn hitTrack(geo: Geometry, px: f32, py: f32) bool {
    return px >= geo.track_x - HIT_PAD and px <= geo.track_x + WIDTH + HIT_PAD and
        py >= geo.track_top_px and py <= geo.track_top_px + geo.track_h;
}

/// Drag offset within the thumb for a press at `py`. If the press is on the
/// thumb, returns `py - thumb_top_px`; if on the bare track, centers the thumb.
pub fn thumbDragOffset(geo: Geometry, py: f32) f32 {
    if (py >= geo.thumb_top_px and py <= geo.thumb_top_px + geo.thumb_h) return py - geo.thumb_top_px;
    return geo.thumb_h / 2.0;
}

/// Map a pointer y (top-left px) plus drag offset to a target scroll_px.
pub fn scrollPxAt(geo: Geometry, py: f32, drag_offset: f32) f32 {
    const usable = @max(1.0, geo.track_h - geo.thumb_h);
    const frac = std.math.clamp((py - geo.track_top_px - drag_offset) / usable, 0.0, 1.0);
    return frac * geo.max_scroll;
}

/// Fade opacity for the scrollbar. `held` is true while hovering or dragging.
/// `show_time` is the last time the bar was shown (ms); 0 means never shown.
pub fn fadeOpacity(show_time: i64, now: i64, held: bool) f32 {
    if (held) return 1.0;
    if (show_time <= 0) return 0;
    const elapsed = now - show_time;
    if (elapsed < FADE_DELAY_MS) return 1.0;
    const fade_elapsed = elapsed - FADE_DELAY_MS;
    if (fade_elapsed >= FADE_DURATION_MS) return 0;
    return 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(FADE_DURATION_MS));
}

test "geometry returns null when content fits" {
    try std.testing.expect(geometry(0, 400, 100, 200, 150, 0) == null);
    try std.testing.expect(geometry(0, 400, 100, 200, 200, 0) == null);
}

test "geometry thumb is proportional and clamps to MIN_THUMB" {
    const geo = geometry(0, 400, 100, 200, 400, 0).?;
    try std.testing.expectEqual(@as(f32, 388), geo.track_x); // round(0+400-12)
    try std.testing.expectEqual(@as(f32, 200), geo.track_h);
    try std.testing.expectEqual(@as(f32, 100), geo.thumb_h); // 200 * (200/400)
    try std.testing.expectEqual(@as(f32, 200), geo.max_scroll);

    // Tiny visible ratio with a tall track still floors at MIN_THUMB.
    const small = geometry(0, 400, 100, 200, 100_000, 0).?;
    try std.testing.expectEqual(@as(f32, MIN_THUMB), small.thumb_h);
}

test "geometry thumb position tracks scroll_px" {
    const top = geometry(0, 400, 100, 200, 400, 0).?;
    try std.testing.expectEqual(@as(f32, 100), top.thumb_top_px); // at track top

    const bottom = geometry(0, 400, 100, 200, 400, 200).?;
    try std.testing.expectEqual(@as(f32, 200), bottom.thumb_top_px); // track_top + (track_h - thumb_h)

    const mid = geometry(0, 400, 100, 200, 400, 100).?;
    try std.testing.expectEqual(@as(f32, 150), mid.thumb_top_px);
}

test "hitTrack respects width, pad, and vertical bounds" {
    const geo = geometry(0, 400, 100, 200, 400, 0).?; // track_x=388, track 100..300
    try std.testing.expect(hitTrack(geo, 390, 150));
    try std.testing.expect(hitTrack(geo, 385, 150)); // within HIT_PAD on the left
    try std.testing.expect(!hitTrack(geo, 350, 150)); // too far left
    try std.testing.expect(!hitTrack(geo, 405, 150)); // too far right (track_x=388, WIDTH=12, HIT_PAD=4 → right bound 404)
    try std.testing.expect(!hitTrack(geo, 390, 90)); // above track
    try std.testing.expect(!hitTrack(geo, 390, 320)); // below track
}

test "thumbDragOffset uses press position on thumb, centers on bare track" {
    const geo = geometry(0, 400, 100, 200, 400, 0).?; // thumb 100..200, thumb_h=100
    try std.testing.expectEqual(@as(f32, 20), thumbDragOffset(geo, 120));
    try std.testing.expectEqual(@as(f32, 50), thumbDragOffset(geo, 250)); // thumb_h/2
}

test "scrollPxAt round-trips track extremes" {
    const geo = geometry(0, 400, 100, 200, 400, 0).?; // usable = 100, max_scroll=200
    try std.testing.expectEqual(@as(f32, 0), scrollPxAt(geo, 100, 0)); // drag to top
    try std.testing.expectEqual(@as(f32, 200), scrollPxAt(geo, 200, 0)); // drag to bottom
    try std.testing.expectEqual(@as(f32, 100), scrollPxAt(geo, 150, 0)); // middle
}

test "fadeOpacity: held, never-shown, full, mid-fade, gone" {
    try std.testing.expectEqual(@as(f32, 1.0), fadeOpacity(0, 5000, true)); // held overrides
    try std.testing.expectEqual(@as(f32, 0), fadeOpacity(0, 5000, false)); // never shown
    try std.testing.expectEqual(@as(f32, 1.0), fadeOpacity(1000, 1500, false)); // within delay
    try std.testing.expectEqual(@as(f32, 0.5), fadeOpacity(1000, 2000, false)); // halfway through fade
    try std.testing.expectEqual(@as(f32, 0), fadeOpacity(1000, 3000, false)); // fully faded
}
