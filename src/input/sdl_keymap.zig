//! Pure SDL3 scancode/modifier → neutral input mapping. Operates on SDL3's
//! stable ABI integer values (see SDL_scancode.h / SDL_keycode.h KMOD_*), so it
//! has no SDL dependency and runs in the fast suite. The SDL shell
//! (`apprt/sdl.zig`) passes `@intFromEnum(event.key.scancode)` and the keymod
//! bitmask here.
const std = @import("std");
const ev = @import("../platform/input_events.zig");

pub const Mods = struct { ctrl: bool, shift: bool, alt: bool, super: bool };

/// SDL3 stable scancode values → neutral KeyCode. Returns null for keys whose
/// text should arrive via SDL_EVENT_TEXT_INPUT (printable characters).
pub fn keyCodeFromScancode(scancode: u32) ?ev.KeyCode {
    return switch (scancode) {
        42 => ev.key_backspace, // SDL_SCANCODE_BACKSPACE
        43 => ev.key_tab, // TAB
        44 => ev.key_space, // SPACE
        40 => ev.key_enter, // RETURN
        41 => ev.key_escape, // ESCAPE
        58 => ev.key_f1, // F1
        59 => ev.key_f2, // F2
        60 => ev.key_f3, // F3
        61 => ev.key_f4, // F4
        62 => ev.key_f5, // F5
        63 => ev.key_f6, // F6
        64 => ev.key_f7, // F7
        65 => ev.key_f8, // F8
        66 => ev.key_f9, // F9
        67 => ev.key_f10, // F10
        68 => ev.key_f11, // F11
        69 => ev.key_f12, // F12
        73 => ev.key_insert, // INSERT
        74 => ev.key_home, // HOME
        75 => ev.key_page_up, // PAGEUP
        76 => ev.key_delete, // DELETE
        77 => ev.key_end, // END
        78 => ev.key_page_down, // PAGEDOWN
        79 => ev.key_right, // RIGHT
        80 => ev.key_left, // LEFT
        81 => ev.key_down, // DOWN
        82 => ev.key_up, // UP
        224 => ev.key_left_control, // LCTRL
        225 => ev.key_left_shift, // LSHIFT
        226 => ev.key_left_alt, // LALT
        227 => null, // LGUI: super flag only, no key code constant
        228 => ev.key_right_control, // RCTRL
        229 => ev.key_right_shift, // RSHIFT
        230 => ev.key_right_alt, // RALT
        else => null,
    };
}

/// SDL3 keycode → neutral KeyCode for alphanumeric and punctuation keys.
/// Returns uppercase letters ('A'-'Z'), digits ('0'-'9'), and common punctuation.
/// Also accepts Ctrl-letter control codes (0x01-0x1A) that some X11 paths emit.
pub fn keyCodeFromSdlKeycode(keycode: u32) ?ev.KeyCode {
    // Some Linux/X11 paths report Ctrl+V as 0x16 rather than 'v'.
    if (keycode >= 1 and keycode <= 26) return 'A' + (keycode - 1);
    if (keycode >= 'a' and keycode <= 'z') return keycode - ('a' - 'A');
    if ((keycode >= 'A' and keycode <= 'Z') or (keycode >= '0' and keycode <= '9')) return keycode;
    return switch (keycode) {
        '`' => 0xC0, // backquote / Key.backquote
        ',' => 0xBC, // comma / Key.comma
        '+', '=' => 0xBB, // plus/equal / Key.plus
        '-' => 0xBD, // minus / Key.minus
        '[' => 0xDB, // bracket_left
        ']' => 0xDD, // bracket_right
        else => null,
    };
}

/// SDL3 scancode → shortcut KeyCode for letters, digits, and punctuation used
/// by default keybinds. Used when the logical keycode is 0 / unmapped.
pub fn keyCodeFromShortcutScancode(scancode: u32) ?ev.KeyCode {
    return switch (scancode) {
        4...29 => 'A' + (scancode - 4), // SDL_SCANCODE_A..Z
        30...38 => '1' + (scancode - 30), // SDL_SCANCODE_1..9
        39 => '0', // SDL_SCANCODE_0
        45 => 0xBD, // SDL_SCANCODE_MINUS
        46 => 0xBB, // SDL_SCANCODE_EQUALS (Key.plus)
        47 => 0xDB, // SDL_SCANCODE_LEFTBRACKET
        48 => 0xDD, // SDL_SCANCODE_RIGHTBRACKET
        53 => 0xC0, // SDL_SCANCODE_GRAVE
        54 => 0xBC, // SDL_SCANCODE_COMMA
        else => null,
    };
}

/// Layout-aware shortcut key first (keycode), then physical scancode fallback.
pub fn shortcutKeyCode(scancode: u32, keycode: u32) ?ev.KeyCode {
    return keyCodeFromSdlKeycode(keycode) orelse keyCodeFromShortcutScancode(scancode);
}

/// SDL3 keymod bitmask (KMOD_*) → neutral modifier flags.
pub fn modifiers(mod: u16) Mods {
    return .{
        .ctrl = (mod & (0x0040 | 0x0080)) != 0, // LCTRL|RCTRL
        .shift = (mod & (0x0001 | 0x0002)) != 0, // LSHIFT|RSHIFT
        .alt = (mod & (0x0100 | 0x0200)) != 0, // LALT|RALT
        .super = (mod & (0x0400 | 0x0800)) != 0, // LGUI|RGUI
    };
}

test "special scancodes map to neutral key codes" {
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_left), keyCodeFromScancode(80)); // SDL_SCANCODE_LEFT
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_up), keyCodeFromScancode(82)); // SDL_SCANCODE_UP
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_enter), keyCodeFromScancode(40)); // SDL_SCANCODE_RETURN
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_escape), keyCodeFromScancode(41)); // SDL_SCANCODE_ESCAPE
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_delete), keyCodeFromScancode(76)); // SDL_SCANCODE_DELETE
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_f1), keyCodeFromScancode(58)); // SDL_SCANCODE_F1
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_f2), keyCodeFromScancode(59)); // SDL_SCANCODE_F2
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_f12), keyCodeFromScancode(69)); // SDL_SCANCODE_F12
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_left_shift), keyCodeFromScancode(225)); // SDL_SCANCODE_LSHIFT
    // A printable key has no special mapping (text arrives via TEXT_INPUT).
    try std.testing.expectEqual(@as(?ev.KeyCode, null), keyCodeFromScancode(4)); // SDL_SCANCODE_A
}

test "modifier bitmask decodes to neutral flags" {
    const m = modifiers(0x0040 | 0x0001); // KMOD_LCTRL | KMOD_LSHIFT
    try std.testing.expect(m.ctrl and m.shift and !m.alt and !m.super);
    const g = modifiers(0x0400); // KMOD_LGUI
    try std.testing.expect(g.super and !g.ctrl);
}

test "SDL keycode maps alphanumeric keys to uppercase for shortcuts" {
    try std.testing.expectEqual(@as(?ev.KeyCode, 'V'), keyCodeFromSdlKeycode('v'));
    try std.testing.expectEqual(@as(?ev.KeyCode, 'P'), keyCodeFromSdlKeycode('p'));
    try std.testing.expectEqual(@as(?ev.KeyCode, 'C'), keyCodeFromSdlKeycode('c'));
    try std.testing.expectEqual(@as(?ev.KeyCode, 'A'), keyCodeFromSdlKeycode('A'));
    try std.testing.expectEqual(@as(?ev.KeyCode, '1'), keyCodeFromSdlKeycode('1'));
    try std.testing.expectEqual(@as(?ev.KeyCode, '9'), keyCodeFromSdlKeycode('9'));
    try std.testing.expectEqual(@as(?ev.KeyCode, 0xBB), keyCodeFromSdlKeycode('+'));
    try std.testing.expectEqual(@as(?ev.KeyCode, 0xBB), keyCodeFromSdlKeycode('='));
    try std.testing.expectEqual(@as(?ev.KeyCode, 0xBD), keyCodeFromSdlKeycode('-'));
    // X11-style Ctrl+letter control codes
    try std.testing.expectEqual(@as(?ev.KeyCode, 'V'), keyCodeFromSdlKeycode(0x16));
    try std.testing.expectEqual(@as(?ev.KeyCode, 'P'), keyCodeFromSdlKeycode(0x10));
}

test "shortcut scancodes map letters and plus/minus keys" {
    try std.testing.expectEqual(@as(?ev.KeyCode, 'A'), keyCodeFromShortcutScancode(4));
    try std.testing.expectEqual(@as(?ev.KeyCode, 'V'), keyCodeFromShortcutScancode(25));
    try std.testing.expectEqual(@as(?ev.KeyCode, 'P'), keyCodeFromShortcutScancode(19));
    try std.testing.expectEqual(@as(?ev.KeyCode, '1'), keyCodeFromShortcutScancode(30));
    try std.testing.expectEqual(@as(?ev.KeyCode, '0'), keyCodeFromShortcutScancode(39));
    try std.testing.expectEqual(@as(?ev.KeyCode, 0xBB), keyCodeFromShortcutScancode(46));
    try std.testing.expectEqual(@as(?ev.KeyCode, 0xBD), keyCodeFromShortcutScancode(45));
}

test "shortcutKeyCode prefers logical keycode then scancode" {
    try std.testing.expectEqual(@as(?ev.KeyCode, 'V'), shortcutKeyCode(25, 'v'));
    try std.testing.expectEqual(@as(?ev.KeyCode, 'V'), shortcutKeyCode(25, 0));
    try std.testing.expectEqual(@as(?ev.KeyCode, 0xBB), shortcutKeyCode(46, '='));
}
