//! wisptermctl — standalone CLI client for the WispTerm agent terminal control
//! API. Auto-discovers the running instance via <config-dir>/agent-control.json
//! (port + token), then speaks the JSON-lines protocol over loopback TCP.
//!
//! Commands:
//!   wisptermctl panes
//!   wisptermctl get-text  -t <surface-id> [--recent N]
//!   wisptermctl send-text -t <surface-id> "<text with \n \t \xNN escapes>"
//!   wisptermctl wait-for  -t <surface-id> "<substring>" [--timeout SECONDS]
//!
//! Lean by design: imports only ctl/* + platform/dirs.zig (std/builtin), so it
//! links without any GUI/SDL dependencies.
const std = @import("std");
const protocol = @import("ctl/protocol.zig");
const discovery = @import("ctl/discovery.zig");
const client = @import("ctl/client.zig");

const ResultKind = enum { raw, text, ok_only };

const WAIT_POLL_MS: u64 = 500;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const action = client.parseArgs(raw_args[1..]) catch {
        // Unknown command / bad flags: usage to stderr, non-zero exit.
        try stderrAll(USAGE);
        std.process.exit(2);
    };
    if (action == .help) {
        try stdoutAll(USAGE); // explicit help: usage to stdout, exit 0
        return;
    }

    const info = (try discovery.read(allocator)) orelse {
        try stderrAll("wisptermctl: agent control is not enabled. Set `agent-control-enabled = true` in your WispTerm config and restart.\n");
        std.process.exit(1);
    };
    defer allocator.free(info.token);

    switch (action) {
        .panes => try runOnce(allocator, info, .{ .token = info.token, .cmd = .panes }, .raw),
        .ui_state => try runOnce(allocator, info, .{ .token = info.token, .cmd = .ui_state }, .raw),
        .get_text => |g| try runOnce(allocator, info, .{ .token = info.token, .cmd = .get_text, .id = g.id, .recent = g.recent }, .text),
        .send_text => |s| {
            const data = try client.decodeEscapes(allocator, s.data);
            defer allocator.free(data);
            try runOnce(allocator, info, .{ .token = info.token, .cmd = .send_text, .id = s.id, .data = data }, .ok_only);
        },
        .wait_for => |w| try runWaitFor(allocator, info, w),
        .help => try stdoutAll(USAGE),
    }
}

/// Open a fresh loopback connection, send one request, return the owned reply
/// line (read until newline or EOF — the server replies then closes).
fn requestOnce(allocator: std.mem.Allocator, info: discovery.Info, req: protocol.Request) ![]u8 {
    const addr = try std.net.Address.parseIp4("127.0.0.1", info.port);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    const line = try protocol.encodeRequest(allocator, req);
    defer allocator.free(line);
    try stream.writeAll(line);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (buf.items.len < 16 * 1024 * 1024) {
        const n = stream.read(&chunk) catch break;
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..n]);
        if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
    }
    return buf.toOwnedSlice(allocator);
}

fn runOnce(allocator: std.mem.Allocator, info: discovery.Info, req: protocol.Request, kind: ResultKind) !void {
    const reply = requestOnce(allocator, info, req) catch |err| {
        try stderrPrint(allocator, "wisptermctl: cannot reach WispTerm on 127.0.0.1:{d} ({s})\n", .{ info.port, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(reply);

    var resp = protocol.parseResponse(allocator, reply) catch {
        try stderrAll("wisptermctl: malformed response from WispTerm\n");
        std.process.exit(1);
    };
    defer resp.deinit();

    if (!resp.ok) {
        try stderrPrint(allocator, "wisptermctl: {s}\n", .{if (resp.error_msg.len != 0) resp.error_msg else "request failed"});
        std.process.exit(1);
    }

    switch (kind) {
        .raw => {
            try stdoutAll(resp.result_raw);
            try stdoutAll("\n");
        },
        .text => {
            if (resp.result_text) |txt| try stdoutAll(txt);
        },
        .ok_only => {},
    }
}

fn runWaitFor(allocator: std.mem.Allocator, info: discovery.Info, w: anytype) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        const reply = requestOnce(allocator, info, .{ .token = info.token, .cmd = .get_text, .id = w.id }) catch |err| {
            try stderrPrint(allocator, "wisptermctl: cannot reach WispTerm on 127.0.0.1:{d} ({s})\n", .{ info.port, @errorName(err) });
            std.process.exit(1);
        };
        defer allocator.free(reply);

        var resp = protocol.parseResponse(allocator, reply) catch {
            try stderrAll("wisptermctl: malformed response from WispTerm\n");
            std.process.exit(1);
        };
        defer resp.deinit();

        if (!resp.ok) {
            try stderrPrint(allocator, "wisptermctl: {s}\n", .{if (resp.error_msg.len != 0) resp.error_msg else "request failed"});
            std.process.exit(1);
        }
        if (resp.result_text) |txt| {
            if (client.waitMatch(txt, w.pattern)) return; // matched → exit 0
        }
        if (std.time.milliTimestamp() - start >= @as(i64, @intCast(w.timeout_ms))) {
            try stderrPrint(allocator, "wisptermctl: wait-for timed out after {d}ms\n", .{w.timeout_ms});
            std.process.exit(2);
        }
        std.Thread.sleep(WAIT_POLL_MS * std.time.ns_per_ms);
    }
}

fn stdoutAll(s: []const u8) !void {
    try std.fs.File.stdout().deprecatedWriter().writeAll(s);
}

fn stderrAll(s: []const u8) !void {
    try std.fs.File.stderr().deprecatedWriter().writeAll(s);
}

fn stderrPrint(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    try stderrAll(msg);
}

const USAGE =
    \\wisptermctl — control WispTerm terminals from external agents/scripts
    \\
    \\Usage:
    \\  wisptermctl panes
    \\      List tabs/panes as JSON (id, title, cwd, cols/rows, cursor, focus, geometry).
    \\  wisptermctl ui-state
    \\      Print overlay UI state as JSON (active overlay, command-palette
    \\      selection/filter/mode, session launcher, settings visibility).
    \\  wisptermctl get-text -t <surface-id> [--recent N]
    \\      Print a surface's terminal text. --recent N prepends N scrollback rows.
    \\  wisptermctl send-text -t <surface-id> "<text>"
    \\      Send input to a surface. Escapes: \n \r \t \0 \\ \xNN (e.g. "ls\n").
    \\  wisptermctl wait-for -t <surface-id> "<substring>" [--timeout SECONDS]
    \\      Poll get-text until the output contains <substring> (default 60s).
    \\      Exit 0 on match, 2 on timeout.
    \\
    \\Enable in WispTerm config:  agent-control-enabled = true
    \\Surface ids come from `wisptermctl panes`.
    \\
;
