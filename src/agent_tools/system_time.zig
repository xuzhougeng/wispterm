//! Read the host clock only when the model asks. Keeping this out of the
//! system prompt preserves the stable request prefix for provider caching.
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");
const local_time = @import("../terminal_agents/sessions/time.zig");

const SECONDS_PER_DAY: i64 = 86_400;

pub fn now(allocator: std.mem.Allocator) ![]u8 {
    return format(allocator, std.time.milliTimestamp(), local_time.localOffsetSeconds());
}

fn format(allocator: std.mem.Allocator, now_ms: i64, offset_seconds: i32) ![]u8 {
    const local_seconds = @divFloor(now_ms, 1000) + @as(i64, offset_seconds);
    const seconds_today: u64 = @intCast(@mod(local_seconds, SECONDS_PER_DAY));
    const date = ai_types.dateKeyFromMs(now_ms, offset_seconds);
    const offset_minutes: i32 = @divTrunc(offset_seconds, 60);
    const offset_abs: u32 = @abs(offset_minutes);
    return std.fmt.allocPrint(
        allocator,
        "Current local system time: {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC{c}{d:0>2}:{d:0>2} (Unix ms: {d}).",
        .{
            date / 10000,
            date / 100 % 100,
            date % 100,
            @divFloor(seconds_today, 3600),
            @divFloor(@mod(seconds_today, 3600), 60),
            @mod(seconds_today, 60),
            @as(u8, if (offset_minutes < 0) '-' else '+'),
            @divFloor(offset_abs, 60),
            @mod(offset_abs, 60),
            now_ms,
        },
    );
}

test "system_time: formats local clock with numeric UTC offset" {
    const text = try format(std.testing.allocator, 1_780_315_200_000, 8 * 3600); // 2026-06-01 12:00 UTC
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Current local system time: 2026-06-01 20:00:00 UTC+08:00 (Unix ms: 1780315200000).", text);
}
