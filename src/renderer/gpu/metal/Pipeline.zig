//! Metal backend render pipeline. Mirrors `gpu/opengl/Pipeline.zig`'s public
//! surface: fields `program`/`vao` and every method the renderer calls
//! (`use`, `bindVao`, `setVec2/3/4`, `setFloat`, `setInt`, `setMat4`,
//! `setProjection`, `drawArrays`, `drawArraysInstanced`, `deinit`, the public
//! `compileShader`, and `init`). D-prep STUB: bodies `@panic("metal: TODO D1")`.
//!
//! Note: callers pass MSL sources (from `gpu/metal/shaders.zig`) to `init`. A
//! real backend will build an `MTLRenderPipelineState` here; `program`/`vao`
//! become indices/handles into Metal pipeline + vertex-descriptor pools. The
//! `program != 0` "link succeeded" convention the callers guard on is preserved.
const c = @import("c.zig");
const Pipeline = @This();

program: c.GLuint,
vao: c.GLuint,

/// Compile a shader stage. STUB returns null (mirrors the OpenGL failure path).
pub fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    _ = shader_type;
    _ = source;
    @panic("metal: TODO D1 — Pipeline.compileShader (compile MSL)");
}

/// Build a pipeline from vertex/fragment sources, paired with a caller-built
/// VAO handle. STUB.
pub fn init(vs_src: [*c]const u8, fs_src: [*c]const u8, vao: c.GLuint) Pipeline {
    _ = vs_src;
    _ = fs_src;
    _ = vao;
    @panic("metal: TODO D1 — Pipeline.init (build MTLRenderPipelineState)");
}

pub fn use(self: Pipeline) void {
    _ = self;
    @panic("metal: TODO D1 — Pipeline.use");
}
pub fn bindVao(self: Pipeline) void {
    _ = self;
    @panic("metal: TODO D1 — Pipeline.bindVao");
}
pub fn setVec2(self: Pipeline, name: [*c]const u8, x: f32, y: f32) void {
    _ = self;
    _ = name;
    _ = x;
    _ = y;
    @panic("metal: TODO D1 — Pipeline.setVec2");
}
pub fn setFloat(self: Pipeline, name: [*c]const u8, v: f32) void {
    _ = self;
    _ = name;
    _ = v;
    @panic("metal: TODO D1 — Pipeline.setFloat");
}
pub fn setInt(self: Pipeline, name: [*c]const u8, v: i32) void {
    _ = self;
    _ = name;
    _ = v;
    @panic("metal: TODO D1 — Pipeline.setInt");
}
pub fn setProjection(self: Pipeline) void {
    _ = self;
    @panic("metal: TODO D1 — Pipeline.setProjection");
}
pub fn setMat4(self: Pipeline, name: [*c]const u8, m: *const [16]f32) void {
    _ = self;
    _ = name;
    _ = m;
    @panic("metal: TODO D1 — Pipeline.setMat4");
}
pub fn setVec3(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32) void {
    _ = self;
    _ = name;
    _ = x;
    _ = y;
    _ = z;
    @panic("metal: TODO D1 — Pipeline.setVec3");
}
pub fn setVec4(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32, w: f32) void {
    _ = self;
    _ = name;
    _ = x;
    _ = y;
    _ = z;
    _ = w;
    @panic("metal: TODO D1 — Pipeline.setVec4");
}
pub fn drawArrays(self: Pipeline, mode: c.GLenum, first: c.GLint, count: c.GLsizei) void {
    _ = self;
    _ = mode;
    _ = first;
    _ = count;
    @panic("metal: TODO D1 — Pipeline.drawArrays");
}
pub fn drawArraysInstanced(self: Pipeline, mode: c.GLenum, first: c.GLint, count: c.GLsizei, instances: c.GLsizei) void {
    _ = self;
    _ = mode;
    _ = first;
    _ = count;
    _ = instances;
    @panic("metal: TODO D1 — Pipeline.drawArraysInstanced");
}
pub fn deinit(self: *Pipeline) void {
    self.* = .{ .program = 0, .vao = 0 };
}
