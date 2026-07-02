//! Phase II D3D11 framebuffer placeholder.

const c = @import("c.zig");
const Texture = @import("Texture.zig");
const render_state = @import("render_state.zig");
const Framebuffer = @This();

handle: c.GLuint = 0,
color: c.GLuint = 0,
width: c_int = 0,
height: c_int = 0,

threadlocal var next_handle: c.GLuint = 1000;

fn allocHandle() c.GLuint {
    const h = next_handle;
    next_handle +%= 1;
    if (next_handle == 0) next_handle = 1000;
    return h;
}

pub fn initColor(width: c_int, height: c_int) ?Framebuffer {
    const color = Texture.create();
    if (!color.isValid()) return null;
    return .{ .handle = allocHandle(), .color = color.handle, .width = width, .height = height };
}

pub fn isValid(self: Framebuffer) bool {
    return self.handle != 0 and self.color != 0;
}

pub fn colorTexture(self: Framebuffer) Texture {
    return Texture.fromHandle(self.color);
}

pub fn bind(self: Framebuffer) void {
    render_state.setViewport(0, 0, self.width, self.height);
}

pub fn unbind() void {}

pub fn deinit(self: *Framebuffer) void {
    self.* = .{};
}
