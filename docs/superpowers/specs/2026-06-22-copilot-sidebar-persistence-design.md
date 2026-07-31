# Copilot Sidebar Persistence Design

## Goal

Today the Copilot sidebar conversation (the per-terminal-tab AI chat shown on the
right of a `.terminal` tab) is **memory-only**: `TabState.deinit` frees
`copilot_session`, the session factory never installs the history hook, and the
quit-time snapshot (`persistOpenAiChatTabsToHistoryStore`) only iterates
`kind == .ai_chat` tabs. So closing the tab — or quitting WispTerm — discards the
conversation, and there is no way to get it back.

This change makes Copilot sidebar conversations **persistent and retrievable**:

1. They survive app restart and reload **in place** into the terminal tab's sidebar.
2. After a terminal (SSH/WSL/zsh) tab is closed, the conversation is **not** lost —
   it can be reloaded into any sidebar from a Copilot conversation picker.
3. The picker is reachable from the sidebar, the command center, and (in the
   sidebar only) the `/resume` slash command.

## Non-goals / context

- The built-in agent-history store (`agent-history.json`, `g_agent_history`) is
  **separate** from the Sessions panel. The Sessions panel scans external CLI
  dirs only (`.claude` / `.codex` / `.reasonix`, see `ai_history_source.zig`
  `ProviderFlags`), and nothing in-repo writes reasonix transcripts. Therefore
  Copilot conversations stored in `agent-history.json` do **not** appear in
  Sessions, and "keep them out of Sessions" needs **no** filtering work — it is
  inherent. This is a deliberate decision, not an oversight.
- No automatic retention cap on stored conversations in v1 (manual delete only).
- "Conversation history" here = past Copilot conversations (the picker). It is
  unrelated to *composer* history (Up/Down prompt recall, separate feature). Names
  in this design avoid the bare word "history" for the picker to prevent confusion.

## Data model

Each Copilot conversation is one record in the existing `g_agent_history` store
(`agent-history.json`), keyed by `session_id`. Reuse the AI Chat tab's store +
incremental flush + quit-snapshot infrastructure unchanged. Closing a terminal
tab does **not** delete the record; it persists and stays retrievable.

A terminal tab's sidebar shows one *active* conversation at a time
(`TabState.copilot_session`); its id is recorded in the tab snapshot for
restore-in-place. "Restore in place" is the special case of the general
load-by-id mechanism.

### Store record marker

Add `copilot: bool = false` to `agent_history.SessionRecord`:

- JSON round-trips; old records default to `false`.
- Written `true` for Copilot sessions.
- Purpose (1): the conversation picker lists only `copilot == true` records, so
  AI Chat *tab* conversations never leak into the Copilot picker (both share the
  one store).
- Purpose (2): on rehydrate, `initFromHistoryRecord` sets `session.copilot =
  record.copilot`, so a restored Copilot session keeps its copilot rendering /
  behavior (today `copilot` is set only by the factory after init and is lost on
  round-trip).

### Tab snapshot fields

Add to `session_persist.zig` `TabSnap`:

- `copilot_session_id: ?[]const u8 = null` — the active sidebar conversation's id
  for restore-in-place. Mirrors the existing `ai_session_id` pattern (conversation
  lives in the store, snapshot only points at it). Null in old snapshots.
- `copilot_visible: bool = false` — restore the sidebar open/closed state as left.
  False in old snapshots → sidebar starts collapsed (conversation still loaded,
  expand to see it). If "always start collapsed on restart" is later preferred,
  drop this field.

## Write paths (three wiring points)

1. **Incremental save**: install the history-change hook on Copilot sessions.
   Today `installAiChatHistoryHook` (`appwindow/tab.zig`) is called only on
   `.ai_chat` tab creation. Call it on the Copilot session too — naturally at the
   point `activeCopilotSession` assigns `t.copilot_session = make()`. Each turn
   then upserts into the store via the existing `saveAiHistoryChangeEvent`, the
   same path AI Chat tabs use.

2. **Quit snapshot**: extend `persistOpenAiChatTabsToHistoryStore`
   (`AppWindow.zig`) so that, in addition to `.ai_chat` tabs, it iterates
   `.terminal` tabs and upserts each non-empty `copilot_session` into the store.

3. **Snapshot id**: when `tab.dumpSessionToFile` serializes a `.terminal` tab,
   set `copilot_session_id` (and `copilot_visible`) when the tab has a Copilot
   session worth persisting (see `shouldPersistCopilot`).

## Restore in place

When the session-restore path rebuilds a `.terminal` tab and
`TabSnap.copilot_session_id` is non-null:

1. Look the id up in `g_agent_history`.
2. If found, `Session.initFromHistoryRecord` rehydrates it (which now sets
   `copilot = true` via the record marker), install the history hook, and assign
   it to `tab.copilot_session`.
3. Apply `copilot_visible`.
4. If the id is **not** found (record deleted / store corrupt), silently fall back
   to an empty sidebar — never block tab restore, never crash.

This load step is shared with the picker (below): both reduce to "load
conversation by id into a tab's sidebar".

## Copilot conversation picker

A keyboard-driven picker overlay listing past Copilot conversations, mirroring the
existing `jupyter_picker` / session launcher patterns.

- **Rows**: `copilot == true` records from the store, **title + relative time**,
  newest first. (Titles already auto-generate via `auto_title_attempted`.) A
  per-record host/tab context label is a possible future addition; v1 is
  title + time.
- **Actions**: load selected, `+ New conversation`, delete (manual cleanup; no
  auto cap in v1).
- **Load semantics**: the sidebar's current conversation is already saved by the
  hook, so loading just swaps the active session in. Empty (never-chatted)
  conversations are not in the list.
- **De-dup (correctness)**: before loading id X, scan open tabs for a *live*
  Copilot session with id X. If one exists, switch to that tab instead of loading
  a second live copy — two live `Session` objects with the same id would both
  write the store and corrupt it. Mirrors `switchToAiTabBySessionId`.

### Entry points

- Sidebar **"Past conversations"** button + keyboard shortcut.
- Command center command (e.g. "Load Copilot conversation…").
- `/resume` typed in the sidebar (see below).

## `/resume` semantics (context-dependent)

`/resume` currently maps `.resume_session` → deferred `.resume_picker` →
`g_session_resume_trigger` → `overlays.commandPaletteOpenAgentHistory()`, i.e. it
opens the **external CLI** Agent History browser and resumes a CLI session in a
**new terminal** (`claude --resume` / `codex resume`, `ai_history_resume.zig`).
This is unrelated to the sidebar's own conversation, which is the source of
confusion.

New behavior — branch on `Session.copilot` when handling `.resume_session`:

- **Copilot sidebar** (`copilot == true`) → open the Copilot conversation picker
  (new deferred action, e.g. `.copilot_conversation_picker`).
- **Standalone AI Chat tab** (`copilot == false`) → unchanged (`.resume_picker` →
  external CLI Agent History browser → new terminal). Out of scope to change.

To make it explicit in the suggestion list, the `/resume` description should be
context-aware: in the sidebar it reads as "load a past Copilot conversation"; in
chat tabs it reads as "resume an external CLI session in a terminal". The
suggestion list (`slash_command_entries`) is currently static; threading the
copilot flag into the suggestion builder is the intended approach. If that proves
too invasive for v1, fall back to a single clarified combined description — to be
finalized in the implementation plan.

## Edge cases

- **Empty conversation**: a sidebar that was never chatted in is not persisted, not
  snapshotted (no id), and not listed in the picker. Gate via a pure
  `shouldPersistCopilot(session)` predicate (true iff ≥1 persistable message).
- **Closed terminal tab**: conversation is retained in the store and retrievable
  via the picker (the core requirement) — explicitly *not* dead weight.
- **Missing id on restore / load**: silent fallback to empty sidebar.
- **Same id live in two sidebars**: prevented by the picker de-dup.
- **Record accumulation**: records accrue intentionally; the picker's delete action
  is the manual cleanup path. Automatic capping is deferred (YAGNI; avoid
  accidental data loss).

## Testing

Favor pure-logic unit tests, consistent with the codebase:

- `session_persist`: `TabSnap` with `copilot_session_id` / `copilot_visible`
  JSON round-trip; old snapshot without these fields parses to null/false.
- `agent_history`: `SessionRecord.copilot` round-trips; old record without the
  field defaults to `false`; `initFromHistoryRecord` propagates `copilot`.
- `shouldPersistCopilot(session)`: true only with ≥1 persistable message.
- Picker row building: only `copilot == true` records are listed, sorted
  newest-first.
- `/resume` dispatch: `copilot == true` → conversation picker action;
  `copilot == false` → external-CLI resume action (pure branch test).
