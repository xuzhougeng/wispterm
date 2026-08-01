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
  via `mouseInRect()`.
- Frame loop keep-alive: `titlebar.sidebarNeedsAnimation()` is called from
  `overlays.anyOverlayActive()` so the event-driven render loop keeps ticking
  during the dwell period and the show window. **Without this integration the
  tooltip never appears** because the render gate returns `needs_render = false`
  and the main loop sleeps.

**Constants:** `SIDEBAR_TOOLTIP_DWELL_MS = 350`, `SIDEBAR_TOOLTIP_SHOW_MS = 3000`.

## 2. Close-on-exit (terminal process exit closes tab/window)

**What:** When the terminal's child process exits (PTY EOF / child exit), the
tab is automatically closed. If it was the last tab, the window closes.

**Where:**
- Detection: `ReadThread.zig` calls `surface.markExited(.eof, status)` when
  `readOutput` returns 0 bytes or `markExitedIfProcessEndedAfterOutput` detects
  the process has exited after output is drained.
- Notification: `Surface.markExited()` sets `io_state = .exited`, calls
  `paintIoStatus()` (writes "Press Enter to reconnect" to terminal), and calls
  `window_backend.postWakeup()` to wake the main loop.
- Sweep: `AppWindow.sweepExitedSurfaces()` is called unconditionally at the
  top of the main loop (before `pollEvents`). It iterates all terminal tabs,
  finds surfaces where `isExited() and hasProcess()` are both true, and calls
  `tab.closeSplitAt()` to close the pane/tab/window.

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
