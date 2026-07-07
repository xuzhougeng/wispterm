//! One digest run (M1, spec §15): collect local sessions, bucket by local
//! day, write daily listings + index, then persist cursors. The cursor file
//! only advances after artifacts were written successfully (spec §6).
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");
const collector = @import("collector.zig");
const cursors_mod = @import("cursors.zig");
const store = @import("store.zig");
const types = @import("types.zig");

pub const Options = struct {
    roots: collector.LocalRoots,
    memory_root: []const u8,
    now_ms: i64,
    tz_offset_seconds: i32 = 0,
    /// 0 = unlimited (tests); default 7 per spec §6/§12.
    backfill_days: u32 = 7,
};

pub const Summary = struct {
    sessions_collected: usize = 0,
    days_written: usize = 0,
};

pub fn runOnce(gpa: std.mem.Allocator, opts: Options) !Summary {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const state_dir = try std.fs.path.join(arena, &.{ opts.memory_root, "state" });
    try std.fs.cwd().makePath(state_dir);
    const cursors_path = try std.fs.path.join(arena, &.{ state_dir, "cursors.json" });

    var cur = try cursors_mod.Set.loadFromPath(gpa, cursors_path);
    defer cur.deinit();

    const min_mtime_ns: i128 = if (opts.backfill_days == 0)
        0
    else
        @as(i128, opts.now_ms) * 1_000_000 - @as(i128, opts.backfill_days) * 86_400_000_000_000;

    var collected = try collector.collectLocal(gpa, opts.roots, &cur, min_mtime_ns);
    defer collected.deinit();

    // Bucket sessions by the local day of their last new activity.
    // ponytail: whole-session bucketing; per-message day slicing is an M2
    // concern together with the LLM stage (spec §11).
    var day_keys: std.ArrayListUnmanaged(u32) = .empty;
    for (collected.sessions) |s| {
        const key = ai_types.dateKeyFromMs(lastActivityMs(s, opts.now_ms), opts.tz_offset_seconds);
        if (std.mem.indexOfScalar(u32, day_keys.items, key) == null) {
            try day_keys.append(arena, key);
        }
    }

    for (day_keys.items) |key| {
        var entries: std.ArrayListUnmanaged(store.DailySession) = .empty;
        for (collected.sessions) |s| {
            if (ai_types.dateKeyFromMs(lastActivityMs(s, opts.now_ms), opts.tz_offset_seconds) != key) continue;
            var slug_buf: [64]u8 = undefined;
            try entries.append(arena, .{
                .provider = @tagName(s.provider),
                .source_id = s.source_id,
                .session_id = s.session_id,
                .project = try arena.dupe(u8, types.projectSlug(s.project_path, &slug_buf)),
                .title = s.title,
                .message_count_new = @intCast(s.new_messages.len),
            });
        }
        var date_buf: [10]u8 = undefined;
        try store.writeDaily(gpa, opts.memory_root, .{
            .date = store.formatDate(key, &date_buf),
            .generated_at = opts.now_ms,
            .sessions = entries.items,
        });
    }

    try writeIndexFromDisk(gpa, arena, opts.memory_root, opts.now_ms);
    try cur.saveToPath(gpa, cursors_path);

    return .{
        .sessions_collected = collected.sessions.len,
        .days_written = day_keys.items.len,
    };
}

fn lastActivityMs(s: types.CollectedSession, fallback_ms: i64) i64 {
    var latest: i64 = 0;
    for (s.new_messages) |m| {
        if (m.timestamp_ms > latest) latest = m.timestamp_ms;
    }
    if (latest == 0) latest = s.ended_at_ms;
    if (latest == 0) latest = fallback_ms;
    return latest;
}

/// Rebuild index.json from the daily files on disk — idempotent by
/// construction, and cheap (daily files are small summaries).
fn writeIndexFromDisk(gpa: std.mem.Allocator, arena: std.mem.Allocator, memory_root: []const u8, now_ms: i64) !void {
    const DailySessionShape = struct { project: []const u8 = "" };
    const DailyShape = struct { sessions: []const DailySessionShape = &.{} };
    const ProjAgg = struct { slug: []const u8, last_active: []const u8, count: u32 };

    var days: std.ArrayListUnmanaged([]const u8) = .empty;
    var projects: std.ArrayListUnmanaged(ProjAgg) = .empty;

    const daily_dir_path = try std.fs.path.join(arena, &.{ memory_root, "daily" });
    var dir = std.fs.cwd().openDir(daily_dir_path, .{ .iterate = true }) catch {
        try store.writeIndex(gpa, memory_root, .{ .generated_at = now_ms, .days = &.{} });
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".json")) continue;
        const date = try arena.dupe(u8, ent.name[0 .. ent.name.len - ".json".len]);
        try days.append(arena, date);
        const bytes = dir.readFileAlloc(arena, ent.name, 16 * 1024 * 1024) catch continue;
        const parsed = std.json.parseFromSlice(DailyShape, arena, bytes, .{
            .ignore_unknown_fields = true,
        }) catch continue; // arena-owned; no deinit needed
        for (parsed.value.sessions) |s| {
            const slug = if (s.project.len == 0) types.UNASSIGNED_SLUG else s.project;
            const agg: ?*ProjAgg = for (projects.items) |*p| {
                if (std.mem.eql(u8, p.slug, slug)) break p;
            } else null;
            if (agg) |p| {
                p.count += 1;
                if (std.mem.order(u8, date, p.last_active) == .gt) p.last_active = date;
            } else {
                try projects.append(arena, .{
                    .slug = try arena.dupe(u8, slug),
                    .last_active = date,
                    .count = 1,
                });
            }
        }
    }

    // Newest day first, matching spec §9's example.
    std.mem.sort([]const u8, days.items, {}, struct {
        fn desc(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.desc);

    const idx_projects = try arena.alloc(store.IndexProject, projects.items.len);
    for (projects.items, 0..) |p, i| {
        idx_projects[i] = .{ .slug = p.slug, .last_active = p.last_active, .session_count = p.count };
    }
    try store.writeIndex(gpa, memory_root, .{
        .generated_at = now_ms,
        .days = days.items,
        .projects = idx_projects,
    });
}

const CLAUDE_JSONL =
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"Fix tests"}}
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the failure."}]}}
    \\
;

const WISPTERM_JSON =
    \\{"session_id":"session-1-1","title":"Copilot","api_key":"sk-SECRET","created_at":1782311875112,"updated_at":1782311885976,
    \\ "messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}
;

test "memory_digest_run: end to end writes daily, index and cursors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try tmp.dir.makePath("claude/proj-a");
    {
        var d = try tmp.dir.openDir("claude/proj-a", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "claude-abc.jsonl", .data = CLAUDE_JSONL });
    }
    try tmp.dir.makePath("wisp");
    {
        var d = try tmp.dir.openDir("wisp", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "session-1-1.json", .data = WISPTERM_JSON });
    }

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const wisp_root = try std.fs.path.join(allocator, &.{ root, "wisp" });
    defer allocator.free(wisp_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    const opts: Options = .{
        .roots = .{ .claude_projects_dir = claude_root, .wispterm_sessions_dir = wisp_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .tz_offset_seconds = 8 * 3600,
        .backfill_days = 0, // unlimited so fixture mtimes always pass
    };

    const first = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 2), first.sessions_collected);
    try std.testing.expect(first.days_written >= 1);

    // Claude fixture messages are 2026-05-31 UTC → daily file exists.
    const daily = try tmp.dir.readFileAlloc(allocator, "memory/daily/2026-05-31.json", 1 << 20);
    defer allocator.free(daily);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"claude-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "\"project\": \"project\"") != null);

    const index = try tmp.dir.readFileAlloc(allocator, "memory/index.json", 1 << 20);
    defer allocator.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "\"2026-05-31\"") != null);

    const cursors = try tmp.dir.readFileAlloc(allocator, "memory/state/cursors.json", 1 << 20);
    defer allocator.free(cursors);
    try std.testing.expect(std.mem.indexOf(u8, cursors, "claude-abc.jsonl") != null);

    // Second run: nothing new, index still valid.
    const second = try runOnce(allocator, opts);
    try std.testing.expectEqual(@as(usize, 0), second.sessions_collected);
    try std.testing.expectEqual(@as(usize, 0), second.days_written);
}

test "memory_digest_run: wispterm session lands in unassigned project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try tmp.dir.makePath("wisp");
    {
        var d = try tmp.dir.openDir("wisp", .{});
        defer d.close();
        try d.writeFile(.{ .sub_path = "session-1-1.json", .data = WISPTERM_JSON });
    }
    const wisp_root = try std.fs.path.join(allocator, &.{ root, "wisp" });
    defer allocator.free(wisp_root);
    const memory_root = try std.fs.path.join(allocator, &.{ root, "memory" });
    defer allocator.free(memory_root);

    _ = try runOnce(allocator, .{
        .roots = .{ .wispterm_sessions_dir = wisp_root },
        .memory_root = memory_root,
        .now_ms = 1783500000000,
        .backfill_days = 0,
    });
    const index = try tmp.dir.readFileAlloc(allocator, "memory/index.json", 1 << 20);
    defer allocator.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "\"unassigned\"") != null);
}
