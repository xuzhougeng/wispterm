const std = @import("std");

pub const MAX_URLS = 16;
const MAX_URL_BYTES = 2048;

threadlocal var g_visible: bool = false;
threadlocal var g_bufs: [MAX_URLS][MAX_URL_BYTES]u8 = undefined;
threadlocal var g_lens: [MAX_URLS]usize = [_]usize{0} ** MAX_URLS;
threadlocal var g_count: usize = 0;
threadlocal var g_selected: usize = 0;

pub fn isVisible() bool {
    return g_visible;
}

pub fn count() usize {
    return g_count;
}

pub fn selectedIndex() usize {
    return g_selected;
}

pub fn urlAt(idx: usize) []const u8 {
    if (idx >= g_count) return "";
    return g_bufs[idx][0..g_lens[idx]];
}

pub fn selectedUrl() []const u8 {
    return urlAt(g_selected);
}

pub fn nextIndex(selected: usize, delta: i32, n: usize) usize {
    if (n == 0) return 0;
    const ni: i64 = @as(i64, @intCast(selected)) + delta;
    const last: i64 = @as(i64, @intCast(n)) - 1;
    if (ni < 0) return 0;
    if (ni > last) return @intCast(last);
    return @intCast(ni);
}

pub fn show(urls: []const []const u8) void {
    g_count = @min(urls.len, MAX_URLS);
    for (0..g_count) |i| {
        const len = @min(urls[i].len, MAX_URL_BYTES);
        @memcpy(g_bufs[i][0..len], urls[i][0..len]);
        g_lens[i] = len;
    }
    g_selected = 0;
    g_visible = true;
}

pub fn move(delta: i32) void {
    g_selected = nextIndex(g_selected, delta, g_count);
}

pub fn hide() void {
    g_visible = false;
    g_count = 0;
    g_selected = 0;
}

test "nextIndex clamps at both ends" {
    try std.testing.expectEqual(@as(usize, 0), nextIndex(0, -1, 3));
    try std.testing.expectEqual(@as(usize, 1), nextIndex(0, 1, 3));
    try std.testing.expectEqual(@as(usize, 2), nextIndex(2, 1, 3));
    try std.testing.expectEqual(@as(usize, 0), nextIndex(0, -1, 0));
}

test "show stores urls and clamps; selectedUrl tracks move" {
    const urls = [_][]const u8{ "http://localhost:1/lab?token=a", "http://localhost:2/lab?token=b" };
    show(&urls);
    defer hide();
    try std.testing.expectEqual(@as(usize, 2), count());
    try std.testing.expectEqualStrings("http://localhost:1/lab?token=a", selectedUrl());
    move(1);
    try std.testing.expectEqualStrings("http://localhost:2/lab?token=b", selectedUrl());
    move(5);
    try std.testing.expectEqualStrings("http://localhost:2/lab?token=b", selectedUrl());
}
