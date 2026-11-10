//! LAN channel for the phone app: advertises `_wispterm._tcp` over Bonjour
//! and serves two things on one raw TCP port, picked by the first line the
//! client sends (`docs/configuration.md` "LAN direct protocol" is the spec):
//!
//! * `WISP1 <remote-session-key>\n` — screen stream. The server pushes the
//!   rendered window as `[u32 big-endian len][jpeg bytes]` frames until either
//!   side closes.
//! * `WISP2 <remote-session-key>\n` — message channel. The server first sends
//!   the current `layout`, then both sides exchange newline-delimited JSON
//!   messages identical to the public relay ("Relay Messages" in
//!   `remote/README.md`): `output-bytes`, `layout`, `input-bytes`,
//!   `open-ai-agent`, `ping`/`pong`, …
//!
//! A wrong key, an unknown greeting, or no greeting within a few seconds just
//! closes the socket. Every accepted connection gets its own thread, so phones
//! never wait on each other.
//!
//! Frames come from the render thread (AppWindow calls `wantsFrame` /
//! `publishRgba` around its ui_screenshot readback) in `window` mode, or from
//! ScreenCaptureKit on its own queue in `display` mode (`Options.source`);
//! either way a viewer thread only ships the latest one, so a slow phone drops
//! frames instead of stalling rendering. Display capture runs only while a
//! stream viewer is connected and falls back to the window when the Screen
//! Recording permission is missing.
//! Messages come from the hub (`remote_hub.zig`) on PTY/UI threads; each
//! connection buffers them in a bounded queue and is dropped when it falls
//! too far behind, so a slow phone never blocks the PTY either.
//!
//! ponytail: macOS only (ImageIO JPEG + dns_sd). Windows/Linux need a JPEG
//! encoder and an mDNS responder before `supported` can flip on there.
const std = @import("std");
const builtin = @import("builtin");
const transport = @import("ctl/transport.zig");
const remote_hub = @import("remote_hub.zig");

pub const supported = builtin.os.tag == .macos;
pub const service_type = "_wispterm._tcp";

const DEFAULT_FPS: u32 = 4;
const JPEG_QUALITY: f32 = 0.6;
/// Display capture is scaled so its width lands in this range (never Retina-native).
const DISPLAY_MIN_WIDTH: u32 = 1280;
const DISPLAY_MAX_WIDTH: u32 = 1920;
const HELLO_TIMEOUT_MS: u32 = 3000;
const SEND_TIMEOUT_MS: u32 = 5000;
/// Reader wake-up interval; bounds how long a dying connection lingers.
const RECV_POLL_MS: u32 = 1000;
const MAX_HELLO_BYTES = 512;
/// One JSON line from the phone may not exceed this (relay uses the same cap).
const MAX_INCOMING_LINE_BYTES = 1024 * 1024;
/// Per-connection outbound queue; past this the phone is too slow and is dropped.
const MSG_QUEUE_LIMIT = 1024;
const MSG_QUEUE_BYTES_LIMIT = 8 * 1024 * 1024;
/// Server pings after this much outbound silence (same cadence as the relay client).
const HEARTBEAT_INTERVAL_MS: i64 = 25 * 1000;
/// A phone that sent nothing at all (not even `pong`) for this long is gone.
const PEER_TIMEOUT_MS: i64 = 90 * 1000;
const PING_LINE = "{\"type\":\"ping\"}\n";
const PONG_MESSAGE = "{\"type\":\"pong\"}";

extern fn wispterm_lan_jpeg_encode(rgba: [*]const u8, width: u32, height: u32, quality: f32, out_len: *usize) ?[*]u8;
extern fn wispterm_lan_jpeg_free(ptr: ?*anyopaque) void;
extern fn wispterm_lan_mdns_register(name: [*:0]const u8, port: u16, txt: [*]const u8, txt_len: u16) ?*anyopaque;
extern fn wispterm_lan_mdns_unregister(ref: ?*anyopaque) void;
extern fn wispterm_lan_display_access(request: bool) bool;
extern fn wispterm_lan_display_start(
    display_index: u32,
    fps: u32,
    min_width: u32,
    max_width: u32,
    quality: f32,
    ctx: *anyopaque,
    frame_fn: *const fn (ctx: *anyopaque, jpeg: [*]const u8, len: usize) callconv(.c) void,
    error_fn: *const fn (ctx: *anyopaque, message: [*:0]const u8) callconv(.c) void,
) ?*anyopaque;
extern fn wispterm_lan_display_stop(handle: ?*anyopaque) void;

var g_server: ?*Server = null;

pub const Source = enum { window, display };

pub const Options = struct {
    /// Advertised Bonjour instance name.
    name: []const u8,
    /// `remote-session-key` (or the relay client's effective key).
    key: []const u8,
    /// Message producer for WISP2; null advertises `caps=stream` only.
    hub: ?*remote_hub.Hub = null,
    /// What WISP1 shows (`lan-stream-source`).
    source: Source = .window,
    /// Display index for `.display` (`lan-stream-display`).
    display_index: u32 = 0,
    /// Frame-rate cap (`lan-stream-fps`), clamped to 1-30.
    fps: u32 = DEFAULT_FPS,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    key_hash: [32]u8,
    listener: std.net.Server,
    port: u16,
    hub: ?*remote_hub.Hub,
    source: Source,
    display_index: u32,
    frame_interval_ms: i64,
    mdns: ?*anyopaque = null,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Number of authenticated stream viewers; the render thread captures only when > 0.
    viewers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_capture_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    frame: ?[]u8 = null,
    seq: u64 = 0,

    conns_mutex: std.Thread.Mutex = .{},
    conns: std.ArrayListUnmanaged(*Conn) = .empty,

    /// ScreenCaptureKit session (`.display` only); exists while viewers > 0.
    display_mutex: std.Thread.Mutex = .{},
    display_handle: ?*anyopaque = null,
    /// Set once display capture failed (permission, API error): the stream
    /// then serves the window instead until restart.
    display_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Binds 0.0.0.0 on an OS-assigned port and advertises it as `options.name`.
    pub fn create(allocator: std.mem.Allocator, options: Options) !*Server {
        if (comptime !supported) return error.LanStreamUnsupported;
        if (options.key.len == 0) return error.LanStreamMissingKey;
        const address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var listener = try address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .key_hash = hashKey(options.key),
            .listener = listener,
            .port = listener.listen_address.getPort(),
            .hub = options.hub,
            .source = options.source,
            .display_index = options.display_index,
            .frame_interval_ms = frameIntervalMs(options.fps),
        };
        const name_z = try allocator.dupeZ(u8, options.name);
        defer allocator.free(name_z);
        const txt = txtRecord(options.hub != null);
        self.mdns = wispterm_lan_mdns_register(name_z.ptr, self.port, txt.ptr, @intCast(txt.len));
        if (self.mdns == null) std.debug.print("lan-stream: Bonjour registration failed\n", .{});
        return self;
    }

    pub fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        g_server = self;
    }

    /// Stops + joins the accept thread and every connection, unregisters
    /// Bonjour, frees everything.
    pub fn destroy(self: *Server) void {
        g_server = null;
        self.stop_flag.store(true, .release);
        if (self.thread) |thread| {
            // Unblock accept() with a throwaway self-connection, and any viewer
            // loop waiting for a frame.
            if (std.net.Address.parseIp4("127.0.0.1", self.port)) |addr| {
                if (std.net.tcpConnectToAddress(addr)) |s| s.close() else |_| {}
            } else |_| {}
            self.cond.broadcast();
            thread.join();
        }
        self.reapConns(true);
        self.stopDisplayCapture();
        if (comptime supported) wispterm_lan_mdns_unregister(self.mdns);
        self.listener.deinit();
        if (self.frame) |f| self.allocator.free(f);
        self.conns.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn capabilities(self: *const Server) []const u8 {
        return if (self.hub != null) "stream,msg" else "stream";
    }

    /// True while frames should come from the window readback: `.window`
    /// mode, or `.display` mode after capture failed.
    fn usesWindowFrames(self: *const Server) bool {
        return self.source == .window or self.display_failed.load(.acquire);
    }

    /// Viewer threads: start ScreenCaptureKit when the first stream viewer
    /// arrives, stop it when the last one leaves, tear it down after failure.
    fn syncDisplayCapture(self: *Server) void {
        if (comptime !supported) return;
        if (self.source != .display) return;
        self.display_mutex.lock();
        defer self.display_mutex.unlock();
        const want = self.viewers.load(.acquire) > 0 and !self.display_failed.load(.acquire);
        if (want and self.display_handle == null) {
            self.display_handle = wispterm_lan_display_start(
                self.display_index,
                @intCast(@divTrunc(1000, self.frame_interval_ms)),
                DISPLAY_MIN_WIDTH,
                DISPLAY_MAX_WIDTH,
                JPEG_QUALITY,
                self,
                displayFrame,
                displayError,
            );
            if (self.display_handle == null) {
                self.display_failed.store(true, .release);
                if (!wispterm_lan_display_access(false)) {
                    std.debug.print(
                        "lan-stream: display capture needs the Screen Recording permission " ++
                            "(System Settings > Privacy & Security > Screen & System Audio Recording > WispTerm); " ++
                            "streaming the window instead until WispTerm restarts\n",
                        .{},
                    );
                } else {
                    std.debug.print("lan-stream: display capture unavailable (needs macOS 12.3+); streaming the window instead\n", .{});
                }
            } else {
                std.debug.print("lan-stream: capturing display {d}\n", .{self.display_index});
            }
        } else if (!want and self.display_handle != null) {
            wispterm_lan_display_stop(self.display_handle);
            self.display_handle = null;
            std.debug.print("lan-stream: display capture stopped\n", .{});
        }
    }

    fn stopDisplayCapture(self: *Server) void {
        if (comptime !supported) return;
        self.display_mutex.lock();
        defer self.display_mutex.unlock();
        if (self.display_handle) |handle| {
            wispterm_lan_display_stop(handle);
            self.display_handle = null;
        }
    }

    /// ScreenCaptureKit queue: one JPEG-encoded frame of the display.
    fn displayFrame(ctx: *anyopaque, jpeg: [*]const u8, len: usize) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        if (len == 0) return;
        publishJpeg(self, jpeg[0..len]);
    }

    /// ScreenCaptureKit queue: capture died; fall back to window frames. The
    /// handle is released by the next `syncDisplayCapture` (never here: the
    /// bridge holds its lock while calling us).
    fn displayError(ctx: *anyopaque, message: [*:0]const u8) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.display_failed.store(true, .release);
        std.debug.print("lan-stream: display capture failed ({s}); streaming the window instead until WispTerm restarts\n", .{std.mem.span(message)});
    }

    fn acceptLoop(self: *Server) void {
        while (!self.stop_flag.load(.acquire)) {
            const conn = self.listener.accept() catch {
                if (self.stop_flag.load(.acquire)) return;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            if (self.stop_flag.load(.acquire)) {
                conn.stream.close();
                return;
            }
            self.reapConns(false);
            self.spawnConn(conn.stream) catch {
                conn.stream.close();
            };
        }
    }

    fn spawnConn(self: *Server, stream: std.net.Stream) !void {
        const conn = try self.allocator.create(Conn);
        errdefer self.allocator.destroy(conn);
        conn.* = .{ .server = self, .stream = stream };
        {
            self.conns_mutex.lock();
            defer self.conns_mutex.unlock();
            try self.conns.append(self.allocator, conn);
        }
        conn.thread = std.Thread.spawn(.{}, Conn.run, .{conn}) catch |err| {
            self.conns_mutex.lock();
            defer self.conns_mutex.unlock();
            if (std.mem.lastIndexOfScalar(*Conn, self.conns.items, conn)) |i| _ = self.conns.swapRemove(i);
            return err;
        };
    }

    /// Joins and frees finished connections; with `all`, shuts every socket
    /// down first so the threads finish promptly, then joins all of them.
    fn reapConns(self: *Server, all: bool) void {
        var i: usize = 0;
        while (true) {
            const conn = blk: {
                self.conns_mutex.lock();
                defer self.conns_mutex.unlock();
                while (i < self.conns.items.len) {
                    const c = self.conns.items[i];
                    if (all or c.done.load(.acquire)) {
                        _ = self.conns.swapRemove(i);
                        break :blk c;
                    }
                    i += 1;
                }
                break :blk null;
            } orelse return;
            if (all) conn.shutdown();
            if (conn.thread) |t| t.join();
            conn.stream.close();
            self.allocator.destroy(conn);
        }
    }

    /// Blocks (≤1s per wait) until a frame newer than `*sent_seq` exists, then
    /// returns a copy of it. Null on timeout so the caller re-checks stop.
    fn takeNewerFrame(self: *Server, sent_seq: *u64) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.seq == sent_seq.*) {
            self.cond.timedWait(&self.mutex, std.time.ns_per_s) catch return null;
            if (self.seq == sent_seq.*) return null;
        }
        const frame = self.frame orelse return null;
        sent_seq.* = self.seq;
        return self.allocator.dupe(u8, frame) catch null;
    }
};

/// One accepted socket: reads the greeting, then runs either the stream
/// loop or the message loop on its own thread.
const Conn = struct {
    server: *Server,
    stream: std.net.Stream,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // WISP2 state. `closed` stops both the writer and the reader; the queue
    // holds relay-format JSON lines (without the trailing newline).
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    queued_bytes: usize = 0,
    overflow: bool = false,
    last_recv_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    reader: ?std.Thread = null,

    fn run(self: *Conn) void {
        defer self.done.store(true, .release);
        self.serve() catch {};
    }

    fn shutdown(self: *Conn) void {
        self.closed.store(true, .release);
        self.cond.broadcast();
        std.posix.shutdown(self.stream.handle, .both) catch {};
    }

    fn serve(self: *Conn) !void {
        const server = self.server;
        const stream = self.stream;
        setTimeout(stream.handle, std.posix.SO.RCVTIMEO, HELLO_TIMEOUT_MS);
        setTimeout(stream.handle, std.posix.SO.SNDTIMEO, SEND_TIMEOUT_MS);
        var hello: [MAX_HELLO_BYTES]u8 = undefined;
        var len: usize = 0;
        while (std.mem.indexOfScalar(u8, hello[0..len], '\n') == null) {
            if (len == hello.len or server.stop_flag.load(.acquire)) return;
            const n = try transport.recv(stream.handle, hello[len..]);
            if (n == 0) return;
            len += n;
        }
        const nl = std.mem.indexOfScalar(u8, hello[0..len], '\n').?;
        const greeting = parseHello(hello[0..nl]) orelse return;
        if (!keyMatches(server.key_hash, greeting.key)) {
            std.debug.print("lan-stream: client rejected (bad key)\n", .{});
            return;
        }
        switch (greeting.version) {
            1 => try self.serveStream(),
            2 => try self.serveMessages(hello[nl + 1 .. len]),
            else => unreachable,
        }
    }

    // ---- WISP1: JPEG frames ------------------------------------------------

    fn serveStream(self: *Conn) !void {
        const server = self.server;
        std.debug.print("lan-stream: viewer connected\n", .{});
        defer std.debug.print("lan-stream: viewer left\n", .{});
        _ = server.viewers.fetchAdd(1, .acq_rel);
        defer {
            _ = server.viewers.fetchSub(1, .acq_rel);
            server.syncDisplayCapture();
        }
        var sent_seq: u64 = 0;
        while (!server.stop_flag.load(.acquire) and !self.closed.load(.acquire)) {
            // Cheap when nothing changed; also reaps a failed capture session.
            server.syncDisplayCapture();
            const frame = server.takeNewerFrame(&sent_seq) orelse continue;
            defer server.allocator.free(frame);
            var header: [4]u8 = undefined;
            std.mem.writeInt(u32, &header, @intCast(frame.len), .big);
            try transport.sendAll(self.stream.handle, &header);
            try transport.sendAll(self.stream.handle, frame);
        }
    }

    // ---- WISP2: relay messages over newline-delimited JSON -----------------

    fn serveMessages(self: *Conn, leftover: []const u8) !void {
        const server = self.server;
        const hub = server.hub orelse {
            std.debug.print("lan-stream: message channel refused (no remote hub)\n", .{});
            return;
        };
        std.debug.print("lan-stream: message client connected\n", .{});
        defer std.debug.print("lan-stream: message client left\n", .{});

        self.last_recv_ms.store(std.time.milliTimestamp(), .release);
        setTimeout(self.stream.handle, std.posix.SO.RCVTIMEO, RECV_POLL_MS);
        // Runs last: only after the hub and the reader can no longer enqueue.
        defer self.drainQueue();

        // Bytes that arrived in the same read as the greeting belong to the
        // reader; hand them over before it starts.
        const carry = try server.allocator.dupe(u8, leftover);
        self.reader = std.Thread.spawn(.{}, readerMain, .{ self, carry }) catch |err| {
            server.allocator.free(carry);
            return err;
        };
        defer {
            self.closed.store(true, .release);
            std.posix.shutdown(self.stream.handle, .both) catch {};
            if (self.reader) |t| t.join();
        }

        hub.addTransport(self, transportSend);
        defer hub.removeTransport(self);
        if (hub.lastLayoutAlloc(server.allocator)) |layout| self.enqueueOwned(layout);

        var last_send_ms = std.time.milliTimestamp();
        while (!server.stop_flag.load(.acquire) and !self.closed.load(.acquire)) {
            const message = self.popMessage() orelse {
                const now = std.time.milliTimestamp();
                if (now - self.last_recv_ms.load(.acquire) > PEER_TIMEOUT_MS) {
                    std.debug.print("lan-stream: message client timed out\n", .{});
                    return;
                }
                if (now - last_send_ms >= HEARTBEAT_INTERVAL_MS) {
                    try transport.sendAll(self.stream.handle, PING_LINE);
                    last_send_ms = now;
                }
                continue;
            };
            defer server.allocator.free(message);
            try transport.sendAll(self.stream.handle, message);
            try transport.sendAll(self.stream.handle, "\n");
            last_send_ms = std.time.milliTimestamp();
        }
    }

    /// Hub callback (PTY/UI threads): enqueue a copy, or flag the connection
    /// as too slow. Never blocks on the socket.
    fn transportSend(ctx: *anyopaque, message: []const u8) void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        if (self.closed.load(.acquire)) return;
        const copy = self.server.allocator.dupe(u8, message) catch return;
        self.enqueueOwned(copy);
    }

    fn enqueueOwned(self: *Conn, message: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.overflow or
            self.queue.items.len >= MSG_QUEUE_LIMIT or
            self.queued_bytes + message.len > MSG_QUEUE_BYTES_LIMIT)
        {
            self.server.allocator.free(message);
            if (!self.overflow) std.debug.print("lan-stream: message client too slow, dropping it\n", .{});
            self.overflow = true;
            self.closed.store(true, .release);
            self.cond.broadcast();
            return;
        }
        self.queue.append(self.server.allocator, message) catch {
            self.server.allocator.free(message);
            return;
        };
        self.queued_bytes += message.len;
        self.cond.signal();
    }

    /// Blocks (≤1s) for the next outbound message; null on timeout so the
    /// writer can run its heartbeat and re-check stop flags.
    fn popMessage(self: *Conn) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len == 0 and !self.closed.load(.acquire)) {
            self.cond.timedWait(&self.mutex, std.time.ns_per_s) catch {};
        }
        if (self.queue.items.len == 0) return null;
        const message = self.queue.orderedRemove(0);
        self.queued_bytes -= message.len;
        return message;
    }

    fn drainQueue(self: *Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.queue.items) |m| self.server.allocator.free(m);
        self.queue.deinit(self.server.allocator);
        self.queue = .empty;
        self.queued_bytes = 0;
    }

    fn readerMain(self: *Conn, carry: []u8) void {
        const allocator = self.server.allocator;
        defer self.closed.store(true, .release);
        defer self.cond.broadcast();
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(allocator);
        var too_long = false;

        {
            // Owned by this thread; free it on the error path too.
            defer allocator.free(carry);
            self.feedLines(&line, carry, &too_long) catch return;
        }

        var buf: [16 * 1024]u8 = undefined;
        while (!self.closed.load(.acquire) and !self.server.stop_flag.load(.acquire)) {
            switch (recvPoll(self.stream.handle, &buf)) {
                .timeout => continue,
                .closed => return,
                .data => |n| {
                    self.last_recv_ms.store(std.time.milliTimestamp(), .release);
                    self.feedLines(&line, buf[0..n], &too_long) catch return;
                },
            }
        }
    }

    fn feedLines(self: *Conn, line: *std.ArrayListUnmanaged(u8), chunk: []const u8, too_long: *bool) !void {
        const allocator = self.server.allocator;
        var rest = chunk;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            if (too_long.*) {
                // Skip the remainder of an oversized line, then resume normally.
                too_long.* = false;
            } else {
                try line.appendSlice(allocator, rest[0..nl]);
                self.handleLine(line.items);
            }
            line.clearRetainingCapacity();
            rest = rest[nl + 1 ..];
        }
        if (too_long.*) return;
        if (line.items.len + rest.len > MAX_INCOMING_LINE_BYTES) {
            std.debug.print("lan-stream: dropping oversized message line\n", .{});
            line.clearRetainingCapacity();
            too_long.* = true;
            return;
        }
        try line.appendSlice(allocator, rest);
    }

    fn handleLine(self: *Conn, raw: []const u8) void {
        const message = std.mem.trim(u8, raw, " \t\r");
        if (message.len == 0) return;
        if (remote_hub.isJsonMessageType(message, "ping")) {
            const pong = self.server.allocator.dupe(u8, PONG_MESSAGE) catch return;
            self.enqueueOwned(pong);
            return;
        }
        if (remote_hub.isJsonMessageType(message, "pong")) return;
        const hub = self.server.hub orelse return;
        hub.handleIncomingMessage(message);
    }
};

const RecvResult = union(enum) { data: usize, timeout, closed };

/// recv() honouring SO_RCVTIMEO: a timeout is reported separately so the
/// reader can re-check its stop flags instead of treating it as a hang-up.
fn recvPoll(handle: std.net.Stream.Handle, buf: []u8) RecvResult {
    if (builtin.os.tag == .windows) {
        const n = transport.recv(handle, buf) catch return .closed;
        return if (n == 0) .closed else .{ .data = n };
    }
    const n = std.posix.recv(handle, buf, 0) catch |err| switch (err) {
        error.WouldBlock => return .timeout,
        else => return .closed,
    };
    return if (n == 0) .closed else .{ .data = n };
}

/// Render thread: true when a viewer is connected, frames come from the
/// window, and the frame interval elapsed.
pub fn wantsFrame(now_ms: i64) bool {
    const server = g_server orelse return false;
    if (server.viewers.load(.acquire) == 0) return false;
    if (!server.usesWindowFrames()) return false;
    return now_ms - server.last_capture_ms.load(.acquire) >= server.frame_interval_ms;
}

/// Render thread: call once per attempted capture, before the readback, so a
/// failing readback (occluded window, no drawable) still waits out the
/// interval instead of forcing a render every loop iteration.
pub fn markCapture(now_ms: i64) void {
    if (g_server) |server| server.last_capture_ms.store(now_ms, .release);
}

/// Render thread: JPEG-encodes a top-down RGBA frame and hands it to viewers.
pub fn publishRgba(rgba: []const u8, width: u32, height: u32) void {
    const server = g_server orelse return;
    if (comptime !supported) return;
    var len: usize = 0;
    const ptr = wispterm_lan_jpeg_encode(rgba.ptr, width, height, JPEG_QUALITY, &len) orelse return;
    defer wispterm_lan_jpeg_free(ptr);
    publishJpeg(server, ptr[0..len]);
}

fn publishJpeg(server: *Server, jpeg: []const u8) void {
    const copy = server.allocator.dupe(u8, jpeg) catch return;
    server.mutex.lock();
    defer server.mutex.unlock();
    if (server.frame) |old| server.allocator.free(old);
    server.frame = copy;
    server.seq += 1;
    server.cond.broadcast();
}

/// `lan-stream-fps` → milliseconds between frames, clamped to 1-30 fps.
fn frameIntervalMs(fps: u32) i64 {
    const clamped = @max(1, @min(fps, 30));
    return @divTrunc(1000, @as(i64, clamped));
}

const Greeting = struct { version: u8, key: []const u8 };

/// `WISP1 <key>` (stream) or `WISP2 <key>` (messages); anything else is null.
fn parseHello(line: []const u8) ?Greeting {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const version: u8 = if (std.mem.startsWith(u8, trimmed, "WISP1 "))
        1
    else if (std.mem.startsWith(u8, trimmed, "WISP2 "))
        2
    else
        return null;
    const key = std.mem.trim(u8, trimmed["WISP1 ".len..], " \t");
    return if (key.len == 0) null else .{ .version = version, .key = key };
}

/// DNS TXT record (length-prefixed strings) advertising what this port serves.
fn txtRecord(with_messages: bool) []const u8 {
    return if (with_messages) "\x0fcaps=stream,msg" else "\x0bcaps=stream";
}

fn hashKey(key: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &out, .{});
    return out;
}

/// Constant-time via digest comparison, so key length never leaks either.
fn keyMatches(expected: [32]u8, key: []const u8) bool {
    return std.crypto.timing_safe.eql([32]u8, expected, hashKey(key));
}

fn setTimeout(handle: std.net.Stream.Handle, which: u32, ms: u32) void {
    if (builtin.os.tag == .windows) return;
    const tv = std.posix.timeval{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, which, std.mem.asBytes(&tv)) catch {};
}

test "parseHello accepts the v1 and v2 greetings and rejects junk" {
    const v1 = parseHello("WISP1 secret\r").?;
    try std.testing.expectEqual(@as(u8, 1), v1.version);
    try std.testing.expectEqualStrings("secret", v1.key);
    const v2 = parseHello("WISP2 a b").?;
    try std.testing.expectEqual(@as(u8, 2), v2.version);
    try std.testing.expectEqualStrings("a b", v2.key);
    try std.testing.expect(parseHello("WISP1 ") == null);
    try std.testing.expect(parseHello("WISP2") == null);
    try std.testing.expect(parseHello("WISP3 secret") == null);
    try std.testing.expect(parseHello("GET / HTTP/1.1") == null);
}

test "frameIntervalMs clamps lan-stream-fps to 1-30" {
    try std.testing.expectEqual(@as(i64, 250), frameIntervalMs(4));
    try std.testing.expectEqual(@as(i64, 1000), frameIntervalMs(0));
    try std.testing.expectEqual(@as(i64, 33), frameIntervalMs(90));
    try std.testing.expectEqual(@as(i64, 100), frameIntervalMs(10));
}

test "display source falls back to window frames only after a failure" {
    var server: Server = undefined;
    server.source = .display;
    server.display_failed = std.atomic.Value(bool).init(false);
    try std.testing.expect(!server.usesWindowFrames());
    server.display_failed.store(true, .release);
    try std.testing.expect(server.usesWindowFrames());
    server.source = .window;
    server.display_failed.store(false, .release);
    try std.testing.expect(server.usesWindowFrames());
}

test "keyMatches compares the exact key only" {
    const h = hashKey("secret");
    try std.testing.expect(keyMatches(h, "secret"));
    try std.testing.expect(!keyMatches(h, "secre"));
    try std.testing.expect(!keyMatches(h, "secrets"));
    try std.testing.expect(!keyMatches(h, ""));
}

test "txtRecord is a well-formed length-prefixed TXT entry" {
    const with = txtRecord(true);
    try std.testing.expectEqual(@as(usize, with[0]), with.len - 1);
    try std.testing.expectEqualStrings("caps=stream,msg", with[1..]);
    const without = txtRecord(false);
    try std.testing.expectEqual(@as(usize, without[0]), without.len - 1);
    try std.testing.expectEqualStrings("caps=stream", without[1..]);
}

test "feedLines splits newline-delimited messages and queues pong for ping" {
    const allocator = std.testing.allocator;
    var server: Server = undefined;
    server.allocator = allocator;
    server.hub = null;
    var conn = Conn{ .server = &server, .stream = undefined };
    defer conn.drainQueue();
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);
    var too_long = false;

    try conn.feedLines(&line, "{\"type\":\"pi", &too_long);
    try std.testing.expectEqual(@as(usize, 0), conn.queue.items.len);
    try conn.feedLines(&line, "ng\"}\r\n{\"type\":\"ping\",\"at\":1}\n{\"type\":\"po", &too_long);
    try std.testing.expectEqual(@as(usize, 2), conn.queue.items.len);
    try std.testing.expectEqualStrings(PONG_MESSAGE, conn.queue.items[0]);
    try std.testing.expectEqualStrings("{\"type\":\"po", line.items);
}

test "enqueueOwned drops the connection once the queue overflows" {
    const allocator = std.testing.allocator;
    var server: Server = undefined;
    server.allocator = allocator;
    server.hub = null;
    var conn = Conn{ .server = &server, .stream = undefined };
    defer conn.drainQueue();

    var i: usize = 0;
    while (i < MSG_QUEUE_LIMIT) : (i += 1) {
        conn.enqueueOwned(try allocator.dupe(u8, "x"));
    }
    try std.testing.expect(!conn.closed.load(.acquire));
    conn.enqueueOwned(try allocator.dupe(u8, "overflow"));
    try std.testing.expect(conn.overflow);
    try std.testing.expect(conn.closed.load(.acquire));
    try std.testing.expectEqual(@as(usize, MSG_QUEUE_LIMIT), conn.queue.items.len);
}
