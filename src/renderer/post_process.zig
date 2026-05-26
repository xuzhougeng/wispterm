//! Post-processing custom shader system (Ghostty-compatible).
//!
//! Ghostty custom shaders use Shadertoy-style conventions:
//!   - iResolution: vec3 (viewport resolution in pixels, z=1.0)
//!   - iTime: float (elapsed time in seconds)
//!   - iTimeDelta: float (time since last frame)
//!   - iFrame: int (frame counter)
//!   - iChannel0: sampler2D (the terminal framebuffer)
//!   - iChannelResolution[0]: vec3 (texture resolution)
//!
//! The shader must define: void mainImage(out vec4 fragColor, in vec2 fragCoord)

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const gpu = AppWindow.gpu;
const c = gpu.c;
const ui_pipeline = @import("ui_pipeline.zig");
const cell_renderer = AppWindow.cell_renderer;
const background_image = AppWindow.background_image;
const Renderer = @import("Renderer.zig");

// Post-processing state (gpu-primitive-backed)
threadlocal var g_post_fb: gpu.Framebuffer = .{};
threadlocal var g_post_pipeline: gpu.Pipeline = .{ .program = 0, .vao = 0 };
threadlocal var g_post_vbo_buf: gpu.Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var g_post_enabled: bool = false; // Whether custom shader is active
threadlocal var g_frame_count: u32 = 0; // Frame counter for iFrame
threadlocal var g_start_time: i64 = 0; // Start time for iTime

/// Vertex shader for the fullscreen post-processing quad
const post_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\layout (location = 1) in vec2 aTexCoord;
    \\out vec2 vTexCoord;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.0, 1.0);
    \\    vTexCoord = aTexCoord;
    \\}
;

/// Build the post-processing fragment shader by wrapping a Ghostty/Shadertoy-style
/// mainImage shader with our uniform declarations and main() entry point.
fn buildPostFragmentSource(allocator: std.mem.Allocator, user_shader: []const u8) ![:0]const u8 {
    const preamble =
        \\#version 330 core
        \\out vec4 _fragColor;
        \\in vec2 vTexCoord;
        \\
        \\uniform vec3 iResolution;
        \\uniform float iTime;
        \\uniform float iTimeDelta;
        \\uniform int iFrame;
        \\uniform sampler2D iChannel0;
        \\uniform vec3 iChannelResolution[1];
        \\
        \\// Provide textureLod via extension or fallback
        \\
    ;
    const epilogue =
        \\
        \\void main() {
        \\    vec2 fragCoord = vTexCoord * iResolution.xy;
        \\    mainImage(_fragColor, fragCoord);
        \\}
    ;

    const total_len = preamble.len + user_shader.len + epilogue.len;
    const buf = try allocator.alloc(u8, total_len + 1); // +1 for sentinel
    @memcpy(buf[0..preamble.len], preamble);
    @memcpy(buf[preamble.len..][0..user_shader.len], user_shader);
    @memcpy(buf[preamble.len + user_shader.len ..][0..epilogue.len], epilogue);
    buf[total_len] = 0; // null-terminate

    return buf[0..total_len :0];
}

/// Load and compile a custom post-processing shader from a file
fn initPostShader(allocator: std.mem.Allocator, shader_path: []const u8) bool {
    const gl = gpu.glTable();
    // Read shader source file
    const file = std.fs.cwd().openFile(shader_path, .{}) catch |err| {
        std.debug.print("Failed to open shader file '{s}': {}\n", .{ shader_path, err });
        return false;
    };
    defer file.close();

    const user_source = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read shader file: {}\n", .{err});
        return false;
    };
    defer allocator.free(user_source);

    // Build complete fragment shader
    const frag_source = buildPostFragmentSource(allocator, user_source) catch |err| {
        std.debug.print("Failed to build shader source: {}\n", .{err});
        return false;
    };
    defer allocator.free(frag_source);

    // Set up fullscreen quad VAO/VBO
    // Two triangles covering [-1,1] NDC with tex coords [0,1]
    const quad_verts = [_]f32{
        // pos      // tex
        -1.0, -1.0, 0.0, 0.0,
        1.0,  -1.0, 1.0, 0.0,
        -1.0, 1.0,  0.0, 1.0,

        1.0,  -1.0, 1.0, 0.0,
        1.0,  1.0,  1.0, 1.0,
        -1.0, 1.0,  0.0, 1.0,
    };

    g_post_vbo_buf = gpu.Buffer.init(c.GL_ARRAY_BUFFER);
    g_post_vbo_buf.uploadData(std.mem.sliceAsBytes(quad_verts[0..]), c.GL_STATIC_DRAW);

    var vao: c.GLuint = 0;
    gl.GenVertexArrays.?(1, &vao);
    gl.BindVertexArray.?(vao);
    g_post_vbo_buf.bind();
    // position (location 0)
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    // texcoord (location 1)
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
    gl.BindVertexArray.?(0);

    // Compile and link via Pipeline.init (logs errors itself)
    g_post_pipeline = gpu.Pipeline.init(post_vertex_source, frag_source.ptr, vao);
    if (g_post_pipeline.program == 0) {
        // Pipeline.init already logged the failure; clean up vbo and vao
        g_post_vbo_buf.deinit();
        gl.DeleteVertexArrays.?(1, &vao);
        return false;
    }

    std.debug.print("Custom shader loaded: {s}\n", .{shader_path});
    return true;
}

/// Create or resize the off-screen framebuffer for post-processing
fn ensurePostFBO(width: c_int, height: c_int) void {
    if (g_post_fb.width == width and g_post_fb.height == height and g_post_fb.handle != 0) return;

    if (g_post_fb.handle != 0) g_post_fb.deinit();

    g_post_fb = gpu.Framebuffer.initColor(width, height) orelse return;
}

/// Render the fullscreen quad with post-processing shader applied
fn renderPostProcess(width: c_int, height: c_int) void {
    const gl = gpu.glTable();
    // Bind default framebuffer (screen)
    gpu.Framebuffer.unbind();
    gl.Viewport.?(0, 0, width, height);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

    // Disable blending for the fullscreen quad - shader output is final color
    ui_pipeline.setBlendEnabled(false);

    g_post_pipeline.use();

    // Set uniforms (Ghostty/Shadertoy conventions)
    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    const now_ms = std.time.milliTimestamp();
    const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(now_ms - g_start_time)) / 1000.0);

    g_post_pipeline.setVec3("iResolution", w_f, h_f, 1.0);
    g_post_pipeline.setFloat("iTime", elapsed);
    g_post_pipeline.setFloat("iTimeDelta", 0.016);
    g_post_pipeline.setInt("iFrame", @intCast(g_frame_count));
    g_post_pipeline.setInt("iChannel0", 0);
    g_post_pipeline.setVec3("iChannelResolution[0]", w_f, h_f, 1.0);

    // Bind the terminal framebuffer texture
    gpu.Texture.fromHandle(g_post_fb.color).bind(0);

    // Draw fullscreen quad
    g_post_pipeline.bindVao();
    g_post_pipeline.drawArrays(c.GL_TRIANGLES, 0, 6);
    AppWindow.gpu.gl_init.g_draw_call_count += 1;

    // Re-enable blending for next terminal render pass
    ui_pipeline.setBlendEnabled(true);

    g_frame_count +%= 1;
}

/// Helper: render a frame to FBO, then apply post-processing to screen.
/// Render with post-processing. Called after updateTerminalCells() has
/// already been called under the lock — this only does GL work.
pub fn renderFrameWithPostFromCells(rend: *const Renderer, width: c_int, height: c_int, padding: f32) void {
    const gl = gpu.glTable();
    ensurePostFBO(width, height);

    // 1. Render terminal to FBO
    g_post_fb.bind();
    ui_pipeline.setProjection(@floatFromInt(width), @floatFromInt(height));
    gl.ClearColor.?(AppWindow.g_theme.background[0], AppWindow.g_theme.background[1], AppWindow.g_theme.background[2], 1.0);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
    background_image.drawFullscreen(@floatFromInt(width), @floatFromInt(height));
    cell_renderer.drawCells(rend, @floatFromInt(height), padding, padding);

    // 2. Apply post-processing shader to screen
    renderPostProcess(width, height);
}

/// Initialize post-processing from a shader path. Returns true if enabled.
pub fn init(allocator: std.mem.Allocator, shader_path: ?[]const u8) void {
    const sp = shader_path orelse return;
    if (initPostShader(allocator, sp)) {
        g_post_enabled = true;
        g_start_time = std.time.milliTimestamp();
    } else {
        std.debug.print("Warning: custom shader failed to load, continuing without it\n", .{});
    }
}

/// Clean up post-processing GL resources.
pub fn deinit() void {
    if (!g_post_enabled) return;
    g_post_pipeline.deinit();
    g_post_vbo_buf.deinit();
    g_post_fb.deinit();
}
