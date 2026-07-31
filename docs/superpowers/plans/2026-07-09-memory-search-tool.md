# memory_search Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 copilot 新增 `memory_search` 首方 tool，按候选词 OR 子串匹配检索 memory digest 的 daily 产物，返回历史 agent 会话的定位信息（日期/主机/项目/summary/session_id/transcript 路径）。

**Architecture:** 三层改动：(1) digest 产物 `DailySession` 补 `source_file` 字段并在 run.zig 三处构造/合并点透传；(2) 新文件 `src/agent_tools/memory_search.zig` 实现纯函数搜索核心 + ToolContext 适配器；(3) 按既有 memory_* 工具模式在 first_party.zig / protocol.zig / mod.zig 注册与分派。实时兜底不写代码，靠 tool description 引导模型改用已有 `ssh_session_exec`。

**Tech Stack:** Zig（仓库现版本）、std.json、std.ascii.indexOfIgnoreCase。无新依赖。

**Spec:** `docs/superpowers/specs/2026-07-09-memory-search-tool-design.md`

## Global Constraints

- 默认 `zig build` 目标是 Windows；本地验证用 `zig build test`（fast 套件，macOS 上真实运行）。
- 推送/收尾前必跑 `zig fmt build.zig src`（CI 的 "Zig fast tests / Linux" 先跑 fmt check，本地 test 不含）。
- Bash 中不要 `cd /Users/.../phantty`（会跳到主仓库其他分支的 worktree），全部用默认 cwd + 相对路径。
- 匹配语义（spec §3）：keywords **OR**、大小写不敏感子串、匹配域 `summary|title|topics[]|project`；排序 = 命中数降序再日期降序；返回上限 **20** 条；`days` 默认 **30**。
- `source` 过滤：大小写不敏感子串匹配 `source_id`。
- 新 tool 名 `memory_search`，category `.memory`（自动受 `ai-memory-enabled` 与 memory_ 前缀禁用守卫约束）。
- 只读工具，无 approval 流程。

---

### Task 1: DailySession.source_file 字段透传

**Files:**
- Modify: `src/memory_digest/store.zig:12-23`（struct 加字段）
- Modify: `src/memory_digest/run.zig:341-348`（M1 原始路径构造）
- Modify: `src/memory_digest/run.zig:518-529`（LLM 归纳路径构造）
- Modify: `src/memory_digest/run.zig:651-728`（mergeDailyWithExisting：ExistingShape + 两个 merge 分支）
- Test: `src/memory_digest/store.zig`（文件尾部追加）

**Interfaces:**
- Produces: `store.DailySession.source_file: []const u8 = ""` — Task 2 的搜索核心读取该字段作为 transcript 定位路径。旧 daily JSON 无此字段 → 解析得 `""`。

- [ ] **Step 1: 写失败测试**

在 `src/memory_digest/store.zig` 文件末尾（`test "memory_digest_store: SummaryStore missing or corrupt file loads empty"` 之后）追加：

```zig
test "memory_digest_store: DailySession source_file round-trips and defaults for old json" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    try writeDaily(a, root, .{
        .date = "2026-07-09",
        .generated_at = 1,
        .sessions = &.{.{
            .provider = "claude",
            .source_id = "ssh:CPU2",
            .session_id = "aaa-111",
            .project = "rnaseq",
            .title = "t",
            .message_count_new = 3,
            .source_file = "/root/.claude/projects/-root-rnaseq/aaa-111.jsonl",
        }},
    });

    const path = try std.fs.path.join(a, &.{ root, "daily", "2026-07-09.json" });
    defer a.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(a, path, 1 << 20);
    defer a.free(bytes);
    var parsed = try std.json.parseFromSlice(Daily, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "/root/.claude/projects/-root-rnaseq/aaa-111.jsonl",
        parsed.value.sessions[0].source_file,
    );

    // 旧格式（无 source_file 字段）解析回默认空串。
    const old_json =
        \\{"schema_version":1,"date":"2026-07-08","generated_at":1,"sessions":[{"provider":"codex","source_id":"local","session_id":"b","project":"p","title":"t","message_count_new":1}]}
    ;
    var old_parsed = try std.json.parseFromSlice(Daily, a, old_json, .{ .ignore_unknown_fields = true });
    defer old_parsed.deinit();
    try std.testing.expectEqualStrings("", old_parsed.value.sessions[0].source_file);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test 2>&1 | tail -20`
Expected: 编译错误 `no field named 'source_file' in struct ...DailySession`

- [ ] **Step 3: 最小实现**

`src/memory_digest/store.zig` 的 `DailySession`（第 12-23 行）在 `artifacts` 字段后加一行：

```zig
pub const DailySession = struct {
    provider: []const u8,
    source_id: []const u8,
    session_id: []const u8,
    project: []const u8,
    title: []const u8,
    message_count_new: u32,
    summary: []const u8 = "",
    topics: []const []const u8 = &.{},
    outcome: []const u8 = "unknown",
    artifacts: []const Artifact = &.{},
    source_file: []const u8 = "",
};
```

`src/memory_digest/run.zig` 三处透传：

(a) 约 341 行（M1 原始路径 `entries.append`）：

```zig
            try entries.append(arena, .{
                .provider = @tagName(s.provider),
                .source_id = s.source_id,
                .session_id = s.session_id,
                .project = try arena.dupe(u8, types.projectSlug(s.project_path, &slug_buf)),
                .title = s.title,
                .message_count_new = @intCast(s.new_messages.len),
                .source_file = s.source_file,
            });
```

(b) 约 518 行（归纳路径 `summarized.append`）：在 `.artifacts = result.artifacts,` 之后加：

```zig
            .source_file = s.source_file,
```

(c) `mergeDailyWithExisting`（约 651 行起）三处：

`ExistingShape` struct 加字段：

```zig
        artifacts: []const store.Artifact = &.{},
        source_file: []const u8 = "",
```

匹配分支（`.artifacts = if (keep_old_summary) old.artifacts else n.artifacts,` 之后）：

```zig
                .source_file = if (n.source_file.len != 0) n.source_file else old.source_file,
```

未匹配保留旧条目的分支（`.artifacts = old.artifacts,` 之后）：

```zig
                .source_file = old.source_file,
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test 2>&1 | tail -5`
Expected: 全部通过，无失败输出

- [ ] **Step 5: 提交**

```bash
git add src/memory_digest/store.zig src/memory_digest/run.zig
git commit -m "Persist source_file in memory digest daily sessions"
```

---

### Task 2: 搜索核心 src/agent_tools/memory_search.zig

**Files:**
- Create: `src/agent_tools/memory_search.zig`
- Modify: `src/test_fast.zig:315`（agent_tools/memory.zig 导入行后加一行）

**Interfaces:**
- Consumes: `digest_store.Daily` / `digest_store.DailySession`（含 Task 1 的 `source_file`）、`digest_store.formatDate`、`ai_types.dateKeyFromMs`（`src/terminal_agents/sessions/types.zig`）、`tool_args.stringArray/string/int`（`src/agent_tools/args.zig`）、`dirs.memoryDir`（`src/platform/dirs.zig:235`）。
- Produces:
  - `pub fn search(ctx: *ToolContext, root: std.json.Value) ![]u8` — Task 3 的 mod.zig 分派调用。
  - `pub fn searchDailyDir(gpa: std.mem.Allocator, daily_dir: []const u8, keywords: []const []const u8, source: ?[]const u8, days: u32, now_ms: i64) ![]u8` — 纯函数核心，测试直接调。

- [ ] **Step 1: 创建带失败测试的新文件**

创建 `src/agent_tools/memory_search.zig`，先只写测试（实现留空函数体骨架也不写——直接让编译失败驱动）：

```zig
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
}

test "memory_search: missing daily dir returns no-match, not error" {
    const a = std.testing.allocator;
    const out = try searchDailyDir(a, "/nonexistent/path/for/test", &.{"x"}, null, 30, 1_720_000_000_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No digest match") != null);
}
```

同时在 `src/test_fast.zig` 第 315 行 `_ = @import("agent_tools/memory.zig");` 之后加：

```zig
    _ = @import("agent_tools/memory_search.zig");
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test 2>&1 | tail -10`
Expected: 编译错误 `use of undeclared identifier 'searchDailyDir'`

- [ ] **Step 3: 实现**

在 `memory_search.zig` 的常量定义之后、测试之前插入实现：

```zig
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
        return std.fmt.allocPrint(
            gpa,
            "No digest match in the last {d} days ({d} daily files scanned). " ++
                "If the work happened on a remote host, run this on an open SSH surface " ++
                "there via ssh_session_exec: grep -rli <keyword> ~/.claude/projects ~/.codex/sessions | head. " ++
                "If digest data is missing, suggest memory-digest-scan-remote=true or 'Run memory digest now'.",
            .{ window_days, files_scanned },
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
    const header = try std.fmt.allocPrint(arena, "{d} match(es), showing {d}:\n\n", .{ matches.items.len, shown });
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test 2>&1 | tail -5`
Expected: 全部通过

- [ ] **Step 5: 提交**

```bash
git add src/agent_tools/memory_search.zig src/test_fast.zig
git commit -m "Add memory_search digest query core"
```

---

### Task 3: 注册、schema 与分派

**Files:**
- Modify: `src/tools/first_party.zig:61`（static_definitions，memory_delete 行后）
- Modify: `src/assistant/conversation/protocol.zig:729`（builtinToolNameReserved 数组，"memory_delete" 后）
- Modify: `src/assistant/conversation/protocol.zig:813`（`if (opts.include_memory)` 块内，memory_delete 的 emitTool 后）
- Modify: `src/agent_tools/mod.zig:24` 附近（import）与 `mod.zig:288`（memory_delete 分派分支后）
- Test: `src/agent_tools/mod.zig`（既有 memory 测试之后追加）

**Interfaces:**
- Consumes: Task 2 的 `agent_memory_search.search(ctx, root)`。
- Produces: 模型可见的 `memory_search` tool（参数 `keywords: []string` required、`source?: string`、`days?: integer`），经 `executeToolCall` 分派。

- [ ] **Step 1: 写失败测试**

在 `src/agent_tools/mod.zig` 的 `test "executeToolCall reports memory disabled when ai-memory-enabled is off"` 之后追加：

```zig
test "executeToolCall memory_search returns no-match text when digest artifacts absent" {
    const a = std.testing.allocator;
    platform_dirs.setTestConfigDirForCurrentThread("memory-search-test-config");
    defer platform_dirs.clearTestConfigDirForCurrentThread();

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .memory_enabled = true },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("1"),
        .name = @constCast("memory_search"),
        .arguments = @constCast("{\"keywords\":[\"DESeq2\",\"RNA-seq\"],\"source\":\"CPU2\"}"),
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No digest match") != null);
}
```

注意：若 mod.zig 尚未导入 `platform_dirs`，在文件头 import 区加
`const platform_dirs = @import("../platform/dirs.zig");`
（先 grep 确认：`grep -n "platform/dirs" src/agent_tools/mod.zig`，已有则复用现有别名）。

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test 2>&1 | tail -10`
Expected: 测试失败，输出含 `Unknown tool: memory_search`（分派缺失，返回 fallback 文案，`indexOf` 断言失败）

- [ ] **Step 3: 实现注册与分派**

(a) `src/tools/first_party.zig` 第 61 行 `memory_delete` 定义后加：

```zig
    .{ .name = "memory_search", .label = "memory_search", .description = "Search digested history of past AI agent sessions across local and remote hosts.", .category = .memory },
```

(b) `src/assistant/conversation/protocol.zig` `builtinToolNameReserved` 数组 `"memory_delete",` 后加：

```zig
        "memory_search",
```

(c) `src/assistant/conversation/protocol.zig` `if (opts.include_memory)` 块内，memory_delete 的 emitTool 行后加（单行长字符串，与相邻行风格一致）：

```zig
        try Filtered.emitToolWithRequired(ctx, opts, "memory_search", "Search the local memory digest of past AI agent sessions (Claude Code, Codex, WispTerm Copilot) from this machine and scanned remote hosts. Use when the user asks where or when they did some past work, e.g. 'I ran an analysis on CPU2, find that session'. First extract 3-6 candidate keywords from the question (topic terms, tool names, Chinese and English variants); any keyword may hit (OR) and results sort by hit count. Returns date, source host, project, summary, session id, and transcript path. If nothing matches and the user names a remote host, fall back to ssh_session_exec on an open SSH surface to that host: grep -rli <keyword> ~/.claude/projects ~/.codex/sessions | head. If digest data is missing entirely, suggest setting memory-digest-scan-remote=true via wispterm_config or running 'Run memory digest now'.", "{\"keywords\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"3-6 candidate filter words from the user's question. Case-insensitive substring match against summary, title, topics, and project; any hit counts (OR).\"},\"source\":{\"type\":\"string\",\"description\":\"Optional host/source filter, e.g. CPU2. Substring-matched against source id (local, wsl:<distro>, ssh:<profile>).\"},\"days\":{\"type\":\"integer\",\"description\":\"Optional lookback window in days, default 30.\"}}", &.{"keywords"});
```

(d) `src/agent_tools/mod.zig`：import 区 `agent_memory_tool` 行后加

```zig
const agent_memory_search = @import("memory_search.zig");
```

`memory_delete` 分派分支（约 284-288 行）后加：

```zig
    if (std.mem.eql(u8, call.name, "memory_search")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        return agent_memory_search.search(ctx, args.value);
    }
```

（`memory_` 前缀的 disabled 守卫在 mod.zig:271 已覆盖 memory_search，无需另加。）

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test 2>&1 | tail -5`
Expected: 全部通过（含 Task 1、2 的测试）

- [ ] **Step 5: 提交**

```bash
git add src/tools/first_party.zig src/assistant/conversation/protocol.zig src/agent_tools/mod.zig
git commit -m "Register memory_search copilot tool"
```

---

### Task 4: 收尾验证

**Files:**
- 无新改动；验证 + 可能的 fmt 修正

- [ ] **Step 1: zig fmt（CI 门禁，必跑）**

Run: `zig fmt build.zig src`
Expected: 无输出，或列出被重排的文件（列出即为已修复，需重新提交）

- [ ] **Step 2: fast 套件全量**

Run: `zig build test 2>&1 | tail -5`
Expected: 全部通过

- [ ] **Step 3: macOS 原生 full 套件（真实运行 ~2300 测试）**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | tail -10`
Expected: 通过；已知抖动 `skill center tool import`（FileNotFound on .zig-cache/tmp）与本改动无关，可忽略

- [ ] **Step 4: 如 fmt 有改动则补提交**

```bash
git add -u && git commit -m "zig fmt" || true
```

---

## Self-Review 记录

- **Spec 覆盖**：§3 tool 定义与匹配语义 → Task 2/3；§3 模型引导文案 → Task 3(c) description；§4 source_file → Task 1；§5 注册结构 → Task 3；§7 测试 → 各 Task 内嵌 + Task 4；§8 边界（profile 名匹配、UTC cutoff）→ 实现内 ponytail 注释。手动 E2E（§7 第三条）留给用户真机验证，不在本计划内。
- **占位符**：无 TBD/TODO；所有代码块完整。
- **类型一致性**：`searchDailyDir` 签名在 Task 2 Interfaces 与实现一致；`search(ctx, root)` 与 mod.zig 分派调用一致；`source_file` 字段名三处统一。
