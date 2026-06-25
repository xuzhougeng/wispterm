# UI State Debt P2.3 - AppWindow State Owner Design

Date: 2026-06-24
Status: Complete

## Context

P2.1 and P2.2 established the migration pattern on overlay state:

- Add a feature-owned state module with default-initialized `State`.
- Aggregate it under an owner (`OverlayState`).
- Keep the legacy facade stable while call sites migrate.
- Add fast unit tests and source guards so state does not flow back into the
  giant facade.

P2.3 starts applying that pattern to `src/AppWindow.zig`. This is intentionally
not a single rewrite of every `AppWindow` global. The first slice creates
explicit state owners, migrates the low-risk private state groups, and leaves
public variable surfaces such as `AppWindow.term_cols`, `AppWindow.term_rows`,
`AppWindow.g_force_rebuild`, and `AppWindow.g_cells_valid` for a follow-up
rename after more input branches return `UiEffect`.

Baseline after fast-forwarding to P2.2:

```text
  10578 src/AppWindow.zig
   7665 src/renderer/overlays.zig
   7100 src/input.zig
   8756 src/ai_chat.zig
  34099 total
```

Verification before planning:

- Branch: `feat/ui-state-debt`
- Head: `66b0723 docs: record ui state P2.2 handoff`
- `zig build test`: passes
- Worktree: no tracked modifications; an unrelated untracked `.claude/` skill
  directory exists and is left untouched.

## Current AppWindow State Inventory

`AppWindow.zig` still has several categories of module-level state.

| Category | Current globals | P2.3 decision |
|---|---|---|
| Process/app services | `g_app`, `g_agent_history`, `g_loop_store`, flush/history mutexes | Not a P2.3 target; process-wide lifetime and cross-window semantics need a separate design. |
| Startup/config mirrors | `g_initial_cwd_*`, requested font/shader/start flags, quake flags, `g_keybinds`, `g_theme`, `g_window`, `g_allocator`, `g_should_close` | Mostly public or startup lifecycle state; document in `WindowState` shape, but do not wire in this slice except where already accessor-owned. |
| Window/render state | `term_cols`, `term_rows`, dirty flags, focus, pending resize, immediate layout resize, present bring-up settled, cursor blink state | Introduce `WindowState`; wire pending resize, immediate layout resize, and present bring-up settled first. Leave public root grid, dirty flags, and cursor mirrors for later call-site migration. |
| UI config flags | focus-follows-mouse, copy-on-select, Copilot hint/shimmer, right-click action, SSH legacy algorithms, notifications, close confirmation, WeChat notify forwarding | Model in `WindowState`; leave wiring for a later slice because these are read from input, renderer, notification, and overlay paths. |
| Remote UI state | `g_remote_layout_last_ms`, `g_remote_ai_sinks`, `g_last_transfer_notification_seq` | Migrate fully to `RemoteState`; these are private to `AppWindow.zig` and have narrow behavior. |
| Diagnostics/IME | frame-latency stats, loop counter, config debounce, resize throttle, IME caret tracker, GL diagnostic snapshots | Not P2.3 except `present_bringup_settled`. These already have focused helper modules or narrow instrumentation semantics. |
| WeChat/control caches | WeChat UI handle, transcript cache, ctl panes/UI-state JSON caches | Not P2.3; cross-thread ownership and atomics need a separate plan. |

`src/input.zig` already owns many input-specific globals (selection, divider
drag, preview-image drag, panel-swap drag, scrollbar drag, AI transcript
selection, command-char suppression). P2.3 does not move those into
`AppWindow.zig`; a later InputState slice should be under `src/input/`, not under
`src/AppWindow.zig`.

## Ghostty Reference

AGENTS.md requires planning against Ghostty. I checked Ghostty `main` with
`gh api`:

- `src/Surface.zig` owns a terminal surface with explicit fields for
  `renderer`, `renderer_state`, `renderer_thread`, `mouse: Mouse`,
  `keyboard: Keyboard`, `size`, `config`, and `focused`. Its nested `Mouse`
  state carries click/mod/link state; `Keyboard` carries active key-sequence
  state. The key point is explicit ownership on the surface object, not loose
  module globals.
- `src/renderer/State.zig` is a focused renderer state object protected by a
  mutex. It contains only the data renderers need (`terminal`, `inspector`,
  `preedit`, renderer-facing mouse state), and documents the lock contract.
- `src/renderer/Thread.zig` owns renderer-thread scheduling (`wakeup`, timers,
  mailbox, visible/focused flags) separately from the surface and renderer state.
- `src/input/` is split by concept: `mouse.zig`, `keyboard.zig`, `Binding.zig`,
  `command.zig`, `key_encode.zig`, `paste.zig`, etc.

P2.3 follows this direction by introducing explicit WispTerm owners:

- `WindowState` for window/render gate state.
- `RemoteState` for remote layout/input-sink bookkeeping.
- `AppWindowState` as the aggregate inside `AppWindow.zig`.

The WispTerm-specific constraint is compatibility: many modules still read
public `AppWindow` globals directly. P2.3 therefore uses a facade-and-guard
strategy rather than immediately breaking those public variable surfaces.

## Goals

1. Add `src/appwindow/window_state.zig`, `remote_state.zig`, and `state.zig`.
2. Fully migrate `g_remote_layout_last_ms`, `g_remote_ai_sinks`, and
   `g_last_transfer_notification_seq` into `RemoteState`.
3. Migrate low-risk window state into `WindowState`: pending resize,
   immediate-layout-resize flag, and D3D present bring-up settlement.
4. Keep existing public AppWindow APIs stable where they are still used by
   `input.zig`, renderers, overlays, or tests.
5. Add fast unit tests and source guards for every migrated state group.
6. Use `zig build test` as the inner loop and bare `zig build test-full` as the
   final Windows cross-compile gate. macOS native gates are out of scope for this
   P2.3 request.
7. Run Windows checkout-safety checks because P2.3 adds files.

## Non-goals

- Do not touch `remote/`.
- Do not change version files.
- Do not migrate `term_cols` / `term_rows` in this first AppWindow slice.
- Do not migrate `g_force_rebuild` / `g_cells_valid` in this slice; input and
  overlay callers still contain many direct writes, and converting those should
  be paired with more `UiEffect` branches.
- Do not migrate cursor blink public variables in this slice; renderers still
  read `AppWindow.g_cursor_blink_visible` / `g_cursor_blink`.
- Do not move process-wide agent history, loop store, WeChat, or ctl caches.
- Do not move input-owned mouse/drag state out of `src/input.zig`.

## Target Modules

### `src/appwindow/window_state.zig`

Pure state model for the window/render-gate state. It defines:

- root grid shape (`term_cols`, `term_rows`) for the eventual migration;
- dirty flags (`cells_valid`, `force_rebuild`) for the eventual migration;
- focus and cursor blink fields for the eventual migration;
- pending resize and immediate layout resize helpers for P2.3 wiring;
- present bring-up settlement helper for P2.3 wiring;
- UI config flags for later wiring.

P2.3 wires only:

- `pending_resize`, `pending_cols`, `pending_rows`, `last_resize_time`
- `layout_resize_immediate`
- `present_bringup_settled`

The module is fast-suite-safe and unit-tested without importing `AppWindow.zig`.

### `src/appwindow/remote_state.zig`

Pure state model for remote layout bookkeeping:

- `layout_last_ms`
- `ai_sinks: [32]AiInputSink`
- `last_transfer_notification_seq`

`AiInputSink` stores `native_handle_bits: usize` instead of
`window_backend.NativeHandle`, so the module stays fast-suite-safe. `AppWindow`
converts those bits back to a native handle at the callback boundary.

### `src/appwindow/state.zig`

Aggregate:

```zig
pub const State = struct {
    window: window_state.State = .{},
    remote: remote_state.State = .{},
};
```

`AppWindow.zig` owns one threadlocal aggregate:

```zig
threadlocal var g_appwindow_state: appwindow_state.State = .{};
```

Private accessors keep wiring local:

```zig
fn windowState() *appwindow_state.WindowState { return &g_appwindow_state.window; }
fn remoteState() *appwindow_state.RemoteState { return &g_appwindow_state.remote; }
```

### `src/appwindow/state_guard.zig`

Fast source guard that embeds `src/AppWindow.zig` and rejects the migrated raw
globals:

- `g_remote_layout_last_ms`
- `g_remote_ai_sinks`
- `g_last_transfer_notification_seq`
- `g_pending_resize`
- `g_pending_cols`
- `g_pending_rows`
- `g_last_resize_time`
- `g_layout_resize_immediate`
- `g_present_bringup_settled`

The guard deliberately does not reject `term_cols`, `term_rows`,
`g_force_rebuild`, `g_cells_valid`, cursor blink globals, or UI config globals in
P2.3 because those are compatibility surfaces for later slices.

## Compatibility Strategy

P2.3 keeps public call sites stable unless a narrow public function already
exists or can replace a private variable group cleanly:

- `requestImmediateLayoutResize()` and `consumeImmediateLayoutResize()` keep
  their names and delegate to `WindowState`.
- New `requestGridResize(cols, rows, now_ms)` replaces `input.zig` direct writes
  to pending resize internals.
- `term_cols` / `term_rows` stay public threadlocals in P2.3.
- `g_force_rebuild` / `g_cells_valid` stay public threadlocals in P2.3.
- Remote callback registration keeps the same remote surface IDs and callback
  behavior; only the sink storage changes.

This mirrors P2.1/P2.2: first establish a real owner and move the safest state,
then use source guards to keep that state from returning to the facade.

## Verification Strategy

Per task:

- Run `zig build test`.
- Commit one focused change.

Final gate:

- Run `zig build test`.
- Run bare `zig build test-full` for the Windows cross-compile/full app compile
  gate. The user explicitly said macOS does not need to be considered for this
  task.
- Run Windows checkout-safety checks from `docs/development.md`.
- Record final line counts and append a P2.3 handoff section.

## Success Criteria

P2.3 is complete when:

- New `WindowState`, `RemoteState`, aggregate, and guard modules exist and are in
  `zig build test`.
- Remote layout throttle, remote AI input sinks, and transfer notification
  sequence no longer live as raw `AppWindow.zig` globals.
- Pending resize, immediate layout resize, and present bring-up settlement no
  longer live as raw `AppWindow.zig` globals.
- `input.zig` queues pending grid resize through an `AppWindow` facade function
  instead of writing `g_pending_*` fields.
- AppWindow public dirty/grid/cursor globals are explicitly documented as
  compatibility surfaces for later migration.
- Fast tests, final Windows cross-compile gate, and checkout-safety checks pass.

## Risks

| Risk | Mitigation |
|---|---|
| Migrating public dirty flags too early would churn many input/overlay/render call sites | Leave `g_force_rebuild` / `g_cells_valid` for a later `UiEffect`-first slice. |
| `RemoteState` could pull platform/window types into the fast suite | Store native handle bits as `usize`; convert only in `AppWindow.zig`. |
| Pending resize behavior could drift from Ghostty-style coalescing | Unit-test `queueResize` / `consumeCoalescedResize`; keep `RESIZE_COALESCE_MS = 25` in `AppWindow.zig`. |
| Source guard false positives on intentionally retained state | Guard only migrated raw global names; document retained compatibility surfaces. |
| AppWindow line count may not drop much yet | P2.3 measures success by explicit ownership and globals removed. Line-count reduction comes from later extracting behavior after ownership is clear. |

## P2.3 handoff

P2.3 introduced `WindowState`, `RemoteState`, and an `AppWindowState`
aggregate under `src/appwindow/`. The new modules are imported by the fast
test suite, and `src/appwindow/state_guard.zig` embeds `src/AppWindow.zig` to
prevent the migrated raw global names from returning.

Remote layout throttle state, remote AI input sink storage, transfer
notification sequence dedupe, pending resize state, immediate layout resize
state, and D3D present bring-up settlement now live behind the
`AppWindowState` owner. `AppWindow.zig` remains the compatibility facade for
callers such as `src/input.zig`.

The intentionally retained public compatibility surfaces are `term_cols`,
`term_rows`, `g_force_rebuild`, `g_cells_valid`, cursor blink globals, and UI
config flags. These remain later-slice targets because existing input,
renderer, overlay, and notification call sites still read or write them
directly.

Verification:

```text
zig build test: PASS (exit 0)
  Existing warning-fixture stderr was emitted for invalid config values,
  malformed agent-access rules, an agent-access.local IsDir fixture, and a
  corrupt session.json fixture.

zig build test-full: PASS (exit 0)
  Windows cross-compile/full app compile gate completed. Existing test stderr
  included agent-access fixture warnings, shell command resolution logs,
  ConfigWatcher unsupported-backend logging, Weixin fixture logs, and the
  corrupt session.json fixture warning.

Windows checkout-safety equivalent:
  tracked_files=1542
  windows_name_violations=0
  casefold_collisions=0
  max_path_length=90 docs/superpowers/specs/2026-06-01-window-size-persistence-and-ai-form-onboarding-design.md
  tracked_symlinks=0
```

Final line counts:

```text
  10571 src/AppWindow.zig
   7665 src/renderer/overlays.zig
   7101 src/input.zig
   8756 src/ai_chat.zig
  34093 total
```
