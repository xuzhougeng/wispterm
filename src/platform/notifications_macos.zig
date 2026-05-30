const platform_window = @import("window.zig");

extern fn wispterm_macos_notification_bell() void;
extern fn wispterm_macos_notification_request_attention(handle: ?*anyopaque) void;
extern fn wispterm_macos_notif_show(title: [*:0]const u8, body: [*:0]const u8) void;
extern fn wispterm_macos_notif_auth_status() c_int;
extern fn wispterm_macos_notif_request_auth() void;

pub fn bell() void {
    wispterm_macos_notification_bell();
}

pub fn requestAttention(handle: platform_window.NativeHandle) void {
    wispterm_macos_notification_request_attention(handle);
}

pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    wispterm_macos_notif_show(title.ptr, body.ptr);
}

pub fn notificationAuthStatus() u8 {
    const s = wispterm_macos_notif_auth_status();
    return if (s < 0 or s > 2) 0 else @intCast(s);
}

pub fn requestNotificationAuth() void {
    wispterm_macos_notif_request_auth();
}
