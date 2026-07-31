//! Metal backend 2D texture. Mirrors `gpu/opengl/Texture.zig`'s public surface.
//! `handle` is a registry id for an Objective-C-retained `MTLTexture`.
const std = @import("std");

const Context = @import("Context.zig");
const c = @import("c.zig");
const types = @import("../types.zig");
const Texture = @This();

handle: c.GLuint,

extern fn wispterm_metal_texture_create() c.GLuint;
extern fn wispterm_metal_texture_upload_2d(handle: c.GLuint, device: ?*anyopaque, width: c_int, height: c_int, data: ?*const anyopaque, format: c.GLenum, data_type: c.GLenum, wrap: c_uint, filter: c_uint, error_buf: [*]u8, error_buf_len: usize) bool;
extern fn wispterm_metal_texture_sub_image_2d(handle: c.GLuint, x: c_int, y: c_int, width: c_int, height: c_int, data: ?*const anyopaque, format: c.GLenum, data_type: c.GLenum, error_buf: [*]u8, error_buf_len: usize) bool;
extern fn wispterm_metal_texture_set_sampler(handle: c.GLuint, wrap: c_uint, filter: c_uint) void;
extern fn wispterm_metal_texture_bind(handle: c.GLuint, unit: c_uint) void;
extern fn wispterm_metal_texture_level_width(handle: c.GLuint) c_int;
extern fn wispterm_metal_texture_destroy(handle: c.GLuint) void;

pub fn invalid() Texture {
    return .{ .handle = 0 };
}

pub fn isValid(self: Texture) bool {
    return self.handle != 0;
}

pub fn fromHandle(h: c.GLuint) Texture {
    return .{ .handle = h };
}
pub fn bind(self: Texture, unit: u32) void {
    wispterm_metal_texture_bind(self.handle, @intCast(unit));
}

/// Options for a 2D texture data upload. Same public fields as the OpenGL
/// backend's `Upload` so call sites type-check unchanged.
pub const Upload = struct {
    format: types.TextureFormat = .rgba8,
    sampler: types.SamplerMode = .linear_clamp,
    unpack_alignment: ?i32 = null,
};

/// Allocate a new texture.
pub fn create() Texture {
    return .{ .handle = wispterm_metal_texture_create() };
}

/// Bind + upload (or allocate, if `data` is null) a 2D image.
pub fn upload2D(self: Texture, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = o.unpack_alignment;
    _ = runBool("Metal texture upload2D failed", wispterm_metal_texture_upload_2d(
        self.handle,
        Context.deviceHandle(),
        width,
        height,
        data,
        formatEnum(o.format),
        c.GL_UNSIGNED_BYTE,
        wrapInt(o.sampler),
        filterInt(o.sampler),
        &scratch_error,
        scratch_error.len,
    ));
}

/// Update sampler parameters.
pub fn setSamplerMode(self: Texture, sampler: types.SamplerMode) void {
    wispterm_metal_texture_set_sampler(self.handle, wrapInt(sampler), filterInt(sampler));
}

/// Update a sub-region of an already-allocated texture.
pub fn subImage2D(self: Texture, x: c_int, y: c_int, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = o.sampler;
    _ = o.unpack_alignment;
    _ = runBool("Metal texture subImage2D failed", wispterm_metal_texture_sub_image_2d(
        self.handle,
        x,
        y,
        width,
        height,
        data,
        formatEnum(o.format),
        c.GL_UNSIGNED_BYTE,
        &scratch_error,
        scratch_error.len,
    ));
}

/// Read back the width of mip level 0.
pub fn levelWidth(self: Texture) c_int {
    return wispterm_metal_texture_level_width(self.handle);
}

/// Delete the texture and zero the handle.
pub fn destroy(self: *Texture) void {
    if (self.handle != 0) {
        wispterm_metal_texture_destroy(self.handle);
        self.handle = 0;
    }
}

threadlocal var scratch_error: [256]u8 = @splat(0);

fn formatEnum(format: types.TextureFormat) c.GLenum {
    return switch (format) {
        .r8 => c.GL_RED,
        .rgba8 => c.GL_RGBA,
        .bgra8 => c.GL_BGRA,
    };
}

fn wrapInt(sampler: types.SamplerMode) c_uint {
    return switch (sampler) {
        .nearest_clamp, .linear_clamp => 0,
        .linear_repeat => 1,
    };
}

fn filterInt(sampler: types.SamplerMode) c_uint {
    return switch (sampler) {
        .nearest_clamp => 0,
        .linear_clamp, .linear_repeat => 1,
    };
}

fn runBool(prefix: []const u8, ok: bool) bool {
    if (ok) return true;
    const end = std.mem.indexOfScalar(u8, &scratch_error, 0) orelse scratch_error.len;
    std.debug.print("{s}: {s}\n", .{ prefix, scratch_error[0..end] });
    return false;
}
