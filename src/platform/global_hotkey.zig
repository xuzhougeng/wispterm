const std = @import("std");
const builtin = @import("builtin");
const platform_window = @import("window.zig");

pub const Backend = enum {
    windows,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("global_hotkey_windows.zig"),
    .unsupported => @import("global_hotkey_unsupported.zig"),
};

pub const Trigger = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    win: bool = false,
    key_code: u32,
};

pub fn modifiersForTrigger(trigger: Trigger) u32 {
    return (if (trigger.ctrl) mod_control else 0) |
        (if (trigger.shift) mod_shift else 0) |
        (if (trigger.alt) mod_alt else 0) |
        (if (trigger.win) mod_win else 0) |
        mod_norepeat;
}

pub fn register(hwnd: platform_window.NativeHandle, id: i32, trigger: Trigger) bool {
    return impl.register(hwnd, id, modifiersForTrigger(trigger), trigger.key_code);
}

pub fn unregister(hwnd: platform_window.NativeHandle, id: i32) void {
    impl.unregister(hwnd, id);
}

const mod_alt: u32 = 0x0001;
const mod_control: u32 = 0x0002;
const mod_shift: u32 = 0x0004;
const mod_win: u32 = 0x0008;
const mod_norepeat: u32 = 0x4000;

test "platform global hotkey maps keybind modifiers to OS flags" {
    const trigger = Trigger{
        .ctrl = true,
        .shift = true,
        .alt = true,
        .win = true,
        .key_code = 0xC0,
    };

    try std.testing.expectEqual(@as(u32, 0x400F), modifiersForTrigger(trigger));
}

test "platform global hotkey exposes register and unregister API" {
    const register_info = @typeInfo(@TypeOf(register)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), register_info.params.len);
    try std.testing.expect(register_info.params[0].type.? == platform_window.NativeHandle);
    try std.testing.expect(register_info.params[1].type.? == i32);
    try std.testing.expect(register_info.params[2].type.? == Trigger);
    try std.testing.expect(register_info.return_type.? == bool);

    const unregister_info = @typeInfo(@TypeOf(unregister)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), unregister_info.params.len);
    try std.testing.expect(unregister_info.params[0].type.? == platform_window.NativeHandle);
    try std.testing.expect(unregister_info.params[1].type.? == i32);
    try std.testing.expect(unregister_info.return_type.? == void);
}

test "platform global hotkey selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
