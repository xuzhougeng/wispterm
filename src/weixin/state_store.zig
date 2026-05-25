//! Persists the WeChat direct binding to a 0600 JSON file. Secrets never go in
//! config; they live here in the app state dir.
const std = @import("std");
const types = @import("types.zig");

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    binding: types.Binding,

    pub fn deinit(self: *Loaded, _: std.mem.Allocator) void {
        self.arena.deinit();
    }
};

const Wire = struct {
    bot_token: []const u8 = "",
    base_url: []const u8 = "",
    owner_user_id: []const u8 = "",
    bot_id: []const u8 = "",
    sync_buf: []const u8 = "",
};

pub fn save(allocator: std.mem.Allocator, path: []const u8, binding: types.Binding) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const wire = Wire{
        .bot_token = binding.bot_token,
        .base_url = binding.base_url,
        .owner_user_id = binding.owner_user_id,
        .bot_id = binding.bot_id,
        .sync_buf = binding.sync_buf,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, wire, .{});
    defer allocator.free(json);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(json);
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Loaded {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const data = std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .binding = .{} },
        else => return err,
    };

    var parsed = std.json.parseFromSlice(Wire, arena.allocator(), data, .{
        .ignore_unknown_fields = true,
    }) catch return .{ .arena = arena, .binding = .{} };
    defer parsed.deinit();

    // Copy strings into the arena so they outlive `parsed`
    const a = arena.allocator();
    return .{ .arena = arena, .binding = .{
        .bot_token = try a.dupe(u8, parsed.value.bot_token),
        .base_url = try a.dupe(u8, parsed.value.base_url),
        .owner_user_id = try a.dupe(u8, parsed.value.owner_user_id),
        .bot_id = try a.dupe(u8, parsed.value.bot_id),
        .sync_buf = try a.dupe(u8, parsed.value.sync_buf),
    } };
}

test "round-trips binding through a file" {
    const tmp_path = "zig-cache-tmp-weixin-state.json";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try save(std.testing.allocator, tmp_path, .{
        .bot_token = "tok-123",
        .base_url = "https://example.test",
        .owner_user_id = "user-9",
        .bot_id = "bot-1",
        .sync_buf = "BUF==",
    });

    var loaded = try load(std.testing.allocator, tmp_path);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("tok-123", loaded.binding.bot_token);
    try std.testing.expectEqualStrings("user-9", loaded.binding.owner_user_id);
    try std.testing.expectEqualStrings("BUF==", loaded.binding.sync_buf);
}

test "load returns empty binding when file is absent" {
    var loaded = try load(std.testing.allocator, "definitely-not-here-weixin.json");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), loaded.binding.bot_token.len);
}
