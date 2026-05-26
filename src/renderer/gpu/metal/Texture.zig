//! Metal backend 2D texture. Mirrors `gpu/opengl/Texture.zig`'s public surface
//! (field `handle`, the `Filter`/`Wrap`/`Upload` types, and every method the
//! callers use). D-prep STUB: bodies are `@panic("metal: TODO D1")`. A real
//! backend will back `handle` with an `MTLTexture`.
const c = @import("c.zig");
const Texture = @This();

handle: c.GLuint,

pub fn fromHandle(h: c.GLuint) Texture {
    return .{ .handle = h };
}
pub fn bind(self: Texture, unit: u32) void {
    _ = self;
    _ = unit;
    @panic("metal: TODO D1 — Texture.bind");
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
    @panic("metal: TODO D1 — Texture.create (allocate MTLTexture)");
}

/// Bind + upload (or allocate, if `data` is null) a 2D image.
pub fn upload2D(self: Texture, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = self;
    _ = width;
    _ = height;
    _ = data;
    _ = o;
    @panic("metal: TODO D1 — Texture.upload2D");
}

/// Update only the wrap_s/wrap_t parameters.
pub fn setWrap(self: Texture, wrap: Wrap) void {
    _ = self;
    _ = wrap;
    @panic("metal: TODO D1 — Texture.setWrap");
}

/// Update a sub-region of an already-allocated texture.
pub fn subImage2D(self: Texture, x: c_int, y: c_int, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = self;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    _ = data;
    _ = o;
    @panic("metal: TODO D1 — Texture.subImage2D");
}

/// Read back the width of mip level 0.
pub fn levelWidth(self: Texture) c_int {
    _ = self;
    @panic("metal: TODO D1 — Texture.levelWidth");
}

/// Delete the texture and zero the handle.
pub fn destroy(self: *Texture) void {
    self.handle = 0;
}
