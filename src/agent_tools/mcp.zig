//! MCP tool adapter: routes one model tool-call to an external MCP server.
//!
//! Mirrors `dynamic.zig` (binary tools) — approval gate via the shared
//! permission model, output truncation via `output.zig` — but talks JSON-RPC
//! over stdio (`mcp_client.zig`) instead of a one-shot argv exec.
//!
//! ponytail: spawn-per-call. Simple and correct; add a persistent connection
//! pool if per-call MCP handshake latency ever matters.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../assistant/conversation/types.zig");
const mcp_client = @import("mcp_client.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;
const McpTool = types.McpTool;

/// Diagnostic scope for MCP; visible in `-Ddebug-console` builds. Filter `(mcp)`.
const log = std.log.scoped(.mcp);

pub fn find(tools: []const McpTool, name: []const u8) ?McpTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.function_name, name)) return tool;
    }
    return null;
}

/// Spawn the tool's MCP server, run one `tools/call`, and return the flattened
/// (truncated) text result. Approval-gated like binary tools.
pub fn run(ctx: *ToolContext, tool: McpTool, arguments_json: []const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    // Approval gate — same permission model as binary tools.
    switch (ctx.settings.permission) {
        .confirm, .auto => {
            const approval_text = try std.fmt.allocPrint(ctx.allocator, "{s} {s}", .{ tool.function_name, arguments_json });
            defer ctx.allocator.free(approval_text);
            if (!ctx.requestApproval(tool.function_name, approval_text, "Call MCP tool")) {
                return tool_output.deniedResult(ctx.allocator, approval_text, "operator denied MCP tool call");
            }
        },
        .full => {},
    }

    // argv = server_command ++ server_args.
    const argv = try ctx.allocator.alloc([]const u8, tool.server_args.len + 1);
    defer ctx.allocator.free(argv);
    argv[0] = tool.server_command;
    for (tool.server_args, 0..) |arg, i| argv[i + 1] = arg;

    log.debug("call '{s}' via {s} args={s}", .{ tool.function_name, tool.server_command, arguments_json });

    // ponytail: no read timeout / cancellation on the MCP call yet — a hung
    // server blocks the turn. Wire a deadline + child kill if that bites.
    var conn = mcp_client.Connection.spawn(ctx.allocator, argv) catch |err| {
        log.warn("call '{s}': server '{s}' failed to start: {s}", .{ tool.function_name, tool.server_command, @errorName(err) });
        return std.fmt.allocPrint(ctx.allocator, "MCP server '{s}' failed to start: {s}", .{ tool.server_command, @errorName(err) });
    };
    defer conn.deinit();

    conn.initialize() catch |err| {
        log.warn("call '{s}': initialize failed: {s}", .{ tool.function_name, @errorName(err) });
        return std.fmt.allocPrint(ctx.allocator, "MCP server '{s}' initialize failed: {s}", .{ tool.server_command, @errorName(err) });
    };

    const raw = conn.callTool(tool.function_name, arguments_json) catch |err| {
        log.warn("call '{s}': tools/call failed: {s}", .{ tool.function_name, @errorName(err) });
        return std.fmt.allocPrint(ctx.allocator, "MCP tool '{s}' failed: {s}", .{ tool.function_name, @errorName(err) });
    };
    log.debug("call '{s}' ok ({d} bytes)", .{ tool.function_name, raw.len });
    // truncateOwned takes ownership of `raw`.
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, raw);
}

test "find matches an MCP tool by name and misses otherwise" {
    const tools = [_]McpTool{.{ .function_name = "echo", .description = "", .server_command = "x" }};
    try std.testing.expect(find(tools[0..], "echo") != null);
    try std.testing.expect(find(tools[0..], "nope") == null);
}

fn denyApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return false;
}
fn allowApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}
fn notCancelled(_: *anyopaque) bool {
    return false;
}

test "run denies the call when the operator rejects it" {
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = std.testing.allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .auto },
        .approve = denyApprove,
        .cancelled = notCancelled,
    };
    const tool = McpTool{ .function_name = "echo", .description = "", .server_command = "/bin/false" };
    const out = try run(&ctx, tool, "{}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "DENIED") != null);
}

test "run round-trips a tool call against a real MCP server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}";
    const call_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hi from adapter\"}],\"isError\":false}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ call_line ++ "'; exec cat >/dev/null";
    const args = [_][]const u8{ "-c", script };

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = allowApprove,
        .cancelled = notCancelled,
    };
    const tool = McpTool{ .function_name = "echo", .description = "", .server_command = "/bin/sh", .server_args = args[0..] };
    const out = try run(&ctx, tool, "{\"text\":\"hi\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings("hi from adapter", out);
}
