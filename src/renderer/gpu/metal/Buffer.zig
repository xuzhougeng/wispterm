//! Metal backend GPU buffer. Mirrors `gpu/opengl/Buffer.zig`'s public surface.
//! `handle` is a registry id for an Objective-C-retained `MTLBuffer`.
const std = @import("std");

const Context = @import("Context.zig");
const c = @import("c.zig");
const types = @import("../types.zig");
const Buffer = @This();

handle: c.GLuint = 0,
target: c.GLenum,

extern fn wispterm_metal_buffer_create(target: c.GLenum) c.GLuint;
extern fn wispterm_metal_buffer_allocate(handle: c.GLuint, device: ?*anyopaque, len: usize, error_buf: [*]u8, error_buf_len: usize) bool;
extern fn wispterm_metal_buffer_upload_data(handle: c.GLuint, device: ?*anyopaque, bytes: ?*const anyopaque, len: usize, error_buf: [*]u8, error_buf_len: usize) bool;
extern fn wispterm_metal_buffer_upload(handle: c.GLuint, device: ?*anyopaque, bytes: ?*const anyopaque, len: usize, error_buf: [*]u8, error_buf_len: usize) bool;
extern fn wispterm_metal_buffer_length(handle: c.GLuint) usize;
extern fn wispterm_metal_buffer_destroy(handle: c.GLuint) void;

fn initTarget(target: c.GLenum) Buffer {
    return .{ .handle = wispterm_metal_buffer_create(target), .target = target };
}

pub fn initVertex() Buffer {
    return initTarget(c.GL_ARRAY_BUFFER);
}

pub fn bind(self: Buffer) void {
    _ = self;
    // Metal binds buffers on the render command encoder, not globally.
}
/// Allocate `size` bytes of uninitialized storage with the given usage hint.
pub fn allocate(self: Buffer, size: usize, usage: types.BufferUsage) void {
    _ = usage;
    _ = runBool("Metal buffer allocate failed", wispterm_metal_buffer_allocate(self.handle, Context.deviceHandle(), size, &scratch_error, scratch_error.len));
}
/// Allocate + fill with `bytes`.
pub fn uploadData(self: Buffer, bytes: []const u8, usage: types.BufferUsage) void {
    _ = usage;
    _ = runBool("Metal buffer uploadData failed", wispterm_metal_buffer_upload_data(self.handle, Context.deviceHandle(), bytes.ptr, bytes.len, &scratch_error, scratch_error.len));
}
/// Overwrite from offset 0.
pub fn upload(self: Buffer, bytes: []const u8) void {
    _ = runBool("Metal buffer upload failed", wispterm_metal_buffer_upload(self.handle, Context.deviceHandle(), bytes.ptr, bytes.len, &scratch_error, scratch_error.len));
}
pub fn byteLength(self: Buffer) usize {
    return wispterm_metal_buffer_length(self.handle);
}
pub fn deinit(self: *Buffer) void {
    if (self.handle != 0) {
        wispterm_metal_buffer_destroy(self.handle);
        self.handle = 0;
    }
}

threadlocal var scratch_error: [256]u8 = @splat(0);

fn runBool(prefix: []const u8, ok: bool) bool {
    if (ok) return true;
    const end = std.mem.indexOfScalar(u8, &scratch_error, 0) orelse scratch_error.len;
    std.debug.print("{s}: {s}\n", .{ prefix, scratch_error[0..end] });
    return false;
}
