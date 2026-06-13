//! Auto-discovery file for wisptermctl: a 0600 JSON file in the config dir
//! holding the running instance's loopback port + auth token. The server writes
//! it on start and removes it on shutdown; the client reads it to connect.
//! Imports only platform/dirs.zig (std+builtin), so the lean client exe links
//! without GUI/SDL dependencies.
const std = @import("std");
const platform_dirs = @import("../platform/dirs.zig");

pub const basename = "agent-control.json";
const MAX_FILE_BYTES = 64 * 1024;

pub const Info = struct {
    port: u16,
    token: []const u8, // owned by the caller's allocator after read()
};

pub fn filePath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.pathInConfigDir(allocator, basename);
}

/// Serialize to JSON (no trailing newline). Caller owns.
pub fn encode(allocator: std.mem.Allocator, info: Info) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "{{\"port\":{d},\"token\":", .{info.port});
    const tok = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = info.token }, .{});
    defer allocator.free(tok);
    try out.appendSlice(allocator, tok);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// Parse file content. `token` is duped into `allocator` (caller frees).
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Info {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDiscovery;
    const obj = parsed.value.object;
    const port_v = obj.get("port") orelse return error.InvalidDiscovery;
    const tok_v = obj.get("token") orelse return error.InvalidDiscovery;
    if (port_v != .integer or tok_v != .string) return error.InvalidDiscovery;
    if (port_v.integer <= 0 or port_v.integer > 65535) return error.InvalidDiscovery;
    return .{ .port = @intCast(port_v.integer), .token = try allocator.dupe(u8, tok_v.string) };
}

/// Write the discovery file with owner-only (0600) perms. Replaces any existing
/// file so perms tighten even if a looser one was left behind.
pub fn write(allocator: std.mem.Allocator, info: Info) !void {
    const path = try filePath(allocator);
    defer allocator.free(path);
    const body = try encode(allocator, info);
    defer allocator.free(body);
    // The control server may start before the first window creates the config
    // dir (Config.ensureConfigExists runs later), so create the parent here or
    // the write fails on a fresh profile and the API is silently disabled.
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    std.fs.cwd().deleteFile(path) catch {};
    var file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(body);
}

/// Read + parse. Returns null when the file is absent. Token owned by caller.
pub fn read(allocator: std.mem.Allocator) !?Info {
    const path = try filePath(allocator);
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, MAX_FILE_BYTES) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);
    return try parse(allocator, content);
}

pub fn remove(allocator: std.mem.Allocator) void {
    const path = filePath(allocator) catch return;
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

// ---- tests ----
const t = std.testing;

test "encode/parse round-trip" {
    const body = try encode(t.allocator, .{ .port = 51234, .token = "deadbeef" });
    defer t.allocator.free(body);
    const info = try parse(t.allocator, body);
    defer t.allocator.free(info.token);
    try t.expectEqual(@as(u16, 51234), info.port);
    try t.expectEqualStrings("deadbeef", info.token);
}

test "parse rejects malformed / out-of-range" {
    try t.expectError(error.InvalidDiscovery, parse(t.allocator, "{}"));
    try t.expectError(error.InvalidDiscovery, parse(t.allocator, "{\"port\":0,\"token\":\"x\"}"));
    try t.expectError(error.InvalidDiscovery, parse(t.allocator, "{\"port\":70000,\"token\":\"x\"}"));
}

test "write then read round-trips via a redirected config dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(dir_path);
    platform_dirs.setTestConfigDirForCurrentThread(dir_path);
    defer platform_dirs.clearTestConfigDirForCurrentThread();

    try write(t.allocator, .{ .port = 40000, .token = "tok123" });
    const got = (try read(t.allocator)).?;
    defer t.allocator.free(got.token);
    try t.expectEqual(@as(u16, 40000), got.port);
    try t.expectEqualStrings("tok123", got.token);

    remove(t.allocator);
    try t.expect((try read(t.allocator)) == null);
}
