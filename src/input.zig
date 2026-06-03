//! Input handling for AppWindow.
//!
//! Processes platform input events (keyboard, mouse, resize) and dispatches
//! to appropriate handlers. Manages clipboard, selection, scrollbar dragging,
//! split divider dragging, and fullscreen toggle.

const std = @import("std");
const builtin = @import("builtin");
const AppWindow = @import("AppWindow.zig");
const tab = AppWindow.tab;
const active_tab_state = @import("appwindow/active_tab.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const overlays = AppWindow.overlays;
const split_layout = AppWindow.split_layout;
const file_explorer = AppWindow.file_explorer;
const markdown_preview = @import("markdown_preview.zig");
const markdown_preview_panel = AppWindow.markdown_preview_panel;
const preview_token = @import("preview_token.zig");
const browser_panel = AppWindow.browser_panel;
const ai_sidebar = @import("ai_sidebar.zig");
const ui_perf = AppWindow.ui_perf;
const render_diagnostics = @import("render_diagnostics.zig");
const link_open = @import("link_open.zig");
const platform_dirs = @import("platform/dirs.zig");
const platform_local_path = @import("platform/local_path.zig");
const platform_open_url = @import("platform/open_url.zig");
const platform_file_dialog = @import("platform/file_dialog.zig");
const input_shortcuts = @import("input_shortcuts.zig");
const keybind = @import("keybind.zig");
const platform_cursor = @import("platform/cursor.zig");
const platform_input = @import("platform/input_events.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const platform_wsl = @import("platform/wsl.zig");
const window_backend = @import("platform/window_backend.zig");
const input_key = @import("input/key.zig");
const command_dispatch = @import("input/command_dispatch.zig");
const Config = @import("config.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("split_tree.zig");
const selection_unit = @import("selection_unit.zig");
const Selection = Surface.Selection;
const CellPos = struct { col: usize, row: usize };

const clipboard = @import("input/clipboard.zig");
const click_tracker = @import("input/click_tracker.zig");
const hit_test = @import("input/hit_test.zig");
const preview_source = @import("input/preview_source.zig");
const terminal_link_action = @import("input/terminal_link_action.zig");
const mouse_report = @import("input/mouse_report.zig");
const close_confirm = @import("close_confirm.zig");
const writeToPty = clipboard.writeToPty;
pub const copyTextToClipboard = clipboard.copyTextToClipboard;
const activeTerminalSelectionExists = clipboard.activeTerminalSelectionExists;
const handleConfiguredRightClick = clipboard.handleConfiguredRightClick;
const copyAiChatToClipboard = clipboard.copyAiChatToClipboard;
const copyAiChatCutToClipboard = clipboard.copyAiChatCutToClipboard;
const copyAiChatMessageToClipboard = clipboard.copyAiChatMessageToClipboard;
pub const handleFileDrop = clipboard.handleFileDrop;
pub const copySelectionToClipboard = clipboard.copySelectionToClipboard;
pub const pasteFromClipboard = clipboard.pasteFromClipboard;
const pasteClipboardIntoBrowserUrlBar = clipboard.pasteClipboardIntoBrowserUrlBar;
const pasteClipboardIntoSessionLauncher = clipboard.pasteClipboardIntoSessionLauncher;
const pasteFromClipboardIntoAiChat = clipboard.pasteFromClipboardIntoAiChat;
const pasteImageIntoAiChat = clipboard.pasteImageIntoAiChat;
pub const pasteImageFromClipboard = clipboard.pasteImageFromClipboard;
pub const writeTextToActivePty = clipboard.writeTextToActivePty;
pub const writeTextToSurfacePty = clipboard.writeTextToSurfacePty;
const looksLikePreviewPath = preview_source.looksLikePreviewPath;
const resolveTerminalPreviewPath = preview_source.resolveTerminalPreviewPath;
const basenameForPreview = preview_source.basenameForPreview;
const buildPreviewCommand = preview_source.buildPreviewCommand;

const LayoutResizeUrgency = terminal_link_action.LayoutResizeUrgency;
const TerminalPathClickAction = terminal_link_action.TerminalPathClickAction;
const InteractiveUnderlineTokenKind = terminal_link_action.InteractiveUnderlineTokenKind;

const panelToggleResizeUrgency = terminal_link_action.panelToggleResizeUrgency;

fn clientSize(win: anytype) window_backend.Size {
    return window_backend.clientSize(win);
}

fn syncGridFromWindow(win: anytype) void {
    const size = clientSize(win);
    syncGridFromWindowSize(size.width, size.height);
}

fn syncPanelGridFromWindow(win: anytype) void {
    const size = clientSize(win);
    syncPanelGridFromWindowSize(size.width, size.height);
}

fn syncSidebarWidthToBackend(win: anytype) void {
    window_backend.setSidebarWidth(win, @intFromFloat(titlebar.sidebarWidth()));
}

const primaryOpenMod = terminal_link_action.primaryOpenMod;
const terminalPathClickAction = terminal_link_action.terminalPathClickAction;

const interactiveUnderlineTokenKind = terminal_link_action.interactiveUnderlineTokenKind;
const looksLikeDownloadPath = terminal_link_action.looksLikeDownloadPath;

test "input: WeChat QR panel consumes text input while visible" {
    AppWindow.weixin_qr_panel.g_visible = true;
    defer AppWindow.weixin_qr_panel.g_visible = false;

    try std.testing.expect(weixinQrPanelConsumesChar());
}

test "input: command palette shortcut toggles command center" {
    const previous_keybinds = AppWindow.g_keybinds;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer overlays.commandPaletteClose();

    AppWindow.g_keybinds = keybind.Set.defaults();
    overlays.commandPaletteClose();

    // macOS migrates app shortcuts to Cmd (the super modifier); other platforms
    // keep Ctrl. So the command palette is Cmd+Shift+P on macOS, Ctrl+Shift+P else.
    const is_macos = builtin.os.tag == .macos;
    const palette_key = platform_input.KeyEvent{
        .key_code = 'P',
        .ctrl = !is_macos,
        .shift = true,
        .alt = false,
        .super = is_macos,
    };

    handleKey(palette_key);
    try std.testing.expect(overlays.commandPaletteVisible());

    handleKey(palette_key);
    try std.testing.expect(!overlays.commandPaletteVisible());
}

test "macOS UI smoke: Cmd+Shift+B toggles the tab sidebar" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const previous_keybinds = AppWindow.g_keybinds;
    const previous_sidebar = tab.g_sidebar_visible;
    defer AppWindow.g_keybinds = previous_keybinds;
    defer tab.g_sidebar_visible = previous_sidebar;

    AppWindow.g_keybinds = keybind.Set.defaults();
    tab.g_sidebar_visible = false;

    // macOS uses Cmd (super) for the sidebar toggle, not Ctrl.
    const sidebar_key = platform_input.KeyEvent{
        .key_code = 'B',
        .ctrl = false,
        .shift = true,
        .alt = false,
        .super = true,
    };

    handleKey(sidebar_key);
    try std.testing.expect(tab.g_sidebar_visible);

    handleKey(sidebar_key);
    try std.testing.expect(!tab.g_sidebar_visible);
}

fn weixinQrPanelConsumesChar() bool {
    return AppWindow.weixin_qr_panel.visible();
}

// Selection + divider drag state (moved from AppWindow.zig)
pub threadlocal var g_selecting: bool = false; // True while mouse button is held
pub threadlocal var g_click_x: f64 = 0; // X position of initial click (for threshold calculation)
pub threadlocal var g_click_y: f64 = 0; // Y position of initial click
var g_selection_changed_for_copy: bool = false;

// Terminal mouse reporting drag state. When a press is delivered to the PTY
// (the focused program enabled mouse tracking and Shift wasn't held), the
// matching drag-motion and release are routed to the PTY too — until the
// button lifts — instead of driving local text selection. See
// input/mouse_report.zig for the protocol encoder.
threadlocal var g_mouse_report_button: ?mouse_report.Button = null;
threadlocal var g_mouse_report_surface: ?*Surface = null;
threadlocal var g_mouse_report_last_cell: ?CellPos = null;
threadlocal var g_left_click_tracker: click_tracker.ClickTracker = .{};
const MULTI_CLICK_INTERVAL_MS: i64 = 500;
const MAX_SELECTION_COLS: usize = 4096;

const UrlUnderline = struct {
    surface: ?*Surface = null,
    row_abs: usize = 0,
    start_col: usize = 0,
    end_col: usize = 0,

    fn active(self: UrlUnderline) bool {
        return self.surface != null;
    }
};

threadlocal var g_url_underline: UrlUnderline = .{};

const TokenAtCell = struct {
    text: []u8,
    row: usize,
    start_col: usize,
    end_col: usize,

    fn deinit(self: TokenAtCell, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const SPLIT_DIVIDER_HIT_WIDTH: f32 = 8; // Larger hit area for easier grabbing

pub threadlocal var g_divider_hover: bool = false; // Mouse is over a divider
pub threadlocal var g_divider_dragging: bool = false; // Currently dragging a divider
pub threadlocal var g_divider_drag_handle: ?SplitTree.Node.Handle = null; // Handle of the split node being resized
pub threadlocal var g_divider_drag_layout: ?SplitTree.Split.Layout = null; // horizontal or vertical

// Alt + left-drag panel swap. `source` is the grabbed panel (recorded on press),
// `target` is the panel under the cursor while dragging (drives the highlight),
// `active` flips true once the drag passes PANEL_SWAP_DRAG_THRESHOLD_PX. The
// renderer reads `g_panel_swap_active`/`source`/`target` to dim the source and
// highlight the drop target.
const PANEL_SWAP_DRAG_THRESHOLD_PX: f64 = 6.0;
pub threadlocal var g_panel_swap_active: bool = false;
pub threadlocal var g_panel_swap_source: ?SplitTree.Node.Handle = null;
pub threadlocal var g_panel_swap_target: ?SplitTree.Node.Handle = null;
threadlocal var g_panel_swap_start_x: f64 = 0;
threadlocal var g_panel_swap_start_y: f64 = 0;
threadlocal var g_scrollbar_drag_surface: ?*Surface = null;
threadlocal var g_scrollbar_drag_view_y: f32 = 0;
threadlocal var g_scrollbar_drag_view_h: f32 = 0;
threadlocal var g_scrollbar_drag_top_pad: f32 = 0;
threadlocal var g_ai_input_scroll_dragging: bool = false;
threadlocal var g_ai_input_scroll_chat: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_input_scroll_drag_offset: f32 = 0;
threadlocal var g_ai_transcript_scroll_dragging: bool = false;
threadlocal var g_ai_transcript_scroll_chat: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_transcript_scroll_drag_offset: f32 = 0;
threadlocal var g_ai_transcript_selecting: bool = false;
threadlocal var g_ai_transcript_select_chat: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_transcript_select_auto_copy: bool = false;
threadlocal var g_ai_history_suppress_refresh_char: bool = false;
pub threadlocal var g_sidebar_resize_hover: bool = false; // Mouse is over the sidebar resize edge
pub threadlocal var g_sidebar_resize_dragging: bool = false; // Currently dragging the sidebar edge
pub threadlocal var g_explorer_resize_hover: bool = false; // Mouse is over the file explorer resize edge
pub threadlocal var g_explorer_resize_dragging: bool = false; // Currently dragging the file explorer edge
pub threadlocal var g_markdown_preview_resize_hover: bool = false; // Mouse is over the preview resize edge
pub threadlocal var g_markdown_preview_resize_dragging: bool = false; // Currently dragging the preview edge
threadlocal var g_markdown_preview_image_dragging: bool = false;
threadlocal var g_markdown_preview_image_hover: bool = false;
threadlocal var g_markdown_preview_image_drag_last_x: f64 = 0;
threadlocal var g_markdown_preview_image_drag_last_y: f64 = 0;
pub threadlocal var g_browser_resize_hover: bool = false; // Mouse is over the embedded browser edge
pub threadlocal var g_browser_resize_dragging: bool = false; // Currently dragging the browser edge
pub threadlocal var g_ai_copilot_resize_hover: bool = false; // Mouse is over the AI copilot left edge
pub threadlocal var g_ai_copilot_resize_dragging: bool = false; // Currently dragging the AI copilot edge
pub threadlocal var g_url_open_mode: link_open.Mode = .embedded;

/// Whether the AI copilot sidebar currently owns keyboard/mouse focus. Set by
/// AppWindow.toggleAiCopilot; full key/mouse routing lands in a later task.
threadlocal var g_ai_copilot_focused: bool = false;

pub fn focusAiCopilot() void {
    g_ai_copilot_focused = true;
}

pub fn blurAiCopilot() void {
    g_ai_copilot_focused = false;
}

pub fn aiCopilotFocused() bool {
    return g_ai_copilot_focused;
}
const SIDEBAR_TAB_DRAG_THRESHOLD_PX: f64 = 6.0;
threadlocal var g_sidebar_tab_drag_pressed: ?usize = null;
threadlocal var g_sidebar_tab_drag_current: ?usize = null;
threadlocal var g_sidebar_tab_drag_start_x: f64 = 0;
threadlocal var g_sidebar_tab_drag_start_y: f64 = 0;
threadlocal var g_sidebar_tab_drag_active: bool = false;

// Internal input state.
threadlocal var plus_btn_pressed: bool = false;
threadlocal var fullscreen_restore_state: window_backend.FullscreenRestoreState = .{};
const CLOSE_SHORTCUT_CONFIRM_MS: i64 = 5000;
threadlocal var g_close_shortcut_confirm_until_ms: i64 = 0;

fn titlebarHeight() f64 {
    return @floatCast(AppWindow.currentTitlebarHeight());
}

fn syncGridFromWindowSize(width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    const render_padding: f32 = 10;
    const tb_offset: f32 = @floatCast(titlebarHeight());
    const left_panels_w = AppWindow.leftPanelsWidth();
    const right_panels_w = AppWindow.rightPanelsWidthForWindow(width);
    const explicit_left: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);
    const explicit_right: f32 = @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING)) + overlays.SCROLLBAR_WIDTH;
    const explicit_top: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);
    const explicit_bottom: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);

    const total_width_padding = left_panels_w + right_panels_w + explicit_left + explicit_right;
    const total_height_padding = render_padding * 2 + tb_offset + explicit_top + explicit_bottom;

    const avail_width = @as(f32, @floatFromInt(width)) - total_width_padding;
    const avail_height = @as(f32, @floatFromInt(height)) - total_height_padding;

    const new_cols: u16 = @intFromFloat(@max(1, avail_width / font.cell_width));
    const new_rows: u16 = @intFromFloat(@max(1, avail_height / font.cell_height));

    if (new_cols != AppWindow.term_cols or new_rows != AppWindow.term_rows) {
        render_diagnostics.log(
            "input-grid-sync source={}x{} avail={d:.1}x{d:.1} panels_l={d:.1} panels_r={d:.1} titlebar={d:.1} cell={d:.2}x{d:.2} pending={}x{} old={}x{}",
            .{
                width,
                height,
                avail_width,
                avail_height,
                left_panels_w,
                right_panels_w,
                tb_offset,
                font.cell_width,
                font.cell_height,
                new_cols,
                new_rows,
                AppWindow.term_cols,
                AppWindow.term_rows,
            },
        );
        AppWindow.g_pending_resize = true;
        AppWindow.g_pending_cols = new_cols;
        AppWindow.g_pending_rows = new_rows;
        AppWindow.g_last_resize_time = std.time.milliTimestamp();
    }
}

fn syncGridFromWindowSizeImmediate(width: i32, height: i32) void {
    AppWindow.requestImmediateLayoutResize();
    syncGridFromWindowSize(width, height);
}

fn syncGridFromWindowSizeWithUrgency(width: i32, height: i32, urgency: LayoutResizeUrgency) void {
    const perf = ui_perf.begin(switch (urgency) {
        .coalesced => "input.grid_sync.coalesced",
        .immediate => "input.grid_sync.immediate",
    });
    defer perf.end();

    switch (urgency) {
        .coalesced => syncGridFromWindowSize(width, height),
        .immediate => syncGridFromWindowSizeImmediate(width, height),
    }
}

fn syncPanelGridFromWindowSize(width: i32, height: i32) void {
    syncGridFromWindowSizeWithUrgency(width, height, panelToggleResizeUrgency());
}

fn markBrowserUrlBarDirty() void {
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn blurBrowserUrlBarIfFocused() void {
    if (!browser_panel.urlBarFocused()) return;
    browser_panel.blurUrlBar();
    markBrowserUrlBarDirty();
}

pub fn cancelTransientMouseState(win: anytype) void {
    g_divider_hover = false;
    g_divider_dragging = false;
    g_divider_drag_handle = null;
    g_divider_drag_layout = null;
    g_sidebar_resize_hover = false;
    g_sidebar_resize_dragging = false;
    g_explorer_resize_hover = false;
    g_explorer_resize_dragging = false;
    g_markdown_preview_resize_hover = false;
    g_markdown_preview_resize_dragging = false;
    g_markdown_preview_image_dragging = false;
    g_markdown_preview_image_hover = false;
    g_markdown_preview_image_drag_last_x = 0;
    g_markdown_preview_image_drag_last_y = 0;
    g_browser_resize_hover = false;
    g_browser_resize_dragging = false;
    g_ai_copilot_resize_hover = false;
    g_ai_copilot_resize_dragging = false;
    g_selecting = false;
    plus_btn_pressed = false;
    tab.g_tab_close_pressed = null;
    resetPanelSwapState();
    resetSidebarTabDragState();
    overlays.scrollbar.g_scrollbar_dragging = false;
    g_scrollbar_drag_surface = null;
    g_ai_input_scroll_dragging = false;
    g_ai_input_scroll_chat = null;
    g_ai_transcript_scroll_dragging = false;
    g_ai_transcript_scroll_chat = null;
    AppWindow.ai_chat_renderer.g_transcript_scrollbar_dragging = false;
    AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover = false;
    g_ai_transcript_selecting = false;
    g_ai_transcript_select_chat = null;
    g_ai_transcript_select_auto_copy = false;
    window_backend.clearTransientInput(win);
}

pub fn toggleSidebar() void {
    const perf = ui_perf.begin("input.toggle_sidebar");
    defer perf.end();

    tab.g_sidebar_visible = !tab.g_sidebar_visible;
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
        syncSidebarWidthToBackend(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

pub fn toggleFileExplorer() void {
    const perf = ui_perf.begin("input.toggle_file_explorer");
    defer perf.end();

    file_explorer.toggle();
    if (file_explorer.isVisibleForActiveTab()) {
        AppWindow.syncVisibleFileExplorerForActiveTab();
    }
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn closeFileExplorerPanel() void {
    file_explorer.close();
    blurBrowserUrlBarIfFocused();
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

pub fn toggleBrowserPanel() void {
    const perf = ui_perf.begin("input.toggle_browser_panel");
    defer perf.end();

    const allocator = AppWindow.g_allocator orelse return;
    const parent = AppWindow.currentNativeHandle();
    const surface = AppWindow.activeSurface();
    if (g_url_open_mode == .system_browser and !browser_panel.isVisibleForActiveTab()) {
        const target = browser_panel.externalUrlForSurface(allocator, browser_panel.DEFAULT_URL, surface) orelse return;
        defer allocator.free(target);
        _ = platform_open_url.open(allocator, .{ .url = target });
        return;
    }
    if (!browser_panel.isVisibleForActiveTab()) AppWindow.hideAiCopilot();
    if (!browser_panel.toggleForSurface(allocator, parent, surface)) return;
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn closeBrowserPanel() void {
    g_close_shortcut_confirm_until_ms = 0;
    browser_panel.close();
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn closeMarkdownPreviewPanel() void {
    g_close_shortcut_confirm_until_ms = 0;
    markdown_preview_panel.close();
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn closeAiCopilotPanel() void {
    AppWindow.hideAiCopilot();
    if (AppWindow.g_window) |win| {
        syncPanelGridFromWindow(win);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

pub fn closePanelOrTab() void {
    if (markdown_preview_panel.isVisibleForActiveTab()) {
        closeMarkdownPreviewPanel();
        return;
    }
    if (browser_panel.isVisibleForActiveTab()) {
        closeBrowserPanel();
        return;
    }
    if (close_confirm.shouldConfirm(AppWindow.g_confirm_close_running_program, AppWindow.activeSurfaceHasRunningProgram())) {
        g_close_shortcut_confirm_until_ms = 0;
        overlays.closeConfirmOpen(.focused_split, .running_program);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    if (AppWindow.closeFocusedSplitWouldCloseWindow()) {
        const now = std.time.milliTimestamp();
        if (now < g_close_shortcut_confirm_until_ms) {
            g_close_shortcut_confirm_until_ms = 0;
            AppWindow.closeFocusedSplit();
            return;
        }
        g_close_shortcut_confirm_until_ms = now + CLOSE_SHORTCUT_CONFIRM_MS;
        overlays.showCloseShortcutConfirm(CLOSE_SHORTCUT_CONFIRM_MS);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    g_close_shortcut_confirm_until_ms = 0;
    AppWindow.closeFocusedSplit();
}

/// Close a tab via a pointer gesture (middle-click or the × button), honoring
/// the running-program confirmation. `tab_idx` is the tab to close.
fn requestCloseTabGesture(tab_idx: usize) void {
    const closes_window = tab.g_tab_count <= 1;
    if (close_confirm.shouldConfirm(AppWindow.g_confirm_close_running_program, AppWindow.tabHasRunningProgram(tab_idx))) {
        const action: close_confirm.PendingClose = if (closes_window) .window else .{ .tab = tab_idx };
        overlays.closeConfirmOpen(action, .running_program);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    if (closes_window) {
        AppWindow.g_should_close = true;
    } else {
        AppWindow.closeTab(tab_idx);
    }
}

pub fn adjustFontSize(delta: i32) void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    const current: i32 = @intCast(cfg.@"font-size");
    var next = current + delta;
    if (next < 6) next = 6;
    if (next > 72) next = 72;
    if (next == current) return;

    var buf: [16]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d}", .{next}) catch return;
    Config.setConfigValue(allocator, "font-size", value) catch {};
}

pub fn copyRemoteSessionKeyToClipboard() bool {
    const app = AppWindow.g_app orelse return false;
    const client = app.remote_client orelse return false;
    const key = client.sessionKey();
    if (!copyTextToClipboard(key)) return false;
    overlays.remoteKeyCopiedFlash();
    overlays.remoteKeyOverlayDismiss(key);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    std.debug.print("Remote session key copied to clipboard\n", .{});
    return true;
}

// ============================================================================
// Shared helpers (used by input + cell_renderer)
// ============================================================================

/// Get the viewport's absolute row offset into the scrollback.
/// Row 0 on screen corresponds to absolute row `viewportOffset()`.
pub fn viewportOffset() usize {
    const surface = AppWindow.activeSurface() orelse return 0;
    return viewportOffsetForSurface(surface);
}

pub const ScrollbarState = struct {
    total: usize,
    offset: usize,
    len: usize,
};

/// Convert mouse position to terminal cell coordinates.
pub fn mouseToCell(xpos: f64, ypos: f64) CellPos {
    const padding_d: f64 = 10;
    const tb_d = titlebarHeight();
    const sidebar_d: f64 = @floatCast(titlebar.sidebarWidth());
    const col_f = (xpos - sidebar_d - padding_d) / @as(f64, font.cell_width);
    const row_f = (ypos - padding_d - tb_d) / @as(f64, font.cell_height);

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(AppWindow.term_cols))) AppWindow.term_cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(AppWindow.term_rows))) AppWindow.term_rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

fn splitRectForSurface(surface: *Surface) ?split_layout.SplitRect {
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(rect)) continue;
        if (rect.surface == surface) return rect;
    }
    return null;
}

const ScrollbarTarget = struct {
    surface: *Surface,
    view_x: f32,
    view_y: f32,
    view_w: f32,
    view_h: f32,
    top_pad: f32,
};

fn scrollbarTargetAt(xpos: f64, ypos: f64, window_w: f32, window_h: f32, top_pad: f32) ?ScrollbarTarget {
    if (split_layout.g_split_rect_count > 1) {
        for (0..split_layout.g_split_rect_count) |i| {
            const rect = split_layout.g_split_rects[i];
            if (!split_layout.cachedRectIsLive(rect)) continue;
            const pad = rect.surface.getPadding();
            const view_x: f32 = @floatFromInt(rect.x);
            const view_y: f32 = @floatFromInt(rect.y);
            const view_w: f32 = @floatFromInt(rect.width);
            const view_h: f32 = @floatFromInt(rect.height);
            const local_top_pad: f32 = @floatFromInt(pad.top);
            if (overlays.scrollbarHitTestForSurface(rect.surface, xpos, ypos, view_x, view_y, view_w, view_h, local_top_pad)) {
                return .{
                    .surface = rect.surface,
                    .view_x = view_x,
                    .view_y = view_y,
                    .view_w = view_w,
                    .view_h = view_h,
                    .top_pad = local_top_pad,
                };
            }
        }
        return null;
    }

    const surface = AppWindow.activeSurface() orelse return null;
    if (!overlays.scrollbarHitTestForSurface(surface, xpos, ypos, 0, 0, window_w, window_h, top_pad)) return null;
    return .{
        .surface = surface,
        .view_x = 0,
        .view_y = 0,
        .view_w = window_w,
        .view_h = window_h,
        .top_pad = top_pad,
    };
}

pub fn viewportOffsetForSurface(surface: *Surface) usize {
    return scrollbarForSurface(surface).offset;
}

pub fn scrollbarForSurface(surface: *Surface) ScrollbarState {
    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    return scrollbarForSurfaceLocked(surface);
}

pub fn viewportOffsetForSurfaceLocked(surface: *Surface) usize {
    return scrollbarForSurfaceLocked(surface).offset;
}

pub fn scrollbarForSurfaceLocked(surface: *Surface) ScrollbarState {
    var pages = &surface.terminal.screens.active.pages;
    const rows: usize = @intCast(pages.rows);
    if (pages.total_rows <= rows) {
        return .{
            .total = rows,
            .offset = 0,
            .len = rows,
        };
    }

    const sb = pages.scrollbar();
    return .{
        .total = sb.total,
        .offset = sb.offset,
        .len = sb.len,
    };
}

/// Convert a window mouse position to a cell in the clicked split surface.
fn mouseToSurfaceCell(surface: *Surface, xpos: f64, ypos: f64) CellPos {
    const rect = splitRectForSurface(surface) orelse return mouseToCell(xpos, ypos);
    const pad = surface.getPadding();
    const col_f = (xpos - @as(f64, @floatFromInt(rect.x)) - @as(f64, @floatFromInt(pad.left))) / @as(f64, @floatCast(font.cell_width));
    const row_f = (ypos - @as(f64, @floatFromInt(rect.y)) - @as(f64, @floatFromInt(pad.top))) / @as(f64, @floatCast(font.cell_height));
    const cols = @max(@as(usize, 1), @as(usize, @intCast(surface.size.grid.cols)));
    const rows = @max(@as(usize, 1), @as(usize, @intCast(surface.size.grid.rows)));

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(cols))) cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(rows))) rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

fn mouseToSurfacePixel(surface: *Surface, xpos: i32, ypos: i32) struct { x: i32, y: i32 } {
    if (splitRectForSurface(surface)) |rect| {
        const pad = surface.getPadding();
        return .{
            .x = xpos - rect.x - @as(i32, @intCast(pad.left)),
            .y = ypos - rect.y - @as(i32, @intCast(pad.top)),
        };
    }
    return .{
        .x = xpos - @as(i32, @intFromFloat(titlebar.sidebarWidth())) - 10,
        .y = ypos - @as(i32, @intFromFloat(titlebarHeight())) - 10,
    };
}

/// Update split focus based on mouse position (focus follows mouse).
pub fn updateFocusFromMouse(mouse_x: i32, mouse_y: i32) void {
    const t = tab.activeTab() orelse return;
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(rect)) continue;
        if (mouse_x >= rect.x and mouse_x < rect.x + rect.width and
            mouse_y >= rect.y and mouse_y < rect.y + rect.height)
        {
            if (rect.handle != t.focused) {
                t.focused = rect.handle;
                AppWindow.handleActiveSurfaceChangeWithinTab();
            }
            return;
        }
    }
}

/// Return the split-tree handle of the panel containing the given window point,
/// or null if the point is not inside any (live) panel rect — e.g. it is over a
/// divider gap or outside the content area.
fn panelHandleAtPoint(x: i32, y: i32) ?SplitTree.Node.Handle {
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(rect)) continue;
        if (x >= rect.x and x < rect.x + rect.width and
            y >= rect.y and y < rect.y + rect.height)
        {
            return rect.handle;
        }
    }
    return null;
}

fn resetPanelSwapState() void {
    g_panel_swap_active = false;
    g_panel_swap_source = null;
    g_panel_swap_target = null;
    g_panel_swap_start_x = 0;
    g_panel_swap_start_y = 0;
}

/// Begin a potential Alt-drag panel swap if the active terminal tab is split and
/// the press landed inside a panel. Returns true if the gesture was engaged (the
/// caller should consume the event). Single-panel tabs are left alone so default
/// click/selection behavior is unchanged.
fn beginPanelSwapIfSplit(x: i32, y: i32) bool {
    const t = tab.activeTab() orelse return false;
    if (t.kind != .terminal or !t.tree.isSplit()) return false;
    const source = panelHandleAtPoint(x, y) orelse return false;
    g_panel_swap_source = source;
    g_panel_swap_target = null;
    g_panel_swap_active = false;
    g_panel_swap_start_x = @floatFromInt(x);
    g_panel_swap_start_y = @floatFromInt(y);
    platform_cursor.set(.size_all);
    return true;
}

/// Drive an in-progress panel swap from a mouse-move. Returns true while the
/// gesture owns the move (caller should return early). Engages `active` once the
/// drag passes the threshold, then tracks the hovered drop target for highlight.
fn updatePanelSwapDrag(x: i32, y: i32) bool {
    const source = g_panel_swap_source orelse return false;

    if (!g_panel_swap_active) {
        const dx = @as(f64, @floatFromInt(x)) - g_panel_swap_start_x;
        const dy = @as(f64, @floatFromInt(y)) - g_panel_swap_start_y;
        if (@sqrt(dx * dx + dy * dy) < PANEL_SWAP_DRAG_THRESHOLD_PX) return true;
        g_panel_swap_active = true;
        g_selecting = false;
    }

    // The drop target is the hovered panel, but never the source itself.
    const hovered = panelHandleAtPoint(x, y);
    const target: ?SplitTree.Node.Handle = if (hovered) |h| (if (h == source) null else h) else null;
    if (target != g_panel_swap_target) {
        g_panel_swap_target = target;
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }
    platform_cursor.set(.size_all);
    return true;
}

/// Finish a panel swap on mouse-up. Returns true if a swap gesture was in
/// progress (caller should consume the event). Performs the swap only when the
/// drag was active and dropped on a valid, different panel.
fn finishPanelSwapDrag() bool {
    const source = g_panel_swap_source orelse return false;
    const did_swap = g_panel_swap_active;
    const target = g_panel_swap_target;
    resetPanelSwapState();
    if (did_swap) {
        if (target) |t| _ = AppWindow.swapPanels(source, t);
    }
    // The press set the size_all cursor; restore it whether or not a swap
    // happened (a bare Alt-click never crossed the drag threshold).
    platform_cursor.set(.arrow);
    return true;
}

/// Process all queued platform input events. Called once per frame from the main loop.
pub fn processEvents(win: anytype) void {
    if (window_backend.isMinimized(win)) {
        cancelTransientMouseState(win);
        _ = window_backend.consumeSizeChanged(win);
        return;
    }
    processKeyAndCharEvents(win);
    processMouseButtonEvents(win);
    processMouseMoveEvents(win);
    processMouseWheelEvents(win);
    processSizeChange(win);
}

// Interleave key and text events so they fire in the order the platform
// backend generated them. Key events can arrive before their matching text
// events, so popping one event from each queue per iteration replays the
// original temporal order. Draining keys fully before text meant a
// focus-shifting key (Enter, Tab, Down) typed right after a character changed
// focus before the queued character was inserted, dropping the last password
// byte into the Port field and silently breaking SSH connect via the form.
fn processKeyAndCharEvents(win: anytype) void {
    while (true) {
        var did_anything = false;
        var handled_key = false;
        if (window_backend.popKeyEvent(win)) |ev| {
            handleKey(ev);
            did_anything = true;
            handled_key = true;
        }
        if (window_backend.popCharEvent(win)) |ev| {
            handleChar(ev);
            did_anything = true;
        } else if (handled_key) {
            g_ai_history_suppress_refresh_char = false;
        }
        if (!did_anything) break;
    }
}

fn processMouseButtonEvents(win: anytype) void {
    while (window_backend.popMouseButtonEvent(win)) |ev| {
        handleMouseButton(ev);
    }
}

fn processMouseMoveEvents(win: anytype) void {
    // Only process the latest move event (coalesce)
    var latest: ?platform_input.MouseMoveEvent = null;
    while (window_backend.popMouseMoveEvent(win)) |ev| {
        latest = ev;
    }
    if (latest) |ev| {
        handleMouseMove(ev);
    }
}

fn processMouseWheelEvents(win: anytype) void {
    while (window_backend.popMouseWheelEvent(win)) |ev| {
        handleMouseWheel(ev);
    }
}

fn processSizeChange(win: anytype) void {
    if (!window_backend.consumeSizeChanged(win)) return;
    const size = window_backend.clientSize(win);
    if (window_backend.isMinimized(win) or size.width <= 0 or size.height <= 0) return;
    render_diagnostics.log(
        "input-size-change client={}x{} dpi={} font_dpi={} cell={d:.2}x{d:.2} term={}x{}",
        .{ size.width, size.height, window_backend.effectiveDpi(win), font.g_dpi, font.cell_width, font.cell_height, AppWindow.term_cols, AppWindow.term_rows },
    );
    if (titlebar.setSidebarWidth(titlebar.g_sidebar_width, @floatFromInt(size.width))) {
        syncSidebarWidthToBackend(win);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }

    syncGridFromWindowSize(size.width, size.height);
}

fn handleChar(ev: platform_input.CharEvent) void {
    overlays.startupShortcutsDismiss();
    if (overlays.sessionLauncherVisible()) {
        if (!ev.ctrl and !ev.alt) overlays.sessionLauncherInsertChar(ev.codepoint);
        return;
    }
    if (overlays.commandPaletteVisible()) {
        if (!ev.ctrl and !ev.alt) overlays.commandPaletteInsertChar(ev.codepoint);
        return;
    }
    if (weixinQrPanelConsumesChar()) return;
    if (browser_panel.urlBarFocused()) {
        if (!ev.ctrl and !ev.alt) {
            browser_panel.insertUrlBarChar(ev.codepoint);
            markBrowserUrlBarDirty();
        }
        return;
    }
    // File explorer inline editing
    if (file_explorer.g_focused and file_explorer.isVisibleForActiveTab() and file_explorer.g_op_mode != .none and file_explorer.g_op_mode != .confirm_delete) {
        if (!ev.ctrl and !ev.alt) file_explorer.inputChar(ev.codepoint);
        return;
    }
    // When tab rename is active, route chars to the rename buffer
    if (tab.g_tab_rename_active) {
        AppWindow.g_cursor_blink_visible = true;
        AppWindow.g_last_blink_time = std.time.milliTimestamp();
        tab.handleRenameChar(ev.codepoint);
        return;
    }
    if (AppWindow.activeAiChat()) |chat| {
        if (!ev.ctrl and !ev.alt) {
            AppWindow.resetCursorBlink();
            chat.handleChar(ev.codepoint);
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
        return;
    }
    if (AppWindow.activeAiHistory() != null) {
        if (g_ai_history_suppress_refresh_char) {
            const suppress = !ev.ctrl and !ev.alt and !ev.super and ev.codepoint == 'r';
            g_ai_history_suppress_refresh_char = false;
            if (suppress) return;
        }
        if (!ev.ctrl and !ev.alt and !ev.super) {
            _ = AppWindow.aiHistoryInsertCodepoint(ev.codepoint);
        }
        return;
    }
    // AI copilot sidebar (terminal tabs): when the copilot owns focus, route
    // text input to its composer. `activeCopilotSessionForInput` is non-null
    // only when the panel is visible on the active terminal tab.
    if (aiCopilotFocused()) {
        if (AppWindow.activeCopilotSessionForInput()) |chat| {
            if (!ev.ctrl and !ev.alt) {
                AppWindow.resetCursorBlink();
                chat.handleChar(ev.codepoint);
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
            }
            return;
        }
    }
    if (!AppWindow.isActiveTabTerminal()) return;
    // Skip chars when Alt is held without Ctrl — those are part of Alt+key
    // combos (e.g. Shift+Alt+4) and shouldn't produce text input.
    // However, AltGr on international keyboards reports as Ctrl+Alt, so
    // we must allow chars when both Ctrl and Alt are held (AltGr chars).
    // This matches Ghostty's consumed_mods / effectiveMods approach.
    if (ev.alt and !ev.ctrl) return;
    // Cmd / Super shortcuts (macOS Cmd+C, Win key on other platforms) are
    // commands, not text input — never inject them into the PTY.
    if (ev.super) return;
    const surface = AppWindow.activeSurface() orelse return;
    AppWindow.resetCursorBlink();
    {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        surface.terminal.scrollViewport(.bottom);
    }
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(ev.codepoint, &buf) catch return;
    writeToPty(surface, buf[0..len]);
}

const KeybindPhase = command_dispatch.Phase;

fn triggerFromKeyEvent(ev: platform_input.KeyEvent) keybind.Trigger {
    return .{
        .mods = .{ .ctrl = ev.ctrl, .shift = ev.shift, .alt = ev.alt, .win = ev.super },
        .key_code = @intCast(ev.key_code),
    };
}

fn configuredAction(ev: platform_input.KeyEvent) ?keybind.Action {
    return AppWindow.g_keybinds.lookupApp(triggerFromKeyEvent(ev));
}

fn logicalKeyEvent(ev: platform_input.KeyEvent) input_key.KeyEvent {
    return .{
        .key = logicalKeyFromCode(ev.key_code),
        .ctrl = ev.ctrl,
        .shift = ev.shift,
        .alt = ev.alt,
    };
}

fn logicalKeyFromCode(key_code: platform_input.KeyCode) input_key.Key {
    return switch (key_code) {
        platform_input.key_backspace => .backspace,
        platform_input.key_tab => .tab,
        platform_input.key_enter => .enter,
        platform_input.key_escape => .escape,
        platform_input.key_delete => .delete,
        platform_input.key_home => .home,
        platform_input.key_end => .end,
        platform_input.key_page_up => .page_up,
        platform_input.key_page_down => .page_down,
        platform_input.key_insert => .insert,
        platform_input.key_up => .arrow_up,
        platform_input.key_down => .arrow_down,
        platform_input.key_left => .arrow_left,
        platform_input.key_right => .arrow_right,
        0x41 => .key_a,
        0x43 => .key_c,
        0x45 => .key_e,
        0x48 => .key_h,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4E => .key_n,
        0x50 => .key_p,
        0x53 => .key_s,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x59 => .key_y,
        else => .unidentified,
    };
}

test "input: logical key mapping includes session launcher H mnemonic" {
    try std.testing.expectEqual(input_key.Key.key_h, logicalKeyFromCode(0x48));
}

fn actionIs(action: ?keybind.Action, expected: keybind.Action) bool {
    return if (action) |actual| actual == expected else false;
}

fn commitTabRenameIfActive() void {
    if (tab.g_tab_rename_active) tab.commitTabRename();
}

fn currentClientWidthOr(default: f64) ?f64 {
    const win = AppWindow.g_window orelse return null;
    const rect = window_backend.clientRect(win) orelse return default;
    return @floatFromInt(rect.right);
}

fn requestNewWindowFromActiveCwd() void {
    const app = AppWindow.g_app orelse return;
    const handle = AppWindow.currentNativeHandle();

    var cwd_buf: platform_pty_command.CwdBuffer = undefined;
    var cwd: ?platform_pty_command.CwdSlice = null;
    if (AppWindow.activeSurface()) |surface| {
        if (surface.getCwd()) |guest_path| {
            std.debug.print("CWD from OSC 7: {s}\n", .{guest_path});
            if (platform_wsl.guestPathToNativeCwd(guest_path, &cwd_buf)) |native_cwd| {
                cwd = native_cwd;
                var path_u8: [260]u8 = undefined;
                var display_buf: platform_pty_command.CwdBuffer = undefined;
                if (platform_wsl.guestPathToLocalPathUtf8(guest_path, &display_buf, &path_u8)) |local_path| {
                    std.debug.print("Converted to local path: {s}\n", .{local_path});
                }
            } else {
                std.debug.print("Failed to convert WSL guest path to local path\n", .{});
            }
        } else {
            std.debug.print("No CWD from active surface (OSC 7 not received)\n", .{});
        }
    }
    app.requestNewWindow(handle, cwd);
}

fn handleConfiguredKeybindAction(action: keybind.Action, phase: KeybindPhase) bool {
    const cmd = command_dispatch.resolve(action, phase) orelse return false;
    if (phase == .early) commitTabRenameIfActive();
    return executeCommand(cmd);
}

/// Dispatch a keybind action through both early and late phases. Used by UI
/// entrypoints (NSMenu items, future buttons) so a click takes the same path
/// as a keyboard shortcut without reproducing the early/late split logic.
pub fn invokeKeybindAction(action: keybind.Action) bool {
    if (handleConfiguredKeybindAction(action, .early)) return true;
    return handleConfiguredKeybindAction(action, .late);
}

fn executeCommand(cmd: command_dispatch.Command) bool {
    switch (cmd) {
        // Early
        .toggle_quake => AppWindow.toggleQuakeVisibility(),
        .toggle_command_palette => overlays.commandPaletteToggle(),
        .new_window => requestNewWindowFromActiveCwd(),
        .new_session => overlays.sessionLauncherOpen(),
        .split_right => AppWindow.splitFocused(.right),
        .toggle_file_explorer => toggleFileExplorer(),
        .toggle_sidebar => toggleSidebar(),
        .toggle_ai_copilot => AppWindow.toggleAiCopilot(),
        .close_panel_or_tab => closePanelOrTab(),
        .toggle_maximize => toggleMaximize(),
        .font_size => |delta| adjustFontSize(delta),
        // Late
        .copy => copySelectionToClipboard(),
        .paste => {
            if (AppWindow.activeAiChat()) |chat| {
                pasteFromClipboardIntoAiChat(chat);
            } else if (aiCopilotFocused()) {
                if (AppWindow.activeCopilotSessionForInput()) |chat| {
                    pasteFromClipboardIntoAiChat(chat);
                } else {
                    pasteFromClipboard();
                }
            } else {
                pasteFromClipboard();
            }
        },
        .paste_image => {
            if (AppWindow.activeAiChat()) |chat| {
                pasteImageIntoAiChat(chat);
            } else if (aiCopilotFocused()) {
                if (AppWindow.activeCopilotSessionForInput()) |chat| {
                    pasteImageIntoAiChat(chat);
                } else {
                    pasteImageFromClipboard();
                }
            } else {
                pasteImageFromClipboard();
            }
        },
        // Panel-focus shortcuts are "performable": if there is no pane in
        // the requested direction, don't consume the key so it falls
        // through to the terminal (e.g. Alt+Up reaches a TUI like Claude
        // Code as \x1b[1;3A when running in a single pane).
        .focus_split => |target| return switch (target) {
            .left => AppWindow.gotoSplit(.{ .spatial = .left }),
            .right => AppWindow.gotoSplit(.{ .spatial = .right }),
            .up => AppWindow.gotoSplit(.{ .spatial = .up }),
            .down => AppWindow.gotoSplit(.{ .spatial = .down }),
            .previous => AppWindow.gotoSplit(.previous_wrapped),
            .next => AppWindow.gotoSplit(.next_wrapped),
        },
        // Numeric panel focus: like focus_split, "performable" — if there is no
        // panel at that index (single-panel tab, or index past the panel count),
        // don't consume the key so it falls through to the terminal.
        .focus_panel => |n| return AppWindow.focusPanel(n),
        .equalize_splits => AppWindow.equalizeSplits(),
        .next_tab => AppWindow.switchTab((active_tab_state.g_active_tab + 1) % tab.g_tab_count),
        .previous_tab => {
            if (active_tab_state.g_active_tab > 0) AppWindow.switchTab(active_tab_state.g_active_tab - 1) else AppWindow.switchTab(tab.g_tab_count - 1);
        },
        .open_config => {
            std.debug.print("[keybind] open_config pressed\n", .{});
            if (AppWindow.g_allocator) |alloc| Config.openConfigInEditor(alloc);
        },
        .switch_tab => |idx| {
            if (idx < tab.g_tab_count) AppWindow.switchTab(idx);
        },
    }
    return true;
}

fn handleKey(ev: platform_input.KeyEvent) void {
    overlays.startupShortcutsDismiss();
    const key_event = logicalKeyEvent(ev);
    if (overlays.windowCloseConfirmVisible()) {
        overlays.windowCloseConfirmHandleKey(key_event);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    if (overlays.transferCancelConfirmVisible()) {
        switch (overlays.transferCancelConfirmHandleKey(key_event)) {
            .interrupt => _ = file_explorer.cancelActiveTransfer(),
            .keep, .none => {},
        }
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    const action = configuredAction(ev);
    const is_close_shortcut = actionIs(action, .close_panel_or_tab);
    if (!is_close_shortcut and !isModifierKey(ev.key_code)) g_close_shortcut_confirm_until_ms = 0;
    if (overlays.sessionLauncherVisible()) {
        if (actionIs(action, .paste)) {
            if (pasteClipboardIntoSessionLauncher()) {
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
            }
            return;
        }
        overlays.sessionLauncherHandleKey(key_event);
        return;
    }
    if (action) |app_action| {
        if (handleConfiguredKeybindAction(app_action, .early)) return;
    }
    if (overlays.commandPaletteVisible()) {
        if (overlays.commandPaletteAgentHistoryVisible()) {
            switch (ev.key_code) {
                platform_input.key_escape => overlays.commandPaletteLeaveAgentHistory(),
                platform_input.key_up => overlays.commandPaletteMoveAgentHistory(-1),
                platform_input.key_down => overlays.commandPaletteMoveAgentHistory(1),
                platform_input.key_enter => overlays.commandPaletteExecuteSelected(),
                platform_input.key_delete => _ = overlays.commandPaletteDeleteSelectedAgentHistory(),
                else => {},
            }
        } else {
            switch (ev.key_code) {
                platform_input.key_escape => overlays.commandPaletteClose(),
                platform_input.key_up => overlays.commandPaletteMove(-1),
                platform_input.key_down => overlays.commandPaletteMove(1),
                platform_input.key_enter => overlays.commandPaletteExecuteSelected(),
                platform_input.key_backspace => overlays.commandPaletteBackspace(),
                platform_input.key_delete => overlays.commandPaletteClearFilter(),
                else => {},
            }
        }
        return;
    }
    if (overlays.restoreDefaultsConfirmVisible()) {
        overlays.restoreDefaultsConfirmHandleKey(key_event);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    if (overlays.settingsPageVisible()) {
        overlays.settingsPageHandleKey(key_event);
        return;
    }
    if (AppWindow.weixin_qr_panel.visible()) {
        switch (ev.key_code) {
            platform_input.key_escape => overlays.weixinQrPanelHandleAction(.close),
            platform_input.key_enter => if (AppWindow.weixin_qr_panel.status() == .expired) overlays.weixinQrPanelHandleAction(.retry),
            else => {},
        }
        return;
    }
    // File explorer key handling (when focused and in operation mode)
    if (file_explorer.g_focused and file_explorer.isVisibleForActiveTab()) {
        if (handleFileExplorerKey(ev)) return;
    }
    // When tab rename is active, handle special keys
    if (tab.g_tab_rename_active) {
        AppWindow.g_cursor_blink_visible = true;
        AppWindow.g_last_blink_time = std.time.milliTimestamp();
        tab.handleRenameKey(key_event);
        return;
    }
    if (browser_panel.urlBarFocused()) {
        handleBrowserUrlBarKey(ev);
        return;
    }
    if (AppWindow.activeAiChat()) |chat| {
        // Accept Cmd (super, macOS) or Ctrl (Windows) for chat editing keys.
        const mod = ev.ctrl or ev.super;
        if (mod and !ev.alt and ev.key_code == 0x41) { // select all
            chat.selectAll();
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
            return;
        }
        if (mod and !ev.alt and ev.key_code == 0x43) { // copy
            copyAiChatToClipboard(chat);
            return;
        }
        if (mod and !ev.alt and ev.key_code == 0x58) { // cut input
            copyAiChatCutToClipboard(chat);
            return;
        }
    }
    // AI copilot sidebar editing-mod keys (select-all / copy / cut), mirroring
    // the ai_chat tab block above but for the copilot session.
    if (aiCopilotFocused()) {
        if (AppWindow.activeCopilotSessionForInput()) |chat| {
            const mod = ev.ctrl or ev.super;
            if (mod and !ev.alt and ev.key_code == 0x41) { // select all
                chat.selectAll();
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                return;
            }
            if (mod and !ev.alt and ev.key_code == 0x43) { // copy
                copyAiChatToClipboard(chat);
                return;
            }
            if (mod and !ev.alt and ev.key_code == 0x58) { // cut input
                copyAiChatCutToClipboard(chat);
                return;
            }
        }
    }
    if (action) |app_action| {
        if (handleConfiguredKeybindAction(app_action, .late)) return;
    }

    if (AppWindow.activeAiChat()) |chat| {
        if (isAiChatKey(ev)) {
            AppWindow.resetCursorBlink();
            chat.handleKeyWithWrapCols(key_event, aiChatInputWrapCols());
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
            return;
        }
    }

    if (AppWindow.activeAiHistory() != null) {
        const plain = !ev.ctrl and !ev.alt and !ev.super;
        switch (ev.key_code) {
            platform_input.key_backspace => {
                _ = AppWindow.aiHistoryBackspaceFilter();
                return;
            },
            platform_input.key_up => {
                _ = AppWindow.aiHistoryNav(-1);
                return;
            },
            platform_input.key_down => {
                _ = AppWindow.aiHistoryNav(1);
                return;
            },
            platform_input.key_left => {
                _ = AppWindow.aiHistoryFocusMove(-1);
                return;
            },
            platform_input.key_right => {
                _ = AppWindow.aiHistoryFocusMove(1);
                return;
            },
            platform_input.key_enter => {
                _ = AppWindow.aiHistoryLoadSelectedTranscript();
                return;
            },
            platform_input.key_page_up => {
                _ = AppWindow.aiHistoryScrollTranscript(-8);
                return;
            },
            platform_input.key_page_down => {
                _ = AppWindow.aiHistoryScrollTranscript(8);
                return;
            },
            platform_input.key_home => {
                _ = AppWindow.aiHistoryScrollTranscript(-(1 << 30));
                return;
            },
            platform_input.key_end => {
                _ = AppWindow.aiHistoryScrollTranscript(1 << 30);
                return;
            },
            0x20 => if (plain) {
                _ = AppWindow.aiHistoryPreviewSelectedTranscript();
                return;
            },
            0x52 => if (plain and !ev.shift) {
                g_ai_history_suppress_refresh_char = AppWindow.aiHistoryScanLocalNow();
                return;
            },
            else => {},
        }
        return;
    }

    // AI copilot sidebar (terminal tabs): route editing/navigation keys to the
    // copilot composer. Esc is intercepted specially so it never reaches the
    // terminal — it stops an in-flight request, or hides the panel when idle.
    if (aiCopilotFocused()) {
        if (AppWindow.activeCopilotSessionForInput()) |chat| {
            if (ev.key_code == platform_input.key_escape) {
                // Progressive Esc: stop an in-flight request, else clear an
                // active selection, else hide the panel. Matches the AI-chat
                // tab's stop/clear behavior; closing is only the final step,
                // so Esc never abruptly dismisses a panel that still has a
                // selection to clear.
                if (chat.requestState().inflight) {
                    chat.stopRequest();
                } else if (chat.hasSelection()) {
                    chat.clearSelection();
                } else {
                    AppWindow.hideAiCopilot();
                }
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                return;
            }
            if (isAiChatKey(ev)) {
                AppWindow.resetCursorBlink();
                chat.handleKeyWithWrapCols(key_event, aiCopilotInputWrapCols());
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                return;
            }
        }
    }

    // Don't send input to PTY if active tab isn't the terminal
    if (!AppWindow.isActiveTabTerminal()) return;

    const surface = AppWindow.activeSurface() orelse return;

    // Track whether this keypress actually sends data to the PTY.
    // Like Ghostty, we only scroll-to-bottom when input is actually generated,
    // not for modifier-only keys or key combos that don't produce PTY output.
    var wrote_to_pty = false;

    const seq: ?[]const u8 = switch (ev.key_code) {
        platform_input.key_enter => "\r",
        platform_input.key_backspace => "\x7f",
        platform_input.key_tab => if (ev.shift) "\x1b[Z" else "\t",
        platform_input.key_escape => "\x1b",
        platform_input.key_up, platform_input.key_down, platform_input.key_right, platform_input.key_left => input_shortcuts.terminalArrowSequence(key_event, surface.terminal.modes.get(.cursor_keys)),
        platform_input.key_home => "\x1b[H",
        platform_input.key_end => "\x1b[F",
        platform_input.key_page_up => blk: { // Page Up
            if (ev.shift) {
                surface.render_state.mutex.lock();
                surface.terminal.scrollViewport(.{ .delta = -@as(isize, AppWindow.term_rows / 2) });
                surface.render_state.mutex.unlock();
                overlays.scrollbarShow();
                break :blk null;
            }
            break :blk "\x1b[5~";
        },
        platform_input.key_page_down => blk: { // Page Down
            if (ev.shift) {
                surface.render_state.mutex.lock();
                surface.terminal.scrollViewport(.{ .delta = @as(isize, AppWindow.term_rows / 2) });
                surface.render_state.mutex.unlock();
                overlays.scrollbarShow();
                break :blk null;
            }
            break :blk "\x1b[6~";
        },
        platform_input.key_insert => "\x1b[2~",
        platform_input.key_delete => "\x1b[3~",
        else => blk: {
            // Ctrl+A through Ctrl+Z
            if (ev.ctrl and ev.key_code >= 0x41 and ev.key_code <= 0x5A) {
                // Shifted Ctrl+letter chords are application shortcuts above.
                if (!ev.shift) {
                    const ctrl_char: u8 = @intCast(ev.key_code - 0x41 + 1);
                    writeToPty(surface, &[_]u8{ctrl_char});
                    wrote_to_pty = true;
                }
            }
            break :blk null;
        },
    };

    if (seq) |s| {
        writeToPty(surface, s);
        wrote_to_pty = true;
    }

    // Only scroll to bottom and reset cursor blink when we actually sent
    // data to the PTY. This matches Ghostty's behavior: modifier-only keys,
    // unbound key combos (like Shift+Alt+4), and scroll keys don't snap
    // the viewport to the bottom.
    if (wrote_to_pty) {
        AppWindow.resetCursorBlink();
        surface.render_state.mutex.lock();
        surface.terminal.scrollViewport(.bottom);
        surface.render_state.mutex.unlock();
    }
}

fn isModifierKey(key_code: platform_input.KeyCode) bool {
    return key_code == platform_input.key_shift or
        key_code == platform_input.key_control or
        key_code == platform_input.key_alt or
        key_code == platform_input.key_left_shift or
        key_code == platform_input.key_right_shift or
        key_code == platform_input.key_left_control or
        key_code == platform_input.key_right_control or
        key_code == platform_input.key_left_alt or
        key_code == platform_input.key_right_alt;
}

fn isAiChatKey(ev: platform_input.KeyEvent) bool {
    if (ev.key_code == platform_input.key_enter or
        ev.key_code == platform_input.key_backspace or
        ev.key_code == platform_input.key_delete or
        ev.key_code == platform_input.key_left or
        ev.key_code == platform_input.key_right or
        ev.key_code == platform_input.key_up or
        ev.key_code == platform_input.key_down or
        ev.key_code == platform_input.key_home or
        ev.key_code == platform_input.key_end or
        ev.key_code == platform_input.key_tab or
        ev.key_code == platform_input.key_escape) return true;
    if (ev.ctrl and !ev.alt and (ev.key_code == 0x41 or ev.key_code == 0x55 or ev.key_code == 0x4C)) return true; // Ctrl+A / Ctrl+U / Ctrl+L
    return false;
}

fn aiChatInputWrapCols() usize {
    const win = AppWindow.g_window orelse return std.math.maxInt(usize);
    const size = clientSize(win);
    const ww: f32 = @floatFromInt(size.width);
    const panel_w = @max(1.0, ww - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidth());
    return AppWindow.ai_chat_renderer.inputWrapColumns(panel_w);
}

/// Wrap columns for the AI copilot sidebar's composer. Mirrors
/// `aiChatInputWrapCols` but uses the sidebar/copilot panel width rather than
/// the full-tab chat width.
fn aiCopilotInputWrapCols() usize {
    const win = AppWindow.g_window orelse return std.math.maxInt(usize);
    const size = clientSize(win);
    const panel_w = AppWindow.aiCopilotWidth(size.width);
    return AppWindow.ai_chat_renderer.inputWrapColumns(panel_w);
}

fn handleBrowserUrlBarKey(ev: platform_input.KeyEvent) void {
    // Accept Cmd (super, macOS) or Ctrl (Windows) for text-field editing keys.
    const mod = ev.ctrl or ev.super;
    if (mod and !ev.shift and !ev.alt and ev.key_code == 0x41) { // Ctrl/Cmd+A
        browser_panel.selectAllUrlBar();
        markBrowserUrlBarDirty();
        return;
    }
    if (mod and !ev.shift and !ev.alt and ev.key_code == 0x56) { // Ctrl/Cmd+V
        if (pasteClipboardIntoBrowserUrlBar()) markBrowserUrlBarDirty();
        return;
    }

    switch (ev.key_code) {
        platform_input.key_escape => {
            browser_panel.blurUrlBar();
            markBrowserUrlBarDirty();
        },
        platform_input.key_enter => {
            const allocator = AppWindow.g_allocator orelse return;
            const parent = AppWindow.currentNativeHandle();
            _ = browser_panel.submitUrlBar(allocator, parent, AppWindow.activeSurface());
            markBrowserUrlBarDirty();
        },
        platform_input.key_backspace => {
            browser_panel.backspaceUrlBar();
            markBrowserUrlBarDirty();
        },
        platform_input.key_delete => {
            browser_panel.clearUrlBar();
            markBrowserUrlBarDirty();
        },
        else => {},
    }
}

fn sidebarLayout() hit_test.SidebarLayout {
    return .{
        .visible = tab.g_sidebar_visible,
        .titlebar_h = titlebarHeight(),
        .width = @floatCast(titlebar.sidebarWidth()),
        .header_h = @floatCast(titlebar.sidebarHeaderHeight()),
        .row_h = @floatCast(titlebar.sidebarRowHeight()),
        .tab_count = tab.g_tab_count,
        .resize_hit_width = @floatCast(titlebar.SIDEBAR_RESIZE_HIT_WIDTH),
        .close_btn_w = @floatCast(tab.TAB_CLOSE_BTN_W),
    };
}

fn hitTestSidebarTab(xpos: f64, ypos: f64) ?usize {
    return hit_test.sidebarTabAt(sidebarLayout(), xpos, ypos);
}

fn resetSidebarTabDragState() void {
    g_sidebar_tab_drag_pressed = null;
    g_sidebar_tab_drag_current = null;
    g_sidebar_tab_drag_start_x = 0;
    g_sidebar_tab_drag_start_y = 0;
    g_sidebar_tab_drag_active = false;
}

fn beginSidebarTabPotentialDrag(tab_idx: usize, xpos: f64, ypos: f64) void {
    if (tab.g_tab_count <= 1) return;
    g_sidebar_tab_drag_pressed = tab_idx;
    g_sidebar_tab_drag_current = tab_idx;
    g_sidebar_tab_drag_start_x = xpos;
    g_sidebar_tab_drag_start_y = ypos;
    g_sidebar_tab_drag_active = false;
}

fn sidebarTabIndexForDragY(ypos: f64) ?usize {
    return hit_test.sidebarTabIndexForDragY(sidebarLayout(), ypos);
}

fn updateSidebarTabDrag(xpos: f64, ypos: f64) bool {
    const current = g_sidebar_tab_drag_current orelse return false;
    if (!tab.g_sidebar_visible or tab.g_tab_count <= 1 or current >= tab.g_tab_count) {
        resetSidebarTabDragState();
        return false;
    }

    if (!g_sidebar_tab_drag_active) {
        const dx = xpos - g_sidebar_tab_drag_start_x;
        const dy = ypos - g_sidebar_tab_drag_start_y;
        const distance = @sqrt(dx * dx + dy * dy);
        if (distance < SIDEBAR_TAB_DRAG_THRESHOLD_PX) return true;
        g_sidebar_tab_drag_active = true;
        g_selecting = false;
    }

    const target = sidebarTabIndexForDragY(ypos) orelse return true;
    if (target != current and AppWindow.reorderTab(current, target)) {
        g_sidebar_tab_drag_current = target;
    }

    return true;
}

fn finishSidebarTabDrag() bool {
    const consumed = g_sidebar_tab_drag_pressed != null or g_sidebar_tab_drag_active;
    resetSidebarTabDragState();
    return consumed;
}

fn hitTestSidebarPlusButton(xpos: f64, ypos: f64) bool {
    return hit_test.sidebarPlusButton(sidebarLayout(), xpos, ypos);
}

fn hitTestSidebarTabCloseButton(xpos: f64, ypos: f64, tab_idx: usize) bool {
    return hit_test.sidebarTabCloseButton(sidebarLayout(), xpos, ypos, tab_idx);
}

fn shouldStartSidebarTabRename(xpos: f64, ypos: f64, tab_idx: usize) bool {
    if (tab_idx >= tab.g_tab_count) return false;
    const layout = sidebarLayout();
    if (hit_test.sidebarPlusButton(layout, xpos, ypos)) return false;
    if (hit_test.sidebarResizeHandle(layout, xpos, ypos)) return false;
    if (hit_test.sidebarTabCloseButton(layout, xpos, ypos, tab_idx)) return false;
    return true;
}

fn hitTestSidebarResizeHandle(xpos: f64, ypos: f64) bool {
    return hit_test.sidebarResizeHandle(sidebarLayout(), xpos, ypos);
}

fn applySidebarWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    if (!titlebar.setSidebarWidth(@floatCast(xpos), @floatFromInt(size.width))) return;
    syncGridFromWindow(win);
    syncSidebarWidthToBackend(win);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn hitTestFileExplorer(xpos: f64, ypos: f64) bool {
    if (!file_explorer.isVisibleForActiveTab()) return false;
    if (ypos < titlebarHeight()) return false;
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    return xpos >= panel_x and xpos < panel_right;
}

fn fileExplorerHeaderLayout() ?hit_test.PanelHeaderLayout {
    if (!file_explorer.isVisibleForActiveTab()) return null;
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    return .{
        .visible = true,
        .left = panel_x,
        .right = panel_right,
        .top = titlebarHeight(),
        .height = @floatCast(file_explorer.headerHeight()),
    };
}

fn hitTestFileExplorerCloseButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderCloseButton(fileExplorerHeaderLayout() orelse return false, xpos, ypos);
}

fn hitTestMarkdownPreviewPanel(xpos: f64, ypos: f64) bool {
    if (!markdown_preview_panel.isVisibleForActiveTab()) return false;
    if (ypos < titlebarHeight()) return false;
    const win = AppWindow.g_window orelse return false;
    const size = clientSize(win);
    const preview_w: f64 = @floatCast(markdown_preview_panel.width());
    const panel_x: f64 = @as(f64, @floatFromInt(size.width)) - preview_w;
    return xpos >= panel_x and xpos < panel_x + preview_w;
}

fn markdownPreviewHeaderLayout() ?hit_test.PanelHeaderLayout {
    if (!markdown_preview_panel.isVisibleForActiveTab()) return null;
    const win = AppWindow.g_window orelse return null;
    const size = clientSize(win);
    const preview_w: f64 = @floatCast(markdown_preview_panel.width());
    const panel_x: f64 = @as(f64, @floatFromInt(size.width)) - preview_w;
    return .{
        .visible = true,
        .left = panel_x,
        .right = panel_x + preview_w,
        .top = titlebarHeight(),
        .height = @floatCast(AppWindow.markdown_preview_renderer.HEADER_HEIGHT),
    };
}

fn hitTestMarkdownPreviewCloseButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderCloseButton(markdownPreviewHeaderLayout() orelse return false, xpos, ypos);
}

fn hitTestMarkdownPreviewHeader(xpos: f64, ypos: f64) bool {
    const layout = markdownPreviewHeaderLayout() orelse return false;
    return xpos >= layout.left and xpos < layout.right and
        ypos >= layout.top and ypos < layout.top + layout.height;
}

fn browserPanelBounds() ?browser_panel.Bounds {
    if (!browser_panel.isVisibleForActiveTab()) return null;
    const win = AppWindow.g_window orelse return null;
    const size = clientSize(win);
    return browser_panel.boundsForWindow(
        size.width,
        size.height,
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        AppWindow.browserPanelRightOffset(),
    );
}

fn hitTestBrowserPanel(xpos: f64, ypos: f64) bool {
    const bounds = browserPanelBounds() orelse return false;
    return xpos >= @as(f64, @floatFromInt(bounds.left)) and
        xpos < @as(f64, @floatFromInt(bounds.right)) and
        ypos >= @as(f64, @floatFromInt(bounds.top)) and
        ypos < @as(f64, @floatFromInt(bounds.bottom));
}

fn hitTestBrowserUrlBar(xpos: f64, ypos: f64) bool {
    const bounds = browserPanelBounds() orelse return false;
    const url_bar = browser_panel.urlBarBounds(bounds) orelse return false;
    return xpos >= @as(f64, @floatFromInt(url_bar.left)) and
        xpos < @as(f64, @floatFromInt(url_bar.right)) and
        ypos >= @as(f64, @floatFromInt(url_bar.top)) and
        ypos < @as(f64, @floatFromInt(url_bar.bottom));
}

fn browserHeaderLayout() ?hit_test.PanelHeaderLayout {
    const bounds = browserPanelBounds() orelse return null;
    const url_bar = browser_panel.urlBarBounds(bounds) orelse return null;
    return .{
        .visible = true,
        .left = @floatFromInt(url_bar.left),
        .right = @floatFromInt(url_bar.right),
        .top = @floatFromInt(url_bar.top),
        .height = @floatFromInt(url_bar.bottom - url_bar.top),
    };
}

fn hitTestBrowserCloseButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderCloseButton(browserHeaderLayout() orelse return false, xpos, ypos);
}

fn aiCopilotHeaderLayout() ?hit_test.PanelHeaderLayout {
    if (!AppWindow.aiCopilotVisible()) return null;
    const win = AppWindow.g_window orelse return null;
    const fb = window_backend.framebufferSize(win);
    const bounds = ai_sidebar.boundsForWindow(
        @intCast(fb.width),
        @intCast(fb.height),
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        0,
    );
    return .{
        .visible = true,
        .left = @floatFromInt(bounds.left),
        .right = @floatFromInt(bounds.right),
        .top = @floatFromInt(bounds.top),
        .height = @floatCast(AppWindow.ai_chat_renderer.HEADER_H),
    };
}

fn hitTestAiCopilotCloseButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderCloseButton(aiCopilotHeaderLayout() orelse return false, xpos, ypos);
}

fn hitTestBrowserResizeHandle(xpos: f64, ypos: f64) bool {
    if (!browser_panel.isVisibleForActiveTab()) return false;
    if (ypos < titlebarHeight()) return false;
    const bounds = browserPanelBounds() orelse return false;
    const panel_x: f64 = @floatFromInt(bounds.left);
    const half_hit: f64 = @as(f64, @floatCast(browser_panel.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_x - half_hit and xpos <= panel_x + half_hit;
}

fn applyBrowserWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    const right_edge = @as(f64, @floatFromInt(size.width)) - @as(f64, @floatCast(AppWindow.browserPanelRightOffset()));
    const new_width = right_edge - xpos;
    const available_width: f32 = @as(f32, @floatFromInt(size.width)) - AppWindow.leftPanelsWidth() - AppWindow.browserPanelRightOffset();
    if (!browser_panel.setWidth(@floatCast(new_width), available_width)) return;
    syncGridFromWindow(win);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

// AI copilot panel resize grip. The copilot is right-docked (right_offset 0)
// and its bounds are computed against framebufferSize everywhere (renderer +
// click handling), so the hit-test/apply mirror the browser resize structure
// but read the framebuffer size to track the panel's actual left edge.
fn hitTestAiCopilotResizeHandle(xpos: f64, ypos: f64) bool {
    if (!AppWindow.aiCopilotVisible()) return false;
    if (ypos < titlebarHeight()) return false;
    const win = AppWindow.g_window orelse return false;
    const fb = window_backend.framebufferSize(win);
    const bounds = ai_sidebar.boundsForWindow(
        @intCast(fb.width),
        @intCast(fb.height),
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        0,
    );
    const panel_x: f64 = @floatFromInt(bounds.left);
    const half_hit: f64 = @as(f64, @floatCast(ai_sidebar.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_x - half_hit and xpos <= panel_x + half_hit;
}

fn applyAiCopilotWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const fb = window_backend.framebufferSize(win);
    // Right-docked at the far right edge (right_offset 0): width grows as the
    // mouse moves left, same as the browser's right-edge math.
    const right_edge = @as(f64, @floatFromInt(fb.width));
    const new_width = right_edge - xpos;
    const available_width: f32 = @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth();
    if (!ai_sidebar.setWidth(@floatCast(new_width), available_width)) return;
    syncGridFromWindow(win);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn hitTestMarkdownPreviewResizeHandle(xpos: f64, ypos: f64) bool {
    if (!markdown_preview_panel.isVisibleForActiveTab()) return false;
    if (ypos < titlebarHeight()) return false;
    const win = AppWindow.g_window orelse return false;
    const size = clientSize(win);
    const preview_w: f64 = @floatCast(markdown_preview_panel.width());
    const panel_x: f64 = @as(f64, @floatFromInt(size.width)) - preview_w;
    const half_hit: f64 = @as(f64, @floatCast(markdown_preview_panel.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_x - half_hit and xpos <= panel_x + half_hit;
}

fn applyMarkdownPreviewWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    const right_edge = @as(f64, @floatFromInt(size.width));
    const new_width = right_edge - xpos;
    if (!markdown_preview_panel.setWidth(@floatCast(new_width), @floatFromInt(size.width))) return;
    syncGridFromWindow(win);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn hitTestFileExplorerResizeHandle(xpos: f64, ypos: f64) bool {
    if (!file_explorer.isVisibleForActiveTab()) return false;
    if (ypos < titlebarHeight()) return false;
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    const half_hit: f64 = @as(f64, @floatCast(file_explorer.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_right - half_hit and xpos <= panel_right + half_hit;
}

fn applyExplorerWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const new_width = xpos - panel_x;
    if (!file_explorer.setWidth(@floatCast(new_width), @floatFromInt(size.width))) return;
    syncGridFromWindow(win);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn handleFileExplorerKey(ev: platform_input.KeyEvent) bool {
    if (file_explorer.g_panel_mode == .agent_history) {
        return handleAgentHistoryKey(ev);
    }

    const key_escape = platform_input.key_escape;
    const key_enter = platform_input.key_enter;
    const key_backspace = platform_input.key_backspace;
    const key_up = platform_input.key_up;
    const key_down = platform_input.key_down;

    // In input mode (rename/new file/new dir)
    if (file_explorer.g_op_mode != .none) {
        switch (ev.key_code) {
            key_escape => {
                file_explorer.cancelOp();
                return true;
            },
            key_enter => {
                file_explorer.commitOp();
                return true;
            },
            key_backspace => {
                file_explorer.inputBackspace();
                return true;
            },
            else => return false,
        }
    }

    // Normal navigation mode
    switch (ev.key_code) {
        key_escape => {
            file_explorer.g_focused = false;
            return true;
        },
        key_up => {
            file_explorer.moveSelection(-1);
            return true;
        },
        key_down => {
            file_explorer.moveSelection(1);
            return true;
        },
        key_enter => {
            // Enter on directory = toggle expand
            if (file_explorer.g_selected) |sel| {
                if (sel < file_explorer.g_entry_count and file_explorer.g_entries[sel].is_dir) {
                    file_explorer.toggleExpand(sel);
                }
            }
            return true;
        },
        0x52 => { // 'R' key = rename
            if (!ev.ctrl and !ev.alt and !ev.super) {
                file_explorer.startRename();
                return true;
            }
            return false;
        },
        0x4E => { // 'N' key = new file, Shift+N = new dir
            if (!ev.ctrl and !ev.alt and !ev.super) {
                if (ev.shift) {
                    file_explorer.startNewDir();
                } else {
                    file_explorer.startNewFile();
                }
                return true;
            }
            return false;
        },
        0x44 => { // 'D' key = delete
            if (!ev.ctrl and !ev.alt and !ev.shift and !ev.super) {
                file_explorer.startDelete();
                return true;
            }
            return false;
        },
        0x53 => { // 'S' key: Ctrl/Cmd+S = download selected file
            if ((ev.ctrl or ev.super) and !ev.alt and !ev.shift) {
                if (file_explorer.g_mode == .remote) {
                    // Download to user's Downloads folder
                    var dl_buf: [260]u8 = undefined;
                    const dl_path = getDownloadsFolder(&dl_buf);
                    if (dl_path.len > 0) {
                        file_explorer.downloadSelected(dl_path);
                    }
                    return true;
                }
            }
            return false;
        },
        0x55 => { // 'U' key = upload local file to remote
            if (!ev.ctrl and !ev.alt and !ev.shift and !ev.super) {
                if (file_explorer.g_mode == .remote) {
                    openFileDialogAndUpload();
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn handleAgentHistoryKey(ev: platform_input.KeyEvent) bool {
    switch (ev.key_code) {
        platform_input.key_escape => {
            file_explorer.g_focused = false;
            return true;
        },
        platform_input.key_up => {
            file_explorer.moveHistorySelection(-1);
            return true;
        },
        platform_input.key_down => {
            file_explorer.moveHistorySelection(1);
            return true;
        },
        platform_input.key_enter => {
            activateSelectedAgentHistoryRow();
            return true;
        },
        platform_input.key_delete => {
            deleteSelectedAgentHistoryRow();
            return true;
        },
        0x44 => { // 'D' key = delete history row
            if (!ev.ctrl and !ev.alt and !ev.shift and !ev.super) {
                deleteSelectedAgentHistoryRow();
                return true;
            }
            return false;
        },
        else => return false,
    }
}

fn getDownloadsFolder(buf: *[260]u8) []const u8 {
    const downloads = platform_dirs.downloadsDir(std.heap.page_allocator) catch return "";
    defer std.heap.page_allocator.free(downloads);
    if (downloads.len > buf.len) return "";
    @memcpy(buf[0..downloads.len], downloads);
    return buf[0..downloads.len];
}

fn openFileDialogAndUpload() void {
    const allocator = AppWindow.g_allocator orelse return;
    const filters = [_]platform_file_dialog.Filter{.{ .name = "All Files", .pattern = "*.*" }};
    const owner: platform_file_dialog.Owner = if (AppWindow.currentNativeHandleBits()) |handle_bits|
        platform_file_dialog.windowOwner(handle_bits)
    else
        .{};
    const path = platform_file_dialog.openFile(allocator, .{
        .owner = owner,
        .title = "Upload file to remote",
        .filters = &filters,
    }) orelse return;
    defer allocator.free(path);

    file_explorer.uploadFile(path);
}

fn handleFileExplorerPress(xpos: f64, ypos: f64, ctrl: bool, shift: bool, alt: bool, super: bool) void {
    file_explorer.g_focused = true;

    // Check resize handle first
    if (hitTestFileExplorerResizeHandle(xpos, ypos)) {
        g_explorer_resize_dragging = true;
        g_explorer_resize_hover = true;
        platform_cursor.set(.size_we);
        return;
    }

    if (file_explorer.g_panel_mode == .agent_history) {
        handleAgentHistoryPress(xpos, ypos);
        return;
    }

    // Cancel any active op on click elsewhere in the panel
    if (file_explorer.g_op_mode != .none) {
        file_explorer.cancelOp();
    }

    // Click on a file entry
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    if (xpos < panel_x or xpos >= panel_right) return;

    const titlebar_h = titlebarHeight();
    const header_h: f64 = @floatCast(file_explorer.headerHeight());
    const list_top = titlebar_h + header_h;
    if (ypos < list_top) return;

    const row_h: f64 = @floatCast(file_explorer.rowHeight());
    const scroll: f64 = @floatCast(file_explorer.g_scroll_offset);
    const row_idx: usize = @intFromFloat((ypos - list_top + scroll) / row_h);

    if (row_idx < file_explorer.g_entry_count) {
        const click_count = nextLeftClickCount(xpos, ypos);
        file_explorer.g_selected = row_idx;
        if (!file_explorer.g_entries[row_idx].is_dir and ((primaryOpenMod(ctrl, super) and !shift and !alt) or click_count == 2)) {
            if (openFileExplorerPreview(row_idx)) {
                AppWindow.g_force_rebuild = true;
                return;
            }
        }
        if (file_explorer.g_entries[row_idx].is_dir) {
            file_explorer.toggleExpand(row_idx);
        }
        AppWindow.g_force_rebuild = true;
    }
}

fn handleAgentHistoryPress(xpos: f64, ypos: f64) void {
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    if (xpos < panel_x or xpos >= panel_right) return;

    const titlebar_h = titlebarHeight();
    const header_h: f64 = @floatCast(file_explorer.headerHeight());
    const list_top = titlebar_h + header_h;
    if (ypos < list_top) return;

    const row_h: f64 = @floatCast(file_explorer.rowHeight());
    const scroll: f64 = @floatCast(file_explorer.g_history_scroll_offset);
    const row_idx: usize = @intFromFloat((ypos - list_top + scroll) / row_h);
    if (row_idx >= file_explorer.g_history_row_count) return;

    const click_count = nextLeftClickCount(xpos, ypos);
    file_explorer.g_history_selected = row_idx;
    if (click_count == 2) {
        activateSelectedAgentHistoryRow();
        return;
    }
    AppWindow.g_force_rebuild = true;
}

fn activateSelectedAgentHistoryRow() void {
    const session_id = file_explorer.selectedHistorySessionId() orelse return;
    file_explorer.g_focused = false;
    if (!AppWindow.reopenAiChatTabFromHistorySessionId(session_id)) return;
    file_explorer.g_focused = false;
}

fn deleteSelectedAgentHistoryRow() void {
    const session_id = file_explorer.selectedHistorySessionId() orelse return;
    if (!AppWindow.deleteAiChatHistorySessionId(session_id)) return;
    AppWindow.syncFileExplorerAgentHistoryRows();
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn hitTestConfigButton(xpos: f64, ypos: f64) bool {
    const titlebar_h = titlebarHeight();
    if (ypos < 0 or ypos >= titlebar_h) return false;

    const win = AppWindow.g_window orelse return false;
    const size = clientSize(win);
    const window_width: f64 = @floatFromInt(size.width);
    const caption_w: f64 = 46 * 3;
    const config_w: f64 = @floatCast(titlebar.TITLEBAR_CONFIG_W);
    const config_x = window_width - caption_w - config_w;
    return xpos >= config_x and xpos < config_x + config_w;
}

fn hitTestHelpButton(xpos: f64, ypos: f64) bool {
    const titlebar_h = titlebarHeight();
    if (ypos < 0 or ypos >= titlebar_h) return false;

    const win = AppWindow.g_window orelse return false;
    const size = clientSize(win);
    const window_width: f64 = @floatFromInt(size.width);
    const caption_w: f64 = 46 * 3;
    const config_w: f64 = @floatCast(titlebar.TITLEBAR_CONFIG_W);
    const help_w: f64 = @floatCast(titlebar.TITLEBAR_HELP_W);
    const help_x = window_width - caption_w - config_w - help_w;
    return xpos >= help_x and xpos < help_x + help_w;
}

fn handleTopbarPress(xpos: f64) void {
    const toggle_x: f64 = @floatCast(titlebar.titlebarLeftReserved());
    const toggle_end: f64 = toggle_x + @as(f64, titlebar.TITLEBAR_TOGGLE_W);
    if (xpos >= toggle_x and xpos < toggle_end) {
        toggleSidebar();
        return;
    }

    if (hitTestHelpButton(xpos, titlebarHeight() / 2)) {
        overlays.startupShortcutsToggle();
        return;
    }

    if (hitTestConfigButton(xpos, titlebarHeight() / 2)) {
        overlays.settingsPageOpen();
    }
}

fn handleSidebarPress(xpos: f64, ypos: f64) void {
    if (tab.g_tab_rename_active) tab.commitTabRename();

    if (hitTestSidebarPlusButton(xpos, ypos)) {
        overlays.sessionLauncherOpen();
        return;
    }

    if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
        if (tab.g_tab_count > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1 and hitTestSidebarTabCloseButton(xpos, ypos, tab_idx)) {
            resetSidebarTabDragState();
            tab.g_tab_close_pressed = tab_idx;
            return;
        }
        beginSidebarTabPotentialDrag(tab_idx, xpos, ypos);
        AppWindow.switchTab(tab_idx);
    }
}

fn viewportCellCodepoint(surface: *Surface, col: usize, row: usize) u21 {
    const cell_data = surface.terminal.screens.active.pages.getCell(.{ .viewport = .{
        .x = @intCast(col),
        .y = @intCast(row),
    } }) orelse return 0;
    return @intCast(cell_data.cell.codepoint());
}

fn markSelectionChanged() void {
    g_selection_changed_for_copy = true;
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn nextLeftClickCount(xpos: f64, ypos: f64) u8 {
    const now = std.time.milliTimestamp();
    const max_distance: f64 = @floatCast(@max(font.cell_width, font.cell_height));
    return g_left_click_tracker.register(xpos, ypos, now, max_distance, MULTI_CLICK_INTERVAL_MS);
}

fn resetLeftClickCount() void {
    g_left_click_tracker.reset();
}

fn readViewportRowLocked(surface: *Surface, row: usize, buf: *[MAX_SELECTION_COLS]u21) []const u21 {
    const cols = @min(@as(usize, @intCast(surface.size.grid.cols)), buf.len);
    if (row >= @as(usize, @intCast(surface.size.grid.rows))) return buf[0..0];
    for (0..cols) |col| {
        buf[col] = viewportCellCodepoint(surface, col, row);
    }
    return buf[0..cols];
}

fn viewportRowIsBlankLocked(surface: *Surface, row: usize, buf: *[MAX_SELECTION_COLS]u21) bool {
    return selection_unit.rowIsBlank(readViewportRowLocked(surface, row, buf));
}

fn activateSelection(surface: *Surface, start_col: usize, start_row: usize, end_col: usize, end_row: usize) void {
    surface.selection.has_anchor = true;
    surface.selection.start_col = start_col;
    surface.selection.start_row = start_row;
    surface.selection.end_col = end_col;
    surface.selection.end_row = end_row;
    surface.selection.active = true;
    markSelectionChanged();
}

fn clearSelectionAtCell(surface: *Surface, cell_pos: CellPos) void {
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    surface.selection.has_anchor = true;
    surface.selection.start_col = cell_pos.col;
    surface.selection.start_row = abs_row;
    surface.selection.end_col = cell_pos.col;
    surface.selection.end_row = abs_row;
    surface.selection.active = false;
    markSelectionChanged();
}

fn startSelectionAtCell(surface: *Surface, cell_pos: CellPos, xpos: f64, ypos: f64) void {
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    surface.selection.has_anchor = true;
    surface.selection.start_col = cell_pos.col;
    surface.selection.start_row = abs_row;
    surface.selection.end_col = cell_pos.col;
    surface.selection.end_row = abs_row;
    surface.selection.active = false;
    g_selecting = true;
    g_click_x = xpos;
    g_click_y = ypos;
    markSelectionChanged();
}

fn extendSelectionAtCell(surface: *Surface, cell_pos: CellPos, xpos: f64, ypos: f64) bool {
    if (!surface.selection.has_anchor) return false;
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    const same_cell = surface.selection.start_col == cell_pos.col and surface.selection.start_row == abs_row;
    surface.selection.end_col = cell_pos.col;
    surface.selection.end_row = abs_row;
    surface.selection.active = !same_cell;
    g_selecting = true;
    g_click_x = xpos;
    g_click_y = ypos;
    markSelectionChanged();
    return true;
}

fn selectWordAtCell(surface: *Surface, cell_pos: CellPos) bool {
    var row_buf: [MAX_SELECTION_COLS]u21 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const row = readViewportRowLocked(surface, cell_pos.row, &row_buf);
    if (cell_pos.col >= row.len) return false;
    const range = selection_unit.wordRange(row, cell_pos.col) orelse return false;
    const abs_row = viewportOffsetForSurfaceLocked(surface) + cell_pos.row;
    activateSelection(surface, range.start, abs_row, range.end, abs_row);
    return true;
}

fn selectSentenceAtCell(surface: *Surface, cell_pos: CellPos) bool {
    var row_buf: [MAX_SELECTION_COLS]u21 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const row = readViewportRowLocked(surface, cell_pos.row, &row_buf);
    if (cell_pos.col >= row.len) return false;
    const range = selection_unit.sentenceRange(row, cell_pos.col) orelse return false;
    const abs_row = viewportOffsetForSurfaceLocked(surface) + cell_pos.row;
    activateSelection(surface, range.start, abs_row, range.end, abs_row);
    return true;
}

fn selectParagraphAtCell(surface: *Surface, cell_pos: CellPos) bool {
    var row_buf: [MAX_SELECTION_COLS]u21 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const rows = @as(usize, @intCast(surface.size.grid.rows));
    if (cell_pos.row >= rows or viewportRowIsBlankLocked(surface, cell_pos.row, &row_buf)) return false;

    var start_row = cell_pos.row;
    while (start_row > 0 and !viewportRowIsBlankLocked(surface, start_row - 1, &row_buf)) : (start_row -= 1) {}

    var end_row = cell_pos.row;
    while (end_row + 1 < rows and !viewportRowIsBlankLocked(surface, end_row + 1, &row_buf)) : (end_row += 1) {}

    const start_cols = readViewportRowLocked(surface, start_row, &row_buf);
    const start_col = selection_unit.firstNonBlankCol(start_cols) orelse 0;
    const end_cols = readViewportRowLocked(surface, end_row, &row_buf);
    const end_col = selection_unit.lastNonBlankCol(end_cols) orelse 0;
    const vp_off = viewportOffsetForSurfaceLocked(surface);

    activateSelection(surface, start_col, vp_off + start_row, end_col, vp_off + end_row);
    return true;
}

fn utf8CodepointCount(text: []const u8) usize {
    const view = std.unicode.Utf8View.init(text) catch return text.len;
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint() != null) count += 1;
    return count;
}

fn extractTokenRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const cols = @as(usize, @intCast(surface.size.grid.cols));
    const rows = @as(usize, @intCast(surface.size.grid.rows));
    if (cols == 0 or rows == 0 or cell_pos.row >= rows) return null;
    const click_col = @min(cell_pos.col, cols - 1);

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    if (preview_token.isDelimiter(viewportCellCodepoint(surface, click_col, cell_pos.row))) return null;

    var start = click_col;
    while (start > 0) {
        const cp = viewportCellCodepoint(surface, start - 1, cell_pos.row);
        if (preview_token.isDelimiter(cp)) break;
        start -= 1;
    }

    var end = click_col + 1;
    while (end < cols) : (end += 1) {
        const cp = viewportCellCodepoint(surface, end, cell_pos.row);
        if (preview_token.isDelimiter(cp)) break;
    }

    var token: std.ArrayListUnmanaged(u8) = .empty;
    defer token.deinit(allocator);
    var col = start;
    while (col < end) : (col += 1) {
        const cp = viewportCellCodepoint(surface, col, cell_pos.row);
        if (preview_token.isDelimiter(cp)) break;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        token.appendSlice(allocator, buf[0..len]) catch return null;
    }

    const span = preview_token.trimSpan(token.items);
    if (span.start >= span.end) return null;

    const leading_cols = utf8CodepointCount(token.items[0..span.start]);
    const trailing_cols = utf8CodepointCount(token.items[span.end..]);
    const start_col = @min(start + leading_cols, cols - 1);
    const end_exclusive = if (end > trailing_cols) end - trailing_cols else start_col + 1;
    const end_col = @max(start_col, @min(end_exclusive - 1, cols - 1));
    const text = allocator.dupe(u8, token.items[span.start..span.end]) catch return null;

    return .{
        .text = text,
        .row = cell_pos.row,
        .start_col = start_col,
        .end_col = end_col,
    };
}

fn extractTokenAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

const looksLikeUrl = terminal_link_action.looksLikeUrl;

fn extractUrlRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    if (!looksLikeUrl(token.text)) {
        token.deinit(allocator);
        return null;
    }
    return token;
}

fn extractUrlAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractUrlRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

fn markUrlUnderlineDirty(surface: ?*Surface) void {
    const s = surface orelse return;
    s.surface_renderer.markDirty();
    AppWindow.g_force_rebuild = true;
}

fn setUrlUnderline(surface: *Surface, row_abs: usize, start_col: usize, end_col: usize) void {
    const old_surface = g_url_underline.surface;
    if (g_url_underline.surface == surface and
        g_url_underline.row_abs == row_abs and
        g_url_underline.start_col == start_col and
        g_url_underline.end_col == end_col)
    {
        return;
    }

    g_url_underline = .{
        .surface = surface,
        .row_abs = row_abs,
        .start_col = start_col,
        .end_col = end_col,
    };
    markUrlUnderlineDirty(old_surface);
    markUrlUnderlineDirty(surface);
}

fn clearUrlUnderline() void {
    if (!g_url_underline.active()) return;
    const old_surface = g_url_underline.surface;
    g_url_underline = .{};
    markUrlUnderlineDirty(old_surface);
}

pub fn isUrlUnderlineCell(surface: *Surface, col: usize, row: usize) bool {
    if (g_url_underline.surface != surface) return false;
    const abs_row = viewportOffsetForSurface(surface) + row;
    return abs_row == g_url_underline.row_abs and
        col >= g_url_underline.start_col and
        col <= g_url_underline.end_col;
}

fn extractPreviewPathAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractPreviewPathRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

fn extractDownloadPathAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractDownloadPathRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

fn extractPreviewPathRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    if (!looksLikePreviewPath(token.text)) {
        token.deinit(allocator);
        return null;
    }
    return token;
}

fn extractDownloadPathRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    if (!looksLikeDownloadPath(token.text)) {
        token.deinit(allocator);
        return null;
    }
    return token;
}

fn extractInteractiveUnderlineRangeAtCell(
    allocator: std.mem.Allocator,
    surface: *Surface,
    cell_pos: CellPos,
    action: TerminalPathClickAction,
) ?TokenAtCell {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    if (interactiveUnderlineTokenKind(action, token.text) == .none) {
        token.deinit(allocator);
        return null;
    }
    return token;
}

fn openUrl(surface: *Surface, url: []const u8) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const target = if (std.mem.startsWith(u8, url, "www."))
        std.fmt.allocPrint(allocator, "https://{s}", .{url}) catch return false
    else
        allocator.dupe(u8, url) catch return false;
    defer allocator.free(target);

    const handle = AppWindow.currentNativeHandle();
    switch (link_open.destinationForUrlClick(browser_panel.embeddedBrowserAvailable(), g_url_open_mode)) {
        .embedded_browser => {
            if (!browser_panel.openForSurface(allocator, handle, target, surface)) return false;
            if (AppWindow.g_window) |win| {
                syncPanelGridFromWindow(win);
            }
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
            return true;
        },
        .system_browser => {
            const external_target = browser_panel.externalUrlForSurface(allocator, target, surface) orelse return false;
            defer allocator.free(external_target);
            return platform_open_url.open(allocator, .{ .url = external_target });
        },
    }
}

fn openUrlAtCell(surface: *Surface, cell_pos: CellPos) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const token = extractUrlRangeAtCell(allocator, surface, cell_pos) orelse return false;
    defer token.deinit(allocator);
    setUrlUnderline(surface, viewportOffsetForSurface(surface) + token.row, token.start_col, token.end_col);
    const opened = openUrl(surface, token.text);
    if (opened) clearUrlUnderline();
    return opened;
}

fn updateInteractiveUnderlineAtMouse(xpos: f64, ypos: f64, ctrl: bool, shift: bool, alt: bool, super: bool) void {
    if (g_selecting or overlays.scrollbar.g_scrollbar_dragging or g_divider_dragging) {
        clearUrlUnderline();
        return;
    }
    if (ypos < titlebarHeight() or hitTestFileExplorer(xpos, ypos) or hitTestMarkdownPreviewPanel(xpos, ypos) or hitTestBrowserPanel(xpos, ypos)) {
        clearUrlUnderline();
        return;
    }
    if (tab.g_sidebar_visible and xpos < @as(f64, @floatCast(titlebar.sidebarWidth()))) {
        clearUrlUnderline();
        return;
    }

    const surface = split_layout.surfaceAtPoint(@intFromFloat(xpos), @intFromFloat(ypos)) orelse {
        clearUrlUnderline();
        return;
    };
    const allocator = AppWindow.g_allocator orelse return;
    const cell_pos = mouseToSurfaceCell(surface, xpos, ypos);

    const action = terminalPathClickAction(surface.launch_kind, surface.ssh_connection != null, primaryOpenMod(ctrl, super), shift, alt);
    const token = extractInteractiveUnderlineRangeAtCell(allocator, surface, cell_pos, action) orelse {
        clearUrlUnderline();
        return;
    };
    defer token.deinit(allocator);

    setUrlUnderline(surface, viewportOffsetForSurface(surface) + token.row, token.start_col, token.end_col);
}

fn openPreviewAsync(kind: markdown_preview.Kind, title: []const u8, path: []const u8, source_kind: markdown_preview_panel.PreviewSourceKind) bool {
    const perf = ui_perf.begin("input.open_preview_async");
    defer perf.end();

    AppWindow.hideAiCopilot();
    if (!markdown_preview_panel.beginAsyncLoad(kind, title, path, source_kind)) {
        file_explorer.setTransferStatus(.failed, "Preview failed");
        return true;
    }
    if (AppWindow.g_window) |win| syncPanelGridFromWindow(win);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    return true;
}

fn fileExplorerPreviewSourceKind() ?markdown_preview_panel.PreviewSourceKind {
    return switch (file_explorer.g_mode) {
        .local => .local,
        .wsl => .wsl,
        .remote => if (file_explorer.g_has_ssh_conn) .{ .remote = file_explorer.g_ssh_conn } else null,
    };
}

fn terminalPreviewSourceKind(surface: *Surface) ?markdown_preview_panel.PreviewSourceKind {
    return switch (surface.launch_kind) {
        .local => .local,
        .wsl => .wsl,
        .ssh => if (surface.ssh_connection) |conn| .{ .remote = conn } else null,
    };
}

fn openFileExplorerPreview(row_idx: usize) bool {
    const perf = ui_perf.begin("input.open_file_explorer_preview");
    defer perf.end();

    if (row_idx >= file_explorer.g_entry_count) return false;
    const entry = &file_explorer.g_entries[row_idx];
    if (entry.is_dir) return false;

    const path = entry.path_buf[0..entry.path_len];
    const kind = markdown_preview.detectKind(path) orelse return false;
    const title = entry.name_buf[0..entry.name_len];
    const source_kind = fileExplorerPreviewSourceKind() orelse {
        file_explorer.setTransferStatus(.failed, "Preview failed");
        return true;
    };

    return openPreviewAsync(kind, title, path, source_kind);
}

fn openPreviewPanelForCell(surface: *Surface, cell_pos: CellPos) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const path = extractPreviewPathAtCell(allocator, surface, cell_pos) orelse return false;
    defer allocator.free(path);

    if (markdown_preview.detectKind(path)) |kind| {
        const resolved_path = resolveTerminalPreviewPath(allocator, surface, path) catch {
            file_explorer.setTransferStatus(.failed, "Preview failed");
            return true;
        };
        defer allocator.free(resolved_path);

        const source_kind = terminalPreviewSourceKind(surface) orelse {
            file_explorer.setTransferStatus(.failed, "Preview failed");
            return true;
        };

        return openPreviewAsync(kind, basenameForPreview(path), resolved_path, source_kind);
    }

    const command = buildPreviewCommand(allocator, path) orelse return false;
    defer allocator.free(command);

    const preview_surface = AppWindow.splitFocusedReturningSurface(.right) orelse return false;
    writeTextToSurfacePty(preview_surface, command);
    return true;
}

fn downloadTerminalFileAtCell(surface: *Surface, cell_pos: CellPos) bool {
    if (surface.launch_kind != .ssh) return false;
    const conn = surface.ssh_connection orelse return false;
    const allocator = AppWindow.g_allocator orelse return false;

    const path = extractDownloadPathAtCell(allocator, surface, cell_pos) orelse return false;
    defer allocator.free(path);

    const resolved_path = resolveTerminalPreviewPath(allocator, surface, path) catch |err| {
        if (err == error.CwdUnavailable) {
            file_explorer.setTransferStatusForKind(.download, .failed, "SSH cwd unknown");
            overlays.showSshCwdFallbackPrompt();
        } else {
            file_explorer.setTransferStatusForKind(.download, .failed, "Download failed");
        }
        return true;
    };
    defer allocator.free(resolved_path);

    const name = basenameForPreview(resolved_path);
    if (name.len == 0) return false;

    var dl_buf: [260]u8 = undefined;
    const dl_path = getDownloadsFolder(&dl_buf);
    if (dl_path.len == 0) {
        file_explorer.setTransferStatusForKind(.download, .failed, "Download folder missing");
        return true;
    }

    var dst_buf: [512]u8 = undefined;
    const dst = platform_local_path.joinInto(dst_buf[0..], dl_path, name) orelse {
        file_explorer.setTransferStatusForKind(.download, .failed, "Path too long");
        return true;
    };

    _ = file_explorer.downloadRemoteFileToPath(resolved_path, dst, name, &conn);
    return true;
}

fn handleMouseButton(ev: platform_input.MouseButtonEvent) void {
    if (ev.action == .press) g_close_shortcut_confirm_until_ms = 0;
    if (overlays.windowCloseConfirmVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            _ = overlays.windowCloseConfirmExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height));
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
        return;
    }
    if (overlays.transferCancelConfirmVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            switch (overlays.transferCancelConfirmExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height))) {
                .interrupt => _ = file_explorer.cancelActiveTransfer(),
                .keep, .none => {},
            }
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
        return;
    }
    if (!hitTestHelpButton(@floatFromInt(ev.x), @floatFromInt(ev.y)))
        overlays.startupShortcutsDismiss();
    if (overlays.sessionLauncherVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.sessionLauncherExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.sessionLauncherContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.sessionLauncherClose();
            }
        }
        return;
    }
    if (overlays.restoreDefaultsConfirmVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            _ = overlays.restoreDefaultsConfirmExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height));
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
        return;
    }
    if (overlays.settingsPageVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.settingsPageExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.settingsPageContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.settingsPageClose();
            }
        }
        return;
    }
    if (overlays.commandPaletteVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.commandPaletteExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.commandPaletteContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.commandPaletteClose();
            }
        }
        return;
    }
    if (AppWindow.weixin_qr_panel.visible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            overlays.weixinQrPanelHandleAction(AppWindow.weixin_qr_panel.executeAt(xpos, ypos, w_f, h_f, top_offset));
        }
        return;
    }
    if (ev.button == .left and ev.action == .press) {
        const win = AppWindow.g_window orelse return;
        const fb = window_backend.framebufferSize(win);
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        if (overlays.transferToastHitTest(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height))) {
            overlays.transferCancelConfirmOpen();
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
            return;
        }
        if (overlays.updatePromptHitTest(xpos, ypos, @floatFromInt(fb.height))) {
            overlays.activateUpdatePrompt();
            return;
        }
        if (overlays.remoteKeyCopyHitTest(xpos, ypos, @floatFromInt(fb.height))) {
            _ = copyRemoteSessionKeyToClipboard();
            return;
        }
    }

    // Alt + left-press begins a panel swap when the active terminal tab is
    // split. Intercept here — before terminal mouse-reporting — so the gesture
    // works even when the panel runs a full-screen mouse-tracking program. Only
    // engages when the press lands inside a panel of a split tab; otherwise it
    // falls through to the normal handling below.
    if (ev.button == .left and ev.action == .press and ev.alt) {
        if (beginPanelSwapIfSplit(ev.x, ev.y)) {
            updateFocusFromMouse(ev.x, ev.y);
            return;
        }
    }

    // Terminal mouse reporting (xterm 1000/1002/1003). When the focused
    // program has enabled mouse tracking, deliver button events to the PTY
    // instead of driving local selection / paste / context-menu. A release
    // always finishes an in-progress reported drag — any modifier, anywhere —
    // so state never leaks. A press starts reporting only over terminal
    // content, with Shift up (Shift forces the terminal's own selection) and
    // without the link-open modifier (Ctrl/Cmd keeps opening links/previews
    // through the existing path below).
    if (ev.action == .release) {
        if (finishTerminalMouseReport(ev)) return;
    } else if (!ev.shift and !(primaryOpenMod(ev.ctrl, ev.super) and !ev.alt)) {
        if (beginTerminalMouseReport(ev)) return;
    }

    // Double-click on tab text to rename, elsewhere to maximize
    if (ev.button == .left and ev.action == .double_click) {
        const xpos: f64 = @floatFromInt(ev.x);
        const titlebar_h: f64 = titlebarHeight();
        const ypos: f64 = @floatFromInt(ev.y);
        if (hitTestFileExplorer(xpos, ypos)) {
            handleFileExplorerPress(xpos, ypos, ev.ctrl, ev.shift, ev.alt, ev.super);
            return;
        }
        if (ypos < titlebar_h) {
            if (hitTestConfigButton(xpos, ypos)) {
                overlays.settingsPageOpen();
            } else if (xpos >= @as(f64, titlebar.titlebarLeftReserved() + titlebar.TITLEBAR_TOGGLE_W)) {
                // Double-clicking on bare titlebar (not on the toggle, and not
                // on the macOS traffic-light strip) zooms / unzooms.
                toggleMaximize();
            }
        } else if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            if (shouldStartSidebarTabRename(xpos, ypos, tab_idx)) {
                tab.startTabRename(tab_idx);
            }
        }
        return;
    }

    // Middle-click on tab to close it
    if (ev.button == .middle and ev.action == .release) {
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            requestCloseTabGesture(tab_idx);
            return;
        }
        if (AppWindow.activeAiChat()) |chat| {
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            if (AppWindow.ai_chat_renderer.inputFieldMetricsAt(
                chat,
                xpos,
                ypos,
                @floatFromInt(fb.width),
                @floatFromInt(fb.height),
                AppWindow.leftPanelsWidth(),
                @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
            ) != null) {
                pasteFromClipboardIntoAiChat(chat);
                return;
            }
        }
        return;
    }

    // Right-click follows Ghostty-compatible right-click-action config.
    if (ev.button == .right and ev.action == .release) {
        handleConfiguredRightClick();
        return;
    }

    if (ev.button == .left) {
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        const titlebar_h: f64 = titlebarHeight();

        if (ev.action == .press) {
            g_selection_changed_for_copy = false;

            // Commit rename on any click
            if (tab.g_tab_rename_active) tab.commitTabRename();

            // Check if click is in the titlebar (tab bar area)
            if (ypos < titlebar_h) {
                blurBrowserUrlBarIfFocused();
                handleTopbarPress(xpos);
                return;
            }
            if (hitTestFileExplorerCloseButton(xpos, ypos)) {
                closeFileExplorerPanel();
                return;
            }
            if (hitTestBrowserCloseButton(xpos, ypos)) {
                closeBrowserPanel();
                return;
            }
            if (hitTestMarkdownPreviewCloseButton(xpos, ypos)) {
                closeMarkdownPreviewPanel();
                return;
            }
            if (hitTestAiCopilotCloseButton(xpos, ypos)) {
                closeAiCopilotPanel();
                return;
            }
            const over_browser_url_bar = hitTestBrowserUrlBar(xpos, ypos);
            if (!over_browser_url_bar) blurBrowserUrlBarIfFocused();
            if (hitTestSidebarResizeHandle(xpos, ypos)) {
                g_sidebar_resize_dragging = true;
                g_sidebar_resize_hover = true;
                platform_cursor.set(.size_we);
                return;
            }
            if (hitTestFileExplorerResizeHandle(xpos, ypos)) {
                g_explorer_resize_dragging = true;
                g_explorer_resize_hover = true;
                platform_cursor.set(.size_we);
                return;
            }
            if (hitTestMarkdownPreviewResizeHandle(xpos, ypos)) {
                g_markdown_preview_resize_dragging = true;
                g_markdown_preview_resize_hover = true;
                platform_cursor.set(.size_we);
                return;
            }
            if (hitTestBrowserResizeHandle(xpos, ypos)) {
                g_browser_resize_dragging = true;
                g_browser_resize_hover = true;
                platform_cursor.set(.size_we);
                return;
            }
            if (hitTestAiCopilotResizeHandle(xpos, ypos)) {
                g_ai_copilot_resize_dragging = true;
                g_ai_copilot_resize_hover = true;
                platform_cursor.set(.size_we);
                return;
            }

            if (over_browser_url_bar) {
                file_explorer.g_focused = false;
                if (file_explorer.g_op_mode != .none) file_explorer.cancelOp();
                browser_panel.focusUrlBar();
                markBrowserUrlBarDirty();
                return;
            }

            if (tab.g_sidebar_visible and xpos < @as(f64, @floatCast(titlebar.sidebarWidth()))) {
                handleSidebarPress(xpos, ypos);
                return;
            }

            if (hitTestBrowserPanel(xpos, ypos)) {
                file_explorer.g_focused = false;
                if (file_explorer.g_op_mode != .none) file_explorer.cancelOp();
                browser_panel.blurUrlBar();
                markBrowserUrlBarDirty();
                browser_panel.focus();
                return;
            }

            // File explorer left sidebar click
            if (hitTestFileExplorer(xpos, ypos)) {
                handleFileExplorerPress(xpos, ypos, ev.ctrl, ev.shift, ev.alt, ev.super);
                return;
            }

            if (hitTestMarkdownPreviewPanel(xpos, ypos)) {
                file_explorer.g_focused = false;
                if (file_explorer.g_op_mode != .none) file_explorer.cancelOp();
                if (hitTestMarkdownPreviewHeader(xpos, ypos)) return;
                if (markdown_preview_panel.g_kind == .image and markdown_preview_panel.g_load_status == .ready) {
                    g_markdown_preview_image_dragging = true;
                    g_markdown_preview_image_hover = true;
                    g_markdown_preview_image_drag_last_x = xpos;
                    g_markdown_preview_image_drag_last_y = ypos;
                    platform_cursor.set(.size_all);
                }
                return;
            }

            // Clicking outside file explorer unfocuses it
            file_explorer.g_focused = false;
            if (file_explorer.g_op_mode != .none) file_explorer.cancelOp();

            if (AppWindow.activeAiHistory() != null) {
                if (AppWindow.aiHistoryHandleMousePress(xpos, ypos)) return;
            }

            // AI copilot sidebar (terminal tabs). When the panel is visible,
            // a click inside its rect focuses the copilot and routes one-shot
            // interactions (stop / missing-api-key / message toggle / copy /
            // permission chip). A click outside the panel blurs the copilot and
            // falls through to normal terminal handling. Drag-based interactions
            // (transcript text selection, scrollbar drags) are intentionally not
            // wired here: their continue-handlers recompute the full-tab rect and
            // would mis-track against the narrower sidebar rect.
            if (AppWindow.aiCopilotVisible()) {
                if (AppWindow.activeCopilotSessionForInput()) |chat| {
                    const win = AppWindow.g_window orelse return;
                    const fb = window_backend.framebufferSize(win);
                    const bounds = ai_sidebar.boundsForWindow(
                        @intCast(fb.width),
                        @intCast(fb.height),
                        @floatCast(titlebarHeight()),
                        AppWindow.leftPanelsWidth(),
                        0,
                    );
                    const bx_left: f64 = @floatFromInt(bounds.left);
                    const bx_right: f64 = @floatFromInt(bounds.right);
                    const by_top: f64 = @floatFromInt(bounds.top);
                    const by_bottom: f64 = @floatFromInt(bounds.bottom);
                    if (xpos >= bx_left and xpos < bx_right and ypos >= by_top and ypos < by_bottom) {
                        focusAiCopilot();
                        const chat_x: f32 = @floatFromInt(bounds.left);
                        const chat_w: f32 = @floatFromInt(bounds.right - bounds.left);
                        if (AppWindow.ai_chat_renderer.stopButtonHitTest(
                            chat,
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                        )) {
                            chat.stopRequest();
                            AppWindow.g_force_rebuild = true;
                            AppWindow.g_cells_valid = false;
                            return;
                        }
                        if (AppWindow.ai_chat_renderer.missingApiKeyStatusHitTest(
                            chat,
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                        )) {
                            overlays.openAiConfigForSession(chat);
                            AppWindow.g_force_rebuild = true;
                            AppWindow.g_cells_valid = false;
                            return;
                        }
                        if (AppWindow.ai_chat_renderer.interactionHitTest(
                            chat,
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatFromInt(fb.height),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                        )) |target| {
                            switch (target) {
                                .copy_message => |message_index| copyAiChatMessageToClipboard(chat, message_index),
                                .toggle_tool => |message_index| {
                                    chat.toggleToolMessageCollapsed(message_index);
                                    AppWindow.g_force_rebuild = true;
                                    AppWindow.g_cells_valid = false;
                                },
                                .toggle_reasoning => |message_index| {
                                    chat.toggleReasoningCollapsed(message_index);
                                    AppWindow.g_force_rebuild = true;
                                    AppWindow.g_cells_valid = false;
                                },
                            }
                            return;
                        }
                        if (AppWindow.ai_chat_renderer.permissionChipHitTest(
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                        )) {
                            toggleAiAgentPermission();
                            return;
                        }
                        // Click landed in the panel but not on an interactive
                        // element: keep focus, clear any selection, consume it.
                        chat.clearSelection();
                        AppWindow.g_force_rebuild = true;
                        AppWindow.g_cells_valid = false;
                        return;
                    }
                    // Click outside the sidebar: hand focus back to the terminal.
                    blurAiCopilot();
                }
            }

            if (AppWindow.activeAiChat()) |chat| {
                const win = AppWindow.g_window orelse return;
                const fb = window_backend.framebufferSize(win);
                if (AppWindow.ai_chat_renderer.stopButtonHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) {
                    chat.stopRequest();
                    AppWindow.g_force_rebuild = true;
                    AppWindow.g_cells_valid = false;
                    return;
                }
                if (AppWindow.ai_chat_renderer.missingApiKeyStatusHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) {
                    overlays.openAiConfigForSession(chat);
                    AppWindow.g_force_rebuild = true;
                    AppWindow.g_cells_valid = false;
                    return;
                }
                if (AppWindow.ai_chat_renderer.interactionHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatFromInt(fb.height),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) |target| {
                    switch (target) {
                        .copy_message => |message_index| copyAiChatMessageToClipboard(chat, message_index),
                        .toggle_tool => |message_index| {
                            chat.toggleToolMessageCollapsed(message_index);
                            AppWindow.g_force_rebuild = true;
                            AppWindow.g_cells_valid = false;
                        },
                        .toggle_reasoning => |message_index| {
                            chat.toggleReasoningCollapsed(message_index);
                            AppWindow.g_force_rebuild = true;
                            AppWindow.g_cells_valid = false;
                        },
                    }
                    return;
                }
                if (AppWindow.ai_chat_renderer.permissionChipHitTest(
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) {
                    toggleAiAgentPermission();
                    return;
                }
                if (AppWindow.ai_chat_renderer.transcriptScrollbarHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatFromInt(fb.height),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) |drag_offset| {
                    g_ai_transcript_scroll_dragging = true;
                    g_ai_transcript_scroll_chat = chat;
                    g_ai_transcript_scroll_drag_offset = drag_offset;
                    AppWindow.ai_chat_renderer.g_transcript_scrollbar_dragging = true;
                    applyAiTranscriptScrollbarDrag(chat, ypos);
                    AppWindow.g_force_rebuild = true;
                    AppWindow.g_cells_valid = false;
                    return;
                }
                if (!ev.ctrl and !ev.alt) {
                    if (AppWindow.ai_chat_renderer.transcriptTextHitTest(
                        chat,
                        xpos,
                        ypos,
                        @floatFromInt(fb.width),
                        @floatFromInt(fb.height),
                        @floatCast(titlebarHeight()),
                        AppWindow.leftPanelsWidth(),
                        @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                    )) |hit| {
                        chat.beginTranscriptSelection(hit.message_index, hit.byte_offset);
                        g_ai_transcript_selecting = true;
                        g_ai_transcript_select_chat = chat;
                        g_ai_transcript_select_auto_copy = ev.shift;
                        platform_cursor.set(.ibeam);
                        AppWindow.g_force_rebuild = true;
                        AppWindow.g_cells_valid = false;
                        return;
                    }
                }
                if (AppWindow.ai_chat_renderer.inputScrollbarHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatFromInt(fb.height),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) |hit| {
                    g_ai_input_scroll_dragging = true;
                    g_ai_input_scroll_chat = chat;
                    g_ai_input_scroll_drag_offset = hit.drag_offset_px;
                    applyAiInputScrollbarDrag(chat, ypos);
                    AppWindow.g_force_rebuild = true;
                    AppWindow.g_cells_valid = false;
                    return;
                }
                chat.clearSelection();
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                return;
            }

            // Click in terminal content area: update split focus
            updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));

            // Check if click is on the scrollbar
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const tb_f: f32 = @floatCast(titlebarHeight());
            const top_pad: f32 = 10 + tb_f;
            if (scrollbarTargetAt(xpos, ypos, w_f, h_f, top_pad)) |target| {
                if (overlays.scrollbarGeometryForSurface(target.surface, target.view_h, target.top_pad)) |geo| {
                    overlays.scrollbar.g_scrollbar_dragging = true;
                    g_scrollbar_drag_surface = target.surface;
                    g_scrollbar_drag_view_y = target.view_y;
                    g_scrollbar_drag_view_h = target.view_h;
                    g_scrollbar_drag_top_pad = target.top_pad;
                    overlays.scrollbarShowForSurface(target.surface);

                    const y_f: f32 = @as(f32, @floatCast(ypos)) - target.view_y;
                    const thumb_top_px = target.view_h - (geo.thumb_y + geo.thumb_h); // convert GL→pixel
                    const thumb_bottom_px = target.view_h - geo.thumb_y;
                    if (y_f >= thumb_top_px and y_f <= thumb_bottom_px) {
                        // Clicked on thumb — offset from top of thumb
                        overlays.scrollbar.g_scrollbar_drag_offset = y_f - thumb_top_px;
                    } else {
                        // Clicked on track — jump thumb center to click position
                        overlays.scrollbar.g_scrollbar_drag_offset = geo.thumb_h / 2;
                        overlays.scrollbarDragForSurface(target.surface, ypos, target.view_y, target.view_h, target.top_pad);
                    }
                    return;
                }
            }

            // Check if click is on a split divider
            if (split_layout.hitTestDivider(ev.x, ev.y)) |hit| {
                g_divider_dragging = true;
                g_divider_drag_handle = hit.handle;
                g_divider_drag_layout = hit.layout;
                // Initialize per-surface resize tracking with current sizes
                // so we only show overlays on surfaces that actually change
                if (AppWindow.activeTab()) |tb| {
                    var it = tb.tree.iterator();
                    while (it.next()) |entry| {
                        entry.surface.resize_overlay_active = false;
                        entry.surface.resize_overlay_last_cols = entry.surface.size.grid.cols;
                        entry.surface.resize_overlay_last_rows = entry.surface.size.grid.rows;
                    }
                }
                return;
            }

            // Find which surface was clicked and focus it
            const clicked_surface = split_layout.surfaceAtPoint(@intFromFloat(xpos), @intFromFloat(ypos)) orelse AppWindow.activeSurface() orelse return;

            // Focus the clicked split if different from current focus
            if (AppWindow.activeTab()) |tb| {
                const previous_focus = tb.focused;
                for (0..split_layout.g_split_rect_count) |i| {
                    const rect = split_layout.g_split_rects[i];
                    if (!split_layout.cachedRectIsLive(rect)) continue;
                    if (rect.surface == clicked_surface) {
                        tb.focused = rect.handle;
                        break;
                    }
                }
                if (tb.focused != previous_focus) {
                    AppWindow.handleActiveSurfaceChangeWithinTab();
                }
            }

            const cell_pos = mouseToSurfaceCell(clicked_surface, xpos, ypos);
            switch (terminalPathClickAction(clicked_surface.launch_kind, clicked_surface.ssh_connection != null, primaryOpenMod(ev.ctrl, ev.super), ev.shift, ev.alt)) {
                .download_ssh_file => {
                    if (downloadTerminalFileAtCell(clicked_surface, cell_pos)) return;
                },
                .open_url_or_preview => {
                    if (openUrlAtCell(clicked_surface, cell_pos)) return;
                    if (openPreviewPanelForCell(clicked_surface, cell_pos)) return;
                },
                .pass_through => {},
            }

            clearUrlUnderline();
            const shift_range_select = ev.shift and !ev.ctrl and !ev.alt;
            const click_count: u8 = if (shift_range_select) blk: {
                resetLeftClickCount();
                break :blk 1;
            } else nextLeftClickCount(xpos, ypos);
            switch (click_count) {
                1 => {
                    // Shift-click extends from the last click anchor, matching
                    // document editor style range selection.
                    if (!(shift_range_select and extendSelectionAtCell(clicked_surface, cell_pos, xpos, ypos))) {
                        startSelectionAtCell(clicked_surface, cell_pos, xpos, ypos);
                    }
                },
                2 => {
                    g_selecting = false;
                    if (!selectWordAtCell(clicked_surface, cell_pos)) clearSelectionAtCell(clicked_surface, cell_pos);
                },
                3 => {
                    g_selecting = false;
                    if (!selectSentenceAtCell(clicked_surface, cell_pos)) clearSelectionAtCell(clicked_surface, cell_pos);
                },
                4 => {
                    g_selecting = false;
                    if (!selectParagraphAtCell(clicked_surface, cell_pos)) clearSelectionAtCell(clicked_surface, cell_pos);
                },
                else => unreachable,
            }
        } else {
            // Mouse up
            overlays.scrollbar.g_scrollbar_dragging = false;
            g_scrollbar_drag_surface = null;
            g_ai_input_scroll_dragging = false;
            g_ai_input_scroll_chat = null;
            g_ai_transcript_scroll_dragging = false;
            g_ai_transcript_scroll_chat = null;
            AppWindow.ai_chat_renderer.g_transcript_scrollbar_dragging = false;
            if (g_ai_transcript_selecting) {
                if (g_ai_transcript_select_chat) |chat| {
                    if (chat.finishTranscriptSelection() and g_ai_transcript_select_auto_copy) copyAiChatToClipboard(chat);
                }
                g_ai_transcript_selecting = false;
                g_ai_transcript_select_chat = null;
                g_ai_transcript_select_auto_copy = false;
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                platform_cursor.set(.arrow);
                return;
            }
            if (g_markdown_preview_image_dragging) {
                g_markdown_preview_image_dragging = false;
                const cursor_shape: platform_cursor.Shape = if (hitTestMarkdownPreviewPanel(xpos, ypos) and markdown_preview_panel.g_kind == .image and markdown_preview_panel.g_load_status == .ready)
                    .size_all
                else
                    .arrow;
                g_markdown_preview_image_hover = cursor_shape == .size_all;
                platform_cursor.set(cursor_shape);
                return;
            }
            if (g_sidebar_resize_dragging) {
                g_sidebar_resize_dragging = false;
                g_sidebar_resize_hover = hitTestSidebarResizeHandle(xpos, ypos);
                platform_cursor.set(if (g_sidebar_resize_hover) .size_we else .arrow);
                return;
            }
            if (g_explorer_resize_dragging) {
                g_explorer_resize_dragging = false;
                g_explorer_resize_hover = hitTestFileExplorerResizeHandle(xpos, ypos);
                platform_cursor.set(if (g_explorer_resize_hover) .size_we else .arrow);
                return;
            }
            if (g_markdown_preview_resize_dragging) {
                g_markdown_preview_resize_dragging = false;
                g_markdown_preview_resize_hover = hitTestMarkdownPreviewResizeHandle(xpos, ypos);
                platform_cursor.set(if (g_markdown_preview_resize_hover) .size_we else .arrow);
                return;
            }
            if (g_browser_resize_dragging) {
                g_browser_resize_dragging = false;
                g_browser_resize_hover = hitTestBrowserResizeHandle(xpos, ypos);
                platform_cursor.set(if (g_browser_resize_hover) .size_we else .arrow);
                return;
            }
            if (g_ai_copilot_resize_dragging) {
                g_ai_copilot_resize_dragging = false;
                g_ai_copilot_resize_hover = hitTestAiCopilotResizeHandle(xpos, ypos);
                platform_cursor.set(if (g_ai_copilot_resize_hover) .size_we else .arrow);
                return;
            }

            // Handle Alt-drag panel swap release (performs the swap if valid).
            if (finishPanelSwapDrag()) return;

            // Handle divider drag release
            if (g_divider_dragging) {
                g_divider_dragging = false;
                g_divider_drag_handle = null;
                g_divider_drag_layout = null;
                // Reset per-surface resize overlay state
                if (AppWindow.activeTab()) |tb| {
                    var it = tb.tree.iterator();
                    while (it.next()) |entry| {
                        entry.surface.resize_overlay_active = false;
                    }
                }
                // Cursor will be reset in handleMouseMove
                return;
            }

            if (finishSidebarTabDrag()) {
                return;
            }

            // Handle close button release — close tab if still on the close button
            if (tab.g_tab_close_pressed) |pressed_idx| {
                tab.g_tab_close_pressed = null;
                if (pressed_idx < tab.g_tab_count and hitTestSidebarTabCloseButton(xpos, ypos, pressed_idx)) {
                    requestCloseTabGesture(pressed_idx);
                }
                return;
            }

            if (plus_btn_pressed) {
                plus_btn_pressed = false;
                // Only fire if still in the + button area
                if (hitTestSidebarPlusButton(xpos, ypos)) {
                    overlays.sessionLauncherOpen();
                }
                return;
            }
            if (AppWindow.g_copy_on_select and g_selection_changed_for_copy and activeTerminalSelectionExists()) {
                copySelectionToClipboard();
            }
            g_selection_changed_for_copy = false;
            g_selecting = false;
        }
    }
}

fn handleTabBarPress(xpos: f64) void {
    // Commit any active rename when clicking in the tab bar
    if (tab.g_tab_rename_active) {
        tab.commitTabRename();
    }
    const window_width = currentClientWidthOr(800.0) orelse return;

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    // Check which tab was clicked — also check close button
    var cursor: f64 = 0;
    for (0..num_tabs) |tab_idx| {
        if (xpos >= cursor and xpos < cursor + tab_w) {
            // Check if the close button was clicked (centered on shortcut position)
            if (num_tabs > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1) {
                const sc_w: f64 = @floatCast(titlebar.titlebarGlyphAdvance(titlebar.tab_shortcut_modifier_cp) + titlebar.titlebarGlyphAdvance(if (tab_idx == 9) @as(u32, '0') else @as(u32, @intCast('1' + tab_idx))));
                const sc_center = cursor + tab_w - 12 - sc_w / 2;
                const close_btn_x = sc_center - tab.TAB_CLOSE_BTN_W / 2;
                if (xpos >= close_btn_x and xpos < close_btn_x + tab.TAB_CLOSE_BTN_W) {
                    tab.g_tab_close_pressed = tab_idx;
                    return;
                }
            }
            AppWindow.switchTab(tab_idx);
            return;
        }
        cursor += tab_w;
    }

    // Check if + button was pressed
    if (show_plus and xpos >= cursor and xpos < cursor + plus_btn_w) {
        plus_btn_pressed = true;
    }
}

fn hitTestTab(xpos: f64) ?usize {
    const window_width = currentClientWidthOr(800.0) orelse return null;

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    var cursor: f64 = 0;
    for (0..num_tabs) |tab_idx| {
        if (xpos >= cursor and xpos < cursor + tab_w) {
            return tab_idx;
        }
        cursor += tab_w;
    }
    return null;
}

fn hitTestTabCloseButton(xpos: f64, tab_idx: usize) bool {
    const window_width = currentClientWidthOr(800.0) orelse 800.0;

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    const tab_x = tab_w * @as(f64, @floatFromInt(tab_idx));
    const sc_w: f64 = @floatCast(titlebar.titlebarGlyphAdvance(titlebar.tab_shortcut_modifier_cp) + titlebar.titlebarGlyphAdvance(if (tab_idx == 9) @as(u32, '0') else @as(u32, @intCast('1' + tab_idx))));
    const sc_center = tab_x + tab_w - 12 - sc_w / 2;
    const close_btn_x = sc_center - tab.TAB_CLOSE_BTN_W / 2;
    return xpos >= close_btn_x and xpos < close_btn_x + tab.TAB_CLOSE_BTN_W;
}

fn hitTestPlusButton(xpos: f64) bool {
    const window_width = currentClientWidthOr(800.0) orelse return false;

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    if (tab.g_tab_count <= 1) return false;

    const right_reserved: f64 = caption_area_w + gap_w + plus_btn_w;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = tab_area_w / @as(f64, @floatFromInt(tab.g_tab_count));
    const plus_x = tab_w * @as(f64, @floatFromInt(tab.g_tab_count));

    return xpos >= plus_x and xpos < plus_x + plus_btn_w;
}

fn applyAiInputScrollbarDrag(chat: *AppWindow.ai_chat.Session, ypos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    if (AppWindow.ai_chat_renderer.inputScrollbarDragRowAt(
        chat,
        ypos,
        @floatFromInt(size.width),
        @floatFromInt(size.height),
        AppWindow.leftPanelsWidth(),
        @as(f32, @floatFromInt(size.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(size.width),
        g_ai_input_scroll_drag_offset,
    )) |drag| {
        _ = chat.setInputScrollRow(drag.row, drag.max_cols, drag.visible_rows);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }
}

fn applyAiTranscriptScrollbarDrag(chat: *AppWindow.ai_chat.Session, ypos: f64) void {
    const win = AppWindow.g_window orelse return;
    const size = clientSize(win);
    if (AppWindow.ai_chat_renderer.transcriptScrollbarScrollPxAt(
        chat,
        ypos,
        @floatFromInt(size.width),
        @floatFromInt(size.height),
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        @as(f32, @floatFromInt(size.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(size.width),
        g_ai_transcript_scroll_drag_offset,
    )) |px| {
        chat.scrollToPx(px);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }
}

fn updateAiTranscriptSelectionDrag(chat: *AppWindow.ai_chat.Session, xpos: f64, ypos: f64) void {
    const win = AppWindow.g_window orelse return;
    const fb = window_backend.framebufferSize(win);
    if (AppWindow.ai_chat_renderer.transcriptTextHitTest(
        chat,
        xpos,
        ypos,
        @floatFromInt(fb.width),
        @floatFromInt(fb.height),
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
    )) |hit| {
        chat.updateTranscriptSelection(hit.message_index, hit.byte_offset);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }
}

fn handleMouseMove(ev: platform_input.MouseMoveEvent) void {
    const xpos: f64 = @floatFromInt(ev.x);
    const ypos: f64 = @floatFromInt(ev.y);
    if (g_sidebar_resize_dragging) {
        applySidebarWidthFromMouse(xpos);
        platform_cursor.set(.size_we);
        return;
    }
    if (g_explorer_resize_dragging) {
        applyExplorerWidthFromMouse(xpos);
        platform_cursor.set(.size_we);
        return;
    }
    if (g_markdown_preview_resize_dragging) {
        applyMarkdownPreviewWidthFromMouse(xpos);
        platform_cursor.set(.size_we);
        return;
    }
    if (g_browser_resize_dragging) {
        applyBrowserWidthFromMouse(xpos);
        platform_cursor.set(.size_we);
        return;
    }
    if (g_ai_copilot_resize_dragging) {
        applyAiCopilotWidthFromMouse(xpos);
        platform_cursor.set(.size_we);
        return;
    }
    if (g_ai_input_scroll_dragging) {
        if (g_ai_input_scroll_chat) |chat| applyAiInputScrollbarDrag(chat, ypos);
        return;
    }
    if (g_ai_transcript_scroll_dragging) {
        if (g_ai_transcript_scroll_chat) |chat| applyAiTranscriptScrollbarDrag(chat, ypos);
        return;
    }
    if (g_ai_transcript_selecting) {
        if (g_ai_transcript_select_chat) |chat| updateAiTranscriptSelectionDrag(chat, xpos, ypos);
        platform_cursor.set(.ibeam);
        return;
    }
    if (g_markdown_preview_image_dragging) {
        const delta_x: f32 = @floatCast(xpos - g_markdown_preview_image_drag_last_x);
        const delta_y: f32 = @floatCast(ypos - g_markdown_preview_image_drag_last_y);
        g_markdown_preview_image_drag_last_x = xpos;
        g_markdown_preview_image_drag_last_y = ypos;
        if (markdown_preview_panel.panImageBy(delta_x, delta_y)) {
            AppWindow.g_force_rebuild = true;
        }
        platform_cursor.set(.size_all);
        return;
    }

    // Alt-drag panel swap: track the drop target / dim the source. Owns the move
    // while a swap source is recorded, so it must precede PTY mouse-report and
    // selection handling below.
    if (updatePanelSwapDrag(ev.x, ev.y)) return;

    // Reported mouse drag: stream motion to the PTY (button/any tracking
    // modes) and suppress local hover/selection while the button is held.
    if (g_mouse_report_button) |button| {
        if (g_mouse_report_surface) |surface| reportMouseMotion(surface, button, ev);
        return;
    }

    if (AppWindow.g_window) |hover_win| {
        if (AppWindow.activeAiChat()) |chat| {
            const hover_fb = window_backend.framebufferSize(hover_win);
            const over = AppWindow.ai_chat_renderer.transcriptScrollbarHitTest(
                chat,
                xpos,
                ypos,
                @floatFromInt(hover_fb.width),
                @floatFromInt(hover_fb.height),
                @floatCast(titlebarHeight()),
                AppWindow.leftPanelsWidth(),
                @as(f32, @floatFromInt(hover_fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(hover_fb.width),
            ) != null;
            if (over != AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover) {
                AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover = over;
                AppWindow.g_force_rebuild = true;
            }
        } else if (AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover) {
            AppWindow.ai_chat_renderer.g_transcript_scrollbar_hover = false;
            AppWindow.g_force_rebuild = true;
        }
    }
    if (updateSidebarTabDrag(xpos, ypos)) return;

    // Handle divider dragging
    if (g_divider_dragging) {
        if (g_divider_drag_handle) |handle| {
            const active_tab = AppWindow.activeTab() orelse return;
            const allocator = AppWindow.g_allocator orelse return;

            // Get spatial info for this split
            var spatial = active_tab.tree.spatial(allocator) catch return;
            defer spatial.deinit(allocator);

            // Get content area dimensions
            const win = AppWindow.g_window orelse return;
            const fb = window_backend.framebufferSize(win);
            const left_panels_w = AppWindow.leftPanelsWidth();
            const right_panels_w = AppWindow.rightPanelsWidthForWindow(fb.width);
            const content_x: f32 = left_panels_w + @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING));
            const content_y: f32 = @floatCast(titlebarHeight());
            const content_w: f32 = @as(f32, @floatFromInt(fb.width)) - left_panels_w - right_panels_w - @as(f32, @floatFromInt(2 * split_layout.DEFAULT_PADDING));
            const content_h: f32 = @as(f32, @floatFromInt(fb.height)) - content_y - @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING));

            const slot = spatial.slots[handle.idx()];
            const layout = g_divider_drag_layout orelse return;

            // Calculate new ratio based on mouse position
            const new_ratio: f16 = switch (layout) {
                .horizontal => blk: {
                    const slot_x = content_x + @as(f32, @floatCast(slot.x)) * content_w;
                    const slot_w = @as(f32, @floatCast(slot.width)) * content_w;
                    const mouse_x: f32 = @floatCast(xpos);
                    // Clamp ratio to 0.1-0.9 to prevent splits from becoming too small
                    break :blk @floatCast(@max(0.1, @min(0.9, (mouse_x - slot_x) / slot_w)));
                },
                .vertical => blk: {
                    const slot_y = content_y + @as(f32, @floatCast(slot.y)) * content_h;
                    const slot_h = @as(f32, @floatCast(slot.height)) * content_h;
                    const mouse_y: f32 = @floatCast(ypos);
                    break :blk @floatCast(@max(0.1, @min(0.9, (mouse_y - slot_y) / slot_h)));
                },
            };

            // Update the ratio in place
            active_tab.tree.resizeInPlace(handle, new_ratio);

            // Force layout recalculation and redraw
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
        return;
    }
    if (!g_selecting and !overlays.scrollbar.g_scrollbar_dragging) {
        if (hitTestMarkdownPreviewHeader(xpos, ypos) or hitTestAiCopilotCloseButton(xpos, ypos)) {
            if (g_markdown_preview_image_hover) {
                g_markdown_preview_image_hover = false;
            }
            platform_cursor.set(.arrow);
            return;
        }
        const over_sidebar_resize = hitTestSidebarResizeHandle(xpos, ypos);
        if (over_sidebar_resize) {
            platform_cursor.set(.size_we);
            g_sidebar_resize_hover = true;
            return;
        } else if (g_sidebar_resize_hover) {
            platform_cursor.set(.arrow);
            g_sidebar_resize_hover = false;
        }
        const over_explorer_resize = hitTestFileExplorerResizeHandle(xpos, ypos);
        if (over_explorer_resize) {
            platform_cursor.set(.size_we);
            g_explorer_resize_hover = true;
            return;
        } else if (g_explorer_resize_hover) {
            platform_cursor.set(.arrow);
            g_explorer_resize_hover = false;
        }
        const over_preview_resize = hitTestMarkdownPreviewResizeHandle(xpos, ypos);
        if (over_preview_resize) {
            platform_cursor.set(.size_we);
            g_markdown_preview_resize_hover = true;
            return;
        } else if (g_markdown_preview_resize_hover) {
            platform_cursor.set(.arrow);
            g_markdown_preview_resize_hover = false;
        }
        const over_preview_image = hitTestMarkdownPreviewPanel(xpos, ypos) and markdown_preview_panel.g_kind == .image and markdown_preview_panel.g_load_status == .ready;
        if (over_preview_image) {
            platform_cursor.set(.size_all);
            g_markdown_preview_image_hover = true;
            return;
        } else if (g_markdown_preview_image_hover) {
            platform_cursor.set(.arrow);
            g_markdown_preview_image_hover = false;
        }
        const over_browser_resize = hitTestBrowserResizeHandle(xpos, ypos);
        if (over_browser_resize) {
            platform_cursor.set(.size_we);
            g_browser_resize_hover = true;
            return;
        } else if (g_browser_resize_hover) {
            platform_cursor.set(.arrow);
            g_browser_resize_hover = false;
        }
        const over_ai_copilot_resize = hitTestAiCopilotResizeHandle(xpos, ypos);
        if (over_ai_copilot_resize) {
            platform_cursor.set(.size_we);
            g_ai_copilot_resize_hover = true;
            return;
        } else if (g_ai_copilot_resize_hover) {
            platform_cursor.set(.arrow);
            g_ai_copilot_resize_hover = false;
        }
    }

    if (hitTestBrowserPanel(xpos, ypos)) {
        clearUrlUnderline();
        return;
    }

    // Focus follows mouse: check if mouse is over a different split
    if (AppWindow.g_focus_follows_mouse) {
        updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));
    }
    updateInteractiveUnderlineAtMouse(xpos, ypos, ev.ctrl, ev.shift, ev.alt, ev.super);

    // Update scrollbar hover state
    const win = AppWindow.g_window orelse return;
    const fb = window_backend.framebufferSize(win);
    const w_f: f32 = @floatFromInt(fb.width);
    const h_f: f32 = @floatFromInt(fb.height);
    const tb_f: f32 = @floatCast(titlebarHeight());
    const top_pad: f32 = 10 + tb_f;

    const was_hover = overlays.scrollbar.g_scrollbar_hover;
    overlays.scrollbar.g_scrollbar_hover = false;
    if (scrollbarTargetAt(xpos, ypos, w_f, h_f, top_pad)) |target| {
        overlays.scrollbar.g_scrollbar_hover = true;
        if (!was_hover) overlays.scrollbarShowForSurface(target.surface);
    }

    // Handle scrollbar drag
    if (overlays.scrollbar.g_scrollbar_dragging) {
        if (g_scrollbar_drag_surface) |surface| {
            overlays.scrollbarDragForSurface(surface, ypos, g_scrollbar_drag_view_y, g_scrollbar_drag_view_h, g_scrollbar_drag_top_pad);
        } else {
            overlays.scrollbarDrag(ypos, h_f, top_pad);
        }
        return;
    }

    // Check for divider hover and update cursor
    if (!overlays.scrollbar.g_scrollbar_hover and !g_selecting) {
        if (split_layout.hitTestDivider(ev.x, ev.y)) |hit| {
            // Set resize cursor based on layout
            const cursor_shape: platform_cursor.Shape = switch (hit.layout) {
                .horizontal => .size_we, // left-right resize
                .vertical => .size_ns, // up-down resize
            };
            platform_cursor.set(cursor_shape);
            g_divider_hover = true;
        } else if (g_divider_hover) {
            // Reset to default cursor when leaving divider
            platform_cursor.set(.arrow);
            g_divider_hover = false;
        }
    }

    // Normal selection handling
    if (!g_selecting) return;

    const surface = AppWindow.activeSurface() orelse return;
    updateDragSelection(surface, xpos, ypos);
}

fn appendBytes(out: *[512]u8, len: *usize, bytes: []const u8) bool {
    if (len.* + bytes.len > out.len) return false;
    @memcpy(out[len.* .. len.* + bytes.len], bytes);
    len.* += bytes.len;
    return true;
}

fn appendByte(out: *[512]u8, len: *usize, byte: u8) bool {
    if (len.* >= out.len) return false;
    out[len.*] = byte;
    len.* += 1;
    return true;
}

fn appendFmt(out: *[512]u8, len: *usize, comptime fmt: []const u8, args: anytype) bool {
    const written = std.fmt.bufPrint(out[len.*..], fmt, args) catch return false;
    len.* += written.len;
    return true;
}

fn mouseWheelUnits(delta: i16) usize {
    const notches = @abs(@as(i32, delta));
    return @max(@as(usize, 1), @as(usize, @intCast((notches * 3 + 119) / 120)));
}

fn appendMouseWheelReport(surface: *Surface, ev: platform_input.MouseWheelEvent, out: *[512]u8, len: *usize) bool {
    if (surface.terminal.flags.mouse_event == .none or surface.terminal.flags.mouse_event == .x10) return false;

    var button_code: u8 = if (ev.delta > 0) 64 else 65; // xterm wheel up/down buttons 4/5
    if (ev.shift) button_code += 4;
    if (ev.alt) button_code += 8;
    if (ev.ctrl) button_code += 16;

    const cell = mouseToSurfaceCell(surface, @floatFromInt(ev.xpos), @floatFromInt(ev.ypos));
    const x = cell.col + 1;
    const y = cell.row + 1;

    switch (surface.terminal.flags.mouse_format) {
        .sgr => return appendFmt(out, len, "\x1b[<{d};{d};{d}M", .{ button_code, x, y }),
        .urxvt => return appendFmt(out, len, "\x1b[{d};{d};{d}M", .{ 32 + @as(u16, button_code), x, y }),
        .sgr_pixels => {
            const pixel = mouseToSurfacePixel(surface, ev.xpos, ev.ypos);
            return appendFmt(out, len, "\x1b[<{d};{d};{d}M", .{ button_code, @max(0, pixel.x), @max(0, pixel.y) });
        },
        .x10, .utf8 => {
            if (cell.col > 222 or cell.row > 222) return false;
            if (!appendBytes(out, len, "\x1b[M")) return false;
            if (!appendByte(out, len, 32 + button_code)) return false;
            if (!appendByte(out, len, 32 + @as(u8, @intCast(cell.col)) + 1)) return false;
            if (!appendByte(out, len, 32 + @as(u8, @intCast(cell.row)) + 1)) return false;
            return true;
        },
    }
}

fn appendAlternateScrollKeys(surface: *Surface, ev: platform_input.MouseWheelEvent, out: *[512]u8, len: *usize) bool {
    if (surface.terminal.screens.active_key != .alternate) return false;
    if (surface.terminal.flags.mouse_event != .none) return false;
    if (!surface.terminal.modes.get(.mouse_alternate_scroll)) return false;

    const seq = if (surface.terminal.modes.get(.cursor_keys))
        if (ev.delta > 0) "\x1bOA" else "\x1bOB"
    else if (ev.delta > 0) "\x1b[A" else "\x1b[B";

    for (0..mouseWheelUnits(ev.delta)) |_| {
        if (!appendBytes(out, len, seq)) return false;
    }
    return true;
}

// --- Terminal mouse button reporting --------------------------------------
// Companion to appendMouseWheelReport: encodes button presses, releases and
// drags so mouse-aware TUIs (nvim, tmux, htop) receive clicks, not just wheel
// scrolls. The pure protocol encoder lives in input/mouse_report.zig; these
// helpers map ghostty-vt's flags onto it and deliver the bytes to the PTY.

// Map ghostty-vt's mouse flags onto the local encoder enums. Typed `anytype`
// because the enums aren't re-exported from the ghostty-vt module root; the
// switch over enum literals coerces to whatever enum the flags field holds
// (the same literals the wheel path compares against in appendMouseWheelReport).
fn mouseReportEvent(mode: anytype) mouse_report.Event {
    return switch (mode) {
        .none => .none,
        .x10 => .x10,
        .normal => .normal,
        .button => .button,
        .any => .any,
    };
}

fn mouseReportFormat(fmt: anytype) mouse_report.Format {
    return switch (fmt) {
        .x10 => .x10,
        .utf8 => .utf8,
        .sgr => .sgr,
        .urxvt => .urxvt,
        .sgr_pixels => .sgr_pixels,
    };
}

fn platformMouseButton(button: platform_input.MouseButton) mouse_report.Button {
    return switch (button) {
        .left => .left,
        .middle => .middle,
        .right => .right,
    };
}

/// Encode and deliver one mouse button/motion event to the surface's PTY.
/// Returns true if bytes were written (false when the active mode does not
/// report this event — e.g. motion in normal mode, or no tracking at all).
fn sendTerminalMouseReport(
    surface: *Surface,
    action: mouse_report.Action,
    button: ?mouse_report.Button,
    x_px: i32,
    y_px: i32,
    mods: mouse_report.Mods,
) bool {
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    surface.render_state.mutex.lock();
    const mode = mouseReportEvent(surface.terminal.flags.mouse_event);
    const fmt = mouseReportFormat(surface.terminal.flags.mouse_format);
    if (mode == .none) {
        surface.render_state.mutex.unlock();
        return false;
    }
    const cell = mouseToSurfaceCell(surface, @floatFromInt(x_px), @floatFromInt(y_px));
    const pixel = mouseToSurfacePixel(surface, x_px, y_px);
    _ = mouse_report.encode(mode, fmt, action, button, mods, cell.col, cell.row, pixel.x, pixel.y, &buf, &len);
    surface.render_state.mutex.unlock();
    if (len == 0) return false;
    writeToPty(surface, buf[0..len]);
    return true;
}

/// True when the AI copilot sidebar is shown and covers (xf, yf).
fn aiCopilotRegionContains(xf: f64, yf: f64) bool {
    if (!AppWindow.aiCopilotVisible()) return false;
    const win = AppWindow.g_window orelse return false;
    const fb = window_backend.framebufferSize(win);
    const bounds = ai_sidebar.boundsForWindow(
        @intCast(fb.width),
        @intCast(fb.height),
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        0,
    );
    return xf >= @as(f64, @floatFromInt(bounds.left)) and xf < @as(f64, @floatFromInt(bounds.right)) and
        yf >= @as(f64, @floatFromInt(bounds.top)) and yf < @as(f64, @floatFromInt(bounds.bottom));
}

/// The surface that should receive a mouse report for an event at (x, y), or
/// null when the point is over window chrome / side panels or the focused
/// program has not enabled mouse tracking. Mirrors the chrome exclusions the
/// left-press path walks before it reaches terminal content.
fn terminalMouseReportTarget(x_i: i32, y_i: i32) ?*Surface {
    const xf: f64 = @floatFromInt(x_i);
    const yf: f64 = @floatFromInt(y_i);
    if (yf < titlebarHeight()) return null; // titlebar
    if (AppWindow.activeAiChat() != null) return null; // AI chat tab: no terminal
    if (tab.g_sidebar_visible and xf < @as(f64, @floatCast(titlebar.sidebarWidth()))) return null;
    if (hitTestFileExplorer(xf, yf)) return null;
    if (hitTestBrowserUrlBar(xf, yf)) return null;
    if (hitTestBrowserPanel(xf, yf)) return null;
    if (hitTestMarkdownPreviewPanel(xf, yf)) return null;
    if (aiCopilotRegionContains(xf, yf)) return null;
    const surface = split_layout.surfaceAtPoint(x_i, y_i) orelse return null;
    surface.render_state.mutex.lock();
    const mode = surface.terminal.flags.mouse_event;
    surface.render_state.mutex.unlock();
    if (mode == .none) return null;
    return surface;
}

/// Begin a reported press for an event that landed on terminal content.
/// Returns true if the press was consumed (delivered to the PTY).
fn beginTerminalMouseReport(ev: platform_input.MouseButtonEvent) bool {
    const surface = terminalMouseReportTarget(ev.x, ev.y) orelse return false;
    const button = platformMouseButton(ev.button);
    updateFocusFromMouse(ev.x, ev.y);
    _ = sendTerminalMouseReport(surface, .press, button, ev.x, ev.y, .{
        .shift = ev.shift,
        .alt = ev.alt,
        .ctrl = ev.ctrl,
    });
    g_mouse_report_button = button;
    g_mouse_report_surface = surface;
    g_mouse_report_last_cell = null;
    return true;
}

/// Finish a reported drag on button release (wherever the pointer ends up, and
/// regardless of modifiers) so the app always sees button-up and state never
/// leaks. Returns true if a matching reported press was in progress.
fn finishTerminalMouseReport(ev: platform_input.MouseButtonEvent) bool {
    const active = g_mouse_report_button orelse return false;
    if (active != platformMouseButton(ev.button)) return false;
    const surface = g_mouse_report_surface;
    g_mouse_report_button = null;
    g_mouse_report_surface = null;
    g_mouse_report_last_cell = null;
    if (surface) |s| {
        _ = sendTerminalMouseReport(s, .release, active, ev.x, ev.y, .{
            .shift = ev.shift,
            .alt = ev.alt,
            .ctrl = ev.ctrl,
        });
    }
    return true;
}

/// Stream a drag-motion report while a reported press is held, deduplicated by
/// cell so we don't flood the PTY with one report per pixel.
fn reportMouseMotion(surface: *Surface, button: mouse_report.Button, ev: platform_input.MouseMoveEvent) void {
    const cell = blk: {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        break :blk mouseToSurfaceCell(surface, @floatFromInt(ev.x), @floatFromInt(ev.y));
    };
    if (g_mouse_report_last_cell) |last| {
        if (last.col == cell.col and last.row == cell.row) return;
    }
    g_mouse_report_last_cell = cell;
    _ = sendTerminalMouseReport(surface, .motion, button, ev.x, ev.y, .{
        .shift = ev.shift,
        .alt = ev.alt,
        .ctrl = ev.ctrl,
    });
}

fn handleMouseWheel(ev: platform_input.MouseWheelEvent) void {
    overlays.startupShortcutsDismiss();
    if (tab.g_sidebar_visible and ev.xpos >= 0 and ev.xpos < @as(i32, @intFromFloat(titlebar.sidebarWidth()))) return;
    if (hitTestBrowserPanel(@floatFromInt(ev.xpos), @floatFromInt(ev.ypos))) return;
    if (hitTestMarkdownPreviewPanel(@floatFromInt(ev.xpos), @floatFromInt(ev.ypos))) {
        if (markdown_preview_panel.g_kind == .image) {
            _ = markdown_preview_panel.zoomImageBySteps(mouseWheelUnits(ev.delta), ev.delta > 0);
        } else {
            const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * 72.0 / 120.0;
            markdown_preview_panel.scrollBy(delta);
        }
        AppWindow.g_force_rebuild = true;
        return;
    }
    // Scroll in file explorer
    if (file_explorer.isVisibleForActiveTab()) {
        const panel_x = @as(i32, @intFromFloat(titlebar.sidebarWidth()));
        const panel_right = @as(i32, @intFromFloat(titlebar.sidebarWidth() + file_explorer.width()));
        if (ev.xpos >= panel_x and ev.xpos < panel_right) {
            const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * file_explorer.rowHeight() * 3 / 120.0;
            file_explorer.scrollBy(delta);
            return;
        }
    }
    // AI History transcript preview: scroll the wrapped transcript when the
    // wheel is over the detail (rightmost) pane.
    if (AppWindow.activeAiHistory() != null) {
        const win = AppWindow.g_window orelse return;
        const size = clientSize(win);
        const left_f = AppWindow.leftPanelsWidth();
        const right_f = @as(f32, @floatFromInt(size.width)) - AppWindow.rightPanelsWidthForWindow(size.width);
        const content_w = @max(0, right_f - left_f);
        const layout = AppWindow.ai_history_renderer.computeLayout(left_f, content_w);
        const x: f32 = @floatFromInt(ev.xpos);
        if (x >= layout.detail_x and x < layout.detail_x + layout.detail_w) {
            const units: i32 = @intCast(mouseWheelUnits(ev.delta));
            const step = units * 3;
            _ = AppWindow.aiHistoryScrollTranscript(if (ev.delta > 0) -step else step);
            return;
        }
        if (x >= layout.left_x and x < layout.left_x + layout.left_w) {
            const units: i32 = @intCast(mouseWheelUnits(ev.delta));
            _ = AppWindow.aiHistoryScrollDateList(if (ev.delta > 0) -units else units);
            return;
        }
        return;
    }
    if (AppWindow.activeAiChat()) |chat| {
        const win = AppWindow.g_window orelse return;
        const size = clientSize(win);
        const left = @as(i32, @intFromFloat(AppWindow.leftPanelsWidth()));
        const right = size.width - @as(i32, @intFromFloat(AppWindow.rightPanelsWidthForWindow(size.width)));
        if (ev.xpos >= left and ev.xpos < right) {
            if (AppWindow.ai_chat_renderer.inputFieldMetricsAt(
                chat,
                @floatFromInt(ev.xpos),
                @floatFromInt(ev.ypos),
                @floatFromInt(size.width),
                @floatFromInt(size.height),
                AppWindow.leftPanelsWidth(),
                @as(f32, @floatFromInt(size.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(size.width),
            )) |metrics| {
                const units: i32 = @intCast(mouseWheelUnits(ev.delta));
                const rows = if (ev.delta > 0) -units else units;
                _ = chat.scrollInputRows(rows, metrics.max_cols, metrics.visible_rows);
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                return;
            }
            const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * 72.0 / 120.0;
            chat.scrollBy(delta);
            AppWindow.g_force_rebuild = true;
            return;
        }
    }
    // AI copilot sidebar (terminal tabs): scroll the copilot transcript (or its
    // composer when the cursor is over the input field) when the wheel event
    // falls inside the sidebar rect. Uses the same clientSize source as the
    // ai_chat-tab wheel path above so the rect matches what was hit-tested.
    if (AppWindow.aiCopilotVisible()) {
        if (AppWindow.activeCopilotSessionForInput()) |chat| {
            const win = AppWindow.g_window orelse return;
            const size = clientSize(win);
            const bounds = ai_sidebar.boundsForWindow(
                size.width,
                size.height,
                @floatCast(titlebarHeight()),
                AppWindow.leftPanelsWidth(),
                0,
            );
            if (ev.xpos >= bounds.left and ev.xpos < bounds.right and ev.ypos >= bounds.top and ev.ypos < bounds.bottom) {
                const chat_x: f32 = @floatFromInt(bounds.left);
                const chat_w: f32 = @floatFromInt(bounds.right - bounds.left);
                if (AppWindow.ai_chat_renderer.inputFieldMetricsAt(
                    chat,
                    @floatFromInt(ev.xpos),
                    @floatFromInt(ev.ypos),
                    @floatFromInt(size.width),
                    @floatFromInt(size.height),
                    chat_x,
                    chat_w,
                )) |metrics| {
                    const units: i32 = @intCast(mouseWheelUnits(ev.delta));
                    const rows = if (ev.delta > 0) -units else units;
                    _ = chat.scrollInputRows(rows, metrics.max_cols, metrics.visible_rows);
                    AppWindow.g_force_rebuild = true;
                    AppWindow.g_cells_valid = false;
                    return;
                }
                const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * 72.0 / 120.0;
                chat.scrollBy(delta);
                AppWindow.g_force_rebuild = true;
                return;
            }
        }
    }
    // Scroll the surface under the mouse cursor (like Ghostty), not the focused surface.
    // Fall back to focused surface if mouse is not over any split.
    const surface = split_layout.surfaceAtPoint(ev.xpos, ev.ypos) orelse AppWindow.activeSurface() orelse return;

    var terminal_input_buf: [512]u8 = undefined;
    var terminal_input_len: usize = 0;
    var sent_to_terminal = false;

    surface.render_state.mutex.lock();
    if (surface.terminal.flags.mouse_event != .none) {
        for (0..mouseWheelUnits(ev.delta)) |_| {
            if (!appendMouseWheelReport(surface, ev, &terminal_input_buf, &terminal_input_len)) break;
        }
        sent_to_terminal = terminal_input_len > 0;
    } else if (appendAlternateScrollKeys(surface, ev, &terminal_input_buf, &terminal_input_len)) {
        sent_to_terminal = true;
    } else {
        // WHEEL_DELTA is 120 per notch. Convert to lines (3 lines per notch, like GLFW).
        const notches = @as(f64, @floatFromInt(ev.delta)) / 120.0;
        const delta: isize = @intFromFloat(-notches * 3);
        surface.terminal.scrollViewport(.{ .delta = delta });

        // Show scrollbar for the scrolled surface
        surface.scrollbar_opacity = 1.0;
        surface.scrollbar_show_time = std.time.milliTimestamp();
    }
    surface.render_state.mutex.unlock();

    if (g_selecting and !sent_to_terminal) {
        updateDragSelection(surface, @floatFromInt(ev.xpos), @floatFromInt(ev.ypos));
    }

    if (sent_to_terminal) {
        writeToPty(surface, terminal_input_buf[0..terminal_input_len]);
    }
}

fn updateDragSelection(surface: *Surface, xpos: f64, ypos: f64) void {
    const selection = &surface.selection;
    const cell_pos = mouseToSurfaceCell(surface, xpos, ypos);
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    selection.has_anchor = true;
    selection.end_col = cell_pos.col;
    selection.end_row = abs_row;

    const threshold = font.cell_width * 0.6;
    const grid_left = blk: {
        if (splitRectForSurface(surface)) |rect| {
            const pad = surface.getPadding();
            break :blk @as(f64, @floatFromInt(rect.x)) + @as(f64, @floatFromInt(pad.left));
        }
        break :blk @as(f64, @floatCast(titlebar.sidebarWidth())) + 10;
    };
    const click_cell_x = g_click_x - grid_left - @as(f64, @floatFromInt(selection.start_col)) * @as(f64, @floatCast(font.cell_width));
    const drag_cell_x = xpos - grid_left - @as(f64, @floatFromInt(cell_pos.col)) * @as(f64, @floatCast(font.cell_width));

    const same_cell = (selection.start_col == cell_pos.col and selection.start_row == abs_row);
    if (same_cell) {
        const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
        const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
        selection.active = moved_right or moved_left;
    } else {
        selection.active = true;
    }

    markSelectionChanged();
}

fn toggleAiAgentPermission() void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    const next = switch (cfg.@"ai-agent-permission") {
        .confirm => "full",
        .full => "confirm",
    };
    Config.setConfigValue(allocator, "ai-agent-permission", next) catch return;
    AppWindow.reloadConfigImmediate(allocator);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

// --- Maximize toggle (native window) ---

pub fn toggleMaximize() void {
    const win = AppWindow.g_window orelse return;
    const size = window_backend.clientSize(win);
    render_diagnostics.log(
        "toggle-maximize requested client={}x{} dpi={} full={} max={}",
        .{ size.width, size.height, window_backend.effectiveDpi(win), window_backend.isFullscreen(win), window_backend.isMaximized(win) },
    );

    if (window_backend.isFullscreen(win)) {
        toggleFullscreen();
        return;
    }

    window_backend.toggleMaximized(win);
}

// --- Fullscreen toggle (native window) ---

pub fn toggleFullscreen() void {
    const win = AppWindow.g_window orelse return;
    const size = window_backend.clientSize(win);
    render_diagnostics.log(
        "toggle-fullscreen requested client={}x{} dpi={} full={} max={}",
        .{ size.width, size.height, window_backend.effectiveDpi(win), window_backend.isFullscreen(win), window_backend.isMaximized(win) },
    );

    if (window_backend.isFullscreen(win)) {
        // Restore windowed mode
        window_backend.exitBorderlessFullscreen(win, fullscreen_restore_state);
        std.debug.print("Exited fullscreen\n", .{});
    } else {
        if (!window_backend.enterBorderlessFullscreen(win, &fullscreen_restore_state)) return;
        std.debug.print("Entered fullscreen\n", .{});
    }
}
