# GPU A3 increment 1 (primitives + cell_renderer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the empty `Buffer`/`Texture`/`Pipeline` stubs in `gpu/opengl/` with real primitive types and convert `cell_renderer.zig` to use them, while extracting its pure cell-geometry logic into a std-only, unit-tested module.

**Architecture:** Pragmatic Ghostty-shaped primitives (thin GL wrappers; no `Frame`/`RenderPass` yet). The cell-specific `bg`/`fg`/`color_fg` instanced pipelines move out of the shared `gl_init` into a cell-owned `cell_pipeline.zig` built from the primitives; `drawCells` routes through them with byte-identical GL ops. The pure snap→instance decision + glyph-rect math + instance data types move into `cell_geometry.zig` (std-only, fast-suite tested). Behavior-preserving — verified by the green baseline plus a manual Windows visual check.

**Tech Stack:** Zig 0.15.2, glad/OpenGL, FreeType. Target `x86_64-windows-gnu`. Tests: `zig build test` (fast), `zig build test-full` (pre-merge, baseline 497/499).

**Spec:** [docs/superpowers/specs/2026-05-26-gpu-a3-cell-renderer-design.md](../specs/2026-05-26-gpu-a3-cell-renderer-design.md)

---

## Conventions

- All primitives call `Context.gl.*` (the GL table in `gpu/opengl/Context.zig`). `c` is `@import("c.zig").c`.
- `cell_geometry.zig` is **std-only** (imports only `std`) so it runs in `zig build test`. It must never import `AppWindow`/`font`/GL.
- Behavior-preserving: do not change GL call order, arguments, blend modes, or shader text. The relocated VAO attribute setup must match `initInstancedBuffers` exactly (offsets/divisors/strides).

---

## Task 1: Generic primitives — `Buffer` / `Texture` / `Pipeline`

**Files:**
- Create: `src/renderer/gpu/opengl/Buffer.zig`, `src/renderer/gpu/opengl/Texture.zig`, `src/renderer/gpu/opengl/Pipeline.zig`
- Modify: `src/renderer/gpu/opengl/api.zig`, `src/renderer/gpu/gpu.zig`

These are thin GL wrappers; they cannot be unit-tested without a live GL context, so this task is verified by `zig build` (they are exercised at runtime in Task 5 + the manual check).

- [ ] **Step 1: Create `src/renderer/gpu/opengl/Buffer.zig`**

```zig
//! A GPU buffer (OpenGL VBO). Backend primitive for the GraphicsAPI spine.
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
pub fn bind(self: Buffer) void {
    Context.gl.BindBuffer.?(self.target, self.handle);
}
/// Allocate `size` bytes of uninitialized storage with the given usage hint.
pub fn allocate(self: Buffer, size: usize, usage: c.GLenum) void {
    self.bind();
    Context.gl.BufferData.?(self.target, @intCast(size), null, usage);
}
/// Allocate + fill with `bytes`.
pub fn uploadData(self: Buffer, bytes: []const u8, usage: c.GLenum) void {
    self.bind();
    Context.gl.BufferData.?(self.target, @intCast(bytes.len), bytes.ptr, usage);
}
/// Overwrite from offset 0 (glBufferSubData).
pub fn upload(self: Buffer, bytes: []const u8) void {
    self.bind();
    Context.gl.BufferSubData.?(self.target, 0, @intCast(bytes.len), bytes.ptr);
}
pub fn deinit(self: *Buffer) void {
    if (self.handle != 0) {
        Context.gl.DeleteBuffers.?(1, &self.handle);
        self.handle = 0;
    }
}
```

- [ ] **Step 2: Create `src/renderer/gpu/opengl/Texture.zig`**

```zig
//! A 2D GPU texture. This increment wraps an existing handle for binding only;
//! ownership/upload of the font atlas is taken over in A4.
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const Texture = @This();

handle: c.GLuint,

pub fn fromHandle(h: c.GLuint) Texture {
    return .{ .handle = h };
}
pub fn bind(self: Texture, unit: u32) void {
    Context.gl.ActiveTexture.?(c.GL_TEXTURE0 + unit);
    Context.gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
}
```

- [ ] **Step 3: Create `src/renderer/gpu/opengl/Pipeline.zig`**

```zig
//! A render pipeline (OpenGL program + VAO). The vertex-attribute layout is
//! built by the caller (it is shader-specific) and the VAO handle handed in.
const std = @import("std");
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const Pipeline = @This();

program: c.GLuint,
vao: c.GLuint,

/// Compile a shader stage. Returns null on failure (logs to stderr).
pub fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    const gl = Context.gl;
    const shader = gl.CreateShader.?(shader_type);
    if (shader == 0) {
        const gl_err = if (gl.GetError) |getErr| getErr() else 0;
        std.debug.print("Shader error: glCreateShader returned 0, type=0x{X}, glError=0x{X}\n", .{ shader_type, gl_err });
        return null;
    }
    gl.ShaderSource.?(shader, 1, &source, null);
    gl.CompileShader.?(shader);
    var success: c.GLint = 0;
    gl.GetShaderiv.?(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetShaderInfoLog.?(shader, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) {
            std.debug.print("Shader compilation failed: {s}\n", .{info_log[0..len]});
        } else {
            std.debug.print("Shader compilation failed (no error log, shader={})\n", .{shader});
        }
        gl.DeleteShader.?(shader);
        return null;
    }
    return shader;
}

/// Compile + link a program from vertex/fragment sources. Returns 0 on failure.
pub fn linkProgram(vs_src: [*c]const u8, fs_src: [*c]const u8) c.GLuint {
    const gl = Context.gl;
    const vs = compileShader(c.GL_VERTEX_SHADER, vs_src) orelse return 0;
    defer gl.DeleteShader.?(vs);
    const fs = compileShader(c.GL_FRAGMENT_SHADER, fs_src) orelse return 0;
    defer gl.DeleteShader.?(fs);
    const prog = gl.CreateProgram.?();
    gl.AttachShader.?(prog, vs);
    gl.AttachShader.?(prog, fs);
    gl.LinkProgram.?(prog);
    var success: c.GLint = 0;
    gl.GetProgramiv.?(prog, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetProgramInfoLog.?(prog, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) std.debug.print("Shader link failed: {s}\n", .{info_log[0..len]});
        gl.DeleteProgram.?(prog);
        return 0;
    }
    return prog;
}

pub fn use(self: Pipeline) void {
    Context.gl.UseProgram.?(self.program);
}
pub fn bindVao(self: Pipeline) void {
    Context.gl.BindVertexArray.?(self.vao);
}
pub fn setVec2(self: Pipeline, name: [*c]const u8, x: f32, y: f32) void {
    Context.gl.Uniform2f.?(Context.gl.GetUniformLocation.?(self.program, name), x, y);
}
pub fn setFloat(self: Pipeline, name: [*c]const u8, v: f32) void {
    Context.gl.Uniform1f.?(Context.gl.GetUniformLocation.?(self.program, name), v);
}
pub fn setInt(self: Pipeline, name: [*c]const u8, v: i32) void {
    Context.gl.Uniform1i.?(Context.gl.GetUniformLocation.?(self.program, name), v);
}
/// Set the orthographic projection uniform from the current viewport.
/// `window_height` is accepted for call-site parity but unused (matches the
/// previous gl_init.setProjectionForProgram behavior).
pub fn setProjection(self: Pipeline, window_height: f32) void {
    const gl = Context.gl;
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const width: f32 = @floatFromInt(viewport[2]);
    const height: f32 = @floatFromInt(viewport[3]);
    _ = window_height;
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(self.program, "projection"), 1, c.GL_FALSE, &projection);
}
pub fn drawArraysInstanced(self: Pipeline, mode: c.GLenum, first: c.GLint, count: c.GLsizei, instances: c.GLsizei) void {
    _ = self;
    Context.gl.DrawArraysInstanced.?(mode, first, count, instances);
}
pub fn deinit(self: *Pipeline) void {
    if (self.program != 0) Context.gl.DeleteProgram.?(self.program);
    if (self.vao != 0) Context.gl.DeleteVertexArrays.?(1, &self.vao);
    self.* = .{ .program = 0, .vao = 0 };
}
```

- [ ] **Step 4: Wire the primitives + shaders into `api.zig`**

In `src/renderer/gpu/opengl/api.zig`, replace the three reserved stub lines:

```zig
pub const Texture = struct {}; // reserved: A4 (font atlas → GPU texture)
pub const Buffer = struct {}; // reserved: A3
pub const Pipeline = struct {}; // reserved: A3
```

with the real types, and add a `shaders` re-export (so cell pipelines can reach the GLSL sources):

```zig
pub const Buffer = @import("Buffer.zig");
pub const Texture = @import("Texture.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const shaders = @import("shaders.zig");
```

- [ ] **Step 5: Expose `shaders` from `gpu.zig`**

In `src/renderer/gpu/gpu.zig`, add next to the other re-exports (after the `gl_init` line):

```zig
pub const shaders = impl.shaders; // backend GLSL sources (for cell pipelines)
```

The `Texture`/`Buffer`/`Pipeline` re-exports already exist there and now resolve to the real types.

- [ ] **Step 6: Build**

Run: `zig build`
Expected: success. The primitives are additive and not yet used.

- [ ] **Step 7: Commit**

```bash
git add src/renderer/gpu/opengl/Buffer.zig src/renderer/gpu/opengl/Texture.zig src/renderer/gpu/opengl/Pipeline.zig src/renderer/gpu/opengl/api.zig src/renderer/gpu/gpu.zig
git commit -m "feat(gpu): real Buffer/Texture/Pipeline primitives [A3]"
```

---

## Task 2: `cell_geometry.zig` — instance types + pure logic + tests

**Files:**
- Create: `src/renderer/cell_geometry.zig`
- Modify: `src/renderer/Renderer.zig` (re-export the moved types), `src/test_fast.zig`

TDD: write the module with tests; the pure functions have known outputs derived from the current `rebuildCells` source.

- [ ] **Step 1: Create `src/renderer/cell_geometry.zig` with types, functions, and tests**

```zig
//! Pure, std-only cell geometry: the GPU instance data types plus the
//! presentation-agnostic transforms used to build them (the BG/cursor/selection
//! decision and the glyph-rect math). No GL, no font, no AppWindow — runs in the
//! fast test suite. The impure glyph lookup (font.loadGlyph / font.glyphUV)
//! stays in cell_renderer.
const std = @import("std");

pub const MAX_GRAPHEME: usize = 8;

/// Background cell instance data for the GPU.
pub const CellBg = extern struct {
    grid_col: f32,
    grid_row: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Foreground (glyph) cell instance data for the GPU.
pub const CellFg = extern struct {
    grid_col: f32,
    grid_row: f32,
    glyph_x: f32,
    glyph_y: f32,
    glyph_w: f32,
    glyph_h: f32,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// Snapshot of a single cell's state (copied from the terminal under lock).
pub const SnapCell = struct {
    codepoint: u21,
    fg: [3]f32,
    bg: ?[3]f32,
    wide: enum(u2) { narrow = 0, wide = 1, spacer_tail = 2, spacer_head = 3 } = .narrow,
    grapheme: [MAX_GRAPHEME]u21 = .{0} ** MAX_GRAPHEME,
    grapheme_len: u4 = 0,
};

pub const Rgb = [3]f32;

pub const ThemeColors = struct {
    background: Rgb,
    cursor_text: ?Rgb,
    selection_background: Rgb,
    selection_foreground: ?Rgb,
    foreground: Rgb,
};

/// The BG/cursor/selection decision (cell_renderer.rebuildCells lines 257-286).
/// Returns the optional background instance to emit and the resolved foreground.
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
) struct { bg: ?CellBg, fg: Rgb } {
    var fg = base_fg;
    var bg: ?CellBg = null;
    if (is_cursor and cursor_visible) {
        if (cursor_is_block) fg = theme.cursor_text orelse theme.background;
        if (cell_bg) |b| bg = .{ .grid_col = grid_col, .grid_row = grid_row, .r = b[0], .g = b[1], .b = b[2], .a = normal_bg_alpha };
    } else if (is_selected) {
        bg = .{ .grid_col = grid_col, .grid_row = grid_row, .r = theme.selection_background[0], .g = theme.selection_background[1], .b = theme.selection_background[2], .a = 1.0 };
        fg = theme.selection_foreground orelse theme.foreground;
    } else if (cell_bg) |b| {
        bg = .{ .grid_col = grid_col, .grid_row = grid_row, .r = b[0], .g = b[1], .b = b[2], .a = normal_bg_alpha };
    }
    return .{ .bg = bg, .fg = fg };
}

pub const GlyphRect = struct { gx: f32, gy: f32, gw: f32, gh: f32 };

/// Grayscale glyph rect math (cell_renderer lines 369-373).
pub fn grayscaleGlyphRect(bearing_x: i32, bearing_y: i32, size_x: u32, size_y: u32, cell_baseline: f32) GlyphRect {
    return .{
        .gx = @floatFromInt(bearing_x),
        .gy = cell_baseline - @as(f32, @floatFromInt(@as(i32, @intCast(size_y)) - bearing_y)),
        .gw = @floatFromInt(size_x),
        .gh = @floatFromInt(size_y),
    };
}

/// Color-emoji aspect-fit + centering (cell_renderer lines 339-348).
pub fn colorEmojiRect(size_x: u32, size_y: u32, grid_width: f32, cell_w: f32, cell_h: f32) GlyphRect {
    const emoji_w: f32 = @floatFromInt(size_x);
    const emoji_h: f32 = @floatFromInt(size_y);
    const target_w = cell_w * grid_width;
    const scale = @min(target_w / emoji_w, cell_h / emoji_h);
    const gw = emoji_w * scale;
    const gh = emoji_h * scale;
    return .{ .gx = (target_w - gw) / 2.0, .gy = (cell_h - gh) / 2.0, .gw = gw, .gh = gh };
}

test "backgroundFor: plain cell emits bg at grid coords, fg unchanged" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = null, .selection_background = .{ 0.2, 0.2, 0.2 }, .selection_foreground = null, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(.{ 0.1, 0.2, 0.3 }, false, false, false, false, theme, 3, 4, 0.5, .{ 0.9, 0.8, 0.7 });
    try std.testing.expect(r.bg != null);
    try std.testing.expectEqual(@as(f32, 3), r.bg.?.grid_col);
    try std.testing.expectEqual(@as(f32, 4), r.bg.?.grid_row);
    try std.testing.expectEqual(@as(f32, 0.5), r.bg.?.a);
    try std.testing.expectEqual(@as(f32, 0.1), r.bg.?.r);
    try std.testing.expectEqual([3]f32{ 0.9, 0.8, 0.7 }, r.fg);
}

test "backgroundFor: no bg color and not cursor/selected emits nothing" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = null, .selection_background = .{ 0.2, 0.2, 0.2 }, .selection_foreground = null, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(null, false, false, false, false, theme, 0, 0, 1.0, .{ 1, 1, 1 });
    try std.testing.expect(r.bg == null);
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, r.fg);
}

test "backgroundFor: selected cell uses opaque selection bg and selection fg" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = null, .selection_background = .{ 0.2, 0.3, 0.4 }, .selection_foreground = .{ 0.5, 0.6, 0.7 }, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(.{ 0.1, 0.1, 0.1 }, false, false, false, true, theme, 1, 2, 0.3, .{ 0.9, 0.9, 0.9 });
    try std.testing.expect(r.bg != null);
    try std.testing.expectEqual(@as(f32, 1.0), r.bg.?.a); // selection stays opaque
    try std.testing.expectEqual(@as(f32, 0.2), r.bg.?.r);
    try std.testing.expectEqual([3]f32{ 0.5, 0.6, 0.7 }, r.fg);
}

test "backgroundFor: block cursor overrides fg to cursor_text" {
    const theme = ThemeColors{ .background = .{ 0, 0, 0 }, .cursor_text = .{ 0.1, 0.1, 0.1 }, .selection_background = .{ 0.2, 0.2, 0.2 }, .selection_foreground = null, .foreground = .{ 1, 1, 1 } };
    const r = backgroundFor(.{ 0.4, 0.4, 0.4 }, true, true, true, false, theme, 0, 0, 1.0, .{ 0.9, 0.9, 0.9 });
    try std.testing.expectEqual([3]f32{ 0.1, 0.1, 0.1 }, r.fg);
    try std.testing.expect(r.bg != null); // cell bg still drawn normally
    try std.testing.expectEqual(@as(f32, 0.4), r.bg.?.r);
}

test "grayscaleGlyphRect: baseline/bearing math" {
    const r = grayscaleGlyphRect(2, 10, 6, 12, 16.0);
    try std.testing.expectEqual(@as(f32, 2), r.gx);
    try std.testing.expectEqual(@as(f32, 16.0 - (12.0 - 10.0)), r.gy); // 14
    try std.testing.expectEqual(@as(f32, 6), r.gw);
    try std.testing.expectEqual(@as(f32, 12), r.gh);
}

test "colorEmojiRect: aspect-fit and centering for a narrow cell" {
    // 20x10 emoji into a 10x16 cell, grid_width 1 → scale = min(10/20, 16/10)=0.5
    const r = colorEmojiRect(20, 10, 1.0, 10.0, 16.0);
    try std.testing.expectEqual(@as(f32, 10), r.gw); // 20*0.5
    try std.testing.expectEqual(@as(f32, 5), r.gh); // 10*0.5
    try std.testing.expectEqual(@as(f32, 0), r.gx); // (10-10)/2
    try std.testing.expectEqual(@as(f32, 5.5), r.gy); // (16-5)/2
}
```

- [ ] **Step 2: Re-export the moved types from `Renderer.zig`**

In `src/renderer/Renderer.zig`, delete the local definitions of `MAX_GRAPHEME` (line ~39), `CellBg` (~47-53), `CellFg` (~57-70), and `SnapCell` (~74-80), and add near the top of the file (after the existing imports):

```zig
const cell_geometry = @import("cell_geometry.zig");
pub const CellBg = cell_geometry.CellBg;
pub const CellFg = cell_geometry.CellFg;
pub const SnapCell = cell_geometry.SnapCell;
```

Leave `pub const MAX_CELLS` where it is. If `grep -n MAX_GRAPHEME src/renderer/Renderer.zig` shows uses beyond the deleted `SnapCell`, also add `const MAX_GRAPHEME = cell_geometry.MAX_GRAPHEME;`.

- [ ] **Step 3: Register the module in the fast test suite**

In `src/test_fast.zig`, inside the `test { ... }` block:

```zig
    _ = @import("renderer/cell_geometry.zig");
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS (the six `cell_geometry` tests run and pass).

- [ ] **Step 5: Build the full app to confirm the re-export compiles**

Run: `zig build`
Expected: success (every `Renderer.CellBg`/`CellFg`/`SnapCell` reference resolves through the re-export).

- [ ] **Step 6: Commit**

```bash
git add src/renderer/cell_geometry.zig src/renderer/Renderer.zig src/test_fast.zig
git commit -m "feat(cells): extract std-only cell_geometry (types + pure logic) [A3]"
```

---

## Task 3: `cell_pipeline.zig` — cell pipelines built from primitives

**Files:**
- Create: `src/renderer/cell_pipeline.zig`

Additive: this module is created but not yet wired in (Task 5 switches to it and strips the old globals). It builds the `bg`/`fg`/`color_fg` pipelines from the Task 1 primitives, relocating the VAO attribute setup verbatim from `gl_init.initInstancedBuffers`.

- [ ] **Step 1: Create `src/renderer/cell_pipeline.zig`**

```zig
//! Cell-grid render pipelines (bg / fg / color-emoji). Cell-specific
//! presentation, built from the gpu backend primitives + the backend GLSL.
//! Relocated from gl_init.initInstancedBuffers (A3). The vertex-attribute
//! layout matches the CellBg/CellFg memory layout exactly.
const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const Renderer = @import("Renderer.zig");
const gpu = AppWindow.gpu;
const c = gpu.c;

const Pipeline = gpu.Pipeline;
const Buffer = gpu.Buffer;

pub threadlocal var bg: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var fg: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var color_fg: Pipeline = .{ .program = 0, .vao = 0 };

pub threadlocal var bg_instances: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var fg_instances: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var color_fg_instances: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var quad: Buffer = .{ .handle = 0, .target = 0 };

/// Build the cell pipelines. Call once after the GL context is current.
pub fn init() void {
    const gl = gpu.glTable();
    const shaders = gpu.shaders;

    // Shared unit quad (triangle strip: 4 verts)
    const quad_verts = [4][2]f32{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 1.0, 1.0 },
    };
    quad = Buffer.init(c.GL_ARRAY_BUFFER);
    quad.uploadData(std.mem.sliceAsBytes(quad_verts[0..]), c.GL_STATIC_DRAW);

    // --- BG VAO ---
    var bg_vao: c.GLuint = 0;
    gl.GenVertexArrays.?(1, &bg_vao);
    bg_instances = Buffer.init(c.GL_ARRAY_BUFFER);
    gl.BindVertexArray.?(bg_vao);
    quad.bind();
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
    bg_instances.allocate(@sizeOf(Renderer.CellBg) * Renderer.MAX_CELLS, c.GL_STREAM_DRAW);
    const bg_stride: c.GLsizei = @sizeOf(Renderer.CellBg);
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 3, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 1, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(5 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    gl.BindVertexArray.?(0);

    // --- FG VAO ---
    var fg_vao: c.GLuint = 0;
    gl.GenVertexArrays.?(1, &fg_vao);
    fg_instances = Buffer.init(c.GL_ARRAY_BUFFER);
    gl.BindVertexArray.?(fg_vao);
    quad.bind();
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
    fg_instances.allocate(@sizeOf(Renderer.CellFg) * Renderer.MAX_CELLS, c.GL_STREAM_DRAW);
    const fg_stride: c.GLsizei = @sizeOf(Renderer.CellFg);
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(6 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    gl.EnableVertexAttribArray.?(4);
    gl.VertexAttribPointer.?(4, 3, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(10 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(4, 1);
    gl.BindVertexArray.?(0);

    // --- Color FG VAO (same layout as FG) ---
    var color_fg_vao: c.GLuint = 0;
    gl.GenVertexArrays.?(1, &color_fg_vao);
    color_fg_instances = Buffer.init(c.GL_ARRAY_BUFFER);
    gl.BindVertexArray.?(color_fg_vao);
    quad.bind();
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
    color_fg_instances.allocate(@sizeOf(Renderer.CellFg) * Renderer.MAX_CELLS, c.GL_STREAM_DRAW);
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(6 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    gl.EnableVertexAttribArray.?(4);
    gl.VertexAttribPointer.?(4, 3, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(10 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(4, 1);
    gl.BindVertexArray.?(0);

    bg = Pipeline.init(shaders.bg_vertex_source, shaders.bg_fragment_source, bg_vao);
    fg = Pipeline.init(shaders.fg_vertex_source, shaders.fg_fragment_source, fg_vao);
    color_fg = Pipeline.init(shaders.fg_vertex_source, shaders.color_fg_fragment_source, color_fg_vao);
    if (bg.program == 0) std.debug.print("BG instanced shader failed\n", .{});
    if (fg.program == 0) std.debug.print("FG instanced shader failed\n", .{});
    if (color_fg.program == 0) std.debug.print("Color FG instanced shader failed\n", .{});
}

pub fn deinit() void {
    bg.deinit();
    fg.deinit();
    color_fg.deinit();
    bg_instances.deinit();
    fg_instances.deinit();
    color_fg_instances.deinit();
    quad.deinit();
}
```

- [ ] **Step 2: Build**

Run: `zig build`
Expected: success. `cell_pipeline` compiles but is not yet referenced.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/cell_pipeline.zig
git commit -m "feat(cells): cell_pipeline built from gpu primitives (unwired) [A3]"
```

---

## Task 4: Route `rebuildCells` through `cell_geometry` (logic switch)

**Files:**
- Modify: `src/renderer/cell_renderer.zig` (`rebuildCells`)

Replace the inline BG/cursor/selection decision and glyph-rect math with calls into `cell_geometry`. Behavior identical; the geometry tests from Task 2 cover the extracted logic.

- [ ] **Step 1: Add the import**

In `src/renderer/cell_renderer.zig`, near the other imports add:

```zig
const cell_geometry = @import("cell_geometry.zig");
```

- [ ] **Step 2: Replace the BG/cursor/selection decision (current lines ~257-286)**

Replace the block that starts `var fg_color = sc.fg;` and runs through the cursor / `is_selected` / `else if (sc.bg)` branches with:

```zig
            const cursor_is_block = if (rend.cached_cursor_effective) |s| s == .block else false;
            const decision = cell_geometry.backgroundFor(
                sc.bg,
                is_cursor,
                rend.cached_cursor_visible,
                cursor_is_block,
                is_selected,
                .{
                    .background = g_theme.background,
                    .cursor_text = g_theme.cursor_text,
                    .selection_background = g_theme.selection_background,
                    .selection_foreground = g_theme.selection_foreground,
                    .foreground = g_theme.foreground,
                },
                col_f,
                row_f,
                normal_bg_alpha,
                sc.fg,
            );
            if (decision.bg) |bg_inst| {
                if (rend.bg_cell_count < rend.bg_cells.items.len) {
                    rend.bg_cells.items[rend.bg_cell_count] = bg_inst;
                    rend.bg_cell_count += 1;
                }
            }
            var fg_color = decision.fg;
```

(`is_cursor`, `is_selected`, `col_f`, `row_f`, `normal_bg_alpha`, `g_theme` are already in scope above this block.)

- [ ] **Step 3: Replace the grayscale glyph rect (current lines ~370-373)**

The grayscale branch currently reads `const uv_val = font.glyphUV(ch.region, atlas_size);` (line 369) followed by four `const gx/gy/gw/gh = …` lines (370-373). Leave the `uv_val` line untouched; replace **only** the four `gx/gy/gw/gh` lines with:

```zig
                            const rect = cell_geometry.grayscaleGlyphRect(ch.bearing_x, ch.bearing_y, ch.size_x, ch.size_y, font.cell_baseline);
                            const gx = rect.gx;
                            const gy = rect.gy;
                            const gw = rect.gw;
                            const gh = rect.gh;
```

The subsequent `rend.fg_cells.items[...] = .{ … }` assignment (which reads `gx/gy/gw/gh/uv_val`) stays unchanged.

- [ ] **Step 4: Replace the color-emoji rect (current lines ~339-347)**

In the color branch, replace the `emoji_w/emoji_h/target_w/scale/gw/gh/gx/gy` computation (lines 339-347) with the call below. Leave the `const uv_val = font.glyphUV(ch.region, color_atlas_size);` line (348) and the subsequent `rend.color_fg_cells.items[...] = .{ … }` assignment untouched:

```zig
                            const rect = cell_geometry.colorEmojiRect(ch.size_x, ch.size_y, grid_width, font.cell_width, font.cell_height);
                            const gx = rect.gx;
                            const gy = rect.gy;
                            const gw = rect.gw;
                            const gh = rect.gh;
```

- [ ] **Step 5: Build and test**

Run: `zig build && zig build test`
Expected: `zig build` succeeds; `zig build test` green (geometry tests pass).

Run: `zig build test-full`
Expected: baseline 497/499 (1 pre-existing Windows-only failure, 1 skip) — no new failures.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/cell_renderer.zig
git commit -m "refactor(cells): rebuildCells uses cell_geometry pure logic [A3]"
```

---

## Task 5: Route `drawCells` through `cell_pipeline`; strip cell parts from `gl_init` (presentation cutover)

**Files:**
- Modify: `src/renderer/cell_renderer.zig` (`drawCells`), `src/renderer/gpu/opengl/gl_init.zig`, `src/AppWindow.zig`

This is the atomic presentation cutover: switch `drawCells`, remove the cell-specific globals/setup from `gl_init`, and repoint `AppWindow`'s init/teardown.

- [ ] **Step 1: Add the `cell_pipeline` import to `cell_renderer.zig`**

```zig
const cell_pipeline = @import("cell_pipeline.zig");
```

- [ ] **Step 2: Rewrite the three instanced passes in `drawCells` (current lines ~408-468)**

Replace the BG, FG, and color-emoji blocks (the ones guarded by `gl_init.bg_shader != 0` etc.) with:

```zig
    // --- Draw BG cells ---
    if (rend.bg_cell_count > 0 and cell_pipeline.bg.program != 0) {
        const p = cell_pipeline.bg;
        p.use();
        p.setVec2("cellSize", font.cell_width, font.cell_height);
        p.setVec2("gridOffset", offset_x, offset_y);
        p.setFloat("windowHeight", window_height);
        p.setProjection();
        p.bindVao();
        cell_pipeline.bg_instances.upload(std.mem.sliceAsBytes(rend.bg_cells.items[0..rend.bg_cell_count]));
        p.drawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(rend.bg_cell_count));
        gl_init.g_draw_call_count += 1;
    }

    image_renderer.draw(rend, window_height, offset_x, offset_y, .below_text);

    // --- Draw FG cells ---
    if (rend.fg_cell_count > 0 and cell_pipeline.fg.program != 0) {
        const p = cell_pipeline.fg;
        p.use();
        p.setVec2("cellSize", font.cell_width, font.cell_height);
        p.setVec2("gridOffset", offset_x, offset_y);
        p.setFloat("windowHeight", window_height);
        p.setProjection();
        gpu.Texture.fromHandle(font.g_atlas_texture).bind(0);
        p.setInt("atlas", 0);
        p.bindVao();
        cell_pipeline.fg_instances.upload(std.mem.sliceAsBytes(rend.fg_cells.items[0..rend.fg_cell_count]));
        p.drawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(rend.fg_cell_count));
        gl_init.g_draw_call_count += 1;
    }

    // --- Draw color emoji cells (premultiplied alpha blend) ---
    if (rend.color_fg_cell_count > 0 and cell_pipeline.color_fg.program != 0) {
        const gl = AppWindow.gpu.glTable();
        gl.BlendFunc.?(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        const p = cell_pipeline.color_fg;
        p.use();
        p.setVec2("cellSize", font.cell_width, font.cell_height);
        p.setVec2("gridOffset", offset_x, offset_y);
        p.setFloat("windowHeight", window_height);
        p.setProjection();
        gpu.Texture.fromHandle(font.g_color_atlas_texture).bind(0);
        p.setInt("atlas", 0);
        p.bindVao();
        cell_pipeline.color_fg_instances.upload(std.mem.sliceAsBytes(rend.color_fg_cells.items[0..rend.color_fg_cell_count]));
        p.drawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(rend.color_fg_cell_count));
        gl_init.g_draw_call_count += 1;
        gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    }
```

Notes: `image_renderer.draw(... .below_bg)` before the BG block and `image_renderer.draw(... .above_text)` / `drawUrlUnderline(...)` after the color block stay exactly as they are. The cursor-overlay block (uses `gl_init.shader_program`/`gl_init.vao`/`gl_init.renderQuad`) is **left untouched** — it uses shared pipelines. `gpu` must be in scope: `cell_renderer.zig` already references `AppWindow.gpu.*`; add `const gpu = AppWindow.gpu;` near the imports if not present.

- [ ] **Step 3: Move the shared shader links into `gl_init.initShaders`**

In `src/renderer/gpu/opengl/gl_init.zig`, append to the end of `initShaders` (just before `return true;`):

```zig
    // Shared simple-color + overlay shaders (used by titlebar/overlays).
    simple_color_shader = linkProgram(shaders.vertex_shader_source, shaders.simple_color_fragment_source);
    if (simple_color_shader == 0) std.debug.print("Simple color shader failed\n", .{});
    overlay_shader = linkProgram(shaders.vertex_shader_source, shaders.overlay_fragment_source);
    if (overlay_shader == 0) std.debug.print("Overlay shader failed\n", .{});
```

- [ ] **Step 4: Delete the cell-specific globals + `initInstancedBuffers` + `deinitInstancedResources` from `gl_init.zig`**

Remove these declarations (lines ~25-34): `bg_shader`, `fg_shader`, `color_fg_shader`, `bg_vao`, `fg_vao`, `color_fg_vao`, `bg_instance_vbo`, `fg_instance_vbo`, `color_fg_instance_vbo`, `quad_vbo`. Delete the entire `pub fn initInstancedBuffers` and `pub fn deinitInstancedResources` functions. Keep `linkProgram` (now used by `initShaders`), `compileShader`, `vao`/`vbo`/`shader_program`, `simple_color_shader`, `overlay_shader`, `solid_texture`, `initBuffers`, `initSolidTexture`, `renderQuad`/`renderQuadAlpha`, `setProjection`, `setProjectionForProgram`, `g_draw_call_count`, `g_bg_opacity`.

- [ ] **Step 5: Repoint `AppWindow.zig` init/teardown**

In `src/AppWindow.zig`: add the import near the other renderer re-exports:
```zig
pub const cell_pipeline = @import("renderer/cell_pipeline.zig");
```
Replace the call `gpu.gl_init.initInstancedBuffers();` (line ~3260) with:
```zig
    cell_pipeline.init();
```
Replace the call `gpu.gl_init.deinitInstancedResources();` (line ~3324) with:
```zig
    cell_pipeline.deinit();
```
(`initShaders` now also links the shared simple_color/overlay shaders; no extra call needed.)

- [ ] **Step 6: Verify nothing else references the removed globals**

Run:
```bash
grep -rn "gl_init\.\(bg_shader\|fg_shader\|color_fg_shader\|bg_vao\|fg_vao\|color_fg_vao\|bg_instance_vbo\|fg_instance_vbo\|color_fg_instance_vbo\)\|initInstancedBuffers\|deinitInstancedResources" src/
```
Expected: no output.

- [ ] **Step 7: Build and test**

Run: `zig build`
Expected: success.

Run: `zig build test-full`
Expected: baseline 497/499 (1 pre-existing Windows-only failure, 1 skip) — no new failures.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(cells): drawCells routes through cell_pipeline; strip cell globals from gl_init [A3]"
```

---

## Task 6: Docs + final verification

**Files:**
- Modify: `TODO.md`, `docs/decoupling-guide.md`

- [ ] **Step 1: Note A3 progress in `TODO.md`**

Under Phase A item **A3**, add a sub-note that the first increment landed: real `Buffer`/`Texture`/`Pipeline` primitives exist in `gpu/opengl/`, `cell_renderer` is converted (draw path through `cell_pipeline`; pure logic in std-only `cell_geometry` with unit tests), and the remaining 9 files + the shared pipelines (`shader_program`/`overlay_shader`/`simple_color_shader`) are still pending. Leave A3 unchecked (incomplete).

- [ ] **Step 2: Add a status line under `docs/decoupling-guide.md` §5 Phase A**

Note that A3 began: primitives defined and `cell_renderer` converted as the proving ground; the per-file pattern (route draw through primitives + extract pure geometry) is established for the remaining files.

- [ ] **Step 3: Final verification**

Run: `zig build test-full`
Expected: 497/499 baseline.

Run: `zig build`
Expected: a clean `phantty.exe` artifact.

- [ ] **Step 4: Request the manual Windows visual check**

Ask the maintainer to run `phantty.exe` on Windows and confirm the terminal grid renders identically: text fg/bg colors, background-image alpha, selection highlight, all four cursor styles (block/bar/underline/hollow), and color emoji. Behavior-preserving change — any visual difference is a regression.

- [ ] **Step 5: Commit**

```bash
git add TODO.md docs/decoupling-guide.md
git commit -m "docs(gpu): note A3 increment 1 (primitives + cell_renderer)"
```

---

## Self-review notes (resolved)

- **Spec coverage:** §2 primitives → Task 1. §3 cell pipelines → Task 3 (build) + Task 5 (wire + strip gl_init). §4 cell_geometry types/logic/tests → Task 2; rebuildCells switch → Task 4. Verification → Task 6. Non-goals (Frame/RenderPass/Target, shared pipelines, other 9 files, A4/A5/A6) are explicitly out.
- **Type consistency:** `Buffer{ .handle, .target }`, `Pipeline{ .program, .vao }` literals in `cell_pipeline.zig` match the field definitions in Task 1. `cell_geometry.backgroundFor` return `{ bg: ?CellBg, fg: Rgb }` and `GlyphRect{ gx, gy, gw, gh }` are used consistently in Task 4. `Pipeline.setProjection(window_height)` / `setVec2`/`setFloat`/`setInt`/`drawArraysInstanced`/`bindVao`/`use` names match Task 1 ↔ Task 5.
- **Atomicity:** Task 5 is one commit (the presentation cutover) because `drawCells`, the `gl_init` strip, and the `AppWindow` repoint must land together to keep the build green. Task 4 (logic) is a separate, independently-green commit — consecutive commits within this increment still "touch cell_renderer once" for each purpose.
- **Behavior preservation:** the relocated VAO attribute setup (Task 3) and the color-emoji blend-mode switch (Task 5) are reproduced exactly from the current `initInstancedBuffers` / `drawCells`; the manual Windows check (Task 6) is the final gate since rendering has no automated coverage.
