# Memory Digest M1（本地采集骨架）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec（docs/superpowers/specs/2026-07-07-ai-memory-digest-design.md）的 M1：本地三源（WispTerm copilot / Claude Code / Codex）增量采集 + 无 LLM 的日报/索引 JSON 产物 + 一个真机可跑的 dev CLI。

**Architecture:** 新模块 `src/memory_digest/`（types → provider_wispterm → cursors → store → collector → run），复用 `src/terminal_agents/sessions/` 的 provider 解析器与类型、`src/platform/atomic_file.zig` 原子写。纯 std，无新依赖。M1 不含 LLM、不含远程源、不含调度。

**Tech Stack:** Zig（仓库既有版本）；测试进 fast 套件（`zig build test`），文件在 `src/test_fast.zig` 的 import 列表注册。

## Global Constraints

- 分支：从 `docs/ai-memory-digest-design` 切出 `feat/memory-digest-m1`，所有任务在该分支提交。
- 每次 commit 前必须跑 `zig fmt build.zig src`（CI 的 "Zig fast tests / Linux" 先跑 `zig fmt --check`，本地 test 不含 fmt 检查）。
- 测试命令统一 `zig build test`（fast 原生逻辑套件，本机可直接跑）；**不要跑裸 `zig build`**（默认目标是 Windows）。
- 新测试命名前缀 `memory_digest_<file>:`，风格对齐 `ai_history_provider_claude: ...`。
- 每个新 .zig 文件创建的同一任务内，在 `src/test_fast.zig` 的 `_ = @import("terminal_agents/sessions/cache.zig");`（约 301 行）之后追加对应 `_ = @import("memory_digest/<file>.zig");` 行。
- 不新增第三方依赖；JSON 一律 `std.json`；写文件一律 `platform/atomic_file.writeFileReplaceSafe`。
- 内存归属约定：collector/run 的输出全部挂在调用方传入的 arena 上，provider 解析的中间产物用 gpa 并及时 free（跟随 provider_claude 的 freeMetadata/freeTranscript 用法）。
- commit 信息用 conventional commits，结尾带 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。

---

### Task 0: 建分支

- [ ] **Step 1: 从 spec 分支切出实现分支**

```bash
git checkout docs/ai-memory-digest-design && git checkout -b feat/memory-digest-m1
```

Expected: `切换到一个新分支 'feat/memory-digest-m1'`

---

### Task 1: `src/memory_digest/types.zig` — 共享类型与项目 slug

**Files:**
- Create: `src/memory_digest/types.zig`
- Modify: `src/test_fast.zig`（import 列表加一行）

**Interfaces:**
- Consumes: `src/terminal_agents/sessions/types.zig` 的 `TranscriptMessage`、`ProviderId`。
- Produces（后续任务全部依赖）:
  - `pub const DigestProvider = enum { wispterm, claude, codex, reasonix }`
  - `pub const CollectedSession = struct { provider: DigestProvider, source_id: []const u8, session_id: []const u8, title: []const u8, project_path: []const u8, started_at_ms: i64, ended_at_ms: i64, total_messages: u32, new_messages: []ai_types.TranscriptMessage, source_file: []const u8 }`
  - `pub const UNASSIGNED_SLUG = "unassigned"`
  - `pub fn projectSlug(path: []const u8, buf: []u8) []const u8`

Zig 的测试与实现同文件，本计划各任务统一按"写完整文件（实现+测试在底部）→ 注册 → 跑测试 → commit"执行；测试先于实现单独提交无意义。

- [ ] **Step 1: 写完整文件（实现+测试）**

```zig
//! Shared types for the memory digest pipeline. Spec:
//! docs/superpowers/specs/2026-07-07-ai-memory-digest-design.md
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");

pub const SCHEMA_VERSION: u32 = 1;

/// Providers the digest scans. Superset of the AI-history browser's
/// ProviderId: adds WispTerm's own copilot history.
pub const DigestProvider = enum {
    wispterm,
    claude,
    codex,
    reasonix,
};

/// One session carrying only the messages that are new since the last run.
/// All slices are owned by the collector's arena.
pub const CollectedSession = struct {
    provider: DigestProvider,
    source_id: []const u8, // "local" | "wsl:<distro>" | "ssh:<profile>"
    session_id: []const u8,
    title: []const u8,
    /// cwd of the session; "" = unknown → UNASSIGNED_SLUG.
    project_path: []const u8,
    started_at_ms: i64,
    ended_at_ms: i64,
    total_messages: u32,
    new_messages: []ai_types.TranscriptMessage,
    source_file: []const u8,
};

pub const UNASSIGNED_SLUG = "unassigned";

/// Derive a project slug from a cwd path: last path component, lowercased,
/// [a-z0-9._-] kept, everything else mapped to '-'. Empty → "unassigned".
/// ponytail: two different paths with the same dirname share a slug; hash
/// suffix disambiguation lands with project.json in M2 (spec §10).
pub fn projectSlug(path: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, path, "/\\");
    if (trimmed.len == 0) return UNASSIGNED_SLUG;
    const base = if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i|
        trimmed[i + 1 ..]
    else
        trimmed;
    if (base.len == 0) return UNASSIGNED_SLUG;
    const n = @min(base.len, buf.len);
    for (base[0..n], 0..) |c, i| {
        const lower = std.ascii.toLower(c);
        buf[i] = if (std.ascii.isAlphanumeric(lower) or lower == '.' or lower == '_' or lower == '-')
            lower
        else
            '-';
    }
    return buf[0..n];
}

test "memory_digest_types: slug takes last component lowercased" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("phantty", projectSlug("/Users/me/Documents/Code/Phantty", &buf));
}

test "memory_digest_types: slug handles windows paths and trailing separators" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("proj", projectSlug("C:\\code\\Proj\\", &buf));
    try std.testing.expectEqualStrings("proj", projectSlug("/home/me/proj///", &buf));
}

test "memory_digest_types: slug maps unsafe chars and empty to unassigned" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("my-dir-1", projectSlug("/tmp/My Dir(1)", &buf));
    try std.testing.expectEqualStrings("unassigned", projectSlug("", &buf));
    try std.testing.expectEqualStrings("unassigned", projectSlug("///", &buf));
}
```

- [ ] **Step 2: 注册进 fast 套件**

在 `src/test_fast.zig` 的 `_ = @import("terminal_agents/sessions/cache.zig");` 行后加：

```zig
    _ = @import("memory_digest/types.zig");
```

- [ ] **Step 3: 跑测试**

Run: `zig build test`
Expected: PASS（含 3 个 memory_digest_types 测试）

- [ ] **Step 4: fmt + commit**

```bash
zig fmt build.zig src && git add -A && git commit -m "feat(memory-digest): shared types and project slug

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `src/memory_digest/provider_wispterm.zig` — 解析自家 copilot 历史

**Files:**
- Create: `src/memory_digest/provider_wispterm.zig`
- Modify: `src/test_fast.zig`

**Interfaces:**
- Consumes: `ai_types.TranscriptMessage`；磁盘格式 = `src/agent/history.zig` 的 SessionRecord JSON（`agent-history/sessions/session-*.json`）。
- Produces:
  - `pub const MAX_SESSION_BYTES = 32 * 1024 * 1024`
  - `pub const Session = struct { session_id: []const u8, title: []const u8, created_at_ms: i64, updated_at_ms: i64, messages: []ai_types.TranscriptMessage }`
  - `pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Session` — 输出全部从 `alloc` 分配（调用方传 arena 整体释放）。

安全要求（spec §7）：`api_key`/`base_url` 字段绝不映射进输出——靠 RawSession 结构不声明这两个字段 + `ignore_unknown_fields` 实现。

- [ ] **Step 1: 写完整文件（实现+测试）**

```zig
//! Parses WispTerm's own copilot chat history (agent-history/sessions/*.json,
//! written by src/agent/history.zig) into TranscriptMessage form for the
//! memory digest. Secret-bearing fields (api_key, base_url) are never mapped
//! out (spec §7): RawSession simply does not declare them.
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");

pub const MAX_SESSION_BYTES = 32 * 1024 * 1024; // mirrors agent/history.zig

const RawMessage = struct {
    role: []const u8 = "user",
    content: []const u8 = "",
};

const RawSession = struct {
    session_id: []const u8 = "",
    title: []const u8 = "",
    created_at: i64 = 0,
    updated_at: i64 = 0,
    messages: []const RawMessage = &.{},
};

pub const Session = struct {
    session_id: []const u8,
    title: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    messages: []ai_types.TranscriptMessage,
};

/// All output memory comes from `alloc`; hand in an arena and free wholesale.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Session {
    const parsed = try std.json.parseFromSlice(RawSession, alloc, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const raw = parsed.value;

    const messages = try alloc.alloc(ai_types.TranscriptMessage, raw.messages.len);
    for (raw.messages, 0..) |m, i| {
        const is_tool = std.mem.eql(u8, m.role, "tool");
        messages[i] = .{
            .role = if (is_tool) .tool else if (std.mem.eql(u8, m.role, "assistant")) .assistant else .user,
            .kind = if (is_tool) .tool_result else .normal,
            .content = try alloc.dupe(u8, m.content),
            // ponytail: no per-message timestamp on disk until spec §10/M4
            // lands; messages inherit the session's updated_at.
            .timestamp_ms = raw.updated_at,
        };
    }
    return .{
        .session_id = try alloc.dupe(u8, raw.session_id),
        .title = try alloc.dupe(u8, raw.title),
        .created_at_ms = raw.created_at,
        .updated_at_ms = raw.updated_at,
        .messages = messages,
    };
}

test "memory_digest_provider_wispterm: parses session and ignores secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"session_id":"session-1-1","title":"Copilot","base_url":"https://x.example","api_key":"sk-SECRET",
        \\ "model":"m","protocol":"chat_completions","system_prompt":"","thinking_enabled":false,
        \\ "reasoning_effort":"","stream":true,"agent_enabled":false,"created_at":1782311875112,
        \\ "updated_at":1782311885976,
        \\ "messages":[
        \\   {"role":"user","content":"hi","reasoning":null},
        \\   {"role":"assistant","content":"hello","usage_footer":"1 token"},
        \\   {"role":"tool","content":"ls output","tool_name":"run"}
        \\ ]}
    ;
    const sess = try parse(arena.allocator(), json);
    try std.testing.expectEqualStrings("session-1-1", sess.session_id);
    try std.testing.expectEqual(@as(i64, 1782311875112), sess.created_at_ms);
    try std.testing.expectEqual(@as(usize, 3), sess.messages.len);
    try std.testing.expectEqual(ai_types.MessageRole.user, sess.messages[0].role);
    try std.testing.expectEqual(ai_types.MessageRole.assistant, sess.messages[1].role);
    try std.testing.expectEqual(ai_types.MessageRole.tool, sess.messages[2].role);
    try std.testing.expectEqual(ai_types.MessageKind.tool_result, sess.messages[2].kind);
    try std.testing.expectEqual(@as(i64, 1782311885976), sess.messages[0].timestamp_ms);
}

test "memory_digest_provider_wispterm: empty and unknown fields tolerated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sess = try parse(arena.allocator(), "{\"future_field\":123}");
    try std.testing.expectEqual(@as(usize, 0), sess.messages.len);
    try std.testing.expectEqualStrings("", sess.session_id);
}
```

注意：若 `zig build test` 报 RawMessage 里未知字段（`reasoning` 等为 null 的键）解析失败，是因为 RawMessage 也需要 `ignore_unknown_fields` 生效——该选项对嵌套结构全局生效，无需额外处理；若真实报错，检查 JSON 字面量转义。

- [ ] **Step 2: 注册 + 跑测试**

`src/test_fast.zig` 加 `_ = @import("memory_digest/provider_wispterm.zig");`
Run: `zig build test`
Expected: PASS

- [ ] **Step 3: fmt + commit**

```bash
zig fmt build.zig src && git add -A && git commit -m "feat(memory-digest): wispterm copilot history parser

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `src/memory_digest/cursors.zig` — 增量游标

**Files:**
- Create: `src/memory_digest/cursors.zig`
- Modify: `src/test_fast.zig`

**Interfaces:**
- Consumes: `types.DigestProvider`、`platform/atomic_file.writeFileReplaceSafe`。
- Produces:
  - `pub const Entry = struct { source_id: []const u8, provider: types.DigestProvider, file: []const u8, size: u64, mtime_ns: i128, processed_messages: u32 }`
  - `pub const Set = struct { ... }`，方法：
    - `pub fn init(gpa: std.mem.Allocator) Set`
    - `pub fn deinit(self: *Set) void`
    - `pub fn pendingFrom(self: *Set, source_id: []const u8, provider: types.DigestProvider, file: []const u8, size: u64, mtime_ns: i128) ?u32` — `null`=stamp 未变跳过；否则返回已处理消息数（新文件为 0）
    - `pub fn update(self: *Set, source_id: []const u8, provider: types.DigestProvider, file: []const u8, size: u64, mtime_ns: i128, processed_messages: u32) !void`
    - `pub fn loadFromPath(gpa: std.mem.Allocator, path: []const u8) !Set`（文件不存在/损坏 → 空集）
    - `pub fn saveToPath(self: *Set, gpa: std.mem.Allocator, path: []const u8) !void`（原子写）

- [ ] **Step 1: 写完整文件（实现+测试）**

```zig
//! Incremental scan cursors (spec §6): one entry per (source, provider,
//! file) recording FileStamp(size+mtime_ns) plus how many transcript
//! messages have been processed. The on-disk file only advances after
//! artifacts were written — run.zig saves at the end of a successful run.
const std = @import("std");
const atomic_file = @import("../platform/atomic_file.zig");
const types = @import("types.zig");

const MAX_CURSOR_BYTES = 16 * 1024 * 1024;

pub const Entry = struct {
    source_id: []const u8,
    provider: types.DigestProvider,
    file: []const u8,
    size: u64 = 0,
    mtime_ns: i128 = 0,
    processed_messages: u32 = 0,
};

const FileShape = struct {
    schema_version: u32 = 1,
    entries: []const Entry = &.{},
};

pub const Set = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) Set {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Set) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn find(self: *Set, source_id: []const u8, provider: types.DigestProvider, file: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.provider == provider and
                std.mem.eql(u8, e.source_id, source_id) and
                std.mem.eql(u8, e.file, file)) return e;
        }
        return null;
    }

    /// null → stamp unchanged, skip the file. Otherwise how many messages
    /// were already processed (0 for unseen files).
    pub fn pendingFrom(self: *Set, source_id: []const u8, provider: types.DigestProvider, file: []const u8, size: u64, mtime_ns: i128) ?u32 {
        const e = self.find(source_id, provider, file) orelse return 0;
        if (e.size == size and e.mtime_ns == mtime_ns) return null;
        return e.processed_messages;
    }

    pub fn update(self: *Set, source_id: []const u8, provider: types.DigestProvider, file: []const u8, size: u64, mtime_ns: i128, processed_messages: u32) !void {
        if (self.find(source_id, provider, file)) |e| {
            e.size = size;
            e.mtime_ns = mtime_ns;
            e.processed_messages = processed_messages;
            return;
        }
        const alloc = self.arena.allocator();
        try self.entries.append(alloc, .{
            .source_id = try alloc.dupe(u8, source_id),
            .provider = provider,
            .file = try alloc.dupe(u8, file),
            .size = size,
            .mtime_ns = mtime_ns,
            .processed_messages = processed_messages,
        });
    }

    pub fn loadFromPath(gpa: std.mem.Allocator, path: []const u8) !Set {
        var set = Set.init(gpa);
        errdefer set.deinit();
        const bytes = std.fs.cwd().readFileAlloc(gpa, path, MAX_CURSOR_BYTES) catch |err| switch (err) {
            error.FileNotFound => return set,
            else => return err,
        };
        defer gpa.free(bytes);
        // Corrupt cursor file → start fresh rather than wedging every run.
        const parsed = std.json.parseFromSlice(FileShape, gpa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return set;
        defer parsed.deinit();
        for (parsed.value.entries) |e| {
            try set.update(e.source_id, e.provider, e.file, e.size, e.mtime_ns, e.processed_messages);
        }
        return set;
    }

    pub fn saveToPath(self: *Set, gpa: std.mem.Allocator, path: []const u8) !void {
        const shape: FileShape = .{ .entries = self.entries.items };
        const json = try std.json.Stringify.valueAlloc(gpa, shape, .{});
        defer gpa.free(json);
        try atomic_file.writeFileReplaceSafe(path, json);
    }
};

test "memory_digest_cursors: unseen file starts at zero, unchanged stamp skips" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    try std.testing.expectEqual(@as(?u32, 0), set.pendingFrom("local", .claude, "/a.jsonl", 10, 100));
    try set.update("local", .claude, "/a.jsonl", 10, 100, 5);
    try std.testing.expectEqual(@as(?u32, null), set.pendingFrom("local", .claude, "/a.jsonl", 10, 100));
    try std.testing.expectEqual(@as(?u32, 5), set.pendingFrom("local", .claude, "/a.jsonl", 12, 101));
}

test "memory_digest_cursors: keys distinguish provider and file" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    try set.update("local", .claude, "/a.jsonl", 10, 100, 5);
    try std.testing.expectEqual(@as(?u32, 0), set.pendingFrom("local", .codex, "/a.jsonl", 10, 100));
    try std.testing.expectEqual(@as(?u32, 0), set.pendingFrom("ssh:hk", .claude, "/a.jsonl", 10, 100));
}

test "memory_digest_cursors: save and load roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const file = try std.fs.path.join(std.testing.allocator, &.{ path, "cursors.json" });
    defer std.testing.allocator.free(file);

    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    try set.update("local", .wispterm, "/s.json", 42, 7_000_000_000, 3);
    try set.saveToPath(std.testing.allocator, file);

    var loaded = try Set.loadFromPath(std.testing.allocator, file);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(?u32, 3), loaded.pendingFrom("local", .wispterm, "/s.json", 1, 1));
    try std.testing.expectEqual(@as(?u32, null), loaded.pendingFrom("local", .wispterm, "/s.json", 42, 7_000_000_000));
}

test "memory_digest_cursors: missing or corrupt file loads empty" {
    var loaded = try Set.loadFromPath(std.testing.allocator, "/nonexistent/cursors.json");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.entries.items.len);
}
```

- [ ] **Step 2: 注册 + 跑测试**

`src/test_fast.zig` 加 `_ = @import("memory_digest/cursors.zig");`
Run: `zig build test`
Expected: PASS

- [ ] **Step 3: fmt + commit**

```bash
zig fmt build.zig src && git add -A && git commit -m "feat(memory-digest): incremental scan cursors

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `src/memory_digest/store.zig` + `dirs.memoryDir()` — 产物写入

**Files:**
- Create: `src/memory_digest/store.zig`
- Modify: `src/platform/dirs.zig`（`agentHistoryDir` 附近加 `memoryDir`）
- Modify: `src/test_fast.zig`

**Interfaces:**
- Produces:
  - `dirs.zig`: `pub fn memoryDir(allocator: std.mem.Allocator) ![]const u8`（= `pathInConfigDir(allocator, "memory")`）
  - `store.zig`:
    - `pub const DailySession = struct { provider: []const u8, source_id: []const u8, session_id: []const u8, project: []const u8, title: []const u8, message_count_new: u32 }`
    - `pub const Daily = struct { schema_version: u32 = 1, date: []const u8, generated_at: i64, sessions: []const DailySession = &.{} }`
    - `pub const IndexProject = struct { slug: []const u8, last_active: []const u8, session_count: u32 }`
    - `pub const Index = struct { schema_version: u32 = 1, generated_at: i64, days: []const []const u8, projects: []const IndexProject = &.{} }`
    - `pub fn formatDate(date_key: u32, buf: *[10]u8) []const u8`（`20260707` → `"2026-07-07"`）
    - `pub fn writeDaily(gpa: std.mem.Allocator, memory_root: []const u8, daily: Daily) !void`（写 `<root>/daily/<date>.json`，自动建目录，原子写，重复写=幂等覆盖）
    - `pub fn writeIndex(gpa: std.mem.Allocator, memory_root: []const u8, index: Index) !void`（写 `<root>/index.json`）

- [ ] **Step 1: dirs.zig 加 memoryDir**

在 `src/platform/dirs.zig` 的 `agentHistoryDir` 函数后加：

```zig
pub fn memoryDir(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "memory");
}
```

- [ ] **Step 2: 写 store.zig 完整文件（实现+测试）**

```zig
//! JSON artifact writes for the memory digest (spec §9). M1 writes the
//! daily raw-session listing and the index; LLM summary fields arrive in
//! M2. Everything goes through atomic replace so a crash never leaves a
//! half-written artifact.
const std = @import("std");
const atomic_file = @import("../platform/atomic_file.zig");

pub const SCHEMA_VERSION: u32 = 1;

pub const DailySession = struct {
    provider: []const u8,
    source_id: []const u8,
    session_id: []const u8,
    project: []const u8,
    title: []const u8,
    message_count_new: u32,
};

pub const Daily = struct {
    schema_version: u32 = SCHEMA_VERSION,
    date: []const u8, // "2026-07-07"
    generated_at: i64,
    sessions: []const DailySession = &.{},
};

pub const IndexProject = struct {
    slug: []const u8,
    last_active: []const u8,
    session_count: u32,
};

pub const Index = struct {
    schema_version: u32 = SCHEMA_VERSION,
    generated_at: i64,
    days: []const []const u8,
    projects: []const IndexProject = &.{},
};

/// Packed YYYYMMDD (ai_types.DateKey) → "YYYY-MM-DD".
pub fn formatDate(date_key: u32, buf: *[10]u8) []const u8 {
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        date_key / 10000,
        date_key / 100 % 100,
        date_key % 100,
    }) catch unreachable;
    return buf[0..10];
}

pub fn writeDaily(gpa: std.mem.Allocator, memory_root: []const u8, daily: Daily) !void {
    const dir = try std.fs.path.join(gpa, &.{ memory_root, "daily" });
    defer gpa.free(dir);
    try std.fs.cwd().makePath(dir);
    const name = try std.fmt.allocPrint(gpa, "{s}.json", .{daily.date});
    defer gpa.free(name);
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    try writeJson(gpa, path, daily);
}

pub fn writeIndex(gpa: std.mem.Allocator, memory_root: []const u8, index: Index) !void {
    try std.fs.cwd().makePath(memory_root);
    const path = try std.fs.path.join(gpa, &.{ memory_root, "index.json" });
    defer gpa.free(path);
    try writeJson(gpa, path, index);
}

fn writeJson(gpa: std.mem.Allocator, path: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    try atomic_file.writeFileReplaceSafe(path, json);
}

test "memory_digest_store: formatDate renders packed keys" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("2026-07-07", formatDate(20260707, &buf));
    try std.testing.expectEqualStrings("2026-01-02", formatDate(20260102, &buf));
}

test "memory_digest_store: writeDaily creates dirs and overwrites idempotently" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const daily: Daily = .{
        .date = "2026-07-07",
        .generated_at = 1,
        .sessions = &.{.{
            .provider = "claude",
            .source_id = "local",
            .session_id = "s1",
            .project = "phantty",
            .title = "t",
            .message_count_new = 2,
        }},
    };
    try writeDaily(allocator, root, daily);
    try writeDaily(allocator, root, daily); // idempotent overwrite

    const bytes = try tmp.dir.readFileAlloc(allocator, "daily/2026-07-07.json", 1 << 20);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"session_id\": \"s1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"schema_version\": 1") != null);
}

test "memory_digest_store: writeIndex lands at root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try writeIndex(allocator, root, .{
        .generated_at = 1,
        .days = &.{"2026-07-07"},
        .projects = &.{.{ .slug = "phantty", .last_active = "2026-07-07", .session_count = 3 }},
    });
    const bytes = try tmp.dir.readFileAlloc(allocator, "index.json", 1 << 20);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"phantty\"") != null);
}
```

- [ ] **Step 3: 注册 + 跑测试**

`src/test_fast.zig` 加 `_ = @import("memory_digest/store.zig");`
Run: `zig build test`
Expected: PASS

- [ ] **Step 4: fmt + commit**

```bash
zig fmt build.zig src && git add -A && git commit -m "feat(memory-digest): artifact store and memoryDir

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `src/memory_digest/collector.zig` — 本地增量采集

**Files:**
- Create: `src/memory_digest/collector.zig`
- Modify: `src/test_fast.zig`

**Interfaces:**
- Consumes: Task 1-3 全部产出；`provider_claude/codex` 的 `parseMetadata`/`parseTranscript`/`freeMetadata`/`freeTranscript`（签名：`parseMetadata(allocator, source_path, jsonl) ParseError!types.SessionMeta`、`parseTranscript(allocator, jsonl) ParseError![]types.TranscriptMessage`）；`ai_types.isSubagentSession(meta)`。
- Produces:
  - `pub const SOURCE_LOCAL = "local"`
  - `pub const LocalRoots = struct { claude_projects_dir: ?[]const u8 = null, codex_sessions_dir: ?[]const u8 = null, wispterm_sessions_dir: ?[]const u8 = null }`
  - `pub const Result = struct { arena: std.heap.ArenaAllocator, sessions: []types.CollectedSession, pub fn deinit(self: *Result) void }`
  - `pub fn collectLocal(gpa: std.mem.Allocator, roots: LocalRoots, cur: *cursors_mod.Set, min_mtime_ns: i128) !Result`

语义要点：
- `min_mtime_ns`：mtime 早于它的文件整个跳过且**不建游标**（回填上限，spec §6）。老会话复活时 mtime 变新，会从 0 全量处理一次——接受，加 ponytail 注释。
- 游标只在内存中更新；落盘由 run.zig 在产物写成功后统一 save（spec §6 "成功后推进"）。
- 无新消息/subagent 会话：更新游标 stamp 后跳过，不产出 session。
- 文件超过 64MB：记录 stamp 防止每次重试，跳过。
- 单文件读/stat 失败：跳过且不动游标（下次重试）。
- 总消息数 < 游标值（文件重写/截断）→ 从 0 重处理。

- [ ] **Step 1: 写完整文件（实现+测试）**

```zig
//! Local filesystem collection (spec §6): enumerate provider logs, compare
//! against cursors, parse only changed files, and return sessions carrying
//! just their new messages. Remote sources (wsl/ssh) arrive in M3 via the
//! existing ScannerHost abstraction.
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");
const provider_claude = @import("../terminal_agents/sessions/provider_claude.zig");
const provider_codex = @import("../terminal_agents/sessions/provider_codex.zig");
const provider_wispterm = @import("provider_wispterm.zig");
const cursors_mod = @import("cursors.zig");
const types = @import("types.zig");

pub const SOURCE_LOCAL = "local";
const MAX_FILE_BYTES = 64 * 1024 * 1024;

pub const LocalRoots = struct {
    /// e.g. <home>/.claude/projects
    claude_projects_dir: ?[]const u8 = null,
    /// e.g. <home>/.codex/sessions
    codex_sessions_dir: ?[]const u8 = null,
    /// e.g. <config>/agent-history/sessions
    wispterm_sessions_dir: ?[]const u8 = null,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    sessions: []types.CollectedSession = &.{},

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Ctx = struct {
    gpa: std.mem.Allocator,
    alloc: std.mem.Allocator, // result arena
    list: *std.ArrayListUnmanaged(types.CollectedSession),
    cur: *cursors_mod.Set,
    min_mtime_ns: i128,
};

pub fn collectLocal(gpa: std.mem.Allocator, roots: LocalRoots, cur: *cursors_mod.Set, min_mtime_ns: i128) !Result {
    var result: Result = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer result.deinit();
    var list: std.ArrayListUnmanaged(types.CollectedSession) = .empty;
    var ctx: Ctx = .{
        .gpa = gpa,
        .alloc = result.arena.allocator(),
        .list = &list,
        .cur = cur,
        .min_mtime_ns = min_mtime_ns,
    };

    if (roots.claude_projects_dir) |root| try collectClaude(&ctx, root);
    if (roots.codex_sessions_dir) |root| try collectCodex(&ctx, root);
    if (roots.wispterm_sessions_dir) |root| try collectWispterm(&ctx, root);

    result.sessions = try list.toOwnedSlice(ctx.alloc);
    return result;
}

fn collectClaude(ctx: *Ctx, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |proj| {
        if (proj.kind != .directory) continue;
        var pdir = dir.openDir(proj.name, .{ .iterate = true }) catch continue;
        defer pdir.close();
        var fit = pdir.iterate();
        while (try fit.next()) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".jsonl")) continue;
            const path = try std.fs.path.join(ctx.alloc, &.{ root, proj.name, ent.name });
            try collectJsonlFile(ctx, .claude, path, pdir, ent.name);
        }
    }
}

fn collectCodex(ctx: *Ctx, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(ctx.gpa);
    defer walker.deinit();
    while (try walker.next()) |ent| {
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.basename, ".jsonl")) continue;
        const path = try std.fs.path.join(ctx.alloc, &.{ root, ent.path });
        try collectJsonlFile(ctx, .codex, path, ent.dir, ent.basename);
    }
}

fn collectJsonlFile(ctx: *Ctx, provider: types.DigestProvider, path: []const u8, dir: std.fs.Dir, name: []const u8) !void {
    const stat = dir.statFile(name) catch return; // transient: retry next run
    if (stat.mtime < ctx.min_mtime_ns) return; // backfill window (spec §6)
    const start = ctx.cur.pendingFrom(SOURCE_LOCAL, provider, path, stat.size, stat.mtime) orelse return;
    const bytes = dir.readFileAlloc(ctx.gpa, name, MAX_FILE_BYTES) catch |err| switch (err) {
        error.FileTooBig => {
            // Remember the stamp so the oversize file is not retried hot.
            try ctx.cur.update(SOURCE_LOCAL, provider, path, stat.size, stat.mtime, 0);
            return;
        },
        else => return,
    };
    defer ctx.gpa.free(bytes);

    const meta = switch (provider) {
        .claude => try provider_claude.parseMetadata(ctx.gpa, path, bytes),
        .codex => try provider_codex.parseMetadata(ctx.gpa, path, bytes),
        else => unreachable,
    };
    defer switch (provider) {
        .claude => provider_claude.freeMetadata(ctx.gpa, meta),
        .codex => provider_codex.freeMetadata(ctx.gpa, meta),
        else => unreachable,
    };
    if (ai_types.isSubagentSession(meta)) {
        try ctx.cur.update(SOURCE_LOCAL, provider, path, stat.size, stat.mtime, 0);
        return;
    }

    const transcript = switch (provider) {
        .claude => try provider_claude.parseTranscript(ctx.gpa, bytes),
        .codex => try provider_codex.parseTranscript(ctx.gpa, bytes),
        else => unreachable,
    };
    defer switch (provider) {
        .claude => provider_claude.freeTranscript(ctx.gpa, transcript),
        .codex => provider_codex.freeTranscript(ctx.gpa, transcript),
        else => unreachable,
    };

    try emit(ctx, provider, path, stat, .{
        .session_id = meta.session_id,
        .title = meta.title,
        .project_path = meta.project_dir,
        .started_at_ms = meta.created_at_ms,
        .ended_at_ms = meta.last_active_at_ms,
    }, transcript, start);
}

fn collectWispterm(ctx: *Ctx, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".json")) continue;
        const path = try std.fs.path.join(ctx.alloc, &.{ root, ent.name });
        const stat = dir.statFile(ent.name) catch continue;
        if (stat.mtime < ctx.min_mtime_ns) continue;
        const start = ctx.cur.pendingFrom(SOURCE_LOCAL, .wispterm, path, stat.size, stat.mtime) orelse continue;
        const bytes = dir.readFileAlloc(ctx.gpa, ent.name, provider_wispterm.MAX_SESSION_BYTES) catch continue;
        defer ctx.gpa.free(bytes);

        var parse_arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer parse_arena.deinit();
        const sess = provider_wispterm.parse(parse_arena.allocator(), bytes) catch {
            // Unparseable file: stamp it so we do not retry hot.
            try ctx.cur.update(SOURCE_LOCAL, .wispterm, path, stat.size, stat.mtime, 0);
            continue;
        };
        try emit(ctx, .wispterm, path, stat, .{
            .session_id = sess.session_id,
            .title = sess.title,
            .project_path = "", // no cwd on disk until spec §10/M4
            .started_at_ms = sess.created_at_ms,
            .ended_at_ms = sess.updated_at_ms,
        }, sess.messages, start);
    }
}

const EmitMeta = struct {
    session_id: []const u8,
    title: []const u8,
    project_path: []const u8,
    started_at_ms: i64,
    ended_at_ms: i64,
};

fn emit(ctx: *Ctx, provider: types.DigestProvider, path: []const u8, stat: std.fs.File.Stat, meta: EmitMeta, transcript: []const ai_types.TranscriptMessage, start: u32) !void {
    const total: u32 = @intCast(transcript.len);
    // Rewritten/truncated file: message count went backwards → reprocess all.
    // ponytail: a revived old session floods once with its full history;
    // acceptable until per-message day slicing lands in M2.
    const from: u32 = if (total < start) 0 else start;
    if (from >= total) {
        try ctx.cur.update(SOURCE_LOCAL, provider, path, stat.size, stat.mtime, total);
        return;
    }
    const fresh = transcript[from..];
    const new_messages = try ctx.alloc.alloc(ai_types.TranscriptMessage, fresh.len);
    for (fresh, 0..) |m, i| new_messages[i] = .{
        .role = m.role,
        .kind = m.kind,
        .content = try ctx.alloc.dupe(u8, m.content),
        .timestamp_ms = m.timestamp_ms,
    };
    try ctx.list.append(ctx.alloc, .{
        .provider = provider,
        .source_id = SOURCE_LOCAL,
        .session_id = try ctx.alloc.dupe(u8, meta.session_id),
        .title = try ctx.alloc.dupe(u8, meta.title),
        .project_path = try ctx.alloc.dupe(u8, meta.project_path),
        .started_at_ms = meta.started_at_ms,
        .ended_at_ms = meta.ended_at_ms,
        .total_messages = total,
        .new_messages = new_messages,
        .source_file = path,
    });
    try ctx.cur.update(SOURCE_LOCAL, provider, path, stat.size, stat.mtime, total);
}
```

测试（同文件底部）。claude/codex 的 fixture 行**必须**复制 provider 测试里的已验证格式（`provider_claude.zig:477`、`provider_codex.zig:304`）：

```zig
const CLAUDE_JSONL =
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"Fix tests"}}
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the failure."}]}}
    \\
;

const CLAUDE_EXTRA_LINE =
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:02:00.000Z","type":"user","message":{"role":"user","content":"And lint"}}
    \\
;

const CODEX_JSONL =
    \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-abc","cwd":"/home/me/project"}}
    \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the renderer crash"}]}}
    \\
;

const WISPTERM_JSON =
    \\{"session_id":"session-1-1","title":"Copilot","api_key":"sk-SECRET","created_at":1782311875112,"updated_at":1782311885976,
    \\ "messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}
;

fn writeTestFile(dir: std.fs.Dir, sub: []const u8, name: []const u8, content: []const u8) !void {
    try dir.makePath(sub);
    var d = try dir.openDir(sub, .{});
    defer d.close();
    try d.writeFile(.{ .sub_path = name, .data = content });
}

test "memory_digest_collector: first run collects all three providers, second run collects none" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try writeTestFile(tmp.dir, "claude/proj-a", "claude-abc.jsonl", CLAUDE_JSONL);
    try writeTestFile(tmp.dir, "codex/2026/05/31", "rollout-x.jsonl", CODEX_JSONL);
    try writeTestFile(tmp.dir, "wisp", "session-1-1.json", WISPTERM_JSON);

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const codex_root = try std.fs.path.join(allocator, &.{ root, "codex" });
    defer allocator.free(codex_root);
    const wisp_root = try std.fs.path.join(allocator, &.{ root, "wisp" });
    defer allocator.free(wisp_root);
    const roots: LocalRoots = .{
        .claude_projects_dir = claude_root,
        .codex_sessions_dir = codex_root,
        .wispterm_sessions_dir = wisp_root,
    };

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();

    var first = try collectLocal(allocator, roots, &cur, 0);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 3), first.sessions.len);

    var again = try collectLocal(allocator, roots, &cur, 0);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 0), again.sessions.len);
}

test "memory_digest_collector: appended lines yield only new messages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try writeTestFile(tmp.dir, "claude/proj-a", "claude-abc.jsonl", CLAUDE_JSONL);
    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const roots: LocalRoots = .{ .claude_projects_dir = claude_root };

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var first = try collectLocal(allocator, roots, &cur, 0);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.sessions[0].new_messages.len);

    const appended = try std.mem.concat(allocator, u8, &.{ CLAUDE_JSONL, CLAUDE_EXTRA_LINE });
    defer allocator.free(appended);
    try writeTestFile(tmp.dir, "claude/proj-a", "claude-abc.jsonl", appended);

    var second = try collectLocal(allocator, roots, &cur, 0);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), second.sessions[0].new_messages.len);
    try std.testing.expectEqualStrings("And lint", second.sessions[0].new_messages[0].content);
    try std.testing.expectEqualStrings("/home/me/project", second.sessions[0].project_path);
}

test "memory_digest_collector: min_mtime skips old files entirely" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeTestFile(tmp.dir, "claude/proj-a", "claude-abc.jsonl", CLAUDE_JSONL);
    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var res = try collectLocal(allocator, .{ .claude_projects_dir = claude_root }, &cur, std.math.maxInt(i128));
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 0), res.sessions.len);
    try std.testing.expectEqual(@as(usize, 0), cur.entries.items.len);
}

test "memory_digest_collector: subagent sessions are stamped and skipped" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const subagent_jsonl =
        \\{"sessionId":"claude-sub","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"You are a search agent. Find X."}}
        \\
    ;
    try writeTestFile(tmp.dir, "claude/proj-a", "claude-sub.jsonl", subagent_jsonl);
    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var res = try collectLocal(allocator, .{ .claude_projects_dir = claude_root }, &cur, 0);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 0), res.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), cur.entries.items.len); // stamped
}

test "memory_digest_collector: missing roots are fine" {
    const allocator = std.testing.allocator;
    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var res = try collectLocal(allocator, .{
        .claude_projects_dir = "/nonexistent/claude",
        .codex_sessions_dir = "/nonexistent/codex",
        .wispterm_sessions_dir = "/nonexistent/wisp",
    }, &cur, 0);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 0), res.sessions.len);
}
```

实现提示：`dir.writeFile(.{ .sub_path, .data })` 若在仓库 Zig 版本下签名不同，参照 `src/agent/history_store.zig` 测试里的写文件惯用法改写；`tmp.dir.makePath` 同理。

- [ ] **Step 2: 注册 + 跑测试**

`src/test_fast.zig` 加 `_ = @import("memory_digest/collector.zig");`
Run: `zig build test`
Expected: PASS（5 个 collector 测试）

- [ ] **Step 3: fmt + commit**

```bash
zig fmt build.zig src && git add -A && git commit -m "feat(memory-digest): local incremental collector for three providers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `src/memory_digest/run.zig` — 单次运行编排

**Files:**
- Create: `src/memory_digest/run.zig`
- Modify: `src/test_fast.zig`

**Interfaces:**
- Consumes: Task 1-5 全部产出；`ai_types.dateKeyFromMs(ms, tz_offset_seconds)`。
- Produces:
  - `pub const Options = struct { roots: collector.LocalRoots, memory_root: []const u8, now_ms: i64, tz_offset_seconds: i32 = 0, backfill_days: u32 = 7 }`
  - `pub const Summary = struct { sessions_collected: usize = 0, days_written: usize = 0 }`
  - `pub fn runOnce(gpa: std.mem.Allocator, opts: Options) !Summary`

流程（顺序即游标安全性）：load cursors → collect（cutoff = `now_ms*1_000_000 - backfill_days*86_400_000_000_000`，backfill_days=0 表示不限）→ 按"最后新消息时间戳（缺省 ended_at，再缺省 now）"的本地日分桶 → 每天写 daily → 重建 index（列 daily 目录 + 读回各 daily 聚合项目计数）→ **最后**保存 cursors。任何一步失败即返回错误，游标不落盘，下次重跑。

- [ ] **Step 1: 写完整文件（实现+测试）**

```zig
//! One digest run (M1, spec §15): collect local sessions, bucket by local
//! day, write daily listings + index, then persist cursors. The cursor file
//! only advances after artifacts were written successfully (spec §6).
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");
const collector = @import("collector.zig");
const cursors_mod = @import("cursors.zig");
const store = @import("store.zig");
const types = @import("types.zig");

pub const Options = struct {
    roots: collector.LocalRoots,
    memory_root: []const u8,
    now_ms: i64,
    tz_offset_seconds: i32 = 0,
    /// 0 = unlimited (tests); default 7 per spec §6/§12.
    backfill_days: u32 = 7,
};

pub const Summary = struct {
    sessions_collected: usize = 0,
    days_written: usize = 0,
};

pub fn runOnce(gpa: std.mem.Allocator, opts: Options) !Summary {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const state_dir = try std.fs.path.join(arena, &.{ opts.memory_root, "state" });
    try std.fs.cwd().makePath(state_dir);
    const cursors_path = try std.fs.path.join(arena, &.{ state_dir, "cursors.json" });

    var cur = try cursors_mod.Set.loadFromPath(gpa, cursors_path);
    defer cur.deinit();

    const min_mtime_ns: i128 = if (opts.backfill_days == 0)
        0
    else
        @as(i128, opts.now_ms) * 1_000_000 - @as(i128, opts.backfill_days) * 86_400_000_000_000;

    var collected = try collector.collectLocal(gpa, opts.roots, &cur, min_mtime_ns);
    defer collected.deinit();

    // Bucket sessions by the local day of their last new activity.
    // ponytail: whole-session bucketing; per-message day slicing is an M2
    // concern together with the LLM stage (spec §11).
    var day_keys: std.ArrayListUnmanaged(u32) = .empty;
    for (collected.sessions) |s| {
        const key = ai_types.dateKeyFromMs(lastActivityMs(s, opts.now_ms), opts.tz_offset_seconds);
        if (std.mem.indexOfScalar(u32, day_keys.items, key) == null) {
            try day_keys.append(arena, key);
        }
    }

    for (day_keys.items) |key| {
        var entries: std.ArrayListUnmanaged(store.DailySession) = .empty;
        for (collected.sessions) |s| {
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
        try store.writeDaily(gpa, opts.memory_root, .{
            .date = store.formatDate(key, &date_buf),
            .generated_at = opts.now_ms,
            .sessions = entries.items,
        });
    }

    try writeIndexFromDisk(gpa, arena, opts.memory_root, opts.now_ms);
    try cur.saveToPath(gpa, cursors_path);

    return .{
        .sessions_collected = collected.sessions.len,
        .days_written = day_keys.items.len,
    };
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
        try days.append(arena, date);
        const bytes = dir.readFileAlloc(arena, ent.name, 16 * 1024 * 1024) catch continue;
        const parsed = std.json.parseFromSlice(DailyShape, arena, bytes, .{
            .ignore_unknown_fields = true,
        }) catch continue; // arena-owned; no deinit needed
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
        idx_projects[i] = .{ .slug = p.slug, .last_active = p.last_active, .session_count = p.count };
    }
    try store.writeIndex(gpa, memory_root, .{
        .generated_at = now_ms,
        .days = days.items,
        .projects = idx_projects,
    });
}
```

测试（同文件底部；fixture 常量与 Task 5 相同来源——为避免跨文件测试耦合，直接在本文件重复声明 CLAUDE_JSONL/WISPTERM_JSON 两个常量，内容同 Task 5）：

```zig
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
}
```

注：wispterm fixture 的 updated_at=1782311885976 对应 2026-06-24 前后（UTC+8），它会落在自己的日期文件里——第一个测试只断言 claude 的那天。

- [ ] **Step 2: 注册 + 跑测试**

`src/test_fast.zig` 加 `_ = @import("memory_digest/run.zig");`
Run: `zig build test`
Expected: PASS

- [ ] **Step 3: fmt + commit**

```bash
zig fmt build.zig src && git add -A && git commit -m "feat(memory-digest): single-run orchestration with daily and index artifacts

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: dev CLI + build step + 真机验证

**Files:**
- Create: `src/memory_digest/scan_main.zig`
- Modify: `build.zig`（`wispterm-filetool` step 之后，仿其模式加 `memory-digest` step）

**Interfaces:**
- Consumes: `run.runOnce`、`dirs.agentHistoryDir`、`dirs.memoryDir`。
- Produces: `zig build memory-digest -Dtarget=aarch64-macos` → `zig-out/bin/wispterm-memory-digest` 可执行。

- [ ] **Step 1: 写 scan_main.zig**

```zig
//! Dev CLI: run one local memory-digest scan against the real machine.
//! Build: zig build memory-digest -Dtarget=aarch64-macos
//! Run:   ./zig-out/bin/wispterm-memory-digest
//! ponytail: macOS/HOME-based dev tool; the app's scheduler (M2) is the
//! real cross-platform entry point.
const std = @import("std");
const dirs = @import("../platform/dirs.zig");
const run_mod = @import("run.zig");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const home = try std.process.getEnvVarOwned(gpa, "HOME");
    defer gpa.free(home);

    const claude_dir = try std.fs.path.join(gpa, &.{ home, ".claude", "projects" });
    defer gpa.free(claude_dir);
    const codex_dir = try std.fs.path.join(gpa, &.{ home, ".codex", "sessions" });
    defer gpa.free(codex_dir);
    const agent_history_dir = try dirs.agentHistoryDir(gpa);
    defer gpa.free(agent_history_dir);
    const wispterm_dir = try std.fs.path.join(gpa, &.{ agent_history_dir, "sessions" });
    defer gpa.free(wispterm_dir);
    const memory_root = try dirs.memoryDir(gpa);
    defer gpa.free(memory_root);

    const summary = try run_mod.runOnce(gpa, .{
        .roots = .{
            .claude_projects_dir = claude_dir,
            .codex_sessions_dir = codex_dir,
            .wispterm_sessions_dir = wispterm_dir,
        },
        .memory_root = memory_root,
        .now_ms = std.time.milliTimestamp(),
        // ponytail: dev CLI hardcodes UTC+8; the app injects the real
        // offset when the M2 scheduler lands.
        .tz_offset_seconds = 8 * 3600,
    });
    std.debug.print(
        "memory-digest: {d} sessions with new messages, {d} daily files written under {s}\n",
        .{ summary.sessions_collected, summary.days_written, memory_root },
    );
}
```

- [ ] **Step 2: build.zig 加 step**

在 `wispterm-filetool` step（build.zig 约 684 行）之后，仿其模式：

```zig
    const memory_digest_mod = b.createModule(.{
        .root_source_file = b.path("src/memory_digest/scan_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const memory_digest_exe = b.addExecutable(.{
        .name = "wispterm-memory-digest",
        .root_module = memory_digest_mod,
    });
    if (platform.supports_gui_subsystem) memory_digest_exe.subsystem = .Console;
    const memory_digest_step = b.step("memory-digest", "Build the dev memory-digest scanner CLI (not bundled with the app)");
    memory_digest_step.dependOn(&b.addInstallArtifact(memory_digest_exe, .{}).step);
```

注意：build.zig 顶部有源码自检测试（`expectSourceContains`，约 418 行起）——只断言既有 step 存在，新增 step 无需登记；若 `zig build test` 因此失败，把 `b.step("memory-digest"` 的断言加进同一列表。

- [ ] **Step 3: 编译 + fast 测试**

Run: `zig build memory-digest -Dtarget=aarch64-macos && zig build test`
Expected: 两者成功，`zig-out/bin/wispterm-memory-digest` 存在

- [ ] **Step 4: 真机验证（M1 出口标准）**

```bash
./zig-out/bin/wispterm-memory-digest
ls ~/Library/Application\ Support/wispterm/memory/daily/
python3 -m json.tool ~/Library/Application\ Support/wispterm/memory/index.json | head -30
```

Expected: 打印 `memory-digest: N sessions ...`（N>0，最近 7 天内有过 claude/codex/copilot 活动即可）；daily/ 下出现日期文件；index.json 里能看到 phantty 等项目 slug。检查任一 daily 文件确认**不含** `api_key` 或 `sk-` 字样（`grep -r "sk-" ~/Library/Application\ Support/wispterm/memory/daily/ || echo CLEAN`，注意消息正文里合法出现的 `sk-` 需人工判断）。

- [ ] **Step 5: fmt + commit**

```bash
zig fmt build.zig src && git add -A && git commit -m "feat(memory-digest): dev scanner CLI and build step

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: 收尾验证

- [ ] **Step 1: 全量 macOS 原生测试**

Run: `zig build test-full -Dtarget=aarch64-macos`
Expected: PASS（已知抖动：`skill center tool import` 的 FileNotFound 与本改动无关，可重跑确认）

- [ ] **Step 2: fmt 终检**

Run: `zig fmt --check build.zig src`
Expected: 无输出（CI 同款检查）

- [ ] **Step 3: 汇报**

M1 完成后停下汇报（不自行开 PR）：出口标准复核（真机 daily JSON 三源可见）、测试结果、已知简化清单（whole-session 日分桶、wispterm 无 cwd、slug 无冲突消歧、UTC+8 硬编码），等待决定是否直接进 M2。
