//! State and embedded-browser interop for the right-side browser panel.

const std = @import("std");
const Surface = @import("Surface.zig");
const platform_webview = @import("platform/webview.zig");
const ssh_tunnel = @import("ssh_tunnel.zig");
const html_server = @import("html_server.zig");
const preview_diagnostics = @import("preview_diagnostics.zig");
const window_backend = @import("platform/window_backend.zig");
const ui_perf = @import("ui_perf.zig");
const tab = @import("appwindow/tab.zig");
const active_tab_state = @import("appwindow/active_tab.zig");
const text_search = @import("text_search.zig");

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

pub const DisplayMode = enum { side, full };
pub threadlocal var g_display_mode: DisplayMode = .side;

pub fn setDisplayMode(mode: DisplayMode) void {
    g_display_mode = mode;
}

pub fn displayMode() DisplayMode {
    return g_display_mode;
}

/// Pure width math. In `full`, the panel covers the entire content area (the
/// native webview occludes the terminal, which stays laid out behind it). In
/// `side`, it reserves MIN_CONTENT_WIDTH for the terminal and clamps to stored_width.
pub fn panelWidthForMode(mode: DisplayMode, stored_width: f32, window_width: i32, left_offset: f32, right_offset: f32) f32 {
    const win_w: f32 = @floatFromInt(window_width);
    if (mode == .full) {
        return @max(MIN_WIDTH, win_w - left_offset - right_offset);
    }
    const max_width = @max(MIN_WIDTH, @min(MAX_WIDTH, win_w - left_offset - right_offset - MIN_CONTENT_WIDTH));
    return @max(MIN_WIDTH, @min(stored_width, max_width));
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

/// Whether the native webview should be shown this frame. Visible on its owning
/// active tab, UNLESS a blocking GPU overlay is up (`suppressed`) — the webview
/// composites above the GPU surface and would occlude the command center et al.
pub fn shouldShowWebview(suppressed: bool) bool {
    return isVisibleForActiveTab() and !suppressed;
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

/// Width reserved from the TERMINAL layout. Always side-sized — even in full
/// mode — so the terminal keeps a sane grid behind the (occluding) webview.
/// Reserving the full width here collapses the terminal toward zero columns and
/// panics ghostty's resize-reflow (PageList ViewportPinInsufficientRows). The
/// webview's own draw rect uses `panelDrawWidthForWindow` instead.
pub fn panelWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    if (!isVisibleForActiveTab()) return 0;
    return panelWidthForMode(.side, g_width, window_width, left_offset, right_offset);
}

/// Width of the panel's DRAW rect (the webview + URL-bar chrome). Covers the
/// whole content area in full mode; side-clamped otherwise.
pub fn panelDrawWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    if (!isVisibleForActiveTab()) return 0;
    return panelWidthForMode(g_display_mode, g_width, window_width, left_offset, right_offset);
}

pub fn embeddedBrowserAvailable() bool {
    if (!g_availability_checked) {
        g_embedded_browser_available = platform_webview.loaderAvailable();
        g_availability_checked = true;
        preview_diagnostics.debug("browser-panel", &.{
            .{ .key = "stage", .value = "loader-check" },
            .{ .key = "available", .value = if (g_embedded_browser_available) "true" else "false" },
        });
    }
    return g_embedded_browser_available;
}

pub fn open(parent: ?window_backend.NativeHandle, url: []const u8) void {
    if (!embeddedBrowserAvailable()) {
        preview_diagnostics.debug("browser-panel", &.{
            .{ .key = "stage", .value = "open-unavailable" },
            .{ .key = "url", .value = url },
        });
        close();
        return;
    }

    preview_diagnostics.debug("browser-panel", &.{
        .{ .key = "stage", .value = "open" },
        .{ .key = "url", .value = url },
    });
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
        preview_diagnostics.debug("browser-panel", &.{
            .{ .key = "stage", .value = "open-for-surface-unavailable" },
            .{ .key = "url", .value = url },
        });
        close();
        return false;
    }

    const target = externalUrlForSurface(allocator, url, surface) orelse {
        preview_diagnostics.debug("browser-panel", &.{
            .{ .key = "stage", .value = "external-url-failed" },
            .{ .key = "launch", .value = if (surface) |s| @tagName(s.launch_kind) else "none" },
            .{ .key = "url", .value = url },
        });
        return false;
    };
    defer allocator.free(target);
    preview_diagnostics.debug("browser-panel", &.{
        .{ .key = "stage", .value = "open-for-surface" },
        .{ .key = "launch", .value = if (surface) |s| @tagName(s.launch_kind) else "none" },
        .{ .key = "url", .value = url },
        .{ .key = "target", .value = target },
    });

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

pub fn openJupyterForSurface(allocator: std.mem.Allocator, parent: ?window_backend.NativeHandle, surface: ?*const Surface) bool {
    if (isVisibleForActiveTab()) {
        focusUrlBar();
        return true;
    }
    // Open blank, then focus the URL bar so the user pastes their Jupyter URL.
    if (!openForSurface(allocator, parent, "", surface)) return false;
    focusUrlBar();
    return true;
}

pub fn close() void {
    g_display_mode = .side;
    g_visible = false;
    g_owner_tab = null;
    g_url_bar_focused = false;
    g_url_edit_select_all = false;
    destroyBrowser();
    html_server.stopAll();
}

pub fn focus() void {
    if (g_browser) |browser| {
        platform_webview.focus(browser);
    }
}

pub fn refresh() void {
    const browser = g_browser orelse return;
    platform_webview.reload(browser);
    g_last_error = platform_webview.lastError(browser);
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

pub fn sync(parent: window_backend.NativeHandle, window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32, suppressed: bool) void {
    const perf = ui_perf.begin("browser_panel.sync");
    defer perf.end();

    if (window_width <= 0 or window_height <= 0) return;

    if (!shouldShowWebview(suppressed)) {
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
                var err_buf: [32]u8 = undefined;
                const err_s = std.fmt.bufPrint(&err_buf, "{d}", .{g_last_error}) catch "";
                preview_diagnostics.debug("browser-panel", &.{
                    .{ .key = "stage", .value = "create-failed" },
                    .{ .key = "url", .value = currentUrl() },
                    .{ .key = "last_error", .value = err_s },
                });
                close();
                return;
            }
            preview_diagnostics.debug("browser-panel", &.{
                .{ .key = "stage", .value = "created" },
                .{ .key = "url", .value = currentUrl() },
            });
        } else {
            preview_diagnostics.debug("browser-panel", &.{
                .{ .key = "stage", .value = "create-null" },
                .{ .key = "url", .value = currentUrl() },
            });
            close();
            return;
        }
    }

    if (g_browser) |browser| {
        platform_webview.setBounds(browser, toWebviewBounds(webview_bounds));
        platform_webview.setVisible(browser, true);
        g_last_error = platform_webview.lastError(browser);
        if (platform_webview.failed(g_last_error)) {
            var err_buf: [32]u8 = undefined;
            const err_s = std.fmt.bufPrint(&err_buf, "{d}", .{g_last_error}) catch "";
            preview_diagnostics.debug("browser-panel", &.{
                .{ .key = "stage", .value = "sync-error" },
                .{ .key = "url", .value = currentUrl() },
                .{ .key = "last_error", .value = err_s },
            });
        }
    }
}

pub fn deinit() void {
    destroyBrowser();
    html_server.stopAll();
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
    const url = platform_webview.urlFromUtf8(currentUrl(), &url_buf) orelse {
        preview_diagnostics.debug("browser-panel", &.{
            .{ .key = "stage", .value = "url-encode-failed" },
            .{ .key = "url", .value = currentUrl() },
        });
        return;
    };
    platform_webview.navigate(browser, url);
    g_last_error = platform_webview.lastError(browser);
    var err_buf: [32]u8 = undefined;
    const err_s = std.fmt.bufPrint(&err_buf, "{d}", .{g_last_error}) catch "";
    preview_diagnostics.debug("browser-panel", &.{
        .{ .key = "stage", .value = "navigate" },
        .{ .key = "url", .value = currentUrl() },
        .{ .key = "last_error", .value = err_s },
    });
}

pub fn boundsForWindow(window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) Bounds {
    const win_w: f32 = @floatFromInt(window_width);
    const win_h: f32 = @floatFromInt(window_height);
    const panel_w = panelDrawWidthForWindow(window_width, left_offset, right_offset);
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
    return text_search.startsWithIgnoreCase(input, "localhost") or
        text_search.startsWithIgnoreCase(input, "127.") or
        text_search.startsWithIgnoreCase(input, "0.0.0.0") or
        text_search.startsWithIgnoreCase(input, "[::1]") or
        std.mem.indexOfScalar(u8, input, ':') != null;
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

test "panelWidthForMode: full covers the whole content area; side reserves min content" {
    try std.testing.expectEqual(@as(f32, 1600), panelWidthForMode(.full, 720, 1600, 0, 0));
    try std.testing.expectEqual(@as(f32, 720), panelWidthForMode(.side, 720, 1600, 0, 0));
    try std.testing.expectEqual(@as(f32, 1500), panelWidthForMode(.full, 720, 1600, 60, 40));
}

test "full mode: terminal-layout width stays side; only the draw rect goes full" {
    // Regression: in full mode the webview DRAWS over the whole content area, but
    // the width reserved from the TERMINAL layout must stay side-sized. Reserving
    // the full width collapsed the terminal to ~1 col and panicked ghostty's
    // resize-reflow (PageList ViewportPinInsufficientRows) on Windows.
    const saved_visible = g_visible;
    const saved_owner = g_owner_tab;
    const saved_active_tab = active_tab_state.g_active_tab;
    const saved_width = g_width;
    const saved_mode = g_display_mode;
    defer {
        g_visible = saved_visible;
        g_owner_tab = saved_owner;
        active_tab_state.g_active_tab = saved_active_tab;
        g_width = saved_width;
        g_display_mode = saved_mode;
    }

    active_tab_state.g_active_tab = 0;
    g_visible = true;
    g_owner_tab = 0;
    g_width = 720;
    g_display_mode = .full;

    // Terminal-layout reservation: side-sized even in full mode.
    try std.testing.expectEqual(@as(f32, 720), panelWidthForWindow(1600, 0, 0));
    // Webview draw rect: full content width in full mode.
    try std.testing.expectEqual(@as(f32, 1600), panelDrawWidthForWindow(1600, 0, 0));
}

test "browser_panel: a blocking overlay suppresses the webview even on the active tab" {
    // The native webview composites ABOVE the GPU surface, so a full-mode panel
    // would otherwise occlude GPU overlays like the command center. sync() must
    // hide the webview whenever the caller reports a blocking overlay is up.
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

    // No overlay: shown on the owning active tab.
    try std.testing.expect(shouldShowWebview(false));
    // Overlay up: hidden, so the command center shows through.
    try std.testing.expect(!shouldShowWebview(true));

    // Inactive tab stays hidden regardless of the overlay flag.
    active_tab_state.g_active_tab = 1;
    try std.testing.expect(!shouldShowWebview(false));
    try std.testing.expect(!shouldShowWebview(true));
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

    const refresh_info = @typeInfo(@TypeOf(refresh)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), refresh_info.params.len);
}
