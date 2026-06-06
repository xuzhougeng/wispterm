//! UTF-8- and width-aware line wrapping for the markdown preview (and any other
//! fixed-width text panel). The previous wrapper sliced at raw byte offsets,
//! which split multi-byte characters mid-sequence — fine for ASCII, but CJK text
//! (3-byte chars, no spaces to break on) wrapped into invalid UTF-8 slices that
//! rendered as `?`. These helpers advance by whole characters so a wrap offset
//! never lands inside a character.
const std = @import("std");

/// Byte length of the UTF-8 character starting at lead byte `b`. A continuation
/// or invalid byte is treated as length 1 so the caller still makes progress.
pub fn utf8CharLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b >= 0xF0) return 4;
    if (b >= 0xE0) return 3;
    if (b >= 0xC0) return 2;
    return 1;
}

/// Display columns for a character of byte length `clen`: 3–4 byte chars (CJK and
/// most wide glyphs) take 2 cells, everything else 1. A heuristic, but it keeps
/// CJK from overflowing the line.
fn charCols(clen: usize) usize {
    return if (clen >= 3) 2 else 1;
}

/// Byte offset at which the line starting at `start` should wrap, given a budget
/// of `max_cols` display columns. Advances by whole UTF-8 characters (so the
/// returned offset is always on a character boundary), prefers breaking at the
/// last space/tab within the line, and always consumes at least one character so
/// callers can't loop forever.
pub fn wrapEnd(text: []const u8, start: usize, max_cols: usize) usize {
    var i = start;
    var cols: usize = 0;
    var last_space: ?usize = null;
    while (i < text.len) {
        const b = text[i];
        const clen = @min(utf8CharLen(b), text.len - i);
        const w = charCols(clen);
        if (cols + w > max_cols and i > start) break;
        if (b == ' ' or b == '\t') last_space = i;
        i += clen;
        cols += w;
    }
    if (i >= text.len) return text.len;
    if (last_space) |sp| {
        if (sp > start) return sp;
    }
    return i;
}

/// Skip leading spaces/tabs (used to drop the break character between lines).
pub fn skipSpaces(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i;
}

// --- Tests ---

test "text_wrap: short text returns full length" {
    const s = "hello world";
    try std.testing.expectEqual(s.len, wrapEnd(s, 0, 40));
}

test "text_wrap: breaks at the last space within budget" {
    const s = "aa bb cc";
    const end = wrapEnd(s, 0, 4); // "aa " fits (cols 1,2,space=3,b=4); next b overflows
    try std.testing.expectEqualStrings("aa", s[0..end]);
}

test "text_wrap: never splits a multi-byte char (the CJK garble bug)" {
    const s = "中文测试一二三四五六七八九十"; // 3-byte CJK, no spaces
    var off: usize = 0;
    var iters: usize = 0;
    while (off < s.len) {
        const end = wrapEnd(s, off, 8);
        try std.testing.expect(end > off); // progress
        try std.testing.expect(std.unicode.utf8ValidateSlice(s[off..end]));
        off = skipSpaces(s, end);
        iters += 1;
        try std.testing.expect(iters < 100);
    }
}

test "text_wrap: a single wide char makes progress past the budget" {
    const s = "中"; // 3 bytes, 2 cols
    try std.testing.expectEqual(@as(usize, 3), wrapEnd(s, 0, 1));
}

test "text_wrap: mixed ascii+cjk slices stay valid utf8" {
    const s = "id: 同源序列 extractor 测试一二三";
    var off: usize = 0;
    while (off < s.len) {
        const end = wrapEnd(s, off, 6);
        try std.testing.expect(end > off);
        try std.testing.expect(std.unicode.utf8ValidateSlice(s[off..end]));
        off = skipSpaces(s, end);
    }
}
