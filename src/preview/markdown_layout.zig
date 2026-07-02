//! Backend-neutral geometry for the right-side markdown/text/image preview pane.
//!
//! The renderer consumes these rectangles in GL-style bottom-left coordinates
//! while document layout still uses top-down pixel offsets. Keeping both in one
//! pure model lets OpenGL, Metal, and D3D11 share the same panel geometry.

const std = @import("std");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Input = struct {
    panel_x: f32,
    panel_top: f32,
    panel_w: f32,
    panel_h: f32,
    window_height: f32,
    header_h: f32,
    footer_h: f32,
    pad_x: f32,
    pad_y: f32,
};

pub const StatusLine = struct {
    rect: Rect,
    text_y: f32,
};

pub const Panel = struct {
    panel_x: f32,
    panel_top: f32,
    panel_w: f32,
    panel_h: f32,
    window_height: f32,
    pane_gl_bottom: f32,
    content_x: f32,
    content_w: f32,
    body_top: f32,
    body_h: f32,
    background: Rect,
    header: Rect,
    header_rule: Rect,
    footer: Rect,
    footer_rule: Rect,

    pub fn contentRight(self: Panel) f32 {
        return self.content_x + self.content_w;
    }

    pub fn headerTextY(self: Panel, text_h: f32) f32 {
        return self.header.y + (self.header.h - text_h) / 2;
    }

    pub fn footerTextY(self: Panel, text_h: f32) f32 {
        return self.footer.y + (self.footer.h - text_h) / 2;
    }

    pub fn bodyAvailable(self: Panel) bool {
        return self.body_h > 0;
    }

    pub fn statusLine(self: Panel, row_h: f32, text_h: f32) StatusLine {
        const y_top = self.body_top + @max(@as(f32, 0), (self.body_h - row_h) / 2);
        const gl_y = self.window_height - y_top - row_h;
        return .{
            .rect = .{ .x = self.content_x, .y = gl_y, .w = self.content_w, .h = row_h },
            .text_y = gl_y + (row_h - text_h) / 2,
        };
    }
};

pub fn compute(input: Input) ?Panel {
    if (input.panel_w <= 0 or input.panel_h <= 0 or input.window_height <= 0) return null;

    const pane_gl_bottom = input.window_height - input.panel_top - input.panel_h;
    const body_top = input.panel_top + input.header_h + input.pad_y;
    const body_bottom_margin = pane_gl_bottom + input.footer_h + input.pad_y;
    const body_h = input.window_height - body_top - body_bottom_margin;

    return .{
        .panel_x = input.panel_x,
        .panel_top = input.panel_top,
        .panel_w = input.panel_w,
        .panel_h = input.panel_h,
        .window_height = input.window_height,
        .pane_gl_bottom = pane_gl_bottom,
        .content_x = input.panel_x + input.pad_x,
        .content_w = input.panel_w - input.pad_x * 2,
        .body_top = body_top,
        .body_h = body_h,
        .background = .{
            .x = input.panel_x,
            .y = pane_gl_bottom,
            .w = input.panel_w,
            .h = input.panel_h,
        },
        .header = .{
            .x = input.panel_x,
            .y = input.window_height - input.panel_top - input.header_h,
            .w = input.panel_w,
            .h = input.header_h,
        },
        .header_rule = .{
            .x = input.panel_x,
            .y = input.window_height - input.panel_top - input.header_h,
            .w = input.panel_w,
            .h = 1,
        },
        .footer = .{
            .x = input.panel_x,
            .y = pane_gl_bottom,
            .w = input.panel_w,
            .h = input.footer_h,
        },
        .footer_rule = .{
            .x = input.panel_x,
            .y = pane_gl_bottom + input.footer_h - 1,
            .w = input.panel_w,
            .h = 1,
        },
    };
}

test "markdown_layout: compute maps pane chrome into GL rectangles" {
    const p = compute(.{
        .panel_x = 100,
        .panel_top = 50,
        .panel_w = 320,
        .panel_h = 500,
        .window_height = 720,
        .header_h = 36,
        .footer_h = 44,
        .pad_x = 16,
        .pad_y = 18,
    }).?;

    try std.testing.expectApproxEqAbs(@as(f32, 170), p.pane_gl_bottom, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 170), p.background.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 634), p.header.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 170), p.footer.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 116), p.content_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 288), p.content_w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 104), p.body_top, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 384), p.body_h, 0.001);
}

test "markdown_layout: text baselines stay centered in chrome bands" {
    const p = compute(.{
        .panel_x = 0,
        .panel_top = 40,
        .panel_w = 240,
        .panel_h = 360,
        .window_height = 500,
        .header_h = 32,
        .footer_h = 44,
        .pad_x = 16,
        .pad_y = 18,
    }).?;

    try std.testing.expectApproxEqAbs(p.header.y + 6, p.headerTextY(20), 0.001);
    try std.testing.expectApproxEqAbs(p.footer.y + 12, p.footerTextY(20), 0.001);
}

test "markdown_layout: status line centers in the body viewport" {
    const p = compute(.{
        .panel_x = 10,
        .panel_top = 30,
        .panel_w = 260,
        .panel_h = 420,
        .window_height = 600,
        .header_h = 36,
        .footer_h = 44,
        .pad_x = 20,
        .pad_y = 16,
    }).?;
    const line = p.statusLine(24, 18);

    try std.testing.expectApproxEqAbs(@as(f32, 30), line.rect.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 220), line.rect.w, 0.001);
    try std.testing.expect(line.rect.y > p.footer.y + p.footer.h);
    try std.testing.expect(line.rect.y + line.rect.h < p.header.y);
    try std.testing.expectApproxEqAbs(line.rect.y + 3, line.text_y, 0.001);
}
