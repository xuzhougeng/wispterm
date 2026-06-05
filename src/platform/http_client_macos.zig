const std = @import("std");
const http_client = @import("http_client.zig");

const CHeader = extern struct {
    name: [*:0]const u8,
    value: [*:0]const u8,
};

const CResponse = extern struct {
    status: i32,
    body: ?*anyopaque,
    body_len: i32,
    error_code: i32,
};

extern fn wispterm_macos_http_fetch(
    method: [*:0]const u8,
    url: [*:0]const u8,
    headers: ?[*]const CHeader,
    header_count: c_int,
    body: ?*const anyopaque,
    body_len: c_int,
    timeout_ms: c_int,
    out: *CResponse,
) c_int;

extern fn wispterm_macos_http_free(ptr: ?*anyopaque) void;

pub fn fetch(allocator: std.mem.Allocator, request: http_client.Request) !http_client.Response {
    const method_z = try allocator.dupeZ(u8, http_client.methodName(request.method));
    defer allocator.free(method_z);
    const url_z = try allocator.dupeZ(u8, request.url);
    defer allocator.free(url_z);

    var names = try allocator.alloc(?[:0]u8, request.headers.len);
    defer allocator.free(names);
    @memset(names, null);
    var values = try allocator.alloc(?[:0]u8, request.headers.len);
    defer allocator.free(values);
    @memset(values, null);
    var c_headers = try allocator.alloc(CHeader, request.headers.len);
    defer allocator.free(c_headers);
    for (request.headers, 0..) |header, i| {
        names[i] = try allocator.dupeZ(u8, header.name);
        values[i] = try allocator.dupeZ(u8, header.value);
        c_headers[i] = .{ .name = names[i].?.ptr, .value = values[i].?.ptr };
    }
    defer {
        for (names) |name| if (name) |n| allocator.free(n);
        for (values) |value| if (value) |v| allocator.free(v);
    }

    var response: CResponse = .{
        .status = 0,
        .body = null,
        .body_len = 0,
        .error_code = 0,
    };
    const body_ptr: ?*const anyopaque = if (request.body.len > 0) @ptrCast(request.body.ptr) else null;
    const ok = wispterm_macos_http_fetch(
        method_z.ptr,
        url_z.ptr,
        if (c_headers.len > 0) c_headers.ptr else null,
        @intCast(c_headers.len),
        body_ptr,
        @intCast(request.body.len),
        @intCast(request.timeout_ms),
        &response,
    );
    defer wispterm_macos_http_free(response.body);
    if (ok == 0) return macosNetworkError(response.error_code);
    if (response.body_len < 0) return error.MacosHttpRequestFailed;

    const len: usize = @intCast(response.body_len);
    const out = try allocator.alloc(u8, len);
    if (len > 0) {
        const src: [*]const u8 = @ptrCast(response.body.?);
        @memcpy(out, src[0..len]);
    }
    return .{
        .status = @intCast(response.status),
        .body = out,
    };
}

fn macosNetworkError(code: i32) anyerror {
    return switch (code) {
        -1001 => error.ConnectionTimedOut,
        -1003, -1006 => error.UnknownHostName,
        -1004 => error.ConnectionRefused,
        -1005 => error.ConnectionResetByPeer,
        -1009 => error.NetworkUnreachable,
        -1200, -1201, -1202, -1203, -1204, -1205, -1206 => error.TlsInitializationFailed,
        -1002 => error.UnsupportedUriScheme,
        -3 => error.OutOfMemory,
        -2 => error.ConnectionTimedOut,
        else => error.MacosHttpRequestFailed,
    };
}
