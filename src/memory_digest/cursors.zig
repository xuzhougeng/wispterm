//! Incremental scan cursors (spec §6): one entry per (source, provider,
//! file) recording FileStamp(size+mtime_ns) plus how many transcript
//! messages have been processed. The on-disk file only advances after
//! artifacts were written — run.zig saves at the end of a successful run.
const std = @import("std");
const atomic_file = @import("../platform/atomic_file.zig");
const types = @import("types.zig");

const MAX_CURSOR_BYTES = 16 * 1024 * 1024;

pub const Entry = struct {
    source_id: []const u8,
    provider: types.DigestProvider,
    file: []const u8,
    size: u64 = 0,
    mtime_ns: i128 = 0,
    processed_messages: u32 = 0,
};

const FileShape = struct {
    schema_version: u32 = 1,
    entries: []const Entry = &.{},
};

pub const Set = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) Set {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Set) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn find(self: *Set, source_id: []const u8, provider: types.DigestProvider, file: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.provider == provider and
                std.mem.eql(u8, e.source_id, source_id) and
                std.mem.eql(u8, e.file, file)) return e;
        }
        return null;
    }

    /// null → stamp unchanged, skip the file. Otherwise how many messages
    /// were already processed (0 for unseen files).
    pub fn pendingFrom(self: *Set, source_id: []const u8, provider: types.DigestProvider, file: []const u8, size: u64, mtime_ns: i128) ?u32 {
        const e = self.find(source_id, provider, file) orelse return 0;
        if (e.size == size and e.mtime_ns == mtime_ns) return null;
        return e.processed_messages;
    }

    pub fn update(self: *Set, source_id: []const u8, provider: types.DigestProvider, file: []const u8, size: u64, mtime_ns: i128, processed_messages: u32) !void {
        if (self.find(source_id, provider, file)) |e| {
            e.size = size;
            e.mtime_ns = mtime_ns;
            e.processed_messages = processed_messages;
            return;
        }
        const alloc = self.arena.allocator();
        try self.entries.append(alloc, .{
            .source_id = try alloc.dupe(u8, source_id),
            .provider = provider,
            .file = try alloc.dupe(u8, file),
            .size = size,
            .mtime_ns = mtime_ns,
            .processed_messages = processed_messages,
        });
    }

    pub fn loadFromPath(gpa: std.mem.Allocator, path: []const u8) !Set {
        var set = Set.init(gpa);
        errdefer set.deinit();
        const bytes = std.fs.cwd().readFileAlloc(gpa, path, MAX_CURSOR_BYTES) catch |err| switch (err) {
            error.FileNotFound => return set,
            else => return err,
        };
        defer gpa.free(bytes);
        // Corrupt cursor file → start fresh rather than wedging every run.
        const parsed = std.json.parseFromSlice(FileShape, gpa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return set;
        defer parsed.deinit();
        for (parsed.value.entries) |e| {
            try set.update(e.source_id, e.provider, e.file, e.size, e.mtime_ns, e.processed_messages);
        }
        return set;
    }

    pub fn saveToPath(self: *Set, gpa: std.mem.Allocator, path: []const u8) !void {
        const shape: FileShape = .{ .entries = self.entries.items };
        const json = try std.json.Stringify.valueAlloc(gpa, shape, .{});
        defer gpa.free(json);
        try atomic_file.writeFileReplaceSafe(path, json);
    }
};

test "memory_digest_cursors: unseen file starts at zero, unchanged stamp skips" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    try std.testing.expectEqual(@as(?u32, 0), set.pendingFrom("local", .claude, "/a.jsonl", 10, 100));
    try set.update("local", .claude, "/a.jsonl", 10, 100, 5);
    try std.testing.expectEqual(@as(?u32, null), set.pendingFrom("local", .claude, "/a.jsonl", 10, 100));
    try std.testing.expectEqual(@as(?u32, 5), set.pendingFrom("local", .claude, "/a.jsonl", 12, 101));
}

test "memory_digest_cursors: keys distinguish provider and file" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    try set.update("local", .claude, "/a.jsonl", 10, 100, 5);
    try std.testing.expectEqual(@as(?u32, 0), set.pendingFrom("local", .codex, "/a.jsonl", 10, 100));
    try std.testing.expectEqual(@as(?u32, 0), set.pendingFrom("ssh:hk", .claude, "/a.jsonl", 10, 100));
}

test "memory_digest_cursors: save and load roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const file = try std.fs.path.join(std.testing.allocator, &.{ path, "cursors.json" });
    defer std.testing.allocator.free(file);

    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    try set.update("local", .wispterm, "/s.json", 42, 7_000_000_000, 3);
    try set.saveToPath(std.testing.allocator, file);

    var loaded = try Set.loadFromPath(std.testing.allocator, file);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(?u32, 3), loaded.pendingFrom("local", .wispterm, "/s.json", 1, 1));
    try std.testing.expectEqual(@as(?u32, null), loaded.pendingFrom("local", .wispterm, "/s.json", 42, 7_000_000_000));
}

test "memory_digest_cursors: missing or corrupt file loads empty" {
    // Test missing file
    var loaded = try Set.loadFromPath(std.testing.allocator, "/nonexistent/cursors.json");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.entries.items.len);

    // Test corrupt JSON
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const file = try std.fs.path.join(std.testing.allocator, &.{ path, "cursors.json" });
    defer std.testing.allocator.free(file);

    try tmp.dir.writeFile(.{ .sub_path = "cursors.json", .data = "{\"schema_version\":1,\"entries\":[{brok" });
    var corrupt = try Set.loadFromPath(std.testing.allocator, file);
    defer corrupt.deinit();
    try std.testing.expectEqual(@as(usize, 0), corrupt.entries.items.len);
}
