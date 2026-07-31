//! Async MCP server "probe": run the real initialize + tools/list handshake
//! against a configured MCP server and report the discovered tool names. Used
//! by the in-app "Test" button on an MCP server config so the check reflects
//! the actual server, not just argv validation.
//!
//! Mirrors `assistant/quick_verify.zig`'s threading shape: `probeBlocking` is
//! the pure, synchronous, unit-testable core; `start` is a thin thread
//! wrapper that never touches UI state directly (it hands the result to an
//! injected `done` callback).
const std = @import("std");
const builtin = @import("builtin");
const mcp_client = @import("../agent_tools/mcp_client.zig");
const mcp_catalog = @import("../tools/mcp_catalog.zig");
const mcp_registry = @import("../tools/mcp_registry.zig");
const ai_chat_protocol = @import("conversation/protocol.zig");
const platform_dirs = @import("../platform/dirs.zig");

const log = std.log.scoped(.mcp);

const max_tools = 24;
const tool_name_len = 64;

/// Fixed-buffer probe outcome — owns nothing on the heap so callers (UI
/// overlays) can copy/store it freely without a matching free.
pub const Result = struct {
    ok: bool,
    message: [256]u8,
    message_len: usize,
    tools: [max_tools][tool_name_len]u8,
    tool_count: usize,
};

fn emptyResult() Result {
    return .{
        .ok = false,
        .message = [_]u8{0} ** 256,
        .message_len = 0,
        .tools = [_][tool_name_len]u8{[_]u8{0} ** tool_name_len} ** max_tools,
        .tool_count = 0,
    };
}

fn setMessage(result: *Result, msg: []const u8) void {
    const n = @min(msg.len, result.message.len);
    @memcpy(result.message[0..n], msg[0..n]);
    result.message_len = n;
}

fn setError(result: *Result, err: anyerror) void {
    result.ok = false;
    setMessage(result, @errorName(err));
}

/// Run the real `initialize` + `tools/list` handshake against `command` and
/// report the discovered tool names. Pure, synchronous, unit-testable — the
/// thread wrapper is `start`.
pub fn probeBlocking(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8, catalog_name: ?[]const u8) Result {
    var result = emptyResult();

    const argv = allocator.alloc([]const u8, args.len + 1) catch |err| {
        setError(&result, err);
        return result;
    };
    defer allocator.free(argv);
    argv[0] = command;
    for (args, 0..) |arg, i| argv[i + 1] = arg;

    var conn = mcp_client.Connection.spawn(allocator, argv) catch |err| {
        log.warn("mcp probe: spawn failed for {s}: {s}", .{ command, @errorName(err) });
        setError(&result, err);
        return result;
    };
    defer conn.deinit();

    conn.initialize() catch |err| {
        log.warn("mcp probe: initialize failed for {s}: {s}", .{ command, @errorName(err) });
        setError(&result, err);
        return result;
    };

    const tools = conn.listTools() catch |err| {
        log.warn("mcp probe: tools/list failed for {s}: {s}", .{ command, @errorName(err) });
        setError(&result, err);
        return result;
    };
    defer mcp_client.freeToolDefs(allocator, tools);

    const n = @min(tools.len, max_tools);
    for (tools[0..n], 0..) |tool, i| {
        const copy_len = @min(tool.name.len, tool_name_len);
        @memcpy(result.tools[i][0..copy_len], tool.name[0..copy_len]);
    }

    if (catalog_name) |cname| {
        if (cname.len > 0) {
            writeCatalog(allocator, cname, command, args, tools) catch |err|
                log.warn("mcp probe: catalog write for '{s}' failed: {s}", .{ cname, @errorName(err) });
        }
    }

    result.tool_count = n;
    result.ok = true;
    return result;
}

/// Persist a successful probe's full tool listing so the registry can build
/// the catalog without spawning this server again.
fn writeCatalog(
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []const u8,
    args: []const []const u8,
    defs: []const mcp_client.ToolDef,
) !void {
    const specs = try allocator.alloc(ai_chat_protocol.McpToolSpec, defs.len);
    var filled: usize = 0;
    defer {
        for (specs[0..filled]) |s| allocator.free(s.properties_json);
        allocator.free(specs);
    }
    for (defs) |def| {
        const props = try mcp_registry.mcpPropertiesFromSchema(allocator, def.input_schema_json);
        specs[filled] = .{ .name = def.name, .description = def.description, .properties_json = props };
        filled += 1;
    }
    try mcp_catalog.upsertServer(allocator, name, mcp_catalog.configHash(command, args), std.time.timestamp(), specs[0..filled]);
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    command: []u8,
    args_buf: [][]u8,
    args: [][]const u8,
    catalog_name: ?[]u8,
    done: *const fn (*anyopaque, Result) void,
    ctx: *anyopaque,
};

fn worker(ctx: *Ctx) void {
    defer {
        ctx.allocator.free(ctx.command);
        for (ctx.args_buf) |a| ctx.allocator.free(a);
        ctx.allocator.free(ctx.args_buf);
        ctx.allocator.free(ctx.args);
        if (ctx.catalog_name) |n| ctx.allocator.free(n);
        ctx.allocator.destroy(ctx);
    }
    const result = probeBlocking(ctx.allocator, ctx.command, ctx.args, ctx.catalog_name);
    ctx.done(ctx.ctx, result);
}

/// Spawn a background thread that runs `probeBlocking(command, args)` and
/// hands the result to `done(ctx, result)` on completion. `command`/`args`
/// are copied onto the heap before the thread starts, so the caller's
/// buffers (e.g. overlay-local slices) may be freed or reused immediately
/// after this call returns.
pub fn start(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8, catalog_name: ?[]const u8, done: *const fn (*anyopaque, Result) void, ctx: *anyopaque) void {
    const command_copy = allocator.dupe(u8, command) catch {
        var result = emptyResult();
        setMessage(&result, "OutOfMemory");
        done(ctx, result);
        return;
    };
    const args_buf = allocator.alloc([]u8, args.len) catch {
        allocator.free(command_copy);
        var result = emptyResult();
        setMessage(&result, "OutOfMemory");
        done(ctx, result);
        return;
    };
    var filled: usize = 0;
    for (args, 0..) |arg, i| {
        args_buf[i] = allocator.dupe(u8, arg) catch {
            for (args_buf[0..filled]) |a| allocator.free(a);
            allocator.free(args_buf);
            allocator.free(command_copy);
            var result = emptyResult();
            setMessage(&result, "OutOfMemory");
            done(ctx, result);
            return;
        };
        filled += 1;
    }
    const args_view = allocator.alloc([]const u8, args.len) catch {
        for (args_buf) |a| allocator.free(a);
        allocator.free(args_buf);
        allocator.free(command_copy);
        var result = emptyResult();
        setMessage(&result, "OutOfMemory");
        done(ctx, result);
        return;
    };
    for (args_buf, 0..) |a, i| args_view[i] = a;

    const catalog_name_copy: ?[]u8 = if (catalog_name) |n| allocator.dupe(u8, n) catch {
        allocator.free(args_view);
        for (args_buf) |a| allocator.free(a);
        allocator.free(args_buf);
        allocator.free(command_copy);
        var result = emptyResult();
        setMessage(&result, "OutOfMemory");
        done(ctx, result);
        return;
    } else null;

    const worker_ctx = allocator.create(Ctx) catch {
        if (catalog_name_copy) |n| allocator.free(n);
        allocator.free(args_view);
        for (args_buf) |a| allocator.free(a);
        allocator.free(args_buf);
        allocator.free(command_copy);
        var result = emptyResult();
        setMessage(&result, "OutOfMemory");
        done(ctx, result);
        return;
    };
    worker_ctx.* = .{
        .allocator = allocator,
        .command = command_copy,
        .args_buf = args_buf,
        .args = args_view,
        .catalog_name = catalog_name_copy,
        .done = done,
        .ctx = ctx,
    };

    const thread = std.Thread.spawn(.{}, worker, .{worker_ctx}) catch {
        if (catalog_name_copy) |n| allocator.free(n);
        allocator.destroy(worker_ctx);
        allocator.free(args_view);
        for (args_buf) |a| allocator.free(a);
        allocator.free(args_buf);
        allocator.free(command_copy);
        var result = emptyResult();
        setMessage(&result, "OutOfMemory");
        done(ctx, result);
        return;
    };
    thread.detach();
}

test "probeBlocking returns discovered tool names against a real server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"f\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"e\",\"inputSchema\":{\"type\":\"object\"}},{\"name\":\"add\",\"description\":\"a\",\"inputSchema\":{\"type\":\"object\"}}]}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "'; exec cat >/dev/null";
    var args = [_][]const u8{ "-c", script };
    const r = probeBlocking(a, "/bin/sh", args[0..], null);
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(usize, 2), r.tool_count);
    try std.testing.expectEqualStrings("echo", r.tools[0][0..4]);
}

test "probeBlocking reports failure for a server that cannot handshake" {
    const a = std.testing.allocator;
    var args = [_][]const u8{"--no"};
    const r = probeBlocking(a, "/bin/false", args[0..], null);
    try std.testing.expect(!r.ok);
    try std.testing.expect(r.message_len > 0);
}

test "probeBlocking with catalog_name writes the disk catalog" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"f\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"e\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"t\":{\"type\":\"string\"}}}}]}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "'; exec cat >/dev/null";
    var args = [_][]const u8{ "-c", script };

    const r = probeBlocking(a, "/bin/sh", args[0..], "probed");
    try std.testing.expect(r.ok);

    var cat = mcp_catalog.load(a);
    defer cat.deinit(a);
    const entry = cat.find("probed").?;
    try std.testing.expectEqual(mcp_catalog.configHash("/bin/sh", args[0..]), entry.config_hash);
    try std.testing.expectEqual(@as(usize, 1), entry.tools.len);
    try std.testing.expectEqualStrings("{\"t\":{\"type\":\"string\"}}", entry.tools[0].properties_json);
}
