# Design: GPU A3 increment 2 — shared UI pipeline + titlebar

Status: approved (design); pending spec review
Date: 2026-05-26
Scope: TODO.md Phase A item **A3**, second increment
References: prior A3 spec `2026-05-26-gpu-a3-cell-renderer-design.md`,
[decoupling-guide.md](../../decoupling-guide.md). Ghostty: `renderer/opengl/`,
API-agnostic `renderer/cell.zig`.

## 1. Goal, scope & strategy

Move the **shared** immediate-mode UI rendering (solid quads, text/glyph,
color-emoji) out of `gl_init`'s raw GL into a new primitives-backed module
`ui_pipeline.zig`, and convert `titlebar.zig` onto it as the proving ground —
both decoupling axes, touching titlebar once.

**Route A (pragmatic).** The primitives stay OpenGL-shaped for now; the eventual
API-neutralization (vertex descriptors, indexed bindings, Frame/RenderPass, MSL)
is a later collation step once all files route through primitives.

**Compat-shim strategy (the key scoping decision).** The shared pipeline handles
(`shader_program`, `simple_color_shader`, `vao`, `vbo`) are referenced with raw
GL by ~13 renderer files. Rather than cascade into all of them now,
`ui_pipeline` **owns** the primitive-built pipelines and `gl_init` keeps those
four as **compat mirror vars** (populated by `ui_pipeline.init()`) plus
**re-exports** the moved functions (`renderQuad`, …). Result: the ~12
not-yet-converted files compile and behave **unchanged**; their `gl_init.*`
references transparently use the primitive-built objects. The mirror vars
dissolve from `gl_init` as each file converts in later increments.

A consequence worth stating up front: because `gl_init.renderQuad` is
re-exported to `ui_pipeline.fillQuad`, titlebar's **63 `renderQuad` call sites
need no change** — they route through primitives transparently. Titlebar's only
GL conversion is its three raw-`gl.*` glyph/emoji functions.

### Non-goals (deferred)

- The other ~12 renderer files (overlays, ai_chat_renderer, file_explorer,
  scrollbar, image_renderer, fbo, background_image, markdown_preview, …) — they
  keep using the `gl_init` compat vars / re-exports until their own increments.
- `overlay_shader` stays in `gl_init` (overlays' concern).
- `cell_renderer.renderChar` + the `drawCells` cursor block keep using the
  `gl_init` compat vars (untouched this increment).
- Frame/RenderPass/Target layer, API-neutralization, MSL (Route-A collation,
  later). A4/A5/A6.

## 2. `ui_pipeline.zig` (new, primitives-backed)

Owns the shared UI rendering, built from `gpu.Pipeline`/`Buffer`/`Texture` +
`gpu.shaders`. Lives in `src/renderer/`. Imports `AppWindow` for `gpu`,
`g_theme`, and `gl_init` (for the `g_draw_call_count` counter + to set compat
vars); the `gl_init↔ui_pipeline` import cycle is tolerated (same as existing
gl_init↔AppWindow).

### State
```zig
pub threadlocal var text: gpu.Pipeline = .{ .program = 0, .vao = 0 };  // shader_program eq (text/glyph + solid)
pub threadlocal var emoji: gpu.Pipeline = .{ .program = 0, .vao = 0 }; // simple_color_shader eq
pub threadlocal var quad: gpu.Buffer = .{ .handle = 0, .target = 0 };  // shared dynamic 6-vertex vbo
pub threadlocal var solid: gpu.Texture = .{ .handle = 0 };             // 1x1 white
```

### Small value types
```zig
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
pub const Uv = struct { u0: f32, v0: f32, u1: f32, v1: f32 };
```

### Public API (the helpers titlebar + future files call)
```zig
pub fn init() void;     // build text/emoji pipelines, quad buffer, solid texture; set gl_init compat vars
pub fn deinit() void;

pub fn setProjection() void;  // ortho from current GL viewport, on the text pipeline (= gl_init.setProjection)

/// Solid color quad (= gl_init.renderQuad). fillQuad = fillQuadAlpha(..., 1.0).
pub fn fillQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void;
/// Preserves the existing alpha trick: blends `color` toward AppWindow.g_theme.background
/// by `alpha` and draws opaque via the solid texture (= gl_init.renderQuadAlpha).
pub fn fillQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void;

/// Grayscale/text glyph via the text pipeline (samples atlas .r as alpha, modulated by color).
pub fn drawGlyph(rect: Rect, uv: Uv, tex: c.GLuint, color: [3]f32) void;

/// Color-emoji via the emoji pipeline: sets opacity, switches to premultiplied
/// blend (GL_ONE, GL_ONE_MINUS_SRC_ALPHA) for the draw, then restores
/// (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA). (= renderTitlebarChar color / renderBellEmoji)
pub fn drawColorGlyph(rect: Rect, uv: Uv, tex: c.GLuint, opacity: f32) void;
```

### Internal helper (DRY)
```zig
fn quadVertices(rect: Rect, uv: Uv) [6][4]f32; // the (x,y+h,u0,v0)…(x+w,y+h,u1,v0) order used everywhere
```
Each draw: `quad.upload(sliceAsBytes(verts))` then `text|emoji.use()` (or use
once + set uniforms) + uniform/texture binds + `gl.DrawArrays(GL_TRIANGLES,0,6)`
via the GL table, exactly mirroring the current sequences. `g_draw_call_count`
increments preserved.

### `init()` builds + populates compat vars
Builds `text` (program from `shaders.vertex_shader_source` /
`fragment_shader_source`, VAO = the single vec4 attrib layout from
`gl_init.initBuffers`, `quad` = its dynamic vbo), `emoji` (program from
`vertex_shader_source` / `simple_color_fragment_source`, sharing the same VAO
layout), and `solid` (1×1 white, from `initSolidTexture`). Then mirrors:
```zig
gl_init.shader_program = text.program;
gl_init.simple_color_shader = emoji.program;
gl_init.vao = text.vao;
gl_init.vbo = quad.handle;
```

## 3. `gl_init.zig` after

- **Moved out** (to `ui_pipeline`): `renderQuad`, `renderQuadAlpha`,
  `setProjection`, `initBuffers`, `initSolidTexture`, `solid_texture`, and the
  `shader_program`/`simple_color_shader` compile+link (out of `initShaders`).
- **Kept**: `overlay_shader` (+ its link in `initShaders`), `g_draw_call_count`,
  `g_bg_opacity`, `compileShader`, `linkProgram`, `setProjectionForProgram`.
- **Compat mirror vars** (kept as `pub threadlocal var`, written by
  `ui_pipeline.init()`; doc-commented as transition mirrors removed per file):
  `shader_program`, `simple_color_shader`, `vao`, `vbo`.
- **Re-exports** (functions; valid via `pub const`):
  ```zig
  pub const renderQuad = ui_pipeline.fillQuad;
  pub const renderQuadAlpha = ui_pipeline.fillQuadAlpha;
  pub const setProjection = ui_pipeline.setProjection;
  ```
  So every existing `gl_init.renderQuad(...)` / `gl_init.shader_program` /
  `gl_init.vao` reference in the ~12 unconverted files keeps working unchanged.

`gl_init.initShaders` now links only `overlay_shader`. `ui_pipeline.init()`
replaces the moved `initBuffers`/`initSolidTexture`/instanced-shader setup for
the shared pipelines.

## 4. titlebar conversion + logic extraction

### Axis A — convert the three raw-`gl.*` functions
- `renderTitlebarChar`: grayscale branch → `ui_pipeline.drawGlyph(.{…}, uv,
  font.g_titlebar_atlas_texture, color)`; color branch → `ui_pipeline.drawColorGlyph(.{…},
  uv, font.g_color_atlas_texture, 1.0)`.
- `renderBellEmoji` → `ui_pipeline.drawColorGlyph(.{…}, uv, font.g_color_atlas_texture, opacity)`.
- `renderIconGlyph` → `ui_pipeline.drawGlyph(.{…}, uv, font.g_icon_atlas_texture, color)`.
- Remove titlebar's now-unused `const gl = AppWindow.gpu.glTable()` usages and
  the `@cImport("glad/gl.h")` block once no raw `gl.*`/`c.GL_*` remain.
- The 63 `gl_init.renderQuad` calls and the layout/draw orchestration in
  `renderTitlebar`/`renderSidebar`/`renderCaptionButton` are **unchanged**
  (renderQuad now primitive-backed via the re-export).

### Axis B — `titlebar_layout.zig` (new, std-only)
Extract the genuinely std-only-extractable pure helpers (geometry/measurement
with metrics passed as params; imports only `std`), registered in
`test_fast.zig`:
- `clampSidebarWidth(width, window_width, min, max) f32`
- `sidebarMaxWidthForWindow(window_width, fraction, cap) f32`
- `mouseInRect(px, py, left, top, width, height) bool`
- `mouseInTitlebarRange(mouse_x, titlebar_h, left, right, ...) bool` (pure form)
- `blend(a: [3]f32, b: [3]f32, t: f32) [3]f32`
- `fallbackCodepoint(byte: u8) u32`

**Per-function std-only check is part of the work**: any candidate whose inputs
pull in a heavy module is either lowered to a plain param type or left in
`titlebar.zig`. Specifically `agentBadgeColor(state)` depends on
`agent_detector.State` — extract it only if that enum is std-only-importable;
otherwise have it take a small local enum / leave it in `titlebar.zig`. The
font-dependent measurement (`titlebarTextWidth`, `collectTextCodepoints`,
`titlebarGlyphAdvance`) and the live-mouse wrappers stay in `titlebar.zig`;
`titlebar.zig` calls the extracted pure helpers (and keeps thin wrappers that
feed them `mouseX()`/font metrics). Unit tests cover: clamp bounds, max-width
fraction/cap, `mouseInRect` inside/edge/outside, `mouseInTitlebarRange`,
`blend` endpoints + midpoint, `fallbackCodepoint` mapping.

## 5. AppWindow wiring
- Add `pub const ui_pipeline = @import("renderer/ui_pipeline.zig");`.
- In init: call `ui_pipeline.init()` where the moved `gl_init.initBuffers()` /
  `initSolidTexture()` were, ordered before `cell_pipeline.init()` and before
  any draw. `gl_init.initShaders()` (now overlay-only) stays.
- In teardown: `ui_pipeline.deinit()` alongside the existing renderer deinits.

## 6. Verification
- `zig build` clean (x86_64-windows-gnu).
- `zig build test` includes the new `titlebar_layout` tests.
- `zig build test-full` stays green (current fully-green baseline + the new
  tests; no new failures).
- **Manual Windows visual check (final gate):** titlebar + sidebar render
  identically — tab strip, active/inactive shading, separators, `+` button,
  caption buttons (min/max/close), the bell emoji, fallback/menu/gear/help
  icons, agent badges, and placeholder tab. Behavior-preserving; any visual
  difference is a regression.

## 7. Risks
- **Compat-var population order.** `ui_pipeline.init()` must run before any file
  reads `gl_init.shader_program`/`vao`/`vbo` (i.e. before the first frame and
  before `cell_pipeline.init` if it depended on them — it does not). Mitigation:
  call `ui_pipeline.init()` at the same point the moved `initBuffers` ran.
- **Glyph/emoji draw parity.** `drawGlyph`/`drawColorGlyph` must reproduce the
  exact vertex order, uniform names (`textColor`, `opacity`, `projection`),
  texture targets, and — for emoji — the premultiplied-blend enter/restore. The
  helpers are extracted verbatim from the three titlebar functions +
  `renderChar`.
- **`renderQuadAlpha` alpha trick.** The blend-toward-`g_theme.background`
  behavior must be preserved exactly in `fillQuadAlpha`.
- **No automated render coverage.** Visual correctness rests on the manual
  Windows check; fast tests cover only the extracted `titlebar_layout` logic.
