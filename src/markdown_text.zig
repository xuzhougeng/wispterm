//! Pure markdown text helpers shared by the AI-chat renderer and model.
//! Owns the canonical "display text" (the cleaned text the user sees) and its
//! single byte-offset space, so selection highlight, click hit-testing, and
//! copy all agree. No rendering, no AppWindow, std-only.
const std = @import("std");

pub const TABLE_MAX_COLS: usize = 8;

pub const SourceLine = struct {
    line: []const u8,
    next: usize,
};

pub const Heading = struct {
    level: usize,
    body: []const u8,
};

pub const List = struct {
    marker: []const u8,
    body: []const u8,
};

pub const Link = struct {
    label: []const u8,
    end: usize,
};

pub fn nextSourceLine(text: []const u8, start: usize) SourceLine {
    if (start >= text.len) return .{ .line = "", .next = text.len };
    const line_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    const raw = std.mem.trimRight(u8, text[start..line_end], "\r");
    return .{
        .line = raw,
        .next = if (line_end < text.len) line_end + 1 else text.len,
    };
}

pub fn isMarkdownTableStart(text: []const u8, start: usize) bool {
    const first = nextSourceLine(text, start);
    if (!looksLikeTableRow(first.line)) return false;
    if (first.next >= text.len) return false;
    const second = nextSourceLine(text, first.next);
    return isTableSeparatorLine(second.line);
}

pub fn tableBlockEnd(text: []const u8, start: usize) usize {
    const first = nextSourceLine(text, start);
    const second = nextSourceLine(text, first.next);
    var cursor = second.next;
    while (cursor < text.len) {
        const line = nextSourceLine(text, cursor);
        const trimmed = std.mem.trim(u8, line.line, " \t");
        if (trimmed.len == 0 or !looksLikeTableRow(line.line) or isTableSeparatorLine(line.line)) break;
        cursor = line.next;
    }
    return cursor;
}

pub fn parseTableRowCells(line: []const u8, out: *[TABLE_MAX_COLS][]const u8) usize {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return 0;
    if (trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];

    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, trimmed, '|');
    while (parts.next()) |part| {
        if (count >= TABLE_MAX_COLS) break;
        out[count] = std.mem.trim(u8, part, " \t");
        count += 1;
    }
    return count;
}

pub fn looksLikeTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len > 0 and std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

pub fn isTableSeparatorLine(line: []const u8) bool {
    if (!looksLikeTableRow(line)) return false;
    var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
    const count = parseTableRowCells(line, &cells);
    if (count == 0) return false;

    for (cells[0..count]) |cell| {
        const trimmed = std.mem.trim(u8, cell, " \t");
        if (trimmed.len == 0) return false;
        var dash_count: usize = 0;
        for (trimmed) |ch| {
            if (ch == '-') {
                dash_count += 1;
                continue;
            }
            if (ch == ':') continue;
            return false;
        }
        if (dash_count == 0) return false;
    }
    return true;
}

pub fn headingBody(line: []const u8) ?Heading {
    var level: usize = 0;
    while (level < line.len and line[level] == '#' and level < 6) : (level += 1) {}
    if (level == 0 or level >= line.len or line[level] != ' ') return null;
    return .{ .level = level, .body = std.mem.trimLeft(u8, line[level + 1 ..], " \t") };
}

pub fn htmlHeadingBody(line: []const u8) ?Heading {
    if (line.len < 4 or line[0] != '<' or (line[1] != 'h' and line[1] != 'H')) return null;
    const level_ch = line[2];
    if (level_ch < '1' or level_ch > '6') return null;
    const open_end = std.mem.indexOfScalar(u8, line, '>') orelse return null;
    const close_start = std.mem.indexOf(u8, line[open_end + 1 ..], "</") orelse line.len - (open_end + 1);
    return .{
        .level = @intCast(level_ch - '0'),
        .body = line[open_end + 1 .. open_end + 1 + close_start],
    };
}

pub fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~");
}

pub fn fenceLanguage(line: []const u8) []const u8 {
    if (!isFence(line) or line.len <= 3) return "";
    return std.mem.trim(u8, line[3..], " \t");
}

pub fn isHorizontalRule(line: []const u8) bool {
    var marker: u8 = 0;
    var count: usize = 0;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (ch != '-' and ch != '*' and ch != '_') return false;
        if (marker == 0) marker = ch;
        if (ch != marker) return false;
        count += 1;
    }
    return count >= 3;
}

pub fn listBody(line: []const u8) ?List {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and isSpace(line[1])) {
        const body = std.mem.trimLeft(u8, line[2..], " \t");
        if (std.mem.startsWith(u8, body, "[ ] ")) return .{ .marker = "[ ] ", .body = body[4..] };
        if (body.len >= 4 and body[0] == '[' and (body[1] == 'x' or body[1] == 'X') and body[2] == ']' and isSpace(body[3])) {
            return .{ .marker = "[x] ", .body = body[4..] };
        }
        return .{ .marker = "- ", .body = body };
    }

    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and isSpace(line[i + 1])) {
        return .{
            .marker = line[0 .. i + 2],
            .body = std.mem.trimLeft(u8, line[i + 2 ..], " \t"),
        };
    }
    return null;
}

pub fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

pub fn cleanPlain(buf: []u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    for (text) |ch| {
        if (pos >= buf.len) break;
        if (ch == '\r' or ch == '\n' or ch == 0x1b) continue;
        buf[pos] = ch;
        pos += 1;
    }
    return std.mem.trim(u8, buf[0..pos], " \t");
}

pub fn cleanInline(buf: []u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < text.len and pos < buf.len) {
        const ch = text[i];
        if (ch == '<') {
            while (i < text.len and text[i] != '>') : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }
        if (ch == '[') {
            if (parseMarkdownLink(text, i)) |link| {
                pos = appendSlice(buf, pos, link.label);
                i = link.end;
                continue;
            }
        }
        if (ch == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (parseMarkdownLink(text, i + 1)) |link| {
                pos = appendSlice(buf, pos, link.label);
                i = link.end;
                continue;
            }
        }
        if (ch == '*' or ch == '_' or ch == '`' or ch == '\r' or ch == '\n' or ch == 0x1b) {
            i += 1;
            continue;
        }
        buf[pos] = ch;
        pos += 1;
        i += 1;
    }
    return std.mem.trim(u8, buf[0..pos], " \t");
}

pub fn parseMarkdownLink(text: []const u8, bracket: usize) ?Link {
    const close_rel = std.mem.indexOfScalar(u8, text[bracket + 1 ..], ']') orelse return null;
    const close = bracket + 1 + close_rel;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const url_start = close + 2;
    const url_rel = std.mem.indexOfScalar(u8, text[url_start..], ')') orelse return null;
    return .{
        .label = text[bracket + 1 .. close],
        .end = url_start + url_rel + 1,
    };
}

pub fn appendSlice(buf: []u8, pos: usize, text: []const u8) usize {
    const len = @min(text.len, buf.len - pos);
    @memcpy(buf[pos..][0..len], text[0..len]);
    return pos + len;
}

pub const LineStyle = enum { blank, fence, rule, normal, heading, code, quote, list };

pub const CleanedLine = struct {
    style: LineStyle,
    text: []const u8 = "",
    heading_level: u8 = 0,
    fence_label: []const u8 = "",
};

/// Cleaned display text + style for one source line. `buf` holds the cleaned
/// bytes; the returned `text` is a slice into `buf`. Mirrors the renderer's
/// prepareMarkdownLine text logic exactly.
pub fn cleanedLine(buf: *[1024]u8, raw_line: []const u8, in_code: bool) CleanedLine {
    const trimmed = std.mem.trimLeft(u8, raw_line, " \t");
    if (trimmed.len == 0) return .{ .style = .blank };
    if (isFence(trimmed)) return .{ .style = .fence, .fence_label = fenceLanguage(trimmed) };
    if (isHorizontalRule(trimmed)) return .{ .style = .rule };
    if (in_code) return .{ .style = .code, .text = cleanPlain(buf, raw_line) };
    if (headingBody(trimmed)) |heading| {
        return .{ .style = .heading, .text = cleanInline(buf, heading.body), .heading_level = @intCast(heading.level) };
    }
    if (htmlHeadingBody(trimmed)) |heading| {
        return .{ .style = .heading, .text = cleanInline(buf, heading.body), .heading_level = @intCast(heading.level) };
    }
    if (std.mem.startsWith(u8, trimmed, ">")) {
        return .{ .style = .quote, .text = cleanInline(buf, std.mem.trimLeft(u8, trimmed[1..], " \t")) };
    }
    if (listBody(trimmed)) |list| {
        const body = cleanInline(buf, list.body);
        if (body.len + list.marker.len <= buf.len) {
            std.mem.copyBackwards(u8, buf[list.marker.len .. list.marker.len + body.len], body);
            @memcpy(buf[0..list.marker.len], list.marker);
            return .{ .style = .list, .text = buf[0 .. list.marker.len + body.len] };
        }
        return .{ .style = .list, .text = body };
    }
    return .{ .style = .normal, .text = cleanInline(buf, trimmed) };
}

/// Append a table block's display text: each non-separator row's cleaned cell
/// text joined by " | ", followed by '\n'. Returns nothing; see tableBlockDisplayLen.
pub fn appendTableBlockDisplay(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
    start: usize,
    end: usize,
) !void {
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;
        var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
        const count = parseTableRowCells(info.line, &cells);
        for (0..count) |i| {
            if (i > 0) try out.appendSlice(allocator, " | ");
            var clean_buf: [256]u8 = undefined;
            try out.appendSlice(allocator, cleanInline(&clean_buf, cells[i]));
        }
        try out.append(allocator, '\n');
    }
}

/// Byte length appendTableBlockDisplay would append. Used to advance the
/// display cursor in the renderer without building the text.
pub fn tableBlockDisplayLen(text: []const u8, start: usize, end: usize) usize {
    var total: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;
        total += tableRowDisplayLen(info.line) + 1; // +1 for '\n'
    }
    return total;
}

/// Display offset (within a table block) of the row at `row_index` (counting
/// only non-separator rows). Used by the hit-test to map a table click.
pub fn tableRowDisplayOffsetWithin(text: []const u8, start: usize, end: usize, row_index: usize) usize {
    var offset: usize = 0;
    var row: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;
        if (row == row_index) return offset;
        offset += tableRowDisplayLen(info.line) + 1;
        row += 1;
    }
    return offset;
}

fn tableRowDisplayLen(line: []const u8) usize {
    var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
    const count = parseTableRowCells(line, &cells);
    var total: usize = 0;
    for (0..count) |i| {
        if (i > 0) total += 3; // " | "
        var clean_buf: [256]u8 = undefined;
        total += cleanInline(&clean_buf, cells[i]).len;
    }
    return total;
}

/// Build the message's cleaned display text — the exact text the transcript
/// renders, in one contiguous buffer. Selection offsets index into this.
pub fn allocDisplayText(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) return out.toOwnedSlice(allocator);

    var cursor: usize = 0;
    var in_code = false;
    var buf: [1024]u8 = undefined;
    while (cursor < content.len) {
        if (!in_code and isMarkdownTableStart(content, cursor)) {
            const end = tableBlockEnd(content, cursor);
            try appendTableBlockDisplay(allocator, &out, content, cursor, end);
            cursor = end;
            continue;
        }
        const info = nextSourceLine(content, cursor);
        cursor = info.next;
        const cl = cleanedLine(&buf, info.line, in_code);
        if (cl.style == .fence) in_code = !in_code;
        try out.appendSlice(allocator, cl.text);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "allocDisplayText strips inline emphasis and code spans" {
    const out = try allocDisplayText(testing.allocator, "**生成的完整 `Markdown`**");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("生成的完整 Markdown\n", out);
}

test "allocDisplayText collapses links to label" {
    const out = try allocDisplayText(testing.allocator, "see [docs](https://x.y) now");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("see docs now\n", out);
}

test "allocDisplayText keeps heading and list text without markers" {
    const out = try allocDisplayText(testing.allocator, "# Title\n- item one\n- item two");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Title\n- item one\n- item two\n", out);
}

test "allocDisplayText plain text is unchanged except trailing newline" {
    const out = try allocDisplayText(testing.allocator, "alpha beta gamma");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("alpha beta gamma\n", out);
}
