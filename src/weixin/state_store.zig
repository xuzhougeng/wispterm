//! Persists the WeChat direct binding to a 0600 JSON file. Secrets never go in
//! config; they live here in the app state dir.
const std = @import("std");
const platform_atomic_file = @import("../platform/atomic_file.zig");
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
    const wire = Wire{
        .bot_token = binding.bot_token,
        .base_url = binding.base_url,
        .owner_user_id = binding.owner_user_id,
        .bot_id = binding.bot_id,
        .sync_buf = binding.sync_buf,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, wire, .{});
    defer allocator.free(json);

    try platform_atomic_file.writeFileReplaceSafeWithOptions(path, json, .{
        .mode = 0o600,
        .sync_file = true,
    });
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
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        renameCorrupt(allocator, path);
        return .{ .arena = arena, .binding = .{} };
    };
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

fn renameCorrupt(allocator: std.mem.Allocator, path: []const u8) void {
    const corrupt = std.fmt.allocPrint(allocator, "{s}.corrupt-{d}", .{ path, std.time.milliTimestamp() }) catch return;
    defer allocator.free(corrupt);
    if (std.fs.path.isAbsolute(path)) {
        std.fs.renameAbsolute(path, corrupt) catch {
            std.fs.cwd().rename(path, corrupt) catch {};
        };
    } else {
        std.fs.cwd().rename(path, corrupt) catch {};
    }
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

test "load renames corrupt binding and returns empty" {
    const allocator = std.testing.allocator;
    const dir_name = "zig-cache-tmp-weixin-corrupt";
    std.fs.cwd().deleteTree(dir_name) catch {};
    defer std.fs.cwd().deleteTree(dir_name) catch {};
    try std.fs.cwd().makePath(dir_name);

    const path = try std.fs.path.join(allocator, &.{ dir_name, "weixin.json" });
    defer allocator.free(path);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "{ broken" });

    var loaded = try load(allocator, path);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), loaded.binding.bot_token.len);

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));

    var found_corrupt = false;
    var dir = try std.fs.cwd().openDir(dir_name, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "weixin.json.corrupt-")) {
            found_corrupt = true;
            break;
        }
    }
    try std.testing.expect(found_corrupt);
}
