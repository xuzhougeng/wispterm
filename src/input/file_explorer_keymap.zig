//! Input-layer key->action mapping for the file explorer.
//!
//! This is the correct dependency direction: the input layer maps a platform
//! key code to a domain-owned `file_explorer/action.zig` intent. The
//! file_explorer module owns the intent type and performs the effect via
//! `handleAction`; this module only classifies a key code.
//!
//! No AppWindow import, no globals, no side effects: this module only names the
//! intent and (in `fromNavigationKey`) classifies a key code.
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
