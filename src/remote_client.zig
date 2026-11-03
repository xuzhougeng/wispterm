//! Outbound WispTerm Remote relay client shared by one WispTerm instance.
//!
//! One transport on the message hub (`remote_hub.zig`): it ships every hub
//! message to the relay over a WebSocket and feeds relay commands back into
//! the hub. Surfaces never talk to it directly.

const std = @import("std");
const remote_hub = @import("remote_hub.zig");
const remote_transport = @import("platform/remote_transport.zig");
const session_lock = @import("platform/session_lock.zig");

const QUEUE_LIMIT = 512;
const RETRY_DELAY_NS = 2 * std.time.ns_per_s;
const MAX_INCOMING_MESSAGE_BYTES = 1024 * 1024;
const HEARTBEAT_INTERVAL_MS: i64 = 25 * 1000;
const PING_MESSAGE = "{\"type\":\"ping\"}";
const PONG_MESSAGE = "{\"type\":\"pong\"}";
const MAX_FIXED_SESSION_KEY_ATTEMPTS = 256;

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
    session_key: ?[]const u8 = null,
};

pub const AiAgentOpenStatus = remote_hub.AiAgentOpenStatus;
pub const appendJsonString = remote_hub.appendJsonString;
pub const nextSurfaceId = remote_hub.nextSurfaceId;

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

const SessionKeyReservation = struct {
    lock: ?session_lock.Reservation = null,

    fn deinit(self: *SessionKeyReservation) void {
        if (self.lock) |*lock| {
            lock.deinit();
            self.lock = null;
        }
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    hub: *remote_hub.Hub,
    endpoint: Endpoint,
    device_name: ?[]u8,
    session_key: []u8,
    session_key_reservation: SessionKeyReservation = .{},

    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.disconnected),
    thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, hub: *remote_hub.Hub, options: Options) !*Client {
        const client = try allocator.create(Client);
        errdefer allocator.destroy(client);

        var session_key_reservation: SessionKeyReservation = .{};
        errdefer session_key_reservation.deinit();

        const key = try sessionKeyAlloc(allocator, options.session_key, &session_key_reservation);
        errdefer allocator.free(key);

        var endpoint = try buildEndpoint(allocator, options.server_url, key, options.device_name);
        errdefer endpoint.deinit(allocator);

        const device_name = if (options.device_name) |name| try allocator.dupe(u8, name) else null;
        errdefer if (device_name) |name| allocator.free(name);

        client.* = .{
            .allocator = allocator,
            .hub = hub,
            .endpoint = endpoint,
            .device_name = device_name,
            .session_key = key,
            .session_key_reservation = session_key_reservation,
        };

        hub.addTransport(client, transportSend);
        errdefer hub.removeTransport(client);
        client.thread = try std.Thread.spawn(.{}, threadMain, .{client});
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.hub.removeTransport(self);
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
        self.queue.deinit(self.allocator);
        self.mutex.unlock();

        self.endpoint.deinit(self.allocator);
        if (self.device_name) |name| self.allocator.free(name);
        self.session_key_reservation.deinit();
        self.allocator.free(self.session_key);
    }

    pub fn destroy(self: *Client) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn sessionKey(self: *const Client) []const u8 {
        return self.session_key;
    }

    pub fn loadState(self: *const Client) State {
        return self.state.load(.acquire);
    }

    /// Hub transport callback: copy the message onto the send queue.
    fn transportSend(ctx: *anyopaque, message: []const u8) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        if (self.stop_requested.load(.acquire)) return;
        const copy = self.allocator.dupe(u8, message) catch return;
        self.enqueueOwnedMessage(copy);
    }

    fn enqueueOwnedMessage(self: *Client, message: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enqueueOwnedMessageLocked(message);
    }

    fn enqueueOwnedMessageLocked(self: *Client, message: []u8) void {
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

    fn replayLastLayout(self: *Client) void {
        const layout = self.hub.lastLayoutAlloc(self.allocator) orelse return;
        self.enqueueOwnedMessage(layout);
    }

    fn popMessage(self: *Client) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn waitForMessageOrStop(self: *Client, connection_alive: *std.atomic.Value(bool)) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.items.len == 0 and
            !self.stop_requested.load(.acquire) and
            connection_alive.load(.acquire))
        {
            self.condition.timedWait(&self.mutex, std.time.ns_per_s) catch {};
        }
        return !self.stop_requested.load(.acquire) and connection_alive.load(.acquire);
    }
};

fn threadMain(client: *Client) void {
    while (!client.stop_requested.load(.acquire)) {
        client.state.store(.connecting, .release);
        var handles = remote_transport.connect(client.allocator, .{
            .secure = client.endpoint.secure,
            .host = client.endpoint.host,
            .port = client.endpoint.port,
            .object_name = client.endpoint.object_name,
        }) catch |err| {
            client.state.store(.failed, .release);
            std.debug.print("Remote client connect failed: {}\n", .{err});
            sleepUntilRetryOrStop(client);
            continue;
        };
        defer handles.close();

        var connection_alive = std.atomic.Value(bool).init(true);
        const receive_thread = if (handles.websocket) |websocket|
            std.Thread.spawn(.{}, receiveThreadMain, .{ client, websocket, &connection_alive }) catch null
        else
            null;

        client.state.store(.connected, .release);
        std.debug.print("Remote client connected\n", .{});
        client.replayLastLayout();

        var next_heartbeat_ms = std.time.milliTimestamp() + HEARTBEAT_INTERVAL_MS;
        while (!client.stop_requested.load(.acquire) and connection_alive.load(.acquire)) {
            const websocket = handles.websocket orelse break;
            const message = client.popMessage() orelse {
                const now = std.time.milliTimestamp();
                if (now >= next_heartbeat_ms) {
                    if (!remote_transport.sendUtf8(websocket, PING_MESSAGE)) {
                        connection_alive.store(false, .release);
                        client.state.store(.disconnected, .release);
                        break;
                    }
                    next_heartbeat_ms = now + HEARTBEAT_INTERVAL_MS;
                    continue;
                }

                if (!client.waitForMessageOrStop(&connection_alive)) break;
                continue;
            };
            defer client.allocator.free(message);

            if (!remote_transport.sendUtf8(websocket, message)) {
                connection_alive.store(false, .release);
                client.state.store(.disconnected, .release);
                break;
            }
            next_heartbeat_ms = std.time.milliTimestamp() + HEARTBEAT_INTERVAL_MS;
        }

        handles.close();
        if (receive_thread) |thread| {
            thread.join();
        }
        if (!client.stop_requested.load(.acquire)) {
            client.state.store(.disconnected, .release);
            sleepUntilRetryOrStop(client);
        }
    }

    client.state.store(.disabled, .release);
}

fn receiveThreadMain(client: *Client, websocket: remote_transport.WebSocketHandle, connection_alive: *std.atomic.Value(bool)) void {
    var buf: [remote_transport.io_chunk_size]u8 = undefined;
    var incoming: IncomingMessageAssembler = .{};
    defer incoming.deinit(client.allocator);

    while (!client.stop_requested.load(.acquire)) {
        const received = remote_transport.receive(websocket, &buf) catch {
            connection_alive.store(false, .release);
            client.condition.broadcast();
            return;
        };
        if (received.buffer_type == .close) {
            connection_alive.store(false, .release);
            client.condition.broadcast();
            return;
        }
        if (received.bytes_read == 0) continue;

        if (received.buffer_type == .utf8_message or received.buffer_type == .utf8_fragment) {
            const maybe_message = incoming.push(
                client.allocator,
                buf[0..received.bytes_read],
                received.buffer_type,
            ) catch continue;
            const message = maybe_message orelse continue;
            defer client.allocator.free(message);

            if (remote_hub.isJsonMessageType(message, "ping")) {
                _ = remote_transport.sendUtf8(websocket, PONG_MESSAGE);
                continue;
            }
            if (remote_hub.isJsonMessageType(message, "pong")) continue;

            client.hub.handleIncomingMessage(message);
        }
    }
}

fn sleepUntilRetryOrStop(client: *Client) void {
    const step_ns = 100 * std.time.ns_per_ms;
    var elapsed: u64 = 0;
    while (elapsed < RETRY_DELAY_NS and !client.stop_requested.load(.acquire)) : (elapsed += step_ns) {
        std.Thread.sleep(step_ns);
    }
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

fn sessionKeyAlloc(allocator: std.mem.Allocator, configured_key: ?[]const u8, reservation: *SessionKeyReservation) ![]u8 {
    if (configured_key) |raw| {
        const base = std.mem.trim(u8, raw, " \t\r\n");
        if (base.len > 0) {
            return try reserveFixedSessionKey(allocator, base, reservation);
        }
    }

    var generated: [32]u8 = undefined;
    fillSessionKey(&generated);
    return allocator.dupe(u8, generated[0..]);
}

fn reserveFixedSessionKey(allocator: std.mem.Allocator, base: []const u8, reservation: *SessionKeyReservation) ![]u8 {
    for (0..MAX_FIXED_SESSION_KEY_ATTEMPTS) |idx| {
        const candidate = try fixedSessionKeyCandidate(allocator, base, idx);
        errdefer allocator.free(candidate);

        if (try session_lock.reserveSessionKey(allocator, candidate)) |lock| {
            reservation.lock = lock;
            return candidate;
        }

        allocator.free(candidate);
    }

    return error.NoAvailableFixedSessionKey;
}

fn fixedSessionKeyCandidate(allocator: std.mem.Allocator, base: []const u8, index: usize) ![]u8 {
    if (index == 0) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s}_{d}", .{ base, index });
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
    try object.appendSlice(allocator, "/ws/wispterm?session=");
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

const IncomingMessageAssembler = struct {
    pending: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *IncomingMessageAssembler, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
    }

    fn push(
        self: *IncomingMessageAssembler,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        buffer_type: remote_transport.BufferType,
    ) !?[]u8 {
        switch (buffer_type) {
            .utf8_fragment => {
                try self.append(allocator, chunk);
                return null;
            },
            .utf8_message => {
                if (self.pending.items.len == 0) return try allocator.dupe(u8, chunk);
                try self.append(allocator, chunk);
                return try self.pending.toOwnedSlice(allocator);
            },
            else => return null,
        }
    }

    fn append(self: *IncomingMessageAssembler, allocator: std.mem.Allocator, chunk: []const u8) !void {
        if (self.pending.items.len + chunk.len > MAX_INCOMING_MESSAGE_BYTES) {
            self.pending.clearRetainingCapacity();
            return error.MessageTooLarge;
        }
        try self.pending.appendSlice(allocator, chunk);
    }
};

test "buildEndpoint maps relay URL to WispTerm websocket route" {
    const allocator = std.testing.allocator;
    const key = "0123456789abcdef0123456789abcdef";

    var endpoint = try buildEndpoint(allocator, "https://remote.example.com", key, "workstation");
    defer endpoint.deinit(allocator);

    try std.testing.expect(endpoint.secure);
    try std.testing.expectEqualStrings("remote.example.com", endpoint.host);
    try std.testing.expectEqual(@as(u16, 443), endpoint.port);
    try std.testing.expectEqualStrings("/ws/wispterm?session=0123456789abcdef0123456789abcdef&device=workstation", endpoint.object_name);
}

test "fixed session key candidates append numeric suffixes after first instance" {
    const allocator = std.testing.allocator;

    const first = try fixedSessionKeyCandidate(allocator, "fixed-password", 0);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("fixed-password", first);

    const second = try fixedSessionKeyCandidate(allocator, "fixed-password", 1);
    defer allocator.free(second);
    try std.testing.expectEqualStrings("fixed-password_1", second);

    const fourth = try fixedSessionKeyCandidate(allocator, "fixed-password", 3);
    defer allocator.free(fourth);
    try std.testing.expectEqualStrings("fixed-password_3", fourth);
}

test "incoming websocket fragments are reassembled before handling JSON" {
    const allocator = std.testing.allocator;
    var assembler: IncomingMessageAssembler = .{};
    defer assembler.deinit(allocator);

    const prefix = "{\"type\":\"input-bytes\",\"surfaceId\":\"aichat0000000000\",\"encoding\":\"hex\",\"data\":\"";
    const suffix = "68656c6c6f0d\"}";

    const first = try assembler.push(allocator, prefix, .utf8_fragment);
    try std.testing.expect(first == null);

    const second = try assembler.push(allocator, suffix, .utf8_message);
    defer if (second) |message| allocator.free(message);
    try std.testing.expect(second != null);

    const expected = "{\"type\":\"input-bytes\",\"surfaceId\":\"aichat0000000000\",\"encoding\":\"hex\",\"data\":\"68656c6c6f0d\"}";
    try std.testing.expectEqualStrings(expected, second.?);
}
