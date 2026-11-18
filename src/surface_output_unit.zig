//! Surface PTY-output bookkeeping unit tests: authoritative OSC 7748 agent
//! markers and the dirty/wakeup dedupe used by termio/ReadThread.
const std = @import("std");
const Surface = @import("Surface.zig");

fn minimalAgentSurface(surface: *Surface) void {
    surface.allocator = std.testing.allocator;
    surface.title_override_len = 0;
    surface.osc7_title_len = 0;
    surface.window_title_len = 0;
    surface.agent_detection = .{};
    surface.agent_detection_shared = std.atomic.Value(u32).init(0);
    surface.agent_osc_active = false;
    surface.wispterm_image_osc_state = .ground;
    surface.wispterm_image_osc_buf = .empty;
    surface.wispterm_agent_osc_buf_len = 0;
}

test "feedVtWithWispTermImageFallback: OSC 7748 marker sets agent detection" {
    var surface: Surface = undefined;
    minimalAgentSurface(&surface);
    defer surface.wispterm_image_osc_buf.deinit(std.testing.allocator);

    surface.feedVtWithWispTermImageFallback("\x1b]7748;wispterm-agent;state=waiting_approval;app=codex\x07");
    try std.testing.expectEqual(.codex, surface.agent_detection.app);
    try std.testing.expectEqual(.waiting_approval, surface.agent_detection.state);
    try std.testing.expectEqual(@as(u8, 100), surface.agent_detection.confidence);
    try std.testing.expect(surface.agent_osc_active);
    // The cross-thread mirror follows the marker.
    try std.testing.expectEqual(surface.agent_detection, surface.agentDetectionShared());
}

test "setTitleOverride: legacy title text does not set agent detection" {
    var surface: Surface = undefined;
    minimalAgentSurface(&surface);
    defer surface.wispterm_image_osc_buf.deinit(std.testing.allocator);

    surface.setTitleOverride("[ * ] OpenAI Codex");
    try std.testing.expectEqual(.none, surface.agent_detection.app);
    try std.testing.expectEqual(.none, surface.agent_detection.state);
}

test "markOutputDirty: only the first mark since the UI consumed it requests a wakeup" {
    var surface: Surface = undefined;
    surface.dirty = std.atomic.Value(bool).init(false);
    surface.agent_screen = .{};

    try std.testing.expect(surface.markOutputDirty());
    try std.testing.expect(!surface.markOutputDirty());
    try std.testing.expect(surface.dirty.load(.acquire));
    // Every output chunk advances the screen-detection epoch.
    try std.testing.expectEqual(@as(u32, 2), surface.agent_screen.output_epoch.load(.monotonic));

    // UI consumed the dirty flag — next output chunk must post a wakeup again.
    _ = surface.dirty.swap(false, .acq_rel);
    try std.testing.expect(surface.markOutputDirty());
}

test "a synchronized frame in one chunk requests a wakeup at its end" {
    var surface: Surface = undefined;
    surface.dirty = std.atomic.Value(bool).init(false);
    surface.agent_screen = .{};
    surface.sync_output_state = .{};

    // The chunk holds a whole frame (`CSI ? 2026 h` … `CSI ? 2026 l`). Both
    // mode notifications mark the surface dirty while the chunk is parsed, so
    // the chunk's own dirty mark is no longer the first one and posts nothing.
    surface.noteSynchronizedOutputMode(true);
    surface.noteSynchronizedOutputMode(false);
    try std.testing.expect(!surface.markOutputDirty());

    // The frame end is what wakes the render loop — exactly once.
    try std.testing.expect(surface.takeSynchronizedFrameEndedLocked());
    try std.testing.expect(!surface.takeSynchronizedFrameEndedLocked());
}

test "a synchronized frame split across chunks requests a wakeup only at its end" {
    var surface: Surface = undefined;
    surface.dirty = std.atomic.Value(bool).init(false);
    surface.agent_screen = .{};
    surface.sync_output_state = .{};

    // Opening chunk: nothing can be drawn until the frame ends, so no wakeup.
    surface.noteSynchronizedOutputMode(true);
    _ = surface.markOutputDirty();
    try std.testing.expect(!surface.takeSynchronizedFrameEndedLocked());

    // Middle chunk: dirty stays latched (the render loop defers the frame
    // without consuming it), so it wakes nobody either.
    try std.testing.expect(!surface.markOutputDirty());
    try std.testing.expect(!surface.takeSynchronizedFrameEndedLocked());

    // Closing chunk: still deduped by the dirty flag; the frame end must ask.
    surface.noteSynchronizedOutputMode(false);
    try std.testing.expect(!surface.markOutputDirty());
    try std.testing.expect(surface.takeSynchronizedFrameEndedLocked());
}
