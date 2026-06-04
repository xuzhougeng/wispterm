//! Pure layout + scroll + hit-test + URL helpers for the "What's New" modal.
//! No GL, no AppWindow — unit-tested in the fast suite. overlays.zig owns the
//! threadlocal modal state and the actual drawing; this module owns the math.
const std = @import("std");
const md = @import("../../markdown_text.zig");

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

pub const MIN_WRAP_COLS: usize = 8;
pub const MAX_HIGHLIGHTS: usize = 4;

pub const Highlights = struct {
    items: [MAX_HIGHLIGHTS][]const u8 = .{""} ** MAX_HIGHLIGHTS,
    len: usize = 0,
};

/// Display rows a single cleaned line of `display_len` bytes occupies at
/// `wrap_cols` columns (always at least 1). Byte-length approximation — adequate
/// for the ASCII-dominant release notes; wide glyphs may wrap a column early.
pub fn lineRows(display_len: usize, wrap_cols: usize) usize {
    if (wrap_cols == 0 or display_len == 0) return 1;
    return (display_len + wrap_cols - 1) / wrap_cols;
}

/// Total wrapped display rows for the whole notes blob at `wrap_cols` columns.
pub fn totalRows(notes: []const u8, wrap_cols: usize) usize {
    var total: usize = 0;
    var in_code = false;
    var it = std.mem.splitScalar(u8, notes, '\n');
    while (it.next()) |raw| {
        var buf: [1024]u8 = undefined;
        const cleaned = md.cleanedLine(&buf, raw, in_code);
        if (cleaned.style == .fence) in_code = !in_code;
        total += lineRows(cleaned.text.len, wrap_cols);
    }
    return total;
}

/// The embedded release notes may include localized sections after a markdown
/// divider. The modal shows the first (English) section in-app.
pub fn englishNotes(notes: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, notes, "\n---") orelse notes.len;
    return std.mem.trimRight(u8, notes[0..end], " \t\r\n");
}

/// Body text for the scrollable area. Drops the release H1 and opening summary
/// quote because the modal header renders those separately.
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

    skipBlankLines(english, &cursor);
    if (cursor < english.len) {
        var quote_cursor = cursor;
        var saw_quote = false;
        while (quote_cursor < english.len) {
            const line = md.nextSourceLine(english, quote_cursor);
            const trimmed = std.mem.trimLeft(u8, line.line, " \t");
            if (trimmed.len == 0) {
                quote_cursor = line.next;
                if (saw_quote) break;
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, ">")) break;
            saw_quote = true;
            quote_cursor = line.next;
        }
        if (saw_quote) cursor = quote_cursor;
    }

    return std.mem.trimLeft(u8, english[cursor..], " \t\r\n");
}

/// Summary text from the opening markdown quote block.
pub fn summaryText(buf: []u8, notes: []const u8) []const u8 {
    const english = englishNotes(notes);
    var cursor: usize = 0;
    var pos: usize = 0;
    var saw_quote = false;

    while (cursor < english.len) {
        const line = md.nextSourceLine(english, cursor);
        cursor = line.next;
        const trimmed = std.mem.trimLeft(u8, line.line, " \t");
        if (trimmed.len == 0) {
            if (saw_quote) break;
            continue;
        }
        if (!std.mem.startsWith(u8, trimmed, ">")) {
            if (saw_quote) break;
            continue;
        }

        saw_quote = true;
        var clean_buf: [1024]u8 = undefined;
        const cleaned = md.cleanInline(&clean_buf, std.mem.trimLeft(u8, trimmed[1..], " \t"));
        if (cleaned.len == 0) continue;
        if (pos > 0 and pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        pos = appendSliceBounded(buf, pos, cleaned);
    }

    return std.mem.trim(u8, buf[0..pos], " \t\r\n");
}

/// Split a release summary into compact highlight rows.
pub fn highlightClauses(buf: []u8, summary_raw: []const u8) Highlights {
    var highlights: Highlights = .{};
    var pos: usize = 0;
    var summary = std.mem.trim(u8, summary_raw, " \t\r\n.");
    if (std.mem.startsWith(u8, summary, "This release ")) {
        summary = summary["This release ".len..];
    } else if (std.mem.startsWith(u8, summary, "This version ")) {
        summary = summary["This version ".len..];
    }

    var parts = std.mem.splitSequence(u8, summary, ", ");
    while (parts.next()) |part_raw| {
        if (highlights.len >= MAX_HIGHLIGHTS) break;
        var part = std.mem.trim(u8, part_raw, " \t\r\n.");
        if (std.mem.startsWith(u8, part, "and ")) part = part["and ".len..];
        if (part.len == 0) continue;

        const start = pos;
        if (pos >= buf.len) break;
        if (std.ascii.isLower(part[0])) {
            buf[pos] = std.ascii.toUpper(part[0]);
        } else {
            buf[pos] = part[0];
        }
        pos += 1;
        pos = appendSliceBounded(buf, pos, part[1..]);
        highlights.items[highlights.len] = std.mem.trim(u8, buf[start..pos], " \t\r\n.");
        highlights.len += 1;
    }

    return highlights;
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
    const panel_w = @round(@min(@max(@as(f32, 320), window_w - 80), @as(f32, 860)));
    const panel_h = @round(@min(@max(@as(f32, 360), window_h - 80), @as(f32, 620)));
    const panel_x = @round((window_w - panel_w) / 2);
    const panel_y = @round((window_h - panel_h) / 2);

    const pad: f32 = 34;
    const header_h = @round(@max(@as(f32, 86), row_h * 2 + 34));
    const footer_h = @round(@max(@as(f32, 58), row_h + 30));
    const content_top = panel_y + header_h + 18;
    const footer_y = panel_y + panel_h - footer_h;
    const content = Rect{
        .x = panel_x + pad,
        .y = content_top,
        .w = panel_w - pad * 2,
        .h = @max(@as(f32, row_h), footer_y - content_top - 18),
    };

    const btn_h: f32 = @round(@max(@as(f32, 34), row_h + 14));
    const ok_w: f32 = 72;
    const view_w: f32 = 156;
    const btn_y = footer_y + @round((footer_h - btn_h) / 2);
    const close_btn = Rect{ .x = panel_x + panel_w - pad - ok_w, .y = btn_y, .w = ok_w, .h = btn_h };
    const view_btn = Rect{ .x = panel_x + pad, .y = btn_y, .w = view_w, .h = btn_h };
    const title_close_size: f32 = @round(@max(@as(f32, 28), row_h + 6));
    const title_close_btn = Rect{
        .x = panel_x + panel_w - pad - title_close_size + 4,
        .y = panel_y + 18,
        .w = title_close_size,
        .h = title_close_size,
    };

    const rows: usize = if (row_h > 0) @intFromFloat(@max(@as(f32, 1), content.h / row_h)) else 1;
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

fn appendSliceBounded(buf: []u8, pos: usize, text: []const u8) usize {
    if (pos >= buf.len) return pos;
    const len = @min(text.len, buf.len - pos);
    @memcpy(buf[pos..][0..len], text[0..len]);
    return pos + len;
}

test "lineRows is at least one and wraps by columns" {
    try std.testing.expectEqual(@as(usize, 1), lineRows(0, 40));
    try std.testing.expectEqual(@as(usize, 1), lineRows(40, 40));
    try std.testing.expectEqual(@as(usize, 2), lineRows(41, 40));
}

test "totalRows counts blank, heading, and wrapped lines" {
    // No trailing newline: splitScalar would otherwise emit a final empty segment.
    const notes = "# Title\n\nshort";
    // "Title" (1) + blank (1) + "short" (1) = 3
    try std.testing.expectEqual(@as(usize, 3), totalRows(notes, 40));
    // A line longer than wrap_cols spans multiple rows.
    try std.testing.expectEqual(@as(usize, 2), totalRows("abcdefghij", 5));
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

test "englishNotes and bodyNotes remove localized trailer and intro chrome" {
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
    try std.testing.expect(std.mem.startsWith(u8, body, "## Added"));
    try std.testing.expect(std.mem.indexOf(u8, body, "This release") == null);
}

test "summaryText and highlightClauses produce compact highlights" {
    const notes =
        \\# WispTerm v1.10.0
        \\
        \\> This release restores true full permission for AI Agent workflows, fixes the
        \\> Default AI settings row interaction, and adds an in-app What's New panel.
    ;
    var summary_buf: [256]u8 = undefined;
    const summary = summaryText(&summary_buf, notes);
    try std.testing.expectEqualStrings(
        "This release restores true full permission for AI Agent workflows, fixes the Default AI settings row interaction, and adds an in-app What's New panel.",
        summary,
    );

    var highlights_buf: [256]u8 = undefined;
    const highlights = highlightClauses(&highlights_buf, summary);
    try std.testing.expectEqual(@as(usize, 3), highlights.len);
    try std.testing.expectEqualStrings("Restores true full permission for AI Agent workflows", highlights.items[0]);
    try std.testing.expectEqualStrings("Fixes the Default AI settings row interaction", highlights.items[1]);
    try std.testing.expectEqualStrings("Adds an in-app What's New panel", highlights.items[2]);
}
