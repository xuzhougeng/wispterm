//! Metal backend 2D texture. Mirrors `gpu/opengl/Texture.zig`'s public surface.
//! `handle` is a registry id for an Objective-C-retained `MTLTexture`.
const std = @import("std");

const Context = @import("Context.zig");
const c = @import("c.zig");
const Texture = @This();

handle: c.GLuint,

extern fn phantty_metal_texture_create() c.GLuint;
extern fn phantty_metal_texture_upload_2d(handle: c.GLuint, device: ?*anyopaque, width: c_int, height: c_int, data: ?*const anyopaque, format: c.GLenum, data_type: c.GLenum, wrap: c_uint, filter: c_uint, error_buf: [*]u8, error_buf_len: usize) bool;
extern fn phantty_metal_texture_sub_image_2d(handle: c.GLuint, x: c_int, y: c_int, width: c_int, height: c_int, data: ?*const anyopaque, format: c.GLenum, data_type: c.GLenum, error_buf: [*]u8, error_buf_len: usize) bool;
extern fn phantty_metal_texture_set_wrap(handle: c.GLuint, wrap: c_uint) void;
extern fn phantty_metal_texture_bind(handle: c.GLuint, unit: c_uint) void;
extern fn phantty_metal_texture_level_width(handle: c.GLuint) c_int;
extern fn phantty_metal_texture_destroy(handle: c.GLuint) void;

pub fn fromHandle(h: c.GLuint) Texture {
    return .{ .handle = h };
}
pub fn bind(self: Texture, unit: u32) void {
    phantty_metal_texture_bind(self.handle, @intCast(unit));
}

pub const Filter = enum { nearest, linear };
pub const Wrap = enum { clamp_to_edge, repeat };

/// Options for a 2D texture data upload. Same public fields as the OpenGL
/// backend's `Upload` so call sites (`.{ .format = ..., .filter = ... }`)
/// type-check unchanged.
pub const Upload = struct {
    internal_format: c.GLenum = c.GL_RGBA8,
    format: c.GLenum = c.GL_RGBA,
    data_type: c.GLenum = c.GL_UNSIGNED_BYTE,
    filter: Filter = .linear,
    wrap: Wrap = .clamp_to_edge,
    unpack_alignment: ?c.GLint = null,
};

/// Allocate a new texture.
pub fn create() Texture {
    return .{ .handle = phantty_metal_texture_create() };
}

/// Bind + upload (or allocate, if `data` is null) a 2D image.
pub fn upload2D(self: Texture, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = o.internal_format;
    _ = o.unpack_alignment;
    _ = runBool("Metal texture upload2D failed", phantty_metal_texture_upload_2d(
        self.handle,
        Context.deviceHandle(),
        width,
        height,
        data,
        o.format,
        o.data_type,
        wrapInt(o.wrap),
        filterInt(o.filter),
        &scratch_error,
        scratch_error.len,
    ));
}

/// Update only the wrap_s/wrap_t parameters.
pub fn setWrap(self: Texture, wrap: Wrap) void {
    phantty_metal_texture_set_wrap(self.handle, wrapInt(wrap));
}

/// Update a sub-region of an already-allocated texture.
pub fn subImage2D(self: Texture, x: c_int, y: c_int, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = o.internal_format;
    _ = o.filter;
    _ = o.wrap;
    _ = o.unpack_alignment;
    _ = runBool("Metal texture subImage2D failed", phantty_metal_texture_sub_image_2d(
        self.handle,
        x,
        y,
        width,
        height,
        data,
        o.format,
        o.data_type,
        &scratch_error,
        scratch_error.len,
    ));
}

/// Read back the width of mip level 0.
pub fn levelWidth(self: Texture) c_int {
    return phantty_metal_texture_level_width(self.handle);
}

/// Delete the texture and zero the handle.
pub fn destroy(self: *Texture) void {
    if (self.handle != 0) {
        phantty_metal_texture_destroy(self.handle);
        self.handle = 0;
    }
}

threadlocal var scratch_error: [256]u8 = @splat(0);

fn wrapInt(wrap: Wrap) c_uint {
    return switch (wrap) {
        .clamp_to_edge => 0,
        .repeat => 1,
    };
}

fn filterInt(filter: Filter) c_uint {
    return switch (filter) {
        .nearest => 0,
        .linear => 1,
    };
}

fn runBool(prefix: []const u8, ok: bool) bool {
    if (ok) return true;
    const end = std.mem.indexOfScalar(u8, &scratch_error, 0) orelse scratch_error.len;
    std.debug.print("{s}: {s}\n", .{ prefix, scratch_error[0..end] });
    return false;
}
