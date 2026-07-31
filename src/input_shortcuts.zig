const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const input_key = @import("input/key.zig");

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

    var writer: std.Io.Writer = .fixed(buf);
    ghostty_vt.input.encodeKey(&writer, .{
        .action = .press,
        .key = key,
        .mods = mods,
    }, opts) catch return null;

    const encoded = writer.buffered();
    return if (encoded.len == 0) null else encoded;
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
