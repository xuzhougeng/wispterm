//! Process-wide `env = KEY=VALUE` config (Ghostty's `env` key) applied to every
//! PTY child the platform backends spawn. `set` runs on the main thread from
//! App config load/reload; backends read `entries()` when starting a command.
//! Mirrors Ghostty's `termio/Exec.zig`, which `put`s `config.env` on top of the
//! inherited environment last so user values win over the terminal's own.
const std = @import("std");

pub const Entry = struct { key: [:0]const u8, value: [:0]const u8 };

// ponytail: plain global, no lock — set/read both happen on the main thread.
var g_entries: []const Entry = &.{};
var g_allocator: ?std.mem.Allocator = null;

pub fn entries() []const Entry {
    return g_entries;
}

/// Replace the active set with a copy of `map` (insertion order kept).
pub fn set(allocator: std.mem.Allocator, map: *const std.StringArrayHashMapUnmanaged([]const u8)) !void {
    var list = try allocator.alloc(Entry, map.count());
    var filled: usize = 0;
    errdefer freeEntries(allocator, list[0..filled]);
    var it = map.iterator();
    while (it.next()) |kv| {
        const key = try allocator.dupeZ(u8, kv.key_ptr.*);
        errdefer allocator.free(key);
        const value = try allocator.dupeZ(u8, kv.value_ptr.*);
        list[filled] = .{ .key = key, .value = value };
        filled += 1;
    }
    clear();
    g_entries = list;
    g_allocator = allocator;
}

pub fn clear() void {
    if (g_allocator) |allocator| freeEntries(allocator, g_entries);
    g_entries = &.{};
    g_allocator = null;
}

fn freeEntries(allocator: std.mem.Allocator, list: []const Entry) void {
    for (list) |e| {
        allocator.free(e.key);
        allocator.free(e.value);
    }
    if (list.len > 0) allocator.free(list.ptr[0..list.len]);
}

test "shell env copies entries and clears" {
    const allocator = std.testing.allocator;
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer map.deinit(allocator);
    try map.put(allocator, "MSYSTEM", "CLANG64");
    try map.put(allocator, "MSYS", "winsymlinks:nativestrict");

    try set(allocator, &map);
    defer clear();
    try std.testing.expectEqual(@as(usize, 2), entries().len);
    try std.testing.expectEqualStrings("MSYSTEM", entries()[0].key);
    try std.testing.expectEqualStrings("CLANG64", entries()[0].value);
    try std.testing.expectEqual(@as(u8, 0), entries()[1].value[entries()[1].value.len]);

    map.clearRetainingCapacity();
    try set(allocator, &map);
    try std.testing.expectEqual(@as(usize, 0), entries().len);
}
