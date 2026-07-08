//! One digest run (M1, spec §15): collect local sessions, bucket by local
//! day, write daily listings + index, then persist cursors. The cursor file
//! only advances after artifacts were written successfully (spec §6).
//! Task 7 adds the LLM map/reduce stage (spec §8/§9/§13) when
//! `Options.completer` is set; with it null the M1 raw-listing path is
//! unchanged.
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");
const collector = @import("collector.zig");
const cursors_mod = @import("cursors.zig");
const digest = @import("digest.zig");
const dirs = @import("../platform/dirs.zig");
const llm = @import("llm.zig");
const protocol = @import("../assistant/conversation/protocol.zig");
const remote = @import("remote.zig");
const store = @import("store.zig");
const types = @import("types.zig");

/// One WSL/SSH remote source to collect from alongside local roots (spec §6,
/// M3). `source_id` becomes CollectedSession.source_id and thus flows into
/// cursors, summaryKey and daily/aliases.
pub const RemoteSource = struct {
    source_id: []const u8,
    host: remote.ExecHost,
};

pub const Options = struct {
    roots: collector.LocalRoots,
    memory_root: []const u8,
    now_ms: i64,
    tz_offset_seconds: i32 = 0,
    /// 0 = unlimited (tests); default 7 per spec §6/§12.
    backfill_days: u32 = 7,
    /// null = M1 raw-listing path (no LLM calls); set = map+reduce every
    /// session/day through this completer (spec §8/§9).
    completer: ?llm.Completer = null,
    model_label: []const u8 = "",
    max_chars_per_message: usize = 2000,
    /// Points at the llm.Client's running total_usage (spec M5 Task 1 B.3),
    /// read into the RunRecord written at the end of this run. null (stub
    /// completers, M1 raw path, tests) records zero usage.
    llm_usage: ?*const protocol.ApiUsage = null,
    /// WSL/SSH sources to collect from in addition to local roots (spec §6,
    /// M3). Empty by default — M1/M2 behavior is local-only.
    remote_sources: []const RemoteSource = &.{},
    progress_sink: ?ProgressSink = null,
};

pub const Progress = union(enum) {
    scanning,
    summarizing: struct {
        total: usize,
        completed: usize,
        failed: usize,
        detail: []const u8 = "",
    },
    finalizing,
};

pub const ProgressSink = struct {
    ctx: *anyopaque,
    onProgressFn: *const fn (*anyopaque, Progress) void,

    pub fn notify(self: ProgressSink, progress: Progress) void {
        self.onProgressFn(self.ctx, progress);
    }
};

pub const Summary = struct {
    sessions_collected: usize = 0,
    days_written: usize = 0,
    sessions_summarized: usize = 0,
    sessions_failed: usize = 0,
    llm_calls: usize = 0,
};

/// Wraps an `llm.Completer` to count calls for run observability
/// (store.RunRecord.llm_calls). runOnce is single-threaded, so a plain
/// counter is enough — no atomics needed.
const CountingCompleter = struct {
    inner: llm.Completer,
    count: usize = 0,

    fn completer(self: *CountingCompleter) llm.Completer {
        return .{ .ctx = self, .completeFn = complete };
    }

    fn complete(ctx: *anyopaque, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8 {
        const self: *CountingCompleter = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.inner.complete(gpa, system_prompt, user_text);
    }
};

/// Owning bundle for `defaultLocalRoots`'s three gpa-allocated paths, freed
/// together via `deinit`.
pub const OwnedLocalRoots = struct {
    claude_projects_dir: []const u8,
    codex_sessions_dir: []const u8,
    wispterm_sessions_dir: []const u8,

    pub fn roots(self: *const OwnedLocalRoots) collector.LocalRoots {
        return .{
            .claude_projects_dir = self.claude_projects_dir,
            .codex_sessions_dir = self.codex_sessions_dir,
            .wispterm_sessions_dir = self.wispterm_sessions_dir,
        };
    }

    pub fn deinit(self: *const OwnedLocalRoots, gpa: std.mem.Allocator) void {
        gpa.free(self.claude_projects_dir);
        gpa.free(self.codex_sessions_dir);
        gpa.free(self.wispterm_sessions_dir);
    }
};

/// Assembles the three real local session roots (Claude/.claude/projects,
/// Codex/.codex/sessions, WispTerm's own agent-history/sessions), matching
/// scan_main.zig's dev-CLI wiring exactly so both entry points scan the same
/// on-disk sources. Shared here so the scheduler doesn't drift from the CLI's
/// root assembly.
pub fn defaultLocalRoots(gpa: std.mem.Allocator) !OwnedLocalRoots {
    const home = try dirs.homeDir(gpa);
    defer gpa.free(home);

    const claude_dir = try std.fs.path.join(gpa, &.{ home, ".claude", "projects" });
    errdefer gpa.free(claude_dir);
    const codex_dir = try std.fs.path.join(gpa, &.{ home, ".codex", "sessions" });
    errdefer gpa.free(codex_dir);
    const agent_history_dir = try dirs.agentHistoryDir(gpa);
    defer gpa.free(agent_history_dir);
    const wispterm_dir = try std.fs.path.join(gpa, &.{ agent_history_dir, "sessions" });
    errdefer gpa.free(wispterm_dir);

    return .{
        .claude_projects_dir = claude_dir,
        .codex_sessions_dir = codex_dir,
        .wispterm_sessions_dir = wispterm_dir,
    };
}

/// Appends a RunRecord for this run (spec M3 Task 1/3), with real per-source
/// status in `sources`. A write failure here must never change runOnce's own
/// result, so it's logged and swallowed.
fn recordRun(
    gpa: std.mem.Allocator,
    memory_root: []const u8,
    started_at: i64,
    status: []const u8,
    sources: []const store.SourceStatus,
    sessions_summarized: usize,
    sessions_failed: usize,
    llm_calls: usize,
    llm_usage: ?*const protocol.ApiUsage,
) void {
    const usage = if (llm_usage) |u| u.* else protocol.ApiUsage{};
    const rec: store.RunRecord = .{
        .started_at = started_at,
        .finished_at = std.time.milliTimestamp(),
        .status = status,
        .sources = sources,
        .sessions_summarized = @intCast(sessions_summarized),
        .sessions_failed = @intCast(sessions_failed),
        .llm_calls = @intCast(llm_calls),
        .prompt_tokens = usage.prompt_tokens,
        .completion_tokens = usage.completion_tokens,
        .total_tokens = usage.total_tokens,
    };
    store.appendRunRecord(gpa, memory_root, rec) catch |err| {
        std.log.warn("memory_digest: appendRunRecord failed: {s}", .{@errorName(err)});
    };
}

/// Collects local sessions plus every configured remote source into `out`,
/// building a SourceStatus per source (spec §13: one source's failure must
/// not abort the others). `out`'s slices are allocated from `arena`, which
/// must outlive `out` (mirrors collector.collectLocal's own arena-ownership
/// contract) — the local collector's own Result.arena is only a scratch
/// allocator here, appended into `arena` via a copy of the CollectedSession
/// values themselves (their string/slice fields still point into
/// `local.arena`, so `local` is returned for the caller to keep alive
/// alongside `arena`, not deinited here).
fn collectAllSources(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
    out: *std.ArrayListUnmanaged(types.CollectedSession),
    cur: *cursors_mod.Set,
    min_mtime_ns: i128,
) !struct { local: collector.Result, sources: []const store.SourceStatus } {
    var sources: std.ArrayListUnmanaged(store.SourceStatus) = .empty;

    const local = try collector.collectLocal(gpa, opts.roots, cur, min_mtime_ns);
    try out.appendSlice(arena, local.sessions);
    try sources.append(arena, .{
        .source_id = "local",
        .status = "ok",
        .sessions_collected = @intCast(local.sessions.len),
    });

    for (opts.remote_sources) |rs| {
        const before = out.items.len;
        if (remote.collectRemote(gpa, arena, out, rs.source_id, rs.host, cur, min_mtime_ns, .{})) |r| {
            const detail = if (r.oversize_skipped > 0)
                try std.fmt.allocPrint(arena, "oversize_skipped={d}", .{r.oversize_skipped})
            else
                "";
            try sources.append(arena, .{
                .source_id = rs.source_id,
                .status = "ok",
                .detail = detail,
                .sessions_collected = r.count,
            });
        } else |err| {
            std.log.warn("memory_digest: source '{s}' failed: {s}", .{ rs.source_id, @errorName(err) });
            try sources.append(arena, .{
                .source_id = rs.source_id,
                .status = "failed",
                .detail = @errorName(err),
                .sessions_collected = @intCast(out.items.len - before),
            });
        }
    }

    return .{ .local = local, .sources = sources.items };
}

fn anySourceFailed(sources: []const store.SourceStatus) bool {
    for (sources) |s| {
        if (std.mem.eql(u8, s.status, "failed")) return true;
    }
    return false;
}

pub fn runOnce(gpa: std.mem.Allocator, opts: Options) !Summary {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const started_at = opts.now_ms;

    const state_dir = try std.fs.path.join(arena, &.{ opts.memory_root, "state" });
    try std.fs.cwd().makePath(state_dir);
    const cursors_path = try std.fs.path.join(arena, &.{ state_dir, "cursors.json" });

    var cur = try cursors_mod.Set.loadFromPath(gpa, cursors_path);
    defer cur.deinit();

    const min_mtime_ns: i128 = if (opts.backfill_days == 0)
        0
    else
        @as(i128, opts.now_ms) * 1_000_000 - @as(i128, opts.backfill_days) * 86_400_000_000_000;

    if (opts.progress_sink) |sink| sink.notify(.scanning);

    var collected_sessions: std.ArrayListUnmanaged(types.CollectedSession) = .empty;
    var collect_result = try collectAllSources(gpa, arena, opts, &collected_sessions, &cur, min_mtime_ns);
    defer collect_result.local.deinit();
    const sources = collect_result.sources;
    const overall_status: []const u8 = if (anySourceFailed(sources)) "partial" else "ok";

    if (opts.completer) |completer| {
        var counting: CountingCompleter = .{ .inner = completer };
        if (runOnceWithLlm(gpa, arena, opts, counting.completer(), collected_sessions.items, &cur, cursors_path)) |summary| {
            recordRun(gpa, opts.memory_root, started_at, overall_status, sources, summary.sessions_summarized, summary.sessions_failed, counting.count, opts.llm_usage);
            var s = summary;
            s.llm_calls = counting.count;
            return s;
        } else |err| {
            recordRun(gpa, opts.memory_root, started_at, "failed", sources, 0, 0, counting.count, opts.llm_usage);
            return err;
        }
    }

    if (opts.progress_sink) |sink| sink.notify(.finalizing);

    // M1: cursor advancement is unconditional here (equivalent to the old
    // emit()-time advancement) — a real artifact-write failure below still
    // returns an error before saveToPath, so the cursor file itself never
    // moves.
    for (collected_sessions.items) |s| {
        try advanceCursor(&cur, s);
    }

    // Bucket sessions by the local day of their last new activity.
    // ponytail: whole-session bucketing; per-message day slicing is an M2
    // concern together with the LLM stage (spec §11).
    var day_keys: std.ArrayListUnmanaged(u32) = .empty;
    for (collected_sessions.items) |s| {
        const key = ai_types.dateKeyFromMs(lastActivityMs(s, opts.now_ms), opts.tz_offset_seconds);
        if (std.mem.indexOfScalar(u32, day_keys.items, key) == null) {
            try day_keys.append(arena, key);
        }
    }

    for (day_keys.items) |key| {
        var entries: std.ArrayListUnmanaged(store.DailySession) = .empty;
        for (collected_sessions.items) |s| {
            if (ai_types.dateKeyFromMs(lastActivityMs(s, opts.now_ms), opts.tz_offset_seconds) != key) continue;
            var slug_buf: [64]u8 = undefined;
            try entries.append(arena, .{
                .provider = @tagName(s.provider),
                .source_id = s.source_id,
                .session_id = s.session_id,
                .project = try arena.dupe(u8, types.projectSlug(s.project_path, &slug_buf)),
                .title = s.title,
                .message_count_new = @intCast(s.new_messages.len),
            });
        }
        var date_buf: [10]u8 = undefined;
        const date = store.formatDate(key, &date_buf);
        const merged = try mergeDailyWithExisting(arena, opts.memory_root, date, entries.items);
        try store.writeDaily(gpa, opts.memory_root, .{
            .date = date,
            .generated_at = opts.now_ms,
            .sessions = merged,
        });
    }

    try writeIndexFromDisk(gpa, arena, opts.memory_root, opts.now_ms);
    try cur.saveToPath(gpa, cursors_path);

    recordRun(gpa, opts.memory_root, started_at, overall_status, sources, 0, 0, 0, opts.llm_usage);
    return .{
        .sessions_collected = collected_sessions.items.len,
        .days_written = day_keys.items.len,
    };
}

/// Builds the "{source_id}|{provider}:{session_id}" key SummaryStore uses
/// (spec M3 Task 3) — the `|` separator can't appear in a source_id (source
/// ids are "local", "wsl:<distro>" or "ssh:<profile>", never containing it).
fn summaryKey(arena: std.mem.Allocator, source_id: []const u8, provider: types.DigestProvider, session_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}|{s}:{s}", .{ source_id, @tagName(provider), session_id });
}

/// Pre-M3 key shape, kept only as a one-cycle migration fallback for local
/// sessions (see findOldSummary below). Delete once every local summary has
/// been rewritten under the new key (one run cycle after M3 ships).
fn legacySummaryKey(arena: std.mem.Allocator, provider: types.DigestProvider, session_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}:{s}", .{ @tagName(provider), session_id });
}

/// Looks up the old summary for a session under the new key, falling back to
/// the pre-M3 "provider:session_id" key for local sessions only (remote
/// sessions never had summaries under the old scheme, so no fallback there).
/// ponytail: migration bridge — delete the fallback branch one run cycle
/// after M3 ships, once every local summary has been rewritten under the new
/// key.
fn findOldSummary(arena: std.mem.Allocator, summaries: *store.SummaryStore, source_id: []const u8, provider: types.DigestProvider, session_id: []const u8, new_key: []const u8) !?[]const u8 {
    if (summaries.find(new_key)) |rec| return rec.summary;
    if (std.mem.eql(u8, source_id, "local")) {
        const legacy_key = try legacySummaryKey(arena, provider, session_id);
        if (summaries.find(legacy_key)) |rec| return rec.summary;
    }
    return null;
}

/// Map+reduce path (spec §8/§9/§13): summarize each collected session (only
/// advancing its cursor and entering it into the daily listing on success),
/// save the summary store immediately, then reduce each active day's full
/// merged session list into projects/highlights/timeline and write those
/// back. The cursor file is saved last, after every reduce succeeds.
fn runOnceWithLlm(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
    completer: llm.Completer,
    collected: []const types.CollectedSession,
    cur: *cursors_mod.Set,
    cursors_path: []const u8,
) !Summary {
    const state_dir = try std.fs.path.join(arena, &.{ opts.memory_root, "state" });
    const summaries_path = try std.fs.path.join(arena, &.{ state_dir, "session_summaries.json" });

    var summaries = try store.SummaryStore.loadFromPath(gpa, summaries_path);
    defer summaries.deinit();

    const map_opts = digest.MapOptions{ .max_chars_per_message = opts.max_chars_per_message };

    // Per-session map stage. Only sessions that summarize successfully
    // advance their cursor and get a daily entry; the rest are silently
    // retried on the next run (spec §13). `summarized_dates`/`summarized_paths`/
    // `summarized_source_ids` track each entry's day bucket, project_path and
    // source_id in lockstep with `summarized` (store.DailySession has no room
    // for any of them).
    var summarized: std.ArrayListUnmanaged(store.DailySession) = .empty;
    var summarized_dates: std.ArrayListUnmanaged([]const u8) = .empty;
    var summarized_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var summarized_source_ids: std.ArrayListUnmanaged([]const u8) = .empty;
    var sessions_summarized: usize = 0;
    var sessions_failed: usize = 0;

    if (opts.progress_sink) |sink| {
        sink.notify(.{ .summarizing = .{
            .total = collected.len,
            .completed = 0,
            .failed = 0,
        } });
    }

    for (collected, 0..) |s, i| {
        const progress_detail = if (opts.progress_sink != null)
            try std.fmt.allocPrint(arena, "{d}/{d} {s}/{s}:{s}", .{
                i + 1,
                collected.len,
                s.source_id,
                @tagName(s.provider),
                s.session_id,
            })
        else
            "";
        if (opts.progress_sink) |sink| {
            std.log.warn("memory_digest: summarizing {s} file={s} messages={d}", .{ progress_detail, s.source_file, s.new_messages.len });
            sink.notify(.{ .summarizing = .{
                .total = collected.len,
                .completed = sessions_summarized,
                .failed = sessions_failed,
                .detail = progress_detail,
            } });
        }

        const key = try summaryKey(arena, s.source_id, s.provider, s.session_id);
        const old_summary = try findOldSummary(arena, &summaries, s.source_id, s.provider, s.session_id, key);

        const result = digest.summarizeSession(arena, gpa, completer, s, old_summary, map_opts) catch |err| {
            std.log.warn("memory_digest: map failed for {s} ({s}): {s}", .{ @tagName(s.provider), s.session_id, @errorName(err) });
            sessions_failed += 1;
            if (opts.progress_sink) |sink| {
                sink.notify(.{ .summarizing = .{
                    .total = collected.len,
                    .completed = sessions_summarized,
                    .failed = sessions_failed,
                    .detail = progress_detail,
                } });
            }
            continue;
        };

        try advanceCursor(cur, s);
        sessions_summarized += 1;
        if (opts.progress_sink) |sink| {
            sink.notify(.{ .summarizing = .{
                .total = collected.len,
                .completed = sessions_summarized,
                .failed = sessions_failed,
                .detail = progress_detail,
            } });
        }

        const date_key = ai_types.dateKeyFromMs(lastActivityMs(s, opts.now_ms), opts.tz_offset_seconds);
        var date_buf: [10]u8 = undefined;
        const date = try arena.dupe(u8, store.formatDate(date_key, &date_buf));

        try summaries.put(.{
            .key = key,
            .date = date,
            .summary = result.summary,
            .topics = result.topics,
            .outcome = result.outcome,
            .artifacts = result.artifacts,
        });

        var slug_buf: [64]u8 = undefined;
        try summarized.append(arena, .{
            .provider = @tagName(s.provider),
            .source_id = s.source_id,
            .session_id = s.session_id,
            .project = try arena.dupe(u8, types.projectSlug(s.project_path, &slug_buf)),
            .title = s.title,
            .message_count_new = @intCast(s.new_messages.len),
            .summary = result.summary,
            .topics = result.topics,
            .outcome = result.outcome,
            .artifacts = result.artifacts,
        });
        try summarized_dates.append(arena, date);
        try summarized_paths.append(arena, s.project_path);
        try summarized_source_ids.append(arena, s.source_id);
    }

    // Map results are persisted before reduce runs at all (spec §13): a
    // reduce failure below must not lose already-summarized sessions.
    try summaries.saveToPath(gpa, summaries_path);
    if (opts.progress_sink) |sink| sink.notify(.finalizing);

    // Bucket only the successfully-summarized sessions by day; a session
    // that failed map stays out of every daily/reduce artifact this run
    // (spec §13) and is retried next time since its cursor did not move.
    var day_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    for (summarized_dates.items) |date| {
        const already = for (day_keys.items) |d| {
            if (std.mem.eql(u8, d, date)) break true;
        } else false;
        if (!already) try day_keys.append(arena, date);
    }

    // Phase 1: merge + reduce every day WITHOUT writing anything. A reduce
    // failure on any single day must not leave an earlier day's daily file
    // written with no matching cursor advance — a rerun would then re-merge
    // that day and double-count message_count_new (spec §13 must be atomic
    // across the whole multi-day run, not just within one day).
    const DayResult = struct {
        date: []const u8,
        merged: []const store.DailySession,
        reduced: digest.ReduceResult,
    };
    var day_results: std.ArrayListUnmanaged(DayResult) = .empty;
    for (day_keys.items) |date| {
        var entries: std.ArrayListUnmanaged(store.DailySession) = .empty;
        for (summarized.items, 0..) |s, i| {
            if (std.mem.eql(u8, summarized_dates.items[i], date)) try entries.append(arena, s);
        }

        const merged = try mergeDailyWithExisting(arena, opts.memory_root, date, entries.items);

        const reduced = digest.reduceDay(arena, gpa, completer, date, merged) catch {
            return error.ReduceFailed;
        };

        try day_results.append(arena, .{ .date = date, .merged = merged, .reduced = reduced });
    }

    // Phase 2: every reduce succeeded — now write dailies, timeline/project
    // upserts, index, and finally cursors.
    for (day_results.items) |dr| {
        try store.writeDaily(gpa, opts.memory_root, .{
            .date = dr.date,
            .generated_at = opts.now_ms,
            .sessions = dr.merged,
            .model = opts.model_label,
            .projects = dr.reduced.projects,
            .highlights = dr.reduced.highlights,
        });

        // Slug allowlist (Item 1): transcripts are untrusted, and `tl.slug`
        // comes from the LLM's parsed reduce output. Only slugs that this
        // day's own merged sessions actually produced (via
        // types.projectSlug) are legal path components; anything else
        // (e.g. prompt-injected "../../.." or "") is dropped rather than
        // path-joined into `projects/<slug>/`.
        for (dr.reduced.timelines) |tl| {
            const known = for (dr.merged) |s| {
                if (std.mem.eql(u8, s.project, tl.slug)) break true;
            } else false;
            if (!known) {
                std.log.warn("memory-digest: dropping timeline for unknown slug '{s}'", .{tl.slug});
                continue;
            }
            try store.upsertTimelineEntry(gpa, opts.memory_root, tl.slug, tl.entry);

            // Minor#7: walk every summarized session under this slug (not
            // just the first match) so a day mixing local and remote
            // sessions of the same project records both a local `paths[]`
            // entry and a remote alias, instead of only whichever source
            // happened to appear first. upsertProject/upsertProjectAlias
            // already dedupe within their own list.
            for (summarized.items, 0..) |sm, i| {
                if (!std.mem.eql(u8, sm.project, tl.slug)) continue;
                const project_path = summarized_paths.items[i];
                const source_id = summarized_source_ids.items[i];
                if (std.mem.eql(u8, source_id, "local")) {
                    try store.upsertProject(gpa, opts.memory_root, tl.slug, project_path, dr.date);
                } else {
                    // Remote sessions (spec M3 Task 3): the raw project_path is a
                    // remote-host path with no meaning on this machine, so it is
                    // recorded as an alias ("{source_id}:{project_path}") instead
                    // of a local `paths[]` entry.
                    const alias = try std.fmt.allocPrint(arena, "{s}:{s}", .{ source_id, project_path });
                    try store.upsertProjectAlias(gpa, opts.memory_root, tl.slug, alias, dr.date);
                }
            }
        }
    }

    try writeIndexFromDisk(gpa, arena, opts.memory_root, opts.now_ms);
    try cur.saveToPath(gpa, cursors_path);

    return .{
        .sessions_collected = collected.len,
        .days_written = day_keys.items.len,
        .sessions_summarized = sessions_summarized,
        .sessions_failed = sessions_failed,
    };
}

/// Merge this run's new-session entries for a day with whatever is already
/// on disk for that date, so a same-day rerun never wipes an earlier run's
/// entries (spec §9: daily files are cumulative for the day, not per-run).
/// Same (provider, source_id, session_id) → sum message_count_new, keep the
/// new title/project; old-only entries are kept; new-only entries appended.
fn mergeDailyWithExisting(
    arena: std.mem.Allocator,
    memory_root: []const u8,
    date: []const u8,
    new_entries: []const store.DailySession,
) ![]const store.DailySession {
    const ExistingShape = struct {
        provider: []const u8 = "",
        source_id: []const u8 = "",
        session_id: []const u8 = "",
        project: []const u8 = "",
        title: []const u8 = "",
        message_count_new: u32 = 0,
        summary: []const u8 = "",
        topics: []const []const u8 = &.{},
        outcome: []const u8 = "unknown",
        artifacts: []const store.Artifact = &.{},
    };
    const DailyShape = struct { sessions: []const ExistingShape = &.{} };

    var existing: []const ExistingShape = &.{};
    const dir_path = try std.fs.path.join(arena, &.{ memory_root, "daily" });
    if (std.fs.cwd().openDir(dir_path, .{})) |d| {
        var dir = d;
        defer dir.close();
        const name = try std.fmt.allocPrint(arena, "{s}.json", .{date});
        if (dir.readFileAlloc(arena, name, 16 * 1024 * 1024)) |bytes| {
            if (std.json.parseFromSlice(DailyShape, arena, bytes, .{
                .ignore_unknown_fields = true,
            })) |parsed| {
                existing = parsed.value.sessions; // arena-owned; no deinit needed
            } else |_| {}
        } else |_| {}
    } else |_| {}

    var merged: std.ArrayListUnmanaged(store.DailySession) = .empty;
    var used = try arena.alloc(bool, new_entries.len);
    @memset(used, false);

    for (existing) |old| {
        const match_idx: ?usize = for (new_entries, 0..) |n, i| {
            if (!used[i] and std.mem.eql(u8, n.provider, old.provider) and
                std.mem.eql(u8, n.source_id, old.source_id) and
                std.mem.eql(u8, n.session_id, old.session_id)) break i;
        } else null;
        if (match_idx) |i| {
            used[i] = true;
            const n = new_entries[i];
            // A rerun that skipped this session (map failure, or the M1
            // no-LLM path) sends an empty summary; keep the prior one rather
            // than clobbering it (spec §13 map results are cumulative too).
            const keep_old_summary = n.summary.len == 0;
            try merged.append(arena, .{
                .provider = n.provider,
                .source_id = n.source_id,
                .session_id = n.session_id,
                .project = n.project,
                .title = n.title,
                .message_count_new = old.message_count_new + n.message_count_new,
                .summary = if (keep_old_summary) old.summary else n.summary,
                .topics = if (keep_old_summary) old.topics else n.topics,
                .outcome = if (keep_old_summary) old.outcome else n.outcome,
                .artifacts = if (keep_old_summary) old.artifacts else n.artifacts,
            });
        } else {
            try merged.append(arena, .{
                .provider = old.provider,
                .source_id = old.source_id,
                .session_id = old.session_id,
                .project = old.project,
                .title = old.title,
                .message_count_new = old.message_count_new,
                .summary = old.summary,
                .topics = old.topics,
                .outcome = old.outcome,
                .artifacts = old.artifacts,
            });
        }
    }
    for (new_entries, 0..) |n, i| {
        if (!used[i]) try merged.append(arena, n);
    }
    return merged.items;
}

fn advanceCursor(cur: *cursors_mod.Set, s: types.CollectedSession) !void {
    try cur.update(s.source_id, s.provider, s.source_file, s.file_size, s.file_mtime_ns, s.total_messages);
}

fn lastActivityMs(s: types.CollectedSession, fallback_ms: i64) i64 {
    var latest: i64 = 0;
    for (s.new_messages) |m| {
        if (m.timestamp_ms > latest) latest = m.timestamp_ms;
    }
    if (latest == 0) latest = s.ended_at_ms;
    if (latest == 0) latest = fallback_ms;
    return latest;
}

/// Rebuild index.json from the daily files on disk — idempotent by
/// construction, and cheap (daily files are small summaries).
fn writeIndexFromDisk(gpa: std.mem.Allocator, arena: std.mem.Allocator, memory_root: []const u8, now_ms: i64) !void {
    const DailySessionShape = struct { project: []const u8 = "" };
    const DailyShape = struct { sessions: []const DailySessionShape = &.{} };
    const ProjAgg = struct { slug: []const u8, last_active: []const u8, count: u32 };

    var days: std.ArrayListUnmanaged([]const u8) = .empty;
    var projects: std.ArrayListUnmanaged(ProjAgg) = .empty;

    const daily_dir_path = try std.fs.path.join(arena, &.{ memory_root, "daily" });
    var dir = std.fs.cwd().openDir(daily_dir_path, .{ .iterate = true }) catch {
        try store.writeIndex(gpa, memory_root, .{ .generated_at = now_ms, .days = &.{} });
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".json")) continue;
        const date = try arena.dupe(u8, ent.name[0 .. ent.name.len - ".json".len]);
        const bytes = dir.readFileAlloc(arena, ent.name, 16 * 1024 * 1024) catch continue;
        const parsed = std.json.parseFromSlice(DailyShape, arena, bytes, .{
            .ignore_unknown_fields = true,
        }) catch continue; // arena-owned; no deinit needed
        try days.append(arena, date);
        for (parsed.value.sessions) |s| {
            const slug = if (s.project.len == 0) types.UNASSIGNED_SLUG else s.project;
            const agg: ?*ProjAgg = for (projects.items) |*p| {
                if (std.mem.eql(u8, p.slug, slug)) break p;
            } else null;
            if (agg) |p| {
                p.count += 1;
                if (std.mem.order(u8, date, p.last_active) == .gt) p.last_active = date;
            } else {
                try projects.append(arena, .{
                    .slug = try arena.dupe(u8, slug),
                    .last_active = date,
                    .count = 1,
                });
            }
        }
    }

    // Newest day first, matching spec §9's example.
    std.mem.sort([]const u8, days.items, {}, struct {
        fn desc(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.desc);

    const idx_projects = try arena.alloc(store.IndexProject, projects.items.len);
    for (projects.items, 0..) |p, i| {
        idx_projects[i] = .{ .slug = p.slug, .name = p.slug, .last_active = p.last_active, .session_count = p.count };
    }
    try store.writeIndex(gpa, memory_root, .{
        .generated_at = now_ms,
        .days = days.items,
        .projects = idx_projects,
    });
}

const CLAUDE_JSONL =
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"Fix tests"}}
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the failure."}]}}
    \\
;

const WISPTERM_JSON =
    \\{"session_id":"session-1-1","title":"Copilot","api_key":"sk-SECRET","created_at":1782311875112,"updated_at":1782311885976,
    \\ "messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}
;

test "memory_digest_run: end to end writes daily, index and cursors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try tmp.dir.makePath("claude/proj-a");
    {
        var d = try tmp.dir.openDir("claude/proj-a", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "claude-abc.jsonl", .data = CLAUDE_JSONL });
    }
    try tmp.dir.makePath("wisp");
    {
        var d = try tmp.dir.openDir("wisp", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "session-1-1.json", .data = WISPTERM_JSON });
    }

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const wisp_root = try std.fs.path.join(allocator, &.{ root, "wisp" });
    defer allocator.free(wisp_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root, .wispterm_sessions_dir = wisp_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0, // unlimited so fixture mtimes always pass
    };

    const first = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 2), first.sessions_collected);
    try std.testing.expect(first.days_written >= 1);

    // Claude fixture messages are 2026-05-31 UTC → daily file exists.
    const daily = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-05-31.json", 1 << 20);
    defer allocator.free(daily);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"claude-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"project\": \"project\"") != null);

    const index = try tmp.dir.readFileAlloc(allocator, "memory/index.json", 1 << 20);
    defer allocator.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "\"2026-05-31\"") != null);

    const cursors = try tmp.dir.readFileAlloc(allocator, "memory/state/cursors.json", 1 << 20);
    defer allocator.free(cursors);
    try std.testing.expect(std.mem.indexOf(u8, cursors, "claude-abc.jsonl") != null);

    // Second run: nothing new, index still valid.
    const second = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 0), second.sessions_collected);
    try std.testing.expectEqual(@as(usize, 0), second.days_written);
}

test "memory_digest_run: wispterm session lands in unassigned project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try tmp.dir.makePath("wisp");
    {
        var d = try tmp.dir.openDir("wisp", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "session-1-1.json", .data = WISPTERM_JSON });
    }
    const wisp_root = try std.fs.path.join(allocator, &.{ root, "wisp" });
    defer allocator.free(wisp_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    _ = try runOnce(allocator, .{
        .roots = .{ .wispterm_sessions_dir = wisp_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .backfill_days = 0,
    });
    const index = try tmp.dir.readFileAlloc(allocator, "memory/index.json", 1 << 20);
    defer allocator.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "\"unassigned\"") != null);

    // Secrets embedded in the raw session (api_key) must never reach the
    // daily artifact. Locate the single daily file regardless of the date
    // bucketing (updated_at 1782311885976 lands on 2026-06-24 at both UTC
    // and UTC+8, but list the dir to stay robust to tz assumptions).
    var daily_dir = try tmp.dir.openDir("memory/daily", .{ .iterate = true });
    defer daily_dir.close();
    var daily_it = daily_dir.iterate();
    const daily_ent = (try daily_it.next()).?;
    const daily_bytes = try daily_dir.readFileAlloc(allocator, daily_ent.name, 1 << 20);
    defer allocator.free(daily_bytes);
    try std.testing.expect(std.mem.indexOf(u8, daily_bytes, "sk-SECRET") == null);
}

const CLAUDE_JSONL_DEF =
    \\{"sessionId":"claude-def","cwd":"/home/me/project2","timestamp":"2026-05-31T11:00:00.000Z","type":"user","message":{"role":"user","content":"Second session"}}
    \\{"sessionId":"claude-def","cwd":"/home/me/project2","timestamp":"2026-05-31T11:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]}}
    \\
;

const CLAUDE_EXTRA_LINE =
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:02:00.000Z","type":"user","message":{"role":"user","content":"And lint"}}
    \\
;

test "memory_digest_run: same-day rerun merges daily entries instead of overwriting" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try tmp.dir.makePath("claude/proj-a");
    {
        var d = try tmp.dir.openDir("claude/proj-a", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "claude-abc.jsonl", .data = CLAUDE_JSONL });
    }

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
    };

    // First run: only claude-abc, message_count_new == 2.
    _ = try runOnce(allocator, opts);
    {
        const daily = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-05-31.json", 1 << 20);
        defer allocator.free(daily);
        try std.testing.expect(std.mem.indexOf(u8, daily, "\"claude-abc\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, daily, "\"message_count_new\": 2") != null);
    }

    // Second run same day: a new session (claude-def) appears while
    // claude-abc is idle. The rerun must not wipe claude-abc's entry.
    try tmp.dir.makePath("claude/proj-b");
    {
        var d = try tmp.dir.openDir("claude/proj-b", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "claude-def.jsonl", .data = CLAUDE_JSONL_DEF });
    }
    _ = try runOnce(allocator, opts);
    {
        const daily = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-05-31.json", 1 << 20);
        defer allocator.free(daily);
        try std.testing.expect(std.mem.indexOf(u8, daily, "\"claude-abc\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, daily, "\"claude-def\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, daily, "\"message_count_new\": 2") != null);
    }

    // Third run same day: claude-abc gets a new line. Its message_count_new
    // must be the preserved 2 plus the new 1 == 3.
    {
        const appended = try std.mem.concat(allocator, u8, &.{ CLAUDE_JSONL, CLAUDE_EXTRA_LINE });
        defer allocator.free(appended);
        var d = try tmp.dir.openDir("claude/proj-a", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "claude-abc.jsonl", .data = appended });
    }
    _ = try runOnce(allocator, opts);
    {
        const daily = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-05-31.json", 1 << 20);
        defer allocator.free(daily);
        try std.testing.expect(std.mem.indexOf(u8, daily, "\"claude-def\"") != null);
        // Find claude-abc's session block and check its message_count_new is 3.
        const abc_idx = std.mem.indexOf(u8, daily, "\"claude-abc\"").?;
        const after_abc = daily[abc_idx..];
        const count_idx = std.mem.indexOf(u8, after_abc, "\"message_count_new\"").?;
        try std.testing.expect(std.mem.indexOf(u8, after_abc[count_idx .. count_idx + 30], "3") != null);
    }
}

// ---- LLM-backed runOnce tests (Task 7) ----

const REDUCE_JSON =
    \\{"projects":[{"slug":"project","summary":"完成了修复","session_refs":[]}],
    \\"highlights":["修复了测试"],
    \\"timeline":[{"slug":"project","summary":"当天进展","events":[{"type":"progress","text":"修好了失败的测试","refs":[]}]}]}
;

const MAP_JSON =
    \\{"summary":"修复了失败的测试","topics":["testing"],"outcome":"completed","artifacts":[]}
;

/// Routes map vs reduce calls by shape (map's user_text carries the
/// 【新增对话】 marker from digest.buildFinalUserText/buildRollingUserText;
/// reduce's is a compact JSON array with no such marker), and within map
/// calls routes per-session by a marker string in the transcript content so
/// one session can be made to fail deterministically while another succeeds.
const RoutingStub = struct {
    map_response: []const u8,
    reduce_response: []const u8,
    garbage_marker: []const u8 = "",
    map_calls: usize = 0,
    reduce_calls: usize = 0,

    fn completer(self: *RoutingStub) llm.Completer {
        return .{ .ctx = self, .completeFn = complete };
    }

    fn complete(ctx: *anyopaque, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8 {
        _ = system_prompt;
        const self: *RoutingStub = @ptrCast(@alignCast(ctx));
        const is_map = std.mem.indexOf(u8, user_text, "【新增对话】") != null;
        if (is_map) {
            self.map_calls += 1;
            if (self.garbage_marker.len != 0 and std.mem.indexOf(u8, user_text, self.garbage_marker) != null) {
                return gpa.dupe(u8, "garbage, not json");
            }
            return gpa.dupe(u8, self.map_response);
        }
        self.reduce_calls += 1;
        return gpa.dupe(u8, self.reduce_response);
    }
};

const ProgressRecorder = struct {
    first_detail_buf: [128]u8 = undefined,
    first_detail_len: usize = 0,

    fn sink(self: *ProgressRecorder) ProgressSink {
        return .{ .ctx = self, .onProgressFn = onProgress };
    }

    fn onProgress(ctx: *anyopaque, progress: Progress) void {
        const self: *ProgressRecorder = @ptrCast(@alignCast(ctx));
        switch (progress) {
            .summarizing => |v| {
                if (self.first_detail_len != 0 or v.detail.len == 0) return;
                const len = @min(self.first_detail_buf.len, v.detail.len);
                @memcpy(self.first_detail_buf[0..len], v.detail[0..len]);
                self.first_detail_len = len;
            },
            else => {},
        }
    }

    fn firstDetail(self: *const ProgressRecorder) []const u8 {
        return self.first_detail_buf[0..self.first_detail_len];
    }
};

fn writeFixtures(tmp: std.testing.TmpDir) !void {
    try tmp.dir.makePath("claude/proj-a");
    var d = try tmp.dir.openDir("claude/proj-a", .{});
    defer d.close();
    try d.writeFile(.{ .sub_path = "claude-abc.jsonl", .data = CLAUDE_JSONL });
}

test "memory_digest_run: llm path writes summaries, projects, highlights and timeline" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeFixtures(tmp);

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON };
    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
    };

    const first = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 1), first.sessions_summarized);
    try std.testing.expectEqual(@as(usize, 0), first.sessions_failed);

    const daily = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-05-31.json", 1 << 20);
    defer allocator.free(daily);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"summary\": \"修复了失败的测试\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"完成了修复\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"修复了测试\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"model\": \"test-model\"") != null);

    const timeline = try tmp.dir.readFileAlloc(allocator, "memory/projects/project/timeline.json", 1 << 20);
    defer allocator.free(timeline);
    try std.testing.expect(std.mem.indexOf(u8, timeline, "\"2026-05-31\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline, "修好了失败的测试") != null);

    const summaries = try tmp.dir.readFileAlloc(allocator, "memory/state/session_summaries.json", 1 << 20);
    defer allocator.free(summaries);
    try std.testing.expect(std.mem.indexOf(u8, summaries, "\"local|claude:claude-abc\"") != null);

    const map_calls_after_first = stub.map_calls;
    const reduce_calls_after_first = stub.reduce_calls;

    // Second run: no new messages → collector yields nothing → zero LLM calls.
    const second = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 0), second.sessions_collected);
    try std.testing.expectEqual(map_calls_after_first, stub.map_calls);
    try std.testing.expectEqual(reduce_calls_after_first, stub.reduce_calls);

    // Verify runs.json was written with "ok" status and llm_calls > 0.
    // Both runOnce calls above append a record; the second legitimately has
    // llm_calls == 0, so parse and require at least one record with > 0.
    const runs = try tmp.dir.readFileAlloc(allocator, "memory/state/runs.json", 1 << 20);
    defer allocator.free(runs);
    try std.testing.expect(std.mem.indexOf(u8, runs, "\"status\": \"ok\"") != null);
    const RunsShape = struct {
        runs: []const struct { llm_calls: u32 = 0 } = &.{},
    };
    const parsed_runs = try std.json.parseFromSlice(RunsShape, allocator, runs, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_runs.deinit();
    var saw_llm_calls = false;
    for (parsed_runs.value.runs) |r| {
        if (r.llm_calls > 0) saw_llm_calls = true;
    }
    try std.testing.expect(saw_llm_calls);
}

test "memory_digest_run: llm_usage flows into runs.json, defaults to 0 when unset" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeFixtures(tmp);

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON };
    const usage: protocol.ApiUsage = .{ .prompt_tokens = 100, .completion_tokens = 20, .total_tokens = 120 };
    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
        .llm_usage = &usage,
    };
    _ = try runOnce(allocator, opts);

    const RunsShape = struct {
        runs: []const struct {
            prompt_tokens: u64 = 0,
            completion_tokens: u64 = 0,
            total_tokens: u64 = 0,
        } = &.{},
    };

    const runs = try tmp.dir.readFileAlloc(allocator, "memory/state/runs.json", 1 << 20);
    defer allocator.free(runs);
    const parsed = try std.json.parseFromSlice(RunsShape, allocator, runs, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const rec = parsed.value.runs[parsed.value.runs.len - 1];
    try std.testing.expectEqual(@as(u64, 100), rec.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 20), rec.completion_tokens);
    try std.testing.expectEqual(@as(u64, 120), rec.total_tokens);

    // Stub/no-usage path (llm_usage left null, as every other test in this
    // file does): usage fields default to 0, existing behavior unchanged.
    const memory_root2 = try std.fs.path.join(allocator, &.{ root, "memory2" });
    defer allocator.free(memory_root2);
    var stub2 = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON };
    _ = try runOnce(allocator, .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root2,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub2.completer(),
        .model_label = "test-model",
    });
    const runs2 = try tmp.dir.readFileAlloc(allocator, "memory2/state/runs.json", 1 << 20);
    defer allocator.free(runs2);
    const parsed2 = try std.json.parseFromSlice(RunsShape, allocator, runs2, .{ .ignore_unknown_fields = true });
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(u64, 0), parsed2.value.runs[0].total_tokens);
}

test "memory_digest_run: progress detail names the active session before map completes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeFixtures(tmp);

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON };
    var recorder = ProgressRecorder{};
    _ = try runOnce(allocator, .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
        .progress_sink = recorder.sink(),
    });

    try std.testing.expect(std.mem.indexOf(u8, recorder.firstDetail(), "1/1 local/claude:claude-abc") != null);
}

test "memory_digest_run: map failure withholds cursor and daily entry, other sessions unaffected" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try tmp.dir.makePath("claude/proj-a");
    {
        var d = try tmp.dir.openDir("claude/proj-a", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "claude-abc.jsonl", .data = CLAUDE_JSONL });
    }
    try tmp.dir.makePath("claude/proj-b");
    {
        var d = try tmp.dir.openDir("claude/proj-b", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "claude-def.jsonl", .data = CLAUDE_JSONL_DEF });
    }

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    // claude-def's transcript contains "Second session" (see CLAUDE_JSONL_DEF
    // below) — route that session's map calls to garbage so it always fails.
    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON, .garbage_marker = "Second session" };
    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
    };

    const first = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 1), first.sessions_summarized);
    try std.testing.expectEqual(@as(usize, 1), first.sessions_failed);

    const daily = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-05-31.json", 1 << 20);
    defer allocator.free(daily);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"claude-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"claude-def\"") == null);

    // Third run (no fixture changes): claude-def's cursor never advanced, so
    // it is re-collected and re-attempted.
    const third = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 1), third.sessions_collected);
    try std.testing.expectEqual(@as(usize, 0), third.sessions_summarized);
    try std.testing.expectEqual(@as(usize, 1), third.sessions_failed);
}

test "memory_digest_run: reduce failure returns error but keeps summaries and withholds cursors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeFixtures(tmp);

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = "garbage, not json" };
    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
    };

    try std.testing.expectError(error.ReduceFailed, runOnce(allocator, opts));

    const summaries = try tmp.dir.readFileAlloc(allocator, "memory/state/session_summaries.json", 1 << 20);
    defer allocator.free(summaries);
    try std.testing.expect(std.mem.indexOf(u8, summaries, "\"local|claude:claude-abc\"") != null);

    const cursors_result = tmp.dir.readFileAlloc(allocator, "memory/state/cursors.json", 1 << 20);
    try std.testing.expectError(error.FileNotFound, cursors_result);

    // Verify runs.json was written with failure status
    const runs = try tmp.dir.readFileAlloc(allocator, "memory/state/runs.json", 1 << 20);
    defer allocator.free(runs);
    try std.testing.expect(std.mem.indexOf(u8, runs, "\"failed\"") != null);
}

// A reduce response whose timeline carries one legit slug ("project", which
// matches CLAUDE_JSONL's project_path-derived slug) and one prompt-injected
// path-traversal slug that must never be path-joined into projects/<slug>/.
const REDUCE_JSON_WITH_EVIL_SLUG =
    \\{"projects":[{"slug":"project","summary":"完成了修复","session_refs":[]}],
    \\"highlights":["修复了测试"],
    \\"timeline":[
    \\{"slug":"project","summary":"当天进展","events":[{"type":"progress","text":"合法时间线","refs":[]}]},
    \\{"slug":"../evil","summary":"注入","events":[{"type":"progress","text":"不应落盘","refs":[]}]}
    \\]}
;

test "memory_digest_run: unknown/path-traversal timeline slug is dropped, valid slug still written" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeFixtures(tmp);

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON_WITH_EVIL_SLUG };
    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
    };

    _ = try runOnce(allocator, opts);

    // The valid slug's timeline is written as usual.
    const timeline = try tmp.dir.readFileAlloc(allocator, "memory/projects/project/timeline.json", 1 << 20);
    defer allocator.free(timeline);
    try std.testing.expect(std.mem.indexOf(u8, timeline, "合法时间线") != null);

    // No directory or file named "evil" exists anywhere under the memory
    // root — neither as memory/evil, memory/projects/evil, nor resolved via
    // ".." out of memory/projects/<something>/../evil.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("memory/projects/evil", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("memory/evil", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("evil", .{}));
}

// Same project cwd as CLAUDE_JSONL ("/home/me/project" → slug "project") so
// both days' merged sessions share the slug the RoutingStub's REDUCE_JSON
// fixture claims — this test is about atomicity across days, not the slug
// allowlist (covered separately above).
const CLAUDE_JSONL_DAY2 =
    \\{"sessionId":"claude-day2","cwd":"/home/me/project","timestamp":"2026-06-01T09:00:00.000Z","type":"user","message":{"role":"user","content":"day two work"}}
    \\{"sessionId":"claude-day2","cwd":"/home/me/project","timestamp":"2026-06-01T09:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
    \\
;

/// Routes map responses to REDUCE_JSON-shaped output always, but for reduce
/// calls: succeeds if the compact sessions JSON mentions `good_date_marker`,
/// otherwise returns garbage twice (forcing digest.reduceDay's retry-once to
/// also fail) so ONE specific day's reduce is made to fail deterministically
/// while the other day's reduce succeeds.
const DateRoutingStub = struct {
    good_date_marker: []const u8,
    map_calls: usize = 0,
    reduce_calls: usize = 0,

    fn completer(self: *DateRoutingStub) llm.Completer {
        return .{ .ctx = self, .completeFn = complete };
    }

    fn complete(ctx: *anyopaque, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8 {
        _ = system_prompt;
        const self: *DateRoutingStub = @ptrCast(@alignCast(ctx));
        const is_map = std.mem.indexOf(u8, user_text, "【新增对话】") != null;
        if (is_map) {
            self.map_calls += 1;
            return gpa.dupe(u8, MAP_JSON);
        }
        self.reduce_calls += 1;
        if (std.mem.indexOf(u8, user_text, self.good_date_marker) != null) {
            return gpa.dupe(u8, REDUCE_JSON);
        }
        return gpa.dupe(u8, "garbage, not json");
    }
};

fn writeTwoDayFixtures(tmp: std.testing.TmpDir) !void {
    try tmp.dir.makePath("claude/proj-a");
    {
        var d = try tmp.dir.openDir("claude/proj-a", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "claude-abc.jsonl", .data = CLAUDE_JSONL });
    }
    try tmp.dir.makePath("claude/proj-b");
    {
        var d = try tmp.dir.openDir("claude/proj-b", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "claude-day2.jsonl", .data = CLAUDE_JSONL_DAY2 });
    }
}

test "memory_digest_run: one day's reduce failure blocks writes for every day in the run" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeTwoDayFixtures(tmp);

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    // claude-abc lands on 2026-05-31, claude-day2 on 2026-06-01. Make
    // 2026-06-01's reduce call succeed and 2026-05-31's fail (the "success"
    // stub only recognizes its own date marker in the compact sessions JSON).
    var stub = DateRoutingStub{ .good_date_marker = "2026-06-01" };
    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
    };

    try std.testing.expectError(error.ReduceFailed, runOnce(allocator, opts));

    // Neither day's daily file was written — the failing day's reduce ran
    // before ANY write phase started (day order in day_keys is insertion
    // order from summarized_dates, so whichever day is processed first is
    // irrelevant: no partial write is acceptable either way).
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("memory/daily/2026-05-31.json", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("memory/daily/2026-06-01.json", .{}));

    // Map results are still persisted (both sessions summarized successfully
    // at the map stage before reduce ran).
    const summaries = try tmp.dir.readFileAlloc(allocator, "memory/state/session_summaries.json", 1 << 20);
    defer allocator.free(summaries);
    try std.testing.expect(std.mem.indexOf(u8, summaries, "\"local|claude:claude-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summaries, "\"local|claude:claude-day2\"") != null);

    // Cursors were not saved.
    const cursors_result = tmp.dir.readFileAlloc(allocator, "memory/state/cursors.json", 1 << 20);
    try std.testing.expectError(error.FileNotFound, cursors_result);

    // Rerun with a stub where every reduce call succeeds: both dailies are
    // now written, and message_count_new is NOT inflated by the earlier
    // failed attempt (each session was only merged once, since nothing was
    // ever written to disk for either day on the first attempt).
    var stub2 = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON };
    const opts2: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub2.completer(),
        .model_label = "test-model",
    };
    _ = try runOnce(allocator, opts2);

    const daily1 = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-05-31.json", 1 << 20);
    defer allocator.free(daily1);
    try std.testing.expect(std.mem.indexOf(u8, daily1, "\"message_count_new\": 2") != null);

    const daily2 = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-06-01.json", 1 << 20);
    defer allocator.free(daily2);
    try std.testing.expect(std.mem.indexOf(u8, daily2, "\"message_count_new\": 2") != null);
}

// ---- Multi-source orchestration, summaryKey migration, alias (Task 3) ----

const REMOTE_CLAUDE_JSONL =
    \\{"sessionId":"remote-abc","cwd":"/root/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"remote work"}}
    \\{"sessionId":"remote-abc","cwd":"/root/project","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
    \\
;

/// A minimal fake `remote.ExecHost`: serves a fixed HOME + `find`/`cat`
/// output for the claude root, or fails the very first `printf %s "$HOME"`
/// call if `fail_home` is set (simulating an unreachable SSH box, spec §13).
const FakeRemoteHost = struct {
    fail_home: bool = false,
    find_output: []const u8 = "",
    cat_content: []const u8 = "",

    fn exec(ctx: *anyopaque, gpa: std.mem.Allocator, command: []const u8) anyerror![]u8 {
        const self: *FakeRemoteHost = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, command, "printf %s \"$HOME\"")) {
            if (self.fail_home) return error.ExecFailed;
            return gpa.dupe(u8, "/root");
        }
        if (std.mem.startsWith(u8, command, "find ")) {
            if (std.mem.indexOf(u8, command, "/.claude/projects") != null) return gpa.dupe(u8, self.find_output);
            return gpa.dupe(u8, "");
        }
        if (std.mem.startsWith(u8, command, "cat ")) return gpa.dupe(u8, self.cat_content);
        return error.UnknownCommand;
    }

    fn execHost(self: *FakeRemoteHost) remote.ExecHost {
        return .{ .ctx = @ptrCast(self), .exec = exec };
    }
};

test "memory_digest_run: multi-source orchestration records ok/failed per source, failed source doesn't block others" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeFixtures(tmp); // local: claude-abc

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    var good_host = FakeRemoteHost{
        .find_output = "1780300860.0\t200\t/root/.claude/projects/proj/remote-abc.jsonl\n",
        .cat_content = REMOTE_CLAUDE_JSONL,
    };
    var bad_host = FakeRemoteHost{ .fail_home = true };

    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON };
    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
        .remote_sources = &.{
            .{ .source_id = "ssh:good", .host = good_host.execHost() },
            .{ .source_id = "ssh:bad", .host = bad_host.execHost() },
        },
    };

    // Must return normally (no error) despite one remote source failing.
    const summary = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 2), summary.sessions_summarized); // local + ssh:good

    const runs = try tmp.dir.readFileAlloc(allocator, "memory/state/runs.json", 1 << 20);
    defer allocator.free(runs);
    const RunsShape = struct {
        runs: []const struct {
            status: []const u8 = "",
            sources: []const struct {
                source_id: []const u8 = "",
                status: []const u8 = "",
                detail: []const u8 = "",
                sessions_collected: u32 = 0,
            } = &.{},
        } = &.{},
    };
    const parsed = try std.json.parseFromSlice(RunsShape, allocator, runs, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const rec = parsed.value.runs[parsed.value.runs.len - 1];
    try std.testing.expectEqualStrings("partial", rec.status);

    var saw_local_ok = false;
    var saw_good_ok = false;
    var saw_bad_failed = false;
    for (rec.sources) |s| {
        if (std.mem.eql(u8, s.source_id, "local") and std.mem.eql(u8, s.status, "ok") and s.sessions_collected == 1) saw_local_ok = true;
        if (std.mem.eql(u8, s.source_id, "ssh:good") and std.mem.eql(u8, s.status, "ok") and s.sessions_collected == 1) saw_good_ok = true;
        if (std.mem.eql(u8, s.source_id, "ssh:bad") and std.mem.eql(u8, s.status, "failed") and std.mem.eql(u8, s.detail, "RemoteHomeFailed")) saw_bad_failed = true;
    }
    try std.testing.expect(saw_local_ok);
    try std.testing.expect(saw_good_ok);
    try std.testing.expect(saw_bad_failed);

    // The successful remote source's session made it into the daily file.
    const daily = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-05-31.json", 1 << 20);
    defer allocator.free(daily);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"remote-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"source_id\": \"ssh:good\"") != null);
}

test "memory_digest_run: summaryKey migration - local falls back to legacy key, remote does not" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeFixtures(tmp); // local: claude-abc

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    // Pre-seed session_summaries.json with the pre-M3 key shape for the
    // local session, as if a previous run (before this feature existed) had
    // already summarized it.
    {
        const state_dir = try std.fs.path.join(allocator, &.{ memory_root, "state" });
        defer allocator.free(state_dir);
        try std.fs.cwd().makePath(state_dir);
        const path = try std.fs.path.join(allocator, &.{ state_dir, "session_summaries.json" });
        defer allocator.free(path);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
            \\{"schema_version":1,"records":[{"key":"claude:claude-abc","date":"2026-05-30","summary":"legacy summary","topics":[],"outcome":"completed","artifacts":[]}]}
        });
    }

    // The stub's map response echoes back whatever old_summary it was given
    // (via digest.summarizeSession's rolling-update prompt, which embeds the
    // old summary text) so the test can assert the legacy record was found:
    // simpler is to just assert the record got rewritten under the NEW key
    // and the run succeeds without needing the LLM to see the old summary.
    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON };
    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
    };
    _ = try runOnce(allocator, opts);

    const summaries = try tmp.dir.readFileAlloc(allocator, "memory/state/session_summaries.json", 1 << 20);
    defer allocator.free(summaries);
    // New key present after this run.
    try std.testing.expect(std.mem.indexOf(u8, summaries, "\"local|claude:claude-abc\"") != null);
}

test "memory_digest_run: findOldSummary falls back to legacy key for local only" {
    const allocator = std.testing.allocator;
    var summaries = store.SummaryStore.init(allocator);
    defer summaries.deinit();
    try summaries.put(.{ .key = "claude:claude-abc", .date = "2026-05-30", .summary = "legacy local summary" });
    try summaries.put(.{ .key = "codex:remote-def", .date = "2026-05-30", .summary = "legacy-shaped but this is a remote session" });

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Local session: new key misses, legacy key hits.
    const new_key_local = try summaryKey(arena, "local", .claude, "claude-abc");
    const found_local = try findOldSummary(arena, &summaries, "local", .claude, "claude-abc", new_key_local);
    try std.testing.expectEqualStrings("legacy local summary", found_local.?);

    // Remote session with a session_id that happens to collide with a
    // legacy-shaped key: must NOT fall back (source_id != "local").
    const new_key_remote = try summaryKey(arena, "ssh:box", .codex, "remote-def");
    const found_remote = try findOldSummary(arena, &summaries, "ssh:box", .codex, "remote-def", new_key_remote);
    try std.testing.expect(found_remote == null);
}

test "memory_digest_run: remote session produces a project alias, not a path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    var good_host = FakeRemoteHost{
        .find_output = "1780300860.0\t200\t/root/.claude/projects/proj/remote-abc.jsonl\n",
        .cat_content = REMOTE_CLAUDE_JSONL,
    };

    // REDUCE_JSON's timeline slug is "project" (matches types.projectSlug of
    // "/root/project", REMOTE_CLAUDE_JSONL's cwd) and CLAUDE_JSONL's local
    // cwd "/home/me/project" slugs the same way, so route only the remote
    // source (no local root configured here — remote-only run).
    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON };
    const opts: Options = .{
        .roots = .{},
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
        .remote_sources = &.{
            .{ .source_id = "ssh:box", .host = good_host.execHost() },
        },
    };
    _ = try runOnce(allocator, opts);

    const project = try tmp.dir.readFileAlloc(allocator, "memory/projects/project/project.json", 1 << 20);
    defer allocator.free(project);
    const parsed = try std.json.parseFromSlice(store.Project, allocator, project, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.paths.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.aliases.len);
    try std.testing.expectEqualStrings("ssh:box:/root/project", parsed.value.aliases[0]);
}

test "memory_digest_run: mixed local+remote sessions under the same slug accumulate both paths and aliases" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeFixtures(tmp); // local: claude-abc under /home/me/project → slug "project"

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    // remote-abc under /root/project also slugs to "project" (types.projectSlug
    // takes only the basename), so one reduce-day bucket covers both sources.
    var good_host = FakeRemoteHost{
        .find_output = "1780300860.0\t200\t/root/.claude/projects/proj/remote-abc.jsonl\n",
        .cat_content = REMOTE_CLAUDE_JSONL,
    };

    var stub = RoutingStub{ .map_response = MAP_JSON, .reduce_response = REDUCE_JSON };
    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0,
        .completer = stub.completer(),
        .model_label = "test-model",
        .remote_sources = &.{
            .{ .source_id = "ssh:box", .host = good_host.execHost() },
        },
    };
    const summary = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 2), summary.sessions_summarized); // local + ssh:box

    const project = try tmp.dir.readFileAlloc(allocator, "memory/projects/project/project.json", 1 << 20);
    defer allocator.free(project);
    const parsed = try std.json.parseFromSlice(store.Project, allocator, project, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Both sides must land: the local session's path and the remote session's
    // alias — not just whichever source happened to be summarized first.
    try std.testing.expectEqual(@as(usize, 1), parsed.value.paths.len);
    try std.testing.expectEqualStrings("/home/me/project", parsed.value.paths[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.aliases.len);
    try std.testing.expectEqualStrings("ssh:box:/root/project", parsed.value.aliases[0]);
}
