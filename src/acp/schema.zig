//! ACP (Agent Client Protocol) schema — pure protocol types, JSON-RPC params
//! encoding, and result parsing for driving an external CLI agent over
//! stdio. No transport/process concerns here (see the stdio client task) —
//! std-only on purpose so this stays unit-testable with
//! `zig test src/acp/schema.zig`.
const std = @import("std");

/// ACP protocol version this client speaks.
pub const PROTOCOL_VERSION: i64 = 1;

pub const StopReason = enum { end_turn, max_tokens, refusal, cancelled, other };

/// One `tool_call` / `tool_call_update` session update payload. All fields owned;
/// unset string fields are empty slices (never left undefined).
pub const ToolCallInfo = struct {
    id: []u8,
    title: []u8,
    kind: []u8,
    status: []u8,
    content_text: []u8,
    terminal_id: []u8,

    pub fn deinit(self: *ToolCallInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.kind);
        allocator.free(self.status);
        allocator.free(self.content_text);
        allocator.free(self.terminal_id);
    }
};

/// One `session/update` notification payload, narrowed to the variants the
/// copilot cares about. Unrecognized `sessionUpdate` values decode as `.ignored`.
pub const SessionUpdate = union(enum) {
    agent_message_chunk: []u8,
    agent_thought_chunk: []u8,
    tool_call: ToolCallInfo,
    tool_call_update: ToolCallInfo,
    plan: []u8,
    ignored,

    pub fn deinit(self: *SessionUpdate, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .agent_message_chunk => |s| allocator.free(s),
            .agent_thought_chunk => |s| allocator.free(s),
            .tool_call => |*info| info.deinit(allocator),
            .tool_call_update => |*info| info.deinit(allocator),
            .plan => |s| allocator.free(s),
            .ignored => {},
        }
    }
};

/// One option offered by a `session/request_permission` request.
pub const PermissionOption = struct {
    id: []u8,
    name: []u8,
    kind: []u8,

    pub fn deinit(self: *PermissionOption, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.kind);
    }
};

/// A `session/request_permission` request: the tool call it's gating, and the
/// choices the user can make.
pub const PermissionRequest = struct {
    title: []u8,
    options: []PermissionOption,

    pub fn deinit(self: *PermissionRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        for (self.options) |*opt| opt.deinit(allocator);
        allocator.free(self.options);
    }
};

fn objectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn objectValue(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn dupeOrEmpty(allocator: std.mem.Allocator, s: ?[]const u8) ![]u8 {
    return allocator.dupe(u8, s orelse "");
}

/// content 块或块数组 → 拼接其中所有 text；同时提取 terminal 内容块的 terminalId。
fn flattenContent(allocator: std.mem.Allocator, content: std.json.Value, terminal_id_out: *?[]u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const items: []const std.json.Value = switch (content) {
        .array => |arr| arr.items,
        .object => &[_]std.json.Value{content},
        else => &.{},
    };
    for (items) |item| {
        const ty = objectString(item, "type") orelse continue;
        if (std.mem.eql(u8, ty, "text")) {
            if (objectString(item, "text")) |t| try out.appendSlice(allocator, t);
        } else if (std.mem.eql(u8, ty, "content")) {
            // ToolCallContent 包一层 {type:"content",content:{type:"text",...}}
            if (objectValue(item, "content")) |inner| {
                if (objectString(inner, "text")) |t| try out.appendSlice(allocator, t);
            }
        } else if (std.mem.eql(u8, ty, "terminal")) {
            if (objectString(item, "terminalId")) |tid| {
                if (terminal_id_out.* == null) terminal_id_out.* = try allocator.dupe(u8, tid);
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

fn parseToolCall(allocator: std.mem.Allocator, update: std.json.Value) !ToolCallInfo {
    const id = try dupeOrEmpty(allocator, objectString(update, "toolCallId"));
    errdefer allocator.free(id);
    const title = try dupeOrEmpty(allocator, objectString(update, "title"));
    errdefer allocator.free(title);
    const kind = try dupeOrEmpty(allocator, objectString(update, "kind"));
    errdefer allocator.free(kind);
    const status = try dupeOrEmpty(allocator, objectString(update, "status"));
    errdefer allocator.free(status);

    var terminal_id: ?[]u8 = null;
    errdefer if (terminal_id) |t| allocator.free(t);
    const content_text = if (objectValue(update, "content")) |content|
        try flattenContent(allocator, content, &terminal_id)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(content_text);

    return .{
        .id = id,
        .title = title,
        .kind = kind,
        .status = status,
        .content_text = content_text,
        .terminal_id = terminal_id orelse try allocator.dupe(u8, ""),
    };
}

/// `plan` session updates carry an `entries` array; render as a bullet list
/// text blob so the copilot can show it inline.
fn renderPlan(allocator: std.mem.Allocator, update: std.json.Value) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "plan:");
    const entries = objectValue(update, "entries") orelse return out.toOwnedSlice(allocator);
    if (entries == .array) {
        for (entries.array.items) |entry| {
            const content = objectString(entry, "content") orelse continue;
            try out.appendSlice(allocator, "\n- ");
            try out.appendSlice(allocator, content);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Parse one `session/update` notification's `params` into a `SessionUpdate`.
/// Returns `null` when `params` isn't a well-formed update envelope at all
/// (missing `update` / `sessionUpdate`); unrecognized `sessionUpdate` values
/// decode as `.ignored` rather than failing.
pub fn parseSessionUpdate(allocator: std.mem.Allocator, params: std.json.Value) ?SessionUpdate {
    const update = objectValue(params, "update") orelse return null;
    const variant = objectString(update, "sessionUpdate") orelse return null;
    if (std.mem.eql(u8, variant, "agent_message_chunk") or std.mem.eql(u8, variant, "agent_thought_chunk")) {
        const content = objectValue(update, "content") orelse return .ignored;
        var tid: ?[]u8 = null;
        const text = flattenContent(allocator, content, &tid) catch return null;
        if (tid) |t| allocator.free(t);
        if (std.mem.eql(u8, variant, "agent_message_chunk")) return .{ .agent_message_chunk = text };
        return .{ .agent_thought_chunk = text };
    }
    if (std.mem.eql(u8, variant, "tool_call") or std.mem.eql(u8, variant, "tool_call_update")) {
        const info = parseToolCall(allocator, update) catch return null;
        if (std.mem.eql(u8, variant, "tool_call")) return .{ .tool_call = info };
        return .{ .tool_call_update = info };
    }
    if (std.mem.eql(u8, variant, "plan")) {
        return .{ .plan = renderPlan(allocator, update) catch return null };
    }
    return .ignored;
}

/// Parse a `session/request_permission` request's `params`.
pub fn parsePermissionRequest(allocator: std.mem.Allocator, params: std.json.Value) !PermissionRequest {
    const tool_call = objectValue(params, "toolCall") orelse .null;
    const title = try dupeOrEmpty(allocator, objectString(tool_call, "title"));
    errdefer allocator.free(title);

    var options: std.ArrayListUnmanaged(PermissionOption) = .empty;
    errdefer {
        for (options.items) |*opt| opt.deinit(allocator);
        options.deinit(allocator);
    }
    if (objectValue(params, "options")) |opts_val| {
        if (opts_val == .array) {
            for (opts_val.array.items) |opt| {
                const id = try dupeOrEmpty(allocator, objectString(opt, "optionId"));
                errdefer allocator.free(id);
                const name = try dupeOrEmpty(allocator, objectString(opt, "name"));
                errdefer allocator.free(name);
                const kind = try dupeOrEmpty(allocator, objectString(opt, "kind"));
                errdefer allocator.free(kind);
                try options.append(allocator, .{ .id = id, .name = name, .kind = kind });
            }
        }
    }

    return .{ .title = title, .options = try options.toOwnedSlice(allocator) };
}

fn encodeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = s }, .{});
}

/// Build the outcome params for a `session/request_permission` response when
/// the user picked an option: `{"outcome":{"outcome":"selected","optionId":<id>}}`.
pub fn encodePermissionSelected(allocator: std.mem.Allocator, option_id: []const u8) ![]u8 {
    const id_quoted = try encodeJsonString(allocator, option_id);
    defer allocator.free(id_quoted);
    return std.fmt.allocPrint(allocator, "{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":{s}}}}}", .{id_quoted});
}

/// Build the outcome params for a cancelled `session/request_permission`.
pub fn encodePermissionCancelled(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"outcome\":{\"outcome\":\"cancelled\"}}");
}

/// Build `initialize` request params.
pub fn encodeInitializeParams(allocator: std.mem.Allocator, terminal_capability: bool) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"protocolVersion\":{d},\"clientCapabilities\":{{\"fs\":{{\"readTextFile\":false,\"writeTextFile\":false}},\"terminal\":{s}}}}}",
        .{ PROTOCOL_VERSION, if (terminal_capability) "true" else "false" },
    );
}

/// Extract the `protocolVersion` integer from an `initialize` response's `result`.
pub fn parseInitializeProtocolVersion(result: std.json.Value) ?i64 {
    const v = objectValue(result, "protocolVersion") orelse return null;
    return if (v == .integer) v.integer else null;
}

/// Build `session/new` request params.
pub fn encodeNewSessionParams(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const cwd_quoted = try encodeJsonString(allocator, cwd);
    defer allocator.free(cwd_quoted);
    return std.fmt.allocPrint(allocator, "{{\"cwd\":{s},\"mcpServers\":[]}}", .{cwd_quoted});
}

/// Extract the new `sessionId` from a `session/new` response's `result`.
pub fn parseNewSessionId(allocator: std.mem.Allocator, result: std.json.Value) ?[]u8 {
    const s = objectString(result, "sessionId") orelse return null;
    return allocator.dupe(u8, s) catch null;
}

/// Build `session/prompt` request params.
pub fn encodePromptParams(allocator: std.mem.Allocator, session_id: []const u8, text: []const u8) ![]u8 {
    const sid_quoted = try encodeJsonString(allocator, session_id);
    defer allocator.free(sid_quoted);
    const text_quoted = try encodeJsonString(allocator, text);
    defer allocator.free(text_quoted);
    return std.fmt.allocPrint(
        allocator,
        "{{\"sessionId\":{s},\"prompt\":[{{\"type\":\"text\",\"text\":{s}}}]}}",
        .{ sid_quoted, text_quoted },
    );
}

/// Extract the `stopReason` from a `session/prompt` response's `result`.
pub fn parseStopReason(result: std.json.Value) StopReason {
    const s = objectString(result, "stopReason") orelse return .other;
    if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
    if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
    if (std.mem.eql(u8, s, "refusal")) return .refusal;
    if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
    return .other;
}

/// Build `session/cancel` request params.
pub fn encodeCancelParams(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    const sid_quoted = try encodeJsonString(allocator, session_id);
    defer allocator.free(sid_quoted);
    return std.fmt.allocPrint(allocator, "{{\"sessionId\":{s}}}", .{sid_quoted});
}

fn parseValue(a: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, json, .{});
}

test "parseSessionUpdate extracts agent_message_chunk text" {
    const a = std.testing.allocator;
    var p = try parseValue(a,
        \\{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}
    );
    defer p.deinit();
    var u = parseSessionUpdate(a, p.value) orelse return error.TestExpectedUpdate;
    defer u.deinit(a);
    try std.testing.expectEqualStrings("hello", u.agent_message_chunk);
}

test "parseSessionUpdate extracts tool_call with terminal content" {
    const a = std.testing.allocator;
    var p = try parseValue(a,
        \\{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"run tests","kind":"execute","status":"pending","content":[{"type":"terminal","terminalId":"term-abc"}]}}
    );
    defer p.deinit();
    var u = parseSessionUpdate(a, p.value) orelse return error.TestExpectedUpdate;
    defer u.deinit(a);
    try std.testing.expectEqualStrings("run tests", u.tool_call.title);
    try std.testing.expectEqualStrings("term-abc", u.tool_call.terminal_id);
    try std.testing.expectEqualStrings("execute", u.tool_call.kind);
}

test "parseSessionUpdate tolerates unknown variants and malformed params" {
    const a = std.testing.allocator;
    var p = try parseValue(a,
        \\{"sessionId":"s1","update":{"sessionUpdate":"future_thing","x":1}}
    );
    defer p.deinit();
    var u = parseSessionUpdate(a, p.value) orelse return error.TestExpectedUpdate;
    defer u.deinit(a);
    try std.testing.expect(u == .ignored);
    var bad = try parseValue(a, "{\"nope\":true}");
    defer bad.deinit();
    try std.testing.expect(parseSessionUpdate(a, bad.value) == null);
}

test "parsePermissionRequest and outcome encoding round-trip" {
    const a = std.testing.allocator;
    var p = try parseValue(a,
        \\{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Edit main.zig"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}
    );
    defer p.deinit();
    var req = try parsePermissionRequest(a, p.value);
    defer req.deinit(a);
    try std.testing.expectEqualStrings("Edit main.zig", req.title);
    try std.testing.expectEqual(@as(usize, 2), req.options.len);
    try std.testing.expectEqualStrings("allow_once", req.options[0].kind);
    const sel = try encodePermissionSelected(a, "allow");
    defer a.free(sel);
    try std.testing.expectEqualStrings("{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow\"}}", sel);
}

test "initialize/new/prompt param encoding and result parsing" {
    const a = std.testing.allocator;
    const init_params = try encodeInitializeParams(a, true);
    defer a.free(init_params);
    try std.testing.expect(std.mem.indexOf(u8, init_params, "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_params, "\"terminal\":true") != null);
    const prompt = try encodePromptParams(a, "s1", "do it");
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"sessionId\":\"s1\"") != null);
    var stop = try parseValue(a, "{\"stopReason\":\"end_turn\"}");
    defer stop.deinit();
    try std.testing.expectEqual(StopReason.end_turn, parseStopReason(stop.value));
    var sid = try parseValue(a, "{\"sessionId\":\"abc\"}");
    defer sid.deinit();
    const id = parseNewSessionId(a, sid.value) orelse return error.TestExpectedId;
    defer a.free(id);
    try std.testing.expectEqualStrings("abc", id);
}
