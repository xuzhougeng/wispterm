# Design: GPU Phase A3 — primitives + cell_renderer (increment 1)

Status: approved (design); pending spec review
Date: 2026-05-26
Scope: TODO.md Phase A item **A3**, first increment only
References: [decoupling-guide.md](../../decoupling-guide.md) §2/§5, prior spec
`2026-05-26-gpu-backend-spine-a1-a2-design.md`. Ghostty: `renderer/opengl/`
(`Buffer`/`Texture`/`Pipeline`), API-agnostic `renderer/cell.zig`.

## 1. Goal & scope

Replace the empty `Buffer`/`Texture`/`Pipeline` stubs in `gpu/opengl/` with real
primitive types, then convert `cell_renderer.zig` as the proving ground —
**both decoupling axes in one pass** (the guide's "touch each file once"):

- **Axis A (presentation):** route `drawCells`' draw path through the new
  primitives instead of raw `gl.*` + `gl_init` global handles.
- **Axis B (logic):** extract the pure snap→instance decision/math + the
  instance data types into a std-only, unit-tested module.

### Non-goals (deferred)

- The `Frame`/`RenderPass`/`Target` layer (manages FBO binds, will carry
  Metal's command encoder) — lands when the FBO/compositing path is converted.
- The **shared** pipelines `shader_program`, `overlay_shader`,
  `simple_color_shader` (used by titlebar/overlays/etc.) stay in `gl_init` until
  those files are converted in later A3 increments.
- The other 9 A3 renderer files; A4 (font atlas → `Texture` ownership/upload);
  A5 (MSL); A6 (guards); Metal backend.
- `Texture` upload/ownership: the font atlas textures remain owned by `font/`;
  this increment only *wraps existing handles* for binding.

### Decisions locked (from brainstorming)

- **Primitives are pragmatic**, Ghostty-named, growing toward the full
  hierarchy later (no `Frame`/`RenderPass`/`Step` now).
- **§2 vertex layout: caller-built VAO.** `Pipeline` holds `program` + `vao` and
  drives use/uniform/draw; the per-shader `VertexAttribPointer`/`Divisor` setup
  relocates verbatim into the cell pipeline builder.
- **§4 logic split: pure pieces only.** Extract the instance data types + the
  BG/cursor/selection decision + the glyph-rect math. The impure glyph lookup
  (`font.loadGlyph`/`loadGraphemeGlyph`/`isRegionalIndicator`) stays in
  `cell_renderer`.

## 2. Generic primitives — `src/renderer/gpu/opengl/`

Thin wrappers over GL handles, each calling `Context.gl.*`. Re-exported through
`api.zig` → `gpu.zig` (`pub const Buffer/Texture/Pipeline = impl.…`), replacing
today's `struct {}` stubs.

### `Buffer.zig` — a VBO
```zig
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const Buffer = @This();

handle: c.GLuint = 0,
target: c.GLenum,

pub fn init(target: c.GLenum) Buffer {
    var b = Buffer{ .target = target };
    Context.gl.GenBuffers.?(1, &b.handle);
    return b;
}
pub fn bind(self: Buffer) void { Context.gl.BindBuffer.?(self.target, self.handle); }
pub fn allocate(self: Buffer, size: usize, usage: c.GLenum) void {
    self.bind();
    Context.gl.BufferData.?(self.target, @intCast(size), null, usage);
}
pub fn uploadData(self: Buffer, bytes: []const u8, usage: c.GLenum) void {
    self.bind();
    Context.gl.BufferData.?(self.target, @intCast(bytes.len), bytes.ptr, usage);
}
pub fn upload(self: Buffer, bytes: []const u8) void { // BufferSubData at offset 0
    self.bind();
    Context.gl.BufferSubData.?(self.target, 0, @intCast(bytes.len), bytes.ptr);
}
pub fn deinit(self: *Buffer) void {
    if (self.handle != 0) { Context.gl.DeleteBuffers.?(1, &self.handle); self.handle = 0; }
}
```

### `Texture.zig` — wraps an existing handle (font owns the atlas; A4 takes over)
```zig
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const Texture = @This();

handle: c.GLuint,

pub fn fromHandle(h: c.GLuint) Texture { return .{ .handle = h }; }
pub fn bind(self: Texture, unit: u32) void {
    Context.gl.ActiveTexture.?(c.GL_TEXTURE0 + unit);
    Context.gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
}
```

### `Pipeline.zig` — program + VAO
```zig
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const Pipeline = @This();

program: c.GLuint,
vao: c.GLuint,

pub fn use(self: Pipeline) void { Context.gl.UseProgram.?(self.program); }
pub fn bindVao(self: Pipeline) void { Context.gl.BindVertexArray.?(self.vao); }
pub fn setVec2(self: Pipeline, name: [*c]const u8, x: f32, y: f32) void {
    Context.gl.Uniform2f.?(Context.gl.GetUniformLocation.?(self.program, name), x, y);
}
pub fn setFloat(self: Pipeline, name: [*c]const u8, v: f32) void {
    Context.gl.Uniform1f.?(Context.gl.GetUniformLocation.?(self.program, name), v);
}
pub fn setInt(self: Pipeline, name: [*c]const u8, v: i32) void {
    Context.gl.Uniform1i.?(Context.gl.GetUniformLocation.?(self.program, name), v);
}
pub fn drawArraysInstanced(self: Pipeline, mode: c.GLenum, first: c.GLint, count: c.GLsizei, instances: c.GLsizei) void {
    Context.gl.DrawArraysInstanced.?(mode, first, count, instances);
}
pub fn deinit(self: *Pipeline) void {
    if (self.program != 0) Context.gl.DeleteProgram.?(self.program);
    if (self.vao != 0) Context.gl.DeleteVertexArrays.?(1, &self.vao);
    self.* = .{ .program = 0, .vao = 0 };
}
```

Shader compile/link (`compileShader`, `linkProgram`) is reused from `gl_init`
(or exposed as a small `Pipeline.link(vertex_src, fragment_src)` helper). The
projection-matrix uniform is set via the existing `gl_init.setProjectionForProgram`
behavior, preserved as a `Pipeline.setProjection`-style call in the cell builder.

## 3. Cell pipelines — `src/renderer/cell_pipeline.zig` (new, cell-owned)

The `bg`/`fg`/`color_fg` instanced triples currently built in
`gl_init.initInstancedBuffers` move here (cell-specific presentation), built from
the §2 primitives + the GLSL already in `gpu/opengl/shaders.zig`. This module owns:

- `bg`, `fg`, `color_fg`: `Pipeline` (program + VAO; VAO attribs set here,
  relocated verbatim from `initInstancedBuffers` — `CellBg` is attr0 quad + attr1
  grid vec2 + attr2 rgb vec3 + attr3 alpha; `CellFg` is attr0 quad + attr1 grid +
  attr2 glyphRect vec4 + attr3 uv vec4 + attr4 rgb, instance attrs `divisor 1`).
- `bg_instances`, `fg_instances`, `color_fg_instances`: `Buffer`
  (`GL_ARRAY_BUFFER`, pre-allocated `@sizeOf(Cell*) * MAX_CELLS`, `STREAM_DRAW`).
- `quad`: a shared unit-quad `Buffer` (`STATIC_DRAW`).
- `init()` (build all), `deinit()` (tear down).

`drawCells` then issues each pass through these (BG shown; FG/color_fg mirror it
with their texture bind + the color_fg blend-mode switch preserved exactly):
```zig
if (rend.bg_cell_count > 0) {
    const p = cell_pipeline.bg;
    p.use();
    p.setVec2("cellSize", font.cell_width, font.cell_height);
    p.setVec2("gridOffset", offset_x, offset_y);
    p.setFloat("windowHeight", window_height);
    cell_pipeline.setProjection(p, window_height);
    p.bindVao();
    cell_pipeline.bg_instances.upload(std.mem.sliceAsBytes(rend.bg_cells.items[0..rend.bg_cell_count]));
    p.drawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(rend.bg_cell_count));
    gl_init.g_draw_call_count += 1;
}
```
The cursor-overlay block in `drawCells` (lines 473-503) uses the *shared*
`shader_program`/`vao` + `renderQuad`, which stay in `gl_init` this increment —
that block is left untouched. `image_renderer.draw(...)` calls are likewise
untouched.

`gl_init.initInstancedBuffers`, `deinitInstancedResources`, and the
`bg_shader`/`fg_shader`/`color_fg_shader`/`*_vao`/`*_instance_vbo` globals are
removed; their callers (init/teardown in `AppWindow`) call
`cell_pipeline.init()`/`deinit()` instead. `g_draw_call_count`/`g_bg_opacity`
stay in `gl_init` (shared).

## 4. Cell geometry — `src/renderer/cell_geometry.zig` (new, std-only)

Holds the pure, testable pieces. **std-only**: imports only `std` (no
`AppWindow`/`font`/GL), so it runs in the fast suite.

### Data types (relocated from `Renderer.zig`)
`CellBg`, `CellFg`, `SnapCell` (plain `extern struct`/`struct`) move here;
`Renderer.zig` re-imports them (`pub const CellBg = cell_geometry.CellBg;` …) so
existing references keep working. `MAX_GRAPHEME` moves with `SnapCell`.

### Pure functions
```zig
pub const Rgb = [3]f32;

pub const ThemeColors = struct {
    background: Rgb,
    cursor_text: ?Rgb,
    selection_background: Rgb,
    selection_foreground: ?Rgb,
    foreground: Rgb,
};

/// The BG/cursor/selection decision (cell_renderer lines 257-286).
pub fn backgroundFor(
    cell_bg: ?Rgb,
    is_cursor: bool,
    cursor_visible: bool,
    cursor_is_block: bool,
    is_selected: bool,
    theme: ThemeColors,
    grid_col: f32,
    grid_row: f32,
    normal_bg_alpha: f32,
    base_fg: Rgb,
) struct { bg: ?CellBg, fg: Rgb } { … }

pub const GlyphRect = struct { gx: f32, gy: f32, gw: f32, gh: f32 };

/// Grayscale glyph rect math (cell_renderer lines 369-373). Returns only the
/// position/size rect; the UV is computed by `font.glyphUV` in cell_renderer
/// (it depends on atlas state) and assembled into the CellFg there.
pub fn grayscaleGlyphRect(bearing_x: i32, bearing_y: i32, size_x: u32, size_y: u32, cell_baseline: f32) GlyphRect { … }

/// Color-emoji aspect-fit + centering (cell_renderer lines 339-348). Returns
/// only the rect; UV comes from `font.glyphUV` in cell_renderer.
pub fn colorEmojiRect(size_x: u32, size_y: u32, grid_width: f32, cell_w: f32, cell_h: f32) GlyphRect { … }
```

### What stays in `cell_renderer.rebuildCells` (impure orchestration)
The row/col walk; `font.loadGlyph`/`loadGraphemeGlyph`/`isRegionalIndicator`
lookups; `font.glyphUV` (atlas-coord computation — depends on atlas state);
spacer/placeholder/RI skipping; `image_renderer.uploadPending`. It now reads:
walk → `backgroundFor(...)` → font glyph lookup → `grayscaleGlyphRect` /
`colorEmojiRect` (+ `font.glyphUV`) → append.

### Unit tests (registered in `src/test_fast.zig`)
- `backgroundFor`: plain cell (bg present → one bg instance at grid coords,
  fg unchanged); selected cell (selection bg opaque alpha=1.0, fg = selection
  fg); cursor-block (fg → cursor_text orelse background, bg drawn normally);
  no bg + not cursor/selected (no bg instance).
- `grayscaleGlyphRect`: bearing/baseline math for a known glyph.
- `colorEmojiRect`: aspect-fit scale + centering for wide vs narrow.

## 5. Verification

- `zig build` clean (x86_64-windows-gnu).
- `zig build test` includes the new `cell_geometry` tests (green).
- `zig build test-full` at baseline (497/499; 1 pre-existing Windows-only
  failure, 1 skip) — no new failures.
- **Manual Windows visual check (final gate):** terminal grid renders
  identically — text, fg/bg colors, background-image alpha, selection
  highlight, block/bar/underline/hollow cursor, and color emoji. This is a
  behavior-preserving change; any visual difference is a regression.

## 6. Risks

- **Pipeline construction parity.** The relocated VAO attrib setup must match
  `initInstancedBuffers` byte-for-byte (offsets, divisors, strides) or the grid
  renders wrong. Mitigation: relocate verbatim; diff against the original.
- **`color_fg` blend-mode switch.** `drawCells` flips to
  `(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)` for the emoji pass then restores
  `(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)`. Must be preserved exactly around the
  `color_fg` draw.
- **Shared-vs-cell pipeline split.** Removing only `bg`/`fg`/`color_fg` from
  `gl_init` while leaving the shared ones requires confirming no other file
  references the removed globals (grep before removal). The cursor overlay in
  `drawCells` still uses the shared `shader_program`/`vao` — left intact.
- **No automated render coverage.** Correctness of the visual result rests on
  the manual Windows check; the fast tests only cover the extracted pure logic.
