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
const PreviewPane = @import("preview_pane.zig");
const renderer = @import("renderer.zig");
const window_backend = @import("platform/window_backend.zig");
const App = @import("App.zig");
const Renderer = @import("renderer/Renderer.zig");
const remote = @import("remote_client.zig");
const remote_snapshot = @import("remote_snapshot.zig");
const weixin_control = @import("weixin/control.zig");
const weixin_types = @import("weixin/types.zig");
const ctl_control = @import("ctl/control.zig");
const memory_debug = @import("memory_debug.zig");
const surface_registry = @import("surface_registry.zig");
const agent_detector = @import("agent_detector.zig");
const agent_history = @import("agent_history.zig");
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
const copilot_hint_gate = @import("copilot_hint_gate.zig");
const platform_window_state = @import("platform/window_state.zig");
const platform_wsl = @import("platform/wsl.zig");
const startup_tabs = @import("startup_tabs.zig");
const session_persist = @import("session_persist.zig");
const quick_terminal = @import("quick_terminal.zig");
const keybind = @import("keybind.zig");
const thread_message = @import("appwindow/thread_message.zig");
const render_diagnostics = @import("render_diagnostics.zig");
const ime_caret = @import("ime_caret.zig");
const hit_test = @import("input/hit_test.zig");
pub const ai_chat = @import("ai_chat.zig");
const ai_history_cache = @import("ai_history_cache.zig");
const ai_history_resume = @import("ai_history_resume.zig");
const ai_loop_store = @import("ai_loop_store.zig");
const ai_history_types = @import("ai_history_types.zig");
pub const ai_history_session = @import("ai_history_session.zig");
pub const ai_history_source = @import("ai_history_source.zig");
pub const skill_center = @import("skill_center.zig");
const skill_install = @import("skill_install.zig");
const update_install = @import("update_install.zig");
const clipboard = @import("input/clipboard.zig");
pub const port_forwarding = @import("port_forwarding.zig");
const port_forward_manager = @import("port_forward_manager.zig");
const port_forward_rule = @import("port_forward_rule.zig");
const ssh_profile_store = @import("ssh_profile_store.zig");
const skill_scan = @import("skill_scan.zig");
const skill_local_fs = @import("skill_local_fs.zig");
const skill_transfer_cmd = @import("skill_transfer_cmd.zig");
const tool_import = @import("tool_import.zig");
const tool_registry = @import("tool_registry.zig");
const tool_skill_draft = @import("tool_skill_draft.zig");
const ai_chat_request = @import("ai_chat_request.zig");
const remote_file = @import("platform/remote_file.zig");
const ssh_connection = @import("ssh_connection.zig");
const skill_transfer = @import("skill_transfer.zig");
const skill_diff = @import("skill_diff.zig");
const scp = @import("scp.zig");
const ssh_error = @import("ssh_error.zig");
const i18n = @import("i18n.zig");
pub const tab = @import("appwindow/tab.zig");
const active_tab_state = @import("appwindow/active_tab.zig");
const tmux_controller = @import("appwindow/tmux_controller.zig");
pub const font = @import("font/manager.zig");
pub const cell_renderer = @import("renderer/cell_renderer.zig");
pub const cell_pipeline = @import("renderer/cell_pipeline.zig");
pub const ui_pipeline = @import("renderer/ui_pipeline.zig");
pub const titlebar = @import("renderer/titlebar.zig");
pub const input = @import("input.zig");
pub const overlays = @import("renderer/overlays.zig");
pub const post_process = @import("renderer/post_process.zig");
pub const gpu = @import("renderer/gpu/gpu.zig");
pub const split_layout = @import("appwindow/split_layout.zig");
const render_gate = @import("appwindow/render_gate.zig");
const frame_latency = @import("appwindow/frame_latency.zig");
const flush_scheduler = @import("appwindow/flush_scheduler.zig");
const resize_throttle = @import("appwindow/resize_throttle.zig");
pub const fbo = @import("renderer/fbo.zig");
pub const background_image = @import("renderer/background_image.zig");
pub const file_explorer = @import("file_explorer.zig");
pub const file_explorer_renderer = @import("renderer/file_explorer_renderer.zig");
pub const markdown_preview_panel = @import("markdown_preview_panel.zig");
pub const markdown_preview_renderer = @import("renderer/markdown_preview_renderer.zig");
pub const weixin_qr_panel = @import("weixin/qr_panel.zig");
pub const weixin_qr_renderer = @import("renderer/weixin_qr_renderer.zig");
const html_server = @import("html_server.zig");
pub const browser_panel = if (build_options.webview)
    @import("browser_panel.zig")
else
    @import("browser_panel_stub.zig");
pub const ai_chat_renderer = @import("renderer/ai_chat_renderer.zig");
pub const ai_history_renderer = @import("renderer/ai_history_renderer.zig");
pub const skill_center_renderer = @import("renderer/skill_center_renderer.zig");
pub const port_forwarding_renderer = @import("renderer/port_forwarding_renderer.zig");
const ai_sidebar = @import("ai_sidebar.zig");
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
    // `/export [full|clean]` writes the active AI Chat transcript as Markdown.
    ai_chat.setMarkdownExportTrigger(struct {
        fn cb(mode: ai_chat.MarkdownExportMode) void {
            exportActiveAiChatMarkdown(mode);
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
    ai_chat.setDefaultWorkingDir(app.ai_agent_working_dir);
    overlays.setSubagentProfileName(app.ai_subagent_profile);
    ai_chat.setSubagentProfileResolver(overlays.resolveSubagentProfileOverride);
    @import("web_search.zig").setJinaApiKey(app.jina_api_key);
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
    gpu.gl_init.g_bg_opacity = app.background_opacity;
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
            .approval = .ask,
        } },
        .{ .tool = .{
            .name = @constCast("tool_b"),
            .executable_path = @constCast("/tmp/tools/tool_b/bin/tool_b"),
            .skill_path = @constCast("/tmp/tools/tool_b/SKILL.md"),
            .enabled = false,
            .approval = .ask,
        } },
    };

    const manifest_b = switch (entries[1]) {
        .tool => |tool| skillCenterToolManifestPath(std.testing.allocator, tool) orelse return error.ExpectedManifestPath,
        .prompt => return error.ExpectedSkillCenterTool,
    };
    defer std.testing.allocator.free(manifest_b);

    try std.testing.expect(skillCenterApplyToolEnabledByManifestPath(std.testing.allocator, entries[0..], manifest_b, true));
    switch (entries[0]) {
        .tool => |tool| try std.testing.expect(!tool.enabled),
        .prompt => return error.ExpectedSkillCenterTool,
    }
    switch (entries[1]) {
        .tool => |tool| try std.testing.expect(tool.enabled),
        .prompt => return error.ExpectedSkillCenterTool,
    }

    try std.testing.expect(!skillCenterApplyToolEnabledByManifestPath(std.testing.allocator, entries[0..], "/tmp/tools/missing/manifest.json", false));
    switch (entries[1]) {
        .tool => |tool| try std.testing.expect(tool.enabled),
        .prompt => return error.ExpectedSkillCenterTool,
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

    const updated = try skillCenterManifestJsonWithEnabled(std.testing.allocator, manifest_json, true);
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
        .approval = .ask,
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
        .approval = .ask,
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
    var dir = try std.fs.openDirAbsolute(tools_root, .{ .iterate = true });
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

    var store = agent_history.Store.init(allocator);
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

// ============================================================================
// Module-level state (will be moved into AppWindow struct in future)
// ============================================================================

// App pointer for requestNewWindow
pub threadlocal var g_app: ?*App = null;
var g_agent_history_mutex: std.Thread.Mutex = .{};
pub var g_agent_history: ?*agent_history.Store = null;
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
threadlocal var g_remote_layout_last_ms: i64 = 0;
threadlocal var g_remote_ai_sinks: [tab.MAX_TABS]RemoteAiInputSink = undefined;
threadlocal var g_last_transfer_notification_seq: u64 = 0;

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

const AgentSshConnectRequest = struct {
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    result: ?ai_chat.ToolSurface = null,
    err: ?anyerror = null,
};

const AgentSshSaveRequest = struct {
    allocator: std.mem.Allocator,
    args: ai_chat.SshProfileSaveArgs,
    result: ?ai_chat.SavedSshProfile = null,
    err: ?anyerror = null,
};

const AgentTabNewRequest = struct {
    allocator: std.mem.Allocator,
    kind: []const u8,
    command: ?[]const u8,
    result: ?ai_chat.ToolSurface = null,
    err: ?anyerror = null,
};

const AgentTabCloseRequest = struct {
    allocator: std.mem.Allocator,
    tab_index: ?usize,
    surface_id: ?[]const u8,
    title: ?[]const u8,
    result: ?ai_chat.ToolClosedTab = null,
    err: ?anyerror = null,
};

const RemoteAiInputSink = struct {
    native_handle: window_backend.NativeHandle,
    tab_index: usize,
};

const RemoteAiInputRequest = struct {
    tab_index: usize,
    data: []u8,
};

const RemoteAiAgentOpenRequest = struct {
    request_id: []const u8,
};

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

fn glDiagString(name: gpu.c.GLenum) []const u8 {
    // The Metal backend hands back a stub GlTable whose fn pointers are null
    // (see renderer/gpu/metal/GlTable.zig). Guard the fn pointer itself, not
    // just its return value, so render diagnostics don't panic on macOS.
    const get_string = gpu.glTable().GetString orelse return "(unavailable)";
    const ptr = get_string(name);
    if (ptr == null) return "(null)";
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

/// Log GPU vendor/renderer/version and the backbuffer clear-alpha fact once,
/// after the GL context + glad table are ready. Lets the analyst correlate
/// glitches with a specific driver (AMD/Intel/NVIDIA) and confirm the alpha=1
/// clear that feeds DWM composition.
fn logGpuDiagnosticsOnce() void {
    if (!render_diagnostics.enabled()) return;
    if (g_gpu_diag_logged) return;
    g_gpu_diag_logged = true;
    render_diagnostics.log(
        "gpu vendor=\"{s}\" renderer=\"{s}\" version=\"{s}\" glsl=\"{s}\" clear_alpha=1.0 dwm_frame_extend_top=-1",
        .{
            glDiagString(gpu.c.GL_VENDOR),
            glDiagString(gpu.c.GL_RENDERER),
            glDiagString(gpu.c.GL_VERSION),
            glDiagString(gpu.c.GL_SHADING_LANGUAGE_VERSION),
        },
    );
}

threadlocal var g_gpu_diag_logged: bool = false;
threadlocal var g_diag_last_vp: [4]gpu.c.GLint = .{ -1, -1, -1, -1 };
threadlocal var g_diag_last_blend: [5]gpu.c.GLint = .{ -1, -1, -1, -1, -1 };
threadlocal var g_diag_last_swap_client_w: i32 = -1;
threadlocal var g_diag_last_swap_client_h: i32 = -1;

/// Just before SwapBuffers, snapshot the *actual* GL viewport, re-read the
/// client rect, and read the active blend state. Logged only when one of these
/// changes (or when viewport diverges from the client size) so it stays
/// analyzable. Targets the viewport/client-size desync (hypothesis ②) and the
/// backbuffer-alpha blend mode (hypothesis ①).
fn logSwapDiagnosticsIfChanged(win: *window_backend.Window, fb_width: c_int, fb_height: c_int) void {
    if (!render_diagnostics.enabled()) return;
    const gl = gpu.glTable();
    // Metal backend's GlTable is a stub with null fn pointers (see GlTable.zig);
    // skip the GL-specific swap diagnostics there instead of panicking on `.?`.
    // Geometry/DPI diagnostics are emitted by logFrameGeometryIfChanged, which
    // doesn't touch GL, so the DPI log we care about for #90 still works.
    const get_integerv = gl.GetIntegerv orelse return;
    const is_enabled = gl.IsEnabled orelse return;

    var vp: [4]gpu.c.GLint = undefined;
    get_integerv(gpu.c.GL_VIEWPORT, &vp);

    var blend: [5]gpu.c.GLint = undefined;
    blend[0] = @intFromBool(is_enabled(gpu.c.GL_BLEND) != 0);
    get_integerv(gpu.c.GL_BLEND_SRC_RGB, &blend[1]);
    get_integerv(gpu.c.GL_BLEND_DST_RGB, &blend[2]);
    get_integerv(gpu.c.GL_BLEND_SRC_ALPHA, &blend[3]);
    get_integerv(gpu.c.GL_BLEND_DST_ALPHA, &blend[4]);

    const client = window_backend.clientSize(win);
    const vp_matches_client = (vp[2] == client.width and vp[3] == client.height);

    const unchanged = std.mem.eql(gpu.c.GLint, &vp, &g_diag_last_vp) and
        std.mem.eql(gpu.c.GLint, &blend, &g_diag_last_blend) and
        client.width == g_diag_last_swap_client_w and
        client.height == g_diag_last_swap_client_h;
    if (unchanged) return;

    g_diag_last_vp = vp;
    g_diag_last_blend = blend;
    g_diag_last_swap_client_w = client.width;
    g_diag_last_swap_client_h = client.height;

    render_diagnostics.log(
        "swap viewport=({},{} {}x{}) client={}x{} fb={}x{} vp_matches_client={} blend_enabled={} blend_rgb=({},{}) blend_alpha=({},{})",
        .{
            vp[0],             vp[1],         vp[2],    vp[3],
            client.width,      client.height, fb_width, fb_height,
            vp_matches_client, blend[0] != 0, blend[1], blend[2],
            blend[3],          blend[4],
        },
    );
}

fn renderAiChatFrame(fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    if (activeAiChat()) |session| {
        const chat_x = left_panels_w;
        const chat_w = @as(f32, @floatFromInt(fb_width)) - left_panels_w - right_panels_w;
        ai_chat_renderer.render(
            session,
            @floatFromInt(fb_width),
            @floatFromInt(fb_height),
            titlebar_offset,
            chat_x,
            chat_w,
        );
    }
}

fn aiHistoryContentWidth(fb_width: c_int, left_panels_w: f32, right_panels_w: f32) f32 {
    return @max(0, @as(f32, @floatFromInt(fb_width)) - left_panels_w - right_panels_w);
}

fn renderAiHistoryFrame(active_tab: *TabState, fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    if (active_tab.ai_history_session) |session| {
        const draw: ai_history_renderer.DrawContext = .{
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
        ai_history_renderer.render(
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
    gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
    gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
    ai_chat_renderer.render(session, @floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, chat_x, chat_w);
    renderAiCopilotCloseButton(bounds, @floatFromInt(fb_height));
}

fn renderAiCopilotCloseButton(bounds: ai_sidebar.Bounds, window_height: f32) void {
    const layout: hit_test.PanelHeaderLayout = .{
        .visible = true,
        .left = @floatFromInt(bounds.left),
        .right = @floatFromInt(bounds.right),
        .top = @floatFromInt(bounds.top),
        .height = ai_chat_renderer.HEADER_H,
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

fn scMoveSel(sel: *usize, len: usize, delta: isize) void {
    if (len == 0) {
        sel.* = 0;
        return;
    }
    const cur: isize = @intCast(sel.*);
    sel.* = @intCast(std.math.clamp(cur + delta, 0, @as(isize, @intCast(len - 1))));
}

/// Move selection in the active overlay list, else in the library list.
pub fn skillCenterMove(delta: isize) bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .picker => |*p| scMoveSel(&p.sel, p.labels.len, delta),
        .import_list => |*il| scMoveSel(&il.sel, il.names.len, delta),
        .install_pick => |*p| scMoveSel(&p.sel, p.entries.len, delta),
        .url_input => {},
        .tool_import_confirm => {},
        .tool_import_preview => {},
        else => {
            const n = session.model.entryCount();
            scMoveSel(&session.model.sel_row, n, delta);
        },
    }
    markUiDirty();
    return true;
}

/// True if an overlay (picker/import/confirm) is open (captures Enter/Esc).
pub fn skillCenterOverlayActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.overlay != .none;
}

pub fn skillCenterOverlayCancel() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    if (session.model.overlay == .none) {
        session.mutex.unlock();
        return false;
    }
    session.model.clearOverlay();
    session.mutex.unlock();
    return true;
}

/// True when the URL-input overlay is capturing text. UI thread.
pub fn skillCenterUrlInputActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.overlay == .url_input;
}

/// 'g': open the URL-input overlay, prefilled from the clipboard if it looks
/// like a GitHub URL. UI thread.
pub fn skillCenterOpenUrlInput() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.model.overlay != .none) return false;
    var st: skill_center.UrlInputState = .{};
    if (clipboard.readClipboardTextOwned(allocator)) |clip| {
        defer allocator.free(clip);
        const trimmed = std.mem.trim(u8, clip, " \t\r\n");
        if (std.mem.indexOf(u8, trimmed, "github.com/") != null and trimmed.len < 512)
            st.insertSlice(allocator, trimmed);
    }
    session.model.setOverlay(.{ .url_input = st });
    markUiDirty();
    return true;
}

/// Append a typed codepoint to the URL buffer (no-op unless url_input active).
pub fn skillCenterUrlInsertChar(codepoint: u21) bool {
    if (codepoint < 0x20 or codepoint == 0x7f) return false;
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .url_input => |*u| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &buf) catch return false;
            u.insertSlice(allocator, buf[0..len]);
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// Backspace in the URL buffer. UI thread.
pub fn skillCenterUrlBackspace() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .url_input => |*u| {
            u.backspace();
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// Ctrl/Cmd+V: append clipboard text to the URL buffer. UI thread.
pub fn skillCenterUrlPaste() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .url_input => |*u| {
            if (clipboard.readClipboardTextOwned(allocator)) |clip| {
                defer allocator.free(clip);
                const trimmed = std.mem.trim(u8, clip, " \t\r\n");
                u.insertSlice(allocator, trimmed);
            }
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// Enter in the URL-input overlay: snapshot the URL, clear the overlay, start
/// the enumerate op. UI thread.
fn skillCenterStartEnumerate(session: *skill_center.Session, allocator: std.mem.Allocator) void {
    var url_owned: ?[]u8 = null;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .url_input => |*u| {
                const t = std.mem.trim(u8, u.text(), " \t\r\n");
                if (t.len > 0) url_owned = allocator.dupe(u8, t) catch null;
                session.model.clearOverlay();
            },
            else => return,
        }
    }
    const url = url_owned orelse {
        markUiDirty();
        return;
    };
    // Validate the URL on the UI thread so a parse error gets a precise toast
    // (a worker-thread .failed can't distinguish bad-URL from network error).
    if (skill_install.parseGithubUrl(allocator, url)) |rr| {
        var probe = rr;
        probe.deinit(allocator);
    } else |_| {
        allocator.free(url);
        overlays.showStatusToast(i18n.s().sc_toast_bad_url);
        markUiDirty();
        return;
    }
    const job = allocator.create(SkillInstallEnumerateJob) catch {
        allocator.free(url);
        return;
    };
    job.* = .{ .url = url };
    if (!session.startOp(.{ .ctx = job, .run = SkillInstallEnumerateJob.run, .destroy = SkillInstallEnumerateJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_fetching)) {
        SkillInstallEnumerateJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
    markUiDirty();
}

/// True when the install checklist is active. UI thread.
pub fn skillCenterPickActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.overlay == .install_pick;
}

/// Space: toggle the highlighted checklist row. UI thread.
pub fn skillCenterPickToggle() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .install_pick => |*p| {
            p.toggle();
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// 'a': toggle select-all in the checklist. UI thread.
pub fn skillCenterPickSelectAll() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .install_pick => |*p| {
            p.setAll(!p.anyChecked());
            markUiDirty();
            return true;
        },
        else => return false,
    }
}

/// Enter in the checklist: snapshot the selection + repo, clear the overlay,
/// start the download op. UI thread.
fn skillCenterStartInstall(session: *skill_center.Session, allocator: std.mem.Allocator) void {
    var repo_owned: ?skill_install.RepoRef = null;
    var entries_owned: ?[]skill_install.SkillEntry = null;
    var empty = false;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .install_pick => |*p| {
                if (!p.anyChecked()) {
                    empty = true;
                } else {
                    repo_owned = p.repo.clone(allocator) catch null;
                    entries_owned = p.selectedEntries(allocator) catch null;
                    session.model.clearOverlay();
                }
            },
            else => return,
        }
    }
    if (empty) {
        overlays.showStatusToast(i18n.s().sc_toast_no_skills);
        markUiDirty();
        return;
    }
    const repo = repo_owned orelse {
        if (entries_owned) |e| skill_install.freeEntries(allocator, e);
        markUiDirty();
        return;
    };
    const entries = entries_owned orelse {
        var rr = repo;
        rr.deinit(allocator);
        markUiDirty();
        return;
    };
    const job = allocator.create(SkillInstallDownloadJob) catch {
        var rr = repo;
        rr.deinit(allocator);
        skill_install.freeEntries(allocator, entries);
        return;
    };
    job.* = .{ .repo = repo, .entries = entries };
    if (!session.startOp(.{ .ctx = job, .run = SkillInstallDownloadJob.run, .destroy = SkillInstallDownloadJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_installing)) {
        SkillInstallDownloadJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
    markUiDirty();
}

/// Library root `<config>/skills`. Caller frees.
fn skillCenterLibraryDir(allocator: std.mem.Allocator) ?[]const u8 {
    return platform_dirs.pathInConfigDir(allocator, "skills") catch null;
}

/// Download every selected skill's files into a temp staging dir under the
/// library, then per-skill atomically replace `<config>/skills/<name>`. Returns
/// {installed, overwritten, failed}. A skill whose download fails is skipped
/// (counted in `failed`); others still install. Staging dir is always removed.
fn downloadSelectedSkillsToLibrary(
    allocator: std.mem.Allocator,
    repo: skill_install.RepoRef,
    entries: []const skill_install.SkillEntry,
) struct { installed: usize, overwritten: usize, failed: usize } {
    var installed: usize = 0;
    var overwritten: usize = 0;
    var failed: usize = 0;

    const lib_dir = skillCenterLibraryDir(allocator) orelse return .{ .installed = 0, .overwritten = 0, .failed = entries.len };
    defer allocator.free(lib_dir);
    const ref = repo.ref orelse "main";

    const tmp_dir = std.fs.path.join(allocator, &.{ lib_dir, ".install-tmp" }) catch
        return .{ .installed = 0, .overwritten = 0, .failed = entries.len };
    defer allocator.free(tmp_dir);
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    for (entries) |entry| {
        // Defense-in-depth: never let a downloaded skill name escape the library dir.
        if (entry.name.len == 0 or
            std.mem.eql(u8, entry.name, ".") or
            std.mem.eql(u8, entry.name, "..") or
            std.mem.indexOfScalar(u8, entry.name, '/') != null or
            std.mem.indexOfScalar(u8, entry.name, '\\') != null)
        {
            failed += 1;
            continue;
        }
        var ok = true;
        for (entry.files) |file_path| {
            const rel = skill_install.relInstallPath(entry.root_path, file_path) orelse continue;
            // Fetch via the GitHub Contents API (api.github.com) rather than
            // raw.githubusercontent.com: the same host that enumeration used and
            // proved reachable. `Accept: application/vnd.github.raw` returns the
            // file's raw bytes.
            const url = skill_install.contentsApiUrl(allocator, repo.owner, repo.repo, file_path, ref) catch {
                ok = false;
                break;
            };
            defer allocator.free(url);
            const dest = std.fs.path.join(allocator, &.{ tmp_dir, rel }) catch {
                ok = false;
                break;
            };
            defer allocator.free(dest);
            update_install.downloadAssetAccept(allocator, url, dest, "application/vnd.github.raw") catch {
                ok = false;
                break;
            };
        }
        if (!ok) {
            failed += 1;
            continue;
        }

        const final = std.fs.path.join(allocator, &.{ lib_dir, entry.name }) catch {
            failed += 1;
            continue;
        };
        defer allocator.free(final);
        const staged = std.fs.path.join(allocator, &.{ tmp_dir, entry.name }) catch {
            failed += 1;
            continue;
        };
        defer allocator.free(staged);

        const existed = blk: {
            std.fs.accessAbsolute(final, .{}) catch break :blk false;
            break :blk true;
        };
        std.fs.deleteTreeAbsolute(final) catch {
            failed += 1;
            continue;
        };
        std.fs.renameAbsolute(staged, final) catch {
            failed += 1;
            continue;
        };
        installed += 1;
        if (existed) overwritten += 1;
    }

    return .{ .installed = installed, .overwritten = overwritten, .failed = failed };
}

/// ExecHost over a location: local POSIX, SSH when a conn is present, or the
/// default WSL distro (`wsl.exe --exec sh -lc`) when `is_wsl` is set.
const SkillLocExec = struct {
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool = false,
    fn exec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) anyerror![]u8 {
        const self: *SkillLocExec = @ptrCast(@alignCast(ctx));
        if (self.conn) |c| return remote_file.sshExecCapture(allocator, c, command);
        if (self.is_wsl) return remote_file.wslExec(allocator, command) orelse error.RemoteExecFailed;
        return remote_file.localPosixExec(allocator, command, 4 * 1024 * 1024);
    }
    fn host(self: *SkillLocExec) skill_scan.ExecHost {
        return .{ .ctx = self, .exec = exec };
    }
};

/// Resolve a target's SshConnection (null for a local target / unresolved).
fn skillCenterTargetConn(target: skill_center.Target) ?ssh_connection.SshConnection {
    if (target.is_local) return null;
    if (std.mem.startsWith(u8, target.machine_id, "ssh:")) {
        return overlays.aiHistorySshConnection(target.machine_id["ssh:".len..]);
    }
    return null;
}

/// Absolute path of a local target software's skills root (`~/.claude/skills`).
/// Used by the native (non-POSIX) scan/transfer path where `$HOME` can't be
/// expanded by a shell. Null if the home dir can't be resolved. Caller frees.
fn skillCenterLocalRootPath(allocator: std.mem.Allocator, software: skill_center.Software) ?[]u8 {
    const home = platform_dirs.homeDir(allocator) catch return null;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, software.rootRel() }) catch null;
}

/// Scan a skills endpoint, picking the right backend:
///   - remote (conn set): the POSIX `find`/`sha256sum` command over SSH.
///   - WSL (`is_wsl`): the same command via `wsl.exe --exec sh -lc`.
///   - local on a POSIX host: the same command via `sh -c` (preserves the
///     existing Linux/macOS hashes).
///   - local on a non-POSIX host (Windows, no WSL): a native `std.fs` scan whose
///     aggregate hash matches the POSIX recipe byte-for-byte.
/// `root_expr` is the shell root expression (for the SSH/POSIX/WSL paths);
/// `local_path` is the raw absolute root (for the native path; null when remote).
fn skillCenterScanOutcome(
    allocator: std.mem.Allocator,
    root_expr: []const u8,
    local_path: ?[]const u8,
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool,
) skill_scan.ScanOutcome {
    if (conn) |c| {
        var le = SkillLocExec{ .conn = c };
        return skill_scan.scanLocation(allocator, root_expr, le.host()) catch
            return .{ .reachable = false, .rows = &.{} };
    }
    if (is_wsl) {
        var le = SkillLocExec{ .conn = null, .is_wsl = true };
        return skill_scan.scanLocation(allocator, root_expr, le.host()) catch
            return .{ .reachable = false, .rows = &.{} };
    }
    if (remote_file.localPosixExecSupported()) {
        var le = SkillLocExec{ .conn = null };
        return skill_scan.scanLocation(allocator, root_expr, le.host()) catch
            return .{ .reachable = false, .rows = &.{} };
    }
    const lp = local_path orelse return .{ .reachable = false, .rows = &.{} };
    return skill_local_fs.scanOutcome(allocator, lp);
}

/// Adapts skill_transfer.Ops onto local/ssh/scp/WSL. conn null + !is_wsl → a
/// local-only target; is_wsl → both endpoints reached via `wsl.exe` (see
/// `wslSkillTransfer`, where the library lives under /mnt/<drive> and the target
/// under $HOME, so the copy primitive is never invoked).
/// `err_buf`/`err_len` capture the last ssh error summary for the UI toast.
const SkillTransferCtx = struct {
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool = false,
    // Sized off ssh_error.MAX (+ margin) so a summary never gets re-truncated here.
    err_buf: [ssh_error.MAX + 40]u8 = undefined,
    err_len: usize = 0,

    fn noteErr(self: *SkillTransferCtx, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
    }
    fn lastErr(self: *const SkillTransferCtx) ?[]const u8 {
        return if (self.err_len > 0) self.err_buf[0..self.err_len] else null;
    }

    fn localExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *SkillTransferCtx = @ptrCast(@alignCast(ctx));
        // A WSL transfer runs every step (tar/extract/cleanup) over `wslExec`;
        // skill_transfer only calls localExec for the LOCAL_TMP cleanup, whose
        // path lives in the WSL /tmp and is already removed by the remoteExec
        // `rm`. A no-op keeps that ignored cleanup from spuriously failing.
        if (self.is_wsl) return true;
        return remote_file.localPosixExecOk(allocator, command);
    }
    fn remoteExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *SkillTransferCtx = @ptrCast(@alignCast(ctx));
        if (self.is_wsl) {
            // Default WSL distro; stdout discarded (only exit status matters).
            const out = remote_file.wslExec(allocator, command) orelse return false;
            allocator.free(out);
            return true;
        }
        const c = self.conn orelse return false;
        // stdout is discarded; remoteExec only cares about exit status + stderr.
        var cap = remote_file.sshExecCaptureFull(allocator, c, command) catch return false;
        defer cap.deinit(allocator);
        if (!cap.exited_ok) {
            if (ssh_error.summarize(cap.stderr)) |s| self.noteErr(s);
            return false;
        }
        return true;
    }
    fn copy(ctx: *anyopaque, allocator: std.mem.Allocator, dir: skill_transfer.CopyDir, local_tmp: []const u8, remote_tmp: []const u8) bool {
        const self: *SkillTransferCtx = @ptrCast(@alignCast(ctx));
        const c = self.conn orelse return false;
        var buf: [512]u8 = undefined;
        const spec = scp.remoteSpec(&buf, &c, remote_tmp);
        const r = switch (dir) {
            .to_remote => scp.transfer(allocator, &c, local_tmp, spec),
            .to_local => scp.transfer(allocator, &c, spec, local_tmp),
        };
        return r == .ok; // scp summary is best-effort; leave err_buf empty → generic toast
    }
    fn ops(self: *SkillTransferCtx) skill_transfer.Ops {
        return .{ .ctx = self, .localExec = localExec, .remoteExec = remoteExec, .copy = copy };
    }
};

/// Marker for a target skill vs the library (by name + hash).
fn skillCenterMarkerFor(model: *const skill_center.PanelModel, name: []const u8, target_hash: ?[]const u8) skill_center.Marker {
    const entries = model.entries orelse return .new_;
    for (entries) |entry| {
        switch (entry) {
            .prompt => |s| {
                if (std.mem.eql(u8, s.name, name)) {
                    const lh = s.agg_hash orelse return .differ;
                    const th = target_hash orelse return .differ;
                    return if (std.mem.eql(u8, lh, th)) .same else .differ;
                }
            },
            .tool => {},
        }
    }
    return .new_;
}

/// Build an ImportState from a target's scanned rows. Caller holds the lock.
fn skillCenterMakeImportState(allocator: std.mem.Allocator, model: *const skill_center.PanelModel, rows: []const skill_scan.SkillRow, target: skill_center.Target) !skill_center.ImportState {
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var markers: std.ArrayListUnmanaged(skill_center.Marker) = .empty;
    errdefer markers.deinit(allocator);
    for (rows) |r| {
        const marker = skillCenterMarkerFor(model, r.name, r.agg_hash);
        const n = try allocator.dupe(u8, r.name);
        // Explicit cleanup: once `n` is in `names`, the function-level errdefer
        // owns it — a per-item errdefer here would double-free on a later error.
        names.append(allocator, n) catch |e| {
            allocator.free(n);
            return e;
        };
        try markers.append(allocator, marker);
    }
    var tgt = try target.clone(allocator);
    errdefer tgt.deinit(allocator);
    return .{
        .target = tgt,
        .names = try names.toOwnedSlice(allocator),
        .markers = try markers.toOwnedSlice(allocator),
        .sel = 0,
    };
}

fn skillCenterAddMachine(allocator: std.mem.Allocator, labels: *std.ArrayListUnmanaged([]u8), targets: *std.ArrayListUnmanaged(skill_center.Target), machine_id: []const u8, machine_label: []const u8, is_local: bool, is_wsl: bool) !void {
    const sws = [_]skill_center.Software{ .claude, .codex };
    for (sws) |sw| {
        const sw_label = switch (sw) {
            .claude => i18n.s().sc_sw_claude,
            .codex => i18n.s().sc_sw_codex,
        };
        // Explicit per-append cleanup: once an item is in its list, the outer
        // (buildPicker) errdefer owns it — a per-item errdefer would double-free.
        const label = try std.fmt.allocPrint(allocator, "{s} · {s}", .{ machine_label, sw_label });
        labels.append(allocator, label) catch |e| {
            allocator.free(label);
            return e;
        };
        var tgt = try skill_center.Target.dupe(allocator, machine_id, machine_label, sw, is_local);
        tgt.is_wsl = is_wsl;
        targets.append(allocator, tgt) catch |e| {
            tgt.deinit(allocator);
            return e;
        };
    }
}

/// Build a target picker over {local, WSL (Windows), ssh profiles} × {claude, codex}.
fn skillCenterBuildPicker(allocator: std.mem.Allocator, purpose: skill_center.Purpose, skill_name: []const u8) !skill_center.PickerState {
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var targets: std.ArrayListUnmanaged(skill_center.Target) = .empty;
    errdefer {
        for (labels.items) |l| allocator.free(l);
        labels.deinit(allocator);
        for (targets.items) |*t| t.deinit(allocator);
        targets.deinit(allocator);
    }
    try skillCenterAddMachine(allocator, &labels, &targets, "local", i18n.s().sc_local, true, false);
    // The default WSL distro, only when one is actually installed (registry
    // probe — never spawns wsl.exe, so a WSL-less machine never pops the
    // "install WSL" window). Hidden on non-Windows hosts (wslAvailable false).
    if (platform_pty_command.wslAvailable()) {
        try skillCenterAddMachine(allocator, &labels, &targets, "wsl", i18n.s().sc_wsl, false, true);
    }
    const names = overlays.sshProfileNames(allocator) catch &[_][]u8{};
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    for (names) |nm| {
        const id = try std.fmt.allocPrint(allocator, "ssh:{s}", .{nm});
        defer allocator.free(id);
        try skillCenterAddMachine(allocator, &labels, &targets, id, nm, false, false);
    }
    const name_copy = try allocator.dupe(u8, skill_name);
    errdefer allocator.free(name_copy);
    return .{
        .purpose = purpose,
        .skill_name = name_copy,
        .labels = try labels.toOwnedSlice(allocator),
        .targets = try targets.toOwnedSlice(allocator),
        .sel = 0,
    };
}

fn skillCenterOpenPicker(purpose: skill_center.Purpose) bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const name = switch (purpose) {
        .deploy => blk: {
            const sk = session.model.selected() orelse return false;
            break :blk sk.name;
        },
        .import_ => blk: {
            if (session.model.entryCount() == 0) break :blk "";
            const entry = session.model.selectedEntry() orelse return false;
            switch (entry) {
                .prompt => break :blk "",
                .tool => return false,
            }
        },
    };
    const picker = skillCenterBuildPicker(allocator, purpose, name) catch return true;
    session.model.setOverlay(.{ .picker = picker });
    markUiDirty();
    return true;
}

pub fn skillCenterDeploy() bool {
    return skillCenterOpenPicker(.deploy);
}
pub fn skillCenterImport() bool {
    return skillCenterOpenPicker(.import_);
}

fn scPathParent(path: []const u8) ?[]const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[0..i];
    }
    return null;
}

fn scPathBase(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[i + 1 ..];
    }
    return path;
}

fn skillCenterToolManifestPath(allocator: std.mem.Allocator, tool: skill_center.ToolSkill) ?[]u8 {
    if (tool.skill_path) |skill_path| {
        if (std.mem.eql(u8, scPathBase(skill_path), "SKILL.md")) {
            const tool_dir = scPathParent(skill_path) orelse return null;
            return std.fs.path.join(allocator, &.{ tool_dir, "manifest.json" }) catch null;
        }
    }
    const bin_dir = scPathParent(tool.executable_path) orelse return null;
    if (!std.mem.eql(u8, scPathBase(bin_dir), "bin")) return null;
    const tool_dir = scPathParent(bin_dir) orelse return null;
    return std.fs.path.join(allocator, &.{ tool_dir, "manifest.json" }) catch null;
}

fn skillCenterApplyToolEnabledByManifestPath(
    allocator: std.mem.Allocator,
    entries: []skill_center.LibraryEntry,
    manifest_path: []const u8,
    enabled: bool,
) bool {
    for (entries) |*entry| {
        switch (entry.*) {
            .prompt => {},
            .tool => |*tool| {
                const path = skillCenterToolManifestPath(allocator, tool.*) orelse continue;
                defer allocator.free(path);
                if (std.mem.eql(u8, path, manifest_path)) {
                    tool.enabled = enabled;
                    return true;
                }
            },
        }
    }
    return false;
}

fn skillCenterManifestJsonWithEnabled(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    enabled: bool,
) ![]u8 {
    var manifest = try tool_registry.parseManifestJson(allocator, bytes);
    defer manifest.deinit(allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolManifest;

    const entry = try parsed.value.object.getOrPutValue("enabled", std.json.Value{ .bool = enabled });
    entry.value_ptr.* = std.json.Value{ .bool = enabled };
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

fn skillCenterSetStatusLocked(session: *skill_center.Session, text: []const u8) void {
    const next = session.allocator.dupe(u8, text) catch return;
    if (session.status.len > 0) session.allocator.free(session.status);
    session.status = next;
}

fn skillCenterOpenFileDialog(allocator: std.mem.Allocator, request: platform_file_dialog.OpenRequest) ?[]u8 {
    if (g_skill_center_open_file_override) |open_fn| return open_fn(allocator, request);
    return platform_file_dialog.openFile(allocator, request);
}

fn skillCenterImportErrorSummary(allocator: std.mem.Allocator, err: anyerror) []u8 {
    switch (err) {
        error.ProbeSpawnFailed => return allocator.dupe(u8, "Tool import failed: could not inspect the executable.") catch return &.{},
        error.ReservedToolName => return allocator.dupe(u8, "Tool import failed: reserved built-in tool names cannot be imported.") catch return &.{},
        else => {},
    }
    return std.fmt.allocPrint(allocator, "Tool import failed: {}", .{err}) catch allocator.dupe(u8, "Tool import failed") catch return &.{};
}

fn skillCenterCloneToolImportConfirm(
    allocator: std.mem.Allocator,
    confirm: skill_center.ToolImportConfirmState,
) !skill_center.ToolImportConfirmState {
    var clone: skill_center.ToolImportConfirmState = .{
        .tool_id = try allocator.dupe(u8, confirm.tool_id),
        .function_name = &.{},
        .source_path = &.{},
        .staged_binary_path = &.{},
        .warning_text = &.{},
        .owns_staging_dir = false,
        .scroll = confirm.scroll,
    };
    errdefer clone.deinit(allocator);
    clone.function_name = try allocator.dupe(u8, confirm.function_name);
    clone.source_path = try allocator.dupe(u8, confirm.source_path);
    clone.staged_binary_path = try allocator.dupe(u8, confirm.staged_binary_path);
    clone.warning_text = try allocator.dupe(u8, confirm.warning_text);
    return clone;
}

fn skillCenterCloneToolImportPreview(
    allocator: std.mem.Allocator,
    preview: skill_center.ToolImportPreviewState,
) !skill_center.ToolImportPreviewState {
    var clone: skill_center.ToolImportPreviewState = .{
        .tool_id = try allocator.dupe(u8, preview.tool_id),
        .function_name = &.{},
        .source_path = &.{},
        .staged_binary_path = &.{},
        .skill_md = &.{},
        .doc_source = preview.doc_source,
        .ai_review_required = preview.ai_review_required,
        .owns_staging_dir = false,
        .scroll = preview.scroll,
    };
    errdefer clone.deinit(allocator);
    clone.function_name = try allocator.dupe(u8, preview.function_name);
    clone.source_path = try allocator.dupe(u8, preview.source_path);
    clone.staged_binary_path = try allocator.dupe(u8, preview.staged_binary_path);
    clone.skill_md = try allocator.dupe(u8, preview.skill_md);
    return clone;
}

fn skillCenterBinaryPlatformLabel(path: []const u8) []const u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".exe")) return "windows";
    return "native";
}

fn skillCenterBinaryFileSize(path: []const u8) !u64 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return (try file.stat()).size;
}

fn skillCenterToolImportConfirmText(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "WispTerm will run the selected executable with `--skill` and `--help` to inspect it before import.\n\n" ++
            "Press Enter to continue to the import preview, or Esc to cancel and remove the staged copy.\n\n" ++
            "Selected file:\n{s}\n",
        .{source_path},
    );
}

const TOOL_IMPORT_DRAFT_SYSTEM_PROMPT =
    "You write concise, accurate WispTerm SKILL.md files for local executable tools. " ++
    "Stay within the evidence provided and name uncertainty when needed.";

const ToolImportDraftJob = struct {
    profile: overlays.DefaultAiProfileSnapshot,
    tool_id: []u8,
    function_name: []u8,
    source_path: []u8,
    staged_binary_path: []u8,
    prompt: []u8,
    success: bool = false,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *ToolImportDraftJob = @ptrCast(@alignCast(ctx));
        const draft = ai_chat_request.runOneShotPrompt(
            allocator,
            .{
                .base_url = job.profile.base_url,
                .api_key = job.profile.api_key,
                .model = job.profile.model,
                .protocol = job.profile.protocol,
                .thinking_enabled = job.profile.thinking_enabled,
                .reasoning_effort = job.profile.reasoning_effort,
                .max_tokens = job.profile.max_tokens,
            },
            TOOL_IMPORT_DRAFT_SYSTEM_PROMPT,
            job.prompt,
        ) catch |err| {
            return .{ .tool_import_failed = std.fmt.allocPrint(allocator, "Tool import failed: {}", .{err}) catch return .failed };
        };
        defer allocator.free(draft);

        const docs = tool_import.resolveDocs(allocator, .{
            .tool_name = job.function_name,
            .help_output = "",
            .skill_output = "",
            .sibling_skill = null,
            .ai_draft = draft,
        }) catch |err| {
            return .{ .tool_import_failed = std.fmt.allocPrint(allocator, "Tool import failed: {}", .{err}) catch return .failed };
        };
        const tool_id = allocator.dupe(u8, job.tool_id) catch {
            allocator.free(docs.skill_md);
            return .{ .tool_import_failed = allocator.dupe(u8, "Tool import failed: could not stage the generated preview.") catch return .failed };
        };
        const function_name = allocator.dupe(u8, job.function_name) catch {
            allocator.free(tool_id);
            allocator.free(docs.skill_md);
            return .{ .tool_import_failed = allocator.dupe(u8, "Tool import failed: could not stage the generated preview.") catch return .failed };
        };
        const source_path = allocator.dupe(u8, job.source_path) catch {
            allocator.free(tool_id);
            allocator.free(function_name);
            allocator.free(docs.skill_md);
            return .{ .tool_import_failed = allocator.dupe(u8, "Tool import failed: could not stage the generated preview.") catch return .failed };
        };
        const staged_binary_path = allocator.dupe(u8, job.staged_binary_path) catch {
            allocator.free(tool_id);
            allocator.free(function_name);
            allocator.free(source_path);
            allocator.free(docs.skill_md);
            return .{ .tool_import_failed = allocator.dupe(u8, "Tool import failed: could not stage the generated preview.") catch return .failed };
        };

        job.success = true;
        return .{ .tool_import_preview = .{
            .tool_id = tool_id,
            .function_name = function_name,
            .source_path = source_path,
            .staged_binary_path = staged_binary_path,
            .skill_md = docs.skill_md,
            .doc_source = docs.source,
            .ai_review_required = true,
        } };
    }

    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *ToolImportDraftJob = @ptrCast(@alignCast(ctx));
        if (!job.success) tool_import.cleanupStagedBinaryPath(job.staged_binary_path);
        var profile = job.profile;
        profile.deinit(allocator);
        allocator.free(job.tool_id);
        allocator.free(job.function_name);
        allocator.free(job.source_path);
        allocator.free(job.staged_binary_path);
        allocator.free(job.prompt);
        allocator.destroy(job);
    }
};

fn skillCenterContinueToolImport(
    session: *skill_center.Session,
    allocator: std.mem.Allocator,
    confirm: *skill_center.ToolImportConfirmState,
) bool {
    var probe = tool_import.probeBinary(allocator, confirm.staged_binary_path) catch |err| {
        const summary = skillCenterImportErrorSummary(allocator, err);
        defer if (summary.len > 0) allocator.free(summary);
        session.mutex.lock();
        skillCenterSetStatusLocked(session, if (summary.len > 0) summary else "Tool import failed");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    defer probe.deinit(allocator);
    const sibling_skill = tool_import.readSiblingSkillMd(allocator, confirm.source_path);
    defer if (sibling_skill) |skill_md| allocator.free(skill_md);

    const docs = tool_import.resolveDocs(allocator, .{
        .tool_name = confirm.function_name,
        .help_output = probe.help,
        .skill_output = probe.skill,
        .sibling_skill = sibling_skill,
        .ai_draft = null,
    }) catch |err| switch (err) {
        error.MissingToolDocumentation => null,
        else => {
            const summary = skillCenterImportErrorSummary(allocator, err);
            defer if (summary.len > 0) allocator.free(summary);
            session.mutex.lock();
            skillCenterSetStatusLocked(session, if (summary.len > 0) summary else "Tool import failed");
            session.mutex.unlock();
            markUiDirty();
            return true;
        },
    };
    if (docs) |resolved| {
        defer allocator.free(resolved.skill_md);
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "");
        var opened = true;
        confirm.owns_staging_dir = false;
        session.model.openToolImportPreview(.{
            .tool_id = confirm.tool_id,
            .function_name = confirm.function_name,
            .source_path = confirm.source_path,
            .staged_binary_path = confirm.staged_binary_path,
            .skill_md = resolved.skill_md,
            .doc_source = resolved.source,
            .ai_review_required = false,
        }) catch {
            opened = false;
            confirm.owns_staging_dir = true;
        };
        if (!opened) skillCenterSetStatusLocked(session, "Tool import failed: could not open the preview.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    }

    var profile = overlays.defaultAiProfileSnapshot(allocator) orelse {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "Add an AI profile or provide SKILL.md next to the binary.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    var profile_owned = true;
    defer if (profile_owned) profile.deinit(allocator);

    const basename = std.fs.path.basename(confirm.source_path);
    const staged_sha256 = tool_import.sha256FileHex(allocator, confirm.staged_binary_path) catch {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "Tool import failed: could not hash the executable.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    defer allocator.free(staged_sha256);
    const staged_size = skillCenterBinaryFileSize(confirm.staged_binary_path) catch {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "Tool import failed: could not inspect the staged executable.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    const prompt = tool_skill_draft.buildDraftPrompt(allocator, .{
        .tool_name = confirm.function_name,
        .filename = basename,
        .sha256 = staged_sha256,
        .file_size = staged_size,
        .platform = skillCenterBinaryPlatformLabel(confirm.source_path),
    }) catch {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "Tool import failed: could not build the documentation draft request.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    var prompt_owned = true;
    defer if (prompt_owned) allocator.free(prompt);

    const job = allocator.create(ToolImportDraftJob) catch {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "Tool import failed: could not start the documentation draft.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    const job_tool_id = allocator.dupe(u8, confirm.tool_id) catch {
        allocator.destroy(job);
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "Tool import failed: could not prepare the documentation draft.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    const job_function_name = allocator.dupe(u8, confirm.function_name) catch {
        allocator.free(job_tool_id);
        allocator.destroy(job);
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "Tool import failed: could not prepare the documentation draft.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    const job_source_path = allocator.dupe(u8, confirm.source_path) catch {
        allocator.free(job_tool_id);
        allocator.free(job_function_name);
        allocator.destroy(job);
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "Tool import failed: could not prepare the documentation draft.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    const job_staged_binary_path = allocator.dupe(u8, confirm.staged_binary_path) catch {
        allocator.free(job_tool_id);
        allocator.free(job_function_name);
        allocator.free(job_source_path);
        allocator.destroy(job);
        session.mutex.lock();
        skillCenterSetStatusLocked(session, "Tool import failed: could not prepare the documentation draft.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    job.* = .{
        .profile = profile,
        .tool_id = job_tool_id,
        .function_name = job_function_name,
        .source_path = job_source_path,
        .staged_binary_path = job_staged_binary_path,
        .prompt = prompt,
    };
    profile_owned = false;
    prompt_owned = false;
    if (!session.startOp(.{ .ctx = job, .run = ToolImportDraftJob.run, .destroy = ToolImportDraftJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_loading)) {
        ToolImportDraftJob.destroy(@ptrCast(job), allocator);
        session.mutex.lock();
        skillCenterSetStatusLocked(session, i18n.s().sc_toast_op_busy);
        session.mutex.unlock();
        markUiDirty();
        return true;
    }
    confirm.owns_staging_dir = false;
    markUiDirty();
    return true;
}

pub fn skillCenterImportTool() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    const filters = [_]platform_file_dialog.Filter{.{ .name = "All Files", .pattern = "*.*" }};
    const owner: platform_file_dialog.Owner = if (currentNativeHandleBits()) |handle_bits|
        platform_file_dialog.windowOwner(handle_bits)
    else
        .{};
    const source_path = skillCenterOpenFileDialog(allocator, .{
        .owner = owner,
        .title = "Import executable tool",
        .filters = &filters,
    }) orelse return false;
    defer allocator.free(source_path);

    const basename = std.fs.path.basename(source_path);
    const function_name = tool_registry.sanitizeFunctionName(allocator, basename) catch return false;
    defer allocator.free(function_name);
    tool_registry.validateImportedFunctionName(function_name) catch |err| {
        const summary = skillCenterImportErrorSummary(allocator, err);
        defer if (summary.len > 0) allocator.free(summary);
        session.mutex.lock();
        skillCenterSetStatusLocked(session, if (summary.len > 0) summary else "Tool import failed");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    const tool_id = allocator.dupe(u8, function_name) catch return false;
    defer allocator.free(tool_id);

    const tools_root = platform_dirs.toolsDir(allocator) catch return false;
    defer allocator.free(tools_root);
    const staging_name = std.fmt.allocPrint(allocator, ".import-staging-{d}-{s}", .{ std.time.milliTimestamp(), function_name }) catch return false;
    defer allocator.free(staging_name);
    const staging_root = std.fs.path.join(allocator, &.{ tools_root, staging_name }) catch return false;
    defer allocator.free(staging_root);
    const staging_bin_dir = std.fs.path.join(allocator, &.{ staging_root, "bin" }) catch return false;
    defer allocator.free(staging_bin_dir);
    const staged_binary_path = std.fs.path.join(allocator, &.{ staging_bin_dir, basename }) catch return false;
    defer allocator.free(staged_binary_path);
    var keep_stage = false;
    defer if (!keep_stage) tool_import.cleanupStagedBinaryPath(staged_binary_path);
    tool_import.ensureDirAbsolute(staging_bin_dir) catch return false;
    tool_import.copyFilePreserveMode(source_path, staged_binary_path) catch {
        tool_import.cleanupStagedBinaryPath(staged_binary_path);
        return false;
    };

    const confirm_text = skillCenterToolImportConfirmText(allocator, source_path) catch return false;
    defer allocator.free(confirm_text);
    session.mutex.lock();
    skillCenterSetStatusLocked(session, "");
    session.model.openToolImportConfirm(.{
        .tool_id = tool_id,
        .function_name = function_name,
        .source_path = source_path,
        .staged_binary_path = staged_binary_path,
        .warning_text = confirm_text,
    }) catch {
        skillCenterSetStatusLocked(session, "Tool import failed: could not open the warning.");
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    session.mutex.unlock();
    keep_stage = true;
    markUiDirty();
    return true;
}

pub fn skillCenterToggleToolEnabled() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    var manifest_path: ?[]u8 = null;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        const entry = session.model.selectedEntry() orelse return false;
        switch (entry) {
            .prompt => return false,
            .tool => |tool| {
                manifest_path = skillCenterToolManifestPath(allocator, tool);
            },
        }
    }
    const path = manifest_path orelse {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, i18n.s().sc_tool_toggle_failed);
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    defer allocator.free(path);

    const bytes = skill_local_fs.readFileAllocAbsolute(allocator, path, 64 * 1024) catch {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, i18n.s().sc_tool_toggle_failed);
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    defer allocator.free(bytes);
    var manifest = tool_registry.parseManifestJson(allocator, bytes) catch {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, i18n.s().sc_tool_toggle_failed);
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    defer manifest.deinit(allocator);

    const new_enabled = !manifest.enabled;
    const json = skillCenterManifestJsonWithEnabled(allocator, bytes, new_enabled) catch {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, i18n.s().sc_tool_toggle_failed);
        session.mutex.unlock();
        markUiDirty();
        return true;
    };
    defer allocator.free(json);
    platform_atomic_file.writeFileReplaceSafe(path, json) catch {
        session.mutex.lock();
        skillCenterSetStatusLocked(session, i18n.s().sc_tool_toggle_failed);
        session.mutex.unlock();
        markUiDirty();
        return true;
    };

    ai_chat.reloadDynamicToolSpecs(allocator);
    session.mutex.lock();
    if (session.model.entries) |entries| {
        _ = skillCenterApplyToolEnabledByManifestPath(allocator, entries, path, new_enabled);
    }
    skillCenterSetStatusLocked(session, if (new_enabled) i18n.s().sc_tool_enabled else i18n.s().sc_tool_disabled);
    session.mutex.unlock();
    markUiDirty();
    return true;
}

/// Scan a chosen target and open the import list — off the UI thread.
fn skillCenterOpenImportList(allocator: std.mem.Allocator, target: skill_center.Target) void {
    const session = activeSkillCenter() orelse return;
    const conn = skillCenterTargetConn(target);
    if (target.requiresSshConn() and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        return;
    }
    const root_expr = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch return;
    // Raw root for the native (non-POSIX) path; null when remote or unresolvable.
    const local_path: ?[]u8 = if (target.is_local) skillCenterLocalRootPath(allocator, target.software) else null;
    // ownership of root_expr + local_path moves into the job on success
    const tgt = target.clone(allocator) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        return;
    };
    const job = allocator.create(SkillImportScanJob) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        var t = tgt;
        t.deinit(allocator);
        return;
    };
    job.* = .{ .target = tgt, .conn = conn, .root_expr = root_expr, .local_path = local_path };
    if (!session.startOp(.{ .ctx = job, .run = SkillImportScanJob.run, .destroy = SkillImportScanJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_syncing)) {
        SkillImportScanJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}

/// Run a transfer (library ⇆ target) off the UI thread; result handled in
/// pollSkillCenterOp.
fn skillCenterRunTransfer(allocator: std.mem.Allocator, is_import: bool, target: skill_center.Target, name: []const u8) void {
    const session = activeSkillCenter() orelse return;
    const conn = skillCenterTargetConn(target);
    if (target.requiresSshConn() and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        return;
    }
    const lib_dir = skillCenterLibraryDir(allocator) orelse return;
    defer allocator.free(lib_dir);
    const lib_root = skill_transfer_cmd.absRootExpr(allocator, lib_dir) catch return;
    const tgt_root = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch {
        allocator.free(lib_root);
        return;
    };
    const lib_path = allocator.dupe(u8, lib_dir) catch {
        allocator.free(lib_root);
        allocator.free(tgt_root);
        return;
    };
    // Raw target root for the native (non-POSIX) path; null when remote.
    const tgt_path: ?[]u8 = if (target.is_local) skillCenterLocalRootPath(allocator, target.software) else null;
    const name_dup = allocator.dupe(u8, name) catch {
        allocator.free(lib_root);
        allocator.free(tgt_root);
        allocator.free(lib_path);
        if (tgt_path) |p| allocator.free(p);
        return;
    };
    const job = allocator.create(SkillTransferJob) catch {
        allocator.free(lib_root);
        allocator.free(tgt_root);
        allocator.free(lib_path);
        if (tgt_path) |p| allocator.free(p);
        allocator.free(name_dup);
        return;
    };
    job.* = .{
        .is_import = is_import,
        .conn = conn,
        .is_wsl = target.is_wsl,
        .lib_root = lib_root,
        .tgt_root = tgt_root,
        .tgt_is_local = target.is_local,
        .name = name_dup,
        .lib_path = lib_path,
        .tgt_path = tgt_path,
        .tgt_software = target.software,
    };
    if (!session.startOp(.{ .ctx = job, .run = SkillTransferJob.run, .destroy = SkillTransferJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_syncing)) {
        SkillTransferJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}

/// Preview the selected server skill's SKILL.md — off the UI thread.
/// Only meaningful inside an import_list overlay.
fn skillCenterPreviewServerSkill(allocator: std.mem.Allocator) void {
    const session = activeSkillCenter() orelse return;
    var name_owned: ?[]u8 = null;
    var target_owned: ?skill_center.Target = null;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .import_list => |*il| {
                if (il.sel < il.names.len) {
                    name_owned = allocator.dupe(u8, il.names[il.sel]) catch null;
                    target_owned = il.target.clone(allocator) catch null;
                }
            },
            else => {},
        }
    }
    const name = name_owned orelse {
        if (target_owned) |*t| t.deinit(allocator);
        return;
    };
    var target = target_owned orelse {
        allocator.free(name);
        return;
    };
    defer target.deinit(allocator); // only need conn + software here

    const conn = skillCenterTargetConn(target);
    if (target.requiresSshConn() and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        allocator.free(name);
        return;
    }
    const root_expr = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch {
        allocator.free(name);
        return;
    };
    defer allocator.free(root_expr);
    const cmd = skill_transfer_cmd.catSkillMdCmd(allocator, root_expr, name) catch {
        allocator.free(name);
        return;
    };
    // Absolute SKILL.md path for a LOCAL target so the worker can read it
    // natively on a non-POSIX host; null for remote (uses the ssh cat cmd).
    const local_md_path: ?[]u8 = if (target.is_local) blk: {
        const root = skillCenterLocalRootPath(allocator, target.software) orelse break :blk null;
        defer allocator.free(root);
        break :blk std.fs.path.join(allocator, &.{ root, name, "SKILL.md" }) catch null;
    } else null;
    const job = allocator.create(SkillPreviewJob) catch {
        allocator.free(name);
        allocator.free(cmd);
        if (local_md_path) |p| allocator.free(p);
        return;
    };
    job.* = .{ .conn = conn, .is_wsl = target.is_wsl, .name = name, .cmd = cmd, .local_md_path = local_md_path };
    if (!session.startOp(.{ .ctx = job, .run = SkillPreviewJob.run, .destroy = SkillPreviewJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_loading)) {
        SkillPreviewJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}

/// Arm an overwrite confirm overlay for a pending deploy/import.
fn skillCenterArmConfirm(allocator: std.mem.Allocator, is_import: bool, target: skill_center.Target, name: []const u8) void {
    const session = activeSkillCenter() orelse return;
    var msg_buf: [256]u8 = undefined;
    const t = i18n.s();
    const msg = std.fmt.bufPrint(&msg_buf, "{s} → {s} {s}", .{ name, target.machine_label, t.sc_confirm_suffix }) catch t.sc_confirm_suffix;
    // Explicit cleanup (not errdefer): this is a void fn, so errdefer would
    // never fire on the `catch return` paths.
    var tgt = target.clone(allocator) catch return;
    const name_dup = allocator.dupe(u8, name) catch {
        tgt.deinit(allocator);
        return;
    };
    const text = allocator.dupe(u8, msg) catch {
        tgt.deinit(allocator);
        allocator.free(name_dup);
        return;
    };
    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.setOverlay(.{ .confirm = .{ .text = text, .is_import = is_import, .target = tgt, .name = name_dup } });
    markUiDirty();
}

/// Deploy: scan the target off the UI thread; the decision happens in
/// pollSkillCenterOp once rows arrive.
fn skillCenterDeployDecide(allocator: std.mem.Allocator, target: skill_center.Target, name: []const u8, src_hash: ?[]const u8) void {
    const session = activeSkillCenter() orelse return;
    const conn = skillCenterTargetConn(target);
    if (target.requiresSshConn() and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        return;
    }
    const root_expr = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch return;
    // Raw root for the native (non-POSIX) path; null when remote or unresolvable.
    const local_path: ?[]u8 = if (target.is_local) skillCenterLocalRootPath(allocator, target.software) else null;
    const tgt = target.clone(allocator) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        return;
    };
    const name_dup = allocator.dupe(u8, name) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        var t = tgt;
        t.deinit(allocator);
        return;
    };
    var hash_dup: ?[]u8 = null;
    if (src_hash) |h| {
        hash_dup = allocator.dupe(u8, h) catch {
            allocator.free(root_expr);
            if (local_path) |p| allocator.free(p);
            var t = tgt;
            t.deinit(allocator);
            allocator.free(name_dup);
            return;
        };
    }
    const job = allocator.create(SkillDeployScanJob) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        var t = tgt;
        t.deinit(allocator);
        allocator.free(name_dup);
        if (hash_dup) |h| allocator.free(h);
        return;
    };
    job.* = .{ .target = tgt, .conn = conn, .root_expr = root_expr, .local_path = local_path, .name = name_dup, .src_hash = hash_dup };
    if (!session.startOp(.{ .ctx = job, .run = SkillDeployScanJob.run, .destroy = SkillDeployScanJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_syncing)) {
        SkillDeployScanJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}

/// Import: the marker already encodes new/same/differ.
fn skillCenterImportAct(allocator: std.mem.Allocator, target: skill_center.Target, name: []const u8, marker: skill_center.Marker) void {
    switch (marker) {
        .same => overlays.showStatusToast(i18n.s().sc_toast_in_sync),
        .new_ => skillCenterRunTransfer(allocator, true, target, name),
        .differ => skillCenterArmConfirm(allocator, true, target, name),
    }
}

/// Enter inside an overlay: act on the selection. Snapshots under the lock,
/// then runs the (blocking) work after releasing it.
pub fn skillCenterOverlaySelect() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    // URL input submits to the enumerate op (manages its own lock).
    if (skillCenterUrlInputActive()) {
        skillCenterStartEnumerate(session, allocator);
        return true;
    }
    // The install checklist submits to the download op (manages its own lock).
    if (skillCenterPickActive()) {
        skillCenterStartInstall(session, allocator);
        return true;
    }
    var tool_confirm_owned: ?skill_center.ToolImportConfirmState = null;
    var tool_preview_owned: ?skill_center.ToolImportPreviewState = null;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        if (session.model.overlay == .tool_import_confirm) {
            tool_confirm_owned = skillCenterCloneToolImportConfirm(allocator, session.model.overlay.tool_import_confirm) catch return false;
            session.model.clearOverlay();
        }
        if (session.model.overlay == .tool_import_preview) {
            tool_preview_owned = skillCenterCloneToolImportPreview(allocator, session.model.overlay.tool_import_preview) catch return false;
        }
    }
    if (tool_confirm_owned) |*confirm| {
        defer confirm.deinit(allocator);
        return skillCenterContinueToolImport(session, allocator, confirm);
    }
    if (tool_preview_owned) |*preview| {
        defer preview.deinit(allocator);
        const tools_root = platform_dirs.toolsDir(allocator) catch {
            session.mutex.lock();
            skillCenterSetStatusLocked(session, "Tool import failed: could not open the tools directory.");
            session.mutex.unlock();
            markUiDirty();
            return true;
        };
        defer allocator.free(tools_root);
        const installed = tool_import.installToolPackageWithSource(
            allocator,
            tools_root,
            preview.staged_binary_path,
            preview.source_path,
            preview.function_name,
            preview.skill_md,
            false,
        ) catch |err| {
            const summary = skillCenterImportErrorSummary(allocator, err);
            defer if (summary.len > 0) allocator.free(summary);
            session.mutex.lock();
            skillCenterSetStatusLocked(session, if (summary.len > 0) summary else "Tool import failed");
            session.mutex.unlock();
            markUiDirty();
            return true;
        };
        defer allocator.free(installed);
        session.mutex.lock();
        session.model.clearOverlay();
        skillCenterSetStatusLocked(session, "");
        session.mutex.unlock();
        startSkillCenterScan(allocator, session);
        ai_chat.reloadDynamicToolSpecs(allocator);
        markUiDirty();
        return true;
    }
    const Act = enum { none, deploy_picked, import_picked, import_item, confirm };
    var act: Act = .none;
    var target: ?skill_center.Target = null;
    var name_owned: ?[]u8 = null;
    var src_hash_owned: ?[]u8 = null;
    var marker: skill_center.Marker = .new_;
    var is_import_confirm = false;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .picker => |*p| {
                if (p.sel < p.targets.len) {
                    target = p.targets[p.sel].clone(allocator) catch null;
                    if (p.purpose == .deploy) {
                        name_owned = allocator.dupe(u8, p.skill_name) catch null;
                        if (session.model.entries) |entries| {
                            for (entries) |entry| {
                                switch (entry) {
                                    .prompt => |s| {
                                        if (std.mem.eql(u8, s.name, p.skill_name)) {
                                            if (s.agg_hash) |h| src_hash_owned = allocator.dupe(u8, h) catch null;
                                        }
                                    },
                                    .tool => {},
                                }
                            }
                        }
                        act = .deploy_picked;
                    } else {
                        act = .import_picked;
                    }
                }
                session.model.clearOverlay();
            },
            .import_list => |*il| {
                if (il.sel < il.names.len) {
                    name_owned = allocator.dupe(u8, il.names[il.sel]) catch null;
                    target = il.target.clone(allocator) catch null;
                    marker = il.markers[il.sel];
                    act = .import_item;
                }
                session.model.clearOverlay();
            },
            .confirm => |*c| {
                target = c.target.clone(allocator) catch null;
                name_owned = allocator.dupe(u8, c.name) catch null;
                is_import_confirm = c.is_import;
                act = .confirm;
                session.model.clearOverlay();
            },
            // Handled by the early guards above; safety no-ops here.
            .url_input => {},
            .install_pick => {},
            .text_preview => {},
            .tool_import_confirm => {},
            .tool_import_preview => {},
            .none, .busy => {},
        }
    }
    defer {
        if (target) |*t| t.deinit(allocator);
        if (name_owned) |n| allocator.free(n);
        if (src_hash_owned) |h| allocator.free(h);
    }
    markUiDirty();
    switch (act) {
        .none => {},
        .deploy_picked => {
            if (target) |tgt| if (name_owned) |nm| skillCenterDeployDecide(allocator, tgt, nm, src_hash_owned);
        },
        .import_picked => {
            if (target) |tgt| skillCenterOpenImportList(allocator, tgt);
        },
        .import_item => {
            if (target) |tgt| if (name_owned) |nm| skillCenterImportAct(allocator, tgt, nm, marker);
        },
        .confirm => {
            if (target) |tgt| if (name_owned) |nm| skillCenterRunTransfer(allocator, is_import_confirm, tgt, nm);
        },
    }
    return true;
}

/// Rescan all sources for the active Skill Center tab. UI thread.
pub fn skillCenterRescan() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    startSkillCenterScan(allocator, session);
    markUiDirty();
    return true;
}

/// Preview the selected library skill's SKILL.md in the markdown panel.
pub fn skillCenterPreviewSelected() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    var path_owned: ?[]u8 = null;
    var name_buf: [128]u8 = undefined;
    var name_len: usize = 0;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        const entry = session.model.selectedEntry() orelse return true;
        switch (entry) {
            .prompt => |sk| {
                name_len = @min(sk.name.len, name_buf.len);
                @memcpy(name_buf[0..name_len], sk.name[0..name_len]);
                const lib_dir = skillCenterLibraryDir(allocator) orelse return true;
                defer allocator.free(lib_dir);
                path_owned = std.fs.path.join(allocator, &.{ lib_dir, sk.rel_path }) catch null;
            },
            .tool => |tool| {
                const skill_path = tool.skill_path orelse return true;
                name_len = @min(tool.name.len, name_buf.len);
                @memcpy(name_buf[0..name_len], tool.name[0..name_len]);
                path_owned = allocator.dupe(u8, skill_path) catch null;
            },
        }
    }
    const abs = path_owned orelse return true;
    defer allocator.free(abs);
    const text = skill_local_fs.readFileAllocAbsolute(allocator, abs, 1024 * 1024) catch null;
    if (text) |t| {
        defer allocator.free(t);
        var title_buf: [160]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} / SKILL.md", .{name_buf[0..name_len]}) catch name_buf[0..name_len];
        session.mutex.lock();
        session.model.openTextPreview(title, t) catch {};
        session.mutex.unlock();
        markUiDirty();
    } else {
        overlays.showStatusToast(i18n.s().sc_toast_read_failed);
    }
    return true;
}

/// True when the scrollable SKILL.md preview overlay is showing.
pub fn skillCenterTextPreviewActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.isTextPreview();
}

pub const SkillCenterPreviewKind = enum {
    none,
    text,
    tool_import_confirm,
    tool_import,
};

pub fn skillCenterPreviewKind() SkillCenterPreviewKind {
    const session = activeSkillCenter() orelse return .none;
    session.mutex.lock();
    defer session.mutex.unlock();
    return switch (session.model.overlay) {
        .text_preview => .text,
        .tool_import_confirm => .tool_import_confirm,
        .tool_import_preview => .tool_import,
        else => .none,
    };
}

/// Scroll the open SKILL.md preview by `delta` wrapped lines (renderer clamps).
pub fn skillCenterPreviewScroll(delta: isize) bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    session.model.scrollTextPreview(delta);
    session.mutex.unlock();
    markUiDirty();
    return true;
}

/// Close the SKILL.md preview overlay.
pub fn skillCenterPreviewClose() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    session.model.clearOverlay();
    session.mutex.unlock();
    markUiDirty();
    return true;
}

/// Space key in the Skill Center: preview the selected item by overlay kind.
/// import_list → server skill (async); main library / deploy picker → local
/// library skill; import picker / confirm → no-op. UI thread.
pub fn skillCenterSpacePreview() bool {
    if (skillCenterPickActive()) return skillCenterPickToggle();
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    const Kind = enum { lib, server, none };
    var kind: Kind = .lib;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .none, .busy => kind = .lib,
            .import_list => kind = .server,
            .picker => |*p| kind = if (p.purpose == .deploy) .lib else .none,
            .confirm => kind = .none,
            .url_input => kind = .none,
            .install_pick => kind = .none,
            .text_preview => kind = .none, // input intercepts Space while previewing
            .tool_import_confirm => kind = .none,
            .tool_import_preview => kind = .none,
        }
    }
    switch (kind) {
        .lib => _ = skillCenterPreviewSelected(),
        .server => skillCenterPreviewServerSkill(allocator),
        .none => {},
    }
    return true;
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

// ===========================================================================
// Skill Center — scan worker, host factory, source enumeration
// ===========================================================================

/// Everything a Skill Center scan host needs for one source, snapshotted on the
/// UI thread. `ssh` carries a copied `SshConnection` value (inline buffers, no
/// threadlocal pointers); `local`/`wsl` resolve inside the worker. `unreachable_`
/// marks a source we want to show as an unreachable column (e.g. an SSH profile
/// that could not be resolved, or local on a non-POSIX host).
/// Background job: scan the local library (`<config>/skills`) off the UI thread.
const SkillLibraryScanJob = struct {
    root_expr: []u8, // owned shell expression for the library root (POSIX path)
    local_path: []u8, // owned raw absolute library root (native path)
    tools_root: []const u8, // owned raw absolute installed binary tools root

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]skill_center.LibraryEntry {
        const job: *SkillLibraryScanJob = @ptrCast(@alignCast(ctx));
        const outcome = skillCenterScanOutcome(allocator, job.root_expr, job.local_path, null, false);
        const prompt_entries = if (outcome.reachable) entries: {
            const prompt_lib = try skill_center.libraryFromRows(allocator, outcome.rows);
            break :entries try skill_center.entriesFromLibrary(allocator, prompt_lib);
        } else try allocator.alloc(skill_center.LibraryEntry, 0);
        var prompt_entries_owned = true;
        errdefer if (prompt_entries_owned) skill_center.freeEntries(allocator, prompt_entries);

        const tools = try tool_registry.scanInstalledTools(allocator, job.tools_root);
        defer tool_registry.freeInstalledTools(allocator, tools);

        const entries = try allocator.alloc(skill_center.LibraryEntry, prompt_entries.len + tools.len);
        var filled: usize = 0;
        errdefer {
            for (entries[0..filled]) |*entry| entry.deinit(allocator);
            allocator.free(entries);
        }

        for (prompt_entries) |entry| {
            entries[filled] = entry;
            filled += 1;
        }
        allocator.free(prompt_entries);
        prompt_entries_owned = false;

        for (tools) |tool| {
            entries[filled] = try skillCenterEntryFromInstalledTool(allocator, job.tools_root, tool);
            filled += 1;
        }

        std.sort.insertion(skill_center.LibraryEntry, entries, {}, skillCenterEntryLessThan);
        return entries;
    }

    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillLibraryScanJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.root_expr);
        allocator.free(job.local_path);
        allocator.free(job.tools_root);
        allocator.destroy(job);
    }
};

fn skillCenterEntryLessThan(_: void, a: skill_center.LibraryEntry, b: skill_center.LibraryEntry) bool {
    return std.mem.lessThan(u8, a.name(), b.name());
}

fn skillCenterEntryFromInstalledTool(
    allocator: std.mem.Allocator,
    tools_root: []const u8,
    tool: tool_registry.InstalledTool,
) !skill_center.LibraryEntry {
    const name = try allocator.dupe(u8, tool.function_name);
    errdefer allocator.free(name);
    const executable_path = try allocator.dupe(u8, tool.executable_abs);
    errdefer allocator.free(executable_path);
    const skill_path = try std.fs.path.join(allocator, &.{ tools_root, tool.id, "SKILL.md" });
    return .{ .tool = .{
        .name = name,
        .executable_path = executable_path,
        .skill_path = skill_path,
        .enabled = tool.enabled,
        .approval = .ask,
    } };
}

/// Background op: scan a target, return rows for the UI to build an import list.
const SkillImportScanJob = struct {
    target: skill_center.Target, // owned
    conn: ?ssh_connection.SshConnection,
    root_expr: []u8, // owned
    local_path: ?[]u8, // owned raw root when local; null when remote (native path)

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillImportScanJob = @ptrCast(@alignCast(ctx));
        var outcome = skillCenterScanOutcome(allocator, job.root_expr, job.local_path, job.conn, job.target.is_wsl);
        const tgt = job.target.clone(allocator) catch {
            outcome.deinit(allocator);
            return .failed;
        };
        // An unreachable source yields `{ reachable = false, rows = &.{} }`;
        // importScanResult turns it into `.failed` rather than an empty list.
        return skill_center.importScanResult(allocator, &outcome, tgt);
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillImportScanJob = @ptrCast(@alignCast(ctx));
        job.target.deinit(allocator);
        allocator.free(job.root_expr);
        if (job.local_path) |p| allocator.free(p);
        allocator.destroy(job);
    }
};

/// Background op: scan a target for deploy, return rows + the skill identity so
/// the UI can decide noop/direct/confirm.
const SkillDeployScanJob = struct {
    target: skill_center.Target, // owned
    conn: ?ssh_connection.SshConnection,
    root_expr: []u8, // owned
    local_path: ?[]u8, // owned raw root when local; null when remote (native path)
    name: []u8, // owned
    src_hash: ?[]u8, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillDeployScanJob = @ptrCast(@alignCast(ctx));
        var outcome = skillCenterScanOutcome(allocator, job.root_expr, job.local_path, job.conn, job.target.is_wsl);
        // A genuinely unreachable target (SSH failure) → fail fast, as the old
        // scan-error path did; a reachable-but-empty target deploys via `.direct`.
        if (!outcome.reachable) {
            outcome.deinit(allocator);
            return .failed;
        }
        const tgt = job.target.clone(allocator) catch {
            outcome.deinit(allocator);
            return .failed;
        };
        const name = allocator.dupe(u8, job.name) catch {
            outcome.deinit(allocator);
            var t = tgt;
            t.deinit(allocator);
            return .failed;
        };
        var src_hash: ?[]u8 = null;
        if (job.src_hash) |h| {
            src_hash = allocator.dupe(u8, h) catch {
                outcome.deinit(allocator);
                var t = tgt;
                t.deinit(allocator);
                allocator.free(name);
                return .failed;
            };
        }
        const rows = outcome.rows;
        outcome.rows = &.{};
        return .{ .deploy_scan = .{ .target = tgt, .name = name, .src_hash = src_hash, .rows = rows } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillDeployScanJob = @ptrCast(@alignCast(ctx));
        job.target.deinit(allocator);
        allocator.free(job.root_expr);
        if (job.local_path) |p| allocator.free(p);
        allocator.free(job.name);
        if (job.src_hash) |h| allocator.free(h);
        allocator.destroy(job);
    }
};

/// Background op: run a transfer (library ⇆ target), capturing a stderr summary.
const SkillTransferJob = struct {
    is_import: bool,
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool,
    lib_root: []u8, // owned shell expr (POSIX path)
    tgt_root: []u8, // owned shell expr (POSIX path)
    tgt_is_local: bool,
    name: []u8, // owned
    lib_path: []u8, // owned raw absolute library root (native path)
    tgt_path: ?[]u8, // owned raw absolute target root when local; null when remote
    tgt_software: skill_center.Software, // for resolving the remote root natively

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillTransferJob = @ptrCast(@alignCast(ctx));
        var tctx = SkillTransferCtx{ .conn = job.conn, .is_wsl = job.is_wsl };
        const ok = if (job.is_wsl)
            wslSkillTransfer(allocator, job, &tctx)
        else if (remote_file.localPosixExecSupported()) blk: {
            // POSIX local host: the proven tar-over-scp dance (Linux/macOS).
            const lib_ep = skill_transfer.Endpoint{ .root_expr = job.lib_root, .is_local = true };
            const tgt_ep = skill_transfer.Endpoint{ .root_expr = job.tgt_root, .is_local = job.tgt_is_local };
            const from = if (job.is_import) tgt_ep else lib_ep;
            const to = if (job.is_import) lib_ep else tgt_ep;
            break :blk skill_transfer.transfer(allocator, tctx.ops(), from, to, job.name) == .ok;
        } else nativeSkillTransfer(allocator, job, &tctx);
        var summary: ?[]u8 = null;
        if (!ok) {
            if (tctx.lastErr()) |s| summary = allocator.dupe(u8, s) catch null;
        }
        return .{ .transfer = .{ .is_import = job.is_import, .ok = ok, .err_summary = summary } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillTransferJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.lib_root);
        allocator.free(job.tgt_root);
        allocator.free(job.name);
        allocator.free(job.lib_path);
        if (job.tgt_path) |p| allocator.free(p);
        allocator.destroy(job);
    }
};

/// Transfer a skill to/from the default WSL distro. Both endpoints are visible
/// to a single `wsl.exe` shell — the library on the Windows filesystem reached
/// at `/mnt/<drive>/…`, the target under `$HOME` — so the whole transfer runs
/// inside WSL with no host↔guest file copy: tar-create + extract over `wslExec`
/// (see `SkillTransferCtx` and the both-remote case of `skill_transfer`).
/// `job.lib_path` is a native Windows path that must be converted to its guest
/// `/mnt` form before `tar -C` can read it. Returns true on full success.
fn wslSkillTransfer(allocator: std.mem.Allocator, job: *SkillTransferJob, tctx: *SkillTransferCtx) bool {
    const guest_lib = (platform_wsl.hostPathToGuestPathAlloc(allocator, job.lib_path) catch null) orelse {
        tctx.noteErr("library is not on a mounted drive");
        return false;
    };
    defer allocator.free(guest_lib);
    const lib_root = skill_transfer_cmd.absRootExpr(allocator, guest_lib) catch return false;
    defer allocator.free(lib_root);

    // Both endpoints remote (is_local = false) → skill_transfer skips its copy
    // primitive and runs tar-create + extract entirely over wslExec.
    const lib_ep = skill_transfer.Endpoint{ .root_expr = lib_root, .is_local = false };
    const tgt_ep = skill_transfer.Endpoint{ .root_expr = job.tgt_root, .is_local = false };
    const from = if (job.is_import) tgt_ep else lib_ep;
    const to = if (job.is_import) lib_ep else tgt_ep;
    return skill_transfer.transfer(allocator, tctx.ops(), from, to, job.name) == .ok;
}

/// Transfer a skill without a POSIX shell (native Windows, no WSL):
///   - local↔local: a native `std.fs` directory copy with atomic swap.
///   - local↔remote: `scp -r` to/from a staging dir + an SSH stage/swap, so the
///     local side never needs `tar` or a `/tmp` path. The remote side stays
///     POSIX (its `mkdir`/`mv` run over SSH). Returns true on full success.
fn nativeSkillTransfer(allocator: std.mem.Allocator, job: *SkillTransferJob, tctx: *SkillTransferCtx) bool {
    if (job.conn == null) {
        const tgt_path = job.tgt_path orelse {
            tctx.noteErr("could not resolve target path");
            return false;
        };
        const src = if (job.is_import) tgt_path else job.lib_path;
        const dst = if (job.is_import) job.lib_path else tgt_path;
        skill_local_fs.transferLocalToLocal(allocator, src, dst, job.name) catch {
            tctx.noteErr("local copy failed");
            return false;
        };
        return true;
    }
    var conn = job.conn.?;
    if (job.is_import) return nativeImportFromRemote(allocator, job, &conn, tctx);
    return nativeDeployToRemote(allocator, job, &conn, tctx);
}

/// Resolve the target's ABSOLUTE skills root on the remote (e.g.
/// `/home/user/.claude/skills`) by asking the remote shell to expand `$HOME`.
/// scp must be handed a literal path: its default (SFTP) protocol does NOT
/// shell-expand a `"$HOME"`/quoted remote spec — passing the shell expression
/// would only work via the legacy `-O` fallback on a POSIX login shell, which
/// breaks on modern Windows OpenSSH (SFTP default) and non-POSIX login shells.
/// Caller frees. Null if the home can't be resolved.
fn resolveRemoteSkillRoot(
    allocator: std.mem.Allocator,
    conn: *const ssh_connection.SshConnection,
    software: skill_center.Software,
) ?[]u8 {
    const home = remote_file.sshExecCapture(allocator, conn.*, "printf %s \"$HOME\"") catch return null;
    defer allocator.free(home);
    const trimmed = std.mem.trim(u8, home, " \t\r\n");
    if (trimmed.len == 0) return null;
    // POSIX remote path → always '/' separators, never std.fs.path.join.
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, software.rootRel() }) catch null;
}

/// Deploy the library skill to a remote target via `scp -r` (no local tar).
fn nativeDeployToRemote(
    allocator: std.mem.Allocator,
    job: *SkillTransferJob,
    conn: *const ssh_connection.SshConnection,
    tctx: *SkillTransferCtx,
) bool {
    const abs_root = resolveRemoteSkillRoot(allocator, conn, job.tgt_software) orelse {
        tctx.noteErr("could not resolve remote home");
        return false;
    };
    defer allocator.free(abs_root);
    const root_expr = skill_transfer_cmd.absRootExpr(allocator, abs_root) catch return false;
    defer allocator.free(root_expr);

    const prep = skill_transfer_cmd.remoteStagePrepCmd(allocator, root_expr) catch return false;
    defer allocator.free(prep);
    if (!SkillTransferCtx.remoteExec(tctx, allocator, prep)) return false;

    const local_src = std.fs.path.join(allocator, &.{ job.lib_path, job.name }) catch return false;
    defer allocator.free(local_src);
    // Clean absolute remote path for scp (works under both the SFTP-default and
    // legacy protocols); the ssh prep above created exactly this dir.
    const remote_stage = std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_root, skill_transfer_cmd.XFER_STAGING }) catch return false;
    defer allocator.free(remote_stage);
    var spec_buf: [512]u8 = undefined;
    const dst_spec = scp.remoteSpec(&spec_buf, conn, remote_stage);
    var control: scp.TransferControl = .{};
    if (scp.transferDirWithControl(allocator, conn, local_src, dst_spec, &control) != .ok) {
        tctx.noteErr("scp upload failed");
        return false;
    }

    const swap = skill_transfer_cmd.remoteStageSwapCmd(allocator, root_expr, job.name) catch return false;
    defer allocator.free(swap);
    return SkillTransferCtx.remoteExec(tctx, allocator, swap);
}

/// Import a remote skill into the library via `scp -r` into a local staging dir,
/// then a native atomic swap.
fn nativeImportFromRemote(
    allocator: std.mem.Allocator,
    job: *SkillTransferJob,
    conn: *const ssh_connection.SshConnection,
    tctx: *SkillTransferCtx,
) bool {
    const abs_root = resolveRemoteSkillRoot(allocator, conn, job.tgt_software) orelse {
        tctx.noteErr("could not resolve remote home");
        return false;
    };
    defer allocator.free(abs_root);

    skill_local_fs.ensureDirAbsolute(job.lib_path) catch {
        tctx.noteErr("library dir unavailable");
        return false;
    };
    const staging = std.fs.path.join(allocator, &.{ job.lib_path, skill_transfer_cmd.XFER_STAGING }) catch return false;
    defer allocator.free(staging);
    std.fs.deleteTreeAbsolute(staging) catch {};
    skill_local_fs.ensureDirAbsolute(staging) catch {
        tctx.noteErr("local staging failed");
        return false;
    };
    defer std.fs.deleteTreeAbsolute(staging) catch {};

    // Clean absolute remote source path for scp (SFTP-default safe).
    const remote_src = std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_root, job.name }) catch return false;
    defer allocator.free(remote_src);
    var spec_buf: [512]u8 = undefined;
    const src_spec = scp.remoteSpec(&spec_buf, conn, remote_src);
    var control: scp.TransferControl = .{};
    if (scp.transferDirWithControl(allocator, conn, src_spec, staging, &control) != .ok) {
        tctx.noteErr("scp download failed");
        return false;
    }

    const staged_skill = std.fs.path.join(allocator, &.{ staging, job.name }) catch return false;
    defer allocator.free(staged_skill);
    const final = std.fs.path.join(allocator, &.{ job.lib_path, job.name }) catch return false;
    defer allocator.free(final);
    std.fs.deleteTreeAbsolute(final) catch {};
    std.fs.renameAbsolute(staged_skill, final) catch {
        tctx.noteErr("local install failed");
        return false;
    };
    return true;
}

/// Background op: read one skill's SKILL.md (local or via ssh) for preview.
const SkillPreviewJob = struct {
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool,
    name: []u8, // owned — becomes the preview title
    cmd: []u8, // owned — `cat <root>/'<name>'/'SKILL.md'`
    local_md_path: ?[]u8, // owned absolute SKILL.md path for a LOCAL target (native read)

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillPreviewJob = @ptrCast(@alignCast(ctx));
        // Local target on a non-POSIX host (Windows): read SKILL.md natively;
        // `cat` via localPosixExec is unavailable. Remote/posix/WSL use the shell
        // cmd (WSL via `wsl.exe`, see SkillLocExec).
        const content = if (job.conn == null and !job.is_wsl and !remote_file.localPosixExecSupported()) blk: {
            const p = job.local_md_path orelse return .failed;
            break :blk skill_local_fs.readFileAllocAbsolute(allocator, p, 1024 * 1024) catch return .failed;
        } else blk: {
            var le = SkillLocExec{ .conn = job.conn, .is_wsl = job.is_wsl };
            const host = le.host();
            break :blk host.exec(host.ctx, allocator, job.cmd) catch return .failed;
        };
        const title = allocator.dupe(u8, job.name) catch {
            allocator.free(content);
            return .failed;
        };
        return .{ .preview = .{ .title = title, .content = content } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillPreviewJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.name);
        allocator.free(job.cmd);
        if (job.local_md_path) |p| allocator.free(p);
        allocator.destroy(job);
    }
};

/// Background op: parse the URL, resolve the default branch if absent, fetch the
/// Git Trees response, and enumerate skills for the checklist.
const SkillInstallEnumerateJob = struct {
    url: []u8, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillInstallEnumerateJob = @ptrCast(@alignCast(ctx));
        var repo = skill_install.parseGithubUrl(allocator, job.url) catch return .failed;
        // NB: `enumerate` is error-returning so `errdefer` fires on every failure
        // path below (the bare `return .failed` of the plan's code would leak
        // `repo` because a value-return does not trigger errdefer).
        return enumerate(allocator, &repo) catch {
            repo.deinit(allocator);
            return .failed;
        };
    }
    fn enumerate(allocator: std.mem.Allocator, repo: *skill_install.RepoRef) !skill_center.OpResult {
        // Resolve the ref if the URL had none.
        if (repo.ref == null) {
            repo.ref = resolveDefaultBranch(allocator, repo.owner, repo.repo) catch
                try allocator.dupe(u8, "main");
        }

        const api = try skill_install.treeApiUrl(allocator, repo.owner, repo.repo, repo.ref.?);
        defer allocator.free(api);
        const json = try update_install.httpGetAlloc(allocator, api, 8 * 1024 * 1024);
        defer allocator.free(json);

        const res = try skill_install.findSkills(allocator, json, repo.subpath);
        return .{ .install_enumerate = .{ .repo = repo.*, .entries = res.entries, .truncated = res.truncated } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillInstallEnumerateJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.url);
        allocator.destroy(job);
    }
};

/// Background op: download + install the selected skills into the library.
const SkillInstallDownloadJob = struct {
    repo: skill_install.RepoRef, // owned
    entries: []skill_install.SkillEntry, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillInstallDownloadJob = @ptrCast(@alignCast(ctx));
        const r = downloadSelectedSkillsToLibrary(allocator, job.repo, job.entries);
        return .{ .install_done = .{ .installed = r.installed, .overwritten = r.overwritten, .failed = r.failed } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillInstallDownloadJob = @ptrCast(@alignCast(ctx));
        job.repo.deinit(allocator);
        skill_install.freeEntries(allocator, job.entries);
        allocator.destroy(job);
    }
};

/// Best-effort default-branch resolution. Tries the repo API's `default_branch`,
/// then falls back to "master" (the caller defaults to "main" on total failure).
fn resolveDefaultBranch(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8) ![]u8 {
    const api = try skill_install.repoApiUrl(allocator, owner, repo);
    defer allocator.free(api);
    const json = update_install.httpGetAlloc(allocator, api, 1024 * 1024) catch return allocator.dupe(u8, "master");
    defer allocator.free(json);
    return skill_install.parseDefaultBranch(allocator, json) catch allocator.dupe(u8, "master");
}

/// Kick off an async library scan for `session`. UI thread.
fn startSkillCenterScan(allocator: std.mem.Allocator, session: *skill_center.Session) void {
    const lib_dir = skillCenterLibraryDir(allocator) orelse {
        session.publishScanFailure(session.scan_generation);
        return;
    };
    defer allocator.free(lib_dir);
    const root_expr = skill_transfer_cmd.absRootExpr(allocator, lib_dir) catch {
        session.publishScanFailure(session.scan_generation);
        return;
    };
    const local_path = allocator.dupe(u8, lib_dir) catch {
        allocator.free(root_expr);
        session.publishScanFailure(session.scan_generation);
        return;
    };
    const tools_root = platform_dirs.toolsDir(allocator) catch {
        allocator.free(root_expr);
        allocator.free(local_path);
        session.publishScanFailure(session.scan_generation);
        return;
    };
    const job = allocator.create(SkillLibraryScanJob) catch {
        allocator.free(root_expr);
        allocator.free(local_path);
        allocator.free(tools_root);
        session.publishScanFailure(session.scan_generation);
        return;
    };
    job.* = .{ .root_expr = root_expr, .local_path = local_path, .tools_root = tools_root };
    session.scanAsync(.{ .ctx = job, .run = SkillLibraryScanJob.run, .destroy = SkillLibraryScanJob.destroy });
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

pub fn aiHistoryHandleMousePress(xpos: f64, ypos: f64) bool {
    const session = activeAiHistory() orelse return false;
    const win = g_window orelse return true;
    const fb = window_backend.framebufferSize(win);
    const left = leftPanelsWidth();
    const right = rightPanelsWidthForWindow(fb.width);
    const width = @as(f32, @floatFromInt(fb.width)) - left - right;
    const visible_rows = ai_history_renderer.listVisibleCapacity(@floatFromInt(fb.height), currentTitlebarHeight(), font.g_titlebar_cell_height);

    session.mutex.lock();
    const hit = ai_history_renderer.interactionHitTest(
        session,
        @floatFromInt(fb.width),
        @floatFromInt(fb.height),
        currentTitlebarHeight(),
        left,
        width,
        font.g_titlebar_cell_height,
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
    g_force_rebuild = true;
    g_cells_valid = false;
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
    return ai_history_renderer.listVisibleCapacity(@floatFromInt(fb.height), currentTitlebarHeight(), font.g_titlebar_cell_height);
}

/// Number of day rows (excluding the pinned "All dates") visible in the DATE
/// navigator, used to keep the Filters cursor's day in view.
fn aiHistoryDateDaySlotsForWindow() usize {
    const win = g_window orelse return 0;
    const fb = window_backend.framebufferSize(win);
    const cell_h = font.g_titlebar_cell_height;
    const lc = ai_history_renderer.leftColumnLayout(currentTitlebarHeight(), cell_h);
    const cap = ai_history_renderer.dateVisibleCapacity(@floatFromInt(fb.height), lc.date_rows_top, cell_h);
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

pub fn exportActiveAiChatMarkdown(mode: ai_chat.MarkdownExportMode) void {
    const allocator = g_allocator orelse return;
    const session = activeAiChat() orelse {
        overlays.showStatusToast("Open a Copilot tab first");
        return;
    };

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

pub fn currentTitlebarHeight() f32 {
    if (g_window) |w| return @floatFromInt(window_backend.titlebarHeight(w));
    return titlebar.titlebarHeight();
}

pub fn leftPanelsWidth() f32 {
    return titlebar.sidebarWidth() + file_explorer.width();
}

pub fn aiCopilotVisible() bool {
    return tab.activeCopilotVisible();
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
    if (!tab.setActiveCopilotVisible(false)) return;
    input.blurAiCopilot();
    g_force_rebuild = true;
    g_cells_valid = false;
}

pub fn aiCopilotWidth(window_width: i32) f32 {
    if (!aiCopilotVisible()) return 0;
    return ai_sidebar.panelWidthForWindow(window_width, leftPanelsWidth(), 0);
}

fn makeCopilotSession() ?*ai_chat.Session {
    return overlays.makeCopilotSessionForDefaultProfile();
}

fn ensureActiveCopilotSession() ?*ai_chat.Session {
    const session = tab.activeCopilotSession(makeCopilotSession) orelse return null;
    if (g_agent_context_surface_id_len > 0) {
        session.setBoundSurface(g_agent_context_surface_id[0..g_agent_context_surface_id_len]);
    }
    return session;
}

/// Input layer getter: the active terminal tab's copilot session, only when the
/// copilot panel is visible. Used by input routing (next task).
pub fn activeCopilotSessionForInput() ?*ai_chat.Session {
    if (!aiCopilotVisible()) return null;
    const t = tab.activeTab() orelse return null;
    return t.copilot_session;
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
    if (!isActiveTabTerminal()) return; // copilot is terminal-only
    if (tab.activeCopilotVisible()) {
        _ = tab.setActiveCopilotVisible(false);
        input.blurAiCopilot();
        g_force_rebuild = true;
        g_cells_valid = false;
        return;
    }
    // Exclusive right slot: close the other right panels first.
    browser_panel.close();
    _ = tab.setActiveCopilotVisible(true);
    _ = ensureActiveCopilotSession();
    input.focusAiCopilot();
    if (g_allocator) |alloc| platform_window_state.setCopilotHintShown(alloc);
    g_force_rebuild = true;
    g_cells_valid = false;
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

fn saveMarkdownDialogPath(
    allocator: std.mem.Allocator,
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
        .title = "Save Copilot Markdown",
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
    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
        return;
    }

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
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
        @memcpy(g_agent_context_surface_id[0..], s.remote_id[0..]);
        g_agent_context_surface_id_len = s.remote_id.len;
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
    g_force_rebuild = true;
    g_cells_valid = false;
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

    const store = try allocator.create(agent_history.Store);
    errdefer allocator.destroy(store);
    store.* = try agent_history.loadDefault(allocator);
    g_agent_history = store;
    g_flush_scheduler.reset();
    g_agent_history_revision = 0;
}

fn installSessionRestoreHooks() void {
    // AppWindow owns the stores needed to rebuild non-terminal tab kinds, so
    // tab.zig routes persisted AI snapshots back through these hooks.
    tab.g_ai_restore_hook = reopenAiChatTabFromHistorySessionId;
    tab.g_ai_history_restore_hook = reopenAiHistoryTabFromSnapshot;
    // tmux session persistence (#4c): save the active tmux profile names; on
    // restore, re-attach each via the launcher's tmux connect path.
    tab.g_tmux_active_profiles_hook = tmux_controller.activeProfileNames;
    tab.g_tmux_restore_hook = overlays.connectProfileByNameTmux;
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
        if (tab_state.kind != .ai_chat) continue;
        const session = tab_state.ai_chat_session orelse continue;

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
    var json: ?[]u8 = null;
    var path: ?[]const u8 = null;
    var snapshot_allocator: ?std.mem.Allocator = null;

    g_agent_history_mutex.lock();
    if (!g_flush_scheduler.shouldFlush(force, now)) {
        g_agent_history_mutex.unlock();
        return;
    }

    const store = g_agent_history orelse {
        g_agent_history_mutex.unlock();
        return;
    };
    snapshot_allocator = store.allocator;
    json = store.toJsonString(store.allocator) catch |err| {
        log.warn("failed to snapshot agent history store for flush: {}", .{err});
        g_flush_scheduler.deferFlush(now);
        g_agent_history_mutex.unlock();
        return;
    };
    path = agent_history.defaultPath(store.allocator) catch |err| {
        log.warn("failed to resolve agent history path for flush: {}", .{err});
        store.allocator.free(json.?);
        g_flush_scheduler.deferFlush(now);
        g_agent_history_mutex.unlock();
        return;
    };
    g_flush_scheduler.beginFlush();
    g_agent_history_mutex.unlock();

    agent_history.saveJsonToPath(path.?, json.?) catch |err| {
        log.warn("failed to flush agent history store: {}", .{err});
        g_agent_history_mutex.lock();
        g_flush_scheduler.failFlush(std.time.milliTimestamp());
        snapshot_allocator.?.free(path.?);
        snapshot_allocator.?.free(json.?);
        g_agent_history_mutex.unlock();
        return;
    };

    g_agent_history_mutex.lock();
    snapshot_allocator.?.free(path.?);
    snapshot_allocator.?.free(json.?);
    g_agent_history_mutex.unlock();
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
pub fn startTmuxSession(ssh_cmd: []const u8, password: []const u8, profile_name: []const u8, ssh_conn: ?@import("ssh_connection.zig").SshConnection) bool {
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

    // No AI profile yet: surface the profile-creation form so the user can set one
    // up (the form is an overlay, not a tab) — but only on the first launch. After
    // it has been shown once, the persisted flag suppresses it so it does not
    // reappear every launch. Users can still open setup via the session launcher.
    if (startup_tabs.shouldAutoShowAgentForm(has_ai_profile, platform_window_state.aiSetupPrompted(allocator))) {
        _ = overlays.openDefaultAgentSessionForStartup();
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
) bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnAiChatTab(allocator, name, base_url, api_key, model, protocol, system_prompt, thinking, reasoning_effort, stream_val, agent_val, max_tokens, vision_val)) return false;
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
                overlays.scheduleSshPasswordForSurface(surface, pw);
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
/// One-shot per window thread: the first present that returns settles the
/// D3D bring-up crash fuse (the process survived presenter bring-up, so the
/// "probing" state-file marker can be removed). No-op off-Windows and when
/// no marker exists.
threadlocal var g_present_bringup_settled: bool = false;

pub threadlocal var window_focused: bool = true; // Track window focus state

// Window state persistence.
const loadWindowState = platform_window_state.loadWindowState;
const saveWindowGeometry = platform_window_state.saveWindowGeometry;
const loadQuakeFrame = platform_window_state.loadQuakeFrame;
const saveQuakeFrame = platform_window_state.saveQuakeFrame;

// Pending resize state (resize is deferred to main loop to avoid PageList integrity issues)
// Ghostty coalesces resize events with a 25ms timer to batch rapid resizes
pub threadlocal var g_pending_resize: bool = false;
pub threadlocal var g_pending_cols: u16 = 0;
pub threadlocal var g_pending_rows: u16 = 0;
pub threadlocal var g_last_resize_time: i64 = 0;
const RESIZE_COALESCE_MS: i64 = 25; // Same as Ghostty

// One-shot layout changes such as opening a browser panel or creating a split
// should not wait for the drag/window-resize coalescing timer.
pub threadlocal var g_layout_resize_immediate: bool = false;

pub fn requestImmediateLayoutResize() void {
    g_layout_resize_immediate = true;
}

pub fn consumeImmediateLayoutResize() bool {
    const immediate = g_layout_resize_immediate;
    g_layout_resize_immediate = false;
    return immediate;
}

pub threadlocal var g_cursor_style: CursorStyle = .block; // Default cursor style
pub threadlocal var g_cursor_blink: bool = true; // Whether cursor should blink (default: true like Ghostty)
pub threadlocal var g_cursor_blink_visible: bool = true; // Current blink state (toggled by timer)
pub threadlocal var g_last_blink_time: i64 = 0; // Timestamp of last blink toggle
const CURSOR_BLINK_INTERVAL_MS: i64 = 600; // Blink interval in ms (same as Ghostty)

const ConfigWatcher = @import("config_watcher.zig");

// GL init, render helpers — see renderer/gpu/opengl/gl_init.zig (GLSL sources
// in renderer/gpu/opengl/shaders.zig); exposed via AppWindow.gpu.gl_init.

/// Focus follows mouse - when true, moving mouse into a split pane focuses it
pub threadlocal var g_focus_follows_mouse: bool = false;
threadlocal var g_agent_context_surface_id: [16]u8 = undefined;
threadlocal var g_agent_context_surface_id_len: usize = 0;
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
                g_pending_resize,
                window_backend.isMaximized(w),
                window_backend.isFullscreen(w),
            },
        );
    } else {
        render_diagnostics.log(
            "platform-resize begin arg={}x{} no-window font_dpi={} cell={d:.2}x{d:.2} term={}x{} pending={}",
            .{ width, height, font.g_dpi, font.cell_width, font.cell_height, term_cols, term_rows, g_pending_resize },
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
        g_pending_resize = false;
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
        if (g_allocator) |alloc| syncRemoteLayout(alloc);

        // A lone PREVIEW pane has no terminal surface and must take the generic
        // split path below so it still paints (preview-only tabs are legal).
        if (split_count == 0 or split_layout.soleTerminalSurface() != null) {
            if (active_tab.kind == .ai_chat) {
                renderAiChatFrame(fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (active_tab.kind == .ai_history) {
                renderAiHistoryFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
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
                gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
            gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
                        gpu.gl_init.setProjection(@floatFromInt(rect.width), @floatFromInt(rect.height));

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
                        gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
            gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
            overlays.renderSplitDividers(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
            overlays.renderPaneAgentDots(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
        }
    } else {
        gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
        gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
    overlays.renderSettingsPage(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderSessionLauncher(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    weixin_qr_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderDebugOverlay(@floatFromInt(fb_width));
    overlays.renderCloseShortcutConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderCopyToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderTransferToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderTransferCancelConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderUpdatePrompt(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderWindowCloseConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderRestoreDefaultsConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderWhatsNew(@floatFromInt(fb_width), @floatFromInt(fb_height));

    render_diagnostics.log(
        "platform-resize swap fb={}x{} term={}x{} draw_calls={}",
        .{ fb_width, fb_height, term_cols, term_rows, gpu.gl_init.g_draw_call_count },
    );
    forceOpaqueBackbufferForPresent();
    if (g_window) |w| window_backend.swapBuffers(w);
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
                .direct => skillCenterRunTransfer(allocator, false, v.target, v.name),
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
    if (notification.seq == g_last_transfer_notification_seq) return;
    g_last_transfer_notification_seq = notification.seq;
    overlays.showTransferToast(notification.kind, notification.status, notification.message);
    g_force_rebuild = true;
    g_cells_valid = false;
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
    ai_chat.setDefaultWorkingDir(cfg.@"ai-agent-working-dir");
    overlays.setSubagentProfileName(cfg.@"ai-subagent-profile");
    @import("web_search.zig").setJinaApiKey(cfg.@"jina-api-key");
    @import("pty.zig").setConsoleHostPreference(cfg.@"windows-conpty");

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
        gpu.gl_init.g_bg_opacity = cfg.@"background-opacity";
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
        totals.terminal_page_bytes +
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
            "[memory] process private={d:.1}MiB ws={d:.1}MiB commit={d:.1}MiB peak_ws={d:.1}MiB tabs={} ai_tabs={} surfaces={} visible_surfaces={} terminal_pages={d:.1}/{d:.1}MiB min={d:.1}MiB renderer_cap={d:.1}MiB font_atlas(cpu/gpu)={d:.1}/{d:.1}MiB kitty_bytes(cpu/gpu)={d:.1}/{d:.1}MiB fbo={d:.1}MiB tracked_cpu={d:.1}MiB untracked_private~={d:.1}MiB faults={}\n",
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

fn syncRemoteLayout(allocator: std.mem.Allocator) void {
    const app = g_app orelse return;
    const client = app.remote_client orelse return;

    const now = std.time.milliTimestamp();
    if (now - g_remote_layout_last_ms < 250) return;
    g_remote_layout_last_ms = now;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    buildRemoteLayoutJson(allocator, &out) catch return;
    client.sendLayout(out.items);
}

fn appendAgentDetectionJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    surface: ?*const Surface,
) !void {
    const detection: agent_detector.Detection = if (surface) |s| s.agent_detection else .{};
    try out.appendSlice(allocator, ",\"agentApp\":\"");
    try remote.appendJsonString(out, allocator, detection.appLabel());
    try out.appendSlice(allocator, "\",\"agentState\":\"");
    try remote.appendJsonString(out, allocator, detection.stateLabel());
    try out.appendSlice(allocator, "\",\"agentBadge\":\"");
    try remote.appendJsonString(out, allocator, detection.badge());
    try out.appendSlice(allocator, "\",\"agentConfidence\":");
    try out.print(allocator, "{d}", .{detection.confidence});
}

fn buildRemoteLayoutJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "{\"type\":\"layout\",\"activeTab\":");
    try out.print(allocator, "{d}", .{active_tab_state.g_active_tab});
    try out.appendSlice(allocator, ",\"tabs\":[");

    var wrote_tab = false;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (wrote_tab) try out.append(allocator, ',');
        wrote_tab = true;

        if (tab_state.kind == .ai_chat) {
            try appendRemoteAiChatTabJson(allocator, out, tab_state, tab_index);
            continue;
        }
        if (tab_state.kind == .ai_history) {
            try appendRemoteAiHistoryTabJson(allocator, out, tab_state, tab_index);
            continue;
        }

        try out.appendSlice(allocator, "{\"index\":");
        try out.print(allocator, "{d}", .{tab_index});
        try out.appendSlice(allocator, ",\"title\":\"");
        try remote.appendJsonString(out, allocator, tab_state.getTitle());
        try out.appendSlice(allocator, "\",\"focusedSurfaceId\":\"");
        var focused_surface: ?*Surface = null;
        if (tab_state.focusedSurface()) |focused| {
            focused_surface = focused;
            try remote.appendJsonString(out, allocator, focused.remote_id[0..]);
        }
        try out.append(allocator, '"');
        try appendAgentDetectionJson(allocator, out, focused_surface);
        try out.appendSlice(allocator, ",\"surfaces\":[");

        var spatial = tab_state.tree.spatial(allocator) catch null;
        defer if (spatial) |*sp| sp.deinit(allocator);

        var wrote_surface = false;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (wrote_surface) try out.append(allocator, ',');
            wrote_surface = true;

            try out.appendSlice(allocator, "{\"id\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.remote_id[0..]);
            try out.appendSlice(allocator, "\",\"title\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.getTitle());
            try out.appendSlice(allocator, "\",\"focused\":");
            try out.appendSlice(allocator, if (entry.handle == tab_state.focused) "true" else "false");
            try appendAgentDetectionJson(allocator, out, entry.surface);
            try out.appendSlice(allocator, ",\"cols\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.cols});
            try out.appendSlice(allocator, ",\"rows\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.rows});
            var cursor_x: usize = 0;
            var cursor_y: usize = 0;
            {
                entry.surface.render_state.mutex.lock();
                defer entry.surface.render_state.mutex.unlock();
                cursor_x = entry.surface.terminal.screens.active.cursor.x;
                cursor_y = entry.surface.terminal.screens.active.cursor.y;
            }
            try out.appendSlice(allocator, ",\"cursorX\":");
            try out.print(allocator, "{d}", .{cursor_x});
            try out.appendSlice(allocator, ",\"cursorY\":");
            try out.print(allocator, "{d}", .{cursor_y});
            try out.appendSlice(allocator, ",\"snapshot\":\"");
            const snapshot = buildRemoteSurfaceSnapshot(allocator, entry.surface, remote_snapshot.default_max_history_rows) catch null;
            defer if (snapshot) |text| allocator.free(text);
            if (snapshot) |text| try remote.appendJsonString(out, allocator, text);
            try out.append(allocator, '"');

            if (spatial) |sp| {
                const slot = sp.slots[entry.handle.idx()];
                try out.appendSlice(allocator, ",\"x\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.x))});
                try out.appendSlice(allocator, ",\"y\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.y))});
                try out.appendSlice(allocator, ",\"w\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.width))});
                try out.appendSlice(allocator, ",\"h\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.height))});
            } else {
                try out.appendSlice(allocator, ",\"x\":0,\"y\":0,\"w\":1,\"h\":1");
            }

            try out.append(allocator, '}');
        }

        try out.appendSlice(allocator, "]}");
    }

    try out.appendSlice(allocator, "]}");
}

/// Lightweight panes listing for the agent-control API. Mirrors
/// buildRemoteLayoutJson's terminal branch but omits the heavy per-surface
/// scrollback snapshot (that is get-text's job) and adds the surface cwd.
/// Non-terminal tabs (AI chat / history / etc.) appear as a minimal entry so
/// the listing is complete. UI-thread only (reads threadlocal tab state).
fn buildCtlPanesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "{\"activeTab\":");
    try out.print(allocator, "{d}", .{active_tab_state.g_active_tab});
    try out.appendSlice(allocator, ",\"tabs\":[");

    var wrote_tab = false;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (wrote_tab) try out.append(allocator, ',');
        wrote_tab = true;

        if (tab_state.kind != .terminal) {
            try out.appendSlice(allocator, "{\"index\":");
            try out.print(allocator, "{d}", .{tab_index});
            try out.appendSlice(allocator, ",\"title\":\"");
            try remote.appendJsonString(out, allocator, tab_state.getTitle());
            try out.appendSlice(allocator, "\",\"kind\":\"");
            try remote.appendJsonString(out, allocator, @tagName(tab_state.kind));
            try out.appendSlice(allocator, "\",\"surfaces\":[]}");
            continue;
        }

        try out.appendSlice(allocator, "{\"index\":");
        try out.print(allocator, "{d}", .{tab_index});
        try out.appendSlice(allocator, ",\"title\":\"");
        try remote.appendJsonString(out, allocator, tab_state.getTitle());
        try out.appendSlice(allocator, "\",\"kind\":\"terminal\",\"focusedSurfaceId\":\"");
        if (tab_state.focusedSurface()) |focused|
            try remote.appendJsonString(out, allocator, focused.remote_id[0..]);
        try out.appendSlice(allocator, "\",\"surfaces\":[");

        var spatial = tab_state.tree.spatial(allocator) catch null;
        defer if (spatial) |*sp| sp.deinit(allocator);

        var wrote_surface = false;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (wrote_surface) try out.append(allocator, ',');
            wrote_surface = true;

            try out.appendSlice(allocator, "{\"id\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.remote_id[0..]);
            try out.appendSlice(allocator, "\",\"title\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.getTitle());
            try out.appendSlice(allocator, "\",\"focused\":");
            try out.appendSlice(allocator, if (entry.handle == tab_state.focused) "true" else "false");
            try appendAgentDetectionJson(allocator, out, entry.surface);
            try out.appendSlice(allocator, ",\"cols\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.cols});
            try out.appendSlice(allocator, ",\"rows\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.rows});
            var cx: usize = 0;
            var cy: usize = 0;
            {
                entry.surface.render_state.mutex.lock();
                defer entry.surface.render_state.mutex.unlock();
                cx = entry.surface.terminal.screens.active.cursor.x;
                cy = entry.surface.terminal.screens.active.cursor.y;
            }
            try out.appendSlice(allocator, ",\"cursorX\":");
            try out.print(allocator, "{d}", .{cx});
            try out.appendSlice(allocator, ",\"cursorY\":");
            try out.print(allocator, "{d}", .{cy});
            try out.appendSlice(allocator, ",\"cwd\":\"");
            if (entry.surface.getCwd()) |cwd| try remote.appendJsonString(out, allocator, cwd);
            try out.append(allocator, '"');

            if (spatial) |sp| {
                const slot = sp.slots[entry.handle.idx()];
                try out.appendSlice(allocator, ",\"x\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.x))});
                try out.appendSlice(allocator, ",\"y\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.y))});
                try out.appendSlice(allocator, ",\"w\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.width))});
                try out.appendSlice(allocator, ",\"h\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.height))});
            } else {
                try out.appendSlice(allocator, ",\"x\":0,\"y\":0,\"w\":1,\"h\":1");
            }

            try out.append(allocator, '}');
        }

        try out.appendSlice(allocator, "]}");
    }

    try out.appendSlice(allocator, "]}");
}

fn remoteAiSurfaceId(tab_index: usize) [16]u8 {
    var id: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&id, "aichat{d:0>10}", .{tab_index}) catch unreachable;
    return id;
}

fn remoteAiHistorySurfaceId(tab_index: usize) [16]u8 {
    var id: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&id, "aihist{d:0>10}", .{tab_index}) catch unreachable;
    return id;
}

fn registerRemoteAiInputSink(tab_index: usize) void {
    const app = g_app orelse return;
    const client = app.remote_client orelse return;
    const window = g_window orelse return;
    if (tab_index >= g_remote_ai_sinks.len) return;

    g_remote_ai_sinks[tab_index] = .{
        .native_handle = window_backend.nativeHandle(window),
        .tab_index = tab_index,
    };
    client.registerSurface(remoteAiSurfaceId(tab_index), &g_remote_ai_sinks[tab_index], remoteAiWrite);
}

fn remoteAiWrite(ctx: *anyopaque, data: []const u8) void {
    const sink: *RemoteAiInputSink = @ptrCast(@alignCast(ctx));
    const request = std.heap.page_allocator.create(RemoteAiInputRequest) catch return;
    request.* = .{
        .tab_index = sink.tab_index,
        .data = std.heap.page_allocator.dupe(u8, data) catch {
            std.heap.page_allocator.destroy(request);
            return;
        },
    };

    const ok = thread_message.postPointer(sink.native_handle, .remote_ai_input, @intFromPtr(request));
    if (!ok) {
        std.heap.page_allocator.free(request.data);
        std.heap.page_allocator.destroy(request);
    }
}

fn remoteAiAgentOpen(ctx: *anyopaque, request_id: []const u8) void {
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

    var request = RemoteAiAgentOpenRequest{ .request_id = owned_request_id };
    const result = thread_message.sendPointer(target, .remote_open_ai_agent, @intFromPtr(&request));
    if (result == 0) {
        if (app.remote_client) |current_client| {
            current_client.sendAiAgentOpenResult(owned_request_id, .failed);
        }
    }
}

fn appendRemoteAiChatTabJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    tab_state: *tab.TabState,
    tab_index: usize,
) !void {
    registerRemoteAiInputSink(tab_index);
    const surface_id = remoteAiSurfaceId(tab_index);
    const title_text = tab_state.getTitle();

    try out.appendSlice(allocator, "{\"index\":");
    try out.print(allocator, "{d}", .{tab_index});
    try out.appendSlice(allocator, ",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focusedSurfaceId\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.append(allocator, '"');
    try appendAgentDetectionJson(allocator, out, null);
    try out.appendSlice(allocator, ",\"surfaces\":[{\"id\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.appendSlice(allocator, "\",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focused\":true");
    try appendAgentDetectionJson(allocator, out, null);
    try out.appendSlice(allocator, ",\"kind\":\"ai_chat\",\"readOnly\":false,\"cols\":120,\"rows\":30,\"cursorX\":0,\"cursorY\":0,\"snapshot\":\"");
    var request_state: ai_chat.Session.RequestState = .{ .inflight = false, .stopping = false };
    if (tab_state.ai_chat_session) |session| {
        request_state = session.requestState();
        const snapshot = session.allocRemoteSnapshot(allocator) catch null;
        defer if (snapshot) |text| allocator.free(text);
        if (snapshot) |text| try remote.appendJsonString(out, allocator, text);
    }
    try out.appendSlice(allocator, "\",\"requestInflight\":");
    try out.appendSlice(allocator, if (request_state.inflight) "true" else "false");
    try out.appendSlice(allocator, ",\"requestStopping\":");
    try out.appendSlice(allocator, if (request_state.stopping) "true" else "false");
    try out.appendSlice(allocator, ",\"x\":0,\"y\":0,\"w\":1,\"h\":1}]}");
}

fn appendRemoteAiHistoryTabJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    tab_state: *tab.TabState,
    tab_index: usize,
) !void {
    const surface_id = remoteAiHistorySurfaceId(tab_index);
    const title_text = tab_state.getTitle();

    try out.appendSlice(allocator, "{\"index\":");
    try out.print(allocator, "{d}", .{tab_index});
    try out.appendSlice(allocator, ",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focusedSurfaceId\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.append(allocator, '"');
    try appendAgentDetectionJson(allocator, out, null);
    try out.appendSlice(allocator, ",\"surfaces\":[{\"id\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.appendSlice(allocator, "\",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focused\":true");
    try appendAgentDetectionJson(allocator, out, null);
    // AI History is read-only in remote layouts. Keep it terminal-style so the
    // remote client does not show AI Chat composer/input affordances.
    try out.appendSlice(allocator, ",\"kind\":\"terminal\",\"readOnly\":true,\"cols\":120,\"rows\":30,\"cursorX\":0,\"cursorY\":0,\"snapshot\":\"Sessions\\n");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"x\":0,\"y\":0,\"w\":1,\"h\":1}]}");
}

fn handleRemoteAiInputRequest(request: *RemoteAiInputRequest) void {
    defer {
        std.heap.page_allocator.free(request.data);
        std.heap.page_allocator.destroy(request);
    }
    if (request.tab_index >= tab.g_tab_count) return;
    const tab_state = tab.g_tabs[request.tab_index] orelse return;
    if (tab_state.kind != .ai_chat) return;
    const session = tab_state.ai_chat_session orelse return;
    session.applyRemoteInput(request.data);
    g_force_rebuild = true;
}

fn handleRemoteAiAgentOpenRequest(request: *RemoteAiAgentOpenRequest) void {
    const app = g_app orelse return;
    const client = app.remote_client orelse return;

    const status: remote.AiAgentOpenStatus = switch (overlays.openDefaultAgentSessionForRemote()) {
        .opened => .opened,
        .no_profile => .no_profile,
        .failed => .failed,
    };
    client.sendAiAgentOpenResult(request.request_id, status);

    if (status == .opened) {
        g_remote_layout_last_ms = 0;
        if (g_allocator) |alloc| syncRemoteLayout(alloc);
    }
}

// ============================================================================
// WeChat direct (embedded ilink) — UI-thread control surface.
//
// The weixin poller runs on its own thread, but tab state (tab.g_tabs etc.) is
// threadlocal to the UI thread. So the Control vtable marshals each request to
// the UI thread via SendMessage (.weixin_control), where handleWeixinControlRequest
// reads/acts on tab state, mirroring the remote .remote_ai_input path.
//
// UNVERIFIED AT RUNTIME: cross-compiles to the Windows exe, but has not been run
// (no Windows runtime / live WeChat here). AI progress follow-up timers remain
// in the poller backlog; the UI control surface below exposes terminal writes
// and AI transcript snapshots for that layer.
// ============================================================================

var g_weixin_ui_handle = std.atomic.Value(usize).init(0);
var g_weixin_ctx: u8 = 0;
var g_weixin_transcript_mutex: std.Thread.Mutex = .{};
var g_weixin_transcript_owned: []u8 = &.{};
/// The AI conversation WeChat is pinned to (independent of the on-screen active
/// tab). UI-thread-only — read/written exclusively inside
/// handleWeixinControlRequest, so no lock is needed. Cleared automatically when
/// its conversation closes (see weixinActiveAiTabIndex).
var g_weixin_pinned_session: ?*ai_chat.Session = null;

const WeixinRequest = struct {
    op: enum { find_ai, find_term, open_ai, open_ai_profile, model_profiles, switch_ai_profile, send_input, latest_transcript, ai_approval_pending, resolve_ai_approval, ai_question_option_count, resolve_ai_question, inbound_file_dir, list_conversations, pin_by_index },
    // operation inputs (valid for the duration of the synchronous call):
    surface_id: [16]u8 = [_]u8{0} ** 16, // send_input
    bytes: []const u8 = "", // send_input
    reply_context: ?weixin_types.ReplyContext = null, // send_input
    profile_name: []const u8 = "", // open_ai_profile / switch_ai_profile
    approve: bool = false, // resolve_ai_approval
    // resolve_ai_question input. A `.custom` reply borrows the caller's bytes,
    // which stay alive because weixinDispatch is synchronous (SendMessage).
    question_reply: weixin_types.QuestionReply = .ignore,
    pin_index: usize = 0, // pin_by_index input
    conv_list_out: ?*weixin_control.ConversationList = null, // list_conversations output
    conv_one_out: ?*weixin_control.Conversation = null, // pin_by_index output
    // outputs filled by the UI-thread handler:
    found: bool = false,
    out_surface_id: [16]u8 = [_]u8{0} ** 16,
    open_result: weixin_control.OpenResult = .failed,
    switch_result: weixin_control.SwitchModelResult = .failed,
    sent: bool = false,
    busy: bool = false, // send_input: AI chat rejected the prompt (request inflight)
    option_count: usize = 0, // ai_question_option_count output
    transcript: []u8 = &.{},
    profiles: []u8 = &.{}, // model_profiles (heap, page_allocator)
    dir: []u8 = &.{}, // inbound_file_dir (heap, page_allocator)
};

/// The *ai_chat.Session a tab contributes as its AI conversation, or null:
/// a dedicated AI-chat tab's session, or a terminal tab's Copilot sidebar
/// session (once opened). A tab contributes at most one.
fn tabConversationSession(ts: *tab.TabState) ?*ai_chat.Session {
    if (ts.kind == .ai_chat) return ts.ai_chat_session;
    return ts.copilot_session;
}

/// Index of the AI-chat tab to target: the active tab if it is AI chat, else the
/// first AI-chat tab. UI-thread only (reads threadlocal tab state).
fn weixinActiveAiTabIndex() ?usize {
    // 1) Honor an explicit WeChat pin if its conversation is still open.
    //    Pointer identity only — never dereference a possibly-stale pointer.
    if (g_weixin_pinned_session) |pinned| {
        for (0..tab.g_tab_count) |i| {
            if (tab.g_tabs[i]) |ts| {
                if (tabConversationSession(ts) == pinned) return i;
            }
        }
        // The pinned conversation was closed: drop the stale pin and fall back.
        g_weixin_pinned_session = null;
    }
    // 2) Default (unchanged): the active tab if it is an AI-chat tab, else the
    //    first AI-chat tab. Copilot sidebars are reachable only via an explicit
    //    /switch pin, not the default.
    if (active_tab_state.g_active_tab < tab.g_tab_count) {
        if (tab.g_tabs[active_tab_state.g_active_tab]) |ts| {
            if (ts.kind == .ai_chat) return active_tab_state.g_active_tab;
        }
    }
    for (0..tab.g_tab_count) |i| {
        if (tab.g_tabs[i]) |ts| {
            if (ts.kind == .ai_chat) return i;
        }
    }
    return null;
}

fn weixinTabIndexFromSurfaceId(id: [16]u8) ?usize {
    if (!std.mem.eql(u8, id[0..6], "aichat")) return null;
    return std.fmt.parseInt(usize, id[6..16], 10) catch null;
}

fn weixinActiveTerminalSurface() ?*Surface {
    if (active_tab_state.g_active_tab < tab.g_tab_count) {
        if (tab.g_tabs[active_tab_state.g_active_tab]) |ts| {
            if (ts.kind == .terminal) {
                if (ts.focusedSurface()) |surface| return surface;
            }
        }
    }
    for (0..tab.g_tab_count) |i| {
        if (tab.g_tabs[i]) |ts| {
            if (ts.kind == .terminal) {
                if (ts.focusedSurface()) |surface| return surface;
            }
        }
    }
    return null;
}

fn weixinTerminalSurfaceFromId(id: [16]u8) ?*Surface {
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.surface.remote_id[0..], id[0..])) return entry.surface;
        }
    }
    return null;
}

/// Runs on the UI thread (dispatched from the window message pump).
fn handleWeixinControlRequest(req: *WeixinRequest) void {
    switch (req.op) {
        .find_ai => {
            if (weixinActiveAiTabIndex()) |idx| {
                req.out_surface_id = remoteAiSurfaceId(idx);
                req.found = true;
            }
        },
        .find_term => {
            if (weixinActiveTerminalSurface()) |surface| {
                req.out_surface_id = surface.remote_id;
                req.found = true;
            }
        },
        .open_ai => {
            req.open_result = switch (overlays.openDefaultAgentSessionForRemote()) {
                .opened => .opened,
                .no_profile => .no_profile,
                .failed => .failed,
            };
            if (req.open_result == .opened) g_force_rebuild = true;
        },
        .open_ai_profile => {
            req.open_result = switch (overlays.openAgentSessionForRemoteProfile(req.profile_name)) {
                .opened => .opened,
                .no_profile => .no_profile,
                .unknown_profile => .unknown_profile,
                .failed => .failed,
            };
            if (req.open_result == .opened) g_force_rebuild = true;
        },
        .model_profiles => {
            req.profiles = overlays.aiModelProfileList(std.heap.page_allocator) catch return;
            req.found = true;
        },
        .switch_ai_profile => {
            const idx = weixinActiveAiTabIndex() orelse {
                req.switch_result = .no_ai;
                return;
            };
            const tab_state = tab.g_tabs[idx] orelse {
                req.switch_result = .no_ai;
                return;
            };
            const session = tabConversationSession(tab_state) orelse {
                req.switch_result = .no_ai;
                return;
            };
            req.switch_result = switch (overlays.switchSessionModelByProfileName(session, req.profile_name)) {
                .switched => .switched,
                .no_profile => .no_profile,
                .unknown_profile => .unknown_profile,
                .failed => .failed,
            };
            if (req.switch_result == .switched) g_force_rebuild = true;
        },
        .send_input => {
            if (weixinTabIndexFromSurfaceId(req.surface_id)) |idx| {
                if (idx >= tab.g_tab_count) return;
                const tab_state = tab.g_tabs[idx] orelse return;
                // copilot_session is unreachable here in practice: aichat{N} surface
                // IDs are only issued for .ai_chat tabs. The fallthrough keeps this
                // correct if the surface registry is ever extended to Copilot panes.
                const session = tabConversationSession(tab_state) orelse return;
                if (req.reply_context) |ctx| {
                    req.busy = !session.applyWeixinInput(req.bytes, ctx);
                } else {
                    session.applyRemoteInput(req.bytes);
                }
                g_force_rebuild = true;
                req.sent = true;
                return;
            }
            const surface = weixinTerminalSurfaceFromId(req.surface_id) orelse return;
            surface.queuePtyWrite(req.bytes);
            req.sent = true;
        },
        .latest_transcript => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            req.transcript = session.allocRemoteSnapshot(std.heap.page_allocator) catch return;
            req.found = true;
        },
        .ai_approval_pending => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            req.found = session.approvalView() != null;
        },
        .resolve_ai_approval => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            req.sent = session.resolveApprovalExternal(req.approve);
            if (req.sent) g_force_rebuild = true;
        },
        .ai_question_option_count => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            if (session.questionView()) |view| {
                req.option_count = view.options.len;
                req.found = true;
            }
        },
        .resolve_ai_question => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
            req.sent = switch (req.question_reply) {
                .option => |i| session.resolveQuestionOption(i),
                .custom => |txt| session.resolveQuestionCustom(txt),
                .ignore => false,
            };
            if (req.sent) g_force_rebuild = true;
        },
        .inbound_file_dir => {
            // Per-conversation working dir if set, else the global default.
            if (weixinActiveAiTabIndex()) |idx| {
                if (tab.g_tabs[idx]) |tab_state| {
                    if (tabConversationSession(tab_state)) |session| {
                        if (session.workingDirOverride()) |w| {
                            req.dir = std.heap.page_allocator.dupe(u8, w) catch return;
                            req.found = true;
                            return;
                        }
                    }
                }
            }
            if (ai_chat.defaultWorkingDir()) |w| {
                req.dir = std.heap.page_allocator.dupe(u8, w) catch return;
                req.found = true;
            }
        },
        .list_conversations => {
            const out = req.conv_list_out orelse return;
            // Also clears g_weixin_pinned_session as a side effect if the pin is
            // stale (its conversation closed) — listing then correctly marks no
            // row current and drops the dead pin.
            const cur = weixinActiveAiTabIndex();
            var n: usize = 0;
            for (0..tab.g_tab_count) |i| {
                if (n >= out.items.len) break;
                const ts = tab.g_tabs[i] orelse continue;
                const session = tabConversationSession(ts) orelse continue;
                var c = &out.items[n];
                c.* = .{};
                c.is_copilot = (ts.kind != .ai_chat);
                c.is_current = (cur != null and cur.? == i);
                c.busy = session.request_inflight;
                c.setTitle(ts.getTitle());
                c.setModel(session.model());
                if (session.workingDirOverride()) |w| c.setCwd(w);
                n += 1;
            }
            out.count = n;
            req.found = true;
        },
        .pin_by_index => {
            const out = req.conv_one_out orelse return;
            var n: usize = 0;
            for (0..tab.g_tab_count) |i| {
                const ts = tab.g_tabs[i] orelse continue;
                const session = tabConversationSession(ts) orelse continue;
                if (n == req.pin_index) {
                    g_weixin_pinned_session = session;
                    out.* = .{};
                    out.is_copilot = (ts.kind != .ai_chat);
                    out.is_current = true;
                    out.busy = session.request_inflight;
                    out.setTitle(ts.getTitle());
                    out.setModel(session.model());
                    if (session.workingDirOverride()) |w| out.setCwd(w);
                    req.found = true;
                    return;
                }
                n += 1;
            }
        },
    }
}

/// Marshals a request to the UI thread synchronously. Returns false if no UI
/// window is currently published. Called from the poller thread.
fn weixinDispatch(req: *WeixinRequest) bool {
    const bits = g_weixin_ui_handle.load(.acquire);
    if (bits == 0) return false;
    const handle = window_backend.nativeHandleFromBits(bits) orelse return false;
    _ = thread_message.sendPointer(handle, .weixin_control, @intFromPtr(req));
    return true;
}

fn wxIsConnected(_: *anyopaque) bool {
    return g_weixin_ui_handle.load(.acquire) != 0;
}

fn wxFindAiSurface(_: *anyopaque) ?weixin_control.Surface {
    var req = WeixinRequest{ .op = .find_ai };
    if (!weixinDispatch(&req) or !req.found) return null;
    return .{ .id = req.out_surface_id, .title = "" };
}

fn wxFindTerminalSurface(_: *anyopaque) ?weixin_control.Surface {
    var req = WeixinRequest{ .op = .find_term };
    if (!weixinDispatch(&req) or !req.found) return null;
    return .{ .id = req.out_surface_id, .title = "" };
}

fn wxOpenAiAgent(_: *anyopaque, _: u32) weixin_control.OpenResult {
    var req = WeixinRequest{ .op = .open_ai };
    if (!weixinDispatch(&req)) return .offline;
    return req.open_result;
}

fn wxOpenAiAgentProfile(_: *anyopaque, profile_name: []const u8, _: u32) weixin_control.OpenResult {
    var req = WeixinRequest{ .op = .open_ai_profile, .profile_name = profile_name };
    if (!weixinDispatch(&req)) return .offline;
    return req.open_result;
}

fn wxModelProfiles(_: *anyopaque, buf: []u8) []const u8 {
    var req = WeixinRequest{ .op = .model_profiles };
    if (!weixinDispatch(&req) or !req.found) return "";
    defer if (req.profiles.len != 0) std.heap.page_allocator.free(req.profiles);
    const n = @min(req.profiles.len, buf.len);
    @memcpy(buf[0..n], req.profiles[0..n]);
    return buf[0..n];
}

fn wxSwitchAiProfile(_: *anyopaque, profile_name: []const u8) weixin_control.SwitchModelResult {
    var req = WeixinRequest{ .op = .switch_ai_profile, .profile_name = profile_name };
    if (!weixinDispatch(&req)) return .offline;
    return req.switch_result;
}

fn wxSendInput(_: *anyopaque, surface_id: [16]u8, bytes: []const u8, reply_context: ?weixin_types.ReplyContext) weixin_control.SendResult {
    var req = WeixinRequest{ .op = .send_input, .surface_id = surface_id, .bytes = bytes, .reply_context = reply_context };
    if (!weixinDispatch(&req) or !req.sent) return .offline;
    return if (req.busy) .busy else .ok;
}

fn wxTranscript(_: *anyopaque) []const u8 {
    var req = WeixinRequest{ .op = .latest_transcript };
    if (!weixinDispatch(&req) or !req.found) return "";

    g_weixin_transcript_mutex.lock();
    defer g_weixin_transcript_mutex.unlock();
    if (g_weixin_transcript_owned.len != 0) std.heap.page_allocator.free(g_weixin_transcript_owned);
    g_weixin_transcript_owned = req.transcript;
    return g_weixin_transcript_owned;
}

fn wxInboundFileDir(_: *anyopaque, buf: []u8) []const u8 {
    var req = WeixinRequest{ .op = .inbound_file_dir };
    if (!weixinDispatch(&req) or !req.found or req.dir.len == 0) return "";
    defer std.heap.page_allocator.free(req.dir);
    const n = @min(req.dir.len, buf.len);
    @memcpy(buf[0..n], req.dir[0..n]);
    return buf[0..n];
}

fn wxListAiConversations(_: *anyopaque, out: *weixin_control.ConversationList) void {
    out.count = 0;
    var req = WeixinRequest{ .op = .list_conversations, .conv_list_out = out };
    _ = weixinDispatch(&req);
    // On dispatch failure (no UI window) out stays count=0, which is correct.
}

fn wxPinAiConversationByIndex(_: *anyopaque, idx0: usize, out: *weixin_control.Conversation) bool {
    var req = WeixinRequest{ .op = .pin_by_index, .pin_index = idx0, .conv_one_out = out };
    if (!weixinDispatch(&req)) return false;
    return req.found;
}

fn wxAiApprovalPending(_: *anyopaque) bool {
    var req = WeixinRequest{ .op = .ai_approval_pending };
    if (!weixinDispatch(&req)) return false;
    return req.found;
}

fn wxAiQuestionOptionCount(_: *anyopaque) usize {
    var req = WeixinRequest{ .op = .ai_question_option_count };
    if (!weixinDispatch(&req) or !req.found) return 0;
    return req.option_count;
}
fn wxResolveAiQuestion(_: *anyopaque, reply: weixin_types.QuestionReply) bool {
    var req = WeixinRequest{ .op = .resolve_ai_question, .question_reply = reply };
    if (!weixinDispatch(&req)) return false;
    return req.sent;
}
fn wxResolveAiApproval(_: *anyopaque, approve: bool) bool {
    var req = WeixinRequest{ .op = .resolve_ai_approval, .approve = approve };
    if (!weixinDispatch(&req)) return false;
    return req.sent;
}

const weixin_vtable = weixin_control.Control.VTable{
    .is_connected = wxIsConnected,
    .find_ai_surface = wxFindAiSurface,
    .find_terminal_surface = wxFindTerminalSurface,
    .open_ai_agent = wxOpenAiAgent,
    .open_ai_agent_profile = wxOpenAiAgentProfile,
    .model_profiles = wxModelProfiles,
    .switch_ai_profile = wxSwitchAiProfile,
    .send_input = wxSendInput,
    .latest_transcript = wxTranscript,
    .ai_approval_pending = wxAiApprovalPending,
    .resolve_ai_approval = wxResolveAiApproval,
    .ai_question_option_count = wxAiQuestionOptionCount,
    .resolve_ai_question = wxResolveAiQuestion,
    .inbound_file_dir = wxInboundFileDir,
    .list_ai_conversations = wxListAiConversations,
    .pin_ai_conversation_by_index = wxPinAiConversationByIndex,
};

/// The Control the weixin controller drives. Backed by process-global state, so
/// the dummy ctx is unused.
pub fn weixinControl() weixin_control.Control {
    return .{ .ctx = &g_weixin_ctx, .vtable = &weixin_vtable };
}

fn clearWeixinTranscriptCache() void {
    g_weixin_transcript_mutex.lock();
    defer g_weixin_transcript_mutex.unlock();
    if (g_weixin_transcript_owned.len != 0) std.heap.page_allocator.free(g_weixin_transcript_owned);
    g_weixin_transcript_owned = &.{};
}

// ============================================================================
// Agent terminal control (wisptermctl) — cross-platform Control surface.
//
// Unlike the weixin path, this does NOT marshal to the UI thread: Win32
// SendMessage is a no-op on Linux (window_linux.zig). get-text/send-text pin
// the target surface through surface_registry (a mutex liveness guard) and run
// directly on the ctl server thread, exactly like the agent worker host
// (agentSurfaceSnapshot / agentWriteSurface). Only `panes` needs threadlocal
// tab topology, so the UI thread publishes a JSON snapshot into
// g_ctl_panes_json on the render tick (syncCtlPanes).
// ============================================================================

var g_agent_control_enabled = std.atomic.Value(bool).init(false);
var g_ctl_ctx: u8 = 0;
var g_ctl_panes_mutex: std.Thread.Mutex = .{};
var g_ctl_panes_json: []u8 = &.{}; // page_allocator-owned latest panes JSON
// Atomic: syncCtlPanes runs from every window's render thread (the panes cache
// is process-global, last-writer-wins — acceptable, matching the relay layout
// sync). The timestamp must be touched atomically to avoid a data race.
var g_ctl_panes_last_ms = std.atomic.Value(i64).init(0);

const ctl_default_rows: u32 = 1000;

pub fn enableAgentControl() void {
    g_agent_control_enabled.store(true, .release);
}

fn ctlListPanes(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
    _ = ctx;
    g_ctl_panes_mutex.lock();
    defer g_ctl_panes_mutex.unlock();
    if (g_ctl_panes_json.len == 0) return null;
    return try allocator.dupe(u8, g_ctl_panes_json);
}

fn ctlGetText(ctx: *anyopaque, allocator: std.mem.Allocator, id: []const u8, recent: ?u32) anyerror!?[]u8 {
    _ = ctx;
    // Cross-platform + UAF-safe: the registry blocks Surface.deinit for the
    // duration of the snapshot, and the id match rejects a reused pointer.
    const ptr = surface_registry.acquireById(id) orelse return null;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(ptr));
    const want: usize = if (recent) |r| r else ctl_default_rows;
    const rows = @min(want, remote_snapshot.default_max_history_rows);
    return try buildRemoteSurfaceSnapshot(allocator, surface, rows);
}

fn ctlSendText(ctx: *anyopaque, id: []const u8, data: []const u8) bool {
    _ = ctx;
    const ptr = surface_registry.acquireById(id) orelse return false;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(ptr));
    surface.queuePtyWrite(data);
    return true;
}

const ctl_vtable = ctl_control.Control.VTable{
    .list_panes = ctlListPanes,
    .get_text = ctlGetText,
    .send_text = ctlSendText,
};

/// The Control the agent-control server drives. Backed by process-global state,
/// so the dummy ctx is unused.
pub fn agentControl() ctl_control.Control {
    return .{ .ctx = &g_ctl_ctx, .vtable = &ctl_vtable };
}

fn clearCtlPanesCache() void {
    g_ctl_panes_mutex.lock();
    defer g_ctl_panes_mutex.unlock();
    if (g_ctl_panes_json.len != 0) std.heap.page_allocator.free(g_ctl_panes_json);
    g_ctl_panes_json = &.{};
}

/// UI-thread: publish a fresh panes JSON snapshot (throttled). Called from the
/// render loop next to syncRemoteLayout. No-op unless ctl is enabled.
fn syncCtlPanes(allocator: std.mem.Allocator) void {
    if (!g_agent_control_enabled.load(.acquire)) return;
    const now = std.time.milliTimestamp();
    if (now - g_ctl_panes_last_ms.load(.monotonic) < 200) return;
    g_ctl_panes_last_ms.store(now, .monotonic);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    buildCtlPanesJson(allocator, &out) catch return;

    const owned = std.heap.page_allocator.dupe(u8, out.items) catch return;
    g_ctl_panes_mutex.lock();
    defer g_ctl_panes_mutex.unlock();
    if (g_ctl_panes_json.len != 0) std.heap.page_allocator.free(g_ctl_panes_json);
    g_ctl_panes_json = owned;
}

test "ctl surface callbacks reject an unregistered id without dereferencing" {
    try std.testing.expect((try ctlGetText(&g_ctl_ctx, std.testing.allocator, "missing", null)) == null);
    try std.testing.expect(!ctlSendText(&g_ctl_ctx, "missing", "x"));
}

fn buildRemoteSurfaceSnapshot(allocator: std.mem.Allocator, surface: *Surface, max_history_rows: usize) ![]u8 {
    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    return remote_snapshot.allocTerminalSnapshot(
        allocator,
        &surface.terminal,
        max_history_rows,
    );
}

pub fn activeSurfaceSnapshot(allocator: std.mem.Allocator) ?[]u8 {
    const surface = activeSurface() orelse return null;
    // Jupyter-URL detection / web-remote mirror want the full scrollback, not the
    // smaller agent budget.
    return buildRemoteSurfaceSnapshot(allocator, surface, remote_snapshot.default_max_history_rows) catch null;
}

const AgentSurfaceLocation = struct {
    tab_index: usize,
    focused: bool,
};

fn findAgentSurfaceLocation(surface: *const Surface) ?AgentSurfaceLocation {
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (entry.surface == surface) {
                return .{
                    .tab_index = tab_index,
                    .focused = tab_index == active_tab_state.g_active_tab and entry.handle == tab_state.focused,
                };
            }
        }
    }
    return null;
}

fn makeAgentToolSurface(
    allocator: std.mem.Allocator,
    surface: *Surface,
    tab_index: usize,
    focused: bool,
) anyerror!ai_chat.ToolSurface {
    const snapshot = buildRemoteSurfaceSnapshot(allocator, surface, remote_snapshot.agent_max_history_rows) catch try allocator.dupe(u8, "");
    return ai_chat.ToolSurface.initOwned(
        allocator,
        surface.remote_id[0..],
        surface.getTitle(),
        surface.getCwd() orelse surface.getInitialCwd() orelse "",
        snapshot,
        .{
            .tab_index = tab_index,
            .focused = focused,
            .is_ssh = surface.launch_kind == .ssh and surface.ssh_connection != null,
            .is_wsl = surface.launch_kind == .wsl,
            .agent_app = surface.agent_detection.app,
            .agent_state = surface.agent_detection.state,
            .agent_confidence = surface.agent_detection.confidence,
            .ptr = @ptrCast(surface),
        },
    );
}

fn collectAgentToolSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!ai_chat.ToolSnapshot {
    _ = ctx;
    var surfaces: std.ArrayListUnmanaged(ai_chat.ToolSurface) = .empty;
    errdefer {
        for (surfaces.items) |surface| surface.deinit(allocator);
        surfaces.deinit(allocator);
    }

    var active_tab = active_tab_state.g_active_tab;
    const context_surface_id = g_agent_context_surface_id[0..g_agent_context_surface_id_len];
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            const is_context = context_surface_id.len > 0 and std.mem.eql(u8, entry.surface.remote_id[0..], context_surface_id);
            if (is_context) active_tab = tab_index;
            const tool_surface = try makeAgentToolSurface(
                allocator,
                entry.surface,
                tab_index,
                is_context,
            );
            errdefer tool_surface.deinit(allocator);
            try surfaces.append(allocator, tool_surface);
        }
    }

    return .{
        .surfaces = try surfaces.toOwnedSlice(allocator),
        .active_tab = active_tab,
    };
}

fn agentSurfaceSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator, surface_id: []const u8, surface_ptr: *anyopaque) anyerror![]u8 {
    _ = ctx;
    // Runs on the agent request worker with a pointer captured at request
    // start; the UI thread may have freed the surface since. The registry
    // guard blocks Surface.deinit for the duration of the snapshot. Matching
    // the captured id prevents a reused pointer from targeting a new surface.
    if (!surface_registry.acquire(surface_ptr, surface_id)) return error.SurfaceClosed;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    return buildRemoteSurfaceSnapshot(allocator, surface, remote_snapshot.agent_max_history_rows);
}

fn agentWriteSurface(ctx: *anyopaque, surface_id: []const u8, surface_ptr: *anyopaque, data: []const u8) bool {
    _ = ctx;
    // Same worker-thread hazard as agentSurfaceSnapshot.
    if (!surface_registry.acquire(surface_ptr, surface_id)) return false;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    surface.queuePtyWrite(data);
    return true;
}

test "agent surface callbacks reject a surface that is not registered as live" {
    // The agent request worker holds ToolSurface.ptr across an entire request
    // while the UI thread may free the surface at any time (close tab/split).
    // Both callbacks must refuse an unregistered pointer before touching any
    // Surface field. The stand-in below is zeroed, never-registered memory; if
    // a callback dereferences it the test crashes instead of erroring.
    var dummy_buf: [@sizeOf(Surface)]u8 align(@alignOf(Surface)) = @splat(0);
    const ptr: *anyopaque = @ptrCast(&dummy_buf);

    try std.testing.expectError(error.SurfaceClosed, agentSurfaceSnapshot(ptr, std.testing.allocator, "missing", ptr));
    try std.testing.expect(!agentWriteSurface(ptr, "missing", ptr, "x"));
}

fn agentSshConnectionForSurface(ctx: *anyopaque, surface_id: []const u8) ?Surface.SshConnection {
    _ = ctx;
    if (surface_id.len == 0) return null;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            const sfc = entry.surface;
            if (!std.mem.eql(u8, sfc.remote_id[0..], surface_id)) continue;
            return sfc.ssh_connection; // value copy (or null if not SSH)
        }
    }
    return null;
}

fn postAgentTabNew(native_handle: window_backend.NativeHandle, request: *AgentTabNewRequest) void {
    _ = thread_message.sendPointer(native_handle, .agent_tab_new, @intFromPtr(request));
}

fn postAgentTabClose(native_handle: window_backend.NativeHandle, request: *AgentTabCloseRequest) void {
    _ = thread_message.sendPointer(native_handle, .agent_tab_close, @intFromPtr(request));
}

fn postAgentSshConnect(native_handle: window_backend.NativeHandle, request: *AgentSshConnectRequest) void {
    _ = thread_message.sendPointer(native_handle, .agent_ssh_connect, @intFromPtr(request));
}

fn postAgentSshSave(native_handle: window_backend.NativeHandle, request: *AgentSshSaveRequest) void {
    _ = thread_message.sendPointer(native_handle, .agent_ssh_save, @intFromPtr(request));
}

fn agentSpawnTab(ctx: *anyopaque, allocator: std.mem.Allocator, kind: []const u8, command: ?[]const u8) anyerror!ai_chat.ToolSurface {
    const window: *AppWindow = @ptrCast(@alignCast(ctx));
    const native_handle = window.getNativeHandle() orelse return error.WindowUnavailable;

    var request = AgentTabNewRequest{
        .allocator = allocator,
        .kind = kind,
        .command = command,
    };

    if (g_window) |current| {
        if (window_backend.nativeHandle(current) == native_handle) {
            handleAgentTabNewRequest(&request);
        } else {
            postAgentTabNew(native_handle, &request);
        }
    } else {
        postAgentTabNew(native_handle, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.SpawnFailed;
}

fn agentCloseTab(ctx: *anyopaque, allocator: std.mem.Allocator, tab_index: ?usize, surface_id: ?[]const u8, title_text: ?[]const u8) anyerror!ai_chat.ToolClosedTab {
    const window: *AppWindow = @ptrCast(@alignCast(ctx));
    const native_handle = window.getNativeHandle() orelse return error.WindowUnavailable;

    var request = AgentTabCloseRequest{
        .allocator = allocator,
        .tab_index = tab_index,
        .surface_id = surface_id,
        .title = title_text,
    };

    if (g_window) |current| {
        if (window_backend.nativeHandle(current) == native_handle) {
            handleAgentTabCloseRequest(&request);
        } else {
            postAgentTabClose(native_handle, &request);
        }
    } else {
        postAgentTabClose(native_handle, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.TabNotFound;
}

fn agentConnectSshProfile(ctx: *anyopaque, allocator: std.mem.Allocator, profile_name: []const u8) anyerror!ai_chat.ToolSurface {
    const window: *AppWindow = @ptrCast(@alignCast(ctx));
    const native_handle = window.getNativeHandle() orelse return error.WindowUnavailable;

    var request = AgentSshConnectRequest{
        .allocator = allocator,
        .profile_name = profile_name,
    };

    if (g_window) |current| {
        if (window_backend.nativeHandle(current) == native_handle) {
            handleAgentSshConnectRequest(&request);
        } else {
            postAgentSshConnect(native_handle, &request);
        }
    } else {
        postAgentSshConnect(native_handle, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.ConnectFailed;
}

fn agentSaveSshProfile(ctx: *anyopaque, allocator: std.mem.Allocator, args: ai_chat.SshProfileSaveArgs) anyerror!ai_chat.SavedSshProfile {
    const window: *AppWindow = @ptrCast(@alignCast(ctx));
    const native_handle = window.getNativeHandle() orelse return error.WindowUnavailable;

    var request = AgentSshSaveRequest{
        .allocator = allocator,
        .args = args,
    };

    if (g_window) |current| {
        if (window_backend.nativeHandle(current) == native_handle) {
            handleAgentSshSaveRequest(&request);
        } else {
            postAgentSshSave(native_handle, &request);
        }
    } else {
        postAgentSshSave(native_handle, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.SaveFailed;
}

fn agentTabCommand(kind_raw: []const u8, command_raw: ?[]const u8) anyerror!?[]const u8 {
    return platform_pty_command.tabCommandForKind(kind_raw, command_raw, tab.getShellCmd());
}

fn handleAgentTabNewRequest(request: *AgentTabNewRequest) void {
    const command = agentTabCommand(request.kind, request.command) catch |err| {
        request.err = err;
        return;
    };

    const surface = if (command) |cmd|
        spawnTabWithCommandUtf8ReturningSurface(cmd)
    else blk: {
        const allocator = g_allocator orelse {
            request.err = error.SpawnFailed;
            return;
        };
        if (!spawnTab(allocator)) {
            request.err = error.SpawnFailed;
            return;
        }
        break :blk activeSurface();
    };

    const new_surface = surface orelse {
        request.err = error.SpawnFailed;
        return;
    };

    const location = findAgentSurfaceLocation(new_surface) orelse {
        request.err = error.SpawnFailed;
        return;
    };
    request.result = makeAgentToolSurface(
        request.allocator,
        new_surface,
        location.tab_index,
        location.focused,
    ) catch |err| {
        request.err = err;
        return;
    };
}

fn findTabIndexBySurfaceId(surface_id: []const u8) ?usize {
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.surface.remote_id[0..], surface_id)) return tab_index;
        }
    }
    return null;
}

fn findTabIndexByTitle(title_text: []const u8) ?usize {
    const title_trimmed = std.mem.trim(u8, title_text, " \t\r\n");
    if (title_trimmed.len == 0) return null;

    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (std.ascii.eqlIgnoreCase(tab_state.getTitle(), title_trimmed)) return tab_index;
    }

    var partial: ?usize = null;
    var partial_count: usize = 0;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (std.ascii.indexOfIgnoreCase(tab_state.getTitle(), title_trimmed) != null) {
            partial = tab_index;
            partial_count += 1;
        }
    }
    return if (partial_count == 1) partial else null;
}

fn resolveAgentCloseTabIndex(request: *const AgentTabCloseRequest) ?usize {
    if (request.tab_index) |idx| return idx;
    if (request.surface_id) |surface_id| {
        if (findTabIndexBySurfaceId(surface_id)) |idx| return idx;
    }
    if (request.title) |title_text| {
        if (findTabIndexByTitle(title_text)) |idx| return idx;
    }
    return active_tab_state.g_active_tab;
}

fn handleAgentTabCloseRequest(request: *AgentTabCloseRequest) void {
    if (tab.g_tab_count <= 1) {
        request.err = error.LastTab;
        return;
    }

    const idx = resolveAgentCloseTabIndex(request) orelse {
        request.err = error.TabNotFound;
        return;
    };
    if (idx >= tab.g_tab_count) {
        request.err = error.TabNotFound;
        return;
    }

    const tab_state = tab.g_tabs[idx] orelse {
        request.err = error.TabNotFound;
        return;
    };
    if (tab_state.kind != .terminal) {
        request.err = error.CannotCloseAiChatTab;
        return;
    }

    const title_copy = request.allocator.dupe(u8, tab_state.getTitle()) catch |err| {
        request.err = err;
        return;
    };

    closeTab(idx);
    request.result = .{
        .tab_index = idx,
        .active_tab = active_tab_state.g_active_tab,
        .title = title_copy,
    };
}

fn handleAgentSshConnectRequest(request: *AgentSshConnectRequest) void {
    switch (overlays.agentConnectSshProfile(request.profile_name)) {
        .connected => |surface| {
            const location = findAgentSurfaceLocation(surface) orelse {
                request.err = error.ConnectFailed;
                return;
            };
            request.result = makeAgentToolSurface(
                request.allocator,
                surface,
                location.tab_index,
                location.focused,
            ) catch |err| {
                request.err = err;
                return;
            };
        },
        .not_found => request.err = error.ProfileNotFound,
        .failed => request.err = error.ConnectFailed,
    }
}

fn handleAgentSshSaveRequest(request: *AgentSshSaveRequest) void {
    request.result = overlays.agentSaveSshProfile(request.allocator, request.args) catch |err| {
        request.err = err;
        return;
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
    switch (decoded.tag) {
        .agent_ssh_connect => handleAgentSshConnectRequest(@ptrFromInt(decoded.ptr)),
        .agent_ssh_save => handleAgentSshSaveRequest(@ptrFromInt(decoded.ptr)),
        .agent_tab_new => handleAgentTabNewRequest(@ptrFromInt(decoded.ptr)),
        .agent_tab_close => handleAgentTabCloseRequest(@ptrFromInt(decoded.ptr)),
        .remote_ai_input => handleRemoteAiInputRequest(@ptrFromInt(decoded.ptr)),
        .remote_open_ai_agent => handleRemoteAiAgentOpenRequest(@ptrFromInt(decoded.ptr)),
        .weixin_control => handleWeixinControlRequest(@ptrFromInt(decoded.ptr)),
    }
    return 1;
}

fn installAgentToolHost(self: *AppWindow) void {
    ai_chat.setToolHost(.{
        .ctx = @ptrCast(self),
        .collectSnapshot = collectAgentToolSnapshot,
        .surfaceSnapshot = agentSurfaceSnapshot,
        .writeSurface = agentWriteSurface,
        .spawnTab = agentSpawnTab,
        .closeTab = agentCloseTab,
        .saveSshProfile = agentSaveSshProfile,
        .connectSshProfile = agentConnectSshProfile,
        .sshConnectionForSurface = agentSshConnectionForSurface,
    });
}

fn installRemoteControlHandlers(self: *AppWindow) void {
    if (self.app.remote_client) |client| {
        client.registerAiAgentOpener(self.app, remoteAiAgentOpen);
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

/// Run deferred agent detections (throttled on the IO thread during output
/// floods, see Surface.agent_throttle) so detection converges once output
/// stops — e.g. an approval prompt arriving as the last chunk of a burst.
/// Repaints only when the detection result actually changed.
fn flushAgentDetectionSweep() void {
    const now = std.time.milliTimestamp();
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |tb| {
            var it = tb.tree.surfaces();
            while (it.next()) |entry| {
                const surface = entry.surface;
                if (!surface.agent_throttle.pendingPeek()) continue;
                const before = surface.agent_detection;
                surface.render_state.mutex.lock();
                const ran = surface.flushAgentDetection(now);
                surface.render_state.mutex.unlock();
                if (ran and !std.meta.eql(before, surface.agent_detection)) {
                    g_force_rebuild = true;
                    g_cells_valid = false;
                }
            }
        }
    }
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
    if (font.g_icon_atlas_texture != 0) {
        var t = gpu.Texture.fromHandle(font.g_icon_atlas_texture);
        t.destroy();
        font.g_icon_atlas_texture = 0;
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
    if (font.g_titlebar_atlas_texture != 0) {
        var t = gpu.Texture.fromHandle(font.g_titlebar_atlas_texture);
        t.destroy();
        font.g_titlebar_atlas_texture = 0;
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
    const layout = ai_chat_renderer.inputLayout(chat_x, chat_w, input_text);
    const cursor = ai_chat_renderer.inputCursorRect(input_text, session.input_cursor, layout.text_x, layout.text_w);
    const scrolled_row = session.input_scroll_row;
    const follow_cursor = session.input_scroll_follow_cursor;
    session.mutex.unlock();
    const input_line_h = @round(@max(23.0, font.g_titlebar_cell_height + 8.0));
    const visible_rows = ai_chat_renderer.inputVisibleRowsForField(layout.field_h);
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
    const cursor_top_px = field_top_px + ai_chat_renderer.INPUT_FIELD_PAD_TOP + @as(f32, @floatFromInt(row)) * input_line_h;
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

    gpu.gl_init.renderQuad(x, y, width, height, bg);
    gpu.gl_init.renderQuad(x, y, width, @max(1.0, @as(f32, @floatFromInt(font.box_thickness))), g_theme.cursor_color);

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
    g_weixin_ui_handle.store(window_backend.nativeHandleBits(&backend_window), .release);
    defer g_weixin_ui_handle.store(0, .release);
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
        .opengl => try gpu.Context.init(@ptrCast(&window_backend.glGetProcAddress)),
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

    if (!gpu.gl_init.initShaders()) {
        std.debug.print("Failed to initialize shaders\n", .{});
        return error.ShaderInitFailed;
    }
    ui_pipeline.init();
    gpu.gl_init.syncSharedHandles();
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
        if (font.g_icon_atlas_texture != 0) {
            var t = gpu.Texture.fromHandle(font.g_icon_atlas_texture);
            t.destroy();
            font.g_icon_atlas_texture = 0;
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
        if (font.g_titlebar_atlas_texture != 0) {
            var t = gpu.Texture.fromHandle(font.g_titlebar_atlas_texture);
            t.destroy();
            font.g_titlebar_atlas_texture = 0;
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
    //   Then setScreenSize: avail_h = content_h - 20 = fb_height - 74
    //
    // Actually there might be edge extension for top/bottom too. Let me just match exactly:
    // For a full-window single split (at all edges):
    //   pw = fb_width (after adding back padding for left+right edges)
    //   ph = content_h = fb_height - top_padding - padding = fb_height - 44 - 10 = fb_height - 54
    //   Wait, is there edge extension for y too?
    //
    // Looking at the code: only left/right edges get extension, not top/bottom.
    // So:
    //   setScreenSize(pw=fb_width, ph=fb_height-54, explicit_padding)
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
            .restored_session => {},
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
        tmux_controller.tickAll(allocator, term_cols, term_rows);
        overlays.tickSessionLauncher();
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
        if (g_pending_resize) {
            const now = std.time.milliTimestamp();
            if (now - g_last_resize_time >= RESIZE_COALESCE_MS) {
                g_pending_resize = false;

                if (g_pending_cols != term_cols or g_pending_rows != term_rows) {
                    term_cols = g_pending_cols;
                    term_rows = g_pending_rows;
                }
            }
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
        // Catch up agent detections deferred by the IO-thread throttle.
        flushAgentDetectionSweep();

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
            const timeout_ms = render_gate.computeBlockTimeoutMs(.{
                .visibility = .hidden,
                .cursor_blink_enabled = false,
                .ms_until_next_blink = CURSOR_BLINK_INTERVAL_MS,
            });
            window_backend.pumpAppEvents(@as(f64, @floatFromInt(timeout_ms)) / 1000.0);
            continue;
        }

        const gate_now = std.time.milliTimestamp();
        const visible = window_backend.isVisible(win);
        const vis: render_gate.Visibility = if (!visible)
            .hidden
        else if (window_focused)
            .focused
        else
            .unfocused_visible;

        const blink_enabled = g_cursor_blink and vis == .focused;
        const blink_due = blink_enabled and
            (gate_now - g_gate_last_blink_render >= CURSOR_BLINK_INTERVAL_MS);

        const signals = render_gate.RenderSignals{
            .force_rebuild = g_force_rebuild or !g_cells_valid or g_pending_resize or g_layout_resize_immediate,
            .any_surface_dirty = anyVisibleSurfaceDirty(),
            .cursor_blink_due = blink_due,
            .ai_streaming = aiStreamingActive(),
            .overlay_active = overlays.anyOverlayActive(gate_now),
            .atlas_sync_pending = font.atlasSyncPending(),
        };

        const needs_render = render_gate.frameNeedsRender(signals);
        if (!needs_render) {
            const ms_until_blink = if (blink_enabled)
                CURSOR_BLINK_INTERVAL_MS - (gate_now - g_gate_last_blink_render)
            else
                CURSOR_BLINK_INTERVAL_MS;
            const timeout_ms = render_gate.computeBlockTimeoutMs(.{
                .visibility = vis,
                .cursor_blink_enabled = blink_enabled,
                .ms_until_next_blink = ms_until_blink,
            });
            window_backend.pumpAppEvents(@as(f64, @floatFromInt(timeout_ms)) / 1000.0);
            continue;
        }
        if (blink_due) g_gate_last_blink_render = gate_now;

        gpu.gl_init.g_draw_call_count = 0;
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
            syncRemoteLayout(allocator);
            syncCtlPanes(allocator);
            syncImeCaretPosition(win, split_count);
            if (active_tab.kind != .ai_chat and active_tab.kind != .ai_history and active_tab.kind != .skill_center and active_tab.kind != .port_forwarding and synchronizedOutputPendingForVisibleSplits(split_count)) {
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
                    gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
                gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
                                gpu.gl_init.setProjection(@floatFromInt(rect.width), @floatFromInt(rect.height));

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
                                gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
                                    gpu.gl_init.setProjection(@floatFromInt(rect.width), @floatFromInt(rect.height));
                                    if (is_swap_target) {
                                        overlays.renderSwapTargetHighlight(@floatFromInt(rect.width), @floatFromInt(rect.height));
                                    } else {
                                        overlays.renderUnfocusedOverlaySimple(@floatFromInt(rect.width), @floatFromInt(rect.height));
                                    }
                                    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
                                    gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                                }
                            },
                        }
                    }

                    // Restore full viewport for dividers
                    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
                    gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));

                    // Draw split dividers and per-pane agent dots
                    overlays.renderSplitDividers(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
                    overlays.renderPaneAgentDots(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
                }
            }
        } else if (!post_process.g_post_enabled) {
            gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
            gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
            clearWithBackground(fb_width, fb_height);
            titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        }

        gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
        gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
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
        overlays.renderSettingsPage(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderSessionLauncher(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        weixin_qr_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderDebugOverlay(@floatFromInt(fb_width));
        overlays.renderCloseShortcutConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderCopyToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderTransferToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderTransferCancelConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderUpdatePrompt(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderWindowCloseConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderRestoreDefaultsConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderWhatsNew(@floatFromInt(fb_width), @floatFromInt(fb_height));
        renderImePreedit(win, fb_width, fb_height);

        logSwapDiagnosticsIfChanged(win, fb_width, fb_height);
        forceOpaqueBackbufferForPresent();
        gpu.state.endFrame();
        window_backend.swapBuffers(win);
        if (!g_present_bringup_settled) {
            g_present_bringup_settled = true;
            platform_window_state.settleD3dBringup(allocator);
        }
        recordFrameLatencyIfInputDriven();
        clearVisibleSurfaceDirty();
        g_force_rebuild = false;
        g_cells_valid = true;
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
    g_weixin_ui_handle.store(0, .release);
    render_diagnostics.log("shutdown window-loop-ended", .{});
    render_diagnostics.close();

    // Clean up file explorer async state (join background thread, free job)
    file_explorer.deinit();
    weixin_qr_renderer.deinit();
    weixin_qr_panel.deinit();
    clearWeixinTranscriptCache();
    clearCtlPanesCache();
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

test "appwindow: ai history content width accounts for right panels" {
    try std.testing.expectEqual(@as(f32, 700), aiHistoryContentWidth(1000, 200, 100));
    try std.testing.expectEqual(@as(f32, 0), aiHistoryContentWidth(250, 200, 100));
}

test "appwindow: remote layout serializes ai_history as non-terminal surface" {
    const allocator = std.testing.allocator;
    for (0..tab.MAX_TABS) |idx| tab.g_tabs[idx] = null;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    defer {
        for (0..tab.MAX_TABS) |idx| tab.g_tabs[idx] = null;
        tab.g_tab_count = 0;
        active_tab_state.g_active_tab = 0;
    }

    var session = @import("ai_history_session.zig").Session.init(allocator, .{
        .id = "local-history",
        .name = "Local History",
        .target = .local,
    });
    defer session.deinit();
    var tab_state = tab.TabState{
        .kind = .ai_history,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = &session,
        .copilot_session = null,
    };
    tab.g_tabs[0] = &tab_state;
    tab.g_tab_count = 1;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try buildRemoteLayoutJson(allocator, &out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"kind\":\"terminal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"kind\":\"ai_chat\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"readOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"surfaces\":[]") == null);
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
