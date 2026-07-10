//! memory_search agent tool: query memory digest daily artifacts by
//! candidate keywords (OR substring match) and locate past AI agent
//! sessions across local and remote sources. Read-only.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const tool_args = @import("args.zig");
const dirs = @import("../platform/dirs.zig");
const digest_store = @import("../memory_digest/store.zig");
const ai_types = @import("../terminal_agents/sessions/types.zig");

const ToolContext = types.ToolContext;

const MAX_DAILY_BYTES = 16 * 1024 * 1024;
const MAX_RESULTS = 20;
const DEFAULT_DAYS: u32 = 30;
const MAX_DAYS: u32 = 3650;

/// Tool-call adapter: parse args, resolve $CONFIG_DIR/memory/daily, delegate.
pub fn search(ctx: *ToolContext, root: std.json.Value) ![]u8 {
    const keywords = tool_args.stringArray(ctx.allocator, root, "keywords") catch |err| switch (err) {
        error.InvalidToolArguments => return ctx.allocator.dupe(u8, "Invalid keywords: expected an array of strings"),
        else => return err,
    };
    defer tool_args.freeStringArray(ctx.allocator, keywords);
    if (keywords.len == 0) return ctx.allocator.dupe(u8, "Missing keywords");
    const source = tool_args.string(root, "source");
    const days = tool_args.int(root, "days") orelse DEFAULT_DAYS;

    const memory_root = try dirs.memoryDir(ctx.allocator);
    defer ctx.allocator.free(memory_root);
    const daily_dir = try std.fs.path.join(ctx.allocator, &.{ memory_root, "daily" });
    defer ctx.allocator.free(daily_dir);

    return searchDailyDir(ctx.allocator, daily_dir, keywords, source, days, std.time.milliTimestamp());
}

/// Pure core: scan daily/*.json newer than the cutoff, OR-match keywords,
/// sort by hit count then date, format the top results as plain text.
pub fn searchDailyDir(
    gpa: std.mem.Allocator,
    daily_dir: []const u8,
    keywords: []const []const u8,
    source: ?[]const u8,
    days: u32,
    now_ms: i64,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const window_days: u32 = @min(if (days == 0) DEFAULT_DAYS else days, MAX_DAYS);
    const cutoff_ms = now_ms -| @as(i64, window_days) * std.time.ms_per_day;
    var cutoff_buf: [10]u8 = undefined;
    // ponytail: UTC day cutoff; a boundary session can drift one day, harmless
    // at the default 30-day window.
    const cutoff = digest_store.formatDate(ai_types.dateKeyFromMs(cutoff_ms, 0), &cutoff_buf);

    const Match = struct { date: []const u8, hits: u32, s: digest_store.DailySession };
    var matches: std.ArrayListUnmanaged(Match) = .empty;
    var files_scanned: usize = 0;
    // ponytail: linear scan per source id; ids number in the handfuls.
    const SourceCount = struct { source_id: []const u8, count: u32 };
    var source_counts: std.ArrayListUnmanaged(SourceCount) = .empty;

    scan: {
        var dir = std.fs.cwd().openDir(daily_dir, .{ .iterate = true }) catch break :scan;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (ent.kind != .file) continue;
            // "YYYY-MM-DD.json" only; anything else is not a daily artifact.
            if (ent.name.len != 15 or !std.mem.endsWith(u8, ent.name, ".json")) continue;
            const date = ent.name[0..10];
            if (std.mem.order(u8, date, cutoff) == .lt) continue;
            const bytes = dir.readFileAlloc(arena, ent.name, MAX_DAILY_BYTES) catch continue;
            const daily = std.json.parseFromSliceLeaky(digest_store.Daily, arena, bytes, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            files_scanned += 1;
            for (daily.sessions) |s| {
                // 覆盖统计在 source 过滤之前计，不受过滤影响。
                const sc: *SourceCount = blk: {
                    for (source_counts.items) |*c| {
                        if (std.mem.eql(u8, c.source_id, s.source_id)) break :blk c;
                    }
                    try source_counts.append(arena, .{ .source_id = try arena.dupe(u8, s.source_id), .count = 0 });
                    break :blk &source_counts.items[source_counts.items.len - 1];
                };
                sc.count += 1;
                if (source) |src| {
                    if (std.ascii.indexOfIgnoreCase(s.source_id, src) == null) continue;
                }
                const hits = keywordHits(s, keywords);
                if (hits == 0) continue;
                try matches.append(arena, .{ .date = try arena.dupe(u8, date), .hits = hits, .s = s });
            }
        }
    }

    if (matches.items.len == 0) {
        const scan_info = try scanLine(arena, files_scanned, source_counts.items);
        return std.fmt.allocPrint(
            gpa,
            "{s}\n" ++
                "No digest match in the last {d} days ({d} daily files scanned). " ++
                "If the work happened on a remote host, run this on an open SSH surface " ++
                "there via ssh_session_exec: grep -rli <keyword> ~/.claude/projects ~/.codex/sessions | head. " ++
                "If digest data is missing, suggest memory-digest-scan-remote=true or 'Run memory digest now'.",
            .{ scan_info, window_days, files_scanned },
        );
    }

    std.mem.sort(Match, matches.items, {}, struct {
        fn lessThan(_: void, a: Match, b: Match) bool {
            if (a.hits != b.hits) return a.hits > b.hits;
            return std.mem.order(u8, a.date, b.date) == .gt;
        }
    }.lessThan);

    const shown = @min(matches.items.len, MAX_RESULTS);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const scan_info = try scanLine(arena, files_scanned, source_counts.items);
    const header = try std.fmt.allocPrint(arena, "{s}\n{d} match(es), showing {d}:\n\n", .{ scan_info, matches.items.len, shown });
    try out.appendSlice(arena, header);
    for (matches.items[0..shown]) |m| {
        const head = try std.fmt.allocPrint(arena, "[{s}] {s} · project: {s} · outcome: {s}\n", .{
            m.date, m.s.source_id, m.s.project, m.s.outcome,
        });
        try out.appendSlice(arena, head);
        if (m.s.title.len != 0) {
            const line = try std.fmt.allocPrint(arena, "title: {s}\n", .{m.s.title});
            try out.appendSlice(arena, line);
        }
        if (m.s.summary.len != 0) {
            const line = try std.fmt.allocPrint(arena, "summary: {s}\n", .{m.s.summary});
            try out.appendSlice(arena, line);
        }
        if (m.s.topics.len != 0) {
            try out.appendSlice(arena, "topics: ");
            for (m.s.topics, 0..) |topic, i| {
                if (i != 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, topic);
            }
            try out.appendSlice(arena, "\n");
        }
        const session_line = try std.fmt.allocPrint(arena, "session: {s} / {s}\n", .{ m.s.provider, m.s.session_id });
        try out.appendSlice(arena, session_line);
        if (m.s.source_file.len != 0) {
            const line = try std.fmt.allocPrint(arena, "transcript: {s}\n", .{m.s.source_file});
            try out.appendSlice(arena, line);
        }
        try out.appendSlice(arena, "\n");
    }
    return gpa.dupe(u8, std.mem.trimRight(u8, out.items, "\n"));
}

/// C3 header line: `Scanned {N} daily files; sources: local (2 sessions), ...`
/// counts is anytype because SourceCount is local to searchDailyDir.
fn scanLine(arena: std.mem.Allocator, files_scanned: usize, counts: anytype) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const head = try std.fmt.allocPrint(arena, "Scanned {d} daily files", .{files_scanned});
    try out.appendSlice(arena, head);
    if (counts.len != 0) {
        try out.appendSlice(arena, "; sources: ");
        for (counts, 0..) |c, i| {
            if (i != 0) try out.appendSlice(arena, ", ");
            const part = try std.fmt.allocPrint(arena, "{s} ({d} sessions)", .{ c.source_id, c.count });
            try out.appendSlice(arena, part);
        }
    }
    try out.appendSlice(arena, ".");
    return out.items;
}

fn keywordHits(s: digest_store.DailySession, keywords: []const []const u8) u32 {
    var hits: u32 = 0;
    for (keywords) |kw| {
        if (kw.len == 0) continue;
        if (fieldHas(s.summary, kw) or fieldHas(s.title, kw) or fieldHas(s.project, kw) or topicsHave(s.topics, kw)) {
            hits += 1;
        }
    }
    return hits;
}

fn fieldHas(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn topicsHave(topics: []const []const u8, needle: []const u8) bool {
    for (topics) |topic| {
        if (fieldHas(topic, needle)) return true;
    }
    return false;
}

test "memory_search: OR keywords rank by hit count, source filter, days cutoff" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const daily_dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(daily_dir);

    const now_ms: i64 = 1_720_000_000_000;
    var buf_today: [10]u8 = undefined;
    var buf_old: [10]u8 = undefined;
    const d_today = digest_store.formatDate(ai_types.dateKeyFromMs(now_ms, 0), &buf_today);
    const d_old = digest_store.formatDate(ai_types.dateKeyFromMs(now_ms - 40 * std.time.ms_per_day, 0), &buf_old);

    // 今天：CPU2 上的 RNA-seq 分析（命中 2 词）+ 本地无关会话（命中 1 词）。
    const today_json = try std.fmt.allocPrint(a,
        \\{{"schema_version":1,"date":"{s}","generated_at":1,"sessions":[
        \\{{"provider":"claude","source_id":"ssh:CPU2","session_id":"aaa-111","project":"rnaseq","title":"差异表达","message_count_new":9,"summary":"用 DESeq2 做了 RNA-seq 差异表达分析","topics":["DESeq2","RNA-seq"],"outcome":"completed","source_file":"/root/.claude/projects/-root-rnaseq/aaa-111.jsonl"}},
        \\{{"provider":"codex","source_id":"local","session_id":"bbb-222","project":"phantty","title":"resize bug","message_count_new":2,"summary":"修 DESeq2 文档笔误","topics":["docs"],"outcome":"completed"}}]}}
    , .{d_today});
    defer a.free(today_json);
    const today_name = try std.fmt.allocPrint(a, "{s}.json", .{d_today});
    defer a.free(today_name);
    try tmp.dir.writeFile(.{ .sub_path = today_name, .data = today_json });

    // 40 天前：窗口外，必须被 days 截断。
    const old_json = try std.fmt.allocPrint(a,
        \\{{"schema_version":1,"date":"{s}","generated_at":1,"sessions":[
        \\{{"provider":"claude","source_id":"ssh:CPU2","session_id":"ccc-333","project":"rnaseq","title":"旧的 DESeq2","message_count_new":1,"summary":"旧 DESeq2","topics":[],"outcome":"unknown"}}]}}
    , .{d_old});
    defer a.free(old_json);
    const old_name = try std.fmt.allocPrint(a, "{s}.json", .{d_old});
    defer a.free(old_name);
    try tmp.dir.writeFile(.{ .sub_path = old_name, .data = old_json });

    // OR + 排序：两词都中的 aaa-111 排在只中一词的 bbb-222 前。
    const out = try searchDailyDir(a, daily_dir, &.{ "DESeq2", "RNA-seq" }, null, 30, now_ms);
    defer a.free(out);
    const first = std.mem.indexOf(u8, out, "aaa-111").?;
    const second = std.mem.indexOf(u8, out, "bbb-222").?;
    try std.testing.expect(first < second);
    try std.testing.expect(std.mem.indexOf(u8, out, "ccc-333") == null); // days 截断
    try std.testing.expect(std.mem.indexOf(u8, out, "/root/.claude/projects/-root-rnaseq/aaa-111.jsonl") != null);

    // source 过滤：cpu2（小写）只留 ssh:CPU2。
    const filtered = try searchDailyDir(a, daily_dir, &.{"DESeq2"}, "cpu2", 30, now_ms);
    defer a.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "aaa-111") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "bbb-222") == null);

    // Task 2 (C3): 头部扫描覆盖行。
    try std.testing.expect(std.mem.indexOf(u8, out, "sources: local (1 sessions), ssh:CPU2 (1 sessions)") != null or
        std.mem.indexOf(u8, out, "sources: ssh:CPU2 (1 sessions), local (1 sessions)") != null);
}

test "memory_search: no match reports scanned window and fallback hint" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const daily_dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(daily_dir);

    const out = try searchDailyDir(a, daily_dir, &.{"nonexistent-keyword"}, null, 30, 1_720_000_000_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No digest match") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ssh_session_exec") != null);
    // no-match 输出同样带扫描覆盖行（0 文件时来源为空）。
    try std.testing.expect(std.mem.indexOf(u8, out, "Scanned 0 daily files") != null);
}

test "memory_search: missing daily dir returns no-match, not error" {
    const a = std.testing.allocator;
    const out = try searchDailyDir(a, "/nonexistent/path/for/test", &.{"x"}, null, 30, 1_720_000_000_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No digest match") != null);
}
