# Sidebar Tab Drag Reorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users reorder Phantty tabs by dragging tab rows in the left sidebar.

**Architecture:** Add a model-level tab reorder operation in `src/appwindow/tab.zig` that moves `g_tabs` entries and keeps `g_active_tab` attached to the same logical tab. Route sidebar mouse drag state through `src/input.zig`, with `src/AppWindow.zig` exposing the reorder wrapper that refreshes UI caches after a move.

**Tech Stack:** Zig 0.15.2, existing `AppWindow` tab model, custom OpenGL sidebar renderer, Win32 mouse event queue, and `zig build test`.

---

## File Structure

- Modify `src/appwindow/tab.zig`: add `reorderTab(from_idx, to_idx) bool`, move per-tab visual state, and add unit tests that use empty `SplitTree` tab states.
- Modify `src/AppWindow.zig`: add `reorderTab(from_idx, to_idx) bool` wrapper that calls the tab model and refreshes tab-change UI state.
- Modify `src/input.zig`: add sidebar tab drag state, destination row calculation, press/move/release wiring, and cancellation cleanup.

No README shortcut change is needed because this feature adds mouse behavior and no keyboard binding.

## Task 1: Tab Model Reorder

**Files:**
- Modify: `src/appwindow/tab.zig`

- [ ] **Step 1: Write the failing tab reorder tests**

Append these helpers and tests near the bottom of `src/appwindow/tab.zig`, before the final `test { ... }` block if one exists:

```zig
fn resetTestTabGlobals() void {
    for (0..MAX_TABS) |idx| {
        g_tabs[idx] = null;
        g_tab_close_opacity[idx] = 0;
        g_tab_text_x_start[idx] = 0;
        g_tab_text_x_end[idx] = 0;
        g_tab_text_y_start[idx] = 0;
        g_tab_text_y_end[idx] = 0;
    }
    g_tab_count = 0;
    g_active_tab = 0;
    g_tab_close_pressed = null;
    g_last_frame_time_ms = 0;
    g_tab_rename_active = false;
    g_tab_rename_idx = 0;
    g_tab_rename_len = 0;
    g_tab_rename_cursor = 0;
    g_tab_rename_select_all = false;
}

fn makeTestTabState() TabState {
    return .{
        .kind = .terminal,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = null,
    };
}

test "tab: reorder moves active tab forward" {
    resetTestTabGlobals();
    var a = makeTestTabState();
    var b = makeTestTabState();
    var c = makeTestTabState();
    g_tabs[0] = &a;
    g_tabs[1] = &b;
    g_tabs[2] = &c;
    g_tab_count = 3;
    g_active_tab = 0;
    g_tab_close_opacity[0] = 0.1;
    g_tab_close_opacity[1] = 0.2;
    g_tab_close_opacity[2] = 0.3;

    try std.testing.expect(reorderTab(0, 2));

    try std.testing.expect(g_tabs[0].? == &b);
    try std.testing.expect(g_tabs[1].? == &c);
    try std.testing.expect(g_tabs[2].? == &a);
    try std.testing.expectEqual(@as(usize, 2), g_active_tab);
    try std.testing.expectEqual(@as(f32, 0.2), g_tab_close_opacity[0]);
    try std.testing.expectEqual(@as(f32, 0.3), g_tab_close_opacity[1]);
    try std.testing.expectEqual(@as(f32, 0.1), g_tab_close_opacity[2]);
}

test "tab: reorder moves active tab backward" {
    resetTestTabGlobals();
    var a = makeTestTabState();
    var b = makeTestTabState();
    var c = makeTestTabState();
    g_tabs[0] = &a;
    g_tabs[1] = &b;
    g_tabs[2] = &c;
    g_tab_count = 3;
    g_active_tab = 2;

    try std.testing.expect(reorderTab(2, 0));

    try std.testing.expect(g_tabs[0].? == &c);
    try std.testing.expect(g_tabs[1].? == &a);
    try std.testing.expect(g_tabs[2].? == &b);
    try std.testing.expectEqual(@as(usize, 0), g_active_tab);
}

test "tab: reorder preserves selected logical tab when another tab moves" {
    resetTestTabGlobals();
    var a = makeTestTabState();
    var b = makeTestTabState();
    var c = makeTestTabState();
    g_tabs[0] = &a;
    g_tabs[1] = &b;
    g_tabs[2] = &c;
    g_tab_count = 3;
    g_active_tab = 1;

    try std.testing.expect(reorderTab(0, 2));
    try std.testing.expect(g_tabs[g_active_tab].? == &b);
    try std.testing.expectEqual(@as(usize, 0), g_active_tab);

    try std.testing.expect(reorderTab(2, 0));
    try std.testing.expect(g_tabs[g_active_tab].? == &b);
    try std.testing.expectEqual(@as(usize, 1), g_active_tab);
}

test "tab: reorder rejects invalid and no-op moves" {
    resetTestTabGlobals();
    var a = makeTestTabState();
    g_tabs[0] = &a;
    g_tab_count = 1;
    g_active_tab = 0;

    try std.testing.expect(!reorderTab(0, 0));
    try std.testing.expect(!reorderTab(0, 1));
    try std.testing.expect(!reorderTab(1, 0));
    try std.testing.expect(g_tabs[0].? == &a);
    try std.testing.expectEqual(@as(usize, 0), g_active_tab);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`

Expected: FAIL with an error that `reorderTab` is undeclared.

- [ ] **Step 3: Implement `reorderTab` in the tab model**

Add this helper and public function after `closeTab` and before `switchTab` in `src/appwindow/tab.zig`:

```zig
const TabVisualState = struct {
    close_opacity: f32,
    text_x_start: f32,
    text_x_end: f32,
    text_y_start: f32,
    text_y_end: f32,
};

fn visualStateAt(idx: usize) TabVisualState {
    return .{
        .close_opacity = g_tab_close_opacity[idx],
        .text_x_start = g_tab_text_x_start[idx],
        .text_x_end = g_tab_text_x_end[idx],
        .text_y_start = g_tab_text_y_start[idx],
        .text_y_end = g_tab_text_y_end[idx],
    };
}

fn setVisualStateAt(idx: usize, state: TabVisualState) void {
    g_tab_close_opacity[idx] = state.close_opacity;
    g_tab_text_x_start[idx] = state.text_x_start;
    g_tab_text_x_end[idx] = state.text_x_end;
    g_tab_text_y_start[idx] = state.text_y_start;
    g_tab_text_y_end[idx] = state.text_y_end;
}

/// Move a tab from one index to another.
/// Keeps g_active_tab attached to the same logical tab after the move.
pub fn reorderTab(from_idx: usize, to_idx: usize) bool {
    if (g_tab_count <= 1) return false;
    if (from_idx >= g_tab_count or to_idx >= g_tab_count) return false;
    if (from_idx == to_idx) return false;

    const moved_tab = g_tabs[from_idx] orelse return false;
    const moved_visual = visualStateAt(from_idx);

    if (from_idx < to_idx) {
        var idx = from_idx;
        while (idx < to_idx) : (idx += 1) {
            g_tabs[idx] = g_tabs[idx + 1];
            setVisualStateAt(idx, visualStateAt(idx + 1));
        }
    } else {
        var idx = from_idx;
        while (idx > to_idx) : (idx -= 1) {
            g_tabs[idx] = g_tabs[idx - 1];
            setVisualStateAt(idx, visualStateAt(idx - 1));
        }
    }

    g_tabs[to_idx] = moved_tab;
    setVisualStateAt(to_idx, moved_visual);

    if (g_active_tab == from_idx) {
        g_active_tab = to_idx;
    } else if (from_idx < to_idx and g_active_tab > from_idx and g_active_tab <= to_idx) {
        g_active_tab -= 1;
    } else if (from_idx > to_idx and g_active_tab >= to_idx and g_active_tab < from_idx) {
        g_active_tab += 1;
    }

    return true;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`

Expected: PASS for all new `tab: reorder ...` tests.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/tab.zig
git commit -m "feat: add tab reorder model"
```

## Task 2: AppWindow Reorder Wrapper

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Add the wrapper**

Add this function after `switchTab` in `src/AppWindow.zig`:

```zig
pub fn reorderTab(from_idx: usize, to_idx: usize) bool {
    if (!tab.reorderTab(from_idx, to_idx)) return false;
    clearUiStateOnTabChange();
    return true;
}
```

- [ ] **Step 2: Run build tests**

Run: `zig build test`

Expected: PASS. The wrapper is not used yet, but it should compile cleanly.

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat: expose tab reorder wrapper"
```

## Task 3: Sidebar Drag State and Mouse Wiring

**Files:**
- Modify: `src/input.zig`

- [ ] **Step 1: Add drag state**

Near the existing mouse state variables in `src/input.zig`, add:

```zig
const SIDEBAR_TAB_DRAG_THRESHOLD_PX: f64 = 6.0;

threadlocal var g_sidebar_tab_drag_pressed: ?usize = null;
threadlocal var g_sidebar_tab_drag_current: ?usize = null;
threadlocal var g_sidebar_tab_drag_start_x: f64 = 0;
threadlocal var g_sidebar_tab_drag_start_y: f64 = 0;
threadlocal var g_sidebar_tab_drag_active: bool = false;
```

- [ ] **Step 2: Add drag helpers**

Place these helpers near `hitTestSidebarTab` in `src/input.zig`:

```zig
fn resetSidebarTabDragState() void {
    g_sidebar_tab_drag_pressed = null;
    g_sidebar_tab_drag_current = null;
    g_sidebar_tab_drag_start_x = 0;
    g_sidebar_tab_drag_start_y = 0;
    g_sidebar_tab_drag_active = false;
}

fn beginSidebarTabPotentialDrag(tab_idx: usize, xpos: f64, ypos: f64) void {
    if (tab.g_tab_count <= 1) return;
    g_sidebar_tab_drag_pressed = tab_idx;
    g_sidebar_tab_drag_current = tab_idx;
    g_sidebar_tab_drag_start_x = xpos;
    g_sidebar_tab_drag_start_y = ypos;
    g_sidebar_tab_drag_active = false;
}

fn sidebarTabIndexForDragY(ypos: f64) ?usize {
    if (!tab.g_sidebar_visible or tab.g_tab_count == 0) return null;

    const list_top = titlebarHeight() + @as(f64, @floatCast(titlebar.sidebarHeaderHeight())) + 6;
    const row_h = @as(f64, @floatCast(titlebar.sidebarRowHeight()));
    if (ypos < list_top) return 0;

    const idx_f = (ypos - list_top) / row_h;
    const idx_raw: usize = @intFromFloat(@floor(idx_f));
    if (idx_raw >= tab.g_tab_count) return tab.g_tab_count - 1;
    return idx_raw;
}

fn updateSidebarTabDrag(xpos: f64, ypos: f64) bool {
    const current = g_sidebar_tab_drag_current orelse return false;
    if (!tab.g_sidebar_visible or tab.g_tab_count <= 1 or current >= tab.g_tab_count) {
        resetSidebarTabDragState();
        return false;
    }

    if (!g_sidebar_tab_drag_active) {
        const dx = xpos - g_sidebar_tab_drag_start_x;
        const dy = ypos - g_sidebar_tab_drag_start_y;
        const distance = @sqrt(dx * dx + dy * dy);
        if (distance < SIDEBAR_TAB_DRAG_THRESHOLD_PX) return true;
        g_sidebar_tab_drag_active = true;
        g_selecting = false;
    }

    const target = sidebarTabIndexForDragY(ypos) orelse return true;
    if (target != current and AppWindow.reorderTab(current, target)) {
        g_sidebar_tab_drag_current = target;
    }

    return true;
}

fn finishSidebarTabDrag() bool {
    const consumed = g_sidebar_tab_drag_pressed != null or g_sidebar_tab_drag_active;
    resetSidebarTabDragState();
    return consumed;
}
```

- [ ] **Step 3: Reset drag state during transient cancellation**

In `cancelTransientMouseState`, add this line after `tab.g_tab_close_pressed = null;`:

```zig
    resetSidebarTabDragState();
```

- [ ] **Step 4: Start pending drag on sidebar tab press**

Change the tab-row branch in `handleSidebarPress` from:

```zig
    if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
        if (tab.g_tab_count > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1 and hitTestSidebarTabCloseButton(xpos, ypos, tab_idx)) {
            tab.g_tab_close_pressed = tab_idx;
            return;
        }
        AppWindow.switchTab(tab_idx);
    }
```

to:

```zig
    if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
        if (tab.g_tab_count > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1 and hitTestSidebarTabCloseButton(xpos, ypos, tab_idx)) {
            resetSidebarTabDragState();
            tab.g_tab_close_pressed = tab_idx;
            return;
        }
        beginSidebarTabPotentialDrag(tab_idx, xpos, ypos);
        AppWindow.switchTab(tab_idx);
    }
```

- [ ] **Step 5: Update drag during mouse movement**

In `handleMouseMove`, after the existing early returns for sidebar/file explorer/markdown/browser resize dragging and AI input scrollbar dragging, add:

```zig
    if (updateSidebarTabDrag(xpos, ypos)) return;
```

The new call must appear before divider dragging and hover handling so an active tab drag consumes movement until mouse release.

- [ ] **Step 6: Finish drag on mouse release**

In the left-button mouse-up branch of `handleMouseButton`, after the divider-dragging release block and before close-button release handling, add:

```zig
            if (finishSidebarTabDrag()) {
                return;
            }
```

- [ ] **Step 7: Run tests and build**

Run: `zig build test`

Expected: PASS.

Run: `zig build`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/input.zig
git commit -m "feat: drag reorder sidebar tabs"
```

## Task 4: Final Verification

**Files:**
- Verify only

- [ ] **Step 1: Run unit tests**

Run: `zig build test`

Expected: PASS. The known config/session tests may print warning lines such as invalid config values or corrupt session fixture warnings.

- [ ] **Step 2: Run development build**

Run: `zig build`

Expected: PASS.

- [ ] **Step 3: Check Windows path compatibility**

Run:

```bash
git ls-files -z | perl -0ne '
chomp;
$path=$_;
$tracked++;
@parts=split(/\//,$path);
for $part (@parts){
  $stem=uc((split(/\./,$part))[0]);
  @reasons=();
  push @reasons,"illegal_char" if $part =~ /[<>:"\\|?*]/;
  push @reasons,"trailing_space_or_dot" if $part =~ /[ .]$/;
  push @reasons,"reserved_name" if $stem =~ /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/;
  if(@reasons){ $violations++; print "violation\t$path\t$part\t".join(",",@reasons)."\n"; }
}
$key=lc($path);
if(exists $seen{$key} && $seen{$key} ne $path){ $collisions++; print "collision\t$seen{$key}\t$path\n"; } else { $seen{$key}=$path; }
if(length($path)>$max_len){ $max_len=length($path); $max_path=$path; }
END { print "tracked_files=$tracked\nwindows_name_violations=".($violations||0)."\ncasefold_collisions=".($collisions||0)."\nmax_path_length=$max_len $max_path\n"; }
'
```

Expected:

```text
windows_name_violations=0
casefold_collisions=0
```

- [ ] **Step 4: Check tracked symlinks**

Run: `git ls-files -s | rg '^120000'`

Expected: no output.

- [ ] **Step 5: Confirm status**

Run: `git status --short --branch`

Expected: implementation branch is clean after the task commits.
