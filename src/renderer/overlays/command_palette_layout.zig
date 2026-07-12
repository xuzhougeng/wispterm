//! Pure layout math for the command palette panel.
//!
//! Extracted from renderer/overlays.zig so the geometry (box size/position, row
//! count, header/filter/footer bands) can be reasoned about and unit-tested in
//! isolation. Everything here is a pure function of its inputs: window
//! dimensions, the top offset of the content area, the font cell height, and the
//! number of result rows. There are NO global reads and NO AppWindow import — the
//! caller (overlays.zig) snapshots the font cell height and result count and
//! passes them in, then uses the returned numbers exactly as before.

const std = @import("std");

/// Hard cap on rows the palette ever renders at once. Must match the scratch
/// buffer size in overlays.zig.
pub const MAX_VISIBLE_ROWS: usize = 14;

/// Computed geometry for the command palette panel, in top-down client pixels.
/// Ghostty-style: no header/footer bands — the panel is filter field + divider
/// + rows, anchored near the top of the content area.
pub const Layout = struct {
    box_x: f32,
    box_top_px: f32,
    box_w: f32,
    box_h: f32,
    filter_h: f32,
    row_top_px: f32,
    row_h: f32,
    rendered_rows: usize,
};

/// Vertical padding around the row list (between the divider and the first
/// row, and below the last row). Mirrors Ghostty's list padding.
pub const LIST_PAD: f32 = 10;

pub const DrawRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const PanelChrome = struct {
    scrim: DrawRect,
    border: DrawRect,
    panel: DrawRect,
};

pub const FieldChrome = struct {
    border: DrawRect,
    field: DrawRect,
    text_y: f32,
};

pub const RowSlot = struct {
    row: DrawRect,
    selected_fill: DrawRect,
    text_y: f32,
};

pub const Scrollbar = struct {
    track: DrawRect,
    thumb: DrawRect,
};

/// Text height for an overlay line, derived from the font cell height.
/// Mirrors overlays.overlayTextHeight().
fn textHeight(cell_height: f32) f32 {
    return @max(1.0, cell_height);
}

/// Row height for list items. Mirrors overlays.overlayRowHeight().
fn rowHeight(cell_height: f32, min_h: f32) f32 {
    return @round(@max(min_h, textHeight(cell_height) + 14.0));
}

/// Control (input) height. Mirrors overlays.overlayControlHeight().
fn controlHeight(cell_height: f32, min_h: f32) f32 {
    return @round(@max(min_h, textHeight(cell_height) + 12.0));
}

/// Clamp the panel height so it never paints past the height available to it
/// (content area minus the top gap and a bottom margin).
fn clampBoxHeight(box_h: f32, avail_h: f32) f32 {
    return @max(1.0, @min(box_h, avail_h));
}

/// How many list rows fit in the height available to the panel.
fn rowCapacity(avail_h: f32, base_h: f32, row_h: f32) usize {
    const usable_h = @max(row_h, avail_h - base_h);
    if (usable_h <= row_h) return 1;
    const count_f = @floor(usable_h / row_h);
    const count: usize = @intFromFloat(@max(1.0, count_f));
    return @min(count, MAX_VISIBLE_ROWS);
}

/// Compute the full command-palette layout.
///
/// `cell_height` is the titlebar font cell height (overlays passes
/// font.g_titlebar_cell_height). `result_count` is the number of filtered result
/// rows (overlays passes commandPaletteResultCount()). The math is identical to
/// the previous in-overlays commandPaletteLayout().
pub fn compute(
    window_width: f32,
    window_height: f32,
    top_offset: f32,
    cell_height: f32,
    result_count: usize,
    scale: f32,
) Layout {
    const content_height = @max(1, window_height - top_offset);

    // Ghostty: maxWidth 500 logical points, anchored a small gap below the
    // top of the content area rather than vertically centered. All layout
    // math is in physical pixels, so the point-based widths scale by DPI.
    const box_w = @round(@min(@max(420 * scale, window_width - 64 * scale), 500 * scale));
    const row_h = rowHeight(cell_height, 36);
    const filter_h = controlHeight(cell_height, 48);
    const top_gap = @max(16.0, content_height * 0.05);
    const avail_h = @max(1.0, content_height - top_gap - 16);
    const base_h = filter_h + LIST_PAD * 2;
    const max_rows = rowCapacity(avail_h, base_h, row_h);
    const rendered_rows = @min(result_count, max_rows);
    const row_area_h = row_h * @as(f32, @floatFromInt(@max(rendered_rows, 1)));
    const box_h = @round(clampBoxHeight(base_h + row_area_h, avail_h));
    const box_x = @round(@max(16, (window_width - box_w) / 2));
    const box_top_px = @round(top_offset + top_gap);
    const row_top_px = @round(box_top_px + filter_h + LIST_PAD);

    return .{
        .box_x = box_x,
        .box_top_px = box_top_px,
        .box_w = box_w,
        .box_h = box_h,
        .filter_h = filter_h,
        .row_top_px = row_top_px,
        .row_h = row_h,
        .rendered_rows = rendered_rows,
    };
}

/// First visible result index that keeps `selected` inside a window of
/// `rendered_rows` rows out of `count` total. Pure scroll-clamp math, shared by
/// the keyboard/list view and the hit-test. Mirrors the body of
/// overlays.commandPaletteFirstVisibleIndex() (the caller still resolves which
/// `selected` value — command vs history — to pass in).
pub fn firstVisibleIndex(rendered_rows: usize, count: usize, selected_in: usize) usize {
    if (rendered_rows == 0 or count <= rendered_rows) return 0;
    const selected = @min(selected_in, count - 1);
    if (selected < rendered_rows) return 0;
    return @min(selected - rendered_rows + 1, count - rendered_rows);
}

pub fn rectY(window_height: f32, top_px: f32, h: f32) f32 {
    return @round(window_height - top_px - h);
}

pub fn textY(row_y: f32, row_h: f32, text_h: f32) f32 {
    return @round(row_y + (row_h - text_h) / 2.0);
}

pub fn panelChrome(layout: Layout, window_width: f32, window_height: f32) PanelChrome {
    const y = rectY(window_height, layout.box_top_px, layout.box_h);
    return .{
        .scrim = .{ .x = 0, .y = 0, .w = window_width, .h = window_height },
        .border = .{ .x = layout.box_x - 1, .y = y - 1, .w = layout.box_w + 2, .h = layout.box_h + 2 },
        .panel = .{ .x = layout.box_x, .y = y, .w = layout.box_w, .h = layout.box_h },
    };
}

pub fn fieldChrome(layout: Layout, window_height: f32, pad_x: f32, text_h: f32) FieldChrome {
    const x = @round(layout.box_x + pad_x);
    const w = layout.box_w - pad_x * 2;
    const y = rectY(window_height, layout.box_top_px, layout.filter_h);
    return .{
        .border = .{ .x = x - 1, .y = y - 1, .w = w + 2, .h = layout.filter_h + 2 },
        .field = .{ .x = x, .y = y, .w = w, .h = layout.filter_h },
        .text_y = textY(y, layout.filter_h, text_h),
    };
}

pub fn rowSlot(layout: Layout, window_height: f32, display_row: usize, text_h: f32) RowSlot {
    const row_top = @round(layout.row_top_px + @as(f32, @floatFromInt(display_row)) * layout.row_h);
    const y = rectY(window_height, row_top, layout.row_h);
    return .{
        .row = .{ .x = layout.box_x, .y = y, .w = layout.box_w, .h = layout.row_h },
        .selected_fill = .{ .x = layout.box_x + 10, .y = y + 2, .w = layout.box_w - 20, .h = layout.row_h - 4 },
        .text_y = textY(y, layout.row_h, text_h),
    };
}

pub fn emptyTextY(layout: Layout, window_height: f32, text_h: f32) f32 {
    const first = rowSlot(layout, window_height, 0, text_h);
    return first.text_y;
}

pub fn scrollbar(layout: Layout, window_height: f32, total_results: usize, first_row: usize) ?Scrollbar {
    if (total_results <= layout.rendered_rows or layout.rendered_rows == 0) return null;

    const total_f: f32 = @floatFromInt(total_results);
    const vis_f: f32 = @floatFromInt(layout.rendered_rows);
    const track_h = layout.row_h * vis_f;
    const sb_w: f32 = 3;
    const sb_x = layout.box_x + layout.box_w - sb_w - 7;
    const track_y = rectY(window_height, layout.row_top_px, track_h);
    const thumb_h = @max(24.0, @round(track_h * vis_f / total_f));
    const max_scroll_f: f32 = @floatFromInt(total_results - layout.rendered_rows);
    const scroll_f: f32 = @floatFromInt(@min(first_row, total_results - layout.rendered_rows));
    const thumb_offset = if (max_scroll_f > 0) @round((track_h - thumb_h) * (scroll_f / max_scroll_f)) else 0;
    const thumb_y = rectY(window_height, layout.row_top_px + thumb_offset, thumb_h);

    return .{
        .track = .{ .x = sb_x, .y = track_y, .w = sb_w, .h = track_h },
        .thumb = .{ .x = sb_x, .y = thumb_y, .w = sb_w, .h = thumb_h },
    };
}

test "row capacity is capped at MAX_VISIBLE_ROWS" {
    // A very tall window with a small base/row height would otherwise fit more
    // than the cap; the result must clamp to MAX_VISIBLE_ROWS.
    const row_h: f32 = 38;
    const big = rowCapacity(10000, 100, row_h);
    try std.testing.expectEqual(@as(usize, MAX_VISIBLE_ROWS), big);
}

test "row capacity is at least one row even when cramped" {
    const row_h: f32 = 38;
    // base_h consumes nearly all of a short window.
    try std.testing.expectEqual(@as(usize, 1), rowCapacity(80, 200, row_h));
}

test "layout box width clamps between 420 and 500" {
    const cell: f32 = 20;
    // Narrow window (width-64 < 420) -> min width 420.
    const narrow = compute(460, 800, 0, cell, 5, 1.0);
    try std.testing.expectEqual(@as(f32, 420), narrow.box_w);
    // Wide window -> capped at 500.
    const wide = compute(2000, 800, 0, cell, 5, 1.0);
    try std.testing.expectEqual(@as(f32, 500), wide.box_w);
    // Middle window -> window_width - 64.
    const mid = compute(520, 800, 0, cell, 5, 1.0);
    try std.testing.expectEqual(@as(f32, 520 - 64), mid.box_w);
}

test "layout box is horizontally centered" {
    const cell: f32 = 20;
    const l = compute(1200, 800, 0, cell, 5, 1.0);
    const expected_x = @round(@max(16, (@as(f32, 1200) - l.box_w) / 2));
    try std.testing.expectEqual(expected_x, l.box_x);
}

test "rendered rows never exceeds result count or capacity" {
    const cell: f32 = 20;
    // Few results: rendered_rows == result_count.
    const few = compute(1200, 1200, 0, cell, 3, 1.0);
    try std.testing.expectEqual(@as(usize, 3), few.rendered_rows);
    // Many results in a tall window: clamped at MAX_VISIBLE_ROWS.
    const many = compute(1200, 4000, 0, cell, 100, 1.0);
    try std.testing.expect(many.rendered_rows <= MAX_VISIBLE_ROWS);
    try std.testing.expectEqual(@as(usize, MAX_VISIBLE_ROWS), many.rendered_rows);
}

test "row band starts below the filter" {
    const cell: f32 = 20;
    const l = compute(1200, 1000, 40, cell, 8, 1.0);
    const expected_row_top = @round(l.box_top_px + l.filter_h + LIST_PAD);
    try std.testing.expectEqual(expected_row_top, l.row_top_px);
    // Row band sits strictly below the box top.
    try std.testing.expect(l.row_top_px > l.box_top_px);
}

test "panel anchors near the top of the content area" {
    const cell: f32 = 20;
    const l = compute(1200, 1000, 40, cell, 8, 1.0);
    const content_height: f32 = 1000 - 40;
    try std.testing.expectEqual(@round(40 + content_height * 0.05), l.box_top_px);
    // Very short window: top gap bottoms out at 16.
    const short = compute(1200, 140, 40, cell, 2, 1.0);
    try std.testing.expectEqual(@as(f32, 40 + 16), short.box_top_px);
}

test "first visible index keeps selection in view" {
    // count <= rendered: window starts at 0.
    try std.testing.expectEqual(@as(usize, 0), firstVisibleIndex(14, 10, 9));
    // selection within the first window: no scroll.
    try std.testing.expectEqual(@as(usize, 0), firstVisibleIndex(5, 20, 4));
    // selection past the window: scroll so selection is the last visible row.
    try std.testing.expectEqual(@as(usize, 1), firstVisibleIndex(5, 20, 5));
    try std.testing.expectEqual(@as(usize, 6), firstVisibleIndex(5, 20, 10));
    // selection at the very end: clamp to count - rendered.
    try std.testing.expectEqual(@as(usize, 15), firstVisibleIndex(5, 20, 19));
    // out-of-range selection is clamped to the last item.
    try std.testing.expectEqual(@as(usize, 15), firstVisibleIndex(5, 20, 99));
    // rendered_rows == 0: degenerate, no scroll.
    try std.testing.expectEqual(@as(usize, 0), firstVisibleIndex(0, 20, 5));
}

test "panel chrome converts command palette box to draw rectangles" {
    const l = compute(1200, 800, 40, 20, 8, 1.0);
    const chrome = panelChrome(l, 1200, 800);
    const y = rectY(800, l.box_top_px, l.box_h);

    try std.testing.expectEqual(DrawRect{ .x = 0, .y = 0, .w = 1200, .h = 800 }, chrome.scrim);
    try std.testing.expectEqual(DrawRect{ .x = l.box_x - 1, .y = y - 1, .w = l.box_w + 2, .h = l.box_h + 2 }, chrome.border);
    try std.testing.expectEqual(DrawRect{ .x = l.box_x, .y = y, .w = l.box_w, .h = l.box_h }, chrome.panel);
}

test "field chrome reserves horizontal padding and centers text" {
    const l = compute(1200, 800, 40, 20, 8, 1.0);
    const field = fieldChrome(l, 800, 16, 20);
    const expected_y = rectY(800, l.box_top_px, l.filter_h);

    try std.testing.expectEqual(@as(f32, l.box_x + 16), field.field.x);
    try std.testing.expectEqual(expected_y, field.field.y);
    try std.testing.expectEqual(@as(f32, l.box_w - 32), field.field.w);
    try std.testing.expectEqual(textY(expected_y, l.filter_h, 20), field.text_y);
}

test "row slots map display rows to selected affordance rects" {
    const l = compute(1200, 800, 40, 20, 8, 1.0);
    const row0 = rowSlot(l, 800, 0, 20);
    const row2 = rowSlot(l, 800, 2, 20);

    try std.testing.expectEqual(l.box_x, row0.row.x);
    try std.testing.expectEqual(l.box_w, row0.row.w);
    try std.testing.expectEqual(l.row_h, row0.row.h);
    try std.testing.expectEqual(row0.row.y - l.row_h * 2, row2.row.y);
    try std.testing.expectEqual(DrawRect{ .x = l.box_x + 10, .y = row0.row.y + 2, .w = l.box_w - 20, .h = l.row_h - 4 }, row0.selected_fill);
}

test "scrollbar geometry tracks visible row window" {
    const l = compute(1200, 800, 40, 20, 100, 1.0);
    const sb = scrollbar(l, 800, 100, 10).?;

    try std.testing.expectEqual(@as(f32, l.box_x + l.box_w - 10), sb.track.x);
    try std.testing.expectEqual(@as(f32, 3), sb.track.w);
    try std.testing.expectEqual(l.row_h * @as(f32, @floatFromInt(l.rendered_rows)), sb.track.h);
    try std.testing.expect(sb.thumb.h >= 24);
    try std.testing.expect(sb.thumb.y < sb.track.y + sb.track.h);
}
