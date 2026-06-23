# 副驾历史存储重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把副驾历史的单文件 `agent-history.json` 存储改为「每会话一个 `sessions/<id>.json` + 派生 `index.json`」目录布局，运行时索引驱动、正文懒加载、写入去抖，去掉 8MB 加载死线。

**Architecture:** 在 `agent_history.zig` 增加纯函数（索引结构、单记录 JSON 读写、文件名净化、搜索预览、索引 IO、由索引投影 Row）；新建 `agent_history_store.zig` 的 `MetaStore`（持目录、内存索引、`pending` 待写记录、迁移/重建/flush）；`MetaStore` 替换全局 `g_agent_history` 指向的类型；`AppWindow.zig` 与 `file_explorer.zig` 的调用点改为指向 `MetaStore`（方法同名，签名基本不变）。旧 `agent_history.Store` 仅保留为「单 blob 解析器」供迁移与原有测试使用，不删。

**Tech Stack:** Zig（`std.json` / `std.fs` 原子写 / `std.testing.tmpDir`），项目既有 `flush_scheduler.FlushScheduler`、`platform_dirs` 测试隔离钩子。

**测试套件归属：**
- `agent_history.zig`、`agent_history_store.zig`（新增，需加进 `test_fast.zig`）、`file_explorer.zig` 的内联测试 → `zig build test`（fast 套件）。
- `platform/dirs.zig`、`AppWindow.zig` 的内联测试 → `zig build test-full`。
- macOS 真机构建验证：`zig build macos-app -Dtarget=aarch64-macos`（默认 `zig build` 目标是 Windows）。

---

## File Structure

- **Modify** `src/platform/dirs.zig` — 新增 `agentHistoryDir` / `agentHistoryDirFromEnvForOs`（目录路径）。
- **Modify** `src/agent_history.zig` — 新增 `IndexEntry`/`IndexFile`、索引 IO、`sanitizeSessionFileName`、`buildSearchPreview`、`recordToIndexEntry`、单记录 JSON 读写、`buildRowsFromEntries`/`buildCopilotRowsFromEntries` 及 free/clone 辅助。现有 `Store` 与其测试保持不动。
- **Create** `src/agent_history_store.zig` — `MetaStore`（目录后端 + 内存索引 + pending + 迁移/重建/flush）。
- **Modify** `src/test_fast.zig` — 增加 `_ = @import("agent_history_store.zig");`。
- **Modify** `src/AppWindow.zig` — 全局类型、`ensureGlobalAgentHistoryStore`、flush 函数、3 处内联测试。
- **Modify** `src/file_explorer.zig` — `syncAgentHistoryRows` 形参类型、3 处内联测试。

---

## Task 1: dirs.zig 新增 agent-history 目录路径

**Files:**
- Modify: `src/platform/dirs.zig`（在 `agentHistoryPath` 之后，约第 205 行）

- [ ] **Step 1: 写失败测试**（追加到 `src/platform/dirs.zig` 末尾的 test 区）

```zig
test "agentHistoryDir resolves under config dir (macos)" {
    const a = std.testing.allocator;
    const p = try agentHistoryDirFromEnvForOs(a, .macos, .{ .home = "/Users/x" });
    defer a.free(p);
    try std.testing.expectEqualStrings("/Users/x/Library/Application Support/wispterm/agent-history", p);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test-full`
Expected: 编译错误 `agentHistoryDirFromEnvForOs` 未定义。

- [ ] **Step 3: 实现**（紧跟现有 `agentHistoryPathFromEnvForOs` 之后插入）

```zig
pub fn agentHistoryDir(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "agent-history");
}

pub fn agentHistoryDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "agent-history");
}
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test-full`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/platform/dirs.zig
git commit -m "feat(dirs): add agentHistoryDir for per-session history layout"
```

---

## Task 2: agent_history.zig 索引结构与 IO

**Files:**
- Modify: `src/agent_history.zig`（结构定义放在 `Row`（第 50 行）之后；函数放在文件下半部公共函数区，如 `freeRows`（第 369 行）附近）

- [ ] **Step 1: 写失败测试**（追加到 `agent_history.zig` 的 test 区，例如第 1021 行测试之后）

```zig
test "agent_history: index file round-trips" {
    const allocator = std.testing.allocator;
    var entries = [_]IndexEntry{
        .{ .session_id = "s1", .title = "T1", .model = "m1", .created_at = 1, .updated_at = 2, .copilot = false, .message_count = 3, .search_preview = "t1 hello" },
        .{ .session_id = "s2", .title = "T2", .model = "m2", .created_at = 5, .updated_at = 6, .copilot = true, .message_count = 0, .search_preview = "" },
    };
    const json = try dumpIndex(allocator, .{ .version = INDEX_VERSION, .entries = &entries });
    defer allocator.free(json);

    var parsed = try parseIndex(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(INDEX_VERSION, parsed.value.version);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
    try std.testing.expectEqualStrings("s2", parsed.value.entries[1].session_id);
    try std.testing.expect(parsed.value.entries[1].copilot);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.entries[0].message_count);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `IndexEntry` / `dumpIndex` / `parseIndex` / `INDEX_VERSION` 未定义。

- [ ] **Step 3: 实现**（结构放在第 50 行 `Row` 之后）

```zig
pub const INDEX_VERSION: u32 = 1;

pub const IndexEntry = struct {
    session_id: []const u8,
    title: []const u8,
    model: []const u8,
    created_at: i64,
    updated_at: i64,
    copilot: bool = false,
    message_count: u32 = 0,
    search_preview: []const u8 = "",
};

pub const IndexFile = struct {
    version: u32 = INDEX_VERSION,
    entries: []IndexEntry = &.{},
};
```

并在公共函数区（如 `freeRows` 之后）加入：

```zig
pub fn dumpIndex(allocator: std.mem.Allocator, index: IndexFile) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, index, .{});
}

pub fn parseIndex(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(IndexFile) {
    return std.json.parseFromSlice(IndexFile, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn cloneIndexEntry(allocator: std.mem.Allocator, input: IndexEntry) !IndexEntry {
    const session_id = try allocator.dupe(u8, input.session_id);
    errdefer allocator.free(session_id);
    const title = try allocator.dupe(u8, input.title);
    errdefer allocator.free(title);
    const model = try allocator.dupe(u8, input.model);
    errdefer allocator.free(model);
    const search_preview = try allocator.dupe(u8, input.search_preview);
    errdefer allocator.free(search_preview);
    return .{
        .session_id = session_id,
        .title = title,
        .model = model,
        .created_at = input.created_at,
        .updated_at = input.updated_at,
        .copilot = input.copilot,
        .message_count = input.message_count,
        .search_preview = search_preview,
    };
}

pub fn freeOwnedIndexEntry(allocator: std.mem.Allocator, entry: *IndexEntry) void {
    allocator.free(entry.session_id);
    allocator.free(entry.title);
    allocator.free(entry.model);
    allocator.free(entry.search_preview);
    entry.* = undefined;
}
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history.zig
git commit -m "feat(agent_history): add IndexEntry/IndexFile and JSON round-trip"
```

---

## Task 3: 文件名净化 sanitizeSessionFileName

**Files:**
- Modify: `src/agent_history.zig`

- [ ] **Step 1: 写失败测试**

```zig
test "agent_history: sanitizeSessionFileName keeps safe ids and hashes unsafe ones" {
    const allocator = std.testing.allocator;

    const safe = try sanitizeSessionFileName(allocator, "session-1719000000000-3");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("session-1719000000000-3.json", safe);

    const unsafe1 = try sanitizeSessionFileName(allocator, "会話/x");
    defer allocator.free(unsafe1);
    const unsafe2 = try sanitizeSessionFileName(allocator, "会話/x");
    defer allocator.free(unsafe2);
    try std.testing.expect(std.mem.endsWith(u8, unsafe1, ".json"));
    try std.testing.expect(std.mem.indexOfScalar(u8, unsafe1, '/') == null);
    try std.testing.expectEqualStrings(unsafe1, unsafe2); // deterministic
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `sanitizeSessionFileName` 未定义。

- [ ] **Step 3: 实现**（公共函数区）

```zig
fn isSafeFileChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '_' or c == '-';
}

pub fn sanitizeSessionFileName(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    var all_safe = session_id.len > 0;
    for (session_id) |c| {
        if (!isSafeFileChar(c)) {
            all_safe = false;
            break;
        }
    }
    if (all_safe) {
        return std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (session_id) |c| {
        try buf.append(allocator, if (isSafeFileChar(c)) c else '_');
    }
    const h = std.hash.Wyhash.hash(0, session_id);
    return std.fmt.allocPrint(allocator, "{s}-{x}.json", .{ buf.items, h });
}
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history.zig
git commit -m "feat(agent_history): add filesystem-safe session filename mapping"
```

---

## Task 4: 搜索预览 buildSearchPreview + recordToIndexEntry

**Files:**
- Modify: `src/agent_history.zig`

- [ ] **Step 1: 写失败测试**

```zig
test "agent_history: recordToIndexEntry derives bounded lowercase preview" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Hello World",
        .base_url = "https://api.example.com",
        .api_key = "k",
        .model = "m1",
        .system_prompt = "sys",
        .thinking_enabled = false,
        .reasoning_effort = "low",
        .stream = true,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &[_]MessageRecord{
            .{ .role = .user, .content = "First Question" },
        },
    });

    var entry = try recordToIndexEntry(allocator, store.records.items[0]);
    defer freeOwnedIndexEntry(allocator, &entry);

    try std.testing.expectEqual(@as(u32, 1), entry.message_count);
    try std.testing.expect(entry.search_preview.len <= SEARCH_PREVIEW_MAX);
    try std.testing.expect(std.unicode.utf8ValidateSlice(entry.search_preview));
    try std.testing.expect(std.mem.indexOf(u8, entry.search_preview, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.search_preview, "first question") != null);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `recordToIndexEntry` / `SEARCH_PREVIEW_MAX` 未定义。

- [ ] **Step 3: 实现**（公共函数区）

```zig
pub const SEARCH_PREVIEW_MAX = 200;

fn lowerAsciiByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub fn buildSearchPreview(allocator: std.mem.Allocator, record: SessionRecord) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (record.title) |c| try buf.append(allocator, lowerAsciiByte(c));
    for (record.messages) |m| {
        if (buf.items.len >= SEARCH_PREVIEW_MAX) break;
        try buf.append(allocator, ' ');
        for (m.content) |c| {
            if (buf.items.len >= SEARCH_PREVIEW_MAX) break;
            try buf.append(allocator, lowerAsciiByte(c));
        }
    }

    // Back off to a valid UTF-8 prefix (lowercasing only touched ASCII bytes).
    var n = @min(buf.items.len, SEARCH_PREVIEW_MAX);
    while (n > 0 and !std.unicode.utf8ValidateSlice(buf.items[0..n])) n -= 1;
    buf.shrinkRetainingCapacity(n);
    return buf.toOwnedSlice(allocator);
}

pub fn recordToIndexEntry(allocator: std.mem.Allocator, record: SessionRecord) !IndexEntry {
    const session_id = try allocator.dupe(u8, record.session_id);
    errdefer allocator.free(session_id);
    const title = try allocator.dupe(u8, record.title);
    errdefer allocator.free(title);
    const model = try allocator.dupe(u8, record.model);
    errdefer allocator.free(model);
    const search_preview = try buildSearchPreview(allocator, record);
    errdefer allocator.free(search_preview);
    return .{
        .session_id = session_id,
        .title = title,
        .model = model,
        .created_at = record.created_at,
        .updated_at = record.updated_at,
        .copilot = record.copilot,
        .message_count = @intCast(record.messages.len),
        .search_preview = search_preview,
    };
}
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history.zig
git commit -m "feat(agent_history): derive index entry + bounded search preview from record"
```

---

## Task 5: 单会话记录 JSON 读写

**Files:**
- Modify: `src/agent_history.zig`

- [ ] **Step 1: 写失败测试**

```zig
test "agent_history: single record JSON round-trips" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Title",
        .base_url = "https://api.example.com",
        .api_key = "k",
        .model = "m1",
        .system_prompt = "sys",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .copilot = true,
        .created_at = 7,
        .updated_at = 9,
        .messages = &[_]MessageRecord{
            .{ .role = .user, .content = "hi" },
            .{ .role = .assistant, .content = "yo" },
        },
    });

    const json = try recordToJson(allocator, store.records.items[0]);
    defer allocator.free(json);

    var rec = try recordFromJson(allocator, json);
    defer freeOwnedRecord(allocator, &rec);

    try std.testing.expectEqualStrings("s1", rec.session_id);
    try std.testing.expect(rec.copilot);
    try std.testing.expectEqual(@as(usize, 2), rec.messages.len);
    try std.testing.expectEqualStrings("yo", rec.messages[1].content);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `recordToJson` / `recordFromJson` 未定义。

- [ ] **Step 3: 实现**（公共函数区；`MAX_SESSION_BYTES` 顶部常量）

在第 5 行 `MAX_HISTORY_BYTES` 附近添加：

```zig
pub const MAX_SESSION_BYTES = 32 * 1024 * 1024;
```

公共函数区添加：

```zig
pub fn recordToJson(allocator: std.mem.Allocator, record: SessionRecord) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, record, .{});
}

pub fn recordFromJson(allocator: std.mem.Allocator, bytes: []const u8) !SessionRecord {
    var parsed = try std.json.parseFromSlice(SessionRecord, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return cloneRecord(allocator, parsed.value);
}
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history.zig
git commit -m "feat(agent_history): single-record JSON serialize/deserialize"
```

---

## Task 6: 由索引投影 Row（含排序与 copilot 过滤）

**Files:**
- Modify: `src/agent_history.zig`

- [ ] **Step 1: 写失败测试**

```zig
test "agent_history: buildRowsFromEntries sorts desc and filters copilot" {
    const allocator = std.testing.allocator;
    var entries = [_]IndexEntry{
        .{ .session_id = "a", .title = "A", .model = "m", .created_at = 1, .updated_at = 1, .copilot = false },
        .{ .session_id = "b", .title = "B", .model = "m", .created_at = 2, .updated_at = 3, .copilot = true },
        .{ .session_id = "c", .title = "C", .model = "m", .created_at = 2, .updated_at = 2, .copilot = false },
    };

    const rows = try buildRowsFromEntries(allocator, &entries);
    defer freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("b", rows[0].session_id); // updated_at=3 first
    try std.testing.expectEqualStrings("c", rows[1].session_id);

    const co = try buildCopilotRowsFromEntries(allocator, &entries);
    defer freeRows(allocator, co);
    try std.testing.expectEqual(@as(usize, 1), co.len);
    try std.testing.expectEqualStrings("b", co[0].session_id);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `buildRowsFromEntries` / `buildCopilotRowsFromEntries` 未定义。

- [ ] **Step 3: 实现**（公共函数区；复用现有私有 `cloneRow`/`freeOwnedRow`/`sortRows`）

```zig
pub fn buildRowsFromEntries(allocator: std.mem.Allocator, entries: []const IndexEntry) ![]Row {
    const rows = try allocator.alloc(Row, entries.len);
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            freeOwnedRow(allocator, &rows[initialized]);
        }
        allocator.free(rows);
    }
    for (entries, 0..) |e, i| {
        rows[i] = try cloneRow(allocator, .{
            .session_id = e.session_id,
            .title = e.title,
            .model = e.model,
            .updated_at = e.updated_at,
            .copilot = e.copilot,
        });
        initialized += 1;
    }
    sortRows(rows);
    return rows;
}

pub fn buildCopilotRowsFromEntries(allocator: std.mem.Allocator, entries: []const IndexEntry) ![]Row {
    var list: std.ArrayListUnmanaged(Row) = .empty;
    errdefer {
        for (list.items) |*r| freeOwnedRow(allocator, r);
        list.deinit(allocator);
    }
    for (entries) |e| {
        if (!e.copilot) continue;
        const row = try cloneRow(allocator, .{
            .session_id = e.session_id,
            .title = e.title,
            .model = e.model,
            .updated_at = e.updated_at,
            .copilot = e.copilot,
        });
        list.append(allocator, row) catch |err| {
            var owned = row;
            freeOwnedRow(allocator, &owned);
            return err;
        };
    }
    const rows = try list.toOwnedSlice(allocator);
    sortRows(rows);
    return rows;
}
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history.zig
git commit -m "feat(agent_history): project sorted rows from index entries"
```

---

## Task 7: MetaStore 骨架（open 空目录 / buildRows / deinit）

**Files:**
- Create: `src/agent_history_store.zig`
- Modify: `src/test_fast.zig`（加入 import）

- [ ] **Step 1: 写失败测试**（写在新文件 `src/agent_history_store.zig` 内联 test）

```zig
const std = @import("std");
const agent_history = @import("agent_history.zig");

pub const MAX_INDEX_BYTES = 32 * 1024 * 1024;
const MIGRATION_MAX_BYTES = 1 << 30;

pub const MetaStore = struct {
    allocator: std.mem.Allocator,
    dir: []u8,
    entries: std.ArrayListUnmanaged(agent_history.IndexEntry) = .empty,
    pending: std.ArrayListUnmanaged(agent_history.SessionRecord) = .empty,
    index_dirty: bool = false,
};

test "MetaStore: open empty dir yields no rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var store = try MetaStore.open(allocator, root);
    defer store.deinit();

    const rows = try store.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}
```

- [ ] **Step 2: 运行确认失败**

先把新文件加入 fast 套件：在 `src/test_fast.zig` 第 137 行 `_ = @import("agent_history.zig");` 之后加入：

```zig
    _ = @import("agent_history_store.zig");
```

Run: `zig build test`
Expected: 编译错误 `MetaStore.open` / `buildRows` / `deinit` 未定义。

- [ ] **Step 3: 实现**（在 `MetaStore` 结构体内补方法 + 私有路径辅助）

```zig
    pub fn open(allocator: std.mem.Allocator, dir_in: []const u8) !MetaStore {
        var self = MetaStore{ .allocator = allocator, .dir = try allocator.dupe(u8, dir_in) };
        errdefer self.deinit();

        try std.fs.cwd().makePath(self.dir);
        const sessions = try self.sessionsDirPath(allocator);
        defer allocator.free(sessions);
        try std.fs.cwd().makePath(sessions);
        return self;
    }

    pub fn deinit(self: *MetaStore) void {
        for (self.entries.items) |*e| agent_history.freeOwnedIndexEntry(self.allocator, e);
        self.entries.deinit(self.allocator);
        for (self.pending.items) |*r| agent_history.freeOwnedRecord(self.allocator, r);
        self.pending.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.* = undefined;
    }

    fn sessionsDirPath(self: *const MetaStore, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.dir, "sessions" });
    }

    fn indexPath(self: *const MetaStore, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.dir, "index.json" });
    }

    fn sessionFilePath(self: *const MetaStore, allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
        const fname = try agent_history.sanitizeSessionFileName(allocator, session_id);
        defer allocator.free(fname);
        const sessions = try self.sessionsDirPath(allocator);
        defer allocator.free(sessions);
        return std.fs.path.join(allocator, &.{ sessions, fname });
    }

    pub fn buildRows(self: *const MetaStore, allocator: std.mem.Allocator) ![]agent_history.Row {
        return agent_history.buildRowsFromEntries(allocator, self.entries.items);
    }

    pub fn buildCopilotRows(self: *const MetaStore, allocator: std.mem.Allocator) ![]agent_history.Row {
        return agent_history.buildCopilotRowsFromEntries(allocator, self.entries.items);
    }

    fn entryIndex(self: *const MetaStore, session_id: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.session_id, session_id)) return i;
        }
        return null;
    }

    fn pendingIndex(self: *const MetaStore, session_id: []const u8) ?usize {
        for (self.pending.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.session_id, session_id)) return i;
        }
        return null;
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history_store.zig src/test_fast.zig
git commit -m "feat(agent_history_store): MetaStore skeleton with dir + index-backed rows"
```

---

## Task 8: MetaStore upsert / cloneRecordBySessionId（pending 路径）

**Files:**
- Modify: `src/agent_history_store.zig`

- [ ] **Step 1: 写失败测试**

```zig
test "MetaStore: upsert is visible via rows and clone before flush (pending)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var store = try MetaStore.open(allocator, root);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "T",
        .base_url = "https://api.example.com",
        .api_key = "k",
        .model = "m",
        .system_prompt = "sys",
        .thinking_enabled = false,
        .reasoning_effort = "low",
        .stream = true,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &[_]agent_history.MessageRecord{.{ .role = .user, .content = "hi" }},
    });

    const rows = try store.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("s1", rows[0].session_id);

    var rec = (try store.cloneRecordBySessionId(allocator, "s1")) orelse return error.Missing;
    defer agent_history.freeOwnedRecord(allocator, &rec);
    try std.testing.expectEqualStrings("hi", rec.messages[0].content);

    try std.testing.expect((try store.cloneRecordBySessionId(allocator, "nope")) == null);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `upsertRecord` / `cloneRecordBySessionId` 未定义。

- [ ] **Step 3: 实现**（MetaStore 内）

```zig
    pub fn upsertRecord(self: *MetaStore, input: anytype) !void {
        var cloned = try agent_history.cloneRecord(self.allocator, input);
        errdefer agent_history.freeOwnedRecord(self.allocator, &cloned);

        var new_entry = try agent_history.recordToIndexEntry(self.allocator, cloned);
        errdefer agent_history.freeOwnedIndexEntry(self.allocator, &new_entry);

        // Reserve space FIRST: these are the only fallible ops. After this point
        // every transfer below is infallible, so ownership moves out of `cloned`/
        // `new_entry` without leaving the errdefers able to double-free them.
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.pending.ensureUnusedCapacity(self.allocator, 1);

        if (self.entryIndex(cloned.session_id)) |i| {
            agent_history.freeOwnedIndexEntry(self.allocator, &self.entries.items[i]);
            self.entries.items[i] = new_entry;
        } else {
            self.entries.appendAssumeCapacity(new_entry);
        }

        if (self.pendingIndex(cloned.session_id)) |i| {
            agent_history.freeOwnedRecord(self.allocator, &self.pending.items[i]);
            self.pending.items[i] = cloned;
        } else {
            self.pending.appendAssumeCapacity(cloned);
        }
        self.index_dirty = true;
        // Reached the end with no error → errdefers do not run; `cloned`/`new_entry`
        // are now owned by self.pending / self.entries.
    }

    pub fn cloneRecordBySessionId(
        self: *const MetaStore,
        allocator: std.mem.Allocator,
        session_id: []const u8,
    ) !?agent_history.SessionRecord {
        if (self.pendingIndex(session_id)) |i| {
            return try agent_history.cloneRecord(allocator, self.pending.items[i]);
        }
        const path = try self.sessionFilePath(allocator, session_id);
        defer allocator.free(path);
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_INDEX_BYTES) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return null,
        };
        defer allocator.free(bytes);
        return try agent_history.recordFromJson(allocator, bytes);
    }
```

> 所有权说明：`errdefer` 仅覆盖到两个 `ensureUnusedCapacity`（最后的可失败步骤）之前；其后的 `appendAssumeCapacity`/下标赋值不可失败，函数遂走到末尾正常返回（无 error），`errdefer` 不触发，`cloned`/`new_entry` 干净地移交给 `pending`/`entries`，由 `deinit` 释放——不存在双重释放。

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS（在 `testing.allocator` 下无泄漏/双释放）。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history_store.zig
git commit -m "feat(agent_history_store): upsert into index+pending, lazy clone by id"
```

---

## Task 9: MetaStore flush（落盘会话文件 + 索引）与冷读

**Files:**
- Modify: `src/agent_history_store.zig`

- [ ] **Step 1: 写失败测试**

```zig
test "MetaStore: flush writes files and index, reopen reads cold from disk" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    {
        var store = try MetaStore.open(allocator, root);
        defer store.deinit();
        try store.upsertRecord(.{
            .session_id = "s1",
            .title = "T",
            .base_url = "https://api.example.com",
            .api_key = "k",
            .model = "m",
            .system_prompt = "sys",
            .thinking_enabled = false,
            .reasoning_effort = "low",
            .stream = true,
            .agent_enabled = true,
            .created_at = 1,
            .updated_at = 2,
            .messages = &[_]agent_history.MessageRecord{.{ .role = .user, .content = "hi" }},
        });
        try store.flush();
        try std.testing.expectEqual(@as(usize, 0), store.pending.items.len);
    }

    // Reopen: index loaded, no pending, body read lazily from file.
    var store2 = try MetaStore.open(allocator, root);
    defer store2.deinit();
    const rows = try store2.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);

    var rec = (try store2.cloneRecordBySessionId(allocator, "s1")) orelse return error.Missing;
    defer agent_history.freeOwnedRecord(allocator, &rec);
    try std.testing.expectEqualStrings("hi", rec.messages[0].content);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 失败——`open` 尚不加载 index（reopen 后 rows.len==0），或 `flush` 未定义。

- [ ] **Step 3: 实现**：加入 `flush` / `writeSessionFile` / `writeIndex`，并在 `open` 中接入「加载 index」分支。

MetaStore 内新增：

```zig
    fn writeSessionFile(self: *const MetaStore, record: agent_history.SessionRecord) !void {
        const json = try agent_history.recordToJson(self.allocator, record);
        defer self.allocator.free(json);
        const path = try self.sessionFilePath(self.allocator, record.session_id);
        defer self.allocator.free(path);
        try agent_history.saveJsonToPath(path, json);
    }

    fn writeIndex(self: *MetaStore) !void {
        const json = try agent_history.dumpIndex(self.allocator, .{
            .version = agent_history.INDEX_VERSION,
            .entries = self.entries.items,
        });
        defer self.allocator.free(json);
        const path = try self.indexPath(self.allocator);
        defer self.allocator.free(path);
        try agent_history.saveJsonToPath(path, json);
    }

    pub fn flush(self: *MetaStore) !void {
        if (!self.index_dirty and self.pending.items.len == 0) return;
        for (self.pending.items) |record| {
            try self.writeSessionFile(record);
        }
        for (self.pending.items) |*r| agent_history.freeOwnedRecord(self.allocator, r);
        self.pending.clearRetainingCapacity();
        try self.writeIndex();
        self.index_dirty = false;
    }

    fn loadIndexFromDisk(self: *MetaStore) !bool {
        const path = try self.indexPath(self.allocator);
        defer self.allocator.free(path);
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, path, MAX_INDEX_BYTES) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return false,
        };
        defer self.allocator.free(bytes);
        var parsed = agent_history.parseIndex(self.allocator, bytes) catch return false;
        defer parsed.deinit();
        if (parsed.value.version != agent_history.INDEX_VERSION) return false;
        for (parsed.value.entries) |e| {
            const cloned = try agent_history.cloneIndexEntry(self.allocator, e);
            self.entries.append(self.allocator, cloned) catch |err| {
                var owned = cloned;
                agent_history.freeOwnedIndexEntry(self.allocator, &owned);
                return err;
            };
        }
        return true;
    }
```

并把 `open` 改为（在 `makePath(sessions)` 之后、`return self` 之前）：

```zig
        if (try self.loadIndexFromDisk()) return self;
        return self;
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history_store.zig
git commit -m "feat(agent_history_store): debounced flush to per-session files + index; load index on open"
```

---

## Task 10: MetaStore deleteBySessionId

**Files:**
- Modify: `src/agent_history_store.zig`

- [ ] **Step 1: 写失败测试**

```zig
test "MetaStore: delete removes entry, pending and on-disk file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var store = try MetaStore.open(allocator, root);
    defer store.deinit();
    try store.upsertRecord(.{
        .session_id = "s1", .title = "T", .base_url = "u", .api_key = "k", .model = "m",
        .system_prompt = "s", .thinking_enabled = false, .reasoning_effort = "low",
        .stream = true, .agent_enabled = true, .created_at = 1, .updated_at = 2,
        .messages = &[_]agent_history.MessageRecord{},
    });
    try store.flush();

    try std.testing.expect(store.deleteBySessionId("s1"));
    try std.testing.expect(!store.deleteBySessionId("s1"));
    try store.flush();

    const rows = try store.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);

    var reopened = try MetaStore.open(allocator, root);
    defer reopened.deinit();
    try std.testing.expect((try reopened.cloneRecordBySessionId(allocator, "s1")) == null);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `deleteBySessionId` 未定义。

- [ ] **Step 3: 实现**（MetaStore 内）

```zig
    pub fn deleteBySessionId(self: *MetaStore, session_id: []const u8) bool {
        const idx = self.entryIndex(session_id) orelse return false;

        if (self.sessionFilePath(self.allocator, session_id)) |path| {
            defer self.allocator.free(path);
            std.fs.cwd().deleteFile(path) catch {};
        } else |_| {}

        var removed = self.entries.orderedRemove(idx);
        agent_history.freeOwnedIndexEntry(self.allocator, &removed);

        if (self.pendingIndex(session_id)) |pi| {
            var r = self.pending.orderedRemove(pi);
            agent_history.freeOwnedRecord(self.allocator, &r);
        }
        self.index_dirty = true;
        return true;
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history_store.zig
git commit -m "feat(agent_history_store): delete entry + pending + on-disk session file"
```

---

## Task 11: MetaStore.open 从会话文件重建索引（容错）

**Files:**
- Modify: `src/agent_history_store.zig`

- [ ] **Step 1: 写失败测试**

```zig
test "MetaStore: rebuilds index from session files when index missing/corrupt; skips bad files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    // Seed two good session files via a first store, then drop index.json.
    {
        var store = try MetaStore.open(allocator, root);
        defer store.deinit();
        inline for (.{ "s1", "s2" }) |sid| {
            try store.upsertRecord(.{
                .session_id = sid, .title = "T", .base_url = "u", .api_key = "k", .model = "m",
                .system_prompt = "s", .thinking_enabled = false, .reasoning_effort = "low",
                .stream = true, .agent_enabled = true, .created_at = 1, .updated_at = 2,
                .messages = &[_]agent_history.MessageRecord{},
            });
        }
        try store.flush();
    }
    // open(allocator, root) uses dir == root, so index.json is at root/index.json
    // and session files live under root/sessions/.
    try tmp.dir.deleteFile("index.json");
    // Drop a corrupt session file that must be skipped on rebuild.
    try tmp.dir.writeFile(.{ .sub_path = "sessions/broken.json", .data = "{ not json" });

    var rebuilt = try MetaStore.open(allocator, root);
    defer rebuilt.deinit();
    const rows = try rebuilt.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 失败——`open` 在缺 index 时不重建（rows.len==0），`rebuildIndexFromSessions` 未定义。

- [ ] **Step 3: 实现**：加入 `rebuildIndexFromSessions`，并在 `open` 的 `loadIndexFromDisk` 之后接入。

MetaStore 内新增：

```zig
    fn rebuildIndexFromSessions(self: *MetaStore) !void {
        const sessions = try self.sessionsDirPath(self.allocator);
        defer self.allocator.free(sessions);
        var dir = std.fs.cwd().openDir(sessions, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.endsWith(u8, ent.name, ".json")) continue;
            const bytes = dir.readFileAlloc(self.allocator, ent.name, agent_history.MAX_SESSION_BYTES) catch continue;
            defer self.allocator.free(bytes);
            var rec = agent_history.recordFromJson(self.allocator, bytes) catch continue;
            defer agent_history.freeOwnedRecord(self.allocator, &rec);
            const entry = try agent_history.recordToIndexEntry(self.allocator, rec);
            self.entries.append(self.allocator, entry) catch |err| {
                var owned = entry;
                agent_history.freeOwnedIndexEntry(self.allocator, &owned);
                return err;
            };
        }
    }
```

把 `open` 中的尾段改为：

```zig
        if (try self.loadIndexFromDisk()) return self;

        try self.rebuildIndexFromSessions();
        if (self.entries.items.len > 0) {
            self.index_dirty = true;
            try self.flush(); // persist freshly rebuilt index.json
        }
        return self;
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history_store.zig
git commit -m "feat(agent_history_store): rebuild index from session files, skip corrupt ones"
```

---

## Task 12: MetaStore.open 从旧单文件迁移

**Files:**
- Modify: `src/agent_history_store.zig`

- [ ] **Step 1: 写失败测试**（迁移依赖 `agent_history.defaultPath`，用 `setTestConfigDirForCurrentThread` 把 config dir 指到 tmp，使旧文件与新目录同根）

```zig
const platform_dirs = @import("platform/dirs.zig");

test "MetaStore: migrates legacy single file to dir layout, idempotently, keeps .bak" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);
    defer platform_dirs.clearTestConfigDirForCurrentThread();

    // Build a legacy agent-history.json with two records via the old Store.
    {
        var legacy = agent_history.Store.init(allocator);
        defer legacy.deinit();
        try legacy.upsertRecord(.{
            .session_id = "old-1", .title = "Old1", .base_url = "u", .api_key = "k", .model = "m",
            .system_prompt = "s", .thinking_enabled = false, .reasoning_effort = "low",
            .stream = true, .agent_enabled = true, .created_at = 1, .updated_at = 2, .copilot = true,
            .messages = &[_]agent_history.MessageRecord{.{ .role = .user, .content = "hey" }},
        });
        try legacy.upsertRecord(.{
            .session_id = "old-2", .title = "Old2", .base_url = "u", .api_key = "k", .model = "m",
            .system_prompt = "s", .thinking_enabled = false, .reasoning_effort = "low",
            .stream = true, .agent_enabled = true, .created_at = 3, .updated_at = 4,
            .messages = &[_]agent_history.MessageRecord{},
        });
        try legacy.saveDefault();
    }

    const dir = try platform_dirs.agentHistoryDir(allocator);
    defer allocator.free(dir);

    var store = try MetaStore.open(allocator, dir);
    defer store.deinit();
    const rows = try store.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);

    // Legacy renamed to .bak (original no longer accessible).
    const legacy_path = try agent_history.defaultPath(allocator);
    defer allocator.free(legacy_path);
    const legacy_exists = if (std.fs.cwd().access(legacy_path, .{})) |_| true else |_| false;
    try std.testing.expect(!legacy_exists);
    const bak_path = try std.fmt.allocPrint(allocator, "{s}.bak", .{legacy_path});
    defer allocator.free(bak_path);
    const bak_exists = if (std.fs.cwd().access(bak_path, .{})) |_| true else |_| false;
    try std.testing.expect(bak_exists);

    // Body recoverable from disk.
    var rec = (try store.cloneRecordBySessionId(allocator, "old-1")) orelse return error.Missing;
    defer agent_history.freeOwnedRecord(allocator, &rec);
    try std.testing.expect(rec.copilot);

    // Idempotent: a second open does not re-migrate (no legacy present anymore).
    var store2 = try MetaStore.open(allocator, dir);
    defer store2.deinit();
    const rows2 = try store2.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows2);
    try std.testing.expectEqual(@as(usize, 2), rows2.len);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 失败——`open` 不迁移（rows.len==0），`migrateLegacy` 未定义。

- [ ] **Step 3: 实现**：加入 `migrateLegacy`，并在 `open` 的重建分支之后、`return self` 之前接入。

MetaStore 内新增：

```zig
    fn migrateLegacy(self: *MetaStore) !bool {
        const legacy = try agent_history.defaultPath(self.allocator);
        defer self.allocator.free(legacy);

        const bytes = std.fs.cwd().readFileAlloc(self.allocator, legacy, MIGRATION_MAX_BYTES) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var store = agent_history.Store.fromJsonStringLenient(self.allocator, bytes) catch return false;
        defer store.deinit();

        for (store.records.items) |record| {
            try self.writeSessionFile(record);
            const entry = try agent_history.recordToIndexEntry(self.allocator, record);
            self.entries.append(self.allocator, entry) catch |err| {
                var owned = entry;
                agent_history.freeOwnedIndexEntry(self.allocator, &owned);
                return err;
            };
        }
        self.index_dirty = true;
        try self.flush(); // writes index.json (session files already written above)

        // Only after success: keep the original as a non-destructive backup.
        const bak = try std.fmt.allocPrint(self.allocator, "{s}.bak", .{legacy});
        defer self.allocator.free(bak);
        std.fs.cwd().rename(legacy, bak) catch |err| {
            std.log.scoped(.agent_history).warn("legacy history rename to .bak failed: {}", .{err});
        };
        return true;
    }
```

把 `open` 尾段改为：

```zig
        if (try self.loadIndexFromDisk()) return self;

        try self.rebuildIndexFromSessions();
        if (self.entries.items.len > 0) {
            self.index_dirty = true;
            try self.flush();
            return self;
        }

        _ = try self.migrateLegacy();
        return self;
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/agent_history_store.zig
git commit -m "feat(agent_history_store): one-time idempotent migration from legacy single file"
```

---

## Task 13: 接入 AppWindow（切换全局类型 + flush + 内联测试）

**Files:**
- Modify: `src/AppWindow.zig`（import；`g_agent_history` 类型 @1368；`ensureGlobalAgentHistoryStore` @5564；`flushAgentHistoryStoreIfDirty` @5659；内联测试 @1161/@1224/@1332）

- [ ] **Step 1: 改全局类型与 import**

在 AppWindow.zig 顶部 import 区（`agent_history` 已 import 处附近）加：

```zig
const agent_history_store = @import("agent_history_store.zig");
```

第 1368 行改为：

```zig
pub var g_agent_history: ?*agent_history_store.MetaStore = null;
```

- [ ] **Step 2: 改 ensureGlobalAgentHistoryStore（@5564）**

```zig
fn ensureGlobalAgentHistoryStore(allocator: std.mem.Allocator) !void {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (g_agent_history != null) return;

    const store = try allocator.create(agent_history_store.MetaStore);
    errdefer allocator.destroy(store);
    const dir = try platform_dirs.agentHistoryDir(allocator);
    defer allocator.free(dir);
    store.* = try agent_history_store.MetaStore.open(allocator, dir);
    g_agent_history = store;
    g_flush_scheduler.reset();
    g_agent_history_revision = 0;
}
```

- [ ] **Step 3: 改 flushAgentHistoryStoreIfDirty（@5659 整函数替换）**

```zig
fn flushAgentHistoryStoreIfDirty(force: bool) void {
    const now = std.time.milliTimestamp();
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (!g_flush_scheduler.shouldFlush(force, now)) return;
    const store = g_agent_history orelse return;
    store.flush() catch |err| {
        log.warn("failed to flush agent history store: {}", .{err});
        g_flush_scheduler.failFlush(std.time.milliTimestamp());
        return;
    };
    g_flush_scheduler.beginFlush();
}
```

- [ ] **Step 4: 改三处内联测试（@1161 / @1224 / @1332）**

把每处的：

```zig
    var store = agent_history.Store.init(allocator);
    defer store.deinit();
    g_agent_history = &store;
```

改为（每处函数体开头增加 tmp 目录变量；注意三处都在各自 test 内）：

```zig
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hist_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(hist_root);
    var store = try agent_history_store.MetaStore.open(allocator, hist_root);
    defer store.deinit();
    g_agent_history = &store;
```

这三处测试随后调用的 `store.upsertRecord(...)`、`store.cloneRecordBySessionId(...)`、以及通过 hook 走 `g_agent_history.?.cloneRecordBySessionId` 方法名均不变，pending 路径保证 flush 前即可读回。

- [ ] **Step 5: 运行确认通过**

Run: `zig build test-full`
Expected: PASS（AppWindow 测试在 full 套件）。若编译报 `snapshotAgentHistoryRowsForCommandPalette`/`deleteAiChatHistorySessionId` 等处类型不符，确认它们调用的 `buildRows`/`deleteBySessionId`/`cloneRecordBySessionId` 名称与 MetaStore 一致（应一致，无需改）。

- [ ] **Step 6: 提交**

```bash
git add src/AppWindow.zig
git commit -m "refactor(AppWindow): back global agent history with MetaStore (dir + lazy bodies)"
```

---

## Task 14: 接入 file_explorer（形参类型 + 内联测试）

**Files:**
- Modify: `src/file_explorer.zig`（import；`syncAgentHistoryRows` @320；内联测试 @2538/@2567/@2613）

- [ ] **Step 1: 加 import + 改形参类型**

顶部 import 区加：

```zig
const agent_history_store = @import("agent_history_store.zig");
```

第 320 行改为：

```zig
pub fn syncAgentHistoryRows(store: *const agent_history_store.MetaStore) void {
```

（函数体内 `store.buildRows(allocator)` 保持不变——MetaStore 同名 const 方法。）

- [ ] **Step 2: 改三处内联测试**

每处把：

```zig
    var store = agent_history.Store.init(allocator);
    defer store.deinit();
```

改为：

```zig
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hist_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(hist_root);
    var store = try agent_history_store.MetaStore.open(allocator, hist_root);
    defer store.deinit();
```

随后的 `store.upsertRecord(...)`、`syncAgentHistoryRows(&store)`、`store.deleteBySessionId(...)` 名称/语义不变；buildRows 从内存索引取值，upsert/delete 即时更新索引，无需 flush。

- [ ] **Step 3: 运行确认通过**

Run: `zig build test`
Expected: PASS（file_explorer 在 fast 套件）。

- [ ] **Step 4: 提交**

```bash
git add src/file_explorer.zig
git commit -m "refactor(file_explorer): sync history rows from MetaStore"
```

---

## Task 15: 全量验证与真机迁移冒烟

**Files:** 无代码改动（仅验证）

- [ ] **Step 1: fast 套件**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 2: full 套件（macOS）**

Run: `zig build test-full`
Expected: PASS。

- [ ] **Step 3: macOS 真机构建**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: 构建成功，产出 .app。

- [ ] **Step 4: 迁移冒烟（手动）**

1. 准备：确保 `~/Library/Application Support/wispterm/agent-history.json`（旧单文件）存在（可用上一个版本运行产生，或手工放置一个有效旧 JSON）。
2. 启动新构建的 app，打开「副驾历史」面板，确认历史条目与旧版一致。
3. 检查目录：`~/Library/Application Support/wispterm/agent-history/index.json` 与 `agent-history/sessions/*.json` 已生成；`agent-history.json.bak` 存在；原 `agent-history.json` 已不在。
4. 新建一个副驾会话、删除一条历史，确认 `sessions/` 与 `index.json` 随之增删。
5. 重启 app，确认列表内容稳定（走 index 加载路径）。

- [ ] **Step 5: 收尾提交（如有验证期间的小修）**

```bash
git add -A
git commit -m "test: verify history storage migration end-to-end"
```

---

## Self-Review（计划作者已核对）

**Spec coverage：**
- 多文件布局 / index → Task 2,7,9。
- 去 8MB 死线（按会话文件读、迁移用大上限）→ Task 5(`MAX_SESSION_BYTES`),12(`MIGRATION_MAX_BYTES`)。
- 索引派生可重建 / 损坏容错 → Task 11。
- 索引驱动 + 懒加载 → Task 7,8(`cloneRecordBySessionId` pending→disk),9(冷读)。
- 去抖写入（pending + flush）→ Task 8,9,13(flush 接 scheduler)。
- 迁移幂等 + `.bak` 不删 → Task 12。
- 文件名安全 → Task 3。
- 搜索预览（检索基础）→ Task 4。
- 调用点接入（AppWindow / file_explorer）→ Task 13,14。
- 验证（fast/full/macos-app/真机迁移）→ Task 15。

**Type 一致性：** `MetaStore.{open,deinit,buildRows,buildCopilotRows,cloneRecordBySessionId,upsertRecord,deleteBySessionId,flush}` 在 Task 7–10 定义、Task 13–14 调用一致；`agent_history.{IndexEntry,IndexFile,INDEX_VERSION,dumpIndex,parseIndex,cloneIndexEntry,freeOwnedIndexEntry,recordToIndexEntry,buildSearchPreview,SEARCH_PREVIEW_MAX,recordToJson,recordFromJson,MAX_SESSION_BYTES,sanitizeSessionFileName,buildRowsFromEntries,buildCopilotRowsFromEntries}` 在 Task 2–6 定义、Task 7–12 引用一致。`pending` 与 `entries` 均为 `ArrayListUnmanaged`，线性查找辅助 `entryIndex`/`pendingIndex` 在 Task 7 定义、后续复用。

**Placeholder 扫描：** 无 TBD/TODO；每个 code step 均给出完整代码与精确命令；Task 11/12 的路径与断言已按 `open(root)` 实际布局写实（无「执行时再改」遗留）。
