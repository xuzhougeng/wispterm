const std = @import("std");

pub const NativeHandle = *anyopaque;
pub const MessageId = u32;
pub const WordParam = usize;
pub const LongParam = isize;
pub const MessageResult = isize;
pub const titlebar_height: i32 = 0;
pub const CaptionButton = enum { none, minimize, maximize, close };
pub const caption_button_width: f32 = 0;
pub const caption_icon_color: [3]f32 = .{ 0, 0, 0 };
pub const caption_hover_icon_color: [3]f32 = .{ 0, 0, 0 };
pub const caption_hover_background_delta: f32 = 0;
pub const caption_close_hover_background: [3]f32 = .{ 0, 0, 0 };

pub const Rect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const overlapped_window_style: u32 = 0;
pub const frame_changed: u32 = 0;
pub const show_window: u32 = 0;
pub const hotkey_message: MessageId = 0x0312;

const wm_close: u32 = 0x0010;
const wm_app: u32 = 0x8000;

extern fn phantty_macos_window_request_close(handle: NativeHandle) void;
extern fn phantty_macos_window_post_message(handle: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) bool;
extern fn phantty_macos_window_get_frame(handle: NativeHandle, rect: *Rect) bool;
extern fn phantty_macos_window_get_content_frame(handle: NativeHandle, rect: *Rect) bool;
extern fn phantty_macos_window_dpi(handle: NativeHandle) u32;
extern fn phantty_macos_window_show(handle: NativeHandle) void;
extern fn phantty_macos_window_hide(handle: NativeHandle) void;
extern fn phantty_macos_window_make_key(handle: NativeHandle) void;
extern fn phantty_macos_window_is_zoomed(handle: NativeHandle) bool;
extern fn phantty_macos_window_zoom(handle: NativeHandle) void;
extern fn phantty_macos_window_set_frame(handle: NativeHandle, x: i32, y: i32, width: i32, height: i32) bool;
extern fn phantty_macos_window_nearest_monitor_frame(handle: NativeHandle, rect: *Rect) bool;
extern fn phantty_macos_window_nearest_monitor_work_area(handle: NativeHandle, rect: *Rect) bool;
extern fn phantty_macos_app_consume_reopen() bool;
extern fn phantty_macos_app_consume_quit() bool;
extern fn phantty_macos_app_request_quit() void;
extern fn phantty_macos_app_pump_events(timeout_seconds: f64) void;

pub fn appMessage(offset: u32) MessageId {
    return wm_app + offset;
}

pub fn longParamFromPtrValue(value: usize) LongParam {
    return @bitCast(@as(isize, @intCast(value)));
}

pub fn ptrValueFromLongParam(value: LongParam) usize {
    return @as(usize, @bitCast(value));
}

pub fn nativeHandleFromBits(bits: usize) ?NativeHandle {
    if (bits == 0) return null;
    return @ptrFromInt(bits);
}

pub fn getWindowRect(hwnd: NativeHandle) ?Rect {
    var rect: Rect = undefined;
    if (!phantty_macos_window_get_frame(hwnd, &rect)) return null;
    return rect;
}

pub fn getClientRect(hwnd: NativeHandle) ?Rect {
    var rect: Rect = undefined;
    if (!phantty_macos_window_get_content_frame(hwnd, &rect)) return null;
    return rect;
}

pub fn postCloseMessage(hwnd: NativeHandle) bool {
    phantty_macos_window_request_close(hwnd);
    return true;
}

pub fn postMessage(hwnd: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) bool {
    if (message == wm_close) return postCloseMessage(hwnd);
    return phantty_macos_window_post_message(hwnd, message, wparam, lparam);
}

pub fn sendMessage(hwnd: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) MessageResult {
    _ = hwnd;
    _ = message;
    _ = wparam;
    _ = lparam;
    return 0;
}

pub fn dpiForWindow(hwnd: NativeHandle) u32 {
    return phantty_macos_window_dpi(hwnd);
}

pub fn showRestored(hwnd: NativeHandle) bool {
    if (phantty_macos_window_is_zoomed(hwnd)) phantty_macos_window_zoom(hwnd);
    phantty_macos_window_show(hwnd);
    return true;
}

pub fn showMaximized(hwnd: NativeHandle) bool {
    if (!phantty_macos_window_is_zoomed(hwnd)) phantty_macos_window_zoom(hwnd);
    return true;
}

pub fn showVisible(hwnd: NativeHandle) bool {
    phantty_macos_window_show(hwnd);
    return true;
}

pub fn showHidden(hwnd: NativeHandle) bool {
    phantty_macos_window_hide(hwnd);
    return true;
}

pub fn setForeground(hwnd: NativeHandle) bool {
    phantty_macos_window_make_key(hwnd);
    return true;
}

pub fn isMaximized(hwnd: NativeHandle) bool {
    return phantty_macos_window_is_zoomed(hwnd);
}

pub fn getWindowStyle(hwnd: NativeHandle) u32 {
    _ = hwnd;
    return 0;
}

pub fn setWindowStyle(hwnd: NativeHandle, style: u32) bool {
    _ = hwnd;
    _ = style;
    return true;
}

pub fn setWindowFrame(hwnd: NativeHandle, rect: Rect, flags: u32) bool {
    return setWindowFrameRaw(
        hwnd,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        flags,
    );
}

pub fn setWindowFrameRaw(hwnd: NativeHandle, x: i32, y: i32, width: i32, height: i32, flags: u32) bool {
    _ = flags;
    return phantty_macos_window_set_frame(hwnd, x, y, width, height);
}

pub fn setOuterFrame(hwnd: NativeHandle, rect: Rect, topmost: bool) bool {
    _ = topmost;
    return setWindowFrame(hwnd, rect, 0);
}

pub fn nearestMonitorRect(hwnd: NativeHandle) ?Rect {
    var rect: Rect = undefined;
    if (!phantty_macos_window_nearest_monitor_frame(hwnd, &rect)) return null;
    return rect;
}

pub fn nearestMonitorWorkArea(hwnd: NativeHandle) ?Rect {
    var rect: Rect = undefined;
    if (!phantty_macos_window_nearest_monitor_work_area(hwnd, &rect)) return null;
    return rect;
}

pub fn consumeReopenRequest() bool {
    return phantty_macos_app_consume_reopen();
}

pub fn consumeQuitRequest() bool {
    return phantty_macos_app_consume_quit();
}

pub fn requestQuit() void {
    phantty_macos_app_request_quit();
}

/// Pump pending NSApp events; blocks up to `timeout_seconds` waiting for the
/// first event so the main thread's run loop also drains the GCD main queue
/// (needed for worker-thread dispatch_sync to the main thread).
pub fn pumpAppEvents(timeout_seconds: f64) void {
    phantty_macos_app_pump_events(timeout_seconds);
}

test "macOS window constants defer caption controls to AppKit" {
    try std.testing.expectEqual(@as(i32, 0), titlebar_height);
    try std.testing.expectEqual(@as(f32, 0), caption_button_width);
    try std.testing.expectEqual(@as(MessageId, wm_app + 7), appMessage(7));
}
