//! Pure keybind-action → command-intent resolution, extracted from input.zig's
//! handleConfiguredKeybindAction. `resolve` answers "what command does this
//! action trigger in this phase?" with no side effects; input.zig's
//! executeCommand performs the effect (and decides consumption for the
//! performable focus/switch commands, which depends on runtime state).
const std = @import("std");
const keybind = @import("../keybind.zig");

/// Which keybind-processing pass this is: `early` (before overlay/palette
/// routing) or `late` (after).
pub const Phase = enum { early, late };

/// Where a focus_split command moves focus: four spatial directions plus
/// previous/next ordering.
pub const FocusTarget = enum { left, right, up, down, previous, next };

pub const Command = union(enum) {
    // Early commands (input.zig commits any active tab rename before executing).
    toggle_quake,
    toggle_command_palette,
    new_window,
    new_session,
    split_right,
    toggle_file_explorer,
    toggle_sidebar,
    close_panel_or_tab,
    toggle_maximize,
    font_size: i32,
    // Late commands.
    copy,
    paste,
    paste_image,
    focus_split: FocusTarget,
    equalize_splits,
    next_tab,
    previous_tab,
    open_config,
    switch_tab: usize,
};

/// Map a configured action + phase to the command it triggers, or null if the
/// action is not handled in that phase. Pure: no globals, no side effects.
pub fn resolve(action: keybind.Action, phase: Phase) ?Command {
    return switch (phase) {
        .early => switch (action) {
            .toggle_quake => .toggle_quake,
            .toggle_command_palette => .toggle_command_palette,
            .new_window => .new_window,
            .new_session => .new_session,
            .split_right => .split_right,
            .toggle_file_explorer => .toggle_file_explorer,
            .toggle_sidebar => .toggle_sidebar,
            .close_panel_or_tab => .close_panel_or_tab,
            .toggle_maximize => .toggle_maximize,
            .font_size_increase => .{ .font_size = 1 },
            .font_size_decrease => .{ .font_size = -1 },
            else => null,
        },
        .late => switch (action) {
            .copy => .copy,
            .paste => .paste,
            .paste_image => .paste_image,
            .focus_left => .{ .focus_split = .left },
            .focus_right => .{ .focus_split = .right },
            .focus_up => .{ .focus_split = .up },
            .focus_down => .{ .focus_split = .down },
            .focus_previous => .{ .focus_split = .previous },
            .focus_next => .{ .focus_split = .next },
            .equalize_splits => .equalize_splits,
            .next_tab => .next_tab,
            .previous_tab => .previous_tab,
            .open_config => .open_config,
            else => if (switchTabIndex(action)) |idx| .{ .switch_tab = idx } else null,
        },
    };
}

/// switch_tab_1..9 → 0-based index, else null. (Was switchTabActionIndex.)
fn switchTabIndex(action: keybind.Action) ?usize {
    return switch (action) {
        .switch_tab_1 => 0,
        .switch_tab_2 => 1,
        .switch_tab_3 => 2,
        .switch_tab_4 => 3,
        .switch_tab_5 => 4,
        .switch_tab_6 => 5,
        .switch_tab_7 => 6,
        .switch_tab_8 => 7,
        .switch_tab_9 => 8,
        else => null,
    };
}

test "early commands resolve only in the early phase" {
    try std.testing.expectEqual(Command.toggle_quake, resolve(.toggle_quake, .early).?);
    try std.testing.expectEqual(Command.split_right, resolve(.split_right, .early).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.toggle_quake, .late));
}

test "font size carries the delta" {
    try std.testing.expectEqual(Command{ .font_size = 1 }, resolve(.font_size_increase, .early).?);
    try std.testing.expectEqual(Command{ .font_size = -1 }, resolve(.font_size_decrease, .early).?);
}

test "late commands resolve only in the late phase" {
    try std.testing.expectEqual(Command.copy, resolve(.copy, .late).?);
    try std.testing.expectEqual(Command.open_config, resolve(.open_config, .late).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.copy, .early));
}

test "focus actions map to focus_split targets" {
    try std.testing.expectEqual(Command{ .focus_split = .left }, resolve(.focus_left, .late).?);
    try std.testing.expectEqual(Command{ .focus_split = .previous }, resolve(.focus_previous, .late).?);
    try std.testing.expectEqual(Command{ .focus_split = .next }, resolve(.focus_next, .late).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.focus_left, .early));
}

test "switch_tab_N maps to a zero-based index" {
    try std.testing.expectEqual(Command{ .switch_tab = 0 }, resolve(.switch_tab_1, .late).?);
    try std.testing.expectEqual(Command{ .switch_tab = 8 }, resolve(.switch_tab_9, .late).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.switch_tab_1, .early));
}
