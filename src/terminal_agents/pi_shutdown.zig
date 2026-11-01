const std = @import("std");

/// Coordinates a confirmed WispTerm window close with Pi's deferred
/// `/wispterm-shutdown` command. It owns only lifecycle state; tab traversal and
/// PTY writes remain in the terminal-agent/tab domain.
pub const Coordinator = struct {
    close_requested: bool = false,
    pending: bool = false,
    deadline_ms: i64 = 0,
    requested_count: usize = 0,

    pub const Outcome = enum { idle, waiting, ready, timed_out };

    pub fn request(self: *Coordinator) void {
        self.close_requested = true;
    }

    pub fn hasRequest(self: *const Coordinator) bool {
        return self.close_requested;
    }

    pub fn isPending(self: *const Coordinator) bool {
        return self.pending;
    }

    pub fn begin(self: *Coordinator, now_ms: i64, timeout_ms: i64, requested_count: usize) bool {
        if (!self.close_requested or self.pending or requested_count == 0) return false;
        self.close_requested = false;
        self.pending = true;
        self.deadline_ms = now_ms + timeout_ms;
        self.requested_count = requested_count;
        return true;
    }

    pub fn consumeImmediateClose(self: *Coordinator) bool {
        if (!self.close_requested or self.pending) return false;
        self.close_requested = false;
        return true;
    }

    pub fn tick(self: *Coordinator, now_ms: i64, all_exited: bool) Outcome {
        if (!self.pending) return .idle;
        if (all_exited) {
            self.pending = false;
            self.requested_count = 0;
            return .ready;
        }
        if (now_ms >= self.deadline_ms) {
            self.pending = false;
            self.requested_count = 0;
            return .timed_out;
        }
        return .waiting;
    }
};

test "Pi shutdown coordinator waits, completes, and times out" {
    var coordinator: Coordinator = .{};
    coordinator.request();
    try std.testing.expect(coordinator.begin(100, 500, 1));
    try std.testing.expectEqual(Coordinator.Outcome.waiting, coordinator.tick(200, false));
    try std.testing.expectEqual(Coordinator.Outcome.ready, coordinator.tick(300, true));
    try std.testing.expectEqual(Coordinator.Outcome.idle, coordinator.tick(301, true));

    coordinator.request();
    try std.testing.expect(coordinator.begin(1000, 500, 2));
    try std.testing.expectEqual(Coordinator.Outcome.timed_out, coordinator.tick(1500, false));
}

test "Pi shutdown coordinator closes immediately when no capable Pi exists" {
    var coordinator: Coordinator = .{};
    coordinator.request();
    try std.testing.expect(!coordinator.begin(0, 500, 0));
    try std.testing.expect(coordinator.consumeImmediateClose());
    try std.testing.expectEqual(Coordinator.Outcome.idle, coordinator.tick(500, true));
}
