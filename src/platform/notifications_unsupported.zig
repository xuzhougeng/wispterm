//! Notification backend for platforms without a native host yet: no-ops until
//! a port wires up the platform's alert sound and window-attention APIs.

const platform_window = @import("window.zig");

pub fn bell() void {}

pub fn requestAttention(handle: platform_window.NativeHandle) void {
    _ = handle;
}
