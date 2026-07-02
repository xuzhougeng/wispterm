//! Direct3D 11 context and swapchain ownership.
//!
//! This owns the native D3D11 device, immediate context, DXGI swapchain, and a
//! tiny HLSL fallback pipeline that draws a solid quad when no feature renderer
//! submits work. Terminal-grid rendering uses the D3D11 resource and pipeline
//! modules through the existing GPU backend seam.

const std = @import("std");
const windows = std.os.windows;
const core = @import("../../../platform/dxgi_core.zig");
const render_diagnostics = @import("../../../render_diagnostics.zig");
const shaders = @import("shaders.zig");

const HWND = windows.HWND;
const HMODULE = windows.HMODULE;
const HRESULT = core.HRESULT;

const DXGI_MWA_NO_ALT_ENTER: u32 = 0x2;

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

const D3D11CreateDeviceFn = *const fn (
    adapter: ?*anyopaque,
    driver_type: u32,
    software: ?HMODULE,
    flags: u32,
    feature_levels: ?[*]const u32,
    num_feature_levels: u32,
    sdk_version: u32,
    device: *?*anyopaque,
    feature_level: ?*u32,
    immediate_context: *?*anyopaque,
) callconv(.winapi) HRESULT;

const D3DCompileFn = *const fn (
    src_data: *const anyopaque,
    src_data_size: usize,
    source_name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entrypoint: [*:0]const u8,
    target: [*:0]const u8,
    flags1: u32,
    flags2: u32,
    code: *?*anyopaque,
    errors: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub const InitError = error{
    D3D11Unavailable,
    DeviceCreateFailed,
    FactoryUnavailable,
    SwapchainCreateFailed,
    BackbufferUnavailable,
    RenderTargetCreateFailed,
    ShaderCompilerUnavailable,
    ShaderCompileFailed,
    ShaderCreateFailed,
};

pub const PresentError = error{
    PresentFailed,
};

pub const ShaderError = error{
    ShaderCompilerUnavailable,
    ShaderCompileFailed,
};

const State = struct {
    device: *anyopaque,
    context: *anyopaque,
    swapchain: *anyopaque,
    backbuffer: ?*anyopaque = null,
    rtv: ?*anyopaque = null,
    vertex_shader: ?*anyopaque = null,
    pixel_shader: ?*anyopaque = null,
    width: i32,
    height: i32,
    feature_draws_this_frame: bool = false,

    fn releaseSized(self: *State) void {
        if (self.rtv) |rtv| {
            core.comRelease(rtv);
            self.rtv = null;
        }
        if (self.backbuffer) |backbuffer| {
            core.comRelease(backbuffer);
            self.backbuffer = null;
        }
    }

    fn releaseShaders(self: *State) void {
        if (self.pixel_shader) |ps| {
            core.comRelease(ps);
            self.pixel_shader = null;
        }
        if (self.vertex_shader) |vs| {
            core.comRelease(vs);
            self.vertex_shader = null;
        }
    }

    fn deinit(self: *State) void {
        self.releaseSized();
        self.releaseShaders();
        core.comRelease(self.swapchain);
        core.comRelease(self.context);
        core.comRelease(self.device);
    }
};

pub threadlocal var state: ?State = null;
pub threadlocal var gl: GlTable = .{};

const GlTable = @import("GlTable.zig").GlTable;

pub fn init(_: anytype) !void {
    return error.D3D11RequiresWindow;
}

pub fn initWithLayer(_: ?*anyopaque) !void {
    return error.D3D11RequiresWindow;
}

pub fn initForWindow(hwnd: HWND, width: i32, height: i32) InitError!void {
    if (width <= 0 or height <= 0) return error.SwapchainCreateFailed;

    const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
        return error.D3D11Unavailable;
    const create_device: D3D11CreateDeviceFn = @ptrCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse
        return error.D3D11Unavailable);

    var device: ?*anyopaque = null;
    var context: ?*anyopaque = null;
    if (create_device(
        null,
        core.D3D_DRIVER_TYPE_HARDWARE,
        null,
        core.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        null,
        0,
        core.D3D11_SDK_VERSION,
        &device,
        null,
        &context,
    ) < 0 or device == null or context == null) return error.DeviceCreateFailed;
    errdefer {
        core.comRelease(context.?);
        core.comRelease(device.?);
    }

    const swapchain = try createSwapchain(device.?, hwnd, width, height);
    errdefer core.comRelease(swapchain);

    var next = State{
        .device = device.?,
        .context = context.?,
        .swapchain = swapchain,
        .width = width,
        .height = height,
    };
    errdefer next.deinit();

    try createRenderTarget(&next, width, height);
    try createPhase2Pipeline(&next);

    state = next;
    render_diagnostics.log("gpu-backend=d3d11 present=dxgi swapchain={}x{}", .{ width, height });
    std.debug.print("D3D11: native backend initialized {}x{}\n", .{ width, height });
}

fn createSwapchain(device: *anyopaque, hwnd: HWND, width: i32, height: i32) InitError!*anyopaque {
    const dxgi_device = core.comQueryInterface(device, &core.IID_IDXGIDevice) orelse
        return error.FactoryUnavailable;
    defer core.comRelease(dxgi_device);

    const get_adapter = core.comCall(dxgi_device, core.slot.DXGIDevice_GetAdapter, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
    var adapter: ?*anyopaque = null;
    if (get_adapter(dxgi_device, &adapter) < 0 or adapter == null) return error.FactoryUnavailable;
    defer core.comRelease(adapter.?);

    const get_parent = core.comCall(adapter.?, core.slot.DXGIObject_GetParent, *const fn (*anyopaque, *const core.Guid, *?*anyopaque) callconv(.winapi) HRESULT);
    var factory: ?*anyopaque = null;
    if (get_parent(adapter.?, &core.IID_IDXGIFactory2, &factory) < 0 or factory == null)
        return error.FactoryUnavailable;
    defer core.comRelease(factory.?);

    const desc = core.DXGI_SWAP_CHAIN_DESC1{
        .width = @intCast(width),
        .height = @intCast(height),
        .format = core.DXGI_FORMAT_B8G8R8A8_UNORM,
        .stereo = 0,
        .sample_desc = .{ .count = 1, .quality = 0 },
        .buffer_usage = core.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .buffer_count = 2,
        .scaling = core.DXGI_SCALING_NONE,
        .swap_effect = core.DXGI_SWAP_EFFECT_FLIP_DISCARD,
        .alpha_mode = core.DXGI_ALPHA_MODE_IGNORE,
        .flags = 0,
    };
    const create_for_hwnd = core.comCall(factory.?, core.slot.DXGIFactory2_CreateSwapChainForHwnd, *const fn (
        *anyopaque,
        *anyopaque,
        HWND,
        *const core.DXGI_SWAP_CHAIN_DESC1,
        ?*const anyopaque,
        ?*anyopaque,
        *?*anyopaque,
    ) callconv(.winapi) HRESULT);
    var swapchain: ?*anyopaque = null;
    if (create_for_hwnd(factory.?, device, hwnd, &desc, null, null, &swapchain) < 0 or swapchain == null)
        return error.SwapchainCreateFailed;

    const make_assoc = core.comCall(factory.?, core.slot.DXGIFactory_MakeWindowAssociation, *const fn (*anyopaque, HWND, u32) callconv(.winapi) HRESULT);
    _ = make_assoc(factory.?, hwnd, DXGI_MWA_NO_ALT_ENTER);

    return swapchain.?;
}

fn createRenderTarget(self: *State, width: i32, height: i32) InitError!void {
    const get_buffer = core.comCall(self.swapchain, core.slot.DXGISwapChain_GetBuffer, *const fn (*anyopaque, u32, *const core.Guid, *?*anyopaque) callconv(.winapi) HRESULT);
    var backbuffer: ?*anyopaque = null;
    if (get_buffer(self.swapchain, 0, &core.IID_ID3D11Texture2D, &backbuffer) < 0 or backbuffer == null)
        return error.BackbufferUnavailable;
    errdefer core.comRelease(backbuffer.?);

    const create_rtv = core.comCall(self.device, core.slot.D3D11Device_CreateRenderTargetView, *const fn (*anyopaque, *anyopaque, ?*const anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
    var rtv: ?*anyopaque = null;
    if (create_rtv(self.device, backbuffer.?, null, &rtv) < 0 or rtv == null)
        return error.RenderTargetCreateFailed;

    self.backbuffer = backbuffer;
    self.rtv = rtv;
    self.width = width;
    self.height = height;
    bindRenderTargetAndViewport(self);
}

fn bindRenderTargetAndViewport(self: *State) void {
    const om_set = core.comCall(self.context, core.slot.D3D11DeviceContext_OMSetRenderTargets, *const fn (*anyopaque, u32, [*]const ?*anyopaque, ?*anyopaque) callconv(.winapi) void);
    var rtvs = [_]?*anyopaque{self.rtv.?};
    om_set(self.context, 1, &rtvs, null);

    const viewport = core.D3D11_VIEWPORT{
        .top_left_x = 0,
        .top_left_y = 0,
        .width = @floatFromInt(@max(self.width, 1)),
        .height = @floatFromInt(@max(self.height, 1)),
        .min_depth = 0,
        .max_depth = 1,
    };
    const rs_viewports = core.comCall(self.context, core.slot.D3D11DeviceContext_RSSetViewports, *const fn (*anyopaque, u32, *const core.D3D11_VIEWPORT) callconv(.winapi) void);
    rs_viewports(self.context, 1, &viewport);
}

fn createPhase2Pipeline(self: *State) InitError!void {
    const vs_blob = try compileShaderBlob(shaders.phase2_vertex, "vs_main", "vs_4_0");
    defer core.comRelease(vs_blob);
    const ps_blob = try compileShaderBlob(shaders.phase2_pixel, "ps_main", "ps_4_0");
    defer core.comRelease(ps_blob);

    const create_vs = core.comCall(self.device, core.slot.D3D11Device_CreateVertexShader, *const fn (*anyopaque, *const anyopaque, usize, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
    const create_ps = core.comCall(self.device, core.slot.D3D11Device_CreatePixelShader, *const fn (*anyopaque, *const anyopaque, usize, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);

    var vs: ?*anyopaque = null;
    if (create_vs(self.device, blobPointer(vs_blob), blobSize(vs_blob), null, &vs) < 0 or vs == null)
        return error.ShaderCreateFailed;
    errdefer core.comRelease(vs.?);

    var ps: ?*anyopaque = null;
    if (create_ps(self.device, blobPointer(ps_blob), blobSize(ps_blob), null, &ps) < 0 or ps == null)
        return error.ShaderCreateFailed;

    self.vertex_shader = vs;
    self.pixel_shader = ps;
}

pub fn compileShaderBlob(source: []const u8, entrypoint: [*:0]const u8, target: [*:0]const u8) ShaderError!*anyopaque {
    const compiler = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3dcompiler_47.dll")) orelse
        return error.ShaderCompilerUnavailable;
    const compile: D3DCompileFn = @ptrCast(GetProcAddress(compiler, "D3DCompile") orelse
        return error.ShaderCompilerUnavailable);

    var code: ?*anyopaque = null;
    var errors: ?*anyopaque = null;
    const hr = compile(
        @ptrCast(source.ptr),
        source.len,
        null,
        null,
        null,
        entrypoint,
        target,
        0,
        0,
        &code,
        &errors,
    );
    defer if (errors) |err_blob| core.comRelease(err_blob);
    if (hr < 0 or code == null) {
        if (errors) |err_blob| {
            const msg = blobBytes(err_blob);
            std.debug.print("D3D11 shader compile failed: {s}\n", .{msg});
            render_diagnostics.log("gpu-backend=d3d11 shader compile failed: {s}", .{msg});
        }
        return error.ShaderCompileFailed;
    }
    return code.?;
}

pub fn blobPointer(blob: *anyopaque) *const anyopaque {
    const f = core.comCall(blob, core.slot.Blob_GetBufferPointer, *const fn (*anyopaque) callconv(.winapi) *anyopaque);
    return f(blob);
}

pub fn blobSize(blob: *anyopaque) usize {
    const f = core.comCall(blob, core.slot.Blob_GetBufferSize, *const fn (*anyopaque) callconv(.winapi) usize);
    return f(blob);
}

pub fn blobBytes(blob: *anyopaque) []const u8 {
    const ptr: [*]const u8 = @ptrCast(blobPointer(blob));
    return ptr[0..blobSize(blob)];
}

pub fn isInitialized() bool {
    return state != null;
}

pub fn deviceHandle() ?*anyopaque {
    return if (state) |*self| self.device else null;
}

pub fn contextHandle() ?*anyopaque {
    return if (state) |*self| self.context else null;
}

pub fn backbufferHandle() ?*anyopaque {
    return if (state) |*self| self.backbuffer else null;
}

pub fn swapchainSize() ?struct { width: i32, height: i32 } {
    return if (state) |*self| .{ .width = self.width, .height = self.height } else null;
}

pub fn beginFrame() void {
    if (state) |*self| self.feature_draws_this_frame = false;
}

pub fn noteFeatureDraw() void {
    if (state) |*self| self.feature_draws_this_frame = true;
}

pub fn featureDrawsThisFrame() bool {
    return if (state) |*self| self.feature_draws_this_frame else false;
}

pub fn bindBackbufferRenderTarget() void {
    if (state) |*self| bindRenderTargetAndViewport(self);
}

pub fn resize(width: i32, height: i32) bool {
    if (width <= 0 or height <= 0) return false;
    if (state == null) return false;
    const self = &state.?;
    if (self.width == width and self.height == height) return true;

    self.releaseSized();
    const resize_buffers = core.comCall(self.swapchain, core.slot.DXGISwapChain_ResizeBuffers, *const fn (*anyopaque, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT);
    if (resize_buffers(self.swapchain, 0, @intCast(width), @intCast(height), 0, 0) < 0) {
        render_diagnostics.log("gpu-backend=d3d11 resize failed at {}x{}", .{ width, height });
        return false;
    }
    createRenderTarget(self, width, height) catch |err| {
        render_diagnostics.log("gpu-backend=d3d11 resize target failed: {s}", .{@errorName(err)});
        return false;
    };
    render_diagnostics.log("gpu-backend=d3d11 resized swapchain to {}x{}", .{ width, height });
    return true;
}

pub fn clear(r: f32, g: f32, b: f32, a: f32) void {
    if (state == null) return;
    const self = &state.?;
    bindRenderTargetAndViewport(self);
    const color = [_]f32{ r, g, b, a };
    const clear_rtv = core.comCall(self.context, core.slot.D3D11DeviceContext_ClearRenderTargetView, *const fn (*anyopaque, *anyopaque, *const [4]f32) callconv(.winapi) void);
    clear_rtv(self.context, self.rtv.?, &color);
}

pub fn drawPhase2Quad() void {
    if (state == null) return;
    const self = &state.?;
    if (self.vertex_shader == null or self.pixel_shader == null) return;
    bindRenderTargetAndViewport(self);

    const ia_topology = core.comCall(self.context, core.slot.D3D11DeviceContext_IASetPrimitiveTopology, *const fn (*anyopaque, u32) callconv(.winapi) void);
    ia_topology(self.context, core.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

    const vs_set = core.comCall(self.context, core.slot.D3D11DeviceContext_VSSetShader, *const fn (*anyopaque, ?*anyopaque, ?[*]const ?*anyopaque, u32) callconv(.winapi) void);
    const ps_set = core.comCall(self.context, core.slot.D3D11DeviceContext_PSSetShader, *const fn (*anyopaque, ?*anyopaque, ?[*]const ?*anyopaque, u32) callconv(.winapi) void);
    vs_set(self.context, self.vertex_shader, null, 0);
    ps_set(self.context, self.pixel_shader, null, 0);

    const draw = core.comCall(self.context, core.slot.D3D11DeviceContext_Draw, *const fn (*anyopaque, u32, u32) callconv(.winapi) void);
    draw(self.context, 6, 0);
}

pub fn present() PresentError!void {
    if (state == null) return;
    const self = &state.?;
    const present_fn = core.comCall(self.swapchain, core.slot.DXGISwapChain_Present, *const fn (*anyopaque, u32, u32) callconv(.winapi) HRESULT);
    if (present_fn(self.swapchain, 1, 0) < 0) return error.PresentFailed;
}

pub fn deinit() void {
    if (state) |*self| self.deinit();
    state = null;
}

test "D3D11 context module exposes the backend lifecycle surface" {
    const init_info = @typeInfo(@TypeOf(initForWindow)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), init_info.params.len);
    try std.testing.expect(@typeInfo(@TypeOf(resize)).@"fn".return_type.? == bool);
    try std.testing.expect(@typeInfo(@TypeOf(present)).@"fn".return_type.? == PresentError!void);
}
