//! Linux notification backend: window attention via SDL_FlashWindow and
//! desktop notifications via the `notify-send` command-line tool.
//!
//! notify-send is part of libnotify and present on most desktop Linux systems
//! (GNOME, KDE, XFCE, etc.). When absent the call is silently swallowed.

const std = @import("std");
const c = @import("../apprt/sdl.zig").c;
const platform_window = @import("window.zig");

const NativeHandle = platform_window.NativeHandle;

/// No-op on Linux: SDL has no cross-platform alert-sound API.
/// The terminal bell is already handled by the pty/VT layer writing '\x07'.
pub fn bell() void {}

/// Flash the taskbar/window-decoration entry until the window is focused.
pub fn requestAttention(handle: NativeHandle) void {
    const win: *c.SDL_Window = @ptrCast(handle);
    _ = c.SDL_FlashWindow(win, c.SDL_FLASH_UNTIL_FOCUSED);
}

/// Spawn `notify-send` with the given title and body.
/// If notify-send is absent or fails the error is silently discarded.
pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    var child = std.process.Child.init(
        &.{ "notify-send", std.mem.span(title.ptr), std.mem.span(body.ptr) },
        std.heap.c_allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch {};
}

/// Linux has no authorization gate for desktop notifications.
pub fn notificationAuthStatus() u8 {
    return 2; // authorized
}

/// No authorization request needed on Linux.
pub fn requestNotificationAuth() void {}
