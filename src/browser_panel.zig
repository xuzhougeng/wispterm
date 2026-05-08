//! State and WebView2 interop for the right-side browser panel.

const std = @import("std");
const win32 = @import("apprt/win32.zig");

pub const DEFAULT_WIDTH: f32 = 720;
pub const MIN_WIDTH: f32 = 360;
pub const MAX_WIDTH: f32 = 1280;
pub const MIN_CONTENT_WIDTH: f32 = 320;
pub const DEFAULT_URL = "http://localhost:3000";

const MAX_URL_BYTES = 2048;
const BrowserHandle = opaque {};

extern fn phantty_webview2_create(
    parent: win32.HWND,
    left: c_int,
    top: c_int,
    right: c_int,
    bottom: c_int,
    initial_url: [*:0]const u16,
) callconv(.c) ?*BrowserHandle;
extern fn phantty_webview2_set_bounds(browser: *BrowserHandle, left: c_int, top: c_int, right: c_int, bottom: c_int) callconv(.c) void;
extern fn phantty_webview2_set_visible(browser: *BrowserHandle, visible: c_int) callconv(.c) void;
extern fn phantty_webview2_focus(browser: *BrowserHandle) callconv(.c) void;
extern fn phantty_webview2_navigate(browser: *BrowserHandle, url: [*:0]const u16) callconv(.c) void;
extern fn phantty_webview2_is_ready(browser: *BrowserHandle) callconv(.c) c_int;
extern fn phantty_webview2_last_error(browser: *BrowserHandle) callconv(.c) win32.HRESULT;
extern fn phantty_webview2_destroy(browser: *BrowserHandle) callconv(.c) void;

const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_last_error: win32.HRESULT = 0;
threadlocal var g_browser: ?*BrowserHandle = null;
threadlocal var g_url_buf: [MAX_URL_BYTES]u8 = undefined;
threadlocal var g_url_len: usize = 0;

pub fn width() f32 {
    return if (g_visible) g_width else 0;
}

pub fn open(parent: ?win32.HWND, url: []const u8) void {
    setUrl(url);
    g_visible = true;

    if (g_browser) |browser| {
        navigateCurrentUrl(browser);
        phantty_webview2_set_visible(browser, 1);
        focus();
        return;
    }

    _ = parent;
}

pub fn toggle(parent: ?win32.HWND) void {
    if (g_visible) {
        close();
    } else {
        open(parent, DEFAULT_URL);
    }
}

pub fn close() void {
    g_visible = false;
    if (g_browser) |browser| {
        phantty_webview2_set_visible(browser, 0);
    }
}

pub fn focus() void {
    if (g_browser) |browser| {
        phantty_webview2_focus(browser);
    }
}

pub fn isReady() bool {
    const browser = g_browser orelse return false;
    return phantty_webview2_is_ready(browser) != 0;
}

pub fn lastError() win32.HRESULT {
    if (g_browser) |browser| {
        g_last_error = phantty_webview2_last_error(browser);
    }
    return g_last_error;
}

pub fn sync(parent: win32.HWND, window_width: i32, window_height: i32, titlebar_height: f32, right_offset: f32) void {
    if (window_width <= 0 or window_height <= 0) return;

    if (!g_visible) {
        if (g_browser) |browser| phantty_webview2_set_visible(browser, 0);
        return;
    }

    const bounds = panelBounds(window_width, window_height, titlebar_height, right_offset);
    if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) return;

    if (g_browser == null) {
        var wide_buf: [MAX_URL_BYTES]u16 = undefined;
        const wide_url = urlToWide(currentUrl(), &wide_buf) orelse return;
        g_browser = phantty_webview2_create(parent, bounds.left, bounds.top, bounds.right, bounds.bottom, wide_url);
        if (g_browser) |browser| {
            g_last_error = phantty_webview2_last_error(browser);
        }
    }

    if (g_browser) |browser| {
        phantty_webview2_set_bounds(browser, bounds.left, bounds.top, bounds.right, bounds.bottom);
        phantty_webview2_set_visible(browser, 1);
        g_last_error = phantty_webview2_last_error(browser);
    }
}

pub fn deinit() void {
    if (g_browser) |browser| {
        phantty_webview2_destroy(browser);
        g_browser = null;
    }
    g_visible = false;
}

fn setUrl(url: []const u8) void {
    const n = @min(url.len, g_url_buf.len - 1);
    @memcpy(g_url_buf[0..n], url[0..n]);
    g_url_len = n;
}

fn currentUrl() []const u8 {
    if (g_url_len == 0) return DEFAULT_URL;
    return g_url_buf[0..g_url_len];
}

fn navigateCurrentUrl(browser: *BrowserHandle) void {
    var wide_buf: [MAX_URL_BYTES]u16 = undefined;
    const wide_url = urlToWide(currentUrl(), &wide_buf) orelse return;
    phantty_webview2_navigate(browser, wide_url);
    g_last_error = phantty_webview2_last_error(browser);
}

fn urlToWide(url: []const u8, out: *[MAX_URL_BYTES]u16) ?[*:0]const u16 {
    if (url.len >= out.len) return null;
    @memset(out, 0);
    const len = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], url) catch return null;
    out[len] = 0;
    return out[0..len :0].ptr;
}

fn panelBounds(window_width: i32, window_height: i32, titlebar_height: f32, right_offset: f32) Bounds {
    const win_w: f32 = @floatFromInt(window_width);
    const win_h: f32 = @floatFromInt(window_height);
    const max_width = @max(MIN_WIDTH, @min(MAX_WIDTH, win_w - right_offset - MIN_CONTENT_WIDTH));
    const panel_w = @max(MIN_WIDTH, @min(g_width, max_width));
    const right = @max(0, win_w - right_offset);
    const left = @max(0, right - panel_w);
    const top = @max(0, titlebar_height);
    const bottom = @max(top, win_h);

    return .{
        .left = @intFromFloat(@round(left)),
        .top = @intFromFloat(@round(top)),
        .right = @intFromFloat(@round(right)),
        .bottom = @intFromFloat(@round(bottom)),
    };
}
