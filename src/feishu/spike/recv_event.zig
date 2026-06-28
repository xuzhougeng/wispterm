//! Feishu long-connection spike — Step B/C/D (M0).
//! Connects to the wss endpoint from discover.zig, performs the WebSocket
//! handshake by hand on top of std's TLS connection, decodes pbbp2 Frames,
//! prints one received `im.message.receive_v1` event, ACKs it, and captures
//! raw-byte fixtures (endpoint response, one Data frame, one ping frame).
//!
//! Why hand-written WS: std has no WebSocket client, but std.http.Client.connect
//! gives a TLS-or-plain *Connection whose .writer()/.reader() are plain
//! std.Io streams. We reuse std's TLS and only hand-write RFC6455 framing +
//! pbbp2 — no third-party dependency. Auth is entirely in the URL query
//! (per oapi-sdk-go: dial passes a nil request header), so no custom upgrade
//! header is needed.
//!
//! Credentials read only from env (FEISHU_APP_ID / FEISHU_APP_SECRET); secrets,
//! tokens and the wss query string are never printed.
//!
//! Run: FEISHU_APP_ID=... FEISHU_APP_SECRET=... zig run src/feishu/spike/recv_event.zig
const std = @import("std");

const FIXTURE_DIR = "src/feishu/spike/fixtures";
const WS_RECV_TIMEOUT_S = 300; // wait up to 5 min for a message to be sent in.

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const app_id = try envOwned(alloc, "FEISHU_APP_ID");
    defer alloc.free(app_id);
    const app_secret = try envOwned(alloc, "FEISHU_APP_SECRET");
    defer alloc.free(app_secret);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --- Step: endpoint discovery (also captured as fixture #1) ---
    std.debug.print("[discover] POST /callback/ws/endpoint ...\n", .{});
    const ep_body = try std.fmt.allocPrint(arena,
        \\{{"AppID":"{s}","AppSecret":"{s}"}}
    , .{ app_id, app_secret });
    const ep_raw = try httpsPost(alloc, arena, "https://open.feishu.cn/callback/ws/endpoint", ep_body);
    try writeFixture(alloc, "01_endpoint_response.bin", redactWssInJson(arena, ep_raw));

    const ep = try parseEndpoint(arena, ep_raw);
    std.debug.print("[discover] code={d} wss_host_path={s} (query=<redacted>) ping_interval={d}s\n", .{
        ep.code, stripQuery(ep.url), ep.ping_interval,
    });
    if (ep.code != 0) {
        std.debug.print("[discover] FAILED code={d} msg={s}\n", .{ ep.code, ep.msg });
        std.process.exit(1);
    }

    // --- Parse wss URL: host, port, path+query, service_id ---
    const u = try parseWss(ep.url);
    const service_id = queryParam(ep.url, "service_id") orelse "";
    // ponytail: service_id is not a secret (a small int), safe to keep; not printed.

    // --- Step B: TLS connect + WS handshake ---
    std.debug.print("[ws] TLS connect {s}:{d} ...\n", .{ u.host, u.port });
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    // connect() (unlike fetch()) does not auto-load system root certs; do it here.
    try client.ca_bundle.rescan(alloc);
    const conn = client.connect(u.host, u.port, .tls) catch |err| {
        std.debug.print("BLOCKED: TLS connect failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer conn.destroy();

    try wsHandshake(conn, u.host, u.path_query);
    std.debug.print("[ws] handshake OK (HTTP 101)\n", .{});

    var ws = WsConn{ .conn = conn, .rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())) };

    // Send one ping immediately (Step C handshake/ping) and capture it (fixture #3).
    {
        const ping = try buildPingFrame(arena, service_id);
        try writeFixture(alloc, "03_ping_frame.bin", ping);
        try ws.writeBinary(ping);
        std.debug.print("[ws] sent ping (Control frame, header type=ping)\n", .{});
    }

    // --- Step C: receive loop ---
    std.debug.print("[ws] waiting up to {d}s for an inbound message (DM the bot a text now)...\n", .{WS_RECV_TIMEOUT_S});
    const deadline = std.time.timestamp() + WS_RECV_TIMEOUT_S;
    var got_event = false;
    while (std.time.timestamp() < deadline) {
        const msg = ws.readBinary(arena) catch |err| switch (err) {
            error.WsClosed => {
                std.debug.print("[ws] server closed connection\n", .{});
                break;
            },
            else => return err,
        };
        const frame = parseFrame(arena, msg) catch |err| {
            std.debug.print("[ws] frame decode error: {s} ({d} bytes)\n", .{ @errorName(err), msg.len });
            continue;
        };
        const ftype = frame.method;
        const htype = frame.header("type") orelse "";

        if (ftype == 0) { // Control
            std.debug.print("[ws] <- control frame type={s}\n", .{htype});
            continue;
        }
        // Data frame (method==1)
        std.debug.print("[ws] <- DATA frame type={s} ({d} payload bytes)\n", .{ htype, frame.payload.len });
        if (!got_event) {
            try writeFixture(alloc, "02_event_data_frame.bin", msg);
            got_event = true;
        }
        printEvent(frame.payload);

        // --- Step C: ACK by reusing the frame, payload = {"code":200}, +biz_rt ---
        const ack = try buildAck(arena, frame);
        try ws.writeBinary(ack);
        std.debug.print("[ws] -> ACK (code 200, biz_rt set)\n", .{});

        // One event proves the path; stop.
        break;
    }

    if (got_event) {
        std.debug.print("\nStep C DONE: received + decoded + ACKed one event.\n", .{});
    } else {
        std.debug.print("\nStep C INCOMPLETE: connected + handshake OK but no event arrived within timeout.\n", .{});
    }
}

// ===================== pbbp2 Frame =====================
// Frame: SeqID=1 varint, LogID=2 varint, service=3 varint, method=4 varint,
//        headers=5 repeated msg, payload_encoding=6 str, payload_type=7 str,
//        payload=8 bytes, LogIDNew=9 str.
// Header: key=1 str, value=2 str.

const Hdr = struct { key: []const u8, value: []const u8 };

const Frame = struct {
    seqid: u64 = 0,
    logid: u64 = 0,
    service: i64 = 0,
    method: i64 = 0,
    headers: []Hdr = &.{},
    payload_encoding: []const u8 = "",
    payload_type: []const u8 = "",
    payload: []const u8 = "",
    logid_new: []const u8 = "",

    fn header(self: Frame, key: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.mem.eql(u8, h.key, key)) return h.value;
        }
        return null;
    }
};

/// Decode a pbbp2 Frame from protobuf bytes.
fn parseFrame(arena: std.mem.Allocator, buf: []const u8) !Frame {
    var f = Frame{};
    var hdrs: std.ArrayListUnmanaged(Hdr) = .empty;
    var i: usize = 0;
    while (i < buf.len) {
        const tag = try readVarint(buf, &i);
        const field: u64 = tag >> 3;
        const wire: u3 = @intCast(tag & 0x7);
        switch (field) {
            1 => f.seqid = try readVarint(buf, &i),
            2 => f.logid = try readVarint(buf, &i),
            3 => f.service = @bitCast(try readVarint(buf, &i)),
            4 => f.method = @bitCast(try readVarint(buf, &i)),
            5 => try hdrs.append(arena, try parseHeader(buf, &i)),
            6 => f.payload_encoding = try readLenDelim(buf, &i),
            7 => f.payload_type = try readLenDelim(buf, &i),
            8 => f.payload = try readLenDelim(buf, &i),
            9 => f.logid_new = try readLenDelim(buf, &i),
            else => try skipField(buf, &i, wire),
        }
    }
    f.headers = hdrs.items;
    return f;
}

fn parseHeader(buf: []const u8, i: *usize) !Hdr {
    const sub = try readLenDelim(buf, i);
    var h = Hdr{ .key = "", .value = "" };
    var j: usize = 0;
    while (j < sub.len) {
        const tag = try readVarint(sub, &j);
        const field = tag >> 3;
        const wire: u3 = @intCast(tag & 0x7);
        switch (field) {
            1 => h.key = try readLenDelim(sub, &j),
            2 => h.value = try readLenDelim(sub, &j),
            else => try skipField(sub, &j, wire),
        }
    }
    return h;
}

fn readVarint(buf: []const u8, i: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (i.* >= buf.len) return error.Truncated;
        const b = buf[i.*];
        i.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

fn readLenDelim(buf: []const u8, i: *usize) ![]const u8 {
    const len = try readVarint(buf, i);
    if (i.* + len > buf.len) return error.Truncated;
    const out = buf[i.* .. i.* + len];
    i.* += len;
    return out;
}

fn skipField(buf: []const u8, i: *usize, wire: u3) !void {
    switch (wire) {
        0 => _ = try readVarint(buf, i),
        1 => i.* += 8,
        2 => _ = try readLenDelim(buf, i),
        5 => i.* += 4,
        else => return error.BadWireType,
    }
}

// --- protobuf encoders ---

fn appendVarint(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u64) !void {
    var x = v;
    while (true) {
        var b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x != 0) b |= 0x80;
        try out.append(a, b);
        if (x == 0) break;
    }
}

fn appendTag(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, field: u64, wire: u3) !void {
    try appendVarint(out, a, (field << 3) | wire);
}

fn appendVarintField(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, field: u64, v: u64) !void {
    try appendTag(out, a, field, 0);
    try appendVarint(out, a, v);
}

fn appendBytesField(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, field: u64, bytes: []const u8) !void {
    try appendTag(out, a, field, 2);
    try appendVarint(out, a, bytes.len);
    try out.appendSlice(a, bytes);
}

fn encodeHeader(a: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    var sub: std.ArrayListUnmanaged(u8) = .empty;
    try appendBytesField(&sub, a, 1, key);
    try appendBytesField(&sub, a, 2, value);
    return sub.items;
}

/// Serialize a Frame back to protobuf bytes (used for ping and ACK).
fn encodeFrame(a: std.mem.Allocator, f: Frame) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendVarintField(&out, a, 1, f.seqid);
    try appendVarintField(&out, a, 2, f.logid);
    try appendVarintField(&out, a, 3, @bitCast(f.service));
    try appendVarintField(&out, a, 4, @bitCast(f.method));
    for (f.headers) |h| {
        try appendBytesField(&out, a, 5, try encodeHeader(a, h.key, h.value));
    }
    if (f.payload_encoding.len != 0) try appendBytesField(&out, a, 6, f.payload_encoding);
    if (f.payload_type.len != 0) try appendBytesField(&out, a, 7, f.payload_type);
    if (f.payload.len != 0) try appendBytesField(&out, a, 8, f.payload);
    if (f.logid_new.len != 0) try appendBytesField(&out, a, 9, f.logid_new);
    return out.items;
}

fn buildPingFrame(a: std.mem.Allocator, service_id: []const u8) ![]u8 {
    const svc = std.fmt.parseInt(i64, service_id, 10) catch 0;
    const hdrs = try a.alloc(Hdr, 1);
    hdrs[0] = .{ .key = "type", .value = "ping" };
    return encodeFrame(a, .{ .method = 0, .service = svc, .headers = hdrs });
}

fn buildAck(a: std.mem.Allocator, recv: Frame) ![]u8 {
    // Reuse seqid/logid/service/method; replace payload with {"code":200}; add biz_rt.
    var hdrs: std.ArrayListUnmanaged(Hdr) = .empty;
    for (recv.headers) |h| try hdrs.append(a, h);
    try hdrs.append(a, .{ .key = "biz_rt", .value = "0" });
    return encodeFrame(a, .{
        .seqid = recv.seqid,
        .logid = recv.logid,
        .service = recv.service,
        .method = recv.method,
        .headers = hdrs.items,
        .payload = "{\"code\":200}",
    });
}

// ===================== WebSocket (RFC6455) =====================

const WsConn = struct {
    conn: *std.http.Client.Connection,
    rng: std.Random.DefaultPrng,

    /// Write one masked binary frame (client->server frames MUST be masked).
    fn writeBinary(self: *WsConn, payload: []const u8) !void {
        const w = self.conn.writer();
        var mask: [4]u8 = undefined;
        self.rng.random().bytes(&mask);

        var hdr: [14]u8 = undefined;
        var n: usize = 0;
        hdr[0] = 0x82; // FIN + opcode 2 (binary)
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
        @memcpy(hdr[n .. n + 4], &mask);
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
        try self.conn.flush();
    }

    /// Read one full message (handles control frames internally), returns the
    /// payload of the next binary/text data frame allocated in `a`.
    fn readBinary(self: *WsConn, a: std.mem.Allocator) ![]u8 {
        const r = self.conn.reader();
        while (true) {
            const b0 = try takeOne(r);
            const opcode = b0 & 0x0f;
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

            switch (opcode) {
                0x1, 0x2 => return data, // text or binary
                0x8 => return error.WsClosed, // close
                0x9 => { // ping -> pong (echo payload)
                    try self.writePong(data);
                    continue;
                },
                0xa => continue, // pong, ignore
                else => continue,
            }
        }
    }

    fn writePong(self: *WsConn, payload: []const u8) !void {
        const w = self.conn.writer();
        var mask: [4]u8 = undefined;
        self.rng.random().bytes(&mask);
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

fn takeOne(r: *std.Io.Reader) !u8 {
    const s = try r.take(1);
    return s[0];
}

/// Send the HTTP Upgrade request and verify a 101 response. No custom auth
/// header: per oapi-sdk-go the dial uses a nil request header (auth is in URL).
fn wsHandshake(conn: *std.http.Client.Connection, host: []const u8, path_query: []const u8) !void {
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
            // HTTP/1.1 101 ...
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

// ===================== Event printing =====================

fn printEvent(payload: []const u8) void {
    // Payload is plaintext JSON (per oapi-sdk-go: no decrypt/gzip).
    // Extract schema + the text content of im.message.receive_v1 if present.
    // ponytail: naive substring extraction, good enough for a spike print.
    const text = extractMessageText(payload);
    if (text) |t| {
        std.debug.print("[event] im.message text content: {s}\n", .{t});
    } else {
        // Fall back to printing a bounded excerpt of the JSON.
        const excerpt = payload[0..@min(payload.len, 600)];
        std.debug.print("[event] payload JSON (excerpt): {s}\n", .{excerpt});
    }
}

/// Pull the `"content"` string value out of message.receive_v1 JSON. The
/// content is itself a JSON string like {"text":"hi"} (escaped). We just print
/// it verbatim so the spike shows the round-trip works.
fn extractMessageText(payload: []const u8) ?[]const u8 {
    const needle = "\"content\":\"";
    const idx = std.mem.indexOf(u8, payload, needle) orelse return null;
    const start = idx + needle.len;
    // find unescaped closing quote
    var i = start;
    while (i < payload.len) : (i += 1) {
        if (payload[i] == '\\') {
            i += 1;
            continue;
        }
        if (payload[i] == '"') return payload[start..i];
    }
    return null;
}

// ===================== HTTP discovery + JSON parse =====================

const Endpoint = struct {
    code: i64,
    msg: []const u8,
    url: []const u8,
    ping_interval: i64,
};

fn parseEndpoint(a: std.mem.Allocator, raw: []const u8) !Endpoint {
    const ClientConfig = struct { PingInterval: i64 = 0 };
    const Data = struct { URL: []const u8 = "", ClientConfig: ClientConfig = .{} };
    const Resp = struct { code: i64 = -1, msg: []const u8 = "", data: Data = .{} };
    const r = try std.json.parseFromSliceLeaky(Resp, a, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return .{ .code = r.code, .msg = r.msg, .url = r.data.URL, .ping_interval = r.data.ClientConfig.PingInterval };
}

fn httpsPost(alloc: std.mem.Allocator, resp_arena: std.mem.Allocator, url: []const u8, body: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(resp_arena);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .keep_alive = false,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json; charset=utf-8" } },
        .response_writer = &out.writer,
    });
    if (response.status != .ok) {
        const items = out.toArrayList().items;
        std.debug.print("HTTP error {}: {s}\n", .{ response.status, items[0..@min(items.len, 256)] });
        return error.HttpError;
    }
    return out.toArrayList().items;
}

// ===================== URL helpers =====================

const WssUrl = struct { host: []const u8, port: u16, path_query: []const u8 };

fn parseWss(url: []const u8) !WssUrl {
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

fn queryParam(url: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var it = std.mem.splitScalar(u8, url[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn stripQuery(url: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    return url[0..q];
}

/// Replace everything after the first "wss://...?" up to the next quote with
/// <redacted>, so the captured endpoint fixture carries no connection token.
fn redactWssInJson(a: std.mem.Allocator, raw: []const u8) []const u8 {
    const marker = "wss://";
    const start = std.mem.indexOf(u8, raw, marker) orelse return raw;
    const q = std.mem.indexOfScalarPos(u8, raw, start, '?') orelse return raw;
    // find the closing quote of the URL string
    const end = std.mem.indexOfScalarPos(u8, raw, q, '"') orelse return raw;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(a, raw[0 .. q + 1]) catch return raw;
    out.appendSlice(a, "<redacted-query>") catch return raw;
    out.appendSlice(a, raw[end..]) catch return raw;
    return out.items;
}

// ===================== fixtures + env =====================

fn writeFixture(alloc: std.mem.Allocator, name: []const u8, bytes: []const u8) !void {
    std.fs.cwd().makePath(FIXTURE_DIR) catch {};
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURE_DIR, name });
    defer alloc.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
    std.debug.print("[fixture] wrote {s} ({d} bytes)\n", .{ path, bytes.len });
}

fn envOwned(a: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(a, name) catch |err| {
        std.debug.print("ERROR: {s} not set ({s})\n", .{ name, @errorName(err) });
        std.process.exit(1);
    };
}

// ===================== self-check =====================

test "pbbp2 round-trip: encode then decode a Frame" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const hdrs = try al.alloc(Hdr, 2);
    hdrs[0] = .{ .key = "type", .value = "event" };
    hdrs[1] = .{ .key = "message_id", .value = "m-123" };
    const original = Frame{
        .seqid = 7,
        .logid = 99,
        .service = 1,
        .method = 1,
        .headers = hdrs,
        .payload = "{\"hello\":\"world\"}",
    };
    const bytes = try encodeFrame(al, original);
    const decoded = try parseFrame(al, bytes);

    try std.testing.expectEqual(@as(u64, 7), decoded.seqid);
    try std.testing.expectEqual(@as(u64, 99), decoded.logid);
    try std.testing.expectEqual(@as(i64, 1), decoded.service);
    try std.testing.expectEqual(@as(i64, 1), decoded.method);
    try std.testing.expectEqualStrings("event", decoded.header("type").?);
    try std.testing.expectEqualStrings("m-123", decoded.header("message_id").?);
    try std.testing.expectEqualStrings("{\"hello\":\"world\"}", decoded.payload);
}

test "ping frame is control with type=ping" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const bytes = try buildPingFrame(al, "42");
    const f = try parseFrame(al, bytes);
    try std.testing.expectEqual(@as(i64, 0), f.method);
    try std.testing.expectEqual(@as(i64, 42), f.service);
    try std.testing.expectEqualStrings("ping", f.header("type").?);
}

test "ack reuses ids and sets code 200 + biz_rt" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const hdrs = try al.alloc(Hdr, 1);
    hdrs[0] = .{ .key = "type", .value = "event" };
    const recv = Frame{ .seqid = 5, .logid = 6, .service = 1, .method = 1, .headers = hdrs, .payload = "x" };
    const bytes = try buildAck(al, recv);
    const f = try parseFrame(al, bytes);
    try std.testing.expectEqual(@as(u64, 5), f.seqid);
    try std.testing.expectEqual(@as(i64, 1), f.method);
    try std.testing.expectEqualStrings("{\"code\":200}", f.payload);
    try std.testing.expect(f.header("biz_rt") != null);
}

test "extract message text from receive_v1-shaped json" {
    const json =
        \\{"schema":"2.0","header":{"event_type":"im.message.receive_v1"},"event":{"message":{"content":"{\"text\":\"hi\"}"}}}
    ;
    const t = extractMessageText(json).?;
    try std.testing.expectEqualStrings("{\\\"text\\\":\\\"hi\\\"}", t);
}

test "parseWss splits host port path" {
    const u = try parseWss("wss://msg-frontier.feishu.cn/ws/v2?device_id=1&service_id=9");
    try std.testing.expectEqualStrings("msg-frontier.feishu.cn", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
    try std.testing.expectEqualStrings("/ws/v2?device_id=1&service_id=9", u.path_query);
    try std.testing.expectEqualStrings("9", queryParam("wss://h/p?device_id=1&service_id=9", "service_id").?);
}

test "redactWssInJson removes the query string" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const out = redactWssInJson(arena.allocator(), "{\"data\":{\"URL\":\"wss://h/p?device_id=tok&x=y\"}}");
    try std.testing.expect(std.mem.indexOf(u8, out, "device_id=tok") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<redacted-query>") != null);
}
