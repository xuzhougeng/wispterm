//! DXGI flip-model presenter for the Win32 OpenGL host.
//!
//! Replaces the legacy GDI `SwapBuffers` present (BLT into the DWM
//! redirection surface) with a D3D11 flip-model swapchain shared with GL via
//! `WGL_NV_DX_interop2`. The legacy path is the source of the cross-DPI /
//! resize artifacts in issues #46/#47/#88: with the frame extended into the
//! whole client area, DWM composites the redirection surface using the GL
//! backbuffer's alpha and stale-surface contents on some drivers (Intel Arc,
//! AMD iGPU). A flip-model swapchain with `DXGI_ALPHA_MODE_IGNORE` is
//! composited opaquely and never goes through the redirection surface.
//!
//! Frame flow (per present):
//!   renderer draws to GL FBO 0 exactly as before →
//!   `presentFrame` blits FBO 0 into an interop renderbuffer (Y-flipped:
//!   GL rows are bottom-up, D3D rows top-down) backed by a shared D3D11
//!   texture → `CopyResource` into swapchain buffer 0 → `Present`.
//!
//! Every failure latches `PresentPolicy.fail()` and the caller reverts to
//! GDI `SwapBuffers` for the rest of the session, so machines without
//! `WGL_NV_DX_interop2` (or with a broken driver) keep the old behavior.
//!
//! Errors alone are not enough, though — the v1.18.0 field reports (black
//! "slideshow" frames, multi-second stalls, crashes at launch) came from
//! drivers that misbehave *without* failing any call. Three guards cover
//! those silent modes:
//!   • adapter matching: the D3D11 device is created on the DXGI adapter
//!     whose PCI vendor matches `GL_VENDOR`, never the default adapter —
//!     cross-adapter interop on hybrid-GPU laptops is what stalled/blacked
//!     out, and matching also keeps dGPU laptops on the flip-model path;
//!   • a first-frames content probe: GL readback vs staging readback of the
//!     shared texture must agree on a frame with real content, otherwise the
//!     path is silently dropping pixels → latch fallback;
//!   • a present-duration watchdog: sustained multi-hundred-ms presents
//!     (cross-GPU syncs, TDR recovery loops) → latch fallback.
//! Crashes *inside* driver init are handled one level up by the bring-up
//! fuse (state-file marker, see dxgi_core + main.zig): the next launch skips
//! the D3D path for this app version.

const std = @import("std");
const windows = std.os.windows;
const core = @import("../platform/dxgi_core.zig");
const render_diagnostics = @import("../render_diagnostics.zig");

const HWND = windows.HWND;
const HANDLE = windows.HANDLE;
const HMODULE = windows.HMODULE;
const BOOL = windows.BOOL;
const HRESULT = windows.HRESULT;

extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

// ============================================================================
// GL constants + function pointers (loaded per presenter, context current)
// ============================================================================

const GL_FRAMEBUFFER: u32 = 0x8D40;
const GL_READ_FRAMEBUFFER: u32 = 0x8CA8;
const GL_DRAW_FRAMEBUFFER: u32 = 0x8CA9;
const GL_RENDERBUFFER: u32 = 0x8D41;
const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;
const GL_NEAREST: u32 = 0x2600;
const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
const GL_SCISSOR_TEST: u32 = 0x0C11;
const GL_RGBA: u32 = 0x1908;
const GL_UNSIGNED_BYTE: u32 = 0x1401;

const WGL_ACCESS_WRITE_DISCARD_NV: u32 = 0x0002;

const DXGI_MWA_NO_ALT_ENTER: u32 = 0x2;

const GlFns = struct {
    gen_framebuffers: *const fn (i32, [*]u32) callconv(.winapi) void,
    delete_framebuffers: *const fn (i32, [*]const u32) callconv(.winapi) void,
    bind_framebuffer: *const fn (u32, u32) callconv(.winapi) void,
    framebuffer_renderbuffer: *const fn (u32, u32, u32, u32) callconv(.winapi) void,
    gen_renderbuffers: *const fn (i32, [*]u32) callconv(.winapi) void,
    delete_renderbuffers: *const fn (i32, [*]const u32) callconv(.winapi) void,
    blit_framebuffer: *const fn (i32, i32, i32, i32, i32, i32, i32, i32, u32, u32) callconv(.winapi) void,
    check_framebuffer_status: *const fn (u32) callconv(.winapi) u32,
    // GL 1.0/1.1 entry points: come from opengl32.dll directly, not
    // wglGetProcAddress.
    disable: *const fn (u32) callconv(.winapi) void,
    read_pixels: *const fn (i32, i32, i32, i32, u32, u32, *anyopaque) callconv(.winapi) void,
    get_error: *const fn () callconv(.winapi) u32,

    fn load() error{GlFunctionsMissing}!GlFns {
        const opengl32 = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll")) orelse
            return error.GlFunctionsMissing;
        return .{
            .gen_framebuffers = @ptrCast(wglGetProcAddress("glGenFramebuffers") orelse return error.GlFunctionsMissing),
            .delete_framebuffers = @ptrCast(wglGetProcAddress("glDeleteFramebuffers") orelse return error.GlFunctionsMissing),
            .bind_framebuffer = @ptrCast(wglGetProcAddress("glBindFramebuffer") orelse return error.GlFunctionsMissing),
            .framebuffer_renderbuffer = @ptrCast(wglGetProcAddress("glFramebufferRenderbuffer") orelse return error.GlFunctionsMissing),
            .gen_renderbuffers = @ptrCast(wglGetProcAddress("glGenRenderbuffers") orelse return error.GlFunctionsMissing),
            .delete_renderbuffers = @ptrCast(wglGetProcAddress("glDeleteRenderbuffers") orelse return error.GlFunctionsMissing),
            .blit_framebuffer = @ptrCast(wglGetProcAddress("glBlitFramebuffer") orelse return error.GlFunctionsMissing),
            .check_framebuffer_status = @ptrCast(wglGetProcAddress("glCheckFramebufferStatus") orelse return error.GlFunctionsMissing),
            .disable = @ptrCast(GetProcAddress(opengl32, "glDisable") orelse return error.GlFunctionsMissing),
            .read_pixels = @ptrCast(GetProcAddress(opengl32, "glReadPixels") orelse return error.GlFunctionsMissing),
            .get_error = @ptrCast(GetProcAddress(opengl32, "glGetError") orelse return error.GlFunctionsMissing),
        };
    }
};

const InteropFns = struct {
    open_device: *const fn (*anyopaque) callconv(.winapi) ?HANDLE,
    close_device: *const fn (HANDLE) callconv(.winapi) BOOL,
    set_resource_share_handle: *const fn (*anyopaque, HANDLE) callconv(.winapi) BOOL,
    register_object: *const fn (HANDLE, *anyopaque, u32, u32, u32) callconv(.winapi) ?HANDLE,
    unregister_object: *const fn (HANDLE, HANDLE) callconv(.winapi) BOOL,
    lock_objects: *const fn (HANDLE, i32, [*]HANDLE) callconv(.winapi) BOOL,
    unlock_objects: *const fn (HANDLE, i32, [*]HANDLE) callconv(.winapi) BOOL,

    fn load() error{InteropUnavailable}!InteropFns {
        return .{
            .open_device = @ptrCast(wglGetProcAddress("wglDXOpenDeviceNV") orelse return error.InteropUnavailable),
            .close_device = @ptrCast(wglGetProcAddress("wglDXCloseDeviceNV") orelse return error.InteropUnavailable),
            .set_resource_share_handle = @ptrCast(wglGetProcAddress("wglDXSetResourceShareHandleNV") orelse return error.InteropUnavailable),
            .register_object = @ptrCast(wglGetProcAddress("wglDXRegisterObjectNV") orelse return error.InteropUnavailable),
            .unregister_object = @ptrCast(wglGetProcAddress("wglDXUnregisterObjectNV") orelse return error.InteropUnavailable),
            .lock_objects = @ptrCast(wglGetProcAddress("wglDXLockObjectsNV") orelse return error.InteropUnavailable),
            .unlock_objects = @ptrCast(wglGetProcAddress("wglDXUnlockObjectsNV") orelse return error.InteropUnavailable),
        };
    }
};

// ============================================================================
// COM dispatch helpers (slot indices from dxgi_core)
// ============================================================================

fn vtable(obj: *anyopaque) [*]const *const anyopaque {
    const pp: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return pp.*;
}

fn comCall(obj: *anyopaque, comptime slot_index: usize, comptime Fn: type) Fn {
    return @ptrCast(vtable(obj)[slot_index]);
}

fn comRelease(obj: *anyopaque) void {
    const f = comCall(obj, core.slot.Release, *const fn (*anyopaque) callconv(.winapi) u32);
    _ = f(obj);
}

fn comQueryInterface(obj: *anyopaque, iid: *const core.Guid) ?*anyopaque {
    const f = comCall(obj, core.slot.QueryInterface, *const fn (*anyopaque, *const core.Guid, *?*anyopaque) callconv(.winapi) HRESULT);
    var out: ?*anyopaque = null;
    if (f(obj, iid, &out) < 0) return null;
    return out;
}

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

pub const InitError = error{
    D3D11Unavailable,
    DeviceCreateFailed,
    FactoryUnavailable,
    AdapterVendorMismatch,
    SwapchainCreateFailed,
    InteropUnavailable,
    InteropOpenFailed,
    GlFunctionsMissing,
    TextureCreateFailed,
    ShareHandleFailed,
    RegisterFailed,
    BackbufferUnavailable,
    FramebufferIncomplete,
    LockFailed,
};

const PresentError = error{
    LockFailed,
    PresentFailed,
    ProbeReadbackFailed,
    ProbeMismatch,
};

// ============================================================================
// Presenter
// ============================================================================

pub const Presenter = struct {
    gl: GlFns,
    interop: InteropFns,

    device: *anyopaque, // ID3D11Device
    context: *anyopaque, // ID3D11DeviceContext (immediate)
    swapchain: *anyopaque, // IDXGISwapChain1
    interop_device: HANDLE,

    // Sized resources, rebuilt on every swapchain resize.
    backbuffer: ?*anyopaque = null, // ID3D11Texture2D (buffer 0)
    shared_tex: ?*anyopaque = null, // ID3D11Texture2D (interop target)
    interop_object: ?HANDLE = null,
    gl_fbo: u32 = 0,
    gl_rbo: u32 = 0,
    // First-frames probe: a CPU-readable copy of shared_tex, compared against
    // GL readbacks until the path has verifiably carried real content once.
    probe_staging: ?*anyopaque = null, // ID3D11Texture2D (STAGING)
    probe_done: bool = false,
    probe_frames: u32 = 0,

    policy: core.PresentPolicy,

    /// Requires the window's GL context to be current (interop + GL function
    /// loading both depend on it). `gl_vendor` is `glGetString(GL_VENDOR)`:
    /// the D3D11 device must be created on the same adapter the GL context
    /// runs on — interop with the default adapter on a hybrid-GPU machine
    /// silently presents black or stalls on cross-GPU syncs.
    pub fn init(hwnd: HWND, width: i32, height: i32, gl_vendor: []const u8) InitError!Presenter {
        if (width <= 0 or height <= 0) return error.SwapchainCreateFailed;

        const gl = try GlFns.load();
        const interop = try InteropFns.load();

        const want_vendor = core.pciVendorForGlVendor(gl_vendor) orelse
            return error.AdapterVendorMismatch;
        const adapter = try pickAdapter(want_vendor);
        defer comRelease(adapter);

        const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
            return error.D3D11Unavailable;
        const create_device: D3D11CreateDeviceFn = @ptrCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse
            return error.D3D11Unavailable);

        var device: ?*anyopaque = null;
        var context: ?*anyopaque = null;
        // Driver type must be UNKNOWN when an explicit adapter is passed.
        if (create_device(
            adapter,
            core.D3D_DRIVER_TYPE_UNKNOWN,
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
            comRelease(context.?);
            comRelease(device.?);
        }

        const swapchain = try createSwapchain(device.?, hwnd, width, height);
        errdefer comRelease(swapchain);

        const interop_device = interop.open_device(device.?) orelse return error.InteropOpenFailed;
        errdefer _ = interop.close_device(interop_device);

        var self = Presenter{
            .gl = gl,
            .interop = interop,
            .device = device.?,
            .context = context.?,
            .swapchain = swapchain,
            .interop_device = interop_device,
            .policy = core.PresentPolicy.init(width, height),
        };
        try self.createSizedResources(width, height);
        return self;
    }

    /// Find the first DXGI adapter belonging to the GL context's GPU vendor.
    /// No match → the machine has no adapter we can safely interop with
    /// (or GL runs on something exotic) → caller falls back to GDI.
    fn pickAdapter(want_vendor: u32) InitError!*anyopaque {
        const dxgi = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dxgi.dll")) orelse
            return error.FactoryUnavailable;
        const CreateFactoryFn = *const fn (*const core.Guid, *?*anyopaque) callconv(.winapi) HRESULT;
        const create_factory: CreateFactoryFn = @ptrCast(GetProcAddress(dxgi, "CreateDXGIFactory1") orelse
            return error.FactoryUnavailable);

        var factory: ?*anyopaque = null;
        if (create_factory(&core.IID_IDXGIFactory1, &factory) < 0 or factory == null)
            return error.FactoryUnavailable;
        defer comRelease(factory.?);

        const enum_adapters = comCall(factory.?, core.slot.DXGIFactory1_EnumAdapters1, *const fn (*anyopaque, u32, *?*anyopaque) callconv(.winapi) HRESULT);
        var index: u32 = 0;
        while (index < 16) : (index += 1) {
            var adapter: ?*anyopaque = null;
            if (enum_adapters(factory.?, index, &adapter) < 0 or adapter == null) break;
            const get_desc = comCall(adapter.?, core.slot.DXGIAdapter1_GetDesc1, *const fn (*anyopaque, *core.DXGI_ADAPTER_DESC1) callconv(.winapi) HRESULT);
            var desc: core.DXGI_ADAPTER_DESC1 = undefined;
            if (get_desc(adapter.?, &desc) >= 0 and
                core.adapterUsableForVendor(desc.vendor_id, desc.flags, want_vendor))
            {
                render_diagnostics.log(
                    "dx-present adapter {}: vendor=0x{x} device=0x{x} (GL vendor match)",
                    .{ index, desc.vendor_id, desc.device_id },
                );
                return adapter.?;
            }
            comRelease(adapter.?);
        }
        return error.AdapterVendorMismatch;
    }

    fn createSwapchain(device: *anyopaque, hwnd: HWND, width: i32, height: i32) InitError!*anyopaque {
        const dxgi_device = comQueryInterface(device, &core.IID_IDXGIDevice) orelse
            return error.FactoryUnavailable;
        defer comRelease(dxgi_device);

        const get_adapter = comCall(dxgi_device, core.slot.DXGIDevice_GetAdapter, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        var adapter: ?*anyopaque = null;
        if (get_adapter(dxgi_device, &adapter) < 0 or adapter == null) return error.FactoryUnavailable;
        defer comRelease(adapter.?);

        const get_parent = comCall(adapter.?, core.slot.DXGIObject_GetParent, *const fn (*anyopaque, *const core.Guid, *?*anyopaque) callconv(.winapi) HRESULT);
        var factory: ?*anyopaque = null;
        if (get_parent(adapter.?, &core.IID_IDXGIFactory2, &factory) < 0 or factory == null)
            return error.FactoryUnavailable;
        defer comRelease(factory.?);

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
        const create_for_hwnd = comCall(factory.?, core.slot.DXGIFactory2_CreateSwapChainForHwnd, *const fn (
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

        // DXGI grabs Alt+Enter for exclusive fullscreen by default; the app
        // has its own borderless-fullscreen handling.
        const make_assoc = comCall(factory.?, core.slot.DXGIFactory_MakeWindowAssociation, *const fn (*anyopaque, HWND, u32) callconv(.winapi) HRESULT);
        _ = make_assoc(factory.?, hwnd, DXGI_MWA_NO_ALT_ENTER);

        return swapchain.?;
    }

    /// Create the shared texture + interop registration + GL FBO for the
    /// current swapchain size, and cache swapchain buffer 0.
    fn createSizedResources(self: *Presenter, width: i32, height: i32) InitError!void {
        const desc = core.D3D11_TEXTURE2D_DESC{
            .width = @intCast(width),
            .height = @intCast(height),
            .mip_levels = 1,
            .array_size = 1,
            .format = core.DXGI_FORMAT_B8G8R8A8_UNORM,
            .sample_desc = .{ .count = 1, .quality = 0 },
            .usage = core.D3D11_USAGE_DEFAULT,
            .bind_flags = core.D3D11_BIND_RENDER_TARGET,
            .cpu_access_flags = 0,
            .misc_flags = core.D3D11_RESOURCE_MISC_SHARED,
        };
        const create_tex = comCall(self.device, core.slot.D3D11Device_CreateTexture2D, *const fn (*anyopaque, *const core.D3D11_TEXTURE2D_DESC, ?*const anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        var tex: ?*anyopaque = null;
        if (create_tex(self.device, &desc, null, &tex) < 0 or tex == null) return error.TextureCreateFailed;
        errdefer comRelease(tex.?);

        // WGL_NV_DX_interop2 requires the share handle to be communicated
        // before registering a DX10/11 resource.
        const dxgi_resource = comQueryInterface(tex.?, &core.IID_IDXGIResource) orelse
            return error.ShareHandleFailed;
        defer comRelease(dxgi_resource);
        const get_shared = comCall(dxgi_resource, core.slot.DXGIResource_GetSharedHandle, *const fn (*anyopaque, *?HANDLE) callconv(.winapi) HRESULT);
        var share_handle: ?HANDLE = null;
        if (get_shared(dxgi_resource, &share_handle) < 0 or share_handle == null)
            return error.ShareHandleFailed;
        if (self.interop.set_resource_share_handle(tex.?, share_handle.?) == 0)
            return error.ShareHandleFailed;

        var rbo: u32 = 0;
        self.gl.gen_renderbuffers(1, @ptrCast(&rbo));
        errdefer self.gl.delete_renderbuffers(1, @ptrCast(&rbo));

        const interop_object = self.interop.register_object(
            self.interop_device,
            tex.?,
            rbo,
            GL_RENDERBUFFER,
            WGL_ACCESS_WRITE_DISCARD_NV,
        ) orelse return error.RegisterFailed;
        errdefer _ = self.interop.unregister_object(self.interop_device, interop_object);

        var fbo: u32 = 0;
        self.gl.gen_framebuffers(1, @ptrCast(&fbo));
        errdefer self.gl.delete_framebuffers(1, @ptrCast(&fbo));

        // Attachment + completeness check require the interop object locked.
        var lock_handle = [1]HANDLE{interop_object};
        if (self.interop.lock_objects(self.interop_device, 1, &lock_handle) == 0)
            return error.LockFailed;
        self.gl.bind_framebuffer(GL_FRAMEBUFFER, fbo);
        self.gl.framebuffer_renderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rbo);
        const status = self.gl.check_framebuffer_status(GL_FRAMEBUFFER);
        self.gl.bind_framebuffer(GL_FRAMEBUFFER, 0);
        _ = self.interop.unlock_objects(self.interop_device, 1, &lock_handle);
        if (status != GL_FRAMEBUFFER_COMPLETE) return error.FramebufferIncomplete;

        const get_buffer = comCall(self.swapchain, core.slot.DXGISwapChain_GetBuffer, *const fn (*anyopaque, u32, *const core.Guid, *?*anyopaque) callconv(.winapi) HRESULT);
        var backbuffer: ?*anyopaque = null;
        if (get_buffer(self.swapchain, 0, &core.IID_ID3D11Texture2D, &backbuffer) < 0 or backbuffer == null)
            return error.BackbufferUnavailable;

        self.shared_tex = tex;
        self.interop_object = interop_object;
        self.gl_fbo = fbo;
        self.gl_rbo = rbo;
        self.backbuffer = backbuffer;
    }

    fn destroySizedResources(self: *Presenter) void {
        if (self.probe_staging) |s| {
            comRelease(s);
            self.probe_staging = null;
        }
        if (self.backbuffer) |b| {
            comRelease(b);
            self.backbuffer = null;
        }
        if (self.interop_object) |obj| {
            _ = self.interop.unregister_object(self.interop_device, obj);
            self.interop_object = null;
        }
        if (self.gl_fbo != 0) {
            self.gl.delete_framebuffers(1, @ptrCast(&self.gl_fbo));
            self.gl_fbo = 0;
        }
        if (self.gl_rbo != 0) {
            self.gl.delete_renderbuffers(1, @ptrCast(&self.gl_rbo));
            self.gl_rbo = 0;
        }
        if (self.shared_tex) |t| {
            comRelease(t);
            self.shared_tex = null;
        }
    }

    fn resize(self: *Presenter, width: i32, height: i32) InitError!void {
        // ResizeBuffers fails while buffer references are outstanding.
        self.destroySizedResources();
        const resize_buffers = comCall(self.swapchain, core.slot.DXGISwapChain_ResizeBuffers, *const fn (*anyopaque, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT);
        if (resize_buffers(self.swapchain, 0, @intCast(width), @intCast(height), 0, 0) < 0)
            return error.SwapchainCreateFailed;
        try self.createSizedResources(width, height);
        self.policy.noteResized(width, height);
        render_diagnostics.log("dx-present resized swapchain to {}x{}", .{ width, height });
    }

    /// Blit the rendered frame (GL FBO 0) into the swapchain and present.
    /// Returns false once the presenter has failed; the caller must revert to
    /// GDI SwapBuffers for the rest of the session.
    pub fn presentFrame(self: *Presenter, width: i32, height: i32, interval: i32) bool {
        switch (self.policy.frameAction(width, height)) {
            .fallback => return false,
            .skip => return true,
            .resize_then_present => self.resize(width, height) catch |err| {
                self.policy.fail();
                render_diagnostics.log("dx-present resize failed: {s}", .{@errorName(err)});
                return false;
            },
            .present => {},
        }
        const start_ms = std.time.milliTimestamp();
        self.blitAndPresent(width, height, interval) catch |err| {
            self.policy.fail();
            render_diagnostics.log("dx-present present failed: {s}", .{@errorName(err)});
            return false;
        };
        const elapsed_ms: u64 = @intCast(@max(std.time.milliTimestamp() - start_ms, 0));

        // The dangerous failure modes here never return an error: a broken
        // interop path happily "presents" frames GL never wrote (hybrid-GPU
        // share bugs, driver-forced MSAA making the Y-flip blit an illegal
        // no-op) or takes seconds per frame (cross-GPU syncs, TDR loops).
        // Two watchers convert those into the latched GDI fallback.
        if (!self.probe_done) {
            self.probeStep(width, height) catch |err| {
                self.policy.fail();
                render_diagnostics.log("dx-present probe failed: {s} — frames are not reaching the swapchain", .{@errorName(err)});
                return false;
            };
        }
        if (self.policy.notePresentMillis(elapsed_ms)) {
            render_diagnostics.log(
                "dx-present watchdog: {} consecutive presents over {}ms (last {}ms)",
                .{ core.PresentPolicy.slow_latch_frames, core.PresentPolicy.slow_frame_ms, elapsed_ms },
            );
            // This frame did reach the screen; the latch takes effect on the
            // next call via frameAction → .fallback.
        }
        return true;
    }

    fn blitAndPresent(self: *Presenter, width: i32, height: i32, interval: i32) PresentError!void {
        var lock_handle = [1]HANDLE{self.interop_object.?};
        if (self.interop.lock_objects(self.interop_device, 1, &lock_handle) == 0)
            return error.LockFailed;

        // Scissor clips glBlitFramebuffer; the frame's present prep disables
        // it, but the presenter must not depend on renderer state.
        self.gl.disable(GL_SCISSOR_TEST);
        self.gl.bind_framebuffer(GL_READ_FRAMEBUFFER, 0);
        self.gl.bind_framebuffer(GL_DRAW_FRAMEBUFFER, self.gl_fbo);
        // Y-flip: GL FBO 0 rows are bottom-up, the D3D texture is top-down.
        self.gl.blit_framebuffer(0, 0, width, height, 0, height, width, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        // Leave FBO 0 bound so the renderer's next frame is unaffected.
        self.gl.bind_framebuffer(GL_FRAMEBUFFER, 0);

        _ = self.interop.unlock_objects(self.interop_device, 1, &lock_handle);

        const copy_resource = comCall(self.context, core.slot.D3D11DeviceContext_CopyResource, *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.winapi) void);
        copy_resource(self.context, self.backbuffer.?, self.shared_tex.?);

        const present = comCall(self.swapchain, core.slot.DXGISwapChain_Present, *const fn (*anyopaque, u32, u32) callconv(.winapi) HRESULT);
        const interval_u: u32 = if (interval > 0) 1 else 0;
        if (present(self.swapchain, interval_u, 0) < 0) return error.PresentFailed;
    }

    /// Verify the present path actually carries pixels: read the same sample
    /// points back from GL FBO 0 and from the D3D shared texture and compare.
    /// Runs after each present until a frame with real content matches
    /// (`probe_done`), erroring out the moment any sample disagrees. Bounded
    /// by `probe_max_frames` so the Map() sync cost doesn't run forever.
    fn probeStep(self: *Presenter, width: i32, height: i32) PresentError!void {
        self.probe_frames += 1;
        if (self.probe_frames > core.probe_max_frames) {
            self.settleProbe(true);
            return;
        }
        if (width < 8 or height < 8) return;

        // Informational only: renderer code may legitimately leave a stale
        // error queued, so a GL error must not fail the probe by itself —
        // but it's the smoking gun for the forced-MSAA illegal-blit case.
        const gl_err = self.gl.get_error();
        if (gl_err != 0)
            render_diagnostics.log("dx-present probe: GL error 0x{x} pending after blit", .{gl_err});

        if (self.probe_staging == null) try self.createProbeStaging(width, height);
        const staging = self.probe_staging.?;

        const copy_resource = comCall(self.context, core.slot.D3D11DeviceContext_CopyResource, *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.winapi) void);
        copy_resource(self.context, staging, self.shared_tex.?);

        const map = comCall(self.context, core.slot.D3D11DeviceContext_Map, *const fn (*anyopaque, *anyopaque, u32, u32, u32, *core.D3D11_MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT);
        const unmap = comCall(self.context, core.slot.D3D11DeviceContext_Unmap, *const fn (*anyopaque, *anyopaque, u32) callconv(.winapi) void);
        var mapped: core.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (map(self.context, staging, 0, core.D3D11_MAP_READ, 0, &mapped) < 0 or mapped.p_data == null)
            return error.ProbeReadbackFailed;
        defer unmap(self.context, staging, 0);
        const dx_bytes: [*]const u8 = @ptrCast(mapped.p_data.?);

        // 3×3 grid; corners-ish + center so titlebar/background/content areas
        // are all represented.
        var gl_rgb: [9][3]u8 = undefined;
        var dx_rgb: [9][3]u8 = undefined;
        var i: usize = 0;
        for ([3]i32{ @divTrunc(height, 4), @divTrunc(height, 2), @divTrunc(height * 3, 4) }) |y| {
            for ([3]i32{ @divTrunc(width, 4), @divTrunc(width, 2), @divTrunc(width * 3, 4) }) |x| {
                var px: [4]u8 = undefined; // RGBA from GL
                // The shared texture holds the Y-flipped (top-down) image;
                // FBO 0 is bottom-up, so sample its mirrored row.
                self.gl.read_pixels(x, height - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px);
                gl_rgb[i] = .{ px[0], px[1], px[2] };
                const row_offset: usize = @as(usize, @intCast(y)) * mapped.row_pitch;
                const dx_px = dx_bytes[row_offset + @as(usize, @intCast(x)) * 4 ..][0..4]; // BGRA
                dx_rgb[i] = .{ dx_px[2], dx_px[1], dx_px[0] };
                i += 1;
            }
        }

        switch (core.evaluateProbe(&gl_rgb, &dx_rgb)) {
            .mismatched => return error.ProbeMismatch,
            .matched_uniform => {}, // keep probing until a frame has content
            .matched_content => self.settleProbe(false),
        }
    }

    fn settleProbe(self: *Presenter, gave_up: bool) void {
        self.probe_done = true;
        if (self.probe_staging) |s| {
            comRelease(s);
            self.probe_staging = null;
        }
        if (gave_up)
            render_diagnostics.log("dx-present probe: no content frame within {} frames — accepting path, watchdog stays armed", .{core.probe_max_frames})
        else
            render_diagnostics.log("dx-present probe passed: swapchain verifiably carries GL content", .{});
    }

    fn createProbeStaging(self: *Presenter, width: i32, height: i32) PresentError!void {
        const desc = core.D3D11_TEXTURE2D_DESC{
            .width = @intCast(width),
            .height = @intCast(height),
            .mip_levels = 1,
            .array_size = 1,
            .format = core.DXGI_FORMAT_B8G8R8A8_UNORM,
            .sample_desc = .{ .count = 1, .quality = 0 },
            .usage = core.D3D11_USAGE_STAGING,
            .bind_flags = 0,
            .cpu_access_flags = core.D3D11_CPU_ACCESS_READ,
            .misc_flags = 0,
        };
        const create_tex = comCall(self.device, core.slot.D3D11Device_CreateTexture2D, *const fn (*anyopaque, *const core.D3D11_TEXTURE2D_DESC, ?*const anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        var tex: ?*anyopaque = null;
        if (create_tex(self.device, &desc, null, &tex) < 0 or tex == null)
            return error.ProbeReadbackFailed;
        self.probe_staging = tex;
    }

    /// Requires the GL context to still be current (interop teardown).
    pub fn deinit(self: *Presenter) void {
        self.destroySizedResources();
        _ = self.interop.close_device(self.interop_device);
        comRelease(self.swapchain);
        comRelease(self.context);
        comRelease(self.device);
    }
};
