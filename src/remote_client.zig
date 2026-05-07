//! Outbound remote relay client shared by one Phantty instance.
//!
//! Surfaces do not own network state. They only publish PTY output into this
//! shared client, so every tab/split in a started Phantty instance uses one
//! RemoteClient and one session key.

const std = @import("std");
const windows = std.os.windows;

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

extern "winhttp" fn WinHttpWebSocketClose(
    hWebSocket: HINTERNET,
    usStatus: u16,
    pvReason: ?*anyopaque,
    dwReasonLength: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "winhttp" fn WinHttpCloseHandle(hInternet: HINTERNET) callconv(.winapi) windows.BOOL;

const WINHTTP_ACCESS_TYPE_DEFAULT_PROXY: windows.DWORD = 0;
const WINHTTP_FLAG_SECURE: windows.DWORD = 0x00800000;
const WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET: windows.DWORD = 114;
const WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE: windows.DWORD = 2;
const WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS: u16 = 1000;

const QUEUE_LIMIT = 512;
const RETRY_DELAY_NS = 2 * std.time.ns_per_s;

pub const State = enum(u8) {
    disabled,
    connecting,
    connected,
    disconnected,
    failed,
};

pub const Options = struct {
    server_url: []const u8,
    device_name: ?[]const u8 = null,
};

const Endpoint = struct {
    secure: bool,
    host: []u8,
    port: u16,
    object_name: []u8,

    fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.object_name);
    }
};

const Handles = struct {
    session: ?HINTERNET = null,
    connect: ?HINTERNET = null,
    request: ?HINTERNET = null,
    websocket: ?HINTERNET = null,

    fn close(self: *Handles) void {
        if (self.websocket) |h| {
            _ = WinHttpWebSocketClose(h, WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, null, 0);
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

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: Endpoint,
    device_name: ?[]u8,
    session_key: [32]u8,

    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.disconnected),
    thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Client {
        const client = try allocator.create(Client);
        errdefer allocator.destroy(client);

        var key: [32]u8 = undefined;
        fillSessionKey(&key);

        var endpoint = try buildEndpoint(allocator, options.server_url, &key, options.device_name);
        errdefer endpoint.deinit(allocator);

        const device_name = if (options.device_name) |name| try allocator.dupe(u8, name) else null;
        errdefer if (device_name) |name| allocator.free(name);

        client.* = .{
            .allocator = allocator,
            .endpoint = endpoint,
            .device_name = device_name,
            .session_key = key,
        };

        client.thread = try std.Thread.spawn(.{}, threadMain, .{client});
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.stop_requested.store(true, .release);
        self.condition.broadcast();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.mutex.lock();
        while (self.queue.pop()) |message| {
            self.allocator.free(message);
        }
        self.mutex.unlock();

        self.endpoint.deinit(self.allocator);
        if (self.device_name) |name| self.allocator.free(name);
    }

    pub fn destroy(self: *Client) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn sessionKey(self: *const Client) []const u8 {
        return self.session_key[0..];
    }

    pub fn loadState(self: *const Client) State {
        return self.state.load(.acquire);
    }

    pub fn sendOutput(self: *Client, data: []const u8) void {
        if (data.len == 0 or self.stop_requested.load(.acquire)) return;

        const message = buildOutputMessage(self.allocator, data) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.items.len >= QUEUE_LIMIT) {
            const dropped = self.queue.orderedRemove(0);
            self.allocator.free(dropped);
        }
        self.queue.append(self.allocator, message) catch {
            self.allocator.free(message);
            return;
        };
        self.condition.signal();
    }

    fn popMessage(self: *Client) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn waitForMessageOrStop(self: *Client) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.items.len == 0 and !self.stop_requested.load(.acquire)) {
            self.condition.timedWait(&self.mutex, std.time.ns_per_s) catch {};
        }
        return !self.stop_requested.load(.acquire);
    }
};

fn threadMain(client: *Client) void {
    while (!client.stop_requested.load(.acquire)) {
        client.state.store(.connecting, .release);
        var handles = connectWebSocket(client) catch |err| {
            client.state.store(.failed, .release);
            std.debug.print("Remote client connect failed: {}\n", .{err});
            sleepUntilRetryOrStop(client);
            continue;
        };
        defer handles.close();

        client.state.store(.connected, .release);
        std.debug.print("Remote client connected\n", .{});

        while (!client.stop_requested.load(.acquire)) {
            const message = client.popMessage() orelse {
                if (!client.waitForMessageOrStop()) break;
                continue;
            };
            defer client.allocator.free(message);

            const websocket = handles.websocket orelse break;
            if (WinHttpWebSocketSend(
                websocket,
                WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                @constCast(message.ptr),
                @intCast(message.len),
            ) != 0) {
                client.state.store(.disconnected, .release);
                break;
            }
        }

        handles.close();
        if (!client.stop_requested.load(.acquire)) {
            client.state.store(.disconnected, .release);
            sleepUntilRetryOrStop(client);
        }
    }

    client.state.store(.disabled, .release);
}

fn sleepUntilRetryOrStop(client: *Client) void {
    const step_ns = 100 * std.time.ns_per_ms;
    var elapsed: u64 = 0;
    while (elapsed < RETRY_DELAY_NS and !client.stop_requested.load(.acquire)) : (elapsed += step_ns) {
        std.Thread.sleep(step_ns);
    }
}

fn connectWebSocket(client: *Client) !Handles {
    var handles: Handles = .{};
    errdefer handles.close();

    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Phantty Remote");
    handles.session = WinHttpOpen(agent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0) orelse return error.WinHttpOpenFailed;

    const host_w = try std.unicode.utf8ToUtf16LeAllocZ(client.allocator, client.endpoint.host);
    defer client.allocator.free(host_w);
    handles.connect = WinHttpConnect(handles.session.?, host_w, client.endpoint.port, 0) orelse return error.WinHttpConnectFailed;

    const get_w = std.unicode.utf8ToUtf16LeStringLiteral("GET");
    const object_w = try std.unicode.utf8ToUtf16LeAllocZ(client.allocator, client.endpoint.object_name);
    defer client.allocator.free(object_w);

    const flags: windows.DWORD = if (client.endpoint.secure) WINHTTP_FLAG_SECURE else 0;
    handles.request = WinHttpOpenRequest(handles.connect.?, get_w, object_w, null, null, null, flags) orelse return error.WinHttpOpenRequestFailed;

    if (WinHttpSetOption(handles.request.?, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, null, 0) == 0) {
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

fn fillSessionKey(out: *[32]u8) void {
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const hex = "0123456789abcdef";
    for (random, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
}

fn buildEndpoint(
    allocator: std.mem.Allocator,
    server_url: []const u8,
    session_key: []const u8,
    device_name: ?[]const u8,
) !Endpoint {
    const uri = try std.Uri.parse(server_url);
    const host_component = uri.host orelse return error.MissingHost;
    const host = host_component.percent_encoded;
    if (host.len == 0) return error.MissingHost;

    const secure = if (std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "wss"))
        true
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "ws"))
        false
    else
        return error.UnsupportedScheme;

    const port: u16 = uri.port orelse if (secure) 443 else 80;
    const owned_host = try allocator.dupe(u8, host);
    errdefer allocator.free(owned_host);

    var object: std.ArrayListUnmanaged(u8) = .empty;
    errdefer object.deinit(allocator);

    const base_path = uri.path.percent_encoded;
    if (base_path.len > 1 and !std.mem.eql(u8, base_path, "/")) {
        try object.appendSlice(allocator, base_path);
        if (object.items[object.items.len - 1] == '/') {
            _ = object.pop();
        }
    }
    try object.appendSlice(allocator, "/ws/phantty?session=");
    try appendQueryEscaped(&object, allocator, session_key);
    if (device_name) |device| {
        if (device.len > 0) {
            try object.appendSlice(allocator, "&device=");
            try appendQueryEscaped(&object, allocator, device);
        }
    }

    return .{
        .secure = secure,
        .host = owned_host,
        .port = port,
        .object_name = try object.toOwnedSlice(allocator),
    };
}

fn appendQueryEscaped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
}

fn buildOutputMessage(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"type\":\"output-bytes\",\"encoding\":\"hex\",\"data\":\"");
    try appendHex(&out, allocator, data);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

fn appendHex(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    const hex = "0123456789abcdef";
    for (data) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

test "buildEndpoint maps relay URL to Phantty websocket route" {
    const allocator = std.testing.allocator;
    const key = "0123456789abcdef0123456789abcdef";

    var endpoint = try buildEndpoint(allocator, "https://remote.example.com", key, "workstation");
    defer endpoint.deinit(allocator);

    try std.testing.expect(endpoint.secure);
    try std.testing.expectEqualStrings("remote.example.com", endpoint.host);
    try std.testing.expectEqual(@as(u16, 443), endpoint.port);
    try std.testing.expectEqualStrings("/ws/phantty?session=0123456789abcdef0123456789abcdef&device=workstation", endpoint.object_name);
}

test "buildOutputMessage preserves PTY bytes as hex" {
    const allocator = std.testing.allocator;
    const message = try buildOutputMessage(allocator, "\x1b[31mhi\r\n");
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "{\"type\":\"output-bytes\",\"encoding\":\"hex\",\"data\":\"1b5b33316d68690d0a\"}",
        message,
    );
}
