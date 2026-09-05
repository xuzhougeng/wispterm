const std = @import("std");
const types = @import("types.zig");

pub const ParseError = error{OutOfMemory};

pub fn parseMetadata(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    wire_jsonl: []const u8,
    state_json: []const u8,
    index_jsonl: []const u8,
) ParseError!types.SessionMeta {
    var meta = try initMetadata(allocator, source_path);
    errdefer freeMetadata(allocator, meta);

    try replaceOwned(allocator, &meta.session_id, sessionIdFromPath(source_path));
    try parseStateMetadata(allocator, state_json, &meta);
    if (meta.project_dir.len == 0) try parseIndexProjectDir(allocator, index_jsonl, &meta);
    try parseWireMetadata(allocator, wire_jsonl, &meta);

    if (meta.title.len == 0) try replaceOwned(allocator, &meta.title, meta.session_id);
    if (meta.summary.len == 0) try replaceOwned(allocator, &meta.summary, meta.title);
    return meta;
}

pub fn parseTranscript(allocator: std.mem.Allocator, wire_jsonl: []const u8) ParseError![]types.TranscriptMessage {
    var messages: std.ArrayListUnmanaged(types.TranscriptMessage) = .empty;
    errdefer {
        freeTranscriptList(allocator, messages.items);
        messages.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, wire_jsonl, '\n');
    while (lines.next()) |line| {
        var parsed = (try parseLine(allocator, line)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        const obj = parsed.value.object;
        const event_type = objectString(obj, "type") orelse continue;
        if (std.mem.eql(u8, event_type, "context.append_message")) {
            try appendContextMessage(allocator, &messages, obj);
        } else if (std.mem.eql(u8, event_type, "context.append_loop_event")) {
            try appendLoopEvent(allocator, &messages, obj);
        }
    }

    return try messages.toOwnedSlice(allocator);
}

pub fn freeMetadata(allocator: std.mem.Allocator, meta: types.SessionMeta) void {
    allocator.free(meta.session_id);
    allocator.free(meta.title);
    allocator.free(meta.summary);
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
    const summary = try allocator.dupe(u8, "");
    errdefer allocator.free(summary);
    const project_dir = try allocator.dupe(u8, "");
    errdefer allocator.free(project_dir);
    const source_path_owned = try allocator.dupe(u8, source_path);

    return .{
        .provider = .kimi,
        .session_id = session_id,
        .title = title,
        .summary = summary,
        .project_dir = project_dir,
        .source_path = source_path_owned,
        .resume_kind = .kimi_resume,
    };
}

fn parseStateMetadata(allocator: std.mem.Allocator, state_json: []const u8, meta: *types.SessionMeta) ParseError!void {
    const trimmed = std.mem.trim(u8, state_json, " \t\r\n");
    if (trimmed.len == 0) return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const obj = parsed.value.object;
    if (objectString(obj, "title")) |title| {
        if (title.len > 0) try replaceOwned(allocator, &meta.title, title);
    }
    if (objectString(obj, "workDir")) |work_dir| {
        if (work_dir.len > 0) try replaceOwned(allocator, &meta.project_dir, work_dir);
    }
    if (objectString(obj, "createdAt")) |timestamp| updateTimestamp(meta, parseTimestampMs(timestamp));
    if (objectString(obj, "updatedAt")) |timestamp| updateTimestamp(meta, parseTimestampMs(timestamp));
}

fn parseIndexProjectDir(allocator: std.mem.Allocator, index_jsonl: []const u8, meta: *types.SessionMeta) ParseError!void {
    var lines = std.mem.splitScalar(u8, index_jsonl, '\n');
    while (lines.next()) |line| {
        var parsed = (try parseLine(allocator, line)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const session_id = objectString(obj, "sessionId") orelse continue;
        if (!std.mem.eql(u8, session_id, meta.session_id)) continue;
        const work_dir = objectString(obj, "workDir") orelse return;
        if (work_dir.len > 0) try replaceOwned(allocator, &meta.project_dir, work_dir);
        return;
    }
}

fn parseWireMetadata(allocator: std.mem.Allocator, wire_jsonl: []const u8, meta: *types.SessionMeta) ParseError!void {
    var lines = std.mem.splitScalar(u8, wire_jsonl, '\n');
    while (lines.next()) |line| {
        var parsed = (try parseLine(allocator, line)) orelse continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        const obj = parsed.value.object;
        const record_type = objectString(obj, "type") orelse continue;
        if (std.mem.eql(u8, record_type, "metadata")) {
            updateTimestamp(meta, objectInt(obj, "created_at"));
            continue;
        }

        var added: u32 = 0;
        if (std.mem.eql(u8, record_type, "context.append_message")) {
            const message = objectObject(obj, "message") orelse continue;
            const role = objectString(message, "role") orelse continue;
            if (message.get("content")) |content| {
                if (firstText(content)) |text| {
                    if (text.len > 0) {
                        added += 1;
                        if (meta.title.len == 0 and std.mem.eql(u8, role, "user")) {
                            try replaceOwned(allocator, &meta.title, text);
                        }
                    }
                }
            }
            if (std.mem.eql(u8, role, "assistant")) added += countToolCalls(message);
        } else if (std.mem.eql(u8, record_type, "context.append_loop_event")) {
            const event = objectObject(obj, "event") orelse continue;
            const event_type = objectString(event, "type") orelse continue;
            if (std.mem.eql(u8, event_type, "content.part")) {
                const part = objectObject(event, "part") orelse continue;
                if (std.mem.eql(u8, objectString(part, "type") orelse "", "text") and
                    (objectString(part, "text") orelse "").len > 0)
                {
                    added = 1;
                }
            } else if (std.mem.eql(u8, event_type, "tool.call")) {
                if ((objectString(event, "name") orelse objectString(event, "description") orelse "").len > 0) added = 1;
            } else if (std.mem.eql(u8, event_type, "tool.result")) {
                if (eventResultValue(event)) |value| {
                    if ((firstText(value) orelse "").len > 0) added = 1;
                }
            }
        }

        if (added > 0) {
            meta.message_count += added;
            updateTimestamp(meta, objectInt(obj, "time"));
        }
    }
}

fn appendContextMessage(
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged(types.TranscriptMessage),
    obj: std.json.ObjectMap,
) ParseError!void {
    const message = objectObject(obj, "message") orelse return;
    const role_text = objectString(message, "role") orelse return;
    const timestamp_ms = objectInt(obj, "time");
    const content = message.get("content");

    if (std.mem.eql(u8, role_text, "user")) {
        if (content) |value| try appendContent(allocator, messages, .user, .normal, value, timestamp_ms);
        return;
    }
    if (std.mem.eql(u8, role_text, "assistant")) {
        if (content) |value| try appendContent(allocator, messages, .assistant, .normal, value, timestamp_ms);
        if (message.get("toolCalls")) |calls| try appendToolCalls(allocator, messages, calls, timestamp_ms);
        return;
    }
    if (std.mem.eql(u8, role_text, "tool")) {
        if (content) |value| try appendContent(allocator, messages, .tool, .tool_result, value, timestamp_ms);
    }
}

fn appendLoopEvent(
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged(types.TranscriptMessage),
    obj: std.json.ObjectMap,
) ParseError!void {
    const event = objectObject(obj, "event") orelse return;
    const event_type = objectString(event, "type") orelse return;
    const timestamp_ms = objectInt(obj, "time");

    if (std.mem.eql(u8, event_type, "content.part")) {
        const part = objectObject(event, "part") orelse return;
        if (!std.mem.eql(u8, objectString(part, "type") orelse "", "text")) return;
        const text = objectString(part, "text") orelse return;
        try appendBorrowed(allocator, messages, .assistant, .normal, text, timestamp_ms);
    } else if (std.mem.eql(u8, event_type, "tool.call")) {
        const text = objectString(event, "name") orelse objectString(event, "description") orelse return;
        try appendBorrowed(allocator, messages, .assistant, .tool_call, text, timestamp_ms);
    } else if (std.mem.eql(u8, event_type, "tool.result")) {
        const value = eventResultValue(event) orelse return;
        try appendContent(allocator, messages, .tool, .tool_result, value, timestamp_ms);
    }
}

fn appendContent(
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged(types.TranscriptMessage),
    role: types.MessageRole,
    kind: types.MessageKind,
    value: std.json.Value,
    timestamp_ms: i64,
) ParseError!void {
    const content = (try ownedTextContent(allocator, value)) orelse return;
    errdefer allocator.free(content);
    try messages.append(allocator, .{ .role = role, .kind = kind, .content = content, .timestamp_ms = timestamp_ms });
}

fn appendToolCalls(
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged(types.TranscriptMessage),
    value: std.json.Value,
    timestamp_ms: i64,
) ParseError!void {
    if (value != .array) return;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const function = objectObject(item.object, "function") orelse continue;
        const name = objectString(function, "name") orelse continue;
        try appendBorrowed(allocator, messages, .assistant, .tool_call, name, timestamp_ms);
    }
}

fn appendBorrowed(
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged(types.TranscriptMessage),
    role: types.MessageRole,
    kind: types.MessageKind,
    content: []const u8,
    timestamp_ms: i64,
) ParseError!void {
    if (content.len == 0) return;
    const owned = try allocator.dupe(u8, content);
    errdefer allocator.free(owned);
    try messages.append(allocator, .{ .role = role, .kind = kind, .content = owned, .timestamp_ms = timestamp_ms });
}

fn ownedTextContent(allocator: std.mem.Allocator, value: std.json.Value) ParseError!?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (value) {
        .string => |text| try appendText(allocator, &out, text),
        .object => |obj| if (objectString(obj, "text")) |text| try appendText(allocator, &out, text),
        .array => |items| for (items.items) |item| {
            if (item != .object) continue;
            if (!std.mem.eql(u8, objectString(item.object, "type") orelse "", "text")) continue;
            if (objectString(item.object, "text")) |text| try appendText(allocator, &out, text);
        },
        else => {},
    }

    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn appendText(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) ParseError!void {
    if (text.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, text);
}

fn firstText(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        .object => |obj| objectString(obj, "text"),
        .array => |items| for (items.items) |item| {
            if (item != .object) continue;
            if (!std.mem.eql(u8, objectString(item.object, "type") orelse "", "text")) continue;
            if (objectString(item.object, "text")) |text| break text;
        } else null,
        else => null,
    };
}

fn countToolCalls(message: std.json.ObjectMap) u32 {
    const calls = message.get("toolCalls") orelse return 0;
    if (calls != .array) return 0;
    var count: u32 = 0;
    for (calls.array.items) |item| {
        if (item != .object) continue;
        const function = objectObject(item.object, "function") orelse continue;
        if ((objectString(function, "name") orelse "").len > 0) count += 1;
    }
    return count;
}

fn eventResultValue(event: std.json.ObjectMap) ?std.json.Value {
    const value = event.get("result") orelse return null;
    return switch (value) {
        .string => value,
        .object => |obj| blk: {
            if (obj.get("output")) |output| {
                if ((firstText(output) orelse "").len > 0) break :blk output;
            }
            break :blk obj.get("note");
        },
        else => null,
    };
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
        .string => |text| text,
        else => null,
    };
}

fn objectObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn objectInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const value = obj.get(key) orelse return 0;
    return switch (value) {
        .integer => |number| number,
        else => 0,
    };
}

fn replaceOwned(allocator: std.mem.Allocator, field: *[]const u8, value: []const u8) ParseError!void {
    const owned = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = owned;
}

fn freeTranscriptList(allocator: std.mem.Allocator, messages: []types.TranscriptMessage) void {
    for (messages) |message| allocator.free(message.content);
}

fn sessionIdFromPath(source_path: []const u8) []const u8 {
    const posix_marker = "/agents/main/wire.jsonl";
    const windows_marker = "\\agents\\main\\wire.jsonl";
    const session_dir = if (std.mem.lastIndexOf(u8, source_path, posix_marker)) |index|
        source_path[0..index]
    else if (std.mem.lastIndexOf(u8, source_path, windows_marker)) |index|
        source_path[0..index]
    else
        source_path;
    return basenameAny(session_dir);
}

fn basenameAny(path: []const u8) []const u8 {
    var start: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| start = index + 1;
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |index| {
        if (index + 1 > start) start = index + 1;
    }
    return path[start..];
}

fn updateTimestamp(meta: *types.SessionMeta, timestamp_ms: i64) void {
    if (timestamp_ms <= 0) return;
    if (meta.created_at_ms == 0 or timestamp_ms < meta.created_at_ms) meta.created_at_ms = timestamp_ms;
    if (timestamp_ms > meta.last_active_at_ms) meta.last_active_at_ms = timestamp_ms;
}

fn parseTimestampMs(timestamp: []const u8) i64 {
    if (timestamp.len < "0000-00-00T00:00:00Z".len) return 0;
    if (timestamp[4] != '-' or timestamp[7] != '-' or timestamp[10] != 'T' or
        timestamp[13] != ':' or timestamp[16] != ':') return 0;

    const year = parseDigits(timestamp[0..4]) orelse return 0;
    const month = parseDigits(timestamp[5..7]) orelse return 0;
    const day = parseDigits(timestamp[8..10]) orelse return 0;
    const hour = parseDigits(timestamp[11..13]) orelse return 0;
    const minute = parseDigits(timestamp[14..16]) orelse return 0;
    const second = parseDigits(timestamp[17..19]) orelse return 0;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or
        hour > 23 or minute > 59 or second > 59) return 0;

    var index: usize = 19;
    var millisecond: i64 = 0;
    if (index < timestamp.len and timestamp[index] == '.') {
        index += 1;
        const start = index;
        var scale: i64 = 100;
        while (index < timestamp.len and std.ascii.isDigit(timestamp[index])) : (index += 1) {
            if (index - start < 3) {
                millisecond += @as(i64, timestamp[index] - '0') * scale;
                scale = @divFloor(scale, 10);
            }
        }
    }
    if (index >= timestamp.len or timestamp[index] != 'Z') return 0;

    const days = daysBeforeYear(year) + daysBeforeMonth(year, month) + day - 1;
    return (((days * 24 + hour) * 60 + minute) * 60 + second) * 1000 + millisecond;
}

fn parseDigits(bytes: []const u8) ?i64 {
    var value: i64 = 0;
    for (bytes) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        value = value * 10 + byte - '0';
    }
    return value;
}

fn daysBeforeYear(year: i64) i64 {
    const y = year - 1970;
    return y * 365 + @divFloor(year - 1969, 4) - @divFloor(year - 1901, 100) + @divFloor(year - 1601, 400);
}

fn daysBeforeMonth(year: i64, month: i64) i64 {
    var days: i64 = 0;
    var value: i64 = 1;
    while (value < month) : (value += 1) days += daysInMonth(year, value);
    return days;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        else => 0,
    };
}

test "ai_history_provider_kimi: parses current wire and state metadata" {
    const allocator = std.testing.allocator;
    const wire =
        \\{"type":"metadata","protocol_version":"1.3","created_at":1785809771313}
        \\{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"Inspect the project"}]},"time":1785809779792}
        \\{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"think","think":"private reasoning"}},"time":1785809793703}
        \\{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Read"},"time":1785809793719}
        \\{"type":"context.append_loop_event","event":{"type":"tool.result","result":{"output":"file contents"}},"time":1785809793732}
        \\{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Done"}},"time":1785809861790}
        \\
    ;
    const state =
        \\{"createdAt":"2026-08-04T02:16:11.313Z","updatedAt":"2026-08-04T02:17:41.790Z","title":"Inspect project","workDir":"/home/me/project"}
    ;

    const meta = try parseMetadata(allocator, "/home/me/.kimi-code/sessions/wd_project/session_abc/agents/main/wire.jsonl", wire, state, "");
    defer freeMetadata(allocator, meta);
    try std.testing.expectEqual(types.ProviderId.kimi, meta.provider);
    try std.testing.expectEqualStrings("session_abc", meta.session_id);
    try std.testing.expectEqualStrings("Inspect project", meta.title);
    try std.testing.expectEqualStrings("Inspect project", meta.summary);
    try std.testing.expectEqualStrings("/home/me/project", meta.project_dir);
    try std.testing.expectEqual(types.ResumeKind.kimi_resume, meta.resume_kind);
    try std.testing.expectEqual(@as(u32, 4), meta.message_count);
    try std.testing.expectEqual(@as(i64, 1785809771313), meta.created_at_ms);
    try std.testing.expectEqual(@as(i64, 1785809861790), meta.last_active_at_ms);
}

test "ai_history_provider_kimi: session index supplies migrated work directory" {
    const allocator = std.testing.allocator;
    const wire =
        \\{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"Migrated prompt"}]}}
        \\
    ;
    const index =
        \\{"sessionId":"other","workDir":"/tmp/other","sessionDir":"/tmp/other-session"}
        \\{"sessionId":"ses_abc","workDir":"/home/me/migrated","sessionDir":"/home/me/.kimi-code/sessions/wd/ses_abc"}
        \\
    ;

    const meta = try parseMetadata(allocator, "/home/me/.kimi-code/sessions/wd/ses_abc/agents/main/wire.jsonl", wire, "{}", index);
    defer freeMetadata(allocator, meta);
    try std.testing.expectEqualStrings("ses_abc", meta.session_id);
    try std.testing.expectEqualStrings("Migrated prompt", meta.title);
    try std.testing.expectEqualStrings("/home/me/migrated", meta.project_dir);
}

test "ai_history_provider_kimi: transcript reads current and migrated records without thinking" {
    const allocator = std.testing.allocator;
    const wire =
        \\{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"Inspect"}]},"time":10}
        \\{"type":"context.append_message","message":{"role":"assistant","content":[{"type":"think","think":"hidden"},{"type":"text","text":"Checking"}],"toolCalls":[{"function":{"name":"Read"}}]},"time":11}
        \\{"type":"context.append_message","message":{"role":"tool","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]},"time":12}
        \\{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"think","think":"also hidden"}},"time":13}
        \\{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Done"}},"time":14}
        \\{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Bash"},"time":15}
        \\{"type":"context.append_loop_event","event":{"type":"tool.result","result":{"output":[{"type":"text","text":"first result"},{"type":"image_url","imageUrl":"data:image/png;base64,AA"},{"type":"text","text":"second result"}]}},"time":16}
        \\
    ;

    const messages = try parseTranscript(allocator, wire);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 7), messages.len);
    try std.testing.expectEqualStrings("Inspect", messages[0].content);
    try std.testing.expectEqualStrings("Checking", messages[1].content);
    try std.testing.expectEqual(types.MessageKind.tool_call, messages[2].kind);
    try std.testing.expectEqualStrings("first\nsecond", messages[3].content);
    try std.testing.expectEqualStrings("Done", messages[4].content);
    try std.testing.expectEqual(types.MessageKind.tool_call, messages[5].kind);
    try std.testing.expectEqual(types.MessageKind.tool_result, messages[6].kind);
    try std.testing.expectEqualStrings("first result\nsecond result", messages[6].content);
}

pub fn kimiStatePath(allocator: std.mem.Allocator, source_path: []const u8) !?[]u8 {
    const posix_marker = "/agents/main/wire.jsonl";
    if (std.mem.lastIndexOf(u8, source_path, posix_marker)) |index| {
        return try std.fmt.allocPrint(allocator, "{s}/state.json", .{source_path[0..index]});
    }
    const windows_marker = "\\agents\\main\\wire.jsonl";
    if (std.mem.lastIndexOf(u8, source_path, windows_marker)) |index| {
        return try std.fmt.allocPrint(allocator, "{s}\\state.json", .{source_path[0..index]});
    }
    return null;
}

pub fn kimiIndexPath(allocator: std.mem.Allocator, source_path: []const u8) !?[]u8 {
    const posix_marker = "/sessions/";
    if (std.mem.lastIndexOf(u8, source_path, posix_marker)) |index| {
        return try std.fmt.allocPrint(allocator, "{s}/session_index.jsonl", .{source_path[0..index]});
    }
    const windows_marker = "\\sessions\\";
    if (std.mem.lastIndexOf(u8, source_path, windows_marker)) |index| {
        return try std.fmt.allocPrint(allocator, "{s}\\session_index.jsonl", .{source_path[0..index]});
    }
    return null;
}
