//! Skill Center v2 renderer: a single-column library list, plus overlays (a
//! selectable list for the target picker / import list, and a confirm bar).
//! Model-agnostic: the caller passes fn-pointer accessors so the renderer never
//! allocates per frame and never imports the model. Strings come pre-localized
//! from the caller (which reads i18n).
const std = @import("std");
const panel_draw = @import("panel_draw.zig");

pub const DrawContext = panel_draw.DrawContext;

const HEADER_H: f32 = 54;
const ROW_H: f32 = 30;
const PAD_X: f32 = 16;
// Action legends are instructional content, not a disposable one-line status.
// Three rows keep the full key map readable at large fonts and narrow panels.
const LEGEND_H: f32 = 72;

pub const ListItem = struct {
    label: []const u8,
    marker: []const u8, // "" when none (e.g. the picker)
    marker_color: [3]f32 = .{ 0, 0, 0 }, // caller-supplied; ignored when marker is ""
    kind: []const u8 = "",
    enabled: []const u8 = "",
};

/// A selectable list overlay (target picker or import list). Accessor-based so
/// it can be backed by the model under the lock with no copying.
pub const ListView = struct {
    title: []const u8,
    len: usize,
    ctx: *anyopaque,
    itemAt: *const fn (*anyopaque, usize) ListItem,
    sel: usize,
};

/// A single-line text-input overlay (the GitHub URL field).
pub const InputView = struct {
    prompt: []const u8,
    text: []const u8,
};

/// A scrollable, read-only text overlay — a skill's SKILL.md preview. The Skill
/// Center is a non-terminal tab and can't host a split preview pane, so it shows
/// the content here. `scroll_out`, when set, receives the clamped scroll offset
/// (the caller holds the model under the render lock), so over-scroll never lags.
pub const TextView = struct {
    title: []const u8,
    content: []const u8,
    hint: []const u8,
    scroll: usize,
    scroll_out: ?*usize = null,
};

pub const Overlay = union(enum) {
    none,
    list: ListView,
    confirm: []const u8, // confirm bar text
    input: InputView,
    text: TextView,
};

pub const View = struct {
    /// Library skill list, via an accessor (no per-frame allocation).
    skills_len: usize,
    ctx: *anyopaque,
    itemAt: *const fn (*anyopaque, usize) ListItem,
    sel_row: usize,
    title: []const u8, // localized "Skill Center"
    legend: []const u8, // localized action legend
    status: []const u8, // "Scanning…" etc, or ""
    overlay: Overlay,
};

fn headerHeight(cell_h: f32) f32 {
    return @max(HEADER_H, cell_h + 18);
}
fn rowHeight(cell_h: f32) f32 {
    return @max(ROW_H, cell_h + 12);
}
fn legendHeight(cell_h: f32) f32 {
    return @max(LEGEND_H, cell_h * 3 + 16);
}

const DrawRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const HeaderChrome = struct {
    band: DrawRect,
    rule: DrawRect,
    title_y: f32,
};

const FooterChrome = struct {
    rule: DrawRect,
    text_y: f32,
};

const RowSlot = struct {
    rect: DrawRect,
    text_y: f32,
};

const ListWindow = struct {
    top_px: f32,
    visible_rows: usize,
    first_visible: usize,
};

const ListScrollbar = struct {
    track: DrawRect,
    thumb: DrawRect,
};

const PanelLayout = struct {
    content_x: f32,
    content_w: f32,
    top: f32,
    content_h: f32,
    header_h: f32,
    row_h: f32,
    legend_h: f32,
    body_top: f32,

    fn background(self: PanelLayout) DrawRect {
        return .{ .x = self.content_x, .y = 0, .w = self.content_w, .h = self.content_h };
    }

    fn header(self: PanelLayout, window_height: f32, cell_h: f32) HeaderChrome {
        return .{
            .band = .{
                .x = self.content_x,
                .y = yFromTop(window_height, self.top, self.header_h),
                .w = self.content_w,
                .h = self.header_h,
            },
            .rule = .{
                .x = self.content_x,
                .y = yFromTop(window_height, self.top + self.header_h, 1),
                .w = self.content_w,
                .h = 1,
            },
            .title_y = yTextFromTop(window_height, self.top + 11, cell_h),
        };
    }

    fn bodyVisibleRows(self: PanelLayout) usize {
        const usable = self.content_h - self.header_h - self.legend_h;
        if (usable <= 0) return 0;
        return @intFromFloat(@max(0.0, @floor(usable / self.row_h)));
    }

    fn mainListWindow(self: PanelLayout, total: usize, selected: usize) ListWindow {
        const cap = self.bodyVisibleRows();
        return .{
            .top_px = self.body_top,
            .visible_rows = cap,
            .first_visible = firstVisibleForSelection(selected, cap, total),
        };
    }

    fn overlayListWindow(self: PanelLayout, window_height: f32, total: usize, selected: usize) ListWindow {
        const list_top = self.body_top + self.row_h;
        const usable = window_height - list_top - self.legend_h;
        const cap: usize = if (usable <= 0) 0 else @intFromFloat(@max(0.0, @floor(usable / self.row_h)));
        return .{
            .top_px = list_top,
            .visible_rows = cap,
            .first_visible = firstVisibleForSelection(selected, cap, total),
        };
    }

    fn rowSlot(self: PanelLayout, window_height: f32, list_top_px: f32, display_row: usize, cell_h: f32) RowSlot {
        const row_top_px = list_top_px + @as(f32, @floatFromInt(display_row)) * self.row_h;
        return .{
            .rect = .{
                .x = self.content_x,
                .y = yFromTop(window_height, row_top_px, self.row_h),
                .w = self.content_w,
                .h = self.row_h,
            },
            .text_y = yTextFromTop(window_height, row_top_px + (self.row_h - cell_h) / 2, cell_h),
        };
    }

    fn footer(self: PanelLayout, cell_h: f32) FooterChrome {
        return .{
            .rule = .{ .x = self.content_x, .y = self.legend_h, .w = self.content_w, .h = 1 },
            .text_y = (self.legend_h - cell_h) / 2,
        };
    }

    fn bottomBar(self: PanelLayout, rows: f32) DrawRect {
        return .{ .x = self.content_x, .y = self.legend_h, .w = self.content_w, .h = self.row_h * rows };
    }

    fn topRule(self: PanelLayout, window_height: f32, top_px: f32) DrawRect {
        return .{ .x = self.content_x, .y = yFromTop(window_height, top_px, 1), .w = self.content_w, .h = 1 };
    }
};

fn panelLayout(window_height: f32, titlebar_offset: f32, cell_h: f32, x: f32, width: f32) ?PanelLayout {
    const content_x = @round(x);
    const content_w = @round(@max(1.0, width));
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    if (content_w <= 1 or content_h <= 1) return null;

    const header_h = headerHeight(cell_h);
    const row_h = rowHeight(cell_h);
    return .{
        .content_x = content_x,
        .content_w = content_w,
        .top = top,
        .content_h = content_h,
        .header_h = header_h,
        .row_h = row_h,
        .legend_h = legendHeight(cell_h),
        .body_top = top + header_h,
    };
}

fn listScrollbar(layout: PanelLayout, window_height: f32, list: ListWindow, total: usize) ?ListScrollbar {
    if (total <= list.visible_rows or list.visible_rows == 0) return null;

    const total_f: f32 = @floatFromInt(total);
    const vis_f: f32 = @floatFromInt(list.visible_rows);
    const track_h = layout.row_h * vis_f;
    const sb_w: f32 = 3;
    const sb_x = layout.content_x + layout.content_w - sb_w - 4;
    const thumb_h = @max(24.0, @round(track_h * vis_f / total_f));
    const max_scroll_f: f32 = @floatFromInt(total - list.visible_rows);
    const scroll_f: f32 = @floatFromInt(list.first_visible);
    const thumb_offset = if (max_scroll_f > 0) @round((track_h - thumb_h) * (scroll_f / max_scroll_f)) else 0;
    return .{
        .track = .{
            .x = sb_x,
            .y = yFromTop(window_height, list.top_px, track_h),
            .w = sb_w,
            .h = track_h,
        },
        .thumb = .{
            .x = sb_x,
            .y = yFromTop(window_height, list.top_px + thumb_offset, thumb_h),
            .w = sb_w,
            .h = thumb_h,
        },
    };
}

/// Rows that fit between the header and the legend.
pub fn bodyVisibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const layout = panelLayout(window_height, titlebar_offset, cell_h, 0, 2) orelse return 0;
    return layout.bodyVisibleRows();
}

/// Scroll offset that keeps the selected row visible, for lists that have only a
/// selection (no stored scroll). Mirrors the overlay scroll-follow helpers.
fn firstVisibleForSelection(selected: usize, visible: usize, total: usize) usize {
    if (visible == 0 or total <= visible) return 0;
    const sel = @min(selected, total - 1);
    if (sel < visible) return 0;
    return @min(sel - visible + 1, total - visible);
}

fn clampScroll(requested: usize, total: usize, visible: usize) usize {
    if (total <= visible) return 0;
    return @min(requested, total - visible);
}

fn yFromTop(window_height: f32, top_px: f32, h: f32) f32 {
    return window_height - top_px - h;
}
fn yTextFromTop(window_height: f32, top_px: f32, cell_h: f32) f32 {
    return window_height - top_px - cell_h;
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const c = @max(0.0, @min(1.0, t));
    return .{ a[0] + (b[0] - a[0]) * c, a[1] + (b[1] - a[1]) * c, a[2] + (b[2] - a[2]) * c };
}

/// Right-aligned geometry for the kind/enabled metadata columns. Scaled to the
/// font's glyph advance so the longest labels ("skill" / "tool" kind, "off" /
/// "on" state) never clip at large font sizes — fixed-pixel budgets fit only a
/// couple of glyphs once cells grow.
const MetaLayout = struct {
    band_w: f32, // total width reserved at the row's right edge for both columns
    kind_w: f32, // max width for the kind label, from the band's left edge
    enabled_dx: f32, // x offset of the enabled label from the band's left edge
    enabled_w: f32, // max width for the enabled label
};

fn metaLayout(advance_in: f32) MetaLayout {
    const a = @max(1.0, advance_in);
    const kind_w = a * 5.5; // "skill" (5) + margin
    const enabled_w = a * 3.5; // "off" (3) + margin
    const gap = a; // one-glyph gutter between the columns
    return .{
        .band_w = @max(160.0, kind_w + gap + enabled_w),
        .kind_w = kind_w,
        .enabled_dx = kind_w + gap,
        .enabled_w = enabled_w,
    };
}

fn renderListMetadata(
    draw: DrawContext,
    item: ListItem,
    content_x: f32,
    content_w: f32,
    text_y: f32,
    muted: [3]f32,
) void {
    const ml = metaLayout(draw.glyphAdvance('M'));
    const band_left = content_x + content_w - PAD_X - ml.band_w;
    if (item.kind.len > 0) {
        _ = draw.renderTextLimited(item.kind, band_left, text_y, muted, ml.kind_w);
    }
    if (item.enabled.len > 0) {
        _ = draw.renderTextLimited(item.enabled, band_left + ml.enabled_dx, text_y, item.marker_color, ml.enabled_w);
    }
}

pub fn render(
    draw: DrawContext,
    view: View,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    x: f32,
    width: f32,
) void {
    _ = window_width;
    const layout = panelLayout(window_height, titlebar_offset, draw.cell_h, x, width) orelse return;

    const bg = draw.bg;
    const fg = draw.fg;
    const accent = draw.accent;
    const panel_strong = mixColor(bg, fg, 0.075);
    const line = mixColor(bg, fg, 0.18);
    const muted = mixColor(bg, fg, 0.58);
    const selected_bg = mixColor(bg, accent, 0.18);

    const background = layout.background();
    draw.fillQuad(background.x, background.y, background.w, background.h, bg);

    // --- Header: title · count + status. ---
    const header = layout.header(window_height, draw.cell_h);
    draw.fillQuadAlpha(header.band.x, header.band.y, header.band.w, header.band.h, panel_strong, 0.9);
    draw.fillQuad(header.rule.x, header.rule.y, header.rule.w, header.rule.h, line);

    const title_y = header.title_y;
    const title_end = draw.renderTextLimited(view.title, layout.content_x + PAD_X, title_y, fg, layout.content_w - PAD_X * 2);
    var sub_buf: [64]u8 = undefined;
    const sub = std.fmt.bufPrint(&sub_buf, " · {d}", .{view.skills_len}) catch "";
    const sub_end = draw.renderTextLimited(sub, title_end, title_y, muted, @max(0, layout.content_x + layout.content_w - PAD_X - title_end));
    if (view.status.len > 0) {
        const sx = sub_end + 16;
        _ = draw.renderTextLimited(view.status, sx, title_y, accent, @max(0, layout.content_x + layout.content_w - PAD_X - sx));
    }

    switch (view.overlay) {
        .list => |lv| {
            renderList(draw, lv, layout, window_height, fg, muted, accent, line, selected_bg);
        },
        .text => |tv| {
            renderTextPreview(draw, tv, layout, window_height, fg, muted, accent, line);
            return; // own footer hint; no action legend
        },
        else => {
            renderSkillList(draw, view, layout, window_height, fg, muted, accent, line, selected_bg);
            if (view.overlay == .confirm) {
                const bar = layout.bottomBar(1);
                draw.fillQuadAlpha(bar.x, bar.y, bar.w, bar.h, mixColor(bg, accent, 0.22), 0.97);
                const t_y = bar.y + (bar.h - draw.cell_h) / 2;
                _ = draw.renderTextLimited(view.overlay.confirm, layout.content_x + PAD_X, t_y, fg, layout.content_w - PAD_X * 2);
                return; // confirm replaces the legend line
            }
            if (view.overlay == .input) {
                const iv = view.overlay.input;
                const bar = layout.bottomBar(2);
                draw.fillQuadAlpha(bar.x, bar.y, bar.w, bar.h, mixColor(bg, accent, 0.22), 0.97);
                const prompt_y = bar.y + bar.h - draw.cell_h - 6;
                _ = draw.renderTextLimited(iv.prompt, layout.content_x + PAD_X, prompt_y, muted, layout.content_w - PAD_X * 2);
                // editable line with a trailing caret
                var line_buf: [600]u8 = undefined;
                const shown = std.fmt.bufPrint(&line_buf, "{s}_", .{iv.text}) catch iv.text;
                const text_y = bar.y + (layout.row_h - draw.cell_h) / 2;
                _ = draw.renderTextLimited(shown, layout.content_x + PAD_X, text_y, fg, layout.content_w - PAD_X * 2);
                return; // input replaces the legend line
            }
        },
    }

    renderLegend(draw, view.legend, layout, muted, line);
}

fn renderSkillList(
    draw: DrawContext,
    view: View,
    layout: PanelLayout,
    window_height: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    line: [3]f32,
    selected_bg: [3]f32,
) void {
    if (view.skills_len == 0) {
        const empty_y = yTextFromTop(window_height, layout.body_top + 24, draw.cell_h);
        _ = draw.renderTextLimited(view.status, layout.content_x + PAD_X, empty_y, muted, layout.content_w - PAD_X * 2);
        return;
    }
    const list = layout.mainListWindow(view.skills_len, view.sel_row);
    var rendered: usize = 0;
    var ri: usize = list.first_visible;
    while (ri < view.skills_len and rendered < list.visible_rows) : (ri += 1) {
        const slot = layout.rowSlot(window_height, list.top_px, rendered, draw.cell_h);
        if (ri == view.sel_row) {
            draw.fillQuadAlpha(slot.rect.x, slot.rect.y, slot.rect.w, slot.rect.h, selected_bg, 0.55);
            draw.fillQuad(slot.rect.x, slot.rect.y, 3, slot.rect.h, accent);
        }
        draw.fillQuadAlpha(slot.rect.x, slot.rect.y, slot.rect.w, 1, line, 0.4);
        const item = view.itemAt(view.ctx, ri);
        const meta_w: f32 = if (item.kind.len > 0 or item.enabled.len > 0) metaLayout(draw.glyphAdvance('M')).band_w else 0;
        _ = draw.renderTextLimited(item.label, layout.content_x + PAD_X, slot.text_y, fg, @max(0, layout.content_w - PAD_X * 2 - meta_w));
        renderListMetadata(draw, item, layout.content_x, layout.content_w, slot.text_y, muted);
        rendered += 1;
    }

    if (listScrollbar(layout, window_height, list, view.skills_len)) |sb| {
        draw.fillQuadAlpha(sb.track.x, sb.track.y, sb.track.w, sb.track.h, mixColor(muted, fg, 0.2), 0.30);
        draw.fillQuadAlpha(sb.thumb.x, sb.thumb.y, sb.thumb.w, sb.thumb.h, accent, 0.55);
    }
}

fn renderList(
    draw: DrawContext,
    lv: ListView,
    layout: PanelLayout,
    window_height: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    line: [3]f32,
    selected_bg: [3]f32,
) void {
    // Title line.
    const title_y = yTextFromTop(window_height, layout.body_top + 8, draw.cell_h);
    _ = draw.renderTextLimited(lv.title, layout.content_x + PAD_X, title_y, muted, layout.content_w - PAD_X * 2);
    const list = layout.overlayListWindow(window_height, lv.len, lv.sel);

    const marker_w: f32 = 110;
    const meta_w: f32 = metaLayout(draw.glyphAdvance('M')).band_w;
    var rendered: usize = 0;
    var i: usize = list.first_visible;
    while (i < lv.len and rendered < list.visible_rows) : (i += 1) {
        const slot = layout.rowSlot(window_height, list.top_px, rendered, draw.cell_h);
        if (i == lv.sel) {
            draw.fillQuadAlpha(slot.rect.x, slot.rect.y, slot.rect.w, slot.rect.h, selected_bg, 0.55);
            draw.fillQuad(slot.rect.x, slot.rect.y, 3, slot.rect.h, accent);
        }
        draw.fillQuadAlpha(slot.rect.x, slot.rect.y, slot.rect.w, 1, line, 0.4);
        const item = lv.itemAt(lv.ctx, i);
        const reserved_w = (if (item.kind.len > 0 or item.enabled.len > 0) meta_w else 0) + (if (item.marker.len > 0) marker_w else 0);
        _ = draw.renderTextLimited(item.label, layout.content_x + PAD_X, slot.text_y, fg, @max(0, layout.content_w - PAD_X * 2 - reserved_w));
        renderListMetadata(draw, item, layout.content_x - (if (item.marker.len > 0) marker_w else 0), layout.content_w, slot.text_y, muted);
        if (item.marker.len > 0) {
            const mx = layout.content_x + layout.content_w - PAD_X - marker_w;
            _ = draw.renderTextLimited(item.marker, mx, slot.text_y, item.marker_color, marker_w);
        }
        rendered += 1;
    }

    if (listScrollbar(layout, window_height, list, lv.len)) |sb| {
        draw.fillQuadAlpha(sb.track.x, sb.track.y, sb.track.w, sb.track.h, mixColor(muted, fg, 0.2), 0.30);
        draw.fillQuadAlpha(sb.thumb.x, sb.thumb.y, sb.thumb.w, sb.thumb.h, accent, 0.55);
    }
}

// --- Text preview overlay (scrollable SKILL.md) ---

/// Fixed-width columns that fit in `width` px at glyph `advance` (≥1).
fn wrapCols(width: f32, advance: f32) usize {
    if (advance <= 0 or width <= 0) return 80;
    const c: usize = @intFromFloat(@floor(width / advance));
    return @max(1, c);
}

/// Iterate `content` as wrapped display lines: a '\n' ends a line, long logical
/// lines wrap every `cols` codepoints, and a trailing '\n' adds no empty line.
/// A trailing '\r' (CRLF) is trimmed per line.
const WrapIter = struct {
    content: []const u8,
    cols: usize,
    pos: usize = 0,

    fn next(self: *WrapIter) ?[]const u8 {
        if (self.pos >= self.content.len) return null;
        const start = self.pos;
        var i = start;
        var count: usize = 0;
        while (i < self.content.len) {
            if (self.content[i] == '\n') {
                self.pos = i + 1;
                return trimCr(self.content[start..i]);
            }
            const cp_len = std.unicode.utf8ByteSequenceLength(self.content[i]) catch 1;
            i += @min(cp_len, self.content.len - i);
            count += 1;
            if (count >= self.cols) {
                self.pos = i;
                return trimCr(self.content[start..i]);
            }
        }
        self.pos = i;
        return trimCr(self.content[start..i]);
    }
};

fn trimCr(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

/// Count the wrapped display lines `content` occupies at `cols` columns.
pub fn wrappedLineCount(content: []const u8, cols: usize) usize {
    var it = WrapIter{ .content = content, .cols = cols };
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn renderTextPreview(
    draw: DrawContext,
    tv: TextView,
    layout: PanelLayout,
    window_height: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    line: [3]f32,
) void {
    // Title row.
    const title_y = yTextFromTop(window_height, layout.body_top + 8, draw.cell_h);
    _ = draw.renderTextLimited(tv.title, layout.content_x + PAD_X, title_y, accent, layout.content_w - PAD_X * 2);
    const title_rule = layout.topRule(window_height, layout.body_top + layout.row_h);
    draw.fillQuad(title_rule.x, title_rule.y, title_rule.w, title_rule.h, line);

    const text_top = layout.body_top + layout.row_h;
    const line_pitch = draw.cell_h + 6;
    const avail_h = window_height - layout.top - text_top - layout.legend_h - 6;

    if (avail_h > line_pitch) {
        const visible: usize = @intFromFloat(@floor(avail_h / line_pitch));
        const advance = draw.glyphAdvance('M');
        const cols = wrapCols(layout.content_w - PAD_X * 2, advance);
        const total = wrappedLineCount(tv.content, cols);
        const scroll = clampScroll(tv.scroll, total, visible);
        if (tv.scroll_out) |p| p.* = scroll;

        var it = WrapIter{ .content = tv.content, .cols = cols };
        var skipped: usize = 0;
        while (skipped < scroll) : (skipped += 1) _ = it.next();
        var rendered: usize = 0;
        while (rendered < visible) : (rendered += 1) {
            const dl = it.next() orelse break;
            const top_px = text_top + @as(f32, @floatFromInt(rendered)) * line_pitch + 4;
            const ly = yTextFromTop(window_height, top_px, draw.cell_h);
            if (dl.len > 0) _ = draw.renderTextLimited(dl, layout.content_x + PAD_X, ly, fg, layout.content_w - PAD_X * 2);
        }
    }

    // Footer hint replaces the action legend.
    const footer = layout.footer(draw.cell_h);
    draw.fillQuad(footer.rule.x, footer.rule.y, footer.rule.w, footer.rule.h, line);
    _ = draw.renderTextLimited(tv.hint, layout.content_x + PAD_X, footer.text_y, muted, layout.content_w - PAD_X * 2);
}

fn renderLegend(draw: DrawContext, legend: []const u8, layout: PanelLayout, muted: [3]f32, line: [3]f32) void {
    const footer = layout.footer(draw.cell_h);
    draw.fillQuad(footer.rule.x, footer.rule.y, footer.rule.w, footer.rule.h, line);
    const text_w = layout.content_w - PAD_X * 2;
    const cols = wrapCols(text_w, draw.glyphAdvance('M'));
    var it = WrapIter{ .content = legend, .cols = cols };
    var line_index: usize = 0;
    while (it.next()) |display_line| : (line_index += 1) {
        if (line_index >= 3) break;
        const y = (layout.legend_h - draw.cell_h - 6) - @as(f32, @floatFromInt(line_index)) * (draw.cell_h + 2);
        _ = draw.renderTextLimited(display_line, layout.content_x + PAD_X, y, muted, text_w);
    }
}

// --- Tests ---

test "skill_center_renderer: firstVisibleForSelection keeps selection in view" {
    try std.testing.expectEqual(@as(usize, 0), firstVisibleForSelection(5, 10, 8));
    try std.testing.expectEqual(@as(usize, 0), firstVisibleForSelection(2, 4, 16));
    try std.testing.expectEqual(@as(usize, 12), firstVisibleForSelection(15, 4, 16));
    try std.testing.expectEqual(@as(usize, 5), firstVisibleForSelection(8, 4, 16));
}

test "skill_center_renderer: main list window follows the selection" {
    const layout = panelLayout(420, 40, 16, 0, 300).?;
    // Selection near the top: window starts at row 0.
    try std.testing.expectEqual(@as(usize, 0), layout.mainListWindow(40, 2).first_visible);
    // Selection past the fold: window scrolls so the selected row stays visible
    // (regression: previously the window was pinned at 0 and rows below were unreachable).
    const deep = layout.mainListWindow(40, 39);
    try std.testing.expect(deep.visible_rows > 0);
    try std.testing.expect(deep.first_visible > 0);
    try std.testing.expect(39 < deep.first_visible + deep.visible_rows);
}

test "skill_center_renderer: clampScroll keeps scroll within range" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(5, 3, 10));
    try std.testing.expectEqual(@as(usize, 2), clampScroll(5, 12, 10));
    try std.testing.expectEqual(@as(usize, 1), clampScroll(1, 12, 10));
}

test "skill_center_renderer: bodyVisibleCapacity grows with height" {
    const cell_h: f32 = 16;
    try std.testing.expect(bodyVisibleCapacity(800, 40, cell_h) >= bodyVisibleCapacity(200, 40, cell_h));
    try std.testing.expectEqual(@as(usize, 0), bodyVisibleCapacity(40, 40, cell_h));
}

test "skill_center_renderer: panel layout exposes backend-neutral chrome bands" {
    const layout = panelLayout(720, 40, 16, 24.2, 320.8).?;
    try std.testing.expectApproxEqAbs(@as(f32, 24), layout.content_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 321), layout.content_w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 680), layout.content_h, 0.001);

    const bg = layout.background();
    try std.testing.expectApproxEqAbs(@as(f32, 0), bg.y, 0.001);
    try std.testing.expectApproxEqAbs(layout.content_h, bg.h, 0.001);

    const header = layout.header(720, 16);
    try std.testing.expectApproxEqAbs(@as(f32, 626), header.band.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 625), header.rule.y, 0.001);
    try std.testing.expect(header.rule.y + header.rule.h <= header.band.y);

    const footer = layout.footer(16);
    try std.testing.expectApproxEqAbs(layout.legend_h, footer.rule.y, 0.001);
    try std.testing.expect(footer.text_y >= 0);
}

test "skill_center_renderer: row slot geometry is stable across visible rows" {
    const layout = panelLayout(800, 50, 20, 10, 300).?;
    const row0 = layout.rowSlot(800, layout.body_top, 0, 20);
    const row1 = layout.rowSlot(800, layout.body_top, 1, 20);

    try std.testing.expectApproxEqAbs(row0.rect.x, row1.rect.x, 0.001);
    try std.testing.expectApproxEqAbs(row0.rect.w, row1.rect.w, 0.001);
    try std.testing.expectApproxEqAbs(row0.rect.y - layout.row_h, row1.rect.y, 0.001);
    try std.testing.expectApproxEqAbs(row0.rect.y + (layout.row_h - 20) / 2, row0.text_y, 0.001);
}

test "skill_center_renderer: overlay scrollbar stays inside list track" {
    const layout = panelLayout(420, 40, 16, 0, 300).?;
    const list = layout.overlayListWindow(420, 20, 15);
    try std.testing.expect(list.visible_rows > 0);
    try std.testing.expect(list.first_visible <= 15);
    try std.testing.expect(15 < list.first_visible + list.visible_rows);

    const sb = listScrollbar(layout, 420, list, 20).?;
    try std.testing.expect(sb.thumb.y >= sb.track.y);
    try std.testing.expect(sb.thumb.y + sb.thumb.h <= sb.track.y + sb.track.h + 0.001);
    try std.testing.expectApproxEqAbs(sb.track.x, sb.thumb.x, 0.001);
    try std.testing.expectApproxEqAbs(sb.track.w, sb.thumb.w, 0.001);
}

test "skill_center_renderer: list item carries kind and enabled marker" {
    const item = ListItem{ .label = "agent_docx_review", .kind = "tool", .enabled = "on", .marker = "" };
    try std.testing.expectEqualStrings("tool", item.kind);
    try std.testing.expectEqualStrings("on", item.enabled);
}

test "skill_center_renderer: metaLayout scales kind/enabled columns so labels never clip" {
    // At a large font (~24px glyph advance), the longest kind label "skill" (5
    // glyphs) and state label "off" (3 glyphs) must still fit their columns —
    // the previous fixed 54px budget showed only "sk" / "of".
    const a: f32 = 24;
    const ml = metaLayout(a);
    try std.testing.expect(ml.kind_w >= a * 5);
    try std.testing.expect(ml.enabled_w >= a * 3);
    // Columns sit side by side inside the reserved band without overlapping.
    try std.testing.expect(ml.enabled_dx >= ml.kind_w);
    try std.testing.expect(ml.band_w >= ml.enabled_dx + ml.enabled_w);
    // The band scales up with the font from its original floor.
    try std.testing.expect(metaLayout(24).band_w > metaLayout(6).band_w);
    try std.testing.expect(metaLayout(6).band_w >= 160);
}

test "skill_center_renderer: input overlay variant is constructible" {
    const ov: Overlay = .{ .input = .{ .prompt = "Paste URL", .text = "https://github.com/o/r" } };
    try std.testing.expect(ov == .input);
    try std.testing.expectEqualStrings("https://github.com/o/r", ov.input.text);
}

test "skill_center_renderer: wrappedLineCount wraps on newlines and column width" {
    // Three logical lines, trailing newline adds no empty line.
    try std.testing.expectEqual(@as(usize, 3), wrappedLineCount("a\nbb\nccc\n", 80));
    // No trailing newline → last line still counts.
    try std.testing.expectEqual(@as(usize, 2), wrappedLineCount("a\nb", 80));
    // Soft-wrap a long logical line every `cols` columns: "abcde" at 2 → ab|cd|e.
    try std.testing.expectEqual(@as(usize, 3), wrappedLineCount("abcde", 2));
    // Empty content → no lines.
    try std.testing.expectEqual(@as(usize, 0), wrappedLineCount("", 80));
}

test "skill_center_renderer: WrapIter yields trimmed CRLF lines in order" {
    var it = WrapIter{ .content = "x1\r\nyy\r\nz", .cols = 80 };
    try std.testing.expectEqualStrings("x1", it.next().?);
    try std.testing.expectEqualStrings("yy", it.next().?);
    try std.testing.expectEqualStrings("z", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "skill_center_renderer: text overlay variant carries scroll write-back" {
    var scroll: usize = 7;
    const ov: Overlay = .{ .text = .{
        .title = "t",
        .content = "body",
        .hint = "Esc close",
        .scroll = scroll,
        .scroll_out = &scroll,
    } };
    try std.testing.expect(ov == .text);
    try std.testing.expectEqual(@as(usize, 7), ov.text.scroll);
}
