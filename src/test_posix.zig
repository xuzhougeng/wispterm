//! Native libc-linked test runner for modules that need real file I/O, the
//! libc timezone functions, or other POSIX capabilities unavailable in the
//! fast (no-libc) or cross-compiled (windows-gnu) test runners.
//!
//! Added to `test-full` (see build.zig) for all non-Windows hosts. Put tests
//! here when they involve:
//!   - std.fs / tmpDir file round-trips
//!   - ai_history_time.localOffsetSeconds() (calls localtime_r / timegm)
//!   - socketpair / fork / other POSIX syscalls
//!
//! Do NOT put tests here that can live in test_fast.zig (no libc needed) or
//! test_main.zig (full app graph, Windows/macOS CI).

const std = @import("std");
// Suppress unused build_options import expected by some imported modules.
pub const build_options = @import("build_options");

comptime {
    _ = @import("ai_loop_store.zig");
    _ = @import("child_output.zig");
    _ = @import("platform/pdf_render_linux.zig");
    // tmux posix-only tests: socketpair virtual PTY + pane I/O bridge. They need
    // libc and a real posix target, and are guarded out of the windows app test
    // binary, so this native runner is the only place they execute.
    _ = @import("platform/pty_virtual_test.zig");
    _ = @import("tmux/pane.zig");
    _ = @import("tmux/pane_io_test.zig");
}

test "ctl server answers a real loopback request and stops cleanly" {
    const ctl_server = @import("ctl/server.zig");
    const protocol = @import("ctl/protocol.zig");
    const control_mod = @import("ctl/control.zig");

    const C = struct {
        fn list_panes(_: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "{\"activeTab\":0,\"tabs\":[]}");
        }
        fn get_text(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?u32) anyerror!?[]u8 {
            return null;
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
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    const line = try protocol.encodeRequest(std.testing.allocator, .{ .token = "tok", .cmd = .panes });
    defer std.testing.allocator.free(line);
    try stream.writeAll(line);

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) break;
        total += n;
        if (std.mem.indexOfScalar(u8, buf[0..total], '\n') != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "activeTab") != null);

    // ui-state round-trips over the same socket protocol as panes.
    var s_ui = try std.net.tcpConnectToAddress(addr);
    defer s_ui.close();
    const ui_line = try protocol.encodeRequest(std.testing.allocator, .{ .token = "tok", .cmd = .ui_state });
    defer std.testing.allocator.free(ui_line);
    try s_ui.writeAll(ui_line);
    var ui_buf: [256]u8 = undefined;
    const ui_n = try s_ui.read(&ui_buf);
    try std.testing.expect(std.mem.indexOf(u8, ui_buf[0..ui_n], "activeOverlay") != null);

    // spawn round-trips its cwd+command over the wire and replies ok.
    var s_sp = try std.net.tcpConnectToAddress(addr);
    defer s_sp.close();
    const sp_line = try protocol.encodeRequest(std.testing.allocator, .{ .token = "tok", .cmd = .spawn, .data = "claude -r abc", .cwd = "/work" });
    defer std.testing.allocator.free(sp_line);
    try s_sp.writeAll(sp_line);
    var sp_buf: [256]u8 = undefined;
    const sp_n = try s_sp.read(&sp_buf);
    try std.testing.expect(std.mem.indexOf(u8, sp_buf[0..sp_n], "\"ok\":true") != null);

    // A bad token is rejected over the wire too.
    var s2 = try std.net.tcpConnectToAddress(addr);
    defer s2.close();
    const bad = try protocol.encodeRequest(std.testing.allocator, .{ .token = "nope", .cmd = .panes });
    defer std.testing.allocator.free(bad);
    try s2.writeAll(bad);
    var buf2: [256]u8 = undefined;
    const n2 = try s2.read(&buf2);
    try std.testing.expect(std.mem.indexOf(u8, buf2[0..n2], "unauthorized") != null);
}

test "ctl server shutdown does not hang on a stalled (newline-less) connection" {
    const ctl_server = @import("ctl/server.zig");
    const control_mod = @import("ctl/control.zig");

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
    try stalled.writeAll("{\"token\":\"tok\",\"cmd\":\"pa");
    std.Thread.sleep(50 * std.time.ns_per_ms); // let the accept loop block in read()

    // If the recv-timeout + stop-flag fix regressed, destroy() -> join() would
    // block forever and this test would hang (a visible failure). With the fix
    // it returns within the recv timeout.
    srv.destroy();
    stalled.close();
}

test "pdf_render_linux rasterizes a generated two-page PDF via poppler" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    // Skip cleanly on hosts without poppler-utils.
    const probe = std.process.Child.run(.{ .allocator = alloc, .argv = &.{ "pdftoppm", "-v" } }) catch return error.SkipZigTest;
    alloc.free(probe.stdout);
    alloc.free(probe.stderr);

    const pdf = try buildMinimalTwoPagePdf(alloc);
    defer alloc.free(pdf);

    const pdf_render = @import("platform/pdf_render.zig");
    const page0 = try pdf_render.renderPage(alloc, pdf, 0, 320);
    defer alloc.free(page0.png);
    try std.testing.expectEqual(@as(u32, 2), page0.page_count);
    // PNG magic
    try std.testing.expect(page0.png.len > 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, page0.png[0..4]);

    const page1 = try pdf_render.renderPage(alloc, pdf, 1, 320);
    defer alloc.free(page1.png);
    try std.testing.expectEqual(@as(u32, 2), page1.page_count);

    // Out-of-range page fails, invalid bytes fail.
    try std.testing.expectError(error.RenderFailed, pdf_render.renderPage(alloc, pdf, 2, 320));
    try std.testing.expectError(error.InvalidPdf, pdf_render.renderPage(alloc, "not a pdf", 0, 320));
}

/// Assemble a minimal valid 2-page PDF, computing xref offsets at runtime so
/// the fixture never drifts out of sync with its body.
fn buildMinimalTwoPagePdf(alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var offsets: [6]usize = undefined; // objects 1..5; index 0 unused

    try out.appendSlice(alloc, "%PDF-1.4\n");
    const objects = [_][]const u8{
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>\nendobj\n",
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj\n",
        "4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj\n",
        "5 0 obj\n<< >>\nendobj\n",
    };
    for (objects, 1..) |obj, num| {
        offsets[num] = out.items.len;
        try out.appendSlice(alloc, obj);
    }
    const xref_at = out.items.len;
    try out.appendSlice(alloc, "xref\n0 6\n0000000000 65535 f \n");
    for (offsets[1..6]) |off| {
        try out.print(alloc, "{d:0>10} 00000 n \n", .{off});
    }
    try out.print(
        alloc,
        "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n",
        .{xref_at},
    );
    return out.toOwnedSlice(alloc);
}

test "copilot hint flag I/O wrappers are callable" {
    const window_state = @import("platform/window_state.zig");
    const alloc = std.testing.allocator;
    _ = window_state.copilotHintShown(alloc);
    window_state.setCopilotHintShown(alloc);
    _ = window_state.copilotHintShown(alloc);
}

test "skill_local_fs aggHashHex matches the POSIX find|sha256sum recipe byte-for-byte" {
    const skill_local_fs = @import("skill_local_fs.zig");
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A skill dir with a top-level file, nested files, and a dotfile — exercises
    // bytewise path sorting and recursion, exactly what the shell pipeline sees.
    try tmp.dir.makePath("skill/refs");
    try tmp.dir.writeFile(.{ .sub_path = "skill/SKILL.md", .data = "# title\nbody\n" });
    try tmp.dir.writeFile(.{ .sub_path = "skill/z.txt", .data = "zzz" });
    try tmp.dir.writeFile(.{ .sub_path = "skill/refs/a.md", .data = "alpha" });
    try tmp.dir.writeFile(.{ .sub_path = "skill/refs/b.md", .data = "beta\n" });
    try tmp.dir.writeFile(.{ .sub_path = "skill/.keep", .data = "" });
    // A whitespace name: default `xargs` word-splits it, so the shell drops it
    // from the aggregate — the native scan must drop it too (parity).
    try tmp.dir.writeFile(.{ .sub_path = "skill/a b.txt", .data = "ws" });

    const skill_abs = try tmp.dir.realpathAlloc(a, "skill");
    defer a.free(skill_abs);

    // Run the exact recipe the scan command uses for a skill_md target dir.
    const script = try std.fmt.allocPrint(a,
        \\HASHCMD="";
        \\if command -v sha256sum >/dev/null 2>&1; then HASHCMD="sha256sum";
        \\elif command -v shasum >/dev/null 2>&1; then HASHCMD="shasum -a 256"; fi;
        \\if [ -z "$HASHCMD" ]; then echo NOHASH; exit 0; fi;
        \\cd '{s}' && find . -type f | LC_ALL=C sort | xargs $HASHCMD | $HASHCMD | cut -d' ' -f1
    , .{skill_abs});
    defer a.free(script);

    const argv = [_][]const u8{ "sh", "-c", script };
    var child = std.process.Child.init(&argv, a);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = child.stdout.?;
    const raw = try stdout.readToEndAlloc(a, 4096);
    defer a.free(raw);
    _ = child.wait() catch {};

    const shell_hex = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, shell_hex, "NOHASH")) return error.SkipZigTest; // no hash tool

    var dir = try tmp.dir.openDir("skill", .{ .iterate = true });
    defer dir.close();
    const native = try skill_local_fs.aggHashHex(a, dir);

    try std.testing.expectEqualStrings(shell_hex, &native);
}
