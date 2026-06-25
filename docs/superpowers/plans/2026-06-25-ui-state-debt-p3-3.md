# UI State Debt P3.3 Input Dirty Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove runtime direct `AppWindow.g_force_rebuild` / `AppWindow.g_cells_valid` assignments from `src/input.zig` by routing mouse, pointer, hover, drag, selection, preview, and wheel invalidation through the existing input effect boundary.

**Architecture:** Keep the P3.2 input effect seam: `input/effects.zig` owns effect helpers, while `src/input.zig` owns the local apply functions that call `AppWindow.applyUiEffect`. Convert dirty writes by semantic shape: full repaint to `requestInputRepaint()`, rebuild-only to `requestInputRebuild()`, and model-returned dirty flags to a narrow `requestInputDirtyFlags()` helper. Expand `src/input/dirty_guard.zig` so the fast suite rejects any runtime direct dirty assignment in the converted input body.

**Tech Stack:** Zig, existing WispTerm input/AppWindow modules, `zig build test` per slice, `zig build test-full` once as the final gate because it can take 5-10 minutes.

---

## Current Baseline

P3.2 left key/char input clean and guarded, but the non-key runtime input body still contains direct dirty writes:

- `src/input.zig`: 7065 lines.
- `src/input/effects.zig`: 70 lines.
- `src/input/dirty_guard.zig`: 47 lines.
- `src/input.zig` direct `AppWindow.` references: 819.
- 120 direct dirty assignment lines remain in runtime input code.

Remaining dirty assignment lines by function before P3.3:

```text
handleMouseButton: 56
handleMouseWheel: 22
handleMouseMove: 8
applyAiCopilotWidthFromMouse: 2
applyAiInputScrollbarDrag: 2
applyAiTranscriptScrollbarDrag: 2
applyBrowserWidthFromMouse: 2
applyExplorerWidthFromMouse: 2
applySidebarWidthFromMouse: 2
handleFileExplorerPress: 2
markSelectionChanged: 2
openHtmlPanelForCell: 2
openPreviewAsync: 2
openPreviewNew: 2
openUrl: 2
toggleAiAgentPermission: 2
toggleBrowserDisplayMode: 2
updateAiTranscriptSelectionDrag: 2
updatePanelSwapDrag: 2
handleAgentHistoryPress: 1
markUrlUnderlineDirty: 1
```

## Ghostty Alignment

Ghostty keeps pointer-triggered redraw and UI notifications behind runtime contracts:

- `src/input.zig` is a small re-export over focused modules including `input/mouse.zig`, `input/key.zig`, and `input/mouse_encode.zig`.
- `src/apprt/action.zig` has action variants such as `render`, `selection_changed`, `mouse_shape`, `mouse_visibility`, `mouse_over_link`, and `scrollbar`.
- `src/apprt/surface.zig` has messages such as `set_mouse_shape`, `selection_scroll_tick`, `scrollbar`, and `present_surface`.
- `src/apprt/gtk/class/surface.zig` normalizes pointer events and delegates to core callbacks such as `mouseButtonCallback`, `cursorPosCallback`, and `scrollCallback`.

P3.3 is the WispTerm-sized step toward that shape: finish local effect routing first. Do not split `src/input.zig` in this phase.

## Guardrails

- Do not edit `remote/`.
- Do not change keyboard shortcuts or user-visible shortcut text.
- Do not update README shortcut docs because no shortcut behavior changes are planned.
- Do not change terminal mouse reporting, PTY writes, terminal mouse escape encoding, selection semantics, URL detection, preview open behavior, panel resize behavior, or AI chat interaction behavior.
- Do not split `src/input.zig` into new files in P3.3.
- Preserve rebuild-only sites as rebuild-only.
- Preserve `mouse_wheel_scroll.repaintFlagsForViewportScroll` dirty-request behavior through `requestInputDirtyFlags`.
- Run `zig build test` after every implementation task.
- Run `zig build test-full` only in the final task unless a failure requires the full app binary.
- Commit after each task before starting the next task.

## Files And Responsibilities

- Modify `src/input/effects.zig`: add `fromDirtyFlags` helper and unit tests.
- Modify `src/input.zig`: add `requestInputDirtyFlags`; convert runtime direct dirty assignments to input effect helpers.
- Modify `src/input/dirty_guard.zig`: expand source guard from key/char slices to the runtime input body.
- Modify `docs/superpowers/specs/2026-06-25-ui-state-debt-p3-3-design.md`: record implementation results after verification.

## Task 1: Add Dirty-Flag Effect Helper

**Purpose:** Add a named helper for the one model-returned dirty flag path in `handleMouseWheel`, then wire it through `src/input.zig` without changing behavior.

**Files:**

- Modify `src/input/effects.zig`
- Modify `src/input.zig`
- Modify `src/input/dirty_guard.zig`

**Steps:**

- [ ] In `src/input/effects.zig`, add this helper after `mergeRebuild`:

```zig
pub inline fn fromDirtyFlags(force_rebuild: bool, cells_valid: bool) UiEffect {
    return .{
        .consumed = true,
        .needs_rebuild = force_rebuild,
        .cells_invalid = !cells_valid,
    };
}
```

- [ ] In `src/input/effects.zig`, add this test after the existing tests:

```zig
test "input effects map dirty flag pairs into effect requests" {
    const repaint_effect = fromDirtyFlags(true, false);
    try std.testing.expect(repaint_effect.consumed);
    try std.testing.expect(repaint_effect.needs_rebuild);
    try std.testing.expect(repaint_effect.cells_invalid);

    const rebuild_only_effect = fromDirtyFlags(true, true);
    try std.testing.expect(rebuild_only_effect.consumed);
    try std.testing.expect(rebuild_only_effect.needs_rebuild);
    try std.testing.expect(!rebuild_only_effect.cells_invalid);
}
```

- [ ] In `src/input.zig`, add this helper immediately after `requestInputRebuild`:

```zig
fn requestInputDirtyFlags(force_rebuild: bool, cells_valid: bool) void {
    applyInputEffect(input_effects.fromDirtyFlags(force_rebuild, cells_valid));
}
```

- [ ] In `src/input/dirty_guard.zig`, extend the existing `"input dirty helpers delegate to the local apply boundary"` test with this assertion:

```zig
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "requestInputDirtyFlags") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "input_effects.fromDirtyFlags(force_rebuild, cells_valid)") != null);
```

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input/effects.zig src/input.zig src/input/dirty_guard.zig
git commit -m "refactor(input): add dirty flag effect helper"
```

## Task 2: Convert Small Runtime Dirty Helpers

**Purpose:** Convert small helper functions before the large mouse entrypoints. These helpers are directly or indirectly used by pointer paths, and converting them first reduces the review size of later tasks.

**Files:**

- Modify `src/input.zig`

**Steps:**

- [ ] Replace full repaint pairs in these functions with `requestInputRepaint();`:

```text
updatePanelSwapDrag
applySidebarWidthFromMouse
toggleBrowserDisplayMode
applyBrowserWidthFromMouse
applyAiCopilotWidthFromMouse
applyExplorerWidthFromMouse
markSelectionChanged
openUrl
openHtmlPanelForCell
openPreviewAsync
openPreviewNew
applyAiInputScrollbarDrag
applyAiTranscriptScrollbarDrag
updateAiTranscriptSelectionDrag
toggleAiAgentPermission
```

The replacement for each pair is:

```zig
    requestInputRepaint();
```

- [ ] Replace rebuild-only writes in these functions with `requestInputRebuild();`:

```text
handleFileExplorerPress
handleAgentHistoryPress
markUrlUnderlineDirty
```

The replacement for each rebuild-only write is:

```zig
    requestInputRebuild();
```

- [ ] Verify none of the converted helper functions still contain direct dirty assignments:

```bash
python3 - <<'PY'
from pathlib import Path
import re

source = Path("src/input.zig").read_text().splitlines()
converted = {
    "updatePanelSwapDrag",
    "applySidebarWidthFromMouse",
    "toggleBrowserDisplayMode",
    "applyBrowserWidthFromMouse",
    "applyAiCopilotWidthFromMouse",
    "applyExplorerWidthFromMouse",
    "markSelectionChanged",
    "openUrl",
    "openHtmlPanelForCell",
    "openPreviewAsync",
    "openPreviewNew",
    "applyAiInputScrollbarDrag",
    "applyAiTranscriptScrollbarDrag",
    "updateAiTranscriptSelectionDrag",
    "toggleAiAgentPermission",
    "handleFileExplorerPress",
    "handleAgentHistoryPress",
    "markUrlUnderlineDirty",
}
current = None
bad = []
for lineno, line in enumerate(source, 1):
    m = re.match(r"(pub )?fn ([A-Za-z0-9_]+)", line)
    if m:
        current = m.group(2)
    if current in converted and ("AppWindow.g_force_rebuild =" in line or "AppWindow.g_cells_valid =" in line):
        bad.append(f"{lineno}:{current}:{line.strip()}")
if bad:
    print("\n".join(bad))
    raise SystemExit(1)
print("small runtime dirty helpers clean")
PY
```

Expected: prints `small runtime dirty helpers clean`.

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input.zig
git commit -m "refactor(input): route helper dirtying through effects"
```

## Task 3: Convert Mouse Wheel Dirtying

**Purpose:** Convert `handleMouseWheel` dirty writes while preserving rebuild-only scroll paths and `mouse_wheel_scroll.repaintFlagsForViewportScroll`.

**Files:**

- Modify `src/input.zig`

**Steps:**

- [ ] In `handleMouseWheel`, replace rebuild-only writes with `requestInputRebuild();` in these branches:

```text
overlays.whatsNewVisible()
overlays.settingsPageVisible()
file_explorer panel scroll
AppWindow.activeAiChat() transcript scroll
AppWindow.aiCopilotVisible() transcript scroll
preview pane wheel scroll/zoom
```

The replacement for each rebuild-only write is:

```zig
            requestInputRebuild();
```

or, at the current indentation level:

```zig
        requestInputRebuild();
```

- [ ] In `handleMouseWheel`, replace full repaint pairs with `requestInputRepaint();` in these branches:

```text
overlays.integrationPromptVisible()
overlays.commandPaletteVisible()
overlays.sessionLauncherVisible()
copilot_picker.isVisible()
jupyter_picker.isVisible()
AppWindow.activeAiChat() input field scroll
AppWindow.aiCopilotVisible() input field scroll
```

The replacement for each pair is:

```zig
                requestInputRepaint();
```

or, at the current indentation level:

```zig
        requestInputRepaint();
```

- [ ] Replace the viewport scroll exact flag assignment:

```zig
            AppWindow.g_force_rebuild = flags.force_rebuild;
            AppWindow.g_cells_valid = flags.cells_valid;
```

with:

```zig
            requestInputDirtyFlags(flags.force_rebuild, flags.cells_valid);
```

- [ ] Verify the `handleMouseWheel` body has no direct dirty assignments:

```bash
python3 - <<'PY'
from pathlib import Path
s = Path("src/input.zig").read_text()
region = s[s.index("fn handleMouseWheel"):s.index("\nfn updateDragSelection")]
for needle in ("AppWindow.g_force_rebuild =", "AppWindow.g_cells_valid ="):
    if needle in region:
        raise SystemExit(f"found {needle} in handleMouseWheel")
print("handleMouseWheel dirty boundary clean")
PY
```

Expected: prints `handleMouseWheel dirty boundary clean`.

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input.zig
git commit -m "refactor(input): route wheel dirtying through effects"
```

## Task 4: Convert Mouse Move Dirtying

**Purpose:** Convert `handleMouseMove` dirty writes while preserving hover, drag, and rebuild-only semantics.

**Files:**

- Modify `src/input.zig`

**Steps:**

- [ ] In `handleMouseMove`, replace rebuild-only writes with `requestInputRebuild();` in these branches:

```text
g_preview_image_drag.move
AI chat transcript scrollbar hover changed to true
AI chat transcript scrollbar hover changed to false
copilot edge handle reveal/hover target visible
```

For single-line conditionals, replace:

```zig
        if (g_preview_image_drag.move(xpos, ypos)) AppWindow.g_force_rebuild = true;
```

with:

```zig
        if (g_preview_image_drag.move(xpos, ypos)) requestInputRebuild();
```

- [ ] In `handleMouseMove`, replace full repaint pairs with `requestInputRepaint();` in these branches:

```text
divider dragging resize
preview close hover changed
```

The replacement for each pair is:

```zig
            requestInputRepaint();
```

- [ ] Verify the `handleMouseMove` body has no direct dirty assignments:

```bash
python3 - <<'PY'
from pathlib import Path
s = Path("src/input.zig").read_text()
region = s[s.index("fn handleMouseMove"):s.index("\nfn appendBytes")]
for needle in ("AppWindow.g_force_rebuild =", "AppWindow.g_cells_valid ="):
    if needle in region:
        raise SystemExit(f"found {needle} in handleMouseMove")
print("handleMouseMove dirty boundary clean")
PY
```

Expected: prints `handleMouseMove dirty boundary clean`.

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input.zig
git commit -m "refactor(input): route mouse move dirtying through effects"
```

## Task 5: Convert Mouse Button Overlay And Chrome Dirtying

**Purpose:** Convert the top-level overlay, toast, titlebar, file explorer, and preview focus dirty writes in `handleMouseButton`. This task stops before AI chat/copilot interaction blocks to keep the diff reviewable.

**Files:**

- Modify `src/input.zig`

**Steps:**

- [ ] In `handleMouseButton`, replace full repaint pairs with `requestInputRepaint();` in these branches:

```text
overlays.whatsNewVisible()
overlays.integrationPromptVisible()
overlays.windowCloseConfirmVisible()
overlays.transferCancelConfirmVisible()
overlays.restoreDefaultsConfirmVisible()
overlays.transferToastHitTest
file_explorer refresh button
preview pane focus changed
g_ai_transcript_selecting mouse-up finish
```

The replacement for each pair is:

```zig
            requestInputRepaint();
```

- [ ] Do not change branches that call helpers already converted in Task 2, such as:

```text
closeFileExplorerPanel
refreshBrowserPanel
toggleBrowserDisplayMode
closeBrowserPanel
closeAiCopilotPanel
markBrowserUrlBarDirty
handleFileExplorerPress
closePreviewPaneByHandle
```

- [ ] Verify the converted overlay/chrome branches no longer contain direct dirty assignments by running this focused function scan:

```bash
python3 - <<'PY'
from pathlib import Path
s = Path("src/input.zig").read_text()
start = s.index("fn handleMouseButton")
rest = s[start:]
end = start + rest.index("if (AppWindow.activeAiChat()) |chat|")
region = s[start:end]
for needle in ("AppWindow.g_force_rebuild =", "AppWindow.g_cells_valid ="):
    if needle in region:
        raise SystemExit(f"found {needle} before active AI chat block")
print("mouse button overlay/chrome dirty boundary clean")
PY
```

Expected: prints `mouse button overlay/chrome dirty boundary clean`.

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input.zig
git commit -m "refactor(input): route mouse chrome dirtying through effects"
```

## Task 6: Convert Mouse Button AI Interaction Dirtying

**Purpose:** Convert the remaining direct dirty writes in `handleMouseButton`, primarily AI copilot sidebar and AI chat tab interaction branches.

**Files:**

- Modify `src/input.zig`

**Steps:**

- [ ] In the AI copilot sidebar block inside `handleMouseButton`, replace full repaint pairs with `requestInputRepaint();` in these branches:

```text
missing API key status hit
toggle_tool
toggle_reasoning
question_option
model label hit
transcript scrollbar hit
transcript text selection begin
click inside panel clears selection
```

The replacement for each pair is:

```zig
                            requestInputRepaint();
```

or, at the current indentation level:

```zig
                        requestInputRepaint();
```

- [ ] In the active AI chat tab block inside `handleMouseButton`, replace full repaint pairs with `requestInputRepaint();` in these branches:

```text
stop button hit
missing API key status hit
toggle_tool
toggle_reasoning
question_option
model label hit
transcript scrollbar hit
transcript text selection begin
input scrollbar hit
click inside panel clears selection
```

The replacement for each pair is:

```zig
                    requestInputRepaint();
```

or, at the current indentation level:

```zig
                requestInputRepaint();
```

- [ ] Verify the full `handleMouseButton` body has no direct dirty assignments:

```bash
python3 - <<'PY'
from pathlib import Path
s = Path("src/input.zig").read_text()
region = s[s.index("fn handleMouseButton"):s.index("\nfn handleTabBarPress")]
for needle in ("AppWindow.g_force_rebuild =", "AppWindow.g_cells_valid ="):
    if needle in region:
        raise SystemExit(f"found {needle} in handleMouseButton")
print("handleMouseButton dirty boundary clean")
PY
```

Expected: prints `handleMouseButton dirty boundary clean`.

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input.zig
git commit -m "refactor(input): route mouse button dirtying through effects"
```

## Task 7: Expand Runtime Dirty Guard

**Purpose:** Make the P3.3 boundary enforceable in the fast suite. After this task, runtime input code cannot reintroduce direct dirty assignments without failing `zig build test`.

**Files:**

- Modify `src/input/dirty_guard.zig`

**Steps:**

- [ ] Replace `expectNoDirectDirtyWrites` in `src/input/dirty_guard.zig` with this stricter helper:

```zig
fn expectNoDirectDirtyAssignments(region: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, region, "AppWindow.g_force_rebuild =") == null);
    try std.testing.expect(std.mem.indexOf(u8, region, "AppWindow.g_cells_valid =") == null);
}
```

- [ ] Replace all existing calls to `expectNoDirectDirtyWrites(region)` with:

```zig
    try expectNoDirectDirtyAssignments(region);
```

- [ ] Add this test after the key-dispatched helper tests:

```zig
test "input runtime dirtying routes through effect boundary" {
    const region = try sourceSlice("fn applyInputEffect", "\n// --- Maximize toggle (native window) ---");
    try expectNoDirectDirtyAssignments(region);
    try std.testing.expect(std.mem.indexOf(u8, region, "requestInputRepaint()") != null);
    try std.testing.expect(std.mem.indexOf(u8, region, "requestInputRebuild()") != null);
    try std.testing.expect(std.mem.indexOf(u8, region, "requestInputDirtyFlags(") != null);
}
```

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Commit:

```bash
git add src/input/dirty_guard.zig
git commit -m "test(input): guard runtime dirty boundary"
```

## Task 8: Record P3.3 Results And Run Final Gates

**Purpose:** Document the final boundary state and run the full verification gate once.

**Files:**

- Modify `docs/superpowers/specs/2026-06-25-ui-state-debt-p3-3-design.md`

**Steps:**

- [ ] Gather final measurements:

```bash
wc -l src/input.zig src/input/effects.zig src/input/dirty_guard.zig
python3 - <<'PY'
from pathlib import Path
s = Path("src/input.zig").read_text()
print(s.count("AppWindow."))
runtime = s[s.index("fn applyInputEffect"):s.index("\n// --- Maximize toggle (native window) ---")]
dirty = [line for line in runtime.splitlines() if "AppWindow.g_force_rebuild =" in line or "AppWindow.g_cells_valid =" in line]
print(len(dirty))
for line in dirty:
    print(line)
PY
```

Expected: the final printed dirty count is `0`.

- [ ] Append generated implementation results to `docs/superpowers/specs/2026-06-25-ui-state-debt-p3-3-design.md`:

```bash
python3 - <<'PY' > /tmp/p3_3_input_dirty_boundary_results.md
from pathlib import Path

def lines(path: str) -> int:
    return len(Path(path).read_text().splitlines())

input_source = Path("src/input.zig").read_text()
appwindow_refs = input_source.count("AppWindow.")
runtime = input_source[input_source.index("fn applyInputEffect"):input_source.index("\n// --- Maximize toggle (native window) ---")]
runtime_dirty = [
    line
    for line in runtime.splitlines()
    if "AppWindow.g_force_rebuild =" in line or "AppWindow.g_cells_valid =" in line
]

print("## P3.3 Implementation Results")
print()
print(f"- `src/input.zig`: {lines('src/input.zig')} lines after P3.3.")
print(f"- `src/input/effects.zig`: {lines('src/input/effects.zig')} lines.")
print(f"- `src/input/dirty_guard.zig`: {lines('src/input/dirty_guard.zig')} lines.")
print(f"- `src/input.zig` direct `AppWindow.` references: {appwindow_refs}.")
print(f"- Runtime direct input dirty assignments: {len(runtime_dirty)}.")
print("- Mouse, pointer, hover, drag, selection, preview, and wheel invalidation now routes through input effect helpers.")
print("- Top-of-file tests still set and assert AppWindow dirty globals intentionally.")
print("- No keyboard shortcut behavior or user-visible shortcut text changed.")
PY
cat /tmp/p3_3_input_dirty_boundary_results.md
cat /tmp/p3_3_input_dirty_boundary_results.md >> docs/superpowers/specs/2026-06-25-ui-state-debt-p3-3-design.md
```

- [ ] Run the fast suite:

```bash
zig build test
```

Expected: exits 0.

- [ ] Run the full suite once:

```bash
zig build test-full
```

Expected: exits 0. This may take 5-10 minutes on a cold or lightly cached build.

- [ ] Run whitespace validation:

```bash
git diff --check
```

Expected: no output.

- [ ] Run tracked-file Windows checkout safety:

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
git add docs/superpowers/specs/2026-06-25-ui-state-debt-p3-3-design.md
git commit -m "docs: record P3.3 input dirty boundary results"
```

## Final Acceptance Criteria

- `zig build test` passes after every task.
- `zig build test-full` passes at the final gate.
- Runtime input code from `fn applyInputEffect` through `// --- Maximize toggle (native window) ---` has zero direct `AppWindow.g_force_rebuild =` or `AppWindow.g_cells_valid =` assignments.
- `src/input/dirty_guard.zig` enforces the runtime dirty boundary in `zig build test`.
- Top-of-file tests may continue to set and assert AppWindow dirty globals.
- No keyboard shortcut behavior or user-visible shortcut text changes.
- Remaining input technical debt is structural size and AppWindow reference count, not manual runtime dirty-flag assignment.
