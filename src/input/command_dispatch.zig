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
    split_down,
    toggle_file_explorer,
    toggle_sidebar,
    toggle_ai_copilot,
    copilot_conversation_picker,
    close_panel_or_tab,
    toggle_maximize,
    font_size: i32,
    open_settings,
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
    focus_panel: usize,
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
            .split_down => .split_down,
            .toggle_file_explorer => .toggle_file_explorer,
            .toggle_sidebar => .toggle_sidebar,
            .toggle_ai_copilot => .toggle_ai_copilot,
            .copilot_conversation_picker => .copilot_conversation_picker,
            .close_panel_or_tab => .close_panel_or_tab,
            .toggle_maximize => .toggle_maximize,
            .font_size_increase => .{ .font_size = 1 },
            .font_size_decrease => .{ .font_size = -1 },
            .open_settings => .open_settings,
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
            else => if (focusPanelNumber(action)) |n|
                .{ .focus_panel = n }
            else if (switchTabIndex(action)) |idx|
                .{ .switch_tab = idx }
            else
                null,
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

/// focus_panel_1..9 → 1-based panel number, else null.
fn focusPanelNumber(action: keybind.Action) ?usize {
    return switch (action) {
        .focus_panel_1 => 1,
        .focus_panel_2 => 2,
        .focus_panel_3 => 3,
        .focus_panel_4 => 4,
        .focus_panel_5 => 5,
        .focus_panel_6 => 6,
        .focus_panel_7 => 7,
        .focus_panel_8 => 8,
        .focus_panel_9 => 9,
        else => null,
    };
}

test "early commands resolve only in the early phase" {
    try std.testing.expectEqual(Command.toggle_quake, resolve(.toggle_quake, .early).?);
    try std.testing.expectEqual(Command.split_right, resolve(.split_right, .early).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.toggle_quake, .late));
}

test "split_right and split_down resolve in the early phase" {
    try std.testing.expectEqual(Command.split_right, resolve(.split_right, .early).?);
    try std.testing.expectEqual(Command.split_down, resolve(.split_down, .early).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.split_down, .late));
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

test "visual settings resolves before overlay routing" {
    try std.testing.expectEqual(Command.open_settings, resolve(.open_settings, .early).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.open_settings, .late));
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

test "toggle_ai_copilot resolves in the early phase" {
    try std.testing.expectEqual(Command.toggle_ai_copilot, resolve(.toggle_ai_copilot, .early).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.toggle_ai_copilot, .late));
}

test "focus_panel actions resolve to a 1-based focus_panel command (late phase only)" {
    try std.testing.expectEqual(Command{ .focus_panel = 1 }, resolve(.focus_panel_1, .late).?);
    try std.testing.expectEqual(Command{ .focus_panel = 9 }, resolve(.focus_panel_9, .late).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.focus_panel_1, .early));
    // Regression: the shared `else` arm still resolves switch_tab.
    try std.testing.expectEqual(Command{ .switch_tab = 0 }, resolve(.switch_tab_1, .late).?);
}

// Behavior test (converted from a source-string grep in test_main.zig that
// asserted input.zig contained a `.copilot_conversation_picker =>` dispatch
// arm). The dispatch lives here now; assert the real resolver wiring instead of
// grepping for the arm text.
test "copilot_conversation_picker resolves to the picker command in the early phase" {
    try std.testing.expectEqual(
        Command.copilot_conversation_picker,
        resolve(.copilot_conversation_picker, .early).?,
    );
    // It is an early-phase command, matching the real key-routing order.
    try std.testing.expectEqual(@as(?Command, null), resolve(.copilot_conversation_picker, .late));
}

// Behavior test (converted from a source-string grep that asserted keybind.zig
// contained the literal "copilot_conversation_picker"). Call the keybind catalog
// directly: the action name must parse to the enum value AND a default binding
// must exist, so the copilot picker is reachable out of the box. `keybind` is
// already imported by this module, so this runs in the fast test suite.
test "copilot_conversation_picker is a real, default-bound keybind action" {
    try std.testing.expectEqual(
        keybind.Action.copilot_conversation_picker,
        keybind.Action.parse("copilot_conversation_picker").?,
    );

    var bound = false;
    for (keybind.default_bindings) |binding| {
        if (binding.action == .copilot_conversation_picker) {
            bound = true;
            break;
        }
    }
    try std.testing.expect(bound);
}
