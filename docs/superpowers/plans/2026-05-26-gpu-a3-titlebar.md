# GPU A3 increment 2 (shared ui_pipeline + titlebar) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the shared immediate-mode UI rendering (solid quad / text-glyph / color-emoji) out of `gl_init` into a primitives-backed `ui_pipeline.zig`, and convert `titlebar.zig` onto it + extract its pure layout logic.

**Architecture:** `ui_pipeline.zig` owns the text + emoji `gpu.Pipeline`s, the shared dynamic quad `gpu.Buffer`, and the 1×1 solid `gpu.Texture`, with **self-contained** draw helpers (each `use()`s its program + binds its VAO, so callers need no ambient GL state). `gl_init` keeps compat mirror vars (`shader_program`/`simple_color_shader`/`vao`/`vbo`, populated by `gl_init.syncSharedHandles()`) and re-exports `renderQuad`/`renderQuadAlpha`/`setProjection` to `ui_pipeline`, so the ~12 unconverted files are unchanged. titlebar's three raw-`gl.*` glyph/emoji functions route through the helpers; its pure logic moves to std-only `titlebar_layout.zig`.

**Tech Stack:** Zig 0.15.2, glad/OpenGL, FreeType. Target `x86_64-windows-gnu`. Tests: `zig build test` (fast), `zig build test-full` (pre-merge; currently fully green).

**Spec:** [docs/superpowers/specs/2026-05-26-gpu-a3-titlebar-design.md](../specs/2026-05-26-gpu-a3-titlebar-design.md)

---

## Conventions

- `ui_pipeline.zig` imports `AppWindow` only (for `gpu`, `g_theme`, and the draw-call counter via `AppWindow.gpu.gl_init.g_draw_call_count`). It does NOT import `gl_init` directly (avoids a new direct cycle). `gl_init` imports `ui_pipeline` (re-exports + sync).
- Helpers are **self-contained**: each `use()`s its pipeline and binds its VAO. This is a deliberate, behavior-equivalent refinement of the old ambient-state contract; it lets titlebar drop its frame-setup `UseProgram`/`BindVertexArray` lines.
- Behavior-preserving: vertex order, uniform names (`projection`, `textColor`, `opacity`), texture targets, and the color-emoji premultiplied-blend bookend are reproduced exactly.

---

## Task 1: `ui_pipeline.zig` (primitives-backed shared UI rendering)

**Files:**
- Create: `src/renderer/ui_pipeline.zig`

Additive: created but not yet wired in (Task 2 wires it and guts `gl_init`). `gl_init` still owns the live shared objects this task, so `ui_pipeline.init()` is unreferenced. Verified by a clean `zig build`.

- [ ] **Step 1: Create `src/renderer/ui_pipeline.zig`**

```zig
//! Shared UI render pipelines (solid quad / text-glyph / color-emoji), built
//! from the gpu backend primitives. Relocated out of gl_init (A3). gl_init keeps
//! compat mirror handles (set via gl_init.syncSharedHandles) + re-exports, so
//! the not-yet-converted renderer files are unchanged.
//!
//! Draw helpers are self-contained: each use()s its pipeline and binds its VAO,
//! so callers need no ambient GL program/VAO state.
const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const gpu = AppWindow.gpu;
const c = gpu.c;
const shaders = gpu.shaders;

const Pipeline = gpu.Pipeline;
const Buffer = gpu.Buffer;
const Texture = gpu.Texture;

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
pub const Uv = struct { u0: f32, v0: f32, u1: f32, v1: f32 };

pub threadlocal var text: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var emoji: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var quad: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var solid: Texture = .{ .handle = 0 };

fn drawCallTick() void {
    AppWindow.gpu.gl_init.g_draw_call_count += 1;
}

/// Build a VAO with the shared text/emoji vertex layout (one vec4 attrib:
/// xy = position, zw = texcoord), pointing at the shared quad buffer.
fn buildQuadVao() c.GLuint {
    const gl = gpu.glTable();
    var vao: c.GLuint = 0;
    gl.GenVertexArrays.?(1, &vao);
    gl.BindVertexArray.?(vao);
    quad.bind();
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 4, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    gl.BindVertexArray.?(0);
    return vao;
}

/// Build the shared pipelines, quad buffer, and solid texture. Call once after
/// the GL context is current (before any UI draw).
pub fn init() void {
    const gl = gpu.glTable();

    quad = Buffer.init(c.GL_ARRAY_BUFFER);
    quad.allocate(@sizeOf(f32) * 6 * 4, c.GL_DYNAMIC_DRAW);

    // Each pipeline owns its own VAO (identical layout) for clean deinit.
    const text_vao = buildQuadVao();
    const emoji_vao = buildQuadVao();
    text = Pipeline.init(shaders.vertex_shader_source, shaders.fragment_shader_source, text_vao);
    emoji = Pipeline.init(shaders.vertex_shader_source, shaders.simple_color_fragment_source, emoji_vao);
    if (text.program == 0) std.debug.print("UI text pipeline failed\n", .{});
    if (emoji.program == 0) std.debug.print("UI emoji pipeline failed\n", .{});

    var solid_handle: c.GLuint = 0;
    gl.GenTextures.?(1, &solid_handle);
    gl.BindTexture.?(c.GL_TEXTURE_2D, solid_handle);
    const white_pixel = [_]u8{255};
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RED, 1, 1, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &white_pixel);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    solid = Texture.fromHandle(solid_handle);
}

pub fn deinit() void {
    text.deinit();
    emoji.deinit();
    quad.deinit();
    if (solid.handle != 0) {
        gpu.glTable().DeleteTextures.?(1, &solid.handle);
        solid.handle = 0;
    }
}

fn quadVertices(rect: Rect, uv: Uv) [6][4]f32 {
    return .{
        .{ rect.x, rect.y + rect.h, uv.u0, uv.v0 },
        .{ rect.x, rect.y, uv.u0, uv.v1 },
        .{ rect.x + rect.w, rect.y, uv.u1, uv.v1 },
        .{ rect.x, rect.y + rect.h, uv.u0, uv.v0 },
        .{ rect.x + rect.w, rect.y, uv.u1, uv.v1 },
        .{ rect.x + rect.w, rect.y + rect.h, uv.u1, uv.v0 },
    };
}

/// Set the text pipeline's ortho projection (frame-level; = old gl_init.setProjection).
pub fn setProjection(width: f32, height: f32) void {
    const gl = gpu.glTable();
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };
    gl.UseProgram.?(text.program);
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(text.program, "projection"), 1, c.GL_FALSE, &projection);
}

pub fn fillQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    fillQuadAlpha(x, y, w, h, color, 1.0);
}

/// Solid color quad (= old gl_init.renderQuadAlpha). Preserves the alpha trick:
/// blends `color` toward g_theme.background by `alpha` and draws opaque via the
/// solid texture.
pub fn fillQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    const gl = gpu.glTable();
    const bg = AppWindow.g_theme.background;
    const r = color[0] * alpha + bg[0] * (1 - alpha);
    const g = color[1] * alpha + bg[1] * (1 - alpha);
    const b = color[2] * alpha + bg[2] * (1 - alpha);
    const verts = quadVertices(.{ .x = x, .y = y, .w = w, .h = h }, .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 });
    text.use();
    text.bindVao();
    gl.Uniform3f.?(gl.GetUniformLocation.?(text.program, "textColor"), r, g, b);
    solid.bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    drawCallTick();
}

/// Grayscale/text glyph via the text pipeline (atlas .r as alpha, modulated by color).
pub fn drawGlyph(rect: Rect, uv: Uv, tex: c.GLuint, color: [3]f32) void {
    const gl = gpu.glTable();
    const verts = quadVertices(rect, uv);
    text.use();
    text.bindVao();
    gl.Uniform3f.?(gl.GetUniformLocation.?(text.program, "textColor"), color[0], color[1], color[2]);
    Texture.fromHandle(tex).bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    drawCallTick();
}

/// Color-emoji via the emoji pipeline: premultiplied-alpha blend bookend +
/// per-call projection from the current viewport (= old renderBellEmoji /
/// renderTitlebarChar color branch).
pub fn drawColorGlyph(rect: Rect, uv: Uv, tex: c.GLuint, opacity: f32) void {
    const gl = gpu.glTable();
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const vp_w: f32 = @floatFromInt(viewport[2]);
    const vp_h: f32 = @floatFromInt(viewport[3]);
    const projection = [16]f32{
        2.0 / vp_w, 0.0,        0.0,  0.0,
        0.0,        2.0 / vp_h, 0.0,  0.0,
        0.0,        0.0,        -1.0, 0.0,
        -1.0,       -1.0,       0.0,  1.0,
    };
    const verts = quadVertices(rect, uv);
    emoji.use();
    emoji.bindVao();
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(emoji.program, "projection"), 1, c.GL_FALSE, &projection);
    gl.Uniform1f.?(gl.GetUniformLocation.?(emoji.program, "opacity"), opacity);
    gl.BlendFunc.?(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    Texture.fromHandle(tex).bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    drawCallTick();
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
}
```

- [ ] **Step 2: Build**

Run: `zig build`
Expected: success. `ui_pipeline` compiles but is unreferenced.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/ui_pipeline.zig
git commit -m "feat(gpu): ui_pipeline shared UI render module from primitives (unwired) [A3]"
```

---

## Task 2: Cutover — gut `gl_init` shared rendering, wire `ui_pipeline` in AppWindow

**Files:**
- Modify: `src/renderer/gpu/opengl/gl_init.zig`, `src/AppWindow.zig`

Atomic cutover: the shared GL objects now come from `ui_pipeline`; `gl_init` keeps compat mirror vars + re-exports so all ~12 unconverted files (and titlebar's 63 `renderQuad` calls) keep working unchanged.

- [ ] **Step 1: Edit `gl_init.zig` — remove moved bodies, keep compat vars, add re-exports + sync**

In `src/renderer/gpu/opengl/gl_init.zig`:

a) Keep these `pub threadlocal var`s as **compat mirror handles** (add a doc comment): `shader_program`, `simple_color_shader`, `vao`, `vbo`. Keep `overlay_shader`, `g_draw_call_count`, `g_bg_opacity`, `compileShader`, `linkProgram`, `setProjectionForProgram`.

b) Delete the `solid_texture` var and the bodies of `initBuffers`, `initSolidTexture`, `renderQuad`, `renderQuadAlpha`, `setProjection` (they move to `ui_pipeline`).

c) In `initShaders`, delete the `shader_program` link block and the `simple_color_shader` link; keep **only** the `overlay_shader` link. The function still returns `bool`:

```zig
pub fn initShaders() bool {
    overlay_shader = linkProgram(shaders.vertex_shader_source, shaders.overlay_fragment_source);
    if (overlay_shader == 0) {
        std.debug.print("Overlay shader failed\n", .{});
        return false;
    }
    return true;
}
```
(`linkProgram` fetches the GL table itself, so `initShaders` needs no local `gl`.)

d) Add the `ui_pipeline` import and the re-exports + sync near the top (after the existing imports):

```zig
const ui_pipeline = @import("../../ui_pipeline.zig");

pub fn renderQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    ui_pipeline.fillQuad(x, y, w, h, color);
}
pub fn renderQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    ui_pipeline.fillQuadAlpha(x, y, w, h, color, alpha);
}
pub fn setProjection(width: f32, height: f32) void {
    ui_pipeline.setProjection(width, height);
}
/// Populate the compat mirror handles from the ui_pipeline-owned objects.
/// Call right after ui_pipeline.init().
pub fn syncSharedHandles() void {
    shader_program = ui_pipeline.text.program;
    simple_color_shader = ui_pipeline.emoji.program;
    vao = ui_pipeline.text.vao;
    vbo = ui_pipeline.quad.handle;
}
```
(`gl_init` already imports `AppWindow`; keep that. The `gl_init`→`ui_pipeline` import is one-directional — `ui_pipeline` does not import `gl_init`.)

- [ ] **Step 2: Wire `ui_pipeline` into `AppWindow.zig`**

a) Add the module re-export near the other renderer re-exports:
```zig
pub const ui_pipeline = @import("renderer/ui_pipeline.zig");
```

b) Replace the init calls. Find `gpu.gl_init.initBuffers();` (≈line 3263) and `gpu.gl_init.initSolidTexture();` (≈line 3310). Remove the `initSolidTexture()` call and replace the `initBuffers()` line with:
```zig
    ui_pipeline.init();
    gpu.gl_init.syncSharedHandles();
```
Keep `gpu.gl_init.initShaders()` (now overlay-only) and `cell_pipeline.init()` where they are. Resulting order: `initShaders()` → `ui_pipeline.init()` + `syncSharedHandles()` → `cell_pipeline.init()`.

c) In teardown, add `ui_pipeline.deinit();` next to `cell_pipeline.deinit();` (≈line 3328).

- [ ] **Step 3: Verify no stale references to moved symbols**

```bash
grep -rn "gl_init\.initBuffers\|gl_init\.initSolidTexture\|gl_init\.solid_texture" src/
```
Expected: no output. (`gl_init.renderQuad`/`renderQuadAlpha`/`setProjection` still resolve — now re-export wrappers.)

- [ ] **Step 4: Build and test**

Run: `zig build`
Expected: success. If a comptime import-cycle error names `gl_init`/`ui_pipeline`, the cycle is the tolerated kind elsewhere in the tree; if it genuinely fails, break it by accessing the counter purely through `AppWindow.gpu.gl_init` (already the case) and confirming `ui_pipeline` has no top-level `gl_init` reference.

Run: `zig build test-full`
Expected: stays green (current fully-green baseline; the weixin `group_message` skip is the only skip). No new failures.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(gpu): move shared UI rendering to ui_pipeline; gl_init keeps compat shim [A3]"
```

---

## Task 3: Convert titlebar's raw-GL glyph/emoji through `ui_pipeline` (Axis A)

**Files:**
- Modify: `src/renderer/titlebar.zig`

Convert the three raw-`gl.*` functions to `ui_pipeline` helpers and drop titlebar's frame-setup `UseProgram`/`BindVertexArray` lines (the self-contained helpers make them unnecessary), so titlebar ends with no raw `gl.*` and no glad `@cImport`.

- [ ] **Step 1: Add the `ui_pipeline` import**

In `src/renderer/titlebar.zig`, near the imports:
```zig
const ui_pipeline = AppWindow.ui_pipeline;
```

- [ ] **Step 2: Convert `renderTitlebarChar` (≈lines 294-373)**

Replace the whole function body's two branches with helper calls (keep the early returns + the glyph metric/UV computation; replace the GL emission):

```zig
pub fn renderTitlebarChar(codepoint: u32, x: f32, y: f32, color: [3]f32) void {
    if (codepoint < 32) return;
    const ch: Character = font.loadTitlebarGlyph(codepoint) orelse return;
    if (ch.region.width == 0 or ch.region.height == 0) return;

    if (ch.is_color) {
        const scale = font.g_titlebar_cell_height / @as(f32, @floatFromInt(ch.size_y));
        const w = @as(f32, @floatFromInt(ch.size_x)) * scale;
        const h = @as(f32, @floatFromInt(ch.size_y)) * scale;
        const atlas_size = if (font.g_color_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
        const uv = font.glyphUV(ch.region, atlas_size);
        ui_pipeline.drawColorGlyph(
            .{ .x = x, .y = y, .w = w, .h = h },
            .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
            font.g_color_atlas_texture,
            1.0,
        );
    } else {
        const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
        const y0 = y + font.g_titlebar_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
        const w = @as(f32, @floatFromInt(ch.size_x));
        const h = @as(f32, @floatFromInt(ch.size_y));
        const atlas_size = if (font.g_titlebar_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
        const uv = font.glyphUV(ch.region, atlas_size);
        ui_pipeline.drawGlyph(
            .{ .x = x0, .y = y0, .w = w, .h = h },
            .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
            font.g_titlebar_atlas_texture,
            color,
        );
    }
}
```

- [ ] **Step 3: Convert `renderBellEmoji` (≈lines 392-444)**

Replace its GL emission with `drawColorGlyph` (keep the bell load/fallback + sizing):

```zig
pub fn renderBellEmoji(x: f32, y: f32, opacity: f32) void {
    const bell = font.loadBellEmoji() orelse {
        renderTitlebarChar(0x1F514, x, y, .{ 1.0, 0.84, 0.0 });
        return;
    };
    const aspect = bell.bmp_w / bell.bmp_h;
    const h = font.g_titlebar_cell_height * 0.85;
    const w = h * aspect;
    const atlas_size = if (font.g_color_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = font.glyphUV(bell.region, atlas_size);
    ui_pipeline.drawColorGlyph(
        .{ .x = x, .y = y, .w = w, .h = h },
        .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
        font.g_color_atlas_texture,
        opacity,
    );
}
```

- [ ] **Step 4: Convert `renderIconGlyph` (≈lines 447-475)**

```zig
pub fn renderIconGlyph(ch: Character, btn_x: f32, btn_y: f32, btn_w: f32, btn_h: f32, color: [3]f32, scale: f32) void {
    if (ch.region.width == 0 or ch.region.height == 0) return;
    const gw = @as(f32, @floatFromInt(ch.size_x)) * scale;
    const gh = @as(f32, @floatFromInt(ch.size_y)) * scale;
    const gx = btn_x + (btn_w - gw) / 2;
    const gy = btn_y + (btn_h - gh) / 2;
    const icon_atlas_size = if (font.g_icon_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = font.glyphUV(ch.region, icon_atlas_size);
    ui_pipeline.drawGlyph(
        .{ .x = gx, .y = gy, .w = gw, .h = gh },
        .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
        font.g_icon_atlas_texture,
        color,
    );
}
```

- [ ] **Step 5: Remove the frame-setup `UseProgram`/`BindVertexArray` lines + now-unused `gl`/`c`**

In `renderTitlebar` (≈494/496), `renderSidebar` (≈1070/1072), `renderPlaceholderTab` (≈1326/1328): delete the two lines
```zig
    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);
```
(the self-contained helpers and `gl_init.renderQuad` now bind their own program/VAO). Then in each of these three functions, and in the three converted functions above, remove the now-unused `const gl = AppWindow.gpu.glTable();` line. Finally remove the file's glad cImport block:
```zig
const c = @cImport({
    @cInclude("glad/gl.h");
});
```
if `grep -n "\bc\.\|\bgl\." src/renderer/titlebar.zig` shows no remaining raw `gl.`/`c.GL` uses. (Keep the `gl_init` import — `gl_init.renderQuad` and `gl_init.g_draw_call_count` may still be referenced.)

- [ ] **Step 6: Verify titlebar has no raw GL left**

```bash
grep -nE "\bgl\.[A-Z]|@cInclude\(\"glad" src/renderer/titlebar.zig
```
Expected: no output.

- [ ] **Step 7: Build and test**

Run: `zig build`
Expected: success (watch for an unused-`const gl`/`const c` error — remove whichever is unused).

Run: `zig build test-full`
Expected: green baseline, no new failures.

- [ ] **Step 8: Commit**

```bash
git add src/renderer/titlebar.zig
git commit -m "refactor(titlebar): route glyph/emoji draws through ui_pipeline; drop raw GL [A3]"
```

---

## Task 4: Extract titlebar pure logic → `titlebar_layout.zig` (Axis B)

**Files:**
- Create: `src/renderer/titlebar_layout.zig`
- Modify: `src/renderer/titlebar.zig`, `src/test_fast.zig`

- [ ] **Step 1: Create `src/renderer/titlebar_layout.zig` (std-only) with tests**

```zig
//! Pure, std-only titlebar/sidebar geometry + measurement helpers extracted
//! from titlebar.zig. No AppWindow/font/GL imports — runs in the fast suite.
const std = @import("std");

/// Is point (px, py) inside the rect [left, left+width) x [top, top+height)?
pub fn pointInRect(px: f32, py: f32, left: f32, top: f32, width: f32, height: f32) bool {
    return px >= left and px < left + width and py >= top and py < top + height;
}

/// Linear blend of two RGB colors; t clamped to [0,1].
pub fn blend(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

/// Max sidebar width for a window, given the bounds.
pub fn sidebarMaxWidthForWindow(window_width: f32, min_width: f32, max_width: f32, min_content_width: f32) f32 {
    return @max(min_width, @min(max_width, window_width - min_content_width));
}

/// Clamp a requested sidebar width to [min_width, max_for_window].
pub fn clampSidebarWidth(width: f32, max_for_window: f32, min_width: f32) f32 {
    return @max(min_width, @min(max_for_window, width));
}

/// Printable-ASCII passthrough, else '?'.
pub fn fallbackCodepoint(byte: u8) u32 {
    return if (byte >= 0x20 and byte <= 0x7e) byte else '?';
}

test "pointInRect inside / edges / outside" {
    try std.testing.expect(pointInRect(5, 5, 0, 0, 10, 10));
    try std.testing.expect(pointInRect(0, 0, 0, 0, 10, 10)); // top-left inclusive
    try std.testing.expect(!pointInRect(10, 5, 0, 0, 10, 10)); // right exclusive
    try std.testing.expect(!pointInRect(5, 10, 0, 0, 10, 10)); // bottom exclusive
    try std.testing.expect(!pointInRect(-1, 5, 0, 0, 10, 10));
}

test "blend endpoints and midpoint" {
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 1, 1, 1 };
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, blend(a, b, 0));
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, blend(a, b, 1));
    try std.testing.expectEqual([3]f32{ 0.5, 0.5, 0.5 }, blend(a, b, 0.5));
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, blend(a, b, 2)); // t clamped
}

test "sidebarMaxWidthForWindow respects bounds" {
    // window roomy: capped by max_width
    try std.testing.expectEqual(@as(f32, 720), sidebarMaxWidthForWindow(2000, 160, 720, 240));
    // window tight: capped by window_width - min_content
    try std.testing.expectEqual(@as(f32, 360), sidebarMaxWidthForWindow(600, 160, 720, 240));
    // window very tight: floored at min_width
    try std.testing.expectEqual(@as(f32, 160), sidebarMaxWidthForWindow(300, 160, 720, 240));
}

test "clampSidebarWidth bounds" {
    try std.testing.expectEqual(@as(f32, 160), clampSidebarWidth(50, 720, 160));
    try std.testing.expectEqual(@as(f32, 720), clampSidebarWidth(900, 720, 160));
    try std.testing.expectEqual(@as(f32, 300), clampSidebarWidth(300, 720, 160));
}

test "fallbackCodepoint maps printable ASCII, else '?'" {
    try std.testing.expectEqual(@as(u32, 'A'), fallbackCodepoint('A'));
    try std.testing.expectEqual(@as(u32, '?'), fallbackCodepoint(0x07));
    try std.testing.expectEqual(@as(u32, '?'), fallbackCodepoint(0xC3));
}
```

- [ ] **Step 2: Point titlebar's helpers at the extracted logic**

In `src/renderer/titlebar.zig`, add the import:
```zig
const titlebar_layout = @import("titlebar_layout.zig");
```
Then rewrite the wrappers to delegate (keep the same titlebar-facing signatures):
- `blend` → `return titlebar_layout.blend(a, b, t);`
- `fallbackCodepoint` → `return titlebar_layout.fallbackCodepoint(byte);`
- `sidebarMaxWidthForWindow(window_width)` → `return titlebar_layout.sidebarMaxWidthForWindow(window_width, SIDEBAR_MIN_WIDTH, SIDEBAR_MAX_WIDTH, SIDEBAR_MIN_CONTENT_WIDTH);`
- `clampSidebarWidth(width, window_width)` → `return titlebar_layout.clampSidebarWidth(width, sidebarMaxWidthForWindow(window_width), SIDEBAR_MIN_WIDTH);`
- `mouseInRect(left, top, width, height)`: keep the mouse-fetch + negative guard, then `return titlebar_layout.pointInRect(@floatFromInt(mouse.x), @floatFromInt(mouse.y), left, top, width, height);`

Leave `agentBadgeColor` in `titlebar.zig` (its `agent_detector.State` input is not std-only). Leave `setSidebarWidth`, `titlebarTextWidth`, `collectTextCodepoints`, `titlebarGlyphAdvance`, `mouseInTitlebarRange` in `titlebar.zig` (they call the wrappers / depend on font/mouse).

- [ ] **Step 3: Register in the fast suite**

In `src/test_fast.zig`, inside the `test { ... }` block:
```zig
    _ = @import("renderer/titlebar_layout.zig");
```

- [ ] **Step 4: Run tests + build**

Run: `zig build test`
Expected: PASS (the new `titlebar_layout` tests run).

Run: `zig build`
Expected: success.

Run: `zig build test-full`
Expected: green baseline + the new tests, no new failures.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/titlebar_layout.zig src/renderer/titlebar.zig src/test_fast.zig
git commit -m "refactor(titlebar): extract std-only titlebar_layout logic + tests [A3]"
```

---

## Task 5: Docs + final verification

**Files:**
- Modify: `TODO.md`, `docs/decoupling-guide.md`

- [ ] **Step 1: Note progress in `TODO.md`**

Under Phase A item **A3**, extend the "Increment 1 done" note: increment 2 converted `titlebar` and introduced the shared `ui_pipeline.zig` (solid/text/emoji rendering on primitives) with `gl_init` keeping compat mirror handles + re-exports for the still-unconverted files; titlebar pure logic extracted to std-only `titlebar_layout.zig`. Remaining: overlays, ai_chat_renderer, file_explorer, scrollbar, image_renderer, fbo, background_image, markdown_preview; the compat shim dissolves as they convert.

- [ ] **Step 2: Status line in `docs/decoupling-guide.md` §5 Phase A**

Add a short note that A3 increment 2 landed (shared `ui_pipeline` + titlebar; compat-shim strategy).

- [ ] **Step 3: Final verification**

Run: `zig build test-full`
Expected: green baseline.

Run: `zig build`
Expected: clean `phantty.exe`.

- [ ] **Step 4: Request the manual Windows visual check**

Ask the maintainer to run `phantty.exe` on Windows and confirm the titlebar + sidebar render identically: tab strip (active/inactive shading + separators), `+` button, caption buttons (minimize/maximize/close icons), the bell emoji, fallback/menu/gear/help icons, agent badges, sidebar rows/header, and the placeholder tab. Behavior-preserving; any visual difference is a regression.

- [ ] **Step 5: Commit**

```bash
git add TODO.md docs/decoupling-guide.md
git commit -m "docs(gpu): note A3 increment 2 (shared ui_pipeline + titlebar)"
```

---

## Self-review notes (resolved)

- **Spec coverage:** §2 ui_pipeline → Task 1; §3 gl_init compat shim + re-exports → Task 2; §4 titlebar Axis A → Task 3, Axis B (`titlebar_layout`) → Task 4; §5 AppWindow wiring → Task 2; §6 verification → Task 5. `agentBadgeColor` left in titlebar per the spec's std-only caveat.
- **Self-contained helpers** (use+bindVao) are the one intentional refinement vs. the old ambient-state contract; it is behavior-equivalent (same program/VAO/pixels) and is what lets titlebar drop its frame-setup lines (Task 3 Step 5). Flagged for the manual visual check.
- **Type consistency:** `Rect{x,y,w,h}` and `Uv{u0,v0,u1,v1}` literals at the titlebar call sites (Task 3) match the `ui_pipeline` definitions (Task 1). `fillQuad`/`fillQuadAlpha`/`drawGlyph`/`drawColorGlyph`/`setProjection`/`init`/`deinit`/`syncSharedHandles` names are consistent across Tasks 1–3. `titlebar_layout.{pointInRect,blend,sidebarMaxWidthForWindow,clampSidebarWidth,fallbackCodepoint}` match Task 4's wrappers.
- **Atomicity:** Task 2 is one commit (the shared-rendering cutover: gl_init + AppWindow must change together to keep the build green); the ~12 unconverted files rely on the compat vars + re-exports and are untouched.
- **Cycle:** `gl_init`→`ui_pipeline` is one-directional; `ui_pipeline` reaches the draw counter via `AppWindow.gpu.gl_init` (the pre-existing AppWindow cycle), so no new direct cycle. Fallback noted in Task 2 Step 4.
