const std = @import("std");
const agent_history = @import("../agent_history.zig");
const command_palette_model = @import("palette_model.zig");

pub const Bucket = enum { today, yesterday, past_week, earlier };
pub const SourceFilter = enum { all, sidebar, tab };

/// A flat display row: either a group header, or a session row referenced by its
/// ordinal into `View.filtered` (0..filtered.len).
pub const DisplayItem = union(enum) { header: Bucket, row: usize };

/// Local civil day number (floored), so day differences are linear and tz-correct.
pub fn localEpochDay(ms: i64, tz_offset_seconds: i32) i64 {
    return @divFloor(@divFloor(ms, 1000) + tz_offset_seconds, 86400);
}

pub fn bucketFor(now_ms: i64, row_ms: i64, tz_offset_seconds: i32) Bucket {
    const diff = localEpochDay(now_ms, tz_offset_seconds) - localEpochDay(row_ms, tz_offset_seconds);
    if (diff <= 0) return .today; // future/clock-skew falls into today
    if (diff == 1) return .yesterday;
    if (diff < 7) return .past_week;
    return .earlier;
}

pub fn rowMatches(row: agent_history.Row, query: []const u8, source: SourceFilter) bool {
    const src_ok = switch (source) {
        .all => true,
        .sidebar => row.copilot,
        .tab => !row.copilot,
    };
    if (!src_ok) return false;
    if (query.len == 0) return true;
    return command_palette_model.containsIgnoreCase(row.title, query) or
        command_palette_model.containsIgnoreCase(row.model, query);
}

pub const View = struct {
    items: []DisplayItem,
    filtered: []usize, // original-row indices in display order; selectable count = len

    pub fn rowCount(self: *const View) usize {
        return self.filtered.len;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        allocator.free(self.filtered);
        self.* = undefined;
    }
};

/// `rows` must already be sorted newest-first (MetaStore.buildRows guarantees this),
/// so buckets are contiguous and one header is emitted per bucket transition.
pub fn build(
    allocator: std.mem.Allocator,
    rows: []const agent_history.Row,
    query: []const u8,
    source: SourceFilter,
    now_ms: i64,
    tz_offset_seconds: i32,
) !View {
    var items: std.ArrayListUnmanaged(DisplayItem) = .empty;
    errdefer items.deinit(allocator);
    var filtered: std.ArrayListUnmanaged(usize) = .empty;
    errdefer filtered.deinit(allocator);

    var have_bucket = false;
    var cur_bucket: Bucket = .today;
    for (rows, 0..) |row, i| {
        if (!rowMatches(row, query, source)) continue;
        const b = bucketFor(now_ms, row.updated_at, tz_offset_seconds);
        if (!have_bucket or b != cur_bucket) {
            try items.append(allocator, .{ .header = b });
            cur_bucket = b;
            have_bucket = true;
        }
        const ord = filtered.items.len;
        try filtered.append(allocator, i);
        try items.append(allocator, .{ .row = ord });
    }
    return .{
        .items = try items.toOwnedSlice(allocator),
        .filtered = try filtered.toOwnedSlice(allocator),
    };
}

test "history view: bucketFor classifies by local calendar day" {
    const tz: i32 = 8 * 3600;
    const day: i64 = 86400 * 1000;
    const now: i64 = 1_700_000_000_000;
    try std.testing.expectEqual(Bucket.today, bucketFor(now, now, tz));
    try std.testing.expectEqual(Bucket.today, bucketFor(now, now + day, tz));
    try std.testing.expectEqual(Bucket.yesterday, bucketFor(now, now - day, tz));
    try std.testing.expectEqual(Bucket.past_week, bucketFor(now, now - 2 * day, tz));
    try std.testing.expectEqual(Bucket.past_week, bucketFor(now, now - 6 * day, tz));
    try std.testing.expectEqual(Bucket.earlier, bucketFor(now, now - 7 * day, tz));
    try std.testing.expectEqual(Bucket.earlier, bucketFor(now, now - 30 * day, tz));
}

test "history view: rowMatches filters by query and source" {
    const r_tab = agent_history.Row{ .session_id = "a", .title = "Deploy notes", .model = "deepseek-v4", .updated_at = 1, .copilot = false };
    const r_side = agent_history.Row{ .session_id = "b", .title = "Chat", .model = "gpt-x", .updated_at = 1, .copilot = true };
    try std.testing.expect(rowMatches(r_tab, "deploy", .all));
    try std.testing.expect(rowMatches(r_tab, "DEEPSEEK", .all));
    try std.testing.expect(!rowMatches(r_tab, "zzz", .all));
    try std.testing.expect(rowMatches(r_tab, "", .all));
    try std.testing.expect(rowMatches(r_side, "", .sidebar));
    try std.testing.expect(!rowMatches(r_side, "", .tab));
    try std.testing.expect(rowMatches(r_tab, "", .tab));
    try std.testing.expect(!rowMatches(r_tab, "", .sidebar));
}

test "history view: build groups, filters, and maps selection" {
    const a = std.testing.allocator;
    const day: i64 = 86400 * 1000;
    const now: i64 = 10_000 * day + day / 2; // noon to avoid midnight boundary crossing
    const rows = [_]agent_history.Row{
        .{ .session_id = "1", .title = "Today A", .model = "m", .updated_at = now, .copilot = false },
        .{ .session_id = "2", .title = "Today B", .model = "m", .updated_at = now - 1000, .copilot = true },
        .{ .session_id = "3", .title = "Yesterday", .model = "m", .updated_at = now - day, .copilot = false },
        .{ .session_id = "4", .title = "Old", .model = "m", .updated_at = now - 20 * day, .copilot = false },
    };
    var v = try build(a, &rows, "", .all, now, 0);
    defer v.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), v.rowCount());
    try std.testing.expectEqual(@as(usize, 7), v.items.len);
    try std.testing.expect(std.meta.activeTag(v.items[0]) == .header);
    try std.testing.expectEqual(Bucket.today, v.items[0].header);
    try std.testing.expect(std.meta.activeTag(v.items[1]) == .row);
    try std.testing.expectEqual(@as(usize, 0), v.items[1].row);
    try std.testing.expectEqual(Bucket.yesterday, v.items[3].header);
    try std.testing.expectEqual(@as(usize, 0), v.filtered[0]);
    try std.testing.expectEqual(@as(usize, 3), v.filtered[3]);

    var v2 = try build(a, &rows, "", .sidebar, now, 0);
    defer v2.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), v2.rowCount());
    try std.testing.expectEqual(@as(usize, 1), v2.filtered[0]);

    var v3 = try build(a, &rows, "yesterday", .all, now, 0);
    defer v3.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), v3.rowCount());

    var v4 = try build(a, &rows, "zzzzz", .all, now, 0);
    defer v4.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), v4.rowCount());
    try std.testing.expectEqual(@as(usize, 0), v4.items.len);
}
