//! Disk cache of MCP server tool listings: <configDir>/mcp_catalog.json.
//! Lets the registry build the tool catalog at startup WITHOUT spawning any
//! MCP server. Entries are keyed by server name and invalidated when the
//! server's command+args hash changes. Written by: panel probe ("Test"),
//! mcp_activate live discovery. Read by: mcp_registry.reloadCache.
const std = @import("std");
const platform_dirs = @import("../platform/dirs.zig");
const atomic_file = @import("../platform/atomic_file.zig");
const ai_chat_protocol = @import("../assistant/conversation/protocol.zig");

const McpToolSpec = ai_chat_protocol.McpToolSpec;
const MAX_CATALOG_BYTES: usize = 4 * 1024 * 1024;

pub const CatalogTool = struct { name: []u8, description: []u8, properties_json: []u8 };

pub const CatalogServer = struct {
    name: []u8,
    config_hash: u64,
    discovered_at: i64,
    tools: []CatalogTool,
};

pub const Catalog = struct {
    servers: []CatalogServer = &.{},

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.servers) |s| {
            allocator.free(s.name);
            for (s.tools) |t| {
                allocator.free(t.name);
                allocator.free(t.description);
                allocator.free(t.properties_json);
            }
            allocator.free(s.tools);
        }
        allocator.free(self.servers);
        self.servers = &.{};
    }

    pub fn find(self: *const Catalog, name: []const u8) ?*const CatalogServer {
        for (self.servers) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

/// Identity of a server config for cache invalidation: command + args.
pub fn configHash(command: []const u8, args: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(command);
    h.update(&[_]u8{0});
    for (args) |arg| {
        h.update(arg);
        h.update(&[_]u8{0});
    }
    return h.final();
}

// Cross-thread invalidation signal: bumped on every catalog/config write.
// Threadlocal registry caches compare against this and reload lazily.
var g_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

pub fn generation() u64 {
    return g_generation.load(.monotonic);
}

pub fn bumpGeneration() void {
    _ = g_generation.fetchAdd(1, .monotonic);
}

fn catalogPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.pathInConfigDir(allocator, "mcp_catalog.json");
}

/// Read the catalog. Missing or corrupt file → empty catalog (never an error;
/// the next successful discovery rewrites it).
pub fn load(allocator: std.mem.Allocator) Catalog {
    return loadInner(allocator) catch .{ .servers = &.{} };
}

fn loadInner(allocator: std.mem.Allocator) !Catalog {
    const path = try catalogPath(allocator);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_CATALOG_BYTES) catch
        return .{ .servers = &.{} };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return .{ .servers = &.{} };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .servers = &.{} };
    const servers_val = parsed.value.object.get("servers") orelse return .{ .servers = &.{} };
    if (servers_val != .object) return .{ .servers = &.{} };

    var list: std.ArrayListUnmanaged(CatalogServer) = .empty;
    errdefer {
        for (list.items) |s| {
            allocator.free(s.name);
            for (s.tools) |t| {
                allocator.free(t.name);
                allocator.free(t.description);
                allocator.free(t.properties_json);
            }
            allocator.free(s.tools);
        }
        list.deinit(allocator);
    }

    var it = servers_val.object.iterator();
    while (it.next()) |entry| {
        const spec = entry.value_ptr.*;
        if (spec != .object) continue;
        const hash_v = spec.object.get("configHash") orelse continue;
        if (hash_v != .string) continue;
        const hash = std.fmt.parseInt(u64, hash_v.string, 16) catch continue;
        const discovered_at: i64 = if (spec.object.get("discoveredAt")) |d|
            (if (d == .integer) d.integer else 0)
        else
            0;

        var tools: std.ArrayListUnmanaged(CatalogTool) = .empty;
        errdefer {
            for (tools.items) |t| {
                allocator.free(t.name);
                allocator.free(t.description);
                allocator.free(t.properties_json);
            }
            tools.deinit(allocator);
        }
        if (spec.object.get("tools")) |tools_v| {
            if (tools_v == .array) {
                for (tools_v.array.items) |tv| {
                    if (tv != .object) continue;
                    const name_v = tv.object.get("name") orelse continue;
                    if (name_v != .string) continue;
                    const desc_v = tv.object.get("description");
                    const props_v = tv.object.get("propertiesJson");
                    const t_name = try allocator.dupe(u8, name_v.string);
                    errdefer allocator.free(t_name);
                    const t_desc = try allocator.dupe(u8, if (desc_v != null and desc_v.? == .string) desc_v.?.string else "");
                    errdefer allocator.free(t_desc);
                    const t_props = try allocator.dupe(u8, if (props_v != null and props_v.? == .string) props_v.?.string else "{}");
                    errdefer allocator.free(t_props);
                    try tools.append(allocator, .{ .name = t_name, .description = t_desc, .properties_json = t_props });
                }
            }
        }

        const s_name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(s_name);
        try list.append(allocator, .{
            .name = s_name,
            .config_hash = hash,
            .discovered_at = discovered_at,
            .tools = try tools.toOwnedSlice(allocator),
        });
    }
    return .{ .servers = try list.toOwnedSlice(allocator) };
}

fn save(allocator: std.mem.Allocator, catalog: *const Catalog) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var servers_obj = std.json.ObjectMap.init(aa);
    for (catalog.servers) |s| {
        var entry = std.json.ObjectMap.init(aa);
        try entry.put("configHash", .{ .string = try std.fmt.allocPrint(aa, "{x}", .{s.config_hash}) });
        try entry.put("discoveredAt", .{ .integer = s.discovered_at });
        var arr = std.json.Array.init(aa);
        for (s.tools) |t| {
            var tool_obj = std.json.ObjectMap.init(aa);
            try tool_obj.put("name", .{ .string = t.name });
            try tool_obj.put("description", .{ .string = t.description });
            try tool_obj.put("propertiesJson", .{ .string = t.properties_json });
            try arr.append(.{ .object = tool_obj });
        }
        try entry.put("tools", .{ .array = arr });
        try servers_obj.put(s.name, .{ .object = entry });
    }
    var root = std.json.ObjectMap.init(aa);
    try root.put("servers", .{ .object = servers_obj });

    const body = try std.json.Stringify.valueAlloc(aa, std.json.Value{ .object = root }, .{});
    const path = try catalogPath(allocator);
    defer allocator.free(path);
    const dir = try platform_dirs.configDir(allocator);
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    try atomic_file.writeFileReplaceSafe(path, body);
}

/// Insert or replace one server's tool listing, persist, and bump the
/// generation so other threads' registry caches reload lazily.
pub fn upsertServer(
    allocator: std.mem.Allocator,
    name: []const u8,
    config_hash: u64,
    discovered_at: i64,
    tools: []const McpToolSpec,
) !void {
    var cat = load(allocator);
    defer cat.deinit(allocator);

    var list: std.ArrayListUnmanaged(CatalogServer) = .empty;
    defer list.deinit(allocator);
    for (cat.servers) |s| {
        if (std.mem.eql(u8, s.name, name)) continue; // replaced below
        try list.append(allocator, s);
    }

    // Borrow the caller's spec strings for the duration of the save (save only
    // reads them; same borrowing trick as mcp_config.addServer).
    const borrowed = try allocator.alloc(CatalogTool, tools.len);
    defer allocator.free(borrowed);
    for (tools, 0..) |t, i| borrowed[i] = .{
        .name = @constCast(t.name),
        .description = @constCast(t.description),
        .properties_json = @constCast(t.properties_json),
    };
    try list.append(allocator, .{
        .name = @constCast(name),
        .config_hash = config_hash,
        .discovered_at = discovered_at,
        .tools = borrowed,
    });

    const to_save: Catalog = .{ .servers = list.items };
    try save(allocator, &to_save);
    bumpGeneration();
}

// Tests
test "configHash changes when command or args change" {
    const a1 = [_][]const u8{ "-y", "pkg" };
    const h1 = configHash("npx", a1[0..]);
    const h2 = configHash("npx2", a1[0..]);
    const a2 = [_][]const u8{ "-y", "pkg2" };
    const h3 = configHash("npx", a2[0..]);
    try std.testing.expect(h1 != h2);
    try std.testing.expect(h1 != h3);
    try std.testing.expectEqual(h1, configHash("npx", a1[0..]));
}

test "upsertServer then load round-trips tools; corrupt file loads empty" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const specs = [_]McpToolSpec{
        .{ .name = "search", .description = "Search things", .properties_json = "{\"q\":{\"type\":\"string\"}}" },
        .{ .name = "read", .description = "Read things", .properties_json = "{}" },
    };
    const gen_before = generation();
    try upsertServer(a, "jina", 42, 1000, specs[0..]);
    try std.testing.expect(generation() > gen_before);

    var cat = load(a);
    defer cat.deinit(a);
    const entry = cat.find("jina").?;
    try std.testing.expectEqual(@as(u64, 42), entry.config_hash);
    try std.testing.expectEqual(@as(usize, 2), entry.tools.len);
    try std.testing.expectEqualStrings("search", entry.tools[0].name);
    try std.testing.expectEqualStrings("{\"q\":{\"type\":\"string\"}}", entry.tools[0].properties_json);

    // upsert 同名替换,不同名共存
    try upsertServer(a, "jina", 43, 1001, specs[0..1]);
    try upsertServer(a, "other", 7, 1002, specs[1..]);
    var cat2 = load(a);
    defer cat2.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), cat2.servers.len);
    try std.testing.expectEqual(@as(u64, 43), cat2.find("jina").?.config_hash);
    try std.testing.expectEqual(@as(usize, 1), cat2.find("jina").?.tools.len);

    // 损坏文件 → 空目录
    const path = try platform_dirs.pathInConfigDir(a, "mcp_catalog.json");
    defer a.free(path);
    try atomic_file.writeFileReplaceSafe(path, "not json");
    var cat3 = load(a);
    defer cat3.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), cat3.servers.len);
}

test "load returns empty when the file is absent" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);
    var cat = load(a);
    defer cat.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), cat.servers.len);
}
