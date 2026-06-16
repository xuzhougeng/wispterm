//! Minimal hover-tooltip primitive: a rounded background quad + one line of
//! titlebar-glyph text. The app has no general tooltip system; this is scoped to
//! the Copilot edge handle for now and is reusable by other hover targets later.
//! Coordinates are GL bottom-left origin (the space overlays render in).
const std = @import("std");
const AppWindow = @import("../../AppWindow.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const primitives = @import("primitives.zig");

pub const Side = enum { left, right };

fn measure(text: []const u8) f32 {
    var w: f32 = 0;
    var view = std.unicode.Utf8View.init(text) catch {
        for (text) |ch| w += titlebar.titlebarGlyphAdvance(@intCast(ch));
        return w;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| w += titlebar.titlebarGlyphAdvance(cp);
    return w;
}

fn drawText(text: []const u8, x_start: f32, y: f32, color: [3]f32) void {
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

/// Draw `text` in a small rounded box whose vertical center is `anchor_y_center`,
/// placed `side` of `anchor_x`.
pub fn render(text: []const u8, anchor_x: f32, anchor_y_center: f32, side: Side, alpha: f32) void {
    if (alpha <= 0.01 or text.len == 0) return;
    const pad_x: f32 = 10;
    const pad_y: f32 = 6;
    const gap: f32 = 8;
    const text_h = @max(1.0, font.g_titlebar_cell_height);
    const text_w = measure(text);
    const box_w = text_w + pad_x * 2;
    const box_h = text_h + pad_y * 2;
    const box_x = switch (side) {
        .left => anchor_x - gap - box_w,
        .right => anchor_x + gap,
    };
    const box_y = anchor_y_center - box_h / 2;

    const bg = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, 0.10);
    const border = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.cursor_color, 0.30);
    primitives.renderRoundedQuadAlpha(box_x - 1, box_y - 1, box_w + 2, box_h + 2, 7, border, alpha * 0.5);
    primitives.renderRoundedQuadAlpha(box_x, box_y, box_w, box_h, 6, bg, alpha * 0.97);
    const fg = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, alpha);
    drawText(text, box_x + pad_x, box_y + pad_y, fg);
}
