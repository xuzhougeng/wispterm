//! User-notification capability: signal terminal events to the user through
//! native OS facilities (alert sound and window attention requests).
//!
//! The bell and attention request are intentionally separate seams. Hosts
//! implement them very differently — Windows uses `MessageBeep` plus a taskbar
//! `FlashWindowEx`, macOS would use an alert sound plus
//! `NSApplication.requestUserAttention`, and Linux toolkits raise the window's
//! urgency hint or post a desktop notification through the session portal.

const std = @import("std");
const builtin = @import("builtin");
const platform_window = @import("window.zig");

pub const Backend = enum {
    windows,
    macos,
    unsupported,
};

/// Cached desktop-notification authorization status. Mirrors the macOS
/// bridge contract: 0 = unavailable/not-determined, 1 = denied, 2 = authorized.
pub const NotifAuthStatus = enum(u8) { unavailable = 0, denied = 1, authorized = 2 };

pub fn backendForOs(comptime os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .macos => .macos,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("notifications_windows.zig"),
    .macos => @import("notifications_macos.zig"),
    .unsupported => @import("notifications_unsupported.zig"),
};

/// Native handle of the window a notification is associated with.
pub const NativeHandle = platform_window.NativeHandle;

/// Play the system alert sound for a terminal bell event.
pub fn bell() void {
    impl.bell();
}

/// Ask the OS to draw attention to the given window (taskbar flash, dock
/// bounce, or urgency hint), typically when the window is not focused. The
/// backend decides whether the window already has focus and skips redundant
/// attention requests.
pub fn requestAttention(handle: NativeHandle) void {
    impl.requestAttention(handle);
}

/// Post a native desktop notification (macOS toast). No-op where unsupported.
pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    impl.showDesktopNotification(title, body);
}

/// Current cached authorization status (synchronous, cheap).
pub fn notificationAuthStatus() NotifAuthStatus {
    return @enumFromInt(impl.notificationAuthStatus());
}

/// Ask the OS for notification permission (shows the system prompt once).
/// Safe to call repeatedly; the OS only prompts on the first undetermined call.
pub fn requestNotificationAuth() void {
    impl.requestNotificationAuth();
}

test "notifications selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.macos, backendForOs(.macos));
}

test "notifications exposes bell and attention API shape" {
    const bell_info = @typeInfo(@TypeOf(bell)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), bell_info.params.len);
    try std.testing.expect(bell_info.return_type.? == void);

    const attention_info = @typeInfo(@TypeOf(requestAttention)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), attention_info.params.len);
    try std.testing.expect(attention_info.params[0].type.? == NativeHandle);
    try std.testing.expect(attention_info.return_type.? == void);

    const show_info = @typeInfo(@TypeOf(showDesktopNotification)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), show_info.params.len);
    try std.testing.expect(show_info.return_type.? == void);

    const status_info = @typeInfo(@TypeOf(notificationAuthStatus)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), status_info.params.len);
    try std.testing.expectEqual(NotifAuthStatus, status_info.return_type.?);
}
