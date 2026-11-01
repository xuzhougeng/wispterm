const std = @import("std");

const c = @import("c.zig");
const Buffer = @import("Buffer.zig");
const Context = @import("Context.zig");
const Framebuffer = @import("Framebuffer.zig");
const Pipeline = @import("Pipeline.zig");
const Texture = @import("Texture.zig");
const gl_init = @import("gl_init.zig");
const readback = @import("readback.zig");
const render_state = @import("render_state.zig");
const shaders = @import("shaders.zig");
const vertex = @import("vertex.zig");

test {
    _ = readback;
}

test "Context.init creates a usable Metal backend context" {
    try Context.init(null);
    defer Context.deinit();

    try std.testing.expect(Context.isInitialized());
}

test "Buffer allocates and updates Metal buffer storage" {
    try Context.init(null);
    defer Context.deinit();

    var buffer = Buffer.initVertex();
    defer buffer.deinit();

    try std.testing.expect(buffer.handle != 0);

    buffer.allocate(16, .dynamic);
    try std.testing.expectEqual(@as(usize, 16), buffer.byteLength());

    const initial = [_]u8{ 1, 2, 3, 4 };
    buffer.uploadData(&initial, .static);
    try std.testing.expectEqual(@as(usize, initial.len), buffer.byteLength());

    const update = [_]u8{ 9, 8, 7, 6 };
    buffer.upload(&update);
    try std.testing.expectEqual(@as(usize, initial.len), buffer.byteLength());

    // A transient upload reports its own length, not the shared arena's.
    const transient = [_]u8{ 1, 2, 3, 4, 5, 6 };
    buffer.uploadTransient(&transient);
    try std.testing.expectEqual(@as(usize, transient.len), buffer.byteLength());
}

test "Texture uploads full and partial 2D image data" {
    try Context.init(null);
    defer Context.deinit();

    var texture = Texture.create();
    defer texture.destroy();

    try std.testing.expect(texture.handle != 0);

    const rgba = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    texture.upload2D(2, 2, &rgba, .{
        .format = .rgba8,
        .unpack_alignment = 1,
    });
    try std.testing.expectEqual(@as(c_int, 2), texture.levelWidth());

    const pixel = [_]u8{ 12, 34, 56, 78 };
    texture.subImage2D(1, 1, 1, 1, &pixel, .{
        .format = .rgba8,
        .unpack_alignment = 1,
    });
    texture.setSamplerMode(.linear_repeat);
    try std.testing.expectEqual(@as(c_int, 2), texture.levelWidth());
}

test "Framebuffer creates offscreen color texture target" {
    try Context.init(null);
    defer Context.deinit();

    var framebuffer = Framebuffer.initColor(4, 3) orelse return error.TestExpectedFramebuffer;
    defer framebuffer.deinit();

    try std.testing.expect(framebuffer.handle != 0);
    try std.testing.expect(framebuffer.color != 0);
    try std.testing.expectEqual(@as(c_int, 4), framebuffer.width);
    try std.testing.expectEqual(@as(c_int, 3), framebuffer.height);
    try std.testing.expectEqual(@as(c_int, 4), Texture.fromHandle(framebuffer.color).levelWidth());

    framebuffer.bind();
    Framebuffer.unbind();
}

test "Pipeline compiles simple MSL vertex and fragment functions" {
    try Context.init(null);
    defer Context.deinit();

    const vs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\vertex float4 vertex_main(uint vertex_id [[vertex_id]]) {
        \\    float2 positions[3] = {
        \\        float2(-1.0, -1.0),
        \\        float2( 3.0, -1.0),
        \\        float2(-1.0,  3.0),
        \\    };
        \\    return float4(positions[vertex_id], 0.0, 1.0);
        \\}
    ;
    const fs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\fragment float4 fragment_main() {
        \\    return float4(1.0, 0.0, 0.0, 1.0);
        \\}
    ;

    var pipeline = Pipeline.init(vs, fs, 0);
    defer pipeline.deinit();

    try std.testing.expect(pipeline.program != 0);
    pipeline.use();
    pipeline.setFloat("iTime", 1.0);
    pipeline.setVec2("cellSize", 8, 16);
    pipeline.setVec3("iResolution", 640, 480, 1);
    pipeline.setVec4("overlayColor", 1, 0, 0, 1);
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());
}

test "render_state batches multiple Metal draws into one presented frame" {
    try Context.init(null);
    defer Context.deinit();

    const vs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\vertex float4 vertex_main(uint vertex_id [[vertex_id]]) {
        \\    float2 positions[3] = {
        \\        float2(-1.0, -1.0),
        \\        float2( 3.0, -1.0),
        \\        float2(-1.0,  3.0),
        \\    };
        \\    return float4(positions[vertex_id], 0.0, 1.0);
        \\}
    ;
    const fs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\fragment float4 fragment_main() {
        \\    return float4(0.0, 1.0, 0.0, 1.0);
        \\}
    ;

    var pipeline = Pipeline.init(vs, fs, 0);
    defer pipeline.deinit();

    render_state.clear(0, 0, 0, 1);
    try std.testing.expect(render_state.isFrameActive());
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());
    render_state.endFrame();
    try std.testing.expect(!render_state.isFrameActive());
}

test "armed ui screenshot capture reads back the rendered frame" {
    try Context.init(null);
    defer Context.deinit();

    // Fullscreen triangle rendered solid orange (R!=B so the channel swap is
    // actually exercised); the readback must return that pixel as RGBA
    // (origin-correct + BGRA->RGBA swap), proving the in-frame blit + shared
    // buffer + readback path works on a real Metal device.
    const vs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\vertex float4 vertex_main(uint vertex_id [[vertex_id]]) {
        \\    float2 positions[3] = {
        \\        float2(-1.0, -1.0),
        \\        float2( 3.0, -1.0),
        \\        float2(-1.0,  3.0),
        \\    };
        \\    return float4(positions[vertex_id], 0.0, 1.0);
        \\}
    ;
    const fs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\fragment float4 fragment_main() {
        \\    return float4(1.0, 0.5, 0.0, 1.0);
        \\}
    ;

    var pipeline = Pipeline.init(vs, fs, 0);
    defer pipeline.deinit();

    render_state.clear(0, 0, 0, 1);
    render_state.armUiScreenshotCapture();
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());
    render_state.endFrame();

    // Standalone layer is 64x64 (Context.init). Read a 1x1 at the origin.
    const px = try readback.readRgba(std.testing.allocator, 0, 0, 1, 1);
    defer std.testing.allocator.free(px);
    try std.testing.expectEqual(@as(usize, 4), px.len);
    try std.testing.expect(px[0] >= 254); // R ~ 255
    try std.testing.expect(px[1] >= 126 and px[1] <= 130); // G ~ 128
    try std.testing.expect(px[2] <= 1); // B ~ 0
    try std.testing.expectEqual(@as(u8, 255), px[3]); // A
}

test "viewport and scissor apply to the encoder without breaking draws" {
    try Context.init(null);
    defer Context.deinit();

    const vs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\vertex float4 vertex_main(uint vertex_id [[vertex_id]]) {
        \\    float2 positions[3] = {
        \\        float2(-1.0, -1.0),
        \\        float2( 3.0, -1.0),
        \\        float2(-1.0,  3.0),
        \\    };
        \\    return float4(positions[vertex_id], 0.0, 1.0);
        \\}
    ;
    const fs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\fragment float4 fragment_main() {
        \\    return float4(0.0, 0.0, 1.0, 1.0);
        \\}
    ;

    var pipeline = Pipeline.init(vs, fs, 0);
    defer pipeline.deinit();

    render_state.clear(0, 0, 0, 1);

    // A sub-rectangle viewport + scissor (GL lower-left convention) — the split
    // pane case. The standalone test layer is 64x64, so these stay in bounds.
    render_state.setViewport(10, 10, 40, 30);
    render_state.setScissor(.{ .x = 12, .y = 12, .w = 20, .h = 16 });
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    // Disabling scissor must reset to the full drawable and still draw.
    render_state.disableScissor();
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    // An intentionally out-of-bounds scissor must be clamped, not crash the
    // command buffer (MTLScissorRect outside the render target raises).
    render_state.setScissor(.{ .x = -100, .y = -100, .w = 100000, .h = 100000 });
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    render_state.endFrame();
}

test "blend modes select pipeline variants without breaking draws" {
    try Context.init(null);
    defer Context.deinit();

    const vs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\vertex float4 vertex_main(uint vertex_id [[vertex_id]]) {
        \\    float2 positions[3] = {
        \\        float2(-1.0, -1.0),
        \\        float2( 3.0, -1.0),
        \\        float2(-1.0,  3.0),
        \\    };
        \\    return float4(positions[vertex_id], 0.0, 1.0);
        \\}
    ;
    const fs: [*c]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\fragment float4 fragment_main() {
        \\    return float4(0.5, 0.5, 0.5, 0.5);
        \\}
    ;

    var pipeline = Pipeline.init(vs, fs, 0);
    defer pipeline.deinit();
    try std.testing.expect(pipeline.program != 0);

    render_state.clear(0, 0, 0, 1);

    // Each blend mode must pick a valid pre-built PSO and draw successfully.
    render_state.setBlendEnabled(true);
    render_state.setBlendMode(.alpha);
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    render_state.setBlendMode(.premultiplied);
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    render_state.setBlendEnabled(false);
    pipeline.drawArrays(.triangles, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    render_state.setBlendEnabled(true);
    render_state.setBlendMode(.alpha);
    render_state.endFrame();
}

test "vertex builder returns stable nonzero layout handles" {
    try Context.init(null);
    defer Context.deinit();

    var buffer = Buffer.initVertex();
    defer buffer.deinit();
    const verts = [_]f32{ 0, 0, 1, 0, 1, 1 };
    buffer.uploadData(std.mem.sliceAsBytes(&verts), .static);

    const attrs = [_]vertex.VertexAttr{
        .{ .loc = 0, .count = 2, .stride = 2 * @sizeOf(f32), .offset = 0 },
    };
    const layouts = [_]vertex.BufferLayout{
        .{ .buffer = buffer, .attrs = &attrs },
    };
    const vao = vertex.buildVertexArray(&layouts);
    defer vertex.deleteVertexArray(vao);

    try std.testing.expect(vao != 0);
}

test "gl_init compatibility helpers do not panic on Metal" {
    try Context.init(null);
    defer Context.deinit();

    try std.testing.expect(gl_init.initShaders());
    gl_init.g_draw_call_count = 0;
    gl_init.setProjection(80, 40);
    gl_init.renderQuad(1, 2, 3, 4, .{ 1, 0, 0 });
    gl_init.renderQuadAlpha(1, 2, 3, 4, .{ 0, 1, 0 }, 0.5);
    // The render helpers now dispatch through BackendHooks installed by
    // ui_pipeline.init() in the real app; the Metal smoke test runs without
    // that registration, so the helpers are no-ops here and the draw counter
    // stays at zero. The test still checks the calls don't panic.
    try std.testing.expectEqual(@as(u32, 0), gl_init.g_draw_call_count);

    // Verify BackendHooks dispatch fires when a hook table is installed.
    const HookCounter = struct {
        var calls: u32 = 0;
        fn fillQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
            _ = x;
            _ = y;
            _ = w;
            _ = h;
            _ = color;
            calls += 1;
        }
        fn fillQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
            _ = x;
            _ = y;
            _ = w;
            _ = h;
            _ = color;
            _ = alpha;
            calls += 1;
        }
        fn setProjection(width: f32, height: f32) void {
            _ = width;
            _ = height;
            calls += 1;
        }
    };
    HookCounter.calls = 0;
    gl_init.setBackendHooks(.{
        .fillQuad = &HookCounter.fillQuad,
        .fillQuadAlpha = &HookCounter.fillQuadAlpha,
        .setProjection = &HookCounter.setProjection,
    });
    defer gl_init.clearBackendHooks();
    gl_init.setProjection(80, 40);
    gl_init.renderQuad(1, 2, 3, 4, .{ 1, 0, 0 });
    gl_init.renderQuadAlpha(1, 2, 3, 4, .{ 0, 1, 0 }, 0.5);
    try std.testing.expectEqual(@as(u32, 3), HookCounter.calls);

    gl_init.syncSharedHandles();
    gl_init.setProjectionForProgram(0, 40);
}

test "bundled Metal shader set compiles into pipeline states" {
    try Context.init(null);
    defer Context.deinit();

    const pairs = [_]struct { vs: [*c]const u8, fs: [*c]const u8 }{
        .{ .vs = shaders.vertex_shader_source, .fs = shaders.fragment_shader_source },
        .{ .vs = shaders.vertex_shader_source, .fs = shaders.simple_color_fragment_source },
        .{ .vs = shaders.vertex_shader_source, .fs = shaders.overlay_fragment_source },
        .{ .vs = shaders.bg_vertex_source, .fs = shaders.bg_fragment_source },
        .{ .vs = shaders.fg_vertex_source, .fs = shaders.fg_fragment_source },
        .{ .vs = shaders.fg_vertex_source, .fs = shaders.color_fg_fragment_source },
        .{ .vs = shaders.ui_batch_vertex_source, .fs = shaders.ui_batch_fragment_source },
    };

    for (pairs) |pair| {
        var pipeline = Pipeline.init(pair.vs, pair.fs, 0);
        defer pipeline.deinit();
        try std.testing.expect(pipeline.program != 0);
    }
}

fn expectPixel(x: i32, y: i32, rgb: [3]u8) !void {
    const px = try readback.readRgba(std.testing.allocator, x, y, 1, 1);
    defer std.testing.allocator.free(px);
    for (rgb, 0..) |want, i| try std.testing.expect(@abs(@as(i32, px[i]) - @as(i32, want)) <= 1);
}

fn clipQuad(x0: f32, x1: f32) [6][4]f32 {
    return .{
        .{ x0, 1, 0, 0 }, .{ x0, -1, 0, 1 }, .{ x1, -1, 1, 1 },
        .{ x0, 1, 0, 0 }, .{ x1, -1, 1, 1 }, .{ x1, 1, 1, 0 },
    };
}

test "transient uploads in one frame keep their own bytes until the GPU reads them" {
    try Context.init(null);
    defer Context.deinit();

    // Two upload+draw pairs through ONE buffer handle in one frame: the
    // deferred-read hazard from docs/macos-ui-lessons.md (Bug #2). Each draw
    // must read the bytes uploaded just before it, not the last upload.
    var quad = Buffer.initVertex();
    defer quad.deinit();
    const vao = vertex.buildVertexArray(&.{.{
        .buffer = quad,
        .attrs = &.{.{ .loc = 0, .count = 4, .stride = 4 * @sizeOf(f32), .offset = 0 }},
    }});
    defer vertex.deleteVertexArray(vao);
    var pipeline = Pipeline.init(shaders.vertex_shader_source, shaders.overlay_fragment_source, vao);
    defer pipeline.deinit();
    try std.testing.expect(pipeline.program != 0);

    for (0..2) |_| { // a second frame starts a fresh arena
        render_state.clear(0, 0, 0, 1);
        render_state.setViewport(0, 0, 64, 64); // earlier tests leave sub-viewports behind
        render_state.disableScissor();
        render_state.armUiScreenshotCapture();
        const left = clipQuad(-1, 0);
        quad.uploadTransient(std.mem.sliceAsBytes(&left));
        pipeline.setVec4("overlayColor", 1, 0, 0, 1);
        pipeline.drawArrays(.triangles, 0, 6);
        try std.testing.expect(Pipeline.lastDrawSucceeded());
        const right = clipQuad(0, 1);
        quad.uploadTransient(std.mem.sliceAsBytes(&right));
        pipeline.setVec4("overlayColor", 0, 1, 0, 1);
        pipeline.drawArrays(.triangles, 0, 6);
        try std.testing.expect(Pipeline.lastDrawSucceeded());
        render_state.endFrame();

        try expectPixel(10, 32, .{ 255, 0, 0 });
        try expectPixel(54, 32, .{ 0, 255, 0 });
    }
}

test "UI batch shader draws instanced glyph quads with per-instance color" {
    try Context.init(null);
    defer Context.deinit();

    // Mirrors renderer/ui_batch.zig `Instance` (44-byte GPU instance layout);
    // the test module root cannot import it.
    const Instance = extern struct { x: f32, y: f32, w: f32, h: f32, u0: f32, v0: f32, u1: f32, v1: f32, r: f32, g: f32, b: f32 };
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(Instance));

    var unit_quad = Buffer.initVertex();
    defer unit_quad.deinit();
    const corners = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
    unit_quad.uploadData(std.mem.sliceAsBytes(&corners), .static);
    var instances = Buffer.initVertex();
    defer instances.deinit();
    const vao = vertex.buildVertexArray(&.{
        .{ .buffer = unit_quad, .attrs = &.{.{ .loc = 0, .count = 2, .stride = 2 * @sizeOf(f32), .offset = 0 }} },
        .{ .buffer = instances, .attrs = &.{.{ .loc = 1, .count = 4, .stride = @sizeOf(Instance), .offset = 0, .divisor = 1 }} },
    });
    defer vertex.deleteVertexArray(vao);
    var pipeline = Pipeline.init(shaders.ui_batch_vertex_source, shaders.ui_batch_fragment_source, vao);
    defer pipeline.deinit();
    try std.testing.expect(pipeline.program != 0);

    var solid = Texture.create();
    defer solid.destroy();
    const white = [_]u8{255};
    solid.upload2D(1, 1, &white, .{ .format = .r8, .sampler = .nearest_clamp, .unpack_alignment = 1 });

    const w: f32 = 64;
    const h: f32 = 64;
    const projection = [16]f32{
        2.0 / w, 0.0,     0.0,  0.0,
        0.0,     2.0 / h, 0.0,  0.0,
        0.0,     0.0,     -1.0, 0.0,
        -1.0,    -1.0,    0.0,  1.0,
    };
    const batch = [_]Instance{
        .{ .x = 0, .y = 0, .w = 32, .h = 64, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .r = 1, .g = 0, .b = 0 },
        .{ .x = 32, .y = 0, .w = 32, .h = 32, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .r = 0, .g = 0, .b = 1 },
    };

    render_state.clear(0, 0, 0, 1);
    render_state.setViewport(0, 0, 64, 64);
    render_state.disableScissor();
    render_state.armUiScreenshotCapture();
    pipeline.use();
    pipeline.setMat4("projection", &projection);
    solid.bind(0);
    instances.uploadTransient(std.mem.sliceAsBytes(&batch));
    pipeline.drawArraysInstanced(.triangle_strip, 0, 4, batch.len);
    try std.testing.expect(Pipeline.lastDrawSucceeded());
    render_state.endFrame();

    try expectPixel(10, 50, .{ 255, 0, 0 }); // first instance, full height
    try expectPixel(50, 10, .{ 0, 0, 255 }); // second instance, bottom half
    try expectPixel(50, 50, .{ 0, 0, 0 }); // outside both
}

test "state and pipeline-use hooks fire before every batch-visible change" {
    try Context.init(null);
    defer Context.deinit();

    const Counter = struct {
        var changes: u32 = 0;
        var uses: u32 = 0;
        fn change() void {
            changes += 1;
        }
        fn use(program: @import("../types.zig").ProgramHandle) void {
            _ = program;
            uses += 1;
        }
    };
    Counter.changes = 0;
    Counter.uses = 0;
    render_state.pre_change_hook = &Counter.change;
    defer render_state.pre_change_hook = null;
    Pipeline.pre_use_hook = &Counter.use;
    defer Pipeline.pre_use_hook = null;

    render_state.clear(0, 0, 0, 1);
    render_state.setViewport(0, 0, 64, 64);
    render_state.setScissor(.{ .x = 0, .y = 0, .w = 8, .h = 8 });
    const saved = render_state.scissorState();
    render_state.disableScissor();
    render_state.restoreScissor(saved);
    render_state.setBlendEnabled(true);
    render_state.setBlendMode(.alpha);
    var fb = Framebuffer.initColor(8, 8) orelse return error.FramebufferUnavailable;
    defer fb.deinit();
    fb.bind(); // its own hook + the viewport it sets
    Framebuffer.unbind();
    render_state.endFrame();
    try std.testing.expectEqual(@as(u32, 11), Counter.changes);

    const pipeline = Pipeline{ .program = 7, .vao = 0 };
    pipeline.use();
    try std.testing.expectEqual(@as(u32, 1), Counter.uses);
}
