//! Timing text for a finished AI turn: the "Done in" status and the usage
//! footer under the reply. Time the turn spent blocked on the user (an
//! `ask_user` question card) is not the model's time, so it is left out of
//! the elapsed time and the token rate and reported on its own. Pure leaf
//! (fast suite); session.zig only passes the numbers in.
const std = @import("std");

pub const FOOTER_MAX = 256;

pub const Timing = struct {
    /// Request start (milliTimestamp); <= 0 when unknown.
    started_ms: i64,
    finished_ms: i64,
    /// First streamed token; 0 when the turn did not stream.
    first_token_ms: i64 = 0,
    /// Time spent waiting for the user to answer inside this turn.
    user_wait_ms: i64 = 0,

    /// Wall time minus the user wait, never negative.
    pub fn activeMs(self: Timing) i64 {
        return @max(@as(i64, 0), self.finished_ms - self.started_ms - @max(@as(i64, 0), self.user_wait_ms));
    }
};

pub fn tokenRateTenths(completion_tokens: u64, elapsed_ms: i64) ?u64 {
    if (completion_tokens == 0 or elapsed_ms <= 0) return null;
    const elapsed: u128 = @intCast(elapsed_ms);
    const rate = (@as(u128, completion_tokens) * 10_000 + elapsed / 2) / elapsed;
    return @intCast(@min(rate, std.math.maxInt(u64)));
}

/// "Done in 2.3s" (active time), "Done" without a start, "Ready" with neither
/// a start nor usage.
pub fn formatDoneStatus(buf: []u8, timing: Timing, has_usage: bool) []const u8 {
    if (timing.started_ms <= 0) return if (has_usage) "Done" else "Ready";
    const ms = timing.activeMs();
    return std.fmt.bufPrint(buf, "Done in {d}.{d}s", .{ @divTrunc(ms, 1000), tenths(ms) }) catch "Ready";
}

/// "time 2.5s | answer wait 20.1s | first 0.8s | 14.8 token/s | total 46 | ..."
/// `usage` is any struct with ApiUsage's token fields. Segments without data
/// (no start, no wait, no first token, no rate) are left out.
pub fn formatFooter(buf: []u8, timing: Timing, usage: anytype) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeFooter(&w, timing, usage) catch return "usage unavailable";
    return w.buffered();
}

fn writeFooter(w: *std.Io.Writer, timing: Timing, u: anytype) !void {
    if (timing.started_ms > 0) {
        const active = timing.activeMs();
        try w.print("time {d}.{d}s | ", .{ @divTrunc(active, 1000), tenths(active) });
        if (timing.user_wait_ms > 0) {
            try w.print("answer wait {d}.{d}s | ", .{ @divTrunc(timing.user_wait_ms, 1000), tenths(timing.user_wait_ms) });
        }
        if (timing.first_token_ms > 0) {
            const first = @max(@as(i64, 0), timing.first_token_ms - timing.started_ms);
            try w.print("first {d}.{d}s | ", .{ @divTrunc(first, 1000), tenths(first) });
        }
        if (tokenRateTenths(u.completion_tokens, active)) |rate| {
            try w.print("{d}.{d} token/s | ", .{ rate / 10, rate % 10 });
        }
    }
    try w.print("total {d} | input {d} | output {d} | cache {d}/{d}", .{
        u.total_tokens,
        u.prompt_tokens,
        u.completion_tokens,
        u.prompt_cache_hit_tokens,
        u.prompt_cache_miss_tokens,
    });
}

fn tenths(ms: i64) i64 {
    return @divTrunc(@mod(ms, 1000), 100);
}

const TestUsage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    prompt_cache_hit_tokens: u64 = 0,
    prompt_cache_miss_tokens: u64 = 0,
    total_tokens: u64 = 0,
};

const sample_usage = TestUsage{
    .prompt_tokens = 12,
    .completion_tokens = 34,
    .prompt_cache_hit_tokens = 5,
    .prompt_cache_miss_tokens = 7,
    .total_tokens = 46,
};

test "usage footer includes time token and cache fields" {
    var buf: [FOOTER_MAX]u8 = undefined;
    const footer = formatFooter(&buf, .{ .started_ms = 1000, .first_token_ms = 1800, .finished_ms = 3300 }, sample_usage);
    try std.testing.expectEqualStrings(
        "time 2.3s | first 0.8s | 14.8 token/s | total 46 | input 12 | output 34 | cache 5/7",
        footer,
    );
}

test "usage footer without a start shows only token counts" {
    var buf: [FOOTER_MAX]u8 = undefined;
    const footer = formatFooter(&buf, .{ .started_ms = 0, .finished_ms = 3300 }, sample_usage);
    try std.testing.expectEqualStrings("total 46 | input 12 | output 34 | cache 5/7", footer);
}

test "answer wait is excluded from time and token rate and shown on its own" {
    var buf: [FOOTER_MAX]u8 = undefined;
    // 35.3s wall clock, 30.0s of it on the question card: 5.3s of model time.
    const footer = formatFooter(&buf, .{ .started_ms = 1000, .finished_ms = 36_300, .user_wait_ms = 30_000 }, TestUsage{
        .completion_tokens = 53,
        .total_tokens = 53,
    });
    try std.testing.expectEqualStrings(
        "time 5.3s | answer wait 30.0s | 10.0 token/s | total 53 | input 0 | output 53 | cache 0/0",
        footer,
    );
}

test "done status counts active time only" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Done in 5.3s", formatDoneStatus(&buf, .{ .started_ms = 1000, .finished_ms = 36_300, .user_wait_ms = 30_000 }, true));
    try std.testing.expectEqualStrings("Done in 2.3s", formatDoneStatus(&buf, .{ .started_ms = 1000, .finished_ms = 3300 }, false));
    try std.testing.expectEqualStrings("Done", formatDoneStatus(&buf, .{ .started_ms = 0, .finished_ms = 3300 }, true));
    try std.testing.expectEqualStrings("Ready", formatDoneStatus(&buf, .{ .started_ms = 0, .finished_ms = 3300 }, false));
}

test "a wait longer than the wall clock clamps active time to zero" {
    const timing = Timing{ .started_ms = 1000, .finished_ms = 2000, .user_wait_ms = 5000 };
    try std.testing.expectEqual(@as(i64, 0), timing.activeMs());
    try std.testing.expectEqual(@as(?u64, null), tokenRateTenths(10, timing.activeMs()));
}
