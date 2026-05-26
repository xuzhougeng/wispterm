//! FBO (Framebuffer Object) management for per-surface rendering.
//!
//! Creates, resizes, and draws FBOs that allow each split surface to be
//! rendered independently and then composited onto the main framebuffer.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const gpu = AppWindow.gpu;
const ui_pipeline = @import("ui_pipeline.zig");
const Renderer = @import("Renderer.zig");

/// Create or resize an FBO for a renderer.
/// Must be called from main thread with GL context current.
pub fn ensureRendererFBO(rend: *Renderer, width: u32, height: u32) void {
    if (!rend.needsFBOUpdate(width, height)) return;

    // Clean up existing FBO if resizing
    if (rend.isFBOReady()) {
        cleanupRendererFBO(rend);
    }

    const framebuffer = gpu.Framebuffer.initColor(@intCast(width), @intCast(height)) orelse return;
    rend.setFBOHandles(framebuffer.handle, framebuffer.color, width, height);
}

/// Clean up FBO resources for a renderer.
pub fn cleanupRendererFBO(rend: *Renderer) void {
    if (!rend.isFBOReady()) return;
    var framebuffer = gpu.Framebuffer{
        .handle = rend.getFBO(),
        .color = rend.getTexture(),
        .width = 0,
        .height = 0,
    };
    framebuffer.deinit();
    rend.clearFBOHandles();
}

/// Bind a renderer's FBO for drawing.
pub fn bindRendererFBO(rend: *Renderer) void {
    if (!rend.isFBOReady()) return;
    const size = rend.getFBOSize();
    const framebuffer = gpu.Framebuffer{
        .handle = rend.getFBO(),
        .color = rend.getTexture(),
        .width = @intCast(size.width),
        .height = @intCast(size.height),
    };
    framebuffer.bind();
}

/// Unbind FBO (return to default framebuffer).
pub fn unbindFBO() void {
    gpu.Framebuffer.unbind();
}

/// Draw a renderer's FBO texture as a quad at the given screen position.
/// This composites the surface onto the main framebuffer.
pub fn drawRendererFBOToScreen(rend: *Renderer, x: f32, y: f32, w: f32, h: f32, window_height: f32, window_width: f32) void {
    if (!rend.isFBOReady()) return;

    _ = window_width;

    // Convert from top-left screen coords to OpenGL bottom-left coords
    // NOTE: window_width is unused; drawTextureQuad derives the ortho projection
    // from the current viewport, which equals the window dimensions when
    // compositing to the default framebuffer.
    const gl_y = window_height - y - h;

    // Vertices for textured quad (position + texcoord)
    const vertices = [6][4]f32{
        .{ x, gl_y + h, 0.0, 1.0 }, // top-left
        .{ x, gl_y, 0.0, 0.0 }, // bottom-left
        .{ x + w, gl_y, 1.0, 0.0 }, // bottom-right
        .{ x, gl_y + h, 0.0, 1.0 }, // top-left
        .{ x + w, gl_y, 1.0, 0.0 }, // bottom-right
        .{ x + w, gl_y + h, 1.0, 1.0 }, // top-right
    };

    ui_pipeline.drawTextureQuad(vertices, rend.getTexture(), 1.0);
}
