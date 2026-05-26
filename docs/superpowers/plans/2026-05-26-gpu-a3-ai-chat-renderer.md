# GPU A3 Increment 3 — ai_chat_renderer → ui_pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route `src/renderer/ai_chat_renderer.zig` entirely through the shared `ui_pipeline` (plus a new clip helper), ending with zero raw `gl.*` and no `glad` cImport, and extract its pure rect-geometry into a std-only, unit-tested `ai_chat_layout.zig`.

**Architecture:** Axis A — replace the 56 `gl_init.renderQuad*` calls with `ui_pipeline.fillQuad*`, the two `GL_SCISSOR_TEST` regions with new `ui_pipeline.beginClip/endClip`, and delete the now-redundant ambient blend/program setup (blend is frame-level in `AppWindow`). Axis B — move 7 pure rect-geometry functions into `src/ai_chat_layout.zig` (std-only, constants/metrics passed as params), with `ai_chat_renderer` keeping thin wrappers so internal call sites are unchanged.

**Tech Stack:** Zig 0.15.2; OpenGL via the `gpu` backend primitives; tests via `zig build test` (fast, std-only) and `zig build test-full` (full app binary, pre-merge gate).

**Reference:** spec `docs/superpowers/specs/2026-05-26-gpu-a3-ai-chat-renderer-design.md`. Prior increments: `titlebar_layout.zig`, `cell_geometry.zig`, `ui_pipeline.zig`.

---

## File Structure

- **Create** `src/ai_chat_layout.zig` — std-only pure rect geometry + unit tests. Sibling of the existing `ai_chat_composer_layout.zig` / `ai_chat_scrollbar_model.zig`.
- **Modify** `src/renderer/ui_pipeline.zig` — add `beginClip(rect)` / `endClip()`.
- **Modify** `src/renderer/ai_chat_renderer.zig` — quad/scissor/ambient conversion; alias `Rect`/`BubbleGeometry` and wrap geometry via `ai_chat_layout`; drop the `glad` cImport.
- **Modify** `src/test_fast.zig` — register `ai_chat_layout.zig`.

---

## Task 1: `ai_chat_layout.zig` — pure rect geometry (Axis B, TDD)

**Files:**
- Create: `src/ai_chat_layout.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Create the module with types + tests only (no impls yet)**

Create `src/ai_chat_layout.zig`:

```zig
//! Pure rect geometry for the AI Chat renderer.
//!
//! No GL, font, or platform imports so it can be unit-tested in the fast test
//! build (mirrors ai_chat_composer_layout.zig / ai_chat_scrollbar_model.zig,
//! extracted for the same reason — src/renderer/ai_chat_renderer.zig @cImports
//! OpenGL historically and the font globals are not part of the test build).
//! Callers pass font-derived metrics (e.g. header_h) and layout constants as
//! params; this module owns none of them.

const std = @import("std");

/// Window-space rect with a top-left-origin `top_px` (matches the renderer's
/// existing Rect: hit-tests compare against top_px, draws convert to GL y).
pub const Rect = struct {
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
};

pub const BubbleGeometry = struct {
    x: f32,
    w: f32,
};

test "pointInRect inside, edges, outside" {
    const r = Rect{ .x = 0, .top_px = 0, .w = 20, .h = 20 };
    try std.testing.expect(pointInRect(10, 10, r));
    try std.testing.expect(pointInRect(0, 0, r)); // top-left edge inclusive
    try std.testing.expect(pointInRect(20, 20, r)); // bottom-right edge inclusive
    try std.testing.expect(!pointInRect(21, 10, r));
    try std.testing.expect(!pointInRect(10, 21, r));
}

test "bubbleGeometry user vs assistant" {
    const u = bubbleGeometry(true, 100, 200); // 0.82 width, right-aligned
    try std.testing.expectApproxEqAbs(@as(f32, 164), u.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 136), u.x, 0.001);
    const a = bubbleGeometry(false, 100, 200); // full width, left
    try std.testing.expectApproxEqAbs(@as(f32, 200), a.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), a.x, 0.001);
}

test "copyButtonRectForBubble placement" {
    const r = copyButtonRectForBubble(100, 50, 200, 14, 24, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 262), r.x, 0.001); // 100+200-14-24
    try std.testing.expectApproxEqAbs(@as(f32, 58), r.top_px, 0.001); // 50+8
    try std.testing.expectApproxEqAbs(@as(f32, 24), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), r.h, 0.001);
}

test "detailHeaderRect passes header_h through" {
    const r = detailHeaderRect(10, 20, 300, 40);
    try std.testing.expectApproxEqAbs(@as(f32, 10), r.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), r.top_px, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 300), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), r.h, 0.001);
}

test "detailCopyButtonRect centers in header_h" {
    const r = detailCopyButtonRect(10, 20, 300, 40, 14, 24);
    try std.testing.expectApproxEqAbs(@as(f32, 272), r.x, 0.001); // 10+300-14-24
    try std.testing.expectApproxEqAbs(@as(f32, 28), r.top_px, 0.001); // 20+round((40-24)/2)
    try std.testing.expectApproxEqAbs(@as(f32, 24), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), r.h, 0.001);
}

test "permissionChipX" {
    const px = permissionChipX(0, 1000, 18, 280, 12, 104); // w - line_pad - status - gap - chip
    try std.testing.expectApproxEqAbs(@as(f32, 586), px, 0.001);
}

test "stopButtonRect centers in header_h" {
    const r = stopButtonRect(0, 1000, 5, 18, 104, 28, 54);
    try std.testing.expectApproxEqAbs(@as(f32, 878), r.x, 0.001); // 1000-18-104
    try std.testing.expectApproxEqAbs(@as(f32, 18), r.top_px, 0.001); // 5+round((54-28)/2)
    try std.testing.expectApproxEqAbs(@as(f32, 104), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 28), r.h, 0.001);
}
```

- [ ] **Step 2: Register the module and run tests to verify they FAIL**

Add to `src/test_fast.zig`, immediately after the `renderer/titlebar_layout.zig` line:

```zig
    _ = @import("ai_chat_layout.zig");
```

Run: `zig build test`
Expected: FAIL — compile error, the test bodies reference `pointInRect`, `bubbleGeometry`, etc. which are not yet defined (`error: use of undeclared identifier`).

- [ ] **Step 3: Add the function implementations**

Insert these `pub fn`s into `src/ai_chat_layout.zig` between the `BubbleGeometry` struct and the first `test` block (transcribed verbatim from the current `ai_chat_renderer.zig` bodies, with constants/metrics lifted to params):

```zig
pub fn pointInRect(px: f32, py: f32, rect: Rect) bool {
    return px >= rect.x and px <= rect.x + rect.w and py >= rect.top_px and py <= rect.top_px + rect.h;
}

pub fn bubbleGeometry(is_user: bool, x: f32, w: f32) BubbleGeometry {
    const bubble_w = @min(w, if (is_user) w * 0.82 else w);
    return .{
        .x = if (is_user) x + w - bubble_w else x,
        .w = bubble_w,
    };
}

pub fn copyButtonRectForBubble(
    bubble_x: f32,
    top_px: f32,
    bubble_w: f32,
    bubble_pad_x: f32,
    button_size: f32,
    button_pad: f32,
) Rect {
    return .{
        .x = bubble_x + bubble_w - bubble_pad_x - button_size,
        .top_px = top_px + button_pad,
        .w = button_size,
        .h = button_size,
    };
}

pub fn detailHeaderRect(x: f32, top_px: f32, w: f32, header_h: f32) Rect {
    return .{ .x = x, .top_px = top_px, .w = w, .h = header_h };
}

pub fn detailCopyButtonRect(
    x: f32,
    top_px: f32,
    w: f32,
    header_h: f32,
    detail_pad_x: f32,
    button_size: f32,
) Rect {
    return .{
        .x = x + w - detail_pad_x - button_size,
        .top_px = top_px + @round((header_h - button_size) / 2),
        .w = button_size,
        .h = button_size,
    };
}

pub fn permissionChipX(x: f32, w: f32, line_pad_x: f32, status_slot_w: f32, chip_gap: f32, chip_w: f32) f32 {
    return x + w - line_pad_x - status_slot_w - chip_gap - chip_w;
}

pub fn stopButtonRect(
    x: f32,
    w: f32,
    titlebar_offset: f32,
    line_pad_x: f32,
    stop_w: f32,
    stop_h: f32,
    header_h: f32,
) Rect {
    return .{
        .x = x + w - line_pad_x - stop_w,
        .top_px = titlebar_offset + @round((header_h - stop_h) / 2),
        .w = stop_w,
        .h = stop_h,
    };
}
```

- [ ] **Step 4: Run tests to verify they PASS**

Run: `zig build test`
Expected: PASS (all `ai_chat_layout` tests green; no other test regresses).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_layout.zig src/test_fast.zig
git commit -m "feat: extract ai_chat_layout pure rect geometry (A3 increment 3, Axis B)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `ui_pipeline.beginClip` / `endClip` (Axis A infra)

**Files:**
- Modify: `src/renderer/ui_pipeline.zig`

- [ ] **Step 1: Add the clip helpers**

In `src/renderer/ui_pipeline.zig`, add after the `setProjection` function (before `fillQuad`):

```zig
/// Enable scissor clipping to `rect` (window-space, same convention as the
/// caller's existing glScissor: x/y are the lower-left corner in GL pixels).
/// Rounds to integer pixels, matching the prior @intFromFloat(@round(...)) calls.
pub fn beginClip(rect: Rect) void {
    const gl = gpu.glTable();
    gl.Enable.?(c.GL_SCISSOR_TEST);
    gl.Scissor.?(
        @intFromFloat(@round(rect.x)),
        @intFromFloat(@round(rect.y)),
        @intFromFloat(@round(rect.w)),
        @intFromFloat(@round(rect.h)),
    );
}

/// Disable scissor clipping (= the prior gl.Disable(GL_SCISSOR_TEST)). Flat
/// enable/disable, not a nesting stack — ai_chat never nests clip regions.
pub fn endClip() void {
    gpu.glTable().Disable.?(c.GL_SCISSOR_TEST);
}
```

(`Rect`, `gpu`, and `c` are already in scope at the top of `ui_pipeline.zig`.)

- [ ] **Step 2: Build to verify it compiles**

Run: `zig build`
Expected: clean build, no errors.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/ui_pipeline.zig
git commit -m "feat: add ui_pipeline.beginClip/endClip scissor helpers (A3 increment 3)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: ai_chat_renderer quad conversion + ui_pipeline import (Axis A)

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig`

- [ ] **Step 1: Add the ui_pipeline import**

In `src/renderer/ai_chat_renderer.zig`, after the `const titlebar = AppWindow.titlebar;` line (line 25), add:

```zig
const ui_pipeline = @import("ui_pipeline.zig");
```

- [ ] **Step 2: Replace all renderQuad / renderQuadAlpha calls**

Replace every occurrence (56 sites) — the signatures are identical, so this is a pure rename:
- `gl_init.renderQuadAlpha(` → `ui_pipeline.fillQuadAlpha(`
- `gl_init.renderQuad(` → `ui_pipeline.fillQuad(`

(Do the `renderQuadAlpha` pattern first; the trailing `(` already prevents `renderQuad(` from matching `renderQuadAlpha(`, so order is safe either way.)

- [ ] **Step 3: Verify no renderQuad calls remain and build**

Run: `grep -nE "gl_init\.renderQuad" src/renderer/ai_chat_renderer.zig`
Expected: no output (all converted).

Run: `zig build`
Expected: clean build. (`gl_init` is still imported — used for the soon-to-be-removed ambient block; that is removed in Task 4.)

- [ ] **Step 4: Commit**

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "refactor: ai_chat_renderer quads via ui_pipeline.fillQuad (A3 increment 3)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Scissor → beginClip/endClip, drop ambient setup + glad cImport (Axis A)

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig`

- [ ] **Step 1: Delete the redundant ambient block**

In `render()`, remove these six lines (currently ~124-129):

```zig
    const gl = AppWindow.gpu.glTable();
    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);
```

(Blend is enabled frame-level in `AppWindow.zig`; the program/VAO binds are dead now that `ui_pipeline`/`titlebar` draw helpers are self-contained. The following `const bg = AppWindow.g_theme.background;` line stays as the new first statement.)

- [ ] **Step 2: Convert the input-field scissor region**

Replace the input-field scissor enable (currently ~183-189):

```zig
    gl.Enable.?(c.GL_SCISSOR_TEST);
    gl.Scissor.?(
        @intFromFloat(@round(layout.field_x)),
        @intFromFloat(@round(layout.field_y)),
        @intFromFloat(@round(layout.field_w)),
        @intFromFloat(@round(layout.field_h)),
    );
```

with:

```zig
    ui_pipeline.beginClip(.{ .x = layout.field_x, .y = layout.field_y, .w = layout.field_w, .h = layout.field_h });
```

And its matching disable (currently ~255): `gl.Disable.?(c.GL_SCISSOR_TEST);` → `ui_pipeline.endClip();`

- [ ] **Step 3: Convert the transcript scissor region**

Replace the transcript scissor enable (currently ~281-287):

```zig
    gl.Enable.?(c.GL_SCISSOR_TEST);
    gl.Scissor.?(
        @intFromFloat(@round(x)),
        @intFromFloat(@round(transcript_bottom)),
        @intFromFloat(@round(w)),
        @intFromFloat(@round(transcript_h)),
    );
```

with:

```zig
    ui_pipeline.beginClip(.{ .x = x, .y = transcript_bottom, .w = w, .h = transcript_h });
```

And its matching disable (currently ~332): `gl.Disable.?(c.GL_SCISSOR_TEST);` → `ui_pipeline.endClip();`

- [ ] **Step 4: Remove the glad cImport**

Delete the cImport block (currently lines 27-29):

```zig
const c = @cImport({
    @cInclude("glad/gl.h");
});
```

- [ ] **Step 5: Verify no raw GL remains and build**

Run: `grep -nE "\bgl\.|\bc\.|glad" src/renderer/ai_chat_renderer.zig`
Expected: no output (no raw `gl.`, no `c.`, no `glad`).

Run: `zig build`
Expected: clean build. (If the compiler reports `c` or `gl` unused/undeclared, a reference was missed — re-grep.)

- [ ] **Step 6: Commit**

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "refactor: ai_chat_renderer scissor via ui_pipeline clip, drop glad cImport (A3 increment 3)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Wire ai_chat_layout (Axis B), keep call sites unchanged

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig`

- [ ] **Step 1: Add the import and alias the value types**

After the `const ui_pipeline = @import("ui_pipeline.zig");` line, add:

```zig
const ai_chat_layout = @import("../ai_chat_layout.zig");
```

Replace the local `Rect` and `BubbleGeometry` struct definitions (currently the `const Rect = struct { x: f32, top_px: f32, w: f32, h: f32 };` at ~1040-1045 and the `const BubbleGeometry = struct { x: f32, w: f32 };` at ~1035-1038) with aliases:

```zig
const Rect = ai_chat_layout.Rect;
const BubbleGeometry = ai_chat_layout.BubbleGeometry;
```

Leave the existing `const CopyButtonRect = Rect;` and `const HeaderButtonRect = Rect;` aliases as-is (they now alias the shared `Rect`).

- [ ] **Step 2: Convert the geometry functions into thin wrappers**

Replace each function body so it delegates to `ai_chat_layout`, feeding the renderer's constants/metrics. The public signatures are unchanged, so all internal call sites and `input.zig` hit-tests stay untouched:

```zig
fn pointInRect(px: f32, py: f32, rect: Rect) bool {
    return ai_chat_layout.pointInRect(px, py, rect);
}

fn bubbleGeometry(role: ai_chat.Role, x: f32, w: f32) BubbleGeometry {
    return ai_chat_layout.bubbleGeometry(role == .user, x, w);
}

fn detailHeaderRect(x: f32, top_px: f32, w: f32) Rect {
    return ai_chat_layout.detailHeaderRect(x, top_px, w, detailHeaderHeight());
}

fn detailCopyButtonRect(x: f32, top_px: f32, w: f32) CopyButtonRect {
    return ai_chat_layout.detailCopyButtonRect(x, top_px, w, detailHeaderHeight(), DETAIL_PAD_X, COPY_BUTTON_SIZE);
}

fn copyButtonRect(role: ai_chat.Role, x: f32, top_px: f32, w: f32) CopyButtonRect {
    const bubble = bubbleGeometry(role, x, w);
    return copyButtonRectForBubble(bubble.x, top_px, bubble.w);
}

fn copyButtonRectForBubble(bubble_x: f32, top_px: f32, bubble_w: f32) CopyButtonRect {
    return ai_chat_layout.copyButtonRectForBubble(bubble_x, top_px, bubble_w, BUBBLE_PAD_X, COPY_BUTTON_SIZE, COPY_BUTTON_PAD);
}

fn permissionChipX(x: f32, w: f32) f32 {
    return ai_chat_layout.permissionChipX(x, w, LINE_PAD_X, STATUS_SLOT_W, 12, PERMISSION_CHIP_W);
}

fn stopButtonRect(x: f32, w: f32, titlebar_offset: f32) HeaderButtonRect {
    return ai_chat_layout.stopButtonRect(x, w, titlebar_offset, LINE_PAD_X, STOP_BUTTON_W, STOP_BUTTON_H, HEADER_H);
}
```

(`detailHeaderHeight()` stays in `ai_chat_renderer.zig` — it reads the `font` global. The layout constants `DETAIL_PAD_X`, `COPY_BUTTON_SIZE`, `COPY_BUTTON_PAD`, `BUBBLE_PAD_X`, `LINE_PAD_X`, `STATUS_SLOT_W`, `PERMISSION_CHIP_W`, `STOP_BUTTON_W`, `STOP_BUTTON_H`, `HEADER_H` stay declared in `ai_chat_renderer.zig` and are passed in.)

- [ ] **Step 3: Build and run the full test suite**

Run: `zig build`
Expected: clean build.

Run: `zig build test`
Expected: PASS (the `ai_chat_layout` tests from Task 1 plus all existing fast tests).

Run: `zig build test-full`
Expected: matches the current fully-green baseline plus the new tests — no new failures.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "refactor: ai_chat_renderer geometry via ai_chat_layout (A3 increment 3, Axis B)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Final verification gate

**Files:** none (verification only)

- [ ] **Step 1: Confirm the file is fully raw-GL-free**

Run: `grep -nE "\bgl\.|\bc\.GL|glad|gl_init\.(shader_program|simple_color_shader|vao|vbo|renderQuad)" src/renderer/ai_chat_renderer.zig`
Expected: no output. (`gl_init` may still be imported only if something else references it — verify with `grep -n "gl_init" src/renderer/ai_chat_renderer.zig`; if the only remaining hits are gone, remove the now-unused `const gl_init = AppWindow.gpu.gl_init;` import and rebuild.)

- [ ] **Step 2: Full build + test gate**

Run: `zig build && zig build test-full`
Expected: clean build; test-full green at the baseline (no new failures).

- [ ] **Step 3: Manual Windows visual check (human gate — hand back to the user)**

The AI chat panel must render identically. Verify:
- Header bar: model / mode / permission chip / status text; **stop button** (position, label, icon) when a request is running.
- Message bubbles: user right-aligned (0.82 width), assistant full-width; selection rule; **copy buttons** (hover/click hit area unchanged).
- Tool / reasoning cards: collapse arrows, header, copy button placement.
- Usage footer.
- Input field: typing, multi-line, and **scroll-clipping** — text scrolled past the field edge clips exactly as before (this exercises the new `beginClip`).
- Input + transcript **scrollbars**: track/thumb render, drag.
- Composer suggestion popup, approval card, markdown / table content, text selection.
- **Blend sanity (primary risk):** bubbles, cards, and glyph text blend correctly with no premultiplied-alpha artifacts. If any appear, the fallback per the spec is to add a single explicit `BlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)` reset at the top of `render()` (via a small `ui_pipeline.resetBlend()` helper) rather than restoring the whole ambient block.

Behavior-preserving — any visual difference is a regression.

---

## Self-review notes

- **Spec coverage:** §2 clip helper → Task 2; §3 quad/scissor/ambient/cImport → Tasks 3-4; §4 ai_chat_layout extraction → Tasks 1 & 5; §5 verification → Task 6; §6 blend risk → Task 6 Step 3 fallback. All covered.
- **Type consistency:** `Rect{x,top_px,w,h}` and `BubbleGeometry{x,w}` defined once in `ai_chat_layout.zig` (Task 1), aliased in the renderer (Task 5). `ui_pipeline.Rect{x,y,w,h}` is the existing distinct type used only by `beginClip` (Task 2/4) — the field name `y` (not `top_px`) is intentional and matches glScissor's lower-left origin.
- **No placeholders:** every code step shows the actual code; every run step states the expected result.
