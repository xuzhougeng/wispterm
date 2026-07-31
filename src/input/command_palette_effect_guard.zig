const std = @import("std");

fn commandPaletteKeyBranch(source: []const u8) ![]const u8 {
    const branch_marker = "if (overlays.commandPaletteVisible()) {";
    const action_marker = "command_palette_input.keyAction";
    const action_start = std.mem.indexOf(u8, source, action_marker) orelse return error.MissingCommandPaletteBranch;
    const branch_start = std.mem.lastIndexOf(u8, source[0..action_start], branch_marker) orelse return error.MissingCommandPaletteBranch;
    const branch_tail = source[branch_start..];
    const branch_end = std.mem.indexOf(u8, branch_tail, "if (copilot_picker.isVisible())") orelse return error.MissingCommandPaletteBranchEnd;
    return branch_tail[0..branch_end];
}

fn commandPaletteCharBranch(source: []const u8) ![]const u8 {
    const char_marker = "const effect = command_palette_input.charEffect(ev);";
    const char_start = std.mem.indexOf(u8, source, char_marker) orelse return error.MissingCommandPaletteCharBranch;
    const char_tail = source[char_start..];
    const char_end = std.mem.indexOf(u8, char_tail, "if (weixinQrPanelConsumesChar())") orelse return error.MissingCommandPaletteCharBranchEnd;
    return char_tail[0..char_end];
}

test "input: command palette dispatch branches use UiEffect instead of direct dirty writes" {
    const source = @embedFile("../input.zig");

    const key_branch = try commandPaletteKeyBranch(source);
    try std.testing.expect(std.mem.indexOf(u8, key_branch, "command_palette_input.keyAction") != null);
    try std.testing.expect(std.mem.indexOf(u8, key_branch, "AppWindow.g_force_rebuild") == null);
    try std.testing.expect(std.mem.indexOf(u8, key_branch, "AppWindow.g_cells_valid") == null);

    const char_branch = try commandPaletteCharBranch(source);
    try std.testing.expect(std.mem.indexOf(u8, char_branch, "AppWindow.g_force_rebuild") == null);
    try std.testing.expect(std.mem.indexOf(u8, char_branch, "AppWindow.g_cells_valid") == null);
}
