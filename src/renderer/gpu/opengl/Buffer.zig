//! A GPU buffer (OpenGL VBO). Backend primitive for the GraphicsAPI spine.
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const types = @import("../types.zig");
const Buffer = @This();

handle: c.GLuint = 0,
target: c.GLenum,

fn initTarget(target: c.GLenum) Buffer {
    var b = Buffer{ .target = target };
    Context.gl.GenBuffers.?(1, &b.handle);
    return b;
}

pub fn initVertex() Buffer {
    return initTarget(c.GL_ARRAY_BUFFER);
}

fn usageEnum(usage: types.BufferUsage) c.GLenum {
    return switch (usage) {
        .static => c.GL_STATIC_DRAW,
        .dynamic => c.GL_DYNAMIC_DRAW,
        .stream => c.GL_STREAM_DRAW,
    };
}

pub fn bind(self: Buffer) void {
    Context.gl.BindBuffer.?(self.target, self.handle);
}
/// Allocate `size` bytes of uninitialized storage with the given usage hint.
pub fn allocate(self: Buffer, size: usize, usage: types.BufferUsage) void {
    self.bind();
    Context.gl.BufferData.?(self.target, @intCast(size), null, usageEnum(usage));
}
/// Allocate + fill with `bytes`.
pub fn uploadData(self: Buffer, bytes: []const u8, usage: types.BufferUsage) void {
    self.bind();
    Context.gl.BufferData.?(self.target, @intCast(bytes.len), bytes.ptr, usageEnum(usage));
}
/// Overwrite from offset 0 (glBufferSubData).
pub fn upload(self: Buffer, bytes: []const u8) void {
    self.bind();
    Context.gl.BufferSubData.?(self.target, 0, @intCast(bytes.len), bytes.ptr);
}
pub fn deinit(self: *Buffer) void {
    if (self.handle != 0) {
        Context.gl.DeleteBuffers.?(1, &self.handle);
        self.handle = 0;
    }
}
