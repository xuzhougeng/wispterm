//! Read-only model for the in-app Memory Center.
const std = @import("std");
const agent_memory = @import("agent/memory.zig");
const dirs = @import("platform/dirs.zig");
const digest_store = @import("memory_digest/store.zig");

const MAX_DAILY_BYTES = 16 * 1024 * 1024;

pub const Source = enum {
    remembered,
    digest,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .remembered => "AI Remembered",
            .digest => "Memory Digest",
        };
    }
};

pub const Row = struct {
    source: Source,
    scope: []const u8,
    title: []const u8,
    detail: []const u8,
    body: []const u8,
    sort_key: []const u8,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Snapshot, source: Source) usize {
        var n: usize = 0;
        for (self.rows) |row| {
            if (row.source == source) n += 1;
        }
        return n;
    }

    pub fn rowAt(self: *const Snapshot, source: Source, index: usize) ?*const Row {
        var n: usize = 0;
        for (self.rows) |*row| {
            if (row.source != source) continue;
            if (n == index) return row;
            n += 1;
        }
        return null;
    }
};

pub fn load(gpa: std.mem.Allocator) !Snapshot {
    var snapshot = Snapshot{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer snapshot.arena.deinit();
    const arena = snapshot.arena.allocator();
    var rows: std.ArrayListUnmanaged(Row) = .empty;

    try loadRemembered(gpa, arena, &rows);
    try loadDigest(gpa, arena, &rows);

    std.mem.sort(Row, rows.items, {}, rowDesc);
    snapshot.rows = try rows.toOwnedSlice(arena);
    return snapshot;
}

fn rowDesc(_: void, a: Row, b: Row) bool {
    if (a.source != b.source) return @intFromEnum(a.source) < @intFromEnum(b.source);
    return std.mem.order(u8, a.sort_key, b.sort_key) == .gt;
}

fn appendRememberedRows(arena: std.mem.Allocator, rows: *std.ArrayListUnmanaged(Row), scope: []const u8, entries: []const agent_memory.Entry) !void {
    for (entries) |entry| {
        try rows.append(arena, .{
            .source = .remembered,
            .scope = try arena.dupe(u8, scope),
            .title = try arena.dupe(u8, entry.name),
            .detail = try arena.dupe(u8, entry.description),
            .body = try arena.dupe(u8, entry.body),
            .sort_key = try arena.dupe(u8, entry.updated),
        });
    }
}

fn loadRemembered(gpa: std.mem.Allocator, arena: std.mem.Allocator, rows: *std.ArrayListUnmanaged(Row)) !void {
    const global_dir = try agent_memory.globalDir(gpa);
    defer gpa.free(global_dir);
    const global_entries = try agent_memory.loadDirEntries(gpa, global_dir);
    defer agent_memory.freeEntries(gpa, global_entries);
    try appendRememberedRows(arena, rows, "global", global_entries);

    const memory_root = try dirs.memoryDir(gpa);
    defer gpa.free(memory_root);
    const projects_root = try std.fs.path.join(gpa, &.{ memory_root, "projects" });
    defer gpa.free(projects_root);
    var dir = std.fs.openDirAbsolute(projects_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .directory) continue;
        const project_dir = try std.fs.path.join(gpa, &.{ projects_root, ent.name });
        defer gpa.free(project_dir);
        const entries = try agent_memory.loadDirEntries(gpa, project_dir);
        defer agent_memory.freeEntries(gpa, entries);
        if (entries.len == 0) continue;
        const scope = try std.fmt.allocPrint(arena, "project:{s}", .{ent.name});
        try appendRememberedRows(arena, rows, scope, entries);
    }
}

fn loadDigest(gpa: std.mem.Allocator, arena: std.mem.Allocator, rows: *std.ArrayListUnmanaged(Row)) !void {
    const memory_root = try dirs.memoryDir(gpa);
    defer gpa.free(memory_root);
    const daily_dir = try std.fs.path.join(gpa, &.{ memory_root, "daily" });
    defer gpa.free(daily_dir);
    var dir = std.fs.openDirAbsolute(daily_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".json")) continue;
        const bytes = dir.readFileAlloc(gpa, ent.name, MAX_DAILY_BYTES) catch continue;
        defer gpa.free(bytes);
        const daily = std.json.parseFromSliceLeaky(digest_store.Daily, arena, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch continue;
        try rows.append(arena, .{
            .source = .digest,
            .scope = "daily",
            .title = try arena.dupe(u8, daily.date),
            .detail = try digestDetail(arena, daily),
            .body = try digestBody(arena, daily),
            .sort_key = try arena.dupe(u8, daily.date),
        });
    }
}

fn digestDetail(arena: std.mem.Allocator, daily: digest_store.Daily) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (daily.model.len > 0) {
        const head = try std.fmt.allocPrint(arena, "{d} sessions, {d} projects, {s}", .{ daily.sessions.len, daily.projects.len, daily.model });
        try out.appendSlice(arena, head);
    } else {
        const head = try std.fmt.allocPrint(arena, "{d} sessions, {d} projects", .{ daily.sessions.len, daily.projects.len });
        try out.appendSlice(arena, head);
    }
    const srcs = try digest_store.aggregateSources(arena, daily.sessions);
    for (srcs) |src| {
        const part = try std.fmt.allocPrint(arena, " · {s}×{d}", .{ src.source_id, src.session_count });
        try out.appendSlice(arena, part);
    }
    return out.items;
}

fn digestBody(arena: std.mem.Allocator, daily: digest_store.Daily) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "Highlights\n");
    if (daily.highlights.len == 0) try out.appendSlice(arena, "- (none)\n");
    for (daily.highlights) |h| try appendBullet(arena, &out, h);

    try out.appendSlice(arena, "\nProjects\n");
    if (daily.projects.len == 0) try out.appendSlice(arena, "- (none)\n");
    for (daily.projects) |p| {
        try out.appendSlice(arena, "- ");
        try out.appendSlice(arena, p.slug);
        if (p.summary.len > 0) {
            try out.appendSlice(arena, ": ");
            try out.appendSlice(arena, p.summary);
        }
        try out.append(arena, '\n');
    }

    try out.appendSlice(arena, "\nSessions\n");
    if (daily.sessions.len == 0) try out.appendSlice(arena, "- (none)\n");
    for (daily.sessions) |s| {
        try out.appendSlice(arena, "- [");
        try out.appendSlice(arena, s.source_id);
        try out.appendSlice(arena, " / ");
        try out.appendSlice(arena, s.provider);
        try out.appendSlice(arena, "] ");
        try out.appendSlice(arena, s.title);
        if (s.summary.len > 0) {
            try out.appendSlice(arena, " -- ");
            try out.appendSlice(arena, s.summary);
        }
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

fn appendBullet(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    try out.appendSlice(arena, "- ");
    try out.appendSlice(arena, text);
    try out.append(arena, '\n');
}

test "memory_viewer: snapshot filters rows by source" {
    var snapshot = Snapshot{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer snapshot.deinit();
    const arena = snapshot.arena.allocator();
    snapshot.rows = try arena.dupe(Row, &.{
        .{ .source = .remembered, .scope = "global", .title = "a", .detail = "", .body = "", .sort_key = "2" },
        .{ .source = .digest, .scope = "daily", .title = "b", .detail = "", .body = "", .sort_key = "1" },
    });

    try std.testing.expectEqual(@as(usize, 1), snapshot.count(.remembered));
    try std.testing.expectEqualStrings("b", snapshot.rowAt(.digest, 0).?.title);
    try std.testing.expect(snapshot.rowAt(.digest, 1) == null);
}

test "memory_viewer: digestDetail appends source breakdown" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const daily = digest_store.Daily{
        .date = "2026-07-08",
        .generated_at = 1,
        .sessions = &.{
            .{ .provider = "claude", .source_id = "local", .session_id = "a", .project = "p", .title = "", .message_count_new = 1 },
            .{ .provider = "claude", .source_id = "ssh:CPU", .session_id = "b", .project = "p", .title = "", .message_count_new = 1 },
        },
    };
    const detail = try digestDetail(arena, daily);
    try std.testing.expect(std.mem.indexOf(u8, detail, "local×1") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "ssh:CPU×1") != null);
}
