# Copilot Discoverability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `Ctrl/Cmd+Shift+A` Copilot sidebar discoverable via a reveal-on-proximity "summon handle" at the terminal's right edge (universal), a one-time first-session shimmer, plus platform-native bonuses (Windows/Linux titlebar icon, macOS View-menu item) and reference entries in the shortcuts overlay and command center.

**Architecture:** Push all logic into pure, fast-tested modules (`copilot_hint_gate.zig` for decisions, `ai_sidebar.closedHandleRect` for geometry, `window_state_codec` for the persisted flag). Keep the GL/input shell thin: a handle renderer + a minimal tooltip primitive driven by those pure functions. The cross-platform asymmetry is handled by one constant (`TITLEBAR_COPILOT_W = macos ? 0 : 46`); macOS gets a native menu item instead.

**Tech Stack:** Zig; custom GPU titlebar/overlay renderer (`src/renderer/overlays/*`); state persisted as `key = value` lines in the platform state file. Tests: `zig build test` (fast, std-only logic) and `zig build test-full` (full app + posix). App build: `zig build`.

**Spec:** `docs/superpowers/specs/2026-06-16-copilot-discoverability-design.md`

---

## File Structure

**New files:**
- `src/copilot_hint_gate.zig` — pure decisions (`shimmerDecision`, `handleRevealTarget`). Fast-suite tested.
- `src/renderer/overlays/hint_tooltip.zig` — minimal hover-tooltip primitive (rounded quad + one text line).
- `src/renderer/overlays/copilot_edge_handle.zig` — closed-state summon handle: reveal easing, hover, shimmer; calls `hint_tooltip`.

**Modified files:**
- `src/ai_sidebar.zig` — add `HandleRect` + `closedHandleRect` (geometry single source of truth).
- `src/platform/window_state_codec.zig` — add `copilot_hint_shown` flag (parse/format/struct).
- `src/platform/window_state.zig` — `copilotHintShown` / `setCopilotHintShown` I/O wrappers.
- `src/test_fast.zig` — register `copilot_hint_gate.zig`.
- `src/input.zig` — `hitTestCopilotEdgeHandle`, mouse-move proximity/hover wiring, click→toggle, `handleTopbarPress` titlebar-icon branch.
- `src/AppWindow.zig` — render call sites for the handle; set hint-shown flag inside `toggleAiCopilot`; per-frame shimmer trigger.
- `src/renderer/titlebar.zig` — `TITLEBAR_COPILOT_W` + icon render block + `renderFallbackCopilotIcon`.
- `src/platform/menu_macos.zig` — View ▸ Toggle Copilot item + id mapping.
- `src/command_center_state.zig` — `CommandAction.toggle_ai_copilot` + command entry.
- `src/renderer/overlays.zig` — `executeCommand` arm for the new action.
- `src/i18n.zig` — zh title/detail for the new command entry.
- `src/renderer/overlays/startup_shortcuts.zig` — shortcut-reference entry.
- `src/config.zig` — `copilot-hint` bool key (default true).

---

## Phase 1 — Pure core (decisions + geometry)

### Task 1: `copilot_hint_gate.zig` — pure decisions

**Files:**
- Create: `src/copilot_hint_gate.zig`
- Modify: `src/test_fast.zig` (register the module)
- Test: inline tests in `src/copilot_hint_gate.zig`

- [ ] **Step 1: Write the failing tests + skeleton**

Create `src/copilot_hint_gate.zig`:

```zig
//! Pure (std-only) decisions for the Copilot discoverability hint. No I/O, no
//! GL, no window — unit-tested in the fast suite. The render/input shell in
//! AppWindow/input.zig supplies the runtime inputs and performs the effects.
const std = @import("std");

pub const ShimmerDecision = enum { shimmer, skip };

/// Whether to play the one-time first-session shimmer on the edge handle.
/// Shimmer only when the feature is enabled, the handle is eligible (a terminal
/// tab with Copilot closed and room to open it), and the user has never seen
/// the hint before.
pub fn shimmerDecision(
    feature_enabled: bool,
    handle_eligible: bool,
    hint_already_shown: bool,
) ShimmerDecision {
    if (!feature_enabled) return .skip;
    if (!handle_eligible) return .skip;
    if (hint_already_shown) return .skip;
    return .shimmer;
}

/// Target reveal alpha [0, revealed_alpha] for the closed-state handle, from the
/// cursor's proximity to the window's right content edge. Pure math; the
/// renderer eases the actual alpha toward this and applies the hover boost.
/// `mouse_x`/`mouse_y` are framebuffer px (top-left origin); the platform passes
/// negative values when the cursor is outside the window.
pub fn handleRevealTarget(
    mouse_x: f32,
    mouse_y: f32,
    window_w: f32,
    titlebar_h: f32,
    reveal_zone_w: f32,
    revealed_alpha: f32,
) f32 {
    if (mouse_x < 0 or mouse_y < 0) return 0;
    if (mouse_y < titlebar_h) return 0; // in the titlebar, not content
    const dist = window_w - mouse_x;
    if (dist < 0 or dist > reveal_zone_w) return 0;
    return revealed_alpha;
}

test "shimmer only on first eligible terminal frame" {
    try std.testing.expectEqual(ShimmerDecision.shimmer, shimmerDecision(true, true, false));
    try std.testing.expectEqual(ShimmerDecision.skip, shimmerDecision(false, true, false)); // disabled
    try std.testing.expectEqual(ShimmerDecision.skip, shimmerDecision(true, false, false)); // not eligible
    try std.testing.expectEqual(ShimmerDecision.skip, shimmerDecision(true, true, true)); // already shown
}

test "reveal target rises near the right edge only, below the titlebar" {
    // far from edge -> 0
    try std.testing.expectEqual(@as(f32, 0), handleRevealTarget(100, 400, 1000, 30, 28, 0.5));
    // within zone, in content -> revealed
    try std.testing.expectEqual(@as(f32, 0.5), handleRevealTarget(985, 400, 1000, 30, 28, 0.5));
    // within zone but in the titlebar -> 0
    try std.testing.expectEqual(@as(f32, 0), handleRevealTarget(985, 10, 1000, 30, 28, 0.5));
    // cursor outside window (negative sentinel) -> 0
    try std.testing.expectEqual(@as(f32, 0), handleRevealTarget(-1, -1, 1000, 30, 28, 0.5));
}
```

Register in `src/test_fast.zig` (alongside the existing pure-module imports near line 132):

```zig
    _ = @import("copilot_hint_gate.zig");
```

- [ ] **Step 2: Run the fast suite to verify it compiles + passes**

Run: `zig build test`
Expected: PASS (new tests included).

- [ ] **Step 3: Commit**

```bash
git add src/copilot_hint_gate.zig src/test_fast.zig
git commit -m "feat: pure decisions for Copilot discoverability hint"
```

---

### Task 2: `ai_sidebar.closedHandleRect` — handle geometry

**Files:**
- Modify: `src/ai_sidebar.zig` (already in the fast suite)
- Test: inline tests in `src/ai_sidebar.zig`

- [ ] **Step 1: Write the failing tests**

Append to `src/ai_sidebar.zig` (after the existing tests):

```zig
test "closedHandleRect sits at the right edge, vertically centered" {
    const r = closedHandleRect(1600, 900, 30, 0);
    try std.testing.expect(r.eligible);
    try std.testing.expectApproxEqAbs(@as(f32, 1600 - HANDLE_W), r.x, 0.001);
    try std.testing.expectApproxEqAbs(HANDLE_W, r.w, 0.001);
    try std.testing.expectApproxEqAbs(HANDLE_H, r.h, 0.001);
    // content height 870, centered: top = 30 + (870-56)/2 = 437
    try std.testing.expectApproxEqAbs(@as(f32, 437), r.y, 0.001);
}

test "closedHandleRect is ineligible when the panel cannot fit" {
    // window_w - left_offset must be >= MIN_WIDTH + MIN_CONTENT_WIDTH (640)
    const tight = closedHandleRect(600, 800, 30, 0);
    try std.testing.expect(!tight.eligible);
    const ok = closedHandleRect(700, 800, 30, 0);
    try std.testing.expect(ok.eligible);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL — `HandleRect` / `closedHandleRect` / `HANDLE_W` undefined.

- [ ] **Step 3: Implement the geometry**

In `src/ai_sidebar.zig`, after the existing constants (near line 16) add:

```zig
pub const HANDLE_W: f32 = 6;
pub const HANDLE_H: f32 = 56;
```

After the `Bounds` struct (near line 23) add:

```zig
pub const HandleRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// false when opening the panel would not fit (window too narrow); the
    /// caller suppresses the handle in that case.
    eligible: bool,
};

/// Closed-state summon-handle rect in the same top-down logical space as
/// `boundsForWindow` (y measured down from the top; `titlebar_height` is the top
/// inset). The renderer converts to GL bottom-left coords exactly the way
/// `renderAiCopilotCloseButton` does: `gl_y = window_h - (rect.y + rect.h)`.
pub fn closedHandleRect(window_w: f32, window_h: f32, titlebar_h: f32, left_offset: f32) HandleRect {
    const content_h = @max(0, window_h - titlebar_h);
    const y = titlebar_h + @max(0, (content_h - HANDLE_H) / 2);
    const x = window_w - HANDLE_W;
    const fits = (window_w - left_offset) >= (MIN_WIDTH + MIN_CONTENT_WIDTH);
    return .{ .x = x, .y = y, .w = HANDLE_W, .h = HANDLE_H, .eligible = fits };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_sidebar.zig
git commit -m "feat: closedHandleRect geometry for the Copilot summon handle"
```

---

## Phase 2 — Persisted one-time flag

### Task 3: `copilot_hint_shown` in the state codec

**Files:**
- Modify: `src/platform/window_state_codec.zig` (fast suite)
- Test: inline tests in `src/platform/window_state_codec.zig`

- [ ] **Step 1: Write the failing tests**

Append to `src/platform/window_state_codec.zig`:

```zig
test "parse reads copilot-hint-shown" {
    const s = parse("copilot-hint-shown = 1\n");
    try std.testing.expectEqual(true, s.copilot_hint_shown);
}

test "old state file without copilot-hint-shown defaults to false" {
    const s = parse("window-x = 10\nai-setup-prompted = 1\n");
    try std.testing.expectEqual(false, s.copilot_hint_shown);
}

test "copilot-hint-shown round-trips and is always written" {
    var buf: [384]u8 = undefined;
    const text = try format(&buf, .{ .copilot_hint_shown = true });
    try std.testing.expect(std.mem.indexOf(u8, text, "copilot-hint-shown = 1") != null);
    const reparsed = parse(text);
    try std.testing.expectEqual(true, reparsed.copilot_hint_shown);
}
```

Also extend the existing worst-case buffer test (`test "a full state file fits the save buffer with the bring-up marker"`) to set the new flag, so the size guard covers it. Change its `PersistedState{ ... }` initializer to include:

```zig
        .ai_setup_prompted = true,
        .copilot_hint_shown = true,
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL — `copilot_hint_shown` is not a field of `PersistedState`.

- [ ] **Step 3: Implement codec support**

In `PersistedState` (after `ai_setup_prompted: bool = false,`, line 34):

```zig
    /// Whether the one-time Copilot discoverability hint (edge-handle shimmer)
    /// has already been shown. Set the first time the handle is eligible, or as
    /// soon as the user opens Copilot by any means.
    copilot_hint_shown: bool = false,
```

In `parse`, after the `ai-setup-prompted` arm (line 90):

```zig
        } else if (std.mem.eql(u8, key, "copilot-hint-shown")) {
            state.copilot_hint_shown = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
```

In `format`, after the `ai-setup-prompted` line (line 116):

```zig
    len += (try std.fmt.bufPrint(buf[len..], "copilot-hint-shown = {d}\n", .{@intFromBool(state.copilot_hint_shown)})).len;
```

- [ ] **Step 4: Run to verify pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/platform/window_state_codec.zig
git commit -m "feat: persist copilot-hint-shown flag in the window state codec"
```

---

### Task 4: `window_state` I/O wrappers

**Files:**
- Modify: `src/platform/window_state.zig`
- Test: posix round-trip in `src/test_posix.zig` (runs under `zig build test-full` on a posix host)

- [ ] **Step 1: Write the failing test**

Add to `src/test_posix.zig` (mirror the existing window-state I/O tests; if none, add a fresh test that uses a temp HOME/config dir as those tests do). Minimal logic-level round-trip via the codec wrappers is already covered in Task 3; this test asserts the I/O wrappers compile and read back what was written:

```zig
test "copilot hint flag persists through window_state I/O" {
    const window_state = @import("platform/window_state.zig");
    const alloc = std.testing.allocator;
    // No state path in the sandbox is fine: setter is best-effort, getter
    // returns the default. This guards the wrapper signatures + compile.
    _ = window_state.copilotHintShown(alloc);
    window_state.setCopilotHintShown(alloc);
    _ = window_state.copilotHintShown(alloc);
}
```

(If `test_posix.zig` already establishes a temp config dir for window-state tests, assert the full round-trip: `setCopilotHintShown` then `copilotHintShown(alloc) == true`.)

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-full`
Expected: FAIL — `copilotHintShown` / `setCopilotHintShown` undefined.

- [ ] **Step 3: Implement wrappers**

In `src/platform/window_state.zig`, after `setAiSetupPrompted` (line 128):

```zig
/// Whether the one-time Copilot discoverability hint has already been shown.
pub fn copilotHintShown(allocator: std.mem.Allocator) bool {
    return loadPersisted(allocator).copilot_hint_shown;
}

/// Record that the Copilot hint has been shown (read-modify-write to preserve
/// geometry + other onboarding flags). No-op if already set.
pub fn setCopilotHintShown(allocator: std.mem.Allocator) void {
    var current = loadPersisted(allocator);
    if (current.copilot_hint_shown) return;
    current.copilot_hint_shown = true;
    savePersisted(allocator, current);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/platform/window_state.zig src/test_posix.zig
git commit -m "feat: window_state wrappers for the Copilot hint flag"
```

---

## Phase 3 — Config key + the edge handle (the hero)

### Task 5: `copilot-hint` config key

**Files:**
- Modify: `src/config.zig`

- [ ] **Step 1: Add the field**

In `src/config.zig`, beside the other UI bools (near `@"whats-new-on-update": bool = true,`, line 441):

```zig
@"copilot-hint": bool = true,
```

- [ ] **Step 2: Add the parse arm**

In the key-parsing chain (mirror `whats-new-on-update`, near line 1028):

```zig
    } else if (std.mem.eql(u8, key, "copilot-hint")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"copilot-hint" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"copilot-hint" = false;
        } else {
            log.warn("invalid copilot-hint: {s}", .{value});
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `zig build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add src/config.zig
git commit -m "feat: copilot-hint config key (default on)"
```

---

### Task 6: `hint_tooltip.zig` — minimal tooltip primitive

**Files:**
- Create: `src/renderer/overlays/hint_tooltip.zig`

- [ ] **Step 1: Implement the primitive**

Create `src/renderer/overlays/hint_tooltip.zig`:

```zig
//! Minimal hover-tooltip primitive: a rounded background quad + one line of
//! titlebar-glyph text. The app has no general tooltip system; this is scoped to
//! the Copilot edge handle for now and is reusable by other hover targets later.
//! Coordinates are GL bottom-left origin (the space overlays render in).
const std = @import("std");
const AppWindow = @import("../../AppWindow.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const primitives = @import("primitives.zig");

pub const Side = enum { left, right };

fn measure(text: []const u8) f32 {
    var w: f32 = 0;
    var view = std.unicode.Utf8View.init(text) catch {
        for (text) |ch| w += titlebar.titlebarGlyphAdvance(@intCast(ch));
        return w;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| w += titlebar.titlebarGlyphAdvance(cp);
    return w;
}

fn drawText(text: []const u8, x_start: f32, y: f32, color: [3]f32) void {
    var x = @round(x_start);
    const y_aligned = @round(y);
    var view = std.unicode.Utf8View.init(text) catch {
        for (text) |ch| {
            titlebar.renderTitlebarChar(@intCast(ch), x, y_aligned, color);
            x += titlebar.titlebarGlyphAdvance(@intCast(ch));
        }
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        titlebar.renderTitlebarChar(cp, x, y_aligned, color);
        x += titlebar.titlebarGlyphAdvance(cp);
    }
}

/// Draw `text` in a small rounded box whose vertical center is `anchor_y_center`,
/// placed `side` of `anchor_x`.
pub fn render(text: []const u8, anchor_x: f32, anchor_y_center: f32, side: Side, alpha: f32) void {
    if (alpha <= 0.01 or text.len == 0) return;
    const pad_x: f32 = 10;
    const pad_y: f32 = 6;
    const gap: f32 = 8;
    const text_h = @max(1.0, font.g_titlebar_cell_height);
    const text_w = measure(text);
    const box_w = text_w + pad_x * 2;
    const box_h = text_h + pad_y * 2;
    const box_x = switch (side) {
        .left => anchor_x - gap - box_w,
        .right => anchor_x + gap,
    };
    const box_y = anchor_y_center - box_h / 2;

    const bg = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, 0.10);
    const border = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.cursor_color, 0.30);
    primitives.renderRoundedQuadAlpha(box_x - 1, box_y - 1, box_w + 2, box_h + 2, 7, border, alpha * 0.5);
    primitives.renderRoundedQuadAlpha(box_x, box_y, box_w, box_h, 6, bg, alpha * 0.97);
    const fg = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, alpha);
    drawText(text, box_x + pad_x, box_y + pad_y, fg);
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `zig build`
Expected: builds clean. (Confirms `titlebar.titlebarGlyphAdvance`, `titlebar.renderTitlebarChar`, `font.g_titlebar_cell_height`, `AppWindow.g_theme.*`, and `primitives.*` resolve.)

- [ ] **Step 3: Commit**

```bash
git add src/renderer/overlays/hint_tooltip.zig
git commit -m "feat: minimal hover-tooltip primitive"
```

---

### Task 7: `copilot_edge_handle.zig` — handle renderer + shimmer

**Files:**
- Create: `src/renderer/overlays/copilot_edge_handle.zig`
- Modify: `src/renderer/overlays.zig` (re-export the render + control functions, mirroring the `startup_shortcuts` re-exports near line 50/76)

- [ ] **Step 1: Implement the renderer**

Create `src/renderer/overlays/copilot_edge_handle.zig`:

```zig
//! Closed-state Copilot "summon handle" at the terminal's right edge — the
//! universal, cross-platform affordance for the Copilot sidebar. Reveal-on-
//! proximity + hover tooltip + a one-time first-session shimmer. Structured like
//! startup_shortcuts.zig: threadlocal animation state, time-based easing.
const std = @import("std");
const AppWindow = @import("../../AppWindow.zig");
const ai_sidebar = @import("../../ai_sidebar.zig");
const keybind = @import("../../keybind.zig");
const primitives = @import("primitives.zig");
const hint_tooltip = @import("hint_tooltip.zig");

pub const REVEAL_ZONE_W: f32 = 28;
pub const REVEALED_ALPHA: f32 = 0.5;
const HOVER_ALPHA: f32 = 0.95;
const EASE_PER_MS: f32 = 0.012; // ~80ms to traverse 0->1
const TOOLTIP_DWELL_MS: i64 = 350;
const SHIMMER_MS: i64 = 700;

threadlocal var g_alpha: f32 = 0;
threadlocal var g_target: f32 = 0;
threadlocal var g_hovered: bool = false;
threadlocal var g_hover_since: i64 = 0;
threadlocal var g_last_frame_ms: i64 = 0;
threadlocal var g_shimmer_start: i64 = 0; // 0 = inactive

pub fn setProximityTarget(target: f32) void {
    g_target = target;
}

pub fn setHovered(h: bool) void {
    if (h and !g_hovered) g_hover_since = std.time.milliTimestamp();
    g_hovered = h;
}

pub fn startShimmer() void {
    g_shimmer_start = std.time.milliTimestamp();
}

fn shortcutText(buf: []u8) []const u8 {
    const binding = AppWindow.g_keybinds.firstForAction(.toggle_ai_copilot) orelse return "";
    return keybind.formatTrigger(binding.trigger, buf) catch "";
}

/// Render the closed-state handle. Caller guarantees Copilot is closed, the
/// active tab is a terminal, the feature is enabled, and no other right-docked
/// panel is open. `left_offset` is `AppWindow.leftPanelsWidth()`.
pub fn render(window_w: f32, window_h: f32, titlebar_h: f32, left_offset: f32) void {
    const now = std.time.milliTimestamp();
    const dt: f32 = if (g_last_frame_ms == 0) 0 else @floatFromInt(now - g_last_frame_ms);
    g_last_frame_ms = now;

    const rect = ai_sidebar.closedHandleRect(window_w, window_h, titlebar_h, left_offset);
    if (!rect.eligible) {
        g_alpha = 0;
        return;
    }

    const target = if (g_hovered) HOVER_ALPHA else g_target;
    const step = EASE_PER_MS * dt;
    if (g_alpha < target) {
        g_alpha = @min(target, g_alpha + step);
    } else {
        g_alpha = @max(target, g_alpha - step);
    }

    var draw_alpha = g_alpha;
    if (g_shimmer_start != 0) {
        const elapsed = now - g_shimmer_start;
        if (elapsed >= SHIMMER_MS) {
            g_shimmer_start = 0;
        } else {
            const t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(SHIMMER_MS));
            const bump = std.math.sin(t * std.math.pi); // peek up then settle
            draw_alpha = @max(draw_alpha, 0.85 * bump);
        }
    }
    if (draw_alpha <= 0.01) return;

    // top-down rect -> GL bottom-left (mirror renderAiCopilotCloseButton).
    const gl_y = window_h - (rect.y + rect.h);
    const accent = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.cursor_color, 0.6);
    const base = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, 0.35);
    const color = if (g_hovered) accent else base;
    primitives.renderRoundedQuadAlpha(rect.x, gl_y, rect.w, rect.h, rect.w / 2, color, draw_alpha);

    if (g_hovered and (now - g_hover_since) >= TOOLTIP_DWELL_MS) {
        var key_buf: [64]u8 = undefined;
        const keys = shortcutText(&key_buf);
        var label_buf: [96]u8 = undefined;
        const label = if (keys.len > 0)
            (std.fmt.bufPrint(&label_buf, "Copilot  {s}", .{keys}) catch "Copilot")
        else
            "Copilot";
        const center_y = gl_y + rect.h / 2;
        hint_tooltip.render(label, rect.x, center_y, .left, 1.0);
    }
}
```

- [ ] **Step 2: Re-export from `overlays.zig`**

In `src/renderer/overlays.zig`, beside the `startup_shortcuts` re-exports (near line 50 and 76):

```zig
pub const copilot_edge_handle = @import("overlays/copilot_edge_handle.zig");
pub const renderCopilotEdgeHandle = copilot_edge_handle.render;
pub const copilotEdgeHandleSetTarget = copilot_edge_handle.setProximityTarget;
pub const copilotEdgeHandleSetHovered = copilot_edge_handle.setHovered;
pub const copilotEdgeHandleStartShimmer = copilot_edge_handle.startShimmer;
```

- [ ] **Step 3: Build to verify it compiles**

Run: `zig build`
Expected: builds clean. (Confirms `AppWindow.g_keybinds.firstForAction`, `keybind.formatTrigger`, `ai_sidebar.closedHandleRect`.)

- [ ] **Step 4: Commit**

```bash
git add src/renderer/overlays/copilot_edge_handle.zig src/renderer/overlays.zig
git commit -m "feat: Copilot edge summon-handle renderer (reveal + shimmer)"
```

---

### Task 8: Hit-test + render wiring in input/AppWindow

**Files:**
- Modify: `src/input.zig` (hit-test, mouse-move proximity/hover, click)
- Modify: `src/AppWindow.zig` (render call sites; set flag in `toggleAiCopilot`; shimmer trigger)

- [ ] **Step 1: Add the closed-state hit-test in `input.zig`**

Near `hitTestAiCopilotResizeHandle` (the resize hit-test you already read), add:

```zig
/// Hit-test the closed-state Copilot summon handle (only valid when Copilot is
/// closed). Widens the click zone to be comfortable without a heavier visual.
fn hitTestCopilotEdgeHandle(xpos: f64, ypos: f64) bool {
    if (AppWindow.aiCopilotVisible()) return false;
    if (!AppWindow.isActiveTabTerminal()) return false;
    if (ypos < titlebarHeight()) return false;
    const win = AppWindow.g_window orelse return false;
    const fb = window_backend.framebufferSize(win);
    const rect = ai_sidebar.closedHandleRect(
        @floatFromInt(fb.width),
        @floatFromInt(fb.height),
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
    );
    if (!rect.eligible) return false;
    const hit_w: f64 = @max(@as(f64, @floatCast(rect.w)), 12);
    const right: f64 = @floatFromInt(fb.width);
    const top: f64 = @floatCast(rect.y);
    const bottom: f64 = @floatCast(rect.y + rect.h);
    return xpos >= right - hit_w and ypos >= top and ypos <= bottom;
}
```

(If `ai_sidebar` is not already imported in `input.zig`, add `const ai_sidebar = @import("ai_sidebar.zig");` with the other imports — it is referenced by `hitTestAiCopilotResizeHandle`, so it is already imported.)

- [ ] **Step 2: Update proximity/hover on mouse move**

In the mouse-move handler, near where the other resize-hover flags are recomputed (the `g_ai_copilot_resize_hover = hitTestAiCopilotResizeHandle(...)` region around line 4513–4532), add a branch for the closed state. Only act when Copilot is closed:

```zig
        if (!AppWindow.aiCopilotVisible()) {
            const enabled = if (AppWindow.g_config) |cfg| cfg.@"copilot-hint" else true;
            const eligible = enabled and AppWindow.isActiveTabTerminal() and !AppWindow.anyRightDockPanelVisible();
            if (eligible) {
                const win = AppWindow.g_window orelse return;
                const fb = window_backend.framebufferSize(win);
                const target = copilot_hint_gate.handleRevealTarget(
                    @floatCast(xpos),
                    @floatCast(ypos),
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    overlays.copilot_edge_handle.REVEAL_ZONE_W,
                    overlays.copilot_edge_handle.REVEALED_ALPHA,
                );
                overlays.copilotEdgeHandleSetTarget(target);
                overlays.copilotEdgeHandleSetHovered(hitTestCopilotEdgeHandle(xpos, ypos));
            } else {
                overlays.copilotEdgeHandleSetTarget(0);
                overlays.copilotEdgeHandleSetHovered(false);
            }
            // Animating reveal needs continuous repaints; request one.
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
```

Add imports at the top of `input.zig` if missing: `const copilot_hint_gate = @import("copilot_hint_gate.zig");` (`overlays` is already imported).

`AppWindow.g_config` and `AppWindow.anyRightDockPanelVisible()` — see Step 5 for the helper; `g_config` is the live config global (confirm its exact name in `AppWindow.zig`; if it is `g_app.config` use that form instead).

- [ ] **Step 3: Handle the click**

In the mouse-press path (where `plus_btn_pressed` / other titlebar+panel presses are handled), before terminal mouse-reporting consumes the click, add:

```zig
        if (!AppWindow.aiCopilotVisible() and hitTestCopilotEdgeHandle(xpos, ypos)) {
            AppWindow.toggleAiCopilot();
            return;
        }
```

Place it adjacent to the existing `hitTestAiCopilotResizeHandle` press branch so the two states (open=resize, closed=summon) read together.

- [ ] **Step 4: Render the handle**

In `src/AppWindow.zig`, at each site that calls `overlays.renderStartupShortcutsOverlay(...)` (there are two render paths; the one near line 8196, and its sibling), add immediately before it:

```zig
        if (!aiCopilotVisible() and isActiveTabTerminal() and !anyRightDockPanelVisible()) {
            const hint_enabled = if (g_config) |cfg| cfg.@"copilot-hint" else true;
            if (hint_enabled) {
                overlays.renderCopilotEdgeHandle(
                    @floatFromInt(fb_width),
                    @floatFromInt(fb_height),
                    titlebar_offset,
                    leftPanelsWidth(),
                );
            }
        }
```

- [ ] **Step 5: Add `anyRightDockPanelVisible` helper + set the flag in `toggleAiCopilot`**

In `src/AppWindow.zig`, add a helper next to `aiCopilotVisible`:

```zig
/// True when any right-docked panel (browser / Jupyter / preview) is showing.
/// The Copilot edge handle defers while one is up, since they share the slot.
pub fn anyRightDockPanelVisible() bool {
    return browser_panel.isVisible();
}
```

(Use the actual visibility predicate(s) for the right-dock panels. `browser_panel` covers the browser/Jupyter webview; if preview-on-right has its own visibility flag, OR it in. Grep `browser_panel.` usage in AppWindow for the exact predicate name — `toggleAiCopilot` already calls `browser_panel.close()`, so the module is imported.)

In `toggleAiCopilot()`, in the branch that *opens* Copilot (after `_ = tab.setActiveCopilotVisible(true);`), record the hint as seen so the shimmer never fires later:

```zig
    if (g_allocator) |alloc| platform_window_state.setCopilotHintShown(alloc);
```

(Use the module alias already imported for window-state I/O — grep `recordSeenVersion` / `window_state` usage in `AppWindow.zig` for the exact alias; the "What's New" path at line ~4044 already imports it.)

- [ ] **Step 6: Build + manual GUI verification**

Run: `zig build`
Expected: builds clean.

GUI check (Linux/WSL or Windows): launch app, land in a terminal; the right edge is empty at rest; moving the cursor toward the right edge fades in a slim handle; hovering it shows a `Copilot  Ctrl+Shift+A` tooltip after a beat; clicking it opens Copilot; opening Copilot turns the edge into the normal resize divider.

- [ ] **Step 7: Commit**

```bash
git add src/input.zig src/AppWindow.zig
git commit -m "feat: wire Copilot edge handle hit-test, reveal, and click"
```

---

### Task 9: One-time shimmer trigger

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Trigger the shimmer once when first eligible**

In `src/AppWindow.zig`, add a per-run guard and a check that runs once per frame in the main render/update path (near the handle render site from Task 8, Step 4):

```zig
threadlocal var g_copilot_shimmer_checked: bool = false;
```

Then, where the handle is eligible to render (inside the same `if (hint_enabled)` block, before/after `renderCopilotEdgeHandle`):

```zig
                if (!g_copilot_shimmer_checked) {
                    g_copilot_shimmer_checked = true;
                    const enabled = if (g_config) |cfg| cfg.@"copilot-hint" else true;
                    const shown = if (g_allocator) |alloc| platform_window_state.copilotHintShown(alloc) else true;
                    if (copilot_hint_gate.shimmerDecision(enabled, true, shown) == .shimmer) {
                        overlays.copilotEdgeHandleStartShimmer();
                        if (g_allocator) |alloc| platform_window_state.setCopilotHintShown(alloc);
                    }
                }
```

Add `const copilot_hint_gate = @import("copilot_hint_gate.zig");` to `AppWindow.zig` imports if not present.

Rationale: the block only runs when the handle is *eligible* (terminal tab, Copilot closed, no right-dock panel, feature on), so passing `handle_eligible = true` to `shimmerDecision` is correct; the remaining gates (`enabled`, `shown`) are evaluated explicitly. `g_copilot_shimmer_checked` ensures we test the persisted flag at most once per run.

- [ ] **Step 2: Build + GUI verification**

Run: `zig build`
Expected: builds clean.

GUI: delete the state file (or its `copilot-hint-shown` line), launch into a terminal — the handle glints once (~700ms) then settles to invisible. Relaunch — no glint (flag now persisted). Set `copilot-hint = false` in config — no glint and no handle at all.

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat: one-time first-session shimmer for the Copilot handle"
```

---

## Phase 4 — Platform-native bonuses

### Task 10: Windows/Linux titlebar Copilot icon

**Files:**
- Modify: `src/renderer/titlebar.zig` (constant + render block + fallback icon)
- Modify: `src/input.zig` (`handleTopbarPress` branch + `hitTestCopilotButton`)

- [ ] **Step 1: Add the width constant**

In `src/renderer/titlebar.zig`, beside `TITLEBAR_HELP_W` (line 35):

```zig
pub const TITLEBAR_COPILOT_W: f32 = if (builtin.os.tag == .macos) 0 else 46;
```

- [ ] **Step 2: Render the icon left of help**

In the titlebar render region, the help button is positioned at `help_x = config_x - TITLEBAR_HELP_W` (the block you read near lines 464–482). Add a Copilot button to its left. After the help block, add:

```zig
        const copilot_x = help_x - TITLEBAR_COPILOT_W;
        if (TITLEBAR_COPILOT_W > 0) {
            const copilot_open = AppWindow.aiCopilotVisible();
            const copilot_usable = AppWindow.isActiveTabTerminal();
            const copilot_hovered = mouseInTitlebarRange(titlebar_h, copilot_x, copilot_x + TITLEBAR_COPILOT_W);
            if (copilot_hovered and copilot_usable) {
                gl_init.renderQuad(copilot_x, tb_top, TITLEBAR_COPILOT_W, titlebar_h, hover_bg);
            }
            const tint = if (!copilot_usable)
                blend(bg, fg, 0.30) // dimmed: no terminal target
            else if (copilot_open)
                blend(bg, AppWindow.g_theme.cursor_color, 0.85) // active
            else
                icon_color;
            renderFallbackCopilotIcon(copilot_x, tb_top, TITLEBAR_COPILOT_W, titlebar_h, tint);
        }
```

Then change the title-text right clamp from `help_x` to `copilot_x` (line ~487):

```zig
            _ = renderTextLimited(title, text_x, text_y, blend(bg, fg, 0.90), copilot_x - text_x - 12);
```

(`blend` is the local color helper used in this file; `icon_color`, `hover_bg`, `tb_top`, `bg`, `fg` are already in scope in this block.)

- [ ] **Step 3: Add the fallback vector icon**

Beside `renderFallbackHelpIcon` / `renderFallbackGearIcon`, add a simple chat-bubble glyph. Mirror their structure (the existing fallbacks draw with `gl_init.renderQuad` / rounded primitives inside the button rect). Concretely:

```zig
/// A minimal chat-bubble icon (rounded body + a small tail), centered in the
/// button rect. Vector so it is font-independent, matching the help/gear
/// fallbacks' approach.
fn renderFallbackCopilotIcon(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    const size = @min(w, h) * 0.42;
    const cx = x + (w - size) / 2;
    const cy = y + (h - size) / 2 + size * 0.08;
    renderRoundedQuadAlpha(cx, cy, size, size * 0.78, size * 0.22, color, 1.0);
    // tail
    gl_init.renderQuad(cx + size * 0.18, cy - size * 0.16, size * 0.18, size * 0.20, color);
}
```

(If `renderRoundedQuadAlpha` is not already imported in `titlebar.zig`, the help/gear fallbacks show the available primitives — use whatever they use; the exact shape is cosmetic and will be tuned in GUI review.)

- [ ] **Step 4: Hit-test the icon in `input.zig`**

Add the hit-test (mirror `hitTestHelpButton`/`hitTestConfigButton`):

```zig
fn hitTestCopilotButton(xpos: f64, ypos: f64) bool {
    if (titlebar.TITLEBAR_COPILOT_W <= 0) return false;
    _ = ypos;
    const caption_w: f64 = @floatCast(window_backend.caption_button_visual_style.width);
    const win = AppWindow.g_window orelse return false;
    const fb = window_backend.framebufferSize(win);
    const window_width: f64 = @floatFromInt(fb.width);
    const caption_start = window_width - caption_w * 3;
    const config_x = caption_start - @as(f64, @floatCast(titlebar.TITLEBAR_CONFIG_W));
    const help_x = config_x - @as(f64, @floatCast(titlebar.TITLEBAR_HELP_W));
    const copilot_x = help_x - @as(f64, @floatCast(titlebar.TITLEBAR_COPILOT_W));
    return xpos >= copilot_x and xpos < help_x;
}
```

(Match the exact x-math the existing `hitTestHelpButton`/`hitTestConfigButton` use — read those two and mirror their convention precisely rather than the sketch above if they differ.)

In `handleTopbarPress`, before the help-button branch:

```zig
    if (hitTestCopilotButton(xpos, titlebarHeight() / 2)) {
        AppWindow.toggleAiCopilot();
        return;
    }
```

- [ ] **Step 5: Build + GUI verification (Windows/Linux)**

Run: `zig build`
Expected: builds clean. On macOS the constant is 0, so nothing renders and the title clamp falls back to `help_x` math being equivalent (`copilot_x == help_x` when width is 0).

GUI (Windows/Linux): a Copilot icon appears left of `?`; click toggles Copilot; it tints "active" when Copilot is open and dims on non-terminal tabs.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/titlebar.zig src/input.zig
git commit -m "feat: Windows/Linux titlebar Copilot icon"
```

---

### Task 11: macOS native View-menu item

**Files:**
- Modify: `src/platform/menu_macos.zig`

- [ ] **Step 1: Add the menu item + id mapping**

In `src/platform/menu_macos.zig`, View submenu, after `Toggle Tab Sidebar` (the line you read near 117):

```zig
    wispterm_macos_menu_add_item("Toggle Copilot", id(.toggle_ai_copilot), "a", ModCtrl | ModShift);
```

Then add the `toggle_ai_copilot` arm to both `id()` and `actionFromId` (mirror the existing `toggle_sidebar` arms in each switch). Extend the round-trip test at the bottom of the file to include `toggle_ai_copilot`.

- [ ] **Step 2: Verify (macOS host) / build elsewhere**

On a macOS host: `zig build test-macos-menu` → PASS.
Elsewhere: `zig build` → builds clean (the menu module is macOS-gated; this confirms no cross-platform breakage).

- [ ] **Step 3: Commit**

```bash
git add src/platform/menu_macos.zig
git commit -m "feat: macOS View menu Toggle Copilot item"
```

---

## Phase 5 — Reference surfaces

### Task 12: Command-center "Toggle Copilot" entry

**Files:**
- Modify: `src/command_center_state.zig` (enum + entry + test)
- Modify: `src/renderer/overlays.zig` (`executeCommand` arm)
- Modify: `src/i18n.zig` (zh title/detail arms)

- [ ] **Step 1: Write the failing test**

In `src/command_center_state.zig`, beside the existing `findCommandAction` tests (near line 288):

```zig
test "command center exposes Toggle Copilot" {
    try std.testing.expectEqual(CommandAction.toggle_ai_copilot, findCommandAction("Toggle Copilot"));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL — `toggle_ai_copilot` not a `CommandAction`, and no entry named "Toggle Copilot".

- [ ] **Step 3: Add the enum variant + entry**

In the `CommandAction` enum (near line 5), add:

```zig
    toggle_ai_copilot,
```

In `command_entries` (after the `New Copilot` row, line 59):

```zig
    .{ .title = "Toggle Copilot", .detail = "Open or close the Copilot sidebar on the current terminal", .shortcut = "", .action = .toggle_ai_copilot },
```

- [ ] **Step 4: Add the dispatch arm**

In `src/renderer/overlays.zig`, `executeCommand` switch (line 542), add:

```zig
        .toggle_ai_copilot => AppWindow.toggleAiCopilot(),
```

- [ ] **Step 5: Add zh strings (exhaustive switches)**

In `src/i18n.zig`, add arms to the CommandAction title switch (near line 714) and detail switch (near line 765):

```zig
        .toggle_ai_copilot => "开 / 关 Copilot",
```
```zig
        .toggle_ai_copilot => "在当前终端上打开或关闭 Copilot 侧栏",
```

- [ ] **Step 6: Run to verify pass + build**

Run: `zig build test` then `zig build`
Expected: both PASS / clean. (The exhaustive i18n switches force the zh arms to exist.)

- [ ] **Step 7: Commit**

```bash
git add src/command_center_state.zig src/renderer/overlays.zig src/i18n.zig
git commit -m "feat: Toggle Copilot command-center entry"
```

---

### Task 13: Shortcuts-overlay reference entry

**Files:**
- Modify: `src/renderer/overlays/startup_shortcuts.zig`

- [ ] **Step 1: Add the entry**

In `STARTUP_SHORTCUT_ENTRIES` (the array near line 53), add, after the sidebar entry:

```zig
    .{ .keys = "Ctrl+Shift+A", .kind = .action, .first = .toggle_ai_copilot, .action = "Toggle Copilot", .action_zh = "开 / 关 Copilot" },
```

(`.action` entries derive their displayed keys from the live keybind, so the `keys` literal is only a fallback; matching the actual binding keeps it correct.)

- [ ] **Step 2: Build + GUI verification**

Run: `zig build`
Expected: clean. GUI: the startup overlay (and the `?` button on Win/Linux) now lists "Toggle Copilot — Ctrl/Cmd+Shift+A".

- [ ] **Step 3: Commit**

```bash
git add src/renderer/overlays/startup_shortcuts.zig
git commit -m "feat: list Toggle Copilot in the shortcuts overlay"
```

---

## Phase 6 — Final verification

### Task 14: Full-suite + cross-compile + GUI pass

- [ ] **Step 1: Fast + full suites**

Run: `zig build test && zig build test-full`
Expected: both green.

- [ ] **Step 2: Windows cross-compile** (this project ships Windows; verify no break)

Run: `zig build -Dtarget=x86_64-windows-gnu`
Expected: builds clean.

- [ ] **Step 3: GUI smoke (record results in the PR)**
  - Resting terminal: right edge empty.
  - Cursor → right edge: handle fades in; hover → tooltip with the live shortcut; click → Copilot opens; open state → resize divider works.
  - Fresh install (cleared flag): one-time shimmer; relaunch → none.
  - `copilot-hint = false`: no handle, no shimmer.
  - Win/Linux titlebar icon: present, click toggles, active/dim states.
  - macOS: no titlebar icon; View ▸ Toggle Copilot works; edge handle works.
  - Command center + shortcuts overlay both list Toggle Copilot.

- [ ] **Step 4: Final commit (if any GUI-driven tuning)**

```bash
git add -A
git commit -m "chore: tune Copilot discoverability handle after GUI review"
```

---

## Self-Review Notes

- **Spec coverage:** edge handle (Tasks 6–8), shimmer + gate (Tasks 1, 9), persistence flag (Tasks 3–4), titlebar icon kept on Win/Linux (Task 10), macOS menu (Task 11), command center + overlay reference surfaces (Tasks 12–13), config `copilot-hint` (Task 5), right-dock exclusivity gating (Task 8 helper). All spec sections map to a task.
- **Type consistency:** `closedHandleRect`/`HandleRect`/`HANDLE_W`/`HANDLE_H` (Task 2) are consumed unchanged in Tasks 7–8. `copilot_hint_shown` field (Task 3) is read/written by the exact wrappers in Task 4 and used in Tasks 8–9. `toggle_ai_copilot` is a pre-existing `keybind.Action` and `command_dispatch.Command`; this plan adds it only as a `command_center_state.CommandAction` (Task 12) and a macOS menu id (Task 11).
- **Known integration-verified-by-build/GUI steps:** the GL renderer, input wiring, and titlebar icon (Tasks 7–11) are verified by `zig build` + the GUI checklist rather than unit tests, because they touch the window/GL shell. All decision/geometry/persistence logic they depend on is unit-tested in Phases 1–2. Where exact in-file x-math or module aliases must match existing code (titlebar hit-tests, `g_config`/window-state alias, right-dock predicate), the step says to read the named sibling and mirror it — do that rather than assuming the sketch is byte-exact.
