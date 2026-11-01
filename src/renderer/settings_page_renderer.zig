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
    // Font picker only: the built-in family, tagged so it can be found again.
    picker_default: []const u8 = "",
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
    var subtitle_buf: [160]u8 = undefined;
    const subtitle = if (picker_open) pickerSubtitle(state, &subtitle_buf) else categoryDescription(state.category);
    _ = draw.renderTextLimited(page_title, layout.content_x, textYFromTop(draw, window_height, layout.page_top_px + 28), mixColor(draw.fg, draw.accent, 0.10), layout.content_w);
    _ = draw.renderTextLimited(subtitle, layout.content_x, textYFromTop(draw, window_height, layout.page_top_px + 28 + lineHeight(draw)), muted, layout.content_w);
    draw.fillQuadAlpha(layout.content_x, @round(window_height - layout.row_top_px), layout.content_w, 1, border, 0.52);

    if (picker_open) {
        for (0..state.pickerCount()) |row_index| {
            const value = state.pickerValueAt(row_index) orelse continue;
            const label = if (state.pickerKind().? == .shell and value.len == 0) view.default_shell_label else value;
            const is_default = view.picker_default.len > 0 and std.ascii.eqlIgnoreCase(value, view.picker_default);
            renderPickerRow(draw, layout, window_height, row_index, label, state.picker.selected == row_index, std.ascii.eqlIgnoreCase(value, view.picker_current), is_default);
        }
    } else {
        for (view.rows, 0..) |row, row_index| {
            renderRow(draw, state.category, layout, window_height, row, row_index, state.focus == row.id);
        }
    }

    const item_count = if (picker_open) state.pickerCount() else view.rows.len;
    renderScrollbar(draw, layout, window_height, item_count);
    renderFooter(draw, layout, window_height, picker_open, state.proxy_editing, state.proxy_draft_invalid, state.research_proxy_editing, state.research_proxy_draft_invalid, muted, border);
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
        const control_h = if (kind == .toggle) 24.0 else @round(@max(32.0, draw.cell_h + 10.0));
        const pill_y = title_y - @round((control_h - draw.cell_h) / 2);
        const value_color = if (selected) draw.accent else mixColor(draw.bg, draw.fg, 0.82);
        if (kind == .adjuster) {
            const adjuster = layout.font_adjuster;
            renderCentered(draw, "-", adjuster.minus, pill_y, control_h, value_color);
            renderCentered(draw, settings_page_layout.fontAdjusterValue(row.value), adjuster.value, pill_y, control_h, value_color);
            renderCentered(draw, "+", adjuster.plus, pill_y, control_h, value_color);
            title_max_w = @max(1.0, adjuster.minus.x - title_x - 18);
        } else {
            const max_value_w: f32 = switch (kind) {
                .toggle => 96,
                .choice => 360,
                .action => 180,
                .adjuster => unreachable,
            };
            const min_value_w: f32 = switch (kind) {
                .toggle => 76,
                .choice => 132,
                .action => 96,
                .adjuster => unreachable,
            };
            const trailing_w: f32 = switch (kind) {
                .choice, .action => 26,
                .toggle => 12,
                .adjuster => unreachable,
            };
            const desired_w = if (kind == .toggle) 46.0 else @min(max_value_w, @max(min_value_w, draw.measureText(row.value) + 24 + trailing_w));
            const value_w = ui_patterns.textColumns(right_edge - title_x, draw.measureText(rowTitle(row.id)), desired_w, 18).right_w;
            const value_x = @round(right_edge - value_w);
            const is_on = std.mem.eql(u8, row.value, i18n.s().settings_value_on);
            if (kind == .toggle) {
                draw.roundedQuadAlpha(value_x, pill_y, value_w, control_h, control_h / 2, if (is_on) mixColor(draw.bg, draw.accent, 0.40) else mixColor(draw.bg, draw.fg, 0.18), 0.96);
                const knob_d = @min(control_h - 6, @max(0, value_w - 6));
                const knob_x = if (is_on) value_x + value_w - knob_d - 3 else value_x + 3;
                draw.roundedQuadAlpha(knob_x, pill_y + 3, knob_d, knob_d, knob_d / 2, if (is_on) draw.accent else mixColor(draw.bg, draw.fg, 0.42), 0.96);
            } else {
                _ = draw.renderTextLimited(row.value, value_x, rowTextY(draw, pill_y, control_h), value_color, value_w - trailing_w);
                if (kind == .choice or kind == .action) _ = draw.renderTextLimited(">", value_x + @max(0, value_w - 12), rowTextY(draw, pill_y, control_h), mixColor(draw.bg, draw.fg, 0.60), @min(12, value_w));
            }
            title_max_w = @max(1.0, value_x - title_x - 18);
        }
    }

    if (visible.visible_index > 0) draw.fillQuadAlpha(x + 18, visible.gl_y + layout.row_h - 1, w - 36, 1, mixColor(draw.bg, draw.fg, 0.14), 0.62);
    _ = draw.renderTextLimited(rowTitle(row.id), title_x, title_y, if (selected) mixColor(draw.fg, draw.accent, 0.16) else draw.fg, title_max_w);
    _ = draw.renderTextLimited(rowDescription(category, row.id), title_x, detail_y, mixColor(draw.bg, draw.fg, 0.56), @max(0, right_edge - title_x));
}

fn renderCentered(draw: DrawContext, text: []const u8, slot: settings_page_layout.HorizontalSlot, y: f32, h: f32, color: [3]f32) void {
    const text_w = draw.measureText(text);
    const text_x = @round(slot.x + @max(0.0, (slot.w - text_w) / 2.0));
    _ = draw.renderTextLimited(text, text_x, rowTextY(draw, y, h), color, slot.w);
}

fn pickerSubtitle(state: *const settings_page.State, buf: []u8) []const u8 {
    const zh = i18n.lang() == .zh_CN;
    const query = state.pickerQuery();
    if (query.len > 0) {
        return (if (zh)
            std.fmt.bufPrint(buf, "搜索：{s}  ·  {d} 项", .{ query, state.pickerCount() })
        else
            std.fmt.bufPrint(buf, "Search: {s}  ·  {d} matches", .{ query, state.pickerCount() })) catch query;
    }
    if (state.pickerKind() == .font_family) {
        return if (zh) "输入名称搜索，用方向键选择，按 Enter 应用，按 Esc 返回" else "Type to search, arrows to choose, Enter to apply, Esc to go back";
    }
    return if (zh) "用方向键选择，按 Enter 应用，按 Esc 返回" else "Use arrows to choose, Enter to apply, Esc to go back";
}

fn renderPickerRow(draw: DrawContext, layout: settings_page_layout.Layout, window_height: f32, row_index: usize, label: []const u8, selected: bool, current: bool, is_default: bool) void {
    const visible = layout.visibleRow(window_height, row_index) orelse return;
    if (selected) {
        draw.fillQuadAlpha(layout.content_x + 2, visible.gl_y + 8, 3, layout.row_h - 16, draw.accent, 0.82);
        draw.fillQuadAlpha(layout.content_x + 8, visible.gl_y + 6, layout.content_w - 16, layout.row_h - 12, mixColor(draw.bg, draw.accent, 0.08), 0.72);
    }
    if (visible.visible_index > 0) draw.fillQuadAlpha(layout.content_x + 18, visible.gl_y + layout.row_h - 1, layout.content_w - 36, 1, mixColor(draw.bg, draw.fg, 0.14), 0.62);
    const text_y = rowTextY(draw, visible.gl_y, layout.row_h);
    const zh = i18n.lang() == .zh_CN;
    const tag: []const u8 = if (current and is_default)
        (if (zh) "当前 · 默认" else "Current · Default")
    else if (current)
        (if (zh) "当前" else "Current")
    else if (is_default)
        (if (zh) "默认" else "Default")
    else
        "";
    const columns = ui_patterns.textColumns(layout.content_w - 38, draw.measureText(label), draw.measureText(tag), 18);
    _ = draw.renderTextLimited(label, layout.content_x + 20, text_y, if (selected) mixColor(draw.fg, draw.accent, 0.16) else draw.fg, columns.left_w);
    if (tag.len > 0) _ = draw.renderTextLimited(tag, layout.content_x + 20 + columns.right_x, text_y, if (current) draw.accent else mixColor(draw.bg, draw.fg, 0.60), columns.right_w);
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

fn renderFooter(draw: DrawContext, layout: settings_page_layout.Layout, window_height: f32, picker_open: bool, proxy_editing: bool, proxy_invalid: bool, research_proxy_editing: bool, research_proxy_invalid: bool, muted: [3]f32, border: [3]f32) void {
    const footer_h = ui_patterns.workbenchFooterHeight(draw.cell_h);
    const footer_top = ui_patterns.workbenchFooterTop(window_height, layout.page_top_px, footer_h);
    const footer_y = @round(window_height - footer_top - footer_h);
    draw.fillQuadAlpha(layout.page_x, footer_y, layout.page_w, footer_h, mixColor(draw.bg, draw.fg, 0.030), 0.98);
    draw.fillQuadAlpha(layout.page_x, footer_y + footer_h - 1, layout.page_w, 1, border, 0.68);
    const zh = i18n.lang() == .zh_CN;
    const text = if (picker_open)
        (if (zh) "↑/↓ 选择  ·  Enter 应用  ·  Esc 返回" else "↑/↓ choose  ·  Enter apply  ·  Esc back")
    else if (research_proxy_editing and research_proxy_invalid)
        (if (zh) "格式应为 127.0.0.1:6789 或 http://127.0.0.1:6789" else "Use 127.0.0.1:6789 or http://127.0.0.1:6789")
    else if (research_proxy_editing)
        (if (zh) "输入研究工具代理  ·  Enter 保存  ·  Esc 取消  ·  清空则继承 AI 代理" else "Type Research Tools Proxy  ·  Enter save  ·  Esc cancel  ·  empty inherits AI proxy")
    else if (proxy_editing and proxy_invalid)
        (if (zh) "格式应为 127.0.0.1:6789 或 http://127.0.0.1:6789" else "Use 127.0.0.1:6789 or http://127.0.0.1:6789")
    else if (proxy_editing)
        (if (zh) "输入 host:port  ·  Enter 保存  ·  Esc 取消  ·  清空则使用系统代理" else "Type host:port  ·  Enter save  ·  Esc cancel  ·  empty uses the system proxy")
    else
        i18n.s().settings_workbench_footer;
    _ = draw.renderTextLimited(text, layout.page_x + 24, rowTextY(draw, footer_y, footer_h), muted, layout.page_w - 48);
}

const ControlKind = enum { adjuster, toggle, choice, action };

fn controlKind(row: usize) ControlKind {
    if (settings_page.SHELL_INTEGRATION_ROWS > 0 and (row == settings_page.SETTINGS_CONTROL_ROW_START + 9 or row == settings_page.SETTINGS_CONTROL_ROW_START + 10)) return .toggle;
    return switch (row) {
        settings_page.SETTINGS_FONT_SIZE_ROW => .adjuster,
        settings_page.SETTINGS_FONT_FAMILY_ROW, settings_page.SETTINGS_THEME_ROW, settings_page.SETTINGS_CONTROL_ROW_START + 0, settings_page.SETTINGS_CONTROL_ROW_START + 3, settings_page.SETTINGS_CONTROL_ROW_START + 4, settings_page.SETTINGS_CONTROL_ROW_START + 6, settings_page.SETTINGS_PROXY_ADDRESS_ROW, settings_page.SETTINGS_RESEARCH_PROXY_ADDRESS_ROW => .choice,
        settings_page.SETTINGS_CONTROL_ROW_START + 1, settings_page.SETTINGS_CONTROL_ROW_START + 2, settings_page.SETTINGS_CONTROL_ROW_START + 5, settings_page.SETTINGS_CONTROL_ROW_START + 7, settings_page.SETTINGS_CONTROL_ROW_START + 8, settings_page.SETTINGS_SYSTEM_PROXY_ROW, settings_page.SETTINGS_RESEARCH_PROXY_ROW => .toggle,
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
        settings_page.SETTINGS_SYSTEM_PROXY_ROW => if (i18n.lang() == .zh_CN) "使用 AI 代理" else "Use AI proxy",
        settings_page.SETTINGS_PROXY_ADDRESS_ROW => if (i18n.lang() == .zh_CN) "AI 代理地址" else "AI proxy",
        settings_page.SETTINGS_RESEARCH_PROXY_ROW => if (i18n.lang() == .zh_CN) "使用研究工具代理" else "Use Research Tools Proxy",
        settings_page.SETTINGS_RESEARCH_PROXY_ADDRESS_ROW => if (i18n.lang() == .zh_CN) "研究工具代理" else "Research Tools Proxy",
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
        settings_page.SETTINGS_SYSTEM_PROXY_ROW => if (zh) "开启后，AI 请求走下一行选择的代理" else "Send AI requests through the proxy chosen below",
        settings_page.SETTINGS_PROXY_ADDRESS_ROW => if (zh) "留空使用系统代理，或填写 127.0.0.1:端口" else "Empty uses the system proxy, or set host:port",
        settings_page.SETTINGS_RESEARCH_PROXY_ROW => if (zh) "开启后，websearch、webread 和 PubMed 使用研究工具代理" else "Send Web Search, Web Read, and PubMed through Research Tools Proxy",
        settings_page.SETTINGS_RESEARCH_PROXY_ADDRESS_ROW => if (zh) "留空使用上方 AI 代理地址，或填写独立地址" else "Empty uses the AI proxy address above, or set a custom address",
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

test "long setting values stay in the row and leave descriptions their own line" {
    const Probe = struct {
        var left: f32 = 0;
        var right: f32 = 0;
        var description_width: f32 = 0;
        var out_of_bounds: bool = false;
        fn quad(_: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
        fn rounded(_: f32, _: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
        fn measure(value: []const u8) f32 {
            var view = std.unicode.Utf8View.init(value) catch unreachable;
            var it = view.iterator();
            var w: f32 = 0;
            while (it.nextCodepoint()) |cp| w += if (cp < 128) @as(f32, 10) else 20;
            return w;
        }
        fn text(s: []const u8, x: f32, _: f32, _: [3]f32, max_w: f32) f32 {
            if (max_w > 0 and (x < left or x + max_w > right + 0.01)) out_of_bounds = true;
            if (std.mem.eql(u8, s, rowDescription(.general, settings_page.SETTINGS_CONTROL_ROW_START + 3))) description_width = max_w;
            return x + @min(@max(0, max_w), measure(s));
        }
    };
    const previous_lang = i18n.lang();
    defer i18n.setLang(previous_lang);
    i18n.setLang(.zh_CN);
    const draw = DrawContext{
        .bg = .{ 0, 0, 0 },
        .fg = .{ 1, 1, 1 },
        .accent = .{ 1, 1, 0 },
        .cell_h = 20,
        .fillQuadAlpha = Probe.quad,
        .roundedQuadAlpha = Probe.rounded,
        .renderTextLimited = Probe.text,
        .measureText = Probe.measure,
    };
    for ([_]f32{ 380, 580, 1000 }) |width| {
        const l = settings_page_layout.compute(.{
            .window_height = 600,
            .top_offset = 34,
            .content_x = 220,
            .content_width = width,
            .cell_height = 20,
            .focus_index = 0,
            .row_count = 1,
            .category_count = 3,
        });
        Probe.left = l.content_x;
        Probe.right = l.content_x + l.content_w;
        Probe.out_of_bounds = false;
        Probe.description_width = 0;
        renderRow(draw, .general, l, 600, .{
            .id = settings_page.SETTINGS_CONTROL_ROW_START + 3,
            .value = "系统默认 (/a/very/long/path/to/a/custom-shell)",
        }, 0, true);
        try std.testing.expect(!Probe.out_of_bounds);
        try std.testing.expectApproxEqAbs(l.content_w - 38, Probe.description_width, 0.01);
    }
}
