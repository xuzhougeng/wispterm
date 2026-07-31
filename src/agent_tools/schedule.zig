//! Agent scheduling tools.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const tool_args = @import("args.zig");
const ai_loop_schedule = @import("../assistant/loop/schedule.zig");

const ToolContext = types.ToolContext;

const DEFAULT_CONTINUATION_MESSAGE =
    "Continue the previous task. First inspect the terminal with terminal_snapshot, then report progress.";

pub fn run(ctx: *ToolContext, arguments: []const u8) ![]u8 {
    const parsed = tool_args.parse(ctx.allocator, arguments) orelse
        return ctx.allocator.dupe(u8, "Invalid tool arguments");
    defer parsed.deinit();

    const delay_text = tool_args.string(parsed.value, "delay") orelse
        return ctx.allocator.dupe(u8, "Bad delay. Use a positive interval like 30m, 2h, or 1d.");
    const delay_ms = ai_loop_schedule.parseIntervalMs(delay_text) catch
        return ctx.allocator.dupe(u8, "Bad delay. Use a positive interval like 30m, 2h, or 1d.");

    const message = tool_args.string(parsed.value, "message") orelse DEFAULT_CONTINUATION_MESSAGE;

    const id = ctx.scheduleContinuation(delay_ms, message) catch |err| switch (err) {
        error.NoScheduler => return ctx.allocator.dupe(u8, "Scheduler is not available."),
        error.NoScheduleContext => return ctx.allocator.dupe(u8, "Scheduler context is not available."),
        else => return err,
    };
    const display = ai_loop_schedule.formatInterval(delay_ms);
    return std.fmt.allocPrint(ctx.allocator, "Scheduled continuation #{d} in {d}{c}.", .{
        id,
        display.value,
        display.unit,
    });
}

var test_dummy_ctx: u8 = 0;

const FakeScheduler = struct {
    var calls: u32 = 0;
    var last_delay_ms: i64 = 0;
    var last_message_buf: [256]u8 = undefined;
    var last_message_len: usize = 0;
    var last_session_buf: [64]u8 = undefined;
    var last_session_len: usize = 0;

    fn reset() void {
        calls = 0;
        last_delay_ms = 0;
        last_message_len = 0;
        last_session_len = 0;
    }

    fn schedule(_: *anyopaque, schedule_context: types.ScheduleContext, delay_ms: i64, message: []const u8) anyerror!u32 {
        calls += 1;
        last_delay_ms = delay_ms;
        last_message_len = @min(message.len, last_message_buf.len);
        @memcpy(last_message_buf[0..last_message_len], message[0..last_message_len]);
        last_session_len = @min(schedule_context.session_id.len, last_session_buf.len);
        @memcpy(last_session_buf[0..last_session_len], schedule_context.session_id[0..last_session_len]);
        return 42;
    }
};

fn approve(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}

fn cancelled(_: *anyopaque) bool {
    return false;
}

fn testContext(schedule: ?types.ScheduleContext, callback: ?types.ScheduleContinuationFn) ToolContext {
    return .{
        .allocator = std.testing.allocator,
        .ctx = &test_dummy_ctx,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .schedule_context = schedule,
        .schedule_continuation = callback,
        .approve = approve,
        .cancelled = cancelled,
    };
}

test "continue_later rejects invalid delay before touching scheduler" {
    FakeScheduler.reset();
    var ctx = testContext(.{ .session_id = "s", .model = "m", .title = "t" }, FakeScheduler.schedule);
    const out = try run(&ctx, "{\"delay\":\"soon\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Bad delay. Use a positive interval like 30m, 2h, or 1d.", out);
    try std.testing.expectEqual(@as(u32, 0), FakeScheduler.calls);
}

test "continue_later requires scheduler callback" {
    FakeScheduler.reset();
    var ctx = testContext(.{ .session_id = "session-tool", .model = "m", .title = "Tool Session" }, null);
    const out = try run(&ctx, "{\"delay\":\"30m\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Scheduler is not available.", out);
    try std.testing.expectEqual(@as(u32, 0), FakeScheduler.calls);
}

test "continue_later requires schedule context" {
    FakeScheduler.reset();
    var ctx = testContext(null, FakeScheduler.schedule);
    const out = try run(&ctx, "{\"delay\":\"30m\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Scheduler context is not available.", out);
    try std.testing.expectEqual(@as(u32, 0), FakeScheduler.calls);
}

test "continue_later schedules through callback" {
    FakeScheduler.reset();
    var ctx = testContext(.{ .session_id = "session-tool", .model = "m", .title = "Tool Session" }, FakeScheduler.schedule);
    const out = try run(&ctx, "{\"delay\":\"30m\",\"message\":\"check progress\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Scheduled continuation #42 in 30m.", out);
    try std.testing.expectEqual(@as(u32, 1), FakeScheduler.calls);
    try std.testing.expectEqual(@as(i64, 30 * std.time.ms_per_min), FakeScheduler.last_delay_ms);
    try std.testing.expectEqualStrings("check progress", FakeScheduler.last_message_buf[0..FakeScheduler.last_message_len]);
    try std.testing.expectEqualStrings("session-tool", FakeScheduler.last_session_buf[0..FakeScheduler.last_session_len]);
}
