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
        if (objectBool(obj, "isMeta") == true) continue;

        if (meta.session_id.len == 0) {
            if (objectString(obj, "sessionId")) |session_id| try replaceOwned(allocator, &meta.session_id, session_id);
        }
        if (meta.project_dir.len == 0) {
            if (objectString(obj, "cwd")) |cwd| try replaceOwned(allocator, &meta.project_dir, cwd);
        }

        const message = messageObject(obj) orelse continue;
        const timestamp_ms = if (objectString(obj, "timestamp")) |timestamp|
            parseTimestampMs(timestamp)
        else
            0;

        var events = metadataMessageEvents(message) orelse continue;
        while (events.next()) |event| {
            meta.message_count += 1;
            if (meta.title.len == 0 and event.role == .user and event.kind == .normal) {
                if (event.title_text) |title_text| try replaceOwned(allocator, &meta.title, title_text);
            }
            if (timestamp_ms > 0) {
                if (meta.created_at_ms == 0) meta.created_at_ms = timestamp_ms;
                if (timestamp_ms > meta.last_active_at_ms) meta.last_active_at_ms = timestamp_ms;
            }
        }
    }

    if (meta.title.len == 0) {
        try replaceOwned(allocator, &meta.title, fallbackTitle(meta.project_dir));
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
        if (objectBool(obj, "isMeta") == true) continue;

        const message = messageObject(obj) orelse continue;
        const timestamp_ms = if (objectString(obj, "timestamp")) |timestamp|
            parseTimestampMs(timestamp)
        else
            0;

        var events = messageEvents(allocator, message) orelse continue;
        while (try events.next()) |event| {
            defer event.deinit(allocator);

            const content_owned = try allocator.dupe(u8, event.content.slice());
            errdefer allocator.free(content_owned);
            try messages.append(allocator, .{
                .role = event.role,
                .kind = event.kind,
                .content = content_owned,
                .timestamp_ms = timestamp_ms,
            });
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
        .provider = .claude,
        .session_id = session_id,
        .title = title,
        .project_dir = project_dir,
        .source_path = source_path_owned,
        .resume_kind = .claude_resume,
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

fn objectBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn messageObject(obj: std.json.ObjectMap) ?std.json.ObjectMap {
    const message = obj.get("message") orelse return null;
    return switch (message) {
        .object => |message_obj| message_obj,
        else => null,
    };
}

const MessageEvent = struct {
    role: types.MessageRole,
    kind: types.MessageKind,
    content: ContentText,

    fn deinit(self: MessageEvent, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
    }
};

const MetadataEvent = struct {
    role: types.MessageRole,
    kind: types.MessageKind,
    title_text: ?[]const u8 = null,
};

const MetadataMessageEvents = struct {
    role: types.MessageRole,
    content: std.json.Value,
    index: usize = 0,

    fn next(self: *MetadataMessageEvents) ?MetadataEvent {
        switch (self.content) {
            .string => |text| {
                if (self.index > 0) return null;
                self.index += 1;
                return .{ .role = self.role, .kind = .normal, .title_text = text };
            },
            .array => |items| {
                while (self.index < items.items.len) {
                    const item = items.items[self.index];
                    self.index += 1;
                    if (item != .object) continue;
                    const item_type = objectString(item.object, "type") orelse continue;
                    if (std.mem.eql(u8, item_type, "text")) {
                        return .{
                            .role = self.role,
                            .kind = .normal,
                            .title_text = objectString(item.object, "text"),
                        };
                    }
                    if (std.mem.eql(u8, item_type, "tool_result")) {
                        return .{ .role = .tool, .kind = .tool_result };
                    }
                }
            },
            else => {},
        }
        return null;
    }
};

const ContentText = union(enum) {
    borrowed: []const u8,
    owned: []const u8,

    fn slice(self: ContentText) []const u8 {
        return switch (self) {
            .borrowed => |text| text,
            .owned => |text| text,
        };
    }

    fn deinit(self: ContentText, allocator: std.mem.Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |text| allocator.free(text),
        }
    }
};

fn metadataMessageEvents(message: std.json.ObjectMap) ?MetadataMessageEvents {
    const role = messageRole(objectString(message, "role") orelse "") orelse return null;
    return .{
        .role = role,
        .content = message.get("content") orelse .{ .null = {} },
    };
}

const MessageEvents = struct {
    allocator: std.mem.Allocator,
    role: types.MessageRole,
    content: std.json.Value,
    index: usize = 0,

    fn next(self: *MessageEvents) ParseError!?MessageEvent {
        switch (self.content) {
            .string => |text| {
                if (self.index > 0) return null;
                self.index += 1;
                return .{ .role = self.role, .kind = .normal, .content = .{ .borrowed = text } };
            },
            .array => |items| {
                while (self.index < items.items.len) {
                    const item = items.items[self.index];
                    self.index += 1;
                    if (item != .object) continue;
                    const item_type = objectString(item.object, "type") orelse continue;
                    if (std.mem.eql(u8, item_type, "text")) {
                        const text = objectString(item.object, "text") orelse continue;
                        return .{ .role = self.role, .kind = .normal, .content = .{ .borrowed = text } };
                    }
                    if (std.mem.eql(u8, item_type, "tool_result")) {
                        const content_value = item.object.get("content") orelse continue;
                        const content = (try normalizeToolResultContent(self.allocator, content_value)) orelse continue;
                        return .{ .role = .tool, .kind = .tool_result, .content = content };
                    }
                }
            },
            else => {},
        }
        return null;
    }
};

fn messageEvents(allocator: std.mem.Allocator, message: std.json.ObjectMap) ?MessageEvents {
    const role = messageRole(objectString(message, "role") orelse "") orelse return null;
    return .{
        .allocator = allocator,
        .role = role,
        .content = message.get("content") orelse .{ .null = {} },
    };
}

// Claude tool_result content may be a string or an array of text blocks. Arrays
// without extractable text are skipped rather than serialized into transcript UI.
fn normalizeToolResultContent(allocator: std.mem.Allocator, value: std.json.Value) ParseError!?ContentText {
    return switch (value) {
        .string => |text| .{ .borrowed = text },
        .array => |items| try joinTextBlocks(allocator, items.items),
        else => null,
    };
}

fn joinTextBlocks(allocator: std.mem.Allocator, items: []const std.json.Value) ParseError!?ContentText {
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    errdefer joined.deinit(allocator);

    var found_text = false;
    for (items) |item| {
        if (item != .object) continue;
        if (!std.mem.eql(u8, objectString(item.object, "type") orelse "", "text")) continue;
        const text = objectString(item.object, "text") orelse continue;

        if (found_text) try joined.append(allocator, '\n');
        try joined.appendSlice(allocator, text);
        found_text = true;
    }

    if (!found_text) return null;
    return .{ .owned = try joined.toOwnedSlice(allocator) };
}

fn fallbackTitle(project_dir: []const u8) []const u8 {
    if (project_dir.len > 0) {
        const basename = std.fs.path.basename(project_dir);
        if (basename.len > 0) return basename;
    }
    return "Claude Code Session";
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

const MaxAllocAllocator = struct {
    child: std.mem.Allocator,
    max_alloc_len: usize,
    allowed_large_allocs: usize = 0,

    fn allocator(self: *MaxAllocAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *MaxAllocAllocator = @ptrCast(@alignCast(ctx));
        if (n > self.max_alloc_len and !self.consumeLargeAllocBudget()) return null;
        return self.child.rawAlloc(n, alignment, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *MaxAllocAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > self.max_alloc_len and !self.consumeLargeAllocBudget()) return false;
        return self.child.rawResize(buf, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *MaxAllocAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > self.max_alloc_len and !self.consumeLargeAllocBudget()) return null;
        return self.child.rawRemap(buf, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *MaxAllocAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ra);
    }

    fn consumeLargeAllocBudget(self: *MaxAllocAllocator) bool {
        if (self.allowed_large_allocs == 0) return false;
        self.allowed_large_allocs -= 1;
        return true;
    }
};

test "ai_history_provider_claude: parses metadata from project transcript" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"Fix tests"}}
        \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the failure."}]}}
        \\
    ;

    const meta = try parseMetadata(allocator, "/home/me/.claude/projects/project/claude-abc.jsonl", jsonl);
    defer freeMetadata(allocator, meta);
    try std.testing.expectEqual(types.ProviderId.claude, meta.provider);
    try std.testing.expectEqualStrings("claude-abc", meta.session_id);
    try std.testing.expectEqualStrings("Fix tests", meta.title);
    try std.testing.expectEqualStrings("/home/me/project", meta.project_dir);
    try std.testing.expectEqualStrings("/home/me/.claude/projects/project/claude-abc.jsonl", meta.source_path);
    try std.testing.expectEqual(types.ResumeKind.claude_resume, meta.resume_kind);
    try std.testing.expectEqual(@as(u32, 2), meta.message_count);
}

test "ai_history_provider_claude: skips isMeta and folds tool result messages" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"sessionId":"claude-abc","isMeta":true,"timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"meta"}}
        \\{"sessionId":"claude-abc","timestamp":"2026-05-31T10:01:00.000Z","type":"user","message":{"role":"user","content":"Inspect repo"}}
        \\{"sessionId":"claude-abc","timestamp":"2026-05-31T10:02:00.000Z","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ls output"}]}}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(types.MessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Inspect repo", messages[0].content);
    try std.testing.expectEqual(types.MessageRole.tool, messages[1].role);
    try std.testing.expectEqual(types.MessageKind.tool_result, messages[1].kind);
    try std.testing.expectEqualStrings("ls output", messages[1].content);
}

test "ai_history_provider_claude: metadata counts array tool results without joining content" {
    var guarded = MaxAllocAllocator{
        .child = std.testing.allocator,
        .max_alloc_len = 2048,
        .allowed_large_allocs = 12,
    };
    const allocator = guarded.allocator();
    const block = "x" ** 512;
    const jsonl =
        \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"Title text"}}
        \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:01:00.000Z","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"
    ++ block ++
        \\"},{"type":"text","text":"
    ++ block ++
        \\"},{"type":"text","text":"
    ++ block ++
        \\"},{"type":"text","text":"
    ++ block ++
        \\"},{"type":"text","text":"
    ++ block ++
        \\"},{"type":"text","text":"
    ++ block ++
        \\"}]}]}}
        \\
    ;

    const meta = try parseMetadata(allocator, "/home/me/.claude/projects/project/claude-abc.jsonl", jsonl);
    defer freeMetadata(allocator, meta);
    try std.testing.expectEqualStrings("Title text", meta.title);
    try std.testing.expectEqual(@as(u32, 2), meta.message_count);
    try std.testing.expectEqual(@as(usize, 0), guarded.allowed_large_allocs);
}

test "ai_history_provider_claude: joins text blocks from tool result arrays" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"sessionId":"claude-abc","timestamp":"2026-05-31T10:02:00.000Z","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"first line"},{"type":"text","text":"second line"}]}]}}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(types.MessageRole.tool, messages[0].role);
    try std.testing.expectEqual(types.MessageKind.tool_result, messages[0].kind);
    try std.testing.expectEqualStrings("first line\nsecond line", messages[0].content);
}

test "ai_history_provider_claude: falls back to cwd basename for title" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"No user text yet."}]}}
        \\
    ;

    const meta = try parseMetadata(allocator, "/home/me/.claude/projects/project/claude-abc.jsonl", jsonl);
    defer freeMetadata(allocator, meta);
    try std.testing.expectEqualStrings("project", meta.title);
}

test "ai_history_provider_claude: falls back to default title without cwd or basename" {
    const allocator = std.testing.allocator;
    const root_jsonl =
        \\{"sessionId":"claude-root","cwd":"/","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"No user text yet."}]}}
        \\
    ;
    const no_cwd_jsonl =
        \\{"sessionId":"claude-empty","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"No cwd."}]}}
        \\
    ;

    const root_meta = try parseMetadata(allocator, "/home/me/.claude/projects/root/claude-root.jsonl", root_jsonl);
    defer freeMetadata(allocator, root_meta);
    try std.testing.expectEqualStrings("Claude Code Session", root_meta.title);

    const no_cwd_meta = try parseMetadata(allocator, "/home/me/.claude/projects/empty/claude-empty.jsonl", no_cwd_jsonl);
    defer freeMetadata(allocator, no_cwd_meta);
    try std.testing.expectEqualStrings("Claude Code Session", no_cwd_meta.title);
}

test "ai_history_provider_claude: malformed json is skipped while parsing continues" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"sessionId":"claude-abc","timestamp":"2026-05-31T10:01:00.000Z","type":"user","message":{"role":"user","content":"Before malformed"}}
        \\{"sessionId":"claude-abc","timestamp":"2026-05-31T10:01:30.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"missing close"}]}
        \\{"sessionId":"claude-abc","timestamp":"2026-05-31T10:02:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"After malformed"}]}}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer freeTranscript(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("Before malformed", messages[0].content);
    try std.testing.expectEqualStrings("After malformed", messages[1].content);
}

test "ai_history_provider_claude: allocation failures propagate" {
    var metadata_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        parseMetadata(metadata_failing.allocator(), "/home/me/.claude/projects/project/claude-abc.jsonl", "{}\n"),
    );

    var transcript_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        parseTranscript(transcript_failing.allocator(), "{\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n"),
    );
}
