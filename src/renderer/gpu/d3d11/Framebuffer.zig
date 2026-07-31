//! D3D11 off-screen framebuffer.
//!
//! Mirrors the OpenGL/Metal public surface while owning a real Direct3D render
//! target: an `ID3D11Texture2D` with both RTV and SRV views. The RTV is bound
//! for drawing; the texture handle is returned for later sampling/compositing.

const std = @import("std");

const Context = @import("Context.zig");
const c = @import("c.zig");
const core = @import("../../../platform/dxgi_core.zig");
const Texture = @import("Texture.zig");
const render_state = @import("render_state.zig");
const Framebuffer = @This();

handle: c.GLuint = 0,
color: c.GLuint = 0,
width: c_int = 0,
height: c_int = 0,
rtv: ?*anyopaque = null,

threadlocal var next_handle: c.GLuint = 1;

fn allocHandle() c.GLuint {
    const h = next_handle;
    next_handle +%= 1;
    if (next_handle == 0) next_handle = 1000;
    return h;
}

pub fn initColor(width: c_int, height: c_int) ?Framebuffer {
    if (width <= 0 or height <= 0) return null;

    var color = Texture.createRenderTarget(width, height, .rgba8, .linear_clamp) orelse return null;

    const device = Context.deviceHandle() orelse {
        color.destroy();
        return null;
    };
    const native_texture = Texture.nativeTexture(color.handle) orelse {
        color.destroy();
        return null;
    };
    const create_rtv = core.comCall(device, core.slot.D3D11Device_CreateRenderTargetView, *const fn (
        *anyopaque,
        *anyopaque,
        ?*const anyopaque,
        *?*anyopaque,
    ) callconv(.winapi) core.HRESULT);
    var rtv: ?*anyopaque = null;
    if (create_rtv(device, native_texture, null, &rtv) < 0 or rtv == null) {
        std.debug.print("D3D11 framebuffer RTV creation failed ({}x{})\n", .{ width, height });
        color.destroy();
        return null;
    }

    return .{
        .handle = allocHandle(),
        .color = color.handle,
        .width = width,
        .height = height,
        .rtv = rtv,
    };
}

pub fn isValid(self: Framebuffer) bool {
    return self.handle != 0 and self.color != 0 and self.rtv != null and Texture.fromHandle(self.color).isValid();
}

pub fn colorTexture(self: Framebuffer) Texture {
    return Texture.fromHandle(self.color);
}

pub fn bind(self: Framebuffer) void {
    if (!self.isValid()) return;
    if (render_state.pre_change_hook) |hook| hook();
    Texture.unbindShaderResourceSlots(0, 16);
    Context.bindRenderTargetView(self.rtv, self.width, self.height);
    render_state.setRenderTargetSize(self.width, self.height);
    render_state.setViewport(0, 0, self.width, self.height);
}

pub fn unbind() void {
    if (render_state.pre_change_hook) |hook| hook();
    Context.bindBackbufferRenderTarget();
    if (Context.currentRenderTargetSize()) |size| {
        render_state.setRenderTargetSize(size.width, size.height);
    }
}

pub fn deinit(self: *Framebuffer) void {
    if (self.rtv) |rtv| core.comRelease(rtv);
    if (self.color != 0) {
        var color = Texture.fromHandle(self.color);
        color.destroy();
    }
    self.* = .{};
}
