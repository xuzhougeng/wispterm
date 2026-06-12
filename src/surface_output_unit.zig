//! Surface PTY-output bookkeeping unit tests: agent-detection throttling and
//! the dirty/wakeup dedupe used by termio/ReadThread. Follows the
//! kitty_graphics_unit.zig pattern (stack Surface with only the touched fields
//! initialized) so these run headless in the full app test binary.
const std = @import("std");
const Surface = @import("Surface.zig");
const agent_detect_throttle = @import("agent_detect_throttle.zig");

const interval = agent_detect_throttle.Throttle.interval_ms;

fn minimalAgentSurface(surface: *Surface) void {
    surface.title_override_len = 0;
    surface.osc7_title_len = 0;
    surface.window_title_len = 0;
    surface.agent_detection = .{};
    surface.agent_recent_output_len = 0;
    surface.agent_throttle = .{};
}

test "noteAgentOutputAt: first chunk detects immediately" {
    var surface: Surface = undefined;
    minimalAgentSurface(&surface);

    surface.noteAgentOutputAt("claude code session\n", 1000);
    try std.testing.expectEqual(.claude_code, surface.agent_detection.app);
}

test "noteAgentOutputAt: chunks within the interval defer detection, flush catches up" {
    var surface: Surface = undefined;
    minimalAgentSurface(&surface);

    surface.noteAgentOutputAt("claude code session\n", 1000);
    try std.testing.expectEqual(.claude_code, surface.agent_detection.app);

    // A flood chunk that overwrites the whole ring with plain text arrives
    // inside the throttle interval: the ring updates but detection is deferred.
    const flood = "x" ** 4200;
    surface.noteAgentOutputAt(flood, 1000 + interval - 1);
    try std.testing.expectEqual(.claude_code, surface.agent_detection.app);
    try std.testing.expect(surface.agent_throttle.pendingPeek());

    // Too early: flush refuses, detection still stale.
    try std.testing.expect(!surface.flushAgentDetection(1000 + interval - 1));

    // After the interval the deferred detection runs on the current ring.
    try std.testing.expect(surface.flushAgentDetection(1000 + 2 * interval));
    try std.testing.expectEqual(.none, surface.agent_detection.app);
    try std.testing.expect(!surface.agent_throttle.pendingPeek());
}

test "noteAgentOutputAt: detection resumes once the interval has elapsed" {
    var surface: Surface = undefined;
    minimalAgentSurface(&surface);

    const flood = "x" ** 4200;
    surface.noteAgentOutputAt(flood, 1000);
    try std.testing.expectEqual(.none, surface.agent_detection.app);

    surface.noteAgentOutputAt("claude code session\n", 1000 + interval);
    try std.testing.expectEqual(.claude_code, surface.agent_detection.app);
}

test "markOutputDirty: only the first mark since the UI consumed it requests a wakeup" {
    var surface: Surface = undefined;
    surface.dirty = std.atomic.Value(bool).init(false);

    try std.testing.expect(surface.markOutputDirty());
    try std.testing.expect(!surface.markOutputDirty());
    try std.testing.expect(surface.dirty.load(.acquire));

    // UI consumed the dirty flag — next output chunk must post a wakeup again.
    _ = surface.dirty.swap(false, .acq_rel);
    try std.testing.expect(surface.markOutputDirty());
}
