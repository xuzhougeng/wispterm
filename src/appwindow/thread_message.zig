const std = @import("std");
const window_backend = @import("../platform/window_backend.zig");

pub const Tag = enum(u8) {
    agent_ssh_connect,
    agent_ssh_save,
    agent_tab_new,
    agent_tab_close,
    remote_ai_input,
    remote_open_ai_agent,
    weixin_control,
    agent_ui_screenshot,
};

pub const Decoded = struct {
    tag: Tag,
    ptr: usize,
};

fn offset(tag: Tag) u32 {
    return switch (tag) {
        .agent_ssh_connect => 0x51,
        .agent_tab_new => 0x52,
        .agent_tab_close => 0x53,
        .remote_ai_input => 0x54,
        .remote_open_ai_agent => 0x55,
        .agent_ssh_save => 0x56,
        .weixin_control => 0x57,
        .agent_ui_screenshot => 0x58,
    };
}

pub fn id(tag: Tag) window_backend.MessageId {
    return window_backend.appMessage(offset(tag));
}

pub fn decode(message_id: window_backend.MessageId, lparam: window_backend.LongParam) ?Decoded {
    inline for (@typeInfo(Tag).@"enum".fields) |field| {
        const tag = @field(Tag, field.name);
        if (message_id == id(tag)) {
            return .{
                .tag = tag,
                .ptr = window_backend.ptrValueFromLongParam(lparam),
            };
        }
    }
    return null;
}

pub fn postPointer(native_handle: window_backend.NativeHandle, tag: Tag, ptr: usize) bool {
    return window_backend.postMessage(native_handle, id(tag), 0, window_backend.longParamFromPtrValue(ptr));
}

pub fn sendPointer(native_handle: window_backend.NativeHandle, tag: Tag, ptr: usize) window_backend.MessageResult {
    return window_backend.sendMessage(native_handle, id(tag), 0, window_backend.longParamFromPtrValue(ptr));
}

test "appwindow thread messages expose backend-neutral pointer dispatch" {
    const id_info = @typeInfo(@TypeOf(id)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), id_info.params.len);
    try std.testing.expect(id_info.params[0].type.? == Tag);
    try std.testing.expect(id_info.return_type.? == window_backend.MessageId);

    const decode_info = @typeInfo(@TypeOf(decode)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), decode_info.params.len);
    try std.testing.expect(decode_info.params[0].type.? == window_backend.MessageId);
    try std.testing.expect(decode_info.params[1].type.? == window_backend.LongParam);
    try std.testing.expect(decode_info.return_type.? == ?Decoded);

    const post_info = @typeInfo(@TypeOf(postPointer)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), post_info.params.len);
    try std.testing.expect(post_info.params[0].type.? == window_backend.NativeHandle);
    try std.testing.expect(post_info.params[1].type.? == Tag);
    try std.testing.expect(post_info.params[2].type.? == usize);
    try std.testing.expect(post_info.return_type.? == bool);

    const send_info = @typeInfo(@TypeOf(sendPointer)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), send_info.params.len);
    try std.testing.expect(send_info.params[0].type.? == window_backend.NativeHandle);
    try std.testing.expect(send_info.params[1].type.? == Tag);
    try std.testing.expect(send_info.params[2].type.? == usize);
    try std.testing.expect(send_info.return_type.? == window_backend.MessageResult);
}

test "appwindow thread messages round-trip message id and pointer payload" {
    const payload_ptr: usize = 0x1234_5678;
    const decoded = decode(id(.agent_tab_new), window_backend.longParamFromPtrValue(payload_ptr)).?;
    try std.testing.expectEqual(Tag.agent_tab_new, decoded.tag);
    try std.testing.expectEqual(payload_ptr, decoded.ptr);
    try std.testing.expect(decode(window_backend.appMessage(0x7f), 0) == null);
}
