# AI History selected-session actions - design

**Date:** 2026-07-07
**Status:** Approved, pending implementation

## Problem

The AI History workbench can scan Local, WSL, and SSH targets, filter external
Codex, Claude Code, and Reasonix sessions, preview the selected transcript with
Space, and resume the selected session with Enter. It does not yet let the user
take the selected history row out of the workbench for archiving, sharing, or
continuing a question in WispTerm's own Copilot.

## Goals

- Download the selected provider's original history file as a local raw file.
- Export the selected transcript as readable Markdown.
- Attach the selected transcript to WispTerm Copilot as context for follow-up
  questions.
- Keep the feature inside the existing AI History and Copilot feature modules.
- Preserve the event-driven UI rule: every action that mutates UI state marks
  the UI dirty through the existing boundary.

## Non-goals

- Do not convert external Codex, Claude Code, or Reasonix histories into
  WispTerm history records wholesale.
- Do not add a new full-screen modal or row action menu for the first version.
- Do not auto-submit a Copilot question after attaching context.
- Do not change terminal emulation, VT parsing, rendering, or Ghostty-derived
  terminal behavior.

## Ghostty comparison

Ghostty has no Copilot, external AI-history browser, Markdown transcript export,
or equivalent session-history action surface. The Ghostty-aligned decision here
is architectural rather than behavioral: keep this feature out of terminal core
and platform rendering paths. The work stays in WispTerm's feature domains:
`terminal_agents/sessions/*`, `renderer/terminal_agents/sessions.zig`, the
existing AppWindow integration layer, and `assistant/conversation/*` for the
Copilot context card.

## Current code facts

- AI History state and parsing live under `src/terminal_agents/sessions/`.
- `SessionMeta.source_path` points at the original provider file.
- Loaded transcripts use `types.TranscriptMessage`.
- Local transcript loading already reads `meta.source_path` through
  `loadLocalTranscript`.
- WSL and SSH transcript loading already use `RemoteExecHost` and
  `loadRemoteTranscript`, which `cat`s `meta.source_path` and parses it.
- SSH downloads already have a reusable SCP path:
  `file_explorer.downloadRemotePathToPath`.
- Copilot and AI Chat sessions already support collapsed context-summary cards
  (`Message.is_context_summary`) that are sent to the model as normal user
  context.
- Markdown export for WispTerm's own Copilot exists in
  `assistant/conversation/session.zig`, but external AI History needs a small
  formatter over `types.TranscriptMessage` instead of reusing WispTerm's own
  `Message` type.

## UX

The selected row gains three actions in the detail pane below the existing
session metadata and near the existing `Resume` action:

- `Download Raw`
- `Export Markdown`
- `Attach to Copilot`

Keyboard shortcuts fire only when AI History is active and the search box is not
focused:

- `D`: download raw provider file.
- `M`: export Markdown.
- `A`: attach transcript to Copilot.

Search-focused printable input keeps its current behavior. Existing shortcuts
remain unchanged: Enter resumes, Space previews, R rescans, arrows navigate.

## Download raw

`Download Raw` saves the selected provider's original history file. This is
different from Markdown export: it preserves provider-native JSONL/JSON content
for backup, migration, or debugging.

Behavior:

1. Clone the currently selected `SessionMeta` under the AI History session lock.
2. Build a safe default filename from provider label, session id, and the source
   path basename.
3. Open a save dialog rooted at the user's Downloads folder.
4. Save/copy the raw file:
   - Local target: read `meta.source_path` and write to the selected local path.
   - WSL target: read raw bytes with the existing WSL remote exec host using a
     quoted `cat <source_path>` command, then write to the selected local path.
     AI history files are provider text files, so this matches the existing WSL
     transcript-loading path.
   - SSH target: reuse `file_explorer.downloadRemotePathToPath` so Windows
     OpenSSH behavior and SCP stderr handling stay consistent with existing SSH
     downloads.
5. Show a toast on success, cancellation, or failure. Local and WSL copies copy
   the saved path to the clipboard on success, matching the existing Markdown
   export behavior. SSH uses the existing asynchronous transfer notification.

## Export Markdown

Markdown export loads the selected transcript if it is not already loaded, then
formats it as a standalone Markdown document.

Format:

```markdown
# AI History Export

- Provider: Codex
- Session: abc123
- Project: /path/to/project
- Source: /path/to/provider/file.jsonl

## User

...

## Assistant

...

## Tool

...
```

Rules:

- Include provider, session id, project directory, source path, and available
  timestamps in the header.
- Use the provider-neutral roles from `TranscriptMessage.role`.
- Preserve message order.
- Omit empty message bodies.
- Keep the formatter pure and unit-testable.
- Use the existing save-dialog and atomic-write pattern from WispTerm Copilot
  Markdown export.

## Attach to Copilot

Attaching a transcript creates model-visible context inside WispTerm Copilot but
does not submit a question.

Behavior:

1. Load the selected transcript if needed.
2. Convert it to a bounded Markdown context block using the same formatter as
   Markdown export.
3. Attach it to a Copilot-capable session:
   - If the active tab is an AI Chat tab, append the context there.
   - If the active tab is a terminal tab with a visible Copilot sidebar, append
     the context to that sidebar session.
   - Otherwise create a new Copilot chat tab from the default AI profile and
     append the context there.
4. Append the context as a collapsed `is_context_summary` user message titled
   with provider and session information.
5. Focus the chat composer and show a toast such as
   `Attached AI History context`.

The context block is bounded before insertion. If the transcript exceeds the
limit, keep the header plus the most recent messages and mark the card as
truncated. This keeps requests under the existing composer/request budgets while
preserving the useful tail of the conversation.

## Architecture

### `src/terminal_agents/sessions/markdown.zig`

Add a focused formatter for external history transcripts:

- `allocMarkdownExport(allocator, meta, messages, options) ![]u8`
- `allocCopilotContext(allocator, meta, messages, max_bytes) !ContextResult`

`ContextResult` returns the Markdown bytes plus a `truncated` flag. The module
depends only on `types.zig` and standard library formatting.

### `src/terminal_agents/sessions/session.zig`

Add small helpers that do not know about AppWindow:

- `selectedMetadataClone(allocator) ?types.SessionMeta`
- `replaceTranscriptFromMessages(provider, messages)` for AppWindow action
  helpers that synchronously load a transcript and want the preview pane to
  reflect the same loaded data.

Keep parsing and memory ownership in the existing provider-specific free paths.

### `src/renderer/terminal_agents/sessions.zig`

Extend the detail-pane hit model:

- Add hit variants for raw download, Markdown export, and Copilot attachment.
- Render the three actions as compact buttons near `Resume`.
- Keep hit-test geometry shared with render geometry so the existing layout
  pattern does not drift.

### `src/AppWindow.zig`

Add action entry points:

- `aiHistoryDownloadSelectedRaw() bool`
- `aiHistoryExportSelectedMarkdown() bool`
- `aiHistoryAttachSelectedToCopilot() bool`

These functions own UI integration: selected-row cloning, save dialogs, toasts,
Copilot tab/session creation, and `markUiDirty()`.

For SSH raw download, call the existing file explorer SCP helper. For Local and
WSL, write the selected destination through the existing atomic file writer.

### `src/assistant/conversation/session.zig`

Add one narrow API for this feature:

- `appendContextCard(title, body, collapsed) !void`

It appends a `.user` message with `is_context_summary = true`,
`content_collapsed = true`, and `persist_to_history = true`, then notifies the
history hook.

### `src/input.zig`

When AI History is active and search is not focused:

- `D` calls `AppWindow.aiHistoryDownloadSelectedRaw()`.
- `M` calls `AppWindow.aiHistoryExportSelectedMarkdown()`.
- `A` calls `AppWindow.aiHistoryAttachSelectedToCopilot()`.

Return through the existing input repaint/effect path.

### Docs

Update:

- `README.md` keyboard shortcut table.
- `docs/ai-agent.md` Sessions section.

## Error handling

- No selected row: show a short unavailable toast.
- Save dialog cancelled: show a cancellation toast and do nothing.
- Local read/write failure: show raw download or Markdown export failure.
- WSL remote read failure: show WSL read/download failure.
- SSH profile unavailable: show SSH profile unavailable.
- SSH SCP failure: rely on existing transfer status and stderr handling.
- Missing default AI profile/API configuration for Copilot attachment: open the
  existing AI config flow or show the existing missing-profile toast.
- Transcript parse failure: show transcript load/export failure and leave any
  existing preview state intact unless the user explicitly requested preview.

## Testing

Use TDD for implementation.

Pure unit tests:

- Markdown formatter includes metadata header and role sections.
- Markdown formatter omits empty message bodies.
- Copilot context formatter truncates oversized transcripts while keeping the
  metadata header and recent messages.
- Raw default filename sanitizes provider/session/path data.
- Context-card append stores a collapsed `is_context_summary` user message and
  persists it to history.

Session/UI model tests:

- Detail-pane hit-test returns the three new action variants.
- Keyboard action routing ignores `D`/`M`/`A` while the AI History search field
  is focused.
- Keyboard action routing fires the AppWindow action when search is not focused.

Integration checks:

- `zig build test`
- `zig build test-full` before finishing implementation.

Manual checks:

- Local AI History row: download raw, export Markdown, attach to Copilot.
- WSL AI History row on Windows: download raw and export Markdown.
- SSH AI History row with a configured profile: raw download uses SCP and keeps
  useful stderr on failure.
