const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    macos,
    unsupported,
};

pub fn backendForOs(comptime os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .macos => .macos,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("http_client_windows.zig"),
    .macos => @import("http_client_macos.zig"),
    .unsupported => @import("http_client_unsupported.zig"),
};

pub const Method = enum {
    GET,
    POST,
    /// WebDAV sync (sync/transport.zig) uploads, removes, and creates folders.
    PUT,
    DELETE,
    MKCOL,
};

pub const Header = std.http.Header;

pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    timeout_ms: u32 = 30_000,
    /// Explicit HTTP proxy (`host:port` or `http://host:port`).
    /// Null keeps the backend default: WinHTTP on Windows, the system session
    /// on macOS, and `https_proxy` / `http_proxy` / `all_proxy` on Linux.
    proxy: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn fetch(allocator: std.mem.Allocator, request: Request) !Response {
    if (request.proxy) |proxy| {
        if (std.mem.trim(u8, proxy, " \t\r\n").len > 0) return fetchUsingProxy(allocator, request, proxy);
    }
    return impl.fetch(allocator, request);
}

pub fn methodName(method: Method) []const u8 {
    return switch (method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .MKCOL => "MKCOL",
    };
}

pub fn buildHeaderBlock(allocator: std.mem.Allocator, headers: []const Header) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var w = out.writer(allocator);
    for (headers) |header| {
        try w.print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    return out.toOwnedSlice(allocator);
}

pub fn objectNameFromUri(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const uri_path: std.Uri.Component = if (uri.path.isEmpty()) .{ .percent_encoded = "/" } else uri.path;
    try uri_path.formatPath(&out.writer);
    if (uri.query) |query| {
        try out.writer.writeByte('?');
        try query.formatQuery(&out.writer);
    }
    var list = out.toArrayList();
    errdefer list.deinit(allocator);
    return list.toOwnedSlice(allocator);
}

pub fn fetchWithStdHttp(allocator: std.mem.Allocator, request: Request) !Response {
    // std.http.Client's built-in HTTPS proxy writes the request in cleartext
    // after CONNECT. Use an explicit TLS handshake on the tunnel instead.
    if (std.mem.startsWith(u8, request.url, "https://")) {
        if (proxyFromEnv(allocator)) |proxy| {
            defer allocator.free(proxy.host);
            return fetchViaHttpProxy(allocator, proxy, request);
        }
    }
    return fetchDirect(allocator, request);
}

fn fetchDirect(allocator: std.mem.Allocator, request: Request) !Response {
    const method: std.http.Method = switch (request.method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .DELETE => .DELETE,
        // std.http has no extension methods; the proxy path writes the verb raw.
        .MKCOL => return error.UnsupportedHttpMethod,
    };
    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16 * 1024,
    };
    defer client.deinit();
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = method,
        // std.http rejects a body on DELETE; GET/POST keep their old behavior.
        .payload = if (request.method == .DELETE) null else request.body,
        .headers = .{},
        .extra_headers = request.headers,
        .keep_alive = false,
        .response_writer = &response_body.writer,
    });
    var list = response_body.toArrayList();
    errdefer list.deinit(allocator);
    return .{
        .status = @intFromEnum(response.status),
        .body = try list.toOwnedSlice(allocator),
    };
}

const ProxyEndpoint = struct { host: []const u8, port: u16 };

pub const ParsedProxy = struct { host: []const u8, port: u16 };

/// `host:port`, `http://host:port`, or `https://host:port`. Empty is not a proxy.
/// The host slice points into `text`.
pub fn parseProxy(text: []const u8) ?ParsedProxy {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 255) return null;
    if (std.mem.indexOf(u8, trimmed, "://")) |scheme_end| {
        const scheme = trimmed[0..scheme_end];
        if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;
        const uri = std.Uri.parse(trimmed) catch return null;
        const host_component = uri.host orelse return null;
        var host = host_component.percent_encoded;
        if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
        if (host.len == 0 or host.len > 255) return null;
        return .{ .host = host, .port = uri.port orelse 80 };
    }
    const colon = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return null;
    if (colon == 0 or colon + 1 >= trimmed.len) return null;
    var host = trimmed[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    if (host.len == 0 or host.len > 255) return null;
    const port = std.fmt.parseInt(u16, trimmed[colon + 1 ..], 10) catch return null;
    if (port == 0) return null;
    return .{ .host = host, .port = port };
}

fn fetchUsingProxy(allocator: std.mem.Allocator, request: Request, proxy_text: []const u8) !Response {
    const parsed = parseProxy(proxy_text) orelse return error.InvalidProxy;
    const host = try allocator.dupe(u8, parsed.host);
    defer allocator.free(host);
    return fetchViaHttpProxy(allocator, .{ .host = host, .port = parsed.port }, request);
}

fn proxyFromEnv(allocator: std.mem.Allocator) ?ProxyEndpoint {
    const names = [_][]const u8{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY", "http_proxy", "HTTP_PROXY" };
    for (names) |name| {
        const value = std.process.getEnvVarOwned(allocator, name) catch continue;
        defer allocator.free(value);
        const parsed = parseProxy(value) orelse continue;
        const host = allocator.dupe(u8, parsed.host) catch continue;
        return .{ .host = host, .port = parsed.port };
    }
    return null;
}

fn fetchViaHttpProxy(allocator: std.mem.Allocator, proxy: ProxyEndpoint, request: Request) !Response {
    const uri = try std.Uri.parse(request.url);
    const host_component = uri.host orelse return error.MissingHost;
    const host = host_component.percent_encoded;
    const port: u16 = uri.port orelse 443;
    const object_name = try objectNameFromUri(allocator, uri);
    defer allocator.free(object_name);

    const stream = try std.net.tcpConnectToHost(allocator, proxy.host, proxy.port);
    defer stream.close();
    const socket_read = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer allocator.free(socket_read);
    const socket_write = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer allocator.free(socket_write);
    var socket_reader = stream.reader(socket_read);
    var socket_writer = stream.writer(socket_write);

    const connect_req = try std.fmt.allocPrint(allocator, "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ host, port, host, port });
    defer allocator.free(connect_req);
    try socket_writer.interface.writeAll(connect_req);
    try socket_writer.interface.flush();
    var connect_head: [512]u8 = undefined;
    const connect_len = try readUntilHeaderEnd(socket_reader.interface(), &connect_head);
    if (std.mem.indexOf(u8, connect_head[0..connect_len], " 200 ") == null) return error.ProxyConnectFailed;

    var bundle: std.crypto.Certificate.Bundle = .{};
    defer bundle.deinit(allocator);
    try bundle.rescan(allocator);
    const tls_read = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer allocator.free(tls_read);
    const tls_write = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer allocator.free(tls_write);
    var tls = try std.crypto.tls.Client.init(socket_reader.interface(), &socket_writer.interface, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = bundle },
        .read_buffer = tls_read,
        .write_buffer = tls_write,
    });

    var head: std.ArrayListUnmanaged(u8) = .empty;
    defer head.deinit(allocator);
    try head.writer(allocator).print("{s} {s} HTTP/1.1\r\nHost: {s}\r\n", .{ methodName(request.method), object_name, host });
    for (request.headers) |header| {
        try head.writer(allocator).print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    try head.writer(allocator).print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{request.body.len});
    try tls.writer.writeAll(head.items);
    if (request.body.len > 0) try tls.writer.writeAll(request.body);
    try tls.writer.flush();
    try socket_writer.interface.flush();

    var raw: std.ArrayListUnmanaged(u8) = .empty;
    defer raw.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (raw.items.len < 8 * 1024 * 1024) {
        const n = tls.reader.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try raw.appendSlice(allocator, chunk[0..n]);
        if (std.mem.indexOf(u8, raw.items, "\r\n\r\n")) |header_end| {
            const header = raw.items[0..header_end];
            const payload = raw.items[header_end + 4 ..];
            if (transferEncodingIsChunked(header)) {
                if (chunkedBodyComplete(payload)) break;
            } else if (contentLengthOf(header)) |length| {
                if (payload.len >= length) break;
            }
        }
    }
    const header_end = std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return error.BadHttpResponse;
    const header = raw.items[0..header_end];
    const status = httpStatusCode(header) orelse return error.BadHttpResponse;
    const payload = raw.items[header_end + 4 ..];
    const body = if (transferEncodingIsChunked(header))
        try decodeChunkedBody(allocator, payload)
    else
        try allocator.dupe(u8, payload);
    return .{
        .status = status,
        .body = body,
    };
}

fn readUntilHeaderEnd(reader: *std.Io.Reader, buf: []u8) !usize {
    var len: usize = 0;
    while (len + 1 < buf.len) {
        const n = reader.readSliceShort(buf[len .. len + 1]) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") != null) return len;
    }
    return error.HeaderTooLarge;
}

fn httpStatusCode(header: []const u8) ?u16 {
    const line_end = std.mem.indexOfScalar(u8, header, '\r') orelse header.len;
    var parts = std.mem.tokenizeScalar(u8, header[0..line_end], ' ');
    _ = parts.next() orelse return null;
    const code = parts.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

fn contentLengthOf(header: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return null;
}

fn transferEncodingIsChunked(header: []const u8) bool {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "transfer-encoding")) continue;
        if (std.ascii.indexOfIgnoreCase(line[colon + 1 ..], "chunked") != null) return true;
    }
    return false;
}

fn chunkSizeLine(raw: []const u8, i: usize) ?struct { size: usize, next: usize } {
    const rel = std.mem.indexOf(u8, raw[i..], "\r\n") orelse return null;
    const line_end = i + rel;
    const size_token = std.mem.sliceTo(std.mem.trim(u8, raw[i..line_end], " \t"), ';');
    const size = std.fmt.parseInt(usize, size_token, 16) catch return null;
    return .{ .size = size, .next = line_end + 2 };
}

fn chunkedBodyComplete(raw: []const u8) bool {
    var i: usize = 0;
    while (i < raw.len) {
        const line = chunkSizeLine(raw, i) orelse return false;
        i = line.next;
        if (line.size == 0) return true;
        if (i + line.size + 2 > raw.len) return false;
        i += line.size;
        if (!std.mem.eql(u8, raw[i .. i + 2], "\r\n")) return false;
        i += 2;
    }
    return false;
}

fn decodeChunkedBody(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        const line = chunkSizeLine(raw, i) orelse return error.BadHttpResponse;
        i = line.next;
        if (line.size == 0) break;
        if (i + line.size + 2 > raw.len) return error.BadHttpResponse;
        try out.appendSlice(allocator, raw[i .. i + line.size]);
        i += line.size;
        if (!std.mem.eql(u8, raw[i .. i + 2], "\r\n")) return error.BadHttpResponse;
        i += 2;
    }
    return out.toOwnedSlice(allocator);
}

test "platform http client parses an explicit proxy address" {
    const plain = parseProxy("127.0.0.1:6789").?;
    try std.testing.expectEqualStrings("127.0.0.1", plain.host);
    try std.testing.expectEqual(@as(u16, 6789), plain.port);
    const url = parseProxy("http://127.0.0.1:7890").?;
    try std.testing.expectEqualStrings("127.0.0.1", url.host);
    try std.testing.expectEqual(@as(u16, 7890), url.port);
    const v6 = parseProxy("[::1]:8080").?;
    try std.testing.expectEqualStrings("::1", v6.host);
    try std.testing.expectEqual(@as(u16, 8080), v6.port);
    try std.testing.expect(parseProxy("") == null);
    try std.testing.expect(parseProxy("socks5://127.0.0.1:1080") == null);
    try std.testing.expect(parseProxy("127.0.0.1") == null);
}

test "platform http client parses a status line and content length" {
    const header = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n";
    try std.testing.expectEqual(@as(u16, 200), httpStatusCode(header).?);
    try std.testing.expectEqual(@as(usize, 4), contentLengthOf(header).?);
    try std.testing.expect(!transferEncodingIsChunked(header));
}

test "platform http client decodes a chunked body" {
    const header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n";
    try std.testing.expect(transferEncodingIsChunked(header));
    const raw = "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n";
    try std.testing.expect(chunkedBodyComplete(raw));
    try std.testing.expect(!chunkedBodyComplete("5\r\nhel"));
    const body = try decodeChunkedBody(std.testing.allocator, raw);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello world", body);
}

test "platform http client selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.macos, backendForOs(.macos));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
}

test "platform http client builds CRLF header blocks" {
    const headers = [_]Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "X-Test", .value = "yes" },
    };
    const text = try buildHeaderBlock(std.testing.allocator, &headers);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Accept: application/json\r\nX-Test: yes\r\n", text);
}

test "platform http client builds URI object name with query" {
    const uri = try std.Uri.parse("https://example.test/search?q=a%20b");
    const object_name = try objectNameFromUri(std.testing.allocator, uri);
    defer std.testing.allocator.free(object_name);
    try std.testing.expectEqualStrings("/search?q=a%20b", object_name);
}
