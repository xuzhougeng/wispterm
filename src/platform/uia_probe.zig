//! Minimal UI Automation (UIA) probe — Windows only, Step 1 of the root cure.
//!
//! We suspect select-translate / copy-on-select tools (有道词典 etc.) read the
//! selection via UIA on conhost and Windows Terminal — both of which expose a
//! UIA text provider — and only fall back to injecting Ctrl+C + clobbering the
//! clipboard when no UIA provider exists (our case). If that's true, the real
//! fix is to implement a UIA text provider; if those tools never query us over
//! UIA, that effort would be wasted.
//!
//! This module answers `WM_GETOBJECT` with a *barebones* IRawElementProviderSimple
//! that implements no text pattern yet — it only LOGS every UIA method a client
//! calls (via input_diagnostics). The point is purely to confirm whether such
//! tools actually inspect us over UIA, before we build the full provider.
//!
//! Everything is gated behind input_diagnostics.enabled(), so normal users get
//! the unchanged DefWindowProc behavior (no provider advertised).

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const input_diagnostics = @import("../input_diagnostics.zig");

const HWND = windows.HWND;
const WPARAM = windows.WPARAM;
const LPARAM = windows.LPARAM;
const LRESULT = windows.LRESULT;
const HRESULT = windows.HRESULT;
const GUID = windows.GUID;
const HMODULE = windows.HMODULE;

const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

/// WM_GETOBJECT object id used by UIA (UiaRootObjectId).
const UiaRootObjectId: i32 = -25;
const UIA_TextPatternId: i32 = 10014;
const ProviderOptions_ServerSideProvider: i32 = 1;

const IID_IUnknown = GUID{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
const IID_IRawElementProviderSimple = GUID{
    .Data1 = 0xd6dd68d1,
    .Data2 = 0x86fd,
    .Data3 = 0x4332,
    .Data4 = .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c },
};

/// 24-byte VARIANT (x64). vt=0 is VT_EMPTY, which UIA treats as "unsupported".
const VARIANT = extern struct {
    vt: u16,
    r1: u16,
    r2: u16,
    r3: u16,
    val: [16]u8,
};

const IRawElementProviderSimple = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*IRawElementProviderSimple, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IRawElementProviderSimple) callconv(.winapi) u32,
        Release: *const fn (*IRawElementProviderSimple) callconv(.winapi) u32,
        get_ProviderOptions: *const fn (*IRawElementProviderSimple, *i32) callconv(.winapi) HRESULT,
        GetPatternProvider: *const fn (*IRawElementProviderSimple, i32, *?*anyopaque) callconv(.winapi) HRESULT,
        GetPropertyValue: *const fn (*IRawElementProviderSimple, i32, *VARIANT) callconv(.winapi) HRESULT,
        get_HostRawElementProvider: *const fn (*IRawElementProviderSimple, *?*IRawElementProviderSimple) callconv(.winapi) HRESULT,
    };
};

fn guidEql(a: *const GUID, b: *const GUID) bool {
    return a.Data1 == b.Data1 and a.Data2 == b.Data2 and a.Data3 == b.Data3 and
        std.mem.eql(u8, &a.Data4, &b.Data4);
}

fn qi(self: *IRawElementProviderSimple, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEql(riid, &IID_IUnknown) or guidEql(riid, &IID_IRawElementProviderSimple)) {
        ppv.* = self;
        input_diagnostics.log("uia QueryInterface -> provider", .{});
        return S_OK;
    }
    input_diagnostics.log("uia QueryInterface other-iid {x:0>8}", .{riid.Data1});
    ppv.* = null;
    return E_NOINTERFACE;
}

fn addRef(self: *IRawElementProviderSimple) callconv(.winapi) u32 {
    _ = self;
    return 1; // static singleton: never freed
}

fn release(self: *IRawElementProviderSimple) callconv(.winapi) u32 {
    _ = self;
    return 1;
}

fn getProviderOptions(self: *IRawElementProviderSimple, ret: *i32) callconv(.winapi) HRESULT {
    _ = self;
    ret.* = ProviderOptions_ServerSideProvider;
    return S_OK;
}

fn getPatternProvider(self: *IRawElementProviderSimple, patternId: i32, ret: *?*anyopaque) callconv(.winapi) HRESULT {
    _ = self;
    input_diagnostics.log("uia GetPatternProvider patternId={d}{s}", .{
        patternId,
        if (patternId == UIA_TextPatternId) " (TextPattern — tool wants to read selected text!)" else "",
    });
    ret.* = null; // probe: advertise no pattern yet
    return S_OK;
}

fn getPropertyValue(self: *IRawElementProviderSimple, propertyId: i32, ret: *VARIANT) callconv(.winapi) HRESULT {
    _ = self;
    input_diagnostics.log("uia GetPropertyValue propertyId={d}", .{propertyId});
    ret.* = std.mem.zeroes(VARIANT); // VT_EMPTY
    return S_OK;
}

fn getHostRawElementProvider(self: *IRawElementProviderSimple, ret: *?*IRawElementProviderSimple) callconv(.winapi) HRESULT {
    _ = self;
    ret.* = null;
    if (g_uia.host_from_hwnd) |f| {
        if (g_hwnd) |h| _ = f(h, ret);
    }
    return S_OK;
}

var g_vtbl = IRawElementProviderSimple.Vtbl{
    .QueryInterface = qi,
    .AddRef = addRef,
    .Release = release,
    .get_ProviderOptions = getProviderOptions,
    .GetPatternProvider = getPatternProvider,
    .GetPropertyValue = getPropertyValue,
    .get_HostRawElementProvider = getHostRawElementProvider,
};
var g_provider = IRawElementProviderSimple{ .lpVtbl = &g_vtbl };

const UiaReturnFn = *const fn (HWND, WPARAM, LPARAM, *IRawElementProviderSimple) callconv(.winapi) LRESULT;
const UiaHostFn = *const fn (HWND, *?*IRawElementProviderSimple) callconv(.winapi) HRESULT;

extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;

const Uia = struct {
    loaded: bool = false,
    ret_provider: ?UiaReturnFn = null,
    host_from_hwnd: ?UiaHostFn = null,
};
var g_uia: Uia = .{};
var g_hwnd: ?HWND = null;

fn ensureLoaded() void {
    if (g_uia.loaded) return;
    g_uia.loaded = true;
    const dll = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("uiautomationcore.dll")) orelse {
        input_diagnostics.log("uia: LoadLibrary uiautomationcore.dll FAILED", .{});
        return;
    };
    if (GetProcAddress(dll, "UiaReturnRawElementProvider")) |p| g_uia.ret_provider = @ptrCast(p);
    if (GetProcAddress(dll, "UiaHostProviderFromHwnd")) |p| g_uia.host_from_hwnd = @ptrCast(p);
    input_diagnostics.log("uia: loaded uiautomationcore.dll ret_provider={} host_from_hwnd={}", .{
        g_uia.ret_provider != null,
        g_uia.host_from_hwnd != null,
    });
}

/// Handle WM_GETOBJECT. Returns the LRESULT when it answered a UIA root query,
/// or null to let DefWindowProc handle it (non-UIA object ids, or diagnostics
/// off — i.e. normal users are unaffected).
pub fn handleGetObject(hwnd: HWND, wParam: WPARAM, lParam: LPARAM) ?LRESULT {
    if (builtin.os.tag != .windows) return null;
    if (!input_diagnostics.enabled()) return null;
    const obj_id: i32 = @truncate(lParam);
    if (obj_id != UiaRootObjectId) return null;
    input_diagnostics.log("uia WM_GETOBJECT UiaRootObjectId — a UIA client is inspecting the window", .{});
    ensureLoaded();
    g_hwnd = hwnd;
    const f = g_uia.ret_provider orelse return null;
    return f(hwnd, wParam, lParam, &g_provider);
}
