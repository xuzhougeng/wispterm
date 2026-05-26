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
/// The emoji pipeline needs no frame-level update — drawColorGlyph re-derives its
/// projection from the viewport per call.
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
/// enable/disable — clip regions are not nested.
pub fn endClip() void {
    gpu.glTable().Disable.?(c.GL_SCISSOR_TEST);
}

pub fn fillQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    fillQuadAlpha(x, y, w, h, color, 1.0);
}

/// Solid color quad (= old gl_init.renderQuadAlpha). Preserves the alpha trick:
/// blends `color` toward g_theme.background by `alpha` and draws opaque via the
/// solid texture (no BlendFunc needed — alpha is baked into the color channel).
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
    const verts = quadVertices(rect, uv);
    emoji.use();
    emoji.bindVao();
    emoji.setProjection(); // viewport-derived ortho on the emoji program (Pipeline.setProjection)
    gl.Uniform1f.?(gl.GetUniformLocation.?(emoji.program, "opacity"), opacity);
    gl.BlendFunc.?(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    Texture.fromHandle(tex).bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    drawCallTick();
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
}
