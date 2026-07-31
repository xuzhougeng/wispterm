//! Pure row/geometry math for the SSH-profiles overlay (list + form modes).
//!
//! Extracted from renderer/overlays.zig so the SSH-specific row mapping (how many
//! rows a list mode renders, which action a given row maps to in `manage` mode,
//! and the fixed form-row count) can be reasoned about and unit-tested in
//! isolation. Mirrors the command-palette pilot: everything here is a pure
//! function of its inputs (the list mode and the count of profiles that pass the
//! filter). There are NO global reads and NO AppWindow import — the caller
//! (overlays.zig) snapshots `sshState().list_mode` and `sshVisibleProfileCount()`
//! and passes them in, then uses the returned numbers exactly as before.
//!
//! NOTE: this module covers the SSH-specific row arithmetic only. The outer box
//! geometry (box width/height/position, scroll capacity) lives in the shared
//! `sessionLayout()` because the session launcher folds SSH, AI and local-shell
//! modes into one panel; that math is not SSH-specific and is intentionally left
//! in overlays.zig.

const std = @import("std");
const ssh_profiles = @import("ssh_profiles.zig");

pub const SshListMode = ssh_profiles.SshListMode;

/// Form rows = 8 fields + 3 action rows (save+connect, save, cancel). Mirrors
/// `SSH_FIELD_COUNT + 3` in overlays.zig and `ssh_profiles.SSH_FORM_ROW_COUNT`.
pub const FORM_ROW_COUNT: usize = ssh_profiles.SSH_FORM_ROW_COUNT;

/// Cap on visible list rows the launcher renders for the SSH list at once.
/// Mirrors `SSH_LIST_MAX_VISIBLE_ROWS` in overlays.zig.
pub const LIST_MAX_VISIBLE_ROWS: usize = 5;

/// What the row at `row` triggers when the SSH list is in `manage` mode. Mirrors
/// the in-overlays `SshManageAction` enum.
pub const ManageAction = enum {
    profile,
    load_openssh_config,
    new_ssh,
    edit_ssh,
    delete_ssh,
    cancel,
};

/// Total rows in the SSH list for the given mode. `visible_profile_count` is the
/// number of profiles that pass the active filter. Mirrors the body of
/// overlays.sshListRowCount() verbatim:
///   manage        -> profiles + 5 (config import, new, edit, delete, cancel)
///   delete_select -> profiles + 2 (delete-selected, back)
///   edit/ai/tmux  -> profiles + 1 (back)
pub fn listRowCount(list_mode: SshListMode, visible_profile_count: usize) usize {
    return switch (list_mode) {
        .manage => visible_profile_count + 5,
        .delete_select => visible_profile_count + 2,
        .edit_select, .ai_history_select, .tmux_connect => visible_profile_count + 1,
    };
}

/// Map a `manage`-mode list row to the action it represents. Rows below
/// `visible_profile_count` are profiles; the trailing rows are the fixed action
/// rows. Mirrors overlays.sshManageActionForRow() verbatim.
pub fn manageActionForRow(row: usize, visible_profile_count: usize) ManageAction {
    if (row < visible_profile_count) return .profile;
    return switch (row - visible_profile_count) {
        0 => .load_openssh_config,
        1 => .new_ssh,
        2 => .edit_ssh,
        3 => .delete_ssh,
        else => .cancel,
    };
}

test "list row count adds the right action rows per mode" {
    // manage: profiles + 5 action rows.
    try std.testing.expectEqual(@as(usize, 5), listRowCount(.manage, 0));
    try std.testing.expectEqual(@as(usize, 7), listRowCount(.manage, 2));
    // delete_select: profiles + 2.
    try std.testing.expectEqual(@as(usize, 2), listRowCount(.delete_select, 0));
    try std.testing.expectEqual(@as(usize, 5), listRowCount(.delete_select, 3));
    // edit/ai-history/tmux: profiles + 1 (just a back row).
    try std.testing.expectEqual(@as(usize, 1), listRowCount(.edit_select, 0));
    try std.testing.expectEqual(@as(usize, 4), listRowCount(.edit_select, 3));
    try std.testing.expectEqual(@as(usize, 1), listRowCount(.ai_history_select, 0));
    try std.testing.expectEqual(@as(usize, 4), listRowCount(.tmux_connect, 3));
}

test "manage action mapping: profile rows then fixed action rows" {
    const visible: usize = 2;
    // First `visible` rows are profiles.
    try std.testing.expectEqual(ManageAction.profile, manageActionForRow(0, visible));
    try std.testing.expectEqual(ManageAction.profile, manageActionForRow(1, visible));
    // Trailing action rows in fixed order.
    try std.testing.expectEqual(ManageAction.load_openssh_config, manageActionForRow(2, visible));
    try std.testing.expectEqual(ManageAction.new_ssh, manageActionForRow(3, visible));
    try std.testing.expectEqual(ManageAction.edit_ssh, manageActionForRow(4, visible));
    try std.testing.expectEqual(ManageAction.delete_ssh, manageActionForRow(5, visible));
    // Anything past the known action rows is a no-op cancel.
    try std.testing.expectEqual(ManageAction.cancel, manageActionForRow(6, visible));
    try std.testing.expectEqual(ManageAction.cancel, manageActionForRow(99, visible));
}

test "manage action mapping with no profiles starts at action rows" {
    try std.testing.expectEqual(ManageAction.load_openssh_config, manageActionForRow(0, 0));
    try std.testing.expectEqual(ManageAction.new_ssh, manageActionForRow(1, 0));
    try std.testing.expectEqual(ManageAction.edit_ssh, manageActionForRow(2, 0));
    try std.testing.expectEqual(ManageAction.delete_ssh, manageActionForRow(3, 0));
}

test "manage list row count covers all five action rows" {
    // manage adds 5 rows: load-config, new, edit, delete, and a trailing cancel
    // row. The last visible row (count-1) is the cancel row; delete_ssh sits just
    // above it (count-2). This couples listRowCount to the action map.
    const visible: usize = 4;
    const count = listRowCount(.manage, visible);
    try std.testing.expectEqual(visible + 5, count);
    try std.testing.expectEqual(ManageAction.cancel, manageActionForRow(count - 1, visible));
    try std.testing.expectEqual(ManageAction.delete_ssh, manageActionForRow(count - 2, visible));
    // One row past the last visible row is still cancel (out of range).
    try std.testing.expectEqual(ManageAction.cancel, manageActionForRow(count, visible));
}

test "form row count matches field count plus three action rows" {
    try std.testing.expectEqual(ssh_profiles.SSH_FIELD_COUNT + 3, FORM_ROW_COUNT);
}
