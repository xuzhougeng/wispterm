const std = @import("std");
const types = @import("types.zig");

pub const ParseError = error{OutOfMemory};

pub fn parseMetadata(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    transcript_jsonl: []const u8,
    meta_json: []const u8,
    events_jsonl: []const u8,
) ParseError!types.SessionMeta {
    var meta = try initMetadata(allocator, source_path);
    errdefer freeMetadata(allocator, meta);

    try replaceOwned(allocator, &meta.session_id, sessionIdFromPath(source_path));

    if (try parseMetaJson(allocator, meta_json)) |sidecar| {
        defer sidecar.deinit(allocator);
        if (sidecar.summary.len > 0) {
            try replaceOwned(allocator, &meta.summary, sidecar.summary);
            try replaceOwned(allocator, &meta.title, sidecar.summary);
        }
        if (sidecar.workspace.len > 0) try replaceOwned(allocator, &meta.project_dir, sidecar.workspace);
    }

    try parseTranscriptMetadata(allocator, transcript_jsonl, &meta);
    try parseEventTimestamps(allocator, events_jsonl, &meta);

    if (meta.title.len == 0) try replaceOwned(allocator, &meta.title, meta.session_id);
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
        const role_text = objectString(obj, "role") orelse continue;
        const role = messageRole(role_text) orelse continue;
        const event = try transcriptEvent(allocator, obj, role) orelse continue;
        errdefer allocator.free(event.content);
        try messages.append(allocator, event);
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
        .provider = .reasonix,
        .session_id = session_id,
        .title = title,
        .summary = summary,
        .project_dir = project_dir,
        .source_path = source_path_owned,
        .resume_kind = .reasonix_resume,
    };
}

fn freeTranscriptList(allocator: std.mem.Allocator, messages: []types.TranscriptMessage) void {
    for (messages) |message| allocator.free(message.content);
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

fn sessionIdFromPath(source_path: []const u8) []const u8 {
    const base = std.fs.path.basename(source_path);
    return if (std.mem.endsWith(u8, base, ".jsonl")) base[0 .. base.len - ".jsonl".len] else base;
}

const ReasonixMetaSidecar = struct {
    summary: []const u8 = "",
    workspace: []const u8 = "",

    fn deinit(self: ReasonixMetaSidecar, allocator: std.mem.Allocator) void {
        if (self.summary.len > 0) allocator.free(self.summary);
        if (self.workspace.len > 0) allocator.free(self.workspace);
    }
};

fn parseMetaJson(allocator: std.mem.Allocator, meta_json: []const u8) ParseError!?ReasonixMetaSidecar {
    const trimmed = std.mem.trim(u8, meta_json, " \t\r\n");
    if (trimmed.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    var sidecar = ReasonixMetaSidecar{};
    errdefer sidecar.deinit(allocator);
    if (objectString(parsed.value.object, "summary")) |summary| {
        sidecar.summary = try allocator.dupe(u8, summary);
    }
    if (objectString(parsed.value.object, "workspace")) |workspace| {
        sidecar.workspace = try allocator.dupe(u8, workspace);
    }
    return sidecar;
}

fn parseTranscriptMetadata(allocator: std.mem.Allocator, jsonl: []const u8, meta: *types.SessionMeta) ParseError!void {
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        var parsed = (try parseLine(allocator, line)) orelse continue;
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const role = messageRole(objectString(obj, "role") orelse "") orelse continue;
        const content = objectString(obj, "content") orelse "";
        if (content.len == 0 and role != .assistant) continue;
        if (meta.title.len == 0 and role == .user and content.len > 0) {
            try replaceOwned(allocator, &meta.title, content);
        }
        meta.message_count += 1;
    }
}

fn parseEventTimestamps(allocator: std.mem.Allocator, events_jsonl: []const u8, meta: *types.SessionMeta) ParseError!void {
    var lines = std.mem.splitScalar(u8, events_jsonl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const timestamp = objectString(parsed.value.object, "ts") orelse continue;
        const ms = parseTimestampMs(timestamp);
        if (ms <= 0) continue;
        if (meta.created_at_ms == 0) meta.created_at_ms = ms;
        if (ms > meta.last_active_at_ms) meta.last_active_at_ms = ms;
    }
}

fn transcriptEvent(allocator: std.mem.Allocator, obj: std.json.ObjectMap, role: types.MessageRole) ParseError!?types.TranscriptMessage {
    if (role == .tool) {
        const content = objectString(obj, "content") orelse return null;
        return .{
            .role = .tool,
            .kind = .tool_result,
            .content = try allocator.dupe(u8, content),
        };
    }

    const content = objectString(obj, "content") orelse "";
    if (content.len > 0) {
        return .{
            .role = role,
            .content = try allocator.dupe(u8, content),
        };
    }

    if (role == .assistant) {
        if (toolCallName(obj)) |name| {
            return .{
                .role = .assistant,
                .kind = .tool_call,
                .content = try allocator.dupe(u8, name),
            };
        }
    }

    return null;
}

fn toolCallName(obj: std.json.ObjectMap) ?[]const u8 {
    const calls = obj.get("tool_calls") orelse return null;
    if (calls != .array or calls.array.items.len == 0) return null;
    const first = calls.array.items[0];
    if (first != .object) return null;
    const function = first.object.get("function") orelse return null;
    if (function != .object) return null;
    return objectString(function.object, "name");
}

fn messageRole(role: []const u8) ?types.MessageRole {
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    if (std.mem.eql(u8, role, "tool")) return .tool;
    if (std.mem.eql(u8, role, "system")) return .system;
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
            if (index - start < 3) {
                millisecond += @as(i64, timestamp[index] - '0') * scale;
                scale = @divFloor(scale, 10);
            }
        }
    }

    if (index >= timestamp.len or timestamp[index] != 'Z') return 0;

    const days = daysBeforeYear(year) + daysBeforeMonth(year, month) + (day - 1);
    const seconds = (((days * 24) + hour) * 60 + minute) * 60 + second;
    return seconds * 1000 + millisecond;
}

fn parseDigits(bytes: []const u8) ?i64 {
    var value: i64 = 0;
    for (bytes) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
        value = value * 10 + @as(i64, ch - '0');
    }
    return value;
}

fn daysBeforeYear(year: i64) i64 {
    const y = year - 1970;
    return y * 365 + @divFloor(year - 1969, 4) - @divFloor(year - 1901, 100) + @divFloor(year - 1601, 400);
}

fn daysBeforeMonth(year: i64, month: i64) i64 {
    var days: i64 = 0;
    var m: i64 = 1;
    while (m < month) : (m += 1) days += daysInMonth(year, m);
    return days;
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

test "ai_history_provider_reasonix: parses metadata from transcript meta and events" {
    const allocator = std.testing.allocator;
    const transcript =
        \\{"role":"user","content":"hello"}
        \\{"role":"assistant","content":"Hi there"}
        \\{"role":"tool","name":"read_file","content":"file contents","tool_call_id":"tc-1"}
        \\
    ;
    const meta_json =
        \\{"workspace":"/home/me/project","summary":"Investigate startup","turnCount":2,"branch":"main"}
    ;
    const events =
        \\{"type":"session.opened","id":1,"name":"code-project","turn":0,"ts":"2026-05-26T13:53:34.400Z"}
        \\{"type":"model.final","id":2,"turn":1,"ts":"2026-05-26T13:54:59.393Z"}
        \\
    ;

    const meta = try parseMetadata(allocator, "/home/me/.reasonix/sessions/code-project.jsonl", transcript, meta_json, events);
    defer freeMetadata(allocator, meta);

    try std.testing.expectEqual(types.ProviderId.reasonix, meta.provider);
    try std.testing.expectEqualStrings("code-project", meta.session_id);
    try std.testing.expectEqualStrings("Investigate startup", meta.title);
    try std.testing.expectEqualStrings("Investigate startup", meta.summary);
    try std.testing.expectEqualStrings("/home/me/project", meta.project_dir);
    try std.testing.expectEqualStrings("/home/me/.reasonix/sessions/code-project.jsonl", meta.source_path);
    try std.testing.expectEqual(types.ResumeKind.reasonix_resume, meta.resume_kind);
    try std.testing.expectEqual(@as(u32, 3), meta.message_count);
    try std.testing.expectEqual(@as(i64, 1779803614400), meta.created_at_ms);
    try std.testing.expectEqual(@as(i64, 1779803699393), meta.last_active_at_ms);
}

test "ai_history_provider_reasonix: transcript keeps user assistant and tool messages" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"role":"user","content":"inspect"}
        \\{"role":"assistant","reasoning_content":"thinking","content":"","tool_calls":[{"id":"tc-1","function":{"name":"list_directory"}}]}
        \\{"role":"tool","name":"list_directory","content":"README.md","tool_call_id":"tc-1"}
        \\{"role":"assistant","content":"Done"}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);

    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqual(types.MessageRole.user, messages[0].role);
    try std.testing.expectEqual(types.MessageKind.normal, messages[0].kind);
    try std.testing.expectEqualStrings("inspect", messages[0].content);
    try std.testing.expectEqual(types.MessageRole.assistant, messages[1].role);
    try std.testing.expectEqual(types.MessageKind.tool_call, messages[1].kind);
    try std.testing.expectEqualStrings("list_directory", messages[1].content);
    try std.testing.expectEqual(types.MessageRole.tool, messages[2].role);
    try std.testing.expectEqual(types.MessageKind.tool_result, messages[2].kind);
    try std.testing.expectEqualStrings("README.md", messages[2].content);
    try std.testing.expectEqual(types.MessageRole.assistant, messages[3].role);
    try std.testing.expectEqualStrings("Done", messages[3].content);
}
