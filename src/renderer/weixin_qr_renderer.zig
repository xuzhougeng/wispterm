//! Renderer for the WeChat QR login panel.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const qr_panel = @import("../weixin/qr_panel.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const gl_init = AppWindow.gpu.gl_init;

const c = AppWindow.gpu.c;

fn mix(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const amount = @max(0.0, @min(1.0, t));
    const inv = 1.0 - amount;
    return .{
        a[0] * inv + b[0] * amount,
        a[1] * inv + b[1] * amount,
        a[2] * inv + b[2] * amount,
    };
}

fn textWidth(text: []const u8) f32 {
    var width: f32 = 0;
    const view = std.unicode.Utf8View.init(text) catch {
        for (text) |byte| width += titlebar.titlebarGlyphAdvance(if (byte >= 0x20 and byte <= 0x7e) byte else '?');
        return width;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| width += titlebar.titlebarGlyphAdvance(cp);
    return width;
}

fn textYFromTop(window_height: f32, top_px: f32) f32 {
    return @round(window_height - top_px - font.g_titlebar_cell_height);
}

fn rectY(window_height: f32, rect: qr_panel.Rect) f32 {
    return @round(window_height - rect.top_px - rect.h);
}

pub fn render(window_width: f32, window_height: f32, top_offset: f32) void {
    if (!qr_panel.visible()) return;

    const allocator = AppWindow.g_allocator orelse std.heap.page_allocator;
    if (qr_panel.refresh(allocator)) {
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }
    if (!qr_panel.visible()) return;

    AppWindow.gpu.state.setBlendEnabled(true);
    AppWindow.gpu.state.setBlendMode(.alpha);

    const l = qr_panel.layout(window_width, window_height, top_offset);
    const panel_y = rectY(window_height, l.panel);
    const qr_y = rectY(window_height, l.qr);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_bg = mix(bg, fg, 0.045);
    const panel_border = mix(bg, fg, 0.22);
    const qr_bg = .{ 0.96, 0.97, 0.98 };
    const qr_border = mix(bg, fg, 0.30);
    const normal = mix(bg, fg, 0.90);
    const muted = mix(bg, fg, 0.62);
    const danger = .{ 0.88, 0.28, 0.24 };

    AppWindow.overlays.renderRoundedQuadAlpha(0, 0, window_width, window_height, 1, .{ 0.0, 0.0, 0.0 }, 0.28);
    AppWindow.overlays.renderRoundedQuadAlpha(l.panel.x - 1, panel_y - 1, l.panel.w + 2, l.panel.h + 2, 10, panel_border, 0.50);
    AppWindow.overlays.renderRoundedQuadAlpha(l.panel.x, panel_y, l.panel.w, l.panel.h, 9, panel_bg, 0.98);

    const pad_x: f32 = 28;
    const title_y = textYFromTop(window_height, l.panel.top_px + 24);
    _ = titlebar.renderTextLimited("Connect WeChat", l.panel.x + pad_x, title_y, normal, l.panel.w - pad_x * 2);

    const status_label = qr_panel.statusLabel(qr_panel.status());
    const status_color = switch (qr_panel.status()) {
        .expired => danger,
        .confirmed => accent,
        .scaned => accent,
        else => normal,
    };
    const status_y = textYFromTop(window_height, l.panel.top_px + 60);
    _ = titlebar.renderTextLimited(status_label, l.panel.x + pad_x, status_y, status_color, l.panel.w - pad_x * 2);

    const detail_y = textYFromTop(window_height, l.panel.top_px + 94);
    _ = titlebar.renderTextLimited(qr_panel.statusDetail(qr_panel.status()), l.panel.x + pad_x, detail_y, muted, l.panel.w - pad_x * 2);

    gl_init.renderQuadAlpha(l.qr.x - 10, qr_y - 10, l.qr.w + 20, l.qr.h + 20, qr_border, 0.42);
    gl_init.renderQuadAlpha(l.qr.x - 8, qr_y - 8, l.qr.w + 16, l.qr.h + 16, qr_bg, 1.0);

    if (qr_panel.qrMatrix()) |matrix| {
        renderQrMatrix(matrix, l.qr, window_height);
    } else {
        renderQrFallback(l, window_height, normal, muted);
    }

    const button_top = l.close.top_px;
    const hint_y = textYFromTop(window_height, button_top - 34);
    _ = titlebar.renderTextLimited("Token is saved locally after confirmation.", l.panel.x + pad_x, hint_y, muted, l.panel.w - pad_x * 2);

    if (qr_panel.status() == .expired) {
        renderButton(l.retry, window_height, "Retry", accent, .{ 1.0, 1.0, 1.0 }, true);
    }
    renderButton(l.unbind, window_height, "Unbind", danger, .{ 1.0, 1.0, 1.0 }, false);
    renderButton(l.close, window_height, "Close", panel_border, normal, false);
}

fn renderQrMatrix(matrix: qr_panel.QrMatrixView, rect: qr_panel.Rect, window_height: f32) void {
    const quiet_modules: usize = 4;
    const total_modules = matrix.size + quiet_modules * 2;
    const module_px = @max(1.0, @floor(rect.w / @as(f32, @floatFromInt(total_modules))));
    const draw_size = module_px * @as(f32, @floatFromInt(total_modules));
    const start_x = @round(rect.x + (rect.w - draw_size) / 2.0 + module_px * @as(f32, @floatFromInt(quiet_modules)));
    const start_top = @round(rect.top_px + (rect.h - draw_size) / 2.0 + module_px * @as(f32, @floatFromInt(quiet_modules)));

    const black = .{ 0.03, 0.04, 0.05 };
    for (0..matrix.size) |y| {
        const y_top = start_top + module_px * @as(f32, @floatFromInt(y));
        const gl_y = @round(window_height - y_top - module_px);
        for (0..matrix.size) |x| {
            if (!matrix.isBlack(x, y)) continue;
            const gl_x = start_x + module_px * @as(f32, @floatFromInt(x));
            gl_init.renderQuadAlpha(gl_x, gl_y, module_px, module_px, black, 1.0);
        }
    }
}

fn renderQrFallback(l: qr_panel.Layout, window_height: f32, normal: [3]f32, muted: [3]f32) void {
    const qr_y = rectY(window_height, l.qr);
    const message = if (qr_panel.qrGenerationFailed())
        "QR code could not be generated"
    else
        "Requesting QR code...";

    const msg_w = textWidth(message);
    const msg_y = qr_y + l.qr.h * 0.52;
    _ = titlebar.renderTextLimited(message, l.qr.x + @max(8.0, (l.qr.w - msg_w) / 2.0), msg_y, normal, l.qr.w - 16);

    const qr_text = qr_panel.qrString();
    if (qr_panel.qrGenerationFailed() and qr_text.len > 0) {
        const text_y = msg_y - font.g_titlebar_cell_height - 10;
        _ = titlebar.renderTextLimited(qr_text, l.qr.x + 12, text_y, muted, l.qr.w - 24);
    }
}

fn renderButton(rect: qr_panel.Rect, window_height: f32, label: []const u8, base: [3]f32, text_color: [3]f32, primary: bool) void {
    const y = rectY(window_height, rect);
    const bg = if (primary) base else mix(AppWindow.g_theme.background, base, 0.30);
    const border = if (primary) mix(base, .{ 1.0, 1.0, 1.0 }, 0.18) else base;
    AppWindow.overlays.renderRoundedQuadAlpha(rect.x - 1, y - 1, rect.w + 2, rect.h + 2, 6, border, if (primary) 0.74 else 0.42);
    AppWindow.overlays.renderRoundedQuadAlpha(rect.x, y, rect.w, rect.h, 5, bg, if (primary) 0.92 else 0.58);

    const label_w = textWidth(label);
    const text_y = @round(y + (rect.h - font.g_titlebar_cell_height) / 2.0);
    _ = titlebar.renderTextLimited(label, rect.x + @max(8.0, (rect.w - label_w) / 2.0), text_y, text_color, rect.w - 16);
}

pub fn deinit() void {}
