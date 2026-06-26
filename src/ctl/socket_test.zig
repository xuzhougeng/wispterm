//! Real-loopback round-trip tests for the agent-control server + transport.
//!
//! These exercise the actual TCP path (Server accept thread ↔ client socket via
//! ctl/transport.zig), not just the pure dispatch layer. They live in their own
//! file — pure std + sockets, no libc-specific or GUI deps — so the same tests
//! run on EVERY host, Windows included, via the `test-ctl` build step. That is
//! the regression guard the v1.30.0 "malformed response" bug slipped through:
//! the round-trip previously ran only on non-Windows hosts (test_posix.zig), and
//! the deprecated Stream.read it used is broken only on Windows overlapped
//! sockets — so the bug was never exercised where it bit. See transport.zig.
const std = @import("std");
const ctl_server = @import("server.zig");
const protocol = @import("protocol.zig");
const control_mod = @import("control.zig");
const transport = @import("transport.zig");

test "ctl server answers a real loopback request and stops cleanly" {
    // get-text for id "big" returns a payload larger than one recv chunk so the
    // round-trip exercises sendAll's partial-write loop and multi-recv reassembly
    // (not just a one-shot small reply).
    const big_len = 200_000;
    const C = struct {
        fn list_panes(_: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "{\"activeTab\":0,\"tabs\":[]}");
        }
        fn get_text(_: *anyopaque, a: std.mem.Allocator, id: []const u8, _: ?u32) anyerror!?[]u8 {
            if (!std.mem.eql(u8, id, "big")) return null;
            const out = try a.alloc(u8, big_len);
            @memset(out, 'x');
            return out;
        }
        fn send_text(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn ui_state(_: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "{\"activeOverlay\":\"none\"}");
        }
        fn spawn(_: *anyopaque, cwd: []const u8, _: []const u8) bool {
            return std.mem.eql(u8, cwd, "/work"); // accept only the expected request
        }
        var dummy: u8 = 0;
        fn iface() control_mod.Control {
            return .{ .ctx = &dummy, .vtable = &.{ .list_panes = list_panes, .get_text = get_text, .send_text = send_text, .ui_state = ui_state, .spawn = spawn } };
        }
    };

    const srv = try ctl_server.Server.create(std.testing.allocator, C.iface(), "tok", 0);
    defer srv.destroy(); // exercises stop()+join even on the success path
    try srv.start();
    try std.testing.expect(srv.port != 0);

    const addr = try std.net.Address.parseIp4("127.0.0.1", srv.port);

    // Drive the client side through ctl/transport — the same code path
    // wisptermctl uses — so this round-trip guards the transport the Windows
    // v1.30.0 bug lived in, not just the protocol layer.
    const roundtrip = struct {
        fn run(a: std.mem.Allocator, ad: std.net.Address, req: protocol.Request, sink: *std.ArrayListUnmanaged(u8)) !void {
            var stream = try std.net.tcpConnectToAddress(ad);
            defer stream.close();
            const line = try protocol.encodeRequest(a, req);
            defer a.free(line);
            try transport.sendAll(stream.handle, line);
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = transport.recv(stream.handle, &chunk) catch break;
                if (n == 0) break;
                try sink.appendSlice(a, chunk[0..n]);
                if (std.mem.indexOfScalar(u8, sink.items, '\n') != null) break;
            }
        }
    }.run;

    const alloc = std.testing.allocator;

    var panes: std.ArrayListUnmanaged(u8) = .empty;
    defer panes.deinit(alloc);
    try roundtrip(alloc, addr, .{ .token = "tok", .cmd = .panes }, &panes);
    try std.testing.expect(std.mem.indexOf(u8, panes.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, panes.items, "activeTab") != null);

    // ui-state round-trips over the same socket protocol as panes.
    var ui: std.ArrayListUnmanaged(u8) = .empty;
    defer ui.deinit(alloc);
    try roundtrip(alloc, addr, .{ .token = "tok", .cmd = .ui_state }, &ui);
    try std.testing.expect(std.mem.indexOf(u8, ui.items, "activeOverlay") != null);

    // spawn round-trips its cwd+command over the wire and replies ok.
    var sp: std.ArrayListUnmanaged(u8) = .empty;
    defer sp.deinit(alloc);
    try roundtrip(alloc, addr, .{ .token = "tok", .cmd = .spawn, .data = "claude -r abc", .cwd = "/work" }, &sp);
    try std.testing.expect(std.mem.indexOf(u8, sp.items, "\"ok\":true") != null);

    // A large get-text reply round-trips intact: this is what a multi-write
    // server response + multi-read client looks like, and proves no bytes are
    // dropped or truncated by the transport.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(alloc);
    try roundtrip(alloc, addr, .{ .token = "tok", .cmd = .get_text, .id = "big" }, &big);
    var big_resp = try protocol.parseResponse(alloc, big.items);
    defer big_resp.deinit();
    try std.testing.expect(big_resp.ok);
    try std.testing.expectEqual(@as(usize, big_len), big_resp.result_text.?.len);

    // A bad token is rejected over the wire too.
    var bad: std.ArrayListUnmanaged(u8) = .empty;
    defer bad.deinit(alloc);
    try roundtrip(alloc, addr, .{ .token = "nope", .cmd = .panes }, &bad);
    try std.testing.expect(std.mem.indexOf(u8, bad.items, "unauthorized") != null);
}

test "ctl server shutdown does not hang on a stalled (newline-less) connection" {
    const C = struct {
        fn list_panes(_: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "{}");
        }
        fn get_text(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?u32) anyerror!?[]u8 {
            return null;
        }
        fn send_text(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn ui_state(_: *anyopaque, _: std.mem.Allocator) anyerror!?[]u8 {
            return null;
        }
        fn spawn(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        var dummy: u8 = 0;
        fn iface() control_mod.Control {
            return .{ .ctx = &dummy, .vtable = &.{ .list_panes = list_panes, .get_text = get_text, .send_text = send_text, .ui_state = ui_state, .spawn = spawn } };
        }
    };

    const srv = try ctl_server.Server.create(std.testing.allocator, C.iface(), "tok", 0);
    try srv.start();

    // Open a connection and send a partial request with NO trailing newline,
    // then never read/close it until after shutdown — the worst case for the
    // serial accept loop.
    const addr = try std.net.Address.parseIp4("127.0.0.1", srv.port);
    var stalled = try std.net.tcpConnectToAddress(addr);
    try transport.sendAll(stalled.handle, "{\"token\":\"tok\",\"cmd\":\"pa");
    std.Thread.sleep(50 * std.time.ns_per_ms); // let the accept loop block in read()

    // If the recv-timeout + stop-flag fix regressed, destroy() -> join() would
    // block forever and this test would hang (a visible failure). With the fix
    // it returns within the recv timeout.
    srv.destroy();
    stalled.close();
}
