# Jupyter Panel Iteration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Open Jupyter auto-detect the running Jupyter URL from the focused terminal and open the browser panel full-screen (terminal hidden), with a full/side toggle button, a close ✕ (already wired), and a picker when multiple servers are detected.

**Architecture:** Builds on the existing `browser_panel` (PR #151 work). Full mode is purely a **webview-geometry change**: in full mode the panel's computed width covers the entire content area, so the native webview child (drawn on top) occludes the terminal; the terminal stays laid out behind it unchanged (no risky zero-width terminal path). Auto-detect is a pure scanner over the focused surface's terminal snapshot. The picker is a small overlay backed by a pure selection model.

**Tech Stack:** Zig 0.15.2. Pure logic unit-tested via the fast suite (`zig build test`); rendering/hit-testing GUI-verified (Windows now via WebView2, macOS later).

---

## Background facts (verified against the code)

- **Close ✕ already works:** `renderBrowserUrlBar` (`overlays.zig:1281`) draws the close icon via `hit_test.panelCloseButtonRect`; the click is wired at `input.zig:2961` (`if (hitTestBrowserCloseButton…) closeBrowserPanel()`). `closeBrowserPanel` → `browser_panel.close()` restores the terminal. **Do not re-implement close.**
- **Panel geometry:** `browser_panel.boundsForWindow` uses `panelWidthForWindow(window_width, left_offset, right_offset)` (`browser_panel.zig:110`), which clamps to leave `MIN_CONTENT_WIDTH=320` for the terminal. The webview is positioned from these bounds in `browser_panel.sync` (called from `AppWindow.zig:2357,5062`).
- **Header buttons:** `hit_test.zig` has `PanelHeaderLayout`, `panelCloseButtonRect`, `panelHeaderCloseButton`, consts `PANEL_HEADER_CLOSE_BTN_W=32`, `PANEL_HEADER_CLOSE_MARGIN=6`. `input.zig:1776 browserHeaderLayout()` builds the layout for the browser URL bar.
- **Focused-surface snapshot:** `AppWindow.zig:~3376 buildRemoteSurfaceSnapshot(allocator, surface)` locks `surface.render_state.mutex` and calls `remote_snapshot.allocTerminalSnapshot(allocator, &surface.terminal, remote_snapshot.default_max_history_rows)` (10000 rows). `AppWindow.activeSurface()` (`AppWindow.zig:814`) returns `?*Surface`.
- **Pure-module test registration:** add `_ = @import("file.zig");` inside the `test { … }` block in `src/test_fast.zig` (around line 22) so its tests run in the fast suite.
- **Open Jupyter entry:** `input.zig openJupyterPanel()` → `browser_panel.openJupyterForSurface()` (opens blank + focuses URL bar). This is what we extend.

## File Structure

- **Create** `src/jupyter_detect.zig` — pure: scan terminal text → deduped Jupyter URLs. One responsibility: detection.
- **Create** `src/jupyter_picker.zig` — pure model: hold detected URLs + selection index; show/hide/move/select. One responsibility: picker state.
- **Modify** `src/browser_panel.zig` — `DisplayMode` state + full-width math (`panelWidthForMode` pure helper) + reset on close.
- **Modify** `src/input/hit_test.zig` — `panelSecondButtonRect` / `panelHeaderSecondButton` for the toggle button (left of close).
- **Modify** `src/renderer/overlays.zig` — render the toggle glyph in the URL bar; render the picker overlay.
- **Modify** `src/input.zig` — toggle hit-test + wiring; picker key handling; rewrite `openJupyterPanel` flow (snapshot → detect → 0/1/2+).
- **Modify** `src/AppWindow.zig` — `pub fn activeSurfaceSnapshot(allocator) ?[]u8` wrapper around `buildRemoteSurfaceSnapshot`.
- **Modify** `src/test_fast.zig` — register the two new pure modules.

---

## Task 1: Jupyter URL detection (pure)

**Files:**
- Create: `src/jupyter_detect.zig`
- Modify: `src/test_fast.zig` (register it)

- [ ] **Step 1: Write the failing tests**

Create `src/jupyter_detect.zig` with the tests first (place at the bottom once the file exists; for TDD, write the file with the public signature stubbed to return an empty result, then the tests, observe fail, then implement). To keep it one file, write the full skeleton + tests now:

```zig
const std = @import("std");

/// Owned list of detected Jupyter URLs, most-recent first, deduped by token.
pub const Result = struct {
    urls: [][]u8,
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        for (self.urls) |u| allocator.free(u);
        allocator.free(self.urls);
    }
};

pub fn findJupyterUrls(allocator: std.mem.Allocator, text: []const u8) !Result {
    _ = text;
    return .{ .urls = try allocator.alloc([]u8, 0) };
}

test "single localhost url with token is detected" {
    const t = "Jupyter Server is running at:\n  http://localhost:8889/lab?token=abc123\n";
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.urls.len);
    try std.testing.expectEqualStrings("http://localhost:8889/lab?token=abc123", r.urls[0]);
}

test "localhost and 127.0.0.1 with same token dedupe to one (prefer localhost)" {
    const t =
        "  http://localhost:8889/lab?token=deadbeef\n" ++
        "  http://127.0.0.1:8889/lab?token=deadbeef\n";
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.urls.len);
    try std.testing.expectEqualStrings("http://localhost:8889/lab?token=deadbeef", r.urls[0]);
}

test "two different servers (different tokens) both detected, most-recent first" {
    const t =
        "  http://localhost:8888/lab?token=aaa\n" ++
        "  http://localhost:9999/lab?token=bbb\n";
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), r.urls.len);
    try std.testing.expectEqualStrings("http://localhost:9999/lab?token=bbb", r.urls[0]);
    try std.testing.expectEqualStrings("http://localhost:8888/lab?token=aaa", r.urls[1]);
}

test "no token, non-loopback, or no port are ignored" {
    const t =
        "http://localhost:8888/lab\n" ++           // no token
        "http://example.com:8888/lab?token=x\n" ++ // not loopback
        "http://localhost/lab?token=y\n";          // no port
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), r.urls.len);
}

test "https and trailing punctuation/whitespace handled" {
    const t = "see (https://127.0.0.1:8890/tree?token=zz9 ) now";
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.urls.len);
    try std.testing.expectEqualStrings("https://127.0.0.1:8890/tree?token=zz9", r.urls[0]);
}
```

Register it in `src/test_fast.zig` inside the `test { … }` block (next to the other `_ = @import(...)` lines):

```zig
    _ = @import("jupyter_detect.zig");
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL (the stub returns 0 urls; the single-url and dedupe tests fail).

- [ ] **Step 3: Implement `findJupyterUrls`**

Replace the stub body with:

```zig
const Match = struct { pos: usize, url: []const u8, host_localhost: bool, token: []const u8 };

fn isUrlByte(c: u8) bool {
    // Stop the URL at whitespace, quotes, brackets, and control chars.
    return switch (c) {
        ' ', '\t', '\r', '\n', '"', '\'', '<', '>', '`', '(', ')', '[', ']', '{', '}', 0...0x1f => false,
        else => true,
    };
}

fn matchAt(text: []const u8, i: usize) ?Match {
    const schemes = [_][]const u8{ "http://", "https://" };
    var scheme_len: usize = 0;
    for (schemes) |s| {
        if (std.mem.startsWith(u8, text[i..], s)) {
            scheme_len = s.len;
            break;
        }
    }
    if (scheme_len == 0) return null;

    // Extent of the URL.
    var end = i + scheme_len;
    while (end < text.len and isUrlByte(text[end])) end += 1;
    // Trim trailing punctuation that commonly abuts a URL.
    while (end > i + scheme_len and (text[end - 1] == '.' or text[end - 1] == ',' or text[end - 1] == ';')) end -= 1;
    const url = text[i..end];

    const after_scheme = url[scheme_len..];
    // Host ends at ':' or '/'.
    const host_end = std.mem.indexOfAny(u8, after_scheme, ":/") orelse return null;
    const host = after_scheme[0..host_end];
    const is_localhost = std.mem.eql(u8, host, "localhost");
    const is_loopback_ip = std.mem.eql(u8, host, "127.0.0.1");
    if (!is_localhost and !is_loopback_ip) return null;

    // Require ':' + at least one digit (a port) right after the host.
    if (host_end >= after_scheme.len or after_scheme[host_end] != ':') return null;
    if (host_end + 1 >= after_scheme.len or !std.ascii.isDigit(after_scheme[host_end + 1])) return null;

    // Require a token= query param with a non-empty value.
    const tk = std.mem.indexOf(u8, url, "token=") orelse return null;
    const tok_start = tk + "token=".len;
    var tok_end = tok_start;
    while (tok_end < url.len and url[tok_end] != '&') tok_end += 1;
    if (tok_end == tok_start) return null;

    return .{ .pos = i, .url = url, .host_localhost = is_localhost, .token = url[tok_start..tok_end] };
}

pub fn findJupyterUrls(allocator: std.mem.Allocator, text: []const u8) !Result {
    // Collect raw matches scanning forward.
    var matches: std.ArrayListUnmanaged(Match) = .empty;
    defer matches.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (matchAt(text, i)) |m| {
            try matches.append(allocator, m);
            i = m.pos + m.url.len; // skip past this URL
        }
    }

    // Dedupe by token. Track most-recent position per token + preferred (localhost) url.
    const Group = struct { token: []const u8, max_pos: usize, url: []const u8, is_localhost: bool };
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    defer groups.deinit(allocator);
    for (matches.items) |m| {
        var found = false;
        for (groups.items) |*g| {
            if (std.mem.eql(u8, g.token, m.token)) {
                found = true;
                if (m.pos > g.max_pos) g.max_pos = m.pos;
                if (m.host_localhost and !g.is_localhost) {
                    g.url = m.url;
                    g.is_localhost = true;
                }
                break;
            }
        }
        if (!found) try groups.append(allocator, .{ .token = m.token, .max_pos = m.pos, .url = m.url, .is_localhost = m.host_localhost });
    }

    // Sort groups by most-recent position, descending.
    std.mem.sort(Group, groups.items, {}, struct {
        fn lessThan(_: void, a: Group, b: Group) bool {
            return a.max_pos > b.max_pos;
        }
    }.lessThan);

    var urls = try allocator.alloc([]u8, groups.items.len);
    errdefer allocator.free(urls);
    var n: usize = 0;
    errdefer for (urls[0..n]) |u| allocator.free(u);
    for (groups.items) |g| {
        urls[n] = try allocator.dupe(u8, g.url);
        n += 1;
    }
    return .{ .urls = urls };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `zig build test`
Expected: PASS (all five `jupyter_detect` tests green; no regressions).

- [ ] **Step 5: Commit**

```bash
git add src/jupyter_detect.zig src/test_fast.zig
git commit -m "feat(jupyter): pure Jupyter-URL detector (token dedupe, localhost-preference)"
```
End the commit body with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## Task 2: Browser panel display mode (side ⇄ full)

**Files:**
- Modify: `src/browser_panel.zig`

- [ ] **Step 1: Write the failing test**

Add to `src/browser_panel.zig` (the file already has tests; add this near them):

```zig
test "panelWidthForMode: full covers the whole content area; side reserves min content" {
    // window 1600, no left/right offsets, stored side width 720.
    try std.testing.expectEqual(@as(f32, 1600), panelWidthForMode(.full, 720, 1600, 0, 0));
    // side mode keeps MIN_CONTENT_WIDTH (320) for the terminal → 720 (within clamp).
    try std.testing.expectEqual(@as(f32, 720), panelWidthForMode(.side, 720, 1600, 0, 0));
    // full mode respects left/right offsets.
    try std.testing.expectEqual(@as(f32, 1500), panelWidthForMode(.full, 720, 1600, 60, 40));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-full`
Expected: FAIL — `panelWidthForMode` and `DisplayMode` do not exist. (Note: `browser_panel.zig` tests run under `test-full`, not the fast suite — confirm the red state there.)

- [ ] **Step 3: Add `DisplayMode` + `panelWidthForMode` and route `panelWidthForWindow` through it**

Add near the top constants:

```zig
pub const DisplayMode = enum { side, full };
pub threadlocal var g_display_mode: DisplayMode = .side;

pub fn setDisplayMode(mode: DisplayMode) void {
    g_display_mode = mode;
}

pub fn displayMode() DisplayMode {
    return g_display_mode;
}

/// Pure width math. In `full`, the panel covers the entire content area (the
/// native webview occludes the terminal, which stays laid out behind it). In
/// `side`, it reserves MIN_CONTENT_WIDTH for the terminal and clamps to g_width.
pub fn panelWidthForMode(mode: DisplayMode, stored_width: f32, window_width: i32, left_offset: f32, right_offset: f32) f32 {
    const win_w: f32 = @floatFromInt(window_width);
    if (mode == .full) {
        return @max(MIN_WIDTH, win_w - left_offset - right_offset);
    }
    const max_width = @max(MIN_WIDTH, @min(MAX_WIDTH, win_w - left_offset - right_offset - MIN_CONTENT_WIDTH));
    return @max(MIN_WIDTH, @min(stored_width, max_width));
}
```

Replace the body of `panelWidthForWindow` (currently `browser_panel.zig:110`) to delegate:

```zig
pub fn panelWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    if (!isVisibleForActiveTab()) return 0;
    return panelWidthForMode(g_display_mode, g_width, window_width, left_offset, right_offset);
}
```

In `close()` (currently `browser_panel.zig:193`), reset the mode so the next side-open is not stuck full. Add as the first line of the body:

```zig
    g_display_mode = .side;
```

- [ ] **Step 4: Run to verify pass**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/browser_panel.zig
git commit -m "feat(browser-panel): side/full display mode + full-coverage width math"
```
End the commit body with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## Task 3: Full/side toggle button in the URL bar

**Files:**
- Modify: `src/input/hit_test.zig` (second header button rect + test)
- Modify: `src/renderer/overlays.zig` (render the toggle glyph)
- Modify: `src/input.zig` (hit-test + toggle action)

- [ ] **Step 1: Write the failing test (hit_test rect)**

Add to `src/input/hit_test.zig` near the panel-header tests:

```zig
test "panelSecondButtonRect: sits just left of the close button" {
    const close = panelCloseButtonRect(sample_panel).?;
    const second = panelSecondButtonRect(sample_panel).?;
    try std.testing.expectEqual(close.width, second.width);
    try std.testing.expectEqual(close.top, second.top);
    try std.testing.expect(second.left < close.left); // to the left of close
    try std.testing.expect(second.left + second.width <= close.left); // no overlap
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL — `panelSecondButtonRect` does not exist.

- [ ] **Step 3: Implement the rect helpers**

Add to `src/input/hit_test.zig` (after `panelCloseButtonRect`):

```zig
pub const PANEL_HEADER_BTN_GAP: f64 = 4;

pub fn panelSecondButtonRect(l: PanelHeaderLayout) ?Rect {
    const close = panelCloseButtonRect(l) orelse return null;
    const left = close.left - PANEL_HEADER_BTN_GAP - close.width;
    if (left <= l.left) return null;
    return .{ .left = left, .top = close.top, .width = close.width, .height = close.height };
}

pub fn panelHeaderSecondButton(l: PanelHeaderLayout, x: f64, y: f64) bool {
    const r = panelSecondButtonRect(l) orelse return false;
    return x >= r.left and x < r.left + r.width and y >= r.top and y < r.top + r.height;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Render the toggle glyph**

In `src/renderer/overlays.zig` `renderBrowserUrlBar`, after the close icon is drawn (after the `titlebar.renderCloseIcon(...)` line, before the final separator `fillQuadAlpha`), add a simple square glyph in the second-button rect. Insert:

```zig
    const toggle = hit_test.panelSecondButtonRect(close_layout);
    if (toggle) |t| {
        const t_left = @round(@as(f32, @floatCast(t.left)));
        const toggle_hovered = blk: {
            const win = AppWindow.g_window orelse break :blk false;
            if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
            break :blk hit_test.panelHeaderSecondButton(close_layout, @floatFromInt(win.mouse_x), @floatFromInt(win.mouse_y));
        };
        if (toggle_hovered) {
            ui_pipeline.fillQuadAlpha(t_left + 6, bar_y + @round((bar_h - 20) / 2), 20, 20, mixColor(bg, fg, 0.14), 0.95);
        }
        // Square-outline glyph: filled in `full` (restore-to-side), hollow in `side` (maximize).
        const glyph_color = if (toggle_hovered) fg else mixColor(bg, fg, 0.68);
        const gx = t_left + @as(f32, @floatCast(t.width)) / 2 - 6;
        const gy = bar_y + bar_h / 2 - 6;
        const filled = browser_panel.displayMode() == .full;
        if (filled) {
            ui_pipeline.fillQuadAlpha(gx, gy, 12, 12, glyph_color, 0.9);
        } else {
            // hollow square (four thin edges)
            ui_pipeline.fillQuadAlpha(gx, gy, 12, 1.5, glyph_color, 0.9);
            ui_pipeline.fillQuadAlpha(gx, gy + 10.5, 12, 1.5, glyph_color, 0.9);
            ui_pipeline.fillQuadAlpha(gx, gy, 1.5, 12, glyph_color, 0.9);
            ui_pipeline.fillQuadAlpha(gx + 10.5, gy, 1.5, 12, glyph_color, 0.9);
        }
    }
```

- [ ] **Step 6: Wire the toggle click + action in input.zig**

Add a hit-test helper next to `hitTestBrowserCloseButton` (`input.zig:1786`):

```zig
fn hitTestBrowserToggleButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderSecondButton(browserHeaderLayout() orelse return false, xpos, ypos);
}

fn toggleBrowserDisplayMode() void {
    browser_panel.setDisplayMode(if (browser_panel.displayMode() == .full) .side else .full);
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}
```

In the mouse-down handler, add the toggle check immediately **before** the existing close check at `input.zig:2961`:

```zig
            if (hitTestBrowserToggleButton(xpos, ypos)) {
                toggleBrowserDisplayMode();
                return;
            }
            if (hitTestBrowserCloseButton(xpos, ypos)) {
                closeBrowserPanel();
                return;
            }
```

- [ ] **Step 7: Verify build + suites**

Run: `zig build test` → PASS. Run: `zig build test-full` → PASS. Run: `zig build test-shared -Dtarget=aarch64-macos` → exit 0.

- [ ] **Step 8: Commit**

```bash
git add src/input/hit_test.zig src/renderer/overlays.zig src/input.zig
git commit -m "feat(browser-panel): full/side toggle button in the URL bar"
```
End the commit body with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## Task 4: Multi-match picker (model + overlay + keys)

**Files:**
- Create: `src/jupyter_picker.zig` (pure model)
- Modify: `src/test_fast.zig` (register it)
- Modify: `src/renderer/overlays.zig` (render the picker)
- Modify: `src/input.zig` (key handling)

- [ ] **Step 1: Write the failing tests (pure model)**

Create `src/jupyter_picker.zig`:

```zig
const std = @import("std");

pub const MAX_URLS = 16;
const MAX_URL_BYTES = 2048;

threadlocal var g_visible: bool = false;
threadlocal var g_bufs: [MAX_URLS][MAX_URL_BYTES]u8 = undefined;
threadlocal var g_lens: [MAX_URLS]usize = [_]usize{0} ** MAX_URLS;
threadlocal var g_count: usize = 0;
threadlocal var g_selected: usize = 0;

pub fn isVisible() bool {
    return g_visible;
}

pub fn count() usize {
    return g_count;
}

pub fn selectedIndex() usize {
    return g_selected;
}

pub fn urlAt(idx: usize) []const u8 {
    if (idx >= g_count) return "";
    return g_bufs[idx][0..g_lens[idx]];
}

pub fn selectedUrl() []const u8 {
    return urlAt(g_selected);
}

/// Pure selection clamp/move so the renderer and key handler agree.
pub fn nextIndex(selected: usize, delta: i32, n: usize) usize {
    if (n == 0) return 0;
    const ni: i64 = @as(i64, @intCast(selected)) + delta;
    const last: i64 = @as(i64, @intCast(n)) - 1;
    if (ni < 0) return 0;
    if (ni > last) return @intCast(last);
    return @intCast(ni);
}

pub fn show(urls: []const []const u8) void {
    g_count = @min(urls.len, MAX_URLS);
    for (0..g_count) |i| {
        const len = @min(urls[i].len, MAX_URL_BYTES);
        @memcpy(g_bufs[i][0..len], urls[i][0..len]);
        g_lens[i] = len;
    }
    g_selected = 0;
    g_visible = true;
}

pub fn move(delta: i32) void {
    g_selected = nextIndex(g_selected, delta, g_count);
}

pub fn hide() void {
    g_visible = false;
    g_count = 0;
    g_selected = 0;
}

test "nextIndex clamps at both ends" {
    try std.testing.expectEqual(@as(usize, 0), nextIndex(0, -1, 3));
    try std.testing.expectEqual(@as(usize, 1), nextIndex(0, 1, 3));
    try std.testing.expectEqual(@as(usize, 2), nextIndex(2, 1, 3));
    try std.testing.expectEqual(@as(usize, 0), nextIndex(0, -1, 0));
}

test "show stores urls and clamps to MAX_URLS; selectedUrl tracks move" {
    const urls = [_][]const u8{ "http://localhost:1/lab?token=a", "http://localhost:2/lab?token=b" };
    show(&urls);
    defer hide();
    try std.testing.expectEqual(@as(usize, 2), count());
    try std.testing.expectEqualStrings("http://localhost:1/lab?token=a", selectedUrl());
    move(1);
    try std.testing.expectEqualStrings("http://localhost:2/lab?token=b", selectedUrl());
    move(5); // clamps
    try std.testing.expectEqualStrings("http://localhost:2/lab?token=b", selectedUrl());
}
```

Register in `src/test_fast.zig`:

```zig
    _ = @import("jupyter_picker.zig");
```

- [ ] **Step 2: Run to verify failure → then pass**

Run: `zig build test`
Expected: the new `jupyter_picker` tests are present and PASS (this module is self-contained; if you wrote it complete, they pass immediately — that is acceptable for a pure data module). If you prefer strict red-first, stub `nextIndex` to `return selected;` first, see the clamp test fail, then implement.

- [ ] **Step 3: Render the picker overlay**

In `src/renderer/overlays.zig`, add a render function (model the box on `renderCommandPalette`'s primitives — `ui_pipeline.fillQuadAlpha`, `renderRoundedQuadAlpha`, `titlebar.renderTextLimited`, `font.g_titlebar_cell_height`, `AppWindow.g_theme`). Add:

```zig
const jupyter_picker = @import("../jupyter_picker.zig");

pub fn renderJupyterPicker(window_width: f32, window_height: f32) void {
    if (!jupyter_picker.isVisible()) return;
    const n = jupyter_picker.count();
    if (n == 0) return;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel = mixColor(bg, fg, 0.05);
    const border = mixColor(bg, fg, 0.18);
    const sel_bg = mixColor(bg, accent, 0.5);
    const text_color = mixColor(bg, fg, 0.88);

    const row_h: f32 = @max(28.0, font.g_titlebar_cell_height + 12);
    const box_w: f32 = @min(window_width - 80, 720);
    const title_h: f32 = row_h;
    const box_h: f32 = title_h + row_h * @as(f32, @floatFromInt(n)) + 16;
    const box_x = @round((window_width - box_w) / 2);
    const box_top = @round((window_height - box_h) / 2); // top-origin px from top
    const box_y = @round(window_height - box_top - box_h); // gl bottom-origin

    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.30);
    renderRoundedQuadAlpha(box_x - 1, box_y - 1, box_w + 2, box_h + 2, 9, border, 0.5);
    renderRoundedQuadAlpha(box_x, box_y, box_w, box_h, 8, panel, 0.99);

    const title_y = @round(box_y + box_h - title_h + (title_h - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited("Select a Jupyter server (↑/↓, Enter, Esc)", box_x + 16, title_y, mixColor(bg, fg, 0.6), box_w - 32);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row_top_px = box_top + title_h + row_h * @as(f32, @floatFromInt(i));
        const row_y = @round(window_height - row_top_px - row_h);
        if (i == jupyter_picker.selectedIndex()) {
            renderRoundedQuadAlpha(box_x + 8, row_y + 3, box_w - 16, row_h - 6, 5, sel_bg, 0.6);
        }
        const ty = @round(row_y + (row_h - font.g_titlebar_cell_height) / 2);
        _ = titlebar.renderTextLimited(jupyter_picker.urlAt(i), box_x + 18, ty, text_color, box_w - 36);
    }
}
```

Call `renderJupyterPicker(window_width, window_height)` from wherever the other top-level overlays are rendered each frame (the same place `renderCommandPalette` / `renderBrowserUrlBar` are invoked in the render loop — search `renderCommandPalette(` call site in `AppWindow.zig` and add the call right after it).

- [ ] **Step 4: Wire key handling in input.zig**

In the key-down handler, **before** the general key dispatch (so it captures keys while open), add a picker branch. Place it near the top of the key handler (mirror how `browser_panel.urlBarFocused()` is checked early at `input.zig:1287`):

```zig
    if (jupyter_picker.isVisible()) {
        switch (ev.key_code) {
            keycode.up => jupyter_picker.move(-1),
            keycode.down => jupyter_picker.move(1),
            keycode.escape => jupyter_picker.hide(),
            keycode.enter => {
                const url = jupyter_picker.selectedUrl();
                const allocator = AppWindow.g_allocator orelse {
                    jupyter_picker.hide();
                    return;
                };
                const parent = AppWindow.currentNativeHandle();
                const surface = AppWindow.activeSurface();
                browser_panel.setDisplayMode(.full);
                _ = browser_panel.openForSurface(allocator, parent, url, surface);
                jupyter_picker.hide();
                if (AppWindow.g_window) |win| syncPanelGridFromWindow(win);
            },
            else => {},
        }
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
```

Add `const jupyter_picker = @import("jupyter_picker.zig");` near the other imports at the top of `input.zig`. Use the existing key-code constants/enum the file already uses for arrows/enter/escape (match how `input.zig` references them elsewhere — e.g. the URL-bar handler around `input.zig:1564-1578` shows the enter/escape/backspace handling style; reuse the same key identifiers).

- [ ] **Step 5: Verify build + suites**

Run: `zig build test` → PASS. Run: `zig build test-full` → PASS. Run: `zig build test-shared -Dtarget=aarch64-macos` → exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/jupyter_picker.zig src/test_fast.zig src/renderer/overlays.zig src/input.zig
git commit -m "feat(jupyter): multi-server picker overlay (pure model + overlay + keys)"
```
End the commit body with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## Task 5: Auto-detect flow in Open Jupyter

**Files:**
- Modify: `src/AppWindow.zig` (`activeSurfaceSnapshot` wrapper)
- Modify: `src/input.zig` (`openJupyterPanel` rewrite)

- [ ] **Step 1: Add a focused-surface snapshot wrapper in AppWindow**

In `src/AppWindow.zig`, next to `buildRemoteSurfaceSnapshot` (`~3376`), add a public wrapper:

```zig
pub fn activeSurfaceSnapshot(allocator: std.mem.Allocator) ?[]u8 {
    const surface = activeSurface() orelse return null;
    return buildRemoteSurfaceSnapshot(allocator, surface) catch null;
}
```

- [ ] **Step 2: Rewrite `openJupyterPanel` to auto-detect**

Replace the body of `openJupyterPanel` in `src/input.zig` (added in the previous feature) with:

```zig
pub fn openJupyterPanel() void {
    const perf = ui_perf.begin("input.open_jupyter_panel");
    defer perf.end();

    const allocator = AppWindow.g_allocator orelse return;
    const parent = AppWindow.currentNativeHandle();
    const surface = AppWindow.activeSurface();
    if (!browser_panel.isVisibleForActiveTab()) AppWindow.hideAiCopilot();

    // Open Jupyter takes over the full content area.
    browser_panel.setDisplayMode(.full);

    // Auto-detect a running Jupyter URL from the focused terminal.
    if (AppWindow.activeSurfaceSnapshot(allocator)) |snap| {
        defer allocator.free(snap);
        if (jupyter_detect.findJupyterUrls(allocator, snap) catch null) |result| {
            defer result.deinit(allocator);
            if (result.urls.len == 1) {
                if (!browser_panel.openForSurface(allocator, parent, result.urls[0], surface)) return;
                finishOpenJupyter();
                return;
            } else if (result.urls.len >= 2) {
                jupyter_picker.show(result.urls);
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                return;
            }
        }
    }

    // 0 matches → open full + focus empty URL bar for manual paste.
    if (!browser_panel.openJupyterForSurface(allocator, parent, surface)) return;
    finishOpenJupyter();
}

fn finishOpenJupyter() void {
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}
```

Add `const jupyter_detect = @import("jupyter_detect.zig");` near the top imports of `input.zig` (alongside the `jupyter_picker` import from Task 4).

- [ ] **Step 3: Esc-to-close for the panel**

In the key-down handler, where Esc is handled, add: when the browser panel is visible, the URL bar is NOT focused, and the picker is NOT visible, Esc closes the panel. Locate the existing Escape handling (the URL-bar branch blurs the bar at `input.zig:1564`); add, after the picker branch (Task 4) and after the url-bar-focused branch, a guard:

```zig
    if (browser_panel.isVisibleForActiveTab() and !browser_panel.urlBarFocused()) {
        if (ev.key_code == keycode.escape) {
            closeBrowserPanel();
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
            return;
        }
    }
```

(Use the same Escape key identifier the file already uses. Esc only reaches here when WispTerm holds keyboard focus; when the embedded web page has focus the webview consumes Esc — that is the documented best-effort behavior, and ✕ is the guaranteed close.)

- [ ] **Step 4: Verify build + suites**

Run: `zig build test` → PASS. Run: `zig build test-full` → PASS. Run: `zig build test-shared -Dtarget=aarch64-macos` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig src/input.zig
git commit -m "feat(jupyter): auto-detect URL from focused terminal; full-screen open; Esc closes"
```
End the commit body with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## Task 6: GUI verification (manual)

**Files:** none (manual; Windows now, macOS later).

- [ ] **Step 1: Windows (WebView2) end-to-end**
  - Start Jupyter on a server reached via a WispTerm SSH session: `jupyter lab --no-browser` (note the printed `http://localhost:PORT/lab?token=...`).
  - With that SSH tab focused, run **Open Jupyter** (Ctrl+Shift+P). Verify: it auto-detects the URL, opens **full-screen** (terminal hidden), and renders JupyterLab via the tunnel — no manual paste.
- [ ] **Step 2: Toggle + close**
  - Click the toggle button (left of ✕): full → side (terminal reappears on the left) and back. Click ✕: panel closes, terminal restored. Press Esc (when the web page doesn't hold focus): panel closes.
- [ ] **Step 3: Picker**
  - Start two Jupyter servers (different ports/tokens) so both URLs are in scrollback. Run Open Jupyter → verify the picker lists **two** entries (not four — the localhost/127.0.0.1 pair for each server is deduped by token). ↑/↓ + Enter opens the chosen one full-screen; Esc cancels.
- [ ] **Step 4: No-match fallback**
  - In a terminal with no Jupyter URL, run Open Jupyter → verify it opens full with an empty, focused URL bar for manual paste.
- [ ] **Step 5: macOS** — repeat once the WKWebView build runs on a Mac (coord-flip/scale of the full-area webview, ATS for the tunnel).

---

## Self-Review

**Spec coverage:**
- Display mode side⇄full + full covers area, terminal hidden → Task 2 (`panelWidthForMode` full branch; webview occludes terminal). ✓
- Toggle button + close ✕ at URL-bar right → Task 3 (toggle; close already wired). ✓
- Esc also closes (best-effort, documented) → Task 5 Step 3. ✓
- Auto-detect from focused terminal → Tasks 1 + 5. ✓
- Dedupe by token, prefer localhost, most-recent-first → Task 1 (`findJupyterUrls`). ✓
- 0 → manual fallback, 1 → open, 2+ → picker → Task 5 flow. ✓
- Picker (list, ↑/↓/Enter/click/Esc) → Task 4. (Click-to-select on a row is optional polish; keyboard + Enter is implemented. If row-click is wanted, add a hit-test in Task 4 Step 4 — noted, not required by spec.) ✓ (keyboard path)
- Testing: pure detector + width math + picker model + button rect via unit tests; rest GUI → Tasks 1–4 unit steps + Task 6. ✓

**Placeholder scan:** Complete code in every code step. The render-loop call site for `renderJupyterPicker` (Task 4 Step 3) and the exact arrow/enter/escape key identifiers (Task 4 Step 4, Task 5 Step 3) are specified by pointing at the precise existing call site / handler to mirror — concrete, not "TBD".

**Type consistency:** `DisplayMode`/`setDisplayMode`/`displayMode`/`panelWidthForMode` consistent across Tasks 2/3/5. `jupyter_detect.Result{ urls: [][]u8, deinit }` consistent between Task 1 and its consumer in Task 5. `jupyter_picker.{isVisible,count,selectedIndex,urlAt,selectedUrl,show,move,hide,nextIndex}` consistent across Tasks 4/5. `hit_test.panelSecondButtonRect/panelHeaderSecondButton` consistent across Tasks 3 render/input. `activeSurfaceSnapshot` defined in Task 5 Step 1, used Step 2.

**Note on row-click in picker:** spec says "↑/↓/Enter + click". Keyboard is implemented; mouse-row-click is optional polish. If desired, add in Task 4: a `pickerRowAt(x,y)` hit-test computed from the same box math and select+open on click.
