//! Pure parsing/answer logic for Claude Code / Codex approval menus. No I/O.
//! `parsePromptOptions` extracts the numbered options of an approval prompt from
//! the live screen text; `resolveAnswer` (Task 5) maps a semantic answer to the
//! keystroke to send. Sibling of `agent_detector.zig`.
const std = @import("std");

pub const Option = struct {
    number: u8 = 0,
    highlighted: bool = false,
    shortcut: ?u8 = null,
    label: []const u8 = "",
};

/// Parse numbered option lines out of `screen`, writing up to `out.len` of them.
/// Returns the count written. An option line is, after optional leading spaces:
/// an optional selection marker (`>` or `❯`), a digit 1-9, `.` or `)`, then the
/// label (which may carry a trailing single-letter `(x)` shortcut).
pub fn parsePromptOptions(screen: []const u8, out: []Option) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |raw| {
        if (count >= out.len) break;
        const line = std.mem.trimRight(u8, raw, " \t\r");
        const parsed = parseOptionLine(line) orelse continue;
        out[count] = parsed;
        count += 1;
    }
    return count;
}

fn parseOptionLine(line: []const u8) ?Option {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    var highlighted = false;
    if (i < line.len and line[i] == '>') {
        highlighted = true;
        i += 1;
    } else if (i + 3 <= line.len and std.mem.eql(u8, line[i .. i + 3], "\xe2\x9d\xaf")) {
        highlighted = true; // ❯ U+276F
        i += 3;
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    if (i >= line.len or line[i] < '1' or line[i] > '9') return null;
    const number = line[i] - '0';
    i += 1;
    if (i >= line.len or (line[i] != '.' and line[i] != ')')) return null;
    i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const label = line[i..];
    return .{
        .number = number,
        .highlighted = highlighted,
        .shortcut = parseShortcut(label),
        .label = label,
    };
}

/// Capture a trailing single-letter parenthesized shortcut, e.g. "Yes (y)" → 'y'.
/// Multi-character hints like "(shift+tab)" or "(esc)" are ignored.
fn parseShortcut(label: []const u8) ?u8 {
    if (label.len < 3) return null;
    if (label[label.len - 1] != ')') return null;
    if (label[label.len - 3] != '(') return null;
    const c = label[label.len - 2];
    if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) return std.ascii.toLower(c);
    return null;
}

test "parsePromptOptions reads a Claude Code edit-approval menu" {
    const screen =
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0].number);
    try std.testing.expectEqualStrings("Yes", buf[0].label);
    try std.testing.expectEqual(@as(u8, 2), buf[1].number);
    try std.testing.expect(std.mem.indexOf(u8, buf[1].label, "allow all edits") != null);
    try std.testing.expectEqual(@as(u8, 3), buf[2].number);
    try std.testing.expectEqualStrings("No", buf[2].label);
}

test "parsePromptOptions reads a Codex menu with highlight and letter shortcuts" {
    const screen =
        \\Would you like to make the following edits?
        \\> 1. Yes, proceed (y)
        \\  2. Yes, and don't ask again for these files (a)
        \\  3. No, and tell codex what to do differently (esc)
        \\Press enter to confirm or esc to cancel
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(buf[0].highlighted);
    try std.testing.expectEqual(@as(?u8, 'y'), buf[0].shortcut);
    try std.testing.expectEqual(@as(?u8, 'a'), buf[1].shortcut);
    try std.testing.expectEqual(@as(?u8, null), buf[2].shortcut); // "(esc)" is not a single letter
}

test "parsePromptOptions ignores non-option lines" {
    const screen = "just some output\nno menu here\n$ ls -la";
    var buf: [8]Option = undefined;
    try std.testing.expectEqual(@as(usize, 0), parsePromptOptions(screen, &buf));
}
