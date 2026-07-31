//! UI-thread state for the Feishu one-click registration QR panel.
//! 镜像 weixin/qr_panel.zig:registration.zig 持网络线程,本模块只拍快照、
//! 持有 UI 侧二维码矩阵、暴露布局/命中给渲染与输入层。无 unbind。

const std = @import("std");
const registration = @import("registration.zig");
const qr_code = @import("../weixin/qr_code.zig");

pub const StatusKind = registration.StatusKind;

pub const Action = enum { none, retry, close };

pub const Rect = struct { x: f32, top_px: f32, w: f32, h: f32 };

pub const Layout = struct {
    panel: Rect,
    qr: Rect,
    retry: Rect,
    close: Rect,
};

pub const QrMatrixView = struct {
    size: usize,
    modules: []const u8,
    pub fn isBlack(self: QrMatrixView, x: usize, y: usize) bool {
        return x < self.size and y < self.size and self.modules[y * self.size + x] != 0;
    }
};

pub const Creds = struct { app_id: []const u8, app_secret: []const u8 };

const PANEL_MIN_W: f32 = 380;
const PANEL_MAX_W: f32 = 900;
const PANEL_MIN_H: f32 = 500;
const PANEL_MAX_H: f32 = 620;
const PANEL_MARGIN: f32 = 24;
const BUTTON_H: f32 = 38;
const BUTTON_W: f32 = 118;

pub threadlocal var g_visible: bool = false;
threadlocal var g_status: StatusKind = .requesting;
threadlocal var g_qr_url: ?[]u8 = null;
threadlocal var g_qr_matrix: ?qr_code.Matrix = null;
threadlocal var g_qr_gen_failed: bool = false;
threadlocal var g_last_url_hash: u64 = 0;
threadlocal var g_success_app_id: ?[]u8 = null;
threadlocal var g_success_app_secret: ?[]u8 = null;
threadlocal var g_success_pending: bool = false;

pub fn open() void {
    g_visible = true;
    g_status = .requesting;
}

pub fn close() void {
    g_visible = false;
}

pub fn visible() bool {
    return g_visible;
}

pub fn status() StatusKind {
    return g_status;
}

pub fn statusLabel(s: StatusKind) []const u8 {
    return switch (s) {
        .requesting => "正在申请",
        .waiting => "等待扫码",
        .success => "创建成功",
        .expired => "已过期",
        .denied => "已取消",
        .err => "出错了",
    };
}

pub fn statusDetail(s: StatusKind) []const u8 {
    return switch (s) {
        .requesting => "正在向飞书申请创建链接…",
        .waiting => "请用飞书扫码并确认创建应用。",
        .success => "凭据已回填到配置表单,请检查后保存。",
        .expired => "二维码已过期,点 Retry 重新申请。",
        .denied => "授权被取消,点 Retry 重试。",
        .err => "网络或服务异常,点 Retry 重试。",
    };
}

pub fn qrMatrix() ?QrMatrixView {
    if (g_qr_matrix) |m| return .{ .size = m.size, .modules = m.modules };
    return null;
}

pub fn qrGenerationFailed() bool {
    return g_qr_gen_failed;
}

pub const RefreshResult = struct { redraw: bool, succeeded: bool };

pub fn refresh(allocator: std.mem.Allocator) RefreshResult {
    if (!g_visible) return .{ .redraw = false, .succeeded = false };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const snap = registration.snapshot(arena.allocator());

    var redraw = false;
    if (snap.status != g_status) {
        g_status = snap.status;
        redraw = true;
    }
    redraw = updateQr(snap.verify_url) or redraw;

    var succeeded = false;
    if (snap.status == .success and !g_success_pending and snap.app_id.len > 0) {
        replaceOwned(&g_success_app_id, snap.app_id);
        replaceOwned(&g_success_app_secret, snap.app_secret);
        g_success_pending = true;
        succeeded = true;
        redraw = true;
    }
    return .{ .redraw = redraw, .succeeded = succeeded };
}

/// 取走成功凭据(供 overlays 回填表单),取后清空 pending。返回的切片在下次
/// takeSuccessCreds/deinit 前有效;调用方应立即 copy 进表单 buffer。
pub fn takeSuccessCreds() ?Creds {
    if (!g_success_pending) return null;
    g_success_pending = false;
    return .{
        .app_id = g_success_app_id orelse "",
        .app_secret = g_success_app_secret orelse "",
    };
}

fn updateQr(url: []const u8) bool {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len == 0) return false;
    const h = std.hash.Wyhash.hash(0, trimmed);
    if (h == g_last_url_hash) return false;
    g_last_url_hash = h;

    replaceOwned(&g_qr_url, trimmed);
    clearMatrix();
    g_qr_matrix = qr_code.encodeText(std.heap.page_allocator, trimmed) catch {
        g_qr_gen_failed = true;
        return true;
    };
    g_qr_gen_failed = false;
    return true;
}

fn replaceOwned(slot: *?[]u8, value: []const u8) void {
    if (slot.*) |old| std.heap.page_allocator.free(old);
    slot.* = std.heap.page_allocator.dupe(u8, value) catch null;
}

fn clearMatrix() void {
    if (g_qr_matrix) |*m| m.deinit();
    g_qr_matrix = null;
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
    const retry_x = @round(panel_x + 24.0);
    const button_top = @round(panel_top + panel_h - 24.0 - BUTTON_H);

    return .{
        .panel = .{ .x = panel_x, .top_px = panel_top, .w = panel_w, .h = panel_h },
        .qr = .{ .x = qr_x, .top_px = qr_top, .w = qr_size, .h = qr_size },
        .retry = .{ .x = retry_x, .top_px = button_top, .w = BUTTON_W, .h = BUTTON_H },
        .close = .{ .x = close_x, .top_px = button_top, .w = BUTTON_W, .h = BUTTON_H },
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
    const retryable = g_status == .expired or g_status == .denied or g_status == .err;
    if (retryable and pointInRect(xpos, ypos, l.retry)) return .retry;
    if (pointInRect(xpos, ypos, l.close)) return .close;
    return .none;
}

pub fn deinit() void {
    g_visible = false;
    clearMatrix();
    if (g_qr_url) |u| std.heap.page_allocator.free(u);
    g_qr_url = null;
    if (g_success_app_id) |s| std.heap.page_allocator.free(s);
    g_success_app_id = null;
    if (g_success_app_secret) |s| std.heap.page_allocator.free(s);
    g_success_app_secret = null;
    g_last_url_hash = 0;
    g_success_pending = false;
    g_status = .requesting;
}

fn pointInRect(xpos: f64, ypos: f64, rect: Rect) bool {
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.top_px and y <= rect.top_px + rect.h;
}

test "layout keeps retry/close inside panel" {
    const l = layout(800, 600, 32);
    try std.testing.expect(l.retry.x >= l.panel.x);
    try std.testing.expect(l.close.x + l.close.w <= l.panel.x + l.panel.w);
    try std.testing.expect(l.close.top_px + l.close.h <= l.panel.top_px + l.panel.h);
}

test "executeAt: retry hot only on retryable states, close always" {
    g_visible = true;
    defer deinit();
    const l = layout(800, 600, 0);

    g_status = .waiting;
    try std.testing.expectEqual(Action.none, executeAt(l.retry.x + 4, l.retry.top_px + 4, 800, 600, 0));
    try std.testing.expectEqual(Action.close, executeAt(l.close.x + 4, l.close.top_px + 4, 800, 600, 0));

    g_status = .expired;
    try std.testing.expectEqual(Action.retry, executeAt(l.retry.x + 4, l.retry.top_px + 4, 800, 600, 0));
}

test "updateQr builds a matrix and dedups by url hash" {
    defer deinit();
    try std.testing.expect(updateQr("https://accounts.feishu.cn/oauth/v1/app/registration?code=abc"));
    try std.testing.expect(qrMatrix() != null);
    try std.testing.expect(!qrGenerationFailed());
    // 同 url 再来一次 → 不重算(返回 false)
    try std.testing.expect(!updateQr("https://accounts.feishu.cn/oauth/v1/app/registration?code=abc"));
}
