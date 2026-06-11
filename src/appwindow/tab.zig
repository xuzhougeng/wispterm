//! Tab and split management for AppWindow.
//!
//! Owns all tab state (TabState, tab array, tab count, active tab),
//! tab rename state, and tab/split operations. Does NOT depend on
//! rendering, GL, or platform windowing APIs — only on Surface and SplitTree.

const std = @import("std");
const Config = @import("../config.zig");
const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");
const PreviewPane = @import("../preview_pane.zig");
const input_key = @import("../input/key.zig");
const remote_client = @import("../remote_client.zig");
const session_persist = @import("../session_persist.zig");
const ai_chat = @import("../ai_chat.zig");
const ai_history_session = @import("../ai_history_session.zig");
const ai_history_source = @import("../ai_history_source.zig");
const skill_center = @import("../skill_center.zig");
const port_forwarding = @import("../port_forwarding.zig");
const ai_history_time = @import("../ai_history_time.zig");
const agent_history = @import("../agent_history.zig");
const platform_pty_command = @import("../platform/pty_command.zig");
const active_tab_state = @import("active_tab.zig");
const i18n = @import("../i18n.zig");

const CursorStyle = Config.CursorStyle;
const Selection = Surface.Selection;

// ============================================================================
// Constants
// ============================================================================

pub const MAX_TABS = 32;
pub const MAX_SPLITS_PER_TAB = 16;
pub const SPLIT_DIVIDER_WIDTH: i32 = 2;
pub const DEFAULT_PADDING: u32 = 10;

// Tab close button
pub const TAB_CLOSE_BTN_W: f32 = 36;
pub const TAB_CLOSE_FADE_SPEED: f32 = 6.0;

pub threadlocal var g_ssh_legacy_algorithms: bool = false;

// ============================================================================
// Tab model — each tab owns a SplitTree of Surfaces
// ============================================================================

pub const TabState = struct {
    kind: Kind = .terminal,
    tree: SplitTree,
    focused: SplitTree.Node.Handle = .root,
    ai_chat_session: ?*ai_chat.Session = null,
    ai_history_session: ?*ai_history_session.Session = null,
    skill_center_session: ?*skill_center.Session = null,
    port_forwarding_session: ?*port_forwarding.Session = null,
    /// Copilot conversation for a terminal tab (Issue #98). Distinct from
    /// `ai_chat_session`, which backs a dedicated AI-chat tab. Lazily created
    /// the first time the copilot sidebar is opened on this tab.
    copilot_session: ?*ai_chat.Session = null,
    /// Whether this terminal tab's right-side Copilot sidebar is currently
    /// open. The session is also per-tab; this flag prevents a Copilot opened
    /// on one tab from appearing on another tab.
    copilot_visible: bool = false,

    pub const Kind = enum {
        terminal,
        ai_chat,
        ai_history,
        skill_center,
        port_forwarding,
    };

    /// Get the focused surface in this tab, or null if tree is empty
    pub fn focusedSurface(self: *const TabState) ?*Surface {
        if (self.kind != .terminal) return null;
        if (self.tree.isEmpty()) return null;
        if (self.focused.idx() >= self.tree.nodes.len) return null;
        return switch (self.tree.nodes[self.focused.idx()]) {
            .leaf => |pane| pane.surface(),
            .split => null,
        };
    }

    /// Get the display title for this tab
    pub fn getTitle(self: *const TabState) []const u8 {
        if (g_forced_title) |forced| {
            return forced;
        }
        if (self.kind == .ai_chat) {
            const chat = self.ai_chat_session orelse return i18n.s().sl_ai_agent;
            const chat_title = chat.title();
            return if (chat_title.len > 0) chat_title else i18n.s().sl_ai_agent;
        }
        if (self.kind == .ai_history) {
            const session = self.ai_history_session orelse return i18n.s().sl_sessions;
            return session.tabTitle();
        }
        if (self.kind == .skill_center) {
            return i18n.s().sl_skill_center;
        }
        if (self.kind == .port_forwarding) {
            return i18n.s().pf_title;
        }
        const surface = self.focusedSurface() orelse return "wispterm";
        return surface.getTitle();
    }

    pub fn deinit(self: *TabState, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .terminal => {
                self.tree.deinit();
                if (self.copilot_session) |session| {
                    session.deinit();
                    self.copilot_session = null;
                }
            },
            .ai_chat => {
                if (self.ai_chat_session) |session| {
                    session.deinit();
                    self.ai_chat_session = null;
                }
            },
            .ai_history => {
                if (self.ai_history_session) |session| {
                    session.deinit();
                    allocator.destroy(session);
                    self.ai_history_session = null;
                }
            },
            .skill_center => {
                if (self.skill_center_session) |session| {
                    session.destroy();
                    self.skill_center_session = null;
                }
            },
            .port_forwarding => {
                if (self.port_forwarding_session) |session| {
                    session.destroy();
                    allocator.destroy(session);
                    self.port_forwarding_session = null;
                }
            },
        }
    }
};

// ============================================================================
// Tab globals
// ============================================================================

pub threadlocal var g_tabs: [MAX_TABS]?*TabState = .{null} ** MAX_TABS;
pub threadlocal var g_tab_count: usize = 0;

// Shell command for spawning new tabs (set once at startup from config)
pub threadlocal var g_shell_cmd_buf: platform_pty_command.CommandLineBuffer = undefined;
pub threadlocal var g_shell_cmd_len: usize = 0;
pub threadlocal var g_scrollback_limit: u32 = 10_000_000;
pub threadlocal var g_remote_client: ?*remote_client.Client = null;
pub threadlocal var g_ai_history_change_hook: ?ai_chat.HistoryChangeHook = null;

// Restore hook: rebuild an AI Chat tab from its persisted agent-history session
// id. Registered by AppWindow (which owns the history store), so tab.zig stays
// free of that dependency. Returns true if the tab was reopened.
pub threadlocal var g_ai_restore_hook: ?*const fn (session_id: []const u8) bool = null;

// Restore hook: rebuild an AI History tab from its persisted source snapshot.
// The snap slices are borrowed from the parsed session JSON and are only valid
// for the duration of the hook call; callees must duplicate any fields they
// keep after returning. Returns true if the tab was reopened.
pub threadlocal var g_ai_history_restore_hook: ?*const fn (session_persist.AiHistorySnap) bool = null;

// Forced title from config (overrides all tab titles)
pub threadlocal var g_forced_title: ?[]const u8 = null;

// ============================================================================
// Tab close button state
// ============================================================================

pub threadlocal var g_tab_close_opacity: [MAX_TABS]f32 = .{0} ** MAX_TABS;
pub threadlocal var g_tab_close_pressed: ?usize = null;
pub threadlocal var g_last_frame_time_ms: i64 = 0;

// ============================================================================
// Tab text hit regions (synced from renderer for double-click rename)
// ============================================================================

pub threadlocal var g_tab_text_x_start: [MAX_TABS]f32 = .{0} ** MAX_TABS;
pub threadlocal var g_tab_text_x_end: [MAX_TABS]f32 = .{0} ** MAX_TABS;
pub threadlocal var g_tab_text_y_start: [MAX_TABS]f32 = .{0} ** MAX_TABS;
pub threadlocal var g_tab_text_y_end: [MAX_TABS]f32 = .{0} ** MAX_TABS;

// Sidebar tab navigation state. This lives beside the tab model because the
// renderer and input layer both need to agree on whether tab navigation is
// currently visible.
pub threadlocal var g_sidebar_visible: bool = true;

// ============================================================================
// Tab rename state
// ============================================================================

pub threadlocal var g_tab_rename_active: bool = false;
pub threadlocal var g_tab_rename_idx: usize = 0;
pub threadlocal var g_tab_rename_buf: [256]u8 = undefined;
pub threadlocal var g_tab_rename_len: usize = 0;
pub threadlocal var g_tab_rename_cursor: usize = 0;
pub threadlocal var g_tab_rename_select_all: bool = false;
pub threadlocal var g_tab_rename_orig_buf: [256]u8 = undefined;
pub threadlocal var g_tab_rename_orig_len: usize = 0;

// ============================================================================
// Query functions
// ============================================================================

pub fn getShellCmd() platform_pty_command.CommandLine {
    return g_shell_cmd_buf[0..g_shell_cmd_len :0];
}

pub fn activeTab() ?*TabState {
    if (g_tab_count == 0) return null;
    return g_tabs[active_tab_state.g_active_tab];
}

pub fn activeSurface() ?*Surface {
    if (g_tab_count == 0) return null;
    const t = g_tabs[active_tab_state.g_active_tab] orelse return null;
    return t.focusedSurface();
}

pub fn activeAiChat() ?*ai_chat.Session {
    if (g_tab_count == 0) return null;
    const t = g_tabs[active_tab_state.g_active_tab] orelse return null;
    if (t.kind != .ai_chat) return null;
    return t.ai_chat_session;
}

/// Get (creating if needed) the copilot session for the active terminal tab.
/// Returns null on non-terminal tabs or if creation fails. `make` builds a
/// fresh Session (AppWindow supplies it so this module stays UI-free).
pub fn activeCopilotSession(
    make: *const fn () ?*ai_chat.Session,
) ?*ai_chat.Session {
    const t = activeTab() orelse return null;
    if (t.kind != .terminal) return null;
    if (t.copilot_session == null) {
        t.copilot_session = make() orelse return null;
    }
    return t.copilot_session;
}

pub fn activeCopilotVisible() bool {
    const t = activeTab() orelse return false;
    return t.kind == .terminal and t.copilot_visible;
}

pub fn setActiveCopilotVisible(visible: bool) bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;
    if (t.copilot_visible == visible) return false;
    t.copilot_visible = visible;
    return true;
}

pub fn toggleActiveCopilotVisible() bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;
    t.copilot_visible = !t.copilot_visible;
    return t.copilot_visible;
}

pub fn findAiTabBySessionId(session_id: []const u8) ?usize {
    for (0..g_tab_count) |idx| {
        const t = g_tabs[idx] orelse continue;
        if (t.kind != .ai_chat) continue;
        const session = t.ai_chat_session orelse continue;
        if (std.mem.eql(u8, session.sessionId(), session_id)) return idx;
    }
    return null;
}

pub fn switchToAiTabBySessionId(session_id: []const u8) bool {
    const idx = findAiTabBySessionId(session_id) orelse return false;
    switchTab(idx);
    return true;
}

fn splitSpawnCommand(
    allocator: std.mem.Allocator,
    surface: *const Surface,
) ?platform_pty_command.OwnedCommandLine {
    return switch (surface.launch_kind) {
        .wsl => splitWslCommand(allocator, surface),
        .ssh => splitSshCommand(allocator, surface),
        .local => null,
    };
}

fn splitWslCommand(
    allocator: std.mem.Allocator,
    surface: *const Surface,
) ?platform_pty_command.OwnedCommandLine {
    var command_buf: [1024]u8 = undefined;
    const command = platform_pty_command.wslInteractiveCommand(command_buf[0..], surface.getCwd()) orelse return null;
    return platform_pty_command.allocCommandLineFromUtf8(allocator, command) catch null;
}

fn splitSshCommand(
    allocator: std.mem.Allocator,
    surface: *const Surface,
) ?platform_pty_command.OwnedCommandLine {
    const conn = surface.ssh_connection orelse return null;

    var command_buf: [512]u8 = undefined;
    const command = platform_pty_command.sshInteractiveCommand(command_buf[0..], .{
        .user = conn.user(),
        .host = conn.host(),
        .port = conn.port(),
        .password_auth = conn.password_auth,
        .legacy_algorithms = conn.legacy_algorithms,
        .proxy_jump = conn.proxyJump(),
    }) orelse return null;

    return platform_pty_command.allocCommandLineFromUtf8(allocator, command) catch null;
}

/// Get the active tab's focused surface's selection
pub fn activeSelection() *Selection {
    if (g_tab_count > 0) {
        if (g_tabs[active_tab_state.g_active_tab]) |t| {
            if (t.kind != .terminal) {
                const S = struct {
                    var dummy: Selection = .{};
                };
                return &S.dummy;
            }
            if (t.focusedSurface()) |surface| {
                return &surface.selection;
            }
        }
    }
    const S = struct {
        var dummy: Selection = .{};
    };
    return &S.dummy;
}

pub fn isActiveTabTerminal() bool {
    if (g_tab_count == 0) return false;
    const t = g_tabs[active_tab_state.g_active_tab] orelse return false;
    return t.kind == .terminal;
}

// ============================================================================
// Tab operations
// ============================================================================

/// Spawn a new tab with its own Surface (PTY + terminal).
/// The caller is responsible for clearing UI state (selection, divider, resize overlay)
/// and setting rebuild flags after a successful spawn.
pub fn spawnTabWithCwd(allocator: std.mem.Allocator, cols: u16, rows: u16, cursor_style: CursorStyle, cursor_blink: bool, cwd: platform_pty_command.Cwd) bool {
    return spawnTabWithCommandAndCwd(allocator, cols, rows, getShellCmd(), cursor_style, cursor_blink, cwd);
}

pub fn spawnTabWithCommandAndCwd(allocator: std.mem.Allocator, cols: u16, rows: u16, command: platform_pty_command.CommandLine, cursor_style: CursorStyle, cursor_blink: bool, cwd: platform_pty_command.Cwd) bool {
    if (g_tab_count >= MAX_TABS) return false;

    const surface = Surface.init(
        allocator,
        cols,
        rows,
        command,
        g_scrollback_limit,
        cursor_style,
        cursor_blink,
        cwd,
    ) catch {
        std.debug.print("Failed to create Surface for new tab\n", .{});
        return false;
    };
    surface.attachRemoteClient(g_remote_client);

    const tree = SplitTree.init(allocator, surface) catch {
        std.debug.print("Failed to create SplitTree for new tab\n", .{});
        surface.deinit(allocator);
        return false;
    };
    surface.unref(allocator);

    const t = allocator.create(TabState) catch {
        std.debug.print("Failed to allocate TabState\n", .{});
        var tree_mut = tree;
        tree_mut.deinit();
        return false;
    };
    t.kind = .terminal;
    t.tree = tree;
    t.focused = .root;
    t.ai_chat_session = null;
    t.ai_history_session = null;
    t.skill_center_session = null;
    t.port_forwarding_session = null;
    t.copilot_session = null;
    t.copilot_visible = false;

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;

    std.debug.print("New tab spawned (count={}), active: {}\n", .{ g_tab_count, active_tab_state.g_active_tab });
    return true;
}

pub fn spawnAiChatTab(
    allocator: std.mem.Allocator,
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
    if (g_tab_count >= MAX_TABS) return false;

    const session = ai_chat.Session.initWithVision(
        allocator,
        name,
        base_url,
        api_key,
        model,
        protocol,
        system_prompt,
        thinking,
        reasoning_effort,
        stream_val,
        agent_val,
        vision_val,
    ) catch {
        std.debug.print("Failed to create AI Chat session\n", .{});
        return false;
    };
    session.setMaxTokens(max_tokens);
    installAiChatHistoryHook(session);

    const t = allocator.create(TabState) catch {
        session.deinit();
        return false;
    };
    t.kind = .ai_chat;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = session;
    t.ai_history_session = null;
    t.skill_center_session = null;
    t.port_forwarding_session = null;
    t.copilot_session = null;
    t.copilot_visible = false;

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;

    std.debug.print("New AI Chat tab spawned (count={}), active: {}\n", .{ g_tab_count, active_tab_state.g_active_tab });
    return true;
}

pub fn spawnAiChatTabFromHistoryRecord(allocator: std.mem.Allocator, record: agent_history.SessionRecord) bool {
    if (switchToAiTabBySessionId(record.session_id)) return true;
    if (g_tab_count >= MAX_TABS) return false;

    const session = ai_chat.Session.initFromHistoryRecord(allocator, record) catch {
        std.debug.print("Failed to restore AI Chat session from history\n", .{});
        return false;
    };
    installAiChatHistoryHook(session);

    const t = allocator.create(TabState) catch {
        session.deinit();
        return false;
    };
    t.kind = .ai_chat;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = session;
    t.ai_history_session = null;
    t.skill_center_session = null;
    t.port_forwarding_session = null;
    t.copilot_session = null;
    t.copilot_visible = false;

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;

    std.debug.print("Restored AI Chat tab from history (count={}), active: {}\n", .{ g_tab_count, active_tab_state.g_active_tab });
    return true;
}

pub fn spawnAiHistoryTab(allocator: std.mem.Allocator, source: ai_history_source.Source) bool {
    if (g_tab_count >= MAX_TABS) return false;
    const session_ptr = allocator.create(ai_history_session.Session) catch return false;
    session_ptr.* = ai_history_session.Session.initOwned(allocator, source) catch {
        allocator.destroy(session_ptr);
        return false;
    };
    session_ptr.tz_offset_seconds = ai_history_time.localOffsetSeconds();

    const t = allocator.create(TabState) catch {
        session_ptr.deinit();
        allocator.destroy(session_ptr);
        return false;
    };
    t.kind = .ai_history;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = null;
    t.copilot_session = null;
    t.copilot_visible = false;
    t.ai_history_session = session_ptr;
    t.skill_center_session = null;
    t.port_forwarding_session = null;

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;
    return true;
}

/// Create and activate a new Skill Center tab. Mirrors `spawnAiHistoryTab`:
/// allocates the tab + Session, rolls back cleanly on any failure. The caller
/// (AppWindow) seeds the cache and starts the scan after this returns.
pub fn spawnSkillCenterTab(allocator: std.mem.Allocator) bool {
    if (g_tab_count >= MAX_TABS) return false;
    const session_ptr = skill_center.Session.create(allocator) catch return false;

    const t = allocator.create(TabState) catch {
        session_ptr.destroy();
        return false;
    };
    t.kind = .skill_center;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = null;
    t.ai_history_session = null;
    t.skill_center_session = session_ptr;
    t.port_forwarding_session = null;
    t.copilot_session = null;
    t.copilot_visible = false;

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;
    return true;
}

/// Create and activate a new Port Forwarding management tab.
pub fn spawnPortForwardingTab(allocator: std.mem.Allocator) bool {
    if (g_tab_count >= MAX_TABS) return false;
    const session_ptr = allocator.create(port_forwarding.Session) catch return false;
    session_ptr.* = port_forwarding.Session.create(allocator) catch {
        allocator.destroy(session_ptr);
        return false;
    };

    const t = allocator.create(TabState) catch {
        session_ptr.destroy();
        allocator.destroy(session_ptr);
        return false;
    };
    t.kind = .port_forwarding;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = null;
    t.ai_history_session = null;
    t.skill_center_session = null;
    t.port_forwarding_session = session_ptr;
    t.copilot_session = null;
    t.copilot_visible = false;

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;
    return true;
}

/// Active tab's Skill Center session, or null if the active tab isn't one.
pub fn activeSkillCenter() ?*skill_center.Session {
    const t = activeTab() orelse return null;
    if (t.kind != .skill_center) return null;
    return t.skill_center_session;
}

/// Active tab's Port Forwarding session, or null if the active tab isn't one.
pub fn activePortForwarding() ?*port_forwarding.Session {
    const t = activeTab() orelse return null;
    if (t.kind != .port_forwarding) return null;
    return t.port_forwarding_session;
}

/// Close the tab at the given index.
/// The caller is responsible for clearing selection state and setting rebuild flags.
pub fn closeTab(idx: usize, allocator: std.mem.Allocator) void {
    if (g_tab_count <= 1) return;
    if (idx >= g_tab_count) return;

    if (g_tabs[idx]) |t| {
        t.deinit(allocator);
        allocator.destroy(t);
    }

    // Shift tabs and close button opacity down
    var i = idx;
    while (i + 1 < g_tab_count) : (i += 1) {
        g_tabs[i] = g_tabs[i + 1];
        g_tab_close_opacity[i] = g_tab_close_opacity[i + 1];
    }
    g_tabs[g_tab_count - 1] = null;
    g_tab_close_opacity[g_tab_count - 1] = 0;
    g_tab_count -= 1;

    if (active_tab_state.g_active_tab == idx) {
        if (active_tab_state.g_active_tab >= g_tab_count) {
            active_tab_state.g_active_tab = g_tab_count - 1;
        }
    } else if (active_tab_state.g_active_tab > idx) {
        active_tab_state.g_active_tab -= 1;
    }
}

const TabVisualState = struct {
    close_opacity: f32,
    text_x_start: f32,
    text_x_end: f32,
    text_y_start: f32,
    text_y_end: f32,
};

fn visualStateAt(idx: usize) TabVisualState {
    return .{
        .close_opacity = g_tab_close_opacity[idx],
        .text_x_start = g_tab_text_x_start[idx],
        .text_x_end = g_tab_text_x_end[idx],
        .text_y_start = g_tab_text_y_start[idx],
        .text_y_end = g_tab_text_y_end[idx],
    };
}

fn setVisualStateAt(idx: usize, state: TabVisualState) void {
    g_tab_close_opacity[idx] = state.close_opacity;
    g_tab_text_x_start[idx] = state.text_x_start;
    g_tab_text_x_end[idx] = state.text_x_end;
    g_tab_text_y_start[idx] = state.text_y_start;
    g_tab_text_y_end[idx] = state.text_y_end;
}

/// Move a tab from one index to another.
/// Keeps active_tab_state.g_active_tab attached to the same logical tab after the move.
pub fn reorderTab(from_idx: usize, to_idx: usize) bool {
    if (g_tab_count <= 1) return false;
    if (from_idx >= g_tab_count or to_idx >= g_tab_count) return false;
    if (from_idx == to_idx) return false;

    const moved_tab = g_tabs[from_idx] orelse return false;
    const moved_visual = visualStateAt(from_idx);

    if (from_idx < to_idx) {
        var idx = from_idx;
        while (idx < to_idx) : (idx += 1) {
            g_tabs[idx] = g_tabs[idx + 1];
            setVisualStateAt(idx, visualStateAt(idx + 1));
        }
    } else {
        var idx = from_idx;
        while (idx > to_idx) : (idx -= 1) {
            g_tabs[idx] = g_tabs[idx - 1];
            setVisualStateAt(idx, visualStateAt(idx - 1));
        }
    }

    g_tabs[to_idx] = moved_tab;
    setVisualStateAt(to_idx, moved_visual);

    if (active_tab_state.g_active_tab == from_idx) {
        active_tab_state.g_active_tab = to_idx;
    } else if (from_idx < to_idx and active_tab_state.g_active_tab > from_idx and active_tab_state.g_active_tab <= to_idx) {
        active_tab_state.g_active_tab -= 1;
    } else if (from_idx > to_idx and active_tab_state.g_active_tab >= to_idx and active_tab_state.g_active_tab < from_idx) {
        active_tab_state.g_active_tab += 1;
    }

    return true;
}

/// Switch to the tab at the given index.
/// The caller is responsible for clearing selection/divider/resize state and setting rebuild flags.
pub fn switchTab(idx: usize) void {
    if (idx >= g_tab_count) return;
    active_tab_state.g_active_tab = idx;
    // Clear bell indicator and force rebuild for surfaces in this tab
    if (g_tabs[idx]) |t| {
        if (t.kind != .terminal) return;
        var it = t.tree.surfaces();
        while (it.next()) |entry| {
            entry.surface.bell_indicator = false;
            entry.surface.surface_renderer.force_rebuild = true;
            entry.surface.surface_renderer.cells_valid = false;
        }
    }
}

fn installAiChatHistoryHook(session: *ai_chat.Session) void {
    session.setHistoryChangeHook(g_ai_history_change_hook);
}

// ============================================================================
// Split operations
// ============================================================================

/// Initial right-edge split ratio: give the terminal (left child) the bulk of
/// the width, the preview (right child) ~DEFAULT_WIDTH px. Falls back to 0.62
/// because tab.zig is UI-free (no AppWindow dependency).
fn rightEdgeRatio() f16 {
    return 0.62;
}

/// Create a preview pane at the RIGHT EDGE of the active tab's layout (a
/// full-height right column). Does NOT move focus (opening a preview keeps the
/// terminal focused). Returns the new PreviewPane (BORROWED — the tree owns it).
///
/// Mirrors the refcount dance of splitFocusedSurfaceWithCommand:
///   create() → refcount 1
///   initPane (pane.ref()) → refcount 2  (insert tree owns it)
///   split (refNodes) → refcount 3  (new_tree owns another ref)
///   old_tree.deinit() → refcount 3  (unrefs the OLD tree's terminal, not the preview)
///   defer insert.deinit() → refcount 2  (insert's ref released)
///   p.unref(gpa) → refcount 1  (local create() ref released; new_tree holds the one owning ref)
pub fn splitIntoPreview(gpa: std.mem.Allocator) ?*PreviewPane {
    const t = activeTab() orelse return null;
    if (t.kind != .terminal) return null;

    const p = PreviewPane.create(gpa) catch return null;
    // insert tree takes ownership of one ref (via pane.ref() inside initPane)
    var insert = SplitTree.initPane(gpa, .{ .preview = p }) catch {
        p.unref(gpa);
        return null;
    };
    defer insert.deinit(); // releases insert's ref when scope exits

    // Remember: split(.root, .right, ...) moves the node at .root to the LAST
    // position in the new tree. We must remap t.focused accordingly so the
    // terminal pane stays focused after the tree rebuild.
    const old_len = t.tree.nodes.len;
    const old_focused = t.focused;

    const new_tree = t.tree.split(gpa, .root, .right, rightEdgeRatio(), &insert) catch {
        p.unref(gpa); // insert.deinit (deferred) will also unref, so keep balanced
        return null;
    };

    // Swap the tree exactly as splitFocusedSurfaceWithCommand does
    var old_tree = t.tree;
    t.tree = new_tree;
    old_tree.deinit();

    // Remap focused handle: split(.root) moves node[0] to node[nodes.len - 1].
    // Any other handles keep their indices because insert nodes are placed at
    // positions old_len .. old_len + insert.nodes.len, and the split node takes
    // over position 0.
    t.focused = if (old_focused.idx() == 0)
        @enumFromInt(old_len + 1) // new_tree.nodes.len - 1 = old_len + insert.len(1)
    else
        old_focused;

    // Release the local create() reference; the tree now holds the sole ref.
    p.unref(gpa);
    return p; // borrowed — tree holds the owning ref
}

/// Handle of the preview pane to reuse: the focused leaf if it is a preview,
/// else the first preview in reading order, else null. Stateless/deterministic.
/// `gpa` is used only for the transient readingOrder slice (freed before return).
pub fn firstPreviewForReuse(gpa: std.mem.Allocator, t: *const TabState) ?SplitTree.Node.Handle {
    // Fast path: focused node is already a preview leaf
    if (t.focused.idx() < t.tree.nodes.len) {
        switch (t.tree.nodes[t.focused.idx()]) {
            .leaf => |pane| switch (pane) {
                .preview => return t.focused,
                else => {},
            },
            .split => {},
        }
    }

    // Scan in reading order (top-left → bottom-right) for the first preview.
    const order = t.tree.readingOrder(gpa) catch return null;
    defer gpa.free(order);

    for (order) |h| {
        switch (t.tree.nodes[h.idx()]) {
            .leaf => |pane| switch (pane) {
                .preview => return h,
                else => {},
            },
            .split => {},
        }
    }
    return null;
}

/// Close the active tab's preview pane: the focused leaf when it is a preview,
/// else the first preview in reading order (the same pane Ctrl+click reuses).
/// Declines (returns false) when the tab has no preview pane, or when the
/// preview is the tab's only pane — closing the last pane is tab/window-close
/// territory, which the caller's standard close path already handles.
pub fn closePreviewPane(allocator: std.mem.Allocator) bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;
    if (!t.tree.isSplit()) return false;
    const handle = firstPreviewForReuse(allocator, t) orelse return false;

    // Handles renumber on removal, so capture the focused leaf's pane VALUE to
    // re-find it afterwards. Tag+pointer comparison only — never dereferenced.
    const keep_focused: ?SplitTree.Pane = if (handle != t.focused and t.focused.idx() < t.tree.nodes.len)
        switch (t.tree.nodes[t.focused.idx()]) {
            .leaf => |pane| pane,
            .split => null,
        }
    else
        null;

    const new_tree = t.tree.remove(allocator, handle) catch {
        std.debug.print("Failed to remove preview pane from tree\n", .{});
        return false;
    };
    var old_tree = t.tree;
    t.tree = new_tree;
    old_tree.deinit();

    t.focused = focus: {
        if (keep_focused) |pane| {
            var it = t.tree.panes();
            while (it.next()) |entry| {
                if (std.meta.eql(entry.pane, pane)) break :focus entry.handle;
            }
        }
        // Fall back to the first terminal, then to the first leaf pane.
        var sit = t.tree.surfaces();
        if (sit.next()) |entry| break :focus entry.handle;
        var pit = t.tree.panes();
        break :focus if (pit.next()) |entry| entry.handle else .root;
    };
    return true;
}

/// Split the focused surface in the given direction.
/// Returns true on success. The caller handles g_resize_active and rebuild flags.
pub fn splitFocused(
    allocator: std.mem.Allocator,
    direction: SplitTree.Split.Direction,
    cell_w: f32,
    cell_h: f32,
    cursor_style: CursorStyle,
    cursor_blink: bool,
    cwd: platform_pty_command.Cwd,
) bool {
    return splitFocusedReturningSurface(allocator, direction, cell_w, cell_h, cursor_style, cursor_blink, cwd) != null;
}

/// Split the focused surface and return the newly-created surface.
/// Returns null on failure. The caller handles g_resize_active and rebuild flags.
pub fn splitFocusedReturningSurface(
    allocator: std.mem.Allocator,
    direction: SplitTree.Split.Direction,
    cell_w: f32,
    cell_h: f32,
    cursor_style: CursorStyle,
    cursor_blink: bool,
    cwd: platform_pty_command.Cwd,
) ?*Surface {
    const t = activeTab() orelse return null;
    if (t.kind != .terminal) return null;
    const focused_surface = t.focusedSurface() orelse return null;
    const split_command = splitSpawnCommand(allocator, focused_surface);
    defer if (split_command) |command| platform_pty_command.freeCommandLine(allocator, command);
    const shell_cmd = if (split_command) |command|
        platform_pty_command.commandLineFromOwned(command)
    else
        getShellCmd();

    return splitFocusedSurfaceWithCommand(
        allocator,
        t,
        focused_surface,
        direction,
        cell_w,
        cell_h,
        cursor_style,
        cursor_blink,
        cwd,
        shell_cmd,
        true,
    );
}

fn splitFocusedSurfaceWithCommand(
    allocator: std.mem.Allocator,
    t: *TabState,
    focused_surface: *Surface,
    direction: SplitTree.Split.Direction,
    cell_w: f32,
    cell_h: f32,
    cursor_style: CursorStyle,
    cursor_blink: bool,
    cwd: platform_pty_command.Cwd,
    shell_cmd: platform_pty_command.CommandLine,
    inherit_ssh_connection: bool,
) ?*Surface {
    // Calculate exact dimensions for the new split surface
    const screen_w = focused_surface.size.screen.width;
    const screen_h = focused_surface.size.screen.height;
    const pad = focused_surface.getPadding();
    const pad_w = pad.left + pad.right;
    const pad_h = pad.top + pad.bottom;

    const half_div = @divTrunc(SPLIT_DIVIDER_WIDTH, 2);
    const new_screen_w: u32 = switch (direction) {
        .left, .right => @max(1, (screen_w / 2) -| half_div),
        .up, .down => screen_w,
    };
    const new_screen_h: u32 = switch (direction) {
        .left, .right => screen_h,
        .up, .down => @max(1, (screen_h / 2) -| half_div),
    };

    const avail_w = @as(i32, @intCast(new_screen_w)) - @as(i32, @intCast(pad_w));
    const avail_h = @as(i32, @intCast(new_screen_h)) - @as(i32, @intCast(pad_h));
    const calc_cols: u16 = if (avail_w > 0) @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_w)) / cell_w)) else 10;
    const calc_rows: u16 = if (avail_h > 0) @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_h)) / cell_h)) else 5;

    const MIN_COLS: u16 = 20;
    const MIN_ROWS: u16 = 5;
    const split_cols = @max(MIN_COLS, calc_cols);
    const split_rows = @max(MIN_ROWS, calc_rows);

    const new_surface = Surface.init(
        allocator,
        split_cols,
        split_rows,
        shell_cmd,
        g_scrollback_limit,
        cursor_style,
        cursor_blink,
        cwd,
    ) catch {
        std.debug.print("Failed to create Surface for split\n", .{});
        return null;
    };
    new_surface.attachRemoteClient(g_remote_client);

    if (inherit_ssh_connection) {
        if (focused_surface.ssh_connection) |conn| {
            new_surface.setSshConnection(conn.user(), conn.host(), conn.port(), conn.password(), conn.proxyJump(), conn.password_auth, conn.legacy_algorithms);
        }
    }

    // Pre-initialize size state to match what computeSplitLayout will compute
    new_surface.size.screen.width = new_screen_w;
    new_surface.size.screen.height = new_screen_h;
    new_surface.size.cell.width = cell_w;
    new_surface.size.cell.height = cell_h;
    new_surface.size.padding = pad;

    var insert_tree = SplitTree.init(allocator, new_surface) catch {
        std.debug.print("Failed to create SplitTree for split\n", .{});
        new_surface.deinit(allocator);
        return null;
    };
    new_surface.unref(allocator);
    defer insert_tree.deinit();

    const new_tree = t.tree.split(
        allocator,
        t.focused,
        direction,
        0.5,
        &insert_tree,
    ) catch {
        std.debug.print("Failed to split tree\n", .{});
        return null;
    };

    const new_handle: SplitTree.Node.Handle = @enumFromInt(t.tree.nodes.len);

    var old_tree = t.tree;
    t.tree = new_tree;
    old_tree.deinit();

    t.focused = new_handle;

    std.debug.print("Split created: initial size {}x{}, handle: {}, tree nodes: {}\n", .{ split_cols, split_rows, @intFromEnum(new_handle), t.tree.nodes.len });
    return new_surface;
}

/// Result of closing the focused split.
pub const CloseResult = enum {
    /// A split was removed from the tree. Caller should set rebuild flags.
    closed_split,
    /// The last split in the tab was closed, and there are other tabs.
    /// The tab has been closed via closeTab. Caller should clear UI state.
    closed_tab,
    /// The last split in the last tab was closed. Caller should set g_should_close.
    close_window,
    /// Nothing happened (no active tab).
    no_op,
};

/// Close the focused split. Returns what happened so the caller can handle side effects.
pub fn closeFocusedSplit(allocator: std.mem.Allocator) CloseResult {
    const t = activeTab() orelse return .no_op;
    if (t.kind != .terminal) {
        if (g_tab_count <= 1) return .close_window;
        closeTab(active_tab_state.g_active_tab, allocator);
        return .closed_tab;
    }

    if (!t.tree.isSplit()) {
        if (g_tab_count <= 1) {
            return .close_window;
        } else {
            closeTab(active_tab_state.g_active_tab, allocator);
            return .closed_tab;
        }
    }

    const next_focus = t.tree.goto(allocator, t.focused, .next_wrapped) catch null;

    const new_tree = t.tree.remove(allocator, t.focused) catch {
        std.debug.print("Failed to remove split from tree\n", .{});
        return .no_op;
    };

    var old_tree = t.tree;
    t.tree = new_tree;
    old_tree.deinit();

    if (t.tree.isEmpty()) {
        if (g_tab_count <= 1) {
            return .close_window;
        } else {
            closeTab(active_tab_state.g_active_tab, allocator);
            return .closed_tab;
        }
    }

    // Find valid focus in new tree
    var it = t.tree.surfaces();
    if (it.next()) |entry| {
        if (next_focus) |nf| {
            if (nf != t.focused and @intFromEnum(nf) < t.tree.nodes.len) {
                t.focused = nf;
            } else {
                t.focused = entry.handle;
            }
        } else {
            t.focused = entry.handle;
        }
    } else {
        // No terminal remains (preview-only tab): focus the first leaf pane so
        // keyboard routing still targets a real pane, never the root split node.
        var pit = t.tree.panes();
        t.focused = if (pit.next()) |pane_entry| pane_entry.handle else .root;
    }

    std.debug.print("Split closed, new focused handle: {}, tree nodes: {}\n", .{ @intFromEnum(t.focused), t.tree.nodes.len });
    return .closed_split;
}

/// Navigate to a split in the given direction. Returns true if focus changed.
pub fn gotoSplit(allocator: std.mem.Allocator, direction: SplitTree.Goto) bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;
    const new_focus = t.tree.goto(allocator, t.focused, direction) catch return false;
    if (new_focus) |handle| {
        t.focused = handle;
        return true;
    }
    return false;
}

/// Focus the n-th panel (1-based) of the active tab in screen reading order
/// (top-left → bottom-right). Returns false if there is no such panel (n out of
/// range, empty/non-terminal tab), leaving focus unchanged so the caller can let
/// the key fall through to the terminal.
pub fn focusPanelByIndex(allocator: std.mem.Allocator, n: usize) bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;
    const handle = (t.tree.panelHandleAt(allocator, n) catch return false) orelse return false;
    t.focused = handle;
    return true;
}

/// Equalize all split ratios. Returns true if equalization was performed.
pub fn equalizeSplits(allocator: std.mem.Allocator) bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;

    var it = t.tree.surfaces();
    while (it.next()) |entry| {
        entry.surface.resize_overlay_active = true;
        entry.surface.resize_overlay_last_cols = entry.surface.size.grid.cols;
        entry.surface.resize_overlay_last_rows = entry.surface.size.grid.rows;
    }

    const new_tree = t.tree.equalize(allocator) catch return false;
    t.tree.deinit();
    t.tree = new_tree;

    return true;
}

/// Swap the panels at handles `a` (drag source) and `b` (drop target). The two
/// leaves exchange their surfaces; the split-tree topology and ratios are
/// unchanged. Focus follows the dragged surface to the target slot.
///
/// Returns false (no-op) if there is no terminal tab, either handle is out of
/// range, either node is not a leaf, or `a == b`. The leaf/range checks are
/// defensive: a shell may have exited mid-drag and reshaped the tree, leaving
/// the caller holding stale handles.
pub fn swapPanels(a: SplitTree.Node.Handle, b: SplitTree.Node.Handle) bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;
    if (a == b) return false;
    if (a.idx() >= t.tree.nodes.len or b.idx() >= t.tree.nodes.len) return false;
    if (t.tree.nodes[a.idx()] != .leaf or t.tree.nodes[b.idx()] != .leaf) return false;

    t.tree.swapLeaves(a, b);
    // The dragged surface (was at `a`) now lives at `b`; keep it focused.
    t.focused = b;
    return true;
}

// ============================================================================
// Tab rename
// ============================================================================

pub fn startTabRename(tab_idx: usize) void {
    if (tab_idx >= g_tab_count) return;
    const t = g_tabs[tab_idx] orelse return;
    const title = t.getTitle();
    const len = @min(title.len, g_tab_rename_buf.len);
    @memcpy(g_tab_rename_buf[0..len], title[0..len]);
    g_tab_rename_len = len;
    g_tab_rename_cursor = len;
    @memcpy(g_tab_rename_orig_buf[0..len], title[0..len]);
    g_tab_rename_orig_len = len;
    g_tab_rename_idx = tab_idx;
    g_tab_rename_active = true;
    g_tab_rename_select_all = true;
}

pub fn commitTabRename() void {
    if (!g_tab_rename_active) return;
    if (g_tab_rename_idx < g_tab_count) {
        if (g_tabs[g_tab_rename_idx]) |t| {
            const changed = g_tab_rename_len != g_tab_rename_orig_len or
                !std.mem.eql(u8, g_tab_rename_buf[0..g_tab_rename_len], g_tab_rename_orig_buf[0..g_tab_rename_orig_len]);
            if (changed) {
                switch (t.kind) {
                    .terminal => if (t.focusedSurface()) |surface| {
                        surface.setTitleOverride(g_tab_rename_buf[0..g_tab_rename_len]);
                    },
                    .ai_chat => if (t.ai_chat_session) |session| {
                        session.setTitle(g_tab_rename_buf[0..g_tab_rename_len]);
                    },
                    .ai_history => {},
                    .skill_center => {},
                    .port_forwarding => {},
                }
            }
        }
    }
    g_tab_rename_active = false;
}

pub fn cancelTabRename() void {
    g_tab_rename_active = false;
}

/// Handle a key event during tab rename. Does NOT reset cursor blink —
/// the caller should reset blink state before calling this.
pub fn handleRenameKey(ev: input_key.KeyEvent) void {
    if (ev.key == .enter) {
        commitTabRename();
        return;
    }
    if (ev.key == .escape) {
        cancelTabRename();
        return;
    }
    if (ev.key == .backspace) {
        if (g_tab_rename_select_all) {
            g_tab_rename_len = 0;
            g_tab_rename_cursor = 0;
            g_tab_rename_select_all = false;
            return;
        }
        if (g_tab_rename_cursor > 0) {
            var i = g_tab_rename_cursor - 1;
            while (i > 0 and (g_tab_rename_buf[i] & 0xC0) == 0x80) i -= 1;
            const removed = g_tab_rename_cursor - i;
            const remaining = g_tab_rename_len - g_tab_rename_cursor;
            if (remaining > 0) {
                std.mem.copyForwards(u8, g_tab_rename_buf[i..], g_tab_rename_buf[g_tab_rename_cursor .. g_tab_rename_cursor + remaining]);
            }
            g_tab_rename_len -= removed;
            g_tab_rename_cursor = i;
        }
        return;
    }
    if (ev.key == .delete) {
        if (g_tab_rename_select_all) {
            g_tab_rename_len = 0;
            g_tab_rename_cursor = 0;
            g_tab_rename_select_all = false;
            return;
        }
        if (g_tab_rename_cursor < g_tab_rename_len) {
            var end = g_tab_rename_cursor + 1;
            while (end < g_tab_rename_len and (g_tab_rename_buf[end] & 0xC0) == 0x80) end += 1;
            const removed = end - g_tab_rename_cursor;
            const remaining = g_tab_rename_len - end;
            if (remaining > 0) {
                std.mem.copyForwards(u8, g_tab_rename_buf[g_tab_rename_cursor..], g_tab_rename_buf[end .. end + remaining]);
            }
            g_tab_rename_len -= removed;
        }
        return;
    }
    if (ev.key == .arrow_left) {
        g_tab_rename_select_all = false;
        if (g_tab_rename_cursor > 0) {
            g_tab_rename_cursor -= 1;
            while (g_tab_rename_cursor > 0 and (g_tab_rename_buf[g_tab_rename_cursor] & 0xC0) == 0x80)
                g_tab_rename_cursor -= 1;
        }
        return;
    }
    if (ev.key == .arrow_right) {
        g_tab_rename_select_all = false;
        if (g_tab_rename_cursor < g_tab_rename_len) {
            g_tab_rename_cursor += 1;
            while (g_tab_rename_cursor < g_tab_rename_len and (g_tab_rename_buf[g_tab_rename_cursor] & 0xC0) == 0x80)
                g_tab_rename_cursor += 1;
        }
        return;
    }
    if (ev.ctrl and ev.key == .key_a) {
        g_tab_rename_select_all = false;
        g_tab_rename_cursor = 0;
        return;
    }
    if (ev.ctrl and ev.key == .key_e) {
        g_tab_rename_select_all = false;
        g_tab_rename_cursor = g_tab_rename_len;
        return;
    }
    if (ev.ctrl and ev.key == .key_u) {
        if (g_tab_rename_select_all) {
            g_tab_rename_len = 0;
            g_tab_rename_cursor = 0;
            g_tab_rename_select_all = false;
        } else if (g_tab_rename_cursor > 0) {
            const remaining = g_tab_rename_len - g_tab_rename_cursor;
            if (remaining > 0) {
                std.mem.copyForwards(u8, g_tab_rename_buf[0..remaining], g_tab_rename_buf[g_tab_rename_cursor .. g_tab_rename_cursor + remaining]);
            }
            g_tab_rename_len = remaining;
            g_tab_rename_cursor = 0;
        }
        return;
    }
    if (ev.ctrl and ev.key == .key_k) {
        if (g_tab_rename_select_all) {
            g_tab_rename_len = 0;
            g_tab_rename_cursor = 0;
            g_tab_rename_select_all = false;
        } else {
            g_tab_rename_len = g_tab_rename_cursor;
        }
        return;
    }
}

/// Insert a character during tab rename. Does NOT reset cursor blink —
/// the caller should reset blink state before calling this.
pub fn handleRenameChar(codepoint: u21) void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return;

    if (g_tab_rename_select_all) {
        if (len > g_tab_rename_buf.len) return;
        @memcpy(g_tab_rename_buf[0..len], buf[0..len]);
        g_tab_rename_len = len;
        g_tab_rename_cursor = len;
        g_tab_rename_select_all = false;
        return;
    }

    if (g_tab_rename_len + len > g_tab_rename_buf.len) return;

    if (g_tab_rename_cursor < g_tab_rename_len) {
        const remaining = g_tab_rename_len - g_tab_rename_cursor;
        std.mem.copyBackwards(u8, g_tab_rename_buf[g_tab_rename_cursor + len .. g_tab_rename_cursor + len + remaining], g_tab_rename_buf[g_tab_rename_cursor .. g_tab_rename_cursor + remaining]);
    }
    @memcpy(g_tab_rename_buf[g_tab_rename_cursor .. g_tab_rename_cursor + len], buf[0..len]);
    g_tab_rename_len += len;
    g_tab_rename_cursor += len;
}

// ============================================================================
// Session persistence — snapshot live tabs into POD for serialization
// ============================================================================

/// Build a session_persist.TabSnap from a live TabState by walking its
/// SplitTree. The returned snapshot owns its strings via `arena`. The arena
/// is the caller's responsibility to free (via Session.deinit pattern, or
/// shared across all tabs in a session).
pub fn snapshotTab(arena: std.mem.Allocator, t: *const TabState) !session_persist.TabSnap {
    // AI Chat tabs persist only their history session id; the conversation
    // itself lives in the agent history store. `tree` is a required field, so
    // emit an ignored placeholder leaf — restoreTab routes by ai_session_id.
    if (t.kind == .ai_chat) {
        const session = t.ai_chat_session orelse return error.NoAiSession;
        const sid = try arena.dupe(u8, session.sessionId());
        return session_persist.TabSnap{
            .title_override = null,
            .focused_leaf = 0,
            .zoomed_leaf = null,
            .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
            .ai_session_id = sid,
        };
    }
    if (t.kind == .ai_history) {
        const session = t.ai_history_session orelse return error.NoAiHistorySession;
        const snap = try session.persistSnap(arena);
        return session_persist.TabSnap{
            .title_override = null,
            .focused_leaf = 0,
            .zoomed_leaf = null,
            .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
            .ai_history = snap,
        };
    }
    if (t.kind != .terminal) return error.NotTerminalTab;
    if (t.tree.isEmpty()) return error.EmptyTree;

    // 1. Build NodeSnap tree.
    const tree = try snapshotNode(arena, &t.tree, .root);

    // 2. Find the focused leaf's index in pre-order. If `focused == .root`
    //    on a single-leaf tree, the root IS the leaf and computeFocusedLeafIndex
    //    correctly returns 0.
    const focused_leaf: u32 = computeFocusedLeafIndex(&t.tree, t.focused);

    // 3. Translate the optional zoomed handle to a pre-order leaf index.
    const zoomed_leaf: ?u32 = if (t.tree.zoomed) |z| computeFocusedLeafIndex(&t.tree, z) else null;

    return session_persist.TabSnap{
        .title_override = try snapshotFocusedTitleOverride(arena, t),
        .focused_leaf = focused_leaf,
        .zoomed_leaf = zoomed_leaf,
        .tree = tree,
    };
}

fn snapshotFocusedTitleOverride(arena: std.mem.Allocator, t: *const TabState) !?[]const u8 {
    const surface = t.focusedSurface() orelse return null;
    if (surface.title_override_len == 0) return null;
    return try arena.dupe(u8, surface.title_override[0..surface.title_override_len]);
}

fn snapshotNode(
    arena: std.mem.Allocator,
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
) !session_persist.NodeSnap {
    const node = tree.nodes[handle.idx()];
    return switch (node) {
        .leaf => |pane| switch (pane) {
            .terminal => |s| .{ .leaf = .{ .surface = try snapshotSurface(arena, s) } },
            // Persist the preview's kind + file path so it can be re-loaded
            // (best-effort) on the next launch.
            .preview => |p| .{ .leaf = .{
                .kind = .preview,
                .preview = .{ .kind = p.kind, .path = try arena.dupe(u8, p.path()) },
            } },
        },
        .split => |sp| blk: {
            const left = try arena.create(session_persist.NodeSnap);
            left.* = try snapshotNode(arena, tree, sp.left);
            const right = try arena.create(session_persist.NodeSnap);
            right.* = try snapshotNode(arena, tree, sp.right);
            break :blk .{ .split = .{
                .layout = switch (sp.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @as(f64, @floatCast(sp.ratio)),
                .left = left,
                .right = right,
            } };
        },
    };
}

fn snapshotSurface(arena: std.mem.Allocator, surface: *const Surface) !session_persist.SurfaceSnap {
    return switch (surface.surfaceKind()) {
        .local_shell => .{ .local_shell = .{
            .cwd = try snapshotOptionalCwd(arena, surface.getCwd() orelse surface.getInitialCwd()),
            .command = null,
        } },
        .ssh => blk: {
            // surfaceKind() returned .ssh, so ssh_connection is non-null.
            const conn = &surface.ssh_connection.?;
            const port_str = conn.port();
            const port_num: u16 = if (port_str.len == 0)
                22
            else
                std.fmt.parseInt(u16, port_str, 10) catch 22;
            break :blk .{ .ssh = .{
                .cwd = try snapshotOptionalCwd(arena, surface.getCwd()),
                .user = try arena.dupe(u8, conn.user()),
                .host = try arena.dupe(u8, conn.host()),
                .port = port_num,
                .proxy_jump = try arena.dupe(u8, conn.proxyJump()),
            } };
        },
    };
}

fn snapshotOptionalCwd(arena: std.mem.Allocator, cwd: ?[]const u8) !?[]const u8 {
    return if (cwd) |c| try arena.dupe(u8, c) else null;
}

fn computeFocusedLeafIndex(tree: *const SplitTree, target: SplitTree.Node.Handle) u32 {
    var idx: u32 = 0;
    var found: ?u32 = null;
    walkTreePreOrder(tree, .root, target, &idx, &found);
    return found orelse 0;
}

fn walkTreePreOrder(
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
    target: SplitTree.Node.Handle,
    idx: *u32,
    found: *?u32,
) void {
    if (found.* != null) return;
    const node = tree.nodes[handle.idx()];
    switch (node) {
        .leaf => {
            if (handle == target) found.* = idx.*;
            idx.* += 1;
        },
        .split => |sp| {
            walkTreePreOrder(tree, sp.left, target, idx, found);
            walkTreePreOrder(tree, sp.right, target, idx, found);
        },
    }
}

// ============================================================================
// Session persistence — restore one TabSnap into a live TabState
// ============================================================================
//
// SplitTree.fromSnapshot takes a free-function factory `(snap, gpa) -> ?*Surface`
// with no closure capture. The cols/rows/cursor settings the caller wants to
// apply to every restored Surface are conveyed through the thread-local
// "restore context" below: restoreTab sets it before calling fromSnapshot and
// the factory reads it for each leaf. This is safe because tab operations are
// single-threaded per appwindow and restore is synchronous.

threadlocal var g_restore_cols: u16 = 80;
threadlocal var g_restore_rows: u16 = 24;
threadlocal var g_restore_cursor_style: CursorStyle = .block;
threadlocal var g_restore_cursor_blink: bool = true;
const SSH_RESTORE_COMMAND_BUF_SIZE: usize = 4096;

/// Free-function factory passed to SplitTree.fromSnapshot. Reads dimensions
/// and cursor settings from the thread-local restore context populated by
/// restoreTab. Returns null on any failure so fromSnapshot can roll back the
/// whole tree.
fn surfaceFromSnap(
    snap: *const session_persist.SurfaceSnap,
    gpa: std.mem.Allocator,
) ?*Surface {
    return surfaceFromSnapImpl(snap, gpa) catch null;
}

fn surfaceFromSnapImpl(
    snap: *const session_persist.SurfaceSnap,
    gpa: std.mem.Allocator,
) !*Surface {
    const cols: u16 = @max(1, g_restore_cols);
    const rows: u16 = @max(1, g_restore_rows);
    const cursor_style = g_restore_cursor_style;
    const cursor_blink = g_restore_cursor_blink;

    switch (snap.*) {
        .local_shell => |sh| {
            // Native process launch copies cwd during Surface.init, so freeing
            // this owned platform string after init is safe.
            var cwd_owned: ?platform_pty_command.OwnedCwd = null;
            defer if (cwd_owned) |owned| platform_pty_command.freeCwd(gpa, owned);
            const cwd_w: platform_pty_command.Cwd = if (sh.cwd) |c| blk: {
                cwd_owned = try platform_pty_command.allocCwdFromUtf8(gpa, c);
                break :blk platform_pty_command.cwdFromOwned(cwd_owned.?);
            } else null;

            const command = getShellCmd();
            const surface = try Surface.init(gpa, cols, rows, command, g_scrollback_limit, cursor_style, cursor_blink, cwd_w);
            surface.attachRemoteClient(g_remote_client);
            return surface;
        },
        .ssh => |s| {
            var stack_buf: [SSH_RESTORE_COMMAND_BUF_SIZE]u8 = undefined;
            const command_text = try buildSshRestoreCommand(gpa, &stack_buf, s);

            var port_buf: [8]u8 = undefined;
            const port_slice = std.fmt.bufPrint(&port_buf, "{}", .{s.port}) catch return error.CommandTooLong;
            const command = try platform_pty_command.allocCommandLineFromUtf8(gpa, command_text);
            defer platform_pty_command.freeCommandLine(gpa, command);
            const surface = try Surface.init(gpa, cols, rows, platform_pty_command.commandLineFromOwned(command), g_scrollback_limit, cursor_style, cursor_blink, null);
            surface.attachRemoteClient(g_remote_client);
            // SSH password is never persisted (security invariant I1). On restore,
            // the native SSH client prompts interactively if key auth fails;
            // the in-app password-autofill flow (which requires password_auth=true)
            // does not engage here.
            surface.setSshConnection(s.user, s.host, port_slice, "", s.proxy_jump, false, g_ssh_legacy_algorithms);
            return surface;
        },
    }
}

fn buildSshRestoreCommand(
    allocator: std.mem.Allocator,
    buf: []u8,
    s: session_persist.SurfaceSnap.SshSnap,
) ![]const u8 {
    // Mirrors the password_auth=false branch: persisted SSH snaps never carry
    // passwords, so restored sessions rely on keys or the native ssh prompt.
    var port_buf: [8]u8 = undefined;
    const port_slice = std.fmt.bufPrint(&port_buf, "{}", .{s.port}) catch return error.CommandTooLong;

    const base = platform_pty_command.sshInteractiveCommand(buf, .{
        .user = s.user,
        .host = s.host,
        .port = port_slice,
        .legacy_algorithms = g_ssh_legacy_algorithms,
        .proxy_jump = s.proxy_jump,
    }) orelse return error.CommandTooLong;
    var final_len: usize = base.len;

    if (s.cwd) |cwd_str| {
        const escaped = try session_persist.shellSingleQuoteEscape(allocator, cwd_str);
        defer allocator.free(escaped);
        const trail = std.fmt.bufPrint(buf[final_len..], " \"cd '{s}' 2>/dev/null; exec $SHELL -l\"", .{escaped}) catch return error.CommandTooLong;
        final_len += trail.len;
    }

    return buf[0..final_len];
}

/// Materialize one TabSnap into a new live tab. Returns true on success.
/// On any leaf failure, the SplitTree is rolled back, no tab is appended,
/// and false is returned — the caller (Task 18 wrapper) skips the failed tab.
///
/// cols/rows/cursor are sourced from the caller (AppWindow) since tab.zig
/// does not maintain its own copy of those values.
pub fn restoreTab(
    allocator: std.mem.Allocator,
    snap: *const session_persist.TabSnap,
    cols: u16,
    rows: u16,
    cursor_style: CursorStyle,
    cursor_blink: bool,
) bool {
    if (g_tab_count >= MAX_TABS) return false;

    if (snap.ai_history) |history_snap| {
        const hook = g_ai_history_restore_hook orelse return false;
        return hook(history_snap);
    }

    // AI Chat tab: rebuild from its persisted history session via the hook
    // AppWindow installed (it owns the history store). The placeholder `tree` in
    // the snapshot is ignored. If the hook isn't installed or the session is
    // gone from history, skip this tab rather than restoring a wrong terminal.
    if (snap.ai_session_id) |sid| {
        const hook = g_ai_restore_hook orelse return false;
        return hook(sid);
    }

    // Populate the thread-local restore context so surfaceFromSnap can read
    // these values without changing the SplitTree.fromSnapshot factory ABI.
    g_restore_cols = cols;
    g_restore_rows = rows;
    g_restore_cursor_style = cursor_style;
    g_restore_cursor_blink = cursor_blink;

    var tree = SplitTree.fromSnapshot(allocator, &snap.tree, &surfaceFromSnap) catch |err| {
        std.debug.print("restoreTab: fromSnapshot failed: {}\n", .{err});
        return false;
    };

    const t = allocator.create(TabState) catch {
        tree.deinit();
        return false;
    };
    t.kind = .terminal;
    t.tree = tree;

    // Resolve focused_leaf from pre-order index back to a Handle.
    t.focused = handleOfNthLeaf(&t.tree, snap.focused_leaf) orelse .root;
    t.ai_chat_session = null;
    t.ai_history_session = null;
    t.skill_center_session = null;
    t.port_forwarding_session = null;
    t.copilot_session = null;
    t.copilot_visible = false;
    applyRestoredTabMetadata(t, snap);

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;
    return true;
}

fn applyRestoredTabMetadata(t: *TabState, snap: *const session_persist.TabSnap) void {
    const title = snap.title_override orelse return;
    switch (t.kind) {
        .terminal => if (t.focusedSurface()) |surface| {
            surface.setTitleOverride(title);
        },
        .ai_chat => if (t.ai_chat_session) |session| {
            session.setTitle(title);
        },
        .ai_history => {},
        .skill_center => {},
        .port_forwarding => {},
    }
}

fn handleOfNthLeaf(tree: *const SplitTree, target_idx: u32) ?SplitTree.Node.Handle {
    var idx: u32 = 0;
    return findLeafHandle(tree, .root, target_idx, &idx);
}

fn findLeafHandle(
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
    target: u32,
    idx: *u32,
) ?SplitTree.Node.Handle {
    const node = tree.nodes[handle.idx()];
    return switch (node) {
        .leaf => blk: {
            if (idx.* == target) break :blk handle;
            idx.* += 1;
            break :blk null;
        },
        .split => |sp| blk: {
            if (findLeafHandle(tree, sp.left, target, idx)) |h| break :blk h;
            if (findLeafHandle(tree, sp.right, target, idx)) |h| break :blk h;
            break :blk null;
        },
    };
}

/// Walk all live tabs and build a complete Session POD. Caller owns the
/// returned ArenaAllocator; deinit it after the Session is no longer needed.
pub fn collectSessionSnapshot(arena: *std.heap.ArenaAllocator) !session_persist.Session {
    const alloc = arena.allocator();
    if (g_tab_count == 0) return error.NoTabs;

    const tabs = try alloc.alloc(session_persist.TabSnap, g_tab_count);
    var i: usize = 0;
    var written: usize = 0;
    while (i < g_tab_count) : (i += 1) {
        if (g_tabs[i]) |t| {
            tabs[written] = snapshotTab(alloc, t) catch continue;
            written += 1;
        }
    }
    if (written == 0) return error.NoTabs;

    return .{
        .version = session_persist.SCHEMA_VERSION,
        .active_tab = @intCast(@min(active_tab_state.g_active_tab, written - 1)),
        .tabs = tabs[0..written],
    };
}

/// One-shot: collect the current session and write it atomically. Errors are
/// logged but not propagated — close path must not be blocked.
pub fn dumpSessionToFile(allocator: std.mem.Allocator) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const session = collectSessionSnapshot(&arena) catch |err| {
        std.debug.print("dumpSessionToFile: collect failed: {}\n", .{err});
        return;
    };

    const path = Config.sessionFilePath(allocator) catch |err| {
        std.debug.print("dumpSessionToFile: sessionFilePath failed: {}\n", .{err});
        return;
    };
    defer allocator.free(path);

    session_persist.dumpSession(allocator, path, session) catch |err| {
        std.debug.print("dumpSessionToFile: dumpSession failed: {}\n", .{err});
    };
}

/// Read the session file and rebuild tabs. Returns true iff at least one
/// tab was restored (caller should then skip openDefaultTab).
///
/// Caller passes the same cols/rows/cursor that openDefaultTab would use.
pub fn restoreSessionFromFile(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    cursor_style: CursorStyle,
    cursor_blink: bool,
) bool {
    const path = Config.sessionFilePath(allocator) catch return false;
    defer allocator.free(path);

    var loaded = (session_persist.loadSession(allocator, path) catch return false) orelse return false;
    defer loaded.deinit();

    session_persist.normalize(&loaded.value);

    var rebuilt: usize = 0;
    for (loaded.value.tabs) |*snap| {
        if (restoreTab(allocator, snap, cols, rows, cursor_style, cursor_blink)) {
            rebuilt += 1;
        } else {
            std.debug.print("restoreSessionFromFile: skipping failed tab\n", .{});
        }
    }
    if (rebuilt == 0) return false;

    const target = @min(@as(usize, loaded.value.active_tab), rebuilt - 1);
    switchTab(target);
    return true;
}

fn resetTestTabGlobals() void {
    for (0..MAX_TABS) |idx| {
        g_tabs[idx] = null;
        g_tab_close_opacity[idx] = 0;
        g_tab_text_x_start[idx] = 0;
        g_tab_text_x_end[idx] = 0;
        g_tab_text_y_start[idx] = 0;
        g_tab_text_y_end[idx] = 0;
    }
    g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    g_tab_close_pressed = null;
    g_last_frame_time_ms = 0;
    g_tab_rename_active = false;
    g_tab_rename_idx = 0;
    g_tab_rename_len = 0;
    g_tab_rename_cursor = 0;
    g_tab_rename_select_all = false;
}

fn makeTestTabState() TabState {
    return .{
        .kind = .terminal,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
    };
}

test "tab: restoreTab routes ai_session_id through the restore hook" {
    resetTestTabGlobals();
    const previous_hook = g_ai_restore_hook;
    defer g_ai_restore_hook = previous_hook;

    const Captured = struct {
        var session_id: []const u8 = "";
        var called: bool = false;
        fn hook(session_id_in: []const u8) bool {
            session_id = session_id_in;
            called = true;
            return true;
        }
    };
    Captured.called = false;
    Captured.session_id = "";
    g_ai_restore_hook = Captured.hook;

    const snap = session_persist.TabSnap{
        .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
        .ai_session_id = "sess-xyz",
    };
    try std.testing.expect(restoreTab(std.testing.allocator, &snap, 80, 24, .block, false));
    try std.testing.expect(Captured.called);
    try std.testing.expectEqualStrings("sess-xyz", Captured.session_id);
    // The hook owns tab creation; restoreTab must not also build a terminal tab.
    try std.testing.expectEqual(@as(usize, 0), g_tab_count);
}

test "tab: restoreTab skips an ai tab when no restore hook is installed" {
    resetTestTabGlobals();
    const previous_hook = g_ai_restore_hook;
    defer g_ai_restore_hook = previous_hook;
    g_ai_restore_hook = null;

    const snap = session_persist.TabSnap{
        .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
        .ai_session_id = "sess-xyz",
    };
    try std.testing.expect(!restoreTab(std.testing.allocator, &snap, 80, 24, .block, false));
}

test "tab: restoreTab routes ai_history through the restore hook" {
    resetTestTabGlobals();
    const previous_hook = g_ai_history_restore_hook;
    defer g_ai_history_restore_hook = previous_hook;

    const Captured = struct {
        var source_id: []const u8 = "";
        var called: bool = false;
        fn hook(snap: session_persist.AiHistorySnap) bool {
            source_id = snap.source_id;
            called = true;
            return true;
        }
    };
    Captured.called = false;
    Captured.source_id = "";
    g_ai_history_restore_hook = Captured.hook;

    const snap = session_persist.TabSnap{
        .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
        .ai_history = .{
            .source_id = "local-history",
            .target_kind = "local",
            .target_name = "Local",
        },
    };
    try std.testing.expect(restoreTab(std.testing.allocator, &snap, 80, 24, .block, false));
    try std.testing.expect(Captured.called);
    try std.testing.expectEqualStrings("local-history", Captured.source_id);
    try std.testing.expectEqual(@as(usize, 0), g_tab_count);
}

test "tab: restoreTab skips an ai_history tab when no restore hook is installed" {
    resetTestTabGlobals();
    const previous_hook = g_ai_history_restore_hook;
    defer g_ai_history_restore_hook = previous_hook;
    g_ai_history_restore_hook = null;

    const snap = session_persist.TabSnap{
        .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
        .ai_history = .{
            .source_id = "local-history",
            .target_kind = "local",
            .target_name = "Local",
        },
    };
    try std.testing.expect(!restoreTab(std.testing.allocator, &snap, 80, 24, .block, false));
    try std.testing.expectEqual(@as(usize, 0), g_tab_count);
}

test "tab: copilot visibility is scoped to the active terminal tab" {
    resetTestTabGlobals();

    var first = TabState{
        .kind = .terminal,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .copilot_session = null,
    };
    var second = TabState{
        .kind = .terminal,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .copilot_session = null,
    };

    g_tabs[0] = &first;
    g_tabs[1] = &second;
    g_tab_count = 2;

    active_tab_state.g_active_tab = 0;
    try std.testing.expect(!activeCopilotVisible());
    try std.testing.expect(toggleActiveCopilotVisible());
    try std.testing.expect(activeCopilotVisible());

    active_tab_state.g_active_tab = 1;
    try std.testing.expect(!activeCopilotVisible());
    try std.testing.expect(!second.copilot_visible);
    try std.testing.expect(!setActiveCopilotVisible(false));
    try std.testing.expect(setActiveCopilotVisible(true));
    try std.testing.expect(activeCopilotVisible());

    active_tab_state.g_active_tab = 0;
    try std.testing.expect(activeCopilotVisible());
    try std.testing.expect(first.copilot_visible);
}

test "tab: snapshotTab persists focused surface title override" {
    const allocator = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    @memcpy(surface.title_override[0..3], "GLM");
    surface.title_override_len = 3;

    var tree = try SplitTree.init(allocator, &surface);
    defer tree.deinit();

    const tab_state = TabState{
        .kind = .terminal,
        .tree = tree,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .copilot_session = null,
    };

    const snap = try snapshotTab(allocator, &tab_state);
    defer if (snap.title_override) |title| allocator.free(title);

    try std.testing.expectEqualStrings("GLM", snap.title_override.?);
}

test "tab: restored title override applies to focused surface" {
    const allocator = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    var tree = try SplitTree.init(allocator, &surface);
    defer tree.deinit();

    var tab_state = TabState{
        .kind = .terminal,
        .tree = tree,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .copilot_session = null,
    };
    const snap = session_persist.TabSnap{
        .title_override = "GLM",
        .focused_leaf = 0,
        .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
    };

    applyRestoredTabMetadata(&tab_state, &snap);

    try std.testing.expectEqualStrings("GLM", tab_state.focusedSurface().?.getTitle());
}

test "tab: snapshotTab does not use local launch cwd as ssh remote cwd" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.cwd_path_len = 0;
    @memcpy(surface.initial_cwd_path[0..6], "/local");
    surface.initial_cwd_path_len = 6;
    surface.title_override_len = 0;
    surface.setSshConnection("root", "server.test", "22", "", "", false, false);

    var tree = try SplitTree.init(allocator, &surface);
    defer tree.deinit();

    const tab_state = TabState{
        .kind = .terminal,
        .tree = tree,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .copilot_session = null,
    };

    const snap = try snapshotTab(arena.allocator(), &tab_state);
    const ssh = switch (snap.tree) {
        .leaf => |leaf| switch (leaf.surface) {
            .ssh => |s| s,
            .local_shell => return error.UnexpectedShell,
        },
        .split => return error.UnexpectedSplit,
    };

    try std.testing.expect(ssh.cwd == null);
}

test "tab: snapshotTab persists ssh cwd only when remote cwd is known" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var surface: Surface = undefined;
    surface.ref_count = 1;
    @memcpy(surface.cwd_path[0..4], "/srv");
    surface.cwd_path_len = 4;
    @memcpy(surface.initial_cwd_path[0..6], "/local");
    surface.initial_cwd_path_len = 6;
    surface.title_override_len = 0;
    surface.setSshConnection("root", "server.test", "22", "", "", false, false);

    var tree = try SplitTree.init(allocator, &surface);
    defer tree.deinit();

    const tab_state = TabState{
        .kind = .terminal,
        .tree = tree,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .copilot_session = null,
    };

    const snap = try snapshotTab(arena.allocator(), &tab_state);
    const ssh = switch (snap.tree) {
        .leaf => |leaf| switch (leaf.surface) {
            .ssh => |s| s,
            .local_shell => return error.UnexpectedShell,
        },
        .split => return error.UnexpectedSplit,
    };

    try std.testing.expectEqualStrings("/srv", ssh.cwd.?);
}

test "tab: SSH restore command accepts the longest persisted connection fields and cwd" {
    const allocator = std.testing.allocator;

    var user_buf: [128]u8 = undefined;
    @memset(&user_buf, 'u');
    var host_buf: [128]u8 = undefined;
    @memset(&host_buf, 'h');
    var proxy_buf: [256]u8 = undefined;
    @memset(&proxy_buf, 'p');
    var cwd_buf: [512]u8 = undefined;
    @memset(&cwd_buf, 'd');

    var command_buf: [SSH_RESTORE_COMMAND_BUF_SIZE]u8 = undefined;
    const command = try buildSshRestoreCommand(
        allocator,
        &command_buf,
        .{
            .cwd = cwd_buf[0..],
            .user = user_buf[0..],
            .host = host_buf[0..],
            .port = 65535,
            .proxy_jump = proxy_buf[0..],
        },
    );

    try std.testing.expect(std.mem.indexOf(u8, command, "ssh") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "-p 65535") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "cd '") != null);
}

test "tab: spawnAiHistoryTab creates active ai_history tab" {
    resetTestTabGlobals();
    const allocator = std.testing.allocator;
    defer {
        for (0..g_tab_count) |idx| {
            if (g_tabs[idx]) |tab_state| {
                tab_state.deinit(allocator);
                allocator.destroy(tab_state);
                g_tabs[idx] = null;
            }
        }
        resetTestTabGlobals();
    }

    try std.testing.expect(spawnAiHistoryTab(allocator, .{
        .id = "local-history",
        .name = "Local History",
        .target = .local,
    }));

    try std.testing.expectEqual(@as(usize, 1), g_tab_count);
    try std.testing.expectEqual(@as(usize, 0), active_tab_state.g_active_tab);
    const active = activeTab() orelse return error.ExpectedActiveTab;
    try std.testing.expectEqual(TabState.Kind.ai_history, active.kind);
    const session = active.ai_history_session orelse return error.ExpectedAiHistorySession;
    try std.testing.expectEqualStrings("local-history", session.source.id);
}

test "tab: spawnAiHistoryTab owns mutable ssh source buffers" {
    resetTestTabGlobals();
    const allocator = std.testing.allocator;
    defer {
        for (0..g_tab_count) |idx| {
            if (g_tabs[idx]) |tab_state| {
                tab_state.deinit(allocator);
                allocator.destroy(tab_state);
                g_tabs[idx] = null;
            }
        }
        resetTestTabGlobals();
    }

    var id_buf = [_]u8{ 's', 's', 'h', '-', 'h', 'i', 's', 't', 'o', 'r', 'y' };
    var name_buf = [_]u8{ 'B', 'u', 'i', 'l', 'd', ' ', 'B', 'o', 'x' };
    var profile_buf = [_]u8{ 'b', 'u', 'i', 'l', 'd', 'b', 'o', 'x' };

    try std.testing.expect(spawnAiHistoryTab(allocator, .{
        .id = id_buf[0..],
        .name = name_buf[0..],
        .target = .{ .ssh = .{ .profile_name = profile_buf[0..] } },
    }));

    @memset(&id_buf, 'x');
    @memset(&name_buf, 'x');
    @memset(&profile_buf, 'x');

    const active = activeTab() orelse return error.ExpectedActiveTab;
    const session = active.ai_history_session orelse return error.ExpectedAiHistorySession;
    try std.testing.expectEqualStrings("ssh-history", session.source.id);
    try std.testing.expectEqualStrings("Build Box", session.source.name);
    try std.testing.expectEqualStrings("buildbox", session.source.target.ssh.profile_name);
    // The tab conveys the sessions workbench, not the bare source name.
    try std.testing.expectEqualStrings("Sessions · Build Box", active.getTitle());
}

test "tab: spawnAiHistoryTab rolls back when tab allocation fails" {
    resetTestTabGlobals();
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 3,
    });

    try std.testing.expect(!spawnAiHistoryTab(failing_allocator.allocator(), .{
        .id = "local-history",
        .name = "Local History",
        .target = .local,
    }));

    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), g_tab_count);
    try std.testing.expect(g_tabs[0] == null);
}

test "tab: snapshotTab persists a live ai_history tab" {
    const allocator = std.testing.allocator;
    const source: ai_history_source.Source = .{
        .id = "local-history",
        .name = "Local History",
        .target = .local,
    };
    const session = try allocator.create(ai_history_session.Session);
    session.* = ai_history_session.Session.init(allocator, source);
    defer {
        session.deinit();
        allocator.destroy(session);
    }

    const tab = TabState{
        .kind = .ai_history,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = session,
        .copilot_session = null,
    };

    const snap = try snapshotTab(allocator, &tab);
    defer if (snap.ai_history) |history| {
        allocator.free(history.source_id);
        allocator.free(history.target_kind);
        allocator.free(history.target_name);
    };

    try std.testing.expect(snap.ai_session_id == null);
    const history = snap.ai_history orelse return error.ExpectedAiHistorySnap;
    try std.testing.expectEqualStrings("local-history", history.source_id);
    try std.testing.expectEqualStrings("local", history.target_kind);
    try std.testing.expectEqualStrings("Local History", history.target_name);

    const leaf = switch (snap.tree) {
        .leaf => |leaf| leaf,
        .split => return error.UnexpectedSplit,
    };
    switch (leaf.surface) {
        .local_shell => {},
        .ssh => return error.UnexpectedSsh,
    }
}

test "tab: restoreTab prioritizes ai_history over ai_session_id" {
    resetTestTabGlobals();
    const previous_history_hook = g_ai_history_restore_hook;
    const previous_chat_hook = g_ai_restore_hook;
    defer {
        g_ai_history_restore_hook = previous_history_hook;
        g_ai_restore_hook = previous_chat_hook;
    }

    const Captured = struct {
        var history_called: bool = false;
        var chat_called: bool = false;
        fn historyHook(_: session_persist.AiHistorySnap) bool {
            history_called = true;
            return true;
        }
        fn chatHook(_: []const u8) bool {
            chat_called = true;
            return true;
        }
    };
    Captured.history_called = false;
    Captured.chat_called = false;
    g_ai_history_restore_hook = Captured.historyHook;
    g_ai_restore_hook = Captured.chatHook;

    const snap = session_persist.TabSnap{
        .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
        .ai_session_id = "chat-session",
        .ai_history = .{
            .source_id = "local-history",
            .target_kind = "local",
            .target_name = "Local",
        },
    };

    try std.testing.expect(restoreTab(std.testing.allocator, &snap, 80, 24, .block, false));
    try std.testing.expect(Captured.history_called);
    try std.testing.expect(!Captured.chat_called);
    try std.testing.expectEqual(@as(usize, 0), g_tab_count);
}

test "tab: reorder moves active tab forward" {
    resetTestTabGlobals();
    var a = makeTestTabState();
    var b = makeTestTabState();
    var c = makeTestTabState();
    g_tabs[0] = &a;
    g_tabs[1] = &b;
    g_tabs[2] = &c;
    g_tab_count = 3;
    active_tab_state.g_active_tab = 0;
    g_tab_close_opacity[0] = 0.1;
    g_tab_close_opacity[1] = 0.2;
    g_tab_close_opacity[2] = 0.3;
    g_tab_text_x_start[0] = 10;
    g_tab_text_x_start[1] = 20;
    g_tab_text_x_start[2] = 30;
    g_tab_text_x_end[0] = 11;
    g_tab_text_x_end[1] = 21;
    g_tab_text_x_end[2] = 31;
    g_tab_text_y_start[0] = 12;
    g_tab_text_y_start[1] = 22;
    g_tab_text_y_start[2] = 32;
    g_tab_text_y_end[0] = 13;
    g_tab_text_y_end[1] = 23;
    g_tab_text_y_end[2] = 33;

    try std.testing.expect(reorderTab(0, 2));

    try std.testing.expect(g_tabs[0].? == &b);
    try std.testing.expect(g_tabs[1].? == &c);
    try std.testing.expect(g_tabs[2].? == &a);
    try std.testing.expectEqual(@as(usize, 2), active_tab_state.g_active_tab);
    try std.testing.expectEqual(@as(f32, 0.2), g_tab_close_opacity[0]);
    try std.testing.expectEqual(@as(f32, 0.3), g_tab_close_opacity[1]);
    try std.testing.expectEqual(@as(f32, 0.1), g_tab_close_opacity[2]);
    try std.testing.expectEqual(@as(f32, 20), g_tab_text_x_start[0]);
    try std.testing.expectEqual(@as(f32, 30), g_tab_text_x_start[1]);
    try std.testing.expectEqual(@as(f32, 10), g_tab_text_x_start[2]);
    try std.testing.expectEqual(@as(f32, 21), g_tab_text_x_end[0]);
    try std.testing.expectEqual(@as(f32, 31), g_tab_text_x_end[1]);
    try std.testing.expectEqual(@as(f32, 11), g_tab_text_x_end[2]);
    try std.testing.expectEqual(@as(f32, 22), g_tab_text_y_start[0]);
    try std.testing.expectEqual(@as(f32, 32), g_tab_text_y_start[1]);
    try std.testing.expectEqual(@as(f32, 12), g_tab_text_y_start[2]);
    try std.testing.expectEqual(@as(f32, 23), g_tab_text_y_end[0]);
    try std.testing.expectEqual(@as(f32, 33), g_tab_text_y_end[1]);
    try std.testing.expectEqual(@as(f32, 13), g_tab_text_y_end[2]);
}

test "tab: rename key handling accepts platform-neutral key events" {
    resetTestTabGlobals();
    @memcpy(g_tab_rename_buf[0..3], "abc");
    g_tab_rename_len = 3;
    g_tab_rename_cursor = 1;
    g_tab_rename_active = true;

    handleRenameKey(.{ .key = input_key.Key.arrow_right });
    try std.testing.expectEqual(@as(usize, 2), g_tab_rename_cursor);

    handleRenameKey(.{ .key = input_key.Key.backspace });
    try std.testing.expectEqualStrings("ac", g_tab_rename_buf[0..g_tab_rename_len]);
    try std.testing.expectEqual(@as(usize, 1), g_tab_rename_cursor);
}

test "tab: reorder moves active tab backward" {
    resetTestTabGlobals();
    var a = makeTestTabState();
    var b = makeTestTabState();
    var c = makeTestTabState();
    g_tabs[0] = &a;
    g_tabs[1] = &b;
    g_tabs[2] = &c;
    g_tab_count = 3;
    active_tab_state.g_active_tab = 2;

    try std.testing.expect(reorderTab(2, 0));

    try std.testing.expect(g_tabs[0].? == &c);
    try std.testing.expect(g_tabs[1].? == &a);
    try std.testing.expect(g_tabs[2].? == &b);
    try std.testing.expectEqual(@as(usize, 0), active_tab_state.g_active_tab);
}

test "tab: reorder preserves selected logical tab when another tab moves" {
    resetTestTabGlobals();
    var a = makeTestTabState();
    var b = makeTestTabState();
    var c = makeTestTabState();
    g_tabs[0] = &a;
    g_tabs[1] = &b;
    g_tabs[2] = &c;
    g_tab_count = 3;
    active_tab_state.g_active_tab = 1;

    try std.testing.expect(reorderTab(0, 2));
    try std.testing.expect(g_tabs[active_tab_state.g_active_tab].? == &b);
    try std.testing.expectEqual(@as(usize, 0), active_tab_state.g_active_tab);

    try std.testing.expect(reorderTab(2, 0));
    try std.testing.expect(g_tabs[active_tab_state.g_active_tab].? == &b);
    try std.testing.expectEqual(@as(usize, 1), active_tab_state.g_active_tab);
}

test "tab: reorder rejects invalid and no-op moves" {
    resetTestTabGlobals();
    var a = makeTestTabState();
    g_tabs[0] = &a;
    g_tab_count = 1;
    active_tab_state.g_active_tab = 0;

    try std.testing.expect(!reorderTab(0, 0));
    try std.testing.expect(!reorderTab(0, 1));
    try std.testing.expect(!reorderTab(1, 0));
    try std.testing.expect(g_tabs[0].? == &a);
    try std.testing.expectEqual(@as(usize, 0), active_tab_state.g_active_tab);
}

test "focusPanelByIndex focuses panels in screen reading order" {
    // Two side-by-side panels: root horizontal, left | right.
    var l = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var r = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var root = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &l, .right = &r } };
    const Stub = struct {
        var counter: usize = 0;
        var sentinels: [8]usize = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: std.mem.Allocator) ?*Surface {
            const ptr = &sentinels[counter];
            counter += 1;
            return @ptrCast(@alignCast(ptr));
        }
    };
    Stub.counter = 0;

    var ts = TabState{
        .kind = .terminal,
        .tree = try SplitTree.fromSnapshot(std.testing.allocator, &root, Stub.make),
        .focused = .root,
    };
    // Sentinel surfaces can't be unref'd, so free the arena directly (no TabState.deinit).
    defer ts.tree.arena.deinit();

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = &ts;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // Handles: root=0, left=1, right=2. Reading order: [left(1), right(2)].
    try std.testing.expect(focusPanelByIndex(std.testing.allocator, 1));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 1), @intFromEnum(ts.focused));
    try std.testing.expect(focusPanelByIndex(std.testing.allocator, 2));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 2), @intFromEnum(ts.focused));
    // Out of range → false, focus unchanged.
    try std.testing.expect(!focusPanelByIndex(std.testing.allocator, 3));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 2), @intFromEnum(ts.focused));
}

test "tab: splitIntoPreview adds a preview leaf and grows the tree by 2 nodes" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    // Build a minimal terminal tab with a stack-allocated surface stub.
    // ref_count starts at 1; SplitTree.init will call pane.ref() → 2.
    // We never let refcount reach 0 (would call surface.deinit → crash on stub),
    // because tree ops keep it ≥ 1 after all cleanup. The testing allocator never
    // tracks the stack surface, so no leak is reported.
    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = try SplitTree.init(gpa, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    const before = t.tree.nodes.len; // 1
    const focused_before = t.focused;

    const p = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;

    // Tree should have grown by exactly 2 nodes (one split node + one preview leaf)
    try std.testing.expectEqual(before + 2, t.tree.nodes.len);

    // Exactly one preview leaf must exist in the tree
    var preview_count: usize = 0;
    var it = t.tree.panes();
    while (it.next()) |entry| {
        switch (entry.pane) {
            .preview => preview_count += 1,
            .terminal => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), preview_count);

    // The returned pointer is the pane in the tree
    _ = p; // borrowed, owned by the tree

    // Focus must NOT have moved to the preview — terminal is still focused.
    // After split(.root, .right, ...), terminal moved from handle 0 to handle 2.
    // focused_before was 0 (.root), so it should now be 2.
    const expected_focused: SplitTree.Node.Handle = @enumFromInt(focused_before.idx() + 2);
    try std.testing.expectEqual(expected_focused, t.focused);

    // Verify the focused node is indeed the terminal leaf, not a split or preview.
    try std.testing.expect(t.focused.idx() < t.tree.nodes.len);
    const focused_node = t.tree.nodes[t.focused.idx()];
    switch (focused_node) {
        .leaf => |pane| switch (pane) {
            .terminal => {}, // correct
            .preview => return error.FocusedIsPreviewNotTerminal,
        },
        .split => return error.FocusedIsSplitNotLeaf,
    }

    // t.deinit (deferred) will call tree.deinit(), which unrefs the preview pane
    // (freeing it) and decrements the surface refcount. The testing allocator
    // must report no leak after the defer runs.
}

test "tab: closePreviewPane closes the unfocused preview and keeps the terminal focused" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = try SplitTree.init(gpa, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // No preview pane yet → nothing to close.
    try std.testing.expect(!closePreviewPane(gpa));

    _ = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;
    // Tree: [0]=split, [1]=preview, [2]=terminal; focus stayed on the terminal.
    const focused_before = t.focused;
    try std.testing.expect(focused_before.idx() == 2);

    try std.testing.expect(closePreviewPane(gpa));

    // Only the terminal leaf remains and it keeps focus.
    try std.testing.expectEqual(@as(usize, 1), t.tree.nodes.len);
    try std.testing.expect(t.focused.idx() < t.tree.nodes.len);
    switch (t.tree.nodes[t.focused.idx()]) {
        .leaf => |pane| switch (pane) {
            .terminal => {},
            .preview => return error.FocusedIsPreview,
        },
        .split => return error.FocusedIsSplit,
    }
}

test "tab: closePreviewPane closes a focused preview and refocuses the terminal" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = try SplitTree.init(gpa, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    _ = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;
    t.focused = firstPreviewForReuse(gpa, t) orelse return error.NoPreviewAfterSplit;

    try std.testing.expect(closePreviewPane(gpa));

    // The surviving terminal leaf takes focus.
    try std.testing.expectEqual(@as(usize, 1), t.tree.nodes.len);
    try std.testing.expect(t.focused.idx() < t.tree.nodes.len);
    switch (t.tree.nodes[t.focused.idx()]) {
        .leaf => |pane| switch (pane) {
            .terminal => {},
            .preview => return error.FocusedIsPreview,
        },
        .split => return error.FocusedIsSplit,
    }
}

test "tab: closePreviewPane leaves a lone preview pane for the standard close path" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    // Preview-only tab (single preview leaf, no terminal).
    const p = try PreviewPane.create(gpa);
    var tree = try SplitTree.initPane(gpa, .{ .preview = p });
    p.unref(gpa); // tree holds the sole owning ref
    errdefer tree.deinit();

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = tree,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // A lone preview pane is the whole tab; closing it is tab/window-close
    // territory, so closePreviewPane declines and the caller falls through.
    try std.testing.expect(!closePreviewPane(gpa));
    try std.testing.expectEqual(@as(usize, 1), t.tree.nodes.len);
}

test "tab: closeFocusedSplit on the last terminal focuses a preview leaf, not a split node" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = try SplitTree.init(gpa, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // Two preview panes around the focused terminal, then close the terminal.
    _ = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;
    _ = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;

    try std.testing.expectEqual(CloseResult.closed_split, closeFocusedSplit(gpa));

    // Remaining tree: [split, preview, preview]. Focus must land on a LEAF
    // pane (a preview), never on the root split node, so keyboard routing
    // (focusedPreviewPane) still targets a real pane.
    try std.testing.expect(t.focused.idx() < t.tree.nodes.len);
    switch (t.tree.nodes[t.focused.idx()]) {
        .leaf => |pane| switch (pane) {
            .preview => {},
            .terminal => return error.TerminalSurvivedClose,
        },
        .split => return error.FocusedIsSplitNode,
    }
}

test "tab: firstPreviewForReuse returns the preview leaf, null when only terminals" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = try SplitTree.init(gpa, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // Before splitIntoPreview: no preview leaf → null
    try std.testing.expect(firstPreviewForReuse(gpa, t) == null);

    // After splitIntoPreview: one preview leaf → its handle
    _ = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;

    const handle = firstPreviewForReuse(gpa, t) orelse return error.NoPreviewAfterSplit;

    // The handle must point to a preview leaf
    try std.testing.expect(handle.idx() < t.tree.nodes.len);
    switch (t.tree.nodes[handle.idx()]) {
        .leaf => |pane| switch (pane) {
            .preview => {}, // correct
            .terminal => return error.HandlePointsToTerminal,
        },
        .split => return error.HandlePointsToSplit,
    }
}
