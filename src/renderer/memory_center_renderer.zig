const std = @import("std");
const memory_center = @import("../memory_center/session.zig");
const panel_draw = @import("panel_draw.zig");

const HEADER_H: f32 = 54;
const ROW_H: f32 = 54;
const PAD_X: f32 = 16;
const SOURCE_ROW_H: f32 = 38;
const SMALL_GAP: f32 = 6;

pub const DrawContext = panel_draw.DrawContext;

pub const Layout = struct {
    left_x: f32,
    left_w: f32,
    list_x: f32,
    list_w: f32,
    detail_x: f32,
    detail_w: f32,
};

pub const Hit = union(enum) {
    none,
    source: memory_center.Source,
    row: usize,
    detail,
};

pub fn computeLayout(x: f32, width: f32) Layout {
    const available = @max(0, width);
    if (available == 0) {
        return .{ .left_x = x, .left_w = 0, .list_x = x, .list_w = 0, .detail_x = x, .detail_w = 0 };
    }

    const min_left_w: f32 = 260;
    const min_list_w: f32 = 300;
    const min_detail_w: f32 = 180;
    const min_total = min_left_w + min_list_w + min_detail_w;
    const left_w = if (available < min_total)
        available * (min_left_w / min_total)
    else
        @min(@max(available * 0.20, min_left_w), 320);
    const list_w = if (available < min_total)
        available * (min_list_w / min_total)
    else
        @min(@max(available * 0.34, min_list_w), 460);
    return .{
        .left_x = x,
        .left_w = left_w,
        .list_x = x + left_w,
        .list_w = list_w,
        .detail_x = x + left_w + list_w,
        .detail_w = available - left_w - list_w,
    };
}

pub fn listVisibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    const visible_h = @max(0, content_h - headerHeight(cell_h));
    return @intFromFloat(@max(0, @floor(visible_h / rowHeight(cell_h))));
}

pub fn hitTest(
    session: *const memory_center.Session,
    window_height: f32,
    titlebar_offset: f32,
    x: f32,
    width: f32,
    cell_h: f32,
    mouse_x: f64,
    mouse_y: f64,
) Hit {
    const mx: f32 = @floatCast(mouse_x);
    const my: f32 = @floatCast(mouse_y);
    const layout = computeLayout(@round(x), @round(@max(1.0, width)));
    const top = @round(titlebar_offset);
    const src_top = sourceRowsTop(top, cell_h);
    const sources = [_]memory_center.Source{ .remembered, .digest };
    for (sources, 0..) |source, i| {
        const row_top = src_top + @as(f32, @floatFromInt(i)) * SOURCE_ROW_H;
        if (rectContains(mx, my, layout.left_x, row_top, layout.left_w, SOURCE_ROW_H)) return .{ .source = source };
    }

    const row_h = rowHeight(cell_h);
    const row_top = top + headerHeight(cell_h);
    if (mx >= layout.list_x and mx < layout.list_x + layout.list_w and my >= row_top) {
        const idx_float = (my - row_top) / row_h;
        if (idx_float >= 0) {
            const idx: usize = @intFromFloat(@floor(idx_float));
            const max_rows = listVisibleCapacity(window_height, top, cell_h);
            const start = session.listWindowStart(max_rows);
            const absolute = start + idx;
            if (idx < max_rows and absolute < session.count()) return .{ .row = absolute };
        }
    }

    if (mx >= layout.detail_x and mx < layout.detail_x + layout.detail_w and my >= top) return .detail;
    return .none;
}

pub fn render(
    draw: DrawContext,
    session: *memory_center.Session,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    x: f32,
    width: f32,
) void {
    _ = window_width;
    const content_x = @round(x);
    const content_w = @round(@max(1.0, width));
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    if (content_w <= 1 or content_h <= 1) return;

    const bg = draw.bg;
    const fg = draw.fg;
    const accent = draw.accent;
    const panel = mixColor(bg, fg, 0.045);
    const panel_soft = mixColor(bg, fg, 0.025);
    const panel_strong = mixColor(bg, fg, 0.075);
    const line = mixColor(bg, fg, 0.18);
    const muted = mixColor(bg, fg, 0.58);
    const selected_bg = mixColor(bg, accent, 0.18);

    const layout = computeLayout(content_x, content_w);
    draw.fillQuad(content_x, 0, content_w, content_h, bg);
    draw.fillQuadAlpha(layout.left_x, 0, layout.left_w, content_h, panel, 0.96);
    draw.fillQuadAlpha(layout.list_x, 0, layout.list_w, content_h, panel_soft, 0.98);
    draw.fillQuadAlpha(layout.detail_x, 0, layout.detail_w, content_h, bg, 1.0);
    draw.fillQuad(layout.list_x, 0, 1, content_h, line);
    draw.fillQuad(layout.detail_x, 0, 1, content_h, line);

    renderSources(draw, session, layout, window_height, top, content_h, fg, muted, accent, panel_strong, line, selected_bg);
    renderList(draw, session, layout, window_height, top, fg, muted, accent, selected_bg, line);
    renderDetail(draw, session, layout, window_height, top, content_h, fg, muted, accent, panel_strong, line);
}

fn renderSources(
    draw: DrawContext,
    session: *const memory_center.Session,
    layout: Layout,
    window_height: f32,
    top: f32,
    content_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    panel_strong: [3]f32,
    line: [3]f32,
    selected_bg: [3]f32,
) void {
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(layout.left_x, yFromTop(window_height, top, header_h), layout.left_w, header_h, panel_strong, 0.9);
    draw.fillQuad(layout.left_x, yFromTop(window_height, top + header_h, 1), layout.left_w, 1, line);
    _ = draw.renderTextLimited("Memory Center", layout.left_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.left_w - PAD_X * 2);

    const src_top = sourceRowsTop(top, draw.cell_h);
    _ = draw.renderTextLimited("SOURCE", layout.left_x + PAD_X, yTextFromTop(draw, window_height, src_top - draw.cell_h - 8), muted, layout.left_w - PAD_X * 2);
    const sources = [_]memory_center.Source{ .remembered, .digest };
    for (sources, 0..) |source, i| {
        const row_top = src_top + @as(f32, @floatFromInt(i)) * SOURCE_ROW_H;
        const active = session.source == source;
        if (active) {
            draw.fillQuadAlpha(layout.left_x, yFromTop(window_height, row_top, SOURCE_ROW_H), layout.left_w, SOURCE_ROW_H, selected_bg, 0.92);
            draw.fillQuad(layout.left_x, yFromTop(window_height, row_top, SOURCE_ROW_H), 4, SOURCE_ROW_H, accent);
        }
        var count_buf: [16]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{if (session.snapshot) |snap| snap.count(source) else 0}) catch "";
        const count_w = countColumnWidth(count_text, draw.glyphAdvance);
        const count_x = layout.left_x + layout.left_w - PAD_X - count_w;
        const label_x = layout.left_x + PAD_X + 6;
        const text_y = yTextFromTop(draw, window_height, row_top + 9);
        const label_color = if (active) fg else muted;
        _ = draw.renderTextLimited(source.label(), label_x, text_y, label_color, @max(0, count_x - label_x - SMALL_GAP));
        _ = draw.renderTextLimited(count_text, count_x, text_y, muted, count_w);
    }

    _ = draw.renderTextLimited("Tab / Left / Right switches source", layout.left_x + PAD_X, 12 + draw.cell_h + 6, muted, layout.left_w - PAD_X * 2);
    _ = draw.renderTextLimited("Up / Down selects - PgUp / PgDn scrolls", layout.left_x + PAD_X, 12, muted, layout.left_w - PAD_X * 2);
    _ = content_h;
}

fn renderList(
    draw: DrawContext,
    session: *const memory_center.Session,
    layout: Layout,
    window_height: f32,
    top: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    selected_bg: [3]f32,
    line: [3]f32,
) void {
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(layout.list_x, yFromTop(window_height, top, header_h), layout.list_w, header_h, mixColor(draw.bg, fg, 0.055), 0.98);
    draw.fillQuad(layout.list_x, yFromTop(window_height, top + header_h, 1), layout.list_w, 1, line);

    const count = session.count();
    var header_buf: [96]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} ({d})", .{ session.source.label(), count }) catch session.source.label();
    _ = draw.renderTextLimited(header, layout.list_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.list_w - PAD_X * 2);

    const status = session.status();
    if (status.len != 0) {
        _ = draw.renderTextLimited(status, layout.list_x + PAD_X, yTextFromTop(draw, window_height, top + header_h + 24), accent, layout.list_w - PAD_X * 2);
        return;
    }

    if (count == 0) {
        _ = draw.renderTextLimited("No memory in this source.", layout.list_x + PAD_X, yTextFromTop(draw, window_height, top + header_h + 24), muted, layout.list_w - PAD_X * 2);
        return;
    }

    const row_h = rowHeight(draw.cell_h);
    const row_top = top + header_h;
    const max_rows = listVisibleCapacity(window_height, top, draw.cell_h);
    const start = session.listWindowStart(max_rows);
    var rendered: usize = 0;
    var i = start;
    while (i < count and rendered < max_rows) : ({
        i += 1;
        rendered += 1;
    }) {
        const row = session.snapshot.?.rowAt(session.source, i) orelse continue;
        const row_top_px = row_top + @as(f32, @floatFromInt(rendered)) * row_h;
        const row_y = yFromTop(window_height, row_top_px, row_h);
        const selected = i == session.selected;
        if (selected) {
            draw.fillQuadAlpha(layout.list_x, row_y, layout.list_w, row_h, selected_bg, 0.92);
            draw.fillQuad(layout.list_x, row_y, 4, row_h, accent);
        }
        draw.fillQuadAlpha(layout.list_x, row_y, layout.list_w, 1, line, 0.55);

        _ = draw.renderTextLimited(row.title, layout.list_x + PAD_X, yTextFromTop(draw, window_height, row_top_px + 8), if (selected) fg else mixColor(fg, accent, 0.05), layout.list_w - PAD_X * 2);
        _ = draw.renderTextLimited(row.detail, layout.list_x + PAD_X, yTextFromTop(draw, window_height, row_top_px + row_h - 9 - draw.cell_h), muted, layout.list_w - PAD_X * 2);
    }
}

fn renderDetail(
    draw: DrawContext,
    session: *memory_center.Session,
    layout: Layout,
    window_height: f32,
    top: f32,
    content_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    panel_strong: [3]f32,
    line: [3]f32,
) void {
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(layout.detail_x, yFromTop(window_height, top, header_h), layout.detail_w, header_h, panel_strong, 0.82);
    draw.fillQuad(layout.detail_x, yFromTop(window_height, top + header_h, 1), layout.detail_w, 1, line);
    _ = draw.renderTextLimited("Memory Detail", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.detail_w - PAD_X * 2);

    const row = session.selectedRow() orelse {
        _ = draw.renderTextLimited("Select a memory row", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top + header_h + 24), muted, layout.detail_w - PAD_X * 2);
        _ = content_h;
        return;
    };

    var y = top + header_h + 18;
    _ = draw.renderTextLimited(row.title, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), fg, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 8;
    var meta_buf: [192]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{s} / {s}", .{ row.source.label(), row.scope }) catch row.scope;
    _ = draw.renderTextLimited(meta, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), accent, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 8;
    if (row.detail.len > 0) {
        _ = draw.renderTextLimited(row.detail, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2);
        y += draw.cell_h + 16;
    } else {
        y += 8;
    }
    draw.fillQuadAlpha(layout.detail_x + PAD_X, yFromTop(window_height, y, 1), layout.detail_w - PAD_X * 2, 1, line, 0.78);
    y += 14;

    const line_h = draw.cell_h + 4;
    const wrap_w = @max(1.0, layout.detail_w - PAD_X * 2);
    const total = wrappedLineCount(row.body, wrap_w, draw.glyphAdvance);
    const visible: usize = @intFromFloat(@max(0, @floor((window_height - y) / line_h)));
    session.detail_scroll = clampScroll(session.detail_scroll, total, visible);
    renderBody(draw, row.body, layout, window_height, y, fg, muted, session.detail_scroll);
}

fn renderBody(draw: DrawContext, body: []const u8, layout: Layout, window_height: f32, top: f32, fg: [3]f32, muted: [3]f32, scroll_lines: usize) void {
    if (body.len == 0) {
        _ = draw.renderTextLimited("(empty)", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top), muted, layout.detail_w - PAD_X * 2);
        return;
    }
    const line_h = draw.cell_h + 4;
    const wrap_w = @max(1.0, layout.detail_w - PAD_X * 2);
    var it = LineWrap{ .text = body, .max_w = wrap_w, .advance = draw.glyphAdvance };
    var line_index: usize = 0;
    var top_px = top;
    var drew_any = false;
    while (it.next()) |line| {
        if (line_index >= scroll_lines) {
            if (top_px + line_h > window_height) return;
            _ = draw.renderTextLimited(std.mem.trim(u8, line, "\r"), layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top_px), fg, wrap_w);
            top_px += line_h;
            drew_any = true;
        }
        line_index += 1;
    }
    if (!drew_any) {
        _ = draw.renderTextLimited("(empty)", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top), muted, wrap_w);
    }
}

const LineWrap = struct {
    text: []const u8,
    max_w: f32,
    advance: *const fn (u32) f32,
    pos: usize = 0,

    fn next(self: *LineWrap) ?[]const u8 {
        if (self.max_w <= 0 or self.pos >= self.text.len) return null;
        const start = self.pos;
        var i = start;
        var width: f32 = 0;
        var last_space: ?usize = null;
        while (i < self.text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(self.text[i]) catch 1;
            const end = @min(i + seq_len, self.text.len);
            const cp = std.unicode.utf8Decode(self.text[i..end]) catch 0xFFFD;
            if (cp == '\n') {
                self.pos = i + 1;
                return self.text[start..i];
            }
            const adv = self.advance(cp);
            if (width + adv > self.max_w and i > start) {
                if (last_space) |sp| {
                    if (sp > start) {
                        self.pos = sp + 1;
                        return self.text[start..sp];
                    }
                }
                self.pos = i;
                return self.text[start..i];
            }
            if (cp == ' ') last_space = i;
            width += adv;
            i = end;
        }
        self.pos = self.text.len;
        return self.text[start..];
    }
};

fn wrappedLineCount(text: []const u8, max_w: f32, advance: *const fn (u32) f32) usize {
    var it = LineWrap{ .text = text, .max_w = max_w, .advance = advance };
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    return count;
}

fn clampScroll(requested: usize, total: usize, visible: usize) usize {
    if (total <= visible) return 0;
    return @min(requested, total - visible);
}

fn sourceRowsTop(top: f32, cell_h: f32) f32 {
    return top + headerHeight(cell_h) + cell_h + 28;
}

fn rowHeight(cell_h: f32) f32 {
    return @max(ROW_H, cell_h * 2 + 22);
}

fn headerHeight(cell_h: f32) f32 {
    return @max(HEADER_H, cell_h + 18);
}

fn yFromTop(window_height: f32, top: f32, height: f32) f32 {
    return @round(window_height - top - height);
}

fn yTextFromTop(draw: DrawContext, window_height: f32, top: f32) f32 {
    return @round(window_height - top - draw.cell_h);
}

fn rectContains(x: f32, y: f32, left: f32, top: f32, w: f32, h: f32) bool {
    return x >= left and x < left + w and y >= top and y < top + h;
}

fn countColumnWidth(text: []const u8, advance: *const fn (u32) f32) f32 {
    var w: f32 = 0;
    for (text) |ch| w += advance(ch);
    return @max(14, w);
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        a[0] * (1 - t) + b[0] * t,
        a[1] * (1 - t) + b[1] * t,
        a[2] * (1 - t) + b[2] * t,
    };
}

fn testAdvance(_: u32) f32 {
    return 8;
}

test "memory center renderer computes stable three-column layout" {
    const layout = computeLayout(40, 1000);
    try std.testing.expect(layout.left_w >= 260);
    try std.testing.expect(layout.list_w >= 300);
    try std.testing.expect(layout.detail_w > 0);
    try std.testing.expectEqual(@as(f32, layout.left_x + layout.left_w), layout.list_x);
}

test "memory center renderer wraps body text" {
    try std.testing.expectEqual(@as(usize, 2), wrappedLineCount("alpha beta", 48, testAdvance));
    try std.testing.expectEqual(@as(usize, 2), wrappedLineCount("alpha\nbeta", 200, testAdvance));
}
