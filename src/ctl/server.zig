//! In-process localhost TCP control server for wisptermctl. Platform-neutral
//! (no GUI deps): binds 127.0.0.1, accepts one JSON-lines request per
//! connection, authenticates the token, dispatches through a Control, replies,
//! and closes. Reads/writes of surfaces are cross-platform — the Control impl
//! pins surfaces via surface_registry rather than Win32 SendMessage (a no-op on
//! Linux). Lifecycle mirrors weixin/controller.zig: created by App with a live
//! Control, owns its accept thread.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const control_mod = @import("control.zig");

const MAX_REQUEST_BYTES = 64 * 1024;
pub const default_rows: u32 = 1000;

/// Per-recv timeout on an accepted connection. Bounds how long a stalled or
/// misbehaving local client can occupy the (serial) accept loop, and — together
/// with the stop-flag check in the read loop — caps shutdown latency so
/// destroy()/join() can never hang on a half-open connection.
const READ_TIMEOUT_MS: u32 = 3000;

pub const Server = struct {
    allocator: std.mem.Allocator,
    control: control_mod.Control,
    token: []u8, // owned
    listener: std.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Binds 127.0.0.1:`port` (0 = OS-assigned). Dupes `token`. Caller owns.
    pub fn create(allocator: std.mem.Allocator, control: control_mod.Control, token: []const u8, port: u16) !*Server {
        const address = try std.net.Address.parseIp4("127.0.0.1", port);
        var listener = try address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();
        const owned_token = try allocator.dupe(u8, token);
        errdefer allocator.free(owned_token);
        const self = try allocator.create(Server);
        self.* = .{
            .allocator = allocator,
            .control = control,
            .token = owned_token,
            .listener = listener,
            .port = listener.listen_address.getPort(),
        };
        return self;
    }

    pub fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// Signals the accept loop to exit and joins it. Idempotent.
    pub fn stop(self: *Server) void {
        if (self.thread == null) return;
        self.stop_flag.store(true, .release);
        // Unblock the blocking accept() with a throwaway self-connection.
        if (std.net.Address.parseIp4("127.0.0.1", self.port)) |addr| {
            if (std.net.tcpConnectToAddress(addr)) |s| s.close() else |_| {}
        } else |_| {}
        self.thread.?.join();
        self.thread = null;
    }

    pub fn destroy(self: *Server) void {
        self.stop();
        self.listener.deinit();
        self.allocator.free(self.token);
        self.allocator.destroy(self);
    }

    fn acceptLoop(self: *Server) void {
        while (!self.stop_flag.load(.acquire)) {
            const conn = self.listener.accept() catch {
                // A persistent accept error (e.g. EMFILE/ENFILE) must not spin
                // the loop at 100% CPU; back off briefly and re-check stop.
                if (self.stop_flag.load(.acquire)) return;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            defer conn.stream.close();
            if (self.stop_flag.load(.acquire)) return;
            self.handleConnection(conn.stream) catch {};
        }
    }

    fn handleConnection(self: *Server, stream: std.net.Stream) !void {
        // Bound each recv so a stalled client cannot block the loop indefinitely.
        setReadTimeout(stream.handle, READ_TIMEOUT_MS);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        var chunk: [4096]u8 = undefined;
        while (buf.items.len < MAX_REQUEST_BYTES) {
            if (self.stop_flag.load(.acquire)) return; // bail promptly on shutdown
            const n = stream.read(&chunk) catch break; // includes recv timeout (WouldBlock)
            if (n == 0) break;
            try buf.appendSlice(self.allocator, chunk[0..n]);
            if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
        }
        const nl = std.mem.indexOfScalar(u8, buf.items, '\n') orelse buf.items.len;
        const reply = try self.dispatch(buf.items[0..nl]);
        defer self.allocator.free(reply);
        stream.writeAll(reply) catch {};
    }

    /// Parse + authenticate + act. Returns an owned, newline-terminated reply.
    fn dispatch(self: *Server, line: []const u8) ![]u8 {
        var parsed = protocol.parseRequest(self.allocator, line) catch
            return protocol.encodeError(self.allocator, "invalid request");
        defer parsed.deinit();
        const req = parsed.value;

        if (!tokenEqual(self.token, req.token))
            return protocol.encodeError(self.allocator, "unauthorized");

        switch (req.cmd) {
            .panes => {
                const json = (try self.control.listPanes(self.allocator)) orelse
                    return protocol.encodeError(self.allocator, "panes not available");
                defer self.allocator.free(json);
                return protocol.encodeOkRawJson(self.allocator, json);
            },
            .get_text => {
                if (req.id.len == 0) return protocol.encodeError(self.allocator, "missing id");
                const text = (try self.control.getText(self.allocator, req.id, req.recent)) orelse
                    return protocol.encodeError(self.allocator, "surface not found");
                defer self.allocator.free(text);
                return protocol.encodeOkText(self.allocator, text);
            },
            .send_text => {
                if (req.id.len == 0) return protocol.encodeError(self.allocator, "missing id");
                if (!self.control.sendText(req.id, req.data))
                    return protocol.encodeError(self.allocator, "surface not found");
                return protocol.encodeOk(self.allocator);
            },
        }
    }
};

/// Set a receive timeout on an accepted socket (best-effort; failures are
/// ignored — a missing timeout only weakens the stall bound, never correctness).
fn setReadTimeout(handle: std.net.Stream.Handle, ms: u32) void {
    if (builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const timeout: u32 = ms; // SO_RCVTIMEO is a DWORD of milliseconds on Windows
        _ = ws2.setsockopt(handle, ws2.SOL.SOCKET, ws2.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(u32));
    } else {
        const tv = std.posix.timeval{
            .sec = @intCast(ms / 1000),
            .usec = @intCast((ms % 1000) * 1000),
        };
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

/// Constant-time token comparison. Empty tokens never match.
fn tokenEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len or a.len == 0) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// ---- tests (pure dispatch; no sockets) ----
const t = std.testing;

const FakeControl = struct {
    sent: std.ArrayListUnmanaged(u8) = .empty,
    fn list_panes(ctx: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        return try a.dupe(u8, "{\"tabs\":[]}");
    }
    fn get_text(ctx: *anyopaque, a: std.mem.Allocator, id: []const u8, _: ?u32) anyerror!?[]u8 {
        _ = ctx;
        if (std.mem.eql(u8, id, "s1")) return try a.dupe(u8, "screen");
        return null;
    }
    fn send_text(ctx: *anyopaque, id: []const u8, data: []const u8) bool {
        const self: *FakeControl = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, id, "s1")) return false;
        self.sent.appendSlice(t.allocator, data) catch return false;
        return true;
    }
    fn iface(self: *FakeControl) control_mod.Control {
        return .{ .ctx = self, .vtable = &.{ .list_panes = list_panes, .get_text = get_text, .send_text = send_text } };
    }
};

fn fakeServer(fc: *FakeControl) Server {
    return .{ .allocator = t.allocator, .control = fc.iface(), .token = @constCast("secret"), .listener = undefined, .port = 0 };
}

test "tokenEqual is constant-time-ish and rejects empty/mismatched" {
    try t.expect(tokenEqual("abc", "abc"));
    try t.expect(!tokenEqual("abc", "abd"));
    try t.expect(!tokenEqual("abc", "ab"));
    try t.expect(!tokenEqual("", ""));
}

test "dispatch rejects bad token" {
    var fc = FakeControl{};
    defer fc.sent.deinit(t.allocator);
    var srv = fakeServer(&fc);
    const line = try protocol.encodeRequest(t.allocator, .{ .token = "wrong", .cmd = .panes });
    defer t.allocator.free(line);
    const reply = try srv.dispatch(line);
    defer t.allocator.free(reply);
    try t.expect(std.mem.indexOf(u8, reply, "unauthorized") != null);
}

test "dispatch panes / get-text / send-text happy + missing paths" {
    var fc = FakeControl{};
    defer fc.sent.deinit(t.allocator);
    var srv = fakeServer(&fc);

    const p = try protocol.encodeRequest(t.allocator, .{ .token = "secret", .cmd = .panes });
    defer t.allocator.free(p);
    const pr = try srv.dispatch(p);
    defer t.allocator.free(pr);
    try t.expect(std.mem.indexOf(u8, pr, "\"ok\":true") != null);
    try t.expect(std.mem.indexOf(u8, pr, "tabs") != null);

    const g = try protocol.encodeRequest(t.allocator, .{ .token = "secret", .cmd = .get_text, .id = "s1" });
    defer t.allocator.free(g);
    const gr = try srv.dispatch(g);
    defer t.allocator.free(gr);
    try t.expect(std.mem.indexOf(u8, gr, "screen") != null);

    const gmiss = try protocol.encodeRequest(t.allocator, .{ .token = "secret", .cmd = .get_text, .id = "ghost" });
    defer t.allocator.free(gmiss);
    const gmr = try srv.dispatch(gmiss);
    defer t.allocator.free(gmr);
    try t.expect(std.mem.indexOf(u8, gmr, "surface not found") != null);

    const s = try protocol.encodeRequest(t.allocator, .{ .token = "secret", .cmd = .send_text, .id = "s1", .data = "echo hi\n" });
    defer t.allocator.free(s);
    const sr = try srv.dispatch(s);
    defer t.allocator.free(sr);
    try t.expect(std.mem.indexOf(u8, sr, "\"ok\":true") != null);
    try t.expectEqualStrings("echo hi\n", fc.sent.items);
}

test "dispatch surfaces a malformed line as an error reply" {
    var fc = FakeControl{};
    defer fc.sent.deinit(t.allocator);
    var srv = fakeServer(&fc);
    const reply = try srv.dispatch("not json at all");
    defer t.allocator.free(reply);
    try t.expect(std.mem.indexOf(u8, reply, "invalid request") != null);
}
