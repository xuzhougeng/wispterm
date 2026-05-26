# Design: GPU A3 increment 3 — ai_chat_renderer → ui_pipeline

Status: approved (design); pending spec review
Date: 2026-05-26
Scope: TODO.md Phase A item **A3**, third increment
References: prior A3 specs `2026-05-26-gpu-a3-cell-renderer-design.md`,
`2026-05-26-gpu-a3-titlebar-design.md`, [decoupling-guide.md](../../decoupling-guide.md).

## 1. Goal, scope & strategy

Route `src/renderer/ai_chat_renderer.zig` entirely through the shared
`ui_pipeline` (and a small new clip primitive), ending with **zero raw `gl.*`
and no `@cInclude("glad/gl.h")`** — matching `titlebar.zig`. Behavior-preserving.
Both decoupling axes, touching the file once.

This is the first conversion to **consume** the `ui_pipeline` foundation built in
increment 2 rather than extend it (apart from the one clip helper). It proves the
pattern on a large, quad-heavy UI file before the 4564-line `overlays`.

### Why this file (vs overlays)

- `ai_chat_renderer` is ~1984 lines; its 56 `gl_init.renderQuad`/`renderQuadAlpha`
  sites map 1:1 to `ui_pipeline.fillQuad`/`fillQuadAlpha`. Its text already routes
  through `titlebar.renderTextLimited` (converted). It does **not** touch
  `overlay_shader`, so there is no cross-file entanglement.
- `overlays` owns one of the two remaining `overlay_shader` draw sites (the other
  is in `background_image`); a clean conversion couples those two files into one
  larger increment. Deferred to a later increment.

### Two findings that shape the conversion

1. **Blend is already frame-level.** `AppWindow.zig` enables `GL_BLEND` + the
   standard `BlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)` once per frame
   before the UI phase; `titlebar` relies on this and touches no blend. So
   `ai_chat`'s local `Enable(GL_BLEND)+BlendFunc` (render() lines ~125-126) and
   the `UseProgram(gl_init.shader_program)+ActiveTexture+BindVertexArray(gl_init.vao)`
   ambient setup (~127-129) are now **redundant** — the `ui_pipeline` draw helpers
   are self-contained (each `use()`s its pipeline and binds its VAO), and
   `cell_renderer` restores standard blend after its premultiplied pass, which
   runs before the UI phase.
2. **Axis B is mostly pre-done.** `ai_chat_renderer` already delegates pure logic
   to std-only `ai_chat_composer_layout.zig` and `ai_chat_scrollbar_model.zig`.
   So this increment is **Axis-A-dominant** with a small Axis-B top-up (§4).

### Non-goals (deferred)

- `overlays`, `markdown_preview_renderer`, `file_explorer_renderer`, and the
  GPU-effect files (`image_renderer`, `post_process`, `background_image`, `fbo`)
  — their own increments; they keep the `gl_init` compat vars / re-exports.
- `overlay_shader` stays in `gl_init`.
- The height/measurement helpers (`bubbleHeight`, `toolCardHeight`, …) depend on
  font-global `measureText`; they stay inline (extracting them would mean
  injecting a measure-fn — YAGNI for this increment).
- Frame/RenderPass/Target layer, API-neutralization, MSL. A4/A5/A6.

## 2. New shared primitive: `ui_pipeline` clip helpers

`ai_chat` uses `GL_SCISSOR_TEST` to clip two regions (the input field and the
scrollable transcript). `ui_pipeline` gains a thin, reusable clip wrapper so the
caller needs no raw GL; `overlays`/`markdown` reuse it later, and it advances A6.

```zig
/// Enable scissor clipping to `rect` (window-space, y-up bottom-left origin —
/// same convention as glScissor / the existing ai_chat scissor calls). Rounds
/// to integer pixels.
pub fn beginClip(rect: Rect) void;
/// Disable scissor clipping (= the old gl.Disable(GL_SCISSOR_TEST)).
pub fn endClip() void;
```

- Implemented over `gpu.glTable()` (`Enable`/`Disable(GL_SCISSOR_TEST)`,
  `Scissor`), living with the other `ui_pipeline` helpers.
- `beginClip` takes `Rect{ x, y, w, h }`; the caller passes the same
  field/transcript rect it currently feeds to `glScissor` (verbatim arithmetic,
  preserving the `@intFromFloat(@round(...))` rounding inside the helper).
- Scope note: this is a flat enable/disable mirror of today's behavior, not a
  nesting stack. `ai_chat` never nests scissor regions, so a single
  enable/disable pair per region is sufficient. Named `beginClip`/`endClip`
  (not `push`/`pop`) so the name reflects the flat semantics rather than
  implying a stack that does not exist (YAGNI).

No other `ui_pipeline` API changes; `fillQuad`/`fillQuadAlpha`/`drawGlyph` are
used as-is.

## 3. ai_chat_renderer Axis-A conversion

1. **Quads (56 sites):** `gl_init.renderQuad(...)` → `ui_pipeline.fillQuad(...)`;
   `gl_init.renderQuadAlpha(...)` → `ui_pipeline.fillQuadAlpha(...)`. Identical
   signatures — pure rename. (Both currently route to `ui_pipeline` via the
   `gl_init` re-export anyway; this drops the indirection so the file imports
   `ui_pipeline` directly.)
2. **Scissor (2 regions):** the `Enable(GL_SCISSOR_TEST)+Scissor(...)` /
   `Disable(GL_SCISSOR_TEST)` pairs → `ui_pipeline.beginClip(rect)` /
   `ui_pipeline.endClip()`.
3. **Delete dead setup:** remove the `Enable(GL_BLEND)+BlendFunc` and the
   `UseProgram+ActiveTexture+BindVertexArray` ambient block at the top of
   `render()` (redundant per §1.1).
4. **Drop the GL include:** once no `gl.*` / `c.GL_*` remain, remove the
   `const c = @cImport({ @cInclude("glad/gl.h") })` block and the
   `const gl = AppWindow.gpu.glTable()` locals. Add
   `const ui_pipeline = @import("ui_pipeline.zig");` (the file already imports
   `gl_init`, `titlebar`, `AppWindow`).
5. **Verify `c` is fully unused** afterward via grep (`c\.` → no hits); Zig will
   not error on an unused container-level `const`, so this is a manual gate.

The layout/draw orchestration, hit-tests, markdown/table rendering, and text via
`titlebar.renderTextLimited` are otherwise unchanged.

## 4. Axis B — `ai_chat_layout.zig` (new, std-only)

Extract the pure, metrics-free rect geometry into a std-only module
(imports only `std`), registered in `test_fast.zig`. Candidates (all currently
pure functions of `x`/`w`/role + layout constants):

- `pointInRect(px, py, rect) bool`
- `bubbleGeometry(is_user, x, w) -> { x, w }`
- `copyButtonRectForBubble(bubble_x, top_px, bubble_w) -> Rect`
- `detailCopyButtonRect(x, top_px, w, header_h) -> Rect`  *(header_h injected)*
- `detailHeaderRect(x, top_px, w, header_h) -> Rect`  *(header_h injected)*
- `permissionChipX(x, w) f32`
- `stopButtonRect(x, w, titlebar_offset) -> Rect`

Threading rules (the titlebar_layout pattern):

- The module owns its own `Rect`/`Geometry` value structs (plain `f32` fields);
  `ai_chat_renderer` maps to/from its existing `Rect`/`BubbleGeometry` at the
  call site, or aliases them to the layout module's types.
- Functions whose value depends on font globals take that metric as a **param**:
  `detailHeaderHeight()` (font-derived) is computed in the renderer and passed in
  as `header_h`. No `font`/`AppWindow`/`ai_chat` imports in the layout module.
- `bubbleGeometry` takes `is_user: bool` (not `ai_chat.Role`) to stay std-only;
  the renderer passes `role == .user`.
- Static layout constants used by these helpers (`COPY_BUTTON_SIZE`,
  `COPY_BUTTON_PAD`, `BUBBLE_PAD_X`, `DETAIL_PAD_X`, `LINE_PAD_X`,
  `STATUS_SLOT_W`, `PERMISSION_CHIP_W`, `STOP_BUTTON_W`, `STOP_BUTTON_H`,
  `HEADER_H`) move into `ai_chat_layout.zig`; `ai_chat_renderer` imports them
  back (or re-declares aliases) so existing references elsewhere keep compiling.
- `ai_chat_renderer`'s `fn pointInRect`/`fn bubbleGeometry`/… become thin
  wrappers delegating to the module (or call sites switch directly).

**Per-function std-only check is part of the work:** any candidate that turns out
to pull in a heavy import is lowered to a plain param type or left inline.

Unit tests cover: `pointInRect` inside/edge/outside; `bubbleGeometry` user
(0.82 width, right-aligned) vs non-user (full width, left); `copyButtonRectForBubble`
and `detailCopyButtonRect` placement (incl. the `header_h` centering); `permissionChipX`;
`stopButtonRect` vertical centering within `HEADER_H`.

## 5. Verification

- `zig build` clean (x86_64-windows-gnu).
- `zig build test` includes the new `ai_chat_layout` tests.
- `zig build test-full` stays green (current fully-green baseline + new tests; no
  new failures).
- **Manual Windows visual check (final gate):** the AI chat panel renders
  identically — header bar (model/mode/permission chip/status, stop button),
  message bubbles (user right-aligned, assistant full-width, selection rule,
  copy buttons), tool/reasoning cards (collapse arrows, copy), usage footer,
  input field with **scroll-clipping** (multi-line text scrolled past the field
  edge must clip exactly as before), input + transcript scrollbars (track/thumb,
  drag), composer suggestion popup, approval card, markdown/table content,
  text selection. Behavior-preserving; any visual difference is a regression.

## 6. Risks

- **Blend-state assumption (primary).** Dropping `ai_chat`'s local `BlendFunc`
  assumes standard alpha blend is active when the AI panel renders. This holds
  because `AppWindow` sets it frame-level and `cell_renderer` restores it after
  its premultiplied pass — but it is the one behavioral change, so the Windows
  visual check must confirm bubbles/cards/text blend correctly (watch for
  premultiplied-blend artifacts if some prior renderer left a non-standard
  `BlendFunc`). If an artifact appears, the fallback is a single
  `ui_pipeline.resetBlend()` call (or keeping one explicit `BlendFunc`) at the
  top of `render()` rather than reintroducing the full ambient block.
- **Scissor coordinate parity.** `beginClip` must reproduce the exact
  `@intFromFloat(@round(...))` rounding and the y-up window-space origin of the
  current `glScissor` calls; the input-field and transcript clip rects are passed
  verbatim.
- **`ai_chat_layout` extraction parity.** The metrics-injected functions must
  return identical rects to the inline versions; the `header_h` param must be fed
  the same `detailHeaderHeight()` value. Unit tests + visual check on copy-button
  hit areas.
- **No automated render coverage.** Visual correctness rests on the manual
  Windows check; fast tests cover only the extracted `ai_chat_layout` logic.
