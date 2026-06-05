# File-Preview Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ctrl+left-click preview `.r`/`.R` scripts, and add ctrl+right-click (Cmd on macOS) to open the file under the cursor in the OS default app for local terminals.

**Architecture:** Part 1 is a one-line extension of `markdown_preview.detectKind`'s text-suffix list, which automatically flows into preview, hover-underline, and token extraction. Part 2 adds a pure predicate (`rightClickOpensInEditor`) in `terminal_link_action.zig` plus a thin `input.zig` handler that reuses the existing path extractor/resolver and `platform_open_url.open` (default-app open per OS).

**Tech Stack:** Zig. Fast unit suite `zig build test` (native, sub-second) for `preview_path.zig` + `terminal_link_action.zig`; full suite `zig build test-full` for `markdown_preview.zig` and the app graph.

---

## Test suite reference (read before starting)

Tests only run in the suite where the file is `_ = @import`ed:

- `src/markdown_preview.zig` → registered in `src/test_main.zig` only ⇒ its tests run under **`zig build test-full`**.
- `src/input/preview_path.zig` and `src/input/terminal_link_action.zig` → registered in `src/test_fast.zig` only ⇒ their tests run under **`zig build test`**.

Both suites exit 0 when green. The full suite baseline is ~670+ passed / a few skipped / **0 failed**; the exact count grows as tasks add tests.

---

## File Structure

- `src/markdown_preview.zig` — modify: add `".r"` to `text_file_suffixes`; extend the existing `detectKind` test.
- `src/input/preview_path.zig` — modify: extend the existing `looksLikePreviewPath` test (no production change; behavior flows from `detectKind`).
- `src/input/terminal_link_action.zig` — modify: add the pure `rightClickOpensInEditor` predicate + its test.
- `src/input.zig` — modify: add the `openInEditorAtRightClick` helper and call it from the right-click-release branch before `handleConfiguredRightClick()`.

---

## Task 1: Preview `.r`/`.R` scripts

**Files:**
- Modify: `src/markdown_preview.zig` (test block at ~452-474; `text_file_suffixes` at ~59-74)
- Modify: `src/input/preview_path.zig` (test at ~28-33)

- [ ] **Step 1: Write the failing assertions (both files)**

In `src/markdown_preview.zig`, inside the existing `detectKind`/`sourceLimit` test, add two lines immediately after the `deploy.sh` assertion:

```zig
    try std.testing.expectEqual(Kind.text, detectKind("deploy.sh").?);
    try std.testing.expectEqual(Kind.text, detectKind("plot.r").?);
    try std.testing.expectEqual(Kind.text, detectKind("model.R").?);
```

In `src/input/preview_path.zig`, extend the existing test:

```zig
test "looksLikePreviewPath: markdown and image and pdf paths" {
    try std.testing.expect(looksLikePreviewPath("README.md"));
    try std.testing.expect(looksLikePreviewPath("notes.pdf"));
    try std.testing.expect(looksLikePreviewPath("~/file"));
    try std.testing.expect(looksLikePreviewPath("dir/file"));
    try std.testing.expect(looksLikePreviewPath("model.R"));
    try std.testing.expect(looksLikePreviewPath("plot.r"));
}
```

- [ ] **Step 2: Run the fast suite to verify the preview_path assertion fails**

Run: `zig build test`
Expected: FAIL — `looksLikePreviewPath("model.R")` is false today (`detectKind` returns null, no `/`, no `~`, no drive, not pdf/image), so the `expect` fails.

- [ ] **Step 3: Run the full suite to verify the detectKind assertion fails**

Run: `zig build test-full`
Expected: FAIL — `detectKind("plot.r")` returns `null`, so `.?` panics / the test fails in `markdown_preview.zig`.

- [ ] **Step 4: Add `.r` to the text-file suffix list**

In `src/markdown_preview.zig`, append `".r"` to `text_file_suffixes` (case-insensitive match covers both `.r` and `.R`):

```zig
const text_file_suffixes = &.{
    ".txt",
    ".text",
    ".rs",
    ".c",
    ".h",
    ".cpp",
    ".zig",
    ".py",
    ".js",
    ".ts",
    ".json",
    ".yaml",
    ".toml",
    ".sh",
    ".r",
};
```

(Note: `.rs` is matched earlier in the list, so adding `.r` does not affect Rust files; `endsWithIgnoreCase(path, ".r")` does not match a `.rs` suffix anyway.)

- [ ] **Step 5: Run the fast suite to verify it passes**

Run: `zig build test`
Expected: PASS (exit 0) — `preview_path` test now green.

- [ ] **Step 6: Run the full suite to verify it passes**

Run: `zig build test-full`
Expected: PASS (exit 0) — `markdown_preview` test now green, 0 failed.

- [ ] **Step 7: Commit**

```bash
git add src/markdown_preview.zig src/input/preview_path.zig
git commit -m "feat(preview): recognize .r/.R scripts as previewable text

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `rightClickOpensInEditor` pure predicate

**Files:**
- Modify: `src/input/terminal_link_action.zig` (add predicate near `terminalPathClickAction` ~29-33; add test at end of file)

- [ ] **Step 1: Write the failing test**

Append to `src/input/terminal_link_action.zig` (after the last existing test):

```zig
test "right-click opens local files in editor only with primary modifier" {
    // Local terminal + primary modifier (Ctrl/Cmd), no shift/alt → open.
    try std.testing.expect(rightClickOpensInEditor(.local, true, false, false));
    // Remote terminals never open a local editor.
    try std.testing.expect(!rightClickOpensInEditor(.ssh, true, false, false));
    try std.testing.expect(!rightClickOpensInEditor(.wsl, true, false, false));
    // Plain right-click (no modifier) falls through to the configured action.
    try std.testing.expect(!rightClickOpensInEditor(.local, false, false, false));
    // Shift/Alt are reserved for other gestures.
    try std.testing.expect(!rightClickOpensInEditor(.local, true, true, false));
    try std.testing.expect(!rightClickOpensInEditor(.local, true, false, true));
}
```

- [ ] **Step 2: Run the fast suite to verify it fails**

Run: `zig build test`
Expected: FAIL — compile error in `terminal_link_action.zig`: no declaration named `rightClickOpensInEditor`.

- [ ] **Step 3: Implement the predicate**

In `src/input/terminal_link_action.zig`, add immediately after `terminalPathClickAction` (around line 33):

```zig
/// Ctrl+right-click (Cmd on macOS) opens the file under the cursor in the OS
/// default app, but only for local terminals — a local app cannot open an SSH
/// or WSL path. `mod` is the primaryOpenMod result. Plain right-click and
/// remote terminals fall through to the configured right-click action.
pub fn rightClickOpensInEditor(launch_kind: platform_pty_command.LaunchKind, mod: bool, shift: bool, alt: bool) bool {
    return launch_kind == .local and mod and !shift and !alt;
}
```

- [ ] **Step 4: Run the fast suite to verify it passes**

Run: `zig build test`
Expected: PASS (exit 0).

- [ ] **Step 5: Commit**

```bash
git add src/input/terminal_link_action.zig
git commit -m "feat(input): add rightClickOpensInEditor decision for local terminals

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Wire ctrl+right-click to open in the OS default app

This task is integration glue with no unit test (it depends on the live
`Surface`/`AppWindow` graph), matching the existing untested click handlers in
`input.zig`. It is verified by compilation, the green suites, and a manual GUI
check.

**Files:**
- Modify: `src/input.zig` (add helper near `downloadTerminalFileAtCell` ~2835; edit right-click branch at ~3052-3056)

- [ ] **Step 1: Add the `openInEditorAtRightClick` helper**

In `src/input.zig`, add this function immediately before `fn handleMouseButton` (around line 2837). All referenced helpers already exist in this file: `split_layout.surfaceAtPoint` (`src/appwindow/split_layout.zig:61`, takes `i32, i32`), `primaryOpenMod` (alias, line 102), `terminal_link_action` (import, line 51), `mouseToSurfaceCell` (line 754, takes `f64, f64`), `extractPreviewPathAtCell` (line 2581), `resolveTerminalPreviewPath` (alias, line 74), `platform_open_url` (import, line 29), `AppWindow.g_allocator`, and `platform_input.MouseButtonEvent`.

```zig
/// Ctrl+right-click (Cmd on macOS) over a local terminal opens the file path
/// under the cursor in the OS default app. Returns true only when it launched
/// an open; false otherwise so the caller falls through to the configured
/// right-click action (copy/paste) for plain right-clicks, remote terminals,
/// empty space, and non-path text.
fn openInEditorAtRightClick(ev: platform_input.MouseButtonEvent) bool {
    const surface = split_layout.surfaceAtPoint(ev.x, ev.y) orelse return false;
    if (!terminal_link_action.rightClickOpensInEditor(
        surface.launch_kind,
        primaryOpenMod(ev.ctrl, ev.super),
        ev.shift,
        ev.alt,
    )) return false;

    const allocator = AppWindow.g_allocator orelse return false;
    const cell_pos = mouseToSurfaceCell(surface, @floatFromInt(ev.x), @floatFromInt(ev.y));

    const path = extractPreviewPathAtCell(allocator, surface, cell_pos) orelse return false;
    defer allocator.free(path);

    const resolved = resolveTerminalPreviewPath(allocator, surface, path) catch return false;
    defer allocator.free(resolved);

    return platform_open_url.open(allocator, .{ .url = resolved });
}
```

- [ ] **Step 2: Call it from the right-click-release branch**

In `src/input.zig`, change the existing branch (around line 3052):

```zig
    // Right-click follows Ghostty-compatible right-click-action config.
    if (ev.button == .right and ev.action == .release) {
        handleConfiguredRightClick();
        return;
    }
```

to:

```zig
    // Ctrl+right-click (Cmd on macOS) over a local terminal opens the file under
    // the cursor in the OS default app; otherwise follow the configured action.
    if (ev.button == .right and ev.action == .release) {
        if (openInEditorAtRightClick(ev)) return;
        handleConfiguredRightClick();
        return;
    }
```

- [ ] **Step 3: Build the app binary to verify it compiles**

Run: `zig build`
Expected: PASS (exit 0), no compile errors.

- [ ] **Step 4: Run the fast suite**

Run: `zig build test`
Expected: PASS (exit 0).

- [ ] **Step 5: Run the full suite**

Run: `zig build test-full`
Expected: PASS (exit 0), 0 failed.

- [ ] **Step 6: Commit**

```bash
git add src/input.zig
git commit -m "feat(input): ctrl+right-click opens local file under cursor in OS default app

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 7: Manual GUI verification (note — not a code step)**

In a local terminal pane:
1. Print a path to a local `.R` file (e.g. `ls` in a dir containing `model.R`, or `echo ~/model.R`).
2. **Ctrl+left-click** (Cmd on macOS) the `model.R` token → the in-app preview panel opens showing the file as text. Confirm the token underlines on ctrl-hover.
3. **Ctrl+right-click** (Cmd on macOS) the `model.R` token → the OS default app for `.R` opens the file.
4. **Plain right-click** the same token → still performs the configured `right-click-action` (copy/paste), not an editor open.
5. In an **SSH or WSL** pane, **Ctrl+right-click** a path → falls through to the configured action (no local-editor open).

---

## Notes for the implementer

- Run commands from the worktree root: `/home/xzg/project/phantty/.claude/worktrees/feat-file-preview-enhance`.
- `platform_open_url.open(allocator, .{ .url = path })` uses the default `.kind = .unknown`, which opens with the OS default app (Linux `xdg-open`, macOS `open <path>`, Windows `ShellExecuteW("open", …)`). It is best-effort and returns `false` on failure — that is fine; do not add an existence pre-check.
- Do not add a config key or toggle; ctrl+right-click is always available on local terminals and plain right-click is unchanged.
- GUI verification cannot run on this Linux/WSL host (no Linux GUI backend); record it as pending for macOS/Windows if you cannot run it.
