const std = @import("std");

fn dispatchKeySource(source: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, source, "fn dispatchKey(") orelse return error.MissingDispatchKey;
    return source[start..];
}

fn branchAfter(source: []const u8, marker: []const u8, end_marker: []const u8) ![]const u8 {
    const dispatch_source = try dispatchKeySource(source);
    const start = std.mem.indexOf(u8, dispatch_source, marker) orelse return error.MissingBranch;
    const tail = dispatch_source[start..];
    const end = std.mem.indexOf(u8, tail, end_marker) orelse return error.MissingBranchEnd;
    return tail[0..end];
}

fn expectNoManualDirtyWrites(branch: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, branch, "AppWindow.g_force_rebuild") == null);
    try std.testing.expect(std.mem.indexOf(u8, branch, "AppWindow.g_cells_valid") == null);
}

test "input: converted settings and confirm branches return UiEffect instead of dirty writes" {
    const source = @embedFile("../input.zig");

    const window_close_branch = try branchAfter(
        source,
        "if (overlays.windowCloseConfirmVisible()) {",
        "if (overlays.transferCancelConfirmVisible())",
    );
    try std.testing.expect(std.mem.indexOf(u8, window_close_branch, "return overlays.windowCloseConfirmHandleKey") != null);
    try expectNoManualDirtyWrites(window_close_branch);

    const transfer_cancel_branch = try branchAfter(
        source,
        "if (overlays.transferCancelConfirmVisible()) {",
        "const action = configuredAction(ev);",
    );
    try std.testing.expect(std.mem.indexOf(u8, transfer_cancel_branch, "overlays.transferCancelConfirmHandleKeyEffect") != null);
    try std.testing.expect(std.mem.indexOf(u8, transfer_cancel_branch, "return result.effect") != null);
    try expectNoManualDirtyWrites(transfer_cancel_branch);

    const restore_branch = try branchAfter(
        source,
        "if (overlays.restoreDefaultsConfirmVisible()) {",
        "if (overlays.settingsPageVisible())",
    );
    try std.testing.expect(std.mem.indexOf(u8, restore_branch, "return overlays.restoreDefaultsConfirmHandleKey") != null);
    try expectNoManualDirtyWrites(restore_branch);

    const settings_branch = try branchAfter(
        source,
        "if (overlays.settingsPageVisible()) {",
        "if (AppWindow.weixin_qr_panel.visible())",
    );
    try std.testing.expect(std.mem.indexOf(u8, settings_branch, "return overlays.settingsPageHandleKey") != null);
    try expectNoManualDirtyWrites(settings_branch);
}
