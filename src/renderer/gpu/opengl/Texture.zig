//! A 2D GPU texture. This increment wraps an existing handle for binding only;
//! ownership/upload of the font atlas is taken over in A4.
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const types = @import("../types.zig");
const Texture = @This();

handle: c.GLuint,

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
    const texture_unit: c.GLenum = @as(c.GLenum, c.GL_TEXTURE0) + unit;
    Context.gl.ActiveTexture.?(texture_unit);
    Context.gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
}

/// Options for a 2D texture data upload.
pub const Upload = struct {
    format: types.TextureFormat = .rgba8,
    sampler: types.SamplerMode = .linear_clamp,
    /// When non-null, sets the backend's unpack row alignment before upload.
    unpack_alignment: ?i32 = null,
};

const FormatEnums = struct {
    internal: c.GLenum,
    source: c.GLenum,
    data_type: c.GLenum = c.GL_UNSIGNED_BYTE,
};

fn formatEnums(format: types.TextureFormat) FormatEnums {
    return switch (format) {
        .r8 => .{ .internal = c.GL_RED, .source = c.GL_RED },
        .rgba8 => .{ .internal = c.GL_RGBA8, .source = c.GL_RGBA },
        .bgra8 => .{ .internal = c.GL_RGBA8, .source = c.GL_BGRA },
    };
}

fn filterEnum(sampler: types.SamplerMode) c.GLint {
    return switch (sampler) {
        .nearest_clamp => c.GL_NEAREST,
        .linear_clamp, .linear_repeat => c.GL_LINEAR,
    };
}

fn wrapEnum(sampler: types.SamplerMode) c.GLint {
    return switch (sampler) {
        .nearest_clamp, .linear_clamp => c.GL_CLAMP_TO_EDGE,
        .linear_repeat => c.GL_REPEAT,
    };
}

/// Allocate a new GL texture name.
pub fn create() Texture {
    var handle: c.GLuint = 0;
    Context.gl.GenTextures.?(1, &handle);
    return .{ .handle = handle };
}

/// Bind and upload (or allocate, if `data` is null) a 2D image, setting
/// min/mag filter and wrap_s/wrap_t. Mirrors the raw GenTextures+TexParameteri+
/// TexImage2D sequences being replaced.
pub fn upload2D(self: Texture, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    const gl = Context.gl;
    const format = formatEnums(o.format);
    gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, filterEnum(o.sampler));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, filterEnum(o.sampler));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, wrapEnum(o.sampler));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, wrapEnum(o.sampler));
    if (o.unpack_alignment) |a| gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, @intCast(a));
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, @intCast(format.internal), width, height, 0, format.source, format.data_type, data);
}

/// Update sampler parameters (binds the texture).
pub fn setSamplerMode(self: Texture, sampler: types.SamplerMode) void {
    const gl = Context.gl;
    gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, filterEnum(sampler));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, filterEnum(sampler));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, wrapEnum(sampler));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, wrapEnum(sampler));
}

/// Update a sub-region (glTexSubImage2D) of an already-allocated texture.
/// Uses o.format / o.unpack_alignment (the sampler field is ignored here).
pub fn subImage2D(self: Texture, x: c_int, y: c_int, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    const gl = Context.gl;
    const format = formatEnums(o.format);
    gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
    if (o.unpack_alignment) |a| gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, @intCast(a));
    gl.TexSubImage2D.?(c.GL_TEXTURE_2D, 0, x, y, width, height, format.source, format.data_type, data);
}

/// Read back the width of mip level 0 (glGetTexLevelParameteriv GL_TEXTURE_WIDTH).
pub fn levelWidth(self: Texture) c_int {
    const gl = Context.gl;
    gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
    var w: c.GLint = 0;
    gl.GetTexLevelParameteriv.?(c.GL_TEXTURE_2D, 0, c.GL_TEXTURE_WIDTH, &w);
    return w;
}

/// Delete the GL texture and zero the handle.
pub fn destroy(self: *Texture) void {
    if (self.handle != 0) {
        Context.gl.DeleteTextures.?(1, &self.handle);
        self.handle = 0;
    }
}
