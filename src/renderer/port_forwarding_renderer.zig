const std = @import("std");
const rule_mod = @import("../port_forward_rule.zig");

const HEADER_H: f32 = 54;
const ROW_H: f32 = 52;
const LEGEND_H: f32 = 36;
const PAD_X: f32 = 16;
const COL_GAP: f32 = 10;
const DIRECTION_W: f32 = 78;
const AUTO_W: f32 = 70;
const STATUS_W: f32 = 92;
pub const REASON_MAX: usize = 192;

pub const StatusKind = enum {
    stopped,
    starting,
    running,
    error_,
    missing_profile,
};

pub const RowView = struct {
    rule: rule_mod.Rule,
    status: StatusKind,
    reason_buf: [REASON_MAX]u8 = undefined,
    reason_len: usize = 0,
    auto_start: bool,

    pub fn reason(self: *const RowView) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }
};

pub const DrawContext = struct {
    bg: [3]f32,
    fg: [3]f32,
    accent: [3]f32,
    cell_h: f32,
    fillQuad: *const fn (f32, f32, f32, f32, [3]f32) void,
    fillQuadAlpha: *const fn (f32, f32, f32, f32, [3]f32, f32) void,
    renderTextLimited: *const fn ([]const u8, f32, f32, [3]f32, f32) f32,
    glyphAdvance: *const fn (u32) f32,
};

pub const RowAt = *const fn (*anyopaque, usize) RowView;

pub const View = struct {
    title: []const u8,
    legend: []const u8,
    count: usize,
    selected: usize,
    scroll: usize,
    ctx: *anyopaque,
    rowAt: RowAt,
    overlay_text: []const u8 = "",
};

pub fn statusLabel(status: StatusKind) []const u8 {
    return switch (status) {
        .stopped => "Stopped",
        .starting => "Starting",
        .running => "Running",
        .error_ => "Error",
        .missing_profile => "Missing",
    };
}

pub fn directionLabel(direction: rule_mod.Direction) []const u8 {
    return switch (direction) {
        .local => "Local",
        .reverse => "Reverse",
    };
}

pub fn autoLabel(auto_start: bool) []const u8 {
    return if (auto_start) "Auto" else "Manual";
}

pub fn clampedTextWidth(x: f32, content_right: f32, requested: f32) f32 {
    const positive_requested = @max(0.0, requested);
    const available = @max(0.0, content_right - x);
    return @min(positive_requested, available);
}

pub fn listenLabel(rule: *const rule_mod.Rule, buf: []u8) []const u8 {
    return switch (rule.direction) {
        .local => endpointLabel("local", rule.localHost(), rule.local_port, buf),
        .reverse => endpointLabel("remote", rule.remoteHost(), rule.remote_port, buf),
    };
}

pub fn targetLabel(rule: *const rule_mod.Rule, buf: []u8) []const u8 {
    return switch (rule.direction) {
        .local => endpointLabel("remote", rule.remoteHost(), rule.remote_port, buf),
        .reverse => endpointLabel("local", rule.localHost(), rule.local_port, buf),
    };
}

pub fn bodyVisibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    const usable = content_h - headerHeight(cell_h) - legendHeight(cell_h);
    if (usable <= 0) return 0;
    return @intFromFloat(@max(0.0, @floor(usable / rowHeight(cell_h))));
}

pub fn visibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    return bodyVisibleCapacity(window_height, titlebar_offset, cell_h);
}

pub fn clampScroll(requested: usize, total: usize, visible: usize) usize {
    if (visible == 0 or total <= visible) return 0;
    return @min(requested, total - visible);
}

pub fn scrollToSelection(selected: usize, requested: usize, total: usize, visible: usize) usize {
    if (visible == 0 or total == 0) return 0;
    const bounded_selected = @min(selected, total - 1);
    var scroll = clampScroll(requested, total, visible);
    if (bounded_selected < scroll) return bounded_selected;
    if (bounded_selected >= scroll + visible) {
        scroll = bounded_selected - visible + 1;
    }
    return clampScroll(scroll, total, visible);
}

pub fn render(
    draw: DrawContext,
    view: View,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    x: f32,
    width: f32,
) void {
    _ = window_width;
    _ = draw.glyphAdvance;

    const content_x = @round(x);
    const content_w = @round(@max(1.0, width));
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    if (content_w <= 1 or content_h <= 1) return;

    const bg = draw.bg;
    const fg = draw.fg;
    const accent = draw.accent;
    const panel_strong = mixColor(bg, fg, 0.075);
    const line = mixColor(bg, fg, 0.18);
    const muted = mixColor(bg, fg, 0.58);
    const selected_bg = mixColor(bg, accent, 0.18);

    draw.fillQuad(content_x, 0, content_w, content_h, bg);
    renderHeader(draw, view, content_x, content_w, window_height, top, fg, muted, panel_strong, line);

    const body_top = top + headerHeight(draw.cell_h);
    renderRows(draw, view, content_x, content_w, window_height, top, body_top, fg, muted, accent, line, selected_bg);

    if (view.overlay_text.len > 0) {
        renderOverlayText(draw, view.overlay_text, content_x, content_w, fg, accent);
    }
    renderLegend(draw, view.legend, content_x, content_w, muted, line);
}

fn endpointLabel(scope: []const u8, host: []const u8, port: u16, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}:{d}", .{ scope, host, port }) catch scope;
}

fn headerHeight(cell_h: f32) f32 {
    return @max(HEADER_H, cell_h + 18);
}

fn rowHeight(cell_h: f32) f32 {
    return @max(ROW_H, cell_h * 2 + 20);
}

fn legendHeight(cell_h: f32) f32 {
    return @max(LEGEND_H, cell_h + 18);
}

fn yFromTop(window_height: f32, top_px: f32, h: f32) f32 {
    return window_height - top_px - h;
}

fn yTextFromTop(draw: DrawContext, window_height: f32, top_px: f32) f32 {
    return window_height - top_px - draw.cell_h;
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

fn renderHeader(
    draw: DrawContext,
    view: View,
    content_x: f32,
    content_w: f32,
    window_height: f32,
    top: f32,
    fg: [3]f32,
    muted: [3]f32,
    panel_strong: [3]f32,
    line: [3]f32,
) void {
    const header_h = headerHeight(draw.cell_h);
    const content_right = content_x + content_w - PAD_X;
    const title_x = content_x + PAD_X;
    draw.fillQuadAlpha(content_x, yFromTop(window_height, top, header_h), content_w, header_h, panel_strong, 0.9);
    draw.fillQuad(content_x, yFromTop(window_height, top + header_h, 1), content_w, 1, line);

    const title_y = yTextFromTop(draw, window_height, top + 11);
    const title_end = draw.renderTextLimited(view.title, title_x, title_y, fg, clampedTextWidth(title_x, content_right, content_w - PAD_X * 2));
    var count_buf: [48]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, " - {d}", .{view.count}) catch "";
    _ = draw.renderTextLimited(count_text, title_end, title_y, muted, clampedTextWidth(title_end, content_right, content_right - title_end));
}

fn renderRows(
    draw: DrawContext,
    view: View,
    content_x: f32,
    content_w: f32,
    window_height: f32,
    top: f32,
    body_top: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    line: [3]f32,
    selected_bg: [3]f32,
) void {
    if (view.count == 0) {
        const empty = if (view.overlay_text.len > 0) view.overlay_text else "No port forwarding rules";
        const text_x = content_x + PAD_X;
        const content_right = content_x + content_w - PAD_X;
        _ = draw.renderTextLimited(empty, text_x, yTextFromTop(draw, window_height, body_top + 24), muted, clampedTextWidth(text_x, content_right, content_w - PAD_X * 2));
        return;
    }

    const row_h = rowHeight(draw.cell_h);
    const cap = bodyVisibleCapacity(window_height, top, draw.cell_h);
    const scroll = scrollToSelection(view.selected, view.scroll, view.count, cap);
    const selected = @min(view.selected, view.count - 1);
    var rendered: usize = 0;
    var ri: usize = scroll;
    while (ri < view.count and rendered < cap) : (ri += 1) {
        const row = view.rowAt(view.ctx, ri);
        const row_top_px = body_top + @as(f32, @floatFromInt(rendered)) * row_h;
        renderRow(draw, row, ri == selected, content_x, content_w, window_height, row_top_px, row_h, fg, muted, accent, line, selected_bg);
        rendered += 1;
    }
}

fn renderRow(
    draw: DrawContext,
    row: RowView,
    selected: bool,
    content_x: f32,
    content_w: f32,
    window_height: f32,
    row_top_px: f32,
    row_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    line: [3]f32,
    selected_bg: [3]f32,
) void {
    const row_y = yFromTop(window_height, row_top_px, row_h);
    if (selected) {
        draw.fillQuadAlpha(content_x, row_y, content_w, row_h, selected_bg, 0.88);
        draw.fillQuad(content_x, row_y, 3, row_h, accent);
    }
    draw.fillQuadAlpha(content_x, row_y, content_w, 1, line, 0.45);

    const right_w = DIRECTION_W + AUTO_W + STATUS_W + COL_GAP * 2;
    const show_columns = content_w >= PAD_X * 2 + right_w + 120;
    const right_x = content_x + content_w - PAD_X - right_w;
    const text_x = content_x + PAD_X;
    const content_right = content_x + content_w - PAD_X;
    const primary_y = yTextFromTop(draw, window_height, row_top_px + 8);
    const secondary_y = yTextFromTop(draw, window_height, row_top_px + row_h - draw.cell_h - 8);

    const title_limit = if (show_columns) @max(0.0, right_x - text_x - COL_GAP) else @max(0.0, content_w - PAD_X * 2);
    _ = draw.renderTextLimited(rowTitle(&row), text_x, primary_y, fg, clampedTextWidth(text_x, content_right, title_limit));

    if (show_columns) {
        var x = right_x;
        _ = draw.renderTextLimited(directionLabel(row.rule.direction), x, primary_y, muted, DIRECTION_W);
        x += DIRECTION_W + COL_GAP;
        _ = draw.renderTextLimited(autoLabel(row.auto_start), x, primary_y, muted, AUTO_W);
        x += AUTO_W + COL_GAP;
        _ = draw.renderTextLimited(statusLabel(row.status), x, primary_y, statusColor(row.status, fg, muted, accent), STATUS_W);
    }

    var listen_buf: [96]u8 = undefined;
    var target_buf: [96]u8 = undefined;
    var endpoint_buf: [224]u8 = undefined;
    const listen = listenLabel(&row.rule, &listen_buf);
    const target = targetLabel(&row.rule, &target_buf);
    const endpoint = if (show_columns)
        std.fmt.bufPrint(&endpoint_buf, "{s} -> {s}", .{ listen, target }) catch ""
    else
        std.fmt.bufPrint(&endpoint_buf, "{s} - {s} -> {s}", .{ statusLabel(row.status), listen, target }) catch "";

    const profile = if (row.rule.profileName().len > 0) row.rule.profileName() else "No profile";
    const profile_w: f32 = 128;
    const profile_limit = clampedTextWidth(text_x, content_right, profile_w);
    const profile_end = @min(content_right, draw.renderTextLimited(profile, text_x, secondary_y, accent, profile_limit));
    const reason = row.reason();
    const detail_x = @min(content_right, profile_end + COL_GAP);
    const detail_limit = clampedTextWidth(detail_x, content_right, content_right - detail_x);
    const detail = if (reason.len > 0) reason else endpoint;
    _ = draw.renderTextLimited(detail, detail_x, secondary_y, if (reason.len > 0) statusColor(row.status, fg, muted, accent) else muted, detail_limit);
}

fn rowTitle(row: *const RowView) []const u8 {
    if (row.rule.name().len > 0) return row.rule.name();
    if (row.reason().len > 0) return row.reason();
    return "Port forward";
}

fn statusColor(status: StatusKind, fg: [3]f32, muted: [3]f32, accent: [3]f32) [3]f32 {
    return switch (status) {
        .running => accent,
        .starting => mixColor(fg, accent, 0.25),
        .stopped => muted,
        .error_ => .{ 0.95, 0.28, 0.28 },
        .missing_profile => .{ 0.95, 0.72, 0.28 },
    };
}

fn renderOverlayText(draw: DrawContext, text: []const u8, content_x: f32, content_w: f32, fg: [3]f32, accent: [3]f32) void {
    const bar_h = rowHeight(draw.cell_h);
    const bar_y = legendHeight(draw.cell_h);
    const text_x = content_x + PAD_X;
    const content_right = content_x + content_w - PAD_X;
    draw.fillQuadAlpha(content_x, bar_y, content_w, bar_h, mixColor(draw.bg, accent, 0.22), 0.97);
    const text_y = bar_y + (bar_h - draw.cell_h) / 2;
    _ = draw.renderTextLimited(text, text_x, text_y, fg, clampedTextWidth(text_x, content_right, content_w - PAD_X * 2));
}

fn renderLegend(draw: DrawContext, legend: []const u8, content_x: f32, content_w: f32, muted: [3]f32, line: [3]f32) void {
    const legend_h = legendHeight(draw.cell_h);
    const text_x = content_x + PAD_X;
    const content_right = content_x + content_w - PAD_X;
    draw.fillQuad(content_x, legend_h, content_w, 1, line);
    const text_y = (legend_h - draw.cell_h) / 2;
    _ = draw.renderTextLimited(legend, text_x, text_y, muted, clampedTextWidth(text_x, content_right, content_w - PAD_X * 2));
}

test "port_forwarding_renderer: status labels" {
    try std.testing.expectEqualStrings("Stopped", statusLabel(StatusKind.stopped));
    try std.testing.expectEqualStrings("Starting", statusLabel(StatusKind.starting));
    try std.testing.expectEqualStrings("Running", statusLabel(StatusKind.running));
    try std.testing.expectEqualStrings("Error", statusLabel(StatusKind.error_));
    try std.testing.expectEqualStrings("Missing", statusLabel(StatusKind.missing_profile));
}

test "port_forwarding_renderer: listen and target labels" {
    var rule = rule_mod.defaultReverseProxy("devbox");
    var listen_buf: [96]u8 = undefined;
    var target_buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("remote 127.0.0.1:7890", listenLabel(&rule, &listen_buf));
    try std.testing.expectEqualStrings("local 127.0.0.1:7890", targetLabel(&rule, &target_buf));

    rule.direction = .local;
    rule.local_port = 8888;
    rule.remote_port = 8888;
    try std.testing.expectEqualStrings("local 127.0.0.1:8888", listenLabel(&rule, &listen_buf));
    try std.testing.expectEqualStrings("remote 127.0.0.1:8888", targetLabel(&rule, &target_buf));
}

test "port_forwarding_renderer: direction and auto labels" {
    try std.testing.expectEqualStrings("Reverse", directionLabel(.reverse));
    try std.testing.expectEqualStrings("Local", directionLabel(.local));
    try std.testing.expectEqualStrings("Auto", autoLabel(true));
    try std.testing.expectEqualStrings("Manual", autoLabel(false));
}

test "port_forwarding_renderer: clamp scroll keeps selected row visible" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(5, 3, 10));
    try std.testing.expectEqual(@as(usize, 2), clampScroll(5, 12, 10));
    try std.testing.expectEqual(@as(usize, 1), clampScroll(1, 12, 10));
    try std.testing.expectEqual(@as(usize, 7), scrollToSelection(12, 5, 10, 3));
    try std.testing.expectEqual(@as(usize, 3), scrollToSelection(3, 6, 10, 4));
}

test "port_forwarding_renderer: endpoint labels preserve distinct hosts and ports" {
    var rule = rule_mod.defaultReverseProxy("devbox");
    rule.setLocalHost("localhost");
    rule.local_port = 18080;
    rule.setRemoteHost("127.0.0.1");
    rule.remote_port = 8080;

    var listen_buf: [96]u8 = undefined;
    var target_buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("remote 127.0.0.1:8080", listenLabel(&rule, &listen_buf));
    try std.testing.expectEqualStrings("local localhost:18080", targetLabel(&rule, &target_buf));

    rule.direction = .local;
    try std.testing.expectEqualStrings("local localhost:18080", listenLabel(&rule, &listen_buf));
    try std.testing.expectEqualStrings("remote 127.0.0.1:8080", targetLabel(&rule, &target_buf));
}

test "port_forwarding_renderer: render accepts row accessor view" {
    const NoopDraw = struct {
        fn fillQuad(_: f32, _: f32, _: f32, _: f32, _: [3]f32) void {}
        fn fillQuadAlpha(_: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
        fn renderTextLimited(text: []const u8, x: f32, _: f32, _: [3]f32, _: f32) f32 {
            return x + @as(f32, @floatFromInt(text.len));
        }
        fn glyphAdvance(_: u32) f32 {
            return 8;
        }
    };

    const Rows = struct {
        row: RowView,

        fn rowAt(ctx: *anyopaque, index: usize) RowView {
            _ = index;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.row;
        }
    };

    var rows = Rows{
        .row = .{
            .rule = rule_mod.defaultReverseProxy("devbox"),
            .status = .error_,
            .auto_start = false,
        },
    };
    rows.row.reason_len = @min(rows.row.reason_buf.len, "ssh exited".len);
    @memcpy(rows.row.reason_buf[0..rows.row.reason_len], "ssh exited"[0..rows.row.reason_len]);

    const draw = DrawContext{
        .bg = .{ 0.02, 0.02, 0.02 },
        .fg = .{ 0.95, 0.95, 0.95 },
        .accent = .{ 0.2, 0.6, 1.0 },
        .cell_h = 16,
        .fillQuad = NoopDraw.fillQuad,
        .fillQuadAlpha = NoopDraw.fillQuadAlpha,
        .renderTextLimited = NoopDraw.renderTextLimited,
        .glyphAdvance = NoopDraw.glyphAdvance,
    };
    const row_at: RowAt = Rows.rowAt;
    render(draw, .{
        .title = "Port Forwarding",
        .legend = "Enter start/stop  n new",
        .count = 1,
        .selected = 0,
        .scroll = 0,
        .ctx = &rows,
        .rowAt = row_at,
        .overlay_text = "Profile missing",
    }, 900, 600, 40, 0, 900);
}

test "port_forwarding_renderer: render does not request rows with zero visible capacity" {
    const NoopDraw = struct {
        fn fillQuad(_: f32, _: f32, _: f32, _: f32, _: [3]f32) void {}
        fn fillQuadAlpha(_: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
        fn renderTextLimited(text: []const u8, x: f32, _: f32, _: [3]f32, _: f32) f32 {
            return x + @as(f32, @floatFromInt(text.len));
        }
        fn glyphAdvance(_: u32) f32 {
            return 8;
        }
    };

    const Rows = struct {
        calls: usize = 0,

        fn rowAt(ctx: *anyopaque, index: usize) RowView {
            _ = index;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return .{
                .rule = rule_mod.defaultReverseProxy("devbox"),
                .status = .running,
                .auto_start = true,
            };
        }
    };

    var rows = Rows{};
    const draw = DrawContext{
        .bg = .{ 0.02, 0.02, 0.02 },
        .fg = .{ 0.95, 0.95, 0.95 },
        .accent = .{ 0.2, 0.6, 1.0 },
        .cell_h = 16,
        .fillQuad = NoopDraw.fillQuad,
        .fillQuadAlpha = NoopDraw.fillQuadAlpha,
        .renderTextLimited = NoopDraw.renderTextLimited,
        .glyphAdvance = NoopDraw.glyphAdvance,
    };

    render(draw, .{
        .title = "Port Forwarding",
        .legend = "Enter start/stop  n new",
        .count = 1,
        .selected = 0,
        .scroll = 0,
        .ctx = &rows,
        .rowAt = Rows.rowAt,
    }, 200, 80, 0, 0, 200);

    try std.testing.expectEqual(@as(usize, 0), rows.calls);
}

test "port_forwarding_renderer: narrow row text widths stay within content" {
    const InstrumentedDraw = struct {
        var content_right: f32 = 0;
        var bad_width: bool = false;

        fn fillQuad(_: f32, _: f32, _: f32, _: f32, _: [3]f32) void {}
        fn fillQuadAlpha(_: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
        fn renderTextLimited(text: []const u8, x: f32, _: f32, _: [3]f32, max_w: f32) f32 {
            const available = @max(0.0, content_right - x);
            if (std.math.isNan(max_w) or max_w < 0.0 or max_w > available + 0.01) {
                bad_width = true;
            }
            return x + @min(max_w, @as(f32, @floatFromInt(text.len)) * 8.0);
        }
        fn glyphAdvance(_: u32) f32 {
            return 8;
        }
    };

    const Rows = struct {
        fn rowAt(_: *anyopaque, index: usize) RowView {
            _ = index;
            return .{
                .rule = rule_mod.defaultReverseProxy("devbox"),
                .status = .running,
                .auto_start = true,
            };
        }
    };

    const width: f32 = 80;
    InstrumentedDraw.content_right = width - PAD_X;
    InstrumentedDraw.bad_width = false;

    const draw = DrawContext{
        .bg = .{ 0.02, 0.02, 0.02 },
        .fg = .{ 0.95, 0.95, 0.95 },
        .accent = .{ 0.2, 0.6, 1.0 },
        .cell_h = 16,
        .fillQuad = InstrumentedDraw.fillQuad,
        .fillQuadAlpha = InstrumentedDraw.fillQuadAlpha,
        .renderTextLimited = InstrumentedDraw.renderTextLimited,
        .glyphAdvance = InstrumentedDraw.glyphAdvance,
    };

    render(draw, .{
        .title = "Port Forwarding",
        .legend = "Enter start/stop  n new",
        .count = 1,
        .selected = 0,
        .scroll = 0,
        .ctx = undefined,
        .rowAt = Rows.rowAt,
    }, width, 160, 0, 0, width);

    try std.testing.expect(!InstrumentedDraw.bad_width);
}
