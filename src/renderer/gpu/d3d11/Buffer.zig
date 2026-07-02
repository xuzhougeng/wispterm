//! Compile-safe D3D11 buffer placeholder for Phase II.

const c = @import("c.zig");
const types = @import("../types.zig");
const Buffer = @This();

handle: c.GLuint = 0,
target: c.GLenum,
len: usize = 0,

threadlocal var next_handle: c.GLuint = 1;

fn allocHandle() c.GLuint {
    const h = next_handle;
    next_handle +%= 1;
    if (next_handle == 0) next_handle = 1;
    return h;
}

fn initTarget(target: c.GLenum) Buffer {
    return .{ .handle = allocHandle(), .target = target };
}

pub fn initVertex() Buffer {
    return initTarget(c.GL_ARRAY_BUFFER);
}

pub fn bind(self: Buffer) void {
    _ = self;
}

pub fn allocate(self: Buffer, size: usize, usage: types.BufferUsage) void {
    _ = self;
    _ = usage;
    _ = size;
}

pub fn uploadData(self: Buffer, bytes: []const u8, usage: types.BufferUsage) void {
    _ = self;
    _ = usage;
    _ = bytes;
}

pub fn upload(self: Buffer, bytes: []const u8) void {
    _ = self;
    _ = bytes;
}

pub fn byteLength(self: Buffer) usize {
    return self.len;
}

pub fn deinit(self: *Buffer) void {
    self.* = .{ .handle = 0, .target = self.target, .len = 0 };
}
