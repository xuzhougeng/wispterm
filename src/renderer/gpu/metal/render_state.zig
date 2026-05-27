//! Metal backend render-state + frame seam. Mirrors
//! `gpu/opengl/render_state.zig`; the state recorded here feeds the real Metal
//! render command encoder as D1 grows.
const std = @import("std");

const Context = @import("Context.zig");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const Size = struct { w: i32, h: i32 };
pub const BlendMode = enum { alpha, premultiplied };
pub const ScissorState = struct { enabled: bool, box: Rect };

threadlocal var frame_active = false;
threadlocal var blend_enabled = false;
threadlocal var blend_mode: BlendMode = .alpha;
threadlocal var viewport: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
threadlocal var scissor: ScissorState = .{
    .enabled = false,
    .box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};
threadlocal var clear_color: [4]f32 = .{ 0, 0, 0, 0 };
threadlocal var scratch_error: [256]u8 = @splat(0);

extern fn phantty_metal_frame_begin(ctx: *Context.Handles, r: f32, g: f32, b: f32, a: f32, error_buf: [*]u8, error_buf_len: usize) bool;
extern fn phantty_metal_frame_end(ctx: *Context.Handles, error_buf: [*]u8, error_buf_len: usize) bool;

/// Frame seam — the Metal backend owns the command buffer / drawable here.
pub fn beginFrame() void {
    if (frame_active) return;
    if (!Context.isInitialized()) return;
    if (!phantty_metal_frame_begin(
        &Context.handles,
        clear_color[0],
        clear_color[1],
        clear_color[2],
        clear_color[3],
        &scratch_error,
        scratch_error.len,
    )) {
        const end = std.mem.indexOfScalar(u8, &scratch_error, 0) orelse scratch_error.len;
        std.debug.print("Metal frame begin failed: {s}\n", .{scratch_error[0..end]});
        return;
    }
    frame_active = true;
}
pub fn endFrame() void {
    if (!frame_active) return;
    if (!phantty_metal_frame_end(&Context.handles, &scratch_error, scratch_error.len)) {
        const end = std.mem.indexOfScalar(u8, &scratch_error, 0) orelse scratch_error.len;
        std.debug.print("Metal frame end failed: {s}\n", .{scratch_error[0..end]});
    }
    frame_active = false;
}

pub fn setBlendEnabled(enabled: bool) void {
    blend_enabled = enabled;
}

pub fn setBlendMode(mode: BlendMode) void {
    blend_mode = mode;
}

pub fn clear(r: f32, g: f32, b: f32, a: f32) void {
    clear_color = .{ r, g, b, a };
    beginFrame();
}

pub fn setViewport(x: i32, y: i32, w: i32, h: i32) void {
    viewport = .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn viewportSize() Size {
    return .{ .w = viewport.w, .h = viewport.h };
}

pub fn setScissor(rect: Rect) void {
    scissor = .{ .enabled = true, .box = rect };
}

pub fn disableScissor() void {
    scissor.enabled = false;
}

pub fn scissorState() ScissorState {
    return scissor;
}

pub fn restoreScissor(s: ScissorState) void {
    scissor = s;
}

pub fn isFrameActive() bool {
    return frame_active;
}

pub fn isBlendEnabled() bool {
    return blend_enabled;
}

pub fn currentBlendMode() BlendMode {
    return blend_mode;
}

pub fn currentClearColor() [4]f32 {
    return clear_color;
}
