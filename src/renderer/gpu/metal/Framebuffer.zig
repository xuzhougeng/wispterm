//! Metal backend off-screen framebuffer. Mirrors `gpu/opengl/Framebuffer.zig`'s
//! public surface: fields `handle`/`color`/`width`/`height` and methods
//! `initColor`/`bind`/`unbind`/`deinit`. Metal has no framebuffer object; the
//! handle is lightweight backend state and `color` is a real `MTLTexture`.
const c = @import("c.zig");
const render_state = @import("render_state.zig");
const Texture = @import("Texture.zig");
const Framebuffer = @This();

handle: c.GLuint = 0,
color: c.GLuint = 0,
width: c_int = 0,
height: c_int = 0,

threadlocal var next_handle: c.GLuint = 1;
threadlocal var bound_handle: c.GLuint = 0;

/// Create an off-screen color render target.
pub fn initColor(width: c_int, height: c_int) ?Framebuffer {
    if (width <= 0 or height <= 0) return null;

    var color = Texture.create();
    if (color.handle == 0) return null;
    color.upload2D(width, height, null, .{});
    if (color.levelWidth() != width) {
        color.destroy();
        return null;
    }

    const handle = next_handle;
    next_handle +%= 1;
    if (next_handle == 0) next_handle = 1;

    return .{ .handle = handle, .color = color.handle, .width = width, .height = height };
}

pub fn isValid(self: Framebuffer) bool {
    return self.handle != 0 and self.color != 0;
}

pub fn colorTexture(self: Framebuffer) Texture {
    return Texture.fromHandle(self.color);
}

/// Bind this framebuffer and set the viewport to its full size.
pub fn bind(self: Framebuffer) void {
    bound_handle = self.handle;
    render_state.setViewport(0, 0, self.width, self.height);
}

/// Bind the default (window) framebuffer.
pub fn unbind() void {
    bound_handle = 0;
}

/// Delete the framebuffer and its color texture; zero the struct.
pub fn deinit(self: *Framebuffer) void {
    if (self.color != 0) {
        var color = Texture.fromHandle(self.color);
        color.destroy();
    }
    self.* = .{};
}

pub fn boundHandle() c.GLuint {
    return bound_handle;
}
