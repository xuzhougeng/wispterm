const std = @import("std");

pub const io_chunk_size = 16 * 1024;

pub const WebSocketHandle = *opaque {};

pub const Endpoint = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    object_name: []const u8,
};

pub const BufferType = enum {
    utf8_message,
    utf8_fragment,
    close,
    other,
};

pub const ReceiveResult = struct {
    bytes_read: usize,
    buffer_type: BufferType,
};

pub const Handles = struct {
    websocket: ?WebSocketHandle = null,

    pub fn close(self: *Handles) void {
        self.websocket = null;
    }
};

pub fn connect(allocator: std.mem.Allocator, endpoint: Endpoint) !Handles {
    _ = allocator;
    _ = endpoint;
    return error.UnsupportedRemoteTransport;
}

pub fn receive(websocket: WebSocketHandle, buffer: []u8) !ReceiveResult {
    _ = websocket;
    _ = buffer;
    return error.UnsupportedRemoteTransport;
}

pub fn sendUtf8(websocket: WebSocketHandle, message: []const u8) bool {
    _ = websocket;
    _ = message;
    return false;
}
