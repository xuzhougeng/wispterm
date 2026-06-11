//! GL render-state + frame seam over Context.gl. Backend-level helpers that
//! eliminate direct glTable() calls for common state mutations. The Metal
//! backend will mirror this file with its own command-buffer seam.
const Context = @import("Context.zig");
const c = @import("c.zig").c;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const Size = struct { w: i32, h: i32 };
pub const BlendMode = enum { alpha, premultiplied };
pub const ScissorState = struct { enabled: bool, box: Rect };

/// Called before any state mutation below takes effect. The UI glyph batcher
/// registers its flush here so deferred draws are submitted under the state
/// they were issued with (scissor/blend/viewport/target), preserving exact
/// immediate-mode ordering. Stays null when batching is disabled.
pub threadlocal var pre_change_hook: ?*const fn () void = null;

inline fn notifyPreChange() void {
    if (pre_change_hook) |hook| hook();
}

/// Frame seam (OpenGL: flushes pending batched UI draws before present; the
/// Metal backend will own a command buffer here).
pub fn beginFrame() void {}
pub fn endFrame() void {
    notifyPreChange();
}

pub fn setBlendEnabled(enabled: bool) void {
    notifyPreChange();
    if (enabled) Context.gl.Enable.?(c.GL_BLEND) else Context.gl.Disable.?(c.GL_BLEND);
}

/// .alpha = (SRC_ALPHA, ONE_MINUS_SRC_ALPHA); .premultiplied = (ONE, ONE_MINUS_SRC_ALPHA)
pub fn setBlendMode(mode: BlendMode) void {
    notifyPreChange();
    switch (mode) {
        .alpha => Context.gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA),
        .premultiplied => Context.gl.BlendFunc.?(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA),
    }
}

pub fn clear(r: f32, g: f32, b: f32, a: f32) void {
    notifyPreChange();
    Context.gl.ClearColor.?(r, g, b, a);
    Context.gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
}

/// Restrict which color channels subsequent draws/clears may write. Used to
/// force the backbuffer alpha opaque before present (DWM composites our custom
/// frame via that alpha) without disturbing the already-rendered RGB.
pub fn setColorMask(r: bool, g: bool, b: bool, a: bool) void {
    notifyPreChange();
    Context.gl.ColorMask.?(@intFromBool(r), @intFromBool(g), @intFromBool(b), @intFromBool(a));
}

pub fn setViewport(x: i32, y: i32, w: i32, h: i32) void {
    notifyPreChange();
    Context.gl.Viewport.?(@intCast(x), @intCast(y), @intCast(w), @intCast(h));
}

pub fn viewportSize() Size {
    var vp: [4]c.GLint = undefined;
    Context.gl.GetIntegerv.?(c.GL_VIEWPORT, &vp);
    return .{ .w = @intCast(vp[2]), .h = @intCast(vp[3]) };
}

pub fn setScissor(rect: Rect) void {
    notifyPreChange();
    Context.gl.Enable.?(c.GL_SCISSOR_TEST);
    Context.gl.Scissor.?(@intCast(rect.x), @intCast(rect.y), @intCast(rect.w), @intCast(rect.h));
}

pub fn disableScissor() void {
    notifyPreChange();
    Context.gl.Disable.?(c.GL_SCISSOR_TEST);
}

/// Save/restore helper (markdown_preview nests a scissor over an outer one).
pub fn scissorState() ScissorState {
    const enabled = Context.gl.IsEnabled.?(c.GL_SCISSOR_TEST) == c.GL_TRUE;
    var box: [4]c.GLint = undefined;
    Context.gl.GetIntegerv.?(c.GL_SCISSOR_BOX, &box);
    return .{
        .enabled = enabled,
        .box = .{
            .x = @intCast(box[0]),
            .y = @intCast(box[1]),
            .w = @intCast(box[2]),
            .h = @intCast(box[3]),
        },
    };
}

pub fn restoreScissor(s: ScissorState) void {
    if (s.enabled) {
        setScissor(s.box);
    } else {
        disableScissor();
    }
}
