//! Bounded, unbuffered CONNECT handshakes. Reading exactly the reply prevents
//! consuming the first SSH banner bytes when proxy reply and banner coalesce.
const std = @import("std");
const network_proxy = @import("network_proxy.zig");

fn readExact(stream: anytype, out: []u8) !void {
    var pos: usize = 0;
    while (pos < out.len) {
        const n = try stream.read(out[pos..]);
        if (n == 0) return error.ProxyUnexpectedEof;
        pos += n;
    }
}

pub fn handshake(stream: anytype, kind: network_proxy.Kind, host_raw: []const u8, port: u16) !void {
    const host = network_proxy.unbracket(host_raw);
    if (!network_proxy.isHostSafe(host) or port == 0) return error.InvalidTarget;
    switch (kind) {
        .none => return error.InvalidProxyType,
        .socks5 => try socks5(stream, host, port),
        .http => try httpConnect(stream, host, port),
    }
}

fn socks5(stream: anytype, host: []const u8, port: u16) !void {
    try stream.writeAll(&.{ 5, 1, 0 }); // no authentication, no stored proxy secret
    var method: [2]u8 = undefined;
    try readExact(stream, &method);
    if (method[0] != 5) return error.InvalidSocksReply;
    if (method[1] != 0) return error.ProxyAuthenticationRequired;
    var request: [262]u8 = undefined;
    @memcpy(request[0..3], &[_]u8{ 5, 1, 0 });
    var n: usize = 4;
    if (std.net.Address.parseIp(host, 0)) |address| {
        if (address.any.family == std.posix.AF.INET) {
            request[3] = 1;
            @memcpy(request[n..][0..4], std.mem.asBytes(&address.in.sa.addr));
            n += 4;
        } else {
            request[3] = 4;
            @memcpy(request[n..][0..16], &address.in6.sa.addr);
            n += 16;
        }
    } else |_| {
        request[3] = 3;
        request[n] = @intCast(host.len);
        n += 1;
        @memcpy(request[n..][0..host.len], host);
        n += host.len;
    }
    std.mem.writeInt(u16, request[n..][0..2], port, .big);
    try stream.writeAll(request[0 .. n + 2]);
    var head: [4]u8 = undefined;
    try readExact(stream, &head);
    if (head[0] != 5 or head[2] != 0) return error.InvalidSocksReply;
    if (head[1] != 0) return error.SocksConnectionRejected;
    var tail: [257]u8 = undefined;
    const tail_len: usize = switch (head[3]) {
        1 => 6,
        4 => 18,
        3 => blk: {
            var len: [1]u8 = undefined;
            try readExact(stream, &len);
            break :blk @as(usize, len[0]) + 2;
        },
        else => return error.InvalidSocksReply,
    };
    try readExact(stream, tail[0..tail_len]);
}

fn httpConnect(stream: anytype, host: []const u8, port: u16) !void {
    var authority_buf: [280]u8 = undefined;
    const ipv6 = std.mem.indexOfScalar(u8, host, ':') != null;
    const authority = try std.fmt.bufPrint(&authority_buf, "{s}{s}{s}:{d}", .{
        if (ipv6) "[" else "", host, if (ipv6) "]" else "", port,
    });
    var request: [768]u8 = undefined;
    const text = try std.fmt.bufPrint(&request, "CONNECT {s} HTTP/1.1\r\nHost: {s}\r\n\r\n", .{ authority, authority });
    try stream.writeAll(text);
    var header: [16384]u8 = undefined;
    var n: usize = 0;
    while (true) {
        if (n == header.len) return error.ProxyHeaderTooLarge;
        try readExact(stream, header[n..][0..1]);
        n += 1;
        if (n >= 4 and std.mem.eql(u8, header[n - 4 .. n], "\r\n\r\n")) break;
    }
    const line_end = std.mem.indexOf(u8, header[0..n], "\r\n") orelse return error.InvalidHttpProxyReply;
    const line = header[0..line_end];
    if (line.len < 12 or (!std.mem.startsWith(u8, line, "HTTP/1.1 ") and !std.mem.startsWith(u8, line, "HTTP/1.0 ")))
        return error.InvalidHttpProxyReply;
    if (line.len > 12 and line[12] != ' ') return error.InvalidHttpProxyReply;
    if (std.mem.eql(u8, line[9..12], "407")) return error.ProxyAuthenticationRequired;
    for (line[9..12]) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidHttpProxyReply;
    // RFC 9110 section 9.3.6: any successful 2xx response switches to tunnel mode.
    if (line[9] != '2') return error.HttpConnectRejected;
}

const FakeStream = struct {
    reply: []const u8,
    pos: usize = 0,
    sent: [1024]u8 = undefined,
    sent_len: usize = 0,

    fn read(self: *FakeStream, out: []u8) !usize {
        if (self.pos == self.reply.len) return 0;
        const n = @min(@min(out.len, self.reply.len - self.pos), 2);
        @memcpy(out[0..n], self.reply[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn writeAll(self: *FakeStream, bytes: []const u8) !void {
        @memcpy(self.sent[self.sent_len..][0..bytes.len], bytes);
        self.sent_len += bytes.len;
    }
};

test "HTTP CONNECT handles fragmented headers without eating the SSH banner" {
    var stream = FakeStream{ .reply = "HTTP/1.1 200 Connection established\r\n\r\nSSH-2.0-test\r\n" };
    try handshake(&stream, .http, "2001:db8::1", 22);
    try std.testing.expectEqualStrings("SSH-2.0-test\r\n", stream.reply[stream.pos..]);
    try std.testing.expect(std.mem.startsWith(u8, stream.sent[0..stream.sent_len], "CONNECT [2001:db8::1]:22 HTTP/1.1\r\n"));
}

test "proxy rejection, authentication, truncation and malformed replies fail closed" {
    var http_auth = FakeStream{ .reply = "HTTP/1.1 407 Authentication Required\r\n\r\n" };
    try std.testing.expectError(error.ProxyAuthenticationRequired, handshake(&http_auth, .http, "host.test", 22));
    var http_bad = FakeStream{ .reply = "HTTP/1.1 2000 bad\r\n\r\n" };
    try std.testing.expectError(error.InvalidHttpProxyReply, handshake(&http_bad, .http, "host.test", 22));
    var socks_auth = FakeStream{ .reply = &.{ 5, 2 } };
    try std.testing.expectError(error.ProxyAuthenticationRequired, handshake(&socks_auth, .socks5, "host.test", 22));
    var eof = FakeStream{ .reply = &.{5} };
    try std.testing.expectError(error.ProxyUnexpectedEof, handshake(&eof, .socks5, "host.test", 22));
}

test "SOCKS5 resolves names remotely and leaves coalesced application bytes untouched" {
    var stream = FakeStream{ .reply = "\x05\x00\x05\x00\x00\x01\x7f\x00\x00\x01\x12\x34SSH-2.0-test\r\n" };
    try handshake(&stream, .socks5, "host.test", 22);
    try std.testing.expectEqualStrings("SSH-2.0-test\r\n", stream.reply[stream.pos..]);
    try std.testing.expectEqual(@as(u8, 3), stream.sent[6]);
    try std.testing.expectEqualStrings("host.test", stream.sent[8..17]);
}

test "SOCKS5 encodes IPv4 and IPv6 targets without local DNS" {
    var ipv4 = FakeStream{ .reply = "\x05\x00\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00" };
    try handshake(&ipv4, .socks5, "192.0.2.9", 2222);
    try std.testing.expectEqualSlices(u8, &.{ 5, 1, 0, 1, 192, 0, 2, 9, 8, 174 }, ipv4.sent[3..ipv4.sent_len]);
    var ipv6 = FakeStream{ .reply = "\x05\x00\x05\x00\x00\x04" ++ "\x00" ** 18 };
    try handshake(&ipv6, .socks5, "[2001:db8::1]", 22);
    try std.testing.expectEqual(@as(u8, 4), ipv6.sent[6]);
    try std.testing.expectEqual(@as(usize, 25), ipv6.sent_len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 22 }, ipv6.sent[23..25]);
}

test "HTTP CONNECT accepts 2xx but rejects nonnumeric status and oversized headers" {
    var success = FakeStream{ .reply = "HTTP/1.0 204 Tunnel ready\r\n\r\nSSH-2.0-test\r\n" };
    try handshake(&success, .http, "host.test", 22);
    try std.testing.expectEqualStrings("SSH-2.0-test\r\n", success.reply[success.pos..]);
    var malformed = FakeStream{ .reply = "HTTP/1.1 2xx Invalid\r\n\r\n" };
    try std.testing.expectError(error.InvalidHttpProxyReply, handshake(&malformed, .http, "host.test", 22));
    var rejected = FakeStream{ .reply = "HTTP/1.1 403 Forbidden\r\n\r\n" };
    try std.testing.expectError(error.HttpConnectRejected, handshake(&rejected, .http, "host.test", 22));
    const oversized = try std.testing.allocator.alloc(u8, 16384);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    var huge = FakeStream{ .reply = oversized };
    try std.testing.expectError(error.ProxyHeaderTooLarge, handshake(&huge, .http, "host.test", 22));
}
