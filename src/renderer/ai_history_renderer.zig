const std = @import("std");

const HEADER_H: f32 = 54;
const FILTER_H: f32 = 42;
const ROW_H: f32 = 54;
const PAD_X: f32 = 16;
const SMALL_GAP: f32 = 6;
const BUTTON_PAD_Y: f32 = 4;
const BUTTON_EXTRA_H: f32 = 10;
const RESUME_BUTTON_W: f32 = 104;

pub const DrawContext = struct {
    bg: [3]f32,
    fg: [3]f32,
    accent: [3]f32,
    cell_h: f32,
    fillQuad: *const fn (f32, f32, f32, f32, [3]f32) void,
    fillQuadAlpha: *const fn (f32, f32, f32, f32, [3]f32, f32) void,
    renderTextLimited: *const fn ([]const u8, f32, f32, [3]f32, f32) f32,
};

pub const Layout = struct {
    left_x: f32,
    left_w: f32,
    list_x: f32,
    list_w: f32,
    detail_x: f32,
    detail_w: f32,
};

pub const Hit = union(enum) {
    none,
    refresh,
    @"resume",
    row: usize,
};

pub fn computeLayout(x: f32, width: f32) Layout {
    const available = @max(0, width);
    if (available == 0) {
        return .{
            .left_x = x,
            .left_w = 0,
            .list_x = x,
            .list_w = 0,
            .detail_x = x,
            .detail_w = 0,
        };
    }

    const min_left_w: f32 = 180;
    const min_list_w: f32 = 260;
    const min_detail_w: f32 = 120;
    const min_total = min_left_w + min_list_w + min_detail_w;
    const left_w = if (available < min_total)
        available * (min_left_w / min_total)
    else
        @min(@max(available * 0.20, min_left_w), 260);
    const list_w = if (available < min_total)
        available * (min_list_w / min_total)
    else
        @min(@max(available * 0.32, min_list_w), 420);
    const detail_w = available - left_w - list_w;
    return .{
        .left_x = x,
        .left_w = left_w,
        .list_x = x + left_w,
        .list_w = list_w,
        .detail_x = x + left_w + list_w,
        .detail_w = detail_w,
    };
}

pub fn hitTest(layout: Layout, x: f32, y_from_top: f32, row_top: f32, row_h: f32, row_count: usize) Hit {
    if (x >= layout.list_x and x < layout.list_x + layout.list_w and y_from_top >= row_top) {
        const idx_float = (y_from_top - row_top) / row_h;
        if (idx_float >= 0) {
            const idx: usize = @intFromFloat(@floor(idx_float));
            if (idx < row_count) return .{ .row = idx };
        }
    }
    return .none;
}

// Vertical band metrics scale with the UI font's cell height so the layout
// stays readable on high-DPI displays. The fixed constants act as floors so
// behaviour at the default (~16px) cell height is unchanged.
fn rowHeight(cell_h: f32) f32 {
    // Fits two stacked text lines (title + path) plus padding; see rowTextLayout.
    return @max(ROW_H, cell_h * 2 + 22);
}

fn filterHeight(cell_h: f32) f32 {
    return @max(FILTER_H, cell_h + 18);
}

fn headerHeight(cell_h: f32) f32 {
    return @max(HEADER_H, cell_h + 18);
}

const RowTextLayout = struct {
    title_top: f32,
    detail_top: f32,
};

// Offsets (from the row's top edge) of the two text lines drawn in a list row:
// the provider+title line on top and the project-path line below it.
fn rowTextLayout(cell_h: f32) RowTextLayout {
    const rh = rowHeight(cell_h);
    return .{
        .title_top = 8,
        .detail_top = rh - 9 - cell_h,
    };
}

pub fn listVisibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    const visible_h = @max(0, content_h - filterHeight(cell_h));
    return @intFromFloat(@max(0, @floor(visible_h / rowHeight(cell_h))));
}

pub fn interactionHitTest(
    session: anytype,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    x: f32,
    width: f32,
    cell_h: f32,
    mouse_x: f64,
    mouse_y: f64,
) Hit {
    _ = window_width;
    const content_x = @round(x);
    const content_w = @round(@max(1.0, width));
    const top = @round(titlebar_offset);
    const layout = computeLayout(content_x, content_w);
    const mx: f32 = @floatCast(mouse_x);
    const my: f32 = @floatCast(mouse_y);

    const refresh_top = refreshButtonTop(top, cell_h);
    if (rectContains(mx, my, layout.left_x + PAD_X, refresh_top, @max(0, layout.left_w - PAD_X * 2), buttonHeight(cell_h))) {
        return .refresh;
    }

    const visible_count = session.visibleCount();
    if (visible_count > 0) {
        const resume_top = resumeButtonTop(top, cell_h);
        if (rectContains(mx, my, layout.detail_x + PAD_X, resume_top, RESUME_BUTTON_W, buttonHeight(cell_h))) {
            return .@"resume";
        }
    }

    const max_rows = listVisibleCapacity(window_height, top, cell_h);
    const start = session.listWindowStart(max_rows);
    const row_count = if (visible_count > start) @min(max_rows, visible_count - start) else 0;
    return switch (hitTest(layout, mx, my, top + filterHeight(cell_h), rowHeight(cell_h), row_count)) {
        .row => |idx| .{ .row = start + idx },
        else => .none,
    };
}

pub fn render(
    draw: DrawContext,
    session: anytype,
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
    const panel = mixColor(bg, fg, 0.045);
    const panel_strong = mixColor(bg, fg, 0.075);
    const line = mixColor(bg, fg, 0.18);
    const muted = mixColor(bg, fg, 0.58);
    const selected_bg = mixColor(bg, accent, 0.18);

    const layout = computeLayout(content_x, content_w);
    draw.fillQuad(content_x, 0, content_w, content_h, bg);
    draw.fillQuadAlpha(layout.left_x, 0, layout.left_w, content_h, panel, 0.96);
    draw.fillQuadAlpha(layout.list_x, 0, layout.list_w, content_h, mixColor(bg, fg, 0.025), 0.98);
    draw.fillQuadAlpha(layout.detail_x, 0, layout.detail_w, content_h, bg, 1.0);
    draw.fillQuad(layout.list_x, 0, 1, content_h, line);
    draw.fillQuad(layout.detail_x, 0, 1, content_h, line);

    renderLeftColumn(draw, session, layout, window_height, top, content_h, fg, muted, accent, panel_strong, line);
    renderList(draw, session, layout, window_height, top, content_h, fg, muted, accent, selected_bg, line);
    renderDetail(draw, session, layout, window_height, top, content_h, fg, muted, accent, panel_strong, line);
}

fn renderLeftColumn(
    draw: DrawContext,
    session: anytype,
    layout: Layout,
    window_height: f32,
    top: f32,
    content_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    panel_strong: [3]f32,
    line: [3]f32,
) void {
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(layout.left_x, yFromTop(window_height, top, header_h), layout.left_w, header_h, panel_strong, 0.9);
    draw.fillQuad(layout.left_x, yFromTop(window_height, top + header_h, 1), layout.left_w, 1, line);
    _ = draw.renderTextLimited("AI History", layout.left_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.left_w - PAD_X * 2);

    var y = top + header_h + 18;
    _ = draw.renderTextLimited(session.source.name, layout.left_x + PAD_X, yTextFromTop(draw, window_height, y), fg, layout.left_w - PAD_X * 2);
    y += draw.cell_h + 8;
    _ = draw.renderTextLimited(targetLabel(session.source.target), layout.left_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.left_w - PAD_X * 2);
    y += draw.cell_h + 18;
    _ = draw.renderTextLimited("Status", layout.left_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.left_w - PAD_X * 2);
    y += draw.cell_h + 5;
    _ = draw.renderTextLimited(statusText(session), layout.left_x + PAD_X, yTextFromTop(draw, window_height, y), accent, layout.left_w - PAD_X * 2);
    y += draw.cell_h + 18;
    _ = draw.renderTextLimited("r  Retry scan", layout.left_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.left_w - PAD_X * 2);

    const footer = "Enter resumes  Space previews";
    _ = draw.renderTextLimited(footer, layout.left_x + PAD_X, 12, muted, layout.left_w - PAD_X * 2);
    _ = content_h;
}

fn renderList(
    draw: DrawContext,
    session: anytype,
    layout: Layout,
    window_height: f32,
    top: f32,
    content_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    selected_bg: [3]f32,
    line: [3]f32,
) void {
    const filter_h = filterHeight(draw.cell_h);
    const filter_y = yFromTop(window_height, top, filter_h);
    draw.fillQuadAlpha(layout.list_x, filter_y, layout.list_w, filter_h, mixColor(draw.bg, fg, 0.055), 0.98);
    draw.fillQuad(layout.list_x, yFromTop(window_height, top + filter_h, 1), layout.list_w, 1, line);

    const query = session.filter[0..session.filter_len];
    const filter_label = if (query.len == 0) "Search sessions" else query;
    const filter_color = if (query.len == 0) muted else fg;
    _ = draw.renderTextLimited(filter_label, layout.list_x + PAD_X, yTextFromTop(draw, window_height, top + 11), filter_color, layout.list_w - PAD_X * 2);

    const row_h = rowHeight(draw.cell_h);
    const lines = rowTextLayout(draw.cell_h);
    const row_top = top + filter_h;
    _ = content_h;
    const max_rows = listVisibleCapacity(window_height, top, draw.cell_h);
    const start = session.listWindowStart(max_rows);
    var visible_index: usize = 0;
    var rendered: usize = 0;
    for (session.rows.items) |row| {
        if (!metadataMatches(row, query)) continue;
        if (visible_index < start) {
            visible_index += 1;
            continue;
        }
        if (rendered >= max_rows) break;

        const row_top_px = row_top + @as(f32, @floatFromInt(rendered)) * row_h;
        const row_y = yFromTop(window_height, row_top_px, row_h);
        const selected = visible_index == session.selected;
        if (selected) {
            draw.fillQuadAlpha(layout.list_x, row_y, layout.list_w, row_h, selected_bg, 0.92);
            draw.fillQuad(layout.list_x, row_y, 3, row_h, accent);
        }
        draw.fillQuadAlpha(layout.list_x, row_y, layout.list_w, 1, line, 0.55);

        const title = displayTitle(row);
        const title_y = yTextFromTop(draw, window_height, row_top_px + lines.title_top);
        const provider_end = draw.renderTextLimited(row.provider.label(), layout.list_x + PAD_X, title_y, accent, 86);
        _ = draw.renderTextLimited(title, provider_end + 8, title_y, fg, layout.list_w - (provider_end - layout.list_x) - PAD_X - 8);
        const detail = if (row.project_dir.len > 0) row.project_dir else row.source_path;
        const detail_y = yTextFromTop(draw, window_height, row_top_px + lines.detail_top);
        _ = draw.renderTextLimited(detail, layout.list_x + PAD_X, detail_y, muted, layout.list_w - PAD_X * 2);

        rendered += 1;
        visible_index += 1;
    }

    if (session.visibleCount() == 0) {
        const empty = if (session.state == .scanning)
            "Scanning AI history..."
        else if (session.rows.items.len == 0)
            "No Codex or Claude Code history found"
        else
            "No sessions match filter";
        _ = draw.renderTextLimited(empty, layout.list_x + PAD_X, yTextFromTop(draw, window_height, row_top + 24), muted, layout.list_w - PAD_X * 2);
    }
}

fn renderDetail(
    draw: DrawContext,
    session: anytype,
    layout: Layout,
    window_height: f32,
    top: f32,
    content_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    panel_strong: [3]f32,
    line: [3]f32,
) void {
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(layout.detail_x, yFromTop(window_height, top, header_h), layout.detail_w, header_h, panel_strong, 0.82);
    draw.fillQuad(layout.detail_x, yFromTop(window_height, top + header_h, 1), layout.detail_w, 1, line);
    _ = draw.renderTextLimited("Transcript Preview", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.detail_w - PAD_X * 2);

    const selected = session.selectedVisible() orelse {
        _ = draw.renderTextLimited("Select a session", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, top + header_h + 24), muted, layout.detail_w - PAD_X * 2);
        return;
    };

    var y = top + header_h + 18;
    _ = draw.renderTextLimited(displayTitle(selected), layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), fg, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 8;
    _ = draw.renderTextLimited(selected.provider.label(), layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), accent, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 8;
    _ = draw.renderTextLimited(if (selected.project_dir.len > 0) selected.project_dir else "Project dir unavailable", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 8;
    _ = draw.renderTextLimited(selected.source_path, layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2);
    y += draw.cell_h + 16;
    const resume_top = resumeButtonTop(top, draw.cell_h);
    const can_resume = selected.project_dir.len > 0;
    draw.fillQuadAlpha(layout.detail_x + PAD_X, yFromTop(window_height, resume_top, buttonHeight(draw.cell_h)), RESUME_BUTTON_W, buttonHeight(draw.cell_h), panel_strong, 0.72);
    _ = draw.renderTextLimited(if (can_resume) "Resume" else "Resume unavailable", layout.detail_x + PAD_X + 12, yTextFromTop(draw, window_height, y), if (can_resume) accent else muted, RESUME_BUTTON_W - 24);

    y += draw.cell_h + 20;
    draw.fillQuadAlpha(layout.detail_x + PAD_X, yFromTop(window_height, y, 1), layout.detail_w - PAD_X * 2, 1, line, 0.78);
    y += 14;

    switch (session.transcript_state) {
        .idle => _ = draw.renderTextLimited("Press Space to load transcript", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2),
        .loading => _ = draw.renderTextLimited("Loading transcript", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), muted, layout.detail_w - PAD_X * 2),
        .failed => _ = draw.renderTextLimited("Transcript failed to load - press Space to retry", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, y), accent, layout.detail_w - PAD_X * 2),
        .ready => renderTranscriptMessages(draw, session.transcript, layout, window_height, y, content_h, fg, muted, accent),
    }
}

fn renderTranscriptMessages(
    draw: DrawContext,
    messages: anytype,
    layout: Layout,
    window_height: f32,
    start_top: f32,
    content_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
) void {
    if (messages.len == 0) {
        _ = draw.renderTextLimited("Transcript is empty", layout.detail_x + PAD_X, yTextFromTop(draw, window_height, start_top), muted, layout.detail_w - PAD_X * 2);
        return;
    }

    const row_h = draw.cell_h + 8;
    _ = content_h;
    const max_rows = transcriptPreviewRowCapacity(window_height, start_top, row_h);
    const count = @min(messages.len, max_rows);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const msg = messages[i];
        const y = yTextFromTop(draw, window_height, start_top + @as(f32, @floatFromInt(i)) * row_h);
        const role_text = roleLabel(msg.role);
        const role_color = if (msg.role == .assistant) accent else muted;
        const role_end = draw.renderTextLimited(role_text, layout.detail_x + PAD_X, y, role_color, 78);
        _ = draw.renderTextLimited(msg.content, role_end + SMALL_GAP, y, fg, layout.detail_w - (role_end - layout.detail_x) - PAD_X - SMALL_GAP);
    }
}

fn displayTitle(row: anytype) []const u8 {
    if (row.title.len > 0) return row.title;
    if (row.summary.len > 0) return row.summary;
    return row.session_id;
}

fn statusText(session: anytype) []const u8 {
    if (session.status.len > 0) {
        if (std.mem.eql(u8, session.status, "Ready with warnings")) return "Scan completed with warnings";
        return session.status;
    }
    return switch (session.state) {
        .idle => "Idle",
        .scanning => "Scanning AI history...",
        .ready => "Ready",
        .failed => "Connection failed - press r to retry",
    };
}

fn targetLabel(target: anytype) []const u8 {
    return switch (target) {
        .local => "Local",
        .wsl => "WSL",
        .ssh => "SSH",
    };
}

fn roleLabel(role: anytype) []const u8 {
    return switch (role) {
        .user => "user:",
        .assistant => "assistant:",
        .system => "system:",
        .tool => "tool:",
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

fn metadataMatches(meta: anytype, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsIgnoreCase(meta.title, query) or
        containsIgnoreCase(meta.summary, query) or
        containsIgnoreCase(meta.project_dir, query) or
        containsIgnoreCase(meta.session_id, query) or
        containsIgnoreCase(meta.source_path, query);
}

fn containsIgnoreCase(haystack: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > haystack.len) return false;
    var i: usize = 0;
    while (i + query.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (query, 0..) |qch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(qch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn buttonHeight(cell_h: f32) f32 {
    return cell_h + BUTTON_EXTRA_H;
}

fn refreshButtonTop(top: f32, cell_h: f32) f32 {
    return top + headerHeight(cell_h) + 18 +
        (cell_h + 8) +
        (cell_h + 18) +
        (cell_h + 5) +
        (cell_h + 18) - BUTTON_PAD_Y;
}

fn resumeButtonTop(top: f32, cell_h: f32) f32 {
    return top + headerHeight(cell_h) + 18 +
        (cell_h + 8) +
        (cell_h + 8) +
        (cell_h + 8) +
        (cell_h + 16) - BUTTON_PAD_Y;
}

fn rectContains(x: f32, y: f32, left: f32, top: f32, width: f32, height: f32) bool {
    return width > 0 and height > 0 and
        x >= left and x < left + width and
        y >= top and y < top + height;
}

fn transcriptPreviewRowCapacity(window_height: f32, start_top: f32, row_h: f32) usize {
    if (row_h <= 0) return 0;
    return @intFromFloat(@max(0, @floor(@max(0, window_height - start_top) / row_h)));
}

test "ai_history_renderer: list row lines never overlap as ui font grows" {
    const cell_heights = [_]f32{ 12, 16, 18, 22, 28, 32, 40 };
    for (cell_heights) |cell_h| {
        const lines = rowTextLayout(cell_h);
        // The path line must begin at or below the bottom of the title line.
        try std.testing.expect(lines.detail_top >= lines.title_top + cell_h);
        // Both lines must stay inside the row box.
        try std.testing.expect(lines.title_top >= 0);
        try std.testing.expect(lines.detail_top + cell_h <= rowHeight(cell_h) + 0.001);
    }
}

test "ai_history_renderer: hit test maps list rows" {
    const layout = computeLayout(0, 1000);
    const hit = hitTest(layout, layout.list_x + 10, 120, 100, 24, 5);
    try std.testing.expectEqual(@as(usize, 0), hit.row);
}

test "ai_history_renderer: layout keeps a readable detail column" {
    const layout = computeLayout(0, 1200);
    try std.testing.expect(layout.left_w >= 180);
    try std.testing.expect(layout.list_w >= 260);
    try std.testing.expect(layout.detail_w >= 120);
    try std.testing.expectEqual(layout.left_x + layout.left_w, layout.list_x);
    try std.testing.expectEqual(layout.list_x + layout.list_w, layout.detail_x);
}

test "ai_history_renderer: narrow layout stays inside available width" {
    const layout = computeLayout(10, 300);
    try std.testing.expect(layout.left_w >= 0);
    try std.testing.expect(layout.list_w >= 0);
    try std.testing.expect(layout.detail_w >= 0);
    try std.testing.expectEqual(layout.left_x + layout.left_w, layout.list_x);
    try std.testing.expectEqual(layout.list_x + layout.list_w, layout.detail_x);
    try std.testing.expect(layout.detail_x + layout.detail_w <= 310.001);
}

test "ai_history_renderer: zero width layout has no columns" {
    const layout = computeLayout(20, 0);
    try std.testing.expectEqual(@as(f32, 0), layout.left_w);
    try std.testing.expectEqual(@as(f32, 0), layout.list_w);
    try std.testing.expectEqual(@as(f32, 0), layout.detail_w);
    try std.testing.expectEqual(@as(f32, 20), layout.left_x);
    try std.testing.expectEqual(@as(f32, 20), layout.list_x);
    try std.testing.expectEqual(@as(f32, 20), layout.detail_x);
}

test "ai_history_renderer: transcript row capacity uses absolute window bottom" {
    try std.testing.expectEqual(@as(usize, 10), transcriptPreviewRowCapacity(600, 300, 30));
    try std.testing.expectEqual(@as(usize, 0), transcriptPreviewRowCapacity(300, 300, 30));
}

test "ai_history_renderer: interaction hit test maps buttons and row offset" {
    const FakeSession = struct {
        fn visibleCount(_: @This()) usize {
            return 8;
        }

        fn listWindowStart(_: @This(), _: usize) usize {
            return 3;
        }
    };

    const session = FakeSession{};
    const layout = computeLayout(0, 1000);
    const cell_h: f32 = 16;
    const top: f32 = 40;

    try std.testing.expectEqual(
        Hit.refresh,
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + PAD_X + 4, refreshButtonTop(top, cell_h) + 2),
    );
    try std.testing.expectEqual(
        Hit.@"resume",
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.detail_x + PAD_X + 4, resumeButtonTop(top, cell_h) + 2),
    );
    const row_hit = interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.list_x + 8, top + FILTER_H + ROW_H + 2);
    try std.testing.expectEqual(@as(usize, 4), row_hit.row);
}
