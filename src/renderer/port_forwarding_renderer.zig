const std = @import("std");
const rule_mod = @import("../port_forward/rule.zig");
const form_mod = @import("../port_forward/forwarding.zig");

const HEADER_H: f32 = 54;
const ROW_H: f32 = 52;
const LEGEND_H: f32 = 72;
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

pub const FormView = struct {
    mode: []const u8,
    focus: usize,
    rule: rule_mod.Rule,
};

pub const View = struct {
    title: []const u8,
    legend: []const u8,
    count: usize,
    selected: usize,
    scroll: usize,
    ctx: *anyopaque,
    rowAt: RowAt,
    overlay_text: []const u8 = "",
    form: ?FormView = null,
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

pub fn formFieldLabel(index: usize) []const u8 {
    return switch (index) {
        form_mod.FIELD_NAME => "Name",
        form_mod.FIELD_PROFILE => "Profile",
        form_mod.FIELD_DIRECTION => "Direction",
        form_mod.FIELD_LOCAL_HOST => "Local host",
        form_mod.FIELD_LOCAL_PORT => "Local port",
        form_mod.FIELD_REMOTE_HOST => "Remote host",
        form_mod.FIELD_REMOTE_PORT => "Remote port",
        form_mod.FIELD_AUTO_START => "Auto start",
        else => "",
    };
}

pub fn formFieldValue(form: *const FormView, index: usize, buf: []u8) []const u8 {
    return switch (index) {
        form_mod.FIELD_NAME => form.rule.name(),
        // The Profile selector cannot be typed into; an empty name means the
        // ssh_hosts store has no decodable profiles, so hint at that instead
        // of rendering a silently dead blank field.
        form_mod.FIELD_PROFILE => if (form.rule.profileName().len > 0) form.rule.profileName() else "No SSH profiles found",
        form_mod.FIELD_DIRECTION => directionLabel(form.rule.direction),
        form_mod.FIELD_LOCAL_HOST => form.rule.localHost(),
        form_mod.FIELD_LOCAL_PORT => std.fmt.bufPrint(buf, "{d}", .{form.rule.local_port}) catch "",
        form_mod.FIELD_REMOTE_HOST => form.rule.remoteHost(),
        form_mod.FIELD_REMOTE_PORT => std.fmt.bufPrint(buf, "{d}", .{form.rule.remote_port}) catch "",
        form_mod.FIELD_AUTO_START => autoLabel(form.rule.auto_start),
        else => "",
    };
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
    if (view.form) |form| {
        renderForm(draw, form, content_x, content_w, window_height, top, fg, accent);
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
    return @max(LEGEND_H, cell_h * 3 + 16);
}

const RowColumns = struct {
    direction_w: f32,
    auto_w: f32,
    status_w: f32,

    fn total(self: RowColumns) f32 {
        return self.direction_w + self.auto_w + self.status_w + COL_GAP * 2;
    }
};

fn rowColumns(draw: DrawContext) RowColumns {
    const a = @max(1.0, draw.glyphAdvance('M'));
    return .{
        // These labels are semantic state, so fixed pixel slots are unsafe
        // once the terminal UI font grows. Size from the longest label.
        .direction_w = @max(DIRECTION_W, a * 8), // Reverse
        .auto_w = @max(AUTO_W, a * 7), // Manual
        .status_w = @max(STATUS_W, a * 8), // Stopped
    };
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

    const columns = rowColumns(draw);
    const right_w = columns.total();
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
        _ = draw.renderTextLimited(directionLabel(row.rule.direction), x, primary_y, muted, columns.direction_w);
        x += columns.direction_w + COL_GAP;
        _ = draw.renderTextLimited(autoLabel(row.auto_start), x, primary_y, muted, columns.auto_w);
        x += columns.auto_w + COL_GAP;
        _ = draw.renderTextLimited(statusLabel(row.status), x, primary_y, statusColor(row.status, fg, muted, accent), columns.status_w);
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

fn renderForm(draw: DrawContext, form: FormView, content_x: f32, content_w: f32, window_height: f32, top: f32, fg: [3]f32, accent: [3]f32) void {
    const box_w = @max(1.0, @min(@max(1.0, content_w - 32), 720));
    const available_h = @max(1.0, window_height - top - legendHeight(draw.cell_h));
    const desired_h = @max(draw.cell_h * 11.0, 220);
    const box_h = @min(desired_h, available_h);
    const box_x = content_x + @max(0.0, (content_w - box_w) / 2);
    const box_top = top + @min(@max(0.0, available_h - box_h), @max(0.0, (available_h - box_h) / 2));
    const box_y = yFromTop(window_height, box_top, box_h);
    const box_bottom_y = box_y;
    const box_top_y = box_y + box_h;
    const box_bottom_top_px = box_top + box_h;
    const content_right = @max(box_x, box_x + box_w - 18);

    draw.fillQuadAlpha(box_x, box_y, box_w, box_h, draw.bg, 0.96);
    draw.fillQuadAlpha(box_x, box_y, box_w, box_h, accent, 0.22);
    const title_x = box_x + @min(18.0, box_w);
    const title_top = box_top + @min(16.0, @max(0.0, box_h - draw.cell_h));
    if (title_top + draw.cell_h <= box_bottom_top_px) {
        _ = draw.renderTextLimited(form.mode, title_x, yTextFromTop(draw, window_height, title_top), fg, clampedTextWidth(title_x, content_right, content_right - title_x));
    }

    // Start the value column just past the widest label so no label is clipped,
    // even at large font sizes. Keep the previous offset as a lower bound so the
    // value column never collapses for short labels.
    const label_x = box_x + @min(22.0, box_w);
    const widest_label = widestFormLabelWidth(draw);
    const min_value_x = box_x + @min(190.0, @max(72.0, box_w * 0.34));
    const value_x = @min(content_right, @max(min_value_x, label_x + widest_label + COL_GAP));

    var field: usize = 0;
    while (field < 8) : (field += 1) {
        const row_top = box_top + draw.cell_h * @as(f32, @floatFromInt(field + 3));
        if (row_top + draw.cell_h > box_bottom_top_px) break;
        const row_y = yFromTop(window_height, row_top, draw.cell_h);
        const text_y = yTextFromTop(draw, window_height, row_top);
        if (field == form.focus) {
            const focus_x = box_x + @min(12.0, box_w);
            const focus_y = @max(box_bottom_y, row_y - 2);
            const focus_h = @max(0.0, @min(draw.cell_h + 6, box_top_y - focus_y));
            draw.fillQuadAlpha(focus_x, focus_y, clampedTextWidth(focus_x, box_x + box_w, box_w), focus_h, accent, 0.20);
        }
        var value_buf: [32]u8 = undefined;
        _ = draw.renderTextLimited(formFieldLabel(field), label_x, text_y, accent, clampedTextWidth(label_x, content_right, value_x - label_x - COL_GAP));
        _ = draw.renderTextLimited(formFieldValue(&form, field, &value_buf), value_x, text_y, fg, clampedTextWidth(value_x, content_right, content_right - value_x));
    }
}

/// Pixel width of the widest form field label at the current font, used to size
/// the value column so labels render in full.
fn widestFormLabelWidth(draw: DrawContext) f32 {
    var widest: f32 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const label = formFieldLabel(i);
        var w: f32 = 0;
        for (label) |ch| w += draw.glyphAdvance(ch);
        widest = @max(widest, w);
    }
    return widest;
}

fn renderLegend(draw: DrawContext, legend: []const u8, content_x: f32, content_w: f32, muted: [3]f32, line: [3]f32) void {
    const legend_h = legendHeight(draw.cell_h);
    const text_x = content_x + PAD_X;
    const content_right = content_x + content_w - PAD_X;
    draw.fillQuad(content_x, legend_h, content_w, 1, line);
    const text_w = clampedTextWidth(text_x, content_right, content_w - PAD_X * 2);
    var it = TextWrap{ .text = legend, .max_w = text_w, .advance = draw.glyphAdvance };
    var line_index: usize = 0;
    while (it.next()) |display_line| : (line_index += 1) {
        if (line_index >= 3) break;
        const text_y = legend_h - draw.cell_h - 6 - @as(f32, @floatFromInt(line_index)) * (draw.cell_h + 2);
        _ = draw.renderTextLimited(display_line, text_x, text_y, muted, text_w);
    }
}

const TextWrap = struct {
    text: []const u8,
    max_w: f32,
    advance: *const fn (u32) f32,
    pos: usize = 0,

    fn next(self: *TextWrap) ?[]const u8 {
        if (self.pos >= self.text.len or self.max_w <= 0) return null;
        const start = self.pos;
        var i = start;
        var width: f32 = 0;
        var last_space: ?usize = null;
        while (i < self.text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(self.text[i]) catch 1;
            const end = @min(i + seq_len, self.text.len);
            const cp = std.unicode.utf8Decode(self.text[i..end]) catch 0xFFFD;
            if (cp == '\n') {
                self.pos = end;
                return self.text[start..i];
            }
            const w = self.advance(cp);
            if (width + w > self.max_w and i > start) {
                if (last_space) |space| {
                    if (space > start) {
                        self.pos = space + 1;
                        return self.text[start..space];
                    }
                }
                self.pos = i;
                return self.text[start..i];
            }
            if (cp == ' ') last_space = i;
            width += w;
            i = end;
        }
        self.pos = self.text.len;
        return self.text[start..];
    }
};

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

test "port_forwarding_renderer: form field labels" {
    try std.testing.expectEqualStrings("Name", formFieldLabel(0));
    try std.testing.expectEqualStrings("Profile", formFieldLabel(1));
    try std.testing.expectEqualStrings("Direction", formFieldLabel(2));
    try std.testing.expectEqualStrings("Local host", formFieldLabel(3));
    try std.testing.expectEqualStrings("Local port", formFieldLabel(4));
    try std.testing.expectEqualStrings("Remote host", formFieldLabel(5));
    try std.testing.expectEqualStrings("Remote port", formFieldLabel(6));
    try std.testing.expectEqualStrings("Auto start", formFieldLabel(7));
    try std.testing.expectEqualStrings("", formFieldLabel(99));
}

test "port_forwarding_renderer: form field values" {
    var rule = rule_mod.defaultReverseProxy("devbox");
    rule.setName("Proxy");
    rule.local_port = 18080;
    rule.remote_port = 7890;
    rule.auto_start = false;
    var buf: [32]u8 = undefined;
    const form = FormView{ .mode = "Edit forwarding rule", .focus = 4, .rule = rule };

    try std.testing.expectEqualStrings("Proxy", formFieldValue(&form, 0, &buf));
    try std.testing.expectEqualStrings("devbox", formFieldValue(&form, 1, &buf));
    try std.testing.expectEqualStrings("Reverse", formFieldValue(&form, 2, &buf));
    try std.testing.expectEqualStrings("18080", formFieldValue(&form, 4, &buf));
    try std.testing.expectEqualStrings("Manual", formFieldValue(&form, 7, &buf));
}

test "port_forwarding_renderer: empty profile renders a store hint" {
    var buf: [32]u8 = undefined;
    const rule = rule_mod.defaultReverseProxy("");
    const form = FormView{ .mode = "New forwarding rule", .focus = 1, .rule = rule };
    try std.testing.expectEqualStrings("No SSH profiles found", formFieldValue(&form, 1, &buf));
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

test "port_forwarding_renderer: form labels get full width at large font sizes" {
    const Probe = struct {
        const advance: f32 = 20;
        const widest = "Remote port";
        var widest_label_max_w: f32 = -1;

        fn fillQuad(_: f32, _: f32, _: f32, _: f32, _: [3]f32) void {}
        fn fillQuadAlpha(_: f32, _: f32, _: f32, _: f32, _: [3]f32, _: f32) void {}
        fn renderTextLimited(text: []const u8, x: f32, _: f32, _: [3]f32, max_w: f32) f32 {
            if (std.mem.eql(u8, text, widest)) widest_label_max_w = max_w;
            return x + max_w;
        }
        fn glyphAdvance(_: u32) f32 {
            return advance;
        }
    };

    const Rows = struct {
        fn rowAt(_: *anyopaque, index: usize) RowView {
            _ = index;
            return .{ .rule = rule_mod.defaultReverseProxy("devbox"), .status = .running, .auto_start = true };
        }
    };

    Probe.widest_label_max_w = -1;
    const draw = DrawContext{
        .bg = .{ 0.02, 0.02, 0.02 },
        .fg = .{ 0.95, 0.95, 0.95 },
        .accent = .{ 0.2, 0.6, 1.0 },
        .cell_h = 28,
        .fillQuad = Probe.fillQuad,
        .fillQuadAlpha = Probe.fillQuadAlpha,
        .renderTextLimited = Probe.renderTextLimited,
        .glyphAdvance = Probe.glyphAdvance,
    };
    var rows = Rows{};

    render(draw, .{
        .title = "Port Forwarding",
        .legend = "x",
        .count = 1,
        .selected = 0,
        .scroll = 0,
        .ctx = &rows,
        .rowAt = Rows.rowAt,
        .form = .{
            .mode = "New forwarding rule",
            .focus = 1,
            .rule = rule_mod.defaultReverseProxy("devbox"),
        },
    }, 900, 600, 40, 0, 760);

    const natural = @as(f32, @floatFromInt(Probe.widest.len)) * Probe.advance;
    try std.testing.expect(Probe.widest_label_max_w >= natural);
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
        marker: u8 = 0,

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
    var rows = Rows{};

    render(draw, .{
        .title = "Port Forwarding",
        .legend = "Enter start/stop  n new",
        .count = 1,
        .selected = 0,
        .scroll = 0,
        .ctx = &rows,
        .rowAt = Rows.rowAt,
    }, width, 160, 0, 0, width);

    try std.testing.expect(!InstrumentedDraw.bad_width);
}

test "port_forwarding_renderer: narrow form stays within non-negative draw bounds" {
    const InstrumentedDraw = struct {
        var bad_width: bool = false;
        var window_h: f32 = 0;

        fn fillQuad(_: f32, y: f32, w: f32, h: f32, _: [3]f32) void {
            if (std.math.isNan(w) or std.math.isNan(h) or std.math.isNan(y) or w < 0.0 or h < 0.0 or y < 0.0 or y + h > window_h + 0.01) bad_width = true;
        }
        fn fillQuadAlpha(_: f32, y: f32, w: f32, h: f32, _: [3]f32, _: f32) void {
            if (std.math.isNan(w) or std.math.isNan(h) or std.math.isNan(y) or w < 0.0 or h < 0.0 or y < 0.0 or y + h > window_h + 0.01) bad_width = true;
        }
        fn renderTextLimited(text: []const u8, x: f32, y: f32, _: [3]f32, max_w: f32) f32 {
            if (std.math.isNan(max_w) or std.math.isNan(y) or max_w < 0.0 or y < 0.0 or y > window_h + 0.01) bad_width = true;
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

    InstrumentedDraw.bad_width = false;
    InstrumentedDraw.window_h = 80;
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
    var rows = Rows{};

    render(draw, .{
        .title = "Port Forwarding",
        .legend = "Enter start/stop  n new",
        .count = 1,
        .selected = 0,
        .scroll = 0,
        .ctx = &rows,
        .rowAt = Rows.rowAt,
        .form = .{
            .mode = "New forwarding rule",
            .focus = 4,
            .rule = rule_mod.defaultReverseProxy("devbox"),
        },
    }, 48, 80, 0, 0, 48);

    try std.testing.expect(!InstrumentedDraw.bad_width);
}
