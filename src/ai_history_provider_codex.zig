const std = @import("std");
const types = @import("ai_history_types.zig");

pub const ParseError = error{OutOfMemory};

pub fn parseMetadata(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    jsonl: []const u8,
) ParseError!types.SessionMeta {
    var meta = try initMetadata(allocator, source_path);
    errdefer freeMetadata(allocator, meta);

    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        var parsed = (try parseLine(allocator, line)) orelse continue;
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const event_type = objectString(obj, "type") orelse continue;
        const timestamp_ms = if (objectString(obj, "timestamp")) |timestamp|
            parseTimestampMs(timestamp)
        else
            0;

        if (std.mem.eql(u8, event_type, "session_meta")) {
            const body = sessionBody(obj);
            if (objectString(body, "id")) |session_id| try replaceOwned(allocator, &meta.session_id, session_id);
            if (objectString(body, "cwd")) |cwd| try replaceOwned(allocator, &meta.project_dir, cwd);
            if (timestamp_ms > 0) {
                if (meta.created_at_ms == 0) meta.created_at_ms = timestamp_ms;
                if (timestamp_ms > meta.last_active_at_ms) meta.last_active_at_ms = timestamp_ms;
            }
            continue;
        }

        if (!std.mem.eql(u8, event_type, "response_item")) continue;
        const body = responseBody(obj) orelse continue;
        const role = messageRole(objectString(body, "role") orelse "") orelse continue;
        if (role != .user and role != .assistant) continue;
        const content = contentText(body.get("content") orelse continue) orelse continue;
        if (role == .user and isNoiseUserText(content)) continue;

        meta.message_count += 1;
        if (meta.title.len == 0 and role == .user) try replaceOwned(allocator, &meta.title, content);
        if (timestamp_ms > 0) {
            if (meta.created_at_ms == 0) meta.created_at_ms = timestamp_ms;
            if (timestamp_ms > meta.last_active_at_ms) meta.last_active_at_ms = timestamp_ms;
        }
    }

    return meta;
}

pub fn parseTranscript(
    allocator: std.mem.Allocator,
    jsonl: []const u8,
) ParseError![]types.TranscriptMessage {
    var messages: std.ArrayListUnmanaged(types.TranscriptMessage) = .empty;
    errdefer {
        freeTranscriptList(allocator, messages.items);
        messages.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        var parsed = (try parseLine(allocator, line)) orelse continue;
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        if (!std.mem.eql(u8, objectString(obj, "type") orelse "", "response_item")) continue;

        const body = responseBody(obj) orelse continue;
        const role = messageRole(objectString(body, "role") orelse "") orelse continue;
        if (role != .user and role != .assistant) continue;
        const content = contentText(body.get("content") orelse continue) orelse continue;
        if (role == .user and isNoiseUserText(content)) continue;
        const timestamp_ms = if (objectString(obj, "timestamp")) |timestamp|
            parseTimestampMs(timestamp)
        else
            0;

        const content_owned = try allocator.dupe(u8, content);
        errdefer allocator.free(content_owned);
        try messages.append(allocator, .{
            .role = role,
            .content = content_owned,
            .timestamp_ms = timestamp_ms,
        });
    }

    return try messages.toOwnedSlice(allocator);
}

/// Frees metadata returned by parseMetadata in this provider.
pub fn freeMetadata(allocator: std.mem.Allocator, meta: types.SessionMeta) void {
    allocator.free(meta.session_id);
    allocator.free(meta.title);
    allocator.free(meta.project_dir);
    allocator.free(meta.source_path);
}

pub fn freeTranscript(allocator: std.mem.Allocator, messages: []types.TranscriptMessage) void {
    freeTranscriptList(allocator, messages);
    allocator.free(messages);
}

fn initMetadata(allocator: std.mem.Allocator, source_path: []const u8) ParseError!types.SessionMeta {
    const session_id = try allocator.dupe(u8, "");
    errdefer allocator.free(session_id);
    const title = try allocator.dupe(u8, "");
    errdefer allocator.free(title);
    const project_dir = try allocator.dupe(u8, "");
    errdefer allocator.free(project_dir);
    const source_path_owned = try allocator.dupe(u8, source_path);

    return .{
        .provider = .codex,
        .session_id = session_id,
        .title = title,
        .project_dir = project_dir,
        .source_path = source_path_owned,
        .resume_kind = .codex_resume,
    };
}

fn freeTranscriptList(allocator: std.mem.Allocator, messages: []types.TranscriptMessage) void {
    for (messages) |message| {
        allocator.free(message.content);
    }
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8) ParseError!?std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn sessionBody(obj: std.json.ObjectMap) std.json.ObjectMap {
    const payload = obj.get("payload") orelse return obj;
    return if (payload == .object) payload.object else obj;
}

fn responseBody(obj: std.json.ObjectMap) ?std.json.ObjectMap {
    const payload = obj.get("payload") orelse return obj;
    if (payload != .object) return obj;
    if (!std.mem.eql(u8, objectString(payload.object, "type") orelse "", "message")) return null;
    return payload.object;
}

fn contentText(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .string => |s| return s,
        .array => |items| {
            for (items.items) |item| {
                if (item != .object) continue;
                if (objectString(item.object, "text")) |text| return text;
            }
        },
        else => {},
    }
    return null;
}

fn isNoiseUserText(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "<environment_context>") != null or
        std.mem.indexOf(u8, text, "AGENTS.md instructions") != null;
}

fn messageRole(role: []const u8) ?types.MessageRole {
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    return null;
}

fn replaceOwned(allocator: std.mem.Allocator, field: *[]const u8, value: []const u8) ParseError!void {
    const owned = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = owned;
}

fn parseTimestampMs(timestamp: []const u8) i64 {
    if (timestamp.len < "0000-00-00T00:00:00Z".len) return 0;
    if (timestamp[4] != '-' or timestamp[7] != '-' or timestamp[10] != 'T' or
        timestamp[13] != ':' or timestamp[16] != ':')
    {
        return 0;
    }

    const year: i64 = parseDigits(timestamp[0..4]) orelse return 0;
    const month: i64 = parseDigits(timestamp[5..7]) orelse return 0;
    const day: i64 = parseDigits(timestamp[8..10]) orelse return 0;
    const hour: i64 = parseDigits(timestamp[11..13]) orelse return 0;
    const minute: i64 = parseDigits(timestamp[14..16]) orelse return 0;
    const second: i64 = parseDigits(timestamp[17..19]) orelse return 0;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or
        hour > 23 or minute > 59 or second > 59)
    {
        return 0;
    }

    var index: usize = 19;
    var millisecond: i64 = 0;
    if (index < timestamp.len and timestamp[index] == '.') {
        index += 1;
        const start = index;
        var scale: i64 = 100;
        while (index < timestamp.len and std.ascii.isDigit(timestamp[index])) : (index += 1) {
            if (scale > 0) {
                millisecond += @as(i64, timestamp[index] - '0') * scale;
                scale = @divTrunc(scale, 10);
            }
        }
        if (index == start) return 0;
    }

    const offset_seconds = parseTimezoneOffsetSeconds(timestamp[index..]) orelse return 0;
    const local_seconds = daysFromCivil(year, month, day) * std.time.s_per_day +
        hour * std.time.s_per_hour + minute * std.time.s_per_min + second;
    return (local_seconds - offset_seconds) * std.time.ms_per_s + millisecond;
}

fn parseDigits(bytes: []const u8) ?i64 {
    var value: i64 = 0;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return null;
        value = value * 10 + byte - '0';
    }
    return value;
}

fn parseTimezoneOffsetSeconds(value: []const u8) ?i64 {
    if (std.mem.eql(u8, value, "Z")) return 0;
    if (value.len != 6 or value[3] != ':') return null;
    if (value[0] != '+' and value[0] != '-') return null;

    const hours = parseDigits(value[1..3]) orelse return null;
    const minutes = parseDigits(value[4..6]) orelse return null;
    if (hours > 23 or minutes > 59) return null;

    const offset = hours * std.time.s_per_hour + minutes * std.time.s_per_min;
    return if (value[0] == '+') offset else -offset;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysFromCivil(year_in: i64, month: i64, day: i64) i64 {
    var year = year_in;
    if (month <= 2) year -= 1;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const month_adjusted = if (month > 2) month - 3 else month + 9;
    const doy = @divTrunc(153 * month_adjusted + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "ai_history_provider_codex: parses metadata from session_meta and response items" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"session_meta","id":"codex-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00Z"}
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"Fix the renderer crash"}],"timestamp":"2026-05-31T10:01:00Z"}
        \\{"type":"response_item","role":"assistant","content":[{"type":"output_text","text":"I found the issue."}],"timestamp":"2026-05-31T10:02:00Z"}
        \\
    ;

    const meta = try parseMetadata(allocator, "/home/me/.codex/sessions/codex-abc.jsonl", jsonl);
    defer freeMetadata(allocator, meta);
    try std.testing.expectEqual(types.ProviderId.codex, meta.provider);
    try std.testing.expectEqualStrings("codex-abc", meta.session_id);
    try std.testing.expectEqualStrings("Fix the renderer crash", meta.title);
    try std.testing.expectEqualStrings("/home/me/project", meta.project_dir);
    try std.testing.expectEqualStrings("/home/me/.codex/sessions/codex-abc.jsonl", meta.source_path);
    try std.testing.expectEqual(types.ResumeKind.codex_resume, meta.resume_kind);
    try std.testing.expectEqual(@as(u32, 2), meta.message_count);
    try std.testing.expect(meta.created_at_ms > 0);
    try std.testing.expect(meta.last_active_at_ms >= meta.created_at_ms);
}

test "ai_history_provider_codex: parses real codex envelope metadata and transcript" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-abc","cwd":"/home/me/project"}}
        \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the renderer crash"}]}}
        \\{"type":"response_item","timestamp":"2026-05-31T10:02:00Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I found the issue."}]}}
        \\
    ;

    const meta = try parseMetadata(allocator, "/home/me/.codex/sessions/codex-abc.jsonl", jsonl);
    defer freeMetadata(allocator, meta);
    try std.testing.expectEqualStrings("codex-abc", meta.session_id);
    try std.testing.expectEqualStrings("/home/me/project", meta.project_dir);
    try std.testing.expectEqualStrings("Fix the renderer crash", meta.title);
    try std.testing.expectEqual(@as(u32, 2), meta.message_count);

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(types.MessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Fix the renderer crash", messages[0].content);
    try std.testing.expectEqual(types.MessageRole.assistant, messages[1].role);
    try std.testing.expectEqualStrings("I found the issue.", messages[1].content);
}

test "ai_history_provider_codex: parses fractional seconds and timezone offsets" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","timestamp":"2026-05-31T10:01:00.250Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"First"}]}}
        \\{"type":"response_item","timestamp":"2026-05-31T18:02:00+08:00","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Second"}]}}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(@as(i64, 1780221660250), messages[0].timestamp_ms);
    try std.testing.expectEqual(@as(i64, 1780221720000), messages[1].timestamp_ms);
}

test "ai_history_provider_codex: invalid timestamp dates are ignored" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","timestamp":"2026-02-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Bad date"}]}}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(@as(i64, 0), messages[0].timestamp_ms);
}

test "ai_history_provider_codex: malformed json is skipped but oom propagates" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"Skipped malformed"}],"timestamp":"2026-05-31T10:00:00Z"
        \\{"type":"response_item","role":"assistant","content":[{"type":"output_text","text":"Also kept"}],"timestamp":"2026-05-31T10:00:01Z"}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("Also kept", messages[0].content);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseTranscript(failing.allocator(), jsonl));
}

test "ai_history_provider_codex: transcript skips environment and AGENTS noise" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}],"timestamp":"2026-05-31T10:00:00Z"}
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp/project"}],"timestamp":"2026-05-31T10:00:01Z"}
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"Summarize this repo"}],"timestamp":"2026-05-31T10:01:00Z"}
        \\{"type":"response_item","role":"assistant","content":[{"type":"output_text","text":"It is a terminal emulator."}],"timestamp":"2026-05-31T10:02:00Z"}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(types.MessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Summarize this repo", messages[0].content);
    try std.testing.expectEqual(types.MessageRole.assistant, messages[1].role);
    try std.testing.expectEqualStrings("It is a terminal emulator.", messages[1].content);
}
