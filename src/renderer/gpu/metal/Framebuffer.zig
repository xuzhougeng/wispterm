//! Metal backend off-screen framebuffer. Mirrors `gpu/opengl/Framebuffer.zig`'s
//! public surface: fields `handle`/`color`/`width`/`height` and methods
//! `initColor`/`bind`/`unbind`/`deinit`. D-prep STUB: GPU bodies
//! `@panic("metal: TODO D1")`. A real backend backs this with an off-screen
//! `MTLTexture` render target + a render pass descriptor.
const c = @import("c.zig");
const Framebuffer = @This();

handle: c.GLuint = 0,
color: c.GLuint = 0,
width: c_int = 0,
height: c_int = 0,

/// Create an off-screen color render target. STUB.
pub fn initColor(width: c_int, height: c_int) ?Framebuffer {
    _ = width;
    _ = height;
    @panic("metal: TODO D1 — Framebuffer.initColor (off-screen MTLTexture target)");
}

/// Bind this framebuffer and set the viewport to its full size.
pub fn bind(self: Framebuffer) void {
    _ = self;
    @panic("metal: TODO D1 — Framebuffer.bind");
}

/// Bind the default (window) framebuffer.
pub fn unbind() void {
    @panic("metal: TODO D1 — Framebuffer.unbind");
}

/// Delete the framebuffer and its color texture; zero the struct.
pub fn deinit(self: *Framebuffer) void {
    self.* = .{};
}
