//! RFC6455 WebSocket client framing (harvested verbatim from M0 spike recv_event.zig).
//! Only allowed refactor: frame read/write operate on generic *std.Io.Writer /*std.Io.Reader
//! so they are unit-testable with an in-memory buffer. Masking XOR, length encoding,
//! and opcode handling are identical to the spike.
//!
//! TLS connect (std.http.Client.connect + ca_bundle.rescan) is the CALLER's job
//! (M2.7 longconn). This module only does handshake + framing on an already-connected
//! *std.http.Client.Connection.
const std = @import("std");

// ===================== Public URL helpers =====================

pub const WssUrl = struct { host: []const u8, port: u16, path_query: []const u8 };

pub fn parseWss(url: []const u8) !WssUrl {
    // wss://host[:port]/path?query
    const scheme = "wss://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.NotWss;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NoPath;
    const authority = rest[0..slash];
    const path_query = rest[slash..];
    var host = authority;
    var port: u16 = 443;
    if (std.mem.indexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = try std.fmt.parseInt(u16, authority[c + 1 ..], 10);
    }
    return .{ .host = host, .port = port, .path_query = path_query };
}

pub fn queryParam(url: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var it = std.mem.splitScalar(u8, url[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn stripQuery(url: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    return url[0..q];
}

// ===================== Handshake =====================

/// Send the HTTP Upgrade request on `conn` and verify a 101 response.
/// No custom auth header: per oapi-sdk-go the dial uses a nil request header
/// (auth is in the URL query string).
pub fn handshake(conn: *std.http.Client.Connection, host: []const u8, path_query: []const u8) !void {
    var key_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&key_bytes);
    var key_b64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

    const w = conn.writer();
    try w.print(
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{ path_query, host, key_b64 },
    );
    try conn.flush();

    // Read status line + headers until blank line.
    const r = conn.reader();
    var status_line: std.ArrayListUnmanaged(u8) = .empty;
    defer status_line.deinit(std.heap.page_allocator);
    var first = true;
    var handshake_status: ?[]u8 = null;
    var handshake_msg: ?[]u8 = null;
    defer if (handshake_status) |s| std.heap.page_allocator.free(s);
    defer if (handshake_msg) |s| std.heap.page_allocator.free(s);

    var got_101 = false;
    while (true) {
        const line = try readLine(r, std.heap.page_allocator);
        defer std.heap.page_allocator.free(line);
        if (first) {
            first = false;
            if (std.mem.indexOf(u8, line, " 101 ") != null) got_101 = true;
            try status_line.appendSlice(std.heap.page_allocator, line);
        } else {
            if (line.len == 0) break; // end of headers
            if (asciiHeaderIs(line, "Handshake-Status")) handshake_status = try dupHeaderVal(line);
            if (asciiHeaderIs(line, "Handshake-Msg")) handshake_msg = try dupHeaderVal(line);
        }
    }

    if (!got_101) {
        std.debug.print("BLOCKED: WS handshake not 101. status_line=\"{s}\" Handshake-Status={s} Handshake-Msg={s}\n", .{
            status_line.items,
            handshake_status orelse "(none)",
            handshake_msg orelse "(none)",
        });
        return error.WsHandshakeFailed;
    }
}

// ===================== Conn =====================

pub const Conn = struct {
    conn: *std.http.Client.Connection,
    rng: std.Random.DefaultPrng,

    /// Write one masked binary frame (client->server frames MUST be masked).
    pub fn writeBinary(self: *Conn, payload: []const u8) !void {
        const w = self.conn.writer(); // returns *std.Io.Writer
        var mask: [4]u8 = undefined;
        self.rng.random().bytes(&mask);
        try writeFrame(w, 0x82, &mask, payload);
        try self.conn.flush();
    }

    /// Read one full message (handles control frames internally), returns the
    /// payload of the next binary/text data frame allocated in `a`.
    pub fn readBinary(self: *Conn, a: std.mem.Allocator) ![]u8 {
        var r = self.conn.reader();
        while (true) {
            const result = try readFrame(&r, a);
            switch (result.opcode) {
                0x1, 0x2 => return result.data, // text or binary
                0x8 => {
                    a.free(result.data);
                    return error.WsClosed; // close
                },
                0x9 => { // ping -> pong (echo payload)
                    defer a.free(result.data);
                    try self.writePong(result.data);
                    continue;
                },
                0xa => { // pong, ignore
                    a.free(result.data);
                    continue;
                },
                else => {
                    a.free(result.data);
                    continue;
                },
            }
        }
    }

    fn writePong(self: *Conn, payload: []const u8) !void {
        var w = self.conn.writer();
        var mask: [4]u8 = undefined;
        self.rng.random().bytes(&mask);
        // ponytail: pong payload is small (control frames ≤125 bytes per RFC6455)
        var hdr: [6]u8 = undefined;
        hdr[0] = 0x8a; // FIN + pong
        hdr[1] = 0x80 | @as(u8, @intCast(payload.len & 0x7f));
        @memcpy(hdr[2..6], &mask);
        try w.writeAll(&hdr);
        var i: usize = 0;
        while (i < payload.len) : (i += 1) try w.writeByte(payload[i] ^ mask[i & 3]);
        try self.conn.flush();
    }
};

// ===================== Low-level frame I/O (generic writer/reader for testability) =====================

const FrameResult = struct { opcode: u4, data: []u8 };

/// Write one masked WebSocket frame with the given first-byte `b0` (encodes FIN+opcode).
/// The mask is caller-supplied so tests can use a fixed mask.
/// ponytail: b0 passed in so writeBinary(0x82) and writePong(0x8a) share this path.
pub fn writeFrame(w: *std.Io.Writer, b0: u8, mask: *const [4]u8, payload: []const u8) !void {
    var hdr: [14]u8 = undefined;
    var n: usize = 0;
    hdr[0] = b0;
    n = 1;
    const len = payload.len;
    if (len < 126) {
        hdr[1] = 0x80 | @as(u8, @intCast(len));
        n = 2;
    } else if (len < 0x10000) {
        hdr[1] = 0x80 | 126;
        hdr[2] = @intCast((len >> 8) & 0xff);
        hdr[3] = @intCast(len & 0xff);
        n = 4;
    } else {
        hdr[1] = 0x80 | 127;
        var k: usize = 0;
        while (k < 8) : (k += 1) hdr[2 + k] = @intCast((len >> @intCast((7 - k) * 8)) & 0xff);
        n = 10;
    }
    @memcpy(hdr[n .. n + 4], mask);
    n += 4;
    try w.writeAll(hdr[0..n]);

    // Mask payload in chunks.
    var buf: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) {
        const chunk = @min(buf.len, payload.len - off);
        var k: usize = 0;
        while (k < chunk) : (k += 1) buf[k] = payload[off + k] ^ mask[(off + k) & 3];
        try w.writeAll(buf[0..chunk]);
        off += chunk;
    }
}

/// Read one WebSocket frame from `r`. Returns opcode and heap-allocated unmasked payload.
fn readFrame(r: *std.Io.Reader, a: std.mem.Allocator) !FrameResult {
    const b0 = try takeOne(r);
    const opcode: u4 = @intCast(b0 & 0x0f);
    const b1 = try takeOne(r);
    const masked = (b1 & 0x80) != 0;
    var len: u64 = b1 & 0x7f;
    if (len == 126) {
        const ext = try r.take(2);
        len = (@as(u64, ext[0]) << 8) | ext[1];
    } else if (len == 127) {
        const ext = try r.take(8);
        len = 0;
        for (ext) |byte| len = (len << 8) | byte;
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) @memcpy(&mask, try r.take(4)); // server frames are unmasked, but handle anyway

    const data = try a.alloc(u8, @intCast(len));
    try r.readSliceAll(data);
    if (masked) {
        for (data, 0..) |*d, idx| d.* ^= mask[idx & 3];
    }
    return .{ .opcode = opcode, .data = data };
}

// ===================== Internal helpers =====================

fn takeOne(r: *std.Io.Reader) !u8 {
    const s = try r.take(1);
    return s[0];
}

fn readLine(r: *std.Io.Reader, a: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    while (true) {
        const b = try takeOne(r);
        if (b == '\r') {
            const n = try takeOne(r);
            if (n == '\n') return out.toOwnedSlice(a);
            try out.append(a, '\r');
            try out.append(a, n);
        } else {
            try out.append(a, b);
        }
    }
}

fn asciiHeaderIs(line: []const u8, name: []const u8) bool {
    if (line.len < name.len + 1) return false;
    if (!std.ascii.eqlIgnoreCase(line[0..name.len], name)) return false;
    return line[name.len] == ':';
}

fn dupHeaderVal(line: []const u8) ![]u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
    var v = line[colon + 1 ..];
    while (v.len > 0 and (v[0] == ' ' or v[0] == '\t')) v = v[1..];
    return std.heap.page_allocator.dupe(u8, v);
}

// ===================== Tests =====================

test "parseWss splits host port path" {
    const u = try parseWss("wss://msg-frontier.feishu.cn/ws/v2?device_id=1&service_id=9");
    try std.testing.expectEqualStrings("msg-frontier.feishu.cn", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
    try std.testing.expectEqualStrings("/ws/v2?device_id=1&service_id=9", u.path_query);
    try std.testing.expectEqualStrings("9", queryParam("wss://h/p?device_id=1&service_id=9", "service_id").?);
}

test "parseWss custom port" {
    const u = try parseWss("wss://example.com:8443/path");
    try std.testing.expectEqualStrings("example.com", u.host);
    try std.testing.expectEqual(@as(u16, 8443), u.port);
    try std.testing.expectEqualStrings("/path", u.path_query);
}

test "stripQuery removes query string" {
    try std.testing.expectEqualStrings("wss://h/p", stripQuery("wss://h/p?a=b&c=d"));
    try std.testing.expectEqualStrings("wss://h/p", stripQuery("wss://h/p"));
}

test "queryParam finds and misses keys" {
    const url = "wss://h/p?foo=bar&baz=qux";
    try std.testing.expectEqualStrings("bar", queryParam(url, "foo").?);
    try std.testing.expectEqualStrings("qux", queryParam(url, "baz").?);
    try std.testing.expect(queryParam(url, "missing") == null);
}

test "mask round-trip: writeFrame then parse raw bytes" {
    // Write a masked binary frame to an in-memory buffer, then manually parse
    // the raw RFC6455 bytes to verify: FIN+opcode=2, masked bit set, mask key,
    // and the payload unmasks to the original.
    const payload = "hello ws";
    const mask: [4]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF };

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFrame(&w, 0x82, &mask, payload);
    const frame = w.buffered();

    try std.testing.expectEqual(@as(u8, 0x82), frame[0]); // FIN + binary(2)
    try std.testing.expect((frame[1] & 0x80) != 0); // masked bit
    const raw_len = frame[1] & 0x7f;
    try std.testing.expectEqual(@as(u8, payload.len), raw_len); // fits in 7-bit
    const mask_off: usize = 2;
    const data_off = mask_off + 4;
    try std.testing.expectEqualSlices(u8, &mask, frame[mask_off..data_off]);

    // Unmask and compare.
    var recovered: [8]u8 = undefined;
    for (frame[data_off .. data_off + payload.len], 0..) |b, i| {
        recovered[i] = b ^ mask[i & 3];
    }
    try std.testing.expectEqualStrings(payload, recovered[0..payload.len]);
}
