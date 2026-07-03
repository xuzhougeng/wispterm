//! GL render-state + frame seam over Context.gl. Backend-level helpers that
//! eliminate direct glTable() calls for common state mutations. The Metal
//! backend will mirror this file with its own command-buffer seam.
const std = @import("std");
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const types = @import("../types.zig");

pub const Rect = types.Scissor;
pub const Viewport = types.Viewport;
pub const Scissor = types.Scissor;
pub const ClearColor = types.ClearColor;
pub const DriverInfo = types.DriverInfo;
pub const BlendFactor = types.BlendFactor;
pub const SwapDiagnostics = types.SwapDiagnostics;
pub const Size = struct { w: i32, h: i32 };
pub const BlendMode = types.BlendMode;
pub const ScissorState = struct { enabled: bool, box: Scissor };

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

/// No-op: the OpenGL `readback.readRgba` reads the live back buffer with
/// `glReadPixels` directly (the buffer is still intact between endFrame and
/// swapBuffers). Only the Metal backend needs an armed in-frame capture.
pub fn armUiScreenshotCapture() void {}

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

fn glString(name: c.GLenum) []const u8 {
    const get_string = Context.gl.GetString orelse return "(unavailable)";
    const ptr = get_string(name);
    if (ptr == null) return "(null)";
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

pub fn driverInfo() DriverInfo {
    return .{
        .vendor = glString(c.GL_VENDOR),
        .renderer = glString(c.GL_RENDERER),
        .version = glString(c.GL_VERSION),
        .shading_language = glString(c.GL_SHADING_LANGUAGE_VERSION),
    };
}

/// GPU adapter identity for the benchmark report. OpenGL has no portable PCI-id
/// query, so vendor/device stay 0 and the name is the GL renderer string (GL-
/// owned pointer, valid while the context is current). Returns null when the GL
/// table isn't loaded yet.
pub fn adapterReport() ?types.AdapterReport {
    const renderer = glString(c.GL_RENDERER);
    if (renderer.len == 0) return null;
    return .{ .name = renderer, .vendor_id = 0, .device_id = 0 };
}

pub fn swapDiagnostics() ?SwapDiagnostics {
    const get_integerv = Context.gl.GetIntegerv orelse return null;
    const is_enabled = Context.gl.IsEnabled orelse return null;

    var vp: [4]c.GLint = undefined;
    get_integerv(c.GL_VIEWPORT, &vp);

    var blend: [4]c.GLint = undefined;
    get_integerv(c.GL_BLEND_SRC_RGB, &blend[0]);
    get_integerv(c.GL_BLEND_DST_RGB, &blend[1]);
    get_integerv(c.GL_BLEND_SRC_ALPHA, &blend[2]);
    get_integerv(c.GL_BLEND_DST_ALPHA, &blend[3]);

    return .{
        .viewport = .{ .x = @intCast(vp[0]), .y = @intCast(vp[1]), .w = @intCast(vp[2]), .h = @intCast(vp[3]) },
        .blend = .{
            .enabled = is_enabled(c.GL_BLEND) != 0,
            .src_rgb = blendFactorFromBackend(blend[0]),
            .dst_rgb = blendFactorFromBackend(blend[1]),
            .src_alpha = blendFactorFromBackend(blend[2]),
            .dst_alpha = blendFactorFromBackend(blend[3]),
        },
    };
}

fn blendFactorFromBackend(value: c.GLint) BlendFactor {
    const factor: c.GLenum = @intCast(value);
    return switch (factor) {
        c.GL_ZERO => .zero,
        c.GL_ONE => .one,
        c.GL_SRC_ALPHA => .src_alpha,
        c.GL_ONE_MINUS_SRC_ALPHA => .one_minus_src_alpha,
        else => .unknown,
    };
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
