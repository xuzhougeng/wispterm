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
//! Ping approach: a SEPARATE ping thread sleeps ping_interval_s, then acquires
//! send_mu and calls writeBinary. The recv thread also holds send_mu for ACKs.
//! This avoids needing a read timeout or polling — readBinary stays a simple
//! blocking call; the ping thread never touches the reader, only the writer.
//! send_mu is per-connection-session, allocated on the stack of connectLoop and
//! passed by pointer to the ping thread via PingCtx.
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
    pub fn stop(self: *Client) void {
        self.stop_requested.store(true, .release);
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
    send_mu: *std.Thread.Mutex,
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
        ctx.send_mu.lock();
        const send_err = ctx.conn.writeBinary(ping);
        ctx.send_mu.unlock();
        if (send_err) |_| {
            log.debug("ping: sent", .{});
        } else |err| {
            // Connection is broken; recv thread will see it too and exit.
            log.warn("ping: send failed: {s}", .{@errorName(err)});
            return;
        }
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
    defer conn_ptr.destroy();

    // 3. WS handshake (auth is in URL query, no extra headers needed).
    try ws.handshake(conn_ptr, u.host, u.path_query);
    log.info("longconn: handshake OK", .{});

    if (self.stop_requested.load(.acquire)) return;

    // Per-connection send mutex (shared between recv loop and ping thread).
    var send_mu: std.Thread.Mutex = .{};
    var conn = ws.Conn{
        .conn = conn_ptr,
        .rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
    };

    // 4. Spawn ping thread.
    var ping_ctx = PingCtx{
        .conn = &conn,
        .send_mu = &send_mu,
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
        // raw is arena-owned; no free needed.

        const frame = pbbp2.decode(a, raw) catch |err| {
            log.warn("longconn: frame decode error: {s} ({d} bytes)", .{ @errorName(err), raw.len });
            continue;
        };

        handleFrame(frame, &conn, &send_mu, self.on_event, self.on_event_ctx) catch |err| {
            log.warn("longconn: handleFrame error: {s}", .{@errorName(err)});
        };
    }
}

// ===================== Testable frame dispatcher =====================

/// Dispatch one decoded pbbp2 Frame.
/// Data frames (method==1): send ACK immediately (before on_event), then call on_event.
/// Control frames (method==0): log only; on_event is NOT called.
///
/// `conn` and `send_mu` are nil-able: if null, ACK write is skipped (for unit tests).
pub fn handleFrame(
    frame: pbbp2.Frame,
    conn: ?*ws.Conn,
    send_mu: ?*std.Thread.Mutex,
    on_event: *const fn (ctx: *anyopaque, payload: []const u8) void,
    ctx: *anyopaque,
) !void {
    if (frame.method == 1) {
        // Data frame: ACK first (3-second deadline), then hand payload to caller.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const ack = try pbbp2.buildAck(arena.allocator(), frame);
        if (conn) |c| {
            if (send_mu) |mu| {
                mu.lock();
                const err = c.writeBinary(ack);
                mu.unlock();
                try err; // propagate write errors
            } else {
                try c.writeBinary(ack);
            }
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

// Capture helper for tests.
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

// Fake Conn writer: captures bytes written via writeBinary.
// We bypass ws.Conn (which wraps std.http.Client.Connection) by using
// handleFrame with conn=null for ACK capture tests and separately testing
// buildAck independently.  For the "ACK bytes are correct" assertion we
// decode the ACK from pbbp2.buildAck directly (already tested in pbbp2.zig).
// Here we verify: (a) on_event called with correct payload, (b) on_event NOT
// called for Control frames.

test "handleFrame Data: on_event called with payload, ACK not required for unit (conn=null)" {
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

    try handleFrame(frame, null, null, EventCapture.onEvent, &cap);

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

    try handleFrame(frame, null, null, EventCapture.onEvent, &cap);

    try t.expect(!cap.called);
}

test "handleFrame Data: ACK bytes reuse seqid/logid/service/method, payload={\"code\":200}" {
    // Verify ACK correctness by building it directly (mirrors the handleFrame
    // path for conn=null) and decoding it.
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
        .payload = "{}",
    };

    const ack_bytes = try pbbp2.buildAck(a, frame);
    const ack = try pbbp2.decode(a, ack_bytes);

    try t.expectEqual(@as(u64, 5), ack.seqid);
    try t.expectEqual(@as(u64, 6), ack.logid);
    try t.expectEqual(@as(i64, 3), ack.service);
    try t.expectEqual(@as(i64, 1), ack.method);
    try t.expectEqualStrings("{\"code\":200}", ack.payload);
    try t.expect(ack.header("biz_rt") != null);
}
