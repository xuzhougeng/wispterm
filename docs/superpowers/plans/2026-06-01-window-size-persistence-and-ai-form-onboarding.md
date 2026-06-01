# Window Size Persistence + AI-Form First-Launch-Only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remember the window's last size across launches (instead of forcing an 80×24 grid), and stop auto-popping the AI-agent setup form on every launch — show it only on the first launch.

**Architecture:** Pure serialization/validation goes in a new `window_state_codec.zig` (unit-tested in the fast suite); `window_state.zig` becomes a thin I/O layer over it, persisting `{x, y, width, height, ai-setup-prompted}` with read-modify-write partial updates. `AppWindow.zig` saves the framebuffer size on close, restores it on launch (unless an explicit `window-width/height` config wins), and gates the startup AI form on a persisted flag. Sizing uses framebuffer pixels end-to-end so it round-trips exactly on the same display with no DPI math.

**Tech Stack:** Zig; native window backends (macOS/AppKit, Windows/Win32); `zig build test` (fast suite) + `zig build test-full` (full graph).

**Reference spec:** `docs/superpowers/specs/2026-06-01-window-size-persistence-and-ai-form-onboarding-design.md`

**Task ordering note:** Task 4 rewrites `window_state.zig` and removes the old `saveWindowState` symbol; the full graph (`AppWindow.zig`) does not compile cleanly again until Task 5 lands. The fast suite (`zig build test`) stays green throughout because it does not compile `AppWindow.zig`. Tasks 1-3 each keep both suites green; Tasks 4-5 are a paired break/fix verified together at the end of Task 5.

---

## File Structure

- **Create** `src/platform/window_state_codec.zig` — pure (std-only) `PersistedState` struct, `parse`/`format`, `sizeIsValid`, `mergeGeometry`. Holds all logic worth testing.
- **Modify** `src/platform/window_state.zig` — thin I/O over the codec: `loadWindowState` (now with size), `saveWindowGeometry`, `aiSetupPrompted`, `setAiSetupPrompted`. Keeps the position off-screen guard.
- **Modify** `src/startup_tabs.zig` — add `shouldAutoShowAgentForm` pure helper + test.
- **Modify** `src/App.zig` — add `window_size_from_config: bool` field, derived from config.
- **Modify** `src/AppWindow.zig` — restore saved size, save size on close, gate the AI form on the persisted flag.
- **Modify** `src/test_fast.zig` — register the new codec module and `startup_tabs.zig` in the fast suite.

---

## Task 1: Window-state codec (pure parse/format/validate)

**Files:**
- Create: `src/platform/window_state_codec.zig`
- Modify: `src/test_fast.zig` (register module)

- [ ] **Step 1: Write the codec module with its tests**

Create `src/platform/window_state_codec.zig`:

```zig
//! Pure (std-only) serialization + validation for the window/UI state file.
//! Kept dependency-light so it unit-tests in the fast suite without pulling in
//! platform display/dirs code. `window_state.zig` is the I/O layer over this.
const std = @import("std");

/// Reject restored sizes smaller than this (treat as "no saved size").
pub const MIN_WIDTH: i32 = 200;
pub const MIN_HEIGHT: i32 = 150;

pub const PersistedState = struct {
    x: ?i32 = null,
    y: ?i32 = null,
    width: ?i32 = null,
    height: ?i32 = null,
    ai_setup_prompted: bool = false,
};

pub fn sizeIsValid(width: i32, height: i32) bool {
    return width >= MIN_WIDTH and height >= MIN_HEIGHT;
}

/// Parse `key = value` lines. Unknown keys and malformed numbers are ignored;
/// missing keys keep their PersistedState defaults.
pub fn parse(data: []const u8) PersistedState {
    var state = PersistedState{};
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
        if (trimmed.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], &[_]u8{ ' ', '\t' });
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], &[_]u8{ ' ', '\t' });
        if (std.mem.eql(u8, key, "window-x")) {
            state.x = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "window-y")) {
            state.y = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "window-width")) {
            state.width = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "window-height")) {
            state.height = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "ai-setup-prompted")) {
            state.ai_setup_prompted = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
        }
    }
    return state;
}

/// Format `state` as `key = value` lines into `buf`. Optional geometry fields are
/// written only when non-null; the flag is always written.
pub fn format(buf: []u8, state: PersistedState) ![]const u8 {
    var len: usize = 0;
    if (state.x) |x| len += (try std.fmt.bufPrint(buf[len..], "window-x = {d}\n", .{x})).len;
    if (state.y) |y| len += (try std.fmt.bufPrint(buf[len..], "window-y = {d}\n", .{y})).len;
    if (state.width) |w| len += (try std.fmt.bufPrint(buf[len..], "window-width = {d}\n", .{w})).len;
    if (state.height) |h| len += (try std.fmt.bufPrint(buf[len..], "window-height = {d}\n", .{h})).len;
    len += (try std.fmt.bufPrint(buf[len..], "ai-setup-prompted = {d}\n", .{@intFromBool(state.ai_setup_prompted)})).len;
    return buf[0..len];
}

/// Copy of `state` with position overwritten; size fields replaced only when the
/// argument is non-null (so a maximized save updates position but preserves the
/// last windowed size).
pub fn mergeGeometry(state: PersistedState, x: i32, y: i32, width: ?i32, height: ?i32) PersistedState {
    var next = state;
    next.x = x;
    next.y = y;
    if (width) |val| next.width = val;
    if (height) |val| next.height = val;
    return next;
}

test "parse reads an old position-only state file" {
    const s = parse("window-x = 100\nwindow-y = 200\n");
    try std.testing.expectEqual(@as(?i32, 100), s.x);
    try std.testing.expectEqual(@as(?i32, 200), s.y);
    try std.testing.expectEqual(@as(?i32, null), s.width);
    try std.testing.expectEqual(@as(?i32, null), s.height);
    try std.testing.expectEqual(false, s.ai_setup_prompted);
}

test "parse reads a full state file with size and flag" {
    const s = parse("window-x = -5\nwindow-y = 0\nwindow-width = 1280\nwindow-height = 800\nai-setup-prompted = 1\n");
    try std.testing.expectEqual(@as(?i32, -5), s.x);
    try std.testing.expectEqual(@as(?i32, 1280), s.width);
    try std.testing.expectEqual(@as(?i32, 800), s.height);
    try std.testing.expectEqual(true, s.ai_setup_prompted);
}

test "parse ignores unknown keys and malformed numbers" {
    const s = parse("garbage\nwindow-x = notanumber\ncolor = red\nai-setup-prompted = true\n");
    try std.testing.expectEqual(@as(?i32, null), s.x);
    try std.testing.expectEqual(true, s.ai_setup_prompted);
}

test "format round-trips through parse" {
    const original = PersistedState{ .x = 12, .y = 34, .width = 1024, .height = 768, .ai_setup_prompted = true };
    var buf: [256]u8 = undefined;
    const text = try format(&buf, original);
    const reparsed = parse(text);
    try std.testing.expectEqual(original.x, reparsed.x);
    try std.testing.expectEqual(original.y, reparsed.y);
    try std.testing.expectEqual(original.width, reparsed.width);
    try std.testing.expectEqual(original.height, reparsed.height);
    try std.testing.expectEqual(original.ai_setup_prompted, reparsed.ai_setup_prompted);
}

test "format omits null geometry but always writes the flag" {
    var buf: [256]u8 = undefined;
    const text = try format(&buf, .{ .ai_setup_prompted = false });
    try std.testing.expectEqualStrings("ai-setup-prompted = 0\n", text);
}

test "sizeIsValid rejects degenerate sizes" {
    try std.testing.expect(sizeIsValid(800, 600));
    try std.testing.expect(sizeIsValid(MIN_WIDTH, MIN_HEIGHT));
    try std.testing.expect(!sizeIsValid(10, 600));
    try std.testing.expect(!sizeIsValid(800, 10));
}

test "mergeGeometry preserves size when width/height are null" {
    const base = PersistedState{ .x = 1, .y = 2, .width = 1000, .height = 700, .ai_setup_prompted = true };
    const merged = mergeGeometry(base, 9, 8, null, null);
    try std.testing.expectEqual(@as(?i32, 9), merged.x);
    try std.testing.expectEqual(@as(?i32, 8), merged.y);
    try std.testing.expectEqual(@as(?i32, 1000), merged.width);
    try std.testing.expectEqual(@as(?i32, 700), merged.height);
    try std.testing.expectEqual(true, merged.ai_setup_prompted);
}

test "mergeGeometry overwrites size when provided" {
    const merged = mergeGeometry(.{}, 0, 0, 1280, 720);
    try std.testing.expectEqual(@as(?i32, 1280), merged.width);
    try std.testing.expectEqual(@as(?i32, 720), merged.height);
}
```

- [ ] **Step 2: Register the module in the fast suite**

In `src/test_fast.zig`, after the line `_ = @import("command_center_state.zig");` (line 33), add:

```zig
    _ = @import("platform/window_state_codec.zig");
```

- [ ] **Step 3: Run the codec tests and verify they pass**

Run: `zig build test`
Expected: build succeeds, all tests pass (the 9 new `window_state_codec` tests included).

- [ ] **Step 4: Commit**

```bash
git add src/platform/window_state_codec.zig src/test_fast.zig
git commit -m "feat(window-state): pure codec for window/UI state persistence

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `shouldAutoShowAgentForm` startup helper

**Files:**
- Modify: `src/startup_tabs.zig` (add helper + test)
- Modify: `src/test_fast.zig` (register `startup_tabs.zig` in the fast suite)

- [ ] **Step 1: Write the failing test + helper**

In `src/startup_tabs.zig`, add the function right after the `initialTabPlan` function (after its closing `}` at line 20):

```zig
/// Whether the startup AI-agent setup form should auto-open. True only when no AI
/// profile exists AND the form has not been shown on a previous launch. Pure so it
/// is unit-testable without the GUI.
pub fn shouldAutoShowAgentForm(has_ai_profile: bool, already_prompted: bool) bool {
    return !has_ai_profile and !already_prompted;
}
```

Add this test at the end of the file (after the existing `initialTabPlan` test):

```zig
test "startup AI form auto-shows only when no profile and not yet prompted" {
    try std.testing.expect(shouldAutoShowAgentForm(false, false));
    try std.testing.expect(!shouldAutoShowAgentForm(true, false));
    try std.testing.expect(!shouldAutoShowAgentForm(false, true));
    try std.testing.expect(!shouldAutoShowAgentForm(true, true));
}
```

- [ ] **Step 2: Register `startup_tabs.zig` in the fast suite**

In `src/test_fast.zig`, directly below the import added in Task 1, add:

```zig
    _ = @import("startup_tabs.zig");
```

- [ ] **Step 3: Run the tests and verify they pass**

Run: `zig build test`
Expected: build succeeds; the new `shouldAutoShowAgentForm` test passes (and the existing `initialTabPlan` test now also runs in the fast suite).

- [ ] **Step 4: Commit**

```bash
git add src/startup_tabs.zig src/test_fast.zig
git commit -m "feat(startup): pure helper gating first-launch AI-agent form

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `App.window_size_from_config` flag

**Files:**
- Modify: `src/App.zig:54-55` (field declaration), `:202` (construction), `:373` (reconfigure)

This is a trivial derived boolean (no branching logic) — verified by build (`zig build test-full`), no dedicated unit test. It lands before the `window_state.zig` rewrite so the full graph still compiles cleanly here.

- [ ] **Step 1: Add the struct field**

In `src/App.zig`, the fields currently read (around line 53-55):

```zig
// Terminal dimensions from config
initial_cols: u16,
initial_rows: u16,
```

Change to:

```zig
// Terminal dimensions from config
initial_cols: u16,
initial_rows: u16,
/// True when window-width/window-height were explicitly set in config (>0).
/// When set, the configured cell grid wins over a remembered window size.
window_size_from_config: bool,
```

- [ ] **Step 2: Set it at construction**

In `src/App.zig` around line 202-203:

```zig
        .initial_cols = if (cfg.@"window-width" > 0) cfg.@"window-width" else 80,
        .initial_rows = if (cfg.@"window-height" > 0) cfg.@"window-height" else 24,
```

Add directly below those two lines:

```zig
        .window_size_from_config = cfg.@"window-width" > 0 or cfg.@"window-height" > 0,
```

- [ ] **Step 3: Set it at reconfigure**

In `src/App.zig` around line 373-374:

```zig
    self.initial_cols = if (cfg.@"window-width" > 0) cfg.@"window-width" else 80;
    self.initial_rows = if (cfg.@"window-height" > 0) cfg.@"window-height" else 24;
```

Add directly below those two lines:

```zig
    self.window_size_from_config = cfg.@"window-width" > 0 or cfg.@"window-height" > 0;
```

- [ ] **Step 4: Verify the full graph compiles and passes**

Run: `zig build test-full`
Expected: builds and all tests pass with 0 failures. (Only an additive field + two assignments changed; nothing else references it yet.)

- [ ] **Step 5: Commit**

```bash
git add src/App.zig
git commit -m "feat(app): expose window_size_from_config flag from config

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `window_state.zig` I/O layer over the codec

**Files:**
- Modify: `src/platform/window_state.zig` (full rewrite — small file)

> After this task the full graph (`AppWindow.zig`) will NOT compile until Task 5, because the old `saveWindowState` symbol is removed. The fast suite stays green (it does not compile `AppWindow.zig`). This is expected; Task 5 restores the full build.

- [ ] **Step 1: Rewrite the module to delegate to the codec**

Replace the entire contents of `src/platform/window_state.zig` with:

```zig
//! Window/UI state persistence — save/restore window geometry + onboarding flags
//! across sessions. Pure serialization/validation lives in window_state_codec.zig;
//! this module is the I/O layer (state file + display validation).

const std = @import("std");
const platform_display = @import("display.zig");
const platform_dirs = @import("dirs.zig");
const codec = @import("window_state_codec.zig");

pub const PersistedState = codec.PersistedState;

/// Saved window geometry for restore. `width`/`height` are framebuffer pixels and
/// are null when no valid size was stored.
pub const WindowState = struct {
    x: i32,
    y: i32,
    width: ?i32 = null,
    height: ?i32 = null,
};

// Saved windowed position for restore (used by window state persistence)
pub threadlocal var g_windowed_x: c_int = 0;
pub threadlocal var g_windowed_y: c_int = 0;

/// Return the state file path in the platform config directory.
pub fn stateFilePath(allocator: std.mem.Allocator) ?[]const u8 {
    return platform_dirs.stateFilePath(allocator) catch null;
}

fn loadPersisted(allocator: std.mem.Allocator) codec.PersistedState {
    const path = stateFilePath(allocator) orelse return .{};
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch return .{};
    defer allocator.free(data);
    return codec.parse(data);
}

fn savePersisted(allocator: std.mem.Allocator, state: codec.PersistedState) void {
    const path = stateFilePath(allocator) orelse return;
    defer allocator.free(path);
    var buf: [256]u8 = undefined;
    const content = codec.format(&buf, state) catch return;
    if (std.fs.cwd().createFile(path, .{})) |file| {
        defer file.close();
        file.writeAll(content) catch {};
    } else |_| {}
}

/// Load saved window geometry. Returns null unless a position is stored and its
/// restored frame lands on a visible monitor. Size is included only when stored
/// and non-degenerate.
pub fn loadWindowState(allocator: std.mem.Allocator) ?WindowState {
    const state = loadPersisted(allocator);
    const x = state.x orelse return null;
    const y = state.y orelse return null;

    // Check a point inside the restored frame, not just the saved origin.
    if (!platform_display.isPointOnAnyDisplay(x + 50, y + 50)) {
        std.debug.print("Saved window position ({}, {}) is off-screen, ignoring\n", .{ x, y });
        return null;
    }

    var result = WindowState{ .x = x, .y = y };
    if (state.width) |w| {
        if (state.height) |h| {
            if (codec.sizeIsValid(w, h)) {
                result.width = w;
                result.height = h;
            }
        }
    }
    return result;
}

/// Save window geometry (read-modify-write to preserve the onboarding flag).
/// `width`/`height` are framebuffer pixels; pass null to preserve the last saved
/// size (e.g. when saving while maximized/fullscreen).
pub fn saveWindowGeometry(allocator: std.mem.Allocator, x: i32, y: i32, width: ?i32, height: ?i32) void {
    const current = loadPersisted(allocator);
    savePersisted(allocator, codec.mergeGeometry(current, x, y, width, height));
}

/// Whether the first-launch AI-agent setup form has already been shown.
pub fn aiSetupPrompted(allocator: std.mem.Allocator) bool {
    return loadPersisted(allocator).ai_setup_prompted;
}

/// Record that the first-launch AI-agent setup form has been shown
/// (read-modify-write to preserve geometry). No-op if already set.
pub fn setAiSetupPrompted(allocator: std.mem.Allocator) void {
    var current = loadPersisted(allocator);
    if (current.ai_setup_prompted) return;
    current.ai_setup_prompted = true;
    savePersisted(allocator, current);
}
```

- [ ] **Step 2: Verify the fast suite still builds and passes**

Run: `zig build test`
Expected: exit 0, all tests pass. (Proves `window_state.zig` + codec compile together. `test-full` is expected to be broken now — fixed in Task 5; do not run it yet.)

- [ ] **Step 3: Commit**

```bash
git add src/platform/window_state.zig
git commit -m "feat(window-state): persist size + ai-setup flag via codec I/O layer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Wire `AppWindow.zig` — restore size, save size, gate AI form

**Files:**
- Modify: `src/AppWindow.zig` — aliases (`:1331-1332`), AI-form gate (`:1060-1064`), restore load (`:3616-3623`), sizing block (`:3862-3877`), save block (`:4280-4292`)

No unit test (GUI integration path; `AppWindow.zig` is not in either test binary). Verified by `zig build test-full` compiling/passing and by manual GUI checks in Task 6.

- [ ] **Step 1: Update the window-state aliases**

In `src/AppWindow.zig` lines 1331-1332, currently:

```zig
const loadWindowState = platform_window_state.loadWindowState;
const saveWindowState = platform_window_state.saveWindowState;
```

Replace with:

```zig
const loadWindowState = platform_window_state.loadWindowState;
const saveWindowGeometry = platform_window_state.saveWindowGeometry;
```

(`aiSetupPrompted` / `setAiSetupPrompted` are called via the `platform_window_state.` prefix below — no aliases needed.)

- [ ] **Step 2: Gate the startup AI form on the persisted flag**

In `src/AppWindow.zig`, the `spawnDefaultAgentAndLocalShellTabs(allocator: std.mem.Allocator)` function currently has (lines 1060-1064):

```zig
    // No AI profile yet: surface the profile-creation form so the user can set
    // one up (the form is an overlay, not a tab).
    if (!has_ai_profile) {
        _ = overlays.openDefaultAgentSessionForStartup();
    }
```

Replace with:

```zig
    // No AI profile yet: surface the profile-creation form so the user can set one
    // up (the form is an overlay, not a tab) — but only on the first launch. After
    // it has been shown once, the persisted flag suppresses it so it does not
    // reappear every launch. Users can still open setup via the session launcher.
    if (startup_tabs.shouldAutoShowAgentForm(has_ai_profile, platform_window_state.aiSetupPrompted(allocator))) {
        _ = overlays.openDefaultAgentSessionForStartup();
        platform_window_state.setAiSetupPrompted(allocator);
    }
```

- [ ] **Step 3: Load the saved size at startup**

In `src/AppWindow.zig`, the restore block currently reads (lines 3616-3623):

```zig
    // Fall back to saved state if no cascade position
    if (init_x == null or init_y == null) {
        const saved_state = loadWindowState(allocator);
        if (saved_state) |s| {
            if (init_x == null) init_x = s.x;
            if (init_y == null) init_y = s.y;
        }
    }
```

Replace with (declare saved-size vars at function scope so the sizing block below can read them; always load so size restores even when a cascade supplies the position):

```zig
    // Restore saved geometry. Position only fills gaps left by a cascade; size is
    // restored regardless (framebuffer px, applied in the sizing block below).
    var saved_fb_w: ?i32 = null;
    var saved_fb_h: ?i32 = null;
    {
        const saved_state = loadWindowState(allocator);
        if (saved_state) |s| {
            if (init_x == null) init_x = s.x;
            if (init_y == null) init_y = s.y;
            saved_fb_w = s.width;
            saved_fb_h = s.height;
        }
    }
```

- [ ] **Step 4: Apply the size precedence in the sizing block**

In `src/AppWindow.zig`, the sizing block currently reads (lines 3862-3877):

```zig
    if (g_quake_mode) {
        applyQuakeFrame(&backend_window, false);
    } else if (term_cols > 0 and term_rows > 0) {
        // If config specifies window-width/window-height, resize window to fit that grid.
        // term_cols/term_rows were set from config at init.
        // Calculate window size needed for desired grid
        const desired_grid_width = font.cell_width * @as(f32, @floatFromInt(term_cols));
        const desired_grid_height = font.cell_height * @as(f32, @floatFromInt(term_rows));

        // Work backwards: fb_width = grid_width + total_width_padding
        //                 fb_height = grid_height + total_height_padding
        const target_fb_width: i32 = @intFromFloat(desired_grid_width + total_width_padding);
        const target_fb_height: i32 = @intFromFloat(desired_grid_height + total_height_padding);

        window_backend.resizeClientArea(&backend_window, target_fb_width, target_fb_height);
    }
```

Replace with:

```zig
    // Initial sizing precedence:
    //   1. quake mode -> quake frame
    //   2. explicit window-width/height in config -> fit that cell grid
    //   3. remembered window size from last session -> restore it (framebuffer px)
    //   4. otherwise -> default cell grid (first-ever launch)
    const size_from_config = if (g_app) |app| app.window_size_from_config else false;
    // Grid size needed for term_cols/term_rows (used by branches 2 and 4).
    const desired_grid_width = font.cell_width * @as(f32, @floatFromInt(term_cols));
    const desired_grid_height = font.cell_height * @as(f32, @floatFromInt(term_rows));
    const target_fb_width: i32 = @intFromFloat(desired_grid_width + total_width_padding);
    const target_fb_height: i32 = @intFromFloat(desired_grid_height + total_height_padding);

    if (g_quake_mode) {
        applyQuakeFrame(&backend_window, false);
    } else if (size_from_config and term_cols > 0 and term_rows > 0) {
        window_backend.resizeClientArea(&backend_window, target_fb_width, target_fb_height);
    } else if (saved_fb_w) |sw| {
        window_backend.resizeClientArea(&backend_window, sw, saved_fb_h.?);
    } else if (term_cols > 0 and term_rows > 0) {
        window_backend.resizeClientArea(&backend_window, target_fb_width, target_fb_height);
    }
```

- [ ] **Step 5: Save the size on close**

In `src/AppWindow.zig`, the save block currently reads (lines 4280-4292):

```zig
    // Save window position for next session
    if (!g_quake_mode and g_window != null) {
        const w = g_window.?;
        if (window_backend.windowRect(w)) |rect| {
            const is_maximized = window_backend.isMaximized(w);
            if (!is_maximized and !window_backend.isFullscreen(w)) {
                saveWindowState(allocator, .{ .x = rect.left, .y = rect.top });
            } else {
                // Save the last known windowed position before maximize/fullscreen
                saveWindowState(allocator, .{ .x = platform_window_state.g_windowed_x, .y = platform_window_state.g_windowed_y });
            }
        }
    }
```

Replace with:

```zig
    // Save window position + size for next session
    if (!g_quake_mode and g_window != null) {
        const w = g_window.?;
        if (window_backend.windowRect(w)) |rect| {
            const is_maximized = window_backend.isMaximized(w);
            if (!is_maximized and !window_backend.isFullscreen(w)) {
                const fb = window_backend.framebufferSize(w);
                saveWindowGeometry(allocator, rect.left, rect.top, fb.width, fb.height);
            } else {
                // Save the last known windowed position; preserve the remembered
                // windowed size (null leaves the saved width/height untouched).
                saveWindowGeometry(allocator, platform_window_state.g_windowed_x, platform_window_state.g_windowed_y, null, null);
            }
        }
    }
```

- [ ] **Step 6: Verify the full graph compiles and passes**

Run: `zig build test-full`
Expected: builds and all tests pass with 0 failures (no remaining `saveWindowState` references; new `startup_tabs`/`window_state_codec` tests included).

- [ ] **Step 7: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(window): remember window size; show AI form only on first launch

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Verify both suites + manual GUI check

**Files:** none (verification + notes)

- [ ] **Step 1: Run the fast suite**

Run: `zig build test`
Expected: exit 0, all tests pass.

- [ ] **Step 2: Run the full suite**

Run: `zig build test-full`
Expected: exit 0, 0 failures (a few skips are normal).

- [ ] **Step 3: Verify there are no leftover references to the removed API**

Run: `grep -rn "saveWindowState" src --include="*.zig"`
Expected: no matches.

- [ ] **Step 4: Manual GUI verification (user, macOS/Windows — no Linux GUI backend)**

Provide these steps to the user to confirm on a real GUI build (`zig build run` / packaged build):
1. Launch, resize the window to a comfortable size, close. Relaunch → window reopens at the remembered size (not a top strip / not 80×24).
2. Set `window-width`/`window-height` in the config file, relaunch → the configured grid wins over the remembered size.
3. Maximize, close, relaunch, un-maximize → the previously remembered windowed size is intact.
4. With **no** AI profile saved: first launch shows the AI-agent setup form once; close without saving a profile; relaunch → the form does **not** auto-appear (two shell tabs open instead). Setup is still reachable via the session launcher → AI agent.
5. Delete the state file (`~/.config/wispterm/<state file>`), relaunch → first-launch behavior returns (default grid + AI form once).

---

## Self-Review Notes

- **Spec coverage:** size persistence (Tasks 4,5) ✓; explicit-config-wins precedence (Tasks 3,5 step 4) ✓; framebuffer-px units (Task 5 steps 4-5) ✓; min-size validity, work-area clamp deferred (Task 1 `sizeIsValid`, Task 4 `loadWindowState`) ✓; position off-screen guard preserved (Task 4) ✓; AI-form first-launch-only via persisted flag (Tasks 1,2,4,5 step 2) ✓; pure helper in `startup_tabs.zig` (Task 2) ✓; fast-suite tests for codec + helper (Tasks 1,2) ✓; backward-compat with old x/y-only files (Task 1 test) ✓.
- **Type consistency:** `PersistedState`, `WindowState{x,y,width?,height?}`, `saveWindowGeometry(allocator, i32, i32, ?i32, ?i32)`, `aiSetupPrompted(allocator) bool`, `setAiSetupPrompted(allocator)`, `shouldAutoShowAgentForm(bool,bool) bool`, `App.window_size_from_config: bool` used consistently across tasks.
- **Known caveat:** `g_windowed_x/y` are `c_int`; they coerce to the `i32` params of `saveWindowGeometry` exactly as the prior `saveWindowState` call did (same bit width on these targets).
