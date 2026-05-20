//! Startup keyboard shortcuts overlay.

const std = @import("std");
const AppWindow = @import("../../AppWindow.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const primitives = @import("primitives.zig");
const mixColor = primitives.mixColor;
const renderRoundedQuadAlpha = primitives.renderRoundedQuadAlpha;

const c = @cImport({
    @cInclude("glad/gl.h");
});

pub const STARTUP_SHORTCUTS_DURATION_MS: i64 = 12000;
pub const STARTUP_SHORTCUTS_FADE_MS: i64 = 800;

const StartupShortcut = struct {
    keys: []const u8,
    action: []const u8,
};

const STARTUP_SHORTCUT_ENTRIES = [_]StartupShortcut{
    .{ .keys = "Ctrl+Shift+P", .action = "Command center" },
    .{ .keys = "Ctrl+Shift+T", .action = "New session" },
    .{ .keys = "Ctrl+Shift+B", .action = "Toggle sidebar" },
    .{ .keys = "Ctrl+Shift+O", .action = "Split right" },
    .{ .keys = "Ctrl+Shift+Alt+E", .action = "File explorer" },
    .{ .keys = "Ctrl/double-click text", .action = "Preview file" },
    .{ .keys = "Ctrl+Shift+[ / ]", .action = "Previous / next panel" },
    .{ .keys = "Alt+Arrows", .action = "Focus panel" },
    .{ .keys = "Ctrl+Shift+Z", .action = "Equalize panels" },
    .{ .keys = "Ctrl+Shift+W", .action = "Close panel / tab; confirm last" },
    .{ .keys = "Ctrl+Shift+C / Ctrl+V", .action = "Copy / paste text" },
    .{ .keys = "Shift-click text", .action = "Select from anchor" },
    .{ .keys = "Ctrl+A / Ctrl+C in AI", .action = "Select / copy chat" },
    .{ .keys = "Right-click selection", .action = "Copy selection" },
    .{ .keys = "Ctrl+Shift+V", .action = "Paste image" },
    .{ .keys = "Ctrl+,", .action = "Open config" },
    .{ .keys = "Ctrl++ / Ctrl+-", .action = "Font size" },
    .{ .keys = "Alt+Enter", .action = "Maximize / restore" },
};

pub threadlocal var g_startup_shortcuts_visible: bool = false;
threadlocal var g_startup_shortcuts_started_at: i64 = 0;

pub fn startupShortcutsShow() void {
    g_startup_shortcuts_visible = true;
    g_startup_shortcuts_started_at = std.time.milliTimestamp();
}

pub fn startupShortcutsDismiss() void {
    g_startup_shortcuts_visible = false;
}

pub fn startupShortcutsToggle() void {
    g_startup_shortcuts_visible = !g_startup_shortcuts_visible;
    if (g_startup_shortcuts_visible) {
        g_startup_shortcuts_started_at = std.time.milliTimestamp();
    }
}

fn startupShortcutsOpacity() f32 {
    if (!g_startup_shortcuts_visible) return 0;
    return 1.0;
}

fn overlayTextHeight() f32 {
    return @max(1.0, font.g_titlebar_cell_height);
}

fn overlayLineHeight() f32 {
    return @round(@max(24.0, overlayTextHeight() + 8.0));
}

fn measureTitlebarText(text: []const u8) f32 {
    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
    return text_width;
}

fn renderTitlebarText(text: []const u8, x_start: f32, y: f32, color: [3]f32) void {
    var x = @round(x_start);
    const y_aligned = @round(y);
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y_aligned, color);
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
}

fn renderTitlebarTextLimited(text: []const u8, x_start: f32, y: f32, color: [3]f32, max_w: f32) void {
    if (max_w <= 0) return;

    var x = @round(x_start);
    const y_aligned = @round(y);
    for (text, 0..) |ch, idx| {
        const advance = titlebar.titlebarGlyphAdvance(@intCast(ch));
        if (x + advance > x_start + max_w) {
            const ellipsis_w = titlebar.titlebarGlyphAdvance('.') * 3;
            if (idx > 0 and x + ellipsis_w <= x_start + max_w) {
                renderTitlebarText("...", x, y_aligned, color);
            }
            return;
        }
        titlebar.renderTitlebarChar(@intCast(ch), x, y_aligned, color);
        x += advance;
    }
}

/// Render a centered startup overlay listing common keyboard shortcuts.
pub fn renderStartupShortcutsOverlay(window_width: f32, window_height: f32, top_offset: f32) void {
    const alpha = startupShortcutsOpacity();
    if (alpha <= 0.01) return;

    const gl = &AppWindow.gl;

    var max_keys_width: f32 = 0;
    var max_action_width: f32 = 0;
    for (STARTUP_SHORTCUT_ENTRIES) |entry| {
        max_keys_width = @max(max_keys_width, measureTitlebarText(entry.keys));
        max_action_width = @max(max_action_width, measureTitlebarText(entry.action));
    }

    const pad_x: f32 = 24;
    const pad_y: f32 = 18;
    const pair_gap_base: f32 = 48;
    const column_gap: f32 = 38;
    const line_height = overlayLineHeight();
    const heading_gap: f32 = 16;
    const hint_gap: f32 = 12;
    const hint = "Press any key or click to hide";
    const heading = "Keyboard shortcuts";
    const content_height = @max(1.0, window_height - top_offset);
    const available_height = @max(line_height, content_height - 24.0);
    const fixed_height = pad_y * 2 + overlayTextHeight() + heading_gap + hint_gap + overlayTextHeight();
    const available_entry_height = @max(line_height, available_height - fixed_height);
    const rows_fit: usize = @max(1, @as(usize, @intFromFloat(@floor(available_entry_height / line_height))));
    var columns: usize = (STARTUP_SHORTCUT_ENTRIES.len + rows_fit - 1) / rows_fit;
    columns = @min(@max(columns, 1), 3);
    const rows_per_column = (STARTUP_SHORTCUT_ENTRIES.len + columns - 1) / columns;
    const entries_height = line_height * @as(f32, @floatFromInt(rows_per_column));
    const pair_width = max_keys_width + pair_gap_base + max_action_width;
    const desired_box_width = @round(@max(
        measureTitlebarText(heading) + pad_x * 2,
        @max(measureTitlebarText(hint) + pad_x * 2, pair_width * @as(f32, @floatFromInt(columns)) + column_gap * @as(f32, @floatFromInt(columns - 1)) + pad_x * 2),
    ));
    const box_width = @round(@min(desired_box_width, @max(260.0, window_width - 24.0)));
    const box_height = @round(fixed_height + entries_height);

    const box_x = @round(@max(12, (window_width - box_width) / 2));
    const box_y = @round(@max(12, (content_height - box_height) / 2));

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const panel_color = mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, 0.035);
    const border_color = mixColor(AppWindow.g_theme.background, AppWindow.g_theme.cursor_color, 0.24);
    renderRoundedQuadAlpha(box_x - 1, box_y - 1, box_width + 2, box_height + 2, 11, border_color, alpha * 0.24);
    renderRoundedQuadAlpha(box_x, box_y, box_width, box_height, 10, panel_color, alpha * 0.94);

    const heading_base = mixColor(AppWindow.g_theme.foreground, AppWindow.g_theme.cursor_color, 0.18);
    const keys_base = mixColor(AppWindow.g_theme.foreground, AppWindow.g_theme.cursor_color, 0.08);
    const action_base = AppWindow.g_theme.foreground;
    const hint_base = mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, 0.58);
    const heading_color = mixColor(AppWindow.g_theme.background, heading_base, alpha);
    const keys_color = mixColor(AppWindow.g_theme.background, keys_base, alpha);
    const action_color = mixColor(AppWindow.g_theme.background, action_base, alpha);
    const hint_color = mixColor(AppWindow.g_theme.background, hint_base, alpha);

    const heading_w = measureTitlebarText(heading);
    const heading_y = @round(box_y + box_height - pad_y - overlayTextHeight());
    renderTitlebarText(heading, box_x + (box_width - heading_w) / 2, heading_y, heading_color);
    gl_init.renderQuadAlpha(box_x + pad_x, heading_y - heading_gap / 2 - 1, box_width - pad_x * 2, 1, border_color, alpha * 0.36);

    const inner_w = @max(1.0, box_width - pad_x * 2);
    const total_column_gap = column_gap * @as(f32, @floatFromInt(columns - 1));
    const column_w = @max(1.0, (inner_w - total_column_gap) / @as(f32, @floatFromInt(columns)));
    const pair_gap = @min(pair_gap_base, @max(18.0, column_w * 0.08));
    const keys_w = @min(max_keys_width, column_w * 0.48);
    const action_w = @max(1.0, column_w - keys_w - pair_gap);

    for (STARTUP_SHORTCUT_ENTRIES, 0..) |entry, idx| {
        const col = idx / rows_per_column;
        const row = idx % rows_per_column;
        const col_x = @round(box_x + pad_x + @as(f32, @floatFromInt(col)) * (column_w + column_gap));
        const action_x = @round(col_x + keys_w + pair_gap);
        const y = @round(heading_y - heading_gap - line_height - @as(f32, @floatFromInt(row)) * line_height);
        renderTitlebarTextLimited(entry.keys, col_x, y, keys_color, keys_w);
        renderTitlebarTextLimited(entry.action, action_x, y, action_color, action_w);
    }

    const hint_w = measureTitlebarText(hint);
    renderTitlebarTextLimited(hint, box_x + (box_width - @min(hint_w, box_width - pad_x * 2)) / 2, box_y + pad_y, hint_color, box_width - pad_x * 2);
}
