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
    .windows => @import("remote_transport_windows.zig"),
    .unsupported => @import("remote_transport_unsupported.zig"),
};

pub const io_chunk_size = impl.io_chunk_size;
pub const WebSocketHandle = impl.WebSocketHandle;
pub const Endpoint = impl.Endpoint;
pub const BufferType = impl.BufferType;
pub const ReceiveResult = impl.ReceiveResult;
pub const Handles = impl.Handles;

pub const connect = impl.connect;
pub const receive = impl.receive;
pub const sendUtf8 = impl.sendUtf8;

test "platform remote transport exposes websocket API" {
    try std.testing.expect(@hasDecl(@This(), "Endpoint"));
    try std.testing.expect(@hasDecl(@This(), "Handles"));
    try std.testing.expect(@hasDecl(@This(), "WebSocketHandle"));
    try std.testing.expect(@hasDecl(@This(), "BufferType"));
    try std.testing.expect(@hasDecl(@This(), "ReceiveResult"));

    const connect_info = @typeInfo(@TypeOf(connect)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), connect_info.params.len);
    try std.testing.expect(connect_info.params[0].type.? == std.mem.Allocator);
    try std.testing.expect(connect_info.params[1].type.? == @This().Endpoint);

    const send_info = @typeInfo(@TypeOf(sendUtf8)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), send_info.params.len);
    try std.testing.expect(send_info.params[0].type.? == @This().WebSocketHandle);
    try std.testing.expect(send_info.params[1].type.? == []const u8);

    const receive_info = @typeInfo(@TypeOf(receive)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), receive_info.params.len);
    try std.testing.expect(receive_info.params[0].type.? == @This().WebSocketHandle);
    try std.testing.expect(receive_info.params[1].type.? == []u8);
}

test "platform remote transport selects backend per OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
