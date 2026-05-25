const std = @import("std");
const windows = std.os.windows;

pub const io_chunk_size = 16 * 1024;

const HINTERNET = *opaque {};

pub const WebSocketHandle = HINTERNET;

pub const Endpoint = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    object_name: []const u8,
};

pub const BufferType = enum {
    utf8_message,
    utf8_fragment,
    close,
    other,
};

pub const ReceiveResult = struct {
    bytes_read: usize,
    buffer_type: BufferType,
};

pub const Handles = struct {
    session: ?HINTERNET = null,
    connect: ?HINTERNET = null,
    request: ?HINTERNET = null,
    websocket: ?WebSocketHandle = null,

    pub fn close(self: *Handles) void {
        if (self.websocket) |h| {
            _ = WinHttpWebSocketClose(h, winhttp_web_socket_success_close_status, null, 0);
            _ = WinHttpCloseHandle(h);
            self.websocket = null;
        }
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

extern "winhttp" fn WinHttpSetOption(
    hInternet: HINTERNET,
    dwOption: windows.DWORD,
    lpBuffer: ?*anyopaque,
    dwBufferLength: windows.DWORD,
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

extern "winhttp" fn WinHttpWebSocketCompleteUpgrade(
    hRequest: HINTERNET,
    pContext: usize,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpWebSocketSend(
    hWebSocket: HINTERNET,
    eBufferType: windows.DWORD,
    pvBuffer: ?*anyopaque,
    dwBufferLength: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "winhttp" fn WinHttpWebSocketReceive(
    hWebSocket: HINTERNET,
    pvBuffer: ?*anyopaque,
    dwBufferLength: windows.DWORD,
    pdwBytesRead: *windows.DWORD,
    peBufferType: *windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "winhttp" fn WinHttpWebSocketClose(
    hWebSocket: HINTERNET,
    usStatus: u16,
    pvReason: ?*anyopaque,
    dwReasonLength: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "winhttp" fn WinHttpCloseHandle(hInternet: HINTERNET) callconv(.winapi) windows.BOOL;

const winhttp_access_type_default_proxy: windows.DWORD = 0;
const winhttp_flag_secure: windows.DWORD = 0x00800000;
const winhttp_option_upgrade_to_web_socket: windows.DWORD = 114;
const winhttp_web_socket_utf8_message_buffer_type: windows.DWORD = 2;
const winhttp_web_socket_utf8_fragment_buffer_type: windows.DWORD = 3;
const winhttp_web_socket_close_buffer_type: windows.DWORD = 4;
const winhttp_web_socket_success_close_status: u16 = 1000;

pub fn connect(allocator: std.mem.Allocator, endpoint: Endpoint) !Handles {
    var handles: Handles = .{};
    errdefer handles.close();

    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Phantty Remote");
    handles.session = WinHttpOpen(agent, winhttp_access_type_default_proxy, null, null, 0) orelse return error.WinHttpOpenFailed;

    const host_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, endpoint.host);
    defer allocator.free(host_w);
    handles.connect = WinHttpConnect(handles.session.?, host_w, endpoint.port, 0) orelse return error.WinHttpConnectFailed;

    const get_w = std.unicode.utf8ToUtf16LeStringLiteral("GET");
    const object_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, endpoint.object_name);
    defer allocator.free(object_w);

    const flags: windows.DWORD = if (endpoint.secure) winhttp_flag_secure else 0;
    handles.request = WinHttpOpenRequest(handles.connect.?, get_w, object_w, null, null, null, flags) orelse return error.WinHttpOpenRequestFailed;

    if (WinHttpSetOption(handles.request.?, winhttp_option_upgrade_to_web_socket, null, 0) == 0) {
        return error.WinHttpUpgradeOptionFailed;
    }
    if (WinHttpSendRequest(handles.request.?, null, 0, null, 0, 0, 0) == 0) {
        return error.WinHttpSendRequestFailed;
    }
    if (WinHttpReceiveResponse(handles.request.?, null) == 0) {
        return error.WinHttpReceiveResponseFailed;
    }

    handles.websocket = WinHttpWebSocketCompleteUpgrade(handles.request.?, 0) orelse return error.WinHttpCompleteUpgradeFailed;
    return handles;
}

pub fn receive(websocket: WebSocketHandle, buffer: []u8) !ReceiveResult {
    var bytes_read: windows.DWORD = 0;
    var raw_buffer_type: windows.DWORD = 0;
    const rc = WinHttpWebSocketReceive(
        websocket,
        buffer.ptr,
        @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD))),
        &bytes_read,
        &raw_buffer_type,
    );
    if (rc != 0) return error.ReceiveFailed;
    return .{
        .bytes_read = @intCast(bytes_read),
        .buffer_type = decodeBufferType(raw_buffer_type),
    };
}

pub fn sendUtf8(websocket: WebSocketHandle, message: []const u8) bool {
    if (message.len <= io_chunk_size) {
        return sendUtf8Chunk(websocket, message, winhttp_web_socket_utf8_message_buffer_type);
    }

    var offset: usize = 0;
    while (offset < message.len) {
        const remaining = message.len - offset;
        const take = @min(io_chunk_size, remaining);
        const end = offset + take;
        const buffer_type: windows.DWORD = if (end == message.len)
            winhttp_web_socket_utf8_message_buffer_type
        else
            winhttp_web_socket_utf8_fragment_buffer_type;
        if (!sendUtf8Chunk(websocket, message[offset..end], buffer_type)) return false;
        offset = end;
    }
    return true;
}

fn sendUtf8Chunk(websocket: WebSocketHandle, message: []const u8, buffer_type: windows.DWORD) bool {
    return WinHttpWebSocketSend(
        websocket,
        buffer_type,
        @constCast(message.ptr),
        @intCast(message.len),
    ) == 0;
}

fn decodeBufferType(raw: windows.DWORD) BufferType {
    return switch (raw) {
        winhttp_web_socket_utf8_message_buffer_type => .utf8_message,
        winhttp_web_socket_utf8_fragment_buffer_type => .utf8_fragment,
        winhttp_web_socket_close_buffer_type => .close,
        else => .other,
    };
}
