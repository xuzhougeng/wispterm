//! Metal backend render pipeline. Mirrors `gpu/opengl/Pipeline.zig`'s public
//! surface: fields `program`/`vao` and every method the renderer calls
//! (`use`, `bindVao`, `setVec2/3/4`, `setFloat`, `setInt`, `setMat4`,
//! `setProjection`, `drawArrays`, `drawArraysInstanced`, `deinit`, the public
//! `compileShader`, and `init`).
//!
//! Note: callers pass MSL sources (from `gpu/metal/shaders.zig`) to `init`.
//! `program` is a registry id for an Objective-C-retained
//! `MTLRenderPipelineState`; `vao` is the backend vertex-layout id. The
//! `program != 0` "link succeeded" convention the callers guard on is preserved.
const std = @import("std");

const Context = @import("Context.zig");
const c = @import("c.zig");
const render_state = @import("render_state.zig");
const types = @import("../types.zig");
const vertex = @import("vertex.zig");
const Pipeline = @This();

program: types.ProgramHandle,
vao: types.VertexArrayHandle,

extern fn wispterm_metal_pipeline_create(device: ?*anyopaque, vs_src: [*c]const u8, fs_src: [*c]const u8, vao: c.GLuint, error_buf: [*]u8, error_buf_len: usize) c.GLuint;
extern fn wispterm_metal_pipeline_destroy(program: c.GLuint) void;
extern fn wispterm_metal_pipeline_set_float(program: c.GLuint, name: [*c]const u8, value: f32) void;
extern fn wispterm_metal_pipeline_set_int(program: c.GLuint, name: [*c]const u8, value: i32) void;
extern fn wispterm_metal_pipeline_set_vec2(program: c.GLuint, name: [*c]const u8, x: f32, y: f32) void;
extern fn wispterm_metal_pipeline_set_vec3(program: c.GLuint, name: [*c]const u8, x: f32, y: f32, z: f32) void;
extern fn wispterm_metal_pipeline_set_vec4(program: c.GLuint, name: [*c]const u8, x: f32, y: f32, z: f32, w: f32) void;
extern fn wispterm_metal_pipeline_set_mat4(program: c.GLuint, name: [*c]const u8, values: *const [16]f32) void;
extern fn wispterm_metal_pipeline_draw_arrays(ctx: *Context.Handles, program: c.GLuint, mode: c.GLenum, first: c.GLint, count: c.GLsizei, instances: c.GLsizei, buffer0: c.GLuint, buffer1: c.GLuint, error_buf: [*]u8, error_buf_len: usize) bool;

threadlocal var last_draw_succeeded = false;

/// Compile a shader stage. Returns null on failure (mirrors the OpenGL failure path).
pub fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    _ = shader_type;
    const program = wispterm_metal_pipeline_create(Context.deviceHandle(), source, empty_fragment_shader, 0, &scratch_error, scratch_error.len);
    return if (program == 0) null else program;
}

/// Build a pipeline from vertex/fragment sources, paired with a caller-built
/// VAO handle.
pub fn init(vs_src: [*c]const u8, fs_src: [*c]const u8, vao: types.VertexArrayHandle) Pipeline {
    const program = wispterm_metal_pipeline_create(Context.deviceHandle(), vs_src, fs_src, @intCast(vao), &scratch_error, scratch_error.len);
    if (program == 0) {
        const end = std.mem.indexOfScalar(u8, &scratch_error, 0) orelse scratch_error.len;
        std.debug.print("Metal pipeline init failed: {s}\n", .{scratch_error[0..end]});
    }
    return .{ .program = @intCast(program), .vao = vao };
}

fn backendProgram(self: Pipeline) c.GLuint {
    return @intCast(self.program);
}

pub fn use(self: Pipeline) void {
    _ = self;
    // Bound on the render command encoder when draw calls are encoded.
}
pub fn bindVao(self: Pipeline) void {
    _ = self;
    // Vertex layouts are tracked by the VAO/vertex registry.
}
pub fn setVec2(self: Pipeline, name: [*c]const u8, x: f32, y: f32) void {
    wispterm_metal_pipeline_set_vec2(self.backendProgram(), name, x, y);
}
pub fn setFloat(self: Pipeline, name: [*c]const u8, v: f32) void {
    wispterm_metal_pipeline_set_float(self.backendProgram(), name, v);
}
pub fn setInt(self: Pipeline, name: [*c]const u8, v: i32) void {
    wispterm_metal_pipeline_set_int(self.backendProgram(), name, v);
}
pub fn setProjection(self: Pipeline) void {
    const size = render_state.viewportSize();
    if (size.w <= 0 or size.h <= 0) return;
    const width: f32 = @floatFromInt(size.w);
    const height: f32 = @floatFromInt(size.h);
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };
    self.setMat4("projection", &projection);
}
pub fn setMat4(self: Pipeline, name: [*c]const u8, m: *const [16]f32) void {
    wispterm_metal_pipeline_set_mat4(self.backendProgram(), name, m);
}
pub fn setVec3(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32) void {
    wispterm_metal_pipeline_set_vec3(self.backendProgram(), name, x, y, z);
}
pub fn setVec4(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32, w: f32) void {
    wispterm_metal_pipeline_set_vec4(self.backendProgram(), name, x, y, z, w);
}
pub fn drawArrays(self: Pipeline, topology: types.PrimitiveTopology, first: c.GLint, count: c.GLsizei) void {
    draw(self, topology, first, count, 1);
}
pub fn drawArraysInstanced(self: Pipeline, topology: types.PrimitiveTopology, first: c.GLint, count: c.GLsizei, instances: c.GLsizei) void {
    draw(self, topology, first, count, instances);
}
pub fn deinit(self: *Pipeline) void {
    if (self.program != 0) wispterm_metal_pipeline_destroy(@intCast(self.program));
    self.* = .{ .program = 0, .vao = 0 };
}

threadlocal var scratch_error: [512]u8 = @splat(0);

fn topologyEnum(topology: types.PrimitiveTopology) c.GLenum {
    return switch (topology) {
        .triangles => c.GL_TRIANGLES,
        .triangle_strip => c.GL_TRIANGLE_STRIP,
    };
}

fn draw(self: Pipeline, topology: types.PrimitiveTopology, first: c.GLint, count: c.GLsizei, instances: c.GLsizei) void {
    const buffer0 = vertex.bufferHandle(self.vao, 0);
    const buffer1 = vertex.bufferHandle(self.vao, 1);
    last_draw_succeeded = wispterm_metal_pipeline_draw_arrays(
        &Context.handles,
        self.backendProgram(),
        topologyEnum(topology),
        first,
        count,
        instances,
        buffer0,
        buffer1,
        &scratch_error,
        scratch_error.len,
    );
    if (!last_draw_succeeded) {
        const end = std.mem.indexOfScalar(u8, &scratch_error, 0) orelse scratch_error.len;
        std.debug.print("Metal draw failed: {s}\n", .{scratch_error[0..end]});
    }
}

pub fn lastDrawSucceeded() bool {
    return last_draw_succeeded;
}

const empty_fragment_shader: [*c]const u8 =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\fragment float4 fragment_main() {
    \\    return float4(1.0);
    \\}
;
