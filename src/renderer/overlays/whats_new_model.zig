//! Pure layout + scroll + hit-test + URL helpers for the "What's New" modal.
//! No GPU or AppWindow dependencies — unit-tested in the fast suite.
const std = @import("std");
const md = @import("../../markdown_text.zig");
const ui_patterns = @import("../ui_patterns.zig");

pub const Action = enum { none, view_on_github, close };

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.w and
            py >= self.y and py <= self.y + self.h;
    }
};

/// All rects use a top-left origin (y grows downward). overlays converts to its
/// bottom-up draw space.
pub const Layout = struct {
    panel: Rect,
    header: Rect,
    content: Rect,
    footer: Rect,
    view_btn: Rect,
    close_btn: Rect,
    title_close_btn: Rect,
    visible_rows: usize,
};

pub const ButtonMetrics = struct {
    view_w: f32 = 156,
    close_w: f32 = 72,
};

/// Counting and drawing use this same measured, UTF-8-safe word wrapper.
/// Only a token wider than the viewport is split, always at a codepoint boundary.
pub const WrappedRows = struct {
    text: []const u8,
    width: f32,
    advance: *const fn (u32) f32,
    offset: usize = 0,
    done: bool = false,

    pub fn next(self: *WrappedRows) ?[]const u8 {
        if (self.done) return null;
        const start = self.offset;
        var end = start;
        var last_space: ?usize = null;
        var used: f32 = 0;
        while (end < self.text.len) {
            const len = std.unicode.utf8ByteSequenceLength(self.text[end]) catch 1;
            const next_end = @min(self.text.len, end + len);
            const cp = std.unicode.utf8Decode(self.text[end..next_end]) catch 0xfffd;
            if (cp == ' ' or cp == '\t') last_space = end;
            const width = self.advance(cp);
            if (end > start and used + width > self.width) {
                if (last_space) |space| {
                    if (space > start) end = space;
                }
                break;
            }
            used += width;
            end = next_end;
        }
        self.offset = end;
        while (self.offset < self.text.len and
            (self.text[self.offset] == ' ' or self.text[self.offset] == '\t')) self.offset += 1;
        self.done = self.offset == self.text.len;
        return std.mem.trimRight(u8, self.text[start..end], " \t");
    }
};

pub fn wrappedRowCount(text: []const u8, width: f32, advance: *const fn (u32) f32) usize {
    var rows: WrappedRows = .{ .text = text, .width = width, .advance = advance };
    var count: usize = 0;
    while (rows.next() != null) count += 1;
    return count;
}

/// Join Markdown soft line breaks before wrapping to the actual viewport.
/// Offsets survive buffer growth; no fixed summary/line buffer truncates notes.
pub const Document = struct {
    pub const Block = struct {
        start: usize,
        len: usize,
        style: md.LineStyle,

        pub fn indented(self: Block) bool {
            return self.style == .list or self.style == .quote or self.style == .code;
        }
    };

    text: std.ArrayList(u8) = .empty,
    blocks: std.ArrayList(Block) = .empty,

    pub fn init(allocator: std.mem.Allocator, notes: []const u8) !Document {
        var doc: Document = .{};
        errdefer doc.deinit(allocator);
        const scratch = try allocator.alloc(u8, notes.len);
        defer allocator.free(scratch);
        var in_code = false;
        var lines = std.mem.splitScalar(u8, notes, '\n');
        while (lines.next()) |raw| {
            const line = md.cleanedLine(scratch, raw, in_code);
            if (line.style == .fence) in_code = !in_code;
            const previous = if (doc.blocks.items.len > 0) &doc.blocks.items[doc.blocks.items.len - 1] else null;
            const join = if (previous) |prev|
                (line.style == .quote and prev.style == .quote) or
                    (line.style == .normal and (prev.style == .normal or prev.style == .list))
            else
                false;
            if (join) {
                try doc.text.append(allocator, ' ');
                try doc.text.appendSlice(allocator, line.text);
                previous.?.len = doc.text.items.len - previous.?.start;
            } else {
                const start = doc.text.items.len;
                try doc.text.appendSlice(allocator, line.text);
                try doc.blocks.append(allocator, .{ .start = start, .len = line.text.len, .style = line.style });
            }
        }
        return doc;
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.blocks.deinit(allocator);
    }

    pub fn blockText(self: Document, block: Block) []const u8 {
        return self.text.items[block.start..][0..block.len];
    }

    pub fn totalRows(self: Document, width: f32, indented_width: f32, advance: *const fn (u32) f32) usize {
        var total: usize = 0;
        for (self.blocks.items) |block| {
            total += wrappedRowCount(self.blockText(block), if (block.indented()) indented_width else width, advance);
        }
        return total;
    }
};

/// The embedded release notes may include localized sections after a markdown
/// divider. The modal shows the first (English) section in-app.
pub fn englishNotes(notes: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, notes, "\n---") orelse notes.len;
    return std.mem.trimRight(u8, notes[0..end], " \t\r\n");
}

/// All release text, including the full opening summary, belongs in the
/// scrollable area. Only the H1 is omitted because it is the fixed modal title.
pub fn bodyNotes(notes: []const u8) []const u8 {
    const english = englishNotes(notes);
    var cursor: usize = 0;

    skipBlankLines(english, &cursor);
    if (cursor < english.len) {
        const first = md.nextSourceLine(english, cursor);
        var clean_buf: [1024]u8 = undefined;
        const cleaned = md.cleanedLine(&clean_buf, first.line, false);
        if (cleaned.style == .heading and cleaned.heading_level == 1) {
            cursor = first.next;
        }
    }

    return std.mem.trimLeft(u8, english[cursor..], " \t\r\n");
}

/// Clamp a (possibly negative or overscrolled) line offset into range.
pub fn clampScroll(offset: i64, total_lines: usize, visible_lines: usize) usize {
    if (total_lines <= visible_lines) return 0;
    const max_off: i64 = @intCast(total_lines - visible_lines);
    if (offset < 0) return 0;
    if (offset > max_off) return @intCast(max_off);
    return @intCast(offset);
}

/// Which button (if any) a top-left-origin point hits.
pub fn buttonActionAt(layout: Layout, px: f32, py: f32) Action {
    if (layout.title_close_btn.contains(px, py)) return .close;
    if (layout.view_btn.contains(px, py)) return .view_on_github;
    if (layout.close_btn.contains(px, py)) return .close;
    return .none;
}

pub const fallback_url = "https://github.com/xuzhougeng/wispterm/releases/latest";

/// Build the release page URL for `version` (e.g. ".../releases/tag/v1.10.0").
/// Falls back to the latest-releases page if formatting fails.
pub fn releaseTagUrl(buf: []u8, version: []const u8) []const u8 {
    const v = std.mem.trimLeft(u8, version, "vV");
    return std.fmt.bufPrint(
        buf,
        "https://github.com/xuzhougeng/wispterm/releases/tag/v{s}",
        .{v},
    ) catch fallback_url;
}

/// Centered modal layout. `row_h` is the pixel height of one text row.
pub fn computeLayout(window_w: f32, window_h: f32, row_h: f32) Layout {
    return computeLayoutWithButtons(window_w, window_h, row_h, .{});
}

/// Centered modal layout with caller-supplied button widths. The renderer uses
/// measured label widths here so centered text cannot escape the panel.
pub fn computeLayoutWithButtons(window_w: f32, window_h: f32, row_h: f32, buttons: ButtonMetrics) Layout {
    // Scale with UI text metrics, then let viewport gutters win over minima.
    const scale = @max(1.0, row_h / 30.0);
    const gutter = @min(40.0 * scale, @min(window_w, window_h) * 0.05);
    const panel_w = ui_patterns.modalWidth(window_w, 320, 860 * scale, 1200 * scale, gutter);
    const panel_h = @round(@max(1.0, @min(window_h - gutter * 2, 620 * scale)));
    const panel_x = @round((window_w - panel_w) / 2);
    const panel_y = @round((window_h - panel_h) / 2);
    const pad = @min(34 * scale, panel_w * 0.06);
    const gap = @min(16 * scale, panel_w * 0.03);
    const inner_w = @max(0, panel_w - pad * 2);
    const ok_w = @min(inner_w, @max(72, buttons.close_w));
    const view_w = @min(inner_w, @max(156, buttons.view_w));
    const stacked = view_w + ok_w + gap > inner_w;
    const btn_h = @round(@max(34, row_h + 14));
    const footer_h = @min(panel_h * 0.5, (if (stacked) btn_h * 2 + gap else btn_h) + 24 * scale);
    const header_h = @min(panel_h - footer_h, @round(@max(86, row_h * 2 + 34 * scale)));
    const footer_y = panel_y + panel_h - footer_h;
    const content_top = @min(footer_y, panel_y + header_h + gap);
    const content = Rect{
        .x = panel_x + pad,
        .y = content_top,
        .w = inner_w - @min(12 * scale, inner_w * 0.05), // scrollbar gutter
        .h = @max(0, footer_y - content_top - gap),
    };
    const actual_btn_h = @min(btn_h, @max(0, (footer_h - gap) / (if (stacked) @as(f32, 2) else 1)));
    const buttons_h = if (stacked) actual_btn_h * 2 + gap else actual_btn_h;
    const btn_y = footer_y + (footer_h - buttons_h) / 2;
    const close_btn = Rect{
        .x = panel_x + panel_w - pad - ok_w,
        .y = if (stacked) btn_y + actual_btn_h + gap else btn_y,
        .w = ok_w,
        .h = actual_btn_h,
    };
    const view_btn = Rect{ .x = panel_x + pad, .y = btn_y, .w = view_w, .h = actual_btn_h };
    const title_close_size = @min(header_h, @round(@max(28, row_h + 6)));
    const title_close_btn = Rect{
        .x = panel_x + panel_w - pad - title_close_size,
        .y = panel_y + @min(18 * scale, @max(0, header_h - title_close_size)),
        .w = title_close_size,
        .h = title_close_size,
    };
    const rows: usize = if (row_h > 0) @intFromFloat(@floor(content.h / row_h)) else 0;
    return .{
        .panel = .{ .x = panel_x, .y = panel_y, .w = panel_w, .h = panel_h },
        .header = .{ .x = panel_x, .y = panel_y, .w = panel_w, .h = header_h },
        .content = content,
        .footer = .{ .x = panel_x, .y = footer_y, .w = panel_w, .h = footer_h },
        .view_btn = view_btn,
        .close_btn = close_btn,
        .title_close_btn = title_close_btn,
        .visible_rows = rows,
    };
}

fn skipBlankLines(text: []const u8, cursor: *usize) void {
    while (cursor.* < text.len) {
        const line = md.nextSourceLine(text, cursor.*);
        if (std.mem.trim(u8, line.line, " \t\r\n").len != 0) break;
        cursor.* = line.next;
    }
}

test "clampScroll clamps both ends" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(-5, 100, 10));
    try std.testing.expectEqual(@as(usize, 90), clampScroll(999, 100, 10));
    try std.testing.expectEqual(@as(usize, 0), clampScroll(7, 5, 10)); // content fits
    try std.testing.expectEqual(@as(usize, 7), clampScroll(7, 100, 10));
}

test "releaseTagUrl strips leading v and builds tag URL" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://github.com/xuzhougeng/wispterm/releases/tag/v1.10.0",
        releaseTagUrl(&buf, "1.10.0"),
    );
    try std.testing.expectEqualStrings(
        "https://github.com/xuzhougeng/wispterm/releases/tag/v1.10.0",
        releaseTagUrl(&buf, "v1.10.0"),
    );
}

test "buttonActionAt resolves clicks" {
    const layout = computeLayout(1200, 800, 20);
    const close_pt_x = layout.close_btn.x + 1;
    const close_pt_y = layout.close_btn.y + 1;
    try std.testing.expectEqual(Action.close, buttonActionAt(layout, close_pt_x, close_pt_y));
    const view_pt_x = layout.view_btn.x + 1;
    const view_pt_y = layout.view_btn.y + 1;
    try std.testing.expectEqual(Action.view_on_github, buttonActionAt(layout, view_pt_x, view_pt_y));
    try std.testing.expectEqual(Action.none, buttonActionAt(layout, layout.panel.x + 1, layout.panel.y + 1));
}

test "computeLayout keeps buttons inside the panel and visible_rows positive" {
    const layout = computeLayout(1200, 800, 20);
    try std.testing.expect(layout.visible_rows >= 1);
    try std.testing.expect(layout.close_btn.x >= layout.panel.x);
    try std.testing.expect(layout.close_btn.x + layout.close_btn.w <= layout.panel.x + layout.panel.w);
    try std.testing.expect(layout.view_btn.x >= layout.panel.x);
}

test "computeLayout exposes header content footer bands and top close button" {
    const layout = computeLayout(1200, 800, 20);
    try std.testing.expect(layout.header.y >= layout.panel.y);
    try std.testing.expect(layout.header.y + layout.header.h <= layout.content.y);
    try std.testing.expect(layout.content.y + layout.content.h <= layout.footer.y);
    try std.testing.expect(layout.footer.y + layout.footer.h <= layout.panel.y + layout.panel.h);
    try std.testing.expect(layout.title_close_btn.x + layout.title_close_btn.w <= layout.panel.x + layout.panel.w);
    try std.testing.expectEqual(Action.close, buttonActionAt(
        layout,
        layout.title_close_btn.x + layout.title_close_btn.w / 2,
        layout.title_close_btn.y + layout.title_close_btn.h / 2,
    ));
}

test "computeLayout places GitHub action on the left side of the footer" {
    const layout = computeLayout(1200, 800, 20);
    const left_pad = layout.view_btn.x - layout.panel.x;
    const right_pad = layout.panel.x + layout.panel.w - layout.close_btn.x - layout.close_btn.w;
    try std.testing.expect(left_pad >= 24);
    try std.testing.expect(left_pad <= 44);
    try std.testing.expect(right_pad >= 24);
    try std.testing.expect(right_pad <= 44);
    try std.testing.expect(layout.view_btn.x + layout.view_btn.w < layout.close_btn.x);
}

test "computeLayoutWithButtons accepts measured wide GitHub label" {
    const layout = computeLayoutWithButtons(1200, 800, 36, .{ .view_w = 292, .close_w = 86 });
    const left_pad = layout.view_btn.x - layout.panel.x;
    try std.testing.expect(left_pad >= 24);
    try std.testing.expect(left_pad <= 44);
    try std.testing.expectEqual(@as(f32, 292), layout.view_btn.w);
    try std.testing.expect(layout.view_btn.x + layout.view_btn.w <= layout.panel.x + layout.panel.w);
    try std.testing.expect(layout.view_btn.x + layout.view_btn.w < layout.close_btn.x);
}

test "bodyNotes preserves the full summary in the scrollable content" {
    const notes =
        \\# WispTerm v1.10.0
        \\
        \\> This release restores true full permission, fixes a setting row,
        \\> and adds a What's New panel.
        \\
        \\## Added
        \\
        \\- **Panel.** Added the panel.
        \\
        \\---
        \\
        \\# WispTerm v1.10.0（中文）
        \\
        \\## 新增
    ;
    const english = englishNotes(notes);
    try std.testing.expect(std.mem.indexOf(u8, english, "中文") == null);
    try std.testing.expect(std.mem.indexOf(u8, english, "## Added") != null);

    const body = bodyNotes(notes);
    try std.testing.expect(std.mem.startsWith(u8, body, "> This release"));
    try std.testing.expect(std.mem.indexOf(u8, body, "## Added") != null);
}

fn testAdvance(cp: u32) f32 {
    return if (cp >= 0x2e80) 2 else 1;
}

test "word wrap keeps words together and counts the rows it draws" {
    var rows: WrappedRows = .{ .text = "Tabs running a terminal agent now show idle", .width = 20, .advance = testAdvance };
    try std.testing.expectEqualStrings("Tabs running a", rows.next().?);
    try std.testing.expectEqualStrings("terminal agent now", rows.next().?);
    try std.testing.expectEqualStrings("show idle", rows.next().?);
    try std.testing.expect(rows.next() == null);
    try std.testing.expectEqual(@as(usize, 3), wrappedRowCount(rows.text, 20, testAdvance));
    try std.testing.expectEqual(@as(usize, 1), wrappedRowCount("", 20, testAdvance));
}

test "long tokens and wide glyphs wrap without losing UTF-8 characters" {
    const text = "ab—cd⌘ef中文";
    for ([_]f32{ 0, 1, 3, 8 }) |width| {
        var rows: WrappedRows = .{ .text = text, .width = width, .advance = testAdvance };
        var joined: [64]u8 = undefined;
        var len: usize = 0;
        while (rows.next()) |row| {
            try std.testing.expect(row.len > 0);
            try std.testing.expect(std.unicode.utf8ValidateSlice(row));
            @memcpy(joined[len..][0..row.len], row);
            len += row.len;
        }
        try std.testing.expectEqualStrings(text, joined[0..len]);
    }
}

test "large fonts and small viewports keep body and buttons in separate bands" {
    for ([_][2]f32{ .{ 2880, 2076 }, .{ 1200, 800 }, .{ 640, 480 }, .{ 420, 340 }, .{ 320, 240 } }) |size| {
        for ([_]f32{ 24, 36, 52, 72 }) |row_h| {
            const layout = computeLayoutWithButtons(size[0], size[1], row_h, .{ .view_w = row_h * 7, .close_w = row_h * 2 });
            try std.testing.expect(layout.panel.x >= 0 and layout.panel.y >= 0);
            try std.testing.expect(layout.panel.x + layout.panel.w <= size[0]);
            try std.testing.expect(layout.panel.y + layout.panel.h <= size[1]);
            try std.testing.expect(layout.header.y + layout.header.h <= layout.content.y);
            try std.testing.expect(layout.content.y + layout.content.h <= layout.footer.y);
            try std.testing.expect(@as(f32, @floatFromInt(layout.visible_rows)) * row_h <= layout.content.h);
            for ([_]Rect{ layout.view_btn, layout.close_btn }) |button| {
                try std.testing.expect(button.x >= layout.panel.x);
                try std.testing.expect(button.x + button.w <= layout.panel.x + layout.panel.w);
                try std.testing.expect(button.y >= layout.footer.y);
                try std.testing.expect(button.y + button.h <= layout.panel.y + layout.panel.h + 0.01);
            }
            try std.testing.expect(layout.view_btn.x + layout.view_btn.w < layout.close_btn.x or
                layout.view_btn.y + layout.view_btn.h < layout.close_btn.y);
        }
    }
}

test "long release summary remains complete and scrollable" {
    const notes = "# WispTerm v1.47.0\n\n> " ++ ("A long release summary with agents and updates. " ** 30) ++ "End of summary.\n\n## Security\nLast body line";
    const body = bodyNotes(notes);
    try std.testing.expect(body.len > 1024);
    try std.testing.expect(std.mem.indexOf(u8, body, "End of summary.") != null);
    var doc = try Document.init(std.testing.allocator, body);
    defer doc.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, doc.blockText(doc.blocks.items[0]), "End of summary."));
    const total = doc.totalRows(38, 36, testAdvance);
    const layout = computeLayout(1200, 800, 52);
    try std.testing.expect(total > layout.visible_rows);
    const last_page = clampScroll(std.math.maxInt(i32), total, layout.visible_rows);
    try std.testing.expectEqual(total, last_page + layout.visible_rows);
}

test "Markdown soft breaks reflow while headings lists and code stay distinct" {
    var doc = try Document.init(std.testing.allocator,
        \\> A release summary
        \\> continues here.
        \\
        \\## Added
        \\- First item
        \\  continues here.
        \\- Second item
        \\```text
        \\first code line
        \\second code line
        \\```
    );
    defer doc.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A release summary continues here.", doc.blockText(doc.blocks.items[0]));
    try std.testing.expectEqual(md.LineStyle.blank, doc.blocks.items[1].style);
    try std.testing.expectEqual(md.LineStyle.heading, doc.blocks.items[2].style);
    try std.testing.expectEqualStrings("- First item continues here.", doc.blockText(doc.blocks.items[3]));
    try std.testing.expectEqualStrings("- Second item", doc.blockText(doc.blocks.items[4]));
    try std.testing.expectEqualStrings("first code line", doc.blockText(doc.blocks.items[6]));
    try std.testing.expectEqualStrings("second code line", doc.blockText(doc.blocks.items[7]));
}
