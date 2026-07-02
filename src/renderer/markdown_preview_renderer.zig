//! Renderer for the right-side Markdown/text/image preview panel.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const markdown_preview = @import("../preview/markdown.zig");
const pdf_preview = @import("../preview/pdf.zig");
const text_wrap = @import("../text_wrap.zig");
const ui_perf = @import("../ui_perf.zig");
const PreviewPane = @import("../preview/pane.zig");
const preview_diagnostics = @import("../preview/diagnostics.zig");
const preview_image_layout = @import("../preview/image_layout.zig");
const preview_close_button = @import("../input/preview_close_button.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const gpu = AppWindow.gpu;
const ui_pipeline = @import("ui_pipeline.zig");
const c = @cImport({
    @cInclude("stb_image.h");
});

const FOOTER_HEIGHT: f32 = 44;
/// Re-exported from the pure geometry module so the drawn header height and the
/// close-button hit-test share a single source of truth.
pub const HEADER_HEIGHT: f32 = preview_close_button.HEADER_HEIGHT;
const PAD_X: f32 = 16;
const PAD_Y: f32 = 18;
const LINE_GAP: f32 = 6;
// Upper bound on lines/rows laid out per pass. Off-screen lines are measured
// (to size the scrollbar) but not drawn, so this also bounds how far a large
// text/log head can be scrolled. Generous enough to page through a sizable head
// while keeping the per-pass walk cheap.
const MAX_RENDER_LINES: usize = 2000;
const MAX_TABLE_SCAN_ROWS: usize = 128;
const TABLE_CELL_PAD_X: f32 = 8;
const TABLE_MIN_COL_W: f32 = 64;
const TABLE_MAX_COL_W: f32 = 220;
const TABLE_FIT_MIN_COL_W: f32 = 28;

fn blend(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

/// Core renderer: draws the preview pane into the given pixel rect.
/// panel_top    = distance from window top to this pane's top edge (pixels)
/// panel_h      = height of this pane in pixels
pub fn renderInto(
    pane: *PreviewPane,
    panel_x: f32,
    panel_top: f32,
    panel_w: f32,
    panel_h: f32,
    window_height: f32,
    close_hovered: bool,
) void {
    if (panel_h <= 0) return;

    // GL origin is bottom-left, so the pane's bottom edge in GL space is:
    //   window_height - panel_top - panel_h
    const pane_gl_bottom = window_height - panel_top - panel_h;

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

    // Side background: fillQuad(x, gl_y, w, h) — gl_y = pane_gl_bottom
    ui_pipeline.fillQuad(panel_x, pane_gl_bottom, panel_w, panel_h, panel_bg);

    renderHeader(pane, panel_x, panel_w, window_height, panel_top, card_bg, border, muted, normal, accent, close_hovered);
    renderFooter(pane, panel_x, panel_w, pane_gl_bottom, card_bg, border, muted, normal, accent);

    renderDocument(pane, panel_x, panel_w, window_height, panel_top, panel_h, pane_gl_bottom, normal, muted, strong, accent, code_bg, border);
}

pub fn deinit() void {
    // Texture is now owned by PreviewPane instances; nothing to do here.
}

fn renderHeader(
    pane: *const PreviewPane,
    panel_x: f32,
    panel_w: f32,
    window_height: f32,
    panel_top: f32,
    card_bg: [3]f32,
    border: [3]f32,
    muted: [3]f32,
    normal: [3]f32,
    accent: [3]f32,
    close_hovered: bool,
) void {
    // The header is a top separator bar (badge/title/path live in the footer),
    // so its top-right corner is free for a close (×) button. The button lets
    // users dismiss the preview with the mouse without knowing the close-split
    // keybind; Ctrl+Shift+W still works too.
    // header_y (GL): window_height - panel_top - HEADER_HEIGHT.
    const header_y = window_height - panel_top - HEADER_HEIGHT;
    ui_pipeline.fillQuad(panel_x, header_y, panel_w, HEADER_HEIGHT, card_bg);
    ui_pipeline.fillQuad(panel_x, header_y, panel_w, 1, border);

    // Close (×) button, top-right. Geometry comes from the shared pure module
    // (top-down px); flip to GL for drawing. Symmetric box, so the X centers the
    // same in either y-convention.
    const b = preview_close_button.rect(panel_x, panel_top, panel_w);
    const btn_gl_y = window_height - b.y - b.h;
    if (close_hovered) {
        ui_pipeline.fillQuad(b.x, btn_gl_y, b.w, b.h, blend(card_bg, normal, 0.18));
    }
    const icon_color = if (close_hovered) normal else muted;
    titlebar.renderCloseIcon(b.x, btn_gl_y, b.w, b.h, icon_color);

    // Large text/log files are shown as a scrollable head; tell the user the rest
    // is clipped so they don't mistake the end of the window for the end of file.
    // The banner stops before the × button (b.x) so the two never overlap.
    if (pane.content_truncated and panel_w > PAD_X * 2) {
        var buf: [96]u8 = undefined;
        const label = truncatedBannerText(&buf, pane.sourceText().len);
        const text_y = header_y + (HEADER_HEIGHT - font.g_titlebar_cell_height) / 2;
        const banner_x = panel_x + PAD_X;
        const banner_max_w = @max(@as(f32, 0), b.x - 8 - banner_x);
        _ = titlebar.renderTextLimited(label, banner_x, text_y, accent, banner_max_w);
    }
}

/// Header banner for a truncated (head-only) preview, e.g.
/// "Large file: showing first 1.0 MB (scroll to read more)".
fn truncatedBannerText(buf: []u8, head_bytes: usize) []const u8 {
    const kib: usize = 1024;
    const mib: usize = 1024 * 1024;
    if (head_bytes >= mib) {
        return std.fmt.bufPrint(buf, "Large file: showing first {d}.{d} MB (scroll to read more)", .{ head_bytes / mib, (head_bytes % mib) * 10 / mib }) catch buf[0..0];
    }
    if (head_bytes >= kib) {
        return std.fmt.bufPrint(buf, "Large file: showing first {d} KB (scroll to read more)", .{head_bytes / kib}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "Large file: showing first {d} bytes (scroll to read more)", .{head_bytes}) catch buf[0..0];
}

fn renderFooter(
    pane: *PreviewPane,
    panel_x: f32,
    panel_w: f32,
    pane_gl_bottom: f32,
    card_bg: [3]f32,
    border: [3]f32,
    muted: [3]f32,
    normal: [3]f32,
    accent: [3]f32,
) void {
    // Footer sits at the pane's bottom edge in GL space.
    // Dock check: pane_gl_bottom = window_height - titlebar_h - (window_height - titlebar_h) = 0 ✓
    ui_pipeline.fillQuad(panel_x, pane_gl_bottom, panel_w, FOOTER_HEIGHT, card_bg);
    ui_pipeline.fillQuad(panel_x, pane_gl_bottom + FOOTER_HEIGHT - 1, panel_w, 1, border);

    const badge = switch (pane.kind) {
        .markdown => "MD",
        .text => "TXT",
        .csv => "CSV",
        .tsv => "TSV",
        .image => "IMG",
        .pdf => "PDF",
    };
    const text_y = pane_gl_bottom + (FOOTER_HEIGHT - font.g_titlebar_cell_height) / 2;
    var badge_end = titlebar.renderTextLimited(badge, panel_x + PAD_X, text_y, accent, 40);
    if (pane.kind == .pdf and pane.pdf_page_count > 0) {
        var page_buf: [24]u8 = undefined;
        const label = pdf_preview.formatPageIndicator(&page_buf, pane.pdf_page, pane.pdf_page_count);
        badge_end = titlebar.renderTextLimited(label, badge_end + 8, text_y, muted, 64);
    }
    const content_right = panel_x + panel_w - PAD_X;
    const title_x = badge_end + 10;
    const title_max_w = @max(40, @min(panel_w * 0.34, content_right - title_x));
    const title_end = titlebar.renderTextLimited(pane.title(), title_x, text_y, normal, title_max_w);

    var sep_x = title_end + 10;
    if (sep_x + 12 < content_right) {
        sep_x = titlebar.renderTextLimited("/", sep_x, text_y, muted, 12) + 8;
        _ = titlebar.renderTextLimited(pane.path(), sep_x, text_y, muted, content_right - sep_x);
    }
}

fn renderDocument(
    pane: *PreviewPane,
    panel_x: f32,
    panel_w: f32,
    window_height: f32,
    panel_top: f32,
    panel_h: f32,
    pane_gl_bottom: f32,
    normal: [3]f32,
    muted: [3]f32,
    strong: [3]f32,
    accent: [3]f32,
    code_bg: [3]f32,
    border: [3]f32,
) void {
    // body_top (from window top): panel_top + HEADER_HEIGHT + PAD_Y
    // Dock check: titlebar_h + HEADER_HEIGHT + PAD_Y ✓
    const body_top = panel_top + HEADER_HEIGHT + PAD_Y;
    // body_bottom margin (from window BOTTOM): pane_gl_bottom + FOOTER_HEIGHT + PAD_Y
    // Dock check: 0 + FOOTER_HEIGHT + PAD_Y = FOOTER_HEIGHT + PAD_Y ✓
    const body_bottom_margin = pane_gl_bottom + FOOTER_HEIGHT + PAD_Y;
    // body_h = window_height - body_top - body_bottom_margin
    // Dock check: window_height - (titlebar_h+HEADER_HEIGHT+PAD_Y) - (FOOTER_HEIGHT+PAD_Y) ✓
    const body_h = window_height - body_top - body_bottom_margin;
    if (body_h <= 0) return;

    if (pane.kind.isRaster()) {
        renderImageDocument(pane, panel_x, panel_w, window_height, body_top, body_h, normal, muted, border);
        return;
    }
    if (markdown_preview.delimiterForKind(pane.kind)) |delimiter| {
        renderDelimitedDocument(pane, panel_x, panel_w, window_height, body_top, body_h, delimiter, normal, muted, strong, accent, code_bg, border);
        return;
    }

    const row_h = @max(22, font.g_titlebar_cell_height + LINE_GAP);
    const body_origin = body_top - pane.scroll_offset;
    var y_from_top: f32 = body_origin;
    const max_w = panel_w - PAD_X * 2;

    var in_code = false;
    var rendered: usize = 0;
    var lines = std.mem.splitScalar(u8, pane.sourceText(), '\n');
    while (lines.next()) |raw_line| {
        if (rendered >= MAX_RENDER_LINES) break;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        // renderMarkdownLine measures every line but only draws the on-screen
        // slice, so we keep walking past the viewport bottom to accumulate the
        // full content height (needed to clamp scroll) without extra draw cost.
        const consumed = renderMarkdownLine(
            pane,
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
    }
    // Clamp scroll to the laid-out height so the pane can't scroll past its last
    // rendered line into blank space (large heads now stop cleanly at the end).
    pane.max_scroll = @max(0, (y_from_top - body_origin) - body_h);
    _ = panel_h;
}

/// Number of non-blank lines — the count of rows the delimited renderer actually
/// draws (it skips blank/whitespace-only lines), used to size the scroll height.
fn countNonBlankLines(source: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) n += 1;
    }
    return n;
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
    pane: *PreviewPane,
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

    switch (pane.load_status) {
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

    const source = pane.sourceText();
    const layout = blk: {
        const perf = ui_perf.begin("markdown_preview_renderer.table_layout");
        defer perf.end();
        break :blk computeTableLayout(source, delimiter, content_w);
    };
    if (layout.col_count == 0) {
        renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Empty table", muted);
        return;
    }

    const row_h = @max(26, font.g_titlebar_cell_height + 10);
    if (body_h <= row_h) return;

    // Rows are fixed-height, so clamp scroll to (visible rows × row_h) - body_h,
    // stopping exactly at the last row. Count NON-BLANK lines (the render loop
    // skips blank/empty lines), capped at the render budget (header + data rows).
    const shown_rows = @min(countNonBlankLines(source), MAX_RENDER_LINES + 1);
    pane.max_scroll = @max(0, @as(f32, @floatFromInt(shown_rows)) * row_h - body_h);

    var saw_header = false;
    var data_row_idx: usize = 0;
    var rendered_rows: usize = 0;
    var hovered_cell: ?HoveredTableCell = null;

    {
        const perf = ui_perf.begin("markdown_preview_renderer.table_rows");
        defer perf.end();

        var buffers: [markdown_preview.MAX_TABLE_COLS][markdown_preview.MAX_TABLE_CELL_BYTES]u8 = undefined;
        var lines = std.mem.splitScalar(u8, source, '\n');
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

            const row_top = body_top + row_h + @as(f32, @floatFromInt(data_row_idx)) * row_h - pane.scroll_offset;
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
    ui_pipeline.fillQuad(popup_x - 1, popup_y - 1, popup_w + 2, popup_h + 2, border);
    ui_pipeline.fillQuad(popup_x, popup_y, popup_w, popup_h, popup_bg);
    ui_pipeline.fillQuad(popup_x, popup_y + popup_h - 2, popup_w, 2, strong);

    for (0..line_count) |idx| {
        const line_top = popup_top + 8 + @as(f32, @floatFromInt(idx)) * row_h;
        const text_y = window_height - line_top - row_h + (row_h - font.g_titlebar_cell_height) / 2;
        _ = titlebar.renderTextLimited(text[ranges[idx].start..ranges[idx].end], popup_x + 12, text_y, normal, inner_w);
    }
}

fn renderImageDocument(
    pane: *PreviewPane,
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

    switch (pane.load_status) {
        .loading => {
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Loading preview...", muted);
            return;
        },
        .failed => {
            // PDF failures carry a specific message in the pane source
            // (tool missing, encrypted, invalid document).
            const msg = if (pane.kind == .pdf and pane.sourceText().len > 0) pane.sourceText() else "Image preview failed";
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, msg, normal);
            return;
        },
        .too_large => {
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Preview too large", normal);
            return;
        },
        .idle => return,
        .ready => {},
    }

    if (!ensureImageTexture(pane)) {
        renderStatusMessage(content_x, content_w, window_height, body_top, body_h, "Image preview failed", normal);
        return;
    }

    const image_size = preview_image_layout.Size{
        .width = @floatFromInt(pane.image_width),
        .height = @floatFromInt(pane.image_height),
    };
    const view_size = preview_image_layout.Size{ .width = content_w, .height = body_h };
    const draw_size = preview_image_layout.drawSize(image_size, view_size, pane.imageZoom()) orelse return;
    pane.clampImagePan(content_w, body_h, draw_size.width, draw_size.height);

    const layout = preview_image_layout.compute(.{
        .content_x = content_x,
        .content_width = content_w,
        .body_top = body_top,
        .body_height = body_h,
        .window_height = window_height,
        .image = image_size,
        .zoom = pane.imageZoom(),
        .pan = .{ .x = pane.imagePanX(), .y = pane.imagePanY() },
    }) orelse return;

    // Clip the image to the body area, restoring any outer scissor afterward.
    const saved_scissor = gpu.state.scissorState();
    gpu.state.setScissor(.{ .x = layout.scissor.x, .y = layout.scissor.y, .w = layout.scissor.w, .h = layout.scissor.h });
    ui_pipeline.fillQuad(layout.border.x, layout.border.y, layout.border.w, layout.border.h, border);
    drawImageTexture(pane, layout.vertices);
    gpu.state.restoreScissor(saved_scissor);
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

fn ensureImageTexture(pane: *PreviewPane) bool {
    const generation = pane.contentGeneration();
    if (pane.image_generation == generation) return pane.image_texture.isValid() and !pane.image_failed;

    pane.unloadImageTexture();
    pane.image_generation = generation;
    pane.image_failed = true;

    const source = pane.sourceText();
    if (source.len == 0 or source.len > std.math.maxInt(c_int)) {
        var bytes_buf: [32]u8 = undefined;
        const bytes_s = std.fmt.bufPrint(&bytes_buf, "{d}", .{source.len}) catch "";
        preview_diagnostics.debug("image-decode", &.{
            .{ .key = "stage", .value = "invalid-source-size" },
            .{ .key = "kind", .value = @tagName(pane.kind) },
            .{ .key = "path", .value = pane.path() },
            .{ .key = "bytes", .value = bytes_s },
        });
        return false;
    }

    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const data = c.stbi_load_from_memory(@ptrCast(source.ptr), @intCast(source.len), &w, &h, &n, 4);
    if (data == null or w <= 0 or h <= 0) {
        var bytes_buf: [32]u8 = undefined;
        const bytes_s = std.fmt.bufPrint(&bytes_buf, "{d}", .{source.len}) catch "";
        preview_diagnostics.debug("image-decode", &.{
            .{ .key = "stage", .value = "decode-failed" },
            .{ .key = "kind", .value = @tagName(pane.kind) },
            .{ .key = "path", .value = pane.path() },
            .{ .key = "bytes", .value = bytes_s },
        });
        return false;
    }
    defer c.stbi_image_free(data);

    const t = gpu.Texture.create();
    pane.image_texture = t;
    if (!pane.image_texture.isValid()) return false;

    pane.image_texture.upload2D(w, h, @ptrCast(data), .{ .unpack_alignment = 1 });

    pane.image_width = w;
    pane.image_height = h;
    pane.image_failed = false;
    var width_buf: [32]u8 = undefined;
    var height_buf: [32]u8 = undefined;
    var bytes_buf: [32]u8 = undefined;
    const width_s = std.fmt.bufPrint(&width_buf, "{d}", .{w}) catch "";
    const height_s = std.fmt.bufPrint(&height_buf, "{d}", .{h}) catch "";
    const bytes_s = std.fmt.bufPrint(&bytes_buf, "{d}", .{source.len}) catch "";
    preview_diagnostics.debug("image-decode", &.{
        .{ .key = "stage", .value = "ready" },
        .{ .key = "kind", .value = @tagName(pane.kind) },
        .{ .key = "path", .value = pane.path() },
        .{ .key = "bytes", .value = bytes_s },
        .{ .key = "width", .value = width_s },
        .{ .key = "height", .value = height_s },
    });
    return true;
}

fn drawImageTexture(pane: *PreviewPane, vertices: preview_image_layout.Vertices) void {
    if (!pane.image_texture.isValid() or ui_pipeline.emoji.program == 0) return;

    ui_pipeline.drawTextureQuad(vertices, pane.image_texture, 1.0);
}

fn renderMarkdownLine(
    pane: *PreviewPane,
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
            ui_pipeline.fillQuad(x, gl_y, max_w, 1, border);
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

    if (pane.kind == .text) {
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
            ui_pipeline.fillQuad(x, gl_y, max_w, 1, muted);
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
            ui_pipeline.fillQuad(x, gl_y, max_w, 1, blend(AppWindow.g_theme.background, accent, 0.32));
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
    ui_pipeline.fillQuad(x, gl_y, w, bottom - top, color);
}

const wrapEnd = text_wrap.wrapEnd;
const skipSpaces = text_wrap.skipSpaces;

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

test "countNonBlankLines ignores blank and whitespace-only lines" {
    try std.testing.expectEqual(@as(usize, 3), countNonBlankLines("a,b\n\nc,d\n   \ne,f\n"));
    try std.testing.expectEqual(@as(usize, 1), countNonBlankLines("only"));
    try std.testing.expectEqual(@as(usize, 0), countNonBlankLines("\n  \n\t\n"));
}

test "truncatedBannerText scales the head size" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Large file: showing first 1.0 MB (scroll to read more)", truncatedBannerText(&buf, 1024 * 1024));
    try std.testing.expectEqualStrings("Large file: showing first 1.5 MB (scroll to read more)", truncatedBannerText(&buf, 1024 * 1024 * 3 / 2));
    try std.testing.expectEqualStrings("Large file: showing first 4 KB (scroll to read more)", truncatedBannerText(&buf, 4096));
    try std.testing.expectEqualStrings("Large file: showing first 200 bytes (scroll to read more)", truncatedBannerText(&buf, 200));
}
