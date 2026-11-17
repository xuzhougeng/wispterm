const std = @import("std");

/// DEC synchronized output (mode 2026) must not be allowed to leave the
/// terminal hidden forever if an application crashes before resetting it.
/// Ghostty uses the same 1 second safety reset.
pub const reset_ms: i64 = 1000;

pub const Poll = enum {
    inactive,
    pending,
    expired,
};

pub const State = struct {
    deadline_ms: i64 = 0,
    /// Latched when the application resets the mode, taken by the IO thread to
    /// post a wakeup for the finished frame. Nothing else wakes the render
    /// loop for it: PTY output posts one wakeup per dirty cycle, and that
    /// wakeup is already spent — by the mode notification itself, which marks
    /// the surface dirty before the chunk is accounted, or by an earlier chunk
    /// of a frame the render loop deferred without consuming dirty. Without
    /// this latch a synchronized frame is drawn only on the loop's idle
    /// timeout (~10 fps), and over SSH, where a frame spans several reads and
    /// the next one often starts before that timeout, it is dropped entirely.
    /// Ghostty wakes its renderer after every read, so it draws at the frame
    /// end the same way.
    frame_ended: bool = false,

    pub fn start(self: *State, now_ms: i64) void {
        self.deadline_ms = now_ms + reset_ms;
    }

    pub fn stop(self: *State) void {
        self.deadline_ms = 0;
    }

    /// The application reset the mode: the batched frame is complete. Latches
    /// even for a reset with no frame open, because that notification spends
    /// the chunk's wakeup just the same.
    pub fn end(self: *State) void {
        self.frame_ended = true;
        self.stop();
    }

    /// Returns true once per application-ended frame.
    pub fn takeFrameEnded(self: *State) bool {
        const ended = self.frame_ended;
        self.frame_ended = false;
        return ended;
    }

    pub fn poll(self: *State, mode_enabled: bool, now_ms: i64) Poll {
        if (!mode_enabled) {
            self.stop();
            return .inactive;
        }

        if (self.deadline_ms == 0) {
            self.start(now_ms);
        }

        if (now_ms >= self.deadline_ms) {
            self.stop();
            return .expired;
        }

        return .pending;
    }
};

test "synchronized output starts pending until deadline" {
    var state: State = .{};

    try std.testing.expectEqual(Poll.inactive, state.poll(false, 100));

    state.start(100);
    try std.testing.expectEqual(@as(i64, 1100), state.deadline_ms);
    try std.testing.expectEqual(Poll.pending, state.poll(true, 1099));
    try std.testing.expectEqual(Poll.expired, state.poll(true, 1100));
    try std.testing.expectEqual(@as(i64, 0), state.deadline_ms);
}

test "synchronized output recovers when mode is already enabled" {
    var state: State = .{};

    try std.testing.expectEqual(Poll.pending, state.poll(true, 50));
    try std.testing.expectEqual(@as(i64, 1050), state.deadline_ms);

    try std.testing.expectEqual(Poll.inactive, state.poll(false, 60));
    try std.testing.expectEqual(@as(i64, 0), state.deadline_ms);
}

test "ending a synchronized frame is reported once" {
    var state: State = .{};

    state.start(100);
    try std.testing.expect(!state.takeFrameEnded());

    state.end();
    try std.testing.expectEqual(@as(i64, 0), state.deadline_ms);
    try std.testing.expect(state.takeFrameEnded());
    try std.testing.expect(!state.takeFrameEnded());
}

test "a mode reset with no frame open still reports once" {
    var state: State = .{};

    state.end();
    try std.testing.expect(state.takeFrameEnded());
    try std.testing.expect(!state.takeFrameEnded());
}

test "watchdog expiry is not an application frame end" {
    var state: State = .{};

    state.start(100);
    try std.testing.expectEqual(Poll.expired, state.poll(true, 1100));
    try std.testing.expect(!state.takeFrameEnded());
}
