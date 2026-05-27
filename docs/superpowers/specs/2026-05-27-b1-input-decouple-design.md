# B1 — Decouple `input.zig` (presentation/logic separation)

Phase B, item B1 of the cross-platform portability roadmap
([TODO.md](../../../TODO.md), [decoupling-guide.md](../../decoupling-guide.md) §5).

## Goal

Extract the **pure decision logic** out of `src/input.zig` into std-only,
unit-testable sibling modules, leaving `input.zig` as the thin platform-event +
global-state + side-effect-execution shell. This satisfies B1 ("extract keybind
parsing and command dispatch from platform input-event handling into pure,
unit-testable modules") and produces B4 unit tests in the same pass.

Approach (chosen): **targeted pure-module extraction**, matching the established
repo pattern (`keybind.zig`, `input_shortcuts.zig`, `selection_unit.zig`,
`ai_chat_layout.zig`, `titlebar_layout.zig`, …): pure logic moves to sibling
modules with std-only `test` blocks, `input.zig` delegates, and the modules are
regression-locked by `_ = @import(...)` in `src/test_main.zig`.

**Explicitly NOT chosen:** struct-ifying the 31 global `threadlocal var`s into an
injected `InputState`. That is the "aggressive" path with a large blast radius
on every call site and is out of scope for B1.

## Current state (the coupling)

`src/input.zig` is a module-level singleton (~3,573 ln, 31 global
`threadlocal var g_*`) mixing:

- platform event pumping (`processEvents`, `handleKey`, `handleChar`),
- keybind action dispatch (`handleConfiguredKeybindAction`, `switchTabActionIndex`),
- hit-testing (`hitTestSidebar*`, panel resize handles, scrollbar targets),
- click/drag state machines (`nextLeftClickCount`, sidebar tab drag),
- selection (`activateSelection`, …) — partly already in `selection_unit.zig`.

`handleConfiguredKeybindAction(action, phase)` is the central dispatch: it
interleaves the *decision* (which command this `keybind.Action` triggers in the
`.early`/`.late` phase, and whether it is consumed) with the *execution* (the
`AppWindow.*` / `overlays.*` side-effect calls). That interleaving is the B1
seam.

## Design — three new modules under `src/input/`

### 1. `src/input/command_dispatch.zig` (pure)

Splits the *decision* from the *execution* in `handleConfiguredKeybindAction`.

- `Phase = enum { early, late }` (moved/mirrored from `input.zig`'s
  `KeybindPhase`).
- `Command` — a tagged union describing the intent of each dispatched action,
  e.g.: `toggle_quake`, `toggle_command_palette`, `new_window`, `new_session`,
  `split_right`, `toggle_file_explorer`, `toggle_sidebar`, `close_panel_or_tab`,
  `toggle_maximize`, `font_size: i32` (±1), `copy`, `paste`, `paste_image`,
  `focus_split: keybind`-direction, `equalize_splits`, `next_tab`,
  `previous_tab`, `open_config`, `switch_tab: usize`.
- `resolve(action: keybind.Action, phase: Phase) ?Command` — **pure**, no globals,
  no side effects. Returns the command for that action in that phase, or `null`
  if the action is not handled in that phase. Absorbs `switchTabActionIndex`
  (pure `Action → ?usize`, surfaced as `Command.switch_tab`).

`input.zig` retains an `executeCommand(cmd: Command) bool` that performs the
side effects — including the "performable" actions (`focus_*`, `switch_tab`)
whose *consumed* result depends on runtime state (does a split/tab exist), which
is intentionally NOT pure. `handleConfiguredKeybindAction` becomes:

```zig
fn handleConfiguredKeybindAction(action: keybind.Action, phase: KeybindPhase) bool {
    const cmd = command_dispatch.resolve(action, mapPhase(phase)) orelse return false;
    return executeCommand(cmd);
}
```

**Behavior invariant:** the `commitTabRenameIfActive()` calls currently sprinkled
through the `.early` arm are preserved — either folded into `executeCommand`'s
early-command prologue or kept as the executor's responsibility, so the observed
behavior is byte-identical.

**Tests:** every `keybind.Action` resolves to the expected `Command` in the
correct phase; actions handled only in `.early` return `null` in `.late` and
vice-versa; `switch_tab_1..9` → `Command.switch_tab` with index 0..8; unhandled
actions → `null` in both phases.

### 2. `src/input/hit_test.zig` (pure)

Pure geometry: a layout descriptor + coordinates → a hit target. No `tab.g_*` or
`titlebar.*()` reads inside the module.

- Descriptor structs, e.g.
  `SidebarLayout{ visible: bool, width: f64, header_h: f64, row_h: f64, titlebar_h: f64, tab_count: usize }`.
- Functions (pure): `sidebarTabAt(layout, x, y) ?usize`,
  `sidebarPlusButton(layout, x, y) bool`,
  `sidebarTabCloseButton(layout, x, y, tab_idx) bool`,
  `sidebarTabIndexForDragY(layout, y) ?usize`, plus the panel **resize-handle**
  and **width-from-mouse** math and the **scrollbar target** geometry — all of
  which are pure arithmetic over current global state today.
- `input.zig` keeps thin wrappers (same signatures as today) that read the
  globals into a descriptor and call the pure function, so external callers are
  untouched.

**Scope control:** B1 extracts the sidebar family + panel resize-handle/
width-from-mouse math + scrollbar target geometry. Hit-tests that are thin
delegations into other modules' own state (e.g. file-explorer/markdown internal
hit-testing) stay as-is — only their pure arithmetic, if any, moves.

**Tests:** boundary cases per region — just inside/outside each edge, `y` above
the list top, empty tab list, index past `tab_count` clamped, single-tab
close-button suppression, resize-handle hit band, scrollbar thumb vs. track.

### 3. `src/input/click_tracker.zig` (pure)

- `ClickTracker = struct { count: u8 = 0, time_ms: i64 = 0, x: f64 = 0, y: f64 = 0 }`
  with `register(self: *ClickTracker, x: f64, y: f64, now_ms: i64, max_distance: f64, interval_ms: i64) u8`
  reproducing `nextLeftClickCount` exactly (reset when outside interval OR
  distance; increment; wrap >4 → 1; update last position/time; return count).
- `input.zig` holds one global `var g_left_click_tracker: ClickTracker = .{}`;
  `nextLeftClickCount(x, y)` computes `max_distance` from `font.cell_*` and the
  `MULTI_CLICK_INTERVAL_MS` constant, then delegates.

**Tests:** first click → 1; fast + near → 2, 3, 4; fifth fast+near → wraps to 1;
slow (beyond interval) → reset to 1; far (beyond distance) → reset to 1.

## B4 — tests & regression-lock

- Unit tests live inside each new module as std-only `test` blocks (runnable via
  `zig test src/input/<mod>.zig` and through `zig build test`).
- Each module is added to the `comptime { _ = @import(...); }` block in
  `src/test_main.zig` so a regression fails `zig build test`.
- The existing integration tests already in `input.zig`
  (`"input: Ctrl+Shift+P toggles command center"`, the macOS sidebar smoke test)
  stay and must remain green — they exercise `handleKey` → `handleConfiguredKeybindAction`,
  which now routes through `command_dispatch.resolve` + `executeCommand`.

## Out of scope

- No struct-ification of the global state.
- No change to selection logic beyond what already lives in `selection_unit.zig`.
- Drag *state machines* keep their globals in `input.zig`; only their pure
  geometry (e.g. `sidebarTabIndexForDragY`, the drag-threshold distance check)
  moves to `hit_test.zig`.
- No renderer/platform changes; `input.zig`'s public API to other modules is
  unchanged.

## Verification

- `zig build test` (native here — the canonical loop).
- `zig build test-full -Dtarget=x86_64-windows-gnu` — keep the memory baseline
  (497/499; 1 known Windows-API failure + 1 skip).
- `zig build test-full -Dtarget=aarch64-macos` — keep macOS green.

## Risks & mitigations

- **Behavior drift in dispatch.** Mitigated by keeping `executeCommand` a literal
  move of today's side-effect bodies, the `resolve` mapping exhaustively covering
  the same `keybind.Action` arms, and the existing integration tests guarding the
  end-to-end path.
- **Hidden global reads in "pure" candidates.** Mitigated by passing every input
  as an explicit descriptor parameter; the module compiles std-only, so any stray
  global reference fails to build.

## Ghostty reference

`input/` + `Binding.zig` are separate from apprt input handling — the same
decision-vs-execution split this design applies.
