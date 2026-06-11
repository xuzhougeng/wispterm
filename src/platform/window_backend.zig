const std = @import("std");
const builtin = @import("builtin");
const platform_input = @import("input_events.zig");
const platform_window = @import("window.zig");

pub const Backend = enum {
    windows,
    macos,
    linux,
    unsupported,
};

pub fn backendForOs(comptime os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .macos => .macos,
        .linux => .linux,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("window_backend_windows.zig"),
    .macos => @import("window_backend_macos.zig"),
    .linux => @import("window_backend_linux.zig"),
    .unsupported => @import("window_backend_unsupported.zig"),
};

pub const Window = impl.Window;
pub const NativeHandle = platform_window.NativeHandle;
pub const MessageId = platform_window.MessageId;
pub const WordParam = platform_window.WordParam;
pub const LongParam = platform_window.LongParam;
pub const MessageResult = platform_window.MessageResult;

pub const Size = struct {
    width: i32,
    height: i32,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const CaptionButton = platform_window.CaptionButton;
pub const CaptionButtonVisualStyle = platform_window.CaptionButtonVisualStyle;
pub const caption_button_visual_style = platform_window.caption_button_visual_style;

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const FullscreenRestoreState = struct {
    rect: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    style: u32 = 0,
};

pub const CreateOptions = struct {
    width: i32,
    height: i32,
    title: []const u8,
    x: ?i32 = null,
    y: ?i32 = null,
    maximize: bool = false,
};

pub const ResizeCallback = *const fn (width: i32, height: i32) void;
pub const MessageCallback = *const fn (
    message: MessageId,
    wparam: WordParam,
    lparam: LongParam,
) ?MessageResult;
pub const FileDropHandler = impl.FileDropHandler;

pub const EventHandlers = struct {
    on_resize: ?ResizeCallback = null,
    on_message: ?MessageCallback = null,
    on_file_drop: ?FileDropHandler = null,
};

pub const setGlobalWindow = impl.setGlobalWindow;

/// Windows-only config gate for the DXGI flip-model present path
/// (`wispterm-d3d-present`). No-op on backends without the seam.
pub fn setFlipPresentEnabled(enabled: bool) void {
    if (comptime @hasDecl(impl, "setFlipPresentEnabled")) impl.setFlipPresentEnabled(enabled);
}
/// Renderer surface seam (host → GPU backend). This is OpenGL-shaped: the host
/// supplies a GL proc-address loader, which `gpu.Context.init` consumes. The
/// seam is per-backend by design — a macOS/AppKit host pairs with the Metal
/// backend and hands `gpu.Context.init` a `CAMetalLayer` instead (see the
/// surface-seam note in `gpu/metal/Context.zig`); it does not call this.
pub const glGetProcAddress = impl.glGetProcAddress;

pub fn create(allocator: std.mem.Allocator, options: CreateOptions) !Window {
    const title_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, options.title);
    defer allocator.free(title_w);
    return Window.init(
        options.width,
        options.height,
        title_w.ptr,
        options.x,
        options.y,
        options.maximize,
    );
}

pub fn setEventHandlers(window: *Window, handlers: EventHandlers) void {
    window.on_resize = handlers.on_resize;
    window.on_message = handlers.on_message;
    window.on_file_drop = handlers.on_file_drop;
}

pub fn appMessage(offset: u32) MessageId {
    return platform_window.appMessage(offset);
}

pub fn longParamFromPtrValue(value: usize) LongParam {
    return platform_window.longParamFromPtrValue(value);
}

pub fn ptrValueFromLongParam(value: LongParam) usize {
    return platform_window.ptrValueFromLongParam(value);
}

pub fn postCloseMessage(handle: NativeHandle) bool {
    return platform_window.postCloseMessage(handle);
}

pub fn postMessage(handle: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) bool {
    return platform_window.postMessage(handle, message, wparam, lparam);
}

pub fn sendMessage(handle: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) MessageResult {
    return platform_window.sendMessage(handle, message, wparam, lparam);
}

pub fn isHotkeyMessage(message: MessageId, wparam: WordParam, hotkey_id: i32) bool {
    return message == platform_window.hotkey_message and wparam == @as(WordParam, @intCast(hotkey_id));
}

pub fn nativeHandleFromBits(bits: usize) ?NativeHandle {
    return platform_window.nativeHandleFromBits(bits);
}

pub fn nativeHandle(window: *Window) NativeHandle {
    if (comptime backendForOs(builtin.os.tag) == .unsupported) {
        return nativeHandleBits(window);
    }
    return window.hwnd;
}

pub fn nativeHandleBits(window: *Window) usize {
    return @intFromPtr(window.hwnd);
}

pub fn metalLayer(window: *Window) ?*anyopaque {
    return if (@hasDecl(impl, "metalLayer")) impl.metalLayer(window) else null;
}

pub fn destroy(window: *Window) void {
    window.deinit();
}

pub fn pollEvents(window: *Window) bool {
    return window.pollEvents();
}

pub fn swapBuffers(window: *Window) void {
    window.swapBuffers();
}

pub fn framebufferSize(window: *Window) Size {
    const size = window.getFramebufferSize();
    return .{ .width = size.width, .height = size.height };
}

pub fn resizeClientArea(window: *Window, width: i32, height: i32) void {
    window.setSize(width, height);
}

pub fn setImeCaret(window: *Window, x: i32, y: i32, height: i32) void {
    window.setImeCaret(x, y, height);
}

pub fn imePreeditText(window: *const Window) []const u8 {
    return window.imePreeditText();
}

pub fn clientSize(window: *const Window) Size {
    return .{ .width = window.width, .height = window.height };
}

fn rectFromPlatform(rect: platform_window.Rect) Rect {
    return .{
        .left = rect.left,
        .top = rect.top,
        .right = rect.right,
        .bottom = rect.bottom,
    };
}

fn rectToPlatform(rect: Rect) platform_window.Rect {
    return .{
        .left = rect.left,
        .top = rect.top,
        .right = rect.right,
        .bottom = rect.bottom,
    };
}

pub fn clientRect(window: *Window) ?Rect {
    const rect = platform_window.getClientRect(nativeHandle(window)) orelse return null;
    return rectFromPlatform(rect);
}

pub fn windowRectForNativeHandle(handle: NativeHandle) ?Rect {
    const rect = platform_window.getWindowRect(handle) orelse return null;
    return rectFromPlatform(rect);
}

pub fn windowRect(window: *Window) ?Rect {
    return windowRectForNativeHandle(nativeHandle(window));
}

pub fn nearestMonitorWorkArea(window: *Window) ?Rect {
    const rect = platform_window.nearestMonitorWorkArea(nativeHandle(window)) orelse return null;
    return rectFromPlatform(rect);
}

pub fn setOuterFrame(window: *Window, rect: Rect, topmost: bool) bool {
    return platform_window.setOuterFrame(nativeHandle(window), rectToPlatform(rect), topmost);
}

/// macOS-only: returns true if the user clicked the Dock icon while no window
/// was visible (NSApplicationDelegate.applicationShouldHandleReopen). Other
/// platforms return false.
pub fn consumeReopenRequest() bool {
    return platform_window.consumeReopenRequest();
}

/// macOS-only: returns true if the user invoked Quit (cmd+Q or menu) and the
/// app should tear down. Other platforms return false.
pub fn consumeQuitRequest() bool {
    return platform_window.consumeQuitRequest();
}

/// macOS-only: signal the idle loop that the app should quit (used when zig
/// initiates a quit, e.g. from a menu handler). No-op elsewhere.
pub fn requestQuit() void {
    platform_window.requestQuit();
}

/// macOS-only: pump pending NSApp events without owning a window — needed by
/// the idle loop in App.run() so AppDelegate callbacks (Dock reopen, cmd+Q)
/// keep firing between window sessions. `timeout_seconds` is the max time the
/// main thread will block waiting for an event (also drains the GCD main
/// queue, which worker threads use to marshal NSWindow modifications back to
/// the main thread). No-op elsewhere.
pub fn pumpAppEvents(timeout_seconds: f64) void {
    platform_window.pumpAppEvents(timeout_seconds);
}

/// 从任意线程唤醒阻塞中的主线程事件泵（app 级，无需 window 句柄）。
pub fn postWakeup() void {
    platform_window.postWakeup();
}

pub fn refreshClientSizeFromNative(window: *Window) bool {
    const rect = clientRect(window) orelse return false;
    setClientSize(window, rect.right - rect.left, rect.bottom - rect.top);
    return true;
}

pub fn setClientSize(window: *Window, width: i32, height: i32) void {
    window.width = width;
    window.height = height;
}

pub fn dpi(window: *const Window) u32 {
    return window.dpi;
}

pub fn dpiForNativeHandle(handle: NativeHandle) u32 {
    return platform_window.dpiForWindow(handle);
}

pub fn effectiveDpi(window: *Window) u32 {
    const current_dpi = dpi(window);
    return if (current_dpi == 0) dpiForNativeHandle(nativeHandle(window)) else current_dpi;
}

pub fn titlebarHeight(window: *const Window) i32 {
    return window.titlebar_height;
}

pub fn titlebarBaseHeight() i32 {
    return platform_window.titlebar_height;
}

pub fn setTitlebarHeight(window: *Window, height: i32) void {
    window.titlebar_height = height;
}

pub fn setSidebarWidth(window: *Window, width: i32) void {
    window.sidebar_width = width;
}

pub fn setTabCount(window: *Window, count: usize) void {
    window.tab_count = count;
}

pub fn mousePosition(window: *const Window) Point {
    return .{ .x = window.mouse_x, .y = window.mouse_y };
}

pub fn hoveredCaptionButton(window: *const Window) CaptionButton {
    return window.hovered_button;
}

pub fn setTabCloseButtonBounds(window: *Window, tab_index: usize, start_x: i32, end_x: i32) void {
    window.close_btn_x_start[tab_index] = start_x;
    window.close_btn_x_end[tab_index] = end_x;
}

pub fn setNewTabButtonBounds(window: *Window, start_x: i32, end_x: i32) void {
    window.plus_btn_x_start = start_x;
    window.plus_btn_x_end = end_x;
}

pub fn isFocused(window: *const Window) bool {
    return window.focused;
}

pub fn isVisible(window: *Window) bool {
    return window.isVisible();
}

pub fn isMinimized(window: *const Window) bool {
    return window.is_minimized;
}

pub fn isFullscreen(window: *const Window) bool {
    return window.is_fullscreen;
}

pub fn setFullscreen(window: *Window, fullscreen: bool) void {
    window.is_fullscreen = fullscreen;
}

pub fn showVisible(window: *Window) bool {
    return platform_window.showVisible(nativeHandle(window));
}

pub fn showHidden(window: *Window) bool {
    return platform_window.showHidden(nativeHandle(window));
}

pub fn setForeground(window: *Window) bool {
    return platform_window.setForeground(nativeHandle(window));
}

pub fn isMaximized(window: *Window) bool {
    return platform_window.isMaximized(nativeHandle(window));
}

pub fn toggleMaximized(window: *Window) void {
    const handle = nativeHandle(window);
    if (platform_window.isMaximized(handle)) {
        _ = platform_window.showRestored(handle);
    } else {
        _ = platform_window.showMaximized(handle);
    }
}

pub fn enterBorderlessFullscreen(window: *Window, restore: *FullscreenRestoreState) bool {
    const handle = nativeHandle(window);
    const rect = platform_window.getWindowRect(handle) orelse return false;
    const monitor_rect = platform_window.nearestMonitorRect(handle) orelse return false;
    restore.* = .{
        .rect = rectFromPlatform(rect),
        .style = platform_window.getWindowStyle(handle),
    };

    // Mark fullscreen before the style/frame change: setWindowStyle/setWindowFrame
    // dispatch WM_NCCALCSIZE + WM_SIZE synchronously, and those handlers branch on
    // is_fullscreen (e.g. the maximized border inset must be skipped in fullscreen).
    setFullscreen(window, true);
    const new_style = restore.style & ~platform_window.overlapped_window_style;
    _ = platform_window.setWindowStyle(handle, new_style);
    _ = platform_window.setWindowFrame(
        handle,
        monitor_rect,
        platform_window.frame_changed | platform_window.show_window,
    );
    return true;
}

pub fn exitBorderlessFullscreen(window: *Window, restore: FullscreenRestoreState) void {
    const handle = nativeHandle(window);
    // Clear fullscreen first so the synchronous WM_NCCALCSIZE/WM_SIZE from the
    // restore below see windowed state (e.g. re-apply the maximized border inset).
    setFullscreen(window, false);
    _ = platform_window.setWindowStyle(handle, restore.style);
    _ = platform_window.setWindowFrame(
        handle,
        rectToPlatform(restore.rect),
        platform_window.frame_changed | platform_window.show_window,
    );
}

pub fn markVisibleAndSizeChanged(window: *Window) void {
    window.is_minimized = false;
    window.size_changed = true;
}

pub fn closeRequested(window: *const Window) bool {
    return window.close_requested;
}

pub fn clearCloseRequested(window: *Window) void {
    window.close_requested = false;
}

fn closeRequestPromptsConfirmationForBackend(backend: Backend) bool {
    // macOS follows traffic-light semantics: the red close button tears down
    // this window immediately with no in-app prompt, and closing the last
    // window does not end the process — App.run() keeps the NSApp alive so the
    // Dock icon can re-open a window. Other backends confirm before closing.
    return backend != .macos;
}

/// Whether an OS window-close request should open an in-app confirmation prompt
/// before the window is torn down, instead of closing immediately.
pub fn closeRequestPromptsConfirmation() bool {
    return closeRequestPromptsConfirmationForBackend(comptime backendForOs(builtin.os.tag));
}

pub fn consumeDpiChanged(window: *Window) bool {
    const changed = window.dpi_changed;
    window.dpi_changed = false;
    return changed;
}

pub fn consumeSizeChanged(window: *Window) bool {
    const changed = window.size_changed;
    window.size_changed = false;
    return changed;
}

pub fn clearTransientInput(window: *Window) void {
    window.clearTransientInputQueues();
}

pub fn popKeyEvent(window: *Window) ?platform_input.KeyEvent {
    return window.key_events.pop();
}

pub fn popCharEvent(window: *Window) ?platform_input.CharEvent {
    return window.char_events.pop();
}

pub fn popMouseButtonEvent(window: *Window) ?platform_input.MouseButtonEvent {
    return window.mouse_button_events.pop();
}

pub fn popMouseMoveEvent(window: *Window) ?platform_input.MouseMoveEvent {
    return window.mouse_move_events.pop();
}

pub fn popMouseWheelEvent(window: *Window) ?platform_input.MouseWheelEvent {
    return window.mouse_wheel_events.pop();
}

test "platform window backend exposes backend-neutral window operations" {
    const framebuffer_info = @typeInfo(@TypeOf(framebufferSize)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), framebuffer_info.params.len);
    try std.testing.expect(framebuffer_info.params[0].type.? == *Window);
    try std.testing.expect(framebuffer_info.return_type.? == Size);

    const resize_info = @typeInfo(@TypeOf(resizeClientArea)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), resize_info.params.len);
    try std.testing.expect(resize_info.params[0].type.? == *Window);
    try std.testing.expect(resize_info.params[1].type.? == i32);
    try std.testing.expect(resize_info.params[2].type.? == i32);
    try std.testing.expect(resize_info.return_type.? == void);

    const poll_info = @typeInfo(@TypeOf(pollEvents)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), poll_info.params.len);
    try std.testing.expect(poll_info.params[0].type.? == *Window);
    try std.testing.expect(poll_info.return_type.? == bool);

    const ime_text_info = @typeInfo(@TypeOf(imePreeditText)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), ime_text_info.params.len);
    try std.testing.expect(ime_text_info.params[0].type.? == *const Window);
    try std.testing.expect(ime_text_info.return_type.? == []const u8);
}

test "platform window backend exposes backend-neutral input event queues" {
    const queue_accessors = .{
        .{ popKeyEvent, ?platform_input.KeyEvent },
        .{ popCharEvent, ?platform_input.CharEvent },
        .{ popMouseButtonEvent, ?platform_input.MouseButtonEvent },
        .{ popMouseMoveEvent, ?platform_input.MouseMoveEvent },
        .{ popMouseWheelEvent, ?platform_input.MouseWheelEvent },
    };

    inline for (queue_accessors) |entry| {
        const info = @typeInfo(@TypeOf(entry[0])).@"fn";
        try std.testing.expectEqual(@as(usize, 1), info.params.len);
        try std.testing.expect(info.params[0].type.? == *Window);
        try std.testing.expect(info.return_type.? == entry[1]);
    }

    const clear_info = @typeInfo(@TypeOf(clearTransientInput)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), clear_info.params.len);
    try std.testing.expect(clear_info.params[0].type.? == *Window);
    try std.testing.expect(clear_info.return_type.? == void);
}

test "platform window backend exposes backend-neutral window state accessors" {
    const client_info = @typeInfo(@TypeOf(clientSize)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), client_info.params.len);
    try std.testing.expect(client_info.params[0].type.? == *const Window);
    try std.testing.expect(client_info.return_type.? == Size);

    const bool_accessors = .{
        isFocused,
        isMinimized,
        isFullscreen,
        closeRequested,
        consumeDpiChanged,
        consumeSizeChanged,
    };
    inline for (bool_accessors) |accessor| {
        const info = @typeInfo(@TypeOf(accessor)).@"fn";
        try std.testing.expectEqual(@as(usize, 1), info.params.len);
        try std.testing.expect(info.params[0].type.? == *const Window or info.params[0].type.? == *Window);
        try std.testing.expect(info.return_type.? == bool);
    }

    const set_fullscreen_info = @typeInfo(@TypeOf(setFullscreen)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), set_fullscreen_info.params.len);
    try std.testing.expect(set_fullscreen_info.params[0].type.? == *Window);
    try std.testing.expect(set_fullscreen_info.params[1].type.? == bool);
    try std.testing.expect(set_fullscreen_info.return_type.? == void);

    const mark_visible_info = @typeInfo(@TypeOf(markVisibleAndSizeChanged)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), mark_visible_info.params.len);
    try std.testing.expect(mark_visible_info.params[0].type.? == *Window);
    try std.testing.expect(mark_visible_info.return_type.? == void);
}

test "platform window backend exposes backend-neutral native window state operations" {
    const client_rect_info = @typeInfo(@TypeOf(clientRect)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), client_rect_info.params.len);
    try std.testing.expect(client_rect_info.params[0].type.? == *Window);
    try std.testing.expect(client_rect_info.return_type.? == ?Rect);

    const maximized_info = @typeInfo(@TypeOf(isMaximized)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), maximized_info.params.len);
    try std.testing.expect(maximized_info.params[0].type.? == *Window);
    try std.testing.expect(maximized_info.return_type.? == bool);

    const toggle_maximize_info = @typeInfo(@TypeOf(toggleMaximized)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), toggle_maximize_info.params.len);
    try std.testing.expect(toggle_maximize_info.params[0].type.? == *Window);
    try std.testing.expect(toggle_maximize_info.return_type.? == void);

    const enter_info = @typeInfo(@TypeOf(enterBorderlessFullscreen)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), enter_info.params.len);
    try std.testing.expect(enter_info.params[0].type.? == *Window);
    try std.testing.expect(enter_info.params[1].type.? == *FullscreenRestoreState);
    try std.testing.expect(enter_info.return_type.? == bool);

    const exit_info = @typeInfo(@TypeOf(exitBorderlessFullscreen)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), exit_info.params.len);
    try std.testing.expect(exit_info.params[0].type.? == *Window);
    try std.testing.expect(exit_info.params[1].type.? == FullscreenRestoreState);
    try std.testing.expect(exit_info.return_type.? == void);
}

test "platform window backend exposes backend-neutral native geometry operations" {
    const native_rect_info = @typeInfo(@TypeOf(windowRectForNativeHandle)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), native_rect_info.params.len);
    try std.testing.expect(native_rect_info.params[0].type.? == NativeHandle);
    try std.testing.expect(native_rect_info.return_type.? == ?Rect);

    const window_rect_info = @typeInfo(@TypeOf(windowRect)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), window_rect_info.params.len);
    try std.testing.expect(window_rect_info.params[0].type.? == *Window);
    try std.testing.expect(window_rect_info.return_type.? == ?Rect);

    const work_area_info = @typeInfo(@TypeOf(nearestMonitorWorkArea)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), work_area_info.params.len);
    try std.testing.expect(work_area_info.params[0].type.? == *Window);
    try std.testing.expect(work_area_info.return_type.? == ?Rect);

    const outer_frame_info = @typeInfo(@TypeOf(setOuterFrame)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), outer_frame_info.params.len);
    try std.testing.expect(outer_frame_info.params[0].type.? == *Window);
    try std.testing.expect(outer_frame_info.params[1].type.? == Rect);
    try std.testing.expect(outer_frame_info.params[2].type.? == bool);
    try std.testing.expect(outer_frame_info.return_type.? == bool);

    const refresh_info = @typeInfo(@TypeOf(refreshClientSizeFromNative)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), refresh_info.params.len);
    try std.testing.expect(refresh_info.params[0].type.? == *Window);
    try std.testing.expect(refresh_info.return_type.? == bool);
}

test "platform window backend exposes backend-neutral visibility operations" {
    const visibility_ops = .{ showVisible, showHidden, setForeground };
    inline for (visibility_ops) |op| {
        const info = @typeInfo(@TypeOf(op)).@"fn";
        try std.testing.expectEqual(@as(usize, 1), info.params.len);
        try std.testing.expect(info.params[0].type.? == *Window);
        try std.testing.expect(info.return_type.? == bool);
    }
}

test "platform window backend exposes backend-neutral message operations" {
    const app_message_info = @typeInfo(@TypeOf(appMessage)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), app_message_info.params.len);
    try std.testing.expect(app_message_info.params[0].type.? == u32);
    try std.testing.expect(app_message_info.return_type.? == MessageId);

    const long_param_info = @typeInfo(@TypeOf(longParamFromPtrValue)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), long_param_info.params.len);
    try std.testing.expect(long_param_info.params[0].type.? == usize);
    try std.testing.expect(long_param_info.return_type.? == LongParam);

    const ptr_value_info = @typeInfo(@TypeOf(ptrValueFromLongParam)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), ptr_value_info.params.len);
    try std.testing.expect(ptr_value_info.params[0].type.? == LongParam);
    try std.testing.expect(ptr_value_info.return_type.? == usize);

    const close_info = @typeInfo(@TypeOf(postCloseMessage)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), close_info.params.len);
    try std.testing.expect(close_info.params[0].type.? == NativeHandle);
    try std.testing.expect(close_info.return_type.? == bool);

    const hotkey_info = @typeInfo(@TypeOf(isHotkeyMessage)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), hotkey_info.params.len);
    try std.testing.expect(hotkey_info.params[0].type.? == MessageId);
    try std.testing.expect(hotkey_info.params[1].type.? == WordParam);
    try std.testing.expect(hotkey_info.params[2].type.? == i32);
    try std.testing.expect(hotkey_info.return_type.? == bool);
}

test "platform window backend exposes backend-neutral dpi resolution" {
    const native_dpi_info = @typeInfo(@TypeOf(dpiForNativeHandle)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), native_dpi_info.params.len);
    try std.testing.expect(native_dpi_info.params[0].type.? == NativeHandle);
    try std.testing.expect(native_dpi_info.return_type.? == u32);

    const effective_info = @typeInfo(@TypeOf(effectiveDpi)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), effective_info.params.len);
    try std.testing.expect(effective_info.params[0].type.? == *Window);
    try std.testing.expect(effective_info.return_type.? == u32);
}

test "platform window backend exposes backend-neutral layout state accessors" {
    const setters = .{
        .{ setClientSize, 3 },
        .{ setTitlebarHeight, 2 },
        .{ setSidebarWidth, 2 },
        .{ setTabCount, 2 },
    };
    inline for (setters) |entry| {
        const info = @typeInfo(@TypeOf(entry[0])).@"fn";
        try std.testing.expectEqual(@as(usize, entry[1]), info.params.len);
        try std.testing.expect(info.params[0].type.? == *Window);
        try std.testing.expect(info.return_type.? == void);
    }

    const titlebar_info = @typeInfo(@TypeOf(titlebarHeight)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), titlebar_info.params.len);
    try std.testing.expect(titlebar_info.params[0].type.? == *const Window);
    try std.testing.expect(titlebar_info.return_type.? == i32);
}

test "platform window backend exposes backend-neutral pointer and titlebar hit state" {
    const base_height_info = @typeInfo(@TypeOf(titlebarBaseHeight)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), base_height_info.params.len);
    try std.testing.expect(base_height_info.return_type.? == i32);

    const mouse_info = @typeInfo(@TypeOf(mousePosition)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), mouse_info.params.len);
    try std.testing.expect(mouse_info.params[0].type.? == *const Window);
    try std.testing.expect(mouse_info.return_type.? == Point);

    const hovered_info = @typeInfo(@TypeOf(hoveredCaptionButton)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), hovered_info.params.len);
    try std.testing.expect(hovered_info.params[0].type.? == *const Window);
    try std.testing.expect(hovered_info.return_type.? == CaptionButton);

    const close_info = @typeInfo(@TypeOf(setTabCloseButtonBounds)).@"fn";
    try std.testing.expectEqual(@as(usize, 4), close_info.params.len);
    try std.testing.expect(close_info.params[0].type.? == *Window);
    try std.testing.expect(close_info.params[1].type.? == usize);
    try std.testing.expect(close_info.params[2].type.? == i32);
    try std.testing.expect(close_info.params[3].type.? == i32);
    try std.testing.expect(close_info.return_type.? == void);

    const plus_info = @typeInfo(@TypeOf(setNewTabButtonBounds)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), plus_info.params.len);
    try std.testing.expect(plus_info.params[0].type.? == *Window);
    try std.testing.expect(plus_info.params[1].type.? == i32);
    try std.testing.expect(plus_info.params[2].type.? == i32);
    try std.testing.expect(plus_info.return_type.? == void);
}

test "platform window backend exposes backend-neutral create options" {
    const create_info = @typeInfo(@TypeOf(create)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), create_info.params.len);
    try std.testing.expect(create_info.params[0].type.? == std.mem.Allocator);
    try std.testing.expect(create_info.params[1].type.? == CreateOptions);
    const create_return_info = @typeInfo(create_info.return_type.?).error_union;
    try std.testing.expect(create_return_info.payload == Window);

    const options = CreateOptions{
        .width = 800,
        .height = 600,
        .title = "WispTerm",
        .x = 10,
        .y = 20,
        .maximize = true,
    };
    try std.testing.expectEqual(@as(i32, 800), options.width);
    try std.testing.expectEqual(@as(i32, 600), options.height);
    try std.testing.expectEqualStrings("WispTerm", options.title);
    try std.testing.expectEqual(@as(?i32, 10), options.x);
    try std.testing.expectEqual(@as(?i32, 20), options.y);
    try std.testing.expect(options.maximize);
}

test "platform window backend exposes backend-neutral event handler registration" {
    const handlers = EventHandlers{};
    try std.testing.expect(handlers.on_resize == null);
    try std.testing.expect(handlers.on_message == null);
    try std.testing.expect(handlers.on_file_drop == null);

    const set_info = @typeInfo(@TypeOf(setEventHandlers)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), set_info.params.len);
    try std.testing.expect(set_info.params[0].type.? == *Window);
    try std.testing.expect(set_info.params[1].type.? == EventHandlers);
    try std.testing.expect(set_info.return_type.? == void);

    const resize_info = @typeInfo(@typeInfo(ResizeCallback).pointer.child).@"fn";
    try std.testing.expectEqual(@as(usize, 2), resize_info.params.len);
    try std.testing.expect(resize_info.params[0].type.? == i32);
    try std.testing.expect(resize_info.params[1].type.? == i32);
    try std.testing.expect(resize_info.return_type.? == void);
}

test "platform window backend exposes current backend window hooks" {
    _ = Window;

    const set_global_info = @typeInfo(@TypeOf(setGlobalWindow)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), set_global_info.params.len);
    try std.testing.expect(set_global_info.params[0].type.? == *Window);

    const gl_loader_info = @typeInfo(@TypeOf(glGetProcAddress)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), gl_loader_info.params.len);
    try std.testing.expect(gl_loader_info.return_type.? == ?*const anyopaque);
}

test "platform window backend exposes Metal layer surface seam" {
    const seam_info = @typeInfo(@TypeOf(metalLayer)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), seam_info.params.len);
    try std.testing.expect(seam_info.params[0].type.? == *Window);
    try std.testing.expect(seam_info.return_type.? == ?*anyopaque);
}

test "macOS AppKit backend creates a Metal-backed native window" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var window = try create(std.testing.allocator, .{
        .width = 320,
        .height = 180,
        .title = "WispTerm Window Smoke",
    });
    defer destroy(&window);

    try std.testing.expect(nativeHandleBits(&window) != 0);
    try std.testing.expect(metalLayer(&window) != null);
    try std.testing.expect(dpi(&window) >= 96);
    const size = framebufferSize(&window);
    try std.testing.expect(size.width > 0);
    try std.testing.expect(size.height > 0);

    resizeClientArea(&window, 360, 200);
    _ = pollEvents(&window);
    const resized = framebufferSize(&window);
    try std.testing.expect(resized.width > 0);
    try std.testing.expect(resized.height > 0);
}

test "platform window backend exposes native handle accessors" {
    const native_handle_info = @typeInfo(@TypeOf(nativeHandle)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), native_handle_info.params.len);
    try std.testing.expect(native_handle_info.params[0].type.? == *Window);
    try std.testing.expect(native_handle_info.return_type.? == NativeHandle);

    const native_bits_info = @typeInfo(@TypeOf(nativeHandleBits)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), native_bits_info.params.len);
    try std.testing.expect(native_bits_info.params[0].type.? == *Window);
    try std.testing.expect(native_bits_info.return_type.? == usize);

    const native_from_bits_info = @typeInfo(@TypeOf(nativeHandleFromBits)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), native_from_bits_info.params.len);
    try std.testing.expect(native_from_bits_info.params[0].type.? == usize);
    try std.testing.expect(native_from_bits_info.return_type.? == ?NativeHandle);
    try std.testing.expect(nativeHandleFromBits(0) == null);
}

test "platform window backend selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.linux, backendForOs(.linux));
    try std.testing.expectEqual(Backend.macos, backendForOs(.macos));
}

test "platform window backend resolves close-request confirmation policy per backend" {
    try std.testing.expect(closeRequestPromptsConfirmationForBackend(.windows));
    try std.testing.expect(closeRequestPromptsConfirmationForBackend(.unsupported));
    try std.testing.expect(!closeRequestPromptsConfirmationForBackend(.macos));
}
