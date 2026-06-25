# UI State Debt Reduction - Design

Date: 2026-06-24
Status: Approved direction; pending spec review

## Problem

The desktop UI layer has crossed the point where continued feature work is
making the core harder to change:

- `src/AppWindow.zig` is 10521 lines and still declares itself a thin wrapper
  around module-level globals.
- `src/renderer/overlays.zig` is 7695 lines and mixes overlay state, layout,
  rendering, input helpers, toasts, settings, launchers, and modal flows.
- `src/input.zig` is 7009 lines and contains many direct writes to
  `AppWindow.g_force_rebuild` and `AppWindow.g_cells_valid`.
- Several UI state groups are `threadlocal` or `g_*` globals, so the code is
  hard to test in isolation and remains structurally hostile to future
  multi-window support.

The most fragile behavior is UI invalidation. Overlay and panel handlers that
change UI state must manually set:

```zig
AppWindow.g_force_rebuild = true;
AppWindow.g_cells_valid = false;
```

If a handler forgets this, keyboard navigation visibly waits for the next
incidental wake. The existing tests in `src/input.zig` already encode this as a
regression risk, but the responsibility is still spread across call sites.

## Ghostty comparison

Ghostty is not split into a single `AppWindow`-style host file. Its structure
keeps major responsibilities behind clearer state owners:

- `src/Surface.zig` owns per-surface state such as renderer, renderer state,
  renderer thread, mouse state, keyboard state, derived config, and terminal IO.
  Its comments describe a terminal surface as a widget driven by the runtime.
- Ghostty has an explicit `InputEffect` enum on `Surface`, allowing callers to
  reason about input outcomes instead of inferring them from scattered globals.
- Renderer state is split across files such as `src/renderer/State.zig`,
  `src/renderer/Thread.zig`, `src/renderer/Overlay.zig`, and backend files.
- Input is split by concern under `src/input/`, including binding, command,
  key, mouse, paste, and encoding modules.

WispTerm should follow the same architectural direction: instance-owned state,
explicit input effects, and renderer/overlay state split by responsibility.
This design does not try to clone Ghostty's exact file names, because WispTerm
has project-specific panels, AI surfaces, and remote-console features, but the
state ownership and effect-return pattern should match the Ghostty approach.

## Goals

1. Replace hand-maintained overlay invalidation with a single explicit
   `UiEffect` path.
2. Establish one overlay split pattern that separates model state, input, and
   rendering.
3. Create explicit state structs as migration targets for existing `g_*` and
   `threadlocal` fields.
4. Keep each step behavior-preserving and testable.
5. Prevent new feature work from adding fresh global UI state to
   `AppWindow.zig`.
6. Use the P1 seam to make P2 file-size reduction mechanical instead of risky.

## Non-goals

- No one-shot rewrite of every global into instance state.
- No behavior changes to keyboard shortcuts, command palette behavior, settings
  behavior, terminal rendering, or panel semantics.
- No remote web-console refactor. Work under `remote/` is out of scope.
- No broad `ai_chat.zig` split in this effort except for UI-facing
  `AgentPanelState` boundaries needed by `AppWindow`/overlay state ownership.

## Recommended approach

Use a two-stage hard target.

P1 introduces the invalidation seam and proves a split pattern on one overlay.
P2 uses that seam to migrate state groups and reduce file sizes.

This is safer than immediately moving thousands of lines because it removes the
bug-prone cross-module contract first. Once handlers return effects, moving
state and handlers between files does not require every caller to remember
which globals to dirty.

## P1: explicit UI effects and one overlay sample

### New `UiEffect` type

Create `src/appwindow/ui_effect.zig` as a small leaf module:

```zig
pub const UiEffect = struct {
    consumed: bool = false,
    needs_rebuild: bool = false,
    cells_invalid: bool = false,
    wake_backend: bool = false,

    pub const none: UiEffect = .{};
    pub const consumed_only: UiEffect = .{ .consumed = true };
    pub const repaint: UiEffect = .{
        .consumed = true,
        .needs_rebuild = true,
        .cells_invalid = true,
    };

    pub fn merge(self: UiEffect, other: UiEffect) UiEffect {
        return .{
            .consumed = self.consumed or other.consumed,
            .needs_rebuild = self.needs_rebuild or other.needs_rebuild,
            .cells_invalid = self.cells_invalid or other.cells_invalid,
            .wake_backend = self.wake_backend or other.wake_backend,
        };
    }
};
```

`cells_invalid` defaults to false so future overlay-only paint paths can request
a frame without forcing terminal cell rebuild. Existing overlay navigation
should use `.repaint` to preserve today's behavior.

### Central application point

Add an `AppWindow.applyUiEffect(effect: UiEffect)` helper. It is the only place
that maps an input effect to the legacy globals during P1:

```zig
pub fn applyUiEffect(effect: ui_effect.UiEffect) void {
    if (effect.needs_rebuild) g_force_rebuild = true;
    if (effect.cells_invalid) g_cells_valid = false;
    if (effect.wake_backend) window_backend.postWakeup();
}
```

Keep `markUiDirty()` as an internal compatibility wrapper during P1, but
implement it through `applyUiEffect(.repaint)`. That makes old paths and new
paths agree.

### Input dispatch shape

`src/input.zig` keeps its current public `handleKey` and `handleChar` entry
points for platform callers. Internally, introduce:

```zig
fn dispatchKey(ev: platform_input.KeyEvent) ui_effect.UiEffect
fn dispatchChar(ev: platform_input.CharEvent) ui_effect.UiEffect
```

`handleKey` becomes:

```zig
pub fn handleKey(ev: platform_input.KeyEvent) void {
    AppWindow.applyUiEffect(dispatchKey(ev));
}
```

P1 does not need to convert every branch. Convert overlay and panel branches
first, because those are the paths covered by the AGENTS.md hard rule. Terminal
write paths can remain legacy until P2 unless touched by the converted overlay
flow.

### Overlay handler return values

Start with command palette because it already has focused repaint regression
tests and acts as the command-center parent for several child overlays.

Create a focused module such as:

- `src/renderer/overlays/command_palette_state.zig`
- `src/renderer/overlays/command_palette_input.zig`
- `src/renderer/overlays/command_palette_render.zig` only if rendering can be
  moved without pulling too much shared drawing code in P1

The P1 minimum is state + input extraction. Rendering may stay in
`overlays.zig` temporarily if moving it would require a larger shared renderer
context than the step can safely validate.

Command palette input handlers should return `UiEffect`:

```zig
pub fn handleKey(state: *State, ev: input_key.KeyEvent) ui_effect.UiEffect
pub fn handleChar(state: *State, cp: u21) ui_effect.UiEffect
```

Rules:

- Mutating selection, filter text, mode, visibility, or child overlay routing
  returns `.repaint`.
- Ignored keys return `.none`.
- Consumed no-op keys return `.consumed_only` only when the current behavior
  intentionally swallows the key without repaint.

### Tests for P1

Add fast unit tests for `UiEffect.merge`.

Update existing full-app input tests so they verify behavior through the new
dispatch seam where possible:

- command palette arrow navigation returns an effect that requests rebuild and
  invalidates cells
- command palette text filtering returns the same repaint effect
- session launcher/settings/other overlay branches still trigger repaint when
  routed through `handleKey` or `handleChar`
- render-gate regression still proves overlay navigation makes
  `frameNeedsRender` true

Because `input.zig` is not in `zig build test`, P1 verification must include
`zig build test-full`. Any new pure leaf modules should be listed in
`src/test_fast.zig`.

## P2: state migration and file-size reduction

P2 uses the P1 effect seam to move state without changing behavior.

### Target state structs

Introduce explicit state structs under `src/appwindow/` and
`src/renderer/overlays/`:

- `WindowState`: terminal dimensions, focus state, dirty flags, resize
  coalescing, cursor blink, config-derived UI settings, window handle pointer.
- `OverlayState`: command palette, session launcher, settings page, toasts,
  update prompts, close confirmations, whats-new/integration prompts.
- `InputState`: mouse drag state, preview image drag, last click tracking,
  hover/selection input state, URL open mode state.
- `RemoteState`: remote layout timing, remote AI input sinks, transfer
  notification sequence.
- `AgentPanelState`: AI panel/sidebar UI-only state currently hosted by
  `AppWindow` or overlay globals.

During migration, keep module-level compatibility accessors where callers are
not yet converted. The target is to make those wrappers thin and temporary, not
to move globals into different files permanently.

### Overlay decomposition order

After command palette proves the pattern, split overlays in this order:

1. Settings page: clear state, clear input handlers, clear config side effects.
2. Toast/update prompt/confirmation overlays: small state, good candidates for
   pure model tests.
3. Session launcher and SSH/AI profile forms: larger, but mostly modal state.
4. File explorer overlay: depends on `file_explorer.zig`, so split after the
   smaller overlays prove shared layout/render helpers.
5. AI overlay/panels: split last because they have the broadest dependencies.

Each overlay module should expose:

```zig
pub const State = struct { ... };
pub fn open(state: *State) ui_effect.UiEffect
pub fn close(state: *State) ui_effect.UiEffect
pub fn handleKey(state: *State, ev: input_key.KeyEvent) ui_effect.UiEffect
pub fn handleChar(state: *State, cp: u21) ui_effect.UiEffect
pub fn render(ctx: RenderContext, state: *const State) void
```

`RenderContext` should carry renderer dependencies explicitly instead of every
module reaching through `AppWindow.g_theme`, `AppWindow.g_allocator`, and
global font/UI helpers. This can start as a small struct and grow only when a
module actually needs a field.

### AppWindow file-size target

The long-term target is `src/AppWindow.zig` below 4000 lines. P2 should make
progress in slices rather than one enormous move:

- Move session restore/history store glue into `src/appwindow/session_restore.zig`
  or a similar existing ownership module.
- Move render-loop diagnostics/frame-latency glue into a focused
  `src/appwindow/render_loop.zig` or extend the existing
  `appwindow/frame_latency.zig` and `appwindow/render_gate.zig` boundaries.
- Move remote-control/Weixin-control glue into feature-owned modules.
- Move panel tick/update helpers to the panel modules that own those states.

No new feature may add module-level UI state to `AppWindow.zig`. New state must
be introduced in one of the explicit state structs or in a feature-owned module
with a migration note if a temporary compatibility wrapper is needed.

## Testing and verification

Every implementation task should follow TDD:

1. Write a failing test for the new effect/state behavior.
2. Run the smallest command that demonstrates the failure.
3. Implement the minimum behavior.
4. Run the targeted test.
5. Run the relevant suite.

Expected verification commands:

```bash
zig build test
zig build test-full
```

When input responsiveness is part of the change, also use the frame-latency
probe described in `AGENTS.md` and verify overlay navigation does not produce a
navigation-key `STALL`.

For file additions, removals, or renames, run the Windows checkout-safety checks
from `docs/development.md#windows-checkout-safety` before finishing.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| `UiEffect` becomes another wrapper around old globals | P1 requires overlay handlers to return effects, and `applyUiEffect` is the only legacy mapping point. |
| File splitting moves globals without improving ownership | P2 requires state structs and compatibility wrappers, not free-floating replacement globals. |
| Command palette extraction pulls too much renderer code | P1 allows rendering to remain in `overlays.zig`; only state/input extraction is mandatory. |
| Behavior drift in overlay routing | Keep existing `input.zig` regression tests, add effect-return tests, and run `test-full`. |
| Multi-window work remains blocked | P1/P2 do not claim full multi-window support, but they replace globals with instance-shaped state owners so later multi-window work has a path. |
| Ghostty divergence | Keep the direction aligned with Ghostty's explicit input effects and state-owned surface model; document any WispTerm-specific deviation in the implementation plan. |

## Success criteria

P1 is complete when:

- `src/appwindow/ui_effect.zig` exists and is in the fast test suite.
- `AppWindow.applyUiEffect` is the central bridge from `UiEffect` to legacy
  dirty globals.
- Command palette state/input has a focused module boundary and returns
  `UiEffect`.
- Overlay/panel input branches converted in P1 no longer write
  `g_force_rebuild`/`g_cells_valid` directly.
- Existing overlay repaint regression tests pass under `zig build test-full`.

P2 is complete when:

- `AppWindow.zig` is below 4000 lines.
- `renderer/overlays.zig` no longer owns command palette, settings, toast,
  split resize, file explorer overlay, and AI overlay state in one file.
- New UI feature state lands in explicit state structs or feature-owned modules,
  not as fresh `AppWindow.zig` globals.
- `zig build test` and `zig build test-full` pass.

## P1 handoff

P1 introduced `UiEffect`, `AppWindow.applyUiEffect`, and the command-palette
input-effect sample. P2 should split settings/toasts/session launcher next,
then migrate state into `WindowState`, `OverlayState`, and `InputState`.
