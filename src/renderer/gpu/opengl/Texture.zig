//! A 2D GPU texture. This increment wraps an existing handle for binding only;
//! ownership/upload of the font atlas is taken over in A4.
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const Texture = @This();

handle: c.GLuint,

pub fn fromHandle(h: c.GLuint) Texture {
    return .{ .handle = h };
}
pub fn bind(self: Texture, unit: u32) void {
    const texture_unit: c.GLenum = @as(c.GLenum, c.GL_TEXTURE0) + unit;
    Context.gl.ActiveTexture.?(texture_unit);
    Context.gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
}

pub const Filter = enum { nearest, linear };
pub const Wrap = enum { clamp_to_edge, repeat };

/// Options for a 2D texture data upload.
pub const Upload = struct {
    /// Uses GLenum (unsigned int) to match GL_RGBA8 etc.; cast to GLint at TexImage2D call.
    internal_format: c.GLenum = c.GL_RGBA8,
    format: c.GLenum = c.GL_RGBA,
    data_type: c.GLenum = c.GL_UNSIGNED_BYTE,
    filter: Filter = .linear,
    wrap: Wrap = .clamp_to_edge,
    /// When non-null, calls glPixelStorei(GL_UNPACK_ALIGNMENT, v) before upload.
    unpack_alignment: ?c.GLint = null,
};

fn filterEnum(f: Filter) c.GLint {
    return switch (f) {
        .nearest => c.GL_NEAREST,
        .linear => c.GL_LINEAR,
    };
}
fn wrapEnum(w: Wrap) c.GLint {
    return switch (w) {
        .clamp_to_edge => c.GL_CLAMP_TO_EDGE,
        .repeat => c.GL_REPEAT,
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
    gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, filterEnum(o.filter));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, filterEnum(o.filter));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, wrapEnum(o.wrap));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, wrapEnum(o.wrap));
    if (o.unpack_alignment) |a| gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, a);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, @intCast(o.internal_format), width, height, 0, o.format, o.data_type, data);
}

/// Update only the wrap_s/wrap_t parameters (binds the texture).
pub fn setWrap(self: Texture, wrap: Wrap) void {
    const gl = Context.gl;
    gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, wrapEnum(wrap));
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, wrapEnum(wrap));
}

/// Delete the GL texture and zero the handle.
pub fn destroy(self: *Texture) void {
    if (self.handle != 0) {
        Context.gl.DeleteTextures.?(1, &self.handle);
        self.handle = 0;
    }
}
