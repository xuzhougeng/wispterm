//! Thread-local state for the Copilot conversation picker overlay. Mirrors
//! `jupyter/picker.zig`: a keyboard-navigable list of past Copilot conversations
//! (title + relative time). Rows are populated from the agent-history store by
//! AppWindow (which owns the store); this module stays UI- and store-free.
const std = @import("std");

pub const MAX_ROWS = 64;
const MAX_ID_BYTES = 128;
const MAX_TITLE_BYTES = 256;

pub const Row = struct {
    session_id: []const u8,
    title: []const u8,
    updated_at: i64,
};

threadlocal var g_visible: bool = false;
threadlocal var g_id_bufs: [MAX_ROWS][MAX_ID_BYTES]u8 = undefined;
threadlocal var g_id_lens: [MAX_ROWS]usize = [_]usize{0} ** MAX_ROWS;
threadlocal var g_title_bufs: [MAX_ROWS][MAX_TITLE_BYTES]u8 = undefined;
threadlocal var g_title_lens: [MAX_ROWS]usize = [_]usize{0} ** MAX_ROWS;
threadlocal var g_updated: [MAX_ROWS]i64 = [_]i64{0} ** MAX_ROWS;
threadlocal var g_count: usize = 0;
threadlocal var g_selected: usize = 0;

pub fn isVisible() bool {
    return g_visible;
}
pub fn count() usize {
    return g_count;
}
/// Total selectable rows = conversations + the trailing "+ New conversation" row.
pub fn rowCount() usize {
    return g_count + 1;
}
pub fn selectedIndex() usize {
    return g_selected;
}
pub fn isNewRowSelected() bool {
    return g_selected == g_count;
}
pub fn idAt(idx: usize) []const u8 {
    if (idx >= g_count) return "";
    return g_id_bufs[idx][0..g_id_lens[idx]];
}
pub fn titleAt(idx: usize) []const u8 {
    if (idx >= g_count) return "";
    return g_title_bufs[idx][0..g_title_lens[idx]];
}
pub fn updatedAt(idx: usize) i64 {
    if (idx >= g_count) return 0;
    return g_updated[idx];
}
pub fn selectedId() []const u8 {
    return idAt(g_selected);
}

pub fn show(rows: []const Row) void {
    g_count = @min(rows.len, MAX_ROWS);
    for (0..g_count) |i| {
        const id_len = @min(rows[i].session_id.len, MAX_ID_BYTES);
        @memcpy(g_id_bufs[i][0..id_len], rows[i].session_id[0..id_len]);
        g_id_lens[i] = id_len;
        const t_len = @min(rows[i].title.len, MAX_TITLE_BYTES);
        @memcpy(g_title_bufs[i][0..t_len], rows[i].title[0..t_len]);
        g_title_lens[i] = t_len;
        g_updated[i] = rows[i].updated_at;
    }
    g_selected = 0;
    g_visible = true;
}

pub fn move(delta: i32) void {
    g_selected = nextIndex(g_selected, delta, rowCount());
}

pub fn hide() void {
    g_visible = false;
    g_count = 0;
    g_selected = 0;
}

pub fn nextIndex(selected: usize, delta: i32, n: usize) usize {
    if (n == 0) return 0;
    const ni: i64 = @as(i64, @intCast(selected)) + delta;
    const last: i64 = @as(i64, @intCast(n)) - 1;
    if (ni < 0) return 0;
    if (ni > last) return @intCast(last);
    return @intCast(ni);
}

pub fn firstVisible(selected: usize, visible_rows: usize, n: usize) usize {
    if (visible_rows == 0 or n <= visible_rows) return 0;
    const sel = @min(selected, n - 1);
    if (sel < visible_rows) return 0;
    return @min(sel - visible_rows + 1, n - visible_rows);
}

/// Short English relative-time label ("just now", "5m ago", "3h ago", "2d ago",
/// "4mo ago", "1y ago"). `now_ms`/`then_ms` are epoch milliseconds. Pure.
pub fn formatRelativeTime(now_ms: i64, then_ms: i64, buf: []u8) []const u8 {
    const diff = now_ms - then_ms;
    if (diff < 60_000) return "just now";
    const min = @divTrunc(diff, 60_000);
    if (min < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{min}) catch "just now";
    const hr = @divTrunc(min, 60);
    if (hr < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hr}) catch "just now";
    const days = @divTrunc(hr, 24);
    if (days < 30) return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "just now";
    const months = @divTrunc(days, 30);
    if (months < 12) return std.fmt.bufPrint(buf, "{d}mo ago", .{months}) catch "just now";
    const years = @divTrunc(days, 365);
    return std.fmt.bufPrint(buf, "{d}y ago", .{years}) catch "just now";
}

test "nextIndex clamps to [0, n)" {
    try std.testing.expectEqual(@as(usize, 0), nextIndex(0, -1, 3));
    try std.testing.expectEqual(@as(usize, 2), nextIndex(2, 1, 3));
    try std.testing.expectEqual(@as(usize, 1), nextIndex(0, 1, 3));
    try std.testing.expectEqual(@as(usize, 0), nextIndex(0, 1, 0));
}

test "formatRelativeTime buckets" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("just now", formatRelativeTime(1000, 1000, &buf));
    try std.testing.expectEqualStrings("just now", formatRelativeTime(40_000, 0, &buf)); // 40s
    try std.testing.expectEqualStrings("5m ago", formatRelativeTime(5 * 60_000, 0, &buf));
    try std.testing.expectEqualStrings("3h ago", formatRelativeTime(3 * 3_600_000, 0, &buf));
    try std.testing.expectEqualStrings("2d ago", formatRelativeTime(2 * 86_400_000, 0, &buf));
    try std.testing.expectEqualStrings("2mo ago", formatRelativeTime(60 * 86_400_000, 0, &buf));
    try std.testing.expectEqualStrings("1y ago", formatRelativeTime(400 * 86_400_000, 0, &buf));
}

test "show then rowCount includes the trailing new row" {
    const rows = [_]Row{
        .{ .session_id = "x", .title = "X", .updated_at = 1 },
        .{ .session_id = "y", .title = "Y", .updated_at = 2 },
    };
    show(&rows);
    defer hide();
    try std.testing.expectEqual(@as(usize, 2), count());
    try std.testing.expectEqual(@as(usize, 3), rowCount());
    try std.testing.expect(!isNewRowSelected());
    move(99); // clamps to last selectable = the new row
    try std.testing.expect(isNewRowSelected());
    try std.testing.expectEqualStrings("x", idAt(0));
}
