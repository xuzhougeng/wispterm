# UI State Debt P3.1 AppWindow Integration Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Continue the UI state debt reduction by extracting AppWindow integration glue into narrow `src/appwindow/` modules while preserving behavior. Reduce `src/AppWindow.zig` from the current 10,571 lines to under 8,000 lines, ideally near 7,000, without touching the render loop, overlay behavior, keyboard shortcuts, remote web console, or release/version surfaces.

**Architecture:** Keep `AppWindow.zig` as the platform/window orchestrator. Move already-isolated integration clusters into modules with explicit host/facade APIs: `surface_snapshots.zig`, `control_api.zig`, `remote_sync.zig`, `weixin_bridge.zig`, and `agent_requests.zig`. AppWindow keeps small public compatibility facades where external code already calls AppWindow functions. The new modules may import existing state modules such as `appwindow/state.zig`, `appwindow/remote_state.zig`, `appwindow/tab.zig`, `renderer/overlays.zig`, `ai_chat.zig`, and platform facades, but they must not own render-loop or tab/split core behavior.

**Tech Stack:** Zig, existing WispTerm appwindow modules, `zig build test` for per-task verification, `zig build test-full` once as the final gate because it takes 5-10 minutes.

---

## Current Baseline

`src/AppWindow.zig` is 10,571 lines. P1 introduced `UiEffect`/invalidation seams and P2 introduced state modules, but the remaining large block is mostly integration code rather than core rendering:

- Remote layout/control glue around `syncRemoteLayout`, `buildRemoteLayoutJson`, remote AI tab JSON, and remote AI input callbacks.
- Agent control API glue around `ctlListPanes`, `ctlGetText`, `ctlSendText`, `ctlUiState`, pane/UI-state caches, and agent surface snapshots.
- Weixin bridge glue around request dispatch, UI-thread request structs, transcript cache, and callback vtable.
- Agent tool request glue around tab/new/close/SSH request structs, worker-post helpers, and UI-thread handlers.

The P3.1 extraction is intentionally not a render-loop refactor. The draw path, render gate, resize draw semantics, GPU lifecycle, tab/split ownership, overlay input behavior, and shortcut bindings remain in place.

## Ghostty Alignment

Ghostty keeps runtime coordination behind explicit seams instead of placing every integration callback directly in the window/render file:

- `src/App.zig` owns application-level coordination, mailbox draining, config propagation, and surface registration.
- `src/apprt/action.zig` defines explicit runtime actions instead of scattering platform callbacks through renderer code.
- `src/apprt/surface.zig` defines surface message/mailbox contracts.
- `src/renderer/Thread.zig` keeps renderer scheduling, wakeups, blink timers, and draw cadence separate from app/runtime actions.

P3.1 follows that direction at WispTerm's current maturity level: it does not attempt Ghostty's full action/mailbox architecture, but it moves control/remote/agent bridge responsibilities out of `AppWindow.zig` and gives each bridge a small public API.

## Guardrails

- Do not edit `remote/`.
- Do not change keyboard shortcuts or user-visible shortcut text.
- Do not change version files or release-note surfaces.
- Do not extract or rewrite `runMainLoop`.
- Do not change `src/appwindow/render_gate.zig` behavior.
- Do not change terminal rendering, PTY, tab/split semantics, or overlay behavior.
- Keep AppWindow compatibility facades for existing public functions unless every caller is updated in the same task.
- Run `zig build test` after every extraction task.
- Run `zig build test-full` only once in the final task unless a focused integration failure requires it.
- Commit after each task, before starting the next task.

## Task 1: Extract Surface Snapshot Helpers

**Purpose:** Move shared remote/agent surface snapshot code out of `AppWindow.zig` first, because later `control_api.zig`, `remote_sync.zig`, and `agent_requests.zig` can depend on this module instead of depending on AppWindow internals.

**Files:**

- Create `src/appwindow/surface_snapshots.zig`
- Modify `src/AppWindow.zig`
- Modify `src/test_fast.zig` if the new module has standalone tests

**Move from `src/AppWindow.zig`:**

- `appendAgentDetectionJson`
- `buildRemoteSurfaceSnapshot`
- `activeSurfaceSnapshot`
- `AgentSurfaceLocation`
- `findAgentSurfaceLocation`
- `makeAgentToolSurface`
- `collectAgentToolSnapshot`
- `agentSurfaceSnapshot`
- `agentWriteSurface`
- `agentSshConnectionForSurface`
- Tests immediately attached to these helpers

**Target public API:**

```zig
pub const AgentSurfaceLocation = struct {
    tab_index: usize,
    tab_type: tab.TabType,
    surface_id: u64,
    terminal: ?*Surface,
};

pub fn appendAgentDetectionJson(out: *std.ArrayList(u8), detection: agent_detector.Detection) !void;
pub fn buildRemoteSurfaceSnapshot(allocator: std.mem.Allocator, term: *Surface, tab_title: []const u8) ![]u8;
pub fn activeSurfaceSnapshot(allocator: std.mem.Allocator) ?[]u8;
pub fn findAgentSurfaceLocation(surface_id: u64) ?AgentSurfaceLocation;
pub fn makeAgentToolSurface(location: AgentSurfaceLocation, allocator: std.mem.Allocator) ?agent_tool_host.Surface;
pub fn collectAgentToolSnapshot(allocator: std.mem.Allocator) agent_tool_host.SnapshotResult;
pub fn agentSurfaceSnapshot(surface_id: u64, allocator: std.mem.Allocator) ?[]u8;
pub fn agentWriteSurface(surface_id: u64, text: []const u8) bool;
pub fn agentSshConnectionForSurface(surface_id: u64, allocator: std.mem.Allocator) ?agent_tool_host.SshConnection;
```

**Steps:**

- [ ] Inspect the exact current source ranges with `rg -n "appendAgentDetectionJson|buildRemoteSurfaceSnapshot|AgentSurfaceLocation|agentSshConnectionForSurface" src/AppWindow.zig`.
- [ ] Create `src/appwindow/surface_snapshots.zig` and move the helper bodies unchanged except for imports and qualified names.
- [ ] Keep `pub fn activeSurfaceSnapshot`, `agentSurfaceSnapshot`, `agentWriteSurface`, and `agentSshConnectionForSurface` facades in `src/AppWindow.zig` if external code still references AppWindow symbols. Each facade should delegate to `surface_snapshots`.
- [ ] Update AppWindow's agent tool host installation to point at `surface_snapshots` functions or the retained facades consistently.
- [ ] Move the related tests into `surface_snapshots.zig` when they no longer need AppWindow-only state. Keep tests in `AppWindow.zig` only when they depend on AppWindow-private setup.
- [ ] Add the new module to `src/test_fast.zig` only if its tests compile without the full app binary.
- [ ] Run `zig build test`.
- [ ] Commit: `refactor(appwindow): extract surface snapshot helpers`

**Expected line reduction:** 250-400 lines.

## Task 2: Extract Agent Control API

**Purpose:** Move the local control-channel API and its caches out of AppWindow. This mirrors Ghostty's separation of runtime actions/control surfaces from renderer scheduling.

**Files:**

- Create `src/appwindow/control_api.zig`
- Modify `src/AppWindow.zig`
- Modify `src/test_fast.zig` if standalone tests are added

**Move from `src/AppWindow.zig`:**

- `g_agent_control_enabled`
- `g_ctl_ctx`
- `g_ctl_panes_mutex`
- `g_ctl_panes_json`
- `g_ctl_panes_json_ts`
- `g_ctl_ui_state_mutex`
- `g_ctl_ui_state_json`
- `g_ctl_ui_state_json_ts`
- `enableAgentControl`
- `ctlListPanes`
- `ctlGetText`
- `ctlSendText`
- `ctlUiState`
- `ctl_vtable`
- `agentControl`
- `clearCtlPanesCache`
- `syncCtlPanes`
- `clearCtlUiStateCache`
- `syncCtlUiState`
- `buildCtlPanesJson`
- The test `ctl surface callbacks reject an unregistered id before dereferencing`

**Target public API:**

```zig
pub fn enable() void;
pub fn control() ctl_control.Control;
pub fn clearPanesCache() void;
pub fn syncPanes(allocator: std.mem.Allocator) void;
pub fn clearUiStateCache() void;
pub fn syncUiState(allocator: std.mem.Allocator) void;
pub fn buildPanesJson(allocator: std.mem.Allocator) ![]u8;
```

**AppWindow compatibility facades:**

```zig
pub fn enableAgentControl() void {
    control_api.enable();
}

pub fn agentControl() ctl_control.Control {
    return control_api.control();
}
```

**Steps:**

- [ ] Inspect current call sites with `rg -n "enableAgentControl|agentControl|syncCtlPanes|syncCtlUiState|clearCtl" src`.
- [ ] Create `src/appwindow/control_api.zig` and move the control callback state and functions unchanged except for imports and calls into `surface_snapshots`.
- [ ] Keep the public AppWindow facades above if any callers still use `AppWindow.enableAgentControl` or `AppWindow.agentControl`.
- [ ] Replace internal AppWindow call sites with `control_api.syncPanes`, `control_api.syncUiState`, `control_api.clearPanesCache`, and `control_api.clearUiStateCache`.
- [ ] Move `buildCtlPanesJson` and its test into `control_api.zig`; keep the JSON schema identical.
- [ ] Add focused tests for invalid surface IDs in `control_api.zig`, reusing the existing assertion.
- [ ] Add the new module to `src/test_fast.zig` only if it compiles without platform-coupled AppWindow state.
- [ ] Run `zig build test`.
- [ ] Commit: `refactor(appwindow): extract agent control api`

**Expected line reduction:** 400-650 lines.

## Task 3: Extract Remote Sync Glue

**Purpose:** Move WispTerm Remote layout publishing and remote AI control callbacks out of AppWindow while preserving the existing remote protocol JSON and callback behavior.

**Files:**

- Create `src/appwindow/remote_sync.zig`
- Modify `src/AppWindow.zig`
- Modify `src/appwindow/remote_state.zig` only if an accessor is required

**Move from `src/AppWindow.zig`:**

- `syncRemoteLayout`
- `buildRemoteLayoutJson`
- `remoteAiSurfaceId`
- `remoteAiHistorySurfaceId`
- `registerRemoteAiInputSink`
- `remoteAiWrite`
- `remoteAiAgentOpen`
- `appendRemoteAiChatTabJson`
- `appendRemoteAiHistoryTabJson`
- `RemoteAiInputRequest`
- `RemoteAiAgentOpenRequest`
- `handleRemoteAiInputRequest`
- `handleRemoteAiAgentOpenRequest`
- The `buildRemoteLayoutJson includes agent metadata from terminal snapshots` test

**Target public API:**

```zig
pub const Host = struct {
    app: ?*App,
    window: ?*window_backend.Window,
    state: *appwindow_state.State,
    markUiDirty: *const fn () void,
    openDefaultAgentSessionForRemote: *const fn () overlays.RemoteAgentOpenResult,
};

pub fn syncLayout(host: Host, allocator: std.mem.Allocator) void;
pub fn buildLayoutJson(host: Host, allocator: std.mem.Allocator) ![]u8;
pub fn writeAiInput(ctx: *anyopaque, surface_id: u64, text: []const u8) bool;
pub fn openAiAgent(ctx: *anyopaque, surface_id: u64, prompt: []const u8) bool;
pub fn handleAiInputRequest(req: *RemoteAiInputRequest, host: Host) void;
pub fn handleAiAgentOpenRequest(req: *RemoteAiAgentOpenRequest, host: Host) void;
```

`RemoteAiInputRequest` and `RemoteAiAgentOpenRequest` should be public only if AppWindow's message-dispatch type annotations require them. Otherwise keep them private and expose typed handler entry points that accept the pointer after AppWindow decodes the platform message.

**Steps:**

- [ ] Inspect current call sites with `rg -n "syncRemoteLayout|remoteAiWrite|remoteAiAgentOpen|handleRemoteAi" src/AppWindow.zig src`.
- [ ] Create `src/appwindow/remote_sync.zig` and move the remote layout JSON helpers unchanged except for imports and host access.
- [ ] Use `surface_snapshots.appendAgentDetectionJson` rather than duplicating agent-detection serialization.
- [ ] Route AppWindow's remote layout call to `remote_sync.syncLayout(host, allocator)`.
- [ ] Route platform message dispatch cases `.remote_ai_input` and `.remote_ai_agent_open` to `remote_sync` handlers with the same ownership and allocator semantics as the current code.
- [ ] Keep native-handle and `remote_state.State` ownership in AppWindow; remote_sync receives them through `Host`.
- [ ] Move the remote layout JSON test into `remote_sync.zig` if it no longer depends on AppWindow-private globals. Keep it in `AppWindow.zig` only if it must use existing AppWindow test fixtures.
- [ ] Run `zig build test`.
- [ ] Commit: `refactor(appwindow): extract remote sync bridge`

**Expected line reduction:** 450-750 lines.

## Task 4: Extract Weixin Bridge

**Purpose:** Move Weixin direct-message bridge state and callback routing out of AppWindow. This keeps the application bridge isolated from core window/render orchestration.

**Files:**

- Create `src/appwindow/weixin_bridge.zig`
- Modify `src/AppWindow.zig`

**Move from `src/AppWindow.zig`:**

- `g_weixin_ui_handle`
- `g_weixin_ctx`
- `g_weixin_transcript_mutex`
- `g_weixin_transcript_owned`
- `g_weixin_pinned_session`
- `WeixinRequest`
- `tabConversationSession`
- `weixinActiveAiTabIndex`
- `weixinTabIndexFromSurfaceId`
- `weixinActiveTerminalSurface`
- `weixinTerminalSurfaceFromId`
- `handleWeixinControlRequest`
- `weixinDispatch`
- `weixinOpenAiPanel`
- `weixinAppendAiInput`
- `weixinSubmitAiPrompt`
- `weixinClearAiPanel`
- `weixinSendToTerminal`
- `weixinActiveSnapshot`
- `weixin_vtable`
- `weixinControl`
- `clearWeixinTranscriptCache`

**Target public API:**

```zig
pub const Host = struct {
    markUiDirty: *const fn () void,
    openAiPanel: *const fn () void,
    appendAiInput: *const fn ([]const u8) bool,
    submitAiPrompt: *const fn () bool,
    clearAiPanel: *const fn () void,
};

pub fn setUiHandle(handle_bits: usize) void;
pub fn control() weixin_control.Control;
pub fn clearTranscriptCache() void;
pub fn handleControlRequest(req: *WeixinRequest, host: Host) void;
```

The module may import `appwindow/tab.zig`, `renderer/overlays.zig`, `Surface.zig`, and `weixin_control.zig` directly for lookups that are already global. Keep the UI-thread request dispatch via `window_backend.postWindowMessage` exactly as it works today.

**Steps:**

- [ ] Inspect current call sites with `rg -n "weixinControl|clearWeixinTranscriptCache|g_weixin_ui_handle|handleWeixinControlRequest" src`.
- [ ] Create `src/appwindow/weixin_bridge.zig` and move the Weixin bridge state, request type, helper lookups, dispatch function, vtable callbacks, control builder, and transcript cache cleanup.
- [ ] Replace AppWindow UI-handle publication with `weixin_bridge.setUiHandle(...)`.
- [ ] Route platform message dispatch case `.weixin_control` to `weixin_bridge.handleControlRequest(...)`.
- [ ] Keep `pub fn weixinControl()` and `pub fn clearWeixinTranscriptCache()` facades in AppWindow if external callers still use those names.
- [ ] Run `zig build test`.
- [ ] Commit: `refactor(appwindow): extract weixin bridge`

**Expected line reduction:** 500-800 lines.

## Task 5: Extract Agent Request Bridge

**Purpose:** Move worker-facing agent tab/SSH request posting and UI-thread request handlers out of AppWindow. This leaves AppWindow responsible for tab/split operations, while `agent_requests.zig` owns the callback/request boundary.

**Files:**

- Create `src/appwindow/agent_requests.zig`
- Modify `src/AppWindow.zig`

**Move from `src/AppWindow.zig`:**

- `AgentTabNewRequest`
- `AgentTabCloseRequest`
- `AgentSshConnectRequest`
- `AgentSshSaveRequest`
- `postAgentRequest`
- `postAgentOwnedStringRequest`
- `agentSpawnTab`
- `agentCloseTab`
- `agentConnectSshProfile`
- `agentSaveSshProfile`
- `agentTabCommand`
- `handleAgentTabNewRequest`
- `findTabIndexBySurfaceId`
- `findTabIndexByTitle`
- `resolveAgentCloseTabIndex`
- `handleAgentTabCloseRequest`
- `handleAgentSshConnectRequest`
- `handleAgentSshSaveRequest`

**Target public API:**

```zig
pub const Host = struct {
    currentNativeHandle: *const fn () ?window_backend.NativeHandle,
    spawnTabWithCommand: *const fn ([]const u8, bool) ?u64,
    closeTabByIndex: *const fn (usize) bool,
    connectSshProfile: *const fn ([]const u8) void,
    saveSshProfile: *const fn ([]const u8) void,
};

pub fn spawnTab(ctx: *anyopaque, command_utf8: []const u8) ?u64;
pub fn closeTab(ctx: *anyopaque, request: agent_tool_host.CloseTabRequest) bool;
pub fn connectSshProfile(ctx: *anyopaque, profile_name: []const u8) bool;
pub fn saveSshProfile(ctx: *anyopaque, profile_json: []const u8) bool;
pub fn handleTabNewRequest(req: *AgentTabNewRequest, host: Host) void;
pub fn handleTabCloseRequest(req: *AgentTabCloseRequest, host: Host) void;
pub fn handleSshConnectRequest(req: *AgentSshConnectRequest, host: Host) void;
pub fn handleSshSaveRequest(req: *AgentSshSaveRequest, host: Host) void;
```

Request types should remain private unless AppWindow dispatch code needs to name them. The UI-thread handlers must preserve current ownership transfer for allocated command/profile strings.

**Steps:**

- [ ] Inspect current call sites with `rg -n "agentSpawnTab|agentCloseTab|handleAgentTab|AgentSsh|resolveAgentCloseTabIndex" src/AppWindow.zig src`.
- [ ] Create `src/appwindow/agent_requests.zig` and move request structs, post helpers, worker callback functions, tab command construction, close-target resolution, and UI-thread handlers.
- [ ] Keep actual tab creation, tab close, SSH connect, and SSH save operations inside AppWindow by passing a small `Host` from AppWindow to the request handlers.
- [ ] Route platform message dispatch cases `.agent_tab_new`, `.agent_tab_close`, `.agent_ssh_connect`, and `.agent_ssh_save` to `agent_requests` handlers.
- [ ] Update AI agent tool host installation to use `agent_requests.spawnTab`, `agent_requests.closeTab`, `agent_requests.connectSshProfile`, and `agent_requests.saveSshProfile`.
- [ ] Run `zig build test`.
- [ ] Commit: `refactor(appwindow): extract agent request bridge`

**Expected line reduction:** 450-750 lines.

## Task 6: Add P3.1 Guards and Final Verification

**Purpose:** Lock the P3.1 boundary so future work does not silently move these bridge responsibilities back into `src/AppWindow.zig`.

**Files:**

- Create `src/appwindow/p3_1_guard.zig`
- Modify `src/test_fast.zig`
- Optionally update `docs/superpowers/specs/2026-06-24-ui-state-debt-p3-1-design.md` with final measured line counts

**Guard content:**

Embed `src/AppWindow.zig` source and assert these symbols are absent from AppWindow:

- `fn buildRemoteLayoutJson`
- `fn buildCtlPanesJson`
- `const WeixinRequest`
- `const weixin_vtable`
- `const ctl_vtable`
- `fn remoteAiWrite`
- `fn remoteAiAgentOpen`
- `fn appendRemoteAiChatTabJson`
- `fn appendRemoteAiHistoryTabJson`
- `fn makeAgentToolSurface`
- `fn agentSpawnTab`
- `fn handleAgentTabNewRequest`
- `fn handleAgentTabCloseRequest`
- `fn handleAgentSshConnectRequest`
- `fn handleAgentSshSaveRequest`

Allow small AppWindow facades such as `syncRemoteLayout`, `agentControl`, `weixinControl`, and `activeSurfaceSnapshot` when they delegate to extracted modules.

**Steps:**

- [ ] Create `src/appwindow/p3_1_guard.zig` with source-boundary tests.
- [ ] Add `p3_1_guard.zig` to `src/test_fast.zig`.
- [ ] Run line counts:

  ```sh
  wc -l src/AppWindow.zig src/appwindow/*.zig src/renderer/overlays.zig src/input.zig
  ```

- [ ] Confirm `src/AppWindow.zig` is below 8,000 lines. If it is above 8,000 after Tasks 1-5, stop and report the exact remaining largest AppWindow regions before implementing additional moves.
- [ ] Run fast tests:

  ```sh
  zig build test
  ```

- [ ] Run Windows checkout-safety checks because new files were added:

  ```sh
  python3 - <<'PY'
  import os
  from collections import defaultdict

  root = "."
  reserved = {"con", "prn", "aux", "nul", *(f"com{i}" for i in range(1, 10)), *(f"lpt{i}" for i in range(1, 10))}
  bad_chars = set('<>:"|?*')
  by_lower = defaultdict(list)
  failures = []

  for dirpath, dirnames, filenames in os.walk(root):
      if ".git" in dirpath.split(os.sep):
          continue
      for name in dirnames + filenames:
          rel = os.path.relpath(os.path.join(dirpath, name), root)
          base = name.split(".")[0].lower()
          if base in reserved:
              failures.append(f"reserved name: {rel}")
          if any(ch in bad_chars for ch in name):
              failures.append(f"illegal char: {rel}")
          if os.path.islink(os.path.join(dirpath, name)):
              failures.append(f"symlink: {rel}")
          if len(os.path.abspath(os.path.join(dirpath, name))) >= 240:
              failures.append(f"long path: {rel}")
          by_lower[rel.lower()].append(rel)

  for paths in by_lower.values():
      if len(paths) > 1:
          failures.append("case collision: " + " | ".join(sorted(paths)))

  if failures:
      print("\n".join(failures))
      raise SystemExit(1)
  print("windows checkout safety: ok")
  PY
  ```

- [ ] Run the final full gate once:

  ```sh
  zig build test-full
  ```

- [ ] Update the P3.1 design spec with final line counts and test results.
- [ ] Commit: `test(appwindow): guard P3.1 extraction boundaries`

**Expected final state:**

- `src/AppWindow.zig` is below 8,000 lines.
- New modules hold extracted bridge responsibilities.
- `zig build test` passes after every task.
- `zig build test-full` passes once at final gate.
- Windows checkout-safety check passes.
- P3.1 has a committed guard preventing the moved bridge symbols from returning to AppWindow.

## Rollback Strategy

Each task is committed separately. If a task regresses behavior, revert only that task's commit and keep earlier extracted modules. Do not revert user changes or unrelated files.

## Handoff Notes for Implementers

- Preserve JSON field names and callback ownership semantics exactly.
- Prefer moving function bodies unchanged before making any cleanup edits.
- Keep each commit focused on one extracted module.
- Treat `zig build test-full` as the final gate because it is slow.
- If a task exposes a hidden dependency on AppWindow-private state, stop at that task boundary and report the exact dependency instead of widening the refactor.
