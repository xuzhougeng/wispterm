//! D3D11 render-state seam.

const std = @import("std");

const Context = @import("Context.zig");
const core = @import("../../../platform/dxgi_core.zig");
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
threadlocal var alpha_blend_state: ?*anyopaque = null;
threadlocal var premultiplied_blend_state: ?*anyopaque = null;
threadlocal var disabled_blend_state: ?*anyopaque = null;
threadlocal var scissor_rasterizer_state: ?*anyopaque = null;

inline fn notifyPreChange() void {
    if (pre_change_hook) |hook| hook();
}

pub fn beginFrame() void {
    Context.beginFrame();
}

pub fn endFrame() void {
    notifyPreChange();
    if (!Context.featureDrawsThisFrame()) Context.drawPhase2Quad();
}

pub fn armUiScreenshotCapture() void {}

pub fn setBlendEnabled(enabled: bool) void {
    notifyPreChange();
    blend_enabled = enabled;
    applyBlendState();
}

pub fn setBlendMode(mode: BlendMode) void {
    notifyPreChange();
    blend_mode = mode;
    applyBlendState();
}

pub fn clear(r: f32, g: f32, b: f32, a: f32) void {
    notifyPreChange();
    Context.clear(r, g, b, a);
    applyViewport();
    applyScissor();
    applyBlendState();
}

pub fn setColorMask(r: bool, g: bool, b: bool, a: bool) void {
    _ = r;
    _ = g;
    _ = b;
    _ = a;
}

pub fn setViewport(x: i32, y: i32, w: i32, h: i32) void {
    notifyPreChange();
    viewport = .{ .x = x, .y = y, .w = w, .h = h };
    applyViewport();
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
    notifyPreChange();
    scissor = .{ .enabled = true, .box = rect };
    applyScissor();
}

pub fn disableScissor() void {
    notifyPreChange();
    scissor.enabled = false;
    applyScissor();
}

pub fn scissorState() ScissorState {
    return scissor;
}

pub fn restoreScissor(s: ScissorState) void {
    scissor = s;
    applyScissor();
}

fn framebufferHeight() i32 {
    return if (Context.swapchainSize()) |size| size.height else viewport.h;
}

fn topLeftY(y: i32, h: i32) i32 {
    return @max(0, framebufferHeight() - y - h);
}

fn applyViewport() void {
    const context = Context.contextHandle() orelse return;
    if (viewport.w <= 0 or viewport.h <= 0) return;
    const vp = core.D3D11_VIEWPORT{
        .top_left_x = @floatFromInt(viewport.x),
        .top_left_y = @floatFromInt(topLeftY(viewport.y, viewport.h)),
        .width = @floatFromInt(viewport.w),
        .height = @floatFromInt(viewport.h),
        .min_depth = 0,
        .max_depth = 1,
    };
    const rs_viewports = core.comCall(context, core.slot.D3D11DeviceContext_RSSetViewports, *const fn (*anyopaque, u32, *const core.D3D11_VIEWPORT) callconv(.winapi) void);
    rs_viewports(context, 1, &vp);
}

fn applyScissor() void {
    const context = Context.contextHandle() orelse return;
    applyRasterizerState();
    const rs_scissor = core.comCall(context, core.slot.D3D11DeviceContext_RSSetScissorRects, *const fn (*anyopaque, u32, ?*const core.D3D11_RECT) callconv(.winapi) void);
    if (!scissor.enabled or scissor.box.w <= 0 or scissor.box.h <= 0) {
        const maybe_size = Context.swapchainSize();
        const width = if (maybe_size) |s| s.width else @max(viewport.w, 1);
        const height = if (maybe_size) |s| s.height else @max(viewport.h, 1);
        const rect = core.D3D11_RECT{
            .left = 0,
            .top = 0,
            .right = @max(width, 1),
            .bottom = @max(height, 1),
        };
        rs_scissor(context, 1, &rect);
        return;
    }
    const y = topLeftY(scissor.box.y, scissor.box.h);
    const rect = core.D3D11_RECT{
        .left = scissor.box.x,
        .top = y,
        .right = scissor.box.x + scissor.box.w,
        .bottom = y + scissor.box.h,
    };
    rs_scissor(context, 1, &rect);
}

fn applyRasterizerState() void {
    const context = Context.contextHandle() orelse return;
    if (scissor_rasterizer_state == null) {
        const device = Context.deviceHandle() orelse return;
        const desc = core.D3D11_RASTERIZER_DESC{
            .fill_mode = core.D3D11_FILL_SOLID,
            .cull_mode = core.D3D11_CULL_NONE,
            .front_counter_clockwise = 0,
            .depth_bias = 0,
            .depth_bias_clamp = 0,
            .slope_scaled_depth_bias = 0,
            .depth_clip_enable = 1,
            .scissor_enable = 1,
            .multisample_enable = 0,
            .antialiased_line_enable = 0,
        };
        const create = core.comCall(device, core.slot.D3D11Device_CreateRasterizerState, *const fn (
            *anyopaque,
            *const core.D3D11_RASTERIZER_DESC,
            *?*anyopaque,
        ) callconv(.winapi) core.HRESULT);
        if (create(device, &desc, &scissor_rasterizer_state) < 0 or scissor_rasterizer_state == null) {
            std.debug.print("D3D11 rasterizer state creation failed\n", .{});
            return;
        }
    }
    const set = core.comCall(context, core.slot.D3D11DeviceContext_RSSetState, *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) void);
    set(context, scissor_rasterizer_state);
}

fn blendDesc(enabled: bool, mode: BlendMode) core.D3D11_BLEND_DESC {
    var targets: [8]core.D3D11_RENDER_TARGET_BLEND_DESC = @splat(.{
        .blend_enable = 0,
        .src_blend = core.D3D11_BLEND_ONE,
        .dest_blend = core.D3D11_BLEND_ZERO,
        .blend_op = core.D3D11_BLEND_OP_ADD,
        .src_blend_alpha = core.D3D11_BLEND_ONE,
        .dest_blend_alpha = core.D3D11_BLEND_ZERO,
        .blend_op_alpha = core.D3D11_BLEND_OP_ADD,
        .render_target_write_mask = core.D3D11_COLOR_WRITE_ENABLE_ALL,
    });
    const BlendFactors = struct {
        src: u32,
        dst: u32,
    };
    const factors: BlendFactors = switch (mode) {
        .alpha => .{ .src = core.D3D11_BLEND_SRC_ALPHA, .dst = core.D3D11_BLEND_INV_SRC_ALPHA },
        .premultiplied => .{ .src = core.D3D11_BLEND_ONE, .dst = core.D3D11_BLEND_INV_SRC_ALPHA },
    };
    targets[0] = .{
        .blend_enable = @intFromBool(enabled),
        .src_blend = factors.src,
        .dest_blend = factors.dst,
        .blend_op = core.D3D11_BLEND_OP_ADD,
        .src_blend_alpha = factors.src,
        .dest_blend_alpha = factors.dst,
        .blend_op_alpha = core.D3D11_BLEND_OP_ADD,
        .render_target_write_mask = core.D3D11_COLOR_WRITE_ENABLE_ALL,
    };
    return .{
        .alpha_to_coverage_enable = 0,
        .independent_blend_enable = 0,
        .render_target = targets,
    };
}

fn ensureBlendState(slot: *?*anyopaque, enabled: bool, mode: BlendMode) ?*anyopaque {
    if (slot.*) |state| return state;
    const device = Context.deviceHandle() orelse return null;
    const desc = blendDesc(enabled, mode);
    const create_blend = core.comCall(device, core.slot.D3D11Device_CreateBlendState, *const fn (
        *anyopaque,
        *const core.D3D11_BLEND_DESC,
        *?*anyopaque,
    ) callconv(.winapi) core.HRESULT);
    var out: ?*anyopaque = null;
    if (create_blend(device, &desc, &out) < 0 or out == null) {
        std.debug.print("D3D11 blend state creation failed\n", .{});
        return null;
    }
    slot.* = out;
    return out;
}

fn applyBlendState() void {
    const context = Context.contextHandle() orelse return;
    const state = if (!blend_enabled)
        ensureBlendState(&disabled_blend_state, false, .alpha)
    else switch (blend_mode) {
        .alpha => ensureBlendState(&alpha_blend_state, true, .alpha),
        .premultiplied => ensureBlendState(&premultiplied_blend_state, true, .premultiplied),
    };
    const om_blend = core.comCall(context, core.slot.D3D11DeviceContext_OMSetBlendState, *const fn (*anyopaque, ?*anyopaque, ?*const [4]f32, u32) callconv(.winapi) void);
    const factor = [_]f32{ 1, 1, 1, 1 };
    om_blend(context, state, &factor, 0xFFFF_FFFF);
}
