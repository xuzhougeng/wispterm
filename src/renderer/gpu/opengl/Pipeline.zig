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
fn linkProgram(vs_src: [*c]const u8, fs_src: [*c]const u8) c.GLuint {
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

/// Build a pipeline: link the program and pair it with a caller-built VAO (the
/// vertex-attribute layout is shader-specific, so the caller owns it). On link
/// failure `program` is 0; callers guard draws on `program != 0`.
pub fn init(vs_src: [*c]const u8, fs_src: [*c]const u8, vao: c.GLuint) Pipeline {
    return .{ .program = linkProgram(vs_src, fs_src), .vao = vao };
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
/// Set the orthographic projection uniform from the current GL viewport
/// (matches the previous gl_init.setProjectionForProgram behavior).
pub fn setProjection(self: Pipeline) void {
    const gl = Context.gl;
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const width: f32 = @floatFromInt(viewport[2]);
    const height: f32 = @floatFromInt(viewport[3]);
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(self.program, "projection"), 1, c.GL_FALSE, &projection);
}
pub fn setVec3(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32) void {
    Context.gl.Uniform3f.?(Context.gl.GetUniformLocation.?(self.program, name), x, y, z);
}
pub fn setVec4(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32, w: f32) void {
    Context.gl.Uniform4f.?(Context.gl.GetUniformLocation.?(self.program, name), x, y, z, w);
}
/// Non-instanced draw against the currently-bound program/VAO. Does NOT touch
/// any draw-call counter (callers tick their own, same as drawArraysInstanced).
pub fn drawArrays(self: Pipeline, mode: c.GLenum, first: c.GLint, count: c.GLsizei) void {
    _ = self;
    Context.gl.DrawArrays.?(mode, first, count);
}
/// Issue an instanced draw against the currently-bound program/VAO. `self` is
/// unused today (the bound state carries the pipeline); kept as a method for
/// call-site ergonomics and so a future backend can attach per-pipeline state.
pub fn drawArraysInstanced(self: Pipeline, mode: c.GLenum, first: c.GLint, count: c.GLsizei, instances: c.GLsizei) void {
    _ = self;
    Context.gl.DrawArraysInstanced.?(mode, first, count, instances);
}
pub fn deinit(self: *Pipeline) void {
    if (self.program != 0) Context.gl.DeleteProgram.?(self.program);
    if (self.vao != 0) Context.gl.DeleteVertexArrays.?(1, &self.vao);
    self.* = .{ .program = 0, .vao = 0 };
}
