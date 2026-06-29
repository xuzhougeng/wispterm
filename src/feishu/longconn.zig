//! Feishu long-connection client (M2.7).
//!
//! Orchestrates: discover endpoint → TLS connect → WS handshake → recv loop
//! (Data → immediate ACK → on_event; Control → log) → periodic ping → reconnect/backoff.
//!
//! Thread design:
//!   main thread: start()/stop() only.
//!   conn thread: discover → connect → handshake → recv loop.
//!   ping thread: spawned per connection; sends buildPing every ping_interval_s.
//!
//! Ping approach: a SEPARATE ping thread sleeps ping_interval_s, then calls
//! conn.writeBinary. All sends (ACK, ping, auto-pong) are serialized inside
//! ws.Conn.send_mu, so the recv thread and ping thread never interleave frames.
//! readBinary stays a simple blocking call; the ping thread only writes.
//!
//! stop() unblocks the blocking read: it shuts down the socket (via the fd held
//! under conn_mu), which makes readBinary return an error → the recv loop exits
//! → connectLoop's defer destroys the connection (sole owner). conn_mu serializes
//! the stop-side shutdown against the defer's null+destroy, so no UAF/double-free.
//!
//! Security: wss URL query / token / app_secret are NEVER logged.
//! on_event is called on the conn thread — caller must not block it long.

const std = @import("std");
const rest = @import("rest.zig");
const ws = @import("ws.zig");
const pbbp2 = @import("pbbp2.zig");
const types = @import("types.zig");

const log = std.log.scoped(.feishu_longconn);

// Reconnect backoff: initial 1s, cap 30s, no jitter (simple, stable).
// ponytail: fixed backoff, upgrade to jittered exp if connection storms matter.
const RECONNECT_INITIAL_MS: u64 = 1_000;
const RECONNECT_MAX_MS: u64 = 30_000;

// ===================== Public API =====================

pub const Client = struct {
    allocator: std.mem.Allocator,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    // Live connection, published by connectLoop under conn_mu so stop() can
    // shutdown() the socket to unblock a blocking readBinary. ONLY connectLoop's
    // defer ever destroy()s it — stop() only shuts it down. conn_mu serializes
    // stop's shutdown against the defer's null+destroy.
    conn_mu: std.Thread.Mutex = .{},
    conn: ?*std.http.Client.Connection = null,

    // Thread context is passed by pointer into threadMain; both start() and
    // stop() touch these fields only before/after the thread is live, so no
    // extra mutex is needed beyond the atomic stop flag.
    on_event: *const fn (ctx: *anyopaque, payload: []const u8) void = undefined,
    on_event_ctx: *anyopaque = undefined,
    creds: types.Credentials = undefined,

    /// Spawn the background connection thread. `on_event` is called on that
    /// thread with the raw event JSON payload — no framing, no ACK ordering.
    pub fn start(
        self: *Client,
        creds: types.Credentials,
        on_event: *const fn (ctx: *anyopaque, payload: []const u8) void,
        ctx: *anyopaque,
    ) !void {
        self.creds = creds;
        self.on_event = on_event;
        self.on_event_ctx = ctx;
        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        log.info("longconn started", .{});
    }

    /// Signal stop and join. Blocks until the thread exits.
    /// Shuts down the live socket (if any) so a blocking readBinary returns
    /// promptly instead of hanging the join on an idle connection.
    pub fn stop(self: *Client) void {
        self.stop_requested.store(true, .release);
        {
            self.conn_mu.lock();
            defer self.conn_mu.unlock();
            if (self.conn) |c| {
                // shutdown only — destroy stays with connectLoop's defer (sole owner).
                const fd = c.stream_reader.getStream().handle;
                std.posix.shutdown(fd, .both) catch |err| {
                    log.debug("longconn: shutdown failed: {s}", .{@errorName(err)});
                };
            }
        }
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
        log.info("longconn stopped", .{});
    }
};

// ===================== Thread main =====================

fn threadMain(self: *Client) void {
    var backoff_ms: u64 = RECONNECT_INITIAL_MS;
    while (!self.stop_requested.load(.acquire)) {
        connectLoop(self) catch |err| {
            if (self.stop_requested.load(.acquire)) return;
            log.warn("longconn lost ({s}); reconnect in {d}ms", .{ @errorName(err), backoff_ms });
            // Sleep in small steps so stop() is noticed quickly.
            const steps = @divTrunc(backoff_ms, 100);
            var i: u64 = 0;
            while (i < steps and !self.stop_requested.load(.acquire)) : (i += 1) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
            // Exponential backoff capped at RECONNECT_MAX_MS.
            backoff_ms = @min(backoff_ms * 2, RECONNECT_MAX_MS);
        };
        if (!self.stop_requested.load(.acquire)) {
            // Clean exit from connectLoop (unusual); reset backoff.
            backoff_ms = RECONNECT_INITIAL_MS;
        }
    }
}

// ===================== Single connection attempt =====================

const PingCtx = struct {
    conn: *ws.Conn,
    stop: *const std.atomic.Value(bool),
    interval_s: i64,
    service_id_buf: [32]u8,
    service_id_len: usize,

    fn serviceId(self: *const PingCtx) []const u8 {
        return self.service_id_buf[0..self.service_id_len];
    }
};

fn pingThread(ctx: *PingCtx) void {
    const interval_ns: u64 = @intCast(@max(ctx.interval_s, 1) * std.time.ns_per_s);
    // Sleep in small steps so we notice stop quickly.
    const step_ns: u64 = 500 * std.time.ns_per_ms;
    var elapsed_ns: u64 = 0;
    while (!ctx.stop.load(.acquire)) {
        std.Thread.sleep(step_ns);
        elapsed_ns += step_ns;
        if (elapsed_ns < interval_ns) continue;
        elapsed_ns = 0;

        // Build ping with an arena; small so stack-arena-sized.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const ping = pbbp2.buildPing(arena.allocator(), ctx.serviceId()) catch |err| {
            log.warn("ping: buildPing failed: {s}", .{@errorName(err)});
            continue;
        };
        // writeBinary serializes internally (ws.Conn.send_mu).
        ctx.conn.writeBinary(ping) catch |err| {
            // Connection is broken; recv thread will see it too and exit.
            log.warn("ping: send failed: {s}", .{@errorName(err)});
            return;
        };
        log.debug("ping: sent", .{});
    }
}

fn connectLoop(self: *Client) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Discover endpoint (may do a REST call with TLS).
    log.info("longconn: discovering ws endpoint", .{});
    const ep = try rest.discoverWsEndpoint(self.allocator, self.creds);
    defer self.allocator.free(ep.url);

    if (self.stop_requested.load(.acquire)) return;

    const u = try ws.parseWss(ep.url);
    // Log only host+path, never the query.
    log.info("longconn: connecting to {s}:{d}{s}", .{
        u.host, u.port, ws.stripQuery(u.path_query),
    });

    // service_id is a small int, not a secret; used for ping.
    const service_id_raw = ws.queryParam(ep.url, "service_id") orelse "";

    // 2. TLS connect (spike-proven: rescan BEFORE connect).
    var client: std.http.Client = .{ .allocator = self.allocator };
    defer client.deinit();
    try client.ca_bundle.rescan(self.allocator);

    const conn_ptr = try client.connect(u.host, u.port, .tls);
    // Sole owner: destroy here on every exit. Before destroying, clear the
    // published pointer under conn_mu so a concurrent stop() can't shutdown a
    // freed socket.
    defer {
        self.conn_mu.lock();
        self.conn = null;
        self.conn_mu.unlock();
        conn_ptr.destroy();
    }

    // 3. WS handshake (auth is in URL query, no extra headers needed).
    try ws.handshake(conn_ptr, u.host, u.path_query);
    log.info("longconn: handshake OK", .{});

    // Publish the live connection so stop() can unblock readBinary by
    // shutting down its socket. Do this AFTER handshake (handshake itself is a
    // short blocking exchange; if stop races in before this, the next
    // stop_requested check below catches it).
    {
        self.conn_mu.lock();
        self.conn = conn_ptr;
        self.conn_mu.unlock();
    }

    if (self.stop_requested.load(.acquire)) return;

    var conn = ws.Conn{
        .conn = conn_ptr,
        .rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
    };

    // 4. Spawn ping thread.
    var ping_ctx = PingCtx{
        .conn = &conn,
        .stop = &self.stop_requested,
        .interval_s = ep.ping_interval_s,
        .service_id_buf = undefined,
        .service_id_len = 0,
    };
    const copy_len = @min(service_id_raw.len, ping_ctx.service_id_buf.len);
    @memcpy(ping_ctx.service_id_buf[0..copy_len], service_id_raw[0..copy_len]);
    ping_ctx.service_id_len = copy_len;

    const ping_th = try std.Thread.spawn(.{}, pingThread, .{&ping_ctx});
    defer ping_th.join();

    // 5. Recv loop.
    while (!self.stop_requested.load(.acquire)) {
        const raw = conn.readBinary(a) catch |err| switch (err) {
            error.WsClosed => {
                log.info("longconn: server closed connection", .{});
                return error.WsClosed;
            },
            else => return err,
        };
        // raw is arena-owned; freed by the per-frame reset below.

        const frame = pbbp2.decode(a, raw) catch |err| {
            log.warn("longconn: frame decode error: {s} ({d} bytes)", .{ @errorName(err), raw.len });
            _ = arena.reset(.retain_capacity);
            continue;
        };

        connWriteAck(&conn, frame, self.on_event, self.on_event_ctx) catch |err| {
            log.warn("longconn: handleFrame error: {s}", .{@errorName(err)});
        };

        // Bound memory to a single frame: on_event is synchronous and has
        // returned, the ACK is already on the wire, so nothing references the
        // arena anymore. Without this a healthy (never-reconnecting) connection
        // grows the arena unboundedly.
        _ = arena.reset(.retain_capacity);
    }
}

/// Production ACK sink: write the ACK bytes through the real ws.Conn (sends are
/// serialized inside Conn.send_mu).
fn connWriteAck(
    conn: *ws.Conn,
    frame: pbbp2.Frame,
    on_event: *const fn (ctx: *anyopaque, payload: []const u8) void,
    ctx: *anyopaque,
) !void {
    const sink = AckSink{ .ctx = conn, .write = connSinkWrite };
    return handleFrame(frame, sink, on_event, ctx);
}

fn connSinkWrite(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const conn: *ws.Conn = @ptrCast(@alignCast(ctx));
    return conn.writeBinary(bytes);
}

// ===================== Testable frame dispatcher =====================

/// Abstracts "send the ACK bytes" so handleFrame is unit-testable without a
/// real TLS connection: production passes a ws.Conn-backed sink, tests pass a
/// recorder. `null` skips the ACK write entirely.
pub const AckSink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

/// Dispatch one decoded pbbp2 Frame.
/// Data frames (method==1): send ACK immediately (BEFORE on_event, to meet
/// Feishu's 3-second deadline regardless of on_event cost), then call on_event.
/// Control frames (method==0): log only; on_event is NOT called.
pub fn handleFrame(
    frame: pbbp2.Frame,
    ack_sink: ?AckSink,
    on_event: *const fn (ctx: *anyopaque, payload: []const u8) void,
    ctx: *anyopaque,
) !void {
    if (frame.method == 1) {
        // Data frame: ACK first, then hand payload to caller.
        if (ack_sink) |sink| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const ack = try pbbp2.buildAck(arena.allocator(), frame);
            try sink.write(sink.ctx, ack);
        }
        on_event(ctx, frame.payload);
    } else {
        // Control frame (method==0): ping/pong/etc. Log and skip.
        const htype = frame.header("type") orelse "";
        log.debug("longconn: control frame type={s}", .{htype});
        // on_event is NOT called.
    }
}

// ===================== Tests =====================

const t = std.testing;

// Records on_event calls.
const EventCapture = struct {
    called: bool = false,
    payload: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *EventCapture) void {
        self.payload.deinit(t.allocator);
    }

    fn onEvent(ctx: *anyopaque, payload: []const u8) void {
        const self: *EventCapture = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.payload.appendSlice(t.allocator, payload) catch {};
    }
};

// Records ACK bytes + ordering relative to on_event. Both the sink write and
// onEvent append a tag to `order`, so the test can assert "ack" precedes "event".
const OrderRecorder = struct {
    order: std.ArrayListUnmanaged([]const u8) = .empty,
    ack_bytes: std.ArrayListUnmanaged(u8) = .empty,
    payload: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *OrderRecorder) void {
        self.order.deinit(t.allocator);
        self.ack_bytes.deinit(t.allocator);
        self.payload.deinit(t.allocator);
    }

    fn sinkWrite(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *OrderRecorder = @ptrCast(@alignCast(ctx));
        try self.order.append(t.allocator, "ack");
        try self.ack_bytes.appendSlice(t.allocator, bytes);
    }

    fn onEvent(ctx: *anyopaque, payload: []const u8) void {
        const self: *OrderRecorder = @ptrCast(@alignCast(ctx));
        self.order.append(t.allocator, "event") catch {};
        self.payload.appendSlice(t.allocator, payload) catch {};
    }
};

test "handleFrame Data: on_event called with payload (no ack sink)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const hdrs = try a.alloc(pbbp2.Header, 1);
    hdrs[0] = .{ .key = "type", .value = "event" };
    const frame = pbbp2.Frame{
        .seqid = 7,
        .logid = 99,
        .service = 1,
        .method = 1, // Data
        .headers = hdrs,
        .payload = "{\"event\":\"im.message.receive_v1\"}",
    };

    var cap = EventCapture{};
    defer cap.deinit();

    try handleFrame(frame, null, EventCapture.onEvent, &cap);

    try t.expect(cap.called);
    try t.expectEqualStrings("{\"event\":\"im.message.receive_v1\"}", cap.payload.items);
}

test "handleFrame Control: on_event NOT called" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const hdrs = try a.alloc(pbbp2.Header, 1);
    hdrs[0] = .{ .key = "type", .value = "ping" };
    const frame = pbbp2.Frame{
        .seqid = 1,
        .service = 2,
        .method = 0, // Control
        .headers = hdrs,
        .payload = "",
    };

    var cap = EventCapture{};
    defer cap.deinit();

    try handleFrame(frame, null, EventCapture.onEvent, &cap);

    try t.expect(!cap.called);
}

test "handleFrame Data: ACK is sent BEFORE on_event, reuses ids, payload={\"code\":200}" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const hdrs = try a.alloc(pbbp2.Header, 1);
    hdrs[0] = .{ .key = "type", .value = "event" };
    const frame = pbbp2.Frame{
        .seqid = 5,
        .logid = 6,
        .service = 3,
        .method = 1,
        .headers = hdrs,
        .payload = "{\"e\":1}",
    };

    var rec = OrderRecorder{};
    defer rec.deinit();
    const sink = AckSink{ .ctx = &rec, .write = OrderRecorder.sinkWrite };

    try handleFrame(frame, sink, OrderRecorder.onEvent, &rec);

    // Ordering: ack first, event second.
    try t.expectEqual(@as(usize, 2), rec.order.items.len);
    try t.expectEqualStrings("ack", rec.order.items[0]);
    try t.expectEqualStrings("event", rec.order.items[1]);

    // Payload passed through to on_event.
    try t.expectEqualStrings("{\"e\":1}", rec.payload.items);

    // ACK bytes are a valid ACK reusing ids with code 200 + biz_rt.
    const ack = try pbbp2.decode(a, rec.ack_bytes.items);
    try t.expectEqual(@as(u64, 5), ack.seqid);
    try t.expectEqual(@as(u64, 6), ack.logid);
    try t.expectEqual(@as(i64, 3), ack.service);
    try t.expectEqual(@as(i64, 1), ack.method);
    try t.expectEqualStrings("{\"code\":200}", ack.payload);
    try t.expect(ack.header("biz_rt") != null);
}
