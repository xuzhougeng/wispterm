//! Pure throttle for the modal-resize-loop sync render. During a window border
//! drag, the platform delivers resize events far faster than a full
//! snapshot+rebuild+scene-draw+swap (see `AppWindow.renderResizeFrame`) can keep
//! up, so painting every event stutters. This caps the heavy render to at most one
//! per `MIN_INTERVAL_MS`. The drag's final size is always painted by the main loop
//! once the modal loop exits, so dropping intermediate events only costs a frame of
//! latency on the freshly exposed edge — never a stale final frame.
const std = @import("std");

/// ~60 Hz. Small enough that a live resize still looks smooth, large enough to
/// drop the redundant sub-frame resize-event storm (and the PTY resizes it drives).
pub const MIN_INTERVAL_MS: i64 = 16;

pub const ResizeThrottle = struct {
    /// Timestamp (ms) of the last render this throttle allowed. The `0` sentinel
    /// means "never rendered" — real `std.time.milliTimestamp()` values are huge,
    /// so they never collide with it (same pattern as `flush_scheduler`).
    last_render_ms: i64 = 0,

    /// Whether the heavy sync render should run for a WM_SIZE arriving at `now_ms`.
    /// The first tick always renders; afterwards we gate to `MIN_INTERVAL_MS`.
    pub fn shouldRender(self: *const ResizeThrottle, now_ms: i64) bool {
        if (self.last_render_ms == 0) return true;
        return now_ms - self.last_render_ms >= MIN_INTERVAL_MS;
    }

    /// Record that a render ran at `now_ms`, arming the next interval.
    pub fn noteRendered(self: *ResizeThrottle, now_ms: i64) void {
        self.last_render_ms = now_ms;
    }

    /// Re-arm so the next tick renders immediately (e.g. at a new drag's start).
    pub fn reset(self: *ResizeThrottle) void {
        self.last_render_ms = 0;
    }
};

test "first tick always renders" {
    const s: ResizeThrottle = .{};
    try std.testing.expect(s.shouldRender(1_000_000_000_000));
}

test "rapid ticks within the interval are throttled" {
    var s: ResizeThrottle = .{};
    const t0: i64 = 1_000_000_000_000;
    try std.testing.expect(s.shouldRender(t0));
    s.noteRendered(t0);
    // A tick 1ms later must be dropped.
    try std.testing.expect(!s.shouldRender(t0 + 1));
    // Right at the boundary it renders again.
    try std.testing.expect(s.shouldRender(t0 + MIN_INTERVAL_MS));
}

test "a tick past the interval renders again" {
    var s: ResizeThrottle = .{};
    const t0: i64 = 1_000_000_000_000;
    s.noteRendered(t0);
    try std.testing.expect(!s.shouldRender(t0 + MIN_INTERVAL_MS - 1));
    try std.testing.expect(s.shouldRender(t0 + MIN_INTERVAL_MS + 5));
}

test "reset re-arms the next tick" {
    var s: ResizeThrottle = .{};
    const t0: i64 = 1_000_000_000_000;
    s.noteRendered(t0);
    try std.testing.expect(!s.shouldRender(t0 + 1));
    s.reset();
    try std.testing.expect(s.shouldRender(t0 + 1));
}
