//! Bookkeeping for the DXGI frame-latency waitable object.
//!
//! The waitable behaves like a semaphore with one permit per frame the
//! swapchain may queue (WispTerm sets the maximum frame latency to 1). A wait
//! that succeeds takes the permit, and DXGI hands it back only after a
//! `Present`. A frame that waits and then never presents — the main loop defers
//! a frame while an application holds synchronized output, and `present` skips
//! while a resize or device recreate is pending — therefore keeps the permit.
//! Waiting again would block the UI thread for the whole timeout (issue #717:
//! one second per scroll step of a TUI that wraps its frames in `CSI ? 2026`).
//!
//! Ghostty's renderer has the same contract on its own swap chain
//! (`renderer/generic.zig`): `nextFrame` "must always be paired with a call to
//! `releaseFrame`", and it checks synchronized output before acquiring a frame.
//! DXGI gives no way to hand a permit back without presenting, so WispTerm
//! remembers that it still holds one instead.

const std = @import("std");

/// Upper bound for one wait. Only reached when DXGI stops retiring frames
/// (occluded window, display off) or a permit was lost some other way.
pub const wait_timeout_ms: u32 = 1000;

pub const FrameSlot = struct {
    /// A wait succeeded and no `Present` has returned the permit since.
    held: bool = false,

    /// Whether the next frame must wait on the waitable before rendering.
    pub fn needsWait(self: FrameSlot) bool {
        return !self.held;
    }

    /// The waitable was signaled: this frame owns the permit. A timed-out or
    /// failed wait took nothing and must not be reported here.
    pub fn noteAcquired(self: *FrameSlot) void {
        self.held = true;
    }

    /// A `Present` succeeded; DXGI signals the waitable again once that frame
    /// leaves the queue.
    pub fn notePresented(self: *FrameSlot) void {
        self.held = false;
    }
};

test "a frame that presents waits again for the next one" {
    var slot: FrameSlot = .{};
    try std.testing.expect(slot.needsWait());
    slot.noteAcquired();
    slot.notePresented();
    try std.testing.expect(slot.needsWait());
}

test "a frame abandoned after its wait keeps the slot for the next frame" {
    var slot: FrameSlot = .{};
    try std.testing.expect(slot.needsWait());
    slot.noteAcquired();

    // Deferred (synchronized output pending) or present skipped: no Present, so
    // the waitable stays unsignaled and the next frames must not wait on it.
    try std.testing.expect(!slot.needsWait());
    try std.testing.expect(!slot.needsWait());

    slot.notePresented();
    try std.testing.expect(slot.needsWait());
}
