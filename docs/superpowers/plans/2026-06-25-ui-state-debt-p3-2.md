# UI State Debt P3.2 Input Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce `src/input.zig` coupling to AppWindow globals by routing keyboard/overlay UI invalidation through an input effect boundary while preserving existing shortcut and UI behavior.

**Architecture:** Keep the existing `src/appwindow/ui_effect.zig` type as the shared effect contract. Add a small `src/input/effects.zig` helper module, apply input effects through one local boundary in `src/input.zig`, convert the highest-risk `dispatchChar` and `dispatchKey` mutation paths to return effects, and add a source guard that prevents direct dirty-flag writes from returning to those dispatch regions. Mouse-heavy paths stay out of P3.2 unless a converted helper already touches them.

**Tech Stack:** Zig, existing WispTerm input/AppWindow modules, `zig build test` for each slice, `zig build test-full` once at the final gate because it takes 5-10 minutes.

---

## Current Baseline

P3.1/P3.1b moved several AppWindow integration clusters into focused `src/appwindow/` modules. The remaining high-coupling input surface is:

- `src/input.zig`: 7,101 lines.
- `src/input.zig`: roughly 869 `AppWindow.` references.
- `src/input.zig`: direct `AppWindow.g_force_rebuild` / `AppWindow.g_cells_valid` writes in helpers, `dispatchChar`, `dispatchKey`, and mouse/panel paths.
- `src/appwindow/ui_effect.zig`: already defines `UiEffect.none`, `UiEffect.consumed_only`, `UiEffect.repaint`, and `merge`.
- `src/AppWindow.zig`: already exposes `pub fn applyUiEffect(effect: UiEffect) void`.

P3.2 is not a line-count task. It is a coupling task: keyboard and overlay mutations should no longer know the exact AppWindow dirty flags they must set.

## Ghostty Alignment

Ghostty routes input-triggered behavior through explicit runtime boundaries instead of letting platform input branches mutate arbitrary renderer/window globals:

- `src/apprt/action.zig` defines runtime `Action` values such as `new_tab`, `new_split`, `toggle_command_palette`, and `render`.
- `src/apprt/surface.zig` defines surface `Message` and `Mailbox` contracts for cross-boundary requests such as rendering, clipboard, selection scroll, and presentation.
- `src/apprt/gtk/class/surface.zig` normalizes platform key/mouse events, builds core input events, and invokes core surface/runtime APIs.

WispTerm is not ready to copy that full action/mailbox architecture in P3.2. The local equivalent is narrower: input handlers keep current behavior, but they return or apply `UiEffect` through a single boundary instead of scattering AppWindow dirty-flag knowledge through business branches.

## Files And Responsibilities

- Create `src/input/effects.zig`: input-local effect helpers and tests. This file imports only `../appwindow/ui_effect.zig` plus `std` for tests.
- Create `src/input/dirty_guard.zig`: fast source guard that scans `src/input.zig` dispatch regions and fails if direct dirty-flag writes reappear there.
- Modify `src/input.zig`: import `input/effects.zig`, add `applyInputEffect` and request helpers, convert selected direct dirty writes in `dispatchChar`, `dispatchKey`, and panel command helpers.
- Modify `src/test_fast.zig`: import the new fast-testable guard/helper modules.
- Modify `docs/superpowers/specs/2026-06-25-ui-state-debt-p3-2-design.md`: append final results after implementation.

## Guardrails

- Do not edit `remote/`.
- Do not change keyboard shortcuts or user-visible shortcut text.
- Do not update `README.md` shortcut docs because no shortcut behavior changes are planned.
- Do not change version files, release notes, packaging, PTY internals, render loop behavior, or renderer overlay imports.
- Do not split all of `src/input.zig` in P3.2.
- Do not refactor mouse selection, terminal mouse reporting, drag selection, or hover underlines in P3.2 unless a helper already converted in this plan touches one line there.
- Preserve rebuild-only behavior where the current code sets only `AppWindow.g_force_rebuild = true` and intentionally leaves `g_cells_valid` unchanged.
- Run `zig build test` after every task.
- Run `zig build test-full` only in the final task unless a focused failure requires the full app binary.
- Commit after each task before starting the next task.

## Task 1: Add Input Effect Helpers

**Purpose:** Give input code named helpers for repaint and rebuild-only effects so later changes read as input effects instead of AppWindow dirty-flag implementation details.

**Files:**

- Create `src/input/effects.zig`
- Modify `src/test_fast.zig`

**Steps:**

- [ ] Create `src/input/effects.zig` with this content:

```zig
const std = @import("std");
const ui_effect = @import("../appwindow/ui_effect.zig");

pub const UiEffect = ui_effect.UiEffect;

pub const rebuild_only: UiEffect = .{
    .consumed = true,
    .needs_rebuild = true,
    .cells_invalid = false,
};

pub inline fn repaint() UiEffect {
    return UiEffect.repaint;
}

pub inline fn rebuildOnly() UiEffect {
    return rebuild_only;
}

pub inline fn consumedOnly() UiEffect {
    return UiEffect.consumed_only;
}

pub inline fn repaintIf(changed: bool) UiEffect {
    return if (changed) repaint() else UiEffect.none;
}

pub inline fn rebuildIf(changed: bool) UiEffect {
    return if (changed) rebuildOnly() else UiEffect.none;
}

pub inline fn mergeRepaint(effect: UiEffect, changed: bool) UiEffect {
    return if (changed) effect.merge(repaint()) else effect;
}

pub inline fn mergeRebuild(effect: UiEffect, changed: bool) UiEffect {
    return if (changed) effect.merge(rebuildOnly()) else effect;
}

test "input effects expose repaint and rebuild-only semantics" {
    const repaint_effect = repaint();
    try std.testing.expect(repaint_effect.consumed);
    try std.testing.expect(repaint_effect.needs_rebuild);
    try std.testing.expect(repaint_effect.cells_invalid);

    const rebuild_effect = rebuildOnly();
    try std.testing.expect(rebuild_effect.consumed);
    try std.testing.expect(rebuild_effect.needs_rebuild);
    try std.testing.expect(!rebuild_effect.cells_invalid);
}

test "input effects conditional helpers preserve none when unchanged" {
    try std.testing.expectEqual(UiEffect.none, repaintIf(false));
    try std.testing.expectEqual(UiEffect.none, rebuildIf(false));
    try std.testing.expect(repaintIf(true).cells_invalid);
    try std.testing.expect(!rebuildIf(true).cells_invalid);
}

test "input effects merge helpers add only requested invalidation" {
    const base = UiEffect.consumed_only;
    const repaint_effect = mergeRepaint(base, true);
    try std.testing.expect(repaint_effect.consumed);
    try std.testing.expect(repaint_effect.needs_rebuild);
    try std.testing.expect(repaint_effect.cells_invalid);

    const rebuild_effect = mergeRebuild(base, true);
    try std.testing.expect(rebuild_effect.consumed);
    try std.testing.expect(rebuild_effect.needs_rebuild);
    try std.testing.expect(!rebuild_effect.cells_invalid);
}
```

- [ ] Add the module to `src/test_fast.zig` inside the existing anonymous `test` block:

```zig
    _ = @import("input/effects.zig");
```

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: the command exits 0 and includes the new `input/effects.zig` tests.

- [ ] Commit:

```bash
git add src/input/effects.zig src/test_fast.zig
git commit -m "refactor(input): add effect boundary helpers"
```

## Task 2: Add A Single Input Apply Boundary

**Purpose:** Keep the public input entry points stable while giving existing `void` helpers one local function for applying input effects to AppWindow.

**Files:**

- Modify `src/input.zig`

**Steps:**

- [ ] Add this import near the existing input-local imports in `src/input.zig`:

```zig
const input_effects = @import("input/effects.zig");
```

- [ ] Replace the bodies of `handleChar` and `handleKey` with calls to a new local boundary:

```zig
fn handleChar(ev: platform_input.CharEvent) void {
    applyInputEffect(dispatchChar(ev));
}

fn handleKey(ev: platform_input.KeyEvent) void {
    applyInputEffect(dispatchKey(ev));
}
```

- [ ] Add these helpers near the existing `markBrowserUrlBarDirty` / `markSkillCenterInputDirty` helpers:

```zig
fn applyInputEffect(effect: ui_effect.UiEffect) void {
    AppWindow.applyUiEffect(effect);
}

fn requestInputRepaint() void {
    applyInputEffect(input_effects.repaint());
}

fn requestInputRebuild() void {
    applyInputEffect(input_effects.rebuildOnly());
}
```

- [ ] Convert the two narrow dirty helpers to use the boundary:

```zig
fn markBrowserUrlBarDirty() void {
    requestInputRepaint();
}

fn markSkillCenterInputDirty() void {
    requestInputRepaint();
}
```

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0. Existing input tests that inspect `AppWindow.g_force_rebuild` and `AppWindow.g_cells_valid` still pass because `applyInputEffect` delegates to `AppWindow.applyUiEffect`.

- [ ] Commit:

```bash
git add src/input.zig
git commit -m "refactor(input): route input effects through local boundary"
```

## Task 3: Convert `dispatchChar` Dirty Writes To Returned Effects

**Purpose:** Make character input paths return invalidation effects instead of mutating AppWindow dirty flags inside the branch.

**Files:**

- Modify `src/input.zig`

**Steps:**

- [ ] In `dispatchChar`, replace the session launcher branch with:

```zig
    if (overlays.sessionLauncherVisible()) {
        if (!ev.ctrl and !ev.alt) {
            overlays.sessionLauncherInsertChar(ev.codepoint);
            return input_effects.repaint();
        }
        return .none;
    }
```

- [ ] In the active AI chat branch, replace the direct dirty writes after `chat.handleChar(ev.codepoint)` with an effect return:

```zig
    if (AppWindow.activeAiChat()) |chat| {
        if (!ev.ctrl and !ev.alt) {
            AppWindow.resetCursorBlink();
            chat.handleChar(ev.codepoint);
            return input_effects.repaint();
        }
        return .none;
    }
```

- [ ] In the active AI copilot branch, replace the direct dirty writes after `chat.handleChar(ev.codepoint)` with an effect return:

```zig
    if (aiCopilotFocused()) {
        if (AppWindow.activeCopilotSessionForInput()) |chat| {
            if (!ev.ctrl and !ev.alt) {
                AppWindow.resetCursorBlink();
                chat.handleChar(ev.codepoint);
                return input_effects.repaint();
            }
            return .none;
        }
    }
```

- [ ] In the focused preview zoom branch, replace the direct dirty writes with:

```zig
            if (zoomed) return input_effects.repaint();
```

Keep the existing `switch (ev.codepoint)` that consumes `+`, `=`, `-`, and `_` when no zoom occurred.

- [ ] Confirm the converted `dispatchChar` slice has no direct dirty writes:

```bash
python3 - <<'PY'
from pathlib import Path
s = Path("src/input.zig").read_text()
region = s[s.index("fn dispatchChar"):s.index("fn triggerFromKeyEvent")]
for needle in ("AppWindow.g_force_rebuild = true", "AppWindow.g_cells_valid = false"):
    if needle in region:
        raise SystemExit(f"found {needle} in dispatchChar")
print("dispatchChar clean")
PY
```

Expected: prints `dispatchChar clean`.

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input.zig
git commit -m "refactor(input): return effects from char dispatch"
```

## Task 4: Convert `dispatchKey` Keyboard/Overlay Dirty Writes

**Purpose:** Remove direct dirty-flag writes from the keyboard dispatch region while preserving the exact consumed behavior and preserving rebuild-only semantics where the old code set only `g_force_rebuild`.

**Files:**

- Modify `src/input.zig`

**Steps:**

- [ ] In `dispatchKey`, convert overlay branches that currently mutate and return `.none` to return `input_effects.repaint()`:

```zig
    if (overlays.whatsNewVisible()) {
        overlays.whatsNewHandleKey(key_event);
        return input_effects.repaint();
    }
    if (overlays.integrationPromptVisible()) {
        overlays.integrationPromptHandleKey(key_event);
        return input_effects.repaint();
    }
```

- [ ] Convert picker and browser-close branches to return repaint after mutation:

```zig
    if (copilot_picker.isVisible()) {
        copilot_picker.handleKey(key_event);
        return input_effects.repaint();
    }
    if (jupyter_picker.isVisible()) {
        jupyter_picker.handleKey(key_event);
        return input_effects.repaint();
    }
```

For the browser Escape branch, keep `closeBrowserPanel();` and replace the following direct dirty writes with:

```zig
            return input_effects.repaint();
```

- [ ] Preserve rebuild-only behavior for file explorer keyboard input. In the branch that calls `handleFileExplorerKey(ev)`, replace the old `AppWindow.g_force_rebuild = true; return .none;` with:

```zig
            return input_effects.rebuildOnly();
```

- [ ] Convert AI chat and AI copilot select-all/key-handling branches to return repaint:

```zig
            chat.selectAll();
            return input_effects.repaint();
```

```zig
            AppWindow.resetCursorBlink();
            chat.handleKeyWithWrapCols(key_event, aiChatInputWrapCols());
            return input_effects.repaint();
```

```zig
                AppWindow.resetCursorBlink();
                chat.handleKeyWithWrapCols(key_event, aiCopilotInputWrapCols());
                return input_effects.repaint();
```

- [ ] Convert the AI copilot Escape branch to return repaint after stop/clear/hide:

```zig
                if (chat.requestState().inflight) {
                    chat.stopRequest();
                } else if (chat.hasSelection()) {
                    chat.clearSelection();
                } else {
                    AppWindow.hideAiCopilot();
                }
                return input_effects.repaint();
```

- [ ] Convert focused preview keyboard navigation to return repaint:

```zig
            if (consumed) {
                return input_effects.repaint();
            }
```

- [ ] Confirm the converted `dispatchKey` slice has no direct dirty writes:

```bash
python3 - <<'PY'
from pathlib import Path
s = Path("src/input.zig").read_text()
region = s[s.index("fn dispatchKey"):s.index("fn isModifierKey")]
for needle in ("AppWindow.g_force_rebuild = true", "AppWindow.g_cells_valid = false"):
    if needle in region:
        raise SystemExit(f"found {needle} in dispatchKey")
print("dispatchKey clean")
PY
```

Expected: prints `dispatchKey clean`.

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input.zig
git commit -m "refactor(input): return effects from key dispatch"
```

## Task 5: Centralize Panel Helper Dirtying

**Purpose:** Replace direct dirty-flag writes in command/panel helpers above `dispatchChar` with `requestInputRepaint()` or `requestInputRebuild()`. This keeps existing `void` helper signatures while moving dirtying behind the same effect boundary.

**Files:**

- Modify `src/input.zig`

**Steps:**

- [ ] Replace each full repaint pair in these helpers with `requestInputRepaint();`:

```text
toggleSidebar
toggleFileExplorer
closeFileExplorerPanel
toggleBrowserPanel
openJupyterPanel picker-open branch
finishOpenJupyter
closeBrowserPanel
refreshBrowserPanel
closeAiCopilotPanel
closePanelOrTab confirm branches
closePreviewPaneByHandle
requestCloseTabGesture confirm branch
copyRemoteSessionKeyToClipboard
processSizeChange titlebar-sidebar branch
```

The replacement is:

```zig
    requestInputRepaint();
```

- [ ] Keep helper behavior unchanged when the existing branch returns before dirtying. For example, `toggleBrowserPanel` must still return without repaint when system-browser open fails or `browser_panel.toggleForSurface` returns false.

- [ ] Replace any rebuild-only writes in this helper group with:

```zig
    requestInputRebuild();
```

Use this only when the old code set `AppWindow.g_force_rebuild = true` and did not set `AppWindow.g_cells_valid = false`.

- [ ] Measure remaining direct dirty writes before and after this task:

```bash
rg -n "AppWindow\\.g_force_rebuild = true|AppWindow\\.g_cells_valid = false" src/input.zig
```

Expected: the helper group above no longer appears in the output. Mouse-heavy paths after `handleFileExplorerKey` may still appear and are intentionally deferred to a later phase.

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input.zig
git commit -m "refactor(input): centralize panel dirty effects"
```

## Task 6: Add Input Dirty Boundary Guard

**Purpose:** Make the P3.2 boundary enforceable. The guard should fail if direct AppWindow dirty writes reappear in `dispatchChar` or `dispatchKey`, while allowing tests and deferred mouse-heavy paths to keep existing code until a later phase.

**Files:**

- Create `src/input/dirty_guard.zig`
- Modify `src/test_fast.zig`

**Steps:**

- [ ] Create `src/input/dirty_guard.zig` with this content:

```zig
const std = @import("std");

const input_source = @embedFile("../input.zig");

fn sourceSlice(start_marker: []const u8, end_marker: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, input_source, start_marker) orelse return error.StartMarkerMissing;
    const rest = input_source[start..];
    const end_rel = std.mem.indexOf(u8, rest, end_marker) orelse return error.EndMarkerMissing;
    return rest[0..end_rel];
}

fn expectNoDirectDirtyWrites(region: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, region, "AppWindow.g_force_rebuild = true") == null);
    try std.testing.expect(std.mem.indexOf(u8, region, "AppWindow.g_cells_valid = false") == null);
}

test "input dispatch char routes UI dirtying through effects" {
    const region = try sourceSlice("fn dispatchChar", "\nfn triggerFromKeyEvent");
    try expectNoDirectDirtyWrites(region);
    try std.testing.expect(std.mem.indexOf(u8, region, "input_effects.repaint()") != null);
}

test "input dispatch key routes UI dirtying through effects" {
    const region = try sourceSlice("fn dispatchKey", "\nfn isModifierKey");
    try expectNoDirectDirtyWrites(region);
    try std.testing.expect(std.mem.indexOf(u8, region, "input_effects.repaint()") != null);
    try std.testing.expect(std.mem.indexOf(u8, region, "input_effects.rebuildOnly()") != null);
}

test "input dirty helpers delegate to the local apply boundary" {
    const helper_region = try sourceSlice("fn applyInputEffect", "\nfn blurBrowserUrlBarIfFocused");
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "AppWindow.applyUiEffect(effect)") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "requestInputRepaint()") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "requestInputRebuild()") != null);
}
```

- [ ] Add the guard to `src/test_fast.zig` inside the existing anonymous `test` block:

```zig
    _ = @import("input/dirty_guard.zig");
```

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0 and the guard tests pass.

- [ ] Commit:

```bash
git add src/input/dirty_guard.zig src/test_fast.zig
git commit -m "test(input): guard P3.2 dirty boundary"
```

## Task 7: Record Results And Run Final Gates

**Purpose:** Document the new boundary and verify the complete branch without paying the `test-full` cost after every small task.

**Files:**

- Modify `docs/superpowers/specs/2026-06-25-ui-state-debt-p3-2-design.md`

**Steps:**

- [ ] Gather final measurements:

```bash
wc -l src/input.zig src/input/effects.zig src/input/dirty_guard.zig
rg -c "AppWindow\\." src/input.zig
rg -n "AppWindow\\.g_force_rebuild = true|AppWindow\\.g_cells_valid = false" src/input.zig
```

Expected: `dispatchChar` and `dispatchKey` do not appear in the direct dirty-write output. Remaining output should be mouse-heavy or deferred compatibility paths.

- [ ] Generate the results section from the current tree:

```bash
python3 - <<'PY' > /tmp/p3_2_input_boundary_results.md
from pathlib import Path

def lines(path: str) -> int:
    return len(Path(path).read_text().splitlines())

input_source = Path("src/input.zig").read_text()
appwindow_refs = input_source.count("AppWindow.")

print("## P3.2 Implementation Results")
print()
print(f"- `src/input.zig`: {lines('src/input.zig')} lines after P3.2.")
print(f"- `src/input/effects.zig`: {lines('src/input/effects.zig')} lines.")
print(f"- `src/input/dirty_guard.zig`: {lines('src/input/dirty_guard.zig')} lines.")
print(f"- `src/input.zig` direct `AppWindow.` references: {appwindow_refs}.")
print("- `dispatchChar` and `dispatchKey` no longer contain direct `AppWindow.g_force_rebuild = true` or `AppWindow.g_cells_valid = false` writes.")
print("- Remaining direct dirty-flag writes are intentionally deferred to mouse-heavy and selection/panel pointer paths for P3.3.")
print("- No keyboard shortcut behavior or user-visible shortcut text changed.")
PY
cat /tmp/p3_2_input_boundary_results.md
```

- [ ] Append `/tmp/p3_2_input_boundary_results.md` to `docs/superpowers/specs/2026-06-25-ui-state-debt-p3-2-design.md`.

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Run the full pre-merge suite once:

```bash
zig build test-full
```

Expected: exits 0. This is expected to take 5-10 minutes on a cold or lightly cached build.

- [ ] Run diff whitespace validation:

```bash
git diff --check
```

Expected: no output.

- [ ] Run tracked-file Windows checkout safety because P3.2 adds files:

```bash
python3 - <<'PY'
import os
import subprocess
from collections import defaultdict

reserved = {
    "con", "prn", "aux", "nul",
    *(f"com{i}" for i in range(1, 10)),
    *(f"lpt{i}" for i in range(1, 10)),
}
illegal = set('<>:"|?*')
files = subprocess.check_output(["git", "ls-files"], text=True).splitlines()
errors = []
folded = defaultdict(list)
for path in files:
    folded[path.lower()].append(path)
    if len(path) > 240:
        errors.append(f"path too long ({len(path)}): {path}")
    for part in path.split("/"):
        stem = part.split(".")[0].lower()
        if stem in reserved:
            errors.append(f"reserved name: {path}")
        if any(ch in illegal for ch in part):
            errors.append(f"illegal char: {path}")
        if part.endswith(" ") or part.endswith("."):
            errors.append(f"bad trailing char: {path}")
    if os.path.islink(path):
        errors.append(f"symlink: {path}")
for group in folded.values():
    if len(group) > 1:
        errors.append("case collision: " + " | ".join(group))
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print(f"checked {len(files)} tracked files; no Windows checkout-safety issues")
PY
```

Expected: prints `checked ... tracked files; no Windows checkout-safety issues`.

- [ ] Commit:

```bash
git add docs/superpowers/specs/2026-06-25-ui-state-debt-p3-2-design.md
git commit -m "docs: record P3.2 input boundary results"
```

## Final Acceptance Criteria

- `zig build test` passes after every task.
- `zig build test-full` passes once at the final gate.
- `dispatchChar` and `dispatchKey` contain no direct `AppWindow.g_force_rebuild = true` or `AppWindow.g_cells_valid = false` writes.
- New `input/dirty_guard.zig` is imported by `src/test_fast.zig` and passes in `zig build test`.
- Shortcut behavior and user-visible shortcut text are unchanged.
- Remaining direct dirty writes in `src/input.zig` are documented as P3.3 deferred mouse-heavy or pointer/selection paths.
