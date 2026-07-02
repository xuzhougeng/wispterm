//! Fast native unit-test aggregator.
//!
//! `zig build test` builds and runs THIS file against the native host target.
//! It pulls in only platform-independent logic modules that have real unit
//! tests and compile without the heavy app graph (no `App.zig`/`AppWindow.zig`,
//! `ghostty-vt`, `xev`, or GL/win32 bindings). The goal is a sub-second inner
//! loop: editing a logic module reruns its tests in ~1s instead of forcing the
//! full `test_main` binary (99 modules + deps) to recompile.
//!
//! The complete suite — including the GUI binary and cross-compile checks —
//! lives behind `zig build test-full`.
//!
//! Only add modules here that (a) have unit tests worth running and (b) pass
//! natively. Platform-coupled modules whose tests assert Windows behavior
//! (e.g. `platform/window_backend`, `platform/pty_command_windows`) belong in
//! `test-full`, not here.

const build_options = @import("build_options");
const std = @import("std");
const app_metadata = @import("app_metadata.zig");

test "input ssh download surfaces missing connection and helper probe failures" {
    const input_source = @embedFile("input.zig");
    try std.testing.expect(std.mem.indexOf(u8, input_source, "\"SSH connection unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, input_source, "\"SSH helper unavailable\"") != null);
}

test "assistant conversation input routing owns keyboard target lookup" {
    const routing_source = @embedFile("input/assistant_conversation.zig");
    try std.testing.expect(std.mem.indexOf(u8, routing_source, "activeAiChat()") != null);
    try std.testing.expect(std.mem.indexOf(u8, routing_source, "activeCopilotSessionForInput()") != null);
    try std.testing.expect(std.mem.indexOf(u8, routing_source, ".copilot_sidebar") != null);

    const input_source = @embedFile("input.zig");
    try std.testing.expect(std.mem.indexOf(u8, input_source, "assistant_conversation.current(aiCopilotFocused())") != null);
}

test "remote file ssh helpers include short keepalive options" {
    const remote_file_source = @embedFile("platform/remote_file.zig");
    try std.testing.expect(std.mem.indexOf(u8, remote_file_source, "\"ServerAliveInterval=5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, remote_file_source, "\"ServerAliveCountMax=2\"") != null);
}

test "remote file capture helpers use process_runner" {
    const remote_file_source = @embedFile("platform/remote_file.zig");
    try std.testing.expect(std.mem.indexOf(u8, remote_file_source, "process_runner.runCapture") != null);
    try std.testing.expect(std.mem.indexOf(u8, remote_file_source, "child_output") == null);
}

test "SSH profile persistence is owned by ssh_profile_store" {
    const overlays_source = @embedFile("renderer/overlays.zig");
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "ssh_profile_store.loadProfiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "ssh_profile_store.saveProfiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "fn sshProfilesPath") == null);
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "decodeSshProfileLine") == null);
}

test "AI profile persistence is owned by assistant profile store" {
    const overlays_source = @embedFile("renderer/overlays.zig");
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "assistant_profile_store.loadProfiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "assistant_profile_store.saveProfiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "fn aiProfilesPath") == null);
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "decodeAiProfileLine") == null);
}

test "ai title worker rejects API error results" {
    const source = @embedFile("assistant/conversation/request.zig");
    const start = std.mem.indexOf(u8, source, "pub fn titleThreadMain") orelse return error.MissingTitleWorker;
    const rest = source[start..];
    const end = std.mem.indexOf(u8, rest, "pub fn summaryThreadMain") orelse return error.MissingSummaryWorker;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "result.api_error") != null);
}

test "ai title request does not use the old 64 token budget" {
    const source = @embedFile("assistant/conversation/session.zig");
    const start = std.mem.indexOf(u8, source, "fn buildTitleRequestLocked") orelse return error.MissingTitleRequestBuilder;
    const rest = source[start..];
    const end = std.mem.indexOf(u8, rest, "// titleThreadMain has moved") orelse return error.MissingTitleRequestEnd;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, ".max_tokens = 64") == null);
}

test "ssh browser tunnel readiness probes HTTP through the tunnel" {
    const source = @embedFile("ssh/tunnel.zig");
    {
        const start = std.mem.indexOf(u8, source, "fn waitForTunnelReady") orelse return error.MissingTunnelReady;
        const rest = source[start..];
        const end = std.mem.indexOf(u8, rest, "fn childHasExited") orelse return error.MissingTunnelReadyEnd;
        const body = rest[0..end];
        try std.testing.expect(std.mem.indexOf(u8, body, "localHttpReadyOnce") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "canConnectToLocalPort") == null);
    }
    {
        const start = std.mem.indexOf(u8, source, "fn findReusableTunnel") orelse return error.MissingTunnelReuse;
        const rest = source[start..];
        const end = std.mem.indexOf(u8, rest, "fn spawnSshTunnel") orelse return error.MissingTunnelReuseEnd;
        const body = rest[0..end];
        try std.testing.expect(std.mem.indexOf(u8, body, "localHttpReadyOnce") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "canConnectToLocalPort") == null);
    }
}

test "agent SSH connection resolver uses the surface registry, not tab threadlocals" {
    const source = @embedFile("appwindow/surface_snapshots.zig");
    const start = std.mem.indexOf(u8, source, "pub fn agentSshConnectionForSurface") orelse return error.MissingAgentSshResolver;
    const rest = source[start..];
    const end = std.mem.indexOf(u8, rest, "test \"agent SSH") orelse return error.MissingAgentSshResolverEnd;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "surface_registry.acquireById") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tab.g_") == null);
}

test "agent request disables worker snapshot fallback when UI capture fails" {
    const source = @embedFile("assistant/conversation/session.zig");
    const start = std.mem.indexOf(u8, source, "fn buildRequestLocked") orelse return error.MissingBuildRequestLocked;
    const rest = source[start..];
    const end = std.mem.indexOf(u8, rest, "var weixin_ctx") orelse return error.MissingBuildRequestSnapshotEnd;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "host.collectSnapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "catch null") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_host = null") != null);
}

test "App Feishu env fallback uses cross-platform env API" {
    const source = @embedFile("App.zig");
    const start = std.mem.indexOf(u8, source, "pub fn startFeishu") orelse return error.MissingStartFeishu;
    const rest = source[start..];
    const end = std.mem.indexOf(u8, rest, "pub fn startAgentControl") orelse return error.MissingStartFeishuEnd;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "std.posix.getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "std.process.getEnvVarOwned") != null);
}

test {
    _ = @import("input/command_dispatch.zig");
    _ = @import("input/file_explorer_keymap.zig");
    _ = @import("file_explorer/action.zig");
    _ = @import("input/effects.zig");
    _ = @import("input/dirty_guard.zig");
    _ = @import("input/command_palette_effect_guard.zig");
    _ = @import("input/overlay_effect_guard.zig");
    _ = @import("input/click_tracker.zig");
    _ = @import("input/hit_test.zig");
    _ = @import("input/mouse_wheel_scroll.zig");
    _ = @import("input/mouse_report.zig");
    _ = @import("input/mouse_dispatch.zig");
    _ = @import("input/preview_path.zig");
    _ = @import("input/preview_close_button.zig");
    _ = @import("input/ls_path_context.zig");
    _ = @import("input/terminal_link_action.zig");
    _ = @import("input/underline_span.zig");
    _ = @import("input/file_drop_path.zig");
    _ = @import("input/sdl_keymap.zig");
    _ = @import("ui/close_shortcut_confirm.zig");
    _ = @import("ui/window_metrics.zig");
    _ = @import("renderer/overlays/profile_codec.zig");
    _ = @import("renderer/overlays/command_palette_input.zig");
    _ = @import("renderer/overlays/command_palette_layout.zig");
    _ = @import("renderer/overlays/startup_shortcuts_layout.zig");
    _ = @import("renderer/overlays/settings_page_layout.zig");
    _ = @import("renderer/overlays/settings_page.zig");
    _ = @import("renderer/overlays/toasts.zig");
    _ = @import("renderer/overlays/confirm_modals.zig");
    _ = @import("renderer/overlays/ssh_profiles.zig");
    _ = @import("renderer/overlays/ssh_profiles_layout.zig");
    _ = @import("renderer/overlays/assistant_profiles.zig");
    _ = @import("renderer/overlays/feishu_config.zig");
    _ = @import("renderer/overlays/quick_ai_config.zig");
    _ = @import("renderer/overlays/mcp_servers.zig");
    _ = @import("assistant/quick_verify.zig");
    _ = @import("assistant/mcp_probe.zig");
    _ = @import("renderer/overlays/session_launcher.zig");
    _ = @import("renderer/overlays/state.zig");
    _ = @import("renderer/overlays/state_guard.zig");
    // Cross-cutting architecture ratchets (file size + global-state / import-hub /
    // side-effect freezes). See docs/decoupling-guide.md.
    _ = @import("source_guards/scan.zig");
    _ = @import("source_guards/file_size_guard.zig");
    _ = @import("source_guards/global_state_guard.zig");
    _ = @import("source_guards/import_hub_guard.zig");
    _ = @import("source_guards/side_effect_guard.zig");
    _ = @import("source_guards/process_runner_guard.zig");
    _ = @import("source_guards/agent_tools_guard.zig");
    _ = @import("source_guards/assistant_agent_boundary_guard.zig");
    _ = @import("source_guards/layered_dependency_guard.zig");
    _ = @import("source_guards/overlay_boundary_guard.zig");
    _ = @import("source_guards/input_feature_boundary_guard.zig");
    _ = @import("renderer/overlays/transfer_toast_model.zig");
    _ = @import("renderer/overlays/update_prompt_model.zig");
    _ = @import("renderer/overlays/whats_new_model.zig");
    _ = @import("renderer/ui_batch.zig");
    _ = @import("renderer/qr_panel_layout.zig");
    _ = @import("renderer/file_explorer_layout.zig");
    _ = @import("renderer/gpu/gl_backend_guard.zig");
    _ = @import("renderer/gpu/types.zig");
    _ = @import("close_confirm.zig");
    _ = @import("command/palette_model.zig");
    _ = @import("command/center_state.zig");
    _ = @import("command/palette_history_view.zig");
    _ = @import("platform/window_state_codec.zig");
    _ = @import("platform/dxgi_core.zig");
    _ = @import("platform/console_host_policy.zig");
    _ = @import("whats_new_gate.zig");
    _ = @import("startup_tabs.zig");
    _ = @import("config.zig");
    _ = @import("agent/config.zig");
    _ = @import("agent/access.zig");
    _ = @import("agent/file_edit.zig");
    _ = @import("agent/remote_filetool.zig");
    _ = @import("agent/file_copy.zig");
    _ = @import("ssh/connection.zig");
    _ = @import("tmux/control.zig");
    _ = @import("tmux/layout.zig");
    _ = @import("tmux/protocol_test.zig");
    _ = @import("tmux/session.zig");
    _ = @import("port_forward/rule.zig");
    _ = @import("ssh/profile_store.zig");
    _ = @import("port_forward/manager.zig");
    _ = @import("port_forward/forwarding.zig");
    _ = @import("ssh/openssh_config_import.zig");
    _ = @import("apprt/window_drag_region.zig");
    _ = @import("apprt/window_registry.zig");
    _ = @import("appwindow/active_tab.zig");
    _ = @import("appwindow/frame_latency.zig");
    _ = @import("appwindow/frame_scheduler.zig");
    _ = @import("appwindow/png_writer.zig");
    _ = @import("appwindow/render_gate.zig");
    _ = @import("appwindow/ui_screenshot.zig");
    _ = @import("appwindow/ui_effect.zig");
    _ = @import("appwindow/window_state.zig");
    _ = @import("appwindow/remote_state.zig");
    _ = @import("appwindow/state.zig");
    _ = @import("appwindow/state_guard.zig");
    _ = @import("appwindow/p3_1_guard.zig");
    _ = @import("ssh/scp.zig");
    _ = @import("surface_registry.zig");
    _ = @import("ctl/protocol.zig");
    _ = @import("ctl/discovery.zig");
    _ = @import("ctl/control.zig");
    _ = @import("ctl/server.zig");
    _ = @import("ctl/client.zig");
    _ = @import("ctl/transport.zig");
    _ = @import("ctl/ui_state.zig");
    _ = @import("preview/png_dimensions.zig");
    _ = @import("preview/pdf.zig");
    _ = @import("preview/gallery.zig");
    _ = @import("preview/diagnostics.zig");
    _ = @import("file_backend.zig");
    _ = @import("file_explorer.zig");
    _ = @import("i18n.zig");
    _ = @import("markdown_text.zig");
    _ = @import("assistant/conversation/composer_layout.zig");
    _ = @import("assistant/conversation/input_text.zig");
    _ = @import("assistant/conversation/composer.zig");
    _ = @import("composer_detail_wrap.zig");
    _ = @import("assistant/conversation/presentation.zig");
    _ = @import("agent_tools/args.zig");
    _ = @import("agent_tools/mod.zig");
    _ = @import("agent_tools/research.zig");
    _ = @import("agent_tools/knowledge.zig");
    _ = @import("agent_tools/memory.zig");
    _ = @import("agent_tools/output.zig");
    _ = @import("agent_tools/terminal.zig");
    _ = @import("agent_tools/sessions.zig");
    _ = @import("agent_tools/access.zig");
    _ = @import("agent_tools/files.zig");
    _ = @import("agent_tools/exec.zig");
    _ = @import("agent_tools/dynamic.zig");
    _ = @import("agent_tools/mcp_client.zig");
    _ = @import("agent_tools/mcp.zig");
    _ = @import("agent_tools/weixin.zig");
    _ = @import("research/commands.zig");
    _ = @import("research/web_search.zig");
    _ = @import("terminal_agents/prompt_answer.zig");
    _ = @import("tools/first_party.zig");
    _ = @import("research/web_read.zig");
    _ = @import("research/web_read_cache.zig");
    _ = @import("research/pubmed.zig");
    _ = @import("assistant/loop/schedule.zig");
    _ = @import("assistant/conversation/distill.zig");
    _ = @import("terminal_agents/sessions/types.zig");
    _ = @import("terminal_agents/sessions/provider_codex.zig");
    _ = @import("terminal_agents/sessions/provider_claude.zig");
    _ = @import("terminal_agents/sessions/provider_reasonix.zig");
    _ = @import("terminal_agents/sessions/source.zig");
    _ = @import("terminal_agents/sessions/cache.zig");
    _ = @import("skill/scan.zig");
    _ = @import("skill/install.zig");
    _ = @import("ssh/error.zig");
    _ = @import("skill/center.zig");
    _ = @import("renderer/skill_center_renderer.zig");
    _ = @import("renderer/port_forwarding_renderer.zig");
    _ = @import("skill/transfer_cmd.zig");
    _ = @import("skill/transfer.zig");
    _ = @import("skill/diff.zig");
    _ = @import("tools/skill_draft.zig");
    _ = @import("text_wrap.zig");
    _ = @import("terminal_agents/sessions/resume.zig");
    _ = @import("terminal_agents/sessions/session.zig");
    _ = @import("browser/url.zig");
    _ = @import("text_search.zig");
    _ = @import("ssh/prompt.zig");
    _ = @import("selection_unit.zig");
    _ = @import("scrollbar_model.zig");
    _ = @import("resize_gate.zig");
    _ = @import("preview/token.zig");
    _ = @import("ime_caret.zig");
    _ = @import("sync_output.zig");
    _ = @import("agent/history.zig");
    _ = @import("agent/history_store.zig");
    _ = @import("render_diagnostics.zig");
    _ = @import("diag_log.zig");
    _ = @import("notification.zig");
    _ = @import("clipboard_osc52.zig");
    _ = @import("renderer/gpu/backend.zig");
    _ = @import("renderer/cell_geometry.zig");
    _ = @import("renderer/titlebar_layout.zig");
    _ = @import("assistant/conversation/layout.zig");
    _ = @import("assistant/conversation/types.zig");
    _ = @import("assistant/profile/store.zig");
    _ = @import("assistant/sidebar/panel.zig");
    _ = @import("assistant/sidebar/hint_gate.zig");
    _ = @import("appwindow/flush_scheduler.zig");
    _ = @import("appwindow/resize_throttle.zig");
    _ = @import("termio/read_coalesce.zig");
    _ = @import("assistant/conversation/protocol.zig");
    _ = @import("weixin/types.zig");
    _ = @import("weixin/ilink_codec.zig");
    _ = @import("weixin/ilink_client.zig");
    _ = @import("weixin/media.zig");
    _ = @import("weixin/binding.zig");
    _ = @import("chatops/approval_reply.zig");
    _ = @import("chatops/question_reply.zig");
    _ = @import("chatops/router.zig");
    _ = @import("feishu/types.zig");
    _ = @import("feishu/pbbp2.zig");
    _ = @import("feishu/ws.zig");
    _ = @import("feishu/rest.zig");
    _ = @import("feishu/codec.zig");
    _ = @import("feishu/binding.zig");
    _ = @import("feishu/longconn.zig");
    _ = @import("feishu/controller.zig");
    _ = @import("feishu/progress.zig");
    _ = @import("feishu/registration.zig");
    _ = @import("feishu/registration_panel.zig");
    _ = @import("feishu/card.zig");
    _ = @import("feishu/media.zig");
    _ = @import("assistant/conversation/title.zig");
    _ = @import("assistant/conversation/model_switch.zig");
    _ = @import("command/registry.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/mcp_registry.zig");
    _ = @import("tools/import.zig");
    // Unified subprocess lifecycle: spawn → concurrent drain → timeout/cancel →
    // reap-exactly-once. Spawn-based tests gate on non-Windows; type guards run
    // everywhere.
    _ = @import("process_runner.zig");
    _ = @import("platform/process_group.zig");
    _ = @import("terminal_agents/detector.zig");
    _ = @import("terminal_agents/integration_prompt.zig");
    _ = @import("jupyter/detect.zig");
    _ = @import("jupyter/picker.zig");
    _ = @import("assistant/sidebar/picker.zig");
    _ = @import("html/server_model.zig");
    // Platform-aware agent prompt: pure string constants, no heavy deps.
    _ = @import("platform/agent_prompt.zig");
    // Pure login-shell argv logic (macOS bash/.bashrc fix). OS-agnostic, so it
    // runs here on the native host rather than in the POSIX-only exec path.
    _ = @import("platform/login_shell.zig");
    // Pure OS/2 weight → fontconfig FC_WEIGHT_* mapping; std-only, no fontconfig dep.
    _ = @import("platform/font_weight_fc.zig");
    // Generic POSIX SSH/WSL command builder: asserts native (non-Windows)
    // command-line shapes, so it runs here rather than in test-full's Windows
    // cross-compile path. (The Windows backend stays in test-full.)
    if (@import("builtin").os.tag != .windows) {
        _ = @import("platform/pty_command_unsupported.zig");
    }
}
