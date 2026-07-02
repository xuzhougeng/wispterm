//! Pure, host-independent core for the Windows DXGI flip-model presenter
//! (`apprt/win32_dx_present.zig`): COM GUID parsing, the few D3D11/DXGI ABI
//! structs the presenter passes across the COM boundary, and the
//! `PresentPolicy` state machine that decides per frame whether to present,
//! resize the swapchain first, skip (degenerate size), or fall back to the
//! legacy GDI `SwapBuffers` path after a latched failure.
//!
//! Everything here is plain data + logic so the fast suite can verify the
//! ABI layouts and the policy on any host; the COM/WGL runtime lives in the
//! win32-only presenter.

const std = @import("std");

// ============================================================================
// COM GUIDs
// ============================================================================

/// Windows GUID with the COM in-memory layout: the first three fields are
/// little-endian integers, `data4` is verbatim bytes.
pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// Parse a canonical GUID string ("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
/// at comptime, so interface IDs are declared in the same form the registry
/// and headers document them.
pub fn guid(comptime s: *const [36]u8) Guid {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-')
            @compileError("GUID string must use 8-4-4-4-12 grouping: " ++ s);
        var data4: [8]u8 = undefined;
        data4[0] = hexByte(s[19..21]);
        data4[1] = hexByte(s[21..23]);
        for (0..6) |i| data4[2 + i] = hexByte(s[24 + i * 2 ..][0..2]);
        break :blk .{
            .data1 = std.fmt.parseInt(u32, s[0..8], 16) catch @compileError("bad GUID hex: " ++ s),
            .data2 = std.fmt.parseInt(u16, s[9..13], 16) catch @compileError("bad GUID hex: " ++ s),
            .data3 = std.fmt.parseInt(u16, s[14..18], 16) catch @compileError("bad GUID hex: " ++ s),
            .data4 = data4,
        };
    };
}

fn hexByte(comptime pair: *const [2]u8) u8 {
    return std.fmt.parseInt(u8, pair, 16) catch @compileError("bad GUID hex byte");
}

// Interface IDs the presenter queries.
pub const IID_IDXGIDevice = guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
pub const IID_IDXGIFactory1 = guid("770aae78-f26f-4dba-a829-253c83d1b387");
pub const IID_IDXGIFactory2 = guid("50c83a1c-e072-4c48-87b0-3630fa36a6d0");
pub const IID_IDXGIResource = guid("035f3ab4-482e-4e50-b41f-8a7f8bd8960b");
pub const IID_ID3D11Texture2D = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

// ============================================================================
// D3D11 / DXGI ABI structs and constants
// ============================================================================

pub const DXGI_SAMPLE_DESC = extern struct {
    count: u32,
    quality: u32,
};

/// dxgi1_2.h DXGI_SWAP_CHAIN_DESC1 (BOOL stereo declared as u32).
pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    width: u32,
    height: u32,
    format: u32,
    stereo: u32,
    sample_desc: DXGI_SAMPLE_DESC,
    buffer_usage: u32,
    buffer_count: u32,
    scaling: u32,
    swap_effect: u32,
    alpha_mode: u32,
    flags: u32,
};

/// d3d11.h D3D11_TEXTURE2D_DESC.
pub const D3D11_TEXTURE2D_DESC = extern struct {
    width: u32,
    height: u32,
    mip_levels: u32,
    array_size: u32,
    format: u32,
    sample_desc: DXGI_SAMPLE_DESC,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
};

/// dxgi.h LUID (8 bytes, two-int layout).
pub const LUID = extern struct {
    low_part: u32,
    high_part: i32,
};

/// dxgi1_2.h DXGI_ADAPTER_DESC1. `dedicated_*`/`shared_*` are SIZE_T, so the
/// layout test below pins the 64-bit shape the presenter actually runs on.
pub const DXGI_ADAPTER_DESC1 = extern struct {
    description: [128]u16,
    vendor_id: u32,
    device_id: u32,
    sub_sys_id: u32,
    revision: u32,
    dedicated_video_memory: usize,
    dedicated_system_memory: usize,
    shared_system_memory: usize,
    adapter_luid: LUID,
    flags: u32,
};

/// d3d11.h D3D11_MAPPED_SUBRESOURCE.
pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    p_data: ?*anyopaque,
    row_pitch: u32,
    depth_pitch: u32,
};

/// d3d11.h D3D11_BOX.
pub const D3D11_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

/// windef.h RECT / D3D11_RECT.
pub const D3D11_RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// d3d11.h D3D11_INPUT_ELEMENT_DESC.
pub const D3D11_INPUT_ELEMENT_DESC = extern struct {
    semantic_name: [*:0]const u8,
    semantic_index: u32,
    format: u32,
    input_slot: u32,
    aligned_byte_offset: u32,
    input_slot_class: u32,
    instance_data_step_rate: u32,
};

/// d3d11.h D3D11_SAMPLER_DESC.
pub const D3D11_SAMPLER_DESC = extern struct {
    filter: u32,
    address_u: u32,
    address_v: u32,
    address_w: u32,
    mip_lod_bias: f32,
    max_anisotropy: u32,
    comparison_func: u32,
    border_color: [4]f32,
    min_lod: f32,
    max_lod: f32,
};

/// d3d11.h D3D11_RENDER_TARGET_BLEND_DESC.
pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    blend_enable: u32,
    src_blend: u32,
    dest_blend: u32,
    blend_op: u32,
    src_blend_alpha: u32,
    dest_blend_alpha: u32,
    blend_op_alpha: u32,
    render_target_write_mask: u8,
};

/// d3d11.h D3D11_BLEND_DESC.
pub const D3D11_BLEND_DESC = extern struct {
    alpha_to_coverage_enable: u32,
    independent_blend_enable: u32,
    render_target: [8]D3D11_RENDER_TARGET_BLEND_DESC,
};

/// d3d11.h D3D11_RASTERIZER_DESC.
pub const D3D11_RASTERIZER_DESC = extern struct {
    fill_mode: u32,
    cull_mode: u32,
    front_counter_clockwise: u32,
    depth_bias: i32,
    depth_bias_clamp: f32,
    slope_scaled_depth_bias: f32,
    depth_clip_enable: u32,
    scissor_enable: u32,
    multisample_enable: u32,
    antialiased_line_enable: u32,
};

pub const HRESULT = i32;

pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
pub const DXGI_FORMAT_R32G32B32A32_FLOAT: u32 = 2;
pub const DXGI_FORMAT_R32G32B32_FLOAT: u32 = 6;
pub const DXGI_FORMAT_R32G32_FLOAT: u32 = 16;
pub const DXGI_FORMAT_R32_FLOAT: u32 = 41;
pub const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
pub const DXGI_FORMAT_R8_UNORM: u32 = 61;
pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SCALING_NONE: u32 = 1;
pub const DXGI_SCALING_STRETCH: u32 = 0;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;
pub const DXGI_ALPHA_MODE_IGNORE: u32 = 3;
pub const DXGI_ADAPTER_FLAG_SOFTWARE: u32 = 2;

pub const D3D_DRIVER_TYPE_UNKNOWN: u32 = 0;
pub const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
pub const D3D11_SDK_VERSION: u32 = 7;
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
pub const D3D11_USAGE_DEFAULT: u32 = 0;
pub const D3D11_USAGE_STAGING: u32 = 3;
pub const D3D11_USAGE_DYNAMIC: u32 = 2;
pub const D3D11_BIND_VERTEX_BUFFER: u32 = 0x1;
pub const D3D11_BIND_INDEX_BUFFER: u32 = 0x2;
pub const D3D11_BIND_CONSTANT_BUFFER: u32 = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: u32 = 0x8;
pub const D3D11_BIND_RENDER_TARGET: u32 = 0x20;
pub const D3D11_CPU_ACCESS_WRITE: u32 = 0x10000;
pub const D3D11_CPU_ACCESS_READ: u32 = 0x20000;
pub const D3D11_RESOURCE_MISC_SHARED: u32 = 0x2;
pub const D3D11_MAP_READ: u32 = 1;
pub const D3D11_MAP_WRITE_DISCARD: u32 = 4;
pub const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST: u32 = 4;
pub const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: u32 = 5;
pub const D3D11_INPUT_PER_VERTEX_DATA: u32 = 0;
pub const D3D11_INPUT_PER_INSTANCE_DATA: u32 = 1;
pub const D3D11_FILTER_MIN_MAG_MIP_POINT: u32 = 0x00;
pub const D3D11_FILTER_MIN_MAG_MIP_LINEAR: u32 = 0x15;
pub const D3D11_TEXTURE_ADDRESS_WRAP: u32 = 1;
pub const D3D11_TEXTURE_ADDRESS_CLAMP: u32 = 3;
pub const D3D11_COMPARISON_NEVER: u32 = 1;
pub const D3D11_FLOAT32_MAX: f32 = 3.4028234663852886e38;
pub const D3D11_BLEND_ZERO: u32 = 1;
pub const D3D11_BLEND_ONE: u32 = 2;
pub const D3D11_BLEND_SRC_ALPHA: u32 = 5;
pub const D3D11_BLEND_INV_SRC_ALPHA: u32 = 6;
pub const D3D11_BLEND_OP_ADD: u32 = 1;
pub const D3D11_COLOR_WRITE_ENABLE_ALL: u8 = 0x0F;
pub const D3D11_FILL_SOLID: u32 = 3;
pub const D3D11_CULL_NONE: u32 = 1;

pub const D3D11_BUFFER_DESC = extern struct {
    byte_width: u32,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
    structure_byte_stride: u32,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    sys_mem: ?*const anyopaque,
    sys_mem_pitch: u32,
    sys_mem_slice_pitch: u32,
};

pub const D3D11_VIEWPORT = extern struct {
    top_left_x: f32,
    top_left_y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

// PCI vendor IDs, for matching the GL context's GPU to a DXGI adapter.
pub const PCI_VENDOR_NVIDIA: u32 = 0x10DE;
pub const PCI_VENDOR_INTEL: u32 = 0x8086;
pub const PCI_VENDOR_AMD: u32 = 0x1002;
pub const PCI_VENDOR_MICROSOFT: u32 = 0x1414; // WARP / Basic Render

/// Map `glGetString(GL_VENDOR)` to the PCI vendor id of the GPU the GL
/// context runs on. WGL_NV_DX_interop2 sharing is only defined when the D3D11
/// device lives on the *same* adapter as the GL context; on hybrid-GPU
/// laptops `D3D11CreateDevice(adapter=null)` picks the default adapter, which
/// is frequently the *other* GPU — drivers then either stall every frame on
/// cross-GPU syncs or "succeed" while presenting frames GL never wrote
/// (the v1.18.0 black-screen/slideshow reports). Returns null for vendors
/// with no reliable interop story (e.g. ARM GL emulation) — callers must
/// fall back to GDI rather than guess.
pub fn pciVendorForGlVendor(gl_vendor: []const u8) ?u32 {
    var lower_buf: [64]u8 = undefined;
    if (gl_vendor.len == 0 or gl_vendor.len > lower_buf.len) return null;
    const lower = std.ascii.lowerString(&lower_buf, gl_vendor);
    if (std.mem.indexOf(u8, lower, "nvidia") != null) return PCI_VENDOR_NVIDIA;
    if (std.mem.indexOf(u8, lower, "intel") != null) return PCI_VENDOR_INTEL;
    if (std.mem.indexOf(u8, lower, "amd") != null) return PCI_VENDOR_AMD;
    if (std.mem.indexOf(u8, lower, "ati ") != null or
        std.mem.startsWith(u8, lower, "ati")) return PCI_VENDOR_AMD;
    if (std.mem.indexOf(u8, lower, "microsoft") != null) return PCI_VENDOR_MICROSOFT;
    return null;
}

/// Whether a DXGI adapter is an acceptable home for the presenter's D3D11
/// device given the GL context's vendor. Software adapters (WARP) only match
/// when GL itself is software-rendered.
pub fn adapterUsableForVendor(desc_vendor_id: u32, desc_flags: u32, want_vendor: u32) bool {
    if ((desc_flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0 and want_vendor != PCI_VENDOR_MICROSOFT)
        return false;
    return desc_vendor_id == want_vendor;
}

// ============================================================================
// COM vtable slots
// ============================================================================
//
// The presenter dispatches COM calls by vtable slot index instead of declaring
// full interface vtables; only the slots below are used. Indices follow the
// header declaration order, offset by the inherited interfaces
// (IUnknown = slots 0..2; IDXGIObject adds 4; IDXGIDeviceSubObject adds 1;
// ID3D11DeviceChild adds 4).

pub const slot = struct {
    // IUnknown
    pub const QueryInterface: usize = 0;
    pub const Release: usize = 2;

    // ID3D11Device (derives IUnknown directly)
    pub const D3D11Device_CreateBuffer: usize = 3;
    pub const D3D11Device_CreateTexture2D: usize = 5;
    pub const D3D11Device_CreateShaderResourceView: usize = 7;
    pub const D3D11Device_CreateRenderTargetView: usize = 9;
    pub const D3D11Device_CreateInputLayout: usize = 11;
    pub const D3D11Device_CreateVertexShader: usize = 12;
    pub const D3D11Device_CreatePixelShader: usize = 15;
    pub const D3D11Device_CreateBlendState: usize = 20;
    pub const D3D11Device_CreateRasterizerState: usize = 22;
    pub const D3D11Device_CreateSamplerState: usize = 23;

    // ID3D11DeviceContext (IUnknown + ID3D11DeviceChild(4) → first own slot 7:
    // VSSetConstantBuffers(7) … Draw(13) Map(14) Unmap(15) … CopyResource(47))
    pub const D3D11DeviceContext_VSSetConstantBuffers: usize = 7;
    pub const D3D11DeviceContext_PSSetShaderResources: usize = 8;
    pub const D3D11DeviceContext_PSSetShader: usize = 9;
    pub const D3D11DeviceContext_PSSetSamplers: usize = 10;
    pub const D3D11DeviceContext_VSSetShader: usize = 11;
    pub const D3D11DeviceContext_Draw: usize = 13;
    pub const D3D11DeviceContext_Map: usize = 14;
    pub const D3D11DeviceContext_Unmap: usize = 15;
    pub const D3D11DeviceContext_PSSetConstantBuffers: usize = 16;
    pub const D3D11DeviceContext_IASetInputLayout: usize = 17;
    pub const D3D11DeviceContext_IASetVertexBuffers: usize = 18;
    pub const D3D11DeviceContext_DrawInstanced: usize = 21;
    pub const D3D11DeviceContext_IASetPrimitiveTopology: usize = 24;
    pub const D3D11DeviceContext_OMSetRenderTargets: usize = 33;
    pub const D3D11DeviceContext_OMSetBlendState: usize = 35;
    pub const D3D11DeviceContext_RSSetState: usize = 43;
    pub const D3D11DeviceContext_RSSetViewports: usize = 44;
    pub const D3D11DeviceContext_RSSetScissorRects: usize = 45;
    pub const D3D11DeviceContext_CopySubresourceRegion: usize = 46;
    pub const D3D11DeviceContext_CopyResource: usize = 47;
    pub const D3D11DeviceContext_UpdateSubresource: usize = 48;
    pub const D3D11DeviceContext_ClearRenderTargetView: usize = 50;

    // ID3DBlob (IUnknown + GetBufferPointer/GetBufferSize).
    pub const Blob_GetBufferPointer: usize = 3;
    pub const Blob_GetBufferSize: usize = 4;

    // IDXGIObject: SetPrivateData(3) SetPrivateDataInterface(4)
    // GetPrivateData(5) GetParent(6)
    pub const DXGIObject_GetParent: usize = 6;

    // IDXGIDevice (IDXGIObject + GetAdapter first)
    pub const DXGIDevice_GetAdapter: usize = 7;

    // IDXGIFactory (IDXGIObject + EnumAdapters(7) MakeWindowAssociation(8) …)
    pub const DXGIFactory_MakeWindowAssociation: usize = 8;

    // IDXGIFactory1 (IDXGIObject + IDXGIFactory(5) → EnumAdapters1(12))
    pub const DXGIFactory1_EnumAdapters1: usize = 12;

    // IDXGIFactory2 (IDXGIObject + IDXGIFactory(5) + IDXGIFactory1(2) →
    // IsWindowedStereoEnabled(14), CreateSwapChainForHwnd(15))
    pub const DXGIFactory2_CreateSwapChainForHwnd: usize = 15;

    // IDXGIAdapter1 (IDXGIObject + EnumOutputs(7) GetDesc(8)
    // CheckInterfaceSupport(9) → GetDesc1(10))
    pub const DXGIAdapter1_GetDesc1: usize = 10;

    // IDXGIDeviceSubObject: GetDevice(7)
    // IDXGISwapChain: Present(8) GetBuffer(9) SetFullscreenState(10)
    // GetFullscreenState(11) GetDesc(12) ResizeBuffers(13)
    pub const DXGISwapChain_Present: usize = 8;
    pub const DXGISwapChain_GetBuffer: usize = 9;
    pub const DXGISwapChain_ResizeBuffers: usize = 13;

    // IDXGIResource (IDXGIDeviceSubObject + GetSharedHandle first)
    pub const DXGIResource_GetSharedHandle: usize = 8;
};

// ============================================================================
// COM dispatch helpers
// ============================================================================

pub fn vtable(obj: *anyopaque) [*]const *const anyopaque {
    const pp: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return pp.*;
}

pub fn comCall(obj: *anyopaque, comptime slot_index: usize, comptime Fn: type) Fn {
    return @ptrCast(vtable(obj)[slot_index]);
}

pub fn comRelease(obj: *anyopaque) void {
    const f = comCall(obj, slot.Release, *const fn (*anyopaque) callconv(.winapi) u32);
    _ = f(obj);
}

pub fn comQueryInterface(obj: *anyopaque, iid: *const Guid) ?*anyopaque {
    const f = comCall(obj, slot.QueryInterface, *const fn (*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT);
    var out: ?*anyopaque = null;
    if (f(obj, iid, &out) < 0) return null;
    return out;
}

// ============================================================================
// PresentPolicy
// ============================================================================

/// Per-frame decision for the flip-model presenter. Pure so the
/// resize/skip/fallback transitions are unit-testable off-Windows.
pub const PresentPolicy = struct {
    pub const Action = enum { skip, present, resize_then_present, fallback };

    /// Watchdog: a present this slow is a stalled interop sync / TDR loop,
    /// not vsync (16ms) or a scheduler hiccup.
    pub const slow_frame_ms: u64 = 400;
    /// Consecutive slow presents before latching fallback. High enough that a
    /// burst of post-resume / driver-recovery frames doesn't trip it.
    pub const slow_latch_frames: u32 = 5;

    width: i32,
    height: i32,
    failed: bool = false,
    slow_streak: u32 = 0,
    slow_reported: bool = false,

    pub fn init(width: i32, height: i32) PresentPolicy {
        return .{ .width = width, .height = height };
    }

    pub fn frameAction(self: *const PresentPolicy, width: i32, height: i32) Action {
        if (self.failed) return .fallback;
        if (width <= 0 or height <= 0) return .skip;
        if (width != self.width or height != self.height) return .resize_then_present;
        return .present;
    }

    /// Commit a successful swapchain resize. frameAction never records sizes
    /// itself because ResizeBuffers can fail mid-flight.
    pub fn noteResized(self: *PresentPolicy, width: i32, height: i32) void {
        self.width = width;
        self.height = height;
    }

    /// Watchdog feed: duration of a *successful* present. A broken interop
    /// path can stall for seconds per frame without ever returning an error
    /// (cross-GPU syncs, TDR recovery loops) — the only externally visible
    /// signal is time. Returns true exactly once, on the `slow_latch_frames`th
    /// consecutive slow present.
    ///
    /// Sustained slowness must NOT switch the present path mid-session: the
    /// frames *are* reaching the screen (unlike a probe mismatch), and an
    /// HWND that has presented through a flip-model swapchain cannot revert
    /// to GDI/blt presents — DWM behavior is undefined and in the field that
    /// "fallback" rendered the window black. The caller persists a marker so
    /// the *next* launch uses GDI from frame 0 instead.
    pub fn notePresentMillis(self: *PresentPolicy, ms: u64) bool {
        if (self.failed or self.slow_reported) return false;
        if (ms < slow_frame_ms) {
            self.slow_streak = 0;
            return false;
        }
        self.slow_streak += 1;
        if (self.slow_streak < slow_latch_frames) return false;
        self.slow_reported = true;
        return true;
    }

    /// Latch the fallback path for the rest of the session — a presenter that
    /// failed once must not flap between DXGI and GDI presents.
    pub fn fail(self: *PresentPolicy) void {
        self.failed = true;
    }
};

// ============================================================================
// First-frames content probe
// ============================================================================

/// Stop probing after this many presented frames without a verdict: the cost
/// of the staging-readback sync isn't worth carrying forever, and the
/// watchdog still covers late-onset stalls.
pub const probe_max_frames: u32 = 120;

pub const ProbeVerdict = enum {
    /// A sampled pixel differs between what GL rendered and what reached the
    /// swapchain: the interop path is silently dropping/corrupting frames.
    mismatched,
    /// Samples agree but the GL frame was a single flat color — consistent
    /// with a broken path that happens to show the same flat color (e.g.
    /// black-on-black), so not yet proof the path works.
    matched_uniform,
    /// Samples agree on a frame with real content: the path verifiably
    /// carries pixels end-to-end.
    matched_content,
};

/// Per-channel slack for the GL↔DX comparison. The blit + CopyResource chain
/// is bit-exact for an RGBA8 backbuffer, but drivers can hand the window a
/// deeper default framebuffer (10bpc pipelines) or dither it, and then the
/// readback→u8 and blit→8bit conversions round independently — off-by-a-LSB
/// differences on a perfectly working path. A real failure (content rendered,
/// black presented) differs by whole channel ranges, far beyond this.
pub const probe_channel_tolerance: u8 = 2;

/// Compare per-sample RGB read back from the GL framebuffer against the same
/// points read back from the D3D shared texture (callers handle the Y-flip
/// and BGRA→RGB swizzle when sampling). Any sample differing beyond
/// `probe_channel_tolerance` means pixels are not reaching the swapchain even
/// though every API call "succeeded".
pub fn evaluateProbe(gl_rgb: []const [3]u8, dx_rgb: []const [3]u8) ProbeVerdict {
    std.debug.assert(gl_rgb.len == dx_rgb.len and gl_rgb.len > 0);
    for (gl_rgb, dx_rgb) |g, d| {
        for (g, d) |gc, dc| {
            if (@abs(@as(i16, gc) - @as(i16, dc)) > probe_channel_tolerance)
                return .mismatched;
        }
    }
    for (gl_rgb[1..]) |g| {
        if (g[0] != gl_rgb[0][0] or g[1] != gl_rgb[0][1] or g[2] != gl_rgb[0][2])
            return .matched_content;
    }
    return .matched_uniform;
}

// ============================================================================
// Bring-up crash fuse
// ============================================================================
//
// Presenter init + the first present run driver code (wglDX*NV, D3D11) that
// on broken ICDs can crash the process outright instead of returning an
// error — the "v1.18 won't open" reports. The fuse is a state-file marker
// written before the first window is created and removed after the first
// successful present: a leftover "probing:<version>" marker on the next
// launch means the last bring-up died mid-flight, so that app version stops
// trying D3D on this machine ("blocked:<version>"). A new app version
// retries once.

pub const bringup_probing_prefix = "probing:";
pub const bringup_blocked_prefix = "blocked:";
/// Marker = prefix + version; sized for window_state_codec's version cap.
pub const bringup_marker_max_len: usize = 32;

pub const BringupFuse = enum { attempt, blocked };

pub fn bringupProbingMarker(buf: []u8, version: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, bringup_probing_prefix ++ "{s}", .{version});
}

pub fn bringupBlockedMarker(buf: []u8, version: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, bringup_blocked_prefix ++ "{s}", .{version});
}

pub fn bringupMarkerIsProbing(stored: []const u8) bool {
    return std.mem.startsWith(u8, stored, bringup_probing_prefix);
}

/// Decide whether this launch may try the D3D present path. Only markers for
/// the *current* version block: an upgrade retries once (the driver bug may
/// be fixed, ours may be), and stale markers from other versions are ignored.
pub fn bringupFuseDecision(stored: []const u8, version: []const u8) BringupFuse {
    inline for (.{ bringup_probing_prefix, bringup_blocked_prefix }) |prefix| {
        if (std.mem.startsWith(u8, stored, prefix) and
            std.mem.eql(u8, stored[prefix.len..], version)) return .blocked;
    }
    return .attempt;
}

// ============================================================================
// Tests (fast suite — registered in test_fast.zig)
// ============================================================================

test "guid parses canonical string into COM byte layout" {
    // IID_ID3D11Texture2D {6f15aaf2-d208-4e89-9ab4-489535d34f9c}
    const g = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    try std.testing.expectEqual(@as(u32, 0x6f15aaf2), g.data1);
    try std.testing.expectEqual(@as(u16, 0xd208), g.data2);
    try std.testing.expectEqual(@as(u16, 0x4e89), g.data3);
    // In-memory layout: data1/data2/data3 little-endian, data4 verbatim.
    const expected = [16]u8{
        0xf2, 0xaa, 0x15, 0x6f,
        0x08, 0xd2, 0x89, 0x4e,
        0x9a, 0xb4, 0x48, 0x95,
        0x35, 0xd3, 0x4f, 0x9c,
    };
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Guid));
    try std.testing.expectEqualSlices(u8, &expected, std.mem.asBytes(&g));
}

test "well-known interface IIDs round-trip their documented strings" {
    // Spot-check first/last bytes of each IID the presenter queries, so a
    // transposed hex pair in the declarations can't reach the COM boundary.
    try std.testing.expectEqual(@as(u32, 0x54ec77fa), IID_IDXGIDevice.data1);
    try std.testing.expectEqual(@as(u8, 0x4c), IID_IDXGIDevice.data4[7]);
    try std.testing.expectEqual(@as(u32, 0x50c83a1c), IID_IDXGIFactory2.data1);
    try std.testing.expectEqual(@as(u8, 0xd0), IID_IDXGIFactory2.data4[7]);
    try std.testing.expectEqual(@as(u32, 0x035f3ab4), IID_IDXGIResource.data1);
    try std.testing.expectEqual(@as(u8, 0x0b), IID_IDXGIResource.data4[7]);
    try std.testing.expectEqual(@as(u32, 0x6f15aaf2), IID_ID3D11Texture2D.data1);
    try std.testing.expectEqual(@as(u8, 0x9c), IID_ID3D11Texture2D.data4[7]);
}

test "DXGI_SWAP_CHAIN_DESC1 matches the documented 48-byte layout" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(DXGI_SWAP_CHAIN_DESC1));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(DXGI_SWAP_CHAIN_DESC1, "width"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(DXGI_SWAP_CHAIN_DESC1, "format"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(DXGI_SWAP_CHAIN_DESC1, "sample_desc"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(DXGI_SWAP_CHAIN_DESC1, "buffer_usage"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(DXGI_SWAP_CHAIN_DESC1, "buffer_count"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(DXGI_SWAP_CHAIN_DESC1, "swap_effect"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(DXGI_SWAP_CHAIN_DESC1, "alpha_mode"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(DXGI_SWAP_CHAIN_DESC1, "flags"));
}

test "D3D11_TEXTURE2D_DESC matches the documented 44-byte layout" {
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(D3D11_TEXTURE2D_DESC));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(D3D11_TEXTURE2D_DESC, "format"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(D3D11_TEXTURE2D_DESC, "usage"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(D3D11_TEXTURE2D_DESC, "bind_flags"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(D3D11_TEXTURE2D_DESC, "misc_flags"));
}

test "PresentPolicy presents at the established size" {
    var p = PresentPolicy.init(800, 600);
    try std.testing.expectEqual(PresentPolicy.Action.present, p.frameAction(800, 600));
}

test "PresentPolicy requests a resize when the frame size changes" {
    var p = PresentPolicy.init(800, 600);
    try std.testing.expectEqual(PresentPolicy.Action.resize_then_present, p.frameAction(1024, 768));
    // frameAction must not record the new size itself — the swapchain resize
    // can fail; only a successful resize commits it.
    try std.testing.expectEqual(PresentPolicy.Action.resize_then_present, p.frameAction(1024, 768));
    p.noteResized(1024, 768);
    try std.testing.expectEqual(PresentPolicy.Action.present, p.frameAction(1024, 768));
}

test "PresentPolicy skips degenerate sizes without failing" {
    var p = PresentPolicy.init(800, 600);
    try std.testing.expectEqual(PresentPolicy.Action.skip, p.frameAction(0, 600));
    try std.testing.expectEqual(PresentPolicy.Action.skip, p.frameAction(800, -1));
    // Still healthy afterwards.
    try std.testing.expectEqual(PresentPolicy.Action.present, p.frameAction(800, 600));
}

test "PresentPolicy latches fallback after a failure" {
    var p = PresentPolicy.init(800, 600);
    p.fail();
    try std.testing.expectEqual(PresentPolicy.Action.fallback, p.frameAction(800, 600));
    // No recovery mid-session: a flaky presenter must not flap between paths.
    p.noteResized(800, 600);
    try std.testing.expectEqual(PresentPolicy.Action.fallback, p.frameAction(800, 600));
}

test "DXGI_ADAPTER_DESC1 matches the documented 64-bit layout" {
    try std.testing.expectEqual(@as(usize, 312), @sizeOf(DXGI_ADAPTER_DESC1));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(DXGI_ADAPTER_DESC1, "description"));
    try std.testing.expectEqual(@as(usize, 256), @offsetOf(DXGI_ADAPTER_DESC1, "vendor_id"));
    try std.testing.expectEqual(@as(usize, 272), @offsetOf(DXGI_ADAPTER_DESC1, "dedicated_video_memory"));
    try std.testing.expectEqual(@as(usize, 296), @offsetOf(DXGI_ADAPTER_DESC1, "adapter_luid"));
    try std.testing.expectEqual(@as(usize, 304), @offsetOf(DXGI_ADAPTER_DESC1, "flags"));
}

test "D3D11_MAPPED_SUBRESOURCE matches the documented 64-bit layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(D3D11_MAPPED_SUBRESOURCE));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(D3D11_MAPPED_SUBRESOURCE, "row_pitch"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(D3D11_MAPPED_SUBRESOURCE, "depth_pitch"));
}

test "D3D11_BUFFER_DESC matches the documented 24-byte layout" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(D3D11_BUFFER_DESC));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(D3D11_BUFFER_DESC, "byte_width"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(D3D11_BUFFER_DESC, "usage"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(D3D11_BUFFER_DESC, "bind_flags"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(D3D11_BUFFER_DESC, "cpu_access_flags"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(D3D11_BUFFER_DESC, "structure_byte_stride"));
}

test "D3D11_SUBRESOURCE_DATA matches the documented 64-bit layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(D3D11_SUBRESOURCE_DATA));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(D3D11_SUBRESOURCE_DATA, "sys_mem"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(D3D11_SUBRESOURCE_DATA, "sys_mem_pitch"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(D3D11_SUBRESOURCE_DATA, "sys_mem_slice_pitch"));
}

test "D3D11_VIEWPORT matches the documented 24-byte layout" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(D3D11_VIEWPORT));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(D3D11_VIEWPORT, "top_left_x"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(D3D11_VIEWPORT, "width"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(D3D11_VIEWPORT, "min_depth"));
}

test "Phase III D3D11 ABI structs match documented layouts" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(D3D11_BOX));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(D3D11_BOX, "right"));

    try std.testing.expectEqual(@as(usize, 16), @sizeOf(D3D11_RECT));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(D3D11_RECT, "right"));

    try std.testing.expectEqual(@as(usize, 32), @sizeOf(D3D11_INPUT_ELEMENT_DESC));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(D3D11_INPUT_ELEMENT_DESC, "semantic_index"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(D3D11_INPUT_ELEMENT_DESC, "input_slot_class"));

    try std.testing.expectEqual(@as(usize, 52), @sizeOf(D3D11_SAMPLER_DESC));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(D3D11_SAMPLER_DESC, "border_color"));

    try std.testing.expectEqual(@as(usize, 32), @sizeOf(D3D11_RENDER_TARGET_BLEND_DESC));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(D3D11_RENDER_TARGET_BLEND_DESC, "render_target_write_mask"));
    try std.testing.expectEqual(@as(usize, 264), @sizeOf(D3D11_BLEND_DESC));

    try std.testing.expectEqual(@as(usize, 40), @sizeOf(D3D11_RASTERIZER_DESC));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(D3D11_RASTERIZER_DESC, "scissor_enable"));
}

test "pciVendorForGlVendor maps the real GL vendor strings" {
    try std.testing.expectEqual(@as(?u32, PCI_VENDOR_NVIDIA), pciVendorForGlVendor("NVIDIA Corporation"));
    try std.testing.expectEqual(@as(?u32, PCI_VENDOR_INTEL), pciVendorForGlVendor("Intel"));
    try std.testing.expectEqual(@as(?u32, PCI_VENDOR_INTEL), pciVendorForGlVendor("Intel Open Source Technology Center"));
    try std.testing.expectEqual(@as(?u32, PCI_VENDOR_AMD), pciVendorForGlVendor("ATI Technologies Inc."));
    try std.testing.expectEqual(@as(?u32, PCI_VENDOR_AMD), pciVendorForGlVendor("AMD"));
    try std.testing.expectEqual(@as(?u32, PCI_VENDOR_MICROSOFT), pciVendorForGlVendor("Microsoft Corporation"));
    // Unknown vendors must NOT guess an adapter — callers fall back to GDI.
    try std.testing.expectEqual(@as(?u32, null), pciVendorForGlVendor("Mesa/X.org"));
    try std.testing.expectEqual(@as(?u32, null), pciVendorForGlVendor(""));
}

test "adapterUsableForVendor rejects software adapters for hardware GL" {
    try std.testing.expect(adapterUsableForVendor(PCI_VENDOR_NVIDIA, 0, PCI_VENDOR_NVIDIA));
    // Hybrid laptop: iGPU enumerated first must not match a dGPU GL context.
    try std.testing.expect(!adapterUsableForVendor(PCI_VENDOR_INTEL, 0, PCI_VENDOR_NVIDIA));
    // WARP only pairs with software GL.
    try std.testing.expect(!adapterUsableForVendor(PCI_VENDOR_MICROSOFT, DXGI_ADAPTER_FLAG_SOFTWARE, PCI_VENDOR_NVIDIA));
    try std.testing.expect(adapterUsableForVendor(PCI_VENDOR_MICROSOFT, DXGI_ADAPTER_FLAG_SOFTWARE, PCI_VENDOR_MICROSOFT));
}

test "PresentPolicy watchdog reports a sustained slow streak once, without switching paths" {
    var p = PresentPolicy.init(800, 600);
    // A fast frame resets the streak: 4 slow + fast + 4 slow never reports.
    for (0..PresentPolicy.slow_latch_frames - 1) |_| try std.testing.expect(!p.notePresentMillis(900));
    try std.testing.expect(!p.notePresentMillis(5));
    for (0..PresentPolicy.slow_latch_frames - 1) |_| try std.testing.expect(!p.notePresentMillis(900));
    try std.testing.expectEqual(PresentPolicy.Action.present, p.frameAction(800, 600));
    // The Nth consecutive slow frame reports, exactly once.
    try std.testing.expect(p.notePresentMillis(900));
    try std.testing.expect(!p.notePresentMillis(900));
    // Slowness must NOT flip the session to GDI: frames are reaching the
    // screen, and blt presents on a flip-presented HWND are undefined (black
    // in the field). The session stays on the flip path.
    try std.testing.expectEqual(PresentPolicy.Action.present, p.frameAction(800, 600));
}

test "evaluateProbe verdicts: mismatch, uniform match, content match" {
    const black: [3]u8 = .{ 0, 0, 0 };
    const grey: [3]u8 = .{ 30, 33, 40 };
    const text: [3]u8 = .{ 220, 220, 225 };
    // Broken interop: GL drew content, swapchain got nothing.
    try std.testing.expectEqual(ProbeVerdict.mismatched, evaluateProbe(&.{ grey, text }, &.{ black, black }));
    // Single-channel corruption beyond the rounding tolerance counts too.
    try std.testing.expectEqual(ProbeVerdict.mismatched, evaluateProbe(&.{ grey, grey }, &.{ grey, .{ 30, 33, 43 } }));
    // 10bpc/dither rounding skew within the tolerance is a working path, not
    // a broken one — a bit-exact probe latched the black GDI fallback on
    // machines whose flip path was fine.
    try std.testing.expectEqual(ProbeVerdict.matched_content, evaluateProbe(&.{ grey, text }, &.{ .{ 30, 33, 42 }, .{ 222, 218, 225 } }));
    // Flat frame matching is not yet proof.
    try std.testing.expectEqual(ProbeVerdict.matched_uniform, evaluateProbe(&.{ black, black }, &.{ black, black }));
    // Real content matching settles the probe.
    try std.testing.expectEqual(ProbeVerdict.matched_content, evaluateProbe(&.{ grey, text }, &.{ grey, text }));
}

test "bringup fuse blocks only markers for the current version" {
    var buf: [bringup_marker_max_len]u8 = undefined;
    const probing = try bringupProbingMarker(&buf, "1.19.0");
    try std.testing.expectEqualStrings("probing:1.19.0", probing);
    try std.testing.expect(bringupMarkerIsProbing(probing));

    // Mid-session degraded/failed sessions persist this marker; the next
    // launch of the same version must come out blocked (GDI from frame 0).
    var blocked_buf: [bringup_marker_max_len]u8 = undefined;
    const blocked = try bringupBlockedMarker(&blocked_buf, "1.19.0");
    try std.testing.expectEqualStrings("blocked:1.19.0", blocked);
    try std.testing.expectEqual(BringupFuse.blocked, bringupFuseDecision(blocked, "1.19.0"));

    // Crashed during last bring-up of this version → blocked.
    try std.testing.expectEqual(BringupFuse.blocked, bringupFuseDecision("probing:1.19.0", "1.19.0"));
    try std.testing.expectEqual(BringupFuse.blocked, bringupFuseDecision("blocked:1.19.0", "1.19.0"));
    // A new version retries once; stale/garbage markers don't block.
    try std.testing.expectEqual(BringupFuse.attempt, bringupFuseDecision("blocked:1.18.0", "1.19.0"));
    try std.testing.expectEqual(BringupFuse.attempt, bringupFuseDecision("probing:1.18.0", "1.19.0"));
    try std.testing.expectEqual(BringupFuse.attempt, bringupFuseDecision("", "1.19.0"));
    try std.testing.expectEqual(BringupFuse.attempt, bringupFuseDecision("garbage", "1.19.0"));
    try std.testing.expect(!bringupMarkerIsProbing("blocked:1.19.0"));
}
