//! API wire format for the agent chat: protocol data types, request-JSON
//! building, and response parsing. Pure w.r.t. Session/threads — takes plain
//! data + an allocator. (Imports the platform tool-description facades that the
//! tool-schema builders already used.)
const std = @import("std");
const first_party_tools = @import("../../tools/first_party.zig");
const platform_process = @import("../../platform/process.zig");
const platform_pty_command = @import("../../platform/pty_command.zig");

pub const DEFAULT_PROTOCOL = "chat_completions";
pub const DEFAULT_THINKING = "enabled";
pub const DEFAULT_REASONING_EFFORT = "high";
pub const DEFAULT_STREAM = "false";
pub const DEFAULT_AGENT = "true";
pub const DEFAULT_MAX_TOKENS = "8192";
pub const DEFAULT_VISION = "off";
pub const TOOL_CALL_REASONING_FALLBACK = "Tool call is required before answering.";

// ---------------------------------------------------------------------------
// Protocol types
// ---------------------------------------------------------------------------

pub const ApiProtocol = enum {
    chat_completions,
    responses,
    anthropic,

    pub fn parse(value: []const u8) ApiProtocol {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return .chat_completions;
        if (std.ascii.eqlIgnoreCase(trimmed, "responses") or
            std.ascii.eqlIgnoreCase(trimmed, "response"))
        {
            return .responses;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "anthropic") or
            std.ascii.eqlIgnoreCase(trimmed, "claude") or
            std.ascii.eqlIgnoreCase(trimmed, "messages"))
        {
            return .anthropic;
        }
        return .chat_completions;
    }

    pub fn name(self: ApiProtocol) []const u8 {
        return switch (self) {
            .chat_completions => DEFAULT_PROTOCOL,
            .responses => "responses",
            .anthropic => "anthropic",
        };
    }

    /// Cycle to the next/previous valid protocol (wraps). Used by the AI profile
    /// form so the Protocol field is a toggle over valid values, not free text.
    pub fn cycle(self: ApiProtocol, forward: bool) ApiProtocol {
        if (forward) {
            return switch (self) {
                .chat_completions => .responses,
                .responses => .anthropic,
                .anthropic => .chat_completions,
            };
        }
        return switch (self) {
            .chat_completions => .anthropic,
            .responses => .chat_completions,
            .anthropic => .responses,
        };
    }
};

test "ApiProtocol.cycle toggles forward and backward through the valid set, wrapping" {
    // forward
    try std.testing.expectEqual(ApiProtocol.responses, ApiProtocol.chat_completions.cycle(true));
    try std.testing.expectEqual(ApiProtocol.anthropic, ApiProtocol.responses.cycle(true));
    try std.testing.expectEqual(ApiProtocol.chat_completions, ApiProtocol.anthropic.cycle(true));
    // backward
    try std.testing.expectEqual(ApiProtocol.anthropic, ApiProtocol.chat_completions.cycle(false));
    try std.testing.expectEqual(ApiProtocol.chat_completions, ApiProtocol.responses.cycle(false));
    try std.testing.expectEqual(ApiProtocol.responses, ApiProtocol.anthropic.cycle(false));
    // a full forward loop returns to start
    try std.testing.expectEqual(ApiProtocol.chat_completions, ApiProtocol.chat_completions.cycle(true).cycle(true).cycle(true));
}

pub const Role = enum {
    user,
    assistant,
    tool,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .user => "You",
            .assistant => "AI",
            .tool => "Tool",
        };
    }

    pub fn apiName(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

/// A base64-encoded image attached to a user message. Both fields are owned by
/// whoever holds the block (the session message, or a cloned request message).
pub const ImageBlock = struct {
    data_b64: []u8,
    media_type: []u8,

    pub fn deinit(self: ImageBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.data_b64);
        allocator.free(self.media_type);
    }

    pub fn clone(self: ImageBlock, allocator: std.mem.Allocator) !ImageBlock {
        const data = try allocator.dupe(u8, self.data_b64);
        errdefer allocator.free(data);
        const media = try allocator.dupe(u8, self.media_type);
        return .{ .data_b64 = data, .media_type = media };
    }
};

/// Deep-clone a slice of image blocks (or null). Frees partial work on error.
pub fn cloneImageBlocks(allocator: std.mem.Allocator, images: ?[]const ImageBlock) !?[]ImageBlock {
    const src = images orelse return null;
    if (src.len == 0) return null;
    const out = try allocator.alloc(ImageBlock, src.len);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |img| img.deinit(allocator);
        allocator.free(out);
    }
    while (written < src.len) : (written += 1) {
        out[written] = try src[written].clone(allocator);
    }
    return out;
}

pub const RequestMessage = struct {
    role: Role,
    content: []u8,
    reasoning: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_calls: ?[]ToolCall = null,
    images: ?[]ImageBlock = null,

    pub fn deinit(self: RequestMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
        if (self.images) |images| {
            for (images) |img| img.deinit(allocator);
            allocator.free(images);
        }
    }

    /// True when this is a user message carrying at least one image.
    pub fn hasImages(self: RequestMessage) bool {
        if (self.role != .user) return false;
        const images = self.images orelse return false;
        return images.len > 0;
    }
};

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments: []u8,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

pub const ApiResult = struct {
    content: []u8,
    reasoning: ?[]u8 = null,
    tool_calls: ?[]ToolCall = null,
    usage: ?ApiUsage = null,
    api_error: bool = false,

    pub fn deinit(self: ApiResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
    }
};

pub const ApiUsage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    prompt_cache_hit_tokens: u64 = 0,
    prompt_cache_miss_tokens: u64 = 0,
    total_tokens: u64 = 0,

    pub fn add(self: *ApiUsage, other: ApiUsage) void {
        self.prompt_tokens += other.prompt_tokens;
        self.completion_tokens += other.completion_tokens;
        self.prompt_cache_hit_tokens += other.prompt_cache_hit_tokens;
        self.prompt_cache_miss_tokens += other.prompt_cache_miss_tokens;
        self.total_tokens += other.total_tokens;
    }
};

pub const DynamicToolSpec = struct {
    name: []const u8,
    description: []const u8,
};

/// One MCP tool advertised to the model. `properties_json` is the JSON Schema
/// `properties` map (inner object) that the emitter wraps in
/// `{"type":"object","properties": ...}`, derived from the server's inputSchema
/// at discovery time. `required` is not carried (v0 — the model still sees each
/// property's description).
pub const McpToolSpec = struct {
    name: []const u8,
    description: []const u8,
    properties_json: []const u8,
};

// ---------------------------------------------------------------------------
// Request building
// ---------------------------------------------------------------------------

pub const RequestParams = struct {
    model: []const u8,
    system_prompt: []const u8,
    protocol: ApiProtocol,
    thinking_enabled: bool,
    reasoning_effort: []const u8,
    stream: bool,
    max_tokens: u32 = 8192,
    memory_enabled: bool = false,
    toolset: Toolset = .full,
    dynamic_tools: []const DynamicToolSpec = &.{},
    mcp_tools: []const McpToolSpec = &.{},
    disabled_first_party_tools: []const []const u8 = &.{},
};

pub fn buildRequestJson(allocator: std.mem.Allocator, params: RequestParams, messages: []const RequestMessage, include_tools: bool) ![]u8 {
    return switch (params.protocol) {
        .chat_completions => buildChatCompletionsRequestJsonForMessages(allocator, params, messages, include_tools),
        .responses => buildResponsesRequestJsonForMessages(allocator, params, messages, include_tools),
        .anthropic => buildAnthropicRequestJsonForMessages(allocator, params, messages, include_tools),
    };
}

pub fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    var i: usize = 0;
    while (i < value.len) {
        const ch = value[i];
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (ch < 0x20) {
                try out.appendSlice(allocator, "\\u00");
                try out.append(allocator, hex[ch >> 4]);
                try out.append(allocator, hex[ch & 0x0f]);
            } else if (ch < 0x80) {
                try out.append(allocator, ch);
            } else {
                const len = std.unicode.utf8ByteSequenceLength(ch) catch {
                    try out.appendSlice(allocator, "\\ufffd");
                    i += 1;
                    continue;
                };
                if (i + len > value.len) {
                    try out.appendSlice(allocator, "\\ufffd");
                    i += 1;
                    continue;
                }
                _ = std.unicode.utf8Decode(value[i .. i + len]) catch {
                    try out.appendSlice(allocator, "\\ufffd");
                    i += 1;
                    continue;
                };
                try out.appendSlice(allocator, value[i .. i + len]);
                i += len;
                continue;
            },
        }
        i += 1;
    }
    try out.append(allocator, '"');
}

pub fn isDeepSeekBaseUrl(base_url: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(base_url, "deepseek.com") != null;
}

pub fn isAnthropicBaseUrl(base_url: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(base_url, "api.anthropic.com") != null;
}

pub fn apiEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8, protocol: ApiProtocol) ![]u8 {
    return switch (protocol) {
        .chat_completions => chatEndpoint(allocator, base_url_raw),
        .responses => responsesEndpoint(allocator, base_url_raw),
        .anthropic => messagesEndpoint(allocator, base_url_raw),
    };
}

pub fn chatEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8) ![]u8 {
    return endpointWithSuffix(allocator, base_url_raw, "/chat/completions");
}

pub fn responsesEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8) ![]u8 {
    return endpointWithSuffix(allocator, base_url_raw, "/responses");
}

pub fn messagesEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8) ![]u8 {
    return endpointWithSuffix(allocator, base_url_raw, "/v1/messages");
}

pub fn endpointWithSuffix(allocator: std.mem.Allocator, base_url_raw: []const u8, suffix: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, base_url_raw, " \t\r\n");
    if (trimmed.len == 0) return error.MissingBaseUrl;
    var end = trimmed.len;
    while (end > 0 and trimmed[end - 1] == '/') end -= 1;
    const normalized = trimmed[0..end];
    if (std.mem.endsWith(u8, normalized, suffix)) {
        return allocator.dupe(u8, normalized);
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ normalized, suffix });
}

fn buildChatCompletionsRequestJsonForMessages(
    allocator: std.mem.Allocator,
    params: RequestParams,
    messages: []const RequestMessage,
    include_tools: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"model\":");
    try appendJsonString(allocator, &out, params.model);
    try out.appendSlice(allocator, ",\"messages\":[");
    if (params.system_prompt.len > 0) {
        try out.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
        try appendJsonString(allocator, &out, params.system_prompt);
        try out.append(allocator, '}');
        if (messages.len > 0) try out.append(allocator, ',');
    }
    for (messages, 0..) |msg, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"role\":");
        try appendJsonString(allocator, &out, msg.role.apiName());
        try out.appendSlice(allocator, ",\"content\":");
        if (msg.hasImages()) {
            try appendChatCompletionsImageContent(allocator, &out, msg);
        } else {
            try appendJsonString(allocator, &out, msg.content);
        }
        if (msg.role == .tool) {
            if (msg.tool_call_id) |id| {
                try out.appendSlice(allocator, ",\"tool_call_id\":");
                try appendJsonString(allocator, &out, id);
            }
        }
        if (msg.tool_calls) |calls| {
            try out.appendSlice(allocator, ",\"tool_calls\":[");
            for (calls, 0..) |call, call_i| {
                if (call_i > 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, "{\"id\":");
                try appendJsonString(allocator, &out, call.id);
                try out.appendSlice(allocator, ",\"type\":\"function\",\"function\":{\"name\":");
                try appendJsonString(allocator, &out, call.name);
                try out.appendSlice(allocator, ",\"arguments\":");
                try appendJsonString(allocator, &out, call.arguments);
                try out.appendSlice(allocator, "}}");
            }
            try out.append(allocator, ']');
        }
        if (msg.role == .assistant) {
            if (msg.reasoning) |reasoning| {
                if (reasoning.len > 0) {
                    try out.appendSlice(allocator, ",\"reasoning_content\":");
                    try appendJsonString(allocator, &out, reasoning);
                }
            } else if (params.thinking_enabled and msg.tool_calls != null) {
                try out.appendSlice(allocator, ",\"reasoning_content\":");
                try appendJsonString(allocator, &out, TOOL_CALL_REASONING_FALLBACK);
            }
        }
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"thinking\":{\"type\":");
    try appendJsonString(allocator, &out, if (params.thinking_enabled) "enabled" else "disabled");
    try out.append(allocator, '}');
    if (params.thinking_enabled) {
        try out.appendSlice(allocator, ",\"reasoning_effort\":");
        try appendJsonString(allocator, &out, if (params.reasoning_effort.len > 0) params.reasoning_effort else "high");
    }
    try out.appendSlice(allocator, ",\"stream\":");
    try out.appendSlice(allocator, if (params.stream) "true" else "false");
    if (params.stream) {
        try out.appendSlice(allocator, ",\"stream_options\":{\"include_usage\":true}");
    }
    if (include_tools) {
        try appendToolSchemas(allocator, &out, .{ .include_memory = params.memory_enabled, .toolset = params.toolset, .dynamic_tools = params.dynamic_tools, .mcp_tools = params.mcp_tools, .disabled_first_party_tools = params.disabled_first_party_tools });
    }
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

fn buildResponsesRequestJsonForMessages(
    allocator: std.mem.Allocator,
    params: RequestParams,
    messages: []const RequestMessage,
    include_tools: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"model\":");
    try appendJsonString(allocator, &out, params.model);
    if (params.system_prompt.len > 0) {
        try out.appendSlice(allocator, ",\"instructions\":");
        try appendJsonString(allocator, &out, params.system_prompt);
    }
    try out.appendSlice(allocator, ",\"input\":[");
    var wrote_item = false;
    for (messages) |msg| {
        if (msg.role == .tool) {
            const id = msg.tool_call_id orelse continue;
            if (id.len == 0) continue;
            if (wrote_item) try out.append(allocator, ',');
            try appendResponseFunctionCallOutput(allocator, &out, id, msg.content);
            wrote_item = true;
            continue;
        }

        if (msg.content.len > 0 or msg.hasImages()) {
            if (wrote_item) try out.append(allocator, ',');
            if (msg.hasImages()) {
                try appendResponseUserImageMessage(allocator, &out, msg);
            } else {
                try appendResponseMessage(allocator, &out, msg.role, msg.content);
            }
            wrote_item = true;
        }

        if (msg.role == .assistant) {
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    if (wrote_item) try out.append(allocator, ',');
                    try appendResponseFunctionCall(allocator, &out, call);
                    wrote_item = true;
                }
            }
        }
    }
    try out.append(allocator, ']');
    if (params.thinking_enabled and params.reasoning_effort.len > 0) {
        try out.appendSlice(allocator, ",\"reasoning\":{\"effort\":");
        try appendJsonString(allocator, &out, params.reasoning_effort);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, ",\"stream\":");
    try out.appendSlice(allocator, if (params.stream) "true" else "false");
    if (include_tools) {
        try appendResponseToolSchemas(allocator, &out, .{ .include_memory = params.memory_enabled, .toolset = params.toolset, .dynamic_tools = params.dynamic_tools, .mcp_tools = params.mcp_tools, .disabled_first_party_tools = params.disabled_first_party_tools });
    }
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

fn buildAnthropicRequestJsonForMessages(
    allocator: std.mem.Allocator,
    params: RequestParams,
    messages: []const RequestMessage,
    include_tools: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"model\":");
    try appendJsonString(allocator, &out, params.model);
    try out.print(allocator, ",\"max_tokens\":{d}", .{params.max_tokens});
    if (params.system_prompt.len > 0) {
        try out.appendSlice(allocator, ",\"system\":");
        try appendJsonString(allocator, &out, params.system_prompt);
    }
    try out.appendSlice(allocator, ",\"messages\":[");
    try appendAnthropicMessages(allocator, &out, messages);
    try out.append(allocator, ']');
    if (include_tools) try appendAnthropicTools(allocator, &out, .{ .include_memory = params.memory_enabled, .toolset = params.toolset, .dynamic_tools = params.dynamic_tools, .mcp_tools = params.mcp_tools, .disabled_first_party_tools = params.disabled_first_party_tools });
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendAnthropicMessages(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), messages: []const RequestMessage) !void {
    var first = true;
    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];
        if (msg.role == .tool) {
            // Anthropic requires tool results grouped into one user turn: collapse
            // consecutive .tool messages into a single user message of tool_result blocks.
            if (!first) try out.append(allocator, ',');
            first = false;
            try out.appendSlice(allocator, "{\"role\":\"user\",\"content\":[");
            var jt: usize = i;
            var block_first = true;
            while (jt < messages.len and messages[jt].role == .tool) : (jt += 1) {
                if (!block_first) try out.append(allocator, ',');
                block_first = false;
                try out.appendSlice(allocator, "{\"type\":\"tool_result\",\"tool_use_id\":");
                try appendJsonString(allocator, out, messages[jt].tool_call_id orelse "");
                try out.appendSlice(allocator, ",\"content\":");
                try appendJsonString(allocator, out, messages[jt].content);
                try out.append(allocator, '}');
            }
            try out.appendSlice(allocator, "]}");
            i = jt;
            continue;
        }
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, "{\"role\":");
        try appendJsonString(allocator, out, msg.role.apiName());
        if (msg.role == .assistant and msg.tool_calls != null and msg.tool_calls.?.len > 0) {
            try out.appendSlice(allocator, ",\"content\":[");
            var wrote = false;
            if (msg.content.len > 0) {
                try out.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
                try appendJsonString(allocator, out, msg.content);
                try out.append(allocator, '}');
                wrote = true;
            }
            for (msg.tool_calls.?) |call| {
                if (wrote) try out.append(allocator, ',');
                wrote = true;
                try out.appendSlice(allocator, "{\"type\":\"tool_use\",\"id\":");
                try appendJsonString(allocator, out, call.id);
                try out.appendSlice(allocator, ",\"name\":");
                try appendJsonString(allocator, out, call.name);
                try out.appendSlice(allocator, ",\"input\":");
                // arguments is already a JSON object string; embed verbatim.
                if (call.arguments.len > 0) {
                    try out.appendSlice(allocator, call.arguments);
                } else {
                    try out.appendSlice(allocator, "{}");
                }
                try out.append(allocator, '}');
            }
            try out.appendSlice(allocator, "]}");
        } else if (msg.hasImages()) {
            try appendAnthropicImageContent(allocator, out, msg);
        } else {
            try out.appendSlice(allocator, ",\"content\":");
            try appendJsonString(allocator, out, msg.content);
            try out.append(allocator, '}');
        }
        i += 1;
    }
}

fn appendAnthropicTools(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), opts: ToolSpecOpts) !void {
    try out.appendSlice(allocator, ",\"tools\":[");
    var ctx = AnthropicToolEmitter{ .allocator = allocator, .out = out };
    try forEachToolSpec(*AnthropicToolEmitter, &ctx, opts, AnthropicToolEmitter.emit);
    try out.append(allocator, ']');
}

fn appendResponseMessage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), role: Role, content: []const u8) !void {
    try out.appendSlice(allocator, "{\"role\":");
    try appendJsonString(allocator, out, role.apiName());
    try out.appendSlice(allocator, ",\"content\":");
    try appendJsonString(allocator, out, content);
    try out.append(allocator, '}');
}

fn appendResponseFunctionCall(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), call: ToolCall) !void {
    try out.appendSlice(allocator, "{\"type\":\"function_call\",\"call_id\":");
    try appendJsonString(allocator, out, call.id);
    try out.appendSlice(allocator, ",\"name\":");
    try appendJsonString(allocator, out, call.name);
    try out.appendSlice(allocator, ",\"arguments\":");
    try appendJsonString(allocator, out, call.arguments);
    try out.append(allocator, '}');
}

fn appendResponseFunctionCallOutput(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    call_id: []const u8,
    output: []const u8,
) !void {
    try out.appendSlice(allocator, "{\"type\":\"function_call_output\",\"call_id\":");
    try appendJsonString(allocator, out, call_id);
    try out.appendSlice(allocator, ",\"output\":");
    try appendJsonString(allocator, out, output);
    try out.append(allocator, '}');
}

// --- Multimodal (image) content for user messages ---------------------------
//
// Only user messages carry images (RequestMessage.hasImages gates on role). Each
// protocol wraps the prompt text and the base64 image data into its own content
// array shape. base64 data and the controlled media type are JSON-safe, so the
// data URI / data field is appended raw between quotes.

fn appendChatCompletionsImageContent(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), msg: RequestMessage) !void {
    try out.appendSlice(allocator, "[{\"type\":\"text\",\"text\":");
    try appendJsonString(allocator, out, msg.content);
    try out.append(allocator, '}');
    for (msg.images.?) |img| {
        try out.appendSlice(allocator, ",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
        try out.appendSlice(allocator, img.media_type);
        try out.appendSlice(allocator, ";base64,");
        try out.appendSlice(allocator, img.data_b64);
        try out.appendSlice(allocator, "\"}}");
    }
    try out.append(allocator, ']');
}

fn appendAnthropicImageContent(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), msg: RequestMessage) !void {
    try out.appendSlice(allocator, ",\"content\":[{\"type\":\"text\",\"text\":");
    try appendJsonString(allocator, out, msg.content);
    try out.append(allocator, '}');
    for (msg.images.?) |img| {
        try out.appendSlice(allocator, ",{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"");
        try out.appendSlice(allocator, img.media_type);
        try out.appendSlice(allocator, "\",\"data\":\"");
        try out.appendSlice(allocator, img.data_b64);
        try out.appendSlice(allocator, "\"}}");
    }
    try out.appendSlice(allocator, "]}");
}

fn appendResponseUserImageMessage(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), msg: RequestMessage) !void {
    try out.appendSlice(allocator, "{\"role\":");
    try appendJsonString(allocator, out, msg.role.apiName());
    try out.appendSlice(allocator, ",\"content\":[{\"type\":\"input_text\",\"text\":");
    try appendJsonString(allocator, out, msg.content);
    try out.append(allocator, '}');
    for (msg.images.?) |img| {
        try out.appendSlice(allocator, ",{\"type\":\"input_image\",\"image_url\":\"data:");
        try out.appendSlice(allocator, img.media_type);
        try out.appendSlice(allocator, ";base64,");
        try out.appendSlice(allocator, img.data_b64);
        try out.appendSlice(allocator, "\"}");
    }
    try out.appendSlice(allocator, "]}");
}

/// Tool visibility for one request. `.subagent` = the nested research
/// subagent's restricted read-only set; gates BOTH schema emission
/// (forEachToolSpec) and dispatch (runSubagentTaskWithModel).
pub const Toolset = enum { full, subagent };

pub const ToolSpecOpts = struct {
    include_memory: bool,
    toolset: Toolset = .full,
    dynamic_tools: []const DynamicToolSpec = &.{},
    mcp_tools: []const McpToolSpec = &.{},
    disabled_first_party_tools: []const []const u8 = &.{},
};

/// Single source of truth for what a subagent may call. Every listed tool is
/// read-only and approval-free.
pub const subagent_allowed_tools = [_][]const u8{
    "terminal_list", "terminal_snapshot", "read_file",
    "websearch",     "webread",           "pubmed",
    "wispterm_docs",
};

pub fn subagentToolAllowed(name: []const u8) bool {
    for (subagent_allowed_tools) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return true;
    }
    return false;
}

pub fn builtinToolNameReserved(name: []const u8) bool {
    const reserved = [_][]const u8{
        "terminal_list",
        "terminal_context",
        "terminal_snapshot",
        "terminal_select",
        "shell_exec",
        "powershell_exec",
        "ssh_session_exec",
        "wsl_session_exec",
        "terminal_repl_exec",
        "terminal_answer_prompt",
        "ask_user",
        "continue_later",
        "read_file",
        "copy_file",
        "write_file",
        "edit_file",
        "ssh_profile_save",
        "ssh_profile_connect",
        "tab_new",
        "tab_close",
        "skill_info",
        "wispterm_docs",
        "mcp_config",
        "mcp_activate",
        "websearch",
        "webread",
        "pubmed",
        "subagent",
        "send_attachment",
        "memory_save",
        "memory_recall",
        "memory_delete",
    };
    for (reserved) |reserved_name| {
        if (std.mem.eql(u8, name, reserved_name)) return true;
    }
    return false;
}

fn dynamicToolNameSeenBefore(tools: []const DynamicToolSpec, index: usize) bool {
    const name = tools[index].name;
    for (tools[0..index]) |previous| {
        if (std.mem.eql(u8, previous.name, name)) return true;
    }
    return false;
}

fn mcpToolNameSeenBefore(tools: []const McpToolSpec, index: usize) bool {
    const name = tools[index].name;
    for (tools[0..index]) |previous| {
        if (std.mem.eql(u8, previous.name, name)) return true;
    }
    return false;
}

// Single source of truth for the agent tool set. Each tool's name, description,
// and JSON Schema `properties` object is defined exactly once here and yielded to
// a per-format emitter (OpenAI chat-completions, OpenAI responses, Anthropic), so
// the schema text is never duplicated across protocols.
//
// `Ctx` is the emitter's context type; `emit` receives `(ctx, name, description,
// properties, required)` for every active tool, in order.
fn forEachToolSpec(
    comptime Ctx: type,
    ctx: Ctx,
    opts: ToolSpecOpts,
    comptime emit: fn (Ctx, []const u8, []const u8, []const u8, []const []const u8) anyerror!void,
) !void {
    const Filtered = struct {
        fn emitTool(c: Ctx, o: ToolSpecOpts, name: []const u8, description: []const u8, properties: []const u8) anyerror!void {
            try emitToolWithRequired(c, o, name, description, properties, &.{});
        }

        fn emitToolWithRequired(c: Ctx, o: ToolSpecOpts, name: []const u8, description: []const u8, properties: []const u8, required: []const []const u8) anyerror!void {
            if (o.toolset == .subagent and !subagentToolAllowed(name)) return;
            if (first_party_tools.isKnown(name) and first_party_tools.isDisabledName(o.disabled_first_party_tools, name)) return;
            try emit(c, name, description, properties, required);
        }
    };
    try Filtered.emitTool(ctx, opts, "terminal_list", "List WispTerm terminal surfaces visible to the agent, including the current agent-selected write context. Before any terminal write, use terminal_select to choose the intended surface_id; use focused=true only as a default hint.", "{}");
    try Filtered.emitTool(ctx, opts, "terminal_context", "Report the current selected terminal write context/binding without changing it. Use this to verify which terminal Copilot or the agent will write to.", "{}");
    try Filtered.emitTool(ctx, opts, "terminal_snapshot", "Read a bounded text snapshot from one terminal surface or all surfaces.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Optional surface id from terminal_list.\"}}");
    try Filtered.emitTool(ctx, opts, "ui_screenshot", "Capture a PNG screenshot of the active WispTerm tab or the focused panel in the active tab. Use target=focused_panel for the panel the user is looking at, or target=active_tab for the whole visible active tab. In a dedicated AI/Copilot tab, focused_panel falls back to active_tab. The tool returns a local PNG path; when the request came from a chat channel (WeChat or Feishu), call send_attachment with kind=image and that path.", "{\"target\":{\"type\":\"string\",\"description\":\"Optional: focused_panel (default) or active_tab.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Optional terminal surface id from terminal_list. Only valid for terminal panels in the active tab.\"}}");
    try Filtered.emitTool(ctx, opts, "terminal_select", platform_pty_command.terminalSelectToolDescription(), "{\"surface_id\":{\"type\":\"string\",\"description\":\"Surface id from terminal_list to make the current agent write context.\"}}");
    try Filtered.emitTool(ctx, opts, "terminal_focus", "Focus and activate a terminal surface in the WispTerm UI by surface_id. Use this before ui_screenshot when the user asks for a screenshot of a tab or panel that is not currently focused. This changes UI focus only; use terminal_select separately before terminal writes.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Surface id from terminal_list to focus in the visible UI.\"}}");
    try Filtered.emitTool(ctx, opts, platform_process.localCommandToolName(), platform_process.localCommandToolDescription(), "{\"command\":{\"type\":\"string\"},\"cwd\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}");
    try Filtered.emitTool(ctx, opts, "ssh_session_exec", "Run a POSIX shell command in the selected already-open SSH terminal surface. The surface_id must match the current terminal_select context. Use only when the surface is at a shell prompt and the command returns; for R, Python, Codex, Claude Code, other REPLs, or launching full-screen agent apps, use terminal_repl_exec.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Selected surface id from terminal_select.\"},\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}");
    if (platform_pty_command.wslSessionToolsEnabled()) {
        try Filtered.emitTool(ctx, opts, platform_pty_command.wslSessionToolName(), platform_pty_command.wslSessionToolDescription(), platform_pty_command.wslSessionToolPropertiesJson());
    }
    try Filtered.emitTool(ctx, opts, "terminal_repl_exec", "Send code or text to the selected already-open interactive REPL/app terminal without shell syntax. The surface_id must match the current terminal_select context. Use repl=r for R, repl=python for Python, repl=codex for Codex, repl=claude_code for Claude Code, or repl=plain for raw text input. For Codex and Claude Code, this waits until the app settles, requests approval/input, reports completion/failure, or reaches timeout_ms.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Selected surface id from terminal_select.\"},\"repl\":{\"type\":\"string\",\"description\":\"r, python, codex, claude_code, or plain\"},\"code\":{\"type\":\"string\",\"description\":\"Code or plain text to submit. To send a control key instead, set code to exactly one of <ctrl-c>, <ctrl-d>, <ctrl-u>, <esc>, <enter> — e.g. to interrupt a stuck command or leave a `>` continuation prompt.\"},\"timeout_ms\":{\"type\":\"integer\"}}");
    try Filtered.emitTool(ctx, opts, "terminal_answer_prompt", "Answer a Claude Code or Codex confirmation/approval prompt in a terminal surface. Reads the on-screen options and sends the correct keystroke. Prefer this over terminal_repl_exec to confirm or reject an agent approval menu. Only acts when a prompt is awaiting input; otherwise it reports the screen and sends nothing.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Optional surface id; defaults to the focused terminal.\"},\"answer\":{\"type\":\"string\",\"description\":\"approve (the plain Yes), approve_all (Yes + allow all / don't ask again), reject (No / cancel), enter, esc, or an explicit option digit 1-9.\"}}");
    try Filtered.emitTool(ctx, opts, "ask_user", "Ask the user a single multiple-choice question and block until they answer. Use when you reach a genuine decision you should not guess (which target, which of several matches, a risky direction). Provide 2 or more options; the user may also type a custom free-text answer. Returns the user's choice. The question is shown as a card in the chat and, when the request came from WeChat, pushed there too.", "{\"question\":{\"type\":\"string\",\"description\":\"The question to ask. One sentence.\"},\"options\":{\"type\":\"array\",\"description\":\"Two or more answer options.\",\"items\":{\"type\":\"object\",\"properties\":{\"label\":{\"type\":\"string\",\"description\":\"Short option label.\"},\"description\":{\"type\":\"string\",\"description\":\"Optional one-line explanation of the option.\"}},\"required\":[\"label\"]}}}");
    try Filtered.emitToolWithRequired(ctx, opts, "continue_later", "Schedule this same Agent or Copilot session to continue later. Use when a terminal command, SSH command, Codex/Claude Code run, or REPL task is still running and immediate polling would waste tokens or risk duplicate side effects. At wake time WispTerm submits message back into this session; the message should inspect progress with terminal_snapshot before acting.", "{\"delay\":{\"type\":\"string\",\"description\":\"Required positive interval: integer plus s, m, h, or d, e.g. 30m, 2h, 1d.\"},\"message\":{\"type\":\"string\",\"description\":\"Optional follow-up prompt. Defaults to continuing the previous task and checking terminal_snapshot first.\"}}", &.{"delay"});
    try Filtered.emitTool(ctx, opts, "read_file", "Read a local, WSL, or SSH text file. Returns numbered lines. Set surface_id to an open terminal surface to read there; omitted surface_id follows the selected terminal context, or local when none is selected. Relative paths resolve against that surface cwd or the agent working directory.", "{\"path\":{\"type\":\"string\",\"description\":\"File path. Absolute, or relative to the selected surface cwd / working directory.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Optional terminal surface id (from terminal_list). Omit to use the selected terminal context, or local when none is selected.\"},\"offset\":{\"type\":\"integer\",\"description\":\"Optional 1-based first line to return.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Optional maximum number of lines to return.\"}}");
    try Filtered.emitTool(ctx, opts, "copy_file", "Copy a binary/artifact file between local workspace, WSL, and SSH without pasting shell commands into a terminal. Pull mode: omit dest_surface_id and dest_path to copy source_path into local wispterm-files and return local_path, useful before send_attachment. Push mode: set dest_surface_id to an open WSL or SSH terminal to copy a local/Weixin/workspace file to that environment. Relative source paths resolve against source_surface_id cwd or the agent working directory; relative destination paths resolve against dest_surface_id cwd or the agent working directory.", "{\"source_path\":{\"type\":\"string\",\"description\":\"Path to the source file. Relative paths resolve against source_surface_id cwd, or the agent working directory when source_surface_id is omitted.\"},\"source_surface_id\":{\"type\":\"string\",\"description\":\"Optional source terminal id from terminal_list. SSH pulls via scp; WSL uses a host-accessible WSL path; omitted means local.\"},\"dest_surface_id\":{\"type\":\"string\",\"description\":\"Optional destination terminal id from terminal_list. Use an SSH or WSL surface to send a local file there. Omit to copy into local wispterm-files.\"},\"dest_path\":{\"type\":\"string\",\"description\":\"Optional destination file path. Relative paths resolve against destination surface cwd, or the agent working directory for local destinations. If omitted, uses dest_name or the source basename.\"},\"dest_name\":{\"type\":\"string\",\"description\":\"Optional safe destination filename. In pull mode it is placed inside wispterm-files. Must not contain path separators.\"}}");
    try Filtered.emitTool(ctx, opts, "write_file", "Create or overwrite a local, WSL, or SSH text file with exact content. Shows a diff and (unless permission is full) asks for approval. Set surface_id to an open terminal surface to write there; omitted surface_id follows the selected terminal context, or local when none is selected. Relative paths resolve against that surface cwd or the agent working directory.", "{\"path\":{\"type\":\"string\",\"description\":\"File path. Absolute, or relative to the selected surface cwd / working directory.\"},\"content\":{\"type\":\"string\",\"description\":\"Full file content to write.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Optional terminal surface id. Omit to use the selected terminal context, or local when none is selected.\"}}");
    try Filtered.emitTool(ctx, opts, "edit_file", "Replace an exact unique string in a local, WSL, or SSH text file. old_string must match exactly and be unique unless replace_all is true. Shows a diff and (unless permission is full) asks for approval. Set surface_id to an open terminal surface to edit there; omitted surface_id follows the selected terminal context, or local when none is selected.", "{\"path\":{\"type\":\"string\",\"description\":\"File path. Absolute, or relative to the selected surface cwd / working directory.\"},\"old_string\":{\"type\":\"string\",\"description\":\"Exact text to replace. Must be unique unless replace_all is true.\"},\"new_string\":{\"type\":\"string\",\"description\":\"Replacement text. May be empty to delete.\"},\"replace_all\":{\"type\":\"boolean\",\"description\":\"Replace every occurrence instead of requiring a unique match.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Optional terminal surface id. Omit to use the selected terminal context, or local when none is selected.\"}}");
    try Filtered.emitTool(ctx, opts, "ssh_profile_save", "Create or update a saved WispTerm SSH server profile. Use before ssh_profile_connect when the user provides SSH host, user, port, password, key, or credential-chain details.", "{\"name\":{\"type\":\"string\",\"description\":\"Optional profile name; defaults to host for new profiles.\"},\"host\":{\"type\":\"string\",\"description\":\"SSH host name or IP address.\"},\"user\":{\"type\":\"string\",\"description\":\"SSH username.\"},\"password\":{\"type\":\"string\",\"description\":\"Optional SSH password. Use only with auth_method=password; omitted password preserves an existing password when updating an existing password profile.\"},\"port\":{\"type\":\"string\",\"description\":\"Optional SSH port; defaults to 22 for new profiles.\"},\"proxy_jump\":{\"type\":\"string\",\"description\":\"Optional OpenSSH ProxyJump/jump host: [user@]host[:port], comma-separated for multi-hop. Omit for a direct connection.\"},\"auth_method\":{\"type\":\"string\",\"description\":\"Optional SSH auth method: password, key, or credentials. credentials means use OpenSSH config/default keys/agent/platform credentials.\"},\"identity_file\":{\"type\":\"string\",\"description\":\"Optional private key path for auth_method=key, equivalent to ssh -i <path>.\"}}");
    try Filtered.emitTool(ctx, opts, "ssh_profile_connect", "Create a new tab connected to a saved WispTerm SSH server profile by its profile name or host.", "{\"profile_name\":{\"type\":\"string\",\"description\":\"Saved SSH profile name or host to open in a new tab.\"}}");
    try Filtered.emitTool(ctx, opts, "tab_new", platform_pty_command.tabNewToolDescription(), platform_pty_command.tabNewToolPropertiesJson());
    try Filtered.emitTool(ctx, opts, "tab_close", "Close a terminal tab by tab_number (the one-based `tab` shown by terminal_list, matching the tab number the user sees), surface_id, title, or the active terminal tab when no selector is provided. Cannot close the AI chat tab running the agent.", "{\"tab_number\":{\"type\":\"integer\",\"description\":\"One-based UI tab number — the `tab` value shown by terminal_list and what the user sees.\"},\"tab_index\":{\"type\":\"integer\",\"description\":\"Zero-based tab index (tab_number minus one). Prefer tab_number.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Surface id from terminal_list.\"},\"title\":{\"type\":\"string\",\"description\":\"Terminal tab title to close, such as CPU2.\"}}");
    try Filtered.emitTool(ctx, opts, "skill_info", "Load a WispTerm skill by stable name. Use when the user explicitly names a skill or asks for specialized skill instructions.", "{\"skill_name\":{\"type\":\"string\",\"description\":\"Skill name or skill directory name.\"}}");
    try Filtered.emitTool(ctx, opts, "wispterm_docs", "Read WispTerm's own documentation (features, configuration, shortcuts, AI agent, file explorer, media). Call with no topic to list available topics, then call again with a topic to read its full text.", "{\"topic\":{\"type\":\"string\",\"description\":\"Topic name from the list. Omit to list available topics.\"}}");
    try Filtered.emitTool(ctx, opts, "mcp_config", "List or configure the user's MCP (Model Context Protocol) servers — the same mcp.json the MCP Servers panel edits. Use action=list (default) to show configured servers and whether each is enabled; action=add to add or update one (name and command required, args optional); action=remove/enable/disable to manage an existing server by name. Changes are saved to mcp.json and reloaded immediately. Example remote server: name=jina, command=npx, args=[\"-y\",\"mcp-remote\",\"https://mcp.jina.ai/v1\"].", "{\"action\":{\"type\":\"string\",\"description\":\"One of: list (default), add, remove, enable, disable.\"},\"name\":{\"type\":\"string\",\"description\":\"Server name. Required for add/remove/enable/disable.\"},\"command\":{\"type\":\"string\",\"description\":\"Executable to launch the server over stdio, e.g. npx. Required for add.\"},\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Command arguments for add, e.g. [\\\"-y\\\",\\\"mcp-remote\\\",\\\"https://mcp.jina.ai/v1\\\"].\"},\"enabled\":{\"type\":\"boolean\",\"description\":\"Whether the server is enabled when added. Default true.\"}}");
    try Filtered.emitTool(ctx, opts, "mcp_activate", "Activate one of the user's configured MCP servers so its tools become callable in this conversation. Inactive servers are listed in the system prompt. If the server was never discovered, this connects to it once to list its tools. Call this before using any tool that belongs to an inactive MCP server.", "{\"server\":{\"type\":\"string\",\"description\":\"MCP server name, as listed in the system prompt or by mcp_config action=list.\"}}");
    try Filtered.emitTool(ctx, opts, "websearch", "Search the web for current information via Jina. Returns the top results with titles, URLs, and page content. Use when you need facts newer than your training or to look something up online.", "{\"query\":{\"type\":\"string\",\"description\":\"The search query.\"},\"max_results\":{\"type\":\"integer\",\"description\":\"Optional max number of results (default 10, max 20).\"}}");
    try Filtered.emitTool(ctx, opts, "webread", "Read a web page or local file into clean markdown via Jina Reader. Pass an http(s):// URL to fetch a page, or a local file path (PDF, Word, Excel, PowerPoint) to upload and convert it. Use when you need the full content of one source, not a search.", "{\"url\":{\"type\":\"string\",\"description\":\"An http(s):// URL, or a local file path to upload.\"}}");
    try Filtered.emitTool(ctx, opts, "pubmed", "Search PubMed (NCBI) for biomedical and life-sciences literature and return matching articles with title, authors, journal, year, PMID, DOI, and abstract. Before calling, decompose the user's academic question into English keywords joined with PubMed boolean operators (AND/OR), then pass that as `query`. Use for scholarly/medical literature questions, not general web search.", "{\"query\":{\"type\":\"string\",\"description\":\"PubMed query: English keywords joined with AND/OR, e.g. metformin AND type 2 diabetes AND cardiovascular events.\"},\"max_results\":{\"type\":\"integer\",\"description\":\"Optional max number of articles (default 10, max 20).\"}}");
    try Filtered.emitTool(ctx, opts, "subagent", "Delegate a self-contained research or reading task to a background subagent with its own separate context window. The subagent can use websearch, webread, pubmed, read_file, terminal_list, terminal_snapshot, and wispterm_docs, then returns one final report; its intermediate tool output never enters this conversation. Use it whenever a task would pull large content here (full web pages, PDFs, multi-query searches). It cannot see this conversation or ask questions: put every needed detail (URLs, paths, constraints) and the expected report format into task.", "{\"task\":{\"type\":\"string\",\"description\":\"Complete self-contained task description: what to investigate or read, all needed context (URLs, paths, constraints), and what the final report must contain.\"}}");
    try Filtered.emitTool(ctx, opts, "send_attachment", "Send a local file back to the active chat conversation (WeChat or Feishu) that triggered this agent request. Use only when the current request came from a chat channel; ordinary local chat has no reply context. Audio and voice files are sent as ordinary file attachments.", "{\"kind\":{\"type\":\"string\",\"description\":\"Attachment kind: file, image, or voice. Voice is accepted as an alias for file.\"},\"path\":{\"type\":\"string\",\"description\":\"Readable local file path to send.\"},\"display_name\":{\"type\":\"string\",\"description\":\"Optional filename shown in the chat for file attachments; defaults to the path basename.\"}}");
    if (opts.include_memory) {
        try Filtered.emitTool(ctx, opts, "memory_save", "Save a durable long-term memory so future sessions remember it. Use for stable user preferences, project conventions, and key decisions — not transient task details. tier=global for facts about the user/preferences; tier=project for facts about the current project/working directory.", "{\"tier\":{\"type\":\"string\",\"description\":\"global or project.\"},\"name\":{\"type\":\"string\",\"description\":\"Short stable slug handle (kebab-case). Reusing an existing name updates that memory.\"},\"description\":{\"type\":\"string\",\"description\":\"One-line summary shown in the resident index.\"},\"type\":{\"type\":\"string\",\"description\":\"Optional: user, feedback, project, or reference. Defaults to user.\"},\"body\":{\"type\":\"string\",\"description\":\"The full memory text.\"}}");
        try Filtered.emitTool(ctx, opts, "memory_recall", "Read the full text of a memory by its name, when its index line looks relevant to the current task. Exact name preferred; a unique fragment of the name or description also resolves.", "{\"name\":{\"type\":\"string\",\"description\":\"The memory name (slug) from the resident index, or a fragment of it.\"}}");
        try Filtered.emitTool(ctx, opts, "memory_delete", "Delete a memory that is wrong or obsolete.", "{\"name\":{\"type\":\"string\",\"description\":\"The memory name (slug) to delete.\"},\"tier\":{\"type\":\"string\",\"description\":\"Optional: global or project. Omit to search both.\"}}");
    }
    if (opts.toolset == .full) {
        for (opts.dynamic_tools, 0..) |tool, i| {
            if (builtinToolNameReserved(tool.name)) continue;
            if (dynamicToolNameSeenBefore(opts.dynamic_tools, i)) continue;
            try Filtered.emitTool(
                ctx,
                opts,
                tool.name,
                tool.description,
                "{\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Command-line arguments to pass after the executable name.\"},\"cwd\":{\"type\":\"string\",\"description\":\"Optional working directory. Defaults to the AI Agent working directory.\"},\"timeout_ms\":{\"type\":\"integer\",\"description\":\"Optional timeout. Defaults to ai-agent-command-timeout-ms.\"}}",
            );
        }
        for (opts.mcp_tools, 0..) |tool, i| {
            if (builtinToolNameReserved(tool.name)) continue;
            if (mcpToolNameSeenBefore(opts.mcp_tools, i)) continue;
            try Filtered.emitTool(ctx, opts, tool.name, tool.description, tool.properties_json);
        }
    }
}

const ToolNameCollectorForTesting = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .empty,

    fn emit(self: *ToolNameCollectorForTesting, name: []const u8, description: []const u8, properties: []const u8, required: []const []const u8) !void {
        _ = description;
        _ = properties;
        _ = required;
        try self.names.append(self.allocator, name);
    }
};

pub fn collectBuiltinToolNamesForTesting(allocator: std.mem.Allocator, opts: ToolSpecOpts) ![]const []const u8 {
    var ctx = ToolNameCollectorForTesting{ .allocator = allocator };
    errdefer ctx.names.deinit(allocator);
    var builtin_opts = opts;
    builtin_opts.dynamic_tools = &.{};
    try forEachToolSpec(*ToolNameCollectorForTesting, &ctx, builtin_opts, ToolNameCollectorForTesting.emit);
    return ctx.names.toOwnedSlice(allocator);
}

pub fn freeCollectedToolNamesForTesting(allocator: std.mem.Allocator, names: []const []const u8) void {
    allocator.free(names);
}

const ToolSchemaEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    first: bool = true,

    fn emit(self: *ToolSchemaEmitter, name: []const u8, description: []const u8, properties: []const u8, required: []const []const u8) !void {
        if (!self.first) try self.out.append(self.allocator, ',');
        self.first = false;
        try self.out.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":");
        try appendJsonString(self.allocator, self.out, name);
        try self.out.appendSlice(self.allocator, ",\"description\":");
        try appendJsonString(self.allocator, self.out, description);
        try self.out.appendSlice(self.allocator, ",\"parameters\":{\"type\":\"object\",\"properties\":");
        try self.out.appendSlice(self.allocator, properties);
        try appendSchemaRequired(self.allocator, self.out, required);
        try self.out.appendSlice(self.allocator, ",\"additionalProperties\":false}}}");
    }
};

const ResponseToolSchemaEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    first: bool = true,

    fn emit(self: *ResponseToolSchemaEmitter, name: []const u8, description: []const u8, properties: []const u8, required: []const []const u8) !void {
        if (!self.first) try self.out.append(self.allocator, ',');
        self.first = false;
        try self.out.appendSlice(self.allocator, "{\"type\":\"function\",\"name\":");
        try appendJsonString(self.allocator, self.out, name);
        try self.out.appendSlice(self.allocator, ",\"description\":");
        try appendJsonString(self.allocator, self.out, description);
        try self.out.appendSlice(self.allocator, ",\"parameters\":{\"type\":\"object\",\"properties\":");
        try self.out.appendSlice(self.allocator, properties);
        try appendSchemaRequired(self.allocator, self.out, required);
        try self.out.appendSlice(self.allocator, ",\"additionalProperties\":false}}");
    }
};

const AnthropicToolEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    first: bool = true,

    fn emit(self: *AnthropicToolEmitter, name: []const u8, description: []const u8, properties: []const u8, required: []const []const u8) !void {
        if (!self.first) try self.out.append(self.allocator, ',');
        self.first = false;
        try self.out.appendSlice(self.allocator, "{\"name\":");
        try appendJsonString(self.allocator, self.out, name);
        try self.out.appendSlice(self.allocator, ",\"description\":");
        try appendJsonString(self.allocator, self.out, description);
        // input_schema reuses the SAME JSON Schema object the OpenAI `parameters` uses.
        try self.out.appendSlice(self.allocator, ",\"input_schema\":{\"type\":\"object\",\"properties\":");
        try self.out.appendSlice(self.allocator, properties);
        try appendSchemaRequired(self.allocator, self.out, required);
        try self.out.appendSlice(self.allocator, ",\"additionalProperties\":false}}");
    }
};

fn appendSchemaRequired(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), required: []const []const u8) !void {
    if (required.len == 0) return;
    try out.appendSlice(allocator, ",\"required\":[");
    for (required, 0..) |name, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, name);
    }
    try out.append(allocator, ']');
}

fn appendToolSchemas(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), opts: ToolSpecOpts) !void {
    try out.appendSlice(allocator, ",\"tools\":[");
    var ctx = ToolSchemaEmitter{ .allocator = allocator, .out = out };
    try forEachToolSpec(*ToolSchemaEmitter, &ctx, opts, ToolSchemaEmitter.emit);
    try out.append(allocator, ']');
    try out.appendSlice(allocator, ",\"tool_choice\":\"auto\"");
}

fn appendResponseToolSchemas(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), opts: ToolSpecOpts) !void {
    try out.appendSlice(allocator, ",\"tools\":[");
    var ctx = ResponseToolSchemaEmitter{ .allocator = allocator, .out = out };
    try forEachToolSpec(*ResponseToolSchemaEmitter, &ctx, opts, ResponseToolSchemaEmitter.emit);
    try out.append(allocator, ']');
    try out.appendSlice(allocator, ",\"tool_choice\":\"auto\"");
}

// ---------------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------------

pub fn parseApiResponse(allocator: std.mem.Allocator, body: []const u8, protocol: ApiProtocol) !ApiResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyResponse;
        return ApiResult{ .content = try allocator.dupe(u8, trimmed) };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    const obj = root.object;

    if (try parseApiErrorResult(allocator, root)) |result| return result;
    if (protocol == .anthropic) return parseAnthropicResponse(allocator, root);
    if (obj.get("choices") != null) return parseChatCompletionsResponse(allocator, root);
    if (obj.get("output") != null or obj.get("output_text") != null) return parseResponsesResponse(allocator, root);
    return error.MissingChoices;
}

pub fn parseApiErrorResult(allocator: std.mem.Allocator, root: std.json.Value) !?ApiResult {
    if (root != .object) return null;
    if (root.object.get("error")) |err_value| {
        if (err_value == .null) return null;
        return ApiResult{ .content = try formatApiError(allocator, root, err_value), .api_error = true };
    }
    return null;
}

fn formatApiError(allocator: std.mem.Allocator, root: std.json.Value, err_value: std.json.Value) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (jsonStringValue(err_value)) |message| {
        if (message.len > 0) try out.appendSlice(allocator, message);
    } else if (err_value == .object) {
        if (jsonStringValue(err_value.object.get("message"))) |message| {
            if (message.len > 0) try out.appendSlice(allocator, message);
        } else if (jsonStringValue(root.object.get("message"))) |message| {
            if (message.len > 0) try out.appendSlice(allocator, message);
        }
    }

    var wrote_meta = false;
    if (err_value == .object) {
        try appendApiErrorMeta(allocator, &out, &wrote_meta, "type", err_value.object.get("type"));
        try appendApiErrorMeta(allocator, &out, &wrote_meta, "code", err_value.object.get("code"));
        try appendApiErrorMeta(allocator, &out, &wrote_meta, "param", err_value.object.get("param"));
        try appendApiErrorMeta(allocator, &out, &wrote_meta, "status", err_value.object.get("status"));
        try appendApiErrorMeta(allocator, &out, &wrote_meta, "status_code", err_value.object.get("status_code"));
    }
    try appendApiErrorMeta(allocator, &out, &wrote_meta, "response_status", root.object.get("status"));
    if (wrote_meta) try out.append(allocator, ')');

    if (out.items.len == 0) {
        const json = try std.json.Stringify.valueAlloc(allocator, err_value, .{});
        defer allocator.free(json);
        if (json.len > 0) {
            try out.appendSlice(allocator, "API error: ");
            try out.appendSlice(allocator, json);
        }
    }

    if (out.items.len == 0) try out.appendSlice(allocator, "API returned an error");
    return out.toOwnedSlice(allocator);
}

fn appendApiErrorMeta(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    wrote_meta: *bool,
    label: []const u8,
    value_opt: ?std.json.Value,
) !void {
    const value = value_opt orelse return;
    switch (value) {
        .string => |text| {
            if (text.len == 0) return;
            try appendApiErrorMetaPrefix(allocator, out, wrote_meta, label);
            try out.appendSlice(allocator, text);
        },
        .integer => |number| {
            try appendApiErrorMetaPrefix(allocator, out, wrote_meta, label);
            try out.print(allocator, "{d}", .{number});
        },
        .float => |number| {
            try appendApiErrorMetaPrefix(allocator, out, wrote_meta, label);
            try out.print(allocator, "{d}", .{number});
        },
        .bool => |flag| {
            try appendApiErrorMetaPrefix(allocator, out, wrote_meta, label);
            try out.appendSlice(allocator, if (flag) "true" else "false");
        },
        else => {},
    }
}

fn appendApiErrorMetaPrefix(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    wrote_meta: *bool,
    label: []const u8,
) !void {
    if (!wrote_meta.*) {
        if (out.items.len == 0) try out.appendSlice(allocator, "API error");
        try out.appendSlice(allocator, " (");
        wrote_meta.* = true;
    } else {
        try out.appendSlice(allocator, ", ");
    }
    try out.appendSlice(allocator, label);
    try out.append(allocator, '=');
}

fn parseChatCompletionsResponse(allocator: std.mem.Allocator, root: std.json.Value) !ApiResult {
    if (root != .object) return error.InvalidResponse;
    const obj = root.object;
    const choices_value = obj.get("choices") orelse return error.MissingChoices;
    if (choices_value != .array or choices_value.array.items.len == 0) return error.MissingChoices;
    const choice = choices_value.array.items[0];
    if (choice != .object) return error.InvalidChoice;
    const message_value = choice.object.get("message") orelse return error.MissingMessage;
    if (message_value != .object) return error.MissingMessage;

    const content = if (message_value.object.get("content")) |content_value|
        if (content_value == .string) content_value.string else ""
    else
        "";
    const reasoning = if (message_value.object.get("reasoning_content")) |reasoning_value|
        if (reasoning_value == .string and reasoning_value.string.len > 0) reasoning_value.string else null
    else
        null;
    const tool_calls = try parseToolCalls(allocator, message_value);

    return .{
        .content = try allocator.dupe(u8, content),
        .reasoning = if (reasoning) |r| try allocator.dupe(u8, r) else null,
        .tool_calls = tool_calls,
        .usage = parseApiUsage(root),
    };
}

fn parseResponsesResponse(allocator: std.mem.Allocator, root: std.json.Value) !ApiResult {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    errdefer content.deinit(allocator);
    var reasoning: std.ArrayListUnmanaged(u8) = .empty;
    errdefer reasoning.deinit(allocator);

    try appendResponsesOutputText(allocator, &content, root);
    try appendResponsesReasoningText(allocator, &reasoning, root);

    const tool_calls = try parseResponsesToolCalls(allocator, root);
    errdefer if (tool_calls) |calls| {
        for (calls) |call| call.deinit(allocator);
        allocator.free(calls);
    };

    if (content.items.len == 0 and tool_calls == null) {
        if (root == .object) {
            if (root.object.get("status")) |status_value| {
                if (status_value == .string and std.mem.eql(u8, status_value.string, "failed")) {
                    if (root.object.get("error")) |err_value| {
                        if (err_value == .object) {
                            if (err_value.object.get("message")) |message_value| {
                                if (message_value == .string) {
                                    return ApiResult{ .content = try allocator.dupe(u8, message_value.string) };
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return .{
        .content = try content.toOwnedSlice(allocator),
        .reasoning = if (reasoning.items.len > 0) try reasoning.toOwnedSlice(allocator) else null,
        .tool_calls = tool_calls,
        .usage = parseApiUsage(root),
    };
}

fn parseAnthropicResponse(allocator: std.mem.Allocator, root: std.json.Value) !ApiResult {
    if (root != .object) return error.InvalidResponse;

    var content: std.ArrayListUnmanaged(u8) = .empty;
    errdefer content.deinit(allocator);

    const tool_calls = try parseAnthropicToolCalls(allocator, root);
    errdefer if (tool_calls) |calls| {
        for (calls) |call| call.deinit(allocator);
        allocator.free(calls);
    };

    if (root.object.get("content")) |content_value| {
        if (content_value == .array) {
            for (content_value.array.items) |item| {
                if (item != .object) continue;
                const typ = jsonStringValue(item.object.get("type")) orelse "";
                if (!std.mem.eql(u8, typ, "text")) continue;
                if (jsonStringValue(item.object.get("text"))) |text| {
                    if (text.len > 0) try content.appendSlice(allocator, text);
                }
            }
        }
    }

    return .{
        .content = try content.toOwnedSlice(allocator),
        .reasoning = null,
        .tool_calls = tool_calls,
        .usage = parseApiUsage(root),
    };
}

fn parseAnthropicToolCalls(allocator: std.mem.Allocator, root: std.json.Value) !?[]ToolCall {
    if (root != .object) return null;
    const content_value = root.object.get("content") orelse return null;
    if (content_value != .array or content_value.array.items.len == 0) return null;

    const calls = try allocator.alloc(ToolCall, content_value.array.items.len);
    errdefer allocator.free(calls);
    var written: usize = 0;
    errdefer {
        for (calls[0..written]) |call| call.deinit(allocator);
    }

    for (content_value.array.items) |item| {
        if (item != .object) continue;
        const typ = jsonStringValue(item.object.get("type")) orelse continue;
        if (!std.mem.eql(u8, typ, "tool_use")) continue;
        const id = jsonStringValue(item.object.get("id")) orelse continue;
        const name = jsonStringValue(item.object.get("name")) orelse continue;
        const arguments = if (item.object.get("input")) |input_value|
            try std.json.Stringify.valueAlloc(allocator, input_value, .{})
        else
            try allocator.dupe(u8, "{}");
        errdefer allocator.free(arguments);
        calls[written] = .{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .arguments = arguments,
        };
        written += 1;
    }

    if (written == 0) {
        allocator.free(calls);
        return null;
    }
    return try allocator.realloc(calls, written);
}

pub fn appendResponsesOutputText(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), root: std.json.Value) !void {
    if (root != .object) return;
    if (root.object.get("output_text")) |value| {
        if (value == .string and value.string.len > 0) try out.appendSlice(allocator, value.string);
    }
    const output_value = root.object.get("output") orelse return;
    if (output_value != .array) return;
    for (output_value.array.items) |item| {
        if (item != .object) continue;
        const typ = jsonStringValue(item.object.get("type")) orelse "";
        if (std.mem.eql(u8, typ, "message") or typ.len == 0) {
            if (item.object.get("content")) |content_value| {
                try appendResponsesContentText(allocator, out, content_value);
            }
        }
    }
}

fn appendResponsesContentText(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    switch (value) {
        .string => |text| if (text.len > 0) try out.appendSlice(allocator, text),
        .array => |array| {
            for (array.items) |item| {
                if (item == .string) {
                    if (item.string.len > 0) try out.appendSlice(allocator, item.string);
                    continue;
                }
                if (item != .object) continue;
                const typ = jsonStringValue(item.object.get("type")) orelse "";
                if (std.mem.eql(u8, typ, "output_text") or
                    std.mem.eql(u8, typ, "text") or
                    std.mem.eql(u8, typ, "summary_text") or
                    std.mem.eql(u8, typ, "reasoning_text") or
                    typ.len == 0)
                {
                    if (jsonStringValue(item.object.get("text"))) |text| {
                        if (text.len > 0) try out.appendSlice(allocator, text);
                    }
                }
            }
        },
        .object => |object| {
            if (jsonStringValue(object.get("text"))) |text| {
                if (text.len > 0) try out.appendSlice(allocator, text);
            }
        },
        else => {},
    }
}

pub fn appendResponsesReasoningText(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), root: std.json.Value) !void {
    if (root != .object) return;
    const output_value = root.object.get("output") orelse return;
    if (output_value != .array) return;
    for (output_value.array.items) |item| {
        if (item != .object) continue;
        const typ = jsonStringValue(item.object.get("type")) orelse "";
        if (!std.mem.eql(u8, typ, "reasoning")) continue;
        if (item.object.get("summary")) |summary_value| {
            try appendResponsesContentText(allocator, out, summary_value);
        }
        if (item.object.get("content")) |content_value| {
            try appendResponsesContentText(allocator, out, content_value);
        }
        if (jsonStringValue(item.object.get("text"))) |text| {
            if (text.len > 0) try out.appendSlice(allocator, text);
        }
    }
}

pub fn parseApiUsage(root: std.json.Value) ?ApiUsage {
    if (root != .object) return null;
    if (root.object.get("response")) |response_value| {
        if (response_value == .object) {
            if (parseApiUsage(response_value)) |usage| return usage;
        }
    }
    const usage_value = root.object.get("usage") orelse return null;
    if (usage_value != .object) return null;
    const input_tokens = jsonU64Value(usage_value.object.get("input_tokens"));
    const output_tokens = jsonU64Value(usage_value.object.get("output_tokens"));
    const cached_tokens = blk: {
        if (usage_value.object.get("input_tokens_details")) |details| {
            if (details == .object) break :blk jsonU64Value(details.object.get("cached_tokens"));
        }
        if (usage_value.object.get("prompt_tokens_details")) |details| {
            if (details == .object) break :blk jsonU64Value(details.object.get("cached_tokens"));
        }
        break :blk jsonU64Value(usage_value.object.get("prompt_cache_hit_tokens"));
    };
    if (input_tokens > 0 or output_tokens > 0) {
        return .{
            .prompt_tokens = input_tokens,
            .completion_tokens = output_tokens,
            .prompt_cache_hit_tokens = cached_tokens,
            .prompt_cache_miss_tokens = if (input_tokens > cached_tokens) input_tokens - cached_tokens else 0,
            .total_tokens = jsonU64Value(usage_value.object.get("total_tokens")),
        };
    }
    return .{
        .prompt_tokens = jsonU64Value(usage_value.object.get("prompt_tokens")),
        .completion_tokens = jsonU64Value(usage_value.object.get("completion_tokens")),
        .prompt_cache_hit_tokens = jsonU64Value(usage_value.object.get("prompt_cache_hit_tokens")),
        .prompt_cache_miss_tokens = jsonU64Value(usage_value.object.get("prompt_cache_miss_tokens")),
        .total_tokens = jsonU64Value(usage_value.object.get("total_tokens")),
    };
}

fn jsonU64Value(value_opt: ?std.json.Value) u64 {
    const value = value_opt orelse return 0;
    return switch (value) {
        .integer => |v| if (v > 0) @intCast(v) else 0,
        .float => |v| if (v > 0 and v <= @as(f64, @floatFromInt(std.math.maxInt(u64)))) @intFromFloat(v) else 0,
        else => 0,
    };
}

pub fn jsonStringValue(value_opt: ?std.json.Value) ?[]const u8 {
    const value = value_opt orelse return null;
    return if (value == .string) value.string else null;
}

fn parseToolCalls(allocator: std.mem.Allocator, message_value: std.json.Value) !?[]ToolCall {
    const calls_value = message_value.object.get("tool_calls") orelse return null;
    if (calls_value != .array or calls_value.array.items.len == 0) return null;

    const calls = try allocator.alloc(ToolCall, calls_value.array.items.len);
    errdefer allocator.free(calls);
    var written: usize = 0;
    errdefer {
        for (calls[0..written]) |call| call.deinit(allocator);
    }

    for (calls_value.array.items) |item| {
        if (item != .object) continue;
        const call_obj = item.object;
        const id_value = call_obj.get("id") orelse continue;
        const function_value = call_obj.get("function") orelse continue;
        if (id_value != .string or function_value != .object) continue;
        const name_value = function_value.object.get("name") orelse continue;
        const args_value = function_value.object.get("arguments") orelse continue;
        if (name_value != .string) continue;
        const args = switch (args_value) {
            .string => args_value.string,
            else => "",
        };
        calls[written] = .{
            .id = try allocator.dupe(u8, id_value.string),
            .name = try allocator.dupe(u8, name_value.string),
            .arguments = try allocator.dupe(u8, args),
        };
        written += 1;
    }

    if (written == 0) {
        allocator.free(calls);
        return null;
    }
    return try allocator.realloc(calls, written);
}

fn parseResponsesToolCalls(allocator: std.mem.Allocator, root: std.json.Value) !?[]ToolCall {
    if (root != .object) return null;
    const output_value = root.object.get("output") orelse return null;
    if (output_value != .array or output_value.array.items.len == 0) return null;

    const calls = try allocator.alloc(ToolCall, output_value.array.items.len);
    errdefer allocator.free(calls);
    var written: usize = 0;
    errdefer {
        for (calls[0..written]) |call| call.deinit(allocator);
    }

    for (output_value.array.items) |item| {
        if (item != .object) continue;
        const typ = jsonStringValue(item.object.get("type")) orelse continue;
        if (!std.mem.eql(u8, typ, "function_call")) continue;
        const call_id = jsonStringValue(item.object.get("call_id")) orelse jsonStringValue(item.object.get("id")) orelse continue;
        const name = jsonStringValue(item.object.get("name")) orelse continue;
        const arguments = jsonStringValue(item.object.get("arguments")) orelse "";
        calls[written] = .{
            .id = try allocator.dupe(u8, call_id),
            .name = try allocator.dupe(u8, name),
            .arguments = try allocator.dupe(u8, arguments),
        };
        written += 1;
    }

    if (written == 0) {
        allocator.free(calls);
        return null;
    }
    return try allocator.realloc(calls, written);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "ApiProtocol.parse and Role.apiName" {
    try std.testing.expectEqual(ApiProtocol.responses, ApiProtocol.parse("responses"));
    try std.testing.expectEqual(ApiProtocol.chat_completions, ApiProtocol.parse(""));
    try std.testing.expectEqualStrings("assistant", Role.assistant.apiName());
}

test "ApiProtocol parses and names anthropic + aliases" {
    try std.testing.expectEqual(ApiProtocol.anthropic, ApiProtocol.parse("anthropic"));
    try std.testing.expectEqual(ApiProtocol.anthropic, ApiProtocol.parse("claude"));
    try std.testing.expectEqual(ApiProtocol.anthropic, ApiProtocol.parse("messages"));
    try std.testing.expectEqualStrings("anthropic", ApiProtocol.anthropic.name());
}

test "apiEndpoint builds the anthropic messages endpoint" {
    const a = std.testing.allocator;
    const ep = try apiEndpoint(a, "https://api.anthropic.com", .anthropic);
    defer a.free(ep);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", ep);
}

test "buildRequestJson chat_completions emits model, roles, flags" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m1", .system_prompt = "sys", .protocol = .chat_completions, .thinking_enabled = true, .reasoning_effort = "high", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"m1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stream\":false") != null);
}

test "buildRequestJson chat_completions emits a multimodal image_url block for a user image" {
    const a = std.testing.allocator;
    var images = [_]ImageBlock{.{ .data_b64 = @constCast("QUJD"), .media_type = @constCast("image/png") }};
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("look"), .images = &images }};
    const params = RequestParams{ .model = "m1", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content\":[{\"type\":\"text\",\"text\":\"look\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,QUJD\"}") != null);
}

test "buildRequestJson chat_completions keeps a plain string content when a user message has no image" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m1", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content\":[") == null);
}

test "buildRequestJson anthropic emits an image source block for a user image" {
    const a = std.testing.allocator;
    var images = [_]ImageBlock{.{ .data_b64 = @constCast("QUJD"), .media_type = @constCast("image/png") }};
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("look"), .images = &images }};
    const params = RequestParams{ .model = "m1", .system_prompt = "", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"type\":\"text\",\"text\":\"look\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}") != null);
}

test "buildRequestJson responses emits an input_image block for a user image" {
    const a = std.testing.allocator;
    var images = [_]ImageBlock{.{ .data_b64 = @constCast("QUJD"), .media_type = @constCast("image/png") }};
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("look"), .images = &images }};
    const params = RequestParams{ .model = "m1", .system_prompt = "", .protocol = .responses, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"input_text\",\"text\":\"look\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,QUJD\"") != null);
}

test "buildRequestJson chat_completions omits reasoning_effort when thinking disabled" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m1", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "low", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reasoning_effort\"") == null);
}

test "buildRequestJson responses uses input + instructions" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m1", .system_prompt = "sys", .protocol = .responses, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"instructions\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input\":[") != null);
}

test "parseApiResponse reads chat_completions content + usage" {
    const a = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8}}
    ;
    var result = try parseApiResponse(a, body, .chat_completions);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("hello", result.content);
    try std.testing.expectEqual(@as(u64, 8), result.usage.?.total_tokens);
}

test "parseApiResponse surfaces an error object as content" {
    const a = std.testing.allocator;
    const body =
        \\{"error":{"message":"boom"}}
    ;
    var result = try parseApiResponse(a, body, .chat_completions);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("boom", result.content);
    try std.testing.expect(result.api_error);
}

test "parseApiResponse surfaces an error string as content" {
    const a = std.testing.allocator;
    const body =
        \\{"error":"model unavailable"}
    ;
    var result = try parseApiResponse(a, body, .responses);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("model unavailable", result.content);
}

test "parseApiResponse surfaces error metadata without a message" {
    const a = std.testing.allocator;
    const body =
        \\{"error":{"type":"invalid_request_error","code":"model_not_found","param":"model"}}
    ;
    var result = try parseApiResponse(a, body, .responses);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("API error (type=invalid_request_error, code=model_not_found, param=model)", result.content);
}

test "parseApiResponse surfaces responses failed error metadata" {
    const a = std.testing.allocator;
    const body =
        \\{"status":"failed","error":{"code":"unsupported_model","status_code":400}}
    ;
    var result = try parseApiResponse(a, body, .responses);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("API error (code=unsupported_model, status_code=400, response_status=failed)", result.content);
}

test "parseApiResponse ignores null error on completed responses result" {
    const a = std.testing.allocator;
    const body =
        \\{"status":"completed","error":null,"output_text":"hello"}
    ;
    var result = try parseApiResponse(a, body, .responses);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("hello", result.content);
}

test "isDeepSeekBaseUrl" {
    try std.testing.expect(isDeepSeekBaseUrl("https://api.deepseek.com/v1"));
    try std.testing.expect(!isDeepSeekBaseUrl("https://api.openai.com/v1"));
}

test "isAnthropicBaseUrl detects the anthropic api host" {
    try std.testing.expect(isAnthropicBaseUrl("https://api.anthropic.com"));
    try std.testing.expect(!isAnthropicBaseUrl("https://api.openai.com"));
}

test "buildRequestJson chat_completions emits tool_calls when present" {
    const a = std.testing.allocator;
    var calls = [_]ToolCall{.{ .id = @constCast("c1"), .name = @constCast("terminal_list"), .arguments = @constCast("{}") }};
    var msgs = [_]RequestMessage{.{ .role = .assistant, .content = @constCast(""), .tool_calls = &calls }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_calls\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"terminal_list\"") != null);
}

test "buildRequestJson includes wispterm_docs tool for both protocols" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};

    const chat = RequestParams{ .model = "m", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const chat_json = try buildRequestJson(a, chat, &msgs, true);
    defer a.free(chat_json);
    try std.testing.expect(std.mem.indexOf(u8, chat_json, "\"wispterm_docs\"") != null);

    const resp = RequestParams{ .model = "m", .system_prompt = "", .protocol = .responses, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const resp_json = try buildRequestJson(a, resp, &msgs, true);
    defer a.free(resp_json);
    try std.testing.expect(std.mem.indexOf(u8, resp_json, "\"wispterm_docs\"") != null);
}

test "tool schemas include send_attachment" {
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("send the report") }};
    const params = RequestParams{
        .model = "m",
        .system_prompt = "",
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
    };
    const json = try buildRequestJson(std.testing.allocator, params, &msgs, true);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"send_attachment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"display_name\"") != null);
}

test "terminal_repl_exec schema documents control keys" {
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("interrupt it") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(std.testing.allocator, params, &msgs, true);
    defer std.testing.allocator.free(json);
    // Assert on bracket-free substrings so the check is robust to any
    // `<`/`>` escaping the JSON emitter might apply.
    try std.testing.expect(std.mem.indexOf(u8, json, "ctrl-c") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ctrl-u") != null);
}

test "parseApiResponse reads responses-protocol output text" {
    const a = std.testing.allocator;
    const body =
        \\{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi there"}]}]}
    ;
    var result = try parseApiResponse(a, body, .responses);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("hi there", result.content);
}

test "parseApiResponse anthropic reads text, tool_use, and usage" {
    const a = std.testing.allocator;
    const body =
        \\{"content":[{"type":"text","text":"hello"},{"type":"tool_use","id":"call_1","name":"shell_exec","input":{"cmd":"ls"}}],"stop_reason":"tool_use","usage":{"input_tokens":12,"output_tokens":7}}
    ;
    var result = try parseApiResponse(a, body, .anthropic);
    defer result.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "hello") != null);
    try std.testing.expect(result.tool_calls != null);
    try std.testing.expectEqualStrings("shell_exec", result.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("call_1", result.tool_calls.?[0].id);
    try std.testing.expect(result.usage != null);
}

test "buildRequestJson anthropic puts system top-level and includes max_tokens" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{
        .{ .role = .user, .content = @constCast("hi") },
    };
    const params = RequestParams{ .model = "claude-x", .system_prompt = "be brief", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"max_tokens\":8192") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"system\":\"be brief\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
    // system must NOT be inside the messages array as a role
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"system\"") == null);
}

test "anthropic maps tool_calls to tool_use and tool results to grouped tool_result" {
    const a = std.testing.allocator;
    var calls = [_]ToolCall{.{ .id = @constCast("call_1"), .name = @constCast("shell_exec"), .arguments = @constCast("{\"cmd\":\"ls\"}") }};
    var msgs = [_]RequestMessage{
        .{ .role = .user, .content = @constCast("run ls") },
        .{ .role = .assistant, .content = @constCast(""), .tool_calls = &calls },
        .{ .role = .tool, .content = @constCast("file.txt"), .tool_call_id = @constCast("call_1") },
    };
    const params = RequestParams{ .model = "claude-x", .system_prompt = "", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input\":{\"cmd\":\"ls\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_use_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input_schema\"") != null);
}

test "agent tool set includes websearch" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"websearch\"") != null);
}

test "agent tool set includes webread" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"webread\"") != null);
}

fn requestParamsWithDisabledToolsForTesting(protocol: ApiProtocol, disabled_tools: []const []const u8) RequestParams {
    return .{
        .model = "m",
        .system_prompt = "",
        .protocol = protocol,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .max_tokens = 8192,
        .memory_enabled = true,
        .disabled_first_party_tools = disabled_tools,
    };
}

fn expectToolSchemaNameForTesting(json: []const u8, name: []const u8, present: bool) !void {
    var buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "\"name\":\"{s}\"", .{name});
    if (present) {
        try std.testing.expect(std.mem.indexOf(u8, json, needle) != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, json, needle) == null);
    }
}

test "disabled webread is omitted from chat_completions tool schemas" {
    const a = std.testing.allocator;
    const disabled = [_][]const u8{"webread"};
    const params = requestParamsWithDisabledToolsForTesting(.chat_completions, disabled[0..]);
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);

    try expectToolSchemaNameForTesting(json, "webread", false);
    try expectToolSchemaNameForTesting(json, "websearch", true);
}

test "disabled webread is omitted from responses tool schemas" {
    const a = std.testing.allocator;
    const disabled = [_][]const u8{"webread"};
    const params = requestParamsWithDisabledToolsForTesting(.responses, disabled[0..]);
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);

    try expectToolSchemaNameForTesting(json, "webread", false);
    try expectToolSchemaNameForTesting(json, "websearch", true);
}

test "disabled webread is omitted from anthropic tool schemas" {
    const a = std.testing.allocator;
    const disabled = [_][]const u8{"webread"};
    const params = requestParamsWithDisabledToolsForTesting(.anthropic, disabled[0..]);
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);

    try expectToolSchemaNameForTesting(json, "webread", false);
    try expectToolSchemaNameForTesting(json, "websearch", true);
}

test "subagent tool schemas inherit disabled first-party tools" {
    const a = std.testing.allocator;
    const disabled = [_][]const u8{"webread"};
    const names = try collectBuiltinToolNamesForTesting(a, .{
        .include_memory = true,
        .toolset = .subagent,
        .disabled_first_party_tools = disabled[0..],
    });
    defer freeCollectedToolNamesForTesting(a, names);

    try std.testing.expect(indexOfToolNameForTesting(names, "webread") == null);
    try std.testing.expect(indexOfToolNameForTesting(names, "websearch") != null);
}

fn indexOfToolNameForTesting(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name, target)) return i;
    }
    return null;
}

test "collectBuiltinToolNamesForTesting names all active first-party catalog tools" {
    const a = std.testing.allocator;
    const definitions = try first_party_tools.activeDefinitions(a);
    defer first_party_tools.freeDefinitions(a, definitions);

    const names = try collectBuiltinToolNamesForTesting(a, .{ .include_memory = true });
    defer freeCollectedToolNamesForTesting(a, names);

    for (definitions) |definition| {
        try std.testing.expect(indexOfToolNameForTesting(names, definition.name) != null);
    }
    for (names) |name| {
        try std.testing.expect(first_party_tools.isKnown(name));
    }
}

test "agent tool set includes pubmed" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pubmed\"") != null);
}

test "buildRequestJson advertises memory tools only when enabled" {
    const a = std.testing.allocator;
    const params_on = RequestParams{ .model = "m", .system_prompt = "s", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .memory_enabled = true };
    const on = try buildRequestJson(a, params_on, &.{}, true);
    defer a.free(on);
    try std.testing.expect(std.mem.indexOf(u8, on, "\"memory_save\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "\"memory_recall\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "\"memory_delete\"") != null);

    const params_off = RequestParams{ .model = "m", .system_prompt = "s", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .memory_enabled = false };
    const off = try buildRequestJson(a, params_off, &.{}, true);
    defer a.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, "\"memory_save\"") == null);
}

test "buildRequestJson advertises enabled binary tools" {
    const a = std.testing.allocator;
    const tools = [_]DynamicToolSpec{.{
        .name = "agent_docx_review",
        .description = "Use for DOCX tracked-change review.",
    }};
    const params = RequestParams{
        .model = "m",
        .system_prompt = "s",
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .dynamic_tools = tools[0..],
    };
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"agent_docx_review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"args\"") != null);
}

test "buildRequestJson advertises MCP tools with their own schema (anthropic)" {
    const a = std.testing.allocator;
    const tools = [_]McpToolSpec{.{
        .name = "add",
        .description = "Add two integers",
        .properties_json = "{\"x\":{\"type\":\"integer\"}}",
    }};
    const params = RequestParams{
        .model = "m",
        .system_prompt = "s",
        .protocol = .anthropic,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .mcp_tools = tools[0..],
    };
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"add\"") != null);
    // the MCP tool carries its OWN schema (x:integer), proving MCP specs aren't
    // forced into a fixed shape. (A general "no \"args\" anywhere" check would be
    // wrong now that the builtin mcp_config tool legitimately advertises `args`.)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"x\":{\"type\":\"integer\"}") != null);
}

test "buildRequestJson advertises mcp_activate" {
    const a = std.testing.allocator;
    const params = RequestParams{ .model = "m", .system_prompt = "s", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"mcp_activate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"server\"") != null);
}

test "MCP tool whose name collides with a builtin is not advertised" {
    const a = std.testing.allocator;
    const tools = [_]McpToolSpec{.{
        .name = "read_file",
        .description = "shadow attempt",
        .properties_json = "{}",
    }};
    const params = RequestParams{
        .model = "m",
        .system_prompt = "s",
        .protocol = .anthropic,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .mcp_tools = tools[0..],
    };
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);
    // The builtin read_file is still advertised, but our shadowing MCP tool
    // (unique description) must be skipped.
    try std.testing.expect(std.mem.indexOf(u8, json, "shadow attempt") == null);
}

test "continue_later is a reserved builtin tool name" {
    try std.testing.expect(builtinToolNameReserved("continue_later"));
}

test "disabled first-party list does not hide dynamic binary tools" {
    const a = std.testing.allocator;
    const disabled = [_][]const u8{"agent_docx_review"};
    const tools = [_]DynamicToolSpec{.{
        .name = "agent_docx_review",
        .description = "Use for DOCX tracked-change review.",
    }};
    const params = RequestParams{
        .model = "m",
        .system_prompt = "s",
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .dynamic_tools = tools[0..],
        .disabled_first_party_tools = disabled[0..],
    };
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"agent_docx_review\"") != null);
}

test "collectBuiltinToolNamesForTesting excludes dynamic binary tools" {
    const a = std.testing.allocator;
    const tools = [_]DynamicToolSpec{.{
        .name = "agent_docx_review",
        .description = "Use for DOCX tracked-change review.",
    }};
    const names = try collectBuiltinToolNamesForTesting(a, .{ .include_memory = true, .dynamic_tools = tools[0..] });
    defer freeCollectedToolNamesForTesting(a, names);

    try std.testing.expect(indexOfToolNameForTesting(names, "agent_docx_review") == null);
    for (names) |name| {
        try std.testing.expect(first_party_tools.isKnown(name));
    }
}

test "dynamic binary tools skip built-in tool name collisions" {
    const a = std.testing.allocator;
    const tools = [_]DynamicToolSpec{
        .{ .name = "terminal_list", .description = "Collision with a built-in tool." },
        .{ .name = "agent_docx_review", .description = "Use for DOCX tracked-change review." },
    };
    const params = RequestParams{
        .model = "m",
        .system_prompt = "s",
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .dynamic_tools = tools[0..],
    };
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\"name\":\"terminal_list\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"agent_docx_review\"") != null);
}

test "dynamic binary tools skip duplicate dynamic tool names" {
    const a = std.testing.allocator;
    const tools = [_]DynamicToolSpec{
        .{ .name = "agent_docx_review", .description = "First DOCX review tool." },
        .{ .name = "agent_docx_review", .description = "Second DOCX review tool." },
        .{ .name = "agent_pdf_review", .description = "PDF review tool." },
    };
    const params = RequestParams{
        .model = "m",
        .system_prompt = "s",
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .dynamic_tools = tools[0..],
    };
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\"name\":\"agent_docx_review\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "First DOCX review tool.") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Second DOCX review tool.") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"agent_pdf_review\"") != null);
}

test "subagent toolset excludes binary tools" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    const tools = [_]DynamicToolSpec{.{ .name = "agent_docx_review", .description = "DOCX" }};
    try appendToolSchemas(a, &out, .{ .include_memory = true, .toolset = .subagent, .dynamic_tools = tools[0..] });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "agent_docx_review") == null);
}

// ---------------------------------------------------------------------------
// Stream-response parser
// ---------------------------------------------------------------------------

/// Parse an SSE/streaming response body into an ApiResult.
/// Handles both OpenAI chat-completions streaming (choices[].delta) and the
/// Responses API event stream (response.output_text.delta, response.completed,
/// etc.).  Pure w.r.t. Session — only touches ApiResult/ApiUsage/std.
pub fn parseApiStreamResponse(allocator: std.mem.Allocator, body: []const u8) !ApiResult {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    errdefer content.deinit(allocator);
    var reasoning: std.ArrayListUnmanaged(u8) = .empty;
    errdefer reasoning.deinit(allocator);
    var usage: ?ApiUsage = null;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;

        const data = std.mem.trim(u8, line["data:".len..], " \t");
        if (data.len == 0) continue;
        if (std.mem.eql(u8, data, "[DONE]")) break;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;
        const obj = root.object;
        if (parseApiUsage(root)) |u| usage = u;

        if (try parseApiErrorResult(allocator, root)) |result| return result;

        if (jsonStringValue(obj.get("type"))) |event_type| {
            if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
                if (jsonStringValue(obj.get("delta"))) |delta| {
                    if (delta.len > 0) try content.appendSlice(allocator, delta);
                }
                continue;
            }
            if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
                std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
            {
                if (jsonStringValue(obj.get("delta"))) |delta| {
                    if (delta.len > 0) try reasoning.appendSlice(allocator, delta);
                }
                continue;
            }
            if (std.mem.eql(u8, event_type, "response.completed")) {
                if (obj.get("response")) |response_value| {
                    if (parseApiUsage(response_value)) |u| usage = u;
                    if (content.items.len == 0) try appendResponsesOutputText(allocator, &content, response_value);
                    if (reasoning.items.len == 0) try appendResponsesReasoningText(allocator, &reasoning, response_value);
                }
                break;
            }
            if (std.mem.eql(u8, event_type, "response.failed")) {
                if (obj.get("response")) |response_value| {
                    if (response_value == .object) {
                        if (try parseApiErrorResult(allocator, response_value)) |result| return result;
                    }
                }
                return ApiResult{ .content = try allocator.dupe(u8, "API returned an error") };
            }
        }

        const choices_value = obj.get("choices") orelse continue;
        if (choices_value != .array or choices_value.array.items.len == 0) continue;
        const choice = choices_value.array.items[0];
        if (choice != .object) continue;
        const delta_value = choice.object.get("delta") orelse continue;
        if (delta_value != .object) continue;

        if (delta_value.object.get("content")) |content_value| {
            if (content_value == .string and content_value.string.len > 0) {
                try content.appendSlice(allocator, content_value.string);
            }
        }
        if (delta_value.object.get("reasoning_content")) |reasoning_value| {
            if (reasoning_value == .string and reasoning_value.string.len > 0) {
                try reasoning.appendSlice(allocator, reasoning_value.string);
            }
        }
    }

    if (content.items.len == 0 and reasoning.items.len == 0) {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyResponse;
        return ApiResult{ .content = try allocator.dupe(u8, trimmed) };
    }

    return .{
        .content = try content.toOwnedSlice(allocator),
        .reasoning = if (reasoning.items.len > 0) try reasoning.toOwnedSlice(allocator) else null,
        .usage = usage,
    };
}

test "ai chat stream response aggregates content and reasoning chunks" {
    const allocator = std.testing.allocator;
    const body =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Think\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"ing\",\"content\":null}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"!\"}}]}\n\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":34,\"prompt_cache_hit_tokens\":5,\"prompt_cache_miss_tokens\":7,\"total_tokens\":46}}\n\n" ++
        "data: [DONE]\n\n";

    const result = try parseApiStreamResponse(allocator, body);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("Hello!", result.content);
    try std.testing.expect(result.reasoning != null);
    try std.testing.expectEqualStrings("Thinking", result.reasoning.?);
    try std.testing.expect(result.usage != null);
    try std.testing.expectEqual(@as(u64, 46), result.usage.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 5), result.usage.?.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u64, 7), result.usage.?.prompt_cache_miss_tokens);
}

test "ai chat Responses API stream aggregates output text and usage" {
    const allocator = std.testing.allocator;
    const body =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hel\"}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"lo\"}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"Checked\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":3,\"total_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":2}},\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}]}}\n\n";
    const result = try parseApiStreamResponse(allocator, body);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("Hello", result.content);
    try std.testing.expect(result.reasoning != null);
    try std.testing.expectEqualStrings("Checked", result.reasoning.?);
    try std.testing.expect(result.usage != null);
    try std.testing.expectEqual(@as(u64, 12), result.usage.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 2), result.usage.?.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u64, 7), result.usage.?.prompt_cache_miss_tokens);
}

test "file-edit tools appear in the tool schema" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = false });
    const json = out.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"write_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"edit_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"replace_all\"") != null);
}

test "copy_file appears in the tool schema" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = false });
    const json = out.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"copy_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dest_surface_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dest_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dest_name\"") != null);
}

test "terminal_answer_prompt appears in the tool schema" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = false });
    const json = out.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_answer_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "approve_all") != null);
}

test "agent tool set includes ui_screenshot" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("show me the screen") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ui_screenshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_focus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"surface_id\"") != null);
}

test "subagentToolAllowed accepts exactly the research tools" {
    const allowed = [_][]const u8{
        "terminal_list", "terminal_snapshot", "read_file",
        "websearch",     "webread",           "pubmed",
        "wispterm_docs",
    };
    for (allowed) |name| try std.testing.expect(subagentToolAllowed(name));
    const denied = [_][]const u8{
        "subagent",        "continue_later", "memory_save",        "ssh_session_exec",
        "write_file",      "edit_file",      "tab_new",            "tab_close",
        "terminal_select", "terminal_focus", "terminal_repl_exec",
    };
    for (denied) |name| try std.testing.expect(!subagentToolAllowed(name));
}

test "subagent toolset restricts tool schemas to research tools" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = true, .toolset = .subagent });
    const json = out.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"websearch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"webread\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pubmed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"wispterm_docs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"subagent\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"continue_later\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"memory_save\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_session_exec\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"write_file\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tab_new\"") == null);
}

test "full toolset includes the subagent tool" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = false });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"subagent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"task\"") != null);
}

test "ask_user appears in the full tool schema with question and options" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = false });
    const json = out.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ask_user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"question\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"options\"") != null);
}

test "continue_later appears in the full tool schema with delay and message" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = false });
    const json = out.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"continue_later\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"delay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"delay\"]") != null);
}

test "ask_user is absent from the subagent tool schema" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = true, .toolset = .subagent });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ask_user\"") == null);
    try std.testing.expect(!subagentToolAllowed("ask_user"));
}

test "subagent toolset gating applies to all three protocol emitters" {
    const a = std.testing.allocator;
    var responses_out: std.ArrayListUnmanaged(u8) = .empty;
    defer responses_out.deinit(a);
    try appendResponseToolSchemas(a, &responses_out, .{ .include_memory = true, .toolset = .subagent });
    try std.testing.expect(std.mem.indexOf(u8, responses_out.items, "\"websearch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses_out.items, "\"name\":\"subagent\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, responses_out.items, "\"name\":\"continue_later\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, responses_out.items, "\"write_file\"") == null);

    var anthropic_out: std.ArrayListUnmanaged(u8) = .empty;
    defer anthropic_out.deinit(a);
    try appendAnthropicTools(a, &anthropic_out, .{ .include_memory = true, .toolset = .subagent });
    try std.testing.expect(std.mem.indexOf(u8, anthropic_out.items, "\"websearch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_out.items, "\"name\":\"subagent\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_out.items, "\"name\":\"continue_later\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_out.items, "\"write_file\"") == null);
}
