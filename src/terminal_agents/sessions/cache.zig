const std = @import("std");
const types = @import("types.zig");
const platform_atomic_file = @import("../../platform/atomic_file.zig");
const platform_dirs = @import("../../platform/dirs.zig");

const MAX_CACHE_BYTES = 16 * 1024 * 1024;

pub const FileStamp = struct {
    size: u64,
    mtime_ns: i128,
};

pub const CacheRecord = struct {
    source_id: []const u8,
    provider: types.ProviderId,
    root_path: []const u8,
    source_path: []const u8,
    stamp: FileStamp,
    meta: types.SessionMeta,
};

pub const CacheFile = struct {
    version: u32 = 1,
    records: []CacheRecord = &.{},
};

pub fn stampMatches(record: CacheRecord, stamp: FileStamp) bool {
    return record.stamp.size == stamp.size and record.stamp.mtime_ns == stamp.mtime_ns;
}

pub fn dump(allocator: std.mem.Allocator, cache: CacheFile) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, cache, .{});
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(CacheFile) {
    // `.alloc_always` makes the parse copy every string into its own arena.
    // The default for slice input is `.alloc_if_needed`, which aliases `bytes`
    // for escape-free strings; loadFromPath frees `bytes`, leaving those slices
    // (e.g. record.source_id) dangling and crashing findRecord later.
    return std.json.parseFromSlice(CacheFile, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn defaultPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.aiHistoryCachePath(allocator);
}

pub fn loadDefault(allocator: std.mem.Allocator) !std.json.Parsed(CacheFile) {
    const path = try defaultPath(allocator);
    defer allocator.free(path);
    return loadFromPath(allocator, path);
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(CacheFile) {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_CACHE_BYTES) catch |err| switch (err) {
        error.FileNotFound => return try load(allocator, "{\"version\":1,\"records\":[]}"),
        else => return err,
    };
    defer allocator.free(bytes);
    return try load(allocator, bytes);
}

pub fn saveToPath(allocator: std.mem.Allocator, path: []const u8, cache: CacheFile) !void {
    const json = try dump(allocator, cache);
    defer allocator.free(json);

    try platform_atomic_file.writeFileReplaceSafe(path, json);
}

pub fn saveDefault(allocator: std.mem.Allocator, cache: CacheFile) !void {
    const path = try defaultPath(allocator);
    defer allocator.free(path);
    try saveToPath(allocator, path, cache);
}

pub fn findRecord(cache: CacheFile, source_id: []const u8, provider: types.ProviderId, source_path: []const u8, stamp: FileStamp) ?CacheRecord {
    for (cache.records) |record| {
        if (record.provider == provider and
            std.mem.eql(u8, record.source_id, source_id) and
            std.mem.eql(u8, record.source_path, source_path) and
            stampMatches(record, stamp))
        {
            return record;
        }
    }
    return null;
}

pub fn cloneRecord(allocator: std.mem.Allocator, record: CacheRecord) !CacheRecord {
    var cloned: CacheRecord = .{
        .source_id = "",
        .provider = record.provider,
        .root_path = "",
        .source_path = "",
        .stamp = record.stamp,
        .meta = .{
            .provider = record.meta.provider,
            .session_id = "",
            .title = "",
            .summary = "",
            .project_dir = "",
            .created_at_ms = record.meta.created_at_ms,
            .last_active_at_ms = record.meta.last_active_at_ms,
            .source_path = "",
            .resume_kind = record.meta.resume_kind,
            .message_count = record.meta.message_count,
            .scan_status = record.meta.scan_status,
        },
    };
    errdefer freeRecord(allocator, &cloned);

    cloned.source_id = try allocator.dupe(u8, record.source_id);
    cloned.root_path = try allocator.dupe(u8, record.root_path);
    cloned.source_path = try allocator.dupe(u8, record.source_path);
    cloned.meta.session_id = try allocator.dupe(u8, record.meta.session_id);
    cloned.meta.title = try allocator.dupe(u8, record.meta.title);
    cloned.meta.summary = try allocator.dupe(u8, record.meta.summary);
    cloned.meta.project_dir = try allocator.dupe(u8, record.meta.project_dir);
    cloned.meta.source_path = try allocator.dupe(u8, record.meta.source_path);
    return cloned;
}

pub fn freeRecord(allocator: std.mem.Allocator, record: *CacheRecord) void {
    if (record.source_id.len > 0) allocator.free(record.source_id);
    if (record.root_path.len > 0) allocator.free(record.root_path);
    if (record.source_path.len > 0) allocator.free(record.source_path);
    if (record.meta.session_id.len > 0) allocator.free(record.meta.session_id);
    if (record.meta.title.len > 0) allocator.free(record.meta.title);
    if (record.meta.summary.len > 0) allocator.free(record.meta.summary);
    if (record.meta.project_dir.len > 0) allocator.free(record.meta.project_dir);
    if (record.meta.source_path.len > 0) allocator.free(record.meta.source_path);
    record.* = undefined;
}

pub fn freeRecords(allocator: std.mem.Allocator, records: []CacheRecord) void {
    for (records) |*record| freeRecord(allocator, record);
    allocator.free(records);
}

test "ai_history_cache: cache stamp matches only exact size and mtime" {
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    const record: CacheRecord = .{
        .source_id = "local",
        .provider = .codex,
        .root_path = "/home/me/.codex",
        .source_path = "/home/me/.codex/sessions/a.jsonl",
        .stamp = .{ .size = 10, .mtime_ns = 20 },
        .meta = meta,
    };
    try std.testing.expect(stampMatches(record, .{ .size = 10, .mtime_ns = 20 }));
    try std.testing.expect(!stampMatches(record, .{ .size = 11, .mtime_ns = 20 }));
    try std.testing.expect(!stampMatches(record, .{ .size = 10, .mtime_ns = 21 }));
}

test "ai_history_cache: json round trip keeps metadata only" {
    const allocator = std.testing.allocator;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    const records = [_]CacheRecord{.{
        .source_id = "local",
        .provider = .codex,
        .root_path = "/home/me/.codex",
        .source_path = "/home/me/.codex/sessions/a.jsonl",
        .stamp = .{ .size = 10, .mtime_ns = 20 },
        .meta = meta,
    }};
    const json = try dump(allocator, .{ .records = @constCast(&records) });
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "transcript") == null);
    var parsed = try load(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc", parsed.value.records[0].meta.session_id);
}

test "ai_history_cache: parsed records own their strings after source bytes freed" {
    const allocator = std.testing.allocator;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "/home/me/.codex/sessions/a.jsonl",
        .resume_kind = .codex_resume,
    };
    const records = [_]CacheRecord{.{
        .source_id = "local-history",
        .provider = .codex,
        .root_path = "/home/me/.codex",
        .source_path = "/home/me/.codex/sessions/a.jsonl",
        .stamp = .{ .size = 10, .mtime_ns = 20 },
        .meta = meta,
    }};

    // Mirror loadFromPath: build the on-disk JSON into a heap buffer, parse it,
    // then free the buffer. The parse must NOT alias `bytes`, otherwise the
    // returned record strings dangle (the crash in findRecord).
    const bytes = try dump(allocator, .{ .records = @constCast(&records) });

    var parsed = try load(allocator, bytes);
    defer parsed.deinit();

    const buf_start = @intFromPtr(bytes.ptr);
    const buf_end = buf_start + bytes.len;
    const sid = @intFromPtr(parsed.value.records[0].source_id.ptr);
    try std.testing.expect(sid < buf_start or sid >= buf_end);

    allocator.free(bytes);

    try std.testing.expectEqualStrings("local-history", parsed.value.records[0].source_id);
    try std.testing.expect(findRecord(parsed.value, "local-history", .codex, "/home/me/.codex/sessions/a.jsonl", .{ .size = 10, .mtime_ns = 20 }) != null);
}

test "ai_history_cache: finds records by source path and stamp" {
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "/home/me/.codex/sessions/a.jsonl",
        .resume_kind = .codex_resume,
    };
    const records = [_]CacheRecord{.{
        .source_id = "local",
        .provider = .codex,
        .root_path = "/home/me/.codex",
        .source_path = "/home/me/.codex/sessions/a.jsonl",
        .stamp = .{ .size = 10, .mtime_ns = 20 },
        .meta = meta,
    }};
    const cache: CacheFile = .{ .records = @constCast(&records) };
    try std.testing.expect(findRecord(cache, "local", .codex, "/home/me/.codex/sessions/a.jsonl", .{ .size = 10, .mtime_ns = 20 }) != null);
    try std.testing.expect(findRecord(cache, "local", .codex, "/home/me/.codex/sessions/a.jsonl", .{ .size = 11, .mtime_ns = 20 }) == null);
}
