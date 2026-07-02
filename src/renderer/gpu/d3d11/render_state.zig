//! D3D11 render-state seam for Phase II.

const Context = @import("Context.zig");
const types = @import("../types.zig");

pub const Rect = types.Scissor;
pub const Viewport = types.Viewport;
pub const Scissor = types.Scissor;
pub const ClearColor = types.ClearColor;
pub const DriverInfo = types.DriverInfo;
pub const SwapDiagnostics = types.SwapDiagnostics;
pub const Size = struct { w: i32, h: i32 };
pub const BlendMode = types.BlendMode;
pub const ScissorState = struct { enabled: bool, box: Scissor };

pub threadlocal var pre_change_hook: ?*const fn () void = null;
threadlocal var blend_enabled = false;
threadlocal var blend_mode: BlendMode = .alpha;
threadlocal var viewport: Viewport = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
threadlocal var scissor: ScissorState = .{
    .enabled = false,
    .box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

inline fn notifyPreChange() void {
    if (pre_change_hook) |hook| hook();
}

pub fn beginFrame() void {}

pub fn endFrame() void {
    notifyPreChange();
    Context.drawPhase2Quad();
}

pub fn armUiScreenshotCapture() void {}

pub fn setBlendEnabled(enabled: bool) void {
    blend_enabled = enabled;
}

pub fn setBlendMode(mode: BlendMode) void {
    blend_mode = mode;
}

pub fn clear(r: f32, g: f32, b: f32, a: f32) void {
    notifyPreChange();
    Context.clear(r, g, b, a);
}

pub fn setColorMask(r: bool, g: bool, b: bool, a: bool) void {
    _ = r;
    _ = g;
    _ = b;
    _ = a;
}

pub fn setViewport(x: i32, y: i32, w: i32, h: i32) void {
    viewport = .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn viewportSize() Size {
    return .{ .w = viewport.w, .h = viewport.h };
}

pub fn driverInfo() DriverInfo {
    return .{
        .vendor = "D3D11",
        .renderer = "Direct3D 11",
        .version = "experimental",
        .shading_language = "HLSL",
    };
}

pub fn swapDiagnostics() ?SwapDiagnostics {
    return .{
        .viewport = viewport,
        .blend = blendSnapshot(),
    };
}

fn blendSnapshot() types.BlendSnapshot {
    const BlendFactors = struct {
        src: types.BlendFactor,
        dst: types.BlendFactor,
    };
    const factors: BlendFactors = switch (blend_mode) {
        .alpha => .{ .src = types.BlendFactor.src_alpha, .dst = types.BlendFactor.one_minus_src_alpha },
        .premultiplied => .{ .src = types.BlendFactor.one, .dst = types.BlendFactor.one_minus_src_alpha },
    };
    return .{
        .enabled = blend_enabled,
        .src_rgb = factors.src,
        .dst_rgb = factors.dst,
        .src_alpha = factors.src,
        .dst_alpha = factors.dst,
    };
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
