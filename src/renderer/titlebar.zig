//! Titlebar rendering — tab bar, caption buttons, bell indicator, placeholder.
//!
//! Owns the visual rendering of the tab bar (active/inactive tabs, close buttons,
//! + button, caption buttons). Uses shared renderer pipelines owned by the active
//! GPU backend. Depends on font module for glyph loading and tab module for state.

const std = @import("std");
const text_hint = @import("text_hint.zig");
const builtin = @import("builtin");
const titlebar_layout = @import("titlebar_layout.zig");
const toolbar_reveal = @import("toolbar_reveal.zig");
const chrome_icons = @import("chrome_icons.zig");
const AppWindow = @import("../AppWindow.zig");
const ui_pipeline = @import("ui_pipeline.zig");
const font = AppWindow.font;
const gpu = AppWindow.gpu;
const tab = AppWindow.tab;
const active_tab_state = @import("../appwindow/active_tab.zig");
const cell_renderer = AppWindow.cell_renderer;
const font_backend = @import("../platform/font_backend.zig");
const window_backend = @import("../platform/window_backend.zig");
const agent_detector = @import("../terminal_agents/detector.zig");
const update_pill_state = @import("../update_pill_state.zig");
const i18n = @import("../i18n.zig");
const primitives = @import("overlays/primitives.zig");
const Character = font.Character;

pub const SIDEBAR_WIDTH: f32 = 220;
pub const SIDEBAR_MIN_WIDTH: f32 = 160;
pub const SIDEBAR_MAX_WIDTH: f32 = 720;
pub const SIDEBAR_MIN_CONTENT_WIDTH: f32 = 240;
pub const SIDEBAR_RESIZE_HIT_WIDTH: f32 = 8;
pub const SIDEBAR_ROW_H: f32 = 42;
pub const SIDEBAR_HEADER_H: f32 = 46;
pub const TITLEBAR_TOGGLE_W: f32 = 46;
// On macOS the native menu bar (WispTerm › Settings…, View › Open Command
// Center) replaces these in-titlebar buttons, so they collapse to zero width and
// are not drawn.
pub const TITLEBAR_CONFIG_W: f32 = if (builtin.os.tag == .macos) 0 else 46;
pub const TITLEBAR_HELP_W: f32 = if (builtin.os.tag == .macos) 0 else 46;
pub const TITLEBAR_COPILOT_W: f32 = if (builtin.os.tag == .macos) 0 else 46;
pub const TITLEBAR_PALETTE_W: f32 = if (builtin.os.tag == .macos) 0 else 46;
// macOS draws the close / minimize / zoom (red / yellow / green) controls over
// the left edge of the titlebar via AppKit when NSWindowStyleMaskFullSizeContentView
// is set. Reserve a strip in *framebuffer pixels* so wispterm's own toggle and
// tab title don't sit underneath them. AppKit positions the traffic lights in
// LOGICAL pixels (~80 across), whereas wispterm renders/hit-tests in framebuffer
// pixels — on a 2x Retina display 80 logical = 160 fb, so we must scale by the
// current DPI ratio. Non-macOS platforms reserve nothing.
const TITLEBAR_LEFT_RESERVED_LOGICAL: f32 = 80;

pub fn titlebarLeftReserved() f32 {
    if (builtin.os.tag != .macos) return 0;
    const dpi: f32 = @floatFromInt(font.g_dpi);
    const scale = if (dpi > 0) dpi / 96.0 else 1.0;
    return @round(TITLEBAR_LEFT_RESERVED_LOGICAL * scale);
}
pub threadlocal var g_sidebar_width: f32 = SIDEBAR_WIDTH;
/// Per-window `window-show-toolbar` reveal state (see toolbar_reveal.zig).
threadlocal var g_toolbar_reveal: toolbar_reveal.State = .{};

pub fn setToolbarMode(mode: toolbar_reveal.Mode) void {
    g_toolbar_reveal.setMode(mode);
}

/// The pointer is over the focused window's titlebar strip or tab sidebar.
/// Unfocused windows keep their toolbar hidden: macOS stops sending mouse
/// moves to a non-key window, so its last pointer position would be stale.
fn toolbarHovered() bool {
    const win = AppWindow.g_window orelse return false;
    if (!window_backend.isFocused(win)) return false;
    // Windows reports the draggable caption area as non-client, where the
    // client mouse position is cleared to -1.
    if (window_backend.pointerOverHostTitlebar(win)) return true;
    const mouse = window_backend.mousePosition(win);
    return toolbar_reveal.pointInZone(@floatFromInt(mouse.x), @floatFromInt(mouse.y), titlebarHeight(), sidebarWidth());
}

/// Sample the toolbar hover once per main-loop iteration. True while the
/// reveal is changing, so the event-driven render gate keeps producing frames
/// through the fade instead of waiting for the next incidental wake.
pub fn tickToolbarReveal(now_ms: i64) bool {
    return g_toolbar_reveal.tick(toolbarHovered(), now_ms);
}

fn toolbarOpacity() f32 {
    return g_toolbar_reveal.opacityAt(std.time.milliTimestamp());
}

pub fn sidebarWidth() f32 {
    return if (tab.g_sidebar_visible) g_sidebar_width else 0;
}

pub fn sidebarRowHeight() f32 {
    return @max(SIDEBAR_ROW_H, @round(font.g_titlebar_cell_height + 22));
}

pub fn sidebarHeaderHeight() f32 {
    return @max(SIDEBAR_HEADER_H, @round(font.g_titlebar_cell_height + 24));
}

pub fn titlebarHeight() f32 {
    return @round(@max(@as(f32, @floatFromInt(window_backend.titlebarBaseHeight())), font.g_titlebar_cell_height + 12));
}

fn currentMousePosition() ?window_backend.Point {
    const win = AppWindow.g_window orelse return null;
    return window_backend.mousePosition(win);
}

fn mouseX() ?f32 {
    const mouse = currentMousePosition() orelse return null;
    return @floatFromInt(mouse.x);
}

fn mouseInRect(left: f32, top: f32, width: f32, height: f32) bool {
    const mouse = currentMousePosition() orelse return false;
    if (mouse.x < 0 or mouse.y < 0) return false;
    return titlebar_layout.pointInRect(@floatFromInt(mouse.x), @floatFromInt(mouse.y), left, top, width, height);
}

fn mouseInTitlebarRange(titlebar_h: f32, left: f32, right: f32) bool {
    return mouseInRect(left, 0, right - left, titlebar_h);
}

fn currentWindowIsMaximized() bool {
    const win = AppWindow.g_window orelse return false;
    return window_backend.isMaximized(win);
}

fn captionIconGlyph(icon: titlebar_layout.CaptionButtonIcon) font_backend.TitlebarIcon {
    return switch (icon) {
        .minimize => .minimize,
        .maximize => .maximize,
        .restore => .restore,
        .close => .close,
    };
}

fn captionButtonVisual(
    kind: titlebar_layout.CaptionButtonKind,
    rect: titlebar_layout.Rect,
    hovered: bool,
) titlebar_layout.CaptionButtonVisual {
    const is_focused = if (AppWindow.g_window) |win| window_backend.isFocused(win) else false;
    const is_maximized = currentWindowIsMaximized();
    const is_fullscreen = if (AppWindow.g_window) |win| window_backend.isFullscreen(win) else false;
    return titlebar_layout.captionButtonVisual(kind, rect, .{
        .hovered = hovered,
        .focused = is_focused,
        .maximized = is_maximized,
        .fullscreen = is_fullscreen,
    });
}

pub fn sidebarMaxWidthForWindow(window_width: f32) f32 {
    return titlebar_layout.sidebarMaxWidthForWindow(window_width, SIDEBAR_MIN_WIDTH, SIDEBAR_MAX_WIDTH, SIDEBAR_MIN_CONTENT_WIDTH);
}

pub fn clampSidebarWidth(width: f32, window_width: f32) f32 {
    return titlebar_layout.clampSidebarWidth(width, SIDEBAR_MIN_WIDTH, sidebarMaxWidthForWindow(window_width));
}

pub fn setSidebarWidth(width: f32, window_width: f32) bool {
    const next = clampSidebarWidth(width, window_width);
    if (next == g_sidebar_width) return false;
    g_sidebar_width = next;
    return true;
}

fn blend(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return titlebar_layout.blend(a, b, t);
}

/// The Update pill shows only where the in-titlebar buttons do (not macOS,
/// whose menu bar replaces them) and only while a staged update is ready.
pub fn updatePillWidth() f32 {
    if (TITLEBAR_PALETTE_W <= 0) return 0;
    return update_pill_state.currentWidth();
}

/// Accent pill with "Update", like Ghostty's UpdatePill. Hover reveals what a
/// click does; the click itself opens the restart confirmation (input.zig).
fn renderUpdatePill(x: f32, top_y: f32, w: f32, h: f32) void {
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const hovered = mouseInTitlebarRange(h, x, x + w);
    const pad_x: f32 = 6;
    const pill_h = @min(h - 10, font.g_titlebar_cell_height + 10);
    const pill_y = @round(top_y + (h - pill_h) / 2);
    const pill_w = w - pad_x * 2;
    primitives.renderRoundedQuadAlpha(x + pad_x, pill_y, pill_w, pill_h, pill_h / 2, accent, if (hovered) 0.34 else 0.22);
    primitives.renderRoundedQuadAlpha(x + pad_x + 8, pill_y + pill_h / 2 - 3, 6, 6, 3, accent, 0.95);

    const label = i18n.s().update_pill_label;
    const text_x = x + pad_x + 20;
    const text_y = top_y + (h - font.g_titlebar_cell_height) / 2;
    _ = renderTextLimited(label, text_x, text_y, blend(fg, accent, 0.35), pill_w - 26);
    if (hovered) text_hint.current.offer(i18n.s().update_pill_hint, x, top_y, w, h);
}

fn titlebarTextWidth(text: []const u8) f32 {
    var codepoints: [128]u32 = undefined;
    var width: f32 = 0;
    _ = collectTextCodepoints(text, &codepoints, &width);
    return width;
}

fn sidebarTabNumberWidth() f32 {
    var max_prefix_buf: [8]u8 = undefined;
    const max_prefix = std.fmt.bufPrint(&max_prefix_buf, "{d}", .{tab.MAX_TABS}) catch "99";
    return @max(@as(f32, 24), @ceil(titlebarTextWidth(max_prefix)) + 4);
}

pub fn agentBadgeColor(state: agent_detector.State) [3]f32 {
    return switch (state) {
        .idle => .{ 0.50, 0.56, 0.66 },
        .running => .{ 0.22, 0.72, 0.40 },
        .waiting_approval => .{ 0.95, 0.64, 0.20 },
        .needs_input => .{ 0.95, 0.45, 0.28 },
        .halted, .failed => .{ 0.90, 0.22, 0.30 },
        .done => .{ 0.34, 0.58, 0.95 },
        .none => .{ 0.45, 0.45, 0.45 },
    };
}

fn renderAgentBadge(detection: agent_detector.Detection, x: f32, text_y: f32, active: bool) f32 {
    const text = detection.badge();
    if (text.len == 0) return x;

    const pad_x: f32 = 5;
    const badge_h = @max(@as(f32, 18), font.g_titlebar_cell_height + 4);
    const text_w = titlebarTextWidth(text);
    const badge_w = @max(@as(f32, 18), text_w + pad_x * 2);
    const badge_y = text_y - 2;
    const base = agentBadgeColor(detection.state);
    const bg = blend(AppWindow.g_theme.background, base, if (active) 0.46 else 0.34);
    const fg = blend(.{ 1.0, 1.0, 1.0 }, base, 0.08);

    ui_pipeline.fillQuad(x, badge_y, badge_w, badge_h, bg);
    _ = renderTextLimited(text, x + (badge_w - text_w) / 2, text_y, fg, badge_w - pad_x * 2);
    return x + badge_w;
}

fn fallbackCodepoint(byte: u8) u32 {
    return titlebar_layout.fallbackCodepoint(byte);
}

fn renderFallbackBytesLimited(text: []const u8, x: f32, y: f32, color: [3]f32, max_w: f32) f32 {
    var total_w: f32 = 0;
    for (text) |byte| total_w += titlebarGlyphAdvance(fallbackCodepoint(byte));
    if (total_w <= max_w) {
        var full_x = x;
        for (text) |byte| {
            const cp = fallbackCodepoint(byte);
            renderTitlebarChar(cp, full_x, y, color);
            full_x += titlebarGlyphAdvance(cp);
        }
        return full_x;
    }

    text_hint.current.offer(text, x, y, max_w, font.g_titlebar_cell_height);
    var cursor_x = x;
    const ellipsis: u32 = 0x2026;
    const ellipsis_w = titlebarGlyphAdvance(ellipsis);
    for (text) |byte| {
        const cp = fallbackCodepoint(byte);
        const adv = titlebarGlyphAdvance(cp);
        // Reserve the ellipsis before drawing the final visible glyph. The
        // old post-overflow check often had no pixels left for it, leaving a
        // hard-cut label in narrow sidebars and compact panel headers.
        if (cursor_x + adv + ellipsis_w > x + max_w) break;
        renderTitlebarChar(cp, cursor_x, y, color);
        cursor_x += adv;
    }
    if (cursor_x + ellipsis_w <= x + max_w) {
        renderTitlebarChar(ellipsis, cursor_x, y, color);
        cursor_x += ellipsis_w;
    }
    return cursor_x;
}

fn collectTextCodepoints(text: []const u8, codepoints: []u32, text_width: *f32) usize {
    var count: usize = 0;
    text_width.* = 0;

    const view = std.unicode.Utf8View.init(text) catch {
        for (text) |byte| {
            if (count >= codepoints.len) break;
            const cp = fallbackCodepoint(byte);
            codepoints[count] = cp;
            text_width.* += titlebarGlyphAdvance(cp);
            count += 1;
        }
        return count;
    };

    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (count >= codepoints.len) break;
        codepoints[count] = cp;
        text_width.* += titlebarGlyphAdvance(cp);
        count += 1;
    }
    return count;
}

pub fn renderTextLimited(text: []const u8, x: f32, y: f32, color: [3]f32, max_w: f32) f32 {
    if (max_w <= 0) return x;

    var total_w: f32 = 0;
    var measure_view = std.unicode.Utf8View.init(text) catch return renderFallbackBytesLimited(text, x, y, color, max_w);
    var measure_it = measure_view.iterator();
    while (measure_it.nextCodepoint()) |cp| total_w += titlebarGlyphAdvance(cp);

    var cursor_x = x;
    var view = std.unicode.Utf8View.init(text) catch unreachable;
    var it = view.iterator();
    if (total_w <= max_w) {
        while (it.nextCodepoint()) |cp| {
            renderTitlebarChar(cp, cursor_x, y, color);
            cursor_x += titlebarGlyphAdvance(cp);
        }
        return cursor_x;
    }

    text_hint.current.offer(text, x, y, max_w, font.g_titlebar_cell_height);
    const ellipsis: u32 = 0x2026;
    const ellipsis_w = titlebarGlyphAdvance(ellipsis);
    while (it.nextCodepoint()) |cp| {
        const adv = titlebarGlyphAdvance(cp);
        if (cursor_x + adv + ellipsis_w > x + max_w) break;
        renderTitlebarChar(cp, cursor_x, y, color);
        cursor_x += adv;
    }
    if (cursor_x + ellipsis_w <= x + max_w) {
        renderTitlebarChar(ellipsis, cursor_x, y, color);
        cursor_x += ellipsis_w;
    }
    return cursor_x;
}

/// Blocking overlays discard hints collected from content behind their scrim.
pub fn clearTextHint() void {
    text_hint.current.clear();
}

/// Render after all pages/overlays so the full label is readable on hover.
pub fn renderTextHint() void {
    const state = &text_hint.current;
    defer state.clear();
    const layout = text_hint.layout(state, font.g_titlebar_cell_height, titlebarGlyphAdvance) orelse return;
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    ui_pipeline.fillQuad(layout.x - 1, layout.y - 1, layout.w + 2, layout.h + 2, blend(bg, fg, 0.3));
    ui_pipeline.fillQuad(layout.x, layout.y, layout.w, layout.h, blend(bg, fg, 0.08));
    ui_pipeline.beginClip(.{ .x = layout.x, .y = layout.y, .w = layout.w, .h = layout.h });
    defer ui_pipeline.endClip();
    for (layout.lines[0..layout.count], 0..) |line, row| {
        const y = layout.y + layout.h - 8 - font.g_titlebar_cell_height - @as(f32, @floatFromInt(row)) * layout.line_h;
        var view = std.unicode.Utf8View.init(state.text[line.start..line.end]) catch continue;
        var it = view.iterator();
        var x = layout.x + 12;
        while (it.nextCodepoint()) |cp| {
            renderTitlebarChar(cp, x, y, fg);
            x += titlebarGlyphAdvance(cp);
        }
    }
}

fn renderChromeIcon(kind: chrome_icons.Kind, x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    var buf: [chrome_icons.max_quads]chrome_icons.Quad = undefined;
    const n = chrome_icons.fill(&buf, kind, x, y, w, h);
    for (buf[0..n]) |q| {
        ui_pipeline.fillQuad(q.x, q.y, q.w, q.h, color);
    }
}

fn renderTitlebarIcon(icon: font_backend.TitlebarIcon, kind: chrome_icons.Kind, x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    if (font.icon_face != null) {
        if (font.loadIconGlyph(font_backend.titlebarIconGlyph(icon))) |ch| {
            renderIconGlyph(ch, x, y, w, h, color, 1.0);
            return;
        }
    }
    renderChromeIcon(kind, x, y, w, h, color);
}

fn renderPlusIcon(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    if (font.icon_face != null) {
        if (font.loadIconGlyph(font_backend.titlebarIconGlyph(.add))) |ch| {
            renderIconGlyph(ch, x, y, w, h, color, 1.1);
            return;
        }
    }

    renderChromeIcon(.add, x, y, w, h, color);
}

pub fn renderCloseIcon(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    if (font.icon_face != null) {
        if (font.loadIconGlyph(font_backend.titlebarIconGlyph(.close))) |ch| {
            renderIconGlyph(ch, x, y, w, h, color, 0.95);
            return;
        }
    }

    renderChromeIcon(.close, x, y, w, h, color);
}

/// Render a titlebar glyph at 1:1 atlas size (no scaling).
/// Supports both grayscale (titlebar atlas) and color emoji (color atlas).
pub fn renderTitlebarChar(codepoint: u32, x: f32, y: f32, color: [3]f32) void {
    if (codepoint < 32) return;
    const ch: Character = font.loadTitlebarGlyph(codepoint) orelse return;
    if (ch.region.width == 0 or ch.region.height == 0) return;

    if (ch.is_color) {
        const scale = font.g_titlebar_cell_height / @as(f32, @floatFromInt(ch.size_y));
        const w = @as(f32, @floatFromInt(ch.size_x)) * scale;
        const h = @as(f32, @floatFromInt(ch.size_y)) * scale;
        const atlas_size = if (font.g_color_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
        const uv = font.glyphUV(ch.region, atlas_size);
        ui_pipeline.drawColorGlyph(
            .{ .x = x, .y = y, .w = w, .h = h },
            .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
            font.g_color_atlas_texture,
            1.0,
        );
    } else {
        const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
        const y0 = y + font.g_titlebar_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
        const w = @as(f32, @floatFromInt(ch.size_x));
        const h = @as(f32, @floatFromInt(ch.size_y));
        const atlas_size = if (font.g_titlebar_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
        const uv = font.glyphUV(ch.region, atlas_size);
        ui_pipeline.drawGlyph(
            .{ .x = x0, .y = y0, .w = w, .h = h },
            .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
            font.g_titlebar_atlas_texture,
            color,
        );
    }
}

/// Prefix glyph for Alt+1…Alt+9 tab-switch hint (Unicode « ⌥ » OPTION KEY).
pub const tab_shortcut_modifier_cp: u32 = 0x2325;

/// Get the advance width of a titlebar glyph.
pub fn titlebarGlyphAdvance(codepoint: u32) f32 {
    if (font.loadTitlebarGlyph(codepoint)) |g| {
        const raw_advance = @as(f32, @floatFromInt(g.advance >> 6));
        if (g.is_color) {
            // Color emoji: scale advance to match the scaled-down rendering size
            const scale = font.g_titlebar_cell_height / @as(f32, @floatFromInt(g.size_y));
            return raw_advance * scale;
        }
        return raw_advance;
    }
    return font.g_titlebar_cell_width;
}

pub fn renderBellEmoji(x: f32, y: f32, opacity: f32) void {
    const bell = font.loadBellEmoji() orelse {
        renderTitlebarChar(0x1F514, x, y, .{ 1.0, 0.84, 0.0 });
        return;
    };
    const aspect = bell.bmp_w / bell.bmp_h;
    const h = font.g_titlebar_cell_height * 0.85;
    const w = h * aspect;
    const atlas_size = if (font.g_color_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = font.glyphUV(bell.region, atlas_size);
    ui_pipeline.drawColorGlyph(
        .{ .x = x, .y = y, .w = w, .h = h },
        .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
        font.g_color_atlas_texture,
        opacity,
    );
}

/// Render an icon glyph centered within a button rect, using the icon atlas.
pub fn renderIconGlyph(ch: Character, btn_x: f32, btn_y: f32, btn_w: f32, btn_h: f32, color: [3]f32, scale: f32) void {
    if (ch.region.width == 0 or ch.region.height == 0) return;
    const gw = @as(f32, @floatFromInt(ch.size_x)) * scale;
    const gh = @as(f32, @floatFromInt(ch.size_y)) * scale;
    const gx = btn_x + (btn_w - gw) / 2;
    const gy = btn_y + (btn_h - gh) / 2;
    const icon_atlas_size = if (font.g_icon_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = font.glyphUV(ch.region, icon_atlas_size);
    ui_pipeline.drawGlyph(
        .{ .x = gx, .y = gy, .w = gw, .h = gh },
        .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
        font.g_icon_atlas_texture,
        color,
    );
}

/// The app's own titlebar buttons: sidebar toggle, then settings, help,
/// Copilot and command center (Windows/Linux). With `window-show-toolbar =
/// hover` they fade toward the titlebar background by `opacity`; the caption
/// buttons, title and Update pill are drawn by the caller and never fade.
fn renderToolbarButtons(layout: titlebar_layout.TopBarLayout, titlebar_h: f32, top_bg: [3]f32, opacity: f32) void {
    if (opacity <= 0.01) return;
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const hover_bg = blend(top_bg, blend(bg, fg, 0.11), opacity);
    const icon_color = blend(top_bg, blend(bg, fg, 0.82), opacity);

    const toggle_x = layout.toggle_x;
    const toggle_hovered = mouseInTitlebarRange(titlebar_h, toggle_x, toggle_x + TITLEBAR_TOGGLE_W);
    if (toggle_hovered) {
        ui_pipeline.fillQuad(toggle_x, layout.top_y, TITLEBAR_TOGGLE_W, titlebar_h, hover_bg);
    }
    renderTitlebarIcon(.menu, .menu, toggle_x, layout.top_y, TITLEBAR_TOGGLE_W, titlebar_h, icon_color);

    const config_x = layout.config_x;
    if (TITLEBAR_CONFIG_W > 0) {
        const config_hovered = mouseInTitlebarRange(titlebar_h, config_x, config_x + TITLEBAR_CONFIG_W);
        if (config_hovered) {
            ui_pipeline.fillQuad(config_x, layout.top_y, TITLEBAR_CONFIG_W, titlebar_h, hover_bg);
        }
        renderTitlebarIcon(.settings, .settings, config_x, layout.top_y, TITLEBAR_CONFIG_W, titlebar_h, icon_color);
    }

    const help_x = layout.help_x;
    if (TITLEBAR_HELP_W > 0) {
        const help_hovered = mouseInTitlebarRange(titlebar_h, help_x, help_x + TITLEBAR_HELP_W);
        if (help_hovered) {
            ui_pipeline.fillQuad(help_x, layout.top_y, TITLEBAR_HELP_W, titlebar_h, hover_bg);
        }
        renderTitlebarIcon(.help, .help, help_x, layout.top_y, TITLEBAR_HELP_W, titlebar_h, icon_color);
    }

    const copilot_x = layout.copilot_x;
    if (TITLEBAR_COPILOT_W > 0) {
        const copilot_open = AppWindow.aiCopilotVisible();
        const copilot_usable = AppWindow.isActiveTabTerminal();
        const copilot_hovered = mouseInTitlebarRange(titlebar_h, copilot_x, copilot_x + TITLEBAR_COPILOT_W);
        if (copilot_hovered and copilot_usable) {
            ui_pipeline.fillQuad(copilot_x, layout.top_y, TITLEBAR_COPILOT_W, titlebar_h, hover_bg);
        }
        const copilot_tint = if (!copilot_usable)
            blend(top_bg, blend(bg, fg, 0.30), opacity) // dimmed: no terminal target
        else if (copilot_open)
            blend(top_bg, blend(bg, AppWindow.g_theme.cursor_color, 0.85), opacity) // active
        else
            icon_color;
        renderTitlebarIcon(.copilot, .copilot, copilot_x, layout.top_y, TITLEBAR_COPILOT_W, titlebar_h, copilot_tint);
    }

    const palette_x = layout.palette_x;
    if (TITLEBAR_PALETTE_W > 0) {
        const palette_hovered = mouseInTitlebarRange(titlebar_h, palette_x, palette_x + TITLEBAR_PALETTE_W);
        if (palette_hovered) {
            ui_pipeline.fillQuad(palette_x, layout.top_y, TITLEBAR_PALETTE_W, titlebar_h, hover_bg);
        }
        renderTitlebarIcon(.command_palette, .command_palette, palette_x, layout.top_y, TITLEBAR_PALETTE_W, titlebar_h, icon_color);
    }
}

/// Render the top bar: the sidebar toggle, the centered title, the toolbar
/// buttons and (where the app draws them) the caption buttons, plus the 1px
/// focus border. Tabs are not drawn here; they live in the sidebar
/// (`renderSidebar`). Draws nothing without a window.
///
/// OpenGL Y=0 is BOTTOM, so titlebar top = window_height - titlebar_h.
pub fn renderTitlebar(window_width: f32, window_height: f32, titlebar_h: f32) void {
    const win = AppWindow.g_window;
    text_hint.current.begin(window_width, window_height, if (win) |w| @floatFromInt(w.mouse_x) else -1, if (win) |w| window_height - @as(f32, @floatFromInt(w.mouse_y)) else -1);
    if (titlebar_h <= 0) return;
    // The ui_pipeline helpers are self-contained: each binds its own program and
    // vertex state per draw.

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    if (AppWindow.g_window != null) {
        const layout = titlebar_layout.topBarLayout(
            window_width,
            window_height,
            titlebar_h,
            titlebarLeftReserved(),
            TITLEBAR_TOGGLE_W,
            TITLEBAR_CONFIG_W,
            TITLEBAR_HELP_W,
            TITLEBAR_COPILOT_W,
            TITLEBAR_PALETTE_W,
            updatePillWidth(),
            window_backend.caption_button_visual_style.width,
        );
        const top_bg = blend(bg, fg, 0.04);
        const border_color_simple = blend(bg, .{ 0.0, 0.0, 0.0 }, 0.20);

        // WispTerm keeps terminal tabs in the application UI layer, matching
        // Ghostty's apprt action/tab-view split. The top bar now only hosts the
        // sidebar toggle and native caption buttons; tab navigation is rendered by
        // renderSidebar below.
        ui_pipeline.fillQuad(0, layout.top_y, window_width, titlebar_h, top_bg);
        ui_pipeline.fillQuad(0, layout.top_y, window_width, 1, border_color_simple);

        renderToolbarButtons(layout, titlebar_h, top_bg, toolbarOpacity());

        const top_hovered: window_backend.CaptionButton = if (AppWindow.g_window) |w| window_backend.hoveredCaptionButton(w) else .none;

        if (layout.update_w > 0) renderUpdatePill(layout.update_x, layout.top_y, layout.update_w, titlebar_h);

        if (tab.activeTab()) |active_tab| {
            const title = active_tab.getTitle();
            const text_y = layout.top_y + (titlebar_h - font.g_titlebar_cell_height) / 2;
            var latency_buf: [64]u8 = undefined;
            const latency = AppWindow.sshLatencyLabel(&latency_buf);
            const title_status = titlebar_layout.titleStatusLayout(
                layout.title_text_x,
                layout.title_text_max_w,
                titlebarTextWidth(latency),
                font.g_titlebar_cell_height / 2,
            );
            _ = renderTextLimited(title, layout.title_text_x, text_y, blend(bg, fg, 0.90), title_status.title_width);
            _ = renderTextLimited(latency, title_status.status_x, text_y, blend(bg, fg, 0.80), title_status.status_width);
        }

        renderCaptionButton(captionButtonVisual(.minimize, layout.caption_buttons.minimize, top_hovered == .minimize));
        renderCaptionButton(captionButtonVisual(.maximize, layout.caption_buttons.maximize, top_hovered == .maximize));
        renderCaptionButton(captionButtonVisual(.close, layout.caption_buttons.close, top_hovered == .close));

        {
            const is_focused = if (AppWindow.g_window) |w| window_backend.isFocused(w) else false;
            const is_maximized = currentWindowIsMaximized();
            if (is_focused and !is_maximized) {
                const b: f32 = 1;
                ui_pipeline.fillQuad(0, 0, window_width, b, bg);
                ui_pipeline.fillQuad(0, window_height - b, window_width, b, bg);
                ui_pipeline.fillQuad(0, 0, b, window_height, bg);
                ui_pipeline.fillQuad(window_width - b, 0, b, window_height, bg);
            }
        }
    }
}

/// Render the left tab sidebar. The top titlebar remains separate so native
/// caption hit-testing stays simple.
pub fn renderSidebar(window_width: f32, window_height: f32, titlebar_h: f32) void {
    _ = window_width;
    if (!tab.g_sidebar_visible) return;
    const sidebar_w = sidebarWidth();

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const sidebar_bg = blend(bg, fg, 0.035);
    const hover_bg = blend(bg, fg, 0.09);
    const active_bg = blend(bg, accent, 0.16);
    const border_color = blend(bg, .{ 0.0, 0.0, 0.0 }, 0.20);
    const text_active = fg;
    const text_inactive = blend(bg, fg, 0.88);
    const muted = blend(bg, fg, 0.76);
    const header_text = blend(bg, fg, 0.84);

    const side_h = window_height - titlebar_h;
    if (side_h <= 0) return;

    const half_resize_hit = SIDEBAR_RESIZE_HIT_WIDTH / 2;
    const resize_hovered = mouseInRect(sidebar_w - half_resize_hit, titlebar_h, SIDEBAR_RESIZE_HIT_WIDTH, window_height - titlebar_h);
    const edge_color = if (resize_hovered) blend(bg, accent, 0.38) else border_color;

    ui_pipeline.fillQuad(0, 0, sidebar_w, side_h, sidebar_bg);
    ui_pipeline.fillQuad(sidebar_w - 1, 0, if (resize_hovered) 2 else 1, side_h, edge_color);

    const header_h = sidebarHeaderHeight();
    const row_h_full = sidebarRowHeight();
    const plus_btn_w: f32 = 42;
    const header = titlebar_layout.sidebarHeaderLayout(
        window_height,
        titlebar_h,
        sidebar_w,
        header_h,
        14,
        plus_btn_w,
        6,
        font.g_titlebar_cell_height,
    );
    _ = renderTextLimited("Tabs", header.title_x, header.title_y, header_text, header.title_max_w);
    // The new-tab button is part of the hover-revealed toolbar.
    const toolbar_opacity = toolbarOpacity();
    if (toolbar_opacity > 0.01) {
        const plus_hovered = mouseInRect(header.plus_x, header.top_px, header.plus_w, header.plus_h);
        if (plus_hovered) {
            ui_pipeline.fillQuad(header.plus_x, header.plus_y + 4, header.plus_w, header.plus_h - 8, blend(sidebar_bg, hover_bg, toolbar_opacity));
        }
        renderPlusIcon(header.plus_x, header.plus_y, header.plus_w, header.plus_h, blend(sidebar_bg, text_active, toolbar_opacity));
    }
    ui_pipeline.fillQuad(0, header.rule_y, sidebar_w, 1, border_color);

    const now_ms = std.time.milliTimestamp();
    const dt: f32 = if (tab.g_last_frame_time_ms > 0)
        @as(f32, @floatFromInt(now_ms - tab.g_last_frame_time_ms)) / 1000.0
    else
        0.016;
    tab.g_last_frame_time_ms = now_ms;

    for (0..tab.MAX_TABS) |tab_idx| {
        tab.g_tab_text_x_start[tab_idx] = 0;
        tab.g_tab_text_x_end[tab_idx] = 0;
        tab.g_tab_text_y_start[tab_idx] = 0;
        tab.g_tab_text_y_end[tab_idx] = 0;
    }

    const number_x: f32 = 14;
    const number_w = sidebarTabNumberWidth();

    for (0..tab.g_tab_count) |tab_idx| {
        const base_row = titlebar_layout.sidebarTabRowLayout(
            window_height,
            titlebar_h,
            header_h,
            row_h_full,
            sidebar_w,
            tab_idx,
            number_x,
            number_w,
            tab.TAB_CLOSE_BTN_W,
            font.g_titlebar_cell_height,
            false,
            0,
            false,
        ) orelse break;
        const is_active = tab_idx == active_tab_state.g_active_tab;

        if (tab.g_tabs[tab_idx]) |tb| {
            if (tb.focusedSurface()) |surface| {
                if (surface.bell_indicator) {
                    surface.bell_opacity = @min(1.0, surface.bell_opacity + tab.TAB_CLOSE_FADE_SPEED * dt);
                    if (is_active and surface.bell_opacity >= 1.0 and now_ms - surface.bell_indicator_time >= 1000) {
                        surface.bell_indicator = false;
                    }
                } else {
                    surface.bell_opacity = @max(0.0, surface.bell_opacity - tab.TAB_CLOSE_FADE_SPEED * dt);
                }
            }
        }

        // Use aggregate of all panes' visible states (plus in-app AI sessions)
        // so the sidebar badge reflects the most attention-worthy agent across
        // all split panes, not just the focused one.
        const detection = if (!tab.g_tab_rename_active) blk: {
            if (tab.g_tabs[tab_idx]) |t| break :blk t.agentDetection();
            break :blk agent_detector.Detection{};
        } else agent_detector.Detection{};
        const show_agent_badge = detection.visible();
        var agent_badge_w: f32 = 0;
        if (show_agent_badge) {
            const badge_text_w = titlebarTextWidth(detection.badge());
            agent_badge_w = @max(@as(f32, 18), badge_text_w + 10);
        }

        const bell_opacity: f32 = if (tab.g_tabs[tab_idx]) |t| (if (t.focusedSurface()) |s| s.bell_opacity else 0) else 0;
        const show_bell = bell_opacity > 0.01;
        const row = titlebar_layout.sidebarTabRowLayout(
            window_height,
            titlebar_h,
            header_h,
            row_h_full,
            sidebar_w,
            tab_idx,
            number_x,
            number_w,
            tab.TAB_CLOSE_BTN_W,
            font.g_titlebar_cell_height,
            show_agent_badge,
            agent_badge_w,
            show_bell,
        ) orelse base_row;

        const row_hovered = mouseInRect(0, row.row_top_px, sidebar_w, row.row_h);

        if (tab.g_tab_count > 1) {
            if (row_hovered) {
                tab.g_tab_close_opacity[tab_idx] = @min(1.0, tab.g_tab_close_opacity[tab_idx] + tab.TAB_CLOSE_FADE_SPEED * dt);
            } else {
                tab.g_tab_close_opacity[tab_idx] = @max(0.0, tab.g_tab_close_opacity[tab_idx] - tab.TAB_CLOSE_FADE_SPEED * dt);
            }
        } else {
            tab.g_tab_close_opacity[tab_idx] = 0;
        }

        const visual = titlebar_layout.sidebarTabVisual(.{
            .row = row,
            .active = is_active,
            .hovered = row_hovered,
            .tab_count = tab.g_tab_count,
            .close_opacity = tab.g_tab_close_opacity[tab_idx],
            .mouse_x = mouseX(),
            .close_btn_w = tab.TAB_CLOSE_BTN_W,
        });

        if (visual.draw_active_background) {
            ui_pipeline.fillQuad(0, row.row_y, sidebar_w, row.row_h, active_bg);
            ui_pipeline.fillQuad(row.active_marker_x, row.active_marker_y, row.active_marker_w, row.active_marker_h, AppWindow.g_theme.cursor_color);
        } else if (visual.draw_hover_background) {
            ui_pipeline.fillQuad(0, row.row_y, sidebar_w, row.row_h, hover_bg);
        }

        var prefix_buf: [8]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{d}", .{tab_idx + 1}) catch "";
        const number_color = switch (visual.number_tone) {
            .active => text_active,
            .inactive => text_inactive,
            .muted => muted,
        };
        _ = renderTextLimited(prefix, row.number_x, row.text_y, number_color, row.number_w);

        const title = if (tab.g_tab_rename_active and tab_idx == tab.g_tab_rename_idx)
            tab.g_tab_rename_buf[0..tab.g_tab_rename_len]
        else if (tab.g_tabs[tab_idx]) |t|
            t.getTitle()
        else
            "New Tab";

        const close_opacity = visual.close_opacity;
        const title_color = switch (visual.title_tone) {
            .active => text_active,
            .inactive => text_inactive,
            .muted => muted,
        };
        const text_end = renderTextLimited(title, row.title_x, row.text_y, title_color, row.title_max_w);

        if (tab.g_tab_rename_active and tab_idx == tab.g_tab_rename_idx and AppWindow.g_cursor_blink_visible) {
            ui_pipeline.fillQuad(@min(text_end + 1, row.title_x + row.title_max_w), row.text_y, 1, font.g_titlebar_cell_height, text_active);
        }

        if (show_bell) {
            renderBellEmoji(row.bell_x, row.text_y, bell_opacity);
        }
        if (show_agent_badge) {
            _ = renderAgentBadge(detection, row.badge_x, row.text_y, is_active);
        }

        if (visual.draw_close) {
            const raw_color = if (visual.close_hovered) text_active else muted;
            const close_color = [3]f32{
                raw_color[0] * close_opacity + sidebar_bg[0] * (1 - close_opacity),
                raw_color[1] * close_opacity + sidebar_bg[1] * (1 - close_opacity),
                raw_color[2] * close_opacity + sidebar_bg[2] * (1 - close_opacity),
            };
            if (visual.draw_close_hover_background) {
                ui_pipeline.fillQuad(row.close_hover_x, row.close_hover_y, row.close_hover_w, row.close_hover_h, blend(bg, fg, 0.14));
            }
            renderCloseIcon(row.close_x, row.row_y, tab.TAB_CLOSE_BTN_W, row.row_h, close_color);
        }

        tab.g_tab_text_x_start[tab_idx] = row.title_x;
        tab.g_tab_text_x_end[tab_idx] = text_end;
        tab.g_tab_text_y_start[tab_idx] = row.row_top_px;
        tab.g_tab_text_y_end[tab_idx] = row.row_top_px + row.row_h;
    }
}

/// Draw a native caption button with hover support.
/// Platform/window provides the concrete colors and metrics.
pub fn renderCaptionButton(button: titlebar_layout.CaptionButtonVisual) void {
    const rect = button.rect;
    if (rect.w <= 0 or rect.h <= 0) return;

    const visual = window_backend.caption_button_visual_style;
    // Draw hover background, respecting the 1px focus border on edges
    if (button.hovered) {
        const hover_bg = switch (button.kind) {
            .close => visual.close_hover_background,
            else => [3]f32{
                @min(1.0, AppWindow.g_theme.background[0] + visual.hover_background_delta),
                @min(1.0, AppWindow.g_theme.background[1] + visual.hover_background_delta),
                @min(1.0, AppWindow.g_theme.background[2] + visual.hover_background_delta),
            },
        };
        const hover = button.hover_rect;
        ui_pipeline.fillQuad(hover.x, hover.y, hover.w, hover.h, hover_bg);
    }

    const icon_color: [3]f32 = if (button.hovered) visual.hover_icon_color else visual.icon_color;
    const icon_codepoint = font_backend.titlebarIconGlyph(captionIconGlyph(button.icon));

    // Try rendering from the platform caption icon font.
    if (font.icon_face != null) {
        if (font.loadIconGlyph(icon_codepoint)) |ch| {
            renderIconGlyph(ch, rect.x, rect.y, rect.w, rect.h, icon_color, 1.0);
            return;
        }
    }

    const kind: chrome_icons.Kind = switch (button.icon) {
        .close => .close,
        .maximize => .maximize,
        .restore => .restore,
        .minimize => .minimize,
    };
    renderChromeIcon(kind, rect.x, rect.y, rect.w, rect.h, icon_color);
}
