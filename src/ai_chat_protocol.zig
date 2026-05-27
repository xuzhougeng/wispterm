//! API wire format for the agent chat: protocol data types, request-JSON
//! building, and response parsing. Pure w.r.t. Session/threads — takes plain
//! data + an allocator. (Imports the platform tool-description facades that the
//! tool-schema builders already used.)
const std = @import("std");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");

pub const DEFAULT_PROTOCOL = "chat_completions";
pub const TOOL_CALL_REASONING_FALLBACK = "Tool call is required before answering.";

// ---------------------------------------------------------------------------
// Protocol types
// ---------------------------------------------------------------------------

pub const ApiProtocol = enum {
    chat_completions,
    responses,

    pub fn parse(value: []const u8) ApiProtocol {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return .chat_completions;
        if (std.ascii.eqlIgnoreCase(trimmed, "responses") or
            std.ascii.eqlIgnoreCase(trimmed, "response"))
        {
            return .responses;
        }
        return .chat_completions;
    }

    pub fn name(self: ApiProtocol) []const u8 {
        return switch (self) {
            .chat_completions => DEFAULT_PROTOCOL,
            .responses => "responses",
        };
    }
};

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

pub const RequestMessage = struct {
    role: Role,
    content: []u8,
    reasoning: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_calls: ?[]ToolCall = null,

    pub fn deinit(self: RequestMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
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
};

pub fn buildRequestJson(allocator: std.mem.Allocator, params: RequestParams, messages: []const RequestMessage, include_tools: bool) ![]u8 {
    return switch (params.protocol) {
        .chat_completions => buildChatCompletionsRequestJsonForMessages(allocator, params, messages, include_tools),
        .responses => buildResponsesRequestJsonForMessages(allocator, params, messages, include_tools),
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

pub fn apiEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8, protocol: ApiProtocol) ![]u8 {
    return switch (protocol) {
        .chat_completions => chatEndpoint(allocator, base_url_raw),
        .responses => responsesEndpoint(allocator, base_url_raw),
    };
}

pub fn chatEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8) ![]u8 {
    return endpointWithSuffix(allocator, base_url_raw, "/chat/completions");
}

pub fn responsesEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8) ![]u8 {
    return endpointWithSuffix(allocator, base_url_raw, "/responses");
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
        try appendJsonString(allocator, &out, msg.content);
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
    try out.appendSlice(allocator, "},\"reasoning_effort\":");
    try appendJsonString(allocator, &out, if (params.reasoning_effort.len > 0) params.reasoning_effort else "high");
    try out.appendSlice(allocator, ",\"stream\":");
    try out.appendSlice(allocator, if (params.stream) "true" else "false");
    if (params.stream) {
        try out.appendSlice(allocator, ",\"stream_options\":{\"include_usage\":true}");
    }
    if (include_tools) {
        try appendToolSchemas(allocator, &out);
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

        if (msg.content.len > 0) {
            if (wrote_item) try out.append(allocator, ',');
            try appendResponseMessage(allocator, &out, msg.role, msg.content);
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
        try appendResponseToolSchemas(allocator, &out);
    }
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
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

fn appendToolSchemas(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"tools\":[");
    try out.appendSlice(allocator, toolSchema("terminal_list", "List Phantty terminal surfaces visible to the agent, including the current agent-selected write context. Before any terminal write, use terminal_select to choose the intended surface_id; use focused=true only as a default hint.", "{}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("terminal_snapshot", "Read a bounded text snapshot from one terminal surface or all surfaces.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Optional surface id from terminal_list.\"}}"));
    try out.append(allocator, ',');
    try appendToolSchema(
        allocator,
        out,
        "terminal_select",
        platform_pty_command.terminalSelectToolDescription(),
        "{\"surface_id\":{\"type\":\"string\",\"description\":\"Surface id from terminal_list to make the current agent write context.\"}}",
    );
    try out.append(allocator, ',');
    try appendToolSchema(
        allocator,
        out,
        platform_process.localCommandToolName(),
        platform_process.localCommandToolDescription(),
        "{\"command\":{\"type\":\"string\"},\"cwd\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}",
    );
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("ssh_session_exec", "Run a POSIX shell command in the selected already-open SSH terminal surface. The surface_id must match the current terminal_select context. Use only when the surface is at a shell prompt; for R, Python, Codex, Claude Code, or other REPLs use terminal_repl_exec.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Selected surface id from terminal_select.\"},\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}"));
    if (platform_pty_command.wslSessionToolsEnabled()) {
        try out.append(allocator, ',');
        try appendToolSchema(
            allocator,
            out,
            platform_pty_command.wslSessionToolName(),
            platform_pty_command.wslSessionToolDescription(),
            platform_pty_command.wslSessionToolPropertiesJson(),
        );
    }
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("terminal_repl_exec", "Send code or text to the selected already-open interactive REPL/app terminal without shell syntax. The surface_id must match the current terminal_select context. Use repl=r for R, repl=python for Python, repl=codex for Codex, repl=claude_code for Claude Code, or repl=plain for raw text input.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Selected surface id from terminal_select.\"},\"repl\":{\"type\":\"string\",\"description\":\"r, python, codex, claude_code, or plain\"},\"code\":{\"type\":\"string\",\"description\":\"Code or plain text to submit.\"},\"timeout_ms\":{\"type\":\"integer\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("ssh_profile_save", "Create or update a saved Phantty SSH server profile. Use before ssh_profile_connect when the user provides SSH host, user, port, or password details.", "{\"name\":{\"type\":\"string\",\"description\":\"Optional profile name; defaults to host for new profiles.\"},\"host\":{\"type\":\"string\",\"description\":\"SSH host name or IP address.\"},\"user\":{\"type\":\"string\",\"description\":\"SSH username.\"},\"password\":{\"type\":\"string\",\"description\":\"Optional SSH password; omit when using keys.\"},\"port\":{\"type\":\"string\",\"description\":\"Optional SSH port; defaults to 22 for new profiles.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("ssh_profile_connect", "Create a new tab connected to a saved Phantty SSH server profile by its profile name or host.", "{\"profile_name\":{\"type\":\"string\",\"description\":\"Saved SSH profile name or host to open in a new tab.\"}}"));
    try out.append(allocator, ',');
    try appendToolSchema(
        allocator,
        out,
        "tab_new",
        platform_pty_command.tabNewToolDescription(),
        platform_pty_command.tabNewToolPropertiesJson(),
    );
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("tab_close", "Close a terminal tab by zero-based tab_index, surface_id, title, or the active terminal tab when no selector is provided. Cannot close the AI chat tab running the agent.", "{\"tab_index\":{\"type\":\"integer\",\"description\":\"Zero-based tab index from terminal_list.\"},\"tab_number\":{\"type\":\"integer\",\"description\":\"One-based UI tab number, accepted as a convenience.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Surface id from terminal_list.\"},\"title\":{\"type\":\"string\",\"description\":\"Terminal tab title to close, such as CPU2.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("skill_info", "Load a Phantty skill by stable name. Use when the user explicitly names a skill or asks for specialized skill instructions.", "{\"skill_name\":{\"type\":\"string\",\"description\":\"Skill name or skill directory name.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("phantty_docs", "Read Phantty's own documentation (features, configuration, shortcuts, AI agent, file explorer, media). Call with no topic to list available topics, then call again with a topic to read its full text.", "{\"topic\":{\"type\":\"string\",\"description\":\"Topic name from the list. Omit to list available topics.\"}}"));
    try out.append(allocator, ']');
    try out.appendSlice(allocator, ",\"tool_choice\":\"auto\"");
}

fn appendResponseToolSchemas(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"tools\":[");
    try out.appendSlice(allocator, responseToolSchema("terminal_list", "List Phantty terminal surfaces visible to the agent, including the current agent-selected write context. Before any terminal write, use terminal_select to choose the intended surface_id; use focused=true only as a default hint.", "{}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, responseToolSchema("terminal_snapshot", "Read a bounded text snapshot from one terminal surface or all surfaces.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Optional surface id from terminal_list.\"}}"));
    try out.append(allocator, ',');
    try appendResponseToolSchema(
        allocator,
        out,
        "terminal_select",
        platform_pty_command.terminalSelectToolDescription(),
        "{\"surface_id\":{\"type\":\"string\",\"description\":\"Surface id from terminal_list to make the current agent write context.\"}}",
    );
    try out.append(allocator, ',');
    try appendResponseToolSchema(
        allocator,
        out,
        platform_process.localCommandToolName(),
        platform_process.localCommandToolDescription(),
        "{\"command\":{\"type\":\"string\"},\"cwd\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}",
    );
    try out.append(allocator, ',');
    try out.appendSlice(allocator, responseToolSchema("ssh_session_exec", "Run a POSIX shell command in the selected already-open SSH terminal surface. The surface_id must match the current terminal_select context. Use only when the surface is at a shell prompt; for R, Python, Codex, Claude Code, or other REPLs use terminal_repl_exec.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Selected surface id from terminal_select.\"},\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}"));
    if (platform_pty_command.wslSessionToolsEnabled()) {
        try out.append(allocator, ',');
        try appendResponseToolSchema(
            allocator,
            out,
            platform_pty_command.wslSessionToolName(),
            platform_pty_command.wslSessionToolDescription(),
            platform_pty_command.wslSessionToolPropertiesJson(),
        );
    }
    try out.append(allocator, ',');
    try out.appendSlice(allocator, responseToolSchema("terminal_repl_exec", "Send code or text to the selected already-open interactive REPL/app terminal without shell syntax. The surface_id must match the current terminal_select context. Use repl=r for R, repl=python for Python, repl=codex for Codex, repl=claude_code for Claude Code, or repl=plain for raw text input.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Selected surface id from terminal_select.\"},\"repl\":{\"type\":\"string\",\"description\":\"r, python, codex, claude_code, or plain\"},\"code\":{\"type\":\"string\",\"description\":\"Code or plain text to submit.\"},\"timeout_ms\":{\"type\":\"integer\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, responseToolSchema("ssh_profile_save", "Create or update a saved Phantty SSH server profile. Use before ssh_profile_connect when the user provides SSH host, user, port, or password details.", "{\"name\":{\"type\":\"string\",\"description\":\"Optional profile name; defaults to host for new profiles.\"},\"host\":{\"type\":\"string\",\"description\":\"SSH host name or IP address.\"},\"user\":{\"type\":\"string\",\"description\":\"SSH username.\"},\"password\":{\"type\":\"string\",\"description\":\"Optional SSH password; omit when using keys.\"},\"port\":{\"type\":\"string\",\"description\":\"Optional SSH port; defaults to 22 for new profiles.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, responseToolSchema("ssh_profile_connect", "Create a new tab connected to a saved Phantty SSH server profile by its profile name or host.", "{\"profile_name\":{\"type\":\"string\",\"description\":\"Saved SSH profile name or host to open in a new tab.\"}}"));
    try out.append(allocator, ',');
    try appendResponseToolSchema(
        allocator,
        out,
        "tab_new",
        platform_pty_command.tabNewToolDescription(),
        platform_pty_command.tabNewToolPropertiesJson(),
    );
    try out.append(allocator, ',');
    try out.appendSlice(allocator, responseToolSchema("tab_close", "Close a terminal tab by zero-based tab_index, surface_id, title, or the active terminal tab when no selector is provided. Cannot close the AI chat tab running the agent.", "{\"tab_index\":{\"type\":\"integer\",\"description\":\"Zero-based tab index from terminal_list.\"},\"tab_number\":{\"type\":\"integer\",\"description\":\"One-based UI tab number, accepted as a convenience.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Surface id from terminal_list.\"},\"title\":{\"type\":\"string\",\"description\":\"Terminal tab title to close, such as CPU2.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, responseToolSchema("skill_info", "Load a Phantty skill by stable name. Use when the user explicitly names a skill or asks for specialized skill instructions.", "{\"skill_name\":{\"type\":\"string\",\"description\":\"Skill name or skill directory name.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, responseToolSchema("phantty_docs", "Read Phantty's own documentation (features, configuration, shortcuts, AI agent, file explorer, media). Call with no topic to list available topics, then call again with a topic to read its full text.", "{\"topic\":{\"type\":\"string\",\"description\":\"Topic name from the list. Omit to list available topics.\"}}"));
    try out.append(allocator, ']');
    try out.appendSlice(allocator, ",\"tool_choice\":\"auto\"");
}

fn toolSchema(comptime name: []const u8, comptime description: []const u8, comptime properties: []const u8) []const u8 {
    return "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++ "\",\"description\":\"" ++ description ++ "\",\"parameters\":{\"type\":\"object\",\"properties\":" ++ properties ++ ",\"additionalProperties\":false}}}";
}

fn responseToolSchema(comptime name: []const u8, comptime description: []const u8, comptime properties: []const u8) []const u8 {
    return "{\"type\":\"function\",\"name\":\"" ++ name ++ "\",\"description\":\"" ++ description ++ "\",\"parameters\":{\"type\":\"object\",\"properties\":" ++ properties ++ ",\"additionalProperties\":false}}";
}

fn appendToolSchema(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8, description: []const u8, properties: []const u8) !void {
    try out.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
    try appendJsonString(allocator, out, name);
    try out.appendSlice(allocator, ",\"description\":");
    try appendJsonString(allocator, out, description);
    try out.appendSlice(allocator, ",\"parameters\":{\"type\":\"object\",\"properties\":");
    try out.appendSlice(allocator, properties);
    try out.appendSlice(allocator, ",\"additionalProperties\":false}}}");
}

fn appendResponseToolSchema(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8, description: []const u8, properties: []const u8) !void {
    try out.appendSlice(allocator, "{\"type\":\"function\",\"name\":");
    try appendJsonString(allocator, out, name);
    try out.appendSlice(allocator, ",\"description\":");
    try appendJsonString(allocator, out, description);
    try out.appendSlice(allocator, ",\"parameters\":{\"type\":\"object\",\"properties\":");
    try out.appendSlice(allocator, properties);
    try out.appendSlice(allocator, ",\"additionalProperties\":false}}");
}

// ---------------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------------

pub fn parseApiResponse(allocator: std.mem.Allocator, body: []const u8) !ApiResult {
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
    if (obj.get("choices") != null) return parseChatCompletionsResponse(allocator, root);
    if (obj.get("output") != null or obj.get("output_text") != null) return parseResponsesResponse(allocator, root);
    return error.MissingChoices;
}

pub fn parseApiErrorResult(allocator: std.mem.Allocator, root: std.json.Value) !?ApiResult {
    if (root != .object) return null;
    if (root.object.get("error")) |err_value| {
        if (err_value == .object) {
            if (err_value.object.get("message")) |message_value| {
                if (message_value == .string) {
                    return ApiResult{ .content = try allocator.dupe(u8, message_value.string) };
                }
            }
        }
        return ApiResult{ .content = try allocator.dupe(u8, "API returned an error") };
    }
    return null;
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
    var result = try parseApiResponse(a, body);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("hello", result.content);
    try std.testing.expectEqual(@as(u64, 8), result.usage.?.total_tokens);
}

test "parseApiResponse surfaces an error object as content" {
    const a = std.testing.allocator;
    const body =
        \\{"error":{"message":"boom"}}
    ;
    var result = try parseApiResponse(a, body);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("boom", result.content);
}

test "isDeepSeekBaseUrl" {
    try std.testing.expect(isDeepSeekBaseUrl("https://api.deepseek.com/v1"));
    try std.testing.expect(!isDeepSeekBaseUrl("https://api.openai.com/v1"));
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

test "buildRequestJson includes phantty_docs tool for both protocols" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};

    const chat = RequestParams{ .model = "m", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const chat_json = try buildRequestJson(a, chat, &msgs, true);
    defer a.free(chat_json);
    try std.testing.expect(std.mem.indexOf(u8, chat_json, "\"phantty_docs\"") != null);

    const resp = RequestParams{ .model = "m", .system_prompt = "", .protocol = .responses, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const resp_json = try buildRequestJson(a, resp, &msgs, true);
    defer a.free(resp_json);
    try std.testing.expect(std.mem.indexOf(u8, resp_json, "\"phantty_docs\"") != null);
}

test "parseApiResponse reads responses-protocol output text" {
    const a = std.testing.allocator;
    const body =
        \\{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi there"}]}]}
    ;
    var result = try parseApiResponse(a, body);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("hi there", result.content);
}
