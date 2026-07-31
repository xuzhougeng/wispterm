//! Pure (std-only) schedule engine for the /loop and /watch AI-chat commands.
//! No I/O, no Session, no globals. The caller passes the current time (`now_ms`,
//! ms since epoch) and the local UTC offset (`offset_s`, seconds); nothing here
//! reads the clock or the timezone. The runtime store (store.zig) is the
//! I/O layer over this.
const std = @import("std");

pub const ParseError = error{
    MissingArgs,
    BadInterval,
    BadCount,
    BadTime,
    PastTime,
    EmptyPrompt,
};

/// "<positive int><unit>" where unit is s|m|h|d -> milliseconds.
pub fn parseIntervalMs(tok: []const u8) ParseError!i64 {
    if (tok.len < 2) return error.BadInterval;
    const unit = tok[tok.len - 1];
    const n = std.fmt.parseInt(i64, tok[0 .. tok.len - 1], 10) catch return error.BadInterval;
    if (n <= 0) return error.BadInterval;
    const mult: i64 = switch (unit) {
        's' => std.time.ms_per_s,
        'm' => std.time.ms_per_min,
        'h' => std.time.ms_per_hour,
        'd' => std.time.ms_per_day,
        else => return error.BadInterval,
    };
    return n * mult;
}

/// Positive decimal integer -> u32 (0 rejected).
pub fn parseCount(tok: []const u8) ParseError!u32 {
    const n = std.fmt.parseInt(u32, tok, 10) catch return error.BadCount;
    if (n == 0) return error.BadCount;
    return n;
}

pub const LoopArgs = struct { interval_ms: i64, count: u32, prompt: []const u8 };
pub const WatchArgs = struct { daily: bool, tod_minutes: i32, next_fire_ms: i64, prompt: []const u8 };

pub fn parseLoopArgs(arg: []const u8) ParseError!LoopArgs {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    if (trimmed.len == 0) return error.MissingArgs;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const interval_tok = it.next() orelse return error.MissingArgs;
    const count_tok = it.next() orelse return error.MissingArgs;
    const interval_ms = try parseIntervalMs(interval_tok);
    const count = try parseCount(count_tok);
    const prompt = std.mem.trim(u8, trimmed[it.index..], " \t\r\n");
    if (prompt.len == 0) return error.EmptyPrompt;
    return .{ .interval_ms = interval_ms, .count = count, .prompt = prompt };
}

pub fn parseWatchArgs(arg: []const u8, now_ms: i64, offset_s: i32) ParseError!WatchArgs {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    if (trimmed.len == 0) return error.MissingArgs;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = it.next() orelse return error.MissingArgs;
    if (std.mem.indexOfScalar(u8, first, '-') != null) {
        const time_tok = it.next() orelse return error.BadTime;
        const abs = try parseAbsoluteMs(first, time_tok, offset_s);
        if (abs <= now_ms) return error.PastTime;
        const prompt = std.mem.trim(u8, trimmed[it.index..], " \t\r\n");
        if (prompt.len == 0) return error.EmptyPrompt;
        return .{ .daily = false, .tod_minutes = 0, .next_fire_ms = abs, .prompt = prompt };
    }
    const tod = try parseHourMinute(first);
    const next = nextDailyOccurrence(tod, now_ms, offset_s);
    const prompt = std.mem.trim(u8, trimmed[it.index..], " \t\r\n");
    if (prompt.len == 0) return error.EmptyPrompt;
    return .{ .daily = true, .tod_minutes = tod, .next_fire_ms = next, .prompt = prompt };
}

fn parseHourMinute(tok: []const u8) ParseError!i32 {
    const colon = std.mem.indexOfScalar(u8, tok, ':') orelse return error.BadTime;
    const hh = std.fmt.parseInt(i32, tok[0..colon], 10) catch return error.BadTime;
    const mm = std.fmt.parseInt(i32, tok[colon + 1 ..], 10) catch return error.BadTime;
    if (hh < 0 or hh > 23 or mm < 0 or mm > 59) return error.BadTime;
    return hh * 60 + mm;
}

fn parseAbsoluteMs(date_tok: []const u8, time_tok: []const u8, offset_s: i32) ParseError!i64 {
    var dit = std.mem.splitScalar(u8, date_tok, '-');
    const y = std.fmt.parseInt(i64, dit.next() orelse return error.BadTime, 10) catch return error.BadTime;
    const mo = std.fmt.parseInt(i64, dit.next() orelse return error.BadTime, 10) catch return error.BadTime;
    const d = std.fmt.parseInt(i64, dit.next() orelse return error.BadTime, 10) catch return error.BadTime;
    if (dit.next() != null) return error.BadTime;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return error.BadTime;
    const tod = try parseHourMinute(time_tok);
    const days = daysFromCivil(y, mo, d);
    const local_ms = (days * std.time.s_per_day + @as(i64, tod) * std.time.s_per_min) * std.time.ms_per_s;
    return local_ms - @as(i64, offset_s) * std.time.ms_per_s;
}

/// Days since 1970-01-01 for a proleptic-Gregorian date (Howard Hinnant).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Next UTC ms at which local time-of-day `tod_minutes` occurs (strictly future).
pub fn nextDailyOccurrence(tod_minutes: i32, now_ms: i64, offset_s: i32) i64 {
    const off_ms: i64 = @as(i64, offset_s) * std.time.ms_per_s;
    const local_now = now_ms + off_ms;
    const day_start = @divFloor(local_now, std.time.ms_per_day) * std.time.ms_per_day;
    var candidate = day_start + @as(i64, tod_minutes) * std.time.ms_per_min;
    if (candidate <= local_now) candidate += std.time.ms_per_day;
    return candidate - off_ms;
}

pub const IntervalDisplay = struct { value: i64, unit: u8 };

/// Render an interval back to its largest evenly-dividing unit for display
/// (e.g. 3_600_000 -> {1,'h'}, 1_000 -> {1,'s'}). Since intervals are entered as
/// a single `<int><unit>`, this recovers a natural, human-readable form and
/// avoids showing sub-minute intervals as "0m".
pub fn formatInterval(ms: i64) IntervalDisplay {
    if (ms != 0 and @rem(ms, std.time.ms_per_day) == 0) return .{ .value = @divTrunc(ms, std.time.ms_per_day), .unit = 'd' };
    if (ms != 0 and @rem(ms, std.time.ms_per_hour) == 0) return .{ .value = @divTrunc(ms, std.time.ms_per_hour), .unit = 'h' };
    if (ms != 0 and @rem(ms, std.time.ms_per_min) == 0) return .{ .value = @divTrunc(ms, std.time.ms_per_min), .unit = 'm' };
    return .{ .value = @divTrunc(ms, std.time.ms_per_s), .unit = 's' };
}

pub const TaskKind = enum { loop, watch };

pub const Task = struct {
    id: u32 = 0,
    kind: TaskKind,
    session_id: []const u8,
    model: []const u8 = "",
    title: []const u8 = "",
    prompt: []const u8,
    interval_ms: i64 = 0, // loop only
    remaining: u32 = 0, // loop: sends left. one-shot watch: 1 pending -> 0 done. daily: unused.
    daily: bool = false, // watch: true=recurring HH:MM, false=one-shot absolute
    tod_minutes: i32 = 0, // daily watch: minutes since local midnight
    next_fire_ms: i64 = 0,
    created_ms: i64 = 0,
};

pub fn isDue(t: *const Task, now_ms: i64) bool {
    return t.next_fire_ms <= now_ms;
}

pub fn isFinished(t: *const Task) bool {
    return switch (t.kind) {
        .loop => t.remaining == 0,
        .watch => if (t.daily) false else t.remaining == 0,
    };
}

pub fn advanceAfterFire(t: *Task, now_ms: i64, offset_s: i32) void {
    switch (t.kind) {
        .loop => {
            if (t.remaining > 0) t.remaining -= 1;
            t.next_fire_ms += t.interval_ms;
            if (t.next_fire_ms <= now_ms) t.next_fire_ms = now_ms + t.interval_ms; // drift guard
        },
        .watch => {
            if (t.daily) {
                t.next_fire_ms = nextDailyOccurrence(t.tod_minutes, now_ms, offset_s);
            } else {
                t.remaining = 0; // one-shot done
            }
        },
    }
}

/// Fix `next_fire_ms` on load: loop skips missed intervals (resume cadence),
/// daily watch -> next future occurrence, missed one-shot -> fire ASAP (now).
pub fn recomputeAfterRestart(t: *Task, now_ms: i64, offset_s: i32) void {
    switch (t.kind) {
        .loop => {
            if (t.next_fire_ms <= now_ms) t.next_fire_ms = now_ms + t.interval_ms;
        },
        .watch => {
            if (t.daily) {
                t.next_fire_ms = nextDailyOccurrence(t.tod_minutes, now_ms, offset_s);
            } else if (t.next_fire_ms <= now_ms) {
                t.next_fire_ms = now_ms;
            }
        },
    }
}

pub const FileModel = struct {
    version: u32 = 1,
    next_id: u32 = 1,
    tasks: []Task = &.{},
};

pub fn encode(allocator: std.mem.Allocator, model: FileModel) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, model, .{});
}

pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(FileModel) {
    return std.json.parseFromSlice(FileModel, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

// ---- Tests ----

test "parseIntervalMs accepts units s/m/h/d" {
    try std.testing.expectEqual(@as(i64, 30_000), try parseIntervalMs("30s"));
    try std.testing.expectEqual(@as(i64, 5 * 60_000), try parseIntervalMs("5m"));
    try std.testing.expectEqual(@as(i64, 2 * 3_600_000), try parseIntervalMs("2h"));
    try std.testing.expectEqual(@as(i64, 24 * 3_600_000), try parseIntervalMs("1d"));
}

test "parseIntervalMs rejects bad forms" {
    try std.testing.expectError(error.BadInterval, parseIntervalMs("5"));
    try std.testing.expectError(error.BadInterval, parseIntervalMs("h"));
    try std.testing.expectError(error.BadInterval, parseIntervalMs("0h"));
    try std.testing.expectError(error.BadInterval, parseIntervalMs("-3h"));
    try std.testing.expectError(error.BadInterval, parseIntervalMs("5x"));
}

test "parseCount" {
    try std.testing.expectEqual(@as(u32, 10), try parseCount("10"));
    try std.testing.expectError(error.BadCount, parseCount("0"));
    try std.testing.expectError(error.BadCount, parseCount("abc"));
    try std.testing.expectError(error.BadCount, parseCount("-1"));
}

test "parseLoopArgs splits interval, count, prompt" {
    const r = try parseLoopArgs("30m 8 检查 CI，把失败的测试贴出来");
    try std.testing.expectEqual(@as(i64, 30 * std.time.ms_per_min), r.interval_ms);
    try std.testing.expectEqual(@as(u32, 8), r.count);
    try std.testing.expectEqualStrings("检查 CI，把失败的测试贴出来", r.prompt);
}

test "parseLoopArgs errors" {
    try std.testing.expectError(error.MissingArgs, parseLoopArgs("   "));
    try std.testing.expectError(error.MissingArgs, parseLoopArgs("30m"));
    try std.testing.expectError(error.EmptyPrompt, parseLoopArgs("30m 8"));
    try std.testing.expectError(error.BadInterval, parseLoopArgs("30 8 hi"));
}

test "parseWatchArgs daily HH:MM" {
    // 2024-01-01 00:00 UTC = 1704067200000 ms; offset 0 for determinism.
    const now: i64 = 1_704_067_200_000;
    const r = try parseWatchArgs("09:00 生成早报", now, 0);
    try std.testing.expect(r.daily);
    try std.testing.expectEqual(@as(i32, 9 * 60), r.tod_minutes);
    try std.testing.expectEqual(now + 9 * std.time.ms_per_hour, r.next_fire_ms);
    try std.testing.expectEqualStrings("生成早报", r.prompt);
}

test "parseWatchArgs daily rolls to tomorrow when time passed" {
    const now: i64 = 1_704_067_200_000 + 10 * std.time.ms_per_hour; // 10:00 UTC
    const r = try parseWatchArgs("09:00 x", now, 0);
    try std.testing.expectEqual(1_704_067_200_000 + std.time.ms_per_day + 9 * std.time.ms_per_hour, r.next_fire_ms);
}

test "parseWatchArgs one-shot absolute" {
    const now: i64 = 1_704_067_200_000; // 2024-01-01 00:00 UTC
    const r = try parseWatchArgs("2024-01-02 09:30 提醒", now, 0);
    try std.testing.expect(!r.daily);
    try std.testing.expectEqual(1_704_067_200_000 + std.time.ms_per_day + 9 * std.time.ms_per_hour + 30 * std.time.ms_per_min, r.next_fire_ms);
    try std.testing.expectEqualStrings("提醒", r.prompt);
}

test "parseWatchArgs one-shot in the past errors" {
    const now: i64 = 1_704_067_200_000;
    try std.testing.expectError(error.PastTime, parseWatchArgs("2023-12-31 09:00 x", now, 0));
}

test "parseWatchArgs bad time" {
    try std.testing.expectError(error.BadTime, parseWatchArgs("25:00 x", 0, 0));
    try std.testing.expectError(error.BadTime, parseWatchArgs("09:99 x", 0, 0));
    try std.testing.expectError(error.MissingArgs, parseWatchArgs("   ", 0, 0));
}

fn fixtureLoop(remaining: u32, next_fire: i64) Task {
    return .{ .kind = .loop, .session_id = "s", .prompt = "p", .interval_ms = 30 * std.time.ms_per_min, .remaining = remaining, .next_fire_ms = next_fire };
}

test "isDue at boundary" {
    const t = fixtureLoop(3, 1000);
    try std.testing.expect(isDue(&t, 1000));
    try std.testing.expect(isDue(&t, 2000));
    try std.testing.expect(!isDue(&t, 999));
}

test "advanceAfterFire loop decrements and pushes interval" {
    var t = fixtureLoop(3, 1000);
    advanceAfterFire(&t, 1000, 0);
    try std.testing.expectEqual(@as(u32, 2), t.remaining);
    try std.testing.expectEqual(@as(i64, 1000 + 30 * std.time.ms_per_min), t.next_fire_ms);
    try std.testing.expect(!isFinished(&t));
}

test "advanceAfterFire loop reaching zero is finished" {
    var t = fixtureLoop(1, 1000);
    advanceAfterFire(&t, 1000, 0);
    try std.testing.expectEqual(@as(u32, 0), t.remaining);
    try std.testing.expect(isFinished(&t));
}

test "advanceAfterFire one-shot watch finishes" {
    var t = Task{ .kind = .watch, .session_id = "s", .prompt = "p", .daily = false, .remaining = 1, .next_fire_ms = 1000 };
    advanceAfterFire(&t, 1000, 0);
    try std.testing.expect(isFinished(&t));
}

test "advanceAfterFire daily watch rolls forward and never finishes" {
    var t = Task{ .kind = .watch, .session_id = "s", .prompt = "p", .daily = true, .tod_minutes = 9 * 60, .next_fire_ms = 1_704_067_200_000 + 9 * std.time.ms_per_hour };
    advanceAfterFire(&t, t.next_fire_ms, 0);
    try std.testing.expectEqual(1_704_067_200_000 + std.time.ms_per_day + 9 * std.time.ms_per_hour, t.next_fire_ms);
    try std.testing.expect(!isFinished(&t));
}

test "recomputeAfterRestart loop skips missed intervals" {
    var t = fixtureLoop(3, 1000); // far in the past
    recomputeAfterRestart(&t, 10_000, 0);
    try std.testing.expectEqual(@as(i64, 10_000 + 30 * std.time.ms_per_min), t.next_fire_ms);
}

test "recomputeAfterRestart one-shot caught up to now when missed" {
    var t = Task{ .kind = .watch, .session_id = "s", .prompt = "p", .daily = false, .remaining = 1, .next_fire_ms = 1000 };
    recomputeAfterRestart(&t, 10_000, 0);
    try std.testing.expectEqual(@as(i64, 10_000), t.next_fire_ms);
}

test "encode/decode round-trip" {
    const a = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = 1, .kind = .loop, .session_id = "session-7", .model = "glm", .title = "Build", .prompt = "check ci", .interval_ms = 1_800_000, .remaining = 8, .next_fire_ms = 123, .created_ms = 100 },
        .{ .id = 2, .kind = .watch, .session_id = "session-7", .prompt = "report", .daily = true, .tod_minutes = 540, .remaining = 0, .next_fire_ms = 456, .created_ms = 100 },
    };
    const model = FileModel{ .version = 1, .next_id = 3, .tasks = @constCast(tasks[0..]) };

    const bytes = try encode(a, model);
    defer a.free(bytes);

    var parsed = try decodeAlloc(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 3), parsed.value.next_id);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tasks.len);
    try std.testing.expectEqualStrings("session-7", parsed.value.tasks[0].session_id);
    try std.testing.expectEqual(TaskKind.watch, parsed.value.tasks[1].kind);
    try std.testing.expectEqual(@as(i32, 540), parsed.value.tasks[1].tod_minutes);
    try std.testing.expectEqualStrings("check ci", parsed.value.tasks[0].prompt);
}

test "formatInterval picks the largest evenly-dividing unit" {
    try std.testing.expectEqual(IntervalDisplay{ .value = 1, .unit = 's' }, formatInterval(std.time.ms_per_s));
    try std.testing.expectEqual(IntervalDisplay{ .value = 30, .unit = 's' }, formatInterval(30 * std.time.ms_per_s));
    try std.testing.expectEqual(IntervalDisplay{ .value = 1, .unit = 'm' }, formatInterval(std.time.ms_per_min));
    try std.testing.expectEqual(IntervalDisplay{ .value = 5, .unit = 'h' }, formatInterval(5 * std.time.ms_per_hour));
    try std.testing.expectEqual(IntervalDisplay{ .value = 1, .unit = 'd' }, formatInterval(std.time.ms_per_day));
    // 120s collapses to the larger exact unit (2m); 90s stays seconds.
    try std.testing.expectEqual(IntervalDisplay{ .value = 2, .unit = 'm' }, formatInterval(120 * std.time.ms_per_s));
    try std.testing.expectEqual(IntervalDisplay{ .value = 90, .unit = 's' }, formatInterval(90 * std.time.ms_per_s));
}
