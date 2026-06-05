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
};

pub const Header = std.http.Header;

pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    timeout_ms: u32 = 30_000,
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
    return impl.fetch(allocator, request);
}

pub fn methodName(method: Method) []const u8 {
    return switch (method) {
        .GET => "GET",
        .POST => "POST",
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
    const method: std.http.Method = switch (request.method) {
        .GET => .GET,
        .POST => .POST,
    };

    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16 * 1024,
    };
    defer client.deinit();

    // Non-native fallback: still honor conventional proxy env vars when a
    // platform backend does not exist.
    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    defer proxy_arena.deinit();
    try client.initDefaultProxies(proxy_arena.allocator());

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = method,
        .payload = request.body,
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
