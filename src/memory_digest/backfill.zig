//! Backfill gap scan (spec 2026-07-09 §3): find daily sessions that were
//! collected before LLM summarization existed (or whose map failed) and
//! still have an empty summary, so the digest run can summarize them late.
const std = @import("std");
const types = @import("types.zig");
const store = @import("store.zig");

const MAX_DAILY_BYTES = 16 * 1024 * 1024;

pub const Gap = struct {
    date: []const u8,
    provider: types.DigestProvider,
    session_id: []const u8,
    source_file: []const u8,
};

pub fn findGaps(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    memory_root: []const u8,
    limit: usize,
) ![]const Gap {
    if (limit == 0) return &.{};
    var gaps: std.ArrayListUnmanaged(Gap) = .empty;
    const daily_dir = try std.fs.path.join(gpa, &.{ memory_root, "daily" });
    defer gpa.free(daily_dir);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        var dir = std.fs.cwd().openDir(daily_dir, .{ .iterate = true }) catch return &.{};
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (ent.kind != .file or ent.name.len != 15 or !std.mem.endsWith(u8, ent.name, ".json")) continue;
            try names.append(arena, try arena.dupe(u8, ent.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);

    outer: for (names.items) |name| {
        const path = try std.fs.path.join(gpa, &.{ daily_dir, name });
        defer gpa.free(path);
        const bytes = std.fs.cwd().readFileAlloc(arena, path, MAX_DAILY_BYTES) catch continue;
        const daily = std.json.parseFromSliceLeaky(store.Daily, arena, bytes, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        for (daily.sessions) |s| {
            if (s.summary.len != 0) continue;
            if (!std.mem.eql(u8, s.source_id, "local")) continue;
            const provider = std.meta.stringToEnum(types.DigestProvider, s.provider) orelse continue;
            try gaps.append(arena, .{
                .date = try arena.dupe(u8, daily.date),
                .provider = provider,
                .session_id = try arena.dupe(u8, s.session_id),
                .source_file = try arena.dupe(u8, s.source_file),
            });
            if (gaps.items.len >= limit) break :outer;
        }
    }
    return gaps.items;
}

test "backfill: findGaps returns local empty-summary sessions oldest-first with limit" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("daily");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    try tmp.dir.writeFile(.{ .sub_path = "daily/2026-06-30.json", .data = 
        \\{"schema_version":1,"date":"2026-06-30","generated_at":1,"sessions":[
        \\{"provider":"codex","source_id":"local","session_id":"gap-1","project":"p","title":"t","message_count_new":5},
        \\{"provider":"claude","source_id":"ssh:CPU","session_id":"remote-1","project":"p","title":"t","message_count_new":2},
        \\{"provider":"claude","source_id":"local","session_id":"done-1","project":"p","title":"t","message_count_new":2,"summary":"已归纳"}]}
    });
    try tmp.dir.writeFile(.{ .sub_path = "daily/2026-07-06.json", .data = 
        \\{"schema_version":1,"date":"2026-07-06","generated_at":1,"sessions":[
        \\{"provider":"codex","source_id":"local","session_id":"gap-2","project":"p","title":"t","message_count_new":9,"source_file":"/tmp/x.jsonl"},
        \\{"provider":"wispterm","source_id":"local","session_id":"gap-3","project":"p","title":"t","message_count_new":1}]}
    });

    const gaps = try findGaps(a, arena, root, 8);
    try std.testing.expectEqual(@as(usize, 3), gaps.len);
    try std.testing.expectEqualStrings("gap-1", gaps[0].session_id); // 旧日期在前
    try std.testing.expectEqualStrings("2026-06-30", gaps[0].date);
    try std.testing.expectEqual(types.DigestProvider.codex, gaps[0].provider);
    try std.testing.expectEqualStrings("", gaps[0].source_file);
    try std.testing.expectEqualStrings("gap-2", gaps[1].session_id);
    try std.testing.expectEqualStrings("/tmp/x.jsonl", gaps[1].source_file);
    try std.testing.expectEqualStrings("gap-3", gaps[2].session_id);

    const limited = try findGaps(a, arena, root, 2);
    try std.testing.expectEqual(@as(usize, 2), limited.len);

    const none = try findGaps(a, arena, root, 0);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "backfill: findGaps tolerates missing daily dir" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const gaps = try findGaps(a, arena_state.allocator(), "/nonexistent/backfill/root", 8);
    try std.testing.expectEqual(@as(usize, 0), gaps.len);
}
