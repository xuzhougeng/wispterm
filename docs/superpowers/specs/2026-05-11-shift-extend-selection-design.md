# Shift+Click Extends Selection — Design

## Context

Phantty's mouse selection currently supports plain click, drag, and 1-to-4 multi-click (char/word/sentence/paragraph). The mouse-event struct already carries Shift/Ctrl/Alt modifier flags, but the `handleMouseButton` left-down path in `src/input.zig:2045+` never consults them — Ctrl is only read for URL/preview opening, and Shift is ignored entirely.

This means a user who selects "Hello", realizes they wanted "Hello world", and Shift+clicks on "d" loses the original anchor: the click is treated as a fresh selection at "d". This is unergonomic and diverges from every mainstream editor and file manager.

This spec adds the standard "Shift+click extends current selection" behavior, plus the same for Shift+drag, with no new fields and no refactoring of the existing selection model.

## Goals

- `Shift+left-click` extends an active selection from its existing anchor to the clicked cell, preserving the original anchor.
- `Shift+left-drag` extends continuously while the mouse moves with Shift held (auto-falls-out of the click case — no extra wiring).
- Be a strict superset of current behavior: no scenario without Shift behaves differently.
- Zero new state on the `Selection` struct. Zero new globals beyond what already exists for click tracking.

## Non-Goals

- **Multi-click mode preservation.** Shift+click after a double-click word selection extends by character, not by word. Adding word/sentence/paragraph-aware extension is deferred to v2 and would require a new `Selection.mode` field plus boundary helpers.
- **Keyboard selection extension** (Shift+arrow keys). Out of scope; deferred to v2.
- **Shift+click on a non-active selection** doing anything fancier than a plain click. The terminal cursor is a moving target driven by the PTY; using it as an implicit anchor would produce unpredictable selections.
- **Ctrl+Shift+click** disambiguation. Shift wins; Ctrl is ignored when both are held. Ctrl+click (URL/preview open) and Shift+click (extend) have unrelated semantics with no useful combination.

## Surveyed Facts (load-bearing)

| Fact | Location |
|---|---|
| `Selection { start_col, start_row, end_col, end_row, active }` per-Surface | `src/Surface.zig:34-40` |
| Mouse button down handler dispatches on click count 1-4 | `src/input.zig:2045-2313` (`handleMouseButton`) |
| Drag extends `selection.end_*` while `g_selecting=true` | `src/input.zig:2674-2703` (`handleMouseMove`) |
| Click count tracked via `g_left_click_count` + 500 ms / one-cell-distance gate | `src/input.zig:335-339`, `1481-1498` |
| Mouse event carries `ctrl/shift/alt: bool` populated via `GetKeyState` | `src/apprt/win32.zig:720-728`, `1260-1266` |
| `markSelectionChanged()` invalidates render cache | `src/input.zig:1476-1479` |
| Ctrl+left-click is taken (URL/preview); Shift+left-click is unbound | `src/input.zig:2280` |

## Behavior Contract

The full matrix of input → behavior. Rows in **bold** are new; everything else is unchanged.

| Input | Shift held | Current `selection.active` | Behavior |
|---|---|---|---|
| Left-click | no | any | Unchanged: `start=end=clicked`, `active=false`, `g_selecting=true`, increment click count |
| Left-drag | no | dragging | Unchanged: `end` follows mouse; `active=true` once movement exceeds threshold |
| Double / triple / quad-click | no | any | Unchanged: select word / sentence / paragraph |
| **Shift+left-click** | **yes** | **`active=true`** | **`end=clicked`, `start` unchanged, `g_selecting=true`, click count reset to 1, last-click position updated to current, `markSelectionChanged()`** |
| **Shift+left-click** | **yes** | **`active=false`** | **Degrades to plain left-click (no extension; new selection at click point)** |
| **Shift+left-drag** | **yes** | **any** | **Automatic: Shift+click sets `g_selecting=true`, then existing `handleMouseMove` carries `end` to mouse position even after Shift is released mid-drag** |
| Shift+double/triple-click | yes | any | Degrades to plain double/triple-click (select word/sentence at click point) |
| Ctrl+Shift+click | yes | any | Treated as Shift+click; Ctrl ignored |

### Why click count resets to 1 on Shift+click

If the count is left intact, a plain click in the same vicinity within 500 ms after Shift+click would be treated as the second click of a sequence and trigger word selection — destroying the just-extended range. Resetting to 1 means "this Shift+click is a fresh first click; the next plain click starts its own sequence."

### Why we update last-click position to current

So the same 500 ms / one-cell distance gate that drives click-count tracking is anchored on where the user actually clicked, not on a stale "Hello" position. Without this, a Shift+click far away followed by a plain click anywhere would not be misidentified as a double-click, but the gate state would be confusingly out of sync with the visible selection.

### Reverse selection (anchor right of click)

Not special-cased. The renderer already normalizes min/max for highlight extent (otherwise reverse drag would not work today). We only mutate `end_col` / `end_row`; the renderer handles the rest.

## Implementation

Single insertion in `src/input.zig` `handleMouseButton`, before the existing left-down dispatch on click count:

```zig
// Shift+left-click extends an existing selection without creating a new one.
// See spec docs/superpowers/specs/2026-05-11-shift-extend-selection-design.md
if (ev.shift and surface.selection.active) {
    surface.selection.end_col = clicked_col;
    surface.selection.end_row = clicked_row;
    g_selecting = true;            // allow follow-up Shift+drag to keep extending
    g_left_click_count = 1;        // don't let this count toward a double-click
    g_last_left_click_ms = std.time.milliTimestamp();
    g_last_left_click_xpos = xpos;
    g_last_left_click_ypos = ypos;
    markSelectionChanged();
    return;
}
// existing left-down path (nextLeftClickCount → switch on count → ...) follows
```

Field names of the click-tracking globals (`g_last_left_click_ms` / `_xpos` / `_ypos`) must be confirmed against the actual declarations near `src/input.zig:335-339`. If any name differs, use the actual one.

`clicked_col` and `clicked_row` are the cell coordinates derived from `xpos` / `ypos` and the cell pitch. The current handler already computes these for the existing dispatch; the Shift branch must be inserted **after** that computation. If the existing code computes them lazily inside the multi-click switch, hoist the computation to the top of the left-down path.

Placement constraint: the Shift branch must sit **after** any PTY-mouse-passthrough check (so vim/tmux mouse mode still gets the event when their app is active) and **before** the multi-click dispatch.

`handleMouseMove` is not modified. Once `g_selecting=true`, the existing drag path at `src/input.zig:2674-2703` already moves `end_col` / `end_row` with the mouse — Shift+drag is therefore automatic. Shift may even be released mid-drag and the drag continues, matching VSCode behavior.

The `Selection` struct is not modified. No new fields, no new globals.

## Invariants

| # | Invariant | Enforcement |
|---|---|---|
| I1 | A non-Shift mouse interaction behaves identically to before this change | The new branch returns early; the old path is untouched |
| I2 | A Shift+click on an inactive selection never crashes or corrupts state | `surface.selection.active` is checked first; the false case falls through to plain-click handling |
| I3 | After Shift+click, a follow-up plain click in the same area is not misread as a double-click | Click count reset to 1 + last-click position updated to current |
| I4 | Reverse selections (`end` before `start`) keep working | We only write `end_*`; renderer already handles min/max |
| I5 | PTY mouse passthrough (vim/tmux) keeps working | Shift branch is inserted after the existing passthrough check |

## Test Strategy

### No unit tests

`handleMouseButton` is tightly coupled to `Surface`, PTY state, and module-level globals. Extracting a pure function for ~10 lines of new logic plus one branch would be over-engineering; the test would mock everything that matters and verify essentially the literal source. The 8-step manual checklist below is the acceptance test.

### Manual verification (`acceptance test`)

Tester: user, on Windows. Failing any step blocks merge.

1. Launch `phantty.exe`, shell prompts, run `echo "Hello world"`.
2. **Baseline.** Plain drag from `H` to `d` → highlights `Hello world`. (Confirms existing drag still works.)
3. **Shift+click extends.** Plain drag from `H` to `o` to select `Hello`. Release. Hold Shift and click on `d` → highlight grows to `Hello world`.
4. **Shift+drag extends.** Same setup as 3. Hold Shift and **drag** from outside the selection to `d` → highlight grows to `Hello world`. Release Shift mid-drag and continue moving → highlight keeps following the mouse.
5. **No-active-selection degrade.** Open a fresh tab, no prior selection. Hold Shift and click on `H` → behaves like a plain click (no crash; `selection.start=end=H`, `active=false`).
6. **Multi-click not poisoned.** Do a Shift+click anywhere, immediately do a plain double-click on a word elsewhere → that word is selected (not misinterpreted as the second click of a sequence).
7. **Reverse selection extends.** Drag from `d` backward to `o` (end is left of start). Release. Shift+click on `H` → highlight is `Hello world` (renderer normalizes min/max).
8. **Clipboard sanity.** After any of steps 3, 4, 7, press `Ctrl+Shift+C` → clipboard contents exactly equal the highlighted text.

### Out of scope for verification

- WSL surfaces (selection is a Phantty concern, not a remote shell concern).
- Cross-platform drag behavior (Phantty is Windows-only).
- Performance — branch is one `if` and four assignments; immeasurable.

## Risks

- **Local variable naming.** If `clicked_col` / `clicked_row` are computed inside the multi-click switch instead of at the top of the left-down path, they must be hoisted before the Shift branch. ~3 lines of motion. Discoverable in seconds during implementation.
- **PTY passthrough placement.** If the Shift branch is accidentally placed before the mouse-passthrough check, vim/tmux users would lose Shift+click in their apps. Implementation must place the Shift branch immediately after passthrough returns.
- **Reverse selection assumption.** This spec assumes the cell renderer normalizes min/max for highlight extent. If it does not, reverse Shift+click could draw an empty or inverted highlight. Behavior is the same as today's reverse drag, so if reverse drag already works, this works.

## Future Work

- v2: `Selection.mode = { char, word, sentence, paragraph }` + boundary helpers, so Shift+click after a double-click word extends by word.
- v2: `Shift+arrow` keyboard extension. Currently `Alt+arrow` is split focus; `Shift+arrow` is unbound for terminal input only at modifier=2 (`\x1b[1;2A` etc.) which most apps interpret as cursor-with-shift, but a Phantty-level "extend selection" pre-empt would require care to not break those apps.
- v2: Drag-and-extend across multi-click selections (e.g., double-click a word to enter word mode, then Shift+click extends to the word at the cursor).
