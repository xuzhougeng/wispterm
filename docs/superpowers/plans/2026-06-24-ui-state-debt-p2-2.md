# UI State Debt P2.2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move session launcher, SSH profile list/form, AI profile list/form, AI history source picker, and switch-model target state out of raw `renderer/overlays.zig` globals into feature-owned modules, preserving the facade API and converting the session-launcher input branch to `UiEffect`.

**Architecture:** P2.2 adds `ssh_profiles`, `ai_profiles`, and `session_launcher` modules under `src/renderer/overlays/`, each a default-initialized `State` struct embedded as a new field of `OverlayState`. `overlays.zig` stays the compatibility facade and keeps the `command_center_state` visibility layer, `profile_codec`, rendering, and persistence. The migrated globals collapse to `sshState().*` / `aiState().*` / `launcherState().*` accessors. The switch-model target is stored `?*anyopaque` so the launcher module stays fast-suite-safe.

**Tech Stack:** Zig, `zig build test` fast suite for leaf/state/source-guard checks, one `zig build test-full` 5-10 minute stage gate (on macOS: `zig build test-full -Dtarget=aarch64-macos` to actually run), Ghostty-aligned nested-state ownership.

---

## P2 Stage Ledger

- **P2.1 (done):** `OverlayState` plus settings, toast/update prompt, and confirmation state modules.
- **P2.2 (this plan):** session launcher, SSH list/form, AI list/form, AI history source picker, switch-model target.
- **P2.3 (future):** `AppWindow` `WindowState`, `InputState`, `RemoteState` toward the 4000-line target.

Do not start P2.3 tasks while executing this plan. P2.3 begins only after P2.2
passes final verification and is explicitly accepted.

## Verification Policy

`zig build test-full` takes 5-10 minutes. During P2.2:

- Run `zig build test` after every leaf/model/source-guard task.
- The fast suite does **not** compile `overlays.zig` / `input.zig`. Use code
  review for those wiring tasks, and run a `zig build test-full` compile check
  right after the two big mechanical renames (Tasks 5 and 6) to catch typos
  early.
- Run `zig build test-full` once at the final P2.2 gate (Task 10).

Ghostty reference: Ghostty embeds feature state as default-initialized nested
structs in `Surface.zig` (`mouse: Mouse`, `keyboard: Keyboard`) and splits
`src/input/` per concept (`mouse.zig`, `keyboard.zig`, `command.zig`). P2.2
follows that by making each launcher sub-feature a `State` struct in its own
`src/renderer/overlays/*.zig` file aggregated into `OverlayState`, while the
facade keeps rendering and persistence.

## File Structure

- Create: `src/renderer/overlays/ssh_profiles.zig`
  - SSH list + form state, `SshListMode`, focus/field/filter methods.
- Create: `src/renderer/overlays/ai_profiles.zig`
  - AI list + form state, `AiListMode`, focus/field methods.
- Create: `src/renderer/overlays/session_launcher.zig`
  - AI history source selection + switch-model target (opaque), `AiHistorySourceChoice`.
- Modify: `src/renderer/overlays/state.zig`
  - Add `ssh`, `ai`, `session` fields to `OverlayState`; heap-allocate aggregate test.
- Modify: `src/renderer/overlays/state_guard.zig`
  - Forbid the migrated globals from reappearing in `overlays.zig`.
- Modify: `src/input/overlay_effect_guard.zig`
  - Assert the converted session-launcher branch returns `UiEffect`.
- Modify: `src/renderer/overlays.zig`
  - Add `sshState()`/`aiState()`/`launcherState()`; delegate state; remove globals.
- Modify: `src/input.zig`
  - Return `UiEffect` from the session-launcher branch.
- Modify: `src/test_fast.zig`
  - Import the three new state modules.
- Modify: `src/test_main.zig`
  - Import the three new modules for the full app binary.

---

### Task 1: Add SSH Profiles State Model

**Files:**
- Create: `src/renderer/overlays/ssh_profiles.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/renderer/overlays/ssh_profiles.zig` with tests first (heap-allocated
because `State` is ~520 KB):

```zig
const std = @import("std");
const profile_codec = @import("profile_codec.zig");

test "ssh form field set/get round-trips through fixed buffers" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    state.setFormField(.name, "web-01");
    state.setFormField(.ip, "10.0.0.5");

    try std.testing.expectEqualStrings("web-01", state.formField(.name));
    try std.testing.expectEqualStrings("10.0.0.5", state.formField(.ip));
    try std.testing.expectEqualStrings("", state.formField(.user));
}

test "ssh form focus navigation wraps over field and action rows" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .focus = 0 };

    state.focusPrevRow();
    try std.testing.expectEqual(SSH_FORM_ROW_COUNT - 1, state.focus);

    state.focusNextRow();
    try std.testing.expectEqual(@as(usize, 0), state.focus);
}

test "ssh form reset clears fields and edit index" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    state.setFormField(.name, "x");
    state.focus = 4;
    state.edit_index = 7;

    state.resetForm();

    try std.testing.expectEqualStrings("", state.formField(.name));
    try std.testing.expectEqual(@intFromEnum(SshField.name), state.focus);
    try std.testing.expectEqual(SSH_PROFILE_NONE, state.edit_index);
}

test "ssh list filter accessor and clear" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    @memcpy(state.list_filter_buf[0..3], "web");
    state.list_filter_len = 3;

    try std.testing.expectEqualStrings("web", state.listFilter());
    state.clearListFilter();
    try std.testing.expectEqualStrings("", state.listFilter());
}
```

Register it in `src/test_fast.zig` near the other overlay state imports:

```zig
    _ = @import("renderer/overlays/ssh_profiles.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `State`, `SshField`, `SSH_FORM_ROW_COUNT`, and
`SSH_PROFILE_NONE` are undeclared.

- [ ] **Step 3: Implement the SSH state model**

Replace `src/renderer/overlays/ssh_profiles.zig` with (keep the tests from Step 1
at the bottom):

```zig
const std = @import("std");
const profile_codec = @import("profile_codec.zig");

pub const SSH_FIELD_COUNT = profile_codec.SSH_FIELD_COUNT;
pub const SSH_FIELD_MAX = profile_codec.SSH_FIELD_MAX;
pub const SSH_PROFILE_MAX: usize = 128;
pub const SSH_PROFILE_NONE: usize = std.math.maxInt(usize);
/// Form rows = 8 fields + 3 action rows (save+connect, save, cancel).
pub const SSH_FORM_ROW_COUNT = SSH_FIELD_COUNT + 3;
pub const SshField = profile_codec.SshField;
pub const SshProfile = profile_codec.SshProfile;

pub const SshListMode = enum {
    manage,
    edit_select,
    delete_select,
    ai_history_select,
    tmux_connect,
};

pub const State = struct {
    focus: usize = @intFromEnum(SshField.name),
    bufs: [SSH_FIELD_COUNT][SSH_FIELD_MAX]u8 = undefined,
    lens: [SSH_FIELD_COUNT]usize = .{0} ** SSH_FIELD_COUNT,
    profiles: [SSH_PROFILE_MAX]SshProfile = undefined,
    profile_count: usize = 0,
    profiles_loaded: bool = false,
    list_selected: usize = 0,
    list_mode: SshListMode = .manage,
    list_filter_buf: [SSH_FIELD_MAX]u8 = undefined,
    list_filter_len: usize = 0,
    delete_selected: [SSH_PROFILE_MAX]bool = .{false} ** SSH_PROFILE_MAX,
    edit_index: usize = SSH_PROFILE_NONE,

    pub fn formField(self: *const State, field: SshField) []const u8 {
        const idx = @intFromEnum(field);
        return self.bufs[idx][0..self.lens[idx]];
    }

    pub fn setFormField(self: *State, field: SshField, value: []const u8) void {
        const idx = @intFromEnum(field);
        const len = @min(value.len, SSH_FIELD_MAX);
        @memcpy(self.bufs[idx][0..len], value[0..len]);
        self.lens[idx] = len;
    }

    pub fn resetForm(self: *State) void {
        self.lens = .{0} ** SSH_FIELD_COUNT;
        self.focus = @intFromEnum(SshField.name);
        self.edit_index = SSH_PROFILE_NONE;
    }

    pub fn focusNextRow(self: *State) void {
        self.focus = (self.focus + 1) % SSH_FORM_ROW_COUNT;
    }

    pub fn focusPrevRow(self: *State) void {
        self.focus = if (self.focus == 0) SSH_FORM_ROW_COUNT - 1 else self.focus - 1;
    }

    pub fn listFilter(self: *const State) []const u8 {
        return self.list_filter_buf[0..self.list_filter_len];
    }

    pub fn clearListFilter(self: *State) void {
        self.list_filter_len = 0;
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
git add src/renderer/overlays/ssh_profiles.zig src/test_fast.zig
git commit -m "refactor(overlays): add SSH profiles state model"
```

---

### Task 2: Add AI Profiles State Model

**Files:**
- Create: `src/renderer/overlays/ai_profiles.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/renderer/overlays/ai_profiles.zig` with tests first:

```zig
const std = @import("std");
const profile_codec = @import("profile_codec.zig");

test "ai form field set/get round-trips through fixed buffers" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    state.setFormField(.name, "claude");
    state.setFormField(.base_url, "https://api.test");

    try std.testing.expectEqualStrings("claude", state.formField(.name));
    try std.testing.expectEqualStrings("https://api.test", state.formField(.base_url));
    try std.testing.expectEqualStrings("", state.formField(.model));
}

test "ai form focus navigation wraps over field and action rows" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .focus = 0 };

    state.focusPrevRow();
    try std.testing.expectEqual(AI_FORM_ROW_COUNT - 1, state.focus);

    state.focusNextRow();
    try std.testing.expectEqual(@as(usize, 0), state.focus);
}

test "ai form reset clears fields and edit index" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    state.setFormField(.name, "x");
    state.focus = 5;
    state.edit_index = 3;

    state.resetForm();

    try std.testing.expectEqualStrings("", state.formField(.name));
    try std.testing.expectEqual(@intFromEnum(AiField.name), state.focus);
    try std.testing.expectEqual(AI_PROFILE_NONE, state.edit_index);
}
```

Register it in `src/test_fast.zig`:

```zig
    _ = @import("renderer/overlays/ai_profiles.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `State`, `AiField`, `AI_FORM_ROW_COUNT`, and
`AI_PROFILE_NONE` are undeclared.

- [ ] **Step 3: Implement the AI state model**

Replace `src/renderer/overlays/ai_profiles.zig` with (keep Step 1 tests at the
bottom):

```zig
const std = @import("std");
const profile_codec = @import("profile_codec.zig");

pub const AI_FIELD_COUNT = profile_codec.AI_FIELD_COUNT;
pub const AI_FIELD_MAX = profile_codec.AI_FIELD_MAX;
pub const AI_PROFILE_MAX: usize = 16;
pub const AI_PROFILE_NONE: usize = std.math.maxInt(usize);
/// Form rows = 12 fields + 3 action rows (save+connect, save, cancel).
pub const AI_FORM_ROW_COUNT = AI_FIELD_COUNT + 3;
pub const AiField = profile_codec.AiField;
pub const AiProfile = profile_codec.AiProfile;

pub const AiListMode = enum {
    manage,
    edit_select,
    delete_select,
    switch_model,
};

pub const State = struct {
    focus: usize = @intFromEnum(AiField.name),
    bufs: [AI_FIELD_COUNT][AI_FIELD_MAX]u8 = undefined,
    lens: [AI_FIELD_COUNT]usize = .{0} ** AI_FIELD_COUNT,
    profiles: [AI_PROFILE_MAX]AiProfile = undefined,
    profile_count: usize = 0,
    profiles_loaded: bool = false,
    list_selected: usize = 0,
    list_mode: AiListMode = .manage,
    edit_index: usize = AI_PROFILE_NONE,

    pub fn formField(self: *const State, field: AiField) []const u8 {
        const idx = @intFromEnum(field);
        return self.bufs[idx][0..self.lens[idx]];
    }

    pub fn setFormField(self: *State, field: AiField, value: []const u8) void {
        const idx = @intFromEnum(field);
        const len = @min(value.len, AI_FIELD_MAX);
        @memcpy(self.bufs[idx][0..len], value[0..len]);
        self.lens[idx] = len;
    }

    pub fn resetForm(self: *State) void {
        self.lens = .{0} ** AI_FIELD_COUNT;
        self.focus = @intFromEnum(AiField.name);
        self.edit_index = AI_PROFILE_NONE;
    }

    pub fn focusNextRow(self: *State) void {
        self.focus = (self.focus + 1) % AI_FORM_ROW_COUNT;
    }

    pub fn focusPrevRow(self: *State) void {
        self.focus = if (self.focus == 0) AI_FORM_ROW_COUNT - 1 else self.focus - 1;
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
git add src/renderer/overlays/ai_profiles.zig src/test_fast.zig
git commit -m "refactor(overlays): add AI profiles state model"
```

---

### Task 3: Add Session Launcher Transient State Model

**Files:**
- Create: `src/renderer/overlays/session_launcher.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/renderer/overlays/session_launcher.zig` with tests first:

```zig
const std = @import("std");

test "history source navigation wraps over a dynamic row count" {
    var state = State{ .ai_history_source_selected = 0 };

    state.historySourcePrev(3);
    try std.testing.expectEqual(@as(usize, 2), state.ai_history_source_selected);

    state.historySourceNext(3);
    try std.testing.expectEqual(@as(usize, 0), state.ai_history_source_selected);

    state.historySourceNext(3);
    try std.testing.expectEqual(@as(usize, 1), state.ai_history_source_selected);
}

test "history source navigation is a no-op on an empty list" {
    var state = State{ .ai_history_source_selected = 0 };

    state.historySourceNext(0);
    state.historySourcePrev(0);

    try std.testing.expectEqual(@as(usize, 0), state.ai_history_source_selected);
}

test "switch model target stores and clears an opaque pointer" {
    var state = State{};
    var dummy: u32 = 7;

    state.switch_model_target = @ptrCast(&dummy);
    try std.testing.expect(state.switch_model_target != null);

    state.clearSwitchTarget();
    try std.testing.expect(state.switch_model_target == null);
}
```

Register it in `src/test_fast.zig`:

```zig
    _ = @import("renderer/overlays/session_launcher.zig");
```

- [ ] **Step 2: Run the fast suite and verify RED**

Run:

```bash
zig build test
```

Expected: FAIL because `State` is undeclared.

- [ ] **Step 3: Implement the launcher transient model**

Replace `src/renderer/overlays/session_launcher.zig` with (keep Step 1 tests at
the bottom):

```zig
const std = @import("std");

pub const AiHistorySourceChoice = enum { local, wsl, ssh };

/// Launcher-level transient picker state that is neither form data
/// (see `ssh_profiles` / `ai_profiles`) nor visibility (`command_center_state`).
/// `switch_model_target` is the live `ai_chat.Session` bound to a `.switch_model`
/// picker, stored opaque so this module stays compilable in the fast test suite
/// without importing the heavy `ai_chat.zig` graph; `overlays.zig` casts it.
pub const State = struct {
    ai_history_source_selected: usize = 0,
    switch_model_target: ?*anyopaque = null,

    pub fn historySourceNext(self: *State, row_count: usize) void {
        if (row_count == 0) return;
        self.ai_history_source_selected = (self.ai_history_source_selected + 1) % row_count;
    }

    pub fn historySourcePrev(self: *State, row_count: usize) void {
        if (row_count == 0) return;
        self.ai_history_source_selected = if (self.ai_history_source_selected == 0)
            row_count - 1
        else
            self.ai_history_source_selected - 1;
    }

    pub fn clearSwitchTarget(self: *State) void {
        self.switch_model_target = null;
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
git add src/renderer/overlays/session_launcher.zig src/test_fast.zig
git commit -m "refactor(overlays): add session launcher transient state model"
```

---

### Task 4: Extend OverlayState Aggregate

**Files:**
- Modify: `src/renderer/overlays/state.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Update the aggregate and its test**

Replace `src/renderer/overlays/state.zig` with:

```zig
const std = @import("std");
const settings_page = @import("settings_page.zig");
const toasts = @import("toasts.zig");
const confirm_modals = @import("confirm_modals.zig");
const ssh_profiles = @import("ssh_profiles.zig");
const ai_profiles = @import("ai_profiles.zig");
const session_launcher = @import("session_launcher.zig");

pub const OverlayState = struct {
    settings: settings_page.State = .{},
    toasts: toasts.State = .{},
    confirms: confirm_modals.State = .{},
    ssh: ssh_profiles.State = .{},
    ai: ai_profiles.State = .{},
    session: session_launcher.State = .{},

    pub fn deinit(self: *OverlayState, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
    }
};

test "overlay state aggregates migrated overlay groups" {
    // OverlayState is multi-MB (SSH/AI profile arrays); heap-allocate.
    const state = try std.testing.allocator.create(OverlayState);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    state.settings.open();
    state.toasts.copy.show("Copied", 10, 100);
    state.confirms.openRestoreDefaults();
    state.ssh.setFormField(.name, "web");
    state.ai.setFormField(.name, "claude");
    state.session.ai_history_source_selected = 2;

    try std.testing.expect(state.settings.visible);
    try std.testing.expectEqualStrings("Copied", state.toasts.copy.text().?);
    try std.testing.expect(state.confirms.restore_defaults_visible);
    try std.testing.expectEqualStrings("web", state.ssh.formField(.name));
    try std.testing.expectEqualStrings("claude", state.ai.formField(.name));
    try std.testing.expectEqual(@as(usize, 2), state.session.ai_history_source_selected);
}

test "overlay state deinit releases settings cache" {
    const state = try std.testing.allocator.create(OverlayState);
    defer std.testing.allocator.destroy(state);
    state.* = .{};

    _ = state.settings.cfg(std.testing.allocator);
    state.deinit(std.testing.allocator);
}
```

- [ ] **Step 2: Register the new modules in the full app binary**

In `src/test_main.zig`, add near the other overlay module imports:

```zig
    _ = @import("renderer/overlays/ssh_profiles.zig");
    _ = @import("renderer/overlays/ai_profiles.zig");
    _ = @import("renderer/overlays/session_launcher.zig");
```

- [ ] **Step 3: Run the fast suite and verify GREEN**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/overlays/state.zig src/test_main.zig
git commit -m "refactor(overlays): aggregate launcher state into OverlayState"
```

---

### Task 5: Wire SSH State Through the Overlay Facade

**Files:**
- Modify: `src/renderer/overlays.zig`

This is a mechanical state-ownership rename. Do all of it before compiling.

- [ ] **Step 1: Add the module import and accessor**

In `src/renderer/overlays.zig`, near the existing `const settings_page = ...`
imports and the `settingsState()` / `toastState()` / `confirmState()` helpers:

```zig
const ssh_profiles = @import("overlays/ssh_profiles.zig");

fn sshState() *ssh_profiles.State {
    return &g_overlay_state.ssh;
}
```

- [ ] **Step 2: Repoint the SSH constant/type aliases**

Replace the existing local SSH constant/type declarations (currently sourced from
`profile_codec` directly) so they resolve through the new module, and remove the
local `SshListMode` enum definition (lines ~2182-2188), replacing it with an
alias:

```zig
const SSH_FIELD_COUNT = ssh_profiles.SSH_FIELD_COUNT;
const SSH_FIELD_MAX = ssh_profiles.SSH_FIELD_MAX;
const SSH_PROFILE_MAX = ssh_profiles.SSH_PROFILE_MAX;
const SSH_PROFILE_NONE = ssh_profiles.SSH_PROFILE_NONE;
const SshField = ssh_profiles.SshField;
const SshProfile = ssh_profiles.SshProfile;
const SshListMode = ssh_profiles.SshListMode;
```

Keep `SSH_LIST_MAX_VISIBLE_ROWS` and the `profile_codec`/`SshProfile` re-exports
that other code relies on; only the SSH form/list state aliases move.

- [ ] **Step 3: Remove the migrated SSH globals**

Delete these declarations from `overlays.zig` (lines ~2243-2254):

```zig
threadlocal var g_ssh_focus: usize = @intFromEnum(SshField.name);
threadlocal var g_ssh_bufs: [SSH_FIELD_COUNT][SSH_FIELD_MAX]u8 = undefined;
threadlocal var g_ssh_lens: [SSH_FIELD_COUNT]usize = .{0} ** SSH_FIELD_COUNT;
threadlocal var g_ssh_profiles: [SSH_PROFILE_MAX]SshProfile = undefined;
threadlocal var g_ssh_profile_count: usize = 0;
threadlocal var g_ssh_profiles_loaded: bool = false;
threadlocal var g_ssh_list_selected: usize = 0;
threadlocal var g_ssh_list_mode: SshListMode = .manage;
threadlocal var g_ssh_list_filter_buf: [SSH_FIELD_MAX]u8 = undefined;
threadlocal var g_ssh_list_filter_len: usize = 0;
threadlocal var g_ssh_delete_selected: [SSH_PROFILE_MAX]bool = .{false} ** SSH_PROFILE_MAX;
threadlocal var g_ssh_edit_index: usize = SSH_PROFILE_NONE;
```

- [ ] **Step 4: Replace every reference (mechanical map)**

Replace all remaining references in `overlays.zig` with the accessor field:

```text
g_ssh_focus            -> sshState().focus
g_ssh_bufs             -> sshState().bufs
g_ssh_lens             -> sshState().lens
g_ssh_profiles         -> sshState().profiles
g_ssh_profile_count    -> sshState().profile_count
g_ssh_profiles_loaded  -> sshState().profiles_loaded
g_ssh_list_selected    -> sshState().list_selected
g_ssh_list_mode        -> sshState().list_mode
g_ssh_list_filter_buf  -> sshState().list_filter_buf
g_ssh_list_filter_len  -> sshState().list_filter_len
g_ssh_delete_selected  -> sshState().delete_selected
g_ssh_edit_index       -> sshState().edit_index
```

Then collapse the two SSH form focus-wrap sites onto the new methods:

```text
g_ssh_focus = (g_ssh_focus + 1) % (SSH_FIELD_COUNT + 3)   -> sshState().focusNextRow()
g_ssh_focus = if (g_ssh_focus == 0) SSH_FIELD_COUNT + 2 else g_ssh_focus - 1   -> sshState().focusPrevRow()
```

(`SSH_FIELD_COUNT + 2` is `SSH_FORM_ROW_COUNT - 1`; both forms are equivalent.)

- [ ] **Step 5: Update SSH overlay tests to the accessor**

Existing `overlays.zig` SSH tests (e.g. "SSH list caps visible rows", "SSH list
filter matches server name prefixes", "SSH delete picker supports multi-select",
"OpenSSH import keeps more than sixteen SSH profiles") that write the raw globals
must use `sshState().*` for the same fields. Replace each `g_ssh_X` in the test
bodies with `sshState().X` using the same map.

- [ ] **Step 6: Compile check (high-risk rename)**

Run:

```bash
zig build test-full
```

Expected: PASS (compile clean). On macOS add `-Dtarget=aarch64-macos` to also run
the native tests. If compilation fails, the failure is a missed `g_ssh_*`
reference — search `overlays.zig` for any remaining `g_ssh_` token and apply the
map.

- [ ] **Step 7: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "refactor(overlays): route SSH profile state through OverlayState"
```

---

### Task 6: Wire AI State Through the Overlay Facade

**Files:**
- Modify: `src/renderer/overlays.zig`

Same mechanical pattern as Task 5. Do all of it before compiling.

- [ ] **Step 1: Add the module import and accessor**

In `src/renderer/overlays.zig`:

```zig
const ai_profiles = @import("overlays/ai_profiles.zig");

fn aiState() *ai_profiles.State {
    return &g_overlay_state.ai;
}
```

- [ ] **Step 2: Repoint the AI constant/type aliases**

Replace the local AI constant/type declarations and remove the local
`AiListMode` enum (lines ~2190-2195), replacing it with an alias:

```zig
const AI_FIELD_COUNT = ai_profiles.AI_FIELD_COUNT;
const AI_FIELD_MAX = ai_profiles.AI_FIELD_MAX;
const AI_PROFILE_MAX = ai_profiles.AI_PROFILE_MAX;
const AI_PROFILE_NONE = ai_profiles.AI_PROFILE_NONE;
const AiField = ai_profiles.AiField;
const AiProfile = ai_profiles.AiProfile;
const AiListMode = ai_profiles.AiListMode;
```

- [ ] **Step 3: Remove the migrated AI globals**

Delete these declarations (lines ~2255-2263):

```zig
threadlocal var g_ai_focus: usize = @intFromEnum(AiField.name);
threadlocal var g_ai_bufs: [AI_FIELD_COUNT][AI_FIELD_MAX]u8 = undefined;
threadlocal var g_ai_lens: [AI_FIELD_COUNT]usize = .{0} ** AI_FIELD_COUNT;
threadlocal var g_ai_profiles: [AI_PROFILE_MAX]AiProfile = undefined;
threadlocal var g_ai_profile_count: usize = 0;
threadlocal var g_ai_profiles_loaded: bool = false;
threadlocal var g_ai_list_selected: usize = 0;
threadlocal var g_ai_list_mode: AiListMode = .manage;
threadlocal var g_ai_edit_index: usize = AI_PROFILE_NONE;
```

- [ ] **Step 4: Replace every reference (mechanical map)**

```text
g_ai_focus            -> aiState().focus
g_ai_bufs             -> aiState().bufs
g_ai_lens             -> aiState().lens
g_ai_profiles         -> aiState().profiles
g_ai_profile_count    -> aiState().profile_count
g_ai_profiles_loaded  -> aiState().profiles_loaded
g_ai_list_selected    -> aiState().list_selected
g_ai_list_mode        -> aiState().list_mode
g_ai_edit_index       -> aiState().edit_index
```

Then collapse the two AI form focus-wrap sites:

```text
g_ai_focus = (g_ai_focus + 1) % (AI_FIELD_COUNT + 3)   -> aiState().focusNextRow()
g_ai_focus = if (g_ai_focus == 0) AI_FIELD_COUNT + 2 else g_ai_focus - 1   -> aiState().focusPrevRow()
```

Note: `g_ai_list_mode` is read in `resetSessionLauncherTransientModes()` and the
switch-model flow; the rename covers those sites too.

- [ ] **Step 5: Update AI overlay tests to the accessor**

Replace `g_ai_X` with `aiState().X` in any `overlays.zig` AI profile/form test
bodies (e.g. the default-AI-profile snapshot test) using the same map.

- [ ] **Step 6: Compile check (high-risk rename)**

Run:

```bash
zig build test-full
```

Expected: PASS (compile clean; `-Dtarget=aarch64-macos` to run on macOS). On
failure, search `overlays.zig` for any remaining `g_ai_` token and apply the map.
Note `g_ai_default_name_*`, `g_ai_default_loaded`, and `g_ai_history_source_*`
are **not** in this task's map — leave them.

- [ ] **Step 7: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "refactor(overlays): route AI profile state through OverlayState"
```

---

### Task 7: Wire Launcher Transient + Switch-Model Target Through the Facade

**Files:**
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: Add the module import and accessors**

In `src/renderer/overlays.zig`:

```zig
const session_launcher = @import("overlays/session_launcher.zig");

fn launcherState() *session_launcher.State {
    return &g_overlay_state.session;
}

fn switchModelTarget() ?*AppWindow.ai_chat.Session {
    const ptr = launcherState().switch_model_target orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn setSwitchModelTarget(session: ?*AppWindow.ai_chat.Session) void {
    launcherState().switch_model_target = @ptrCast(session);
}
```

- [ ] **Step 2: Repoint the AiHistorySourceChoice alias**

Remove the local `AiHistorySourceChoice` enum (line ~2197) and alias it:

```zig
const AiHistorySourceChoice = session_launcher.AiHistorySourceChoice;
```

- [ ] **Step 3: Remove the migrated launcher globals**

Delete (lines ~2240-2242):

```zig
threadlocal var g_switch_model_target: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_history_source_selected: usize = 0;
```

(Keep `g_ai_history_source_visible` — that visibility bit is owned by
`command_center_state`, not this task.)

- [ ] **Step 4: Replace the references**

```text
g_ai_history_source_selected   -> launcherState().ai_history_source_selected
g_switch_model_target          -> (read)  switchModelTarget()
g_switch_model_target = X       -> (write) setSwitchModelTarget(X)
&g_ai_history_source_selected   -> &launcherState().ai_history_source_selected
```

Then collapse the AI history source focus-wrap site:

```text
g_ai_history_source_selected = (g_ai_history_source_selected + 1) % row_count
    -> launcherState().historySourceNext(row_count)
g_ai_history_source_selected = if (g_ai_history_source_selected == 0) row_count - 1 else g_ai_history_source_selected - 1
    -> launcherState().historySourcePrev(row_count)
```

For the `.switch_model` picker close path that previously did
`g_switch_model_target = null`, use `launcherState().clearSwitchTarget()`.

- [ ] **Step 5: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS. (This is a small, reviewable change; the SSH/AI compile gates in
Tasks 5-6 already proved the facade graph compiles. The full compile of this
change is covered by the Task 10 gate.)

- [ ] **Step 6: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "refactor(overlays): route launcher transient + switch-model target through OverlayState"
```

---

### Task 8: Convert the Session Launcher Input Branch to UiEffect

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/input.zig`

- [ ] **Step 1: Add the full-suite test for the converted branch**

In `src/input.zig`, near the existing session launcher tests (around line 391),
add:

```zig
test "input: session launcher dispatchKey returns repaint effect" {
    defer overlays.sessionLauncherClose();
    overlays.sessionLauncherOpen();

    const effect = dispatchKey(.{
        .key_code = platform_input.key_down,
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

- [ ] **Step 2: Verify RED at the source level**

Run:

```bash
zig build test
```

Expected: PASS (the new test is full-suite-only). Record RED as source-level:
`sessionLauncherHandleKey` returns `void` and the input branch manually writes
dirty globals.

- [ ] **Step 3: Wrap `sessionLauncherHandleKey` to return `UiEffect`**

In `src/renderer/overlays.zig`, rename the existing body to a private impl and
add the effect-returning public wrapper:

```zig
pub fn sessionLauncherHandleKey(ev: input_key.KeyEvent) AppWindow.UiEffect {
    sessionLauncherHandleKeyImpl(ev);
    return .repaint;
}

fn sessionLauncherHandleKeyImpl(ev: input_key.KeyEvent) void {
    // ...unchanged existing body of sessionLauncherHandleKey...
}
```

- [ ] **Step 4: Convert the `input.zig` branch**

In `src/input.zig`, replace (around lines 3022-3034):

```zig
    if (overlays.sessionLauncherVisible()) {
        if (actionIs(action, .paste)) {
            if (pasteClipboardIntoSessionLauncher()) {
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
            }
            return .none;
        }
        overlays.sessionLauncherHandleKey(key_event);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return .none;
    }
```

with:

```zig
    if (overlays.sessionLauncherVisible()) {
        if (actionIs(action, .paste)) {
            return if (pasteClipboardIntoSessionLauncher()) .repaint else .none;
        }
        return overlays.sessionLauncherHandleKey(key_event);
    }
```

- [ ] **Step 5: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS. (Full compile + the new input test run at the Task 10 gate.)

- [ ] **Step 6: Commit**

```bash
git add src/renderer/overlays.zig src/input.zig
git commit -m "refactor(overlays): route session launcher input through UiEffect"
```

---

### Task 9: Add Fast Source Guards for P2.2 Boundaries

**Files:**
- Modify: `src/renderer/overlays/state_guard.zig`
- Modify: `src/input/overlay_effect_guard.zig`

- [ ] **Step 1: Extend the overlay state guard**

In `src/renderer/overlays/state_guard.zig`, add the P2.2 globals to the
`forbidden` list (after the existing P2.1 entries, before the closing `}`):

```zig
        "g_ssh_focus",
        "g_ssh_bufs",
        "g_ssh_lens",
        "g_ssh_profiles",
        "g_ssh_profile_count",
        "g_ssh_profiles_loaded",
        "g_ssh_list_selected",
        "g_ssh_list_mode",
        "g_ssh_list_filter_buf",
        "g_ssh_list_filter_len",
        "g_ssh_delete_selected",
        "g_ssh_edit_index",
        "g_ai_focus",
        "g_ai_bufs",
        "g_ai_lens",
        "g_ai_profiles",
        "g_ai_profile_count",
        "g_ai_profiles_loaded",
        "g_ai_list_selected",
        "g_ai_list_mode",
        "g_ai_edit_index",
        "g_ai_history_source_selected",
        "g_switch_model_target",
```

Note: each forbidden entry must match a whole token. `g_ai_profile_count` is a
prefix of nothing else here, and `g_ai_profiles_loaded` / `g_ai_profiles` differ
only by suffix; `std.mem.indexOf` substring matching means `g_ai_profiles` would
also match `g_ai_profiles_loaded`. That is fine — both are forbidden. Do **not**
add `g_ai_history_source_visible` (still owned by `command_center_state`) or
`g_ai_default_*` (not migrated).

- [ ] **Step 2: Extend the input effect guard**

In `src/input/overlay_effect_guard.zig`, add a session-launcher branch assertion
inside the existing test, after the settings branch block:

```zig
    const session_launcher_branch = try branchAfter(
        source,
        "if (overlays.sessionLauncherVisible()) {",
        "if (action) |app_action| {",
    );
    try std.testing.expect(std.mem.indexOf(u8, session_launcher_branch, "return overlays.sessionLauncherHandleKey") != null);
    try expectNoManualDirtyWrites(session_launcher_branch);
```

- [ ] **Step 3: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS. If `state_guard` fails, a migrated `g_ssh_*` / `g_ai_*` /
`g_ai_history_source_selected` / `g_switch_model_target` token still lives in
`overlays.zig` — finish that rename. If `overlay_effect_guard` fails, the
session-launcher branch still writes dirty globals — finish Task 8.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/overlays/state_guard.zig src/input/overlay_effect_guard.zig
git commit -m "test(overlays): guard P2.2 launcher state boundaries"
```

---

### Task 10: Final P2.2 Verification and Handoff

**Files:**
- Modify: `docs/superpowers/specs/2026-06-24-ui-state-debt-p2-2-design.md`

- [ ] **Step 1: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 2: Run the full suite once (stage gate)**

Run:

```bash
zig build test-full
```

On macOS, run the version that actually executes the native tests:

```bash
zig build test-full -Dtarget=aarch64-macos
```

Expected: PASS. This is the 5-10 minute P2.2 stage gate. The known-flaky
"skill center tool import" FileNotFound test is unrelated (see memory).

- [ ] **Step 3: Run Windows checkout-safety checks**

Run the checks documented in `docs/development.md#windows-checkout-safety`, or an
equivalent check covering Windows-reserved names, illegal path characters,
trailing spaces/dots, case-fold collisions, tracked symlinks, and path length.
P2.2 adds three new files, so this must pass.

Expected: PASS.

- [ ] **Step 4: Record line counts**

Run:

```bash
wc -l src/AppWindow.zig src/renderer/overlays.zig src/input.zig src/ai_chat.zig
```

- [ ] **Step 5: Append the P2.2 handoff note**

Replace the placeholder `## P2.2 handoff` section at the bottom of
`docs/superpowers/specs/2026-06-24-ui-state-debt-p2-2-design.md` with:

```markdown
## P2.2 handoff

P2.2 moved session launcher, SSH list/form, AI list/form, AI history source
picker, and switch-model target state into `ssh_profiles.zig`, `ai_profiles.zig`,
and `session_launcher.zig`, aggregated under `OverlayState`, while keeping
`overlays.zig` the compatibility facade and the `command_center_state` visibility
layer unchanged. The session-launcher input branch now returns `UiEffect`.

Final line counts:
```

Follow it with a fenced `text` block containing the exact `wc -l` output from
Step 4, then this closing paragraph:

```markdown
P2.3 starts the AppWindow `WindowState` / `InputState` / `RemoteState` migration.
Do not start P2.3 until P2.2 is accepted. The SSH password-prompt side channel
(`g_pending_ssh_password*`, `g_pending_ssh_surface`) was deliberately left in
`overlays.zig` and is a candidate for a later slice.
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-06-24-ui-state-debt-p2-2-design.md
git commit -m "docs: record ui state P2.2 handoff"
```

---

## Plan Self-Review

- **Spec coverage:** Tasks 1-3 create the three modules named in the design's
  Target Modules. Task 4 aggregates them. Tasks 5-7 remove every global in the
  design's Current State Inventory (SSH, AI, AI-history-source, switch-model
  target). Task 8 converts the input branch to `UiEffect`. Task 9 guards both
  boundaries. Task 10 is the gate + handoff. The `g_pending_ssh_password*`
  non-goal is explicitly excluded in Tasks 6 and 10.
- **Placeholder scan:** Leaf modules (Tasks 1-3) carry complete code and tests.
  Wiring tasks (5-7) use exact rename maps and exact globals-to-remove lists.
  Task 8 shows the exact before/after. Task 9 shows the exact guard entries.
- **Type consistency:** `sshState()`/`aiState()`/`launcherState()` return the
  module `*State`. Method names (`formField`, `setFormField`, `focusNextRow`,
  `focusPrevRow`, `resetForm`, `listFilter`, `clearListFilter`,
  `historySourceNext`, `historySourcePrev`, `clearSwitchTarget`) match between
  the module definitions (Tasks 1-3), the aggregate test (Task 4), and the wiring
  maps (Tasks 5-7). `SSH_FORM_ROW_COUNT` / `AI_FORM_ROW_COUNT` equal
  `FIELD_COUNT + 3`, matching the existing `% (FIELD_COUNT + 3)` arithmetic.
- **Verification coverage:** New modules and guards run under `zig build test`;
  the two high-risk renames add a `zig build test-full` compile check; the final
  gate runs the full suite once.
- **Ghostty alignment:** Nested default-initialized `State` structs in
  `OverlayState` mirror Ghostty's `Surface { mouse: Mouse, keyboard: Keyboard }`;
  per-feature files mirror `src/input/*.zig`; the `?*anyopaque` switch-model
  target is the WispTerm-specific accommodation for the fast/full test split,
  documented in the design.
