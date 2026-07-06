//! Direct3D 11 context and swapchain ownership.
//!
//! This owns the native D3D11 device, immediate context, DXGI swapchain, and a
//! tiny HLSL fallback pipeline that draws a solid quad when no feature renderer
//! submits work. Terminal-grid rendering uses the D3D11 resource and pipeline
//! modules through the existing GPU backend seam.

const std = @import("std");
const windows = std.os.windows;
const core = @import("../../../platform/dxgi_core.zig");
const fallback_marker = @import("fallback_marker.zig");
const present_policy = @import("present_policy.zig");
const render_diagnostics = @import("../../../render_diagnostics.zig");
const shaders = @import("shaders.zig");
const types = @import("../types.zig");

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
    DeviceHung,
    DeviceRemoved,
    DeviceReset,
    DriverInternalError,
    PresentFailed,
};

pub const ShaderError = error{
    ShaderCompilerUnavailable,
    ShaderCompileFailed,
};

pub const DeviceRecreatePreparation = struct {
    initialized: bool = false,
    released_backbuffer: bool = false,
    released_render_target: bool = false,
    released_phase2_pipeline: bool = false,

    pub fn anyReleased(self: DeviceRecreatePreparation) bool {
        return self.released_backbuffer or
            self.released_render_target or
            self.released_phase2_pipeline;
    }
};

pub const DeviceRecreateResult = struct {
    attempted: bool = false,
    succeeded: bool = false,
    fallback_candidate: bool = false,
    fallback_reason: present_policy.FallbackReason = .none,
    width: i32 = 0,
    height: i32 = 0,
    error_name: []const u8 = "none",

    pub fn failed(self: DeviceRecreateResult) bool {
        return self.attempted and !self.succeeded;
    }

    pub fn fallbackReasonName(self: DeviceRecreateResult) []const u8 {
        return self.fallback_reason.name();
    }

    pub fn fallbackMarkerReason(self: DeviceRecreateResult) fallback_marker.Reason {
        return switch (self.fallback_reason) {
            .none => .unknown,
            .device_lost => .device_lost,
            .invalid_call => .invalid_call,
            .present_failed => .present_failed,
            .resize_failed => .resize_failed,
            .recreate_failed => .recreate_failed,
            .render_target_failed => .render_target_failed,
        };
    }
};

/// DXGI Present sync interval (0 = tear off, 1 = vsync). Defaults to vsync on;
/// the in-app GPU benchmark sets it to 0 so the main loop spins at the GPU's
/// max frame rate instead of being capped at the refresh rate.
var present_interval: u32 = 1;

/// Set the Present sync interval. Called by the benchmark startup to disable
/// vsync; normal app sessions leave the default (1).
pub fn setPresentInterval(interval: u32) void {
    present_interval = interval;
}

/// Active adapter identity for the benchmark report. `buf` backs the UTF-8 name
/// (the adapter description is stored UTF-16); the returned `name` borrows it,
/// so `buf` must outlive the result. Returns null before the device is created.
pub fn adapterReport(buf: []u8) ?types.AdapterReport {
    const s = state orelse return null;
    if (!s.adapter.available) return null;
    const name = s.adapter.descriptionUtf8(buf);
    return .{
        .name = name,
        .vendor_id = s.adapter.vendor_id,
        .device_id = s.adapter.device_id,
    };
}

const State = struct {
    hwnd: HWND,
    device: *anyopaque,
    context: *anyopaque,
    swapchain: *anyopaque,
    backbuffer: ?*anyopaque = null,
    rtv: ?*anyopaque = null,
    current_rtv: ?*anyopaque = null,
    current_width: i32 = 0,
    current_height: i32 = 0,
    vertex_shader: ?*anyopaque = null,
    pixel_shader: ?*anyopaque = null,
    adapter: AdapterInfo = .{},
    feature_level: u32 = 0,
    policy: present_policy.Policy,
    width: i32,
    height: i32,
    feature_draws_this_frame: bool = false,

    fn clearAndFlushContext(self: *State) void {
        const clear_state = core.comCall(self.context, core.slot.D3D11DeviceContext_ClearState, *const fn (*anyopaque) callconv(.winapi) void);
        clear_state(self.context);
        const flush = core.comCall(self.context, core.slot.D3D11DeviceContext_Flush, *const fn (*anyopaque) callconv(.winapi) void);
        flush(self.context);
        self.current_rtv = null;
        self.current_width = 0;
        self.current_height = 0;
    }

    fn unbindRenderTargets(self: *State) void {
        const om_set = core.comCall(self.context, core.slot.D3D11DeviceContext_OMSetRenderTargets, *const fn (*anyopaque, u32, [*]const ?*anyopaque, ?*anyopaque) callconv(.winapi) void);
        var rtvs = [_]?*anyopaque{null};
        om_set(self.context, 1, &rtvs, null);
        self.current_rtv = null;
        self.current_width = 0;
        self.current_height = 0;
    }

    fn releaseSized(self: *State) void {
        self.unbindRenderTargets();
        self.clearAndFlushContext();
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
        core.comRelease(self.context);
        core.comRelease(self.swapchain);
        core.comRelease(self.device);
    }
};

pub threadlocal var state: ?State = null;
threadlocal var force_recreate_failure_for_smoke = false;
pub threadlocal var gl: GlTable = .{};

const GlTable = @import("GlTable.zig").GlTable;

const AdapterInfo = struct {
    available: bool = false,
    description: [128]u16 = [_]u16{0} ** 128,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    sub_sys_id: u32 = 0,
    revision: u32 = 0,
    dedicated_video_memory: usize = 0,
    dedicated_system_memory: usize = 0,
    shared_system_memory: usize = 0,
    luid_low: u32 = 0,
    luid_high: i32 = 0,
    flags: u32 = 0,
    output_count: u32 = 0,

    fn descriptionUtf8(self: *const AdapterInfo, buf: []u8) []const u8 {
        if (!self.available or buf.len == 0) return "";
        const end = std.mem.indexOfScalar(u16, &self.description, 0) orelse self.description.len;
        if (end == 0) return "";
        const written = std.unicode.utf16LeToUtf8(buf, self.description[0..end]) catch return "unavailable";
        return buf[0..written];
    }
};

const SwapchainCreateResult = struct {
    swapchain: *anyopaque,
    adapter: AdapterInfo,
};

pub fn init(_: anytype) !void {
    return error.D3D11RequiresWindow;
}

pub fn initWithLayer(_: ?*anyopaque) !void {
    return error.D3D11RequiresWindow;
}

pub fn initForWindow(hwnd: HWND, width: i32, height: i32) InitError!void {
    if (state) |*self| {
        self.deinit();
        state = null;
    }

    state = try createStateForWindow(hwnd, width, height);
    logBackendInit(&state.?);
    std.debug.print("D3D11: native backend initialized {}x{}\n", .{ width, height });
}

fn createStateForWindow(hwnd: HWND, width: i32, height: i32) InitError!State {
    if (width <= 0 or height <= 0) return error.SwapchainCreateFailed;

    const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
        return error.D3D11Unavailable;
    const create_device: D3D11CreateDeviceFn = @ptrCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse
        return error.D3D11Unavailable);

    var device: ?*anyopaque = null;
    var context: ?*anyopaque = null;
    var feature_level: u32 = 0;
    if (create_device(
        null,
        core.D3D_DRIVER_TYPE_HARDWARE,
        null,
        core.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        null,
        0,
        core.D3D11_SDK_VERSION,
        &device,
        &feature_level,
        &context,
    ) < 0 or device == null or context == null) return error.DeviceCreateFailed;
    errdefer {
        core.comRelease(context.?);
        core.comRelease(device.?);
    }

    const swapchain_result = try createSwapchain(device.?, hwnd, width, height);
    errdefer core.comRelease(swapchain_result.swapchain);

    var next = State{
        .hwnd = hwnd,
        .device = device.?,
        .context = context.?,
        .swapchain = swapchain_result.swapchain,
        .adapter = swapchain_result.adapter,
        .feature_level = feature_level,
        .policy = present_policy.Policy.init(width, height),
        .width = width,
        .height = height,
    };
    errdefer next.deinit();

    try createRenderTarget(&next, width, height);
    try createPhase2Pipeline(&next);

    return next;
}

fn createSwapchain(device: *anyopaque, hwnd: HWND, width: i32, height: i32) InitError!SwapchainCreateResult {
    const dxgi_device = core.comQueryInterface(device, &core.IID_IDXGIDevice) orelse
        return error.FactoryUnavailable;
    defer core.comRelease(dxgi_device);

    const get_adapter = core.comCall(dxgi_device, core.slot.DXGIDevice_GetAdapter, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
    var adapter: ?*anyopaque = null;
    if (get_adapter(dxgi_device, &adapter) < 0 or adapter == null) return error.FactoryUnavailable;
    defer core.comRelease(adapter.?);
    const adapter_info = queryAdapterInfo(adapter.?);

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
    const hr = create_for_hwnd(factory.?, device, hwnd, &desc, null, null, &swapchain);
    if (hr < 0 or swapchain == null) {
        render_diagnostics.log(
            "gpu-backend=d3d11 create swapchain failed hr=0x{x:0>8} kind={s} swapchain={}x{}",
            .{ core.hresultBits(hr), core.dxgiFailureKind(hr).name(), width, height },
        );
        return error.SwapchainCreateFailed;
    }

    const make_assoc = core.comCall(factory.?, core.slot.DXGIFactory_MakeWindowAssociation, *const fn (*anyopaque, HWND, u32) callconv(.winapi) HRESULT);
    _ = make_assoc(factory.?, hwnd, DXGI_MWA_NO_ALT_ENTER);

    return .{ .swapchain = swapchain.?, .adapter = adapter_info };
}

fn queryAdapterInfo(adapter: *anyopaque) AdapterInfo {
    const adapter1 = core.comQueryInterface(adapter, &core.IID_IDXGIAdapter1) orelse return .{};
    defer core.comRelease(adapter1);

    const get_desc = core.comCall(adapter1, core.slot.DXGIAdapter1_GetDesc1, *const fn (*anyopaque, *core.DXGI_ADAPTER_DESC1) callconv(.winapi) HRESULT);
    var desc: core.DXGI_ADAPTER_DESC1 = undefined;
    if (get_desc(adapter1, &desc) < 0) return .{};

    return .{
        .available = true,
        .description = desc.description,
        .vendor_id = desc.vendor_id,
        .device_id = desc.device_id,
        .sub_sys_id = desc.sub_sys_id,
        .revision = desc.revision,
        .dedicated_video_memory = desc.dedicated_video_memory,
        .dedicated_system_memory = desc.dedicated_system_memory,
        .shared_system_memory = desc.shared_system_memory,
        .luid_low = desc.adapter_luid.low_part,
        .luid_high = desc.adapter_luid.high_part,
        .flags = desc.flags,
        .output_count = countAdapterOutputs(adapter1),
    };
}

fn countAdapterOutputs(adapter1: *anyopaque) u32 {
    const enum_outputs = core.comCall(adapter1, core.slot.DXGIAdapter1_EnumOutputs, *const fn (*anyopaque, u32, *?*anyopaque) callconv(.winapi) HRESULT);
    var count: u32 = 0;
    while (count < 32) : (count += 1) {
        var output: ?*anyopaque = null;
        const hr = enum_outputs(adapter1, count, &output);
        if (hr == core.DXGI_ERROR_NOT_FOUND) return count;
        if (hr < 0 or output == null) return count;
        core.comRelease(output.?);
    }
    return count;
}

fn logBackendInit(self: *const State) void {
    if (self.adapter.available) {
        var desc_buf: [256]u8 = undefined;
        const adapter_description = self.adapter.descriptionUtf8(&desc_buf);
        render_diagnostics.log(
            "gpu-backend=d3d11 present=dxgi swapchain={}x{} swap_effect={s} adapter_vendor=0x{x} adapter_device=0x{x} adapter_luid={x}:{x} adapter_flags=0x{x} fallback_reason=none policy_state={s} fallback_candidate=false",
            .{
                self.width,
                self.height,
                core.dxgiSwapEffectName(core.DXGI_SWAP_EFFECT_FLIP_DISCARD),
                self.adapter.vendor_id,
                self.adapter.device_id,
                @as(u32, @bitCast(self.adapter.luid_high)),
                self.adapter.luid_low,
                self.adapter.flags,
                self.policy.status().stateName(),
            },
        );
        render_diagnostics.log(
            "gpu-backend=d3d11 environment adapter_description=\"{s}\" vendor_id=0x{x} device_id=0x{x} subsys_id=0x{x} revision={} dedicated_video_memory={} dedicated_system_memory={} shared_system_memory={} adapter_luid={x}:{x} adapter_flags=0x{x} output_count={} feature_level={s} swap_effect={s}",
            .{
                adapter_description,
                self.adapter.vendor_id,
                self.adapter.device_id,
                self.adapter.sub_sys_id,
                self.adapter.revision,
                self.adapter.dedicated_video_memory,
                self.adapter.dedicated_system_memory,
                self.adapter.shared_system_memory,
                @as(u32, @bitCast(self.adapter.luid_high)),
                self.adapter.luid_low,
                self.adapter.flags,
                self.adapter.output_count,
                core.d3dFeatureLevelName(self.feature_level),
                core.dxgiSwapEffectName(core.DXGI_SWAP_EFFECT_FLIP_DISCARD),
            },
        );
    } else {
        render_diagnostics.log(
            "gpu-backend=d3d11 present=dxgi swapchain={}x{} swap_effect={s} adapter=unknown fallback_reason=none policy_state={s} fallback_candidate=false",
            .{ self.width, self.height, core.dxgiSwapEffectName(core.DXGI_SWAP_EFFECT_FLIP_DISCARD), self.policy.status().stateName() },
        );
        render_diagnostics.log(
            "gpu-backend=d3d11 environment adapter_description=\"unknown\" output_count=0 feature_level={s} swap_effect={s}",
            .{ core.d3dFeatureLevelName(self.feature_level), core.dxgiSwapEffectName(core.DXGI_SWAP_EFFECT_FLIP_DISCARD) },
        );
    }
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
    bindRenderTargetViewForState(self, self.rtv, self.width, self.height);
}

fn bindRenderTargetViewForState(self: *State, rtv: ?*anyopaque, width: i32, height: i32) void {
    if (rtv == null) return;
    const om_set = core.comCall(self.context, core.slot.D3D11DeviceContext_OMSetRenderTargets, *const fn (*anyopaque, u32, [*]const ?*anyopaque, ?*anyopaque) callconv(.winapi) void);
    var rtvs = [_]?*anyopaque{rtv};
    om_set(self.context, 1, &rtvs, null);
    self.current_rtv = rtv;
    self.current_width = width;
    self.current_height = height;

    const viewport = core.D3D11_VIEWPORT{
        .top_left_x = 0,
        .top_left_y = 0,
        .width = @floatFromInt(@max(width, 1)),
        .height = @floatFromInt(@max(height, 1)),
        .min_depth = 0,
        .max_depth = 1,
    };
    const rs_viewports = core.comCall(self.context, core.slot.D3D11DeviceContext_RSSetViewports, *const fn (*anyopaque, u32, *const core.D3D11_VIEWPORT) callconv(.winapi) void);
    rs_viewports(self.context, 1, &viewport);
}

pub fn bindRenderTargetView(rtv: ?*anyopaque, width: i32, height: i32) void {
    if (state) |*self| bindRenderTargetViewForState(self, rtv, width, height);
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

/// D3DCompile entry point, loaded once per thread. The compiler module stays
/// resident on purpose: pipelines are recompiled on device recreate, and the
/// DLL image is file-backed/shared — the waste was re-LoadLibraryW'ing it for
/// every one of the ~18 startup compiles (refcount grew, never released).
threadlocal var g_d3dcompile: ?D3DCompileFn = null;

pub fn compileShaderBlob(source: []const u8, entrypoint: [*:0]const u8, target: [*:0]const u8) ShaderError!*anyopaque {
    const compile = g_d3dcompile orelse blk: {
        const compiler = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3dcompiler_47.dll")) orelse
            return error.ShaderCompilerUnavailable;
        const f: D3DCompileFn = @ptrCast(GetProcAddress(compiler, "D3DCompile") orelse
            return error.ShaderCompilerUnavailable);
        g_d3dcompile = f;
        break :blk f;
    };

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

pub fn currentRenderTargetSize() ?struct { width: i32, height: i32 } {
    return if (state) |*self| .{ .width = self.current_width, .height = self.current_height } else null;
}

pub fn beginFrame() void {
    if (state) |*self| {
        self.feature_draws_this_frame = false;
        bindRenderTargetAndViewport(self);
    }
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
    if (state == null) return false;
    const self = &state.?;
    switch (self.policy.frameAction(width, height)) {
        .skip => return false,
        .present => return true,
        .resize_then_present => {},
        .wait_for_recreate, .fallback_candidate => return false,
    }

    self.releaseSized();
    const resize_buffers = core.comCall(self.swapchain, core.slot.DXGISwapChain_ResizeBuffers, *const fn (*anyopaque, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT);
    const hr = resize_buffers(self.swapchain, 0, @intCast(width), @intCast(height), 0, 0);
    if (hr < 0) {
        const status = self.policy.noteDxgiFailure(.resize, hr);
        logDxgiFailure(self, "resize", hr, status);
        return false;
    }
    createRenderTarget(self, width, height) catch |err| {
        const status = self.policy.noteBackendFailure(.resize_target, .render_target_failed, false);
        render_diagnostics.log(
            "gpu-backend=d3d11 resize target failed: {s} policy_state={s} fallback_candidate={} fallback_candidate_reason={s} requires_device_recreate={}",
            .{ @errorName(err), status.stateName(), status.fallbackCandidate(), status.reasonName(), status.requires_device_recreate },
        );
        return false;
    };
    self.policy.noteResizeSucceeded(width, height);
    render_diagnostics.log("gpu-backend=d3d11 resized swapchain to {}x{}", .{ width, height });
    return true;
}

pub fn clear(r: f32, g: f32, b: f32, a: f32) void {
    if (state == null) return;
    const self = &state.?;
    const rtv = self.current_rtv orelse self.rtv orelse return;
    if (self.rtv) |backbuffer_rtv| {
        if (rtv == backbuffer_rtv) bindRenderTargetAndViewport(self);
    }
    const bound_rtv = self.current_rtv orelse rtv;
    const color = [_]f32{ r, g, b, a };
    const clear_rtv = core.comCall(self.context, core.slot.D3D11DeviceContext_ClearRenderTargetView, *const fn (*anyopaque, *anyopaque, *const [4]f32) callconv(.winapi) void);
    clear_rtv(self.context, bound_rtv, &color);
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
    switch (self.policy.frameAction(self.width, self.height)) {
        .present => {},
        .skip, .resize_then_present, .wait_for_recreate, .fallback_candidate => return,
    }
    const present_fn = core.comCall(self.swapchain, core.slot.DXGISwapChain_Present, *const fn (*anyopaque, u32, u32) callconv(.winapi) HRESULT);
    const hr = present_fn(self.swapchain, present_interval, 0);
    if (hr < 0) {
        const status = self.policy.noteDxgiFailure(.present, hr);
        logDxgiFailure(self, "present", hr, status);
        return presentErrorFromHRESULT(hr);
    }
}

fn presentErrorFromHRESULT(hr: HRESULT) PresentError {
    return switch (core.dxgiFailureKind(hr)) {
        .device_removed => error.DeviceRemoved,
        .device_hung => error.DeviceHung,
        .device_reset => error.DeviceReset,
        .driver_internal_error => error.DriverInternalError,
        else => error.PresentFailed,
    };
}

fn deviceRemovedReason(self: *const State) HRESULT {
    const get_reason = core.comCall(self.device, core.slot.D3D11Device_GetDeviceRemovedReason, *const fn (*anyopaque) callconv(.winapi) HRESULT);
    return get_reason(self.device);
}

pub fn presentPolicyStatus() present_policy.Status {
    return if (state) |*self| self.policy.status() else present_policy.Status.healthy();
}

pub fn adapterFallbackIdentity(buf: []u8) ?[]const u8 {
    if (state) |*self| {
        if (!self.adapter.available) return null;
        return fallback_marker.adapterIdentity(
            buf,
            self.adapter.vendor_id,
            self.adapter.device_id,
            self.adapter.luid_low,
            self.adapter.luid_high,
        ) catch null;
    }
    return null;
}

pub fn takeRecoveryRequest() ?present_policy.RecoveryRequest {
    return if (state) |*self| self.policy.takeRecoveryRequest() else null;
}

pub fn needsDeviceRecreate() bool {
    return presentPolicyStatus().state == .needs_recreate;
}

pub fn prepareForDeviceRecreate() DeviceRecreatePreparation {
    if (state == null) return .{};
    const self = &state.?;
    const result = DeviceRecreatePreparation{
        .initialized = true,
        .released_backbuffer = self.backbuffer != null,
        .released_render_target = self.rtv != null,
        .released_phase2_pipeline = self.vertex_shader != null or self.pixel_shader != null,
    };
    self.releaseSized();
    self.releaseShaders();
    render_diagnostics.log(
        "gpu-backend=d3d11 device recreate preparation context_initialized=true released_backbuffer={} released_render_target={} released_phase2_pipeline={} released_any={}",
        .{
            result.released_backbuffer,
            result.released_render_target,
            result.released_phase2_pipeline,
            result.anyReleased(),
        },
    );
    return result;
}

pub fn recreateDevice(width: i32, height: i32) DeviceRecreateResult {
    if (state == null) return .{ .error_name = "not_initialized" };

    const self = &state.?;
    const hwnd = self.hwnd;
    const target_width = if (width > 0) width else self.width;
    const target_height = if (height > 0) height else self.height;
    const result_base = DeviceRecreateResult{
        .attempted = true,
        .width = target_width,
        .height = target_height,
    };

    if (force_recreate_failure_for_smoke) {
        force_recreate_failure_for_smoke = false;
        const status = self.policy.noteRecreateFailed();
        render_diagnostics.log(
            "gpu-backend=d3d11 device recreate forced failure for smoke error=smoke_forced_recreate_failed swapchain={}x{} policy_state={s} fallback_candidate={} fallback_candidate_reason={s} automatic_fallback=false default_unchanged=true",
            .{ target_width, target_height, status.stateName(), status.fallbackCandidate(), status.reasonName() },
        );
        var failed_result = result_base;
        failed_result.error_name = "smoke_forced_recreate_failed";
        failed_result.fallback_candidate = status.fallbackCandidate();
        failed_result.fallback_reason = status.reason;
        return failed_result;
    }

    var old = state.?;
    state = null;
    old.deinit();

    const next = createStateForWindow(hwnd, target_width, target_height) catch |err| {
        const failed_status = old.policy.noteRecreateFailed();
        render_diagnostics.log(
            "gpu-backend=d3d11 device recreate failed error={s} swapchain={}x{} policy_state={s} fallback_candidate={} fallback_candidate_reason={s} automatic_fallback=false default_unchanged=true",
            .{ @errorName(err), target_width, target_height, failed_status.stateName(), failed_status.fallbackCandidate(), failed_status.reasonName() },
        );
        var failed_result = result_base;
        failed_result.error_name = @errorName(err);
        failed_result.fallback_candidate = failed_status.fallbackCandidate();
        failed_result.fallback_reason = failed_status.reason;
        return failed_result;
    };

    state = next;
    logBackendInit(&state.?);
    render_diagnostics.log(
        "gpu-backend=d3d11 device recreate succeeded swapchain={}x{} policy_state={s} automatic_fallback=false default_unchanged=true",
        .{ target_width, target_height, state.?.policy.status().stateName() },
    );
    var success_result = result_base;
    success_result.succeeded = true;
    return success_result;
}

pub fn requestDeviceRecreateForSmoke() bool {
    if (state == null) return false;
    const status = state.?.policy.noteBackendFailure(.present, .device_lost, true);
    render_diagnostics.log(
        "gpu-backend=d3d11 recreate smoke latched policy_state={s} fallback_candidate_reason={s} requires_device_recreate={}",
        .{ status.stateName(), status.reasonName(), status.requires_device_recreate },
    );
    return status.requires_device_recreate;
}

pub fn requestFailedDeviceRecreateForSmoke() bool {
    if (state == null) return false;
    force_recreate_failure_for_smoke = true;
    const status = state.?.policy.noteBackendFailure(.present, .device_lost, true);
    render_diagnostics.log(
        "gpu-backend=d3d11 recreate failure smoke latched policy_state={s} fallback_candidate_reason={s} requires_device_recreate={}",
        .{ status.stateName(), status.reasonName(), status.requires_device_recreate },
    );
    return status.requires_device_recreate;
}

fn logDxgiFailure(self: *const State, operation: []const u8, hr: HRESULT, status: present_policy.Status) void {
    const kind = core.dxgiFailureKind(hr);
    if (kind.requiresDeviceRecreate()) {
        const reason = deviceRemovedReason(self);
        render_diagnostics.log(
            "gpu-backend=d3d11 {s} failed hr=0x{x:0>8} kind={s} device_removed_reason=0x{x:0>8} device_removed_kind={s} policy_state={s} fallback_candidate={} fallback_candidate_reason={s} requires_device_recreate=true fallback_reason=device_lost",
            .{ operation, core.hresultBits(hr), kind.name(), core.hresultBits(reason), core.dxgiFailureName(reason), status.stateName(), status.fallbackCandidate(), status.reasonName() },
        );
        return;
    }

    render_diagnostics.log(
        "gpu-backend=d3d11 {s} failed hr=0x{x:0>8} kind={s} policy_state={s} fallback_candidate={} fallback_candidate_reason={s} requires_device_recreate=false fallback_reason={s}",
        .{ operation, core.hresultBits(hr), kind.name(), status.stateName(), status.fallbackCandidate(), status.reasonName(), status.reasonName() },
    );
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

test "D3D11 present errors distinguish device-loss HRESULTs" {
    try std.testing.expectEqual(error.DeviceRemoved, presentErrorFromHRESULT(core.DXGI_ERROR_DEVICE_REMOVED));
    try std.testing.expectEqual(error.DeviceHung, presentErrorFromHRESULT(core.DXGI_ERROR_DEVICE_HUNG));
    try std.testing.expectEqual(error.DeviceReset, presentErrorFromHRESULT(core.DXGI_ERROR_DEVICE_RESET));
    try std.testing.expectEqual(error.DriverInternalError, presentErrorFromHRESULT(core.DXGI_ERROR_DRIVER_INTERNAL_ERROR));
    try std.testing.expectEqual(error.PresentFailed, presentErrorFromHRESULT(core.DXGI_ERROR_INVALID_CALL));
}

test "D3D11 context device recreate preparation is a no-op when uninitialized" {
    const preparation = prepareForDeviceRecreate();
    try std.testing.expect(!preparation.initialized);
    try std.testing.expect(!preparation.anyReleased());
}

test "D3D11 context device recreate reports no attempt when uninitialized" {
    const result = recreateDevice(800, 600);
    try std.testing.expect(!result.attempted);
    try std.testing.expect(!result.succeeded);
    try std.testing.expect(!result.failed());
    try std.testing.expectEqualStrings("not_initialized", result.error_name);
}

test "D3D11 context recreate result reports fallback reason names" {
    const result = DeviceRecreateResult{
        .attempted = true,
        .fallback_candidate = true,
        .fallback_reason = .recreate_failed,
        .error_name = "smoke_forced_recreate_failed",
    };

    try std.testing.expect(result.failed());
    try std.testing.expect(result.fallback_candidate);
    try std.testing.expectEqualStrings("recreate_failed", result.fallbackReasonName());
    try std.testing.expectEqual(fallback_marker.Reason.recreate_failed, result.fallbackMarkerReason());
}

test "D3D11 adapter info converts UTF-16 descriptions for diagnostics" {
    var info = AdapterInfo{ .available = true };
    const text = std.unicode.utf8ToUtf16LeStringLiteral("Test Adapter");
    @memcpy(info.description[0..text.len], text);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Test Adapter", info.descriptionUtf8(&buf));
}
