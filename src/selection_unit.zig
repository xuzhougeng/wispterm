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

pub fn isWordCodepoint(cp: u21) bool {
    return !isBlankCodepoint(cp) and !isWordDelimiter(cp);
}

/// Copy the wide character into each following spacer-tail column.
/// Ghostty stores that tail as codepoint 0, which word selection would treat
/// as a blank and which would cut a Chinese word after every glyph.
pub fn bridgeWideSpacers(row: []u21, spacer_tail: []const bool) void {
    const n = @min(row.len, spacer_tail.len);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        if (spacer_tail[i]) row[i] = row[i - 1];
    }
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

test "selection unit: wide spacer tails stay inside a Chinese word" {
    var row = [_]u21{ '分', 0, '析', 0, '.', 'd', 'o', 'c', 'x' };
    const tails = [_]bool{ false, true, false, true, false, false, false, false, false };
    bridgeWideSpacers(&row, &tails);
    try std.testing.expectEqual(ColRange{ .start = 0, .end = 8 }, wordRange(&row, 1).?);
    try std.testing.expectEqual(ColRange{ .start = 0, .end = 8 }, wordRange(&row, 6).?);
}

test "selection unit: a real empty cell still splits a word" {
    var row = [_]u21{ '分', 0, '析' };
    const tails = [_]bool{ false, false, false };
    bridgeWideSpacers(&row, &tails);
    try std.testing.expectEqual(ColRange{ .start = 0, .end = 0 }, wordRange(&row, 0).?);
    try std.testing.expect(wordRange(&row, 1) == null);
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

fn toCodepoints(comptime text: []const u8) [text.len]u21 {
    var out: [text.len]u21 = undefined;
    for (text, 0..) |ch, i| out[i] = ch;
    return out;
}
