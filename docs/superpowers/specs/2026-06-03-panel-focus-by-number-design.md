# Focus Panel by Number (Cmd/Ctrl + 1–9)

**Date:** 2026-06-03
**Status:** Design — approved by user, pending spec review

## Problem

Within a single tab, WispTerm can hold multiple terminal panels (leaves of the
tab's `SplitTree`). Today you can only move panel focus **directionally**
(`Alt/Option+Arrow` → `focus_left/right/up/down`) or **cyclically**
(`Ctrl/Cmd+Shift+[` / `]` → `focus_previous/next`). There is no way to jump
directly to a specific panel by number.

We want **Cmd+1 … Cmd+9** (macOS) to focus the 1st…9th panel in the active tab,
numbered by **screen position, top-left → bottom-right (row-major)**.

The number keys are otherwise unused with this modifier: tab switching is bound
to `Alt/Option+number` (`switch_tab_1..9`, `keybind.zig:427`), and `Cmd+number`
is currently unbound.

## Constraints & decisions

- **Numbering:** by on-screen position, row-major — top rows first, left→right
  within a row. Independent of tree/insertion order.
- **Modifier:** default `Ctrl+1..9`. The keybind table is authored in `Ctrl`
  and remapped to `Cmd` on macOS (`keybind.zig:122-142`), so this renders as
  **Cmd+1..9** on macOS and `Ctrl+1..9` on Linux/Windows. Tabs keep
  `Alt/Option+number`; no conflict.
- **Range:** panels 1–9 only. A 10th+ panel is not reachable by number.
- **Fall-through:** if there is no panel at the requested index (e.g. a
  single-panel tab, or the index exceeds the panel count), the action does
  nothing and **does not consume** the key — it falls through to the terminal,
  mirroring `gotoSplit`'s `bool` return (`AppWindow.zig:2108`). This avoids
  shadowing terminal `Ctrl+number` input on Linux/Windows when there's nothing
  to focus.
- **No conflict** with the existing `focus_previous/next` cycle (tree order) or
  `Alt+Arrow` directional focus — those are unchanged.

## Architecture

The split tree already exposes everything needed:

- `SplitTree.spatial(alloc) → Spatial{ slots: []Slot }` — each node gets a
  normalized `Slot{ x, y, width, height }` in a 1×1 space, top-left = (0,0)
  (`split_tree.zig:892-940`). Slots are indexed by node handle.
- `SplitTree.iterator()` yields `SurfaceEntry{ handle, surface }` for every leaf
  (`split_tree.zig:154-183`).
- Focus is just `TabState.focused: SplitTree.Node.Handle` (`tab.zig:47`); the
  existing `gotoSplit` sets it and the app reacts via
  `handleActiveSurfaceChangeWithinTab()` (`AppWindow.zig:2108-2116`).

### Reading-order ordering (pure, testable)

A small pure layer, independent of `Surface`:

```zig
pub const PanelPos = struct { handle: SplitTree.Node.Handle, x: f16, y: f16 };

/// Stable row-major sort: primary key y quantized to a tolerance so panels
/// sharing a visual row group together, secondary key x (left→right).
pub fn sortReadingOrder(items: []PanelPos) void;
```

Quantization: bucket `y` by `@round(y * ROW_QUANTA)` (with `ROW_QUANTA = 64`,
giving ~1.5% tolerance) as the primary sort key, then `x` ascending. Splits
produce clean fractions and rows are separated by a meaningful fraction of
height, so quantization groups true same-row panels (whose `y` are equal or
near-equal) without merging distinct rows. Using a quantized integer key keeps
the comparator transitive (avoids the floating-epsilon-comparator hazard). The
sort is stable so ties (same bucket, same x — not expected) keep tree order.

### Enumerate + focus

In `appwindow/tab.zig`:

```zig
/// Leaf-panel handles in screen reading order (top-left → bottom-right).
/// Caller owns the returned slice (allocated with `alloc`).
pub fn panelsInReadingOrder(alloc: std.mem.Allocator) ![]SplitTree.Node.Handle;

/// Focus the n-th panel (1-based) in reading order. Returns false if there is
/// no such panel (n < 1 or n > panel count), leaving focus unchanged.
pub fn focusPanelByIndex(alloc: std.mem.Allocator, n: usize) bool;
```

`panelsInReadingOrder` builds `[]PanelPos` from `tree.spatial(alloc)` (reading
`slots[handle.idx()]`) for each leaf from `tree.iterator()`, calls
`sortReadingOrder`, and returns the handles. `focusPanelByIndex` calls it; if
`n >= 1 and n <= handles.len`, sets `t.focused = handles[n-1]` and returns true,
else returns false.

In `AppWindow.zig` (mirrors `gotoSplit`):

```zig
/// Focus the n-th panel by reading order. Returns whether focus moved (false =
/// no such panel, so the caller can let the key fall through).
pub fn focusPanel(n: usize) bool {
    const allocator = g_allocator orelse return false;
    if (tab.focusPanelByIndex(allocator, n)) {
        handleActiveSurfaceChangeWithinTab();
        return true;
    }
    return false;
}
```

### Keybind actions + dispatch

- Add `focus_panel_1 … focus_panel_9` to `keybind.Action`
  (`keybind.zig:83-91`, beside `switch_tab_1..9`).
- Add default triggers `Ctrl + '1'..'9' → focus_panel_N`
  (`keybind.zig` default table, beside the `Alt+number` tab binds at 427-435).
- A `focusPanelIndex(action) ?usize` helper (mirroring `switchTabIndex` in
  `input/command_dispatch.zig:80-92`) maps `focus_panel_N → N`.
- In `input.zig`, where actions are handled (beside the `focus_left/right/...`
  → `gotoSplit` arm at `input.zig:1152-1157` and the `switch_tab` arm at
  `1163-1169`): `focus_panel_N → if (!AppWindow.focusPanel(N)) <fall through>`.
  Consume the key only when `focusPanel` returns true; otherwise let it pass to
  the terminal (same convention as the directional `gotoSplit` arm).

## Files

- `src/split_tree.zig` — add `PanelPos` + `sortReadingOrder` (pure). (Or a tiny
  new leaf module if it keeps `split_tree.zig` focused; default: keep in
  `split_tree.zig` next to `Spatial`, since it operates on spatial slots.)
- `src/appwindow/tab.zig` — `panelsInReadingOrder`, `focusPanelByIndex`.
- `src/AppWindow.zig` — `focusPanel`.
- `src/keybind.zig` — `focus_panel_1..9` actions + default `Ctrl+1..9` triggers.
- `src/input/command_dispatch.zig` — `focusPanelIndex` mapping helper.
- `src/input.zig` — dispatch arm + fall-through.
- (Optional) `src/renderer/overlays/startup_shortcuts.zig` — add a hint row for
  the new shortcut, matching the existing "Previous / next panel" entry
  (`startup_shortcuts.zig:62`).

## Error handling / edge cases

- Empty tree / no `g_allocator` → `focusPanel` returns false (no-op,
  fall-through).
- Single-panel tab → only index 1 exists; `Cmd+1` re-focuses it (no visible
  change), `Cmd+2..9` fall through.
- Index beyond panel count → false / fall-through.
- `spatial()` allocates; `panelsInReadingOrder` frees the spatial slots and
  returns its own owned handle slice (caller frees). On allocation failure,
  `focusPanelByIndex` returns false (treated as no-op).
- Zoomed/maximized panel state is unaffected — we only change which leaf is
  focused; existing focus-change handling applies.

## Testing

**Pure (`sortReadingOrder`, runs wherever `split_tree.zig` tests run):**
- Two-wide row `[(h0,x0,y0),(h1,x0.5,y0)]` → `[h0,h1]`.
- Two-stacked column `[(h0,x0,y0),(h1,x0,y0.5)]` → `[h0,h1]`.
- 2×2 grid (handles shuffled on input) → row-major `[top-left, top-right,
  bottom-left, bottom-right]`.
- Uneven nesting: one tall left panel + two stacked right panels → `[left,
  top-right, bottom-right]` (left `y=0` groups with top-right's row by quanta;
  tie broken by x so left precedes top-right).
- Already-ordered input stays ordered (stability).

**Tab-level (`focusPanelByIndex`, where `tab.zig` tests run — full suite):**
- Build a 2-panel split; `focusPanelByIndex(1)`/`(2)` set the expected handle
  and return true; `(3)` and `(0)` return false and leave `focused` unchanged.

**Keybind:**
- Default-binding test: `Ctrl+1` resolves to `.focus_panel_1` (and on macOS the
  remap yields the `Cmd` form), mirroring the existing `switch_tab` binding
  test.

## YAGNI / out of scope

- No numbers beyond 9; no "panel 10+".
- No on-screen panel-number overlay/badges (focus is already indicated by the
  active-surface border).
- No reordering/renumbering UI; order is derived from layout each time.
- No change to tab switching, directional focus, or the prev/next cycle.
