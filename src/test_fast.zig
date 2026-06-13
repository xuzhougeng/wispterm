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

test {
    _ = @import("input/command_dispatch.zig");
    _ = @import("input/click_tracker.zig");
    _ = @import("input/hit_test.zig");
    _ = @import("input/mouse_wheel_scroll.zig");
    _ = @import("input/mouse_report.zig");
    _ = @import("input/preview_path.zig");
    _ = @import("input/ls_path_context.zig");
    _ = @import("input/terminal_link_action.zig");
    _ = @import("input/underline_span.zig");
    _ = @import("input/file_drop_path.zig");
    _ = @import("input/sdl_keymap.zig");
    _ = @import("renderer/overlays/profile_codec.zig");
    _ = @import("renderer/overlays/transfer_toast_model.zig");
    _ = @import("renderer/overlays/update_prompt_model.zig");
    _ = @import("renderer/overlays/whats_new_model.zig");
    _ = @import("agent_detect_throttle.zig");
    _ = @import("renderer/ui_batch.zig");
    _ = @import("close_confirm.zig");
    _ = @import("command_palette_model.zig");
    _ = @import("command_center_state.zig");
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
    _ = @import("port_forward_rule.zig");
    _ = @import("ssh_profile_store.zig");
    _ = @import("port_forward_manager.zig");
    _ = @import("port_forwarding.zig");
    _ = @import("openssh_config_import.zig");
    _ = @import("apprt/window_drag_region.zig");
    _ = @import("apprt/window_registry.zig");
    _ = @import("appwindow/active_tab.zig");
    _ = @import("appwindow/frame_latency.zig");
    _ = @import("appwindow/render_gate.zig");
    _ = @import("scp.zig");
    _ = @import("surface_registry.zig");
    _ = @import("png_dimensions.zig");
    _ = @import("pdf_preview.zig");
    _ = @import("file_backend.zig");
    _ = @import("file_explorer.zig");
    _ = @import("i18n.zig");
    _ = @import("markdown_text.zig");
    _ = @import("ai_chat_composer_layout.zig");
    _ = @import("ai_chat_input_text.zig");
    _ = @import("ai_chat_composer.zig");
    _ = @import("web_search.zig");
    _ = @import("agent_prompt_answer.zig");
    _ = @import("web_read.zig");
    _ = @import("web_read_cache.zig");
    _ = @import("pubmed.zig");
    _ = @import("ai_loop_schedule.zig");
    _ = @import("ai_skill_distill.zig");
    _ = @import("ai_history_types.zig");
    _ = @import("ai_history_provider_codex.zig");
    _ = @import("ai_history_provider_claude.zig");
    _ = @import("ai_history_provider_reasonix.zig");
    _ = @import("ai_history_source.zig");
    _ = @import("ai_history_cache.zig");
    _ = @import("skill_scan.zig");
    _ = @import("ssh_error.zig");
    _ = @import("skill_inventory.zig");
    _ = @import("skill_inventory_cache.zig");
    _ = @import("skill_center.zig");
    _ = @import("renderer/skill_center_renderer.zig");
    _ = @import("renderer/port_forwarding_renderer.zig");
    _ = @import("skill_pairing.zig");
    _ = @import("skill_transfer_cmd.zig");
    _ = @import("skill_transfer.zig");
    _ = @import("skill_diff.zig");
    _ = @import("text_wrap.zig");
    _ = @import("ai_history_resume.zig");
    _ = @import("ai_history_session.zig");
    _ = @import("browser_url.zig");
    _ = @import("ssh_prompt.zig");
    _ = @import("selection_unit.zig");
    _ = @import("scrollbar_model.zig");
    _ = @import("resize_gate.zig");
    _ = @import("preview_token.zig");
    _ = @import("ime_caret.zig");
    _ = @import("sync_output.zig");
    _ = @import("agent_history.zig");
    _ = @import("render_diagnostics.zig");
    _ = @import("notification.zig");
    _ = @import("clipboard_osc52.zig");
    _ = @import("renderer/gpu/backend.zig");
    _ = @import("renderer/cell_geometry.zig");
    _ = @import("renderer/titlebar_layout.zig");
    _ = @import("ai_chat_layout.zig");
    _ = @import("ai_chat_types.zig");
    _ = @import("ai_sidebar.zig");
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
    _ = @import("ai_chat_title.zig");
    _ = @import("command_registry.zig");
    _ = @import("jupyter_detect.zig");
    _ = @import("jupyter_picker.zig");
    _ = @import("html_server_model.zig");
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
