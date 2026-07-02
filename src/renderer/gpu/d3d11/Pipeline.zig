//! Compile-safe D3D11 pipeline placeholder for Phase II feature renderers.

const c = @import("c.zig");
const types = @import("../types.zig");
const Context = @import("Context.zig");
const Pipeline = @This();

program: types.ProgramHandle,
vao: types.VertexArrayHandle,

pub threadlocal var pre_use_hook: ?*const fn (program: types.ProgramHandle) void = null;
threadlocal var next_program: types.ProgramHandle = 1;

fn allocProgram() types.ProgramHandle {
    const h = next_program;
    next_program +%= 1;
    if (next_program == 0) next_program = 1;
    return h;
}

pub fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    _ = shader_type;
    _ = source;
    return allocProgram();
}

pub fn init(vs_src: [*c]const u8, fs_src: [*c]const u8, vao: types.VertexArrayHandle) Pipeline {
    _ = vs_src;
    _ = fs_src;
    return .{ .program = allocProgram(), .vao = vao };
}

pub fn use(self: Pipeline) void {
    if (pre_use_hook) |hook| hook(self.program);
}

pub fn bindVao(self: Pipeline) void {
    _ = self;
}

pub fn setVec2(self: Pipeline, name: [*c]const u8, x: f32, y: f32) void {
    _ = self;
    _ = name;
    _ = x;
    _ = y;
}

pub fn setFloat(self: Pipeline, name: [*c]const u8, v: f32) void {
    _ = self;
    _ = name;
    _ = v;
}

pub fn setInt(self: Pipeline, name: [*c]const u8, v: i32) void {
    _ = self;
    _ = name;
    _ = v;
}

pub fn setProjection(self: Pipeline) void {
    _ = self;
}

pub fn setMat4(self: Pipeline, name: [*c]const u8, m: *const [16]f32) void {
    _ = self;
    _ = name;
    _ = m;
}

pub fn setVec3(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32) void {
    _ = self;
    _ = name;
    _ = x;
    _ = y;
    _ = z;
}

pub fn setVec4(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32, w: f32) void {
    _ = self;
    _ = name;
    _ = x;
    _ = y;
    _ = z;
    _ = w;
}

pub fn drawArrays(self: Pipeline, topology: types.PrimitiveTopology, first: c.GLint, count: c.GLsizei) void {
    _ = self;
    _ = topology;
    _ = first;
    _ = count;
}

pub fn drawArraysInstanced(self: Pipeline, topology: types.PrimitiveTopology, first: c.GLint, count: c.GLsizei, instances: c.GLsizei) void {
    _ = self;
    _ = topology;
    _ = first;
    _ = count;
    _ = instances;
}

pub fn drawPhase2Quad() void {
    Context.drawPhase2Quad();
}

pub fn deinit(self: *Pipeline) void {
    self.* = .{ .program = 0, .vao = 0 };
}
