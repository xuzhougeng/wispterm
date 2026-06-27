//! Input-layer key->action mapping for the file explorer.
//!
//! This is the correct dependency direction: the input layer maps a platform
//! key code to a domain-owned `file_explorer/action.zig` intent. The
//! file_explorer module owns the intent type and performs the effect via
//! `handleAction`; this module only classifies a key code.
//!
//! No AppWindow import, no globals, no side effects: this module only names the
//! intent and classifies a key event.
const std = @import("std");
const platform_input = @import("../platform/input_events.zig");
const fe_action = @import("../file_explorer/action.zig");

/// Classify a key code in normal navigation mode into a typed intent, or null
/// if the key is not one of the navigation keys this module owns. Pure: the
/// caller still decides consumption / repaint exactly as before.
///
/// Only the modifier-free Up/Down/Enter navigation keys are mapped here; the
/// remaining file-explorer keys (rename, new, delete, download, refresh) carry
/// runtime/modifier conditions and stay in input.zig for this slice.
pub fn fromNavigationKey(key_code: platform_input.KeyCode) ?fe_action.Action {
    if (key_code == platform_input.key_up) return .move_selection_up;
    if (key_code == platform_input.key_down) return .move_selection_down;
    if (key_code == platform_input.key_enter) return .toggle_selected_expand;
    return null;
}

/// Classify file-operation shortcuts in normal mode. These are the operations
/// fully owned by file_explorer itself; host-dependent operations such as file
/// dialogs and default download directories stay in input.zig.
pub fn fromOperationKey(ev: platform_input.KeyEvent) ?fe_action.Action {
    switch (ev.key_code) {
        0x52 => { // 'R': bare = rename, Ctrl/Cmd+R = refresh
            if (!ev.ctrl and !ev.alt and !ev.super) return .rename_selected;
            if ((ev.ctrl or ev.super) and !ev.alt and !ev.shift) return .refresh;
            return null;
        },
        0x4E => { // 'N': bare = new file, Shift+N = new folder
            if (!ev.ctrl and !ev.alt and !ev.super) {
                return if (ev.shift) .create_directory else .create_file;
            }
            return null;
        },
        0x44 => { // 'D': delete
            if (!ev.ctrl and !ev.alt and !ev.shift and !ev.super) return .delete_selected;
            return null;
        },
        platform_input.key_f5 => return .refresh,
        else => return null,
    }
}

test "navigation keys map to the matching file-explorer intent" {
    try std.testing.expectEqual(
        fe_action.Action.move_selection_up,
        fromNavigationKey(platform_input.key_up).?,
    );
    try std.testing.expectEqual(
        fe_action.Action.move_selection_down,
        fromNavigationKey(platform_input.key_down).?,
    );
    try std.testing.expectEqual(
        fe_action.Action.toggle_selected_expand,
        fromNavigationKey(platform_input.key_enter).?,
    );
}

test "non-navigation keys are not owned by this mapping" {
    try std.testing.expectEqual(@as(?fe_action.Action, null), fromNavigationKey(platform_input.key_escape));
    try std.testing.expectEqual(@as(?fe_action.Action, null), fromNavigationKey(platform_input.key_backspace));
    try std.testing.expectEqual(@as(?fe_action.Action, null), fromNavigationKey(0x52)); // 'R'
}

test "file operation keys map to file-explorer intents" {
    try std.testing.expectEqual(fe_action.Action.rename_selected, fromOperationKey(.{ .key_code = 0x52, .ctrl = false, .shift = false, .alt = false }).?);
    try std.testing.expectEqual(fe_action.Action.refresh, fromOperationKey(.{ .key_code = 0x52, .ctrl = true, .shift = false, .alt = false }).?);
    try std.testing.expectEqual(fe_action.Action.refresh, fromOperationKey(.{ .key_code = 0x52, .ctrl = false, .shift = false, .alt = false, .super = true }).?);
    try std.testing.expectEqual(fe_action.Action.create_file, fromOperationKey(.{ .key_code = 0x4E, .ctrl = false, .shift = false, .alt = false }).?);
    try std.testing.expectEqual(fe_action.Action.create_directory, fromOperationKey(.{ .key_code = 0x4E, .ctrl = false, .shift = true, .alt = false }).?);
    try std.testing.expectEqual(fe_action.Action.delete_selected, fromOperationKey(.{ .key_code = 0x44, .ctrl = false, .shift = false, .alt = false }).?);
    try std.testing.expectEqual(fe_action.Action.refresh, fromOperationKey(.{ .key_code = platform_input.key_f5, .ctrl = false, .shift = false, .alt = false }).?);
}

test "modified file operation keys stay unowned when they are not shortcuts" {
    try std.testing.expectEqual(@as(?fe_action.Action, null), fromOperationKey(.{ .key_code = 0x52, .ctrl = false, .shift = false, .alt = true }));
    try std.testing.expectEqual(@as(?fe_action.Action, null), fromOperationKey(.{ .key_code = 0x4E, .ctrl = true, .shift = false, .alt = false }));
    try std.testing.expectEqual(@as(?fe_action.Action, null), fromOperationKey(.{ .key_code = 0x44, .ctrl = false, .shift = true, .alt = false }));
}
