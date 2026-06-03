# Panel Swap via Alt-Drag — Design

Date: 2026-06-03
Status: Approved, ready for implementation
Branch: `worktree-feat-enhancer-panel-control`

## Problem

Within a single tab, panels (terminal surfaces in the `SplitTree`) can today only
be **created** (`splitFocused` → `tree.split`) and **closed**
(`closeFocusedSplit` → `tree.remove`). There is no way to **rearrange** them. Users
want to swap two panels' positions, driven by the mouse.

## Goal

Add a mouse gesture that swaps the contents of two panels within a tab:

- **Gesture:** hold **Alt** and left-drag from a source panel, drop onto a target
  panel; on release the two panels' contents are swapped.
- **Semantics:** swap the two leaves' `*Surface` only. The split-tree topology,
  layout, and ratios are **unchanged**. Any two panels in the tab can be swapped,
  not just adjacent ones.
- **Feedback:** during the drag the source panel dims, the hovered target panel
  gets a highlight border, and the cursor becomes the `size_all` (4-way move) shape.

Non-goals (YAGNI for v1):

- Keyboard shortcut / command-palette entry (the request is mouse-driven).
- Topology-changing "move panel to a new edge" (re-parenting subtrees).
- A floating thumbnail/ghost of the dragged panel.

## Why "swap leaves" (chosen approach)

Three options were considered for the core operation:

| Option | Approach | Trade-off |
|--------|----------|-----------|
| **A. In-place leaf-surface swap (CHOSEN)** | Swap the two `*Surface` pointers at the two leaf nodes. Topology/ratio unchanged, no ref-count change, O(1), no allocation. Same mutable pattern as `resizeInPlace`/`zoom`. | Simplest and most predictable. No undo support — but the project has no split undo anyway. |
| B. Clone-and-swap into a new tree | Honors the "immutable tree" doc comment; leaves room for future undo/redo. | Extra allocation + `refNodes` for no current benefit (no undo system, topology unchanged). |
| C. `remove` + `split` to physically move the node | Truly mutates topology. | Overkill; changes ratios/layout; error-prone; it is a "move", not a "swap". |

Option A is chosen.

## Components

### 1. `src/split_tree.zig` — new operation

```zig
/// Swap the surfaces held by two leaf nodes in place. Both handles MUST refer
/// to leaf nodes (asserted). Topology, layout, ratios, zoom state, and
/// reference counts are all unchanged — only the two *Surface pointers swap.
pub fn swapLeaves(self: *SplitTree, a: Node.Handle, b: Node.Handle) void
```

- Asserts `a.idx()` and `b.idx()` are in range and both nodes are `.leaf`.
- Uses the same `@constCast` pattern as `resizeInPlace` to mutate the owned nodes.
- `a == b` is a harmless no-op (still valid).
- Does **not** touch `zoomed`: the zoomed handle refers to a slot, and swapping the
  surface in a slot keeps the zoom on that slot. (Dragging while a panel is zoomed
  is practically impossible since the other panels aren't visible.)

### 2. `src/appwindow/tab.zig` — wrapper

```zig
/// Swap the panels at handles `a` (drag source) and `b` (drop target).
/// Focus follows the dragged surface to the target slot. Returns true on success.
pub fn swapPanels(a: SplitTree.Node.Handle, b: SplitTree.Node.Handle) bool
```

- Returns `false` if: no active tab, tab is not `.terminal`, either handle is out of
  range, either node is not a leaf, or `a == b`. (Defensive: a shell may have exited
  mid-drag and changed the tree.)
- Calls `t.tree.swapLeaves(a, b)`.
- Sets `t.focused = b` so focus follows the dragged surface to its new slot.
- Returns `true`. The caller (input layer) is responsible for
  `split_layout.invalidateCachedRects()`, `AppWindow.g_force_rebuild = true`, and
  `AppWindow.handleActiveSurfaceChangeWithinTab()`.

### 3. `src/input.zig` — Alt-drag state machine

Modeled on the existing `g_divider_drag*` and sidebar-tab-drag patterns.

New thread-local state:
- `g_panel_swap_source: ?SplitTree.Node.Handle`
- `g_panel_swap_target: ?SplitTree.Node.Handle`
- `g_panel_swap_start_x: f64`, `g_panel_swap_start_y: f64`
- `g_panel_swap_active: bool`

New helper:
- `panelHandleAtPoint(x, y) ?SplitTree.Node.Handle` — scans `split_layout.g_split_rects`
  (skipping non-live rects), returns the handle of the panel containing the point.

New constant: `PANEL_SWAP_DRAG_THRESHOLD_PX` (~6px).

Flow:
- **Mouse press** (left button + `ev.alt`, active tab is terminal, `tree.isSplit()`):
  record `g_panel_swap_source = panelHandleAtPoint(...)`, save start coords, focus the
  source panel, set cursor to `size_all`, and `return` (do **not** enter selection).
  If `tree.isSplit()` is false (single panel) the gesture is not engaged and input
  falls through to default behavior.
- **Mouse move** while a source is recorded: if not yet `active`, engage `active`
  once the move distance exceeds `PANEL_SWAP_DRAG_THRESHOLD_PX` (and clear
  `g_selecting`). Once active, compute `g_panel_swap_target = panelHandleAtPoint(...)`,
  but set it to `null` when the point is over the source itself, over a divider, or
  outside any panel. Trigger a rebuild so the highlight updates.
- **Mouse release** while a source is recorded: if `g_panel_swap_active` and the
  target is non-null and `!= source`, call `tab.swapPanels(source, target)` and (on
  success) invalidate rects + force rebuild + `handleActiveSurfaceChangeWithinTab`.
  Otherwise cancel. Always reset swap state and restore the cursor. Consume the event.
- `cancelTransientMouseState` resets all swap state too.

The press-time check is added **before** the existing divider / selection / URL-open
logic so Alt-drag is intercepted cleanly.

### 4. `src/AppWindow.zig` per-panel render loop + `src/renderer/overlays.zig` — feedback

In the per-split render loop (`for (0..split_count)`), when `input.g_panel_swap_active`:
- If `rect.handle == g_panel_swap_source`: dim it via the existing
  `overlays.renderUnfocusedOverlaySimple(width, height)` (even if it is the focused
  panel).
- Else if `rect.handle == g_panel_swap_target`: draw
  `overlays.renderSwapTargetHighlight(width, height)`.
- Else: existing non-focused dim logic applies unchanged.

New overlay helper in `overlays.zig`:
```zig
/// Accent-colored highlight for a panel that is the current swap drop target:
/// a faint accent fill plus an accent border, drawn in the panel's own viewport.
pub fn renderSwapTargetHighlight(width: f32, height: f32) void
```
Implemented with `ui_pipeline.fillQuadAlpha` (faint `mixColor(bg, accent, …)` fill +
four thin border quads in `accent = AppWindow.g_theme.cursor_color`).

## Data flow

```
Alt + left press in panel P (tab is split)
  → input: g_panel_swap_source = handle(P), focus P, cursor = size_all
move (> threshold)
  → input: g_panel_swap_active = true; g_panel_swap_target = handle under cursor
  → render: source dimmed, target highlighted
release over target T (T != P)
  → input: tab.swapPanels(handle(P), handle(T))
      → split_tree.swapLeaves: swap *Surface at the two leaves
      → tab: focus follows to T's slot
  → input: invalidate rects + force rebuild + active-surface-change
  → reset swap state, restore cursor
```

## Edge cases

- **Single panel (not split):** gesture not engaged; default behavior (Alt-drag is
  not otherwise used for selection).
- **Release over source / divider / outside any panel:** cancel, no swap.
- **Drag never crosses threshold (Alt-click):** treated as a focus click on the
  source panel; no swap, no selection.
- **Shell exits mid-drag and mutates the tree:** stored handles may be stale;
  `swapPanels` validates range + leaf-ness and returns `false`, so nothing happens.
- **Zoomed panel:** zoom is left untouched; in practice the other panels aren't
  visible to drop onto.

## Testing

- `src/split_tree.zig`: unit test for `swapLeaves` using the existing sentinel-surface
  pattern (see `fromSnapshot` tests):
  - After swapping two leaves, the two slots' surface pointers are exchanged.
  - `layout`, `ratio`, and all `Node.Handle`s are unchanged.
  - Swapping the same pair twice restores the original arrangement.
- Register the new test file usage if needed (split_tree tests already run; confirm
  via `test_fast.zig` / `test_main.zig` wiring).
- Input/render glue follows the project's GUI-verify convention (not unit-tested);
  verify manually on macOS/Windows.

## Out of scope / future

- Keyboard `swap_panel_*` keybind and command-palette entry.
- Topology-changing move (drop on a panel edge to re-split).
- Floating ghost thumbnail of the dragged panel.
- Optional: a one-line mention of the gesture in the help/shortcuts overlay.
