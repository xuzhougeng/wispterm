# UI State Debt P1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first safe seam for UI invalidation by introducing `UiEffect`, routing command-palette input through it, and keeping existing overlay repaint regressions green.

**Architecture:** P1 adds a small leaf `UiEffect` module, an `AppWindow.applyUiEffect` bridge that maps effects to the legacy dirty globals, and a focused command-palette input decision module. `input.zig` keeps its public event-processing surface but starts returning effects for the command palette path while legacy branches continue to work until P2.

**Tech Stack:** Zig, existing `zig build test` fast suite, existing `zig build test-full` full app suite, Ghostty-aligned explicit input-effect pattern.

---

## Scope

This plan implements P1 only. It does not try to reduce `AppWindow.zig` below
4000 lines yet. P2 should be planned after this lands, because P2 depends on
the `UiEffect` seam and the command-palette split pattern established here.

## Verification Adjustment

`zig build test-full` is currently very slow because it rebuilds the full
Windows-target app test binary. During P1 execution, use `zig build test` for
leaf/model tasks and code review for AppWindow/input integration tasks. Treat
`zig build test-full` as the final P1 gate, or run it only when a specific
integration risk justifies the time. This preserves the pre-merge gate while
keeping the task loop fast enough to make progress.

Where a check is static and does not need the full app binary, move it into the
fast suite. In particular, the command-palette source guard in Task 6 should be
implemented as a leaf fast test rather than another `input.zig` full-suite-only
test.

Ghostty reference: Ghostty's `Surface` owns per-surface input/renderer state and
uses explicit input outcomes such as `InputEffect`. WispTerm's P1 mirrors that
direction by making input handlers return `UiEffect` instead of requiring each
call site to know the dirty globals.

## File Structure

- Create: `src/appwindow/ui_effect.zig`
  - Leaf effect type with merge helpers and tests. Imported by fast and full
    suites.
- Create: `src/renderer/overlays/command_palette_input.zig`
  - Pure command-palette key/char decision module. It returns actions plus
    `UiEffect` and does not import `AppWindow.zig`.
- Modify: `src/AppWindow.zig`
  - Re-export `UiEffect`, add `applyUiEffect`, and route `markUiDirty()` through
    the new bridge.
- Modify: `src/input.zig`
  - Add `dispatchKey` / `dispatchChar` for the converted command-palette path.
  - Keep legacy handling for unconverted branches.
  - Apply effects through `AppWindow.applyUiEffect`.
- Modify: `src/test_fast.zig`
  - Import `appwindow/ui_effect.zig` and
    `renderer/overlays/command_palette_input.zig`.
- Modify: `src/test_main.zig`
  - Import `renderer/overlays/command_palette_input.zig` for full-suite compile
    coverage.
- No README shortcut updates are required because shortcuts do not change.

---

### Task 1: Add `UiEffect` Leaf Module

**Files:**
- Create: `src/appwindow/ui_effect.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/appwindow/ui_effect.zig` with tests that reference the not-yet
defined `UiEffect`:

```zig
const std = @import("std");

test "ui effect repaint requests consumed rebuild and cell invalidation" {
    const effect = UiEffect.repaint;
    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
    try std.testing.expect(!effect.wake_backend);
}

test "ui effect merge keeps every requested flag" {
    const merged = UiEffect.consumed_only.merge(.{
        .needs_rebuild = true,
        .wake_backend = true,
    });

    try std.testing.expect(merged.consumed);
    try std.testing.expect(merged.needs_rebuild);
    try std.testing.expect(!merged.cells_invalid);
    try std.testing.expect(merged.wake_backend);
}
```

Add this import to the existing aggregate `test` block in `src/test_fast.zig`
near the other `appwindow/*` imports:

```zig
    _ = @import("appwindow/ui_effect.zig");
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
zig build test
```

Expected: FAIL because `UiEffect` is undeclared in
`src/appwindow/ui_effect.zig`.

- [ ] **Step 3: Implement the minimal effect type**

Replace `src/appwindow/ui_effect.zig` with:

```zig
const std = @import("std");

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

test "ui effect repaint requests consumed rebuild and cell invalidation" {
    const effect = UiEffect.repaint;
    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
    try std.testing.expect(!effect.wake_backend);
}

test "ui effect merge keeps every requested flag" {
    const merged = UiEffect.consumed_only.merge(.{
        .needs_rebuild = true,
        .wake_backend = true,
    });

    try std.testing.expect(merged.consumed);
    try std.testing.expect(merged.needs_rebuild);
    try std.testing.expect(!merged.cells_invalid);
    try std.testing.expect(merged.wake_backend);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/ui_effect.zig src/test_fast.zig
git commit -m "refactor(ui): add UiEffect model"
```

---

### Task 2: Add the AppWindow Effect Bridge

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Write the failing bridge tests**

Add these tests near the existing `AppWindow` dirty-flag tests in
`src/AppWindow.zig`:

```zig
test "AppWindow: applyUiEffect maps repaint to dirty globals" {
    const previous_force_rebuild = g_force_rebuild;
    const previous_cells_valid = g_cells_valid;
    defer {
        g_force_rebuild = previous_force_rebuild;
        g_cells_valid = previous_cells_valid;
    }

    g_force_rebuild = false;
    g_cells_valid = true;

    applyUiEffect(UiEffect.repaint);

    try std.testing.expect(g_force_rebuild);
    try std.testing.expect(!g_cells_valid);
}

test "AppWindow: applyUiEffect none leaves dirty globals unchanged" {
    const previous_force_rebuild = g_force_rebuild;
    const previous_cells_valid = g_cells_valid;
    defer {
        g_force_rebuild = previous_force_rebuild;
        g_cells_valid = previous_cells_valid;
    }

    g_force_rebuild = false;
    g_cells_valid = true;

    applyUiEffect(UiEffect.none);

    try std.testing.expect(!g_force_rebuild);
    try std.testing.expect(g_cells_valid);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
zig build test-full
```

Expected: FAIL because `UiEffect` or `applyUiEffect` is not yet declared in
`AppWindow.zig`.

- [ ] **Step 3: Implement the bridge**

Add this import near the existing `appwindow/*` imports in `src/AppWindow.zig`:

```zig
const ui_effect = @import("appwindow/ui_effect.zig");
pub const UiEffect = ui_effect.UiEffect;
```

Add this public bridge near `markUiDirty()`:

```zig
pub fn applyUiEffect(effect: UiEffect) void {
    if (effect.needs_rebuild) g_force_rebuild = true;
    if (effect.cells_invalid) g_cells_valid = false;
    if (effect.wake_backend) window_backend.postWakeup();
}
```

Change `markUiDirty()` to:

```zig
fn markUiDirty() void {
    applyUiEffect(.repaint);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
zig build test-full
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig
git commit -m "refactor(ui): centralize AppWindow effect application"
```

---

### Task 3: Add Command Palette Input Decisions

**Files:**
- Create: `src/renderer/overlays/command_palette_input.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write the failing command-palette input tests**

Create `src/renderer/overlays/command_palette_input.zig` with tests that
reference the not-yet defined API:

```zig
const std = @import("std");
const platform_input = @import("../../platform/input_events.zig");

test "command palette input maps arrow down to repainting move action" {
    const action = keyAction(.{
        .key_code = platform_input.key_down,
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    }, false);

    try std.testing.expectEqual(Action.move_down, action);
    const effect = effectForAction(action);
    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "command palette input maps history escape to leave history" {
    const action = keyAction(.{
        .key_code = platform_input.key_escape,
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    }, true);

    try std.testing.expectEqual(Action.leave_history, action);
    try std.testing.expect(effectForAction(action).needs_rebuild);
}

test "command palette char input repaints only for plain text" {
    try std.testing.expect(charEffect(.{ .codepoint = 'a', .ctrl = false, .alt = false }).needs_rebuild);
    try std.testing.expect(!charEffect(.{ .codepoint = 'a', .ctrl = true, .alt = false }).needs_rebuild);
    try std.testing.expect(!charEffect(.{ .codepoint = 'a', .ctrl = false, .alt = true }).needs_rebuild);
}
```

Add this import to the aggregate `test` block in `src/test_fast.zig` near the
other overlay model imports:

```zig
    _ = @import("renderer/overlays/command_palette_input.zig");
```

Add this import to the aggregate `test` block in `src/test_main.zig` near
`renderer/overlays.zig`:

```zig
    _ = @import("renderer/overlays/command_palette_input.zig");
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
zig build test
```

Expected: FAIL because `Action`, `keyAction`, `effectForAction`, and
`charEffect` are not yet declared.

- [ ] **Step 3: Implement command-palette input decisions**

Replace `src/renderer/overlays/command_palette_input.zig` with:

```zig
const std = @import("std");
const ui_effect = @import("../../appwindow/ui_effect.zig");
const platform_input = @import("../../platform/input_events.zig");

pub const Action = enum {
    noop,
    close,
    leave_history,
    move_up,
    move_down,
    execute,
    backspace,
    clear_filter,
    delete_history,
    cycle_history_source,
};

pub fn keyAction(ev: platform_input.KeyEvent, history_visible: bool) Action {
    if (history_visible) {
        return switch (ev.key_code) {
            platform_input.key_escape => .leave_history,
            platform_input.key_up => .move_up,
            platform_input.key_down => .move_down,
            platform_input.key_enter => .execute,
            platform_input.key_delete => .delete_history,
            platform_input.key_backspace => .backspace,
            platform_input.key_tab => .cycle_history_source,
            else => .noop,
        };
    }

    return switch (ev.key_code) {
        platform_input.key_escape => .close,
        platform_input.key_up => .move_up,
        platform_input.key_down => .move_down,
        platform_input.key_enter => .execute,
        platform_input.key_backspace => .backspace,
        platform_input.key_delete => .clear_filter,
        else => .noop,
    };
}

pub fn effectForAction(action: Action) ui_effect.UiEffect {
    _ = action;
    // Preserve current behavior: while the command palette is visible, key
    // events are consumed and request a repaint even when the key maps to no
    // state mutation.
    return .repaint;
}

pub fn charEffect(ev: platform_input.CharEvent) ui_effect.UiEffect {
    if (ev.ctrl or ev.alt) return .consumed_only;
    return .repaint;
}

test "command palette input maps arrow down to repainting move action" {
    const action = keyAction(.{
        .key_code = platform_input.key_down,
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    }, false);

    try std.testing.expectEqual(Action.move_down, action);
    const effect = effectForAction(action);
    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "command palette input maps history escape to leave history" {
    const action = keyAction(.{
        .key_code = platform_input.key_escape,
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    }, true);

    try std.testing.expectEqual(Action.leave_history, action);
    try std.testing.expect(effectForAction(action).needs_rebuild);
}

test "command palette char input repaints only for plain text" {
    try std.testing.expect(charEffect(.{ .codepoint = 'a', .ctrl = false, .alt = false }).needs_rebuild);
    try std.testing.expect(!charEffect(.{ .codepoint = 'a', .ctrl = true, .alt = false }).needs_rebuild);
    try std.testing.expect(!charEffect(.{ .codepoint = 'a', .ctrl = false, .alt = true }).needs_rebuild);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
zig build test
zig build test-full
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays/command_palette_input.zig src/test_fast.zig src/test_main.zig
git commit -m "refactor(overlays): add command palette input model"
```

---

### Task 4: Route Command Palette Key Input Through `UiEffect`

**Files:**
- Modify: `src/input.zig`

- [ ] **Step 1: Write the failing dispatch tests**

Add these tests near the existing command palette repaint tests in
`src/input.zig`:

```zig
test "input: command palette dispatchKey returns repaint effect" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.commandPaletteClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.commandPaletteOpen();

    const effect = dispatchKey(arrow_down_event);

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "input: command palette dispatchKey preserves repaint for unmapped palette keys" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.commandPaletteClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.commandPaletteOpen();

    const effect = dispatchKey(.{
        .key_code = 0x5A,
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

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
zig build test-full
```

Expected: FAIL because `dispatchKey` is not yet declared.

- [ ] **Step 3: Implement the command-palette key effect path**

Add imports near the other input helper imports in `src/input.zig`:

```zig
const ui_effect = @import("appwindow/ui_effect.zig");
const command_palette_input = @import("renderer/overlays/command_palette_input.zig");
```

Add this helper before `handleKey`:

```zig
fn applyCommandPaletteAction(action: command_palette_input.Action, history_visible: bool) void {
    switch (action) {
        .noop => {},
        .close => overlays.commandPaletteClose(),
        .leave_history => overlays.commandPaletteLeaveAgentHistory(),
        .move_up => if (history_visible) overlays.commandPaletteMoveAgentHistory(-1) else overlays.commandPaletteMove(-1),
        .move_down => if (history_visible) overlays.commandPaletteMoveAgentHistory(1) else overlays.commandPaletteMove(1),
        .execute => overlays.commandPaletteExecuteSelected(),
        .backspace => overlays.commandPaletteBackspace(),
        .clear_filter => overlays.commandPaletteClearFilter(),
        .delete_history => _ = overlays.commandPaletteDeleteSelectedAgentHistory(),
        .cycle_history_source => overlays.commandPaletteCycleHistorySource(),
    }
}
```

Refactor `handleKey` so it becomes a thin applier:

```zig
fn handleKey(ev: platform_input.KeyEvent) void {
    AppWindow.applyUiEffect(dispatchKey(ev));
}
```

Create `dispatchKey` immediately after `handleKey` and move the current
`handleKey` body into it. Change the command-palette branch inside the moved
body to this exact block:

```zig
    if (overlays.commandPaletteVisible()) {
        const history_visible = overlays.commandPaletteAgentHistoryVisible();
        const palette_action = command_palette_input.keyAction(ev, history_visible);
        applyCommandPaletteAction(palette_action, history_visible);
        return command_palette_input.effectForAction(palette_action);
    }
```

For all existing `return;` statements in the moved `dispatchKey` body that are
not part of the command-palette branch, return `.none` after preserving the
existing side effects. For example, an existing block like:

```zig
    if (overlays.settingsPageVisible()) {
        overlays.settingsPageHandleKey(key_event);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
```

becomes:

```zig
    if (overlays.settingsPageVisible()) {
        overlays.settingsPageHandleKey(key_event);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return .none;
    }
```

The final signature must be:

```zig
fn dispatchKey(ev: platform_input.KeyEvent) ui_effect.UiEffect {
    // moved body from old handleKey, with returns changed to UiEffect values
}
```

End the function with:

```zig
    return .none;
```

- [ ] **Step 4: Run targeted tests**

Run:

```bash
zig build test-full
```

Expected: PASS. The existing command palette tests still pass, and the new
`dispatchKey` tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/input.zig
git commit -m "refactor(input): return command palette key effects"
```

---

### Task 5: Route Command Palette Text Input Through `UiEffect`

**Files:**
- Modify: `src/input.zig`

- [ ] **Step 1: Write the failing dispatch-char tests**

Add these tests near the existing command palette text-filter repaint test in
`src/input.zig`:

```zig
test "input: command palette dispatchChar returns repaint effect for text filtering" {
    defer overlays.commandPaletteClose();
    overlays.commandPaletteOpen();

    const effect = dispatchChar(.{ .codepoint = 'a' });

    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "input: command palette dispatchChar consumes ctrl text without repaint" {
    defer overlays.commandPaletteClose();
    overlays.commandPaletteOpen();

    const effect = dispatchChar(.{ .codepoint = 'a', .ctrl = true, .alt = false });

    try std.testing.expect(effect.consumed);
    try std.testing.expect(!effect.needs_rebuild);
    try std.testing.expect(!effect.cells_invalid);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
zig build test-full
```

Expected: FAIL because `dispatchChar` is not yet declared.

- [ ] **Step 3: Implement the command-palette char effect path**

Refactor `handleChar` so it becomes a thin applier:

```zig
fn handleChar(ev: platform_input.CharEvent) void {
    AppWindow.applyUiEffect(dispatchChar(ev));
}
```

Create `dispatchChar` immediately after `handleChar` and move the current
`handleChar` body into it. Change the command-palette branch inside the moved
body to this exact block:

```zig
    if (overlays.commandPaletteVisible()) {
        const effect = command_palette_input.charEffect(ev);
        if (effect.needs_rebuild) overlays.commandPaletteInsertChar(ev.codepoint);
        return effect;
    }
```

For all existing `return;` statements in the moved `dispatchChar` body that are
not part of the command-palette branch, return `.none` after preserving the
existing side effects. For example:

```zig
    if (weixinQrPanelConsumesChar()) return .none;
```

The final signature must be:

```zig
fn dispatchChar(ev: platform_input.CharEvent) ui_effect.UiEffect {
    // moved body from old handleChar, with returns changed to UiEffect values
}
```

End the function with:

```zig
    return .none;
```

- [ ] **Step 4: Run targeted tests**

Run:

```bash
zig build test-full
```

Expected: PASS. Existing command palette text filtering still requests repaint.

- [ ] **Step 5: Commit**

```bash
git add src/input.zig
git commit -m "refactor(input): return command palette char effects"
```

---

### Task 6: Remove Direct Dirty Writes From the Converted Command Palette Branches

**Files:**
- Create: `src/input/command_palette_effect_guard.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Add a source guard for the converted branches**

Create `src/input/command_palette_effect_guard.zig` and register it in
`src/test_fast.zig` near the other input/helper imports. The guard reads
`../input.zig` directly so it can run in the fast suite without compiling the
full app input module:

```zig
const std = @import("std");

test "input: command palette dispatch branches use UiEffect instead of direct dirty writes" {
    const source = @embedFile("../input.zig");
    const key_marker = "command_palette_input.keyAction";
    const key_action_start = std.mem.indexOf(u8, source, key_marker) orelse return error.MissingCommandPaletteBranch;
    const key_branch_marker = "if (overlays.commandPaletteVisible()) {";
    const key_start = std.mem.lastIndexOf(u8, source[0..key_action_start], key_branch_marker) orelse return error.MissingCommandPaletteBranch;
    const key_tail = source[key_start..];
    const key_end = std.mem.indexOf(u8, key_tail, "if (copilot_picker.isVisible())") orelse return error.MissingCommandPaletteBranchEnd;
    const key_branch = key_tail[0..key_end];

    try std.testing.expect(std.mem.indexOf(u8, key_branch, "command_palette_input.keyAction") != null);
    try std.testing.expect(std.mem.indexOf(u8, key_branch, "AppWindow.g_force_rebuild") == null);
    try std.testing.expect(std.mem.indexOf(u8, key_branch, "AppWindow.g_cells_valid") == null);

    const char_marker = "const effect = command_palette_input.charEffect(ev);";
    const char_start = std.mem.indexOf(u8, source, char_marker) orelse return error.MissingCommandPaletteCharBranch;
    const char_tail = source[char_start..];
    const char_end = std.mem.indexOf(u8, char_tail, "if (weixinQrPanelConsumesChar())") orelse return error.MissingCommandPaletteCharBranchEnd;
    const char_branch = char_tail[0..char_end];

    try std.testing.expect(std.mem.indexOf(u8, char_branch, "AppWindow.g_force_rebuild") == null);
    try std.testing.expect(std.mem.indexOf(u8, char_branch, "AppWindow.g_cells_valid") == null);
}
```

- [ ] **Step 2: Run the guard**

Run:

```bash
zig build test
```

Expected: PASS if Tasks 4 and 5 removed direct dirty writes from the converted
command-palette branches. If it fails, remove only the direct dirty writes in
those converted command-palette branches and keep the `UiEffect` return path.

- [ ] **Step 3: Verify manual grep output is scoped**

Run:

```bash
rg -n "command_palette_input|AppWindow\\.g_force_rebuild|AppWindow\\.g_cells_valid" src/input.zig
```

Expected: `command_palette_input` appears in the converted command-palette
branches. Direct `AppWindow.g_force_rebuild` and `AppWindow.g_cells_valid`
writes may still appear in unconverted legacy branches, but not inside the
command-palette key or char branches guarded by the new source test.

- [ ] **Step 4: Commit**

```bash
git add src/input/command_palette_effect_guard.zig src/test_fast.zig
git commit -m "test(input): guard command palette effect dispatch"
```

---

### Task 7: Final P1 Verification

**Files:**
- No code changes expected.

- [ ] **Step 1: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 2: Run the full suite**

Run:

```bash
zig build test-full
```

Expected: PASS.

- [ ] **Step 3: Check Windows checkout safety because files were added**

Run the Windows checkout-safety command documented in
`docs/development.md#windows-checkout-safety`. At minimum, confirm the documented
checks cover reserved names, illegal characters, case-fold collisions,
symlinks, and path length for:

```text
src/appwindow/ui_effect.zig
src/renderer/overlays/command_palette_input.zig
docs/superpowers/plans/2026-06-24-ui-state-debt-p1.md
```

Expected: PASS with no unsafe paths reported.

- [ ] **Step 4: Record P2 handoff notes**

Append this short handoff section to
`docs/superpowers/specs/2026-06-24-ui-state-debt-design.md`:

```markdown
## P1 handoff

P1 introduced `UiEffect`, `AppWindow.applyUiEffect`, and the command-palette
input-effect sample. P2 should split settings/toasts/session launcher next,
then migrate state into `WindowState`, `OverlayState`, and `InputState`.
```

- [ ] **Step 5: Commit the handoff note**

```bash
git add docs/superpowers/specs/2026-06-24-ui-state-debt-design.md
git commit -m "docs: record ui state P1 handoff"
```

---

## Plan Self-Review

- Spec coverage: P1 covers the explicit `UiEffect` path, a command-palette
  overlay sample, fast/full test registration, and preservation of existing
  repaint regressions. P2 file-size reduction is intentionally deferred to a
  follow-up plan after P1 creates the seam.
- Placeholder scan: this plan contains concrete paths, snippets, commands, and
  expected outcomes for every task.
- Type consistency: `UiEffect`, `applyUiEffect`, `dispatchKey`,
  `dispatchChar`, `command_palette_input.Action`, `keyAction`,
  `effectForAction`, and `charEffect` use consistent names across tasks.
