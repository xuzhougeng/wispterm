//! JSON artifact writes for the memory digest (spec §9). M1 writes the
//! daily raw-session listing and the index; LLM summary fields arrive in
//! M2. Everything goes through atomic replace so a crash never leaves a
//! half-written artifact.
const std = @import("std");
const atomic_file = @import("../platform/atomic_file.zig");

pub const SCHEMA_VERSION: u32 = 1;

pub const DailySession = struct {
    provider: []const u8,
    source_id: []const u8,
    session_id: []const u8,
    project: []const u8,
    title: []const u8,
    message_count_new: u32,
};

pub const Daily = struct {
    schema_version: u32 = SCHEMA_VERSION,
    date: []const u8, // "2026-07-07"
    generated_at: i64,
    sessions: []const DailySession = &.{},
};

pub const IndexProject = struct {
    slug: []const u8,
    last_active: []const u8,
    session_count: u32,
};

pub const Index = struct {
    schema_version: u32 = SCHEMA_VERSION,
    generated_at: i64,
    days: []const []const u8,
    projects: []const IndexProject = &.{},
};

/// Packed YYYYMMDD (ai_types.DateKey) → "YYYY-MM-DD".
pub fn formatDate(date_key: u32, buf: *[10]u8) []const u8 {
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        date_key / 10000,
        date_key / 100 % 100,
        date_key % 100,
    }) catch unreachable;
    return buf[0..10];
}

pub fn writeDaily(gpa: std.mem.Allocator, memory_root: []const u8, daily: Daily) !void {
    const dir = try std.fs.path.join(gpa, &.{ memory_root, "daily" });
    defer gpa.free(dir);
    try std.fs.cwd().makePath(dir);
    const name = try std.fmt.allocPrint(gpa, "{s}.json", .{daily.date});
    defer gpa.free(name);
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    try writeJson(gpa, path, daily);
}

pub fn writeIndex(gpa: std.mem.Allocator, memory_root: []const u8, index: Index) !void {
    try std.fs.cwd().makePath(memory_root);
    const path = try std.fs.path.join(gpa, &.{ memory_root, "index.json" });
    defer gpa.free(path);
    try writeJson(gpa, path, index);
}

fn writeJson(gpa: std.mem.Allocator, path: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    try atomic_file.writeFileReplaceSafe(path, json);
}

test "memory_digest_store: formatDate renders packed keys" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("2026-07-07", formatDate(20260707, &buf));
    try std.testing.expectEqualStrings("2026-01-02", formatDate(20260102, &buf));
}

test "memory_digest_store: writeDaily creates dirs and overwrites idempotently" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const daily: Daily = .{
        .date = "2026-07-07",
        .generated_at = 1,
        .sessions = &.{.{
            .provider = "claude",
            .source_id = "local",
            .session_id = "s1",
            .project = "phantty",
            .title = "t",
            .message_count_new = 2,
        }},
    };
    try writeDaily(allocator, root, daily);
    try writeDaily(allocator, root, daily); // idempotent overwrite

    const bytes = try tmp.dir.readFileAlloc(allocator, "daily/2026-07-07.json", 1 << 20);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"session_id\": \"s1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"schema_version\": 1") != null);
}

test "memory_digest_store: writeIndex lands at root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try writeIndex(allocator, root, .{
        .generated_at = 1,
        .days = &.{"2026-07-07"},
        .projects = &.{.{ .slug = "phantty", .last_active = "2026-07-07", .session_count = 3 }},
    });
    const bytes = try tmp.dir.readFileAlloc(allocator, "index.json", 1 << 20);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"phantty\"") != null);
}
