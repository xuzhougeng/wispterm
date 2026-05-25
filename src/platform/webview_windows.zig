const std = @import("std");

pub const NativeWindowHandle = std.os.windows.HWND;
pub const Browser = opaque {};
pub const max_url_units = 2048;
pub const UrlBuffer = [max_url_units]u16;
pub const Url = [:0]const u16;

extern fn phantty_webview2_create(
    parent: NativeWindowHandle,
    left: c_int,
    top: c_int,
    right: c_int,
    bottom: c_int,
    initial_url: [*:0]const u16,
) callconv(.c) ?*Browser;
extern fn phantty_webview2_set_bounds(browser: *Browser, left: c_int, top: c_int, right: c_int, bottom: c_int) callconv(.c) void;
extern fn phantty_webview2_set_visible(browser: *Browser, visible: c_int) callconv(.c) void;
extern fn phantty_webview2_focus(browser: *Browser) callconv(.c) void;
extern fn phantty_webview2_navigate(browser: *Browser, url: [*:0]const u16) callconv(.c) void;
extern fn phantty_webview2_is_ready(browser: *Browser) callconv(.c) c_int;
extern fn phantty_webview2_last_error(browser: *Browser) callconv(.c) i32;
extern fn phantty_webview2_destroy(browser: *Browser) callconv(.c) void;
extern fn phantty_webview2_loader_available() callconv(.c) c_int;

pub fn loaderAvailable() bool {
    return phantty_webview2_loader_available() != 0;
}

pub fn urlFromUtf8(url: []const u8, out: *UrlBuffer) ?Url {
    @memset(out, 0);
    const len = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], url) catch return null;
    out[len] = 0;
    return out[0..len :0];
}

pub fn create(parent: NativeWindowHandle, bounds: anytype, initial_url: Url) ?*Browser {
    return phantty_webview2_create(parent, bounds.left, bounds.top, bounds.right, bounds.bottom, initial_url.ptr);
}

pub fn setBounds(browser: *Browser, bounds: anytype) void {
    phantty_webview2_set_bounds(browser, bounds.left, bounds.top, bounds.right, bounds.bottom);
}

pub fn setVisible(browser: *Browser, visible: bool) void {
    phantty_webview2_set_visible(browser, if (visible) 1 else 0);
}

pub fn focus(browser: *Browser) void {
    phantty_webview2_focus(browser);
}

pub fn navigate(browser: *Browser, url: Url) void {
    phantty_webview2_navigate(browser, url.ptr);
}

pub fn isReady(browser: *Browser) bool {
    return phantty_webview2_is_ready(browser) != 0;
}

pub fn lastError(browser: *Browser) i32 {
    return phantty_webview2_last_error(browser);
}

pub fn destroy(browser: *Browser) void {
    phantty_webview2_destroy(browser);
}
