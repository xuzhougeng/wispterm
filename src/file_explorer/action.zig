//! Domain-owned file-explorer keyboard intents.
//!
//! This is pure data describing what a navigation key should do to the file
//! explorer; the key->action classification lives in the input layer
//! (`input/file_explorer_keymap.zig`), and `file_explorer.handleAction` performs
//! the effect by delegating to its existing `moveSelection`/`toggleExpand` API.
//! The goal is to keep input.zig from calling file_explorer internals (and from
//! reaching into `file_explorer.g_*`) directly on the navigation key path; the
//! file_explorer module stays the owner of the actual mutation.
//!
//! No AppWindow import, no input import, no platform import, no globals, no side
//! effects: this module only names the intent.

/// A file-explorer keyboard intent in normal navigation mode (i.e. when there
/// is no active rename/new/delete op). Each variant corresponds to an existing
/// file_explorer operation; routing a key through this enum keeps input.zig from
/// calling those operations — or poking `file_explorer.g_*` — directly.
pub const Action = enum {
    /// Move the selection up one row (Up arrow). → file_explorer.moveSelection(-1)
    move_selection_up,
    /// Move the selection down one row (Down arrow). → file_explorer.moveSelection(1)
    move_selection_down,
    /// Expand/collapse the selected directory (Enter). A no-op when the current
    /// selection is not a directory. → file_explorer.toggleExpand(selected)
    toggle_selected_expand,
    /// Start renaming the selected entry (`R`).
    rename_selected,
    /// Refresh the current directory (`Ctrl/Cmd+R` or F5).
    refresh,
    /// Start the inline "new file" operation (`N`).
    create_file,
    /// Start the inline "new folder" operation (`Shift+N`).
    create_directory,
    /// Start the delete confirmation for the selected entry (`D`).
    delete_selected,
};
