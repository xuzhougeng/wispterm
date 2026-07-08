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

const PROMPT_REDUCE_SYSTEM =
    \\你是一名开发日志归纳员。你会收到当天多个开发会话的紧凑摘要（每条含 project/title/
    \\summary/outcome）。请按项目（project）分组归纳，并生成当天的整体亮点和各项目的时间线。
    \\要求：
    \\- 不得复述任何密钥、token 或其他敏感凭证（如遇 [REDACTED] 标记，原样保留即可）。
    \\- 只输出合法 JSON，不要输出任何 JSON 之外的文字或代码块围栏。
    \\- JSON 结构必须是：{"projects":[{"slug":"…","summary":"…","session_refs":["…"]}],"highlights":["…"],"timeline":[{"slug":"…","summary":"…","events":[{"type":"progress|decision|problem|todo","text":"…","refs":["…"]}]}]}
    \\- timeline 必须是数组（每个元素对应一个项目），不要用以 slug 为键的对象。
    \\- projects 与 timeline 的 session_refs 只能填输入数组里 session_id 字段的原值（原样照抄，不得改写、拼接或翻译），
    \\  禁止填标题（title）或自造的编号/名称；不确定就留空数组。
;

const PROMPT_HIGHLIGHTS_SYSTEM =
    \\你是一名开发日志归纳员。你会收到当天各项目的摘要。请只生成当天的整体亮点列表。
    \\要求：
    \\- 只输出合法 JSON，不要输出任何 JSON 之外的文字或代码块围栏。
    \\- JSON 结构必须是：{"highlights":["…"]}
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

/// Snap a byte offset backward to the nearest UTF-8 sequence start so a
/// slice ending (or starting) there never splits a codepoint.
fn snapToCharBoundary(text: []const u8, offset: usize) usize {
    var o = offset;
    // 0b10xxxxxx are continuation bytes; walk back to a lead byte.
    while (o > 0 and o < text.len and (text[o] & 0b1100_0000) == 0b1000_0000) o -= 1;
    return o;
}

/// If `text` is over `max_chars`, keeps the head 2/3 and tail 1/3 around a
/// `\n…[截断]…\n` marker; otherwise dupes `text` unchanged.
fn truncateMiddle(gpa: std.mem.Allocator, text: []const u8, max_chars: usize) ![]u8 {
    if (text.len <= max_chars or max_chars == 0) return gpa.dupe(u8, text);
    const marker = "\n…[截断]…\n";
    const head_len = (max_chars * 2) / 3;
    const tail_len = max_chars - head_len;
    const head_end = snapToCharBoundary(text, head_len);
    const tail_start = snapToCharBoundary(text, text.len - tail_len);
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        text[0..head_end],
        marker,
        text[tail_start..],
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

    // Nothing left after filtering meta/empty messages: no-op, no LLM call
    // (spec: an all-meta transcript has nothing to summarize).
    if (lines.len == 0) {
        return .{
            .summary = try arena.dupe(u8, old_summary orelse ""),
            .topics = &.{},
            .outcome = "unknown",
            .artifacts = &.{},
        };
    }

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

const VALID_OUTCOMES = [_][]const u8{ "completed", "in_progress", "abandoned", "unknown" };
const VALID_EVENT_TYPES = [_][]const u8{ "progress", "decision", "problem", "todo" };

/// The LLM's `outcome`/event `type` fields are free text; clamp anything
/// outside the closed enum to a safe default rather than let it flow into
/// stored JSON unchecked.
fn clampEnum(value: []const u8, valid: []const []const u8, default: []const u8) []const u8 {
    for (valid) |v| {
        if (std.mem.eql(u8, value, v)) return value;
    }
    return default;
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
        .outcome = try arena.dupe(u8, clampEnum(parsed.outcome, &VALID_OUTCOMES, "unknown")),
        .artifacts = artifacts,
    };
}

// ---- Reduce stage (daily report + timelines, spec §8/§9 rollup) ----

/// Sessions above this count are bucketed by project (one LLM call per
/// project) plus one small highlights-only synthesis call, instead of a
/// single call with everything inlined.
const REDUCE_BUCKET_THRESHOLD = 50;

pub const ProjectTimeline = struct { slug: []const u8, entry: store.TimelineEntry };

pub const ReduceResult = struct {
    projects: []const store.DailyProject,
    highlights: []const []const u8,
    timelines: []const ProjectTimeline,
};

/// session_id/project/title/summary/outcome — the compact input fed to the
/// reduce prompt via `std.json.Stringify.valueAlloc` (never hand-built).
/// `session_id` is included specifically so the LLM has the real id to copy
/// into `session_refs` instead of inventing one from the title.
const SessionCompact = struct {
    session_id: []const u8,
    project: []const u8,
    title: []const u8,
    summary: []const u8,
    outcome: []const u8,
};

const JsonReduceEvent = struct {
    type: []const u8 = "",
    text: []const u8 = "",
    refs: []const []const u8 = &.{},
};
const JsonReduceTimeline = struct {
    slug: []const u8 = "",
    summary: []const u8 = "",
    events: []const JsonReduceEvent = &.{},
};
const JsonReduceProject = struct {
    slug: []const u8 = "",
    summary: []const u8 = "",
    session_refs: []const []const u8 = &.{},
};
const JsonReduceResult = struct {
    projects: []const JsonReduceProject = &.{},
    highlights: []const []const u8 = &.{},
    timeline: []const JsonReduceTimeline = &.{},
};
const JsonHighlightsOnly = struct {
    highlights: []const []const u8 = &.{},
};

/// Sends `user_text` to the completer, parses leniently as `T`, and retries
/// once (with the parse error appended) on failure. `error.ReduceFailed` on
/// a second bad response. Mirrors summarizeSession's retry-once flow.
fn completeAndParse(arena: std.mem.Allocator, gpa: std.mem.Allocator, completer: llm.Completer, comptime T: type, system_prompt: []const u8, user_text: []const u8) !T {
    var raw = try completer.complete(gpa, system_prompt, user_text);
    defer gpa.free(raw);

    return parseJsonObjectLenient(arena, T, raw) catch |err| {
        const retry_text = try std.fmt.allocPrint(gpa, "{s}\n（上次输出无法解析为 JSON：{s}。请只输出合法 JSON。）", .{ user_text, @errorName(err) });
        defer gpa.free(retry_text);
        const retry_raw = try completer.complete(gpa, system_prompt, retry_text);
        gpa.free(raw);
        raw = retry_raw;
        return parseJsonObjectLenient(arena, T, raw) catch return error.ReduceFailed;
    };
}

/// Renders `sessions` as the compact `[{project,title,summary,outcome}, …]`
/// JSON array the reduce prompt expects.
fn compactSessionsJson(gpa: std.mem.Allocator, sessions: []const store.DailySession) ![]u8 {
    var compact = try gpa.alloc(SessionCompact, sessions.len);
    defer gpa.free(compact);
    for (sessions, 0..) |s, i| {
        compact[i] = .{ .session_id = s.session_id, .project = s.project, .title = s.title, .summary = s.summary, .outcome = s.outcome };
    }
    return std.json.Stringify.valueAlloc(gpa, compact, .{});
}

/// Fills in `session_refs` for a parsed project/timeline entry when the LLM
/// omitted it, using the session_ids of every session under `slug`.
fn sessionRefsForSlug(arena: std.mem.Allocator, sessions: []const store.DailySession, slug: []const u8) ![]const []const u8 {
    var refs: std.ArrayListUnmanaged([]const u8) = .empty;
    for (sessions) |s| {
        if (std.mem.eql(u8, s.project, slug)) try refs.append(arena, s.session_id);
    }
    return refs.toOwnedSlice(arena);
}

/// Keeps only the entries of `refs` that match an actual `session_id` in
/// `sessions` (the day's real input set), dropping anything the LLM
/// hallucinated (e.g. a title copied in place of an id). Unlike `events[].refs`
/// (which legitimately hold pr/commit/file references and are never
/// filtered), `session_refs` must only ever point at real session ids.
/// Illegal entries are dropped silently save for a debug-level count.
fn filterSessionRefs(arena: std.mem.Allocator, refs: []const []const u8, sessions: []const store.DailySession) ![]const []const u8 {
    var kept: std.ArrayListUnmanaged([]const u8) = .empty;
    var dropped: usize = 0;
    for (refs) |r| {
        const valid = for (sessions) |s| {
            if (std.mem.eql(u8, s.session_id, r)) break true;
        } else false;
        if (valid) {
            try kept.append(arena, try arena.dupe(u8, r));
        } else {
            dropped += 1;
        }
    }
    if (dropped > 0) {
        std.log.debug("memory_digest: dropped {d} non-session_id ref(s) from session_refs", .{dropped});
    }
    return kept.toOwnedSlice(arena);
}

/// Dupes a parsed reduce result into `arena`, backfilling `session_refs` from
/// `sessions` wherever the LLM left them empty, and filtering whatever the
/// LLM did supply down to real session ids (spec: session_refs must be
/// faithful to the input, never a hallucinated title or made-up id).
fn dupeReduceResult(arena: std.mem.Allocator, parsed: JsonReduceResult, date: []const u8, sessions: []const store.DailySession) !ReduceResult {
    const projects = try arena.alloc(store.DailyProject, parsed.projects.len);
    for (parsed.projects, 0..) |p, i| {
        const slug = try arena.dupe(u8, p.slug);
        var refs = p.session_refs;
        if (refs.len == 0) refs = try sessionRefsForSlug(arena, sessions, slug);
        const duped_refs = try filterSessionRefs(arena, refs, sessions);
        projects[i] = .{ .slug = slug, .summary = try arena.dupe(u8, p.summary), .session_refs = duped_refs };
    }

    const highlights = try arena.alloc([]const u8, parsed.highlights.len);
    for (parsed.highlights, 0..) |h, i| highlights[i] = try arena.dupe(u8, h);

    const timelines = try arena.alloc(ProjectTimeline, parsed.timeline.len);
    for (parsed.timeline, 0..) |t, i| {
        const slug = try arena.dupe(u8, t.slug);
        const events = try arena.alloc(store.TimelineEvent, t.events.len);
        for (t.events, 0..) |e, j| {
            const event_refs = try arena.alloc([]const u8, e.refs.len);
            for (e.refs, 0..) |r, k| event_refs[k] = try arena.dupe(u8, r);
            events[j] = .{ .type = try arena.dupe(u8, clampEnum(e.type, &VALID_EVENT_TYPES, "progress")), .text = try arena.dupe(u8, e.text), .refs = event_refs };
        }
        const session_refs = try sessionRefsForSlug(arena, sessions, slug);
        timelines[i] = .{ .slug = slug, .entry = .{
            .date = try arena.dupe(u8, date),
            .summary = try arena.dupe(u8, t.summary),
            .events = events,
            .session_refs = session_refs,
        } };
    }

    return .{ .projects = projects, .highlights = highlights, .timelines = timelines };
}

/// One reduce call over `sessions` (assumed to already fit the prompt): builds
/// the compact JSON input, calls the completer, parses (with retry), and
/// dupes the result into `arena`.
fn reduceOnce(arena: std.mem.Allocator, gpa: std.mem.Allocator, completer: llm.Completer, date: []const u8, sessions: []const store.DailySession) !ReduceResult {
    const input_json = try compactSessionsJson(gpa, sessions);
    defer gpa.free(input_json);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const parsed = try completeAndParse(arena_state.allocator(), gpa, completer, JsonReduceResult, PROMPT_REDUCE_SYSTEM, input_json);
    return dupeReduceResult(arena, parsed, date, sessions);
}

/// >50-session path: buckets sessions by project (one reduce call per
/// bucket), then makes one small highlights-only call over the per-project
/// summaries to synthesize the day's overall highlights.
fn reduceBucketed(arena: std.mem.Allocator, gpa: std.mem.Allocator, completer: llm.Completer, date: []const u8, sessions: []const store.DailySession) !ReduceResult {
    // Partition session indices by project slug (stable, contiguous runs).
    const order = try gpa.alloc(usize, sessions.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, sessions, struct {
        fn less(ctx: []const store.DailySession, a: usize, b: usize) bool {
            return std.mem.order(u8, ctx[a].project, ctx[b].project) == .lt;
        }
    }.less);

    var grouped = try gpa.alloc(store.DailySession, sessions.len);
    defer gpa.free(grouped);
    for (order, 0..) |o, i| grouped[i] = sessions[o];

    var all_projects: std.ArrayListUnmanaged(store.DailyProject) = .empty;
    var all_timelines: std.ArrayListUnmanaged(ProjectTimeline) = .empty;

    var i: usize = 0;
    while (i < grouped.len) {
        var j = i + 1;
        while (j < grouped.len and std.mem.eql(u8, grouped[j].project, grouped[i].project)) : (j += 1) {}
        const bucket = try reduceOnce(arena, gpa, completer, date, grouped[i..j]);
        try all_projects.appendSlice(arena, bucket.projects);
        try all_timelines.appendSlice(arena, bucket.timelines);
        i = j;
    }

    // Small synthesis call: feed each project's summary back in to produce
    // the day's overall highlights.
    const HighlightInput = struct { slug: []const u8, summary: []const u8 };
    var highlight_inputs = try gpa.alloc(HighlightInput, all_projects.items.len);
    defer gpa.free(highlight_inputs);
    for (all_projects.items, 0..) |p, k| highlight_inputs[k] = .{ .slug = p.slug, .summary = p.summary };

    const highlights_input_json = try std.json.Stringify.valueAlloc(gpa, highlight_inputs, .{});
    defer gpa.free(highlights_input_json);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const parsed_highlights = try completeAndParse(arena_state.allocator(), gpa, completer, JsonHighlightsOnly, PROMPT_HIGHLIGHTS_SYSTEM, highlights_input_json);

    const highlights = try arena.alloc([]const u8, parsed_highlights.highlights.len);
    for (parsed_highlights.highlights, 0..) |h, k| highlights[k] = try arena.dupe(u8, h);

    return .{ .projects = all_projects.items, .highlights = highlights, .timelines = all_timelines.items };
}

/// Builds the daily report (per-project summaries + overall highlights) and
/// per-project timeline entries for `date` from `sessions`' map-stage
/// summaries (spec §8/§9). Sessions above `REDUCE_BUCKET_THRESHOLD` are
/// bucketed by project to keep each LLM call's input bounded; otherwise one
/// call covers everything.
pub fn reduceDay(arena: std.mem.Allocator, gpa: std.mem.Allocator, completer: llm.Completer, date: []const u8, sessions: []const store.DailySession) !ReduceResult {
    if (sessions.len > REDUCE_BUCKET_THRESHOLD) {
        return reduceBucketed(arena, gpa, completer, date, sessions);
    }
    return reduceOnce(arena, gpa, completer, date, sessions);
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

test "memory_digest_digest: UTF-8 truncation snaps to char boundaries" {
    var stub = StubCompleter{ .responses = &.{
        "{\"summary\":\"s\",\"topics\":[],\"outcome\":\"unknown\",\"artifacts\":[]}",
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const gpa = std.testing.allocator;
    // Build a 3000-char message of '中' (each '中' is 3 bytes in UTF-8: E4 B8 AD)
    // Total = 3000 * 3 = 9000 bytes
    const big = try gpa.alloc(u8, 9000);
    defer gpa.free(big);
    var i: usize = 0;
    while (i < 9000) : (i += 3) {
        big[i] = 0xE4;
        big[i + 1] = 0xB8;
        big[i + 2] = 0xAD;
    }

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = big },
    };
    _ = try summarizeSession(arena.allocator(), gpa, stub.completer(), testSession(&messages), null, .{ .max_chars_per_message = 2000 });

    const sent = stub.last_user_text[0..stub.last_user_len];
    // Verify the result is valid UTF-8
    try std.testing.expect(std.unicode.utf8ValidateSlice(sent) == true);
    // Verify the truncation marker is present
    try std.testing.expect(std.mem.indexOf(u8, sent, "…[截断]…") != null);
}

test "memory_digest_digest: all-meta transcript is a no-op, zero LLM calls" {
    var stub = StubCompleter{ .responses = &.{"unused"} };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = "ignored", .kind = .meta },
        .{ .role = .assistant, .content = "", .kind = .meta },
    };
    const result = try summarizeSession(arena.allocator(), std.testing.allocator, stub.completer(), testSession(&messages), "old summary", .{});

    try std.testing.expectEqual(@as(usize, 0), stub.calls);
    try std.testing.expectEqualStrings("old summary", result.summary);
    try std.testing.expectEqual(@as(usize, 0), result.topics.len);
    try std.testing.expectEqualStrings("unknown", result.outcome);
    try std.testing.expectEqual(@as(usize, 0), result.artifacts.len);
}

test "memory_digest_digest: out-of-enum outcome is clamped to unknown" {
    var stub = StubCompleter{ .responses = &.{
        \\{"summary":"s","topics":[],"outcome":"done","artifacts":[]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var messages = [_]ai_types.TranscriptMessage{
        .{ .role = .user, .content = "hi" },
    };
    const result = try summarizeSession(arena.allocator(), std.testing.allocator, stub.completer(), testSession(&messages), null, .{});
    try std.testing.expectEqualStrings("unknown", result.outcome);
}

test "memory_digest_digest: reduceDay clamps out-of-enum event type to progress" {
    var stub = StubCompleter{ .responses = &.{
        \\{"projects":[{"slug":"phantty","summary":"s","session_refs":[]}],
        \\"highlights":[],"timeline":[{"slug":"phantty","summary":"t","events":[{"type":"bogus","text":"x","refs":[]}]}]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sessions = [_]store.DailySession{testDailySession("phantty", "s1", "t1", "sum1", "completed")};
    const result = try reduceDay(arena.allocator(), std.testing.allocator, stub.completer(), "2026-07-07", &sessions);

    try std.testing.expectEqual(@as(usize, 1), result.timelines[0].entry.events.len);
    try std.testing.expectEqualStrings("progress", result.timelines[0].entry.events[0].type);
}

// ---- Reduce stage tests ----

fn testDailySession(project: []const u8, session_id: []const u8, title: []const u8, summary: []const u8, outcome: []const u8) store.DailySession {
    return .{
        .provider = "claude",
        .source_id = "local",
        .session_id = session_id,
        .project = project,
        .title = title,
        .message_count_new = 1,
        .summary = summary,
        .outcome = outcome,
    };
}

test "memory_digest_digest: reduceDay parses projects, highlights and timelines" {
    var stub = StubCompleter{ .responses = &.{
        \\{"projects":[{"slug":"phantty","summary":"做了 A","session_refs":["s1","s2"]},{"slug":"other","summary":"做了 B","session_refs":["s3"]}],
        \\"highlights":["完成了 A","推进了 B"],
        \\"timeline":[{"slug":"phantty","summary":"当天进展","events":[{"type":"progress","text":"实现功能","refs":["s1"]}]},
        \\{"slug":"other","summary":"另一天","events":[]}]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sessions = [_]store.DailySession{
        testDailySession("phantty", "s1", "t1", "sum1", "completed"),
        testDailySession("phantty", "s2", "t2", "sum2", "completed"),
        testDailySession("other", "s3", "t3", "sum3", "in_progress"),
    };

    const result = try reduceDay(arena.allocator(), std.testing.allocator, stub.completer(), "2026-07-07", &sessions);

    try std.testing.expectEqual(@as(usize, 1), stub.calls);

    try std.testing.expectEqual(@as(usize, 2), result.projects.len);
    try std.testing.expectEqualStrings("phantty", result.projects[0].slug);
    try std.testing.expectEqualStrings("做了 A", result.projects[0].summary);
    try std.testing.expectEqual(@as(usize, 2), result.projects[0].session_refs.len);
    try std.testing.expectEqualStrings("s1", result.projects[0].session_refs[0]);
    try std.testing.expectEqualStrings("other", result.projects[1].slug);

    try std.testing.expectEqual(@as(usize, 2), result.highlights.len);
    try std.testing.expectEqualStrings("完成了 A", result.highlights[0]);

    try std.testing.expectEqual(@as(usize, 2), result.timelines.len);
    try std.testing.expectEqualStrings("phantty", result.timelines[0].slug);
    try std.testing.expectEqualStrings("2026-07-07", result.timelines[0].entry.date);
    try std.testing.expectEqualStrings("当天进展", result.timelines[0].entry.summary);
    try std.testing.expectEqual(@as(usize, 1), result.timelines[0].entry.events.len);
    try std.testing.expectEqualStrings("progress", result.timelines[0].entry.events[0].type);
    try std.testing.expectEqualStrings("实现功能", result.timelines[0].entry.events[0].text);
}

test "memory_digest_digest: reduceDay buckets over 50 sessions by project and synthesizes highlights" {
    var stub = StubCompleter{ .responses = &.{
        \\{"projects":[{"slug":"proj-a","summary":"a 项目总结","session_refs":[]}],
        \\"highlights":[],"timeline":[{"slug":"proj-a","summary":"a 时间线","events":[]}]}
        ,
        \\{"projects":[{"slug":"proj-b","summary":"b 项目总结","session_refs":[]}],
        \\"highlights":[],"timeline":[{"slug":"proj-b","summary":"b 时间线","events":[]}]}
        ,
        \\{"highlights":["整体亮点"]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = std.testing.allocator;

    var sessions = try gpa.alloc(store.DailySession, 60);
    defer gpa.free(sessions);
    var slug_bufs: [60][16]u8 = undefined;
    var id_bufs: [60][16]u8 = undefined;
    for (0..60) |i| {
        const project = if (i < 30) "proj-a" else "proj-b";
        const slug = try std.fmt.bufPrint(&slug_bufs[i], "{s}", .{project});
        const id = try std.fmt.bufPrint(&id_bufs[i], "s{d}", .{i});
        sessions[i] = testDailySession(slug, id, "t", "sum", "completed");
    }

    const result = try reduceDay(arena.allocator(), gpa, stub.completer(), "2026-07-07", sessions);

    try std.testing.expect(stub.calls >= 3);
    try std.testing.expectEqual(@as(usize, 2), result.timelines.len);

    var seen_a = false;
    var seen_b = false;
    for (result.timelines) |tl| {
        if (std.mem.eql(u8, tl.slug, "proj-a")) seen_a = true;
        if (std.mem.eql(u8, tl.slug, "proj-b")) seen_b = true;
    }
    try std.testing.expect(seen_a);
    try std.testing.expect(seen_b);

    try std.testing.expectEqual(@as(usize, 1), result.highlights.len);
    try std.testing.expectEqualStrings("整体亮点", result.highlights[0]);
}

test "memory_digest_digest: reduceDay retries once on parse failure then succeeds" {
    var stub = StubCompleter{ .responses = &.{
        "not json",
        \\{"projects":[{"slug":"phantty","summary":"s","session_refs":[]}],"highlights":[],"timeline":[]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sessions = [_]store.DailySession{testDailySession("phantty", "s1", "t", "sum", "completed")};
    const result = try reduceDay(arena.allocator(), std.testing.allocator, stub.completer(), "2026-07-07", &sessions);

    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqual(@as(usize, 1), result.projects.len);
}

test "memory_digest_digest: reduceDay fails ReduceFailed after second bad response" {
    var stub = StubCompleter{ .responses = &.{ "garbage one", "garbage two" } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sessions = [_]store.DailySession{testDailySession("phantty", "s1", "t", "sum", "completed")};
    const result = reduceDay(arena.allocator(), std.testing.allocator, stub.completer(), "2026-07-07", &sessions);

    try std.testing.expectError(error.ReduceFailed, result);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "memory_digest_digest: reduceDay backfills session_refs when the LLM omits them" {
    var stub = StubCompleter{ .responses = &.{
        \\{"projects":[{"slug":"phantty","summary":"s"}],"highlights":[],"timeline":[{"slug":"phantty","summary":"t","events":[]}]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sessions = [_]store.DailySession{
        testDailySession("phantty", "s1", "t1", "sum1", "completed"),
        testDailySession("phantty", "s2", "t2", "sum2", "completed"),
    };
    const result = try reduceDay(arena.allocator(), std.testing.allocator, stub.completer(), "2026-07-07", &sessions);

    try std.testing.expectEqual(@as(usize, 1), result.projects.len);
    try std.testing.expectEqual(@as(usize, 2), result.projects[0].session_refs.len);
    try std.testing.expectEqualStrings("s1", result.projects[0].session_refs[0]);
    try std.testing.expectEqualStrings("s2", result.projects[0].session_refs[1]);

    try std.testing.expectEqual(@as(usize, 1), result.timelines.len);
    try std.testing.expectEqual(@as(usize, 2), result.timelines[0].entry.session_refs.len);
    try std.testing.expectEqualStrings("s1", result.timelines[0].entry.session_refs[0]);
}

test "memory_digest_digest: reduceDay filters hallucinated session_refs down to real session ids" {
    var stub = StubCompleter{ .responses = &.{
        \\{"projects":[{"slug":"phantty","summary":"s","session_refs":["s1","做了 A 功能","s2"]}],
        \\"highlights":[],"timeline":[]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sessions = [_]store.DailySession{
        testDailySession("phantty", "s1", "t1", "sum1", "completed"),
        testDailySession("phantty", "s2", "t2", "sum2", "completed"),
    };
    const result = try reduceDay(arena.allocator(), std.testing.allocator, stub.completer(), "2026-07-07", &sessions);

    try std.testing.expectEqual(@as(usize, 1), result.projects.len);
    try std.testing.expectEqual(@as(usize, 2), result.projects[0].session_refs.len);
    try std.testing.expectEqualStrings("s1", result.projects[0].session_refs[0]);
    try std.testing.expectEqualStrings("s2", result.projects[0].session_refs[1]);
}

test "memory_digest_digest: reduceDay drops all-illegal session_refs to an empty array without error" {
    var stub = StubCompleter{ .responses = &.{
        \\{"projects":[{"slug":"phantty","summary":"s","session_refs":["标题一","不存在的id"]}],
        \\"highlights":[],"timeline":[]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sessions = [_]store.DailySession{testDailySession("phantty", "s1", "t1", "sum1", "completed")};
    const result = try reduceDay(arena.allocator(), std.testing.allocator, stub.completer(), "2026-07-07", &sessions);

    try std.testing.expectEqual(@as(usize, 1), result.projects.len);
    try std.testing.expectEqual(@as(usize, 0), result.projects[0].session_refs.len);
}

test "memory_digest_digest: reduceDay leaves events[].refs untouched (pr/commit/file refs are not session ids)" {
    var stub = StubCompleter{ .responses = &.{
        \\{"projects":[{"slug":"phantty","summary":"s","session_refs":[]}],
        \\"highlights":[],"timeline":[{"slug":"phantty","summary":"t","events":[{"type":"progress","text":"x","refs":["#123","abc1234"]}]}]}
    } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sessions = [_]store.DailySession{testDailySession("phantty", "s1", "t1", "sum1", "completed")};
    const result = try reduceDay(arena.allocator(), std.testing.allocator, stub.completer(), "2026-07-07", &sessions);

    try std.testing.expectEqual(@as(usize, 2), result.timelines[0].entry.events[0].refs.len);
    try std.testing.expectEqualStrings("#123", result.timelines[0].entry.events[0].refs[0]);
    try std.testing.expectEqualStrings("abc1234", result.timelines[0].entry.events[0].refs[1]);
}
