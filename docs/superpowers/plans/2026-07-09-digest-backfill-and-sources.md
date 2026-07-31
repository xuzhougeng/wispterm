# Digest Backfill 与来源增强 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复"codex 历史会话搜不到"的根因（无 summary 空洞回填归纳），并在 daily JSON / Memory Center / memory_search 三处补齐来源展示，同时把远端采集的 `ok(0)` 变成可解释的诊断明细。

**Architecture:** 三个子特性：A 回填 = collector 增"按路径全量加载" + 新 backfill.zig 找空洞 + runOnceWithLlm 归纳后追加回填条目（复用既有 merge/reduce/持久化路径）；B 诊断 = collector/remote 产出 per-provider 明细写进 SourceStatus.detail + sources.zig ssh exec 失败带 stderr 日志；C 展示 = store 新增 DailySource 聚合，viewer/memory_search 文案增强。

**Tech Stack:** Zig（仓库现版本）、std.json。无新依赖。

**Spec:** `docs/superpowers/specs/2026-07-09-digest-backfill-and-sources-design.md`

## Global Constraints

- 默认 `zig build` 目标是 Windows；本地验证用 `zig build test`（fast 套件，macOS 真实运行）。收尾前必跑 `zig fmt build.zig src`（CI fmt 门禁）。
- Bash 中不要 `cd`，用默认 cwd。
- 回填规则（spec §3）：扫**所有** daily 文件不限窗口；只回填 `summary==""` 且 `source_id=="local"` 的条目；每轮上限 **8** 个；原文件找不到 → 永久跳过；summary store 已有非空记录 → 直接回写 daily 不调 LLM；回填**不推进游标**；回填条目 `message_count_new = 0`（merge 时保留旧计数）；date 用条目原始 daily 日期。
- 持久化顺序不变式保持：summaries 先落盘，daily 后写（既有 runOnceWithLlm 顺序不动，回填条目并入既有 `summarized` 列表走同一条路）。
- C1 聚合字段：`DailySource{source_id, providers, session_count}`，从 sessions[] 派生，旧文件缺字段解析为空（`ignore_unknown_fields` 兼容双向）。
- C2 文案格式：`{N} sessions, {M} projects[, model] · local×4 · ssh:CPU×2`。
- C3 头部行格式（有无命中都输出）：`Scanned {N} daily files; sources: local ({a} sessions), ssh:CPU ({b} sessions).`
- B detail 是人读文本非结构化字段（spec §7）。

---

### Task 1: store.DailySource 聚合（C1）

**Files:**
- Modify: `src/memory_digest/store.zig:27-35`（Daily struct）+ 新增 DailySource/aggregateSources
- Modify: `src/memory_digest/run.zig:353-357` 与 `run.zig:580` 附近（两处 writeDaily 调用）
- Test: `src/memory_digest/store.zig` 文件尾部

**Interfaces:**
- Produces: `store.DailySource = struct { source_id, providers: []const []const u8, session_count: u32 }`；`Daily.sources: []const DailySource = &.{}`；`pub fn aggregateSources(arena: std.mem.Allocator, sessions: []const DailySession) ![]const DailySource` — Task 2 的 viewer 复用同一函数。

- [ ] **Step 1: 写失败测试**（store.zig 尾部追加）

```zig
test "memory_digest_store: aggregateSources groups by source with provider list" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sessions = [_]DailySession{
        .{ .provider = "claude", .source_id = "local", .session_id = "a", .project = "p", .title = "", .message_count_new = 1 },
        .{ .provider = "codex", .source_id = "local", .session_id = "b", .project = "p", .title = "", .message_count_new = 1 },
        .{ .provider = "claude", .source_id = "local", .session_id = "c", .project = "p", .title = "", .message_count_new = 1 },
        .{ .provider = "claude", .source_id = "ssh:CPU", .session_id = "d", .project = "p", .title = "", .message_count_new = 1 },
    };
    const srcs = try aggregateSources(arena, &sessions);
    try std.testing.expectEqual(@as(usize, 2), srcs.len);
    try std.testing.expectEqualStrings("local", srcs[0].source_id);
    try std.testing.expectEqual(@as(u32, 3), srcs[0].session_count);
    try std.testing.expectEqual(@as(usize, 2), srcs[0].providers.len); // claude, codex 去重
    try std.testing.expectEqualStrings("ssh:CPU", srcs[1].source_id);
    try std.testing.expectEqual(@as(u32, 1), srcs[1].session_count);

    // 旧 daily JSON（无 sources 字段）解析回默认空。
    const old_json =
        \\{"schema_version":1,"date":"2026-07-08","generated_at":1,"sessions":[]}
    ;
    var parsed = try std.json.parseFromSlice(Daily, a, old_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.sources.len);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test 2>&1 | tail -5`
Expected: 编译错误 `use of undeclared identifier 'aggregateSources'`（或 DailySession 缺字段报错）

- [ ] **Step 3: 实现**

store.zig 在 `DailyProject` 定义后加：

```zig
pub const DailySource = struct {
    source_id: []const u8,
    providers: []const []const u8 = &.{},
    session_count: u32 = 0,
};

/// Derive the per-source rollup shown in daily artifacts and the Memory
/// Center from a day's session list. Order follows first appearance.
pub fn aggregateSources(arena: std.mem.Allocator, sessions: []const DailySession) ![]const DailySource {
    const Acc = struct { source_id: []const u8, providers: std.ArrayListUnmanaged([]const u8), count: u32 };
    var accs: std.ArrayListUnmanaged(Acc) = .empty;
    for (sessions) |s| {
        const acc: *Acc = blk: {
            for (accs.items) |*a| {
                if (std.mem.eql(u8, a.source_id, s.source_id)) break :blk a;
            }
            try accs.append(arena, .{ .source_id = s.source_id, .providers = .empty, .count = 0 });
            break :blk &accs.items[accs.items.len - 1];
        };
        acc.count += 1;
        const seen = for (acc.providers.items) |p| {
            if (std.mem.eql(u8, p, s.provider)) break true;
        } else false;
        if (!seen) try acc.providers.append(arena, s.provider);
    }
    var out = try arena.alloc(DailySource, accs.items.len);
    for (accs.items, 0..) |*a, i| out[i] = .{
        .source_id = a.source_id,
        .providers = a.providers.items,
        .session_count = a.count,
    };
    return out;
}
```

`Daily` struct 在 `highlights` 字段后加：

```zig
    sources: []const DailySource = &.{},
```

run.zig 两处 `store.writeDaily(gpa, opts.memory_root, .{...})`（M1 raw 路径约 353 行、LLM 路径约 580 行）都在字面量里加一行（merged 是该处已有的合并结果变量名，以实际代码为准）：

```zig
            .sources = try store.aggregateSources(arena, merged),
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test 2>&1 | tail -3`
Expected: 通过

- [ ] **Step 5: 提交**

```bash
git add src/memory_digest/store.zig src/memory_digest/run.zig
git commit -m "Aggregate per-source rollup into daily digest artifacts"
```

---

### Task 2: 来源展示文案（C2 Memory Center + C3 memory_search）

**Files:**
- Modify: `src/memory_viewer.zig:151-156`（digestDetail）
- Modify: `src/agent_tools/memory_search.zig:60-108`（扫描时聚合 + 头部行）
- Test: 两文件各自尾部/既有测试内

**Interfaces:**
- Consumes: Task 1 的 `store.aggregateSources` / `Daily.sources`。
- Produces: 无新接口（纯文案）。

- [ ] **Step 1: 写失败测试**

memory_viewer.zig 尾部追加：

```zig
test "memory_viewer: digestDetail appends source breakdown" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const daily = digest_store.Daily{
        .date = "2026-07-08",
        .generated_at = 1,
        .sessions = &.{
            .{ .provider = "claude", .source_id = "local", .session_id = "a", .project = "p", .title = "", .message_count_new = 1 },
            .{ .provider = "claude", .source_id = "ssh:CPU", .session_id = "b", .project = "p", .title = "", .message_count_new = 1 },
        },
    };
    const detail = try digestDetail(arena, daily);
    try std.testing.expect(std.mem.indexOf(u8, detail, "local×1") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "ssh:CPU×1") != null);
}
```

memory_search.zig 既有第一个测试（`OR keywords rank by hit count...`）末尾追加断言；no-match 测试也加一条：

```zig
    // Task 2 (C3): 头部扫描覆盖行。
    try std.testing.expect(std.mem.indexOf(u8, out, "sources: local (1 sessions), ssh:CPU2 (1 sessions)") != null or
        std.mem.indexOf(u8, out, "sources: ssh:CPU2 (1 sessions), local (1 sessions)") != null);
```

```zig
    // no-match 输出同样带扫描覆盖行（0 文件时来源为空）。
    try std.testing.expect(std.mem.indexOf(u8, out, "Scanned 0 daily files") != null);
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test 2>&1 | tail -5`
Expected: viewer 测试编译失败（digestDetail 现签名不产出来源）或断言失败；memory_search 断言失败

- [ ] **Step 3: 实现**

memory_viewer.zig `digestDetail` 改为：

```zig
fn digestDetail(arena: std.mem.Allocator, daily: digest_store.Daily) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (daily.model.len > 0) {
        const head = try std.fmt.allocPrint(arena, "{d} sessions, {d} projects, {s}", .{ daily.sessions.len, daily.projects.len, daily.model });
        try out.appendSlice(arena, head);
    } else {
        const head = try std.fmt.allocPrint(arena, "{d} sessions, {d} projects", .{ daily.sessions.len, daily.projects.len });
        try out.appendSlice(arena, head);
    }
    const srcs = try digest_store.aggregateSources(arena, daily.sessions);
    for (srcs) |src| {
        const part = try std.fmt.allocPrint(arena, " · {s}×{d}", .{ src.source_id, src.session_count });
        try out.appendSlice(arena, part);
    }
    return out.items;
}
```

memory_search.zig `searchDailyDir` 内：

(a) `files_scanned` 声明旁加来源聚合列表：

```zig
    const SourceCount = struct { source_id: []const u8, count: u32 };
    var source_counts: std.ArrayListUnmanaged(SourceCount) = .empty;
```

(b) 扫描循环 `for (daily.sessions) |s|` 体内、`source` 过滤**之前**（覆盖统计不受过滤影响）：

```zig
                const sc: *SourceCount = blk: {
                    for (source_counts.items) |*c| {
                        if (std.mem.eql(u8, c.source_id, s.source_id)) break :blk c;
                    }
                    try source_counts.append(arena, .{ .source_id = try arena.dupe(u8, s.source_id), .count = 0 });
                    break :blk &source_counts.items[source_counts.items.len - 1];
                };
                sc.count += 1;
```

(c) 构造头部行的公共函数（文件内新增）：

```zig
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
```

(d) no-match 分支改为在既有文案前拼上 `scanLine(...) ++ "\n"`（用 allocPrint 组合，保留既有 "No digest match..." 文本原样）；命中分支的 header 改为：

```zig
    const scan_info = try scanLine(arena, files_scanned, source_counts.items);
    const header = try std.fmt.allocPrint(arena, "{s}\n{d} match(es), showing {d}:\n\n", .{ scan_info, matches.items.len, shown });
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test 2>&1 | tail -3`
Expected: 通过

- [ ] **Step 5: 提交**

```bash
git add src/memory_viewer.zig src/agent_tools/memory_search.zig
git commit -m "Show per-source breakdown in Memory Center and memory_search"
```

---

### Task 3: collector 全量加载与定位（A 前置）

**Files:**
- Modify: `src/memory_digest/collector.zig`（新增两个 pub fn）
- Test: `src/memory_digest/collector.zig` 尾部

**Interfaces:**
- Consumes: 既有 `ingestJsonlBytes`、`provider_wispterm.parse`、`cursors_mod.Set.init`。
- Produces（Task 4/5 依赖，签名逐字）:
  - `pub fn locateSessionFile(gpa: std.mem.Allocator, alloc: std.mem.Allocator, roots: LocalRoots, provider: types.DigestProvider, session_id: []const u8) !?[]const u8` — 在 provider 根目录下按"basename 含 session_id"找文件，返回 alloc 拥有的绝对路径或 null。
  - `pub fn loadFullSessionByPath(gpa: std.mem.Allocator, alloc: std.mem.Allocator, provider: types.DigestProvider, path: []const u8) !?types.CollectedSession` — 读取并解析整个会话（start=0，全部消息），不触碰真实游标；文件缺失/解析失败/subagent 会话返回 null。

- [ ] **Step 1: 写失败测试**（collector.zig 尾部；fixture jsonl 参考本文件既有测试的写法——文件里已有 claude/codex 测试 fixture，逐字复用其最小 jsonl 内容构造）

```zig
test "collector: locateSessionFile finds codex file by session id substring" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("codex/2026/07/05");
    try tmp.dir.writeFile(.{ .sub_path = "codex/2026/07/05/rollout-2026-07-05T17-00-27-abc-123.jsonl", .data = "" });
    const root = try tmp.dir.realpathAlloc(a, "codex");
    defer a.free(root);

    const found = try locateSessionFile(a, arena, .{ .codex_sessions_dir = root }, .codex, "abc-123");
    try std.testing.expect(found != null);
    try std.testing.expect(std.mem.endsWith(u8, found.?, "rollout-2026-07-05T17-00-27-abc-123.jsonl"));

    const missing = try locateSessionFile(a, arena, .{ .codex_sessions_dir = root }, .codex, "zzz-999");
    try std.testing.expect(missing == null);
}

test "collector: loadFullSessionByPath returns all messages ignoring cursors" {
    // fixture：复用本文件既有 claude 测试的最小 jsonl 内容（含 2 条消息），
    // 写入 tmp 文件后调用 loadFullSessionByPath(.claude)，断言：
    //   sess.new_messages.len == 全部消息数
    //   sess.total_messages == 同值
    //   sess.source_file == 传入 path
    // 缺失路径返回 null：
    //   try std.testing.expect((try loadFullSessionByPath(a, arena, .claude, "/nonexistent.jsonl")) == null);
    // （实现者按既有 fixture 补全本测试体，断言如上三条 + null 例）
}
```

注意：第二个测试体要写完整可运行的代码——先读本文件既有测试（grep `test "collector` 定位）取其 jsonl fixture 字符串，不要凭空造格式。

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test 2>&1 | tail -5`
Expected: 编译错误 `use of undeclared identifier 'locateSessionFile'`

- [ ] **Step 3: 实现**（collector.zig 尾部测试之前）

```zig
/// Locate a local session file by provider + session id, for backfill of
/// daily entries that predate the source_file field. All three providers
/// name files with the session id in the basename.
pub fn locateSessionFile(
    gpa: std.mem.Allocator,
    alloc: std.mem.Allocator,
    roots: LocalRoots,
    provider: types.DigestProvider,
    session_id: []const u8,
) !?[]const u8 {
    if (session_id.len == 0) return null;
    const root = switch (provider) {
        .claude => roots.claude_projects_dir,
        .codex => roots.codex_sessions_dir,
        .wispterm => roots.wispterm_sessions_dir,
        else => null,
    } orelse return null;
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return null;
    defer dir.close();
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (true) {
        const ent = (walker.next() catch break) orelse break;
        if (ent.kind != .file) continue;
        if (std.mem.indexOf(u8, ent.basename, session_id) == null) continue;
        return try std.fs.path.join(alloc, &.{ root, ent.path });
    }
    return null;
}

/// Load one full session (all messages, cursor-independent) for backfill.
/// Returns null when the file is gone, unparseable, or a subagent session.
pub fn loadFullSessionByPath(
    gpa: std.mem.Allocator,
    alloc: std.mem.Allocator,
    provider: types.DigestProvider,
    path: []const u8,
) !?types.CollectedSession {
    const stat = std.fs.cwd().statFile(path) catch return null;
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, MAX_FILE_BYTES) catch return null;
    defer gpa.free(bytes);

    var scratch = cursors_mod.Set.init(gpa); // backfill never touches real cursors
    defer scratch.deinit();
    var list: std.ArrayListUnmanaged(types.CollectedSession) = .empty;
    defer list.deinit(alloc);

    switch (provider) {
        .claude, .codex => ingestJsonlBytes(gpa, alloc, &list, &scratch, provider, SOURCE_LOCAL, path, stat.size, stat.mtime, bytes, 0) catch return null,
        .wispterm => {
            var parse_arena = std.heap.ArenaAllocator.init(gpa);
            defer parse_arena.deinit();
            const sess = provider_wispterm.parse(parse_arena.allocator(), bytes) catch return null;
            try emit(alloc, &list, &scratch, .wispterm, SOURCE_LOCAL, path, stat.size, stat.mtime, .{
                .session_id = sess.session_id,
                .title = sess.title,
                .project_path = sess.cwd,
                .started_at_ms = sess.created_at_ms,
                .ended_at_ms = sess.updated_at_ms,
            }, sess.messages, 0);
        },
        else => return null,
    }
    if (list.items.len == 0) return null; // subagent or empty
    return list.items[0];
}
```

注意 `list.deinit(alloc)`：`toOwnedSlice` 未调用时列表内部数组由 alloc 持有；返回值 `list.items[0]` 的字段切片均在 alloc（调用者的 arena）上，值拷贝安全。若编译器对 defer deinit + return item 的组合报 use-after-free 疑虑（Zig 值语义，不会），以实际编译结果为准。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test 2>&1 | tail -3`
Expected: 通过

- [ ] **Step 5: 提交**

```bash
git add src/memory_digest/collector.zig
git commit -m "Add cursor-independent full-session loading for backfill"
```

---

### Task 4: backfill.zig 空洞扫描（A）

**Files:**
- Create: `src/memory_digest/backfill.zig`
- Modify: `src/test_fast.zig`（memory_digest 导入区加一行）
- Test: 新文件内

**Interfaces:**
- Consumes: `store.Daily`/`store.DailySession`。
- Produces（Task 5 依赖，签名逐字）:
  - `pub const Gap = struct { date: []const u8, provider: types.DigestProvider, session_id: []const u8, source_file: []const u8 };`
  - `pub fn findGaps(gpa: std.mem.Allocator, arena: std.mem.Allocator, memory_root: []const u8, limit: usize) ![]const Gap` — 扫描全部 daily 文件（文件名升序，稳定输出），收集 `summary==""` 且 `source_id=="local"` 的条目，最多 limit 个；provider 字符串未知值跳过。

- [ ] **Step 1: 创建带失败测试的新文件**

```zig
//! Backfill gap scan (spec 2026-07-09 §3): find daily sessions that were
//! collected before LLM summarization existed (or whose map failed) and
//! still have an empty summary, so the digest run can summarize them late.
const std = @import("std");
const types = @import("types.zig");
const store = @import("store.zig");

const MAX_DAILY_BYTES = 16 * 1024 * 1024;

test "backfill: findGaps returns local empty-summary sessions oldest-first with limit" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("daily");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    try tmp.dir.writeFile(.{ .sub_path = "daily/2026-06-30.json", .data =
        \\{"schema_version":1,"date":"2026-06-30","generated_at":1,"sessions":[
        \\{"provider":"codex","source_id":"local","session_id":"gap-1","project":"p","title":"t","message_count_new":5},
        \\{"provider":"claude","source_id":"ssh:CPU","session_id":"remote-1","project":"p","title":"t","message_count_new":2},
        \\{"provider":"claude","source_id":"local","session_id":"done-1","project":"p","title":"t","message_count_new":2,"summary":"已归纳"}]}
    });
    try tmp.dir.writeFile(.{ .sub_path = "daily/2026-07-06.json", .data =
        \\{"schema_version":1,"date":"2026-07-06","generated_at":1,"sessions":[
        \\{"provider":"codex","source_id":"local","session_id":"gap-2","project":"p","title":"t","message_count_new":9,"source_file":"/tmp/x.jsonl"},
        \\{"provider":"wispterm","source_id":"local","session_id":"gap-3","project":"p","title":"t","message_count_new":1}]}
    });

    const gaps = try findGaps(a, arena, root, 8);
    try std.testing.expectEqual(@as(usize, 3), gaps.len);
    try std.testing.expectEqualStrings("gap-1", gaps[0].session_id); // 旧日期在前
    try std.testing.expectEqualStrings("2026-06-30", gaps[0].date);
    try std.testing.expectEqual(types.DigestProvider.codex, gaps[0].provider);
    try std.testing.expectEqualStrings("", gaps[0].source_file);
    try std.testing.expectEqualStrings("gap-2", gaps[1].session_id);
    try std.testing.expectEqualStrings("/tmp/x.jsonl", gaps[1].source_file);
    try std.testing.expectEqualStrings("gap-3", gaps[2].session_id);

    const limited = try findGaps(a, arena, root, 2);
    try std.testing.expectEqual(@as(usize, 2), limited.len);
}

test "backfill: findGaps tolerates missing daily dir" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const gaps = try findGaps(a, arena_state.allocator(), "/nonexistent/backfill/root", 8);
    try std.testing.expectEqual(@as(usize, 0), gaps.len);
}
```

test_fast.zig 的 memory_digest 导入区（`_ = @import("memory_digest/remote.zig");` 附近）加：

```zig
    _ = @import("memory_digest/backfill.zig");
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test 2>&1 | tail -5`
Expected: 编译错误 `use of undeclared identifier 'findGaps'`

- [ ] **Step 3: 实现**（插在测试之前）

```zig
pub const Gap = struct {
    date: []const u8,
    provider: types.DigestProvider,
    session_id: []const u8,
    source_file: []const u8,
};

pub fn findGaps(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    memory_root: []const u8,
    limit: usize,
) ![]const Gap {
    var gaps: std.ArrayListUnmanaged(Gap) = .empty;
    const daily_dir = try std.fs.path.join(gpa, &.{ memory_root, "daily" });
    defer gpa.free(daily_dir);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        var dir = std.fs.cwd().openDir(daily_dir, .{ .iterate = true }) catch return &.{};
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (ent.kind != .file or ent.name.len != 15 or !std.mem.endsWith(u8, ent.name, ".json")) continue;
            try names.append(arena, try arena.dupe(u8, ent.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);

    outer: for (names.items) |name| {
        const path = try std.fs.path.join(gpa, &.{ daily_dir, name });
        defer gpa.free(path);
        const bytes = std.fs.cwd().readFileAlloc(arena, path, MAX_DAILY_BYTES) catch continue;
        const daily = std.json.parseFromSliceLeaky(store.Daily, arena, bytes, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        for (daily.sessions) |s| {
            if (s.summary.len != 0) continue;
            if (!std.mem.eql(u8, s.source_id, "local")) continue;
            const provider = std.meta.stringToEnum(types.DigestProvider, s.provider) orelse continue;
            try gaps.append(arena, .{
                .date = try arena.dupe(u8, daily.date),
                .provider = provider,
                .session_id = try arena.dupe(u8, s.session_id),
                .source_file = try arena.dupe(u8, s.source_file),
            });
            if (gaps.items.len >= limit) break :outer;
        }
    }
    return gaps.items;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test 2>&1 | tail -3`
Expected: 通过

- [ ] **Step 5: 提交**

```bash
git add src/memory_digest/backfill.zig src/test_fast.zig
git commit -m "Add backfill gap scan over daily digest artifacts"
```

---

### Task 5: backfill 接入归纳管道（A 收口）

**Files:**
- Modify: `src/memory_digest/run.zig`（runOnceWithLlm 的 map 循环之后、`summaries.saveToPath` 之前）
- Test: `src/memory_digest/run.zig`（参照本文件既有 stub-completer 测试的写法）

**Interfaces:**
- Consumes: Task 3 `collector.locateSessionFile`/`loadFullSessionByPath`、Task 4 `backfill.findGaps`、既有 `digest.summarizeSession`/`summaries`/`summaryKey`/`summarized*` 四列表。
- Produces: 无新接口。行为：每轮最多回填 8 个 local 空洞；store 已有非空 summary 直接复用不调 LLM；找不到原文件跳过；回填条目 `message_count_new=0`、date 取 gap.date、不推进游标。

- [ ] **Step 1: 写失败测试**（run.zig 尾部，参照本文件既有 runOnceWithLlm 测试的 stub completer/roots 组装方式——先 grep `test "` 通读既有测试再写，fixture 全部逐字复用既有模式）

测试场景（一个测试函数覆盖主链路）：

1. tmp 目录布置：`memory/daily/2026-06-30.json` 含一条 `provider=codex, source_id=local, session_id=<id>, summary=""` 的条目（无 source_file）；codex roots 目录下放一个 basename 含 `<id>` 的最小合法 codex jsonl fixture（复用 collector 既有 fixture 内容）。
2. 用既有测试的 stub completer（返回固定 JSON summary）调 `runOnce`。
3. 断言：
   - 重读 `daily/2026-06-30.json`：该条目 `summary` 非空、`source_file` 非空、`message_count_new` 保持原值（merge 加 0）。
   - summary store 文件含该 session 的记录。
   - 再跑一次 `runOnce`（同 stub）：LLM 调用计数不再增长（幂等——store 已有记录）。

```zig
test "run: backfill summarizes local empty-summary daily entries without touching cursors" {
    // （实现者按上述场景写完整代码，组装方式逐字参照本文件既有
    //   runOnceWithLlm/stub completer 测试；断言三组如上。）
}
```

注意：这个测试体必须写完整可运行代码——本文件已有同构测试可整段借用组装逻辑，禁止留空壳。

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test 2>&1 | tail -5`
Expected: 断言失败（backfill 尚未接入，summary 仍为空）

- [ ] **Step 3: 实现**

run.zig 顶部 import 区加：

```zig
const backfill_mod = @import("backfill.zig");
```

文件内常量区加：

```zig
/// Max historical empty-summary sessions summarized per run (spec §3).
/// ponytail: fixed cap, make it a config key only if real backlogs demand.
const BACKFILL_LIMIT: usize = 8;
```

runOnceWithLlm 中 map 循环（`for (collected, 0..) |s, i| { ... }`）结束之后、`try summaries.saveToPath(...)` 之前插入：

```zig
    // Backfill (spec 2026-07-09 §3): summarize historical daily entries that
    // still have an empty summary (collected before M2, or map previously
    // failed). Never advances cursors; merges via the same summarized lists.
    const gaps = backfill_mod.findGaps(gpa, arena, opts.memory_root, BACKFILL_LIMIT) catch |err| blk: {
        std.log.warn("memory_digest: backfill scan failed: {s}", .{@errorName(err)});
        break :blk &.{};
    };
    for (gaps) |gap| {
        const key = try summaryKey(arena, "local", gap.provider, gap.session_id);
        // 本轮增量刚处理过（或历史已归纳但 daily 写失败的窗口）→ 直接复用。
        var reused: ?*store.SummaryRecord = summaries.find(key);
        var sess: ?types.CollectedSession = null;
        if (reused == null) {
            const path = if (gap.source_file.len != 0)
                gap.source_file
            else
                (collector.locateSessionFile(gpa, arena, opts.roots, gap.provider, gap.session_id) catch null) orelse {
                    std.log.warn("memory_digest: backfill source missing for {s}:{s}", .{ @tagName(gap.provider), gap.session_id });
                    continue;
                };
            sess = (collector.loadFullSessionByPath(gpa, arena, gap.provider, path) catch null) orelse {
                std.log.warn("memory_digest: backfill load failed for {s}:{s}", .{ @tagName(gap.provider), gap.session_id });
                continue;
            };
        }

        var summary_text: []const u8 = undefined;
        var topics: []const []const u8 = undefined;
        var outcome: []const u8 = undefined;
        var artifacts: []const store.Artifact = undefined;
        var source_file: []const u8 = gap.source_file;
        if (reused) |rec| {
            summary_text = rec.summary;
            topics = rec.topics;
            outcome = rec.outcome;
            artifacts = rec.artifacts;
        } else {
            const s = sess.?;
            const result = digest.summarizeSession(arena, gpa, completer, s, null, .{
                .max_chars_per_message = opts.max_chars_per_message,
                .input_budget_chars = opts.input_budget_chars,
            }) catch |err| {
                std.log.warn("memory_digest: backfill map failed for {s}:{s}: {s}", .{ @tagName(gap.provider), gap.session_id, @errorName(err) });
                sessions_failed += 1;
                continue;
            };
            summary_text = result.summary;
            topics = result.topics;
            outcome = result.outcome;
            artifacts = result.artifacts;
            source_file = s.source_file;
            try summaries.put(.{
                .key = key,
                .date = gap.date,
                .summary = result.summary,
                .topics = result.topics,
                .outcome = result.outcome,
                .artifacts = result.artifacts,
            });
            sessions_summarized += 1;
        }

        var slug_buf: [64]u8 = undefined;
        const project_path = if (sess) |s| s.project_path else "";
        try summarized.append(arena, .{
            .provider = @tagName(gap.provider),
            .source_id = "local",
            .session_id = gap.session_id,
            .project = try arena.dupe(u8, types.projectSlug(project_path, &slug_buf)),
            .title = if (sess) |s| s.title else "",
            .message_count_new = 0, // merge keeps the original count
            .summary = summary_text,
            .topics = topics,
            .outcome = outcome,
            .artifacts = artifacts,
            .source_file = source_file,
        });
        try summarized_dates.append(arena, gap.date);
        try summarized_paths.append(arena, project_path);
        try summarized_source_ids.append(arena, "local");
    }
```

细节以实际代码为准的点：`SummaryRecord` 字段名（读 store.zig:314 起）；`sessions_summarized/sessions_failed` 为既有 var；merge 分支中 title/project 为空串时 mergeDailyWithExisting 用**新值覆盖旧值**——检查其匹配分支：project/title 直接取 `n.`，回填条目若 title 为空会抹掉旧 title，**必须**在 merge 语义处理：回填复用（reused）路径拿不到 title/project_path，为避免抹除，向 `summarized.append` 传 `.title = ""`/`.project = "unassigned"` 前先确认 mergeDailyWithExisting 对空新值的行为——若直接覆盖，则在本任务顺带把 merge 的 title/project 改为"新值为空取旧值"（与 source_file 同款三目），并补一条断言进 Task 5 测试。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test 2>&1 | tail -3`
Expected: 通过（含幂等断言）

- [ ] **Step 5: 提交**

```bash
git add src/memory_digest/run.zig
git commit -m "Backfill empty-summary daily sessions through the LLM map path"
```

---

### Task 6: 采集诊断 detail（B）

**Files:**
- Modify: `src/memory_digest/collector.zig`（Result 加 detail + per-provider 计数）
- Modify: `src/memory_digest/remote.zig`（CollectResult 加 detail：per-provider 文件数、no-stamps/BSD 标记、目录缺失）
- Modify: `src/memory_digest/run.zig:223-266`（collectAllSources 把两侧 detail 写进 SourceStatus.detail，与 oversize 信息合并）
- Modify: `src/memory_digest/sources.zig:27`（sshExec 失败时 log stderr 摘要）
- Test: collector/remote 既有测试内扩展断言

**Interfaces:**
- Consumes: `remote_file.sshExecCaptureFullCapped`（stderr+exit，src/platform/remote_file.zig:100）。
- Produces: `collector.Result.detail: []const u8`（arena 拥有，如 `"claude: 3 files; codex: 1 files; wispterm: 2 files"`）；`remote.CollectResult.detail: []const u8`（如 `"claude: 12 files; codex: 0 files"`、`"claude: no-stamps(BSD?)"`）。schema 不变，纯 detail 文本。

- [ ] **Step 1: 写失败测试**

collector.zig 既有 collectLocal 测试（grep 定位）追加断言：

```zig
    try std.testing.expect(std.mem.indexOf(u8, result.detail, "claude:") != null);
```

remote.zig 既有打桩测试（248 行起）追加断言：

```zig
    try std.testing.expect(std.mem.indexOf(u8, r.detail, "claude:") != null);
```

BSD find（no stamps）打桩测试（329 行附近既有）追加：

```zig
    try std.testing.expect(std.mem.indexOf(u8, r.detail, "no-stamps") != null);
```

（既有测试若解构为 `_ =`，改为具名变量。detail 生命周期 = 各自 arena。）

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test 2>&1 | tail -5`
Expected: 编译错误（Result/CollectResult 无 detail 字段）

- [ ] **Step 3: 实现**

(a) collector.zig：`Result` 加 `detail: []const u8 = ""`；`Ctx` 加 `claude_files: u32 = 0, codex_files: u32 = 0, wispterm_files: u32 = 0`；三个 collect* 每处理一个候选文件计数 +1（claude/codex 在 collectJsonlFile 按 provider 分支计数，wispterm 在其循环内）；collectLocal 末尾：

```zig
    result.detail = try std.fmt.allocPrint(result.arena.allocator(), "claude: {d} files; codex: {d} files; wispterm: {d} files", .{ ctx.claude_files, ctx.codex_files, ctx.wispterm_files });
```

(b) remote.zig：`CollectResult` 加 `detail: []const u8 = ""`；collectRemote 内部对每个 provider 记 find 返回的文件数；既有 "no stamps (BSD find?)" warn 分支同时把 `"{provider}: no-stamps(BSD?)"` 计入 detail；探测到远端目录不存在（find 对不存在目录的输出/退出处理，以实际代码分支为准）记 `"{provider}: no dir"`。detail 用传入的 arena 分配。

(c) run.zig collectAllSources：

```zig
    try sources.append(arena, .{
        .source_id = "local",
        .status = "ok",
        .detail = try arena.dupe(u8, local.detail),
        .sessions_collected = @intCast(local.sessions.len),
    });
```

远端成功分支 detail 改为合并：

```zig
            const detail = if (r.oversize_skipped > 0)
                try std.fmt.allocPrint(arena, "{s}; oversize_skipped={d}", .{ r.detail, r.oversize_skipped })
            else
                r.detail;
```

(d) sources.zig sshExec（27 行）改用 `sshExecCaptureFullCapped`，非零退出时：

```zig
    std.log.warn("memory_digest: remote exec failed exit={d} stderr={s}", .{ cap.exit_code, cap.stderr[0..@min(cap.stderr.len, 200)] });
```

然后返回错误（保持既有错误语义；SshCapture 字段名以 remote_file.zig:96 实际定义为准）。成功时返回 stdout，行为不变。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test 2>&1 | tail -3`
Expected: 通过

- [ ] **Step 5: 提交**

```bash
git add src/memory_digest/collector.zig src/memory_digest/remote.zig src/memory_digest/run.zig src/memory_digest/sources.zig
git commit -m "Record per-provider collection diagnostics in run records"
```

---

### Task 7: 收尾验证

**Files:** 无新改动；验证 + 可能的 fmt 修正

- [ ] **Step 1: zig fmt（CI 门禁）**

Run: `zig fmt build.zig src`
Expected: 无输出或列出已修复文件

- [ ] **Step 2: fast 套件**

Run: `zig build test > /tmp/fast.log 2>&1; echo "exit=$?"`
Expected: exit=0

- [ ] **Step 3: macOS 原生 full 套件**

Run: `zig build test-full -Dtarget=aarch64-macos > /tmp/full.log 2>&1; echo "exit=$?"`
Expected: exit=0，或唯一失败为既有抖动 `tool_import runArgvProbe`（与本分支无关，可忽略）

- [ ] **Step 4: 如 fmt 有改动补提交**

```bash
git add -u && git commit -m "zig fmt" || true
```

---

## Self-Review 记录

- **Spec 覆盖**：§3 回填全流程（扫描/定位/归纳/回写/幂等/上限/游标不动）→ Task 3/4/5；§4 诊断（local+remote detail、home 失败 stderr）→ Task 6；§5 C1/C2/C3 → Task 1/2；§6 测试 → 各任务内嵌 + Task 7。真机验证（下一次 digest 运行看 runs.json detail、回填后 memory_search 搜 codex）留给用户/合并后。
- **占位符**：Task 3 第二个测试与 Task 5 测试标注"实现者按既有 fixture 补全"并给出断言清单——保留为受控例外（fixture 内容必须逐字取自既有测试，plan 无法预知其内容而不复制整个文件）；其余代码块完整。
- **类型一致性**：`locateSessionFile`/`loadFullSessionByPath`/`findGaps`/`Gap` 的签名在 Interfaces 与实现代码一致；Task 5 消费的名字与 Task 3/4 Produces 逐字一致；`Result.detail`/`CollectResult.detail` 两处命名统一。
- **已知风险点已显式标注**：Task 5 merge 空 title/project 覆盖问题（要求实现者核实并带三目修复+断言）；Task 6 SshCapture 字段名以实际定义为准。
