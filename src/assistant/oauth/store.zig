//! Subscription credentials in `<config>/oauth.json` (mode 0600).
//! The file holds Codex, Kimi, and xAI tokens. Callers copy a credential out
//! before doing network I/O so the lock is not held across a refresh.
const std = @import("std");
const codec = @import("codec.zig");
const platform_atomic_file = @import("../../platform/atomic_file.zig");
const platform_dirs = @import("../../platform/dirs.zig");

const Slot = struct {
    access: []u8,
    refresh: []u8,
    expires_ms: i64,
};

var g_lock: std.Thread.Mutex = .{};
var g_loaded: bool = false;
var g_slots: [3]?Slot = .{ null, null, null };

fn slotIndex(provider: codec.Provider) usize {
    return @intFromEnum(provider);
}

pub fn has(provider: codec.Provider) bool {
    g_lock.lock();
    defer g_lock.unlock();
    ensureLoadedLocked() catch return false;
    return g_slots[slotIndex(provider)] != null;
}

pub fn copy(allocator: std.mem.Allocator, provider: codec.Provider) ?codec.OwnedCredential {
    g_lock.lock();
    defer g_lock.unlock();
    ensureLoadedLocked() catch return null;
    const slot = g_slots[slotIndex(provider)] orelse return null;
    const access = allocator.dupe(u8, slot.access) catch return null;
    const refresh = allocator.dupe(u8, slot.refresh) catch {
        allocator.free(access);
        return null;
    };
    return .{ .access = access, .refresh = refresh, .expires_ms = slot.expires_ms };
}

pub fn put(provider: codec.Provider, access: []const u8, refresh: []const u8, expires_ms: i64) !void {
    const heap = std.heap.page_allocator;
    const access_copy = try heap.dupe(u8, access);
    errdefer heap.free(access_copy);
    const refresh_copy = try heap.dupe(u8, refresh);
    errdefer heap.free(refresh_copy);

    g_lock.lock();
    defer g_lock.unlock();
    ensureLoadedLocked() catch {};
    freeSlot(slotIndex(provider));
    g_slots[slotIndex(provider)] = .{
        .access = access_copy,
        .refresh = refresh_copy,
        .expires_ms = expires_ms,
    };
    try writeLocked();
}

pub fn clear(provider: codec.Provider) void {
    g_lock.lock();
    defer g_lock.unlock();
    ensureLoadedLocked() catch {};
    freeSlot(slotIndex(provider));
    writeLocked() catch {};
}

fn freeSlot(index: usize) void {
    if (g_slots[index]) |slot| {
        std.heap.page_allocator.free(slot.access);
        std.heap.page_allocator.free(slot.refresh);
        g_slots[index] = null;
    }
}

fn ensureLoadedLocked() !void {
    if (g_loaded) return;
    g_loaded = true;
    const path = platform_dirs.pathInConfigDir(std.heap.page_allocator, "oauth.json") catch return;
    defer std.heap.page_allocator.free(path);
    const body = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 256 * 1024) catch return;
    defer std.heap.page_allocator.free(body);
    loadBody(body) catch {};
}

fn loadBody(body: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const providers = [_]codec.Provider{ .codex, .kimi, .xai };
    for (providers) |provider| {
        const value = parsed.value.object.get(provider.name()) orelse continue;
        const access = jsonString(value, "access") orelse continue;
        const refresh = jsonString(value, "refresh") orelse continue;
        const expires = jsonI64(value, "expires") orelse continue;
        const access_copy = std.heap.page_allocator.dupe(u8, access) catch continue;
        const refresh_copy = std.heap.page_allocator.dupe(u8, refresh) catch {
            std.heap.page_allocator.free(access_copy);
            continue;
        };
        freeSlot(slotIndex(provider));
        g_slots[slotIndex(provider)] = .{
            .access = access_copy,
            .refresh = refresh_copy,
            .expires_ms = expires,
        };
    }
}

fn writeLocked() !void {
    const path = try platform_dirs.pathInConfigDir(std.heap.page_allocator, "oauth.json");
    defer std.heap.page_allocator.free(path);
    const body = try encodeSlots(std.heap.page_allocator);
    defer std.heap.page_allocator.free(body);
    try platform_atomic_file.writeFileReplaceSafeWithOptions(path, body, .{ .mode = 0o600 });
}

pub fn encodeSlotsForTest(allocator: std.mem.Allocator, codex: ?codec.OwnedCredential, kimi: ?codec.OwnedCredential, xai: ?codec.OwnedCredential) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{");
    try writeSlot(allocator, &out, "codex", codex, false);
    try writeSlot(allocator, &out, "kimi", kimi, true);
    try writeSlot(allocator, &out, "xai", xai, true);
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

fn encodeSlots(allocator: std.mem.Allocator) ![]u8 {
    const cred = struct {
        fn owned(index: usize) ?codec.OwnedCredential {
            const slot = g_slots[index] orelse return null;
            return .{ .access = slot.access, .refresh = slot.refresh, .expires_ms = slot.expires_ms };
        }
    };
    return encodeSlotsForTest(allocator, cred.owned(0), cred.owned(1), cred.owned(2));
}

fn writeSlot(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8, cred: ?codec.OwnedCredential, comma: bool) !void {
    if (comma) try out.append(allocator, ',');
    try out.append(allocator, '"');
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\":");
    const slot = cred orelse {
        try out.appendSlice(allocator, "null");
        return;
    };
    try out.appendSlice(allocator, "{\"access\":");
    try appendJsonString(allocator, out, slot.access);
    try out.appendSlice(allocator, ",\"refresh\":");
    try appendJsonString(allocator, out, slot.refresh);
    try out.writer(allocator).print(",\"expires\":{d}}}", .{slot.expires_ms});
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| switch (ch) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        else => if (ch < 0x20) {
            try out.writer(allocator).print("\\u{x:0>4}", .{ch});
        } else try out.append(allocator, ch),
    };
    try out.append(allocator, '"');
}

fn jsonString(root: std.json.Value, name: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonI64(root: std.json.Value, name: []const u8) ?i64 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

test "oauth file round-trips one credential and leaves the others empty" {
    const cred = codec.OwnedCredential{
        .access = @constCast("access-token"),
        .refresh = @constCast("refresh-token"),
        .expires_ms = 42,
    };
    const json = try encodeSlotsForTest(std.testing.allocator, cred, null, null);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kimi\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "access-token") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const slot = parsed.value.object.get("codex").?;
    try std.testing.expectEqualStrings("refresh-token", slot.object.get("refresh").?.string);
    try std.testing.expectEqual(@as(i64, 42), slot.object.get("expires").?.integer);
}
