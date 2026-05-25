//! Windows notification backend: system alert sound via `MessageBeep` and
//! taskbar/caption attention via `FlashWindowEx`.

const std = @import("std");
const platform_window = @import("window.zig");

const NativeHandle = platform_window.NativeHandle;
const windows = std.os.windows;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HWND = windows.HWND;
const UINT = u32;

extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;
extern "user32" fn FlashWindowEx(pfwi: *const FLASHWINFO) callconv(.winapi) BOOL;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;

const FLASHWINFO = extern struct {
    cbSize: UINT,
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD,
};

const FLASHW_ALL: DWORD = 3; // Flash both caption and taskbar
const FLASHW_TIMERNOFG: DWORD = 12; // Flash until window comes to foreground
const MB_OK: UINT = 0x00000000; // Default system sound

pub fn bell() void {
    _ = MessageBeep(MB_OK);
}

pub fn requestAttention(handle: NativeHandle) void {
    // Only flash if the window is not already the foreground window.
    if (GetForegroundWindow() == handle) return;
    var fwi = FLASHWINFO{
        .cbSize = @sizeOf(FLASHWINFO),
        .hwnd = handle,
        .dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG,
        .uCount = 3,
        .dwTimeout = 0, // Use default cursor blink rate
    };
    _ = FlashWindowEx(&fwi);
}
