# Persistent UI Behaviors

These are WispTerm identity UI behaviors. They must survive every merge from `main`.
If a merge overwrites or removes them, restore them before committing the merge.

## 1. Sidebar hover tooltip (floating info popup)

**What:** When the mouse hovers over a tab icon in the left sidebar, a floating
tooltip popup appears after a 350ms dwell. The popup shows the tab title,
current working directory, and git branch (for terminal tabs). The tooltip has
an opaque background (sidebar panel color, not transparent), a 1px accent
border, and auto-dismisses after 3 seconds.

**Where:**
- Render: `titlebar.renderSidebarTooltipOverlay()` — called during the overlay
  pass (after terminal content) in `AppWindow.zig` so the popup is not
  overwritten by cell rendering.
- Hover tracking: `titlebar.renderSidebar()` sets `g_sidebar_tooltip_hovered_tab`
  via `mouseInRect()`. The renderer only runs when the render gate allows a
  frame, so the mouse-move handler must request a repaint to kick-start
  hover detection.
- Mouse-move trigger: `input.handleMouseMove()` requests a repaint
  (`requestInputRepaint()`) when the mouse is over the sidebar area. **Without
  this the render gate blocks, `renderSidebar()` never runs, the hover-tab is
  never set, and the tooltip never appears** (chicken-and-egg: the keep-alive
  below only fires once `g_sidebar_tooltip_hovered_tab` is non-null).
- Frame loop keep-alive: `titlebar.sidebarNeedsAnimation()` is called from
  `overlays.anyOverlayActive()` so the event-driven render loop keeps ticking
  during the dwell period and the show window.

**Constants:** `SIDEBAR_TOOLTIP_DWELL_MS = 350`, `SIDEBAR_TOOLTIP_SHOW_MS = 3000`.

## 2. Close-on-exit (terminal process exit closes tab/window)

**What:** When the terminal's child process exits (PTY EOF / child exit), the
tab is automatically closed. If it was the last tab, the window closes.

**Where:**
- Detection: `ReadThread.zig` calls `surface.markExited(.eof, status)` when
  `readOutput` returns 0 bytes or `markExitedIfProcessEndedAfterOutput` detects
  the process has exited after output is drained. If the read fails with an
  error, `surface.failIo()` sets `io_state = .failed` instead.
- Notification: `Surface.markExited()` / `Surface.failIo()` set `io_state` to
  `.exited` / `.failed`, call `paintIoStatus()` (writes status message to
  terminal), and call `window_backend.postWakeup()` to wake the main loop.
- Sweep: `AppWindow.sweepExitedSurfaces()` is called unconditionally at the
  top of the main loop (before `pollEvents`). It iterates all terminal tabs,
  finds surfaces where `isExited() and hasProcess()` are both true, and calls
  `tab.closeSplitAt()` to close the pane/tab/window. **`isExited()` returns
  true for both `.exited` and `.failed` states** so that normal exits AND IO
  failures trigger close-on-exit.

**Key invariant:** `sweepExitedSurfaces()` runs **before** the render gate check,
so exited panes are closed before any frame is drawn showing the reconnect
message.

## 3. Right-click sidebar tab → confirmation dialog

**What:** Right-clicking a tab icon in the sidebar always opens a close
confirmation dialog — it never directly closes the tab. The dialog variant
depends on whether a program is running:
- `running_program` — "A program is still running / Closing now will end it."
- `window_generic` — "Close WispTerm? / Running panels will be terminated."

Left-click still switches tabs directly. Middle-click uses
`requestCloseTabGesture()` which only confirms when a program is running.

**Where:** `input.zig` right-click release handler — the `hitTestSidebarTab`
branch opens `overlays.closeConfirmOpen(action, variant)` unconditionally.

## 4. File-explorer toggle on the titlebar

**What:** A folder icon (📂 or MDL2 `0xE8B7`) sits on the window titlebar,
immediately to the right of the sidebar toggle icon. Clicking it toggles the
global file explorer panel — the same action as `Ctrl+Shift+Alt+E`. The file
explorer shows the file tree for the currently active terminal's working
directory.

**Layout:** `titlebar_layout.topBarLayout()` computes `folder_x =
left_reserved + toggle_w`. The title text starts after `folder_x + folder_w +
10px`. `TITLEBAR_FOLDER_W = 46` (same as `TITLEBAR_TOGGLE_W`).

**Where:**
- Render: `titlebar.renderTitlebar()` draws the folder icon at `layout.folder_x`.
  When the file explorer is visible (`file_explorer.isVisibleForActiveTab()`),
  the icon uses the accent color; otherwise it uses the muted icon color.
- Click: `input.handleTopbarPress()` checks `xpos` in `[toggle_end,
  toggle_end + TITLEBAR_FOLDER_W)` and calls `toggleFileExplorer()`.
- Hit test: inline in `handleTopbarPress` — no separate function needed since
  the geometry is just "the next button-width after the toggle".

**Do NOT put the file-explorer toggle in the sidebar.** It belongs on the
  titlebar next to the sidebar toggle, not between the tab list and the plus
  button.

## 5. File-explorer toggle suppressed on non-terminal tabs

**What:** The file-explorer toggle (titlebar icon and `Ctrl+Shift+Alt+E`) is
suppressed when the active tab is not a terminal tab (e.g., AI chat / Copilot,
settings, SSH profile editor). The file explorer shows the file tree for the
active terminal's working directory — it has no meaning on non-terminal tabs.

**Where:** `input.toggleFileExplorer()` checks
`AppWindow.isActiveTabTerminal()` and returns early if false. This covers both
the titlebar click and the keyboard shortcut.
