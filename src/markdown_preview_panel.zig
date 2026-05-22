//! State for the right-side Markdown/text preview panel.

const std = @import("std");
const markdown_preview = @import("markdown_preview.zig");
const tab = @import("appwindow/tab.zig");

pub const DEFAULT_WIDTH: f32 = 440;
pub const MIN_WIDTH: f32 = 280;
pub const MAX_WIDTH: f32 = 1120;
pub const MIN_CONTENT_WIDTH: f32 = 180;
pub const RESIZE_HIT_WIDTH: f32 = 16;

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_owner_tab: ?usize = null;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_kind: markdown_preview.Kind = .markdown;
pub threadlocal var g_scroll_offset: f32 = 0;

pub threadlocal var g_title_buf: [256]u8 = undefined;
pub threadlocal var g_title_len: usize = 0;
pub threadlocal var g_path_buf: [512]u8 = undefined;
pub threadlocal var g_path_len: usize = 0;
pub threadlocal var g_source_buf: [markdown_preview.MAX_SOURCE_BYTES]u8 = undefined;
pub threadlocal var g_source_len: usize = 0;

pub fn width() f32 {
    return if (isVisibleForActiveTab()) g_width else 0;
}

pub fn isVisibleForActiveTab() bool {
    const owner = g_owner_tab orelse return false;
    return g_visible and owner == tab.g_active_tab;
}

pub fn onTabClosed(closed_idx: usize) void {
    const owner = g_owner_tab orelse return;
    if (owner == closed_idx) {
        close();
    } else if (owner > closed_idx) {
        g_owner_tab = owner - 1;
    }
}

pub fn onTabReordered(from_idx: usize, to_idx: usize) void {
    const owner = g_owner_tab orelse return;
    if (owner == from_idx) {
        g_owner_tab = to_idx;
    } else if (from_idx < to_idx and owner > from_idx and owner <= to_idx) {
        g_owner_tab = owner - 1;
    } else if (from_idx > to_idx and owner >= to_idx and owner < from_idx) {
        g_owner_tab = owner + 1;
    }
}

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

pub fn setWidth(w: f32, window_width: f32) bool {
    const next = @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
    if (next == g_width) return false;
    g_width = next;
    return true;
}

pub fn open(kind: markdown_preview.Kind, preview_title: []const u8, preview_path: []const u8, source_text: []const u8) void {
    g_visible = true;
    g_owner_tab = tab.g_active_tab;
    g_kind = kind;
    g_scroll_offset = 0;

    g_title_len = @min(preview_title.len, g_title_buf.len);
    @memcpy(g_title_buf[0..g_title_len], preview_title[0..g_title_len]);

    g_path_len = @min(preview_path.len, g_path_buf.len);
    @memcpy(g_path_buf[0..g_path_len], preview_path[0..g_path_len]);

    g_source_len = @min(source_text.len, g_source_buf.len);
    @memcpy(g_source_buf[0..g_source_len], source_text[0..g_source_len]);
}

pub fn close() void {
    g_visible = false;
    g_owner_tab = null;
    g_scroll_offset = 0;
    g_source_len = 0;
    g_title_len = 0;
    g_path_len = 0;
}

pub fn title() []const u8 {
    return g_title_buf[0..g_title_len];
}

pub fn path() []const u8 {
    return g_path_buf[0..g_path_len];
}

pub fn source() []const u8 {
    return g_source_buf[0..g_source_len];
}

pub fn scrollBy(delta: f32) void {
    const max_scroll = estimatedMaxScroll();
    g_scroll_offset = @max(0, @min(max_scroll, g_scroll_offset + delta));
}

fn estimatedMaxScroll() f32 {
    const line_count = @max(@as(usize, 1), std.mem.count(u8, source(), "\n") + 1);
    return @max(0, @as(f32, @floatFromInt(line_count)) * 28 - 360);
}

test "markdown_preview_panel: visible only on owning active tab" {
    const saved_visible = g_visible;
    const saved_owner = g_owner_tab;
    const saved_active_tab = tab.g_active_tab;
    defer {
        g_visible = saved_visible;
        g_owner_tab = saved_owner;
        tab.g_active_tab = saved_active_tab;
    }

    tab.g_active_tab = 0;
    open(.markdown, "README.md", "README.md", "# Title\n");

    try std.testing.expect(isVisibleForActiveTab());
    try std.testing.expectEqual(DEFAULT_WIDTH, width());

    tab.g_active_tab = 1;
    try std.testing.expect(!isVisibleForActiveTab());
    try std.testing.expectEqual(@as(f32, 0), width());

    tab.g_active_tab = 0;
    try std.testing.expect(isVisibleForActiveTab());
}
