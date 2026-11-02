//! LAN screen stream for the phone app: advertises `_wispterm._tcp` over
//! Bonjour and serves the rendered window as JPEG frames over raw TCP.
//!
//! Wire protocol: the client sends one line `WISP1 <remote-session-key>\n`;
//! the server then pushes frames as `[u32 big-endian len][jpeg bytes]` until
//! either side closes. A wrong key just closes the socket.
//!
//! Frames come from the render thread (AppWindow calls `wantsFrame` /
//! `publishRgba` around its ui_screenshot readback); the accept thread only
//! ships the latest one, so a slow phone drops frames instead of stalling
//! rendering.
//!
//! ponytail: macOS only (ImageIO JPEG + dns_sd). Windows/Linux need a JPEG
//! encoder and an mDNS responder before `supported` can flip on there.
const std = @import("std");
const builtin = @import("builtin");
const transport = @import("ctl/transport.zig");

pub const supported = builtin.os.tag == .macos;
pub const service_type = "_wispterm._tcp";

/// ponytail: 4 fps cap; raise once encode cost is measured.
const FRAME_INTERVAL_MS: i64 = 250;
const JPEG_QUALITY: f32 = 0.6;
const HELLO_TIMEOUT_MS: u32 = 3000;
const SEND_TIMEOUT_MS: u32 = 5000;
const MAX_HELLO_BYTES = 512;

extern fn wispterm_lan_jpeg_encode(rgba: [*]const u8, width: u32, height: u32, quality: f32, out_len: *usize) ?[*]u8;
extern fn wispterm_lan_jpeg_free(ptr: ?*anyopaque) void;
extern fn wispterm_lan_mdns_register(name: [*:0]const u8, port: u16) ?*anyopaque;
extern fn wispterm_lan_mdns_unregister(ref: ?*anyopaque) void;

var g_server: ?*Server = null;

pub const Server = struct {
    allocator: std.mem.Allocator,
    key_hash: [32]u8,
    listener: std.net.Server,
    port: u16,
    mdns: ?*anyopaque = null,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Number of authenticated viewers; the render thread captures only when > 0.
    viewers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_capture_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    frame: ?[]u8 = null,
    seq: u64 = 0,

    /// Binds 0.0.0.0 on an OS-assigned port and advertises it as `name`.
    pub fn create(allocator: std.mem.Allocator, name: []const u8, key: []const u8) !*Server {
        if (comptime !supported) return error.LanStreamUnsupported;
        if (key.len == 0) return error.LanStreamMissingKey;
        const address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var listener = try address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .key_hash = hashKey(key),
            .listener = listener,
            .port = listener.listen_address.getPort(),
        };
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        self.mdns = wispterm_lan_mdns_register(name_z.ptr, self.port);
        if (self.mdns == null) std.debug.print("lan-stream: Bonjour registration failed\n", .{});
        return self;
    }

    pub fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        g_server = self;
    }

    /// Stops + joins the accept thread, unregisters Bonjour, frees everything.
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
        if (comptime supported) wispterm_lan_mdns_unregister(self.mdns);
        self.listener.deinit();
        if (self.frame) |f| self.allocator.free(f);
        self.allocator.destroy(self);
    }

    fn acceptLoop(self: *Server) void {
        // ponytail: one viewer at a time; a second phone waits in the backlog.
        while (!self.stop_flag.load(.acquire)) {
            const conn = self.listener.accept() catch {
                if (self.stop_flag.load(.acquire)) return;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            defer conn.stream.close();
            if (self.stop_flag.load(.acquire)) return;
            self.serve(conn.stream) catch {};
        }
    }

    fn serve(self: *Server, stream: std.net.Stream) !void {
        setTimeout(stream.handle, std.posix.SO.RCVTIMEO, HELLO_TIMEOUT_MS);
        setTimeout(stream.handle, std.posix.SO.SNDTIMEO, SEND_TIMEOUT_MS);
        var hello: [MAX_HELLO_BYTES]u8 = undefined;
        var len: usize = 0;
        while (std.mem.indexOfScalar(u8, hello[0..len], '\n') == null) {
            if (len == hello.len or self.stop_flag.load(.acquire)) return;
            const n = try transport.recv(stream.handle, hello[len..]);
            if (n == 0) return;
            len += n;
        }
        const line = hello[0..std.mem.indexOfScalar(u8, hello[0..len], '\n').?];
        if (!keyMatches(self.key_hash, parseHello(line) orelse return)) {
            std.debug.print("lan-stream: viewer rejected (bad key)\n", .{});
            return;
        }

        std.debug.print("lan-stream: viewer connected\n", .{});
        defer std.debug.print("lan-stream: viewer left\n", .{});
        _ = self.viewers.fetchAdd(1, .acq_rel);
        defer _ = self.viewers.fetchSub(1, .acq_rel);
        var sent_seq: u64 = 0;
        while (!self.stop_flag.load(.acquire)) {
            const frame = self.takeNewerFrame(&sent_seq) orelse continue;
            defer self.allocator.free(frame);
            var header: [4]u8 = undefined;
            std.mem.writeInt(u32, &header, @intCast(frame.len), .big);
            try transport.sendAll(stream.handle, &header);
            try transport.sendAll(stream.handle, frame);
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

/// Render thread: true when a viewer is connected and the frame interval elapsed.
pub fn wantsFrame(now_ms: i64) bool {
    const server = g_server orelse return false;
    if (server.viewers.load(.acquire) == 0) return false;
    return now_ms - server.last_capture_ms.load(.acquire) >= FRAME_INTERVAL_MS;
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
    const copy = server.allocator.dupe(u8, ptr[0..len]) catch return;
    server.mutex.lock();
    defer server.mutex.unlock();
    if (server.frame) |old| server.allocator.free(old);
    server.frame = copy;
    server.seq += 1;
    server.cond.broadcast();
}

fn parseHello(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "WISP1 ")) return null;
    const key = std.mem.trim(u8, trimmed["WISP1 ".len..], " \t");
    return if (key.len == 0) null else key;
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

test "parseHello accepts the v1 greeting and rejects junk" {
    try std.testing.expectEqualStrings("secret", parseHello("WISP1 secret\r").?);
    try std.testing.expectEqualStrings("a b", parseHello("WISP1 a b").?);
    try std.testing.expect(parseHello("WISP1 ") == null);
    try std.testing.expect(parseHello("GET / HTTP/1.1") == null);
}

test "keyMatches compares the exact key only" {
    const h = hashKey("secret");
    try std.testing.expect(keyMatches(h, "secret"));
    try std.testing.expect(!keyMatches(h, "secre"));
    try std.testing.expect(!keyMatches(h, "secrets"));
    try std.testing.expect(!keyMatches(h, ""));
}
