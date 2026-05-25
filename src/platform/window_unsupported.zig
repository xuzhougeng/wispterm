pub const NativeHandle = usize;
pub const MessageId = u32;
pub const WordParam = usize;
pub const LongParam = isize;
pub const MessageResult = isize;
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

const wm_close: u32 = 0x0010;
const wm_app: u32 = 0x8000;

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
    return bits;
}

pub fn getWindowRect(hwnd: NativeHandle) ?Rect {
    _ = hwnd;
    return null;
}

pub fn getClientRect(hwnd: NativeHandle) ?Rect {
    _ = hwnd;
    return null;
}

pub fn postCloseMessage(hwnd: NativeHandle) bool {
    return postMessage(hwnd, wm_close, 0, 0);
}

pub fn postMessage(hwnd: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) bool {
    _ = hwnd;
    _ = message;
    _ = wparam;
    _ = lparam;
    return false;
}

pub fn sendMessage(hwnd: NativeHandle, message: MessageId, wparam: WordParam, lparam: LongParam) MessageResult {
    _ = hwnd;
    _ = message;
    _ = wparam;
    _ = lparam;
    return 0;
}

pub fn dpiForWindow(hwnd: NativeHandle) u32 {
    _ = hwnd;
    return 96;
}

pub fn showRestored(hwnd: NativeHandle) bool {
    _ = hwnd;
    return false;
}

pub fn showMaximized(hwnd: NativeHandle) bool {
    _ = hwnd;
    return false;
}

pub fn showVisible(hwnd: NativeHandle) bool {
    _ = hwnd;
    return false;
}

pub fn showHidden(hwnd: NativeHandle) bool {
    _ = hwnd;
    return false;
}

pub fn setForeground(hwnd: NativeHandle) bool {
    _ = hwnd;
    return false;
}

pub fn isMaximized(hwnd: NativeHandle) bool {
    _ = hwnd;
    return false;
}

pub fn getWindowStyle(hwnd: NativeHandle) u32 {
    _ = hwnd;
    return 0;
}

pub fn setWindowStyle(hwnd: NativeHandle, style: u32) bool {
    _ = hwnd;
    _ = style;
    return false;
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
    _ = hwnd;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    _ = flags;
    return false;
}

pub fn setOuterFrame(hwnd: NativeHandle, rect: Rect, topmost: bool) bool {
    _ = hwnd;
    _ = rect;
    _ = topmost;
    return false;
}

pub fn nearestMonitorRect(hwnd: NativeHandle) ?Rect {
    _ = hwnd;
    return null;
}

pub fn nearestMonitorWorkArea(hwnd: NativeHandle) ?Rect {
    _ = hwnd;
    return null;
}
