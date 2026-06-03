# Drag-and-drop a local file onto the chat panel to insert its path

Date: 2026-06-03
Branch: `worktree-feat-enhancer-chat-panel`

## Goal

When the user drags a local file from the OS file manager and drops it anywhere
over a visible AI chat surface, insert that file's absolute path into the chat
session's composer. The path is quoted when it contains whitespace and is
followed by a trailing space, so successive drops and continued typing stay
separated. Existing terminal / SSH / file-explorer drop behavior is unchanged.

## Scope decisions (confirmed with user)

- **Insert format:** absolute path; if it contains whitespace, single-quote it
  (with `'\''` escaping for any embedded single quote); always append one
  trailing space.
- **Drop region:** the *entire* chat panel/page is a drop target — both the
  transcript area and the bottom composer. Any drop landing inside the panel
  bounds inserts into that panel's composer.

## Background: existing drop pipeline

The OS already delivers dropped file paths to a single Zig entry point:

- macOS: `performDragOperation:` in `src/platform/window_macos_bridge.m` reads
  file URLs from the pasteboard and pushes one event per file with coordinates
  `x = point.x * scale`, `y = (bounds.height - point.y) * scale` — i.e.
  **framebuffer/physical pixels**, top-left origin.
- Windows: the `WM_DROPFILES` handler in `src/apprt/win32.zig` iterates files
  via `DragQueryFileW` and reports `DragQueryPoint` client coords —
  **physical pixels**.
- No Linux GUI backend exists (consistent with the rest of the app); this
  feature is macOS + Windows only.

Both call the installed handler `input.handleFileDrop(path, x, y)` =
`clipboard.handleFileDrop` (`src/input/clipboard.zig:240`), which today routes:

```
handleFileDrop(path, x, y):
    if handleFileExplorerDrop(path, x) return true   // left-docked remote panel upload
    return handleSshTerminalFileDrop(path)           // scp upload to active SSH cwd
```

Inserting text into a chat composer is already a solved one-liner: clipboard
paste uses `pasteFromClipboardIntoAiChat` →
`session.appendInputText(text)` (`src/ai_chat.zig:875`), which inserts at the
cursor, clears any select-all, and clamps to the composer's fixed buffer.

## Design

Add one branch to `handleFileDrop`, ordered between the file-explorer and SSH
handlers (no overlap with the left-docked explorer; must precede the SSH
terminal handler so a drop on a copilot panel sitting over an SSH terminal goes
to the chat, not scp):

```
handleFileDrop(path, x, y):
    if handleFileExplorerDrop(path, x) return true
    if handleAiChatFileDrop(path, x, y) return true   // NEW
    return handleSshTerminalFileDrop(path)
```

Three small, independently-testable units:

### 1. `AppWindow.aiChatSessionAtPoint(x: i32, y: i32) ?*ai_chat.Session`

Geometry + session lookup, placed alongside the other panel geometry in
`AppWindow.zig`. Reuses the exact rects the IME-caret code already computes
(`AppWindow.zig:4109`), so it stays consistent with how the panels are drawn:

- **AI chat tab:** if `activeAiChat()` returns a session, the content rect is
  `left = leftPanelsWidth()`,
  `w = clientSize.width - left - rightPanelsWidthForWindow(width)`,
  spanning from the titlebar to the window bottom. If `(x, y)` is inside →
  return that session.
- **Copilot sidebar:** else if `aiCopilotVisible()` and `(x, y)` is inside
  `ai_sidebar.boundsForWindow(clientSize.width, clientSize.height,
  currentTitlebarHeight(), leftPanelsWidth(), 0)` → return
  `activeCopilotSessionForInput()`.
- Otherwise `null`.

All inputs (`clientSize`, `leftPanelsWidth`, `rightPanelsWidthForWindow`,
`boundsForWindow`) are in framebuffer pixels, matching the drop coordinates.

### 2. `formatDroppedPath(allocator, raw: []const u8) ![]u8`

Pure function (the TDD core). Rules:

- No whitespace in `raw` → return `raw <space>` (raw copied, one trailing
  space appended).
- Contains whitespace → return `'<raw>' <space>`, where any single quote in
  `raw` is escaped using the POSIX `'\''` idiom (close quote, escaped quote,
  reopen quote).
- A trailing space is always appended.

Caller owns and frees the returned slice.

### 3. `handleAiChatFileDrop(path, x, y) bool` (in `clipboard.zig`)

Glue only:

```
session = AppWindow.aiChatSessionAtPoint(x, y) orelse return false
text    = formatDroppedPath(alloc, path) catch return false
defer alloc.free(text)
session.appendInputText(text)
if target was the copilot sidebar: input.focusAiCopilot()   // ready to edit/Enter
return true
```

For an AI chat *tab*, the session is already the focused surface, so no extra
focus call is needed; only the copilot sidebar needs `focusAiCopilot()`.

## Data flow

OS drop → `handleFileDrop` → `handleAiChatFileDrop` → `aiChatSessionAtPoint`
→ `formatDroppedPath` → `appendInputText`.

**Multiple files** require no special handling: the pipeline fires one event per
dropped file, so each appends `<path> `, producing a space-separated list in the
composer.

## Error handling

- Off-panel drops → `aiChatSessionAtPoint` returns `null` →
  `handleAiChatFileDrop` returns `false` → the existing SSH/terminal path runs
  unchanged.
- Allocation failure in `formatDroppedPath` → return `false` (treated as
  not-handled) so nothing is silently inserted into the wrong place.
- `appendInputText` already clamps to the composer's fixed-size `input_buf`.

## Testing

- **Unit (TDD), `formatDroppedPath`:** no-whitespace passthrough + trailing
  space; whitespace → single-quoted + trailing space; embedded single-quote
  escaping; trailing space always present.
- **Geometry:** if the rect math in `aiChatSessionAtPoint` is extracted into a
  pure helper, add point-in-rect tests (inside chat-tab rect, inside copilot
  bounds, outside both). Otherwise covered by manual GUI verification.
- **Manual GUI:** the macOS bridge already exposes
  `wispterm_macos_window_test_push_file_drop` for driving drop events. Verify on
  macOS and Windows: drop onto an AI chat tab, drop onto a copilot sidebar over
  a terminal (path goes to chat, not scp), drop with a space-containing path,
  drop multiple files at once, drop onto the terminal (unchanged SSH behavior).
- Run `zig build test` and `zig build test-full` (both must stay green).

## Out of scope (YAGNI)

- `@file` mention syntax (the composer has no such concept).
- Drag-hover highlight / drop-target affordance.
- Special handling for directories vs. files.
- Inserting at the drop's vertical position within the composer (always inserts
  at the current cursor).
