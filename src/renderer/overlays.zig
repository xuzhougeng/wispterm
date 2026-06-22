//! Overlay rendering for AppWindow.
//!
//! Scrollbar (virtual overlay with idle visibility), resize overlay ("cols x rows"),
//! debug overlays (FPS, draw calls), split dividers, and unfocused split overlays.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const ai_chat = @import("../ai_chat.zig");
const ai_chat_protocol = @import("../ai_chat_protocol.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const tab = AppWindow.tab;
const gl_init = AppWindow.gpu.gl_init;
const split_layout = AppWindow.split_layout;
const browser_panel = AppWindow.browser_panel;
const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");
const Config = @import("../config.zig");
const themes_embed = @import("../themes.zig");
const input_key = @import("../input/key.zig");
const hit_test = @import("../input/hit_test.zig");
const ssh_prompt = @import("../ssh_prompt.zig");
const ssh_connection = @import("../ssh_connection.zig");
const app_metadata = @import("../app_metadata.zig");
const command_center_state = @import("../command_center_state.zig");
const command_palette_model = @import("../command_palette_model.zig");
const agent_history = @import("../agent_history.zig");
const platform_dirs = @import("../platform/dirs.zig");
const platform_open_url = @import("../platform/open_url.zig");
const platform_pty_command = @import("../platform/pty_command.zig");
const update_check = @import("../update_check.zig");
const keybind = @import("../keybind.zig");
const overlay_keys = @import("overlay_keys.zig");
const close_confirm = @import("../close_confirm.zig");
const weixin_qr_panel = @import("../weixin/qr_panel.zig");
const weixin_types = @import("../weixin/types.zig");
const i18n = @import("../i18n.zig");
const ai_model_switch = @import("../ai_model_switch.zig");
const claude_integration = @import("../claude_integration.zig");
const platform_atomic_file = @import("../platform/atomic_file.zig");
const agent_detector = @import("../agent_detector.zig");

const ui_pipeline = @import("ui_pipeline.zig");

const TabState = tab.TabState;
const SplitRect = split_layout.SplitRect;
const primitives = @import("overlays/primitives.zig");
const mixColor = primitives.mixColor;
pub const renderRoundedQuadAlpha = primitives.renderRoundedQuadAlpha;
pub const scrollbar = @import("overlays/scrollbar.zig");
pub const resize = @import("overlays/resize.zig");
pub const startup_shortcuts = @import("overlays/startup_shortcuts.zig");
pub const copilot_edge_handle = @import("overlays/copilot_edge_handle.zig");

pub const SCROLLBAR_WIDTH = scrollbar.SCROLLBAR_WIDTH;
pub const ScrollbarGeometry = scrollbar.ScrollbarGeometry;
pub const scrollbarGeometryForSurface = scrollbar.scrollbarGeometryForSurface;
pub const scrollbarGeometry = scrollbar.scrollbarGeometry;
pub const scrollbarShow = scrollbar.scrollbarShow;
pub const scrollbarShowForSurface = scrollbar.scrollbarShowForSurface;
pub const renderScrollbarForSurface = scrollbar.renderScrollbarForSurface;
pub const renderScrollbar = scrollbar.renderScrollbar;
pub const scrollbarHitTest = scrollbar.scrollbarHitTest;
pub const scrollbarHitTestForSurface = scrollbar.scrollbarHitTestForSurface;
pub const scrollbarThumbHitTest = scrollbar.scrollbarThumbHitTest;
pub const scrollbarDrag = scrollbar.scrollbarDrag;
pub const scrollbarDragForSurface = scrollbar.scrollbarDragForSurface;

pub const RESIZE_OVERLAY_DURATION_MS = resize.RESIZE_OVERLAY_DURATION_MS;
pub const resizeOverlayShow = resize.resizeOverlayShow;
pub const renderResizeOverlay = resize.renderResizeOverlay;
pub const renderResizeOverlayWithOffset = resize.renderResizeOverlayWithOffset;
pub const renderResizeOverlayForSurface = resize.renderResizeOverlayForSurface;
pub const STARTUP_SHORTCUTS_DURATION_MS = startup_shortcuts.STARTUP_SHORTCUTS_DURATION_MS;
pub const STARTUP_SHORTCUTS_FADE_MS = startup_shortcuts.STARTUP_SHORTCUTS_FADE_MS;
pub const startupShortcutsShow = startup_shortcuts.startupShortcutsShow;
pub const startupShortcutsDismiss = startup_shortcuts.startupShortcutsDismiss;
pub const startupShortcutsToggle = startup_shortcuts.startupShortcutsToggle;
pub const renderStartupShortcutsOverlay = startup_shortcuts.renderStartupShortcutsOverlay;
pub const renderCopilotEdgeHandle = copilot_edge_handle.render;
pub const copilotEdgeHandleSetTarget = copilot_edge_handle.setProximityTarget;
pub const copilotEdgeHandleSetHovered = copilot_edge_handle.setHovered;
pub const copilotEdgeHandleStartShimmer = copilot_edge_handle.startShimmer;

// ============================================================================
// Split divider rendering
// ============================================================================

const SPLIT_DIVIDER_WIDTH = tab.SPLIT_DIVIDER_WIDTH;

/// Unfocused split opacity (default 0.7, configurable)
pub threadlocal var g_unfocused_split_opacity: f32 = 0.7;

/// Split divider color (null = use scrollbar style with alpha)
pub threadlocal var g_split_divider_color: ?[3]f32 = null;

const DebugLineRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

threadlocal var g_remote_key_copy_rect: ?DebugLineRect = null;
threadlocal var g_remote_key_copied_until_ms: i64 = 0;
// Once the user has copied the active session key (via overlay click or the
// command palette), the floating key overlay is dismissed for that key.
// Stored as a digest so fixed keys can be shorter or longer than 32 bytes.
threadlocal var g_remote_key_dismissed_digest: ?[32]u8 = null;

// Selection copy toast — flashes "Copied" briefly after right-click /
// Ctrl+Shift+C so the user can see that the clipboard write succeeded.
const COPY_TOAST_DURATION_MS: i64 = 1500;
threadlocal var g_copy_toast_until_ms: i64 = 0;
threadlocal var g_copy_toast_buf: [64]u8 = undefined;
threadlocal var g_copy_toast_len: usize = 0;

const TRANSFER_TOAST_DURATION_MS: i64 = 2500;
threadlocal var g_transfer_toast_until_ms: i64 = 0;
threadlocal var g_transfer_toast_sticky: bool = false;
threadlocal var g_transfer_toast_status: AppWindow.file_explorer.TransferStatus = .idle;
threadlocal var g_transfer_toast_clickable: bool = false;
threadlocal var g_transfer_toast_buf: [160]u8 = undefined;
threadlocal var g_transfer_toast_len: usize = 0;

pub const TransferCancelConfirmAction = overlay_keys.TransferCancelConfirmAction;
threadlocal var g_transfer_cancel_confirm_visible: bool = false;

const UPDATE_PROMPT_DURATION_MS: i64 = 10000;
const UPDATE_STATUS_DURATION_MS: i64 = 2500;
const SSH_CWD_HELP_URL = "https://github.com/xuzhougeng/wispterm#ssh-current-directory-for-downloads-and-uploads";
const update_prompt_model = @import("overlays/update_prompt_model.zig");
const UpdatePromptAction = update_prompt_model.UpdatePromptAction;
const md = @import("../markdown_text.zig");
const whats_new_model = @import("overlays/whats_new_model.zig");
threadlocal var g_whats_new_visible: bool = false;
threadlocal var g_whats_new_scroll: i64 = 0;
threadlocal var g_update_prompt_until_ms: i64 = 0;
threadlocal var g_update_prompt_buf: [128]u8 = undefined;
threadlocal var g_update_prompt_len: usize = 0;
threadlocal var g_update_prompt_url_buf: [256]u8 = undefined;
threadlocal var g_update_prompt_url_len: usize = 0;
threadlocal var g_update_prompt_clickable: bool = false;
threadlocal var g_update_prompt_action: UpdatePromptAction = .none;
threadlocal var g_update_prompt_rect: ?DebugLineRect = null;

threadlocal var g_close_shortcut_confirm_until_ms: i64 = 0;

pub const CloseConfirmVariant = enum { running_program, window_generic, terminal_split };
threadlocal var g_window_close_confirm_visible: bool = false;
threadlocal var g_close_confirm_pending: close_confirm.PendingClose = .window;
threadlocal var g_close_confirm_variant: CloseConfirmVariant = .window_generic;

// "Restore default settings" confirmation, shown on top of the settings page.
threadlocal var g_restore_defaults_confirm_visible: bool = false;

const WindowCloseConfirmLayout = struct {
    panel_x: f32,
    panel_top_px: f32,
    panel_w: f32,
    panel_h: f32,
    close_x: f32,
    close_top_px: f32,
    close_w: f32,
    close_h: f32,
    cancel_x: f32,
    cancel_top_px: f32,
    cancel_w: f32,
    cancel_h: f32,
};

const TransferCancelConfirmLayout = struct {
    panel_x: f32,
    panel_top_px: f32,
    panel_w: f32,
    panel_h: f32,
    interrupt_x: f32,
    interrupt_top_px: f32,
    interrupt_w: f32,
    interrupt_h: f32,
    keep_x: f32,
    keep_top_px: f32,
    keep_w: f32,
    keep_h: f32,
};

// ============================================================================
// Command center
// ============================================================================

const COMMAND_PALETTE_FILTER_MAX = 64;
const COMMAND_PALETTE_MAX_VISIBLE_ROWS = 14;

const THEME_OVERRIDE_KEYS = [_][]const u8{
    "background",
    "foreground",
    "cursor-color",
    "cursor-text",
    "selection-background",
    "selection-foreground",
    "palette",
};

const CommandAction = command_center_state.CommandAction;
const CommandEntry = command_center_state.CommandEntry;
const COMMAND_ENTRIES = command_center_state.command_entries;

const PaletteItem = union(enum) {
    command: usize,
    ssh_profile: usize,
    tmux_profile: usize,
    ai_profile: usize,
    theme: usize,
};

const CommandPaletteMode = command_center_state.CommandPaletteMode;

threadlocal var g_palette_scratch: [COMMAND_PALETTE_MAX_VISIBLE_ROWS]PaletteItem = undefined;
threadlocal var g_palette_scratch_len: usize = 0;
threadlocal var g_command_palette_history_rows: []agent_history.Row = &.{};
threadlocal var g_command_palette_history_rows_owned: bool = false;
threadlocal var g_command_palette_history_revision: u64 = 0;

pub threadlocal var g_command_palette_visible: bool = false;
threadlocal var g_command_palette_selected: usize = 0;
threadlocal var g_command_palette_filter: [COMMAND_PALETTE_FILTER_MAX]u8 = undefined;
threadlocal var g_command_palette_filter_len: usize = 0;
threadlocal var g_command_palette_mode: CommandPaletteMode = .commands;
threadlocal var g_command_palette_history_selected: usize = 0;

const CommandPaletteLayout = struct {
    box_x: f32,
    box_top_px: f32,
    box_w: f32,
    box_h: f32,
    header_h: f32,
    filter_h: f32,
    footer_h: f32,
    row_top_px: f32,
    row_h: f32,
    rendered_rows: usize,
};

pub fn commandPaletteVisible() bool {
    return g_command_palette_visible;
}

fn commandPaletteIsHistoryMode() bool {
    return commandCenterStateSnapshot().commandPaletteIsHistoryMode();
}

fn commandPaletteSetMode(mode: CommandPaletteMode) void {
    var state = commandCenterStateSnapshot();
    state.commandPaletteSetMode(mode);
    commandCenterStateCommit(state);
}

fn commandPaletteOpenWithMode(mode: CommandPaletteMode) void {
    var state = commandCenterStateSnapshot();
    state.commandPaletteOpenWithMode(mode);
    commandCenterStateCommit(state);
}

pub fn commandPaletteOpen() void {
    commandPaletteOpenWithMode(.commands);
}

pub fn commandPaletteClose() void {
    var state = commandCenterStateSnapshot();
    state.commandPaletteClose();
    commandCenterStateCommit(state);
}

pub fn commandPaletteToggle() void {
    if (g_command_palette_visible) {
        commandPaletteClose();
    } else {
        commandPaletteOpen();
    }
}

pub fn commandPaletteMove(delta: i32) void {
    if (commandPaletteIsHistoryMode()) return;
    const count = commandPaletteVisibleCount();
    if (count == 0) {
        g_command_palette_selected = 0;
        return;
    }

    const current: i32 = @intCast(g_command_palette_selected);
    const count_i: i32 = @intCast(count);
    var next = current + delta;
    while (next < 0) next += count_i;
    next = @mod(next, count_i);
    g_command_palette_selected = @intCast(next);
}

/// Mouse-wheel handling for the command center. The list scrolls by moving the
/// selection (which the view follows via commandPaletteFirstVisibleIndex),
/// matching the keyboard Up/Down model. Positive delta scrolls toward the top,
/// mirroring whatsNewHandleScroll(). Clamps at the ends so the wheel never wraps.
pub fn commandPaletteHandleScroll(delta_y: f64) void {
    if (!g_command_palette_visible) return;
    const step: i32 = if (delta_y > 0) -1 else if (delta_y < 0) 1 else 0;
    if (step == 0) return;
    if (commandPaletteIsHistoryMode()) {
        commandPaletteMoveAgentHistory(step);
        return;
    }
    const count = commandPaletteVisibleCount();
    if (count == 0) return;
    if (step < 0) {
        if (g_command_palette_selected == 0) return;
    } else if (g_command_palette_selected + 1 >= count) return;
    commandPaletteMove(step);
}

pub fn commandPaletteAgentHistoryVisible() bool {
    return commandPaletteIsHistoryMode();
}

pub fn commandPaletteMoveAgentHistory(delta: i32) void {
    commandPaletteSyncAgentHistoryRows();
    var state = commandCenterStateSnapshot();
    state.commandPaletteMoveAgentHistory(delta, g_command_palette_history_rows.len);
    commandCenterStateCommit(state);
}

pub fn commandPaletteDeleteSelectedAgentHistory() bool {
    if (!commandPaletteIsHistoryMode()) return false;
    commandPaletteSyncAgentHistoryRows();
    const state = commandCenterStateSnapshot();
    const row_idx = state.commandPaletteSelectedAgentHistoryIndex(g_command_palette_history_rows.len) orelse return false;
    return commandPaletteDeleteAgentHistoryIndex(row_idx);
}

pub fn commandPaletteLeaveAgentHistory() void {
    if (!commandPaletteIsHistoryMode()) return;
    var state = commandCenterStateSnapshot();
    state.commandPaletteLeaveAgentHistory();
    commandCenterStateCommit(state);
}

pub fn commandPaletteBackspace() void {
    if (commandPaletteIsHistoryMode()) return;
    if (g_command_palette_filter_len == 0) return;
    // Remove a whole UTF-8 codepoint: walk back over continuation bytes (0b10xxxxxx).
    var n = g_command_palette_filter_len - 1;
    while (n > 0 and (g_command_palette_filter[n] & 0xC0) == 0x80) n -= 1;
    g_command_palette_filter_len = n;
    commandPaletteClampSelection();
}

pub fn commandPaletteClearFilter() void {
    if (commandPaletteIsHistoryMode()) return;
    g_command_palette_filter_len = 0;
    commandPaletteClampSelection();
}

pub fn commandPaletteInsertChar(codepoint: u21) void {
    if (commandPaletteIsHistoryMode()) return;
    if (codepoint < 0x20 or codepoint == 0x7f) return;

    // UTF-8-encode the codepoint so CJK (e.g. IME-committed 中文) is accepted,
    // not just ASCII. Mirrors the terminal char path's utf8Encode.
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return;
    if (g_command_palette_filter_len + len > g_command_palette_filter.len) return;
    @memcpy(g_command_palette_filter[g_command_palette_filter_len..][0..len], buf[0..len]);
    g_command_palette_filter_len += len;
    commandPaletteClampSelection();
}

pub fn commandPaletteExecuteSelected() void {
    if (commandPaletteIsHistoryMode()) {
        _ = commandPaletteActivateSelectedAgentHistory();
        return;
    }
    rebuildPaletteScratch();
    if (g_palette_scratch_len == 0) return;
    if (g_command_palette_selected >= g_palette_scratch_len) return;
    const item = g_palette_scratch[g_command_palette_selected];
    commandPaletteClose();
    executePaletteItem(item);
}

pub fn commandPaletteExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    if (commandPaletteIsHistoryMode()) {
        commandPaletteSyncAgentHistoryRows();
        const row_idx = commandPaletteHistoryHitTestIndex(xpos, ypos, window_width, window_height, top_offset) orelse
            return commandPaletteContainsPoint(xpos, ypos, window_width, window_height, top_offset);
        _ = commandPaletteActivateAgentHistoryRow(row_idx);
        return true;
    }
    const item = commandPaletteHitTest(xpos, ypos, window_width, window_height, top_offset) orelse return false;
    commandPaletteClose();
    executePaletteItem(item);
    return true;
}

pub fn commandPaletteContainsPoint(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const layout = commandPaletteLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    return x >= layout.box_x and x <= layout.box_x + layout.box_w and
        y >= layout.box_top_px and y <= layout.box_top_px + layout.box_h;
}

pub fn closeConfirmOpen(action: close_confirm.PendingClose, variant: CloseConfirmVariant) void {
    g_close_confirm_pending = action;
    g_close_confirm_variant = variant;
    g_window_close_confirm_visible = true;
}

pub fn windowCloseConfirmClose() void {
    g_window_close_confirm_visible = false;
}

fn closeConfirmConfirm() void {
    g_window_close_confirm_visible = false;
    switch (g_close_confirm_pending) {
        .window => AppWindow.g_should_close = true,
        .focused_split => AppWindow.closeFocusedSplit(),
        .tab => |idx| AppWindow.closeTab(idx),
    }
}

pub fn windowCloseConfirmVisible() bool {
    return g_window_close_confirm_visible;
}

pub fn windowCloseConfirmHandleKey(ev: input_key.KeyEvent) void {
    if (!g_window_close_confirm_visible) return;
    switch (close_confirm.keyOutcome(ev)) {
        .confirm => closeConfirmConfirm(),
        .cancel => windowCloseConfirmClose(),
        .none => {},
    }
}

pub fn windowCloseConfirmExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32) bool {
    if (!g_window_close_confirm_visible) return false;
    const layout = windowCloseConfirmLayout(window_width, window_height);
    if (pointInTopRect(xpos, ypos, layout.close_x, layout.close_top_px, layout.close_w, layout.close_h)) {
        closeConfirmConfirm();
        return true;
    }
    if (pointInTopRect(xpos, ypos, layout.cancel_x, layout.cancel_top_px, layout.cancel_w, layout.cancel_h)) {
        windowCloseConfirmClose();
        return true;
    }
    return pointInTopRect(xpos, ypos, layout.panel_x, layout.panel_top_px, layout.panel_w, layout.panel_h);
}

pub fn restoreDefaultsConfirmOpen() void {
    g_restore_defaults_confirm_visible = true;
}

pub fn restoreDefaultsConfirmClose() void {
    g_restore_defaults_confirm_visible = false;
}

pub fn restoreDefaultsConfirmVisible() bool {
    return g_restore_defaults_confirm_visible;
}

/// Reset the settings-page keys to their defaults, then refresh the live config
/// so the settings page reflects the change immediately, and close the dialog.
fn restoreDefaultsConfirmApply() void {
    const allocator = AppWindow.g_allocator orelse {
        restoreDefaultsConfirmClose();
        return;
    };
    Config.resetSettingsToDefaults(allocator) catch {};
    settingsPageReloadCfg();
    restoreDefaultsConfirmClose();
}

pub fn restoreDefaultsConfirmHandleKey(ev: input_key.KeyEvent) void {
    if (!g_restore_defaults_confirm_visible) return;
    switch (ev.key) {
        .enter => restoreDefaultsConfirmApply(),
        .escape => restoreDefaultsConfirmClose(),
        else => {},
    }
}

/// Mouse handling for the restore-defaults dialog. Returns true when the click
/// was consumed (a button or anywhere inside the panel), mirroring
/// windowCloseConfirmExecuteAt so clicks never fall through to the settings page.
pub fn restoreDefaultsConfirmExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32) bool {
    if (!g_restore_defaults_confirm_visible) return false;
    const layout = windowCloseConfirmLayout(window_width, window_height);
    if (pointInTopRect(xpos, ypos, layout.close_x, layout.close_top_px, layout.close_w, layout.close_h)) {
        restoreDefaultsConfirmApply();
        return true;
    }
    if (pointInTopRect(xpos, ypos, layout.cancel_x, layout.cancel_top_px, layout.cancel_w, layout.cancel_h)) {
        restoreDefaultsConfirmClose();
        return true;
    }
    return pointInTopRect(xpos, ypos, layout.panel_x, layout.panel_top_px, layout.panel_w, layout.panel_h);
}

pub fn transferCancelConfirmOpen() void {
    g_transfer_cancel_confirm_visible = true;
}

pub fn transferCancelConfirmClose() void {
    g_transfer_cancel_confirm_visible = false;
}

pub fn transferCancelConfirmVisible() bool {
    return g_transfer_cancel_confirm_visible;
}

pub fn transferCancelConfirmHandleKey(ev: input_key.KeyEvent) TransferCancelConfirmAction {
    if (!g_transfer_cancel_confirm_visible) return .none;
    const action = overlay_keys.transferCancelConfirmAction(ev);
    if (action != .none) transferCancelConfirmClose();
    return action;
}

pub fn transferCancelConfirmExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32) TransferCancelConfirmAction {
    if (!g_transfer_cancel_confirm_visible) return .none;
    const layout = transferCancelConfirmLayout(window_width, window_height);
    if (pointInTopRect(xpos, ypos, layout.interrupt_x, layout.interrupt_top_px, layout.interrupt_w, layout.interrupt_h)) {
        transferCancelConfirmClose();
        return .interrupt;
    }
    if (pointInTopRect(xpos, ypos, layout.keep_x, layout.keep_top_px, layout.keep_w, layout.keep_h)) {
        transferCancelConfirmClose();
        return .keep;
    }
    if (pointInTopRect(xpos, ypos, layout.panel_x, layout.panel_top_px, layout.panel_w, layout.panel_h)) return .none;
    transferCancelConfirmClose();
    return .keep;
}

fn transferCancelConfirmLayoutForTest(window_width: f32, window_height: f32) TransferCancelConfirmLayout {
    return transferCancelConfirmLayout(window_width, window_height);
}

fn transferCancelConfirmExecuteAtForTest(xpos: f32, ypos: f32, window_width: f32, window_height: f32) TransferCancelConfirmAction {
    return transferCancelConfirmExecuteAt(xpos, ypos, window_width, window_height);
}

fn executeCommand(action: CommandAction) void {
    switch (action) {
        .new_tab => sessionLauncherOpenFromCommandPalette(),
        .load_openssh_config => loadOpenSshConfigDefault(),
        .new_agent => openDefaultAgentSessionFromCommandCenter(),
        .toggle_ai_copilot => AppWindow.toggleAiCopilot(),
        .manage_ai_profiles => openAiListFromCommandPalette(),
        .select_agent_history => commandPaletteOpenAgentHistory(),
        .split_right => AppWindow.splitFocused(.right),
        .split_down => AppWindow.splitFocused(.down),
        .split_left => AppWindow.splitFocused(.left),
        .split_up => AppWindow.splitFocused(.up),
        .focus_previous => _ = AppWindow.gotoSplit(.previous_wrapped),
        .focus_next => _ = AppWindow.gotoSplit(.next_wrapped),
        .equalize_splits => AppWindow.equalizeSplits(),
        .close_split_or_tab => AppWindow.input.closePanelOrTab(),
        .toggle_sidebar => AppWindow.input.toggleSidebar(),
        .toggle_file_explorer => AppWindow.input.toggleFileExplorer(),
        .toggle_browser_panel => AppWindow.input.toggleBrowserPanel(),
        .open_jupyter_panel => AppWindow.input.openJupyterPanel(),
        .toggle_quake => AppWindow.toggleQuakeVisibility(),
        .open_settings => settingsPageOpen(),
        .show_shortcuts => startupShortcutsShow(),
        .open_config => if (AppWindow.g_allocator) |alloc| Config.openConfigInEditor(alloc),
        .font_size_decrease => AppWindow.input.adjustFontSize(-1),
        .font_size_increase => AppWindow.input.adjustFontSize(1),
        .toggle_maximize => AppWindow.input.toggleMaximize(),
        .copy_remote_key => {
            _ = AppWindow.input.copyRemoteSessionKeyToClipboard();
        },
        .connect_wechat => connectWeixinDirect(),
        .start_wechat => startWeixinDirect(),
        .stop_wechat => stopWeixinDirect(),
        .wechat_status => showWeixinDirectStatus(),
        .unbind_wechat => unbindWeixinDirect(),
        .export_ai_chat_markdown => AppWindow.exportActiveAiChatMarkdown(.full),
        .export_ai_chat_markdown_clean => AppWindow.exportActiveAiChatMarkdown(.clean),
        .show_version => showVersionToast(),
        .check_for_updates => {
            showUpdateCheckingToast();
            if (AppWindow.g_app) |app| app.requestManualUpdateCheck();
        },
        .download_update => {
            if (AppWindow.g_app) |app| {
                if (app.hasDownloadableUpdate()) {
                    showUpdatePrompt(.{ .state = .downloading }, .none);
                    app.requestUpdateDownload();
                } else {
                    showUpdateDownloadUnavailableToast();
                }
            } else {
                showUpdateDownloadUnavailableToast();
            }
        },
        .open_latest_release => openLatestRelease(),
        .show_whats_new => showWhatsNew(),
        .install_claude_code_integration => installClaudeCodeIntegration(),
        .remove_claude_code_integration => removeClaudeCodeIntegration(),
        .open_skill_center => {
            _ = AppWindow.spawnSkillCenterTab();
        },
        .open_port_forwarding => {
            _ = AppWindow.spawnPortForwardingTab();
        },
        .split_preview => {
            if (AppWindow.g_allocator) |gpa| {
                // Focus the new (empty) preview so Ctrl+Shift+W closes it.
                if (AppWindow.tab.splitIntoPreview(gpa)) |pane| {
                    _ = AppWindow.tab.focusPreviewPane(pane);
                }
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
            }
        },
    }
}

fn activeWeixinController() ?*weixin_qr_panel.Controller {
    const app = AppWindow.g_app orelse return null;
    return app.weixin_controller;
}

fn connectWeixinDirect() void {
    const allocator = AppWindow.g_allocator orelse std.heap.page_allocator;
    const controller = activeWeixinController() orelse {
        showStatusToast(i18n.s().toast_enable_weixin_first);
        return;
    };
    weixin_qr_panel.start(allocator, controller) catch {
        showStatusToast(i18n.s().toast_wechat_login_failed);
        return;
    };
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn startWeixinDirect() void {
    const controller = activeWeixinController() orelse {
        showStatusToast(i18n.s().toast_enable_weixin_first);
        return;
    };
    const before = controller.statusSnapshot();
    if (before.running) {
        showStatusToast(i18n.s().toast_wechat_poller_already_running);
        return;
    }
    controller.start() catch |err| {
        std.debug.print("weixin direct start failed from command palette: {}\n", .{err});
        showStatusToast(i18n.s().toast_wechat_start_failed);
        return;
    };
    const after = controller.statusSnapshot();
    if (after.running) {
        showStatusToast(i18n.s().toast_wechat_poller_started);
    } else if (after.has_token) {
        showStatusToast(i18n.s().toast_wechat_binding_saved_stopped);
    } else {
        showStatusToast(i18n.s().toast_wechat_not_connected);
    }
}

fn stopWeixinDirect() void {
    const controller = activeWeixinController() orelse {
        showStatusToast(i18n.s().toast_wechat_not_active);
        return;
    };
    const before = controller.statusSnapshot();
    if (!before.running and !before.has_token and !before.login_active) {
        showStatusToast(i18n.s().toast_wechat_not_connected);
        return;
    }
    controller.stop();
    if (before.running) {
        showStatusToast(i18n.s().toast_wechat_poller_stopped);
    } else if (before.login_active) {
        showStatusToast(i18n.s().toast_wechat_login_waiting);
    } else {
        showStatusToast(i18n.s().toast_wechat_poller_already_stopped);
    }
}

fn showWeixinDirectStatus() void {
    const controller = activeWeixinController() orelse {
        showStatusToast(i18n.s().toast_wechat_direct_disabled);
        return;
    };
    const s = controller.statusSnapshot();
    var buf: [64]u8 = undefined;
    const msg = weixinStatusMessage(&buf, s);
    showStatusToast(msg);
}

fn weixinStatusMessage(buf: []u8, s: weixin_qr_panel.Controller.Status) []const u8 {
    if (s.login_active) {
        return std.fmt.bufPrint(buf, "WeChat login: {s}", .{weixinLoginStatusName(s.login_status)}) catch "WeChat login active";
    }
    if (s.running) {
        return std.fmt.bufPrint(buf, "WeChat running (owner={s}, bot={s})", .{ yesNo(s.has_owner), yesNo(s.has_bot_id) }) catch "WeChat running";
    }
    if (s.has_token) return "WeChat stopped (binding saved)";
    return "WeChat not connected";
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn weixinLoginStatusName(status: weixin_types.QrStatusKind) []const u8 {
    return switch (status) {
        .wait => "waiting",
        .scaned => "scanned",
        .confirmed => "confirmed",
        .expired => "expired",
        .unknown => "unknown",
    };
}

fn unbindWeixinDirect() void {
    const controller = activeWeixinController() orelse {
        showStatusToast(i18n.s().toast_wechat_not_active);
        return;
    };
    controller.unbind() catch {
        showStatusToast(i18n.s().toast_wechat_unbind_failed);
        return;
    };
    weixin_qr_panel.close();
    showStatusToast(i18n.s().toast_wechat_unbound);
}

pub fn weixinQrPanelHandleAction(action: weixin_qr_panel.Action) void {
    switch (action) {
        .none => {},
        .close => {
            if (weixin_qr_panel.controller()) |controller| controller.cancelLogin();
            weixin_qr_panel.close();
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        },
        .retry => {
            const allocator = AppWindow.g_allocator orelse std.heap.page_allocator;
            const controller = weixin_qr_panel.controller() orelse activeWeixinController() orelse {
                showStatusToast(i18n.s().toast_wechat_not_active);
                return;
            };
            weixin_qr_panel.start(allocator, controller) catch {
                showStatusToast(i18n.s().toast_wechat_login_failed);
                return;
            };
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        },
        .unbind => unbindWeixinDirect(),
    }
}

pub fn commandPaletteOpenAgentHistory() void {
    var state = commandCenterStateSnapshot();
    state.commandPaletteOpenAgentHistory();
    commandCenterStateCommit(state);
    commandPaletteRefreshAgentHistoryRows();
}

fn commandPaletteFilter() []const u8 {
    return g_command_palette_filter[0..g_command_palette_filter_len];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return command_palette_model.containsIgnoreCase(haystack, needle);
}

fn commandEntryMatches(entry: CommandEntry) bool {
    const filter = commandPaletteFilter();
    if (filter.len == 0) return true;
    return commandEntryTitleMatches(entry, filter) or commandEntrySecondaryMatches(entry, filter);
}

fn commandEntryTitleMatches(entry: CommandEntry, filter: []const u8) bool {
    // Match the English source title always (so e.g. typing "settings" finds 设置),
    // plus the localized title (so 中文 search works too).
    if (containsIgnoreCase(entry.title, filter)) return true;
    if (i18n.commandTitle(entry.action)) |localized| {
        if (containsIgnoreCase(localized, filter)) return true;
    }
    return false;
}

fn commandEntrySecondaryMatches(entry: CommandEntry, filter: []const u8) bool {
    var shortcut_buf: [64]u8 = undefined;
    if (containsIgnoreCase(entry.detail, filter)) return true;
    if (i18n.commandDetail(entry.action)) |localized| {
        if (containsIgnoreCase(localized, filter)) return true;
    }
    return containsIgnoreCase(commandEntryShortcut(entry, &shortcut_buf), filter);
}

test "tmuxSessionName sanitizes a profile name to a tmux-safe session name" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("wispterm-NGS00", tmuxSessionName(&buf, "NGS00"));
    try std.testing.expectEqualStrings("wispterm-prod_db_1", tmuxSessionName(&buf, "prod.db:1"));
    try std.testing.expectEqualStrings("wispterm-a_b_c", tmuxSessionName(&buf, "a b\tc"));
    try std.testing.expectEqualStrings("wispterm", tmuxSessionName(&buf, ""));
}

test "command palette filter accepts UTF-8 CJK and backspaces whole codepoints" {
    commandPaletteClearFilter();
    defer commandPaletteClearFilter();
    commandPaletteInsertChar('a'); // ASCII (1 byte)
    commandPaletteInsertChar(0x8BBE); // 设 (3 bytes)
    commandPaletteInsertChar(0x7F6E); // 置 (3 bytes)
    try std.testing.expectEqualStrings("a设置", commandPaletteFilter());
    commandPaletteBackspace(); // removes 置 as one codepoint, not one byte
    try std.testing.expectEqualStrings("a设", commandPaletteFilter());
    commandPaletteBackspace();
    try std.testing.expectEqualStrings("a", commandPaletteFilter());
    commandPaletteBackspace();
    try std.testing.expectEqualStrings("", commandPaletteFilter());
}

test "command palette matches English source even when title is localized" {
    defer i18n.setLang(.en);
    const entry = CommandEntry{
        .title = "Settings",
        .detail = "Open the settings page",
        .shortcut = "",
        .action = .open_settings,
    };
    i18n.setLang(.zh_CN);
    try std.testing.expect(commandEntryTitleMatches(entry, "settings")); // English finds the zh-labeled command
    try std.testing.expect(commandEntryTitleMatches(entry, "设置")); // Chinese also matches
    try std.testing.expect(!commandEntryTitleMatches(entry, "zzz"));
    i18n.setLang(.en);
    try std.testing.expect(commandEntryTitleMatches(entry, "Settings"));
    try std.testing.expect(!commandEntryTitleMatches(entry, "设置")); // no localized title under en
}

fn setCommandPaletteFilterForTest(filter: []const u8) void {
    const len = @min(filter.len, g_command_palette_filter.len);
    @memcpy(g_command_palette_filter[0..len], filter[0..len]);
    g_command_palette_filter_len = len;
    g_command_palette_selected = 0;
}

fn paletteContainsSshProfileForTest(profile_idx: usize) bool {
    for (g_palette_scratch[0..g_palette_scratch_len]) |item| {
        switch (item) {
            .ssh_profile => |idx| {
                if (idx == profile_idx) return true;
            },
            else => {},
        }
    }
    return false;
}

fn paletteContainsTmuxProfileForTest(profile_idx: usize) bool {
    for (g_palette_scratch[0..g_palette_scratch_len]) |item| {
        switch (item) {
            .tmux_profile => |idx| {
                if (idx == profile_idx) return true;
            },
            else => {},
        }
    }
    return false;
}

test "command palette includes tmux profile actions for SSH profile search" {
    const previous_mode = g_command_palette_mode;
    const previous_filter_len = g_command_palette_filter_len;
    var previous_filter: [COMMAND_PALETTE_FILTER_MAX]u8 = undefined;
    if (previous_filter_len > 0) @memcpy(previous_filter[0..previous_filter_len], g_command_palette_filter[0..previous_filter_len]);
    const previous_selected = g_command_palette_selected;
    const previous_scratch_len = g_palette_scratch_len;
    const previous_ssh_loaded = g_ssh_profiles_loaded;
    const previous_ssh_count = g_ssh_profile_count;
    var previous_ssh_profiles: [SSH_PROFILE_MAX]SshProfile = undefined;
    if (previous_ssh_count > 0) @memcpy(previous_ssh_profiles[0..previous_ssh_count], g_ssh_profiles[0..previous_ssh_count]);
    const previous_ai_loaded = g_ai_profiles_loaded;
    const previous_ai_count = g_ai_profile_count;
    var previous_ai_profiles: [AI_PROFILE_MAX]AiProfile = undefined;
    if (previous_ai_count > 0) @memcpy(previous_ai_profiles[0..previous_ai_count], g_ai_profiles[0..previous_ai_count]);
    defer {
        g_command_palette_mode = previous_mode;
        g_command_palette_filter_len = previous_filter_len;
        if (previous_filter_len > 0) @memcpy(g_command_palette_filter[0..previous_filter_len], previous_filter[0..previous_filter_len]);
        g_command_palette_selected = previous_selected;
        g_palette_scratch_len = previous_scratch_len;
        g_ssh_profiles_loaded = previous_ssh_loaded;
        g_ssh_profile_count = previous_ssh_count;
        if (previous_ssh_count > 0) @memcpy(g_ssh_profiles[0..previous_ssh_count], previous_ssh_profiles[0..previous_ssh_count]);
        g_ai_profiles_loaded = previous_ai_loaded;
        g_ai_profile_count = previous_ai_count;
        if (previous_ai_count > 0) @memcpy(g_ai_profiles[0..previous_ai_count], previous_ai_profiles[0..previous_ai_count]);
    }

    g_command_palette_mode = .commands;
    g_ssh_profiles_loaded = true;
    g_ssh_profile_count = 2;
    g_ssh_profiles[0] = makeSshProfile("CPU2", "10.0.0.1", "user", "22");
    g_ssh_profiles[1] = makeSshProfile("GPU", "10.0.0.2", "user", "22");
    g_ai_profiles_loaded = true;
    g_ai_profile_count = 0;

    setCommandPaletteFilterForTest("CPU");
    rebuildPaletteScratch();
    try std.testing.expect(paletteContainsSshProfileForTest(0));
    try std.testing.expect(paletteContainsTmuxProfileForTest(0));
    try std.testing.expect(!paletteContainsTmuxProfileForTest(1));

    setCommandPaletteFilterForTest("tmux");
    rebuildPaletteScratch();
    try std.testing.expect(paletteContainsTmuxProfileForTest(0));
    try std.testing.expect(paletteContainsTmuxProfileForTest(1));
}

fn commandEntryKeybindAction(action: CommandAction) ?keybind.Action {
    return switch (action) {
        .new_tab => .new_session,
        .split_right => .split_right,
        .split_down => .split_down,
        .focus_previous => .focus_previous,
        .focus_next => .focus_next,
        .equalize_splits => .equalize_splits,
        .close_split_or_tab => .close_panel_or_tab,
        .toggle_sidebar => .toggle_sidebar,
        .toggle_file_explorer => .toggle_file_explorer,
        .toggle_quake => .toggle_quake,
        .open_config => .open_config,
        .font_size_decrease => .font_size_decrease,
        .font_size_increase => .font_size_increase,
        .toggle_maximize => .toggle_maximize,
        else => null,
    };
}

fn commandEntryShortcut(entry: CommandEntry, buf: []u8) []const u8 {
    if (commandEntryKeybindAction(entry.action)) |action| {
        if (keybind.formatActionShortcut(&AppWindow.g_keybinds, action, buf)) |shortcut| return shortcut;
        return "";
    }
    return entry.shortcut;
}

fn rebuildPaletteScratch() void {
    if (commandPaletteIsHistoryMode()) {
        g_palette_scratch_len = 0;
        return;
    }
    const filter = commandPaletteFilter();
    g_palette_scratch_len = 0;

    if (filter.len == 0) {
        for (COMMAND_ENTRIES, 0..) |entry, idx| {
            if (!commandEntryMatches(entry)) continue;
            if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
            g_palette_scratch[g_palette_scratch_len] = .{ .command = idx };
            g_palette_scratch_len += 1;
        }
        return;
    }

    for (COMMAND_ENTRIES, 0..) |entry, idx| {
        if (!commandEntryTitleMatches(entry, filter)) continue;
        if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
        g_palette_scratch[g_palette_scratch_len] = .{ .command = idx };
        g_palette_scratch_len += 1;
    }
    for (COMMAND_ENTRIES, 0..) |entry, idx| {
        if (commandEntryTitleMatches(entry, filter)) continue;
        if (!commandEntrySecondaryMatches(entry, filter)) continue;
        if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
        g_palette_scratch[g_palette_scratch_len] = .{ .command = idx };
        g_palette_scratch_len += 1;
    }
    loadSshProfiles();
    for (0..g_ssh_profile_count) |profile_idx| {
        if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
        const profile = &g_ssh_profiles[profile_idx];
        const name = profileField(profile, .name);
        if (command_palette_model.sshProfileNameMatchesFilter(name, filter)) {
            g_palette_scratch[g_palette_scratch_len] = .{ .ssh_profile = profile_idx };
            g_palette_scratch_len += 1;
            if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
        }
        if (command_palette_model.tmuxProfileMatchesFilter(name, filter)) {
            g_palette_scratch[g_palette_scratch_len] = .{ .tmux_profile = profile_idx };
            g_palette_scratch_len += 1;
        }
    }
    loadAiProfiles();
    for (0..g_ai_profile_count) |ai_idx| {
        if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
        const profile = &g_ai_profiles[ai_idx];
        if (!command_palette_model.aiProfileLabelMatchesFilter(aiProfileField(profile, .name), filter)) continue;
        g_palette_scratch[g_palette_scratch_len] = .{ .ai_profile = ai_idx };
        g_palette_scratch_len += 1;
    }
    for (&themes_embed.entries, 0..) |th, ti| {
        if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
        if (!containsIgnoreCase(th.name, filter)) continue;
        g_palette_scratch[g_palette_scratch_len] = .{ .theme = ti };
        g_palette_scratch_len += 1;
    }
}

fn executePaletteItem(item: PaletteItem) void {
    switch (item) {
        .command => |cmd_idx| executeCommand(COMMAND_ENTRIES[cmd_idx].action),
        .ssh_profile => |profile_idx| connectSshProfile(profile_idx),
        .tmux_profile => |profile_idx| connectSshProfileTmux(profile_idx),
        .ai_profile => |profile_idx| _ = spawnAiProfileWithAgentOverride(profile_idx, null),
        .theme => |ti| applyEmbeddedThemeFromPalette(ti),
    }
}

fn commandPaletteClearAgentHistoryRows() void {
    if (!g_command_palette_history_rows_owned) {
        g_command_palette_history_rows = &.{};
        g_command_palette_history_revision = 0;
        return;
    }
    const allocator = AppWindow.g_allocator orelse {
        g_command_palette_history_rows = &.{};
        g_command_palette_history_rows_owned = false;
        g_command_palette_history_revision = 0;
        return;
    };
    agent_history.freeRows(allocator, g_command_palette_history_rows);
    g_command_palette_history_rows = &.{};
    g_command_palette_history_rows_owned = false;
    g_command_palette_history_revision = 0;
}

fn commandPaletteRefreshAgentHistoryRows() void {
    commandPaletteClearAgentHistoryRows();
    const allocator = AppWindow.g_allocator orelse return;
    const snapshot = AppWindow.snapshotAgentHistoryRowsForCommandPalette(allocator) catch return;
    g_command_palette_history_rows = snapshot.rows;
    g_command_palette_history_rows_owned = true;
    g_command_palette_history_revision = snapshot.revision;
}

fn commandPaletteSyncAgentHistoryRows() void {
    const state = commandCenterStateSnapshot();
    if (!state.commandPaletteShouldRefreshAgentHistory(
        g_command_palette_history_revision,
        AppWindow.agentHistoryRevision(),
    )) return;
    commandPaletteRefreshAgentHistoryRows();
}

fn applyEmbeddedThemeFromPalette(theme_index: usize) void {
    const allocator = AppWindow.g_allocator orelse return;
    if (theme_index >= themes_embed.entries.len) return;
    Config.removeConfigKeys(allocator, &THEME_OVERRIDE_KEYS) catch {};
    Config.setConfigValue(allocator, "theme", themes_embed.entries[theme_index].name) catch {};
    AppWindow.reloadConfigImmediate(allocator);
}

fn commandPaletteVisibleCount() usize {
    rebuildPaletteScratch();
    return g_palette_scratch_len;
}

fn commandPaletteResultCount() usize {
    if (commandPaletteIsHistoryMode()) return g_command_palette_history_rows.len;
    return commandPaletteVisibleCount();
}

fn commandPaletteClampSelection() void {
    const count = commandPaletteVisibleCount();
    if (count == 0) {
        g_command_palette_selected = 0;
    } else if (g_command_palette_selected >= count) {
        g_command_palette_selected = count - 1;
    }
}

fn overlayTextHeight() f32 {
    return @max(1.0, font.g_titlebar_cell_height);
}

/// Clamp an overlay box height so the centered panel never paints past the
/// content area on very short windows. The *RowCapacity helpers already size the
/// box to fit in the common case; this guards the degenerate case where even the
/// header + one row + footer exceeds the window.
fn clampOverlayBoxHeight(box_h: f32, content_height: f32) f32 {
    return @max(1.0, @min(box_h, content_height - 32.0));
}

fn overlayLineHeight() f32 {
    return @round(@max(24.0, overlayTextHeight() + 8.0));
}

fn overlayRowHeight(min_h: f32) f32 {
    return @round(@max(min_h, overlayTextHeight() + 14.0));
}

fn overlayControlHeight(min_h: f32) f32 {
    return @round(@max(min_h, overlayTextHeight() + 12.0));
}

fn textYFromTop(window_height: f32, top_px: f32) f32 {
    return @round(window_height - top_px - overlayTextHeight());
}

fn rowTextY(row_y: f32, row_h: f32) f32 {
    return @round(row_y + (row_h - overlayTextHeight()) / 2.0);
}

fn commandPaletteRowCapacity(content_height: f32, base_h: f32, row_h: f32) usize {
    const usable_h = @max(row_h, content_height - 32.0 - base_h);
    if (usable_h <= row_h) return 1;
    const count_f = @floor(usable_h / row_h);
    const count: usize = @intFromFloat(@max(1.0, count_f));
    return @min(count, COMMAND_PALETTE_MAX_VISIBLE_ROWS);
}

fn commandPaletteFirstVisibleIndex(rendered_rows: usize) usize {
    const count = commandPaletteResultCount();
    if (rendered_rows == 0 or count <= rendered_rows) return 0;
    const selected = if (commandPaletteIsHistoryMode())
        @min(g_command_palette_history_selected, count - 1)
    else
        @min(g_command_palette_selected, count - 1);
    if (selected < rendered_rows) return 0;
    return @min(selected - rendered_rows + 1, count - rendered_rows);
}

fn commandPaletteLayout(window_width: f32, window_height: f32, top_offset: f32) CommandPaletteLayout {
    const content_height = @max(1, window_height - top_offset);
    const visible_count = commandPaletteResultCount();

    const box_w = @round(@min(@max(520, window_width - 64), 760));
    const row_h = overlayRowHeight(38);
    const header_h = @round(@max(48.0, overlayTextHeight() + 30.0));
    const filter_h = overlayControlHeight(42);
    const footer_h = @round(@max(34.0, overlayTextHeight() + 18.0));
    const base_h = header_h + filter_h + 12 + footer_h;
    const max_rows = commandPaletteRowCapacity(content_height, base_h, row_h);
    const rendered_rows = @min(visible_count, max_rows);
    const row_area_h = row_h * @as(f32, @floatFromInt(@max(rendered_rows, 1)));
    const box_h = @round(clampOverlayBoxHeight(base_h + row_area_h, content_height));
    const box_x = @round(@max(16, (window_width - box_w) / 2));
    const box_top_px = @round(top_offset + @max(16, (content_height - box_h) / 2));
    const row_top_px = @round(box_top_px + header_h + filter_h + 12);

    return .{
        .box_x = box_x,
        .box_top_px = box_top_px,
        .box_w = box_w,
        .box_h = box_h,
        .header_h = header_h,
        .filter_h = filter_h,
        .footer_h = footer_h,
        .row_top_px = row_top_px,
        .row_h = row_h,
        .rendered_rows = rendered_rows,
    };
}

pub const ImeCaretPx = struct { x: f32, y: f32, h: f32 };

/// Pixel position (top-down client coords) of the command-palette filter caret,
/// so the OS IME composition/candidate window anchors to the filter — not the
/// underlying terminal/AI-chat cursor. Returns null when the palette is not in
/// text-filter mode. Inputs must match what renderCommandPalette is called with.
pub fn commandPaletteImeCaret(window_width: f32, window_height: f32, top_offset: f32) ?ImeCaretPx {
    if (!g_command_palette_visible) return null;
    if (commandPaletteIsHistoryMode()) return null; // history mode has no text filter
    const layout = commandPaletteLayout(window_width, window_height, top_offset);
    const pad_x: f32 = 24; // must match renderCommandPalette
    const text_x = @round(layout.box_x + pad_x) + 12;
    const cell_h = font.g_titlebar_cell_height;
    return .{
        .x = text_x + measureTitlebarText(commandPaletteFilter()),
        .y = layout.box_top_px + layout.header_h + (layout.filter_h - cell_h) / 2,
        .h = cell_h,
    };
}

fn commandPaletteHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) ?PaletteItem {
    const layout = commandPaletteLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    if (x < layout.box_x or x > layout.box_x + layout.box_w) return null;
    if (y < layout.row_top_px) return null;

    const row_f = (y - layout.row_top_px) / layout.row_h;
    if (row_f < 0) return null;
    const row: usize = @intFromFloat(@floor(row_f));
    rebuildPaletteScratch();
    if (row >= layout.rendered_rows) return null;
    const item_idx = commandPaletteFirstVisibleIndex(layout.rendered_rows) + row;
    if (item_idx >= g_palette_scratch_len) return null;
    return g_palette_scratch[item_idx];
}

fn commandPaletteHistoryHitTestIndex(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) ?usize {
    const layout = commandPaletteLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    if (x < layout.box_x or x > layout.box_x + layout.box_w) return null;
    if (y < layout.row_top_px) return null;

    const row_f = (y - layout.row_top_px) / layout.row_h;
    if (row_f < 0) return null;
    const row: usize = @intFromFloat(@floor(row_f));
    if (row >= layout.rendered_rows) return null;

    const item_idx = commandPaletteFirstVisibleIndex(layout.rendered_rows) + row;
    if (item_idx >= g_command_palette_history_rows.len) return null;
    return item_idx;
}

fn commandPaletteActivateSelectedAgentHistory() bool {
    if (!commandPaletteIsHistoryMode()) return false;
    commandPaletteSyncAgentHistoryRows();
    const state = commandCenterStateSnapshot();
    const row_idx = state.commandPaletteActivateSelected(g_command_palette_history_rows.len) orelse return false;
    return commandPaletteActivateAgentHistoryIndex(row_idx);
}

fn commandPaletteActivateAgentHistoryRow(row_idx: usize) bool {
    if (!commandPaletteIsHistoryMode()) return false;
    commandPaletteSyncAgentHistoryRows();
    var state = commandCenterStateSnapshot();
    _ = state.commandPaletteActivateHistoryRow(row_idx, g_command_palette_history_rows.len) orelse return false;
    commandCenterStateCommit(state);
    return commandPaletteActivateAgentHistoryIndex(row_idx);
}

fn commandPaletteActivateAgentHistoryIndex(row_idx: usize) bool {
    if (!commandPaletteIsHistoryMode()) return false;
    if (row_idx >= g_command_palette_history_rows.len) return false;
    if (AppWindow.reopenAiChatTabFromHistorySessionId(g_command_palette_history_rows[row_idx].session_id)) {
        commandPaletteClose();
        return true;
    }

    const allocator = AppWindow.g_allocator orelse return false;
    const session_id = allocator.dupe(u8, g_command_palette_history_rows[row_idx].session_id) catch return false;
    defer allocator.free(session_id);

    commandPaletteRefreshAgentHistoryRows();

    var state = commandCenterStateSnapshot();
    const refreshed_idx = findAgentHistoryRowBySessionId(session_id) orelse {
        state.commandPaletteClampAgentHistorySelection(g_command_palette_history_rows.len);
        commandCenterStateCommit(state);
        return false;
    };
    _ = state.commandPaletteActivateHistoryRow(refreshed_idx, g_command_palette_history_rows.len) orelse return false;
    commandCenterStateCommit(state);

    if (!AppWindow.reopenAiChatTabFromHistorySessionId(g_command_palette_history_rows[refreshed_idx].session_id)) return false;
    commandPaletteClose();
    return true;
}

fn commandPaletteDeleteAgentHistoryIndex(row_idx: usize) bool {
    if (!commandPaletteIsHistoryMode()) return false;
    if (row_idx >= g_command_palette_history_rows.len) return false;
    if (!AppWindow.deleteAiChatHistorySessionId(g_command_palette_history_rows[row_idx].session_id)) return false;

    commandPaletteRefreshAgentHistoryRows();

    var state = commandCenterStateSnapshot();
    state.commandPaletteClampAgentHistorySelection(g_command_palette_history_rows.len);
    commandCenterStateCommit(state);
    return true;
}

fn findAgentHistoryRowBySessionId(session_id: []const u8) ?usize {
    for (g_command_palette_history_rows, 0..) |row, idx| {
        if (std.mem.eql(u8, row.session_id, session_id)) return idx;
    }
    return null;
}

fn windowCloseConfirmLayout(window_width: f32, window_height: f32) WindowCloseConfirmLayout {
    const panel_w = @round(@min(@max(620.0, window_width - 128.0), 860.0));
    const panel_h = @round(@max(250.0, overlayTextHeight() * 4.0 + 132.0));
    const panel_x = @round(@max(24.0, (window_width - panel_w) / 2.0));
    const panel_top_px = @round(@max(48.0, (window_height - panel_h) / 2.0));

    const button_h = @round(@max(38.0, overlayTextHeight() + 16.0));
    const button_w = @round(@max(142.0, measureTitlebarText("Close") + 40.0));
    const cancel_w = @round(@max(130.0, measureTitlebarText("Cancel") + 42.0));
    const gap: f32 = 12.0;
    const button_top_px = panel_top_px + panel_h - 30.0 - button_h;
    const cancel_x = panel_x + panel_w - 32.0 - cancel_w;
    const close_x = cancel_x - gap - button_w;

    return .{
        .panel_x = panel_x,
        .panel_top_px = panel_top_px,
        .panel_w = panel_w,
        .panel_h = panel_h,
        .close_x = close_x,
        .close_top_px = button_top_px,
        .close_w = button_w,
        .close_h = button_h,
        .cancel_x = cancel_x,
        .cancel_top_px = button_top_px,
        .cancel_w = cancel_w,
        .cancel_h = button_h,
    };
}

fn transferCancelConfirmLayout(window_width: f32, window_height: f32) TransferCancelConfirmLayout {
    const panel_w = @round(@min(440.0, @max(320.0, window_width - 48.0)));
    const panel_h: f32 = 152;
    const panel_x = @round((window_width - panel_w) / 2);
    const bottom_margin: f32 = 96;
    const panel_top_px = @round(@max(18.0, window_height - bottom_margin - panel_h));
    const button_h: f32 = 34;
    const button_top_px = panel_top_px + panel_h - 22 - button_h;
    const gap: f32 = 10;
    const interrupt_w = @round(@max(118.0, measureTitlebarText("Interrupt") + 34.0));
    const keep_w = @round(@max(92.0, measureTitlebarText("Keep") + 34.0));
    const interrupt_x = panel_x + panel_w - 24.0 - interrupt_w;
    const keep_x = interrupt_x - gap - keep_w;

    return .{
        .panel_x = panel_x,
        .panel_top_px = panel_top_px,
        .panel_w = panel_w,
        .panel_h = panel_h,
        .interrupt_x = interrupt_x,
        .interrupt_top_px = button_top_px,
        .interrupt_w = interrupt_w,
        .interrupt_h = button_h,
        .keep_x = keep_x,
        .keep_top_px = button_top_px,
        .keep_w = keep_w,
        .keep_h = button_h,
    };
}

fn pointInTopRect(xpos: f64, ypos: f64, x: f32, top_px: f32, w: f32, h: f32) bool {
    const x_f: f32 = @floatCast(xpos);
    const y_f: f32 = @floatCast(ypos);
    return x_f >= x and x_f <= x + w and y_f >= top_px and y_f <= top_px + h;
}

fn measureTitlebarText(text: []const u8) f32 {
    var text_width: f32 = 0;
    var view = std.unicode.Utf8View.init(text) catch {
        // Malformed UTF-8: fall back to per-byte measurement.
        for (text) |ch| text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
        return text_width;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        text_width += titlebar.titlebarGlyphAdvance(cp);
    }
    return text_width;
}

fn renderTitlebarText(text: []const u8, x_start: f32, y: f32, color: [3]f32) void {
    var x = @round(x_start);
    const y_aligned = @round(y);
    var view = std.unicode.Utf8View.init(text) catch {
        // Malformed UTF-8: fall back to per-byte rendering.
        for (text) |ch| {
            titlebar.renderTitlebarChar(@intCast(ch), x, y_aligned, color);
            x += titlebar.titlebarGlyphAdvance(@intCast(ch));
        }
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        titlebar.renderTitlebarChar(cp, x, y_aligned, color);
        x += titlebar.titlebarGlyphAdvance(cp);
    }
}

fn renderTitlebarTextStrong(text: []const u8, x_start: f32, y: f32, color: [3]f32) void {
    const x = @round(x_start);
    const y_aligned = @round(y);
    renderTitlebarText(text, x, y_aligned, color);
    renderTitlebarText(text, x + 1, y_aligned, color);
}

fn renderTitlebarTextLimited(text: []const u8, x_start: f32, y: f32, color: [3]f32, max_w: f32) void {
    if (max_w <= 0) return;

    var x = @round(x_start);
    const y_aligned = @round(y);
    var view = std.unicode.Utf8View.init(text) catch {
        // Malformed UTF-8: best-effort byte render (no codepoint truncation).
        renderTitlebarText(text, x, y_aligned, color);
        return;
    };
    var it = view.iterator();
    var drew_any = false;
    while (it.nextCodepoint()) |cp| {
        const advance = titlebar.titlebarGlyphAdvance(cp);
        if (x + advance > x_start + max_w) {
            const ellipsis_w = titlebar.titlebarGlyphAdvance('.') * 3;
            if (drew_any and x + ellipsis_w <= x_start + max_w) {
                renderTitlebarText("...", x, y_aligned, color);
            }
            return;
        }
        titlebar.renderTitlebarChar(cp, x, y_aligned, color);
        x += advance;
        drew_any = true;
    }
}

fn renderTitlebarTextStrongLimited(text: []const u8, x_start: f32, y: f32, color: [3]f32, max_w: f32) void {
    if (max_w <= 0) return;
    const x = @round(x_start);
    const y_aligned = @round(y);
    renderTitlebarTextLimited(text, x, y_aligned, color, max_w);
    renderTitlebarTextLimited(text, x + 1, y_aligned, color, max_w - 1);
}

const jupyter_picker = @import("../jupyter_picker.zig");
const copilot_picker = @import("../copilot_picker.zig");

/// Render the multi-server Jupyter picker overlay.
pub fn renderJupyterPicker(window_width: f32, window_height: f32) void {
    if (!jupyter_picker.isVisible()) return;
    const n = jupyter_picker.count();
    if (n == 0) return;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel = mixColor(bg, fg, 0.05);
    const border = mixColor(bg, fg, 0.18);
    const sel_bg = mixColor(bg, accent, 0.5);
    const text_color = mixColor(bg, fg, 0.88);

    const row_h: f32 = @max(28.0, font.g_titlebar_cell_height + 12);
    const box_w: f32 = @min(window_width - 80, 720);
    const title_h: f32 = row_h;
    const bottom_pad: f32 = 16;
    // Clamp the row count to what fits the window, then scroll to keep the
    // selected server visible (the list is keyboard/wheel navigable).
    const usable_h = @max(row_h, window_height - 32.0 - title_h - bottom_pad);
    const fit: usize = @intFromFloat(@max(1.0, @floor(usable_h / row_h)));
    const visible = @min(n, fit);
    const scroll = jupyter_picker.firstVisible(jupyter_picker.selectedIndex(), visible, n);
    const box_h: f32 = clampOverlayBoxHeight(title_h + row_h * @as(f32, @floatFromInt(visible)) + bottom_pad, window_height);
    const box_x = @round((window_width - box_w) / 2);
    const box_top = @round(@max(16.0, (window_height - box_h) / 2));
    const box_y = @round(window_height - box_top - box_h);

    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.30);
    renderRoundedQuadAlpha(box_x - 1, box_y - 1, box_w + 2, box_h + 2, 9, border, 0.5);
    renderRoundedQuadAlpha(box_x, box_y, box_w, box_h, 8, panel, 0.99);

    const title_y = @round(box_y + box_h - title_h + (title_h - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited("Select a Jupyter server (Up/Down, Enter, Esc)", box_x + 16, title_y, mixColor(bg, fg, 0.6), box_w - 32);

    var display: usize = 0;
    while (display < visible) : (display += 1) {
        const i = scroll + display;
        if (i >= n) break;
        const row_top_px = box_top + title_h + row_h * @as(f32, @floatFromInt(display));
        const row_y = @round(window_height - row_top_px - row_h);
        if (i == jupyter_picker.selectedIndex()) {
            renderRoundedQuadAlpha(box_x + 8, row_y + 3, box_w - 16, row_h - 6, 5, sel_bg, 0.6);
        }
        const ty = @round(row_y + (row_h - font.g_titlebar_cell_height) / 2);
        _ = titlebar.renderTextLimited(jupyter_picker.urlAt(i), box_x + 18, ty, text_color, box_w - 36);
    }

    // Scrollbar thumb when the list is taller than the window.
    if (n > visible and visible > 0) {
        const total_f: f32 = @floatFromInt(n);
        const vis_f: f32 = @floatFromInt(visible);
        const track_h = row_h * vis_f;
        const track_top_px = box_top + title_h;
        const sb_w: f32 = 3;
        const sb_x = box_x + box_w - sb_w - 6;
        const track_gl_y = @round(window_height - track_top_px - track_h);
        ui_pipeline.fillQuadAlpha(sb_x, track_gl_y, sb_w, track_h, mixColor(bg, fg, 0.25), 0.30);
        const thumb_h = @max(24.0, @round(track_h * vis_f / total_f));
        const max_scroll_f: f32 = @floatFromInt(n - visible);
        const scroll_f: f32 = @floatFromInt(scroll);
        const thumb_offset = if (max_scroll_f > 0) @round((track_h - thumb_h) * (scroll_f / max_scroll_f)) else 0;
        const thumb_gl_y = @round(window_height - (track_top_px + thumb_offset) - thumb_h);
        ui_pipeline.fillQuadAlpha(sb_x, thumb_gl_y, sb_w, thumb_h, accent, 0.55);
    }
}

/// Render the Copilot conversation picker overlay (mirror of renderJupyterPicker).
pub fn renderCopilotPicker(window_width: f32, window_height: f32) void {
    if (!copilot_picker.isVisible()) return;
    const total = copilot_picker.rowCount(); // conversations + "+ New" row
    if (total == 0) return;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel = mixColor(bg, fg, 0.05);
    const border = mixColor(bg, fg, 0.18);
    const sel_bg = mixColor(bg, accent, 0.5);
    const text_color = mixColor(bg, fg, 0.88);
    const meta_color = mixColor(bg, fg, 0.54);

    const row_h: f32 = @max(28.0, font.g_titlebar_cell_height + 12);
    const box_w: f32 = @min(window_width - 80, 720);
    const title_h: f32 = row_h;
    const bottom_pad: f32 = 16;
    const usable_h = @max(row_h, window_height - 32.0 - title_h - bottom_pad);
    const fit: usize = @intFromFloat(@max(1.0, @floor(usable_h / row_h)));
    const visible = @min(total, fit);
    const scroll = copilot_picker.firstVisible(copilot_picker.selectedIndex(), visible, total);
    const box_h: f32 = clampOverlayBoxHeight(title_h + row_h * @as(f32, @floatFromInt(visible)) + bottom_pad, window_height);
    const box_x = @round((window_width - box_w) / 2);
    const box_top = @round(@max(16.0, (window_height - box_h) / 2));
    const box_y = @round(window_height - box_top - box_h);

    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.30);
    renderRoundedQuadAlpha(box_x - 1, box_y - 1, box_w + 2, box_h + 2, 9, border, 0.5);
    renderRoundedQuadAlpha(box_x, box_y, box_w, box_h, 8, panel, 0.99);

    const title_y = @round(box_y + box_h - title_h + (title_h - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited(i18n.s().copilot_picker_title, box_x + 16, title_y, mixColor(bg, fg, 0.6), box_w - 32);

    const now_ms = std.time.milliTimestamp();
    var display: usize = 0;
    while (display < visible) : (display += 1) {
        const i = scroll + display;
        if (i >= total) break;
        const row_top_px = box_top + title_h + row_h * @as(f32, @floatFromInt(display));
        const row_y = @round(window_height - row_top_px - row_h);
        if (i == copilot_picker.selectedIndex()) {
            renderRoundedQuadAlpha(box_x + 8, row_y + 3, box_w - 16, row_h - 6, 5, sel_bg, 0.6);
        }
        const ty = @round(row_y + (row_h - font.g_titlebar_cell_height) / 2);
        if (i == copilot_picker.count()) {
            // Trailing "+ New conversation" action row.
            renderTitlebarTextLimited(i18n.s().copilot_picker_new, box_x + 18, ty, text_color, box_w - 36);
        } else {
            var tbuf: [32]u8 = undefined;
            const rel = copilot_picker.formatRelativeTime(now_ms, copilot_picker.updatedAt(i), &tbuf);
            const rel_w = measureTitlebarText(rel);
            const meta_right = box_x + box_w - 18;
            renderTitlebarText(rel, meta_right - rel_w, ty, meta_color);
            renderTitlebarTextLimited(copilot_picker.titleAt(i), box_x + 18, ty, text_color, (meta_right - rel_w) - (box_x + 18) - 12);
        }
    }

    // Scrollbar thumb when the list is taller than the window.
    if (total > visible and visible > 0) {
        const total_f: f32 = @floatFromInt(total);
        const vis_f: f32 = @floatFromInt(visible);
        const track_h = row_h * vis_f;
        const track_top_px = box_top + title_h;
        const sb_w: f32 = 3;
        const sb_x = box_x + box_w - sb_w - 6;
        const track_gl_y = @round(window_height - track_top_px - track_h);
        ui_pipeline.fillQuadAlpha(sb_x, track_gl_y, sb_w, track_h, mixColor(bg, fg, 0.25), 0.30);
        const thumb_h = @max(24.0, @round(track_h * vis_f / total_f));
        const max_scroll_f: f32 = @floatFromInt(total - visible);
        const scroll_f: f32 = @floatFromInt(scroll);
        const thumb_offset = if (max_scroll_f > 0) @round((track_h - thumb_h) * (scroll_f / max_scroll_f)) else 0;
        const thumb_gl_y = @round(window_height - (track_top_px + thumb_offset) - thumb_h);
        ui_pipeline.fillQuadAlpha(sb_x, thumb_gl_y, sb_w, thumb_h, accent, 0.55);
    }
}

pub fn renderBrowserUrlBar(window_width: f32, window_height: f32, top_offset: f32) void {
    if (!browser_panel.isVisibleForActiveTab()) return;

    const bounds = browser_panel.boundsForWindow(
        @intFromFloat(@round(window_width)),
        @intFromFloat(@round(window_height)),
        top_offset,
        AppWindow.leftPanelsWidth(),
        AppWindow.browserPanelRightOffset(),
    );
    const url_bar = browser_panel.urlBarBounds(bounds) orelse return;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_bg = mixColor(bg, fg, 0.055);
    const field_bg = mixColor(bg, fg, 0.12);
    const field_border = if (browser_panel.urlBarFocused()) accent else mixColor(bg, fg, 0.28);
    const text_color = mixColor(bg, fg, 0.88);
    const placeholder_color = mixColor(bg, fg, 0.48);

    const panel_x: f32 = @floatFromInt(bounds.left);
    const panel_w: f32 = @floatFromInt(bounds.right - bounds.left);
    const bar_top: f32 = @floatFromInt(url_bar.top);
    const bar_bottom: f32 = @floatFromInt(url_bar.bottom);
    const bar_h = @max(1.0, bar_bottom - bar_top);
    const bar_y = @round(window_height - bar_bottom);
    ui_pipeline.fillQuadAlpha(panel_x, bar_y, panel_w, bar_h, panel_bg, 0.98);

    const margin = browser_panel.URL_BAR_MARGIN;
    const close_layout: hit_test.PanelHeaderLayout = .{
        .visible = true,
        .left = @floatFromInt(url_bar.left),
        .right = @floatFromInt(url_bar.right),
        .top = @floatFromInt(url_bar.top),
        .height = @floatFromInt(url_bar.bottom - url_bar.top),
    };
    const close = hit_test.panelHeaderButtonRect(close_layout, 0) orelse return;
    const toggle_rect = hit_test.panelHeaderButtonRect(close_layout, 1);
    const refresh_rect = hit_test.panelHeaderButtonRect(close_layout, 2);
    const close_btn_w: f32 = @floatCast(close.width);
    const close_x = @round(@as(f32, @floatCast(close.left)));
    const input_x = @round(@as(f32, @floatFromInt(url_bar.left)) + margin);
    const first_button_x = if (refresh_rect) |r| @round(@as(f32, @floatCast(r.left))) else close_x;
    const input_w = @max(1.0, first_button_x - input_x - margin);
    const input_h = @max(24.0, bar_h - margin * 2);
    const input_y = @round(bar_y + margin);
    renderRoundedQuadAlpha(input_x - 1, input_y - 1, input_w + 2, input_h + 2, 6, field_border, if (browser_panel.urlBarFocused()) 0.70 else 0.34);
    renderRoundedQuadAlpha(input_x, input_y, input_w, input_h, 5, field_bg, 0.96);

    const text = browser_panel.urlBarText();
    const shown_text = if (text.len == 0) "Enter URL" else text;
    const shown_color = if (text.len == 0) placeholder_color else text_color;
    const text_x = input_x + 10;
    const text_y = @round(input_y + (input_h - font.g_titlebar_cell_height) / 2);
    const text_max_w = @max(1.0, input_w - 22);
    if (browser_panel.urlBarSelectAll()) {
        const selection_w = @min(text_max_w, measureTitlebarText(shown_text) + 6);
        renderRoundedQuadAlpha(text_x - 3, input_y + 5, selection_w, @max(8.0, input_h - 10), 3, mixColor(bg, accent, 0.58), 0.64);
    }
    const text_end = titlebar.renderTextLimited(shown_text, text_x, text_y, shown_color, text_max_w);

    if (browser_panel.urlBarFocused() and !browser_panel.urlBarSelectAll()) {
        const cursor_x = @min(input_x + input_w - 10, @max(text_x, text_end + 1));
        ui_pipeline.fillQuadAlpha(cursor_x, input_y + 6, 1.5, @max(8.0, input_h - 12), accent, 0.90);
    }

    const close_hovered = blk: {
        const win = AppWindow.g_window orelse break :blk false;
        if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
        break :blk hit_test.panelHeaderCloseButton(close_layout, @floatFromInt(win.mouse_x), @floatFromInt(win.mouse_y));
    };
    if (close_hovered) {
        ui_pipeline.fillQuadAlpha(close_x + 6, bar_y + @round((bar_h - 20) / 2), 20, 20, mixColor(bg, fg, 0.14), 0.95);
    }
    titlebar.renderCloseIcon(close_x, bar_y, close_btn_w, bar_h, if (close_hovered) fg else mixColor(bg, fg, 0.68));

    if (toggle_rect) |t| {
        const t_left = @round(@as(f32, @floatCast(t.left)));
        const toggle_hovered = blk: {
            const win = AppWindow.g_window orelse break :blk false;
            if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
            break :blk hit_test.panelHeaderSecondButton(close_layout, @floatFromInt(win.mouse_x), @floatFromInt(win.mouse_y));
        };
        if (toggle_hovered) {
            ui_pipeline.fillQuadAlpha(t_left + 6, bar_y + @round((bar_h - 20) / 2), 20, 20, mixColor(bg, fg, 0.14), 0.95);
        }
        const glyph_color = if (toggle_hovered) fg else mixColor(bg, fg, 0.68);
        const gx = t_left + @as(f32, @floatCast(t.width)) / 2 - 6;
        const gy = bar_y + bar_h / 2 - 6;
        if (browser_panel.displayMode() == .full) {
            ui_pipeline.fillQuadAlpha(gx, gy, 12, 12, glyph_color, 0.9);
        } else {
            ui_pipeline.fillQuadAlpha(gx, gy, 12, 1.5, glyph_color, 0.9);
            ui_pipeline.fillQuadAlpha(gx, gy + 10.5, 12, 1.5, glyph_color, 0.9);
            ui_pipeline.fillQuadAlpha(gx, gy, 1.5, 12, glyph_color, 0.9);
            ui_pipeline.fillQuadAlpha(gx + 10.5, gy, 1.5, 12, glyph_color, 0.9);
        }
    }

    if (refresh_rect) |r| {
        const r_left = @round(@as(f32, @floatCast(r.left)));
        const refresh_hovered = blk: {
            const win = AppWindow.g_window orelse break :blk false;
            if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
            break :blk hit_test.panelHeaderButton(close_layout, 2, @floatFromInt(win.mouse_x), @floatFromInt(win.mouse_y));
        };
        if (refresh_hovered) {
            ui_pipeline.fillQuadAlpha(r_left + 6, bar_y + @round((bar_h - 20) / 2), 20, 20, mixColor(bg, fg, 0.14), 0.95);
        }
        const glyph_color = if (refresh_hovered) fg else mixColor(bg, fg, 0.68);
        const cx = r_left + @as(f32, @floatCast(r.width)) / 2;
        const cy = bar_y + bar_h / 2;
        ui_pipeline.fillQuadAlpha(cx - 5, cy - 6, 8, 1.5, glyph_color, 0.9);
        ui_pipeline.fillQuadAlpha(cx + 3, cy - 6, 1.5, 6, glyph_color, 0.9);
        ui_pipeline.fillQuadAlpha(cx - 5, cy + 4.5, 8, 1.5, glyph_color, 0.9);
        ui_pipeline.fillQuadAlpha(cx - 6.5, cy - 1, 1.5, 6, glyph_color, 0.9);
    }

    ui_pipeline.fillQuadAlpha(panel_x, bar_y, panel_w, 1, mixColor(bg, fg, 0.18), 0.55);
}

/// Render the command center overlay.
pub fn renderCommandPalette(window_width: f32, window_height: f32, top_offset: f32) void {
    if (!g_command_palette_visible) return;
    commandPaletteSyncAgentHistoryRows();

    const layout = commandPaletteLayout(window_width, window_height, top_offset);
    const box_y = @round(window_height - layout.box_top_px - layout.box_h);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_color = mixColor(bg, fg, 0.035);
    const border_color = mixColor(bg, fg, 0.16);
    const field_color = mixColor(bg, fg, 0.075);
    const field_border = mixColor(bg, fg, 0.19);
    const muted = mixColor(bg, fg, 0.62);
    const dim = mixColor(bg, fg, 0.44);
    const title_color = mixColor(fg, accent, 0.08);
    const selected_bg = mixColor(bg, accent, 0.50);
    const selected_border = mixColor(accent, fg, 0.16);

    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.22);
    renderRoundedQuadAlpha(layout.box_x - 1, box_y - 1, layout.box_w + 2, layout.box_h + 2, 9, border_color, 0.42);
    renderRoundedQuadAlpha(layout.box_x, box_y, layout.box_w, layout.box_h, 8, panel_color, 0.98);

    const pad_x: f32 = 24;
    const title_y = textYFromTop(window_height, layout.box_top_px + 16);
    renderTitlebarText(if (commandPaletteIsHistoryMode()) i18n.s().cmd_palette_history_title else i18n.s().cmd_palette_title, layout.box_x + pad_x, title_y, title_color);
    const esc_hint = if (commandPaletteIsHistoryMode()) i18n.s().cmd_palette_esc_returns else i18n.s().cmd_palette_esc_closes;
    renderTitlebarText(esc_hint, layout.box_x + layout.box_w - pad_x - measureTitlebarText(esc_hint), title_y, muted);

    const filter_x = @round(layout.box_x + pad_x);
    const filter_box_y = @round(window_height - (layout.box_top_px + layout.header_h + layout.filter_h));
    const filter_w = layout.box_w - pad_x * 2;
    renderRoundedQuadAlpha(filter_x - 1, filter_box_y - 1, filter_w + 2, layout.filter_h + 2, 6, field_border, 0.42);
    renderRoundedQuadAlpha(filter_x, filter_box_y, filter_w, layout.filter_h, 5, field_color, 0.92);

    const filter_text_y = rowTextY(filter_box_y, layout.filter_h);
    if (commandPaletteIsHistoryMode()) {
        const history_hint = if (g_command_palette_history_rows.len == 0)
            i18n.s().cmd_palette_no_sessions_yet
        else
            i18n.s().cmd_palette_recent_sessions;
        renderTitlebarTextLimited(history_hint, filter_x + 12, filter_text_y, dim, filter_w - 24);
    } else {
        const filter = commandPaletteFilter();
        if (filter.len > 0) {
            renderTitlebarTextLimited(filter, filter_x + 12, filter_text_y, fg, filter_w - 24);
        } else {
            renderTitlebarTextLimited(i18n.s().cmd_palette_filter_placeholder, filter_x + 12, filter_text_y, dim, filter_w - 24);
        }
    }

    if (commandPaletteIsHistoryMode()) {
        if (g_command_palette_history_rows.len == 0) {
            const empty_text = i18n.s().cmd_palette_no_sessions;
            const empty_y = @round(window_height - layout.row_top_px - layout.row_h + (layout.row_h - overlayTextHeight()) / 2);
            renderTitlebarText(empty_text, layout.box_x + (layout.box_w - measureTitlebarText(empty_text)) / 2, empty_y, muted);
        } else {
            const first_row = commandPaletteFirstVisibleIndex(layout.rendered_rows);
            var display_row: usize = 0;
            while (display_row < layout.rendered_rows) : (display_row += 1) {
                const item_idx = first_row + display_row;
                if (item_idx >= g_command_palette_history_rows.len) break;
                const row = g_command_palette_history_rows[item_idx];
                const selected = item_idx == g_command_palette_history_selected;

                const row_top = @round(layout.row_top_px + @as(f32, @floatFromInt(display_row)) * layout.row_h);
                const row_y = @round(window_height - row_top - layout.row_h);
                if (selected) {
                    renderRoundedQuadAlpha(layout.box_x + 12, row_y + 4, layout.box_w - 24, layout.row_h - 8, 5, selected_border, 0.38);
                    renderRoundedQuadAlpha(layout.box_x + 13, row_y + 5, layout.box_w - 26, layout.row_h - 10, 4, selected_bg, 0.78);
                }

                const row_title_color = if (selected) fg else mixColor(bg, fg, 0.86);
                const meta_color = if (selected) mixColor(fg, accent, 0.08) else mixColor(bg, fg, 0.54);
                const text_y = rowTextY(row_y, layout.row_h);
                const title_x = @round(layout.box_x + pad_x + 2);
                const meta_right = layout.box_x + layout.box_w - pad_x;
                if (row.model.len > 0) {
                    const meta_w = measureTitlebarText(row.model);
                    renderTitlebarText(row.model, meta_right - meta_w, text_y, meta_color);
                    renderTitlebarTextLimited(row.title, title_x, text_y, row_title_color, (meta_right - meta_w) - title_x - 18);
                } else {
                    renderTitlebarTextLimited(row.title, title_x, text_y, row_title_color, meta_right - title_x);
                }
            }
        }
    } else {
        rebuildPaletteScratch();
        if (g_palette_scratch_len == 0) {
            const empty_text = "No matching results";
            const empty_y = @round(window_height - layout.row_top_px - layout.row_h + (layout.row_h - overlayTextHeight()) / 2);
            renderTitlebarText(empty_text, layout.box_x + (layout.box_w - measureTitlebarText(empty_text)) / 2, empty_y, muted);
        } else {
            const first_row = commandPaletteFirstVisibleIndex(layout.rendered_rows);
            var display_row: usize = 0;
            while (display_row < layout.rendered_rows) : (display_row += 1) {
                const item_idx = first_row + display_row;
                if (item_idx >= g_palette_scratch_len) break;
                const item = g_palette_scratch[item_idx];
                const selected = item_idx == g_command_palette_selected;

                const row_top = @round(layout.row_top_px + @as(f32, @floatFromInt(display_row)) * layout.row_h);
                const row_y = @round(window_height - row_top - layout.row_h);
                if (selected) {
                    renderRoundedQuadAlpha(layout.box_x + 12, row_y + 4, layout.box_w - 24, layout.row_h - 8, 5, selected_border, 0.38);
                    renderRoundedQuadAlpha(layout.box_x + 13, row_y + 5, layout.box_w - 26, layout.row_h - 10, 4, selected_bg, 0.78);
                }

                const row_title_color = if (selected) fg else mixColor(bg, fg, 0.86);
                const shortcut_color = if (selected) mixColor(fg, accent, 0.08) else mixColor(bg, fg, 0.54);

                const text_y = rowTextY(row_y, layout.row_h);
                const title_x = @round(layout.box_x + pad_x + 2);

                switch (item) {
                    .command => |cmd_idx| {
                        const entry = COMMAND_ENTRIES[cmd_idx];
                        var shortcut_buf: [64]u8 = undefined;
                        const shortcut = commandEntryShortcut(entry, &shortcut_buf);
                        var shortcut_left = layout.box_x + layout.box_w - pad_x;
                        if (shortcut.len > 0) {
                            const shortcut_w = measureTitlebarText(shortcut);
                            shortcut_left = @round(layout.box_x + layout.box_w - pad_x - shortcut_w);
                            renderTitlebarText(shortcut, shortcut_left, text_y, shortcut_color);
                        }
                        renderTitlebarTextLimited(i18n.commandTitle(entry.action) orelse entry.title, title_x, text_y, row_title_color, shortcut_left - title_x - 18);
                    },
                    .ssh_profile => |profile_idx| {
                        if (profile_idx >= g_ssh_profile_count) continue;
                        const profile = &g_ssh_profiles[profile_idx];
                        var title_buf: [SSH_FIELD_MAX + 5]u8 = undefined;
                        const ssh_title = std.fmt.bufPrint(title_buf[0..], "SSH: {s}", .{profileField(profile, .name)}) catch "SSH";
                        var target_buf: [SSH_FIELD_MAX * 2]u8 = undefined;
                        const target = sshProfileTarget(profile, target_buf[0..]);
                        const target_w = measureTitlebarText(target);
                        const target_max_w = @min(target_w, @max(80.0, layout.box_w * 0.40));
                        const target_left = @round(layout.box_x + layout.box_w - pad_x - target_max_w);
                        renderTitlebarTextLimited(target, target_left, text_y, shortcut_color, target_max_w);
                        renderTitlebarTextLimited(ssh_title, title_x, text_y, row_title_color, @max(1.0, target_left - title_x - 18));
                    },
                    .tmux_profile => |profile_idx| {
                        if (profile_idx >= g_ssh_profile_count) continue;
                        const profile = &g_ssh_profiles[profile_idx];
                        var title_buf: [SSH_FIELD_MAX + 6]u8 = undefined;
                        const tmux_title = std.fmt.bufPrint(title_buf[0..], "tmux: {s}", .{profileField(profile, .name)}) catch "tmux";
                        var target_buf: [SSH_FIELD_MAX * 2]u8 = undefined;
                        const target = sshProfileTarget(profile, target_buf[0..]);
                        const target_w = measureTitlebarText(target);
                        const target_max_w = @min(target_w, @max(80.0, layout.box_w * 0.40));
                        const target_left = @round(layout.box_x + layout.box_w - pad_x - target_max_w);
                        renderTitlebarTextLimited(target, target_left, text_y, shortcut_color, target_max_w);
                        renderTitlebarTextLimited(tmux_title, title_x, text_y, row_title_color, @max(1.0, target_left - title_x - 18));
                    },
                    .ai_profile => |profile_idx| {
                        if (profile_idx >= g_ai_profile_count) continue;
                        const profile = &g_ai_profiles[profile_idx];
                        var title_buf: [AI_FIELD_MAX + 8]u8 = undefined;
                        const ai_title = std.fmt.bufPrint(title_buf[0..], "AI: {s}", .{aiProfileField(profile, .name)}) catch "AI";
                        var tag_buf: [24]u8 = undefined;
                        const mode = aiProfileModeLabel(profile);
                        const tag = if (profile_idx == defaultAiProfileIndex())
                            (std.fmt.bufPrint(tag_buf[0..], "{s} (default)", .{mode}) catch mode)
                        else
                            mode;
                        const tag_w = measureTitlebarText(tag);
                        const tag_left = @round(layout.box_x + layout.box_w - pad_x - tag_w);
                        renderTitlebarText(tag, tag_left, text_y, shortcut_color);
                        renderTitlebarTextLimited(ai_title, title_x, text_y, row_title_color, @max(1.0, tag_left - title_x - 18));
                    },
                    .theme => |ti| {
                        const name = themes_embed.entries[ti].name;
                        const suffix = "  theme";
                        const suffix_w = measureTitlebarText(suffix);
                        const shortcut_right = layout.box_x + layout.box_w - pad_x;
                        renderTitlebarText(suffix, shortcut_right - suffix_w, text_y, shortcut_color);
                        renderTitlebarTextLimited(name, title_x, text_y, row_title_color, (shortcut_right - suffix_w) - title_x - 18);
                    },
                }
            }
        }
    }

    // Scrollbar indicator when more results exist than fit (short windows or
    // long result lists). The list scrolls via keyboard/click selection-follow
    // and the mouse wheel.
    const total_results = commandPaletteResultCount();
    if (total_results > layout.rendered_rows and layout.rendered_rows > 0) {
        const total_f: f32 = @floatFromInt(total_results);
        const vis_f: f32 = @floatFromInt(layout.rendered_rows);
        const track_h = layout.row_h * vis_f;
        const track_top_px = layout.row_top_px;
        const sb_w: f32 = 3;
        const sb_x = layout.box_x + layout.box_w - sb_w - 7;
        const track_gl_y = @round(window_height - track_top_px - track_h);
        ui_pipeline.fillQuadAlpha(sb_x, track_gl_y, sb_w, track_h, mixColor(bg, fg, 0.25), 0.30);

        const first_row = commandPaletteFirstVisibleIndex(layout.rendered_rows);
        const thumb_h = @max(24.0, @round(track_h * vis_f / total_f));
        const max_scroll_f: f32 = @floatFromInt(total_results - layout.rendered_rows);
        const scroll_f: f32 = @floatFromInt(first_row);
        const thumb_offset = if (max_scroll_f > 0) @round((track_h - thumb_h) * (scroll_f / max_scroll_f)) else 0;
        const thumb_gl_y = @round(window_height - (track_top_px + thumb_offset) - thumb_h);
        ui_pipeline.fillQuadAlpha(sb_x, thumb_gl_y, sb_w, thumb_h, accent, 0.55);
    }

    const footer = if (commandPaletteIsHistoryMode()) i18n.s().cmd_palette_footer_history else i18n.s().cmd_palette_footer;
    renderTitlebarTextLimited(footer, layout.box_x + pad_x, rowTextY(box_y, layout.footer_h), muted, layout.box_w - pad_x * 2);
}

// ============================================================================
// New session / SSH launcher
// ============================================================================

const profile_codec = @import("overlays/profile_codec.zig");
const openssh_config_import = @import("../openssh_config_import.zig");
const SSH_FIELD_COUNT = profile_codec.SSH_FIELD_COUNT;
const SSH_FIELD_MAX = profile_codec.SSH_FIELD_MAX;
const SSH_PROFILE_MAX = 16;
const SSH_PROFILE_NONE = std.math.maxInt(usize);
const AI_FIELD_COUNT = profile_codec.AI_FIELD_COUNT;
const AI_FIELD_MAX = profile_codec.AI_FIELD_MAX;
const AI_PROFILE_MAX = 16;
const AI_PROFILE_NONE = std.math.maxInt(usize);
const SshField = profile_codec.SshField;
const AiField = profile_codec.AiField;

const SessionAction = enum {
    local_shell,
    ssh,
    tmux,
    wsl,
    ai_chat,
    ai_history,
    ai_history_local,
    ai_history_wsl,
    ai_history_ssh,
    connect_selected,
    load_openssh_config,
    new_ssh,
    edit_selected,
    delete_selected,
    connect_ai_selected,
    new_ai,
    edit_ai_selected,
    delete_ai_selected,
    connect,
    save,
    connect_ai,
    save_ai,
    cancel,
};

const SshListMode = enum {
    manage,
    edit_select,
    delete_select,
    ai_history_select,
    tmux_connect,
};

const AiListMode = enum {
    manage,
    edit_select,
    delete_select,
    switch_model,
};

const AiHistorySourceChoice = enum { local, wsl, ssh };

const SshProfile = profile_codec.SshProfile;
pub const AgentSshConnectResult = union(enum) {
    connected: *Surface,
    not_found,
    failed,
};

pub const DefaultAgentOpenResult = enum {
    opened,
    form_opened,
    failed,
};

const AiProfile = profile_codec.AiProfile;

const SessionLayout = struct {
    box_x: f32,
    box_top_px: f32,
    box_w: f32,
    box_h: f32,
    header_h: f32,
    first_row_top_px: f32,
    row_h: f32,
    /// Total rows in the active mode.
    row_count: usize,
    /// Rows that fit in the box for the current window height.
    visible_rows: usize,
    /// Index of the first rendered row (scroll offset, selection-following).
    scroll: usize,
};

pub threadlocal var g_session_launcher_visible: bool = false;
threadlocal var g_session_launcher_selected: usize = 0;
threadlocal var g_session_launcher_return_to_command_palette: bool = false;
threadlocal var g_ssh_list_visible: bool = false;
threadlocal var g_ssh_form_visible: bool = false;
threadlocal var g_ai_list_visible: bool = false;
threadlocal var g_ai_form_visible: bool = false;
/// Live session bound to a `.switch_model` picker; set when the picker opens,
/// cleared when a row is chosen or the picker closes.
threadlocal var g_switch_model_target: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_history_source_visible: bool = false;
threadlocal var g_ai_history_source_selected: usize = 0;
threadlocal var g_ssh_focus: usize = @intFromEnum(SshField.name);
threadlocal var g_ssh_bufs: [SSH_FIELD_COUNT][SSH_FIELD_MAX]u8 = undefined;
threadlocal var g_ssh_lens: [SSH_FIELD_COUNT]usize = .{0} ** SSH_FIELD_COUNT;
threadlocal var g_ssh_profiles: [SSH_PROFILE_MAX]SshProfile = undefined;
threadlocal var g_ssh_profile_count: usize = 0;
threadlocal var g_ssh_profiles_loaded: bool = false;
threadlocal var g_ssh_list_selected: usize = 0;
threadlocal var g_ssh_list_mode: SshListMode = .manage;
threadlocal var g_ssh_list_filter_buf: [SSH_FIELD_MAX]u8 = undefined;
threadlocal var g_ssh_list_filter_len: usize = 0;
threadlocal var g_ssh_edit_index: usize = SSH_PROFILE_NONE;
threadlocal var g_ai_focus: usize = @intFromEnum(AiField.name);
threadlocal var g_ai_bufs: [AI_FIELD_COUNT][AI_FIELD_MAX]u8 = undefined;
threadlocal var g_ai_lens: [AI_FIELD_COUNT]usize = .{0} ** AI_FIELD_COUNT;
threadlocal var g_ai_profiles: [AI_PROFILE_MAX]AiProfile = undefined;
threadlocal var g_ai_profile_count: usize = 0;
threadlocal var g_ai_profiles_loaded: bool = false;
threadlocal var g_ai_list_selected: usize = 0;
threadlocal var g_ai_list_mode: AiListMode = .manage;
threadlocal var g_ai_edit_index: usize = AI_PROFILE_NONE;

pub const RemoteAgentOpenResult = enum {
    opened,
    no_profile,
    failed,
};

pub const NamedAgentOpenResult = enum {
    opened,
    no_profile,
    unknown_profile,
    failed,
};

pub const ModelProfileSwitchResult = enum {
    switched,
    no_profile,
    unknown_profile,
    failed,
};

threadlocal var g_pending_ssh_password: [SSH_FIELD_MAX + 1]u8 = undefined;
threadlocal var g_pending_ssh_password_len: usize = 0;
threadlocal var g_pending_ssh_password_due_ms: i64 = 0;
threadlocal var g_pending_ssh_password_deadline_ms: i64 = 0;
threadlocal var g_pending_ssh_surface: ?*Surface = null;

const SSH_PASSWORD_PROMPT_MIN_WAIT_MS: i64 = 250;
const SSH_PASSWORD_PROMPT_TIMEOUT_MS: i64 = 60_000;
const SSH_PROMPT_SCAN_MAX_COLS: usize = 4096;

pub fn sessionLauncherVisible() bool {
    return commandCenterStateSnapshot().sessionLauncherVisible();
}

fn commandCenterStateSnapshot() command_center_state.State {
    return .{
        .command_palette_visible = g_command_palette_visible,
        .command_palette_selected = g_command_palette_selected,
        .command_palette_filter_len = g_command_palette_filter_len,
        .command_palette_mode = g_command_palette_mode,
        .command_palette_history_selected = g_command_palette_history_selected,
        .startup_shortcuts_visible = startup_shortcuts.g_startup_shortcuts_visible,
        .session_launcher_visible = g_session_launcher_visible,
        .session_launcher_selected = g_session_launcher_selected,
        .session_launcher_return_to_command_palette = g_session_launcher_return_to_command_palette,
        .ssh_list_visible = g_ssh_list_visible,
        .ssh_form_visible = g_ssh_form_visible,
        .ai_list_visible = g_ai_list_visible,
        .ai_form_visible = g_ai_form_visible,
        .ai_history_source_visible = g_ai_history_source_visible,
        .settings_visible = g_settings_visible,
    };
}

fn commandCenterStateCommit(state: command_center_state.State) void {
    const previous = commandCenterStateSnapshot();
    if (command_center_state.historyRowsNeedCleanup(previous, state)) {
        commandPaletteClearAgentHistoryRows();
    }
    commandCenterStateApply(state);
}

fn commandCenterStateApply(state: command_center_state.State) void {
    g_command_palette_visible = state.command_palette_visible;
    g_command_palette_selected = state.command_palette_selected;
    g_command_palette_filter_len = state.command_palette_filter_len;
    g_command_palette_mode = state.command_palette_mode;
    g_command_palette_history_selected = state.command_palette_history_selected;
    startup_shortcuts.g_startup_shortcuts_visible = state.startup_shortcuts_visible;
    g_session_launcher_visible = state.session_launcher_visible;
    g_session_launcher_selected = state.session_launcher_selected;
    g_session_launcher_return_to_command_palette = state.session_launcher_return_to_command_palette;
    g_ssh_list_visible = state.ssh_list_visible;
    g_ssh_form_visible = state.ssh_form_visible;
    g_ai_list_visible = state.ai_list_visible;
    g_ai_form_visible = state.ai_form_visible;
    g_ai_history_source_visible = state.ai_history_source_visible;
    g_settings_visible = state.settings_visible;
}

pub fn sessionLauncherOpen() void {
    var state = commandCenterStateSnapshot();
    state.sessionLauncherOpen();
    commandCenterStateCommit(state);
    resetSessionLauncherTransientModes();
}

pub fn sessionLauncherOpenFromCommandPalette() void {
    var state = commandCenterStateSnapshot();
    state.sessionLauncherOpenFromCommandPalette();
    commandCenterStateCommit(state);
    resetSessionLauncherTransientModes();
}

fn resetSessionLauncherTransientModes() void {
    g_ssh_list_mode = .manage;
    g_ai_list_mode = .manage;
    g_ai_history_source_selected = 0;
}

pub fn sessionLauncherClose() void {
    var state = commandCenterStateSnapshot();
    state.sessionLauncherClose();
    commandCenterStateCommit(state);
    resetSessionLauncherTransientModes();
}

fn sessionLauncherBackOrClose() void {
    var state = commandCenterStateSnapshot();
    if (!state.sessionLauncherBackToCommandPalette()) {
        state.sessionLauncherClose();
    }
    commandCenterStateCommit(state);
    resetSessionLauncherTransientModes();
}

fn sessionLauncherCancelLabel() []const u8 {
    return if (g_session_launcher_return_to_command_palette) i18n.s().sl_back else i18n.s().sl_cancel;
}

fn markSessionLauncherReturnToCommandPalette() void {
    g_session_launcher_return_to_command_palette = true;
}

fn openAiListFromCommandPalette() void {
    openAiList();
    markSessionLauncherReturnToCommandPalette();
}

fn openAiFormNewFromCommandPalette() void {
    openAiFormNew();
    markSessionLauncherReturnToCommandPalette();
}

pub fn sessionLauncherInsertChar(codepoint: u21) void {
    if (codepoint < 0x20 or codepoint == 0x7f) return;
    if (g_ssh_list_visible) {
        appendSshListFilterCodepoint(codepoint);
        return;
    }
    if (g_ssh_form_visible) {
        if (codepoint > 0x7f) return;
        if (g_ssh_focus >= SSH_FIELD_COUNT) return;
        const field = g_ssh_focus;
        if (g_ssh_lens[field] >= SSH_FIELD_MAX) return;
        g_ssh_bufs[field][g_ssh_lens[field]] = @intCast(codepoint);
        g_ssh_lens[field] += 1;
        return;
    }
    if (g_ai_form_visible) {
        if (g_ai_focus >= AI_FIELD_COUNT) return;
        appendAiFormCodepoint(g_ai_focus, codepoint);
    }
}

pub fn sessionLauncherPasteText(text: []const u8) bool {
    if (g_ssh_list_visible) {
        appendSshListFilterText(text);
        return true;
    }
    if (g_ai_form_visible) {
        if (g_ai_focus >= AI_FIELD_COUNT) return false;
        appendAiFormText(g_ai_focus, text);
        return true;
    }
    if (g_ssh_form_visible) {
        if (g_ssh_focus >= SSH_FIELD_COUNT) return false;
        appendSshFormText(g_ssh_focus, text);
        return true;
    }
    return false;
}

fn aiHistorySourceSshRow() usize {
    return if (platform_pty_command.sessionLauncherWslRow() != null) 2 else 1;
}

fn aiHistorySourceCancelRow() usize {
    return aiHistorySourceSshRow() + 1;
}

fn aiHistorySourceRowCount() usize {
    return aiHistorySourceCancelRow() + 1;
}

fn aiHistorySourceChoiceForRow(row: usize) ?AiHistorySourceChoice {
    if (row == 0) return .local;
    if (platform_pty_command.sessionLauncherWslRow()) |wsl_row| {
        if (row == wsl_row - 1) return .wsl;
    }
    if (row == aiHistorySourceSshRow()) return .ssh;
    return null;
}

fn handleAiHistorySourceKey(ev: input_key.KeyEvent) void {
    const row_count = aiHistorySourceRowCount();
    switch (ev.key) {
        .arrow_down, .tab => g_ai_history_source_selected = (g_ai_history_source_selected + 1) % row_count,
        .arrow_up => g_ai_history_source_selected = if (g_ai_history_source_selected == 0) row_count - 1 else g_ai_history_source_selected - 1,
        .enter => runAiHistorySourceRow(g_ai_history_source_selected),
        .key_l => runAiHistorySourceRow(0),
        .key_w => {
            if (platform_pty_command.sessionLauncherWslRow() != null) runAiHistorySourceRow(1);
        },
        .key_s => runAiHistorySourceRow(aiHistorySourceSshRow()),
        else => {},
    }
}

pub fn sessionLauncherHandleKey(ev: input_key.KeyEvent) void {
    if (ev.key == .escape) {
        if (g_ssh_list_visible and g_ssh_list_filter_len > 0) {
            clearSshListFilter();
            return;
        }
        if (g_ssh_list_visible and g_ssh_list_mode == .ai_history_select) {
            openAiHistorySourcePicker();
            return;
        }
        sessionLauncherBackOrClose();
        return;
    }

    if (!g_ssh_form_visible and !g_ai_form_visible) {
        if (g_ai_history_source_visible) {
            handleAiHistorySourceKey(ev);
            return;
        }
        if (g_ssh_list_visible) {
            handleSshListKey(ev);
            return;
        }
        if (g_ai_list_visible) {
            handleAiListKey(ev);
            return;
        }
        switch (ev.key) {
            .arrow_down, .tab => g_session_launcher_selected = (g_session_launcher_selected + 1) % platform_pty_command.sessionLauncherRowCount(),
            .arrow_up => g_session_launcher_selected = if (g_session_launcher_selected == 0) platform_pty_command.sessionLauncherRowCount() - 1 else g_session_launcher_selected - 1,
            .enter => runSessionLauncherRow(g_session_launcher_selected),
            .key_p => {
                g_session_launcher_selected = 0;
                runSessionLauncherRow(g_session_launcher_selected);
            },
            .key_s => {
                g_session_launcher_selected = 1;
                runSessionLauncherRow(g_session_launcher_selected);
            },
            .key_w => {
                if (platform_pty_command.sessionLauncherWslRow()) |wsl_row| {
                    g_session_launcher_selected = wsl_row;
                    runSessionLauncherRow(g_session_launcher_selected);
                }
            },
            .key_a => {
                g_session_launcher_selected = platform_pty_command.sessionLauncherAiAgentRow();
                runSessionLauncherRow(g_session_launcher_selected);
            },
            .key_h => {
                g_session_launcher_selected = platform_pty_command.sessionLauncherAiHistoryRow();
                runSessionLauncherRow(g_session_launcher_selected);
            },
            else => {},
        }
        return;
    }

    if (g_ai_form_visible) {
        switch (ev.key) {
            .tab, .arrow_down => g_ai_focus = (g_ai_focus + 1) % (AI_FIELD_COUNT + 3),
            .arrow_up => g_ai_focus = if (g_ai_focus == 0) AI_FIELD_COUNT + 2 else g_ai_focus - 1,
            .arrow_right => {
                if (g_ai_focus == @intFromEnum(AiField.protocol)) cycleAiFormProtocol(true);
                if (g_ai_focus == @intFromEnum(AiField.vision)) toggleAiFormVision();
            },
            .arrow_left => {
                if (g_ai_focus == @intFromEnum(AiField.protocol)) cycleAiFormProtocol(false);
                if (g_ai_focus == @intFromEnum(AiField.vision)) toggleAiFormVision();
            },
            .backspace => {
                if (g_ai_focus < AI_FIELD_COUNT) backspaceAiFormField(g_ai_focus);
            },
            .enter => runAiFormFocusAction(),
            else => {},
        }
        return;
    }

    switch (ev.key) {
        .tab, .arrow_down => g_ssh_focus = (g_ssh_focus + 1) % (SSH_FIELD_COUNT + 3),
        .arrow_up => g_ssh_focus = if (g_ssh_focus == 0) SSH_FIELD_COUNT + 2 else g_ssh_focus - 1,
        .backspace => {
            if (g_ssh_focus < SSH_FIELD_COUNT and g_ssh_lens[g_ssh_focus] > 0) g_ssh_lens[g_ssh_focus] -= 1;
        },
        .enter => runSshFormFocusAction(),
        else => {},
    }
}

/// Mouse-wheel handling for the session launcher. Scrolls by moving the active
/// mode's selected/focused row (the view follows it), clamped at the ends so the
/// wheel never wraps. Positive delta scrolls toward the top, mirroring
/// whatsNewHandleScroll().
pub fn sessionLauncherHandleScroll(delta_y: f64) void {
    if (!sessionLauncherVisible()) return;
    const step: i32 = if (delta_y > 0) -1 else if (delta_y < 0) 1 else 0;
    if (step == 0) return;
    const count = sessionActiveRowCount();
    if (count == 0) return;
    const sel = sessionActiveSelectionPtr();
    if (step < 0) {
        if (sel.* == 0) return;
        sel.* -= 1;
    } else {
        if (sel.* + 1 >= count) return;
        sel.* += 1;
    }
}

pub fn sessionLauncherContainsPoint(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const layout = sessionLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    return x >= layout.box_x and x <= layout.box_x + layout.box_w and
        y >= layout.box_top_px and y <= layout.box_top_px + layout.box_h;
}

pub fn sessionLauncherExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const action = sessionHitTest(xpos, ypos, window_width, window_height, top_offset) orelse return false;
    switch (action) {
        .local_shell => openLocalShellSession(),
        .ssh => openSshList(),
        .tmux => openTmuxSshPicker(),
        .wsl => openWslSession(),
        .ai_chat => openDefaultAiSession(),
        .ai_history => openAiHistorySourcePicker(),
        .ai_history_local => openLocalAiHistorySession(),
        .ai_history_wsl => openWslAiHistorySession(),
        .ai_history_ssh => openAiHistorySshPicker(),
        .connect_selected => runSshListRow(g_ssh_list_selected),
        .load_openssh_config => loadOpenSshConfigDefault(),
        .new_ssh => openSshFormNew(),
        .edit_selected => openSshEditPicker(),
        .delete_selected => openSshDeletePicker(),
        .connect_ai_selected => runAiListRow(g_ai_list_selected),
        .new_ai => openAiFormNew(),
        .edit_ai_selected => openAiEditPicker(),
        .delete_ai_selected => openAiDeletePicker(),
        .connect => connectSshFromForm(),
        .save => saveSshFormOnly(),
        .connect_ai => connectAiFromForm(),
        .save_ai => saveAiFormOnly(),
        .cancel => sessionLauncherBackOrClose(),
    }
    return true;
}

fn openLocalShellSession() void {
    sessionLauncherClose();
    _ = AppWindow.spawnConfiguredLocalShellTab();
}

fn openWslSession() void {
    sessionLauncherClose();
    var command_buf: [1024]u8 = undefined;
    const command = platform_pty_command.wslInteractiveCommand(command_buf[0..], null) orelse return;
    _ = AppWindow.spawnTabWithCommandUtf8(command);
}

fn openAiHistorySourcePicker() void {
    g_session_launcher_visible = false;
    g_ssh_list_visible = false;
    g_ssh_form_visible = false;
    g_ai_list_visible = false;
    g_ai_form_visible = false;
    g_ai_history_source_visible = true;
    g_ai_history_source_selected = 0;
}

fn openLocalAiHistorySession() void {
    sessionLauncherClose();
    _ = AppWindow.spawnAiHistoryTab(.{
        .id = "local",
        .name = "Local",
        .target = .local,
    });
}

fn openWslAiHistorySession() void {
    sessionLauncherClose();
    _ = AppWindow.spawnAiHistoryTab(.{
        .id = "wsl-default",
        .name = "WSL",
        .target = .{ .wsl = .{} },
    });
}

fn openAiHistorySshPicker() void {
    loadSshProfiles();
    openSshProfilePicker(.ai_history_select);
}

fn openSshAiHistorySession(profile_idx: usize) void {
    if (profile_idx >= g_ssh_profile_count) return;
    const profile = &g_ssh_profiles[profile_idx];
    const name = profileField(profile, .name);
    sessionLauncherClose();
    _ = AppWindow.spawnAiHistoryTab(.{
        .id = name,
        .name = name,
        .target = .{ .ssh = .{ .profile_name = name } },
    });
}

fn runAiHistorySourceRow(row: usize) void {
    if (aiHistorySourceChoiceForRow(row)) |choice| {
        switch (choice) {
            .local => openLocalAiHistorySession(),
            .wsl => openWslAiHistorySession(),
            .ssh => openAiHistorySshPicker(),
        }
    } else {
        sessionLauncherClose();
    }
}

fn runSessionLauncherRow(row: usize) void {
    if (row == 0) {
        openLocalShellSession();
    } else if (row == 1) {
        openSshList();
    } else if (row == command_center_state.SESSION_LAUNCHER_ROW_TMUX) {
        openTmuxSshPicker();
        return;
    } else if (platform_pty_command.sessionLauncherWslRow()) |wsl_row| {
        if (row == wsl_row) {
            openWslSession();
            return;
        }
    }
    if (row == platform_pty_command.sessionLauncherAiAgentRow()) {
        openDefaultAiSession();
    } else if (row == platform_pty_command.sessionLauncherAiHistoryRow()) {
        openAiHistorySourcePicker();
    }
}

fn openSshList() void {
    loadSshProfiles();
    g_session_launcher_visible = false;
    g_ai_history_source_visible = false;
    g_ssh_list_visible = true;
    g_ssh_form_visible = false;
    g_ssh_list_mode = .manage;
    clearSshListFilter();
    clampSshListSelection();
}

fn openSshEditPicker() void {
    openSshProfilePicker(.edit_select);
}

fn openSshDeletePicker() void {
    openSshProfilePicker(.delete_select);
}

fn openSshProfilePicker(mode: SshListMode) void {
    if (g_ssh_profile_count == 0 and mode != .ai_history_select and mode != .tmux_connect) return;
    g_session_launcher_visible = false;
    g_ai_history_source_visible = false;
    g_ssh_list_visible = true;
    g_ssh_form_visible = false;
    g_ssh_list_mode = mode;
    clearSshListFilter();
    clampSshListSelection();
}

fn openSshFormNew() void {
    clearSshForm();
    g_ssh_edit_index = SSH_PROFILE_NONE;
    openSshForm();
}

fn openSshFormEdit(index: usize) void {
    if (index >= g_ssh_profile_count) return;
    clearSshForm();
    for (0..SSH_FIELD_COUNT) |i| {
        g_ssh_lens[i] = @min(g_ssh_profiles[index].lens[i], SSH_FIELD_MAX);
        @memcpy(g_ssh_bufs[i][0..g_ssh_lens[i]], g_ssh_profiles[index].fields[i][0..g_ssh_lens[i]]);
    }
    g_ssh_edit_index = index;
    openSshForm();
}

fn openSshForm() void {
    g_ssh_list_visible = false;
    g_session_launcher_visible = false;
    g_ai_history_source_visible = false;
    g_ssh_form_visible = true;
    g_ssh_focus = @intFromEnum(SshField.name);
    if (g_ssh_lens[@intFromEnum(SshField.port)] == 0) {
        g_ssh_bufs[@intFromEnum(SshField.port)][0] = '2';
        g_ssh_bufs[@intFromEnum(SshField.port)][1] = '2';
        g_ssh_lens[@intFromEnum(SshField.port)] = 2;
    }
}

fn clearSshForm() void {
    g_ssh_lens = .{0} ** SSH_FIELD_COUNT;
    g_ssh_bufs[@intFromEnum(SshField.port)][0] = '2';
    g_ssh_bufs[@intFromEnum(SshField.port)][1] = '2';
    g_ssh_lens[@intFromEnum(SshField.port)] = 2;
    appendSshFormText(@intFromEnum(SshField.auth_method), profile_codec.defaultSshFormAuthMethod());
}

fn handleSshListKey(ev: input_key.KeyEvent) void {
    const row_count = sshListRowCount();
    switch (ev.key) {
        .arrow_down, .tab => g_ssh_list_selected = (g_ssh_list_selected + 1) % row_count,
        .arrow_up => g_ssh_list_selected = if (g_ssh_list_selected == 0) row_count - 1 else g_ssh_list_selected - 1,
        .enter => runSshListRow(g_ssh_list_selected),
        .backspace => backspaceSshListFilter(),
        else => {},
    }
}

fn sshListRowCount() usize {
    return switch (g_ssh_list_mode) {
        .manage => sshVisibleProfileCount() + 5,
        .edit_select, .delete_select, .ai_history_select, .tmux_connect => sshVisibleProfileCount() + 1,
    };
}

const SshManageAction = enum {
    profile,
    load_openssh_config,
    new_ssh,
    edit_ssh,
    delete_ssh,
    cancel,
};

fn sshManageActionForRow(row: usize, visible_profile_count: usize) SshManageAction {
    if (row < visible_profile_count) return .profile;
    return switch (row - visible_profile_count) {
        0 => .load_openssh_config,
        1 => .new_ssh,
        2 => .edit_ssh,
        3 => .delete_ssh,
        else => .cancel,
    };
}

fn sshListFilter() []const u8 {
    return g_ssh_list_filter_buf[0..g_ssh_list_filter_len];
}

fn clearSshListFilter() void {
    g_ssh_list_filter_len = 0;
    resetSshListSelection();
}

fn backspaceSshListFilter() void {
    if (g_ssh_list_filter_len == 0) return;
    g_ssh_list_filter_len -= 1;
    resetSshListSelection();
}

fn appendSshListFilterCodepoint(codepoint: u21) void {
    if (codepoint > 0x7f) return;
    if (g_ssh_list_filter_len >= g_ssh_list_filter_buf.len) return;
    g_ssh_list_filter_buf[g_ssh_list_filter_len] = @intCast(codepoint);
    g_ssh_list_filter_len += 1;
    resetSshListSelection();
}

fn appendSshListFilterText(text: []const u8) void {
    for (text) |ch| {
        if (ch < 0x20 or ch == 0x7f) continue;
        if (g_ssh_list_filter_len >= g_ssh_list_filter_buf.len) break;
        g_ssh_list_filter_buf[g_ssh_list_filter_len] = ch;
        g_ssh_list_filter_len += 1;
    }
    resetSshListSelection();
}

fn sshProfileMatchesFilter(profile: *const SshProfile) bool {
    const filter = sshListFilter();
    if (filter.len == 0) return true;
    return startsWithIgnoreCase(profileField(profile, .name), filter);
}

fn sshVisibleProfileCount() usize {
    var count: usize = 0;
    for (0..g_ssh_profile_count) |idx| {
        if (sshProfileMatchesFilter(&g_ssh_profiles[idx])) count += 1;
    }
    return count;
}

fn sshVisibleProfileIndexAt(visible_row: usize) ?usize {
    var count: usize = 0;
    for (0..g_ssh_profile_count) |idx| {
        if (!sshProfileMatchesFilter(&g_ssh_profiles[idx])) continue;
        if (count == visible_row) return idx;
        count += 1;
    }
    return null;
}

fn clampSshListSelection() void {
    const row_count = sshListRowCount();
    if (row_count == 0) {
        g_ssh_list_selected = 0;
        return;
    }
    g_ssh_list_selected = @min(g_ssh_list_selected, row_count - 1);
}

fn resetSshListSelection() void {
    g_ssh_list_selected = 0;
    clampSshListSelection();
}

fn sshField(field: SshField) []const u8 {
    const idx: usize = @intFromEnum(field);
    return g_ssh_bufs[idx][0..g_ssh_lens[idx]];
}

const profileField = profile_codec.profileField;

fn parseSshAuthMethod(value: []const u8) ?ssh_connection.SshAuthMethod {
    return ssh_connection.SshAuthMethod.parse(std.mem.trim(u8, value, " \t\r\n"));
}

fn defaultSshAuthMethodForPassword(password: []const u8) ssh_connection.SshAuthMethod {
    return if (password.len > 0) .password else .credentials;
}

fn sshFormAuthMethod() ?ssh_connection.SshAuthMethod {
    const raw = sshField(.auth_method);
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return defaultSshAuthMethodForPassword(sshField(.password));
    return parseSshAuthMethod(raw);
}

fn sshProfileAuthMethod(profile: *const SshProfile) ?ssh_connection.SshAuthMethod {
    const raw = profileField(profile, .auth_method);
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return defaultSshAuthMethodForPassword(profileField(profile, .password));
    return parseSshAuthMethod(raw);
}

fn isIdentityFileSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

fn sshConnectionFromProfile(profile: *const SshProfile) ?ssh_connection.SshConnection {
    const ip = profileField(profile, .ip);
    const user = profileField(profile, .user);
    const port = profileField(profile, .port);
    const password = profileField(profile, .password);
    const proxy_jump = profileField(profile, .proxy_jump);
    const auth_method = sshProfileAuthMethod(profile) orelse return null;
    const identity_file = profileField(profile, .identity_file);
    if (ip.len == 0 or user.len == 0) return null;
    if (!isSshTokenSafe(ip) or !isSshTokenSafe(user)) return null;
    if (port.len > 0 and !isPortTokenSafe(port)) return null;
    if (!command_palette_model.isProxyJumpSafe(proxy_jump)) return null;
    if (auth_method == .password and password.len == 0) return null;
    if (auth_method == .key and !isIdentityFileSafe(identity_file)) return null;

    var conn = ssh_connection.SshConnection.fromParts(.{
        .user = user,
        .host = ip,
        .port = port,
        .proxy_jump = proxy_jump,
        .password = password,
        .auth_method = auth_method,
        .identity_file = identity_file,
    });
    conn.legacy_algorithms = AppWindow.g_ssh_legacy_algorithms;
    return conn;
}

fn findSshProfileIndex(identifier_raw: []const u8) ?usize {
    loadSshProfiles();
    return findLoadedSshProfileIndex(identifier_raw);
}

fn findLoadedSshProfileIndex(identifier_raw: []const u8) ?usize {
    const identifier = std.mem.trim(u8, identifier_raw, " \t\r\n");
    if (identifier.len == 0) return null;

    for (0..g_ssh_profile_count) |idx| {
        if (std.ascii.eqlIgnoreCase(identifier, profileField(&g_ssh_profiles[idx], .name))) return idx;
    }
    for (0..g_ssh_profile_count) |idx| {
        if (std.ascii.eqlIgnoreCase(identifier, profileField(&g_ssh_profiles[idx], .ip))) return idx;
    }
    return null;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

pub fn agentConnectSshProfile(identifier: []const u8) AgentSshConnectResult {
    const idx = findSshProfileIndex(identifier) orelse return .not_found;
    const surface = connectSshProfileReturningSurface(idx) orelse return .failed;
    return .{ .connected = surface };
}

pub fn aiHistoryConnectSshProfile(identifier: []const u8, remote_command: []const u8) AgentSshConnectResult {
    const idx = findSshProfileIndex(identifier) orelse return .not_found;
    const surface = connectSshProfileReturningSurfaceWithCommand(idx, remote_command) orelse return .failed;
    return .{ .connected = surface };
}

pub fn aiHistorySshConnection(identifier: []const u8) ?ssh_connection.SshConnection {
    const idx = findSshProfileIndex(identifier) orelse return null;
    if (idx >= g_ssh_profile_count) return null;
    return sshConnectionFromProfile(&g_ssh_profiles[idx]);
}

/// Enumerate the saved SSH profile names (UI thread; loads the threadlocal
/// store on demand). Returns an owned slice of owned name strings — the caller
/// frees each name and then the slice. Used by the Skill Center to build one
/// scan column per SSH profile. Empty/unsafe names are skipped.
pub fn sshProfileNames(allocator: std.mem.Allocator) ![][]u8 {
    loadSshProfiles();
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }
    for (0..g_ssh_profile_count) |idx| {
        const name = profileField(&g_ssh_profiles[idx], .name);
        if (name.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, name));
    }
    return out.toOwnedSlice(allocator);
}

const copySshProfileField = profile_codec.copySshProfileField;

const makeSshProfile = profile_codec.makeSshProfile;

const OpenSshImportStats = struct {
    created: usize = 0,
    updated: usize = 0,
    skipped: usize = 0,
    capped: bool = false,
};

fn mergeOpenSshCandidate(candidate: openssh_config_import.Candidate, stats: *OpenSshImportStats) void {
    const name = candidate.name();
    const host = candidate.host();
    const user = candidate.user();
    const port = candidate.port();
    const proxy_jump = candidate.proxyJump();
    if (name.len == 0 or host.len == 0 or user.len == 0) {
        stats.skipped += 1;
        return;
    }
    if (!isSshTokenSafe(name) or !isSshTokenSafe(host) or !isSshTokenSafe(user)) {
        stats.skipped += 1;
        return;
    }
    if (!isPortTokenSafe(port) or !command_palette_model.isProxyJumpSafe(proxy_jump)) {
        stats.skipped += 1;
        return;
    }

    const found_idx = findLoadedSshProfileIndex(name) orelse findLoadedSshProfileIndex(host);
    var created_new = false;
    const idx = found_idx orelse blk: {
        if (g_ssh_profile_count >= SSH_PROFILE_MAX) {
            stats.capped = true;
            return;
        }
        const next = g_ssh_profile_count;
        g_ssh_profile_count += 1;
        g_ssh_profiles[next] = .{};
        created_new = true;
        break :blk next;
    };

    if (idx >= g_ssh_profile_count) {
        stats.skipped += 1;
        return;
    }

    if (created_new) {
        stats.created += 1;
    } else {
        stats.updated += 1;
    }
    const profile = &g_ssh_profiles[idx];
    copySshProfileField(profile, .name, name);
    copySshProfileField(profile, .ip, host);
    copySshProfileField(profile, .user, user);
    copySshProfileField(profile, .port, if (port.len > 0) port else "22");
    copySshProfileField(profile, .proxy_jump, proxy_jump);
    if (created_new) {
        copySshProfileField(profile, .auth_method, ssh_connection.SshAuthMethod.credentials.fieldValue());
        copySshProfileField(profile, .identity_file, "");
    }
}

fn opensshCandidateSetForTest(candidate: *openssh_config_import.Candidate, comptime field: enum { name, host, user, port, proxy_jump }, value: []const u8) void {
    const len = @min(value.len, openssh_config_import.FIELD_MAX);
    switch (field) {
        .name => {
            @memcpy(candidate.name_buf[0..len], value[0..len]);
            candidate.name_len = len;
        },
        .host => {
            @memcpy(candidate.host_buf[0..len], value[0..len]);
            candidate.host_len = len;
        },
        .user => {
            @memcpy(candidate.user_buf[0..len], value[0..len]);
            candidate.user_len = len;
        },
        .port => {
            @memcpy(candidate.port_buf[0..len], value[0..len]);
            candidate.port_len = len;
        },
        .proxy_jump => {
            @memcpy(candidate.proxy_jump_buf[0..len], value[0..len]);
            candidate.proxy_jump_len = len;
        },
    }
}

pub fn agentSaveSshProfile(allocator: std.mem.Allocator, args: AppWindow.ai_chat.SshProfileSaveArgs) !AppWindow.ai_chat.SavedSshProfile {
    loadSshProfiles();

    const host = std.mem.trim(u8, args.host, " \t\r\n");
    const user = std.mem.trim(u8, args.user, " \t\r\n");
    const name_raw = std.mem.trim(u8, args.name, " \t\r\n");
    const port_raw = std.mem.trim(u8, args.port, " \t\r\n");
    const port = if (port_raw.len > 0) port_raw else "22";
    const proxy_jump = std.mem.trim(u8, args.proxy_jump, " \t\r\n");
    const identity_file = std.mem.trim(u8, args.identity_file, " \t\r\n");
    const auth_method_raw = std.mem.trim(u8, args.auth_method, " \t\r\n");
    if (host.len == 0 or user.len == 0) return error.InvalidProfile;
    if (!isSshTokenSafe(host) or !isSshTokenSafe(user)) return error.InvalidProfile;
    if (!isPortTokenSafe(port)) return error.InvalidProfile;
    if (!command_palette_model.isProxyJumpSafe(proxy_jump)) return error.InvalidProfile;

    const lookup = if (name_raw.len > 0) name_raw else host;
    const found_idx = findSshProfileIndex(lookup) orelse findSshProfileIndex(host);
    const updated_existing = found_idx != null;
    const idx = found_idx orelse blk: {
        if (g_ssh_profile_count >= SSH_PROFILE_MAX) return error.ProfileLimit;
        const next = g_ssh_profile_count;
        g_ssh_profile_count += 1;
        g_ssh_profiles[next] = .{};
        break :blk next;
    };

    const profile = &g_ssh_profiles[idx];
    const auth_method = if (auth_method_raw.len > 0)
        (parseSshAuthMethod(auth_method_raw) orelse return error.InvalidProfile)
    else if (args.password.len > 0)
        ssh_connection.SshAuthMethod.password
    else if (identity_file.len > 0)
        ssh_connection.SshAuthMethod.key
    else if (updated_existing)
        (sshProfileAuthMethod(profile) orelse defaultSshAuthMethodForPassword(profileField(profile, .password)))
    else
        ssh_connection.SshAuthMethod.credentials;
    const password_to_save = if (auth_method == .password)
        (if (args.password.len > 0) args.password else profileField(profile, .password))
    else
        "";
    const identity_to_save = if (auth_method == .key)
        (if (identity_file.len > 0) identity_file else profileField(profile, .identity_file))
    else
        "";
    if (auth_method == .password and password_to_save.len == 0) return error.InvalidProfile;
    if (auth_method == .key and !isIdentityFileSafe(identity_to_save)) return error.InvalidProfile;

    const final_name = if (name_raw.len > 0)
        name_raw
    else if (updated_existing and profileField(profile, .name).len > 0)
        profileField(profile, .name)
    else
        host;

    copySshProfileField(profile, .name, final_name);
    copySshProfileField(profile, .ip, host);
    copySshProfileField(profile, .user, user);
    copySshProfileField(profile, .password, password_to_save);
    if (proxy_jump.len > 0 or !updated_existing) {
        copySshProfileField(profile, .proxy_jump, proxy_jump);
    }
    copySshProfileField(profile, .port, port);
    copySshProfileField(profile, .auth_method, auth_method.fieldValue());
    copySshProfileField(profile, .identity_file, identity_to_save);

    saveSshProfiles(allocator);

    const saved_name = profileField(profile, .name);
    const saved_host = profileField(profile, .ip);
    const saved_user = profileField(profile, .user);
    const saved_port = profileField(profile, .port);
    const saved_auth_method = profileField(profile, .auth_method);
    const name_copy = try allocator.dupe(u8, saved_name);
    errdefer allocator.free(name_copy);
    const host_copy = try allocator.dupe(u8, saved_host);
    errdefer allocator.free(host_copy);
    const user_copy = try allocator.dupe(u8, saved_user);
    errdefer allocator.free(user_copy);
    const port_copy = try allocator.dupe(u8, saved_port);
    errdefer allocator.free(port_copy);
    const auth_method_copy = try allocator.dupe(u8, saved_auth_method);
    errdefer allocator.free(auth_method_copy);
    return .{
        .name = name_copy,
        .host = host_copy,
        .user = user_copy,
        .port = port_copy,
        .auth_method = auth_method_copy,
        .updated_existing = updated_existing,
        .password_saved = profileField(profile, .password).len > 0,
        .identity_file_saved = profileField(profile, .identity_file).len > 0,
    };
}

fn runSshListRow(row: usize) void {
    const visible_profile_count = sshVisibleProfileCount();
    switch (g_ssh_list_mode) {
        .manage => {
            switch (sshManageActionForRow(row, visible_profile_count)) {
                .profile => {
                    const profile_idx = sshVisibleProfileIndexAt(row) orelse return;
                    connectSshProfile(profile_idx);
                },
                .load_openssh_config => loadOpenSshConfigDefault(),
                .new_ssh => openSshFormNew(),
                .edit_ssh => openSshEditPicker(),
                .delete_ssh => openSshDeletePicker(),
                .cancel => sessionLauncherClose(),
            }
        },
        .edit_select => {
            if (row < visible_profile_count) {
                const profile_idx = sshVisibleProfileIndexAt(row) orelse return;
                openSshFormEdit(profile_idx);
            } else {
                openSshList();
            }
        },
        .delete_select => {
            if (row < visible_profile_count) {
                const profile_idx = sshVisibleProfileIndexAt(row) orelse return;
                deleteSshProfile(profile_idx);
                openSshList();
            } else {
                openSshList();
            }
        },
        .ai_history_select => {
            if (row < visible_profile_count) {
                const profile_idx = sshVisibleProfileIndexAt(row) orelse return;
                openSshAiHistorySession(profile_idx);
            } else {
                openAiHistorySourcePicker();
            }
        },
        .tmux_connect => {
            if (row < visible_profile_count) {
                const profile_idx = sshVisibleProfileIndexAt(row) orelse return;
                connectSshProfileTmux(profile_idx);
            } else {
                sessionLauncherClose();
            }
        },
    }
}

fn deleteSshProfile(idx: usize) void {
    if (g_ssh_profile_count == 0) return;
    if (idx >= g_ssh_profile_count) return;
    var i = idx;
    while (i + 1 < g_ssh_profile_count) : (i += 1) {
        g_ssh_profiles[i] = g_ssh_profiles[i + 1];
    }
    g_ssh_profile_count -= 1;
    clampSshListSelection();
    if (AppWindow.g_allocator) |allocator| saveSshProfiles(allocator);
}

fn connectSshFromForm() void {
    const idx = saveSshFormProfile() orelse return;
    connectSshProfile(idx);
}

fn saveSshFormOnly() void {
    _ = saveSshFormProfile() orelse return;
    openSshList();
}

fn runSshFormFocusAction() void {
    if (g_ssh_focus < SSH_FIELD_COUNT) {
        g_ssh_focus = (g_ssh_focus + 1) % (SSH_FIELD_COUNT + 3);
        return;
    }
    switch (g_ssh_focus - SSH_FIELD_COUNT) {
        0 => connectSshFromForm(),
        1 => saveSshFormOnly(),
        else => openSshList(),
    }
}

fn saveSshFormProfile() ?usize {
    const allocator = AppWindow.g_allocator orelse return null;
    const ip = sshField(.ip);
    const user = sshField(.user);
    const port = sshField(.port);
    const auth_method = sshFormAuthMethod() orelse return null;
    if (ip.len == 0 or user.len == 0) return null;
    if (!isSshTokenSafe(ip) or !isSshTokenSafe(user)) return null;
    if (port.len > 0 and !isPortTokenSafe(port)) return null;
    if (!command_palette_model.isProxyJumpSafe(sshField(.proxy_jump))) return null;
    if (auth_method == .password and sshField(.password).len == 0) return null;
    if (auth_method == .key and !isIdentityFileSafe(sshField(.identity_file))) return null;

    const idx = if (g_ssh_edit_index != SSH_PROFILE_NONE)
        g_ssh_edit_index
    else blk: {
        if (g_ssh_profile_count >= SSH_PROFILE_MAX) return null;
        const next = g_ssh_profile_count;
        g_ssh_profile_count += 1;
        break :blk next;
    };

    for (0..SSH_FIELD_COUNT) |i| {
        g_ssh_profiles[idx].lens[i] = g_ssh_lens[i];
        @memcpy(g_ssh_profiles[idx].fields[i][0..g_ssh_lens[i]], g_ssh_bufs[i][0..g_ssh_lens[i]]);
    }
    copySshProfileField(&g_ssh_profiles[idx], .auth_method, auth_method.fieldValue());
    if (auth_method != .password) copySshProfileField(&g_ssh_profiles[idx], .password, "");
    if (auth_method != .key) copySshProfileField(&g_ssh_profiles[idx], .identity_file, "");
    if (g_ssh_profiles[idx].lens[@intFromEnum(SshField.name)] == 0) {
        const host = sshField(.ip);
        const len = @min(host.len, SSH_FIELD_MAX);
        @memcpy(g_ssh_profiles[idx].fields[@intFromEnum(SshField.name)][0..len], host[0..len]);
        g_ssh_profiles[idx].lens[@intFromEnum(SshField.name)] = len;
    }

    saveSshProfiles(allocator);
    g_ssh_edit_index = idx;
    return idx;
}

fn connectSshProfile(idx: usize) void {
    _ = connectSshProfileReturningSurface(idx);
}

/// Derive a tmux-safe session name from a profile name: `wispterm-<name>` with
/// every char outside [A-Za-z0-9_-] replaced by '_'. Empty name → "wispterm".
/// `buf` must be at least 9 + name.len bytes.
fn tmuxSessionName(buf: []u8, profile_name: []const u8) []const u8 {
    const prefix = "wispterm";
    @memcpy(buf[0..prefix.len], prefix);
    if (profile_name.len == 0) return buf[0..prefix.len];
    buf[prefix.len] = '-';
    var n: usize = prefix.len + 1;
    for (profile_name) |c| {
        if (n >= buf.len) break;
        buf[n] = if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') c else '_';
        n += 1;
    }
    return buf[0..n];
}

/// Open the SSH profile picker in tmux-connect mode (mirrors the AI-history SSH
/// picker). Picking a profile starts a tmux control-mode session.
fn openTmuxSshPicker() void {
    loadSshProfiles();
    openSshProfilePicker(.tmux_connect);
}

/// Connect the profile at `idx` in tmux control mode: `ssh … tmux -CC new -A -s
/// wispterm-<profile>`. No surface is spawned — the controller owns the tabs.
fn connectSshProfileTmux(idx: usize) void {
    if (idx >= g_ssh_profile_count) return;
    const profile = &g_ssh_profiles[idx];
    const name = profileField(profile, .name);
    const conn = sshConnectionFromProfile(profile) orelse return;

    var name_buf: [96]u8 = undefined;
    const session_name = tmuxSessionName(&name_buf, name);
    var remote_buf: [128]u8 = undefined;
    const remote = std.fmt.bufPrint(&remote_buf, "tmux -CC new -A -s {s}", .{session_name}) catch return;

    var cmd_buf: [8192]u8 = undefined;
    const cmd = platform_pty_command.sshControlCommand(cmd_buf[0..], .{
        .user = conn.user(),
        .host = conn.host(),
        .port = conn.port(),
        .auth_method = conn.auth_method,
        .identity_file = conn.identityFile(),
        .password_auth = conn.password_auth,
        .legacy_algorithms = AppWindow.g_ssh_legacy_algorithms,
        .proxy_jump = conn.proxyJump(),
        .remote_command = remote,
    }) orelse return;

    sessionLauncherClose();
    _ = AppWindow.startTmuxSession(cmd, if (conn.usesPasswordAuth()) conn.password() else "", name, conn);
}

/// Connect a profile by name in tmux mode (dev/automation hook).
pub fn connectProfileByNameTmux(name: []const u8) bool {
    loadSshProfiles();
    var idx: usize = 0;
    while (idx < g_ssh_profile_count) : (idx += 1) {
        if (std.mem.eql(u8, profileField(&g_ssh_profiles[idx], .name), name)) {
            connectSshProfileTmux(idx);
            return true;
        }
    }
    return false;
}

/// Connect the SSH profile with the given name (Phase 3d programmatic/test
/// entry). Loads profiles if needed; returns false if no profile matches.
pub fn connectProfileByName(name: []const u8) bool {
    loadSshProfiles();
    var idx: usize = 0;
    while (idx < g_ssh_profile_count) : (idx += 1) {
        if (std.mem.eql(u8, profileField(&g_ssh_profiles[idx], .name), name)) {
            connectSshProfile(idx);
            return true;
        }
    }
    return false;
}

fn connectSshProfileReturningSurface(idx: usize) ?*Surface {
    return connectSshProfileReturningSurfaceWithCommand(idx, "");
}

fn connectSshProfileReturningSurfaceWithCommand(idx: usize, remote_command: []const u8) ?*Surface {
    if (idx >= g_ssh_profile_count) return null;
    const profile = &g_ssh_profiles[idx];
    const server_name = profileField(profile, .name);
    const conn = sshConnectionFromProfile(profile) orelse return null;

    var command_buf: [8192]u8 = undefined;
    const command = platform_pty_command.sshInteractiveCommand(command_buf[0..], .{
        .user = conn.user(),
        .host = conn.host(),
        .port = conn.port(),
        .auth_method = conn.auth_method,
        .identity_file = conn.identityFile(),
        .password_auth = conn.password_auth,
        .legacy_algorithms = AppWindow.g_ssh_legacy_algorithms,
        .proxy_jump = conn.proxyJump(),
        .remote_command = remote_command,
    }) orelse return null;

    sessionLauncherClose();
    if (AppWindow.spawnTabWithCommandUtf8ReturningSurface(command)) |surface| {
        surface.setSshConnectionValue(conn);
        if (server_name.len > 0) {
            surface.setTitleOverride(server_name);
        }
        if (conn.usesPasswordAuth()) {
            scheduleSshPasswordForSurface(surface, conn.password());
        }
        return surface;
    }
    return null;
}

fn isSshTokenSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch == '@') continue;
        return false;
    }
    return true;
}

fn isPortTokenSafe(value: []const u8) bool {
    if (value.len == 0) return true;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// Queue password entry for a new SSH surface.
///
/// OpenSSH only consumes the password after it has printed the password prompt.
/// A fixed startup delay races slow networks, so the main-loop tick waits until
/// the prompt is visible in terminal state before injecting the stored password.
pub fn scheduleSshPasswordForSurface(surface: *Surface, password: []const u8) void {
    const len = @min(password.len, SSH_FIELD_MAX);
    const now = std.time.milliTimestamp();
    @memcpy(g_pending_ssh_password[0..len], password[0..len]);
    g_pending_ssh_password[len] = '\r';
    g_pending_ssh_password_len = len + 1;
    g_pending_ssh_password_due_ms = now + SSH_PASSWORD_PROMPT_MIN_WAIT_MS;
    g_pending_ssh_password_deadline_ms = now + SSH_PASSWORD_PROMPT_TIMEOUT_MS;
    g_pending_ssh_surface = surface;
}

pub fn tickSessionLauncher() void {
    if (g_pending_ssh_password_len == 0) return;
    const now = std.time.milliTimestamp();
    if (now < g_pending_ssh_password_due_ms) return;

    const surface = g_pending_ssh_surface orelse {
        clearPendingSshPassword();
        return;
    };
    if (!surfaceIsOpen(surface)) {
        clearPendingSshPassword();
        return;
    }
    if (now > g_pending_ssh_password_deadline_ms) {
        clearPendingSshPassword();
        return;
    }
    if (!surfaceHasSshPasswordPrompt(surface)) return;

    AppWindow.input.writeTextToSurfacePty(surface, g_pending_ssh_password[0..g_pending_ssh_password_len]);
    clearPendingSshPassword();
}

fn clearPendingSshPassword() void {
    g_pending_ssh_password_len = 0;
    g_pending_ssh_password_due_ms = 0;
    g_pending_ssh_password_deadline_ms = 0;
    g_pending_ssh_surface = null;
}

fn surfaceIsOpen(surface: *const Surface) bool {
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (@intFromPtr(entry.surface) == @intFromPtr(surface)) return true;
        }
    }
    return false;
}

fn surfaceHasSshPasswordPrompt(surface: *Surface) bool {
    var line_buf: [SSH_PROMPT_SCAN_MAX_COLS]u8 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const rows: usize = @intCast(surface.size.grid.rows);
    const cols: usize = @min(@as(usize, @intCast(surface.size.grid.cols)), line_buf.len);
    const screen = surface.terminal.screens.active;

    for (0..rows) |row| {
        var last_col: ?usize = null;
        for (0..cols) |col| {
            const cell_data = screen.pages.getCell(.{ .viewport = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse continue;
            const cp = cell_data.cell.codepoint();
            if (cp != 0 and cp != ' ') last_col = col;
        }

        const end_col = last_col orelse continue;
        var len: usize = 0;
        for (0..end_col + 1) |col| {
            const cell_data = screen.pages.getCell(.{ .viewport = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse {
                line_buf[len] = ' ';
                len += 1;
                continue;
            };

            const wide_val: u2 = @intFromEnum(cell_data.cell.wide);
            if (wide_val == 2 or wide_val == 3) continue;

            const cp = cell_data.cell.codepoint();
            if (cp == 0 or cp == ' ' or cp > 0x7f) {
                line_buf[len] = ' ';
                len += 1;
            } else {
                line_buf[len] = @intCast(cp);
                len += 1;
            }
        }

        if (ssh_prompt.containsPasswordPromptText(line_buf[0..len])) return true;
    }

    return false;
}

fn openAiList() void {
    loadAiProfiles();
    g_session_launcher_visible = false;
    g_ssh_list_visible = false;
    g_ssh_form_visible = false;
    g_ai_history_source_visible = false;
    g_ai_list_visible = true;
    g_ai_form_visible = false;
    g_ai_list_mode = .manage;
    g_ai_list_selected = @min(g_ai_list_selected, aiListRowCount() - 1);
}

fn openDefaultAiSession() void {
    loadAiProfiles();
    if (g_ai_profile_count == 0) {
        openAiFormNew();
        return;
    }
    connectAiProfile(defaultAiProfileIndex());
}

fn openDefaultAgentSessionFromCommandCenter() void {
    loadAiProfiles();
    switch (command_center_state.resolveNewAgentLaunch(g_ai_profile_count != 0)) {
        .open_form => openAiFormNewFromCommandPalette(),
        .connect_default_profile_as_agent => connectAiProfileWithAgentOverride(defaultAiProfileIndex(), "true"),
    }
}

pub fn hasAiProfiles() bool {
    loadAiProfiles();
    return g_ai_profile_count > 0;
}

pub fn openDefaultAgentSessionForStartup() DefaultAgentOpenResult {
    loadAiProfiles();
    if (g_ai_profile_count == 0) {
        openAiFormNew();
        return .form_opened;
    }
    return if (spawnAiProfileWithAgentOverride(defaultAiProfileIndex(), "true")) .opened else .failed;
}

pub fn openDefaultAgentSessionForRemote() RemoteAgentOpenResult {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return .no_profile;
    return if (spawnAiProfileWithAgentOverride(defaultAiProfileIndex(), "true")) .opened else .failed;
}

pub fn openAgentSessionForRemoteProfile(profile_name: []const u8) NamedAgentOpenResult {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return .no_profile;
    const idx = blk: {
        const name = std.mem.trim(u8, profile_name, " \t\r\n");
        if (name.len == 0) break :blk defaultAiProfileIndex();
        var names: [AI_PROFILE_MAX][]const u8 = undefined;
        for (0..g_ai_profile_count) |i| names[i] = aiProfileField(&g_ai_profiles[i], .name);
        break :blk ai_model_switch.matchProfileByName(names[0..g_ai_profile_count], name) orelse return .unknown_profile;
    };
    return if (spawnAiProfileWithAgentOverride(idx, "true")) .opened else .failed;
}

pub fn aiModelProfileList(allocator: std.mem.Allocator) ![]u8 {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return allocator.dupe(u8, "");
    const default_idx = defaultAiProfileIndex();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (0..g_ai_profile_count) |idx| {
        const profile = &g_ai_profiles[idx];
        const name = aiProfileField(profile, .name);
        const model = aiProfileField(profile, .model);
        try out.print(allocator, "- {s}", .{name});
        if (model.len != 0 and !std.mem.eql(u8, name, model)) {
            try out.print(allocator, " ({s})", .{model});
        }
        if (idx == default_idx) try out.appendSlice(allocator, " [default]");
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn openAiEditPicker() void {
    openAiProfilePicker(.edit_select);
}

fn openAiDeletePicker() void {
    openAiProfilePicker(.delete_select);
}

fn openAiProfilePicker(mode: AiListMode) void {
    if (g_ai_profile_count == 0) return;
    g_session_launcher_visible = false;
    g_ssh_list_visible = false;
    g_ssh_form_visible = false;
    g_ai_list_visible = true;
    g_ai_form_visible = false;
    g_ai_list_mode = mode;
    g_ai_list_selected = if (g_ai_list_selected < g_ai_profile_count) g_ai_list_selected else 0;
}

fn openAiFormNew() void {
    clearAiForm();
    g_ai_edit_index = AI_PROFILE_NONE;
    openAiForm();
}

fn openAiFormEdit(index: usize) void {
    if (index >= g_ai_profile_count) return;
    clearAiForm();
    for (0..AI_FIELD_COUNT) |i| {
        g_ai_lens[i] = @min(g_ai_profiles[index].lens[i], AI_FIELD_MAX);
        @memcpy(g_ai_bufs[i][0..g_ai_lens[i]], g_ai_profiles[index].fields[i][0..g_ai_lens[i]]);
    }
    g_ai_edit_index = index;
    openAiForm();
}

pub fn openAiConfigForSession(session: *AppWindow.ai_chat.Session) void {
    loadAiProfiles();

    session.mutex.lock();
    const profile_idx = findAiProfileForSession(session.title(), session.baseUrl(), session.model());
    session.mutex.unlock();

    if (profile_idx) |idx| {
        openAiFormEdit(idx);
        g_ai_focus = @intFromEnum(AiField.api_key);
        return;
    }

    clearAiForm();
    session.mutex.lock();
    setAiDefault(.name, if (session.title().len > 0) session.title() else AppWindow.ai_chat.DEFAULT_NAME);
    setAiDefault(.base_url, session.baseUrl());
    setAiDefault(.api_key, session.apiKey());
    setAiDefault(.model, session.model());
    setAiDefault(.system_prompt, session.systemPrompt());
    setAiDefault(.thinking, session.thinkingConfigValue());
    setAiDefault(.reasoning_effort, session.reasoningEffort());
    setAiDefault(.stream, session.streamConfigValue());
    setAiDefault(.agent, session.agentConfigValue());
    setAiDefault(.protocol, session.apiProtocolName());
    setAiDefault(.vision, session.visionConfigValue());
    var max_tokens_buf: [16]u8 = undefined;
    if (std.fmt.bufPrint(max_tokens_buf[0..], "{d}", .{session.maxTokens()})) |s| {
        setAiDefault(.max_tokens, s);
    } else |_| {}
    session.mutex.unlock();

    g_ai_edit_index = AI_PROFILE_NONE;
    openAiForm();
    g_ai_focus = @intFromEnum(AiField.api_key);
}

fn findAiProfileForSession(name: []const u8, base_url: []const u8, model: []const u8) ?usize {
    if (name.len > 0) {
        for (0..g_ai_profile_count) |idx| {
            if (std.mem.eql(u8, aiProfileField(&g_ai_profiles[idx], .name), name)) return idx;
        }
    }

    if (base_url.len > 0 and model.len > 0) {
        for (0..g_ai_profile_count) |idx| {
            if (std.mem.eql(u8, aiProfileField(&g_ai_profiles[idx], .base_url), base_url) and
                std.mem.eql(u8, aiProfileField(&g_ai_profiles[idx], .model), model))
            {
                return idx;
            }
        }
    }

    return null;
}

fn openAiForm() void {
    g_ssh_list_visible = false;
    g_ssh_form_visible = false;
    g_ai_list_visible = false;
    g_session_launcher_visible = false;
    g_settings_visible = false;
    g_ai_form_visible = true;
    g_ai_focus = @intFromEnum(AiField.name);
}

fn setAiDefault(field: AiField, value: []const u8) void {
    const idx: usize = @intFromEnum(field);
    const len = @min(value.len, AI_FIELD_MAX);
    @memcpy(g_ai_bufs[idx][0..len], value[0..len]);
    g_ai_lens[idx] = len;
}

const setProfileDefault = profile_codec.setProfileDefault;

fn clearAiForm() void {
    g_ai_lens = .{0} ** AI_FIELD_COUNT;
    setAiDefault(.name, AppWindow.ai_chat.DEFAULT_NAME);
    setAiDefault(.base_url, AppWindow.ai_chat.DEFAULT_BASE_URL);
    setAiDefault(.model, AppWindow.ai_chat.DEFAULT_MODEL);
    setAiDefault(.system_prompt, AppWindow.ai_chat.DEFAULT_SYSTEM_PROMPT);
    setAiDefault(.thinking, AppWindow.ai_chat.DEFAULT_THINKING);
    setAiDefault(.reasoning_effort, AppWindow.ai_chat.DEFAULT_REASONING_EFFORT);
    setAiDefault(.stream, AppWindow.ai_chat.DEFAULT_STREAM);
    setAiDefault(.agent, AppWindow.ai_chat.DEFAULT_AGENT);
    setAiDefault(.protocol, AppWindow.ai_chat.DEFAULT_PROTOCOL);
    setAiDefault(.max_tokens, AppWindow.ai_chat.DEFAULT_MAX_TOKENS);
    setAiDefault(.vision, AppWindow.ai_chat.DEFAULT_VISION);
}

fn appendAiFormCodepoint(field: usize, codepoint: u21) void {
    if (field >= AI_FIELD_COUNT) return;
    // Protocol and Vision are ←/→ toggles, not free-text fields.
    if (field == @intFromEnum(AiField.protocol)) return;
    if (field == @intFromEnum(AiField.vision)) return;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return;
    if (g_ai_lens[field] + len > AI_FIELD_MAX) return;
    @memcpy(g_ai_bufs[field][g_ai_lens[field]..][0..len], buf[0..len]);
    g_ai_lens[field] += len;
}

fn appendAiFormText(field: usize, text: []const u8) void {
    if (field >= AI_FIELD_COUNT) return;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        if (codepoint >= 0x20 and codepoint != 0x7f) {
            appendAiFormCodepoint(field, codepoint);
        }
        i += len;
    }
}

fn appendSshFormText(field: usize, text: []const u8) void {
    if (field >= SSH_FIELD_COUNT) return;
    for (text) |ch| {
        if (ch < 0x20 or ch >= 0x7f) continue;
        if (g_ssh_lens[field] >= SSH_FIELD_MAX) return;
        g_ssh_bufs[field][g_ssh_lens[field]] = ch;
        g_ssh_lens[field] += 1;
    }
}

fn backspaceAiFormField(field: usize) void {
    if (field >= AI_FIELD_COUNT or g_ai_lens[field] == 0) return;
    // Protocol and Vision are toggle fields; they are not text-editable.
    if (field == @intFromEnum(AiField.protocol)) return;
    if (field == @intFromEnum(AiField.vision)) return;
    g_ai_lens[field] -= 1;
    while (g_ai_lens[field] > 0 and (g_ai_bufs[field][g_ai_lens[field]] & 0xC0) == 0x80) {
        g_ai_lens[field] -= 1;
    }
}

/// Cycle the Protocol form field to the next/previous valid protocol. The field
/// is constrained to valid values (chat_completions / responses / anthropic),
/// so users toggle with ←/→ instead of typing an arbitrary string.
fn cycleAiFormProtocol(forward: bool) void {
    const idx = @intFromEnum(AiField.protocol);
    const current = AppWindow.ai_chat.ApiProtocol.parse(g_ai_bufs[idx][0..g_ai_lens[idx]]);
    setAiDefault(.protocol, current.cycle(forward).name());
}

/// Protocol row display: the current protocol name plus a small ASCII toggle
/// affordance (←/→ switches between the three valid protocols).
fn aiProtocolDisplay() []const u8 {
    const S = struct {
        threadlocal var buf: [48]u8 = undefined;
    };
    const p = AppWindow.ai_chat.ApiProtocol.parse(aiField(.protocol));
    return std.fmt.bufPrint(&S.buf, "{s}   <-/->", .{p.name()}) catch p.name();
}

/// Vision is an on/off ←/→ toggle (default off). Models with vision enabled can
/// receive images pasted into the chat composer with Ctrl+Shift+V.
fn toggleAiFormVision() void {
    const on = AppWindow.ai_chat.parseVisionEnabled(aiField(.vision));
    setAiDefault(.vision, if (on) "off" else "on");
}

/// Vision row display: on/off plus the ←/→ toggle affordance.
fn aiVisionDisplay() []const u8 {
    const S = struct {
        threadlocal var buf: [32]u8 = undefined;
    };
    const on = AppWindow.ai_chat.parseVisionEnabled(aiField(.vision));
    return std.fmt.bufPrint(&S.buf, "{s}   <-/->", .{if (on) "on" else "off"}) catch (if (on) "on" else "off");
}

fn handleAiListKey(ev: input_key.KeyEvent) void {
    const row_count = aiListRowCount();
    switch (ev.key) {
        .arrow_down, .tab => g_ai_list_selected = (g_ai_list_selected + 1) % row_count,
        .arrow_up => g_ai_list_selected = if (g_ai_list_selected == 0) row_count - 1 else g_ai_list_selected - 1,
        .enter => runAiListRow(g_ai_list_selected),
        else => {},
    }
}

fn aiListRowCount() usize {
    return switch (g_ai_list_mode) {
        .manage => g_ai_profile_count + 4,
        .edit_select, .delete_select, .switch_model => g_ai_profile_count + 1,
    };
}

fn aiField(field: AiField) []const u8 {
    const idx: usize = @intFromEnum(field);
    return g_ai_bufs[idx][0..g_ai_lens[idx]];
}

const aiProfileField = profile_codec.aiProfileField;

fn runAiListRow(row: usize) void {
    switch (g_ai_list_mode) {
        .manage => {
            if (row < g_ai_profile_count) {
                connectAiProfile(row);
                return;
            }
            const action_row = row - g_ai_profile_count;
            switch (action_row) {
                0 => openAiFormNew(),
                1 => openAiEditPicker(),
                2 => openAiDeletePicker(),
                else => sessionLauncherClose(),
            }
        },
        .edit_select => {
            if (row < g_ai_profile_count) {
                openAiFormEdit(row);
            } else {
                openAiList();
            }
        },
        .delete_select => {
            if (row < g_ai_profile_count) {
                deleteAiProfile(row);
                openAiList();
            } else {
                openAiList();
            }
        },
        .switch_model => {
            if (row < g_ai_profile_count) {
                if (g_switch_model_target) |session| _ = applyProfileToSession(session, row);
            }
            g_switch_model_target = null;
            sessionLauncherClose();
        },
    }
}

fn deleteAiProfile(idx: usize) void {
    if (g_ai_profile_count == 0) return;
    if (idx >= g_ai_profile_count) return;
    const deleted_is_default = std.mem.eql(u8, aiProfileField(&g_ai_profiles[idx], .name), aiDefaultProfileName());
    var i = idx;
    while (i + 1 < g_ai_profile_count) : (i += 1) {
        g_ai_profiles[i] = g_ai_profiles[i + 1];
    }
    g_ai_profile_count -= 1;
    g_ai_list_selected = @min(g_ai_list_selected, aiListRowCount() - 1);
    if (deleted_is_default) {
        if (AppWindow.g_allocator) |allocator| Config.removeConfigKeys(allocator, &.{"ai-default-profile"}) catch {};
        invalidateAiDefaultName();
    }
    if (AppWindow.g_allocator) |allocator| saveAiProfiles(allocator);
}

fn connectAiFromForm() void {
    const idx = saveAiFormProfile() orelse return;
    connectAiProfile(idx);
}

fn saveAiFormOnly() void {
    _ = saveAiFormProfile() orelse return;
    sessionLauncherClose();
}

fn cancelAiFormOrLauncher() void {
    sessionLauncherBackOrClose();
}

fn runAiFormFocusAction() void {
    if (g_ai_focus < AI_FIELD_COUNT) {
        g_ai_focus = (g_ai_focus + 1) % (AI_FIELD_COUNT + 3);
        return;
    }
    switch (g_ai_focus - AI_FIELD_COUNT) {
        0 => connectAiFromForm(),
        1 => saveAiFormOnly(),
        else => cancelAiFormOrLauncher(),
    }
}

fn saveAiFormProfile() ?usize {
    const allocator = AppWindow.g_allocator orelse return null;
    const base_url = aiField(.base_url);
    const model = aiField(.model);
    if (base_url.len == 0 or model.len == 0) return null;
    if (!isHttpUrlish(base_url)) return null;

    const editing_existing = g_ai_edit_index != AI_PROFILE_NONE;
    const idx = if (editing_existing)
        g_ai_edit_index
    else blk: {
        if (g_ai_profile_count >= AI_PROFILE_MAX) return null;
        const next = g_ai_profile_count;
        g_ai_profile_count += 1;
        break :blk next;
    };

    // Capture the pre-edit name so a rename of the current default profile
    // can keep `ai-default-profile` pointing at it instead of falling back
    // to the first profile.
    var old_name_buf: [256]u8 = undefined;
    var old_name_len: usize = 0;
    if (editing_existing) {
        const old_name = aiProfileField(&g_ai_profiles[idx], .name);
        old_name_len = @min(old_name.len, old_name_buf.len);
        @memcpy(old_name_buf[0..old_name_len], old_name[0..old_name_len]);
    }

    for (0..AI_FIELD_COUNT) |i| {
        g_ai_profiles[idx].lens[i] = g_ai_lens[i];
        @memcpy(g_ai_profiles[idx].fields[i][0..g_ai_lens[i]], g_ai_bufs[i][0..g_ai_lens[i]]);
    }
    if (g_ai_profiles[idx].lens[@intFromEnum(AiField.name)] == 0) {
        const len = @min(model.len, AI_FIELD_MAX);
        @memcpy(g_ai_profiles[idx].fields[@intFromEnum(AiField.name)][0..len], model[0..len]);
        g_ai_profiles[idx].lens[@intFromEnum(AiField.name)] = len;
    }

    if (editing_existing and old_name_len > 0) {
        const old_name = old_name_buf[0..old_name_len];
        const new_name = aiProfileField(&g_ai_profiles[idx], .name);
        if (!std.mem.eql(u8, old_name, new_name) and std.mem.eql(u8, old_name, aiDefaultProfileName())) {
            Config.setConfigValue(allocator, "ai-default-profile", new_name) catch {};
            invalidateAiDefaultName();
        }
    }

    saveAiProfiles(allocator);
    g_ai_edit_index = idx;
    return idx;
}

fn connectAiProfile(idx: usize) void {
    connectAiProfileWithAgentOverride(idx, null);
}

fn connectAiProfileWithAgentOverride(idx: usize, agent_override: ?[]const u8) void {
    _ = spawnAiProfileWithAgentOverride(idx, agent_override);
}

fn spawnAiProfileWithAgentOverride(idx: usize, agent_override: ?[]const u8) bool {
    if (idx >= g_ai_profile_count) return false;
    const profile = &g_ai_profiles[idx];
    const name = aiProfileField(profile, .name);
    const base_url = aiProfileField(profile, .base_url);
    const api_key = aiProfileField(profile, .api_key);
    const model = aiProfileField(profile, .model);
    const system_prompt = aiProfileField(profile, .system_prompt);
    const thinking = aiProfileField(profile, .thinking);
    const reasoning_effort = aiProfileField(profile, .reasoning_effort);
    const stream_val = aiProfileField(profile, .stream);
    const agent_val = agent_override orelse aiProfileField(profile, .agent);
    const protocol = aiProfileField(profile, .protocol);
    const max_tokens = std.fmt.parseInt(u32, std.mem.trim(u8, aiProfileField(profile, .max_tokens), " \t"), 10) catch 8192;
    const vision_val = aiProfileField(profile, .vision);
    if (base_url.len == 0 or model.len == 0) return false;
    if (!isHttpUrlish(base_url)) return false;

    sessionLauncherClose();
    return AppWindow.spawnAiChatTab(name, base_url, api_key, model, protocol, system_prompt, thinking, reasoning_effort, stream_val, agent_val, max_tokens, vision_val);
}

/// Apply profile `idx` to the given live session in place (provider/model only)
/// and kick off the background summary. Returns false on an invalid profile.
fn applyProfileToSession(session: *AppWindow.ai_chat.Session, idx: usize) bool {
    if (idx >= g_ai_profile_count) return false;
    const profile = &g_ai_profiles[idx];
    const base_url = aiProfileField(profile, .base_url);
    const api_key = aiProfileField(profile, .api_key);
    const model = aiProfileField(profile, .model);
    const thinking = aiProfileField(profile, .thinking);
    const reasoning_effort = aiProfileField(profile, .reasoning_effort);
    const protocol = aiProfileField(profile, .protocol);
    const max_tokens = std.fmt.parseInt(u32, std.mem.trim(u8, aiProfileField(profile, .max_tokens), " \t"), 10) catch 8192;
    const vision_val = aiProfileField(profile, .vision);
    if (base_url.len == 0 or model.len == 0) return false;
    if (!isHttpUrlish(base_url)) return false;
    ai_chat.applyProviderProfile(session, base_url, api_key, model, protocol, thinking, reasoning_effort, max_tokens, vision_val);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    return true;
}

pub fn switchSessionModelByProfileName(session: *AppWindow.ai_chat.Session, profile_name: []const u8) ModelProfileSwitchResult {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return .no_profile;
    var names: [AI_PROFILE_MAX][]const u8 = undefined;
    for (0..g_ai_profile_count) |i| names[i] = aiProfileField(&g_ai_profiles[i], .name);
    const idx = ai_model_switch.matchProfileByName(names[0..g_ai_profile_count], profile_name) orelse return .unknown_profile;
    return if (applyProfileToSession(session, idx)) .switched else .failed;
}

/// Open the profile picker in switch-model mode, bound to `session`.
pub fn openSwitchModelPicker(session: *AppWindow.ai_chat.Session) void {
    loadAiProfiles();
    if (g_ai_profile_count == 0) {
        session.appendLocalToolMessage(i18n.s().ai_model_no_profiles);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    g_switch_model_target = session;
    openAiList(); // sets visibility flags + mode .manage
    g_ai_list_mode = .switch_model;
    g_ai_list_selected = @min(g_ai_list_selected, aiListRowCount() - 1);
}

/// `/model <name>`: match by name and apply directly; on no match, note the
/// available profiles in the transcript and fall back to opening the picker.
pub fn switchModelByName(session: *AppWindow.ai_chat.Session, name: []const u8) void {
    switch (switchSessionModelByProfileName(session, name)) {
        .switched => return,
        .no_profile, .unknown_profile, .failed => {
            session.appendLocalToolMessage(i18n.s().ai_model_unknown_profile);
            openSwitchModelPicker(session);
        },
    }
}

/// Build a standalone copilot Session from the default AI profile (Issue #98).
/// Mirrors spawnAiProfileWithAgentOverride's profile reading but returns a
/// Session with copilot mode + the copilot system prompt, instead of a tab.
pub fn makeCopilotSessionForDefaultProfile() ?*ai_chat.Session {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return null;
    const idx = defaultAiProfileIndex();
    if (idx >= g_ai_profile_count) return null;
    const profile = &g_ai_profiles[idx];
    const base_url = aiProfileField(profile, .base_url);
    const api_key = aiProfileField(profile, .api_key);
    const model = aiProfileField(profile, .model);
    const thinking = aiProfileField(profile, .thinking);
    const reasoning_effort = aiProfileField(profile, .reasoning_effort);
    const stream_val = aiProfileField(profile, .stream);
    const protocol = aiProfileField(profile, .protocol);
    const max_tokens = std.fmt.parseInt(u32, std.mem.trim(u8, aiProfileField(profile, .max_tokens), " \t"), 10) catch 8192;
    const vision_val = aiProfileField(profile, .vision);
    if (base_url.len == 0 or model.len == 0) return null;
    if (!isHttpUrlish(base_url)) return null;
    const allocator = AppWindow.g_allocator orelse return null;
    const session = ai_chat.Session.initWithVision(
        allocator,
        "Copilot",
        base_url,
        api_key,
        model,
        protocol,
        ai_chat.COPILOT_SYSTEM_PROMPT,
        thinking,
        reasoning_effort,
        stream_val,
        "true", // agent_enabled
        vision_val,
    ) catch return null;
    session.max_tokens = max_tokens;
    session.copilot = true;
    return session;
}

pub const DefaultAiProfileSnapshot = struct {
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    protocol: ai_chat.ApiProtocol,
    thinking_enabled: bool,
    reasoning_effort: []u8,
    max_tokens: u32,

    pub fn deinit(self: *DefaultAiProfileSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.reasoning_effort);
        self.* = undefined;
    }
};

pub fn defaultAiProfileSnapshot(allocator: std.mem.Allocator) ?DefaultAiProfileSnapshot {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return null;
    const idx = defaultAiProfileIndex();
    if (idx >= g_ai_profile_count) return null;
    const profile = &g_ai_profiles[idx];
    const base_url = aiProfileField(profile, .base_url);
    const api_key = aiProfileField(profile, .api_key);
    const model = aiProfileField(profile, .model);
    const thinking = aiProfileField(profile, .thinking);
    const reasoning_effort = aiProfileField(profile, .reasoning_effort);
    const protocol = aiProfileField(profile, .protocol);
    const max_tokens = std.fmt.parseInt(u32, std.mem.trim(u8, aiProfileField(profile, .max_tokens), " \t"), 10) catch 8192;
    if (base_url.len == 0 or model.len == 0) return null;
    if (!isHttpUrlish(base_url)) return null;

    const base_url_copy = allocator.dupe(u8, base_url) catch return null;
    const api_key_copy = allocator.dupe(u8, api_key) catch {
        allocator.free(base_url_copy);
        return null;
    };
    const model_copy = allocator.dupe(u8, model) catch {
        allocator.free(base_url_copy);
        allocator.free(api_key_copy);
        return null;
    };
    const reasoning_copy = allocator.dupe(u8, reasoning_effort) catch {
        allocator.free(base_url_copy);
        allocator.free(api_key_copy);
        allocator.free(model_copy);
        return null;
    };
    return .{
        .base_url = base_url_copy,
        .api_key = api_key_copy,
        .model = model_copy,
        .protocol = defaultAiProfileSnapshotProtocol(base_url, protocol),
        .thinking_enabled = !std.mem.eql(u8, thinking, "disabled"),
        .reasoning_effort = reasoning_copy,
        .max_tokens = max_tokens,
    };
}

fn defaultAiProfileSnapshotProtocol(base_url: []const u8, protocol: []const u8) ai_chat.ApiProtocol {
    var parsed = ai_chat.ApiProtocol.parse(protocol);
    if (parsed == .chat_completions and ai_chat_protocol.isAnthropicBaseUrl(base_url)) {
        parsed = .anthropic;
    }
    return parsed;
}

test "default AI profile snapshot normalizes Anthropic URL with default protocol" {
    try std.testing.expectEqual(
        ai_chat.ApiProtocol.anthropic,
        defaultAiProfileSnapshotProtocol("https://api.anthropic.com", ""),
    );
}

threadlocal var g_ai_default_name_buf: [256]u8 = undefined;
threadlocal var g_ai_default_name_len: usize = 0;
threadlocal var g_ai_default_loaded: bool = false;

/// Cached value of the `ai-default-profile` config key. Cached to avoid file
/// IO on every render frame; invalidated on in-app writes.
fn aiDefaultProfileName() []const u8 {
    if (!g_ai_default_loaded) {
        g_ai_default_loaded = true;
        g_ai_default_name_len = 0;
        const allocator = AppWindow.g_allocator orelse return "";
        var cfg = Config.load(allocator) catch return "";
        defer cfg.deinit(allocator);
        const name = cfg.@"ai-default-profile";
        const len = @min(name.len, g_ai_default_name_buf.len);
        @memcpy(g_ai_default_name_buf[0..len], name[0..len]);
        g_ai_default_name_len = len;
    }
    return g_ai_default_name_buf[0..g_ai_default_name_len];
}

fn invalidateAiDefaultName() void {
    g_ai_default_loaded = false;
}

threadlocal var g_subagent_profile_name_buf: [256]u8 = undefined;
threadlocal var g_subagent_profile_name_len: usize = 0;

/// Cache of the `ai-subagent-profile` config key, pushed by the app layer at
/// startup and on config reload (no file IO on the resolve path).
pub fn setSubagentProfileName(name: []const u8) void {
    const len = @min(name.len, g_subagent_profile_name_buf.len);
    @memcpy(g_subagent_profile_name_buf[0..len], name[0..len]);
    g_subagent_profile_name_len = len;
}

/// ai_chat.SubagentProfileResolver: map the configured profile name to owned
/// credentials. Any miss (unset key, unknown name, invalid profile) returns
/// null — the subagent then falls back to the main conversation's profile.
pub fn resolveSubagentProfileOverride(allocator: std.mem.Allocator) ?ai_chat.SubagentProfileOverride {
    const name = g_subagent_profile_name_buf[0..g_subagent_profile_name_len];
    if (name.len == 0) return null;
    loadAiProfiles();
    var found: ?usize = null;
    for (0..g_ai_profile_count) |i| {
        if (std.mem.eql(u8, aiProfileField(&g_ai_profiles[i], .name), name)) {
            found = i;
            break;
        }
    }
    const idx = found orelse return null;
    const profile = &g_ai_profiles[idx];
    const base_url = aiProfileField(profile, .base_url);
    const model = aiProfileField(profile, .model);
    if (base_url.len == 0 or model.len == 0) return null;
    if (!isHttpUrlish(base_url)) return null;

    const base_url_copy = allocator.dupe(u8, base_url) catch return null;
    const api_key_copy = allocator.dupe(u8, aiProfileField(profile, .api_key)) catch {
        allocator.free(base_url_copy);
        return null;
    };
    const model_copy = allocator.dupe(u8, model) catch {
        allocator.free(base_url_copy);
        allocator.free(api_key_copy);
        return null;
    };
    const reasoning_copy = allocator.dupe(u8, aiProfileField(profile, .reasoning_effort)) catch {
        allocator.free(base_url_copy);
        allocator.free(api_key_copy);
        allocator.free(model_copy);
        return null;
    };
    return .{
        .base_url = base_url_copy,
        .api_key = api_key_copy,
        .model = model_copy,
        .protocol = ai_chat.ApiProtocol.parse(aiProfileField(profile, .protocol)),
        .thinking_enabled = !std.mem.eql(u8, aiProfileField(profile, .thinking), "disabled"),
        .reasoning_effort = reasoning_copy,
        .max_tokens = std.fmt.parseInt(u32, std.mem.trim(u8, aiProfileField(profile, .max_tokens), " \t"), 10) catch 8192,
    };
}

/// Index of the default AI profile, resolved by name from config. Falls back
/// to the first profile. Returns 0 when no profiles exist (callers guard).
fn defaultAiProfileIndex() usize {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return 0;
    var names: [AI_PROFILE_MAX][]const u8 = undefined;
    for (0..g_ai_profile_count) |i| {
        names[i] = aiProfileField(&g_ai_profiles[i], .name);
    }
    return command_palette_model.resolveDefaultIndex(names[0..g_ai_profile_count], aiDefaultProfileName());
}

/// Name of the profile `delta` positions from the current default, wrapping in
/// both directions (+1 for next, -1 for previous). Empty when no profiles exist.
fn cycledDefaultAiProfileName(delta: i64) []const u8 {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return "";
    const idx = command_palette_model.cycleIndex(defaultAiProfileIndex(), g_ai_profile_count, delta);
    return aiProfileField(&g_ai_profiles[idx], .name);
}

/// Persist the default AI profile `delta` positions from the current one
/// (+1 next, -1 previous). No-op when no profiles exist.
fn cycleDefaultAiProfile(delta: i64) void {
    const allocator = AppWindow.g_allocator orelse return;
    loadAiProfiles();
    if (g_ai_profile_count == 0) return;
    const next_name = cycledDefaultAiProfileName(delta);
    Config.setConfigValue(allocator, "ai-default-profile", next_name) catch {};
    invalidateAiDefaultName();
}

fn isHttpUrlish(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://");
}

fn aiProfilesPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.aiProfilesPath(allocator);
}

fn loadAiProfiles() void {
    if (g_ai_profiles_loaded) return;
    g_ai_profiles_loaded = true;
    g_ai_profile_count = 0;
    const allocator = AppWindow.g_allocator orelse return;
    const path = aiProfilesPath(allocator) catch return;
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        if (g_ai_profile_count >= AI_PROFILE_MAX) break;
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const profile = decodeAiProfileLine(line) orelse continue;
        g_ai_profiles[g_ai_profile_count] = profile;
        g_ai_profile_count += 1;
    }
}

/// Decode one tab-separated, hex-encoded AI profile line into an `AiProfile`,
/// then fill defaults for any empty optional field. Returns null when a present
/// field contains malformed hex or fewer than five fields are present. Trailing
/// fields absent from the line (e.g. `protocol`/`max_tokens` from older builds)
/// are defaulted rather than misaligned, so profiles written before the schema
/// grew still load correctly.
const decodeAiProfileLine = profile_codec.decodeAiProfileLine;

fn saveAiProfiles(allocator: std.mem.Allocator) void {
    const path = aiProfilesPath(allocator) catch return;
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, "# WispTerm AI Chat profiles. Fields are hex encoded: name, base_url, api_key, model, system_prompt, thinking, reasoning_effort, stream, agent, protocol, max_tokens, vision.\n") catch return;
    for (g_ai_profiles[0..g_ai_profile_count]) |profile| {
        for (0..AI_FIELD_COUNT) |i| {
            if (i > 0) out.append(allocator, '\t') catch return;
            appendHexField(allocator, &out, profile.fields[i][0..profile.lens[i]]) catch return;
        }
        out.append(allocator, '\n') catch return;
    }

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer file.close();
    file.writeAll(out.items) catch {};
}

fn sshProfilesPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.sshHostsPath(allocator);
}

fn loadSshProfiles() void {
    if (g_ssh_profiles_loaded) return;
    g_ssh_profiles_loaded = true;
    g_ssh_profile_count = 0;
    const allocator = AppWindow.g_allocator orelse return;
    const path = sshProfilesPath(allocator) catch return;
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        if (g_ssh_profile_count >= SSH_PROFILE_MAX) break;
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const profile = decodeSshProfileLine(line) orelse continue;
        g_ssh_profiles[g_ssh_profile_count] = profile;
        g_ssh_profile_count += 1;
    }
}

const decodeSshProfileLine = profile_codec.decodeSshProfileLine;

fn saveSshProfiles(allocator: std.mem.Allocator) void {
    _ = saveSshProfilesChecked(allocator);
}

fn saveSshProfilesChecked(allocator: std.mem.Allocator) bool {
    const path = sshProfilesPath(allocator) catch return false;
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return false;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, "# WispTerm SSH profiles. Fields are hex encoded: name, host, user, password, port, proxy_jump, auth_method, identity_file.\n") catch return false;
    for (g_ssh_profiles[0..g_ssh_profile_count]) |profile| {
        for (0..SSH_FIELD_COUNT) |i| {
            if (i > 0) out.append(allocator, '\t') catch return false;
            appendHexField(allocator, &out, profile.fields[i][0..profile.lens[i]]) catch return false;
        }
        out.append(allocator, '\n') catch return false;
    }

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return false;
    defer file.close();
    file.writeAll(out.items) catch return false;
    return true;
}

fn loadOpenSshConfigDefault() void {
    const allocator = AppWindow.g_allocator orelse return;
    loadSshProfiles();

    const path = platform_dirs.openSshConfigPath(allocator) catch {
        openSshList();
        showStatusToast("OpenSSH config not found");
        return;
    };
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
        openSshList();
        showStatusToast("OpenSSH config not found");
        return;
    };
    defer allocator.free(content);

    var candidates_buf: [64]openssh_config_import.Candidate = undefined;
    const candidates = openssh_config_import.parseCandidates(content, &candidates_buf);
    var stats = OpenSshImportStats{};
    for (candidates) |candidate| mergeOpenSshCandidate(candidate, &stats);

    var saved = true;
    if (stats.created + stats.updated > 0) {
        saved = saveSshProfilesChecked(allocator);
    }
    openSshList();

    var msg_buf: [96]u8 = undefined;
    const msg = if (stats.created + stats.updated == 0)
        "No OpenSSH hosts imported"
    else if (!saved)
        std.fmt.bufPrint(&msg_buf, "Imported {d}, updated {d} SSH profiles (not saved)", .{ stats.created, stats.updated }) catch "Imported OpenSSH profiles (not saved)"
    else
        std.fmt.bufPrint(&msg_buf, "Imported {d}, updated {d} SSH profiles", .{ stats.created, stats.updated }) catch "Imported OpenSSH profiles";
    showStatusToast(msg);
}

fn appendHexField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

const decodeHexField = profile_codec.decodeHexField;
const decodeHexFieldToSlice = profile_codec.decodeHexFieldToSlice;
const hexValue = profile_codec.hexValue;

fn sessionTwoColumnWidth(left: []const u8, right: []const u8) f32 {
    const right_w = if (right.len > 0) measureTitlebarText(right) + 36.0 else 0.0;
    return measureTitlebarText(left) + right_w + 80.0;
}

fn sessionLauncherTitle() []const u8 {
    if (g_ai_history_source_visible) return i18n.s().sl_sessions;
    if (g_ai_form_visible) {
        return i18n.s().sl_ai_agent;
    }
    if (g_ai_list_visible) {
        return switch (g_ai_list_mode) {
            .manage => i18n.s().sl_llm_providers,
            .edit_select => i18n.s().sl_edit_llm_provider,
            .delete_select => i18n.s().sl_delete_llm_provider,
            .switch_model => i18n.s().sl_switch_model_title,
        };
    }
    if (g_ssh_form_visible) return i18n.s().sl_ssh_server;
    if (g_ssh_list_visible) {
        return switch (g_ssh_list_mode) {
            .manage => i18n.s().sl_ssh_servers,
            .edit_select => i18n.s().sl_edit_ssh_server,
            .delete_select => i18n.s().sl_delete_ssh_server,
            .ai_history_select => "Sessions SSH Profile",
            .tmux_connect => "tmux SSH Profile",
        };
    }
    return i18n.s().sl_new_session;
}

fn sessionLauncherHint() []const u8 {
    if (g_ai_history_source_visible) return "Choose a source";
    if (g_ai_form_visible) {
        return i18n.s().sl_hint_ai_form;
    }
    if (g_ai_list_visible) {
        return switch (g_ai_list_mode) {
            .manage => i18n.s().sl_hint_ai_manage,
            .edit_select => i18n.s().sl_hint_choose_profile_edit,
            .delete_select => i18n.s().sl_hint_choose_profile_delete,
            .switch_model => i18n.s().sl_switch_model_hint,
        };
    }
    if (g_ssh_form_visible) return i18n.s().sl_hint_ssh_form;
    if (g_ssh_list_visible) {
        const has_filter = g_ssh_list_filter_len > 0;
        return switch (g_ssh_list_mode) {
            .manage => if (has_filter) i18n.s().sl_hint_ssh_filter_edits else i18n.s().sl_hint_ssh_filter_manage,
            .edit_select => if (has_filter) i18n.s().sl_hint_ssh_filter_choose_edit else i18n.s().sl_hint_choose_server_edit,
            .delete_select => if (has_filter) i18n.s().sl_hint_ssh_filter_choose_delete else i18n.s().sl_hint_choose_server_delete,
            .ai_history_select => if (has_filter) "Filter profiles" else "Choose a profile or go back",
            .tmux_connect => if (has_filter) "Filter profiles" else "Choose a profile or go back",
        };
    }
    return i18n.s().sl_hint_main;
}

fn sessionDesiredBoxWidth() f32 {
    const title = sessionLauncherTitle();
    const hint = sessionLauncherHint();
    var desired = @max(measureTitlebarText(title), measureTitlebarText(hint)) + 48.0;

    if (g_ai_form_visible) {
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_profile_name, aiField(.name)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_base_url, aiField(.base_url)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_api_key, aiField(.api_key)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_model, aiField(.model)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_system, aiField(.system_prompt)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_thinking, aiField(.thinking)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_effort, aiField(.reasoning_effort)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_stream, aiField(.stream)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_protocol, aiProtocolDisplay()));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_max_tokens, aiField(.max_tokens)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_vision, aiVisionDisplay()));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_save_open, i18n.s().sl_v_agent));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_save, i18n.s().sl_v_profile));
        desired = @max(desired, sessionTwoColumnWidth(sessionLauncherCancelLabel(), "Esc"));
        return desired;
    }

    if (g_ssh_form_visible) {
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ssh_server_name, sshField(.name)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ssh_ip_host, sshField(.ip)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ssh_user, sshField(.user)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ssh_password, sshField(.password)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ssh_port, sshField(.port)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ssh_jump_host, sshField(.proxy_jump)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ssh_auth_method, sshField(.auth_method)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ssh_identity_file, sshField(.identity_file)));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_save_connect, platform_pty_command.sshLauncherDetail()));
        desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_save, i18n.s().sl_v_profile));
        desired = @max(desired, sessionTwoColumnWidth(sessionLauncherCancelLabel(), "Esc"));
        return desired;
    }

    if (g_ai_list_visible) {
        var row: usize = 0;
        while (row < g_ai_profile_count) : (row += 1) {
            var detail_buf: [AI_FIELD_MAX]u8 = undefined;
            const profile = &g_ai_profiles[row];
            const model = aiProfileField(profile, .model);
            const base_url = aiProfileField(profile, .base_url);
            const detail = if (model.len > 0)
                model
            else
                std.fmt.bufPrint(&detail_buf, "{s}", .{base_url}) catch "";
            desired = @max(desired, sessionTwoColumnWidth(aiProfileField(profile, .name), detail));
        }
        switch (g_ai_list_mode) {
            .manage => {
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_new_llm_provider, i18n.s().sl_v_add));
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_edit_llm_provider, if (g_ai_profile_count > 0) i18n.s().sl_v_choose else i18n.s().sl_v_no_profile));
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_delete_llm_provider, if (g_ai_profile_count > 0) i18n.s().sl_v_choose else i18n.s().sl_v_no_profile));
                desired = @max(desired, sessionTwoColumnWidth(sessionLauncherCancelLabel(), "Esc"));
            },
            .edit_select, .delete_select, .switch_model => {
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_back, i18n.s().sl_v_manage));
            },
        }
        return desired;
    }

    if (g_ssh_list_visible) {
        var profile_idx: usize = 0;
        while (profile_idx < g_ssh_profile_count) : (profile_idx += 1) {
            var target_buf: [SSH_FIELD_MAX * 2]u8 = undefined;
            const profile = &g_ssh_profiles[profile_idx];
            if (!sshProfileMatchesFilter(profile)) continue;
            const host = profileField(profile, .ip);
            const user = profileField(profile, .user);
            const port = profileField(profile, .port);
            const target = if (port.len > 0)
                std.fmt.bufPrint(&target_buf, "{s}@{s}:{s}", .{ user, host, port }) catch ""
            else
                std.fmt.bufPrint(&target_buf, "{s}@{s}", .{ user, host }) catch "";
            desired = @max(desired, sessionTwoColumnWidth(profileField(profile, .name), target));
        }
        switch (g_ssh_list_mode) {
            .manage => {
                desired = @max(desired, sessionTwoColumnWidth("Load OpenSSH config", "~/.ssh/config"));
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_new_ssh_server, i18n.s().sl_v_add));
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_edit_ssh_server, if (g_ssh_profile_count > 0) i18n.s().sl_v_choose else i18n.s().sl_v_no_server));
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_delete_ssh_server, if (g_ssh_profile_count > 0) i18n.s().sl_v_choose else i18n.s().sl_v_no_server));
                desired = @max(desired, sessionTwoColumnWidth(sessionLauncherCancelLabel(), "Esc"));
            },
            .edit_select, .delete_select => {
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_back, i18n.s().sl_v_manage));
            },
            .ai_history_select => {
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_back, i18n.s().sl_sessions));
            },
            .tmux_connect => {
                desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_back, "tmux"));
            },
        }
        return desired;
    }

    if (g_ai_history_source_visible) {
        desired = @max(desired, sessionTwoColumnWidth("Local", "This computer"));
        if (platform_pty_command.sessionLauncherWslRow() != null) {
            desired = @max(desired, sessionTwoColumnWidth("WSL", "Default distro"));
        }
        desired = @max(desired, sessionTwoColumnWidth("SSH Profile...", "Choose server"));
        desired = @max(desired, sessionTwoColumnWidth(sessionLauncherCancelLabel(), "Esc"));
        return desired;
    }

    desired = @max(desired, sessionTwoColumnWidth(AppWindow.configuredLocalShellSessionTitle(), AppWindow.configuredLocalShellSessionDetail()));
    desired = @max(desired, sessionTwoColumnWidth("SSH", i18n.s().sl_v_connect_server));
    if (platform_pty_command.sessionLauncherWslRow() != null) {
        desired = @max(desired, sessionTwoColumnWidth("WSL", platform_pty_command.wslLauncherDetail()));
    }
    desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_ai_agent, defaultAiModeLabel()));
    desired = @max(desired, sessionTwoColumnWidth(i18n.s().sl_sessions, i18n.s().sl_sessions_detail));
    return desired;
}

/// Total rows in the currently active session-launcher mode.
fn sessionActiveRowCount() usize {
    return if (g_ai_form_visible)
        AI_FIELD_COUNT + 3
    else if (g_ai_list_visible)
        aiListRowCount()
    else if (g_ai_history_source_visible)
        aiHistorySourceRowCount()
    else if (g_ssh_form_visible)
        SSH_FIELD_COUNT + 3
    else if (g_ssh_list_visible)
        sshListRowCount()
    else
        platform_pty_command.sessionLauncherRowCount();
}

/// Selected/focused row of the currently active session-launcher mode.
fn sessionActiveSelection() usize {
    return if (g_ai_form_visible)
        g_ai_focus
    else if (g_ai_list_visible)
        g_ai_list_selected
    else if (g_ai_history_source_visible)
        g_ai_history_source_selected
    else if (g_ssh_form_visible)
        g_ssh_focus
    else if (g_ssh_list_visible)
        g_ssh_list_selected
    else
        g_session_launcher_selected;
}

/// Mutable pointer to the active mode's selection (for the mouse wheel).
fn sessionActiveSelectionPtr() *usize {
    return if (g_ai_form_visible)
        &g_ai_focus
    else if (g_ai_list_visible)
        &g_ai_list_selected
    else if (g_ai_history_source_visible)
        &g_ai_history_source_selected
    else if (g_ssh_form_visible)
        &g_ssh_focus
    else if (g_ssh_list_visible)
        &g_ssh_list_selected
    else
        &g_session_launcher_selected;
}

/// Rows that fit within the box for the given window height. Mirrors
/// commandPaletteRowCapacity().
fn sessionRowCapacity(content_height: f32, base_h: f32, row_h: f32, row_count: usize) usize {
    if (row_count == 0) return 0;
    const usable_h = @max(row_h, content_height - 32.0 - base_h);
    if (usable_h <= row_h) return 1;
    const fit: usize = @intFromFloat(@max(1.0, @floor(usable_h / row_h)));
    return @min(row_count, fit);
}

/// First row to render so the selected row stays visible. Mirrors
/// commandPaletteFirstVisibleIndex().
fn sessionFirstVisibleRow(selection: usize, visible_rows: usize, row_count: usize) usize {
    if (visible_rows == 0 or row_count <= visible_rows) return 0;
    const sel = @min(selection, row_count - 1);
    if (sel < visible_rows) return 0;
    return @min(sel - visible_rows + 1, row_count - visible_rows);
}

fn sessionLayout(window_width: f32, window_height: f32, top_offset: f32) SessionLayout {
    const content_height = @max(1, window_height - top_offset);
    const min_box_w: f32 = if (g_ssh_form_visible or g_ssh_list_visible or g_ai_form_visible or g_ai_list_visible) 460 else 360;
    const max_box_w = @max(260.0, @min(760.0, window_width - 48.0));
    const box_w: f32 = @round(@min(@max(min_box_w, sessionDesiredBoxWidth()), max_box_w));
    const row_h = overlayRowHeight(38);
    const header_h = @round(18 + overlayLineHeight() * 2 + 12);
    const bottom_pad = @round(@max(20.0, overlayTextHeight() * 0.55));
    const row_count = sessionActiveRowCount();
    const visible_rows = sessionRowCapacity(content_height, header_h + bottom_pad, row_h, row_count);
    const scroll = sessionFirstVisibleRow(sessionActiveSelection(), visible_rows, row_count);
    const box_h = @round(clampOverlayBoxHeight(header_h + row_h * @as(f32, @floatFromInt(visible_rows)) + bottom_pad, content_height));
    const box_x = @round(@max(16, (window_width - box_w) / 2));
    const box_top_px = @round(top_offset + @max(16, (content_height - box_h) / 2));
    return .{
        .box_x = box_x,
        .box_top_px = box_top_px,
        .box_w = box_w,
        .box_h = box_h,
        .header_h = header_h,
        .first_row_top_px = box_top_px + header_h,
        .row_h = row_h,
        .row_count = row_count,
        .visible_rows = visible_rows,
        .scroll = scroll,
    };
}

fn sessionHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) ?SessionAction {
    const layout = sessionLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    if (x < layout.box_x or x > layout.box_x + layout.box_w) return null;
    if (y < layout.first_row_top_px) return null;
    const visible_index: usize = @intFromFloat(@floor((y - layout.first_row_top_px) / layout.row_h));
    if (visible_index >= layout.visible_rows) return null;
    const row = visible_index + layout.scroll;

    if (g_ai_history_source_visible) {
        if (row >= aiHistorySourceRowCount()) return null;
        g_ai_history_source_selected = row;
        return switch (aiHistorySourceChoiceForRow(row) orelse return .cancel) {
            .local => .ai_history_local,
            .wsl => .ai_history_wsl,
            .ssh => .ai_history_ssh,
        };
    }

    if (g_ssh_list_visible) {
        if (row >= sshListRowCount()) return null;
        g_ssh_list_selected = row;
        if (row < sshVisibleProfileCount()) return .connect_selected;
        if (g_ssh_list_mode != .manage) return .connect_selected;
        return switch (sshManageActionForRow(row, sshVisibleProfileCount())) {
            .profile => .connect_selected,
            .load_openssh_config => .load_openssh_config,
            .new_ssh => .new_ssh,
            .edit_ssh => .edit_selected,
            .delete_ssh => .delete_selected,
            else => .cancel,
        };
    }

    if (g_ai_list_visible) {
        if (row >= aiListRowCount()) return null;
        g_ai_list_selected = row;
        if (row < g_ai_profile_count) return .connect_ai_selected;
        if (g_ai_list_mode != .manage) return .connect_ai_selected;
        return switch (row - g_ai_profile_count) {
            0 => .new_ai,
            1 => .edit_ai_selected,
            2 => .delete_ai_selected,
            else => .cancel,
        };
    }

    if (!g_ssh_form_visible and !g_ai_form_visible) {
        if (row >= platform_pty_command.sessionLauncherRowCount()) return null;
        g_session_launcher_selected = row;
        if (row == 0) return .local_shell;
        if (row == 1) return .ssh;
        if (row == command_center_state.SESSION_LAUNCHER_ROW_TMUX) return .tmux;
        if (platform_pty_command.sessionLauncherWslRow()) |wsl_row| {
            if (row == wsl_row) return .wsl;
        }
        if (row == platform_pty_command.sessionLauncherAiAgentRow()) return .ai_chat;
        if (row == platform_pty_command.sessionLauncherAiHistoryRow()) return .ai_history;
        return null;
    }

    if (g_ai_form_visible) {
        if (row < AI_FIELD_COUNT) {
            g_ai_focus = row;
            return null;
        }
        g_ai_focus = row;
        return switch (row) {
            AI_FIELD_COUNT => .connect_ai,
            AI_FIELD_COUNT + 1 => .save_ai,
            AI_FIELD_COUNT + 2 => .cancel,
            else => null,
        };
    }

    if (row < SSH_FIELD_COUNT) {
        g_ssh_focus = row;
        return null;
    }
    g_ssh_focus = row;
    return switch (row) {
        SSH_FIELD_COUNT => .connect,
        SSH_FIELD_COUNT + 1 => .save,
        SSH_FIELD_COUNT + 2 => .cancel,
        else => null,
    };
}

fn renderSessionRow(layout: SessionLayout, window_height: f32, row: usize, left: []const u8, right: []const u8, selected: bool) void {
    // Skip rows scrolled out of view above or below the visible window.
    if (row < layout.scroll) return;
    const visible_index = row - layout.scroll;
    if (visible_index >= layout.visible_rows) return;
    const row_top = @round(layout.first_row_top_px + @as(f32, @floatFromInt(visible_index)) * layout.row_h);
    const row_y = @round(window_height - row_top - layout.row_h);
    const x = layout.box_x + 18;
    const w = layout.box_w - 36;
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const row_color = if (selected) mixColor(bg, accent, 0.34) else mixColor(bg, fg, 0.055);
    ui_pipeline.fillQuadAlpha(x, row_y + 3, w, layout.row_h - 6, row_color, if (selected) 0.82 else 0.78);
    if (selected) ui_pipeline.fillQuadAlpha(x, row_y + 3, 3, layout.row_h - 6, accent, 0.86);
    const text_y = rowTextY(row_y, layout.row_h);
    const left_color = if (selected) mixColor(fg, accent, 0.12) else mixColor(bg, fg, 0.88);
    const left_x = x + 12;
    const right_edge = layout.box_x + layout.box_w - 34;
    if (right.len > 0) {
        const right_w = measureTitlebarText(right);
        const right_color = if (selected) mixColor(fg, accent, 0.08) else mixColor(bg, fg, 0.56);
        const right_max_w = @max(0.0, right_edge - left_x - 96);
        const right_draw_w = @min(right_w, right_max_w);
        const right_x = @round(right_edge - right_draw_w);
        renderTitlebarTextStrongLimited(left, left_x, text_y, left_color, right_x - left_x - 18);
        renderTitlebarTextStrongLimited(right, right_x, text_y, right_color, right_draw_w);
    } else {
        renderTitlebarTextStrongLimited(left, left_x, text_y, left_color, w - 24);
    }
}

fn renderSessionField(layout: SessionLayout, window_height: f32, row: usize, label: []const u8, value: []const u8, masked: bool) void {
    renderSessionFieldValue(layout, window_height, row, label, value, masked, g_ssh_focus == row);
}

fn renderAiSessionField(layout: SessionLayout, window_height: f32, row: usize, label: []const u8, value: []const u8, masked: bool) void {
    renderSessionFieldValue(layout, window_height, row, label, value, masked, g_ai_focus == row);
}

fn renderSessionFieldValue(layout: SessionLayout, window_height: f32, row: usize, label: []const u8, value: []const u8, masked: bool, selected: bool) void {
    var display_buf: [AI_FIELD_MAX]u8 = undefined;
    const display = if (masked) blk: {
        const len = @min(value.len, display_buf.len);
        @memset(display_buf[0..len], '*');
        break :blk display_buf[0..len];
    } else value;
    renderSessionRow(layout, window_height, row, label, display, selected);
}

fn renderSshProfileRow(layout: SessionLayout, window_height: f32, row: usize, profile: *const SshProfile, selected: bool) void {
    var target_buf: [SSH_FIELD_MAX * 2]u8 = undefined;
    const target = sshProfileTarget(profile, target_buf[0..]);
    renderSessionRow(layout, window_height, row, profileField(profile, .name), target, selected);
}

fn sshProfileTarget(profile: *const SshProfile, target_buf: []u8) []const u8 {
    const host = profileField(profile, .ip);
    const user = profileField(profile, .user);
    const port = profileField(profile, .port);
    return if (port.len > 0)
        std.fmt.bufPrint(target_buf, "{s}@{s}:{s}", .{ user, host, port }) catch host
    else
        std.fmt.bufPrint(target_buf, "{s}@{s}", .{ user, host }) catch host;
}

fn renderAiProfileRow(layout: SessionLayout, window_height: f32, row: usize, profile: *const AiProfile, selected: bool) void {
    const name = aiProfileField(profile, .name);
    const mode = aiProfileModeLabel(profile);
    var detail_buf: [48]u8 = undefined;
    const detail = if (row == defaultAiProfileIndex())
        (std.fmt.bufPrint(detail_buf[0..], "{s}{s}", .{ mode, i18n.s().sl_default_suffix }) catch mode)
    else
        mode;
    renderSessionRow(layout, window_height, row, name, detail, selected);
}

fn aiModeText(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "enabled")) return i18n.s().sl_ai_agent_field;
    return i18n.s().sl_mode_chat;
}

fn aiProfileModeLabel(profile: *const AiProfile) []const u8 {
    return aiModeText(aiProfileField(profile, .agent));
}

fn defaultAiModeLabel() []const u8 {
    loadAiProfiles();
    if (g_ai_profile_count > 0) return aiProfileModeLabel(&g_ai_profiles[defaultAiProfileIndex()]);
    return aiModeText(AppWindow.ai_chat.DEFAULT_AGENT);
}

pub fn renderSessionLauncher(window_width: f32, window_height: f32, top_offset: f32) void {
    if (!sessionLauncherVisible()) return;

    const layout = sessionLayout(window_width, window_height, top_offset);
    const box_y = @round(window_height - layout.box_top_px - layout.box_h);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_color = mixColor(bg, fg, 0.035);
    const border_color = mixColor(bg, accent, 0.24);
    const title_color = mixColor(fg, accent, 0.14);
    const muted_color = mixColor(bg, fg, 0.58);

    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.18);
    renderRoundedQuadAlpha(layout.box_x - 1, box_y - 1, layout.box_w + 2, layout.box_h + 2, 11, border_color, 0.24);
    renderRoundedQuadAlpha(layout.box_x, box_y, layout.box_w, layout.box_h, 10, panel_color, 0.96);

    // Scrollbar indicator when more rows exist than fit (short windows or long
    // lists). The list scrolls via keyboard/click selection-follow and the wheel.
    if (layout.row_count > layout.visible_rows and layout.visible_rows > 0) {
        const total_f: f32 = @floatFromInt(layout.row_count);
        const vis_f: f32 = @floatFromInt(layout.visible_rows);
        const track_h = layout.row_h * vis_f;
        const track_top_px = layout.first_row_top_px;
        const sb_w: f32 = 3;
        const sb_x = layout.box_x + layout.box_w - sb_w - 7;
        const track_gl_y = @round(window_height - track_top_px - track_h);
        ui_pipeline.fillQuadAlpha(sb_x, track_gl_y, sb_w, track_h, mixColor(bg, fg, 0.25), 0.30);

        const thumb_h = @max(24.0, @round(track_h * vis_f / total_f));
        const max_scroll_f: f32 = @floatFromInt(layout.row_count - layout.visible_rows);
        const scroll_f: f32 = @floatFromInt(layout.scroll);
        const thumb_offset = if (max_scroll_f > 0) @round((track_h - thumb_h) * (scroll_f / max_scroll_f)) else 0;
        const thumb_gl_y = @round(window_height - (track_top_px + thumb_offset) - thumb_h);
        ui_pipeline.fillQuadAlpha(sb_x, thumb_gl_y, sb_w, thumb_h, accent, 0.55);
    }

    const title = sessionLauncherTitle();
    const hint = sessionLauncherHint();
    const title_y = textYFromTop(window_height, layout.box_top_px + 18);
    const hint_y = textYFromTop(window_height, layout.box_top_px + 18 + overlayLineHeight());
    renderTitlebarTextStrong(title, layout.box_x + 24, title_y, title_color);
    renderTitlebarTextStrongLimited(hint, layout.box_x + 24, hint_y, muted_color, layout.box_w - 48);

    if (!g_ssh_form_visible and !g_ai_form_visible) {
        if (g_ai_history_source_visible) {
            var row: usize = 0;
            renderSessionRow(layout, window_height, row, "Local", "This computer", g_ai_history_source_selected == row);
            row += 1;
            if (platform_pty_command.sessionLauncherWslRow() != null) {
                renderSessionRow(layout, window_height, row, "WSL", "Default distro", g_ai_history_source_selected == row);
                row += 1;
            }
            renderSessionRow(layout, window_height, row, "SSH Profile...", "Choose server", g_ai_history_source_selected == row);
            row += 1;
            renderSessionRow(layout, window_height, row, sessionLauncherCancelLabel(), "Esc", g_ai_history_source_selected == row);
            return;
        }
        if (g_ai_list_visible) {
            var row: usize = 0;
            while (row < g_ai_profile_count) : (row += 1) {
                renderAiProfileRow(layout, window_height, row, &g_ai_profiles[row], g_ai_list_selected == row);
            }
            switch (g_ai_list_mode) {
                .manage => {
                    renderSessionRow(layout, window_height, row, i18n.s().sl_new_llm_provider, i18n.s().sl_v_add, g_ai_list_selected == row);
                    row += 1;
                    renderSessionRow(layout, window_height, row, i18n.s().sl_edit_llm_provider, if (g_ai_profile_count > 0) i18n.s().sl_v_choose else i18n.s().sl_v_no_profile, g_ai_list_selected == row);
                    row += 1;
                    renderSessionRow(layout, window_height, row, i18n.s().sl_delete_llm_provider, if (g_ai_profile_count > 0) i18n.s().sl_v_choose else i18n.s().sl_v_no_profile, g_ai_list_selected == row);
                    row += 1;
                    renderSessionRow(layout, window_height, row, sessionLauncherCancelLabel(), "Esc", g_ai_list_selected == row);
                },
                .edit_select, .delete_select, .switch_model => {
                    renderSessionRow(layout, window_height, row, i18n.s().sl_back, i18n.s().sl_v_manage, g_ai_list_selected == row);
                },
            }
            return;
        }
        if (g_ssh_list_visible) {
            var row: usize = 0;
            var profile_idx: usize = 0;
            while (profile_idx < g_ssh_profile_count) : (profile_idx += 1) {
                const profile = &g_ssh_profiles[profile_idx];
                if (!sshProfileMatchesFilter(profile)) continue;
                renderSshProfileRow(layout, window_height, row, profile, g_ssh_list_selected == row);
                row += 1;
            }
            switch (g_ssh_list_mode) {
                .manage => {
                    renderSessionRow(layout, window_height, row, "Load OpenSSH config", "~/.ssh/config", g_ssh_list_selected == row);
                    row += 1;
                    renderSessionRow(layout, window_height, row, i18n.s().sl_new_ssh_server, i18n.s().sl_v_add, g_ssh_list_selected == row);
                    row += 1;
                    renderSessionRow(layout, window_height, row, i18n.s().sl_edit_ssh_server, if (g_ssh_profile_count > 0) i18n.s().sl_v_choose else i18n.s().sl_v_no_server, g_ssh_list_selected == row);
                    row += 1;
                    renderSessionRow(layout, window_height, row, i18n.s().sl_delete_ssh_server, if (g_ssh_profile_count > 0) i18n.s().sl_v_choose else i18n.s().sl_v_no_server, g_ssh_list_selected == row);
                    row += 1;
                    renderSessionRow(layout, window_height, row, sessionLauncherCancelLabel(), "Esc", g_ssh_list_selected == row);
                },
                .edit_select, .delete_select => {
                    renderSessionRow(layout, window_height, row, i18n.s().sl_back, i18n.s().sl_v_manage, g_ssh_list_selected == row);
                },
                .ai_history_select => {
                    renderSessionRow(layout, window_height, row, i18n.s().sl_back, i18n.s().sl_sessions, g_ssh_list_selected == row);
                },
                .tmux_connect => {
                    renderSessionRow(layout, window_height, row, i18n.s().sl_back, "tmux", g_ssh_list_selected == row);
                },
            }
            return;
        }
        var row: usize = 0;
        renderSessionRow(layout, window_height, row, AppWindow.configuredLocalShellSessionTitle(), AppWindow.configuredLocalShellSessionDetail(), g_session_launcher_selected == row);
        row += 1;
        renderSessionRow(layout, window_height, row, "SSH", i18n.s().sl_v_connect_server, g_session_launcher_selected == row);
        row += 1;
        renderSessionRow(layout, window_height, command_center_state.SESSION_LAUNCHER_ROW_TMUX, "tmux", "Alive session", g_session_launcher_selected == command_center_state.SESSION_LAUNCHER_ROW_TMUX);
        row += 1;
        if (platform_pty_command.sessionLauncherWslRow()) |wsl_row| {
            row = wsl_row;
            renderSessionRow(layout, window_height, row, "WSL", platform_pty_command.wslLauncherDetail(), g_session_launcher_selected == row);
            row += 1;
        }
        renderSessionRow(layout, window_height, platform_pty_command.sessionLauncherAiAgentRow(), i18n.s().sl_ai_agent, defaultAiModeLabel(), g_session_launcher_selected == platform_pty_command.sessionLauncherAiAgentRow());
        renderSessionRow(layout, window_height, platform_pty_command.sessionLauncherAiHistoryRow(), i18n.s().sl_sessions, i18n.s().sl_sessions_detail, g_session_launcher_selected == platform_pty_command.sessionLauncherAiHistoryRow());
        return;
    }

    if (g_ai_form_visible) {
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.name), i18n.s().sl_ai_profile_name, aiField(.name), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.base_url), i18n.s().sl_ai_base_url, aiField(.base_url), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.api_key), i18n.s().sl_ai_api_key, aiField(.api_key), true);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.model), i18n.s().sl_ai_model, aiField(.model), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.system_prompt), i18n.s().sl_ai_system, aiField(.system_prompt), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.thinking), i18n.s().sl_ai_thinking, aiField(.thinking), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.reasoning_effort), i18n.s().sl_ai_effort, aiField(.reasoning_effort), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.stream), i18n.s().sl_ai_stream, aiField(.stream), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.agent), i18n.s().sl_ai_agent_field, aiField(.agent), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.protocol), i18n.s().sl_ai_protocol, aiProtocolDisplay(), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.max_tokens), i18n.s().sl_ai_max_tokens, aiField(.max_tokens), false);
        renderAiSessionField(layout, window_height, @intFromEnum(AiField.vision), i18n.s().sl_ai_vision, aiVisionDisplay(), false);
        renderSessionRow(layout, window_height, AI_FIELD_COUNT, i18n.s().sl_save_open, i18n.s().sl_v_agent, g_ai_focus == AI_FIELD_COUNT);
        renderSessionRow(layout, window_height, AI_FIELD_COUNT + 1, i18n.s().sl_save, i18n.s().sl_v_profile, g_ai_focus == AI_FIELD_COUNT + 1);
        renderSessionRow(layout, window_height, AI_FIELD_COUNT + 2, sessionLauncherCancelLabel(), "Esc", g_ai_focus == AI_FIELD_COUNT + 2);
        return;
    }

    renderSessionField(layout, window_height, @intFromEnum(SshField.name), i18n.s().sl_ssh_server_name, sshField(.name), false);
    renderSessionField(layout, window_height, @intFromEnum(SshField.ip), i18n.s().sl_ssh_ip_host, sshField(.ip), false);
    renderSessionField(layout, window_height, @intFromEnum(SshField.user), i18n.s().sl_ssh_user, sshField(.user), false);
    renderSessionField(layout, window_height, @intFromEnum(SshField.password), i18n.s().sl_ssh_password, sshField(.password), true);
    renderSessionField(layout, window_height, @intFromEnum(SshField.port), i18n.s().sl_ssh_port, sshField(.port), false);
    renderSessionField(layout, window_height, @intFromEnum(SshField.proxy_jump), i18n.s().sl_ssh_jump_host, sshField(.proxy_jump), false);
    renderSessionField(layout, window_height, @intFromEnum(SshField.auth_method), i18n.s().sl_ssh_auth_method, sshField(.auth_method), false);
    renderSessionField(layout, window_height, @intFromEnum(SshField.identity_file), i18n.s().sl_ssh_identity_file, sshField(.identity_file), false);
    renderSessionRow(layout, window_height, SSH_FIELD_COUNT, i18n.s().sl_save_connect, platform_pty_command.sshLauncherDetail(), g_ssh_focus == SSH_FIELD_COUNT);
    renderSessionRow(layout, window_height, SSH_FIELD_COUNT + 1, i18n.s().sl_save, i18n.s().sl_v_profile, g_ssh_focus == SSH_FIELD_COUNT + 1);
    renderSessionRow(layout, window_height, SSH_FIELD_COUNT + 2, sessionLauncherCancelLabel(), "Esc", g_ssh_focus == SSH_FIELD_COUNT + 2);
}

// ============================================================================
// Settings page
// ============================================================================

const ThemePreset = struct {
    label: []const u8,
    theme: ?[]const u8,
    detail: []const u8,
};

const SETTINGS_THEME_PRESETS = [_]ThemePreset{
    .{ .label = "WispTerm Default", .theme = null, .detail = "Warm balanced dark" },
    .{ .label = "Catppuccin Mocha", .theme = "Catppuccin Mocha", .detail = "Soft popular dark" },
    .{ .label = "TokyoNight Night", .theme = "TokyoNight Night", .detail = "Deep blue coding" },
    .{ .label = "GitHub Light", .theme = "GitHub Light Default", .detail = "Clean white" },
    .{ .label = "Xcode Light", .theme = "Xcode Light", .detail = "Bright native" },
};

const SETTINGS_THEME_ROW = 1;
const SETTINGS_CONTROL_ROW_START = SETTINGS_THEME_ROW + 1;
const SETTINGS_ROW_COUNT = SETTINGS_CONTROL_ROW_START + 12;

const SettingsAction = enum {
    font_size_minus,
    font_size_plus,
    cycle_theme,
    cycle_cursor_style,
    toggle_cursor_blink,
    toggle_focus_follows_mouse,
    cycle_shell,
    cycle_default_ai_profile,
    cycle_default_ai_profile_prev,
    toggle_weixin_direct,
    cycle_language,
    toggle_restore_tabs,
    toggle_distill_suggest,
    open_raw_config,
    restore_defaults,
    close,
};

const SettingsLayout = struct {
    box_x: f32,
    box_top_px: f32,
    box_w: f32,
    box_h: f32,
    header_h: f32,
    footer_h: f32,
    row_top_px: f32,
    row_h: f32,
    /// Number of rows that fit in the box for the current window height.
    visible_rows: usize,
    /// Index of the first rendered row (scroll offset).
    scroll: usize,
};

pub threadlocal var g_settings_visible: bool = false;
threadlocal var g_settings_focus: usize = SETTINGS_THEME_ROW;
threadlocal var g_settings_cfg_dirty: bool = true;
threadlocal var g_settings_cfg_cache: Config = .{};

pub fn settingsPageVisible() bool {
    return g_settings_visible;
}

pub fn settingsPageOpen() void {
    var state = commandCenterStateSnapshot();
    state.settingsPageOpen();
    commandCenterStateCommit(state);
    g_settings_focus = SETTINGS_THEME_ROW;
    g_ai_list_mode = .manage;
    g_settings_cfg_dirty = true;
}

fn settingsPageReloadCfg() void {
    g_settings_cfg_dirty = true;
}

fn settingsCfg(allocator: std.mem.Allocator) *Config {
    if (g_settings_cfg_dirty) {
        g_settings_cfg_cache.deinit(allocator);
        g_settings_cfg_cache = Config.load(allocator) catch Config{};
        g_settings_cfg_dirty = false;
    }
    return &g_settings_cfg_cache;
}

pub fn settingsPageClose() void {
    g_settings_visible = false;
    if (g_settings_cfg_dirty == false) {
        const allocator = AppWindow.g_allocator orelse return;
        g_settings_cfg_cache.deinit(allocator);
        g_settings_cfg_cache = .{};
        g_settings_cfg_dirty = true;
    }
}

pub fn settingsPageHandleKey(ev: input_key.KeyEvent) void {
    switch (ev.key) {
        .escape => settingsPageClose(),
        .arrow_down, .tab => g_settings_focus = (g_settings_focus + 1) % SETTINGS_ROW_COUNT,
        .arrow_up => g_settings_focus = if (g_settings_focus == 0) SETTINGS_ROW_COUNT - 1 else g_settings_focus - 1,
        .arrow_left => runSettingsFocusLeft(),
        .arrow_right => runSettingsFocusRight(),
        .enter => runSettingsFocusPrimary(),
        else => {},
    }
}

pub fn settingsPageContainsPoint(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const layout = settingsLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    return x >= layout.box_x and x <= layout.box_x + layout.box_w and
        y >= layout.box_top_px and y <= layout.box_top_px + layout.box_h;
}

pub fn settingsPageExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const action = settingsHitTest(xpos, ypos, window_width, window_height, top_offset) orelse return false;
    executeSettingsAction(action);
    return true;
}

/// Number of settings rows that fit within the box for the given window height,
/// leaving room for the header and footer. Mirrors commandPaletteRowCapacity().
fn settingsRowCapacity(content_height: f32, base_h: f32, row_h: f32) usize {
    const usable_h = @max(row_h, content_height - 32.0 - base_h);
    if (usable_h <= row_h) return 1;
    const count_f = @floor(usable_h / row_h);
    const count: usize = @intFromFloat(@max(1.0, count_f));
    return @min(count, SETTINGS_ROW_COUNT);
}

/// First row to render so the focused row stays visible (scroll offset).
/// Mirrors commandPaletteFirstVisibleIndex().
fn settingsFirstVisibleRow(visible_rows: usize) usize {
    if (visible_rows == 0 or SETTINGS_ROW_COUNT <= visible_rows) return 0;
    const focus = @min(g_settings_focus, SETTINGS_ROW_COUNT - 1);
    if (focus < visible_rows) return 0;
    return @min(focus - visible_rows + 1, SETTINGS_ROW_COUNT - visible_rows);
}

fn settingsLayout(window_width: f32, window_height: f32, top_offset: f32) SettingsLayout {
    const content_height = @max(1, window_height - top_offset);
    const box_w = @round(@min(@max(420, window_width - 48), 760));
    const row_h = overlayRowHeight(42);
    const header_h = @round(18 + overlayLineHeight() * 2 + 12);
    const footer_h = @round(@max(52.0, overlayTextHeight() + 28.0));
    const visible_rows = settingsRowCapacity(content_height, header_h + footer_h, row_h);
    const scroll = settingsFirstVisibleRow(visible_rows);
    const box_h = @round(clampOverlayBoxHeight(header_h + row_h * @as(f32, @floatFromInt(visible_rows)) + footer_h, content_height));
    const box_x = @round(@max(16, (window_width - box_w) / 2));
    const box_top_px = @round(top_offset + @max(16, (content_height - box_h) / 2));
    const row_top_px = @round(box_top_px + header_h);
    return .{
        .box_x = box_x,
        .box_top_px = box_top_px,
        .box_w = box_w,
        .box_h = box_h,
        .header_h = header_h,
        .footer_h = footer_h,
        .row_top_px = row_top_px,
        .row_h = row_h,
        .visible_rows = visible_rows,
        .scroll = scroll,
    };
}

fn settingsHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) ?SettingsAction {
    const layout = settingsLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);

    const close_x = layout.box_x + layout.box_w - 62;
    if (y >= layout.box_top_px + 18 and y < layout.box_top_px + 46 and x >= close_x and x < close_x + 44) {
        return .close;
    }

    if (x < layout.box_x + 18 or x > layout.box_x + layout.box_w - 18) return null;
    if (y < layout.row_top_px) return null;
    const visible_index: usize = @intFromFloat(@floor((y - layout.row_top_px) / layout.row_h));
    if (visible_index >= layout.visible_rows) return null;
    const row = visible_index + layout.scroll;
    if (row >= SETTINGS_ROW_COUNT) return null;
    g_settings_focus = row;

    if (row == 0) {
        const plus_x = layout.box_x + layout.box_w - 70;
        const minus_x = plus_x - 42;
        if (x >= minus_x and x < minus_x + 30) return .font_size_minus;
        if (x >= plus_x and x < plus_x + 30) return .font_size_plus;
        return null;
    }

    if (row == SETTINGS_THEME_ROW) {
        return .cycle_theme;
    }

    return switch (row - SETTINGS_CONTROL_ROW_START) {
        0 => .cycle_cursor_style,
        1 => .toggle_cursor_blink,
        2 => .toggle_focus_follows_mouse,
        3 => .cycle_shell,
        4 => .cycle_default_ai_profile,
        5 => .toggle_weixin_direct,
        6 => .cycle_language,
        7 => .toggle_restore_tabs,
        8 => .toggle_distill_suggest,
        9 => .open_raw_config,
        10 => .restore_defaults,
        11 => .close,
        else => null,
    };
}

fn executeSettingsAction(action: SettingsAction) void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    switch (action) {
        .font_size_minus => {
            const next = if (cfg.@"font-size" > 6) cfg.@"font-size" - 1 else cfg.@"font-size";
            writeConfigInt("font-size", next);
        },
        .font_size_plus => {
            const next = @min(cfg.@"font-size" + 1, 72);
            writeConfigInt("font-size", next);
        },
        .cycle_theme => cycleThemePreset(1),
        .cycle_cursor_style => Config.setConfigValue(allocator, "cursor-style", nextCursorStyle(cfg.@"cursor-style")) catch {},
        .toggle_cursor_blink => Config.setConfigValue(allocator, "cursor-style-blink", if (cfg.@"cursor-style-blink") "false" else "true") catch {},
        .toggle_focus_follows_mouse => Config.setConfigValue(allocator, "focus-follows-mouse", if (cfg.@"focus-follows-mouse") "false" else "true") catch {},
        .cycle_shell => Config.setConfigValue(allocator, "shell", platform_pty_command.nextConfigShell(cfg.shell)) catch {},
        .cycle_default_ai_profile => cycleDefaultAiProfile(1),
        .cycle_default_ai_profile_prev => cycleDefaultAiProfile(-1),
        .toggle_weixin_direct => Config.setConfigValue(allocator, "weixin-direct-enabled", if (cfg.@"weixin-direct-enabled") "false" else "true") catch {},
        .cycle_language => Config.setConfigValue(allocator, "language", nextLanguageSetting(cfg.language)) catch {},
        .toggle_restore_tabs => Config.setConfigValue(allocator, "restore-tabs-on-startup", if (cfg.@"restore-tabs-on-startup") "false" else "true") catch {},
        .toggle_distill_suggest => Config.setConfigValue(allocator, "ai-distill-suggest", if (cfg.@"ai-distill-suggest") "false" else "true") catch {},
        .open_raw_config => Config.openConfigInEditor(allocator),
        .restore_defaults => restoreDefaultsConfirmOpen(),
        .close => settingsPageClose(),
    }
    settingsPageReloadCfg();

    // Apply the change to the running terminal right away instead of waiting for
    // the config-file watcher's debounce (mirrors applyEmbeddedThemeFromPalette).
    // cycle_theme already applies via cycleThemePreset; the excluded actions open
    // an editor/confirm dialog or close the page and write nothing to apply.
    switch (action) {
        .cycle_theme, .open_raw_config, .restore_defaults, .close => {},
        else => AppWindow.reloadConfigImmediate(allocator),
    }
}

fn writeConfigInt(key: []const u8, value: u32) void {
    const allocator = AppWindow.g_allocator orelse return;
    var buf: [32]u8 = undefined;
    const value_text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    Config.setConfigValue(allocator, key, value_text) catch {};
}

fn runSettingsFocusPrimary() void {
    switch (g_settings_focus) {
        0 => executeSettingsAction(.font_size_plus),
        SETTINGS_THEME_ROW => cycleThemePreset(1),
        SETTINGS_CONTROL_ROW_START + 0 => executeSettingsAction(.cycle_cursor_style),
        SETTINGS_CONTROL_ROW_START + 1 => executeSettingsAction(.toggle_cursor_blink),
        SETTINGS_CONTROL_ROW_START + 2 => executeSettingsAction(.toggle_focus_follows_mouse),
        SETTINGS_CONTROL_ROW_START + 3 => executeSettingsAction(.cycle_shell),
        SETTINGS_CONTROL_ROW_START + 4 => executeSettingsAction(.cycle_default_ai_profile),
        SETTINGS_CONTROL_ROW_START + 5 => executeSettingsAction(.toggle_weixin_direct),
        SETTINGS_CONTROL_ROW_START + 6 => executeSettingsAction(.cycle_language),
        SETTINGS_CONTROL_ROW_START + 7 => executeSettingsAction(.toggle_restore_tabs),
        SETTINGS_CONTROL_ROW_START + 8 => executeSettingsAction(.toggle_distill_suggest),
        SETTINGS_CONTROL_ROW_START + 9 => executeSettingsAction(.open_raw_config),
        SETTINGS_CONTROL_ROW_START + 10 => executeSettingsAction(.restore_defaults),
        SETTINGS_CONTROL_ROW_START + 11 => executeSettingsAction(.close),
        else => {},
    }
}

fn runSettingsFocusLeft() void {
    switch (g_settings_focus) {
        0 => executeSettingsAction(.font_size_minus),
        SETTINGS_THEME_ROW => cycleThemePreset(-1),
        SETTINGS_CONTROL_ROW_START + 4 => executeSettingsAction(.cycle_default_ai_profile_prev),
        else => {},
    }
}

fn runSettingsFocusRight() void {
    switch (g_settings_focus) {
        0 => executeSettingsAction(.font_size_plus),
        SETTINGS_THEME_ROW => cycleThemePreset(1),
        else => runSettingsFocusPrimary(),
    }
}

const THEME_RESET_KEYS = [_][]const u8{
    "theme",
    "background",
    "foreground",
    "cursor-color",
    "cursor-text",
    "selection-background",
    "selection-foreground",
    "palette",
};

fn applyThemePreset(index: usize) void {
    const allocator = AppWindow.g_allocator orelse return;
    if (index >= SETTINGS_THEME_PRESETS.len) return;

    const preset = SETTINGS_THEME_PRESETS[index];
    if (preset.theme) |theme_name| {
        Config.removeConfigKeys(allocator, &THEME_OVERRIDE_KEYS) catch {};
        Config.setConfigValue(allocator, "theme", theme_name) catch {};
    } else {
        Config.removeConfigKeys(allocator, &THEME_RESET_KEYS) catch {};
    }
}

fn activeThemePresetIndex(cfg: *const Config) ?usize {
    for (SETTINGS_THEME_PRESETS, 0..) |preset, i| {
        if (themePresetIsActive(cfg, preset)) return i;
    }
    return null;
}

fn cycleThemePreset(delta: i32) void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    const count: i32 = @intCast(SETTINGS_THEME_PRESETS.len);
    const current: i32 = @intCast(activeThemePresetIndex(&cfg) orelse 0);
    const next = @mod(current + delta, count);
    applyThemePreset(@intCast(next));
    settingsPageReloadCfg();
    // Theme rows reach here directly from the focus handlers (not via
    // executeSettingsAction), so apply the new theme to the terminal immediately.
    AppWindow.reloadConfigImmediate(allocator);
}

fn themePresetIsActive(cfg: *const Config, preset: ThemePreset) bool {
    if (preset.theme) |theme_name| {
        return if (cfg.theme) |active| std.mem.eql(u8, active, theme_name) else false;
    }
    return cfg.theme == null;
}

fn currentThemePresetLabel(cfg: *const Config) []const u8 {
    if (activeThemePresetIndex(cfg)) |idx| return SETTINGS_THEME_PRESETS[idx].label;
    if (cfg.theme) |theme_name| return theme_name;
    return SETTINGS_THEME_PRESETS[0].label;
}

fn cursorStyleText(style: Config.CursorStyle) []const u8 {
    return switch (style) {
        .block => "block",
        .bar => "bar",
        .underline => "underline",
        .block_hollow => "block_hollow",
    };
}

fn nextCursorStyle(style: Config.CursorStyle) []const u8 {
    return switch (style) {
        .block => "bar",
        .bar => "underline",
        .underline => "block_hollow",
        .block_hollow => "block",
    };
}

fn boolText(value: bool) []const u8 {
    return if (value) i18n.s().settings_value_on else i18n.s().settings_value_off;
}

/// Config value string for the next language in the cycle (auto → en → zh-CN → auto).
fn nextLanguageSetting(setting: i18n.LanguageSetting) []const u8 {
    return switch (setting) {
        .auto => "en",
        .en => "zh-CN",
        .zh_CN => "auto",
    };
}

/// Display label for the Language settings row. Language names show natively;
/// only "Auto" is localized.
fn languageSettingText(setting: i18n.LanguageSetting) []const u8 {
    return switch (setting) {
        .auto => i18n.s().settings_lang_auto,
        .en => "English",
        .zh_CN => "简体中文",
    };
}

fn renderSettingsRow(layout: SettingsLayout, window_height: f32, row: usize, title: []const u8, value: []const u8, hint: []const u8, clickable: bool, selected: bool) void {
    // Skip rows scrolled out of view above or below the visible window.
    if (row < layout.scroll) return;
    const visible_index = row - layout.scroll;
    if (visible_index >= layout.visible_rows) return;
    const row_y = @round(@as(f32, @floatFromInt(visible_index)) * layout.row_h);
    const y_top_px = layout.row_top_px + row_y;
    const gl_y = @round(window_height - y_top_px - layout.row_h);
    const x = layout.box_x + 18;
    const w = layout.box_w - 36;
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const active = std.mem.eql(u8, value, "active");

    if (clickable) {
        const row_color = if (selected) mixColor(bg, accent, 0.24) else if (active) mixColor(bg, accent, 0.18) else mixColor(bg, fg, 0.055);
        ui_pipeline.fillQuadAlpha(x, gl_y + 3, w, layout.row_h - 6, row_color, if (selected) 0.72 else if (active) 0.44 else 0.82);
        if (selected) ui_pipeline.fillQuadAlpha(x, gl_y + 3, 3, layout.row_h - 6, accent, 0.82);
    }

    const text_y = rowTextY(gl_y, layout.row_h);
    const title_color = if (selected or active) mixColor(fg, accent, 0.18) else fg;
    const title_x = x + 12;
    const right_edge = layout.box_x + layout.box_w - 36;
    var title_max_w = w - 24;
    var value_x = right_edge;

    if (value.len > 0) {
        const value_w = measureTitlebarText(value);
        const value_max_w = @min(value_w, @max(0.0, right_edge - title_x - 150));
        value_x = @round(right_edge - value_max_w);
        title_max_w = @min(title_max_w, value_x - title_x - 18);
        const value_color = if (selected or active) accent else mixColor(bg, fg, 0.78);
        renderTitlebarTextLimited(value, value_x, text_y, value_color, value_max_w);
    }

    if (hint.len > 0) {
        const preferred_hint_x = title_x + @max(160.0, measureTitlebarText(title) + 28.0);
        const hint_x = @min(preferred_hint_x, value_x - 60);
        const hint_max_w = value_x - hint_x - 18;
        title_max_w = @min(title_max_w, hint_x - title_x - 18);
        if (hint_max_w > font.g_titlebar_cell_width * 4) {
            renderTitlebarTextLimited(hint, hint_x, text_y, mixColor(bg, fg, 0.55), hint_max_w);
        }
    }

    renderTitlebarTextLimited(title, title_x, text_y, title_color, title_max_w);
}

pub fn renderSettingsPage(window_width: f32, window_height: f32, top_offset: f32) void {
    if (!g_settings_visible) return;
    const allocator = AppWindow.g_allocator orelse return;

    const cfg = settingsCfg(allocator);

    const layout = settingsLayout(window_width, window_height, top_offset);
    const box_y = @round(window_height - layout.box_top_px - layout.box_h);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_color = mixColor(bg, fg, 0.035);
    const border_color = mixColor(bg, accent, 0.24);
    const muted_color = mixColor(bg, fg, 0.58);

    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.16);
    renderRoundedQuadAlpha(layout.box_x - 1, box_y - 1, layout.box_w + 2, layout.box_h + 2, 11, border_color, 0.24);
    renderRoundedQuadAlpha(layout.box_x, box_y, layout.box_w, layout.box_h, 10, panel_color, 0.96);

    const title_y = textYFromTop(window_height, layout.box_top_px + 18);
    const subtitle_y = textYFromTop(window_height, layout.box_top_px + 18 + overlayLineHeight());
    renderTitlebarText(i18n.s().settings_title, layout.box_x + 24, title_y, mixColor(fg, accent, 0.14));
    renderTitlebarTextLimited(i18n.s().settings_subtitle, layout.box_x + 24, subtitle_y, muted_color, layout.box_w - 96);
    renderTitlebarText("Esc", layout.box_x + layout.box_w - 52, title_y, mixColor(bg, fg, 0.72));

    var font_buf: [24]u8 = undefined;
    const font_value = std.fmt.bufPrint(&font_buf, "-  {d}  +", .{cfg.@"font-size"}) catch "";
    renderSettingsRow(layout, window_height, 0, i18n.s().settings_font_size, font_value, "", true, g_settings_focus == 0);

    var theme_buf: [96]u8 = undefined;
    const theme_value = std.fmt.bufPrint(&theme_buf, "< {s} >", .{currentThemePresetLabel(cfg)}) catch currentThemePresetLabel(cfg);
    renderSettingsRow(layout, window_height, SETTINGS_THEME_ROW, i18n.s().settings_theme, theme_value, "", true, g_settings_focus == SETTINGS_THEME_ROW);

    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 0, i18n.s().settings_cursor_style, cursorStyleText(cfg.@"cursor-style"), "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 0);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 1, i18n.s().settings_cursor_blink, boolText(cfg.@"cursor-style-blink"), "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 1);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 2, i18n.s().settings_focus_follows_mouse, boolText(cfg.@"focus-follows-mouse"), "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 2);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 3, i18n.s().settings_shell, cfg.shell, "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 3);
    loadAiProfiles();
    const ai_default_value = if (g_ai_profile_count > 0)
        aiProfileField(&g_ai_profiles[defaultAiProfileIndex()], .name)
    else
        i18n.s().settings_value_none;
    const ai_default_hint = if (g_ai_profile_count > 0)
        aiProfileModeLabel(&g_ai_profiles[defaultAiProfileIndex()])
    else
        i18n.s().settings_hint_add_profiles;
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 4, i18n.s().settings_default_ai, ai_default_value, ai_default_hint, true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 4);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 5, i18n.s().settings_weixin_direct, boolText(cfg.@"weixin-direct-enabled"), "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 5);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 6, i18n.s().settings_language, languageSettingText(cfg.language), i18n.s().settings_hint_restart, true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 6);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 7, i18n.s().settings_restore_tabs, boolText(cfg.@"restore-tabs-on-startup"), "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 7);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 8, i18n.s().settings_distill_suggest, boolText(cfg.@"ai-distill-suggest"), "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 8);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 9, i18n.s().settings_raw_config, i18n.s().settings_value_open, i18n.s().settings_hint_advanced_editor, true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 9);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 10, i18n.s().settings_restore_defaults, "Enter", "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 10);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 11, i18n.s().settings_close, "Esc", "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 11);

    // Scrollbar indicator when not all rows fit (short windows). The list is
    // scrolled via keyboard/click focus-follow and the mouse wheel.
    if (layout.visible_rows < SETTINGS_ROW_COUNT) {
        const total: f32 = @floatFromInt(SETTINGS_ROW_COUNT);
        const vis: f32 = @floatFromInt(layout.visible_rows);
        const track_h = layout.row_h * vis;
        const track_top_px = layout.row_top_px;
        const sb_w: f32 = 3;
        const sb_x = layout.box_x + layout.box_w - sb_w - 7;
        const track_gl_y = @round(window_height - track_top_px - track_h);
        ui_pipeline.fillQuadAlpha(sb_x, track_gl_y, sb_w, track_h, mixColor(bg, fg, 0.25), 0.30);

        const thumb_h = @max(24.0, @round(track_h * vis / total));
        const max_scroll_f: f32 = @floatFromInt(SETTINGS_ROW_COUNT - layout.visible_rows);
        const scroll_f: f32 = @floatFromInt(layout.scroll);
        const thumb_offset = if (max_scroll_f > 0) @round((track_h - thumb_h) * (scroll_f / max_scroll_f)) else 0;
        const thumb_gl_y = @round(window_height - (track_top_px + thumb_offset) - thumb_h);
        ui_pipeline.fillQuadAlpha(sb_x, thumb_gl_y, sb_w, thumb_h, accent, 0.55);
    }
}

/// Mouse-wheel handling for the settings page. The list scrolls by moving the
/// focused row (which the view follows), matching the keyboard navigation model.
/// Positive delta scrolls toward the top, mirroring whatsNewHandleScroll().
pub fn settingsPageHandleScroll(delta_y: f64) void {
    if (!g_settings_visible) return;
    if (delta_y > 0) {
        if (g_settings_focus > 0) g_settings_focus -= 1;
    } else if (delta_y < 0) {
        if (g_settings_focus + 1 < SETTINGS_ROW_COUNT) g_settings_focus += 1;
    }
}

// ============================================================================
// FPS debug overlay state
// ============================================================================

pub threadlocal var g_debug_fps: bool = false; // Whether to show FPS overlay
pub threadlocal var g_debug_draw_calls: bool = false; // Whether to show draw call count overlay
threadlocal var g_fps_frame_count: u32 = 0; // Frames since last FPS update
pub threadlocal var g_fps_last_time: i64 = 0; // Timestamp of last FPS calculation
threadlocal var g_fps_value: f32 = 0; // Current FPS value to display

// ============================================================================
// Split rendering helpers
// ============================================================================

/// Render a semi-transparent overlay over an unfocused split pane.
pub fn renderUnfocusedOverlay(rect: SplitRect, window_height: f32) void {
    const opacity = 1.0 - g_unfocused_split_opacity;
    if (opacity < 0.01) return;

    // Draw semi-transparent background color overlay
    const px: f32 = @floatFromInt(rect.x);
    const py: f32 = window_height - @as(f32, @floatFromInt(rect.y + rect.height));
    const pw: f32 = @floatFromInt(rect.width);
    const ph: f32 = @floatFromInt(rect.height);

    // Use background color with alpha for the overlay
    ui_pipeline.fillQuadAlpha(px, py, pw, ph, AppWindow.g_theme.background, opacity);
}

/// Render unfocused overlay within current viewport (for split rendering).
/// Assumes viewport is already set to the split's region.
/// Uses true alpha blending so it blends with actual rendered content.
pub fn renderUnfocusedOverlaySimple(width: f32, height: f32) void {
    const alpha = 1.0 - g_unfocused_split_opacity;
    if (alpha < 0.01) return;

    const vertices = [6][4]f32{
        .{ 0, height, 0.0, 0.0 },
        .{ 0, 0, 0.0, 1.0 },
        .{ width, 0, 1.0, 1.0 },
        .{ 0, height, 0.0, 0.0 },
        .{ width, 0, 1.0, 1.0 },
        .{ width, height, 1.0, 0.0 },
    };

    ui_pipeline.fillOverlay(vertices, .{
        AppWindow.g_theme.background[0],
        AppWindow.g_theme.background[1],
        AppWindow.g_theme.background[2],
        alpha,
    });
}

/// Highlight a panel that is the current Alt-drag swap drop target. Drawn inside
/// the panel's own viewport (coords 0..width / 0..height), like the unfocused
/// overlay: a faint accent wash plus an accent border. Uses real alpha blending
/// (fillOverlay) so the underlying terminal content stays visible.
pub fn renderSwapTargetHighlight(width: f32, height: f32) void {
    const accent = AppWindow.g_theme.cursor_color;
    const border: f32 = 2.0;

    const fillRectOverlay = struct {
        fn call(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
            if (w <= 0 or h <= 0) return;
            const verts = [6][4]f32{
                .{ x, y + h, 0.0, 0.0 },
                .{ x, y, 0.0, 1.0 },
                .{ x + w, y, 1.0, 1.0 },
                .{ x, y + h, 0.0, 0.0 },
                .{ x + w, y, 1.0, 1.0 },
                .{ x + w, y + h, 1.0, 0.0 },
            };
            ui_pipeline.fillOverlay(verts, .{ color[0], color[1], color[2], alpha });
        }
    }.call;

    // Faint accent wash over the whole panel.
    fillRectOverlay(0, 0, width, height, accent, 0.14);

    // Accent border on all four edges.
    fillRectOverlay(0, 0, width, border, accent, 0.85); // bottom
    fillRectOverlay(0, height - border, width, border, accent, 0.85); // top
    fillRectOverlay(0, 0, border, height, accent, 0.85); // left
    fillRectOverlay(width - border, 0, border, height, accent, 0.85); // right
}

/// Render split dividers between panes in the active tab.
/// If split-divider-color is configured, uses that color (solid).
/// Otherwise uses scrollbar-style rendering: black with alpha transparency.
pub fn renderSplitDividers(active_tab: *const TabState, content_x: i32, content_y: i32, content_w: i32, content_h: i32, window_height: f32) void {
    if (!active_tab.tree.isSplit()) return;

    const allocator = AppWindow.g_allocator orelse return;

    // Get spatial representation
    var spatial = active_tab.tree.spatial(allocator) catch return;
    defer spatial.deinit(allocator);

    // Check if custom color is configured
    const use_custom_color = g_split_divider_color != null;
    const custom_color = g_split_divider_color orelse .{ 0, 0, 0 };
    // Default alpha - similar to scrollbar thumb (0.45) but slightly less prominent
    const default_alpha: f32 = 0.35;

    // Walk the tree nodes and draw dividers for each split
    for (active_tab.tree.nodes, 0..) |node, i| {
        switch (node) {
            .leaf => {},
            .split => |s| {
                const slot = spatial.slots[i];
                const slot_x: f32 = @as(f32, @floatCast(slot.x)) * @as(f32, @floatFromInt(content_w)) + @as(f32, @floatFromInt(content_x));
                const slot_y: f32 = @as(f32, @floatCast(slot.y)) * @as(f32, @floatFromInt(content_h)) + @as(f32, @floatFromInt(content_y));
                const slot_w: f32 = @as(f32, @floatCast(slot.width)) * @as(f32, @floatFromInt(content_w));
                const slot_h: f32 = @as(f32, @floatCast(slot.height)) * @as(f32, @floatFromInt(content_h));

                switch (s.layout) {
                    .horizontal => {
                        // Vertical divider at ratio position
                        const div_x = slot_x + slot_w * @as(f32, @floatCast(s.ratio)) - @as(f32, @floatFromInt(@divTrunc(SPLIT_DIVIDER_WIDTH, 2)));
                        const div_y = window_height - slot_y - slot_h;
                        if (use_custom_color) {
                            ui_pipeline.fillQuad(div_x, div_y, @floatFromInt(SPLIT_DIVIDER_WIDTH), slot_h, custom_color);
                        } else {
                            ui_pipeline.fillQuadAlpha(div_x, div_y, @floatFromInt(SPLIT_DIVIDER_WIDTH), slot_h, .{ 0, 0, 0 }, default_alpha);
                        }
                    },
                    .vertical => {
                        // Horizontal divider at ratio position
                        const div_x = slot_x;
                        const div_y = window_height - slot_y - slot_h * @as(f32, @floatCast(s.ratio)) - @as(f32, @floatFromInt(@divTrunc(SPLIT_DIVIDER_WIDTH, 2)));
                        if (use_custom_color) {
                            ui_pipeline.fillQuad(div_x, div_y, slot_w, @floatFromInt(SPLIT_DIVIDER_WIDTH), custom_color);
                        } else {
                            ui_pipeline.fillQuadAlpha(div_x, div_y, slot_w, @floatFromInt(SPLIT_DIVIDER_WIDTH), .{ 0, 0, 0 }, default_alpha);
                        }
                    },
                }
            },
        }
    }
}

/// Draw a small filled dot at the top-right corner of each split pane that has
/// a visible agent running. The dot is colored by agentBadgeColor(state) and is
/// additive — it does not replace the existing focused-surface titlebar badge.
///
/// Coordinate system: OpenGL Y=0 is bottom. content_x/y/w/h are in framebuffer
/// pixels (same as renderSplitDividers). window_height is the framebuffer height.
pub fn renderPaneAgentDots(active_tab: *const TabState, content_x: i32, content_y: i32, content_w: i32, content_h: i32, window_height: f32) void {
    if (!active_tab.tree.isSplit()) {
        // Single-pane tab — no per-pane dot needed (focused badge in titlebar covers it).
        return;
    }

    const allocator = AppWindow.g_allocator orelse return;

    var spatial = active_tab.tree.spatial(allocator) catch return;
    defer spatial.deinit(allocator);

    const dot_size: f32 = 6; // diameter of the dot square
    const dot_margin: f32 = 4; // inset from the pane corner

    var it = active_tab.tree.surfaces();
    while (it.next()) |entry| {
        const det = entry.surface.agent_detection;
        if (!det.visible()) continue;

        const idx = @intFromEnum(entry.handle);
        if (idx >= spatial.slots.len) continue;
        const slot = spatial.slots[idx];

        // Convert normalized slot to framebuffer pixel rect.
        const px: f32 = @as(f32, @floatCast(slot.x)) * @as(f32, @floatFromInt(content_w)) + @as(f32, @floatFromInt(content_x));
        const py: f32 = @as(f32, @floatCast(slot.y)) * @as(f32, @floatFromInt(content_h)) + @as(f32, @floatFromInt(content_y));
        const pw: f32 = @as(f32, @floatCast(slot.width)) * @as(f32, @floatFromInt(content_w));

        // Top-right corner in GL coords (Y=0 at bottom). py is top-down from the
        // framebuffer top, so the pane spans GL-Y [window_height - py - ph,
        // window_height - py]; its visual top edge is the higher value
        // (window_height - py). fillQuad's y is the quad's bottom edge (it extends
        // upward by dot_size), so inset the dot below the top edge by the margin.
        const gl_pane_top = window_height - py;
        const dot_x = px + pw - dot_size - dot_margin;
        const dot_y = gl_pane_top - dot_size - dot_margin;

        const color = titlebar.agentBadgeColor(det.state);
        ui_pipeline.fillQuad(dot_x, dot_y, dot_size, dot_size, color);
    }
}

// ============================================================================
// Debug overlays
// ============================================================================

/// Update the FPS counter. Call once per frame.
pub fn updateFps() void {
    g_fps_frame_count += 1;
    const now = std.time.milliTimestamp();
    const elapsed = now - g_fps_last_time;
    if (elapsed >= 1000) {
        g_fps_value = @as(f32, @floatFromInt(g_fps_frame_count)) * 1000.0 / @as(f32, @floatFromInt(elapsed));
        g_fps_frame_count = 0;
        g_fps_last_time = now;
    }
}

/// Render the FPS debug overlay in the bottom-right corner.
pub fn renderDebugOverlay(window_width: f32) void {
    const margin: f32 = 8;
    const pad_h: f32 = 4;
    const pad_v: f32 = 2;
    const line_h = font.g_titlebar_cell_height + pad_v * 2;
    var overlay_y: f32 = margin;
    g_remote_key_copy_rect = null;

    if (AppWindow.g_app) |app| {
        if (app.remote_client) |client| {
            const session_key = client.sessionKey();
            const flash_active = std.time.milliTimestamp() < g_remote_key_copied_until_ms;
            const dismissed = isRemoteKeyDismissed(session_key);
            // Show the key once when remote starts; after the user copies it,
            // briefly flash "Remote key copied" then hide permanently for that
            // session. The command palette is the only re-copy path afterwards.
            if (!dismissed or flash_active) {
                g_remote_key_copy_rect = renderDebugLine(window_width, &overlay_y, margin, pad_h, pad_v, line_h, blk: {
                    var buf: [256]u8 = undefined;
                    if (flash_active) {
                        break :blk "Remote key copied";
                    }
                    break :blk std.fmt.bufPrint(
                        &buf,
                        "Remote {s} key {s}  click to copy",
                        .{ remoteStateLabel(client.loadState()), session_key },
                    ) catch break :blk "";
                }, remoteStateColor(client.loadState()));
            }
        }
    }

    if (g_debug_fps) {
        _ = renderDebugLine(window_width, &overlay_y, margin, pad_h, pad_v, line_h, blk: {
            var buf: [32]u8 = undefined;
            const fps_int: u32 = @intFromFloat(@round(g_fps_value));
            break :blk std.fmt.bufPrint(&buf, "{d} fps", .{fps_int}) catch break :blk "";
        }, .{ 0.0, 1.0, 0.0 });
    }

    if (g_debug_draw_calls) {
        _ = renderDebugLine(window_width, &overlay_y, margin, pad_h, pad_v, line_h, blk: {
            var buf: [32]u8 = undefined;
            break :blk std.fmt.bufPrint(&buf, "{d} draws", .{gl_init.g_draw_call_count}) catch break :blk "";
        }, .{ 1.0, 1.0, 0.0 });
    }
}

pub fn remoteKeyCopiedFlash() void {
    g_remote_key_copied_until_ms = std.time.milliTimestamp() + 1200;
}

pub fn showCopyToast(byte_count: usize) void {
    const msg = std.fmt.bufPrint(&g_copy_toast_buf, "{s}{d}{s}", .{ i18n.s().toast_copied_prefix, byte_count, i18n.s().toast_copied_bytes_suffix }) catch return;
    g_copy_toast_len = msg.len;
    g_copy_toast_until_ms = std.time.milliTimestamp() + COPY_TOAST_DURATION_MS;
}

pub fn showStatusToast(message: []const u8) void {
    const len = @min(message.len, g_copy_toast_buf.len);
    @memcpy(g_copy_toast_buf[0..len], message[0..len]);
    g_copy_toast_len = len;
    g_copy_toast_until_ms = std.time.milliTimestamp() + COPY_TOAST_DURATION_MS;
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

const transferToastVerb = transfer_toast_model.transferToastVerb;

const transfer_toast_model = @import("overlays/transfer_toast_model.zig");
const formatTransferToast = transfer_toast_model.formatTransferToast;

pub fn showTransferToast(
    kind: AppWindow.file_explorer.TransferKind,
    status: AppWindow.file_explorer.TransferStatus,
    message: []const u8,
) void {
    const msg = formatTransferToast(&g_transfer_toast_buf, kind, status, message) catch return;
    g_transfer_toast_len = msg.len;
    g_transfer_toast_status = status;
    g_transfer_toast_sticky = status == .in_progress;
    g_transfer_toast_clickable = kind == .download and status == .in_progress;
    if (status != .in_progress) transferCancelConfirmClose();
    g_transfer_toast_until_ms = std.time.milliTimestamp() + TRANSFER_TOAST_DURATION_MS;
}

test "overlays: command center Settings command opens settings page" {
    commandPaletteOpen();
    defer settingsPageClose();
    defer commandPaletteClose();

    executeCommand(.open_settings);

    try std.testing.expect(settingsPageVisible());
    try std.testing.expect(!commandPaletteVisible());
}

test "macOS UI smoke: command center opens settings and settings writes config" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);
    const config_dir = try std.fs.path.join(allocator, &.{ tmp_root, "config" });
    defer allocator.free(config_dir);

    platform_dirs.setTestConfigDirForCurrentThread(config_dir);
    defer platform_dirs.clearTestConfigDirForCurrentThread();

    try tmp.dir.makePath("config");
    {
        const file = try tmp.dir.createFile("config/config", .{});
        defer file.close();
        try file.writeAll(
            \\font-size = 13
            \\cursor-style-blink = true
            \\
        );
    }

    const previous_allocator = AppWindow.g_allocator;
    defer AppWindow.g_allocator = previous_allocator;
    AppWindow.g_allocator = allocator;

    commandPaletteOpen();
    defer commandPaletteClose();
    defer settingsPageClose();

    for ("settings") |c| commandPaletteInsertChar(c);
    try std.testing.expect(commandPaletteVisible());

    commandPaletteExecuteSelected();
    try std.testing.expect(!commandPaletteVisible());
    try std.testing.expect(settingsPageVisible());

    settingsPageHandleKey(.{ .key = .arrow_up });
    settingsPageHandleKey(.{ .key = .arrow_right });

    const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config" });
    defer allocator.free(config_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "font-size = 14") != null);
}

test "macOS UI smoke: settings toggles WeChat direct" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);
    const config_dir = try std.fs.path.join(allocator, &.{ tmp_root, "config" });
    defer allocator.free(config_dir);

    platform_dirs.setTestConfigDirForCurrentThread(config_dir);
    defer platform_dirs.clearTestConfigDirForCurrentThread();

    try tmp.dir.makePath("config");
    {
        const file = try tmp.dir.createFile("config/config", .{});
        defer file.close();
        try file.writeAll(
            \\weixin-direct-enabled = false
            \\
        );
    }

    const previous_allocator = AppWindow.g_allocator;
    defer AppWindow.g_allocator = previous_allocator;
    AppWindow.g_allocator = allocator;

    settingsPageOpen();
    defer settingsPageClose();

    executeSettingsAction(.toggle_weixin_direct);

    const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config" });
    defer allocator.free(config_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "weixin-direct-enabled = true") != null);
}

test "overlays: settings page caps visible rows and scrolls to keep focus visible on short windows" {
    const row_h = overlayRowHeight(42);
    const header_h = @round(18 + overlayLineHeight() * 2 + 12);
    const footer_h = @round(@max(52.0, overlayTextHeight() + 28.0));
    const base_h = header_h + footer_h;

    // A tall window fits every row, so no scrolling is needed.
    try std.testing.expectEqual(SETTINGS_ROW_COUNT, settingsRowCapacity(2000, base_h, row_h));

    // The reported short window (~522px tall) cannot fit all rows.
    const short_rows = settingsRowCapacity(522, base_h, row_h);
    try std.testing.expect(short_rows >= 1);
    try std.testing.expect(short_rows < SETTINGS_ROW_COUNT);

    const saved_focus = g_settings_focus;
    defer g_settings_focus = saved_focus;

    // Focus near the top keeps the list pinned to the top.
    g_settings_focus = 0;
    try std.testing.expectEqual(@as(usize, 0), settingsFirstVisibleRow(short_rows));

    // Focusing the last row (the close action that was clipped in the report)
    // scrolls just far enough to reveal it as the bottom visible row.
    g_settings_focus = SETTINGS_ROW_COUNT - 1;
    const scroll = settingsFirstVisibleRow(short_rows);
    try std.testing.expectEqual(SETTINGS_ROW_COUNT - short_rows, scroll);
    try std.testing.expect(g_settings_focus >= scroll);
    try std.testing.expect(g_settings_focus < scroll + short_rows);
}

test "overlays: command center mouse wheel moves selection without wrapping" {
    commandPaletteOpen();
    defer commandPaletteClose();

    // Default command mode with an empty filter lists many commands.
    const count = commandPaletteVisibleCount();
    try std.testing.expect(count >= 2);

    g_command_palette_selected = 0;
    // Positive delta scrolls toward the top; negative toward the bottom
    // (mirrors whatsNewHandleScroll / the wheel sign convention).
    commandPaletteHandleScroll(-1);
    try std.testing.expectEqual(@as(usize, 1), g_command_palette_selected);

    commandPaletteHandleScroll(1);
    try std.testing.expectEqual(@as(usize, 0), g_command_palette_selected);

    // At the top, scrolling up does not wrap to the bottom.
    commandPaletteHandleScroll(1);
    try std.testing.expectEqual(@as(usize, 0), g_command_palette_selected);

    // At the bottom, scrolling down does not wrap to the top.
    g_command_palette_selected = count - 1;
    commandPaletteHandleScroll(-1);
    try std.testing.expectEqual(count - 1, g_command_palette_selected);
}

test "overlays: session launcher caps rows and scrolls to keep selection visible on short windows" {
    const row_h = overlayRowHeight(38);
    const header_h = @round(18 + overlayLineHeight() * 2 + 12);
    const bottom_pad = @round(@max(20.0, overlayTextHeight() * 0.55));
    const base_h = header_h + bottom_pad;

    // The tallest mode is the AI form (12 fields + 3 action rows = 15 rows).
    const total: usize = AI_FIELD_COUNT + 3;

    // A tall window fits every row.
    try std.testing.expectEqual(total, sessionRowCapacity(2000, base_h, row_h, total));

    // The reported short window cannot fit all rows.
    const short_vis = sessionRowCapacity(522, base_h, row_h, total);
    try std.testing.expect(short_vis >= 1);
    try std.testing.expect(short_vis < total);

    // Selection near the top keeps the list pinned to the top.
    try std.testing.expectEqual(@as(usize, 0), sessionFirstVisibleRow(0, short_vis, total));

    // Selecting the last row scrolls just far enough to reveal it.
    const scroll = sessionFirstVisibleRow(total - 1, short_vis, total);
    try std.testing.expectEqual(total - short_vis, scroll);
    try std.testing.expect(total - 1 >= scroll);
    try std.testing.expect(total - 1 < scroll + short_vis);
}

test "overlays: session launcher mouse wheel moves selection without wrapping" {
    sessionLauncherOpen();
    defer sessionLauncherClose();

    const count = platform_pty_command.sessionLauncherRowCount();
    try std.testing.expect(count >= 2);

    g_session_launcher_selected = 0;
    sessionLauncherHandleScroll(-1);
    try std.testing.expectEqual(@as(usize, 1), g_session_launcher_selected);

    sessionLauncherHandleScroll(1);
    try std.testing.expectEqual(@as(usize, 0), g_session_launcher_selected);

    // At the top, scrolling up does not wrap.
    sessionLauncherHandleScroll(1);
    try std.testing.expectEqual(@as(usize, 0), g_session_launcher_selected);

    // At the bottom, scrolling down does not wrap.
    g_session_launcher_selected = count - 1;
    sessionLauncherHandleScroll(-1);
    try std.testing.expectEqual(count - 1, g_session_launcher_selected);
}

test "overlays: short-window overlay boxes stay within the window" {
    // A window far too short to hold the full box must still keep the panel
    // inside the content area (never paint past the bottom edge).
    {
        const layout = settingsLayout(800, 120, 0);
        try std.testing.expect(layout.box_top_px + layout.box_h <= 120);
    }
    {
        sessionLauncherOpen();
        defer sessionLauncherClose();
        const layout = sessionLayout(800, 120, 0);
        try std.testing.expect(layout.box_top_px + layout.box_h <= 120);
    }
    {
        commandPaletteOpen();
        defer commandPaletteClose();
        const layout = commandPaletteLayout(800, 120, 0);
        try std.testing.expect(layout.box_top_px + layout.box_h <= 120);
    }
}

test "overlays: active download toast can be clicked for interruption" {
    showTransferToast(.download, .in_progress, "file.txt - 1.5 MB/s");
    try std.testing.expect(transferToastHitTestForTest(780, 534, 800, 600));

    showTransferToast(.download, .success, "file.txt");
    try std.testing.expect(!transferToastHitTestForTest(780, 534, 800, 600));
}

test "overlays: transfer interruption prompt returns explicit actions" {
    transferCancelConfirmOpen();
    try std.testing.expect(transferCancelConfirmVisible());

    const layout = transferCancelConfirmLayoutForTest(800, 600);
    try std.testing.expectEqual(
        TransferCancelConfirmAction.interrupt,
        transferCancelConfirmExecuteAtForTest(
            layout.interrupt_x + 4,
            layout.interrupt_top_px + 4,
            800,
            600,
        ),
    );

    transferCancelConfirmOpen();
    try std.testing.expectEqual(
        TransferCancelConfirmAction.keep,
        transferCancelConfirmExecuteAtForTest(
            layout.keep_x + 4,
            layout.keep_top_px + 4,
            800,
            600,
        ),
    );
}

test "overlays: stored prompt URL does not affect latest release command URL" {
    showSshCwdFallbackPrompt();

    var latest_buf: [256]u8 = undefined;
    var prompt_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(update_check.latest_release_page_url, latestReleaseUrl(&latest_buf));
    try std.testing.expectEqualStrings(SSH_CWD_HELP_URL, storedPromptUrl(&prompt_buf));
}

test "overlays: SSH list filter matches server name prefixes case-insensitively" {
    g_ssh_profile_count = 3;
    g_ssh_profiles[0] = makeSshProfile("CPU2", "10.0.0.1", "user", "22");
    g_ssh_profiles[1] = makeSshProfile("GX15041", "10.0.0.2", "user", "22");
    g_ssh_profiles[2] = makeSshProfile("gxy", "10.0.0.3", "user", "22");
    g_ssh_list_mode = .manage;
    g_ssh_list_selected = 0;
    g_ssh_list_filter_len = 0;

    appendSshListFilterText("g");
    try std.testing.expectEqual(@as(usize, 2), sshVisibleProfileCount());
    try std.testing.expectEqual(@as(?usize, 1), sshVisibleProfileIndexAt(0));
    try std.testing.expectEqual(@as(?usize, 2), sshVisibleProfileIndexAt(1));
    try std.testing.expectEqual(@as(usize, 7), sshListRowCount());

    appendSshListFilterText("x1");
    try std.testing.expectEqual(@as(usize, 1), sshVisibleProfileCount());
    try std.testing.expectEqual(@as(?usize, 1), sshVisibleProfileIndexAt(0));
}

test "overlays: SSH manage list includes Load OpenSSH config action" {
    const saved_count = g_ssh_profile_count;
    const saved_mode = g_ssh_list_mode;
    const saved_filter_len = g_ssh_list_filter_len;
    const saved_selected = g_ssh_list_selected;
    defer {
        g_ssh_profile_count = saved_count;
        g_ssh_list_mode = saved_mode;
        g_ssh_list_filter_len = saved_filter_len;
        g_ssh_list_selected = saved_selected;
    }

    g_ssh_profile_count = 0;
    g_ssh_list_mode = .manage;
    g_ssh_list_filter_len = 0;
    g_ssh_list_selected = 0;
    try std.testing.expectEqual(@as(usize, 5), sshListRowCount());
    try std.testing.expectEqual(SshManageAction.load_openssh_config, sshManageActionForRow(0, sshVisibleProfileCount()));
    try std.testing.expectEqual(SshManageAction.new_ssh, sshManageActionForRow(1, sshVisibleProfileCount()));

    g_ssh_profile_count = 1;
    g_ssh_profiles[0] = makeSshProfile("GPU", "10.0.0.1", "user", "22");
    try std.testing.expectEqual(@as(usize, 6), sshListRowCount());
    try std.testing.expectEqual(SshManageAction.profile, sshManageActionForRow(0, sshVisibleProfileCount()));
    try std.testing.expectEqual(SshManageAction.load_openssh_config, sshManageActionForRow(1, sshVisibleProfileCount()));
}

test "overlays: OpenSSH import merge preserves existing password" {
    const saved_count = g_ssh_profile_count;
    defer {
        g_ssh_profile_count = saved_count;
    }

    g_ssh_profile_count = 1;
    g_ssh_profiles[0] = makeSshProfile("lab", "old.example", "olduser", "22");
    copySshProfileField(&g_ssh_profiles[0], .password, "secret");

    var candidate = openssh_config_import.Candidate{};
    opensshCandidateSetForTest(&candidate, .name, "lab");
    opensshCandidateSetForTest(&candidate, .host, "new.example");
    opensshCandidateSetForTest(&candidate, .user, "alice");
    opensshCandidateSetForTest(&candidate, .port, "2222");
    opensshCandidateSetForTest(&candidate, .proxy_jump, "jump.example");

    var stats = OpenSshImportStats{};
    mergeOpenSshCandidate(candidate, &stats);

    try std.testing.expectEqual(@as(usize, 1), stats.updated);
    try std.testing.expectEqualStrings("new.example", profileField(&g_ssh_profiles[0], .ip));
    try std.testing.expectEqualStrings("alice", profileField(&g_ssh_profiles[0], .user));
    try std.testing.expectEqualStrings("2222", profileField(&g_ssh_profiles[0], .port));
    try std.testing.expectEqualStrings("jump.example", profileField(&g_ssh_profiles[0], .proxy_jump));
    try std.testing.expectEqualStrings("secret", profileField(&g_ssh_profiles[0], .password));
}

test "overlays: SSH list filter backspace restores matching rows" {
    g_ssh_profile_count = 2;
    g_ssh_profiles[0] = makeSshProfile("GPU", "10.0.0.1", "user", "22");
    g_ssh_profiles[1] = makeSshProfile("CPU", "10.0.0.2", "user", "22");
    g_ssh_list_mode = .edit_select;
    g_ssh_list_selected = 0;
    g_ssh_list_filter_len = 0;

    appendSshListFilterText("gpux");
    try std.testing.expectEqual(@as(usize, 0), sshVisibleProfileCount());
    try std.testing.expectEqual(@as(usize, 1), sshListRowCount());

    backspaceSshListFilter();
    try std.testing.expectEqual(@as(usize, 1), sshVisibleProfileCount());
    try std.testing.expectEqual(@as(?usize, 0), sshVisibleProfileIndexAt(0));
    try std.testing.expectEqual(@as(usize, 2), sshListRowCount());
}

test "overlays: anyBlockingOverlayVisible reflects each modal overlay" {
    const saved_palette = g_command_palette_visible;
    const saved_settings = g_settings_visible;
    const saved_whats_new = g_whats_new_visible;
    const saved_close = g_window_close_confirm_visible;
    const saved_restore = g_restore_defaults_confirm_visible;
    const saved_transfer = g_transfer_cancel_confirm_visible;
    const saved_session = g_session_launcher_visible;
    const saved_ssh_list = g_ssh_list_visible;
    const saved_ssh_form = g_ssh_form_visible;
    const saved_ai_list = g_ai_list_visible;
    const saved_ai_form = g_ai_form_visible;
    const saved_ai_history = g_ai_history_source_visible;
    defer {
        g_command_palette_visible = saved_palette;
        g_settings_visible = saved_settings;
        g_whats_new_visible = saved_whats_new;
        g_window_close_confirm_visible = saved_close;
        g_restore_defaults_confirm_visible = saved_restore;
        g_transfer_cancel_confirm_visible = saved_transfer;
        g_session_launcher_visible = saved_session;
        g_ssh_list_visible = saved_ssh_list;
        g_ssh_form_visible = saved_ssh_form;
        g_ai_list_visible = saved_ai_list;
        g_ai_form_visible = saved_ai_form;
        g_ai_history_source_visible = saved_ai_history;
    }

    // Clear every blocking flag → nothing should report blocking.
    g_command_palette_visible = false;
    g_settings_visible = false;
    g_whats_new_visible = false;
    g_window_close_confirm_visible = false;
    g_restore_defaults_confirm_visible = false;
    g_transfer_cancel_confirm_visible = false;
    g_session_launcher_visible = false;
    g_ssh_list_visible = false;
    g_ssh_form_visible = false;
    g_ai_list_visible = false;
    g_ai_form_visible = false;
    g_ai_history_source_visible = false;
    try std.testing.expect(!anyBlockingOverlayVisible());

    // Each modal independently makes the webview need hiding.
    g_command_palette_visible = true;
    try std.testing.expect(anyBlockingOverlayVisible());
    g_command_palette_visible = false;

    g_settings_visible = true;
    try std.testing.expect(anyBlockingOverlayVisible());
    g_settings_visible = false;

    g_whats_new_visible = true;
    try std.testing.expect(anyBlockingOverlayVisible());
    g_whats_new_visible = false;

    g_window_close_confirm_visible = true;
    try std.testing.expect(anyBlockingOverlayVisible());
    g_window_close_confirm_visible = false;

    g_session_launcher_visible = true;
    try std.testing.expect(anyBlockingOverlayVisible());
    g_session_launcher_visible = false;

    try std.testing.expect(!anyBlockingOverlayVisible());
}

fn showVersionToast() void {
    const msg = app_metadata.versionLine(&g_copy_toast_buf) catch return;
    g_copy_toast_len = msg.len;
    g_copy_toast_until_ms = std.time.milliTimestamp() + COPY_TOAST_DURATION_MS;
}

pub fn showUpdateCheckingToast() void {
    showUpdatePrompt(.{ .state = .checking }, .none);
}

pub fn showSshCwdFallbackPrompt() void {
    const msg = std.fmt.bufPrint(&g_update_prompt_buf, "SSH cwd unknown; click for setup", .{}) catch return;
    g_update_prompt_len = msg.len;

    const url_len = @min(g_update_prompt_url_buf.len, SSH_CWD_HELP_URL.len);
    @memcpy(g_update_prompt_url_buf[0..url_len], SSH_CWD_HELP_URL[0..url_len]);
    g_update_prompt_url_len = url_len;
    g_update_prompt_clickable = true;
    g_update_prompt_action = .open_release;
    g_update_prompt_until_ms = std.time.milliTimestamp() + UPDATE_PROMPT_DURATION_MS;
}

pub fn showUpdateCheckResult(result: update_check.CheckResult) void {
    if (result.state == .idle) return;
    showUpdatePrompt(result, updatePromptActionForResult(result));
}

const updatePromptActionForResult = update_prompt_model.updatePromptActionForResult;

fn showUpdatePrompt(result: update_check.CheckResult, action: UpdatePromptAction) void {
    var status_buf: [96]u8 = undefined;
    const status = update_check.formatStatusMessage(&status_buf, result) catch return;
    const suffix = switch (action) {
        .download_update => "  click to download",
        .open_release => "  click to open",
        .none => "",
    };
    const msg = std.fmt.bufPrint(&g_update_prompt_buf, "{s}{s}", .{ status, suffix }) catch return;

    g_update_prompt_len = msg.len;
    g_update_prompt_url_len = 0;
    if (action == .open_release and result.release_url.len > 0) {
        const url_len = @min(g_update_prompt_url_buf.len, result.release_url.len);
        @memcpy(g_update_prompt_url_buf[0..url_len], result.release_url[0..url_len]);
        g_update_prompt_url_len = url_len;
    }
    g_update_prompt_clickable = action != .none;
    g_update_prompt_action = action;
    g_update_prompt_until_ms = std.time.milliTimestamp() + if (action != .none) UPDATE_PROMPT_DURATION_MS else UPDATE_STATUS_DURATION_MS;
}

fn showUpdateDownloadUnavailableToast() void {
    const msg = std.fmt.bufPrint(&g_update_prompt_buf, "No update ready; run Check for Updates", .{}) catch return;
    g_update_prompt_len = msg.len;
    g_update_prompt_url_len = 0;
    g_update_prompt_clickable = false;
    g_update_prompt_action = .none;
    g_update_prompt_until_ms = std.time.milliTimestamp() + UPDATE_STATUS_DURATION_MS;
}

pub fn showCloseShortcutConfirm(duration_ms: i64) void {
    g_close_shortcut_confirm_until_ms = std.time.milliTimestamp() + duration_ms;
}

pub fn renderWindowCloseConfirm(window_width: f32, window_height: f32) void {
    if (!g_window_close_confirm_visible) return;

    const layout = windowCloseConfirmLayout(window_width, window_height);
    const panel_y = @round(window_height - layout.panel_top_px - layout.panel_h);
    const close_y = @round(window_height - layout.close_top_px - layout.close_h);
    const cancel_y = @round(window_height - layout.cancel_top_px - layout.cancel_h);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel = mixColor(bg, fg, 0.050);
    const panel_top = mixColor(bg, fg, 0.073);
    const panel_border = mixColor(bg, fg, 0.24);
    const quiet_border = mixColor(bg, fg, 0.15);
    const muted = mixColor(bg, fg, 0.56);
    const body = mixColor(bg, fg, 0.80);
    const danger = .{ 0.86, 0.22, 0.20 };
    const danger_soft = mixColor(bg, danger, 0.20);
    const warning = .{ 0.95, 0.62, 0.18 };

    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.46);
    renderRoundedQuadAlpha(layout.panel_x + 10, panel_y - 10, layout.panel_w, layout.panel_h, 13, .{ 0.0, 0.0, 0.0 }, 0.26);
    renderRoundedQuadAlpha(layout.panel_x - 1, panel_y - 1, layout.panel_w + 2, layout.panel_h + 2, 13, panel_border, 0.42);
    renderRoundedQuadAlpha(layout.panel_x, panel_y, layout.panel_w, layout.panel_h, 12, panel, 0.99);
    renderRoundedQuadAlpha(layout.panel_x + 1, panel_y + layout.panel_h - 76, layout.panel_w - 2, 75, 12, panel_top, 0.78);
    ui_pipeline.fillQuadAlpha(layout.panel_x + 1, panel_y + layout.panel_h - 76, layout.panel_w - 2, 1, quiet_border, 0.40);
    renderRoundedQuadAlpha(layout.panel_x, panel_y, 5, layout.panel_h, 12, danger, 0.84);

    const pad: f32 = 34;
    const icon_size: f32 = 34;
    const icon_x = layout.panel_x + pad;
    const title_y = @round(panel_y + layout.panel_h - 52);
    const icon_y = @round(title_y - (icon_size - overlayTextHeight()) / 2.0 - 2.0);
    renderRoundedQuadAlpha(icon_x, icon_y, icon_size, icon_size, 17, warning, 0.18);
    renderRoundedQuadAlpha(icon_x + 5, icon_y + 5, icon_size - 10, icon_size - 10, 12, warning, 0.88);
    renderTitlebarTextStrong("!", icon_x + (icon_size - measureTitlebarText("!")) / 2, rowTextY(icon_y, icon_size), .{ 0.11, 0.09, 0.07 });

    const text_x = icon_x + icon_size + 18;
    const text_right = layout.panel_x + layout.panel_w - pad;
    const title_text = switch (g_close_confirm_variant) {
        .running_program => "A program is still running",
        .window_generic => "Close WispTerm?",
        .terminal_split => "Close this terminal?",
    };
    const body_text = switch (g_close_confirm_variant) {
        .running_program => "Closing now will end it.",
        .window_generic => "Running panels in this window will be terminated.",
        .terminal_split => "This terminal pane will be closed.",
    };
    const hint_text = "Press Enter or Close to proceed, Esc to cancel.";
    renderTitlebarTextStrongLimited(title_text, text_x, title_y, fg, text_right - text_x);

    const body_y = title_y - overlayTextHeight() - 16;
    renderTitlebarTextLimited(body_text, text_x, body_y, body, text_right - text_x);

    const hint_y = body_y - overlayTextHeight() - 8;
    renderTitlebarTextLimited(hint_text, text_x, hint_y, muted, text_right - text_x);

    const footer_y = close_y + layout.close_h + 20;
    ui_pipeline.fillQuadAlpha(layout.panel_x + 5, footer_y, layout.panel_w - 5, 1, quiet_border, 0.46);

    renderRoundedQuadAlpha(layout.close_x - 1, close_y - 1, layout.close_w + 2, layout.close_h + 2, 8, danger, 0.48);
    renderRoundedQuadAlpha(layout.close_x, close_y, layout.close_w, layout.close_h, 7, danger_soft, 0.96);
    const close_label = "Close";
    renderTitlebarTextStrong(close_label, layout.close_x + (layout.close_w - measureTitlebarText(close_label)) / 2, rowTextY(close_y, layout.close_h), .{ 1.0, 0.72, 0.68 });

    renderRoundedQuadAlpha(layout.cancel_x - 1, cancel_y - 1, layout.cancel_w + 2, layout.cancel_h + 2, 8, mixColor(accent, fg, 0.20), 0.76);
    renderRoundedQuadAlpha(layout.cancel_x, cancel_y, layout.cancel_w, layout.cancel_h, 7, mixColor(bg, accent, 0.22), 0.96);
    const cancel_label = "Cancel";
    renderTitlebarTextStrong(cancel_label, layout.cancel_x + (layout.cancel_w - measureTitlebarText(cancel_label)) / 2, rowTextY(cancel_y, layout.cancel_h), mixColor(fg, accent, 0.18));
}

pub fn renderRestoreDefaultsConfirm(window_width: f32, window_height: f32) void {
    if (!g_restore_defaults_confirm_visible) return;

    // Reuses the window-close panel/button geometry; close_* is the Restore
    // button, cancel_* is Cancel.
    const layout = windowCloseConfirmLayout(window_width, window_height);
    const panel_y = @round(window_height - layout.panel_top_px - layout.panel_h);
    const apply_y = @round(window_height - layout.close_top_px - layout.close_h);
    const cancel_y = @round(window_height - layout.cancel_top_px - layout.cancel_h);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel = mixColor(bg, fg, 0.050);
    const panel_top = mixColor(bg, fg, 0.073);
    const panel_border = mixColor(bg, fg, 0.24);
    const quiet_border = mixColor(bg, fg, 0.15);
    const muted = mixColor(bg, fg, 0.56);
    const body = mixColor(bg, fg, 0.80);
    const accent_soft = mixColor(bg, accent, 0.20);

    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.46);
    renderRoundedQuadAlpha(layout.panel_x + 10, panel_y - 10, layout.panel_w, layout.panel_h, 13, .{ 0.0, 0.0, 0.0 }, 0.26);
    renderRoundedQuadAlpha(layout.panel_x - 1, panel_y - 1, layout.panel_w + 2, layout.panel_h + 2, 13, panel_border, 0.42);
    renderRoundedQuadAlpha(layout.panel_x, panel_y, layout.panel_w, layout.panel_h, 12, panel, 0.99);
    renderRoundedQuadAlpha(layout.panel_x + 1, panel_y + layout.panel_h - 76, layout.panel_w - 2, 75, 12, panel_top, 0.78);
    ui_pipeline.fillQuadAlpha(layout.panel_x + 1, panel_y + layout.panel_h - 76, layout.panel_w - 2, 1, quiet_border, 0.40);
    renderRoundedQuadAlpha(layout.panel_x, panel_y, 5, layout.panel_h, 12, accent, 0.84);

    const pad: f32 = 34;
    const icon_size: f32 = 34;
    const icon_x = layout.panel_x + pad;
    const title_y = @round(panel_y + layout.panel_h - 52);
    const icon_y = @round(title_y - (icon_size - overlayTextHeight()) / 2.0 - 2.0);
    renderRoundedQuadAlpha(icon_x, icon_y, icon_size, icon_size, 17, accent, 0.18);
    renderRoundedQuadAlpha(icon_x + 5, icon_y + 5, icon_size - 10, icon_size - 10, 12, accent, 0.88);

    const text_x = icon_x + icon_size + 18;
    const text_right = layout.panel_x + layout.panel_w - pad;
    renderTitlebarTextStrongLimited(i18n.s().restore_defaults_title, text_x, title_y, fg, text_right - text_x);

    const body_y = title_y - overlayTextHeight() - 16;
    renderTitlebarTextLimited(i18n.s().restore_defaults_body, text_x, body_y, body, text_right - text_x);

    const hint_y = body_y - overlayTextHeight() - 8;
    renderTitlebarTextLimited(i18n.s().restore_defaults_hint, text_x, hint_y, muted, text_right - text_x);

    const footer_y = apply_y + layout.close_h + 20;
    ui_pipeline.fillQuadAlpha(layout.panel_x + 5, footer_y, layout.panel_w - 5, 1, quiet_border, 0.46);

    renderRoundedQuadAlpha(layout.close_x - 1, apply_y - 1, layout.close_w + 2, layout.close_h + 2, 8, mixColor(accent, fg, 0.20), 0.80);
    renderRoundedQuadAlpha(layout.close_x, apply_y, layout.close_w, layout.close_h, 7, accent_soft, 0.96);
    const apply_label = i18n.s().restore_defaults_apply;
    renderTitlebarTextStrong(apply_label, layout.close_x + (layout.close_w - measureTitlebarText(apply_label)) / 2, rowTextY(apply_y, layout.close_h), mixColor(fg, accent, 0.18));

    renderRoundedQuadAlpha(layout.cancel_x - 1, cancel_y - 1, layout.cancel_w + 2, layout.cancel_h + 2, 8, quiet_border, 0.76);
    renderRoundedQuadAlpha(layout.cancel_x, cancel_y, layout.cancel_w, layout.cancel_h, 7, mixColor(bg, fg, 0.10), 0.96);
    const cancel_label = i18n.s().restore_defaults_cancel;
    renderTitlebarTextStrong(cancel_label, layout.cancel_x + (layout.cancel_w - measureTitlebarText(cancel_label)) / 2, rowTextY(cancel_y, layout.cancel_h), body);
}

pub fn renderTransferCancelConfirm(window_width: f32, window_height: f32) void {
    if (!g_transfer_cancel_confirm_visible) return;

    const layout = transferCancelConfirmLayout(window_width, window_height);
    const panel_y = @round(window_height - layout.panel_top_px - layout.panel_h);
    const interrupt_y = @round(window_height - layout.interrupt_top_px - layout.interrupt_h);
    const keep_y = @round(window_height - layout.keep_top_px - layout.keep_h);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const warning = .{ 1.0, 0.72, 0.28 };
    const danger = .{ 0.90, 0.22, 0.18 };
    const panel = mixColor(bg, fg, 0.060);
    const panel_border = mixColor(bg, fg, 0.22);
    const muted = mixColor(bg, fg, 0.58);

    renderRoundedQuadAlpha(layout.panel_x + 6, panel_y - 6, layout.panel_w, layout.panel_h, 11, .{ 0.0, 0.0, 0.0 }, 0.22);
    renderRoundedQuadAlpha(layout.panel_x - 1, panel_y - 1, layout.panel_w + 2, layout.panel_h + 2, 11, panel_border, 0.48);
    renderRoundedQuadAlpha(layout.panel_x, panel_y, layout.panel_w, layout.panel_h, 10, panel, 0.99);
    renderRoundedQuadAlpha(layout.panel_x, panel_y, 4, layout.panel_h, 10, warning, 0.86);

    const pad: f32 = 24;
    const title_y = @round(panel_y + layout.panel_h - 38);
    const text_x = layout.panel_x + pad;
    const text_right = layout.panel_x + layout.panel_w - pad;
    renderTitlebarTextStrongLimited("Interrupt download?", text_x, title_y, fg, text_right - text_x);
    renderTitlebarTextLimited(
        "The active file transfer will be stopped.",
        text_x,
        title_y - overlayTextHeight() - 10,
        muted,
        text_right - text_x,
    );

    renderRoundedQuadAlpha(layout.keep_x - 1, keep_y - 1, layout.keep_w + 2, layout.keep_h + 2, 8, mixColor(accent, fg, 0.20), 0.58);
    renderRoundedQuadAlpha(layout.keep_x, keep_y, layout.keep_w, layout.keep_h, 7, mixColor(bg, accent, 0.18), 0.96);
    const keep_label = "Keep";
    renderTitlebarTextStrong(keep_label, layout.keep_x + (layout.keep_w - measureTitlebarText(keep_label)) / 2, rowTextY(keep_y, layout.keep_h), mixColor(fg, accent, 0.16));

    renderRoundedQuadAlpha(layout.interrupt_x - 1, interrupt_y - 1, layout.interrupt_w + 2, layout.interrupt_h + 2, 8, danger, 0.52);
    renderRoundedQuadAlpha(layout.interrupt_x, interrupt_y, layout.interrupt_w, layout.interrupt_h, 7, mixColor(bg, danger, 0.23), 0.98);
    const interrupt_label = "Interrupt";
    renderTitlebarTextStrong(interrupt_label, layout.interrupt_x + (layout.interrupt_w - measureTitlebarText(interrupt_label)) / 2, rowTextY(interrupt_y, layout.interrupt_h), .{ 1.0, 0.70, 0.66 });
}

pub fn renderCloseShortcutConfirm(window_width: f32, window_height: f32) void {
    _ = window_height;
    if (std.time.milliTimestamp() >= g_close_shortcut_confirm_until_ms) return;

    var shortcut_buf: [64]u8 = undefined;
    const shortcut = keybind.formatActionShortcut(&AppWindow.g_keybinds, .close_panel_or_tab, &shortcut_buf) orelse "close shortcut";
    var text_buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Press {s} again to close WispTerm", .{shortcut}) catch "Press close shortcut again to close WispTerm";

    const pad_h: f32 = 18;
    const pad_v: f32 = 8;
    const line_h = font.g_titlebar_cell_height + pad_v * 2;
    const text_w = measureTitlebarText(text);
    const bg_w = text_w + pad_h * 2;
    const bg_x = @round((window_width - bg_w) / 2);
    const bg_y: f32 = 60;

    ui_pipeline.fillQuad(bg_x, bg_y, bg_w, line_h, .{ 0.18, 0.11, 0.08 });
    ui_pipeline.fillQuad(bg_x, bg_y + line_h - 2, bg_w, 2, .{ 0.86, 0.48, 0.20 });
    renderTitlebarText(text, bg_x + pad_h, bg_y + pad_v, .{ 1.0, 0.82, 0.56 });
}

pub fn renderCopyToast(window_width: f32, window_height: f32) void {
    _ = window_height;
    const now = std.time.milliTimestamp();
    if (now >= g_copy_toast_until_ms) return;
    if (g_copy_toast_len == 0) return;

    const text = g_copy_toast_buf[0..g_copy_toast_len];
    const pad_h: f32 = 14;
    const pad_v: f32 = 6;
    const line_h = font.g_titlebar_cell_height + pad_v * 2;

    const text_width = measureTitlebarText(text);

    const bg_w = text_width + pad_h * 2;
    const bg_x = (window_width - bg_w) / 2;
    const bg_y: f32 = 60; // GL y=0 at bottom — float above the prompt area

    ui_pipeline.fillQuad(bg_x, bg_y, bg_w, line_h, .{ 0.10, 0.14, 0.10 });

    const x = bg_x + pad_h;
    const y = bg_y + pad_v;
    const text_color: [3]f32 = .{ 0.55, 0.95, 0.55 };
    renderTitlebarText(text, x, y, text_color);
}

fn transferToastLayout(window_width: f32, text: []const u8) DebugLineRect {
    const pad_h: f32 = 14;
    const pad_v: f32 = 6;
    const line_h = font.g_titlebar_cell_height + pad_v * 2;
    const text_width = measureTitlebarText(text);
    const max_w = @max(180.0, window_width - 32.0);
    const bg_w = @min(text_width + pad_h * 2, max_w);
    const bg_x = @round(@max(12.0, window_width - bg_w - 16.0));
    return .{ .x = bg_x, .y = 60, .w = bg_w, .h = line_h };
}

pub fn transferToastHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32) bool {
    if (!g_transfer_toast_clickable) return false;
    if (g_transfer_toast_len == 0) return false;
    if (std.time.milliTimestamp() >= g_transfer_toast_until_ms and !g_transfer_toast_sticky) return false;

    const rect = transferToastLayout(window_width, g_transfer_toast_buf[0..g_transfer_toast_len]);
    const x: f32 = @floatCast(xpos);
    const y_from_bottom = window_height - @as(f32, @floatCast(ypos));
    return x >= rect.x and x <= rect.x + rect.w and
        y_from_bottom >= rect.y and y_from_bottom <= rect.y + rect.h;
}

fn transferToastHitTestForTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32) bool {
    return transferToastHitTest(xpos, ypos, window_width, window_height);
}

pub fn renderTransferToast(window_width: f32, window_height: f32) void {
    _ = window_height;
    const now = std.time.milliTimestamp();
    if (!g_transfer_toast_sticky and now >= g_transfer_toast_until_ms) return;
    if (g_transfer_toast_len == 0) return;

    const text = g_transfer_toast_buf[0..g_transfer_toast_len];
    const pad_h: f32 = 14;
    const pad_v: f32 = 6;
    const layout = transferToastLayout(window_width, text);

    const accent = switch (g_transfer_toast_status) {
        .in_progress => AppWindow.g_theme.cursor_color,
        .success => .{ 0.24, 1.0, 0.44 },
        .failed => .{ 1.0, 0.30, 0.28 },
        .cancelled => .{ 1.0, 0.72, 0.28 },
        .idle => AppWindow.g_theme.foreground,
    };
    const bg = mixColor(AppWindow.g_theme.background, accent, 0.16);
    ui_pipeline.fillQuadAlpha(layout.x, layout.y, layout.w, layout.h, bg, 0.96);
    ui_pipeline.fillQuadAlpha(layout.x, layout.y, 3, layout.h, accent, 0.88);
    if (g_transfer_toast_clickable) {
        ui_pipeline.fillQuadAlpha(layout.x, layout.y + layout.h - 2, layout.w, 2, accent, 0.64);
    }

    const text_x = layout.x + pad_h;
    const y = layout.y + pad_v;
    renderTitlebarTextStrongLimited(text, text_x, y, accent, layout.w - pad_h * 2);
}

fn whatsNewNotes() []const u8 {
    return app_metadata.release_notes;
}

pub fn showWhatsNew() void {
    g_whats_new_scroll = 0;
    g_whats_new_visible = true;
}

pub fn hideWhatsNew() void {
    g_whats_new_visible = false;
}

pub fn whatsNewVisible() bool {
    return g_whats_new_visible;
}

/// True when a full-window GPU overlay is up that the native browser/Jupyter
/// webview would otherwise occlude. The webview is an OS-level control
/// composited ABOVE the GPU surface, so in full mode it covers the entire
/// content area — including these modals. Callers (browser_panel.sync) hide the
/// webview while this holds so the command center, settings, confirm dialogs,
/// etc. stay visible.
pub fn anyBlockingOverlayVisible() bool {
    return commandPaletteVisible() or
        settingsPageVisible() or
        sessionLauncherVisible() or
        whatsNewVisible() or
        windowCloseConfirmVisible() or
        restoreDefaultsConfirmVisible() or
        transferCancelConfirmVisible();
}

/// 脏门控用：是否有任何 overlay 时间动画处于活动状态。
/// 与 `anyBlockingOverlayVisible`（仅模态遮挡 webview）不同 —— 这里要尽量全，
/// 漏判会导致 overlay 动画卡住，所以宁可多列。静态打开态 overlay 不放这里；
/// 打开/输入/关闭时已有 g_force_rebuild 触发一帧。`now` = std.time.milliTimestamp()。
pub fn anyOverlayActive(now: i64) bool {
    // 时间动画：到期前每帧需持续渲染
    if (now < g_copy_toast_until_ms) return true;
    if (now < g_transfer_toast_until_ms) return true;
    if (now < g_update_prompt_until_ms) return true;
    if (now < g_close_shortcut_confirm_until_ms) return true;
    if (now < g_remote_key_copied_until_ms) return true;
    if (now < resize.g_split_resize_overlay_until) return true;

    // Copilot edge handle: shimmer / reveal-fade / hover-tooltip dwell.
    if (copilot_edge_handle.isAnimating()) return true;

    // FPS 叠层开启时每秒刷新
    if (g_debug_fps) return true;

    return false;
}

pub fn whatsNewHandleKey(ev: input_key.KeyEvent) void {
    if (!g_whats_new_visible) return;
    switch (ev.key) {
        .escape, .enter => hideWhatsNew(),
        .page_up => g_whats_new_scroll -= 10,
        .page_down => g_whats_new_scroll += 10,
        .arrow_up => g_whats_new_scroll -= 1,
        .arrow_down => g_whats_new_scroll += 1,
        .home => g_whats_new_scroll = 0,
        .end => g_whats_new_scroll = std.math.maxInt(i32),
        else => {},
    }
}

pub fn whatsNewHandleScroll(delta_y: f64) void {
    if (!g_whats_new_visible) return;
    g_whats_new_scroll += if (delta_y > 0) @as(i64, -3) else 3;
}

fn openWhatsNewRelease() void {
    const allocator = AppWindow.g_allocator orelse return;
    var url_buf: [256]u8 = undefined;
    const url = whats_new_model.releaseTagUrl(&url_buf, app_metadata.version);
    _ = platform_open_url.open(allocator, .{ .url = url });
}

/// Returns true if the click was consumed by the modal (always true while open,
/// so clicks never fall through to the terminal underneath).
pub fn whatsNewExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32) bool {
    if (!g_whats_new_visible) return false;
    const layout = whatsNewLayout(window_width, window_height);
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    switch (whats_new_model.buttonActionAt(layout, px, py)) {
        .view_on_github => {
            openWhatsNewRelease();
            hideWhatsNew();
        },
        .close => hideWhatsNew(),
        .none => {
            // A click outside the panel dismisses; inside is ignored (so users can
            // click/select within the modal without closing it).
            if (!layout.panel.contains(px, py)) hideWhatsNew();
        },
    }
    return true;
}

fn whatsNewTrimV(v: []const u8) []const u8 {
    return std.mem.trimLeft(u8, v, "vV");
}

fn whatsNewLineHeight() f32 {
    return @round(@max(@as(f32, 24), font.g_titlebar_cell_height + 6));
}

const WHATS_NEW_VIEW_LABEL = "View on GitHub";
const WHATS_NEW_OK_LABEL = "OK";

fn whatsNewButtonMetrics() whats_new_model.ButtonMetrics {
    return .{
        .view_w = @round(measureTitlebarText(WHATS_NEW_VIEW_LABEL) + 44),
        .close_w = @round(measureTitlebarText(WHATS_NEW_OK_LABEL) + 42),
    };
}

fn whatsNewLayout(window_width: f32, window_height: f32) whats_new_model.Layout {
    return whats_new_model.computeLayoutWithButtons(window_width, window_height, whatsNewLineHeight(), whatsNewButtonMetrics());
}

fn topRectY(window_height: f32, rect: whats_new_model.Rect) f32 {
    return window_height - rect.y - rect.h;
}

fn drawWhatsNewButton(rect: whats_new_model.Rect, label: []const u8, window_height: f32, border: [3]f32, fill: [3]f32, text: [3]f32, strong: bool) void {
    const y_bu = window_height - rect.y - rect.h;
    renderRoundedQuadAlpha(rect.x - 1, y_bu - 1, rect.w + 2, rect.h + 2, 8, border, 0.64);
    renderRoundedQuadAlpha(rect.x, y_bu, rect.w, rect.h, 7, fill, 0.96);
    const tw = measureTitlebarText(label);
    const tx = if (tw <= rect.w - 18) rect.x + (rect.w - tw) / 2 else rect.x + 12;
    const ty = rowTextY(y_bu, rect.h);
    if (strong) {
        renderTitlebarTextStrongLimited(label, tx, ty, text, rect.x + rect.w - tx - 12);
    } else {
        renderTitlebarTextLimited(label, tx, ty, text, rect.x + rect.w - tx - 12);
    }
}

const WhatsNewRows = struct {
    row_index: usize = 0,
    drawn: usize = 0,
    scroll: usize = 0,
};

fn renderWhatsNewWrappedLine(
    layout: whats_new_model.Layout,
    window_height: f32,
    text: []const u8,
    x: f32,
    color: [3]f32,
    strong: bool,
    wrap_cols: usize,
    line_h: f32,
    rows_state: *WhatsNewRows,
) bool {
    const rows = whats_new_model.lineRows(text.len, wrap_cols);
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        defer rows_state.row_index += 1;
        if (rows_state.row_index < rows_state.scroll) continue;
        if (rows_state.drawn >= layout.visible_rows) return false;

        const start = r * wrap_cols;
        const end = @min(text.len, start + wrap_cols);
        const slice = if (start < text.len) text[start..end] else "";
        const top = layout.content.y + @as(f32, @floatFromInt(rows_state.drawn)) * line_h;
        const row_y = window_height - top - line_h;
        const text_y = rowTextY(row_y, line_h);
        if (slice.len > 0) {
            const max_w = layout.content.x + layout.content.w - x;
            if (strong) {
                renderTitlebarTextStrongLimited(slice, x, text_y, color, max_w);
            } else {
                renderTitlebarTextLimited(slice, x, text_y, color, max_w);
            }
        }
        rows_state.drawn += 1;
    }
    return true;
}

fn whatsNewHighlightsRows(highlights: whats_new_model.Highlights, wrap_cols: usize) usize {
    if (highlights.len == 0) return 0;
    var total: usize = whats_new_model.lineRows("Highlights".len, wrap_cols);
    var i: usize = 0;
    while (i < highlights.len) : (i += 1) {
        total += whats_new_model.lineRows(highlights.items[i].len + 2, wrap_cols);
    }
    return total + 1; // spacer after highlights
}

fn renderWhatsNewHighlights(
    layout: whats_new_model.Layout,
    window_height: f32,
    highlights: whats_new_model.Highlights,
    wrap_cols: usize,
    line_h: f32,
    rows_state: *WhatsNewRows,
    heading_color: [3]f32,
    accent: [3]f32,
    body: [3]f32,
) bool {
    if (highlights.len == 0) return true;
    if (!renderWhatsNewWrappedLine(layout, window_height, "Highlights", layout.content.x, heading_color, true, wrap_cols, line_h, rows_state)) return false;

    var i: usize = 0;
    while (i < highlights.len) : (i += 1) {
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "* {s}", .{highlights.items[i]}) catch highlights.items[i];
        if (!renderWhatsNewWrappedLine(layout, window_height, line, layout.content.x + 16, mixColor(body, accent, 0.08), false, wrap_cols, line_h, rows_state)) return false;
    }
    return renderWhatsNewWrappedLine(layout, window_height, "", layout.content.x, body, false, wrap_cols, line_h, rows_state);
}

fn renderWhatsNewBody(
    layout: whats_new_model.Layout,
    window_height: f32,
    notes: []const u8,
    wrap_cols: usize,
    line_h: f32,
    rows_state: *WhatsNewRows,
    heading_color: [3]f32,
    body: [3]f32,
    muted: [3]f32,
) void {
    var in_code = false;
    var it = std.mem.splitScalar(u8, notes, '\n');
    while (it.next()) |raw| {
        var cbuf: [1024]u8 = undefined;
        const cleaned = md.cleanedLine(&cbuf, raw, in_code);
        if (cleaned.style == .fence) {
            in_code = !in_code;
            if (!renderWhatsNewWrappedLine(layout, window_height, "", layout.content.x, muted, false, wrap_cols, line_h, rows_state)) return;
            continue;
        }

        const x = switch (cleaned.style) {
            .list, .quote, .code => layout.content.x + 16,
            else => layout.content.x,
        };
        const color = switch (cleaned.style) {
            .heading => heading_color,
            .quote, .code => muted,
            else => body,
        };
        const strong = cleaned.style == .heading;
        if (!renderWhatsNewWrappedLine(layout, window_height, cleaned.text, x, color, strong, wrap_cols, line_h, rows_state)) return;
    }
}

pub fn renderWhatsNew(window_width: f32, window_height: f32) void {
    if (!g_whats_new_visible) return;

    const line_h = whatsNewLineHeight();
    const layout = whatsNewLayout(window_width, window_height);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel = mixColor(bg, fg, 0.05);
    const panel_top = mixColor(bg, fg, 0.075);
    const panel_footer = mixColor(bg, fg, 0.060);
    const panel_border = mixColor(bg, fg, 0.24);
    const quiet_border = mixColor(bg, fg, 0.15);
    const muted = mixColor(bg, fg, 0.56);
    const body = mixColor(bg, fg, 0.82);
    const heading = mixColor(fg, accent, 0.12);

    // Background scrim + panel (panel drawn in bottom-up space).
    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.46);
    const panel_y_bu = window_height - layout.panel.y - layout.panel.h;
    renderRoundedQuadAlpha(layout.panel.x + 10, panel_y_bu - 10, layout.panel.w, layout.panel.h, 13, .{ 0.0, 0.0, 0.0 }, 0.26);
    renderRoundedQuadAlpha(layout.panel.x - 1, panel_y_bu - 1, layout.panel.w + 2, layout.panel.h + 2, 13, panel_border, 0.42);
    renderRoundedQuadAlpha(layout.panel.x, panel_y_bu, layout.panel.w, layout.panel.h, 12, panel, 0.99);
    renderRoundedQuadAlpha(layout.panel.x, panel_y_bu, 5, layout.panel.h, 12, accent, 0.78);

    const header_y = topRectY(window_height, layout.header);
    const footer_y = topRectY(window_height, layout.footer);
    renderRoundedQuadAlpha(layout.header.x + 1, header_y, layout.header.w - 2, layout.header.h - 1, 12, panel_top, 0.76);
    ui_pipeline.fillQuadAlpha(layout.header.x + 5, header_y, layout.header.w - 5, 1, quiet_border, 0.45);
    ui_pipeline.fillQuadAlpha(layout.footer.x + 5, footer_y + layout.footer.h - 1, layout.footer.w - 5, 1, quiet_border, 0.50);
    ui_pipeline.fillQuadAlpha(layout.footer.x + 1, footer_y, layout.footer.w - 2, layout.footer.h, panel_footer, 0.45);

    const notes = whatsNewNotes();
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "WispTerm v{s}", .{whatsNewTrimV(app_metadata.version)}) catch "WispTerm";
    const title_top = layout.header.y + 20;
    const header_right = layout.title_close_btn.x - 16;
    renderTitlebarTextStrongLimited(title, layout.content.x, textYFromTop(window_height, title_top), fg, header_right - layout.content.x);

    const close_y = topRectY(window_height, layout.title_close_btn);
    titlebar.renderCloseIcon(layout.title_close_btn.x, close_y, layout.title_close_btn.w, layout.title_close_btn.h, muted);

    if (notes.len > 0) {
        var summary_buf: [512]u8 = undefined;
        const summary = whats_new_model.summaryText(&summary_buf, notes);
        if (summary.len > 0) {
            const subtitle_top = title_top + overlayTextHeight() + 12;
            renderTitlebarTextLimited(summary, layout.content.x, textYFromTop(window_height, subtitle_top), body, header_right - layout.content.x);
        }
    }

    if (notes.len == 0) {
        renderTitlebarText("Release notes unavailable for this version.", layout.content.x, window_height - layout.content.y - line_h, muted);
    } else {
        const adv = @max(@as(f32, 1), titlebar.titlebarGlyphAdvance('M'));
        var wrap_cols: usize = @intFromFloat(layout.content.w / adv);
        if (wrap_cols < whats_new_model.MIN_WRAP_COLS) wrap_cols = whats_new_model.MIN_WRAP_COLS;

        const body_notes = whats_new_model.bodyNotes(notes);
        var summary_buf: [512]u8 = undefined;
        const summary = whats_new_model.summaryText(&summary_buf, notes);
        var highlights_buf: [512]u8 = undefined;
        const highlights = whats_new_model.highlightClauses(&highlights_buf, summary);

        const total = whatsNewHighlightsRows(highlights, wrap_cols) + whats_new_model.totalRows(body_notes, wrap_cols);
        const scroll = whats_new_model.clampScroll(g_whats_new_scroll, total, layout.visible_rows);
        g_whats_new_scroll = @intCast(scroll);

        var rows_state: WhatsNewRows = .{ .scroll = scroll };
        if (renderWhatsNewHighlights(layout, window_height, highlights, wrap_cols, line_h, &rows_state, heading, accent, body)) {
            renderWhatsNewBody(layout, window_height, body_notes, wrap_cols, line_h, &rows_state, heading, body, muted);
        }
    }

    // Footer buttons.
    drawWhatsNewButton(layout.view_btn, WHATS_NEW_VIEW_LABEL, window_height, quiet_border, mixColor(bg, fg, 0.10), body, false);
    drawWhatsNewButton(layout.close_btn, WHATS_NEW_OK_LABEL, window_height, mixColor(accent, fg, 0.22), mixColor(bg, accent, 0.24), mixColor(fg, accent, 0.16), true);
}

pub fn renderUpdatePrompt(window_width: f32, window_height: f32) void {
    _ = window_height;
    g_update_prompt_rect = null;

    const now = std.time.milliTimestamp();
    if (now >= g_update_prompt_until_ms) return;
    if (g_update_prompt_len == 0) return;

    const text = g_update_prompt_buf[0..g_update_prompt_len];
    const pad_h: f32 = 14;
    const pad_v: f32 = 6;
    const line_h = font.g_titlebar_cell_height + pad_v * 2;

    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }

    const bg_w = text_width + pad_h * 2;
    const bg_x = @max(12, (window_width - bg_w) / 2);
    const bg_y: f32 = 92;

    const bg_color: [3]f32 = if (g_update_prompt_clickable) .{ 0.18, 0.14, 0.06 } else .{ 0.08, 0.13, 0.16 };
    const text_color: [3]f32 = if (g_update_prompt_clickable) .{ 1.0, 0.82, 0.38 } else .{ 0.55, 0.85, 0.95 };
    ui_pipeline.fillQuad(bg_x, bg_y, bg_w, line_h, bg_color);
    if (g_update_prompt_clickable) {
        ui_pipeline.fillQuad(bg_x, bg_y + line_h - 2, bg_w, 2, .{ 0.86, 0.48, 0.20 });
        g_update_prompt_rect = .{ .x = bg_x, .y = bg_y, .w = bg_w, .h = line_h };
    }

    var x = bg_x + pad_h;
    const y = bg_y + pad_v;
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y, text_color);
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
}

pub fn updatePromptHitTest(xpos: f64, ypos: f64, window_height: f32) bool {
    if (!g_update_prompt_clickable) return false;
    if (std.time.milliTimestamp() >= g_update_prompt_until_ms) return false;
    const rect = g_update_prompt_rect orelse return false;
    const x: f32 = @floatCast(xpos);
    const y_from_bottom = window_height - @as(f32, @floatCast(ypos));
    return x >= rect.x and x <= rect.x + rect.w and
        y_from_bottom >= rect.y and y_from_bottom <= rect.y + rect.h;
}

fn latestReleaseUrl(out: *[256]u8) []const u8 {
    return if (AppWindow.g_app) |app|
        app.copyLatestReleaseUrl(out) orelse update_check.latest_release_page_url
    else
        update_check.latest_release_page_url;
}

fn storedPromptUrl(out: *[256]u8) []const u8 {
    return if (g_update_prompt_url_len > 0)
        g_update_prompt_url_buf[0..g_update_prompt_url_len]
    else
        latestReleaseUrl(out);
}

pub fn openLatestRelease() void {
    const allocator = AppWindow.g_allocator orelse return;
    var url_buf: [256]u8 = undefined;
    const url = latestReleaseUrl(&url_buf);
    _ = platform_open_url.open(allocator, .{ .url = url });
}

/// Read the Claude Code hook settings file (empty string if absent), call
/// claude_integration.install, write atomically, show a toast.
fn installClaudeCodeIntegration() void {
    const allocator = AppWindow.g_allocator orelse return;
    applyClaudeIntegration(allocator, true);
}

/// Read the Claude Code hook settings file (empty string if absent), call
/// claude_integration.uninstall, write atomically, show a toast.
fn removeClaudeCodeIntegration() void {
    const allocator = AppWindow.g_allocator orelse return;
    applyClaudeIntegration(allocator, false);
}

fn applyClaudeIntegration(allocator: std.mem.Allocator, comptime do_install: bool) void {
    // Resolve the Claude Code settings file path via platform_dirs.
    const settings_path = platform_dirs.agentHookSettingsPath(allocator) catch |err| {
        std.log.warn("claude integration: cannot resolve settings path: {}", .{err});
        showStatusToast("Claude Code integration: cannot resolve home directory");
        return;
    };
    defer allocator.free(settings_path);

    // Read existing content; treat missing file as "".
    const existing = std.fs.cwd().readFileAlloc(allocator, settings_path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => allocator.dupe(u8, "") catch {
            showStatusToast("Claude Code integration: out of memory");
            return;
        },
        else => {
            std.log.warn("claude integration: read {s}: {}", .{ settings_path, err });
            showStatusToast("Claude Code integration: failed to read settings.json");
            return;
        },
    };
    defer allocator.free(existing);

    // Apply install or uninstall (pure, no IO).
    const new_content = if (do_install)
        claude_integration.install(allocator, existing)
    else
        claude_integration.uninstall(allocator, existing);
    const result = new_content catch |err| {
        std.log.warn("claude integration: transform failed: {}", .{err});
        showStatusToast("Claude Code integration: settings.json parse error");
        return;
    };
    defer allocator.free(result);

    // Ensure the settings directory exists.
    const settings_dir = std.fs.path.dirname(settings_path) orelse settings_path;
    std.fs.cwd().makePath(settings_dir) catch |err| {
        std.log.warn("claude integration: makePath {s}: {}", .{ settings_dir, err });
        showStatusToast("Claude Code integration: cannot create settings directory");
        return;
    };

    // Write atomically (temp file + rename via platform helper).
    platform_atomic_file.writeFileReplaceSafe(settings_path, result) catch |err| {
        std.log.warn("claude integration: write {s}: {}", .{ settings_path, err });
        showStatusToast("Claude Code integration: failed to write settings.json");
        return;
    };

    if (do_install) {
        showStatusToast("Claude Code agent integration installed");
    } else {
        showStatusToast("Claude Code agent integration removed");
    }
}

fn openStoredPromptUrl() void {
    const allocator = AppWindow.g_allocator orelse return;
    var url_buf: [256]u8 = undefined;
    const url = storedPromptUrl(&url_buf);
    _ = platform_open_url.open(allocator, .{ .url = url });
}

pub fn activateUpdatePrompt() void {
    switch (g_update_prompt_action) {
        .download_update => {
            if (AppWindow.g_app) |app| {
                if (app.hasDownloadableUpdate()) {
                    showUpdatePrompt(.{ .state = .downloading }, .none);
                    app.requestUpdateDownload();
                } else {
                    showUpdateDownloadUnavailableToast();
                }
            } else {
                showUpdateDownloadUnavailableToast();
            }
        },
        .open_release => openStoredPromptUrl(),
        .none => {},
    }
}

pub fn remoteKeyOverlayDismiss(key: []const u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    g_remote_key_dismissed_digest = digest;
}

fn isRemoteKeyDismissed(key: []const u8) bool {
    const dismissed = g_remote_key_dismissed_digest orelse return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    return std.mem.eql(u8, dismissed[0..], digest[0..]);
}

pub fn remoteKeyCopyHitTest(xpos: f64, ypos: f64, window_height: f32) bool {
    const rect = g_remote_key_copy_rect orelse return false;
    const x: f32 = @floatCast(xpos);
    const y_from_bottom = window_height - @as(f32, @floatCast(ypos));
    return x >= rect.x and x <= rect.x + rect.w and
        y_from_bottom >= rect.y and y_from_bottom <= rect.y + rect.h;
}

fn remoteStateLabel(state: @import("../remote_client.zig").State) []const u8 {
    return switch (state) {
        .disabled => "off",
        .connecting => "connecting",
        .connected => "connected",
        .disconnected => "offline",
        .failed => "retrying",
    };
}

fn remoteStateColor(state: @import("../remote_client.zig").State) [3]f32 {
    return switch (state) {
        .disabled => .{ 0.55, 0.55, 0.55 },
        .connecting => .{ 1.0, 0.78, 0.22 },
        .connected => .{ 0.24, 1.0, 0.44 },
        .disconnected => .{ 1.0, 0.58, 0.24 },
        .failed => .{ 1.0, 0.28, 0.24 },
    };
}

fn renderDebugLine(window_width: f32, y_pos: *f32, margin: f32, pad_h: f32, pad_v: f32, line_h: f32, text: []const u8, text_color: [3]f32) ?DebugLineRect {
    if (text.len == 0) return null;

    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }

    const bg_w = text_width + pad_h * 2;
    const bg_x = window_width - bg_w - margin;
    const bg_y = y_pos.*;

    ui_pipeline.fillQuad(bg_x, bg_y, bg_w, line_h, .{ 0.0, 0.0, 0.0 });

    var x = bg_x + pad_h;
    const y = bg_y + pad_v;
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y, text_color);
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }

    const rect: DebugLineRect = .{ .x = bg_x, .y = bg_y, .w = bg_w, .h = line_h };
    y_pos.* += line_h + 2; // spacing between lines
    return rect;
}
