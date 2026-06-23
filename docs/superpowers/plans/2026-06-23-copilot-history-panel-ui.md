# 副驾历史面板 UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给命令面板「副驾历史」模态加上每行相对时间、本地日历日分组（今天/昨天/过去7天/更早）、实时 title+model 搜索、Tab 来源筛选。

**Architecture:** 过滤/分桶/相对时间/导航逻辑放进纯模块 `command_palette_history_view.zig`（可单测）；`renderCommandPalette` 历史分支、input 键位、`command_center_state` 状态、`i18n` 文案只做接线；新增一个 macOS e2e 输入驱动冒烟测试。

**Tech Stack:** Zig 0.15.2（`zig build test` / `test-full` / `macos-app`）、tests/macos_e2e（pytest + PyObjC + wisptermctl，`make test-macos-e2e`）。

**测试套件归属：**
- `command_palette_history_view.zig`（新建，需加进 `test_fast.zig`）、`command_center_state.zig`、`i18n.zig` 的内联测试 → `zig build test`（fast）。
- `overlays.zig`/`input.zig` 改动无内联单测，靠 `zig build test-full` 编译 + e2e + 手测。
- macOS app：`zig build macos-app -Dtarget=aarch64-macos`（默认 `zig build` 目标是 Windows）。

---

## File Structure

- **Create** `src/command_palette_history_view.zig` — 纯逻辑：`Bucket`/`SourceFilter`/`DisplayItem`/`localEpochDay`/`bucketFor`/`rowMatches`/`View`/`build`。
- **Modify** `src/test_fast.zig` — 加 `_ = @import("command_palette_history_view.zig");`。
- **Modify** `src/command_center_state.zig` — `command_palette_history_source` 字段 + `commandPaletteCycleHistorySource` + 进入历史模式时复位。
- **Modify** `src/i18n.zig` — 分组标题 / 来源标签 / 搜索 placeholder / footer 文案（中英）。
- **Modify** `src/renderer/overlays.zig` — 来源 threadlocal + snapshot/apply、`buildHistoryView` 辅助、move/delete/activate 改用过滤映射、`commandPaletteResultCount`/窗口化改为 items、历史分支渲染重写、cycle 包装。
- **Modify** `src/input.zig` — 历史模式启用字符/Backspace、Tab 切来源。
- **Modify** `tests/macos_e2e/driver/keycodes.py` — 加 `"p": 35`。
- **Create** `tests/macos_e2e/test_copilot_history.py` — 输入驱动冒烟（预置历史 + 终端 round-trip 断言）。

---

## Task 1: 视图模块 — localEpochDay + bucketFor

**Files:**
- Create: `src/command_palette_history_view.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: 建文件并写失败测试**

新建 `src/command_palette_history_view.zig`：

```zig
const std = @import("std");
const agent_history = @import("agent_history.zig");
const command_palette_model = @import("command_palette_model.zig");

pub const Bucket = enum { today, yesterday, past_week, earlier };
pub const SourceFilter = enum { all, sidebar, tab };

/// A flat display row: either a group header, or a session row referenced by its
/// ordinal into `View.filtered` (0..filtered.len).
pub const DisplayItem = union(enum) { header: Bucket, row: usize };

/// Local civil day number (floored), so day differences are linear and tz-correct.
pub fn localEpochDay(ms: i64, tz_offset_seconds: i32) i64 {
    return @divFloor(@divFloor(ms, 1000) + tz_offset_seconds, 86400);
}

pub fn bucketFor(now_ms: i64, row_ms: i64, tz_offset_seconds: i32) Bucket {
    const diff = localEpochDay(now_ms, tz_offset_seconds) - localEpochDay(row_ms, tz_offset_seconds);
    if (diff <= 0) return .today; // future/clock-skew falls into today
    if (diff == 1) return .yesterday;
    if (diff < 7) return .past_week;
    return .earlier;
}

test "history view: bucketFor classifies by local calendar day" {
    const tz: i32 = 8 * 3600;
    const day: i64 = 86400 * 1000;
    const now: i64 = 1_700_000_000_000;
    try std.testing.expectEqual(Bucket.today, bucketFor(now, now, tz));
    try std.testing.expectEqual(Bucket.today, bucketFor(now, now + day, tz));
    try std.testing.expectEqual(Bucket.yesterday, bucketFor(now, now - day, tz));
    try std.testing.expectEqual(Bucket.past_week, bucketFor(now, now - 2 * day, tz));
    try std.testing.expectEqual(Bucket.past_week, bucketFor(now, now - 6 * day, tz));
    try std.testing.expectEqual(Bucket.earlier, bucketFor(now, now - 7 * day, tz));
    try std.testing.expectEqual(Bucket.earlier, bucketFor(now, now - 30 * day, tz));
}
```

并在 `src/test_fast.zig` 紧跟 `_ = @import("command_center_state.zig");` 之后加：

```zig
    _ = @import("command_palette_history_view.zig");
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 失败（断言或编译）——确认 `bucketFor` 已被测试驱动。

- [ ] **Step 3: 实现已在 Step 1（bucketFor/localEpochDay 已写）** — 若 Step 2 因测试逻辑失败则修正，使其通过。

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/command_palette_history_view.zig src/test_fast.zig
git commit -m "feat(history-view): bucketFor classifies rows into today/yesterday/past-week/earlier"
```

---

## Task 2: 视图模块 — rowMatches

**Files:**
- Modify: `src/command_palette_history_view.zig`

- [ ] **Step 1: 写失败测试**（追加到文件）

```zig
test "history view: rowMatches filters by query and source" {
    const r_tab = agent_history.Row{ .session_id = "a", .title = "Deploy notes", .model = "deepseek-v4", .updated_at = 1, .copilot = false };
    const r_side = agent_history.Row{ .session_id = "b", .title = "Chat", .model = "gpt-x", .updated_at = 1, .copilot = true };
    try std.testing.expect(rowMatches(r_tab, "deploy", .all));
    try std.testing.expect(rowMatches(r_tab, "DEEPSEEK", .all)); // case-insensitive, matches model
    try std.testing.expect(!rowMatches(r_tab, "zzz", .all));
    try std.testing.expect(rowMatches(r_tab, "", .all)); // empty query matches
    try std.testing.expect(rowMatches(r_side, "", .sidebar));
    try std.testing.expect(!rowMatches(r_side, "", .tab));
    try std.testing.expect(rowMatches(r_tab, "", .tab));
    try std.testing.expect(!rowMatches(r_tab, "", .sidebar));
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `rowMatches` 未定义。

- [ ] **Step 3: 实现**（加在 `bucketFor` 之后）

```zig
pub fn rowMatches(row: agent_history.Row, query: []const u8, source: SourceFilter) bool {
    const src_ok = switch (source) {
        .all => true,
        .sidebar => row.copilot,
        .tab => !row.copilot,
    };
    if (!src_ok) return false;
    if (query.len == 0) return true;
    return command_palette_model.containsIgnoreCase(row.title, query) or
        command_palette_model.containsIgnoreCase(row.model, query);
}
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/command_palette_history_view.zig
git commit -m "feat(history-view): rowMatches filters by title/model query and source"
```

---

## Task 3: 视图模块 — View + build

**Files:**
- Modify: `src/command_palette_history_view.zig`

- [ ] **Step 1: 写失败测试**（追加）

```zig
test "history view: build groups, filters, and maps selection" {
    const a = std.testing.allocator;
    const day: i64 = 86400 * 1000;
    const now: i64 = 10_000 * day;
    const rows = [_]agent_history.Row{
        .{ .session_id = "1", .title = "Today A", .model = "m", .updated_at = now, .copilot = false },
        .{ .session_id = "2", .title = "Today B", .model = "m", .updated_at = now - 1000, .copilot = true },
        .{ .session_id = "3", .title = "Yesterday", .model = "m", .updated_at = now - day, .copilot = false },
        .{ .session_id = "4", .title = "Old", .model = "m", .updated_at = now - 20 * day, .copilot = false },
    };

    var v = try build(a, &rows, "", .all, now, 0);
    defer v.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), v.rowCount());
    // items = header(today),row0,row1, header(yesterday),row2, header(earlier),row3
    try std.testing.expectEqual(@as(usize, 7), v.items.len);
    try std.testing.expect(std.meta.activeTag(v.items[0]) == .header);
    try std.testing.expectEqual(Bucket.today, v.items[0].header);
    try std.testing.expect(std.meta.activeTag(v.items[1]) == .row);
    try std.testing.expectEqual(@as(usize, 0), v.items[1].row);
    try std.testing.expectEqual(Bucket.yesterday, v.items[3].header);
    try std.testing.expectEqual(@as(usize, 0), v.filtered[0]);
    try std.testing.expectEqual(@as(usize, 3), v.filtered[3]);

    var v2 = try build(a, &rows, "", .sidebar, now, 0);
    defer v2.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), v2.rowCount());
    try std.testing.expectEqual(@as(usize, 1), v2.filtered[0]);

    var v3 = try build(a, &rows, "yesterday", .all, now, 0);
    defer v3.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), v3.rowCount());

    var v4 = try build(a, &rows, "zzzzz", .all, now, 0);
    defer v4.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), v4.rowCount());
    try std.testing.expectEqual(@as(usize, 0), v4.items.len);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `View` / `build` 未定义。

- [ ] **Step 3: 实现**（加在 `rowMatches` 之后）

```zig
pub const View = struct {
    items: []DisplayItem,
    filtered: []usize, // original-row indices in display order; selectable count = len

    pub fn rowCount(self: *const View) usize {
        return self.filtered.len;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        allocator.free(self.filtered);
        self.* = undefined;
    }
};

/// `rows` must already be sorted newest-first (MetaStore.buildRows guarantees this),
/// so buckets are contiguous and one header is emitted per bucket transition.
pub fn build(
    allocator: std.mem.Allocator,
    rows: []const agent_history.Row,
    query: []const u8,
    source: SourceFilter,
    now_ms: i64,
    tz_offset_seconds: i32,
) !View {
    var items: std.ArrayListUnmanaged(DisplayItem) = .empty;
    errdefer items.deinit(allocator);
    var filtered: std.ArrayListUnmanaged(usize) = .empty;
    errdefer filtered.deinit(allocator);

    var have_bucket = false;
    var cur_bucket: Bucket = .today;
    for (rows, 0..) |row, i| {
        if (!rowMatches(row, query, source)) continue;
        const b = bucketFor(now_ms, row.updated_at, tz_offset_seconds);
        if (!have_bucket or b != cur_bucket) {
            try items.append(allocator, .{ .header = b });
            cur_bucket = b;
            have_bucket = true;
        }
        const ord = filtered.items.len;
        try filtered.append(allocator, i);
        try items.append(allocator, .{ .row = ord });
    }
    return .{
        .items = try items.toOwnedSlice(allocator),
        .filtered = try filtered.toOwnedSlice(allocator),
    };
}
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/command_palette_history_view.zig
git commit -m "feat(history-view): build grouped display items + filtered selection mapping"
```

---

## Task 4: 来源筛选状态（command_center_state + overlays 桥接）

**Files:**
- Modify: `src/command_center_state.zig`
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: 写失败测试**（追加到 `src/command_center_state.zig` 测试区）

```zig
test "command palette: history source cycles and resets on open" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.all, state.command_palette_history_source);
    state.commandPaletteCycleHistorySource();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.sidebar, state.command_palette_history_source);
    state.commandPaletteCycleHistorySource();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.tab, state.command_palette_history_source);
    state.commandPaletteCycleHistorySource();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.all, state.command_palette_history_source);
    // re-open resets to all + selection 0 + empty filter
    state.command_palette_history_source = .tab;
    state.command_palette_history_selected = 5;
    state.command_palette_filter_len = 3;
    state.commandPaletteOpenAgentHistory();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.all, state.command_palette_history_source);
    try std.testing.expectEqual(@as(usize, 0), state.command_palette_history_selected);
    try std.testing.expectEqual(@as(usize, 0), state.command_palette_filter_len);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `command_palette_history_view` 未导入 / `command_palette_history_source` 字段缺失。

- [ ] **Step 3: 实现 — command_center_state.zig**

文件顶部 import 区加：

```zig
const command_palette_history_view = @import("command_palette_history_view.zig");
```

`State` 结构里，在 `command_palette_history_selected: usize = 0,` 之后加字段：

```zig
    command_palette_history_source: command_palette_history_view.SourceFilter = .all,
```

`commandPaletteOpenAgentHistory` 改为（在原有 visibility 复位基础上补三行复位）：

```zig
pub fn commandPaletteOpenAgentHistory(self: *State) void {
    self.commandPaletteOpen();
    self.commandPaletteSetMode(.agent_history);
    self.session_launcher_visible = false;
    self.ssh_list_visible = false;
    self.ssh_form_visible = false;
    self.ai_list_visible = false;
    self.ai_form_visible = false;
    self.ai_history_source_visible = false;
    self.command_palette_history_source = .all;
    self.command_palette_history_selected = 0;
    self.command_palette_filter_len = 0;
}
```

并新增循环方法（放在 `commandPaletteLeaveAgentHistory` 附近）：

```zig
pub fn commandPaletteCycleHistorySource(self: *State) void {
    self.command_palette_history_source = switch (self.command_palette_history_source) {
        .all => .sidebar,
        .sidebar => .tab,
        .tab => .all,
    };
    self.command_palette_history_selected = 0;
}
```

- [ ] **Step 4: 实现 — overlays.zig 桥接 threadlocal**

在 threadlocal 变量区（`g_command_palette_history_selected` 附近，约 220-229）加：

```zig
threadlocal var g_command_palette_history_source: command_palette_history_view.SourceFilter = .all;
```

文件顶部 import 区加（与其他 `@import("../xxx.zig")` 同处）：

```zig
const command_palette_history_view = @import("../command_palette_history_view.zig");
```

`commandCenterStateSnapshot()` 的返回字面量里加一行：

```zig
        .command_palette_history_source = g_command_palette_history_source,
```

`commandCenterStateApply()` 里加一行：

```zig
    g_command_palette_history_source = state.command_palette_history_source;
```

并加面向输入层的包装（放在 `commandPaletteMoveAgentHistory` 附近）：

```zig
pub fn commandPaletteCycleHistorySource() void {
    var state = commandCenterStateSnapshot();
    state.commandPaletteCycleHistorySource();
    commandCenterStateCommit(state);
}
```

- [ ] **Step 5: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add src/command_center_state.zig src/renderer/overlays.zig
git commit -m "feat(command-center): history source-filter state + snapshot/apply bridge"
```

---

## Task 5: i18n 文案（分组 / 来源 / placeholder / footer）

**Files:**
- Modify: `src/i18n.zig`

- [ ] **Step 1: 写失败测试**（追加到 i18n.zig 测试区）

```zig
test "i18n: history panel strings present in both locales" {
    defer setLang(.en); // 复位，避免污染其它测试（与现有 "setLang switches..." 测试同款）
    setLang(.en);
    try std.testing.expectEqualStrings("Today", s().cmd_palette_group_today);
    try std.testing.expectEqualStrings("Sidebar", s().cmd_palette_source_sidebar);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("今天", s().cmd_palette_group_today);
    try std.testing.expectEqualStrings("过去7天", s().cmd_palette_group_past_week);
    try std.testing.expectEqualStrings("侧栏", s().cmd_palette_source_sidebar);
}
```

> `setLang(.en)`/`setLang(.zh_CN)` 是 i18n.zig:665 的现成切换函数（见现有测试 "setLang switches the active strings table"）。

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译错误 `cmd_palette_group_today` 等字段缺失。

- [ ] **Step 3: 实现 — 三处新增字段**

(a) `Strings` 结构声明区（`cmd_palette_sidebar_tag` 之后）加：

```zig
cmd_palette_group_today: []const u8,
cmd_palette_group_yesterday: []const u8,
cmd_palette_group_past_week: []const u8,
cmd_palette_group_earlier: []const u8,
cmd_palette_source_all: []const u8,
cmd_palette_source_sidebar: []const u8,
cmd_palette_source_tab: []const u8,
cmd_palette_history_search_placeholder: []const u8,
```

(b) 英文 locale（`.cmd_palette_sidebar_tag = "Sidebar",` 之后）：

```zig
.cmd_palette_group_today = "Today",
.cmd_palette_group_yesterday = "Yesterday",
.cmd_palette_group_past_week = "Past 7 days",
.cmd_palette_group_earlier = "Earlier",
.cmd_palette_source_all = "All",
.cmd_palette_source_sidebar = "Sidebar",
.cmd_palette_source_tab = "Tab",
.cmd_palette_history_search_placeholder = "Search Copilot history",
```

并把英文 `cmd_palette_footer_history` 改为：

```zig
.cmd_palette_footer_history = "Type to filter, Tab source, Up/Down, Enter reopens, Delete removes, Esc returns",
```

(c) 中文 locale（`.cmd_palette_sidebar_tag = "侧栏",` 之后）：

```zig
.cmd_palette_group_today = "今天",
.cmd_palette_group_yesterday = "昨天",
.cmd_palette_group_past_week = "过去7天",
.cmd_palette_group_earlier = "更早",
.cmd_palette_source_all = "全部",
.cmd_palette_source_sidebar = "侧栏",
.cmd_palette_source_tab = "标签页",
.cmd_palette_history_search_placeholder = "搜索副驾历史",
```

并把中文 `cmd_palette_footer_history` 改为：

```zig
.cmd_palette_footer_history = "输入筛选，Tab 来源，上下选择，回车重开，Delete 删除，Esc 返回",
```

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/i18n.zig
git commit -m "feat(i18n): copilot history group/source/search strings (en+zh)"
```

---

## Task 6: overlays 历史导航改用过滤映射（buildHistoryView + move/delete/activate）

**Files:**
- Modify: `src/renderer/overlays.zig`

目标：把 move/delete/activate 从"直接索引 `g_command_palette_history_rows`"改为"基于当前过滤后的 View 的序号 → 原始行下标"。空查询 + `.all` 时行为与现状一致。

- [ ] **Step 1: 加 `buildHistoryView` 辅助**（放在 `commandPaletteSyncAgentHistoryRows` 附近）

```zig
const ai_history_time = @import("../ai_history_time.zig");

/// Build the current filtered/grouped view from the loaded history rows + live
/// filter/source. Caller owns the View and must `deinit` it. Null on no allocator.
fn buildHistoryView() ?command_palette_history_view.View {
    const allocator = AppWindow.g_allocator orelse return null;
    const now_ms = std.time.milliTimestamp();
    const tz = ai_history_time.localOffsetSeconds();
    return command_palette_history_view.build(
        allocator,
        g_command_palette_history_rows,
        commandPaletteFilter(),
        g_command_palette_history_source,
        now_ms,
        tz,
    ) catch null;
}
```

> `ai_history_time` 的 import 路径按 overlays.zig 现有相对路径风格（`../`）书写。

- [ ] **Step 2: move 改用过滤计数**

把 `commandPaletteMoveAgentHistory` 改为：

```zig
pub fn commandPaletteMoveAgentHistory(delta: i32) void {
    commandPaletteSyncAgentHistoryRows();
    var view = buildHistoryView() orelse {
        // Fallback: move over unfiltered rows.
        var state0 = commandCenterStateSnapshot();
        state0.commandPaletteMoveAgentHistory(delta, g_command_palette_history_rows.len);
        commandCenterStateCommit(state0);
        return;
    };
    defer view.deinit(AppWindow.g_allocator.?);
    var state = commandCenterStateSnapshot();
    state.commandPaletteMoveAgentHistory(delta, view.rowCount());
    commandCenterStateCommit(state);
}
```

- [ ] **Step 3: delete 改用 filtered 映射**

把 `commandPaletteDeleteSelectedAgentHistory` 改为：

```zig
pub fn commandPaletteDeleteSelectedAgentHistory() bool {
    if (!commandPaletteIsHistoryMode()) return false;
    commandPaletteSyncAgentHistoryRows();
    var view = buildHistoryView() orelse return false;
    defer view.deinit(AppWindow.g_allocator.?);
    const state = commandCenterStateSnapshot();
    const ord = state.commandPaletteSelectedAgentHistoryIndex(view.rowCount()) orelse return false;
    const orig = view.filtered[ord];
    return commandPaletteDeleteAgentHistoryIndex(orig);
}
```

`commandPaletteDeleteAgentHistoryIndex` 末尾的 clamp 仍按总行数 `g_command_palette_history_rows.len`——保持不变（删除后选中会在下次 move/render 经过滤重新夹持）。

- [ ] **Step 4: activate 改用 filtered 映射**

把 `commandPaletteActivateSelectedAgentHistory` 改为：

```zig
fn commandPaletteActivateSelectedAgentHistory() bool {
    if (!commandPaletteIsHistoryMode()) return false;
    commandPaletteSyncAgentHistoryRows();
    var view = buildHistoryView() orelse return false;
    defer view.deinit(AppWindow.g_allocator.?);
    const state = commandCenterStateSnapshot();
    const ord = state.commandPaletteActivateSelected(view.rowCount()) orelse return false;
    const orig = view.filtered[ord];
    return commandPaletteActivateAgentHistoryIndex(orig);
}
```

- [ ] **Step 5: 运行确认编译 + fast 套件通过**

Run: `zig build test`
Expected: PASS（fast 套件不含 overlays 渲染测试，但会编译 overlays.zig 经依赖；若 fast 不编译 overlays，则改跑 `zig build test-full`）。
若 fast 不触达 overlays，Run: `zig build test-full`，Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add src/renderer/overlays.zig
git commit -m "refactor(command-center): history nav/delete/activate operate on filtered view"
```

---

## Task 7: overlays 历史分支渲染重写（相对时间 + 分组 + 来源 chip + 可编辑搜索 + items 窗口化）

**Files:**
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: 加 items 计数 threadlocal + 历史 result count + 窗口/标签辅助**

threadlocal 区加：

```zig
threadlocal var g_command_palette_history_item_count: usize = 0;
```

加分组标题文案映射 + 来源 chip 文案 + 窗口辅助（放在 `commandPaletteFirstVisibleIndex` 附近）：

```zig
fn historyBucketLabel(b: command_palette_history_view.Bucket) []const u8 {
    return switch (b) {
        .today => i18n.s().cmd_palette_group_today,
        .yesterday => i18n.s().cmd_palette_group_yesterday,
        .past_week => i18n.s().cmd_palette_group_past_week,
        .earlier => i18n.s().cmd_palette_group_earlier,
    };
}

fn historySourceLabel(src: command_palette_history_view.SourceFilter) []const u8 {
    return switch (src) {
        .all => i18n.s().cmd_palette_source_all,
        .sidebar => i18n.s().cmd_palette_source_sidebar,
        .tab => i18n.s().cmd_palette_source_tab,
    };
}

/// First visible item index that keeps `focus_item` (the selected row's item
/// index) inside a window of `rendered` items out of `count`.
fn historyWindowStart(count: usize, rendered: usize, focus_item: usize) usize {
    if (rendered == 0 or count <= rendered) return 0;
    if (focus_item < rendered) return 0;
    return @min(focus_item - rendered + 1, count - rendered);
}

/// The items-index of the row whose ordinal == selected_ord (0 if not found).
fn historySelectedItemIndex(view: command_palette_history_view.View, selected_ord: usize) usize {
    for (view.items, 0..) |it, i| {
        switch (it) {
            .row => |ord| if (ord == selected_ord) return i,
            .header => {},
        }
    }
    return 0;
}
```

- [ ] **Step 2: 让 `commandPaletteResultCount` 在历史模式返回 items 数**

`commandPaletteResultCount` 当前为：

```zig
fn commandPaletteResultCount() usize {
    if (commandPaletteIsHistoryMode()) return g_command_palette_history_rows.len;
    return commandPaletteVisibleCount();
}
```

把历史分支的 `g_command_palette_history_rows.len` 改为 items 数：

```zig
fn commandPaletteResultCount() usize {
    if (commandPaletteIsHistoryMode()) return g_command_palette_history_item_count;
    return commandPaletteVisibleCount();
}
```

- [ ] **Step 3: 在 renderCommandPalette 顶部构建一次 View 并暴露 item 数**

在 `renderCommandPalette` 里、`commandPaletteSyncAgentHistoryRows();` 之后、`const layout = commandPaletteLayout(...)` 之前插入：

```zig
    var history_view: ?command_palette_history_view.View = null;
    const hist_alloc = AppWindow.g_allocator;
    defer if (history_view) |*v| {
        if (hist_alloc) |a| v.deinit(a);
    };
    const hist_now_ms = std.time.milliTimestamp();
    if (commandPaletteIsHistoryMode()) {
        history_view = buildHistoryView();
        g_command_palette_history_item_count = if (history_view) |v| v.items.len else 0;
    }
```

- [ ] **Step 4: 重写历史搜索框 + 历史列表渲染**

把历史模式的"搜索框提示"分支（当前显示 `cmd_palette_recent_sessions` 静态提示）改为显示可编辑 query：

```zig
    if (commandPaletteIsHistoryMode()) {
        const filter = commandPaletteFilter();
        if (filter.len > 0) {
            renderTitlebarTextLimited(filter, filter_x + 12, filter_text_y, fg, filter_w - 24);
        } else {
            renderTitlebarTextLimited(i18n.s().cmd_palette_history_search_placeholder, filter_x + 12, filter_text_y, dim, filter_w - 24);
        }
    } else {
        // ... 命令模式 filter 渲染保持原状 ...
    }
```

在标题栏画来源 chip：紧接标题/esc 提示渲染之后加（历史模式才画）：

```zig
    if (commandPaletteIsHistoryMode()) {
        const chip = historySourceLabel(g_command_palette_history_source);
        const chip_w = measureTitlebarText(chip);
        const chip_x = layout.box_x + layout.box_w - pad_x - measureTitlebarText(esc_hint) - 16 - chip_w;
        renderTitlebarText(chip, chip_x, title_y, mixColor(fg, accent, 0.20));
    }
```

把历史**列表**渲染分支整体替换为基于 `history_view` 的 items 窗口化：

```zig
    if (commandPaletteIsHistoryMode()) {
        const view_opt = history_view;
        const selectable = if (view_opt) |v| v.rowCount() else 0;
        if (view_opt == null or selectable == 0) {
            const empty_text = if (g_command_palette_history_rows.len == 0)
                i18n.s().cmd_palette_no_sessions
            else
                i18n.s().cmd_palette_no_sessions; // 无会话 / 无匹配 共用：见下注
            const empty_y = @round(window_height - layout.row_top_px - layout.row_h + (layout.row_h - overlayTextHeight()) / 2);
            renderTitlebarText(empty_text, layout.box_x + (layout.box_w - measureTitlebarText(empty_text)) / 2, empty_y, muted);
        } else {
            const view = view_opt.?;
            const selected_ord = @min(g_command_palette_history_selected, selectable - 1);
            const focus_item = historySelectedItemIndex(view, selected_ord);
            const first_item = historyWindowStart(view.items.len, layout.rendered_rows, focus_item);

            var display_row: usize = 0;
            while (display_row < layout.rendered_rows) : (display_row += 1) {
                const item_idx = first_item + display_row;
                if (item_idx >= view.items.len) break;
                const row_top = @round(layout.row_top_px + @as(f32, @floatFromInt(display_row)) * layout.row_h);
                const row_y = @round(window_height - row_top - layout.row_h);
                const text_y = rowTextY(row_y, layout.row_h);
                switch (view.items[item_idx]) {
                    .header => |b| {
                        const label = historyBucketLabel(b);
                        renderTitlebarText(label, @round(layout.box_x + pad_x + 2), text_y, mixColor(bg, fg, 0.40));
                    },
                    .row => |ord| {
                        const row = g_command_palette_history_rows[view.filtered[ord]];
                        const selected = ord == selected_ord;
                        if (selected) {
                            renderRoundedQuadAlpha(layout.box_x + 12, row_y + 4, layout.box_w - 24, layout.row_h - 8, 5, selected_border, 0.38);
                            renderRoundedQuadAlpha(layout.box_x + 13, row_y + 5, layout.box_w - 26, layout.row_h - 10, 4, selected_bg, 0.78);
                        }
                        const row_title_color = if (selected) fg else mixColor(bg, fg, 0.86);
                        const meta_color = if (selected) mixColor(fg, accent, 0.08) else mixColor(bg, fg, 0.54);
                        const title_x = @round(layout.box_x + pad_x + 2);
                        const meta_right = layout.box_x + layout.box_w - pad_x;

                        // Rightmost: relative time. Left of it: model / "Sidebar" tag.
                        var tbuf: [32]u8 = undefined;
                        const rel = copilot_picker.formatRelativeTime(hist_now_ms, row.updated_at, &tbuf);
                        const rel_w = measureTitlebarText(rel);
                        renderTitlebarText(rel, meta_right - rel_w, text_y, meta_color);

                        const tag = if (row.copilot) i18n.s().cmd_palette_sidebar_tag else row.model;
                        var title_limit_right = meta_right - rel_w - 14;
                        if (tag.len > 0) {
                            const tag_w = measureTitlebarText(tag);
                            renderTitlebarText(tag, title_limit_right - tag_w, text_y, meta_color);
                            title_limit_right = title_limit_right - tag_w - 14;
                        }
                        renderTitlebarTextLimited(row.title, title_x, text_y, row_title_color, title_limit_right - title_x);
                    },
                }
            }
        }
    } else {
        // ... 命令模式列表渲染保持原状 ...
    }
```

> 注：上面"无会话/无匹配"暂复用 `cmd_palette_no_sessions`。若想区分，可在 i18n 另加 `cmd_palette_no_matches`（"无匹配"/"No matches"）并在 `g_command_palette_history_rows.len != 0` 分支用它——可选，不做也可。
> `copilot_picker` 已被 overlays.zig 引用（picker 渲染处用过 `copilot_picker.formatRelativeTime`），无需新增 import。

- [ ] **Step 5: 编译 + 全量验证**

Run: `zig build test-full`
Expected: PASS（编译通过；overlays 改动靠编译 + 后续 e2e/手测验证）。

- [ ] **Step 6: 提交**

```bash
git add src/renderer/overlays.zig
git commit -m "feat(command-center): render copilot history with relative time, date groups, source chip, live search"
```

---

## Task 8: input — 历史模式启用字符/Backspace + Tab 切来源

**Files:**
- Modify: `src/renderer/overlays.zig`（解除 insertChar/backspace 历史守卫，历史下重置选中）
- Modify: `src/input.zig`（历史键位加 Tab/Backspace；字符输入已对命令面板生效，无需改 input.zig 字符分支）

- [ ] **Step 1: overlays.zig 解除历史守卫，历史下编辑 query 重置选中**

`commandPaletteInsertChar` 改为：

```zig
pub fn commandPaletteInsertChar(codepoint: u21) void {
    if (codepoint < 0x20 or codepoint == 0x7f) return;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return;
    if (g_command_palette_filter_len + len > g_command_palette_filter.len) return;
    @memcpy(g_command_palette_filter[g_command_palette_filter_len..][0..len], buf[0..len]);
    g_command_palette_filter_len += len;
    if (commandPaletteIsHistoryMode()) {
        g_command_palette_history_selected = 0;
    } else {
        commandPaletteClampSelection();
    }
}
```

`commandPaletteBackspace` 改为：

```zig
pub fn commandPaletteBackspace() void {
    if (g_command_palette_filter_len == 0) return;
    var n = g_command_palette_filter_len - 1;
    while (n > 0 and (g_command_palette_filter[n] & 0xC0) == 0x80) n -= 1;
    g_command_palette_filter_len = n;
    if (commandPaletteIsHistoryMode()) {
        g_command_palette_history_selected = 0;
    } else {
        commandPaletteClampSelection();
    }
}
```

- [ ] **Step 2: input.zig 历史键位加 Tab + Backspace**

把历史模式 switch（约 2930）改为：

```zig
        if (overlays.commandPaletteAgentHistoryVisible()) {
            switch (ev.key_code) {
                platform_input.key_escape => overlays.commandPaletteLeaveAgentHistory(),
                platform_input.key_up => overlays.commandPaletteMoveAgentHistory(-1),
                platform_input.key_down => overlays.commandPaletteMoveAgentHistory(1),
                platform_input.key_enter => overlays.commandPaletteExecuteSelected(),
                platform_input.key_delete => _ = overlays.commandPaletteDeleteSelectedAgentHistory(),
                platform_input.key_backspace => overlays.commandPaletteBackspace(),
                platform_input.key_tab => overlays.commandPaletteCycleHistorySource(),
                else => {},
            }
        } else {
```

> `platform_input.key_tab`（= 0x09）与 `key_backspace`（= 0x08）均定义在 `src/platform/input_events.zig`，确认可用。字符输入路径（input.zig 字符分支调 `overlays.commandPaletteInsertChar`，在 `commandPaletteVisible()` 时统一生效）无需改动——Step 1 解除 `commandPaletteInsertChar` 的历史守卫后，历史模式即可接收字符。

- [ ] **Step 3: 编译 + 全量验证**

Run: `zig build test-full`
Expected: PASS。

- [ ] **Step 4: 提交**

```bash
git add src/renderer/overlays.zig src/input.zig
git commit -m "feat(command-center): enable history search input + Tab source cycling"
```

---

## Task 9: macOS e2e — keycode + 输入驱动冒烟

**Files:**
- Modify: `tests/macos_e2e/driver/keycodes.py`
- Create: `tests/macos_e2e/test_copilot_history.py`

- [ ] **Step 1: keycodes 加 "p"**

在 `tests/macos_e2e/driver/keycodes.py` 的 `_KEYCODES` 字典里，给字母行补上 `p`（macOS virtual keycode 35）：

```python
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "t": 17, "n": 45, "p": 35,
```

- [ ] **Step 2: 写 e2e 测试**

新建 `tests/macos_e2e/test_copilot_history.py`：

```python
import json
import os
import time

import pytest

from tests.macos_e2e.conftest import APP_BUNDLE, CTL_BINARY
from tests.macos_e2e.driver.macos import MacDriver


def _session_record(session_id: str, title: str, model: str, updated_at_ms: int, copilot: bool):
    return {
        "session_id": session_id,
        "title": title,
        "base_url": "https://api.example.com",
        "api_key": "k",
        "model": model,
        "protocol": "chat_completions",
        "system_prompt": "sys",
        "thinking_enabled": False,
        "reasoning_effort": "low",
        "stream": True,
        "max_tokens": 8192,
        "agent_enabled": True,
        "vision_enabled": False,
        "copilot": copilot,
        "created_at": updated_at_ms,
        "updated_at": updated_at_ms,
        "messages": [{"role": "user", "content": f"hello from {title}"}],
    }


@pytest.fixture()
def seeded_app():
    """A fresh isolated WispTerm instance pre-seeded with copilot history sessions.

    Writing only sessions/*.json (no index.json) exercises the storage layer's
    index-rebuild path on first launch.
    """
    driver = MacDriver(app_bundle=APP_BUNDLE, ctl_binary=CTL_BINARY)
    sessions_dir = os.path.join(driver._config_dir(), "agent-history", "sessions")
    os.makedirs(sessions_dir, exist_ok=True)
    now_ms = int(time.time() * 1000)
    day = 86400 * 1000
    seeds = [
        _session_record("hist-deploy", "Deploy notes", "deepseek-v4", now_ms, False),
        _session_record("hist-sidebar", "Sidebar chat", "glm-5", now_ms - day, True),
        _session_record("hist-old", "Old planning", "gpt-x", now_ms - 20 * day, False),
    ]
    for rec in seeds:
        with open(os.path.join(sessions_dir, f"{rec['session_id']}.json"), "w") as f:
            json.dump(rec, f)
    driver.launch()
    yield driver
    driver.quit()


@pytest.mark.e2e
@pytest.mark.macos_only
def test_copilot_history_input_driven(seeded_app):
    app = seeded_app
    app.focus()
    pane = app.primary_pane()

    # Baseline: app is alive and the terminal round-trips.
    app.send_text("echo before-history\n")
    app.wait_for(pane, "before-history", timeout=8)

    # Open the command palette (default keybind Ctrl+Shift+P), then select the
    # "Copilot History" command to enter history mode. Default locale is English.
    app.key("p", "ctrl", "shift")
    time.sleep(0.3)
    app.text("Copilot History")  # filters the command list to the history entry
    time.sleep(0.3)
    app.key("return")  # execute -> enters history mode (panel shows seeded rows)
    time.sleep(0.3)

    # Exercise the new history-mode input handlers (must not crash / not eat input):
    app.text("deploy")     # live title filter
    time.sleep(0.2)
    app.key("down")        # navigate filtered rows (skips group headers)
    app.key("up")
    app.key("delete")      # backspace one char of the query
    app.key("tab")         # cycle source filter all -> sidebar
    app.key("tab")         # -> tab
    time.sleep(0.2)
    app.key("escape")      # leave history mode
    app.key("escape")      # close palette

    # The whole overlay-input flow must have left the app responsive and must NOT
    # have eaten subsequent terminal input. (overlay text itself is unobservable
    # via get-text; covered by unit tests instead.)
    app.send_text("echo after-history\n")
    app.wait_for(pane, "after-history", timeout=8)
```

> 说明：`app.key("delete")` 在历史模式映射为 Backspace（编辑 query）——driver 的 `"delete"` keycode 51 是主键盘的退格键（macOS 上 keycode 51 即 Backspace），对应我们绑定的 `key_backspace`/`key_delete` 取决于平台映射；若该键触发的是"删除会话"而非退格，改用一个不会误删的序列（去掉这行 `delete`，仅保留 `text`/`down`/`up`/`tab`）。本测试的硬断言只在最后的终端 round-trip，删/退格仅作"输入不致命"的压测。

- [ ] **Step 3: 运行 e2e**

Run: `make test-macos-e2e`
Expected: 新测试 `test_copilot_history_input_driven` PASS（需 macOS + 已授权辅助功能；CI/无头环境会 skip）。若因"进入历史模式的命令筛选"不稳定，按 Step 2 注释将进入方式调整为更稳的序列，但保持最后的终端 round-trip 断言不变。

- [ ] **Step 4: 提交**

```bash
git add tests/macos_e2e/driver/keycodes.py tests/macos_e2e/test_copilot_history.py
git commit -m "test(e2e): input-driven copilot history smoke (seeded sessions + responsiveness)"
```

---

## Task 10: 全量验证

**Files:** 无代码改动（仅验证）

- [ ] **Step 1: fast 套件** — Run: `zig build test` — Expected: PASS。
- [ ] **Step 2: full 套件** — Run: `zig build test-full` — Expected: PASS。
- [ ] **Step 3: macOS 构建** — Run: `zig build macos-app -Dtarget=aarch64-macos` — Expected: 构建成功。
- [ ] **Step 4: e2e** — Run: `make test-macos-e2e` — Expected: 新 e2e PASS（或在不满足环境时 skip）。
- [ ] **Step 5: 手测**（真机）：打开副驾历史 → 每行右侧有相对时间、列表按 今天/昨天/过去7天/更早 分组 → 输入筛 title/model → ↑↓ 跳过分组标题 → Tab 切来源 chip（全部/侧栏/标签页）→ 回车重开 → Esc 返回。

---

## Self-Review（计划作者已核对）

**Spec coverage：**
- 相对时间 → Task 7（formatRelativeTime 每行）。
- 时间分组（今天/昨天/过去7天/更早）→ Task 1（bucketFor）+ Task 3（build 插 header）+ Task 7（渲染 header）。
- 启用搜索 title+model → Task 2（rowMatches）+ Task 8（解除守卫、历史下编辑 query）+ Task 7（搜索框显示 query）。
- 来源 Tab 筛选 → Task 4（状态+cycle+桥接）+ Task 8（Tab 键）+ Task 7（chip）。
- 导航跳过 header → Task 3（filtered 序号）+ Task 6（move/delete/activate 用 filtered）+ Task 7（窗口化 + selected 映射）。
- i18n → Task 5。
- 单测 → Task 1/2/3/4/5。
- macos-e2e 输入驱动 + 重开/响应性断言 → Task 9。
- 验证 → Task 10。

**Type 一致性：** `command_palette_history_view.{Bucket,SourceFilter,DisplayItem,localEpochDay,bucketFor,rowMatches,View,build}` 在 Task 1-3 定义、Task 4/6/7 引用一致；`State.command_palette_history_source` + `commandPaletteCycleHistorySource` 在 Task 4 定义、Task 6/7/8 用；overlays `g_command_palette_history_source`/`g_command_palette_history_item_count`/`buildHistoryView`/`historyBucketLabel`/`historySourceLabel`/`historyWindowStart`/`historySelectedItemIndex` 在 Task 4/6/7 定义并互用一致。

**已知执行注意：**
- Task 6 的 `zig build test` 是否编译 overlays 取决于 fast 套件依赖图；若不编译则以 `test-full` 为准（步骤已注明）。
- Task 9 的合成 `delete` 键在历史模式映射为 Backspace 编辑 query——若该键触发"删除会话"，按 Step 2 注释去掉该行（硬断言只在最后的终端 round-trip，不受影响）。
- 其余（i18n `setLang`、`key_tab`/`key_backspace` 常量、`commandPaletteResultCount` 现状）均已实证固化。
