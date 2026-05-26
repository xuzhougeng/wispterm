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

    pub fn start(self: *State, now_ms: i64) void {
        self.deadline_ms = now_ms + reset_ms;
    }

    pub fn stop(self: *State) void {
        self.deadline_ms = 0;
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
