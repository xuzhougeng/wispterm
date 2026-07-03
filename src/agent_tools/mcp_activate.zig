//! Native Copilot tool `mcp_activate`: turn on one configured MCP server's
//! tools for this process. The system prompt lists inactive servers; the model
//! calls this before using their tools. If the server has no valid catalog
//! entry yet, this spawns it once (initialize + tools/list), writes the disk
//! catalog, and reloads the registry cache — so activation doubles as
//! first-time discovery. No approval gate: it only launches a server the user
//! already configured, and the real tool calls keep their own gate.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const mcp_registry = @import("../tools/mcp_registry.zig");
const mcp_catalog = @import("../tools/mcp_catalog.zig");
const tool_args = @import("args.zig");

const ToolContext = types.ToolContext;

/// Core op, allocator-only for tests. Returns the model-facing text.
pub fn activateByName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const servers = try mcp_registry.loadConfigFile(allocator);
    defer mcp_registry.freeServersConfig(allocator, servers);

    const idx = for (servers, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, name)) break i;
    } else null;
    if (idx == null) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.print(allocator, "No MCP server named \"{s}\".", .{name});
        if (servers.len > 0) {
            try out.appendSlice(allocator, " Configured servers:");
            for (servers) |s| try out.print(allocator, " {s}", .{s.name});
        } else {
            try out.appendSlice(allocator, " None configured; use mcp_config action=add.");
        }
        return out.toOwnedSlice(allocator);
    }
    const server = servers[idx.?];
    if (!server.enabled) {
        return std.fmt.allocPrint(allocator, "MCP server \"{s}\" is disabled. Enable it first with mcp_config action=enable.", .{name});
    }

    const hash = mcp_catalog.configHash(server.command, server.args);
    var catalog = mcp_catalog.load(allocator);
    const cached_ok = if (catalog.find(name)) |e| e.config_hash == hash else false;
    catalog.deinit(allocator);

    if (!cached_ok) {
        // First-time (or config-changed) discovery: spawn the server once.
        const one = [_]mcp_registry.ServerConfig{server};
        const snap = try mcp_registry.discover(allocator, one[0..]);
        defer mcp_registry.freeSnapshots(allocator, snap);
        if (snap.specs.len == 0) {
            return std.fmt.allocPrint(allocator, "Could not discover tools from MCP server \"{s}\" — it failed to start, failed the handshake, or listed no tools. Check its command with mcp_config action=list.", .{name});
        }
        try mcp_catalog.upsertServer(allocator, name, hash, std.time.timestamp(), snap.specs);
    }

    mcp_registry.reloadCache(allocator);
    if (!mcp_registry.activateServer(name)) {
        return std.fmt.allocPrint(allocator, "Could not activate MCP server \"{s}\" — activation slots are full (32) or the name is too long. Its tools can still be called directly.", .{name});
    }

    // Summarize what just became available from this thread's fresh cache.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (mcp_registry.cachedServers()) |srv| {
        if (!std.mem.eql(u8, srv.name, name)) continue;
        try out.print(allocator, "Activated MCP server \"{s}\" — {d} tool(s) now available:\n", .{ name, srv.spec_len });
        const specs = mcp_registry.cachedSpecs();
        for (specs[srv.spec_off..][0..srv.spec_len]) |s| {
            try out.print(allocator, "- {s}: {s}\n", .{ s.name, s.description });
        }
        return out.toOwnedSlice(allocator);
    }
    try out.print(allocator, "Activated MCP server \"{s}\".", .{name});
    return out.toOwnedSlice(allocator);
}

/// Tool entrypoint.
pub fn run(ctx: *ToolContext, arguments_json: []const u8) ![]u8 {
    var parsed = tool_args.parse(ctx.allocator, arguments_json) orelse
        return ctx.allocator.dupe(u8, "Invalid tool arguments");
    defer parsed.deinit();
    const name = tool_args.string(parsed.value, "server") orelse
        tool_args.string(parsed.value, "name") orelse
        return ctx.allocator.dupe(u8, "mcp_activate requires a \"server\" name (see the inactive-server list in the system prompt or mcp_config action=list).");
    return activateByName(ctx.allocator, name) catch |err|
        std.fmt.allocPrint(ctx.allocator, "MCP activate error: {s}", .{@errorName(err)});
}

// --- tests -------------------------------------------------------------------

const builtin = @import("builtin");
const dirs = @import("../platform/dirs.zig");

test "activateByName reports unknown and disabled servers" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    dirs.setTestConfigDirOverride(dir_path);
    defer dirs.setTestConfigDirOverride(null);
    mcp_registry.resetActivationForTest();
    defer mcp_registry.resetActivationForTest();

    const servers = [_]mcp_registry.ServerConfig{.{ .name = @constCast("off"), .command = @constCast("/bin/false"), .args = &.{}, .enabled = false }};
    try mcp_registry.saveConfigFile(a, servers[0..]);

    const unknown = try activateByName(a, "nope");
    defer a.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "No MCP server named") != null);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "off") != null); // 列出可用名

    const disabled = try activateByName(a, "off");
    defer a.free(disabled);
    try std.testing.expect(std.mem.indexOf(u8, disabled, "disabled") != null);
}

test "activateByName discovers a live server, writes the catalog, and activates" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    dirs.setTestConfigDirOverride(dir_path);
    defer dirs.setTestConfigDirOverride(null);
    mcp_registry.resetActivationForTest();
    defer mcp_registry.resetActivationForTest();

    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"greet\",\"description\":\"Greet someone\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"who\":{\"type\":\"string\"}}}}]}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "'; exec cat >/dev/null";
    var args0 = [_][]u8{ @constCast("-c"), @constCast(script) };
    const servers = [_]mcp_registry.ServerConfig{.{ .name = @constCast("demo"), .command = @constCast("/bin/sh"), .args = args0[0..], .enabled = true }};
    try mcp_registry.saveConfigFile(a, servers[0..]);

    const msg = try activateByName(a, "demo");
    defer a.free(msg);
    defer mcp_registry.reloadCacheFromServersForTest(a, &.{}); // 释放本线程缓存
    try std.testing.expect(std.mem.indexOf(u8, msg, "Activated MCP server \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "greet") != null);
    try std.testing.expect(mcp_registry.isActivated("demo"));

    // 目录已落盘且 hash 匹配
    var cat = mcp_catalog.load(a);
    defer cat.deinit(a);
    const entry = cat.find("demo").?;
    const arg_view = [_][]const u8{ "-c", script };
    try std.testing.expectEqual(mcp_catalog.configHash("/bin/sh", arg_view[0..]), entry.config_hash);
    try std.testing.expectEqual(@as(usize, 1), entry.tools.len);
}
