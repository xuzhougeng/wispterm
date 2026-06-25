# UI State Debt P3.2 - Input Host and Effect Boundary Design

Status: Approved for implementation

## Context

P3.1/P3.1b reduced `src/AppWindow.zig` to 7,091 lines and extracted several AppWindow integration boundaries into focused `src/appwindow/` modules. The next highest-leverage coupling point is `src/input.zig`.

Current local measurements before P3.2:

- `src/input.zig`: 7,101 lines.
- `src/input.zig`: roughly 869 direct `AppWindow.` references.
- `src/input.zig`: many direct writes to `AppWindow.g_force_rebuild` and `AppWindow.g_cells_valid`.
- Input still imports `AppWindow.zig` directly and aliases many AppWindow-owned modules and globals.
- `src/renderer/overlays.zig` and renderer files are still coupled to AppWindow, but input is the first priority because it is where UI invalidation, shortcuts, mouse state, and command dispatch converge.

The immediate technical debt is not only file size. It is that input handlers still know too much about AppWindow global state and are responsible for manually dirtying UI state in many branches. That was the original fragile rule P1 started to address.

## Ghostty Reference

Ghostty uses explicit runtime boundaries for input-triggered behavior:

- `src/apprt/action.zig` defines `Target` and `Action`. Actions are one-way runtime requests such as `new_tab`, `new_split`, `toggle_command_palette`, and `render`.
- `src/apprt/surface.zig` defines surface `Message` and `Mailbox`. Surface requests such as clipboard, rendering, selection scroll, title/pwd updates, and presentation are routed through message boundaries.
- `src/apprt/gtk/class/surface.zig` handles platform input events, normalizes key/mouse details, and invokes core surface callbacks or runtime actions rather than directly mutating arbitrary application globals.

P3.2 should not attempt to copy Ghostty's full runtime architecture. The near-term WispTerm equivalent is a narrower input host/effect seam: input can continue to call existing behavior, but UI invalidation and AppWindow-owned capabilities should be funneled through a single host boundary.

## Goal

Make `src/input.zig` less coupled to AppWindow by introducing an input host/effect boundary that centralizes UI invalidation and AppWindow-owned operations, without changing keyboard shortcut behavior or user-visible UI behavior.

P3.2 is successful when:

- Input event paths use a single effect/apply boundary for rebuild/cell invalidation instead of scattering manual `AppWindow.g_force_rebuild = true; AppWindow.g_cells_valid = false;` writes through business branches.
- Overlay and panel key/char mutation paths return or merge `UiEffect.repaint` instead of requiring each branch to remember dirty flags.
- A guard prevents new direct dirty-flag writes from being added in input business logic.
- Existing shortcut behavior remains unchanged.
- Existing P3.1 guards and tests continue to pass.

## Non-Goals

- Do not change keyboard shortcuts or their user-visible text.
- Do not update `README.md` shortcut docs because no shortcut behavior changes are planned.
- Do not split all of `input.zig` in one pass.
- Do not refactor renderer AppWindow imports in P3.2.
- Do not move mouse selection internals unless needed for the input effect seam.
- Do not change terminal mouse reporting, clipboard behavior, AI chat behavior, Skill Center behavior, file explorer behavior, or panel layout behavior.
- Do not touch `remote/`, version files, release notes, packaging, or PTY internals.

## Architecture

### 1. Input Effects Stay Small

Keep using `src/appwindow/ui_effect.zig` as the shared effect type:

- `consumed`
- `needs_rebuild`
- `cells_invalid`
- `wake_backend`

P3.2 should extend usage, not invent a parallel effect type. If input needs a convenience helper, add it near the input boundary or as a small method on `UiEffect`.

### 2. Add An Input Host Boundary

Introduce a small host interface owned by input, likely in `src/input/host.zig` or `src/input/effects.zig`.

The host should represent capabilities input needs from AppWindow without importing the whole AppWindow module into every extracted helper. The first iteration can be intentionally conservative:

- `markUiDirty` or `applyEffect`
- access to allocator/window where existing input paths require it
- narrow callbacks for high-level AppWindow operations that cannot move yet

The host is not meant to model every AppWindow operation in P3.2. It is a seam that lets later tasks peel input helpers away without expanding direct global coupling.

### 3. Convert Dirtying Paths First

P3.2 should prioritize direct dirty flag writes:

```zig
AppWindow.g_force_rebuild = true;
AppWindow.g_cells_valid = false;
```

The desired pattern is:

```zig
return ui_effect.UiEffect.repaint;
```

or, for handlers that already perform side effects and cannot return early:

```zig
effect = effect.merge(ui_effect.UiEffect.repaint);
```

Only one boundary should apply the effect to AppWindow globals:

```zig
AppWindow.applyUiEffect(effect);
```

### 4. Keep Public Entry Points Stable

Keep existing externally used input entry points:

- `processEvents`
- `handleKey`/`dispatchKey`
- `handleChar`/`dispatchChar`
- mouse handlers and exported helpers used by AppWindow/renderer/tests

Where signatures must remain `void`, build and apply an effect internally. Where signatures already return `UiEffect`, preserve that direction and expand it.

### 5. Guard Against Regression

Add a source guard for input invalidation debt. The guard should not ban the final apply boundary, tests, or compatibility helpers. It should fail when direct dirty-flag writes reappear inside normal input business branches.

The guard can be conservative in P3.2:

- allow `AppWindow.applyUiEffect`
- allow test setup/restoration references to `AppWindow.g_force_rebuild` and `AppWindow.g_cells_valid`
- allow exactly named internal helper(s), such as `applyInputEffect`, if needed
- ban scattered `AppWindow.g_force_rebuild = true` / `AppWindow.g_cells_valid = false` writes outside approved sections

## Proposed P3.2 Scope

P3.2 should be implemented in two or three focused slices:

1. **Effect application seam**
   - Add input-local helper/host for applying `UiEffect`.
   - Convert obvious repaint sites in key/char overlay branches.
   - Keep behavior unchanged.

2. **Overlay/panel key-char paths**
   - Convert command palette, session launcher, settings, port forwarding, Skill Center, AI chat, AI history, file explorer keyboard paths where they mutate UI state.
   - Preserve existing tests that assert repaint behavior.

3. **Mouse/panel dirtying paths**
   - Convert mouse wheel, drag, resize, hover, selection, and panel mouse paths where practical.
   - Leave complex selection/reporting internals in place if moving them would risk behavior.

If P3.2 becomes too large after slice 2, stop and write P3.3 for the remaining mouse-heavy paths. The priority is reducing fragile manual invalidation in the highest-risk keyboard/overlay paths first.

## Testing Strategy

Per slice:

- Run `zig build test`.
- Keep or extend existing input repaint tests.
- Add focused guard tests to the fast suite when possible.
- Do not run `test-full` after every small slice.

Final gate:

- `zig build test`
- `zig build test-full`
- Windows tracked-file checkout-safety if files are added/moved
- macOS E2E can be run by the user as an external final confidence check, as done after P3.1

## Acceptance Criteria

- `src/input.zig` remains behavior-compatible.
- `zig build test` passes after each implementation slice.
- `zig build test-full` passes at final gate.
- P3.1 boundary guards still pass.
- New input invalidation guard is added and passes.
- Direct AppWindow dirty-flag writes in input business logic are removed or reduced to an explicitly documented compatibility boundary.
- The design and final implementation document any remaining direct `AppWindow.` dependencies that are intentionally deferred.

## Risks

- `input.zig` handles keyboard, mouse, drag, selection, panels, browser, AI chat, file explorer, terminal mouse protocol, and shortcut dispatch. A broad split can easily change behavior.
- Mouse/selection paths have many subtle side effects and should not be refactored aggressively in the same slice as keyboard invalidation.
- Tests in `zig build test` cover many pure/logic paths, but not every live GUI interaction. `test-full` and macOS E2E remain important confidence gates.

## Recommended Next Step

Write a P3.2 implementation plan limited to the input host/effect seam. The first implementation task should create the host/effect boundary and guard, then convert a narrow keyboard/overlay slice before touching mouse-heavy paths.

## P3.2 Implementation Results

- `src/input.zig`: 7065 lines after P3.2.
- `src/input/effects.zig`: 70 lines.
- `src/input/dirty_guard.zig`: 47 lines.
- `src/input.zig` direct `AppWindow.` references: 819.
- `dispatchChar` and `dispatchKey` no longer contain direct `AppWindow.g_force_rebuild = true` or `AppWindow.g_cells_valid = false` writes.
- Remaining direct dirty-flag writes are intentionally deferred to non-dispatch mouse-heavy, pointer, hover, drag, selection, and non-key helper paths for P3.3.
- No keyboard shortcut behavior or user-visible shortcut text changed.
