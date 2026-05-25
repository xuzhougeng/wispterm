//! UI-thread state for the WeChat QR login panel.
//!
//! The controller owns the network/login thread; this module only snapshots its
//! login state, keeps an owned copy of the QR payload for rendering, and exposes
//! layout/hit-test helpers for the renderer/input layers.

const std = @import("std");
const controller_mod = @import("controller.zig");
const qr_code = @import("qr_code.zig");
const types = @import("types.zig");

pub const Controller = controller_mod.Controller;

pub const Action = enum {
    none,
    retry,
    close,
    unbind,
};

pub const Rect = struct {
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
};

pub const Layout = struct {
    panel: Rect,
    qr: Rect,
    retry: Rect,
    close: Rect,
    unbind: Rect,
};

pub const QrMatrixView = struct {
    size: usize,
    modules: []const u8,

    pub fn isBlack(self: QrMatrixView, x: usize, y: usize) bool {
        return x < self.size and y < self.size and self.modules[y * self.size + x] != 0;
    }
};

const PANEL_MIN_W: f32 = 380;
const PANEL_MAX_W: f32 = 900;
const PANEL_MIN_H: f32 = 500;
const PANEL_MAX_H: f32 = 620;
const PANEL_MARGIN: f32 = 24;
const BUTTON_H: f32 = 38;
const BUTTON_W: f32 = 118;
const BUTTON_GAP: f32 = 10;

pub threadlocal var g_visible: bool = false;
threadlocal var g_controller: ?*Controller = null;
threadlocal var g_status: types.QrStatusKind = .unknown;
threadlocal var g_qr_string: ?[]u8 = null;
threadlocal var g_qr_content: ?[]u8 = null;
threadlocal var g_qr_matrix: ?qr_code.Matrix = null;
threadlocal var g_qr_generation: u64 = 0;
threadlocal var g_qr_generation_failed: bool = false;
threadlocal var g_last_qr_hash: u64 = 0;

pub fn start(allocator: std.mem.Allocator, ctrl: *Controller) !void {
    try ctrl.startLoginAsync();
    open(ctrl);
    _ = refresh(allocator);
}

pub fn open(ctrl: *Controller) void {
    if (g_controller != ctrl) {
        clearSnapshot();
        g_controller = ctrl;
    }
    g_visible = true;
    if (g_status == .unknown) g_status = .wait;
}

pub fn close() void {
    g_visible = false;
}

pub fn visible() bool {
    return g_visible;
}

pub fn controller() ?*Controller {
    return g_controller;
}

pub fn status() types.QrStatusKind {
    return g_status;
}

pub fn statusLabel(s: types.QrStatusKind) []const u8 {
    return switch (s) {
        .wait => "等待扫码",
        .scaned => "已扫码",
        .confirmed => "已确认",
        .expired => "已过期",
        .unknown => "准备登录",
    };
}

pub fn statusDetail(s: types.QrStatusKind) []const u8 {
    return switch (s) {
        .wait => "Open WeChat and scan the QR code.",
        .scaned => "Confirm the login request in WeChat.",
        .confirmed => "WeChat is connected.",
        .expired => "The QR code expired. Retry to request a fresh code.",
        .unknown => "Requesting a QR code from the WeChat ilink service.",
    };
}

pub fn qrString() []const u8 {
    return g_qr_string orelse "";
}

pub fn qrContent() []const u8 {
    return g_qr_content orelse "";
}

pub fn qrMatrix() ?QrMatrixView {
    if (g_qr_matrix) |matrix| {
        return .{ .size = matrix.size, .modules = matrix.modules };
    }
    return null;
}

pub fn qrGeneration() u64 {
    return g_qr_generation;
}

pub fn qrGenerationFailed() bool {
    return g_qr_generation_failed;
}

/// Pulls the latest controller login state into UI-owned storage. Returns true
/// when visible UI should be redrawn.
pub fn refresh(allocator: std.mem.Allocator) bool {
    if (!g_visible) return false;
    const ctrl = g_controller orelse return false;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const snap = ctrl.loginSnapshot(arena.allocator()) catch {
        if (g_status == .unknown and g_qr_generation_failed) return false;
        g_status = .unknown;
        g_qr_generation_failed = true;
        return true;
    };

    var changed = false;
    if (snap.status != g_status) {
        g_status = snap.status;
        changed = true;
    }

    if (!optionalEql(g_qr_string, snap.qr_string)) {
        replaceQrString(snap.qr_string);
        changed = true;
    }

    changed = updateQrContent(snap.qr_content, snap.qr_string) or changed;

    if (snap.status == .confirmed) {
        close();
        changed = true;
    }

    return changed;
}

pub fn layout(window_width: f32, window_height: f32, top_offset: f32) Layout {
    const content_h = @max(1.0, window_height - top_offset);
    const panel_w = @round(@min(PANEL_MAX_W, @max(PANEL_MIN_W, window_width - PANEL_MARGIN * 2)));
    const panel_h = @round(@min(PANEL_MAX_H, @max(PANEL_MIN_H, content_h - PANEL_MARGIN * 2)));
    const panel_x = @round(@max(12.0, (window_width - panel_w) / 2.0));
    const panel_top = @round(top_offset + @max(12.0, (content_h - panel_h) / 2.0));

    const qr_size = @round(@max(180.0, @min(@min(panel_w - 104.0, panel_h - 254.0), 292.0)));
    const qr_x = @round(panel_x + (panel_w - qr_size) / 2.0);
    const qr_top = @round(panel_top + 136.0);

    const close_x = @round(panel_x + panel_w - 24.0 - BUTTON_W);
    const unbind_x = @round(close_x - BUTTON_GAP - BUTTON_W);
    const retry_x = @round(panel_x + 24.0);
    const button_top = @round(panel_top + panel_h - 24.0 - BUTTON_H);

    return .{
        .panel = .{ .x = panel_x, .top_px = panel_top, .w = panel_w, .h = panel_h },
        .qr = .{ .x = qr_x, .top_px = qr_top, .w = qr_size, .h = qr_size },
        .retry = .{ .x = retry_x, .top_px = button_top, .w = BUTTON_W, .h = BUTTON_H },
        .close = .{ .x = close_x, .top_px = button_top, .w = BUTTON_W, .h = BUTTON_H },
        .unbind = .{ .x = unbind_x, .top_px = button_top, .w = BUTTON_W, .h = BUTTON_H },
    };
}

pub fn containsPoint(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    if (!g_visible) return false;
    const l = layout(window_width, window_height, top_offset);
    return pointInRect(xpos, ypos, l.panel);
}

pub fn executeAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) Action {
    if (!g_visible) return .none;
    const l = layout(window_width, window_height, top_offset);
    if (g_status == .expired and pointInRect(xpos, ypos, l.retry)) return .retry;
    if (pointInRect(xpos, ypos, l.unbind)) return .unbind;
    if (pointInRect(xpos, ypos, l.close)) return .close;
    return .none;
}

pub fn deinit() void {
    g_visible = false;
    g_controller = null;
    clearSnapshot();
}

fn optionalEql(current: ?[]u8, next: []const u8) bool {
    if (current) |value| return std.mem.eql(u8, value, next);
    return next.len == 0;
}

fn replaceQrString(value: []const u8) void {
    if (g_qr_string) |old| std.heap.page_allocator.free(old);
    g_qr_string = null;
    if (value.len == 0) return;
    g_qr_string = std.heap.page_allocator.dupe(u8, value) catch null;
}

fn updateQrContent(qr_content_raw: []const u8, qr_string_raw: []const u8) bool {
    const qr_content = std.mem.trim(u8, if (qr_content_raw.len != 0) qr_content_raw else qr_string_raw, " \t\r\n");
    if (qr_content.len == 0) {
        const had_qr = g_qr_content != null or g_qr_matrix != null or g_last_qr_hash != 0 or g_qr_generation_failed;
        clearQr();
        if (had_qr) g_qr_generation +%= 1;
        return had_qr;
    }

    const next_hash = std.hash.Wyhash.hash(0, qr_content);
    if (next_hash == g_last_qr_hash) return false;

    replaceQrContent(qr_content);
    const matrix = qr_code.encodeText(std.heap.page_allocator, qr_content) catch {
        clearQrMatrix();
        g_last_qr_hash = next_hash;
        g_qr_generation_failed = true;
        g_qr_generation +%= 1;
        return true;
    };

    clearQrMatrix();
    g_qr_matrix = matrix;
    g_last_qr_hash = next_hash;
    g_qr_generation_failed = false;
    g_qr_generation +%= 1;
    return true;
}

fn clearSnapshot() void {
    replaceQrString("");
    clearQr();
    g_status = .unknown;
}

fn replaceQrContent(value: []const u8) void {
    if (g_qr_content) |old| std.heap.page_allocator.free(old);
    g_qr_content = std.heap.page_allocator.dupe(u8, value) catch null;
}

fn clearQr() void {
    if (g_qr_content) |old| std.heap.page_allocator.free(old);
    g_qr_content = null;
    clearQrMatrix();
    g_last_qr_hash = 0;
    g_qr_generation_failed = false;
}

fn clearQrMatrix() void {
    if (g_qr_matrix) |*old| old.deinit();
    g_qr_matrix = null;
}

fn pointInRect(xpos: f64, ypos: f64, rect: Rect) bool {
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    return x >= rect.x and x <= rect.x + rect.w and
        y >= rect.top_px and y <= rect.top_px + rect.h;
}

test "qr_panel: stores a generated matrix from qrcode content" {
    clearSnapshot();
    defer deinit();

    try std.testing.expect(updateQrContent("weixin://qr-content", ""));
    try std.testing.expectEqualStrings("weixin://qr-content", qrContent());
    try std.testing.expect(qrMatrix() != null);
    try std.testing.expect(!qrGenerationFailed());
}

test "qr_panel: layout keeps buttons inside the panel" {
    const l = layout(800, 600, 32);
    try std.testing.expect(l.retry.x >= l.panel.x);
    try std.testing.expect(l.close.x + l.close.w <= l.panel.x + l.panel.w);
    try std.testing.expect(l.close.top_px + l.close.h <= l.panel.top_px + l.panel.h);
}

test "qr_panel: wide layout expands text room without enlarging QR" {
    const l = layout(1200, 900, 0);
    try std.testing.expectEqual(@as(f32, 900), l.panel.w);
    try std.testing.expectEqual(@as(f32, 620), l.panel.h);
    try std.testing.expectEqual(@as(f32, 292), l.qr.w);
    try std.testing.expectEqual(@as(f32, 292), l.qr.h);
}

test "qr_panel: expired status exposes retry hit target" {
    g_visible = true;
    g_status = .expired;
    defer deinit();

    const l = layout(800, 600, 0);
    const action = executeAt(l.retry.x + 4, l.retry.top_px + 4, 800, 600, 0);
    try std.testing.expectEqual(Action.retry, action);
}
