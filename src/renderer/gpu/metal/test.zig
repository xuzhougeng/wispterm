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

    var buffer = Buffer.init(c.GL_ARRAY_BUFFER);
    defer buffer.deinit();

    try std.testing.expect(buffer.handle != 0);

    buffer.allocate(16, c.GL_DYNAMIC_DRAW);
    try std.testing.expectEqual(@as(usize, 16), buffer.byteLength());

    const initial = [_]u8{ 1, 2, 3, 4 };
    buffer.uploadData(&initial, c.GL_STATIC_DRAW);
    try std.testing.expectEqual(@as(usize, initial.len), buffer.byteLength());

    const update = [_]u8{ 9, 8, 7, 6 };
    buffer.upload(&update);
    try std.testing.expectEqual(@as(usize, initial.len), buffer.byteLength());
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
        .internal_format = c.GL_RGBA8,
        .format = c.GL_RGBA,
        .unpack_alignment = 1,
    });
    try std.testing.expectEqual(@as(c_int, 2), texture.levelWidth());

    const pixel = [_]u8{ 12, 34, 56, 78 };
    texture.subImage2D(1, 1, 1, 1, &pixel, .{
        .internal_format = c.GL_RGBA8,
        .format = c.GL_RGBA,
        .unpack_alignment = 1,
    });
    texture.setWrap(.repeat);
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
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
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
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
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
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
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
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    // Disabling scissor must reset to the full drawable and still draw.
    render_state.disableScissor();
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    // An intentionally out-of-bounds scissor must be clamped, not crash the
    // command buffer (MTLScissorRect outside the render target raises).
    render_state.setScissor(.{ .x = -100, .y = -100, .w = 100000, .h = 100000 });
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
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
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    render_state.setBlendMode(.premultiplied);
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    render_state.setBlendEnabled(false);
    pipeline.drawArrays(c.GL_TRIANGLES, 0, 3);
    try std.testing.expect(Pipeline.lastDrawSucceeded());

    render_state.setBlendEnabled(true);
    render_state.setBlendMode(.alpha);
    render_state.endFrame();
}

test "vertex builder returns stable nonzero layout handles" {
    try Context.init(null);
    defer Context.deinit();

    var buffer = Buffer.init(c.GL_ARRAY_BUFFER);
    defer buffer.deinit();
    const verts = [_]f32{ 0, 0, 1, 0, 1, 1 };
    buffer.uploadData(std.mem.sliceAsBytes(&verts), c.GL_STATIC_DRAW);

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
    };

    for (pairs) |pair| {
        var pipeline = Pipeline.init(pair.vs, pair.fs, 0);
        defer pipeline.deinit();
        try std.testing.expect(pipeline.program != 0);
    }
}
