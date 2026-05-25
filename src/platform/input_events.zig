const std = @import("std");

pub const KeyCode = usize;

pub const key_backspace: KeyCode = 0x08;
pub const key_tab: KeyCode = 0x09;
pub const key_enter: KeyCode = 0x0D;
pub const key_shift: KeyCode = 0x10;
pub const key_control: KeyCode = 0x11;
pub const key_alt: KeyCode = 0x12;
pub const key_escape: KeyCode = 0x1B;
pub const key_page_up: KeyCode = 0x21;
pub const key_page_down: KeyCode = 0x22;
pub const key_end: KeyCode = 0x23;
pub const key_home: KeyCode = 0x24;
pub const key_left: KeyCode = 0x25;
pub const key_up: KeyCode = 0x26;
pub const key_right: KeyCode = 0x27;
pub const key_down: KeyCode = 0x28;
pub const key_insert: KeyCode = 0x2D;
pub const key_delete: KeyCode = 0x2E;
pub const key_left_shift: KeyCode = 0xA0;
pub const key_right_shift: KeyCode = 0xA1;
pub const key_left_control: KeyCode = 0xA2;
pub const key_right_control: KeyCode = 0xA3;
pub const key_left_alt: KeyCode = 0xA4;
pub const key_right_alt: KeyCode = 0xA5;

pub const KeyEvent = struct {
    key_code: KeyCode,
    ctrl: bool,
    shift: bool,
    alt: bool,
};

pub const CharEvent = struct {
    codepoint: u21,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const MouseButton = enum { left, right, middle };
pub const MouseButtonAction = enum { press, release, double_click };

pub const MouseButtonEvent = struct {
    button: MouseButton,
    action: MouseButtonAction,
    x: i32,
    y: i32,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const MouseMoveEvent = struct {
    x: i32,
    y: i32,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const MouseWheelEvent = struct {
    delta: i16,
    xpos: i32,
    ypos: i32,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

test "platform input events expose backend-neutral keyboard and mouse shapes" {
    const key = KeyEvent{ .key_code = key_left, .ctrl = true, .shift = false, .alt = true };
    try std.testing.expectEqual(key_left, key.key_code);
    try std.testing.expect(key.ctrl);
    try std.testing.expect(!key.shift);
    try std.testing.expect(key.alt);

    const button = MouseButtonEvent{ .button = .left, .action = .press, .x = 10, .y = 20 };
    try std.testing.expectEqual(MouseButton.left, button.button);
    try std.testing.expectEqual(MouseButtonAction.press, button.action);
    try std.testing.expectEqual(@as(i32, 10), button.x);
    try std.testing.expectEqual(@as(i32, 20), button.y);
}

test "platform input events expose key code constants used by input logic" {
    try std.testing.expectEqual(@as(KeyCode, 0x0D), key_enter);
    try std.testing.expectEqual(@as(KeyCode, 0x1B), key_escape);
    try std.testing.expectEqual(@as(KeyCode, 0x25), key_left);
    try std.testing.expectEqual(@as(KeyCode, 0x26), key_up);
    try std.testing.expectEqual(@as(KeyCode, 0x2E), key_delete);
}
