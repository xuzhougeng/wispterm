//! JSON artifact writes for the memory digest (spec §9). M1 writes the
//! daily raw-session listing and the index; LLM summary fields arrive in
//! M2. Everything goes through atomic replace so a crash never leaves a
//! half-written artifact.
const std = @import("std");
const atomic_file = @import("../platform/atomic_file.zig");

pub const SCHEMA_VERSION: u32 = 1;

pub const Artifact = struct { type: []const u8, ref: []const u8 };

pub const DailySession = struct {
    provider: []const u8,
    source_id: []const u8,
    session_id: []const u8,
    project: []const u8,
    title: []const u8,
    message_count_new: u32,
    summary: []const u8 = "",
    topics: []const []const u8 = &.{},
    outcome: []const u8 = "unknown",
    artifacts: []const Artifact = &.{},
    source_file: []const u8 = "",
};

pub const DailyProject = struct { slug: []const u8, summary: []const u8, session_refs: []const []const u8 = &.{} };

pub const Daily = struct {
    schema_version: u32 = SCHEMA_VERSION,
    date: []const u8, // "2026-07-07"
    generated_at: i64,
    sessions: []const DailySession = &.{},
    model: []const u8 = "",
    projects: []const DailyProject = &.{},
    highlights: []const []const u8 = &.{},
};

pub const IndexProject = struct {
    slug: []const u8,
    name: []const u8,
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

pub const TimelineEvent = struct { type: []const u8, text: []const u8, refs: []const []const u8 = &.{} };
pub const TimelineEntry = struct { date: []const u8, summary: []const u8, events: []const TimelineEvent = &.{}, session_refs: []const []const u8 = &.{} };

fn projectDir(gpa: std.mem.Allocator, memory_root: []const u8, slug: []const u8) ![]const u8 {
    return std.fs.path.join(gpa, &.{ memory_root, "projects", slug });
}

/// Read `projects/<slug>/timeline.json` (missing/corrupt → empty), replace or
/// append the entry for `entry.date`, sort entries date-descending, and write
/// back atomically. Mirrors mergeDailyWithExisting's lenient-readback shape.
pub fn upsertTimelineEntry(gpa: std.mem.Allocator, memory_root: []const u8, slug: []const u8, entry: TimelineEntry) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try projectDir(arena, memory_root, slug);
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(arena, &.{ dir, "timeline.json" });

    const FileShape = struct {
        schema_version: u32 = SCHEMA_VERSION,
        slug: []const u8 = "",
        entries: []const TimelineEntry = &.{},
    };

    var existing: []const TimelineEntry = &.{};
    if (std.fs.cwd().readFileAlloc(arena, path, 16 * 1024 * 1024)) |bytes| {
        if (std.json.parseFromSlice(FileShape, arena, bytes, .{
            .ignore_unknown_fields = true,
        })) |parsed| {
            existing = parsed.value.entries; // arena-owned; no deinit needed
        } else |_| {}
    } else |_| {}

    var merged: std.ArrayListUnmanaged(TimelineEntry) = .empty;
    var replaced = false;
    for (existing) |old| {
        if (std.mem.eql(u8, old.date, entry.date)) {
            try merged.append(arena, entry);
            replaced = true;
        } else {
            try merged.append(arena, old);
        }
    }
    if (!replaced) try merged.append(arena, entry);

    std.mem.sort(TimelineEntry, merged.items, {}, struct {
        fn desc(_: void, a: TimelineEntry, b: TimelineEntry) bool {
            return std.mem.order(u8, a.date, b.date) == .gt;
        }
    }.desc);

    try writeJson(gpa, path, FileShape{ .slug = slug, .entries = merged.items });
}

pub const Project = struct {
    schema_version: u32 = SCHEMA_VERSION,
    slug: []const u8,
    name: []const u8,
    paths: []const []const u8 = &.{},
    aliases: []const []const u8 = &.{},
    first_seen: []const u8,
    last_active: []const u8,
};

/// Read `projects/<slug>/project.json` (missing → new record), append
/// `project_path` to `paths` if non-empty and not already present, extend
/// `first_seen`/`last_active` to cover `date`, and write back atomically.
pub fn upsertProject(gpa: std.mem.Allocator, memory_root: []const u8, slug: []const u8, project_path: []const u8, date: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try projectDir(arena, memory_root, slug);
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(arena, &.{ dir, "project.json" });

    var proj: Project = .{
        .slug = slug,
        .name = slug,
        .first_seen = date,
        .last_active = date,
    };
    if (std.fs.cwd().readFileAlloc(arena, path, 16 * 1024 * 1024)) |bytes| {
        if (std.json.parseFromSlice(Project, arena, bytes, .{
            .ignore_unknown_fields = true,
        })) |parsed| {
            proj = parsed.value; // arena-owned; no deinit needed
        } else |_| {}
    } else |_| {}

    if (project_path.len != 0) {
        const already = for (proj.paths) |p| {
            if (std.mem.eql(u8, p, project_path)) break true;
        } else false;
        if (!already) {
            var paths = try arena.alloc([]const u8, proj.paths.len + 1);
            @memcpy(paths[0..proj.paths.len], proj.paths);
            paths[proj.paths.len] = project_path;
            proj.paths = paths;
        }
    }
    if (std.mem.order(u8, date, proj.last_active) == .gt) proj.last_active = date;
    if (std.mem.order(u8, date, proj.first_seen) == .lt) proj.first_seen = date;

    try writeJson(gpa, path, proj);
}

/// Same read/extend/write shape as `upsertProject`, but for a remote session
/// (spec M3 Task 3): `alias` (typically "{source_id}:{project_path}") is
/// appended to `aliases` instead of `paths`, since a remote host's raw path
/// has no meaning as a local filesystem path on this machine.
pub fn upsertProjectAlias(gpa: std.mem.Allocator, memory_root: []const u8, slug: []const u8, alias: []const u8, date: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try projectDir(arena, memory_root, slug);
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(arena, &.{ dir, "project.json" });

    var proj: Project = .{
        .slug = slug,
        .name = slug,
        .first_seen = date,
        .last_active = date,
    };
    if (std.fs.cwd().readFileAlloc(arena, path, 16 * 1024 * 1024)) |bytes| {
        if (std.json.parseFromSlice(Project, arena, bytes, .{
            .ignore_unknown_fields = true,
        })) |parsed| {
            proj = parsed.value; // arena-owned; no deinit needed
        } else |_| {}
    } else |_| {}

    if (alias.len != 0) {
        const already = for (proj.aliases) |a| {
            if (std.mem.eql(u8, a, alias)) break true;
        } else false;
        if (!already) {
            var aliases = try arena.alloc([]const u8, proj.aliases.len + 1);
            @memcpy(aliases[0..proj.aliases.len], proj.aliases);
            aliases[proj.aliases.len] = alias;
            proj.aliases = aliases;
        }
    }
    if (std.mem.order(u8, date, proj.last_active) == .gt) proj.last_active = date;
    if (std.mem.order(u8, date, proj.first_seen) == .lt) proj.first_seen = date;

    try writeJson(gpa, path, proj);
}

pub const SourceStatus = struct {
    source_id: []const u8,
    status: []const u8 = "ok", // "ok" | "skipped" | "failed"
    detail: []const u8 = "",
    sessions_collected: u32 = 0,
};

pub const RunRecord = struct {
    started_at: i64,
    finished_at: i64 = 0,
    status: []const u8 = "ok", // "ok" | "partial" | "failed"
    sources: []const SourceStatus = &.{},
    sessions_summarized: u32 = 0,
    sessions_failed: u32 = 0,
    llm_calls: u32 = 0,
    // M5 Task 1 B.2: cumulative LLM token usage for the run (additive,
    // schema-compatible — old runs.json entries parse fine with these at 0).
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
};

const MAX_RUNS_STORE_BYTES = 16 * 1024 * 1024;
const MAX_RUNS_KEPT = 60;

/// Read `state/runs.json` (missing/corrupt → empty), append `rec`, keep only
/// the most recent MAX_RUNS_KEPT entries, and write back atomically. Mirrors
/// SummaryStore's lenient-readback shape.
pub fn appendRunRecord(gpa: std.mem.Allocator, memory_root: []const u8, rec: RunRecord) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try std.fs.path.join(arena, &.{ memory_root, "state" });
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(arena, &.{ dir, "runs.json" });

    const FileShape = struct {
        schema_version: u32 = SCHEMA_VERSION,
        runs: []const RunRecord = &.{},
    };

    var existing: []const RunRecord = &.{};
    if (std.fs.cwd().readFileAlloc(arena, path, MAX_RUNS_STORE_BYTES)) |bytes| {
        if (std.json.parseFromSlice(FileShape, arena, bytes, .{
            .ignore_unknown_fields = true,
        })) |parsed| {
            existing = parsed.value.runs; // arena-owned; no deinit needed
        } else |_| {}
    } else |_| {}

    var runs: std.ArrayListUnmanaged(RunRecord) = .empty;
    try runs.appendSlice(arena, existing);
    try runs.append(arena, rec);

    const items = if (runs.items.len > MAX_RUNS_KEPT)
        runs.items[runs.items.len - MAX_RUNS_KEPT ..]
    else
        runs.items;

    try writeJson(gpa, path, FileShape{ .runs = items });
}

const MAX_SUMMARY_STORE_BYTES = 16 * 1024 * 1024;

pub const SummaryRecord = struct {
    key: []const u8, // "provider:session_id"
    date: []const u8,
    summary: []const u8,
    topics: []const []const u8 = &.{},
    outcome: []const u8 = "unknown",
    artifacts: []const Artifact = &.{},
};

/// Per-session LLM summaries, keyed by "provider:session_id" (spec §8).
/// Mirrors cursors.Set: arena-backed, lenient load, atomic save.
pub const SummaryStore = struct {
    arena: std.heap.ArenaAllocator,
    records: std.ArrayListUnmanaged(SummaryRecord) = .empty,

    pub fn init(gpa: std.mem.Allocator) SummaryStore {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *SummaryStore) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *SummaryStore, key: []const u8) ?*SummaryRecord {
        for (self.records.items) |*r| {
            if (std.mem.eql(u8, r.key, key)) return r;
        }
        return null;
    }

    /// Overwrite the record for `rec.key`, or append if new. Fields are
    /// duped into the store's arena so callers can free their originals.
    pub fn put(self: *SummaryStore, rec: SummaryRecord) !void {
        const alloc = self.arena.allocator();
        const topics = try alloc.alloc([]const u8, rec.topics.len);
        for (rec.topics, 0..) |t, i| topics[i] = try alloc.dupe(u8, t);
        const artifacts = try alloc.alloc(Artifact, rec.artifacts.len);
        for (rec.artifacts, 0..) |a, i| {
            artifacts[i] = .{ .type = try alloc.dupe(u8, a.type), .ref = try alloc.dupe(u8, a.ref) };
        }
        const duped: SummaryRecord = .{
            .key = try alloc.dupe(u8, rec.key),
            .date = try alloc.dupe(u8, rec.date),
            .summary = try alloc.dupe(u8, rec.summary),
            .topics = topics,
            .outcome = try alloc.dupe(u8, rec.outcome),
            .artifacts = artifacts,
        };
        if (self.find(rec.key)) |existing| {
            existing.* = duped;
            return;
        }
        try self.records.append(alloc, duped);
    }

    pub fn loadFromPath(gpa: std.mem.Allocator, path: []const u8) !SummaryStore {
        var store = SummaryStore.init(gpa);
        errdefer store.deinit();
        const bytes = std.fs.cwd().readFileAlloc(gpa, path, MAX_SUMMARY_STORE_BYTES) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer gpa.free(bytes);
        const FileShape = struct {
            schema_version: u32 = SCHEMA_VERSION,
            records: []const SummaryRecord = &.{},
        };
        // Corrupt file → start fresh rather than wedging every run.
        const parsed = std.json.parseFromSlice(FileShape, gpa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return store;
        defer parsed.deinit();
        for (parsed.value.records) |r| {
            try store.put(r);
        }
        return store;
    }

    pub fn saveToPath(self: *SummaryStore, gpa: std.mem.Allocator, path: []const u8) !void {
        const FileShape = struct {
            schema_version: u32 = SCHEMA_VERSION,
            records: []const SummaryRecord,
        };
        try writeJson(gpa, path, FileShape{ .records = self.records.items });
    }
};

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
        .projects = &.{.{ .slug = "phantty", .name = "phantty", .last_active = "2026-07-07", .session_count = 3 }},
    });
    const bytes = try tmp.dir.readFileAlloc(allocator, "index.json", 1 << 20);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"phantty\"") != null);
}

test "memory_digest_store: upsertTimelineEntry creates, appends, then replaces in place" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try upsertTimelineEntry(allocator, root, "phantty", .{ .date = "2026-07-07", .summary = "day one" });
    try upsertTimelineEntry(allocator, root, "phantty", .{ .date = "2026-07-08", .summary = "day two" });

    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "projects/phantty/timeline.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(struct {
            slug: []const u8 = "",
            entries: []const TimelineEntry = &.{},
        }, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("phantty", parsed.value.slug);
        try std.testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
        // Newest date first.
        try std.testing.expectEqualStrings("2026-07-08", parsed.value.entries[0].date);
        try std.testing.expectEqualStrings("2026-07-07", parsed.value.entries[1].date);
    }

    // Replay the first date with a new summary: must replace, not duplicate.
    try upsertTimelineEntry(allocator, root, "phantty", .{ .date = "2026-07-07", .summary = "day one revised" });
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "projects/phantty/timeline.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(struct {
            entries: []const TimelineEntry = &.{},
        }, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
        try std.testing.expectEqualStrings("2026-07-08", parsed.value.entries[0].date);
        try std.testing.expectEqualStrings("2026-07-07", parsed.value.entries[1].date);
        try std.testing.expectEqualStrings("day one revised", parsed.value.entries[1].summary);
    }
}

test "memory_digest_store: upsertProject creates then extends paths and active range" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try upsertProject(allocator, root, "phantty", "/home/me/phantty", "2026-07-05");
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "projects/phantty/project.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Project, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("phantty", parsed.value.name);
        try std.testing.expectEqual(@as(usize, 1), parsed.value.paths.len);
        try std.testing.expectEqualStrings("/home/me/phantty", parsed.value.paths[0]);
        try std.testing.expectEqualStrings("2026-07-05", parsed.value.first_seen);
        try std.testing.expectEqualStrings("2026-07-05", parsed.value.last_active);
    }

    // Second call: new path (ssh alias) + later date → paths grows, last_active advances.
    try upsertProject(allocator, root, "phantty", "ssh:hk:/root/phantty", "2026-07-07");
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "projects/phantty/project.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Project, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 2), parsed.value.paths.len);
        try std.testing.expectEqualStrings("2026-07-05", parsed.value.first_seen);
        try std.testing.expectEqualStrings("2026-07-07", parsed.value.last_active);
    }

    // Earlier date → first_seen moves back; same path is not duplicated.
    try upsertProject(allocator, root, "phantty", "/home/me/phantty", "2026-07-01");
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "projects/phantty/project.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Project, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 2), parsed.value.paths.len);
        try std.testing.expectEqualStrings("2026-07-01", parsed.value.first_seen);
        try std.testing.expectEqualStrings("2026-07-07", parsed.value.last_active);
    }
}

test "memory_digest_store: upsertProjectAlias creates then dedupes aliases, extends active range" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try upsertProjectAlias(allocator, root, "phantty", "ssh:hk:/root/phantty", "2026-07-05");
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "projects/phantty/project.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Project, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 0), parsed.value.paths.len);
        try std.testing.expectEqual(@as(usize, 1), parsed.value.aliases.len);
        try std.testing.expectEqualStrings("ssh:hk:/root/phantty", parsed.value.aliases[0]);
        try std.testing.expectEqualStrings("2026-07-05", parsed.value.first_seen);
    }

    // New alias + later date -> aliases grows, last_active advances.
    try upsertProjectAlias(allocator, root, "phantty", "ssh:box2:/home/me/phantty", "2026-07-07");
    // Same alias again -> not duplicated.
    try upsertProjectAlias(allocator, root, "phantty", "ssh:hk:/root/phantty", "2026-07-06");
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "projects/phantty/project.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Project, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 0), parsed.value.paths.len);
        try std.testing.expectEqual(@as(usize, 2), parsed.value.aliases.len);
        try std.testing.expectEqualStrings("2026-07-05", parsed.value.first_seen);
        try std.testing.expectEqualStrings("2026-07-07", parsed.value.last_active);
    }
}

test "memory_digest_store: SummaryStore put overwrites by key" {
    var store = SummaryStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put(.{ .key = "claude:s1", .date = "2026-07-07", .summary = "first" });
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);

    try store.put(.{ .key = "claude:s1", .date = "2026-07-08", .summary = "second", .outcome = "completed" });
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    const rec = store.find("claude:s1").?;
    try std.testing.expectEqualStrings("second", rec.summary);
    try std.testing.expectEqualStrings("completed", rec.outcome);

    try store.put(.{ .key = "codex:s2", .date = "2026-07-08", .summary = "other" });
    try std.testing.expectEqual(@as(usize, 2), store.records.items.len);
}

test "memory_digest_store: SummaryStore save and load roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "session_summaries.json" });
    defer allocator.free(path);

    var store = SummaryStore.init(allocator);
    defer store.deinit();
    try store.put(.{
        .key = "claude:s1",
        .date = "2026-07-07",
        .summary = "did the thing",
        .topics = &.{ "memory", "design" },
        .outcome = "completed",
        .artifacts = &.{.{ .type = "pr", .ref = "511" }},
    });
    try store.saveToPath(allocator, path);

    var loaded = try SummaryStore.loadFromPath(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.records.items.len);
    const rec = loaded.find("claude:s1").?;
    try std.testing.expectEqualStrings("did the thing", rec.summary);
    try std.testing.expectEqual(@as(usize, 2), rec.topics.len);
    try std.testing.expectEqualStrings("pr", rec.artifacts[0].type);
}

test "memory_digest_store: appendRunRecord creates, appends, then truncates to 60" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try appendRunRecord(allocator, root, .{ .started_at = 1, .status = "ok" });
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "state/runs.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(struct {
            runs: []const RunRecord = &.{},
        }, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.runs.len);
        try std.testing.expectEqual(@as(i64, 1), parsed.value.runs[0].started_at);
    }

    try appendRunRecord(allocator, root, .{ .started_at = 2, .status = "failed" });
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "state/runs.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(struct {
            runs: []const RunRecord = &.{},
        }, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 2), parsed.value.runs.len);
        try std.testing.expectEqual(@as(i64, 1), parsed.value.runs[0].started_at);
        try std.testing.expectEqual(@as(i64, 2), parsed.value.runs[1].started_at);
    }

    // Append 59 more (total 61) → must truncate to the most recent 60, i.e.
    // started_at values 2..61 (the very first record, started_at=1, drops).
    var i: i64 = 3;
    while (i <= 61) : (i += 1) {
        try appendRunRecord(allocator, root, .{ .started_at = i, .status = "ok" });
    }
    {
        const bytes = try tmp.dir.readFileAlloc(allocator, "state/runs.json", 1 << 20);
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(struct {
            runs: []const RunRecord = &.{},
        }, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 60), parsed.value.runs.len);
        try std.testing.expectEqual(@as(i64, 2), parsed.value.runs[0].started_at);
        try std.testing.expectEqual(@as(i64, 61), parsed.value.runs[parsed.value.runs.len - 1].started_at);
    }
}

test "memory_digest_store: appendRunRecord round-trips token usage fields" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try appendRunRecord(allocator, root, .{
        .started_at = 1,
        .status = "ok",
        .prompt_tokens = 123,
        .completion_tokens = 45,
        .total_tokens = 168,
    });

    const bytes = try tmp.dir.readFileAlloc(allocator, "state/runs.json", 1 << 20);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(struct {
        runs: []const RunRecord = &.{},
    }, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.runs.len);
    try std.testing.expectEqual(@as(u64, 123), parsed.value.runs[0].prompt_tokens);
    try std.testing.expectEqual(@as(u64, 45), parsed.value.runs[0].completion_tokens);
    try std.testing.expectEqual(@as(u64, 168), parsed.value.runs[0].total_tokens);

    // A record with no usage set (M1-era stub path) defaults to 0 — schema
    // compatibility with pre-M5 runs.json entries missing these fields.
    try appendRunRecord(allocator, root, .{ .started_at = 2, .status = "ok" });
    const bytes2 = try tmp.dir.readFileAlloc(allocator, "state/runs.json", 1 << 20);
    defer allocator.free(bytes2);
    const parsed2 = try std.json.parseFromSlice(struct {
        runs: []const RunRecord = &.{},
    }, allocator, bytes2, .{ .ignore_unknown_fields = true });
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(u64, 0), parsed2.value.runs[1].total_tokens);
}

test "memory_digest_store: appendRunRecord rebuilds from a corrupt runs.json" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try tmp.dir.makePath("state");
    try tmp.dir.writeFile(.{ .sub_path = "state/runs.json", .data = "{\"schema_version\":1,\"runs\":[{brok" });

    try appendRunRecord(allocator, root, .{ .started_at = 42, .status = "ok" });

    const bytes = try tmp.dir.readFileAlloc(allocator, "state/runs.json", 1 << 20);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(struct {
        runs: []const RunRecord = &.{},
    }, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.runs.len);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.runs[0].started_at);
}

test "memory_digest_store: SummaryStore missing or corrupt file loads empty" {
    const allocator = std.testing.allocator;
    var missing = try SummaryStore.loadFromPath(allocator, "/nonexistent/session_summaries.json");
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.records.items.len);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "session_summaries.json" });
    defer allocator.free(path);

    try tmp.dir.writeFile(.{ .sub_path = "session_summaries.json", .data = "{\"schema_version\":1,\"records\":[{brok" });
    var corrupt = try SummaryStore.loadFromPath(allocator, path);
    defer corrupt.deinit();
    try std.testing.expectEqual(@as(usize, 0), corrupt.records.items.len);
}

test "memory_digest_store: DailySession source_file round-trips and defaults for old json" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    try writeDaily(a, root, .{
        .date = "2026-07-09",
        .generated_at = 1,
        .sessions = &.{.{
            .provider = "claude",
            .source_id = "ssh:CPU2",
            .session_id = "aaa-111",
            .project = "rnaseq",
            .title = "t",
            .message_count_new = 3,
            .source_file = "/root/.claude/projects/-root-rnaseq/aaa-111.jsonl",
        }},
    });

    const path = try std.fs.path.join(a, &.{ root, "daily", "2026-07-09.json" });
    defer a.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(a, path, 1 << 20);
    defer a.free(bytes);
    var parsed = try std.json.parseFromSlice(Daily, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "/root/.claude/projects/-root-rnaseq/aaa-111.jsonl",
        parsed.value.sessions[0].source_file,
    );

    // 旧格式（无 source_file 字段）解析回默认空串。
    const old_json =
        \\{"schema_version":1,"date":"2026-07-08","generated_at":1,"sessions":[{"provider":"codex","source_id":"local","session_id":"b","project":"p","title":"t","message_count_new":1}]}
    ;
    var old_parsed = try std.json.parseFromSlice(Daily, a, old_json, .{ .ignore_unknown_fields = true });
    defer old_parsed.deinit();
    try std.testing.expectEqualStrings("", old_parsed.value.sessions[0].source_file);
}
