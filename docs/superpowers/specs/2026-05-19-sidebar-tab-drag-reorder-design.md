# Sidebar Tab Drag Reorder Design

## Context

Phantty currently shows terminal tabs in the left sidebar. The top titlebar is
not a tab bar; it contains the sidebar toggle, current tab title, help/settings
buttons, and native caption buttons. The old top-tab drawing path remains in
`src/renderer/titlebar.zig`, but the normal window path returns before using
it. Therefore drag-to-reorder should target only sidebar tab rows.

Ghostty models tab reordering as a tab action rather than a renderer feature.
Its core action is `move_tab(amount)`. The GTK app runtime finds the page for
the tab and calls `TabView.reorderPage`; the macOS runtime delegates movement
to the native tab group. Phantty uses a custom-drawn sidebar and an in-process
`g_tabs` array, so the matching design is to add a model-level reorder
operation and have mouse dragging call that operation.

## Goals

- Let users reorder tabs by dragging rows in the left tab sidebar.
- Preserve normal click-to-switch behavior when the mouse does not move enough
  to count as a drag.
- Keep close buttons, sidebar resizing, and double-click rename behavior
  unchanged.
- Keep the dragged tab selected after it moves.
- Preserve reordered tabs through existing session persistence.

## Non-Goals

- Do not restore or implement the old top tab bar.
- Do not add a new keyboard shortcut.
- Do not support dragging tabs between windows.
- Do not add animated tab previews or detached drag windows.

## User Experience

The user presses a tab row in the left sidebar and moves the mouse. Movement
under a small threshold, such as 6px, is treated as a normal click and switches
to that tab. Once movement exceeds the threshold, Phantty enters tab-drag mode.

While dragging, the tab is reordered as the pointer crosses other tab row
centers. The active tab follows the dragged tab, so the user never loses focus
on the terminal or AI tab they are moving. Releasing the mouse exits drag mode.

Clicking a close button still closes only on release over the close button and
does not start a drag. Dragging the sidebar resize handle keeps resizing the
sidebar and does not affect tabs. Double-clicking a tab title still starts tab
rename when the pointer is over the editable text region.

## Architecture

Add a model operation in `src/appwindow/tab.zig`:

- validate source and destination indexes;
- move the `TabState` pointer within `g_tabs`;
- move associated per-tab UI arrays such as close opacity;
- update `g_active_tab` so it continues pointing at the same logical tab;
- return whether the order changed.

Expose the operation through `src/AppWindow.zig` so input code can call it and
then clear or refresh tab-change UI state consistently with existing tab
switching.

Add sidebar drag state in `src/input.zig`:

- pressed tab index;
- current dragged tab index;
- initial pointer position;
- whether the threshold has been crossed.

On left press in the sidebar tab row, record the potential drag and switch to
that tab unless the press is on a close button. On mouse move, once the
threshold is crossed, enter drag mode and compute the destination row from the
current pointer. When the destination differs, call the model reorder function.
On release or transient input cancellation, reset the drag state.

The existing `hitTestSidebarTab` row mapping can be reused for destination
calculation. For pointer positions slightly above or below the visible tab list,
clamp the destination to the first or last tab so dragging can move a tab to an
edge without requiring pixel-perfect placement.

## Data Flow

1. User presses a sidebar tab row.
2. Input records a pending drag and switches to the pressed tab.
3. Mouse movement crosses the drag threshold.
4. Input maps pointer position to a destination tab index.
5. `AppWindow.reorderTab(from, to)` updates the tab model.
6. Rendering uses the new `g_tabs` order on the next frame.
7. Session persistence naturally snapshots the reordered `g_tabs` order.

## Error Handling and Edge Cases

Invalid indexes and single-tab windows are no-ops. A drag is canceled when
transient mouse state is canceled, the sidebar is hidden, or the tab count drops
below two. If a close button was pressed, close-button handling wins and drag
state is not started.

Dragging outside the sidebar horizontally continues the active drag, but only
vertical position affects ordering. Releasing outside the sidebar ends the drag
without additional action.

## Testing

Unit tests cover the tab model reorder operation:

- moving a tab forward;
- moving a tab backward;
- preserving the selected logical tab when moving the active tab;
- preserving the selected logical tab when moving a different tab around it;
- no-op behavior for invalid indexes and single-tab state.

Build verification uses:

```powershell
zig build test
zig build
```

Because this adds a tracked file, final verification also checks Windows path
compatibility and tracked symlinks.

## Open Decisions

No unresolved product decisions remain. The approved scope is sidebar-only tab
drag reordering.
