//! Feature-owned renderer for the Settings workbench.
//!
//! Integration code prepares a small view model; this module owns Settings
//! presentation and never reaches back into AppWindow or configuration I/O.

const std = @import("std");
const i18n = @import("../i18n.zig");
const settings_page = @import("overlays/settings_page.zig");
const settings_page_layout = @import("overlays/settings_page_layout.zig");
const ui_patterns = @import("ui_patterns.zig");

pub const DrawContext = struct {
    bg: [3]f32,
    fg: [3]f32,
    accent: [3]f32,
    cell_h: f32,
    fillQuadAlpha: *const fn (f32, f32, f32, f32, [3]f32, f32) void,
    roundedQuadAlpha: *const fn (f32, f32, f32, f32, f32, [3]f32, f32) void,
    renderTextLimited: *const fn ([]const u8, f32, f32, [3]f32, f32) f32,
    measureText: *const fn ([]const u8) f32,
};

pub const Row = struct {
    id: usize,
    value: []const u8,
};

pub const View = struct {
    state: *const settings_page.State,
    rows: []const Row,
    picker_current: []const u8 = "",
    default_shell_label: []const u8 = "",
};

pub fn render(draw: DrawContext, view: View, layout: settings_page_layout.Layout, window_height: f32) void {
    const state = view.state;
    const picker_open = state.pickerOpen();
    const page_y = @round(window_height - layout.page_top_px - layout.page_h);
    const border = mixColor(draw.bg, draw.fg, 0.16);
    const muted = mixColor(draw.bg, draw.fg, 0.58);

    draw.fillQuadAlpha(layout.page_x, page_y, layout.page_w, layout.page_h, mixColor(draw.bg, draw.fg, 0.012), 1.0);
    draw.fillQuadAlpha(layout.page_x, page_y, layout.nav_w, layout.page_h, mixColor(draw.bg, draw.fg, 0.025), 0.96);
    draw.fillQuadAlpha(layout.page_x + layout.nav_w - 1, page_y, 1, layout.page_h, border, 0.72);

    _ = draw.renderTextLimited(i18n.s().settings_title, layout.page_x + 24, textYFromTop(draw, window_height, layout.nav_title_top_px), mixColor(draw.fg, draw.accent, 0.10), layout.nav_w - 48);
    _ = draw.renderTextLimited(if (i18n.lang() == .zh_CN) "偏好设置" else "PREFERENCES", layout.page_x + 24, textYFromTop(draw, window_height, layout.nav_label_top_px), muted, layout.nav_w - 48);

    for (0..settings_page.categoryCount()) |idx| {
        const category = settings_page.categoryAt(idx) orelse continue;
        const item_top = layout.nav_item_top_px + layout.nav_item_h * @as(f32, @floatFromInt(idx));
        const item_y = @round(window_height - item_top - layout.nav_item_h);
        const selected = category == state.category;
        if (selected) draw.fillQuadAlpha(layout.page_x + 14, item_y + 10, 3, layout.nav_item_h - 20, draw.accent, 0.84);
        _ = draw.renderTextLimited(categoryLabel(category), layout.page_x + 28, rowTextY(draw, item_y, layout.nav_item_h), if (selected) mixColor(draw.fg, draw.accent, 0.16) else mixColor(draw.bg, draw.fg, 0.76), layout.nav_w - 48);
    }

    const page_title = if (state.pickerKind()) |kind| switch (kind) {
        .font_family => if (i18n.lang() == .zh_CN) "选择字体" else "Choose font family",
        .shell => if (i18n.lang() == .zh_CN) "选择默认 Shell" else "Choose default shell",
    } else categoryLabel(state.category);
    const subtitle = if (picker_open)
        (if (i18n.lang() == .zh_CN) "用方向键选择，按 Enter 应用，按 Esc 返回" else "Use arrows to choose, Enter to apply, Esc to go back")
    else
        categoryDescription(state.category);
    _ = draw.renderTextLimited(page_title, layout.content_x, textYFromTop(draw, window_height, layout.page_top_px + 28), mixColor(draw.fg, draw.accent, 0.10), layout.content_w);
    _ = draw.renderTextLimited(subtitle, layout.content_x, textYFromTop(draw, window_height, layout.page_top_px + 28 + lineHeight(draw)), muted, layout.content_w);
    draw.fillQuadAlpha(layout.content_x, @round(window_height - layout.row_top_px), layout.content_w, 1, border, 0.52);

    if (picker_open) {
        for (0..state.pickerCount()) |row_index| {
            const value = state.pickerValueAt(row_index) orelse continue;
            const label = if (state.pickerKind().? == .shell and value.len == 0) view.default_shell_label else value;
            renderPickerRow(draw, layout, window_height, row_index, label, state.picker.selected == row_index, std.ascii.eqlIgnoreCase(value, view.picker_current));
        }
    } else {
        for (view.rows, 0..) |row, row_index| {
            renderRow(draw, state.category, layout, window_height, row, row_index, state.focus == row.id);
        }
    }

    const item_count = if (picker_open) state.pickerCount() else view.rows.len;
    renderScrollbar(draw, layout, window_height, item_count);
    renderFooter(draw, layout, window_height, picker_open, muted, border);
}

fn renderRow(draw: DrawContext, category: settings_page.Category, layout: settings_page_layout.Layout, window_height: f32, row: Row, row_index: usize, selected: bool) void {
    const visible = layout.visibleRow(window_height, row_index) orelse return;
    const x = layout.content_x;
    const w = layout.content_w;
    const title_x = x + 20;
    const right_edge = x + w - 18;
    const title_y = textYFromTop(draw, window_height, visible.top_px + 10);
    const detail_y = textYFromTop(draw, window_height, visible.top_px + 10 + lineHeight(draw));
    var title_max_w = w - 40;

    if (selected) draw.fillQuadAlpha(x + 2, visible.gl_y + 8, 3, layout.row_h - 16, draw.accent, 0.82);
    if (row.value.len > 0) {
        const kind = controlKind(row.id);
        const max_value_w: f32 = switch (kind) {
            .toggle => 96,
            .adjuster => 152,
            .choice => 360,
            .action => 180,
        };
        const min_value_w: f32 = switch (kind) {
            .toggle => 76,
            .adjuster => 118,
            .choice => 132,
            .action => 96,
        };
        const trailing_w: f32 = switch (kind) {
            .choice, .action => 26,
            .adjuster, .toggle => 12,
        };
        const value_w = if (kind == .toggle) 46.0 else @min(max_value_w, @max(min_value_w, draw.measureText(row.value) + 24 + trailing_w));
        const value_x = @round(right_edge - value_w);
        const control_h = if (kind == .toggle) 24.0 else @round(@max(32.0, draw.cell_h + 10.0));
        const pill_y = visible.gl_y + @round((layout.row_h - control_h) / 2);
        const is_on = std.mem.eql(u8, row.value, i18n.s().settings_value_on);
        if (kind == .toggle) {
            draw.roundedQuadAlpha(value_x, pill_y, value_w, control_h, control_h / 2, if (is_on) mixColor(draw.bg, draw.accent, 0.40) else mixColor(draw.bg, draw.fg, 0.18), 0.96);
            const knob_d = control_h - 6;
            const knob_x = if (is_on) value_x + value_w - knob_d - 3 else value_x + 3;
            draw.roundedQuadAlpha(knob_x, pill_y + 3, knob_d, knob_d, knob_d / 2, if (is_on) draw.accent else mixColor(draw.bg, draw.fg, 0.42), 0.96);
        } else {
            _ = draw.renderTextLimited(row.value, value_x, rowTextY(draw, pill_y, control_h), if (selected) draw.accent else mixColor(draw.bg, draw.fg, 0.82), value_w - trailing_w);
            if (kind == .choice or kind == .action) _ = draw.renderTextLimited(">", value_x + value_w - 12, rowTextY(draw, pill_y, control_h), mixColor(draw.bg, draw.fg, 0.60), 12);
        }
        title_max_w = @max(1.0, value_x - title_x - 18);
    }

    if (visible.visible_index > 0) draw.fillQuadAlpha(x + 18, visible.gl_y + layout.row_h - 1, w - 36, 1, mixColor(draw.bg, draw.fg, 0.14), 0.62);
    _ = draw.renderTextLimited(rowTitle(row.id), title_x, title_y, if (selected) mixColor(draw.fg, draw.accent, 0.16) else draw.fg, title_max_w);
    _ = draw.renderTextLimited(rowDescription(category, row.id), title_x, detail_y, mixColor(draw.bg, draw.fg, 0.56), title_max_w);
}

fn renderPickerRow(draw: DrawContext, layout: settings_page_layout.Layout, window_height: f32, row_index: usize, label: []const u8, selected: bool, current: bool) void {
    const visible = layout.visibleRow(window_height, row_index) orelse return;
    if (selected) {
        draw.fillQuadAlpha(layout.content_x + 2, visible.gl_y + 8, 3, layout.row_h - 16, draw.accent, 0.82);
        draw.fillQuadAlpha(layout.content_x + 8, visible.gl_y + 6, layout.content_w - 16, layout.row_h - 12, mixColor(draw.bg, draw.accent, 0.08), 0.72);
    }
    if (visible.visible_index > 0) draw.fillQuadAlpha(layout.content_x + 18, visible.gl_y + layout.row_h - 1, layout.content_w - 36, 1, mixColor(draw.bg, draw.fg, 0.14), 0.62);
    const text_y = rowTextY(draw, visible.gl_y, layout.row_h);
    _ = draw.renderTextLimited(label, layout.content_x + 20, text_y, if (selected) mixColor(draw.fg, draw.accent, 0.16) else draw.fg, layout.content_w - 170);
    if (current) _ = draw.renderTextLimited(if (i18n.lang() == .zh_CN) "当前" else "Current", layout.content_x + layout.content_w - 100, text_y, draw.accent, 82);
}

fn renderScrollbar(draw: DrawContext, layout: settings_page_layout.Layout, window_height: f32, item_count: usize) void {
    if (layout.visible_rows >= item_count) return;
    const total: f32 = @floatFromInt(item_count);
    const vis: f32 = @floatFromInt(layout.visible_rows);
    const track_h = layout.row_h * vis;
    const sb_x = layout.content_x + layout.content_w - 10;
    draw.fillQuadAlpha(sb_x, @round(window_height - layout.row_top_px - track_h), 3, track_h, mixColor(draw.bg, draw.fg, 0.25), 0.30);
    const thumb_h = @max(24.0, @round(track_h * vis / total));
    const max_scroll: f32 = @floatFromInt(item_count - layout.visible_rows);
    const offset = if (max_scroll > 0) @round((track_h - thumb_h) * (@as(f32, @floatFromInt(layout.scroll)) / max_scroll)) else 0;
    draw.fillQuadAlpha(sb_x, @round(window_height - (layout.row_top_px + offset) - thumb_h), 3, thumb_h, draw.accent, 0.55);
}

fn renderFooter(draw: DrawContext, layout: settings_page_layout.Layout, window_height: f32, picker_open: bool, muted: [3]f32, border: [3]f32) void {
    const footer_h = ui_patterns.workbenchFooterHeight(draw.cell_h);
    const footer_top = ui_patterns.workbenchFooterTop(window_height, layout.page_top_px, footer_h);
    const footer_y = @round(window_height - footer_top - footer_h);
    draw.fillQuadAlpha(layout.page_x, footer_y, layout.page_w, footer_h, mixColor(draw.bg, draw.fg, 0.030), 0.98);
    draw.fillQuadAlpha(layout.page_x, footer_y + footer_h - 1, layout.page_w, 1, border, 0.68);
    const text = if (picker_open)
        (if (i18n.lang() == .zh_CN) "↑/↓ 选择  ·  Enter 应用  ·  Esc 返回" else "↑/↓ choose  ·  Enter apply  ·  Esc back")
    else
        i18n.s().settings_workbench_footer;
    _ = draw.renderTextLimited(text, layout.content_x, rowTextY(draw, footer_y, footer_h), muted, layout.content_w);
}

const ControlKind = enum { adjuster, toggle, choice, action };

fn controlKind(row: usize) ControlKind {
    if (settings_page.SHELL_INTEGRATION_ROWS > 0 and (row == settings_page.SETTINGS_CONTROL_ROW_START + 9 or row == settings_page.SETTINGS_CONTROL_ROW_START + 10)) return .toggle;
    return switch (row) {
        settings_page.SETTINGS_FONT_SIZE_ROW => .adjuster,
        settings_page.SETTINGS_FONT_FAMILY_ROW, settings_page.SETTINGS_THEME_ROW, settings_page.SETTINGS_CONTROL_ROW_START + 0, settings_page.SETTINGS_CONTROL_ROW_START + 3, settings_page.SETTINGS_CONTROL_ROW_START + 4, settings_page.SETTINGS_CONTROL_ROW_START + 6 => .choice,
        settings_page.SETTINGS_CONTROL_ROW_START + 1, settings_page.SETTINGS_CONTROL_ROW_START + 2, settings_page.SETTINGS_CONTROL_ROW_START + 5, settings_page.SETTINGS_CONTROL_ROW_START + 7, settings_page.SETTINGS_CONTROL_ROW_START + 8 => .toggle,
        else => .action,
    };
}

fn categoryLabel(category: settings_page.Category) []const u8 {
    return switch (i18n.lang()) {
        .en => switch (category) {
            .general => "General",
            .appearance => "Appearance",
            .ai => "AI & Integrations",
            .system => "System",
        },
        .zh_CN => switch (category) {
            .general => "常规",
            .appearance => "外观",
            .ai => "AI 与集成",
            .system => "系统",
        },
    };
}

fn categoryDescription(category: settings_page.Category) []const u8 {
    return switch (i18n.lang()) {
        .en => switch (category) {
            .general => "Startup, language, and configuration",
            .appearance => "Typography, theme, and cursor behavior",
            .ai => "Profiles and assistant integrations",
            .system => "Desktop integration and startup behavior",
        },
        .zh_CN => switch (category) {
            .general => "启动、语言与配置管理",
            .appearance => "字体、主题与光标行为",
            .ai => "配置文件与智能助手集成",
            .system => "桌面集成与启动方式",
        },
    };
}

fn rowTitle(row: usize) []const u8 {
    if (settings_page.SHELL_INTEGRATION_ROWS > 0 and row == settings_page.SETTINGS_CONTROL_ROW_START + 9) return i18n.s().settings_start_menu;
    if (settings_page.SHELL_INTEGRATION_ROWS > 0 and row == settings_page.SETTINGS_CONTROL_ROW_START + 10) return i18n.s().settings_startup;
    return switch (row) {
        settings_page.SETTINGS_FONT_FAMILY_ROW => if (i18n.lang() == .zh_CN) "字体" else "Font family",
        settings_page.SETTINGS_FONT_SIZE_ROW => i18n.s().settings_font_size,
        settings_page.SETTINGS_THEME_ROW => i18n.s().settings_theme,
        settings_page.SETTINGS_CONTROL_ROW_START + 0 => i18n.s().settings_cursor_style,
        settings_page.SETTINGS_CONTROL_ROW_START + 1 => i18n.s().settings_cursor_blink,
        settings_page.SETTINGS_CONTROL_ROW_START + 2 => i18n.s().settings_focus_follows_mouse,
        settings_page.SETTINGS_CONTROL_ROW_START + 3 => i18n.s().settings_shell,
        settings_page.SETTINGS_CONTROL_ROW_START + 4 => i18n.s().settings_default_ai,
        settings_page.SETTINGS_CONTROL_ROW_START + 5 => i18n.s().settings_weixin_direct,
        settings_page.SETTINGS_CONTROL_ROW_START + 6 => i18n.s().settings_language,
        settings_page.SETTINGS_CONTROL_ROW_START + 7 => i18n.s().settings_restore_tabs,
        settings_page.SETTINGS_CONTROL_ROW_START + 8 => i18n.s().settings_distill_suggest,
        settings_page.SETTINGS_RAW_CONFIG_ROW => i18n.s().settings_raw_config,
        settings_page.SETTINGS_RESTORE_DEFAULTS_ROW => i18n.s().settings_restore_defaults,
        else => "",
    };
}

fn rowDescription(_: settings_page.Category, row: usize) []const u8 {
    const zh = i18n.lang() == .zh_CN;
    if (settings_page.SHELL_INTEGRATION_ROWS > 0 and row == settings_page.SETTINGS_CONTROL_ROW_START + 9) return if (zh) "在 Windows 开始菜单中显示 WispTerm" else "Show WispTerm in the Windows Start menu";
    if (settings_page.SHELL_INTEGRATION_ROWS > 0 and row == settings_page.SETTINGS_CONTROL_ROW_START + 10) return if (zh) "登录系统后自动启动 WispTerm" else "Launch WispTerm when you sign in";
    return switch (row) {
        settings_page.SETTINGS_FONT_FAMILY_ROW => if (zh) "从系统已安装字体中选择终端字体" else "Choose from fonts installed on this system",
        settings_page.SETTINGS_FONT_SIZE_ROW => if (zh) "调整终端内容的显示字号" else "Adjust the terminal text size",
        settings_page.SETTINGS_THEME_ROW => if (zh) "选择终端和应用界面的配色主题" else "Choose the terminal and app color theme",
        settings_page.SETTINGS_CONTROL_ROW_START + 0 => if (zh) "选择终端光标的形状" else "Choose the terminal cursor shape",
        settings_page.SETTINGS_CONTROL_ROW_START + 1 => if (zh) "控制光标是否闪烁" else "Control whether the cursor blinks",
        settings_page.SETTINGS_CONTROL_ROW_START + 2 => if (zh) "鼠标移动时自动切换面板焦点" else "Move panel focus with the pointer",
        settings_page.SETTINGS_CONTROL_ROW_START + 3 => if (zh) "设置新标签页使用的默认 Shell" else "Set the default shell for new tabs",
        settings_page.SETTINGS_CONTROL_ROW_START + 4 => if (zh) "选择新建 AI 会话使用的配置" else "Choose the profile for new AI sessions",
        settings_page.SETTINGS_CONTROL_ROW_START + 5 => if (zh) "允许微信消息直接进入当前会话" else "Allow WeChat messages into the active session",
        settings_page.SETTINGS_CONTROL_ROW_START + 6 => if (zh) "选择 WispTerm 的界面语言" else "Choose the WispTerm interface language",
        settings_page.SETTINGS_CONTROL_ROW_START + 7 => if (zh) "启动时恢复上次打开的标签页" else "Restore previously open tabs at launch",
        settings_page.SETTINGS_CONTROL_ROW_START + 8 => if (zh) "在合适时建议将工作流沉淀为技能" else "Suggest reusable skills from completed work",
        settings_page.SETTINGS_RAW_CONFIG_ROW => if (zh) "在编辑器中打开完整配置文件" else "Open the complete config file in your editor",
        settings_page.SETTINGS_RESTORE_DEFAULTS_ROW => if (zh) "移除自定义设置并恢复默认值" else "Remove custom settings and restore defaults",
        else => "",
    };
}

fn lineHeight(draw: DrawContext) f32 {
    return @round(@max(24.0, draw.cell_h + 8.0));
}
fn textYFromTop(draw: DrawContext, window_height: f32, top: f32) f32 {
    return @round(window_height - top - draw.cell_h);
}
fn rowTextY(draw: DrawContext, y: f32, h: f32) f32 {
    return @round(y + (h - draw.cell_h) / 2);
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}
