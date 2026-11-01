//! Named-key syntax for `wisptermctl send-keys`, mirroring herdr's key-combo
//! grammar so scripts written for `herdr pane send-keys` carry over:
//!
//!   - plain printable keys: `a`, `/`, `你`
//!   - special keys: `enter`, `tab`, `esc`, `backspace`, `up`, `home`, `f5`, …
//!   - modifier chords: `ctrl+c`, `control+j`, `alt+x`, `shift+tab`,
//!     `ctrl+shift+s`; legacy `C-c` / `c-c` / `M-x` are aliases
//!   - named punctuation: `minus`, `plus`, `backtick`, `comma`, …
//!
//! Pure (std only): the standalone client validates names before it talks to
//! the server, and the server turns the parsed `Spec` into bytes with the
//! surface's live key encoder (Kitty keyboard protocol, DECCKM, …) so a sent
//! key is byte-identical to the user pressing it.
const std = @import("std");

pub const Key = enum {
    /// A printable character; `Spec.codepoint` holds it.
    char,
    enter,
    tab,
    escape,
    backspace,
    space,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Spec = struct {
    key: Key,
    /// Set for `.char` (and for named punctuation, which is a `.char`).
    codepoint: u21 = 0,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn eql(a: Spec, b: Spec) bool {
        return std.meta.eql(a, b);
    }
};

const Named = struct { name: []const u8, key: Key, codepoint: u21 = 0 };

/// Case-insensitive key names. The first entry for a key is its canonical
/// spelling; later ones are accepted aliases (herdr's and tmux's).
const named_keys = [_]Named{
    .{ .name = "enter", .key = .enter },
    .{ .name = "return", .key = .enter },
    .{ .name = "cr", .key = .enter },
    .{ .name = "tab", .key = .tab },
    .{ .name = "esc", .key = .escape },
    .{ .name = "escape", .key = .escape },
    .{ .name = "backspace", .key = .backspace },
    .{ .name = "bspace", .key = .backspace },
    .{ .name = "bs", .key = .backspace },
    .{ .name = "space", .key = .space },
    .{ .name = "delete", .key = .delete },
    .{ .name = "del", .key = .delete },
    .{ .name = "dc", .key = .delete },
    .{ .name = "insert", .key = .insert },
    .{ .name = "ins", .key = .insert },
    .{ .name = "ic", .key = .insert },
    .{ .name = "home", .key = .home },
    .{ .name = "end", .key = .end },
    .{ .name = "pageup", .key = .page_up },
    .{ .name = "page_up", .key = .page_up },
    .{ .name = "pgup", .key = .page_up },
    .{ .name = "ppage", .key = .page_up },
    .{ .name = "pagedown", .key = .page_down },
    .{ .name = "page_down", .key = .page_down },
    .{ .name = "pgdn", .key = .page_down },
    .{ .name = "npage", .key = .page_down },
    .{ .name = "up", .key = .up },
    .{ .name = "arrow_up", .key = .up },
    .{ .name = "down", .key = .down },
    .{ .name = "arrow_down", .key = .down },
    .{ .name = "left", .key = .left },
    .{ .name = "arrow_left", .key = .left },
    .{ .name = "right", .key = .right },
    .{ .name = "arrow_right", .key = .right },
    .{ .name = "f1", .key = .f1 },
    .{ .name = "f2", .key = .f2 },
    .{ .name = "f3", .key = .f3 },
    .{ .name = "f4", .key = .f4 },
    .{ .name = "f5", .key = .f5 },
    .{ .name = "f6", .key = .f6 },
    .{ .name = "f7", .key = .f7 },
    .{ .name = "f8", .key = .f8 },
    .{ .name = "f9", .key = .f9 },
    .{ .name = "f10", .key = .f10 },
    .{ .name = "f11", .key = .f11 },
    .{ .name = "f12", .key = .f12 },
    // Named punctuation (herdr): lets a chord name a key that `+` / `-`
    // syntax would otherwise swallow, and keeps shell quoting simple.
    .{ .name = "minus", .key = .char, .codepoint = '-' },
    .{ .name = "plus", .key = .char, .codepoint = '+' },
    .{ .name = "backtick", .key = .char, .codepoint = '`' },
    .{ .name = "grave", .key = .char, .codepoint = '`' },
    .{ .name = "comma", .key = .char, .codepoint = ',' },
    .{ .name = "period", .key = .char, .codepoint = '.' },
    .{ .name = "dot", .key = .char, .codepoint = '.' },
    .{ .name = "slash", .key = .char, .codepoint = '/' },
    .{ .name = "backslash", .key = .char, .codepoint = '\\' },
    .{ .name = "semicolon", .key = .char, .codepoint = ';' },
    .{ .name = "colon", .key = .char, .codepoint = ':' },
    .{ .name = "apostrophe", .key = .char, .codepoint = '\'' },
    .{ .name = "quote", .key = .char, .codepoint = '\'' },
    .{ .name = "doublequote", .key = .char, .codepoint = '"' },
    .{ .name = "equal", .key = .char, .codepoint = '=' },
    .{ .name = "equals", .key = .char, .codepoint = '=' },
    .{ .name = "underscore", .key = .char, .codepoint = '_' },
    .{ .name = "tilde", .key = .char, .codepoint = '~' },
    .{ .name = "bracketleft", .key = .char, .codepoint = '[' },
    .{ .name = "bracketright", .key = .char, .codepoint = ']' },
    .{ .name = "braceleft", .key = .char, .codepoint = '{' },
    .{ .name = "braceright", .key = .char, .codepoint = '}' },
    .{ .name = "parenleft", .key = .char, .codepoint = '(' },
    .{ .name = "parenright", .key = .char, .codepoint = ')' },
    .{ .name = "less", .key = .char, .codepoint = '<' },
    .{ .name = "greater", .key = .char, .codepoint = '>' },
    .{ .name = "question", .key = .char, .codepoint = '?' },
    .{ .name = "exclam", .key = .char, .codepoint = '!' },
    .{ .name = "at", .key = .char, .codepoint = '@' },
    .{ .name = "hash", .key = .char, .codepoint = '#' },
    .{ .name = "dollar", .key = .char, .codepoint = '$' },
    .{ .name = "percent", .key = .char, .codepoint = '%' },
    .{ .name = "caret", .key = .char, .codepoint = '^' },
    .{ .name = "ampersand", .key = .char, .codepoint = '&' },
    .{ .name = "asterisk", .key = .char, .codepoint = '*' },
    .{ .name = "star", .key = .char, .codepoint = '*' },
    .{ .name = "pipe", .key = .char, .codepoint = '|' },
    .{ .name = "bar", .key = .char, .codepoint = '|' },
};

const Modifier = enum { ctrl, alt, shift };

fn modifierFromName(name: []const u8) ?Modifier {
    const ctrl_names = [_][]const u8{ "ctrl", "control", "c" };
    const alt_names = [_][]const u8{ "alt", "option", "opt", "meta", "m" };
    const shift_names = [_][]const u8{ "shift", "s" };
    for (ctrl_names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return .ctrl;
    for (alt_names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return .alt;
    for (shift_names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return .shift;
    return null;
}

fn applyModifier(spec: *Spec, m: Modifier) void {
    switch (m) {
        .ctrl => spec.ctrl = true,
        .alt => spec.alt = true,
        .shift => spec.shift = true,
    }
}

/// A key name without modifiers: a named key, or a single printable
/// codepoint (any script). Null for anything else.
fn baseKey(name: []const u8) ?Spec {
    for (named_keys) |n| if (std.ascii.eqlIgnoreCase(name, n.name)) return .{ .key = n.key, .codepoint = n.codepoint };
    if (name.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(name[0]) catch return null;
    if (len != name.len) return null;
    const cp = std.unicode.utf8Decode(name) catch return null;
    if (cp < 0x20 or cp == 0x7f) return null;
    return .{ .key = .char, .codepoint = cp };
}

/// Parse one key spec. Null when the name is unknown or a chord names a
/// modifier it does not recognize.
pub fn parse(raw: []const u8) ?Spec {
    const spec = std.mem.trim(u8, raw, " \t\r\n");
    if (spec.len == 0) return null;

    // Legacy tmux/emacs style: `C-c`, `M-x`, `S-tab`, also `C-M-x`.
    if (spec.len > 2 and spec[1] == '-' and modifierFromName(spec[0..1]) != null) {
        var out = parse(spec[2..]) orelse return null;
        applyModifier(&out, modifierFromName(spec[0..1]).?);
        return out;
    }

    // `+`-joined chord. A trailing `+` (as in `ctrl++`) or a lone `+` is the
    // plus key itself.
    var mods: struct { ctrl: bool = false, alt: bool = false, shift: bool = false } = .{};
    var rest = spec;
    while (std.mem.indexOfScalar(u8, rest, '+')) |i| {
        if (i == 0) {
            // Leading `+`: only valid as the whole remaining key (`+`).
            if (rest.len != 1) return null;
            break;
        }
        const m = modifierFromName(rest[0..i]) orelse return null;
        switch (m) {
            .ctrl => mods.ctrl = true,
            .alt => mods.alt = true,
            .shift => mods.shift = true,
        }
        rest = rest[i + 1 ..];
        if (rest.len == 0) {
            rest = "+";
            break;
        }
    }
    var out = baseKey(rest) orelse return null;
    out.ctrl = mods.ctrl;
    out.alt = mods.alt;
    out.shift = mods.shift;
    return out;
}

const t = std.testing;

test "parse: named keys, aliases, and case-insensitivity" {
    try t.expectEqual(Key.enter, parse("enter").?.key);
    try t.expectEqual(Key.enter, parse("Enter").?.key);
    try t.expectEqual(Key.enter, parse("return").?.key);
    try t.expectEqual(Key.escape, parse("esc").?.key);
    try t.expectEqual(Key.escape, parse("escape").?.key);
    try t.expectEqual(Key.backspace, parse("BSpace").?.key);
    try t.expectEqual(Key.page_down, parse("pgdn").?.key);
    try t.expectEqual(Key.up, parse("up").?.key);
    try t.expectEqual(Key.f12, parse("F12").?.key);
    try t.expect(parse("f13") == null);
    try t.expect(parse("") == null);
    try t.expect(parse("bogus") == null);
}

test "parse: printable characters and named punctuation" {
    const a = parse("a").?;
    try t.expectEqual(Key.char, a.key);
    try t.expectEqual(@as(u21, 'a'), a.codepoint);
    try t.expectEqual(@as(u21, '/'), parse("/").?.codepoint);
    try t.expectEqual(@as(u21, '你'), parse("你").?.codepoint);
    try t.expectEqual(@as(u21, '-'), parse("-").?.codepoint);
    try t.expectEqual(@as(u21, '-'), parse("minus").?.codepoint);
    try t.expectEqual(@as(u21, '+'), parse("+").?.codepoint);
    try t.expectEqual(@as(u21, '+'), parse("plus").?.codepoint);
    try t.expectEqual(@as(u21, '`'), parse("backtick").?.codepoint);
    // Two characters are not one key, and control bytes are not printable.
    try t.expect(parse("ab") == null);
    try t.expect(parse("\x03") == null);
}

test "parse: modifier chords, aliases, and legacy C-/M- forms" {
    const c = parse("ctrl+c").?;
    try t.expect(c.ctrl and !c.alt and !c.shift);
    try t.expectEqual(@as(u21, 'c'), c.codepoint);
    try t.expect(parse("control+j").?.ctrl);
    try t.expect(parse("alt+x").?.alt);
    try t.expect(parse("option+x").?.alt);
    try t.expect(parse("meta+x").?.alt);
    const st = parse("shift+tab").?;
    try t.expect(st.shift);
    try t.expectEqual(Key.tab, st.key);
    const cs = parse("ctrl+shift+s").?;
    try t.expect(cs.ctrl and cs.shift and !cs.alt);
    try t.expect(parse("C-c").?.ctrl);
    try t.expect(parse("c-c").?.ctrl);
    try t.expect(parse("M-x").?.alt);
    const cmx = parse("C-M-x").?;
    try t.expect(cmx.ctrl and cmx.alt);
    try t.expectEqual(@as(u21, 'x'), cmx.codepoint);
    try t.expect(parse("S-Tab").?.shift);
    // `ctrl++` is ctrl + the plus key; `ctrl+-` is ctrl + minus.
    const cp = parse("ctrl++").?;
    try t.expect(cp.ctrl);
    try t.expectEqual(@as(u21, '+'), cp.codepoint);
    try t.expectEqual(@as(u21, '-'), parse("ctrl+-").?.codepoint);
    // Unknown modifier or missing key.
    try t.expect(parse("hyper+x") == null);
    try t.expect(parse("ctrl+") != null); // = ctrl + plus
    try t.expect(parse("+x") == null);
    try t.expect(parse("ctrl+bogus") == null);
}

test "parse trims surrounding whitespace" {
    try t.expectEqual(Key.escape, parse(" esc\n").?.key);
}
