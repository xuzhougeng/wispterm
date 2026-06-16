//! Startup keyboard shortcuts overlay.

const std = @import("std");
const builtin = @import("builtin");
const AppWindow = @import("../../AppWindow.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const gl_init = AppWindow.gpu.gl_init;
const keybind = @import("../../keybind.zig");
const i18n = @import("../../i18n.zig");
const primitives = @import("primitives.zig");
const mixColor = primitives.mixColor;
const renderRoundedQuadAlpha = primitives.renderRoundedQuadAlpha;

const c = AppWindow.gpu.c;

pub const STARTUP_SHORTCUTS_DURATION_MS: i64 = 12000;
pub const STARTUP_SHORTCUTS_FADE_MS: i64 = 800;

const StartupShortcutKind = enum {
    literal,
    action,
    pair,
    quad,
};

const StartupShortcut = struct {
    keys: []const u8,
    // macOS-specific literal text (Cmd instead of Ctrl). Only used for `.literal`
    // entries whose keys were migrated to Cmd; `.action`-family entries derive
    // their text from the live keybind via formatTrigger and ignore this.
    keys_macos: ?[]const u8 = null,
    kind: StartupShortcutKind = .literal,
    first: ?keybind.Action = null,
    second: ?keybind.Action = null,
    third: ?keybind.Action = null,
    fourth: ?keybind.Action = null,
    separator: []const u8 = " / ",
    action: []const u8,
    /// Simplified-Chinese variant of `action`, shown when the UI language is zh-CN
    /// (mirrors the `keys_macos` variant-field pattern). English `action` is the source.
    action_zh: ?[]const u8 = null,
};

/// The action label in the active UI language (English source, zh override).
fn localizedAction(entry: StartupShortcut) []const u8 {
    if (i18n.lang() == .zh_CN) {
        if (entry.action_zh) |zh| return zh;
    }
    return entry.action;
}

const STARTUP_SHORTCUT_ENTRIES = [_]StartupShortcut{
    .{ .keys = "Ctrl+Backquote", .kind = .action, .first = .toggle_quake, .action = "Show / hide Quake window", .action_zh = "显示 / 隐藏 Quake 窗口" },
    .{ .keys = "Ctrl+Shift+P", .kind = .action, .first = .toggle_command_palette, .action = "Command center", .action_zh = "命令中心" },
    .{ .keys = "Ctrl+Shift+T", .kind = .action, .first = .new_session, .action = "New session", .action_zh = "新建会话" },
    .{ .keys = "Ctrl+Shift+B", .kind = .action, .first = .toggle_sidebar, .action = "Toggle sidebar", .action_zh = "切换侧边栏" },
    .{ .keys = "Ctrl+Shift+A", .kind = .action, .first = .toggle_ai_copilot, .action = "Toggle Copilot", .action_zh = "开 / 关 Copilot" },
    .{ .keys = "Ctrl+Shift++ / Ctrl+Shift+-", .kind = .pair, .first = .split_right, .second = .split_down, .action = "Split right / down", .action_zh = "向右 / 向下分屏" },
    .{ .keys = "Ctrl+Shift+Alt+E", .kind = .action, .first = .toggle_file_explorer, .action = "File explorer", .action_zh = "文件浏览器" },
    .{ .keys = "Ctrl/double-click file", .keys_macos = "Cmd/double-click file", .action = "Preview file", .action_zh = "预览文件" },
    .{ .keys = "Ctrl+Shift-click SSH file", .keys_macos = "Cmd+Shift-click SSH file", .action = "Download file", .action_zh = "下载文件" },
    .{ .keys = "Ctrl+Shift+[ / Ctrl+Shift+]", .kind = .pair, .first = .focus_previous, .second = .focus_next, .action = "Previous / next panel", .action_zh = "上一个 / 下一个面板" },
    .{ .keys = "Ctrl+1..9", .kind = .pair, .first = .focus_panel_1, .second = .focus_panel_9, .action = "Focus panel 1–9 by number", .action_zh = "按编号聚焦面板 (1–9)" },
    .{ .keys = "Alt+Left / Alt+Right / Alt+Up / Alt+Down", .kind = .quad, .first = .focus_left, .second = .focus_right, .third = .focus_up, .fourth = .focus_down, .action = "Focus panel", .action_zh = "聚焦面板" },
    .{ .keys = "Ctrl+Shift+Z", .kind = .action, .first = .equalize_splits, .action = "Equalize panels", .action_zh = "均分面板" },
    .{ .keys = "Ctrl+Shift+W", .kind = .action, .first = .close_panel_or_tab, .action = "Close panel / tab; confirm last", .action_zh = "关闭面板 / 标签页；最后一个需确认" },
    .{ .keys = "Ctrl+Shift+C / Ctrl+V", .kind = .pair, .first = .copy, .second = .paste, .action = "Copy / paste text", .action_zh = "复制 / 粘贴文本" },
    .{ .keys = "Shift-click text", .action = "Select from anchor", .action_zh = "从锚点开始选择" },
    .{ .keys = "Drag in AI / Ctrl+C", .keys_macos = "Drag in AI / Cmd+C", .action = "Copy answer selection", .action_zh = "复制回答选区" },
    .{ .keys = "Shift-drag in AI", .action = "Copy answer selection", .action_zh = "复制回答选区" },
    .{ .keys = "Ctrl+A / Ctrl+C in AI", .keys_macos = "Cmd+A / Cmd+C in AI", .action = "Select / copy chat", .action_zh = "选择 / 复制对话" },
    .{ .keys = "Right-click selection", .action = "Copy selection", .action_zh = "复制选区" },
    .{ .keys = "Ctrl+Shift+V", .kind = .action, .first = .paste_image, .action = "Paste image", .action_zh = "粘贴图片" },
    .{ .keys = "Ctrl+,", .kind = .action, .first = .open_config, .action = "Open config", .action_zh = "打开配置" },
    .{ .keys = "Ctrl++ / Ctrl+-", .kind = .pair, .first = .font_size_increase, .second = .font_size_decrease, .action = "Font size", .action_zh = "字号" },
    .{ .keys = "Alt+Enter", .kind = .action, .first = .toggle_maximize, .action = "Maximize / restore", .action_zh = "最大化 / 还原" },
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
    var view = std.unicode.Utf8View.init(text) catch {
        for (text) |ch| text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
        return text_width;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        text_width += titlebar.titlebarGlyphAdvance(cp);
    }
    return text_width;
}

fn renderTitlebarText(text: []const u8, x_start: f32, y: f32, color: [3]f32) void {
    var x = @round(x_start);
    const y_aligned = @round(y);
    var view = std.unicode.Utf8View.init(text) catch {
        for (text) |ch| {
            titlebar.renderTitlebarChar(@intCast(ch), x, y_aligned, color);
            x += titlebar.titlebarGlyphAdvance(@intCast(ch));
        }
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        titlebar.renderTitlebarChar(cp, x, y_aligned, color);
        x += titlebar.titlebarGlyphAdvance(cp);
    }
}

fn renderTitlebarTextLimited(text: []const u8, x_start: f32, y: f32, color: [3]f32, max_w: f32) void {
    if (max_w <= 0) return;

    var x = @round(x_start);
    const y_aligned = @round(y);
    var view = std.unicode.Utf8View.init(text) catch {
        renderTitlebarText(text, x, y_aligned, color);
        return;
    };
    var it = view.iterator();
    var drew_any = false;
    while (it.nextCodepoint()) |cp| {
        const advance = titlebar.titlebarGlyphAdvance(cp);
        if (x + advance > x_start + max_w) {
            const ellipsis_w = titlebar.titlebarGlyphAdvance('.') * 3;
            if (drew_any and x + ellipsis_w <= x_start + max_w) {
                renderTitlebarText("...", x, y_aligned, color);
            }
            return;
        }
        titlebar.renderTitlebarChar(cp, x, y_aligned, color);
        x += advance;
        drew_any = true;
    }
}

fn writeActionShortcut(writer: anytype, action: keybind.Action) !bool {
    const binding = AppWindow.g_keybinds.firstForAction(action) orelse return false;
    var buf: [64]u8 = undefined;
    const text = try keybind.formatTrigger(binding.trigger, &buf);
    try writer.writeAll(text);
    return true;
}

fn startupShortcutKeys(entry: StartupShortcut, buf: []u8) []const u8 {
    if (entry.kind == .literal) {
        if (builtin.target.os.tag == .macos) {
            if (entry.keys_macos) |m| return m;
        }
        return entry.keys;
    }

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    const ok = switch (entry.kind) {
        .literal => true,
        .action => writeActionShortcut(writer, entry.first.?) catch false,
        .pair => blk: {
            if (!(writeActionShortcut(writer, entry.first.?) catch false)) break :blk false;
            writer.writeAll(entry.separator) catch break :blk false;
            if (!(writeActionShortcut(writer, entry.second.?) catch false)) break :blk false;
            break :blk true;
        },
        .quad => blk: {
            if (!(writeActionShortcut(writer, entry.first.?) catch false)) break :blk false;
            writer.writeAll(entry.separator) catch break :blk false;
            if (!(writeActionShortcut(writer, entry.second.?) catch false)) break :blk false;
            writer.writeAll(entry.separator) catch break :blk false;
            if (!(writeActionShortcut(writer, entry.third.?) catch false)) break :blk false;
            writer.writeAll(entry.separator) catch break :blk false;
            if (!(writeActionShortcut(writer, entry.fourth.?) catch false)) break :blk false;
            break :blk true;
        },
    };
    return if (ok) stream.getWritten() else i18n.s().shortcuts_unbound;
}

/// Render a centered startup overlay listing common keyboard shortcuts.
pub fn renderStartupShortcutsOverlay(window_width: f32, window_height: f32, top_offset: f32) void {
    const alpha = startupShortcutsOpacity();
    if (alpha <= 0.01) return;

    var max_keys_width: f32 = 0;
    var max_action_width: f32 = 0;
    for (STARTUP_SHORTCUT_ENTRIES) |entry| {
        var keys_buf: [256]u8 = undefined;
        const keys = startupShortcutKeys(entry, &keys_buf);
        max_keys_width = @max(max_keys_width, measureTitlebarText(keys));
        max_action_width = @max(max_action_width, measureTitlebarText(localizedAction(entry)));
    }

    const pad_x: f32 = 24;
    const pad_y: f32 = 18;
    const pair_gap_base: f32 = 48;
    const column_gap: f32 = 38;
    const line_height = overlayLineHeight();
    const heading_gap: f32 = 16;
    const hint_gap: f32 = 12;
    const hint = i18n.s().shortcuts_hint;
    const heading = i18n.s().shortcuts_heading;
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
        var keys_buf: [256]u8 = undefined;
        const keys = startupShortcutKeys(entry, &keys_buf);
        const col = idx / rows_per_column;
        const row = idx % rows_per_column;
        const col_x = @round(box_x + pad_x + @as(f32, @floatFromInt(col)) * (column_w + column_gap));
        const action_x = @round(col_x + keys_w + pair_gap);
        const y = @round(heading_y - heading_gap - line_height - @as(f32, @floatFromInt(row)) * line_height);
        renderTitlebarTextLimited(keys, col_x, y, keys_color, keys_w);
        renderTitlebarTextLimited(localizedAction(entry), action_x, y, action_color, action_w);
    }

    const hint_w = measureTitlebarText(hint);
    renderTitlebarTextLimited(hint, box_x + (box_width - @min(hint_w, box_width - pad_x * 2)) / 2, box_y + pad_y, hint_color, box_width - pad_x * 2);
}
