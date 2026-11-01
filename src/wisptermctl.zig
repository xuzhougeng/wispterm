//! wisptermctl — standalone CLI client for the WispTerm agent terminal control
//! API. Auto-discovers the running instance via <config-dir>/agent-control.json
//! (port + token), then speaks the JSON-lines protocol over loopback TCP.
//!
//! Commands:
//!   wisptermctl panes
//!   wisptermctl get-text    -t <surface-id> [--recent N]
//!   wisptermctl send-text   -t <surface-id> "<text with \n \t \xNN escapes>"
//!   wisptermctl wait-for    -t <surface-id> "<substring|regex>" [--regex] [--lines N] [--timeout SECONDS]
//!   wisptermctl spawn       [--cwd DIR] [--kind AGENT] [--split right|down] [--wait-ready] [-- program args...]
//!   wisptermctl agent-state -t <surface-id>
//!   wisptermctl wait-agent  -t <surface-id> [--until STATE]... [--timeout SECONDS]
//!   wisptermctl prompt      -t <surface-id> "<text>" [--wait] [--until STATE]... [--timeout SECONDS]
//!
//! Lean by design: imports only ctl/* (+ the pure terminal_agents detector and
//! screen regex) and platform/dirs.zig, so it links without any GUI/SDL
//! dependencies.
const std = @import("std");
const protocol = @import("ctl/protocol.zig");
const discovery = @import("ctl/discovery.zig");
const client = @import("ctl/client.zig");
const transport = @import("ctl/transport.zig");

const ResultKind = enum { raw, text, ok_only };

const WAIT_POLL_MS: u64 = 500;
/// Agent-state waits poll faster: the server answers from a published mirror,
/// so a round trip is cheap and the wait returns within ~100 ms of the edge.
const AGENT_POLL_MS: u64 = 100;
/// Delay between a prompt's text and its Enter, like herdr's `agent prompt`.
const PROMPT_ENTER_DELAY_MS: u64 = 60;
/// After submitting a prompt, how long to wait for the agent to visibly react
/// (working or blocked) before reporting `prompt_stalled`.
const PROMPT_ACTIVITY_WINDOW_MS: i64 = 5000;
/// How long `spawn` waits for the UI thread to report the new surface id.
const SPAWN_RESOLVE_MS: i64 = 5000;

/// Exit codes beyond 0/1/2 (ok / request failed / timed out), mirroring the
/// herdr error names scripts key on.
const EXIT_TIMEOUT: u8 = 2;
const EXIT_AGENT_BLOCKED: u8 = 3;
const EXIT_PROMPT_STALLED: u8 = 4;
const EXIT_AGENT_NOT_READY: u8 = 5;

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
        .spawn => |sp| try runSpawn(allocator, info, sp),
        .wait_for => |w| try runWaitFor(allocator, info, w),
        .agent_state => |a| try runOnce(allocator, info, .{ .token = info.token, .cmd = .agent_state, .id = a.id }, .raw),
        .wait_agent => |w| {
            const final = try waitAgentState(allocator, info, w.id, w.until, w.timeout_ms, null);
            try printAgentState(allocator, final);
        },
        .prompt => |p| try runPrompt(allocator, info, p),
        .help => try stdoutAll(USAGE),
    }
}

/// A surface's agent state as the server reports it.
const AgentSnapshot = struct {
    app: client.AgentApp,
    state: client.AgentState,
    confidence: u8,
    /// Owned JSON text of the `agent-state` result, for printing.
    json: []u8,

    fn deinit(self: AgentSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
    }
};

/// One `agent-state` round trip. Exits (1) when the surface is gone or the
/// server cannot be reached, like every other request.
fn fetchAgentState(allocator: std.mem.Allocator, info: discovery.Info, id: []const u8) !AgentSnapshot {
    var resp = try requestChecked(allocator, info, .{ .token = info.token, .cmd = .agent_state, .id = id });
    defer resp.deinit();
    const json = try allocator.dupe(u8, resp.result_raw);
    errdefer allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const obj = if (parsed.value == .object) parsed.value.object else return error.MalformedResponse;
    const app_label = jsonString(obj, "agentApp") orelse "none";
    const state_label = jsonString(obj, "agentState") orelse "none";
    var confidence: u8 = 0;
    if (obj.get("agentConfidence")) |v| if (v == .integer and v.integer >= 0) {
        confidence = @intCast(@min(v.integer, 255));
    };
    return .{
        .app = @import("terminal_agents/detector.zig").appFromLabel(app_label) orelse .none,
        .state = @import("terminal_agents/detector.zig").stateFromLabel(state_label) orelse .none,
        .confidence = confidence,
        .json = json,
    };
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn printAgentState(allocator: std.mem.Allocator, snap: AgentSnapshot) !void {
    defer snap.deinit(allocator);
    try stdoutAll(snap.json);
    try stdoutAll("\n");
}

/// Poll `agent-state` until the state is in `until` (or, when `want_app` is
/// set, until that agent is identified AND in `until`). Returns the final
/// snapshot; exits 2 on timeout.
fn waitAgentState(
    allocator: std.mem.Allocator,
    info: discovery.Info,
    id: []const u8,
    until: client.UntilSet,
    timeout_ms: u32,
    want_app: ?client.AgentApp,
) !AgentSnapshot {
    const start = std.time.milliTimestamp();
    while (true) {
        const snap = try fetchAgentState(allocator, info, id);
        const app_ok = if (want_app) |app| snap.app == app else true;
        if (app_ok and until.contains(snap.state)) return snap;
        snap.deinit(allocator);
        if (std.time.milliTimestamp() - start >= @as(i64, @intCast(timeout_ms))) {
            try stderrPrint(allocator, "wisptermctl: timed out after {d}ms waiting for agent state\n", .{timeout_ms});
            std.process.exit(EXIT_TIMEOUT);
        }
        std.Thread.sleep(AGENT_POLL_MS * std.time.ns_per_ms);
    }
}

fn runSpawn(allocator: std.mem.Allocator, info: discovery.Info, sp: anytype) !void {
    // `--kind` prepends the agent's launcher to the argv tail.
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(allocator);
    var kind_label: []const u8 = "";
    var want_app: ?client.AgentApp = null;
    if (sp.kind.len != 0) {
        const kind = client.resolveKind(sp.kind) orelse unreachable; // validated by parseArgs
        try parts.append(allocator, kind.executable);
        kind_label = kind.label;
        want_app = kind.app;
    }
    try parts.appendSlice(allocator, sp.command);
    const command = try std.mem.join(allocator, " ", parts.items);
    defer allocator.free(command);

    var resp = try requestChecked(allocator, info, .{
        .token = info.token,
        .cmd = .spawn,
        .data = command,
        .cwd = sp.cwd,
        .kind = kind_label,
        .split = sp.split,
    });
    defer resp.deinit();
    const ticket = ticketFromResult(allocator, resp.result_raw) catch {
        try stderrAll("wisptermctl: malformed spawn reply from WispTerm\n");
        std.process.exit(1);
    };

    // The UI thread creates the terminal on its next tick; resolve its id.
    const surface_id = try resolveSpawnTicket(allocator, info, ticket);
    defer allocator.free(surface_id);

    if (!sp.wait_ready) {
        try stdoutPrint(allocator, "{{\"surfaceId\":\"{s}\"}}\n", .{surface_id});
        return;
    }
    // Like herdr's `agent start`: return once the agent is identified and
    // accepts input; a blocked agent (e.g. a trust prompt) returns
    // agent_not_ready so the caller can look before typing.
    const snap = try waitAgentState(allocator, info, surface_id, client.UntilSet.ready, sp.timeout_ms, want_app);
    defer snap.deinit(allocator);
    try stdoutPrint(allocator, "{{\"surfaceId\":\"{s}\",\"agentApp\":\"{s}\",\"agentState\":\"{s}\"}}\n", .{ surface_id, snap.app.label(), snap.state.label() });
    if (client.UntilSet.blocked.contains(snap.state)) {
        try stderrAll("wisptermctl: agent_not_ready (the agent is waiting for a decision)\n");
        std.process.exit(EXIT_AGENT_NOT_READY);
    }
}

fn ticketFromResult(allocator: std.mem.Allocator, raw: []const u8) !u32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const v = parsed.value.object.get("ticket") orelse return error.MalformedResponse;
    if (v != .integer or v.integer < 0) return error.MalformedResponse;
    return @intCast(@min(v.integer, std.math.maxInt(u32)));
}

/// Poll `spawn-result` until the UI thread has created the terminal. Owned id.
fn resolveSpawnTicket(allocator: std.mem.Allocator, info: discovery.Info, ticket: u32) ![]u8 {
    const start = std.time.milliTimestamp();
    while (true) {
        var resp = try requestChecked(allocator, info, .{ .token = info.token, .cmd = .spawn_result, .ticket = ticket });
        defer resp.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.result_raw, .{});
        defer parsed.deinit();
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (jsonString(obj, "surfaceId")) |id| return try allocator.dupe(u8, id);
            if (obj.get("failed") != null) {
                try stderrAll("wisptermctl: spawn failed (WispTerm could not open the terminal)\n");
                std.process.exit(1);
            }
        }
        if (std.time.milliTimestamp() - start >= SPAWN_RESOLVE_MS) {
            try stderrAll("wisptermctl: spawn accepted but no terminal appeared in time\n");
            std.process.exit(EXIT_TIMEOUT);
        }
        std.Thread.sleep(AGENT_POLL_MS * std.time.ns_per_ms);
    }
}

fn runPrompt(allocator: std.mem.Allocator, info: discovery.Info, p: anytype) !void {
    // A blocked agent gets no input: the dialog must be answered first
    // (herdr's agent_blocked).
    const before = try fetchAgentState(allocator, info, p.id);
    defer before.deinit(allocator);
    if (client.UntilSet.blocked.contains(before.state)) {
        try stderrAll("wisptermctl: agent_blocked (the agent is waiting for a decision; answer it with send-text first)\n");
        std.process.exit(EXIT_AGENT_BLOCKED);
    }

    const text = try client.decodeEscapes(allocator, p.text);
    defer allocator.free(text);
    try runOnce(allocator, info, .{ .token = info.token, .cmd = .send_text, .id = p.id, .data = text }, .ok_only);
    std.Thread.sleep(PROMPT_ENTER_DELAY_MS * std.time.ns_per_ms);
    try runOnce(allocator, info, .{ .token = info.token, .cmd = .send_text, .id = p.id, .data = "\r" }, .ok_only);
    if (!p.wait) return;

    // Unless the agent was already working, it must visibly react within a
    // short window; otherwise the prompt may not have been taken (a quiet
    // idle→idle would otherwise satisfy the wait immediately).
    const started = std.time.milliTimestamp();
    if (before.state != .running) {
        var reacted = false;
        while (std.time.milliTimestamp() - started < PROMPT_ACTIVITY_WINDOW_MS) {
            const snap = try fetchAgentState(allocator, info, p.id);
            defer snap.deinit(allocator);
            if (snap.state == .running or client.UntilSet.blocked.contains(snap.state)) {
                reacted = true;
                break;
            }
            std.Thread.sleep(AGENT_POLL_MS * std.time.ns_per_ms);
        }
        if (!reacted) {
            try stderrAll("wisptermctl: prompt_stalled (no working or blocked state was observed after submitting; read the agent before retrying)\n");
            std.process.exit(EXIT_PROMPT_STALLED);
        }
    }
    const elapsed: u32 = @intCast(@min(std.time.milliTimestamp() - started, p.timeout_ms));
    const final = try waitAgentState(allocator, info, p.id, p.until, p.timeout_ms - elapsed, null);
    try printAgentState(allocator, final);
}

/// Send one request and return the parsed response; exits (1) on transport
/// failure, malformed reply, or a server-side error.
fn requestChecked(allocator: std.mem.Allocator, info: discovery.Info, req: protocol.Request) !protocol.Response {
    const reply = requestOnce(allocator, info, req) catch |err| {
        try stderrPrint(allocator, "wisptermctl: cannot reach WispTerm on 127.0.0.1:{d} ({s})\n", .{ info.port, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(reply);
    var resp = protocol.parseResponse(allocator, reply) catch {
        try stderrAll("wisptermctl: malformed response from WispTerm\n");
        std.process.exit(1);
    };
    errdefer resp.deinit();
    if (!resp.ok) {
        try stderrPrint(allocator, "wisptermctl: {s}\n", .{if (resp.error_msg.len != 0) resp.error_msg else "request failed"});
        std.process.exit(1);
    }
    return resp;
}

/// Open a fresh loopback connection, send one request, return the owned reply
/// line (read until newline or EOF — the server replies then closes).
fn requestOnce(allocator: std.mem.Allocator, info: discovery.Info, req: protocol.Request) ![]u8 {
    const addr = try std.net.Address.parseIp4("127.0.0.1", info.port);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    const line = try protocol.encodeRequest(allocator, req);
    defer allocator.free(line);
    // posix.send/recv, not the deprecated Stream.write/read: the read path is
    // broken on Windows overlapped sockets and returned 0 bytes for every reply
    // ("malformed response from WispTerm"). See ctl/transport.zig.
    try transport.sendAll(stream.handle, line);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (buf.items.len < 16 * 1024 * 1024) {
        const n = transport.recv(stream.handle, &chunk) catch break;
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
            const matched = client.waitMatchText(allocator, txt, w.pattern, w.regex, w.lines) catch |err| {
                try stderrPrint(allocator, "wisptermctl: invalid --regex pattern ({s})\n", .{@errorName(err)});
                std.process.exit(1);
            };
            if (matched) return; // matched → exit 0
        }
        if (std.time.milliTimestamp() - start >= @as(i64, @intCast(w.timeout_ms))) {
            try stderrPrint(allocator, "wisptermctl: wait-for timed out after {d}ms\n", .{w.timeout_ms});
            std.process.exit(EXIT_TIMEOUT);
        }
        std.Thread.sleep(WAIT_POLL_MS * std.time.ns_per_ms);
    }
}

fn stdoutAll(s: []const u8) !void {
    try std.fs.File.stdout().deprecatedWriter().writeAll(s);
}

fn stdoutPrint(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    try stdoutAll(msg);
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
    \\  wisptermctl wait-for -t <surface-id> "<pattern>" [--regex] [--lines N] [--timeout SECONDS]
    \\      Poll get-text until the output contains <pattern> (default 60s).
    \\      --regex matches the pattern against each line; --lines N searches
    \\      only the last N lines. Exit 0 on match, 2 on timeout.
    \\  wisptermctl spawn [--cwd DIR] [--kind AGENT] [--split right|down] [--wait-ready]
    \\                    [--timeout SECONDS] [-- program args...]
    \\      Open a new tab (or split the focused pane) in the running instance and
    \\      print {"surfaceId":...}. --cwd sets the working directory (default:
    \\      the active tab's cwd). --kind runs that agent's launcher (claude,
    \\      codex, gemini, copilot, cursor, kimi, opencode, pi, qwen, ...) with the
    \\      args after `--`; --wait-ready then blocks until the agent is at its
    \\      prompt (exit 5 if it stopped on a decision first). Examples:
    \\        wisptermctl spawn --cwd "F:\proj" -- claude -r 1b42b2ea
    \\        wisptermctl spawn --kind codex --split right --wait-ready -- -m gpt-5.4
    \\  wisptermctl agent-state -t <surface-id>
    \\      Print the surface's agent and state (idle/running/waiting_approval/
    \\      needs_input/done/none) as JSON.
    \\  wisptermctl wait-agent -t <surface-id> [--until STATE]... [--timeout SECONDS]
    \\      Wait until the agent's state is one of the --until values (default:
    \\      ready = idle, done, waiting_approval, needs_input). STATE also accepts
    \\      ready, blocked, run. Exit 0 and print the state, 2 on timeout.
    \\  wisptermctl prompt -t <surface-id> "<text>" [--wait] [--until STATE]... [--timeout SECONDS]
    \\      Type <text> into the agent and press Enter. Exit 3 (agent_blocked)
    \\      without sending when the agent is waiting for a decision. --wait then
    \\      waits like wait-agent; exit 4 (prompt_stalled) if the agent never
    \\      started working.
    \\
    \\Enable in WispTerm config:  agent-control-enabled = true
    \\Surface ids come from `wisptermctl panes`.
    \\
;
