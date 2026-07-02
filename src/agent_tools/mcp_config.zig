//! Native Copilot tool `mcp_config`: let the model list and configure MCP
//! servers — the same `mcp.json` the MCP Servers panel edits. Every mutation is
//! written to `mcp.json` and the runtime tool cache is reloaded, so it takes
//! effect without a restart (mirrors the panel's auto-save).
//!
//! The read-modify-write "core ops" (`listText`/`addServer`/`removeServer`/
//! `setEnabled`) take a plain allocator so they're unit-testable against a temp
//! config dir; `run` wraps them with argument parsing, the approval gate, and
//! the cache reload.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const mcp_registry = @import("../tools/mcp_registry.zig");
const tool_args = @import("args.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;
const ServerConfig = mcp_registry.ServerConfig;

/// Human-readable listing of the configured servers (read-only).
pub fn listText(allocator: std.mem.Allocator) ![]u8 {
    const servers = try mcp_registry.loadConfigFile(allocator);
    defer mcp_registry.freeServersConfig(allocator, servers);
    if (servers.len == 0) {
        return allocator.dupe(u8, "No MCP servers configured yet. Use action=add to add one.");
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "{d} MCP server(s) in mcp.json:\n", .{servers.len});
    for (servers) |s| {
        try out.print(allocator, "- {s} [{s}]: {s}", .{ s.name, if (s.enabled) "enabled" else "disabled", s.command });
        for (s.args) |a| try out.print(allocator, " {s}", .{a});
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// Add a server, or replace an existing one with the same name. Returns a
/// human-readable confirmation. Does NOT reload the cache (see `run`).
pub fn addServer(allocator: std.mem.Allocator, name: []const u8, command: []const u8, args: []const []const u8, enabled: bool) ![]u8 {
    const servers = try mcp_registry.loadConfigFile(allocator);
    defer mcp_registry.freeServersConfig(allocator, servers);

    var list: std.ArrayListUnmanaged(ServerConfig) = .empty;
    defer list.deinit(allocator);
    var replaced = false;
    for (servers) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            replaced = true;
            continue; // re-added below with the new values
        }
        try list.append(allocator, s);
    }
    // Borrow the caller's arg strings for the duration of the save (save only
    // reads them); ServerConfig wants []u8, the args are []const u8.
    var argv = try allocator.alloc([]u8, args.len);
    defer allocator.free(argv);
    for (args, 0..) |a, i| argv[i] = @constCast(a);
    try list.append(allocator, .{ .name = @constCast(name), .command = @constCast(command), .args = argv, .enabled = enabled });

    try mcp_registry.saveConfigFile(allocator, list.items);
    return std.fmt.allocPrint(allocator, "{s} MCP server \"{s}\" ({s}).", .{ if (replaced) "Updated" else "Added", name, if (enabled) "enabled" else "disabled" });
}

/// Remove a server by name. Returns a message noting whether it existed.
pub fn removeServer(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const servers = try mcp_registry.loadConfigFile(allocator);
    defer mcp_registry.freeServersConfig(allocator, servers);

    var list: std.ArrayListUnmanaged(ServerConfig) = .empty;
    defer list.deinit(allocator);
    var found = false;
    for (servers) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            found = true;
            continue;
        }
        try list.append(allocator, s);
    }
    if (!found) return std.fmt.allocPrint(allocator, "No MCP server named \"{s}\".", .{name});
    try mcp_registry.saveConfigFile(allocator, list.items);
    return std.fmt.allocPrint(allocator, "Removed MCP server \"{s}\".", .{name});
}

/// Enable or disable an existing server by name.
pub fn setEnabled(allocator: std.mem.Allocator, name: []const u8, enabled: bool) ![]u8 {
    const servers = try mcp_registry.loadConfigFile(allocator);
    defer mcp_registry.freeServersConfig(allocator, servers);

    var found = false;
    for (servers) |*s| {
        if (std.mem.eql(u8, s.name, name)) {
            s.enabled = enabled;
            found = true;
        }
    }
    if (!found) return std.fmt.allocPrint(allocator, "No MCP server named \"{s}\".", .{name});
    try mcp_registry.saveConfigFile(allocator, servers);
    return std.fmt.allocPrint(allocator, "{s} MCP server \"{s}\".", .{ if (enabled) "Enabled" else "Disabled", name });
}

/// Parse the `args` field as either a JSON array of strings or a single
/// whitespace-separated string (models pass it both ways). Caller frees with
/// `tool_args.freeStringArray`.
fn parseArgsOwned(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value == .object) {
        if (value.object.get("args")) |av| {
            switch (av) {
                .array => return tool_args.stringArray(allocator, value, "args"),
                .string => {
                    var list: std.ArrayListUnmanaged([]const u8) = .empty;
                    errdefer {
                        for (list.items) |s| allocator.free(s);
                        list.deinit(allocator);
                    }
                    var it = std.mem.tokenizeAny(u8, av.string, " \t");
                    while (it.next()) |tok| try list.append(allocator, try allocator.dupe(u8, tok));
                    return list.toOwnedSlice(allocator);
                },
                else => {},
            }
        }
    }
    return allocator.alloc([]const u8, 0);
}

fn approve(ctx: *ToolContext, action: []const u8, name: []const u8) bool {
    switch (ctx.settings.permission) {
        .full => return true,
        .confirm, .auto => {},
    }
    var buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "mcp_config {s} {s}", .{ action, name }) catch "mcp_config change";
    return ctx.requestApproval("mcp_config", summary, "Change MCP server configuration");
}

fn errText(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "MCP config error: {s}", .{@errorName(err)});
}

/// Tool entrypoint. `list` is read-only; `add`/`remove`/`enable`/`disable`
/// require approval, then apply the change and reload the MCP tool cache.
pub fn run(ctx: *ToolContext, arguments_json: []const u8) ![]u8 {
    var parsed = tool_args.parse(ctx.allocator, arguments_json) orelse
        return ctx.allocator.dupe(u8, "Invalid tool arguments.");
    defer parsed.deinit();
    const value = parsed.value;
    const action = tool_args.string(value, "action") orelse "list";

    if (std.mem.eql(u8, action, "list")) return listText(ctx.allocator);

    if (std.mem.eql(u8, action, "add")) {
        const name = tool_args.string(value, "name") orelse return ctx.allocator.dupe(u8, "add requires a \"name\".");
        const command = tool_args.string(value, "command") orelse return ctx.allocator.dupe(u8, "add requires a \"command\".");
        const enabled = tool_args.boolean(value, "enabled") orelse true;
        const argv = try parseArgsOwned(ctx.allocator, value);
        defer tool_args.freeStringArray(ctx.allocator, argv);
        if (!approve(ctx, "add", name)) return tool_output.deniedResult(ctx.allocator, name, "operator denied MCP config change");
        const msg = addServer(ctx.allocator, name, command, argv, enabled) catch |err| return errText(ctx.allocator, err);
        mcp_registry.reloadCache(ctx.allocator);
        return msg;
    }

    if (std.mem.eql(u8, action, "remove")) {
        const name = tool_args.string(value, "name") orelse return ctx.allocator.dupe(u8, "remove requires a \"name\".");
        if (!approve(ctx, "remove", name)) return tool_output.deniedResult(ctx.allocator, name, "operator denied MCP config change");
        const msg = removeServer(ctx.allocator, name) catch |err| return errText(ctx.allocator, err);
        mcp_registry.reloadCache(ctx.allocator);
        return msg;
    }

    const set_enable = std.mem.eql(u8, action, "enable");
    const set_disable = std.mem.eql(u8, action, "disable");
    if (set_enable or set_disable) {
        const name = tool_args.string(value, "name") orelse return ctx.allocator.dupe(u8, "enable/disable requires a \"name\".");
        if (!approve(ctx, action, name)) return tool_output.deniedResult(ctx.allocator, name, "operator denied MCP config change");
        const msg = setEnabled(ctx.allocator, name, set_enable) catch |err| return errText(ctx.allocator, err);
        mcp_registry.reloadCache(ctx.allocator);
        return msg;
    }

    return std.fmt.allocPrint(ctx.allocator, "Unknown action \"{s}\". Use: list, add, remove, enable, disable.", .{action});
}

// --- tests: core ops against a temp config dir (no ToolContext needed) -------

const dirs = @import("../platform/dirs.zig");

fn setupTempConfig(a: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    dirs.setTestConfigDirOverride(dir_path);
    return dir_path;
}

test "addServer writes a new server, then listText shows it" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try setupTempConfig(a, &tmp);
    defer a.free(dir_path);
    defer dirs.setTestConfigDirOverride(null);

    const args = [_][]const u8{ "-y", "mcp-remote", "https://mcp.jina.ai/v1" };
    const msg = try addServer(a, "jina", "npx", args[0..], true);
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Added") != null);

    const listing = try listText(a);
    defer a.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "jina") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "mcp-remote") != null);
}

test "addServer with an existing name replaces it" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try setupTempConfig(a, &tmp);
    defer a.free(dir_path);
    defer dirs.setTestConfigDirOverride(null);

    const empty = [_][]const u8{};
    const first = try addServer(a, "s", "old-cmd", empty[0..], true);
    a.free(first);
    const second = try addServer(a, "s", "new-cmd", empty[0..], true);
    defer a.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "Updated") != null);

    const loaded = try mcp_registry.loadConfigFile(a);
    defer mcp_registry.freeServersConfig(a, loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("new-cmd", loaded[0].command);
}

test "setEnabled persists the disabled flag; removeServer deletes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try setupTempConfig(a, &tmp);
    defer a.free(dir_path);
    defer dirs.setTestConfigDirOverride(null);

    const empty = [_][]const u8{};
    a.free(try addServer(a, "s", "cmd", empty[0..], true));

    const dis = try setEnabled(a, "s", false);
    defer a.free(dis);
    try std.testing.expect(std.mem.indexOf(u8, dis, "Disabled") != null);
    {
        const loaded = try mcp_registry.loadConfigFile(a);
        defer mcp_registry.freeServersConfig(a, loaded);
        try std.testing.expect(!loaded[0].enabled);
    }

    const missing = try setEnabled(a, "nope", true);
    defer a.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "No MCP server") != null);

    const rm = try removeServer(a, "s");
    defer a.free(rm);
    try std.testing.expect(std.mem.indexOf(u8, rm, "Removed") != null);
    const loaded2 = try mcp_registry.loadConfigFile(a);
    defer mcp_registry.freeServersConfig(a, loaded2);
    try std.testing.expectEqual(@as(usize, 0), loaded2.len);
}

test "listText reports empty config" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try setupTempConfig(a, &tmp);
    defer a.free(dir_path);
    defer dirs.setTestConfigDirOverride(null);

    const listing = try listText(a);
    defer a.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "No MCP servers") != null);
}

test "parseArgsOwned accepts a JSON array or a space-separated string" {
    const a = std.testing.allocator;
    var arr = tool_args.parse(a, "{\"args\":[\"-y\",\"pkg\"]}").?;
    defer arr.deinit();
    const from_arr = try parseArgsOwned(a, arr.value);
    defer tool_args.freeStringArray(a, from_arr);
    try std.testing.expectEqual(@as(usize, 2), from_arr.len);
    try std.testing.expectEqualStrings("pkg", from_arr[1]);

    var str = tool_args.parse(a, "{\"args\":\"-y mcp-remote https://x\"}").?;
    defer str.deinit();
    const from_str = try parseArgsOwned(a, str.value);
    defer tool_args.freeStringArray(a, from_str);
    try std.testing.expectEqual(@as(usize, 3), from_str.len);
    try std.testing.expectEqualStrings("mcp-remote", from_str[1]);
}
