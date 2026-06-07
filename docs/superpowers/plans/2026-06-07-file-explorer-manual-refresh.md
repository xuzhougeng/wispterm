# File Explorer Manual Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a manual refresh capability to the file explorer (local / WSL / SSH) via a clickable header button, a keyboard shortcut (`Ctrl/Cmd+R`, plus `F5`), and force-rescan-on-reopen, so externally-created files appear without restarting the panel.

**Architecture:** Introduce one shared `file_explorer.refresh()` that re-runs the existing `rescan()` (which already dispatches local/WSL synchronous vs. remote async) while preserving the selected entry by path and the scroll offset. Wire three triggers to it: a header refresh button (mirrors the existing browser-panel refresh button at header button index 1), keyboard keys in `handleFileExplorerKey`, and a `force` flag threaded through the `syncPanelForTerminalTarget` chain so re-opening the panel bypasses the unchanged-target guard.

**Tech Stack:** Zig; OpenGL UI primitives (`ui_pipeline`); existing `hit_test` panel-header button geometry; threadlocal panel state in `src/file_explorer.zig`.

**Reference spec:** `docs/superpowers/specs/2026-06-07-file-explorer-manual-refresh-design.md`

**Build/test notes (macOS):** Default `zig build` targets Windows. Use `zig build test` for the fast unit suite (links + passes on macOS) and `zig build macos-app -Dtarget=aarch64-macos` for the app build. Run commands from the repo root `/Users/xuzhougeng/Documents/Code/phantty`.

---

### Task 1: Add the `key_f5` virtual-key constant

**Files:**
- Modify: `src/platform/input_events.zig:20`

- [ ] **Step 1: Add the constant**

In `src/platform/input_events.zig`, immediately after the `key_down` line (`pub const key_down: KeyCode = 0x28;`), add the F5 virtual-key code:

```zig
pub const key_f5: KeyCode = 0x74;
```

(`KeyCode` is `usize`; `0x74` is Windows `VK_F5`. On macOS this is best-effort — the primary refresh keys are `Ctrl/Cmd+R` and the button.)

- [ ] **Step 2: Verify it compiles**

Run: `zig build test`
Expected: builds and the existing suite passes (no behavior change yet).

- [ ] **Step 3: Commit**

```bash
git add src/platform/input_events.zig
git commit -m "feat(file-explorer): add key_f5 virtual-key constant

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Core `refresh()` + selection-restore logic

**Files:**
- Modify: `src/file_explorer.zig` (add threadlocal restore state + `refresh()` + `applyRefreshRestore()`; hook the async `.rescan` completion in `tickAsync`)
- Test: `src/file_explorer.zig` (unit tests appended near the existing tests around line 1960)

- [ ] **Step 1: Write the failing tests**

Append these to `src/file_explorer.zig` right after the existing test `test "file_explorer: unchanged terminal target preserves file state" { ... }` (which ends at line 2001). The helper `setFlatEntryPathForTest` is shared by both tests:

```zig
fn setFlatEntryPathForTest(idx: usize, path: []const u8) void {
    @memcpy(g_entries[idx].path_buf[0..path.len], path);
    g_entries[idx].path_len = @intCast(path.len);
}

test "file_explorer: refresh restore re-selects entry by path" {
    const saved_entry_count = g_entry_count;
    const saved_selected = g_selected;
    const saved_scroll = g_scroll_offset;
    const saved_pending = g_refresh_restore_pending;
    const saved_keep_len = g_refresh_keep_path_len;
    defer {
        g_entry_count = saved_entry_count;
        g_selected = saved_selected;
        g_scroll_offset = saved_scroll;
        g_refresh_restore_pending = saved_pending;
        g_refresh_keep_path_len = saved_keep_len;
    }

    g_entry_count = 3;
    setFlatEntryPathForTest(0, "a.txt");
    setFlatEntryPathForTest(1, "b.txt");
    setFlatEntryPathForTest(2, "c.txt");
    g_selected = null;
    g_scroll_offset = 0;

    g_refresh_restore_pending = true;
    g_refresh_keep_scroll = 0;
    @memcpy(g_refresh_keep_path[0..5], "b.txt");
    g_refresh_keep_path_len = 5;

    applyRefreshRestore();

    try std.testing.expectEqual(@as(?usize, 1), g_selected);
    try std.testing.expectEqual(false, g_refresh_restore_pending);
}

test "file_explorer: refresh restore clears selection when path is gone" {
    const saved_entry_count = g_entry_count;
    const saved_selected = g_selected;
    const saved_pending = g_refresh_restore_pending;
    const saved_keep_len = g_refresh_keep_path_len;
    defer {
        g_entry_count = saved_entry_count;
        g_selected = saved_selected;
        g_refresh_restore_pending = saved_pending;
        g_refresh_keep_path_len = saved_keep_len;
    }

    g_entry_count = 2;
    setFlatEntryPathForTest(0, "x.txt");
    setFlatEntryPathForTest(1, "y.txt");
    g_selected = null;

    g_refresh_restore_pending = true;
    g_refresh_keep_scroll = 0;
    @memcpy(g_refresh_keep_path[0..8], "gone.txt");
    g_refresh_keep_path_len = 8;

    applyRefreshRestore();

    try std.testing.expectEqual(@as(?usize, null), g_selected);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: compile error — `g_refresh_restore_pending`, `g_refresh_keep_path`, `g_refresh_keep_path_len`, `g_refresh_keep_scroll`, and `applyRefreshRestore` are undefined.

- [ ] **Step 3: Add the threadlocal restore state**

In `src/file_explorer.zig`, immediately before `pub fn rescan() void {` (line 609), add:

```zig
// Manual-refresh restore state: capture selection (by path) + scroll before a
// rescan rebuilds the flat list, then re-apply once the list is ready. Only
// refresh() sets `pending`, so ordinary rescans (tab switch, etc.) never restore.
threadlocal var g_refresh_restore_pending: bool = false;
threadlocal var g_refresh_keep_path: [512]u8 = undefined;
threadlocal var g_refresh_keep_path_len: u16 = 0;
threadlocal var g_refresh_keep_scroll: f32 = 0;
```

- [ ] **Step 4: Add `refresh()` and `applyRefreshRestore()`**

In `src/file_explorer.zig`, immediately after the end of `rescanRemote()` (the closing `}` at line 659), add:

```zig
/// Manually re-list the current directory, preserving selection (by path) and
/// scroll where possible. Works for local, WSL, and remote (SSH) modes.
/// For remote, the list is rebuilt asynchronously and the restore is applied
/// when the rescan job completes in tickAsync().
pub fn refresh() void {
    g_refresh_restore_pending = true;
    g_refresh_keep_scroll = g_scroll_offset;
    g_refresh_keep_path_len = 0;
    if (g_selected) |sel| {
        if (sel < g_entry_count) {
            const p = g_entries[sel].path_buf[0..g_entries[sel].path_len];
            const n: u16 = @intCast(@min(p.len, g_refresh_keep_path.len));
            @memcpy(g_refresh_keep_path[0..n], p[0..n]);
            g_refresh_keep_path_len = n;
        }
    }

    rescan();

    if (g_mode == .remote and g_has_ssh_conn) {
        // Async rebuild; restore happens in tickAsync's .rescan completion.
        setTransferStatus(.in_progress, "Refreshing…");
    } else {
        applyRefreshRestore();
    }
}

fn applyRefreshRestore() void {
    if (!g_refresh_restore_pending) return;
    g_refresh_restore_pending = false;

    if (g_refresh_keep_path_len > 0) {
        if (findEntryByPath(g_refresh_keep_path[0..g_refresh_keep_path_len])) |idx| {
            g_selected = idx;
        }
    }
    g_scroll_offset = g_refresh_keep_scroll;
    clampFileScroll();
    if (g_selected != null) ensureSelectedVisible();
    setTransferStatus(.success, "Refreshed");
}
```

- [ ] **Step 5: Hook the async `.rescan` completion**

In `src/file_explorer.zig`, inside `tickAsync`'s `.rescan =>` branch, the list is rebuilt at line 597:

```zig
            const root = g_root_path[0..g_root_path_len];
            _ = insertBackendChildren(0, job.entries[0..job.count], 0, root, '/');
```

Add the restore call on the next line (still inside the `.rescan =>` block, before its closing `},`):

```zig
            const root = g_root_path[0..g_root_path_len];
            _ = insertBackendChildren(0, job.entries[0..job.count], 0, root, '/');
            applyRefreshRestore();
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS, including the two new `refresh restore` tests.

- [ ] **Step 7: Commit**

```bash
git add src/file_explorer.zig
git commit -m "feat(file-explorer): add refresh() with selection/scroll restore

refresh() re-runs rescan() (local/WSL sync, remote async) and re-selects the
previously selected entry by path. Remote restore is applied when the async
rescan job completes in tickAsync.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Thread a `force` flag through the sync chain (reopen forces a rescan)

This is an atomic signature change across three files plus one internal test caller — the build stays red until every call site is updated, so do all edits before building.

**Files:**
- Modify: `src/file_explorer.zig:301-311` (signature + guard) and `src/file_explorer.zig:1994` (test caller)
- Modify: `src/AppWindow.zig:2895-2906` and `src/AppWindow.zig:2922-2960` (helpers) and `src/AppWindow.zig:2483`, `:2507` (callers)
- Modify: `src/input.zig:436-439` (toggle passes `force = true`)

- [ ] **Step 1: Update `syncPanelForTerminalTarget`**

In `src/file_explorer.zig`, replace the whole function (lines 301-311):

```zig
pub fn syncPanelForTerminalTarget(target: TerminalPanelTarget) void {
    if (terminalTargetMatchesCurrentState(target)) return;

    applyTerminalTargetState(target);
    switch (target) {
        .remote => rescanRemote(),
        .wsl, .local => {
            if (g_root_path_len > 0) rescan();
        },
    }
}
```

with:

```zig
pub fn syncPanelForTerminalTarget(target: TerminalPanelTarget, force: bool) void {
    const matches = terminalTargetMatchesCurrentState(target);
    if (matches and !force) return;

    if (!matches) applyTerminalTargetState(target);

    if (matches and force) {
        // Re-opening the same target: force a rescan but keep the selection.
        refresh();
    } else {
        switch (target) {
            .remote => rescanRemote(),
            .wsl, .local => {
                if (g_root_path_len > 0) rescan();
            },
        }
    }
}
```

- [ ] **Step 2: Update the internal test caller**

In `src/file_explorer.zig:1994`, change:

```zig
    syncPanelForTerminalTarget(.{ .local = "" });
```

to:

```zig
    syncPanelForTerminalTarget(.{ .local = "" }, false);
```

(The test `"file_explorer: unchanged terminal target preserves file state"` still passes: `force = false` + matching target → early return, state preserved.)

- [ ] **Step 3: Update `AppWindow.syncVisibleFileExplorerForActiveTab`**

In `src/AppWindow.zig`, replace the function at line 2895:

```zig
pub fn syncVisibleFileExplorerForActiveTab() void {
    if (!file_explorer.isVisibleForActiveTab()) return;

    const is_ai_tab = activeAiChat() != null;
    if (is_ai_tab) {
        file_explorer.syncPanelForTabKind(true);
        syncFileExplorerAgentHistoryRows();
        return;
    }

    syncFileExplorerToActiveTerminalSurface();
}
```

with:

```zig
pub fn syncVisibleFileExplorerForActiveTab(force: bool) void {
    if (!file_explorer.isVisibleForActiveTab()) return;

    const is_ai_tab = activeAiChat() != null;
    if (is_ai_tab) {
        file_explorer.syncPanelForTabKind(true);
        syncFileExplorerAgentHistoryRows();
        return;
    }

    syncFileExplorerToActiveTerminalSurface(force);
}
```

- [ ] **Step 4: Update `syncFileExplorerToActiveTerminalSurface`**

In `src/AppWindow.zig`, change the signature at line 2922 from:

```zig
fn syncFileExplorerToActiveTerminalSurface() void {
```

to:

```zig
fn syncFileExplorerToActiveTerminalSurface(force: bool) void {
```

Then pass `force` to each `syncPanelForTerminalTarget` call inside it (there are 4: the remote one at ~2938, the wsl one at ~2949, and the two local ones at ~2958 and ~2973). After editing they read:

```zig
                file_explorer.syncPanelForTerminalTarget(.{
                    .remote = .{
                        .conn = &conn,
                        .cwd = surface.getCwd() orelse "",
                    },
                }, force);
```

```zig
            file_explorer.syncPanelForTerminalTarget(.{ .wsl = surface.getCwd() orelse "~" }, force);
```

```zig
                    file_explorer.syncPanelForTerminalTarget(.{ .local = local_path }, force);
```

```zig
                file_explorer.syncPanelForTerminalTarget(.{ .local = initial_cwd }, force);
```

- [ ] **Step 5: Update the two automatic-sync callers**

In `src/AppWindow.zig`, the automatic resync points must NOT force (tab switches keep the guard). Change line 2483:

```zig
    syncVisibleFileExplorerForActiveTab();
```
to
```zig
    syncVisibleFileExplorerForActiveTab(false);
```

and line 2507 the same way:

```zig
    syncVisibleFileExplorerForActiveTab(false);
```

- [ ] **Step 6: Update the toggle caller to force**

In `src/input.zig`, the `toggleFileExplorer` body (lines 436-439) is:

```zig
    file_explorer.toggle();
    if (file_explorer.isVisibleForActiveTab()) {
        AppWindow.syncVisibleFileExplorerForActiveTab();
    }
```

Change the inner call to force a rescan when the panel becomes visible:

```zig
    file_explorer.toggle();
    if (file_explorer.isVisibleForActiveTab()) {
        AppWindow.syncVisibleFileExplorerForActiveTab(true);
    }
```

- [ ] **Step 7: Build and run tests**

Run: `zig build test`
Expected: PASS. No remaining call sites with the old 1-arg signature.

- [ ] **Step 8: Commit**

```bash
git add src/file_explorer.zig src/AppWindow.zig src/input.zig
git commit -m "feat(file-explorer): force rescan when the panel is (re)opened

Thread a force flag through syncPanelForTerminalTarget so toggling the panel
visible re-lists even when the target is unchanged; automatic tab-switch syncs
stay guarded (force=false). Re-open reuses refresh() to keep the selection.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Keyboard shortcuts (`Ctrl/Cmd+R`, `F5`)

**Files:**
- Modify: `src/input.zig:2086-2157` (the `handleFileExplorerKey` normal-navigation switch)

- [ ] **Step 1: Extend the `'R'` branch and add an `F5` prong**

In `src/input.zig`, inside the `switch (ev.key_code)` of `handleFileExplorerKey`, replace the existing `'R'` branch (lines 2108-2114):

```zig
        0x52 => { // 'R' key = rename
            if (!ev.ctrl and !ev.alt and !ev.super) {
                file_explorer.startRename();
                return true;
            }
            return false;
        },
```

with (adds `Ctrl/Cmd+R` = refresh, keeps bare `R` = rename):

```zig
        0x52 => { // 'R': bare = rename, Ctrl/Cmd+R = refresh
            if (!ev.ctrl and !ev.alt and !ev.super) {
                file_explorer.startRename();
                return true;
            }
            if ((ev.ctrl or ev.super) and !ev.alt and !ev.shift) {
                file_explorer.refresh();
                return true;
            }
            return false;
        },
```

Then add an `F5` prong. Insert it right before the `else => return false,` at line 2156:

```zig
        platform_input.key_f5 => {
            file_explorer.refresh();
            return true;
        },
        else => return false,
```

- [ ] **Step 2: Build and run tests**

Run: `zig build test`
Expected: PASS (compiles; `platform_input.key_f5` resolves to the constant from Task 1).

- [ ] **Step 3: Commit**

```bash
git add src/input.zig
git commit -m "feat(file-explorer): Ctrl/Cmd+R and F5 refresh when focused

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Clickable header refresh button

The button reuses the existing panel-header button geometry: the close button is index 0 (rightmost), the refresh button is index 1 (immediately left of close). The render mirrors `renderHeaderCloseButton`; the glyph mirrors the browser panel's refresh glyph in `overlays.zig`.

**Files:**
- Modify: `src/renderer/file_explorer_renderer.zig` (add `headerRefreshRect`, `renderHeaderRefreshButton`; call them in `renderFiles` and widen-exclude the title text)
- Modify: `src/input.zig` (add `hitTestFileExplorerRefreshButton`; dispatch on press)
- Test: `src/input/hit_test.zig` (geometry test that index 1 sits left of close and is hit-distinct)

- [ ] **Step 1: Write the failing geometry test**

In `src/input/hit_test.zig`, append after the existing `panelHeaderCloseButton` tests (after line 211):

```zig
test "panelHeaderSecondButton: sits left of the close button and is hit-distinct" {
    const layout: PanelHeaderLayout = .{
        .visible = true,
        .left = 0,
        .right = 400,
        .top = 30,
        .height = 40, // y spans [30, 70)
    };
    const close_rect = panelCloseButtonRect(layout).?;
    const second_rect = panelSecondButtonRect(layout).?;
    // Second button is strictly to the left of the close button.
    try std.testing.expect(second_rect.left + second_rect.width <= close_rect.left);
    // A point inside the second button hits second, not close.
    const cx = second_rect.left + second_rect.width / 2;
    const cy = 50;
    try std.testing.expect(panelHeaderSecondButton(layout, cx, cy));
    try std.testing.expect(!panelHeaderCloseButton(layout, cx, cy));
}
```

- [ ] **Step 2: Run the test to verify it passes (geometry already exists)**

Run: `zig build test`
Expected: PASS. This test documents the geometry the renderer/hit-test rely on; it should pass against the existing `panelHeaderButtonRect`. If it fails, stop and reconcile before continuing.

- [ ] **Step 3: Add `headerRefreshRect` in the renderer**

In `src/renderer/file_explorer_renderer.zig`, immediately after `headerCloseRect` (ends line 51), add:

```zig
fn headerRefreshRect(panel_x: f32, panel_w: f32) HeaderCloseRect {
    const rect = hit_test.panelSecondButtonRect(.{
        .visible = true,
        .left = panel_x,
        .right = panel_x + panel_w,
        .top = 0,
        .height = 1,
    }) orelse return .{ .x = panel_x + panel_w, .w = 0 };
    return .{ .x = @floatCast(rect.left), .w = @floatCast(rect.width) };
}
```

- [ ] **Step 4: Add `renderHeaderRefreshButton` in the renderer**

In `src/renderer/file_explorer_renderer.zig`, immediately after `renderHeaderCloseButton` (ends line 77), add:

```zig
fn renderHeaderRefreshButton(
    titlebar_h: f32,
    header_y: f32,
    header_h: f32,
    panel_x: f32,
    panel_w: f32,
    palette: Palette,
) void {
    const r = headerRefreshRect(panel_x, panel_w);
    if (r.w <= 0) return;
    const hovered = blk: {
        const win = AppWindow.g_window orelse break :blk false;
        if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
        break :blk hit_test.panelHeaderSecondButton(.{
            .visible = true,
            .left = panel_x,
            .right = panel_x + panel_w,
            .top = titlebar_h,
            .height = header_h,
        }, @floatFromInt(win.mouse_x), @floatFromInt(win.mouse_y));
    };
    if (hovered) {
        ui_pipeline.fillQuad(r.x + 6, header_y + @round((header_h - 20) / 2), 20, 20, blend(palette.bg, palette.fg, 0.14));
    }
    const glyph = if (hovered) palette.fg else palette.text_muted;
    const cx = r.x + r.w / 2;
    const cy = header_y + header_h / 2;
    // Simple "refresh" glyph: an open square-arc drawn from 4 thin quads.
    ui_pipeline.fillQuad(cx - 5, cy - 6, 8, 1.5, glyph);
    ui_pipeline.fillQuad(cx + 3, cy - 6, 1.5, 6, glyph);
    ui_pipeline.fillQuad(cx - 5, cy + 4.5, 8, 1.5, glyph);
    ui_pipeline.fillQuad(cx - 6.5, cy - 1, 1.5, 6, glyph);
}
```

- [ ] **Step 5: Render the button and exclude it from the title text width**

In `src/renderer/file_explorer_renderer.zig`, in `renderFiles`, replace lines 168-171:

```zig
    const close = headerCloseRect(panel_x, explorer_w);
    const label_end = titlebar.renderTextLimited(mode_label, panel_x + 12, header_text_y, mode_color, @max(1.0, close.x - panel_x - 20));
    _ = titlebar.renderTextLimited(" Explorer", label_end, header_text_y, header_text, @max(1.0, close.x - label_end - 8));
    renderHeaderCloseButton(titlebar_h, header_y, header_h, panel_x, explorer_w, palette);
```

with:

```zig
    const close = headerCloseRect(panel_x, explorer_w);
    const refresh_rect = headerRefreshRect(panel_x, explorer_w);
    const text_limit_x = if (refresh_rect.w > 0) refresh_rect.x else close.x;
    const label_end = titlebar.renderTextLimited(mode_label, panel_x + 12, header_text_y, mode_color, @max(1.0, text_limit_x - panel_x - 20));
    _ = titlebar.renderTextLimited(" Explorer", label_end, header_text_y, header_text, @max(1.0, text_limit_x - label_end - 8));
    renderHeaderRefreshButton(titlebar_h, header_y, header_h, panel_x, explorer_w, palette);
    renderHeaderCloseButton(titlebar_h, header_y, header_h, panel_x, explorer_w, palette);
```

(The agent-history header in `renderAgentHistory` is intentionally left with only the close button.)

- [ ] **Step 6: Add the hit-test helper in input.zig**

In `src/input.zig`, immediately after `hitTestFileExplorerCloseButton` (ends line 1834), add:

```zig
fn hitTestFileExplorerRefreshButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderSecondButton(fileExplorerHeaderLayout() orelse return false, xpos, ypos);
}
```

- [ ] **Step 7: Dispatch the click on press**

In `src/input.zig`, the press handler has (around line 3196):

```zig
            if (hitTestFileExplorerCloseButton(xpos, ypos)) {
                closeFileExplorerPanel();
                return;
            }
```

Insert the refresh dispatch immediately after that block (only act in files mode, so it never fires over the agent-history header which has no refresh button):

```zig
            if (hitTestFileExplorerCloseButton(xpos, ypos)) {
                closeFileExplorerPanel();
                return;
            }
            if (file_explorer.g_panel_mode == .files and hitTestFileExplorerRefreshButton(xpos, ypos)) {
                file_explorer.refresh();
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                return;
            }
```

- [ ] **Step 8: Build and run tests**

Run: `zig build test`
Expected: PASS (including the new `panelHeaderSecondButton` geometry test).

- [ ] **Step 9: Build the macOS app**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: builds successfully.

- [ ] **Step 10: Commit**

```bash
git add src/renderer/file_explorer_renderer.zig src/input.zig src/input/hit_test.zig
git commit -m "feat(file-explorer): clickable header refresh button

Adds a refresh button at header index 1 (left of close), mirroring the browser
panel's refresh button; click dispatches file_explorer.refresh() in files mode.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Final verification (manual)

**Files:** none (manual verification).

- [ ] **Step 1: Confirm the full build**

Run: `zig build test && zig build macos-app -Dtarget=aarch64-macos`
Expected: both succeed.

- [ ] **Step 2: macOS local-tab manual check**

Open the app, open a local terminal tab, `Ctrl+Shift+Alt+E` to show the explorer. In the shell run `touch __refresh_probe.txt`. Then verify each trigger surfaces the new file:
- Click the header refresh button → `__refresh_probe.txt` appears.
- Focus the explorer and press `Ctrl+R` (and `Cmd+R`) → appears.
- Press `Ctrl+Shift+Alt+E` twice (close then reopen) → appears.
Clean up: `rm __refresh_probe.txt`, refresh, confirm it disappears.

- [ ] **Step 3: WSL and SSH manual checks (where available)**

Repeat Step 2 in a WSL tab and an SSH tab. For SSH specifically confirm:
- After refresh the previously selected file stays selected (selection restored by path once the async list returns).
- Rapidly clicking refresh several times does not show a spurious "SSH list busy" error.

- [ ] **Step 4: Regression checks**

- Bare `R` on a selected entry still starts rename (not refresh).
- The close button still closes the panel.
- Switching tabs does not trigger an extra remote `ls` (automatic syncs remain `force=false`).

- [ ] **Step 5: Finish the branch**

Use the `superpowers:finishing-a-development-branch` skill to decide how to integrate (the work is on branch `feat/file-explorer-manual-refresh`).

---

## Self-Review

**Spec coverage:**
- Root cause (unchanged-target guard) → Task 3 adds the `force` bypass. ✓
- Shared `refresh()` across local/WSL/remote, simple-rebuild + restore-by-path, remote async restore via `tickAsync` → Task 2. ✓
- Status feedback (`setTransferStatus`) → Task 2 (`Refreshing…` / `Refreshed`). ✓
- Trigger ① clickable refresh button at header index 1, mirrors browser panel, files-mode only → Task 5. ✓
- Trigger ② `Ctrl/Cmd+R` + `F5` when focused → Tasks 1 & 4. ✓
- Trigger ③ force-rescan-on-reopen via `force` through the sync chain, `force=true` only at toggle, `false` at auto-sync points → Task 3. ✓
- Affected files match the spec (`file_explorer.zig`, `input.zig`, `file_explorer_renderer.zig`, `AppWindow.zig`, `input_events.zig`). ✓
- YAGNI items (no file-watcher, no incremental merge, no legend) — not implemented. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code and exact commands. ✓

**Type consistency:** `refresh()`/`applyRefreshRestore()` names consistent across Tasks 2–5; `g_refresh_restore_pending`/`g_refresh_keep_path`/`g_refresh_keep_path_len`/`g_refresh_keep_scroll` defined in Task 2 and used in Tasks 2–3; `syncPanelForTerminalTarget(target, force)` 2-arg signature applied at all call sites (file_explorer.zig:301 & test:1994; AppWindow.zig ×4); `syncVisibleFileExplorerForActiveTab(force)` updated at all 3 call sites; `hitTestFileExplorerRefreshButton` / `panelHeaderSecondButton` / `panelSecondButtonRect` names match existing `hit_test` API. ✓
