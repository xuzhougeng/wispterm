//! WispTerm Remote message hub: the single producer of relay-format messages
//! (`layout`, `output-bytes`, `open-ai-agent-result`) and the single consumer
//! of relay-format commands (`input-bytes`, `open-ai-agent`), independent of
//! how the bytes travel.
//!
//! Surfaces register as sinks here and publish PTY output with their stable
//! surface id. Transports (the public relay client in `remote_client.zig`, the
//! LAN message channel in `lan_stream.zig`) attach with `addTransport` and get
//! every outbound message; they hand inbound messages to
//! `handleIncomingMessage`. The hub never blocks on the network: a transport's
//! `send_fn` must only enqueue (or drop) and must not call back into the hub.
//!
//! Message formats match `remote/README.md` "Relay Messages" byte-for-byte.

const std = @import("std");

var next_surface_counter = std.atomic.Value(u64).init(1);

pub const SurfaceWriteFn = *const fn (ctx: *anyopaque, data: []const u8) void;
pub const AiAgentOpenStatus = enum {
    opened,
    no_profile,
    failed,
};
pub const AiAgentOpenFn = *const fn (ctx: *anyopaque, request_id: []const u8) void;
pub const TransportSendFn = *const fn (ctx: *anyopaque, message: []const u8) void;

const SurfaceSink = struct {
    id: [16]u8,
    ctx: *anyopaque,
    write_fn: SurfaceWriteFn,
};

pub const Transport = struct {
    ctx: *anyopaque,
    send_fn: TransportSendFn,
};

pub const Hub = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    surface_sinks: std.ArrayListUnmanaged(SurfaceSink) = .empty,
    transports: std.ArrayListUnmanaged(Transport) = .empty,
    ai_agent_open_ctx: ?*anyopaque = null,
    ai_agent_open_fn: ?AiAgentOpenFn = null,
    last_layout: ?[]u8 = null,

    pub fn create(allocator: std.mem.Allocator) !*Hub {
        const hub = try allocator.create(Hub);
        hub.* = .{ .allocator = allocator };
        return hub;
    }

    pub fn init(allocator: std.mem.Allocator) Hub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Hub) void {
        self.mutex.lock();
        self.surface_sinks.deinit(self.allocator);
        self.transports.deinit(self.allocator);
        if (self.last_layout) |layout| self.allocator.free(layout);
        self.last_layout = null;
        self.mutex.unlock();
    }

    pub fn destroy(self: *Hub) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    // ---- transports -------------------------------------------------------

    pub fn addTransport(self: *Hub, ctx: *anyopaque, send_fn: TransportSendFn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.transports.items) |*t| {
            if (t.ctx == ctx) {
                t.send_fn = send_fn;
                return;
            }
        }
        self.transports.append(self.allocator, .{ .ctx = ctx, .send_fn = send_fn }) catch {};
    }

    /// After this returns the hub never calls `ctx` again, so the transport
    /// may free itself.
    pub fn removeTransport(self: *Hub, ctx: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.transports.items, 0..) |t, i| {
            if (t.ctx == ctx) {
                _ = self.transports.swapRemove(i);
                return;
            }
        }
    }

    pub fn transportCount(self: *Hub) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.transports.items.len;
    }

    /// Copy of the most recent layout, for a transport that just (re)connected.
    pub fn lastLayoutAlloc(self: *Hub, allocator: std.mem.Allocator) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const last = self.last_layout orelse return null;
        return allocator.dupe(u8, last) catch null;
    }

    // ---- outbound ---------------------------------------------------------

    pub fn sendOutput(self: *Hub, surface_id: []const u8, data: []const u8) void {
        if (data.len == 0) return;
        if (!self.hasTransports()) return;
        const message = buildOutputMessage(self.allocator, surface_id, data) catch return;
        defer self.allocator.free(message);
        self.broadcast(message);
    }

    pub fn sendAiAgentOpenResult(self: *Hub, request_id: []const u8, status: AiAgentOpenStatus) void {
        if (request_id.len == 0) return;
        const message = buildAiAgentOpenResultMessage(self.allocator, request_id, status) catch return;
        defer self.allocator.free(message);
        self.broadcast(message);
    }

    /// Remembers the layout for late joiners and broadcasts it when it changed.
    pub fn sendLayout(self: *Hub, layout_json: []const u8) void {
        if (layout_json.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.last_layout) |last| {
            if (std.mem.eql(u8, last, layout_json)) return;
        }
        const next_layout = self.allocator.dupe(u8, layout_json) catch return;
        if (self.last_layout) |last| self.allocator.free(last);
        self.last_layout = next_layout;
        self.broadcastLocked(next_layout);
    }

    fn hasTransports(self: *Hub) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.transports.items.len > 0;
    }

    fn broadcast(self: *Hub, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.broadcastLocked(message);
    }

    fn broadcastLocked(self: *Hub, message: []const u8) void {
        for (self.transports.items) |t| t.send_fn(t.ctx, message);
    }

    // ---- sinks ------------------------------------------------------------

    pub fn registerSurface(self: *Hub, surface_id: [16]u8, ctx: *anyopaque, write_fn: SurfaceWriteFn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.surface_sinks.items) |*sink| {
            if (std.mem.eql(u8, sink.id[0..], surface_id[0..])) {
                sink.ctx = ctx;
                sink.write_fn = write_fn;
                return;
            }
        }
        self.surface_sinks.append(self.allocator, .{ .id = surface_id, .ctx = ctx, .write_fn = write_fn }) catch {};
    }

    pub fn unregisterSurface(self: *Hub, surface_id: [16]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.surface_sinks.items, 0..) |sink, i| {
            if (std.mem.eql(u8, sink.id[0..], surface_id[0..])) {
                _ = self.surface_sinks.swapRemove(i);
                return;
            }
        }
    }

    pub fn registerAiAgentOpener(self: *Hub, ctx: *anyopaque, open_fn: AiAgentOpenFn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ai_agent_open_ctx = ctx;
        self.ai_agent_open_fn = open_fn;
    }

    // ---- inbound ----------------------------------------------------------

    /// One relay-format JSON message from any transport. `ping`/`pong` are the
    /// transport's business and never reach here.
    pub fn handleIncomingMessage(self: *Hub, message: []const u8) void {
        if (isJsonMessageType(message, "input-bytes")) {
            const surface_id = extractJsonString(message, "surfaceId") orelse return;
            const hex_data = extractJsonString(message, "data") orelse return;
            const decoded = decodeHexAlloc(self.allocator, hex_data) catch return;
            defer self.allocator.free(decoded);
            self.dispatchInput(surface_id, decoded);
            return;
        }
        if (isJsonMessageType(message, "open-ai-agent")) {
            const request_id = extractJsonString(message, "requestId") orelse return;
            self.dispatchAiAgentOpen(request_id);
        }
    }

    fn dispatchInput(self: *Hub, surface_id: []const u8, data: []const u8) void {
        if (data.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.surface_sinks.items) |sink| {
            if (std.mem.eql(u8, sink.id[0..], surface_id)) {
                sink.write_fn(sink.ctx, data);
                return;
            }
        }
    }

    fn dispatchAiAgentOpen(self: *Hub, request_id: []const u8) void {
        self.mutex.lock();
        const ctx = self.ai_agent_open_ctx;
        const open_fn = self.ai_agent_open_fn;
        self.mutex.unlock();

        if (ctx == null or open_fn == null) {
            self.sendAiAgentOpenResult(request_id, .failed);
            return;
        }
        open_fn.?(ctx.?, request_id);
    }
};

pub fn nextSurfaceId(out: *[16]u8) void {
    const id = next_surface_counter.fetchAdd(1, .monotonic);
    _ = std.fmt.bufPrint(out, "{x:0>16}", .{id}) catch unreachable;
}

// ---- message builders -----------------------------------------------------

pub fn buildOutputMessage(allocator: std.mem.Allocator, surface_id: []const u8, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"type\":\"output-bytes\",\"surfaceId\":\"");
    try appendJsonString(&out, allocator, surface_id);
    try out.appendSlice(allocator, "\",\"encoding\":\"hex\",\"data\":\"");
    try appendHex(&out, allocator, data);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

pub fn buildAiAgentOpenResultMessage(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    status: AiAgentOpenStatus,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"type\":\"open-ai-agent-result\",\"requestId\":\"");
    try appendJsonString(&out, allocator, request_id);
    try out.appendSlice(allocator, "\",\"status\":\"");
    try out.appendSlice(allocator, aiAgentOpenStatusJson(status));
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

fn aiAgentOpenStatusJson(status: AiAgentOpenStatus) []const u8 {
    return switch (status) {
        .opened => "opened",
        .no_profile => "no-profile",
        .failed => "failed",
    };
}

// ---- JSON helpers ---------------------------------------------------------

pub fn isJsonMessageType(message: []const u8, comptime kind: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"type\":\"" ++ kind ++ "\"") != null;
}

pub fn extractJsonString(message: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (field.len + 4 > needle_buf.len) return null;

    needle_buf[0] = '"';
    @memcpy(needle_buf[1..][0..field.len], field);
    needle_buf[field.len + 1] = '"';
    needle_buf[field.len + 2] = ':';
    needle_buf[field.len + 3] = '"';
    const needle = needle_buf[0 .. field.len + 4];

    const start = std.mem.indexOf(u8, message, needle) orelse return null;
    var i = start + needle.len;
    const value_start = i;
    while (i < message.len) : (i += 1) {
        if (message[i] == '"') return message[value_start..i];
        if (message[i] == '\\') return null;
    }
    return null;
}

pub fn decodeHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);

    for (out, 0..) |*byte, i| {
        const high = try hexValue(hex[i * 2]);
        const low = try hexValue(hex[i * 2 + 1]);
        byte.* = (high << 4) | low;
    }
    return out;
}

fn hexValue(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHex,
    };
}

pub fn appendHex(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    const hex = "0123456789abcdef";
    for (data) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

pub fn appendJsonString(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < data.len) {
        const ch = data[i];
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hex[ch >> 4]);
                    try out.append(allocator, hex[ch & 0x0f]);
                } else if (ch < 0x80) {
                    try out.append(allocator, ch);
                } else {
                    const len = std.unicode.utf8ByteSequenceLength(ch) catch {
                        try out.appendSlice(allocator, "\\ufffd");
                        i += 1;
                        continue;
                    };
                    if (i + len > data.len) {
                        try out.appendSlice(allocator, "\\ufffd");
                        i += 1;
                        continue;
                    }
                    _ = std.unicode.utf8Decode(data[i .. i + len]) catch {
                        try out.appendSlice(allocator, "\\ufffd");
                        i += 1;
                        continue;
                    };
                    try out.appendSlice(allocator, data[i .. i + len]);
                    i += len;
                    continue;
                }
            },
        }
        i += 1;
    }
}

// ---- tests ----------------------------------------------------------------

const TestTransport = struct {
    allocator: std.mem.Allocator,
    received: std.ArrayListUnmanaged([]u8) = .empty,

    fn send(ctx: *anyopaque, message: []const u8) void {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        const copy = self.allocator.dupe(u8, message) catch return;
        self.received.append(self.allocator, copy) catch self.allocator.free(copy);
    }

    fn deinit(self: *TestTransport) void {
        for (self.received.items) |m| self.allocator.free(m);
        self.received.deinit(self.allocator);
    }
};

const TestSink = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn write(ctx: *anyopaque, data: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.len = @min(data.len, self.buf.len);
        @memcpy(self.buf[0..self.len], data[0..self.len]);
    }
};

const TestAiAgentOpenCtx = struct {
    called: bool = false,
    request_id_buf: [128]u8 = undefined,
    request_id_len: usize = 0,

    fn onOpen(ctx: *anyopaque, request_id: []const u8) void {
        const self: *TestAiAgentOpenCtx = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.request_id_len = @min(request_id.len, self.request_id_buf.len);
        @memcpy(self.request_id_buf[0..self.request_id_len], request_id[0..self.request_id_len]);
    }
};

test "hub fans output out to every transport and dedupes layouts" {
    const allocator = std.testing.allocator;
    var hub = Hub.init(allocator);
    defer hub.deinit();
    var a = TestTransport{ .allocator = allocator };
    defer a.deinit();
    var b = TestTransport{ .allocator = allocator };
    defer b.deinit();
    hub.addTransport(&a, TestTransport.send);
    hub.addTransport(&b, TestTransport.send);

    hub.sendOutput("0000000000000001", "hi");
    hub.sendLayout("{\"type\":\"layout\",\"activeTab\":0,\"tabs\":[]}");
    hub.sendLayout("{\"type\":\"layout\",\"activeTab\":0,\"tabs\":[]}");

    try std.testing.expectEqual(@as(usize, 2), a.received.items.len);
    try std.testing.expectEqual(@as(usize, 2), b.received.items.len);
    try std.testing.expectEqualStrings(
        "{\"type\":\"output-bytes\",\"surfaceId\":\"0000000000000001\",\"encoding\":\"hex\",\"data\":\"6869\"}",
        a.received.items[0],
    );

    const last = hub.lastLayoutAlloc(allocator).?;
    defer allocator.free(last);
    try std.testing.expectEqualStrings("{\"type\":\"layout\",\"activeTab\":0,\"tabs\":[]}", last);

    hub.removeTransport(&a);
    hub.sendOutput("0000000000000001", "x");
    try std.testing.expectEqual(@as(usize, 2), a.received.items.len);
    try std.testing.expectEqual(@as(usize, 3), b.received.items.len);
}

test "hub routes input-bytes to the registered surface sink" {
    const allocator = std.testing.allocator;
    var hub = Hub.init(allocator);
    defer hub.deinit();
    var sink = TestSink{};
    hub.registerSurface("0000000000000001".*, &sink, TestSink.write);

    hub.handleIncomingMessage("{\"type\":\"input-bytes\",\"surfaceId\":\"0000000000000001\",\"encoding\":\"hex\",\"data\":\"0d1b5b41\"}");
    try std.testing.expectEqualSlices(u8, "\r\x1b[A", sink.buf[0..sink.len]);

    hub.unregisterSurface("0000000000000001".*);
    sink.len = 0;
    hub.handleIncomingMessage("{\"type\":\"input-bytes\",\"surfaceId\":\"0000000000000001\",\"encoding\":\"hex\",\"data\":\"41\"}");
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "open ai agent message dispatches request id" {
    const allocator = std.testing.allocator;
    var hub = Hub.init(allocator);
    defer hub.deinit();

    var ctx = TestAiAgentOpenCtx{};
    hub.registerAiAgentOpener(&ctx, TestAiAgentOpenCtx.onOpen);
    hub.handleIncomingMessage("{\"type\":\"open-ai-agent\",\"requestId\":\"remote-ai-1\"}");

    try std.testing.expect(ctx.called);
    try std.testing.expectEqualStrings("remote-ai-1", ctx.request_id_buf[0..ctx.request_id_len]);
}

test "open ai agent without registered opener broadcasts failed result" {
    const allocator = std.testing.allocator;
    var hub = Hub.init(allocator);
    defer hub.deinit();
    var t = TestTransport{ .allocator = allocator };
    defer t.deinit();
    hub.addTransport(&t, TestTransport.send);

    hub.handleIncomingMessage("{\"type\":\"open-ai-agent\",\"requestId\":\"remote-ai-1\"}");

    try std.testing.expectEqual(@as(usize, 1), t.received.items.len);
    try std.testing.expectEqualStrings(
        "{\"type\":\"open-ai-agent-result\",\"requestId\":\"remote-ai-1\",\"status\":\"failed\"}",
        t.received.items[0],
    );
}

test "open ai agent result message escapes request id" {
    const allocator = std.testing.allocator;
    const message = try buildAiAgentOpenResultMessage(allocator, "remote-\"one", .no_profile);
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "{\"type\":\"open-ai-agent-result\",\"requestId\":\"remote-\\\"one\",\"status\":\"no-profile\"}",
        message,
    );
}

test "buildOutputMessage preserves PTY bytes as hex" {
    const allocator = std.testing.allocator;
    const message = try buildOutputMessage(allocator, "0000000000000001", "\x1b[31mhi\r\n");
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "{\"type\":\"output-bytes\",\"surfaceId\":\"0000000000000001\",\"encoding\":\"hex\",\"data\":\"1b5b33316d68690d0a\"}",
        message,
    );
}

test "remote json string replaces invalid utf8 bytes" {
    const allocator = std.testing.allocator;
    const bad = [_]u8{ 'o', 'k', ' ', 0xff, ' ', 0xc3 };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try appendJsonString(&out, allocator, bad[0..]);
    try std.testing.expectEqualStrings("ok \\ufffd \\ufffd", out.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.items));
}

test "remote json string preserves valid multibyte utf8" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try appendJsonString(&out, allocator, "标题 🚀");
    try std.testing.expectEqualStrings("标题 🚀", out.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.items));
}

test "decode input message bytes" {
    const allocator = std.testing.allocator;
    const bytes = try decodeHexAlloc(allocator, "0d1b5b41");
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, "\r\x1b[A", bytes);
}
