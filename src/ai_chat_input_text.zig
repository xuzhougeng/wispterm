//! Pure input-text geometry helpers for the AI chat composer.
//!
//! This module is std-only: no platform imports, no app graph. It provides
//! UTF-8 boundary utilities and visual layout calculations (cursor position,
//! row spans, wrapped line counts) used by `ai_chat.zig`.

const std = @import("std");

pub fn clampUtf8Boundary(text: []const u8, cursor: usize) usize {
    var i = @min(cursor, text.len);
    while (i > 0 and i < text.len and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

pub fn previousUtf8Boundary(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var i = @min(cursor, text.len);
    i -= 1;
    while (i > 0 and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

pub fn nextUtf8Boundary(text: []const u8, cursor: usize) usize {
    if (cursor >= text.len) return text.len;
    var i = cursor + 1;
    while (i < text.len and (text[i] & 0xC0) == 0x80) : (i += 1) {}
    return i;
}

pub const VisualCursor = struct {
    row: usize,
    col: usize,
};

pub const VisualRow = struct {
    start: usize,
    end: usize,
};

pub fn nextUtf8Step(text: []const u8, index: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    return if (index + len <= text.len) len else 1;
}

pub fn visualCursorPosition(text: []const u8, cursor_raw: usize, max_cols_raw: usize) VisualCursor {
    const cursor = @min(cursor_raw, text.len);
    const max_cols = @max(@as(usize, 1), max_cols_raw);
    var row: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < cursor) {
        if (text[i] == '\n') {
            row += 1;
            col = 0;
            i += 1;
            continue;
        }
        if (col >= max_cols) {
            row += 1;
            col = 0;
        }
        col += 1;
        i += nextUtf8Step(text, i);
    }
    return .{ .row = row, .col = col };
}

pub fn visualRowAt(text: []const u8, target_row: usize, max_cols_raw: usize) ?VisualRow {
    const max_cols = @max(@as(usize, 1), max_cols_raw);
    var row: usize = 0;
    var row_start: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            if (row == target_row) return .{ .start = row_start, .end = i };
            row += 1;
            row_start = i + 1;
            col = 0;
            i += 1;
            continue;
        }
        if (col >= max_cols) {
            if (row == target_row) return .{ .start = row_start, .end = i };
            row += 1;
            row_start = i;
            col = 0;
        }
        col += 1;
        i += nextUtf8Step(text, i);
    }
    if (row == target_row) return .{ .start = row_start, .end = text.len };
    return null;
}

pub fn byteOffsetForVisualPosition(text: []const u8, target_row: usize, target_col: usize, max_cols: usize) ?usize {
    const row = visualRowAt(text, target_row, max_cols) orelse return null;
    var col: usize = 0;
    var i = row.start;
    while (i < row.end and col < target_col) {
        i += nextUtf8Step(text, i);
        col += 1;
    }
    return i;
}

pub fn inputWrappedLineCount(text: []const u8, max_cols_raw: usize) usize {
    if (text.len == 0) return 1;
    const max_cols = @max(@as(usize, 1), max_cols_raw);
    var lines: usize = 1;
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            lines += 1;
            cols = 0;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (cols >= max_cols) {
            lines += 1;
            cols = 0;
        }
        cols += 1;
        i += if (i + len <= text.len) len else 1;
    }
    return lines;
}

test "utf8 boundaries step across multi-byte runes" {
    const s = "a\u{00e9}b"; // 'a', 'é' (2 bytes), 'b'
    try std.testing.expectEqual(@as(usize, 1), nextUtf8Boundary(s, 0));
    try std.testing.expectEqual(@as(usize, 3), nextUtf8Boundary(s, 1));
    try std.testing.expectEqual(@as(usize, 1), previousUtf8Boundary(s, 3));
    try std.testing.expectEqual(@as(usize, 1), clampUtf8Boundary(s, 2));
}

test "visualCursorPosition wraps and honors newlines" {
    try std.testing.expectEqual(VisualCursor{ .row = 0, .col = 3 }, visualCursorPosition("abc", 3, 10));
    try std.testing.expectEqual(VisualCursor{ .row = 1, .col = 1 }, visualCursorPosition("ab\nc", 4, 10));
    try std.testing.expectEqual(VisualCursor{ .row = 1, .col = 2 }, visualCursorPosition("abcd", 4, 2));
}

test "visualRowAt spans rows including the last" {
    const s = "ab\ncd";
    try std.testing.expectEqual(VisualRow{ .start = 0, .end = 2 }, visualRowAt(s, 0, 10).?);
    try std.testing.expectEqual(VisualRow{ .start = 3, .end = 5 }, visualRowAt(s, 1, 10).?);
    try std.testing.expectEqual(@as(?VisualRow, null), visualRowAt(s, 2, 10));
}

test "byteOffsetForVisualPosition round-trips with visualCursorPosition" {
    const s = "hello\nworld";
    const cur = visualCursorPosition(s, 8, 10);
    try std.testing.expectEqual(@as(?usize, 8), byteOffsetForVisualPosition(s, cur.row, cur.col, 10));
}

test "inputWrappedLineCount: empty, newlines, wrap" {
    try std.testing.expectEqual(@as(usize, 1), inputWrappedLineCount("", 10));
    try std.testing.expectEqual(@as(usize, 1), inputWrappedLineCount("abc", 10));
    try std.testing.expectEqual(@as(usize, 2), inputWrappedLineCount("a\nb", 10));
    try std.testing.expectEqual(@as(usize, 2), inputWrappedLineCount("abcd", 2));
}
