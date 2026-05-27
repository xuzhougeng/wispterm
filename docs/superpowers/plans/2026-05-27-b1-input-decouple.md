# B1 — Decouple `input.zig` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the pure decision logic out of `src/input.zig` (click counting, sidebar hit-test geometry, keybind→command dispatch) into three std-only, unit-tested sibling modules under `src/input/`, leaving `input.zig` as the thin platform-event + global-state + side-effect shell.

**Architecture:** Targeted pure-module extraction matching the established repo pattern (`keybind.zig`, `selection_unit.zig`, `titlebar_layout.zig`, …). Each new module is std-only with its own `test` blocks and is regression-locked by `_ = @import(...)` in `src/test_main.zig`. `input.zig` keeps its 31 globals and event pump; it gathers globals into plain descriptor structs and delegates the decisions to the pure modules. No struct-ification of globals.

**Tech Stack:** Zig (Zig build system; `zig build test` is the native test loop here).

**Spec:** `docs/superpowers/specs/2026-05-27-b1-input-decouple-design.md`

---

## File structure

| File | Responsibility |
|------|----------------|
| `src/input/click_tracker.zig` (NEW) | Pure `ClickTracker` state machine: multi-click counting from (x, y, time, distance, interval). |
| `src/input/hit_test.zig` (NEW) | Pure sidebar geometry: tab-at, drag-index, plus-button, close-button, resize-handle, over an explicit `SidebarLayout`. |
| `src/input/command_dispatch.zig` (NEW) | Pure `resolve(action, phase) → ?Command`: maps a `keybind.Action` + phase to a command intent. |
| `src/input.zig` (MODIFY) | Delegates `nextLeftClickCount`/`resetLeftClickCount`, the `hitTestSidebar*` family, and `handleConfiguredKeybindAction` to the new modules; adds `executeCommand`. |
| `src/test_main.zig` (MODIFY) | Adds the three `_ = @import(...)` lines to the comptime regression-lock block. |

**Scope note (deviation from spec, intentional):** the spec mentioned scrollbar-target and panel resize-handle geometry. `scrollbarTargetAt` reads `split_layout` globals and delegates the real hit math to `overlays.scrollbarHitTestForSurface`, so it is **not** cleanly pure and is excluded from B1. The non-sidebar panel resize handles follow the identical `SidebarLayout`-style pattern and are deferred to keep B1 focused. B1 extracts the genuinely-pure **sidebar geometry family** (highest value — it backs tab drag/reorder and close hit-testing).

---

## Task 1: `click_tracker.zig` — pure multi-click counter

**Files:**
- Create: `src/input/click_tracker.zig`
- Modify: `src/input.zig` (remove the 4 `g_left_click_*` globals; rewrite `nextLeftClickCount` + `resetLeftClickCount` to delegate)
- Modify: `src/test_main.zig` (regression-lock import)

This reproduces `input.zig:nextLeftClickCount` exactly. Current source for reference:

```zig
// src/input.zig (current)
threadlocal var g_left_click_count: u8 = 0;
threadlocal var g_left_click_time_ms: i64 = 0;
threadlocal var g_left_click_x: f64 = 0;
threadlocal var g_left_click_y: f64 = 0;
const MULTI_CLICK_INTERVAL_MS: i64 = 500;

fn nextLeftClickCount(xpos: f64, ypos: f64) u8 {
    const now = std.time.milliTimestamp();
    const max_distance: f64 = @floatCast(@max(font.cell_width, font.cell_height));
    const dx = xpos - g_left_click_x;
    const dy = ypos - g_left_click_y;
    const distance = @sqrt(dx * dx + dy * dy);
    const within_interval = g_left_click_count > 0 and now - g_left_click_time_ms <= MULTI_CLICK_INTERVAL_MS;
    const within_distance = g_left_click_count > 0 and distance <= max_distance;
    if (!within_interval or !within_distance) g_left_click_count = 0;
    g_left_click_count += 1;
    if (g_left_click_count > 4) g_left_click_count = 1;
    g_left_click_time_ms = now;
    g_left_click_x = xpos;
    g_left_click_y = ypos;
    return g_left_click_count;
}

fn resetLeftClickCount() void {
    g_left_click_count = 0;
    g_left_click_time_ms = 0;
    g_left_click_x = 0;
    g_left_click_y = 0;
}
```

- [ ] **Step 1: Create `src/input/click_tracker.zig` with the type and its tests**

```zig
//! Pure multi-click (double/triple/quad) counting state machine.
//! Extracted from input.zig's nextLeftClickCount so the logic is std-only and
//! unit-testable. input.zig owns one instance and supplies time/distance.
const std = @import("std");

pub const ClickTracker = struct {
    count: u8 = 0,
    time_ms: i64 = 0,
    x: f64 = 0,
    y: f64 = 0,

    /// Register a click at (x, y) occurring at now_ms. A click continues the
    /// streak only if it is within interval_ms of the previous click AND within
    /// max_distance pixels of it; otherwise the streak resets. The count cycles
    /// 1→2→3→4→1. Returns the new count.
    pub fn register(self: *ClickTracker, x: f64, y: f64, now_ms: i64, max_distance: f64, interval_ms: i64) u8 {
        const dx = x - self.x;
        const dy = y - self.y;
        const distance = @sqrt(dx * dx + dy * dy);
        const within_interval = self.count > 0 and now_ms - self.time_ms <= interval_ms;
        const within_distance = self.count > 0 and distance <= max_distance;
        if (!within_interval or !within_distance) self.count = 0;
        self.count += 1;
        if (self.count > 4) self.count = 1;
        self.time_ms = now_ms;
        self.x = x;
        self.y = y;
        return self.count;
    }

    pub fn reset(self: *ClickTracker) void {
        self.* = .{};
    }
};

const max_dist: f64 = 10;
const interval: i64 = 500;

test "first click returns 1" {
    var t: ClickTracker = .{};
    try std.testing.expectEqual(@as(u8, 1), t.register(100, 100, 1000, max_dist, interval));
}

test "fast, near clicks increment to 2, 3, 4" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 2), t.register(101, 101, 1100, max_dist, interval));
    try std.testing.expectEqual(@as(u8, 3), t.register(102, 102, 1200, max_dist, interval));
    try std.testing.expectEqual(@as(u8, 4), t.register(103, 103, 1300, max_dist, interval));
}

test "fifth fast, near click wraps to 1" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    _ = t.register(100, 100, 1100, max_dist, interval);
    _ = t.register(100, 100, 1200, max_dist, interval);
    _ = t.register(100, 100, 1300, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 1), t.register(100, 100, 1400, max_dist, interval));
}

test "click beyond interval resets to 1" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 1), t.register(100, 100, 1000 + interval + 1, max_dist, interval));
}

test "click beyond distance resets to 1" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    try std.testing.expectEqual(@as(u8, 1), t.register(100 + max_dist + 1, 100, 1050, max_dist, interval));
}

test "reset clears the streak" {
    var t: ClickTracker = .{};
    _ = t.register(100, 100, 1000, max_dist, interval);
    _ = t.register(100, 100, 1100, max_dist, interval);
    t.reset();
    try std.testing.expectEqual(@as(u8, 1), t.register(100, 100, 1200, max_dist, interval));
}
```

- [ ] **Step 2: Run the module tests, expect PASS**

Run: `zig test src/input/click_tracker.zig`
Expected: all tests pass (`All N tests passed.`).

- [ ] **Step 3: Add the import to the input.zig import block**

In `src/input.zig`, next to the other `input/` imports (near `const input_shortcuts = @import("input_shortcuts.zig");`), add:

```zig
const click_tracker = @import("input/click_tracker.zig");
```

- [ ] **Step 4: Replace the click globals + delegate in input.zig**

Delete these four lines:

```zig
threadlocal var g_left_click_count: u8 = 0;
threadlocal var g_left_click_time_ms: i64 = 0;
threadlocal var g_left_click_x: f64 = 0;
threadlocal var g_left_click_y: f64 = 0;
```

Replace with:

```zig
threadlocal var g_left_click_tracker: click_tracker.ClickTracker = .{};
```

Rewrite `nextLeftClickCount` to:

```zig
fn nextLeftClickCount(xpos: f64, ypos: f64) u8 {
    const now = std.time.milliTimestamp();
    const max_distance: f64 = @floatCast(@max(font.cell_width, font.cell_height));
    return g_left_click_tracker.register(xpos, ypos, now, max_distance, MULTI_CLICK_INTERVAL_MS);
}
```

Rewrite `resetLeftClickCount` to:

```zig
fn resetLeftClickCount() void {
    g_left_click_tracker.reset();
}
```

(Keep `const MULTI_CLICK_INTERVAL_MS: i64 = 500;` — it is now passed as the `interval_ms` argument.)

- [ ] **Step 5: Add the regression-lock import to test_main.zig**

In `src/test_main.zig`, inside the `comptime { ... }` block (alongside `_ = @import("input/clipboard.zig");`), add:

```zig
    _ = @import("input/click_tracker.zig");
```

- [ ] **Step 6: Build the full native test suite, expect PASS**

Run: `zig build test`
Expected: exit 0. (Config `(warn)` lines about `maybe` values are expected test fixtures, not failures.)

- [ ] **Step 7: Commit**

```bash
git add src/input/click_tracker.zig src/input.zig src/test_main.zig
git commit -m "refactor(b1): extract pure ClickTracker from input.zig

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `hit_test.zig` — pure sidebar geometry

**Files:**
- Create: `src/input/hit_test.zig`
- Modify: `src/input.zig` (rewrite `hitTestSidebarTab`, `sidebarTabIndexForDragY`, `hitTestSidebarPlusButton`, `hitTestSidebarTabCloseButton`, `hitTestSidebarResizeHandle` to delegate; add a `sidebarLayout()` gatherer)
- Modify: `src/test_main.zig` (regression-lock import)

Current source for reference (`src/input.zig`), with the globals each reads:

```zig
fn hitTestSidebarTab(xpos: f64, ypos: f64) ?usize {
    if (!tab.g_sidebar_visible) return null;
    if (xpos < 0 or xpos >= @as(f64, @floatCast(titlebar.sidebarWidth()))) return null;
    const list_top = titlebarHeight() + @as(f64, @floatCast(titlebar.sidebarHeaderHeight())) + 6;
    if (ypos < list_top) return null;
    const idx_f = (ypos - list_top) / @as(f64, @floatCast(titlebar.sidebarRowHeight()));
    const idx: usize = @intFromFloat(@floor(idx_f));
    if (idx >= tab.g_tab_count) return null;
    return idx;
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

fn hitTestSidebarPlusButton(xpos: f64, ypos: f64) bool {
    if (!tab.g_sidebar_visible) return false;
    const top = titlebarHeight();
    const plus_w: f64 = 42;
    const plus_x = @as(f64, @floatCast(titlebar.sidebarWidth())) - plus_w - 6;
    return xpos >= plus_x and xpos < plus_x + plus_w and
        ypos >= top and ypos < top + @as(f64, @floatCast(titlebar.sidebarHeaderHeight()));
}

fn hitTestSidebarTabCloseButton(xpos: f64, ypos: f64, tab_idx: usize) bool {
    if (!tab.g_sidebar_visible or tab_idx >= tab.g_tab_count or tab.g_tab_count <= 1) return false;
    const row = hitTestSidebarTab(xpos, ypos) orelse return false;
    if (row != tab_idx) return false;
    const close_x = @as(f64, @floatCast(titlebar.sidebarWidth() - tab.TAB_CLOSE_BTN_W - 4));
    return xpos >= close_x and xpos < close_x + @as(f64, tab.TAB_CLOSE_BTN_W);
}

fn hitTestSidebarResizeHandle(xpos: f64, ypos: f64) bool {
    if (!tab.g_sidebar_visible) return false;
    if (ypos < titlebarHeight()) return false;
    const sidebar_w: f64 = @floatCast(titlebar.sidebarWidth());
    const half_hit: f64 = @as(f64, @floatCast(titlebar.SIDEBAR_RESIZE_HIT_WIDTH)) / 2;
    return xpos >= sidebar_w - half_hit and xpos <= sidebar_w + half_hit;
}
```

Constants: `titlebar.sidebarWidth/RowHeight/HeaderHeight()` and `SIDEBAR_RESIZE_HIT_WIDTH` are `f32`; `tab.TAB_CLOSE_BTN_W` is `f32 = 36`; the `+6`, `42`, `-6`, `-4` are literal layout offsets.

- [ ] **Step 1: Create `src/input/hit_test.zig` with the descriptor, functions, and tests**

```zig
//! Pure sidebar hit-test geometry, extracted from input.zig. Callers gather the
//! current layout into a SidebarLayout and ask which region a point hits. No
//! globals here — the math is std-only and unit-testable.
const std = @import("std");

pub const SidebarLayout = struct {
    visible: bool,
    titlebar_h: f64,
    width: f64, // titlebar.sidebarWidth()
    header_h: f64, // titlebar.sidebarHeaderHeight()
    row_h: f64, // titlebar.sidebarRowHeight()
    tab_count: usize,
    resize_hit_width: f64, // titlebar.SIDEBAR_RESIZE_HIT_WIDTH
    close_btn_w: f64, // tab.TAB_CLOSE_BTN_W
};

fn listTop(l: SidebarLayout) f64 {
    return l.titlebar_h + l.header_h + 6;
}

/// Which tab row a point falls on, or null if outside the tab list.
pub fn sidebarTabAt(l: SidebarLayout, x: f64, y: f64) ?usize {
    if (!l.visible) return null;
    if (x < 0 or x >= l.width) return null;
    const top = listTop(l);
    if (y < top) return null;
    const idx_f = (y - top) / l.row_h;
    const idx: usize = @intFromFloat(@floor(idx_f));
    if (idx >= l.tab_count) return null;
    return idx;
}

/// Drag-target row for a given y: clamps to [0, tab_count-1] instead of
/// returning null, so a drag above/below the list snaps to the ends.
pub fn sidebarTabIndexForDragY(l: SidebarLayout, y: f64) ?usize {
    if (!l.visible or l.tab_count == 0) return null;
    const top = listTop(l);
    if (y < top) return 0;
    const idx_f = (y - top) / l.row_h;
    const idx_raw: usize = @intFromFloat(@floor(idx_f));
    if (idx_raw >= l.tab_count) return l.tab_count - 1;
    return idx_raw;
}

pub fn sidebarPlusButton(l: SidebarLayout, x: f64, y: f64) bool {
    if (!l.visible) return false;
    const plus_w: f64 = 42;
    const plus_x = l.width - plus_w - 6;
    return x >= plus_x and x < plus_x + plus_w and
        y >= l.titlebar_h and y < l.titlebar_h + l.header_h;
}

pub fn sidebarTabCloseButton(l: SidebarLayout, x: f64, y: f64, tab_idx: usize) bool {
    if (!l.visible or tab_idx >= l.tab_count or l.tab_count <= 1) return false;
    const row = sidebarTabAt(l, x, y) orelse return false;
    if (row != tab_idx) return false;
    const close_x = l.width - l.close_btn_w - 4;
    return x >= close_x and x < close_x + l.close_btn_w;
}

pub fn sidebarResizeHandle(l: SidebarLayout, x: f64, y: f64) bool {
    if (!l.visible) return false;
    if (y < l.titlebar_h) return false;
    const half_hit = l.resize_hit_width / 2;
    return x >= l.width - half_hit and x <= l.width + half_hit;
}

const sample: SidebarLayout = .{
    .visible = true,
    .titlebar_h = 30,
    .width = 200,
    .header_h = 40,
    .row_h = 28,
    .tab_count = 3,
    .resize_hit_width = 8,
    .close_btn_w = 36,
};

test "sidebarTabAt: invisible sidebar never hits" {
    var l = sample;
    l.visible = false;
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(l, 10, 100));
}

test "sidebarTabAt: row math and bounds" {
    // list_top = 30 + 40 + 6 = 76; row_h = 28
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(sample, 10, 75)); // above list
    try std.testing.expectEqual(@as(?usize, 0), sidebarTabAt(sample, 10, 76)); // first row top
    try std.testing.expectEqual(@as(?usize, 0), sidebarTabAt(sample, 10, 103)); // still row 0
    try std.testing.expectEqual(@as(?usize, 1), sidebarTabAt(sample, 10, 104)); // row 1
    try std.testing.expectEqual(@as(?usize, 2), sidebarTabAt(sample, 10, 132)); // row 2 (last)
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(sample, 10, 160)); // past tab_count
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(sample, 200, 100)); // x == width (outside)
    try std.testing.expectEqual(@as(?usize, null), sidebarTabAt(sample, -1, 100)); // x < 0
}

test "sidebarTabIndexForDragY: clamps to ends" {
    try std.testing.expectEqual(@as(?usize, 0), sidebarTabIndexForDragY(sample, 0)); // above -> 0
    try std.testing.expectEqual(@as(?usize, 2), sidebarTabIndexForDragY(sample, 9999)); // below -> last
    try std.testing.expectEqual(@as(?usize, 1), sidebarTabIndexForDragY(sample, 104));
    var empty = sample;
    empty.tab_count = 0;
    try std.testing.expectEqual(@as(?usize, null), sidebarTabIndexForDragY(empty, 100));
}

test "sidebarPlusButton: top-right header box" {
    // plus_x = 200 - 42 - 6 = 152; spans x in [152, 194); y in [30, 70)
    try std.testing.expect(sidebarPlusButton(sample, 160, 50));
    try std.testing.expect(!sidebarPlusButton(sample, 151, 50)); // left of box
    try std.testing.expect(!sidebarPlusButton(sample, 160, 70)); // y == header bottom (outside)
}

test "sidebarTabCloseButton: only on its own hovered row, needs >1 tab" {
    // close_x = 200 - 36 - 4 = 160; spans [160, 196); row 0 spans y in [76, 104)
    try std.testing.expect(sidebarTabCloseButton(sample, 170, 80, 0));
    try std.testing.expect(!sidebarTabCloseButton(sample, 100, 80, 0)); // left of close box
    try std.testing.expect(!sidebarTabCloseButton(sample, 170, 80, 1)); // hovering row 0, asking row 1
    var one = sample;
    one.tab_count = 1;
    try std.testing.expect(!sidebarTabCloseButton(one, 170, 80, 0)); // single tab: no close
}

test "sidebarResizeHandle: band around the right edge" {
    // half_hit = 4; band x in [196, 204]; needs y >= titlebar_h (30)
    try std.testing.expect(sidebarResizeHandle(sample, 200, 100));
    try std.testing.expect(sidebarResizeHandle(sample, 196, 100));
    try std.testing.expect(sidebarResizeHandle(sample, 204, 100));
    try std.testing.expect(!sidebarResizeHandle(sample, 195, 100)); // left of band
    try std.testing.expect(!sidebarResizeHandle(sample, 200, 20)); // above titlebar
}
```

- [ ] **Step 2: Run the module tests, expect PASS**

Run: `zig test src/input/hit_test.zig`
Expected: all tests pass.

- [ ] **Step 3: Add the import to input.zig**

In `src/input.zig`, near the other `input/` imports, add:

```zig
const hit_test = @import("input/hit_test.zig");
```

- [ ] **Step 4: Add the layout gatherer and rewrite the five functions to delegate**

Add a private gatherer (place it just above `hitTestSidebarTab`):

```zig
fn sidebarLayout() hit_test.SidebarLayout {
    return .{
        .visible = tab.g_sidebar_visible,
        .titlebar_h = titlebarHeight(),
        .width = @floatCast(titlebar.sidebarWidth()),
        .header_h = @floatCast(titlebar.sidebarHeaderHeight()),
        .row_h = @floatCast(titlebar.sidebarRowHeight()),
        .tab_count = tab.g_tab_count,
        .resize_hit_width = @floatCast(titlebar.SIDEBAR_RESIZE_HIT_WIDTH),
        .close_btn_w = @floatCast(tab.TAB_CLOSE_BTN_W),
    };
}
```

Replace the five function bodies with delegations (keep their existing signatures so all call sites are untouched):

```zig
fn hitTestSidebarTab(xpos: f64, ypos: f64) ?usize {
    return hit_test.sidebarTabAt(sidebarLayout(), xpos, ypos);
}

fn sidebarTabIndexForDragY(ypos: f64) ?usize {
    return hit_test.sidebarTabIndexForDragY(sidebarLayout(), ypos);
}

fn hitTestSidebarPlusButton(xpos: f64, ypos: f64) bool {
    return hit_test.sidebarPlusButton(sidebarLayout(), xpos, ypos);
}

fn hitTestSidebarTabCloseButton(xpos: f64, ypos: f64, tab_idx: usize) bool {
    return hit_test.sidebarTabCloseButton(sidebarLayout(), xpos, ypos, tab_idx);
}

fn hitTestSidebarResizeHandle(xpos: f64, ypos: f64) bool {
    return hit_test.sidebarResizeHandle(sidebarLayout(), xpos, ypos);
}
```

- [ ] **Step 5: Add the regression-lock import to test_main.zig**

In `src/test_main.zig`, inside the `comptime { ... }` block (alongside `_ = @import("input/click_tracker.zig");`), add:

```zig
    _ = @import("input/hit_test.zig");
```

- [ ] **Step 6: Build the full native test suite, expect PASS**

Run: `zig build test`
Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add src/input/hit_test.zig src/input.zig src/test_main.zig
git commit -m "refactor(b1): extract pure sidebar hit-test geometry from input.zig

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `command_dispatch.zig` — pure keybind→command resolution

**Files:**
- Create: `src/input/command_dispatch.zig`
- Modify: `src/input.zig` (alias `KeybindPhase`; rewrite `handleConfiguredKeybindAction` to `resolve` + new `executeCommand`; remove `switchTabActionIndex`)
- Modify: `src/test_main.zig` (regression-lock import)

Current dispatch for reference — `src/input.zig:handleConfiguredKeybindAction` (lines ~927–1040) plus `switchTabActionIndex` (~912–925) and `const KeybindPhase = enum { early, late };` (~818). The behavior to preserve exactly:
- **Early** (each first calls `commitTabRenameIfActive()`, then a side effect, returns `true`): `toggle_quake`, `toggle_command_palette`, `new_window`, `new_session`, `split_right`, `toggle_file_explorer`, `toggle_sidebar`, `close_panel_or_tab`, `toggle_maximize`, `font_size_increase`(+1), `font_size_decrease`(−1). All other actions → `false`.
- **Late**: `copy`, `paste`, `paste_image` (return `true`); `focus_left/right/up/down/previous/next` (return the bool from `AppWindow.gotoSplit` — "performable", may not consume); `equalize_splits`, `next_tab`, `previous_tab`, `open_config` (return `true`); `switch_tab_1..9` → switch to index 0..8 (`if (idx < tab.g_tab_count) AppWindow.switchTab(idx); return true;`). All other actions → `false`.

Note: every early arm calls `commitTabRenameIfActive()` and no late arm does, so hoisting that single call to "before executing an early command" is behavior-identical.

- [ ] **Step 1: Create `src/input/command_dispatch.zig` with the types, resolver, and tests**

```zig
//! Pure keybind-action → command-intent resolution, extracted from input.zig's
//! handleConfiguredKeybindAction. `resolve` answers "what command does this
//! action trigger in this phase?" with no side effects; input.zig's
//! executeCommand performs the effect (and decides consumption for the
//! performable focus/switch commands, which depends on runtime state).
const std = @import("std");
const keybind = @import("../keybind.zig");

pub const Phase = enum { early, late };

pub const FocusTarget = enum { left, right, up, down, previous, next };

pub const Command = union(enum) {
    // Early commands (input.zig commits any active tab rename before executing).
    toggle_quake,
    toggle_command_palette,
    new_window,
    new_session,
    split_right,
    toggle_file_explorer,
    toggle_sidebar,
    close_panel_or_tab,
    toggle_maximize,
    font_size: i32,
    // Late commands.
    copy,
    paste,
    paste_image,
    focus_split: FocusTarget,
    equalize_splits,
    next_tab,
    previous_tab,
    open_config,
    switch_tab: usize,
};

/// Map a configured action + phase to the command it triggers, or null if the
/// action is not handled in that phase. Pure: no globals, no side effects.
pub fn resolve(action: keybind.Action, phase: Phase) ?Command {
    return switch (phase) {
        .early => switch (action) {
            .toggle_quake => .toggle_quake,
            .toggle_command_palette => .toggle_command_palette,
            .new_window => .new_window,
            .new_session => .new_session,
            .split_right => .split_right,
            .toggle_file_explorer => .toggle_file_explorer,
            .toggle_sidebar => .toggle_sidebar,
            .close_panel_or_tab => .close_panel_or_tab,
            .toggle_maximize => .toggle_maximize,
            .font_size_increase => .{ .font_size = 1 },
            .font_size_decrease => .{ .font_size = -1 },
            else => null,
        },
        .late => switch (action) {
            .copy => .copy,
            .paste => .paste,
            .paste_image => .paste_image,
            .focus_left => .{ .focus_split = .left },
            .focus_right => .{ .focus_split = .right },
            .focus_up => .{ .focus_split = .up },
            .focus_down => .{ .focus_split = .down },
            .focus_previous => .{ .focus_split = .previous },
            .focus_next => .{ .focus_split = .next },
            .equalize_splits => .equalize_splits,
            .next_tab => .next_tab,
            .previous_tab => .previous_tab,
            .open_config => .open_config,
            else => if (switchTabIndex(action)) |idx| .{ .switch_tab = idx } else null,
        },
    };
}

/// switch_tab_1..9 → 0-based index, else null. (Was switchTabActionIndex.)
fn switchTabIndex(action: keybind.Action) ?usize {
    return switch (action) {
        .switch_tab_1 => 0,
        .switch_tab_2 => 1,
        .switch_tab_3 => 2,
        .switch_tab_4 => 3,
        .switch_tab_5 => 4,
        .switch_tab_6 => 5,
        .switch_tab_7 => 6,
        .switch_tab_8 => 7,
        .switch_tab_9 => 8,
        else => null,
    };
}

test "early commands resolve only in the early phase" {
    try std.testing.expectEqual(Command.toggle_quake, resolve(.toggle_quake, .early).?);
    try std.testing.expectEqual(Command.split_right, resolve(.split_right, .early).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.toggle_quake, .late));
}

test "font size carries the delta" {
    try std.testing.expectEqual(Command{ .font_size = 1 }, resolve(.font_size_increase, .early).?);
    try std.testing.expectEqual(Command{ .font_size = -1 }, resolve(.font_size_decrease, .early).?);
}

test "late commands resolve only in the late phase" {
    try std.testing.expectEqual(Command.copy, resolve(.copy, .late).?);
    try std.testing.expectEqual(Command.open_config, resolve(.open_config, .late).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.copy, .early));
}

test "focus actions map to focus_split targets" {
    try std.testing.expectEqual(Command{ .focus_split = .left }, resolve(.focus_left, .late).?);
    try std.testing.expectEqual(Command{ .focus_split = .previous }, resolve(.focus_previous, .late).?);
    try std.testing.expectEqual(Command{ .focus_split = .next }, resolve(.focus_next, .late).?);
}

test "switch_tab_N maps to a zero-based index" {
    try std.testing.expectEqual(Command{ .switch_tab = 0 }, resolve(.switch_tab_1, .late).?);
    try std.testing.expectEqual(Command{ .switch_tab = 8 }, resolve(.switch_tab_9, .late).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.switch_tab_1, .early));
}
```

- [ ] **Step 2: Run the module tests, expect PASS**

Run: `zig test src/input/command_dispatch.zig`
Expected: all tests pass.

> If a build error reports a `.focus_*`, `.switch_tab_*`, or other action name that does not exist on `keybind.Action`, the action set drifted from this plan. Open `src/keybind.zig` (`pub const Action = enum { ... }`), reconcile the arm names in `resolve`/`switchTabIndex` with the real enum, and keep the early/late grouping identical to the current `handleConfiguredKeybindAction`.

- [ ] **Step 3: Add the import and alias the phase enum in input.zig**

In `src/input.zig`, near the other `input/` imports, add:

```zig
const command_dispatch = @import("input/command_dispatch.zig");
```

Replace `const KeybindPhase = enum { early, late };` with an alias so existing `.early`/`.late` call sites in `handleKey` keep working:

```zig
const KeybindPhase = command_dispatch.Phase;
```

- [ ] **Step 4: Rewrite the dispatch to resolve + executeCommand; delete switchTabActionIndex**

Delete `fn switchTabActionIndex(...)` (now `switchTabIndex` inside `command_dispatch.zig`).

Replace the whole body of `handleConfiguredKeybindAction` with:

```zig
fn handleConfiguredKeybindAction(action: keybind.Action, phase: KeybindPhase) bool {
    const cmd = command_dispatch.resolve(action, phase) orelse return false;
    if (phase == .early) commitTabRenameIfActive();
    return executeCommand(cmd);
}

fn executeCommand(cmd: command_dispatch.Command) bool {
    switch (cmd) {
        // Early
        .toggle_quake => AppWindow.toggleQuakeVisibility(),
        .toggle_command_palette => overlays.commandPaletteToggle(),
        .new_window => requestNewWindowFromActiveCwd(),
        .new_session => overlays.sessionLauncherOpen(),
        .split_right => AppWindow.splitFocused(.right),
        .toggle_file_explorer => toggleFileExplorer(),
        .toggle_sidebar => toggleSidebar(),
        .close_panel_or_tab => closePanelOrTab(),
        .toggle_maximize => toggleMaximize(),
        .font_size => |delta| adjustFontSize(delta),
        // Late
        .copy => copySelectionToClipboard(),
        .paste => {
            if (AppWindow.activeAiChat()) |chat| {
                pasteFromClipboardIntoAiChat(chat);
            } else {
                pasteFromClipboard();
            }
        },
        .paste_image => pasteImageFromClipboard(),
        .focus_split => |target| return switch (target) {
            .left => AppWindow.gotoSplit(.{ .spatial = .left }),
            .right => AppWindow.gotoSplit(.{ .spatial = .right }),
            .up => AppWindow.gotoSplit(.{ .spatial = .up }),
            .down => AppWindow.gotoSplit(.{ .spatial = .down }),
            .previous => AppWindow.gotoSplit(.previous_wrapped),
            .next => AppWindow.gotoSplit(.next_wrapped),
        },
        .equalize_splits => AppWindow.equalizeSplits(),
        .next_tab => AppWindow.switchTab((tab.g_active_tab + 1) % tab.g_tab_count),
        .previous_tab => {
            if (tab.g_active_tab > 0) AppWindow.switchTab(tab.g_active_tab - 1) else AppWindow.switchTab(tab.g_tab_count - 1);
        },
        .open_config => {
            std.debug.print("[keybind] open_config pressed\n", .{});
            if (AppWindow.g_allocator) |alloc| Config.openConfigInEditor(alloc);
        },
        .switch_tab => |idx| {
            if (idx < tab.g_tab_count) AppWindow.switchTab(idx);
        },
    }
    return true;
}
```

This preserves the original behavior exactly: early commands commit the tab rename first; `focus_split` returns `gotoSplit`'s bool (performable); `switch_tab` switches only if in range but always consumes; everything else returns `true`.

- [ ] **Step 5: Add the regression-lock import to test_main.zig**

In `src/test_main.zig`, inside the `comptime { ... }` block, add:

```zig
    _ = @import("input/command_dispatch.zig");
```

- [ ] **Step 6: Build the full native test suite, expect PASS**

Run: `zig build test`
Expected: exit 0. This also runs the two existing in-`input.zig` integration tests (`"input: Ctrl+Shift+P toggles command center"` and the macOS sidebar smoke test), which exercise this dispatch path end-to-end.

- [ ] **Step 7: Commit**

```bash
git add src/input/command_dispatch.zig src/input.zig src/test_main.zig
git commit -m "refactor(b1): extract pure keybind command dispatch from input.zig

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Cross-target verification

**Files:** none (verification only).

- [ ] **Step 1: Native suite**

Run: `zig build test`
Expected: exit 0.

- [ ] **Step 2: Windows cross-target full suite**

Run: `zig build test-full -Dtarget=x86_64-windows-gnu`
Expected: matches the recorded baseline — 497/499 (1 known Windows-API failure, 1 skip). No *new* failures.

- [ ] **Step 3: macOS cross-target full suite**

Run: `zig build test-full -Dtarget=aarch64-macos`
Expected: green (matches pre-B1 state).

- [ ] **Step 4: Confirm input.zig shrank and the globals are gone**

Run: `grep -nE "g_left_click_count|switchTabActionIndex" src/input.zig`
Expected: no matches (the four click globals and the old helper are fully removed).

- [ ] **Step 5 (if any cross-target regression):** Use superpowers:systematic-debugging before changing code. Do not paper over a new failure.

---

## Self-review notes

- **Spec coverage:** command_dispatch (B1 "command dispatch") → Task 3; hit_test (pure geometry) → Task 2; click_tracker → Task 1; B4 tests + `test_main.zig` lock → every task's Steps 1/5/6; verification matrix → Task 4. Scrollbar-target exclusion is documented above with rationale.
- **Type consistency:** `ClickTracker.register` signature, `SidebarLayout` field names, and `Command`/`FocusTarget`/`Phase` names are used identically in the module definitions and the input.zig delegations. `resolve(action, phase)` returns `?Command`; `executeCommand(Command) bool`.
- **Behavior preservation:** `executeCommand` is a literal move of the original arm bodies; the `commitTabRenameIfActive()` hoist is behavior-identical because it was in every early arm and no late arm.
