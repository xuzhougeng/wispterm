const std = @import("std");

pub const NativeWindowHandle = *anyopaque;
pub const Browser = opaque {};
pub const max_url_units = 2048;
pub const UrlBuffer = [max_url_units]u8;
pub const Url = [:0]const u8;

extern fn wispterm_webview_macos_loader_available() callconv(.c) c_int;
extern fn wispterm_webview_macos_create(
    parent: NativeWindowHandle,
    left: c_int,
    top: c_int,
    right: c_int,
    bottom: c_int,
    initial_url: [*:0]const u8,
) callconv(.c) ?*Browser;
extern fn wispterm_webview_macos_set_bounds(browser: *Browser, left: c_int, top: c_int, right: c_int, bottom: c_int) callconv(.c) void;
extern fn wispterm_webview_macos_set_visible(browser: *Browser, visible: c_int) callconv(.c) void;
extern fn wispterm_webview_macos_focus(browser: *Browser) callconv(.c) void;
extern fn wispterm_webview_macos_navigate(browser: *Browser, url: [*:0]const u8) callconv(.c) void;
extern fn wispterm_webview_macos_reload(browser: *Browser) callconv(.c) void;
extern fn wispterm_webview_macos_is_ready(browser: *Browser) callconv(.c) c_int;
extern fn wispterm_webview_macos_last_error(browser: *Browser) callconv(.c) i32;
extern fn wispterm_webview_macos_destroy(browser: *Browser) callconv(.c) void;

pub fn loaderAvailable() bool {
    return wispterm_webview_macos_loader_available() != 0;
}

pub fn urlFromUtf8(url: []const u8, out: *UrlBuffer) ?Url {
    if (url.len >= out.len) return null;
    @memcpy(out[0..url.len], url);
    out[url.len] = 0;
    return out[0..url.len :0];
}

pub fn create(parent: NativeWindowHandle, bounds: anytype, initial_url: Url) ?*Browser {
    return wispterm_webview_macos_create(parent, bounds.left, bounds.top, bounds.right, bounds.bottom, initial_url.ptr);
}

pub fn setBounds(browser: *Browser, bounds: anytype) void {
    wispterm_webview_macos_set_bounds(browser, bounds.left, bounds.top, bounds.right, bounds.bottom);
}

pub fn setVisible(browser: *Browser, visible: bool) void {
    wispterm_webview_macos_set_visible(browser, if (visible) 1 else 0);
}

pub fn focus(browser: *Browser) void {
    wispterm_webview_macos_focus(browser);
}

pub fn navigate(browser: *Browser, url: Url) void {
    wispterm_webview_macos_navigate(browser, url.ptr);
}

pub fn reload(browser: *Browser) void {
    wispterm_webview_macos_reload(browser);
}

pub fn isReady(browser: *Browser) bool {
    return wispterm_webview_macos_is_ready(browser) != 0;
}

pub fn lastError(browser: *Browser) i32 {
    return wispterm_webview_macos_last_error(browser);
}

pub fn destroy(browser: *Browser) void {
    wispterm_webview_macos_destroy(browser);
}
