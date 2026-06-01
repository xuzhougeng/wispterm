//! State and embedded-browser interop for the right-side browser panel.

const std = @import("std");
const Surface = @import("Surface.zig");
const platform_webview = @import("platform/webview.zig");
const ssh_tunnel = @import("ssh_tunnel.zig");
const window_backend = @import("platform/window_backend.zig");
const ui_perf = @import("ui_perf.zig");
const tab = @import("appwindow/tab.zig");
const active_tab_state = @import("appwindow/active_tab.zig");

pub const DEFAULT_WIDTH: f32 = 720;
pub const MIN_WIDTH: f32 = 360;
pub const MAX_WIDTH: f32 = 1800;
pub const MIN_CONTENT_WIDTH: f32 = 320;
pub const RESIZE_HIT_WIDTH: f32 = 12;
pub const URL_BAR_HEIGHT: f32 = 42;
pub const URL_BAR_MARGIN: f32 = 8;
pub const DEFAULT_URL = "http://localhost:3000";

const MAX_URL_BYTES = 2048;

pub const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub fn urlBarBounds(bounds: Bounds) ?Bounds {
    const grip: i32 = @intFromFloat(@round(RESIZE_HIT_WIDTH));
    const left = @min(bounds.right, bounds.left + grip);
    const bottom = @min(bounds.bottom, bounds.top + @as(i32, @intFromFloat(@round(URL_BAR_HEIGHT))));
    if (bounds.right <= left or bottom <= bounds.top) return null;
    return .{
        .left = left,
        .top = bounds.top,
        .right = bounds.right,
        .bottom = bottom,
    };
}

pub fn contentBounds(bounds: Bounds) ?Bounds {
    const grip: i32 = @intFromFloat(@round(RESIZE_HIT_WIDTH));
    const left = @min(bounds.right, bounds.left + grip);
    const top = @min(bounds.bottom, bounds.top + @as(i32, @intFromFloat(@round(URL_BAR_HEIGHT))));
    if (bounds.right <= left or bounds.bottom <= top) return null;
    return .{
        .left = left,
        .top = top,
        .right = bounds.right,
        .bottom = bounds.bottom,
    };
}

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_owner_tab: ?usize = null;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_last_error: platform_webview.ErrorCode = 0;
threadlocal var g_browser: ?*platform_webview.Browser = null;
threadlocal var g_url_buf: [MAX_URL_BYTES]u8 = undefined;
threadlocal var g_url_len: usize = 0;
threadlocal var g_url_bar_focused: bool = false;
threadlocal var g_url_edit_buf: [MAX_URL_BYTES]u8 = undefined;
threadlocal var g_url_edit_len: usize = 0;
threadlocal var g_url_edit_select_all: bool = false;
threadlocal var g_availability_checked: bool = false;
threadlocal var g_embedded_browser_available: bool = false;

pub fn width() f32 {
    return if (isVisibleForActiveTab()) g_width else 0;
}

pub fn isVisibleForActiveTab() bool {
    const owner = g_owner_tab orelse return false;
    return g_visible and owner == active_tab_state.g_active_tab;
}

pub fn onTabClosed(closed_idx: usize) void {
    const owner = g_owner_tab orelse return;
    if (owner == closed_idx) {
        close();
    } else if (owner > closed_idx) {
        g_owner_tab = owner - 1;
    }
}

pub fn onTabReordered(from_idx: usize, to_idx: usize) void {
    const owner = g_owner_tab orelse return;
    if (owner == from_idx) {
        g_owner_tab = to_idx;
    } else if (from_idx < to_idx and owner > from_idx and owner <= to_idx) {
        g_owner_tab = owner - 1;
    } else if (from_idx > to_idx and owner >= to_idx and owner < from_idx) {
        g_owner_tab = owner + 1;
    }
}

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

pub fn setWidth(w: f32, window_width: f32) bool {
    const next = @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
    if (next == g_width) return false;
    g_width = next;
    return true;
}

pub fn panelWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    if (!isVisibleForActiveTab()) return 0;
    const win_w: f32 = @floatFromInt(window_width);
    const max_width = @max(MIN_WIDTH, @min(MAX_WIDTH, win_w - left_offset - right_offset - MIN_CONTENT_WIDTH));
    return @max(MIN_WIDTH, @min(g_width, max_width));
}

pub fn embeddedBrowserAvailable() bool {
    if (!g_availability_checked) {
        g_embedded_browser_available = platform_webview.loaderAvailable();
        g_availability_checked = true;
    }
    return g_embedded_browser_available;
}

pub fn open(parent: ?window_backend.NativeHandle, url: []const u8) void {
    if (!embeddedBrowserAvailable()) {
        close();
        return;
    }

    setUrl(url);
    g_visible = true;
    g_owner_tab = active_tab_state.g_active_tab;

    if (g_browser) |browser| {
        navigateCurrentUrl(browser);
        platform_webview.setVisible(browser, true);
        focus();
        return;
    }

    _ = parent;
}

pub fn openForSurface(allocator: std.mem.Allocator, parent: ?window_backend.NativeHandle, url: []const u8, surface: ?*const Surface) bool {
    const perf = ui_perf.begin("browser_panel.open_for_surface");
    defer perf.end();

    if (!embeddedBrowserAvailable()) {
        close();
        return false;
    }

    const target = externalUrlForSurface(allocator, url, surface) orelse return false;
    defer allocator.free(target);

    open(parent, target);
    return true;
}

pub fn externalUrlForSurface(allocator: std.mem.Allocator, url: []const u8, surface: ?*const Surface) ?[]u8 {
    return ssh_tunnel.externalUrlForSurface(allocator, url, surface);
}

pub fn toggle(parent: ?window_backend.NativeHandle) void {
    if (isVisibleForActiveTab()) {
        close();
    } else {
        if (!embeddedBrowserAvailable()) return;
        open(parent, DEFAULT_URL);
    }
}

pub fn toggleForSurface(allocator: std.mem.Allocator, parent: ?window_backend.NativeHandle, surface: ?*const Surface) bool {
    if (isVisibleForActiveTab()) {
        close();
        return true;
    }
    return openForSurface(allocator, parent, DEFAULT_URL, surface);
}

pub fn close() void {
    g_visible = false;
    g_owner_tab = null;
    g_url_bar_focused = false;
    g_url_edit_select_all = false;
    destroyBrowser();
}

pub fn focus() void {
    if (g_browser) |browser| {
        platform_webview.focus(browser);
    }
}

pub fn isReady() bool {
    const browser = g_browser orelse return false;
    return platform_webview.isReady(browser);
}

pub fn lastError() platform_webview.ErrorCode {
    if (g_browser) |browser| {
        g_last_error = platform_webview.lastError(browser);
    }
    return g_last_error;
}

pub fn sync(parent: window_backend.NativeHandle, window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) void {
    const perf = ui_perf.begin("browser_panel.sync");
    defer perf.end();

    if (window_width <= 0 or window_height <= 0) return;

    if (!isVisibleForActiveTab()) {
        if (g_browser) |browser| platform_webview.setVisible(browser, false);
        return;
    }

    if (!embeddedBrowserAvailable()) {
        close();
        return;
    }

    const bounds = boundsForWindow(window_width, window_height, titlebar_height, left_offset, right_offset);
    if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) return;

    const webview_bounds = contentBounds(bounds) orelse return;

    if (g_browser == null) {
        var url_buf: platform_webview.UrlBuffer = undefined;
        const initial_url = platform_webview.urlFromUtf8(currentUrl(), &url_buf) orelse return;
        g_browser = platform_webview.create(parent, toWebviewBounds(webview_bounds), initial_url);
        if (g_browser) |browser| {
            g_last_error = platform_webview.lastError(browser);
            if (platform_webview.failed(g_last_error)) {
                close();
                return;
            }
        } else {
            close();
            return;
        }
    }

    if (g_browser) |browser| {
        platform_webview.setBounds(browser, toWebviewBounds(webview_bounds));
        platform_webview.setVisible(browser, true);
        g_last_error = platform_webview.lastError(browser);
    }
}

pub fn deinit() void {
    destroyBrowser();
    ssh_tunnel.deinit();
    g_visible = false;
    g_owner_tab = null;
    g_url_bar_focused = false;
    g_url_edit_select_all = false;
}

fn destroyBrowser() void {
    if (g_browser) |browser| {
        platform_webview.destroy(browser);
        g_browser = null;
    }
}

fn toWebviewBounds(bounds: Bounds) platform_webview.Bounds {
    return .{
        .left = bounds.left,
        .top = bounds.top,
        .right = bounds.right,
        .bottom = bounds.bottom,
    };
}

fn setUrl(url: []const u8) void {
    const n = @min(url.len, g_url_buf.len - 1);
    @memcpy(g_url_buf[0..n], url[0..n]);
    g_url_len = n;
}

pub fn currentUrl() []const u8 {
    if (g_url_len == 0) return DEFAULT_URL;
    return g_url_buf[0..g_url_len];
}

pub fn urlBarFocused() bool {
    return isVisibleForActiveTab() and g_url_bar_focused;
}

pub fn urlBarText() []const u8 {
    if (g_url_bar_focused) return g_url_edit_buf[0..g_url_edit_len];
    return currentUrl();
}

pub fn urlBarSelectAll() bool {
    return g_url_bar_focused and g_url_edit_select_all and g_url_edit_len > 0;
}

pub fn focusUrlBar() void {
    g_url_bar_focused = true;
    g_url_edit_len = copyBounded(g_url_edit_buf[0 .. g_url_edit_buf.len - 1], currentUrl());
    g_url_edit_select_all = g_url_edit_len > 0;
}

pub fn blurUrlBar() void {
    g_url_bar_focused = false;
    g_url_edit_select_all = false;
}

pub fn insertUrlBarChar(codepoint: u21) void {
    if (!g_url_bar_focused) return;
    if (codepoint <= 0x20 or codepoint == 0x7F or codepoint > 0x7E) return;
    replaceSelectedUrlBeforeEdit();
    if (g_url_edit_len >= g_url_edit_buf.len - 1) return;
    g_url_edit_buf[g_url_edit_len] = @intCast(codepoint);
    g_url_edit_len += 1;
}

pub fn appendUrlBarText(text: []const u8) void {
    for (text) |ch| {
        if (ch <= 0x20 or ch == 0x7F) continue;
        replaceSelectedUrlBeforeEdit();
        if (g_url_edit_len >= g_url_edit_buf.len - 1) return;
        g_url_edit_buf[g_url_edit_len] = ch;
        g_url_edit_len += 1;
    }
}

pub fn backspaceUrlBar() void {
    if (!g_url_bar_focused or g_url_edit_len == 0) return;
    if (g_url_edit_select_all) {
        g_url_edit_len = 0;
        g_url_edit_select_all = false;
        return;
    }
    g_url_edit_len -= 1;
}

pub fn clearUrlBar() void {
    if (!g_url_bar_focused) return;
    g_url_edit_len = 0;
    g_url_edit_select_all = false;
}

pub fn submitUrlBar(allocator: std.mem.Allocator, parent: ?window_backend.NativeHandle, surface: ?*const Surface) bool {
    const target = normalizeUrlInput(allocator, g_url_edit_buf[0..g_url_edit_len]) orelse return false;
    defer allocator.free(target);

    if (!openForSurface(allocator, parent, target, surface)) return false;
    g_url_bar_focused = false;
    return true;
}

pub fn selectAllUrlBar() void {
    if (!g_url_bar_focused) return;
    g_url_edit_select_all = g_url_edit_len > 0;
}

fn replaceSelectedUrlBeforeEdit() void {
    if (!g_url_edit_select_all) return;
    g_url_edit_len = 0;
    g_url_edit_select_all = false;
}

fn navigateCurrentUrl(browser: *platform_webview.Browser) void {
    var url_buf: platform_webview.UrlBuffer = undefined;
    const url = platform_webview.urlFromUtf8(currentUrl(), &url_buf) orelse return;
    platform_webview.navigate(browser, url);
    g_last_error = platform_webview.lastError(browser);
}

pub fn boundsForWindow(window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) Bounds {
    const win_w: f32 = @floatFromInt(window_width);
    const win_h: f32 = @floatFromInt(window_height);
    const panel_w = panelWidthForWindow(window_width, left_offset, right_offset);
    const right = @max(0, win_w - right_offset);
    const left = @max(left_offset, right - panel_w);
    const top = @max(0, titlebar_height);
    const bottom = @max(top, win_h);

    return .{
        .left = @intFromFloat(@round(left)),
        .top = @intFromFloat(@round(top)),
        .right = @intFromFloat(@round(right)),
        .bottom = @intFromFloat(@round(bottom)),
    };
}

fn normalizeUrlInput(allocator: std.mem.Allocator, input: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOf(u8, trimmed, "://") != null) return allocator.dupe(u8, trimmed) catch null;

    const scheme = if (defaultsToHttp(trimmed)) "http" else "https";
    return std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, trimmed }) catch null;
}

fn defaultsToHttp(input: []const u8) bool {
    return startsWithIgnoreCase(input, "localhost") or
        startsWithIgnoreCase(input, "127.") or
        startsWithIgnoreCase(input, "0.0.0.0") or
        startsWithIgnoreCase(input, "[::1]") or
        std.mem.indexOfScalar(u8, input, ':') != null;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

test "browser_panel: visible only on owning active tab" {
    const saved_visible = g_visible;
    const saved_owner = g_owner_tab;
    const saved_active_tab = active_tab_state.g_active_tab;
    defer {
        g_visible = saved_visible;
        g_owner_tab = saved_owner;
        active_tab_state.g_active_tab = saved_active_tab;
    }

    active_tab_state.g_active_tab = 0;
    g_visible = true;
    g_owner_tab = 0;

    try std.testing.expect(isVisibleForActiveTab());
    try std.testing.expectEqual(DEFAULT_WIDTH, width());

    active_tab_state.g_active_tab = 1;
    try std.testing.expect(!isVisibleForActiveTab());
    try std.testing.expectEqual(@as(f32, 0), width());

    active_tab_state.g_active_tab = 0;
    try std.testing.expect(isVisibleForActiveTab());
}

test "browser_panel: public parent handle API uses window backend handle" {
    const open_info = @typeInfo(@TypeOf(open)).@"fn";
    try std.testing.expect(open_info.params[0].type.? == ?window_backend.NativeHandle);

    const open_surface_info = @typeInfo(@TypeOf(openForSurface)).@"fn";
    try std.testing.expect(open_surface_info.params[1].type.? == ?window_backend.NativeHandle);

    const toggle_info = @typeInfo(@TypeOf(toggle)).@"fn";
    try std.testing.expect(toggle_info.params[0].type.? == ?window_backend.NativeHandle);

    const sync_info = @typeInfo(@TypeOf(sync)).@"fn";
    try std.testing.expect(sync_info.params[0].type.? == window_backend.NativeHandle);

    const submit_info = @typeInfo(@TypeOf(submitUrlBar)).@"fn";
    try std.testing.expect(submit_info.params[1].type.? == ?window_backend.NativeHandle);
}
