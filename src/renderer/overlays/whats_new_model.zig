//! Pure layout + scroll + hit-test + URL helpers for the "What's New" modal.
//! No GL, no AppWindow — unit-tested in the fast suite. overlays.zig owns the
//! threadlocal modal state and the actual drawing; this module owns the math.
const std = @import("std");
const md = @import("../../markdown_text.zig");

pub const Action = enum { none, view_on_github, close };

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.w and
            py >= self.y and py <= self.y + self.h;
    }
};

/// All rects use a top-left origin (y grows downward). overlays converts to its
/// bottom-up draw space.
pub const Layout = struct {
    panel: Rect,
    content: Rect,
    view_btn: Rect,
    close_btn: Rect,
    visible_rows: usize,
};

pub const MIN_WRAP_COLS: usize = 8;

/// Display rows a single cleaned line of `display_len` bytes occupies at
/// `wrap_cols` columns (always at least 1). Byte-length approximation — adequate
/// for the ASCII-dominant release notes; wide glyphs may wrap a column early.
pub fn lineRows(display_len: usize, wrap_cols: usize) usize {
    if (wrap_cols == 0 or display_len == 0) return 1;
    return (display_len + wrap_cols - 1) / wrap_cols;
}

/// Total wrapped display rows for the whole notes blob at `wrap_cols` columns.
pub fn totalRows(notes: []const u8, wrap_cols: usize) usize {
    var total: usize = 0;
    var in_code = false;
    var it = std.mem.splitScalar(u8, notes, '\n');
    while (it.next()) |raw| {
        var buf: [1024]u8 = undefined;
        const cleaned = md.cleanedLine(&buf, raw, in_code);
        if (cleaned.style == .fence) in_code = !in_code;
        total += lineRows(cleaned.text.len, wrap_cols);
    }
    return total;
}

/// Clamp a (possibly negative or overscrolled) line offset into range.
pub fn clampScroll(offset: i64, total_lines: usize, visible_lines: usize) usize {
    if (total_lines <= visible_lines) return 0;
    const max_off: i64 = @intCast(total_lines - visible_lines);
    if (offset < 0) return 0;
    if (offset > max_off) return @intCast(max_off);
    return @intCast(offset);
}

/// Which button (if any) a top-left-origin point hits.
pub fn buttonActionAt(layout: Layout, px: f32, py: f32) Action {
    if (layout.view_btn.contains(px, py)) return .view_on_github;
    if (layout.close_btn.contains(px, py)) return .close;
    return .none;
}

pub const fallback_url = "https://github.com/xuzhougeng/wispterm/releases/latest";

/// Build the release page URL for `version` (e.g. ".../releases/tag/v1.10.0").
/// Falls back to the latest-releases page if formatting fails.
pub fn releaseTagUrl(buf: []u8, version: []const u8) []const u8 {
    const v = std.mem.trimLeft(u8, version, "vV");
    return std.fmt.bufPrint(
        buf,
        "https://github.com/xuzhougeng/wispterm/releases/tag/v{s}",
        .{v},
    ) catch fallback_url;
}

/// Centered modal layout. `row_h` is the pixel height of one text row.
pub fn computeLayout(window_w: f32, window_h: f32, row_h: f32) Layout {
    const panel_w = @min(window_w - 80, 720);
    const panel_h = @min(window_h - 80, 560);
    const panel_x = (window_w - panel_w) / 2;
    const panel_y = (window_h - panel_h) / 2;

    const pad: f32 = 28;
    const title_h: f32 = row_h + 18;
    const footer_h: f32 = 56;
    const content = Rect{
        .x = panel_x + pad,
        .y = panel_y + title_h,
        .w = panel_w - pad * 2,
        .h = panel_h - title_h - footer_h,
    };

    const btn_w: f32 = 150;
    const btn_h: f32 = 34;
    const btn_y = panel_y + panel_h - footer_h + (footer_h - btn_h) / 2;
    const close_btn = Rect{ .x = panel_x + panel_w - pad - btn_w, .y = btn_y, .w = btn_w, .h = btn_h };
    const view_btn = Rect{ .x = close_btn.x - 14 - btn_w, .y = btn_y, .w = btn_w, .h = btn_h };

    const rows: usize = if (row_h > 0) @intFromFloat(@max(@as(f32, 1), content.h / row_h)) else 1;
    return .{
        .panel = .{ .x = panel_x, .y = panel_y, .w = panel_w, .h = panel_h },
        .content = content,
        .view_btn = view_btn,
        .close_btn = close_btn,
        .visible_rows = rows,
    };
}

test "lineRows is at least one and wraps by columns" {
    try std.testing.expectEqual(@as(usize, 1), lineRows(0, 40));
    try std.testing.expectEqual(@as(usize, 1), lineRows(40, 40));
    try std.testing.expectEqual(@as(usize, 2), lineRows(41, 40));
}

test "totalRows counts blank, heading, and wrapped lines" {
    // No trailing newline: splitScalar would otherwise emit a final empty segment.
    const notes = "# Title\n\nshort";
    // "Title" (1) + blank (1) + "short" (1) = 3
    try std.testing.expectEqual(@as(usize, 3), totalRows(notes, 40));
    // A line longer than wrap_cols spans multiple rows.
    try std.testing.expectEqual(@as(usize, 2), totalRows("abcdefghij", 5));
}

test "clampScroll clamps both ends" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(-5, 100, 10));
    try std.testing.expectEqual(@as(usize, 90), clampScroll(999, 100, 10));
    try std.testing.expectEqual(@as(usize, 0), clampScroll(7, 5, 10)); // content fits
    try std.testing.expectEqual(@as(usize, 7), clampScroll(7, 100, 10));
}

test "releaseTagUrl strips leading v and builds tag URL" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://github.com/xuzhougeng/wispterm/releases/tag/v1.10.0",
        releaseTagUrl(&buf, "1.10.0"),
    );
    try std.testing.expectEqualStrings(
        "https://github.com/xuzhougeng/wispterm/releases/tag/v1.10.0",
        releaseTagUrl(&buf, "v1.10.0"),
    );
}

test "buttonActionAt resolves clicks" {
    const layout = computeLayout(1200, 800, 20);
    const close_pt_x = layout.close_btn.x + 1;
    const close_pt_y = layout.close_btn.y + 1;
    try std.testing.expectEqual(Action.close, buttonActionAt(layout, close_pt_x, close_pt_y));
    const view_pt_x = layout.view_btn.x + 1;
    const view_pt_y = layout.view_btn.y + 1;
    try std.testing.expectEqual(Action.view_on_github, buttonActionAt(layout, view_pt_x, view_pt_y));
    try std.testing.expectEqual(Action.none, buttonActionAt(layout, layout.panel.x + 1, layout.panel.y + 1));
}

test "computeLayout keeps buttons inside the panel and visible_rows positive" {
    const layout = computeLayout(1200, 800, 20);
    try std.testing.expect(layout.visible_rows >= 1);
    try std.testing.expect(layout.close_btn.x >= layout.panel.x);
    try std.testing.expect(layout.close_btn.x + layout.close_btn.w <= layout.panel.x + layout.panel.w);
    try std.testing.expect(layout.view_btn.x >= layout.panel.x);
}
