# UI State Debt P2.1 - Overlay State Split Design

Date: 2026-06-24
Status: Approved P2.1 direction

## Context

P1 introduced the invalidation seam:

- `src/appwindow/ui_effect.zig` defines `UiEffect`.
- `AppWindow.applyUiEffect()` maps `UiEffect` to the legacy dirty globals.
- Command palette key/char input now returns `UiEffect`.
- A fast source guard prevents the converted command-palette key/char branches
  from reintroducing direct dirty flag writes.

P2 uses that seam to reduce state/global debt. The full P2 target remains:

- `src/AppWindow.zig` below 4000 lines.
- `src/renderer/overlays.zig` split by overlay ownership.
- New UI feature state in explicit state structs or feature-owned modules.

The current baseline after P1 is still large:

- `src/AppWindow.zig`: 10578 lines.
- `src/renderer/overlays.zig`: 7695 lines.
- `src/input.zig`: 7070 lines.
- `src/ai_chat.zig`: 8756 lines.

P2.1 is the first P2 slice. It should not attempt the final AppWindow line
target. Its job is to establish a repeatable `OverlayState` pattern on smaller
overlays before the larger session launcher and AppWindow migrations.

## P2 Stage Record

### P2.1: OverlayState + small overlays

P2.1 owns the current work:

- Introduce `OverlayState` under `src/renderer/overlays/`.
- Move settings page state/input into a focused module.
- Move toast/update prompt state into a focused module.
- Move close/restore/transfer confirmation state into a focused module.
- Keep `src/renderer/overlays.zig` as the compatibility facade for callers.
- Expand the `UiEffect` path for settings and confirmation key handlers where
  the change is small and behavior-preserving.
- Add fast source guards so new overlay state does not regress into fresh
  `overlays.zig` globals.

P2.1 is complete before P2.2 starts.

### P2.2: Session launcher and profile forms

P2.2 starts only after P2.1 is merged or explicitly accepted. It should split:

- Session launcher state and input.
- SSH profile list/form state.
- AI profile list/form state.
- AI history source picker state.
- Switch-model target state.

These are larger modal flows and should reuse the P2.1 state-module pattern.

### P2.3: AppWindow state migration

P2.3 starts only after P2.2 is complete. It should introduce and wire:

- `WindowState`: terminal dimensions, dirty flags, focus, cursor blink, resize
  coalescing, window handle, UI config flags.
- `InputState`: mouse drag state, hover/click/selection state, preview image
  drag, input suppression state.
- `RemoteState`: remote layout timing, AI input sinks, transfer notification
  sequence.

P2.3 is where `src/AppWindow.zig` should make major progress toward the
4000-line target.

## Ghostty Reference

Ghostty keeps terminal UI ownership split across explicit state holders:

- `src/Surface.zig` owns a terminal surface, its renderer, renderer state,
  renderer thread, mouse state, keyboard state, focus state, and derived config.
- `src/renderer/State.zig` is the data renderers need, with a mutex contract.
- `src/renderer/Overlay.zig` is a focused overlay implementation, not a global
  catch-all for every app modal.
- `src/input/` is split by input concepts such as key events, mouse events,
  bindings, paste, and encoding.

P2.1 follows this direction by making overlay state explicit and feature-owned.
WispTerm's `overlays.zig` remains as a facade during migration because many
callers still import it through `AppWindow.overlays`.

## P2.1 Goals

1. Introduce `OverlayState` as the owner for the first migrated overlay groups.
2. Remove settings/toast/confirmation state globals from `overlays.zig`.
3. Keep public overlay function names stable during P2.1.
4. Convert settings and simple confirmation key handlers to return `UiEffect`
   through the compatibility facade.
5. Put new pure state behavior in `zig build test`.
6. Treat `zig build test-full` as a 5-10 minute stage gate, not a per-task gate.

## P2.1 Non-goals

- Do not split session launcher, SSH forms, AI profile forms, file explorer
  overlay, or AI panels in P2.1.
- Do not attempt to reduce `AppWindow.zig` below 4000 lines in P2.1.
- Do not remove `overlays.zig` as the caller-facing facade.
- Do not change keyboard shortcuts, settings behavior, toast timing, confirm
  modal behavior, or update prompt behavior.
- Do not touch `remote/`.

## Target Modules

### `src/renderer/overlays/settings_page.zig`

Owns settings page state and input decisions:

- visibility
- focused row
- config cache dirty flag
- config cache lifetime
- row capacity and first-visible-row math
- key-to-action mapping

It does not execute config writes directly. It returns a `settings_page.Action`
for `overlays.zig` to execute through existing project services such as
`Config.setConfigValue()` and `AppWindow.reloadConfigImmediate()`.

### `src/renderer/overlays/toasts.zig`

Owns transient toast/update prompt state:

- copy/status toast message buffer, length, and expiration
- transfer toast buffer, status, sticky/clickable flags, and expiration
- update prompt buffer, URL buffer, clickable flag, action, and expiration
- close-shortcut confirm expiration

Formatting and hit-test logic should be unit-tested in the fast suite. Rendering
may stay in `overlays.zig` during P2.1 if moving it would require a large render
context; state must move out of `overlays.zig`.

### `src/renderer/overlays/confirm_modals.zig`

Owns modal confirmation state:

- window close confirmation visibility
- pending close action and variant
- restore-defaults confirmation visibility
- transfer-cancel confirmation visibility

The module should return small action values. `overlays.zig` keeps side effects
that touch `AppWindow`, config files, or file transfer cancellation.

### `src/renderer/overlays/state.zig`

Aggregates the migrated state:

```zig
pub const OverlayState = struct {
    settings: settings_page.State = .{},
    toasts: toasts.State = .{},
    confirms: confirm_modals.State = .{},

    pub fn deinit(self: *OverlayState, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
    }
};
```

`overlays.zig` owns one threadlocal compatibility instance during P2.1:

```zig
threadlocal var g_overlay_state: overlay_state.OverlayState = .{};
```

Future P2.3 work can move this field into a true window-owned state object.

## Compatibility Strategy

P2.1 keeps the caller-facing API stable:

- `overlays.settingsPageOpen()`
- `overlays.settingsPageClose()`
- `overlays.settingsPageVisible()`
- `overlays.showStatusToast()`
- `overlays.showTransferToast()`
- `overlays.windowCloseConfirmHandleKey()`
- `overlays.transferCancelConfirmHandleKey()`

Internally these wrappers delegate to the new state modules. This avoids a
repo-wide import churn while still removing the state globals from the large
facade.

When a wrapper is touched by keyboard input, it should return `UiEffect` if the
signature can be changed without broad fallout. `input.zig` should then return
that effect from `dispatchKey()` instead of manually setting dirty globals.

## Verification Strategy

`zig build test-full` takes 5-10 minutes, so P2.1 uses a two-tier verification
policy:

- Every leaf state module gets fast tests in `zig build test`.
- Static source guards that do not need the full app binary go into
  `zig build test`.
- Wiring tasks run `zig build test` and receive code review.
- `zig build test-full` runs once at the P2.1 stage gate, or earlier only when a
  full-app integration risk justifies the time.

P2.1 also runs Windows checkout-safety checks because it adds files.

## P2.1 Success Criteria

P2.1 is complete when:

- `settings_page.zig`, `toasts.zig`, `confirm_modals.zig`, and `state.zig`
  exist and compile.
- Settings, toast/update prompt, and confirmation state no longer live as
  `g_settings_*`, `g_copy_toast_*`, `g_transfer_toast_*`,
  `g_update_prompt_*`, `g_window_close_confirm_*`,
  `g_restore_defaults_confirm_*`, or `g_transfer_cancel_confirm_*` globals in
  `overlays.zig`.
- `overlays.zig` remains the compatibility facade for existing callers.
- Converted settings and confirmation key branches use `UiEffect` instead of
  direct input-side dirty flag writes.
- New state modules and source guards are covered by `zig build test`.
- `zig build test-full` passes at the P2.1 stage gate.

## Risks

| Risk | Mitigation |
|---|---|
| State modules become another global bucket | Keep feature-owned modules and expose narrow state methods. |
| Moving settings rendering creates dependency cycles | Move state/input first; rendering can stay in facade unless the render context is small. |
| Behavior drift in config writes | Keep settings side effects in `overlays.zig` initially and reuse existing tests. |
| `test-full` slows iteration | Fast tests and source guards run per task; full suite runs once at the stage gate. |
| P2.2 starts before P2.1 stabilizes | Treat P2.2/P2.3 as recorded future stages, not executable P2.1 tasks. |
