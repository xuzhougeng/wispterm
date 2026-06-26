//! Typed file-explorer keyboard intents, extracted from input.zig's
//! `handleFileExplorerKey`. This is pure data: a key event maps to a
//! `FileExplorerInputAction`, and `file_explorer.handleInputAction` performs the
//! effect by delegating to its existing `moveSelection`/`toggleExpand` API. The
//! goal is to stop input.zig from calling file_explorer internals (and from
//! reaching into `file_explorer.g_*`) directly on the navigation key path; the
//! file_explorer module stays the owner of the actual mutation.
//!
//! No AppWindow import, no globals, no side effects: this module only names the
//! intent and (in `fromNavigationKey`) classifies a key code.
const std = @import("std");
const platform_input = @import("../platform/input_events.zig");

/// A file-explorer keyboard intent in normal navigation mode (i.e. when there
/// is no active rename/new/delete op). Each variant corresponds to an existing
/// file_explorer operation; routing a key through this enum keeps input.zig from
/// calling those operations — or poking `file_explorer.g_*` — directly.
pub const FileExplorerInputAction = enum {
    /// Move the selection up one row (Up arrow). → file_explorer.moveSelection(-1)
    move_selection_up,
    /// Move the selection down one row (Down arrow). → file_explorer.moveSelection(1)
    move_selection_down,
    /// Expand/collapse the selected directory (Enter). A no-op when the current
    /// selection is not a directory. → file_explorer.toggleExpand(selected)
    toggle_selected_expand,
};

/// Classify a key code in normal navigation mode into a typed intent, or null
/// if the key is not one of the navigation keys this module owns. Pure: the
/// caller still decides consumption / repaint exactly as before.
///
/// Only the modifier-free Up/Down/Enter navigation keys are mapped here; the
/// remaining file-explorer keys (rename, new, delete, download, refresh) carry
/// runtime/modifier conditions and stay in input.zig for this slice.
pub fn fromNavigationKey(key_code: platform_input.KeyCode) ?FileExplorerInputAction {
    if (key_code == platform_input.key_up) return .move_selection_up;
    if (key_code == platform_input.key_down) return .move_selection_down;
    if (key_code == platform_input.key_enter) return .toggle_selected_expand;
    return null;
}

test "navigation keys map to the matching file-explorer intent" {
    try std.testing.expectEqual(
        FileExplorerInputAction.move_selection_up,
        fromNavigationKey(platform_input.key_up).?,
    );
    try std.testing.expectEqual(
        FileExplorerInputAction.move_selection_down,
        fromNavigationKey(platform_input.key_down).?,
    );
    try std.testing.expectEqual(
        FileExplorerInputAction.toggle_selected_expand,
        fromNavigationKey(platform_input.key_enter).?,
    );
}

test "non-navigation keys are not owned by this mapping" {
    try std.testing.expectEqual(@as(?FileExplorerInputAction, null), fromNavigationKey(platform_input.key_escape));
    try std.testing.expectEqual(@as(?FileExplorerInputAction, null), fromNavigationKey(platform_input.key_backspace));
    try std.testing.expectEqual(@as(?FileExplorerInputAction, null), fromNavigationKey(0x52)); // 'R'
}
