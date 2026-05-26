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
pub threadlocal var overlay: Pipeline = .{ .program = 0, .vao = 0 }; // flat-color tint (was gl_init.overlay_shader)
pub threadlocal var quad: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var solid: Texture = .{ .handle = 0 };

fn drawCallTick() void {
    AppWindow.gpu.gl_init.g_draw_call_count += 1;
}

/// Build a VAO with the shared text/emoji vertex layout (one vec4 attrib:
/// xy = position, zw = texcoord), pointing at the shared quad buffer.
fn buildQuadVao() c.GLuint {
    return gpu.vertex.buildVertexArray(&.{.{
        .buffer = quad,
        .attrs = &.{.{ .loc = 0, .count = 4, .stride = 4 * @sizeOf(f32), .offset = 0 }},
    }});
}

/// Build the shared pipelines, quad buffer, and solid texture. Call once after
/// the GL context is current (before any UI draw).
pub fn init() void {
    quad = Buffer.init(c.GL_ARRAY_BUFFER);
    quad.allocate(@sizeOf(f32) * 6 * 4, c.GL_DYNAMIC_DRAW);

    // Each pipeline owns its own VAO (identical layout) for clean deinit.
    const text_vao = buildQuadVao();
    const emoji_vao = buildQuadVao();
    text = Pipeline.init(shaders.vertex_shader_source, shaders.fragment_shader_source, text_vao);
    emoji = Pipeline.init(shaders.vertex_shader_source, shaders.simple_color_fragment_source, emoji_vao);
    if (text.program == 0) std.debug.print("UI text pipeline failed\n", .{});
    if (emoji.program == 0) std.debug.print("UI emoji pipeline failed\n", .{});

    const overlay_vao = buildQuadVao();
    overlay = Pipeline.init(shaders.vertex_shader_source, shaders.overlay_fragment_source, overlay_vao);
    if (overlay.program == 0) std.debug.print("UI overlay pipeline failed\n", .{});

    const white_pixel = [_]u8{255};
    solid = Texture.create();
    solid.upload2D(1, 1, &white_pixel, .{
        .internal_format = c.GL_RED,
        .format = c.GL_RED,
        .filter = .nearest,
        .wrap = .clamp_to_edge,
        .unpack_alignment = 1,
    });
}

pub fn deinit() void {
    text.deinit();
    emoji.deinit();
    overlay.deinit();
    quad.deinit();
    solid.destroy();
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
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };
    text.use();
    text.setMat4("projection", &projection);
}

/// Enable scissor clipping to `rect` (window-space, same convention as the
/// caller's existing glScissor: x/y are the lower-left corner in GL pixels).
/// Rounds to integer pixels, matching the prior @intFromFloat(@round(...)) calls.
pub fn beginClip(rect: Rect) void {
    gpu.state.setScissor(.{
        .x = @intFromFloat(@round(rect.x)),
        .y = @intFromFloat(@round(rect.y)),
        .w = @intFromFloat(@round(rect.w)),
        .h = @intFromFloat(@round(rect.h)),
    });
}

/// Disable scissor clipping (= the prior gl.Disable(GL_SCISSOR_TEST)). Flat
/// enable/disable — clip regions are not nested.
pub fn endClip() void {
    gpu.state.disableScissor();
}

/// Toggle GL_BLEND. Lets callers that draw opaque content (e.g. a background
/// image or post-process pass) disable blending for a draw and restore it,
/// without touching raw GL (= the prior gl.Disable/Enable(GL_BLEND) bookends).
pub fn setBlendEnabled(enabled: bool) void {
    gpu.state.setBlendEnabled(enabled);
}

pub fn fillQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    fillQuadAlpha(x, y, w, h, color, 1.0);
}

/// Solid color quad (= old gl_init.renderQuadAlpha). Preserves the alpha trick:
/// blends `color` toward g_theme.background by `alpha` and draws opaque via the
/// solid texture (no BlendFunc needed — alpha is baked into the color channel).
pub fn fillQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    const bg = AppWindow.g_theme.background;
    const r = color[0] * alpha + bg[0] * (1 - alpha);
    const g = color[1] * alpha + bg[1] * (1 - alpha);
    const b = color[2] * alpha + bg[2] * (1 - alpha);
    const verts = quadVertices(.{ .x = x, .y = y, .w = w, .h = h }, .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 });
    text.use();
    text.bindVao();
    text.setVec3("textColor", r, g, b);
    solid.bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    text.drawArrays(c.GL_TRIANGLES, 0, 6);
    drawCallTick();
}

/// Grayscale/text glyph via the text pipeline (atlas .r as alpha, modulated by color).
pub fn drawGlyph(rect: Rect, uv: Uv, tex: c.GLuint, color: [3]f32) void {
    const verts = quadVertices(rect, uv);
    text.use();
    text.bindVao();
    text.setVec3("textColor", color[0], color[1], color[2]);
    Texture.fromHandle(tex).bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    text.drawArrays(c.GL_TRIANGLES, 0, 6);
    drawCallTick();
}

/// Color-emoji via the emoji pipeline: premultiplied-alpha blend bookend +
/// per-call projection from the current viewport (= old renderBellEmoji /
/// renderTitlebarChar color branch).
pub fn drawColorGlyph(rect: Rect, uv: Uv, tex: c.GLuint, opacity: f32) void {
    const verts = quadVertices(rect, uv);
    emoji.use();
    emoji.bindVao();
    emoji.setProjection(); // viewport-derived ortho on the emoji program (Pipeline.setProjection)
    emoji.setFloat("opacity", opacity);
    gpu.state.setBlendMode(.premultiplied);
    Texture.fromHandle(tex).bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    emoji.drawArrays(c.GL_TRIANGLES, 0, 6);
    drawCallTick();
    gpu.state.setBlendMode(.alpha);
}

/// Draw a textured RGBA quad through the emoji/color pipeline (the old
/// gl_init.simple_color_shader path). `verts` is 6 vertices of (x, y, u, v).
/// `opacity` modulates alpha; the texture is sampled on unit 0. Does NOT change
/// blend state — the caller sets blend as needed.
pub fn drawTextureQuad(verts: [6][4]f32, tex: c.GLuint, opacity: f32) void {
    emoji.use();
    emoji.bindVao();
    emoji.setProjection();
    emoji.setFloat("opacity", opacity);
    emoji.setInt("text", 0);
    Texture.fromHandle(tex).bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    emoji.drawArrays(c.GL_TRIANGLES, 0, 6);
    drawCallTick();
}

/// Draw a flat-color quad through the overlay pipeline (the old
/// gl_init.overlay_shader path). `verts` is 6 vertices of (x, y, u, v) — the
/// overlay shader ignores the uv. `color` is RGBA (alpha = tint strength).
/// Does NOT change blend state.
pub fn fillOverlay(verts: [6][4]f32, color: [4]f32) void {
    overlay.use();
    overlay.bindVao();
    overlay.setProjection();
    overlay.setVec4("overlayColor", color[0], color[1], color[2], color[3]);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    overlay.drawArrays(c.GL_TRIANGLES, 0, 6);
    drawCallTick();
}
