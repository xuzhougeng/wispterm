//! Pure markdown text helpers shared by the AI-chat renderer and model.
//! Owns the canonical "display text" (the cleaned text the user sees) and its
//! single byte-offset space, so selection highlight, click hit-testing, and
//! copy all agree. No rendering, no AppWindow, std-only.
const std = @import("std");

pub const TABLE_MAX_COLS: usize = 32;

pub const TableAlignment = enum { left, center, right };

/// Keep short columns compact and give long cells the remaining wrap width.
pub fn fitTableWidths(widths: []f32, available: f32, minimum: f32) void {
    if (widths.len == 0) return;
    const floor = @min(minimum, available / @as(f32, @floatFromInt(widths.len)));
    var total: f32 = 0;
    for (widths) |*width| {
        width.* = @max(floor, width.*);
        total += width.*;
    }
    if (total <= available) return;
    var low = floor;
    var high = total;
    for (0..32) |_| {
        const cap = (low + high) / 2;
        var used: f32 = 0;
        for (widths) |width| used += @min(width, cap);
        if (used > available) high = cap else low = cap;
    }
    for (widths) |*width| width.* = @min(width.*, low);
}

pub fn tableAlignment(cell: []const u8) TableAlignment {
    const value = std.mem.trim(u8, cell, " \t");
    if (std.mem.endsWith(u8, value, ":")) {
        return if (std.mem.startsWith(u8, value, ":")) .center else .right;
    }
    return .left;
}

/// Small cells stay on the caller's stack; long paths/content are never cut
/// at the old 256-byte boundary. The model and renderer use the same bytes.
pub const CellText = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    pub fn init(scratch: []u8, source: []const u8) CellText {
        if (source.len <= scratch.len) return .{ .text = cleanInline(scratch, source) };
        const owned = std.heap.page_allocator.alloc(u8, source.len) catch return .{ .text = source };
        return .{ .text = cleanInline(owned, source), .owned = owned };
    }

    pub fn deinit(self: CellText) void {
        if (self.owned) |owned| std.heap.page_allocator.free(owned);
    }
};

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
    if (!isTableSeparatorLine(second.line)) return false;
    var header: [TABLE_MAX_COLS][]const u8 = undefined;
    var separator: [TABLE_MAX_COLS][]const u8 = undefined;
    const count = parseTableRowCells(first.line, &header);
    return count > 0 and count == parseTableRowCells(second.line, &separator);
}

pub fn tableBlockEnd(text: []const u8, start: usize) usize {
    const first = nextSourceLine(text, start);
    const second = nextSourceLine(text, first.next);
    var cursor = second.next;
    while (cursor < text.len) {
        const line = nextSourceLine(text, cursor);
        const trimmed = std.mem.trim(u8, line.line, " \t");
        if (trimmed.len == 0 or !looksLikeTableRow(line.line) or isTableSeparatorLine(line.line)) break;
        var cells: [TABLE_MAX_COLS][]const u8 = undefined;
        if (parseTableRowCells(line.line, &cells) == 0) break;
        cursor = line.next;
    }
    return cursor;
}

pub fn parseTableRowCells(line: []const u8, out: *[TABLE_MAX_COLS][]const u8) usize {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return 0;
    if (trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|' and !isEscaped(trimmed, trimmed.len - 1)) trimmed = trimmed[0 .. trimmed.len - 1];

    var count: usize = 0;
    var start: usize = 0;
    for (0..trimmed.len + 1) |i| {
        if (i < trimmed.len and (trimmed[i] != '|' or isEscaped(trimmed, i))) continue;
        // Unsupported oversized tables fall back to text, never lose columns.
        if (count >= TABLE_MAX_COLS) return 0;
        out[count] = std.mem.trim(u8, trimmed[start..i], " \t");
        count += 1;
        start = i + 1;
    }
    return count;
}

fn isEscaped(text: []const u8, index: usize) bool {
    var start = index;
    while (start > 0 and text[start - 1] == '\\') : (start -= 1) {}
    return (index - start) % 2 == 1;
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
        var dashes = trimmed;
        if (dashes[0] == ':') dashes = dashes[1..];
        if (dashes.len > 0 and dashes[dashes.len - 1] == ':') dashes = dashes[0 .. dashes.len - 1];
        if (dashes.len == 0) return false;
        for (dashes) |ch| if (ch != '-') return false;
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
        if (ch == '\\' and i + 1 < text.len and std.ascii.isPrint(text[i + 1]) and !std.ascii.isAlphanumeric(text[i + 1]) and text[i + 1] != ' ') {
            buf[pos] = text[i + 1];
            pos += 1;
            i += 2;
            continue;
        }
        if (ch == '`') {
            var run_end = i + 1;
            while (run_end < text.len and text[run_end] == '`') : (run_end += 1) {}
            if (std.mem.indexOf(u8, text[run_end..], text[i..run_end])) |close| {
                var code_i = run_end;
                while (code_i < run_end + close and pos < buf.len) : (code_i += 1) {
                    // GFM table pipes are escaped even inside code spans.
                    if (text[code_i] == '\\' and code_i + 1 < run_end + close and text[code_i + 1] == '|') code_i += 1;
                    buf[pos] = text[code_i];
                    pos += 1;
                }
                i = run_end + close + (run_end - i);
                continue;
            }
            pos = appendSlice(buf, pos, text[i..run_end]);
            i = run_end;
            continue;
        }
        if (ch == '<') {
            if (inlineHtmlTagEnd(text, i)) |end| {
                i = end;
                continue;
            }
            // A bare less-than ("if x < 10", "a <= b") is text, not markup.
            buf[pos] = ch;
            pos += 1;
            i += 1;
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
        if (ch == '_' and isIntrawordUnderscore(text, i)) {
            buf[pos] = ch;
            pos += 1;
            i += 1;
            continue;
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

/// End index (one past `>`) of an inline HTML tag, comment or autolink that
/// starts at `text[start] == '<'`, or null when the `<` is ordinary text. A
/// tag must open with a letter, `/` or `!` and close with `>` on the same
/// line; anything else — a comparison, an arrow, an unclosed `<` — is kept.
pub fn inlineHtmlTagEnd(text: []const u8, start: usize) ?usize {
    if (start + 1 >= text.len) return null;
    const next = text[start + 1];
    if (!std.ascii.isAlphabetic(next) and next != '/' and next != '!') return null;
    const close = std.mem.indexOfScalarPos(u8, text, start + 1, '>') orelse return null;
    return close + 1;
}

fn isIntrawordUnderscore(text: []const u8, index: usize) bool {
    return index > 0 and index + 1 < text.len and isWordByte(text[index - 1]) and isWordByte(text[index + 1]);
}

fn isWordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
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

/// Extract the cleaned display text + style for one source line. `buf` holds
/// the cleaned bytes; the returned `text` is a slice into `buf`. The renderer's
/// prepareMarkdownLine duplicates these text branches (it also adds colors and
/// line heights); both must be updated together when new constructs are added.
pub fn cleanedLine(buf: []u8, raw_line: []const u8, in_code: bool) CleanedLine {
    const trimmed = std.mem.trimLeft(u8, raw_line, " \t");
    if (isFence(trimmed)) return .{ .style = .fence, .fence_label = fenceLanguage(trimmed) };
    if (in_code) return .{ .style = .code, .text = raw_line };
    if (trimmed.len == 0) return .{ .style = .blank };
    if (isHorizontalRule(trimmed)) return .{ .style = .rule };
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
            const cell = CellText.init(&clean_buf, cells[i]);
            defer cell.deinit();
            try out.appendSlice(allocator, cell.text);
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

/// Display offset (within a table block) of the row at `row_index`, counting
/// only non-separator rows. Returns the total block display length if
/// `row_index` >= the number of rows (i.e. an "end of block" offset).
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
        const cell = CellText.init(&clean_buf, cells[i]);
        defer cell.deinit();
        total += cell.text.len;
    }
    return total;
}

/// Build the message's cleaned display text — the text the transcript renders,
/// in one contiguous buffer, used as the single offset space for selection.
/// Every source line contributes its cleaned text + '\n'; structural lines
/// (fences, rules, blanks) contribute a bare '\n' each so offsets stay
/// contiguous. Selection offsets index into this buffer.
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

pub const Range = struct { start: usize, end: usize };

/// Byte range of a fenced code block's *content* — the lines between the
/// opening fence at `fence_start` and the matching closing fence, excluding
/// both fence lines. An unterminated fence (still streaming) runs to EOF.
/// Powers the renderer's per-code-block copy button (copies just the code).
pub fn codeBlockContentRange(text: []const u8, fence_start: usize) Range {
    const opening = nextSourceLine(text, fence_start);
    const start = opening.next;
    var cursor = start;
    while (cursor < text.len) {
        const info = nextSourceLine(text, cursor);
        if (isFence(std.mem.trimLeft(u8, info.line, " \t"))) return .{ .start = start, .end = cursor };
        cursor = info.next;
    }
    return .{ .start = start, .end = text.len };
}

const testing = std.testing;

test "codeBlockContentRange extracts code between fences" {
    const text = "```rust\nfn main() {}\n```\n";
    const r = codeBlockContentRange(text, 0);
    try testing.expectEqualStrings("fn main() {}\n", text[r.start..r.end]);
}

test "codeBlockContentRange unterminated fence runs to end" {
    const text = "```\nline1\nline2";
    const r = codeBlockContentRange(text, 0);
    try testing.expectEqualStrings("line1\nline2", text[r.start..r.end]);
}

test "codeBlockContentRange skips language label and finds nested closing" {
    const text = "prefix\n```py\na\nb\nc\n```\nafter";
    const fence = std.mem.indexOf(u8, text, "```").?;
    const r = codeBlockContentRange(text, fence);
    try testing.expectEqualStrings("a\nb\nc\n", text[r.start..r.end]);
}

test "allocDisplayText strips inline emphasis and code spans" {
    const out = try allocDisplayText(testing.allocator, "**生成的完整 `Markdown`**");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("生成的完整 Markdown\n", out);
}

test "allocDisplayText preserves underscores inside identifiers" {
    const out = try allocDisplayText(testing.allocator, "`delegation_runtime.rs` and ssh_hosts.rs");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("delegation_runtime.rs and ssh_hosts.rs\n", out);
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

test "GFM tables accept omitted outer pipes and escaped code pipes" {
    const text = "名称 | 值\n:--- | ---:\n中文😀 | `a\\|b_*<c>`\n";
    try testing.expect(isMarkdownTableStart(text, 0));
    const out = try allocDisplayText(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("名称 | 值\n中文😀 | a|b_*<c>\n", out);
    try testing.expectEqual(out.len, tableBlockDisplayLen(text, 0, text.len));
    try testing.expectEqual(TableAlignment.center, tableAlignment(":---:"));
    try testing.expectEqual(TableAlignment.right, tableAlignment("---:"));
    try testing.expectEqual(TableAlignment.left, tableAlignment(":---"));
}

test "table recognition rejects mismatched and invalid delimiters" {
    try testing.expect(!isMarkdownTableStart("a | b\n--- | --- | ---\n", 0));
    try testing.expect(!isMarkdownTableStart("a | b\n--- | :-:-\n", 0));
    try testing.expect(!isTableSeparatorLine("| ::--- | --- |"));
    try testing.expect(!isMarkdownTableStart("a | b\n--- |", 0));
    var cells: [TABLE_MAX_COLS][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), parseTableRowCells("| a | b\\|", &cells));
    try testing.expectEqualStrings("b\\|", cells[1]);
}

test "long UTF-8 table cells are fully copied and offsets agree" {
    const content = "长路径😀/" ** 100;
    const text = "| path |\n| --- |\n| `" ++ content ++ "` |\n";
    const out = try allocDisplayText(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("path\n" ++ content ++ "\n", out);
    try testing.expectEqual(out.len, tableBlockDisplayLen(text, 0, text.len));
    try testing.expectEqual(@as(usize, 5), tableRowDisplayOffsetWithin(text, 0, text.len, 1));
}

test "column allocation fits narrow panels and preserves compact columns" {
    var widths = [_]f32{ 32, 900, 80 };
    fitTableWidths(&widths, 300, 56);
    try testing.expectApproxEqAbs(@as(f32, 56), widths[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80), widths[2], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 300), widths[0] + widths[1] + widths[2], 0.01);
    fitTableWidths(&widths, 30, 56);
    for (widths) |width| try testing.expectApproxEqAbs(@as(f32, 10), width, 0.01);
}

test "fenced code preserves indentation blank lines and rule-looking source" {
    const out = try allocDisplayText(testing.allocator, "```\n    x = a * b\n\n---\n```\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\n    x = a * b\n\n---\n\n", out);
}

test "cleanInline keeps a bare less-than and still strips inline HTML" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("if x < 10 then y", cleanInline(&buf, "if x < 10 then y"));
    try testing.expectEqualStrings("a <= b and c -> d", cleanInline(&buf, "a <= b and c -> d"));
    try testing.expectEqualStrings("x < y > z", cleanInline(&buf, "x < y > z"));
    try testing.expectEqualStrings("line break here", cleanInline(&buf, "line <br>break</br> here"));
    try testing.expectEqualStrings("see  now", cleanInline(&buf, "see <!-- note --> now"));
    try testing.expectEqualStrings("tail <", cleanInline(&buf, "tail <"));
}
