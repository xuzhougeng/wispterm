//! MCP server discovery: read the MCP server config, run tools/list against
//! each configured server, and project the results into the two shapes the AI
//! session needs — McpToolSpec (advertise to the model) and McpTool (dispatch
//! target). Mirrors tool_registry's dynamicSpecs/dynamicRuntime split.
//!
//! The config-parse + schema-extract helpers below are std-only; `discover`
//! additionally pulls the MCP client + tool-spec types, so the whole module is
//! exercised via the fast suite (`zig build test`).
const std = @import("std");
const builtin = @import("builtin");
const mcp_client = @import("../agent_tools/mcp_client.zig");
const ai_chat_protocol = @import("../assistant/conversation/protocol.zig");
const ai_chat_types = @import("../assistant/conversation/types.zig");
const platform_dirs = @import("../platform/dirs.zig");
const atomic_file = @import("../platform/atomic_file.zig");
const mcp_catalog = @import("mcp_catalog.zig");

const McpToolSpec = ai_chat_protocol.McpToolSpec;
const McpTool = ai_chat_types.McpTool;

/// Diagnostic scope for MCP. Visible in `-Ddebug-console` builds
/// (<config-dir>/wispterm-debug.log); filter with `(mcp)`.
const log = std.log.scoped(.mcp);

const MAX_MCP_CONFIG_BYTES: usize = 256 * 1024;

/// One configured MCP server. All fields owned.
pub const ServerConfig = struct {
    name: []u8,
    command: []u8,
    args: [][]u8,
    enabled: bool,
};

fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

fn freeServerConfig(allocator: std.mem.Allocator, s: ServerConfig) void {
    allocator.free(s.name);
    allocator.free(s.command);
    freeStringList(allocator, s.args);
}

pub fn freeServersConfig(allocator: std.mem.Allocator, servers: []ServerConfig) void {
    for (servers) |s| freeServerConfig(allocator, s);
    allocator.free(servers);
}

fn dupeStringArray(allocator: std.mem.Allocator, maybe_val: ?std.json.Value) ![][]u8 {
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    if (maybe_val) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                if (item != .string) continue;
                try list.append(allocator, try allocator.dupe(u8, item.string));
            }
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Parse `{"mcpServers":{"<name>":{"command":..,"args":[..],"enabled":bool}}}`
/// (the de-facto ecosystem format). `enabled` defaults true; a server with no
/// string `command` is skipped. Order follows the JSON object. Malformed → [].
pub fn parseServersConfig(allocator: std.mem.Allocator, json: []const u8) ![]ServerConfig {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return allocator.alloc(ServerConfig, 0);
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.alloc(ServerConfig, 0);
    const servers_val = parsed.value.object.get("mcpServers") orelse return allocator.alloc(ServerConfig, 0);
    if (servers_val != .object) return allocator.alloc(ServerConfig, 0);

    var list: std.ArrayListUnmanaged(ServerConfig) = .empty;
    errdefer {
        for (list.items) |s| freeServerConfig(allocator, s);
        list.deinit(allocator);
    }

    var it = servers_val.object.iterator();
    while (it.next()) |entry| {
        const spec = entry.value_ptr.*;
        if (spec != .object) continue;
        const command_v = spec.object.get("command") orelse continue;
        if (command_v != .string) continue;

        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const command = try allocator.dupe(u8, command_v.string);
        errdefer allocator.free(command);
        const enabled = if (spec.object.get("enabled")) |e| (if (e == .bool) e.bool else true) else true;
        const args = try dupeStringArray(allocator, spec.object.get("args"));
        errdefer freeStringList(allocator, args);

        try list.append(allocator, .{ .name = name, .command = command, .args = args, .enabled = enabled });
    }
    return list.toOwnedSlice(allocator);
}

test "parseServersConfig reads command, args and the enabled flag in order" {
    const a = std.testing.allocator;
    const json =
        \\{"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]},"off":{"command":"foo","enabled":false}}}
    ;
    const servers = try parseServersConfig(a, json);
    defer freeServersConfig(a, servers);
    try std.testing.expectEqual(@as(usize, 2), servers.len);
    try std.testing.expectEqualStrings("context7", servers[0].name);
    try std.testing.expectEqualStrings("npx", servers[0].command);
    try std.testing.expectEqual(@as(usize, 2), servers[0].args.len);
    try std.testing.expectEqualStrings("-y", servers[0].args[0]);
    try std.testing.expect(servers[0].enabled);
    try std.testing.expectEqualStrings("off", servers[1].name);
    try std.testing.expect(!servers[1].enabled);
    try std.testing.expectEqual(@as(usize, 0), servers[1].args.len);
}

/// Serialize `servers` back to `{"mcpServers":{...}}` text (owned, ends in
/// `\n`). Inverse of `parseServersConfig`: a disabled server gets an explicit
/// `"enabled":false`; enabled is the default so it's omitted.
pub fn writeServersConfig(allocator: std.mem.Allocator, servers: []const ServerConfig) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = std.json.ObjectMap.init(aa);
    var servers_obj = std.json.ObjectMap.init(aa);
    for (servers) |s| {
        var entry = std.json.ObjectMap.init(aa);
        try entry.put("command", .{ .string = s.command });
        var arr = std.json.Array.init(aa);
        for (s.args) |arg| try arr.append(.{ .string = arg });
        try entry.put("args", .{ .array = arr });
        if (!s.enabled) try entry.put("enabled", .{ .bool = false });
        try servers_obj.put(s.name, .{ .object = entry });
    }
    try root.put("mcpServers", .{ .object = servers_obj });

    const body = try std.json.Stringify.valueAlloc(aa, std.json.Value{ .object = root }, .{});
    return std.fmt.allocPrint(allocator, "{s}\n", .{body});
}

test "parseServersConfig returns empty for a missing key or malformed json" {
    const a = std.testing.allocator;
    const empty = try parseServersConfig(a, "{}");
    defer freeServersConfig(a, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const bad = try parseServersConfig(a, "not json");
    defer freeServersConfig(a, bad);
    try std.testing.expectEqual(@as(usize, 0), bad.len);
}

test "writeServersConfig round-trips through parseServersConfig" {
    const a = std.testing.allocator;
    var args0 = [_][]u8{ @constCast("-y"), @constCast("pkg") };
    const servers = [_]ServerConfig{
        .{ .name = @constCast("ctx7"), .command = @constCast("npx"), .args = args0[0..], .enabled = true },
        .{ .name = @constCast("off"), .command = @constCast("foo"), .args = &.{}, .enabled = false },
    };
    const json = try writeServersConfig(a, servers[0..]);
    defer a.free(json);
    // enabled:true omitted, false emitted
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":true") == null);
    // parse it back
    const back = try parseServersConfig(a, json);
    defer freeServersConfig(a, back);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("ctx7", back[0].name);
    try std.testing.expectEqualStrings("npx", back[0].command);
    try std.testing.expectEqual(@as(usize, 2), back[0].args.len);
    try std.testing.expect(back[0].enabled);
    try std.testing.expect(!back[1].enabled);
}

test "writeServersConfig with no servers is an empty mcpServers object" {
    const a = std.testing.allocator;
    const json = try writeServersConfig(a, &.{});
    defer a.free(json);
    const back = try parseServersConfig(a, json);
    defer freeServersConfig(a, back);
    try std.testing.expectEqual(@as(usize, 0), back.len);
}

/// Read `<config-dir>/mcp.json`. A missing (or unreadable) file is not an
/// error — it means no servers are configured yet.
pub fn loadConfigFile(allocator: std.mem.Allocator) ![]ServerConfig {
    const path = try platform_dirs.pathInConfigDir(allocator, "mcp.json");
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_MCP_CONFIG_BYTES) catch
        return allocator.alloc(ServerConfig, 0);
    defer allocator.free(bytes);
    return parseServersConfig(allocator, bytes);
}

/// Serialize `servers` and atomically replace `<config-dir>/mcp.json`.
pub fn saveConfigFile(allocator: std.mem.Allocator, servers: []const ServerConfig) !void {
    const path = try platform_dirs.pathInConfigDir(allocator, "mcp.json");
    defer allocator.free(path);
    const json = try writeServersConfig(allocator, servers);
    defer allocator.free(json);
    try atomic_file.writeFileReplaceSafe(path, json);
    mcp_catalog.bumpGeneration();
}

/// Absolute path to the MCP config file (`<config-dir>/mcp.json`). Owned.
pub fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.pathInConfigDir(allocator, "mcp.json");
}

const CONFIG_TEMPLATE =
    \\{
    \\  "mcpServers": {
    \\    "example": {
    \\      "command": "npx",
    \\      "args": ["-y", "@upstash/context7-mcp"],
    \\      "enabled": false
    \\    }
    \\  }
    \\}
    \\
;

/// Create `<config-dir>/mcp.json` with a starter template if it doesn't exist,
/// so "open in editor" always has a valid, illustrative file to show. An
/// existing file is left untouched.
pub fn ensureConfigFile(allocator: std.mem.Allocator) !void {
    const path = try configPath(allocator);
    defer allocator.free(path);
    if (std.fs.cwd().access(path, .{})) |_| {
        return; // already there — never clobber the user's file
    } else |_| {}
    const dir = try platform_dirs.configDir(allocator);
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    try atomic_file.writeFileReplaceSafe(path, CONFIG_TEMPLATE);
}

test "saveConfigFile then loadConfigFile round-trips via the config dir" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    var args0 = [_][]u8{@constCast("--stdio")};
    const servers = [_]ServerConfig{.{ .name = @constCast("gh"), .command = @constCast("github-mcp"), .args = args0[0..], .enabled = true }};
    try saveConfigFile(a, servers[0..]);

    const back = try loadConfigFile(a);
    defer freeServersConfig(a, back);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("gh", back[0].name);
    try std.testing.expectEqualStrings("github-mcp", back[0].command);
}

test "ensureConfigFile writes a valid template only when absent" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    // Absent → writes a parseable template (with the disabled example server).
    try ensureConfigFile(a);
    const first = try loadConfigFile(a);
    defer freeServersConfig(a, first);
    try std.testing.expect(first.len >= 1);

    // Present → left untouched (overwrite with empty, ensure it survives).
    const path = try configPath(a);
    defer a.free(path);
    try atomic_file.writeFileReplaceSafe(path, "{\"mcpServers\":{}}\n");
    try ensureConfigFile(a);
    const second = try loadConfigFile(a);
    defer freeServersConfig(a, second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "loadConfigFile returns empty when the file is absent" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const back = try loadConfigFile(a);
    defer freeServersConfig(a, back);
    try std.testing.expectEqual(@as(usize, 0), back.len);
}

/// Extract the inner `properties` map from a full JSON-Schema `inputSchema`,
/// re-serialized. The tool-schema emitter wraps this in `{"type":"object",
/// "properties": ...}`, so we hand it just the map. Missing/malformed → `{}`.
pub fn mcpPropertiesFromSchema(allocator: std.mem.Allocator, schema_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{}) catch return allocator.dupe(u8, "{}");
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "{}");
    const props = parsed.value.object.get("properties") orelse return allocator.dupe(u8, "{}");
    if (props != .object) return allocator.dupe(u8, "{}");
    return std.json.Stringify.valueAlloc(allocator, props, .{});
}

test "mcpPropertiesFromSchema extracts the inner properties map" {
    const a = std.testing.allocator;
    const out = try mcpPropertiesFromSchema(a, "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\"}},\"required\":[\"x\"]}");
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"x\":{\"type\":\"integer\"}}", out);
}

test "mcpPropertiesFromSchema defaults to an empty object when absent or malformed" {
    const a = std.testing.allocator;
    const noprops = try mcpPropertiesFromSchema(a, "{\"type\":\"object\"}");
    defer a.free(noprops);
    try std.testing.expectEqualStrings("{}", noprops);
    const bad = try mcpPropertiesFromSchema(a, "not json");
    defer a.free(bad);
    try std.testing.expectEqualStrings("{}", bad);
}

// ---------------------------------------------------------------------------
// Discovery — spawn each server, tools/list, project into the two shapes.
// ---------------------------------------------------------------------------

/// Discovered tools in the two shapes the AI session consumes: `specs` to
/// advertise to the model, `tools` to dispatch a call back to its server.
pub const Snapshots = struct {
    specs: []McpToolSpec,
    tools: []McpTool,
};

fn freeSpecItems(allocator: std.mem.Allocator, items: []const McpToolSpec) void {
    for (items) |s| {
        allocator.free(s.name);
        allocator.free(s.description);
        allocator.free(s.properties_json);
    }
}

fn freeConstStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

fn freeToolItems(allocator: std.mem.Allocator, items: []const McpTool) void {
    for (items) |t| {
        allocator.free(t.function_name);
        allocator.free(t.description);
        allocator.free(t.server_command);
        freeConstStringList(allocator, t.server_args);
    }
}

pub fn freeSnapshots(allocator: std.mem.Allocator, snap: Snapshots) void {
    freeSpecItems(allocator, snap.specs);
    allocator.free(snap.specs);
    freeToolItems(allocator, snap.tools);
    allocator.free(snap.tools);
}

fn dupeStringList(allocator: std.mem.Allocator, src: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, src.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (src) |s| {
        out[n] = try allocator.dupe(u8, s);
        n += 1;
    }
    return out;
}

/// Spawn each enabled server, run initialize + tools/list, and project the
/// tools. A server that fails to start/handshake/list is skipped (not fatal).
/// ponytail: discovery spawns every server once here; the returned snapshots
/// are cached by the caller. Per-server errors are swallowed — surface them to
/// an MCP status panel when one exists.
pub fn discover(allocator: std.mem.Allocator, servers: []const ServerConfig) !Snapshots {
    var specs: std.ArrayListUnmanaged(McpToolSpec) = .empty;
    var tools: std.ArrayListUnmanaged(McpTool) = .empty;
    errdefer {
        freeSpecItems(allocator, specs.items);
        specs.deinit(allocator);
        freeToolItems(allocator, tools.items);
        tools.deinit(allocator);
    }

    for (servers) |server| {
        if (!server.enabled) continue;

        const argv = try allocator.alloc([]const u8, server.args.len + 1);
        defer allocator.free(argv);
        argv[0] = server.command;
        for (server.args, 0..) |arg, i| argv[i + 1] = arg;

        var conn = mcp_client.Connection.spawn(allocator, argv) catch |err| {
            log.warn("server '{s}' failed to start ({s}): {s}", .{ server.name, server.command, @errorName(err) });
            continue;
        };
        defer conn.deinit();
        conn.initialize() catch |err| {
            log.warn("server '{s}' initialize failed: {s}", .{ server.name, @errorName(err) });
            continue;
        };
        const defs = conn.listTools() catch |err| {
            log.warn("server '{s}' tools/list failed: {s}", .{ server.name, @errorName(err) });
            continue;
        };
        defer mcp_client.freeToolDefs(allocator, defs);
        log.info("server '{s}': discovered {d} tool(s)", .{ server.name, defs.len });

        for (defs) |def| {
            if (ai_chat_protocol.builtinToolNameReserved(def.name)) {
                log.warn("server '{s}': tool '{s}' shadows a builtin — skipped", .{ server.name, def.name });
                continue;
            }

            const props = try mcpPropertiesFromSchema(allocator, def.input_schema_json);
            errdefer allocator.free(props);
            const spec_name = try allocator.dupe(u8, def.name);
            errdefer allocator.free(spec_name);
            const spec_desc = try allocator.dupe(u8, def.description);
            errdefer allocator.free(spec_desc);
            try specs.append(allocator, .{ .name = spec_name, .description = spec_desc, .properties_json = props });

            const t_name = try allocator.dupe(u8, def.name);
            errdefer allocator.free(t_name);
            const t_desc = try allocator.dupe(u8, def.description);
            errdefer allocator.free(t_desc);
            const t_cmd = try allocator.dupe(u8, server.command);
            errdefer allocator.free(t_cmd);
            const t_args = try dupeStringList(allocator, server.args);
            errdefer freeStringList(allocator, t_args);
            try tools.append(allocator, .{
                .function_name = t_name,
                .description = t_desc,
                .server_command = t_cmd,
                .server_args = t_args,
            });
        }
    }

    return .{
        .specs = try specs.toOwnedSlice(allocator),
        .tools = try tools.toOwnedSlice(allocator),
    };
}

test "discover projects a server's tools into advertise specs and dispatch tools" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"add\",\"description\":\"Add two ints\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\"}},\"required\":[\"x\"]}}]}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "'; exec cat >/dev/null";

    var args = [_][]u8{ @constCast("-c"), @constCast(script) };
    const servers = [_]ServerConfig{.{
        .name = @constCast("demo"),
        .command = @constCast("/bin/sh"),
        .args = args[0..],
        .enabled = true,
    }};

    const snap = try discover(a, servers[0..]);
    defer freeSnapshots(a, snap);

    try std.testing.expectEqual(@as(usize, 1), snap.specs.len);
    try std.testing.expectEqualStrings("add", snap.specs[0].name);
    try std.testing.expectEqualStrings("Add two ints", snap.specs[0].description);
    try std.testing.expectEqualStrings("{\"x\":{\"type\":\"integer\"}}", snap.specs[0].properties_json);

    try std.testing.expectEqual(@as(usize, 1), snap.tools.len);
    try std.testing.expectEqualStrings("add", snap.tools[0].function_name);
    try std.testing.expectEqualStrings("/bin/sh", snap.tools[0].server_command);
    try std.testing.expectEqual(@as(usize, 2), snap.tools[0].server_args.len);
    try std.testing.expectEqualStrings("-c", snap.tools[0].server_args[0]);
}

test "discover skips a disabled server" {
    const a = std.testing.allocator;
    const servers = [_]ServerConfig{.{
        .name = @constCast("off"),
        .command = @constCast("/bin/false"),
        .args = &.{},
        .enabled = false,
    }};
    const snap = try discover(a, servers[0..]);
    defer freeSnapshots(a, snap);
    try std.testing.expectEqual(@as(usize, 0), snap.specs.len);
    try std.testing.expectEqual(@as(usize, 0), snap.tools.len);
}

// ---------------------------------------------------------------------------
// Session-lifetime cache. Lives here (a feature-owned module) rather than as
// fresh top-level globals in the session monolith — see global_state_guard.
// ---------------------------------------------------------------------------

threadlocal var g_cache_specs: []McpToolSpec = &.{};
threadlocal var g_cache_specs_owned: bool = false;
threadlocal var g_cache_tools: []McpTool = &.{};
threadlocal var g_cache_tools_owned: bool = false;

pub const CachedServer = struct {
    name: []u8,
    discovered: bool,
    spec_off: usize,
    spec_len: usize,
};

threadlocal var g_cache_servers: []CachedServer = &.{};
threadlocal var g_cache_servers_owned: bool = false;
threadlocal var g_cache_seen_gen: u64 = 0;

/// Per-server grouping of the cached specs/tools (borrowed, same lifetime as
/// cachedSpecs). Order follows mcp.json; disabled servers are absent.
pub fn cachedServers() []const CachedServer {
    return g_cache_servers;
}

/// MCP tools to advertise to the model (borrowed; valid until the next reload).
pub fn cachedSpecs() []const McpToolSpec {
    return g_cache_specs;
}

/// MCP tools to dispatch a call back to (borrowed; valid until the next reload).
pub fn cachedTools() []const McpTool {
    return g_cache_tools;
}

fn freeCache(allocator: std.mem.Allocator) void {
    if (g_cache_specs_owned) {
        freeSpecItems(allocator, g_cache_specs);
        allocator.free(g_cache_specs);
        g_cache_specs = &.{};
        g_cache_specs_owned = false;
    }
    if (g_cache_tools_owned) {
        freeToolItems(allocator, g_cache_tools);
        allocator.free(g_cache_tools);
        g_cache_tools = &.{};
        g_cache_tools_owned = false;
    }
    if (g_cache_servers_owned) {
        for (g_cache_servers) |s| allocator.free(s.name);
        allocator.free(g_cache_servers);
        g_cache_servers = &.{};
        g_cache_servers_owned = false;
    }
}

// ---------------------------------------------------------------------------
// Activation: which servers' tool schemas are advertised to the model.
// ponytail: app-global (process lifetime), not per chat session — tools can't
// reach the Session object, and sharing activation across sessions is fine.
// Fixed-size name slots; server names longer than 64 bytes can't be activated.
// ---------------------------------------------------------------------------

const MAX_ACTIVATED = 32;
const MAX_ACT_NAME = 64;
var g_act_mutex: std.Thread.Mutex = .{};
var g_act_names: [MAX_ACTIVATED][MAX_ACT_NAME]u8 = undefined;
var g_act_lens: [MAX_ACTIVATED]usize = [_]usize{0} ** MAX_ACTIVATED;
var g_act_count: usize = 0;

/// Mark a server's tools as advertised. Idempotent. False when the slot table
/// is full or the name doesn't fit.
pub fn activateServer(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_ACT_NAME) return false;
    g_act_mutex.lock();
    defer g_act_mutex.unlock();
    for (0..g_act_count) |i| {
        if (std.mem.eql(u8, g_act_names[i][0..g_act_lens[i]], name)) return true;
    }
    if (g_act_count >= MAX_ACTIVATED) return false;
    @memcpy(g_act_names[g_act_count][0..name.len], name);
    g_act_lens[g_act_count] = name.len;
    g_act_count += 1;
    return true;
}

pub fn isActivated(name: []const u8) bool {
    g_act_mutex.lock();
    defer g_act_mutex.unlock();
    for (0..g_act_count) |i| {
        if (std.mem.eql(u8, g_act_names[i][0..g_act_lens[i]], name)) return true;
    }
    return false;
}

pub fn resetActivationForTest() void {
    g_act_mutex.lock();
    defer g_act_mutex.unlock();
    g_act_count = 0;
}

/// Owned deep copies of the specs belonging to ACTIVATED servers only — what a
/// request advertises. Caller frees each spec's three strings + the slice
/// (session's freeOwnedMcpToolSpecs shape).
pub fn cloneActivatedSpecs(allocator: std.mem.Allocator) ![]McpToolSpec {
    ensureCacheFresh(allocator);
    var out: std.ArrayListUnmanaged(McpToolSpec) = .empty;
    errdefer {
        freeSpecItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (g_cache_servers) |srv| {
        if (!isActivated(srv.name)) continue;
        for (g_cache_specs[srv.spec_off..][0..srv.spec_len]) |s| {
            const n = try allocator.dupe(u8, s.name);
            errdefer allocator.free(n);
            const d = try allocator.dupe(u8, s.description);
            errdefer allocator.free(d);
            const p = try allocator.dupe(u8, s.properties_json);
            errdefer allocator.free(p);
            try out.append(allocator, .{ .name = n, .description = d, .properties_json = p });
        }
    }
    return out.toOwnedSlice(allocator);
}

const DIGEST_MAX_TOOL_NAMES = 8;

/// System-prompt digest of the INACTIVE servers (the model's map of what it
/// can mcp_activate). Null when every configured server is already activated
/// (or none are configured).
pub fn inactiveDigest(allocator: std.mem.Allocator) !?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var listed: usize = 0;
    for (g_cache_servers) |srv| {
        if (isActivated(srv.name)) continue;
        if (listed == 0) {
            try out.appendSlice(allocator, "Inactive MCP servers — call mcp_activate with the server name before using their tools:\n");
        }
        if (srv.discovered) {
            try out.print(allocator, "- {s} ({d} tools): ", .{ srv.name, srv.spec_len });
            const n = @min(srv.spec_len, DIGEST_MAX_TOOL_NAMES);
            for (g_cache_specs[srv.spec_off..][0..n], 0..) |s, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, s.name);
            }
            if (srv.spec_len > DIGEST_MAX_TOOL_NAMES) try out.appendSlice(allocator, ", ...");
            try out.append(allocator, '\n');
        } else {
            try out.print(allocator, "- {s} (not discovered yet; mcp_activate connects to it and lists its tools)\n", .{srv.name});
        }
        listed += 1;
    }
    if (listed == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

const CatalogSnapshots = struct {
    snap: Snapshots,
    servers: []CachedServer,
};

/// Build the cache from mcp.json + the disk catalog. Spawns NOTHING — a
/// server without a valid (hash-matched) catalog entry appears with
/// discovered=false and zero tools until it is probed or activated.
fn loadSnapshotsFromCatalog(allocator: std.mem.Allocator) !CatalogSnapshots {
    const configs = try loadConfigFile(allocator);
    defer freeServersConfig(allocator, configs);
    var catalog = mcp_catalog.load(allocator);
    defer catalog.deinit(allocator);

    var specs: std.ArrayListUnmanaged(McpToolSpec) = .empty;
    var tools: std.ArrayListUnmanaged(McpTool) = .empty;
    var servers: std.ArrayListUnmanaged(CachedServer) = .empty;
    errdefer {
        freeSpecItems(allocator, specs.items);
        specs.deinit(allocator);
        freeToolItems(allocator, tools.items);
        tools.deinit(allocator);
        for (servers.items) |s| allocator.free(s.name);
        servers.deinit(allocator);
    }

    for (configs) |server| {
        if (!server.enabled) continue;
        const hash = mcp_catalog.configHash(server.command, server.args);
        const entry = catalog.find(server.name);
        const valid = entry != null and entry.?.config_hash == hash;
        const off = specs.items.len;

        if (valid) {
            for (entry.?.tools) |t| {
                if (ai_chat_protocol.builtinToolNameReserved(t.name)) continue;
                const spec_name = try allocator.dupe(u8, t.name);
                errdefer allocator.free(spec_name);
                const spec_desc = try allocator.dupe(u8, t.description);
                errdefer allocator.free(spec_desc);
                const props = try allocator.dupe(u8, t.properties_json);
                errdefer allocator.free(props);
                try specs.append(allocator, .{ .name = spec_name, .description = spec_desc, .properties_json = props });

                const t_name = try allocator.dupe(u8, t.name);
                errdefer allocator.free(t_name);
                const t_desc = try allocator.dupe(u8, t.description);
                errdefer allocator.free(t_desc);
                const t_cmd = try allocator.dupe(u8, server.command);
                errdefer allocator.free(t_cmd);
                const t_args = try dupeStringList(allocator, server.args);
                errdefer freeStringList(allocator, t_args);
                try tools.append(allocator, .{ .function_name = t_name, .description = t_desc, .server_command = t_cmd, .server_args = t_args });
            }
        }
        const s_name = try allocator.dupe(u8, server.name);
        errdefer allocator.free(s_name);
        try servers.append(allocator, .{
            .name = s_name,
            .discovered = valid,
            .spec_off = off,
            .spec_len = specs.items.len - off,
        });
    }
    return .{
        .snap = .{ .specs = try specs.toOwnedSlice(allocator), .tools = try tools.toOwnedSlice(allocator) },
        .servers = try servers.toOwnedSlice(allocator),
    };
}

/// Re-read <configDir>/mcp.json + mcp_catalog.json and swap the cache. Never
/// fails: on any error the cache is left empty. Spawns no servers (discovery
/// moved to probe/activation — see mcp_catalog.zig).
pub fn reloadCache(allocator: std.mem.Allocator) void {
    const gen = mcp_catalog.generation();
    freeCache(allocator);
    const loaded = loadSnapshotsFromCatalog(allocator) catch |err| {
        log.warn("reload failed: {s}", .{@errorName(err)});
        return;
    };
    g_cache_specs = loaded.snap.specs;
    g_cache_specs_owned = loaded.snap.specs.len != 0;
    g_cache_tools = loaded.snap.tools;
    g_cache_tools_owned = loaded.snap.tools.len != 0;
    g_cache_servers = loaded.servers;
    g_cache_servers_owned = loaded.servers.len != 0;
    g_cache_seen_gen = gen;
    log.info("ready: {d} tool(s) across {d} server(s) from catalog", .{ g_cache_tools.len, g_cache_servers.len });
}

/// Reload this thread's cache iff the catalog/config changed since it was
/// built (or it was never built on this thread). Cheap: one atomic load.
pub fn ensureCacheFresh(allocator: std.mem.Allocator) void {
    if (g_cache_seen_gen == mcp_catalog.generation()) return;
    reloadCache(allocator);
}

test "discovered tools compose into an advertised request" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"greet\",\"description\":\"Greet someone\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"who\":{\"type\":\"string\"}}}}]}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "'; exec cat >/dev/null";
    var args = [_][]u8{ @constCast("-c"), @constCast(script) };
    const servers = [_]ServerConfig{.{ .name = @constCast("demo"), .command = @constCast("/bin/sh"), .args = args[0..], .enabled = true }};

    const snap = try discover(a, servers[0..]);
    defer freeSnapshots(a, snap);

    // The discovered specs flow into a real request, schema and all.
    const params = ai_chat_protocol.RequestParams{
        .model = "m",
        .system_prompt = "s",
        .protocol = .anthropic,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .mcp_tools = snap.specs,
    };
    const json = try ai_chat_protocol.buildRequestJson(a, params, &.{}, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"who\":{\"type\":\"string\"}") != null);
}

/// Test seam: populate the cache directly from server configs, skipping the
/// config-file read (which depends on the user's config dir).
pub fn reloadCacheFromServersForTest(allocator: std.mem.Allocator, servers: []const ServerConfig) void {
    freeCache(allocator);
    const snap = discover(allocator, servers) catch return;
    g_cache_specs = snap.specs;
    g_cache_specs_owned = snap.specs.len != 0;
    g_cache_tools = snap.tools;
    g_cache_tools_owned = snap.tools.len != 0;
}

test "cache stores discovered tools and frees them on the next reload" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"greet\",\"description\":\"Greet\",\"inputSchema\":{\"type\":\"object\"}}]}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "'; exec cat >/dev/null";
    var args = [_][]u8{ @constCast("-c"), @constCast(script) };
    const servers = [_]ServerConfig{.{ .name = @constCast("demo"), .command = @constCast("/bin/sh"), .args = args[0..], .enabled = true }};

    reloadCacheFromServersForTest(a, servers[0..]);
    try std.testing.expectEqual(@as(usize, 1), cachedSpecs().len);
    try std.testing.expectEqualStrings("greet", cachedSpecs()[0].name);
    try std.testing.expectEqual(@as(usize, 1), cachedTools().len);
    try std.testing.expectEqualStrings("greet", cachedTools()[0].function_name);

    // Reload with no servers frees the previous cache (leak checker asserts) and empties it.
    reloadCacheFromServersForTest(a, &.{});
    try std.testing.expectEqual(@as(usize, 0), cachedSpecs().len);
    try std.testing.expectEqual(@as(usize, 0), cachedTools().len);
}

test "reloadCache builds specs from the disk catalog without spawning" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    // 配一个根本不存在的命令——若 reloadCache 还会 spawn,这个测试拿不到工具
    var args0 = [_][]u8{@constCast("--x")};
    const servers = [_]ServerConfig{
        .{ .name = @constCast("cached"), .command = @constCast("/nonexistent/bin"), .args = args0[0..], .enabled = true },
        .{ .name = @constCast("fresh"), .command = @constCast("/nonexistent/bin2"), .args = &.{}, .enabled = true },
        .{ .name = @constCast("off"), .command = @constCast("/nonexistent/bin3"), .args = &.{}, .enabled = false },
    };
    try saveConfigFile(a, servers[0..]);

    // 只有 "cached" 有匹配 hash 的目录条目
    const one_arg = [_][]const u8{"--x"};
    const specs = [_]McpToolSpec{.{ .name = "greet", .description = "Greet", .properties_json = "{}" }};
    try mcp_catalog.upsertServer(a, "cached", mcp_catalog.configHash("/nonexistent/bin", one_arg[0..]), 1, specs[0..]);

    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{}); // 释放缓存

    try std.testing.expectEqual(@as(usize, 1), cachedSpecs().len);
    try std.testing.expectEqualStrings("greet", cachedSpecs()[0].name);
    try std.testing.expectEqual(@as(usize, 1), cachedTools().len);
    try std.testing.expectEqualStrings("/nonexistent/bin", cachedTools()[0].server_command);

    const srvs = cachedServers();
    try std.testing.expectEqual(@as(usize, 2), srvs.len); // disabled 的不进目录
    try std.testing.expectEqualStrings("cached", srvs[0].name);
    try std.testing.expect(srvs[0].discovered);
    try std.testing.expectEqual(@as(usize, 1), srvs[0].spec_len);
    try std.testing.expectEqualStrings("fresh", srvs[1].name);
    try std.testing.expect(!srvs[1].discovered);
    try std.testing.expectEqual(@as(usize, 0), srvs[1].spec_len);
}

test "reloadCache treats a hash-mismatched catalog entry as undiscovered" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const servers = [_]ServerConfig{.{ .name = @constCast("s"), .command = @constCast("/bin/new"), .args = &.{}, .enabled = true }};
    try saveConfigFile(a, servers[0..]);
    const specs = [_]McpToolSpec{.{ .name = "old", .description = "", .properties_json = "{}" }};
    try mcp_catalog.upsertServer(a, "s", 999999, 1, specs[0..]); // 错的 hash

    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{});
    try std.testing.expectEqual(@as(usize, 0), cachedSpecs().len);
    try std.testing.expect(!cachedServers()[0].discovered);
}

test "ensureCacheFresh reloads after a generation bump" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const servers = [_]ServerConfig{.{ .name = @constCast("s"), .command = @constCast("/bin/x"), .args = &.{}, .enabled = true }};
    try saveConfigFile(a, servers[0..]);
    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{});
    try std.testing.expectEqual(@as(usize, 0), cachedSpecs().len);

    const specs = [_]McpToolSpec{.{ .name = "t", .description = "", .properties_json = "{}" }};
    const no_args = [_][]const u8{};
    try mcp_catalog.upsertServer(a, "s", mcp_catalog.configHash("/bin/x", no_args[0..]), 1, specs[0..]); // bumps generation
    ensureCacheFresh(a);
    try std.testing.expectEqual(@as(usize, 1), cachedSpecs().len);
}

test "activation filters cloneActivatedSpecs and inactiveDigest" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);
    resetActivationForTest();
    defer resetActivationForTest();

    const servers = [_]ServerConfig{
        .{ .name = @constCast("alpha"), .command = @constCast("/bin/a"), .args = &.{}, .enabled = true },
        .{ .name = @constCast("beta"), .command = @constCast("/bin/b"), .args = &.{}, .enabled = true },
    };
    try saveConfigFile(a, servers[0..]);
    const no_args = [_][]const u8{};
    const sa = [_]McpToolSpec{.{ .name = "a_tool", .description = "A", .properties_json = "{}" }};
    const sb = [_]McpToolSpec{.{ .name = "b_tool", .description = "B", .properties_json = "{}" }};
    try mcp_catalog.upsertServer(a, "alpha", mcp_catalog.configHash("/bin/a", no_args[0..]), 1, sa[0..]);
    try mcp_catalog.upsertServer(a, "beta", mcp_catalog.configHash("/bin/b", no_args[0..]), 1, sb[0..]);
    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{});

    // 未激活:specs 空,摘要两行都在
    const none = try cloneActivatedSpecs(a);
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const digest1 = (try inactiveDigest(a)).?;
    defer a.free(digest1);
    try std.testing.expect(std.mem.indexOf(u8, digest1, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, digest1, "b_tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, digest1, "mcp_activate") != null);

    // 激活 alpha:只克隆 alpha 的;摘要只剩 beta
    try std.testing.expect(activateServer("alpha"));
    try std.testing.expect(isActivated("alpha"));
    try std.testing.expect(activateServer("alpha")); // 幂等
    const only_a = try cloneActivatedSpecs(a);
    defer {
        for (only_a) |s| {
            a.free(s.name);
            a.free(s.description);
            a.free(s.properties_json);
        }
        a.free(only_a);
    }
    try std.testing.expectEqual(@as(usize, 1), only_a.len);
    try std.testing.expectEqualStrings("a_tool", only_a[0].name);
    const digest2 = (try inactiveDigest(a)).?;
    defer a.free(digest2);
    try std.testing.expect(std.mem.indexOf(u8, digest2, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, digest2, "beta") != null);

    // 全部激活 → null
    _ = activateServer("beta");
    try std.testing.expect(try inactiveDigest(a) == null);
}

test "inactiveDigest marks an undiscovered server" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);
    resetActivationForTest();
    defer resetActivationForTest();

    const servers = [_]ServerConfig{.{ .name = @constCast("mystery"), .command = @constCast("/bin/m"), .args = &.{}, .enabled = true }};
    try saveConfigFile(a, servers[0..]);
    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{});

    const digest = (try inactiveDigest(a)).?;
    defer a.free(digest);
    try std.testing.expect(std.mem.indexOf(u8, digest, "mystery") != null);
    try std.testing.expect(std.mem.indexOf(u8, digest, "not discovered yet") != null);
}
