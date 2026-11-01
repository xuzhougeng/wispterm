//! Right dock renderer: the tab row (icon-only tabs, the selected one
//! expanded to icon + label, the open/close toggle at the far right), the
//! dock's resize edge, and the selected panel — Copilot's conversation or the
//! docked File Explorer — with an explicit empty state when a panel has
//! nothing to show. Layout math lives in `appwindow/right_dock.zig`.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const ui_pipeline = @import("ui_pipeline.zig");
const chrome_icons = @import("chrome_icons.zig");
const right_dock = @import("../appwindow/right_dock.zig");
const file_explorer_renderer = @import("file_explorer_renderer.zig");

const Palette = struct {
    bg: [3]f32,
    fg: [3]f32,
    panel_bg: [3]f32,
    row_bg: [3]f32,
    border: [3]f32,
    text: [3]f32,
    muted: [3]f32,
    hover_bg: [3]f32,
    selected_bg: [3]f32,
    accent: [3]f32,
};

fn blend(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

fn palette() Palette {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    return .{
        .bg = bg,
        .fg = fg,
        .panel_bg = blend(bg, fg, 0.035),
        .row_bg = blend(bg, fg, 0.05),
        .border = blend(bg, .{ 0.0, 0.0, 0.0 }, 0.20),
        .text = blend(bg, fg, 0.92),
        .muted = blend(bg, fg, 0.60),
        .hover_bg = blend(bg, fg, 0.09),
        .selected_bg = blend(bg, fg, 0.13),
        .accent = accent,
    };
}

/// Measured width of a short label in the titlebar font.
pub fn labelWidth(text: []const u8) f32 {
    var w: f32 = 0;
    var view = std.unicode.Utf8View.init(text) catch return 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| w += titlebar.titlebarGlyphAdvance(cp);
    return w;
}

/// The tab-row layout for the active dock, shared with input hit-testing so
/// clicks land exactly on what is drawn.
pub fn headerLayout(window_width: i32, window_height: i32) ?right_dock.HeaderLayout {
    const dock = AppWindow.rightDockBounds(window_width, window_height) orelse return null;
    const selected = AppWindow.rightDockActivePanel() orelse return null;
    var buf: [right_dock.MAX_PANELS]right_dock.Panel = undefined;
    const panels = right_dock.availablePanels(right_dock.g_state.placement, &buf);
    return right_dock.headerLayout(dock, AppWindow.rightDockTabRowHeight(), panels, selected, labelWidth(selected.label()), AppWindow.rightDockUiScale());
}

fn mouseIn(rect: right_dock.Rect) bool {
    const win = AppWindow.g_window orelse return false;
    if (win.mouse_x < 0 or win.mouse_y < 0) return false;
    return rect.contains(@floatFromInt(win.mouse_x), @floatFromInt(win.mouse_y));
}

pub fn render(fb_width: c_int, fb_height: c_int, titlebar_h: f32) void {
    _ = titlebar_h;
    const win_w: i32 = @intCast(fb_width);
    const win_h: i32 = @intCast(fb_height);
    const dock = AppWindow.rightDockBounds(win_w, win_h) orelse return;
    const panel = AppWindow.rightDockActivePanel() orelse return;
    const layout = headerLayout(win_w, win_h) orelse return;
    const window_h: f32 = @floatFromInt(fb_height);
    const content = right_dock.contentBounds(dock, layout.row.h);
    const p = palette();

    // Panel first, so the tab row and the resize edge paint over any overflow.
    switch (panel) {
        .copilot => renderCopilot(content, fb_width, fb_height, p),
        .files => {
            fillTopDown(content.left, content.top, content.right - content.left, content.bottom - content.top, window_h, p.panel_bg);
            file_explorer_renderer.renderDocked(
                @floatFromInt(content.left),
                content.width(),
                @floatFromInt(content.top),
                window_h,
            );
        },
    }
    renderTabRow(&layout, window_h, p);
    renderLeftEdge(dock, window_h, p);
}

fn fillTopDown(x: i32, top: i32, w: i32, h: i32, window_h: f32, color: [3]f32) void {
    if (w <= 0 or h <= 0) return;
    const fx: f32 = @floatFromInt(x);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const ftop: f32 = @floatFromInt(top);
    ui_pipeline.fillQuad(fx, window_h - ftop - fh, fw, fh, color);
}

fn renderCopilot(content: right_dock.Bounds, fb_width: c_int, fb_height: c_int, p: Palette) void {
    const window_h: f32 = @floatFromInt(fb_height);
    const status: right_dock.CopilotStatus = if (!AppWindow.isActiveTabTerminal())
        .not_terminal_tab
    else if (AppWindow.ensureActiveCopilotSession()) |session| {
        AppWindow.assistant_conversation_renderer.render(
            session,
            @floatFromInt(fb_width),
            window_h,
            @floatFromInt(content.top),
            @floatFromInt(content.left),
            content.width(),
            true, // docked Copilot: status shown as a colored dot
        );
        return;
    } else .no_profile;

    fillTopDown(content.left, content.top, content.right - content.left, content.bottom - content.top, window_h, p.panel_bg);
    const empty = right_dock.copilotEmptyState(status) orelse return;
    renderEmptyState(content, window_h, p, empty);
}

/// Explanation near the top of the content area: why it is empty, then what
/// to do next (word-wrapped; shared with the explorer's empty states).
fn renderEmptyState(content: right_dock.Bounds, window_h: f32, p: Palette, state: right_dock.EmptyState) void {
    const scale = AppWindow.rightDockUiScale();
    file_explorer_renderer.drawEmptyState(
        @floatFromInt(content.left),
        content.width(),
        @as(f32, @floatFromInt(content.top)) + 24 * scale,
        window_h,
        p.text,
        p.muted,
        state,
        scale,
    );
}

fn renderTabRow(layout: *const right_dock.HeaderLayout, window_h: f32, p: Palette) void {
    const scale = AppWindow.rightDockUiScale();
    const row = layout.row;
    const row_gl_y = window_h - row.y - row.h;
    ui_pipeline.fillQuad(row.x, row_gl_y, row.w, row.h, p.row_bg);
    ui_pipeline.fillQuad(row.x, row_gl_y, row.w, 1, p.border);

    for (layout.slots()) |slot| {
        const r = slot.rect;
        const gl_y = window_h - r.y - r.h;
        const hovered = mouseIn(r);
        if (slot.selected) {
            ui_pipeline.fillQuad(r.x, gl_y, r.w, r.h, p.selected_bg);
            // Accent underline marks the active tab, like a segmented control.
            ui_pipeline.fillQuad(r.x + 4 * scale, gl_y, @max(0, r.w - 8 * scale), 2 * scale, p.accent);
        } else if (hovered) {
            ui_pipeline.fillQuad(r.x, gl_y, r.w, r.h, p.hover_bg);
        }
        const icon_color = if (slot.selected or hovered) p.text else p.muted;
        renderIcon(iconFor(slot.panel), r.x + layout.icon_w / 2, gl_y + r.h / 2, scale, icon_color);
        if (slot.show_label) {
            const text_y = gl_y + (r.h - font.g_titlebar_cell_height) / 2;
            _ = titlebar.renderTextLimited(slot.panel.label(), r.x + layout.icon_w - 2 * scale, text_y, p.text, slot.label_w + 2 * scale);
        }
    }

    const t = layout.toggle;
    const t_gl_y = window_h - t.y - t.h;
    const toggle_hovered = mouseIn(t);
    if (toggle_hovered) ui_pipeline.fillQuad(t.x, t_gl_y, t.w, t.h, p.hover_bg);
    renderIcon(.panel_right, t.x + t.w / 2, t_gl_y + t.h / 2, scale, if (toggle_hovered) p.text else p.muted);
}

fn iconFor(panel: right_dock.Panel) chrome_icons.Kind {
    return switch (panel) {
        .copilot => .copilot,
        .files => .folder,
    };
}

/// Chrome icons are drawn at the titlebar's logical size (a 46x34 button at
/// 96 DPI) around the origin, then scaled by the UI scale and centered on
/// (cx, cy) so they keep the same physical size on Retina displays.
fn renderIcon(kind: chrome_icons.Kind, cx: f32, cy: f32, scale: f32, color: [3]f32) void {
    const slot_w: f32 = 46;
    const slot_h: f32 = 34;
    var buf: [chrome_icons.max_quads]chrome_icons.Quad = undefined;
    const n = chrome_icons.fill(&buf, kind, -slot_w / 2, -slot_h / 2, slot_w, slot_h);
    for (buf[0..n]) |q| ui_pipeline.fillQuad(cx + q.x * scale, cy + q.y * scale, q.w * scale, q.h * scale, color);
}

fn renderLeftEdge(dock: right_dock.Bounds, window_h: f32, p: Palette) void {
    const active = right_dock.g_interaction.resize_hover or right_dock.g_interaction.resize_dragging;
    const x: f32 = @floatFromInt(dock.left);
    const h: f32 = @floatFromInt(dock.bottom - dock.top);
    const color = if (active) blend(p.bg, p.accent, 0.38) else p.border;
    const scale = AppWindow.rightDockUiScale();
    ui_pipeline.fillQuad(x, window_h - @as(f32, @floatFromInt(dock.top)) - h, if (active) 2 * scale else scale, h, color);
}
