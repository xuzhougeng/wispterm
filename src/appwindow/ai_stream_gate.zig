//! Frame gate for an in-flight AI request (chat tab, Copilot sidebar, btw
//! overlay). Pure logic, zero project dependencies; in the fast test suite.
//!
//! Before this gate the render loop treated `request_inflight` itself as a
//! render signal, so for the whole lifetime of a request — including minutes
//! spent waiting on a tool-approval dialog or a long `exec` tool — the loop
//! never blocked and repainted the full window at display refresh rate
//! (60–120 fps) with nothing changing. Ghostty never renders on a timer like
//! that: its renderer wakes when the terminal state changes.
//!
//! Now a frame is produced when the session reports a UI change
//! (`Session.markUiDirty`, set by the request thread after each streamed
//! delta / status / tool card, which also wakes the loop), plus a slow
//! heartbeat while a request is in flight as a safety net for any mutation
//! path that forgot to mark itself. The heartbeat is deliberately well below
//! the old frame rate: 2 fps instead of 60–120.
const std = @import("std");

/// While a request is in flight and nothing marked itself dirty, repaint at
/// most this often. Also bounds how stale a missed `markUiDirty` can look.
pub const HEARTBEAT_MS: i64 = 500;

pub const State = struct {
    /// Timestamp of the last frame this gate asked for.
    last_frame_ms: i64 = 0,
};

pub const Inputs = struct {
    /// Any displayed session has `request_inflight` set.
    inflight: bool,
    /// Any displayed session reported a UI change since the last frame.
    dirty: bool,
    now_ms: i64,
};

/// True when the AI surfaces need a frame this iteration.
pub fn needsFrame(state: *State, in: Inputs) bool {
    if (in.dirty) {
        state.last_frame_ms = in.now_ms;
        return true;
    }
    if (!in.inflight) return false;
    if (in.now_ms - state.last_frame_ms >= HEARTBEAT_MS) {
        state.last_frame_ms = in.now_ms;
        return true;
    }
    return false;
}

test "idle session never asks for a frame" {
    var s = State{};
    try std.testing.expect(!needsFrame(&s, .{ .inflight = false, .dirty = false, .now_ms = 1000 }));
    try std.testing.expect(!needsFrame(&s, .{ .inflight = false, .dirty = false, .now_ms = 99_000 }));
}

test "a UI change renders at once, in flight or not" {
    var s = State{};
    try std.testing.expect(needsFrame(&s, .{ .inflight = true, .dirty = true, .now_ms = 1000 }));
    // The request just finished: its final state must still paint.
    try std.testing.expect(needsFrame(&s, .{ .inflight = false, .dirty = true, .now_ms = 1001 }));
}

test "in flight without changes renders only on the heartbeat" {
    var s = State{};
    try std.testing.expect(needsFrame(&s, .{ .inflight = true, .dirty = true, .now_ms = 1000 }));
    // Back-to-back loop iterations with nothing new: no frame (this was the
    // 60–120 fps spin).
    try std.testing.expect(!needsFrame(&s, .{ .inflight = true, .dirty = false, .now_ms = 1008 }));
    try std.testing.expect(!needsFrame(&s, .{ .inflight = true, .dirty = false, .now_ms = 1000 + HEARTBEAT_MS - 1 }));
    try std.testing.expect(needsFrame(&s, .{ .inflight = true, .dirty = false, .now_ms = 1000 + HEARTBEAT_MS }));
    try std.testing.expect(!needsFrame(&s, .{ .inflight = true, .dirty = false, .now_ms = 1000 + HEARTBEAT_MS + 1 }));
}

test "a dirty frame resets the heartbeat" {
    var s = State{};
    _ = needsFrame(&s, .{ .inflight = true, .dirty = false, .now_ms = 5000 });
    try std.testing.expect(needsFrame(&s, .{ .inflight = true, .dirty = true, .now_ms = 5400 }));
    try std.testing.expect(!needsFrame(&s, .{ .inflight = true, .dirty = false, .now_ms = 5400 + HEARTBEAT_MS - 1 }));
    try std.testing.expect(needsFrame(&s, .{ .inflight = true, .dirty = false, .now_ms = 5400 + HEARTBEAT_MS }));
}
