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

/// Reserved message id for the synchronous-send shim (see `sendMessage`).
/// Distinct from the app-message range thread_message uses (wm_app + 0x51..0x57)
/// and from `hotkey_message`, so it never collides with a real posted message.
pub const sync_message: MessageId = wm_app + 0x7e;

extern fn wispterm_macos_window_request_close(handle: NativeHandle) void;
extern fn wispterm_macos_window_post_message(handle: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) bool;
extern fn wispterm_macos_window_get_frame(handle: NativeHandle, rect: *Rect) bool;
extern fn wispterm_macos_window_get_content_frame(handle: NativeHandle, rect: *Rect) bool;
extern fn wispterm_macos_window_dpi(handle: NativeHandle) u32;
extern fn wispterm_macos_window_show(handle: NativeHandle) void;
extern fn wispterm_macos_window_hide(handle: NativeHandle) void;
extern fn wispterm_macos_window_make_key(handle: NativeHandle) void;
extern fn wispterm_macos_window_is_zoomed(handle: NativeHandle) bool;
extern fn wispterm_macos_window_zoom(handle: NativeHandle) void;
extern fn wispterm_macos_window_set_frame(handle: NativeHandle, x: i32, y: i32, width: i32, height: i32) bool;
extern fn wispterm_macos_window_nearest_monitor_frame(handle: NativeHandle, rect: *Rect) bool;
extern fn wispterm_macos_window_nearest_monitor_work_area(handle: NativeHandle, rect: *Rect) bool;
extern fn wispterm_macos_app_consume_reopen() bool;
extern fn wispterm_macos_app_consume_quit() bool;
extern fn wispterm_macos_app_request_quit() void;
extern fn wispterm_macos_app_pump_events(timeout_seconds: f64) void;
extern fn wispterm_macos_post_wakeup() void;

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
    if (!wispterm_macos_window_get_frame(hwnd, &rect)) return null;
    return rect;
}

pub fn getClientRect(hwnd: NativeHandle) ?Rect {
    var rect: Rect = undefined;
    if (!wispterm_macos_window_get_content_frame(hwnd, &rect)) return null;
    return rect;
}

pub fn postCloseMessage(hwnd: NativeHandle) bool {
    wispterm_macos_window_request_close(hwnd);
    return true;
}

pub fn postMessage(hwnd: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) bool {
    if (message == wm_close) return postCloseMessage(hwnd);
    return wispterm_macos_window_post_message(hwnd, message, wparam, lparam);
}

/// Wall-clock cap for a blocked `sendMessage` caller. A backstop only: the
/// window's event loop drains its message queue every frame, so a live window
/// answers within ~1 frame. The cap bounds the wait if the target window is
/// tearing down (its native handle is published as 0 first, so callers normally
/// skip this path) or if the bounded message queue ever overflowed the request.
const send_message_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// Cross-thread synchronous-call envelope used to emulate Win32 `SendMessage`
/// on macOS. `sendMessage` posts one of these through the normal async message
/// queue and blocks until the window's event-loop thread drains it, runs the
/// real handler on that thread (where the threadlocal UI state lives), records
/// the result, and signals `done`.
///
/// Heap-owned and reference counted (init 2: caller + worker) so that a
/// timed-out caller and the later-draining worker never use-after-free: each
/// side releases its reference once and the last release frees the envelope.
pub const SyncCall = struct {
    message: MessageId,
    wparam: WordParam,
    lparam: LongParam,
    result: MessageResult = 0,
    done: std.Thread.ResetEvent = .{},
    refs: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),
};

pub fn syncCallFromLparam(lparam: LongParam) *SyncCall {
    return @ptrFromInt(ptrValueFromLongParam(lparam));
}

fn releaseSyncCall(call: *SyncCall) void {
    if (call.refs.fetchSub(1, .acq_rel) == 1) {
        std.heap.page_allocator.destroy(call);
    }
}

/// Event-loop side: called by the window backend's message drain when it pops a
/// `sync_message`. Records the handler's result, wakes the blocked caller, and
/// drops the worker's reference.
pub fn completeSyncCall(call: *SyncCall, result: MessageResult) void {
    call.result = result;
    call.done.set();
    releaseSyncCall(call);
}

/// Synchronous cross-thread message dispatch. AppKit has no Win32-style
/// `SendMessage`, so this marshals the message onto the window's event-loop
/// thread (via the async queue) and blocks until that thread runs the handler
/// and reports back. Must be called from another thread than the event loop;
/// every in-tree caller does (weixin poller, remote client, AI tool host's
/// cross-window path), guarded by the same-thread checks at their call sites.
pub fn sendMessage(hwnd: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) MessageResult {
    if (message == wm_close) {
        _ = postCloseMessage(hwnd);
        return 0;
    }
    const call = std.heap.page_allocator.create(SyncCall) catch return 0;
    call.* = .{ .message = message, .wparam = wparam, .lparam = lparam };
    if (!wispterm_macos_window_post_message(hwnd, sync_message, 0, longParamFromPtrValue(@intFromPtr(call)))) {
        // Never queued, so the event loop will never touch it: drop both refs.
        releaseSyncCall(call);
        releaseSyncCall(call);
        return 0;
    }
    const result: MessageResult = if (call.done.timedWait(send_message_timeout_ns)) |_|
        call.result
    else |_|
        0;
    releaseSyncCall(call);
    return result;
}

pub fn dpiForWindow(hwnd: NativeHandle) u32 {
    return wispterm_macos_window_dpi(hwnd);
}

pub fn showRestored(hwnd: NativeHandle) bool {
    if (wispterm_macos_window_is_zoomed(hwnd)) wispterm_macos_window_zoom(hwnd);
    wispterm_macos_window_show(hwnd);
    return true;
}

pub fn showMaximized(hwnd: NativeHandle) bool {
    if (!wispterm_macos_window_is_zoomed(hwnd)) wispterm_macos_window_zoom(hwnd);
    return true;
}

pub fn showVisible(hwnd: NativeHandle) bool {
    wispterm_macos_window_show(hwnd);
    return true;
}

pub fn showHidden(hwnd: NativeHandle) bool {
    wispterm_macos_window_hide(hwnd);
    return true;
}

pub fn setForeground(hwnd: NativeHandle) bool {
    wispterm_macos_window_make_key(hwnd);
    return true;
}

pub fn isMaximized(hwnd: NativeHandle) bool {
    return wispterm_macos_window_is_zoomed(hwnd);
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
    return wispterm_macos_window_set_frame(hwnd, x, y, width, height);
}

pub fn setOuterFrame(hwnd: NativeHandle, rect: Rect, topmost: bool) bool {
    _ = topmost;
    return setWindowFrame(hwnd, rect, 0);
}

pub fn nearestMonitorRect(hwnd: NativeHandle) ?Rect {
    var rect: Rect = undefined;
    if (!wispterm_macos_window_nearest_monitor_frame(hwnd, &rect)) return null;
    return rect;
}

pub fn nearestMonitorWorkArea(hwnd: NativeHandle) ?Rect {
    var rect: Rect = undefined;
    if (!wispterm_macos_window_nearest_monitor_work_area(hwnd, &rect)) return null;
    return rect;
}

pub fn consumeReopenRequest() bool {
    return wispterm_macos_app_consume_reopen();
}

pub fn consumeQuitRequest() bool {
    return wispterm_macos_app_consume_quit();
}

pub fn requestQuit() void {
    wispterm_macos_app_request_quit();
}

/// Pump pending NSApp events; blocks up to `timeout_seconds` waiting for the
/// first event so the main thread's run loop also drains the GCD main queue
/// (needed for worker-thread dispatch_sync to the main thread). On worker
/// threads (every window past the first) this must not touch NSApp — AppKit
/// throws off-main — so the bridge instead blocks on a wakeup condition that
/// input pushes, close requests, and postWakeup() signal.
pub fn pumpAppEvents(timeout_seconds: f64) void {
    wispterm_macos_app_pump_events(timeout_seconds);
}

/// 从任意线程唤醒阻塞中的事件泵：主线程的 NSApp 泵和 worker 窗口的条件等待都会被唤醒。
pub fn postWakeup() void {
    wispterm_macos_post_wakeup();
}

pub fn registerEventWindow(hwnd: NativeHandle) void {
    _ = hwnd;
}

pub fn unregisterEventWindow(hwnd: NativeHandle) void {
    _ = hwnd;
}

test "macOS window constants defer caption controls to AppKit" {
    try std.testing.expectEqual(@as(i32, 0), titlebar_height);
    try std.testing.expectEqual(@as(f32, 0), caption_button_width);
    try std.testing.expectEqual(@as(MessageId, wm_app + 7), appMessage(7));
}
