const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const input_key = @import("input/key.zig");
const platform_input = @import("platform/input_events.zig");

/// Encode a "special" terminal key (Enter, Tab, Backspace, …) using the Kitty
/// keyboard protocol when the running application has enabled it.
///
/// Full-screen TUIs such as Claude Code and Codex push Kitty keyboard flags so
/// they can tell a modified press apart from a bare one. With the protocol
/// active this returns the disambiguated CSI-u sequence — e.g. Shift+Enter
/// becomes "\x1b[13;2u" instead of the legacy "\r" — letting those apps treat
/// it as "insert newline" rather than "submit" (issue #302).
///
/// Returns the encoded bytes (written into `buf`) when the protocol is active,
/// or null when it is disabled, in which case the caller falls back to the
/// historical legacy byte(s) so plain shells and non-Kitty apps are completely
/// unaffected. A bare Enter still encodes as "\r" even while the protocol is on.
pub fn kittyKeyEncode(
    opts: ghostty_vt.input.KeyEncodeOptions,
    key: ghostty_vt.input.Key,
    mods: ghostty_vt.input.KeyMods,
    buf: []u8,
) ?[]const u8 {
    // Diverge from legacy encoding only when the app opted into the Kitty
    // keyboard protocol; otherwise signal the caller to keep existing behavior.
    if (opts.kitty_flags.int() == 0) return null;

    return terminalKeyEncode(opts, key, mods, buf);
}

/// Encode a Ctrl+Shift letter/digit chord using the Kitty keyboard protocol
/// when the running application enabled it (e.g. pi-stash's ctrl+shift+s/r).
/// Ghostty's kitty encoder emits CSI-u with the unshifted codepoint and all
/// original mods (Ctrl+Shift+S -> "\x1b[115;6u"); wispterm's legacy path
/// previously dropped shifted Ctrl+letter/digit chords. Returns null when the
/// protocol is off so callers keep the historical behavior.
pub fn asciiKeyCode(key_code: platform_input.KeyCode) ?u8 {
    return switch (key_code) {
        0x30...0x39 => @intCast(key_code),
        0x41...0x5A => @intCast(key_code + 0x20),
        0xBA => ';', // VK_OEM_1 / SDL semicolon
        0xBB => '=', // VK_OEM_PLUS / SDL equals
        0xBC => ',', // VK_OEM_COMMA
        0xBD => '-', // VK_OEM_MINUS
        0xBE => '.', // VK_OEM_PERIOD
        0xBF => '/', // VK_OEM_2
        0xC0 => '`', // VK_OEM_3
        0xDB => '[', // VK_OEM_4
        0xDC => '\\', // VK_OEM_5
        0xDD => ']', // VK_OEM_6
        0xDE => '\'', // VK_OEM_7
        else => null,
    };
}

/// Encode a Ctrl+Shift ASCII chord using the Kitty keyboard protocol.
pub fn kittyCtrlShiftKeyEncode(
    opts: ghostty_vt.input.KeyEncodeOptions,
    key_code: platform_input.KeyCode,
    mods: ghostty_vt.input.KeyMods,
    buf: []u8,
) ?[]const u8 {
    if (!mods.ctrl or !mods.shift) return null;
    if (opts.kitty_flags.int() == 0) return null;
    const codepoint: u21 = @intCast(asciiKeyCode(key_code) orelse return null);
    return std.fmt.bufPrint(buf, "\x1b[{d};6u", .{codepoint}) catch null;
}

/// Encode a plain Alt+ASCII chord for Kitty-aware applications.
pub fn kittyAltKeyEncode(
    opts: ghostty_vt.input.KeyEncodeOptions,
    key_code: platform_input.KeyCode,
    buf: []u8,
) ?[]const u8 {
    if (opts.kitty_flags.int() == 0) return null;
    const codepoint: u21 = @intCast(asciiKeyCode(key_code) orelse return null);
    return std.fmt.bufPrint(buf, "\x1b[{d};3u", .{codepoint}) catch null;
}

pub fn terminalKeyEncode(
    opts: ghostty_vt.input.KeyEncodeOptions,
    key: ghostty_vt.input.Key,
    mods: ghostty_vt.input.KeyMods,
    buf: []u8,
) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    ghostty_vt.input.encodeKey(&writer, .{
        .action = .press,
        .key = key,
        .mods = mods,
    }, opts) catch return null;
    const encoded = writer.buffered();
    return if (encoded.len == 0) null else encoded;
}

pub fn terminalFunctionKeyEncode(
    opts: ghostty_vt.input.KeyEncodeOptions,
    key_code: platform_input.KeyCode,
    mods: ghostty_vt.input.KeyMods,
    buf: []u8,
) ?[]const u8 {
    const key: ghostty_vt.input.Key = switch (key_code) {
        platform_input.key_f1 => .f1,
        platform_input.key_f2 => .f2,
        platform_input.key_f3 => .f3,
        platform_input.key_f4 => .f4,
        platform_input.key_f5 => .f5,
        platform_input.key_f6 => .f6,
        platform_input.key_f7 => .f7,
        platform_input.key_f8 => .f8,
        platform_input.key_f9 => .f9,
        platform_input.key_f10 => .f10,
        platform_input.key_f11 => .f11,
        platform_input.key_f12 => .f12,
        else => return null,
    };
    return terminalKeyEncode(opts, key, mods, buf);
}

pub fn terminalNavigationKeyEncode(
    opts: ghostty_vt.input.KeyEncodeOptions,
    key_code: platform_input.KeyCode,
    mods: ghostty_vt.input.KeyMods,
    buf: []u8,
) ?[]const u8 {
    const key: ghostty_vt.input.Key = switch (key_code) {
        platform_input.key_escape => .escape,
        platform_input.key_home => .home,
        platform_input.key_end => .end,
        platform_input.key_page_up => .page_up,
        platform_input.key_page_down => .page_down,
        platform_input.key_insert => .insert,
        platform_input.key_delete => .delete,
        else => return null,
    };
    return terminalKeyEncode(opts, key, mods, buf);
}

pub fn terminalAsciiKeyEncode(
    opts: ghostty_vt.input.KeyEncodeOptions,
    key_code: platform_input.KeyCode,
    mods: ghostty_vt.input.KeyMods,
    buf: []u8,
) ?[]const u8 {
    if (mods.ctrl and mods.shift) return kittyCtrlShiftKeyEncode(opts, key_code, mods, buf);
    if (mods.alt and !mods.ctrl and !mods.shift and !mods.super) return kittyAltKeyEncode(opts, key_code, buf);

    const key: ghostty_vt.input.Key = switch (asciiKeyCode(key_code) orelse return null) {
        '0' => .digit_0,
        '1' => .digit_1,
        '2' => .digit_2,
        '3' => .digit_3,
        '4' => .digit_4,
        '5' => .digit_5,
        '6' => .digit_6,
        '7' => .digit_7,
        '8' => .digit_8,
        '9' => .digit_9,
        'a' => .key_a,
        'b' => .key_b,
        'c' => .key_c,
        'd' => .key_d,
        'e' => .key_e,
        'f' => .key_f,
        'g' => .key_g,
        'h' => .key_h,
        'i' => .key_i,
        'j' => .key_j,
        'k' => .key_k,
        'l' => .key_l,
        'm' => .key_m,
        'n' => .key_n,
        'o' => .key_o,
        'p' => .key_p,
        'q' => .key_q,
        'r' => .key_r,
        's' => .key_s,
        't' => .key_t,
        'u' => .key_u,
        'v' => .key_v,
        'w' => .key_w,
        'x' => .key_x,
        'y' => .key_y,
        'z' => .key_z,
        ';' => .semicolon,
        '=' => .equal,
        ',' => .comma,
        '-' => .minus,
        '.' => .period,
        '/' => .slash,
        '`' => .backquote,
        '[' => .bracket_left,
        '\\' => .backslash,
        ']' => .bracket_right,
        '\'' => .quote,
        else => return null,
    };
    return terminalKeyEncode(opts, key, mods, buf);
}

pub fn terminalArrowSequence(ev: input_key.KeyEvent, cursor_keys: bool) ?[]const u8 {
    const modifier: u8 = 1 +
        @as(u8, if (ev.shift) 1 else 0) +
        @as(u8, if (ev.alt) 2 else 0) +
        @as(u8, if (ev.ctrl) 4 else 0);

    inline for (terminal_arrow_sequences) |entry| {
        if (ev.key == entry.key) {
            return if (modifier == 1) cursorModeSequence(entry, cursor_keys) else entry.modified[modifier - 2];
        }
    }
    return null;
}

fn cursorModeSequence(entry: TerminalArrowSequence, cursor_keys: bool) []const u8 {
    return if (cursor_keys) entry.application else entry.normal;
}

const TerminalArrowSequence = struct {
    key: input_key.Key,
    normal: []const u8,
    application: []const u8,
    modified: [7][]const u8,
};

const terminal_arrow_sequences = [_]TerminalArrowSequence{
    .{ .key = .arrow_up, .normal = "\x1b[A", .application = "\x1bOA", .modified = .{ "\x1b[1;2A", "\x1b[1;3A", "\x1b[1;4A", "\x1b[1;5A", "\x1b[1;6A", "\x1b[1;7A", "\x1b[1;8A" } },
    .{ .key = .arrow_down, .normal = "\x1b[B", .application = "\x1bOB", .modified = .{ "\x1b[1;2B", "\x1b[1;3B", "\x1b[1;4B", "\x1b[1;5B", "\x1b[1;6B", "\x1b[1;7B", "\x1b[1;8B" } },
    .{ .key = .arrow_right, .normal = "\x1b[C", .application = "\x1bOC", .modified = .{ "\x1b[1;2C", "\x1b[1;3C", "\x1b[1;4C", "\x1b[1;5C", "\x1b[1;6C", "\x1b[1;7C", "\x1b[1;8C" } },
    .{ .key = .arrow_left, .normal = "\x1b[D", .application = "\x1bOD", .modified = .{ "\x1b[1;2D", "\x1b[1;3D", "\x1b[1;4D", "\x1b[1;5D", "\x1b[1;6D", "\x1b[1;7D", "\x1b[1;8D" } },
};

test "terminal navigation encoding preserves modifiers" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[1;5H", terminalNavigationKeyEncode(.{}, platform_input.key_home, .{ .ctrl = true }, &buf).?);
    try std.testing.expectEqualStrings("\x1b[2;2~", terminalNavigationKeyEncode(.{}, platform_input.key_insert, .{ .shift = true }, &buf).?);
    try std.testing.expectEqualStrings("\x1b[3;3~", terminalNavigationKeyEncode(.{}, platform_input.key_delete, .{ .alt = true }, &buf).?);
    try std.testing.expectEqualStrings("\x1b\x1b", terminalNavigationKeyEncode(.{}, platform_input.key_escape, .{ .alt = true }, &buf).?);
}

test "terminal ASCII encoding covers modified letters and digits" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[115;6u", terminalAsciiKeyEncode(kitty_disambiguate, 0x53, .{ .ctrl = true, .shift = true }, &buf).?);
    try std.testing.expectEqualStrings("\x1b[115;3u", terminalAsciiKeyEncode(kitty_disambiguate, 0x53, .{ .alt = true }, &buf).?);
    try std.testing.expect(terminalAsciiKeyEncode(.{}, 0x53, .{ .ctrl = true, .shift = true }, &buf) == null);
}

test "terminal arrow sequence handles modifiers" {
    try std.testing.expectEqualStrings(
        "\x1b[A",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_up }, false).?,
    );
    try std.testing.expectEqualStrings(
        "\x1bOA",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_up }, true).?,
    );
    try std.testing.expectEqualStrings(
        "\x1bOD",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_left }, true).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;3D",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_left, .alt = true }, true).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;5C",
        terminalArrowSequence(.{ .key = input_key.Key.arrow_right, .ctrl = true }, false).?,
    );
    try std.testing.expect(terminalArrowSequence(.{ .key = input_key.Key.key_a, .alt = true }, false) == null);
}

const kitty_disambiguate: ghostty_vt.input.KeyEncodeOptions = .{
    .kitty_flags = .{ .disambiguate = true },
};

test "kittyCtrlShiftKeyEncode emits CSI-u for letters and digits when active" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[115;6u",
        kittyCtrlShiftKeyEncode(kitty_disambiguate, 0x53, .{ .ctrl = true, .shift = true }, &buf).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[48;6u",
        kittyCtrlShiftKeyEncode(kitty_disambiguate, 0x30, .{ .ctrl = true, .shift = true }, &buf).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[49;6u",
        kittyCtrlShiftKeyEncode(kitty_disambiguate, 0x31, .{ .ctrl = true, .shift = true }, &buf).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[57;6u",
        kittyCtrlShiftKeyEncode(kitty_disambiguate, 0x39, .{ .ctrl = true, .shift = true }, &buf).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[59;6u",
        kittyCtrlShiftKeyEncode(kitty_disambiguate, 0xBA, .{ .ctrl = true, .shift = true }, &buf).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[39;6u",
        kittyCtrlShiftKeyEncode(kitty_disambiguate, 0xDE, .{ .ctrl = true, .shift = true }, &buf).?,
    );
}

test "kittyCtrlShiftKeyEncode returns null when protocol disabled, mods missing, or key is unsupported" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(kittyCtrlShiftKeyEncode(.{}, 0x53, .{ .ctrl = true, .shift = true }, &buf) == null);
    try std.testing.expect(kittyCtrlShiftKeyEncode(kitty_disambiguate, 0x53, .{ .ctrl = true }, &buf) == null);
    try std.testing.expect(kittyCtrlShiftKeyEncode(kitty_disambiguate, 0x53, .{ .shift = true }, &buf) == null);
    try std.testing.expect(kittyCtrlShiftKeyEncode(kitty_disambiguate, 0x2F, .{ .ctrl = true, .shift = true }, &buf) == null);
    try std.testing.expect(kittyCtrlShiftKeyEncode(kitty_disambiguate, platform_input.key_enter, .{ .ctrl = true, .shift = true }, &buf) == null);
}

test "kittyKeyEncode returns null when the Kitty keyboard protocol is disabled" {
    var buf: [64]u8 = undefined;
    // Protocol off (default options): caller must fall back to legacy bytes,
    // so Shift+Enter stays a bare Enter for plain shells.
    try std.testing.expect(kittyKeyEncode(.{}, .enter, .{ .shift = true }, &buf) == null);
}

test "kittyKeyEncode encodes Shift+Enter as CSI u when the protocol is active" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[13;2u",
        kittyKeyEncode(kitty_disambiguate, .enter, .{ .shift = true }, &buf).?,
    );
}

test "kittyKeyEncode keeps a bare Enter as \\r while the protocol is active" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\r",
        kittyKeyEncode(kitty_disambiguate, .enter, .{}, &buf).?,
    );
}

test "kittyKeyEncode disambiguates Shift+Tab and Shift+Backspace when active" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[9;2u",
        kittyKeyEncode(kitty_disambiguate, .tab, .{ .shift = true }, &buf).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[127;2u",
        kittyKeyEncode(kitty_disambiguate, .backspace, .{ .shift = true }, &buf).?,
    );
}

test "terminalFunctionKeyEncode emits xterm F-key sequences" {
    const cases = [_]struct { key: platform_input.KeyCode, expected: []const u8 }{
        .{ .key = platform_input.key_f1, .expected = "\x1bOP" },
        .{ .key = platform_input.key_f2, .expected = "\x1bOQ" },
        .{ .key = platform_input.key_f3, .expected = "\x1bOR" },
        .{ .key = platform_input.key_f4, .expected = "\x1bOS" },
        .{ .key = platform_input.key_f5, .expected = "\x1b[15~" },
        .{ .key = platform_input.key_f6, .expected = "\x1b[17~" },
        .{ .key = platform_input.key_f7, .expected = "\x1b[18~" },
        .{ .key = platform_input.key_f8, .expected = "\x1b[19~" },
        .{ .key = platform_input.key_f9, .expected = "\x1b[20~" },
        .{ .key = platform_input.key_f10, .expected = "\x1b[21~" },
        .{ .key = platform_input.key_f11, .expected = "\x1b[23~" },
        .{ .key = platform_input.key_f12, .expected = "\x1b[24~" },
    };
    var buf: [128]u8 = undefined;
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, terminalFunctionKeyEncode(.{}, case.key, .{}, &buf).?);
    }
    try std.testing.expectEqualStrings(
        "\x1b[1;5Q",
        terminalFunctionKeyEncode(.{}, platform_input.key_f2, .{ .ctrl = true }, &buf).?,
    );
    try std.testing.expect(terminalFunctionKeyEncode(.{}, platform_input.key_enter, .{}, &buf) == null);
}
