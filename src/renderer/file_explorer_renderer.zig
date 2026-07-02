//! File explorer sidebar renderer.
//!
//! Renders the left-side file explorer panel through the backend-neutral UI
//! pipeline and the shared titlebar glyph atlas.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const titlebar = AppWindow.titlebar;
const ui_pipeline = @import("ui_pipeline.zig");
const layout_math = @import("file_explorer_layout.zig");
const font = AppWindow.font;
const file_explorer = @import("../file_explorer.zig");
const hit_test = @import("../input/hit_test.zig");

fn blend(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

const Palette = struct {
    bg: [3]f32,
    fg: [3]f32,
    border_color: [3]f32,
    header_text: [3]f32,
    text_normal: [3]f32,
    text_dir: [3]f32,
    text_muted: [3]f32,
    hover_bg: [3]f32,
    selected_bg: [3]f32,
    accent: [3]f32,
};

const HeaderCloseRect = struct {
    x: f32,
    w: f32,
};

fn headerCloseRect(panel_x: f32, panel_w: f32) HeaderCloseRect {
    const rect = hit_test.panelCloseButtonRect(.{
        .visible = true,
        .left = panel_x,
        .right = panel_x + panel_w,
        .top = 0,
        .height = 1,
    }) orelse return .{ .x = panel_x + panel_w, .w = 0 };
    return .{ .x = @floatCast(rect.left), .w = @floatCast(rect.width) };
}

fn headerRefreshRect(panel_x: f32, panel_w: f32) HeaderCloseRect {
    const rect = hit_test.panelSecondButtonRect(.{
        .visible = true,
        .left = panel_x,
        .right = panel_x + panel_w,
        .top = 0,
        .height = 1,
    }) orelse return .{ .x = panel_x + panel_w, .w = 0 };
    return .{ .x = @floatCast(rect.left), .w = @floatCast(rect.width) };
}

fn renderHeaderCloseButton(
    titlebar_h: f32,
    header_y: f32,
    header_h: f32,
    panel_x: f32,
    panel_w: f32,
    palette: Palette,
) void {
    const close = headerCloseRect(panel_x, panel_w);
    const hovered = blk: {
        const win = AppWindow.g_window orelse break :blk false;
        if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
        break :blk hit_test.panelHeaderCloseButton(.{
            .visible = true,
            .left = panel_x,
            .right = panel_x + panel_w,
            .top = titlebar_h,
            .height = header_h,
        }, @floatFromInt(win.mouse_x), @floatFromInt(win.mouse_y));
    };
    if (hovered) {
        ui_pipeline.fillQuad(close.x + 6, header_y + @round((header_h - 20) / 2), 20, 20, blend(palette.bg, palette.fg, 0.14));
    }
    titlebar.renderCloseIcon(close.x, header_y, close.w, header_h, if (hovered) palette.fg else palette.text_muted);
}

fn renderHeaderRefreshButton(
    titlebar_h: f32,
    header_y: f32,
    header_h: f32,
    panel_x: f32,
    panel_w: f32,
    palette: Palette,
) void {
    const r = headerRefreshRect(panel_x, panel_w);
    if (r.w <= 0) return;
    const hovered = blk: {
        const win = AppWindow.g_window orelse break :blk false;
        if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
        break :blk hit_test.panelHeaderSecondButton(.{
            .visible = true,
            .left = panel_x,
            .right = panel_x + panel_w,
            .top = titlebar_h,
            .height = header_h,
        }, @floatFromInt(win.mouse_x), @floatFromInt(win.mouse_y));
    };
    if (hovered) {
        ui_pipeline.fillQuad(r.x + 6, header_y + @round((header_h - 20) / 2), 20, 20, blend(palette.bg, palette.fg, 0.14));
    }
    const glyph = if (hovered) palette.fg else palette.text_muted;
    const cx = r.x + r.w / 2;
    const cy = header_y + header_h / 2;
    // Simple "refresh" glyph: an open square-arc drawn from 4 thin quads.
    ui_pipeline.fillQuad(cx - 5, cy - 6, 8, 1.5, glyph);
    ui_pipeline.fillQuad(cx + 3, cy - 6, 1.5, 6, glyph);
    ui_pipeline.fillQuad(cx - 5, cy + 4.5, 8, 1.5, glyph);
    ui_pipeline.fillQuad(cx - 6.5, cy - 1, 1.5, 6, glyph);
}

pub fn render(window_width: f32, window_height: f32, titlebar_h: f32) void {
    if (!file_explorer.isVisibleForActiveTab()) return;
    file_explorer.syncLayoutMetrics(font.g_titlebar_cell_height);
    file_explorer.syncViewportMetrics(window_height, titlebar_h);
    const header_h = file_explorer.headerHeight();
    const row_h = file_explorer.rowHeight();
    const explorer_w = file_explorer.width();
    if (explorer_w <= 0) return;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const sidebar_bg = blend(bg, fg, 0.035);
    const border_color = blend(bg, .{ 0.0, 0.0, 0.0 }, 0.20);
    const header_text = blend(bg, fg, 0.84);
    const text_normal = blend(bg, fg, 0.88);
    const text_dir = AppWindow.g_theme.foreground;
    const text_muted = blend(bg, fg, 0.60);
    const hover_bg = blend(bg, fg, 0.09);
    const selected_bg = blend(bg, AppWindow.g_theme.cursor_color, 0.16);
    const accent = AppWindow.g_theme.cursor_color;
    const palette: Palette = .{
        .bg = bg,
        .fg = fg,
        .border_color = border_color,
        .header_text = header_text,
        .text_normal = text_normal,
        .text_dir = text_dir,
        .text_muted = text_muted,
        .hover_bg = hover_bg,
        .selected_bg = selected_bg,
        .accent = accent,
    };

    _ = window_width;
    const layout = layout_math.compute(.{
        .window_height = window_height,
        .titlebar_height = titlebar_h,
        .sidebar_width = titlebar.sidebarWidth(),
        .explorer_width = explorer_w,
        .header_height = header_h,
        .row_height = row_h,
        .text_height = font.g_titlebar_cell_height,
    });
    if (layout.side_height <= 0) return;

    // Background
    ui_pipeline.fillQuad(layout.panel_x, 0, layout.explorer_width, layout.side_height, sidebar_bg);

    // Right border (resize edge between explorer and terminal content)
    const resize_hovered = blk: {
        const win = AppWindow.g_window orelse break :blk false;
        if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
        const mx: f32 = @floatFromInt(win.mouse_x);
        const my: f32 = @floatFromInt(win.mouse_y);
        const half_hit = file_explorer.RESIZE_HIT_WIDTH / 2;
        break :blk mx >= layout.panel_right - half_hit and mx <= layout.panel_right + half_hit and my >= titlebar_h and my < window_height;
    };
    const edge_color = if (resize_hovered) blend(bg, accent, 0.38) else border_color;
    ui_pipeline.fillQuad(layout.panel_right - 1, 0, if (resize_hovered) 2 else 1, layout.side_height, edge_color);

    switch (file_explorer.g_panel_mode) {
        .files => renderFiles(layout, palette),
        .agent_history => renderAgentHistory(layout, palette),
    }
}

fn renderFiles(
    layout: layout_math.Layout,
    palette: Palette,
) void {
    const bg = palette.bg;
    const fg = palette.fg;
    const border_color = palette.border_color;
    const header_text = palette.header_text;
    const text_normal = palette.text_normal;
    const text_dir = palette.text_dir;
    const hover_bg = palette.hover_bg;
    const selected_bg = palette.selected_bg;
    const accent = palette.accent;

    // Header with mode indicator
    const mode_label = switch (file_explorer.g_mode) {
        .remote => "REMOTE",
        .wsl => "WSL",
        .local => "LOCAL",
    };
    const mode_color = if (file_explorer.g_mode == .local) header_text else accent;
    const close = headerCloseRect(layout.panel_x, layout.explorer_width);
    const refresh_rect = headerRefreshRect(layout.panel_x, layout.explorer_width);
    const text_limit_x = if (refresh_rect.w > 0) refresh_rect.x else close.x;
    const label_end = titlebar.renderTextLimited(mode_label, layout.panel_x + 12, layout.header_text_y, mode_color, @max(1.0, text_limit_x - layout.panel_x - 20));
    _ = titlebar.renderTextLimited(" Explorer", label_end, layout.header_text_y, header_text, @max(1.0, text_limit_x - label_end - 8));
    renderHeaderRefreshButton(layout.titlebar_height, layout.header_y, layout.header_height, layout.panel_x, layout.explorer_width, palette);
    renderHeaderCloseButton(layout.titlebar_height, layout.header_y, layout.header_height, layout.panel_x, layout.explorer_width, palette);
    ui_pipeline.fillQuad(layout.panel_x, layout.header_y, layout.explorer_width, 1, border_color);

    // File entries
    const scroll = file_explorer.g_scroll_offset;

    var i: usize = 0;
    while (i < file_explorer.g_entry_count) : (i += 1) {
        const row = switch (layout.row(i, scroll)) {
            .before => continue,
            .after => break,
            .visible => |row| row,
        };

        const entry = &file_explorer.g_entries[i];
        const indent = @as(f32, @floatFromInt(entry.depth)) * file_explorer.INDENT_WIDTH;

        // Hover detection
        const row_hovered = blk: {
            const win = AppWindow.g_window orelse break :blk false;
            if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
            const mx: f32 = @floatFromInt(win.mouse_x);
            const my: f32 = @floatFromInt(win.mouse_y);
            break :blk mx >= layout.panel_x and mx < layout.panel_x + layout.explorer_width and my >= row.top_px and my < row.top_px + layout.row_height;
        };

        const is_selected = if (file_explorer.g_selected) |sel| sel == i else false;

        if (is_selected) {
            ui_pipeline.fillQuad(layout.panel_x, row.y, layout.explorer_width, layout.row_height, selected_bg);
        } else if (row_hovered) {
            ui_pipeline.fillQuad(layout.panel_x, row.y, layout.explorer_width, layout.row_height, hover_bg);
        }

        // Expand/collapse indicator for directories
        const text_x = layout.panel_x + 8 + indent;
        const text_y = layout.textY(row.y);

        // When renaming this entry, show input buffer instead of name
        const is_renaming = is_selected and file_explorer.g_op_mode == .rename;

        if (entry.is_dir) {
            const arrow: u32 = if (entry.expanded) 0x25BE else 0x25B8; // ▾ or ▸
            titlebar.renderTitlebarChar(arrow, text_x, text_y, text_dir);
            if (is_renaming) {
                renderInputField(text_x + 14, text_y, layout.explorer_width - indent - 34, fg, accent);
            } else {
                _ = titlebar.renderTextLimited(
                    entry.name_buf[0..entry.name_len],
                    text_x + 14,
                    text_y,
                    text_dir,
                    layout.explorer_width - indent - 34,
                );
            }
        } else {
            if (is_renaming) {
                renderInputField(text_x + 14, text_y, layout.explorer_width - indent - 34, fg, accent);
            } else {
                _ = titlebar.renderTextLimited(
                    entry.name_buf[0..entry.name_len],
                    text_x + 14,
                    text_y,
                    text_normal,
                    layout.explorer_width - indent - 34,
                );
            }
        }
    }

    if (file_explorer.g_loading and file_explorer.g_entry_count == 0) {
        const row_y = layout.window_height - layout.list_top_px - layout.row_height;
        const ty = layout.textY(row_y);
        const prefix_end = titlebar.renderTextLimited("Loading: ", layout.panel_x + 8, ty, accent, layout.explorer_width - 16);
        _ = titlebar.renderTextLimited(file_explorer.g_loading_msg[0..file_explorer.g_loading_msg_len], prefix_end, ty, text_normal, layout.explorer_width - (prefix_end - layout.panel_x) - 8);
    }

    // Render new file/dir input or delete confirmation at bottom of list
    if (file_explorer.g_op_mode == .new_file or file_explorer.g_op_mode == .new_dir) {
        if (layout.operationRow(file_explorer.g_entry_count, scroll)) |new_row| {
            ui_pipeline.fillQuad(layout.panel_x, new_row.y, layout.explorer_width, layout.row_height, selected_bg);
            const label = if (file_explorer.g_op_mode == .new_dir) "New folder: " else "New file: ";
            const input_y = layout.textY(new_row.y);
            const op_label_end = titlebar.renderTextLimited(label, layout.panel_x + 8, input_y, header_text, layout.explorer_width - 16);
            renderInputField(op_label_end + 2, input_y, layout.explorer_width - (op_label_end - layout.panel_x) - 10, fg, accent);
        }
    } else if (file_explorer.g_op_mode == .confirm_delete) {
        if (layout.operationRow(file_explorer.g_entry_count, scroll)) |del_row| {
            const warn_bg = blend(bg, .{ 0.8, 0.2, 0.2 }, 0.2);
            ui_pipeline.fillQuad(layout.panel_x, del_row.y, layout.explorer_width, layout.row_height, warn_bg);
            _ = titlebar.renderTextLimited("Delete? Enter=yes Esc=no", layout.panel_x + 8, layout.textY(del_row.y), fg, layout.explorer_width - 16);
        }
    }

    // Loading status stays local to the panel; transfer status is shown by the
    // global bottom-right toast so terminal and File Explorer downloads match.
    if (file_explorer.g_loading) {
        const status_y: f32 = 0;
        ui_pipeline.fillQuad(layout.panel_x, status_y, layout.explorer_width, layout.status_height, blend(bg, accent, 0.15));
        const ty = status_y + (layout.status_height - layout.text_height) / 2;
        const prefix_end = titlebar.renderTextLimited("Loading: ", layout.panel_x + 8, ty, accent, layout.explorer_width - 16);
        _ = titlebar.renderTextLimited(file_explorer.g_loading_msg[0..file_explorer.g_loading_msg_len], prefix_end, ty, fg, layout.explorer_width - (prefix_end - layout.panel_x) - 8);
    }
}

fn renderAgentHistory(
    layout: layout_math.Layout,
    palette: Palette,
) void {
    const close = headerCloseRect(layout.panel_x, layout.explorer_width);
    const agent_end = titlebar.renderTextLimited("AGENT", layout.panel_x + 12, layout.header_text_y, palette.accent, @max(1.0, close.x - layout.panel_x - 20));
    _ = titlebar.renderTextLimited(" History", agent_end, layout.header_text_y, palette.header_text, @max(1.0, close.x - agent_end - 8));
    renderHeaderCloseButton(layout.titlebar_height, layout.header_y, layout.header_height, layout.panel_x, layout.explorer_width, palette);
    ui_pipeline.fillQuad(layout.panel_x, layout.header_y, layout.explorer_width, 1, palette.border_color);

    const scroll = file_explorer.g_history_scroll_offset;
    const two_line = layout.row_height >= font.g_titlebar_cell_height * 2 + 6;

    var row_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < file_explorer.g_history_row_count) : (i += 1) {
        const row_pos = switch (layout.row(i, scroll)) {
            .before => continue,
            .after => break,
            .visible => |row| row,
        };
        const row = &file_explorer.g_history_rows[i];

        const row_hovered = blk: {
            const win = AppWindow.g_window orelse break :blk false;
            if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
            const mx: f32 = @floatFromInt(win.mouse_x);
            const my: f32 = @floatFromInt(win.mouse_y);
            break :blk mx >= layout.panel_x and mx < layout.panel_x + layout.explorer_width and my >= row_pos.top_px and my < row_pos.top_px + layout.row_height;
        };

        const is_selected = if (file_explorer.g_history_selected) |selected| selected == i else false;
        if (is_selected) {
            ui_pipeline.fillQuad(layout.panel_x, row_pos.y, layout.explorer_width, layout.row_height, palette.selected_bg);
        } else if (row_hovered) {
            ui_pipeline.fillQuad(layout.panel_x, row_pos.y, layout.explorer_width, layout.row_height, palette.hover_bg);
        }

        const title = historyRowTitle(i, row);
        const text_x = layout.panel_x + 12;
        if (two_line) {
            const vertical_padding = @max(2.0, @floor((layout.row_height - (font.g_titlebar_cell_height * 2 + 2)) / 2));
            const secondary_y = row_pos.y + vertical_padding;
            const primary_y = secondary_y + font.g_titlebar_cell_height + 2;
            _ = titlebar.renderTextLimited(title, text_x, primary_y, palette.text_normal, layout.explorer_width - 24);
            _ = titlebar.renderTextLimited(historyRowSubtitle(row, &row_buf), text_x, secondary_y, palette.text_muted, layout.explorer_width - 24);
        } else {
            const text_y = layout.textY(row_pos.y);
            _ = titlebar.renderTextLimited(title, text_x, text_y, palette.text_normal, layout.explorer_width - 24);
        }
    }
}

fn historyRowTitle(idx: usize, row: *const file_explorer.HistoryRow) []const u8 {
    if (row.title_len > 0) return row.title_buf[0..row.title_len];
    return file_explorer.historySessionIdAt(idx) orelse "Untitled chat";
}

fn historyRowSubtitle(row: *const file_explorer.HistoryRow, buf: *[32]u8) []const u8 {
    if (row.model_len > 0) return row.model_buf[0..row.model_len];
    return formatRelativeTimestamp(row.updated_at, buf);
}

fn formatRelativeTimestamp(updated_at: i64, buf: *[32]u8) []const u8 {
    const delta_ms = @max(@as(i64, 0), std.time.milliTimestamp() - updated_at);
    const delta_s = @divTrunc(delta_ms, 1000);
    if (delta_s < 60) return "just now";
    if (delta_s < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(delta_s, 60)}) catch "recent";
    if (delta_s < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(delta_s, 3600)}) catch "recent";
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(delta_s, 86400)}) catch "recent";
}

fn renderInputField(x: f32, y: f32, max_w: f32, text_color: [3]f32, cursor_color: [3]f32) void {
    const text = file_explorer.g_input_buf[0..file_explorer.g_input_len];
    const text_end = titlebar.renderTextLimited(text, x, y, text_color, max_w);
    // Blinking cursor
    const now = std.time.milliTimestamp();
    if (@mod(@divTrunc(now, 530), 2) == 0) {
        const font_mod = @import("../font/manager.zig");
        ui_pipeline.fillQuad(text_end + 1, y, 1, font_mod.g_titlebar_cell_height, cursor_color);
    }
}
