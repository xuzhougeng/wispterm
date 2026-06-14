//! Skill Center v2 renderer: a single-column library list, plus overlays (a
//! selectable list for the target picker / import list, and a confirm bar).
//! Model-agnostic: the caller passes fn-pointer accessors so the renderer never
//! allocates per frame and never imports the model. Strings come pre-localized
//! from the caller (which reads i18n).
const std = @import("std");
const ai_history_renderer = @import("ai_history_renderer.zig");

pub const DrawContext = ai_history_renderer.DrawContext;

const HEADER_H: f32 = 54;
const ROW_H: f32 = 30;
const PAD_X: f32 = 16;
const LEGEND_H: f32 = 36;

pub const ListItem = struct {
    label: []const u8,
    marker: []const u8, // "" when none (e.g. the picker)
    marker_color: [3]f32 = .{ 0, 0, 0 }, // caller-supplied; ignored when marker is ""
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
    nameAt: *const fn (*anyopaque, usize) []const u8,
    sel_row: usize,
    scroll: usize,
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
    return @max(LEGEND_H, cell_h + 18);
}

/// Rows that fit between the header and the legend.
pub fn bodyVisibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    const usable = content_h - headerHeight(cell_h) - legendHeight(cell_h);
    if (usable <= 0) return 0;
    return @intFromFloat(@max(0.0, @floor(usable / rowHeight(cell_h))));
}

fn clampScroll(requested: usize, total: usize, visible: usize) usize {
    if (total <= visible) return 0;
    return @min(requested, total - visible);
}

fn yFromTop(window_height: f32, top_px: f32, h: f32) f32 {
    return window_height - top_px - h;
}
fn yTextFromTop(draw: DrawContext, window_height: f32, top_px: f32) f32 {
    return window_height - top_px - draw.cell_h;
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const c = @max(0.0, @min(1.0, t));
    return .{ a[0] + (b[0] - a[0]) * c, a[1] + (b[1] - a[1]) * c, a[2] + (b[2] - a[2]) * c };
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
    const content_x = @round(x);
    const content_w = @round(@max(1.0, width));
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    if (content_w <= 1 or content_h <= 1) return;

    const bg = draw.bg;
    const fg = draw.fg;
    const accent = draw.accent;
    const panel_strong = mixColor(bg, fg, 0.075);
    const line = mixColor(bg, fg, 0.18);
    const muted = mixColor(bg, fg, 0.58);
    const selected_bg = mixColor(bg, accent, 0.18);

    draw.fillQuad(content_x, 0, content_w, content_h, bg);

    // --- Header: title · count + status. ---
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(content_x, yFromTop(window_height, top, header_h), content_w, header_h, panel_strong, 0.9);
    draw.fillQuad(content_x, yFromTop(window_height, top + header_h, 1), content_w, 1, line);

    const title_y = yTextFromTop(draw, window_height, top + 11);
    const title_end = draw.renderTextLimited(view.title, content_x + PAD_X, title_y, fg, content_w - PAD_X * 2);
    var sub_buf: [64]u8 = undefined;
    const sub = std.fmt.bufPrint(&sub_buf, " · {d}", .{view.skills_len}) catch "";
    const sub_end = draw.renderTextLimited(sub, title_end, title_y, muted, @max(0, content_x + content_w - PAD_X - title_end));
    if (view.status.len > 0) {
        const sx = sub_end + 16;
        _ = draw.renderTextLimited(view.status, sx, title_y, accent, @max(0, content_x + content_w - PAD_X - sx));
    }

    const body_top = top + header_h;

    switch (view.overlay) {
        .list => |lv| {
            renderList(draw, lv, content_x, content_w, window_height, body_top, fg, muted, accent, line, selected_bg);
        },
        .text => |tv| {
            renderTextPreview(draw, tv, content_x, content_w, window_height, top, body_top, fg, muted, accent, line);
            return; // own footer hint; no action legend
        },
        else => {
            renderSkillList(draw, view, content_x, content_w, window_height, top, body_top, fg, muted, accent, line, selected_bg);
            if (view.overlay == .confirm) {
                const bar_h = rowHeight(draw.cell_h);
                const bar_y = legendHeight(draw.cell_h);
                draw.fillQuadAlpha(content_x, bar_y, content_w, bar_h, mixColor(bg, accent, 0.22), 0.97);
                const t_y = bar_y + (bar_h - draw.cell_h) / 2;
                _ = draw.renderTextLimited(view.overlay.confirm, content_x + PAD_X, t_y, fg, content_w - PAD_X * 2);
                return; // confirm replaces the legend line
            }
            if (view.overlay == .input) {
                const iv = view.overlay.input;
                const bar_h = rowHeight(draw.cell_h) * 2;
                const bar_y = legendHeight(draw.cell_h);
                draw.fillQuadAlpha(content_x, bar_y, content_w, bar_h, mixColor(bg, accent, 0.22), 0.97);
                const prompt_y = bar_y + bar_h - draw.cell_h - 6;
                _ = draw.renderTextLimited(iv.prompt, content_x + PAD_X, prompt_y, muted, content_w - PAD_X * 2);
                // editable line with a trailing caret
                var line_buf: [600]u8 = undefined;
                const shown = std.fmt.bufPrint(&line_buf, "{s}_", .{iv.text}) catch iv.text;
                const text_y = bar_y + (rowHeight(draw.cell_h) - draw.cell_h) / 2;
                _ = draw.renderTextLimited(shown, content_x + PAD_X, text_y, fg, content_w - PAD_X * 2);
                return; // input replaces the legend line
            }
        },
    }

    renderLegend(draw, view.legend, content_x, content_w, muted, line);
}

fn renderSkillList(
    draw: DrawContext,
    view: View,
    content_x: f32,
    content_w: f32,
    window_height: f32,
    top: f32,
    body_top: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    line: [3]f32,
    selected_bg: [3]f32,
) void {
    if (view.skills_len == 0) {
        _ = draw.renderTextLimited(view.status, content_x + PAD_X, yTextFromTop(draw, window_height, body_top + 24), muted, content_w - PAD_X * 2);
        return;
    }
    const row_h = rowHeight(draw.cell_h);
    const cap = bodyVisibleCapacity(window_height, top, draw.cell_h);
    const scroll = clampScroll(view.scroll, view.skills_len, cap);
    var rendered: usize = 0;
    var ri: usize = scroll;
    while (ri < view.skills_len and rendered < cap) : (ri += 1) {
        const row_top_px = body_top + @as(f32, @floatFromInt(rendered)) * row_h;
        const row_y = yFromTop(window_height, row_top_px, row_h);
        if (ri == view.sel_row) {
            draw.fillQuadAlpha(content_x, row_y, content_w, row_h, selected_bg, 0.55);
            draw.fillQuad(content_x, row_y, 3, row_h, accent);
        }
        draw.fillQuadAlpha(content_x, row_y, content_w, 1, line, 0.4);
        const text_y = yTextFromTop(draw, window_height, row_top_px + (row_h - draw.cell_h) / 2);
        _ = draw.renderTextLimited(view.nameAt(view.ctx, ri), content_x + PAD_X, text_y, fg, content_w - PAD_X * 2);
        rendered += 1;
    }
}

fn renderList(
    draw: DrawContext,
    lv: ListView,
    content_x: f32,
    content_w: f32,
    window_height: f32,
    body_top: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    line: [3]f32,
    selected_bg: [3]f32,
) void {
    // Title line.
    const title_y = yTextFromTop(draw, window_height, body_top + 8);
    _ = draw.renderTextLimited(lv.title, content_x + PAD_X, title_y, muted, content_w - PAD_X * 2);
    const list_top = body_top + rowHeight(draw.cell_h);

    const row_h = rowHeight(draw.cell_h);
    const marker_w: f32 = 110;
    var i: usize = 0;
    while (i < lv.len) : (i += 1) {
        const row_top_px = list_top + @as(f32, @floatFromInt(i)) * row_h;
        const row_y = yFromTop(window_height, row_top_px, row_h);
        if (i == lv.sel) {
            draw.fillQuadAlpha(content_x, row_y, content_w, row_h, selected_bg, 0.55);
            draw.fillQuad(content_x, row_y, 3, row_h, accent);
        }
        draw.fillQuadAlpha(content_x, row_y, content_w, 1, line, 0.4);
        const text_y = yTextFromTop(draw, window_height, row_top_px + (row_h - draw.cell_h) / 2);
        const item = lv.itemAt(lv.ctx, i);
        _ = draw.renderTextLimited(item.label, content_x + PAD_X, text_y, fg, content_w - PAD_X * 2 - marker_w);
        if (item.marker.len > 0) {
            const mx = content_x + content_w - PAD_X - marker_w;
            _ = draw.renderTextLimited(item.marker, mx, text_y, item.marker_color, marker_w);
        }
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
    content_x: f32,
    content_w: f32,
    window_height: f32,
    top: f32,
    body_top: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    line: [3]f32,
) void {
    const row_h = rowHeight(draw.cell_h);
    // Title row.
    const title_y = yTextFromTop(draw, window_height, body_top + 8);
    _ = draw.renderTextLimited(tv.title, content_x + PAD_X, title_y, accent, content_w - PAD_X * 2);
    draw.fillQuad(content_x, yFromTop(window_height, body_top + row_h, 1), content_w, 1, line);

    const text_top = body_top + row_h;
    const footer_h = legendHeight(draw.cell_h);
    const line_pitch = draw.cell_h + 6;
    const avail_h = window_height - top - text_top - footer_h - 6;

    if (avail_h > line_pitch) {
        const visible: usize = @intFromFloat(@floor(avail_h / line_pitch));
        const advance = draw.glyphAdvance('M');
        const cols = wrapCols(content_w - PAD_X * 2, advance);
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
            const ly = yTextFromTop(draw, window_height, top_px);
            if (dl.len > 0) _ = draw.renderTextLimited(dl, content_x + PAD_X, ly, fg, content_w - PAD_X * 2);
        }
    }

    // Footer hint replaces the action legend.
    const legend_h = legendHeight(draw.cell_h);
    draw.fillQuad(content_x, legend_h, content_w, 1, line);
    const hint_y = (legend_h - draw.cell_h) / 2;
    _ = draw.renderTextLimited(tv.hint, content_x + PAD_X, hint_y, muted, content_w - PAD_X * 2);
}

fn renderLegend(draw: DrawContext, legend: []const u8, content_x: f32, content_w: f32, muted: [3]f32, line: [3]f32) void {
    const legend_h = legendHeight(draw.cell_h);
    draw.fillQuad(content_x, legend_h, content_w, 1, line);
    const text_y = (legend_h - draw.cell_h) / 2;
    _ = draw.renderTextLimited(legend, content_x + PAD_X, text_y, muted, content_w - PAD_X * 2);
}

// --- Tests ---

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
