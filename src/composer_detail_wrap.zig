//! Wrapping math for the composer suggestion detail panel.
//!
//! Splits a suggestion's (already single-line) description into at most
//! `MAX_LINES` display lines that fit a pixel width, capping the result so the
//! popup never grows unbounded. Kept free of renderer/font globals so the logic
//! is unit-testable: callers inject codepoint advances via `advance`.

const std = @import("std");

/// Hard ceiling on rendered detail lines, regardless of the requested cap.
pub const MAX_LINES: usize = 6;

pub const WrapLine = struct {
    /// Byte offset where the line's text begins.
    start: usize,
    /// Byte offset one past the line's text (excludes any '\n' break).
    end: usize,
};

pub const WrapResult = struct {
    lines: [MAX_LINES]WrapLine,
    /// Number of populated entries in `lines`.
    count: usize,
    /// True when `text` needed more than `max_lines` lines, so the caller should
    /// render the final line with an overflow ellipsis.
    truncated: bool,
};

const CodepointItem = struct { len: usize, advance: f32 };

fn nextCodepoint(text: []const u8, i: usize, advance: *const fn (u21) f32) CodepointItem {
    const first = text[i];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (i + len > text.len) return .{ .len = 1, .advance = advance('?') };
    const cp = std.unicode.utf8Decode(text[i .. i + len]) catch @as(u21, '?');
    return .{ .len = len, .advance = advance(cp) };
}

/// Wrap `text` into at most `min(max_lines, MAX_LINES)` lines no wider than
/// `max_w`, breaking on width overflow and on '\n'. Width is measured by summing
/// `advance(codepoint)` (character-level wrapping, matching the renderer's other
/// wrap helpers — there is no word-boundary logic).
pub fn wrap(
    text: []const u8,
    max_w: f32,
    max_lines: usize,
    advance: *const fn (u21) f32,
) WrapResult {
    var result = WrapResult{ .lines = undefined, .count = 0, .truncated = false };
    const limit = @min(max_lines, MAX_LINES);
    if (limit == 0) {
        result.truncated = text.len > 0;
        return result;
    }

    var line_start: usize = 0;
    var line_width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            result.lines[result.count] = .{ .start = line_start, .end = i };
            result.count += 1;
            i += 1; // drop the break byte itself
            line_start = i;
            line_width = 0;
            if (result.count >= limit) {
                result.truncated = i < text.len;
                return result;
            }
            continue;
        }

        const item = nextCodepoint(text, i, advance);
        if (line_width > 0 and line_width + item.advance > max_w) {
            result.lines[result.count] = .{ .start = line_start, .end = i };
            result.count += 1;
            line_start = i; // re-measure this codepoint on the next line
            line_width = 0;
            if (result.count >= limit) {
                result.truncated = i < text.len;
                return result;
            }
            continue;
        }

        line_width += item.advance;
        i += item.len;
    }

    result.lines[result.count] = .{ .start = line_start, .end = text.len };
    result.count += 1;
    return result;
}

fn asciiAdvance(cp: u21) f32 {
    return if (cp < 0x80) 1.0 else 2.0;
}

test "wrap: character-wraps text at the width limit" {
    const r = wrap("aaabbbccc", 3.0, 6, &asciiAdvance);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expect(!r.truncated);
    try std.testing.expectEqualStrings("aaa", "aaabbbccc"[r.lines[0].start..r.lines[0].end]);
    try std.testing.expectEqualStrings("bbb", "aaabbbccc"[r.lines[1].start..r.lines[1].end]);
    try std.testing.expectEqualStrings("ccc", "aaabbbccc"[r.lines[2].start..r.lines[2].end]);
}

test "wrap: caps at max_lines and reports truncation" {
    const r = wrap("aaabbbcccddd", 3.0, 2, &asciiAdvance);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expect(r.truncated);
}

test "wrap: short text fits without truncation" {
    const r = wrap("aaabbbcccddd", 3.0, 6, &asciiAdvance);
    try std.testing.expectEqual(@as(usize, 4), r.count);
    try std.testing.expect(!r.truncated);
}

test "wrap: breaks on explicit newlines without emitting the break byte" {
    const text = "ab\ncd";
    const r = wrap(text, 100.0, 6, &asciiAdvance);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expect(!r.truncated);
    try std.testing.expectEqualStrings("ab", text[r.lines[0].start..r.lines[0].end]);
    try std.testing.expectEqualStrings("cd", text[r.lines[1].start..r.lines[1].end]);
}

test "wrap: measures multi-byte glyphs by their advance" {
    const text = "中文a"; // each CJK glyph advances 2.0, 'a' advances 1.0
    const r = wrap(text, 2.0, 6, &asciiAdvance);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqualStrings("中", text[r.lines[0].start..r.lines[0].end]);
    try std.testing.expectEqualStrings("文", text[r.lines[1].start..r.lines[1].end]);
    try std.testing.expectEqualStrings("a", text[r.lines[2].start..r.lines[2].end]);
}
