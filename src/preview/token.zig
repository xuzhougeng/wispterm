//! Token helpers for Ctrl-click URL and file preview extraction.

const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const GridCell = struct {
    row: usize,
    col: usize,
};

const Segment = struct {
    row: usize,
    start_col: usize,
    end_col: usize,
};

pub const GridToken = struct {
    text: []u8,
    start: GridCell,
    end: GridCell,

    pub fn deinit(self: GridToken, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub fn isDelimiter(cp: u21) bool {
    if (cp == 0 or cp <= 0x20) return true;
    return switch (cp) {
        '"', '\'', '`', '<', '>', '(', ')', '[', ']', '{', '}', '|', '\t', '\r', '\n' => true,
        0xFF08, 0xFF09 => true, // fullwidth parentheses
        else => false,
    };
}

fn appendInitialSegments(
    allocator: std.mem.Allocator,
    segments: *std.ArrayListUnmanaged(Segment),
    grid: anytype,
    start: GridCell,
    end: GridCell,
) !void {
    var row = start.row;
    while (true) : (row += 1) {
        const cols = grid.colCount(row);
        if (cols > 0) {
            try segments.append(allocator, .{
                .row = row,
                .start_col = if (row == start.row) start.col else 0,
                .end_col = if (row == end.row) end.col else cols - 1,
            });
        }
        if (row == end.row) break;
    }
}

pub fn trim(token: []const u8) []const u8 {
    const span = trimSpan(token);
    return token[span.start..span.end];
}

pub fn trimSpan(token: []const u8) Span {
    var start: usize = 0;
    var end: usize = token.len;

    while (start < end) {
        const decoded = codepointAt(token, start);
        if (!isLeadingTrimCodepoint(decoded.cp)) break;
        start += decoded.len;
    }

    while (end > start) {
        const prev = previousCodepointStart(token, start, end) orelse break;
        const decoded = codepointAt(token, prev);
        if (!isTrailingTrimCodepoint(decoded.cp)) break;
        end = prev;
    }

    return .{ .start = start, .end = end };
}

/// Extract a delimiter-bounded token from a terminal-like grid. The `grid`
/// argument is any type that provides:
///
/// - rowCount() usize
/// - colCount(row) usize
/// - codepoint(row, col) u21
/// - wrapsNext(row) bool
/// - continuesFromPrev(row) bool
///
/// Soft-wrapped rows are joined only when both adjacent row flags agree:
/// previous row `wrapsNext` and next row `continuesFromPrev`.
pub fn extractGridTokenAtCell(
    allocator: std.mem.Allocator,
    grid: anytype,
    cell: GridCell,
) ?GridToken {
    const rows = grid.rowCount();
    if (rows == 0 or cell.row >= rows) return null;

    const clicked_cols = grid.colCount(cell.row);
    if (clicked_cols == 0) return null;
    const click_col = @min(cell.col, clicked_cols - 1);
    if (isDelimiter(grid.codepoint(cell.row, click_col))) return null;

    var start = GridCell{ .row = cell.row, .col = click_col };
    while (true) {
        if (start.col > 0) {
            const prev_col = start.col - 1;
            if (isDelimiter(grid.codepoint(start.row, prev_col))) break;
            start.col = prev_col;
            continue;
        }

        if (start.row == 0) break;
        const prev_row = start.row - 1;
        if (!grid.continuesFromPrev(start.row) or !grid.wrapsNext(prev_row)) break;

        const prev_cols = grid.colCount(prev_row);
        if (prev_cols == 0) break;
        const prev_col = prev_cols - 1;
        if (isDelimiter(grid.codepoint(prev_row, prev_col))) break;

        start = .{ .row = prev_row, .col = prev_col };
    }

    var end = GridCell{ .row = cell.row, .col = click_col };
    while (true) {
        const cols = grid.colCount(end.row);
        if (end.col + 1 < cols) {
            const next_col = end.col + 1;
            if (isDelimiter(grid.codepoint(end.row, next_col))) break;
            end.col = next_col;
            continue;
        }

        const next_row = end.row + 1;
        if (next_row >= rows) break;
        if (!grid.wrapsNext(end.row) or !grid.continuesFromPrev(next_row)) break;

        const next_cols = grid.colCount(next_row);
        if (next_cols == 0) break;
        if (isDelimiter(grid.codepoint(next_row, 0))) break;

        end = .{ .row = next_row, .col = 0 };
    }

    var segments: std.ArrayListUnmanaged(Segment) = .empty;
    defer segments.deinit(allocator);
    // Only the genuine soft-wrap range (start..end, joined above via the wrap
    // flags) is part of the path. A hard newline is a real boundary, so we do
    // NOT stitch a '/'-terminated line to the next line: that wrongly merged
    // separate listing entries (e.g. git status `.claude/` + `docs/...`).
    appendInitialSegments(allocator, &segments, grid, start, end) catch return null;

    var token: std.ArrayListUnmanaged(u8) = .empty;
    defer token.deinit(allocator);
    var positions: std.ArrayListUnmanaged(GridCell) = .empty;
    defer positions.deinit(allocator);

    for (segments.items) |segment| {
        var col = segment.start_col;
        while (col <= segment.end_col) : (col += 1) {
            const cp = grid.codepoint(segment.row, col);
            if (isDelimiter(cp)) return null;

            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return null;
            token.appendSlice(allocator, buf[0..len]) catch return null;
            positions.append(allocator, .{ .row = segment.row, .col = col }) catch return null;
        }
    }

    const span = trimSpan(token.items);
    if (span.start >= span.end) return null;

    const leading_cells = utf8CodepointCount(token.items[0..span.start]);
    const kept_cells = utf8CodepointCount(token.items[span.start..span.end]);
    if (kept_cells == 0 or leading_cells + kept_cells > positions.items.len) return null;

    const text = allocator.dupe(u8, token.items[span.start..span.end]) catch return null;
    return .{
        .text = text,
        .start = positions.items[leading_cells],
        .end = positions.items[leading_cells + kept_cells - 1],
    };
}

const Decoded = struct {
    cp: u21,
    len: usize,
};

fn codepointAt(text: []const u8, index: usize) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    if (index + len > text.len) return .{ .cp = text[index], .len = 1 };
    const cp = std.unicode.utf8Decode(text[index .. index + len]) catch text[index];
    return .{ .cp = cp, .len = len };
}

fn previousCodepointStart(text: []const u8, start: usize, end: usize) ?usize {
    var cursor = start;
    var previous: ?usize = null;
    while (cursor < end) {
        previous = cursor;
        cursor += codepointAt(text, cursor).len;
    }
    return if (cursor == end) previous else null;
}

fn utf8CodepointCount(text: []const u8) usize {
    const view = std.unicode.Utf8View.init(text) catch return text.len;
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint() != null) count += 1;
    return count;
}

fn isLeadingTrimCodepoint(cp: u21) bool {
    return switch (cp) {
        '@',
        ':', // separator left in front of a path, e.g. "文档在:docs/x.md"
        '\'',
        '"',
        '`',
        0xFF1A, // fullwidth colon

        0x2018, // left single quotation mark
        0x201C, // left double quotation mark
        0x300C, // left corner bracket
        0x300E, // left white corner bracket
        0xFF08, // fullwidth left parenthesis
        0xFF02, // fullwidth quotation mark
        0xFF07, // fullwidth apostrophe
        => true,
        else => false,
    };
}

fn isTrailingTrimCodepoint(cp: u21) bool {
    return switch (cp) {
        '.',
        ',',
        ';',
        ':',
        '!',
        '?',
        ')',
        ']',
        '}',
        '(',
        '"',
        '\'',
        '`',
        0x00BB, // right-pointing double angle quotation mark
        0x2019, // right single quotation mark
        0x201D, // right double quotation mark
        0x3001, // ideographic comma
        0x3002, // ideographic full stop
        0x300D, // right corner bracket
        0x300F, // right white corner bracket
        0x3011, // right black lenticular bracket
        0x3015, // right tortoise shell bracket
        0xFF01, // fullwidth exclamation mark
        0xFF08, // fullwidth left parenthesis
        0xFF09, // fullwidth right parenthesis
        0xFF0C, // fullwidth comma
        0xFF0E, // fullwidth full stop
        0xFF1A, // fullwidth colon
        0xFF1B, // fullwidth semicolon
        0xFF1F, // fullwidth question mark
        0xFF3D, // fullwidth right square bracket
        0xFF5D, // fullwidth right curly bracket
        => true,
        else => false,
    };
}

test "trim keeps preview path and drops ASCII sentence punctuation" {
    try std.testing.expectEqualStrings("docs/readme.md", trim("`docs/readme.md`."));
}

test "trim drops leading mention marker before markdown path" {
    try std.testing.expectEqualStrings(
        "docs/superpowers/plans/2026-06-04-copilot-tiling-panel.md",
        trim("@docs/superpowers/plans/2026-06-04-copilot-tiling-panel.md"),
    );
}

test "trim drops leading colon left by a sentence separator" {
    // "文档在:docs/foo.md" — the wide CJK char before the colon ends the token
    // at the colon, so the extracted token starts with ':'. A path never begins
    // with a colon, so it must be trimmed.
    try std.testing.expectEqualStrings("docs/readme.md", trim(":docs/readme.md"));
    // Fullwidth colon (U+FF1A), common in Chinese text.
    try std.testing.expectEqualStrings("docs/readme.md", trim("\xEF\xBC\x9Adocs/readme.md"));
}

test "trim keeps an interior colon (windows drive / host:path)" {
    try std.testing.expectEqualStrings("C:/Users/me/notes.md", trim("C:/Users/me/notes.md"));
}

test "trim drops Chinese sentence punctuation after markdown path" {
    const token = "docs/superpowers/specs/2026-05-12-github-pages-docs-design.md\xE3\x80\x82";
    try std.testing.expectEqualStrings(
        "docs/superpowers/specs/2026-05-12-github-pages-docs-design.md",
        trim(token),
    );
}

test "fullwidth parentheses bound preview path tokens" {
    try std.testing.expect(isDelimiter(0xFF08)); // fullwidth left parenthesis
    try std.testing.expect(isDelimiter(0xFF09)); // fullwidth right parenthesis
}

test "trim drops paired fullwidth parentheses after markdown path" {
    try std.testing.expectEqualStrings("./TODO.md", trim("./TODO.md\xEF\xBC\x88\xEF\xBC\x89"));
}

test "trim preserves internal Unicode punctuation" {
    const token = "docs/\xE8\xAE\xBE\xE8\xAE\xA1\xE3\x80\x82notes.md\xEF\xBC\x8C";
    try std.testing.expectEqualStrings("docs/\xE8\xAE\xBE\xE8\xAE\xA1\xE3\x80\x82notes.md", trim(token));
}

test "extractGridTokenAtCell joins soft-wrapped path rows" {
    const TestGrid = struct {
        const Row = struct {
            text: []const u8,
            wraps_next: bool = false,
            continues_from_prev: bool = false,
        };

        rows: []const Row,

        fn rowCount(self: @This()) usize {
            return self.rows.len;
        }

        fn colCount(self: @This(), row: usize) usize {
            return self.rows[row].text.len;
        }

        fn codepoint(self: @This(), row: usize, col: usize) u21 {
            return self.rows[row].text[col];
        }

        fn wrapsNext(self: @This(), row: usize) bool {
            return self.rows[row].wraps_next;
        }

        fn continuesFromPrev(self: @This(), row: usize) bool {
            return self.rows[row].continues_from_prev;
        }
    };

    const rows = [_]TestGrid.Row{
        .{
            .text = "Spec at docs/superpowers/specs/2026-06-05-openssh-config-import-",
            .wraps_next = true,
        },
        .{
            .text = "design.md.",
            .continues_from_prev = true,
        },
    };

    const token = extractGridTokenAtCell(std.testing.allocator, TestGrid{ .rows = &rows }, .{
        .row = 1,
        .col = 0,
    }) orelse return error.ExpectedToken;
    defer token.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "docs/superpowers/specs/2026-06-05-openssh-config-import-design.md",
        token.text,
    );
    try std.testing.expectEqual(GridCell{ .row = 0, .col = 8 }, token.start);
    try std.testing.expectEqual(GridCell{ .row = 1, .col = 8 }, token.end);
}

const HardBreakGrid = struct {
    rows: []const []const u8,
    cols: usize,

    fn rowCount(self: @This()) usize {
        return self.rows.len;
    }

    fn colCount(self: @This(), row: usize) usize {
        _ = row;
        return self.cols;
    }

    fn codepoint(self: @This(), row: usize, col: usize) u21 {
        const text = self.rows[row];
        return if (col < text.len) text[col] else 0;
    }

    fn wrapsNext(self: @This(), row: usize) bool {
        _ = self;
        _ = row;
        return false;
    }

    fn continuesFromPrev(self: @This(), row: usize) bool {
        _ = self;
        _ = row;
        return false;
    }
};

test "extractGridTokenAtCell does NOT join across a hard line break" {
    // A directory entry ending in '/' followed by a separate file entry on the
    // next HARD line (no soft-wrap flags) must NOT be concatenated. This is the
    // git-status pattern: `.claude/` and `docs/...` are two distinct entries, not
    // one wrapped path. Joining produced bogus paths like `.claude/docs/...`.
    const rows = [_][]const u8{
        ".claude/",
        "docs/superpowers/specs/2026-06-08-copilot-memory-system-design.md",
    };
    const grid = HardBreakGrid{ .rows = &rows, .cols = 80 };

    const from_dir = extractGridTokenAtCell(std.testing.allocator, grid, .{
        .row = 0,
        .col = 0,
    }) orelse return error.ExpectedToken;
    defer from_dir.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(".claude/", from_dir.text);

    const from_file = extractGridTokenAtCell(std.testing.allocator, grid, .{
        .row = 1,
        .col = 0,
    }) orelse return error.ExpectedToken;
    defer from_file.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "docs/superpowers/specs/2026-06-08-copilot-memory-system-design.md",
        from_file.text,
    );
}

test "extractGridTokenAtCell does NOT join a bare filename across a hard break" {
    // Even when the continuation is a bare filename (no interior separator), a
    // hard newline is a real boundary between two listing entries.
    const rows = [_][]const u8{
        "/home/xzg/bioinformatics-skills/seq-align/",
        "SKILL.md",
    };
    const grid = HardBreakGrid{ .rows = &rows, .cols = 80 };

    const from_dir = extractGridTokenAtCell(std.testing.allocator, grid, .{
        .row = 0,
        .col = 0,
    }) orelse return error.ExpectedToken;
    defer from_dir.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/home/xzg/bioinformatics-skills/seq-align/", from_dir.text);

    const from_file = extractGridTokenAtCell(std.testing.allocator, grid, .{
        .row = 1,
        .col = 0,
    }) orelse return error.ExpectedToken;
    defer from_file.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("SKILL.md", from_file.text);
}

test "extractGridTokenAtCell drops a leading colon separator before a path" {
    // "see :docs/x.md" — the space before ':' bounds the token at the colon, so
    // the raw token is ":docs/x.md". The colon must be trimmed and the reported
    // start must point at 'd', not ':'.
    const rows = [_][]const u8{"see :docs/x.md"};
    const grid = HardBreakGrid{ .rows = &rows, .cols = 14 };

    const token = extractGridTokenAtCell(std.testing.allocator, grid, .{
        .row = 0,
        .col = 6, // on the 'o' of docs
    }) orelse return error.ExpectedToken;
    defer token.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("docs/x.md", token.text);
    try std.testing.expectEqual(GridCell{ .row = 0, .col = 5 }, token.start); // 'd' of docs
}
