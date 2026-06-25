# UI State Debt P2.3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start the AppWindow state migration by adding explicit window/remote state owners, migrating low-risk AppWindow globals, and guarding the new boundaries.

**Architecture:** Add `WindowState`, `RemoteState`, and an `AppWindowState` aggregate under `src/appwindow/`. `AppWindow.zig` owns one threadlocal aggregate and keeps compatibility facade functions for callers. P2.3 fully migrates remote layout/input-sink/transfer notification state and the low-risk window resize/immediate-layout/present-settlement state; public root-grid, dirty, and cursor globals remain compatibility surfaces for later `UiEffect`-first slices.

**Tech Stack:** Zig, `zig build test` fast suite for pure state/source-guard checks, bare `zig build test-full` as the final Windows cross-compile/full app compile gate, Ghostty-aligned explicit state ownership.

---

## P2 Stage Ledger

- **P2.1 (done):** `OverlayState` plus settings, toast/update prompt, and confirmation state modules.
- **P2.2 (done):** session launcher, SSH list/form, AI list/form, AI history source picker, switch-model target.
- **P2.3 (this plan):** AppWindow `WindowState` / `RemoteState` owner foundation and first low-risk migrations.
- **Later P2/P3 slices:** public dirty/grid/cursor globals, UI config flags, input-owned mouse/drag state modules, process-wide agent/control caches.

Do not start later slices while executing this plan. If a task becomes too large,
stop and split it with user approval instead of silently reducing scope.

## Verification Policy

- Run `zig build test` after every task.
- Commit after every task.
- Run bare `zig build test-full` once at the final P2.3 gate. The user specified
  Windows cross-compilation only; macOS native test gates are not required for
  this stage.
- Run Windows checkout-safety checks because this plan adds files.

Ghostty reference: Ghostty's `Surface.zig` owns explicit nested state fields
(`renderer_state`, `mouse: Mouse`, `keyboard: Keyboard`, focus/config/size),
`renderer/State.zig` is a focused renderer-data object with a documented mutex
contract, `renderer/Thread.zig` owns wakeup/mailbox/render timers, and
`src/input/` is split by concept. P2.3 follows that direction by adding explicit
WispTerm state owners before extracting larger behavior from `AppWindow.zig`.

## File Structure

- Create: `src/appwindow/window_state.zig`
  - Pure window/render state model, pending resize helpers, immediate-layout
    helper, dirty helper, cursor blink helper, present bring-up settlement.
- Create: `src/appwindow/remote_state.zig`
  - Pure remote layout throttle, remote AI input sink storage, transfer
    notification sequence dedupe.
- Create: `src/appwindow/state.zig`
  - Aggregated `AppWindowState`.
- Create: `src/appwindow/state_guard.zig`
  - Source guard preventing migrated AppWindow globals from returning.
- Modify: `src/AppWindow.zig`
  - Own one `g_appwindow_state`; route remote and selected window state through
    accessors; keep public compatibility globals outside the P2.3 scope.
- Modify: `src/input.zig`
  - Replace direct pending-resize writes with `AppWindow.requestGridResize`.
- Modify: `src/test_fast.zig`
  - Import new pure state modules and guard.
- Modify: `src/test_main.zig`
  - Import new modules for full app compile coverage.
- Modify: `docs/superpowers/specs/2026-06-24-ui-state-debt-p2-3-design.md`
  - Append final handoff after implementation.

---

### Task 1: Add WindowState Model

**Files:**
- Create: `src/appwindow/window_state.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/appwindow/window_state.zig` with tests first:

```zig
const std = @import("std");
const Config = @import("../config.zig");
const resize_throttle = @import("resize_throttle.zig");
const UiEffect = @import("ui_effect.zig").UiEffect;

test "window state dirty helpers mirror UiEffect repaint" {
    var state = State{ .force_rebuild = false, .cells_valid = true };

    state.applyUiEffect(UiEffect.repaint);

    try std.testing.expect(state.force_rebuild);
    try std.testing.expect(!state.cells_valid);

    state.clearDirty();
    try std.testing.expect(!state.force_rebuild);
    try std.testing.expect(state.cells_valid);
}

test "window state pending resize coalesces and ignores unchanged grid" {
    var state = State{ .term_cols = 80, .term_rows = 24 };

    state.queueResize(100, 40, 1_000);
    try std.testing.expectEqual(@as(?GridSize, null), state.consumeCoalescedResize(1_010, 25, 80, 24));
    try std.testing.expect(state.pending_resize.pending);

    const consumed = state.consumeCoalescedResize(1_030, 25, 80, 24).?;
    try std.testing.expectEqual(@as(u16, 100), consumed.cols);
    try std.testing.expectEqual(@as(u16, 40), consumed.rows);
    try std.testing.expect(!state.pending_resize.pending);

    state.queueResize(100, 40, 2_000);
    try std.testing.expectEqual(@as(?GridSize, null), state.consumeCoalescedResize(2_030, 25, 100, 40));
    try std.testing.expect(!state.pending_resize.pending);
}

test "window state immediate layout resize is one-shot" {
    var state = State{};

    state.requestImmediateLayoutResize();
    try std.testing.expect(state.layout_resize_immediate);
    try std.testing.expect(state.consumeImmediateLayoutResize());
    try std.testing.expect(!state.consumeImmediateLayoutResize());
}

test "window state cursor blink toggles only when enabled and due" {
    var state = State{ .cursor_blink = true, .cursor_blink_visible = true, .last_blink_time_ms = 100 };

    try std.testing.expect(!state.updateCursorBlink(650, 600));
    try std.testing.expect(state.cursor_blink_visible);

    try std.testing.expect(state.updateCursorBlink(700, 600));
    try std.testing.expect(!state.cursor_blink_visible);
    try std.testing.expectEqual(@as(i64, 700), state.last_blink_time_ms);

    state.cursor_blink = false;
    state.cursor_blink_visible = false;
    try std.testing.expect(!state.updateCursorBlink(2_000, 600));
    try std.testing.expect(state.cursor_blink_visible);
}

test "window state present bringup settlement fires once" {
    var state = State{};

    try std.testing.expect(state.takePresentBringupSettlement());
    try std.testing.expect(!state.takePresentBringupSettlement());
}
```

Register it in `src/test_fast.zig` near the other appwindow imports:

```zig
    _ = @import("appwindow/window_state.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `State` and `GridSize` are undeclared.

- [ ] **Step 3: Implement the WindowState model**

Replace `src/appwindow/window_state.zig` with this full implementation, keeping
the tests from Step 1 at the bottom:

```zig
const std = @import("std");
const Config = @import("../config.zig");
const resize_throttle = @import("resize_throttle.zig");
const UiEffect = @import("ui_effect.zig").UiEffect;

pub const GridSize = struct {
    cols: u16,
    rows: u16,
};

pub const PendingResize = struct {
    pending: bool = false,
    cols: u16 = 0,
    rows: u16 = 0,
    last_ms: i64 = 0,
};

pub const State = struct {
    // Compatibility shape for the eventual root-grid migration.
    term_cols: u16 = 80,
    term_rows: u16 = 24,

    // Compatibility shape for the eventual dirty-flag migration.
    cells_valid: bool = false,
    force_rebuild: bool = true,

    // P2.3-wired window state.
    present_bringup_settled: bool = false,
    focused: bool = true,
    pending_resize: PendingResize = .{},
    layout_resize_immediate: bool = false,

    // Compatibility shape for a later cursor/config migration.
    cursor_style: Config.CursorStyle = .block,
    cursor_blink: bool = true,
    cursor_blink_visible: bool = true,
    last_blink_time_ms: i64 = 0,
    focus_follows_mouse: bool = false,
    copy_on_select: bool = false,
    copilot_hint: bool = true,
    copilot_shimmer_checked: bool = false,
    right_click_action: Config.RightClickAction = .copy,
    ssh_legacy_algorithms: bool = false,
    desktop_notifications: bool = true,
    confirm_close_running_program: bool = true,
    weixin_notify_forward: bool = false,
    notification_auth_requested: bool = false,

    resize_throttle: resize_throttle.ResizeThrottle = .{},

    pub fn markDirty(self: *State) void {
        self.force_rebuild = true;
        self.cells_valid = false;
    }

    pub fn clearDirty(self: *State) void {
        self.force_rebuild = false;
        self.cells_valid = true;
    }

    pub fn applyUiEffect(self: *State, effect: UiEffect) void {
        if (effect.needs_rebuild) self.force_rebuild = true;
        if (effect.cells_invalid) self.cells_valid = false;
    }

    pub fn requestImmediateLayoutResize(self: *State) void {
        self.layout_resize_immediate = true;
    }

    pub fn consumeImmediateLayoutResize(self: *State) bool {
        const immediate = self.layout_resize_immediate;
        self.layout_resize_immediate = false;
        return immediate;
    }

    pub fn queueResize(self: *State, cols: u16, rows: u16, now_ms: i64) void {
        self.pending_resize = .{
            .pending = true,
            .cols = cols,
            .rows = rows,
            .last_ms = now_ms,
        };
    }

    pub fn clearPendingResize(self: *State) void {
        self.pending_resize.pending = false;
    }

    pub fn consumeCoalescedResize(
        self: *State,
        now_ms: i64,
        interval_ms: i64,
        current_cols: u16,
        current_rows: u16,
    ) ?GridSize {
        if (!self.pending_resize.pending) return null;
        if (now_ms - self.pending_resize.last_ms < interval_ms) return null;

        const next = GridSize{
            .cols = self.pending_resize.cols,
            .rows = self.pending_resize.rows,
        };
        self.pending_resize.pending = false;

        if (next.cols == current_cols and next.rows == current_rows) return null;
        return next;
    }

    pub fn updateFocus(self: *State, focused: bool) bool {
        const changed = self.focused != focused;
        self.focused = focused;
        return changed;
    }

    pub fn resetCursorBlink(self: *State, now_ms: i64) void {
        self.cursor_blink_visible = true;
        self.last_blink_time_ms = now_ms;
    }

    pub fn updateCursorBlink(self: *State, now_ms: i64, interval_ms: i64) bool {
        if (!self.cursor_blink) {
            const changed = !self.cursor_blink_visible;
            self.cursor_blink_visible = true;
            return changed;
        }
        if (now_ms - self.last_blink_time_ms < interval_ms) return false;
        self.cursor_blink_visible = !self.cursor_blink_visible;
        self.last_blink_time_ms = now_ms;
        return true;
    }

    pub fn takePresentBringupSettlement(self: *State) bool {
        if (self.present_bringup_settled) return false;
        self.present_bringup_settled = true;
        return true;
    }
};

// ...tests from Step 1...
```

- [ ] **Step 4: Run the fast suite and verify GREEN**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/window_state.zig src/test_fast.zig
git commit -m "refactor(appwindow): add window state model"
```

---

### Task 2: Add RemoteState Model

**Files:**
- Create: `src/appwindow/remote_state.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/appwindow/remote_state.zig` with tests first:

```zig
const std = @import("std");

test "remote state throttles layout sends and can force the next layout" {
    var state = State{};

    try std.testing.expect(state.shouldSendLayout(1_000, 250));
    try std.testing.expect(!state.shouldSendLayout(1_100, 250));

    state.forceNextLayout();
    try std.testing.expect(state.shouldSendLayout(1_101, 250));
}

test "remote state records ai input sinks by index" {
    var state = State{};

    const sink = state.recordAiSink(2, 0x1234).?;
    try std.testing.expectEqual(@as(usize, 2), sink.tab_index);
    try std.testing.expectEqual(@as(usize, 0x1234), sink.native_handle_bits);
    try std.testing.expect(sink.registered);

    try std.testing.expectEqual(sink, state.aiSink(2).?);
    try std.testing.expectEqual(@as(?*AiInputSink, null), state.recordAiSink(MAX_REMOTE_AI_SINKS, 1));
}

test "remote state dedupes transfer notifications by sequence" {
    var state = State{};

    try std.testing.expect(state.acceptTransferNotification(10));
    try std.testing.expect(!state.acceptTransferNotification(10));
    try std.testing.expect(state.acceptTransferNotification(11));
}
```

Register it in `src/test_fast.zig`:

```zig
    _ = @import("appwindow/remote_state.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `State`, `AiInputSink`, and `MAX_REMOTE_AI_SINKS` are undeclared.

- [ ] **Step 3: Implement the RemoteState model**

Replace `src/appwindow/remote_state.zig` with this full implementation, keeping
the tests from Step 1 at the bottom:

```zig
const std = @import("std");

pub const MAX_REMOTE_AI_SINKS: usize = 32;

pub const AiInputSink = struct {
    native_handle_bits: usize = 0,
    tab_index: usize = 0,
    registered: bool = false,
};

pub const State = struct {
    layout_last_ms: i64 = 0,
    ai_sinks: [MAX_REMOTE_AI_SINKS]AiInputSink = .{.{}} ** MAX_REMOTE_AI_SINKS,
    last_transfer_notification_seq: u64 = 0,

    pub fn shouldSendLayout(self: *State, now_ms: i64, interval_ms: i64) bool {
        if (self.layout_last_ms != 0 and now_ms - self.layout_last_ms < interval_ms) return false;
        self.layout_last_ms = now_ms;
        return true;
    }

    pub fn forceNextLayout(self: *State) void {
        self.layout_last_ms = 0;
    }

    pub fn recordAiSink(self: *State, tab_index: usize, native_handle_bits: usize) ?*AiInputSink {
        if (tab_index >= self.ai_sinks.len) return null;
        self.ai_sinks[tab_index] = .{
            .native_handle_bits = native_handle_bits,
            .tab_index = tab_index,
            .registered = true,
        };
        return &self.ai_sinks[tab_index];
    }

    pub fn aiSink(self: *State, tab_index: usize) ?*AiInputSink {
        if (tab_index >= self.ai_sinks.len) return null;
        if (!self.ai_sinks[tab_index].registered) return null;
        return &self.ai_sinks[tab_index];
    }

    pub fn acceptTransferNotification(self: *State, seq: u64) bool {
        if (seq == self.last_transfer_notification_seq) return false;
        self.last_transfer_notification_seq = seq;
        return true;
    }
};

// ...tests from Step 1...
```

- [ ] **Step 4: Run the fast suite and verify GREEN**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/remote_state.zig src/test_fast.zig
git commit -m "refactor(appwindow): add remote state model"
```

---

### Task 3: Add AppWindowState Aggregate

**Files:**
- Create: `src/appwindow/state.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write the failing aggregate test**

Create `src/appwindow/state.zig`:

```zig
const std = @import("std");
const window_state = @import("window_state.zig");
const remote_state = @import("remote_state.zig");

test "appwindow state aggregates window and remote state" {
    var state = State{};

    state.window.queueResize(120, 32, 100);
    _ = state.remote.recordAiSink(1, 0x5678);

    try std.testing.expect(state.window.pending_resize.pending);
    try std.testing.expectEqual(@as(usize, 0x5678), state.remote.aiSink(1).?.native_handle_bits);
}
```

Register it in `src/test_fast.zig`:

```zig
    _ = @import("appwindow/state.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `State` is undeclared.

- [ ] **Step 3: Implement the aggregate**

Replace `src/appwindow/state.zig` with:

```zig
const std = @import("std");
const window_state = @import("window_state.zig");
const remote_state = @import("remote_state.zig");

pub const WindowState = window_state.State;
pub const RemoteState = remote_state.State;
pub const RemoteAiInputSink = remote_state.AiInputSink;

pub const State = struct {
    window: WindowState = .{},
    remote: RemoteState = .{},
};

test "appwindow state aggregates window and remote state" {
    var state = State{};

    state.window.queueResize(120, 32, 100);
    _ = state.remote.recordAiSink(1, 0x5678);

    try std.testing.expect(state.window.pending_resize.pending);
    try std.testing.expectEqual(@as(usize, 0x5678), state.remote.aiSink(1).?.native_handle_bits);
}
```

- [ ] **Step 4: Register the modules in the full app binary**

In `src/test_main.zig`, add near the other `appwindow/` imports:

```zig
    _ = @import("appwindow/window_state.zig");
    _ = @import("appwindow/remote_state.zig");
    _ = @import("appwindow/state.zig");
```

- [ ] **Step 5: Run the fast suite and verify GREEN**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/appwindow/state.zig src/test_fast.zig src/test_main.zig
git commit -m "refactor(appwindow): aggregate AppWindow state"
```

---

### Task 4: Wire RemoteState Through AppWindow

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Add the aggregate import and accessors**

In `src/AppWindow.zig`, add near the other `appwindow/` imports:

```zig
const appwindow_state = @import("appwindow/state.zig");
```

Near the module-level state block, add the aggregate and private accessors:

```zig
threadlocal var g_appwindow_state: appwindow_state.State = .{};

fn windowState() *appwindow_state.WindowState {
    return &g_appwindow_state.window;
}

fn remoteState() *appwindow_state.RemoteState {
    return &g_appwindow_state.remote;
}
```

- [ ] **Step 2: Remove the migrated remote globals**

Delete these declarations from `src/AppWindow.zig`:

```zig
threadlocal var g_remote_layout_last_ms: i64 = 0;
threadlocal var g_remote_ai_sinks: [tab.MAX_TABS]RemoteAiInputSink = undefined;
threadlocal var g_last_transfer_notification_seq: u64 = 0;
```

Keep the `RemoteAiInputRequest` and `RemoteAiAgentOpenRequest` structs. Remove
the old `RemoteAiInputSink` struct if it becomes unused after Step 4.

- [ ] **Step 3: Route layout throttling and transfer notification dedupe**

In `syncRemoteLayout`, replace:

```zig
    const now = std.time.milliTimestamp();
    if (now - g_remote_layout_last_ms < 250) return;
    g_remote_layout_last_ms = now;
```

with:

```zig
    const now = std.time.milliTimestamp();
    if (!remoteState().shouldSendLayout(now, 250)) return;
```

In `syncTransferToastFromFileExplorer`, replace:

```zig
    if (notification.seq == g_last_transfer_notification_seq) return;
    g_last_transfer_notification_seq = notification.seq;
```

with:

```zig
    if (!remoteState().acceptTransferNotification(notification.seq)) return;
```

In `handleRemoteAiAgentOpenRequest`, replace:

```zig
        g_remote_layout_last_ms = 0;
```

with:

```zig
        remoteState().forceNextLayout();
```

- [ ] **Step 4: Route remote AI input sinks through RemoteState**

In `registerRemoteAiInputSink`, replace the direct array write:

```zig
    if (tab_index >= g_remote_ai_sinks.len) return;

    g_remote_ai_sinks[tab_index] = .{
        .native_handle = window_backend.nativeHandle(window),
        .tab_index = tab_index,
    };
    client.registerSurface(remoteAiSurfaceId(tab_index), &g_remote_ai_sinks[tab_index], remoteAiWrite);
```

with:

```zig
    const sink = remoteState().recordAiSink(tab_index, window_backend.nativeHandleBits(window)) orelse return;
    client.registerSurface(remoteAiSurfaceId(tab_index), sink, remoteAiWrite);
```

In `remoteAiWrite`, replace the sink cast and post target:

```zig
    const sink: *RemoteAiInputSink = @ptrCast(@alignCast(ctx));
```

with:

```zig
    const sink: *appwindow_state.RemoteAiInputSink = @ptrCast(@alignCast(ctx));
    const native_handle = window_backend.nativeHandleFromBits(sink.native_handle_bits) orelse return;
```

Then replace:

```zig
    const ok = thread_message.postPointer(sink.native_handle, .remote_ai_input, @intFromPtr(request));
```

with:

```zig
    const ok = thread_message.postPointer(native_handle, .remote_ai_input, @intFromPtr(request));
```

- [ ] **Step 5: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS. This fast run covers `RemoteState`; `AppWindow.zig` itself is
compiled in the final full gate.

- [ ] **Step 6: Commit**

```bash
git add src/AppWindow.zig
git commit -m "refactor(appwindow): route remote state through AppWindowState"
```

---

### Task 5: Wire Low-Risk WindowState Fields Through AppWindow

**Files:**
- Modify: `src/AppWindow.zig`
- Modify: `src/input.zig`

- [ ] **Step 1: Add facade helpers for the migrated window fields**

In `src/AppWindow.zig`, near the existing resize helpers, add:

```zig
pub fn requestGridResize(cols: u16, rows: u16, now_ms: i64) void {
    windowState().queueResize(cols, rows, now_ms);
}

fn pendingResizeActive() bool {
    return windowState().pending_resize.pending;
}

fn clearPendingResize() void {
    windowState().clearPendingResize();
}

fn consumePendingGridResize(now_ms: i64) ?@import("appwindow/window_state.zig").GridSize {
    return windowState().consumeCoalescedResize(now_ms, RESIZE_COALESCE_MS, term_cols, term_rows);
}
```

Change the existing immediate-layout helpers to delegate:

```zig
pub fn requestImmediateLayoutResize() void {
    windowState().requestImmediateLayoutResize();
}

pub fn consumeImmediateLayoutResize() bool {
    return windowState().consumeImmediateLayoutResize();
}
```

- [ ] **Step 2: Remove the migrated window globals**

Delete these declarations from `src/AppWindow.zig`:

```zig
threadlocal var g_present_bringup_settled: bool = false;
pub threadlocal var g_pending_resize: bool = false;
pub threadlocal var g_pending_cols: u16 = 0;
pub threadlocal var g_pending_rows: u16 = 0;
pub threadlocal var g_last_resize_time: i64 = 0;
pub threadlocal var g_layout_resize_immediate: bool = false;
```

- [ ] **Step 3: Replace pending resize uses in AppWindow**

In `renderResizeFrame`, replace log args and clears:

```text
g_pending_resize -> pendingResizeActive()
g_pending_resize = false -> clearPendingResize()
```

In the main loop, replace the coalesced resize block:

```zig
        if (g_pending_resize) {
            const now = std.time.milliTimestamp();
            if (now - g_last_resize_time >= RESIZE_COALESCE_MS) {
                g_pending_resize = false;

                if (g_pending_cols != term_cols or g_pending_rows != term_rows) {
                    term_cols = g_pending_cols;
                    term_rows = g_pending_rows;
                }
            }
        }
```

with:

```zig
        if (consumePendingGridResize(std.time.milliTimestamp())) |grid| {
            term_cols = grid.cols;
            term_rows = grid.rows;
        }
```

In render-gate signal collection, replace:

```zig
            .force_rebuild = g_force_rebuild or !g_cells_valid or g_pending_resize or g_layout_resize_immediate,
```

with:

```zig
            .force_rebuild = g_force_rebuild or !g_cells_valid or pendingResizeActive() or windowState().layout_resize_immediate,
```

In the present bring-up settlement path, replace:

```zig
        if (!g_present_bringup_settled) {
            g_present_bringup_settled = true;
            platform_window_state.settleD3dBringup(allocator);
        }
```

with:

```zig
        if (windowState().takePresentBringupSettlement()) {
            platform_window_state.settleD3dBringup(allocator);
        }
```

- [ ] **Step 4: Replace pending resize writes in input**

In `src/input.zig`, inside `syncGridFromWindowSize`, replace:

```zig
        AppWindow.g_pending_resize = true;
        AppWindow.g_pending_cols = new_cols;
        AppWindow.g_pending_rows = new_rows;
        AppWindow.g_last_resize_time = std.time.milliTimestamp();
```

with:

```zig
        AppWindow.requestGridResize(new_cols, new_rows, std.time.milliTimestamp());
```

- [ ] **Step 5: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS. `input.zig` and `AppWindow.zig` full compilation is covered in
the final full gate.

- [ ] **Step 6: Commit**

```bash
git add src/AppWindow.zig src/input.zig
git commit -m "refactor(appwindow): route resize state through WindowState"
```

---

### Task 6: Add AppWindow State Source Guard

**Files:**
- Create: `src/appwindow/state_guard.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the source guard**

Create `src/appwindow/state_guard.zig`:

```zig
const std = @import("std");

test "appwindow: migrated P2.3 state globals stay out of AppWindow facade" {
    const source = @embedFile("../AppWindow.zig");
    const forbidden = [_][]const u8{
        "g_remote_layout_last_ms",
        "g_remote_ai_sinks",
        "g_last_transfer_notification_seq",
        "g_pending_resize",
        "g_pending_cols",
        "g_pending_rows",
        "g_last_resize_time",
        "g_layout_resize_immediate",
        "g_present_bringup_settled",
    };

    for (forbidden) |name| {
        try std.testing.expect(std.mem.indexOf(u8, source, name) == null);
    }
}
```

Register it in `src/test_fast.zig` near the other appwindow imports:

```zig
    _ = @import("appwindow/state_guard.zig");
```

- [ ] **Step 2: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS. If the guard fails, search `src/AppWindow.zig` for the reported
token and finish the migration from Tasks 4-5.

- [ ] **Step 3: Commit**

```bash
git add src/appwindow/state_guard.zig src/test_fast.zig
git commit -m "test(appwindow): guard P2.3 state boundaries"
```

---

### Task 7: Final P2.3 Verification and Handoff

**Files:**
- Modify: `docs/superpowers/specs/2026-06-24-ui-state-debt-p2-3-design.md`

- [ ] **Step 1: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 2: Run the Windows cross-compile/full app gate**

Run:

```bash
zig build test-full
```

Expected: PASS compile gate. Do not run macOS-specific native gates for this
stage unless the user asks; the request explicitly scopes testing to Windows
cross-compilation.

- [ ] **Step 3: Run Windows checkout-safety checks**

Run the PowerShell checks from `docs/development.md#windows-checkout-safety` on a
Windows host, or an equivalent local script covering:

- Windows-reserved names
- illegal Windows path characters
- trailing spaces/dots
- case-fold collisions
- tracked symlinks
- max path length

Expected: 0 violations, 0 case-fold collisions, 0 tracked symlinks.

- [ ] **Step 4: Record line counts**

Run:

```bash
wc -l src/AppWindow.zig src/renderer/overlays.zig src/input.zig src/ai_chat.zig
```

- [ ] **Step 5: Append the P2.3 handoff note**

Append a `## P2.3 handoff` section to
`docs/superpowers/specs/2026-06-24-ui-state-debt-p2-3-design.md` with:

- a paragraph saying P2.3 introduced `WindowState`, `RemoteState`, and an
  `AppWindowState` aggregate under `src/appwindow/`;
- a paragraph saying remote layout throttle, remote AI input sink storage,
  transfer notification sequence dedupe, pending resize state, immediate layout
  resize state, and D3D present bring-up settlement now live behind the
  `AppWindowState` owner while `AppWindow.zig` remains the compatibility facade;
- a paragraph naming the intentionally retained public compatibility surfaces:
  `term_cols`, `term_rows`, `g_force_rebuild`, `g_cells_valid`, cursor blink
  globals, and UI config flags;
- a `Verification:` label followed by a fenced `text` block containing the exact
  result summary from Steps 1-3;
- a `Final line counts:` label followed by a fenced `text` block containing the
  exact `wc -l` output from Step 4.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-06-24-ui-state-debt-p2-3-design.md
git commit -m "docs: record ui state P2.3 handoff"
```

---

## Plan Self-Review

- **Spec coverage:** Tasks 1-3 create the state owner modules. Task 4 migrates
  the full RemoteState group. Task 5 migrates the low-risk WindowState group.
  Task 6 guards the migrated raw globals. Task 7 runs the final Windows-scoped
  verification and writes the handoff.
- **Placeholder scan:** No `TBD`, `TODO`, angle-bracket placeholders, or fake
  values remain. The handoff step instructs the executor to insert exact
  verification and line-count outputs after running the commands.
- **Type consistency:** `windowState()` / `remoteState()` return the types
  exported by `appwindow/state.zig`. `RemoteAiInputSink` uses
  `native_handle_bits`, matching the `remoteAiWrite` callback conversion.
  `requestGridResize(cols, rows, now_ms)` matches the `input.zig` call site.
- **Verification coverage:** New pure modules and source guard run in
  `zig build test`; AppWindow/input wiring compiles under the final
  `zig build test-full` Windows cross-compile gate.
- **Ghostty alignment:** The plan moves toward Ghostty-style explicit owner
  fields (`Surface.mouse`, `Surface.keyboard`, `renderer.State`,
  `renderer.Thread`) while respecting WispTerm's current public compatibility
  surfaces.
