//! Worker-thread result sink for a conversation `Session`.
//!
//! Request workers (`request.zig`) run with no lock held and land their
//! output here: a finished or failed reply, streamed deltas, tool progress
//! rows, web-search and distill results, and the stop path. Every entry point
//! checks `closing` / `stop_requested` before and after taking
//! `Session.mutex`, and notifies the history hook only after unlocking.
//!
//! Split out of session.zig by responsibility: session.zig owns the session
//! state and the UI-thread API, this file owns what worker threads write back.
const std = @import("std");
const ai_chat = @import("session.zig");
const ai_chat_protocol = @import("protocol.zig");
const ai_chat_skills = @import("skills.zig");
const ai_skill_distill = @import("distill.zig");
const turn_stats = @import("turn_stats.zig");

const Session = ai_chat.Session;
const Message = ai_chat.Message;
const ChatRequest = ai_chat.ChatRequest;
const PendingHistoryChange = ai_chat.PendingHistoryChange;
const ApiResult = ai_chat_protocol.ApiResult;
const ApiUsage = ai_chat_protocol.ApiUsage;
const allocUsageFooter = ai_chat.allocUsageFooter;
const parseApiErrorResult = ai_chat_protocol.parseApiErrorResult;
const parseApiUsage = ai_chat_protocol.parseApiUsage;
const jsonStringValue = ai_chat_protocol.jsonStringValue;

pub fn requestCancelled(request: *const ChatRequest) bool {
    return request.session.closing.load(.acquire) or request.session.stop_requested.load(.acquire);
}

pub fn sessionCancelled(session: *Session) bool {
    return session.closing.load(.acquire) or session.stop_requested.load(.acquire);
}

pub fn finishStoppedRequest(session: *Session) void {
    defer session.markUiDirty();
    if (session.closing.load(.acquire)) return;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    session.request_inflight = false;
    session.distill_inflight = false;
    session.request_stopping = false;
    session.stop_requested.store(false, .release);
    session.collapseAutoExpandedDetailsLocked();
    session.setStatusLocked("Stopped");
}

pub fn appendAssistantResult(session: *Session, result: ApiResult, started_ms: i64) void {
    defer session.markUiDirty();
    const allocator = session.allocator;
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        session.request_inflight = false;
        session.request_stopping = false;
        session.stop_requested.store(false, .release);
        session.setStatusLocked("Stopped");
        return;
    }

    const content = allocator.dupe(u8, result.content) catch {
        session.request_inflight = false;
        session.collapseAutoExpandedDetailsLocked();
        session.setStatusLocked("Out of memory");
        return;
    };
    const timing = turn_stats.Timing{ .started_ms = started_ms, .finished_ms = std.time.milliTimestamp(), .user_wait_ms = result.user_wait_ms };
    var usage_footer = allocUsageFooter(allocator, timing, result.usage) catch null;
    var reasoning_copy: ?[]u8 = null;
    if (result.reasoning) |reasoning| {
        reasoning_copy = allocator.dupe(u8, reasoning) catch null;
    }
    const reasoning_visible = if (reasoning_copy) |r| r.len > 0 else false;
    session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = reasoning_copy,
        .usage_footer = usage_footer,
        .reasoning_collapsed = reasoning_visible,
        .reasoning_auto_expand = false,
        .ts_ms = std.time.milliTimestamp(),
    }) catch {
        allocator.free(content);
        if (reasoning_copy) |r| allocator.free(r);
        if (usage_footer) |footer| allocator.free(footer);
        session.request_inflight = false;
        session.collapseAutoExpandedDetailsLocked();
        session.setStatusLocked("Out of memory");
        return;
    };
    usage_footer = null;
    session.request_inflight = false;
    session.distill_inflight = false;
    session.collapseAutoExpandedDetailsLocked();
    session.scroll_px = 1_000_000;
    session.setCompletionStatusLocked(timing, result.usage);
    session.maybeAppendDistillSuggestionLocked();
    history_change = session.captureHistoryChangeLocked();
}

/// Append a `$websearch` result (or error text) as a local tool message and
/// finish the in-flight request. Called from the web-search worker thread with
/// no lock held. Mirrors the closing-guarded shape of `appendAssistantResult`.
pub fn appendWebSearchResult(session: *Session, text: []const u8) void {
    defer session.markUiDirty();
    if (session.closing.load(.acquire)) return;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    session.appendLocalToolMessageLocked(text) catch {
        session.request_inflight = false;
        session.setStatusLocked("Out of memory");
        return;
    };
    session.request_inflight = false;
    session.setStatusLocked("Ready");
}

pub fn applyDistillCandidate(session: *Session, candidate: *ai_skill_distill.Candidate) void {
    defer session.markUiDirty();
    const allocator = session.allocator;
    const root = ai_chat_skills.defaultWritableSkillRootPath(allocator) catch |err| {
        candidate.deinit(allocator);
        failDistillRequest(session, err);
        return;
    };
    defer allocator.free(root);
    const save_path = std.fs.path.join(allocator, &.{ root, candidate.name, "SKILL.md" }) catch |err| {
        candidate.deinit(allocator);
        failDistillRequest(session, err);
        return;
    };
    defer allocator.free(save_path);
    const preview = ai_skill_distill.renderPreviewMarkdown(allocator, candidate.*, save_path) catch |err| {
        candidate.deinit(allocator);
        failDistillRequest(session, err);
        return;
    };
    defer allocator.free(preview);

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire) or session.stop_requested.load(.acquire)) {
        candidate.deinit(allocator);
        session.request_inflight = false;
        session.request_stopping = false;
        session.distill_inflight = false;
        session.stop_requested.store(false, .release);
        session.setStatusLocked("Stopped");
        return;
    }

    session.clearDistillCandidateLocked();
    session.distill_candidate = candidate.*;
    candidate.* = undefined;
    session.distill_suggestion_pending = false;
    session.request_inflight = false;
    session.request_stopping = false;
    session.distill_inflight = false;
    session.appendLocalToolMessageLocked(preview) catch {
        session.clearDistillCandidateLocked();
        session.setStatusLocked("Out of memory");
        return;
    };
    session.setStatusLocked("Distill preview ready");
}

pub fn failDistillRequest(session: *Session, err: anyerror) void {
    defer session.markUiDirty();
    const allocator = session.allocator;
    const text = std.fmt.allocPrint(allocator, "Could not distill this conversation: {}.", .{err}) catch null;
    defer if (text) |msg| allocator.free(msg);

    session.mutex.lock();
    defer session.mutex.unlock();
    session.request_inflight = false;
    session.request_stopping = false;
    session.distill_inflight = false;
    session.stop_requested.store(false, .release);
    session.clearDistillCandidateLocked();
    if (text) |msg| {
        session.appendLocalToolMessageLocked(msg) catch {
            session.setStatusLocked("Out of memory");
            return;
        };
    }
    session.setStatusLocked("Ready");
}

pub fn appendProgressMessage(session: *Session, text: []const u8) !void {
    return appendProgressMessageCollapsed(session, text, false);
}

/// Live progress row; `collapsed` shows only its header row (the ask_user
/// call, whose question card already shows the arguments).
pub fn appendProgressMessageCollapsed(session: *Session, text: []const u8, collapsed: bool) !void {
    defer session.markUiDirty();
    if (sessionCancelled(session)) return error.Canceled;
    const allocator = session.allocator;
    const content = try allocator.dupe(u8, text);
    errdefer allocator.free(content);

    session.mutex.lock();
    defer session.mutex.unlock();
    if (sessionCancelled(session)) return error.Canceled;
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = content,
        .reasoning = null,
        .persist_to_history = false,
        .content_collapsed = collapsed,
        .content_auto_expand = true,
        .ts_ms = std.time.milliTimestamp(),
    });
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Running tools...");
}

pub fn appendReplayableToolMessage(
    session: *Session,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) !void {
    defer session.markUiDirty();
    if (sessionCancelled(session)) return error.Canceled;
    const allocator = session.allocator;
    const content = try allocator.dupe(u8, text);
    var content_owned = true;
    errdefer if (content_owned) allocator.free(content);
    const id = try allocator.dupe(u8, tool_call_id);
    var id_owned = true;
    errdefer if (id_owned) allocator.free(id);
    const name = try allocator.dupe(u8, tool_name);
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);

    var msg = Message{
        .role = .tool,
        .content = content,
        .tool_call_id = id,
        .tool_name = name,
        .replay_to_model = true,
        .content_collapsed = true,
        .content_auto_expand = false,
        .ts_ms = std.time.milliTimestamp(),
    };
    content_owned = false;
    id_owned = false;
    name_owned = false;
    var msg_owned = true;
    errdefer if (msg_owned) msg.deinit(allocator);

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (sessionCancelled(session)) return error.Canceled;
    try session.messages.append(allocator, msg);
    msg_owned = false;
    history_change = session.captureHistoryChangeLocked();
}

pub fn beginAssistantStream(session: *Session) !usize {
    defer session.markUiDirty();
    const allocator = session.allocator;
    if (sessionCancelled(session)) return error.Canceled;

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (sessionCancelled(session)) return error.Canceled;

    const content = try allocator.dupe(u8, "");
    errdefer allocator.free(content);
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = null,
        .reasoning_collapsed = false,
        .reasoning_auto_expand = true,
        .ts_ms = std.time.milliTimestamp(),
    });
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Streaming...");
    history_change = session.captureHistoryChangeLocked();
    return session.messages.items.len - 1;
}

fn growStreamCapacity(current_capacity: usize, required_capacity: usize) usize {
    var capacity = if (current_capacity > 0) current_capacity else @as(usize, 64);
    while (capacity < required_capacity) {
        if (capacity > std.math.maxInt(usize) / 2) return required_capacity;
        capacity *= 2;
    }
    return capacity;
}

fn appendOwnedBytes(
    allocator: std.mem.Allocator,
    bytes: *[]u8,
    capacity: *usize,
    delta: []const u8,
) !void {
    if (delta.len == 0) return;

    const old_len = bytes.*.len;
    const new_len = try std.math.add(usize, old_len, delta.len);
    const current_capacity = if (capacity.* > 0) capacity.* else old_len;
    if (new_len > current_capacity) {
        const new_capacity = growStreamCapacity(current_capacity, new_len);
        const grown = if (current_capacity == 0)
            try allocator.alloc(u8, new_capacity)
        else
            try allocator.realloc(bytes.*.ptr[0..current_capacity], new_capacity);
        bytes.* = grown[0..new_len];
        capacity.* = new_capacity;
    } else {
        bytes.* = bytes.*.ptr[0..new_len];
    }
    @memcpy(bytes.*[old_len..new_len], delta);
}

fn appendOptionalOwnedBytes(
    allocator: std.mem.Allocator,
    bytes: *?[]u8,
    capacity: *usize,
    delta: []const u8,
) !void {
    if (bytes.*) |old_bytes| {
        var updated = old_bytes;
        try appendOwnedBytes(allocator, &updated, capacity, delta);
        bytes.* = updated;
        return;
    }

    const new_capacity = growStreamCapacity(0, delta.len);
    const allocated = try allocator.alloc(u8, new_capacity);
    @memcpy(allocated[0..delta.len], delta);
    bytes.* = allocated[0..delta.len];
    capacity.* = new_capacity;
}

pub fn appendAssistantStreamDelta(session: *Session, message_idx: usize, content_delta: []const u8, reasoning_delta: []const u8) !void {
    if (content_delta.len == 0 and reasoning_delta.len == 0) return;
    const allocator = session.allocator;
    if (sessionCancelled(session)) return;

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (sessionCancelled(session)) return;
    if (message_idx >= session.messages.items.len) return error.StreamMessageMissing;

    var msg = &session.messages.items[message_idx];
    if (content_delta.len > 0) {
        try appendOwnedBytes(allocator, &msg.content, &msg.content_capacity, content_delta);
    }
    if (reasoning_delta.len > 0) {
        try appendOptionalOwnedBytes(allocator, &msg.reasoning, &msg.reasoning_capacity, reasoning_delta);
    }
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Streaming...");
    history_change = session.captureHistoryChangeLocked();
}

pub fn finishAssistantStream(session: *Session, message_idx: usize, started_ms: i64, first_token_ms: i64, usage: ?ApiUsage) void {
    defer session.markUiDirty();
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        session.request_inflight = false;
        session.distill_inflight = false;
        session.request_stopping = false;
        session.stop_requested.store(false, .release);
        session.setStatusLocked("Stopped");
        return;
    }
    const timing = turn_stats.Timing{ .started_ms = started_ms, .finished_ms = std.time.milliTimestamp(), .first_token_ms = first_token_ms };
    history_change = sealStreamMessageLocked(session, message_idx, timing, usage);
    session.request_inflight = false;
    session.distill_inflight = false;
    session.collapseAutoExpandedDetailsLocked();
    session.scroll_px = 1_000_000;
    session.setCompletionStatusLocked(timing, usage);
    session.maybeAppendDistillSuggestionLocked();
}

/// Seal a stream bubble's message in place: fill an all-empty message with
/// "No response", attach the usage footer, and capture the history change.
/// Message-only — request state and status stay with the caller.
fn sealStreamMessageLocked(session: *Session, message_idx: usize, timing: turn_stats.Timing, usage: ?ApiUsage) ?PendingHistoryChange {
    if (message_idx >= session.messages.items.len) return null;
    const msg = &session.messages.items[message_idx];
    if (msg.content.len == 0 and msg.reasoning == null) {
        appendOwnedBytes(session.allocator, &msg.content, &msg.content_capacity, "No response") catch {};
    }
    if (allocUsageFooter(session.allocator, timing, usage) catch null) |footer| {
        if (msg.usage_footer) |old_footer| session.allocator.free(old_footer);
        msg.usage_footer = footer;
    }
    return session.captureHistoryChangeLocked();
}

/// Cancel-path seal: `finishAssistantStream` deliberately refuses to touch the
/// message once `stop_requested` is set (it routes to `finishStoppedRequest`),
/// which left a cancelled turn's half-streamed bubble unsealed. Seals the
/// message only — pair with `finishStoppedRequest` for the request state.
pub fn sealCancelledAssistantStream(session: *Session, message_idx: usize, started_ms: i64, usage: ?ApiUsage) void {
    if (session.closing.load(.acquire)) return;
    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (session.closing.load(.acquire)) return;
    history_change = sealStreamMessageLocked(session, message_idx, .{ .started_ms = started_ms, .finished_ms = std.time.milliTimestamp() }, usage);
}

pub fn failAssistantStream(session: *Session, message_idx: ?usize, text: []const u8) void {
    defer session.markUiDirty();
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }
    if (message_idx) |idx| {
        appendAssistantStreamDelta(session, idx, text, "") catch {};
        finishAssistantStream(session, idx, 0, 0, null);
        return;
    }

    appendAssistantResult(session, .{ .content = @constCast(text) }, 0);
}

pub fn applyApiStreamLineToSession(
    allocator: std.mem.Allocator,
    session: *Session,
    message_idx: usize,
    line_raw: []const u8,
    usage_out: *?ApiUsage,
    first_token_ms: *i64,
) !bool {
    defer session.markUiDirty();
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (!std.mem.startsWith(u8, line, "data:")) return false;

    const data = std.mem.trim(u8, line["data:".len..], " \t");
    if (data.len == 0) return false;
    if (std.mem.eql(u8, data, "[DONE]")) return true;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return false;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return false;
    const obj = root.object;
    if (parseApiUsage(root)) |usage| usage_out.* = usage;

    if (try parseApiErrorResult(allocator, root)) |result| {
        defer result.deinit(allocator);
        try appendAssistantStreamDelta(session, message_idx, result.content, "");
        return true;
    }

    if (jsonStringValue(obj.get("type"))) |event_type| {
        if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            const content_delta = jsonStringValue(obj.get("delta")) orelse "";
            try appendAssistantStreamDelta(session, message_idx, content_delta, "");
            if (content_delta.len > 0 and first_token_ms.* == 0) first_token_ms.* = std.time.milliTimestamp();
            return false;
        }
        if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            const reasoning_delta = jsonStringValue(obj.get("delta")) orelse "";
            try appendAssistantStreamDelta(session, message_idx, "", reasoning_delta);
            if (reasoning_delta.len > 0 and first_token_ms.* == 0) first_token_ms.* = std.time.milliTimestamp();
            return false;
        }
        if (std.mem.eql(u8, event_type, "response.completed")) {
            if (obj.get("response")) |response_value| {
                if (parseApiUsage(response_value)) |usage| usage_out.* = usage;
            }
            return true;
        }
        if (std.mem.eql(u8, event_type, "response.failed")) {
            if (obj.get("response")) |response_value| {
                if (try parseApiErrorResult(allocator, response_value)) |result| {
                    defer result.deinit(allocator);
                    try appendAssistantStreamDelta(session, message_idx, result.content, "");
                    return true;
                }
            }
            try appendAssistantStreamDelta(session, message_idx, "API returned an error", "");
            return true;
        }
    }

    // Some providers send `"error": null` on every chunk; only a real value
    // that parseApiErrorResult could not describe ends the stream here.
    if (obj.get("error")) |error_value| {
        if (error_value != .null) {
            try appendAssistantStreamDelta(session, message_idx, "API returned an error", "");
            return true;
        }
    }

    const choices_value = obj.get("choices") orelse return false;
    if (choices_value != .array or choices_value.array.items.len == 0) return false;
    const choice = choices_value.array.items[0];
    if (choice != .object) return false;
    const delta_value = choice.object.get("delta") orelse return false;
    if (delta_value != .object) return false;

    const content_delta = if (delta_value.object.get("content")) |content_value|
        if (content_value == .string) content_value.string else ""
    else
        "";
    const reasoning_delta = if (delta_value.object.get("reasoning_content")) |reasoning_value|
        if (reasoning_value == .string) reasoning_value.string else ""
    else
        "";
    try appendAssistantStreamDelta(session, message_idx, content_delta, reasoning_delta);
    if ((content_delta.len > 0 or reasoning_delta.len > 0) and first_token_ms.* == 0) first_token_ms.* = std.time.milliTimestamp();
    return false;
}

test "ai chat appends usage footer to completed assistant message" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    appendAssistantResult(&session, .{
        .content = @constCast("done"),
        .usage = .{
            .prompt_tokens = 12,
            .completion_tokens = 34,
            .prompt_cache_hit_tokens = 5,
            .prompt_cache_miss_tokens = 7,
            .total_tokens = 46,
        },
    }, std.time.milliTimestamp() - 2300);

    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expect(session.messages.items[0].usage_footer != null);
    const footer = session.messages.items[0].usage_footer.?;
    try std.testing.expect(std.mem.indexOf(u8, footer, "total 46") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "cache 5/7") != null);
}

test "ai chat stream records first token timestamp once" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    const message_idx = try beginAssistantStream(&session);
    var usage: ?ApiUsage = null;
    var first_token_ms: i64 = 0;

    try std.testing.expect(!try applyApiStreamLineToSession(
        allocator,
        &session,
        message_idx,
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}",
        &usage,
        &first_token_ms,
    ));
    try std.testing.expect(first_token_ms > 0);
    const first = first_token_ms;

    try std.testing.expect(!try applyApiStreamLineToSession(
        allocator,
        &session,
        message_idx,
        "data: {\"choices\":[{\"delta\":{\"content\":\"!\"}}]}",
        &usage,
        &first_token_ms,
    ));
    try std.testing.expectEqual(first, first_token_ms);
    try std.testing.expectEqualStrings("hi!", session.messages.items[message_idx].content);
}

test "ai chat stop request suppresses late assistant result" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    session.request_inflight = true;
    session.stopRequest();
    try std.testing.expect(session.request_stopping);
    try std.testing.expectEqualStrings("Stopping...", session.status());

    appendAssistantResult(&session, .{ .content = @constCast("late result") }, 0);
    try std.testing.expect(!session.request_inflight);
    try std.testing.expect(!session.request_stopping);
    try std.testing.expect(!session.stop_requested.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqualStrings("Stopped", session.status());
}

test "ai chat appends automatic distill suggestion after tool-heavy result" {
    const a = std.testing.allocator;
    ai_chat.configureAgent(.{ .distill_suggest_enabled = true });
    defer ai_chat.configureAgent(.{});
    var session = Session{ .allocator = a };
    defer {
        if (session.distill_candidate) |*candidate| candidate.deinit(a);
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "fix this") });
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running exec one"), .persist_to_history = false });
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running exec two"), .persist_to_history = false });
    session.request_inflight = true;

    appendAssistantResult(&session, .{ .content = @constCast("done") }, 0);

    try std.testing.expect(session.distill_suggestion_pending);
    try std.testing.expectEqual(@as(usize, 5), session.messages.items.len);
    try std.testing.expectEqual(ai_chat.Role.tool, session.messages.items[4].role);
    try std.testing.expect(!session.messages.items[4].persist_to_history);
    try std.testing.expect(std.mem.containsAtLeast(u8, session.messages.items[4].content, 1, "Distill it into a skill"));
}

test "ai chat skips automatic distill suggestion when disabled" {
    const a = std.testing.allocator;
    // Default: ai-distill-suggest is off, so the prompt must not auto-appear
    // even after a tool-heavy turn that the heuristic would otherwise flag.
    ai_chat.configureAgent(.{});
    defer ai_chat.configureAgent(.{});
    var session = Session{ .allocator = a };
    defer {
        if (session.distill_candidate) |*candidate| candidate.deinit(a);
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "fix this") });
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running exec one"), .persist_to_history = false });
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running exec two"), .persist_to_history = false });
    session.request_inflight = true;

    appendAssistantResult(&session, .{ .content = @constCast("done") }, 0);

    try std.testing.expect(!session.distill_suggestion_pending);
    // Only the appended assistant message — no extra distill-suggestion tool row.
    try std.testing.expectEqual(@as(usize, 4), session.messages.items.len);
    try std.testing.expectEqual(ai_chat.Role.assistant, session.messages.items[3].role);
}

test "assistant stream deltas grow with spare capacity" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();

    const message_idx = try beginAssistantStream(session);
    for (0..100) |_| {
        try appendAssistantStreamDelta(session, message_idx, "x", "");
    }
    for (0..20) |_| {
        try appendAssistantStreamDelta(session, message_idx, "", "r");
    }

    const msg = session.messages.items[message_idx];
    try std.testing.expectEqual(@as(usize, 100), msg.content.len);
    try std.testing.expect(std.mem.allEqual(u8, msg.content, 'x'));
    try std.testing.expect(msg.content_capacity > msg.content.len);
    try std.testing.expect(msg.reasoning != null);
    try std.testing.expectEqual(@as(usize, 20), msg.reasoning.?.len);
    try std.testing.expect(std.mem.allEqual(u8, msg.reasoning.?, 'r'));
    try std.testing.expect(msg.reasoning_capacity > msg.reasoning.?.len);
}
