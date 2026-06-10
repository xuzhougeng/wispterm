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

pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SCALING_NONE: u32 = 1;
pub const DXGI_SCALING_STRETCH: u32 = 0;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;
pub const DXGI_ALPHA_MODE_IGNORE: u32 = 3;

pub const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
pub const D3D11_SDK_VERSION: u32 = 7;
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
pub const D3D11_USAGE_DEFAULT: u32 = 0;
pub const D3D11_BIND_RENDER_TARGET: u32 = 0x20;
pub const D3D11_RESOURCE_MISC_SHARED: u32 = 0x2;

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
    pub const D3D11Device_CreateTexture2D: usize = 5;

    // ID3D11DeviceContext (IUnknown + ID3D11DeviceChild(4) → first own slot 7)
    pub const D3D11DeviceContext_CopyResource: usize = 47;

    // IDXGIObject: SetPrivateData(3) SetPrivateDataInterface(4)
    // GetPrivateData(5) GetParent(6)
    pub const DXGIObject_GetParent: usize = 6;

    // IDXGIDevice (IDXGIObject + GetAdapter first)
    pub const DXGIDevice_GetAdapter: usize = 7;

    // IDXGIFactory (IDXGIObject + EnumAdapters(7) MakeWindowAssociation(8) …)
    pub const DXGIFactory_MakeWindowAssociation: usize = 8;

    // IDXGIFactory2 (IDXGIObject + IDXGIFactory(5) + IDXGIFactory1(2) →
    // IsWindowedStereoEnabled(14), CreateSwapChainForHwnd(15))
    pub const DXGIFactory2_CreateSwapChainForHwnd: usize = 15;

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
// PresentPolicy
// ============================================================================

/// Per-frame decision for the flip-model presenter. Pure so the
/// resize/skip/fallback transitions are unit-testable off-Windows.
pub const PresentPolicy = struct {
    pub const Action = enum { skip, present, resize_then_present, fallback };

    width: i32,
    height: i32,
    failed: bool = false,

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

    /// Latch the fallback path for the rest of the session — a presenter that
    /// failed once must not flap between DXGI and GDI presents.
    pub fn fail(self: *PresentPolicy) void {
        self.failed = true;
    }
};

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
        0x08, 0xd2,
        0x89, 0x4e,
        0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c,
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
