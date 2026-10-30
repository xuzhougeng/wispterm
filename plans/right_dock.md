# Right dock: one switchable right panel (Copilot + File Explorer)

Status: approved (defaults: `file-explorer-position = right`, dock state per
tab) and implemented on this branch.
Branch: `feat/right-dock` (plan ships with the implementation, no doc-only PR).

## Goal

Today the right edge hosts only the Copilot sidebar (plus the separate
browser/Jupyter webview panel), and the File Explorer is pinned to the left.
Model WispTerm's right side on Otty's "details" panel: **one right dock with a
tab row that switches between features**, starting with **Copilot** and
**Files**, so the File Explorer can live on the right.

## How Ghostty handles side panels (comparison required by AGENTS.md)

Ghostty has **no tabbed side dock, sidebar, or file explorer**. Its only
side-panel-like UI is the **terminal inspector** (`inspector:toggle` action,
default `ctrl+shift+i` on GTK and `cmd+alt+i` on macOS, "matching Chromium"):

- **Per surface, not per window.** On macOS `InspectableSurface`
  (`macos/Sources/Ghostty/Surface View/InspectorView.swift`) swaps the surface
  for a vertical `SplitView` with the inspector on the **right**, a draggable
  divider, and a split fraction defaulting to 0.5. Showing it moves focus into
  the inspector; hiding it moves focus back to the surface.
- On GTK it is a separate top-level `InspectorWindow`
  (`src/apprt/gtk/class/inspector_window.zig`), not a docked panel.
- Inside, the inspector (`src/inspector/Inspector.zig`) enables **Dear ImGui
  docking** (`ImGuiConfigFlags_DockingEnable`), so its panels (screen, modes,
  keyboard, terminal IO, cell…) appear as dockable tabbed windows. That is the
  closest Ghostty gets to "tabs inside a side panel".
- Position-like config keys use a plain enum named `<feature>-position` /
  `<feature>-location`: `quick-terminal-position = top|bottom|left|right|center`,
  `gtk-tabs-location = top|bottom|left|right|hidden`.

What we take from Ghostty:

- **Open/closed is owned by the tab, not the window**, like the inspector being
  per surface. That also keeps today's per-tab Copilot visibility and its
  session-restore behavior.
- Showing the dock focuses the selected panel, and hiding it returns focus to
  the terminal. Copilot already does this; the docked explorer gets the same.
- A draggable divider on the dock's inner edge.
- The config name follows the `quick-terminal-position` shape:
  **`file-explorer-position = left | right`**.

Where we diverge, and why:

- The tab strip itself is WispTerm/Otty-specific. Ghostty has no equivalent
  outside ImGui's internal docking.
- Width is a remembered pixel width shared by every dock tab, not Ghostty's
  split fraction. Copilot already uses a pixel width, and a shared width means
  switching dock tabs never reflows or resizes the terminal PTY.

## Current layout (mapped before changing anything)

- `AppWindow.leftPanelsWidth()` = titlebar sidebar + `file_explorer.width()`.
- `AppWindow.rightPanelsWidthForWindow()` = browser panel width + Copilot width.
- `anyRightDockPanelVisible()` = browser/Jupyter only; the Copilot edge handle
  defers to it.
- **Copilot**: per-tab `TabState.copilot_visible` + `copilot_session`
  (`src/appwindow/tab.zig`), persisted per tab as `copilot_visible`
  (`src/session_persist.zig`). Width lives in `assistant/sidebar/panel.zig`
  (`g_width`, 480 default / 380 min / 1200 max, not persisted). Orchestration is
  in `src/appwindow/copilot_sidebar.zig`. The conversation renderer draws its own
  54px header (model / mode / permission chip / status dot), and AppWindow draws
  a × close button over it. The closed-state summon handle is
  `renderer/overlays/copilot_edge_handle.zig` (gated by `copilot-hint`).
- **File Explorer**: one global model in `src/file_explorer.zig`
  (`g_visible` + single `g_owner_tab`, `g_width` 240 / 160 / 720). It is
  left-anchored in three places: `renderer/file_explorer_layout.zig`
  (`panel_x = sidebar_width`), `renderer/file_explorer_renderer.zig`, and about
  eight hit-tests in `input.zig` that hard-code
  `panel_x = titlebar.sidebarWidth()`. On AI-chat tabs it switches to the
  "Agent History" list.
- **Browser/Jupyter panel** (`src/browser/`): right-docked and mutually
  exclusive with Copilot (opening one closes the other).
- `split_layout.zig` receives `content_x/content_w` from the two width
  functions above, so moving width between left and right needs no change there.

## Design

### State (feature-owned, no new globals in watched files)

New pure module **`src/appwindow/right_dock.zig`**, listed in `src/test_fast.zig`:

- `Panel = enum { copilot, files }`, `Placement = enum { left, right }`
  (the value of `file-explorer-position`).
- `TabDock = struct { open: bool = false, panel: Panel = .copilot }` holds
  **per-tab** state. It replaces `TabState.copilot_visible`, and
  `tab.activeCopilotVisible()` becomes `kind == .terminal and dock.open and
  dock.panel == .copilot`.
- `State = struct { width, explorer_placement }` holds **window-level**
  state: the shared dock width (absorbs Copilot's `g_width` and constants) and
  the placement. It lives in one module-owned instance, not in
  AppWindow/input/overlays.
- `Interaction = struct { resize_hover, resize_dragging, hover_tab, … }` moves
  `g_ai_copilot_resize_*` out of `input.zig`. When the explorer is docked, its
  resize drag goes through the dock's handle as well.
- Pure transitions: `toggle(dock, panel)` (open on that panel, or close if it
  is already showing), `select(dock, panel)`, `close(dock)`, and
  `availablePanels(placement)` (`.left` hides the Files tab).
- Pure layout: dock bounds, the **tab row** (icon-only tabs, with the selected
  tab expanded to an icon + label pill), the far-right toggle rect, content
  bounds below the tab row, the resize hit zone, `tabAt(x, y)`, and width clamp.
- Pure `emptyState(panel, ctx)` picks the empty-state copy (below).

### Visibility and layout wiring

- `leftPanelsWidth()` = sidebar + explorer width **only when placement is `left`**.
- `rightPanelsWidthForWindow()` = browser + dock width when the active tab's
  dock is open.
- When placement is `right`, the explorer's existing `g_visible`/`g_owner_tab`
  are driven by the dock through one sync function: the active tab's dock
  showing Files means `openForActiveTab()` plus a resync to that tab's cwd;
  otherwise the explorer is closed for that tab. That sync runs from
  `clearUiStateOnTabChange()` (which already resyncs the explorer) and from
  every dock transition, so tab switches and toggles cannot drift.
- One geometry source per panel: `AppWindow.rightDockContentBounds()` replaces
  the nine `ai_sidebar.boundsForWindow(…, titlebar_h, …)` call sites and the
  `titlebarHeight()` tops passed to Copilot's own hit-tests (stop button,
  input metrics, transcript selection, scroll). An `explorerPanelRect()` helper
  replaces the hard-coded `panel_x = sidebarWidth()` explorer hit-tests, and
  `file_explorer_layout.compute` takes `panel_x`/`top` instead of assuming the
  left edge.
- The dock renders where Copilot renders today, after terminal content, so a
  docked explorer is never painted over by cell backgrounds.
- The browser/Jupyter panel stays a separate, exclusive right panel. Opening it
  closes the dock and opening the dock closes it, using today's arbiter. Moving
  the browser into the dock is a follow-up.

### UI (Workbench-page style, persistent panel)

- **Tab row** at the top of the dock, height `max(32, text_h + 14)`. Each tab
  is a 28px icon button; the selected tab expands to an icon + label pill
  ("Copilot", "Files"). New `chrome_icons` kinds are `folder` and
  `panel_right`; `copilot` already exists. Hovering highlights the tab and
  repaints.
- **One open/close toggle**: the `panel_right` button at the far right of the
  tab row. The per-panel × buttons (Copilot header, explorer header) are
  removed in the dock; the explorer keeps Refresh. When the dock is closed, the
  existing right-edge hover handle (`copilot-hint`) reopens it on the
  last-selected tab. A titlebar right-edge toggle should join #703's
  hover-revealed toolbar, so it is a **follow-up after #703 merges**, since
  that PR rewrites `titlebar.zig`, `win32.zig` and the macOS bridge.
- **Width** is one shared width, resizable from the dock's left edge, clamped
  to 380–1200 px while keeping ≥ 320 px of terminal. It is **persisted** in the
  window-state file (`right_dock_width`) when a drag ends and restored on
  launch.
- **Empty states**: each tab says why it is empty and what to do next.
  - Copilot on a non-terminal tab: "Copilot runs beside terminal tabs." /
    "Switch to a terminal tab to chat."
  - Copilot with no usable profile: "No Copilot profile configured." /
    "Open Settings › AI to add one."
  - Files with no cwd: "No working directory yet." / "The shell has not
    reported one; cd somewhere or press Refresh."
  - Files on an empty folder: "This folder is empty."
  - Agent History (AI tabs) with no rows: "No saved agent conversations yet."
- **Repaint**: every dock click, hover or key change returns or lands a
  `UiEffect`; nothing in the dock writes `g_force_rebuild`/`g_cells_valid`.

### Keyboard shortcuts (bindings unchanged)

- Copilot (`Ctrl+Shift+A` / `Cmd+Shift+A`, `toggle_ai_copilot`) opens the dock
  on Copilot, or closes it when Copilot is already showing.
- File Explorer (`Ctrl+Shift+Alt+E` / `Cmd+Shift+Opt+E`,
  `toggle_file_explorer`): with `right` it does the same for the Files tab;
  with `left` it behaves as today.
- README "Keyboard shortcuts" rows, the command-center detail strings
  ("left-side file explorer"), and the startup-shortcut overlay text are
  updated to describe the dock. `docs/configuration.md` and
  `docs/file-explorer.md` document `file-explorer-position`.

### Config

`file-explorer-position = right | left`, **default `right`** (decision for the
user, see below). It hot-reloads: switching placement closes the explorer and
resyncs the layout.

### Persistence

- Per-tab `copilot_visible` stays in the session file for backward
  compatibility. It is written as `dock.open and dock.panel == .copilot` and
  read back into the tab's `TabDock`. Files-dock state is not persisted, just
  as explorer visibility is not persisted today.
- `right_dock_width` is added to `platform/window_state_codec.zig`.

### Guards

- No new top-level `g_*`/`threadlocal` in `AppWindow.zig`, `input.zig`, or
  `renderer/overlays.zig`.
- Moving the Copilot and explorer resize hover/drag flags into
  `right_dock.Interaction` **lowers the `input.zig` global-state ceiling**
  (41 → ≤ 39). Any direct dirty-global write touched on the way is converted to
  a `UiEffect`, and the side-effect ceilings are lowered to match.
- The import hub is untouched; new code imports `appwindow/right_dock.zig`
  directly.

### Tests

- Fast suite, `right_dock.zig`: tab-row layout (selected expands; icon-only
  others fit), `tabAt`, toggle-rect and resize hit zones, transitions
  (toggle/select/close; Files unavailable when `left`), width clamp, and
  empty-state selection.
- Updated `file_explorer_layout` tests for right-anchored geometry.
- Config parse test for `file-explorer-position`.
- Window-state codec round-trip for `right_dock_width`.
- Session-persist compat: old `copilot_visible: true` restores the dock on
  Copilot.
- `test-full`: an input→repaint regression for clicking a dock tab, via the
  existing `UiEffect` test helpers.

### Verification

- `zig build test`, `zig build test-full`, and `zig build` (Windows
  cross-compile).
- macOS: `zig build macos-app -Dtarget=aarch64-macos`, then launch a **separate**
  instance with `HOME` pointed at a scratch directory, so its config, window
  state and session file stay apart from the user's. Launch it via
  `./zig-out/bin/WispTerm.app/Contents/MacOS/WispTerm`. Check
  tab switching, toggle, resize, empty states and both shortcuts. The user's
  running WispTerm window is not touched.

## Decisions needed before implementing

1. **Explorer default position**: `file-explorer-position` defaults to
   **`right`** (recommended; it is the point of the dock), with `left`
   restoring today's layout. Alternative: default `left`, with the dock opt-in.
2. **Dock open/closed scope**: **per tab** (recommended; matches Ghostty's
   per-surface inspector and today's per-tab Copilot). Alternative: per window,
   like Otty, where the dock stays open across tab switches and Copilot follows
   whichever tab is active.

## Implementation notes

Refinements made while building it, all within the approved design:

- **DPI scaling**: tab-row metrics are logical pixels scaled by `dpi / 96`, the
  same factor the titlebar uses. Without it the icons rendered at half size on
  Retina.
- **Word-wrapped empty states**: in a narrow dock both lines wrap instead of
  ending in an ellipsis.
- **Copilot with no profile**: the dock stays open on the "No Copilot profile
  configured" empty state, and the Quick Configure AI dialog still opens, as the
  shortcut always did.
- **Copilot header**: the 36 px trailing slot reserved for the removed × button
  is reclaimed. The status dot keeps a 4 px gap.
- **Ratchets**: `input.zig` globals go from 41 to 39 (the Copilot resize flags
  moved to `right_dock.Interaction`). `AppWindow.zig` direct dirty writes go
  from 26 to 24 (`markRemoteSyncUiDirty` and `markWeixinUiDirty` now go through
  `applyUiEffect`).

## Out of scope / follow-ups

- Titlebar right-edge dock toggle inside #703's hover-revealed toolbar (after
  #703 merges).
- Moving the browser/Jupyter webview panel into the dock as a third tab.
- Otty-style Info/Ports/Process tabs.
