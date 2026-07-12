//! AppWindow — per-window state and rendering.
//!
//! This module contains all the terminal rendering, input handling, and
//! per-window state. Currently uses module-level globals for state, which
//! will be converted to struct fields in a future refactoring step.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const freetype = @import("freetype");
const Config = @import("config.zig");
const build_options = @import("build_options");
const Surface = @import("Surface.zig");
const SplitTree = @import("split_tree.zig");
const PreviewPane = @import("preview/pane.zig");
const renderer = @import("renderer.zig");
const window_backend = @import("platform/window_backend.zig");
const App = @import("App.zig");
const Renderer = @import("renderer/Renderer.zig");
const weixin_control = @import("chatops/control.zig");
const ctl_control = @import("ctl/control.zig");
const memory_debug = @import("memory_debug.zig");
const agent_history = @import("agent/history.zig");
const agent_history_store = @import("agent/history_store.zig");
const close_confirm = @import("close_confirm.zig");
const font_backend = @import("platform/font_backend.zig");
const platform_display = @import("platform/display.zig");
const platform_dirs = @import("platform/dirs.zig");
const platform_atomic_file = @import("platform/atomic_file.zig");
const platform_file_dialog = @import("platform/file_dialog.zig");
const platform_global_hotkey = @import("platform/global_hotkey.zig");
const platform_menu = @import("platform/menu.zig");
const platform_notifications = @import("platform/notifications.zig");
const notif_mod = @import("notification.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const copilot_hint_gate = @import("assistant/sidebar/hint_gate.zig");
const platform_window_state = @import("platform/window_state.zig");
const platform_wsl = @import("platform/wsl.zig");
const startup_tabs = @import("startup_tabs.zig");
const session_persist = @import("session_persist.zig");
const quick_terminal = @import("quick_terminal.zig");
const keybind = @import("keybind.zig");
const thread_message = @import("appwindow/thread_message.zig");
const skill_center_actions = @import("appwindow/skill_center_actions.zig");
const copilot_sidebar = @import("appwindow/copilot_sidebar.zig");
const appwindow_state = @import("appwindow/state.zig");
const render_diagnostics = @import("render_diagnostics.zig");
const ime_caret = @import("ime_caret.zig");
const hit_test = @import("input/hit_test.zig");
pub const ai_chat = @import("assistant/conversation/session.zig");
const ai_chat_types = @import("assistant/conversation/types.zig");
const ai_history_cache = @import("terminal_agents/sessions/cache.zig");
const ai_history_resume = @import("terminal_agents/sessions/resume.zig");
const ai_history_markdown = @import("terminal_agents/sessions/markdown.zig");
const ai_loop_store = @import("assistant/loop/store.zig");
const ai_history_types = @import("terminal_agents/sessions/types.zig");
const ai_history_session = @import("terminal_agents/sessions/session.zig");
const ai_history_source = @import("terminal_agents/sessions/source.zig");
pub const skill_center = @import("skill/center.zig");
const skill_install = @import("skill/install.zig");
const update_install = @import("update_install.zig");
const clipboard = @import("input/clipboard.zig");
const port_forwarding = @import("port_forward/forwarding.zig");
const port_forward_manager = @import("port_forward/manager.zig");
const port_forward_rule = @import("port_forward/rule.zig");
const ssh_profile_store = @import("ssh/profile_store.zig");
const skill_scan = @import("skill/scan.zig");
const skill_local_fs = @import("skill/local_fs.zig");
const skill_transfer_cmd = @import("skill/transfer_cmd.zig");
const tool_import = @import("tools/import.zig");
const tool_registry = @import("tools/registry.zig");
const tool_skill_draft = @import("tools/skill_draft.zig");
const first_party_tools = @import("tools/first_party.zig");
const ai_chat_request = @import("assistant/conversation/request.zig");
const remote_file = @import("platform/remote_file.zig");
const ssh_connection = @import("ssh/connection.zig");
const skill_transfer = @import("skill/transfer.zig");
const skill_diff = @import("skill/diff.zig");
const scp = @import("ssh/scp.zig");
const ssh_error = @import("ssh/error.zig");
const i18n = @import("i18n.zig");
pub const tab = @import("appwindow/tab.zig");
const active_tab_state = @import("appwindow/active_tab.zig");
const tmux_controller = @import("appwindow/tmux_controller.zig");
const memory_digest_scheduler = @import("memory_digest/scheduler.zig");
const memory_center_session = @import("memory_center/session.zig");
pub const font = @import("font/manager.zig");
pub const cell_renderer = @import("renderer/cell_renderer.zig");
const cell_pipeline = @import("renderer/cell_pipeline.zig");
pub const ui_pipeline = @import("renderer/ui_pipeline.zig");
pub const titlebar = @import("renderer/titlebar.zig");
pub const input = @import("input.zig");
pub const overlays = @import("renderer/overlays.zig");
const post_process = @import("renderer/post_process.zig");
const d3d11_offscreen_smoke = @import("renderer/d3d11_offscreen_smoke.zig");
const d3d11_ui_smoke = @import("renderer/d3d11_ui_smoke.zig");
const d3d11_recreate_smoke = @import("renderer/d3d11_recreate_smoke.zig");
const d3d11_fallback_marker = @import("renderer/gpu/d3d11/fallback_marker.zig");
pub const gpu = @import("renderer/gpu/gpu.zig");
pub const split_layout = @import("appwindow/split_layout.zig");
const render_gate = @import("appwindow/render_gate.zig");
const frame_scheduler = @import("appwindow/frame_scheduler.zig");
const frame_latency = @import("appwindow/frame_latency.zig");
const flush_scheduler = @import("appwindow/flush_scheduler.zig");
const resize_throttle = @import("appwindow/resize_throttle.zig");
const surface_snapshots = @import("appwindow/surface_snapshots.zig");
const control_api = @import("appwindow/control_api.zig");
const remote_sync = @import("appwindow/remote_sync.zig");
const weixin_bridge = @import("appwindow/chatops_bridge.zig");
const agent_requests = @import("appwindow/agent_requests.zig");
const appwindow_ui_screenshot = @import("appwindow/ui_screenshot.zig");
const png_writer = @import("appwindow/png_writer.zig");
const ui_effect = @import("appwindow/ui_effect.zig");
pub const UiEffect = ui_effect.UiEffect;
const bench_driver = @import("benchmark/driver.zig");
const bench_report = @import("benchmark/report.zig");
pub const background_image = @import("renderer/background_image.zig");
pub const file_explorer = @import("file_explorer.zig");
const file_explorer_renderer = @import("renderer/file_explorer_renderer.zig");
const markdown_preview_renderer = @import("renderer/markdown_preview_renderer.zig");
pub const weixin_qr_panel = @import("weixin/qr_panel.zig");
const weixin_qr_renderer = @import("renderer/weixin_qr_renderer.zig");
const feishu_registration = @import("feishu/registration.zig");
const feishu_reg_panel = @import("feishu/registration_panel.zig");
const feishu_reg_renderer = @import("renderer/feishu_qr_renderer.zig");
const html_server = @import("html/server.zig");
pub const browser_panel = if (build_options.webview)
    @import("browser/panel.zig")
else
    @import("browser/panel_stub.zig");
pub const assistant_conversation_renderer = @import("renderer/assistant/conversation.zig");
pub const terminal_agent_sessions_renderer = @import("renderer/terminal_agents/sessions.zig");
const memory_center_renderer = @import("renderer/memory_center_renderer.zig");
const skill_center_renderer = @import("renderer/skill_center_renderer.zig");
const port_forwarding_renderer = @import("renderer/port_forwarding_renderer.zig");
const ai_sidebar = @import("assistant/sidebar/panel.zig");
pub const ui_perf = @import("ui_perf.zig");
const log = std.log.scoped(.app_window);

// Type aliases from config module
const Color = Config.Color;
const Theme = Config.Theme;
const CursorStyle = Config.CursorStyle;
const hexToColor = Config.hexToColor;
const parseColor = Config.parseColor;

/// AppWindow represents a single terminal window.
/// For now, this is a thin wrapper that uses module-level globals.
/// TODO: Move all globals into this struct for true multi-window support.
pub const AppWindow = @This();

allocator: std.mem.Allocator,
app: *App,
native_handle_bits: std.atomic.Value(usize) = .init(0),
force_close_requested: std.atomic.Value(bool) = .init(false),

/// Initialize an AppWindow with the given App.
pub fn init(allocator: std.mem.Allocator, app: *App) !AppWindow {
    // Store allocator globally for now (used by many functions)
    g_allocator = allocator;

    // Store app pointer globally for requestNewWindow
    g_app = app;
    // `/resume` opens the existing command-center agent history picker (the same
    // entry point the Command Palette uses for the "Select Agent History" action).
    ai_chat.setSessionResumeTrigger(struct {
        fn cb() void {
            overlays.commandPaletteOpenAgentHistory();
        }
    }.cb);
    // `/resume` in the Copilot sidebar opens the Copilot conversation picker.
    ai_chat.setCopilotPickerTrigger(struct {
        fn cb() void {
            openCopilotConversationPicker();
        }
    }.cb);
    // `/export [full|clean]` writes the active AI Chat transcript as Markdown.
    ai_chat.setMarkdownExportTrigger(struct {
        fn cb(session: *ai_chat.Session, mode: ai_chat.MarkdownExportMode) void {
            exportAiChatMarkdown(session, mode);
        }
    }.cb);
    // `/copy [full|clean]` puts the same Markdown on the clipboard instead.
    ai_chat.setTranscriptCopyTrigger(struct {
        fn cb(session: *ai_chat.Session, mode: ai_chat.MarkdownExportMode) void {
            copyAiChatMarkdown(session, mode);
        }
    }.cb);
    // `/model [name]` switches the active session's profile (and summarizes the
    // prior context with the new model). Empty pending name => open the picker.
    ai_chat.setModelSwitchTrigger(struct {
        fn cb(chat: *ai_chat.Session) void {
            const name = chat.takePendingModelSwitchName();
            if (name.len > 0) {
                overlays.switchModelByName(chat, name);
            } else {
                overlays.openSwitchModelPicker(chat);
            }
        }
    }.cb);
    app.maybeStartStartupUpdateCheck();

    try ensureGlobalAgentHistoryStore(allocator);
    tab.g_ai_history_change_hook = saveAiHistoryChangeEvent;
    installSessionRestoreHooks();
    // Init the scheduler store once per process (guard prevents re-init on
    // subsequent window creations). The store must not move after setActive, so
    // we keep it in the stable g_loop_store global.
    if (g_loop_store == null) {
        if (platform_dirs.pathInConfigDir(allocator, "loop_tasks.json")) |loop_path| {
            defer allocator.free(loop_path);
            g_loop_store = ai_loop_store.Store.init(allocator, loop_path);
            ai_loop_store.setActive(&g_loop_store.?);
            ai_loop_store.setInjector(loopInjector);
        } else |_| {}
    }

    // Apply config from App to globals
    g_theme = app.theme;
    g_force_rebuild = true;
    g_cursor_style = app.cursor_style;
    g_cursor_blink = app.cursor_blink;
    overlays.g_debug_fps = app.debug_fps;
    overlays.g_debug_draw_calls = app.debug_draw_calls;
    g_debug_memory = app.debug_memory;

    // Split config
    overlays.g_unfocused_split_opacity = app.unfocused_split_opacity;
    g_focus_follows_mouse = app.focus_follows_mouse;
    g_copy_on_select = app.copy_on_select;
    g_copilot_hint = app.copilot_hint;
    g_right_click_action = app.right_click_action;
    input.g_url_open_mode = app.url_open_mode;
    g_ssh_legacy_algorithms = app.ssh_legacy_algorithms;
    tab.g_ssh_legacy_algorithms = app.ssh_legacy_algorithms;
    g_weixin_notify_forward = app.weixin_notify_forward;
    overlays.g_split_divider_color = app.split_divider_color;

    // Apply window size from config
    term_cols = app.initial_cols;
    term_rows = app.initial_rows;

    tab.g_scrollback_limit = app.scrollback_limit;
    tab.g_remote_client = app.remote_client;
    ai_chat.configureAgent(.{
        .enabled = app.ai_agent_enabled,
        .permission = app.ai_agent_permission,
        .command_timeout_ms = app.ai_agent_command_timeout_ms,
        .output_limit = app.ai_agent_output_limit,
        .memory_enabled = app.ai_memory_enabled,
        .distill_suggest_enabled = app.ai_distill_suggest,
    });
    ai_chat.reloadFirstPartyToolState(allocator);
    ai_chat.setDefaultWorkingDir(app.ai_agent_working_dir);
    overlays.setSubagentProfileName(app.ai_subagent_profile);
    ai_chat.setSubagentProfileResolver(overlays.resolveSubagentProfileOverride);
    @import("research/web_search.zig").setJinaApiKey(app.jina_api_key);
    @import("pty.zig").setConsoleHostPreference(app.console_host_preference);
    // Copy shell command from App
    @memcpy(tab.g_shell_cmd_buf[0..app.shell_cmd_len], app.shell_cmd_buf[0..app.shell_cmd_len]);
    tab.g_shell_cmd_buf[app.shell_cmd_len] = 0;
    tab.g_shell_cmd_len = app.shell_cmd_len;

    // Store config values we need for init
    setRequestedFont(app.font_family);
    // Copy into the font module's own buffers rather than aliasing App's
    // strings: App frees and reallocates these on every config reload (see
    // App.replaceOptStr), which would leave the globals dangling.
    font.setCjkFontFamily(app.font_family_cjk);
    font.setFallbackFontFamilies(app.font_family_fallback);
    g_requested_weight = app.font_weight;
    font.g_font_size = app.font_size;
    g_shader_path = app.shader_path;
    g_start_maximize = app.maximize;
    g_start_fullscreen = app.fullscreen;
    g_quake_mode = app.quake_mode;
    g_keybinds = app.keybinds;
    background_image.g_mode = app.background_image_mode;
    gpu.background_opacity = app.background_opacity;
    tab.g_forced_title = app.title;

    // Get initial CWD for this window (if any) - copy into thread-local buffer
    g_initial_cwd_len = app.takeInitialCwd(&g_initial_cwd_buf);

    return AppWindow{
        .allocator = allocator,
        .app = app,
    };
}

/// Run the window's main loop. Blocks until the window is closed.
pub fn run(self: *AppWindow) void {
    runMainLoop(self) catch |err| {
        std.debug.print("AppWindow run failed: {}\n", .{err});
    };
}

/// Get the native window handle for cross-thread communication.
pub fn getNativeHandle(self: *AppWindow) ?window_backend.NativeHandle {
    const bits = self.native_handle_bits.load(.acquire);
    return window_backend.nativeHandleFromBits(bits);
}

/// Get the native handle for the current thread-local platform window.
pub fn currentNativeHandle() ?window_backend.NativeHandle {
    const window = g_window orelse return null;
    return window_backend.nativeHandle(window);
}

/// Get the native handle bits for the current thread-local platform window.
pub fn currentNativeHandleBits() ?usize {
    const window = g_window orelse return null;
    return window_backend.nativeHandleBits(window);
}

pub var g_skill_center_open_file_override: ?*const fn (std.mem.Allocator, platform_file_dialog.OpenRequest) ?[]u8 = null;

/// Request this window to exit without showing the interactive close prompt.
pub fn requestForceClose(self: *AppWindow) void {
    self.force_close_requested.store(true, .release);
}

fn consumeForceCloseRequest(self: *AppWindow) bool {
    return self.force_close_requested.swap(false, .acq_rel);
}

/// Clean up resources.
pub fn deinit(self: *AppWindow) void {
    // Persist the session to disk if restore-tabs-on-startup is enabled.
    // Only the LAST window to close performs the dump — this matches the
    // first-window-only restore behavior in run() and avoids losing the
    // tabs of other still-open windows when one window closes early.
    // (When this deinit runs, the window has already been swap-removed
    // from app.windows by the caller in App.run/windowThreadMain.)
    //
    // Errors are logged inside dumpSessionToFile and must not block shutdown.
    var is_last_window = false;
    {
        const restore_enabled = self.app.restore_tabs_on_startup;
        {
            self.app.mutex.lock();
            defer self.app.mutex.unlock();
            is_last_window = self.app.windows.items.len == 0;
        }
        if (restore_enabled and is_last_window) {
            persistOpenAiChatTabsToHistoryStore(self.allocator);
            tab.dumpSessionToFile(self.allocator);
        }
    }

    // Tear down this thread's tmux control-mode controllers. They are
    // thread-local and persist across transport drops (reconnect-with-backoff,
    // no auto-teardown), so quit is the only place they are freed — closing
    // each transport PTY detaches (not kills) the remote tmux session, the
    // persistence we want. Must run AFTER dumpSessionToFile above, which reads
    // the live controllers' profile names to persist them, and BEFORE the tab
    // cleanup below: destroy closes every pane's virtual controller (EOF'ing the
    // Surfaces) without freeing the Surfaces, which the tab teardown then owns.
    tmux_controller.shutdownAll(self.allocator);

    // In-app GPU benchmark: free the driver's run state (samples, payloads, and
    // the benchmark surface's virtual PTY controller). No-op when not running.
    bench_driver.deinit();

    // Clean up all tabs
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |t| {
            t.deinit(self.allocator);
            self.allocator.destroy(t);
            tab.g_tabs[ti] = null;
        }
    }
    tab.g_tab_count = 0;
    tab.g_remote_client = null;
    if (is_last_window) deinitGlobalAgentHistoryStore(self.allocator);
    if (is_last_window) {
        if (g_loop_store != null) {
            ai_loop_store.clearActive();
            g_loop_store.?.deinit();
            g_loop_store = null;
        }
    }
    markdown_preview_renderer.deinit();
    browser_panel.deinit();
}

test "AppWindow: forced close request is consumed once" {
    var window = AppWindow{
        .allocator = std.testing.allocator,
        .app = undefined,
    };

    try std.testing.expect(!window.consumeForceCloseRequest());
    window.requestForceClose();
    try std.testing.expect(window.consumeForceCloseRequest());
    try std.testing.expect(!window.consumeForceCloseRequest());
}

test "AppWindow: current backend window handle is exposed through platform facade" {
    const window_handle_info = @typeInfo(@TypeOf(AppWindow.getNativeHandle)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), window_handle_info.params.len);
    try std.testing.expect(window_handle_info.return_type.? == ?window_backend.NativeHandle);

    const from_bits_info = @typeInfo(@TypeOf(window_backend.nativeHandleFromBits)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), from_bits_info.params.len);
    try std.testing.expect(from_bits_info.params[0].type.? == usize);
    try std.testing.expect(from_bits_info.return_type.? == ?window_backend.NativeHandle);
    try std.testing.expect(window_backend.nativeHandleFromBits(0) == null);

    const native_handle_info = @typeInfo(@TypeOf(currentNativeHandle)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), native_handle_info.params.len);
    try std.testing.expect(native_handle_info.return_type.? == ?window_backend.NativeHandle);

    const native_bits_info = @typeInfo(@TypeOf(currentNativeHandleBits)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), native_bits_info.params.len);
    try std.testing.expect(native_bits_info.return_type.? == ?usize);
}

test "AppWindow: native handle bit conversion stays in platform backend" {
    const source = @embedFile("AppWindow.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "builtin." ++ "os.tag") == null);
}

// deinit runs on the same thread as runMainLoop (first window → main thread,
// spawned window → its worker thread), so it is the only place the thread-local
// tmux controller list can be freed. A restored persistent tmux session
// allocates a TmuxController/TmuxBridge/Session there; without this teardown
// call they leak at clean exit (GPA reports ~14 leaks). Guard the wiring.
test "AppWindow: deinit tears down tmux controllers so restored sessions don't leak" {
    const source = @embedFile("AppWindow.zig");
    // Split the needle so this assertion does not match its own literal.
    try std.testing.expect(std.mem.indexOf(u8, source, "tmux_controller." ++ "shutdownAll") != null);
}

test "AppWindow: platform window callbacks use backend-neutral names" {
    const resize_info = @typeInfo(@TypeOf(onPlatformResize)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), resize_info.params.len);
    try std.testing.expect(resize_info.params[0].type.? == i32);
    try std.testing.expect(resize_info.params[1].type.? == i32);
    try std.testing.expect(resize_info.return_type.? == void);

    const message_info = @typeInfo(@TypeOf(onPlatformMessage)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), message_info.params.len);
    try std.testing.expect(message_info.params[0].type.? == window_backend.MessageId);
    try std.testing.expect(message_info.params[1].type.? == window_backend.WordParam);
    try std.testing.expect(message_info.params[2].type.? == window_backend.LongParam);
    try std.testing.expect(message_info.return_type.? == ?window_backend.MessageResult);
}

test "AppWindow: session restore hooks include AI chat and AI history tabs" {
    const previous_chat_hook = tab.g_ai_restore_hook;
    const previous_history_hook = tab.g_ai_history_restore_hook;
    defer {
        tab.g_ai_restore_hook = previous_chat_hook;
        tab.g_ai_history_restore_hook = previous_history_hook;
    }

    tab.g_ai_restore_hook = null;
    tab.g_ai_history_restore_hook = null;

    installSessionRestoreHooks();

    try std.testing.expect(tab.g_ai_restore_hook != null);
    try std.testing.expect(tab.g_ai_history_restore_hook != null);
}

test "AppWindow: AI history restore snapshot rebuilds an SSH source" {
    const source = aiHistorySourceFromSnap(.{
        .source_id = "buildbox",
        .target_kind = "ssh",
        .target_name = "buildbox",
    }) orelse return error.ExpectedSource;

    try std.testing.expectEqualStrings("buildbox", source.id);
    try std.testing.expectEqualStrings("buildbox", source.name);
    switch (source.target) {
        .ssh => |ssh| try std.testing.expectEqualStrings("buildbox", ssh.profile_name),
        else => return error.ExpectedSshTarget,
    }
}

test "AppWindow: skill center tool enabled update matches manifest path" {
    var entries = [_]skill_center.LibraryEntry{
        .{ .tool = .{
            .name = @constCast("tool_a"),
            .executable_path = @constCast("/tmp/tools/tool_a/bin/tool_a"),
            .skill_path = @constCast("/tmp/tools/tool_a/SKILL.md"),
            .enabled = false,
        } },
        .{ .tool = .{
            .name = @constCast("tool_b"),
            .executable_path = @constCast("/tmp/tools/tool_b/bin/tool_b"),
            .skill_path = @constCast("/tmp/tools/tool_b/SKILL.md"),
            .enabled = false,
        } },
    };

    const manifest_b = switch (entries[1]) {
        .tool => |tool| skill_center_actions.toolManifestPath(std.testing.allocator, tool) orelse return error.ExpectedManifestPath,
        else => return error.ExpectedSkillCenterTool,
    };
    defer std.testing.allocator.free(manifest_b);

    try std.testing.expect(skill_center_actions.applyToolEnabledByManifestPath(std.testing.allocator, entries[0..], manifest_b, true));
    switch (entries[0]) {
        .tool => |tool| try std.testing.expect(!tool.enabled),
        else => return error.ExpectedSkillCenterTool,
    }
    switch (entries[1]) {
        .tool => |tool| try std.testing.expect(tool.enabled),
        else => return error.ExpectedSkillCenterTool,
    }

    try std.testing.expect(!skill_center_actions.applyToolEnabledByManifestPath(std.testing.allocator, entries[0..], "/tmp/tools/missing/manifest.json", false));
    switch (entries[1]) {
        .tool => |tool| try std.testing.expect(tool.enabled),
        else => return error.ExpectedSkillCenterTool,
    }
}

test "AppWindow: skill center first-party enabled update matches name only" {
    var entries = [_]skill_center.LibraryEntry{
        .{ .first_party_tool = .{
            .name = @constCast("webread"),
            .description = @constCast("Read web pages."),
            .enabled = false,
            .disableable = true,
        } },
        .{ .first_party_tool = .{
            .name = @constCast("pubmed"),
            .description = @constCast("Search PubMed."),
            .enabled = false,
            .disableable = true,
        } },
        .{ .tool = .{
            .name = @constCast("webread"),
            .executable_path = @constCast("/tmp/tools/webread/bin/webread"),
            .skill_path = @constCast("/tmp/tools/webread/SKILL.md"),
            .enabled = false,
        } },
    };

    try std.testing.expect(skill_center_actions.applyFirstPartyEnabledByName(entries[0..], "pubmed", true));
    switch (entries[0]) {
        .first_party_tool => |tool| try std.testing.expect(!tool.enabled),
        else => return error.ExpectedFirstPartyTool,
    }
    switch (entries[1]) {
        .first_party_tool => |tool| try std.testing.expect(tool.enabled),
        else => return error.ExpectedFirstPartyTool,
    }
    switch (entries[2]) {
        .tool => |tool| try std.testing.expect(!tool.enabled),
        else => return error.ExpectedSkillCenterTool,
    }

    try std.testing.expect(!skill_center_actions.applyFirstPartyEnabledByName(entries[0..], "missing", false));
    switch (entries[1]) {
        .first_party_tool => |tool| try std.testing.expect(tool.enabled),
        else => return error.ExpectedFirstPartyTool,
    }
}

test "AppWindow: skill center tool manifest toggle preserves extra fields" {
    const manifest_json =
        \\{
        \\  "kind": "binary_tool",
        \\  "id": "sample_tool",
        \\  "function_name": "sample_tool",
        \\  "enabled": false,
        \\  "executable": "bin/sample_tool",
        \\  "source_path": "/tmp/sample_tool",
        \\  "sha256": "abc123",
        \\  "imported_at_ms": 1234,
        \\  "description": "Sample tool",
        \\  "custom_meta": {
        \\    "owner": "qa"
        \\  }
        \\}
    ;

    const updated = try skill_center_actions.manifestJsonWithEnabled(std.testing.allocator, manifest_json, true);
    defer std.testing.allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "\"custom_meta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"owner\"") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, updated, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const enabled_value = parsed.value.object.get("enabled") orelse return error.ExpectedEnabledField;
    try std.testing.expect(enabled_value == .bool);
    try std.testing.expect(enabled_value.bool);
}

test "AppWindow: applyUiEffect maps repaint to dirty globals" {
    const previous_force_rebuild = g_force_rebuild;
    const previous_cells_valid = g_cells_valid;
    defer {
        g_force_rebuild = previous_force_rebuild;
        g_cells_valid = previous_cells_valid;
    }

    g_force_rebuild = false;
    g_cells_valid = true;

    applyUiEffect(UiEffect.repaint);

    try std.testing.expect(g_force_rebuild);
    try std.testing.expect(!g_cells_valid);
}

test "AppWindow: applyUiEffect none leaves dirty globals unchanged" {
    const previous_force_rebuild = g_force_rebuild;
    const previous_cells_valid = g_cells_valid;
    defer {
        g_force_rebuild = previous_force_rebuild;
        g_cells_valid = previous_cells_valid;
    }

    g_force_rebuild = false;
    g_cells_valid = true;

    applyUiEffect(UiEffect.none);

    try std.testing.expect(!g_force_rebuild);
    try std.testing.expect(g_cells_valid);
}

test "AppWindow: applyUiEffect documents UI-thread-only dirty flags" {
    const source = @embedFile("AppWindow.zig");
    const fn_needle = "pub fn applyUi" ++ "Effect(effect: UiEffect) void";
    const fn_pos = std.mem.indexOf(u8, source, fn_needle) orelse return error.MissingApplyUiEffect;
    const prefix_start = if (fn_pos > 400) fn_pos - 400 else 0;
    const prefix = source[prefix_start..fn_pos];

    try std.testing.expect(std.mem.indexOf(u8, prefix, "UI thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "threadlocal") != null);
}

test "AppWindow: skill center import picker allows empty library and blocks tool rows" {
    const allocator = std.testing.allocator;
    const previous_allocator = g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = g_force_rebuild;
    const previous_cells_valid = g_cells_valid;
    defer {
        g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        g_force_rebuild = previous_force_rebuild;
        g_cells_valid = previous_cells_valid;
    }

    g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    g_force_rebuild = false;
    g_cells_valid = true;
    try std.testing.expect(skillCenterImport());
    try std.testing.expect(g_force_rebuild);
    try std.testing.expect(!g_cells_valid);
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .picker => |picker| {
                try std.testing.expectEqual(skill_center.Purpose.import_, picker.purpose);
                try std.testing.expectEqualStrings("", picker.skill_name);
            },
            else => return error.ExpectedSkillCenterPicker,
        }
        session.model.clearOverlay();
    }

    const name = try allocator.dupe(u8, "fake_tool");
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);
    const executable_path = try allocator.dupe(u8, "/tmp/tools/fake_tool/bin/fake_tool");
    var executable_path_owned = true;
    errdefer if (executable_path_owned) allocator.free(executable_path);
    const skill_path = try allocator.dupe(u8, "/tmp/tools/fake_tool/SKILL.md");
    var skill_path_owned = true;
    errdefer if (skill_path_owned) allocator.free(skill_path);
    const entries = try allocator.alloc(skill_center.LibraryEntry, 1);
    var entries_owned = true;
    errdefer if (entries_owned) allocator.free(entries);
    entries[0] = .{ .tool = .{
        .name = name,
        .executable_path = executable_path,
        .skill_path = skill_path,
        .enabled = false,
    } };

    session.mutex.lock();
    session.model.setEntries(entries);
    entries_owned = false;
    name_owned = false;
    executable_path_owned = false;
    skill_path_owned = false;
    session.mutex.unlock();

    g_force_rebuild = false;
    g_cells_valid = true;
    try std.testing.expect(!skillCenterOpenPicker(.import_));
    try std.testing.expect(!g_force_rebuild);
    try std.testing.expect(g_cells_valid);
    try std.testing.expect(!skillCenterOverlayActive());
}

test "AppWindow: skill center tool toggle failure uses toggle status" {
    const allocator = std.testing.allocator;
    const previous_allocator = g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    const previous_force_rebuild = g_force_rebuild;
    const previous_cells_valid = g_cells_valid;
    defer {
        g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        g_force_rebuild = previous_force_rebuild;
        g_cells_valid = previous_cells_valid;
    }

    g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    const name = try allocator.dupe(u8, "bad_tool");
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);
    const executable_path = try allocator.dupe(u8, "/tmp/tools/bad_tool/bad_tool");
    var executable_path_owned = true;
    errdefer if (executable_path_owned) allocator.free(executable_path);
    const entries = try allocator.alloc(skill_center.LibraryEntry, 1);
    var entries_owned = true;
    errdefer if (entries_owned) allocator.free(entries);
    entries[0] = .{ .tool = .{
        .name = name,
        .executable_path = executable_path,
        .skill_path = null,
        .enabled = false,
    } };

    session.mutex.lock();
    session.model.setEntries(entries);
    entries_owned = false;
    name_owned = false;
    executable_path_owned = false;
    session.mutex.unlock();

    try std.testing.expect(skillCenterToggleToolEnabled());
    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqualStrings(i18n.s().sc_tool_toggle_failed, session.status);
}

test "AppWindow: failed tool import preserves preview overlay and sets status" {
    const allocator = std.testing.allocator;
    const previous_allocator = g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("tools/docx");
    try tmp.dir.makePath("tools/.import-stage-docx/bin");
    try tmp.dir.makePath("source");
    try tmp.dir.writeFile(.{ .sub_path = "tools/.import-stage-docx/bin/docx", .data = "staged bytes" });
    try tmp.dir.writeFile(.{ .sub_path = "source/docx", .data = "original bytes" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);

    const staged_path = try tmp.dir.realpathAlloc(allocator, "tools/.import-stage-docx/bin/docx");
    defer allocator.free(staged_path);
    const stage_root = try tmp.dir.realpathAlloc(allocator, "tools/.import-stage-docx");
    defer allocator.free(stage_root);
    const source_path = try tmp.dir.realpathAlloc(allocator, "source/docx");
    defer allocator.free(source_path);

    g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    session.mutex.lock();
    try session.model.openToolImportPreview(.{
        .tool_id = "docx",
        .function_name = "docx",
        .source_path = source_path,
        .staged_binary_path = staged_path,
        .skill_md = "---\nname: docx\n---\nUse docs.\n",
        .doc_source = .skill_flag,
        .ai_review_required = false,
    });
    session.mutex.unlock();

    try std.testing.expect(skillCenterOverlaySelect());
    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(session.model.overlay == .tool_import_preview);
    try std.testing.expect(std.mem.indexOf(u8, session.status, "Tool import failed:") != null);
    try std.testing.expectEqualStrings(staged_path, session.model.overlay.tool_import_preview.staged_binary_path);
    try std.fs.accessAbsolute(stage_root, .{});
}

fn countMatchingToolDirs(tools_root: []const u8, prefix: []const u8) !usize {
    var dir = std.fs.openDirAbsolute(tools_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close();
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, prefix)) count += 1;
    }
    return count;
}

test "AppWindow: skill center tool import stages file behind explicit confirmation" {
    const allocator = std.testing.allocator;
    const previous_allocator = g_allocator;
    const previous_open_file = g_skill_center_open_file_override;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        g_allocator = previous_allocator;
        g_skill_center_open_file_override = previous_open_file;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("source");
    try tmp.dir.writeFile(.{ .sub_path = "source/docx", .data = "plain bytes" });
    const source_path = try tmp.dir.realpathAlloc(allocator, "source/docx");
    defer allocator.free(source_path);
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);
    const tools_root = try platform_dirs.toolsDir(allocator);
    defer allocator.free(tools_root);

    g_allocator = allocator;
    const open_file = struct {
        var path: []const u8 = "";
        fn open(a: std.mem.Allocator, _: platform_file_dialog.OpenRequest) ?[]u8 {
            return a.dupe(u8, path) catch null;
        }
    };
    open_file.path = source_path;
    g_skill_center_open_file_override = open_file.open;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    try std.testing.expect(skillCenterImportTool());
    try std.testing.expect(skillCenterOverlayActive());
    try std.testing.expectEqual(@as(usize, 1), try countMatchingToolDirs(tools_root, ".import-staging-"));
    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqualStrings("", session.status);
}

test "AppWindow: skill center tool import confirmation opens preview for launchable binary" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const previous_allocator = g_allocator;
    const previous_open_file = g_skill_center_open_file_override;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        g_allocator = previous_allocator;
        g_skill_center_open_file_override = previous_open_file;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("source");
    const script =
        "#!/bin/sh\n" ++
        "if [ \"$1\" = \"--skill\" ]; then\n" ++
        "  printf '%s\\n' '---' 'name: docx_tool' 'description: Import docx files' '---' 'Use docx files.'\n" ++
        "  exit 0\n" ++
        "fi\n" ++
        "if [ \"$1\" = \"--help\" ]; then\n" ++
        "  printf 'docx tool help\\n'\n" ++
        "  exit 0\n" ++
        "fi\n" ++
        "exit 0\n";
    try tmp.dir.writeFile(.{ .sub_path = "source/docx-tool", .data = script });
    var file = try tmp.dir.openFile("source/docx-tool", .{});
    defer file.close();
    try file.chmod(0o755);
    const source_path = try tmp.dir.realpathAlloc(allocator, "source/docx-tool");
    defer allocator.free(source_path);
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);
    const tools_root = try platform_dirs.toolsDir(allocator);
    defer allocator.free(tools_root);

    g_allocator = allocator;
    const open_file = struct {
        var path: []const u8 = "";
        fn open(a: std.mem.Allocator, _: platform_file_dialog.OpenRequest) ?[]u8 {
            return a.dupe(u8, path) catch null;
        }
    };
    open_file.path = source_path;
    g_skill_center_open_file_override = open_file.open;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    try std.testing.expect(skillCenterImportTool());
    try std.testing.expect(skillCenterOverlayActive());
    try std.testing.expectEqual(@as(usize, 1), try countMatchingToolDirs(tools_root, ".import-staging-"));

    try std.testing.expect(skillCenterOverlaySelect());

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(session.model.overlay == .tool_import_preview);
    try std.testing.expectEqualStrings("", session.status);
    const preview = session.model.overlay.tool_import_preview;
    try std.testing.expectEqualStrings("docx_tool", preview.function_name);
    try std.testing.expect(std.mem.indexOf(u8, preview.skill_md, "Use docx files.") != null);
    try std.fs.accessAbsolute(preview.staged_binary_path, .{});
}

test "AppWindow: skill center tool import probe spawn failure aborts without fallback docs" {
    const allocator = std.testing.allocator;
    const previous_allocator = g_allocator;
    const previous_open_file = g_skill_center_open_file_override;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        g_allocator = previous_allocator;
        g_skill_center_open_file_override = previous_open_file;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("source");
    try tmp.dir.writeFile(.{ .sub_path = "source/docx", .data = "plain bytes" });
    try tmp.dir.writeFile(.{ .sub_path = "source/SKILL.md", .data = "---\nname: docx\n---\nSibling docs.\n" });
    const source_path = try tmp.dir.realpathAlloc(allocator, "source/docx");
    defer allocator.free(source_path);
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);
    const tools_root = try platform_dirs.toolsDir(allocator);
    defer allocator.free(tools_root);

    g_allocator = allocator;
    const open_file = struct {
        var path: []const u8 = "";
        fn open(a: std.mem.Allocator, _: platform_file_dialog.OpenRequest) ?[]u8 {
            return a.dupe(u8, path) catch null;
        }
    };
    open_file.path = source_path;
    g_skill_center_open_file_override = open_file.open;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    try std.testing.expect(skillCenterImportTool());
    try std.testing.expect(skillCenterOverlayActive());
    try std.testing.expect(skillCenterOverlaySelect());
    try std.testing.expect(!skillCenterOverlayActive());
    try std.testing.expectEqual(@as(usize, 0), try countMatchingToolDirs(tools_root, ".import-staging-"));
    try std.testing.expectEqual(@as(usize, 0), try countMatchingToolDirs(tools_root, "docx"));
    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(std.mem.indexOf(u8, session.status, "could not inspect the executable") != null);
}

test "AppWindow: skill center tool import rejects reserved built-in function names" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const previous_allocator = g_allocator;
    const previous_open_file = g_skill_center_open_file_override;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        g_allocator = previous_allocator;
        g_skill_center_open_file_override = previous_open_file;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("source");
    const script =
        "#!/bin/sh\n" ++
        "if [ \"$1\" = \"--skill\" ]; then\n" ++
        "  printf '%s\\n' '---' 'name: read_file' 'description: Reserved' '---' 'Reserved tool.'\n" ++
        "  exit 0\n" ++
        "fi\n" ++
        "if [ \"$1\" = \"--help\" ]; then\n" ++
        "  printf 'reserved help\\n'\n" ++
        "  exit 0\n" ++
        "fi\n" ++
        "exit 0\n";
    try tmp.dir.writeFile(.{ .sub_path = "source/read-file", .data = script });
    var file = try tmp.dir.openFile("source/read-file", .{});
    defer file.close();
    try file.chmod(0o755);
    const source_path = try tmp.dir.realpathAlloc(allocator, "source/read-file");
    defer allocator.free(source_path);
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);
    const tools_root = try platform_dirs.toolsDir(allocator);
    defer allocator.free(tools_root);

    g_allocator = allocator;
    const open_file = struct {
        var path: []const u8 = "";
        fn open(a: std.mem.Allocator, _: platform_file_dialog.OpenRequest) ?[]u8 {
            return a.dupe(u8, path) catch null;
        }
    };
    open_file.path = source_path;
    g_skill_center_open_file_override = open_file.open;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    try std.testing.expect(skillCenterImportTool());
    try std.testing.expect(!skillCenterOverlayActive());
    try std.testing.expectEqual(@as(usize, 0), try countMatchingToolDirs(tools_root, ".import-staging-"));
    try std.testing.expectEqual(@as(usize, 0), try countMatchingToolDirs(tools_root, "read_file"));
    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(std.mem.indexOf(u8, session.status, "reserved") != null);
}

test "AppWindow: tool import draft failure result keeps view and sets status" {
    const allocator = std.testing.allocator;
    const previous_allocator = g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
    }

    g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    session.mutex.lock();
    try session.model.openTextPreview("docx / SKILL.md", "preview");
    session.op_pending = .{ .tool_import_failed = try allocator.dupe(u8, "Draft generation failed.") };
    session.mutex.unlock();

    pollSkillCenterOp(session);

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(session.model.overlay == .text_preview);
    try std.testing.expectEqualStrings("Draft generation failed.", session.status);
}

test "AppWindow: open AI chat tabs are persisted to agent history before session dump" {
    const allocator = std.testing.allocator;

    const previous_store = g_agent_history;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        g_agent_history = previous_store;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
    }

    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hist_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(hist_root);
    var store = try agent_history_store.MetaStore.open(allocator, hist_root);
    defer store.deinit();
    g_agent_history = &store;

    const session = try ai_chat.Session.init(
        allocator,
        "Agent",
        "https://api.example.test",
        "key",
        "model",
        "system",
        "enabled",
        "",
        "false",
        "true",
    );

    const tab_state = try allocator.create(tab.TabState);
    tab_state.* = .{
        .kind = .ai_chat,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = session,
        .ai_history_session = null,
        .copilot_session = null,
    };
    defer {
        tab_state.deinit(allocator);
        allocator.destroy(tab_state);
        tab.g_tabs[0] = null;
        tab.g_tab_count = 0;
    }

    tab.g_tabs[0] = tab_state;
    tab.g_tab_count = 1;

    persistOpenAiChatTabsToHistoryStore(allocator);

    var restored = try store.cloneRecordBySessionId(allocator, session.sessionId()) orelse return error.ExpectedHistoryRecord;
    defer agent_history.freeOwnedRecord(allocator, &restored);

    try std.testing.expectEqualStrings("Agent", restored.title);
    try std.testing.expect(restored.agent_enabled);
}

test "AppWindow: terminal tab copilot sessions are persisted to agent history before session dump" {
    const allocator = std.testing.allocator;

    const previous_store = g_agent_history;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        g_agent_history = previous_store;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
    }

    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hist_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(hist_root);
    var store = try agent_history_store.MetaStore.open(allocator, hist_root);
    defer store.deinit();
    g_agent_history = &store;

    const session = try ai_chat.Session.init(
        allocator,
        "Copilot",
        "https://api.example.test",
        "key",
        "model",
        "system",
        "enabled",
        "",
        "false",
        "true",
    );
    session.copilot = true;

    // Append one message so shouldPersistCopilot() returns true (persist_to_history defaults to true)
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        try session.messages.append(allocator, .{
            .role = .user,
            .content = try allocator.dupe(u8, "hello from copilot"),
        });
    }

    const tab_state = try allocator.create(tab.TabState);
    tab_state.* = .{
        .kind = .terminal,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .copilot_session = session,
    };
    defer {
        tab_state.deinit(allocator);
        allocator.destroy(tab_state);
        tab.g_tabs[0] = null;
        tab.g_tab_count = 0;
    }

    tab.g_tabs[0] = tab_state;
    tab.g_tab_count = 1;

    persistOpenAiChatTabsToHistoryStore(allocator);

    var restored = try store.cloneRecordBySessionId(allocator, session.sessionId()) orelse return error.ExpectedHistoryRecord;
    defer agent_history.freeOwnedRecord(allocator, &restored);

    try std.testing.expect(restored.copilot);
}

test "AppWindow: markdown export target includes visible copilot sidebar" {
    const allocator = std.testing.allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
    }

    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;

    var copilot = ai_chat.Session{ .allocator = allocator, .copilot = true };
    var terminal_tab = tab.TabState{
        .kind = .terminal,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .copilot_session = &copilot,
        .copilot_visible = true,
    };
    tab.g_tabs[0] = &terminal_tab;
    tab.g_tab_count = 1;
    try std.testing.expectEqual(&copilot, activeMarkdownExportSession().?);

    var chat = ai_chat.Session{ .allocator = allocator };
    var chat_tab = tab.TabState{
        .kind = .ai_chat,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = &chat,
        .ai_history_session = null,
        .copilot_session = null,
    };
    tab.g_tabs[0] = &chat_tab;
    try std.testing.expectEqual(&chat, activeMarkdownExportSession().?);
}

test "AppWindow: copilot restore hook rehydrates a copilot session by id" {
    const allocator = std.testing.allocator;
    const previous_store = g_agent_history;
    const previous_hook = tab.g_copilot_restore_hook;
    const previous_alloc = g_allocator;
    defer {
        g_agent_history = previous_store;
        tab.g_copilot_restore_hook = previous_hook;
        g_allocator = previous_alloc;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hist_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(hist_root);
    var store = try agent_history_store.MetaStore.open(allocator, hist_root);
    defer store.deinit();
    g_agent_history = &store;
    g_allocator = allocator;

    try store.upsertRecord(.{
        .session_id = "cp-restore",
        .title = "T",
        .base_url = "https://x",
        .api_key = "k",
        .model = "m",
        .system_prompt = "s",
        .thinking_enabled = false,
        .reasoning_effort = "low",
        .stream = true,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .copilot = true,
        .messages = &[_]agent_history.MessageRecord{},
    });

    tab.g_copilot_restore_hook = reopenCopilotSessionFromHistorySessionId;
    const session = tab.g_copilot_restore_hook.?("cp-restore") orelse return error.RestoreFailed;
    defer session.deinit();
    try std.testing.expect(session.copilot);
    try std.testing.expectEqualStrings("cp-restore", session.sessionId());
}

// ============================================================================
// Module-level state (will be moved into AppWindow struct in future)
// ============================================================================

// App pointer for requestNewWindow
pub threadlocal var g_app: ?*App = null;
var g_agent_history_mutex: std.Thread.Mutex = .{};
pub var g_agent_history: ?*agent_history_store.MetaStore = null;
var g_flush_scheduler: flush_scheduler.FlushScheduler = .{};
var g_agent_history_revision: u64 = 0;

// Process-wide scheduler store for /loop and /watch tasks.
// Must be a stable global so setActive(&g_loop_store.?) never dangles.
var g_loop_store: ?ai_loop_store.Store = null;

/// Resolves a session by id across all open tabs (UI thread only: tab.g_tabs
/// is threadlocal and only populated on the window's UI thread).
fn loopInjector(session_id: []const u8, prompt: []const u8) ai_loop_store.InjectOutcome {
    var i: usize = 0;
    while (i < tab.MAX_TABS) : (i += 1) {
        const t = tab.g_tabs[i] orelse continue;
        if (t.ai_chat_session) |s| {
            if (std.mem.eql(u8, s.sessionId(), session_id))
                return if (s.submitScheduledPrompt(prompt)) .sent else .busy;
        }
        if (t.copilot_session) |s| {
            if (std.mem.eql(u8, s.sessionId(), session_id))
                return if (s.submitScheduledPrompt(prompt)) .sent else .busy;
        }
    }
    return .closed;
}

// Initial CWD for this window (used when spawning the first tab)
threadlocal var g_initial_cwd_buf: platform_pty_command.CwdBuffer = undefined;
threadlocal var g_initial_cwd_len: usize = 0;

// Tracks whether session restore has been attempted this process. We only
// try to restore tabs from session.json once — for the first window. New
// windows spawned via the new-window keybind still get a fresh default tab.
var g_session_restore_attempted: std.atomic.Value(bool) = .init(false);

// Stored config values for deferred initialization
threadlocal var g_requested_font: []const u8 = "";
// Backing buffer for g_requested_font. The configured family must be copied
// here rather than aliasing App.font_family: App frees and reallocates that
// string on every config reload (App.replaceStr), and g_requested_font is read
// later in the event loop (handleWindowDpiChanged), which would dangle.
threadlocal var g_requested_font_buf: [256]u8 = undefined;
threadlocal var g_requested_weight: font_backend.FontWeight = .NORMAL;
threadlocal var g_shader_path: ?[]const u8 = null;
threadlocal var g_start_maximize: bool = false;
threadlocal var g_start_fullscreen: bool = false;
threadlocal var g_quake_mode: bool = false;
threadlocal var g_quake_hidden: bool = false;
threadlocal var g_quake_frame: ?quick_terminal.Frame = null;
threadlocal var g_quake_hotkey_registered: bool = false;
pub threadlocal var g_keybinds: keybind.Set = keybind.Set.defaults();
threadlocal var g_debug_memory: bool = false;
threadlocal var g_debug_memory_last_ms: i64 = 0;
threadlocal var g_appwindow_state: appwindow_state.State = .{};

fn windowState() *appwindow_state.WindowState {
    return &g_appwindow_state.window;
}

fn remoteState() *appwindow_state.RemoteState {
    return &g_appwindow_state.remote;
}

// Global theme (set at startup via config)
pub threadlocal var g_theme: Theme = Theme.default();

// Global pointers for callbacks
pub threadlocal var g_window: ?*window_backend.Window = null;
pub threadlocal var g_allocator: ?std.mem.Allocator = null;

// Selection is defined in Surface.zig
const Selection = Surface.Selection;

pub threadlocal var g_should_close: bool = false; // Set when the final tab closes

// Tab model — see appwindow/tab.zig
const TabState = tab.TabState;

// Split layout — see appwindow/split_layout.zig
pub const SplitRect = split_layout.SplitRect;
pub const DividerHit = split_layout.DividerHit;
pub const DEFAULT_PADDING = split_layout.DEFAULT_PADDING;
pub const surfaceAtPoint = split_layout.surfaceAtPoint;
pub const hitTestDivider = split_layout.hitTestDivider;
const computeSplitLayout = split_layout.computeSplitLayout;

/// Draw a thin accent-colored focus border around a split-leaf rect, in
/// window-absolute coordinates (GL origin bottom-left). Used to indicate the
/// focused non-terminal pane (e.g. a preview), which has no terminal cursor.
/// The caller must have the full-window viewport/projection set.
fn drawPaneFocusRing(rect: SplitRect, window_height: f32) void {
    const accent = g_theme.cursor_color;
    const border: f32 = 2.0;
    const px: f32 = @floatFromInt(rect.x);
    const py: f32 = window_height - @as(f32, @floatFromInt(rect.y + rect.height));
    const pw: f32 = @floatFromInt(rect.width);
    const ph: f32 = @floatFromInt(rect.height);
    if (pw <= 0 or ph <= 0) return;
    ui_pipeline.fillQuad(px, py, pw, border, accent); // bottom
    ui_pipeline.fillQuad(px, py + ph - border, pw, border, accent); // top
    ui_pipeline.fillQuad(px, py, border, ph, accent); // left
    ui_pipeline.fillQuad(px + pw - border, py, border, ph, accent); // right
}

fn synchronizedOutputPendingForVisibleSplits(split_count: usize) bool {
    for (0..split_count) |i| {
        const surface = split_layout.g_split_rects[i].surface() orelse continue;
        surface.render_state.mutex.lock();
        const pending = surface.synchronizedOutputPendingLocked();
        surface.render_state.mutex.unlock();

        if (pending) return true;
    }
    return false;
}

pub const MAX_TABS = tab.MAX_TABS;
comptime {
    std.debug.assert(@import("appwindow/remote_state.zig").MAX_REMOTE_AI_SINKS == tab.MAX_TABS);
}

// ============================================================================
// Tab/split operation wrappers — delegate to tab module, handle UI side effects
// ============================================================================

/// Clear the framebuffer with the theme background color, then draw the
/// background image (if any) over the cleared color. The current viewport
/// must already cover (0,0)..(fb_w,fb_h).
fn clearWithBackground(fb_w: c_int, fb_h: c_int) void {
    gpu.state.clear(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
    background_image.drawFullscreen(@floatFromInt(fb_w), @floatFromInt(fb_h));
}

/// Force the whole backbuffer opaque (alpha = 1) just before present.
///
/// We extend the DWM frame into the entire client area (`cyTopHeight = -1`, for
/// the custom titlebar + window shadow), so DWM composites the window using the
/// GL backbuffer's alpha channel. UI chrome drawn in the `.alpha` blend mode
/// (caption-button icons, overlays) drives dst-alpha below 1 where it touches,
/// which DWM then renders translucent: the top-right caption icons "ghost" when
/// the window is dragged across monitors, and the surface darkens to black in
/// borderless fullscreen (nothing is behind the window). Masking RGB and clearing
/// alpha to 1 makes composition solid regardless of per-draw alpha, without
/// disturbing the rendered colors. OpenGL backend only — the Metal backend
/// composites opaquely on its own, and its clear would wipe the frame here.
fn forceOpaqueBackbufferForPresent() void {
    if (comptime gpu.active == .opengl) {
        // glClear honors the scissor box; drop it so the whole surface is covered.
        gpu.state.disableScissor();
        gpu.state.setColorMask(false, false, false, true);
        gpu.state.clear(0, 0, 0, 1.0);
        gpu.state.setColorMask(true, true, true, true);
    }
}

fn syncBackendSurfaceSize(fb_width: c_int, fb_height: c_int) void {
    if (comptime gpu.active == .d3d11) {
        if (!gpu.Context.resize(fb_width, fb_height)) {
            render_diagnostics.log("gpu-backend=d3d11 resize sync failed for {}x{}", .{ fb_width, fb_height });
        }
    }
}

fn presentBackendFrame(win: *window_backend.Window) void {
    if (comptime gpu.active == .d3d11) {
        gpu.Context.present() catch |err| {
            render_diagnostics.log("gpu-backend=d3d11 present failed: {s}", .{@errorName(err)});
            std.debug.print("D3D11 present failed: {s}\n", .{@errorName(err)});
        };
    } else {
        window_backend.swapBuffers(win);
    }
}

fn prepareD3D11DeviceRecreateResources() void {
    if (comptime gpu.active == .d3d11) {
        cell_pipeline.deinit();
        ui_pipeline.deinit();
        d3d11_offscreen_smoke.deinit();
        d3d11_ui_smoke.deinit();
        background_image.deinit();
        post_process.deinit();
        const atlas_release = font.releaseAtlasGpuTexturesForDeviceRecreate();
        const context_release = gpu.Context.prepareForDeviceRecreate();
        render_diagnostics.log(
            "gpu-backend=d3d11 resource recreate prepared context_initialized={} context_released_any={} released_atlas_any={} released_atlas_glyph={} released_atlas_color={} released_atlas_icon={} released_atlas_titlebar={} released_feature_pipelines=true released_auxiliary_targets=true automatic_fallback=false default_unchanged=true",
            .{
                context_release.initialized,
                context_release.anyReleased(),
                atlas_release.anyReleased(),
                atlas_release.glyph,
                atlas_release.color,
                atlas_release.icon,
                atlas_release.titlebar,
            },
        );
    }
}

fn restoreD3D11DeviceRecreateResources(allocator: std.mem.Allocator) void {
    if (comptime gpu.active == .d3d11) {
        ui_pipeline.init();
        cell_pipeline.init();
        post_process.init(allocator, g_shader_path);
        if (g_app) |app| {
            app.mutex.lock();
            const image_path: ?[]u8 = if (app.background_image) |p| (allocator.dupe(u8, p) catch null) else null;
            app.mutex.unlock();
            if (image_path) |p| {
                defer allocator.free(p);
                background_image.load(allocator, p);
            }
        }
        render_diagnostics.log(
            "gpu-backend=d3d11 resource recreate restored feature_pipelines=true background_reloaded={} post_process_rechecked=true automatic_fallback=false default_unchanged=true",
            .{background_image.g_enabled},
        );
    }
}

fn recordD3D11FallbackCandidate(
    allocator: std.mem.Allocator,
    adapter_id: []const u8,
    reason: d3d11_fallback_marker.Reason,
) bool {
    if (comptime gpu.active != .d3d11) return false;
    var marker_buf: [d3d11_fallback_marker.marker_max_len]u8 = undefined;
    const marker = d3d11_fallback_marker.format(
        &marker_buf,
        .fallback_candidate,
        build_options.app_version,
        adapter_id,
        reason,
    ) catch |err| {
        render_diagnostics.log(
            "gpu-backend=d3d11 fallback marker record failed error={s} adapter={s} reason={s} automatic_fallback=false default_unchanged=true",
            .{ @errorName(err), adapter_id, reason.name() },
        );
        return false;
    };

    platform_window_state.recordD3d11Fallback(allocator, marker);
    render_diagnostics.log(
        "gpu-backend=d3d11 fallback marker recorded marker={s} adapter={s} reason={s} automatic_fallback=false default_unchanged=true",
        .{ marker, adapter_id, reason.name() },
    );
    return true;
}

fn handleD3D11RecoveryRequest(allocator: std.mem.Allocator, fb_width: c_int, fb_height: c_int) void {
    if (comptime gpu.active == .d3d11) {
        const request = gpu.Context.takeRecoveryRequest() orelse return;
        const status = request.status;
        var adapter_buf: [64]u8 = undefined;
        const adapter_id = gpu.Context.adapterFallbackIdentity(&adapter_buf) orelse "unknown-adapter";
        render_diagnostics.log(
            "gpu-backend=d3d11 recovery requested action={s} policy_state={s} operation={s} fallback_candidate_reason={s} dxgi_kind={s} requires_device_recreate={} automatic_fallback=false default_unchanged=true",
            .{
                request.actionName(),
                status.stateName(),
                status.operationName(),
                status.reasonName(),
                status.dxgiKindName(),
                status.requires_device_recreate,
            },
        );

        if (status.requires_device_recreate) {
            prepareD3D11DeviceRecreateResources();
            const recreate = gpu.Context.recreateDevice(fb_width, fb_height);
            render_diagnostics.log(
                "gpu-backend=d3d11 recovery recreate attempt attempted={} succeeded={} error={s} swapchain={}x{} automatic_fallback=false default_unchanged=true",
                .{ recreate.attempted, recreate.succeeded, recreate.error_name, recreate.width, recreate.height },
            );
            if (recreate.succeeded) {
                restoreD3D11DeviceRecreateResources(allocator);
            } else if (recreate.fallback_candidate) {
                const marker_written = recordD3D11FallbackCandidate(
                    allocator,
                    adapter_id,
                    recreate.fallbackMarkerReason(),
                );
                render_diagnostics.log(
                    "gpu-backend=d3d11 recovery recreate failed escalated policy_state=fallback_candidate fallback_candidate={} fallback_candidate_reason={s} marker_written={} automatic_fallback=false default_unchanged=true",
                    .{ recreate.fallback_candidate, recreate.fallbackReasonName(), marker_written },
                );
            }
        }
        applyUiEffect(UiEffect.repaint);
        markAllRenderersDirty();
    }
}

threadlocal var g_diag_last_fb_w: c_int = -1;
threadlocal var g_diag_last_fb_h: c_int = -1;
threadlocal var g_diag_last_client_w: i32 = -1;
threadlocal var g_diag_last_client_h: i32 = -1;
threadlocal var g_diag_last_dpi: u32 = 0;
threadlocal var g_diag_last_cell_w: f32 = 0;
threadlocal var g_diag_last_cell_h: f32 = 0;

fn logFrameGeometryIfChanged(win: *window_backend.Window, fb_width: c_int, fb_height: c_int, titlebar_offset: f32) void {
    if (!render_diagnostics.enabled()) return;

    const client = window_backend.clientSize(win);
    const dpi_now = window_backend.effectiveDpi(win);
    if (fb_width == g_diag_last_fb_w and
        fb_height == g_diag_last_fb_h and
        client.width == g_diag_last_client_w and
        client.height == g_diag_last_client_h and
        dpi_now == g_diag_last_dpi and
        font.cell_width == g_diag_last_cell_w and
        font.cell_height == g_diag_last_cell_h)
    {
        return;
    }

    g_diag_last_fb_w = fb_width;
    g_diag_last_fb_h = fb_height;
    g_diag_last_client_w = client.width;
    g_diag_last_client_h = client.height;
    g_diag_last_dpi = dpi_now;
    g_diag_last_cell_w = font.cell_width;
    g_diag_last_cell_h = font.cell_height;

    render_diagnostics.log(
        "frame-geometry client={}x{} fb={}x{} dpi={} font_dpi={} cell={d:.2}x{d:.2} titlebar={d:.1} panels_l={d:.1} panels_r={d:.1} term={}x{} max={} full={} min={}",
        .{
            client.width,
            client.height,
            fb_width,
            fb_height,
            dpi_now,
            font.g_dpi,
            font.cell_width,
            font.cell_height,
            titlebar_offset,
            leftPanelsWidth(),
            rightPanelsWidthForWindow(fb_width),
            term_cols,
            term_rows,
            window_backend.isMaximized(win),
            window_backend.isFullscreen(win),
            window_backend.isMinimized(win),
        },
    );
}

/// Log GPU vendor/renderer/version and the backbuffer clear-alpha fact once,
/// after the GPU backend is ready. Lets the analyst correlate
/// glitches with a specific driver (AMD/Intel/NVIDIA) and confirm the alpha=1
/// clear that feeds DWM composition.
fn logGpuDiagnosticsOnce() void {
    if (!render_diagnostics.enabled()) return;
    if (g_gpu_diag_logged) return;
    g_gpu_diag_logged = true;
    const info = gpu.state.driverInfo();
    render_diagnostics.log(
        "gpu vendor=\"{s}\" renderer=\"{s}\" version=\"{s}\" shading_language=\"{s}\" clear_alpha=1.0 dwm_frame_extend_top=-1",
        .{
            info.vendor,
            info.renderer,
            info.version,
            info.shading_language,
        },
    );
}

threadlocal var g_gpu_diag_logged: bool = false;
threadlocal var g_diag_last_swap_diag: ?gpu.SwapDiagnostics = null;
threadlocal var g_diag_last_swap_client_w: i32 = -1;
threadlocal var g_diag_last_swap_client_h: i32 = -1;

/// Just before swap/present, snapshot the backend viewport, re-read the client
/// rect, and read the active blend state. Logged only when one of these changes
/// (or when viewport diverges from the client size) so it stays analyzable.
fn logSwapDiagnosticsIfChanged(win: *window_backend.Window, fb_width: c_int, fb_height: c_int) void {
    if (!render_diagnostics.enabled()) return;
    const diag = gpu.state.swapDiagnostics() orelse return;
    const vp = diag.viewport;
    const blend = diag.blend;

    const client = window_backend.clientSize(win);
    const vp_matches_client = (vp.w == client.width and vp.h == client.height);

    const unchanged = if (g_diag_last_swap_diag) |last|
        std.meta.eql(last, diag) and
            client.width == g_diag_last_swap_client_w and
            client.height == g_diag_last_swap_client_h
    else
        false;
    if (unchanged) return;

    g_diag_last_swap_diag = diag;
    g_diag_last_swap_client_w = client.width;
    g_diag_last_swap_client_h = client.height;

    render_diagnostics.log(
        "swap viewport=({},{} {}x{}) client={}x{} fb={}x{} vp_matches_client={} blend_enabled={} blend_rgb=({s},{s}) blend_alpha=({s},{s})",
        .{
            vp.x,
            vp.y,
            vp.w,
            vp.h,
            client.width,
            client.height,
            fb_width,
            fb_height,
            vp_matches_client,
            blend.enabled,
            @tagName(blend.src_rgb),
            @tagName(blend.dst_rgb),
            @tagName(blend.src_alpha),
            @tagName(blend.dst_alpha),
        },
    );
}

fn renderAiChatFrame(fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    if (activeAiChat()) |session| {
        const chat_x = left_panels_w;
        const chat_w = @as(f32, @floatFromInt(fb_width)) - left_panels_w - right_panels_w;
        assistant_conversation_renderer.render(
            session,
            @floatFromInt(fb_width),
            @floatFromInt(fb_height),
            titlebar_offset,
            chat_x,
            chat_w,
            false, // full tab: status shown as text + Esc Stop button
        );
    }
}

fn aiHistoryContentWidth(fb_width: c_int, left_panels_w: f32, right_panels_w: f32) f32 {
    return @max(0, @as(f32, @floatFromInt(fb_width)) - left_panels_w - right_panels_w);
}

fn renderAiHistoryFrame(active_tab: *TabState, fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    if (active_tab.ai_history_session) |session| {
        const draw: terminal_agent_sessions_renderer.DrawContext = .{
            .bg = g_theme.background,
            .fg = g_theme.foreground,
            .accent = g_theme.cursor_color,
            .cell_h = font.g_titlebar_cell_height,
            .fillQuad = ui_pipeline.fillQuad,
            .fillQuadAlpha = ui_pipeline.fillQuadAlpha,
            .renderTextLimited = titlebar.renderTextLimited,
            .glyphAdvance = titlebar.titlebarGlyphAdvance,
        };
        session.mutex.lock();
        defer session.mutex.unlock();
        terminal_agent_sessions_renderer.render(
            draw,
            session,
            @floatFromInt(fb_width),
            @floatFromInt(fb_height),
            titlebar_offset,
            left_panels_w,
            aiHistoryContentWidth(fb_width, left_panels_w, right_panels_w),
        );
    }
}

fn renderMemoryCenterFrame(active_tab: *TabState, fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    if (active_tab.memory_center_session) |session| {
        const draw: memory_center_renderer.DrawContext = .{
            .bg = g_theme.background,
            .fg = g_theme.foreground,
            .accent = g_theme.cursor_color,
            .cell_h = font.g_titlebar_cell_height,
            .fillQuad = ui_pipeline.fillQuad,
            .fillQuadAlpha = ui_pipeline.fillQuadAlpha,
            .renderTextLimited = titlebar.renderTextLimited,
            .glyphAdvance = titlebar.titlebarGlyphAdvance,
        };
        memory_center_renderer.render(
            draw,
            session,
            @floatFromInt(fb_width),
            @floatFromInt(fb_height),
            titlebar_offset,
            left_panels_w,
            aiHistoryContentWidth(fb_width, left_panels_w, right_panels_w),
        );
    }
}

fn renderSkillCenterFrame(active_tab: *TabState, fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    if (active_tab.skill_center_session) |session| {
        const draw: skill_center_renderer.DrawContext = .{
            .bg = g_theme.background,
            .fg = g_theme.foreground,
            .accent = g_theme.cursor_color,
            .cell_h = font.g_titlebar_cell_height,
            .fillQuad = ui_pipeline.fillQuad,
            .fillQuadAlpha = ui_pipeline.fillQuadAlpha,
            .renderTextLimited = titlebar.renderTextLimited,
            .glyphAdvance = titlebar.titlebarGlyphAdvance,
        };
        // Hold the lock for the duration of render: the View borrows the pairing.
        session.mutex.lock();
        defer session.mutex.unlock();
        const m = &session.model;
        const lib_len = m.entryCount();
        const overlay: skill_center_renderer.Overlay = switch (m.overlay) {
            .none, .busy => .none,
            .picker => |*p| .{ .list = .{
                .title = if (p.purpose == .deploy) i18n.s().sc_pick_deploy else i18n.s().sc_pick_import,
                .len = p.labels.len,
                .ctx = @ptrCast(p),
                .itemAt = scPickerItemAt,
                .sel = p.sel,
            } },
            .import_list => |*il| .{ .list = .{
                .title = i18n.s().sc_import_title,
                .len = il.names.len,
                .ctx = @ptrCast(il),
                .itemAt = scImportItemAt,
                .sel = il.sel,
            } },
            .confirm => |*c| .{ .confirm = c.text },
            .url_input => |*u| .{ .input = .{ .prompt = i18n.s().sc_url_prompt, .text = u.text() } },
            .install_pick => |*p| .{ .list = .{
                .title = i18n.s().sc_pick_install,
                .len = p.entries.len,
                .ctx = @ptrCast(p),
                .itemAt = scInstallPickItemAt,
                .sel = p.sel,
            } },
            // scroll_out lets the renderer clamp `scroll` against the wrapped
            // height and write it back — safe here under the session lock.
            .text_preview => |*tp| .{ .text = .{
                .title = tp.title,
                .content = tp.content,
                .hint = i18n.s().sc_preview_hint,
                .scroll = tp.scroll,
                .scroll_out = &tp.scroll,
            } },
            .tool_import_confirm => |*tp| .{ .text = .{
                .title = tp.function_name,
                .content = tp.warning_text,
                .hint = "Enter inspect/import preview · Esc cancel · ↑/↓ scroll",
                .scroll = tp.scroll,
                .scroll_out = &tp.scroll,
            } },
            .tool_import_preview => |*tp| .{ .text = .{
                .title = tp.function_name,
                .content = tp.skill_md,
                .hint = "Enter import · Esc cancel · ↑/↓ scroll",
                .scroll = tp.scroll,
                .scroll_out = &tp.scroll,
            } },
        };
        const view: skill_center_renderer.View = .{
            .skills_len = lib_len,
            .ctx = @ptrCast(m),
            .itemAt = scEntryItemAt,
            .sel_row = m.sel_row,
            .scroll = m.scroll,
            .title = i18n.s().sl_skill_center,
            .legend = switch (m.overlay) {
                .import_list => i18n.s().sc_legend_import,
                .install_pick => i18n.s().sc_pick_install,
                else => i18n.s().sc_legend_v2,
            },
            .status = session.status,
            .overlay = overlay,
        };
        skill_center_renderer.render(
            draw,
            view,
            @floatFromInt(fb_width),
            @floatFromInt(fb_height),
            titlebar_offset,
            left_panels_w,
            aiHistoryContentWidth(fb_width, left_panels_w, right_panels_w),
        );
    }
}

fn pfStatusKind(status: port_forward_manager.StatusKind) port_forwarding_renderer.StatusKind {
    return switch (status) {
        .stopped => .stopped,
        .starting => .starting,
        .running => .running,
        .error_ => .error_,
        .missing_profile => .missing_profile,
    };
}

fn pfRowAt(ctx: *anyopaque, i: usize) port_forwarding_renderer.RowView {
    const manager: *port_forward_manager.Manager = @ptrCast(@alignCast(ctx));
    if (manager.rowAt(i)) |row| {
        var out: port_forwarding_renderer.RowView = .{
            .rule = row.rule,
            .status = pfStatusKind(row.status),
            .auto_start = row.auto_start,
        };
        out.reason_len = copyPortForwardingReason(out.reason_buf[0..], row.reason());
        return out;
    }
    return .{
        .rule = port_forward_rule.defaultReverseProxy(""),
        .status = .stopped,
        .auto_start = false,
    };
}

fn copyPortForwardingReason(dest: []u8, reason: []const u8) usize {
    const n = @min(dest.len, reason.len);
    @memcpy(dest[0..n], reason[0..n]);
    return n;
}

fn renderPortForwardingFrame(active_tab: *TabState, fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    const session = active_tab.port_forwarding_session orelse return;
    const app = g_app orelse return;

    session.mutex.lock();
    defer session.mutex.unlock();
    const row_count = app.port_forward_manager.count();
    session.model.move(0, row_count);
    const overlay_text = switch (session.model.overlay) {
        .none, .form => "",
        .confirm_delete => |*c| c.text,
    };
    const form_view: ?port_forwarding_renderer.FormView = switch (session.model.overlay) {
        .form => |form| .{
            .mode = if (form.mode == .new) "New forwarding rule" else "Edit forwarding rule",
            .focus = form.focus,
            .rule = form.rule,
        },
        else => null,
    };
    const draw: port_forwarding_renderer.DrawContext = .{
        .bg = g_theme.background,
        .fg = g_theme.foreground,
        .accent = g_theme.cursor_color,
        .cell_h = font.g_titlebar_cell_height,
        .fillQuad = ui_pipeline.fillQuad,
        .fillQuadAlpha = ui_pipeline.fillQuadAlpha,
        .renderTextLimited = titlebar.renderTextLimited,
        .glyphAdvance = titlebar.titlebarGlyphAdvance,
    };
    const legend = if (form_view != null) i18n.s().pf_form_legend else i18n.s().pf_legend;
    const view: port_forwarding_renderer.View = .{
        .title = i18n.s().pf_title,
        .legend = legend,
        .count = row_count,
        .selected = session.model.sel_row,
        .scroll = session.model.scroll,
        .ctx = @ptrCast(&app.port_forward_manager),
        .rowAt = pfRowAt,
        .overlay_text = overlay_text,
        .form = form_view,
    };
    port_forwarding_renderer.render(
        draw,
        view,
        @floatFromInt(fb_width),
        @floatFromInt(fb_height),
        titlebar_offset,
        left_panels_w,
        aiHistoryContentWidth(fb_width, left_panels_w, right_panels_w),
    );
}

/// Renderer accessor: library entry metadata at index i (read under the session lock).
fn scEntryItemAt(ctx: *anyopaque, i: usize) skill_center_renderer.ListItem {
    const m: *const skill_center.PanelModel = @ptrCast(@alignCast(ctx));
    const entries = m.entries orelse return .{ .label = "", .marker = "" };
    if (i >= entries.len) return .{ .label = "", .marker = "" };
    return switch (entries[i]) {
        .prompt => |s| .{ .label = s.name, .marker = "", .kind = "skill" },
        .tool => |t| .{
            .label = t.name,
            .marker = "",
            .kind = "tool",
            .enabled = if (t.enabled) "on" else "off",
            .marker_color = if (t.enabled) .{ 0.3, 0.85, 0.45 } else .{ 0.85, 0.45, 0.35 },
        },
        .first_party_tool => |t| .{
            .label = t.name,
            .marker = "",
            .kind = "built-in",
            .enabled = if (t.enabled) "on" else "off",
            .marker_color = if (t.enabled) .{ 0.3, 0.85, 0.45 } else .{ 0.85, 0.45, 0.35 },
        },
    };
}
fn scPickerItemAt(ctx: *anyopaque, i: usize) skill_center_renderer.ListItem {
    const p: *const skill_center.PickerState = @ptrCast(@alignCast(ctx));
    return if (i < p.labels.len) .{ .label = p.labels[i], .marker = "" } else .{ .label = "", .marker = "" };
}
fn scImportItemAt(ctx: *anyopaque, i: usize) skill_center_renderer.ListItem {
    const il: *const skill_center.ImportState = @ptrCast(@alignCast(ctx));
    if (i >= il.names.len) return .{ .label = "", .marker = "" };
    const t = i18n.s();
    return switch (il.markers[i]) {
        .new_ => .{ .label = il.names[i], .marker = t.sc_marker_new, .marker_color = .{ 0.42, 0.62, 0.88 } },
        .same => .{ .label = il.names[i], .marker = t.sc_marker_same, .marker_color = mixColor(g_theme.background, g_theme.foreground, 0.58) },
        .differ => .{ .label = il.names[i], .marker = t.sc_marker_differ, .marker_color = .{ 0.86, 0.70, 0.28 } },
    };
}
fn scInstallPickItemAt(ctx: *anyopaque, i: usize) skill_center_renderer.ListItem {
    const p: *const skill_center.InstallPickState = @ptrCast(@alignCast(ctx));
    if (i >= p.entries.len) return .{ .label = "", .marker = "" };
    // Static buffers keyed off a small ring so labels survive the frame draw.
    const checked = i < p.checked.len and p.checked[i];
    const box = if (checked) "[x] " else "[ ] ";
    const slot = &g_sc_pick_label_buf[i % g_sc_pick_label_buf.len];
    const label = std.fmt.bufPrint(slot, "{s}{s}", .{ box, p.entries[i].name }) catch p.entries[i].name;
    return .{ .label = label, .marker = "" };
}
var g_sc_pick_label_buf: [64][256]u8 = undefined;

fn renderAiCopilotPanel(fb_width: c_int, fb_height: c_int, titlebar_offset: f32) void {
    if (!aiCopilotVisible()) return;
    const session = ensureActiveCopilotSession() orelse return;
    const left = leftPanelsWidth();
    const bounds = ai_sidebar.boundsForWindow(@intCast(fb_width), @intCast(fb_height), titlebar_offset, left, 0);
    const chat_x: f32 = @floatFromInt(bounds.left);
    const chat_w: f32 = @floatFromInt(bounds.right - bounds.left);
    assistant_conversation_renderer.render(session, @floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, chat_x, chat_w, true); // copilot sidebar: status shown as a colored dot
    renderAiCopilotCloseButton(bounds, @floatFromInt(fb_height));
}

fn renderAiCopilotCloseButton(bounds: ai_sidebar.Bounds, window_height: f32) void {
    const layout: hit_test.PanelHeaderLayout = .{
        .visible = true,
        .left = @floatFromInt(bounds.left),
        .right = @floatFromInt(bounds.right),
        .top = @floatFromInt(bounds.top),
        .height = assistant_conversation_renderer.HEADER_H,
    };
    const close = hit_test.panelCloseButtonRect(layout) orelse return;
    const close_x: f32 = @floatCast(close.left);
    const close_w: f32 = @floatCast(close.width);
    const close_h: f32 = @floatCast(close.height);
    const close_y = window_height - @as(f32, @floatCast(close.top + close.height));

    const bg = g_theme.background;
    const fg = g_theme.foreground;
    const hovered = blk: {
        const win = g_window orelse break :blk false;
        const mouse = window_backend.mousePosition(win);
        if (mouse.x < 0 or mouse.y < 0) break :blk false;
        break :blk hit_test.panelHeaderCloseButton(layout, @floatFromInt(mouse.x), @floatFromInt(mouse.y));
    };
    if (hovered) {
        ui_pipeline.fillQuadAlpha(close_x + 6, close_y + @round((close_h - 20) / 2), 20, 20, mixColor(bg, fg, 0.14), 0.95);
    }
    titlebar.renderCloseIcon(close_x, close_y, close_w, close_h, if (hovered) fg else mixColor(bg, fg, 0.68));
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

pub fn activeTab() ?*TabState {
    return tab.activeTab();
}

pub fn activeSurface() ?*Surface {
    return tab.activeSurface();
}

/// Gather GPU adapter + window/grid info and write the in-app benchmark report.
/// Called once from the main loop when `bench_driver.finished()` turns true.
fn finishBenchReport(win: *window_backend.Window) void {
    var adapter_buf: [256]u8 = undefined;
    const gpu_info: ?bench_report.GpuInfo = if (gpu.adapterReport(&adapter_buf)) |a|
        .{
            .backend = @tagName(gpu.active),
            .adapter = a.name,
            .vendor_id = a.vendor_id,
            .device_id = a.device_id,
        }
    else
        null;

    const fb = window_backend.framebufferSize(win);
    const window_info: ?bench_report.WindowInfo = .{
        .width_px = @intCast(fb.width),
        .height_px = @intCast(fb.height),
        .grid_cols = @intCast(term_cols),
        .grid_rows = @intCast(term_rows),
        .dpi = window_backend.effectiveDpi(win),
    };

    bench_driver.finishAndWriteReport(@tagName(gpu.active), gpu_info, window_info) catch |err| {
        std.debug.print("wispterm-benchmark: failed to write report: {}\n", .{err});
    };
}

fn surfaceOnAltScreen(s: *const Surface) bool {
    return s.terminal.screens.active_key == .alternate;
}

/// True if the focused surface is running a full-screen program (alt-screen).
pub fn activeSurfaceHasRunningProgram() bool {
    const s = activeSurface() orelse return false;
    return surfaceOnAltScreen(s);
}

/// True when the focused pane in the active tab is a terminal surface (rather than
/// a preview pane, a split node, or a non-terminal tab). Used to guard terminal
/// closes behind a confirm while preview panes still close on a single press.
pub fn focusedPaneIsTerminal() bool {
    return activeSurface() != null;
}

fn tabStateHasRunningProgram(t: *const TabState) bool {
    if (t.kind != .terminal) return false;
    var it = t.tree.surfaces();
    while (it.next()) |entry| {
        if (surfaceOnAltScreen(entry.surface)) return true;
    }
    return false;
}

/// True if any surface in the given tab is running a full-screen program.
pub fn tabHasRunningProgram(idx: usize) bool {
    if (idx >= tab.g_tab_count) return false;
    const t = tab.g_tabs[idx] orelse return false;
    return tabStateHasRunningProgram(t);
}

/// True if any surface in any tab in the window is running a full-screen program.
pub fn anyTabHasRunningProgram() bool {
    for (0..tab.g_tab_count) |ti| {
        const t = tab.g_tabs[ti] orelse continue;
        if (tabStateHasRunningProgram(t)) return true;
    }
    return false;
}

pub fn activeAiChat() ?*ai_chat.Session {
    return tab.activeAiChat();
}

pub fn activeAiHistory() ?*ai_history_session.Session {
    const active = activeTab() orelse return null;
    if (active.kind != .ai_history) return null;
    return active.ai_history_session;
}

pub fn activeMemoryCenter() ?*memory_center_session.Session {
    return tab.activeMemoryCenter();
}

pub fn activeSkillCenter() ?*skill_center.Session {
    return tab.activeSkillCenter();
}

pub fn activePortForwarding() ?*port_forwarding.Session {
    return tab.activePortForwarding();
}

pub const PortForwardingOverlayKind = enum {
    none,
    form,
    confirm_delete,
};

pub fn portForwardingOverlayKind() ?PortForwardingOverlayKind {
    const session = activePortForwarding() orelse return null;
    session.mutex.lock();
    defer session.mutex.unlock();
    return switch (session.model.overlay) {
        .none => .none,
        .form => .form,
        .confirm_delete => .confirm_delete,
    };
}

fn activePortForwardManager() ?*port_forward_manager.Manager {
    const app = g_app orelse return null;
    return &app.port_forward_manager;
}

pub fn portForwardingMove(delta: isize) bool {
    const session = activePortForwarding() orelse return false;
    const row_count = if (activePortForwardManager()) |manager| manager.count() else 0;
    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.move(delta, row_count);
    markUiDirty();
    return true;
}

pub fn portForwardingToggleSelected() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    const app = g_app orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const row = manager.rowAt(idx) orelse return false;
    const ok = switch (row.status) {
        .running, .starting => manager.stopIndex(idx),
        else => manager.startIndex(idx, app.ssh_legacy_algorithms),
    };
    markUiDirty();
    return ok;
}

pub fn portForwardingRestartSelected() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    const app = g_app orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const ok = manager.restartIndex(idx, app.ssh_legacy_algorithms);
    markUiDirty();
    return ok;
}

pub fn portForwardingToggleAutoStart() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const ok = manager.toggleAutoStart(idx);
    if (ok) _ = manager.save();
    markUiDirty();
    return ok;
}

pub fn portForwardingOpenNew() bool {
    const session = activePortForwarding() orelse return false;
    var name_buf: [port_forward_rule.PROFILE_MAX]u8 = undefined;
    const default_profile = firstSshProfileName(&name_buf);
    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.openNewForm(default_profile) catch return false;
    markUiDirty();
    return true;
}

/// Name of the first SSH profile in the store, written into `buf` (the returned
/// slice points into `buf`, not the freed file content). Returns "" when no
/// profiles exist or the store can't be read. Used to preselect the Profile
/// selector when opening a new forwarding rule.
fn firstSshProfileName(buf: []u8) []const u8 {
    const manager = activePortForwardManager() orelse return "";
    const allocator = manager.allocator;
    const content = readSshHostsContent(allocator) orelse return "";
    defer allocator.free(content);
    return ssh_profile_store.cycleProfileName(content, "", 0, buf);
}

/// Test seam: when set, readSshHostsContent serves a copy of this instead of
/// the real store, so tests never depend on the host's ssh_hosts file.
threadlocal var g_ssh_hosts_content_for_test: ?[]const u8 = null;

pub fn setSshHostsContentForTest(content: ?[]const u8) void {
    g_ssh_hosts_content_for_test = content;
}

/// Read the encoded ssh_hosts file. Caller frees. Returns null when unavailable.
fn readSshHostsContent(allocator: std.mem.Allocator) ?[]u8 {
    if (g_ssh_hosts_content_for_test) |content| return allocator.dupe(u8, content) catch null;
    const path = platform_dirs.sshHostsPath(allocator) catch return null;
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch null;
}

pub fn portForwardingOpenEdit() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const row = manager.rowAt(idx) orelse return false;

    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.openEditForm(idx, row.rule) catch return false;
    markUiDirty();
    return true;
}

pub fn portForwardingOpenDeleteConfirm() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const row = manager.rowAt(idx) orelse return false;
    const label = if (row.rule.name().len > 0) row.rule.name() else row.rule.profileName();

    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.openDeleteConfirm(idx, label) catch return false;
    markUiDirty();
    return true;
}

pub fn portForwardingConfirmOrApply() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;

    var form_copy: ?port_forwarding.FormState = null;
    var delete_index: ?usize = null;
    session.mutex.lock();
    switch (session.model.overlay) {
        .form => |form| form_copy = form,
        .confirm_delete => |confirm| delete_index = confirm.index,
        .none => {
            session.mutex.unlock();
            return false;
        },
    }
    session.mutex.unlock();

    var ok = false;
    if (form_copy) |form| {
        if (!form.rule.validate()) return false;
        ok = switch (form.mode) {
            .new => blk: {
                manager.addRule(form.rule) catch break :blk false;
                break :blk true;
            },
            .edit => if (form.edit_index) |idx| manager.updateRule(idx, form.rule) else false,
        };
    } else if (delete_index) |idx| {
        ok = manager.deleteRule(idx);
    }

    if (!ok) return false;
    _ = manager.save();
    const row_count = manager.count();
    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.clearOverlay();
    session.model.move(0, row_count);
    markUiDirty();
    return true;
}

pub fn portForwardingCancelOrClose() bool {
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    const had_overlay = session.model.overlay != .none;
    if (had_overlay) session.model.clearOverlay();
    session.mutex.unlock();
    if (had_overlay) {
        markUiDirty();
        return true;
    }
    input.closePanelOrTab();
    return true;
}

pub fn portForwardingFormMove(delta: isize) bool {
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return false;
    form.moveFocus(delta);
    markUiDirty();
    return true;
}

/// Adjust the focused selector field by `delta` steps. Profile cycles through
/// the SSH profiles in the store; Direction and Auto start flip. Other
/// (text/port) fields are unaffected. Used by Space (+1) and the ←/→ arrows.
pub fn portForwardingFormAdjust(delta: isize) bool {
    const session = activePortForwarding() orelse return false;

    // Determine the focused field and the current profile name without holding
    // the lock across the ssh_hosts file read below.
    session.mutex.lock();
    const focus = if (session.model.form()) |form| form.focus else {
        session.mutex.unlock();
        return false;
    };
    var current_buf: [port_forward_rule.PROFILE_MAX]u8 = undefined;
    var current_len: usize = 0;
    if (focus == port_forwarding.FIELD_PROFILE) {
        const form = session.model.form().?;
        const current = form.rule.profileName();
        current_len = @min(current_buf.len, current.len);
        @memcpy(current_buf[0..current_len], current[0..current_len]);
    }
    session.mutex.unlock();

    if (focus == port_forwarding.FIELD_PROFILE) {
        const manager = activePortForwardManager() orelse return false;
        const allocator = manager.allocator;
        const content = readSshHostsContent(allocator) orelse return false;
        defer allocator.free(content);
        var next_buf: [port_forward_rule.PROFILE_MAX]u8 = undefined;
        const next = ssh_profile_store.cycleProfileName(content, current_buf[0..current_len], delta, &next_buf);
        if (next.len == 0) return false;

        session.mutex.lock();
        defer session.mutex.unlock();
        const form = session.model.form() orelse return false;
        // The lock was released across the ssh_hosts read; re-verify the
        // Profile field still has focus before writing the cycled name.
        if (form.focus != port_forwarding.FIELD_PROFILE) return false;
        form.rule.setProfileName(next);
        markUiDirty();
        return true;
    }

    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return false;
    if (form.focus != port_forwarding.FIELD_DIRECTION and form.focus != port_forwarding.FIELD_AUTO_START) return false;
    form.toggleFocused();
    markUiDirty();
    return true;
}

pub fn portForwardingInsertChar(codepoint: u21) bool {
    if (codepoint > std.math.maxInt(u8)) return false;
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return false;
    form.insertChar(@intCast(codepoint));
    markUiDirty();
    return true;
}

pub fn portForwardingBackspace() bool {
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return false;
    form.backspace();
    markUiDirty();
    return true;
}

fn skillCenterHost() skill_center_actions.Host {
    return .{
        .allocator = g_allocator,
        .open_file_override = g_skill_center_open_file_override,
        .current_native_handle_bits = currentNativeHandleBits(),
        .mark_ui_dirty = markUiDirty,
    };
}

pub fn skillCenterMove(delta: isize) bool {
    return skill_center_actions.skillCenterMove(skillCenterHost(), delta);
}

pub fn skillCenterOverlayActive() bool {
    return skill_center_actions.skillCenterOverlayActive();
}

pub fn skillCenterOverlayCancel() bool {
    return skill_center_actions.skillCenterOverlayCancel();
}

pub fn skillCenterUrlInputActive() bool {
    return skill_center_actions.skillCenterUrlInputActive();
}

pub fn skillCenterOpenUrlInput() bool {
    return skill_center_actions.skillCenterOpenUrlInput(skillCenterHost());
}

pub fn skillCenterUrlInsertChar(codepoint: u21) bool {
    return skill_center_actions.skillCenterUrlInsertChar(skillCenterHost(), codepoint);
}

pub fn skillCenterUrlBackspace() bool {
    return skill_center_actions.skillCenterUrlBackspace(skillCenterHost());
}

pub fn skillCenterUrlPaste() bool {
    return skill_center_actions.skillCenterUrlPaste(skillCenterHost());
}

pub fn skillCenterPickActive() bool {
    return skill_center_actions.skillCenterPickActive();
}

pub fn skillCenterPickToggle() bool {
    return skill_center_actions.skillCenterPickToggle(skillCenterHost());
}

pub fn skillCenterPickSelectAll() bool {
    return skill_center_actions.skillCenterPickSelectAll(skillCenterHost());
}

fn skillCenterOpenPicker(purpose: skill_center.Purpose) bool {
    return skill_center_actions.openPicker(skillCenterHost(), purpose);
}

pub fn skillCenterDeploy() bool {
    return skill_center_actions.skillCenterDeploy(skillCenterHost());
}

pub fn skillCenterImport() bool {
    return skill_center_actions.skillCenterImport(skillCenterHost());
}

fn skillCenterSetStatusLocked(session: *skill_center.Session, text: []const u8) void {
    skill_center_actions.setStatusLocked(session, text);
}

pub fn skillCenterImportTool() bool {
    return skill_center_actions.skillCenterImportTool(skillCenterHost());
}

pub fn skillCenterToggleToolEnabled() bool {
    return skill_center_actions.skillCenterToggleToolEnabled(skillCenterHost());
}

fn skillCenterArmConfirm(allocator: std.mem.Allocator, is_import: bool, target: skill_center.Target, name: []const u8) void {
    skill_center_actions.armConfirm(skillCenterHost(), allocator, is_import, target, name);
}

pub fn skillCenterOverlaySelect() bool {
    return skill_center_actions.skillCenterOverlaySelect(skillCenterHost());
}

pub fn skillCenterRescan() bool {
    return skill_center_actions.skillCenterRescan(skillCenterHost());
}

pub fn skillCenterPreviewSelected() bool {
    return skill_center_actions.skillCenterPreviewSelected(skillCenterHost());
}

pub fn skillCenterTextPreviewActive() bool {
    return skill_center_actions.skillCenterTextPreviewActive();
}

pub const SkillCenterPreviewKind = skill_center_actions.SkillCenterPreviewKind;

pub fn skillCenterPreviewKind() SkillCenterPreviewKind {
    return skill_center_actions.skillCenterPreviewKind();
}

pub fn skillCenterPreviewScroll(delta: isize) bool {
    return skill_center_actions.skillCenterPreviewScroll(skillCenterHost(), delta);
}

pub fn skillCenterPreviewClose() bool {
    return skill_center_actions.skillCenterPreviewClose(skillCenterHost());
}

pub fn skillCenterSpacePreview() bool {
    return skill_center_actions.skillCenterSpacePreview(skillCenterHost());
}

fn skillCenterMakeImportState(allocator: std.mem.Allocator, model: *const skill_center.PanelModel, rows: []const skill_scan.SkillRow, target: skill_center.Target) !skill_center.ImportState {
    return skill_center_actions.makeImportState(allocator, model, rows, target);
}

fn startSkillCenterScan(allocator: std.mem.Allocator, session: *skill_center.Session) void {
    skill_center_actions.startScan(allocator, session);
}

pub fn aiHistoryInsertCodepoint(codepoint: u21) bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    const consumed = session.typeIntoSearch(codepoint);
    session.mutex.unlock();
    if (consumed) markUiDirty();
    return consumed;
}

/// True while the Sessions panel's Search box has keyboard focus. The input layer
/// uses this to decide whether 'r'/Space type into the query or fire the
/// Scan/Preview shortcuts.
pub fn aiHistorySearchFocused() bool {
    const session = activeAiHistory() orelse return false;
    return session.focus == .search;
}

/// True when a plain Space should preview the selected transcript instead of
/// typing into the Search box (search unfocused, or focused with an empty
/// query). Keeps "Press Space to load transcript" working from the default
/// focus while still allowing spaces inside a non-empty query.
pub fn aiHistorySpacePreviews() bool {
    const session = activeAiHistory() orelse return false;
    return session.spacePreviewsTranscript();
}

pub fn aiHistoryBackspaceFilter() bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    session.backspaceFilter();
    session.mutex.unlock();
    markUiDirty();
    return true;
}

pub fn aiHistoryMoveSelection(delta: isize) bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    session.moveSelection(delta);
    session.ensureSelectionVisible(aiHistoryListVisibleRowsForWindow());
    session.mutex.unlock();
    markUiDirty();
    return true;
}

/// ←/→ move keyboard focus between the Filters, Sessions, and Transcript panels.
pub fn aiHistoryFocusMove(delta: isize) bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    session.focusMove(delta);
    session.mutex.unlock();
    markUiDirty();
    return true;
}

/// ↑/↓ act within the focused panel: walk the combined CATEGORY+DATE filter
/// list, change the selected session, or scroll the transcript preview.
pub fn aiHistoryNav(delta: isize) bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    switch (session.focus) {
        .filters => {
            session.moveFilterCursor(delta);
            session.ensureFilterCursorVisible(aiHistoryDateDaySlotsForWindow());
            session.ensureSelectionVisible(aiHistoryListVisibleRowsForWindow());
        },
        // While typing in the Search box, ↑/↓ still walk the result list so you can
        // filter then arrow straight to a hit without leaving the query.
        .search, .sessions => {
            session.moveSelection(delta);
            session.ensureSelectionVisible(aiHistoryListVisibleRowsForWindow());
        },
        .transcript => session.scrollTranscriptBy(delta * AI_HISTORY_TRANSCRIPT_KEY_STEP),
    }
    session.mutex.unlock();
    markUiDirty();
    return true;
}

const AI_HISTORY_TRANSCRIPT_KEY_STEP: isize = 3;

pub fn aiHistoryPreviewSelectedTranscript() bool {
    const session = activeAiHistory() orelse return false;
    const allocator = g_allocator orelse return false;
    startAiHistoryTranscript(allocator, session);
    return true;
}

/// Scroll the transcript preview by `delta` wrapped visual lines (negative
/// scrolls up). The renderer clamps the offset against the content height.
pub fn aiHistoryScrollTranscript(delta: isize) bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    session.scrollTranscriptBy(delta);
    session.mutex.unlock();
    markUiDirty();
    return true;
}

/// Scroll the DATE navigator's day list by `delta` rows (negative scrolls up).
/// The renderer clamps the offset against the visible capacity each frame.
pub fn aiHistoryScrollDateList(delta: isize) bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    session.scrollDateBy(delta);
    session.mutex.unlock();
    markUiDirty();
    return true;
}

pub fn aiHistoryLoadSelectedTranscript() bool {
    return resumeAiHistorySelection();
}

pub fn memoryCenterCycleSource(delta: isize) bool {
    const session = activeMemoryCenter() orelse return false;
    session.cycleSource(delta);
    markUiDirty();
    return true;
}

pub fn memoryCenterMoveSelection(delta: isize) bool {
    const session = activeMemoryCenter() orelse return false;
    session.moveSelection(delta);
    markUiDirty();
    return true;
}

pub fn memoryCenterScrollDetail(delta: isize) bool {
    const session = activeMemoryCenter() orelse return false;
    session.scrollDetailBy(delta);
    markUiDirty();
    return true;
}

pub fn memoryCenterReload() bool {
    const allocator = g_allocator orelse return false;
    const session = activeMemoryCenter() orelse return false;
    session.reload(allocator);
    markUiDirty();
    return true;
}

pub fn memoryCenterHandleMousePress(xpos: f64, ypos: f64) bool {
    const session = activeMemoryCenter() orelse return false;
    const win = g_window orelse return false;
    const fb = window_backend.framebufferSize(win);
    const left = leftPanelsWidth();
    const width = aiHistoryContentWidth(fb.width, left, rightPanelsWidthForWindow(fb.width));
    const hit = memory_center_renderer.hitTest(
        session,
        @floatFromInt(fb.height),
        currentTitlebarHeight(),
        left,
        width,
        font.g_titlebar_cell_height,
        xpos,
        ypos,
    );
    switch (hit) {
        .source => |source| session.setSource(source),
        .row => |idx| session.selectIndex(idx),
        .detail => {},
        .none => return false,
    }
    markUiDirty();
    return true;
}

pub fn memoryCenterHandleMouseWheel(xpos: i32, ypos: i32, delta: i32) bool {
    const session = activeMemoryCenter() orelse return false;
    const win = g_window orelse return false;
    const fb = window_backend.framebufferSize(win);
    const left = leftPanelsWidth();
    const width = aiHistoryContentWidth(fb.width, left, rightPanelsWidthForWindow(fb.width));
    const hit = memory_center_renderer.hitTest(
        session,
        @floatFromInt(fb.height),
        currentTitlebarHeight(),
        left,
        width,
        font.g_titlebar_cell_height,
        @floatFromInt(xpos),
        @floatFromInt(ypos),
    );
    const direction: isize = if (delta > 0) -1 else 1;
    switch (hit) {
        .detail => session.scrollDetailBy(direction * 3),
        .source, .row, .none => session.moveSelection(direction),
    }
    markUiDirty();
    return true;
}

pub fn resumeAiHistorySelection() bool {
    const active = tab.activeTab() orelse return false;
    if (active.kind != .ai_history) return false;
    const session = active.ai_history_session orelse return false;
    const allocator = g_allocator orelse return false;

    session.mutex.lock();
    const selected = session.selectedVisible();
    const meta_clone: ?ai_history_types.SessionMeta = if (selected) |m|
        (ai_history_session.cloneMetadata(allocator, m) catch null)
    else
        null;
    session.mutex.unlock();

    const meta = meta_clone orelse return false;
    defer ai_history_session.freeMetadata(allocator, meta);
    return spawnResumeTerminal(session.source.target, meta);
}

pub fn spawnResumeTerminal(target: ai_history_source.Target, meta: ai_history_types.SessionMeta) bool {
    var resume_buf: [512]u8 = undefined;
    const resume_cmd = ai_history_resume.resumeCommand(meta, &resume_buf) catch |err| {
        log.warn("failed to build AI History provider resume command for {s}: {}", .{ meta.session_id, err });
        return showAiHistoryResumeFailure(err, meta);
    };

    var checked_buf: [2048]u8 = undefined;
    const checked_cmd = ai_history_resume.checkedPosixResume(resume_cmd, meta.project_dir, &checked_buf) catch |err| {
        log.warn("failed to build AI History checked resume command for {s}: {}", .{ meta.session_id, err });
        return showAiHistoryResumeFailure(err, meta);
    };

    var command_buf: [8192]u8 = undefined;
    switch (target) {
        .local => {
            var native_checked_buf: [2048]u8 = undefined;
            const local_checked_cmd = switch (platform_pty_command.backend()) {
                .windows => ai_history_resume.checkedPowerShellResume(meta, &native_checked_buf) catch |err| {
                    log.warn("failed to build AI History PowerShell resume command for {s}: {}", .{ meta.session_id, err });
                    return showAiHistoryResumeFailure(err, meta);
                },
                .unsupported => checked_cmd,
            };
            const shell_cmd = tab.getShellCmd();
            const command = platform_pty_command.localShellInitialCommand(command_buf[0..], shell_cmd, local_checked_cmd) orelse {
                if (platform_pty_command.backend() == .windows and !platform_pty_command.shellCommandLooksLikeConfiguredLocalShell(shell_cmd)) {
                    return showAiHistoryResumeToast("Cannot resume: set shell=powershell or pwsh");
                }
                return showAiHistoryResumeToast("Cannot resume: command is too long");
            };
            if (spawnTabWithCommandUtf8(command)) return true;
            return showAiHistoryResumeToast("Cannot resume: failed to open resume tab");
        },
        .wsl => {
            var user_shell_buf: [4096]u8 = undefined;
            const user_shell_cmd = ai_history_resume.posixUserShellCommand(checked_cmd, &user_shell_buf) catch |err| {
                log.warn("failed to build AI History WSL user-shell resume command for {s}: {}", .{ meta.session_id, err });
                return showAiHistoryResumeFailure(err, meta);
            };
            const command = platform_pty_command.wslShellCommand(command_buf[0..], user_shell_cmd) orelse return showAiHistoryResumeToast("Cannot resume: command is too long");
            if (spawnTabWithCommandUtf8(command)) return true;
            return showAiHistoryResumeToast("Cannot resume: failed to open resume tab");
        },
        .ssh => |ssh| {
            var user_shell_buf: [4096]u8 = undefined;
            const user_shell_cmd = ai_history_resume.posixUserShellCommand(checked_cmd, &user_shell_buf) catch |err| {
                log.warn("failed to build AI History SSH user-shell resume command for {s}: {}", .{ meta.session_id, err });
                return showAiHistoryResumeFailure(err, meta);
            };
            return switch (overlays.aiHistoryConnectSshProfile(ssh.profile_name, user_shell_cmd)) {
                .connected => true,
                .not_found => {
                    return showAiHistoryResumeToast("Cannot resume: SSH profile not found");
                },
                .failed => {
                    return showAiHistoryResumeToast("Cannot resume: SSH connection failed");
                },
            };
        },
    }
}

fn showAiHistoryResumeFailure(err: ai_history_resume.ResumeError, meta: ai_history_types.SessionMeta) bool {
    var msg_buf: [160]u8 = undefined;
    return showAiHistoryResumeToast(ai_history_resume.failureMessage(err, meta, &msg_buf));
}

fn showAiHistoryResumeToast(message: []const u8) bool {
    overlays.showStatusToast(message);
    markUiDirty();
    return false;
}

pub fn aiHistoryScanLocalNow() bool {
    const session = activeAiHistory() orelse return false;
    const allocator = g_allocator orelse return false;
    startAiHistoryScan(allocator, session);
    return true;
}

/// Everything a background AI History worker needs, snapshotted on the UI thread.
/// `ssh` carries a copied `SshConnection` value (inline buffers, no threadlocal
/// pointers). `local`/`wsl` resolve their inputs inside the worker.
const AiHistoryTarget = union(enum) {
    local,
    wsl,
    ssh: ssh_connection.SshConnection,
};

const AiHistoryScanJob = struct {
    target: AiHistoryTarget,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, source: ai_history_source.Source, sink: ?ai_history_session.ScanSink) anyerror!ai_history_session.ScanResult {
        const job: *AiHistoryScanJob = @ptrCast(@alignCast(ctx));
        switch (job.target) {
            .local => {
                const home = try localHomeForAiHistory(allocator);
                defer allocator.free(home);
                var parsed_cache = ai_history_cache.loadDefault(allocator) catch null;
                defer if (parsed_cache) |*cache| cache.deinit();
                var host_state = ai_history_session.LocalScannerHost{
                    .home = home,
                    .cache = if (parsed_cache) |cache| cache.value else null,
                };
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source, sink);
            },
            .wsl => {
                var parsed_cache = ai_history_cache.loadDefault(allocator) catch null;
                defer if (parsed_cache) |*cache| cache.deinit();
                var host_state = ai_history_session.WslScannerHost{
                    .cache = if (parsed_cache) |cache| cache.value else null,
                };
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source, sink);
            },
            .ssh => |conn| {
                var parsed_cache = ai_history_cache.loadDefault(allocator) catch null;
                defer if (parsed_cache) |*cache| cache.deinit();
                var host_state = ai_history_session.SshScannerHost{
                    .conn = conn,
                    .cache = if (parsed_cache) |cache| cache.value else null,
                };
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source, sink);
            },
        }
    }

    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *AiHistoryScanJob = @ptrCast(@alignCast(ctx));
        allocator.destroy(job);
    }
};

const AiHistoryTranscriptJob = struct {
    target: AiHistoryTarget,
    meta: ai_history_types.SessionMeta, // owned clone

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]ai_history_types.TranscriptMessage {
        const job: *AiHistoryTranscriptJob = @ptrCast(@alignCast(ctx));
        switch (job.target) {
            .local => {
                var host_state = ai_history_session.LocalScannerHost{ .home = "" };
                const host = host_state.scannerHost();
                return host.loadTranscript(host.ctx, allocator, job.meta);
            },
            .wsl => {
                var host_state = ai_history_session.WslScannerHost{};
                const host = host_state.scannerHost();
                return host.loadTranscript(host.ctx, allocator, job.meta);
            },
            .ssh => |conn| {
                var host_state = ai_history_session.SshScannerHost{ .conn = conn };
                const host = host_state.scannerHost();
                return host.loadTranscript(host.ctx, allocator, job.meta);
            },
        }
    }

    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *AiHistoryTranscriptJob = @ptrCast(@alignCast(ctx));
        ai_history_session.freeMetadata(allocator, job.meta);
        allocator.destroy(job);
    }
};

/// Snapshot the source's target into a worker-safe value (UI thread). Returns
/// null only when an SSH profile cannot be resolved.
fn aiHistoryTargetSnapshot(target: ai_history_source.Target) ?AiHistoryTarget {
    return switch (target) {
        .local => .local,
        .wsl => .wsl,
        .ssh => |ssh| .{ .ssh = overlays.aiHistorySshConnection(ssh.profile_name) orelse return null },
    };
}

/// Kick off an async scan for `session`. UI thread. On setup failure marks the
/// session failed instead of spawning a doomed worker.
fn startAiHistoryScan(allocator: std.mem.Allocator, session: *ai_history_session.Session) void {
    const target = aiHistoryTargetSnapshot(session.source.target) orelse {
        session.mutex.lock();
        session.state = .failed;
        session.status = "SSH profile unavailable";
        session.mutex.unlock();
        return;
    };
    const job = allocator.create(AiHistoryScanJob) catch {
        session.mutex.lock();
        session.state = .failed;
        session.status = "Scan failed";
        session.mutex.unlock();
        return;
    };
    job.* = .{ .target = target };
    session.scanAsync(.{ .ctx = job, .run = AiHistoryScanJob.run, .destroy = AiHistoryScanJob.destroy });
}

/// Kick off an async transcript load for the selected row. UI thread.
fn startAiHistoryTranscript(allocator: std.mem.Allocator, session: *ai_history_session.Session) void {
    session.mutex.lock();
    const selected = session.selectedVisible();
    const meta_clone: ?ai_history_types.SessionMeta = if (selected) |m|
        (ai_history_session.cloneMetadata(allocator, m) catch |err| blk: {
            log.warn("failed to clone ai history metadata for transcript: {}", .{err});
            break :blk null;
        })
    else
        null;
    session.mutex.unlock();

    const meta = meta_clone orelse return;

    const target = aiHistoryTargetSnapshot(session.source.target) orelse {
        ai_history_session.freeMetadata(allocator, meta);
        session.mutex.lock();
        session.transcript_state = .failed;
        session.transcript_status = "SSH profile unavailable";
        session.mutex.unlock();
        return;
    };
    const job = allocator.create(AiHistoryTranscriptJob) catch {
        ai_history_session.freeMetadata(allocator, meta);
        session.mutex.lock();
        session.transcript_state = .failed;
        session.transcript_status = "Transcript failed";
        session.mutex.unlock();
        return;
    };
    job.* = .{ .target = target, .meta = meta };
    session.loadTranscriptAsync(.{
        .ctx = job,
        .provider = job.meta.provider,
        .run = AiHistoryTranscriptJob.run,
        .destroy = AiHistoryTranscriptJob.destroy,
    });
}

fn selectedAiHistoryMetaForAction(allocator: std.mem.Allocator, session: *ai_history_session.Session) ?ai_history_types.SessionMeta {
    return session.selectedMetadataClone(allocator);
}

fn loadAiHistoryTranscriptForAction(
    allocator: std.mem.Allocator,
    session: *ai_history_session.Session,
    meta: ai_history_types.SessionMeta,
) ?[]ai_history_types.TranscriptMessage {
    session.mutex.lock();
    if (session.transcript_state == .ready and
        session.transcript_provider != null and
        session.transcript_provider.? == meta.provider)
    {
        const preview_copy = cloneAiHistoryTranscriptMessages(allocator, session.transcript) catch null;
        session.mutex.unlock();
        if (preview_copy) |copy| return copy;
    } else {
        session.mutex.unlock();
    }

    const target = aiHistoryTargetSnapshot(session.source.target) orelse return null;
    const messages: []ai_history_types.TranscriptMessage = switch (target) {
        .local => ai_history_session.loadLocalTranscript(allocator, meta) catch return null,
        .wsl => blk: {
            var host_state = ai_history_session.WslScannerHost{};
            const host = host_state.scannerHost();
            break :blk host.loadTranscript(host.ctx, allocator, meta) catch return null;
        },
        .ssh => |conn| blk: {
            var host_state = ai_history_session.SshScannerHost{ .conn = conn };
            const host = host_state.scannerHost();
            break :blk host.loadTranscript(host.ctx, allocator, meta) catch return null;
        },
    };

    const preview_copy = cloneAiHistoryTranscriptMessages(allocator, messages) catch null;
    if (preview_copy) |copy| session.replaceTranscriptFromMessages(meta.provider, copy);
    return messages;
}

fn cloneAiHistoryTranscriptMessages(
    allocator: std.mem.Allocator,
    messages: []const ai_history_types.TranscriptMessage,
) ![]ai_history_types.TranscriptMessage {
    const cloned = try allocator.alloc(ai_history_types.TranscriptMessage, messages.len);
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            allocator.free(cloned[initialized].content);
        }
        allocator.free(cloned);
    }
    for (messages) |msg| {
        cloned[initialized] = msg;
        cloned[initialized].content = try allocator.dupe(u8, msg.content);
        initialized += 1;
    }
    return cloned;
}

pub fn aiHistoryHandleMousePress(xpos: f64, ypos: f64) bool {
    const session = activeAiHistory() orelse return false;
    const win = g_window orelse return true;
    const fb = window_backend.framebufferSize(win);
    const left = leftPanelsWidth();
    const right = rightPanelsWidthForWindow(fb.width);
    const width = @as(f32, @floatFromInt(fb.width)) - left - right;
    const visible_rows = terminal_agent_sessions_renderer.listVisibleCapacity(@floatFromInt(fb.height), currentTitlebarHeight(), font.g_titlebar_cell_height);

    session.mutex.lock();
    const hit = terminal_agent_sessions_renderer.interactionHitTest(
        session,
        @floatFromInt(fb.width),
        @floatFromInt(fb.height),
        currentTitlebarHeight(),
        left,
        width,
        font.g_titlebar_cell_height,
        font.g_titlebar_cell_width,
        xpos,
        ypos,
    );
    session.mutex.unlock();

    switch (hit) {
        .none => {},
        .search => {
            session.mutex.lock();
            session.focus = .search;
            session.mutex.unlock();
            markUiDirty();
            return true;
        },
        .refresh => {
            _ = aiHistoryScanLocalNow();
            return true;
        },
        .@"resume" => {
            _ = resumeAiHistorySelection();
            markUiDirty();
            return true;
        },
        .download_raw => {
            _ = aiHistoryDownloadSelectedRaw();
            return true;
        },
        .export_markdown => {
            _ = aiHistoryExportSelectedMarkdown();
            return true;
        },
        .attach_copilot => {
            _ = aiHistoryAttachSelectedToCopilot();
            return true;
        },
        .category => |cat| {
            session.setCategory(cat);
            session.ensureSelectionVisible(visible_rows);
            markUiDirty();
            return true;
        },
        .date => |k| {
            session.setDateFilter(k);
            session.ensureSelectionVisible(visible_rows);
            markUiDirty();
            return true;
        },
        .row => |visible_index| {
            // Re-lock independently of the hit-test above: a worker may have
            // replaced rows in between, but selectVisibleIndex clamps to the
            // current visible count, so a now-stale index is safe. Clicking a row
            // also moves focus to the list so 'r'/Space act as Scan/Preview again.
            session.mutex.lock();
            session.focus = .sessions;
            session.selectVisibleIndex(visible_index);
            session.ensureSelectionVisible(visible_rows);
            session.mutex.unlock();
            markUiDirty();
            return true;
        },
    }
    markUiDirty();
    return true;
}

fn markUiDirty() void {
    applyUiEffect(.repaint);
}

/// Apply a UI-thread effect to AppWindow's legacy dirty flags.
///
/// This must run on the UI thread: the dirty flags are threadlocal, so worker
/// threads must queue work back to the UI thread and use `window_backend.postWakeup()`
/// rather than calling this helper directly.
pub fn applyUiEffect(effect: UiEffect) void {
    if (effect.needs_rebuild) g_force_rebuild = true;
    if (effect.cells_invalid) g_cells_valid = false;
    if (effect.wake_backend) window_backend.postWakeup();
}

/// Worker 线程用:直接唤醒后端事件循环,无需经 UiEffect 结构。
/// 供 feishu registration worker 等后台线程在状态变更后调用。
pub fn postWakeup() void {
    window_backend.postWakeup();
}

/// Tick all preview panes across every tab. Returns true if any pane
/// updated its content (caller should redraw).
fn tickAllPreviewPanes() bool {
    var changed = false;
    for (0..tab.g_tab_count) |ti| {
        const tb = tab.g_tabs[ti] orelse continue;
        var it = tb.tree.panes();
        while (it.next()) |e| switch (e.pane) {
            .preview => |p| {
                if (p.tickAsync()) changed = true;
            },
            else => {},
        };
    }
    return changed;
}

fn aiHistoryListVisibleRowsForWindow() usize {
    const win = g_window orelse return 1;
    const fb = window_backend.framebufferSize(win);
    return terminal_agent_sessions_renderer.listVisibleCapacity(@floatFromInt(fb.height), currentTitlebarHeight(), font.g_titlebar_cell_height);
}

/// Number of day rows (excluding the pinned "All dates") visible in the DATE
/// navigator, used to keep the Filters cursor's day in view.
fn aiHistoryDateDaySlotsForWindow() usize {
    const win = g_window orelse return 0;
    const fb = window_backend.framebufferSize(win);
    const cell_h = font.g_titlebar_cell_height;
    const lc = terminal_agent_sessions_renderer.leftColumnLayout(currentTitlebarHeight(), cell_h);
    const cap = terminal_agent_sessions_renderer.dateVisibleCapacity(@floatFromInt(fb.height), lc.date_rows_top, cell_h);
    return if (cap > 1) cap - 1 else 0;
}

fn localHomeForAiHistory(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "HOME")) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    } else |_| {}
    return error.NoHomeDirectory;
}

fn showAiHistoryActionToast(message: []const u8) bool {
    overlays.showStatusToast(message);
    markUiDirty();
    return true;
}

fn showNoAiHistorySelectionForAction() bool {
    return showAiHistoryActionToast("No AI History session selected");
}

pub fn aiHistoryDownloadSelectedRaw() bool {
    const allocator = g_allocator orelse return false;
    const session = activeAiHistory() orelse return showNoAiHistorySelectionForAction();
    const meta = selectedAiHistoryMetaForAction(allocator, session) orelse return showNoAiHistorySelectionForAction();
    defer ai_history_session.freeMetadata(allocator, meta);

    const path = chooseAiHistoryRawDownloadPath(allocator, meta) catch |err| {
        log.warn("failed to choose AI history raw download path for {s}: {}", .{ meta.session_id, err });
        return showAiHistoryActionToast("Raw download failed");
    } orelse {
        markUiDirty();
        return true;
    };
    defer allocator.free(path);

    var filename_buf: [180]u8 = undefined;
    const filename = ai_history_markdown.rawDownloadFilename(meta, &filename_buf);

    switch (session.source.target) {
        .local => {
            const bytes = readLocalAiHistoryRaw(allocator, meta.source_path) catch |err| {
                log.warn("failed to read local AI history raw file {s}: {}", .{ meta.source_path, err });
                return showAiHistoryActionToast("Raw download failed");
            };
            defer allocator.free(bytes);
            return writeAiHistoryRawDownload(path, bytes);
        },
        .wsl => {
            const bytes = readWslAiHistoryRaw(allocator, meta.source_path) catch |err| {
                log.warn("failed to read WSL AI history raw file {s}: {}", .{ meta.source_path, err });
                return showAiHistoryActionToast("WSL raw download failed");
            };
            defer allocator.free(bytes);
            return writeAiHistoryRawDownload(path, bytes);
        },
        .ssh => |ssh| {
            const conn = overlays.aiHistorySshConnection(ssh.profile_name) orelse {
                return showAiHistoryActionToast("SSH profile unavailable");
            };
            if (!file_explorer.downloadRemotePathToPath(meta.source_path, path, filename, &conn, false)) {
                return showAiHistoryActionToast("Raw download failed");
            }
            markUiDirty();
            return true;
        },
    }
}

fn writeAiHistoryRawDownload(path: []const u8, bytes: []const u8) bool {
    writeFilePath(path, bytes) catch |err| {
        log.warn("failed to write AI history raw download {s}: {}", .{ path, err });
        return showAiHistoryActionToast("Raw download failed");
    };
    if (input.copyTextToClipboard(path)) {
        return showAiHistoryActionToast("Downloaded raw file; path copied");
    }
    return showAiHistoryActionToast("Downloaded raw file");
}

pub fn aiHistoryExportSelectedMarkdown() bool {
    const allocator = g_allocator orelse return false;
    const session = activeAiHistory() orelse return showNoAiHistorySelectionForAction();
    const meta = selectedAiHistoryMetaForAction(allocator, session) orelse return showNoAiHistorySelectionForAction();
    defer ai_history_session.freeMetadata(allocator, meta);

    const messages = loadAiHistoryTranscriptForAction(allocator, session, meta) orelse {
        return showAiHistoryActionToast("Markdown export failed");
    };
    defer ai_history_session.freeTranscript(allocator, meta.provider, messages);

    const markdown = ai_history_markdown.allocMarkdownExport(allocator, meta, messages, .{}) catch |err| {
        log.warn("failed to render AI history Markdown export for {s}: {}", .{ meta.session_id, err });
        return showAiHistoryActionToast("Markdown export failed");
    };
    defer allocator.free(markdown);

    const path = chooseAiHistoryMarkdownExportPath(allocator, meta) catch |err| {
        log.warn("failed to choose AI history Markdown export path for {s}: {}", .{ meta.session_id, err });
        return showAiHistoryActionToast("Markdown export failed");
    } orelse {
        markUiDirty();
        return true;
    };
    defer allocator.free(path);

    writeFilePath(path, markdown) catch |err| {
        log.warn("failed to write AI history Markdown export {s}: {}", .{ path, err });
        return showAiHistoryActionToast("Markdown export failed");
    };

    if (input.copyTextToClipboard(path)) {
        return showAiHistoryActionToast("Exported AI History Markdown; path copied");
    }
    return showAiHistoryActionToast("Exported AI History Markdown");
}

pub fn aiHistoryAttachSelectedToCopilot() bool {
    const allocator = g_allocator orelse return false;
    const session = activeAiHistory() orelse return showNoAiHistorySelectionForAction();
    const meta = selectedAiHistoryMetaForAction(allocator, session) orelse return showNoAiHistorySelectionForAction();
    defer ai_history_session.freeMetadata(allocator, meta);

    const messages = loadAiHistoryTranscriptForAction(allocator, session, meta) orelse {
        return showAiHistoryActionToast("Attach failed");
    };
    defer ai_history_session.freeTranscript(allocator, meta.provider, messages);

    var context = ai_history_markdown.allocCopilotContext(allocator, meta, messages, 48 * 1024) catch |err| {
        log.warn("failed to render AI history Copilot context for {s}: {}", .{ meta.session_id, err });
        return showAiHistoryActionToast("Attach failed");
    };
    defer context.deinit(allocator);

    const target = ensureAiHistoryCopilotTarget() orelse return true;
    const title_text = std.fmt.allocPrint(
        allocator,
        "AI History: {s} {s}",
        .{ meta.provider.label(), meta.session_id },
    ) catch |err| {
        log.warn("failed to build AI history Copilot context title for {s}: {}", .{ meta.session_id, err });
        return showAiHistoryActionToast("Attach failed");
    };
    defer allocator.free(title_text);

    target.appendContextCard(title_text, context.markdown, true) catch |err| {
        log.warn("failed to attach AI history context to Copilot for {s}: {}", .{ meta.session_id, err });
        const message = switch (err) {
            error.SessionBusy => "Copilot is busy",
            error.SessionClosing => "Copilot session is closing",
            else => "Attach failed",
        };
        return showAiHistoryActionToast(message);
    };

    if (context.truncated) {
        return showAiHistoryActionToast("Attached AI History to Copilot; truncated");
    }
    return showAiHistoryActionToast("Attached AI History to Copilot");
}

fn activeMarkdownExportSession() ?*ai_chat.Session {
    if (activeAiChat()) |session| return session;
    return activeCopilotSessionForInput();
}

pub fn exportActiveAiChatMarkdown(mode: ai_chat.MarkdownExportMode) void {
    const session = activeMarkdownExportSession() orelse {
        overlays.showStatusToast("Open a Copilot tab or sidebar first");
        return;
    };
    exportAiChatMarkdown(session, mode);
}

fn exportAiChatMarkdown(session: *ai_chat.Session, mode: ai_chat.MarkdownExportMode) void {
    const allocator = g_allocator orelse return;

    const markdown = session.allocMarkdownExport(allocator, mode) catch |err| {
        log.warn("failed to render AI chat Markdown export: {}", .{err});
        overlays.showStatusToast("Markdown export failed");
        return;
    };
    defer allocator.free(markdown);

    const path = chooseAiChatMarkdownExportPath(allocator, mode) catch |err| {
        log.warn("failed to choose AI chat Markdown export path: {}", .{err});
        overlays.showStatusToast("Markdown export failed");
        return;
    } orelse return;
    defer allocator.free(path);

    writeFilePath(path, markdown) catch |err| {
        log.warn("failed to write AI chat Markdown export {s}: {}", .{ path, err });
        overlays.showStatusToast("Markdown export failed");
        return;
    };

    if (input.copyTextToClipboard(path)) {
        overlays.showStatusToast("Exported Markdown; path copied");
    } else {
        overlays.showStatusToast("Exported Markdown");
    }
    std.debug.print("Exported AI chat Markdown to {s}\n", .{path});
}

fn copyAiChatMarkdown(session: *ai_chat.Session, mode: ai_chat.MarkdownExportMode) void {
    const allocator = g_allocator orelse return;

    const markdown = session.allocMarkdownExport(allocator, mode) catch |err| {
        log.warn("failed to render AI chat Markdown for copy: {}", .{err});
        overlays.showStatusToast("Copy failed");
        return;
    };
    defer allocator.free(markdown);

    if (input.copyTextToClipboard(markdown)) {
        overlays.showCopyToast(markdown.len);
        markUiDirty();
    } else {
        overlays.showStatusToast("Copy failed");
    }
}

pub fn currentTitlebarHeight() f32 {
    if (g_window) |w| return @floatFromInt(window_backend.titlebarHeight(w));
    return titlebar.titlebarHeight();
}

pub fn leftPanelsWidth() f32 {
    return titlebar.sidebarWidth() + file_explorer.width();
}

fn copilotSidebarHost() copilot_sidebar.Host {
    return .{
        .allocator = g_allocator,
        .history_store = &g_agent_history,
        .history_mutex = &g_agent_history_mutex,
        .make_session = makeCopilotSession,
        .open_api_config = openCopilotApiConfig,
        .focus_input = input.focusAiCopilot,
        .blur_input = input.blurAiCopilot,
        .mark_dirty = markUiDirty,
        .mark_history_dirty_locked = markAgentHistoryDirtyLocked,
        .reopen_session = reopenCopilotSessionFromHistorySessionId,
    };
}

pub fn aiCopilotVisible() bool {
    return copilot_sidebar.visible();
}

/// True when a right-docked panel (browser / Jupyter webview) is showing for the
/// active tab. The Copilot edge handle defers while one is up, since they share
/// the exclusive right slot.
pub fn anyRightDockPanelVisible() bool {
    return browser_panel.isVisibleForActiveTab();
}

/// Hide the active tab's copilot panel if visible (used by the right-slot
/// arbiter when another right panel opens). No-op if already hidden.
pub fn hideAiCopilot() void {
    copilot_sidebar.hide(copilotSidebarHost());
}

pub fn aiCopilotWidth(window_width: i32) f32 {
    return copilot_sidebar.width(window_width, leftPanelsWidth());
}

fn makeCopilotSession() ?*ai_chat.Session {
    return overlays.makeCopilotSessionForDefaultProfile();
}

fn ensureActiveCopilotSession() ?*ai_chat.Session {
    return copilot_sidebar.ensureActiveSession(copilotSidebarHost());
}

fn ensureAiHistoryCopilotTarget() ?*ai_chat.Session {
    if (activeAiChat()) |session| return session;
    if (activeCopilotSessionForInput()) |session| return session;
    const allocator = g_allocator orelse {
        _ = showAiHistoryActionToast("Attach failed");
        return null;
    };
    const session = makeCopilotSession() orelse {
        overlays.openAiConfigForMissingCopilotApi();
        _ = showAiHistoryActionToast("Configure a Copilot profile first");
        return null;
    };
    if (!tab.spawnAiChatSession(allocator, session)) {
        session.deinit();
        _ = showAiHistoryActionToast("Attach failed");
        return null;
    }
    clearUiStateOnTabChange();
    return activeAiChat();
}

fn openCopilotApiConfig(session: ?*ai_chat.Session) void {
    if (session) |s| {
        overlays.openAiConfigForSession(s);
    } else {
        overlays.openAiConfigForMissingCopilotApi();
    }
    overlays.showStatusToast("Missing API key. Configure API settings.");
}

fn ensureActiveCopilotSessionConfigured() ?*ai_chat.Session {
    return copilot_sidebar.ensureActiveSessionConfigured(copilotSidebarHost());
}

/// Input layer getter: the active terminal tab's copilot session, only when the
/// copilot panel is visible. Used by input routing (next task).
pub fn activeCopilotSessionForInput() ?*ai_chat.Session {
    return copilot_sidebar.activeSessionForInput();
}

/// Build the picker rows from the store (copilot records only) and open it.
pub fn openCopilotConversationPicker() void {
    copilot_sidebar.openPicker(copilotSidebarHost());
}

/// (Re)load picker rows from the store. Called on open and after a delete.
pub fn refreshCopilotPickerRows() void {
    copilot_sidebar.refreshPickerRows(copilotSidebarHost());
}

/// Load conversation `session_id` into the active terminal tab's sidebar. If a
/// live copy is already open in some tab, switch to that tab instead (a second
/// live Session with the same id would corrupt the store).
pub fn loadCopilotConversationById(session_id: []const u8) void {
    copilot_sidebar.loadConversationById(copilotSidebarHost(), session_id);
}

pub fn deleteCopilotConversationById(session_id: []const u8) void {
    copilot_sidebar.deleteConversationById(copilotSidebarHost(), session_id);
}

/// Start a fresh, empty Copilot conversation on the active terminal tab.
pub fn newCopilotConversation() void {
    copilot_sidebar.newConversation(copilotSidebarHost());
}

/// The preview pane that currently has split-tree focus, or null if the
/// focused leaf is a terminal (or there is no active tab / the handle is
/// stale). Used to route keyboard scroll/zoom to a focused preview leaf.
pub fn focusedPreviewPane() ?*PreviewPane {
    const t = tab.activeTab() orelse return null;
    if (t.focused.idx() >= t.tree.nodes.len) return null;
    return switch (t.tree.nodes[t.focused.idx()]) {
        .leaf => |pane| switch (pane) {
            .preview => |p| p,
            else => null,
        },
        .split => null,
    };
}

/// Inserts `text` into a visible AI chat composer when a file is dropped at
/// framebuffer-pixel `(x, y)`. Returns true if the point landed over a chat
/// surface and the text was inserted. Checks the dedicated AI-chat tab first
/// (its whole content area is the drop target), then the right-docked copilot
/// panel. Called by the file-drop pipeline (input/clipboard.zig). Coordinates
/// are framebuffer px, matching the OS drop events and clientSize.
pub fn appendDroppedPathToChatAtPoint(text: []const u8, x: i32, y: i32) bool {
    const win = g_window orelse return false;
    const size = window_backend.clientSize(win);

    if (activeAiChat()) |session| {
        const px: f32 = @floatFromInt(x);
        const py: f32 = @floatFromInt(y);
        const left = leftPanelsWidth();
        const top = currentTitlebarHeight();
        const right = @as(f32, @floatFromInt(size.width)) - rightPanelsWidthForWindow(size.width);
        const bottom: f32 = @floatFromInt(size.height);
        if (px >= left and px < right and py >= top and py < bottom) {
            session.appendInputText(text);
            return true;
        }
        return false;
    }

    if (aiCopilotVisible()) {
        const bounds = ai_sidebar.boundsForWindow(size.width, size.height, currentTitlebarHeight(), leftPanelsWidth(), 0);
        if (x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom) {
            const session = activeCopilotSessionForInput() orelse return false;
            session.appendInputText(text);
            input.focusAiCopilot();
            return true;
        }
    }

    return false;
}

pub fn toggleAiCopilot() void {
    copilot_sidebar.toggle(copilotSidebarHost());
}

pub fn rightPanelsWidth() f32 {
    const copilot_w = if (aiCopilotVisible()) ai_sidebar.g_width else 0;
    return browser_panel.width() + copilot_w;
}

pub fn rightPanelsWidthForWindow(window_width: i32) f32 {
    const browser_w = browser_panel.panelWidthForWindow(window_width, leftPanelsWidth(), 0);
    return browser_w + aiCopilotWidth(window_width);
}

pub fn browserPanelRightOffset() f32 {
    // The preview is a split-tree leaf now, not a right-dock, so it reserves no
    // right-edge space for the browser panel.
    return 0;
}

fn aiChatExportRoot(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.exportsDir(allocator);
}

fn chooseAiChatMarkdownExportPath(
    allocator: std.mem.Allocator,
    mode: ai_chat.MarkdownExportMode,
) !?[]u8 {
    const root = try aiChatExportRoot(allocator);
    defer allocator.free(root);
    std.fs.cwd().makePath(root) catch |err| {
        log.warn("failed to create AI chat export directory {s}: {}", .{ root, err });
    };

    const suffix = switch (mode) {
        .full => "full",
        .clean => "clean",
    };
    const filename = try std.fmt.allocPrint(
        allocator,
        "ai-chat-{d}-{s}.md",
        .{ std.time.milliTimestamp(), suffix },
    );
    defer allocator.free(filename);

    return saveMarkdownDialogPath(allocator, root, filename);
}

fn chooseAiHistoryMarkdownExportPath(
    allocator: std.mem.Allocator,
    meta: ai_history_types.SessionMeta,
) !?[]u8 {
    const root = try aiChatExportRoot(allocator);
    defer allocator.free(root);
    std.fs.cwd().makePath(root) catch |err| {
        log.warn("failed to create AI history export directory {s}: {}", .{ root, err });
    };
    var safe_buf: [180]u8 = undefined;
    const raw = ai_history_markdown.rawDownloadFilename(meta, &safe_buf);
    const filename = try std.fmt.allocPrint(allocator, "ai-history-{s}.md", .{std.fs.path.stem(raw)});
    defer allocator.free(filename);
    return saveMarkdownDialogPathWithTitle(allocator, "Save AI History Markdown", root, filename);
}

fn chooseAiHistoryRawDownloadPath(
    allocator: std.mem.Allocator,
    meta: ai_history_types.SessionMeta,
) !?[]u8 {
    const root = platform_dirs.downloadsDir(allocator) catch try aiChatExportRoot(allocator);
    defer allocator.free(root);
    var filename_buf: [180]u8 = undefined;
    const filename = ai_history_markdown.rawDownloadFilename(meta, &filename_buf);
    const filters = [_]platform_file_dialog.Filter{.{ .name = "All Files (*.*)", .pattern = "*.*" }};
    const owner: platform_file_dialog.Owner = if (g_window) |w|
        platform_file_dialog.windowOwner(window_backend.nativeHandleBits(w))
    else
        .{};
    return platform_file_dialog.saveFile(allocator, .{
        .owner = owner,
        .title = "Save AI History Raw File",
        .initial_dir = root,
        .default_filename = filename,
        .filters = &filters,
    }) orelse {
        overlays.showStatusToast("Raw download cancelled");
        return null;
    };
}

fn saveMarkdownDialogPath(
    allocator: std.mem.Allocator,
    initial_dir: []const u8,
    default_filename: []const u8,
) !?[]u8 {
    return saveMarkdownDialogPathWithTitle(allocator, "Save Copilot Markdown", initial_dir, default_filename);
}

fn saveMarkdownDialogPathWithTitle(
    allocator: std.mem.Allocator,
    title_text: []const u8,
    initial_dir: []const u8,
    default_filename: []const u8,
) !?[]u8 {
    const filters = [_]platform_file_dialog.Filter{
        .{ .name = "Markdown (*.md)", .pattern = "*.md" },
        .{ .name = "All Files (*.*)", .pattern = "*.*" },
    };
    const owner: platform_file_dialog.Owner = if (g_window) |w|
        platform_file_dialog.windowOwner(window_backend.nativeHandleBits(w))
    else
        .{};
    const path = platform_file_dialog.saveFile(allocator, .{
        .owner = owner,
        .title = title_text,
        .initial_dir = initial_dir,
        .default_filename = default_filename,
        .default_extension = "md",
        .filters = &filters,
    }) orelse {
        overlays.showStatusToast("Markdown export cancelled");
        return null;
    };
    return path;
}

fn writeFilePath(path: []const u8, bytes: []const u8) !void {
    try platform_atomic_file.writeFileReplaceSafe(path, bytes);
}

fn readLocalAiHistoryRaw(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, ai_history_session.MAX_TRANSCRIPT_FILE_BYTES);
    }
    return try std.fs.cwd().readFileAlloc(allocator, path, ai_history_session.MAX_TRANSCRIPT_FILE_BYTES);
}

fn readWslAiHistoryRaw(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var command_buf: [2048]u8 = undefined;
    const command = try ai_history_session.remoteCatCommand(path, command_buf[0..]);
    return remote_file.wslExecCapped(allocator, command, ai_history_session.MAX_TRANSCRIPT_FILE_BYTES) orelse error.RemoteExecFailed;
}

fn syncWindowTitlebarHeight(win: *window_backend.Window) f32 {
    const next: i32 = @intFromFloat(titlebar.titlebarHeight());
    window_backend.setTitlebarHeight(win, next);
    return @floatFromInt(next);
}

pub fn activeSelection() *Selection {
    return tab.activeSelection();
}

pub fn isActiveTabTerminal() bool {
    return tab.isActiveTabTerminal();
}

/// Clear UI state after tab creation or switch.
fn syncActiveSurfaceCaches() void {
    split_layout.invalidateCachedRects();
    const surface = activeSurface();
    cell_renderer.g_current_render_surface = surface;
    if (surface) |s| {
        surface_snapshots.setAgentContextSurface(s);
        if (tab.activeTab()) |t| {
            if (t.kind == .terminal) {
                if (t.copilot_session) |session| session.setBoundSurface(s.remote_id[0..]);
            }
        }
    }
}

pub fn handleActiveSurfaceChangeWithinTab() void {
    syncVisibleFileExplorerForActiveTab(false);
    syncActiveSurfaceCaches();
    applyUiEffect(.{ .needs_rebuild = true, .cells_invalid = true });
}

fn clearUiStateOnTabChange() void {
    input.g_selecting = false;
    input.g_sidebar_resize_hover = false;
    input.g_sidebar_resize_dragging = false;
    input.g_explorer_resize_hover = false;
    input.g_explorer_resize_dragging = false;
    input.g_browser_resize_hover = false;
    input.g_browser_resize_dragging = false;
    input.blurAiCopilot();
    browser_panel.blurUrlBar();
    input.g_divider_dragging = false;
    input.g_divider_drag_handle = null;
    input.g_divider_drag_layout = null;
    overlays.resize.g_resize_overlay_visible = false;
    overlays.resize.g_resize_overlay_opacity = 0;
    overlays.resize.g_resize_overlay_suppress_until = std.time.milliTimestamp() + 100;
    syncVisibleFileExplorerForActiveTab(false);
    syncActiveSurfaceCaches();
    requestImmediateLayoutResize();
    g_force_rebuild = true;
    g_cells_valid = false;
}

/// Convert the active surface's CWD from a WSL guest path to a platform-native path.
fn getActiveCwd(cwd_buf: *platform_pty_command.CwdBuffer) platform_pty_command.Cwd {
    if (tab.activeSurface()) |surface| {
        if (surface.getCwd()) |guest_path| {
            if (platform_wsl.nativeCwdForLaunchKind(surface.launch_kind, guest_path, cwd_buf)) |cwd| {
                return platform_pty_command.cwdFromBuffer(cwd_buf, cwd.len);
            }
        }
        if (surface.launch_kind == .local) {
            if (surface.getInitialCwd()) |initial_cwd| {
                return platform_pty_command.cwdFromUtf8(cwd_buf, initial_cwd);
            }
        }
    }
    return null;
}

fn ensureGlobalAgentHistoryStore(allocator: std.mem.Allocator) !void {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (g_agent_history != null) return;

    const store = try allocator.create(agent_history_store.MetaStore);
    errdefer allocator.destroy(store);
    const dir = try platform_dirs.agentHistoryDir(allocator);
    defer allocator.free(dir);
    store.* = try agent_history_store.MetaStore.open(allocator, dir);
    g_agent_history = store;
    g_flush_scheduler.reset();
    g_agent_history_revision = 0;
}

fn installSessionRestoreHooks() void {
    // AppWindow owns the stores needed to rebuild non-terminal tab kinds, so
    // tab.zig routes persisted AI snapshots back through these hooks.
    tab.g_ai_restore_hook = reopenAiChatTabFromHistorySessionId;
    tab.g_ai_history_restore_hook = reopenAiHistoryTabFromSnapshot;
    // Copilot sidebar conversations are stored in the same agent-history store;
    // rehydrate them in place when restoring their owning terminal tab.
    tab.g_copilot_restore_hook = reopenCopilotSessionFromHistorySessionId;
    // tmux session persistence (#4c): save the active tmux profile names; on
    // restore, re-attach each via the launcher's tmux connect path.
    tab.g_tmux_active_profiles_hook = tmux_controller.activeProfileNames;
    tab.g_tmux_restore_hook = overlays.connectProfileByNameTmux;
    tab.g_ssh_restore_arm_hook = overlays.armSshPasswordFromProfileForSurface;
}

fn deinitGlobalAgentHistoryStore(allocator: std.mem.Allocator) void {
    flushAgentHistoryStoreIfDirty(true);

    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (g_agent_history) |store| {
        store.deinit();
        allocator.destroy(store);
        g_agent_history = null;
    }
    g_flush_scheduler.reset();
    g_agent_history_revision = 0;
}

fn saveAiHistoryChangeEvent(event: ai_chat.HistoryChangeEvent) void {
    var owned_event = event;
    defer owned_event.deinit();

    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    const store = g_agent_history orelse return;
    store.upsertRecord(owned_event.record) catch |err| {
        log.warn("failed to clone AI history update for session {s}: {}", .{ owned_event.record.session_id, err });
        return;
    };
    markAgentHistoryDirtyLocked();
}

fn persistOpenAiChatTabsToHistoryStore(allocator: std.mem.Allocator) void {
    for (0..tab.g_tab_count) |idx| {
        const tab_state = tab.g_tabs[idx] orelse continue;
        const session: *ai_chat.Session = switch (tab_state.kind) {
            .ai_chat => tab_state.ai_chat_session orelse continue,
            .terminal => blk: {
                const cs = tab_state.copilot_session orelse continue;
                if (!cs.shouldPersistCopilot()) continue;
                break :blk cs;
            },
            else => continue,
        };

        var record = session.toHistoryRecord(allocator) catch |err| {
            log.warn("failed to snapshot open AI tab for session restore: {}", .{err});
            continue;
        };

        g_agent_history_mutex.lock();
        if (g_agent_history) |store| {
            if (store.upsertRecord(record)) {
                markAgentHistoryDirtyLocked();
            } else |err| {
                log.warn("failed to persist open AI tab {s}: {}", .{ record.session_id, err });
            }
        }
        g_agent_history_mutex.unlock();

        agent_history.freeOwnedRecord(allocator, &record);
    }
}

fn markAgentHistoryDirtyLocked() void {
    g_flush_scheduler.markDirty(std.time.milliTimestamp());
    g_agent_history_revision +%= 1;
}

fn flushAgentHistoryStoreIfDirty(force: bool) void {
    const now = std.time.milliTimestamp();
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (!g_flush_scheduler.shouldFlush(force, now)) return;
    const store = g_agent_history orelse return;
    store.flush() catch |err| {
        log.warn("failed to flush agent history store: {}", .{err});
        g_flush_scheduler.failFlush(std.time.milliTimestamp());
        return;
    };
    g_flush_scheduler.beginFlush();
}

fn spawnTabWithCwd(allocator: std.mem.Allocator, cwd: platform_pty_command.Cwd) bool {
    if (!tab.spawnTabWithCwd(allocator, term_cols, term_rows, g_cursor_style, g_cursor_blink, cwd)) return false;
    clearUiStateOnTabChange();
    return true;
}

pub fn spawnTab(allocator: std.mem.Allocator) bool {
    var cwd_buf: platform_pty_command.CwdBuffer = undefined;
    const cwd = getActiveCwd(&cwd_buf);
    return spawnTabWithCwd(allocator, cwd);
}

pub fn spawnTabWithCommandUtf8(command: []const u8) bool {
    return spawnTabWithCommandUtf8ReturningSurface(command) != null;
}

/// Start a tmux control-mode session (Phase 3d). `ssh_cmd` is a full
/// `ssh … tmux -CC …` command; `password` is injected at the SSH prompt (empty
/// for key auth). The controller (pumped from the main loop) builds tabs/splits
/// from the remote tmux windows/panes. Returns false if the transport could not
/// be launched.
pub fn startTmuxSession(ssh_cmd: []const u8, password: []const u8, profile_name: []const u8, ssh_conn: ?@import("ssh/connection.zig").SshConnection) bool {
    const allocator = g_allocator orelse return false;
    return tmux_controller.start(
        allocator,
        ssh_cmd,
        password,
        profile_name,
        term_cols,
        term_rows,
        tab.g_scrollback_limit,
        g_cursor_style,
        g_cursor_blink,
        ssh_conn,
    );
}

pub fn spawnTabWithCommandUtf8ReturningSurface(command: []const u8) ?*Surface {
    const allocator = g_allocator orelse return null;
    const command_line = platform_pty_command.allocCommandLineFromUtf8(allocator, command) catch return null;
    defer platform_pty_command.freeCommandLine(allocator, command_line);

    var cwd_buf: platform_pty_command.CwdBuffer = undefined;
    const cwd = getActiveCwd(&cwd_buf);
    if (!tab.spawnTabWithCommandAndCwd(allocator, term_cols, term_rows, platform_pty_command.commandLineFromOwned(command_line), g_cursor_style, g_cursor_blink, cwd)) return null;
    clearUiStateOnTabChange();
    return activeSurface();
}

pub fn syncDefaultShellCommandFromConfig(shell: []const u8) void {
    tab.g_shell_cmd_len = App.resolveShellCommandLine(&tab.g_shell_cmd_buf, shell);
}

/// Store the configured primary font family in our own buffer. Must be used
/// instead of aliasing App.font_family, which is freed/reallocated on reload.
fn setRequestedFont(family: []const u8) void {
    const n = @min(family.len, g_requested_font_buf.len);
    @memcpy(g_requested_font_buf[0..n], family[0..n]);
    g_requested_font = g_requested_font_buf[0..n];
}

threadlocal var g_configured_shell_title_buf: [1024]u8 = undefined;
threadlocal var g_configured_shell_detail_buf: [1024]u8 = undefined;

pub fn configuredLocalShellSessionTitle() []const u8 {
    const display = platform_pty_command.commandLineDisplay(tab.getShellCmd(), &g_configured_shell_title_buf);
    if (display.len == 0) return platform_pty_command.localShellLauncherTitle();

    const title = platform_pty_command.friendlyShellTitle(display);
    if (title.len == 0) return platform_pty_command.localShellLauncherTitle();
    return title;
}

pub fn configuredLocalShellSessionDetail() []const u8 {
    const display = platform_pty_command.commandLineDisplay(tab.getShellCmd(), &g_configured_shell_detail_buf);
    if (display.len == 0) return platform_pty_command.guaranteedLocalShellCommand();
    return display;
}

pub fn spawnConfiguredLocalShellTab() bool {
    const shell_cmd = tab.getShellCmd();

    if (spawnLocalShellCommandLine(shell_cmd)) return true;

    // Keep the issue #65 safety net: if the configured shell cannot launch, open
    // a guaranteed local shell so the user is not left without a terminal.
    const fallback = platform_pty_command.guaranteedLocalShellCommand();
    var configured_buf: [1024]u8 = undefined;
    const configured = platform_pty_command.commandLineDisplay(shell_cmd, &configured_buf);
    if (std.mem.eql(u8, configured, fallback)) return false;
    return spawnTabWithCommandUtf8(fallback);
}

fn spawnLocalShellCommandLine(shell_cmd: platform_pty_command.CommandLine) bool {
    const allocator = g_allocator orelse return false;
    var cwd_buf: platform_pty_command.CwdBuffer = undefined;
    const cwd = getActiveCwd(&cwd_buf);
    if (!tab.spawnTabWithCommandAndCwd(allocator, term_cols, term_rows, shell_cmd, g_cursor_style, g_cursor_blink, cwd)) return false;
    clearUiStateOnTabChange();
    return true;
}

fn spawnDefaultAgentAndLocalShellTabs(allocator: std.mem.Allocator) bool {
    const first_tab_index = tab.g_tab_count;
    const has_ai_profile = overlays.hasAiProfiles();

    // Open the local shell first so it is the leftmost, default-focused tab.
    const local_shell_opened = spawnConfiguredLocalShellTab();

    // Then open the Agent session to the right of the shell. With no AI profile
    // there is no agent to open, so fall back to a second local shell tab.
    const second_opened = if (has_ai_profile)
        overlays.openDefaultAgentSessionForStartup() == .opened
    else
        spawnTabWithCwd(allocator, null);

    if (!local_shell_opened and !second_opened) return false;

    // Focus the shell (the first tab).
    if (first_tab_index < tab.g_tab_count) {
        switchTab(first_tab_index);
    }

    // No AI profile yet, first launch only: surface the Quick Configure AI overlay so
    // the user can paste a DeepSeek key in one step (it's an overlay, not a tab). The
    // persisted ai-setup-prompted flag suppresses it after it has been shown once, so
    // it does not reappear every launch — opening the Copilot sidebar later still
    // prompts setup when no AI is configured.
    if (startup_tabs.shouldAutoShowAgentForm(has_ai_profile, platform_window_state.aiSetupPrompted(allocator))) {
        overlays.openQuickAiForm();
        platform_window_state.setAiSetupPrompted(allocator);
    }

    // After an upgrade, surface the changelog once (records last-seen version
    // unconditionally so it shows at most once per upgrade).
    if (g_app) |app| {
        if (app.shouldShowWhatsNewOnStartup(allocator)) overlays.showWhatsNew();
    }

    return true;
}

pub fn spawnAiChatTab(
    name: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    protocol: []const u8,
    system_prompt: []const u8,
    thinking: []const u8,
    reasoning_effort: []const u8,
    stream_val: []const u8,
    agent_val: []const u8,
    max_tokens: u32,
    vision_val: []const u8,
    command: []const u8,
) bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnAiChatTab(allocator, name, base_url, api_key, model, protocol, system_prompt, thinking, reasoning_effort, stream_val, agent_val, max_tokens, vision_val, command)) return false;
    clearUiStateOnTabChange();
    return true;
}

pub fn spawnAiHistoryTab(source: ai_history_source.Source) bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnAiHistoryTab(allocator, source)) return false;
    clearUiStateOnTabChange();
    if (activeAiHistory()) |session| startAiHistoryScan(allocator, session);
    return true;
}

pub fn spawnMemoryCenterTab() bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnMemoryCenterTab(allocator)) return false;
    clearUiStateOnTabChange();
    markUiDirty();
    return true;
}

/// Opens a dedicated Memory Center tab so digest progress stays scoped to it.
pub fn runMemoryDigestNow() bool {
    const allocator = g_allocator orelse return false;
    if (!spawnMemoryCenterTab()) return false;
    memory_digest_scheduler.runNow(allocator);
    syncMemoryDigestStatus();
    return true;
}

/// Runs a digest from the focused Memory Center without creating another tab.
pub fn runMemoryDigestFromCenter() bool {
    const allocator = g_allocator orelse return false;
    if (activeMemoryCenter() == null) return false;
    memory_digest_scheduler.runNow(allocator);
    syncMemoryDigestStatus();
    return true;
}

/// Open a new Skill Center tab and scan the local library.
pub fn spawnSkillCenterTab() bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnSkillCenterTab(allocator)) return false;
    clearUiStateOnTabChange();
    if (activeSkillCenter()) |session| {
        startSkillCenterScan(allocator, session);
    }
    return true;
}

pub fn spawnPortForwardingTab() bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnPortForwardingTab(allocator)) return false;
    clearUiStateOnTabChange();
    markUiDirty();
    return true;
}

pub fn reopenAiChatTabFromHistorySessionId(session_id: []const u8) bool {
    if (tab.switchToAiTabBySessionId(session_id)) {
        clearUiStateOnTabChange();
        return true;
    }

    const allocator = g_allocator orelse return false;
    g_agent_history_mutex.lock();
    const record = if (g_agent_history) |store|
        store.cloneRecordBySessionId(allocator, session_id) catch null
    else
        null;
    g_agent_history_mutex.unlock();

    var owned_record = record orelse return false;
    defer agent_history.freeOwnedRecord(allocator, &owned_record);

    if (!tab.spawnAiChatTabFromHistoryRecord(allocator, owned_record)) return false;
    clearUiStateOnTabChange();
    return true;
}

fn reopenCopilotSessionFromHistorySessionId(session_id: []const u8) ?*ai_chat.Session {
    const allocator = g_allocator orelse return null;

    const maybe_record: ?agent_history.SessionRecord = blk: {
        g_agent_history_mutex.lock();
        defer g_agent_history_mutex.unlock();
        const store = g_agent_history orelse break :blk null;
        break :blk store.cloneRecordBySessionId(allocator, session_id) catch null;
    };
    var record = maybe_record orelse return null;
    defer agent_history.freeOwnedRecord(allocator, &record);

    const session = ai_chat.Session.initFromHistoryRecord(allocator, record) catch return null;
    // initFromHistoryRecord set session.copilot from the record marker; wire the
    // same incremental-save hook AI-chat tabs use so future turns keep persisting.
    session.setHistoryChangeHook(saveAiHistoryChangeEvent);
    return session;
}

fn aiHistorySourceFromSnap(snap: session_persist.AiHistorySnap) ?ai_history_source.Source {
    if (snap.source_id.len == 0) return null;
    const name = if (snap.target_name.len > 0) snap.target_name else snap.source_id;

    if (std.ascii.eqlIgnoreCase(snap.target_kind, "local")) {
        return .{
            .id = snap.source_id,
            .name = name,
            .target = .local,
        };
    }
    if (std.ascii.eqlIgnoreCase(snap.target_kind, "wsl")) {
        return .{
            .id = snap.source_id,
            .name = name,
            .target = .{ .wsl = .{} },
        };
    }
    if (std.ascii.eqlIgnoreCase(snap.target_kind, "ssh")) {
        return .{
            .id = snap.source_id,
            .name = name,
            .target = .{ .ssh = .{ .profile_name = name } },
        };
    }
    return null;
}

fn reopenAiHistoryTabFromSnapshot(snap: session_persist.AiHistorySnap) bool {
    const source = aiHistorySourceFromSnap(snap) orelse return false;
    return spawnAiHistoryTab(source);
}

pub fn deleteAiChatHistorySessionId(session_id: []const u8) bool {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    const store = g_agent_history orelse return false;
    if (!store.deleteBySessionId(session_id)) return false;
    markAgentHistoryDirtyLocked();
    return true;
}

pub const AgentHistoryRowsSnapshot = struct {
    rows: []agent_history.Row,
    revision: u64,
};

pub fn snapshotAgentHistoryRowsForCommandPalette(allocator: std.mem.Allocator) !AgentHistoryRowsSnapshot {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (g_agent_history) |store| {
        return .{
            .rows = try store.buildRows(allocator),
            .revision = g_agent_history_revision,
        };
    }

    return .{
        .rows = try allocator.alloc(agent_history.Row, 0),
        .revision = g_agent_history_revision,
    };
}

pub fn agentHistoryRevision() u64 {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();
    return g_agent_history_revision;
}

pub fn syncVisibleFileExplorerForActiveTab(force: bool) void {
    if (!file_explorer.isVisibleForActiveTab()) return;

    const is_ai_tab = activeAiChat() != null;
    if (is_ai_tab) {
        file_explorer.syncPanelForTabKind(true);
        syncFileExplorerAgentHistoryRows();
        return;
    }

    syncFileExplorerToActiveTerminalSurface(force);
}

pub fn syncFileExplorerAgentHistoryRows() void {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (g_agent_history) |store| {
        file_explorer.syncAgentHistoryRows(store);
        return;
    }

    var empty_store = agent_history.Store.init(std.heap.page_allocator);
    defer empty_store.deinit();
    file_explorer.syncAgentHistoryRows(&empty_store);
}

/// 解析本地文件浏览器的根目录：shell 的实时工作目录
/// （OSC 7 → 进程 cwd 查询 → 启动目录）。调用方拥有返回的切片。
/// 仅用于 POSIX——本地路径是原生路径，绝不能走 WSL guest 路径转换。
fn localExplorerLiveCwd(surface: *const Surface, allocator: std.mem.Allocator) ?[]u8 {
    return surface.dupeCurrentCwd(allocator);
}

fn syncFileExplorerToActiveTerminalSurface(force: bool) void {
    const surface = activeSurface() orelse {
        file_explorer.syncPanelForTabKind(false);
        return;
    };

    switch (surface.launch_kind) {
        .ssh => {
            if (surface.ssh_connection) |conn| {
                file_explorer.syncPanelForTerminalTarget(.{
                    .remote = .{
                        .conn = &conn,
                        .cwd = surface.getCwd() orelse "",
                    },
                }, force);
                return;
            }
            file_explorer.syncPanelForTabKind(false);
        },
        .wsl => {
            file_explorer.syncPanelForTerminalTarget(.{ .wsl = surface.getCwd() orelse "~" }, force);
        },
        .local => {
            if (comptime platform_pty_command.local_explorer_uses_live_cwd) {
                // POSIX（含 macOS）：本地路径是原生路径，跟随 shell 实时 cwd，
                // 不走 WSL 转换（后者在 macOS 上对普通 Unix 路径恒返回 null）。
                const alloc = g_allocator orelse std.heap.page_allocator;
                if (localExplorerLiveCwd(surface, alloc)) |cwd| {
                    defer alloc.free(cwd);
                    file_explorer.syncPanelForTerminalTarget(.{ .local = cwd }, force);
                } else {
                    file_explorer.syncPanelForTabKind(false);
                }
            } else {
                // Windows：本地 shell 的 cwd 可能是 WSL guest 路径，沿用既有转换。
                if (surface.getCwd()) |guest_path| {
                    var native_buf: platform_pty_command.CwdBuffer = undefined;
                    var utf8_buf: [260]u8 = undefined;
                    if (platform_wsl.guestPathToLocalPathUtf8(guest_path, &native_buf, &utf8_buf)) |local_path| {
                        file_explorer.syncPanelForTerminalTarget(.{ .local = local_path }, force);
                        return;
                    }
                }
                if (surface.getInitialCwd()) |initial_cwd| {
                    file_explorer.syncPanelForTerminalTarget(.{ .local = initial_cwd }, force);
                    return;
                }
                file_explorer.syncPanelForTabKind(false);
            }
        },
    }
}

pub fn closeTab(idx: usize) void {
    const allocator = g_allocator orelse return;
    if (tab.g_tab_count <= 1 or idx >= tab.g_tab_count) return;
    if (tab.g_tabs[idx]) |closing| {
        if (closing.tmux_window_id != null) tmux_controller.forgetClosedTab(closing);
    }
    tab.closeTab(idx, allocator);
    file_explorer.onTabClosed(idx);
    browser_panel.onTabClosed(idx);
    clearUiStateOnTabChange();
}

pub fn closeFocusedSplitWouldCloseWindow() bool {
    const active_tab = activeTab() orelse return false;
    if (active_tab.kind == .ai_chat) return tab.g_tab_count <= 1;
    return tab.g_tab_count <= 1 and !active_tab.tree.isSplit();
}

pub fn switchTab(idx: usize) void {
    tab.switchTab(idx);
    clearUiStateOnTabChange();
}

pub fn reorderTab(from_idx: usize, to_idx: usize) bool {
    if (!tab.reorderTab(from_idx, to_idx)) return false;
    file_explorer.onTabReordered(from_idx, to_idx);
    browser_panel.onTabReordered(from_idx, to_idx);
    clearUiStateOnTabChange();
    return true;
}

pub fn splitFocused(direction: SplitTree.Split.Direction) void {
    _ = splitFocusedReturningSurface(direction);
}

pub fn splitFocusedReturningSurface(direction: SplitTree.Split.Direction) ?*Surface {
    const allocator = g_allocator orelse return null;

    // In a tmux-backed tab, a split must be a real tmux pane: drive
    // `split-window` and let the echoed %layout-change reconcile the new pane.
    // Returning null here is correct — the new surface arrives asynchronously
    // via the controller, not from this call.
    if (tab.activeTab()) |t| {
        if (t.tmux_window_id != null) {
            if (t.focusedSurface()) |focused| {
                const horizontal = direction == .left or direction == .right;
                _ = tmux_controller.requestSplit(focused, horizontal);
            }
            return null; // a tmux tab's splits are owned by tmux; never spawn a local/ssh surface
        }
    }

    var cwd_buf: platform_pty_command.CwdBuffer = undefined;
    const cwd = getActiveCwd(&cwd_buf);
    const surface = tab.splitFocusedReturningSurface(allocator, direction, font.cell_width, font.cell_height, g_cursor_style, g_cursor_blink, cwd) orelse return null;
    if (surface.ssh_connection) |conn| {
        if (conn.usesPasswordAuth()) {
            const pw = conn.password();
            if (pw.len > 0)
                overlays.scheduleSshPasswordForSurface(surface);
        }
    }
    handleActiveSurfaceChangeWithinTab();
    {
        overlays.resize.g_resize_active = false;
        requestImmediateLayoutResize();
    }
    return surface;
}

pub fn closeFocusedSplit() void {
    const allocator = g_allocator orelse return;

    // tmux tab: kill-pane and let tmux drive removal — its %layout-change drops
    // the split, or %window-close drops the whole tab when the last pane goes.
    if (tab.activeTab()) |t| {
        if (t.tmux_window_id != null) {
            if (t.focusedSurface()) |focused| {
                if (tmux_controller.requestClosePane(focused)) return;
            }
        }
    }

    const closing_tab_idx = active_tab_state.g_active_tab;
    var closing_surface_id: ?[16]u8 = null;
    if (tab.activeSurface()) |surface| closing_surface_id = surface.remote_id;
    switch (tab.closeFocusedSplit(allocator)) {
        .closed_split => {
            if (closing_surface_id) |*source_id| html_server.stopForSurfaceId(source_id);
            input.g_selecting = false;
            handleActiveSurfaceChangeWithinTab();
            requestImmediateLayoutResize();
        },
        .closed_tab => {
            file_explorer.onTabClosed(closing_tab_idx);
            browser_panel.onTabClosed(closing_tab_idx);
            clearUiStateOnTabChange();
        },
        .close_window => {
            split_layout.invalidateCachedRects();
            cell_renderer.g_current_render_surface = null;
            g_should_close = true;
        },
        .no_op => {},
    }
}

/// Move focus to the split in the given direction. Returns whether focus
/// actually moved — false means there is no pane in that direction, so callers
/// can let the key fall through to the terminal instead of consuming it.
pub fn gotoSplit(direction: SplitTree.Goto) bool {
    const allocator = g_allocator orelse return false;
    if (tab.gotoSplit(allocator, direction)) {
        handleActiveSurfaceChangeWithinTab();
        return true;
    }
    return false;
}

/// Focus the n-th panel (1-based) of the active tab by screen reading order.
/// Returns whether focus moved (false = no such panel, so the caller can let the
/// key fall through to the terminal).
pub fn focusPanel(n: usize) bool {
    const allocator = g_allocator orelse return false;
    if (tab.focusPanelByIndex(allocator, n)) {
        handleActiveSurfaceChangeWithinTab();
        return true;
    }
    return false;
}

pub fn equalizeSplits() void {
    const allocator = g_allocator orelse return;
    if (tab.equalizeSplits(allocator)) {
        overlays.resize.g_split_resize_overlay_until = std.time.milliTimestamp() + overlays.RESIZE_OVERLAY_DURATION_MS;
        requestImmediateLayoutResize();
        g_force_rebuild = true;
        g_cells_valid = false;
    }
}

/// Swap the contents of two panels (drag source `a`, drop target `b`) within
/// the active tab. Returns whether a swap happened so the input layer can avoid
/// redundant work on a no-op. Topology is unchanged, so cached rects only need
/// to be re-pointed at their (swapped) surfaces — invalidate and rebuild.
pub fn swapPanels(a: SplitTree.Node.Handle, b: SplitTree.Node.Handle) bool {
    if (!tab.swapPanels(a, b)) return false;
    split_layout.invalidateCachedRects();
    handleActiveSurfaceChangeWithinTab();
    g_force_rebuild = true;
    g_cells_valid = false;
    return true;
}

// Embed the font
// Embedded fallback font (JetBrains Mono, like Ghostty)
const embedded = @import("font/embedded.zig");

// Terminal dimensions (initial, will be updated on resize)
// Defaults match Ghostty's default of 0 (auto-size), but we set
// reasonable defaults since we don't auto-detect screen size.
pub threadlocal var term_cols: u16 = 80;
pub threadlocal var term_rows: u16 = 24;
// Dirty tracking — skip rebuildCells when nothing changed
pub threadlocal var g_cells_valid: bool = false;
pub threadlocal var g_force_rebuild: bool = true;

pub threadlocal var window_focused: bool = true; // Track window focus state

// Window state persistence.
const loadWindowState = platform_window_state.loadWindowState;
const saveWindowGeometry = platform_window_state.saveWindowGeometry;
const loadQuakeFrame = platform_window_state.loadQuakeFrame;
const saveQuakeFrame = platform_window_state.saveQuakeFrame;

// Pending resize state (resize is deferred to main loop to avoid PageList integrity issues)
// Ghostty coalesces resize events with a 25ms timer to batch rapid resizes
const RESIZE_COALESCE_MS: i64 = 25; // Same as Ghostty

pub fn requestGridResize(cols: u16, rows: u16, now_ms: i64) void {
    windowState().queueResize(cols, rows, now_ms);
}

fn pendingResizeActive() bool {
    return windowState().pending_resize.pending;
}

fn clearPendingResize() void {
    windowState().clearPendingResize();
}

fn consumePendingGridResize(now_ms: i64) ?@import("appwindow/window_state.zig").GridSize {
    return windowState().consumeCoalescedResize(now_ms, RESIZE_COALESCE_MS, term_cols, term_rows);
}

pub fn requestImmediateLayoutResize() void {
    windowState().requestImmediateLayoutResize();
}

pub fn consumeImmediateLayoutResize() bool {
    return windowState().consumeImmediateLayoutResize();
}

pub threadlocal var g_cursor_style: CursorStyle = .block; // Default cursor style
pub threadlocal var g_cursor_blink: bool = true; // Whether cursor should blink (default: true like Ghostty)
pub threadlocal var g_cursor_blink_visible: bool = true; // Current blink state (toggled by timer)
pub threadlocal var g_last_blink_time: i64 = 0; // Timestamp of last blink toggle
const CURSOR_BLINK_INTERVAL_MS: i64 = 600; // Blink interval in ms (same as Ghostty)

const ConfigWatcher = @import("config_watcher.zig");

// Shared GPU pipeline init lives behind renderer/gpu plus ui/cell pipelines.

/// Focus follows mouse - when true, moving mouse into a split pane focuses it
pub threadlocal var g_focus_follows_mouse: bool = false;
pub threadlocal var g_copy_on_select: bool = false;
pub threadlocal var g_copilot_hint: bool = true;
threadlocal var g_copilot_shimmer_checked: bool = false;
pub threadlocal var g_right_click_action: Config.RightClickAction = .copy;
pub threadlocal var g_ssh_legacy_algorithms: bool = false;
pub threadlocal var g_desktop_notifications: bool = true;
pub threadlocal var g_confirm_close_running_program: bool = true;
pub threadlocal var g_weixin_notify_forward: bool = false;
threadlocal var g_notif_auth_requested: bool = false;

/// Update cursor blink state based on time (call once per frame)
fn updateCursorBlink() void {
    if (!g_cursor_blink) {
        g_cursor_blink_visible = true;
        return;
    }

    const now = std.time.milliTimestamp();
    if (now - g_last_blink_time >= CURSOR_BLINK_INTERVAL_MS) {
        g_cursor_blink_visible = !g_cursor_blink_visible;
        g_last_blink_time = now;
    }
}

/// Update cursor blink for a specific renderer (per-surface blink state)
fn updateCursorBlinkForRenderer(rend: *Renderer) void {
    if (!g_cursor_blink) {
        rend.cursor_blink_visible = true;
        return;
    }

    const now = std.time.milliTimestamp();
    if (now - rend.last_cursor_blink_time >= CURSOR_BLINK_INTERVAL_MS) {
        rend.cursor_blink_visible = !rend.cursor_blink_visible;
        rend.last_cursor_blink_time = now;
    }
}

/// Resize the window to fit the current terminal grid and cell dimensions.
/// Called from the platform backend during a modal live resize loop.
/// Performs a full render cycle: resize terminal → snapshot → rebuild → draw.
/// This runs synchronously on the main thread (which owns the GL context)
/// while the backend's modal drag loop is active.
/// Registered as the platform `on_resize` callback. The platform's modal resize
/// loop delivers resize events far faster than a full frame renders, so throttle
/// the heavy paint to ~60Hz here (that loop blocks our main loop, so an
/// un-throttled paint per event stutters the drag). One-shot resizes (DPI change,
/// font reload) call `renderResizeFrame` directly so they always paint immediately.
threadlocal var g_resize_throttle: resize_throttle.ResizeThrottle = .{};

fn onPlatformResize(width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    const now = std.time.milliTimestamp();
    if (!g_resize_throttle.shouldRender(now)) return;
    g_resize_throttle.noteRendered(now);
    renderResizeFrame(width, height);
}

fn renderResizeFrame(width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    if (g_allocator == null) return;
    const resize_perf = ui_perf.begin("appwindow.on_platform_resize");
    defer resize_perf.end();
    if (g_window) |w| {
        const client = window_backend.clientSize(w);
        const fb = window_backend.framebufferSize(w);
        render_diagnostics.log(
            "platform-resize begin arg={}x{} client={}x{} fb={}x{} dpi={} font_dpi={} cell={d:.2}x{d:.2} term={}x{} pending={} max={} full={}",
            .{
                width,
                height,
                client.width,
                client.height,
                fb.width,
                fb.height,
                window_backend.effectiveDpi(w),
                font.g_dpi,
                font.cell_width,
                font.cell_height,
                term_cols,
                term_rows,
                pendingResizeActive(),
                window_backend.isMaximized(w),
                window_backend.isFullscreen(w),
            },
        );
    } else {
        render_diagnostics.log(
            "platform-resize begin arg={}x{} no-window font_dpi={} cell={d:.2}x{d:.2} term={}x{} pending={}",
            .{ width, height, font.g_dpi, font.cell_width, font.cell_height, term_cols, term_rows, pendingResizeActive() },
        );
    }

    // Match exactly what computeSplitLayout → setScreenSize computes for a
    // root (full-window) surface, so term_cols/term_rows stay in sync and
    // new tabs don't see a spurious resize on first render.
    //
    // Width: render-loop subtracts 2*render_padding, then edge extensions add
    //        it back for the root surface, so only explicit L+R matter.
    // Height: render-loop subtracts (render_padding+TB) top and render_padding
    //         bottom, then setScreenSize subtracts explicit T+B on top of that.
    const padding_left: f32 = @floatFromInt(DEFAULT_PADDING);
    const padding_right: f32 = @as(f32, @floatFromInt(DEFAULT_PADDING)) + overlays.SCROLLBAR_WIDTH;
    const padding_top: f32 = @floatFromInt(DEFAULT_PADDING);
    const padding_bottom: f32 = @floatFromInt(DEFAULT_PADDING);
    const render_padding: f32 = 10;
    const tb = currentTitlebarHeight();
    const left_panels_w = leftPanelsWidth();
    const right_panels_w = rightPanelsWidthForWindow(width);
    const avail_w = @as(f32, @floatFromInt(width)) - left_panels_w - right_panels_w - padding_left - padding_right;
    const avail_h = @as(f32, @floatFromInt(height)) - (render_padding * 2 + tb) - padding_top - padding_bottom;
    if (avail_w <= 0 or avail_h <= 0) return;

    const new_cols: u16 = @intFromFloat(@max(1, avail_w / font.cell_width));
    const new_rows: u16 = @intFromFloat(@max(1, avail_h / font.cell_height));
    render_diagnostics.log(
        "platform-resize grid avail={d:.1}x{d:.1} panels_l={d:.1} panels_r={d:.1} titlebar={d:.1} new={}x{} old={}x{}",
        .{ avail_w, avail_h, left_panels_w, right_panels_w, tb, new_cols, new_rows, term_cols, term_rows },
    );

    // Update root grid dimensions (used for spawning new tabs).
    // Actual terminal + PTY resize is handled by computeSplitLayout → setScreenSize
    // below, which is the single resize path for all surfaces.
    if (new_cols != term_cols or new_rows != term_rows) {
        term_cols = new_cols;
        term_rows = new_rows;
        // Clear any pending coalesced resize — we're handling it now
        clearPendingResize();
        render_diagnostics.log("platform-resize root-grid-updated {}x{}", .{ term_cols, term_rows });
    }

    // Sync atlas textures
    if (font.g_atlas != null) font.syncAtlasTexture(&font.g_atlas, &font.g_atlas_texture, &font.g_atlas_modified);
    if (font.g_color_atlas != null) font.syncAtlasTexture(&font.g_color_atlas, &font.g_color_atlas_texture, &font.g_color_atlas_modified);
    if (font.g_icon_atlas != null) font.syncAtlasTexture(&font.g_icon_atlas, &font.g_icon_atlas_texture, &font.g_icon_atlas_modified);
    if (font.g_titlebar_atlas != null) font.syncAtlasTexture(&font.g_titlebar_atlas, &font.g_titlebar_atlas_texture, &font.g_titlebar_atlas_modified);

    const fb_width: c_int = width;
    const fb_height: c_int = height;
    const titlebar_offset: f32 = tb;
    if (g_window) |w| {
        const perf = ui_perf.begin("appwindow.browser_panel_sync_resize");
        defer perf.end();
        browser_panel.sync(window_backend.nativeHandle(w), width, height, titlebar_offset, left_panels_w, browserPanelRightOffset(), overlays.anyBlockingOverlayVisible());
    }

    // Snapshot + rebuild + draw (split-aware, mirrors main loop)
    if (activeTab()) |active_tab| {
        // Compute split layout — also calls setScreenSize on each surface,
        // which corrects the per-surface dimensions for splits.
        const content_x: i32 = @intFromFloat(left_panels_w + render_padding);
        const content_y: i32 = @intFromFloat(render_padding + tb);
        const content_w: i32 = @intFromFloat(@as(f32, @floatFromInt(width)) - left_panels_w - right_panels_w - render_padding * 2);
        const content_h: i32 = @intFromFloat(@as(f32, @floatFromInt(height)) - (render_padding + tb) - render_padding);
        const split_count = blk: {
            const perf = ui_perf.begin("appwindow.resize_compute_split_layout");
            defer perf.end();
            break :blk computeSplitLayout(active_tab, content_x, content_y, content_w, content_h, font.cell_width, font.cell_height);
        };
        if (g_allocator) |alloc| remote_sync.syncLayout(remoteSyncHost(), alloc);

        // A lone PREVIEW pane has no terminal surface and must take the generic
        // split path below so it still paints (preview-only tabs are legal).
        if (split_count == 0 or split_layout.soleTerminalSurface() != null) {
            if (active_tab.kind == .ai_chat) {
                renderAiChatFrame(fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (active_tab.kind == .ai_history) {
                renderAiHistoryFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (active_tab.kind == .memory_center) {
                renderMemoryCenterFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (active_tab.kind == .skill_center) {
                renderSkillCenterFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (active_tab.kind == .port_forwarding) {
                renderPortForwardingFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (split_layout.soleTerminalSurface()) |surface| {
                // Single surface: simple render path
                const rend = &surface.surface_renderer;
                var needs_rebuild: bool = false;
                {
                    surface.render_state.mutex.lock();
                    defer surface.render_state.mutex.unlock();
                    cell_renderer.g_current_render_surface = surface;
                    rend.force_rebuild = true;
                    needs_rebuild = cell_renderer.updateTerminalCells(rend, &surface.terminal);
                }
                if (needs_rebuild) cell_renderer.rebuildCells(rend);

                gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
                ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                clearWithBackground(fb_width, fb_height);

                const pad = surface.getPadding();
                const pad_top = @as(f32, @floatFromInt(pad.top)) + titlebar_offset;
                titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                cell_renderer.drawCells(rend, @floatFromInt(fb_height), left_panels_w + @as(f32, @floatFromInt(pad.left)), pad_top);
                overlays.renderScrollbar(@floatFromInt(fb_width), @floatFromInt(fb_height), pad_top);
                overlays.renderResizeOverlayWithOffset(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            }
        } else {
            // Multiple splits: render each surface in its own viewport
            gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
            ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
            clearWithBackground(fb_width, fb_height);

            titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);

            for (0..split_count) |i| {
                const rect = split_layout.g_split_rects[i];
                const is_focused = (rect.handle == active_tab.focused);

                switch (rect.pane) {
                    .terminal => |surface| {
                        const rend = &surface.surface_renderer;

                        const viewport_y = fb_height - rect.y - rect.height;
                        gpu.state.setViewport(rect.x, viewport_y, rect.width, rect.height);
                        ui_pipeline.setProjection(@floatFromInt(rect.width), @floatFromInt(rect.height));

                        {
                            surface.render_state.mutex.lock();
                            defer surface.render_state.mutex.unlock();
                            rend.force_rebuild = true;
                            cell_renderer.g_current_render_surface = surface;
                            _ = cell_renderer.updateTerminalCellsForSurface(rend, &surface.terminal, is_focused);
                        }
                        cell_renderer.rebuildCells(rend);

                        const pad = surface.getPadding();
                        cell_renderer.drawCells(rend, @floatFromInt(rect.height), @floatFromInt(pad.left), @floatFromInt(pad.top));
                        overlays.renderScrollbarForSurface(surface, @floatFromInt(rect.width), @floatFromInt(rect.height), @floatFromInt(pad.top));

                        if (!is_focused) {
                            overlays.renderUnfocusedOverlaySimple(@floatFromInt(rect.width), @floatFromInt(rect.height));
                        }

                        // Show resize overlay on all splits during window resize
                        if (is_focused) {
                            overlays.renderResizeOverlay(@floatFromInt(rect.width), @floatFromInt(rect.height));
                        }
                    },
                    .preview => |p| {
                        // The preview renderer paints in window-absolute coords, so
                        // restore the full-window viewport/projection first (the
                        // terminal arm leaves a per-rect viewport set).
                        gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
                        ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                        const close_hovered = if (input.g_preview_close_hover) |h| h == rect.handle else false;
                        markdown_preview_renderer.renderInto(
                            p,
                            @floatFromInt(rect.x),
                            @floatFromInt(rect.y),
                            @floatFromInt(rect.width),
                            @floatFromInt(rect.height),
                            @floatFromInt(fb_height),
                            close_hovered,
                        );
                        if (is_focused) drawPaneFocusRing(rect, @floatFromInt(fb_height));
                    },
                }
            }

            // Restore full viewport for dividers
            gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
            ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
            overlays.renderSplitDividers(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
            overlays.renderPaneAgentDots(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
        }
    } else {
        gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
        ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
        clearWithBackground(fb_width, fb_height);
        titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    }

    // Copilot panel draws on top of the reserved right region (terminal tabs only;
    // renderAiCopilotPanel gates on aiCopilotVisible). Placed after the terminal
    // content + markdown preview so it occupies the exclusive right slot.
    renderAiCopilotPanel(fb_width, fb_height, titlebar_offset);

    overlays.renderBrowserUrlBar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderCommandPalette(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderJupyterPicker(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderCopilotPicker(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderSettingsPage(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderSessionLauncher(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderMcpServers(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    weixin_qr_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    feishu_reg_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderDebugOverlay(@floatFromInt(fb_width));
    overlays.renderCloseShortcutConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderCopyToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderTransferToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderTransferCancelConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderUpdatePrompt(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderWindowCloseConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderRestoreDefaultsConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderIntegrationPrompt(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderWhatsNew(@floatFromInt(fb_width), @floatFromInt(fb_height));

    d3d11_offscreen_smoke.render(fb_width, fb_height);
    d3d11_ui_smoke.render(fb_width, fb_height);
    render_diagnostics.log(
        "platform-resize swap fb={}x{} term={}x{} draw_calls={}",
        .{ fb_width, fb_height, term_cols, term_rows, gpu.draw_call_count },
    );
    forceOpaqueBackbufferForPresent();
    if (g_window) |w| presentBackendFrame(w);
}

fn resizeWindowToGrid() void {
    const padding: f32 = 10;
    const tb = currentTitlebarHeight();
    const content_w: f32 = font.cell_width * @as(f32, @floatFromInt(term_cols));
    const content_h: f32 = font.cell_height * @as(f32, @floatFromInt(term_rows));
    const win_w: i32 = @intFromFloat(content_w + leftPanelsWidth() + rightPanelsWidth() + padding * 2);
    const win_h: i32 = @intFromFloat(content_h + padding + (padding + tb));
    if (g_window) |w| window_backend.resizeClientArea(w, win_w, win_h);
}

fn pollUpdateCheck(app: *App) void {
    const result = app.consumeUpdateResult();
    if (result.state != .idle) overlays.showUpdateCheckResult(result);
}

/// UI thread: consume a finished skill-center op result and apply it (open the
/// import list, run the deploy decision, or show a transfer toast).
fn pollSkillCenterOp(session: *skill_center.Session) void {
    const allocator = g_allocator orelse return;
    var result = session.takePendingOp() orelse return;
    defer result.deinit(allocator);

    // The "Syncing…" indicator lives in session.status (set by startOp, cleared
    // by the op worker on finish), so the UI thread here only applies results.
    switch (result) {
        .failed => {
            overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        },
        .import_scan => |*v| {
            session.mutex.lock();
            const st = skillCenterMakeImportState(allocator, &session.model, v.rows, v.target) catch {
                session.mutex.unlock();
                markUiDirty();
                return;
            };
            session.model.setOverlay(.{ .import_list = st });
            session.mutex.unlock();
        },
        .deploy_scan => |*v| {
            var present = false;
            var target_hash: ?[]const u8 = null;
            for (v.rows) |r| {
                if (std.mem.eql(u8, r.name, v.name)) {
                    present = true;
                    target_hash = r.agg_hash;
                }
            }
            switch (skill_center.overwriteDecision(present, target_hash, v.src_hash)) {
                .noop => overlays.showStatusToast(i18n.s().sc_toast_in_sync),
                .direct => skill_center_actions.runTransfer(allocator, false, v.target, v.name),
                .confirm => skillCenterArmConfirm(allocator, false, v.target, v.name),
            }
        },
        .transfer => |*v| {
            if (v.ok) {
                overlays.showStatusToast(if (v.is_import) i18n.s().sc_toast_imported else i18n.s().sc_toast_synced);
                startSkillCenterScan(allocator, session);
            } else if (v.err_summary) |s| {
                var buf: [200]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s}{s}", .{ i18n.s().sc_toast_sync_failed_prefix, s }) catch i18n.s().sc_toast_sync_failed;
                overlays.showStatusToast(msg);
            } else {
                overlays.showStatusToast(i18n.s().sc_toast_sync_failed);
            }
        },
        .preview => |*v| {
            session.mutex.lock();
            session.model.openTextPreview(v.title, v.content) catch {};
            session.mutex.unlock();
        },
        .tool_import_preview => {
            const moved = result;
            result = .failed;
            session.mutex.lock();
            session.model.setOverlay(.{ .tool_import_preview = moved.tool_import_preview });
            skillCenterSetStatusLocked(session, "");
            session.mutex.unlock();
        },
        .tool_import_failed => |summary| {
            session.mutex.lock();
            skillCenterSetStatusLocked(session, summary);
            session.mutex.unlock();
        },
        .install_enumerate => {
            const moved = result; // shallow copy of the union (owns repo+entries)
            result = .failed; // outer defer now no-ops; `moved` is sole owner
            const v = moved.install_enumerate;
            if (v.entries.len == 0) {
                var mv = moved;
                mv.deinit(allocator); // free repo+entries
                overlays.showStatusToast(i18n.s().sc_toast_no_skills);
            } else {
                if (v.truncated) overlays.showStatusToast(i18n.s().sc_toast_truncated);
                const checked = allocator.alloc(bool, v.entries.len) catch {
                    var mv = moved;
                    mv.deinit(allocator);
                    markUiDirty();
                    return;
                };
                for (checked) |*c| c.* = true; // default: all selected
                session.mutex.lock();
                session.model.setOverlay(.{ .install_pick = .{ .repo = v.repo, .entries = v.entries, .checked = checked } });
                session.mutex.unlock();
                // ownership of v.repo + v.entries now belongs to the overlay; do NOT deinit `moved`.
            }
        },
        .install_done => |*v| {
            if (v.failed == 0) {
                overlays.showStatusToast(i18n.s().sc_toast_installed);
            } else {
                overlays.showStatusToast(i18n.s().sc_toast_install_partial);
            }
            log.info("skill install: {d} installed, {d} updated, {d} failed", .{ v.installed, v.overwritten, v.failed });
            startSkillCenterScan(allocator, session); // refresh the library list
        },
    }
    markUiDirty();
}

/// Reload config from disk and apply theme/font/cursor/etc. (used after UI writes config).
pub fn reloadConfigImmediate(allocator: std.mem.Allocator) void {
    const cfg = Config.load(allocator) catch |err| {
        std.debug.print("reloadConfigImmediate: failed to load config: {}\n", .{err});
        return;
    };
    defer cfg.deinit(allocator);
    applyReloadedConfig(allocator, &cfg);
}

fn syncTransferToastFromFileExplorer() void {
    const notification = file_explorer.latestTransferNotification() orelse return;
    if (!remoteState().acceptTransferNotification(notification.seq)) return;
    overlays.showTransferToast(notification.kind, notification.status, notification.message);
    markUiDirty();
}

fn syncMemoryDigestStatus() void {
    const progress = memory_digest_scheduler.progressSnapshot();
    if (activeMemoryCenter()) |session| {
        if (session.syncDigestProgress(progress)) markUiDirty();
    }
}

/// Apply freshly loaded configuration to this window/font/theme state.
fn applyReloadedConfig(allocator: std.mem.Allocator, cfg: *const Config) void {
    // Update App's cached config so new windows get the new settings
    if (g_app) |app| {
        app.updateConfig(cfg);
    }
    syncDefaultShellCommandFromConfig(cfg.shell);
    ai_chat.configureAgent(.{
        .enabled = cfg.@"ai-agent-enabled",
        .permission = cfg.@"ai-agent-permission",
        .command_timeout_ms = cfg.@"ai-agent-command-timeout-ms",
        .output_limit = cfg.@"ai-agent-output-limit",
        .memory_enabled = cfg.@"ai-memory-enabled",
        .distill_suggest_enabled = cfg.@"ai-distill-suggest",
    });
    ai_chat.reloadFirstPartyToolState(allocator);
    ai_chat.setDefaultWorkingDir(cfg.@"ai-agent-working-dir");
    overlays.setSubagentProfileName(cfg.@"ai-subagent-profile");
    @import("research/web_search.zig").setJinaApiKey(cfg.@"jina-api-key");
    @import("pty.zig").setConsoleHostPreference(cfg.@"windows-conpty");
    memory_digest_scheduler.updateSettings(.{
        .enabled = cfg.@"memory-digest-enabled",
        .profile_name = cfg.@"memory-digest-profile",
        .run_after = cfg.@"memory-digest-run-after",
        .scan_remote = cfg.@"memory-digest-scan-remote",
        .backfill_days = cfg.@"memory-digest-backfill-days",
        .max_chars = cfg.@"memory-digest-max-chars",
        .input_budget_chars = cfg.@"memory-digest-input-budget-chars",
    });

    if (g_window == null) return;
    g_quake_mode = cfg.@"quake-mode";
    g_keybinds = cfg.keybinds;
    if (g_window) |win| syncQuakeHotkeyRegistration(win);
    const ft_lib = font.g_ft_lib orelse return;

    // --- Theme, cursor, debug ---
    g_theme = cfg.resolved_theme;
    g_force_rebuild = true;
    g_cursor_style = cfg.@"cursor-style";
    g_cursor_blink = cfg.@"cursor-style-blink";
    overlays.g_debug_fps = cfg.@"wispterm-debug-fps";
    overlays.g_debug_draw_calls = cfg.@"wispterm-debug-draw-calls";
    g_debug_memory = cfg.@"wispterm-debug-memory";

    // --- Split config ---
    overlays.g_unfocused_split_opacity = cfg.@"unfocused-split-opacity";
    g_focus_follows_mouse = cfg.@"focus-follows-mouse";
    g_copy_on_select = cfg.@"copy-on-select";
    g_copilot_hint = cfg.@"copilot-hint";
    g_right_click_action = cfg.@"right-click-action";
    input.g_url_open_mode = cfg.@"url-open-mode";
    g_ssh_legacy_algorithms = cfg.@"ssh-legacy-algorithms";
    g_desktop_notifications = cfg.@"desktop-notifications";
    g_confirm_close_running_program = cfg.@"confirm-close-running-program";
    g_weixin_notify_forward = cfg.@"weixin-notify-forward";
    tab.g_ssh_legacy_algorithms = cfg.@"ssh-legacy-algorithms";
    overlays.g_split_divider_color = cfg.@"split-divider-color";

    // --- Background image ---
    {
        const mode_changed = background_image.g_mode != cfg.@"background-image-mode";
        background_image.g_mode = cfg.@"background-image-mode";
        gpu.background_opacity = cfg.@"background-opacity";
        if (!background_image.isLoaded(cfg.@"background-image")) {
            background_image.load(allocator, cfg.@"background-image");
        } else if (mode_changed) {
            background_image.refreshWrapMode();
        }
    }

    // Sync cursor style to all tabs' terminals (rendering reads from terminal state)
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |tb| {
            // Update all surfaces in this tab's split tree
            var it = tb.tree.surfaces();
            while (it.next()) |entry| {
                entry.surface.render_state.mutex.lock();
                entry.surface.terminal.screens.active.cursor.cursor_style = switch (g_cursor_style) {
                    .bar => .bar,
                    .block => .block,
                    .underline => .underline,
                    .block_hollow => .block_hollow,
                };
                entry.surface.render_state.mutex.unlock();
            }
        }
    }

    // --- Font ---
    const new_font_size = cfg.@"font-size";
    const new_weight = font_backend.fontWeightFromValue(cfg.@"font-style".value());
    const new_family = cfg.@"font-family";
    // Copy into the font module's own buffers: `cfg` is deinit'd right after
    // this returns, and these globals are read lazily on the next fallback
    // lookup. Aliasing the config-owned slices here was a use-after-free.
    font.setCjkFontFamily(cfg.@"font-family-cjk");
    font.setFallbackFontFamilies(cfg.@"font-family-fallback");

    const font_changed = new_font_size != font.g_font_size;

    // Only reload font faces when font parameters actually changed.
    // Theme-only changes must not trigger a font reload + window resize.
    if (font_changed) {
        if (reloadFontFaces(allocator, new_family, new_weight, new_font_size, ft_lib)) {
            if (g_window) |w| {
                const is_os_sized = window_backend.isFullscreen(w) or window_backend.isMaximized(w);
                if (is_os_sized) {
                    const size = window_backend.clientSize(w);
                    renderResizeFrame(size.width, size.height);
                } else {
                    if (cfg.@"window-width" > 0) term_cols = cfg.@"window-width";
                    if (cfg.@"window-height" > 0) term_rows = cfg.@"window-height";
                    resizeWindowToGrid();
                }
            }
        } else {
            std.debug.print("Reload: failed to load font, keeping current font\n", .{});
        }
    }

    std.debug.print("Config reloaded successfully\n", .{});
}

const MemoryDebugTotals = struct {
    tabs: usize = 0,
    ai_tabs: usize = 0,
    visible_surfaces: usize = 0,
    surfaces: usize = 0,
    terminal_page_bytes: usize = 0,
    terminal_page_committed_bytes: usize = 0,
    terminal_page_limit_bytes: usize = 0,
    terminal_min_page_bytes: usize = 0,
    renderer_cpu_capacity_bytes: usize = 0,
    kitty_pending_cpu_bytes: usize = 0,
    kitty_texture_pixel_bytes: usize = 0,
    fbo_pixel_bytes: usize = 0,
};

const SurfaceMemoryDebug = struct {
    cols: usize = 0,
    rows: usize = 0,
    screen_count: usize = 0,
    terminal_page_bytes: usize = 0,
    terminal_page_committed_bytes: usize = 0,
    terminal_page_limit_bytes: usize = 0,
    terminal_min_page_bytes: usize = 0,
    renderer_cpu_capacity_bytes: usize = 0,
    bg_cell_count: usize = 0,
    fg_cell_count: usize = 0,
    color_fg_cell_count: usize = 0,
    kitty_textures: usize = 0,
    kitty_pending_uploads: usize = 0,
    kitty_pending_cpu_bytes: usize = 0,
    kitty_texture_pixel_bytes: usize = 0,
    fbo_width: u32 = 0,
    fbo_height: u32 = 0,
    fbo_pixel_bytes: usize = 0,
};

fn collectSurfaceMemoryDebug(surface: *Surface) SurfaceMemoryDebug {
    var stats: SurfaceMemoryDebug = .{};

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    stats.cols = surface.terminal.cols;
    stats.rows = surface.terminal.rows;

    var screen_it = surface.terminal.screens.all.iterator();
    while (screen_it.next()) |entry| {
        const screen = entry.value.*;
        stats.screen_count += 1;
        stats.terminal_page_bytes += screen.pages.page_size;
        // page_size excludes the pool's preheated-but-unused pages (committed
        // via VirtualAlloc at init), while the pool arena's capacity includes
        // the in-use pooled pages — so take the max instead of summing.
        // ponytail: undercounts a screen holding both pool surplus and
        // oversized non-pool pages; fine for a debug metric.
        stats.terminal_page_committed_bytes += @max(
            screen.pages.page_size,
            screen.pages.pool.pages.arena.queryCapacity(),
        );
        stats.terminal_page_limit_bytes += screen.pages.explicit_max_size;
        stats.terminal_min_page_bytes += screen.pages.min_max_size;
    }

    const rend = &surface.surface_renderer;
    stats.renderer_cpu_capacity_bytes = rend.cpuBufferCapacityBytes();
    stats.bg_cell_count = rend.bg_cell_count;
    stats.fg_cell_count = rend.fg_cell_count;
    stats.color_fg_cell_count = rend.color_fg_cell_count;
    stats.kitty_textures = rend.kitty_textures.items.len;
    stats.kitty_pending_uploads = rend.kitty_pending_uploads.items.len;
    stats.kitty_pending_cpu_bytes = rend.kittyPendingCpuBytes();
    stats.kitty_texture_pixel_bytes = rend.kittyTexturePixelBytes();
    stats.fbo_width = rend.fbo_width;
    stats.fbo_height = rend.fbo_height;
    stats.fbo_pixel_bytes = rend.fboPixelBytes();

    return stats;
}

fn maybePrintMemoryDebug(now: i64) void {
    if (!g_debug_memory) return;
    if (now - g_debug_memory_last_ms < 5000) return;
    g_debug_memory_last_ms = now;

    var totals: MemoryDebugTotals = .{};

    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        totals.tabs += 1;

        if (tab_state.kind == .ai_chat) {
            totals.ai_tabs += 1;
            continue;
        }

        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            const visible = tab_index == active_tab_state.g_active_tab;
            const stats = collectSurfaceMemoryDebug(entry.surface);

            totals.surfaces += 1;
            if (visible) totals.visible_surfaces += 1;
            totals.terminal_page_bytes += stats.terminal_page_bytes;
            totals.terminal_page_committed_bytes += stats.terminal_page_committed_bytes;
            totals.terminal_page_limit_bytes += stats.terminal_page_limit_bytes;
            totals.terminal_min_page_bytes += stats.terminal_min_page_bytes;
            totals.renderer_cpu_capacity_bytes += stats.renderer_cpu_capacity_bytes;
            totals.kitty_pending_cpu_bytes += stats.kitty_pending_cpu_bytes;
            totals.kitty_texture_pixel_bytes += stats.kitty_texture_pixel_bytes;
            totals.fbo_pixel_bytes += stats.fbo_pixel_bytes;

            if (totals.surfaces <= 8) {
                std.debug.print(
                    "[memory] surface#{d}{s} grid={}x{} screens={} pages={d:.1}/{d:.1}MiB min={d:.1}MiB renderer_cap={d:.1}MiB cells(bg/fg/color)={}/{}/{} kitty(tex/pending)={}/{} kitty_bytes(cpu/gpu)={d:.1}/{d:.1}MiB fbo={}x{} {d:.1}MiB\n",
                    .{
                        totals.surfaces,
                        if (visible) " visible" else "",
                        stats.cols,
                        stats.rows,
                        stats.screen_count,
                        memory_debug.mib(stats.terminal_page_bytes),
                        memory_debug.mib(stats.terminal_page_limit_bytes),
                        memory_debug.mib(stats.terminal_min_page_bytes),
                        memory_debug.mib(stats.renderer_cpu_capacity_bytes),
                        stats.bg_cell_count,
                        stats.fg_cell_count,
                        stats.color_fg_cell_count,
                        stats.kitty_textures,
                        stats.kitty_pending_uploads,
                        memory_debug.mib(stats.kitty_pending_cpu_bytes),
                        memory_debug.mib(stats.kitty_texture_pixel_bytes),
                        stats.fbo_width,
                        stats.fbo_height,
                        memory_debug.mib(stats.fbo_pixel_bytes),
                    },
                );
            }
        }
    }

    const font_stats = font.memoryStats();
    const font_cpu_bytes =
        font_stats.atlas_cpu_bytes +
        font_stats.color_atlas_cpu_bytes +
        font_stats.icon_atlas_cpu_bytes +
        font_stats.titlebar_atlas_cpu_bytes;
    const font_gpu_bytes =
        font_stats.atlas_gpu_bytes +
        font_stats.color_atlas_gpu_bytes +
        font_stats.icon_atlas_gpu_bytes +
        font_stats.titlebar_atlas_gpu_bytes;
    const tracked_cpu_bytes =
        totals.terminal_page_committed_bytes +
        totals.renderer_cpu_capacity_bytes +
        font_cpu_bytes +
        totals.kitty_pending_cpu_bytes;

    std.debug.print(
        "[memory] font glyphs={} graphemes={} titlebar={} icons={} fallback_faces={} no_fallback={} hb_fallback={} atlas(text/color/icon/titlebar)={}x{}/{}x{}/{}x{}/{}x{} font_atlas(cpu/gpu)={d:.1}/{d:.1}MiB\n",
        .{
            font_stats.glyphs,
            font_stats.graphemes,
            font_stats.titlebar_glyphs,
            font_stats.icons,
            font_stats.fallback_faces,
            font_stats.no_fallback_entries,
            font_stats.hb_fallback_fonts,
            font_stats.atlas_size,
            font_stats.atlas_size,
            font_stats.color_atlas_size,
            font_stats.color_atlas_size,
            font_stats.icon_atlas_size,
            font_stats.icon_atlas_size,
            font_stats.titlebar_atlas_size,
            font_stats.titlebar_atlas_size,
            memory_debug.mib(font_cpu_bytes),
            memory_debug.mib(font_gpu_bytes),
        },
    );

    if (memory_debug.queryProcess()) |process| {
        const untracked_private = process.private_usage -| tracked_cpu_bytes;
        std.debug.print(
            "[memory] process private={d:.1}MiB ws={d:.1}MiB commit={d:.1}MiB peak_ws={d:.1}MiB tabs={} ai_tabs={} surfaces={} visible_surfaces={} terminal_pages={d:.1}/{d:.1}MiB committed={d:.1}MiB min={d:.1}MiB renderer_cap={d:.1}MiB font_atlas(cpu/gpu)={d:.1}/{d:.1}MiB kitty_bytes(cpu/gpu)={d:.1}/{d:.1}MiB fbo={d:.1}MiB tracked_cpu={d:.1}MiB untracked_private~={d:.1}MiB faults={}\n",
            .{
                memory_debug.mib(process.private_usage),
                memory_debug.mib(process.working_set),
                memory_debug.mib(process.pagefile_usage),
                memory_debug.mib(process.peak_working_set),
                totals.tabs,
                totals.ai_tabs,
                totals.surfaces,
                totals.visible_surfaces,
                memory_debug.mib(totals.terminal_page_bytes),
                memory_debug.mib(totals.terminal_page_limit_bytes),
                memory_debug.mib(totals.terminal_page_committed_bytes),
                memory_debug.mib(totals.terminal_min_page_bytes),
                memory_debug.mib(totals.renderer_cpu_capacity_bytes),
                memory_debug.mib(font_cpu_bytes),
                memory_debug.mib(font_gpu_bytes),
                memory_debug.mib(totals.kitty_pending_cpu_bytes),
                memory_debug.mib(totals.kitty_texture_pixel_bytes),
                memory_debug.mib(totals.fbo_pixel_bytes),
                memory_debug.mib(tracked_cpu_bytes),
                memory_debug.mib(untracked_private),
                process.page_fault_count,
            },
        );
    } else {
        std.debug.print(
            "[memory] process query failed tabs={} ai_tabs={} surfaces={} terminal_pages={d:.1}MiB renderer_cap={d:.1}MiB\n",
            .{
                totals.tabs,
                totals.ai_tabs,
                totals.surfaces,
                memory_debug.mib(totals.terminal_page_bytes),
                memory_debug.mib(totals.renderer_cpu_capacity_bytes),
            },
        );
    }
}

fn markRemoteSyncUiDirty() void {
    g_force_rebuild = true;
}

fn openDefaultAiAgentForRemoteSync() remote_sync.AiAgentOpenStatus {
    return switch (overlays.openDefaultAgentSessionForRemote()) {
        .opened => .opened,
        .no_profile => .no_profile,
        .failed => .failed,
    };
}

fn remoteSyncHost() remote_sync.Host {
    const client = if (g_app) |app| app.remote_client else null;
    return .{
        .client = client,
        .window = g_window,
        .state = &g_appwindow_state,
        .allocator = g_allocator,
        .markUiDirty = markRemoteSyncUiDirty,
        .openDefaultAiAgentForRemote = openDefaultAiAgentForRemoteSync,
    };
}

// Allowed P3.1 shim: this callback owns App-window lookup under App.mutex and
// keeps remote_sync.zig decoupled from App.zig while forwarding to the UI thread.
fn openRemoteAiAgentForClient(ctx: *anyopaque, request_id: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const client = app.remote_client orelse return;

    const owned_request_id = std.heap.page_allocator.dupe(u8, request_id) catch {
        client.sendAiAgentOpenResult(request_id, .failed);
        return;
    };
    defer std.heap.page_allocator.free(owned_request_id);

    var native_handle: ?window_backend.NativeHandle = null;
    {
        app.mutex.lock();
        defer app.mutex.unlock();
        for (app.windows.items) |window| {
            if (window.getNativeHandle()) |candidate| {
                native_handle = candidate;
                break;
            }
        }
    }

    const target = native_handle orelse {
        if (app.remote_client) |current_client| {
            current_client.sendAiAgentOpenResult(owned_request_id, .failed);
        }
        return;
    };

    var request = remote_sync.RemoteAiAgentOpenRequest{ .request_id = owned_request_id };
    const result = thread_message.sendPointer(target, .remote_open_ai_agent, @intFromPtr(&request));
    if (result == 0) {
        if (app.remote_client) |current_client| {
            current_client.sendAiAgentOpenResult(owned_request_id, .failed);
        }
    }
}

fn markWeixinUiDirty() void {
    g_force_rebuild = true;
}

fn openDefaultAgentSessionForWeixin() weixin_control.OpenResult {
    return switch (overlays.openDefaultAgentSessionForRemote()) {
        .opened => .opened,
        .no_profile => .no_profile,
        .failed => .failed,
    };
}

fn openAgentSessionProfileForWeixin(profile_name: []const u8) weixin_control.OpenResult {
    return switch (overlays.openAgentSessionForRemoteProfile(profile_name)) {
        .opened => .opened,
        .no_profile => .no_profile,
        .unknown_profile => .unknown_profile,
        .failed => .failed,
    };
}

fn weixinModelProfiles(allocator: std.mem.Allocator) anyerror![]u8 {
    return overlays.aiModelProfileList(allocator);
}

fn switchSessionModelProfileForWeixin(session: *ai_chat.Session, profile_name: []const u8) weixin_control.SwitchModelResult {
    return switch (overlays.switchSessionModelByProfileName(session, profile_name)) {
        .switched => .switched,
        .no_profile => .no_profile,
        .unknown_profile => .unknown_profile,
        .failed => .failed,
    };
}

fn weixinBridgeHost() weixin_bridge.Host {
    return .{
        .markUiDirty = markWeixinUiDirty,
        .openDefaultAgentSession = openDefaultAgentSessionForWeixin,
        .openAgentSessionProfile = openAgentSessionProfileForWeixin,
        .modelProfiles = weixinModelProfiles,
        .switchSessionModelProfile = switchSessionModelProfileForWeixin,
    };
}

/// The Control the chatops channel drives. Backed by process-global state.
pub fn chatopsControl() weixin_control.Control {
    return weixin_bridge.control();
}

pub fn clearWeixinTranscriptCache() void {
    weixin_bridge.clearTranscriptCache();
}

pub fn enableAgentControl() void {
    control_api.setUiStateBuilder(overlays.buildUiStateJson);
    control_api.setSpawnHandler(ctlSpawnTab);
    control_api.enable();
}

/// UI-thread handler for `wisptermctl spawn`: open a new terminal tab. `cwd`
/// empty = inherit the active tab's cwd; `command` empty = the configured shell.
fn ctlSpawnTab(cwd_path: []const u8, command: []const u8) void {
    const allocator = g_allocator orelse return;
    var cwd_buf: platform_pty_command.CwdBuffer = undefined;
    const cwd = if (cwd_path.len != 0)
        platform_pty_command.cwdFromUtf8(&cwd_buf, cwd_path)
    else
        getActiveCwd(&cwd_buf);

    const ok = if (command.len != 0) blk: {
        const command_line = platform_pty_command.allocCommandLineFromUtf8(allocator, command) catch break :blk false;
        defer platform_pty_command.freeCommandLine(allocator, command_line);
        break :blk tab.spawnTabWithCommandAndCwd(allocator, term_cols, term_rows, platform_pty_command.commandLineFromOwned(command_line), g_cursor_style, g_cursor_blink, cwd);
    } else tab.spawnTabWithCwd(allocator, term_cols, term_rows, g_cursor_style, g_cursor_blink, cwd);

    if (ok) clearUiStateOnTabChange();
}

/// The Control the agent-control server drives. Backed by process-global state,
/// so the dummy ctx is unused.
pub fn agentControl() ctl_control.Control {
    return control_api.control();
}

pub fn activeSurfaceSnapshot(allocator: std.mem.Allocator) ?[]u8 {
    return surface_snapshots.activeSurfaceSnapshot(allocator);
}

fn agentRequestNativeHandle(ctx: *anyopaque) ?window_backend.NativeHandle {
    const window: *AppWindow = @ptrCast(@alignCast(ctx));
    return window.getNativeHandle();
}

fn agentRequestSpawnDefaultTab() ?*Surface {
    const allocator = g_allocator orelse return null;
    if (!spawnTab(allocator)) return null;
    return activeSurface();
}

fn agentRequestSpawnTabWithCommand(command: []const u8) ?*Surface {
    return spawnTabWithCommandUtf8ReturningSurface(command);
}

fn agentRequestCloseTabByIndex(idx: usize) void {
    closeTab(idx);
}

fn agentRequestConnectSshProfile(identifier: []const u8) agent_requests.SshConnectResult {
    return switch (overlays.agentConnectSshProfile(identifier)) {
        .connected => |surface| .{ .connected = surface },
        .not_found => .not_found,
        .failed => .failed,
    };
}

fn agentRequestSaveSshProfile(allocator: std.mem.Allocator, args: ai_chat.SshProfileSaveArgs) anyerror!ai_chat.SavedSshProfile {
    return overlays.agentSaveSshProfile(allocator, args);
}

const AgentTerminalFocusTarget = struct {
    surface: *Surface,
    tab_index: usize,
};

fn focusAgentTerminalSurfaceById(surface_id_raw: []const u8) ?AgentTerminalFocusTarget {
    const surface_id = std.mem.trim(u8, surface_id_raw, " \t\r\n");
    if (surface_id.len == 0) return null;

    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.surface.remote_id[0..], surface_id)) continue;

            if (active_tab_state.g_active_tab != tab_index) {
                switchTab(tab_index);
            }
            tab_state.focused = entry.handle;
            handleActiveSurfaceChangeWithinTab();
            return .{
                .surface = entry.surface,
                .tab_index = tab_index,
            };
        }
    }
    return null;
}

fn reconnectAgentTerminalSurface(allocator: std.mem.Allocator, surface_id_raw: []const u8) anyerror!ai_chat.ToolSurface {
    const surface_id = std.mem.trim(u8, surface_id_raw, " \t\r\n");
    if (surface_id.len == 0) return error.SurfaceNotFound;

    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            const surface = entry.surface;
            if (!std.mem.eql(u8, surface.remote_id[0..], surface_id)) continue;
            if (surface.launch_kind != .ssh) return error.NotSshSurface;
            if (!surface.canRespawn()) return error.NotReconnectable;
            surface.respawn();
            // Match the UI Enter-to-reconnect path: respawn retains the SSH
            // profile but does not arm password prompt detection itself.
            if (surface.ssh_connection) |*conn| {
                if (conn.usesPasswordAuth()) overlays.scheduleSshPasswordForSurface(surface);
            }
            return surface_snapshots.makeAgentToolSurface(allocator, surface, tab_index, false);
        }
    }
    return error.SurfaceNotFound;
}

fn agentRequestFocusTerminalSurface(allocator: std.mem.Allocator, surface_id: []const u8) anyerror!ai_chat.ToolSurface {
    const target = focusAgentTerminalSurfaceById(surface_id) orelse return error.SurfaceNotFound;
    return surface_snapshots.makeAgentToolSurface(
        allocator,
        target.surface,
        target.tab_index,
        true,
    );
}

const AgentUiScreenshotCapture = struct {
    rect: appwindow_ui_screenshot.Rect,
    target: ai_chat_types.UiScreenshotTarget,
    surface_id: ?[]const u8 = null,
};

const LiveUiScreenshotRect = struct {
    rect: appwindow_ui_screenshot.Rect,
    surface_id: ?[]const u8 = null,
};

fn fullUiScreenshotCapture(fb_width: u32, fb_height: u32) AgentUiScreenshotCapture {
    return .{
        .rect = .{ .x = 0, .y = 0, .width = fb_width, .height = fb_height },
        .target = .active_tab,
    };
}

fn splitRectToUiScreenshotRect(rect: split_layout.SplitRect) ?appwindow_ui_screenshot.Rect {
    if (rect.width <= 0 or rect.height <= 0) return null;
    return .{
        .x = rect.x,
        .y = rect.y,
        .width = @intCast(rect.width),
        .height = @intCast(rect.height),
    };
}

fn liveUiScreenshotRectForHandle(handle: SplitTree.Node.Handle) ?LiveUiScreenshotRect {
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (rect.handle != handle) continue;
        if (!split_layout.cachedRectIsLive(rect)) continue;
        return .{
            .rect = splitRectToUiScreenshotRect(rect) orelse return null,
            .surface_id = if (rect.surface()) |surface| surface.remote_id[0..] else null,
        };
    }
    return null;
}

fn liveUiScreenshotRectForSurfaceId(surface_id: []const u8) ?LiveUiScreenshotRect {
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(rect)) continue;
        const surface = rect.surface() orelse continue;
        if (std.mem.eql(u8, surface.remote_id[0..], surface_id)) {
            return .{
                .rect = splitRectToUiScreenshotRect(rect) orelse continue,
                .surface_id = surface.remote_id[0..],
            };
        }
    }
    return null;
}

fn isFocusedUiScreenshotSelector(surface_id: []const u8) bool {
    return surface_id.len == 0 or
        std.ascii.eqlIgnoreCase(surface_id, "focused") or
        std.ascii.eqlIgnoreCase(surface_id, "active") or
        std.ascii.eqlIgnoreCase(surface_id, "current");
}

fn resolveAgentUiScreenshotCapture(
    target: ai_chat_types.UiScreenshotTarget,
    surface_id: ?[]const u8,
    fb_width: u32,
    fb_height: u32,
) anyerror!AgentUiScreenshotCapture {
    const full = fullUiScreenshotCapture(fb_width, fb_height);
    const id = if (surface_id) |raw| std.mem.trim(u8, raw, " \t\r\n") else "";
    const focused_selector = isFocusedUiScreenshotSelector(id);
    switch (target) {
        .active_tab => {
            if (focused_selector) return full;
            const active_tab = tab.activeTab() orelse return error.SurfaceNotInActiveTab;
            if (active_tab.kind != .terminal) return error.SurfaceNotInActiveTab;
            const live = liveUiScreenshotRectForSurfaceId(id) orelse return error.SurfaceNotInActiveTab;
            return .{ .rect = full.rect, .target = .active_tab, .surface_id = live.surface_id };
        },
        .focused_panel => {
            const active_tab = tab.activeTab() orelse {
                if (focused_selector) return full;
                return error.SurfaceNotInActiveTab;
            };
            if (active_tab.kind != .terminal) {
                if (focused_selector) return full;
                return error.SurfaceNotInActiveTab;
            }

            if (focused_selector) {
                const live = liveUiScreenshotRectForHandle(active_tab.focused) orelse return full;
                return .{ .rect = live.rect, .target = .focused_panel, .surface_id = live.surface_id };
            }

            const live = liveUiScreenshotRectForSurfaceId(id) orelse return error.SurfaceNotInActiveTab;
            return .{ .rect = live.rect, .target = .focused_panel, .surface_id = live.surface_id };
        },
    }
}

fn ensureAbsoluteDir(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return err;
            try ensureAbsoluteDir(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => {},
                else => return err2,
            };
        },
        else => return err,
    };
}

fn writeUiScreenshotFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) {
            if (std.fs.path.isAbsolute(parent)) {
                try ensureAbsoluteDir(parent);
            } else {
                try std.fs.cwd().makePath(parent);
            }
        }
    }

    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn agentUiScreenshotBaseDir(allocator: std.mem.Allocator, working_dir: ?[]const u8) ![]const u8 {
    if (working_dir) |wd| {
        if (wd.len > 0) return allocator.dupe(u8, wd);
    }
    return platform_dirs.exportsDir(allocator);
}

fn agentRequestCaptureUiScreenshot(
    allocator: std.mem.Allocator,
    target: ai_chat_types.UiScreenshotTarget,
    surface_id: ?[]const u8,
    working_dir: ?[]const u8,
) anyerror!ai_chat_types.UiScreenshotResult {
    const win = g_window orelse return error.WindowUnavailable;
    if (window_backend.isMinimized(win)) return error.WindowUnavailable;

    const fb = window_backend.framebufferSize(win);
    if (fb.width <= 0 or fb.height <= 0) return error.WindowUnavailable;
    const fb_width: u32 = @intCast(fb.width);
    const fb_height: u32 = @intCast(fb.height);

    const output_base = try agentUiScreenshotBaseDir(allocator, working_dir);
    defer allocator.free(output_base);

    const capture = try resolveAgentUiScreenshotCapture(target, surface_id, fb_width, fb_height);
    const rect = appwindow_ui_screenshot.clampRect(capture.rect, fb_width, fb_height) orelse return error.WindowUnavailable;

    const bottom_up = try gpu.readback.readRgba(
        allocator,
        rect.x,
        appwindow_ui_screenshot.glReadY(rect, fb_height),
        rect.width,
        rect.height,
    );
    defer allocator.free(bottom_up);

    const top_down = try png_writer.flipRgbaRows(allocator, bottom_up, rect.width, rect.height);
    defer allocator.free(top_down);

    const output_image = try appwindow_ui_screenshot.fitRgbaToMaxLongEdge(
        allocator,
        top_down,
        rect.width,
        rect.height,
        appwindow_ui_screenshot.max_output_long_edge,
    );
    defer output_image.deinit(allocator);

    const png = try png_writer.encodeRgba(allocator, .{
        .width = output_image.width,
        .height = output_image.height,
        .rgba = output_image.rgba,
    });
    defer allocator.free(png);

    var result_surface_id: ?[]u8 = null;
    errdefer if (result_surface_id) |id| allocator.free(id);
    if (capture.surface_id) |id| {
        result_surface_id = try allocator.dupe(u8, id);
    }

    const path = try appwindow_ui_screenshot.outputPath(allocator, output_base, std.time.milliTimestamp());
    errdefer allocator.free(path);
    try writeUiScreenshotFile(path, png);

    return .{
        .path = path,
        .mime = "image/png",
        .width = output_image.width,
        .height = output_image.height,
        .target = capture.target,
        .surface_id = result_surface_id,
    };
}

fn agentRequestHost() agent_requests.Host {
    return .{
        .nativeHandleForContext = agentRequestNativeHandle,
        .currentNativeHandle = currentNativeHandle,
        .spawnDefaultTab = agentRequestSpawnDefaultTab,
        .spawnTabWithCommand = agentRequestSpawnTabWithCommand,
        .closeTabByIndex = agentRequestCloseTabByIndex,
        .connectSshProfile = agentRequestConnectSshProfile,
        .saveSshProfile = agentRequestSaveSshProfile,
        .captureUiScreenshot = agentRequestCaptureUiScreenshot,
        .focusTerminalSurface = agentRequestFocusTerminalSurface,
        .reconnectTerminalSurface = reconnectAgentTerminalSurface,
    };
}

fn quakeWorkAreaForWindow(win: *window_backend.Window) ?quick_terminal.WorkArea {
    const work_area = window_backend.nearestMonitorWorkArea(win) orelse return null;
    return .{
        .left = work_area.left,
        .top = work_area.top,
        .right = work_area.right,
        .bottom = work_area.bottom,
    };
}

fn currentQuakeFrame(win: *window_backend.Window) ?quick_terminal.Frame {
    const rect = window_backend.windowRect(win) orelse return null;
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    if (width <= 0 or height <= 0) return null;
    return .{ .x = rect.left, .y = rect.top, .width = width, .height = height };
}

fn rememberQuakeFrame(win: *window_backend.Window) void {
    if (window_backend.isMinimized(win) or window_backend.isFullscreen(win)) return;
    if (window_backend.isMaximized(win)) return;

    const frame = currentQuakeFrame(win) orelse return;
    if (quakeWorkAreaForWindow(win)) |work_area| {
        if (!quick_terminal.frameIntersectsWorkArea(frame, work_area)) return;
    }
    g_quake_frame = frame;
}

/// Record the window's top-left while it is in a normal windowed state, so the
/// save-on-close path can persist a real position when the window is closed while
/// maximized or fullscreen (those report a maximized rect, not the user's windowed
/// origin). Skipped in quake mode, which manages its own frame.
fn rememberWindowedPosition(win: *window_backend.Window) void {
    if (g_quake_mode) return;
    if (window_backend.isMinimized(win) or window_backend.isMaximized(win) or window_backend.isFullscreen(win)) return;
    const rect = window_backend.windowRect(win) orelse return;
    platform_window_state.g_windowed_x = rect.left;
    platform_window_state.g_windowed_y = rect.top;
}

fn applyQuakeFrame(win: *window_backend.Window, use_cached_frame: bool) void {
    const work_area = quakeWorkAreaForWindow(win) orelse return;
    const frame = if (use_cached_frame) frame: {
        if (g_quake_frame) |cached| {
            if (quick_terminal.frameIntersectsWorkArea(cached, work_area)) {
                break :frame cached;
            }
            g_quake_frame = null;
        }
        break :frame quick_terminal.calculateFrame(.{ .work_area = work_area });
    } else quick_terminal.calculateFrame(.{ .work_area = work_area });

    applyOuterFrame(win, frame, false);
}

fn applyOuterFrame(win: *window_backend.Window, frame: quick_terminal.Frame, topmost: bool) void {
    _ = window_backend.setOuterFrame(win, .{
        .left = frame.x,
        .top = frame.y,
        .right = frame.x + frame.width,
        .bottom = frame.y + frame.height,
    }, topmost);
    _ = window_backend.refreshClientSizeFromNative(win);
    window_backend.markVisibleAndSizeChanged(win);
}

fn quakeHotkeyBinding() ?keybind.Binding {
    const binding = g_keybinds.firstForAction(.toggle_quake) orelse return null;
    return if (binding.global) binding else null;
}

fn globalHotkeyTrigger(trigger: keybind.Trigger) platform_global_hotkey.Trigger {
    return .{
        .ctrl = trigger.mods.ctrl,
        .shift = trigger.mods.shift,
        .alt = trigger.mods.alt,
        .win = trigger.mods.win,
        .key_code = trigger.key_code,
    };
}

fn syncQuakeHotkeyRegistration(win: *window_backend.Window) void {
    const handle = window_backend.nativeHandle(win);
    if (g_quake_hotkey_registered) {
        platform_global_hotkey.unregister(handle, quick_terminal.HOTKEY_ID);
        g_quake_hotkey_registered = false;
    }

    if (!g_quake_mode) return;
    const binding = quakeHotkeyBinding() orelse return;
    g_quake_hotkey_registered = platform_global_hotkey.register(
        handle,
        quick_terminal.HOTKEY_ID,
        globalHotkeyTrigger(binding.trigger),
    );
    if (!g_quake_hotkey_registered) {
        var label_buf: [64]u8 = undefined;
        const label = keybind.formatTrigger(binding.trigger, &label_buf) catch "configured";
        std.debug.print("Quake mode hotkey {s} is already registered by another app or window\n", .{label});
    }
}

pub fn toggleQuakeVisibility() void {
    if (!g_quake_mode) return;
    const win = g_window orelse return;

    if (g_quake_hidden or window_backend.isMinimized(win)) {
        applyQuakeFrame(win, true);
        _ = window_backend.showVisible(win);
        _ = window_backend.setForeground(win);
        g_quake_hidden = false;
        g_force_rebuild = true;
        g_cells_valid = false;
    } else {
        rememberQuakeFrame(win);
        window_backend.clearTransientInput(win);
        _ = window_backend.showHidden(win);
        g_quake_hidden = true;
    }
}

fn onPlatformMessage(msg: window_backend.MessageId, wParam: window_backend.WordParam, lParam: window_backend.LongParam) ?window_backend.MessageResult {
    if (window_backend.isHotkeyMessage(msg, wParam, quick_terminal.HOTKEY_ID)) {
        toggleQuakeVisibility();
        return 1;
    }

    const decoded = thread_message.decode(msg, lParam) orelse return null;
    const agent_host = agentRequestHost();
    switch (decoded.tag) {
        .agent_ssh_connect => agent_requests.handleSshConnectRequest(@ptrFromInt(decoded.ptr), agent_host),
        .agent_ssh_save => agent_requests.handleSshSaveRequest(@ptrFromInt(decoded.ptr), agent_host),
        .agent_tab_new => agent_requests.handleTabNewRequest(@ptrFromInt(decoded.ptr), agent_host),
        .agent_tab_close => agent_requests.handleTabCloseRequest(@ptrFromInt(decoded.ptr), agent_host),
        .agent_ui_screenshot => agent_requests.handleUiScreenshotRequest(@ptrFromInt(decoded.ptr), agent_host),
        .agent_terminal_focus => agent_requests.handleTerminalFocusRequest(@ptrFromInt(decoded.ptr), agent_host),
        .agent_terminal_reconnect => agent_requests.handleTerminalReconnectRequest(@ptrFromInt(decoded.ptr), agent_host),
        .remote_ai_input => remote_sync.handleAiInputRequest(@ptrFromInt(decoded.ptr), remoteSyncHost()),
        .remote_open_ai_agent => remote_sync.handleAiAgentOpenRequest(@ptrFromInt(decoded.ptr), remoteSyncHost()),
        .chatops_control => weixin_bridge.handleControlRequest(@ptrFromInt(decoded.ptr), weixinBridgeHost()),
    }
    return 1;
}

fn installAgentToolHost(self: *AppWindow) void {
    agent_requests.setHost(agentRequestHost());
    ai_chat.setToolHost(.{
        .ctx = @ptrCast(self),
        .collectSnapshot = surface_snapshots.collectAgentToolSnapshot,
        .surfaceSnapshot = surface_snapshots.agentSurfaceSnapshot,
        .writeSurface = surface_snapshots.agentWriteSurface,
        .spawnTab = agent_requests.spawnTab,
        .closeTab = agent_requests.closeTab,
        .saveSshProfile = agent_requests.saveSshProfile,
        .connectSshProfile = agent_requests.connectSshProfile,
        .sshConnectionForSurface = surface_snapshots.agentSshConnectionForSurface,
        .uiScreenshot = agent_requests.uiScreenshot,
        .focusTerminal = agent_requests.focusTerminal,
        .reconnectTerminal = agent_requests.reconnectTerminal,
    });
}

fn installRemoteControlHandlers(self: *AppWindow) void {
    if (self.app.remote_client) |client| {
        client.registerAiAgentOpener(self.app, openRemoteAiAgentForClient);
    }
}

fn onPlatformMenuAction(action: keybind.Action) void {
    _ = input.invokeKeybindAction(action);
}

fn installPlatformMenu() void {
    if (platform_menu.isInstalled()) return;
    platform_menu.install(onPlatformMenuAction);
}

fn uiFontSize(term_font_size: u32) u32 {
    return @min(24, @max(9, term_font_size));
}

fn markAllRenderersDirty() void {
    g_force_rebuild = true;
    g_cells_valid = false;
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |tb| {
            var it = tb.tree.surfaces();
            while (it.next()) |entry| {
                entry.surface.surface_renderer.markDirty();
            }
        }
    }
}

/// Last render timestamp driven by the render gate's focused cursor blink.
threadlocal var g_gate_last_blink_render: i64 = 0;

/// Monotonic main-loop iteration counter. Lets the latency probe tell whether a
/// frame was presented in the SAME iteration that processed the input (true
/// input→present latency) or a LATER one (the input painted nothing in its own
/// iteration — a modifier/unfocused key, or a missing-force_rebuild bug — and an
/// unrelated wake such as the cursor blink presented instead).
pub threadlocal var g_loop_iter: u64 = 0;

/// Frame-latency instrumentation (opt-in via render diagnostics): the sliding
/// window of input→present samples and the last time we flushed a summary line.
/// Lets us quantify the overlay arrow-key "feel" (see frame_latency.zig).
threadlocal var g_frame_latency: frame_latency.Stats = .{};
threadlocal var g_frame_latency_last_flush_ms: i64 = 0;

fn usToMs(us: i64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

/// Called once per presented frame. When the frame was triggered by a key/char
/// event, record how long input→present took, and emit a p50/p95/max summary to
/// the render-diagnostics log about once a second. No-op unless diagnostics are
/// enabled (`WISPTERM_RENDER_DIAGNOSTICS=1` or `wispterm-debug-render = true`).
fn recordFrameLatencyIfInputDriven() void {
    if (!render_diagnostics.enabled()) return;
    if (input.g_pending_input_us != 0) {
        const lat_us = std.time.microTimestamp() - input.g_pending_input_us;
        if (input.g_pending_input_iter == g_loop_iter) {
            // Painted in the same iteration that processed the input: real feel.
            g_frame_latency.record(lat_us);
        } else {
            // The loop idled between the input and this paint, so an unrelated
            // wake (cursor blink, PTY output) presented — not real input latency.
            // Surface it separately so it never inflates p50/p95, and so a real
            // missing-force_rebuild regression still shows up while navigating.
            render_diagnostics.log("frame-latency STALL input->present={d:.1}ms iters={d} (input painted nothing in its own iteration: modifier/unfocused key, or a missing force_rebuild)", .{
                usToMs(lat_us),
                g_loop_iter -% input.g_pending_input_iter,
            });
        }
        input.g_pending_input_us = 0;
    }
    if (g_frame_latency.isEmpty()) return;
    const now_ms = std.time.milliTimestamp();
    if (now_ms - g_frame_latency_last_flush_ms < 1000) return;
    g_frame_latency_last_flush_ms = now_ms;
    const s = g_frame_latency.summary();
    render_diagnostics.log("frame-latency input->present count={d} p50={d:.1}ms p95={d:.1}ms max={d:.1}ms", .{
        s.count,
        usToMs(s.p50_us),
        usToMs(s.p95_us),
        usToMs(s.max_us),
    });
    g_frame_latency.resetWindow();
}

/// Whether any surface in `tb` has unconsumed PTY output. Pure over the tab so
/// the active-tab-only render gate is unit-testable.
fn anyTabSurfaceDirty(tb: *const tab.TabState) bool {
    var it = tb.tree.surfaces();
    while (it.next()) |entry| {
        if (entry.surface.dirty.load(.acquire)) return true;
    }
    return false;
}

fn clearTabSurfaceDirty(tb: *const tab.TabState) void {
    var it = tb.tree.surfaces();
    while (it.next()) |entry| {
        _ = entry.surface.dirty.swap(false, .acq_rel);
    }
}

/// Render-gate dirty signal: only the active tab's surfaces are drawn, so only
/// their output should trigger frames. Background-tab output leaves its dirty
/// flag latched (consumed on tab switch, which force-rebuilds); with the
/// one-wakeup-per-consume dedupe this also means a backgrounded build stops
/// waking the UI thread entirely instead of driving vsync-rate repaints.
fn anyVisibleSurfaceDirty() bool {
    const tb = activeTab() orelse return false;
    return anyTabSurfaceDirty(tb);
}

fn clearVisibleSurfaceDirty() void {
    const tb = activeTab() orelse return;
    clearTabSurfaceDirty(tb);
}

fn aiStreamingActive() bool {
    if (activeAiChat()) |session| {
        if (session.request_inflight) return true;
    }
    if (activeTab()) |tb| {
        if (tb.copilot_session) |session| {
            if (session.request_inflight) return true;
        }
    }
    return false;
}

fn clearIconFont(allocator: std.mem.Allocator) void {
    if (font.icon_face) |old_icon| old_icon.deinit();
    font.icon_face = null;
    font.icon_cache.deinit(allocator);
    font.icon_cache = .empty;
    if (font.g_icon_atlas) |*a| {
        a.deinit(allocator);
        font.g_icon_atlas = null;
    }
    if (font.g_icon_atlas_texture.isValid()) {
        font.g_icon_atlas_texture.destroy();
        font.g_icon_atlas_texture = gpu.Texture.invalid();
        font.g_icon_atlas_modified = 0;
    }
}

fn rebuildIconFont(allocator: std.mem.Allocator, ft_lib: freetype.Library) void {
    clearIconFont(allocator);

    const icon_font = font_backend.titlebarIconFont();
    if (ft_lib.initFace(icon_font.path, @intCast(icon_font.face_index))) |iface| {
        const icon_size_26_6 = platform_display.scaledPixels26Dot6ForDpi(10, font.g_dpi);
        iface.setCharSize(0, icon_size_26_6, 72, 72) catch {};
        font.icon_face = iface;
        std.debug.print("Loaded {s} for caption icons (dpi={})\n", .{ icon_font.display_name, font.g_dpi });
    } else |_| {
        std.debug.print("{s} not found, using quad-based caption icons\n", .{icon_font.display_name});
    }
}

fn clearTitlebarFont(allocator: std.mem.Allocator) void {
    if (font.g_titlebar_face) |old_tb| old_tb.deinit();
    font.g_titlebar_face = null;
    font.g_titlebar_cache.deinit(allocator);
    font.g_titlebar_cache = .empty;
    if (font.g_titlebar_atlas) |*a| {
        a.deinit(allocator);
        font.g_titlebar_atlas = null;
    }
    if (font.g_titlebar_atlas_texture.isValid()) {
        font.g_titlebar_atlas_texture.destroy();
        font.g_titlebar_atlas_texture = gpu.Texture.invalid();
        font.g_titlebar_atlas_modified = 0;
    }
}

fn reloadFontFaces(
    allocator: std.mem.Allocator,
    family: []const u8,
    weight: font_backend.FontWeight,
    font_size: u32,
    ft_lib: freetype.Library,
) bool {
    const new_face = font.loadFontFromConfig(allocator, family, weight, font_size, ft_lib) orelse return false;

    if (font.glyph_face) |old| old.deinit();
    font.clearGlyphCache(allocator);
    font.clearFallbackFaces(allocator);
    font.g_bell_cache = null;
    if (font.g_bell_emoji_face) |f| f.deinit();
    font.g_bell_emoji_face = null;

    font.g_font_size = font_size;
    font.preloadCharacters(new_face);

    rebuildTitlebarFont(allocator, family, weight, uiFontSize(font_size), ft_lib);
    rebuildIconFont(allocator, ft_lib);
    if (g_window) |w| _ = syncWindowTitlebarHeight(w);
    markAllRenderersDirty();
    return true;
}

fn handleWindowDpiChanged(
    allocator: std.mem.Allocator,
    win: *window_backend.Window,
    ft_lib: freetype.Library,
    family: []const u8,
    weight: font_backend.FontWeight,
) void {
    const new_dpi = window_backend.effectiveDpi(win);
    if (new_dpi == 0) return;

    // Reject a degenerate DPI before it reaches font sizing (see #90). A bogus
    // value (observed on some multi-monitor / HiDPI setups during the startup
    // resize) would scale glyph bitmaps to absurd dimensions; while the atlas
    // packer now rejects oversized glyphs, keeping the old DPI here also avoids
    // a window full of unrenderable text. The cap is 32x the platform baseline
    // (display.default_dpi), far above any real display.
    const max_sane_dpi: u32 = platform_display.default_dpi * 32;
    if (new_dpi > max_sane_dpi) {
        render_diagnostics.log(
            "dpi-change reject implausible new_dpi={} (max={}) keeping font_dpi={}",
            .{ new_dpi, max_sane_dpi, font.g_dpi },
        );
        std.debug.print("Ignoring implausible DPI {} (keeping {})\n", .{ new_dpi, font.g_dpi });
        return;
    }

    const client_before = window_backend.clientSize(win);
    const fb_before = window_backend.framebufferSize(win);
    render_diagnostics.log(
        "dpi-change begin old_font_dpi={} new_dpi={} client={}x{} fb={}x{} cell={d:.2}x{d:.2} term={}x{}",
        .{
            font.g_dpi,
            new_dpi,
            client_before.width,
            client_before.height,
            fb_before.width,
            fb_before.height,
            font.cell_width,
            font.cell_height,
            term_cols,
            term_rows,
        },
    );
    if (font.g_dpi == new_dpi) {
        const size = window_backend.clientSize(win);
        render_diagnostics.log(
            "dpi-change same-dpi render-refresh client={}x{} font_dpi={} cell={d:.2}x{d:.2}",
            .{ size.width, size.height, font.g_dpi, font.cell_width, font.cell_height },
        );
        renderResizeFrame(size.width, size.height);
        return;
    }

    const old_font_dpi = font.g_dpi;
    std.debug.print("DPI changed: {} -> {}\n", .{ old_font_dpi, new_dpi });
    font.g_dpi = new_dpi;
    if (reloadFontFaces(allocator, family, weight, font.g_font_size, ft_lib)) {
        const size = window_backend.clientSize(win);
        const fb_after = window_backend.framebufferSize(win);
        render_diagnostics.log(
            "dpi-change font-reloaded client={}x{} fb={}x{} font_dpi={} cell={d:.2}x{d:.2} term={}x{}",
            .{ size.width, size.height, fb_after.width, fb_after.height, font.g_dpi, font.cell_width, font.cell_height, term_cols, term_rows },
        );
        renderResizeFrame(size.width, size.height);
    } else {
        font.g_dpi = old_font_dpi;
        const size = window_backend.clientSize(win);
        render_diagnostics.log(
            "dpi-change font-reload-failed new_dpi={} restored_font_dpi={} kept_cell={d:.2}x{d:.2}",
            .{ new_dpi, old_font_dpi, font.cell_width, font.cell_height },
        );
        std.debug.print("DPI font reload failed, keeping previous font\n", .{});
        renderResizeFrame(size.width, size.height);
    }
}

fn rebuildTitlebarFont(
    allocator: std.mem.Allocator,
    family: []const u8,
    weight: font_backend.FontWeight,
    pt: u32,
    ft_lib: freetype.Library,
) void {
    clearTitlebarFont(allocator);

    if (font.loadFontFromConfig(allocator, family, weight, pt, ft_lib)) |tb_face| {
        font.g_titlebar_face = tb_face;

        const sm = tb_face.handle.*.size.*.metrics;
        const tb_ascent = @as(f32, @floatFromInt(sm.ascender)) / 64.0;
        const tb_descent = @as(f32, @floatFromInt(sm.descender)) / 64.0;
        const tb_height = @as(f32, @floatFromInt(sm.height)) / 64.0;
        font.g_titlebar_cell_height = @round(tb_height);
        font.g_titlebar_baseline = @round(-tb_descent);

        var max_adv: f32 = 0;
        for (32..127) |cp| {
            if (font.loadTitlebarGlyph(@intCast(cp))) |g| {
                const adv = @as(f32, @floatFromInt(g.advance >> 6));
                max_adv = @max(max_adv, adv);
            }
        }
        if (max_adv > 0) font.g_titlebar_cell_width = max_adv;

        std.debug.print("UI font: {}pt {d:.0}x{d:.0} (ascent={d:.1}, descent={d:.1}, baseline={d:.0})\n", .{
            pt, font.g_titlebar_cell_width, font.g_titlebar_cell_height, tb_ascent, tb_descent, font.g_titlebar_baseline,
        });
    } else {
        std.debug.print("UI font init failed, keeping titlebar fallback metrics\n", .{});
    }
}

/// Check if the config file has changed and reload if so.
/// Debounces rapid changes (e.g. settings page writing multiple keys) into a single reload.
threadlocal var g_config_change_time: i64 = 0;
const CONFIG_DEBOUNCE_MS: i64 = 250;

fn checkConfigReload(allocator: std.mem.Allocator, watcher: *ConfigWatcher) void {
    if (watcher.hasChanged()) {
        g_config_change_time = std.time.milliTimestamp();
        return;
    }

    if (g_config_change_time == 0) return;
    const elapsed = std.time.milliTimestamp() - g_config_change_time;
    if (elapsed < CONFIG_DEBOUNCE_MS) return;

    g_config_change_time = 0;
    std.debug.print("Config file changed, reloading...\n", .{});

    const cfg = Config.load(allocator) catch |err| {
        std.debug.print("Failed to reload config: {}\n", .{err});
        return;
    };
    defer cfg.deinit(allocator);
    applyReloadedConfig(allocator, &cfg);
}

/// Reset cursor blink to visible state (call on keypress like Ghostty)
pub fn resetCursorBlink() void {
    g_cursor_blink_visible = true;
    g_last_blink_time = std.time.milliTimestamp();
}

// Cached cursor sampling state for the IME caret. TUIs (e.g. Claude Code)
// emit cursor save/restore sequences many times per second to animate a
// status line; the render-loop sampler would otherwise catch the cursor
// mid-animation and re-anchor the IME popup / inline preedit on the wrong row.
threadlocal var g_ime_caret_tracker: ime_caret.StabilityTracker = .{};

const ImeCaretSource = ime_caret.Source;

const ImeCaret = struct {
    x: usize,
    y: usize,
    source: ImeCaretSource,
};

fn syncImeCaretPosition(win: *window_backend.Window, split_count: usize) void {
    // The command palette is a modal overlay on top of every tab; anchor the IME
    // caret to its text filter, not the underlying terminal/AI-chat cursor.
    if (overlays.commandPaletteVisible()) {
        if (win.ime_composing) return; // freeze during composition (avoid drift)
        const size = window_backend.clientSize(win);
        if (overlays.commandPaletteImeCaret(
            @floatFromInt(size.width),
            @floatFromInt(size.height),
            currentTitlebarHeight(),
        )) |caret| {
            window_backend.setImeCaret(
                win,
                @intFromFloat(@round(caret.x)),
                @intFromFloat(@round(caret.y)),
                @intFromFloat(@max(1.0, @round(caret.h))),
            );
        }
        return;
    }

    if (activeAiChat()) |session| {
        // Freeze the caret during composition so the IMM popup, anchored when
        // the composition started, doesn't drift with local UI relayout.
        if (win.ime_composing) return;
        const size = window_backend.clientSize(win);
        const left = leftPanelsWidth();
        const chat_w = @max(1.0, @as(f32, @floatFromInt(size.width)) - left - rightPanelsWidthForWindow(size.width));
        syncAiChatImeCaret(win, session, left, chat_w);
        return;
    }

    // Copilot sidebar (on a terminal tab): anchor the IME caret to the panel's
    // composer, not the terminal cursor.
    if (aiCopilotVisible() and input.aiCopilotFocused()) {
        if (activeCopilotSessionForInput()) |session| {
            if (win.ime_composing) return;
            const size = window_backend.clientSize(win);
            const bounds = ai_sidebar.boundsForWindow(size.width, size.height, currentTitlebarHeight(), leftPanelsWidth(), 0);
            const chat_x: f32 = @floatFromInt(bounds.left);
            const chat_w: f32 = @floatFromInt(bounds.right - bounds.left);
            syncAiChatImeCaret(win, session, chat_x, chat_w);
            return;
        }
    }

    const surface = activeSurface() orelse return;

    // Once the IME starts composing, keep the candidate window and inline
    // preedit anchored to the last stable position. TUIs can repaint status
    // areas while composing, and moving the OS IME window mid-composition is
    // more disruptive than waiting for the next composition session.
    if (win.ime_composing) return;

    var caret: ImeCaret = undefined;
    {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        caret = imeCaretFromSurfaceLocked(surface);
    }

    // Require two consecutive frames at the same terminal-cursor position
    // before committing, so single-frame transients during status-line
    // animations are skipped. Visual inverse carets are app-drawn stable cells
    // (some TUIs hide the terminal cursor and draw one this way), so accept
    // them immediately.
    if (g_ime_caret_tracker.commit(.{
        .x = @intCast(caret.x),
        .y = @intCast(caret.y),
        .source = caret.source,
    }) == null) return;

    const pad = surface.getPadding();
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;

    var origin_x: f32 = titlebar.sidebarWidth();
    var origin_y: f32 = currentTitlebarHeight();
    if (split_count > 1) {
        for (0..split_layout.g_split_rect_count) |i| {
            const rect = split_layout.g_split_rects[i];
            if (rect.surface()) |s| {
                if (s == surface) {
                    origin_x = @floatFromInt(rect.x);
                    origin_y = @floatFromInt(rect.y);
                    break;
                }
            }
        }
    }
    const px = ime_caret.pixelPosition(caret.x, caret.y, origin_x, origin_y, pad.left, pad.top, cell_w, cell_h);
    window_backend.setImeCaret(
        win,
        @intFromFloat(@round(px.x)),
        @intFromFloat(@round(px.y)),
        @intFromFloat(@max(1.0, @round(cell_h))),
    );
}

fn imeCaretFromSurfaceLocked(surface: *Surface) ImeCaret {
    const terminal = &surface.terminal;
    const screen = terminal.screens.active;

    var caret: ImeCaret = .{
        .x = screen.cursor.x,
        .y = screen.cursor.y,
        .source = .terminal_cursor,
    };

    // Match the renderer: translate the cursor's page pin to a visible
    // viewport row. `screen.cursor.y` can be misleading when scrollback or
    // alternate screen page pins are involved.
    var cursor_row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var cursor_row_idx: usize = 0;
    while (cursor_row_it.next()) |row_pin| : (cursor_row_idx += 1) {
        if (@as(?*anyopaque, row_pin.node) == @as(?*anyopaque, screen.cursor.page_pin.node) and
            row_pin.y == screen.cursor.page_pin.y)
        {
            caret.y = cursor_row_idx;
            break;
        }
    }

    if (!terminal.modes.get(.cursor_visible)) {
        if (visualInverseImeCaretLocked(surface, caret)) |visual| return visual;
    }

    return caret;
}

fn visualInverseImeCaretLocked(surface: *Surface, anchor: ImeCaret) ?ImeCaret {
    const terminal = &surface.terminal;
    const screen = terminal.screens.active;
    const render_cols = @as(usize, terminal.cols);
    var best: ?ImeCaret = null;
    var best_point: ?ime_caret.Point = null;
    const anchor_point: ime_caret.Point = .{ .x = anchor.x, .y = anchor.y };

    var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var row_idx: usize = 0;
    while (row_it.next()) |row_pin| : (row_idx += 1) {
        const p = &row_pin.node.data;
        const rac = row_pin.rowAndCell();
        const page_cells = p.getCells(rac.row);
        const num_cols = @min(page_cells.len, render_cols);

        var col: usize = 0;
        while (col < num_cols) {
            if (!isInverseBlankImeCell(p, &page_cells[col])) {
                col += 1;
                continue;
            }

            const run_start = col;
            while (col < num_cols and isInverseBlankImeCell(p, &page_cells[col])) : (col += 1) {}
            const run_len = col - run_start;
            if (run_len <= 2) {
                const point: ime_caret.Point = .{ .x = run_start, .y = row_idx };
                if (!ime_caret.isBetterCandidate(anchor_point, best_point, point)) continue;
                best = .{
                    .x = run_start,
                    .y = row_idx,
                    .source = .visual_inverse,
                };
                best_point = point;
            }
        }
    }

    return best;
}

fn isInverseBlankImeCell(p: anytype, cell: anytype) bool {
    const cp = cell.codepoint();
    if (cp != 0 and cp != ' ') return false;
    const wide = @intFromEnum(cell.wide);
    if (wide == 2 or wide == 3) return false;
    if (!cell.hasStyling()) return false;
    const style = p.styles.get(p.memory, cell.style_id);
    return style.flags.inverse;
}

fn syncAiChatImeCaret(win: *window_backend.Window, session: *ai_chat.Session, chat_x: f32, chat_w: f32) void {
    const size = window_backend.clientSize(win);
    const wh: f32 = @floatFromInt(size.height);
    session.mutex.lock();
    const input_text = session.input();
    const layout = assistant_conversation_renderer.inputLayout(chat_x, chat_w, input_text);
    const cursor = assistant_conversation_renderer.inputCursorRect(input_text, session.inputCursorLocked(), layout.text_x, layout.text_w);
    const scrolled_row = session.input_scroll_row;
    const follow_cursor = session.input_scroll_follow_cursor;
    session.mutex.unlock();
    const input_line_h = @round(@max(23.0, font.g_titlebar_cell_height + 8.0));
    const visible_rows = assistant_conversation_renderer.inputVisibleRowsForField(layout.field_h);
    var first_row = scrolled_row;
    if (follow_cursor) {
        if (cursor.row < first_row) {
            first_row = cursor.row;
        } else if (cursor.row >= first_row + visible_rows) {
            first_row = cursor.row - visible_rows + 1;
        }
    }
    if (cursor.row < first_row) return;
    const row = cursor.row - first_row;
    const field_top_px = wh - layout.field_y - layout.field_h;
    const cursor_top_px = field_top_px + assistant_conversation_renderer.INPUT_FIELD_PAD_TOP + @as(f32, @floatFromInt(row)) * input_line_h;
    const cursor_y = cursor_top_px;
    const h = font.g_titlebar_cell_height;
    window_backend.setImeCaret(
        win,
        @intFromFloat(@round(cursor.x)),
        @intFromFloat(@round(cursor_y)),
        @intFromFloat(@max(1.0, @round(h))),
    );
}

fn renderImePreedit(win: *window_backend.Window, fb_width: i32, fb_height: i32) void {
    _ = fb_width;
    const text = window_backend.imePreeditText(win);
    if (text.len == 0) return;

    var view = std.unicode.Utf8View.init(text) catch return;
    var count_it = view.iterator();
    var cells: usize = 0;
    while (count_it.nextCodepoint()) |_| cells += 1;
    if (cells == 0) return;

    const x = @as(f32, @floatFromInt(win.ime_caret_x));
    const y = @as(f32, @floatFromInt(@max(0, fb_height - win.ime_caret_y - win.ime_caret_height)));
    const width = @as(f32, @floatFromInt(cells)) * font.cell_width;
    const height = @as(f32, @floatFromInt(win.ime_caret_height));

    const bg = g_theme.selection_background;
    const fg = g_theme.selection_foreground orelse g_theme.foreground;

    ui_pipeline.fillQuad(x, y, width, height, bg);
    ui_pipeline.fillQuad(x, y, width, @max(1.0, @as(f32, @floatFromInt(font.box_thickness))), g_theme.cursor_color);

    view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    var cursor_x = x;
    while (it.nextCodepoint()) |cp| {
        cell_renderer.renderChar(@intCast(cp), cursor_x, y, fg);
        cursor_x += font.cell_width;
    }
}

/// Handle a bell notification from the terminal.
/// Rate-limited to once per 100ms (matching Ghostty).
fn handleBell(surface: *Surface, win: *window_backend.Window, is_active_tab: bool) void {
    _ = is_active_tab;
    const now = std.time.milliTimestamp();
    if (now - surface.last_bell_time < 100) return;
    surface.last_bell_time = now;

    // Activate bell indicator (shown on both active and background tabs)
    surface.bell_indicator = true;
    surface.bell_indicator_time = now;

    platform_notifications.bell();
    platform_notifications.requestAttention(window_backend.nativeHandle(win));
}

/// Drain and handle queued desktop notifications for one surface.
/// `is_active_surface` means this is the focused surface of the active tab.
/// Window focus is applied separately inside `notif_mod.decideRoute`, which
/// only suppresses the toast when the window is focused AND this is true.
fn handleNotification(surface: *Surface, is_active_surface: bool) void {
    if (!g_desktop_notifications) {
        // Drain and discard so the queue can't grow while disabled.
        while (surface.notif_queue.pop() != null) {}
        return;
    }

    const native_toast = platform_notifications.supports_desktop_notifications;

    while (surface.notif_queue.pop()) |item| {
        const now = std.time.milliTimestamp();
        const h = notif_mod.contentHash(item.title(), item.body());
        if (!notif_mod.shouldDeliver(now, h, surface.last_notif_time, surface.last_notif_hash)) {
            continue;
        }

        // Lazy authorization request (macOS): first time we'd want a toast,
        // ask once. This delivery falls back to badge until the user answers.
        if (native_toast and !g_notif_auth_requested) {
            platform_notifications.requestNotificationAuth();
            g_notif_auth_requested = true;
        }

        const auth: notif_mod.AuthStatus = @enumFromInt(
            @intFromEnum(platform_notifications.notificationAuthStatus()),
        );
        const route = notif_mod.decideRoute(
            true, // g_desktop_notifications already checked above
            native_toast,
            auth,
            window_focused,
            is_active_surface,
        );

        switch (route) {
            .none => {},
            .toast => {
                var title_z: [notif_mod.max_title + 1]u8 = undefined;
                var body_z: [notif_mod.max_body + 1]u8 = undefined;
                const t = item.title();
                const b = item.body();
                @memcpy(title_z[0..t.len], t);
                title_z[t.len] = 0;
                @memcpy(body_z[0..b.len], b);
                body_z[b.len] = 0;
                platform_notifications.showDesktopNotification(
                    title_z[0..t.len :0],
                    body_z[0..b.len :0],
                );
                surface.bell_indicator = true; // also badge the tab
                surface.bell_indicator_time = now;
                surface.last_notif_hash = h;
                surface.last_notif_time = now;
            },
            .badge => {
                surface.bell_indicator = true;
                surface.bell_indicator_time = now;
                surface.last_notif_hash = h;
                surface.last_notif_time = now;
            },
        }

        // Forward to the bound WeChat owner when the notifier marked it, the
        // opt-in is on, and you are not looking right at this surface. The
        // controller self-guards on an active binding + bound owner and sends
        // off-thread, so this never blocks. (Reaches here only after the
        // shouldDeliver gate above, so it inherits rate-limit/dedup.)
        if (item.forward_wechat and g_weixin_notify_forward and
            !(window_focused and is_active_surface))
        {
            if (g_app) |app| {
                if (app.weixin_controller) |ctrl| ctrl.enqueueNotify(item.title(), item.body());
            }
        }
    }
}

/// Internal main loop - called by AppWindow.run() after init() has set up globals.
fn runMainLoop(self: *AppWindow) !void {
    const allocator = self.allocator;

    // Use stored config values from init()
    const requested_font = g_requested_font;
    const requested_weight = g_requested_weight;
    const font_size = font.g_font_size;
    const shader_path = g_shader_path;

    // NOTE: Initial tab is spawned AFTER window sizing (see below),
    // so the terminal is created with the correct dimensions.

    // ================================================================
    // Initialize windowing backend
    // Defers MUST be at function scope so the window/GL context
    // stays alive for the rest of main().
    // ================================================================

    // --- Platform window (cascade from parent or restore from last session) ---
    // Check if App has a suggested position (for cascading from parent window)
    var init_x: ?i32 = null;
    var init_y: ?i32 = null;
    if (g_app) |app| {
        app.mutex.lock();
        if (app.next_window_x) |x| {
            init_x = x;
            app.next_window_x = null;
        }
        if (app.next_window_y) |y| {
            init_y = y;
            app.next_window_y = null;
        }
        app.mutex.unlock();
    }
    // Restore saved geometry. Position only fills gaps left by a cascade; size is
    // restored only for a non-cascade (first/primary) window, so a new window
    // opened over an existing one does not snap to the last session's size.
    const restore_saved_size = init_x == null or init_y == null;
    var saved_fb_w: ?i32 = null;
    var saved_fb_h: ?i32 = null;
    {
        const saved_state = loadWindowState(allocator);
        if (saved_state) |s| {
            if (init_x == null) init_x = s.x;
            if (init_y == null) init_y = s.y;
            // Seed the last-windowed position so a session that stays maximized the
            // whole time still persists a real origin on close (otherwise (0,0)).
            // rememberWindowedPosition overwrites this on the first windowed frame.
            platform_window_state.g_windowed_x = s.x;
            platform_window_state.g_windowed_y = s.y;
            if (restore_saved_size) {
                saved_fb_w = s.width;
                saved_fb_h = s.height;
            }
        }
    }
    var backend_window = window_backend.create(allocator, .{
        .width = 800,
        .height = 600,
        .title = "WispTerm",
        .x = init_x,
        .y = init_y,
        .maximize = g_start_maximize and !g_start_fullscreen, // Don't maximize if going fullscreen
    }) catch |err| {
        std.debug.print("Failed to create platform window: {}\n", .{err});
        return err;
    };
    defer window_backend.destroy(&backend_window);
    window_backend.setGlobalWindow(&backend_window);
    g_window = &backend_window;
    self.native_handle_bits.store(window_backend.nativeHandleBits(&backend_window), .release);
    defer self.native_handle_bits.store(0, .release);
    // Publish a process-global UI handle so the WeChat poller thread can marshal
    // control requests here. Last window to init wins; cleared on teardown.
    weixin_bridge.setUiHandle(window_backend.nativeHandleBits(&backend_window));
    defer weixin_bridge.setUiHandle(0);
    if (g_quake_mode and (g_start_maximize or g_start_fullscreen)) {
        std.debug.print("Quake mode disabled for this window because maximize/fullscreen is enabled\n", .{});
        g_quake_mode = false;
    }
    window_backend.setEventHandlers(&backend_window, .{
        .on_message = &onPlatformMessage,
        .on_file_drop = &input.handleFileDrop,
    });
    syncQuakeHotkeyRegistration(&backend_window);
    defer if (g_quake_hotkey_registered) platform_global_hotkey.unregister(window_backend.nativeHandle(&backend_window), quick_terminal.HOTKEY_ID);
    installAgentToolHost(self);
    installRemoteControlHandlers(self);
    installPlatformMenu();
    font.g_dpi = window_backend.dpi(&backend_window);

    // --- Initialize the active GPU backend through the host surface seam ---
    switch (gpu.active) {
        .metal => try gpu.Context.initWithLayer(window_backend.metalLayer(&backend_window)),
        .opengl => {
            try gpu.Context.init(@ptrCast(&window_backend.glGetProcAddress));
            render_diagnostics.log(
                "gpu-backend=opengl present=window_backend fallback_path=available d3d11_active=false default_unchanged=true",
                .{},
            );
        },
        .d3d11 => {
            const fb = window_backend.framebufferSize(&backend_window);
            try gpu.Context.initForWindow(window_backend.nativeHandle(&backend_window), fb.width, fb.height);
        },
    }
    // Free the per-window-thread heap-backed TLS state (overlay state and, on
    // D3D11, the handle registries) when this window unwinds. Declared before
    // the pipeline/texture-owning defers below so it runs after all of them
    // (defers are LIFO); their deinits still see live storage to release
    // resources through.
    defer {
        overlays.releaseThreadState();
        if (comptime gpu.active == .d3d11) {
            gpu.Pipeline.releaseRegistry();
            gpu.Texture.releaseRegistry();
            gpu.Buffer.releaseRegistry();
            gpu.vertex.releaseRegistry();
        }
    }

    // Initialize FreeType
    const ft_lib = freetype.Library.init() catch |err| {
        std.debug.print("Failed to initialize FreeType: {}\n", .{err});
        return err;
    };
    defer ft_lib.deinit();

    // Store globally for fallback font loading
    font.g_ft_lib = ft_lib;
    defer font.g_ft_lib = null;

    std.debug.print("Requested font: {s} (weight: {})\n", .{ requested_font, @intFromEnum(requested_weight) });
    std.debug.print("Cursor style: {s}, blink: {}\n", .{ @tagName(g_cursor_style), g_cursor_blink });

    // Initialize system font discovery (keep alive for fallback lookups)
    var font_discovery: ?font_backend.FontDiscovery = font_backend.FontDiscovery.init() catch |err| blk: {
        std.debug.print("{s}: {}\n", .{ font_backend.discoveryInitErrorPrefix(), err });
        break :blk null;
    };
    defer if (font_discovery) |*discovery| discovery.deinit();

    // Store globally for fallback font lookups
    font.g_font_discovery = if (font_discovery) |*discovery| discovery else null;
    defer font.g_font_discovery = null;

    // Fallback faces are cleaned up in the main defer block (with font.glyph_face)

    // Try to find the requested font via the system font backend
    var font_result: ?font_backend.FontDiscovery.FontResult = null;

    if (font_discovery) |*discovery| {
        if (requested_font.len > 0) {
            if (discovery.findFontFilePath(allocator, requested_font, requested_weight, .NORMAL) catch null) |result| {
                font_result = result;
                std.debug.print("Found system font: {s}\n", .{result.path});
            } else {
                std.debug.print("Font '{s}' not found, will use embedded fallback\n", .{requested_font});
            }
        } else {
            std.debug.print("No font-family set, will use embedded fallback\n", .{});
        }
    }

    defer if (font_result) |*fr| fr.deinit();

    // Load the font with FreeType
    const face: freetype.Face = blk: {
        // Try system font first
        if (font_result) |fr| {
            if (ft_lib.initFace(fr.path, @intCast(fr.face_index))) |f| {
                break :blk f;
            } else |err| {
                std.debug.print("Failed to load system font: {}, using embedded fallback\n", .{err});
            }
        }

        // Fall back to embedded JetBrains Mono
        std.debug.print("Using embedded JetBrains Mono as fallback\n", .{});
        break :blk ft_lib.initMemoryFace(embedded.regular, 0) catch |err| {
            std.debug.print("Failed to load embedded font: {}\n", .{err});
            return err;
        };
    };
    // Don't defer face.deinit() here — glyph_face owns it and may be
    // replaced by hot-reload. Cleanup is in the defer block below.

    font.setFacePointSize(face, font_size) catch |err| {
        std.debug.print("Failed to set font size: {}\n", .{err});
        return err;
    };

    // Store font size globally for fallback fonts
    font.g_font_size = font_size;

    ui_pipeline.init();
    cell_pipeline.init();
    font.preloadCharacters(face);

    rebuildTitlebarFont(allocator, requested_font, requested_weight, uiFontSize(font_size), ft_lib);
    _ = syncWindowTitlebarHeight(&backend_window);

    // Load the platform caption icon font for titlebar buttons.
    rebuildIconFont(allocator, ft_lib);

    defer {
        // Clean up icon font
        if (font.icon_face) |f| {
            f.deinit();
            font.icon_face = null;
        }

        // Clean up the current font face (may have been replaced by hot-reload)
        if (font.glyph_face) |f| f.deinit();
        font.glyph_face = null;
        // Clean up glyph cache and atlas
        font.clearGlyphCache(allocator);
        font.clearFallbackFaces(allocator);
        // Clean up icon cache and icon atlas. Reset to .empty so the
        // threadlocal slot is safe to re-use if the main thread spawns
        // another first-window (e.g. macOS Dock reopen).
        font.icon_cache.deinit(allocator);
        font.icon_cache = .empty;
        if (font.g_icon_atlas) |*a| {
            a.deinit(allocator);
            font.g_icon_atlas = null;
        }
        if (font.g_icon_atlas_texture.isValid()) {
            font.g_icon_atlas_texture.destroy();
            font.g_icon_atlas_texture = gpu.Texture.invalid();
        }

        // Clean up titlebar font. Reset cache to .empty for the same reason
        // as icon_cache above.
        if (font.g_titlebar_face) |f| f.deinit();
        font.g_titlebar_face = null;
        font.g_titlebar_cache.deinit(allocator);
        font.g_titlebar_cache = .empty;
        if (font.g_titlebar_atlas) |*a| {
            a.deinit(allocator);
            font.g_titlebar_atlas = null;
        }
        if (font.g_titlebar_atlas_texture.isValid()) {
            font.g_titlebar_atlas_texture.destroy();
            font.g_titlebar_atlas_texture = gpu.Texture.invalid();
        }
    }
    // Initialize custom post-processing shader if requested
    post_process.init(allocator, shader_path);
    if (g_app) |app| {
        // Dupe the path under app.mutex so a concurrent updateConfig from
        // another window cannot free it out from under us.
        app.mutex.lock();
        const initial_path: ?[]u8 = if (app.background_image) |p| (allocator.dupe(u8, p) catch null) else null;
        app.mutex.unlock();
        if (initial_path) |p| {
            defer allocator.free(p);
            background_image.load(allocator, p);
        }
    }
    defer {
        background_image.deinit();
        d3d11_offscreen_smoke.deinit();
        d3d11_ui_smoke.deinit();
        post_process.deinit();
        // macOS/Metal: cell_pipeline/ui_pipeline.deinit() release the
        // MTLRenderPipelineState/MTLBuffer objects held in the render thread's
        // _Thread_local slot tables (renderer/gpu/metal/bridge.m). At TRUE
        // process exit on x86_64 that manual-refcount [obj release] cascade
        // faults as the thread's TLV storage is torn down (the reported crash is
        // inside cell_pipeline.deinit). The Metal device/queue/layer are already
        // leaked on purpose (gpu.Context.deinit is never called) and the OS
        // reclaims all GPU memory on process death, so skip these two on the LAST
        // window. A SECONDARY window closing while the app keeps running still
        // tears them down on its own live render thread to avoid leaking the
        // slot-table objects. OpenGL (Windows/Linux) teardown is well-behaved
        // and stays unchanged: gpu.active is comptime, so `skip` folds to false
        // off Metal and both deinits always run there.
        const is_last_window = blk: {
            self.app.mutex.lock();
            defer self.app.mutex.unlock();
            // This window is still in app.windows here — the caller swap-removes
            // it only AFTER runMainLoop returns — so len <= 1 means it is last.
            break :blk self.app.windows.items.len <= 1;
        };
        const skip_pipeline_teardown = gpu.active == .metal and is_last_window;
        if (!skip_pipeline_teardown) {
            cell_pipeline.deinit();
            ui_pipeline.deinit();
        }
    }

    // Ghostty approach: calculate grid size from ACTUAL window size.
    // This ensures the terminal is created with dimensions that match
    // what setScreenSize will compute, avoiding any resize on startup.
    //
    // Padding breakdown for a SINGLE FULL-WINDOW split:
    // - Render loop: content_w = fb_width - 20 (symmetric padding)
    // - computeSplitLayout: adds back padding for edge splits: pw = content_w + 20 = fb_width
    // - setScreenSize: subtracts explicit_padding: avail = pw - 32 (L=10, R=22)
    // - So total subtracted from fb_width: 32
    //
    // For height:
    // - Render loop: content_h = fb_height - top_padding - padding = fb_height - 44 - 10 = fb_height - 54
    //   (where top_padding = padding + titlebar = 10 + 34 = 44)
    // - computeSplitLayout: no edge extension for top/bottom, so ph = content_h
    // - setScreenSize: subtracts explicit_padding: avail = ph - 20 (T=10, B=10)
    // - So total subtracted from fb_height: 54 + 20 = 74
    //   Wait, let me recalculate...
    //   Actually: content_h = fb_height - (10+34) - 10 = fb_height - 54
    //   Then setScreenSizeWithPolicy: avail_h = content_h - 20 = fb_height - 74
    //
    // Actually there might be edge extension for top/bottom too. Let me just match exactly:
    // For a full-window single split (at all edges):
    //   pw = fb_width (after adding back padding for left+right edges)
    //   ph = content_h = fb_height - top_padding - padding = fb_height - 44 - 10 = fb_height - 54
    //   Wait, is there edge extension for y too?
    //
    // Looking at the code: only left/right edges get extension, not top/bottom.
    // So:
    //   setScreenSizeWithPolicy(pw=fb_width, ph=fb_height-54, explicit_padding)
    //   avail_w = fb_width - 10 - 22 = fb_width - 32
    //   avail_h = (fb_height - 54) - 10 - 10 = fb_height - 74
    const titlebar_height = currentTitlebarHeight();
    const explicit_left: f32 = @floatFromInt(DEFAULT_PADDING);
    const explicit_right: f32 = @as(f32, @floatFromInt(DEFAULT_PADDING)) + overlays.SCROLLBAR_WIDTH;
    const explicit_top: f32 = @floatFromInt(DEFAULT_PADDING);
    const explicit_bottom: f32 = @floatFromInt(DEFAULT_PADDING);
    const render_padding: f32 = 10;
    const initial_left_panels_w: f32 = leftPanelsWidth();

    // For width: pw = fb_width - left_panels_w, then subtract explicit_padding
    const total_width_padding = initial_left_panels_w + explicit_left + explicit_right;
    // For height: ph = fb_height - (render_padding + titlebar) - render_padding, then subtract explicit_padding
    const total_height_padding = (render_padding + titlebar_height) + render_padding + explicit_top + explicit_bottom; // 44 + 10 + 20 = 74

    // Initial sizing precedence:
    //   1. quake mode -> quake frame
    //   2. explicit window-width/height in config -> fit that cell grid
    //   3. remembered window size from last session -> restore it (framebuffer px)
    //   4. otherwise -> default cell grid (first-ever launch)
    const size_from_config = if (g_app) |app| app.window_size_from_config else false;
    // Grid size needed for term_cols/term_rows (used by branches 2 and 4).
    const desired_grid_width = font.cell_width * @as(f32, @floatFromInt(term_cols));
    const desired_grid_height = font.cell_height * @as(f32, @floatFromInt(term_rows));
    const target_fb_width: i32 = @intFromFloat(desired_grid_width + total_width_padding);
    const target_fb_height: i32 = @intFromFloat(desired_grid_height + total_height_padding);

    if (g_quake_mode) {
        // Seed the remembered frame from disk so the drop-down reopens at the
        // user's last size/position. applyQuakeFrame(.., true) validates it
        // against the current monitor work area and falls back to the default
        // frame if it no longer fits (resolution / monitor change).
        if (loadQuakeFrame(allocator)) |qf| {
            g_quake_frame = .{ .x = qf.x, .y = qf.y, .width = qf.width, .height = qf.height };
        }
        applyQuakeFrame(&backend_window, true);
    } else if (size_from_config and term_cols > 0 and term_rows > 0) {
        window_backend.resizeClientArea(&backend_window, target_fb_width, target_fb_height);
    } else if (saved_fb_w) |sw| {
        window_backend.resizeClientArea(&backend_window, sw, saved_fb_h.?);
    } else if (term_cols > 0 and term_rows > 0) {
        window_backend.resizeClientArea(&backend_window, target_fb_width, target_fb_height);
    }

    // Get actual window client size (after potential resize)
    const init_fb = window_backend.framebufferSize(&backend_window);
    const actual_width: f32 = @floatFromInt(init_fb.width);
    const actual_height: f32 = @floatFromInt(init_fb.height);

    // Calculate grid that fits in this window
    const avail_width = actual_width - total_width_padding;
    const avail_height = actual_height - total_height_padding;

    const computed_cols: u16 = @intFromFloat(@max(1, avail_width / font.cell_width));
    const computed_rows: u16 = @intFromFloat(@max(1, avail_height / font.cell_height));

    // Update term_cols/term_rows to match what the window can actually display
    term_cols = computed_cols;
    term_rows = computed_rows;

    // Now spawn the initial tab with the correct dimensions.
    // No resize will be needed because term_cols/term_rows match
    // what setScreenSize will compute from the window size.
    {
        const initial_cwd: platform_pty_command.Cwd = if (g_initial_cwd_len > 0)
            @ptrCast(&g_initial_cwd_buf)
        else
            null;
        g_initial_cwd_len = 0; // Clear after use

        if (bench_driver.isEnabled()) {
            // In-app GPU benchmark: spawn a no-shell virtual surface and hand
            // it (plus the virtual PTY controller) to the driver. Disable vsync
            // on both present paths so the loop spins at the GPU's max rate.
            // Session restore and the normal shell-tab plan are skipped — the
            // benchmark owns the single virtual surface for its whole run.
            const spawn = tab.spawnBenchmarkTab(allocator, term_cols, term_rows, g_cursor_style, g_cursor_blink) orelse {
                std.debug.print("Failed to spawn benchmark surface\n", .{});
                return error.SpawnFailed;
            };
            bench_driver.start(allocator, spawn.surface, term_cols, spawn.controller) catch {
                std.debug.print("Failed to start benchmark driver\n", .{});
                return error.SpawnFailed;
            };
            window_backend.setPresentInterval(0);
            // Native D3D11 Present uses its own interval (OpenGL goes through
            // window_backend above). Comptime-gated so non-D3D11 builds skip it.
            if (gpu.active == .d3d11) gpu.Context.setPresentInterval(0);
        } else {
            // Try to restore the previous session, but only:
            //   - once per process (first window only),
            //   - if config.restore-tabs-on-startup is true,
            //   - if no CWD override was provided (CLI/spawn).
            // TODO: also detect --command CLI override once a structured CLI
            // arg parser exists (today CLI args are merged into Config keys
            // and there is no positional/--command flag).
            const restore_once = !g_session_restore_attempted.swap(true, .seq_cst);
            const restore_enabled = if (g_app) |app| app.restore_tabs_on_startup else false;
            const should_try_restore = restore_once and restore_enabled and initial_cwd == null;
            const restored = should_try_restore and tab.restoreSessionFromFile(
                allocator,
                term_cols,
                term_rows,
                g_cursor_style,
                g_cursor_blink,
            );

            switch (startup_tabs.initialTabPlan(.{
                .restored_session = restored,
                .initial_cwd_present = initial_cwd != null,
                .first_plain_window = restore_once,
            })) {
                // Restoring tabs bypasses the normal tab-switch integration
                // path. Seed the active surface context now so a restored SSH
                // tab's Copilot binds to SSH instead of falling back to the
                // host-local command tool.
                .restored_session => syncActiveSurfaceCaches(),
                .single_terminal => {
                    if (!spawnTabWithCwd(allocator, initial_cwd)) {
                        std.debug.print("Failed to spawn initial tab\n", .{});
                        return error.SpawnFailed;
                    }
                },
                .agent_and_local_shell => {
                    if (!spawnDefaultAgentAndLocalShellTabs(allocator)) {
                        std.debug.print("Failed to spawn default Agent and local shell tabs\n", .{});
                        return error.SpawnFailed;
                    }
                },
            }
        }

        // Dev/automation hook: WISPTERM_AUTOCONNECT names an SSH profile to
        // connect (plain) on launch; WISPTERM_AUTOCONNECT_TMUX connects one in
        // tmux control mode. No manual launcher click — for testing/automation.
        if (std.process.getEnvVarOwned(allocator, "WISPTERM_AUTOCONNECT")) |autoconnect_profile| {
            defer allocator.free(autoconnect_profile);
            if (autoconnect_profile.len > 0) {
                std.debug.print("ssh: auto-connecting profile '{s}'\n", .{autoconnect_profile});
                _ = overlays.connectProfileByName(autoconnect_profile);
            }
        } else |_| {}
        if (std.process.getEnvVarOwned(allocator, "WISPTERM_AUTOCONNECT_TMUX")) |p| {
            defer allocator.free(p);
            if (p.len > 0) {
                std.debug.print("tmux: auto-connecting profile '{s}' (tmux)\n", .{p});
                _ = overlays.connectProfileByNameTmux(p);
            }
        } else |_| {}
    }

    gpu.state.setBlendEnabled(true);
    gpu.state.setBlendMode(.alpha);
    logGpuDiagnosticsOnce();

    // Register resize callback so newly exposed pixels get filled with the
    // terminal background during live resize. Some platform resize loops block
    // our main loop, so the backend can ask us to render from the resize event.
    window_backend.setEventHandlers(&backend_window, .{
        .on_resize = &onPlatformResize,
        .on_message = &onPlatformMessage,
        .on_file_drop = &input.handleFileDrop,
    });

    std.debug.print("Ready! Cell size: {d:.1}x{d:.1}\n", .{ font.cell_width, font.cell_height });

    // Ensure config directory + file exist so the watcher can observe from startup
    Config.ensureConfigExists(allocator);

    // Set up config file watcher.
    var config_watcher = ConfigWatcher.init(allocator);
    if (config_watcher == null) {
        std.debug.print("Config watcher not available (config directory may not exist)\n", .{});
    }
    defer if (config_watcher) |*w| w.deinit();

    // Initialize FPS timer
    overlays.g_fps_last_time = std.time.milliTimestamp();

    // Apply fullscreen if requested (after all initialization is complete)
    std.debug.print("g_start_fullscreen = {}\n", .{g_start_fullscreen});
    if (g_start_fullscreen) {
        std.debug.print("Entering fullscreen at startup...\n", .{});
        input.toggleFullscreen();
    }

    // Main loop — shared logic with backend-specific window management
    var running = true;
    while (running) {
        g_loop_iter +%= 1; // tag each iteration so the latency probe can tell same-iteration paints from stalls
        // Check for config file changes
        if (config_watcher) |*w| checkConfigReload(allocator, w);
        memory_digest_scheduler.tick(allocator);
        syncMemoryDigestStatus();
        tmux_controller.tickAll(allocator, term_cols, term_rows);
        overlays.tickSessionLauncher();
        overlays.tickQuickAiVerify();
        if (file_explorer.tickAsync()) {
            g_force_rebuild = true;
            g_cells_valid = false;
        }
        syncTransferToastFromFileExplorer();
        if (tickAllPreviewPanes()) {
            g_force_rebuild = true;
            g_cells_valid = false;
        }
        if (weixin_qr_panel.visible()) {
            const qr_allocator = g_allocator orelse allocator;
            if (weixin_qr_panel.refresh(qr_allocator)) {
                g_force_rebuild = true;
                g_cells_valid = false;
            }
        }
        maybePrintMemoryDebug(std.time.milliTimestamp());
        flushAgentHistoryStoreIfDirty(false);
        pollUpdateCheck(self.app);
        if (activeSkillCenter()) |sc_session| pollSkillCenterOp(sc_session);
        if (self.app.port_forward_manager.tick() and activePortForwarding() != null) {
            g_force_rebuild = true;
            g_cells_valid = false;
        }

        // Process pending resize (coalesced, like Ghostty)
        // We wait for RESIZE_COALESCE_MS after last resize event before applying.
        // Only update the root grid dimensions here — actual terminal + PTY resize
        // is handled by computeSplitLayout → setScreenSize in the render loop below.
        if (consumePendingGridResize(std.time.milliTimestamp())) |grid| {
            term_cols = grid.cols;
            term_rows = grid.rows;
        }

        // PTY reading is handled by per-surface IO threads (termio.Thread).
        // We just need to render. The IO threads set surface.dirty when
        // new data arrives.

        // Get framebuffer size and render
        const win = g_window orelse break;

        // Poll platform messages, filling event queues and close state.
        running = window_backend.pollEvents(win) and !g_should_close;
        if (self.consumeForceCloseRequest()) {
            window_backend.clearCloseRequested(win);
            g_should_close = true;
            running = false;
            continue;
        }
        if (window_backend.closeRequested(win)) {
            window_backend.clearCloseRequested(win);
            const running_program = anyTabHasRunningProgram();
            const confirm_for_program = close_confirm.shouldConfirm(g_confirm_close_running_program, running_program);
            const want_confirm = window_backend.closeRequestPromptsConfirmation() or confirm_for_program;
            if (!want_confirm) {
                // Backend tears the window down immediately with no in-app
                // prompt; closing this window does not necessarily end the app
                // session (the backend owns process lifecycle).
                g_should_close = true;
                running = false;
                continue;
            }
            const variant: overlays.CloseConfirmVariant = if (confirm_for_program) .running_program else .window_generic;
            overlays.closeConfirmOpen(.window, variant);
            g_force_rebuild = true;
            g_cells_valid = false;
        }

        if (window_backend.consumeDpiChanged(win)) {
            render_diagnostics.log("main-loop consume-dpi-changed dpi={} font_dpi={}", .{ window_backend.effectiveDpi(win), font.g_dpi });
            handleWindowDpiChanged(allocator, win, ft_lib, requested_font, requested_weight);
        }

        // Sync tab count to the window backend for hit-testing
        window_backend.setTabCount(win, tab.g_tab_count);
        window_backend.setSidebarWidth(win, @intFromFloat(titlebar.sidebarWidth()));

        // Process all queued input events (keyboard, mouse, resize)
        input.processEvents(win);

        // Track the last windowed position so a maximized/fullscreen close still
        // persists where the window was, not (0,0).
        rememberWindowedPosition(win);
        // Fire any due /loop or /watch tasks (UI thread: tab.g_tabs is populated).
        ai_loop_store.tick(std.time.milliTimestamp());
        // Open any tabs requested via `wisptermctl spawn` (queued by the ctl
        // server thread, created here on the UI thread).
        control_api.drainSpawnQueue();

        // Handle bells, notifications, and OSC 52 clipboard writes staged by
        // the IO threads. This runs before the render gate: background-tab
        // output no longer triggers frames, so these must not depend on one.
        for (0..tab.g_tab_count) |ti| {
            if (tab.g_tabs[ti]) |tb| {
                var it = tb.tree.surfaces();
                while (it.next()) |entry| {
                    if (entry.surface.bell_pending.swap(false, .acquire)) {
                        handleBell(entry.surface, win, ti == active_tab_state.g_active_tab);
                    }
                    {
                        const is_active_surface = (ti == active_tab_state.g_active_tab) and
                            (if (tb.focusedSurface()) |fs| fs == entry.surface else false);
                        handleNotification(entry.surface, is_active_surface);
                    }
                    if (entry.surface.takeClipboardWrite()) |text| {
                        _ = input.copyTextToClipboard(text);
                        entry.surface.allocator.free(text);
                    }
                }
            }
        }

        // Update focus state
        const focused = window_backend.isFocused(win);
        if (window_focused != focused) g_force_rebuild = true;
        window_focused = focused;

        const fb = window_backend.framebufferSize(win);
        const fb_width: c_int = fb.width;
        const fb_height: c_int = fb.height;
        if (window_backend.isMinimized(win) or fb_width <= 0 or fb_height <= 0) {
            agent_requests.failPendingUiScreenshots(error.WindowUnavailable);
            const timeout_ms = render_gate.computeBlockTimeoutMs(.{
                .visibility = .hidden,
                .cursor_blink_enabled = false,
                .ms_until_next_blink = CURSOR_BLINK_INTERVAL_MS,
            });
            window_backend.pumpAppEvents(@as(f64, @floatFromInt(timeout_ms)) / 1000.0);
            continue;
        }
        syncBackendSurfaceSize(fb_width, fb_height);

        const gate_now = std.time.milliTimestamp();
        const visible = window_backend.isVisible(win);
        const vis: render_gate.Visibility = if (!visible)
            .hidden
        else if (window_focused)
            .focused
        else
            .unfocused_visible;

        const blink = frame_scheduler.decideBlink(.{
            .cursor_blink_enabled = g_cursor_blink,
            .focused = vis == .focused,
            .now_ms = gate_now,
            .last_blink_render_ms = g_gate_last_blink_render,
            .interval_ms = CURSOR_BLINK_INTERVAL_MS,
        });

        const signals = render_gate.RenderSignals{
            .force_rebuild = g_force_rebuild or !g_cells_valid or pendingResizeActive() or windowState().layout_resize_immediate or agent_requests.hasPendingUiScreenshot(),
            .any_surface_dirty = anyVisibleSurfaceDirty(),
            .cursor_blink_due = blink.due,
            .ai_streaming = aiStreamingActive(),
            .overlay_active = overlays.anyOverlayActive(gate_now),
            .atlas_sync_pending = font.atlasSyncPending(),
        };

        const needs_render = render_gate.frameNeedsRender(signals);
        if (!needs_render) {
            const timeout_ms = render_gate.computeBlockTimeoutMs(.{
                .visibility = vis,
                .cursor_blink_enabled = blink.enabled,
                .ms_until_next_blink = blink.ms_until_next,
            });
            window_backend.pumpAppEvents(@as(f64, @floatFromInt(timeout_ms)) / 1000.0);
            continue;
        }
        if (blink.due) g_gate_last_blink_render = gate_now;

        // In-app GPU benchmark: capture the render-branch start timestamp. The
        // matching frameEnd (after present + dirty-clear) records the sample and
        // feeds the next VT chunk; see driver.zig for the measurement model.
        if (bench_driver.isEnabled()) bench_driver.frameBegin();

        // A pending ui_screenshot is captured from this frame's framebuffer right
        // after endFrame. The Metal backend can't read a presented+released
        // drawable, so arm an in-frame capture before we render+endFrame. No-op
        // on OpenGL (it reads the live back buffer post-endFrame).
        if (agent_requests.hasPendingUiScreenshot()) gpu.state.armUiScreenshotCapture();

        gpu.draw_call_count = 0;
        overlays.updateFps();

        // Sync atlas textures to GPU if modified
        if (font.g_atlas != null) font.syncAtlasTexture(&font.g_atlas, &font.g_atlas_texture, &font.g_atlas_modified);
        if (font.g_color_atlas != null) font.syncAtlasTexture(&font.g_color_atlas, &font.g_color_atlas_texture, &font.g_color_atlas_modified);
        if (font.g_icon_atlas != null) font.syncAtlasTexture(&font.g_icon_atlas, &font.g_icon_atlas_texture, &font.g_icon_atlas_modified);
        if (font.g_titlebar_atlas != null) font.syncAtlasTexture(&font.g_titlebar_atlas, &font.g_titlebar_atlas_texture, &font.g_titlebar_atlas_modified);

        // Render padding constants - used for content area and titlebar positioning
        const padding: f32 = 10;
        const titlebar_offset = syncWindowTitlebarHeight(win);
        const left_panels_w = leftPanelsWidth();
        const right_panels_w = rightPanelsWidthForWindow(fb_width);
        const top_padding: f32 = padding + titlebar_offset;
        logFrameGeometryIfChanged(win, fb_width, fb_height, titlebar_offset);
        {
            const perf = ui_perf.begin("appwindow.browser_panel_sync");
            defer perf.end();
            browser_panel.sync(window_backend.nativeHandle(win), fb_width, fb_height, titlebar_offset, left_panels_w, browserPanelRightOffset(), overlays.anyBlockingOverlayVisible());
        }

        if (activeTab()) |active_tab| {
            // Compute split layout for the active tab
            const content_x: i32 = @intFromFloat(left_panels_w + padding);
            const content_y: i32 = @intFromFloat(top_padding);
            const content_w: i32 = @intFromFloat(@as(f32, @floatFromInt(fb_width)) - left_panels_w - right_panels_w - padding * 2);
            const content_h: i32 = @intFromFloat(@as(f32, @floatFromInt(fb_height)) - top_padding - padding);
            const split_count = computeSplitLayout(active_tab, content_x, content_y, content_w, content_h, font.cell_width, font.cell_height);
            remote_sync.syncLayout(remoteSyncHost(), allocator);
            control_api.syncPanes(allocator);
            control_api.syncUiState(allocator);
            syncImeCaretPosition(win, split_count);
            if (active_tab.kind != .ai_chat and active_tab.kind != .ai_history and active_tab.kind != .memory_center and active_tab.kind != .skill_center and active_tab.kind != .port_forwarding and synchronizedOutputPendingForVisibleSplits(split_count)) {
                // Block instead of spinning at ~1kHz: the IO thread posts a
                // wakeup when the application ends synchronized output (or new
                // output arrives), and the timeout bounds the watchdog check.
                window_backend.pumpAppEvents(@as(f64, @floatFromInt(render_gate.MIN_TIMEOUT_MS)) / 1000.0);
                continue;
            }

            // Debug: print split count on first few frames
            // GL rendering
            if (active_tab.kind == .ai_chat) {
                renderAiChatFrame(fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (active_tab.kind == .ai_history) {
                renderAiHistoryFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (active_tab.kind == .memory_center) {
                renderMemoryCenterFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (active_tab.kind == .skill_center) {
                renderSkillCenterFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (active_tab.kind == .port_forwarding) {
                renderPortForwardingFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (post_process.g_post_enabled and activeSurface() != null) {
                // Post-processing path: only render focused surface for now.
                // (With no focused terminal — e.g. a preview pane focused — fall
                // through to the generic split path so the frame still paints.)
                if (activeSurface()) |surface| {
                    var needs_rebuild: bool = false;
                    const rend = &surface.surface_renderer;
                    {
                        surface.render_state.mutex.lock();
                        defer surface.render_state.mutex.unlock();
                        updateCursorBlinkForRenderer(rend);
                        cell_renderer.g_current_render_surface = surface;
                        rend.is_focused = true; // Single surface is always focused
                        needs_rebuild = cell_renderer.updateTerminalCells(rend, &surface.terminal);
                    }
                    if (needs_rebuild) cell_renderer.rebuildCells(rend);
                    post_process.renderFrameWithPostFromCells(rend, fb_width, fb_height, padding);
                }
            } else if (split_layout.soleTerminalSurface()) |surface| {
                // Single terminal pane (no splits): original simple rendering
                // path. A lone PREVIEW pane has no terminal surface and must take
                // the generic split path below so it still paints.
                // The surface padding is set by computeSplitLayout, so we use it here
                {
                    const rend = &surface.surface_renderer;
                    var needs_rebuild: bool = false;
                    {
                        surface.render_state.mutex.lock();
                        defer surface.render_state.mutex.unlock();
                        updateCursorBlinkForRenderer(rend);
                        cell_renderer.g_current_render_surface = surface;
                        rend.is_focused = true; // Single surface is always focused
                        needs_rebuild = cell_renderer.updateTerminalCells(rend, &surface.terminal);
                    }
                    if (needs_rebuild) cell_renderer.rebuildCells(rend);

                    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
                    ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                    clearWithBackground(fb_width, fb_height);

                    // Use surface's computed padding (includes titlebar offset from content_y)
                    const pad = surface.getPadding();
                    const pad_top = @as(f32, @floatFromInt(pad.top)) + titlebar_offset;
                    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                    cell_renderer.drawCells(rend, @floatFromInt(fb_height), left_panels_w + @as(f32, @floatFromInt(pad.left)), pad_top);
                    overlays.renderScrollbar(@floatFromInt(fb_width), @floatFromInt(fb_height), pad_top);

                    // Render resize overlay centered in content area (offset for titlebar)
                    overlays.renderResizeOverlayWithOffset(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                }
            } else {
                // Multiple splits: render with scissor/viewport per surface
                gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
                ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                clearWithBackground(fb_width, fb_height);

                titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);

                // Render each split surface directly to screen using viewport
                if (split_count > 0) {
                    for (0..split_count) |i| {
                        const rect = split_layout.g_split_rects[i];
                        const is_focused = (rect.handle == active_tab.focused);

                        switch (rect.pane) {
                            .terminal => |surface| {
                                const rend = &surface.surface_renderer;

                                // Set viewport to this split's region
                                // OpenGL viewport: (x, y, width, height) where y is from bottom
                                const viewport_y = fb_height - rect.y - rect.height;
                                gpu.state.setViewport(rect.x, viewport_y, rect.width, rect.height);

                                // Set projection for this viewport size
                                ui_pipeline.setProjection(@floatFromInt(rect.width), @floatFromInt(rect.height));

                                // Update cells for this surface
                                var needs_rebuild: bool = false;
                                {
                                    surface.render_state.mutex.lock();
                                    defer surface.render_state.mutex.unlock();
                                    if (is_focused) updateCursorBlinkForRenderer(rend);
                                    // One-shot global invalidations (window focus,
                                    // theme or layout events that set
                                    // g_force_rebuild) must reach every pane.
                                    // Otherwise the per-renderer dirty check
                                    // decides, so panes whose content did not
                                    // change skip the full snapshot+rebuild —
                                    // with one pane streaming output, the others
                                    // no longer pay a per-frame full-grid rebuild.
                                    if (g_force_rebuild or !g_cells_valid) rend.force_rebuild = true;
                                    cell_renderer.g_current_render_surface = surface;
                                    needs_rebuild = cell_renderer.updateTerminalCellsForSurface(rend, &surface.terminal, is_focused);
                                }
                                if (needs_rebuild) cell_renderer.rebuildCells(rend);

                                // Draw cells using the surface's computed padding
                                const pad = surface.getPadding();
                                cell_renderer.drawCells(rend, @floatFromInt(rect.height), @floatFromInt(pad.left), @floatFromInt(pad.top));

                                // Render scrollbar for this surface within its viewport
                                overlays.renderScrollbarForSurface(surface, @floatFromInt(rect.width), @floatFromInt(rect.height), @floatFromInt(pad.top));

                                // Alt-drag panel swap feedback: highlight the drop target,
                                // dim the grabbed source. Otherwise dim any unfocused panel.
                                const is_swap_target = input.g_panel_swap_active and
                                    input.g_panel_swap_target != null and
                                    rect.handle == input.g_panel_swap_target.?;
                                const is_swap_source = input.g_panel_swap_active and
                                    input.g_panel_swap_source != null and
                                    rect.handle == input.g_panel_swap_source.?;
                                if (is_swap_target) {
                                    overlays.renderSwapTargetHighlight(@floatFromInt(rect.width), @floatFromInt(rect.height));
                                } else if (is_swap_source or !is_focused) {
                                    overlays.renderUnfocusedOverlaySimple(@floatFromInt(rect.width), @floatFromInt(rect.height));
                                }

                                // Render resize overlay:
                                // - During divider dragging or timed overlay (equalize): show on ALL splits
                                // - Otherwise: show only on focused split (for window resize)
                                const show_timed_overlay = std.time.milliTimestamp() < overlays.resize.g_split_resize_overlay_until;
                                if (input.g_divider_dragging or show_timed_overlay) {
                                    overlays.renderResizeOverlayForSurface(surface, @floatFromInt(rect.width), @floatFromInt(rect.height));
                                } else if (is_focused) {
                                    overlays.renderResizeOverlay(@floatFromInt(rect.width), @floatFromInt(rect.height));
                                }
                            },
                            .preview => |p| {
                                // The preview renderer paints in window-absolute coords,
                                // so restore the full-window viewport/projection first.
                                gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
                                ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                                const close_hovered = if (input.g_preview_close_hover) |h| h == rect.handle else false;
                                markdown_preview_renderer.renderInto(
                                    p,
                                    @floatFromInt(rect.x),
                                    @floatFromInt(rect.y),
                                    @floatFromInt(rect.width),
                                    @floatFromInt(rect.height),
                                    @floatFromInt(fb_height),
                                    close_hovered,
                                );
                                if (is_focused) drawPaneFocusRing(rect, @floatFromInt(fb_height));

                                // Alt-drag panel swap feedback for preview leaves,
                                // mirroring the terminal branch. The highlight
                                // overlays draw in panel-local coords, so switch to
                                // this rect's viewport/projection first, then restore
                                // the full-window viewport for the next leaf.
                                const is_swap_target = input.g_panel_swap_active and
                                    input.g_panel_swap_target != null and
                                    rect.handle == input.g_panel_swap_target.?;
                                const is_swap_source = input.g_panel_swap_active and
                                    input.g_panel_swap_source != null and
                                    rect.handle == input.g_panel_swap_source.?;
                                if (is_swap_target or is_swap_source) {
                                    const vp_y = fb_height - rect.y - rect.height;
                                    gpu.state.setViewport(rect.x, vp_y, rect.width, rect.height);
                                    ui_pipeline.setProjection(@floatFromInt(rect.width), @floatFromInt(rect.height));
                                    if (is_swap_target) {
                                        overlays.renderSwapTargetHighlight(@floatFromInt(rect.width), @floatFromInt(rect.height));
                                    } else {
                                        overlays.renderUnfocusedOverlaySimple(@floatFromInt(rect.width), @floatFromInt(rect.height));
                                    }
                                    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
                                    ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                                }
                            },
                        }
                    }

                    // Restore full viewport for dividers
                    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
                    ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));

                    // Draw split dividers and per-pane agent dots
                    overlays.renderSplitDividers(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
                    overlays.renderPaneAgentDots(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
                }
            }
        } else if (!post_process.g_post_enabled) {
            gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
            ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
            clearWithBackground(fb_width, fb_height);
            titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        }

        gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
        ui_pipeline.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
        // Copilot panel draws on top of the reserved right region (terminal tabs
        // only; renderAiCopilotPanel gates on aiCopilotVisible). Placed after the
        // full-window viewport/projection are restored — so it is unaffected by the
        // per-split viewport and the post-process framebuffer paths above — and
        // after terminal content, occupying the exclusive right slot.
        renderAiCopilotPanel(fb_width, fb_height, titlebar_offset);
        overlays.renderBrowserUrlBar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        if (copilot_hint_gate.handleEligible(g_copilot_hint, aiCopilotVisible(), isActiveTabTerminal(), anyRightDockPanelVisible())) {
            if (!g_copilot_shimmer_checked) {
                g_copilot_shimmer_checked = true;
                const hint_shown = if (g_allocator) |alloc| platform_window_state.copilotHintShown(alloc) else true;
                if (copilot_hint_gate.shimmerDecision(true, true, hint_shown) == .shimmer) {
                    overlays.copilotEdgeHandleStartShimmer();
                    if (g_allocator) |alloc| platform_window_state.setCopilotHintShown(alloc);
                }
            }
            overlays.renderCopilotEdgeHandle(
                @floatFromInt(fb_width),
                @floatFromInt(fb_height),
                titlebar_offset,
                leftPanelsWidth(),
            );
        }
        overlays.renderStartupShortcutsOverlay(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderCommandPalette(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderJupyterPicker(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderCopilotPicker(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderSettingsPage(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderSessionLauncher(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderMcpServers(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        weixin_qr_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        feishu_reg_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderDebugOverlay(@floatFromInt(fb_width));
        overlays.renderCloseShortcutConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderCopyToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderTransferToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderTransferCancelConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderUpdatePrompt(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderWindowCloseConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderRestoreDefaultsConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderIntegrationPrompt(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderWhatsNew(@floatFromInt(fb_width), @floatFromInt(fb_height));
        renderImePreedit(win, fb_width, fb_height);

        d3d11_offscreen_smoke.render(fb_width, fb_height);
        d3d11_ui_smoke.render(fb_width, fb_height);
        d3d11_recreate_smoke.maybeRequest();
        logSwapDiagnosticsIfChanged(win, fb_width, fb_height);
        forceOpaqueBackbufferForPresent();
        gpu.state.endFrame();
        agent_requests.capturePendingUiScreenshots(agentRequestHost());
        presentBackendFrame(win);
        handleD3D11RecoveryRequest(allocator, fb_width, fb_height);
        if (windowState().takePresentBringupSettlement()) {
            platform_window_state.settleD3dBringup(allocator);
        }
        recordFrameLatencyIfInputDriven();
        clearVisibleSurfaceDirty();
        g_force_rebuild = false;
        g_cells_valid = true;
        if (bench_driver.isEnabled()) {
            // Records this frame's pipeline sample, feeds the next VT chunk for
            // the upcoming frame, and advances the scenario schedule. On the
            // final frame of the last scenario, write the report and exit.
            bench_driver.frameEnd() catch |err| {
                std.debug.print("wispterm-benchmark: driver error: {}, aborting\n", .{err});
                g_should_close = true;
            };
            if (bench_driver.finished()) {
                finishBenchReport(win);
                g_should_close = true;
            }
        }
        if (window_backend.takePresentFallbackEvent(win)) {
            // The DXGI present path was just latched off mid-session. While
            // it was broken the GPU may have dropped glyph-atlas uploads
            // (device reset / stalled context), leaving every glyph first
            // seen during that window permanently blank — rebuild the atlas
            // and re-render everything on the GDI path.
            font.clearGlyphCache(allocator);
            g_force_rebuild = true;
            g_cells_valid = false;
            // The in-session GDI switch is best-effort only: this HWND has
            // already flip-presented, and blt presents on such a window are
            // undefined (often blank). Persist the marker so the next launch
            // of this version runs GDI from frame 0, which always works.
            platform_window_state.blockD3dBringup(allocator, build_options.app_version);
        }
        if (window_backend.takePresentDegradedEvent(win)) {
            // Watchdog: presents are sustained-slow but frames do reach the
            // screen, so the session keeps the flip path (switching would
            // blank the window). Next launch goes straight to GDI instead.
            platform_window_state.blockD3dBringup(allocator, build_options.app_version);
        }
    }

    agent_requests.failPendingUiScreenshots(error.WindowUnavailable);

    // Save window position + size for next session
    if (g_window) |w| {
        if (g_quake_mode) {
            // Persist the drop-down outer frame so it reopens where the user left
            // it. rememberQuakeFrame refreshes g_quake_frame from the live window
            // (skipping degenerate / off-work-area frames); persist whatever it
            // leaves, falling back to a frame captured on the last hide.
            rememberQuakeFrame(w);
            if (g_quake_frame) |f| {
                saveQuakeFrame(allocator, f.x, f.y, f.width, f.height);
            }
        } else if (window_backend.windowRect(w)) |rect| {
            const is_maximized = window_backend.isMaximized(w);
            if (!is_maximized and !window_backend.isFullscreen(w)) {
                const fb = window_backend.framebufferSize(w);
                saveWindowGeometry(allocator, rect.left, rect.top, fb.width, fb.height);
            } else {
                // Save the last known windowed position; preserve the remembered
                // windowed size (null leaves the saved width/height untouched).
                saveWindowGeometry(allocator, platform_window_state.g_windowed_x, platform_window_state.g_windowed_y, null, null);
            }
        }
    }

    // Stop accepting cross-thread WeChat control calls before UI-owned globals
    // and renderer resources start tearing down. The App-level controller is
    // stopped shortly after this window loop returns.
    weixin_bridge.setUiHandle(0);
    render_diagnostics.log("shutdown window-loop-ended", .{});
    render_diagnostics.close();

    // Clean up file explorer async state (join background thread, free job)
    file_explorer.deinit();
    memory_digest_scheduler.deinit();
    weixin_qr_renderer.deinit();
    weixin_qr_panel.deinit();
    feishu_reg_renderer.deinit();
    feishu_reg_panel.deinit();
    feishu_registration.shutdown();
    clearWeixinTranscriptCache();
    control_api.clearPanesCache();
    control_api.clearUiStateCache();
    control_api.clearSpawnQueue();
    markdown_preview_renderer.deinit();
    browser_panel.deinit();

    // Tab cleanup is handled by AppWindow.deinit()
}

test "appwindow: setRequestedFont keeps a private copy of the family string" {
    // Regression: g_requested_font aliased App.font_family, which App frees and
    // reallocates on every config reload (App.replaceStr). The captured family
    // is read later in the event loop (handleWindowDpiChanged), so it must not
    // point into freed memory. The setter copies into its own buffer.
    defer {
        @memset(&g_requested_font_buf, 0);
        g_requested_font = "";
    }
    var src: [16]u8 = undefined;
    @memcpy(src[0..11], "JetBrains M");
    setRequestedFont(src[0..11]);
    @memset(&src, 'x'); // clobber the source the way replaceStr would
    try std.testing.expectEqualStrings("JetBrains M", g_requested_font);

    const long = "z" ** 1000;
    setRequestedFont(long);
    try std.testing.expect(g_requested_font.len < long.len);
}

test "appwindow: syncDefaultShellCommandFromConfig refreshes tab default shell" {
    const testing = std.testing;
    const test_shell = platform_pty_command.configReloadTestNextShell();

    defer {
        @memset(&tab.g_shell_cmd_buf, 0);
        tab.g_shell_cmd_len = 0;
    }

    syncDefaultShellCommandFromConfig(test_shell);

    var expected_buf: platform_pty_command.CommandLineBuffer = undefined;
    const expected_len = platform_pty_command.resolveShellCommandLine(&expected_buf, test_shell);
    const CommandUnit = @TypeOf(expected_buf[0]);
    try testing.expectEqualSlices(CommandUnit, expected_buf[0..expected_len], tab.getShellCmd());
}

test "appwindow: configured local shell session labels reflect shell config" {
    defer {
        @memset(&tab.g_shell_cmd_buf, 0);
        tab.g_shell_cmd_len = 0;
    }

    syncDefaultShellCommandFromConfig("cmd");

    switch (platform_pty_command.backend()) {
        .windows => {
            try std.testing.expectEqualStrings("Command Prompt", configuredLocalShellSessionTitle());
            try std.testing.expectEqualStrings("cmd.exe", configuredLocalShellSessionDetail());
        },
        .unsupported => {
            try std.testing.expectEqualStrings("cmd", configuredLocalShellSessionTitle());
            try std.testing.expectEqualStrings("cmd", configuredLocalShellSessionDetail());
        },
    }
}

test "appwindow: render gate ignores background-tab surface dirty" {
    const allocator = std.testing.allocator;
    for (0..tab.MAX_TABS) |idx| tab.g_tabs[idx] = null;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    defer {
        for (0..tab.MAX_TABS) |idx| tab.g_tabs[idx] = null;
        tab.g_tab_count = 0;
        active_tab_state.g_active_tab = 0;
    }

    // Stack surfaces: the tree refs/unrefs them, so seed ref_count at 1 to
    // keep unref from ever reaching 0 (which would run the full deinit).
    var active_surface: Surface = undefined;
    active_surface.ref_count = 1;
    active_surface.dirty = std.atomic.Value(bool).init(false);
    var background_surface: Surface = undefined;
    background_surface.ref_count = 1;
    background_surface.dirty = std.atomic.Value(bool).init(true);

    var active_tab_v = tab.TabState{ .tree = try SplitTree.init(allocator, &active_surface) };
    defer active_tab_v.tree.deinit();
    var background_tab_v = tab.TabState{ .tree = try SplitTree.init(allocator, &background_surface) };
    defer background_tab_v.tree.deinit();

    tab.g_tabs[0] = &active_tab_v;
    tab.g_tabs[1] = &background_tab_v;
    tab.g_tab_count = 2;
    active_tab_state.g_active_tab = 0;

    // Background output alone must not trigger frames.
    try std.testing.expect(!anyVisibleSurfaceDirty());

    // Active-tab output does.
    active_surface.dirty.store(true, .release);
    try std.testing.expect(anyVisibleSurfaceDirty());

    // Frame-end clear consumes only the rendered (active) tab; the background
    // tab's dirty flag stays latched for its eventual tab switch.
    clearVisibleSurfaceDirty();
    try std.testing.expect(!active_surface.dirty.load(.acquire));
    try std.testing.expect(background_surface.dirty.load(.acquire));
}

test "appwindow: ui screenshot focused_panel uses focused non-terminal split rect" {
    const allocator = std.testing.allocator;
    const saved_active = active_tab_state.g_active_tab;
    const saved_tab_count = tab.g_tab_count;
    const saved_tab0 = tab.g_tabs[0];
    const saved_split_rect_count = split_layout.g_split_rect_count;
    const saved_split_rect0: split_layout.SplitRect = if (saved_split_rect_count > 0) split_layout.g_split_rects[0] else undefined;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    var active_tab_v = tab.TabState{ .tree = try SplitTree.init(allocator, &surface) };
    defer active_tab_v.tree.deinit();

    tab.g_tabs[0] = &active_tab_v;
    tab.g_tab_count = 1;
    active_tab_state.g_active_tab = 0;
    split_layout.g_split_rect_count = 0;
    defer {
        if (saved_split_rect_count > 0) split_layout.g_split_rects[0] = saved_split_rect0;
        split_layout.g_split_rect_count = saved_split_rect_count;
        tab.g_tabs[0] = saved_tab0;
        tab.g_tab_count = saved_tab_count;
        active_tab_state.g_active_tab = saved_active;
    }

    const preview = tab.splitIntoPreview(allocator) orelse return error.SplitIntoPreviewFailed;
    try std.testing.expect(tab.focusPreviewPane(preview));
    const focused_pane = switch (active_tab_v.tree.nodes[active_tab_v.focused.idx()]) {
        .leaf => |pane| pane,
        .split => return error.FocusedIsSplit,
    };

    split_layout.g_split_rects[0] = .{
        .x = 11,
        .y = 22,
        .width = 33,
        .height = 44,
        .cols = 0,
        .rows = 0,
        .pane = focused_pane,
        .handle = active_tab_v.focused,
    };
    split_layout.g_split_rect_count = 1;

    const capture = try resolveAgentUiScreenshotCapture(.focused_panel, null, 100, 100);
    try std.testing.expectEqual(ai_chat_types.UiScreenshotTarget.focused_panel, capture.target);
    try std.testing.expectEqual(appwindow_ui_screenshot.Rect{ .x = 11, .y = 22, .width = 33, .height = 44 }, capture.rect);
}

test "appwindow: ui screenshot explicit surface id errors on non-terminal active tab" {
    const saved_active = active_tab_state.g_active_tab;
    const saved_tab_count = tab.g_tab_count;
    const saved_tab0 = tab.g_tabs[0];

    var active_tab_v = tab.TabState{ .kind = .ai_chat, .tree = .empty };
    tab.g_tabs[0] = &active_tab_v;
    tab.g_tab_count = 1;
    active_tab_state.g_active_tab = 0;
    defer {
        tab.g_tabs[0] = saved_tab0;
        tab.g_tab_count = saved_tab_count;
        active_tab_state.g_active_tab = saved_active;
    }

    try std.testing.expectError(
        error.SurfaceNotInActiveTab,
        resolveAgentUiScreenshotCapture(.focused_panel, "surface-123", 100, 100),
    );
    try std.testing.expectError(
        error.SurfaceNotInActiveTab,
        resolveAgentUiScreenshotCapture(.active_tab, "surface-123", 100, 100),
    );
}

test "appwindow: agent terminal focus activates the owning tab and split" {
    const allocator = std.testing.allocator;
    const id_a = "00000000000000a1";
    const id_b = "00000000000000b2";
    const id_c = "00000000000000c3";

    var surface_a: Surface = undefined;
    surface_a.ref_count = 1;
    @memcpy(surface_a.remote_id[0..], id_a);
    var surface_b: Surface = undefined;
    surface_b.ref_count = 1;
    @memcpy(surface_b.remote_id[0..], id_b);
    var surface_c: Surface = undefined;
    surface_c.ref_count = 1;
    @memcpy(surface_c.remote_id[0..], id_c);

    var tab0_v = tab.TabState{ .tree = try SplitTree.init(allocator, &surface_a) };
    defer tab0_v.tree.deinit();

    var left = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var right = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var root = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &left, .right = &right } };
    const Stub = struct {
        var idx: usize = 0;
        var surfaces: [2]*Surface = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: std.mem.Allocator) ?*Surface {
            const surface = surfaces[idx];
            idx += 1;
            return surface;
        }
    };
    Stub.idx = 0;
    Stub.surfaces = .{ &surface_b, &surface_c };
    var tab1_v = tab.TabState{
        .tree = try SplitTree.fromSnapshot(allocator, &root, Stub.make),
        .focused = @enumFromInt(1),
    };
    defer tab1_v.tree.arena.deinit();

    const saved_active = active_tab_state.g_active_tab;
    const saved_tab_count = tab.g_tab_count;
    const saved_tab0 = tab.g_tabs[0];
    const saved_tab1 = tab.g_tabs[1];
    defer {
        tab.g_tabs[0] = saved_tab0;
        tab.g_tabs[1] = saved_tab1;
        tab.g_tab_count = saved_tab_count;
        active_tab_state.g_active_tab = saved_active;
    }

    tab.g_tabs[0] = &tab0_v;
    tab.g_tabs[1] = &tab1_v;
    tab.g_tab_count = 2;
    active_tab_state.g_active_tab = 0;

    const target = focusAgentTerminalSurfaceById(id_c) orelse return error.FocusTargetMissing;
    try std.testing.expect(target.surface == &surface_c);
    try std.testing.expectEqual(@as(usize, 1), target.tab_index);
    try std.testing.expectEqual(@as(usize, 1), active_tab_state.g_active_tab);
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 2), @intFromEnum(tab1_v.focused));
}

test "appwindow: ui screenshot base dir falls back to exports dir" {
    const allocator = std.testing.allocator;
    platform_dirs.setTestConfigDirForCurrentThread("/tmp/wispterm-test-config");
    defer platform_dirs.clearTestConfigDirForCurrentThread();

    const fallback = try agentUiScreenshotBaseDir(allocator, null);
    defer allocator.free(fallback);
    const expected = try std.fs.path.join(allocator, &.{ "/tmp/wispterm-test-config", "exports" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, fallback);

    const explicit = try agentUiScreenshotBaseDir(allocator, "/work/project");
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("/work/project", explicit);
}

test "appwindow: ui screenshot reports unavailable window before missing working dir" {
    const saved_window = g_window;
    g_window = null;
    defer g_window = saved_window;

    try std.testing.expectError(
        error.WindowUnavailable,
        agentRequestCaptureUiScreenshot(std.testing.allocator, .active_tab, null, null),
    );
}

test "appwindow: ai history content width accounts for right panels" {
    try std.testing.expectEqual(@as(f32, 700), aiHistoryContentWidth(1000, 200, 100));
    try std.testing.expectEqual(@as(f32, 0), aiHistoryContentWidth(250, 200, 100));
}

test "appwindow: localExplorerLiveCwd resolves the surface live cwd" {
    var surface: Surface = undefined;
    const live = "/Users/test/live";
    @memcpy(surface.cwd_path[0..live.len], live);
    surface.cwd_path_len = live.len;

    const got = localExplorerLiveCwd(&surface, std.testing.allocator) orelse return error.NullCwd;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(live, got);
}
