//! Test entry point — imports modules containing unit tests.
//! Run with: zig build test

const build_options = @import("build_options");
const std = @import("std");
const app_metadata = @import("app_metadata.zig");
const command_center_state = @import("command_center_state.zig");

comptime {
    _ = @import("ai_chat.zig");
    _ = @import("ai_chat_request.zig");
    _ = @import("ai_model_switch.zig");
    _ = @import("ai_chat_tools.zig");
    _ = @import("ai_chat_skills.zig");
    _ = @import("ai_chat_types.zig");
    _ = @import("ai_agent_access.zig");
    _ = @import("ai_chat_protocol.zig");
    _ = @import("ai_chat_markdown.zig");
    _ = @import("agent_history.zig");
    _ = @import("ai_chat_composer_layout.zig");
    _ = @import("ai_chat_input_text.zig");
    _ = @import("ai_chat_composer.zig");
    _ = @import("ai_loop_schedule.zig");
    _ = @import("ai_loop_store.zig");
    _ = @import("ai_history_types.zig");
    _ = @import("ai_history_provider_codex.zig");
    _ = @import("ai_history_provider_claude.zig");
    _ = @import("ai_history_provider_reasonix.zig");
    _ = @import("ai_history_source.zig");
    _ = @import("ai_history_cache.zig");
    _ = @import("ai_history_resume.zig");
    _ = @import("ai_history_session.zig");
    _ = @import("renderer/ai_history_renderer.zig");
    _ = @import("agent_detector.zig");
    _ = @import("Surface.zig");
    _ = @import("agent_prompt_answer.zig");
    _ = @import("App.zig");
    _ = @import("AppWindow.zig");
    _ = @import("surface_registry.zig");
    _ = @import("png_dimensions.zig");
    _ = @import("appwindow/flush_scheduler.zig");
    _ = @import("appwindow/window_state.zig");
    _ = @import("appwindow/remote_state.zig");
    _ = @import("appwindow/state.zig");
    _ = @import("appwindow/split_layout.zig");
    _ = @import("appwindow/tab.zig");
    _ = @import("appwindow/thread_message.zig");
    _ = @import("scp.zig");
    _ = @import("diag_log.zig");
    _ = if (build_options.webview) @import("browser_panel.zig") else @import("browser_panel_stub.zig");
    _ = @import("browser_url.zig");
    _ = @import("build_guards.zig");
    _ = @import("command_center_state.zig");
    _ = @import("command_palette_model.zig");
    _ = @import("openssh_config_import.zig");
    _ = @import("config.zig");
    _ = @import("i18n.zig");
    _ = @import("config_watcher.zig");
    _ = @import("file_backend.zig");
    _ = @import("file_explorer.zig");
    _ = @import("first_party_tools.zig");
    _ = @import("input.zig");
    _ = @import("input/clipboard.zig");
    _ = @import("clipboard_osc52.zig");
    _ = @import("input/click_tracker.zig");
    _ = @import("input/command_dispatch.zig");
    _ = @import("input/hit_test.zig");
    _ = @import("input/key.zig");
    _ = @import("input/preview_source.zig");
    _ = @import("input/preview_image_drag.zig");
    _ = @import("input_shortcuts.zig");
    _ = @import("html_server.zig");
    _ = @import("keybind.zig");
    _ = @import("kitty_graphics_unit.zig");
    _ = @import("renderer/cell_update_unit.zig");
    _ = @import("renderer/ui_batch.zig");
    _ = @import("input/underline_span.zig");
    _ = @import("surface_output_unit.zig");
    _ = @import("link_open.zig");
    _ = @import("markdown_preview.zig");
    _ = @import("markdown_text.zig");
    _ = @import("memory_debug.zig");
    _ = @import("wispterm_docs.zig");
    _ = @import("platform/atomic_file.zig");
    _ = @import("platform/clipboard.zig");
    _ = @import("platform/com.zig");
    _ = @import("platform/console.zig");
    _ = @import("platform/config_watcher.zig");
    _ = @import("platform/cursor.zig");
    _ = @import("platform/display.zig");
    _ = @import("platform/dirs.zig");
    _ = @import("platform/editor.zig");
    _ = @import("platform/file_dialog.zig");
    _ = @import("platform/font_backend.zig");
    _ = @import("platform/global_hotkey.zig");
    _ = @import("platform/input_events.zig");
    _ = @import("platform/agent_prompt.zig");
    _ = @import("platform/apprt_win32_guard.zig");
    _ = @import("renderer/gpu/gl_backend_guard.zig");
    _ = @import("platform/local_path.zig");
    _ = @import("platform/memory.zig");
    _ = @import("platform/notifications.zig");
    _ = @import("platform/open_url.zig");
    _ = @import("platform/process.zig");
    _ = @import("platform/console_host_policy.zig");
    _ = @import("platform/pty.zig");
    switch (@import("builtin").os.tag) {
        .windows, .linux, .macos => {
            _ = @import("platform/pty_virtual_test.zig");
            _ = @import("tmux/pane_io_test.zig");
            _ = @import("appwindow/tmux_bridge.zig");
        },
        else => {},
    }
    // The posix tmux controller (drop/reconnect decision) is posix-only; it uses
    // std.posix poll/read paths that don't compile for the windows app target.
    switch (@import("builtin").os.tag) {
        .linux, .macos => {
            _ = @import("appwindow/tmux_controller_posix.zig");
        },
        else => {},
    }
    _ = @import("platform/pty_command.zig");
    _ = @import("platform/remote_file.zig");
    _ = @import("platform/remote_transport.zig");
    _ = @import("platform/session_lock.zig");
    _ = @import("platform/text.zig");
    _ = @import("platform/thread_control.zig");
    _ = @import("platform/threading.zig");
    _ = @import("platform/update_package.zig");
    _ = @import("platform/webview.zig");
    _ = @import("platform/window.zig");
    _ = @import("platform/window_backend.zig");
    _ = @import("platform/window_state.zig");
    _ = @import("platform/wsl.zig");
    _ = @import("preview_token.zig");
    _ = @import("quick_terminal.zig");
    _ = @import("remote_client.zig");
    _ = @import("remote_snapshot.zig");
    _ = @import("weixin/types.zig");
    _ = @import("weixin/state_store.zig");
    _ = @import("weixin/binding.zig");
    _ = @import("weixin/control.zig");
    _ = @import("weixin/agent.zig");
    _ = @import("weixin/reply_progress.zig");
    _ = @import("weixin/ilink_codec.zig");
    _ = @import("weixin/media_inbound.zig");
    _ = @import("weixin/ilink_client.zig");
    _ = @import("weixin/poller.zig");
    _ = @import("weixin/controller.zig");
    _ = @import("weixin/qr_code.zig");
    _ = @import("weixin/qr_panel.zig");
    _ = @import("weixin/approval_reply.zig");
    _ = @import("weixin/question_reply.zig");
    _ = @import("renderer/overlay_keys.zig");
    _ = @import("close_confirm.zig");
    _ = @import("renderer/overlays.zig");
    _ = @import("renderer/overlays/confirm_modals.zig");
    _ = @import("renderer/overlays/command_palette_input.zig");
    _ = @import("renderer/overlays/settings_page.zig");
    _ = @import("renderer/overlays/ssh_profiles.zig");
    _ = @import("renderer/overlays/ai_profiles.zig");
    _ = @import("renderer/overlays/session_launcher.zig");
    _ = @import("renderer/overlays/state.zig");
    _ = @import("renderer/overlays/toasts.zig");
    _ = @import("selection_unit.zig");
    _ = @import("session_persist.zig");
    _ = @import("agent_memory.zig");
    _ = @import("skill_registry.zig");
    _ = @import("skill_scan.zig");
    _ = @import("skill_install.zig");
    _ = @import("skill_local_fs.zig");
    _ = @import("skill_center.zig");
    _ = @import("renderer/skill_center_renderer.zig");
    _ = @import("port_forward_rule.zig");
    _ = @import("ssh_profile_store.zig");
    _ = @import("port_forward_manager.zig");
    _ = @import("port_forwarding.zig");
    _ = @import("renderer/port_forwarding_renderer.zig");
    _ = @import("command_registry.zig");
    _ = @import("tool_registry.zig");
    _ = @import("tool_import.zig");
    _ = @import("tool_skill_draft.zig");
    _ = @import("scrollbar_model.zig");
    _ = @import("ai_chat_scrollbar_model.zig");
    _ = @import("ssh_prompt.zig");
    _ = @import("ssh_tunnel.zig");
    _ = @import("startup_tabs.zig");
    _ = @import("split_tree.zig");
    _ = @import("preview_pane.zig");
    _ = @import("renderer/markdown_preview_renderer.zig");
    _ = @import("ui_perf.zig");
    _ = @import("update_check.zig");
    _ = @import("update_install.zig");
}

test "app version metadata is exposed for CLI and command center" {
    const expected_version = "1.29.0";
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

test "copilot conversation picker has a keybind action and dispatch" {
    const kb_src = @embedFile("keybind.zig");
    try std.testing.expect(std.mem.indexOf(u8, kb_src, "copilot_conversation_picker") != null);
    const input_src = @embedFile("input.zig");
    try std.testing.expect(std.mem.indexOf(u8, input_src, ".copilot_conversation_picker =>") != null);
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
    const aw_src = @embedFile("AppWindow.zig");
    const load_idx = std.mem.indexOf(u8, aw_src, "pub fn loadCopilotConversationById(") orelse return error.Missing;
    try std.testing.expect(std.mem.indexOf(u8, aw_src[load_idx..], "switchToCopilotTabBySessionId(") != null);
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
