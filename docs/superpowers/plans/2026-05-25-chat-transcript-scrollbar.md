# Chat Transcript Scrollbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a right-edge scrollbar to the AI Chat transcript that behaves like the terminal's — appears on scroll, fades after 0.8s, stays visible on hover, and is draggable.

**Architecture:** Put the pure geometry/drag/fade math in a new dependency-free module (`src/ai_chat_scrollbar_model.zig`) so it is unit-testable (mirrors how the terminal extracted `src/scrollbar_model.zig`). The GL-importing renderer (`src/renderer/ai_chat_renderer.zig`) calls into it to draw and to hit-test; `src/input.zig` wires up mouse drag/hover; `src/ai_chat.zig` gains one timestamp field plus a `scrollToPx` helper. The transcript already scrolls via `Session.scroll_px` — this only adds the visible/draggable affordance.

**Tech Stack:** Zig, OpenGL quad rendering (`gl_init.renderQuadAlpha`), existing Phantty AI-chat renderer/input patterns.

---

## Scroll model reference (read before starting)

- `Session.scroll_px`: `0` = top of conversation (oldest) visible; larger = scrolled toward bottom (newest). Render clamps it to `max_scroll = content_h - transcript_h`. The sentinel `1_000_000` means "pin to bottom".
- Thumb fraction `f = scroll_px / max_scroll` ∈ [0,1]; `f = 0` → thumb at track top, `f = 1` → thumb at track bottom.
- Coordinate systems: mouse positions and the renderer's `*_top_px` values use **top-left origin** (y grows downward). `gl_init.renderQuadAlpha` uses **GL origin** (y grows upward), so the renderer converts with `gl_y = window_height - top_px - h`. The existing `stopButtonRect`/`renderStopButton` pair shows this convention.

## File Structure

- **Create** `src/ai_chat_scrollbar_model.zig` — pure math: `Geometry`, `geometry()`, `hitTrack()`, `thumbDragOffset()`, `scrollPxAt()`, `fadeOpacity()`, constants, and tests. No GL/platform imports.
- **Modify** `src/test_main.zig` — register the new module so its tests are part of the suite.
- **Modify** `src/ai_chat.zig` — add `scrollbar_show_time` field; stamp it in `scrollBy`; add `scrollToPx`.
- **Modify** `src/renderer/ai_chat_renderer.zig` — import the model; add hover/drag threadlocal flags; add `renderTranscriptScrollbar` (called from `render`), `transcriptScrollbarHitTest`, `transcriptScrollbarScrollPxAt`, and a private `transcriptLayoutLocked` helper.
- **Modify** `src/input.zig` — add drag-state globals; mouse-down hit-test branch; `applyAiTranscriptScrollbarDrag`; mouse-move drag + hover handling; mouse-up + reset clearing.

---

## Task 1: Pure scrollbar model module

**Files:**
- Create: `src/ai_chat_scrollbar_model.zig`
- Modify: `src/test_main.zig` (comptime import block ending at line ~671)

- [ ] **Step 1: Create the module with types, constants, and stubbed functions**

Create `src/ai_chat_scrollbar_model.zig`:

```zig
//! Pure geometry / drag / fade math for the AI Chat transcript scrollbar.
//!
//! No GL or platform imports so it can be unit-tested in test_main.zig
//! (mirrors src/scrollbar_model.zig, which the terminal scrollbar extracted
//! for the same reason — src/renderer/ai_chat_renderer.zig @cImports OpenGL
//! and is not part of the test build).

const std = @import("std");

pub const WIDTH: f32 = 12; // Track/thumb width in px
pub const MIN_THUMB: f32 = 20; // Minimum thumb height in px
pub const HIT_PAD: f32 = 4; // Extra hit area on each side of the track
pub const FADE_DELAY_MS: i64 = 800; // Fully visible before fading
pub const FADE_DURATION_MS: i64 = 400; // Fade-out animation length

/// Resolved scrollbar geometry. All `*_px` values use top-left origin.
pub const Geometry = struct {
    track_x: f32,
    track_top_px: f32,
    track_h: f32,
    thumb_top_px: f32,
    thumb_h: f32,
    max_scroll: f32,
};

/// Compute geometry for the transcript scrollbar.
/// `x`/`w` are the transcript panel's left edge and width; `transcript_top`
/// is the top of the transcript area (top-left px); `transcript_h` the visible
/// height; `content_h` the total content height; `scroll_px` the current scroll.
/// Returns null when the content fits (no overflow → no scrollbar).
pub fn geometry(x: f32, w: f32, transcript_top: f32, transcript_h: f32, content_h: f32, scroll_px: f32) ?Geometry {
    _ = x;
    _ = w;
    _ = transcript_top;
    _ = transcript_h;
    _ = content_h;
    _ = scroll_px;
    return null;
}

/// True when a point (top-left px) is over the track (including HIT_PAD).
pub fn hitTrack(geo: Geometry, px: f32, py: f32) bool {
    _ = geo;
    _ = px;
    _ = py;
    return false;
}

/// Drag offset within the thumb for a press at `py`. If the press is on the
/// thumb, returns `py - thumb_top_px`; if on the bare track, centers the thumb.
pub fn thumbDragOffset(geo: Geometry, py: f32) f32 {
    _ = geo;
    _ = py;
    return 0;
}

/// Map a pointer y (top-left px) plus drag offset to a target scroll_px.
pub fn scrollPxAt(geo: Geometry, py: f32, drag_offset: f32) f32 {
    _ = geo;
    _ = py;
    _ = drag_offset;
    return 0;
}

/// Fade opacity for the scrollbar. `held` is true while hovering or dragging.
/// `show_time` is the last time the bar was shown (ms); 0 means never shown.
pub fn fadeOpacity(show_time: i64, now: i64, held: bool) f32 {
    _ = show_time;
    _ = now;
    _ = held;
    return 0;
}
```

- [ ] **Step 2: Add the failing tests to the same module**

Append to `src/ai_chat_scrollbar_model.zig`:

```zig
test "geometry returns null when content fits" {
    try std.testing.expect(geometry(0, 400, 100, 200, 150, 0) == null);
    try std.testing.expect(geometry(0, 400, 100, 200, 200, 0) == null);
}

test "geometry thumb is proportional and clamps to MIN_THUMB" {
    const geo = geometry(0, 400, 100, 200, 400, 0).?;
    try std.testing.expectEqual(@as(f32, 388), geo.track_x); // round(0+400-12)
    try std.testing.expectEqual(@as(f32, 200), geo.track_h);
    try std.testing.expectEqual(@as(f32, 100), geo.thumb_h); // 200 * (200/400)
    try std.testing.expectEqual(@as(f32, 200), geo.max_scroll);

    // Tiny visible ratio still respects MIN_THUMB.
    const small = geometry(0, 400, 100, 10, 4000, 0).?;
    try std.testing.expectEqual(@as(f32, MIN_THUMB), small.thumb_h);
}

test "geometry thumb position tracks scroll_px" {
    const top = geometry(0, 400, 100, 200, 400, 0).?;
    try std.testing.expectEqual(@as(f32, 100), top.thumb_top_px); // at track top

    const bottom = geometry(0, 400, 100, 200, 400, 200).?;
    try std.testing.expectEqual(@as(f32, 200), bottom.thumb_top_px); // track_top + (track_h - thumb_h)

    const mid = geometry(0, 400, 100, 200, 400, 100).?;
    try std.testing.expectEqual(@as(f32, 150), mid.thumb_top_px);
}

test "hitTrack respects width, pad, and vertical bounds" {
    const geo = geometry(0, 400, 100, 200, 400, 0).?; // track_x=388, track 100..300
    try std.testing.expect(hitTrack(geo, 390, 150));
    try std.testing.expect(hitTrack(geo, 385, 150)); // within HIT_PAD on the left
    try std.testing.expect(!hitTrack(geo, 350, 150)); // too far left
    try std.testing.expect(!hitTrack(geo, 390, 90)); // above track
    try std.testing.expect(!hitTrack(geo, 390, 320)); // below track
}

test "thumbDragOffset uses press position on thumb, centers on bare track" {
    const geo = geometry(0, 400, 100, 200, 400, 0).?; // thumb 100..200, thumb_h=100
    try std.testing.expectEqual(@as(f32, 20), thumbDragOffset(geo, 120));
    try std.testing.expectEqual(@as(f32, 50), thumbDragOffset(geo, 250)); // thumb_h/2
}

test "scrollPxAt round-trips track extremes" {
    const geo = geometry(0, 400, 100, 200, 400, 0).?; // usable = 100, max_scroll=200
    try std.testing.expectEqual(@as(f32, 0), scrollPxAt(geo, 100, 0)); // drag to top
    try std.testing.expectEqual(@as(f32, 200), scrollPxAt(geo, 200, 0)); // drag to bottom
    try std.testing.expectEqual(@as(f32, 100), scrollPxAt(geo, 150, 0)); // middle
}

test "fadeOpacity: held, never-shown, full, mid-fade, gone" {
    try std.testing.expectEqual(@as(f32, 1.0), fadeOpacity(0, 5000, true)); // held overrides
    try std.testing.expectEqual(@as(f32, 0), fadeOpacity(0, 5000, false)); // never shown
    try std.testing.expectEqual(@as(f32, 1.0), fadeOpacity(1000, 1500, false)); // within delay
    try std.testing.expectEqual(@as(f32, 0.5), fadeOpacity(1000, 2000, false)); // halfway through fade
    try std.testing.expectEqual(@as(f32, 0), fadeOpacity(1000, 3000, false)); // fully faded
}
```

- [ ] **Step 3: Register the module in the test suite**

In `src/test_main.zig`, inside the `comptime { ... }` block (it currently ends near line 671 with `_ = @import("updater_core.zig");`), add next to the other model imports — after the `scrollbar_model.zig` line (~662):

```zig
    _ = @import("ai_chat_scrollbar_model.zig");
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `zig test src/ai_chat_scrollbar_model.zig`

(This module imports only `std`, so it compiles and runs natively even though the project's default target is Windows.)

Expected: FAIL — e.g. `expected 388, found 0` (stubs return zero/null/false).

- [ ] **Step 5: Implement the function bodies**

Replace the five stub bodies in `src/ai_chat_scrollbar_model.zig`:

```zig
pub fn geometry(x: f32, w: f32, transcript_top: f32, transcript_h: f32, content_h: f32, scroll_px: f32) ?Geometry {
    if (transcript_h <= 0 or content_h <= transcript_h) return null;
    const max_scroll = content_h - transcript_h;
    const track_x = @round(x + w - WIDTH);
    const track_top_px = @round(transcript_top);
    const track_h = @round(@max(1.0, transcript_h));
    const visible_ratio = transcript_h / content_h;
    const thumb_h = @round(@min(track_h, @max(MIN_THUMB, track_h * visible_ratio)));
    const frac = std.math.clamp(scroll_px / max_scroll, 0.0, 1.0);
    const thumb_top_px = @round(track_top_px + frac * (track_h - thumb_h));
    return .{
        .track_x = track_x,
        .track_top_px = track_top_px,
        .track_h = track_h,
        .thumb_top_px = thumb_top_px,
        .thumb_h = thumb_h,
        .max_scroll = max_scroll,
    };
}

pub fn hitTrack(geo: Geometry, px: f32, py: f32) bool {
    return px >= geo.track_x - HIT_PAD and px <= geo.track_x + WIDTH + HIT_PAD and
        py >= geo.track_top_px and py <= geo.track_top_px + geo.track_h;
}

pub fn thumbDragOffset(geo: Geometry, py: f32) f32 {
    if (py >= geo.thumb_top_px and py <= geo.thumb_top_px + geo.thumb_h) return py - geo.thumb_top_px;
    return geo.thumb_h / 2.0;
}

pub fn scrollPxAt(geo: Geometry, py: f32, drag_offset: f32) f32 {
    const usable = @max(1.0, geo.track_h - geo.thumb_h);
    const frac = std.math.clamp((py - geo.track_top_px - drag_offset) / usable, 0.0, 1.0);
    return frac * geo.max_scroll;
}

pub fn fadeOpacity(show_time: i64, now: i64, held: bool) f32 {
    if (held) return 1.0;
    if (show_time <= 0) return 0;
    const elapsed = now - show_time;
    if (elapsed < FADE_DELAY_MS) return 1.0;
    const fade_elapsed = elapsed - FADE_DELAY_MS;
    if (fade_elapsed >= FADE_DURATION_MS) return 0;
    return 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(FADE_DURATION_MS));
}
```

Remove the now-unused `_ = ...;` discard lines from each function.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig test src/ai_chat_scrollbar_model.zig`
Expected: PASS — `All N tests passed.`

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat_scrollbar_model.zig src/test_main.zig
git commit -m "Add pure transcript scrollbar geometry/fade model"
```

---

## Task 2: Session field + scroll helpers

**Files:**
- Modify: `src/ai_chat.zig` (field near line 875; `scrollBy` at line 1698)

- [ ] **Step 1: Add the show-time field to `Session`**

In `src/ai_chat.zig`, find `scroll_px: f32 = 0,` (line 875) and add directly below it:

```zig
    scroll_px: f32 = 0,
    scrollbar_show_time: i64 = 0,
```

- [ ] **Step 2: Stamp the show time in `scrollBy`**

Replace `scrollBy` (lines 1698-1702):

```zig
    pub fn scrollBy(self: *Session, delta_px: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scroll_px = @max(0.0, self.scroll_px + delta_px);
        self.scrollbar_show_time = std.time.milliTimestamp();
    }
```

- [ ] **Step 3: Add `scrollToPx` for drag**

Immediately after `scrollBy`, add:

```zig
    pub fn scrollToPx(self: *Session, px: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scroll_px = @max(0.0, px);
        self.scrollbar_show_time = std.time.milliTimestamp();
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `zig build`
Expected: builds with no errors (cross-compiles to the default Windows target).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "Track scrollbar show-time and add scrollToPx to chat Session"
```

---

## Task 3: Renderer — draw + hit-test

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig` (imports ~line 6; `render` body ~245-322; helpers added near the input-scrollbar helpers ~847)

- [ ] **Step 1: Import the model and declare hover/drag flags**

In `src/renderer/ai_chat_renderer.zig`, after the existing import block (the `composer_layout` import is line 6), add:

```zig
const scrollbar_model = @import("../ai_chat_scrollbar_model.zig");
```

Then, just below the import lines (before the `const c = @cImport(...)` block at line 11), add the global interaction flags (only one mouse, like `overlays/scrollbar.zig`):

```zig
// Transcript scrollbar interaction state (one mouse). Set by input.zig,
// read by the fade computation in renderTranscriptScrollbar.
pub threadlocal var g_transcript_scrollbar_hover: bool = false;
pub threadlocal var g_transcript_scrollbar_dragging: bool = false;
```

- [ ] **Step 2: Call the render helper from `render`**

In `render`, the transcript scissor is disabled at line 317 (`gl.Disable.?(c.GL_SCISSOR_TEST);`) just before the `if (approval) |view|` block. Insert the call right after that `gl.Disable` line and before `if (approval) |view| {`:

```zig
    gl.Disable.?(c.GL_SCISSOR_TEST);

    renderTranscriptScrollbar(session, x, w, transcript_top, transcript_h, content_h, window_height);

    if (approval) |view| {
```

(`session`, `x`, `w`, `transcript_top`, `transcript_h`, `content_h`, and `window_height` are all in scope here, and `render` holds `session.mutex` for the whole function.)

- [ ] **Step 3: Add the render helper**

Add this function immediately after `renderInputScrollbar` (which ends at line 858):

```zig
fn renderTranscriptScrollbar(
    session: *ai_chat.Session,
    x: f32,
    w: f32,
    transcript_top: f32,
    transcript_h: f32,
    content_h: f32,
    window_height: f32,
) void {
    const geo = scrollbar_model.geometry(x, w, transcript_top, transcript_h, content_h, session.scroll_px) orelse return;

    const held = g_transcript_scrollbar_hover or g_transcript_scrollbar_dragging;
    const opacity = scrollbar_model.fadeOpacity(session.scrollbar_show_time, std.time.milliTimestamp(), held);
    if (opacity <= 0.01) return;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const track_y = window_height - geo.track_top_px - geo.track_h;
    const thumb_y = window_height - geo.thumb_top_px - geo.thumb_h;

    gl_init.renderQuadAlpha(geo.track_x, track_y, scrollbar_model.WIDTH, geo.track_h, mixColor(bg, fg, 0.18), opacity * 0.20);
    gl_init.renderQuadAlpha(geo.track_x, thumb_y, scrollbar_model.WIDTH, geo.thumb_h, mixColor(bg, fg, 0.46), opacity * 0.62);
}
```

- [ ] **Step 4: Add a shared layout helper for hit-testing**

`render` and `interactionHitTest` both compute the transcript layout inline. Add a small locked helper (caller must already hold `session.mutex`) right before `transcriptScrollbarHitTest` (added in the next step). Place both new public functions immediately after `inputScrollbarDragRowAt` (which ends at line 614):

```zig
const TranscriptLayout = struct {
    x: f32,
    w: f32,
    transcript_top: f32,
    transcript_h: f32,
    content_h: f32,
};

fn transcriptLayoutLocked(
    session: *ai_chat.Session,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) ?TranscriptLayout {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    if (w <= 1) return null;

    const approval = session.approvalView();
    const approval_h: f32 = if (approval != null) APPROVAL_H + APPROVAL_GAP else 0;
    const input_h = inputLayout(x, w, session.input()).input_h;
    const transcript_top = titlebar_offset + HEADER_H + 18;
    const transcript_bottom = input_h + approval_h + 18;
    const transcript_h = @max(1.0, window_height - transcript_top - transcript_bottom);
    const content_w = w - LINE_PAD_X * 2;

    var content_h: f32 = 0;
    for (session.messages.items) |msg| {
        content_h += messageBlockHeight(msg, content_w);
        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) content_h += reasoningCardHeight(msg, content_w);
        }
        if (msg.usage_footer) |footer| {
            if (footer.len > 0) content_h += usageFooterHeight(footer, content_w);
        }
        content_h += BUBBLE_GAP;
    }

    return .{
        .x = x,
        .w = w,
        .transcript_top = transcript_top,
        .transcript_h = transcript_h,
        .content_h = content_h,
    };
}
```

- [ ] **Step 5: Add the public hit-test and drag-target functions**

Directly after `transcriptLayoutLocked`, add:

```zig
/// Returns the drag offset within the thumb if (xpos, ypos) is over the
/// transcript scrollbar track, else null.
pub fn transcriptScrollbarHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) ?f32 {
    session.mutex.lock();
    const layout = transcriptLayoutLocked(session, window_width, window_height, titlebar_offset, left_panels_w, right_panels_w);
    const scroll_px = session.scroll_px;
    session.mutex.unlock();

    const l = layout orelse return null;
    const geo = scrollbar_model.geometry(l.x, l.w, l.transcript_top, l.transcript_h, l.content_h, scroll_px) orelse return null;
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    if (!scrollbar_model.hitTrack(geo, px, py)) return null;
    return scrollbar_model.thumbDragOffset(geo, py);
}

/// Maps a pointer y to a target scroll_px for the transcript scrollbar.
pub fn transcriptScrollbarScrollPxAt(
    session: *ai_chat.Session,
    ypos: f64,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
    drag_offset: f32,
) ?f32 {
    session.mutex.lock();
    const layout = transcriptLayoutLocked(session, window_width, window_height, titlebar_offset, left_panels_w, right_panels_w);
    const scroll_px = session.scroll_px;
    session.mutex.unlock();

    const l = layout orelse return null;
    const geo = scrollbar_model.geometry(l.x, l.w, l.transcript_top, l.transcript_h, l.content_h, scroll_px) orelse return null;
    return scrollbar_model.scrollPxAt(geo, @floatCast(ypos), drag_offset);
}
```

- [ ] **Step 6: Verify it compiles**

Run: `zig build`
Expected: builds with no errors.

- [ ] **Step 7: Commit**

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "Render and hit-test the chat transcript scrollbar"
```

---

## Task 4: Input — drag and hover wiring

**Files:**
- Modify: `src/input.zig` (globals ~208; reset ~325; mouse-up ~2708; mouse-down ~2548; helpers ~2928; mouse-move ~2972)

- [ ] **Step 1: Add drag-state globals**

In `src/input.zig`, after `threadlocal var g_ai_input_scroll_drag_offset: f32 = 0;` (line 208), add:

```zig
threadlocal var g_ai_transcript_scroll_dragging: bool = false;
threadlocal var g_ai_transcript_scroll_chat: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_transcript_scroll_drag_offset: f32 = 0;
```

- [ ] **Step 2: Clear drag state in the input reset**

In the reset block, after `g_ai_input_scroll_chat = null;` (line 326), add:

```zig
    g_ai_transcript_scroll_dragging = false;
    g_ai_transcript_scroll_chat = null;
    AppWindow.ai_chat_renderer.g_transcript_scrollbar_dragging = false;
    AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover = false;
```

- [ ] **Step 3: Clear drag state on mouse-up**

In the mouse-up branch, after `g_ai_input_scroll_chat = null;` (line 2709), add:

```zig
            g_ai_transcript_scroll_dragging = false;
            g_ai_transcript_scroll_chat = null;
            AppWindow.ai_chat_renderer.g_transcript_scrollbar_dragging = false;
```

- [ ] **Step 4: Add the mouse-down hit-test branch**

In the AI-chat mouse-down dispatch, insert a new branch *after* the `permissionChipHitTest` block (which ends at line 2548 with its `return;` and `}`) and *before* the `if (!ev.ctrl and !ev.alt) {` transcript-text-selection block at line 2549. Ordering matters: the scrollbar sits on the right edge of the transcript, so it must claim the click before text selection.

```zig
                if (AppWindow.ai_chat_renderer.transcriptScrollbarHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatFromInt(fb.height),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    AppWindow.rightPanelsWidthForWindow(fb.width),
                )) |drag_offset| {
                    g_ai_transcript_scroll_dragging = true;
                    g_ai_transcript_scroll_chat = chat;
                    g_ai_transcript_scroll_drag_offset = drag_offset;
                    AppWindow.ai_chat_renderer.g_transcript_scrollbar_dragging = true;
                    applyAiTranscriptScrollbarDrag(chat, ypos);
                    AppWindow.g_force_rebuild = true;
                    AppWindow.g_cells_valid = false;
                    return;
                }
```

- [ ] **Step 5: Add the drag-apply helper**

Add this function immediately after `applyAiInputScrollbarDrag` (which ends at line 2928):

```zig
fn applyAiTranscriptScrollbarDrag(chat: *AppWindow.ai_chat.Session, ypos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    if (AppWindow.ai_chat_renderer.transcriptScrollbarScrollPxAt(
        chat,
        ypos,
        @floatFromInt(size.width),
        @floatFromInt(size.height),
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        AppWindow.rightPanelsWidthForWindow(size.width),
        g_ai_transcript_scroll_drag_offset,
    )) |px| {
        chat.scrollToPx(px);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }
}
```

- [ ] **Step 6: Handle drag + hover in `handleMouseMove`**

In `handleMouseMove`, after the input-scrollbar drag branch (lines 2972-2975), add the transcript drag branch:

```zig
    if (g_ai_transcript_scroll_dragging) {
        if (g_ai_transcript_scroll_chat) |chat| applyAiTranscriptScrollbarDrag(chat, ypos);
        return;
    }
```

Then, just before `if (updateSidebarTabDrag(xpos, ypos)) return;` (line 2993), add hover tracking (no early return — it falls through to the existing cursor/hover logic):

```zig
    if (AppWindow.g_window) |hover_win| {
        if (AppWindow.activeAiChat()) |chat| {
            const hover_fb = window_backend.framebufferSize(hover_win);
            const over = AppWindow.ai_chat_renderer.transcriptScrollbarHitTest(
                chat,
                xpos,
                ypos,
                @floatFromInt(hover_fb.width),
                @floatFromInt(hover_fb.height),
                @floatCast(titlebarHeight()),
                AppWindow.leftPanelsWidth(),
                AppWindow.rightPanelsWidthForWindow(hover_fb.width),
            ) != null;
            if (over != AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover) {
                AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover = over;
                AppWindow.g_force_rebuild = true;
            }
        } else if (AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover) {
            AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover = false;
            AppWindow.g_force_rebuild = true;
        }
    }
```

- [ ] **Step 7: Verify it compiles**

Run: `zig build`
Expected: builds with no errors.

- [ ] **Step 8: Run the full test suite**

Run: `zig build test`
Expected: PASS (or, if the host skips foreign-target test execution, the build/compile step succeeds; the model assertions were already verified natively in Task 1 via `zig test src/ai_chat_scrollbar_model.zig`).

- [ ] **Step 9: Commit**

```bash
git add src/input.zig
git commit -m "Wire transcript scrollbar drag and hover into input"
```

---

## Task 5: Manual verification on Windows

The app runs on Windows (the renderer uses Win32/WebView2); cross-compiling on the WSL host produces the artifact but cannot run it there. Verify behavior in the running app.

- [ ] **Step 1: Build and launch the app, open an AI Chat tab with a long conversation** (enough messages that the transcript overflows).

- [ ] **Step 2: Verify appearance on scroll**

Scroll the transcript with the mouse wheel. Expected: a thin scrollbar appears at the right edge of the transcript area, the thumb height is proportional to the visible fraction, and it position-tracks the scroll. After ~0.8s without interaction it fades out over ~0.4s.

If the bar appears but does not *fade* (stays until the next event), the redraw cadence is event-driven here. Contingency: at the end of `renderTranscriptScrollbar`, when `opacity > 0.01`, set `AppWindow.g_force_rebuild = true;` so the fade window keeps producing frames (mirrors how `handleScroll` already sets `g_force_rebuild` after `chat.scrollBy`). Add only if needed.

- [ ] **Step 3: Verify drag**

Press on the thumb and drag up/down. Expected: the transcript scrolls to match; releasing ends the drag; the thumb stays under the cursor while dragging (no jump on press because `thumbDragOffset` preserves the grab point).

- [ ] **Step 4: Verify hover hold**

Move the pointer over the scrollbar and leave it there. Expected: the bar stays fully visible while hovered and resumes fading once the pointer leaves.

- [ ] **Step 5: Verify no overflow = no bar**

Open a short conversation that fits without scrolling. Expected: no scrollbar is drawn, and clicking/dragging at the right edge still allows normal transcript text selection (the hit-test returns null when `content_h <= transcript_h`).

- [ ] **Step 6: Final commit (if the contingency in Step 2 was applied)**

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "Keep redrawing while the transcript scrollbar fades"
```

---

## Notes / deviations from the spec

- The spec proposed a `scrollbar_opacity` field plus a `showScrollbar()` method. The implementation collapses this to a single `scrollbar_show_time: i64` field: `fadeOpacity` derives the opacity purely from the timestamp (`0` = never shown, `held` overrides to fully visible), so no per-frame write-back or separate opacity field is needed. Hover/drag visibility is handled by the `held` flag rather than by mutating session state.
- The spec said tests would live in `ai_chat_renderer.zig`. Because that file `@cImport`s OpenGL and is excluded from the test build, the testable math lives in the new pure module `ai_chat_scrollbar_model.zig` instead (same rationale the terminal used for `scrollbar_model.zig`).
- Track clicks outside the thumb are treated as drag-with-centered-thumb (matching the input scrollbar's `inputScrollbarHitTest`), not page-jumps. This is intentional for v1.
