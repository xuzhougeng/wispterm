//! LLM map stage for the memory digest (spec §8): turn one session's new
//! transcript messages into a structured summary. Long sessions are chunked
//! and rolled up through a plain-text rolling summary (prompt B) before the
//! final JSON extraction (prompt A). Reduce (Task 6) builds the daily/
//! project rollup on top of these per-session results and reuses
//! `parseJsonObjectLenient`.
const std = @import("std");
const llm = @import("llm.zig");
const redact = @import("redact.zig");
const store = @import("store.zig");
const types = @import("types.zig");
const ai_types = @import("../terminal_agents/sessions/types.zig");

const PROMPT_A_SYSTEM =
    \\你是一名开发日志归纳员。你会收到一段开发会话的新增对话内容，以及（可能存在的）
    \\上一次的摘要。请在旧摘要的基础上合并本次新进展，生成一份简明的会话摘要。
    \\要求：
    \\- 不得复述任何密钥、token 或其他敏感凭证（如遇 [REDACTED] 标记，原样保留即可）。
    \\- 只输出合法 JSON，不要输出任何 JSON 之外的文字或代码块围栏。
    \\- JSON 结构必须是：{"summary":"…","topics":["…"],"outcome":"completed|in_progress|abandoned|unknown","artifacts":[{"type":"pr|commit|file|url","ref":"…"}]}
;

const PROMPT_B_SYSTEM =
    \\你是一名开发日志归纳员。你会收到一段开发会话的部分新增对话内容（可能还有更多内容
    \\会在后续追加）。请输出一段简明的纯文本滚动摘要，覆盖目前为止的关键进展、决策和结果。
    \\不要输出 JSON，不要复述任何密钥、token 或其他敏感凭证。
;

pub const MapOptions = struct {
    max_chars_per_message: usize = 2000,
    input_budget_chars: usize = 24_000,
};

pub const MapResult = struct {
    summary: []const u8,
    topics: []const []const u8,
    outcome: []const u8,
    artifacts: []const store.Artifact,
};

const JsonMapResult = struct {
    summary: []const u8 = "",
    topics: []const []const u8 = &.{},
    outcome: []const u8 = "unknown",
    artifacts: []const store.Artifact = &.{},
};

/// Strips a leading/trailing ``` fence (optionally tagged, e.g. ```json) and
/// slices from the first `{` to the last `}`, then parses leniently into
/// `arena` (ignore_unknown_fields, alloc_always so the result outlives
/// `raw`). Exported for reduce (Task 6) to reuse on its own LLM responses.
pub fn parseJsonObjectLenient(arena: std.mem.Allocator, comptime T: type, raw: []const u8) !T {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, text, "```")) {
        if (std.mem.indexOfScalar(u8, text, '\n')) |nl| {
            text = text[nl + 1 ..];
        }
        if (std.mem.endsWith(u8, text, "```")) {
            text = text[0 .. text.len - 3];
        }
        text = std.mem.trim(u8, text, " \t\r\n");
    }
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return error.NoJsonObject;
    const end = std.mem.lastIndexOfScalar(u8, text, '}') orelse return error.NoJsonObject;
    if (end < start) return error.NoJsonObject;
    const slice = text[start .. end + 1];
    const parsed = try std.json.parseFromSliceLeaky(T, arena, slice, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return parsed;
}

/// Builds the `[角色] 内容\n` line list for one session: skips meta/empty
/// messages, redacts each message, truncates oversized ones (head 2/3 +
/// marker + tail 1/3). Returns owned lines (gpa); caller frees with
/// `freeLines`.
fn buildLines(gpa: std.mem.Allocator, messages: []const ai_types.TranscriptMessage, max_chars_per_message: usize) ![][]u8 {
    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    for (messages) |msg| {
        if (msg.kind == .meta) continue;
        if (msg.content.len == 0) continue;

        const redacted = try redact.redact(gpa, msg.content);
        defer gpa.free(redacted);

        const body = try truncateMiddle(gpa, redacted, max_chars_per_message);
        defer gpa.free(body);

        const line = try std.fmt.allocPrint(gpa, "[{s}] {s}\n", .{ @tagName(msg.role), body });
        try lines.append(gpa, line);
    }
    return lines.toOwnedSlice(gpa);
}

fn freeLines(gpa: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| gpa.free(l);
    gpa.free(lines);
}

/// If `text` is over `max_chars`, keeps the head 2/3 and tail 1/3 around a
/// `\n…[截断]…\n` marker; otherwise dupes `text` unchanged.
fn truncateMiddle(gpa: std.mem.Allocator, text: []const u8, max_chars: usize) ![]u8 {
    if (text.len <= max_chars or max_chars == 0) return gpa.dupe(u8, text);
    const marker = "\n…[截断]…\n";
    const head_len = (max_chars * 2) / 3;
    const tail_len = max_chars - head_len;
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        text[0..head_len],
        marker,
        text[text.len - tail_len ..],
    });
}

pub fn summarizeSession(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    completer: llm.Completer,
    sess: types.CollectedSession,
    old_summary: ?[]const u8,
    opts: MapOptions,
) !MapResult {
    const lines = try buildLines(gpa, sess.new_messages, opts.max_chars_per_message);
    defer freeLines(gpa, lines);

    // Split into chunks that fit the input budget, cutting on message
    // boundaries. A chunk always contains at least one line even if that
    // single line exceeds the budget on its own.
    var chunk_starts: std.ArrayListUnmanaged(usize) = .empty;
    defer chunk_starts.deinit(gpa);
    try chunk_starts.append(gpa, 0);
    {
        var running: usize = 0;
        for (lines, 0..) |line, i| {
            if (running != 0 and running + line.len > opts.input_budget_chars) {
                try chunk_starts.append(gpa, i);
                running = 0;
            }
            running += line.len;
        }
    }
    try chunk_starts.append(gpa, lines.len); // sentinel end

    const num_chunks = chunk_starts.items.len - 1;

    var rolling: ?[]u8 = null; // gpa-owned, freed at loop end
    defer if (rolling) |r| gpa.free(r);

    var idx: usize = 0;
    while (idx < num_chunks) : (idx += 1) {
        const lo = chunk_starts.items[idx];
        const hi = chunk_starts.items[idx + 1];
        const chunk_text = try joinLines(gpa, lines[lo..hi]);
        defer gpa.free(chunk_text);

        const is_last = idx == num_chunks - 1;
        if (!is_last) {
            const user_text = try buildRollingUserText(gpa, rolling, chunk_text);
            defer gpa.free(user_text);
            const resp = try completer.complete(gpa, PROMPT_B_SYSTEM, user_text);
            if (rolling) |r| gpa.free(r);
            rolling = resp;
            continue;
        }

        // Final chunk: produce the JSON result, using old_summary + any
        // rolling summary as prior context.
        const user_text = try buildFinalUserText(gpa, old_summary, rolling, chunk_text);
        defer gpa.free(user_text);

        var raw = try completer.complete(gpa, PROMPT_A_SYSTEM, user_text);
        defer gpa.free(raw);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const parsed = parseJsonObjectLenient(arena_state.allocator(), JsonMapResult, raw) catch |err| retry: {
            const retry_text = try std.fmt.allocPrint(gpa, "{s}\n（上次输出无法解析为 JSON：{s}。请只输出合法 JSON。）", .{ user_text, @errorName(err) });
            defer gpa.free(retry_text);
            const retry_raw = try completer.complete(gpa, PROMPT_A_SYSTEM, retry_text);
            gpa.free(raw);
            raw = retry_raw;
            break :retry parseJsonObjectLenient(arena_state.allocator(), JsonMapResult, raw) catch return error.MapFailed;
        };

        return dupeResult(arena, parsed);
    }

    // No messages at all (num_chunks == 0 shouldn't happen since we always
    // push at least the [0, lines.len] chunk, even when lines.len == 0).
    unreachable;
}

fn joinLines(gpa: std.mem.Allocator, lines: []const []u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines) |l| try out.appendSlice(gpa, l);
    return out.toOwnedSlice(gpa);
}

fn buildRollingUserText(gpa: std.mem.Allocator, rolling: ?[]const u8, chunk_text: []const u8) ![]u8 {
    if (rolling) |r| {
        return std.fmt.allocPrint(gpa, "【目前为止的滚动摘要】\n{s}\n\n【新增对话】\n{s}", .{ r, chunk_text });
    }
    return std.fmt.allocPrint(gpa, "【新增对话】\n{s}", .{chunk_text});
}

fn buildFinalUserText(gpa: std.mem.Allocator, old_summary: ?[]const u8, rolling: ?[]const u8, chunk_text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    const w = out.writer(gpa);
    if (old_summary) |old| {
        if (old.len != 0) try w.print("【旧摘要】\n{s}\n\n", .{old});
    }
    if (rolling) |r| {
        try w.print("【滚动摘要】\n{s}\n\n", .{r});
    }
    try w.print("【新增对话】\n{s}", .{chunk_text});
    return out.toOwnedSlice(gpa);
}

fn dupeResult(arena: std.mem.Allocator, parsed: JsonMapResult) !MapResult {
    const topics = try arena.alloc([]const u8, parsed.topics.len);
    for (parsed.topics, 0..) |t, i| topics[i] = try arena.dupe(u8, t);
    const artifacts = try arena.alloc(store.Artifact, parsed.artifacts.len);
    for (parsed.artifacts, 0..) |a, i| {
        artifacts[i] = .{ .type = try arena.dupe(u8, a.type), .ref = try arena.dupe(u8, a.ref) };
    }
    return .{
        .summary = try arena.dupe(u8, parsed.summary),
        .topics = topics,
        .outcome = try arena.dupe(u8, parsed.outcome),
        .artifacts = artifacts,
    };
}

// ---- Tests ----

const StubCompleter = struct {
    responses: []const []const u8,
    calls: usize = 0,
    last_user_text: [8192]u8 = undefined,
    last_user_len: usize = 0,

    fn completer(self: *StubCompleter) llm.Completer {
        return .{ .ctx = self, .completeFn = complete };
    }
    fn complete(ctx: *anyopaque, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8 {
        _ = system_prompt;
        const self: *StubCompleter = @ptrCast(@alignCast(ctx));
        const n = @min(user_text.len, self.last_user_text.len);
        @memcpy(self.last_user_text[0..n], user_text[0..n]);
        self.last_user_len = n;
        const resp = self.responses[@min(self.calls, self.responses.len - 1)];
        self.calls += 1;
        return gpa.dupe(u8, resp);
    }
};

fn testSession(messages: []ai_types.TranscriptMessage) types.CollectedSession {
    return .{
        .provider = .claude,
        .source_id = "local",
        .session_id = "s1",
        .title = "t",
        .project_path = "/tmp/phantty",
        .started_at_ms = 0,
        .ended_at_ms = 0,
        .total_messages = @intCast(messages.len),
        .new_messages = messages,
        .source_file = "f.jsonl",
    };
}

test "memory_digest_digest: normal response parses into MapResult" {
    var stub = StubCompleter{ .responses = &.{
        \\{"summary":"s","topics":["t"],"outcome":"completed","artifacts":[{"type":"pr","ref":"#1"}]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = "hello" },
    };
    const result = try summarizeSession(arena.allocator(), std.testing.allocator, stub.completer(), testSession(&messages), null, .{});

    try std.testing.expectEqualStrings("s", result.summary);
    try std.testing.expectEqual(@as(usize, 1), result.topics.len);
    try std.testing.expectEqualStrings("t", result.topics[0]);
    try std.testing.expectEqualStrings("completed", result.outcome);
    try std.testing.expectEqual(@as(usize, 1), result.artifacts.len);
    try std.testing.expectEqualStrings("pr", result.artifacts[0].type);
    try std.testing.expectEqualStrings("#1", result.artifacts[0].ref);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
}

test "memory_digest_digest: strips code fence around JSON" {
    var stub = StubCompleter{ .responses = &.{
        "```json\n{\"summary\":\"s\",\"topics\":[],\"outcome\":\"in_progress\",\"artifacts\":[]}\n```",
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .assistant, .content = "did stuff" },
    };
    const result = try summarizeSession(arena.allocator(), std.testing.allocator, stub.completer(), testSession(&messages), null, .{});
    try std.testing.expectEqualStrings("s", result.summary);
    try std.testing.expectEqualStrings("in_progress", result.outcome);
}

test "memory_digest_digest: retries once on parse failure then succeeds" {
    var stub = StubCompleter{ .responses = &.{
        "not json at all",
        "{\"summary\":\"ok\",\"topics\":[],\"outcome\":\"unknown\",\"artifacts\":[]}",
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = "hi" },
    };
    const result = try summarizeSession(arena.allocator(), std.testing.allocator, stub.completer(), testSession(&messages), null, .{});
    try std.testing.expectEqualStrings("ok", result.summary);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "memory_digest_digest: fails MapFailed after second bad response" {
    var stub = StubCompleter{ .responses = &.{ "garbage one", "garbage two" } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = "hi" },
    };
    const result = summarizeSession(arena.allocator(), std.testing.allocator, stub.completer(), testSession(&messages), null, .{});
    try std.testing.expectError(error.MapFailed, result);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "memory_digest_digest: old summary is injected into the user text" {
    var stub = StubCompleter{ .responses = &.{
        "{\"summary\":\"s\",\"topics\":[],\"outcome\":\"unknown\",\"artifacts\":[]}",
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = "hi" },
    };
    _ = try summarizeSession(arena.allocator(), std.testing.allocator, stub.completer(), testSession(&messages), "上次做了 X 功能", .{});
    try std.testing.expect(std.mem.indexOf(u8, stub.last_user_text[0..stub.last_user_len], "上次做了 X 功能") != null);
}

test "memory_digest_digest: oversized message is truncated with marker" {
    var stub = StubCompleter{ .responses = &.{
        "{\"summary\":\"s\",\"topics\":[],\"outcome\":\"unknown\",\"artifacts\":[]}",
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 6000);
    defer gpa.free(big);
    @memset(big, 'x');

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = big },
    };
    _ = try summarizeSession(arena.allocator(), gpa, stub.completer(), testSession(&messages), null, .{ .max_chars_per_message = 2000 });

    const sent = stub.last_user_text[0..stub.last_user_len];
    try std.testing.expect(std.mem.indexOf(u8, sent, "…[截断]…") != null);
    try std.testing.expect(sent.len < 6000);
}

test "memory_digest_digest: chunks across the input budget and rolls up" {
    var stub = StubCompleter{ .responses = &.{
        "rolling summary so far",
        "{\"summary\":\"s\",\"topics\":[],\"outcome\":\"unknown\",\"artifacts\":[]}",
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const gpa = std.testing.allocator;
    var msg_bufs: [3][100]u8 = undefined;
    for (&msg_bufs) |*b| @memset(b, 'a');
    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = &msg_bufs[0] },
        .{ .role = .assistant, .content = &msg_bufs[1] },
        .{ .role = .user, .content = &msg_bufs[2] },
    };
    _ = try summarizeSession(arena.allocator(), gpa, stub.completer(), testSession(&messages), null, .{ .input_budget_chars = 120 });
    try std.testing.expect(stub.calls >= 2);
}

test "memory_digest_digest: secrets are redacted before reaching the completer" {
    var stub = StubCompleter{ .responses = &.{
        "{\"summary\":\"s\",\"topics\":[],\"outcome\":\"unknown\",\"artifacts\":[]}",
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = "my key is sk-abc12345678 do not share" },
    };
    _ = try summarizeSession(arena.allocator(), std.testing.allocator, stub.completer(), testSession(&messages), null, .{});

    const sent = stub.last_user_text[0..stub.last_user_len];
    try std.testing.expect(std.mem.indexOf(u8, sent, "sk-abc12345678") == null);
    try std.testing.expect(std.mem.indexOf(u8, sent, redact.MASK) != null);
}
