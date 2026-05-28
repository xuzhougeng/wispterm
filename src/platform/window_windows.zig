const std = @import("std");
const builtin = @import("builtin");

pub const NativeHandle = if (builtin.os.tag == .windows) std.os.windows.HWND else usize;
pub const MessageId = u32;
pub const WordParam = if (builtin.os.tag == .windows) std.os.windows.WPARAM else usize;
pub const LongParam = if (builtin.os.tag == .windows) std.os.windows.LPARAM else isize;
pub const MessageResult = if (builtin.os.tag == .windows) std.os.windows.LRESULT else isize;
pub const titlebar_height: i32 = 34;
pub const CaptionButton = enum { none, minimize, maximize, close };
pub const caption_button_width: f32 = 46;
pub const caption_icon_color: [3]f32 = .{ 0.75, 0.75, 0.75 };
pub const caption_hover_icon_color: [3]f32 = .{ 1.0, 1.0, 1.0 };
pub const caption_hover_background_delta: f32 = 0.05;
pub const caption_close_hover_background: [3]f32 = .{ 0.77, 0.17, 0.11 };

pub const Rect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const overlapped_window_style: u32 = 0x00CF0000;
pub const frame_changed: u32 = 0x0020;
pub const show_window: u32 = 0x0040;
pub const hotkey_message: MessageId = 0x0312;

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
    return switch (builtin.os.tag) {
        .windows => @ptrFromInt(bits),
        else => bits,
    };
}

pub fn getWindowRect(hwnd: NativeHandle) ?Rect {
    return switch (builtin.os.tag) {
        .windows => {
            var rect: Rect = undefined;
            if (GetWindowRect(hwnd, &rect) == 0) return null;
            return rect;
        },
        else => null,
    };
}

pub fn getClientRect(hwnd: NativeHandle) ?Rect {
    return switch (builtin.os.tag) {
        .windows => {
            var rect: Rect = undefined;
            if (GetClientRect(hwnd, &rect) == 0) return null;
            return rect;
        },
        else => null,
    };
}

pub fn postCloseMessage(hwnd: NativeHandle) bool {
    return postMessage(hwnd, wm_close, 0, 0);
}

pub fn postMessage(hwnd: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) bool {
    return switch (builtin.os.tag) {
        .windows => PostMessageW(hwnd, message, wparam, lparam) != 0,
        else => false,
    };
}

pub fn sendMessage(hwnd: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) MessageResult {
    return switch (builtin.os.tag) {
        .windows => SendMessageW(hwnd, message, wparam, lparam),
        else => 0,
    };
}

pub fn dpiForWindow(hwnd: NativeHandle) u32 {
    return switch (builtin.os.tag) {
        .windows => GetDpiForWindow(hwnd),
        else => 96,
    };
}

pub fn showRestored(hwnd: NativeHandle) bool {
    return show(hwnd, sw_restore);
}

pub fn showMaximized(hwnd: NativeHandle) bool {
    return show(hwnd, sw_maximize);
}

pub fn showVisible(hwnd: NativeHandle) bool {
    return show(hwnd, sw_show);
}

pub fn showHidden(hwnd: NativeHandle) bool {
    return show(hwnd, sw_hide);
}

fn show(hwnd: NativeHandle, command: i32) bool {
    return switch (builtin.os.tag) {
        .windows => ShowWindow(hwnd, command) != 0,
        else => false,
    };
}

pub fn setForeground(hwnd: NativeHandle) bool {
    return switch (builtin.os.tag) {
        .windows => SetForegroundWindow(hwnd) != 0,
        else => false,
    };
}

pub fn isMaximized(hwnd: NativeHandle) bool {
    return switch (builtin.os.tag) {
        .windows => IsZoomed(hwnd) != 0,
        else => false,
    };
}

pub fn getWindowStyle(hwnd: NativeHandle) u32 {
    return switch (builtin.os.tag) {
        .windows => @bitCast(GetWindowLongW(hwnd, gwl_style)),
        else => 0,
    };
}

pub fn setWindowStyle(hwnd: NativeHandle, style: u32) bool {
    return switch (builtin.os.tag) {
        .windows => SetWindowLongW(hwnd, gwl_style, @bitCast(style)) != 0,
        else => false,
    };
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
    return switch (builtin.os.tag) {
        .windows => SetWindowPos(hwnd, null, x, y, width, height, flags) != 0,
        else => false,
    };
}

pub fn setOuterFrame(hwnd: NativeHandle, rect: Rect, topmost: bool) bool {
    return switch (builtin.os.tag) {
        .windows => SetWindowPos(
            hwnd,
            if (topmost) hwnd_topmost else hwnd_notopmost,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            swp_show_window,
        ) != 0,
        else => false,
    };
}

pub fn nearestMonitorRect(hwnd: NativeHandle) ?Rect {
    return switch (builtin.os.tag) {
        .windows => {
            const monitor = MonitorFromWindow(hwnd, monitor_default_to_nearest) orelse return null;
            var mi = MONITORINFO{ .cbSize = @sizeOf(MONITORINFO) };
            if (GetMonitorInfoW(monitor, &mi) == 0) return null;
            return mi.rcMonitor;
        },
        else => null,
    };
}

pub fn nearestMonitorWorkArea(hwnd: NativeHandle) ?Rect {
    return switch (builtin.os.tag) {
        .windows => {
            const monitor = MonitorFromWindow(hwnd, monitor_default_to_nearest) orelse return null;
            var mi = MONITORINFO{ .cbSize = @sizeOf(MONITORINFO) };
            if (GetMonitorInfoW(monitor, &mi) == 0) return null;
            return mi.rcWork;
        },
        else => null,
    };
}

pub fn consumeReopenRequest() bool {
    return false;
}

pub fn consumeQuitRequest() bool {
    return false;
}

pub fn requestQuit() void {}

pub fn pumpAppEvents(timeout_seconds: f64) void {
    _ = timeout_seconds;
}

const wm_close: u32 = 0x0010;
const wm_app: u32 = 0x8000;
const sw_hide: i32 = 0;
const sw_show: i32 = 5;
const sw_restore: i32 = 9;
const sw_maximize: i32 = 3;
const gwl_style: i32 = -16;
const monitor_default_to_nearest: u32 = 0x00000002;
const HMONITOR = *opaque {};
const swp_show_window: u32 = 0x0040;
const hwnd_topmost: std.os.windows.HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const hwnd_notopmost: std.os.windows.HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: Rect = undefined,
    rcWork: Rect = undefined,
    dwFlags: u32 = 0,
};

extern "user32" fn GetWindowRect(
    hWnd: std.os.windows.HWND,
    lpRect: *Rect,
) callconv(.winapi) std.os.windows.BOOL;

extern "user32" fn GetClientRect(
    hWnd: std.os.windows.HWND,
    lpRect: *Rect,
) callconv(.winapi) std.os.windows.BOOL;

extern "user32" fn PostMessageW(
    hWnd: std.os.windows.HWND,
    Msg: u32,
    wParam: std.os.windows.WPARAM,
    lParam: std.os.windows.LPARAM,
) callconv(.winapi) std.os.windows.BOOL;

extern "user32" fn SendMessageW(
    hWnd: std.os.windows.HWND,
    Msg: u32,
    wParam: std.os.windows.WPARAM,
    lParam: std.os.windows.LPARAM,
) callconv(.winapi) std.os.windows.LRESULT;

extern "user32" fn GetDpiForWindow(hWnd: std.os.windows.HWND) callconv(.winapi) u32;

extern "user32" fn IsZoomed(hWnd: std.os.windows.HWND) callconv(.winapi) std.os.windows.BOOL;
extern "user32" fn ShowWindow(hWnd: std.os.windows.HWND, nCmdShow: i32) callconv(.winapi) std.os.windows.BOOL;
extern "user32" fn SetForegroundWindow(hWnd: std.os.windows.HWND) callconv(.winapi) std.os.windows.BOOL;
extern "user32" fn GetWindowLongW(hWnd: std.os.windows.HWND, nIndex: i32) callconv(.winapi) i32;
extern "user32" fn SetWindowLongW(hWnd: std.os.windows.HWND, nIndex: i32, dwNewLong: i32) callconv(.winapi) i32;
extern "user32" fn SetWindowPos(
    hWnd: std.os.windows.HWND,
    hWndInsertAfter: ?std.os.windows.HWND,
    X: i32,
    Y: i32,
    cx: i32,
    cy: i32,
    uFlags: u32,
) callconv(.winapi) std.os.windows.BOOL;
extern "user32" fn MonitorFromWindow(hWnd: std.os.windows.HWND, dwFlags: u32) callconv(.winapi) ?HMONITOR;
extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFO) callconv(.winapi) std.os.windows.BOOL;

test "platform window exposes native handle helpers" {
    const rect_info = @typeInfo(@TypeOf(getWindowRect)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), rect_info.params.len);
    try std.testing.expect(rect_info.params[0].type.? == NativeHandle);
    try std.testing.expect(rect_info.return_type.? == ?Rect);

    const close_info = @typeInfo(@TypeOf(postCloseMessage)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), close_info.params.len);
    try std.testing.expect(close_info.params[0].type.? == NativeHandle);
    try std.testing.expect(close_info.return_type.? == bool);

    const maximized_info = @typeInfo(@TypeOf(isMaximized)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), maximized_info.params.len);
    try std.testing.expect(maximized_info.params[0].type.? == NativeHandle);
    try std.testing.expect(maximized_info.return_type.? == bool);
    try std.testing.expectEqual(@as(i32, 34), titlebar_height);
}

test "platform window exposes native frame and style helpers" {
    try std.testing.expect(@typeInfo(@TypeOf(getClientRect)).@"fn".return_type.? == ?Rect);
    try std.testing.expect(@typeInfo(@TypeOf(showRestored)).@"fn".return_type.? == bool);
    try std.testing.expect(@typeInfo(@TypeOf(showMaximized)).@"fn".return_type.? == bool);
    try std.testing.expect(@typeInfo(@TypeOf(getWindowStyle)).@"fn".return_type.? == u32);
    try std.testing.expect(@typeInfo(@TypeOf(setWindowStyle)).@"fn".return_type.? == bool);
    try std.testing.expect(@typeInfo(@TypeOf(setWindowFrame)).@"fn".return_type.? == bool);
    try std.testing.expect(@typeInfo(@TypeOf(nearestMonitorRect)).@"fn".return_type.? == ?Rect);
}

test "platform window exposes quake window helpers" {
    try std.testing.expect(@typeInfo(@TypeOf(nearestMonitorWorkArea)).@"fn".return_type.? == ?Rect);
    try std.testing.expect(@typeInfo(@TypeOf(showVisible)).@"fn".return_type.? == bool);
    try std.testing.expect(@typeInfo(@TypeOf(showHidden)).@"fn".return_type.? == bool);
    try std.testing.expect(@typeInfo(@TypeOf(setForeground)).@"fn".return_type.? == bool);
    try std.testing.expect(@typeInfo(@TypeOf(setOuterFrame)).@"fn".return_type.? == bool);
}

test "platform window exposes message and dpi helpers" {
    try std.testing.expectEqual(@as(MessageId, 0x8000 + 0x51), appMessage(0x51));
    try std.testing.expectEqual(@as(MessageId, 0x0312), hotkey_message);
    try std.testing.expect(@typeInfo(@TypeOf(postMessage)).@"fn".return_type.? == bool);
    try std.testing.expect(@typeInfo(@TypeOf(sendMessage)).@"fn".return_type.? == MessageResult);
    try std.testing.expect(@typeInfo(@TypeOf(dpiForWindow)).@"fn".return_type.? == u32);
    try std.testing.expectEqual(@as(LongParam, @bitCast(@as(isize, 42))), longParamFromPtrValue(42));
    try std.testing.expectEqual(@as(usize, 42), ptrValueFromLongParam(longParamFromPtrValue(42)));
}
