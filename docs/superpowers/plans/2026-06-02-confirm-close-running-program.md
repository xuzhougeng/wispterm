# Confirm Close With Running Program — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prompt the user to confirm before closing a terminal surface that is running a full-screen program (claude code, codex, vim, etc.), on all three close gestures: Ctrl+Shift+W, the window close (X) button, and a tab's × / middle-click.

**Architecture:** Detection uses the terminal's alternate-screen flag (`surface.terminal.screens.active_key == .alternate`) — authoritative for "a full-screen program is running," no per-tool heuristics. A new pure module `src/close_confirm.zig` holds the testable decision logic (key→action mapping, the toggle gate, and the `PendingClose` action type). The existing window-close confirm modal in `renderer/overlays.zig` is generalized to carry a `PendingClose` action plus a message variant, and all three close paths route through it. A config toggle `confirm-close-running-program` (default `true`) gates the feature.

**Tech Stack:** Zig, ghostty-vt terminal library, custom GL overlay renderer. Tests: `zig build test` (fast native unit suite) and `zig build test-full` (full app graph).

---

## File Structure

- **Create** `src/close_confirm.zig` — pure logic: `PendingClose` union, `KeyOutcome` enum, `keyOutcome(ev)`, `shouldConfirm(enabled, running)`. Imports only `input/key.zig`. Unit-tested in the fast suite.
- **Modify** `src/config.zig` — add the `confirm-close-running-program` bool field (default `true`).
- **Modify** `src/AppWindow.zig` — cached config global + apply; detection helpers (`activeSurfaceHasRunningProgram`, `tabHasRunningProgram`, `anyTabHasRunningProgram`); rewire the window-X main-loop block.
- **Modify** `src/renderer/overlays.zig` — generalize the confirm overlay: pending-action + variant state, `closeConfirmOpen`, `closeConfirmConfirm`, rewire `windowCloseConfirmHandleKey` / `windowCloseConfirmExecuteAt`, variant-driven text in `renderWindowCloseConfirm`.
- **Modify** `src/renderer/overlay_keys.zig` — remove the now-obsolete `windowCloseConfirmDismisses` + its test (logic moves to `close_confirm.keyOutcome`).
- **Modify** `src/input.zig` — gate `closePanelOrTab()` (Ctrl+Shift+W) and the two tab-close gestures (middle-click, close-button release) on the running-program check.
- **Modify** `src/test_fast.zig` and `src/test_main.zig` — register `close_confirm.zig`.

---

## Task 1: Pure decision module `close_confirm.zig`

**Files:**
- Create: `src/close_confirm.zig`
- Modify: `src/test_fast.zig` (add import in the `test { ... }` block)
- Modify: `src/test_main.zig` (add import near line 706, alongside `overlay_keys.zig`)

- [ ] **Step 1: Write the module with failing tests**

Create `src/close_confirm.zig`:

```zig
//! Pure decision logic for "confirm before closing a surface that is running a
//! full-screen program." Kept free of the app graph so it runs in the fast
//! unit-test suite. Wiring (overlay state, AppWindow globals) lives in
//! overlays.zig / input.zig / AppWindow.zig.

const std = @import("std");
const input_key = @import("input/key.zig");

/// What a confirmed close should actually do. Carried by the confirm overlay
/// so a single modal can serve all three close gestures.
pub const PendingClose = union(enum) {
    /// Close the whole window (sets AppWindow.g_should_close).
    window,
    /// Close the focused split (AppWindow.closeFocusedSplit).
    focused_split,
    /// Close a specific tab by index (AppWindow.closeTab).
    tab: usize,
};

/// Result of a key press while the confirm modal is open.
pub const KeyOutcome = enum { none, confirm, cancel };

/// Enter confirms the close; Esc cancels; everything else is ignored.
pub fn keyOutcome(ev: input_key.KeyEvent) KeyOutcome {
    return switch (ev.key) {
        .enter => .confirm,
        .escape => .cancel,
        else => .none,
    };
}

/// Whether a close gesture on a surface should prompt: only when the feature is
/// enabled AND a full-screen program is running in the target surface(s).
pub fn shouldConfirm(feature_enabled: bool, running_program: bool) bool {
    return feature_enabled and running_program;
}

test "keyOutcome maps Enter to confirm and Esc to cancel" {
    try std.testing.expectEqual(KeyOutcome.confirm, keyOutcome(.{ .key = .enter }));
    try std.testing.expectEqual(KeyOutcome.cancel, keyOutcome(.{ .key = .escape }));
    try std.testing.expectEqual(KeyOutcome.none, keyOutcome(.{ .key = .tab }));
}

test "shouldConfirm requires both the toggle and a running program" {
    try std.testing.expect(shouldConfirm(true, true));
    try std.testing.expect(!shouldConfirm(false, true));
    try std.testing.expect(!shouldConfirm(true, false));
    try std.testing.expect(!shouldConfirm(false, false));
}
```

- [ ] **Step 2: Register in the fast suite**

In `src/test_fast.zig`, inside the `test {` block (after line `_ = @import("renderer/overlays/update_prompt_model.zig");`), add:

```zig
    _ = @import("close_confirm.zig");
```

- [ ] **Step 3: Register in the full suite**

In `src/test_main.zig`, near line 706 (next to `_ = @import("renderer/overlay_keys.zig");`), add:

```zig
    _ = @import("close_confirm.zig");
```

- [ ] **Step 4: Run the fast suite**

Run: `zig build test`
Expected: PASS — the two new tests in `close_confirm.zig` run and pass (the file is new, so the only way to fail is a typo; verify it compiles and the tests are picked up).

- [ ] **Step 5: Commit**

```bash
git add src/close_confirm.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: pure close-confirm decision logic (keyOutcome, shouldConfirm, PendingClose)"
```

---

## Task 2: Config toggle `confirm-close-running-program`

**Files:**
- Modify: `src/config.zig` (struct field ~line 290; parse branch in `applyKeyValue`, ~line 684)

> **Note:** config parsing is a manual `if/else if` chain in `applyKeyValue` (NOT reflection over struct fields). A new key is silently ignored unless it gets its own branch there. Both edits below are required for the toggle to actually load from the config file.

- [ ] **Step 1: Add the config struct field**

In `src/config.zig`, add this line directly after the `@"desktop-notifications": bool = true,` field (~line 290):

```zig
@"confirm-close-running-program": bool = true,
```

- [ ] **Step 2: Add the parse branch in `applyKeyValue`**

In `src/config.zig`, insert the following lines **immediately before** the existing line `    } else if (std.mem.eql(u8, key, "right-click-action")) {` (~line 751). This adds a new link to the `if/else if` chain; the existing `right-click-action` line's leading `}` closes this new branch, so the inserted block deliberately has no trailing brace of its own — exactly mirroring the `copy-on-select` branch immediately above it:

```zig
    } else if (std.mem.eql(u8, key, "confirm-close-running-program")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"confirm-close-running-program" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"confirm-close-running-program" = false;
        } else {
            log.warn("invalid confirm-close-running-program: {s}", .{value});
        }
```

- [ ] **Step 3: Add a parse test**

In `src/config.zig`, near the other config tests, add:

```zig
test "confirm-close-running-program defaults true and parses false" {
    var cfg = Config{};
    try std.testing.expect(cfg.@"confirm-close-running-program");
    cfg.applyKeyValue(std.testing.allocator, "confirm-close-running-program", "false", ".");
    try std.testing.expect(!cfg.@"confirm-close-running-program");
}
```

If the existing config tests construct `Config` differently or `applyKeyValue` has a different arity than `(allocator, key, value, base_dir)`, match the existing test's call shape (check a nearby `applyKeyValue` test for the exact signature — confirmed `(self, allocator, key, value, base_dir)` at the definition ~line 684).

- [ ] **Step 4: Run the fast suite**

Run: `zig build test`
Expected: PASS — `config.zig` is in the fast suite; the new test runs and passes, and existing config tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat: add confirm-close-running-program config toggle (default true)"
```

---

## Task 3: Cached config global + detection helpers in `AppWindow.zig`

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Declare the cached global**

In `src/AppWindow.zig`, directly after the existing line `pub threadlocal var g_desktop_notifications: bool = true;` (~line 2054), add:

```zig
pub threadlocal var g_confirm_close_running_program: bool = true;
```

- [ ] **Step 2: Apply it from config**

In `applyReloadedConfig` (~line 2367), directly after the existing line `g_desktop_notifications = cfg.@"desktop-notifications";` (~line 2402), add:

```zig
    g_confirm_close_running_program = cfg.@"confirm-close-running-program";
```

- [ ] **Step 3: Add the import for close_confirm (if not present)**

In `src/AppWindow.zig`, near the other top-level imports (e.g. next to `const agent_detector = @import("agent_detector.zig");` ~line 23), add:

```zig
const close_confirm = @import("close_confirm.zig");
```

- [ ] **Step 4: Add detection helpers**

In `src/AppWindow.zig`, add these public functions next to `activeSurface` (~line 790):

```zig
fn surfaceOnAltScreen(s: *const Surface) bool {
    return s.terminal.screens.active_key == .alternate;
}

/// True if the focused surface is running a full-screen program (alt-screen).
pub fn activeSurfaceHasRunningProgram() bool {
    const s = activeSurface() orelse return false;
    return surfaceOnAltScreen(s);
}

/// True if any surface in the given tab is running a full-screen program.
pub fn tabHasRunningProgram(idx: usize) bool {
    if (idx >= tab.g_tab_count) return false;
    const t = tab.g_tabs[idx] orelse return false;
    if (t.kind != .terminal) return false;
    var it = t.tree.iterator();
    while (it.next()) |entry| {
        if (surfaceOnAltScreen(entry.surface)) return true;
    }
    return false;
}

/// True if any surface in any tab in the window is running a full-screen program.
pub fn anyTabHasRunningProgram() bool {
    for (0..tab.g_tab_count) |ti| {
        const t = tab.g_tabs[ti] orelse continue;
        if (t.kind != .terminal) continue;
        var it = t.tree.iterator();
        while (it.next()) |entry| {
            if (surfaceOnAltScreen(entry.surface)) return true;
        }
    }
    return false;
}
```

- [ ] **Step 5: Build the full suite (these touch the app graph)**

Run: `zig build test-full`
Expected: PASS — compiles; `Surface`, `tab.g_tabs`, and `SplitTree.iterator()` resolve. No new unit tests here (requires a live window/terminal); covered by build + GUI verification later.

- [ ] **Step 6: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat: running-program detection helpers + cached confirm toggle"
```

---

## Task 4: Generalize the confirm overlay in `overlays.zig`

**Files:**
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: Add the import and variant/state**

In `src/renderer/overlays.zig`, near the top-of-file imports add (path is `../` because overlays.zig lives in `src/renderer/`):

```zig
const close_confirm = @import("../close_confirm.zig");
```

Add the variant enum just above the `g_window_close_confirm_visible` declaration (~line 134):

```zig
pub const CloseConfirmVariant = enum { running_program, window_generic };
```

Replace the single visibility var (~line 134) — keep it and add the pending-action + variant state next to it:

```zig
threadlocal var g_window_close_confirm_visible: bool = false;
threadlocal var g_close_confirm_pending: close_confirm.PendingClose = .window;
threadlocal var g_close_confirm_variant: CloseConfirmVariant = .window_generic;
```

- [ ] **Step 2: Add `closeConfirmOpen` and make `windowCloseConfirmOpen` a wrapper**

Replace the existing `windowCloseConfirmOpen` (~line 370):

```zig
pub fn closeConfirmOpen(action: close_confirm.PendingClose, variant: CloseConfirmVariant) void {
    g_close_confirm_pending = action;
    g_close_confirm_variant = variant;
    g_window_close_confirm_visible = true;
}

pub fn windowCloseConfirmOpen() void {
    closeConfirmOpen(.window, .window_generic);
}
```

- [ ] **Step 3: Add `closeConfirmConfirm` (the dispatch)**

Add directly after `windowCloseConfirmClose` (~line 376):

```zig
fn closeConfirmConfirm() void {
    g_window_close_confirm_visible = false;
    switch (g_close_confirm_pending) {
        .window => AppWindow.g_should_close = true,
        .focused_split => AppWindow.closeFocusedSplit(),
        .tab => |idx| AppWindow.closeTab(idx),
    }
}
```

- [ ] **Step 4: Rewire the key handler (Enter confirms, Esc cancels)**

Replace the body of `windowCloseConfirmHandleKey` (~line 382):

```zig
pub fn windowCloseConfirmHandleKey(ev: input_key.KeyEvent) void {
    if (!g_window_close_confirm_visible) return;
    switch (close_confirm.keyOutcome(ev)) {
        .confirm => closeConfirmConfirm(),
        .cancel => windowCloseConfirmClose(),
        .none => {},
    }
}
```

- [ ] **Step 5: Rewire the click handler to dispatch the pending action**

In `windowCloseConfirmExecuteAt` (~line 387), replace the Close-button branch body so it dispatches the pending action instead of hardcoding `g_should_close`:

```zig
    if (pointInTopRect(xpos, ypos, layout.close_x, layout.close_top_px, layout.close_w, layout.close_h)) {
        closeConfirmConfirm();
        return true;
    }
```

(Leave the Cancel branch and the final panel-hit `return` as-is.)

- [ ] **Step 6: Variant-driven text in `renderWindowCloseConfirm`**

In `renderWindowCloseConfirm` (~line 4636), replace the three text lines (`renderTitlebarTextStrongLimited("Close WispTerm?", ...)`, the body `"Running panels in this window will be terminated."`, and the hint `"Press Esc or Cancel to keep working."`) with variant-selected strings. Insert this block just before the `renderTitlebarTextStrongLimited(...title...)` call and use the locals:

```zig
    const title_text = switch (g_close_confirm_variant) {
        .running_program => "A program is still running",
        .window_generic => "Close WispTerm?",
    };
    const body_text = switch (g_close_confirm_variant) {
        .running_program => "Closing now will end it.",
        .window_generic => "Running panels in this window will be terminated.",
    };
    const hint_text = "Press Enter or Close to proceed, Esc to cancel.";
```

Then change the three render calls to use `title_text`, `body_text`, and `hint_text` respectively (replace the string literals with these variables; keep all coordinates/colors unchanged).

- [ ] **Step 7: Build the full suite**

Run: `zig build test-full`
Expected: PASS — overlays.zig compiles with the new state and dispatch. (`AppWindow.closeFocusedSplit`/`closeTab` are already public; `AppWindow` is already imported here, as evidenced by the existing `AppWindow.g_should_close` usage.)

- [ ] **Step 8: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "feat: generalize close-confirm modal with pending action + variant text"
```

---

## Task 5: Remove obsolete `windowCloseConfirmDismisses`

**Files:**
- Modify: `src/renderer/overlay_keys.zig`

- [ ] **Step 1: Confirm there are no remaining callers**

Run: `grep -rn "windowCloseConfirmDismisses" src/`
Expected: only matches in `src/renderer/overlay_keys.zig` (the definition and its test). If any other file still references it, stop — Task 4 Step 4 should have removed the overlays.zig use.

- [ ] **Step 2: Delete the function and its test**

In `src/renderer/overlay_keys.zig`, delete the `windowCloseConfirmDismisses` function (lines ~6-11) and the test `"overlay close confirmation handles platform-neutral keys"` (lines ~21-25). Leave `transferCancelConfirmAction` and its test intact.

- [ ] **Step 3: Run both suites**

Run: `zig build test && zig build test-full`
Expected: PASS — no dangling references; `close_confirm.keyOutcome` now owns this logic.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/overlay_keys.zig
git commit -m "refactor: drop windowCloseConfirmDismisses (superseded by close_confirm.keyOutcome)"
```

---

## Task 6: Gate Ctrl+Shift+W in `input.zig`

**Files:**
- Modify: `src/input.zig` (`closePanelOrTab`, ~line 481)

- [ ] **Step 1: Add the import for close_confirm (if not present)**

In `src/input.zig`, near the existing imports, add:

```zig
const close_confirm = @import("close_confirm.zig");
```

(Skip if it is already imported.)

- [ ] **Step 2: Insert the running-program gate**

In `closePanelOrTab` (~line 481), after the markdown/browser panel checks and **before** the `if (AppWindow.closeFocusedSplitWouldCloseWindow())` block, insert:

```zig
    if (close_confirm.shouldConfirm(AppWindow.g_confirm_close_running_program, AppWindow.activeSurfaceHasRunningProgram())) {
        g_close_shortcut_confirm_until_ms = 0;
        overlays.closeConfirmOpen(.focused_split, .running_program);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
```

This runs before the existing "last tab → press-again toast" logic, so a running program always gets the modal, even on a non-last split/tab.

- [ ] **Step 3: Build the full suite**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/input.zig
git commit -m "feat: confirm Ctrl+Shift+W close when a program is running"
```

---

## Task 7: Gate the tab × button and middle-click in `input.zig`

**Files:**
- Modify: `src/input.zig` (middle-click ~line 2722; close-button release ~line 3301)

- [ ] **Step 1: Add a shared tab-close-gesture helper**

In `src/input.zig`, add this helper (e.g. near the other close helpers, after `closePanelOrTab`):

```zig
/// Close a tab via a pointer gesture (middle-click or the × button), honoring
/// the running-program confirmation. `tab_idx` is the tab to close.
fn requestCloseTabGesture(tab_idx: usize) void {
    const closes_window = tab.g_tab_count <= 1;
    if (close_confirm.shouldConfirm(AppWindow.g_confirm_close_running_program, AppWindow.tabHasRunningProgram(tab_idx))) {
        const action: close_confirm.PendingClose = if (closes_window) .window else .{ .tab = tab_idx };
        overlays.closeConfirmOpen(action, .running_program);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    if (closes_window) {
        AppWindow.g_should_close = true;
    } else {
        AppWindow.closeTab(tab_idx);
    }
}
```

(`tab` is already imported in `input.zig` — it is referenced as `tab.g_tab_count` elsewhere in the file.)

- [ ] **Step 2: Route the middle-click gesture through the helper**

In the middle-click block (~line 2722), replace:

```zig
        if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            if (tab.g_tab_count <= 1) {
                AppWindow.g_should_close = true;
            } else {
                AppWindow.closeTab(tab_idx);
            }
            return;
        }
```

with:

```zig
        if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            requestCloseTabGesture(tab_idx);
            return;
        }
```

- [ ] **Step 3: Route the close-button release through the helper**

In the close-button release block (~line 3301), replace:

```zig
            if (tab.g_tab_close_pressed) |pressed_idx| {
                tab.g_tab_close_pressed = null;
                if (pressed_idx < tab.g_tab_count and hitTestSidebarTabCloseButton(xpos, ypos, pressed_idx)) {
                    if (tab.g_tab_count <= 1) {
                        AppWindow.g_should_close = true;
                    } else {
                        AppWindow.closeTab(pressed_idx);
                    }
                }
                return;
            }
```

with:

```zig
            if (tab.g_tab_close_pressed) |pressed_idx| {
                tab.g_tab_close_pressed = null;
                if (pressed_idx < tab.g_tab_count and hitTestSidebarTabCloseButton(xpos, ypos, pressed_idx)) {
                    requestCloseTabGesture(pressed_idx);
                }
                return;
            }
```

- [ ] **Step 4: Build the full suite**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/input.zig
git commit -m "feat: confirm tab close (x button / middle-click) when a program is running"
```

---

## Task 8: Gate the window X button in `AppWindow.zig`

**Files:**
- Modify: `src/AppWindow.zig` (main-loop close-requested block, ~line 4786)

- [ ] **Step 1: Replace the close-requested block**

In the main loop, replace the existing block:

```zig
        if (window_backend.closeRequested(win)) {
            window_backend.clearCloseRequested(win);
            if (!window_backend.closeRequestPromptsConfirmation()) {
                // Backend tears the window down immediately with no in-app
                // prompt; closing this window does not necessarily end the app
                // session (the backend owns process lifecycle).
                g_should_close = true;
                running = false;
                continue;
            }
            overlays.windowCloseConfirmOpen();
            g_force_rebuild = true;
            g_cells_valid = false;
        }
```

with:

```zig
        if (window_backend.closeRequested(win)) {
            window_backend.clearCloseRequested(win);
            const running_program = anyTabHasRunningProgram();
            const confirm_for_program = close_confirm.shouldConfirm(g_confirm_close_running_program, running_program);
            const want_confirm = window_backend.closeRequestPromptsConfirmation() or confirm_for_program;
            if (!want_confirm) {
                // Backend tears the window down immediately with no in-app
                // prompt; closing this window does not necessarily end the app
                // session (the backend owns process lifecycle).
                g_should_close = true;
                running = false;
                continue;
            }
            const variant: overlays.CloseConfirmVariant = if (confirm_for_program) .running_program else .window_generic;
            overlays.closeConfirmOpen(.window, variant);
            g_force_rebuild = true;
            g_cells_valid = false;
        }
```

This adds the prompt on macOS (where `closeRequestPromptsConfirmation()` is false today) when a program is running, while preserving the existing Windows always-prompt for the generic case.

- [ ] **Step 2: Build the full suite**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat: confirm window-X close when any tab has a running program"
```

---

## Task 9: Final verification

- [ ] **Step 1: Run both suites clean**

Run: `zig build test && zig build test-full`
Expected: PASS — both exit 0. Baseline before this work was ~673/677 passed, 4 skipped, 0 failed; expect 0 failed and a couple more passing tests (the two new `close_confirm` tests).

- [ ] **Step 2: Confirm no leftover references**

Run: `grep -rn "windowCloseConfirmDismisses" src/`
Expected: no matches.

- [ ] **Step 3: GUI verification (deferred — macOS / Windows, no Linux GUI backend)**

Manual checklist once on a GUI platform:
- Run `claude code` (or `vim`) in a tab, press **Ctrl+Shift+W** → modal appears; **Esc** keeps the session; **Enter** / click **Close** ends it.
- Same with the **tab × button** and **middle-click** on the tab.
- Click the **window X** with a running program in any tab (including a background tab) → modal appears; verify Cancel keeps the window and Close (Enter) closes it. **macOS specifically:** confirm the window actually closes after Close and that red-X / Cmd-W behavior is not broken (this is the one platform-risk flagged in the spec).
- Plain shell prompt (no program): all three gestures close with **no** modal.
- Set `confirm-close-running-program = false` in config → all three gestures close a running program with no modal (Windows generic window-X prompt still appears, unchanged).

---

## Self-Review Notes

- **Spec coverage:** alt-screen trigger (Task 3), Approach A generalized modal (Task 4), all three close paths (Tasks 6/7/8), Enter=confirm / Esc=cancel (Tasks 1+4), window-X warns if *any* tab has a program (Task 8), config toggle default true (Tasks 2/3), tests (Task 1) + GUI checklist (Task 9). macOS teardown risk surfaced in Task 8 Step 1 + Task 9 Step 3.
- **Type consistency:** `PendingClose` (`.window` / `.focused_split` / `.tab: usize`), `CloseConfirmVariant` (`.running_program` / `.window_generic`), `KeyOutcome` (`.none`/`.confirm`/`.cancel`), helper names (`activeSurfaceHasRunningProgram`, `tabHasRunningProgram`, `anyTabHasRunningProgram`, `requestCloseTabGesture`, `closeConfirmOpen`, `closeConfirmConfirm`) are used identically across all tasks.
- **No placeholders:** every code step shows the exact code; every run step shows the command + expected result.
