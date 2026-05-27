//! Pure debounce state machine for the agent-history store flush, extracted
//! from AppWindow.zig. The caller owns the mutex/store/IO; this owns only the
//! "is a write due?" decision over a dirty flag + a debounce deadline.
const std = @import("std");

pub const DEBOUNCE_MS: i64 = 350;

pub const FlushScheduler = struct {
    dirty: bool = false,
    next_flush_ms: i64 = 0,

    /// Mark the store dirty. On the clean→dirty transition, arm the debounce.
    pub fn markDirty(self: *FlushScheduler, now_ms: i64) void {
        if (!self.dirty) {
            self.dirty = true;
            self.next_flush_ms = now_ms + DEBOUNCE_MS;
        }
    }

    /// Whether a flush should run now: dirty AND (forced OR the debounce elapsed).
    pub fn shouldFlush(self: *const FlushScheduler, force: bool, now_ms: i64) bool {
        if (!self.dirty) return false;
        if (!force and now_ms < self.next_flush_ms) return false;
        return true;
    }

    /// A flush is starting and has captured a snapshot: clear the dirty state.
    pub fn beginFlush(self: *FlushScheduler) void {
        self.dirty = false;
        self.next_flush_ms = 0;
    }

    /// A transient error BEFORE the snapshot (snapshot/path build failed): stay
    /// dirty, re-arm the debounce.
    pub fn deferFlush(self: *FlushScheduler, now_ms: i64) void {
        self.next_flush_ms = now_ms + DEBOUNCE_MS;
    }

    /// The flush write failed: re-mark dirty (if cleared) and re-arm.
    pub fn failFlush(self: *FlushScheduler, now_ms: i64) void {
        if (!self.dirty) {
            self.dirty = true;
            self.next_flush_ms = now_ms + DEBOUNCE_MS;
        }
    }

    pub fn reset(self: *FlushScheduler) void {
        self.dirty = false;
        self.next_flush_ms = 0;
    }
};

test "clean scheduler never flushes" {
    var s: FlushScheduler = .{};
    try std.testing.expect(!s.shouldFlush(false, 1000));
    try std.testing.expect(!s.shouldFlush(true, 1000));
}

test "markDirty arms a debounce window" {
    var s: FlushScheduler = .{};
    s.markDirty(1000);
    try std.testing.expect(s.dirty);
    try std.testing.expectEqual(@as(i64, 1000 + DEBOUNCE_MS), s.next_flush_ms);
    try std.testing.expect(!s.shouldFlush(false, 1000));
    try std.testing.expect(s.shouldFlush(true, 1000));
    try std.testing.expect(s.shouldFlush(false, 1000 + DEBOUNCE_MS));
}

test "markDirty does not re-arm while already dirty" {
    var s: FlushScheduler = .{};
    s.markDirty(1000);
    s.markDirty(1200);
    try std.testing.expectEqual(@as(i64, 1000 + DEBOUNCE_MS), s.next_flush_ms);
}

test "beginFlush clears; failFlush and deferFlush re-arm" {
    var s: FlushScheduler = .{};
    s.markDirty(1000);
    s.beginFlush();
    try std.testing.expect(!s.dirty);
    try std.testing.expect(!s.shouldFlush(true, 5000));
    s.failFlush(2000);
    try std.testing.expect(s.dirty);
    try std.testing.expectEqual(@as(i64, 2000 + DEBOUNCE_MS), s.next_flush_ms);
    s.deferFlush(3000);
    try std.testing.expect(s.dirty);
    try std.testing.expectEqual(@as(i64, 3000 + DEBOUNCE_MS), s.next_flush_ms);
}

test "reset clears everything" {
    var s: FlushScheduler = .{};
    s.markDirty(1000);
    s.reset();
    try std.testing.expect(!s.dirty);
    try std.testing.expectEqual(@as(i64, 0), s.next_flush_ms);
}
