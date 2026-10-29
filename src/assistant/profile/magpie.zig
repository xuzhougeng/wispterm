//! Read-only Magpie connection. Kept outside native settings and ai_profiles.
const std = @import("std");
const builtin = @import("builtin");
const dirs = @import("../../platform/dirs.zig");
const codec = @import("../../renderer/overlays/profile_codec.zig");

const Connection = struct {
    baseURL: []const u8,
    apiKey: []const u8,
    model: []const u8,
    // User-owned override, preserved by Magpie when it rewrites connection keys.
    vision: std.json.Value = .null,
};
pub const max_file_bytes = 64 * 1024;

pub fn pathFromHome(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".config", "wispterm", "magpie.json" });
}

pub fn load(allocator: std.mem.Allocator) ?codec.AiProfile {
    // Tests must explicitly provide a fixture path, never read personal keys.
    if (builtin.is_test) return null;
    const home = dirs.homeDir(allocator) catch return null;
    defer allocator.free(home);
    const path = pathFromHome(allocator, home) catch return null;
    defer allocator.free(path);
    return loadFromPath(allocator, path);
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) ?codec.AiProfile {
    const content = std.fs.cwd().readFileAlloc(allocator, path, max_file_bytes) catch return null;
    defer allocator.free(content);
    return parse(allocator, content);
}

fn validField(value: []const u8) bool {
    if (value.len == 0 or value.len > codec.AI_FIELD_MAX) return false;
    if (std.mem.trim(u8, value, " \t\r\n").len != value.len) return false;
    for (value) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8) ?codec.AiProfile {
    if (content.len > max_file_bytes) return null;
    const parsed = std.json.parseFromSlice(Connection, allocator, content, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const c = parsed.value;
    if (!validField(c.baseURL) or !validField(c.apiKey) or !validField(c.model)) return null;
    const uri = std.Uri.parse(c.baseURL) catch return null;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return null;
    const host = uri.host orelse return null;
    const host_text = switch (host) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
    if (host_text.len == 0 or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return null;
    var profile = codec.AiProfile{ .managed_by_magpie = true };
    codec.setProfileDefault(&profile, .name, "Magpie");
    codec.setProfileDefault(&profile, .base_url, c.baseURL);
    codec.setProfileDefault(&profile, .api_key, c.apiKey);
    codec.setProfileDefault(&profile, .model, c.model);
    codec.setProfileDefault(&profile, .protocol, "chat_completions");
    codec.setProfileDefault(&profile, .thinking, "disabled");
    codec.setProfileDefault(&profile, .stream, "true");
    codec.setProfileDefault(&profile, .agent, "true");
    codec.setProfileDefault(&profile, .max_tokens, "8192");
    // The gateway can route to image-capable models; a missing capability field
    // must not disable image attachment for every Magpie profile.
    const vision = switch (c.vision) {
        .null => true,
        .bool => |enabled| enabled,
        .string => |value| enabled: {
            if (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "enabled")) break :enabled true;
            if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "disabled")) break :enabled false;
            return null;
        },
        else => return null,
    };
    codec.setProfileDefault(&profile, .vision, if (vision) "on" else "off");
    return profile;
}

/// Keep every personal profile and reserve a distinct visible name on collision.
pub fn append(profile: codec.AiProfile, out: []codec.AiProfile, count: usize) usize {
    if (count >= out.len) return count;
    out[count] = profile;
    var suffix: usize = 1;
    var name_buf: [64]u8 = undefined;
    while (true) {
        const name = codec.aiProfileField(&out[count], .name);
        var collision = false;
        for (out[0..count]) |*existing| {
            if (std.mem.eql(u8, name, codec.aiProfileField(existing, .name))) {
                collision = true;
                break;
            }
        }
        if (!collision) return count + 1;
        suffix += 1;
        codec.setProfileDefault(&out[count], .name, std.fmt.bufPrint(&name_buf, "Magpie ({d})", .{suffix}) catch unreachable);
    }
}

pub fn managedIndex(profiles: []const codec.AiProfile) ?usize {
    for (profiles, 0..) |p, i| if (p.managed_by_magpie) return i;
    return null;
}

test "Magpie parses gateway fields without adding a model prefix or duplicating v1" {
    const p = parse(std.testing.allocator, "{\"baseURL\":\"http://127.0.0.1:3425/v1\",\"apiKey\":\"magpie-wispterm\",\"model\":\"provider/model\",\"future\":true}") orelse return error.ExpectedProfile;
    try std.testing.expect(p.managed_by_magpie);
    try std.testing.expectEqualStrings("on", codec.aiProfileField(&p, .vision));
    try std.testing.expectEqualStrings("provider/model", codec.aiProfileField(&p, .model));
    const endpoint = try @import("../conversation/protocol.zig").apiEndpoint(std.testing.allocator, codec.aiProfileField(&p, .base_url), .chat_completions);
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("http://127.0.0.1:3425/v1/chat/completions", endpoint);
}

test "Magpie ignores disconnected partial malformed and unsafe settings" {
    for ([_][]const u8{
        "{}",                                                                                    "null",                                                             "[]",                                                            "{",                                                                                   "{\"baseURL\":true}",
        "{\"baseURL\":\"http://localhost/v1\",\"apiKey\":\"\",\"model\":\"m\"}",                 "{\"baseURL\":\"file:///tmp/x\",\"apiKey\":\"k\",\"model\":\"m\"}", "{\"baseURL\":\"http:///v1\",\"apiKey\":\"k\",\"model\":\"m\"}", "{\"baseURL\":\"https://user:pass@example.com/v1\",\"apiKey\":\"k\",\"model\":\"m\"}", "{\"baseURL\":\"https://example.com/v1?x=y\",\"apiKey\":\"k\",\"model\":\"m\"}",
        "{\"baseURL\":\"https://example.com/v1\",\"apiKey\":\"k\\r\\nheader\",\"model\":\"m\"}",
    }) |content| try std.testing.expect(parse(std.testing.allocator, content) == null);
    const huge = try std.testing.allocator.alloc(u8, max_file_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, ' ');
    try std.testing.expect(parse(std.testing.allocator, huge) == null);
}

test "Magpie connect switch disconnect reads a file without changing personal profiles" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "magpie.json" });
    defer a.free(path);
    try std.testing.expect(loadFromPath(a, path) == null);
    var profiles: [3]codec.AiProfile = .{codec.AiProfile{}} ** 3;
    codec.setProfileDefault(&profiles[0], .name, "Magpie");
    codec.setProfileDefault(&profiles[0], .model, "personal");
    for ([_][]const u8{ "p/first", "p/second" }) |model| {
        const content = try std.fmt.allocPrint(a, "{{\"baseURL\":\"http://localhost:3425/v1\",\"apiKey\":\"test-key\",\"model\":\"{s}\"}}", .{model});
        defer a.free(content);
        try tmp.dir.writeFile(.{ .sub_path = "magpie.json", .data = content });
        const count = append(loadFromPath(a, path) orelse return error.ExpectedProfile, &profiles, 1);
        try std.testing.expectEqual(@as(usize, 2), count);
        try std.testing.expectEqual(@as(?usize, 1), managedIndex(profiles[0..count]));
        try std.testing.expectEqualStrings("Magpie (2)", codec.aiProfileField(&profiles[1], .name));
        try std.testing.expectEqualStrings(model, codec.aiProfileField(&profiles[1], .model));
        try std.testing.expectEqualStrings("personal", codec.aiProfileField(&profiles[0], .model));
    }
    try tmp.dir.writeFile(.{ .sub_path = "magpie.json", .data = "{}" });
    try std.testing.expect(loadFromPath(a, path) == null);
    try std.testing.expect(managedIndex(profiles[0..1]) == null);
    try std.testing.expectEqual(@as(usize, 1), append(profiles[1], profiles[0..1], 1));
}

test "Magpie vision accepts explicit booleans and profile-style switches" {
    const a = std.testing.allocator;
    for ([_]struct { json: []const u8, expected: ?[]const u8 }{
        .{ .json = "true", .expected = "on" },
        .{ .json = "false", .expected = "off" },
        .{ .json = "null", .expected = "on" },
        .{ .json = "\"on\"", .expected = "on" },
        .{ .json = "\"off\"", .expected = "off" },
        .{ .json = "\"true\"", .expected = "on" },
        .{ .json = "\"false\"", .expected = "off" },
        .{ .json = "\"enabled\"", .expected = "on" },
        .{ .json = "\"disabled\"", .expected = "off" },
        .{ .json = "\"auto\"", .expected = null },
        .{ .json = "0", .expected = null },
        .{ .json = "{}", .expected = null },
        .{ .json = "[]", .expected = null },
    }) |case| {
        const json = try std.fmt.allocPrint(a, "{{\"baseURL\":\"http://localhost/v1\",\"apiKey\":\"fixture\",\"model\":\"provider/opaque-model\",\"vision\":{s}}}", .{case.json});
        defer a.free(json);
        const profile = parse(a, json);
        if (case.expected) |expected| {
            const p = profile orelse return error.ExpectedProfile;
            try std.testing.expectEqualStrings(expected, codec.aiProfileField(&p, .vision));
        } else {
            try std.testing.expect(profile == null);
        }
    }
}
