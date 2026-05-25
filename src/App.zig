//! App — coordinates multiple terminal windows.
//!
//! Owns shared configuration and manages the lifecycle of AppWindow instances.
//! Each window runs on its own thread with an independent native message pump,
//! OpenGL context, fonts, and terminal state.

const std = @import("std");
const Config = @import("config.zig");
const AppWindow = @import("AppWindow.zig");
const ai_chat = @import("ai_chat.zig");
const app_metadata = @import("app_metadata.zig");
const keybind = @import("keybind.zig");
const platform_com = @import("platform/com.zig");
const platform_display = @import("platform/display.zig");
const font_backend = @import("platform/font_backend.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const window_backend = @import("platform/window_backend.zig");
const remote = @import("remote_client.zig");
const weixin = @import("weixin/controller.zig");
const weixin_control = @import("weixin/control.zig");
const weixin_types = @import("weixin/types.zig");
const platform_dirs = @import("platform/dirs.zig");
const update_check = @import("update_check.zig");
const update_install = @import("update_install.zig");

const App = @This();

// ============================================================================
// Fields
// ============================================================================

allocator: std.mem.Allocator,

// Resolved platform shell command.
shell_cmd_buf: platform_pty_command.CommandLineBuffer,
shell_cmd_len: usize,

// Config values (read-only after init)
scrollback_limit: u32,
font_family: []const u8,
font_family_cjk: ?[]const u8,
font_family_fallback: ?[]const u8,
font_weight: font_backend.FontWeight,
font_size: u32,
cursor_style: Config.CursorStyle,
cursor_blink: bool,
theme: Config.Theme,
shader_path: ?[]const u8,

// Terminal dimensions from config
initial_cols: u16,
initial_rows: u16,

// Window state options
maximize: bool,
fullscreen: bool,
title: ?[]const u8,
quake_mode: bool,
keybinds: keybind.Set,

// Debug flags
debug_fps: bool,
debug_draw_calls: bool,
debug_memory: bool,

// Split config
unfocused_split_opacity: f32,
split_divider_color: ?Config.Color,
focus_follows_mouse: bool,
copy_on_select: bool,
right_click_action: Config.RightClickAction,
ssh_legacy_algorithms: bool,

// Background image
background_image: ?[]const u8,
background_opacity: f32,
background_image_mode: Config.BackgroundImageMode,

// Remote access config
remote_enabled: bool,
remote_server_url: ?[]const u8,
remote_server_fingerprint: ?[]const u8,
remote_device_name: ?[]const u8,
remote_session_key: ?[]const u8,
remote_client: ?*remote.Client,

// WeChat direct (embedded ilink). Mutually exclusive with remote_client.
weixin_controller: ?*weixin.Controller,

// AI agent config
ai_agent_enabled: bool,
ai_agent_permission: ai_chat.AgentPermission,
ai_agent_command_timeout_ms: u32,
ai_agent_output_limit: u32,

// Session persistence
restore_tabs_on_startup: bool,

// Update check state
auto_update_check: bool,
update_mutex: std.Thread.Mutex,
update_result: update_check.CheckResult,
update_latest_version_buf: [32]u8,
update_release_url_buf: [256]u8,
update_asset_name_buf: [update_check.asset_name_buffer_len]u8,
update_asset_download_url_buf: [update_check.asset_download_url_buffer_len]u8,
available_update: update_check.CheckResult,
available_update_package: update_check.ReleasePackage,
pending_install_update: update_check.CheckResult,
pending_install_package: update_check.ReleasePackage,
install_latest_version_buf: [32]u8,
install_release_url_buf: [256]u8,
install_asset_name_buf: [update_check.asset_name_buffer_len]u8,
install_asset_download_url_buf: [update_check.asset_download_url_buffer_len]u8,
update_thread: ?std.Thread,
update_check_in_flight: bool,
install_thread: ?std.Thread,
install_in_flight: bool,
install_worker_running: bool,
startup_update_check_started: bool,

// Window management
windows: std.ArrayListUnmanaged(*AppWindow),
mutex: std.Thread.Mutex,
window_threads: std.ArrayListUnmanaged(std.Thread),

// Position for next spawned window (cascading)
next_window_x: ?i32 = null,
next_window_y: ?i32 = null,

// CWD for next spawned window (working directory inheritance)
next_window_cwd: platform_pty_command.CwdBuffer = undefined,
next_window_cwd_len: usize = 0,

// ============================================================================
// Initialization
// ============================================================================

fn dupeStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    return allocator.dupe(u8, s);
}

fn dupeOptStr(allocator: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try allocator.dupe(u8, v) else null;
}

fn freeOptStr(allocator: std.mem.Allocator, s: ?[]const u8) void {
    if (s) |v| allocator.free(v);
}

pub fn resolveShellCommandLine(out_buf: *platform_pty_command.CommandLineBuffer, cmd: []const u8) usize {
    return platform_pty_command.resolveShellCommandLine(out_buf, cmd);
}

/// Initialize the App with configuration.
pub fn init(allocator: std.mem.Allocator, cfg: Config) !App {
    const font_family = try dupeStr(allocator, cfg.@"font-family");
    errdefer allocator.free(font_family);
    const font_family_cjk = try dupeOptStr(allocator, cfg.@"font-family-cjk");
    errdefer freeOptStr(allocator, font_family_cjk);
    const font_family_fallback = try dupeOptStr(allocator, cfg.@"font-family-fallback");
    errdefer freeOptStr(allocator, font_family_fallback);
    const shader_path = try dupeOptStr(allocator, cfg.@"custom-shader");
    errdefer freeOptStr(allocator, shader_path);
    const title = try dupeOptStr(allocator, cfg.title);
    errdefer freeOptStr(allocator, title);
    const remote_server_url = try dupeOptStr(allocator, cfg.@"remote-server-url");
    errdefer freeOptStr(allocator, remote_server_url);
    const remote_server_fingerprint = try dupeOptStr(allocator, cfg.@"remote-server-fingerprint");
    errdefer freeOptStr(allocator, remote_server_fingerprint);
    const remote_device_name = try dupeOptStr(allocator, cfg.@"remote-device-name");
    errdefer freeOptStr(allocator, remote_device_name);
    const remote_session_key = try dupeOptStr(allocator, cfg.@"remote-session-key");
    errdefer freeOptStr(allocator, remote_session_key);
    const remote_client_ptr = startRemoteClient(allocator, cfg.@"remote-enabled", remote_server_url, remote_device_name, remote_session_key);
    errdefer if (remote_client_ptr) |client| client.destroy();
    const background_image = try dupeOptStr(allocator, cfg.@"background-image");
    errdefer freeOptStr(allocator, background_image);

    var app = App{
        .allocator = allocator,
        .shell_cmd_buf = undefined,
        .shell_cmd_len = 0,
        .scrollback_limit = cfg.@"scrollback-limit",
        .font_family = font_family,
        .font_family_cjk = font_family_cjk,
        .font_family_fallback = font_family_fallback,
        .font_weight = font_backend.fontWeightFromValue(cfg.@"font-style".value()),
        .font_size = cfg.@"font-size",
        .cursor_style = cfg.@"cursor-style",
        .cursor_blink = cfg.@"cursor-style-blink",
        .theme = cfg.resolved_theme,
        .shader_path = shader_path,
        .initial_cols = if (cfg.@"window-width" > 0) cfg.@"window-width" else 80,
        .initial_rows = if (cfg.@"window-height" > 0) cfg.@"window-height" else 24,
        .maximize = cfg.maximize,
        .fullscreen = cfg.fullscreen,
        .title = title,
        .quake_mode = cfg.@"quake-mode",
        .keybinds = cfg.keybinds,
        .debug_fps = cfg.@"phantty-debug-fps",
        .debug_draw_calls = cfg.@"phantty-debug-draw-calls",
        .debug_memory = cfg.@"phantty-debug-memory",
        .unfocused_split_opacity = cfg.@"unfocused-split-opacity",
        .split_divider_color = cfg.@"split-divider-color",
        .focus_follows_mouse = cfg.@"focus-follows-mouse",
        .copy_on_select = cfg.@"copy-on-select",
        .right_click_action = cfg.@"right-click-action",
        .ssh_legacy_algorithms = cfg.@"ssh-legacy-algorithms",
        .background_image = background_image,
        .background_opacity = cfg.@"background-opacity",
        .background_image_mode = cfg.@"background-image-mode",
        .remote_enabled = cfg.@"remote-enabled",
        .remote_server_url = remote_server_url,
        .remote_server_fingerprint = remote_server_fingerprint,
        .remote_device_name = remote_device_name,
        .remote_session_key = remote_session_key,
        .remote_client = remote_client_ptr,
        // Created later by startWeixin(), once App lives at a stable address.
        .weixin_controller = null,
        .ai_agent_enabled = cfg.@"ai-agent-enabled",
        .ai_agent_permission = cfg.@"ai-agent-permission",
        .ai_agent_command_timeout_ms = cfg.@"ai-agent-command-timeout-ms",
        .ai_agent_output_limit = cfg.@"ai-agent-output-limit",
        .restore_tabs_on_startup = cfg.@"restore-tabs-on-startup",
        .auto_update_check = cfg.@"auto-update-check",
        .update_mutex = .{},
        .update_result = .{ .state = .idle },
        .update_latest_version_buf = undefined,
        .update_release_url_buf = undefined,
        .update_asset_name_buf = undefined,
        .update_asset_download_url_buf = undefined,
        .available_update = .{ .state = .idle },
        .available_update_package = update_install.defaultPackage(),
        .pending_install_update = .{ .state = .idle },
        .pending_install_package = update_install.defaultPackage(),
        .install_latest_version_buf = undefined,
        .install_release_url_buf = undefined,
        .install_asset_name_buf = undefined,
        .install_asset_download_url_buf = undefined,
        .update_thread = null,
        .update_check_in_flight = false,
        .install_thread = null,
        .install_in_flight = false,
        .install_worker_running = false,
        .startup_update_check_started = false,
        .windows = .empty,
        .mutex = .{},
        .window_threads = .empty,
    };

    app.shell_cmd_len = resolveShellCommandLine(&app.shell_cmd_buf, cfg.shell);
    std.debug.print("Shell command resolved: '{s}'\n", .{cfg.shell});
    if (app.remote_client) |client| {
        std.debug.print("Remote session key: {s}\n", .{client.sessionKey()});
    }

    return app;
}

fn startRemoteClient(
    allocator: std.mem.Allocator,
    enabled: bool,
    server_url: ?[]const u8,
    device_name: ?[]const u8,
    session_key: ?[]const u8,
) ?*remote.Client {
    if (!enabled) return null;
    const raw_url = server_url orelse return null;
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) return null;

    return remote.Client.create(allocator, .{
        .server_url = url,
        .device_name = device_name,
        .session_key = session_key,
    }) catch |err| {
        std.debug.print("Remote client disabled: {}\n", .{err});
        return null;
    };
}

// =====================================================================
// WeChat direct (embedded ilink) — host integration.
//
// UNVERIFIED SCAFFOLD: this block compiles against the weixin/ modules but
// the surface-control vtable bodies are safe stubs. With these stubs the
// WeChat bridge connects, logs in, and long-polls; control actions report
// "offline" until the TODOs are wired to the focused AppWindow (mirroring the
// remote path in AppWindow.zig: remoteAiSurfaceId / remoteAiWrite /
// remoteAiAgentOpen via thread_message, and activeAiChat() for the transcript).
// This has not been compiled (the desktop GUI is Windows-only); verify symbol
// names and signatures against AppWindow.zig during Windows compile iteration.
// =====================================================================

const weixin_vtable = weixin_control.Control.VTable{
    .is_connected = wxIsConnected,
    .find_ai_surface = wxFindAiSurface,
    .find_terminal_surface = wxFindTerminalSurface,
    .open_ai_agent = wxOpenAiAgent,
    .send_input = wxSendInput,
    .latest_transcript = wxTranscript,
};

/// Builds the Control the weixin controller drives. `self` must be stable
/// (this is only valid after App is in its final location — see startWeixin).
pub fn weixinControl(self: *App) weixin_control.Control {
    return .{ .ctx = self, .vtable = &weixin_vtable };
}

fn wxIsConnected(ctx: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.mutex.lock();
    defer app.mutex.unlock();
    return app.windows.items.len != 0;
}

fn wxFindAiSurface(ctx: *anyopaque) ?weixin_control.Surface {
    _ = ctx;
    // TODO(weixin-windows): return the focused window's AI-chat surface id/title.
    // Reuse AppWindow.remoteAiSurfaceId(tab_index) for the active .ai_chat tab.
    return null;
}

fn wxFindTerminalSurface(ctx: *anyopaque) ?weixin_control.Surface {
    _ = ctx;
    // TODO(weixin-windows): return the active writable terminal surface id/title.
    return null;
}

fn wxOpenAiAgent(ctx: *anyopaque, timeout_ms: u32) weixin_control.OpenResult {
    _ = ctx;
    _ = timeout_ms;
    // TODO(weixin-windows): marshal an open-AI-agent request onto the UI thread,
    // mirroring AppWindow.remoteAiAgentOpen (thread_message .remote_open_ai_agent).
    return .offline;
}

fn wxSendInput(ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8) bool {
    _ = ctx;
    _ = surface_id;
    _ = bytes;
    // TODO(weixin-windows): marshal input to the surface on the UI thread,
    // mirroring AppWindow.remoteAiWrite (thread_message .remote_ai_input).
    return false;
}

fn wxTranscript(ctx: *anyopaque) []const u8 {
    _ = ctx;
    // TODO(weixin-windows): render AppWindow.activeAiChat() in the
    // "You:/AI:/Status:" label format that reply_progress.zig parses.
    return "";
}

/// Creates and starts the WeChat direct controller when enabled and remote is
/// not active. Call once, after App is at its final address (see main.zig).
/// Mutually exclusive with remote: if remote is active, this is skipped.
pub fn startWeixin(self: *App, cfg: *const Config) void {
    if (!cfg.@"weixin-direct-enabled") return;
    if (self.remote_client != null) {
        std.debug.print("weixin-direct disabled: remote-enabled takes precedence\n", .{});
        return;
    }
    const state_path = platform_dirs.pathInConfigDir(self.allocator, "weixin.json") catch return;
    defer self.allocator.free(state_path);

    const settings = weixin_types.Settings{
        .enabled = true,
        .reply_timeout_ms = std.math.clamp(cfg.@"weixin-reply-timeout-ms", 5000, 180000),
        .allowed_user = cfg.@"weixin-allowed-user" orelse "",
    };
    const controller = weixin.Controller.create(self.allocator, state_path, self.weixinControl(), settings) catch |err| {
        std.debug.print("weixin-direct disabled: {}\n", .{err});
        return;
    };
    controller.start() catch {};
    self.weixin_controller = controller;
}

/// Get the shell command as a native null-terminated command line.
pub fn getShellCmd(self: *const App) platform_pty_command.CommandLine {
    return self.shell_cmd_buf[0..self.shell_cmd_len :0];
}

/// Take the initial CWD for a new window (copies into provided buffer, clears source).
/// Returns the length of the CWD, or 0 if no CWD was set.
pub fn takeInitialCwd(self: *App, out_buf: *platform_pty_command.CwdBuffer) usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.next_window_cwd_len == 0) return 0;

    const len = self.next_window_cwd_len;
    @memcpy(out_buf[0..len], self.next_window_cwd[0..len]);
    out_buf[len] = 0;
    self.next_window_cwd_len = 0;
    return len;
}

/// Replace an owned string field with a new dupe. Frees the old value.
fn replaceStr(self: *App, old: *[]const u8, new: []const u8) void {
    const duped = self.allocator.dupe(u8, new) catch return;
    self.allocator.free(old.*);
    old.* = duped;
}

fn replaceOptStr(self: *App, old: *?[]const u8, new: ?[]const u8) void {
    const duped = if (new) |v| (self.allocator.dupe(u8, v) catch return) else null;
    freeOptStr(self.allocator, old.*);
    old.* = duped;
}

/// Update cached config values from a reloaded config.
/// Called by windows when they detect a config change via hot-reload.
pub fn updateConfig(self: *App, cfg: *const Config) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.scrollback_limit = cfg.@"scrollback-limit";
    self.replaceStr(&self.font_family, cfg.@"font-family");
    self.replaceOptStr(&self.font_family_cjk, cfg.@"font-family-cjk");
    self.replaceOptStr(&self.font_family_fallback, cfg.@"font-family-fallback");
    self.font_weight = font_backend.fontWeightFromValue(cfg.@"font-style".value());
    self.font_size = cfg.@"font-size";
    self.cursor_style = cfg.@"cursor-style";
    self.cursor_blink = cfg.@"cursor-style-blink";
    self.theme = cfg.resolved_theme;
    self.replaceOptStr(&self.shader_path, cfg.@"custom-shader");
    self.initial_cols = if (cfg.@"window-width" > 0) cfg.@"window-width" else 80;
    self.initial_rows = if (cfg.@"window-height" > 0) cfg.@"window-height" else 24;
    self.debug_fps = cfg.@"phantty-debug-fps";
    self.debug_draw_calls = cfg.@"phantty-debug-draw-calls";
    self.debug_memory = cfg.@"phantty-debug-memory";
    self.unfocused_split_opacity = cfg.@"unfocused-split-opacity";
    self.split_divider_color = cfg.@"split-divider-color";
    self.focus_follows_mouse = cfg.@"focus-follows-mouse";
    self.copy_on_select = cfg.@"copy-on-select";
    self.right_click_action = cfg.@"right-click-action";
    self.ssh_legacy_algorithms = cfg.@"ssh-legacy-algorithms";
    self.replaceOptStr(&self.background_image, cfg.@"background-image");
    self.background_opacity = cfg.@"background-opacity";
    self.background_image_mode = cfg.@"background-image-mode";
    self.remote_enabled = cfg.@"remote-enabled";
    self.replaceOptStr(&self.remote_server_url, cfg.@"remote-server-url");
    self.replaceOptStr(&self.remote_server_fingerprint, cfg.@"remote-server-fingerprint");
    self.replaceOptStr(&self.remote_device_name, cfg.@"remote-device-name");
    self.replaceOptStr(&self.remote_session_key, cfg.@"remote-session-key");
    self.replaceOptStr(&self.title, cfg.title);
    self.quake_mode = cfg.@"quake-mode";
    self.keybinds = cfg.keybinds;
    self.ai_agent_enabled = cfg.@"ai-agent-enabled";
    self.ai_agent_permission = cfg.@"ai-agent-permission";
    self.ai_agent_command_timeout_ms = cfg.@"ai-agent-command-timeout-ms";
    self.ai_agent_output_limit = cfg.@"ai-agent-output-limit";
    self.restore_tabs_on_startup = cfg.@"restore-tabs-on-startup";
    self.auto_update_check = cfg.@"auto-update-check";
    self.shell_cmd_len = resolveShellCommandLine(&self.shell_cmd_buf, cfg.shell);
}

// ============================================================================
// Update checks
// ============================================================================

pub fn maybeStartStartupUpdateCheck(self: *App) void {
    var should_start = false;
    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        if (self.auto_update_check and !self.startup_update_check_started) {
            self.startup_update_check_started = true;
            should_start = true;
        }
    }
    if (should_start) self.startUpdateCheck(false);
}

pub fn requestManualUpdateCheck(self: *App) void {
    self.startUpdateCheck(true);
}

fn startUpdateCheck(self: *App, show_failures: bool) void {
    self.joinFinishedUpdateThread();

    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        if (self.update_check_in_flight or self.install_in_flight or self.install_worker_running) return;
        self.update_check_in_flight = true;
        self.update_result = .{ .state = if (show_failures) .checking else .idle };
    }

    const thread = std.Thread.spawn(.{}, updateCheckThreadMain, .{ self, show_failures }) catch |err| {
        std.debug.print("Update check: failed to spawn thread: {}\n", .{err});
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        self.update_check_in_flight = false;
        self.update_result = .{ .state = if (show_failures) .failed else .idle };
        return;
    };

    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    self.update_thread = thread;
}

fn updateCheckThreadMain(app: *App, show_failures: bool) void {
    var latest_version_buf: [32]u8 = undefined;
    var release_url_buf: [256]u8 = undefined;
    var asset_name_buf: [update_check.asset_name_buffer_len]u8 = undefined;
    var asset_download_url_buf: [update_check.asset_download_url_buffer_len]u8 = undefined;
    const package = update_install.currentPackage(app.allocator) catch update_install.defaultPackage();
    var result = update_check.fetchLatestReleaseForPackage(
        app.allocator,
        app_metadata.version,
        package,
        .{
            .latest_version = &latest_version_buf,
            .release_url = &release_url_buf,
            .asset_name = &asset_name_buf,
            .asset_download_url = &asset_download_url_buf,
        },
    );
    if (!show_failures and result.state != .update_available and result.release_url.len == 0) {
        result = .{ .state = .idle };
    }
    app.storeUpdateResult(result, package);
}

fn storeUpdateResult(self: *App, result: update_check.CheckResult, package: update_check.ReleasePackage) void {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    if (self.install_in_flight or self.install_worker_running) {
        self.update_check_in_flight = false;
        return;
    }
    const copied = update_check.copyResult(
        result,
        .{
            .latest_version = &self.update_latest_version_buf,
            .release_url = &self.update_release_url_buf,
            .asset_name = &self.update_asset_name_buf,
            .asset_download_url = &self.update_asset_download_url_buf,
        },
    );
    self.update_result = copied;
    if (copied.state == .update_available) {
        self.available_update = copied;
        self.available_update_package = package;
    }
    self.update_check_in_flight = false;
}

pub fn consumeUpdateResult(self: *App) update_check.CheckResult {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();

    if (self.update_result.state == .idle or self.update_result.state == .checking) {
        return .{ .state = .idle };
    }

    const result = self.update_result;
    self.update_result = .{ .state = .idle };
    return result;
}

pub fn copyLatestReleaseUrl(self: *App, out: []u8) ?[]const u8 {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();

    const url = if (self.update_result.release_url.len > 0)
        self.update_result.release_url
    else
        update_check.latest_release_page_url;
    return copyBounded(out, url);
}

pub fn hasInstallableUpdate(self: *App) bool {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();

    return !self.install_in_flight and
        !self.install_worker_running and
        self.available_update.state == .update_available and
        self.available_update.asset_download_url.len > 0;
}

pub fn requestUpdateInstall(self: *App) void {
    self.joinFinishedUpdateThread();
    self.joinFinishedInstallThread();

    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        if (self.install_in_flight or self.install_worker_running) return;
        if (self.available_update.state != .update_available or self.available_update.asset_download_url.len == 0) {
            self.update_result = .{ .state = .install_failed };
            return;
        }
        if (!self.copyPendingInstallUpdateLocked()) {
            self.update_result = .{ .state = .install_failed };
            return;
        }
        self.install_in_flight = true;
        self.install_worker_running = true;
        self.update_result = self.pendingInstallResultWithStateLocked(.downloading);
    }

    const thread = std.Thread.spawn(.{}, updateInstallThreadMain, .{self}) catch |err| {
        std.debug.print("Update install: failed to spawn thread: {}\n", .{err});
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        self.install_worker_running = false;
        self.install_in_flight = false;
        self.update_result = self.pendingInstallResultWithStateLocked(.install_failed);
        return;
    };

    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    self.install_thread = thread;
}

fn updateInstallThreadMain(app: *App) void {
    var latest_version_buf: [32]u8 = undefined;
    var release_url_buf: [256]u8 = undefined;
    var asset_name_buf: [update_check.asset_name_buffer_len]u8 = undefined;
    var asset_download_url_buf: [update_check.asset_download_url_buffer_len]u8 = undefined;
    const snapshot = blk: {
        app.update_mutex.lock();
        defer app.update_mutex.unlock();
        break :blk PendingInstallSnapshot{
            .update = update_check.copyResult(
                app.pending_install_update,
                .{
                    .latest_version = &latest_version_buf,
                    .release_url = &release_url_buf,
                    .asset_name = &asset_name_buf,
                    .asset_download_url = &asset_download_url_buf,
                },
            ),
            .package = app.pending_install_package,
        };
    };
    const update = snapshot.update;
    if (update.state != .update_available or update.asset_download_url.len == 0) {
        app.storeInstallFailure();
        return;
    }

    var prepared = update_install.prepareWorkPaths(app.allocator, update.latest_version, update.asset_name) catch |err| {
        std.debug.print("Update install: failed to prepare work paths: {}\n", .{err});
        app.storeInstallFailure();
        return;
    };
    defer prepared.deinit(app.allocator);

    update_install.downloadAsset(app.allocator, update.asset_download_url, prepared.zip_path) catch |err| {
        std.debug.print("Update install: failed to download asset: {}\n", .{err});
        app.storeInstallFailure();
        return;
    };
    app.storeTransientUpdateState(.extracting);

    update_install.extractZipToPayload(prepared.zip_path, prepared.payload_dir) catch |err| {
        std.debug.print("Update install: failed to extract asset: {}\n", .{err});
        app.storeInstallFailure();
        return;
    };

    var payload = std.fs.openDirAbsolute(prepared.payload_dir, .{}) catch |err| {
        std.debug.print("Update install: failed to open payload: {}\n", .{err});
        app.storeInstallFailure();
        return;
    };
    defer payload.close();
    update_install.validatePayloadDirForPackage(payload, snapshot.package) catch |err| {
        std.debug.print("Update install: payload validation failed: {}\n", .{err});
        app.storeInstallFailure();
        return;
    };

    const target_dir = update_install.currentExeDir(app.allocator) catch |err| {
        std.debug.print("Update install: failed to resolve current exe dir: {}\n", .{err});
        app.storeInstallFailure();
        return;
    };
    defer app.allocator.free(target_dir);

    app.storeTransientUpdateState(.installing);
    update_install.launchUpdater(
        app.allocator,
        snapshot.package,
        prepared.payload_dir,
        target_dir,
        platform_process.currentProcessId(),
    ) catch |err| {
        std.debug.print("Update install: failed to launch updater: {}\n", .{err});
        app.storeInstallFailure();
        return;
    };

    app.storeInstallLaunched();
    app.requestImmediateShutdown();
}

const PendingInstallSnapshot = struct {
    update: update_check.CheckResult,
    package: update_check.ReleasePackage,
};

fn copyPendingInstallUpdateLocked(self: *App) bool {
    const copied = update_check.copyResult(
        self.available_update,
        .{
            .latest_version = &self.install_latest_version_buf,
            .release_url = &self.install_release_url_buf,
            .asset_name = &self.install_asset_name_buf,
            .asset_download_url = &self.install_asset_download_url_buf,
        },
    );
    if (copied.state != .update_available or copied.asset_download_url.len == 0) return false;
    self.pending_install_update = copied;
    self.pending_install_package = self.available_update_package;
    return true;
}

fn pendingInstallResultWithStateLocked(self: *const App, state: update_check.State) update_check.CheckResult {
    return .{
        .state = state,
        .latest_version = self.pending_install_update.latest_version,
        .release_url = self.pending_install_update.release_url,
        .asset_name = self.pending_install_update.asset_name,
        .asset_download_url = self.pending_install_update.asset_download_url,
        .asset_size = self.pending_install_update.asset_size,
    };
}

fn storeTransientUpdateState(self: *App, state: update_check.State) void {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    self.update_result = self.pendingInstallResultWithStateLocked(state);
}

fn storeInstallFailure(self: *App) void {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    self.install_worker_running = false;
    self.install_in_flight = false;
    self.update_result = self.pendingInstallResultWithStateLocked(.install_failed);
}

fn storeInstallLaunched(self: *App) void {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    self.install_worker_running = false;
    self.update_result = self.pendingInstallResultWithStateLocked(.installing);
}

fn copyBounded(out: []u8, value: []const u8) ?[]const u8 {
    if (out.len == 0 or value.len == 0) return null;
    const len = @min(out.len, value.len);
    @memcpy(out[0..len], value[0..len]);
    return out[0..len];
}

fn joinFinishedInstallThread(self: *App) void {
    var thread: ?std.Thread = null;
    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        if (!self.install_worker_running) {
            thread = self.install_thread;
            self.install_thread = null;
        }
    }
    if (thread) |t| t.join();
}

fn joinFinishedUpdateThread(self: *App) void {
    var thread: ?std.Thread = null;
    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        if (!self.update_check_in_flight) {
            thread = self.update_thread;
            self.update_thread = null;
        }
    }
    if (thread) |t| t.join();
}

fn joinUpdateThread(self: *App) void {
    var thread: ?std.Thread = null;
    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        thread = self.update_thread;
        self.update_thread = null;
    }
    if (thread) |t| t.join();
}

fn joinInstallThread(self: *App) void {
    var thread: ?std.Thread = null;
    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        thread = self.install_thread;
        self.install_thread = null;
    }
    if (thread) |t| t.join();
}

// ============================================================================
// Window Management
// ============================================================================

/// Run the first window on the main thread. Blocks until that window closes.
/// After returning, waits for all spawned window threads to finish.
pub fn run(self: *App) !void {
    // Create and run the first window on the main thread
    var first_window = try AppWindow.init(self.allocator, self);
    defer first_window.deinit();

    // Add to window list
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.windows.append(self.allocator, &first_window);
    }

    // Run blocks until window closes
    first_window.run();

    // Remove from list
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.windows.items, 0..) |w, i| {
            if (w == &first_window) {
                _ = self.windows.swapRemove(i);
                break;
            }
        }
    }

    // Wait for all spawned window threads to finish
    self.joinAllWindowThreads();
}

/// Request a new window to be spawned on a separate thread.
/// Called from the `new_window` keybind in any window.
/// If parent_handle is provided, the new window will cascade from that position.
/// If cwd is provided, the new window's first tab will start in that directory.
pub fn requestNewWindow(self: *App, parent_handle: ?window_backend.NativeHandle, cwd: ?platform_pty_command.CwdSlice) void {
    self.mutex.lock();

    // Get parent window position for cascading
    if (parent_handle) |handle| {
        if (window_backend.windowRectForNativeHandle(handle)) |rect| {
            const new_x = rect.left + 30;
            const new_y = rect.top + 30;
            // Validate that the new position is on a visible monitor
            if (platform_display.isPointOnAnyDisplay(new_x + 50, new_y + 50)) {
                self.next_window_x = new_x;
                self.next_window_y = new_y;
            }
            // If off-screen, don't set position - window will use default
        }
    }

    // Store CWD for new window
    if (cwd) |dir| {
        const len = @min(dir.len, self.next_window_cwd.len - 1);
        @memcpy(self.next_window_cwd[0..len], dir[0..len]);
        self.next_window_cwd[len] = 0;
        self.next_window_cwd_len = len;
    } else {
        self.next_window_cwd_len = 0;
    }

    self.mutex.unlock();

    const thread = std.Thread.spawn(.{}, windowThreadMain, .{self}) catch |err| {
        std.debug.print("Failed to spawn window thread: {}\n", .{err});
        return;
    };

    // Track the thread so we can join it later
    self.mutex.lock();
    defer self.mutex.unlock();
    self.window_threads.append(self.allocator, thread) catch {
        std.debug.print("Failed to track window thread, detaching\n", .{});
        thread.detach();
    };
}

/// Thread entry point for spawned windows.
fn windowThreadMain(app: *App) void {
    // Initialize the native UI thread apartment for platform backends.
    const com_apartment = platform_com.initUiThread();
    defer com_apartment.deinit();

    std.debug.print("Window thread started\n", .{});

    // Create the window
    var window = AppWindow.init(app.allocator, app) catch |err| {
        std.debug.print("Failed to create window: {}\n", .{err});
        return;
    };
    defer window.deinit();

    // Add to window list
    {
        app.mutex.lock();
        defer app.mutex.unlock();
        app.windows.append(app.allocator, &window) catch {
            std.debug.print("Failed to add window to list\n", .{});
        };
    }

    // Run the window (blocks until closed)
    window.run();

    // Remove from list
    {
        app.mutex.lock();
        defer app.mutex.unlock();
        for (app.windows.items, 0..) |w, i| {
            if (w == &window) {
                _ = app.windows.swapRemove(i);
                break;
            }
        }
    }

    std.debug.print("Window thread exiting\n", .{});
}

/// Wait for all spawned window threads to finish.
fn joinAllWindowThreads(self: *App) void {
    // Take ownership of the thread list
    self.mutex.lock();
    const threads = self.window_threads.toOwnedSlice(self.allocator) catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();

    defer self.allocator.free(threads);

    for (threads) |thread| {
        thread.join();
    }
}

// ============================================================================
// Shutdown
// ============================================================================

/// Request all windows to close through the native window backend.
/// The windows will exit their run loops and threads will terminate.
pub fn requestShutdown(self: *App) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.windows.items) |window| {
        if (window.getNativeHandle()) |handle| {
            _ = window_backend.postCloseMessage(handle);
        }
    }
}

/// Request all windows to close without showing interactive close confirmation.
/// Used after launching the updater helper so the old process exits promptly.
pub fn requestImmediateShutdown(self: *App) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.windows.items) |window| {
        window.requestForceClose();
        if (window.getNativeHandle()) |handle| {
            _ = window_backend.postCloseMessage(handle);
        }
    }
}

// ============================================================================
// Cleanup
// ============================================================================

pub fn deinit(self: *App) void {
    // Join any remaining threads
    self.joinAllWindowThreads();
    self.joinUpdateThread();
    self.joinInstallThread();

    if (self.remote_client) |client| {
        client.destroy();
        self.remote_client = null;
    }

    if (self.weixin_controller) |controller| {
        controller.destroy();
        self.weixin_controller = null;
    }

    // Free owned string copies
    self.allocator.free(self.font_family);
    freeOptStr(self.allocator, self.font_family_cjk);
    freeOptStr(self.allocator, self.font_family_fallback);
    freeOptStr(self.allocator, self.shader_path);
    freeOptStr(self.allocator, self.title);
    freeOptStr(self.allocator, self.remote_server_url);
    freeOptStr(self.allocator, self.remote_server_fingerprint);
    freeOptStr(self.allocator, self.remote_device_name);
    freeOptStr(self.allocator, self.remote_session_key);
    freeOptStr(self.allocator, self.background_image);

    self.windows.deinit(self.allocator);
    self.window_threads.deinit(self.allocator);
}

test "app: updateConfig refreshes configured shell command" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const initial_shell = platform_pty_command.configReloadTestInitialShell();
    const next_shell = platform_pty_command.configReloadTestNextShell();

    var cfg = Config{};
    cfg.shell = initial_shell;
    var app = try App.init(allocator, cfg);
    defer app.deinit();

    var next = Config{};
    next.shell = next_shell;
    app.updateConfig(&next);

    var expected_buf: platform_pty_command.CommandLineBuffer = undefined;
    const expected_len = platform_pty_command.resolveShellCommandLine(&expected_buf, next_shell);
    const CommandUnit = @TypeOf(expected_buf[0]);
    try testing.expectEqualSlices(CommandUnit, expected_buf[0..expected_len], app.getShellCmd());
}

test "app: pending install snapshot remains stable when update buffers change" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var app = try App.init(allocator, .{});
    defer app.deinit();

    app.storeUpdateResult(.{
        .state = .update_available,
        .latest_version = "v0.28.0",
        .release_url = "https://example.test/releases/v0.28.0",
        .asset_name = "selected-update.zip",
        .asset_download_url = "https://example.test/selected-update.zip",
        .asset_size = 28,
    }, update_install.runtimePackage(true, true));

    app.update_mutex.lock();
    const copied = app.copyPendingInstallUpdateLocked();
    app.update_mutex.unlock();
    try testing.expect(copied);

    app.storeUpdateResult(.{
        .state = .update_available,
        .latest_version = "v0.29.0",
        .release_url = "https://example.test/releases/v0.29.0",
        .asset_name = "newer-update.zip",
        .asset_download_url = "https://example.test/newer-update.zip",
        .asset_size = 29,
    }, update_install.runtimePackage(false, false));

    app.update_mutex.lock();
    defer app.update_mutex.unlock();
    try testing.expectEqual(update_install.runtimePackage(true, true), app.pending_install_package);
    try testing.expectEqualStrings("v0.28.0", app.pending_install_update.latest_version);
    try testing.expectEqualStrings("https://example.test/releases/v0.28.0", app.pending_install_update.release_url);
    try testing.expectEqualStrings("selected-update.zip", app.pending_install_update.asset_name);
    try testing.expectEqualStrings("https://example.test/selected-update.zip", app.pending_install_update.asset_download_url);
    try testing.expectEqual(@as(u64, 28), app.pending_install_update.asset_size);
}

test "app: installability reports only stored update with download asset" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var app = try App.init(allocator, .{});
    defer app.deinit();

    try testing.expect(!app.hasInstallableUpdate());

    app.storeUpdateResult(.{
        .state = .update_available,
        .latest_version = "v0.28.0",
        .release_url = "https://example.test/releases/v0.28.0",
    }, update_install.runtimePackage(true, false));
    try testing.expect(!app.hasInstallableUpdate());

    app.storeUpdateResult(.{
        .state = .update_available,
        .latest_version = "v0.28.0",
        .release_url = "https://example.test/releases/v0.28.0",
        .asset_name = "installable-update.zip",
        .asset_download_url = "https://example.test/installable-update.zip",
        .asset_size = 28,
    }, update_install.runtimePackage(true, false));
    try testing.expect(app.hasInstallableUpdate());

    app.update_mutex.lock();
    app.install_in_flight = true;
    app.update_mutex.unlock();
    try testing.expect(!app.hasInstallableUpdate());
}

test "app: update check result does not replace install progress while install is active" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var app = try App.init(allocator, .{});
    defer app.deinit();

    app.storeUpdateResult(.{
        .state = .update_available,
        .latest_version = "v0.28.0",
        .release_url = "https://example.test/releases/v0.28.0",
        .asset_name = "installable-update.zip",
        .asset_download_url = "https://example.test/installable-update.zip",
        .asset_size = 28,
    }, update_install.runtimePackage(true, false));

    app.update_mutex.lock();
    try testing.expect(app.copyPendingInstallUpdateLocked());
    app.install_in_flight = true;
    app.install_worker_running = true;
    app.update_result = app.pendingInstallResultWithStateLocked(.downloading);
    app.update_mutex.unlock();

    app.storeUpdateResult(.{
        .state = .update_available,
        .latest_version = "v0.29.0",
        .release_url = "https://example.test/releases/v0.29.0",
        .asset_name = "newer-update.zip",
        .asset_download_url = "https://example.test/newer-update.zip",
        .asset_size = 29,
    }, update_install.runtimePackage(false, false));

    app.update_mutex.lock();
    defer app.update_mutex.unlock();
    try testing.expectEqual(update_check.State.downloading, app.update_result.state);
    try testing.expectEqualStrings("v0.28.0", app.update_result.latest_version);
    try testing.expectEqual(update_install.runtimePackage(true, false), app.pending_install_package);
    try testing.expectEqualStrings("v0.28.0", app.available_update.latest_version);
}

test "app: install launch completion can be joined while duplicate installs stay blocked" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var app = try App.init(allocator, .{});
    defer app.deinit();

    app.storeUpdateResult(.{
        .state = .update_available,
        .latest_version = "v0.28.0",
        .release_url = "https://example.test/releases/v0.28.0",
        .asset_name = "installable-update.zip",
        .asset_download_url = "https://example.test/installable-update.zip",
        .asset_size = 28,
    }, update_install.runtimePackage(true, false));

    app.update_mutex.lock();
    try testing.expect(app.copyPendingInstallUpdateLocked());
    app.install_in_flight = true;
    app.install_worker_running = true;
    app.update_result = app.pendingInstallResultWithStateLocked(.installing);
    app.update_mutex.unlock();

    app.storeInstallLaunched();

    app.update_mutex.lock();
    defer app.update_mutex.unlock();
    try testing.expect(app.install_in_flight);
    try testing.expect(!app.install_worker_running);
    try testing.expectEqual(update_check.State.installing, app.update_result.state);
    try testing.expectEqualStrings("https://example.test/releases/v0.28.0", app.update_result.release_url);
}
