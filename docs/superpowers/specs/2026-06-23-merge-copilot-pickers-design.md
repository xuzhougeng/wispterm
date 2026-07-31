# Merge the two Copilot conversation pickers in the Command Center

**Date:** 2026-06-23
**Branch:** `feat/pane-aware-agent-integration`
**Status:** Design approved, pending implementation plan

## Problem

The Command Center exposes two near-duplicate entries for Copilot conversations:

- **"Select Copilot History"** (`CommandAction.select_agent_history`) opens the
  command-palette history picker (`command_palette_mode == .agent_history`). It
  lists **all** saved built-in Copilot conversations via `Store.buildRows`, shows
  the model name in the right column, and on Enter/click reopens the selected
  session **as a full AI-chat tab** (`reopenAiChatTabFromHistorySessionId`).
- **"Load Copilot Conversation"** (`CommandAction.load_copilot_conversation`)
  opens the separate `copilot_picker` overlay. It lists **only sidebar**
  conversations via `Store.buildCopilotRows` (the `copilot == true` records),
  shows relative time in the right column, and on Enter/click loads the selected
  session **into the active tab's Copilot sidebar** (`loadCopilotConversationById`).
  This overlay is also reachable via the **Ctrl+Shift+R** keybind
  (`copilot_conversation_picker`) and the in-sidebar **`/resume`** command.

The two lists draw from the same `agent_history` store and overlap heavily. Users
see two confusingly-similar Command Center commands that differ only in filter and
open-target.

## Goal

The Command Center keeps a **single** Copilot-conversations entry — the existing
history picker, with its label shortened from "Select Copilot History" to
**"Copilot History"**. It lists all saved built-in Copilot
conversations. Rows that originated in the **sidebar** are marked with a
`Sidebar` tag in the right column (replacing the model name for those rows only);
tab conversations keep showing their model name. Selecting a row restores it to
where it came from:

- A **`Sidebar`** row → loads into the **current tab's Copilot sidebar**
  (`loadCopilotConversationById`).
- Any **other** row → reopens as a **new AI-chat tab**
  (`reopenAiChatTabFromHistorySessionId`, the current behavior).

The standalone **"Load Copilot Conversation"** Command Center entry is removed.
The sidebar's own **Ctrl+Shift+R** and **`/resume`** triggers keep using the
existing `copilot_picker` overlay, unchanged — only the Command Center merges.

## Key insight

The `copilot: bool` field already on each `agent_history.SessionRecord` is exactly
the "this conversation lived in the sidebar" marker (set true for sidebar Copilot
sessions, false for AI-chat tabs). No data-model change is needed beyond surfacing
that flag on the lightweight `Row` the picker renders from.

## Design

### 1. `src/agent_history.zig` — surface the sidebar flag on `Row`

- Add `copilot: bool = false` to the `Row` struct.
- Populate it in both `buildRows` and `buildCopilotRows` by passing
  `.copilot = record.copilot` into the `cloneRow` literal.
- `cloneRow` reads it via the existing `anytype` pattern (guard with
  `@hasField(@TypeOf(input), "copilot")`, default `false`, matching `cloneRecord`).
- `freeOwnedRow` / `freeRows` need **no** change — a `bool` owns no allocation.
- `sortRows` is unaffected.

Other consumers of `Row` are unaffected by the added field:
`file_explorer.syncAgentHistoryRows` only reads `row.model`; `copilot_picker.Row`
is a separate struct.

### 2. `src/command_center_state.zig` — drop the duplicate entry

- Remove the `.{ ... .action = .load_copilot_conversation }` catalog row.
- Remove the `load_copilot_conversation` value from the `CommandAction` enum.
- Keep `select_agent_history` as the single entry, but shorten its catalog
  `.title` from `"Select Copilot History"` to `"Copilot History"`. The action
  enum name stays `select_agent_history` (internal identifier unchanged).

### 3. `src/renderer/overlays.zig` — render the tag and branch on select

- **Dispatch:** remove the `.load_copilot_conversation => AppWindow.openCopilotConversationPicker()`
  case in `executePaletteItem` (the enum value no longer exists).
- **Row render** (history-mode loop, currently `if (row.model.len > 0)`): when
  `row.copilot` is true, render the localized `Sidebar` tag in the right column
  instead of `row.model`; otherwise keep the existing model-name rendering. The
  title's available width is measured against whichever label is drawn.
- **Activation** (`commandPaletteActivateAgentHistoryIndex`): branch on the
  selected row's `copilot` flag:
  - `copilot == true` → `AppWindow.loadCopilotConversationById(session_id)`, then
    `commandPaletteClose()` and return true.
  - `copilot == false` → existing `reopenAiChatTabFromHistorySessionId` path
    (including its refresh-and-retry fallback), unchanged.

  The sidebar branch runs before the palette closes/refreshes, so it can pass
  `g_command_palette_history_rows[row_idx].session_id` directly — same as the tab
  path's first reopen attempt. No dupe is required (the tab path only dupes in its
  post-refresh fallback).

### 4. `src/i18n.zig` — strings

- Add a `cmd_palette_sidebar_tag` field to the `Strings` struct: English
  `"Sidebar"`, zh-CN `"侧栏"`.
- Remove the `load_copilot_conversation` cases from `commandTitle` and
  `commandDetail` (the enum value is gone).
- Shorten the `select_agent_history` zh-CN `commandTitle` override from
  `"选择副驾历史"` to `"副驾历史"` to match the trimmed English label.

### 5. Tests (TDD)

- **`agent_history`**: a test asserting `buildRows` propagates `Row.copilot` from
  the record (true for a sidebar record, false for a tab record), and that
  `buildCopilotRows` rows all carry `copilot == true`.
- **`command_center_state`**: delete the now-invalid
  "command catalog includes Load Copilot Conversation" test; update the
  "Select Copilot History" test to look up `findCommandAction("Copilot History")`.
  Optionally assert the catalog no longer contains a `load_copilot_conversation`
  action.
- **Activation branch**: the activation calls into `AppWindow` globals, which are
  hard to unit-test directly. Where feasible, extract the
  "sidebar row → sidebar load, else → tab" decision into a pure helper (input:
  `copilot: bool`; output: an enum `{ sidebar, tab }`) and unit-test that, keeping
  the overlay function a thin dispatcher. If extraction adds more indirection than
  value, cover the rendering/flag plumbing instead and verify the branch via the
  existing `test_main.zig` source-substring guards.

## Behavior preserved / known limitations

- **`loadCopilotConversationById` no-op case:** if a `Sidebar` row is selected
  while the active tab is not a terminal and no live copy of that conversation is
  already open, the sidebar load is a no-op — identical to today's `copilot_picker`
  behavior. The palette still closes. Not a regression; documented, not fixed here.
- **Ctrl+Shift+R / `/resume`:** unchanged. They still open the sidebar-only
  `copilot_picker` overlay. `AppWindow.openCopilotConversationPicker` and
  `refreshCopilotPickerRows` remain in place for those triggers.
- **Delete (Del key) in the merged picker:** unchanged — still deletes the
  selected history record via the existing agent-history delete path, regardless
  of whether the row is a sidebar or tab conversation.

## Out of scope

- Retiring the `copilot_picker` overlay or its Ctrl+Shift+R / `/resume` triggers.
- Changing what conversations get persisted or how the `copilot` flag is set.
- Any change to the external CLI "Sessions" browser (a separate store/panel).
