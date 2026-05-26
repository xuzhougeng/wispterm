//! OpenGL shader-compilation helpers + the overlay shader, plus the transition
//! compat shim for the shared UI pipelines.
//!
//! Owns: `compileShader`/`linkProgram`, the `overlay_shader`, `setProjectionForProgram`.
//! Compat mirrors: `vao`/`vbo`/`shader_program`/`simple_color_shader` are populated
//!   by `syncSharedHandles()` after `ui_pipeline.init()`; not-yet-converted renderer
//!   files still read them directly. They dissolve as each file converts.
//! Re-exports: `renderQuad`/`renderQuadAlpha`/`setProjection` delegate to ui_pipeline.
//! The shared UI rendering lives in renderer/ui_pipeline.zig; the cell-grid
//! instanced pipelines in renderer/cell_pipeline.zig.

const std = @import("std");
const AppWindow = @import("../../../AppWindow.zig");

const c = @cImport({
    @cInclude("glad/gl.h");
});

const shaders = @import("shaders.zig");
const ui_pipeline = @import("../../ui_pipeline.zig");

// ============================================================================
// GL object handles
// ============================================================================

// Compat mirror handles, populated by syncSharedHandles() after ui_pipeline.init().
// Transition shim: not-yet-converted renderer files still read these directly.
// They dissolve as each file converts to ui_pipeline.
pub threadlocal var vao: c.GLuint = 0; // compat mirror — from ui_pipeline.text.vao
pub threadlocal var vbo: c.GLuint = 0; // compat mirror — from ui_pipeline.quad.handle
pub threadlocal var shader_program: c.GLuint = 0; // compat mirror — from ui_pipeline.text.program
pub threadlocal var simple_color_shader: c.GLuint = 0; // compat mirror — from ui_pipeline.emoji.program

pub threadlocal var overlay_shader: c.GLuint = 0; // gl_init-owned — compiled in initShaders()

// Draw call counter (reset each frame)
pub threadlocal var g_draw_call_count: u32 = 0;

// Opacity for cell background quads (0..1). Set from config
// `background-opacity`; lower values reveal the background image underneath.
pub threadlocal var g_bg_opacity: f32 = 1.0;

// ============================================================================
// Shader compilation and linking
// ============================================================================

pub fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    const gl = AppWindow.gpu.glTable();
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

fn linkProgram(vs_src: [*c]const u8, fs_src: [*c]const u8) c.GLuint {
    const gl = AppWindow.gpu.glTable();
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

// ============================================================================
// Initialization
// ============================================================================

pub fn initShaders() bool {
    overlay_shader = linkProgram(shaders.vertex_shader_source, shaders.overlay_fragment_source);
    if (overlay_shader == 0) {
        std.debug.print("Overlay shader failed\n", .{});
        return false;
    }
    return true;
}

// ============================================================================
// Render helpers — re-export wrappers delegating to ui_pipeline
// ============================================================================

pub fn renderQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    ui_pipeline.fillQuad(x, y, w, h, color);
}
pub fn renderQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    ui_pipeline.fillQuadAlpha(x, y, w, h, color, alpha);
}
pub fn setProjection(width: f32, height: f32) void {
    ui_pipeline.setProjection(width, height);
}

// ============================================================================
// Compat shim — populate the mirror handles from ui_pipeline (transition)
// ============================================================================

/// Populate the compat mirror handles from the ui_pipeline-owned objects.
/// Call right after ui_pipeline.init().
pub fn syncSharedHandles() void {
    shader_program = ui_pipeline.text.program;
    simple_color_shader = ui_pipeline.emoji.program;
    vao = ui_pipeline.text.vao;
    vbo = ui_pipeline.quad.handle;
}

/// Set the orthographic projection matrix on a specific shader program.
pub fn setProjectionForProgram(program: c.GLuint, window_height: f32) void {
    const gl = AppWindow.gpu.glTable();
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

    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(program, "projection"), 1, c.GL_FALSE, &projection);
}
