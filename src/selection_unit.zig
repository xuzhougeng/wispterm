const std = @import("std");

pub const ColRange = struct {
    start: usize,
    end: usize,
};

pub const default_word_delimiters = "\\ :;~`!@#$%^&*()=+|[]{}'\",<>?";

pub fn wordRange(row: []const u21, col: usize) ?ColRange {
    if (col >= row.len or !isWordCodepoint(row[col])) return null;

    var start = col;
    while (start > 0 and isWordCodepoint(row[start - 1])) : (start -= 1) {}

    var end = col;
    while (end + 1 < row.len and isWordCodepoint(row[end + 1])) : (end += 1) {}

    return .{ .start = start, .end = end };
}

/// Range covering a single row's text, from its first to last non-blank cell.
/// Used by triple-click to select the whole line. Null for a blank row.
pub fn lineRange(row: []const u21) ?ColRange {
    const start = firstNonBlankCol(row) orelse return null;
    const end = lastNonBlankCol(row) orelse return null;
    return .{ .start = start, .end = end };
}

pub fn firstNonBlankCol(row: []const u21) ?usize {
    for (row, 0..) |cp, i| {
        if (!isBlankCodepoint(cp)) return i;
    }
    return null;
}

pub fn lastNonBlankCol(row: []const u21) ?usize {
    var i = row.len;
    while (i > 0) {
        i -= 1;
        if (!isBlankCodepoint(row[i])) return i;
    }
    return null;
}

pub fn rowIsBlank(row: []const u21) bool {
    return firstNonBlankCol(row) == null;
}

pub fn trimTrailingClipboardSpaces(row: []const u8) []const u8 {
    var end = row.len;
    while (end > 0 and row[end - 1] <= ' ') : (end -= 1) {}
    return row[0..end];
}

/// One selected terminal row, ready to be joined into clipboard text.
pub const SelectionRow = struct {
    /// The selected span of this row as UTF-8 text. Trailing terminal blanks
    /// are NOT pre-trimmed; `joinSelectionRows` decides whether to trim.
    text: []const u8,
    /// True when this row is soft-wrapped: the next selected row is a visual
    /// continuation of the same logical line (ghostty `Row.wrap`).
    wraps_next: bool,
};

/// Join selected terminal rows into clipboard text.
///
/// A soft-wrapped row (`wraps_next`) is a continuation of one logical line, so
/// it is concatenated to the following row with no separator and without
/// trimming trailing blanks — a visually wrapped line such as a long path
/// copies back as a single line. A row that ends a logical line is joined to
/// the next with "\r\n" after trimming trailing terminal blanks, and the final
/// row is trimmed with no trailing separator. This matches Windows Terminal and
/// Ghostty (whose `selectionString` "unwraps soft-wrapped edges").
pub fn joinSelectionRows(
    allocator: std.mem.Allocator,
    rows: []const SelectionRow,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (rows, 0..) |r, i| {
        const is_last = i + 1 == rows.len;
        if (!is_last and r.wraps_next) {
            // Soft wrap: this row continues onto the next, so join with no
            // separator and keep trailing content verbatim.
            try out.appendSlice(allocator, r.text);
        } else {
            // Hard line end (or the final row): trim trailing terminal blanks,
            // and break to the next line unless this is the last row.
            try out.appendSlice(allocator, trimTrailingClipboardSpaces(r.text));
            if (!is_last) try out.appendSlice(allocator, "\r\n");
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn isWordCodepoint(cp: u21) bool {
    return !isBlankCodepoint(cp) and !isWordDelimiter(cp);
}

fn isWordDelimiter(cp: u21) bool {
    if (cp > 0x7f) return false;
    for (default_word_delimiters) |delimiter| {
        if (cp == delimiter) return true;
    }
    return false;
}

fn isBlankCodepoint(cp: u21) bool {
    return cp == 0 or cp <= 0x20;
}

test "selection unit: word range selects an alphanumeric token" {
    const row = comptime toCodepoints("alpha beta_42.");
    try std.testing.expectEqual(ColRange{ .start = 6, .end = 13 }, wordRange(&row, 8).?);
}

test "selection unit: word range uses configured delimiter set" {
    const row = comptime toCodepoints("cat SRP174132_metadata.csv /tmp/a-b.c:next");
    try std.testing.expectEqual(ColRange{ .start = 4, .end = 25 }, wordRange(&row, 12).?);
    try std.testing.expectEqual(ColRange{ .start = 27, .end = 36 }, wordRange(&row, 33).?);
    try std.testing.expectEqual(ColRange{ .start = 38, .end = 41 }, wordRange(&row, 40).?);
    try std.testing.expect(wordRange(&row, 26) == null);
    try std.testing.expect(wordRange(&row, 37) == null);
}

test "selection unit: line range spans first to last nonblank cell" {
    const row = comptime toCodepoints("  hello world  ");
    try std.testing.expectEqual(ColRange{ .start = 2, .end = 12 }, lineRange(&row).?);
}

test "selection unit: line range is null for a blank row" {
    const row = comptime toCodepoints("    ");
    try std.testing.expect(lineRange(&row) == null);
}

test "selection unit: clipboard row trim removes trailing terminal blanks only" {
    try std.testing.expectEqualStrings(
        "CC_AGENT_API_KEY=\"$(cat ~/.cc-agent-key)\" \\",
        trimTrailingClipboardSpaces("CC_AGENT_API_KEY=\"$(cat ~/.cc-agent-key)\" \\     "),
    );
    try std.testing.expectEqualStrings(
        "           -cwd ~/cc-agent/yard \\",
        trimTrailingClipboardSpaces("           -cwd ~/cc-agent/yard \\     "),
    );
    try std.testing.expectEqualStrings("", trimTrailingClipboardSpaces("     \t  "));
}

test "join selection rows: soft-wrapped line copies as one line" {
    // The reported bug: a long path that visually wraps must copy as a single
    // line, not split at the wrap boundary.
    const rows = [_]SelectionRow{
        .{ .text = "~/project/Plant-Root-Atlas-Project/06.trajectory_analysis/result/pl", .wraps_next = true },
        .{ .text = "ot/marker_gene_grouped_panels/combinations/Osa_Sly_Gma_Cri_Ath_ref_cri", .wraps_next = false },
    };
    const joined = try joinSelectionRows(std.testing.allocator, &rows);
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings(
        "~/project/Plant-Root-Atlas-Project/06.trajectory_analysis/result/plot/marker_gene_grouped_panels/combinations/Osa_Sly_Gma_Cri_Ath_ref_cri",
        joined,
    );
}

test "join selection rows: hard line breaks keep CRLF separators" {
    const rows = [_]SelectionRow{
        .{ .text = "line one", .wraps_next = false },
        .{ .text = "line two", .wraps_next = false },
    };
    const joined = try joinSelectionRows(std.testing.allocator, &rows);
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("line one\r\nline two", joined);
}

test "join selection rows: trims hard-break and final rows but preserves soft-wrap content" {
    const rows = [_]SelectionRow{
        // Soft wrap: trailing spaces are part of the logical line — keep them.
        .{ .text = "abc   ", .wraps_next = true },
        // Hard break: trailing terminal blanks trimmed, CRLF added.
        .{ .text = "def   ", .wraps_next = false },
        // Final row: trailing blanks trimmed, no separator.
        .{ .text = "ghi   ", .wraps_next = false },
    };
    const joined = try joinSelectionRows(std.testing.allocator, &rows);
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("abc   def\r\nghi", joined);
}

test "join selection rows: single row trims trailing blanks without separator" {
    const rows = [_]SelectionRow{
        .{ .text = "hello   ", .wraps_next = false },
    };
    const joined = try joinSelectionRows(std.testing.allocator, &rows);
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("hello", joined);
}

test "join selection rows: wraps_next on the final selected row is ignored" {
    // Selection ends exactly at a soft-wrap boundary: there is no next row to
    // join to, so the final row is trimmed like any line end.
    const rows = [_]SelectionRow{
        .{ .text = "foo", .wraps_next = true },
        .{ .text = "bar   ", .wraps_next = true },
    };
    const joined = try joinSelectionRows(std.testing.allocator, &rows);
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("foobar", joined);
}

test "join selection rows: mixes soft wrap and hard breaks" {
    const rows = [_]SelectionRow{
        .{ .text = "aaa", .wraps_next = true },
        .{ .text = "bbb", .wraps_next = false },
        .{ .text = "ccc", .wraps_next = false },
    };
    const joined = try joinSelectionRows(std.testing.allocator, &rows);
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("aaabbb\r\nccc", joined);
}

fn toCodepoints(comptime text: []const u8) [text.len]u21 {
    var out: [text.len]u21 = undefined;
    for (text, 0..) |ch, i| out[i] = ch;
    return out;
}
