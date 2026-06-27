const std = @import("std");
const platform_atomic_file = @import("../platform/atomic_file.zig");
const platform_dirs = @import("../platform/dirs.zig");
const log = std.log.scoped(.agent_history);

pub const MAX_SESSION_BYTES = 32 * 1024 * 1024;
const DEFAULT_PROTOCOL = "chat_completions";

pub const MessageRole = enum {
    user,
    assistant,
    tool,
};

pub const MessageRecord = struct {
    role: MessageRole,
    content: []const u8,
    reasoning: ?[]const u8 = null,
    usage_footer: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    replay_to_model: bool = false,
};

pub const SessionRecord = struct {
    session_id: []const u8,
    title: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    protocol: []const u8 = DEFAULT_PROTOCOL,
    system_prompt: []const u8,
    thinking_enabled: bool,
    reasoning_effort: []const u8,
    stream: bool,
    max_tokens: u32 = 8192,
    agent_enabled: bool,
    vision_enabled: bool = false,
    copilot: bool = false,
    /// True once the user manually renamed the chat; defaults false for records
    /// written before this field existed (std.json fills the default).
    title_is_custom: bool = false,
    created_at: i64,
    updated_at: i64,
    messages: []MessageRecord,
};

pub const Row = struct {
    session_id: []const u8,
    title: []const u8,
    model: []const u8,
    updated_at: i64,
    copilot: bool = false,
};

pub const INDEX_VERSION: u32 = 1;

pub const IndexEntry = struct {
    session_id: []const u8,
    title: []const u8,
    model: []const u8,
    created_at: i64,
    updated_at: i64,
    copilot: bool = false,
    message_count: u32 = 0,
    search_preview: []const u8 = "",
};

pub const IndexFile = struct {
    version: u32 = INDEX_VERSION,
    entries: []IndexEntry = &.{},
};

const PersistedStore = struct {
    records: []SessionRecord = &.{},
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(SessionRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.records.deinit(self.allocator);
    }

    pub fn clear(self: *Store) void {
        for (self.records.items) |*record| freeOwnedRecord(self.allocator, record);
        self.records.clearRetainingCapacity();
    }

    pub fn upsertRecord(self: *Store, input: anytype) !void {
        var cloned = try cloneRecord(self.allocator, input);
        var cloned_owned = true;
        errdefer if (cloned_owned) freeOwnedRecord(self.allocator, &cloned);

        cloned_owned = false;
        try self.upsertOwnedRecord(cloned);
    }

    pub fn upsertOwnedRecord(self: *Store, record: SessionRecord) !void {
        var owned = record;
        errdefer freeOwnedRecord(self.allocator, &owned);

        if (self.findIndexBySessionId(owned.session_id)) |idx| {
            freeOwnedRecord(self.allocator, &self.records.items[idx]);
            self.records.items[idx] = owned;
            return;
        }

        try self.records.append(self.allocator, owned);
    }

    /// Returns rows with owned string slices. Call `freeRows()` when done.
    pub fn buildRows(self: *const Store, allocator: std.mem.Allocator) ![]Row {
        const rows = try allocator.alloc(Row, self.records.items.len);
        var initialized: usize = 0;
        errdefer {
            while (initialized > 0) {
                initialized -= 1;
                freeOwnedRow(allocator, &rows[initialized]);
            }
            allocator.free(rows);
        }

        for (self.records.items, 0..) |record, i| {
            rows[i] = try cloneRow(allocator, .{
                .session_id = record.session_id,
                .title = record.title,
                .model = record.model,
                .updated_at = record.updated_at,
                .copilot = record.copilot,
            });
            initialized += 1;
        }
        sortRows(rows);
        return rows;
    }

    /// Like `buildRows` but only `copilot == true` records (the Copilot conversation
    /// picker). Owned slices; call `freeRows()` when done. Sorted newest-first.
    pub fn buildCopilotRows(self: *const Store, allocator: std.mem.Allocator) ![]Row {
        var list: std.ArrayListUnmanaged(Row) = .empty;
        errdefer {
            for (list.items) |*r| freeOwnedRow(allocator, r);
            list.deinit(allocator);
        }
        for (self.records.items) |record| {
            if (!record.copilot) continue;
            const row = try cloneRow(allocator, .{
                .session_id = record.session_id,
                .title = record.title,
                .model = record.model,
                .updated_at = record.updated_at,
                .copilot = record.copilot,
            });
            try list.append(allocator, row);
        }
        const rows = try list.toOwnedSlice(allocator);
        sortRows(rows);
        return rows;
    }

    pub fn toJsonString(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, PersistedStore{
            .records = self.records.items,
        }, .{});
    }

    pub fn fromJsonString(allocator: std.mem.Allocator, bytes: []const u8) !Store {
        var parsed = try std.json.parseFromSlice(PersistedStore, allocator, bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var store = Store.init(allocator);
        errdefer store.deinit();

        for (parsed.value.records) |record| {
            try store.upsertRecord(record);
        }
        return store;
    }

    pub fn fromJsonStringLenient(allocator: std.mem.Allocator, bytes: []const u8) !Store {
        return fromJsonString(allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                if (isLenientJsonLoadError(err)) return Store.init(allocator);
                return err;
            },
        };
    }

    pub fn cloneRecordBySessionId(self: *const Store, allocator: std.mem.Allocator, session_id: []const u8) !?SessionRecord {
        const idx = self.findIndexBySessionId(session_id) orelse return null;
        return try cloneRecord(allocator, self.records.items[idx]);
    }

    pub fn deleteBySessionId(self: *Store, session_id: []const u8) bool {
        const idx = self.findIndexBySessionId(session_id) orelse return false;
        var removed = self.records.items[idx];
        var i = idx;
        while (i + 1 < self.records.items.len) : (i += 1) {
            self.records.items[i] = self.records.items[i + 1];
        }
        self.records.items = self.records.items[0 .. self.records.items.len - 1];
        freeOwnedRecord(self.allocator, &removed);
        return true;
    }

    pub fn saveToPath(self: *const Store, path: []const u8) !void {
        const json = try self.toJsonString(self.allocator);
        defer self.allocator.free(json);

        try saveJsonToPath(path, json);
    }

    pub fn saveDefault(self: *const Store) !void {
        const path = try defaultPath(self.allocator);
        defer self.allocator.free(path);
        try self.saveToPath(path);
    }

    fn findIndexBySessionId(self: *const Store, session_id: []const u8) ?usize {
        for (self.records.items, 0..) |record, i| {
            if (std.mem.eql(u8, record.session_id, session_id)) return i;
        }
        return null;
    }
};

pub fn saveJsonToPath(path: []const u8, json: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            log.warn("failed to create history dir {s}: {}", .{ dir, err });
            return err;
        };
    }

    try platform_atomic_file.writeFileReplaceSafe(path, json);
}

pub fn sortRows(rows: []Row) void {
    std.sort.block(Row, rows, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            if (a.updated_at != b.updated_at) return a.updated_at > b.updated_at;
            return std.mem.order(u8, a.session_id, b.session_id) == .lt;
        }
    }.lessThan);
}

pub fn cloneRecord(allocator: std.mem.Allocator, input: anytype) !SessionRecord {
    const session_id = try allocator.dupe(u8, input.session_id);
    errdefer allocator.free(session_id);
    const title = try allocator.dupe(u8, input.title);
    errdefer allocator.free(title);
    const base_url = try allocator.dupe(u8, input.base_url);
    errdefer allocator.free(base_url);
    const api_key = try allocator.dupe(u8, input.api_key);
    errdefer allocator.free(api_key);
    const model = try allocator.dupe(u8, input.model);
    errdefer allocator.free(model);
    const protocol_input = if (@hasField(@TypeOf(input), "protocol")) input.protocol else DEFAULT_PROTOCOL;
    const protocol = try allocator.dupe(u8, protocol_input);
    errdefer allocator.free(protocol);
    const system_prompt = try allocator.dupe(u8, input.system_prompt);
    errdefer allocator.free(system_prompt);
    const reasoning_effort = try allocator.dupe(u8, input.reasoning_effort);
    errdefer allocator.free(reasoning_effort);

    const messages = try cloneMessages(allocator, input.messages);
    errdefer {
        for (messages) |*message| deinitMessage(allocator, message);
        allocator.free(messages);
    }

    return .{
        .session_id = session_id,
        .title = title,
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .protocol = protocol,
        .system_prompt = system_prompt,
        .thinking_enabled = input.thinking_enabled,
        .reasoning_effort = reasoning_effort,
        .stream = input.stream,
        .max_tokens = if (@hasField(@TypeOf(input), "max_tokens")) input.max_tokens else 8192,
        .agent_enabled = input.agent_enabled,
        .vision_enabled = if (@hasField(@TypeOf(input), "vision_enabled")) input.vision_enabled else false,
        .copilot = if (@hasField(@TypeOf(input), "copilot")) input.copilot else false,
        .title_is_custom = if (@hasField(@TypeOf(input), "title_is_custom")) input.title_is_custom else false,
        .created_at = input.created_at,
        .updated_at = input.updated_at,
        .messages = messages,
    };
}

pub fn freeOwnedRecord(allocator: std.mem.Allocator, record: *SessionRecord) void {
    allocator.free(record.session_id);
    allocator.free(record.title);
    allocator.free(record.base_url);
    allocator.free(record.api_key);
    allocator.free(record.model);
    allocator.free(record.protocol);
    allocator.free(record.system_prompt);
    allocator.free(record.reasoning_effort);
    for (record.messages) |*message| freeOwnedMessage(allocator, message);
    allocator.free(record.messages);
    record.* = undefined;
}

pub fn cloneMessage(allocator: std.mem.Allocator, input: anytype) !MessageRecord {
    const content = try allocator.dupe(u8, input.content);
    errdefer allocator.free(content);
    const reasoning = if (@hasField(@TypeOf(input), "reasoning"))
        try dupeOptionalString(allocator, input.reasoning)
    else
        null;
    errdefer if (reasoning) |value| allocator.free(value);
    const usage_footer = if (@hasField(@TypeOf(input), "usage_footer"))
        try dupeOptionalString(allocator, input.usage_footer)
    else
        null;
    errdefer if (usage_footer) |value| allocator.free(value);
    const tool_call_id = if (@hasField(@TypeOf(input), "tool_call_id"))
        try dupeOptionalString(allocator, input.tool_call_id)
    else
        null;
    errdefer if (tool_call_id) |value| allocator.free(value);
    const tool_name = if (@hasField(@TypeOf(input), "tool_name"))
        try dupeOptionalString(allocator, input.tool_name)
    else
        null;
    errdefer if (tool_name) |value| allocator.free(value);

    return .{
        .role = input.role,
        .content = content,
        .reasoning = reasoning,
        .usage_footer = usage_footer,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .replay_to_model = if (@hasField(@TypeOf(input), "replay_to_model")) input.replay_to_model else false,
    };
}

pub fn deinitMessage(allocator: std.mem.Allocator, message: *MessageRecord) void {
    freeOwnedMessage(allocator, message);
}

pub fn freeOwnedMessage(allocator: std.mem.Allocator, message: *MessageRecord) void {
    allocator.free(message.content);
    if (message.reasoning) |reasoning| allocator.free(reasoning);
    if (message.usage_footer) |usage_footer| allocator.free(usage_footer);
    if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
    if (message.tool_name) |tool_name| allocator.free(tool_name);
    message.* = undefined;
}

pub fn freeRows(allocator: std.mem.Allocator, rows: []Row) void {
    for (rows) |*row| freeOwnedRow(allocator, row);
    allocator.free(rows);
}

pub fn dumpIndex(allocator: std.mem.Allocator, index: IndexFile) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, index, .{});
}

pub fn parseIndex(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(IndexFile) {
    return std.json.parseFromSlice(IndexFile, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn cloneIndexEntry(allocator: std.mem.Allocator, input: IndexEntry) !IndexEntry {
    const session_id = try allocator.dupe(u8, input.session_id);
    errdefer allocator.free(session_id);
    const title = try allocator.dupe(u8, input.title);
    errdefer allocator.free(title);
    const model = try allocator.dupe(u8, input.model);
    errdefer allocator.free(model);
    const search_preview = try allocator.dupe(u8, input.search_preview);
    errdefer allocator.free(search_preview);
    return .{
        .session_id = session_id,
        .title = title,
        .model = model,
        .created_at = input.created_at,
        .updated_at = input.updated_at,
        .copilot = input.copilot,
        .message_count = input.message_count,
        .search_preview = search_preview,
    };
}

pub fn freeOwnedIndexEntry(allocator: std.mem.Allocator, entry: *IndexEntry) void {
    allocator.free(entry.session_id);
    allocator.free(entry.title);
    allocator.free(entry.model);
    allocator.free(entry.search_preview);
    entry.* = undefined;
}

fn isSafeFileChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '_' or c == '-';
}

pub const SEARCH_PREVIEW_MAX = 200;

fn lowerAsciiByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub fn buildSearchPreview(allocator: std.mem.Allocator, record: SessionRecord) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (record.title) |c| try buf.append(allocator, lowerAsciiByte(c));
    for (record.messages) |m| {
        if (buf.items.len >= SEARCH_PREVIEW_MAX) break;
        try buf.append(allocator, ' ');
        for (m.content) |c| {
            if (buf.items.len >= SEARCH_PREVIEW_MAX) break;
            try buf.append(allocator, lowerAsciiByte(c));
        }
    }
    var n = @min(buf.items.len, SEARCH_PREVIEW_MAX);
    while (n > 0 and !std.unicode.utf8ValidateSlice(buf.items[0..n])) n -= 1;
    buf.shrinkRetainingCapacity(n);
    return buf.toOwnedSlice(allocator);
}

pub fn buildRowsFromEntries(allocator: std.mem.Allocator, entries: []const IndexEntry) ![]Row {
    const rows = try allocator.alloc(Row, entries.len);
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            freeOwnedRow(allocator, &rows[initialized]);
        }
        allocator.free(rows);
    }
    for (entries, 0..) |e, i| {
        rows[i] = try cloneRow(allocator, .{
            .session_id = e.session_id,
            .title = e.title,
            .model = e.model,
            .updated_at = e.updated_at,
            .copilot = e.copilot,
        });
        initialized += 1;
    }
    sortRows(rows);
    return rows;
}

pub fn buildCopilotRowsFromEntries(allocator: std.mem.Allocator, entries: []const IndexEntry) ![]Row {
    var list: std.ArrayListUnmanaged(Row) = .empty;
    errdefer {
        for (list.items) |*r| freeOwnedRow(allocator, r);
        list.deinit(allocator);
    }
    for (entries) |e| {
        if (!e.copilot) continue;
        const row = try cloneRow(allocator, .{
            .session_id = e.session_id,
            .title = e.title,
            .model = e.model,
            .updated_at = e.updated_at,
            .copilot = e.copilot,
        });
        list.append(allocator, row) catch |err| {
            var owned = row;
            freeOwnedRow(allocator, &owned);
            return err;
        };
    }
    const rows = try list.toOwnedSlice(allocator);
    sortRows(rows);
    return rows;
}

pub fn recordToJson(allocator: std.mem.Allocator, record: SessionRecord) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, record, .{});
}

pub fn recordFromJson(allocator: std.mem.Allocator, bytes: []const u8) !SessionRecord {
    var parsed = try std.json.parseFromSlice(SessionRecord, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return cloneRecord(allocator, parsed.value);
}

pub fn recordToIndexEntry(allocator: std.mem.Allocator, record: SessionRecord) !IndexEntry {
    const session_id = try allocator.dupe(u8, record.session_id);
    errdefer allocator.free(session_id);
    const title = try allocator.dupe(u8, record.title);
    errdefer allocator.free(title);
    const model = try allocator.dupe(u8, record.model);
    errdefer allocator.free(model);
    const search_preview = try buildSearchPreview(allocator, record);
    errdefer allocator.free(search_preview);
    return .{
        .session_id = session_id,
        .title = title,
        .model = model,
        .created_at = record.created_at,
        .updated_at = record.updated_at,
        .copilot = record.copilot,
        .message_count = @intCast(record.messages.len),
        .search_preview = search_preview,
    };
}

pub fn sanitizeSessionFileName(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    var all_safe = session_id.len > 0;
    for (session_id) |c| {
        if (!isSafeFileChar(c)) {
            all_safe = false;
            break;
        }
    }
    if (all_safe) {
        return std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (session_id) |c| {
        try buf.append(allocator, if (isSafeFileChar(c)) c else '_');
    }
    const h = std.hash.Wyhash.hash(0, session_id);
    return std.fmt.allocPrint(allocator, "{s}-{x}.json", .{ buf.items, h });
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |slice| return try allocator.dupe(u8, slice);
    return null;
}

fn cloneRow(allocator: std.mem.Allocator, input: anytype) !Row {
    const session_id = try allocator.dupe(u8, input.session_id);
    errdefer allocator.free(session_id);
    const title = try allocator.dupe(u8, input.title);
    errdefer allocator.free(title);
    const model = try allocator.dupe(u8, input.model);
    errdefer allocator.free(model);

    return .{
        .session_id = session_id,
        .title = title,
        .model = model,
        .updated_at = input.updated_at,
        .copilot = if (@hasField(@TypeOf(input), "copilot")) input.copilot else false,
    };
}

fn freeOwnedRow(allocator: std.mem.Allocator, row: *Row) void {
    allocator.free(row.session_id);
    allocator.free(row.title);
    allocator.free(row.model);
    row.* = undefined;
}

fn cloneMessages(allocator: std.mem.Allocator, message_inputs: anytype) ![]MessageRecord {
    const count = messageInputCount(message_inputs);
    const messages = try allocator.alloc(MessageRecord, count);
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            freeOwnedMessage(allocator, &messages[initialized]);
        }
        allocator.free(messages);
    }

    switch (@typeInfo(@TypeOf(message_inputs))) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                for (message_inputs) |message| {
                    messages[initialized] = try cloneMessage(allocator, message);
                    initialized += 1;
                }
            },
            .one => switch (@typeInfo(pointer.child)) {
                .array => {
                    for (message_inputs) |message| {
                        messages[initialized] = try cloneMessage(allocator, message);
                        initialized += 1;
                    }
                },
                .@"struct" => |info| {
                    if (!info.is_tuple) @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple");
                    inline for (info.fields) |field| {
                        messages[initialized] = try cloneMessage(allocator, @field(message_inputs.*, field.name));
                        initialized += 1;
                    }
                },
                else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
            },
            else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
        },
        .array => {
            for (message_inputs) |message| {
                messages[initialized] = try cloneMessage(allocator, message);
                initialized += 1;
            }
        },
        .@"struct" => |info| {
            if (!info.is_tuple) @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple");
            inline for (info.fields) |field| {
                messages[initialized] = try cloneMessage(allocator, @field(message_inputs, field.name));
                initialized += 1;
            }
        },
        else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
    }

    return messages;
}

fn isLenientJsonLoadError(err: anyerror) bool {
    return switch (err) {
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        error.UnexpectedToken,
        error.InvalidNumber,
        error.InvalidEnumTag,
        error.DuplicateField,
        error.UnknownField,
        error.MissingField,
        error.LengthMismatch,
        error.InvalidCharacter,
        error.Overflow,
        error.BufferUnderrun,
        => true,
        else => false,
    };
}

pub fn defaultPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.agentHistoryPath(allocator);
}

fn messageInputCount(message_inputs: anytype) usize {
    return switch (@typeInfo(@TypeOf(message_inputs))) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => message_inputs.len,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.len,
                .@"struct" => |info| if (info.is_tuple) info.fields.len else @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
                else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
            },
            else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
        },
        .array => |array| array.len,
        .@"struct" => |info| if (info.is_tuple) info.fields.len else @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
        else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
    };
}

test "agent_history: sorts sessions by updated_at descending" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "old",
        .title = "Old",
        .base_url = "https://api.example.com",
        .api_key = "k1",
        .model = "m1",
        .system_prompt = "p1",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 100,
        .updated_at = 100,
        .messages = &.{},
    });
    try store.upsertRecord(.{
        .session_id = "new",
        .title = "New",
        .base_url = "https://api.example.com",
        .api_key = "k2",
        .model = "m2",
        .system_prompt = "p2",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 200,
        .updated_at = 300,
        .messages = &.{},
    });

    const rows = try store.buildRows(allocator);
    defer freeRows(allocator, rows);

    try std.testing.expectEqualStrings("new", rows[0].session_id);
    try std.testing.expectEqualStrings("old", rows[1].session_id);
}

test "agent_history: json round trip preserves messages" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Chat 1",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "m1",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 10,
        .updated_at = 20,
        .messages = &.{
            .{ .role = .user, .content = "hello", .reasoning = null, .usage_footer = null },
            .{ .role = .assistant, .content = "world", .reasoning = "r", .usage_footer = "u" },
        },
    });

    const json = try store.toJsonString(allocator);
    defer allocator.free(json);

    var parsed = try Store.fromJsonString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.records.items[0].messages.len);
    try std.testing.expectEqualStrings("world", parsed.records.items[0].messages[1].content);
}

test "agent_history: json round trip preserves replayable tool metadata" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "session-tool",
        .title = "Tool Session",
        .base_url = "https://api.deepseek.com",
        .api_key = "",
        .model = "deepseek-v4-pro",
        .system_prompt = "You are a helpful assistant.",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{
            .{
                .role = .tool,
                .content = "# Skill: pdf",
                .tool_call_id = "skill-preload-pdf",
                .tool_name = "skill_info",
                .replay_to_model = true,
            },
        },
    });

    const json = try store.toJsonString(allocator);
    defer allocator.free(json);

    var parsed = try Store.fromJsonString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.items.len);
    const message = parsed.records.items[0].messages[0];
    try std.testing.expectEqual(.tool, message.role);
    try std.testing.expectEqualStrings("skill-preload-pdf", message.tool_call_id.?);
    try std.testing.expectEqualStrings("skill_info", message.tool_name.?);
    try std.testing.expect(message.replay_to_model);
}

test "agent_history: malformed json falls back to empty store" {
    const allocator = std.testing.allocator;
    var parsed = try Store.fromJsonStringLenient(allocator, "{not json");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.records.items.len);
}

test "agent_history: missing protocol defaults to chat completions" {
    const allocator = std.testing.allocator;
    const json =
        \\{"records":[{"session_id":"s1","title":"Chat 1","base_url":"https://api.example.com","api_key":"secret","model":"m1","system_prompt":"system","thinking_enabled":true,"reasoning_effort":"high","stream":false,"agent_enabled":true,"created_at":10,"updated_at":20,"messages":[]}]}
    ;
    var parsed = try Store.fromJsonString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.items.len);
    try std.testing.expectEqualStrings(DEFAULT_PROTOCOL, parsed.records.items[0].protocol);
}

test "agent_history: missing max_tokens defaults to 8192" {
    const allocator = std.testing.allocator;
    const json =
        \\{"records":[{"session_id":"s1","title":"Chat 1","base_url":"https://api.example.com","api_key":"secret","model":"m1","system_prompt":"system","thinking_enabled":true,"reasoning_effort":"high","stream":false,"agent_enabled":true,"created_at":10,"updated_at":20,"messages":[]}]}
    ;
    var parsed = try Store.fromJsonString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.items.len);
    try std.testing.expectEqual(@as(u32, 8192), parsed.records.items[0].max_tokens);
}

test "agent_history: json round trip preserves max_tokens" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Chat 1",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "m1",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .max_tokens = 2048,
        .agent_enabled = true,
        .created_at = 10,
        .updated_at = 20,
        .messages = &.{},
    });

    const json = try store.toJsonString(allocator);
    defer allocator.free(json);

    var parsed = try Store.fromJsonString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.items.len);
    try std.testing.expectEqual(@as(u32, 2048), parsed.records.items[0].max_tokens);
}

test "agent_history: buildCopilotRows lists only copilot records, newest first" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    const base = SessionRecord{
        .session_id = "",
        .title = "",
        .base_url = "u",
        .api_key = "k",
        .model = "m",
        .system_prompt = "s",
        .thinking_enabled = false,
        .reasoning_effort = "low",
        .stream = true,
        .agent_enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .messages = &[_]MessageRecord{},
    };
    var a = base;
    a.session_id = "a";
    a.title = "A";
    a.updated_at = 10;
    a.copilot = true;
    var b = base;
    b.session_id = "b";
    b.title = "B";
    b.updated_at = 20;
    b.copilot = true;
    var c = base;
    c.session_id = "c";
    c.title = "C";
    c.updated_at = 99;
    c.copilot = false;
    try store.upsertRecord(a);
    try store.upsertRecord(b);
    try store.upsertRecord(c);

    const rows = try store.buildCopilotRows(allocator);
    defer freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("b", rows[0].session_id); // newest (20) first
    try std.testing.expectEqualStrings("a", rows[1].session_id);
}

test "agent_history: buildRows carries the copilot sidebar flag per record" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    const base = SessionRecord{
        .session_id = "",
        .title = "",
        .base_url = "u",
        .api_key = "k",
        .model = "m",
        .system_prompt = "s",
        .thinking_enabled = false,
        .reasoning_effort = "low",
        .stream = true,
        .agent_enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .messages = &[_]MessageRecord{},
    };
    var sidebar = base;
    sidebar.session_id = "s";
    sidebar.updated_at = 20;
    sidebar.copilot = true;
    var tabrec = base;
    tabrec.session_id = "t";
    tabrec.updated_at = 10;
    tabrec.copilot = false;
    try store.upsertRecord(sidebar);
    try store.upsertRecord(tabrec);

    const rows = try store.buildRows(allocator);
    defer freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("s", rows[0].session_id); // newest (20) first
    try std.testing.expect(rows[0].copilot);
    try std.testing.expectEqualStrings("t", rows[1].session_id);
    try std.testing.expect(!rows[1].copilot);
}

test "agent_history: missing vision_enabled defaults to false" {
    const allocator = std.testing.allocator;
    const json =
        \\{"records":[{"session_id":"s1","title":"Chat 1","base_url":"https://api.example.com","api_key":"secret","model":"m1","system_prompt":"system","thinking_enabled":true,"reasoning_effort":"high","stream":false,"agent_enabled":true,"created_at":10,"updated_at":20,"messages":[]}]}
    ;
    var parsed = try Store.fromJsonString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.items.len);
    try std.testing.expect(!parsed.records.items[0].vision_enabled);
}

test "agent_history: json round trip preserves vision_enabled" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Chat 1",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "m1",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .max_tokens = 2048,
        .agent_enabled = true,
        .vision_enabled = true,
        .created_at = 10,
        .updated_at = 20,
        .messages = &.{},
    });

    const json = try store.toJsonString(allocator);
    defer allocator.free(json);

    var parsed = try Store.fromJsonString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.items.len);
    try std.testing.expect(parsed.records.items[0].vision_enabled);
}

test "agent_history: lenient parse propagates out of memory" {
    const json =
        \\{"records":[{"session_id":"s1","title":"Chat 1","base_url":"https://api.example.com","api_key":"secret","model":"m1","system_prompt":"system","thinking_enabled":true,"reasoning_effort":"high","stream":false,"agent_enabled":true,"created_at":10,"updated_at":20,"messages":[]}]}
    ;

    try expectLenientParseOutOfMemory(json);
}

test "agent_history: upsertOwnedRecord takes ownership and replaces existing record" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    const original = try cloneRecord(allocator, .{
        .session_id = "s1",
        .title = "Old",
        .base_url = "https://api.example.com",
        .api_key = "k1",
        .model = "m1",
        .system_prompt = "p1",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 10,
        .updated_at = 10,
        .messages = &.{},
    });
    try store.upsertOwnedRecord(original);

    const replacement = try cloneRecord(allocator, .{
        .session_id = "s1",
        .title = "New",
        .base_url = "https://api.example.com",
        .api_key = "k2",
        .model = "m2",
        .system_prompt = "p2",
        .thinking_enabled = true,
        .reasoning_effort = "medium",
        .stream = true,
        .agent_enabled = true,
        .created_at = 10,
        .updated_at = 20,
        .messages = &.{
            .{ .role = .assistant, .content = "updated", .reasoning = null, .usage_footer = null },
        },
    });
    try store.upsertOwnedRecord(replacement);

    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try std.testing.expectEqualStrings("New", store.records.items[0].title);
    try std.testing.expectEqualStrings("updated", store.records.items[0].messages[0].content);
}

test "agent_history: upsertRecord cleans owned clone when append fails" {
    const allocator = std.testing.allocator;
    var fail_index: usize = 0;
    var saw_oom = false;
    while (fail_index < 128) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });
        var store = Store.init(failing_allocator.allocator());
        defer store.deinit();

        const result = store.upsertRecord(.{
            .session_id = "s1",
            .title = "OOM",
            .base_url = "https://api.example.com",
            .api_key = "secret",
            .model = "m1",
            .system_prompt = "system",
            .thinking_enabled = true,
            .reasoning_effort = "high",
            .stream = false,
            .agent_enabled = true,
            .created_at = 10,
            .updated_at = 20,
            .messages = &.{},
        });
        if (result) |_| {
            if (!failing_allocator.has_induced_failure) break;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => return err,
        }
    }

    try std.testing.expect(saw_oom);
}

test "agent_history: upsert replaces existing session id instead of duplicating" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "same",
        .title = "First",
        .base_url = "https://api.example.com",
        .api_key = "a",
        .model = "m",
        .system_prompt = "p",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 1,
        .messages = &.{},
    });
    try store.upsertRecord(.{
        .session_id = "same",
        .title = "Second",
        .base_url = "https://api.example.com",
        .api_key = "b",
        .model = "m2",
        .system_prompt = "p2",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 10,
        .messages = &.{},
    });

    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try std.testing.expectEqualStrings("Second", store.records.items[0].title);
}

test "agent_history: deleteBySessionId removes the matching record" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "first",
        .title = "First",
        .base_url = "https://api.example.com",
        .api_key = "a",
        .model = "m1",
        .system_prompt = "p1",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 1,
        .messages = &.{},
    });
    try store.upsertRecord(.{
        .session_id = "second",
        .title = "Second",
        .base_url = "https://api.example.com",
        .api_key = "b",
        .model = "m2",
        .system_prompt = "p2",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 2,
        .updated_at = 2,
        .messages = &.{},
    });

    try std.testing.expect(store.deleteBySessionId("first"));
    try std.testing.expect(!store.deleteBySessionId("missing"));
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try std.testing.expectEqualStrings("second", store.records.items[0].session_id);
}

test "agent_history: buildRows returns owned rows that survive store cleanup" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Chat 1",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "m1",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 10,
        .updated_at = 20,
        .messages = &.{},
    });

    const rows = try store.buildRows(allocator);
    defer freeRows(allocator, rows);

    store.clear();

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("s1", rows[0].session_id);
    try std.testing.expectEqualStrings("Chat 1", rows[0].title);
    try std.testing.expectEqualStrings("m1", rows[0].model);
}

test "agent_history: SessionRecord copilot flag round-trips through JSON" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "copilot-1",
        .title = "T",
        .base_url = "https://x",
        .api_key = "k",
        .model = "m",
        .system_prompt = "s",
        .thinking_enabled = false,
        .reasoning_effort = "low",
        .stream = true,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .copilot = true,
        .messages = &[_]MessageRecord{},
    });

    const json = try store.toJsonString(allocator);
    defer allocator.free(json);

    var reloaded = try Store.fromJsonString(allocator, json);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.records.items.len);
    try std.testing.expect(reloaded.records.items[0].copilot);
}

test "agent_history: old record without copilot field defaults to false" {
    const allocator = std.testing.allocator;
    const json =
        \\{"records":[{"session_id":"old","title":"T","base_url":"u","api_key":"k",
        \\"model":"m","system_prompt":"s","thinking_enabled":false,"reasoning_effort":"low",
        \\"stream":true,"agent_enabled":true,"created_at":1,"updated_at":2,"messages":[]}]}
    ;
    var store = try Store.fromJsonString(allocator, json);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try std.testing.expect(!store.records.items[0].copilot);
}

test "agent_history: index file round-trips" {
    const allocator = std.testing.allocator;
    var entries = [_]IndexEntry{
        .{ .session_id = "s1", .title = "T1", .model = "m1", .created_at = 1, .updated_at = 2, .copilot = false, .message_count = 3, .search_preview = "t1 hello" },
        .{ .session_id = "s2", .title = "T2", .model = "m2", .created_at = 5, .updated_at = 6, .copilot = true, .message_count = 0, .search_preview = "" },
    };
    const json = try dumpIndex(allocator, .{ .version = INDEX_VERSION, .entries = &entries });
    defer allocator.free(json);
    var parsed = try parseIndex(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(INDEX_VERSION, parsed.value.version);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
    try std.testing.expectEqualStrings("s2", parsed.value.entries[1].session_id);
    try std.testing.expect(parsed.value.entries[1].copilot);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.entries[0].message_count);
}

test "agent_history: sanitizeSessionFileName keeps safe ids and hashes unsafe ones" {
    const allocator = std.testing.allocator;
    const safe = try sanitizeSessionFileName(allocator, "session-1719000000000-3");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("session-1719000000000-3.json", safe);
    const unsafe1 = try sanitizeSessionFileName(allocator, "会話/x");
    defer allocator.free(unsafe1);
    const unsafe2 = try sanitizeSessionFileName(allocator, "会話/x");
    defer allocator.free(unsafe2);
    try std.testing.expect(std.mem.endsWith(u8, unsafe1, ".json"));
    try std.testing.expect(std.mem.indexOfScalar(u8, unsafe1, '/') == null);
    try std.testing.expectEqualStrings(unsafe1, unsafe2);
}

test "agent_history: recordToIndexEntry derives bounded lowercase preview" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Hello World",
        .base_url = "https://api.example.com",
        .api_key = "k",
        .model = "m1",
        .system_prompt = "sys",
        .thinking_enabled = false,
        .reasoning_effort = "low",
        .stream = true,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &[_]MessageRecord{.{ .role = .user, .content = "First Question" }},
    });
    var entry = try recordToIndexEntry(allocator, store.records.items[0]);
    defer freeOwnedIndexEntry(allocator, &entry);
    try std.testing.expectEqual(@as(u32, 1), entry.message_count);
    try std.testing.expect(entry.search_preview.len <= SEARCH_PREVIEW_MAX);
    try std.testing.expect(std.unicode.utf8ValidateSlice(entry.search_preview));
    try std.testing.expect(std.mem.indexOf(u8, entry.search_preview, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.search_preview, "first question") != null);
}

test "agent_history: single record JSON round-trips" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Title",
        .base_url = "https://api.example.com",
        .api_key = "k",
        .model = "m1",
        .system_prompt = "sys",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .copilot = true,
        .created_at = 7,
        .updated_at = 9,
        .messages = &[_]MessageRecord{ .{ .role = .user, .content = "hi" }, .{ .role = .assistant, .content = "yo" } },
    });
    const json = try recordToJson(allocator, store.records.items[0]);
    defer allocator.free(json);
    var rec = try recordFromJson(allocator, json);
    defer freeOwnedRecord(allocator, &rec);
    try std.testing.expectEqualStrings("s1", rec.session_id);
    try std.testing.expect(rec.copilot);
    try std.testing.expectEqual(@as(usize, 2), rec.messages.len);
    try std.testing.expectEqualStrings("yo", rec.messages[1].content);
}

test "agent_history: buildRowsFromEntries sorts desc and filters copilot" {
    const allocator = std.testing.allocator;
    var entries = [_]IndexEntry{
        .{ .session_id = "a", .title = "A", .model = "m", .created_at = 1, .updated_at = 1, .copilot = false },
        .{ .session_id = "b", .title = "B", .model = "m", .created_at = 2, .updated_at = 3, .copilot = true },
        .{ .session_id = "c", .title = "C", .model = "m", .created_at = 2, .updated_at = 2, .copilot = false },
    };
    const rows = try buildRowsFromEntries(allocator, &entries);
    defer freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("b", rows[0].session_id);
    try std.testing.expectEqualStrings("c", rows[1].session_id);
    const co = try buildCopilotRowsFromEntries(allocator, &entries);
    defer freeRows(allocator, co);
    try std.testing.expectEqual(@as(usize, 1), co.len);
    try std.testing.expectEqualStrings("b", co[0].session_id);
}

fn expectLenientParseOutOfMemory(json: []const u8) !void {
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = Store.fromJsonStringLenient(failing_allocator.allocator(), json);
        if (result) |store| {
            var owned_store = store;
            owned_store.deinit();
            if (failing_allocator.has_induced_failure) return error.SwallowedOutOfMemory;
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => return,
            else => return err,
        }
    }

    return error.MissingOutOfMemoryPath;
}
