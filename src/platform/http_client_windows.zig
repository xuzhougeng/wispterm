const std = @import("std");
const windows = std.os.windows;
const http_client = @import("http_client.zig");

const HINTERNET = *opaque {};

extern "winhttp" fn WinHttpOpen(
    pszAgentW: ?windows.LPCWSTR,
    dwAccessType: windows.DWORD,
    pszProxyW: ?windows.LPCWSTR,
    pszProxyBypassW: ?windows.LPCWSTR,
    dwFlags: windows.DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpConnect(
    hSession: HINTERNET,
    pswzServerName: windows.LPCWSTR,
    nServerPort: u16,
    dwReserved: windows.DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpOpenRequest(
    hConnect: HINTERNET,
    pwszVerb: windows.LPCWSTR,
    pwszObjectName: windows.LPCWSTR,
    pwszVersion: ?windows.LPCWSTR,
    pwszReferrer: ?windows.LPCWSTR,
    ppwszAcceptTypes: ?*const ?windows.LPCWSTR,
    dwFlags: windows.DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpSetTimeouts(
    hInternet: HINTERNET,
    dwResolveTimeout: c_int,
    dwConnectTimeout: c_int,
    dwSendTimeout: c_int,
    dwReceiveTimeout: c_int,
) callconv(.winapi) windows.BOOL;

extern "winhttp" fn WinHttpSendRequest(
    hRequest: HINTERNET,
    lpszHeaders: ?windows.LPCWSTR,
    dwHeadersLength: windows.DWORD,
    lpOptional: ?*anyopaque,
    dwOptionalLength: windows.DWORD,
    dwTotalLength: windows.DWORD,
    dwContext: usize,
) callconv(.winapi) windows.BOOL;

extern "winhttp" fn WinHttpReceiveResponse(
    hRequest: HINTERNET,
    lpReserved: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "winhttp" fn WinHttpQueryHeaders(
    hRequest: HINTERNET,
    dwInfoLevel: windows.DWORD,
    pwszName: ?windows.LPCWSTR,
    lpBuffer: ?*anyopaque,
    lpdwBufferLength: *windows.DWORD,
    lpdwIndex: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "winhttp" fn WinHttpReadData(
    hRequest: HINTERNET,
    lpBuffer: ?*anyopaque,
    dwNumberOfBytesToRead: windows.DWORD,
    lpdwNumberOfBytesRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "winhttp" fn WinHttpCloseHandle(hInternet: HINTERNET) callconv(.winapi) windows.BOOL;

const winhttp_access_type_automatic_proxy: windows.DWORD = 4;
const winhttp_flag_secure: windows.DWORD = 0x00800000;
const winhttp_query_status_code: windows.DWORD = 19;
const winhttp_query_flag_number: windows.DWORD = 0x20000000;

const error_winhttp_timeout: u32 = 12002;
const error_winhttp_incorrect_handle_state: u32 = 12019;
const error_winhttp_name_not_resolved: u32 = 12007;
const error_winhttp_cannot_connect: u32 = 12029;
const error_winhttp_connection_error: u32 = 12030;
const error_winhttp_resend_request: u32 = 12032;
const error_winhttp_secure_failure: u32 = 12175;
const error_winhttp_client_auth_cert_needed: u32 = 12044;
const error_winhttp_secure_cert_date_invalid: u32 = 12037;
const error_winhttp_secure_cert_cn_invalid: u32 = 12038;
const error_winhttp_secure_invalid_ca: u32 = 12045;
const error_winhttp_secure_cert_rev_failed: u32 = 12057;
const error_winhttp_bad_auto_proxy_script: u32 = 12166;
const error_winhttp_unable_to_download_script: u32 = 12167;
const error_winhttp_auto_proxy_service_error: u32 = 12178;
const error_winhttp_autodetection_failed: u32 = 12180;

const Handles = struct {
    session: ?HINTERNET = null,
    connect: ?HINTERNET = null,
    request: ?HINTERNET = null,

    fn close(self: *Handles) void {
        if (self.request) |h| {
            _ = WinHttpCloseHandle(h);
            self.request = null;
        }
        if (self.connect) |h| {
            _ = WinHttpCloseHandle(h);
            self.connect = null;
        }
        if (self.session) |h| {
            _ = WinHttpCloseHandle(h);
            self.session = null;
        }
    }
};

pub fn fetch(allocator: std.mem.Allocator, request: http_client.Request) !http_client.Response {
    const uri = try std.Uri.parse(request.url);
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.UnsupportedUriScheme;
    const secure = std.mem.eql(u8, uri.scheme, "https");
    const port: u16 = uri.port orelse if (secure) 443 else 80;
    var uri_arena = std.heap.ArenaAllocator.init(allocator);
    defer uri_arena.deinit();
    const host = try uri.getHostAlloc(uri_arena.allocator());
    const object_name = try http_client.objectNameFromUri(allocator, uri);
    defer allocator.free(object_name);
    const header_block = try http_client.buildHeaderBlock(allocator, request.headers);
    defer allocator.free(header_block);

    const host_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, host);
    defer allocator.free(host_w);
    const object_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, object_name);
    defer allocator.free(object_w);
    const method_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, http_client.methodName(request.method));
    defer allocator.free(method_w);
    const header_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, header_block);
    defer allocator.free(header_w);

    var handles: Handles = .{};
    defer handles.close();

    const agent = std.unicode.utf8ToUtf16LeStringLiteral("WispTerm");
    handles.session = WinHttpOpen(agent, winhttp_access_type_automatic_proxy, null, null, 0) orelse return winHttpError();
    _ = WinHttpSetTimeouts(
        handles.session.?,
        @intCast(request.timeout_ms),
        @intCast(request.timeout_ms),
        @intCast(request.timeout_ms),
        @intCast(request.timeout_ms),
    );
    handles.connect = WinHttpConnect(handles.session.?, host_w.ptr, port, 0) orelse return winHttpError();
    handles.request = WinHttpOpenRequest(
        handles.connect.?,
        method_w.ptr,
        object_w.ptr,
        null,
        null,
        null,
        if (secure) winhttp_flag_secure else 0,
    ) orelse return winHttpError();

    const optional: ?*anyopaque = if (request.body.len > 0) @constCast(request.body.ptr) else null;
    if (WinHttpSendRequest(
        handles.request.?,
        if (header_w.len > 0) header_w.ptr else null,
        if (header_w.len > 0) @intCast(header_w.len) else 0,
        optional,
        @intCast(request.body.len),
        @intCast(request.body.len),
        0,
    ) == 0) return winHttpError();

    if (WinHttpReceiveResponse(handles.request.?, null) == 0) return winHttpError();

    var status_u32: windows.DWORD = 0;
    var status_len: windows.DWORD = @sizeOf(windows.DWORD);
    if (WinHttpQueryHeaders(
        handles.request.?,
        winhttp_query_status_code | winhttp_query_flag_number,
        null,
        &status_u32,
        &status_len,
        null,
    ) == 0) return winHttpError();

    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        var bytes_read: windows.DWORD = 0;
        if (WinHttpReadData(
            handles.request.?,
            &buffer,
            @intCast(buffer.len),
            &bytes_read,
        ) == 0) return winHttpError();
        if (bytes_read == 0) break;
        try body.appendSlice(allocator, buffer[0..bytes_read]);
    }

    return .{
        .status = @intCast(status_u32),
        .body = try body.toOwnedSlice(allocator),
    };
}

fn winHttpError() anyerror {
    const code = @intFromEnum(windows.GetLastError());
    std.log.warn("WinHTTP request failed: {d}", .{code});
    return switch (code) {
        error_winhttp_timeout => error.ConnectionTimedOut,
        error_winhttp_name_not_resolved => error.UnknownHostName,
        error_winhttp_cannot_connect => error.ConnectionRefused,
        error_winhttp_connection_error,
        error_winhttp_resend_request,
        error_winhttp_incorrect_handle_state,
        => error.ConnectionResetByPeer,
        error_winhttp_secure_failure,
        error_winhttp_client_auth_cert_needed,
        error_winhttp_secure_cert_date_invalid,
        error_winhttp_secure_cert_cn_invalid,
        error_winhttp_secure_invalid_ca,
        error_winhttp_secure_cert_rev_failed,
        => error.TlsInitializationFailed,
        error_winhttp_bad_auto_proxy_script,
        error_winhttp_unable_to_download_script,
        error_winhttp_auto_proxy_service_error,
        error_winhttp_autodetection_failed,
        => error.ProxyConfigurationFailed,
        else => error.WinHttpRequestFailed,
    };
}
