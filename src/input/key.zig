const std = @import("std");

pub const Key = enum {
    unidentified,
    backspace,
    tab,
    enter,
    escape,
    delete,
    home,
    end,
    page_up,
    page_down,
    insert,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    key_a,
    key_c,
    key_e,
    key_k,
    key_l,
    key_u,
    key_v,
    key_y,
    key_n,
    key_p,
    key_s,
    key_w,
};

pub const KeyEvent = struct {
    key: Key,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,

    pub fn matches(self: KeyEvent, key: Key) bool {
        return self.key == key;
    }

    pub fn ctrlOnly(self: KeyEvent, key: Key) bool {
        return self.key == key and self.ctrl and !self.shift and !self.alt;
    }
};

test "input key event exposes platform-neutral modifiers and named keys" {
    const ev = KeyEvent{ .key = .arrow_left, .ctrl = true };

    try std.testing.expectEqual(Key.arrow_left, ev.key);
    try std.testing.expect(ev.ctrl);
    try std.testing.expect(!ev.shift);
    try std.testing.expect(!ev.alt);
    try std.testing.expect(ev.matches(.arrow_left));
    try std.testing.expect(ev.ctrlOnly(.arrow_left));
    try std.testing.expect(!ev.ctrlOnly(.arrow_right));
}
