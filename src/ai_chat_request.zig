//! AI-chat request layer: worker-thread bodies, the agent tool loop, provider
//! network calls, request-JSON serialization, and request-message cloning.
//! Mutually imports ai_chat.zig for Session/ChatRequest and the (pub) Session-
//! state helpers; references are pointer-based so the cycle is legal in Zig.
const std = @import("std");
const ai_chat = @import("ai_chat.zig");
const Session = ai_chat.Session;
const ChatRequest = ai_chat.ChatRequest;
const ai_chat_protocol = @import("ai_chat_protocol.zig");
const ai_skill_distill = @import("ai_skill_distill.zig");
const ai_chat_tools = @import("ai_chat_tools.zig");
const web_search = @import("web_search.zig");
const web_read = @import("web_read.zig");
const pubmed = @import("pubmed.zig");
const ai_chat_types = @import("ai_chat_types.zig");
const platform_agent_prompt = @import("platform/agent_prompt.zig");

// Type aliases from ai_chat_protocol
const RequestMessage = ai_chat_protocol.RequestMessage;
const ToolCall = ai_chat_protocol.ToolCall;
const ImageBlock = ai_chat_protocol.ImageBlock;
const ApiResult = ai_chat_protocol.ApiResult;
const ApiUsage = ai_chat_protocol.ApiUsage;
const Role = ai_chat_protocol.Role;

// ---------------------------------------------------------------------------
// MOVE: worker-thread entry points
// ---------------------------------------------------------------------------

pub fn requestThreadMain(request: *ChatRequest) void {
    const allocator = request.allocator;
    defer request.deinit();

    if (request.agent_enabled) {
        const result = runAgentRequest(request) catch |err| blk: {
            if (ai_chat.requestCancelled(request)) {
                ai_chat.finishStoppedRequest(request.session);
                return;
            }
            const text = std.fmt.allocPrint(allocator, "Agent request failed: {}", .{err}) catch return;
            break :blk ApiResult{ .content = text };
        };
        defer result.deinit(allocator);
        if (ai_chat.requestCancelled(request)) {
            ai_chat.finishStoppedRequest(request.session);
            return;
        }
        ai_chat.appendAssistantResult(request.session, result, request.started_ms);
        ai_chat.maybeAutoTitle(request.session);
        return;
    }

    if (request.stream) {
        runChatRequestStreaming(request) catch |err| {
            if (ai_chat.requestCancelled(request)) {
                ai_chat.finishStoppedRequest(request.session);
                return;
            }
            const text = std.fmt.allocPrint(allocator, "AI stream failed: {}", .{err}) catch return;
            defer allocator.free(text);
            ai_chat.appendAssistantResult(request.session, .{ .content = text }, request.started_ms);
        };
        if (ai_chat.requestCancelled(request)) {
            ai_chat.finishStoppedRequest(request.session);
            return;
        }
        ai_chat.maybeAutoTitle(request.session);
        return;
    }

    const result = runChatRequest(request) catch |err| blk: {
        if (ai_chat.requestCancelled(request)) {
            ai_chat.finishStoppedRequest(request.session);
            return;
        }
        const text = std.fmt.allocPrint(allocator, "AI request failed: {}", .{err}) catch return;
        break :blk ApiResult{ .content = text };
    };
    defer result.deinit(allocator);

    if (ai_chat.requestCancelled(request)) {
        ai_chat.finishStoppedRequest(request.session);
        return;
    }
    ai_chat.appendAssistantResult(request.session, result, request.started_ms);
    ai_chat.maybeAutoTitle(request.session);
}

/// Background worker for one title request. Owns `req` and frees it on exit.
pub fn titleThreadMain(req: *ChatRequest) void {
    defer req.deinit();
    const session = req.session;
    const allocator = req.allocator;
    if (session.closing.load(.acquire)) return;

    const result = runChatRequestForMessages(req, req.messages, false) catch return;
    defer result.deinit(allocator);
    if (session.closing.load(.acquire)) return;

    ai_chat.applyGeneratedTitle(session, result.content);
}

/// Background worker for the post-model-switch context summary. Owns `sreq`
/// (and its inner ChatRequest) and frees it on exit. On success, splices the
/// pre-switch transcript into a single "上文摘要" card; on failure, keeps the
/// full raw history.
pub fn summaryThreadMain(sreq: *ai_chat.SummaryRequest) void {
    defer sreq.deinit();
    const session = sreq.req.session;
    const allocator = sreq.req.allocator;
    if (session.closing.load(.acquire)) return;

    const result = runChatRequestForMessages(sreq.req, sreq.req.messages, false) catch {
        ai_chat.failSummaryResult(session);
        return;
    };
    defer result.deinit(allocator);
    if (session.closing.load(.acquire)) return;

    ai_chat.applySummaryResult(session, result.content, sreq.boundary, sreq.fromModel());
}

/// Background worker for one skill-distillation request. Owns `request` and
/// frees it on exit. Distillation is tool-free and never appends a normal
/// assistant message; it stores a preview candidate in Session state.
pub fn distillThreadMain(request: *ChatRequest) void {
    const allocator = request.allocator;
    defer request.deinit();

    const result = runChatRequestForMessages(request, request.messages, false) catch |err| {
        if (ai_chat.requestCancelled(request)) {
            ai_chat.finishStoppedRequest(request.session);
            return;
        }
        ai_chat.failDistillRequest(request.session, err);
        return;
    };
    defer result.deinit(allocator);

    if (ai_chat.requestCancelled(request)) {
        ai_chat.finishStoppedRequest(request.session);
        return;
    }

    var candidate = ai_skill_distill.parseCandidateJson(allocator, result.content, "") catch |err| {
        ai_chat.failDistillRequest(request.session, err);
        return;
    };
    ai_chat.applyDistillCandidate(request.session, &candidate);
}

/// Background worker for one `$websearch` command. Owns `req`; frees it on exit.
/// Re-fetches the Jina key on this thread, runs the search (snippets only), and
/// appends the formatted results to the transcript.
pub fn webSearchThreadMain(req: *ai_chat.WebSearchRequest) void {
    defer req.deinit();
    const allocator = req.allocator;
    const session = req.session;
    if (session.closing.load(.acquire)) return;

    const key = (web_search.jinaApiKeyAlloc(allocator) catch null) orelse {
        ai_chat.appendWebSearchResult(session, web_search.errorText(error.MissingApiKey));
        return;
    };
    defer allocator.free(key);

    var results = web_search.executeSearch(allocator, req.query, .{
        .engine = .jina,
        .api_key = key,
        .with_content = false,
        .max_results = 10,
    }) catch |err| {
        const text = web_search.formatErrorText(allocator, err) catch {
            ai_chat.appendWebSearchResult(session, web_search.errorText(err));
            return;
        };
        defer allocator.free(text);
        ai_chat.appendWebSearchResult(session, text);
        return;
    };
    defer results.deinit();

    const text = web_search.formatForUser(allocator, req.query, results.items) catch {
        ai_chat.appendWebSearchResult(session, "Out of memory formatting results.");
        return;
    };
    defer allocator.free(text);
    ai_chat.appendWebSearchResult(session, text);
}

/// Background worker for one `$webread` command. Owns `req`; frees it on exit.
/// Reuses the Jina key when configured (optional — anonymous read works), reads the
/// target, and appends the formatted content to the transcript.
pub fn webReadThreadMain(req: *ai_chat.WebReadRequest) void {
    defer req.deinit();
    const allocator = req.allocator;
    const session = req.session;
    if (session.closing.load(.acquire)) return;

    const key_opt = web_search.jinaApiKeyAlloc(allocator) catch null;
    defer if (key_opt) |k| allocator.free(k);
    const key = key_opt orelse "";

    const cache_dir: ?[]const u8 = if (req.working_dir.len > 0) req.working_dir else null;
    var result = web_read.executeRead(allocator, req.target, .{ .api_key = key, .cache_dir = cache_dir }) catch |err| {
        const text = web_read.formatErrorText(allocator, err) catch {
            ai_chat.appendWebSearchResult(session, web_read.errorText(err));
            return;
        };
        defer allocator.free(text);
        ai_chat.appendWebSearchResult(session, text);
        return;
    };
    defer result.deinit();

    const text = web_read.formatForUser(allocator, req.target, &result) catch {
        ai_chat.appendWebSearchResult(session, "Out of memory formatting content.");
        return;
    };
    defer allocator.free(text);
    ai_chat.appendWebSearchResult(session, text);
}

/// Background worker for one `$pubmed` command. Owns `req`; frees it on exit.
/// Runs the two-call NCBI search and appends the formatted articles to the
/// transcript. Reuses `appendWebSearchResult` (generic local tool message).
pub fn pubMedThreadMain(req: *ai_chat.WebPubMedRequest) void {
    defer req.deinit();
    const allocator = req.allocator;
    const session = req.session;
    if (session.closing.load(.acquire)) return;

    var results = pubmed.executeSearch(allocator, req.query, .{ .max_results = 10 }) catch |err| {
        const text = pubmed.formatErrorText(allocator, err) catch {
            ai_chat.appendWebSearchResult(session, pubmed.errorText(err));
            return;
        };
        defer allocator.free(text);
        ai_chat.appendWebSearchResult(session, text);
        return;
    };
    defer results.deinit();

    const text = pubmed.formatForUser(allocator, req.query, results.items) catch {
        ai_chat.appendWebSearchResult(session, "Out of memory formatting PubMed results.");
        return;
    };
    defer allocator.free(text);
    ai_chat.appendWebSearchResult(session, text);
}

// ---------------------------------------------------------------------------
// MOVE: agent tool loop
// ---------------------------------------------------------------------------

fn runAgentRequest(request: *ChatRequest) !ApiResult {
    var transcript: std.ArrayListUnmanaged(RequestMessage) = .empty;
    defer {
        for (transcript.items) |msg| msg.deinit(request.allocator);
        transcript.deinit(request.allocator);
    }

    for (request.messages) |msg| {
        var cloned = try cloneRequestMessage(request.allocator, msg);
        var cloned_owned = true;
        errdefer if (cloned_owned) cloned.deinit(request.allocator);
        try transcript.append(request.allocator, cloned);
        cloned_owned = false;
    }

    var total_usage: ApiUsage = .{};
    var has_usage = false;
    while (true) {
        if (ai_chat.requestCancelled(request)) return error.Canceled;
        const result = try runChatRequestForMessages(request, transcript.items, true);
        if (ai_chat.requestCancelled(request)) {
            result.deinit(request.allocator);
            return error.Canceled;
        }
        if (result.usage) |usage| {
            total_usage.add(usage);
            has_usage = true;
        }
        if (result.tool_calls == null or result.tool_calls.?.len == 0) {
            applySubagentUsage(request, &total_usage, &has_usage);
            var final = result;
            if (has_usage) final.usage = total_usage;
            return final;
        }
        errdefer result.deinit(request.allocator);

        if (result.content.len > 0) {
            ai_chat.appendProgressMessage(request.session, result.content) catch {};
        }

        var assistant_msg = try assistantToolCallMessage(request.allocator, result.content, result.reasoning, result.tool_calls.?);
        var assistant_msg_owned = true;
        errdefer if (assistant_msg_owned) assistant_msg.deinit(request.allocator);
        try transcript.append(request.allocator, assistant_msg);
        assistant_msg_owned = false;

        for (result.tool_calls.?) |call| {
            if (ai_chat.requestCancelled(request)) return error.Canceled;
            const progress = try std.fmt.allocPrint(request.allocator, "running {s} {s}", .{ call.name, call.arguments });
            defer request.allocator.free(progress);
            ai_chat.appendProgressMessage(request.session, progress) catch {};

            const tool_result = try executeToolCall(request, call);
            defer request.allocator.free(tool_result);
            if (ai_chat.requestCancelled(request)) return error.Canceled;
            if (std.mem.eql(u8, call.name, "skill_info")) {
                ai_chat.appendReplayableToolMessage(request.session, call.id, call.name, tool_result) catch {};
            }

            var tool_msg = try requestMessageWithClonedFields(request.allocator, .tool, tool_result, null, call.id, null, null);
            var tool_msg_owned = true;
            errdefer if (tool_msg_owned) tool_msg.deinit(request.allocator);
            try transcript.append(request.allocator, tool_msg);
            tool_msg_owned = false;
        }
        result.deinit(request.allocator);
    }
}

// ---------------------------------------------------------------------------
// Subagent: nested research agent loop (the `subagent` tool)
// ---------------------------------------------------------------------------

/// Model-call seam so tests can stub the network round-trip.
pub const SubagentModel = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, request: *const ChatRequest, messages: []const RequestMessage) anyerror!ApiResult,
};

fn realSubagentModelCall(_: ?*anyopaque, request: *const ChatRequest, messages: []const RequestMessage) anyerror!ApiResult {
    return runChatRequestForMessages(request, messages, true);
}

fn subagentToolCall(request: *ChatRequest, call: ToolCall) anyerror![]u8 {
    const args = ai_chat_tools.parseArgs(request.allocator, call.arguments) orelse
        return request.allocator.dupe(u8, "Invalid tool arguments");
    defer args.deinit();
    const task = ai_chat_tools.jsonStringArg(args.value, "task") orelse
        return request.allocator.dupe(u8, "Missing task");
    if (std.mem.trim(u8, task, " \t\r\n").len == 0)
        return request.allocator.dupe(u8, "Missing task");
    return runSubagentTaskWithModel(request, task, .{ .call = realSubagentModelCall });
}

pub fn runSubagentTaskWithModel(request: *ChatRequest, task: []const u8, model: SubagentModel) anyerror![]u8 {
    const allocator = request.allocator;

    // Stack-local derived request: shares the parent's session (cancellation),
    // tool host/snapshot, and settings; overrides prompt/toolset/credentials.
    // Never deinit it — every pointer is borrowed from the parent or static.
    var sub_request = request.*;
    sub_request.system_prompt = @constCast(platform_agent_prompt.subagentSystemPrompt);
    sub_request.stream = false;
    sub_request.memory_enabled = false;
    sub_request.copilot = false;
    sub_request.toolset = .subagent;
    if (request.subagent_profile) |profile| {
        sub_request.base_url = profile.base_url;
        sub_request.api_key = profile.api_key;
        sub_request.model = profile.model;
        sub_request.protocol = profile.protocol;
        sub_request.thinking_enabled = profile.thinking_enabled;
        sub_request.reasoning_effort = profile.reasoning_effort;
        sub_request.max_tokens = profile.max_tokens;
    }

    var transcript: std.ArrayListUnmanaged(RequestMessage) = .empty;
    defer {
        for (transcript.items) |msg| msg.deinit(allocator);
        transcript.deinit(allocator);
    }
    {
        var user_msg = try requestMessageWithClonedFields(allocator, .user, task, null, null, null, null);
        var owned = true;
        errdefer if (owned) user_msg.deinit(allocator);
        try transcript.append(allocator, user_msg);
        owned = false;
    }

    var sub_usage: ApiUsage = .{};
    var has_sub_usage = false;
    var rounds: usize = 0;
    while (true) {
        if (ai_chat.requestCancelled(request)) return error.Canceled;
        const result = try model.call(model.ctx, &sub_request, transcript.items);
        rounds += 1;
        if (ai_chat.requestCancelled(request)) {
            result.deinit(allocator);
            return error.Canceled;
        }
        if (result.usage) |usage| {
            sub_usage.add(usage);
            has_sub_usage = true;
        }
        if (result.tool_calls == null or result.tool_calls.?.len == 0) {
            if (result.reasoning) |reasoning| allocator.free(reasoning);
            if (result.tool_calls) |calls| allocator.free(calls);
            if (has_sub_usage) {
                request.subagent_usage.add(sub_usage);
                request.subagent_usage_present = true;
            }
            const done = std.fmt.allocPrint(allocator, "subagent: done ({d} rounds, {d} tokens)", .{ rounds, sub_usage.total_tokens }) catch null;
            if (done) |text| {
                defer allocator.free(text);
                ai_chat.appendProgressMessage(request.session, text) catch {};
            }
            return ai_chat_tools.truncateOwned(allocator, ai_chat.currentAgentSettings(), result.content);
        }
        errdefer result.deinit(allocator);

        var assistant_msg = try assistantToolCallMessage(allocator, result.content, result.reasoning, result.tool_calls.?);
        var assistant_msg_owned = true;
        errdefer if (assistant_msg_owned) assistant_msg.deinit(allocator);
        try transcript.append(allocator, assistant_msg);
        assistant_msg_owned = false;

        for (result.tool_calls.?) |tool_call| {
            if (ai_chat.requestCancelled(request)) return error.Canceled;
            const progress = try std.fmt.allocPrint(allocator, "subagent: running {s} {s}", .{ tool_call.name, tool_call.arguments });
            defer allocator.free(progress);
            ai_chat.appendProgressMessage(request.session, progress) catch {};

            // Allow-list first: a nested `subagent` (or any exec/write tool)
            // never reaches the dispatcher.
            const tool_result = if (!ai_chat_protocol.subagentToolAllowed(tool_call.name))
                try allocator.dupe(u8, "Tool not available in subagent.")
            else
                try executeToolCall(request, tool_call);
            defer allocator.free(tool_result);
            if (ai_chat.requestCancelled(request)) return error.Canceled;

            var tool_msg = try requestMessageWithClonedFields(allocator, .tool, tool_result, null, tool_call.id, null, null);
            var tool_msg_owned = true;
            errdefer if (tool_msg_owned) tool_msg.deinit(allocator);
            try transcript.append(allocator, tool_msg);
            tool_msg_owned = false;
        }
        result.deinit(allocator);
    }
}

fn applySubagentUsage(request: *const ChatRequest, total_usage: *ApiUsage, has_usage: *bool) void {
    if (!request.subagent_usage_present) return;
    total_usage.add(request.subagent_usage);
    has_usage.* = true;
}

// ---------------------------------------------------------------------------
// MOVE: network / HTTP calls
// ---------------------------------------------------------------------------

fn runChatRequest(request: *const ChatRequest) !ApiResult {
    return runChatRequestForMessages(request, request.messages, request.agent_enabled);
}

fn runChatRequestForMessages(request: *const ChatRequest, messages: []const RequestMessage, include_tools: bool) !ApiResult {
    if (ai_chat.requestCancelled(request)) return error.Canceled;
    const allocator = request.allocator;
    const endpoint = try ai_chat_protocol.apiEndpoint(allocator, request.base_url, request.protocol);
    defer allocator.free(endpoint);

    const body = try buildRequestJsonForMessages(allocator, request, messages, include_tools);
    defer allocator.free(body);

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(bearer);

    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16384,
    };
    defer client.deinit();

    var resp_buf: std.Io.Writer.Allocating = .init(allocator);
    defer resp_buf.deinit();

    const is_anthropic = request.protocol == .anthropic;
    const anthropic_headers = [_]std.http.Header{
        .{ .name = "x-api-key", .value = request.api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };
    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = if (is_anthropic) .omit else .{ .override = bearer },
        },
        .extra_headers = if (is_anthropic) &anthropic_headers else &.{},
        .response_writer = &resp_buf.writer,
    }) catch |err| return networkFailureResult(allocator, endpoint, err);
    if (ai_chat.requestCancelled(request)) return error.Canceled;

    var resp_list = resp_buf.toArrayList();
    defer resp_list.deinit(allocator);

    if (result.status != .ok) {
        const trimmed = std.mem.trim(u8, resp_list.items, " \t\r\n");
        if (trimmed.len > 0) return ApiResult{ .content = try allocator.dupe(u8, trimmed) };
        return ApiResult{ .content = try std.fmt.allocPrint(allocator, "HTTP {d}", .{@intFromEnum(result.status)}) };
    }

    return if (request.stream)
        ai_chat_protocol.parseApiStreamResponse(allocator, resp_list.items)
    else
        ai_chat_protocol.parseApiResponse(allocator, resp_list.items, request.protocol);
}

fn runChatRequestStreaming(request: *const ChatRequest) !void {
    if (ai_chat.requestCancelled(request)) return error.Canceled;
    const allocator = request.allocator;
    const endpoint = try ai_chat_protocol.apiEndpoint(allocator, request.base_url, request.protocol);
    defer allocator.free(endpoint);

    const body = try buildRequestJson(allocator, request);
    defer allocator.free(body);

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(bearer);

    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16384,
    };
    defer client.deinit();

    const is_anthropic = request.protocol == .anthropic;
    const anthropic_headers = [_]std.http.Header{
        .{ .name = "x-api-key", .value = request.api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };
    const uri = try std.Uri.parse(endpoint);
    var req = client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = if (is_anthropic) .omit else .{ .override = bearer },
        },
        .extra_headers = if (is_anthropic) &anthropic_headers else &.{},
        .keep_alive = false,
    }) catch |err| {
        try failStreamNetworkRequest(request, endpoint, "open request", err);
        return;
    };
    defer req.deinit();

    req.sendBodyComplete(body) catch |err| {
        try failStreamNetworkRequest(request, endpoint, "send request", err);
        return;
    };

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        try failStreamNetworkRequest(request, endpoint, "receive response", err);
        return;
    };
    if (ai_chat.requestCancelled(request)) return error.Canceled;
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    if (response.head.status != .ok) {
        var err_buf: std.Io.Writer.Allocating = .init(allocator);
        defer err_buf.deinit();
        _ = reader.streamRemaining(&err_buf.writer) catch {};
        var err_list = err_buf.toArrayList();
        defer err_list.deinit(allocator);
        const trimmed = std.mem.trim(u8, err_list.items, " \t\r\n");
        if (trimmed.len > 0) {
            ai_chat.failAssistantStream(request.session, null, trimmed);
        } else {
            const msg = try std.fmt.allocPrint(allocator, "HTTP {d}", .{@intFromEnum(response.head.status)});
            defer allocator.free(msg);
            ai_chat.failAssistantStream(request.session, null, msg);
        }
        return;
    }

    const message_idx = try ai_chat.beginAssistantStream(request.session);
    var usage: ?ApiUsage = null;
    while (true) {
        if (ai_chat.requestCancelled(request)) return error.Canceled;
        const line = reader.takeDelimiter('\n') catch |err| {
            if (ai_chat.requestCancelled(request)) return error.Canceled;
            const msg = std.fmt.allocPrint(allocator, "Stream read failed: {}", .{err}) catch return err;
            defer allocator.free(msg);
            ai_chat.failAssistantStream(request.session, message_idx, msg);
            return;
        } orelse break;

        if (ai_chat.requestCancelled(request)) return error.Canceled;
        if (try ai_chat.applyApiStreamLineToSession(allocator, request.session, message_idx, line, &usage)) break;
    }
    ai_chat.finishAssistantStream(request.session, message_idx, request.started_ms, usage);
}

fn networkFailureResult(allocator: std.mem.Allocator, endpoint: []const u8, err: anyerror) !ApiResult {
    return .{
        .content = try std.fmt.allocPrint(
            allocator,
            "HTTP request failed before response: {s} ({s})",
            .{ @errorName(err), endpoint },
        ),
    };
}

fn failStreamNetworkRequest(request: *const ChatRequest, endpoint: []const u8, stage: []const u8, err: anyerror) !void {
    const msg = try std.fmt.allocPrint(
        request.allocator,
        "HTTP stream {s} failed before response: {s} ({s})",
        .{ stage, @errorName(err), endpoint },
    );
    defer request.allocator.free(msg);
    ai_chat.failAssistantStream(request.session, null, msg);
}

// ---------------------------------------------------------------------------
// MOVE: request-JSON serialization
// ---------------------------------------------------------------------------

pub fn buildRequestJson(allocator: std.mem.Allocator, request: *const ChatRequest) ![]u8 {
    return ai_chat_protocol.buildRequestJson(allocator, request.toParams(), request.messages, request.agent_enabled);
}

pub fn buildRequestJsonForMessages(allocator: std.mem.Allocator, request: *const ChatRequest, messages: []const RequestMessage, include_tools: bool) ![]u8 {
    return ai_chat_protocol.buildRequestJson(allocator, request.toParams(), messages, include_tools);
}

// ---------------------------------------------------------------------------
// MOVE: request-message cloning
// ---------------------------------------------------------------------------

fn cloneRequestMessage(allocator: std.mem.Allocator, msg: RequestMessage) !RequestMessage {
    return requestMessageWithClonedFields(allocator, msg.role, msg.content, msg.reasoning, msg.tool_call_id, msg.tool_calls, msg.images);
}

fn cloneToolCalls(allocator: std.mem.Allocator, calls: []const ToolCall) ![]ToolCall {
    const out = try allocator.alloc(ToolCall, calls.len);
    errdefer allocator.free(out);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |call| call.deinit(allocator);
    }
    for (calls, 0..) |call, i| {
        {
            const id = try allocator.dupe(u8, call.id);
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, call.name);
            errdefer allocator.free(name);
            const arguments = try allocator.dupe(u8, call.arguments);
            errdefer allocator.free(arguments);
            out[i] = .{
                .id = id,
                .name = name,
                .arguments = arguments,
            };
        }
        written += 1;
    }
    return out;
}

fn assistantToolCallMessage(allocator: std.mem.Allocator, content: []const u8, reasoning: ?[]const u8, calls: []const ToolCall) !RequestMessage {
    return requestMessageWithClonedFields(allocator, .assistant, content, reasoning, null, calls, null);
}

pub fn requestMessageWithClonedFields(
    allocator: std.mem.Allocator,
    role: Role,
    content: []const u8,
    reasoning: ?[]const u8,
    tool_call_id: ?[]const u8,
    tool_calls: ?[]const ToolCall,
    images: ?[]const ImageBlock,
) !RequestMessage {
    const content_copy = try allocator.dupe(u8, content);
    errdefer allocator.free(content_copy);

    var reasoning_copy: ?[]u8 = null;
    errdefer if (reasoning_copy) |text| allocator.free(text);
    if (reasoning) |text| reasoning_copy = try allocator.dupe(u8, text);

    var tool_call_id_copy: ?[]u8 = null;
    errdefer if (tool_call_id_copy) |id| allocator.free(id);
    if (tool_call_id) |id| tool_call_id_copy = try allocator.dupe(u8, id);

    var tool_calls_copy: ?[]ToolCall = null;
    errdefer if (tool_calls_copy) |calls| {
        for (calls) |call| call.deinit(allocator);
        allocator.free(calls);
    };
    if (tool_calls) |calls| tool_calls_copy = try cloneToolCalls(allocator, calls);

    const images_copy = try ai_chat_protocol.cloneImageBlocks(allocator, images);
    errdefer if (images_copy) |imgs| {
        for (imgs) |img| img.deinit(allocator);
        allocator.free(imgs);
    };

    return .{
        .role = role,
        .content = content_copy,
        .reasoning = reasoning_copy,
        .tool_call_id = tool_call_id_copy,
        .tool_calls = tool_calls_copy,
        .images = images_copy,
    };
}

pub fn durableToolAssistantRequestMessage(allocator: std.mem.Allocator, id: []const u8, name: []const u8) !RequestMessage {
    const content = try allocator.dupe(u8, "");
    errdefer allocator.free(content);

    const calls = try allocator.alloc(ToolCall, 1);
    errdefer allocator.free(calls);

    {
        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const arguments = try allocator.dupe(u8, "{}");
        errdefer allocator.free(arguments);

        calls[0] = .{
            .id = id_copy,
            .name = name_copy,
            .arguments = arguments,
        };
    }

    return .{
        .role = .assistant,
        .content = content,
        .tool_calls = calls,
    };
}

// ---------------------------------------------------------------------------
// MOVE: ToolContext seam adapters — bridge Session into the leaf tool module
// ---------------------------------------------------------------------------

fn toolApprove(ctx: *anyopaque, tool: []const u8, command: []const u8, reason: []const u8) bool {
    const session: *Session = @ptrCast(@alignCast(ctx));
    return session.requestApproval(tool, command, reason);
}

fn toolCancelled(ctx: *anyopaque) bool {
    const session: *Session = @ptrCast(@alignCast(ctx));
    return ai_chat.sessionCancelled(session);
}

fn toolNote(ctx: *anyopaque, text: []const u8) void {
    const session: *Session = @ptrCast(@alignCast(ctx));
    session.appendLocalToolMessage(text);
}

fn toolAsk(ctx: *anyopaque, question: []const u8, options: []const ai_chat_types.QuestionOption) ai_chat_types.AskResult {
    const session: *Session = @ptrCast(@alignCast(ctx));
    return session.askUser(question, options);
}

fn toolContextFromRequest(request: *ChatRequest) ai_chat_types.ToolContext {
    var settings = ai_chat.currentAgentSettings();
    // Per-conversation override beats the global default.
    if (request.session.workingDirOverride()) |override| settings.working_dir = override;
    return .{
        .allocator = request.allocator,
        .ctx = request.session,
        .tool_host = request.tool_host,
        .tool_snapshot = request.tool_snapshot,
        .settings = settings,
        .copilot = request.copilot,
        .weixin_reply_context = request.weixin_reply_context,
        .write_context_surface_id = request.write_context_surface_id,
        .write_context_surface_id_len = request.write_context_surface_id_len,
        .approve = toolApprove,
        .cancelled = toolCancelled,
        .note = toolNote,
        .ask = toolAsk,
    };
}

pub fn executeToolCall(request: *ChatRequest, call: ToolCall) ![]u8 {
    if (std.mem.eql(u8, call.name, "subagent")) return subagentToolCall(request, call);
    var tool_ctx = toolContextFromRequest(request);
    const result = try ai_chat_tools.executeToolCall(&tool_ctx, call);
    // Write-context state may have changed inside the tool (e.g. terminal_select).
    request.write_context_surface_id = tool_ctx.write_context_surface_id;
    request.write_context_surface_id_len = tool_ctx.write_context_surface_id_len;
    // tool_snapshot may have been updated (e.g. tab_new, tab_close, ssh_profile_connect).
    request.tool_snapshot = tool_ctx.tool_snapshot;
    return result;
}

// ---------------------------------------------------------------------------
// Tests for request JSON serialization (moved from ai_chat.zig)
// ---------------------------------------------------------------------------

test "ai chat network failure result includes endpoint and underlying error" {
    const allocator = std.testing.allocator;
    var result = try networkFailureResult(allocator, "https://api.example.test/v1/responses", error.UnknownHostName);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings(
        "HTTP request failed before response: UnknownHostName (https://api.example.test/v1/responses)",
        result.content,
    );
}

test "ai chat request json includes deepseek thinking mode" {
    const allocator = std.testing.allocator;
    var messages = [_]RequestMessage{.{
        .role = .user,
        .content = @constCast("Hello"),
    }};
    const request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = @constCast("https://api.deepseek.com"),
        .api_key = @constCast("key"),
        .model = @constCast(ai_chat.DEFAULT_MODEL),
        .system_prompt = @constCast(ai_chat.DEFAULT_SYSTEM_PROMPT),
        .messages = messages[0..],
        .thinking_enabled = true,
        .reasoning_effort = @constCast("high"),
        .stream = false,
        .agent_enabled = false,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    const json = try buildRequestJson(allocator, &request);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reasoning_effort\":\"high\"") != null);
}

test "ai chat agent request json includes tool schemas" {
    const allocator = std.testing.allocator;
    var messages = [_]RequestMessage{.{
        .role = .user,
        .content = @constCast("List terminals"),
    }};
    const request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = @constCast("https://api.deepseek.com"),
        .api_key = @constCast("key"),
        .model = @constCast(ai_chat.DEFAULT_MODEL),
        .system_prompt = @constCast(ai_chat.DEFAULT_SYSTEM_PROMPT),
        .messages = messages[0..],
        .thinking_enabled = true,
        .reasoning_effort = @constCast("high"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    const json = try buildRequestJson(allocator, &request);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_session_exec\"") != null);
    if (@import("platform/pty_command.zig").wslSessionToolsEnabled()) {
        try std.testing.expect(std.mem.indexOf(u8, json, "\"wsl_session_exec\"") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, json, "\"wsl_session_exec\"") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_repl_exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_profile_save\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proxy_jump\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_profile_connect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tab_new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, @import("platform/pty_command.zig").tabNewToolPropertiesJson()) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, @import("platform/pty_command.zig").tabKindUsage()) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tab_close\"") != null);
}

test "ai chat responses request json uses input and response tool schemas" {
    const allocator = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = @constCast("call_1"),
        .name = @constCast("terminal_list"),
        .arguments = @constCast("{}"),
    }};
    var messages = [_]RequestMessage{
        .{
            .role = .user,
            .content = @constCast("List terminals"),
        },
        .{
            .role = .assistant,
            .content = @constCast(""),
            .tool_calls = calls[0..],
        },
        .{
            .role = .tool,
            .content = @constCast("surface=1"),
            .tool_call_id = @constCast("call_1"),
        },
    };
    const request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = @constCast("https://api.openai.com/v1"),
        .api_key = @constCast("key"),
        .model = @constCast("gpt-5"),
        .protocol = .responses,
        .system_prompt = @constCast("system"),
        .messages = messages[0..],
        .thinking_enabled = true,
        .reasoning_effort = @constCast("high"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    const json = try buildRequestJsonForMessages(allocator, &request, messages[0..], true);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"instructions\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function\",\"name\":\"terminal_list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function\",\"name\":\"terminal_context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function_call\",\"call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"surface=1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reasoning\":{\"effort\":\"high\"}") != null);
}

test "ai chat request json replays assistant reasoning content" {
    const allocator = std.testing.allocator;
    var messages = [_]RequestMessage{.{
        .role = .assistant,
        .content = @constCast("I will inspect the system."),
        .reasoning = @constCast("Need system info before answering."),
    }};
    const request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = @constCast("https://api.deepseek.com"),
        .api_key = @constCast("key"),
        .model = @constCast(ai_chat.DEFAULT_MODEL),
        .system_prompt = @constCast(ai_chat.DEFAULT_SYSTEM_PROMPT),
        .messages = messages[0..],
        .thinking_enabled = true,
        .reasoning_effort = @constCast("high"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    const json = try buildRequestJson(allocator, &request);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reasoning_content\":\"Need system info before answering.\"") != null);
}

test "ai chat request json adds thinking fallback for assistant tool calls without reasoning" {
    const allocator = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = @constCast("call-1"),
        .name = @constCast("skill_info"),
        .arguments = @constCast("{}"),
    }};
    var messages = [_]RequestMessage{.{
        .role = .assistant,
        .content = @constCast(""),
        .tool_calls = calls[0..],
    }};
    const request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = @constCast("https://api.deepseek.com"),
        .api_key = @constCast("key"),
        .model = @constCast(ai_chat.DEFAULT_MODEL),
        .system_prompt = @constCast(ai_chat.DEFAULT_SYSTEM_PROMPT),
        .messages = messages[0..],
        .thinking_enabled = true,
        .reasoning_effort = @constCast("high"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };

    const json = try buildRequestJson(allocator, &request);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"reasoning_content\":\"Tool call is required before answering.\"") != null);
}

test "ai chat request json replaces invalid utf8 bytes" {
    const allocator = std.testing.allocator;
    const bad = [_]u8{ 'o', 'k', ' ', 0xff, ' ', 0xc3 };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try ai_chat_protocol.appendJsonString(allocator, &out, bad[0..]);
    try std.testing.expectEqualStrings("\"ok \\ufffd \\ufffd\"", out.items);
}

test "ai chat streaming request asks provider to include usage" {
    const allocator = std.testing.allocator;
    var content = [_]u8{ 'h', 'i' };
    var model = [_]u8{ 'd', 'e', 'e', 'p', 's', 'e', 'e', 'k', '-', 'v', '4', '-', 'p', 'r', 'o' };
    var reasoning = [_]u8{ 'h', 'i', 'g', 'h' };
    var msg = [_]RequestMessage{.{ .role = .user, .content = content[0..] }};
    var request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = &.{},
        .api_key = &.{},
        .model = model[0..],
        .system_prompt = &.{},
        .messages = msg[0..],
        .stream = true,
        .agent_enabled = false,
        .tool_host = null,
        .tool_snapshot = null,
        .thinking_enabled = true,
        .reasoning_effort = reasoning[0..],
        .started_ms = 0,
    };
    const body = try buildRequestJsonForMessages(allocator, &request, msg[0..], false);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
}

// --- Subagent loop tests -----------------------------------------------------

const SubagentStubModel = struct {
    step: usize = 0,
    saw_base_url: [128]u8 = undefined,
    saw_base_url_len: usize = 0,
    saw_toolset: ai_chat_protocol.Toolset = .full,
    saw_memory_enabled: bool = true,
    saw_subagent_prompt: bool = false,

    fn call(ctx: ?*anyopaque, request: *const ChatRequest, messages: []const RequestMessage) anyerror!ApiResult {
        _ = messages;
        const self: *SubagentStubModel = @ptrCast(@alignCast(ctx.?));
        const a = request.allocator;
        const n = @min(request.base_url.len, self.saw_base_url.len);
        @memcpy(self.saw_base_url[0..n], request.base_url[0..n]);
        self.saw_base_url_len = n;
        self.saw_toolset = request.toolset;
        self.saw_memory_enabled = request.memory_enabled;
        self.saw_subagent_prompt = std.mem.eql(u8, request.system_prompt, @import("platform/agent_prompt.zig").subagentSystemPrompt);
        defer self.step += 1;
        if (self.step == 0) {
            const calls = try a.alloc(ToolCall, 1);
            calls[0] = .{
                .id = try a.dupe(u8, "c1"),
                .name = try a.dupe(u8, "write_file"),
                .arguments = try a.dupe(u8, "{}"),
            };
            return .{
                .content = try a.dupe(u8, ""),
                .tool_calls = calls,
                .usage = .{ .prompt_tokens = 8, .completion_tokens = 2, .total_tokens = 10 },
            };
        }
        return .{
            .content = try a.dupe(u8, "FINAL REPORT"),
            .usage = .{ .prompt_tokens = 4, .completion_tokens = 1, .total_tokens = 5 },
        };
    }
};

fn testSessionAndRequest(a: std.mem.Allocator) !struct { session: *Session, request: *ChatRequest } {
    const session = try Session.init(a, "test", "https://api.example", "key", "model", "prompt", "enabled", "medium", "false", "true");
    errdefer session.deinit();
    const request = try a.create(ChatRequest);
    request.* = .{
        .allocator = a,
        .session = session,
        .base_url = try a.dupe(u8, "https://api.example"),
        .api_key = try a.dupe(u8, "key"),
        .model = try a.dupe(u8, "model"),
        .system_prompt = try a.dupe(u8, "prompt"),
        .messages = &.{},
        .thinking_enabled = false,
        .reasoning_effort = try a.dupe(u8, "medium"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    return .{ .session = session, .request = request };
}

test "subagent loop rejects disallowed tools, returns the final report, accumulates usage" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();

    var stub = SubagentStubModel{};
    const report = try runSubagentTaskWithModel(env.request, "find the answer", .{ .ctx = &stub, .call = SubagentStubModel.call });
    defer a.free(report);

    try std.testing.expectEqualStrings("FINAL REPORT", report);
    try std.testing.expect(env.request.subagent_usage_present);
    try std.testing.expectEqual(@as(u64, 15), env.request.subagent_usage.total_tokens);
    try std.testing.expectEqual(ai_chat_protocol.Toolset.subagent, stub.saw_toolset);
    try std.testing.expect(!stub.saw_memory_enabled);
    try std.testing.expect(stub.saw_subagent_prompt);

    // Progress lines landed in the session as .tool messages: the rejected
    // write_file round plus the done line with rounds + tokens.
    env.session.mutex.lock();
    defer env.session.mutex.unlock();
    var saw_running = false;
    var saw_done = false;
    for (env.session.messages.items) |msg| {
        if (msg.role != .tool) continue;
        if (std.mem.indexOf(u8, msg.content, "subagent: running write_file") != null) saw_running = true;
        if (std.mem.indexOf(u8, msg.content, "subagent: done (2 rounds, 15 tokens)") != null) saw_done = true;
    }
    try std.testing.expect(saw_running);
    try std.testing.expect(saw_done);
}

test "subagent loop applies the profile override to the sub-request" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();
    env.request.subagent_profile = .{
        .base_url = try a.dupe(u8, "https://override.example"),
        .api_key = try a.dupe(u8, "ok"),
        .model = try a.dupe(u8, "om"),
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = try a.dupe(u8, "low"),
        .max_tokens = 2048,
    };

    var stub = SubagentStubModel{ .step = 1 }; // first call already returns the final answer
    const report = try runSubagentTaskWithModel(env.request, "task", .{ .ctx = &stub, .call = SubagentStubModel.call });
    defer a.free(report);
    try std.testing.expectEqualStrings("https://override.example", stub.saw_base_url[0..stub.saw_base_url_len]);
}

test "subagent loop honors cancellation" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();
    env.session.stop_requested.store(true, .release);

    var stub = SubagentStubModel{};
    try std.testing.expectError(error.Canceled, runSubagentTaskWithModel(env.request, "task", .{ .ctx = &stub, .call = SubagentStubModel.call }));
}

test "subagent tool call requires a task argument" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();

    var call = ToolCall{
        .id = try a.dupe(u8, "c1"),
        .name = try a.dupe(u8, "subagent"),
        .arguments = try a.dupe(u8, "{}"),
    };
    defer call.deinit(a);
    const out = try executeToolCall(env.request, call);
    defer a.free(out);
    try std.testing.expectEqualStrings("Missing task", out);
}

test "applySubagentUsage merges into the loop total" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();
    env.request.subagent_usage = .{ .prompt_tokens = 100, .completion_tokens = 20, .total_tokens = 120 };
    env.request.subagent_usage_present = true;

    var total: ApiUsage = .{ .total_tokens = 7 };
    var has_usage = false;
    applySubagentUsage(env.request, &total, &has_usage);
    try std.testing.expect(has_usage);
    try std.testing.expectEqual(@as(u64, 127), total.total_tokens);
}
