# UI State Debt P2.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the first batch of overlay state out of `renderer/overlays.zig` into feature-owned state modules while preserving the facade API and expanding the `UiEffect` path.

**Architecture:** P2.1 adds `settings_page`, `toasts`, `confirm_modals`, and `state` modules under `src/renderer/overlays/`. `overlays.zig` remains the compatibility facade, but migrated state lives behind `OverlayState`. Settings and simple confirmation key paths return `UiEffect` so `input.zig` stops manually dirtying those converted branches.

**Tech Stack:** Zig, `zig build test` fast suite for leaf/state/source-guard checks, one `zig build test-full` 5-10 minute stage gate at the end, Ghostty-aligned explicit state ownership.

---

## P2 Stage Ledger

P2 is intentionally staged:

- **P2.1 current plan:** `OverlayState` plus settings, toast/update prompt, and confirmation state modules.
- **P2.2 future plan:** session launcher, SSH forms, AI profile forms, AI history source picker, switch-model target state.
- **P2.3 future plan:** `AppWindow` `WindowState`, `InputState`, and `RemoteState` migrations toward the 4000-line target.

Do not start P2.2 or P2.3 tasks while executing this plan. P2.2 begins only
after P2.1 passes final verification and is explicitly accepted.

## Verification Policy

`zig build test-full` takes 5-10 minutes. During P2.1:

- Run `zig build test` after every leaf/model/source-guard task.
- Run `zig build test` after wiring tasks.
- Use code review for `overlays.zig` and `input.zig` wiring.
- Run `zig build test-full` once at the final P2.1 gate, unless a wiring task
  creates a specific high-risk integration question.

Ghostty reference: Ghostty keeps state in explicit owners such as `Surface`,
`renderer/State.zig`, `renderer/Overlay.zig`, and `input/*`. P2.1 follows that
direction by moving overlay state into feature-owned modules while preserving
WispTerm's existing facade during migration.

## File Structure

- Create: `src/renderer/overlays/settings_page.zig`
  - Settings page state, row math, and key-to-action decisions.
- Create: `src/renderer/overlays/toasts.zig`
  - Copy/status toast, transfer toast, update prompt, and close-shortcut
    confirmation timing state.
- Create: `src/renderer/overlays/confirm_modals.zig`
  - Window close, restore defaults, and transfer-cancel confirmation state.
- Create: `src/renderer/overlays/state.zig`
  - Aggregated `OverlayState`.
- Create: `src/renderer/overlays/state_guard.zig`
  - Fast source guard that prevents migrated globals from reappearing in
    `overlays.zig`.
- Create: `src/input/overlay_effect_guard.zig`
  - Fast source guard that prevents converted settings/confirm input branches
    from writing dirty globals directly.
- Modify: `src/renderer/overlays.zig`
  - Keep public facade functions; delegate state to `OverlayState`.
  - Keep large rendering helpers in the facade unless moving them is trivial.
- Modify: `src/input.zig`
  - Return `UiEffect` from converted settings and confirmation branches.
- Modify: `src/test_fast.zig`
  - Import all new pure/state/guard modules.
- Modify: `src/test_main.zig`
  - Import new modules that are not already reached through `overlays.zig`.

---

### Task 1: Add Settings Page State Model

**Files:**
- Create: `src/renderer/overlays/settings_page.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/renderer/overlays/settings_page.zig` with tests first:

```zig
const std = @import("std");
const input_key = @import("../../input/key.zig");

test "settings page state open resets focus and marks config dirty" {
    var state = State{ .visible = false, .focus = 4, .cfg_dirty = false };

    state.open();

    try std.testing.expect(state.visible);
    try std.testing.expectEqual(SETTINGS_THEME_ROW, state.focus);
    try std.testing.expect(state.cfg_dirty);
}

test "settings page key navigation wraps and returns side-effect actions" {
    var state = State{ .visible = true, .focus = 0 };

    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_up }));
    try std.testing.expectEqual(SETTINGS_ROW_COUNT - 1, state.focus);

    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_down }));
    try std.testing.expectEqual(@as(usize, 0), state.focus);

    try std.testing.expectEqual(Action.font_size_plus, state.handleKey(.{ .key = .enter }).?);
    try std.testing.expectEqual(Action.font_size_minus, state.handleKey(.{ .key = .arrow_left }).?);
    try std.testing.expectEqual(Action.close, state.handleKey(.{ .key = .escape }).?);
}

test "settings page first visible row keeps focus in short view" {
    var state = State{ .visible = true, .focus = SETTINGS_ROW_COUNT - 1 };

    const scroll = state.firstVisibleRow(3);

    try std.testing.expect(scroll <= state.focus);
    try std.testing.expect(state.focus < scroll + 3);
}
```

Register it in `src/test_fast.zig` near other overlay imports:

```zig
    _ = @import("renderer/overlays/settings_page.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `State`, `Action`, and constants are undeclared.

- [ ] **Step 3: Implement the settings state model**

Replace `src/renderer/overlays/settings_page.zig` with:

```zig
const std = @import("std");
const input_key = @import("../../input/key.zig");
const Config = @import("../../config.zig");

pub const SETTINGS_THEME_ROW: usize = 1;
pub const SETTINGS_CONTROL_ROW_START: usize = 2;
pub const SETTINGS_ROW_COUNT: usize = SETTINGS_CONTROL_ROW_START + 12;

pub const Action = enum {
    font_size_minus,
    font_size_plus,
    cycle_theme,
    cycle_theme_prev,
    cycle_cursor_style,
    toggle_cursor_blink,
    toggle_focus_follows_mouse,
    cycle_shell,
    cycle_default_ai_profile,
    cycle_default_ai_profile_prev,
    toggle_weixin_direct,
    cycle_language,
    toggle_restore_tabs,
    toggle_distill_suggest,
    open_raw_config,
    restore_defaults,
    close,
};

pub const State = struct {
    visible: bool = false,
    focus: usize = SETTINGS_THEME_ROW,
    cfg_dirty: bool = true,
    cfg_cache: Config = .{},

    pub fn open(self: *State) void {
        self.visible = true;
        self.focus = SETTINGS_THEME_ROW;
        self.cfg_dirty = true;
    }

    pub fn close(self: *State, allocator: ?std.mem.Allocator) void {
        self.visible = false;
        if (!self.cfg_dirty) {
            if (allocator) |alloc| self.cfg_cache.deinit(alloc);
            self.cfg_cache = .{};
            self.cfg_dirty = true;
        }
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (!self.cfg_dirty) self.cfg_cache.deinit(allocator);
        self.cfg_cache = .{};
        self.cfg_dirty = true;
        self.visible = false;
    }

    pub fn reloadConfig(self: *State) void {
        self.cfg_dirty = true;
    }

    pub fn cfg(self: *State, allocator: std.mem.Allocator) *Config {
        if (self.cfg_dirty) {
            self.cfg_cache.deinit(allocator);
            self.cfg_cache = Config.load(allocator) catch Config{};
            self.cfg_dirty = false;
        }
        return &self.cfg_cache;
    }

    pub fn handleKey(self: *State, ev: input_key.KeyEvent) ?Action {
        switch (ev.key) {
            .escape => return .close,
            .arrow_down, .tab => {
                self.focus = (self.focus + 1) % SETTINGS_ROW_COUNT;
                return null;
            },
            .arrow_up => {
                self.focus = if (self.focus == 0) SETTINGS_ROW_COUNT - 1 else self.focus - 1;
                return null;
            },
            .arrow_left => return self.focusLeftAction(),
            .arrow_right => return self.focusRightAction(),
            .enter => return self.focusPrimaryAction(),
            else => return null,
        }
    }

    pub fn handleScroll(self: *State, delta_y: f64) void {
        if (!self.visible) return;
        if (delta_y > 0) {
            if (self.focus > 0) self.focus -= 1;
        } else if (delta_y < 0) {
            if (self.focus + 1 < SETTINGS_ROW_COUNT) self.focus += 1;
        }
    }

    pub fn firstVisibleRow(self: *const State, visible_rows: usize) usize {
        if (visible_rows == 0 or SETTINGS_ROW_COUNT <= visible_rows) return 0;
        const focus = @min(self.focus, SETTINGS_ROW_COUNT - 1);
        if (focus < visible_rows) return 0;
        return @min(focus - visible_rows + 1, SETTINGS_ROW_COUNT - visible_rows);
    }

    pub fn focusPrimaryAction(self: *const State) ?Action {
        return switch (self.focus) {
            0 => .font_size_plus,
            SETTINGS_THEME_ROW => .cycle_theme,
            SETTINGS_CONTROL_ROW_START + 0 => .cycle_cursor_style,
            SETTINGS_CONTROL_ROW_START + 1 => .toggle_cursor_blink,
            SETTINGS_CONTROL_ROW_START + 2 => .toggle_focus_follows_mouse,
            SETTINGS_CONTROL_ROW_START + 3 => .cycle_shell,
            SETTINGS_CONTROL_ROW_START + 4 => .cycle_default_ai_profile,
            SETTINGS_CONTROL_ROW_START + 5 => .toggle_weixin_direct,
            SETTINGS_CONTROL_ROW_START + 6 => .cycle_language,
            SETTINGS_CONTROL_ROW_START + 7 => .toggle_restore_tabs,
            SETTINGS_CONTROL_ROW_START + 8 => .toggle_distill_suggest,
            SETTINGS_CONTROL_ROW_START + 9 => .open_raw_config,
            SETTINGS_CONTROL_ROW_START + 10 => .restore_defaults,
            SETTINGS_CONTROL_ROW_START + 11 => .close,
            else => null,
        };
    }

    pub fn focusLeftAction(self: *const State) ?Action {
        return switch (self.focus) {
            0 => .font_size_minus,
            SETTINGS_THEME_ROW => .cycle_theme_prev,
            SETTINGS_CONTROL_ROW_START + 4 => .cycle_default_ai_profile_prev,
            else => null,
        };
    }

    pub fn focusRightAction(self: *const State) ?Action {
        return switch (self.focus) {
            0 => .font_size_plus,
            SETTINGS_THEME_ROW => .cycle_theme,
            else => self.focusPrimaryAction(),
        };
    }
};

test "settings page state open resets focus and marks config dirty" {
    var state = State{ .visible = false, .focus = 4, .cfg_dirty = false };

    state.open();

    try std.testing.expect(state.visible);
    try std.testing.expectEqual(SETTINGS_THEME_ROW, state.focus);
    try std.testing.expect(state.cfg_dirty);
}

test "settings page key navigation wraps and returns side-effect actions" {
    var state = State{ .visible = true, .focus = 0 };

    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_up }));
    try std.testing.expectEqual(SETTINGS_ROW_COUNT - 1, state.focus);

    try std.testing.expectEqual(@as(?Action, null), state.handleKey(.{ .key = .arrow_down }));
    try std.testing.expectEqual(@as(usize, 0), state.focus);

    try std.testing.expectEqual(Action.font_size_plus, state.handleKey(.{ .key = .enter }).?);
    try std.testing.expectEqual(Action.font_size_minus, state.handleKey(.{ .key = .arrow_left }).?);
    try std.testing.expectEqual(Action.close, state.handleKey(.{ .key = .escape }).?);
}

test "settings page first visible row keeps focus in short view" {
    var state = State{ .visible = true, .focus = SETTINGS_ROW_COUNT - 1 };

    const scroll = state.firstVisibleRow(3);

    try std.testing.expect(scroll <= state.focus);
    try std.testing.expect(state.focus < scroll + 3);
}
```

- [ ] **Step 4: Run the fast suite and verify GREEN**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays/settings_page.zig src/test_fast.zig
git commit -m "refactor(overlays): add settings page state model"
```

---

### Task 2: Add Toast and Update Prompt State Model

**Files:**
- Create: `src/renderer/overlays/toasts.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/renderer/overlays/toasts.zig` with tests:

```zig
const std = @import("std");
const file_explorer = @import("../../file_explorer.zig");

test "toast state stores status text until expiration" {
    var state = State{};

    state.copy.show("Copied", 1000, 1500);

    try std.testing.expectEqualStrings("Copied", state.copy.text().?);
    try std.testing.expect(state.copy.active(2499));
    try std.testing.expect(!state.copy.active(2500));
}

test "transfer toast state tracks sticky clickable download progress" {
    var state = State{};

    state.transfer.show(.download, .in_progress, "file.txt", 1000, 2500);

    try std.testing.expect(state.transfer.sticky);
    try std.testing.expect(state.transfer.clickable);
    try std.testing.expectEqual(file_explorer.TransferStatus.in_progress, state.transfer.status);
    try std.testing.expect(state.transfer.active(9000));
}

test "update prompt state stores URL only when provided" {
    var state = State{};

    state.update.show("Update ready", "https://example.test/release", true, .open_release, 1000, 10000);

    try std.testing.expectEqualStrings("Update ready", state.update.text().?);
    try std.testing.expectEqualStrings("https://example.test/release", state.update.url().?);
    try std.testing.expect(state.update.clickable);
}
```

Register it in `src/test_fast.zig`:

```zig
    _ = @import("renderer/overlays/toasts.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `State` and toast structs are undeclared.

- [ ] **Step 3: Implement toast state**

Replace `src/renderer/overlays/toasts.zig` with:

```zig
const std = @import("std");
const file_explorer = @import("../../file_explorer.zig");
const update_prompt_model = @import("update_prompt_model.zig");
const transfer_toast_model = @import("transfer_toast_model.zig");

pub const COPY_TOAST_DURATION_MS: i64 = 1500;
pub const TRANSFER_TOAST_DURATION_MS: i64 = 2500;
pub const UPDATE_PROMPT_DURATION_MS: i64 = 10000;
pub const UPDATE_STATUS_DURATION_MS: i64 = 2500;

pub const TextToast = struct {
    until_ms: i64 = 0,
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn show(self: *TextToast, message: []const u8, now_ms: i64, duration_ms: i64) void {
        const len = @min(message.len, self.buf.len);
        @memcpy(self.buf[0..len], message[0..len]);
        self.len = len;
        self.until_ms = now_ms + duration_ms;
    }

    pub fn active(self: *const TextToast, now_ms: i64) bool {
        return self.len > 0 and now_ms < self.until_ms;
    }

    pub fn text(self: *const TextToast) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }
};

pub const TransferToast = struct {
    until_ms: i64 = 0,
    sticky: bool = false,
    status: file_explorer.TransferStatus = .idle,
    clickable: bool = false,
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn show(
        self: *TransferToast,
        kind: file_explorer.TransferKind,
        status: file_explorer.TransferStatus,
        message: []const u8,
        now_ms: i64,
        duration_ms: i64,
    ) void {
        const msg = transfer_toast_model.formatTransferToast(&self.buf, kind, status, message) catch return;
        self.len = msg.len;
        self.status = status;
        self.sticky = status == .in_progress;
        self.clickable = kind == .download and status == .in_progress;
        self.until_ms = now_ms + duration_ms;
    }

    pub fn active(self: *const TransferToast, now_ms: i64) bool {
        return self.len > 0 and (self.sticky or now_ms < self.until_ms);
    }

    pub fn text(self: *const TransferToast) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }
};

pub const UpdatePrompt = struct {
    until_ms: i64 = 0,
    buf: [128]u8 = undefined,
    len: usize = 0,
    url_buf: [256]u8 = undefined,
    url_len: usize = 0,
    clickable: bool = false,
    action: update_prompt_model.UpdatePromptAction = .none,

    pub fn show(
        self: *UpdatePrompt,
        message: []const u8,
        url: []const u8,
        clickable: bool,
        action: update_prompt_model.UpdatePromptAction,
        now_ms: i64,
        duration_ms: i64,
    ) void {
        const msg_len = @min(message.len, self.buf.len);
        @memcpy(self.buf[0..msg_len], message[0..msg_len]);
        self.len = msg_len;

        const url_len = @min(url.len, self.url_buf.len);
        if (url_len > 0) @memcpy(self.url_buf[0..url_len], url[0..url_len]);
        self.url_len = url_len;

        self.clickable = clickable;
        self.action = action;
        self.until_ms = now_ms + duration_ms;
    }

    pub fn active(self: *const UpdatePrompt, now_ms: i64) bool {
        return self.len > 0 and now_ms < self.until_ms;
    }

    pub fn text(self: *const UpdatePrompt) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }

    pub fn url(self: *const UpdatePrompt) ?[]const u8 {
        if (self.url_len == 0) return null;
        return self.url_buf[0..self.url_len];
    }
};

pub const State = struct {
    copy: TextToast = .{},
    transfer: TransferToast = .{},
    update: UpdatePrompt = .{},
    close_shortcut_confirm_until_ms: i64 = 0,
};

test "toast state stores status text until expiration" {
    var state = State{};

    state.copy.show("Copied", 1000, 1500);

    try std.testing.expectEqualStrings("Copied", state.copy.text().?);
    try std.testing.expect(state.copy.active(2499));
    try std.testing.expect(!state.copy.active(2500));
}

test "transfer toast state tracks sticky clickable download progress" {
    var state = State{};

    state.transfer.show(.download, .in_progress, "file.txt", 1000, 2500);

    try std.testing.expect(state.transfer.sticky);
    try std.testing.expect(state.transfer.clickable);
    try std.testing.expectEqual(file_explorer.TransferStatus.in_progress, state.transfer.status);
    try std.testing.expect(state.transfer.active(9000));
}

test "update prompt state stores URL only when provided" {
    var state = State{};

    state.update.show("Update ready", "https://example.test/release", true, .open_release, 1000, 10000);

    try std.testing.expectEqualStrings("Update ready", state.update.text().?);
    try std.testing.expectEqualStrings("https://example.test/release", state.update.url().?);
    try std.testing.expect(state.update.clickable);
}
```

- [ ] **Step 4: Run the fast suite and verify GREEN**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays/toasts.zig src/test_fast.zig
git commit -m "refactor(overlays): add toast state model"
```

---

### Task 3: Add Confirmation Modal State Model

**Files:**
- Create: `src/renderer/overlays/confirm_modals.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/renderer/overlays/confirm_modals.zig` with tests:

```zig
const std = @import("std");
const input_key = @import("../../input/key.zig");
const close_confirm = @import("../../close_confirm.zig");
const overlay_keys = @import("overlay_keys.zig");

test "confirm modal state maps enter to pending close action" {
    var state = State{};

    state.openCloseConfirm(.{ .tab = 2 }, .terminal_split);

    try std.testing.expect(state.window_close_visible);
    try std.testing.expectEqual(CloseKeyAction{ .close_tab = 2 }, state.handleWindowCloseKey(.{ .key = .enter }));
    try std.testing.expect(!state.window_close_visible);
}

test "restore defaults confirmation maps escape to cancel" {
    var state = State{};

    state.openRestoreDefaults();

    try std.testing.expectEqual(RestoreDefaultsAction.cancel, state.handleRestoreDefaultsKey(.{ .key = .escape }));
    try std.testing.expect(!state.restore_defaults_visible);
}

test "transfer cancel confirmation closes on interrupt" {
    var state = State{};

    state.openTransferCancel();

    try std.testing.expectEqual(overlay_keys.TransferCancelConfirmAction.interrupt, state.handleTransferCancelKey(.{ .key = .enter }));
    try std.testing.expect(!state.transfer_cancel_visible);
}
```

Register it in `src/test_fast.zig`:

```zig
    _ = @import("renderer/overlays/confirm_modals.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `State`, `CloseKeyAction`, and restore actions are undeclared.

- [ ] **Step 3: Implement confirmation modal state**

Replace `src/renderer/overlays/confirm_modals.zig` with:

```zig
const std = @import("std");
const input_key = @import("../../input/key.zig");
const close_confirm = @import("../../close_confirm.zig");
const overlay_keys = @import("overlay_keys.zig");

pub const CloseConfirmVariant = enum { running_program, window_generic, terminal_split };

pub const CloseKeyAction = union(enum) {
    none,
    close_window,
    close_focused_split,
    close_tab: usize,
};

pub const RestoreDefaultsAction = enum { none, apply, cancel };

pub const State = struct {
    transfer_cancel_visible: bool = false,
    window_close_visible: bool = false,
    close_pending: close_confirm.PendingClose = .window,
    close_variant: CloseConfirmVariant = .window_generic,
    restore_defaults_visible: bool = false,

    pub fn openCloseConfirm(self: *State, action: close_confirm.PendingClose, variant: CloseConfirmVariant) void {
        self.close_pending = action;
        self.close_variant = variant;
        self.window_close_visible = true;
    }

    pub fn closeWindowConfirm(self: *State) void {
        self.window_close_visible = false;
    }

    pub fn handleWindowCloseKey(self: *State, ev: input_key.KeyEvent) CloseKeyAction {
        if (!self.window_close_visible) return .none;
        return switch (close_confirm.keyOutcome(ev)) {
            .confirm => self.confirmClose(),
            .cancel => blk: {
                self.closeWindowConfirm();
                break :blk .none;
            },
            .none => .none,
        };
    }

    pub fn confirmClose(self: *State) CloseKeyAction {
        self.window_close_visible = false;
        return switch (self.close_pending) {
            .window => .close_window,
            .focused_split => .close_focused_split,
            .tab => |idx| .{ .close_tab = idx },
        };
    }

    pub fn openRestoreDefaults(self: *State) void {
        self.restore_defaults_visible = true;
    }

    pub fn closeRestoreDefaults(self: *State) void {
        self.restore_defaults_visible = false;
    }

    pub fn handleRestoreDefaultsKey(self: *State, ev: input_key.KeyEvent) RestoreDefaultsAction {
        if (!self.restore_defaults_visible) return .none;
        return switch (ev.key) {
            .enter => blk: {
                self.closeRestoreDefaults();
                break :blk .apply;
            },
            .escape => blk: {
                self.closeRestoreDefaults();
                break :blk .cancel;
            },
            else => .none,
        };
    }

    pub fn openTransferCancel(self: *State) void {
        self.transfer_cancel_visible = true;
    }

    pub fn closeTransferCancel(self: *State) void {
        self.transfer_cancel_visible = false;
    }

    pub fn handleTransferCancelKey(self: *State, ev: input_key.KeyEvent) overlay_keys.TransferCancelConfirmAction {
        if (!self.transfer_cancel_visible) return .none;
        const action = overlay_keys.transferCancelConfirmAction(ev);
        if (action != .none) self.closeTransferCancel();
        return action;
    }
};

test "confirm modal state maps enter to pending close action" {
    var state = State{};

    state.openCloseConfirm(.{ .tab = 2 }, .terminal_split);

    try std.testing.expect(state.window_close_visible);
    try std.testing.expectEqual(CloseKeyAction{ .close_tab = 2 }, state.handleWindowCloseKey(.{ .key = .enter }));
    try std.testing.expect(!state.window_close_visible);
}

test "restore defaults confirmation maps escape to cancel" {
    var state = State{};

    state.openRestoreDefaults();

    try std.testing.expectEqual(RestoreDefaultsAction.cancel, state.handleRestoreDefaultsKey(.{ .key = .escape }));
    try std.testing.expect(!state.restore_defaults_visible);
}

test "transfer cancel confirmation closes on interrupt" {
    var state = State{};

    state.openTransferCancel();

    try std.testing.expectEqual(overlay_keys.TransferCancelConfirmAction.interrupt, state.handleTransferCancelKey(.{ .key = .enter }));
    try std.testing.expect(!state.transfer_cancel_visible);
}
```

- [ ] **Step 4: Run the fast suite and verify GREEN**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays/confirm_modals.zig src/test_fast.zig
git commit -m "refactor(overlays): add confirmation modal state model"
```

---

### Task 4: Add Aggregated OverlayState

**Files:**
- Create: `src/renderer/overlays/state.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/renderer/overlays/state.zig`:

```zig
const std = @import("std");

test "overlay state aggregates migrated overlay groups" {
    var state = OverlayState{};

    state.settings.open();
    state.toasts.copy.show("Copied", 10, 100);
    state.confirms.openRestoreDefaults();

    try std.testing.expect(state.settings.visible);
    try std.testing.expectEqualStrings("Copied", state.toasts.copy.text().?);
    try std.testing.expect(state.confirms.restore_defaults_visible);
}
```

Register it in `src/test_fast.zig`:

```zig
    _ = @import("renderer/overlays/state.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `OverlayState` is undeclared.

- [ ] **Step 3: Implement OverlayState**

Replace `src/renderer/overlays/state.zig` with:

```zig
const std = @import("std");
const settings_page = @import("settings_page.zig");
const toasts = @import("toasts.zig");
const confirm_modals = @import("confirm_modals.zig");

pub const OverlayState = struct {
    settings: settings_page.State = .{},
    toasts: toasts.State = .{},
    confirms: confirm_modals.State = .{},

    pub fn deinit(self: *OverlayState, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
    }
};

test "overlay state aggregates migrated overlay groups" {
    var state = OverlayState{};

    state.settings.open();
    state.toasts.copy.show("Copied", 10, 100);
    state.confirms.openRestoreDefaults();

    try std.testing.expect(state.settings.visible);
    try std.testing.expectEqualStrings("Copied", state.toasts.copy.text().?);
    try std.testing.expect(state.confirms.restore_defaults_visible);
}
```

- [ ] **Step 4: Run the fast suite and verify GREEN**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays/state.zig src/test_fast.zig
git commit -m "refactor(overlays): add OverlayState aggregate"
```

---

### Task 5: Wire Settings State Through the Overlay Facade

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/input.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Add failing full-suite tests**

In `src/input.zig`, add a full-suite-only test near the existing settings page
repaint tests:

```zig
test "input: settings page dispatchKey returns repaint effect" {
    defer overlays.settingsPageClose();
    overlays.settingsPageOpen();

    const effect = dispatchKey(arrow_down_event);

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}
```

In `src/renderer/overlays.zig`, add a test near the settings tests:

```zig
test "overlays: settings page state is owned by OverlayState" {
    settingsPageOpen();
    defer settingsPageClose();

    try std.testing.expect(g_overlay_state.settings.visible);
    try std.testing.expect(settingsPageVisible());
}
```

- [ ] **Step 2: Verify RED without running the long full suite**

Run:

```bash
zig build test
```

Expected: PASS. The new tests are full-suite-only, so this command does not
compile them. Record that the RED condition is source-level: `dispatchKey`
currently returns `.none` for the settings branch.

- [ ] **Step 3: Wire settings state in `overlays.zig`**

Make these structural changes:

1. Add imports near other overlay submodule imports:

```zig
const overlay_state = @import("overlays/state.zig");
const settings_page = @import("overlays/settings_page.zig");
```

2. Add one compatibility state instance near the current top-level overlay
state declarations:

```zig
threadlocal var g_overlay_state: overlay_state.OverlayState = .{};

fn settingsState() *settings_page.State {
    return &g_overlay_state.settings;
}
```

3. Remove these globals from `overlays.zig`:

```zig
pub threadlocal var g_settings_visible: bool = false;
threadlocal var g_settings_focus: usize = SETTINGS_THEME_ROW;
threadlocal var g_settings_cfg_dirty: bool = true;
threadlocal var g_settings_cfg_cache: Config = .{};
```

4. Replace local settings constants/action type with aliases:

```zig
const SettingsAction = settings_page.Action;
const SETTINGS_THEME_ROW = settings_page.SETTINGS_THEME_ROW;
const SETTINGS_CONTROL_ROW_START = settings_page.SETTINGS_CONTROL_ROW_START;
const SETTINGS_ROW_COUNT = settings_page.SETTINGS_ROW_COUNT;
```

5. Update settings facade functions:

```zig
pub fn settingsPageVisible() bool {
    return settingsState().visible;
}

pub fn settingsPageOpen() void {
    var state = commandCenterStateSnapshot();
    state.settingsPageOpen();
    commandCenterStateCommit(state);
    settingsState().open();
    g_ai_list_mode = .manage;
}

fn settingsPageReloadCfg() void {
    settingsState().reloadConfig();
}

fn settingsCfg(allocator: std.mem.Allocator) *Config {
    return settingsState().cfg(allocator);
}

pub fn settingsPageClose() void {
    settingsState().close(AppWindow.g_allocator);
}

pub fn settingsPageHandleKey(ev: input_key.KeyEvent) AppWindow.UiEffect {
    if (!settingsPageVisible()) return .none;
    if (settingsState().handleKey(ev)) |action| executeSettingsAction(action);
    return .repaint;
}
```

6. Replace all remaining settings state references:

```text
g_settings_visible      -> settingsState().visible
g_settings_focus        -> settingsState().focus
g_settings_cfg_dirty    -> settingsState().cfg_dirty
g_settings_cfg_cache    -> settingsState().cfg_cache
settingsFirstVisibleRow -> settingsState().firstVisibleRow
```

7. Update `settingsFirstVisibleRow()` to either disappear or delegate:

```zig
fn settingsFirstVisibleRow(visible_rows: usize) usize {
    return settingsState().firstVisibleRow(visible_rows);
}
```

8. Update `settingsPageHandleScroll()`:

```zig
pub fn settingsPageHandleScroll(delta_y: f64) void {
    settingsState().handleScroll(delta_y);
}
```

- [ ] **Step 4: Update `input.zig` settings branch**

In `dispatchKey`, replace:

```zig
    if (overlays.settingsPageVisible()) {
        overlays.settingsPageHandleKey(key_event);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return .none;
    }
```

with:

```zig
    if (overlays.settingsPageVisible()) {
        return overlays.settingsPageHandleKey(key_event);
    }
```

- [ ] **Step 5: Register full-suite import**

In `src/test_main.zig`, add near other overlay module imports:

```zig
    _ = @import("renderer/overlays/settings_page.zig");
    _ = @import("renderer/overlays/state.zig");
```

- [ ] **Step 6: Run fast verification**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/renderer/overlays.zig src/input.zig src/test_main.zig
git commit -m "refactor(overlays): route settings page through OverlayState"
```

---

### Task 6: Wire Toast State Through the Overlay Facade

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Add failing full-suite tests**

In `src/renderer/overlays.zig`, add tests near existing toast tests:

```zig
test "overlays: status toast state is owned by OverlayState" {
    const saved = g_overlay_state.toasts.copy;
    defer g_overlay_state.toasts.copy = saved;

    showStatusToast("hello");

    try std.testing.expectEqualStrings("hello", g_overlay_state.toasts.copy.text().?);
}

test "overlays: transfer toast state is owned by OverlayState" {
    const saved = g_overlay_state.toasts.transfer;
    defer g_overlay_state.toasts.transfer = saved;

    showTransferToast(.download, .in_progress, "file.txt");

    try std.testing.expect(g_overlay_state.toasts.transfer.sticky);
    try std.testing.expect(g_overlay_state.toasts.transfer.clickable);
}
```

- [ ] **Step 2: Verify RED without running the long full suite**

Run:

```bash
zig build test
```

Expected: PASS. The new tests are full-suite-only. Record RED as source-level:
the toast globals still live directly in `overlays.zig`.

- [ ] **Step 3: Wire toast state**

In `src/renderer/overlays.zig`:

1. Add import:

```zig
const toasts = @import("overlays/toasts.zig");
```

2. Add helper:

```zig
fn toastState() *toasts.State {
    return &g_overlay_state.toasts;
}
```

3. Remove these globals and duration constants from `overlays.zig`:

```zig
const COPY_TOAST_DURATION_MS: i64 = 1500;
threadlocal var g_copy_toast_until_ms: i64 = 0;
threadlocal var g_copy_toast_buf: [64]u8 = undefined;
threadlocal var g_copy_toast_len: usize = 0;

const TRANSFER_TOAST_DURATION_MS: i64 = 2500;
threadlocal var g_transfer_toast_until_ms: i64 = 0;
threadlocal var g_transfer_toast_sticky: bool = false;
threadlocal var g_transfer_toast_status: AppWindow.file_explorer.TransferStatus = .idle;
threadlocal var g_transfer_toast_clickable: bool = false;
threadlocal var g_transfer_toast_buf: [160]u8 = undefined;
threadlocal var g_transfer_toast_len: usize = 0;

const UPDATE_PROMPT_DURATION_MS: i64 = 10000;
const UPDATE_STATUS_DURATION_MS: i64 = 2500;
threadlocal var g_update_prompt_until_ms: i64 = 0;
threadlocal var g_update_prompt_buf: [128]u8 = undefined;
threadlocal var g_update_prompt_len: usize = 0;
threadlocal var g_update_prompt_url_buf: [256]u8 = undefined;
threadlocal var g_update_prompt_url_len: usize = 0;
threadlocal var g_update_prompt_clickable: bool = false;
threadlocal var g_update_prompt_action: UpdatePromptAction = .none;
```

4. Update public functions:

```zig
pub fn showCopyToast(byte_count: usize) void {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d}{s}", .{ i18n.s().toast_copied_prefix, byte_count, i18n.s().toast_copied_bytes_suffix }) catch return;
    toastState().copy.show(msg, std.time.milliTimestamp(), toasts.COPY_TOAST_DURATION_MS);
}

pub fn showStatusToast(message: []const u8) void {
    toastState().copy.show(message, std.time.milliTimestamp(), toasts.COPY_TOAST_DURATION_MS);
    AppWindow.applyUiEffect(.repaint);
}

pub fn showTransferToast(
    kind: AppWindow.file_explorer.TransferKind,
    status: AppWindow.file_explorer.TransferStatus,
    message: []const u8,
) void {
    toastState().transfer.show(kind, status, message, std.time.milliTimestamp(), toasts.TRANSFER_TOAST_DURATION_MS);
    if (status != .in_progress) transferCancelConfirmClose();
}
```

5. Update update prompt functions to use `toastState().update.show(...)`.
Use `toasts.UPDATE_PROMPT_DURATION_MS` and `toasts.UPDATE_STATUS_DURATION_MS`.

6. Update render and hit-test functions:

```text
g_copy_toast_until_ms       -> toastState().copy.until_ms
g_copy_toast_buf[0..len]    -> toastState().copy.text() orelse return
g_copy_toast_len            -> toastState().copy.len
g_transfer_toast_until_ms   -> toastState().transfer.until_ms
g_transfer_toast_sticky     -> toastState().transfer.sticky
g_transfer_toast_status     -> toastState().transfer.status
g_transfer_toast_clickable  -> toastState().transfer.clickable
g_transfer_toast_buf[0..len]-> toastState().transfer.text() orelse return
g_update_prompt_until_ms    -> toastState().update.until_ms
g_update_prompt_buf[0..len] -> toastState().update.text() orelse return
g_update_prompt_len         -> toastState().update.len
g_update_prompt_url_buf     -> toastState().update.url_buf
g_update_prompt_url_len     -> toastState().update.url_len
g_update_prompt_clickable   -> toastState().update.clickable
g_update_prompt_action      -> toastState().update.action
```

- [ ] **Step 4: Update tests that saved raw globals**

Update existing overlay tests that save `g_copy_toast_*` fields to save and
restore `g_overlay_state.toasts.copy` instead:

```zig
const saved_toast = g_overlay_state.toasts.copy;
defer g_overlay_state.toasts.copy = saved_toast;
```

- [ ] **Step 5: Register full-suite import**

In `src/test_main.zig`, add near other overlay module imports:

```zig
    _ = @import("renderer/overlays/toasts.zig");
```

- [ ] **Step 6: Run fast verification**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/renderer/overlays.zig src/test_main.zig
git commit -m "refactor(overlays): route toasts through OverlayState"
```

---

### Task 7: Wire Confirmation State Through the Overlay Facade

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/input.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Add failing full-suite tests**

In `src/input.zig`, add near confirmation repaint tests:

```zig
test "input: window close confirm dispatchKey returns repaint effect" {
    defer overlays.windowCloseConfirmClose();
    overlays.closeConfirmOpen(.window, .window_generic);

    const effect = dispatchKey(.{
        .key_code = platform_input.key_escape,
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    });

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}
```

In `src/renderer/overlays.zig`, add near confirmation tests:

```zig
test "overlays: restore defaults confirm state is owned by OverlayState" {
    restoreDefaultsConfirmOpen();
    defer restoreDefaultsConfirmClose();

    try std.testing.expect(g_overlay_state.confirms.restore_defaults_visible);
    try std.testing.expect(restoreDefaultsConfirmVisible());
}
```

- [ ] **Step 2: Verify RED without running the long full suite**

Run:

```bash
zig build test
```

Expected: PASS. The new tests are full-suite-only. Record RED as source-level:
confirmation state still lives directly in `overlays.zig`, and input still
manually writes dirty globals for these branches.

- [ ] **Step 3: Wire confirmation state**

In `src/renderer/overlays.zig`:

1. Add import:

```zig
const confirm_modals = @import("overlays/confirm_modals.zig");
```

2. Replace local close confirm variant alias:

```zig
pub const CloseConfirmVariant = confirm_modals.CloseConfirmVariant;
```

3. Add helper:

```zig
fn confirmState() *confirm_modals.State {
    return &g_overlay_state.confirms;
}
```

4. Remove these globals from `overlays.zig`:

```zig
threadlocal var g_transfer_cancel_confirm_visible: bool = false;
threadlocal var g_window_close_confirm_visible: bool = false;
threadlocal var g_close_confirm_pending: close_confirm.PendingClose = .window;
threadlocal var g_close_confirm_variant: CloseConfirmVariant = .window_generic;
threadlocal var g_restore_defaults_confirm_visible: bool = false;
```

5. Add close-action executor:

```zig
fn executeCloseKeyAction(action: confirm_modals.CloseKeyAction) void {
    switch (action) {
        .none => {},
        .close_window => AppWindow.g_should_close = true,
        .close_focused_split => AppWindow.closeFocusedSplit(),
        .close_tab => |idx| AppWindow.closeTab(idx),
    }
}
```

6. Update confirmation facade functions:

```zig
pub fn closeConfirmOpen(action: close_confirm.PendingClose, variant: CloseConfirmVariant) void {
    confirmState().openCloseConfirm(action, variant);
}

pub fn windowCloseConfirmClose() void {
    confirmState().closeWindowConfirm();
}

pub fn windowCloseConfirmVisible() bool {
    return confirmState().window_close_visible;
}

pub fn windowCloseConfirmHandleKey(ev: input_key.KeyEvent) AppWindow.UiEffect {
    if (!windowCloseConfirmVisible()) return .none;
    executeCloseKeyAction(confirmState().handleWindowCloseKey(ev));
    return .repaint;
}

pub fn restoreDefaultsConfirmOpen() void {
    confirmState().openRestoreDefaults();
}

pub fn restoreDefaultsConfirmClose() void {
    confirmState().closeRestoreDefaults();
}

pub fn restoreDefaultsConfirmVisible() bool {
    return confirmState().restore_defaults_visible;
}

pub fn restoreDefaultsConfirmHandleKey(ev: input_key.KeyEvent) AppWindow.UiEffect {
    if (!restoreDefaultsConfirmVisible()) return .none;
    switch (confirmState().handleRestoreDefaultsKey(ev)) {
        .apply => restoreDefaultsConfirmApply(),
        .cancel, .none => {},
    }
    return .repaint;
}

pub fn transferCancelConfirmOpen() void {
    confirmState().openTransferCancel();
}

pub fn transferCancelConfirmClose() void {
    confirmState().closeTransferCancel();
}

pub fn transferCancelConfirmVisible() bool {
    return confirmState().transfer_cancel_visible;
}
```

7. Add a new effect-aware transfer key function while keeping the old action
function for callers that only need the action:

```zig
pub const TransferCancelKeyResult = struct {
    action: TransferCancelConfirmAction = .none,
    effect: AppWindow.UiEffect = .none,
};

pub fn transferCancelConfirmHandleKeyEffect(ev: input_key.KeyEvent) TransferCancelKeyResult {
    if (!transferCancelConfirmVisible()) return .{};
    const action = confirmState().handleTransferCancelKey(ev);
    return .{ .action = action, .effect = .repaint };
}

pub fn transferCancelConfirmHandleKey(ev: input_key.KeyEvent) TransferCancelConfirmAction {
    return transferCancelConfirmHandleKeyEffect(ev).action;
}
```

8. Replace layout/render references:

```text
g_window_close_confirm_visible      -> confirmState().window_close_visible
g_close_confirm_variant             -> confirmState().close_variant
g_restore_defaults_confirm_visible  -> confirmState().restore_defaults_visible
g_transfer_cancel_confirm_visible   -> confirmState().transfer_cancel_visible
```

- [ ] **Step 4: Update `input.zig` confirmation branches**

In `dispatchKey`, replace:

```zig
    if (overlays.windowCloseConfirmVisible()) {
        overlays.windowCloseConfirmHandleKey(key_event);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return .none;
    }
```

with:

```zig
    if (overlays.windowCloseConfirmVisible()) {
        return overlays.windowCloseConfirmHandleKey(key_event);
    }
```

Replace the transfer cancel branch with:

```zig
    if (overlays.transferCancelConfirmVisible()) {
        const result = overlays.transferCancelConfirmHandleKeyEffect(key_event);
        switch (result.action) {
            .interrupt => _ = file_explorer.cancelActiveTransfer(),
            .keep, .none => {},
        }
        return result.effect;
    }
```

Replace the restore defaults branch with:

```zig
    if (overlays.restoreDefaultsConfirmVisible()) {
        return overlays.restoreDefaultsConfirmHandleKey(key_event);
    }
```

- [ ] **Step 5: Register full-suite import**

In `src/test_main.zig`, add near other overlay module imports:

```zig
    _ = @import("renderer/overlays/confirm_modals.zig");
```

- [ ] **Step 6: Run fast verification**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/renderer/overlays.zig src/input.zig src/test_main.zig
git commit -m "refactor(overlays): route confirmations through OverlayState"
```

---

### Task 8: Add Fast Source Guards for P2.1 Boundaries

**Files:**
- Create: `src/renderer/overlays/state_guard.zig`
- Create: `src/input/overlay_effect_guard.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write overlay state guard**

Create `src/renderer/overlays/state_guard.zig`:

```zig
const std = @import("std");

test "overlays: migrated P2.1 state globals stay out of overlays facade" {
    const source = @embedFile("../overlays.zig");
    const forbidden = [_][]const u8{
        "g_settings_visible",
        "g_settings_focus",
        "g_settings_cfg_dirty",
        "g_settings_cfg_cache",
        "g_copy_toast_until_ms",
        "g_copy_toast_buf",
        "g_copy_toast_len",
        "g_transfer_toast_until_ms",
        "g_transfer_toast_sticky",
        "g_transfer_toast_status",
        "g_transfer_toast_clickable",
        "g_transfer_toast_buf",
        "g_transfer_toast_len",
        "g_update_prompt_until_ms",
        "g_update_prompt_buf",
        "g_update_prompt_len",
        "g_update_prompt_url_buf",
        "g_update_prompt_url_len",
        "g_update_prompt_clickable",
        "g_update_prompt_action",
        "g_transfer_cancel_confirm_visible",
        "g_window_close_confirm_visible",
        "g_close_confirm_pending",
        "g_close_confirm_variant",
        "g_restore_defaults_confirm_visible",
    };

    for (forbidden) |name| {
        try std.testing.expect(std.mem.indexOf(u8, source, name) == null);
    }
}
```

- [ ] **Step 2: Write input effect guard**

Create `src/input/overlay_effect_guard.zig`:

```zig
const std = @import("std");

fn branchAfter(source: []const u8, marker: []const u8, end_marker: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, source, marker) orelse return error.MissingBranch;
    const tail = source[start..];
    const end = std.mem.indexOf(u8, tail, end_marker) orelse return error.MissingBranchEnd;
    return tail[0..end];
}

test "input: converted settings and confirm branches return UiEffect instead of dirty writes" {
    const source = @embedFile("../input.zig");

    const settings_branch = try branchAfter(
        source,
        "if (overlays.settingsPageVisible()) {",
        "if (AppWindow.weixin_qr_panel.visible())",
    );
    try std.testing.expect(std.mem.indexOf(u8, settings_branch, "return overlays.settingsPageHandleKey") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings_branch, "AppWindow.g_force_rebuild") == null);
    try std.testing.expect(std.mem.indexOf(u8, settings_branch, "AppWindow.g_cells_valid") == null);

    const window_close_branch = try branchAfter(
        source,
        "if (overlays.windowCloseConfirmVisible()) {",
        "if (overlays.transferCancelConfirmVisible())",
    );
    try std.testing.expect(std.mem.indexOf(u8, window_close_branch, "return overlays.windowCloseConfirmHandleKey") != null);
    try std.testing.expect(std.mem.indexOf(u8, window_close_branch, "AppWindow.g_force_rebuild") == null);
    try std.testing.expect(std.mem.indexOf(u8, window_close_branch, "AppWindow.g_cells_valid") == null);

    const restore_branch = try branchAfter(
        source,
        "if (overlays.restoreDefaultsConfirmVisible()) {",
        "if (overlays.settingsPageVisible())",
    );
    try std.testing.expect(std.mem.indexOf(u8, restore_branch, "return overlays.restoreDefaultsConfirmHandleKey") != null);
    try std.testing.expect(std.mem.indexOf(u8, restore_branch, "AppWindow.g_force_rebuild") == null);
    try std.testing.expect(std.mem.indexOf(u8, restore_branch, "AppWindow.g_cells_valid") == null);
}
```

- [ ] **Step 3: Register guards in fast suite**

In `src/test_fast.zig`, add:

```zig
    _ = @import("renderer/overlays/state_guard.zig");
    _ = @import("input/overlay_effect_guard.zig");
```

- [ ] **Step 4: Run fast verification**

Run:

```bash
zig build test
```

Expected: PASS. If it fails, fix only the converted P2.1 branches or migrated
state globals identified by the guard.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays/state_guard.zig src/input/overlay_effect_guard.zig src/test_fast.zig
git commit -m "test(overlays): guard P2.1 overlay state boundaries"
```

---

### Task 9: Final P2.1 Verification and Handoff

**Files:**
- Modify: `docs/superpowers/specs/2026-06-24-ui-state-debt-p2-1-design.md`

- [ ] **Step 1: Run fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 2: Run full suite once**

Run:

```bash
zig build test-full
```

Expected: PASS. This is the 5-10 minute P2.1 stage gate. Do not repeat it
inside earlier tasks unless a specific integration failure needs confirmation.

- [ ] **Step 3: Run Windows checkout-safety checks**

Run the Windows checkout-safety checks documented in
`docs/development.md#windows-checkout-safety`, or an equivalent check covering:

- Windows-reserved names.
- Illegal Windows path characters.
- Trailing spaces or trailing dots.
- Case-fold collisions.
- Tracked symlinks.
- Path length.

Expected: PASS.

- [ ] **Step 4: Record line counts**

Run:

```bash
wc -l src/AppWindow.zig src/renderer/overlays.zig src/input.zig src/ai_chat.zig
```

Record the output in the P2.1 handoff note.

- [ ] **Step 5: Append P2.1 handoff note**

Append this section to
`docs/superpowers/specs/2026-06-24-ui-state-debt-p2-1-design.md` with the real
line counts from Step 4. The appended section must have this exact heading and
body text, followed by a fenced `text` block containing the exact `wc -l`
output from Step 4:

```markdown
## P2.1 handoff

P2.1 introduced `OverlayState` and moved settings, toast/update prompt, and
confirmation state behind feature-owned modules while keeping `overlays.zig` as
the compatibility facade.

Final line counts:
```

After the fenced `text` block with the line counts, add this exact closing
paragraph:

```markdown
P2.2 should start from the session launcher and profile-form state. Do not start
P2.3 AppWindow state migration until P2.2 is complete and verified.
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-06-24-ui-state-debt-p2-1-design.md
git commit -m "docs: record ui state P2.1 handoff"
```

---

## Plan Self-Review

- Spec coverage: This plan implements only P2.1. P2.2 and P2.3 are recorded as
  future stages and have no executable tasks here.
- Verification coverage: New state modules and source guards run under
  `zig build test`; `zig build test-full` is reserved for the final P2.1 gate.
- Boundary coverage: Settings, toast/update prompt, and confirmation state move
  into feature-owned modules; `overlays.zig` remains the compatibility facade.
- Ghostty alignment: The plan follows Ghostty's explicit state-owner direction
  without forcing WispTerm's callers through a repo-wide import rewrite.
