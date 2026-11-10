const std = @import("std");
const ui_effect = @import("../../appwindow/ui_effect.zig");
const platform_input = @import("../../platform/input_events.zig");

pub const Action = enum {
    noop,
    close,
    leave_history,
    move_up,
    move_down,
    execute,
    backspace,
    clear_filter,
    delete_history,
    cycle_history_source,
    open_conversation_center,
};

pub fn keyAction(ev: platform_input.KeyEvent, history_visible: bool) Action {
    if (history_visible) {
        return switch (ev.key_code) {
            platform_input.key_escape => .leave_history,
            platform_input.key_up => .move_up,
            platform_input.key_down => .move_down,
            platform_input.key_enter => if (ev.ctrl or ev.super) .open_conversation_center else .execute,
            platform_input.key_delete => .delete_history,
            platform_input.key_backspace => .backspace,
            platform_input.key_tab => .cycle_history_source,
            else => .noop,
        };
    }

    return switch (ev.key_code) {
        platform_input.key_escape => .close,
        platform_input.key_up => .move_up,
        platform_input.key_down => .move_down,
        platform_input.key_enter => .execute,
        platform_input.key_backspace => .backspace,
        platform_input.key_delete => .clear_filter,
        else => .noop,
    };
}

pub fn effectForAction(action: Action) ui_effect.UiEffect {
    _ = action;
    // Preserve current behavior: while the command palette is visible, key
    // events are consumed and request a repaint even when the key maps to no
    // state mutation.
    return .repaint;
}

pub fn charEffect(ev: platform_input.CharEvent) ui_effect.UiEffect {
    if (!ev.isTextInput()) return .consumed_only;
    return .repaint;
}

test "command palette input maps arrow down to repainting move action" {
    const action = keyAction(.{
        .key_code = platform_input.key_down,
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    }, false);

    try std.testing.expectEqual(Action.move_down, action);
    const effect = effectForAction(action);
    try std.testing.expect(effect.consumed);
    try std.testing.expect(effect.needs_rebuild);
    try std.testing.expect(effect.cells_invalid);
}

test "command palette input maps history escape to leave history" {
    const action = keyAction(.{
        .key_code = platform_input.key_escape,
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    }, true);

    try std.testing.expectEqual(Action.leave_history, action);
    try std.testing.expect(effectForAction(action).needs_rebuild);
}

test "command palette history Ctrl+Enter opens conversation center" {
    const action = keyAction(.{
        .key_code = platform_input.key_enter,
        .ctrl = true,
        .shift = false,
        .alt = false,
        .super = false,
    }, true);
    try std.testing.expectEqual(Action.open_conversation_center, action);
}

test "command palette char input repaints only for plain text" {
    try std.testing.expect(charEffect(.{ .codepoint = 'a', .ctrl = false, .alt = false }).needs_rebuild);
    try std.testing.expect(!charEffect(.{ .codepoint = 'a', .ctrl = true, .alt = false }).needs_rebuild);
    try std.testing.expect(!charEffect(.{ .codepoint = 'a', .ctrl = false, .alt = true }).needs_rebuild);
    // AltGr arrives as Ctrl+Alt on Windows and is text, not a chord.
    try std.testing.expect(charEffect(.{ .codepoint = '@', .ctrl = true, .alt = true }).needs_rebuild);
}
