//! Pi provider. Pi stores each session as JSONL under
//! `~/.pi/agent/sessions/<munged-cwd>/<timestamp>_<uuid>.jsonl`. The first
//! `session` event carries `id`, `timestamp`, and `cwd`; `message` events wrap
//! `{message: {role, content}}` where content is a string or an array of
//! `{type: "text"|"thinking"|"toolCall", ...}` parts. `toolResult` events carry
//! `{role: "toolResult", content: [...{type:"text", text}]}`.
//! Parsing is fail-soft like the other providers: malformed lines are skipped
//! and only OutOfMemory propagates.

const std = @import("std");
const types = @import("types.zig");

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

        if (std.mem.eql(u8, event_type, "session")) {
            if (meta.session_id.len == 0) {
                if (objectString(obj, "id")) |session_id| try replaceOwned(allocator, &meta.session_id, session_id);
            }
            if (meta.project_dir.len == 0) {
                if (objectString(obj, "cwd")) |cwd| try replaceOwned(allocator, &meta.project_dir, cwd);
            }
            if (timestamp_ms > 0) {
                if (meta.created_at_ms == 0) meta.created_at_ms = timestamp_ms;
                if (timestamp_ms > meta.last_active_at_ms) meta.last_active_at_ms = timestamp_ms;
            }
            continue;
        }
        if (!std.mem.eql(u8, event_type, "message") and !std.mem.eql(u8, event_type, "toolResult")) continue;

        const body = obj.get("message") orelse continue;
        if (body != .object) continue;
        const message = body.object;
        const role = messageRole(objectString(message, "role") orelse "") orelse continue;
        const content = messageContentText(message.get("content") orelse continue) orelse continue;
        if (content.len == 0) continue;

        meta.message_count += 1;
        if (meta.title.len == 0 and role == .user) try replaceOwned(allocator, &meta.title, content);
        if (timestamp_ms > 0) {
            if (meta.created_at_ms == 0) meta.created_at_ms = timestamp_ms;
            if (timestamp_ms > meta.last_active_at_ms) meta.last_active_at_ms = timestamp_ms;
        }
    }

    if (meta.session_id.len == 0) {
        try replaceOwned(allocator, &meta.session_id, fileStemId(source_path));
    }

    return meta;
}

/// Fallback id: the transcript file name without its `.jsonl` extension
/// (e.g. `20261004T03-51-11Z_abc`). Sessions always carry an id on the first
/// line; this only covers truncated or hand-made files.
fn fileStemId(source_path: []const u8) []const u8 {
    // Session metadata can come from a Windows host while the provider test
    // or scanner runs on POSIX (and vice versa). Do not use the host-specific
    // std.fs.path separator set here; Pi paths may contain either separator.
    var basename_start: usize = 0;
    for (source_path, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') basename_start = index + 1;
    }
    const basename = source_path[basename_start..];
    return if (std.mem.endsWith(u8, basename, ".jsonl"))
        basename[0 .. basename.len - ".jsonl".len]
    else
        basename;
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
        const event_type = objectString(obj, "type") orelse continue;
        if (!std.mem.eql(u8, event_type, "message") and !std.mem.eql(u8, event_type, "toolResult")) continue;
        const timestamp_ms = if (objectString(obj, "timestamp")) |timestamp|
            parseTimestampMs(timestamp)
        else
            0;

        const body = obj.get("message") orelse continue;
        if (body != .object) continue;
        const message = body.object;
        const role = messageRole(objectString(message, "role") orelse "") orelse continue;
        const content_value = message.get("content") orelse continue;

        if (role == .tool) {
            const text = messageContentText(content_value) orelse continue;
            try appendOwned(allocator, &messages, .tool, .tool_result, text, timestamp_ms);
            continue;
        }

        // Assistant messages pack thinking/toolCall parts around text parts;
        // surface thinking as a separate entry and tool calls by tool name.
        if (content_value == .array) {
            for (content_value.array.items) |part| {
                if (part != .object) continue;
                const p = part.object;
                const part_type = objectString(p, "type") orelse continue;
                if (std.mem.eql(u8, part_type, "text")) {
                    if (objectString(p, "text")) |text| {
                        try appendOwned(allocator, &messages, role, .normal, text, timestamp_ms);
                    }
                } else if (std.mem.eql(u8, part_type, "thinking")) {
                    if (objectString(p, "thinking")) |text| {
                        try appendOwned(allocator, &messages, role, .normal, text, timestamp_ms);
                    }
                } else if (std.mem.eql(u8, part_type, "toolCall")) {
                    const name = if (p.get("toolCall")) |call| objectString(call.object, "name") else null;
                    const label = name orelse "tool call";
                    try appendOwned(allocator, &messages, .assistant, .tool_call, label, timestamp_ms);
                }
            }
            continue;
        }
        if (objectString(message, "content")) |text| {
            try appendOwned(allocator, &messages, role, .normal, text, timestamp_ms);
        }
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
        .provider = .pi,
        .session_id = session_id,
        .title = title,
        .project_dir = project_dir,
        .source_path = source_path_owned,
        .resume_kind = .pi_resume,
    };
}

fn appendOwned(
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged(types.TranscriptMessage),
    role: types.MessageRole,
    kind: types.MessageKind,
    content: []const u8,
    timestamp_ms: i64,
) ParseError!void {
    const content_owned = try allocator.dupe(u8, content);
    errdefer allocator.free(content_owned);
    try messages.append(allocator, .{
        .role = role,
        .kind = kind,
        .content = content_owned,
        .timestamp_ms = timestamp_ms,
    });
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

fn messageRole(role: []const u8) ?types.MessageRole {
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    if (std.mem.eql(u8, role, "system")) return .system;
    if (std.mem.eql(u8, role, "toolResult")) return .tool;
    return null;
}

fn messageContentText(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .string => |s| return s,
        .array => |items| {
            for (items.items) |item| {
                if (item != .object) continue;
                if (objectString(item.object, "type")) |t| {
                    if (!std.mem.eql(u8, t, "text")) continue;
                }
                if (objectString(item.object, "text")) |text| return text;
            }
        },
        else => {},
    }
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

test "ai_history_provider_pi: parses session metadata, title, and counts" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"session","version":3,"id":"01a10509-test","timestamp":"2026-10-04T03:51:11.514Z","cwd":"e:\\repo\\wispterm"}
        \\{"type":"model_change","id":"m1","timestamp":"2026-10-04T03:51:21.342Z"}
        \\{"type":"message","id":"x1","timestamp":"2026-10-04T03:52:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Fix the renderer crash"}]}}
        \\{"type":"message","id":"x2","timestamp":"2026-10-04T03:53:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"I found the issue."}]}}
        \\{"type":"message","id":"x3","timestamp":"2026-10-04T03:54:00.000Z","message":{"role":"toolResult","content":[{"type":"text","text":"ok"}]}}
        \\
    ;

    const meta = try parseMetadata(allocator, "C:\\pi\\sessions\\one.jsonl", jsonl);
    defer freeMetadata(allocator, meta);
    try std.testing.expectEqual(types.ProviderId.pi, meta.provider);
    try std.testing.expectEqualStrings("01a10509-test", meta.session_id);
    try std.testing.expectEqualStrings("Fix the renderer crash", meta.title);
    try std.testing.expectEqualStrings("e:\\repo\\wispterm", meta.project_dir);
    try std.testing.expectEqual(types.ResumeKind.pi_resume, meta.resume_kind);
    try std.testing.expectEqual(@as(u32, 3), meta.message_count);
    try std.testing.expect(meta.created_at_ms > 0);
    try std.testing.expect(meta.last_active_at_ms >= meta.created_at_ms);
}

test "ai_history_provider_pi: transcript splits parts and maps toolResult" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"message","timestamp":"2026-10-04T03:52:00.000Z","message":{"role":"user","content":[{"type":"text","text":"First"}]}}
        \\{"type":"message","timestamp":"2026-10-04T03:53:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"toolCall","toolCall":{"name":"bash"}},{"type":"text","text":"Done"}]}}
        \\{"type":"message","timestamp":"2026-10-04T03:54:00.000Z","message":{"role":"toolResult","content":[{"type":"text","text":"exit 0"}]}}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 5), messages.len);
    try std.testing.expectEqual(types.MessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("First", messages[0].content);
    try std.testing.expectEqualStrings("hmm", messages[1].content);
    try std.testing.expectEqual(types.MessageKind.tool_call, messages[2].kind);
    try std.testing.expectEqualStrings("bash", messages[2].content);
    try std.testing.expectEqualStrings("Done", messages[3].content);
    try std.testing.expectEqual(types.MessageRole.tool, messages[4].role);
    try std.testing.expectEqualStrings("exit 0", messages[4].content);
}

test "ai_history_provider_pi: malformed json is skipped but oom propagates" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"message","message":{"role":"user","content":"Skipped malformed"},"timestamp":"2026-10-04T03:52:00.000Z"
        \\{"type":"message","message":{"role":"assistant","content":"Kept"},"timestamp":"2026-10-04T03:53:00.000Z"}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("Kept", messages[0].content);
}

test "ai_history_provider_pi: file stem handles host-independent separators" {
    try std.testing.expectEqualStrings("20261004T03-51-11Z_abc", fileStemId("C:\\pi\\sessions\\20261004T03-51-11Z_abc.jsonl"));
    try std.testing.expectEqualStrings("20261004T03-51-11Z_abc", fileStemId("/home/pi/sessions/20261004T03-51-11Z_abc.jsonl"));
}

test "ai_history_provider_pi: missing session id falls back to file stem" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"message","timestamp":"2026-10-04T03:52:00.000Z","message":{"role":"user","content":"Hello"}}
        \\
    ;

    const meta = try parseMetadata(allocator, "C:\\pi\\sessions\\20261004T03-51-11Z_abc.jsonl", jsonl);
    defer freeMetadata(allocator, meta);
    try std.testing.expectEqualStrings("20261004T03-51-11Z_abc", meta.session_id);
}
