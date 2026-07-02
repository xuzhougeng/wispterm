//! Test entry point — imports modules containing unit tests.
//! Run with: zig build test

const build_options = @import("build_options");
const std = @import("std");

const AppTestShard = enum {
    all,
    assistant,
    app,
    platform,
    input_renderer,
    integrations,
    behavior,
};

const app_test_shard = std.meta.stringToEnum(AppTestShard, build_options.app_test_shard) orelse
    @compileError("unknown app_test_shard build option: " ++ build_options.app_test_shard);

fn activeAppTestShard(comptime shard: AppTestShard) bool {
    return app_test_shard == .all or app_test_shard == shard;
}

comptime {
    if (activeAppTestShard(.assistant)) {
        _ = @import("assistant/conversation/session.zig");
        _ = @import("assistant/conversation/request.zig");
        _ = @import("assistant/conversation/model_switch.zig");
        _ = @import("agent_tools/mod.zig");
        _ = @import("assistant/conversation/skills.zig");
        _ = @import("assistant/conversation/types.zig");
        _ = @import("agent/access.zig");
        _ = @import("assistant/conversation/protocol.zig");
        _ = @import("assistant/conversation/markdown.zig");
        _ = @import("agent/history.zig");
        _ = @import("assistant/conversation/composer_layout.zig");
        _ = @import("assistant/conversation/input_text.zig");
        _ = @import("assistant/conversation/composer.zig");
        _ = @import("assistant/conversation/presentation.zig");
        _ = @import("assistant/loop/schedule.zig");
        _ = @import("assistant/loop/store.zig");
        _ = @import("terminal_agents/sessions/types.zig");
        _ = @import("terminal_agents/sessions/provider_codex.zig");
        _ = @import("terminal_agents/sessions/provider_claude.zig");
        _ = @import("terminal_agents/sessions/provider_reasonix.zig");
        _ = @import("terminal_agents/sessions/source.zig");
        _ = @import("terminal_agents/sessions/cache.zig");
        _ = @import("terminal_agents/sessions/resume.zig");
        _ = @import("terminal_agents/sessions/session.zig");
        _ = @import("renderer/terminal_agents/sessions.zig");
        _ = @import("terminal_agents/detector.zig");
        _ = @import("terminal_agents/prompt_answer.zig");
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
        _ = @import("agent_tools/weixin.zig");
    }

    if (activeAppTestShard(.app)) {
        _ = @import("Surface.zig");
        _ = @import("termio/Mailbox.zig");
        _ = @import("App.zig");
        _ = @import("AppWindow.zig");
        _ = @import("surface_registry.zig");
        _ = @import("preview/png_dimensions.zig");
        _ = @import("appwindow/flush_scheduler.zig");
        _ = @import("appwindow/window_state.zig");
        _ = @import("appwindow/remote_state.zig");
        _ = @import("appwindow/state.zig");
        _ = @import("appwindow/split_layout.zig");
        _ = @import("appwindow/tab.zig");
        _ = @import("appwindow/thread_message.zig");
        _ = @import("ssh/scp.zig");
        _ = @import("diag_log.zig");
        _ = if (build_options.webview) @import("browser/panel.zig") else @import("browser/panel_stub.zig");
        _ = @import("browser/url.zig");
        _ = @import("build_guards.zig");
        _ = @import("command/center_state.zig");
        _ = @import("command/palette_model.zig");
        _ = @import("ssh/openssh_config_import.zig");
        _ = @import("config.zig");
        _ = @import("i18n.zig");
        _ = @import("config_watcher.zig");
        _ = @import("file_backend.zig");
        _ = @import("file_explorer.zig");
        _ = @import("research/commands.zig");
        _ = @import("tools/first_party.zig");
    }

    if (activeAppTestShard(.input_renderer)) {
        _ = @import("input.zig");
        _ = @import("input/clipboard.zig");
        _ = @import("clipboard_osc52.zig");
        _ = @import("input/click_tracker.zig");
        _ = @import("input/mouse_dispatch.zig");
        _ = @import("input/command_dispatch.zig");
        _ = @import("input/hit_test.zig");
        _ = @import("input/key.zig");
        _ = @import("input/preview_source.zig");
        _ = @import("input/preview_image_drag.zig");
        _ = @import("input_shortcuts.zig");
        _ = @import("html/server.zig");
        _ = @import("keybind.zig");
        _ = @import("kitty_graphics_unit.zig");
        _ = @import("renderer/cell_update_unit.zig");
        _ = @import("renderer/ui_batch.zig");
        _ = @import("input/underline_span.zig");
        _ = @import("surface_output_unit.zig");
        _ = @import("link_open.zig");
        _ = @import("preview/markdown.zig");
        _ = @import("markdown_text.zig");
        _ = @import("memory_debug.zig");
        _ = @import("wispterm_docs.zig");
    }

    if (activeAppTestShard(.platform)) {
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
    }

    if (activeAppTestShard(.integrations)) {
        _ = @import("preview/token.zig");
        _ = @import("quick_terminal.zig");
        _ = @import("remote_client.zig");
        _ = @import("remote_snapshot.zig");
        _ = @import("weixin/types.zig");
        _ = @import("weixin/state_store.zig");
        _ = @import("weixin/binding.zig");
        _ = @import("chatops/control.zig");
        _ = @import("chatops/router.zig");
        _ = @import("chatops/reply_progress.zig");
        _ = @import("weixin/ilink_codec.zig");
        _ = @import("weixin/media_inbound.zig");
        _ = @import("weixin/ilink_client.zig");
        _ = @import("weixin/poller.zig");
        _ = @import("weixin/controller.zig");
        _ = @import("weixin/qr_code.zig");
        _ = @import("weixin/qr_panel.zig");
        _ = @import("chatops/approval_reply.zig");
        _ = @import("chatops/question_reply.zig");
        _ = @import("chatops/session_list.zig");
        _ = @import("renderer/overlay_keys.zig");
        _ = @import("close_confirm.zig");
        _ = @import("renderer/overlays.zig");
        _ = @import("renderer/overlays/confirm_modals.zig");
        _ = @import("renderer/overlays/command_palette_input.zig");
        _ = @import("renderer/overlays/command_palette_layout.zig");
        _ = @import("renderer/overlays/settings_page.zig");
        _ = @import("renderer/overlays/ssh_profiles.zig");
        _ = @import("renderer/overlays/assistant_profiles.zig");
        _ = @import("renderer/overlays/session_launcher.zig");
        _ = @import("renderer/overlays/state.zig");
        _ = @import("renderer/overlays/toasts.zig");
        _ = @import("selection_unit.zig");
        _ = @import("session_persist.zig");
        _ = @import("agent/memory.zig");
        _ = @import("skill/registry.zig");
        _ = @import("skill/scan.zig");
        _ = @import("skill/install.zig");
        _ = @import("skill/local_fs.zig");
        _ = @import("skill/center.zig");
        _ = @import("renderer/skill_center_renderer.zig");
        _ = @import("port_forward/rule.zig");
        _ = @import("ssh/profile_store.zig");
        _ = @import("port_forward/manager.zig");
        _ = @import("port_forward/forwarding.zig");
        _ = @import("renderer/port_forwarding_renderer.zig");
        _ = @import("command/registry.zig");
        _ = @import("tools/registry.zig");
        _ = @import("tools/import.zig");
        _ = @import("tools/skill_draft.zig");
        _ = @import("scrollbar_model.zig");
        _ = @import("assistant/conversation/scrollbar_model.zig");
        _ = @import("ssh/prompt.zig");
        _ = @import("ssh/tunnel.zig");
        _ = @import("startup_tabs.zig");
        _ = @import("split_tree.zig");
        _ = @import("preview/pane.zig");
        _ = @import("renderer/markdown_preview_renderer.zig");
        _ = @import("ui_perf.zig");
        _ = @import("update_check.zig");
        _ = @import("update_install.zig");
    }
}

comptime {
    if (activeAppTestShard(.behavior)) {
        _ = @import("test_main_behavior.zig");
    }
}
