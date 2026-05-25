const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("window_windows.zig"),
    .unsupported => @import("window_unsupported.zig"),
};

pub const NativeHandle = impl.NativeHandle;
pub const MessageId = impl.MessageId;
pub const WordParam = impl.WordParam;
pub const LongParam = impl.LongParam;
pub const MessageResult = impl.MessageResult;
pub const titlebar_height = impl.titlebar_height;
pub const CaptionButton = impl.CaptionButton;
pub const CaptionButtonVisualStyle = struct {
    width: f32,
    icon_color: [3]f32,
    hover_icon_color: [3]f32,
    hover_background_delta: f32,
    close_hover_background: [3]f32,
};
pub const caption_button_visual_style: CaptionButtonVisualStyle = .{
    .width = impl.caption_button_width,
    .icon_color = impl.caption_icon_color,
    .hover_icon_color = impl.caption_hover_icon_color,
    .hover_background_delta = impl.caption_hover_background_delta,
    .close_hover_background = impl.caption_close_hover_background,
};
pub const Rect = impl.Rect;
pub const overlapped_window_style = impl.overlapped_window_style;
pub const frame_changed = impl.frame_changed;
pub const show_window = impl.show_window;
pub const hotkey_message = impl.hotkey_message;

pub const appMessage = impl.appMessage;
pub const longParamFromPtrValue = impl.longParamFromPtrValue;
pub const ptrValueFromLongParam = impl.ptrValueFromLongParam;
pub const nativeHandleFromBits = impl.nativeHandleFromBits;
pub const getWindowRect = impl.getWindowRect;
pub const getClientRect = impl.getClientRect;
pub const postCloseMessage = impl.postCloseMessage;
pub const postMessage = impl.postMessage;
pub const sendMessage = impl.sendMessage;
pub const dpiForWindow = impl.dpiForWindow;
pub const showRestored = impl.showRestored;
pub const showMaximized = impl.showMaximized;
pub const showVisible = impl.showVisible;
pub const showHidden = impl.showHidden;
pub const setForeground = impl.setForeground;
pub const isMaximized = impl.isMaximized;
pub const getWindowStyle = impl.getWindowStyle;
pub const setWindowStyle = impl.setWindowStyle;
pub const setWindowFrame = impl.setWindowFrame;
pub const setWindowFrameRaw = impl.setWindowFrameRaw;
pub const setOuterFrame = impl.setOuterFrame;
pub const nearestMonitorRect = impl.nearestMonitorRect;
pub const nearestMonitorWorkArea = impl.nearestMonitorWorkArea;

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

test "platform window exposes caption button visual style" {
    try std.testing.expectEqual(@as(f32, 46), caption_button_visual_style.width);
    try std.testing.expectEqual(@as(f32, 0.75), caption_button_visual_style.icon_color[0]);
    try std.testing.expectEqual(@as(f32, 1.0), caption_button_visual_style.hover_icon_color[0]);
    try std.testing.expect(caption_button_visual_style.hover_background_delta > 0);
    try std.testing.expect(caption_button_visual_style.close_hover_background[0] > caption_button_visual_style.close_hover_background[1]);
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
    try std.testing.expect(nativeHandleFromBits(0) == null);
}

test "platform window selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
