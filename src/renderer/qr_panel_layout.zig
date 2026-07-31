//! Pure renderer-side geometry helpers shared by QR panels.
//!
//! The WeChat and Feishu QR panels own their UI state and panel layout. This
//! module handles only the renderer math both panels need after that: converting
//! top-down rectangles to bottom-up draw coordinates, centering QR modules with
//! quiet-zone padding, and placing button labels.

const std = @import("std");

pub const Rect = struct {
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
};

pub const ModuleRect = struct {
    x: f32,
    y: f32,
    size: f32,
};

pub const QrModules = struct {
    quiet_modules: usize,
    total_modules: usize,
    module_px: f32,
    draw_size: f32,
    start_x: f32,
    start_top_px: f32,

    pub fn moduleRect(self: QrModules, window_height: f32, x: usize, y: usize) ModuleRect {
        const top_px = self.start_top_px + self.module_px * @as(f32, @floatFromInt(y));
        return .{
            .x = self.start_x + self.module_px * @as(f32, @floatFromInt(x)),
            .y = @round(window_height - top_px - self.module_px),
            .size = self.module_px,
        };
    }
};

pub const ButtonLabel = struct {
    x: f32,
    y: f32,
    max_w: f32,
};

pub const DrawRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const PanelChrome = struct {
    scrim: DrawRect,
    border: DrawRect,
    panel: DrawRect,
};

pub const QrFrame = struct {
    border: DrawRect,
    fill: DrawRect,
};

pub fn rectY(window_height: f32, rect: anytype) f32 {
    return @round(window_height - rect.top_px - rect.h);
}

pub fn textYFromTop(window_height: f32, top_px: f32, cell_h: f32) f32 {
    return @round(window_height - top_px - cell_h);
}

pub fn qrModules(rect: anytype, matrix_size: usize) QrModules {
    const quiet_modules: usize = 4;
    const total_modules = matrix_size + quiet_modules * 2;
    const module_px = @max(1.0, @floor(rect.w / @as(f32, @floatFromInt(total_modules))));
    const draw_size = module_px * @as(f32, @floatFromInt(total_modules));
    return .{
        .quiet_modules = quiet_modules,
        .total_modules = total_modules,
        .module_px = module_px,
        .draw_size = draw_size,
        .start_x = @round(rect.x + (rect.w - draw_size) / 2.0 + module_px * @as(f32, @floatFromInt(quiet_modules))),
        .start_top_px = @round(rect.top_px + (rect.h - draw_size) / 2.0 + module_px * @as(f32, @floatFromInt(quiet_modules))),
    };
}

pub fn panelChrome(rect: anytype, window_width: f32, window_height: f32) PanelChrome {
    const y = rectY(window_height, rect);
    return .{
        .scrim = .{ .x = 0, .y = 0, .w = window_width, .h = window_height },
        .border = .{ .x = rect.x - 1, .y = y - 1, .w = rect.w + 2, .h = rect.h + 2 },
        .panel = .{ .x = rect.x, .y = y, .w = rect.w, .h = rect.h },
    };
}

pub fn qrFrame(rect: anytype, window_height: f32) QrFrame {
    const y = rectY(window_height, rect);
    return .{
        .border = .{ .x = rect.x - 10, .y = y - 10, .w = rect.w + 20, .h = rect.h + 20 },
        .fill = .{ .x = rect.x - 8, .y = y - 8, .w = rect.w + 16, .h = rect.h + 16 },
    };
}

pub fn fallbackMessage(rect: anytype, window_height: f32, label_w: f32) ButtonLabel {
    const y = rectY(window_height, rect) + rect.h * 0.52;
    return .{
        .x = rect.x + @max(8.0, (rect.w - label_w) / 2.0),
        .y = y,
        .max_w = @max(1.0, rect.w - 16.0),
    };
}

pub fn fallbackDetail(rect: anytype, window_height: f32, cell_h: f32) ButtonLabel {
    const message = fallbackMessage(rect, window_height, 0);
    return .{
        .x = rect.x + 12.0,
        .y = message.y - cell_h - 10.0,
        .max_w = @max(1.0, rect.w - 24.0),
    };
}

pub fn buttonLabel(rect: anytype, window_height: f32, cell_h: f32, label_w: f32) ButtonLabel {
    const y = rectY(window_height, rect);
    return .{
        .x = rect.x + @max(8.0, (rect.w - label_w) / 2.0),
        .y = @round(y + (rect.h - cell_h) / 2.0),
        .max_w = @max(1.0, rect.w - 16.0),
    };
}

test "rectY converts top-down panel rects to bottom-up draw coordinates" {
    const rect = Rect{ .x = 10, .top_px = 100, .w = 80, .h = 40 };
    try std.testing.expectEqual(@as(f32, 460), rectY(600, rect));
}

test "qr modules are centered with a four-module quiet zone" {
    const rect = Rect{ .x = 100, .top_px = 120, .w = 292, .h = 292 };
    const layout = qrModules(rect, 21);

    try std.testing.expectEqual(@as(usize, 4), layout.quiet_modules);
    try std.testing.expectEqual(@as(usize, 29), layout.total_modules);
    try std.testing.expectEqual(@as(f32, 10), layout.module_px);
    try std.testing.expectEqual(@as(f32, 290), layout.draw_size);
    try std.testing.expectEqual(@as(f32, 141), layout.start_x);
    try std.testing.expectEqual(@as(f32, 161), layout.start_top_px);

    const first = layout.moduleRect(600, 0, 0);
    try std.testing.expectEqual(@as(f32, 141), first.x);
    try std.testing.expectEqual(@as(f32, 429), first.y);
    try std.testing.expectEqual(@as(f32, 10), first.size);
}

test "small QR rect still keeps at least one pixel per module" {
    const rect = Rect{ .x = 0, .top_px = 0, .w = 20, .h = 20 };
    const layout = qrModules(rect, 177);
    try std.testing.expectEqual(@as(f32, 1), layout.module_px);
    try std.testing.expect(layout.draw_size > rect.w);
}

test "panel chrome converts shared QR panel surfaces to draw rectangles" {
    const rect = Rect{ .x = 90, .top_px = 80, .w = 320, .h = 440 };
    const chrome = panelChrome(rect, 900, 700);

    try std.testing.expectEqual(DrawRect{ .x = 0, .y = 0, .w = 900, .h = 700 }, chrome.scrim);
    try std.testing.expectEqual(DrawRect{ .x = 89, .y = 179, .w = 322, .h = 442 }, chrome.border);
    try std.testing.expectEqual(DrawRect{ .x = 90, .y = 180, .w = 320, .h = 440 }, chrome.panel);
}

test "QR frame expands the matrix area consistently" {
    const rect = Rect{ .x = 140, .top_px = 150, .w = 260, .h = 260 };
    const frame = qrFrame(rect, 640);

    try std.testing.expectEqual(DrawRect{ .x = 130, .y = 220, .w = 280, .h = 280 }, frame.border);
    try std.testing.expectEqual(DrawRect{ .x = 132, .y = 222, .w = 276, .h = 276 }, frame.fill);
}

test "fallback labels share centered message and detail geometry" {
    const rect = Rect{ .x = 120, .top_px = 200, .w = 240, .h = 250 };
    const message = fallbackMessage(rect, 700, 96);
    const detail = fallbackDetail(rect, 700, 22);

    try std.testing.expectEqual(@as(f32, 192), message.x);
    try std.testing.expectEqual(@as(f32, 380), message.y);
    try std.testing.expectEqual(@as(f32, 224), message.max_w);
    try std.testing.expectEqual(@as(f32, 132), detail.x);
    try std.testing.expectEqual(@as(f32, 348), detail.y);
    try std.testing.expectEqual(@as(f32, 216), detail.max_w);
}

test "button label centers text and reserves horizontal padding" {
    const rect = Rect{ .x = 50, .top_px = 400, .w = 118, .h = 38 };
    const label = buttonLabel(rect, 600, 20, 48);
    try std.testing.expectEqual(@as(f32, 85), label.x);
    try std.testing.expectEqual(@as(f32, 171), label.y);
    try std.testing.expectEqual(@as(f32, 102), label.max_w);
}
