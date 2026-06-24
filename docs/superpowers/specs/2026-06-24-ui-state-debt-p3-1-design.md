# UI State Debt P3.1 - AppWindow Integration Extraction Design

Status: Approved for implementation

## Context

P1 introduced the `UiEffect` seam. P2.1/P2.2/P2.3 then moved selected overlay
and AppWindow state into explicit state owners with source guards. That reduced
raw global-state debt, but it did not materially reduce `src/AppWindow.zig`:

```text
  10571 src/AppWindow.zig
   7665 src/renderer/overlays.zig
   7101 src/input.zig
   8756 src/ai_chat.zig
  34093 total
```

P3 changes the success metric from "state moved" to "behavior extracted." P3.1
is the first low-risk behavior extraction slice. It moves integration glue out
of `AppWindow.zig` while preserving the current runtime model and public
callers.

## Ghostty Comparison

Ghostty does not put all app/window behavior into one window file:

- `src/App.zig` owns app-level coordination, surface registration, mailbox
  draining, and config propagation.
- `src/apprt/action.zig` models runtime actions explicitly instead of scattering
  action glue through the window implementation.
- `src/apprt/surface.zig` defines surface message/mailbox contracts separately
  from app coordination.
- `src/renderer/Thread.zig` owns renderer-thread scheduling, wakeups, blink
  timers, and draw cadence outside the app runtime.

P3.1 follows that direction without attempting a full Ghostty runtime rewrite.
WispTerm will first split AppWindow integration adapters into focused modules,
then later P3 slices can tackle render-loop and tab/split ownership.

## Goals

1. Reduce `src/AppWindow.zig` from ~10,571 lines to under 8,000 lines, ideally
   near 7,000, by extracting behavior rather than moving state fields only.
2. Extract low-risk integration glue first:
   - WispTerm Remote layout/control glue.
   - Control API callbacks and surface snapshots.
   - Weixin bridge dispatch and vtable glue.
   - Agent request structs, post helpers, and UI-thread handlers.
3. Keep `AppWindow.zig` as the compatibility facade for existing callers.
4. Add source guards so extracted function groups do not drift back into
   `AppWindow.zig`.
5. Preserve behavior. This is a technical-debt refactor, not a feature change.

## Non-Goals

P3.1 does not:

- Extract or rewrite `runMainLoop`.
- Split the render gate, frame loop, GPU frame lifecycle, or resize frame
  rendering.
- Move tab/split core orchestration.
- Change overlay behavior or `input.zig` shortcut semantics.
- Change `remote/`, desktop version files, packaging, or release surfaces.
- Introduce a full Ghostty-style action/mailbox architecture.

Those are later P3 slices after the integration modules are stable.

## Proposed Modules

### `src/appwindow/remote_sync.zig`

Owns WispTerm Remote UI sync glue currently embedded in `AppWindow.zig`:

- remote layout throttle entry point;
- layout JSON construction;
- terminal, AI chat, and AI history tab serialization;
- remote AI input sink registration and write callback support;
- remote AI agent open callback support.

It should use P2.3 `RemoteState` for throttling, sink storage, and transfer
notification dedupe. `AppWindow.zig` keeps a small facade that supplies host
operations such as active tab lookup, remote client lookup, and surface spawn.

### `src/appwindow/control_api.zig`

Owns the `ctl` and agent-control callback glue:

- `list-panes`, `get-text`, `send-text`, and `ui-state` callbacks;
- cached panes/UI-state JSON helpers if they can be moved with the callbacks;
- active surface snapshot construction;
- agent tool surface lookup, snapshot, and write callbacks.

The module should communicate through a narrow host/context API rather than
importing and mutating unrelated AppWindow globals directly.

### `src/appwindow/weixin_bridge.zig`

Owns Weixin control integration:

- request struct and dispatch;
- AI/terminal surface lookup helpers;
- Weixin vtable functions;
- transcript cache helpers if they move cleanly with the vtable.

The behavior should remain unchanged: no protocol changes, no new Weixin
features, and no changes to visible message routing.

### `src/appwindow/agent_requests.zig`

Owns agent-triggered request plumbing:

- request structs for tab new/close, SSH connect, and SSH save;
- post helpers from worker callbacks to the UI thread;
- UI-thread request handlers where they can be expressed via a small host API.

`AppWindow.zig` should still expose the concrete operations that own tabs,
surfaces, SSH profile execution, and overlays. P3.1 does not move those core
operations.

## Host Boundary

Each extracted module should either:

- take a small `Host` struct of function pointers for app/window operations; or
- receive explicit values and callbacks from the `AppWindow.zig` facade.

Direct reads of existing AppWindow globals are acceptable only when the global is
already a compatibility surface and the module would otherwise become a pass-
through wrapper. New broad global accessors should be avoided.

The preferred shape is:

```zig
pub const Host = struct {
    allocator: std.mem.Allocator,
    activeTab: *const fn () ?*tab.TabState,
    activeSurface: *const fn () ?*Surface,
    markDirty: *const fn () void,
};
```

The exact host surface can be smaller or split per module. It should be driven
by the code being extracted, not designed as a universal AppWindow API.

## Verification Strategy

Per implementation task:

- Move one behavior group at a time.
- Keep the `AppWindow.zig` public/facade entry points stable.
- Run `zig build test`.
- Add or extend source guards for the extracted group.
- Commit one focused change.

P3.1 final gate:

- `zig build test`.
- `zig build test-full` once.
- Windows checkout-safety checks from `docs/development.md`.
- Record final line counts in a P3.1 handoff section.

`zig build test-full` remains expensive and should not be repeated inside every
task unless a specific integration compile failure needs confirmation.

## Source Guards

P3.1 should add guards under `src/appwindow/` and import them from
`src/test_fast.zig`.

The guards should assert that extracted markers no longer appear in
`src/AppWindow.zig`, for example:

- remote layout builder/helper names after `remote_sync.zig` owns them;
- `ctl` callback helper names after `control_api.zig` owns them;
- Weixin vtable/helper names after `weixin_bridge.zig` owns them;
- agent request struct/helper names after `agent_requests.zig` owns them.

The guards should avoid banning intentionally retained facade names.

## Success Criteria

P3.1 is complete when:

- `remote_sync.zig`, `control_api.zig`, `weixin_bridge.zig`, and
  `agent_requests.zig` exist or the implementation plan explicitly justifies
  merging two of them because their boundaries are inseparable.
- `AppWindow.zig` is below 8,000 lines.
- Extracted behavior is reachable through stable `AppWindow.zig` facades.
- Fast source guards prevent the extracted groups from returning.
- `zig build test` passes per task.
- The final `zig build test-full` gate passes once.
- Windows checkout-safety checks pass.
- A P3.1 handoff records final line counts and names the next P3 target.

## P3.1 Final Handoff - 2026-06-24

P3.1 and the user-approved P3.1b follow-up are complete. P3.1 extracted the
Remote sync, control API, Weixin bridge, surface snapshot, and agent request
boundaries. P3.1b extracted Skill Center action glue into
`src/appwindow/skill_center_actions.zig`, which was needed to reach the
AppWindow line target without touching the render loop, tab/split semantics,
PTY behavior, shortcut bindings, overlay behavior, `remote/`, or version
surfaces.

Final measured line counts:

```text
   7091 src/AppWindow.zig
      5 src/appwindow/active_tab.zig
    333 src/appwindow/agent_requests.zig
    267 src/appwindow/control_api.zig
    105 src/appwindow/flush_scheduler.zig
    131 src/appwindow/frame_latency.zig
    193 src/appwindow/p3_1_guard.zig
     73 src/appwindow/remote_state.zig
    390 src/appwindow/remote_sync.zig
    127 src/appwindow/render_gate.zig
     69 src/appwindow/resize_throttle.zig
   2325 src/appwindow/skill_center_actions.zig
    397 src/appwindow/split_layout.zig
     22 src/appwindow/state.zig
     20 src/appwindow/state_guard.zig
    207 src/appwindow/surface_snapshots.zig
   3157 src/appwindow/tab.zig
     89 src/appwindow/thread_message.zig
    530 src/appwindow/tmux_bridge.zig
     44 src/appwindow/tmux_controller.zig
    496 src/appwindow/tmux_controller_posix.zig
    765 src/appwindow/tmux_controller_windows.zig
     45 src/appwindow/ui_effect.zig
    462 src/appwindow/weixin_bridge.zig
     85 src/appwindow/window_state.zig
   7665 src/renderer/overlays.zig
   7101 src/input.zig
  32194 total
```

Final verification:

- New source guard: `src/appwindow/p3_1_guard.zig`, imported by
  `src/test_fast.zig`. The guard embeds `src/AppWindow.zig` and fails if P3.1
  bridge/request or P3.1b Skill Center implementation symbols return to
  AppWindow.
- Explicit allowed shim: `openRemoteAiAgentForClient` remains in AppWindow
  because it owns `App.windows` lookup under `App.mutex` and keeps
  `remote_sync.zig` decoupled from `App.zig`; it only forwards the request to
  the extracted remote handler on the UI thread.
- Guard red check: `zig build test` failed before cleanup on
  `fn remoteAiAgentOpen` and `fn skillCenterToolManifestPath`, proving the
  guard caught boundary violations.
- Review-fix guard red check: a temporary marker for
  `fn openRemoteAiAgentForClient` failed `zig build test`, proving the expanded
  guard still trips on AppWindow bodies before that marker was removed as an
  explicit allowed shim.
- Fast gate: `zig build test` passed after cleanup.
- Windows checkout safety: checked 1553 paths including the new guard file;
  name violations 0, case-fold collisions 0, symlinks 0, max path length 90.
- Full gate: `zig build test-full` passed once.

## Risks

| Risk | Mitigation |
|---|---|
| Extracted modules become broad global facades | Keep host/context APIs narrow and module-specific. |
| Moving callback glue breaks pointer lifetimes or thread handoff | Move request structs and post handlers together; preserve existing allocation/free ownership. |
| Remote/control JSON behavior drifts | Reuse existing tests and add source guards; do not rewrite JSON schemas in P3.1. |
| Line count target tempts risky render-loop moves | P3.1 explicitly excludes `runMainLoop` and render frame lifecycle. |
| `test-full` slows iteration | Run fast tests per task and reserve `test-full` for the final P3.1 gate. |

## P3 Continuation

After P3.1, the next stage should choose one of:

- P3.2 render/main-loop extraction, aligned with Ghostty's renderer-thread
  separation; or
- P3.2 tab/split/session orchestration extraction, if render-loop risk is still
  too high.

P3.1 should not attempt both.
