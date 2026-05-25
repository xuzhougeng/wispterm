const platform_window = @import("window.zig");

pub fn register(hwnd: platform_window.NativeHandle, id: i32, modifiers: u32, key_code: u32) bool {
    _ = hwnd;
    _ = id;
    _ = modifiers;
    _ = key_code;
    return false;
}

pub fn unregister(hwnd: platform_window.NativeHandle, id: i32) void {
    _ = hwnd;
    _ = id;
}
