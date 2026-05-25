const platform_window = @import("window.zig");

pub fn register(hwnd: platform_window.NativeHandle, id: i32, modifiers: u32, vk: u32) bool {
    return RegisterHotKey(hwnd, id, modifiers, vk) != 0;
}

pub fn unregister(hwnd: platform_window.NativeHandle, id: i32) void {
    _ = UnregisterHotKey(hwnd, id);
}

extern "user32" fn RegisterHotKey(
    hWnd: ?@import("std").os.windows.HWND,
    id: i32,
    fsModifiers: u32,
    vk: u32,
) callconv(.winapi) @import("std").os.windows.BOOL;

extern "user32" fn UnregisterHotKey(
    hWnd: ?@import("std").os.windows.HWND,
    id: i32,
) callconv(.winapi) @import("std").os.windows.BOOL;
