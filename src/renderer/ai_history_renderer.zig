const std = @import("std");
const ai_history_session = @import("../ai_history_session.zig");
const types = @import("../ai_history_types.zig");
const i18n = @import("../i18n.zig");

const HEADER_H: f32 = 54;
const FILTER_H: f32 = 42;
const ROW_H: f32 = 54;
const PAD_X: f32 = 16;
const SMALL_GAP: f32 = 6;
const BUTTON_PAD_Y: f32 = 4;
const BUTTON_EXTRA_H: f32 = 10;
const RESUME_BUTTON_W: f32 = 104;
/// Width of the "r Retry" affordance sharing the Status value line (right-aligned).
const RETRY_LABEL_W: f32 = 70;
const MAX_DATE_BUCKETS: usize = 256;

pub const DrawContext = struct {
    bg: [3]f32,
    fg: [3]f32,
    accent: [3]f32,
    cell_h: f32,
    fillQuad: *const fn (f32, f32, f32, f32, [3]f32) void,
    fillQuadAlpha: *const fn (f32, f32, f32, f32, [3]f32, f32) void,
    renderTextLimited: *const fn ([]const u8, f32, f32, [3]f32, f32) f32,
    // Advance width (px) of a single glyph in the UI font, used to wrap
    // transcript text. Must use the same metric as renderTextLimited.
    glyphAdvance: *const fn (u32) f32,
};

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
    refresh,
    @"resume",
    category: types.CategoryFilter,
    date: ?types.DateKey,
    row: usize,
};

pub const LeftColumnLayout = struct {
    source_name_top: f32,
    status_label_top: f32,
    status_value_top: f32,
    /// Retry/rescan affordance — shares the status value line, right-aligned.
    retry_text_top: f32,
    category_heading_top: f32,
    category_rows_top: f32,
    category_row_h: f32,
    date_heading_top: f32,
    date_rows_top: f32,
    date_row_h: f32,
};

pub fn leftColumnLayout(top: f32, cell_h: f32) LeftColumnLayout {
    var y = top + headerHeight(cell_h) + 18;
    const source_name_top = y;
    y += cell_h + 16; // single source line (the target type no longer duplicates it)
    const status_label_top = y;
    y += cell_h + 5;
    const status_value_top = y;
    // Retry shares the status value line (it is scan-related), so CATEGORY and
    // DATE become one contiguous filter group below.
    const retry_text_top = status_value_top;
    y += cell_h + 18;
    const category_heading_top = y;
    y += cell_h + 8;
    const category_rows_top = y;
    const category_row_h = cell_h + 10;
    y += category_row_h * @as(f32, @floatFromInt(types.CATEGORY_ORDER.len));
    y += 14;
    const date_heading_top = y;
    y += cell_h + 8;
    const date_rows_top = y;
    const date_row_h = category_row_h;
    return .{
        .source_name_top = source_name_top,
        .status_label_top = status_label_top,
        .status_value_top = status_value_top,
        .retry_text_top = retry_text_top,
        .category_heading_top = category_heading_top,
        .category_rows_top = category_rows_top,
        .category_row_h = category_row_h,
        .date_heading_top = date_heading_top,
        .date_rows_top = date_rows_top,
        .date_row_h = date_row_h,
    };
}

pub fn computeLayout(x: f32, width: f32) Layout {
    const available = @max(0, width);
    if (available == 0) {
        return .{
            .left_x = x,
            .left_w = 0,
            .list_x = x,
            .list_w = 0,
            .detail_x = x,
            .detail_w = 0,
        };
    }

    const min_left_w: f32 = 180;
    const min_list_w: f32 = 260;
    const min_detail_w: f32 = 120;
    const min_total = min_left_w + min_list_w + min_detail_w;
    const left_w = if (available < min_total)
        available * (min_left_w / min_total)
    else
        @min(@max(available * 0.20, min_left_w), 260);
    const list_w = if (available < min_total)
        available * (min_list_w / min_total)
    else
        @min(@max(available * 0.32, min_list_w), 420);
    const detail_w = available - left_w - list_w;
    return .{
        .left_x = x,
        .left_w = left_w,
        .list_x = x + left_w,
        .list_w = list_w,
        .detail_x = x + left_w + list_w,
        .detail_w = detail_w,
    };
}

pub fn hitTest(layout: Layout, x: f32, y_from_top: f32, row_top: f32, row_h: f32, row_count: usize) Hit {
    if (x >= layout.list_x and x < layout.list_x + layout.list_w and y_from_top >= row_top) {
        const idx_float = (y_from_top - row_top) / row_h;
        if (idx_float >= 0) {
            const idx: usize = @intFromFloat(@floor(idx_float));
            if (idx < row_count) return .{ .row = idx };
        }
    }
    return .none;
}

// Vertical band metrics scale with the UI font's cell height so the layout
// stays readable on high-DPI displays. The fixed constants act as floors so
// behaviour at the default (~16px) cell height is unchanged.
fn rowHeight(cell_h: f32) f32 {
    // Fits two stacked text lines (title + path) plus padding; see rowTextLayout.
    return @max(ROW_H, cell_h * 2 + 22);
}

fn filterHeight(cell_h: f32) f32 {
    return @max(FILTER_H, cell_h + 18);
}

fn headerHeight(cell_h: f32) f32 {
    return @max(HEADER_H, cell_h + 18);
}

const RowTextLayout = struct {
    title_top: f32,
    detail_top: f32,
};

// Offsets (from the row's top edge) of the two text lines drawn in a list row:
// the provider+title line on top and the project-path line below it.
fn rowTextLayout(cell_h: f32) RowTextLayout {
    const rh = rowHeight(cell_h);
    return .{
        .title_top = 8,
        .detail_top = rh - 9 - cell_h,
    };
}

pub fn listVisibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    const visible_h = @max(0, content_h - filterHeight(cell_h));
    return @intFromFloat(@max(0, @floor(visible_h / rowHeight(cell_h))));
}

pub fn interactionHitTest(
    session: anytype,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    x: f32,
    width: f32,
    cell_h: f32,
    mouse_x: f64,
    mouse_y: f64,
) Hit {
    _ = window_width;
    const content_x = @round(x);
    const content_w = @round(@max(1.0, width));
    const top = @round(titlebar_offset);
    const layout = computeLayout(content_x, content_w);
    const mx: f32 = @floatCast(mouse_x);
    const my: f32 = @floatCast(mouse_y);

    const lc = leftColumnLayout(top, cell_h);
    for (types.CATEGORY_ORDER, 0..) |cat, i| {
        const cat_top = lc.category_rows_top + @as(f32, @floatFromInt(i)) * lc.category_row_h;
        if (rectContains(mx, my, layout.left_x, cat_top, layout.left_w, lc.category_row_h)) {
            return .{ .category = cat };
        }
    }

    // Retry shares the Status value line, right-aligned; only that label is clickable.
    const refresh_top = refreshButtonTop(top, cell_h);
    const retry_x = layout.left_x + layout.left_w - PAD_X - RETRY_LABEL_W;
    if (rectContains(mx, my, retry_x, refresh_top, RETRY_LABEL_W, buttonHeight(cell_h))) {
        return .refresh;
    }

    // DATE navigator rows (below the Refresh button). Row 0 = pinned "All dates"
    // (-> null); rows 1.. map to the windowed day buckets.
    {
        var bucket_buf: [MAX_DATE_BUCKETS]types.DateBucket = undefined;
        const buckets = session.buildDateBuckets(&bucket_buf);
        const cap = dateVisibleCapacity(window_height, lc.date_rows_top, cell_h);
        if (cap > 0) {
            if (rectContains(mx, my, layout.left_x, lc.date_rows_top, layout.left_w, lc.date_row_h)) {
                return .{ .date = null };
            }
            const day_slots = cap - 1;
            const offset = clampDateOffset(session.date_offset, buckets.len, day_slots);
            var j: usize = 0;
            while (j < day_slots and offset + j < buckets.len) : (j += 1) {
                const row_top = lc.date_rows_top + @as(f32, @floatFromInt(j + 1)) * lc.date_row_h;
                if (rectContains(mx, my, layout.left_x, row_top, layout.left_w, lc.date_row_h)) {
                    return .{ .date = buckets[offset + j].key };
                }
            }
        }
    }

    const visible_count = session.visibleCount();
    if (visible_count > 0) {
        const resume_top = resumeButtonTop(top, cell_h);
        if (rectContains(mx, my, layout.detail_x + PAD_X, resume_top, RESUME_BUTTON_W, buttonHeight(cell_h))) {
            return .@"resume";
        }
    }

    const max_rows = listVisibleCapacity(window_height, top, cell_h);
    const start = session.listWindowStart(max_rows);
    const row_count = if (visible_count > start) @min(max_rows, visible_count - start) else 0;
    return switch (hitTest(layout, mx, my, top + filterHeight(cell_h), rowHeight(cell_h), row_count)) {
        .row => |idx| .{ .row = start + idx },
        else => .none,
    };
}

pub fn render(
    draw: DrawContext,
    session: anytype,
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
    const panel_strong = mixColor(bg, fg, 0.075);
    const line = mixColor(bg, fg, 0.18);
    const muted = mixColor(bg, fg, 0.58);
    const selected_bg = mixColor(bg, accent, 0.18);

    const layout = computeLayout(content_x, content_w);
    draw.fillQuad(content_x, 0, content_w, content_h, bg);
    draw.fillQuadAlpha(layout.left_x, 0, layout.left_w, content_h, panel, 0.96);
    draw.fillQuadAlpha(layout.list_x, 0, layout.list_w, content_h, mixColor(bg, fg, 0.025), 0.98);
    draw.fillQuadAlpha(layout.detail_x, 0, layout.detail_w, content_h, bg, 1.0);
    draw.fillQuad(layout.list_x, 0, 1, content_h, line);
    draw.fillQuad(layout.detail_x, 0, 1, content_h, line);

    renderLeftColumn(draw, session, layout, window_height, top, content_h, fg, muted, accent, panel_strong, line);
    renderList(draw, session, layout, window_height, top, content_h, fg, muted, accent, selected_bg, line);
    renderDetail(draw, session, layout, window_height, top, content_h, fg, muted, accent, panel_strong, line);
}

fn drawDateRow(
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
    const text_top = row_top + (row_h - draw.cell_h) / 2;
    const label_color = if (highlight) fg else muted;
    var num_buf: [16]u8 = undefined;
    const num_text = std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch "";
    const count_w: f32 = 44;
    const count_x = layout.left_x + layout.left_w - PAD_X - count_w;
    const label_x = layout.left_x + PAD_X + 6;
    _ = draw.renderTextLimited(label, label_x, yTextFromTop(draw, window_height, text_top), label_color, @max(0, count_x - label_x - 6));
    _ = draw.renderTextLimited(num_text, count_x, yTextFromTop(draw, window_height, text_top), muted, count_w);
}

fn renderLeftColumn(
    draw: DrawContext,
    session: anytype,
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
    const filters_focused = session.focus == .filters;
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(layout.left_x, yFromTop(window_height, top, header_h), layout.left_w, header_h, panel_strong, 0.9);
    draw.fillQuad(layout.left_x, yFromTop(window_height, top + header_h, 1), layout.left_w, 1, line);
    _ = draw.renderTextLimited(i18n.s().sl_sessions, layout.left_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.left_w - PAD_X * 2);
    drawFocusUnderline(draw, layout.left_x, layout.left_w, window_height, top, header_h, accent, filters_focused);

    const lc = leftColumnLayout(top, draw.cell_h);
    var source_buf: [160]u8 = undefined;
    _ = draw.renderTextLimited(sourceDisplayText(session.source, &source_buf), layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.source_name_top), fg, layout.left_w - PAD_X * 2);

    // Status label, plus the rescan affordance sharing the value line on the right.
    _ = draw.renderTextLimited("Status", layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.status_label_top), muted, layout.left_w - PAD_X * 2);
    const retry_x = layout.left_x + layout.left_w - PAD_X - RETRY_LABEL_W;
    _ = draw.renderTextLimited("r Retry", retry_x, yTextFromTop(draw, window_height, lc.retry_text_top), muted, RETRY_LABEL_W);
    var status_buf: [48]u8 = undefined;
    const status_label = if (session.state == .scanning)
        ai_history_session.scanningStatusLabel(&status_buf, session.rows.items.len)
    else
        statusText(session);
    _ = draw.renderTextLimited(status_label, layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.status_value_top), accent, @max(0, retry_x - (layout.left_x + PAD_X) - 8));

    _ = draw.renderTextLimited("CATEGORY", layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.category_heading_top), muted, layout.left_w - PAD_X * 2);

    const query = session.filter[0..session.filter_len];
    const counts = session.categoryCounts(query);
    const selected_bg = mixColor(draw.bg, accent, 0.18);
    for (types.CATEGORY_ORDER, 0..) |cat, i| {
        const row_top = lc.category_rows_top + @as(f32, @floatFromInt(i)) * lc.category_row_h;
        const active = session.category == cat;
        const cursor = filters_focused and session.filter_cursor == i;
        const highlight = active or cursor;
        if (highlight) {
            const row_y = yFromTop(window_height, row_top, lc.category_row_h);
            draw.fillQuadAlpha(layout.left_x, row_y, layout.left_w, lc.category_row_h, selected_bg, if (cursor) 0.98 else 0.92);
            draw.fillQuad(layout.left_x, row_y, if (cursor) 4 else 3, lc.category_row_h, accent);
        }
        const text_top = row_top + (lc.category_row_h - draw.cell_h) / 2;
        const label_color = if (highlight) fg else muted;
        const count = types.categoryCount(counts, cat);
        var num_buf: [16]u8 = undefined;
        const num_text = std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch "";
        const count_w: f32 = 44;
        const count_x = layout.left_x + layout.left_w - PAD_X - count_w;
        const label_x = layout.left_x + PAD_X + 6;
        _ = draw.renderTextLimited(categoryLabelText(cat), label_x, yTextFromTop(draw, window_height, text_top), label_color, @max(0, count_x - label_x - 6));
        _ = draw.renderTextLimited(num_text, count_x, yTextFromTop(draw, window_height, text_top), muted, count_w);
    }

    _ = draw.renderTextLimited("DATE", layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.date_heading_top), muted, layout.left_w - PAD_X * 2);
    var bucket_buf: [MAX_DATE_BUCKETS]types.DateBucket = undefined;
    const buckets = session.buildDateBuckets(&bucket_buf);
    const date_cap = dateVisibleCapacity(window_height, lc.date_rows_top, draw.cell_h);
    if (date_cap > 0) {
        const all_dates_cursor = filters_focused and session.filter_cursor == ai_history_session.FILTER_ALL_DATES_ROW;
        drawDateRow(draw, layout, window_height, lc.date_rows_top, lc.date_row_h, "All dates", session.dateAllCount(), session.date_filter == null, all_dates_cursor, fg, muted, accent, selected_bg);
        const day_slots = date_cap - 1;
        const offset = clampDateOffset(session.date_offset, buckets.len, day_slots);
        var j: usize = 0;
        while (j < day_slots and offset + j < buckets.len) : (j += 1) {
            const bucket = buckets[offset + j];
            const row_top = lc.date_rows_top + @as(f32, @floatFromInt(j + 1)) * lc.date_row_h;
            var label_buf: [16]u8 = undefined;
            const label = types.formatDateKey(bucket.key, &label_buf);
            const active = session.date_filter != null and session.date_filter.? == bucket.key;
            const cursor = filters_focused and session.filter_cursor == ai_history_session.FILTER_DAY_BASE + offset + j;
            drawDateRow(draw, layout, window_height, row_top, lc.date_row_h, label, bucket.count, active, cursor, fg, muted, accent, selected_bg);
        }
    }

    const footer = "Enter resumes  Space previews";
    _ = draw.renderTextLimited(footer, layout.left_x + PAD_X, 12, muted, layout.left_w - PAD_X * 2);
    _ = content_h;
}

fn renderList(
    draw: DrawContext,
    session: anytype,
    layout: Layout,
    window_height: f32,
    top: f32,
    content_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    selected_bg: [3]f32,
    line: [3]f32,
) void {
    const filter_h = filterHeight(draw.cell_h);
    const filter_y = yFromTop(window_height, top, filter_h);
    draw.fillQuadAlpha(layout.list_x, filter_y, layout.list_w, filter_h, mixColor(draw.bg, fg, 0.055), 0.98);
    draw.fillQuad(layout.list_x, yFromTop(window_height, top + filter_h, 1), layout.list_w, 1, line);
    drawFocusUnderline(draw, layout.list_x, layout.list_w, window_height, top, filter_h, accent, session.focus == .sessions);

    const query = session.filter[0..session.filter_len];
    const filter_label = if (query.len == 0) "Search sessions" else query;
    const filter_color = if (query.len == 0) muted else fg;
    _ = draw.renderTextLimited(filter_label, layout.list_x + PAD_X, yTextFromTop(draw, window_height, top + 11), filter_color, layout.list_w - PAD_X * 2);

    const row_h = rowHeight(draw.cell_h);
    const lines = rowTextLayout(draw.cell_h);
    const row_top = top + filter_h;
    _ = content_h;
    const max_rows = listVisibleCapacity(window_height, top, draw.cell_h);
    const start = session.listWindowStart(max_rows);
    var visible_index: usize = 0;
    var rendered: usize = 0;
    for (session.rows.items) |row| {
        // Use the same visibility predicate as visibleCount/selectedVisible/
        // listWindowStart so the rendered rows, the selection index, and the
        // hit-test all agree (category AND date AND text query).
        if (!session.rowVisible(row, query)) continue;
        if (visible_index < start) {
            visible_index += 1;
            continue;
        }
        if (rendered >= max_rows) break;

        const row_top_px = row_top + @as(f32, @floatFromInt(rendered)) * row_h;
        const row_y = yFromTop(window_height, row_top_px, row_h);
        const selected = visible_index == session.selected;
        if (selected) {
            draw.fillQuadAlpha(layout.list_x, row_y, layout.list_w, row_h, selected_bg, 0.92);
            draw.fillQuad(layout.list_x, row_y, 3, row_h, accent);
        }
        draw.fillQuadAlpha(layout.list_x, row_y, layout.list_w, 1, line, 0.55);

        const title = displayTitle(row);
        const title_y = yTextFromTop(draw, window_height, row_top_px + lines.title_top);
        const provider_end = draw.renderTextLimited(row.provider.label(), layout.list_x + PAD_X, title_y, accent, 86);
        _ = draw.renderTextLimited(title, provider_end + 8, title_y, fg, layout.list_w - (provider_end - layout.list_x) - PAD_X - 8);
        const detail = if (row.project_dir.len > 0) row.project_dir else row.source_path;
        const detail_y = yTextFromTop(draw, window_height, row_top_px + lines.detail_top);
        _ = draw.renderTextLimited(detail, layout.list_x + PAD_X, detail_y, muted, layout.list_w - PAD_X * 2);

        rendered += 1;
        visible_index += 1;
    }

    if (session.visibleCount() == 0) {
        const empty = if (session.state == .scanning)
            "Scanning AI history..."
        else if (session.rows.items.len == 0)
            "No AI history found"
        else switch (session.category) {
            .all => "No sessions match filter",
            .codex => "No Codex sessions",
            .claude => "No Claude Code sessions",
            .reasonix => "No Reasonix sessions",
            .subagent => "No Subagent sessions",
        };
        _ = draw.renderTextLimited(empty, layout.list_x + PAD_X, yTextFromTop(draw, window_height, row_top + 24), muted, layout.list_w - PAD_X * 2);
    }
}

fn renderDetail(
    draw: DrawContext,
    session: anytype,
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
    _ = draw.renderTextLimited("Transcript Preview", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.detail_w - PAD_X * 2);
    drawFocusUnderline(draw, layout.detail_x, layout.detail_w, window_height, top, header_h, accent, session.focus == .transcript);

    const selected = session.selectedVisible() orelse {
        _ = draw.renderTextLimited("Select a session", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top + header_h + 24), muted, layout.detail_w - PAD_X * 2);
        return;
    };

    var y = top + header_h + 18;
    _ = draw.renderTextLimited(displayTitle(selected), layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), fg, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 8;
    _ = draw.renderTextLimited(selected.provider.label(), layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), accent, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 8;
    _ = draw.renderTextLimited(if (selected.project_dir.len > 0) selected.project_dir else "Project dir unavailable", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 8;
    _ = draw.renderTextLimited(selected.source_path, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 16;
    const resume_top = resumeButtonTop(top, draw.cell_h);
    const can_resume = selected.project_dir.len > 0;
    draw.fillQuadAlpha(layout.detail_x + PAD_X, yFromTop(window_height, resume_top, buttonHeight(draw.cell_h)), RESUME_BUTTON_W, buttonHeight(draw.cell_h), panel_strong, 0.72);
    _ = draw.renderTextLimited(if (can_resume) "Resume" else "Resume unavailable", layout.detail_x + PAD_X + 12, yTextFromTop(draw, window_height, y), if (can_resume) accent else muted, RESUME_BUTTON_W - 24);

    y += draw.cell_h + 20;
    draw.fillQuadAlpha(layout.detail_x + PAD_X, yFromTop(window_height, y, 1), layout.detail_w - PAD_X * 2, 1, line, 0.78);
    y += 14;

    switch (session.transcript_state) {
        .idle => _ = draw.renderTextLimited("Press Space to load transcript", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2),
        .loading => _ = draw.renderTextLimited("Loading transcript", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2),
        .failed => _ = draw.renderTextLimited("Transcript failed to load - press Space to retry", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), accent, layout.detail_w - PAD_X * 2),
        .ready => {
            // Clamp the stored scroll against the actual wrapped height every
            // frame so it self-corrects (e.g. after the window or font resizes),
            // then render from that offset. Safe to write back: render runs while
            // the session mutex is held.
            const line_h = draw.cell_h + 4;
            const wrap_w = @max(1.0, layout.detail_w - PAD_X * 2 - 12);
            const total = transcriptLineTotal(session.transcript, wrap_w, draw.glyphAdvance);
            const visible: usize = @intFromFloat(@max(0, @floor((window_height - y) / line_h)));
            const scroll = clampScroll(session.transcript_scroll, total, visible);
            session.transcript_scroll = scroll;
            renderTranscriptMessages(draw, session.transcript, layout, window_height, y, content_h, fg, muted, accent, scroll);
        },
    }
}

// Wraps a single message's text into visual lines that each fit within `max_w`,
// using the caller-supplied glyph advance metric. Breaks on explicit '\n' and,
// when a line overflows, at the last space if one exists (word wrap) or at the
// codepoint boundary otherwise (hard wrap). At least one glyph is emitted per
// line so an oversized glyph can never stall iteration.
const LineWrap = struct {
    text: []const u8,
    max_w: f32,
    advance: *const fn (u32) f32,
    pos: usize = 0,

    fn next(self: *LineWrap) ?[]const u8 {
        if (self.max_w <= 0) return null;
        if (self.pos >= self.text.len) return null;

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

// Total visual lines a transcript occupies: one role-label line plus the
// wrapped content lines for every message. Matches the line accounting in
// renderTranscriptMessages so scroll offsets stay consistent.
fn transcriptLineTotal(messages: anytype, wrap_w: f32, advance: *const fn (u32) f32) usize {
    var total: usize = 0;
    for (messages) |msg| {
        total += 1 + wrappedLineCount(msg.content, wrap_w, advance);
    }
    return total;
}

// Clamp a requested scroll offset (in visual lines) to the range that keeps at
// least `visible` lines on screen; returns 0 when everything already fits.
fn clampScroll(requested: usize, total: usize, visible: usize) usize {
    if (total <= visible) return 0;
    const max_scroll = total - visible;
    return @min(requested, max_scroll);
}

fn renderTranscriptMessages(
    draw: DrawContext,
    messages: anytype,
    layout: Layout,
    window_height: f32,
    start_top: f32,
    content_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    scroll_lines: usize,
) void {
    if (messages.len == 0) {
        _ = draw.renderTextLimited("Transcript is empty", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, start_top), muted, layout.detail_w - PAD_X * 2);
        return;
    }

    _ = content_h;
    const line_h = draw.cell_h + 4;
    const text_x = layout.detail_x + PAD_X;
    const content_w = @max(1.0, layout.detail_w - PAD_X * 2);
    const indent: f32 = 12;
    const wrap_w = @max(1.0, content_w - indent);

    // Draw messages top-to-bottom, wrapping each message's content across as
    // many visual lines as it needs. The role label gets its own full-width
    // line so it is never truncated. `scroll_lines` visual lines are skipped
    // from the top; drawing stops once we run out of vertical space. The line
    // accounting here must match transcriptLineTotal.
    var vis_index: usize = 0;
    var top_px = start_top;
    var drew_any = false;
    for (messages) |msg| {
        if (vis_index >= scroll_lines) {
            if (top_px + line_h > window_height) return;
            const role_color = if (msg.role == .assistant) accent else muted;
            _ = draw.renderTextLimited(roleLabel(msg.role), text_x, yTextFromTop(draw, window_height, top_px), role_color, content_w);
            top_px += line_h;
            drew_any = true;
        }
        vis_index += 1;

        var it = LineWrap{ .text = msg.content, .max_w = wrap_w, .advance = draw.glyphAdvance };
        while (it.next()) |line| {
            if (vis_index >= scroll_lines) {
                if (top_px + line_h > window_height) return;
                _ = draw.renderTextLimited(line, text_x + indent, yTextFromTop(draw, window_height, top_px), fg, wrap_w);
                top_px += line_h;
                drew_any = true;
            }
            vis_index += 1;
        }
        if (drew_any) top_px += SMALL_GAP;
    }
}

fn displayTitle(row: anytype) []const u8 {
    if (row.title.len > 0) return row.title;
    if (row.summary.len > 0) return row.summary;
    return row.session_id;
}

fn statusText(session: anytype) []const u8 {
    if (session.status.len > 0) {
        if (std.mem.eql(u8, session.status, "Ready with warnings")) return "Scan completed with warnings";
        return session.status;
    }
    return switch (session.state) {
        .idle => "Idle",
        .scanning => "Scanning AI history...",
        .ready => "Ready",
        .failed => "Connection failed - press r to retry",
    };
}

/// Accent rule under a panel's header marking it as the keyboard-focused panel.
fn drawFocusUnderline(draw: DrawContext, x: f32, w: f32, window_height: f32, top: f32, header_h: f32, accent: [3]f32, focused: bool) void {
    if (!focused) return;
    draw.fillQuad(x, yFromTop(window_height, top + header_h - 2, 2), w, 2, accent);
}

/// Single source line for the left column: the source name, with the target
/// type appended only when it adds information (e.g. "panda · SSH"). When the
/// name already equals the target type (the common "WSL"/"WSL" case) it is shown
/// once instead of duplicated.
fn sourceDisplayText(source: anytype, buf: []u8) []const u8 {
    const name = source.name;
    const tlabel = targetLabel(source.target);
    if (name.len == 0) return tlabel;
    if (std.ascii.eqlIgnoreCase(name, tlabel)) return name;
    return std.fmt.bufPrint(buf, "{s} · {s}", .{ name, tlabel }) catch name;
}

fn targetLabel(target: anytype) []const u8 {
    return switch (target) {
        .local => "Local",
        .wsl => "WSL",
        .ssh => "SSH",
    };
}

fn categoryLabelText(category: types.CategoryFilter) []const u8 {
    return types.categoryLabel(category);
}

fn roleLabel(role: anytype) []const u8 {
    return switch (role) {
        .user => "user:",
        .assistant => "assistant:",
        .system => "system:",
        .tool => "tool:",
    };
}

fn yFromTop(window_height: f32, top_px: f32, h: f32) f32 {
    return window_height - top_px - h;
}

fn yTextFromTop(draw: DrawContext, window_height: f32, top_px: f32) f32 {
    return window_height - top_px - draw.cell_h;
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

fn metadataMatches(meta: anytype, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsIgnoreCase(meta.title, query) or
        containsIgnoreCase(meta.summary, query) or
        containsIgnoreCase(meta.project_dir, query) or
        containsIgnoreCase(meta.session_id, query) or
        containsIgnoreCase(meta.source_path, query);
}

fn containsIgnoreCase(haystack: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > haystack.len) return false;
    var i: usize = 0;
    while (i + query.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (query, 0..) |qch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(qch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn buttonHeight(cell_h: f32) f32 {
    return cell_h + BUTTON_EXTRA_H;
}

fn refreshButtonTop(top: f32, cell_h: f32) f32 {
    return leftColumnLayout(top, cell_h).retry_text_top - BUTTON_PAD_Y;
}

fn resumeButtonTop(top: f32, cell_h: f32) f32 {
    return top + headerHeight(cell_h) + 18 +
        (cell_h + 8) +
        (cell_h + 8) +
        (cell_h + 8) +
        (cell_h + 16) - BUTTON_PAD_Y;
}

/// How many DATE rows (including the pinned "All dates" row) fit between
/// `date_rows_top` and the bottom of the left column, reserving the footer.
pub fn dateVisibleCapacity(window_height: f32, date_rows_top: f32, cell_h: f32) usize {
    const footer_reserve = cell_h + 20; // bottom "Enter resumes  Space previews"
    const bottom_limit = window_height - footer_reserve;
    if (bottom_limit <= date_rows_top) return 0;
    const row_h = cell_h + 10; // == leftColumnLayout(...).date_row_h
    return @intFromFloat(@max(0.0, @floor((bottom_limit - date_rows_top) / row_h)));
}

/// Clamp a stored date scroll offset so the windowed day list never scrolls
/// past its end. `day_slots` is the visible capacity minus the pinned All row.
fn clampDateOffset(offset: usize, bucket_count: usize, day_slots: usize) usize {
    if (bucket_count <= day_slots) return 0;
    return @min(offset, bucket_count - day_slots);
}

fn rectContains(x: f32, y: f32, left: f32, top: f32, width: f32, height: f32) bool {
    return width > 0 and height > 0 and
        x >= left and x < left + width and
        y >= top and y < top + height;
}

test "ai_history_renderer: list row lines never overlap as ui font grows" {
    const cell_heights = [_]f32{ 12, 16, 18, 22, 28, 32, 40 };
    for (cell_heights) |cell_h| {
        const lines = rowTextLayout(cell_h);
        // The path line must begin at or below the bottom of the title line.
        try std.testing.expect(lines.detail_top >= lines.title_top + cell_h);
        // Both lines must stay inside the row box.
        try std.testing.expect(lines.title_top >= 0);
        try std.testing.expect(lines.detail_top + cell_h <= rowHeight(cell_h) + 0.001);
    }
}

test "ai_history_renderer: hit test maps list rows" {
    const layout = computeLayout(0, 1000);
    const hit = hitTest(layout, layout.list_x + 10, 120, 100, 24, 5);
    try std.testing.expectEqual(@as(usize, 0), hit.row);
}

test "ai_history_renderer: layout keeps a readable detail column" {
    const layout = computeLayout(0, 1200);
    try std.testing.expect(layout.left_w >= 180);
    try std.testing.expect(layout.list_w >= 260);
    try std.testing.expect(layout.detail_w >= 120);
    try std.testing.expectEqual(layout.left_x + layout.left_w, layout.list_x);
    try std.testing.expectEqual(layout.list_x + layout.list_w, layout.detail_x);
}

test "ai_history_renderer: narrow layout stays inside available width" {
    const layout = computeLayout(10, 300);
    try std.testing.expect(layout.left_w >= 0);
    try std.testing.expect(layout.list_w >= 0);
    try std.testing.expect(layout.detail_w >= 0);
    try std.testing.expectEqual(layout.left_x + layout.left_w, layout.list_x);
    try std.testing.expectEqual(layout.list_x + layout.list_w, layout.detail_x);
    try std.testing.expect(layout.detail_x + layout.detail_w <= 310.001);
}

test "ai_history_renderer: zero width layout has no columns" {
    const layout = computeLayout(20, 0);
    try std.testing.expectEqual(@as(f32, 0), layout.left_w);
    try std.testing.expectEqual(@as(f32, 0), layout.list_w);
    try std.testing.expectEqual(@as(f32, 0), layout.detail_w);
    try std.testing.expectEqual(@as(f32, 20), layout.left_x);
    try std.testing.expectEqual(@as(f32, 20), layout.list_x);
    try std.testing.expectEqual(@as(f32, 20), layout.detail_x);
}

test "ai_history_renderer: interaction hit test maps buttons and row offset" {
    const FakeSession = struct {
        date_offset: usize = 0,
        fn visibleCount(_: @This()) usize {
            return 8;
        }

        fn listWindowStart(_: @This(), _: usize) usize {
            return 3;
        }

        fn buildDateBuckets(_: @This(), buf: []types.DateBucket) []types.DateBucket {
            return buf[0..0];
        }
    };

    const session = FakeSession{};
    const layout = computeLayout(0, 1000);
    const cell_h: f32 = 16;
    const top: f32 = 40;

    // Retry is right-aligned on the Status value line; click inside that label.
    try std.testing.expectEqual(
        Hit.refresh,
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + layout.left_w - PAD_X - RETRY_LABEL_W + 4, refreshButtonTop(top, cell_h) + 2),
    );
    try std.testing.expectEqual(
        Hit.@"resume",
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.detail_x + PAD_X + 4, resumeButtonTop(top, cell_h) + 2),
    );
    const row_hit = interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.list_x + 8, top + FILTER_H + ROW_H + 2);
    try std.testing.expectEqual(@as(usize, 4), row_hit.row);
}

// A fixed-advance metric so wrapping tests are deterministic without a font.
fn tenPxAdvance(_: u32) f32 {
    return 10;
}

fn collectWrapped(text: []const u8, max_w: f32, out: *std.ArrayList([]const u8)) !void {
    var it = LineWrap{ .text = text, .max_w = max_w, .advance = tenPxAdvance };
    while (it.next()) |line| try out.append(std.testing.allocator, line);
}

test "ai_history_renderer: LineWrap hard-wraps when text exceeds width" {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    // max_w 35 fits three 10px glyphs (30) but not four (40).
    try collectWrapped("abcdefg", 35, &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("abc", lines.items[0]);
    try std.testing.expectEqualStrings("def", lines.items[1]);
    try std.testing.expectEqualStrings("g", lines.items[2]);
}

test "ai_history_renderer: LineWrap breaks on explicit newlines" {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    try collectWrapped("ab\n\ncd", 1000, &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("ab", lines.items[0]);
    try std.testing.expectEqualStrings("", lines.items[1]);
    try std.testing.expectEqualStrings("cd", lines.items[2]);
}

test "ai_history_renderer: LineWrap prefers a space boundary when wrapping" {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    // "ab cd ef" at max_w 55: "ab cd " would need 60px, so break at the first space.
    try collectWrapped("ab cd ef", 55, &lines);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("ab", lines.items[0]);
    try std.testing.expectEqualStrings("cd ef", lines.items[1]);
}

test "ai_history_renderer: LineWrap always advances past an oversized glyph" {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    // max_w smaller than one glyph must still emit one glyph per line, not loop.
    try collectWrapped("abc", 5, &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
}

test "ai_history_renderer: LineWrap counts wrapped lines" {
    try std.testing.expectEqual(@as(usize, 3), wrappedLineCount("abcdefg", 35, tenPxAdvance));
    try std.testing.expectEqual(@as(usize, 1), wrappedLineCount("ab", 1000, tenPxAdvance));
    try std.testing.expectEqual(@as(usize, 0), wrappedLineCount("", 1000, tenPxAdvance));
}

test "ai_history_renderer: transcriptLineTotal counts a role line plus wrapped content per message" {
    const Msg = struct { content: []const u8 };
    const msgs = [_]Msg{
        .{ .content = "abcdefg" }, // 1 role + 3 wrapped = 4
        .{ .content = "ab" }, // 1 role + 1 wrapped = 2
        .{ .content = "" }, // 1 role + 0 content = 1
    };
    try std.testing.expectEqual(@as(usize, 7), transcriptLineTotal(&msgs, 35, tenPxAdvance));
}

test "ai_history_renderer: clampScroll keeps scroll within the scrollable range" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(5, 3, 10)); // everything fits
    try std.testing.expectEqual(@as(usize, 2), clampScroll(5, 12, 10)); // clamped to max
    try std.testing.expectEqual(@as(usize, 1), clampScroll(1, 12, 10)); // within range
    try std.testing.expectEqual(@as(usize, 0), clampScroll(0, 12, 10));
}

test "ai_history_renderer: left column layout is ordered top to bottom" {
    const lc = leftColumnLayout(40, 16);
    try std.testing.expect(lc.source_name_top < lc.status_label_top);
    try std.testing.expect(lc.status_label_top < lc.status_value_top);
    // Retry shares the status value line, then CATEGORY/DATE follow.
    try std.testing.expectEqual(lc.status_value_top, lc.retry_text_top);
    try std.testing.expect(lc.status_value_top < lc.category_heading_top);
    try std.testing.expect(lc.category_heading_top < lc.date_heading_top);
    try std.testing.expectEqual(lc.retry_text_top - BUTTON_PAD_Y, refreshButtonTop(40, 16));
}

test "ai_history_renderer: interaction hit test maps category rows" {
    const FakeSession = struct {
        date_offset: usize = 0,
        fn visibleCount(_: @This()) usize {
            return 0;
        }
        fn listWindowStart(_: @This(), _: usize) usize {
            return 0;
        }
        fn buildDateBuckets(_: @This(), buf: []types.DateBucket) []types.DateBucket {
            return buf[0..0];
        }
    };

    const session = FakeSession{};
    const layout = computeLayout(0, 1000);
    const cell_h: f32 = 16;
    const top: f32 = 40;
    const lc = leftColumnLayout(top, cell_h);

    const all_y = lc.category_rows_top + lc.category_row_h * 0.5;
    try std.testing.expectEqual(
        Hit{ .category = .all },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, all_y),
    );

    const codex_y = lc.category_rows_top + lc.category_row_h * 1.5;
    try std.testing.expectEqual(
        Hit{ .category = .codex },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, codex_y),
    );

    const claude_y = lc.category_rows_top + lc.category_row_h * 2.5;
    try std.testing.expectEqual(
        Hit{ .category = .claude },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, claude_y),
    );

    const reasonix_y = lc.category_rows_top + lc.category_row_h * 3.5;
    try std.testing.expectEqual(
        Hit{ .category = .reasonix },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, reasonix_y),
    );

    const subagent_y = lc.category_rows_top + lc.category_row_h * 4.5;
    try std.testing.expectEqual(
        Hit{ .category = .subagent },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, subagent_y),
    );
}

test "ai_history_renderer: interaction hit test maps date rows" {
    const FakeSession = struct {
        date_offset: usize = 0,
        fn visibleCount(_: @This()) usize {
            return 0;
        }
        fn listWindowStart(_: @This(), _: usize) usize {
            return 0;
        }
        fn buildDateBuckets(_: @This(), buf: []types.DateBucket) []types.DateBucket {
            buf[0] = .{ .key = 20260602, .count = 3 };
            buf[1] = .{ .key = 20260601, .count = 5 };
            return buf[0..2];
        }
    };

    const session = FakeSession{};
    const layout = computeLayout(0, 1000);
    const cell_h: f32 = 16;
    const top: f32 = 40;
    const lc = leftColumnLayout(top, cell_h);

    // Row 0 is the pinned "All dates" row -> null.
    const all_y = lc.date_rows_top + lc.date_row_h * 0.5;
    try std.testing.expectEqual(
        Hit{ .date = null },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, all_y),
    );

    // Row 1 -> first bucket (20260602).
    const d1_y = lc.date_rows_top + lc.date_row_h * 1.5;
    try std.testing.expectEqual(
        Hit{ .date = @as(?types.DateKey, 20260602) },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, d1_y),
    );

    // Row 2 -> second bucket (20260601).
    const d2_y = lc.date_rows_top + lc.date_row_h * 2.5;
    try std.testing.expectEqual(
        Hit{ .date = @as(?types.DateKey, 20260601) },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, d2_y),
    );
}
