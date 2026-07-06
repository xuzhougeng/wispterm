//! Shared UI render pipelines (solid quad / text-glyph / color-emoji), built
//! from the gpu backend primitives. Relocated out of the legacy init shim (A3).
//! The shim keeps compat mirror handles for not-yet-converted renderer files.
//!
//! Draw helpers are self-contained: each use()s its pipeline and binds its VAO,
//! so callers need no ambient backend program/vertex-array state.
const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const gpu = AppWindow.gpu;
const shaders = gpu.shaders;
const ui_batch = @import("ui_batch.zig");

const Pipeline = gpu.Pipeline;
const Buffer = gpu.Buffer;
const Texture = gpu.Texture;

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
pub const Uv = struct { u0: f32, v0: f32, u1: f32, v1: f32 };

pub threadlocal var text: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var emoji: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var overlay: Pipeline = .{ .program = 0, .vao = 0 }; // flat-color tint
pub threadlocal var quad: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var solid: Texture = .{ .handle = 0 };

// ---------------------------------------------------------------------------
// Batched UI glyph/quad path (OpenGL only).
//
// drawGlyph/fillQuad calls accumulate per-texture instance runs and submit
// them as one instanced draw instead of one use+bind+upload+draw per glyph —
// the dominant CPU cost of chrome/panel text on weak machines. Draw order is
// preserved by flushing before anything foreign happens: the gpu.state
// pre_change_hook (viewport/scissor/blend/clear/colormask/endFrame/FBO bind)
// and the Pipeline pre_use_hook (any non-batch program about to draw). The
// Metal backend keeps the immediate path (its shader set has no batch mirror).
// ---------------------------------------------------------------------------
const batching_supported = gpu.active == .opengl;

threadlocal var batch: Pipeline = .{ .program = 0, .vao = 0 };
threadlocal var batch_instances: Buffer = .{ .handle = 0, .target = 0 };
threadlocal var batch_quad: Buffer = .{ .handle = 0, .target = 0 };
// GL-only UI glyph batcher, heap-allocated on first use (~180 KB — kept out
// of the TLS template, which Windows commits privately for every thread; on
// non-GL backends it never allocates at all).
threadlocal var g_batcher: ?*ui_batch.Batcher = null;

fn batcher() *ui_batch.Batcher {
    if (g_batcher == null) {
        const b = std.heap.page_allocator.create(ui_batch.Batcher) catch
            @panic("out of memory allocating UI batcher");
        b.* = .{};
        g_batcher = b;
    }
    return g_batcher.?;
}
/// Shadow of the text pipeline's projection (set in setProjection); the batch
/// draw applies it at flush time. Flushes happen before any projection change,
/// so pending instances always use the projection they were issued under.
threadlocal var batch_projection: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

const GlSink = struct {
    pub fn draw(_: GlSink, texture: u32, instances: []const ui_batch.Instance) void {
        const p = batch;
        p.use(); // own program: the pre_use_hook ignores it (no recursion)
        p.setMat4("projection", &batch_projection);
        Texture.fromHandle(texture).bind(0);
        p.setInt("text", 0);
        p.bindVao();
        batch_instances.upload(std.mem.sliceAsBytes(instances));
        p.drawArraysInstanced(.triangle_strip, 0, 4, @intCast(instances.len));
        drawCallTick();
    }
};

/// Submit any pending batched UI draws. Registered into the gpu hooks; also
/// called directly by frame tails that present without an endFrame (resize).
pub fn flushBatch() void {
    batcher().flush(GlSink{});
}

fn pipelineUseHook(program: gpu.ProgramHandle) void {
    if (ui_batch.shouldFlushOnPipelineUse(batcher().pending(), program, batch.program)) flushBatch();
}

fn drawCallTick() void {
    AppWindow.gpu.draw_call_count += 1;
}

/// Build a VAO with the shared text/emoji vertex layout (one vec4 attrib:
/// xy = position, zw = texcoord), pointing at the shared quad buffer.
fn buildQuadVao() gpu.VertexArrayHandle {
    return gpu.vertex.buildVertexArray(&.{.{
        .buffer = quad,
        .attrs = &.{.{ .loc = 0, .count = 4, .stride = 4 * @sizeOf(f32), .offset = 0 }},
    }});
}

/// Build the shared pipelines, quad buffer, and solid texture. Call once after
/// the GL context is current (before any UI draw).
pub fn init() void {
    quad = Buffer.initVertex();
    quad.allocate(@sizeOf(f32) * 6 * 4, .dynamic);

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
        .format = .r8,
        .sampler = .nearest_clamp,
        .unpack_alignment = 1,
    });

    if (comptime batching_supported) initBatch();
}

/// Build the instanced UI batch pipeline and register the flush hooks.
/// On shader-link failure `batch.program` stays 0 and every draw falls back to
/// the immediate path (hooks then never fire on an empty batcher).
fn initBatch() void {
    const quad_verts = [4][2]f32{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 1.0, 1.0 },
    };
    batch_quad = Buffer.initVertex();
    batch_quad.uploadData(std.mem.sliceAsBytes(quad_verts[0..]), .static);

    batch_instances = Buffer.initVertex();
    batch_instances.allocate(@sizeOf(ui_batch.Instance) * ui_batch.capacity, .stream);

    const stride = @sizeOf(ui_batch.Instance);
    const batch_vao = gpu.vertex.buildVertexArray(&.{
        .{
            .buffer = batch_quad,
            .attrs = &.{
                .{ .loc = 0, .count = 2, .stride = 2 * @sizeOf(f32), .offset = 0 },
            },
        },
        .{
            .buffer = batch_instances,
            .attrs = &.{
                .{ .loc = 1, .count = 4, .stride = stride, .offset = 0, .divisor = 1 },
                .{ .loc = 2, .count = 4, .stride = stride, .offset = 4 * @sizeOf(f32), .divisor = 1 },
                .{ .loc = 3, .count = 3, .stride = stride, .offset = 8 * @sizeOf(f32), .divisor = 1 },
            },
        },
    });
    batch = Pipeline.init(shaders.ui_batch_vertex_source, shaders.ui_batch_fragment_source, batch_vao);
    if (batch.program == 0) {
        std.debug.print("UI batch pipeline failed — falling back to immediate UI draws\n", .{});
        return;
    }

    gpu.state.pre_change_hook = flushBatch;
    Pipeline.pre_use_hook = pipelineUseHook;
}

pub fn deinit() void {
    if (comptime batching_supported) {
        gpu.state.pre_change_hook = null;
        Pipeline.pre_use_hook = null;
        if (g_batcher) |b| {
            std.heap.page_allocator.destroy(b);
            g_batcher = null;
        }
        batch.deinit();
        batch_instances.deinit();
        batch_quad.deinit();
    }
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

/// Set the text pipeline's frame-level orthographic projection.
/// The emoji pipeline needs no frame-level update — drawColorGlyph re-derives its
/// projection from the viewport per call.
pub fn setProjection(width: f32, height: f32) void {
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };
    // text.use() flushes any pending batch (pre_use_hook) under the OLD
    // projection before the shadow updates — instances are always drawn with
    // the projection they were issued under.
    text.use();
    text.setMat4("projection", &projection);
    if (comptime batching_supported) batch_projection = projection;
}

/// Enable scissor clipping to `rect` (window-space, lower-left pixel origin).
/// Rounds to integer pixels, matching the prior @intFromFloat(@round(...)) calls.
pub fn beginClip(rect: Rect) void {
    gpu.state.setScissor(.{
        .x = @intFromFloat(@round(rect.x)),
        .y = @intFromFloat(@round(rect.y)),
        .w = @intFromFloat(@round(rect.w)),
        .h = @intFromFloat(@round(rect.h)),
    });
}

/// Disable backend scissor clipping. Flat
/// enable/disable — clip regions are not nested.
pub fn endClip() void {
    gpu.state.disableScissor();
}

/// Toggle backend blending. Lets callers that draw opaque content (e.g. a
/// background image or post-process pass) disable blending for a draw and
/// restore it.
pub fn setBlendEnabled(enabled: bool) void {
    gpu.state.setBlendEnabled(enabled);
}

pub fn fillQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    fillQuadAlpha(x, y, w, h, color, 1.0);
}

/// Solid color quad. Preserves the alpha trick:
/// blends `color` toward g_theme.background by `alpha` and draws opaque via the
/// solid texture (no BlendFunc needed — alpha is baked into the color channel).
pub fn fillQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    const bg = AppWindow.g_theme.background;
    const r = color[0] * alpha + bg[0] * (1 - alpha);
    const g = color[1] * alpha + bg[1] * (1 - alpha);
    const b = color[2] * alpha + bg[2] * (1 - alpha);
    if (comptime batching_supported) {
        if (batch.program != 0) {
            batcher().push(solid.handle, .{
                .x = x,
                .y = y,
                .w = w,
                .h = h,
                .u0 = 0,
                .v0 = 0,
                .u1 = 1,
                .v1 = 1,
                .r = r,
                .g = g,
                .b = b,
            }, GlSink{});
            return;
        }
    }
    const verts = quadVertices(.{ .x = x, .y = y, .w = w, .h = h }, .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 });
    text.use();
    text.bindVao();
    text.setVec3("textColor", r, g, b);
    solid.bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    text.drawArrays(.triangles, 0, 6);
    drawCallTick();
}

/// Grayscale/text glyph via the text pipeline (atlas .r as alpha, modulated by color).
pub fn drawGlyph(rect: Rect, uv: Uv, tex: Texture, color: [3]f32) void {
    if (comptime batching_supported) {
        if (batch.program != 0) {
            batcher().push(tex.handle, .{
                .x = rect.x,
                .y = rect.y,
                .w = rect.w,
                .h = rect.h,
                .u0 = uv.u0,
                .v0 = uv.v0,
                .u1 = uv.u1,
                .v1 = uv.v1,
                .r = color[0],
                .g = color[1],
                .b = color[2],
            }, GlSink{});
            return;
        }
    }
    const verts = quadVertices(rect, uv);
    text.use();
    text.bindVao();
    text.setVec3("textColor", color[0], color[1], color[2]);
    tex.bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    text.drawArrays(.triangles, 0, 6);
    drawCallTick();
}

/// Color-emoji via the emoji pipeline: premultiplied-alpha blend bookend +
/// per-call projection from the current viewport (= old renderBellEmoji /
/// renderTitlebarChar color branch).
pub fn drawColorGlyph(rect: Rect, uv: Uv, tex: Texture, opacity: f32) void {
    const verts = quadVertices(rect, uv);
    emoji.use();
    emoji.bindVao();
    emoji.setProjection(); // viewport-derived ortho on the emoji program (Pipeline.setProjection)
    emoji.setFloat("opacity", opacity);
    gpu.state.setBlendMode(.premultiplied);
    tex.bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    emoji.drawArrays(.triangles, 0, 6);
    drawCallTick();
    gpu.state.setBlendMode(.alpha);
}

/// Draw a textured RGBA quad through the emoji/color pipeline. `verts` is 6
/// vertices of (x, y, u, v).
/// `opacity` modulates alpha; the texture is sampled on unit 0. Does NOT change
/// blend state — the caller sets blend as needed.
pub fn drawTextureQuad(verts: [6][4]f32, tex: Texture, opacity: f32) void {
    emoji.use();
    emoji.bindVao();
    emoji.setProjection();
    emoji.setFloat("opacity", opacity);
    emoji.setInt("text", 0);
    tex.bind(0);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    emoji.drawArrays(.triangles, 0, 6);
    drawCallTick();
}

/// Draw a flat-color quad through the overlay pipeline. `verts` is 6 vertices
/// of (x, y, u, v); the overlay shader ignores the uv. `color` is RGBA
/// (alpha = tint strength).
/// Does NOT change blend state.
pub fn fillOverlay(verts: [6][4]f32, color: [4]f32) void {
    overlay.use();
    overlay.bindVao();
    overlay.setProjection();
    overlay.setVec4("overlayColor", color[0], color[1], color[2], color[3]);
    quad.upload(std.mem.sliceAsBytes(verts[0..]));
    overlay.drawArrays(.triangles, 0, 6);
    drawCallTick();
}
