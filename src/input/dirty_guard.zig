const std = @import("std");

const input_source = @embedFile("../input.zig");

fn sourceSlice(start_marker: []const u8, end_marker: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, input_source, start_marker) orelse return error.StartMarkerMissing;
    const rest = input_source[start..];
    const end_rel = std.mem.indexOf(u8, rest, end_marker) orelse return error.EndMarkerMissing;
    return rest[0..end_rel];
}

fn expectNoDirectDirtyAssignments(region: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, region, "AppWindow.g_force_rebuild =") == null);
    try std.testing.expect(std.mem.indexOf(u8, region, "AppWindow.g_cells_valid =") == null);
}

test "input dispatch char routes UI dirtying through effects" {
    const region = try sourceSlice("fn dispatchChar", "\nfn triggerFromKeyEvent");
    try expectNoDirectDirtyAssignments(region);
    try std.testing.expect(std.mem.indexOf(u8, region, "input_effects.repaint()") != null);
}

test "input dispatch key routes UI dirtying through effects" {
    const region = try sourceSlice("fn dispatchKey", "\nfn isModifierKey");
    try expectNoDirectDirtyAssignments(region);
    try std.testing.expect(std.mem.indexOf(u8, region, "input_effects.repaint()") != null);
    try std.testing.expect(std.mem.indexOf(u8, region, "input_effects.rebuildOnly()") != null);
}

test "input key-dispatched preview helpers route UI dirtying through effects" {
    const region = try sourceSlice("fn openPreviewGalleryNeighbor", "\nfn findPreviewGalleryNeighbor");
    try expectNoDirectDirtyAssignments(region);
    try std.testing.expect(std.mem.indexOf(u8, region, "requestInputRepaint()") != null);
}

test "input key-dispatched agent history helpers route UI dirtying through effects" {
    const region = try sourceSlice("fn deleteSelectedAgentHistoryRow", "\nfn hitTestConfigButton");
    try expectNoDirectDirtyAssignments(region);
    try std.testing.expect(std.mem.indexOf(u8, region, "requestInputRepaint()") != null);
}

test "input runtime dirtying routes through effect boundary" {
    const region = try sourceSlice("fn applyInputEffect", "\n// --- Maximize toggle (native window) ---");
    try expectNoDirectDirtyAssignments(region);
    try std.testing.expect(std.mem.indexOf(u8, region, "requestInputRepaint()") != null);
    try std.testing.expect(std.mem.indexOf(u8, region, "requestInputRebuild()") != null);
    try std.testing.expect(std.mem.indexOf(u8, region, "requestInputDirtyFlags(") != null);
}

test "input dirty helpers delegate to the local apply boundary" {
    const helper_region = try sourceSlice("fn applyInputEffect", "\nfn blurBrowserUrlBarIfFocused");
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "AppWindow.applyUiEffect(effect)") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "requestInputRepaint()") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "requestInputRebuild()") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "requestInputDirtyFlags") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_region, "input_effects.fromDirtyFlags(force_rebuild, cells_valid)") != null);
}
