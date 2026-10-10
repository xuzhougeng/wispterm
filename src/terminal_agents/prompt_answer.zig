//! Pure parsing/answer logic for Claude Code / Codex approval menus. No I/O.
//! `parsePromptOptions` extracts the numbered options of an approval prompt from
//! the live screen text; `resolveAnswer` (Task 5) maps a semantic answer to the
//! keystroke to send. Sibling of `detector.zig`.
const std = @import("std");
const text_search = @import("../text_search.zig");

pub const Option = struct {
    number: u8 = 0,
    highlighted: bool = false,
    shortcut: ?u8 = null,
    label: []const u8 = "",
};

pub const Intent = enum { approve, approve_all, reject, enter, esc, option };

pub const Keystroke = struct {
    bytes: []const u8,
    confirm_enter: bool = false,
};

const digit_keys = "0123456789";

pub fn parseIntent(answer: []const u8) ?Intent {
    const a = std.mem.trim(u8, answer, " \t\r\n");
    if (eqlIgnoreCase(a, "approve") or eqlIgnoreCase(a, "yes") or eqlIgnoreCase(a, "y")) return .approve;
    if (eqlIgnoreCase(a, "approve_all") or eqlIgnoreCase(a, "always") or eqlIgnoreCase(a, "all")) return .approve_all;
    if (eqlIgnoreCase(a, "reject") or eqlIgnoreCase(a, "no") or eqlIgnoreCase(a, "n") or eqlIgnoreCase(a, "deny")) return .reject;
    if (eqlIgnoreCase(a, "enter")) return .enter;
    if (eqlIgnoreCase(a, "esc") or eqlIgnoreCase(a, "escape")) return .esc;
    if (a.len == 1 and a[0] >= '1' and a[0] <= '9') return .option;
    return null;
}

pub fn parseOptionNumber(answer: []const u8) ?u8 {
    const a = std.mem.trim(u8, answer, " \t\r\n");
    if (a.len == 1 and a[0] >= '1' and a[0] <= '9') return a[0] - '0';
    return null;
}

/// Map a semantic answer to the keystroke to send. `option_number` is only used
/// when `intent == .option`. Returns null when the intent cannot be matched to
/// anything on screen (caller should then ask for an explicit option number).
pub fn resolveAnswer(options: []const Option, screen: []const u8, intent: Intent, option_number: u8) ?Keystroke {
    const confirm = containsIgnoreCase(screen, "press enter to confirm");

    if (options.len == 0 and hasInlineYesNo(screen)) {
        return switch (intent) {
            .approve, .approve_all => Keystroke{ .bytes = "y", .confirm_enter = true },
            .reject => Keystroke{ .bytes = "n", .confirm_enter = true },
            .enter => Keystroke{ .bytes = "\r" },
            .esc => Keystroke{ .bytes = "\x1b" },
            .option => null,
        };
    }

    return switch (intent) {
        .enter => Keystroke{ .bytes = "\r" },
        .esc, .reject => Keystroke{ .bytes = "\x1b" },
        .option => digitKeystroke(option_number, confirm),
        .approve => blk: {
            const opt = firstAffirmative(options) orelse break :blk null;
            break :blk digitKeystroke(opt.number, confirm);
        },
        .approve_all => blk: {
            const opt = firstAllowAll(options) orelse break :blk null;
            break :blk digitKeystroke(opt.number, confirm);
        },
    };
}

/// True when no parsed option carries an on-screen digit, i.e. the menu was
/// answered with arrow navigation (Pi selectors). Numbered menus keep digits.
pub fn optionsAreArrowStyle(options: []const Option) bool {
    if (options.len == 0) return false;
    for (options) |o| {
        if (o.number != 0) return false;
    }
    return true;
}

/// Pi dialogs use arrow keys + Enter (no digits). `option_number` selects by
/// parsed list ordinal when intent is .option; semantic intents pick the Yes/
/// allow-all/No row. Navigation recomputes Up/Down steps from the highlighted
/// row and commits with Enter. Only marked rows are navigable.
pub fn resolveArrowAnswer(options: []const Option, intent: Intent, option_number: u8, buf: []u8) ?Keystroke {
    if (options.len == 0) return null;
    const picked: ?usize = switch (intent) {
        .approve => blk: {
            for (options, 0..) |o, idx| {
                if (startsWithIgnoreCase(o.label, "yes") and !isAllowAllLabel(o.label)) break :blk idx;
            }
            break :blk null;
        },
        .approve_all => blk: {
            for (options, 0..) |o, idx| {
                if (isAllowAllLabel(o.label)) break :blk idx;
            }
            break :blk null;
        },
        .reject => blk: {
            for (options, 0..) |o, idx| {
                if (startsWithIgnoreCase(o.label, "no") or eqlIgnoreCase(o.label, "reject") or eqlIgnoreCase(o.label, "deny") or eqlIgnoreCase(o.label, "cancel")) break :blk idx;
            }
            break :blk null;
        },
        .option => blk: {
            if (option_number < 1 or option_number > options.len) break :blk null;
            break :blk option_number - 1;
        },
        .enter => return Keystroke{ .bytes = "\r" },
        .esc => return Keystroke{ .bytes = "\x1b" },
    };
    const target = picked orelse return null;
    var current: usize = 0;
    for (options, 0..) |o, idx| {
        if (o.highlighted) {
            current = idx;
            break;
        }
    }
    var down = target > current;
    var moves: usize = if (down) target - current else current - target;
    if (moves == 0) {
        // Pi wraps selection; taking the shorter wrap direction can still be
        // zero moves only when target == current, which cannot happen here.
        if (target == current) return Keystroke{ .bytes = "\r" };
        down = current < target;
        moves = if (down) target - current else current - target;
    }
    var len: usize = 0;
    const seq: []const u8 = if (down) "\x1b[B" else "\x1b[A";
    while (moves > 0 and len + seq.len + 1 <= buf.len) : (moves -= 1) {
        @memcpy(buf[len .. len + seq.len], seq);
        len += seq.len;
    }
    if (moves != 0) return null;
    buf[len] = '\r';
    len += 1;
    return .{ .bytes = buf[0..len] };
}

fn digitKeystroke(number: u8, confirm: bool) ?Keystroke {
    if (number < 1 or number > 9) return null;
    return .{ .bytes = digit_keys[number .. number + 1], .confirm_enter = confirm };
}

fn firstAffirmative(options: []const Option) ?Option {
    for (options) |o| {
        if (startsWithIgnoreCase(o.label, "yes") and !isAllowAllLabel(o.label)) return o;
    }
    for (options) |o| {
        if (o.number == 1 and !isAllowAllLabel(o.label)) return o;
    }
    return null;
}

fn firstAllowAll(options: []const Option) ?Option {
    for (options) |o| {
        if (isAllowAllLabel(o.label)) return o;
    }
    return null;
}

fn isAllowAllLabel(label: []const u8) bool {
    return containsIgnoreCase(label, "all") or
        containsIgnoreCase(label, "don't ask") or
        containsIgnoreCase(label, "dont ask") or
        containsIgnoreCase(label, "this session");
}

fn hasInlineYesNo(screen: []const u8) bool {
    return containsIgnoreCase(screen, "[y/n]") or containsIgnoreCase(screen, "(y/n)");
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return text_search.startsWithIgnoreCase(haystack, prefix);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return text_search.containsIgnoreCase(haystack, needle);
}

/// Parse numbered option lines out of `screen`, writing up to `out.len` of them.
/// Returns the count written. An option line is, after optional leading spaces:
/// an optional selection marker (`>` or `❯`), a digit 1-9, `.` or `)`, then the
/// label (which may carry a trailing single-letter `(x)` shortcut).
/// Pi's ExtensionSelectorComponent renders unnumbered arrow-style rows
/// (`→ Yes`, `  No`; arrow keys + Enter/esc), so those rows are parsed too:
/// list order becomes the 1..n ordinal and the marker sets `highlighted`.
pub fn parsePromptOptions(screen: []const u8, out: []Option) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |raw| {
        if (count >= out.len) break;
        const line = std.mem.trimRight(u8, raw, " \t\r");
        if (parseOptionLine(line)) |parsed| {
            out[count] = parsed;
            count += 1;
            continue;
        }
        if (parseArrowOptionLine(line)) |parsed| {
            out[count] = parsed;
            count += 1;
        }
    }
    return count;
}

/// Pi-style unnumbered selector row: two spaces, optional `→`/`>` highlight
/// marker, then the label (arrow keys + Enter; digits are never rendered).
/// Any such row inside the dialog block makes the menu arrow-style.
fn parseArrowOptionLine(line: []const u8) ?Option {
    var i: usize = 0;
    var spaces: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {
        spaces += 1;
    }
    var highlighted = false;
    if (i + 3 <= line.len and std.mem.eql(u8, line[i .. i + 3], "\xe2\x86\x92")) { // → U+2192
        highlighted = true;
        i += 3;
    } else if (i < line.len and line[i] == '>') {
        highlighted = true;
        i += 1;
    }
    // Marker rows may start at column 0 (Pi renders the selected row flush
    // left); unmarked rows need two spaces of indent to reject prose lines.
    if (!highlighted and spaces < 2) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return null;
    const label = line[i..];
    // Guard against prose lines that merely start with spaces.
    if (label.len < 2) return null;
    return .{
        .number = 0,
        .highlighted = highlighted,
        .label = label,
    };
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

test "parseIntent maps answer words and digits" {
    try std.testing.expectEqual(Intent.approve, parseIntent("approve").?);
    try std.testing.expectEqual(Intent.approve, parseIntent("yes").?);
    try std.testing.expectEqual(Intent.approve_all, parseIntent("approve_all").?);
    try std.testing.expectEqual(Intent.reject, parseIntent("reject").?);
    try std.testing.expectEqual(Intent.reject, parseIntent("no").?);
    try std.testing.expectEqual(Intent.esc, parseIntent("esc").?);
    try std.testing.expectEqual(Intent.enter, parseIntent("enter").?);
    try std.testing.expectEqual(Intent.option, parseIntent("2").?);
    try std.testing.expectEqual(@as(?Intent, null), parseIntent("banana"));
    try std.testing.expectEqual(@as(?u8, 2), parseOptionNumber("2"));
}

test "resolveAnswer picks the plain Yes for approve" {
    const screen =
        \\Do you want to make this edit?
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    const k = resolveAnswer(buf[0..n], screen, .approve, 0).?;
    try std.testing.expectEqualStrings("1", k.bytes);
    try std.testing.expect(!k.confirm_enter);
}

test "resolveAnswer picks the allow-all option for approve_all" {
    const screen =
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    const k = resolveAnswer(buf[0..n], screen, .approve_all, 0).?;
    try std.testing.expectEqualStrings("2", k.bytes);
}

test "resolveAnswer rejects with esc" {
    const screen = "  1. Yes\n  3. No";
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    const k = resolveAnswer(buf[0..n], screen, .reject, 0).?;
    try std.testing.expectEqualStrings("\x1b", k.bytes);
}

test "resolveAnswer follows Codex 'press enter to confirm' with a confirm Enter" {
    const screen =
        \\> 1. Yes, proceed (y)
        \\  3. No, and tell codex what to do differently (esc)
        \\Press enter to confirm or esc to cancel
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    const k = resolveAnswer(buf[0..n], screen, .approve, 0).?;
    try std.testing.expectEqualStrings("1", k.bytes);
    try std.testing.expect(k.confirm_enter);
}

test "resolveAnswer handles an inline [y/N] prompt with no numbered options" {
    const screen = "Overwrite existing file? [y/N]";
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
    const yes = resolveAnswer(buf[0..n], screen, .approve, 0).?;
    try std.testing.expectEqualStrings("y", yes.bytes);
    try std.testing.expect(yes.confirm_enter);
    const no = resolveAnswer(buf[0..n], screen, .reject, 0).?;
    try std.testing.expectEqualStrings("n", no.bytes);
}

test "parsePromptOptions reads Pi selector rows and numbers them by order" {
    const screen = "Allow bash to run?\n\xe2\x86\x92 Yes\n    No\n";
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    // The highlighted row is flush left; the unmarked row is indented.
    // Both are captured with no on-screen digit; list order gives ordinals.
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(buf[0].highlighted);
    try std.testing.expectEqualStrings("Yes", buf[0].label);
    try std.testing.expect(!buf[1].highlighted);
    try std.testing.expectEqualStrings("No", buf[1].label);
    try std.testing.expect(optionsAreArrowStyle(buf[0..n]));
}

test "resolveArrowAnswer navigates Pi selectors with arrow keys" {
    // Highlighted Yes plus a plain No row: both are navigable selector rows.
    const screen = "\xe2\x86\x92 Yes\n    No";
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(optionsAreArrowStyle(buf[0..n]));

    var yes_buf: [40]u8 = undefined;
    const yes = resolveArrowAnswer(buf[0..n], .approve, 0, &yes_buf).?;
    try std.testing.expectEqualStrings("\r", yes.bytes);

    // `→ Yes` is row 0; No is row 1 → one Down then Enter.
    var no_buf: [40]u8 = undefined;
    const no = resolveArrowAnswer(buf[0..n], .reject, 0, &no_buf).?;
    try std.testing.expectEqualStrings("\x1b[B\r", no.bytes);

    var esc_buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b", resolveArrowAnswer(buf[0..n], .esc, 0, &esc_buf).?.bytes);
    var option_buf: [40]u8 = undefined;
    try std.testing.expectEqual(@as(?Keystroke, null), resolveArrowAnswer(buf[0..n], .option, 9, &option_buf));
}

test "resolveAnswer returns null when approve has no matching option" {
    const screen = "some text, no menu";
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    try std.testing.expectEqual(@as(?Keystroke, null), resolveAnswer(buf[0..n], screen, .approve, 0));
}
