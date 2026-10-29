//! Portable blocking socket capability for the standalone SSH proxy bridge.
//! Use recv/send rather than std.net.Stream's Windows ReadFile path: Winsock
//! receive timeouts are not compatible with that file-handle read path.
const std = @import("std");
const builtin = @import("builtin");

pub const Socket = struct {
    stream: std.net.Stream,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !Socket {
        return .{ .stream = try std.net.tcpConnectToHost(allocator, host, port) };
    }

    pub fn close(self: Socket) void {
        self.stream.close();
    }

    pub fn read(self: Socket, out: []u8) !usize {
        return std.posix.recv(self.stream.handle, out, 0);
    }

    pub fn writeAll(self: Socket, bytes: []const u8) !void {
        var n: usize = 0;
        while (n < bytes.len) {
            const sent = try std.posix.send(self.stream.handle, bytes[n..], 0);
            if (sent == 0) return error.ConnectionResetByPeer;
            n += sent;
        }
    }

    pub fn shutdownSend(self: Socket) void {
        std.posix.shutdown(self.stream.handle, .send) catch {};
    }

    pub fn handshakeTimeout(self: Socket, enabled: bool) !void {
        const timeout = if (builtin.os.tag == .windows)
            @as(u32, if (enabled) 10000 else 0)
        else
            std.posix.timeval{ .sec = if (enabled) 10 else 0, .usec = 0 };
        try std.posix.setsockopt(self.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    }
};
