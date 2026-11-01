//! Bundled OpenSSH ProxyCommand helper: native stdio <-> proxied TCP.
//! Intentionally separate from the GUI and never changes system proxy settings.
const std = @import("std");
const proxy = @import("ssh/network_proxy.zig");
const protocol = @import("ssh/proxy_protocol.zig");
const Socket = @import("platform/proxy_socket.zig").Socket;

pub fn main() void {
    run() catch |err| {
        std.debug.print("WispTerm SSH proxy: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    // The standalone process owns its stdin worker. A remote EOF must exit even
    // if OpenSSH still has the worker's stdin pipe open; never wait indefinitely.
    std.process.exit(0);
}

fn run() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 6) return error.ExpectedTypeProxyHostProxyPortTargetHostTargetPort;
    const kind = proxy.Kind.parse(args[1]) orelse return error.InvalidProxyType;
    if (kind == .none) return error.InvalidProxyType;
    const host = proxy.unbracket(args[2]);
    if (!proxy.isHostSafe(host) or !proxy.isPortSafe(args[3]) or !proxy.isPortSafe(args[5])) return error.InvalidEndpoint;
    const port = try std.fmt.parseInt(u16, args[3], 10);
    const target_port = try std.fmt.parseInt(u16, args[5], 10);
    const stream = try Socket.connect(allocator, host, port);
    defer stream.close();
    try stream.handshakeTimeout(true);
    try protocol.handshake(stream, kind, args[4], target_port);
    try stream.handshakeTimeout(false);
    const worker = try std.Thread.spawn(.{}, stdinToSocket, .{stream});
    worker.detach();
    var bytes: [32768]u8 = undefined;
    const stdout = std.fs.File.stdout();
    while (true) {
        const n = try stream.read(&bytes);
        if (n == 0) return;
        try stdout.writeAll(bytes[0..n]);
    }
}

fn stdinToSocket(stream: Socket) void {
    defer stream.shutdownSend();
    const stdin = std.fs.File.stdin();
    var bytes: [32768]u8 = undefined;
    while (true) {
        const n = stdin.read(&bytes) catch return;
        if (n == 0) return;
        stream.writeAll(bytes[0..n]) catch return;
    }
}
