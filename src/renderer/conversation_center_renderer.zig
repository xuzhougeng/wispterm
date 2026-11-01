//! Workbench renderer for Conversation Center: source + date filters, session
//! list, transcript preview, footer hints. Pure geometry + draw callbacks.
const std = @import("std");
const i18n = @import("../i18n.zig");
const conversation_center = @import("../conversation_center/session.zig");
const panel_draw = @import("panel_draw.zig");
const ui_patterns = @import("ui_patterns.zig");
const copilot_picker = @import("../assistant/sidebar/picker.zig");

const HEADER_H: f32 = 54;
const ROW_H: f32 = 54;
const PAD_X: f32 = 16;
const SOURCE_ROW_H: f32 = 34;
const SMALL_GAP: f32 = 6;
const DATE_SLOTS: usize = 8;

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
    source: conversation_center.SourceFilter,
    all_dates,
    date: conversation_center.DateKey,
    row: usize,
    resume_btn,
    search,
    detail,
};

pub fn computeLayout(x: f32, width: f32) Layout {
    const available = @max(0, width);
    if (available == 0) {
        return .{ .left_x = x, .left_w = 0, .list_x = x, .list_w = 0, .detail_x = x, .detail_w = 0 };
    }
    const min_left_w: f32 = 220;
    const min_list_w: f32 = 280;
    const min_detail_w: f32 = 180;
    const min_total = min_left_w + min_list_w + min_detail_w;
    const left_w = if (available < min_total)
        available * (min_left_w / min_total)
    else
        @min(@max(available * 0.22, min_left_w), 300);
    const list_w = if (available < min_total)
        available * (min_list_w / min_total)
    else
        @min(@max(available * 0.34, min_list_w), 440);
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
    const footer_h = ui_patterns.workbenchFooterHeight(cell_h);
    const content_h = @round(@max(1.0, window_height - top - footer_h));
    const list_top = top + headerHeight(cell_h);
    const visible_h = @max(0, content_h - (list_top - top));
    return @intFromFloat(@max(0, @floor(visible_h / rowHeight(cell_h))));
}

pub fn hitTest(
    session: *const conversation_center.Session,
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
    const top = @round(titlebar_offset);
    const footer_top = ui_patterns.workbenchFooterTop(window_height, top, ui_patterns.workbenchFooterHeight(cell_h));
    if (my < top or my >= footer_top) return .none;
    const layout = computeLayout(@round(x), @round(@max(1.0, width)));
    const left = leftColumnLayout(top, cell_h);

    const source_h = sourceRowHeight(cell_h);
    for (conversation_center.SOURCE_ORDER, 0..) |source, i| {
        const row_top = left.source_rows_top + @as(f32, @floatFromInt(i)) * source_h;
        if (rectContains(mx, my, layout.left_x, row_top, layout.left_w, source_h)) return .{ .source = source };
    }

    const date_h = source_h;
    if (rectContains(mx, my, layout.left_x, left.date_rows_top, layout.left_w, date_h)) return .all_dates;
    const buckets = session.visibleDateBuckets(DATE_SLOTS);
    for (buckets, 0..) |bucket, j| {
        const row_top = left.date_rows_top + date_h * @as(f32, @floatFromInt(j + 1));
        if (rectContains(mx, my, layout.left_x, row_top, layout.left_w, date_h)) return .{ .date = bucket.key };
    }

    const header_h = headerHeight(cell_h);
    if (rectContains(mx, my, layout.list_x, top, layout.list_w, header_h)) return .search;

    const resume_rect = resumeButtonRect(layout, top, cell_h);
    if (session.selectedRow() != null and rectContains(mx, my, resume_rect.x, resume_rect.top, resume_rect.w, resume_rect.h)) return .resume_btn;

    const row_h = rowHeight(cell_h);
    const row_top = top + header_h;
    if (mx >= layout.list_x and mx < layout.list_x + layout.list_w and my >= row_top and my < footer_top) {
        const idx_float = (my - row_top) / row_h;
        if (idx_float >= 0) {
            const idx: usize = @intFromFloat(@floor(idx_float));
            const max_rows = listVisibleCapacity(window_height, top, cell_h);
            const start = session.listWindowStart(max_rows);
            const absolute = start + idx;
            if (idx < max_rows and absolute < session.filteredCount()) return .{ .row = absolute };
        }
    }

    if (mx >= layout.detail_x and mx < layout.detail_x + layout.detail_w and my >= top) return .detail;
    return .none;
}

pub fn render(
    draw: DrawContext,
    session: *conversation_center.Session,
    now_ms: i64,
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
    const footer_h = ui_patterns.workbenchFooterHeight(draw.cell_h);
    const content_bottom = ui_patterns.workbenchFooterTop(window_height, top, footer_h);
    draw.fillQuad(content_x, 0, content_w, content_h, bg);
    draw.fillQuadAlpha(layout.left_x, 0, layout.left_w, content_h, panel, 0.96);
    draw.fillQuadAlpha(layout.list_x, 0, layout.list_w, content_h, panel_soft, 0.98);
    draw.fillQuadAlpha(layout.detail_x, 0, layout.detail_w, content_h, bg, 1.0);
    draw.fillQuad(layout.list_x, 0, 1, content_h, line);
    draw.fillQuad(layout.detail_x, 0, 1, content_h, line);

    renderLeft(draw, session, layout, window_height, top, fg, muted, accent, selected_bg, panel_strong, line);
    renderList(draw, session, now_ms, layout, window_height, top, content_bottom, fg, muted, accent, selected_bg, line);
    renderDetail(draw, session, layout, window_height, content_bottom, top, fg, muted, accent, panel_strong, line);
    renderFooter(draw, content_x, content_w, window_height, content_bottom, footer_h, muted, line);
}

const LeftColumnLayout = struct {
    source_rows_top: f32,
    date_heading_top: f32,
    date_rows_top: f32,
};

fn leftColumnLayout(top: f32, cell_h: f32) LeftColumnLayout {
    const header_h = headerHeight(cell_h);
    const source_h = sourceRowHeight(cell_h);
    var y = top + header_h + cell_h + 28;
    const source_rows_top = y;
    y += source_h * @as(f32, @floatFromInt(conversation_center.SOURCE_ROWS));
    y += 16;
    const date_heading_top = y;
    y += cell_h + 8;
    return .{
        .source_rows_top = source_rows_top,
        .date_heading_top = date_heading_top,
        .date_rows_top = y,
    };
}

fn renderLeft(
    draw: DrawContext,
    session: *const conversation_center.Session,
    layout: Layout,
    window_height: f32,
    top: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    selected_bg: [3]f32,
    panel_strong: [3]f32,
    line: [3]f32,
) void {
    const header_h = headerHeight(draw.cell_h);
    const source_h = sourceRowHeight(draw.cell_h);
    const left = leftColumnLayout(top, draw.cell_h);
    const filters_focus = session.focus == .filters;

    draw.fillQuadAlpha(layout.left_x, yFromTop(window_height, top, header_h), layout.left_w, header_h, panel_strong, 0.9);
    draw.fillQuad(layout.left_x, yFromTop(window_height, top + header_h, 1), layout.left_w, 1, line);
    _ = draw.renderTextLimited(i18n.s().conversation_center_title, layout.left_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.left_w - PAD_X * 2);

    _ = draw.renderTextLimited(i18n.s().conversation_center_source, layout.left_x + PAD_X, yTextFromTop(draw, window_height, left.source_rows_top - draw.cell_h - 8), muted, layout.left_w - PAD_X * 2);
    for (conversation_center.SOURCE_ORDER, 0..) |source, i| {
        const row_top = left.source_rows_top + @as(f32, @floatFromInt(i)) * source_h;
        const active = session.source == source;
        const cursor = filters_focus and session.filter_cursor == i;
        drawFilterRow(draw, layout, window_height, row_top, source_h, sourceLabel(source), session.sourceCount(source), active, cursor, fg, muted, accent, selected_bg);
    }

    _ = draw.renderTextLimited(i18n.s().conversation_center_dates, layout.left_x + PAD_X, yTextFromTop(draw, window_height, left.date_heading_top), muted, layout.left_w - PAD_X * 2);
    drawFilterRow(
        draw,
        layout,
        window_height,
        left.date_rows_top,
        source_h,
        i18n.s().conversation_center_all_dates,
        session.sourceCount(session.source),
        session.date_filter == null,
        filters_focus and session.filter_cursor == conversation_center.FILTER_ALL_DATES_ROW,
        fg,
        muted,
        accent,
        selected_bg,
    );
    var date_buf: [16]u8 = undefined;
    for (session.visibleDateBuckets(DATE_SLOTS), 0..) |bucket, j| {
        const row_top = left.date_rows_top + source_h * @as(f32, @floatFromInt(j + 1));
        const abs_idx = session.date_offset + j;
        const label = conversation_center.formatDateKey(bucket.key, &date_buf);
        drawFilterRow(
            draw,
            layout,
            window_height,
            row_top,
            source_h,
            label,
            bucket.count,
            if (session.date_filter) |key| key == bucket.key else false,
            filters_focus and session.filter_cursor == conversation_center.FILTER_DAY_BASE + abs_idx,
            fg,
            muted,
            accent,
            selected_bg,
        );
    }
}

fn drawFilterRow(
    draw: DrawContext,
    layout: Layout,
    window_height: f32,
    row_top: f32,
    row_h: f32,
    label: []const u8,
    count: usize,
    active: bool,
    cursor: bool,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    selected_bg: [3]f32,
) void {
    const highlight = active or cursor;
    if (highlight) {
        const row_y = yFromTop(window_height, row_top, row_h);
        draw.fillQuadAlpha(layout.left_x, row_y, layout.left_w, row_h, selected_bg, if (cursor) 0.98 else 0.92);
        draw.fillQuad(layout.left_x, row_y, if (cursor) 4 else 3, row_h, accent);
    }
    var num_buf: [16]u8 = undefined;
    const num_text = std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch "";
    const count_w = countColumnWidth(num_text, draw.glyphAdvance);
    const count_x = layout.left_x + layout.left_w - PAD_X - count_w;
    const text_y = yTextFromTop(draw, window_height, row_top + (row_h - draw.cell_h) / 2);
    const color = if (highlight) fg else muted;
    _ = draw.renderTextLimited(label, layout.left_x + PAD_X + 6, text_y, color, @max(0, count_x - layout.left_x - PAD_X - 12));
    _ = draw.renderTextLimited(num_text, count_x, text_y, muted, count_w);
}

fn renderList(
    draw: DrawContext,
    session: *const conversation_center.Session,
    now_ms: i64,
    layout: Layout,
    window_height: f32,
    top: f32,
    content_bottom: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    selected_bg: [3]f32,
    line: [3]f32,
) void {
    const header_h = headerHeight(draw.cell_h);
    const row_h = rowHeight(draw.cell_h);
    draw.fillQuadAlpha(layout.list_x, yFromTop(window_height, top, header_h), layout.list_w, header_h, mixColor(draw.bg, fg, 0.055), 0.98);
    draw.fillQuad(layout.list_x, yFromTop(window_height, top + header_h, 1), layout.list_w, 1, line);

    const q = session.query();
    if (q.len > 0) {
        _ = draw.renderTextLimited(q, layout.list_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.list_w - PAD_X * 2);
    } else {
        _ = draw.renderTextLimited(i18n.s().conversation_center_search_placeholder, layout.list_x + PAD_X, yTextFromTop(draw, window_height, top + 11), muted, layout.list_w - PAD_X * 2);
    }

    const count = session.filteredCount();
    if (count == 0) {
        _ = draw.renderTextLimited(i18n.s().conversation_center_empty, layout.list_x + PAD_X, yTextFromTop(draw, window_height, top + header_h + 24), muted, layout.list_w - PAD_X * 2);
        return;
    }

    const max_rows = listVisibleCapacity(window_height, top, draw.cell_h);
    const start = session.listWindowStart(max_rows);
    var i: usize = 0;
    while (i < max_rows) : (i += 1) {
        const abs = start + i;
        if (abs >= count) break;
        const row = session.rows[session.filtered.items[abs]];
        const row_top = top + header_h + @as(f32, @floatFromInt(i)) * row_h;
        if (row_top + row_h > content_bottom) break;
        const selected = abs == session.selected and session.focus != .filters;
        if (selected) {
            draw.fillQuadAlpha(layout.list_x, yFromTop(window_height, row_top, row_h), layout.list_w, row_h, selected_bg, 0.94);
            draw.fillQuad(layout.list_x, yFromTop(window_height, row_top, row_h), 4, row_h, accent);
        }
        const title_color = if (selected) fg else mixColor(draw.bg, fg, 0.86);
        const meta_color = if (selected) mixColor(fg, accent, 0.08) else muted;
        var tbuf: [32]u8 = undefined;
        const rel = copilot_picker.formatRelativeTime(now_ms, row.updated_at, &tbuf);
        const text_x = layout.list_x + PAD_X + 8;
        const text_w = @max(0, layout.list_w - PAD_X * 2 - 8);
        const text_y = yTextFromTop(draw, window_height, row_top + 8);
        const tag = if (row.copilot) i18n.s().cmd_palette_sidebar_tag else row.model;
        const columns = ui_patterns.textColumns(text_w, measure(tag, draw.glyphAdvance), measure(rel, draw.glyphAdvance), 12);
        // Metadata belongs below its title. GL y increases upwards; adding a
        // line height here used to paint model IDs over the previous row/header.
        const meta_y = text_y - draw.cell_h - 4;
        _ = draw.renderTextLimited(row.title, text_x, text_y, title_color, text_w);
        _ = draw.renderTextLimited(tag, text_x, meta_y, meta_color, columns.left_w);
        _ = draw.renderTextLimited(rel, text_x + columns.right_x, meta_y, meta_color, columns.right_w);
    }
}

fn resumeButtonRect(layout: Layout, top: f32, cell_h: f32) struct { x: f32, top: f32, w: f32, h: f32 } {
    const header_h = headerHeight(cell_h);
    const label = i18n.s().conversation_center_resume;
    const label_chars = std.unicode.utf8CountCodepoints(label) catch label.len;
    const preferred_w = @max(72.0, @as(f32, @floatFromInt(label_chars)) * cell_h + 24.0);
    const w = @min(preferred_w, @max(0, layout.detail_w - PAD_X * 2));
    return .{
        .x = layout.detail_x + layout.detail_w - PAD_X - w,
        .top = top + (header_h - (cell_h + 12)) / 2,
        .w = w,
        .h = cell_h + 12,
    };
}

fn renderDetail(
    draw: DrawContext,
    session: *conversation_center.Session,
    layout: Layout,
    window_height: f32,
    content_bottom: f32,
    top: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    panel_strong: [3]f32,
    line: [3]f32,
) void {
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(layout.detail_x, yFromTop(window_height, top, header_h), layout.detail_w, header_h, panel_strong, 0.82);
    draw.fillQuad(layout.detail_x, yFromTop(window_height, top + header_h, 1), layout.detail_w, 1, line);
    _ = draw.renderTextLimited(i18n.s().conversation_center_detail, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, @max(0, resumeButtonRect(layout, top, draw.cell_h).x - layout.detail_x - PAD_X - 12));

    const row = session.selectedRow() orelse {
        const empty = if (session.filteredCount() == 0)
            i18n.s().conversation_center_detail_empty
        else
            i18n.s().conversation_center_detail_select;
        _ = draw.renderTextLimited(empty, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top + header_h + 24), muted, layout.detail_w - PAD_X * 2);
        return;
    };

    const resume_rect = resumeButtonRect(layout, top, draw.cell_h);
    draw.fillQuadAlpha(resume_rect.x, yFromTop(window_height, resume_rect.top, resume_rect.h), resume_rect.w, resume_rect.h, mixColor(draw.bg, accent, 0.22), 0.98);
    _ = draw.renderTextLimited(i18n.s().conversation_center_resume, resume_rect.x + 10, yTextFromTop(draw, window_height, resume_rect.top + (resume_rect.h - draw.cell_h) / 2), accent, resume_rect.w - 20);

    var y = top + header_h + 18;
    _ = draw.renderTextLimited(row.title, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), fg, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 8;
    const tag = if (row.copilot) i18n.s().cmd_palette_sidebar_tag else row.model;
    _ = draw.renderTextLimited(tag, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), accent, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 14;
    draw.fillQuadAlpha(layout.detail_x + PAD_X, yFromTop(window_height, y, 1), layout.detail_w - PAD_X * 2, 1, line, 0.78);
    y += 14;

    const body = if (session.previewMatchesSelection()) session.preview_body else "";
    if (body.len == 0) {
        _ = draw.renderTextLimited(i18n.s().conversation_center_detail_select, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2);
        return;
    }

    const line_h = draw.cell_h + 4;
    const wrap_w = @max(1.0, layout.detail_w - PAD_X * 2);
    const total = wrappedLineCount(body, wrap_w, draw.glyphAdvance);
    const visible: usize = @intFromFloat(@max(0, @floor((content_bottom - y) / line_h)));
    session.detail_scroll = clampScroll(session.detail_scroll, total, visible);
    renderBody(draw, body, layout, window_height, content_bottom, y, fg, muted, session.detail_scroll);
}

fn renderBody(draw: DrawContext, body: []const u8, layout: Layout, window_height: f32, content_bottom: f32, top: f32, fg: [3]f32, muted: [3]f32, scroll_lines: usize) void {
    const line_h = draw.cell_h + 4;
    const wrap_w = @max(1.0, layout.detail_w - PAD_X * 2);
    var it = LineWrap{ .text = body, .max_w = wrap_w, .advance = draw.glyphAdvance };
    var line_index: usize = 0;
    var y = top;
    while (it.next()) |line| {
        if (line_index >= scroll_lines) {
            if (y + line_h > content_bottom) break;
            const color = if (std.mem.eql(u8, line, "You") or std.mem.eql(u8, line, "Assistant") or std.mem.eql(u8, line, "Tool")) muted else fg;
            _ = draw.renderTextLimited(line, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), color, wrap_w);
            y += line_h;
        }
        line_index += 1;
    }
}

fn renderFooter(draw: DrawContext, content_x: f32, content_w: f32, window_height: f32, footer_top: f32, footer_h: f32, muted: [3]f32, line: [3]f32) void {
    draw.fillQuadAlpha(content_x, yFromTop(window_height, footer_top, footer_h), content_w, footer_h, mixColor(draw.bg, draw.fg, 0.035), 0.98);
    draw.fillQuad(content_x, yFromTop(window_height, footer_top, 1), content_w, 1, line);
    _ = draw.renderTextLimited(i18n.s().conversation_center_footer, content_x + PAD_X, yTextFromTop(draw, window_height, footer_top + (footer_h - draw.cell_h) / 2), muted, content_w - PAD_X * 2);
}

fn sourceLabel(source: conversation_center.SourceFilter) []const u8 {
    return switch (source) {
        .all => i18n.s().cmd_palette_source_all,
        .sidebar => i18n.s().cmd_palette_source_sidebar,
        .tab => i18n.s().cmd_palette_source_tab,
    };
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
    return @max(count, 1);
}

fn clampScroll(requested: usize, total: usize, visible: usize) usize {
    if (total <= visible) return 0;
    return @min(requested, total - visible);
}

fn headerHeight(cell_h: f32) f32 {
    return @max(HEADER_H, cell_h + 18);
}

fn rowHeight(cell_h: f32) f32 {
    return @max(ROW_H, cell_h * 2 + 22);
}

fn sourceRowHeight(cell_h: f32) f32 {
    return @max(SOURCE_ROW_H, cell_h + 12);
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

fn measure(text: []const u8, advance: *const fn (u32) f32) f32 {
    var w: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq_len, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch 0xFFFD;
        w += advance(cp);
        i = end;
    }
    return w;
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        a[0] * (1 - t) + b[0] * t,
        a[1] * (1 - t) + b[1] * t,
        a[2] * (1 - t) + b[2] * t,
    };
}

test "conversation center renderer computes three columns" {
    const layout = computeLayout(40, 1200);
    try std.testing.expect(layout.left_w >= 220);
    try std.testing.expect(layout.list_w >= 280);
    try std.testing.expect(layout.detail_w > 0);
    try std.testing.expectEqual(layout.left_x + layout.left_w, layout.list_x);
    try std.testing.expectEqual(layout.list_x + layout.list_w, layout.detail_x);
}

test "conversation center hit-test finds source rows" {
    var session = conversation_center.Session.init(std.testing.allocator);
    defer session.deinit();
    const layout = computeLayout(0, 1200);
    const left = leftColumnLayout(40, 20);
    const hit = hitTest(&session, 800, 40, 0, 1200, 20, layout.left_x + 8, left.source_rows_top + 4);
    switch (hit) {
        .source => |src| try std.testing.expectEqual(conversation_center.SourceFilter.all, src),
        else => return error.ExpectedSourceHit,
    }
}

test "conversation metadata stays below its title and inside the list column" {
    const Probe = struct {
        var left: f32 = 0;
        var right: f32 = 0;
        var title_y: f32 = 0;
        var model_y: f32 = 0;
        var escaped: bool = false;
        fn quad(_: f32, _: f32, _: f32, _: f32, _: [3]f32) void {}
        fn alpha(_: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
        fn advance(_: u32) f32 {
            return 12;
        }
        fn text(s: []const u8, x: f32, y: f32, _: [3]f32, max_w: f32) f32 {
            if (max_w > 0 and (x < left or x + max_w > right + 0.01)) escaped = true;
            if (std.mem.eql(u8, s, "Conversation title")) title_y = y;
            if (std.mem.startsWith(u8, s, "very-long-model")) model_y = y;
            return x + @min(@max(0, max_w), @as(f32, @floatFromInt(s.len)) * 12);
        }
    };
    var session = conversation_center.Session.init(std.testing.allocator);
    defer session.deinit();
    var rows = [_]@import("../agent/history.zig").Row{.{
        .session_id = "test",
        .title = "Conversation title",
        .model = "very-long-model-name-that-used-to-overlap-the-source-column",
        .updated_at = 0,
    }};
    session.rows = &rows;
    try session.filtered.append(std.testing.allocator, 0);
    for ([_]f32{ 380, 582, 1000 }) |width| {
        for ([_]f32{ 20, 40 }) |cell_h| {
            const l = computeLayout(220, width);
            Probe.left = l.list_x;
            Probe.right = l.list_x + l.list_w;
            Probe.escaped = false;
            const draw = DrawContext{
                .bg = .{ 0, 0, 0 },
                .fg = .{ 1, 1, 1 },
                .accent = .{ 1, 1, 0 },
                .cell_h = cell_h,
                .fillQuad = Probe.quad,
                .fillQuadAlpha = Probe.alpha,
                .renderTextLimited = Probe.text,
                .glyphAdvance = Probe.advance,
            };
            renderList(draw, &session, 0, l, 600, 34, 550, draw.fg, draw.fg, draw.accent, draw.bg, draw.bg);
            try std.testing.expect(!Probe.escaped);
            try std.testing.expect(Probe.model_y + cell_h <= Probe.title_y);
            try std.testing.expect(Probe.model_y >= 600 - 34 - headerHeight(cell_h) - rowHeight(cell_h));
        }
    }
}
