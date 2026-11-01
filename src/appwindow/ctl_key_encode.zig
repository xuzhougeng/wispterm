//! `wisptermctl send-keys`: turn parsed key specs (`ctl/key_names.zig`) into
//! the bytes a real keypress in that pane would produce.
//!
//! Encoding goes through Ghostty's key encoder (`ghostty_vt.input.encodeKey`)
//! with options read from the surface's live terminal state, exactly as
//! `input.zig` does for the keyboard: the Kitty keyboard protocol flags a
//! full-screen agent pushed, DECCKM application cursor keys, DECBKM, and
//! modifyOtherKeys all apply. So `shift+enter` reaches Claude Code as the
//! CSI-u "insert newline" it expects, and `up` reaches a TUI in whichever
//! form it asked for — not a fixed byte table.
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const key_names = @import("../ctl/key_names.zig");

pub const Options = ghostty_vt.input.KeyEncodeOptions;
const Key = ghostty_vt.input.Key;

/// Encoder options for a surface's terminal. The caller holds the lock that
/// guards `terminal` (the IO thread mutates its modes).
pub fn optionsForTerminal(terminal: *const ghostty_vt.Terminal) Options {
    var opts = Options.fromTerminal(terminal);
    // A scripted `alt+x` always means Alt: there is no physical Option key
    // whose macOS unicode translation we would be preserving.
    opts.macos_option_as_alt = .true;
    return opts;
}

/// Ghostty's logical key for a printable character, so chords on letters,
/// digits and US punctuation encode like the physical key (ctrl+c → 0x03,
/// and CSI-u with the unshifted codepoint under Kitty). Anything else is
/// `.unidentified` and travels as its UTF-8 text.
fn charKey(cp: u21) Key {
    return switch (cp) {
        'a'...'z' => @enumFromInt(@intFromEnum(Key.key_a) + (cp - 'a')),
        'A'...'Z' => @enumFromInt(@intFromEnum(Key.key_a) + (cp - 'A')),
        '0'...'9' => @enumFromInt(@intFromEnum(Key.digit_0) + (cp - '0')),
        ' ' => .space,
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
        else => .unidentified,
    };
}

fn namedKey(key: key_names.Key) Key {
    return switch (key) {
        .char => unreachable,
        .enter => .enter,
        .tab => .tab,
        .escape => .escape,
        .backspace => .backspace,
        .space => .space,
        .delete => .delete,
        .insert => .insert,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .up => .arrow_up,
        .down => .arrow_down,
        .left => .arrow_left,
        .right => .arrow_right,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
    };
}

/// Encode one spec into `buf`. Null when the encoder produced nothing (a
/// chord the active encoding cannot express, e.g. ctrl+shift+s without the
/// Kitty protocol) — the caller reports it instead of sending a bare key.
pub fn encodeSpec(opts: Options, spec: key_names.Spec, buf: []u8) ?[]const u8 {
    var utf8_buf: [4]u8 = undefined;
    var event: ghostty_vt.input.KeyEvent = .{
        .mods = .{ .ctrl = spec.ctrl, .alt = spec.alt, .shift = spec.shift },
    };
    switch (spec.key) {
        .char => {
            var cp = spec.codepoint;
            event.key = charKey(cp);
            // The unshifted codepoint is the lowercase letter; a shifted
            // letter chord types its uppercase form.
            if (cp >= 'A' and cp <= 'Z') {
                event.unshifted_codepoint = cp + ('a' - 'A');
            } else {
                event.unshifted_codepoint = cp;
                if (spec.shift and cp >= 'a' and cp <= 'z') cp -= 'a' - 'A';
            }
            // Like the keyboard, a ctrl chord carries no text: the encoder
            // derives the C0 byte (or CSI-u) from the logical key.
            if (!spec.ctrl) {
                const n = std.unicode.utf8Encode(cp, &utf8_buf) catch return null;
                event.utf8 = utf8_buf[0..n];
            }
        },
        .space => {
            event.key = .space;
            event.unshifted_codepoint = ' ';
            if (!spec.ctrl) event.utf8 = " ";
        },
        else => event.key = namedKey(spec.key),
    }
    var writer: std.Io.Writer = .fixed(buf);
    ghostty_vt.input.encodeKey(&writer, event, opts) catch return null;
    const out = writer.buffered();
    return if (out.len == 0) null else out;
}

pub const EncodeError = error{ UnencodableKey, OutOfMemory };

/// Encode every spec in order, appending to `out`. On `UnencodableKey`
/// nothing should be sent: the caller discards `out`.
pub fn encodeAll(allocator: std.mem.Allocator, opts: Options, specs: []const key_names.Spec, out: *std.ArrayListUnmanaged(u8)) EncodeError!void {
    var buf: [64]u8 = undefined;
    for (specs) |spec| {
        const bytes = encodeSpec(opts, spec, &buf) orelse return error.UnencodableKey;
        try out.appendSlice(allocator, bytes);
    }
}

// ---------------------------------------------------------------------------
// Tests (link ghostty-vt: full suite only)
// ---------------------------------------------------------------------------
const t = std.testing;

fn enc(opts: Options, name: []const u8) ?[]const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    return encodeSpec(opts, key_names.parse(name).?, &S.buf);
}

// Test fixtures carry the same `macos_option_as_alt` that
// `optionsForTerminal` sets: without it Ghostty's encoder (correctly) treats
// Option on a macOS host as a unicode-composition key, not Alt.
const legacy: Options = .{ .alt_esc_prefix = true, .macos_option_as_alt = .true };

test "legacy encoding matches what the keyboard sends" {
    try t.expectEqualStrings("\r", enc(legacy, "enter").?);
    try t.expectEqualStrings("\t", enc(legacy, "tab").?);
    try t.expectEqualStrings("\x1b", enc(legacy, "esc").?);
    try t.expectEqualStrings("\x7f", enc(legacy, "backspace").?);
    try t.expectEqualStrings(" ", enc(legacy, "space").?);
    try t.expectEqualStrings("\x1b[3~", enc(legacy, "delete").?);
    try t.expectEqualStrings("\x1b[2~", enc(legacy, "insert").?);
    try t.expectEqualStrings("\x1b[H", enc(legacy, "home").?);
    try t.expectEqualStrings("\x1b[F", enc(legacy, "end").?);
    try t.expectEqualStrings("\x1b[5~", enc(legacy, "pageup").?);
    try t.expectEqualStrings("\x1b[6~", enc(legacy, "pagedown").?);
    try t.expectEqualStrings("\x1b[A", enc(legacy, "up").?);
    try t.expectEqualStrings("\x1b[D", enc(legacy, "left").?);
    try t.expectEqualStrings("\x1bOP", enc(legacy, "f1").?);
    try t.expectEqualStrings("\x1b[15~", enc(legacy, "f5").?);
    try t.expectEqualStrings("\x1b[24~", enc(legacy, "f12").?);
    try t.expectEqualStrings("a", enc(legacy, "a").?);
    try t.expectEqualStrings("/", enc(legacy, "/").?);
    try t.expectEqualStrings("-", enc(legacy, "minus").?);
    try t.expectEqualStrings("你", enc(legacy, "你").?);
}

test "legacy chords: ctrl C0 bytes, alt ESC prefix, shift+tab, modified cursor keys" {
    try t.expectEqualStrings("\x03", enc(legacy, "ctrl+c").?);
    try t.expectEqualStrings("\x03", enc(legacy, "C-c").?);
    try t.expectEqualStrings("\x01", enc(legacy, "ctrl+a").?);
    try t.expectEqualStrings("\x00", enc(legacy, "ctrl+space").?);
    try t.expectEqualStrings("\x1bx", enc(legacy, "alt+x").?);
    try t.expectEqualStrings("\x1b\x03", enc(legacy, "ctrl+alt+c").?);
    try t.expectEqualStrings("\x1b[Z", enc(legacy, "shift+tab").?);
    try t.expectEqualStrings("A", enc(legacy, "shift+a").?);
    try t.expectEqualStrings("\x1b[1;5A", enc(legacy, "ctrl+up").?);
    try t.expectEqualStrings("\x1b[1;2C", enc(legacy, "shift+right").?);
    try t.expectEqualStrings("\x1b[1;5H", enc(legacy, "ctrl+home").?);
    try t.expectEqualStrings("\x1b[3;3~", enc(legacy, "alt+delete").?);
    // Ghostty gives a modified Enter the xterm CSI 27 form even without the
    // Kitty protocol, like a real shift+Enter keypress in WispTerm.
    try t.expectEqualStrings("\x1b[27;2;13~", enc(legacy, "shift+enter").?);
}

test "application cursor keys (DECCKM) switch arrows to SS3" {
    const app: Options = .{ .alt_esc_prefix = true, .cursor_key_application = true, .macos_option_as_alt = .true };
    try t.expectEqualStrings("\x1bOA", enc(app, "up").?);
    try t.expectEqualStrings("\x1bOB", enc(app, "down").?);
    try t.expectEqualStrings("\x1b[1;5A", enc(app, "ctrl+up").?);
    try t.expectEqualStrings("\x1b[A", enc(legacy, "up").?);
}

test "Kitty keyboard protocol: disambiguated CSI-u like a keypress in Claude Code" {
    const kitty: Options = .{ .alt_esc_prefix = true, .kitty_flags = .{ .disambiguate = true }, .macos_option_as_alt = .true };
    try t.expectEqualStrings("\x1b[13;2u", enc(kitty, "shift+enter").?);
    try t.expectEqualStrings("\r", enc(kitty, "enter").?);
    try t.expectEqualStrings("\x1b[27u", enc(kitty, "esc").?);
    try t.expectEqualStrings("\x1b[99;5u", enc(kitty, "ctrl+c").?);
    try t.expectEqualStrings("\x1b[115;6u", enc(kitty, "ctrl+shift+s").?);
    try t.expectEqualStrings("\x1b[120;3u", enc(kitty, "alt+x").?);
    try t.expectEqualStrings("\x1b[1;5A", enc(kitty, "ctrl+up").?);
    try t.expectEqualStrings("a", enc(kitty, "a").?);
}

test "encodeAll concatenates in order and rejects an unencodable chord without partial output" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(t.allocator);
    const specs = [_]key_names.Spec{ key_names.parse("esc").?, key_names.parse("ctrl+c").?, key_names.parse("enter").? };
    try encodeAll(t.allocator, legacy, &specs, &out);
    try t.expectEqualStrings("\x1b\x03\r", out.items);

    // ctrl+shift+s has no legacy encoding (the keyboard drops it too).
    try t.expect(enc(legacy, "ctrl+shift+s") == null);
    var out2: std.ArrayListUnmanaged(u8) = .empty;
    defer out2.deinit(t.allocator);
    const bad = [_]key_names.Spec{ key_names.parse("esc").?, key_names.parse("ctrl+shift+s").? };
    try t.expectError(error.UnencodableKey, encodeAll(t.allocator, legacy, &bad, &out2));
}
