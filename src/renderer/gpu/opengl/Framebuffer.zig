//! An off-screen framebuffer with a single RGBA8 color-texture attachment.
//! Wraps the GenFramebuffers + color-texture + completeness-check sequence used
//! by the per-surface FBO compositor and the post-processing pass.
const std = @import("std");
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const Texture = @import("Texture.zig");
const render_state = @import("render_state.zig");
const Framebuffer = @This();

handle: c.GLuint = 0,
color: c.GLuint = 0,
width: c_int = 0,
height: c_int = 0,

/// Create an FBO with a fresh RGBA8 LINEAR/CLAMP_TO_EDGE color texture attached.
/// Returns null (after cleaning up) if the framebuffer is incomplete.
pub fn initColor(width: c_int, height: c_int) ?Framebuffer {
    const gl = Context.gl;
    var handle: c.GLuint = 0;
    gl.GenFramebuffers.?(1, &handle);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, handle);

    const color = Texture.create();
    color.upload2D(width, height, null, .{}); // RGBA8, LINEAR, CLAMP_TO_EDGE
    gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, color.handle, 0);

    const status = gl.CheckFramebufferStatus.?(c.GL_FRAMEBUFFER);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, 0);

    if (status != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("Framebuffer incomplete: 0x{X}\n", .{status});
        var tex = color;
        tex.destroy();
        gl.DeleteFramebuffers.?(1, &handle);
        return null;
    }
    return .{ .handle = handle, .color = color.handle, .width = width, .height = height };
}

/// Bind this framebuffer and set the viewport to its full size. Pending
/// batched UI draws are flushed first (via the state hook) so they land in
/// the render target they were issued against.
pub fn bind(self: Framebuffer) void {
    if (render_state.pre_change_hook) |hook| hook();
    const gl = Context.gl;
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, self.handle);
    gl.Viewport.?(0, 0, self.width, self.height);
}

/// Bind the default (window) framebuffer.
pub fn unbind() void {
    if (render_state.pre_change_hook) |hook| hook();
    Context.gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
}

/// Delete the framebuffer and its color texture; zero the struct.
pub fn deinit(self: *Framebuffer) void {
    const gl = Context.gl;
    if (self.color != 0) gl.DeleteTextures.?(1, &self.color);
    if (self.handle != 0) gl.DeleteFramebuffers.?(1, &self.handle);
    self.* = .{};
}
