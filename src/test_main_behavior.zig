//! Behavior tests imported only by the `behavior` app-test shard.

const std = @import("std");
const app_metadata = @import("app_metadata.zig");
const command_center_state = @import("command/center_state.zig");
const keybind = @import("keybind.zig");
const command_dispatch = @import("input/command_dispatch.zig");

test "app version metadata is exposed for CLI and command center" {
    const expected_version = "1.32.0";
    try std.testing.expectEqualStrings("WispTerm", app_metadata.name);
    try std.testing.expectEqualStrings(expected_version, app_metadata.version);
    try std.testing.expect(std.mem.indexOf(u8, app_metadata.release_notes, "# WispTerm v" ++ expected_version) != null);

    var buf: [64]u8 = undefined;
    const line = try app_metadata.versionLine(&buf);
    try std.testing.expectEqualStrings("WispTerm " ++ app_metadata.version, line);
}

test "command center browser entries do not expose backend implementation names" {
    for (command_center_state.command_entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.detail, "WebView2") == null);
    }
}

// Behavior tests (converted from source-string greps): instead of asserting the
// keybind action *name* appears in keybind.zig and that input.zig contains a
// `.copilot_conversation_picker =>` dispatch arm, call the real catalog/seam
// functions and assert what they actually do at runtime. This proves the action
// is a real, parseable, default-bound keybind and that the extracted dispatch
// resolver wires it to the copilot picker command -- the same facts the greps
// encoded, but checked through behavior rather than text. The same assertions
// also live in src/input/command_dispatch.zig so they run in the fast suite
// (`zig build test`); these copies keep coverage in the full `test-full` binary.
test "copilot conversation picker is a real, default-bound keybind action" {
    // The action name resolves to the enum value (the action exists in the catalog).
    try std.testing.expectEqual(
        keybind.Action.copilot_conversation_picker,
        keybind.Action.parse("copilot_conversation_picker").?,
    );

    // A default keybind binds something to it (so the picker is reachable out of the box).
    var bound = false;
    for (keybind.default_bindings) |binding| {
        if (binding.action == .copilot_conversation_picker) {
            bound = true;
            break;
        }
    }
    try std.testing.expect(bound);
}

test "copilot conversation picker action dispatches to the picker command" {
    // The extracted dispatch resolver maps the action to the copilot picker
    // command in the early phase (this replaces grepping input.zig for the arm).
    try std.testing.expectEqual(
        command_dispatch.Command.copilot_conversation_picker,
        command_dispatch.resolve(.copilot_conversation_picker, .early).?,
    );
    // It only fires in the early phase, mirroring the real key-routing order.
    try std.testing.expectEqual(
        @as(?command_dispatch.Command, null),
        command_dispatch.resolve(.copilot_conversation_picker, .late),
    );
}

test "activeCopilotSession installs the history-change hook" {
    const src = @embedFile("appwindow/tab.zig");
    const anchor = "t.copilot_session = make() orelse return null;";
    const idx = std.mem.indexOf(u8, src, anchor) orelse return error.AnchorMissing;
    try std.testing.expect(std.mem.indexOf(u8, src[idx..], "installAiChatHistoryHook(") != null);
}

test "snapshotTab records copilot_session_id for terminal tabs" {
    const src = @embedFile("appwindow/tab.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, ".copilot_session_id = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "shouldPersistCopilot()") != null);
}

test "copilot load de-dups against open tabs" {
    const tab_src = @embedFile("appwindow/tab.zig");
    try std.testing.expect(std.mem.indexOf(u8, tab_src, "pub fn switchToCopilotTabBySessionId(") != null);
    const sidebar_src = @embedFile("appwindow/copilot_sidebar.zig");
    const load_idx = std.mem.indexOf(u8, sidebar_src, "pub fn loadConversationById(") orelse return error.Missing;
    try std.testing.expect(std.mem.indexOf(u8, sidebar_src[load_idx..], "switchToCopilotTabBySessionId(") != null);
}

test "copilot picker is rendered and key-routed" {
    const overlays_src = @embedFile("renderer/overlays.zig");
    try std.testing.expect(std.mem.indexOf(u8, overlays_src, "pub fn renderCopilotPicker(") != null);
    const input_src = @embedFile("input.zig");
    try std.testing.expect(std.mem.indexOf(u8, input_src, "copilot_picker.isVisible()") != null);
    const aw_src = @embedFile("AppWindow.zig");
    try std.testing.expect(std.mem.indexOf(u8, aw_src, "renderCopilotPicker(") != null);
}

test "merged copilot history picker tags sidebar rows and restores by origin" {
    const overlays_src = @embedFile("renderer/overlays.zig");
    // Right column shows the Sidebar tag for sidebar-origin rows.
    try std.testing.expect(std.mem.indexOf(u8, overlays_src, "cmd_palette_sidebar_tag") != null);
    // Activation branches on the row's copilot flag and loads into the sidebar.
    const act_idx = std.mem.indexOf(u8, overlays_src, "fn commandPaletteActivateAgentHistoryIndex(") orelse return error.Missing;
    const act = overlays_src[act_idx..];
    try std.testing.expect(std.mem.indexOf(u8, act, ".copilot)") != null);
    try std.testing.expect(std.mem.indexOf(u8, act, "loadCopilotConversationById(") != null);
}
