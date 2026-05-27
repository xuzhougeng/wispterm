//! Pure multi-click (double/triple/quad) counting state machine.
//! Extracted from input.zig's nextLeftClickCount so the logic is std-only and
//! unit-testable. input.zig owns one instance and supplies time/distance.
const std = @import("std");

pub const ClickTracker = struct {
    count: u8 = 0,
    time_ms: i64 = 0,
    x: f64 = 0,
    y: f64 = 0,

    /// Register a click at (x, y) occurring at now_ms. A click continues the
    /// streak only if it is within interval_ms of the previous click AND within
    /// max_distance pixels of it; otherwise the streak resets. The count cycles
    /// 1→2→3→4→1. Returns the new count.
    pub fn register(self: *ClickTracker, x: f64, y: f64, now_ms: i64, max_distance: f64, interval_ms: i64) u8 {
        const dx = x - self.x;
        const dy = y - self.y;
        const distance = @sqrt(dx * dx + dy * dy);
        const within_interval = self.count > 0 and now_ms - self.time_ms <= interval_ms;
        const within_distance = self.count > 0 and distance <= max_distance;
        if (!within_interval or !within_distance) self.count = 0;
        self.count += 1;
        if (self.count > 4) self.count = 1;
        self.time_ms = now_ms;
        self.x = x;
        self.y = y;
        return self.count;
    }

    pub fn reset(self: *ClickTracker) void {
        self.* = .{};
    }
};

const max_dist: f64 = 10;
const interval: i64 = 500; // matches MULTI_CLICK_INTERVAL_MS in input.zig

test "first click returns 1" {
    var t: ClickTracker = .{};
    try std.testing.expectEqual(@as(u8, 1), t.register(100, 100, 1000, max_dist, interval));
}

test "fast, near clicks increment to 2, 3, 4" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 2), t.register(101, 101, 1100, max_dist, interval));
    try std.testing.expectEqual(@as(u8, 3), t.register(102, 102, 1200, max_dist, interval));
    try std.testing.expectEqual(@as(u8, 4), t.register(103, 103, 1300, max_dist, interval));
}

test "fifth fast, near click wraps to 1" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    _ = t.register(100, 100, 1100, max_dist, interval);
    _ = t.register(100, 100, 1200, max_dist, interval);
    _ = t.register(100, 100, 1300, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 1), t.register(100, 100, 1400, max_dist, interval));
}

test "click beyond interval resets to 1" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 1), t.register(100, 100, 1000 + interval + 1, max_dist, interval));
}

test "click beyond distance resets to 1" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 1), t.register(100 + max_dist + 1, 100, 1050, max_dist, interval));
}

test "reset clears the streak" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    _ = t.register(100, 100, 1100, max_dist, interval);
    t.reset();
    try std.testing.expectEqual(@as(u8, 1), t.register(100, 100, 1200, max_dist, interval));
}

test "click exactly at interval boundary stays in streak" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 2), t.register(100, 100, 1000 + interval, max_dist, interval));
}

test "click exactly at distance boundary stays in streak" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 2), t.register(100 + max_dist, 100, 1050, max_dist, interval));
}
