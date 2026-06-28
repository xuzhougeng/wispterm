//! Feishu long-connection pbbp2 frame encode/decode (harvested verbatim from M0 spike).
const std = @import("std");

pub const Header = struct { key: []const u8, value: []const u8 };

pub const Frame = struct {
    seqid: u64 = 0,
    logid: u64 = 0,
    service: i64 = 0,
    method: i64 = 0,
    headers: []Header = &.{},
    payload_encoding: []const u8 = "",
    payload_type: []const u8 = "",
    payload: []const u8 = "",
    logid_new: []const u8 = "",

    pub fn header(self: Frame, key: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.mem.eql(u8, h.key, key)) return h.value;
        }
        return null;
    }
};

/// Decode a pbbp2 Frame from protobuf bytes.
pub fn decode(arena: std.mem.Allocator, buf: []const u8) !Frame {
    var f = Frame{};
    var hdrs: std.ArrayListUnmanaged(Header) = .empty;
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

fn parseHeader(buf: []const u8, i: *usize) !Header {
    const sub = try readLenDelim(buf, i);
    var h = Header{ .key = "", .value = "" };
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
pub fn encode(a: std.mem.Allocator, f: Frame) ![]u8 {
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

pub fn buildPing(a: std.mem.Allocator, service_id: []const u8) ![]u8 {
    const svc = std.fmt.parseInt(i64, service_id, 10) catch 0;
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .key = "type", .value = "ping" };
    return encode(a, .{ .method = 0, .service = svc, .headers = hdrs });
}

pub fn buildAck(a: std.mem.Allocator, recv: Frame) ![]u8 {
    // Reuse seqid/logid/service/method; replace payload with {"code":200}; add biz_rt.
    var hdrs: std.ArrayListUnmanaged(Header) = .empty;
    for (recv.headers) |h| try hdrs.append(a, h);
    try hdrs.append(a, .{ .key = "biz_rt", .value = "0" });
    return encode(a, .{
        .seqid = recv.seqid,
        .logid = recv.logid,
        .service = recv.service,
        .method = recv.method,
        .headers = hdrs.items,
        .payload = "{\"code\":200}",
    });
}

test "pbbp2 round-trip: encode then decode a Frame" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const hdrs = try al.alloc(Header, 2);
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
    const bytes = try encode(al, original);
    const decoded = try decode(al, bytes);

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
    const bytes = try buildPing(al, "42");
    const f = try decode(al, bytes);
    try std.testing.expectEqual(@as(i64, 0), f.method);
    try std.testing.expectEqual(@as(i64, 42), f.service);
    try std.testing.expectEqualStrings("ping", f.header("type").?);
}

test "ack reuses ids and sets code 200 + biz_rt" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const hdrs = try al.alloc(Header, 1);
    hdrs[0] = .{ .key = "type", .value = "event" };
    const recv = Frame{ .seqid = 5, .logid = 6, .service = 1, .method = 1, .headers = hdrs, .payload = "x" };
    const bytes = try buildAck(al, recv);
    const f = try decode(al, bytes);
    try std.testing.expectEqual(@as(u64, 5), f.seqid);
    try std.testing.expectEqual(@as(i64, 1), f.method);
    try std.testing.expectEqualStrings("{\"code\":200}", f.payload);
    try std.testing.expect(f.header("biz_rt") != null);
}
