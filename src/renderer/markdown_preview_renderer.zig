//! Renderer for the right-side Markdown/text/image preview panel.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const panel = @import("../markdown_preview_panel.zig");
const markdown_preview = @import("../markdown_preview.zig");
const ui_perf = @import("../ui_perf.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const c = @cImport({
    @cInclude("glad/gl.h");
    @cInclude("stb_image.h");
});

const FOOTER_HEIGHT: f32 = 44;
const PAD_X: f32 = 16;
const PAD_Y: f32 = 18;
const LINE_GAP: f32 = 6;
const MAX_RENDER_LINES: usize = 512;
const MAX_TABLE_SCAN_ROWS: usize = 128;
const TABLE_CELL_PAD_X: f32 = 8;
const TABLE_MIN_COL_W: f32 = 64;
const TABLE_MAX_COL_W: f32 = 220;
const TABLE_FIT_MIN_COL_W: f32 = 28;

threadlocal var g_image_texture: c.GLuint = 0;
threadlocal var g_image_width: c_int = 0;
threadlocal var g_image_height: c_int = 0;
threadlocal var g_image_generation: u64 = std.math.maxInt(u64);
threadlocal var g_image_failed: bool = false;

fn blend(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

pub fn render(window_width: f32, window_height: f32, titlebar_h: f32, right_offset: f32) void {
    if (!panel.isVisibleForActiveTab()) {
        unloadImageTexture();
        return;
    }
    const perf = ui_perf.begin("markdown_preview_renderer.render");
    defer perf.end();

    const panel_w = panel.width();
    if (panel_w <= 0) return;

    const side_h = window_height - titlebar_h;
    if (side_h <= 0) return;

    const panel_x = window_width - right_offset - panel_w;

    const gl = AppWindow.gl;
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_bg = blend(bg, fg, 0.03);
    const card_bg = blend(bg, fg, 0.055);
    const code_bg = blend(bg, fg, 0.075);
    const border = blend(bg, .{ 0.0, 0.0, 0.0 }, 0.22);
    const muted = blend(bg, fg, 0.62);
    const normal = blend(bg, fg, 0.88);
    const strong = blend(bg, fg, 0.96);
    const resize_hovered = blk: {
        const win = AppWindow.g_window orelse break :blk false;
        if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
        const mx: f32 = @floatFromInt(win.mouse_x);
        const my: f32 = @floatFromInt(win.mouse_y);
        const half_hit = panel.RESIZE_HIT_WIDTH / 2;
        break :blk mx >= panel_x - half_hit and mx <= panel_x + half_hit and my >= titlebar_h and my < window_height;
    };
    const edge_color = if (resize_hovered or AppWindow.input.g_markdown_preview_resize_dragging) blend(bg, accent, 0.38) else border;

    gl_init.renderQuad(panel_x, 0, panel_w, side_h, panel_bg);
    gl_init.renderQuad(panel_x, 0, if (resize_hovered or AppWindow.input.g_markdown_preview_resize_dragging) 2 else 1, side_h, edge_color);

    renderFooter(panel_x, panel_w, card_bg, border, muted, normal, accent);

    renderDocument(panel_x, panel_w, window_height, titlebar_h, normal, muted, strong, accent, code_bg, border);
}

fn renderFooter(
    panel_x: f32,
    panel_w: f32,
    card_bg: [3]f32,
    border: [3]f32,
    muted: [3]f32,
    normal: [3]f32,
    accent: [3]f32,
) void {
    gl_init.renderQuad(panel_x, 0, panel_w, FOOTER_HEIGHT, card_bg);
    gl_init.renderQuad(panel_x, FOOTER_HEIGHT - 1, panel_w, 1, border);

    const badge = switch (panel.g_kind) {
        .markdown => "MD",
        .text => "TXT",
        .csv => "CSV",
        .tsv => "TSV",
        .image => "IMG",
    };
    const text_y = (FOOTER_HEIGHT - font.g_titlebar_cell_height) / 2;
    const badge_end = titlebar.renderTextLimited(badge, panel_x + PAD_X, text_y, accent, 40);
    const content_right = panel_x + panel_w - PAD_X;
    const title_x = badge_end + 10;
    const title_max_w = @max(40, @min(panel_w * 0.34, content_right - title_x));
    const title_end = titlebar.renderTextLimited(panel.title(), title_x, text_y, normal, title_max_w);

    var sep_x = title_end + 10;
    if (sep_x + 12 < content_right) {
        sep_x = titlebar.renderTextLimited("/", sep_x, text_y, muted, 12) + 8;
        _ = titlebar.renderTextLimited(panel.path(), sep_x, text_y, muted, content_right - sep_x);
    }
}

fn renderDocument(
    panel_x: f32,
    panel_w: f32,
    window_height: f32,
    titlebar_h: f32,
    normal: [3]f32,
    muted: [3]f32,
    strong: [3]f32,
    accent: [3]f32,
    code_bg: [3]f32,
    border: [3]f32,
) void {
    const body_top = titlebar_h + PAD_Y;
    const body_bottom = FOOTER_HEIGHT + PAD_Y;
    const body_h = window_height - body_top - body_bottom;
    if (body_h <= 0) return;

    if (panel.g_kind == .image) {
        renderImageDocument(panel_x, panel_w, window_height, body_top, body_h, normal, muted, border);
        return;
    }
    if (markdown_preview.delimiterForKind(panel.g_kind)) |delimiter| {
        renderDelimitedDocument(panel_x, panel_w, window_height, body_top, body_h, delimiter, normal, muted, strong, accent, code_bg, border);
        return;
    }

    const row_h = @max(22, font.g_titlebar_cell_height + LINE_GAP);
    var y_from_top: f32 = body_top - panel.g_scroll_offset;
    const max_w = panel_w - PAD_X * 2;

    var in_code = false;
    var rendered: usize = 0;
    var lines = std.mem.splitScalar(u8, panel.source(), '\n');
    while (lines.next()) |raw_line| {
        if (rendered >= MAX_RENDER_LINES) break;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const consumed = renderMarkdownLine(
            panel_x + PAD_X,
            max_w,
            window_height,
            body_top,
            body_h,
            y_from_top,
            row_h,
            line,
            &in_code,
            normal,
            muted,
            strong,
            accent,
            code_bg,
            border,
        );
        y_from_top += consumed;
        rendered += 1;
        if (y_from_top > body_top + body_h + row_h * 4) break;
    }
}

const TableLayout = struct {
    widths: [markdown_preview.MAX_TABLE_COLS]f32 = [_]f32{0} ** markdown_preview.MAX_TABLE_COLS,
    col_count: usize = 0,
    total_w: f32 = 0,
};

const HoveredTableCell = struct {
    x: f32 = 0,
    y_top: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    text_buf: [markdown_preview.MAX_TABLE_CELL_BYTES]u8 = undefined,
    text_len: usize = 0,
};

fn renderDelimitedDocument(
    panel_x: f32,
    panel_w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    delimiter: u8,
    normal: [3]f32,
    muted: [3]f32,
    strong: [3]f32,
    accent: [3]f32,
    code_bg: [3]f32,
    border: [3]f32,
) void {
    const content_x = panel_x + PAD_X;
    const content_w = panel_w - PAD_X * 2;
    if (content_w <= 0) return;

    switch (panel.g_load_status) {
        .loading => {
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Loading preview...", muted);
            return;
        },
        .failed => {
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Preview failed", normal);
            return;
        },
        .too_large => {
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Preview too large", normal);
            return;
        },
        .idle => return,
        .ready => {},
    }

    const source = panel.source();
    const layout = computeTableLayout(source, delimiter, content_w);
    if (layout.col_count == 0) {
        renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Empty table", muted);
        return;
    }

    const row_h = @max(26, font.g_titlebar_cell_height + 10);
    if (body_h <= row_h) return;

    var buffers: [markdown_preview.MAX_TABLE_COLS][markdown_preview.MAX_TABLE_CELL_BYTES]u8 = undefined;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var saw_header = false;
    var data_row_idx: usize = 0;
    var rendered_rows: usize = 0;
    var hovered_cell: ?HoveredTableCell = null;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;

        const row = markdown_preview.parseDelimitedRow(line, delimiter, &buffers);
        if (row.count == 0) continue;

        if (!saw_header) {
            renderTableRow(
                content_x,
                window_height,
                body_top,
                row_h,
                body_top,
                row_h,
                row_h,
                &row,
                &layout,
                &hovered_cell,
                true,
                0,
                normal,
                muted,
                strong,
                accent,
                code_bg,
                border,
            );
            saw_header = true;
            continue;
        }

        const row_top = body_top + row_h + @as(f32, @floatFromInt(data_row_idx)) * row_h - panel.g_scroll_offset;
        data_row_idx += 1;
        if (rendered_rows >= MAX_RENDER_LINES) break;
        if (row_top > body_top + body_h) break;
        if (row_top + row_h < body_top + row_h) continue;

        renderTableRow(
            content_x,
            window_height,
            body_top + row_h,
            body_h - row_h,
            row_top,
            row_h,
            row_h,
            &row,
            &layout,
            &hovered_cell,
            false,
            data_row_idx,
            normal,
            muted,
            strong,
            accent,
            code_bg,
            border,
        );
        rendered_rows += 1;
    }

    if (!saw_header) {
        renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Empty table", muted);
        return;
    }

    if (hovered_cell) |cell| {
        renderTableHover(cell, panel_x, panel_w, window_height, body_top, body_h, normal, strong, code_bg, border);
    }
}

fn computeTableLayout(source: []const u8, delimiter: u8, max_w: f32) TableLayout {
    var layout: TableLayout = .{};
    var buffers: [markdown_preview.MAX_TABLE_COLS][markdown_preview.MAX_TABLE_CELL_BYTES]u8 = undefined;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var scanned: usize = 0;

    while (lines.next()) |raw_line| {
        if (scanned >= MAX_TABLE_SCAN_ROWS) break;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;

        const row = markdown_preview.parseDelimitedRow(line, delimiter, &buffers);
        if (row.count == 0) continue;
        layout.col_count = @max(layout.col_count, row.count);
        for (0..row.count) |idx| {
            layout.widths[idx] = @max(layout.widths[idx], tableCellDesiredWidth(row.cells[idx]));
        }
        scanned += 1;
    }

    if (layout.col_count == 0) return layout;
    for (0..layout.col_count) |idx| {
        if (layout.widths[idx] <= 0) layout.widths[idx] = TABLE_MIN_COL_W;
    }

    fitTableLayout(&layout, max_w);
    return layout;
}

fn tableCellDesiredWidth(text: []const u8) f32 {
    const capped_len = @min(text.len, @as(usize, 28));
    const text_w = @as(f32, @floatFromInt(capped_len)) * @max(font.g_titlebar_cell_width, 1);
    return @max(TABLE_MIN_COL_W, @min(TABLE_MAX_COL_W, text_w + TABLE_CELL_PAD_X * 2));
}

fn fitTableLayout(layout: *TableLayout, max_w: f32) void {
    const grid_w = @as(f32, @floatFromInt(layout.col_count + 1));
    var cell_total: f32 = 0;
    for (0..layout.col_count) |idx| cell_total += layout.widths[idx];
    layout.total_w = cell_total + grid_w;

    if (layout.total_w <= max_w or layout.col_count == 0) return;

    const count_f = @as(f32, @floatFromInt(layout.col_count));
    const raw_available = @max(1, max_w - grid_w);
    const fit_floor = @max(8, @floor(raw_available / count_f));
    const min_w = if (count_f * TABLE_FIT_MIN_COL_W <= raw_available) TABLE_FIT_MIN_COL_W else fit_floor;
    const available_cells = @max(count_f * min_w, raw_available);
    const scale = if (cell_total > 0) available_cells / cell_total else 1.0;

    cell_total = 0;
    for (0..layout.col_count) |idx| {
        layout.widths[idx] = @max(min_w, @floor(layout.widths[idx] * scale));
        cell_total += layout.widths[idx];
    }
    layout.total_w = cell_total + grid_w;

    if (layout.total_w > max_w and max_w > grid_w) {
        const equal_w = @max(8, @floor((max_w - grid_w) / count_f));
        cell_total = 0;
        for (0..layout.col_count) |idx| {
            layout.widths[idx] = @min(layout.widths[idx], equal_w);
            cell_total += layout.widths[idx];
        }
        layout.total_w = cell_total + grid_w;
    }
}

fn renderTableRow(
    x: f32,
    window_height: f32,
    clip_top: f32,
    clip_h: f32,
    row_top: f32,
    row_h: f32,
    text_row_h: f32,
    row: *const markdown_preview.TableRow,
    layout: *const TableLayout,
    hovered_cell: *?HoveredTableCell,
    is_header: bool,
    row_index: usize,
    normal: [3]f32,
    muted: [3]f32,
    strong: [3]f32,
    accent: [3]f32,
    code_bg: [3]f32,
    border: [3]f32,
) void {
    const bg = AppWindow.g_theme.background;
    const row_bg: ?[3]f32 = if (is_header)
        blend(code_bg, accent, 0.18)
    else if (row_index % 2 == 0)
        blend(bg, AppWindow.g_theme.foreground, 0.035)
    else
        null;

    if (row_bg) |color| {
        renderTopQuad(x, layout.total_w, window_height, clip_top, clip_h, row_top, row_h, color);
    }

    renderTopQuad(x, layout.total_w, window_height, clip_top, clip_h, row_top, 1, border);
    renderTopQuad(x, layout.total_w, window_height, clip_top, clip_h, row_top + row_h - 1, 1, border);

    var col_x = x;
    renderTopQuad(col_x, 1, window_height, clip_top, clip_h, row_top, row_h, border);
    for (0..layout.col_count) |col| {
        const col_w = layout.widths[col];
        col_x += col_w + 1;
        renderTopQuad(col_x, 1, window_height, clip_top, clip_h, row_top, row_h, border);
    }

    if (row_top < clip_top or row_top + row_h > clip_top + clip_h) return;

    captureTableHoverCell(x, row_top, row_h, row, layout, hovered_cell);

    col_x = x + 1;
    const text_color = if (is_header) strong else normal;
    const empty_color = if (is_header) strong else muted;
    const gl_y = window_height - row_top - text_row_h + (text_row_h - font.g_titlebar_cell_height) / 2;
    for (0..layout.col_count) |col| {
        const col_w = layout.widths[col];
        const text = if (col < row.count) row.cells[col] else "";
        const color = if (text.len == 0) empty_color else text_color;
        _ = titlebar.renderTextLimited(text, col_x + TABLE_CELL_PAD_X, gl_y, color, @max(4, col_w - TABLE_CELL_PAD_X * 2));
        col_x += col_w + 1;
    }
}

fn captureTableHoverCell(
    x: f32,
    row_top: f32,
    row_h: f32,
    row: *const markdown_preview.TableRow,
    layout: *const TableLayout,
    hovered_cell: *?HoveredTableCell,
) void {
    const win = AppWindow.g_window orelse return;
    if (win.mouse_x < 0 or win.mouse_y < 0) return;

    const mx: f32 = @floatFromInt(win.mouse_x);
    const my: f32 = @floatFromInt(win.mouse_y);
    if (my < row_top or my >= row_top + row_h) return;

    var col_x = x + 1;
    for (0..layout.col_count) |col| {
        const col_w = layout.widths[col];
        if (mx >= col_x and mx < col_x + col_w) {
            if (col >= row.count) return;
            const text = row.cells[col];
            if (text.len == 0 or !tableCellNeedsHover(text, col_w)) return;

            var hover: HoveredTableCell = .{
                .x = col_x,
                .y_top = row_top,
                .w = col_w,
                .h = row_h,
            };
            hover.text_len = @min(text.len, hover.text_buf.len);
            @memcpy(hover.text_buf[0..hover.text_len], text[0..hover.text_len]);
            hovered_cell.* = hover;
            return;
        }
        col_x += col_w + 1;
    }
}

fn tableCellNeedsHover(text: []const u8, col_w: f32) bool {
    const available = @max(1, col_w - TABLE_CELL_PAD_X * 2);
    const approx_w = @as(f32, @floatFromInt(text.len)) * @max(font.g_titlebar_cell_width, 1);
    return approx_w > available or text.len > 20;
}

fn renderTableHover(
    cell: HoveredTableCell,
    panel_x: f32,
    panel_w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    normal: [3]f32,
    strong: [3]f32,
    code_bg: [3]f32,
    border: [3]f32,
) void {
    const text = cell.text_buf[0..cell.text_len];
    if (text.len == 0) return;

    const popup_max_w = @min(620, @max(160, panel_w - PAD_X * 2));
    const text_w = @as(f32, @floatFromInt(@min(text.len, @as(usize, 72)))) * @max(font.g_titlebar_cell_width, 1);
    const popup_w = @min(popup_max_w, @max(220, text_w + 24));
    const row_h = @max(24, font.g_titlebar_cell_height + 8);
    const inner_w = popup_w - 24;
    const chars_per_line = @max(@as(usize, 12), @as(usize, @intFromFloat(inner_w / @max(font.g_titlebar_cell_width, 1))));

    var ranges: [6]struct { start: usize, end: usize } = undefined;
    var line_count: usize = 0;
    var offset: usize = 0;
    while (offset < text.len and line_count < ranges.len) {
        const end = wrapEnd(text, offset, chars_per_line);
        ranges[line_count] = .{ .start = offset, .end = end };
        line_count += 1;
        offset = skipSpaces(text, end);
    }
    if (line_count == 0) return;

    const popup_h = @as(f32, @floatFromInt(line_count)) * row_h + 16;
    const min_x = panel_x + PAD_X;
    const max_x = panel_x + panel_w - PAD_X - popup_w;
    const popup_x = @max(min_x, @min(max_x, cell.x));

    var popup_top = cell.y_top + cell.h + 6;
    const body_bottom = body_top + body_h;
    if (popup_top + popup_h > body_bottom) popup_top = cell.y_top - popup_h - 6;
    popup_top = @max(body_top + 4, @min(body_bottom - popup_h - 4, popup_top));

    const popup_y = window_height - popup_top - popup_h;
    const popup_bg = blend(AppWindow.g_theme.background, code_bg, 0.82);
    gl_init.renderQuad(popup_x - 1, popup_y - 1, popup_w + 2, popup_h + 2, border);
    gl_init.renderQuad(popup_x, popup_y, popup_w, popup_h, popup_bg);
    gl_init.renderQuad(popup_x, popup_y + popup_h - 2, popup_w, 2, strong);

    for (0..line_count) |idx| {
        const line_top = popup_top + 8 + @as(f32, @floatFromInt(idx)) * row_h;
        const text_y = window_height - line_top - row_h + (row_h - font.g_titlebar_cell_height) / 2;
        _ = titlebar.renderTextLimited(text[ranges[idx].start..ranges[idx].end], popup_x + 12, text_y, normal, inner_w);
    }
}

fn renderImageDocument(
    panel_x: f32,
    panel_w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    normal: [3]f32,
    muted: [3]f32,
    border: [3]f32,
) void {
    const content_x = panel_x + PAD_X;
    const content_w = panel_w - PAD_X * 2;
    if (content_w <= 0) return;

    switch (panel.g_load_status) {
        .loading => {
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Loading preview...", muted);
            return;
        },
        .failed => {
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Image preview failed", normal);
            return;
        },
        .too_large => {
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Preview too large", normal);
            return;
        },
        .idle => return,
        .ready => {},
    }

    if (!ensureImageTexture()) {
        renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Image preview failed", normal);
        return;
    }

    const image_w: f32 = @floatFromInt(g_image_width);
    const image_h: f32 = @floatFromInt(g_image_height);
    if (image_w <= 0 or image_h <= 0) return;

    const scale = @min(content_w / image_w, body_h / image_h) * panel.imageZoom();
    if (scale <= 0) return;

    const draw_w = image_w * scale;
    const draw_h = image_h * scale;
    panel.clampImagePan(content_w, body_h, draw_w, draw_h);
    const draw_x = content_x + (content_w - draw_w) / 2 + panel.imagePanX();
    const draw_top = body_top + (body_h - draw_h) / 2 + panel.imagePanY();
    const draw_y = window_height - draw_top - draw_h;

    const gl = AppWindow.gl;
    const clip_x: c.GLint = @intFromFloat(@max(0, @floor(content_x)));
    const clip_y: c.GLint = @intFromFloat(@max(0, @floor(window_height - body_top - body_h)));
    const clip_w: c.GLsizei = @intFromFloat(@max(0, @ceil(content_w)));
    const clip_h: c.GLsizei = @intFromFloat(@max(0, @ceil(body_h)));
    if (clip_w <= 0 or clip_h <= 0) return;

    const scissor_was_enabled = gl.IsEnabled.?(c.GL_SCISSOR_TEST) == c.GL_TRUE;
    var previous_scissor: [4]c.GLint = undefined;
    if (scissor_was_enabled) gl.GetIntegerv.?(c.GL_SCISSOR_BOX, &previous_scissor);
    gl.Enable.?(c.GL_SCISSOR_TEST);
    gl.Scissor.?(clip_x, clip_y, clip_w, clip_h);
    gl_init.renderQuad(draw_x - 1, draw_y - 1, draw_w + 2, draw_h + 2, border);
    drawImageTexture(draw_x, draw_y, draw_w, draw_h, window_height);
    if (scissor_was_enabled) {
        gl.Scissor.?(previous_scissor[0], previous_scissor[1], previous_scissor[2], previous_scissor[3]);
    } else {
        gl.Disable.?(c.GL_SCISSOR_TEST);
    }
}

fn renderStatusMessage(
    x: f32,
    max_w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    text: []const u8,
    color: [3]f32,
) void {
    const row_h = @max(22, font.g_titlebar_cell_height + LINE_GAP);
    const y_top = body_top + @max(0, (body_h - row_h) / 2);
    const gl_y = window_height - y_top - row_h;
    _ = titlebar.renderTextLimited(text, x, gl_y + (row_h - font.g_titlebar_cell_height) / 2, color, max_w);
}

fn ensureImageTexture() bool {
    const generation = panel.contentGeneration();
    if (g_image_generation == generation) return g_image_texture != 0 and !g_image_failed;

    unloadImageTexture();
    g_image_generation = generation;
    g_image_failed = true;

    const source = panel.source();
    if (source.len == 0 or source.len > std.math.maxInt(c_int)) return false;

    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const data = c.stbi_load_from_memory(@ptrCast(source.ptr), @intCast(source.len), &w, &h, &n, 4);
    if (data == null or w <= 0 or h <= 0) return false;
    defer c.stbi_image_free(data);

    const gl = AppWindow.gl;
    gl.GenTextures.?(1, &g_image_texture);
    if (g_image_texture == 0) return false;

    gl.BindTexture.?(c.GL_TEXTURE_2D, g_image_texture);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, 1);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, data);

    g_image_width = w;
    g_image_height = h;
    g_image_failed = false;
    return true;
}

fn drawImageTexture(x: f32, y: f32, w: f32, h: f32, window_height: f32) void {
    if (g_image_texture == 0 or gl_init.simple_color_shader == 0) return;
    const gl = AppWindow.gl;

    gl.UseProgram.?(gl_init.simple_color_shader);
    gl_init.setProjectionForProgram(gl_init.simple_color_shader, window_height);
    gl.Uniform1f.?(gl.GetUniformLocation.?(gl_init.simple_color_shader, "opacity"), 1.0);
    gl.Uniform1i.?(gl.GetUniformLocation.?(gl_init.simple_color_shader, "text"), 0);

    const vertices = [6][4]f32{
        .{ x, y + h, 0, 0 },
        .{ x, y, 0, 1 },
        .{ x + w, y, 1, 1 },
        .{ x, y + h, 0, 0 },
        .{ x + w, y, 1, 1 },
        .{ x + w, y + h, 1, 0 },
    };

    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_image_texture);
    gl.BindVertexArray.?(gl_init.vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    gl_init.g_draw_call_count += 1;
}

fn unloadImageTexture() void {
    if (g_image_texture != 0) {
        const gl = AppWindow.gl;
        gl.DeleteTextures.?(1, &g_image_texture);
        g_image_texture = 0;
    }
    g_image_width = 0;
    g_image_height = 0;
    g_image_generation = std.math.maxInt(u64);
    g_image_failed = false;
}

pub fn deinit() void {
    unloadImageTexture();
}

fn renderMarkdownLine(
    x: f32,
    max_w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    y_from_top: f32,
    row_h: f32,
    raw_line: []const u8,
    in_code: *bool,
    normal: [3]f32,
    muted: [3]f32,
    strong: [3]f32,
    accent: [3]f32,
    code_bg: [3]f32,
    border: [3]f32,
) f32 {
    const trimmed = std.mem.trimLeft(u8, raw_line, " \t");
    if (isFence(trimmed)) {
        in_code.* = !in_code.*;
        const line_y_top = y_from_top + row_h * 0.15;
        if (line_y_top + row_h >= body_top and line_y_top <= body_top + body_h) {
            const gl_y = window_height - line_y_top - row_h * 0.75;
            gl_init.renderQuad(x, gl_y, max_w, 1, border);
            const lang = fenceLanguage(trimmed);
            if (lang.len > 0 and in_code.*) {
                _ = titlebar.renderTextLimited(lang, x + 8, gl_y + 5, muted, max_w - 16);
            }
        }
        return row_h * 0.9;
    }

    if (trimmed.len == 0) return row_h * 0.65;

    var clean_buf: [1024]u8 = undefined;
    var text = cleanInline(&clean_buf, trimmed);
    var color = normal;
    var indent: f32 = 0;
    var line_h = row_h;
    var bg: ?[3]f32 = null;
    var left_rule: ?[3]f32 = null;
    var underline = false;

    if (panel.g_kind == .text) {
        text = cleanPlain(&clean_buf, raw_line);
    } else if (in_code.*) {
        color = accent;
        text = cleanPlain(&clean_buf, raw_line);
        bg = code_bg;
        left_rule = accent;
    } else if (headingBody(trimmed)) |heading| {
        text = cleanInline(&clean_buf, heading.body);
        color = if (heading.level <= 2) strong else normal;
        line_h = switch (heading.level) {
            1 => row_h * 1.85,
            2 => row_h * 1.55,
            3 => row_h * 1.35,
            else => row_h * 1.18,
        };
        if (heading.level <= 2) {
            bg = blend(AppWindow.g_theme.background, accent, 0.08);
            left_rule = accent;
            underline = true;
        }
    } else if (htmlHeadingBody(trimmed)) |heading| {
        text = cleanInline(&clean_buf, heading.body);
        color = if (heading.level <= 2) strong else normal;
        line_h = switch (heading.level) {
            1 => row_h * 1.85,
            2 => row_h * 1.55,
            3 => row_h * 1.35,
            else => row_h * 1.18,
        };
        if (heading.level <= 2) {
            bg = blend(AppWindow.g_theme.background, accent, 0.08);
            left_rule = accent;
            underline = true;
        }
    } else if (std.mem.startsWith(u8, trimmed, ">")) {
        color = muted;
        indent = 18;
        left_rule = accent;
        text = cleanInline(&clean_buf, std.mem.trimLeft(u8, trimmed[1..], " \t"));
    } else if (isHorizontalRule(trimmed)) {
        const line_y_top = y_from_top + row_h * 0.5;
        if (line_y_top >= body_top and line_y_top <= body_top + body_h) {
            const gl_y = window_height - line_y_top - 1;
            gl_init.renderQuad(x, gl_y, max_w, 1, muted);
        }
        return row_h;
    } else if (listBody(trimmed)) |list| {
        color = normal;
        indent = 20;
        const body = cleanInline(&clean_buf, list.body);
        if (body.len + 2 <= clean_buf.len) {
            std.mem.copyBackwards(u8, clean_buf[2 .. body.len + 2], body);
            clean_buf[0] = bulletForList(list);
            clean_buf[1] = ' ';
            text = clean_buf[0 .. body.len + 2];
        } else {
            text = body;
        }
    }

    if (bg) |bg_color| {
        renderTopQuad(x - 8, max_w + 16, window_height, body_top, body_h, y_from_top, line_h, bg_color);
    }
    if (left_rule) |rule_color| {
        renderTopQuad(x - 8, 2, window_height, body_top, body_h, y_from_top + 3, @max(1, line_h - 6), rule_color);
    }
    if (underline) {
        const line_y_top = y_from_top + line_h - 4;
        if (line_y_top >= body_top and line_y_top <= body_top + body_h) {
            const gl_y = window_height - line_y_top - 1;
            gl_init.renderQuad(x, gl_y, max_w, 1, blend(AppWindow.g_theme.background, accent, 0.32));
        }
    }

    return renderWrappedText(
        x + indent,
        max_w - indent,
        window_height,
        body_top,
        body_h,
        y_from_top,
        line_h,
        text,
        color,
    );
}

fn renderWrappedText(
    x: f32,
    max_w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    y_from_top: f32,
    row_h: f32,
    text: []const u8,
    color: [3]f32,
) f32 {
    if (text.len == 0) return row_h;
    const chars_per_line = @max(@as(usize, 8), @as(usize, @intFromFloat(max_w / @max(font.g_titlebar_cell_width, 1))));
    var offset: usize = 0;
    var consumed: f32 = 0;
    while (offset < text.len) {
        const end = wrapEnd(text, offset, chars_per_line);
        const line_y_top = y_from_top + consumed;
        if (line_y_top + row_h >= body_top and line_y_top <= body_top + body_h) {
            const gl_y = window_height - line_y_top - row_h;
            _ = titlebar.renderTextLimited(text[offset..end], x, gl_y + (row_h - font.g_titlebar_cell_height) / 2, color, max_w);
        }
        consumed += row_h;
        offset = skipSpaces(text, end);
    }
    return consumed;
}

fn renderTopQuad(
    x: f32,
    w: f32,
    window_height: f32,
    body_top: f32,
    body_h: f32,
    y_from_top: f32,
    h: f32,
    color: [3]f32,
) void {
    const top = @max(y_from_top, body_top);
    const bottom = @min(y_from_top + h, body_top + body_h);
    if (bottom <= top) return;
    const gl_y = window_height - bottom;
    gl_init.renderQuad(x, gl_y, w, bottom - top, color);
}

fn wrapEnd(text: []const u8, start: usize, max_chars: usize) usize {
    const end = @min(text.len, start + max_chars);
    if (end >= text.len) return text.len;
    var i = end;
    while (i > start) : (i -= 1) {
        if (text[i - 1] == ' ' or text[i - 1] == '\t') return i - 1;
    }
    return end;
}

fn skipSpaces(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i;
}

const Heading = struct { level: usize, body: []const u8 };
const List = struct { body: []const u8 };

fn headingBody(line: []const u8) ?Heading {
    var level: usize = 0;
    while (level < line.len and line[level] == '#' and level < 6) : (level += 1) {}
    if (level == 0 or level >= line.len or line[level] != ' ') return null;
    return .{ .level = level, .body = std.mem.trimLeft(u8, line[level + 1 ..], " \t") };
}

fn htmlHeadingBody(line: []const u8) ?Heading {
    if (line.len < 4 or line[0] != '<' or (line[1] != 'h' and line[1] != 'H')) return null;
    const level_ch = line[2];
    if (level_ch < '1' or level_ch > '6') return null;
    const open_end = std.mem.indexOfScalar(u8, line, '>') orelse return null;
    const close_start = std.mem.indexOf(u8, line[open_end + 1 ..], "</") orelse line.len - (open_end + 1);
    const body = line[open_end + 1 .. open_end + 1 + close_start];
    return .{ .level = @intCast(level_ch - '0'), .body = body };
}

fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~");
}

fn fenceLanguage(line: []const u8) []const u8 {
    if (!isFence(line) or line.len <= 3) return "";
    return std.mem.trim(u8, line[3..], " \t");
}

fn isHorizontalRule(line: []const u8) bool {
    var marker: u8 = 0;
    var count: usize = 0;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (ch != '-' and ch != '*' and ch != '_') return false;
        if (marker == 0) marker = ch;
        if (ch != marker) return false;
        count += 1;
    }
    return count >= 3;
}

fn listBody(line: []const u8) ?List {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and isSpace(line[1])) {
        return .{ .body = std.mem.trimLeft(u8, line[2..], " \t") };
    }
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and isSpace(line[i + 1])) {
        return .{ .body = std.mem.trimLeft(u8, line[i + 2 ..], " \t") };
    }
    return null;
}

fn bulletForList(_: List) u8 {
    return '-';
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn cleanPlain(buf: *[1024]u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    for (text) |ch| {
        if (pos >= buf.len) break;
        if (ch == '\r' or ch == '\n' or ch == 0x1b) continue;
        buf[pos] = ch;
        pos += 1;
    }
    return std.mem.trim(u8, buf[0..pos], " \t");
}

fn cleanInline(buf: *[1024]u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < text.len and pos < buf.len) {
        const ch = text[i];
        if (ch == '<') {
            while (i < text.len and text[i] != '>') : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }
        if (ch == '[') {
            if (parseMarkdownLink(text, i)) |link| {
                pos = appendSlice(buf, pos, link.label);
                i = link.end;
                continue;
            }
        }
        if (ch == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (parseMarkdownLink(text, i + 1)) |link| {
                pos = appendSlice(buf, pos, link.label);
                i = link.end;
                continue;
            }
        }
        if (ch == '*' or ch == '_' or ch == '`' or ch == '\r' or ch == '\n' or ch == 0x1b) {
            i += 1;
            continue;
        }
        buf[pos] = ch;
        pos += 1;
        i += 1;
    }
    return std.mem.trim(u8, buf[0..pos], " \t");
}

const Link = struct { label: []const u8, end: usize };

fn parseMarkdownLink(text: []const u8, bracket: usize) ?Link {
    const close_rel = std.mem.indexOfScalar(u8, text[bracket + 1 ..], ']') orelse return null;
    const close = bracket + 1 + close_rel;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const url_start = close + 2;
    const url_rel = std.mem.indexOfScalar(u8, text[url_start..], ')') orelse return null;
    return .{ .label = text[bracket + 1 .. close], .end = url_start + url_rel + 1 };
}

fn appendSlice(buf: *[1024]u8, pos: usize, text: []const u8) usize {
    const len = @min(text.len, buf.len - pos);
    @memcpy(buf[pos..][0..len], text[0..len]);
    return pos + len;
}
