# Merge Copilot Conversation Pickers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the two Command Center Copilot-conversation entries into one renamed "Copilot History" picker that tags sidebar-origin rows and restores each conversation to where it came from.

**Architecture:** Surface the existing per-record `copilot` (= "lived in the sidebar") flag onto the lightweight `agent_history.Row`. The command-palette history picker then renders a localized `Sidebar` tag in place of the model name for those rows, and its activation branches on the flag: sidebar rows load into the active tab's Copilot sidebar (`loadCopilotConversationById`), all others reopen as a full AI-chat tab (`reopenAiChatTabFromHistorySessionId`, unchanged). The duplicate "Load Copilot Conversation" command and its `CommandAction` are removed; the sidebar's Ctrl+Shift+R / `/resume` keep the separate `copilot_picker` overlay.

**Tech Stack:** Zig 0.15.2, in-repo `agent_history` / `command_center_state` / `renderer/overlays` / `i18n` modules, GPU titlebar text renderer.

## Global Constraints

- Zig version: 0.15.2. No new dependencies.
- Tests run via `zig build test` (fast native logic suite — includes `agent_history.zig` and `command_center_state.zig`) and `zig build test-full` (full suite — includes `test_main.zig` source guards). There is no `--test-filter` passthrough; run the whole suite and read the per-test pass/fail lines.
- `CommandAction` is switched over exhaustively in `command_center_state.zig`, `i18n.zig` (twice), and `renderer/overlays.zig`. Removing an enum value requires deleting every matching `case` in the same change or the build breaks.
- Adding a field to the `i18n.Strings` struct requires adding it to BOTH the `en` (line ~230) and `zh_CN` (line ~439) struct literals, or i18n won't compile.
- The `Row.copilot` field default (`= false`) means struct-literal constructors must explicitly set `.copilot` to propagate a true value.
- Follow existing patterns: behavioral unit tests for pure data plumbing; `@embedFile` + `std.mem.indexOf` source guards in `test_main.zig` for UI-glue wiring that can't be unit-tested.

---

### Task 1: Surface the sidebar flag on `agent_history.Row`

**Files:**
- Modify: `src/agent_history.zig` (`Row` struct ~44-49; `buildRows` ~107-118; `buildCopilotRows` ~128-141; `cloneRow` ~373-388)
- Test: `src/agent_history.zig` (inline test, add after the `buildCopilotRows` test ~line 700)

**Interfaces:**
- Consumes: nothing new.
- Produces: `agent_history.Row` gains `copilot: bool` (default `false`), populated from `SessionRecord.copilot` by both `buildRows` and `buildCopilotRows`. Downstream (Task 3) reads `row.copilot`.

- [ ] **Step 1: Write the failing test**

Add this test immediately after the existing `test "agent_history: buildCopilotRows lists only copilot records, newest first"` block (~line 700):

```zig
test "agent_history: buildRows carries the copilot sidebar flag per record" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    const base = SessionRecord{
        .session_id = "", .title = "", .base_url = "u", .api_key = "k", .model = "m",
        .system_prompt = "s", .thinking_enabled = false, .reasoning_effort = "low",
        .stream = true, .agent_enabled = true, .created_at = 0, .updated_at = 0,
        .messages = &[_]MessageRecord{},
    };
    var sidebar = base; sidebar.session_id = "s"; sidebar.updated_at = 20; sidebar.copilot = true;
    var tabrec = base; tabrec.session_id = "t"; tabrec.updated_at = 10; tabrec.copilot = false;
    try store.upsertRecord(sidebar);
    try store.upsertRecord(tabrec);

    const rows = try store.buildRows(allocator);
    defer freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("s", rows[0].session_id); // newest (20) first
    try std.testing.expect(rows[0].copilot);
    try std.testing.expectEqualStrings("t", rows[1].session_id);
    try std.testing.expect(!rows[1].copilot);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -30`
Expected: compile error — `no field named 'copilot' in struct '...Row'` (the test references `rows[0].copilot`).

- [ ] **Step 3: Add the field to `Row`**

Replace the `Row` struct (~line 44):

```zig
pub const Row = struct {
    session_id: []const u8,
    title: []const u8,
    model: []const u8,
    updated_at: i64,
};
```

with:

```zig
pub const Row = struct {
    session_id: []const u8,
    title: []const u8,
    model: []const u8,
    updated_at: i64,
    copilot: bool = false,
};
```

- [ ] **Step 4: Propagate the flag in `cloneRow`**

In `cloneRow` (~line 373), replace the return literal:

```zig
    return .{
        .session_id = session_id,
        .title = title,
        .model = model,
        .updated_at = input.updated_at,
    };
```

with:

```zig
    return .{
        .session_id = session_id,
        .title = title,
        .model = model,
        .updated_at = input.updated_at,
        .copilot = if (@hasField(@TypeOf(input), "copilot")) input.copilot else false,
    };
```

- [ ] **Step 5: Pass the flag from both row builders**

In `buildRows` (~line 108), replace the `cloneRow` call literal:

```zig
            rows[i] = try cloneRow(allocator, .{
                .session_id = record.session_id,
                .title = record.title,
                .model = record.model,
                .updated_at = record.updated_at,
            });
```

with:

```zig
            rows[i] = try cloneRow(allocator, .{
                .session_id = record.session_id,
                .title = record.title,
                .model = record.model,
                .updated_at = record.updated_at,
                .copilot = record.copilot,
            });
```

In `buildCopilotRows` (~line 130), replace:

```zig
            const row = try cloneRow(allocator, .{
                .session_id = record.session_id,
                .title = record.title,
                .model = record.model,
                .updated_at = record.updated_at,
            });
```

with:

```zig
            const row = try cloneRow(allocator, .{
                .session_id = record.session_id,
                .title = record.title,
                .model = record.model,
                .updated_at = record.updated_at,
                .copilot = record.copilot,
            });
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -30`
Expected: all pass, including `agent_history: buildRows carries the copilot sidebar flag per record`.

- [ ] **Step 7: Commit**

```bash
git add src/agent_history.zig
git commit -m "feat(agent-history): carry copilot sidebar flag on Row

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QN9vs3xFKUgcsfRgpZTjfT"
```

---

### Task 2: Remove the duplicate entry and rename to "Copilot History"

**Files:**
- Modify: `src/command_center_state.zig` (`CommandAction` enum ~12; `command_entries` ~64-65; inline tests ~303-311)
- Modify: `src/i18n.zig` (`commandTitle` switch ~759-760; `commandDetail` switch ~812-813)
- Modify: `src/renderer/overlays.zig` (`executeCommand` switch ~556)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: a single Copilot history command titled `"Copilot History"` (action `select_agent_history`); `CommandAction.load_copilot_conversation` no longer exists.

- [ ] **Step 1: Update the catalog tests (failing)**

In `src/command_center_state.zig`, replace these two tests (~line 303):

```zig
test "command center includes Select Copilot History action" {
    try std.testing.expectEqual(CommandAction.select_agent_history, findCommandAction("Select Copilot History"));
}

test "command catalog includes Load Copilot Conversation" {
    try std.testing.expectEqual(
        CommandAction.load_copilot_conversation,
        findCommandAction("Load Copilot Conversation"),
    );
}
```

with:

```zig
test "command center includes Copilot History action" {
    try std.testing.expectEqual(CommandAction.select_agent_history, findCommandAction("Copilot History"));
}

test "command catalog no longer has a Load Copilot Conversation entry" {
    try std.testing.expectEqual(@as(?CommandAction, null), findCommandAction("Load Copilot Conversation"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -30`
Expected: `command center includes Copilot History action` fails (returns `null`, not `select_agent_history`) — the catalog still has the old `"Select Copilot History"` title and the `load_copilot_conversation` entry.

- [ ] **Step 3: Remove the enum value**

In `src/command_center_state.zig`, delete the `load_copilot_conversation,` line from the `CommandAction` enum (~line 12):

```zig
    select_agent_history,
    load_copilot_conversation,
    split_right,
```

becomes:

```zig
    select_agent_history,
    split_right,
```

- [ ] **Step 4: Rename the survivor and drop the duplicate catalog row**

In `command_entries` (~line 64), replace:

```zig
    .{ .title = "Select Copilot History", .detail = "Open the command-center Copilot history picker", .shortcut = "", .action = .select_agent_history },
    .{ .title = "Load Copilot Conversation", .detail = "Reopen a saved Copilot sidebar conversation", .shortcut = "", .action = .load_copilot_conversation },
```

with:

```zig
    .{ .title = "Copilot History", .detail = "Open the command-center Copilot history picker", .shortcut = "", .action = .select_agent_history },
```

- [ ] **Step 5: Fix the `i18n` switches**

In `src/i18n.zig` `commandTitle` (~line 759), replace:

```zig
        .select_agent_history => "选择副驾历史",
        .load_copilot_conversation => "载入副驾对话",
```

with:

```zig
        .select_agent_history => "副驾历史",
```

In `commandDetail` (~line 812), delete the `load_copilot_conversation` case:

```zig
        .select_agent_history => "打开命令中心的副驾历史选择器",
        .load_copilot_conversation => "重新打开已保存的副驾侧栏对话",
```

becomes:

```zig
        .select_agent_history => "打开命令中心的副驾历史选择器",
```

- [ ] **Step 6: Remove the overlays dispatch case**

In `src/renderer/overlays.zig` `executeCommand` (~line 556), delete the `load_copilot_conversation` arm:

```zig
        .select_agent_history => commandPaletteOpenAgentHistory(),
        .load_copilot_conversation => AppWindow.openCopilotConversationPicker(),
        .split_right => AppWindow.splitFocused(.right),
```

becomes:

```zig
        .select_agent_history => commandPaletteOpenAgentHistory(),
        .split_right => AppWindow.splitFocused(.right),
```

(Leave `AppWindow.openCopilotConversationPicker` itself in place — Ctrl+Shift+R and `/resume` still call it.)

- [ ] **Step 7: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -30`
Expected: all pass, including `command center includes Copilot History action` and `command catalog no longer has a Load Copilot Conversation entry`.

- [ ] **Step 8: Commit**

```bash
git add src/command_center_state.zig src/i18n.zig src/renderer/overlays.zig
git commit -m "feat(command-center): single Copilot History entry

Remove the duplicate Load Copilot Conversation command and rename
Select Copilot History to Copilot History. Ctrl+Shift+R and /resume
keep the separate copilot_picker overlay.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QN9vs3xFKUgcsfRgpZTjfT"
```

---

### Task 3: Render the "Sidebar" tag and restore by origin

**Files:**
- Modify: `src/i18n.zig` (`Strings` struct ~193; `en` table ~405; `zh_CN` table ~614)
- Modify: `src/renderer/overlays.zig` (history-row render ~1780-1786; `commandPaletteActivateAgentHistoryIndex` ~1242-1268)
- Test: `src/test_main.zig` (add a source-guard test ~after line 866)

**Interfaces:**
- Consumes: `agent_history.Row.copilot` (Task 1); single `Copilot History` entry (Task 2); `i18n.s().cmd_palette_sidebar_tag` (added here); existing `AppWindow.loadCopilotConversationById(session_id: []const u8) void` and `AppWindow.reopenAiChatTabFromHistorySessionId(session_id: []const u8) bool`.
- Produces: final user-visible behavior. No new exports.

- [ ] **Step 1: Write the failing source-guard test**

In `src/test_main.zig`, add after the `test "copilot picker is rendered and key-routed"` block (~line 866):

```zig
test "merged copilot history picker tags sidebar rows and restores by origin" {
    const overlays_src = @embedFile("renderer/overlays.zig");
    // Right column shows the Sidebar tag for sidebar-origin rows.
    try std.testing.expect(std.mem.indexOf(u8, overlays_src, "cmd_palette_sidebar_tag") != null);
    // Activation branches on the row's copilot flag and loads into the sidebar.
    const act_idx = std.mem.indexOf(u8, overlays_src, "fn commandPaletteActivateAgentHistoryIndex(") orelse return error.Missing;
    const act = overlays_src[act_idx..];
    try std.testing.expect(std.mem.indexOf(u8, act, ".copilot)") != null);
    try std.testing.expect(std.mem.indexOf(u8, act, "loadCopilotConversationById(") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: `merged copilot history picker tags sidebar rows and restores by origin` fails — `cmd_palette_sidebar_tag` is absent and the activation function has no `.copilot)` branch yet.

- [ ] **Step 3: Add the `cmd_palette_sidebar_tag` string (struct + both tables)**

In `src/i18n.zig`, add the field to the `Strings` struct after `cmd_palette_footer_history` (~line 193):

```zig
    cmd_palette_footer_history: []const u8,
    cmd_palette_sidebar_tag: []const u8,
    copilot_picker_title: []const u8,
```

In the `en` table, after the `cmd_palette_footer_history` line (~line 405):

```zig
    .cmd_palette_footer_history = "Up/Down selects, Enter reopens, Delete removes, Esc returns",
    .cmd_palette_sidebar_tag = "Sidebar",
    .copilot_picker_title = "Copilot conversations (Up/Down, Enter, Delete, Esc)",
```

In the `zh_CN` table, after its `cmd_palette_footer_history` line (~line 614):

```zig
    .cmd_palette_footer_history = "上下选择，回车重开，Delete 删除，Esc 返回",
    .cmd_palette_sidebar_tag = "侧栏",
    .copilot_picker_title = "副驾对话（上下选择，回车打开，Delete 删除，Esc 关闭）",
```

- [ ] **Step 4: Render the tag in the history row loop**

In `src/renderer/overlays.zig`, replace the right-column block (~line 1780):

```zig
                if (row.model.len > 0) {
                    const meta_w = measureTitlebarText(row.model);
                    renderTitlebarText(row.model, meta_right - meta_w, text_y, meta_color);
                    renderTitlebarTextLimited(row.title, title_x, text_y, row_title_color, (meta_right - meta_w) - title_x - 18);
                } else {
                    renderTitlebarTextLimited(row.title, title_x, text_y, row_title_color, meta_right - title_x);
                }
```

with:

```zig
                // Sidebar-origin conversations show a "Sidebar" tag where tab
                // conversations show their model name.
                const right_label = if (row.copilot) i18n.s().cmd_palette_sidebar_tag else row.model;
                if (right_label.len > 0) {
                    const meta_w = measureTitlebarText(right_label);
                    renderTitlebarText(right_label, meta_right - meta_w, text_y, meta_color);
                    renderTitlebarTextLimited(row.title, title_x, text_y, row_title_color, (meta_right - meta_w) - title_x - 18);
                } else {
                    renderTitlebarTextLimited(row.title, title_x, text_y, row_title_color, meta_right - title_x);
                }
```

- [ ] **Step 5: Branch activation on the sidebar flag**

In `src/renderer/overlays.zig`, replace `commandPaletteActivateAgentHistoryIndex` (~line 1242):

```zig
fn commandPaletteActivateAgentHistoryIndex(row_idx: usize) bool {
    if (!commandPaletteIsHistoryMode()) return false;
    if (row_idx >= g_command_palette_history_rows.len) return false;
    if (AppWindow.reopenAiChatTabFromHistorySessionId(g_command_palette_history_rows[row_idx].session_id)) {
        commandPaletteClose();
        return true;
    }

    const allocator = AppWindow.g_allocator orelse return false;
    const session_id = allocator.dupe(u8, g_command_palette_history_rows[row_idx].session_id) catch return false;
    defer allocator.free(session_id);

    commandPaletteRefreshAgentHistoryRows();

    var state = commandCenterStateSnapshot();
    const refreshed_idx = findAgentHistoryRowBySessionId(session_id) orelse {
        state.commandPaletteClampAgentHistorySelection(g_command_palette_history_rows.len);
        commandCenterStateCommit(state);
        return false;
    };
    _ = state.commandPaletteActivateHistoryRow(refreshed_idx, g_command_palette_history_rows.len) orelse return false;
    commandCenterStateCommit(state);

    if (!AppWindow.reopenAiChatTabFromHistorySessionId(g_command_palette_history_rows[refreshed_idx].session_id)) return false;
    commandPaletteClose();
    return true;
}
```

with:

```zig
fn commandPaletteActivateAgentHistoryIndex(row_idx: usize) bool {
    if (!commandPaletteIsHistoryMode()) return false;
    if (row_idx >= g_command_palette_history_rows.len) return false;

    // Sidebar-origin conversations restore into the active tab's Copilot
    // sidebar; tab conversations reopen as a full AI-chat tab. The sidebar
    // branch runs before the palette closes, so the row pointer stays valid.
    if (g_command_palette_history_rows[row_idx].copilot) {
        AppWindow.loadCopilotConversationById(g_command_palette_history_rows[row_idx].session_id);
        commandPaletteClose();
        return true;
    }

    if (AppWindow.reopenAiChatTabFromHistorySessionId(g_command_palette_history_rows[row_idx].session_id)) {
        commandPaletteClose();
        return true;
    }

    const allocator = AppWindow.g_allocator orelse return false;
    const session_id = allocator.dupe(u8, g_command_palette_history_rows[row_idx].session_id) catch return false;
    defer allocator.free(session_id);

    commandPaletteRefreshAgentHistoryRows();

    var state = commandCenterStateSnapshot();
    const refreshed_idx = findAgentHistoryRowBySessionId(session_id) orelse {
        state.commandPaletteClampAgentHistorySelection(g_command_palette_history_rows.len);
        commandCenterStateCommit(state);
        return false;
    };
    _ = state.commandPaletteActivateHistoryRow(refreshed_idx, g_command_palette_history_rows.len) orelse return false;
    commandCenterStateCommit(state);

    if (!AppWindow.reopenAiChatTabFromHistorySessionId(g_command_palette_history_rows[refreshed_idx].session_id)) return false;
    commandPaletteClose();
    return true;
}
```

- [ ] **Step 6: Run the full suite to verify it passes**

Run: `zig build test-full 2>&1 | tail -30`
Expected: all pass, including `merged copilot history picker tags sidebar rows and restores by origin`.

- [ ] **Step 7: Verify the fast suite and a release-mode build still compile**

Run: `zig build test 2>&1 | tail -5 && zig build 2>&1 | tail -5`
Expected: both succeed with no errors.

- [ ] **Step 8: Commit**

```bash
git add src/i18n.zig src/renderer/overlays.zig src/test_main.zig
git commit -m "feat(command-center): tag Copilot sidebar rows and restore by origin

Copilot History rows that originated in the sidebar show a Sidebar tag and
reopen into the active tab's sidebar; tab conversations keep their model
label and reopen as a tab.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QN9vs3xFKUgcsfRgpZTjfT"
```

---

## Manual GUI verification (post-implementation)

Native logic + source guards are covered by the suites above; the rendering and
tab/sidebar restore are GUI-only. After implementation, verify in a running app:

1. Open Command Center → exactly one Copilot entry, titled **Copilot History**; **Load Copilot Conversation** is gone.
2. Open Copilot History → sidebar conversations show a **Sidebar** tag on the right; tab conversations show their model name.
3. Enter on a **Sidebar** row from a terminal tab → conversation loads into that tab's Copilot sidebar.
4. Enter on a non-Sidebar row → conversation reopens as a full AI-chat tab.
5. In a Copilot sidebar, **Ctrl+Shift+R** and **`/resume`** still open the old sidebar-only picker (unchanged).

## Self-Review notes

- **Spec coverage:** Row flag (Task 1) ✓; remove duplicate + rename incl. zh title (Task 2) ✓; Sidebar tag render + open-by-origin + `cmd_palette_sidebar_tag` (Task 3) ✓; Ctrl+Shift+R / `/resume` untouched (Task 2 Step 6 note) ✓; no-op-when-not-terminal limitation inherited from `loadCopilotConversationById` (unchanged) ✓.
- **Type consistency:** `loadCopilotConversationById([]const u8) void` and `reopenAiChatTabFromHistorySessionId([]const u8) bool` match their callsites; `findCommandAction` returns `?CommandAction` (null-assert valid); `Row.copilot: bool` name is identical across Tasks 1 and 3.
- **Placeholders:** none — every code step shows full code and exact commands.
