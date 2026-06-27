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

test "AI profile persistence is owned by ai_profile_store" {
    const overlays_source = @embedFile("renderer/overlays.zig");
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "ai_profile_store.loadProfiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "ai_profile_store.saveProfiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "fn aiProfilesPath") == null);
    try std.testing.expect(std.mem.indexOf(u8, overlays_source, "decodeAiProfileLine") == null);
}

test "ai title worker rejects API error results" {
    const source = @embedFile("ai_chat_request.zig");
    const start = std.mem.indexOf(u8, source, "pub fn titleThreadMain") orelse return error.MissingTitleWorker;
    const rest = source[start..];
    const end = std.mem.indexOf(u8, rest, "pub fn summaryThreadMain") orelse return error.MissingSummaryWorker;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "result.api_error") != null);
}

test "ai title request does not use the old 64 token budget" {
    const source = @embedFile("ai_chat.zig");
    const start = std.mem.indexOf(u8, source, "fn buildTitleRequestLocked") orelse return error.MissingTitleRequestBuilder;
    const rest = source[start..];
    const end = std.mem.indexOf(u8, rest, "// titleThreadMain has moved") orelse return error.MissingTitleRequestEnd;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, ".max_tokens = 64") == null);
}

test "ssh browser tunnel readiness probes HTTP through the tunnel" {
    const source = @embedFile("ssh_tunnel.zig");
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
    const source = @embedFile("ai_chat.zig");
    const start = std.mem.indexOf(u8, source, "fn buildRequestLocked") orelse return error.MissingBuildRequestLocked;
    const rest = source[start..];
    const end = std.mem.indexOf(u8, rest, "var weixin_ctx") orelse return error.MissingBuildRequestSnapshotEnd;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "host.collectSnapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "catch null") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_host = null") != null);
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
    _ = @import("renderer/overlays/settings_page.zig");
    _ = @import("renderer/overlays/toasts.zig");
    _ = @import("renderer/overlays/confirm_modals.zig");
    _ = @import("renderer/overlays/ssh_profiles.zig");
    _ = @import("renderer/overlays/ssh_profiles_layout.zig");
    _ = @import("renderer/overlays/ai_profiles.zig");
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
    _ = @import("source_guards/layered_dependency_guard.zig");
    _ = @import("source_guards/overlay_boundary_guard.zig");
    _ = @import("source_guards/input_feature_boundary_guard.zig");
    _ = @import("renderer/overlays/transfer_toast_model.zig");
    _ = @import("renderer/overlays/update_prompt_model.zig");
    _ = @import("renderer/overlays/whats_new_model.zig");
    _ = @import("renderer/ui_batch.zig");
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
    _ = @import("ai_agent_config.zig");
    _ = @import("ai_agent_access.zig");
    _ = @import("agent_file_edit.zig");
    _ = @import("agent_file_copy.zig");
    _ = @import("ssh_connection.zig");
    _ = @import("tmux/control.zig");
    _ = @import("tmux/layout.zig");
    _ = @import("tmux/protocol_test.zig");
    _ = @import("tmux/session.zig");
    _ = @import("port_forward/rule.zig");
    _ = @import("ssh_profile_store.zig");
    _ = @import("port_forward/manager.zig");
    _ = @import("port_forward/forwarding.zig");
    _ = @import("openssh_config_import.zig");
    _ = @import("apprt/window_drag_region.zig");
    _ = @import("apprt/window_registry.zig");
    _ = @import("appwindow/active_tab.zig");
    _ = @import("appwindow/frame_latency.zig");
    _ = @import("appwindow/frame_scheduler.zig");
    _ = @import("appwindow/render_gate.zig");
    _ = @import("appwindow/ui_effect.zig");
    _ = @import("appwindow/window_state.zig");
    _ = @import("appwindow/remote_state.zig");
    _ = @import("appwindow/state.zig");
    _ = @import("appwindow/state_guard.zig");
    _ = @import("appwindow/p3_1_guard.zig");
    _ = @import("scp.zig");
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
    _ = @import("ai_chat_composer_layout.zig");
    _ = @import("ai_chat_input_text.zig");
    _ = @import("ai_chat_composer.zig");
    _ = @import("composer_detail_wrap.zig");
    _ = @import("agent_tools/args.zig");
    _ = @import("agent_tools/research.zig");
    _ = @import("agent_tools/knowledge.zig");
    _ = @import("research/commands.zig");
    _ = @import("research/web_search.zig");
    _ = @import("agent_prompt_answer.zig");
    _ = @import("tools/first_party.zig");
    _ = @import("research/web_read.zig");
    _ = @import("research/web_read_cache.zig");
    _ = @import("research/pubmed.zig");
    _ = @import("ai_loop_schedule.zig");
    _ = @import("ai_skill_distill.zig");
    _ = @import("ai_history/types.zig");
    _ = @import("ai_history/provider_codex.zig");
    _ = @import("ai_history/provider_claude.zig");
    _ = @import("ai_history/provider_reasonix.zig");
    _ = @import("ai_history/source.zig");
    _ = @import("ai_history/cache.zig");
    _ = @import("skill/scan.zig");
    _ = @import("skill/install.zig");
    _ = @import("ssh_error.zig");
    _ = @import("skill/center.zig");
    _ = @import("renderer/skill_center_renderer.zig");
    _ = @import("renderer/port_forwarding_renderer.zig");
    _ = @import("skill/transfer_cmd.zig");
    _ = @import("skill/transfer.zig");
    _ = @import("skill/diff.zig");
    _ = @import("tools/skill_draft.zig");
    _ = @import("text_wrap.zig");
    _ = @import("ai_history/resume.zig");
    _ = @import("ai_history/session.zig");
    _ = @import("browser/url.zig");
    _ = @import("text_search.zig");
    _ = @import("ssh_prompt.zig");
    _ = @import("selection_unit.zig");
    _ = @import("scrollbar_model.zig");
    _ = @import("resize_gate.zig");
    _ = @import("preview/token.zig");
    _ = @import("ime_caret.zig");
    _ = @import("sync_output.zig");
    _ = @import("agent_history.zig");
    _ = @import("agent_history_store.zig");
    _ = @import("render_diagnostics.zig");
    _ = @import("diag_log.zig");
    _ = @import("notification.zig");
    _ = @import("clipboard_osc52.zig");
    _ = @import("renderer/gpu/backend.zig");
    _ = @import("renderer/cell_geometry.zig");
    _ = @import("renderer/titlebar_layout.zig");
    _ = @import("ai_chat_layout.zig");
    _ = @import("ai_chat_types.zig");
    _ = @import("ai_profile_store.zig");
    _ = @import("ai_sidebar.zig");
    _ = @import("copilot_hint_gate.zig");
    _ = @import("appwindow/flush_scheduler.zig");
    _ = @import("appwindow/resize_throttle.zig");
    _ = @import("termio/read_coalesce.zig");
    _ = @import("ai_chat_protocol.zig");
    _ = @import("weixin/types.zig");
    _ = @import("weixin/ilink_codec.zig");
    _ = @import("weixin/ilink_client.zig");
    _ = @import("weixin/media.zig");
    _ = @import("weixin/binding.zig");
    _ = @import("weixin/approval_reply.zig");
    _ = @import("weixin/question_reply.zig");
    _ = @import("ai_chat_title.zig");
    _ = @import("ai_model_switch.zig");
    _ = @import("command/registry.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/import.zig");
    // Unified subprocess lifecycle: spawn → concurrent drain → timeout/cancel →
    // reap-exactly-once. Spawn-based tests gate on non-Windows; type guards run
    // everywhere.
    _ = @import("process_runner.zig");
    _ = @import("platform/process_group.zig");
    _ = @import("agent_detector.zig");
    _ = @import("agent_integration_prompt.zig");
    _ = @import("jupyter/detect.zig");
    _ = @import("jupyter/picker.zig");
    _ = @import("copilot_picker.zig");
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
