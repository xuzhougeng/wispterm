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
    // The consumer calls close() twice — once before joining the receive thread
    // (to unblock it) and once after (remote_client.zig). The first call only
    // tears the socket down so the in-flight receive can finish; the second
    // frees the native connection once no thread can touch it anymore.
    torn_down: bool = false,

    pub fn close(self: *Handles) void {
        const ws = self.websocket orelse return;
        if (!self.torn_down) {
            self.torn_down = true;
            wispterm_macos_ws_shutdown(ws);
        } else {
            wispterm_macos_ws_free(ws);
            self.websocket = null;
        }
    }
};

const connect_timeout_seconds: f64 = 10.0;

extern fn wispterm_macos_ws_connect(
    secure: bool,
    host: [*:0]const u8,
    port: u16,
    object_name: [*:0]const u8,
    timeout_seconds: f64,
) ?WebSocketHandle;
extern fn wispterm_macos_ws_shutdown(websocket: WebSocketHandle) void;
extern fn wispterm_macos_ws_free(websocket: WebSocketHandle) void;
extern fn wispterm_macos_ws_send(websocket: WebSocketHandle, bytes: [*]const u8, len: usize) bool;
extern fn wispterm_macos_ws_receive(
    websocket: WebSocketHandle,
    buffer: [*]u8,
    buffer_len: usize,
    out_type: *i32,
) isize;

pub fn connect(allocator: std.mem.Allocator, endpoint: Endpoint) !Handles {
    const host_z = allocator.dupeZ(u8, endpoint.host) catch return error.OutOfMemory;
    defer allocator.free(host_z);
    const object_z = allocator.dupeZ(u8, endpoint.object_name) catch return error.OutOfMemory;
    defer allocator.free(object_z);

    const websocket = wispterm_macos_ws_connect(
        endpoint.secure,
        host_z.ptr,
        endpoint.port,
        object_z.ptr,
        connect_timeout_seconds,
    ) orelse return error.RemoteTransportConnectFailed;

    return .{ .websocket = websocket };
}

pub fn receive(websocket: WebSocketHandle, buffer: []u8) !ReceiveResult {
    var out_type: i32 = 0;
    const n = wispterm_macos_ws_receive(websocket, buffer.ptr, buffer.len, &out_type);
    if (n < 0) return error.RemoteTransportReceiveFailed;
    return .{
        .bytes_read = @intCast(n),
        .buffer_type = decodeBufferType(out_type),
    };
}

pub fn sendUtf8(websocket: WebSocketHandle, message: []const u8) bool {
    return wispterm_macos_ws_send(websocket, message.ptr, message.len);
}

fn decodeBufferType(raw: i32) BufferType {
    return switch (raw) {
        0 => .utf8_message,
        1 => .utf8_fragment,
        2 => .close,
        else => .other,
    };
}
