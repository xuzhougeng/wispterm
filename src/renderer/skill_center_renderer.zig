const std = @import("std");
const pairing = @import("../skill_pairing.zig");
const ai_history_renderer = @import("ai_history_renderer.zig");
const i18n = @import("../i18n.zig");

pub const DrawContext = ai_history_renderer.DrawContext;

const HEADER_H: f32 = 54;
const COLHEAD_H: f32 = 40;
const ROW_H: f32 = 30;
const PAD_X: f32 = 16;
const LEGEND_H: f32 = 36;
/// Left band: provider tag column + skill name. Two status columns follow it.
const NAME_W: f32 = 320;
/// Fixed width of the provider tag column, so skill names line up and the
/// claude/codex tags get a clear, separated slot.
const TAG_W: f32 = 84;
const COL_W: f32 = 120;
const SMALL_GAP: f32 = 6;

pub const View = struct {
    rows: []const pairing.PairRow,
    server_name: []const u8, // selected server display name, or "" if none
    server_reachable: bool,
    sel_row: usize,
    scroll: usize,
    stale: bool,
    status: []const u8,
    confirm_text: []const u8, // "" when no confirm pending
};

fn localGlyph(rel: pairing.Relation) []const u8 {
    return switch (rel) {
        .same, .differ, .local_only, .unknown => "✓",
        .remote_only => "—",
    };
}

fn remoteGlyph(rel: pairing.Relation) []const u8 {
    return switch (rel) {
        .same, .remote_only => "✓",
        .differ => "≠",
        .local_only => "—",
        .unknown => "?",
    };
}

fn hintFor(rel: pairing.Relation) []const u8 {
    const t = i18n.s();
    return switch (rel) {
        .same => t.sc_hint_same,
        .differ => t.sc_hint_differ,
        .local_only => t.sc_hint_local_only,
        .remote_only => t.sc_hint_remote_only,
        .unknown => t.sc_hint_unknown,
    };
}

/// Distinct color per provider so the claude/codex tags are tellable apart at a
/// glance (the short tag text alone — "cla"/"cod" — reads as noise).
fn providerColor(provider: pairing.Provider) [3]f32 {
    return switch (provider) {
        .claude => .{ 0.85, 0.52, 0.28 }, // warm orange
        .codex => .{ 0.40, 0.72, 0.74 }, // teal
    };
}

fn headerHeight(cell_h: f32) f32 {
    return @max(HEADER_H, cell_h + 18);
}
fn colHeaderHeight(cell_h: f32) f32 {
    return @max(COLHEAD_H, cell_h + 14);
}
fn rowHeight(cell_h: f32) f32 {
    return @max(ROW_H, cell_h + 12);
}
fn legendHeight(cell_h: f32) f32 {
    return @max(LEGEND_H, cell_h + 18);
}

pub fn bodyVisibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    const header_h = headerHeight(cell_h) + colHeaderHeight(cell_h);
    const usable = content_h - header_h - legendHeight(cell_h);
    if (usable <= 0) return 0;
    return @intFromFloat(@max(0.0, @floor(usable / rowHeight(cell_h))));
}

fn clampScroll(requested: usize, total: usize, visible: usize) usize {
    if (total <= visible) return 0;
    return @min(requested, total - visible);
}

fn yFromTop(window_height: f32, top_px: f32, h: f32) f32 {
    return window_height - top_px - h;
}
fn yTextFromTop(draw: DrawContext, window_height: f32, top_px: f32) f32 {
    return window_height - top_px - draw.cell_h;
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const c = @max(0.0, @min(1.0, t));
    return .{ a[0] + (b[0] - a[0]) * c, a[1] + (b[1] - a[1]) * c, a[2] + (b[2] - a[2]) * c };
}

/// Color for the REMOTE column glyph (the local column uses a plain
/// present/absent fg/muted; see render). `fg` is unused today but kept in the
/// signature so callers don't need to special-case the palette.
fn colorForRelation(rel: pairing.Relation, fg: [3]f32, muted: [3]f32) [3]f32 {
    _ = fg;
    return switch (rel) {
        .same => .{ 0.36, 0.74, 0.42 }, // green: in sync
        .differ => .{ 0.86, 0.70, 0.28 }, // yellow: content differs
        .local_only => muted, // remote `—`: not on the server
        .remote_only => .{ 0.42, 0.62, 0.88 }, // blue: only on the server
        .unknown => muted, // `?`: couldn't check
    };
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

    // --- Header: title + "Local N ⇆ <server> M" + status. ---
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(content_x, yFromTop(window_height, top, header_h), content_w, header_h, panel_strong, 0.9);
    draw.fillQuad(content_x, yFromTop(window_height, top + header_h, 1), content_w, 1, line);

    const title_y = yTextFromTop(draw, window_height, top + 11);
    const title_end = draw.renderTextLimited("Skill Center", content_x + PAD_X, title_y, fg, content_w - PAD_X * 2);

    // Counts: local is always known (local presence is never ambiguous); the
    // remote count counts every row present on the server, which is only
    // meaningful when the server is reachable and fresh (when offline, `unknown`
    // rows don't imply remote presence) — so it's shown only in that case.
    var local_count: usize = 0;
    var remote_count: usize = 0;
    for (view.rows) |r| {
        if (r.relation != .remote_only) local_count += 1;
        if (r.relation != .local_only) remote_count += 1;
    }
    const t = i18n.s();
    var sub_buf: [192]u8 = undefined;
    const sub = if (view.server_name.len == 0)
        std.fmt.bufPrint(&sub_buf, "{s} {d} {s}", .{ t.sc_local, local_count, t.sc_no_server }) catch ""
    else if (view.stale)
        std.fmt.bufPrint(&sub_buf, "{s} {d} ⇆ {s} {s}", .{ t.sc_local, local_count, view.server_name, t.sc_cached }) catch ""
    else if (!view.server_reachable)
        std.fmt.bufPrint(&sub_buf, "{s} {d} ⇆ {s} {s}", .{ t.sc_local, local_count, view.server_name, t.sc_offline }) catch ""
    else
        std.fmt.bufPrint(&sub_buf, "{s} {d} ⇆ {s} {d}", .{ t.sc_local, local_count, view.server_name, remote_count }) catch "";
    const sub_x = title_end + 16;
    _ = draw.renderTextLimited(sub, sub_x, title_y, muted, @max(0, content_x + content_w - PAD_X - sub_x));

    if (view.status.len > 0) {
        const status_w: f32 = 220;
        const status_x = content_x + content_w - PAD_X - status_w;
        if (status_x > sub_x) _ = draw.renderTextLimited(view.status, status_x, title_y, accent, status_w);
    }

    // --- Column header row: 本地 | <server>. ---
    const colhead_h = colHeaderHeight(draw.cell_h);
    const colhead_top = top + header_h;
    draw.fillQuadAlpha(content_x, yFromTop(window_height, colhead_top, colhead_h), content_w, colhead_h, mixColor(bg, fg, 0.04), 0.95);
    draw.fillQuad(content_x, yFromTop(window_height, colhead_top + colhead_h, 1), content_w, 1, line);

    const col0_x = content_x + PAD_X + NAME_W;
    const col1_x = col0_x + COL_W;
    const colhead_text_y = yTextFromTop(draw, window_height, colhead_top + (colhead_h - draw.cell_h) / 2);
    _ = draw.renderTextLimited(t.sc_local, col0_x, colhead_text_y, fg, COL_W - SMALL_GAP);
    const server_col_color = if (view.server_reachable) fg else muted;
    const server_label = if (view.server_name.len == 0) "—" else view.server_name;
    _ = draw.renderTextLimited(server_label, col1_x, colhead_text_y, server_col_color, COL_W - SMALL_GAP);

    // --- Empty state. ---
    if (view.rows.len == 0) {
        _ = draw.renderTextLimited(
            t.sc_scanning,
            content_x + PAD_X,
            yTextFromTop(draw, window_height, colhead_top + colhead_h + 24),
            muted,
            content_w - PAD_X * 2,
        );
        renderLegend(draw, content_x, content_w, muted, line);
        return;
    }

    // --- Body rows. ---
    const row_h = rowHeight(draw.cell_h);
    const body_top = colhead_top + colhead_h;
    const cap = bodyVisibleCapacity(window_height, top, draw.cell_h);
    const scroll = clampScroll(view.scroll, view.rows.len, cap);

    var rendered: usize = 0;
    var ri: usize = scroll;
    while (ri < view.rows.len and rendered < cap) : (ri += 1) {
        const row_top_px = body_top + @as(f32, @floatFromInt(rendered)) * row_h;
        const row_y = yFromTop(window_height, row_top_px, row_h);

        if (ri == view.sel_row) {
            draw.fillQuadAlpha(content_x, row_y, content_w, row_h, selected_bg, 0.55);
            draw.fillQuad(content_x, row_y, 3, row_h, accent);
        }
        draw.fillQuadAlpha(content_x, row_y, content_w, 1, line, 0.4);

        const pr = view.rows[ri];
        const text_y = yTextFromTop(draw, window_height, row_top_px + (row_h - draw.cell_h) / 2);

        // Provider tag in its own fixed column, color-coded per provider so
        // claude vs codex are tellable apart; names align at a fixed offset.
        _ = draw.renderTextLimited(pr.provider.toString(), content_x + PAD_X, text_y, providerColor(pr.provider), TAG_W - SMALL_GAP);
        const name_x = content_x + PAD_X + TAG_W;
        _ = draw.renderTextLimited(pr.name, name_x, text_y, fg, @max(0, col0_x - name_x - SMALL_GAP));

        // Local column is the hub baseline: it shows presence only (fg when the
        // skill is present locally, muted for the `—` when it isn't). All the
        // divergence semantics (green=same, yellow=differ, …) live in the remote
        // column where the action is.
        const local_present = pr.relation != .remote_only;
        _ = draw.renderTextLimited(localGlyph(pr.relation), col0_x, text_y, if (local_present) fg else muted, COL_W - SMALL_GAP);
        _ = draw.renderTextLimited(remoteGlyph(pr.relation), col1_x, text_y, colorForRelation(pr.relation, fg, muted), COL_W - SMALL_GAP);

        const hint_x = col1_x + COL_W;
        _ = draw.renderTextLimited(hintFor(pr.relation), hint_x, text_y, muted, @max(0, content_x + content_w - PAD_X - hint_x));

        rendered += 1;
    }

    if (view.confirm_text.len > 0) {
        const bar_h = rowHeight(draw.cell_h);
        const bar_y = legendHeight(draw.cell_h);
        draw.fillQuadAlpha(content_x, bar_y, content_w, bar_h, mixColor(bg, accent, 0.22), 0.97);
        const t_y = bar_y + (bar_h - draw.cell_h) / 2;
        _ = draw.renderTextLimited(view.confirm_text, content_x + PAD_X, t_y, fg, content_w - PAD_X * 2);
        return; // the confirm bar replaces the legend line while active
    }

    renderLegend(draw, content_x, content_w, muted, line);
}

fn renderLegend(draw: DrawContext, content_x: f32, content_w: f32, muted: [3]f32, line: [3]f32) void {
    const legend_h = legendHeight(draw.cell_h);
    draw.fillQuad(content_x, legend_h, content_w, 1, line);
    const text_y = (legend_h - draw.cell_h) / 2;
    _ = draw.renderTextLimited(i18n.s().sc_legend, content_x + PAD_X, text_y, muted, content_w - PAD_X * 2);
}

// --- Tests ---

test "skill_center_renderer: relation glyphs" {
    try std.testing.expectEqualStrings("✓", localGlyph(.same));
    try std.testing.expectEqualStrings("✓", localGlyph(.local_only));
    try std.testing.expectEqualStrings("—", localGlyph(.remote_only));
    try std.testing.expectEqualStrings("✓", remoteGlyph(.same));
    try std.testing.expectEqualStrings("≠", remoteGlyph(.differ));
    try std.testing.expectEqualStrings("—", remoteGlyph(.local_only));
    try std.testing.expectEqualStrings("✓", remoteGlyph(.remote_only));
    try std.testing.expectEqualStrings("?", remoteGlyph(.unknown));
}

test "skill_center_renderer: clampScroll keeps scroll within range" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(5, 3, 10));
    try std.testing.expectEqual(@as(usize, 2), clampScroll(5, 12, 10));
    try std.testing.expectEqual(@as(usize, 1), clampScroll(1, 12, 10));
}

test "skill_center_renderer: bodyVisibleCapacity grows with height" {
    const cell_h: f32 = 16;
    try std.testing.expect(bodyVisibleCapacity(800, 40, cell_h) >= bodyVisibleCapacity(200, 40, cell_h));
    try std.testing.expectEqual(@as(usize, 0), bodyVisibleCapacity(40, 40, cell_h));
}
