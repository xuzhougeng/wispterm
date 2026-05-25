const app_metadata = @import("app_metadata.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const std = @import("std");

pub const CommandAction = enum {
    new_tab,
    new_agent,
    select_agent_history,
    split_right,
    split_down,
    split_left,
    split_up,
    focus_previous,
    focus_next,
    equalize_splits,
    close_split_or_tab,
    toggle_sidebar,
    toggle_file_explorer,
    toggle_browser_panel,
    toggle_quake,
    show_shortcuts,
    open_config,
    font_size_decrease,
    font_size_increase,
    toggle_maximize,
    copy_remote_key,
    connect_wechat,
    start_wechat,
    stop_wechat,
    wechat_status,
    unbind_wechat,
    export_ai_chat_markdown,
    export_ai_chat_markdown_clean,
    show_version,
    check_for_updates,
    install_update,
    open_latest_release,
};

pub const CommandEntry = struct {
    title: []const u8,
    detail: []const u8,
    shortcut: []const u8,
    action: CommandAction,
};

pub const command_entries = [_]CommandEntry{
    .{ .title = "New Session", .detail = platform_pty_command.session_launcher_detail, .shortcut = "", .action = .new_tab },
    .{ .title = "New Agent", .detail = "Open a new Agent tab with the default AI config", .shortcut = "", .action = .new_agent },
    .{ .title = "Select Agent History", .detail = "Open the command-center agent history picker", .shortcut = "", .action = .select_agent_history },
    .{ .title = "Split Right", .detail = "Create a panel to the right", .shortcut = "", .action = .split_right },
    .{ .title = "Split Down", .detail = "Create a panel below", .shortcut = "", .action = .split_down },
    .{ .title = "Split Left", .detail = "Create a panel to the left", .shortcut = "", .action = .split_left },
    .{ .title = "Split Up", .detail = "Create a panel above", .shortcut = "", .action = .split_up },
    .{ .title = "Previous Panel", .detail = "Move focus to the previous panel", .shortcut = "", .action = .focus_previous },
    .{ .title = "Next Panel", .detail = "Move focus to the next panel", .shortcut = "", .action = .focus_next },
    .{ .title = "Equalize Panels", .detail = "Reset split sizes in the current tab", .shortcut = "", .action = .equalize_splits },
    .{ .title = "Close Panel / Tab", .detail = "Close focused panel or tab; press again for the last panel", .shortcut = "", .action = .close_split_or_tab },
    .{ .title = "Toggle Sidebar", .detail = "Show or hide the tab sidebar", .shortcut = "", .action = .toggle_sidebar },
    .{ .title = "Toggle File Explorer", .detail = "Show or hide the left-side file explorer", .shortcut = "", .action = .toggle_file_explorer },
    .{ .title = "Toggle Browser", .detail = "Show embedded browser for local or SSH URLs", .shortcut = "", .action = .toggle_browser_panel },
    .{ .title = "Toggle Quake Window", .detail = "Show or hide the drop-down terminal window", .shortcut = "", .action = .toggle_quake },
    .{ .title = "Keyboard Shortcuts", .detail = "Show the shortcut reference overlay", .shortcut = "", .action = .show_shortcuts },
    .{ .title = "Open Config", .detail = "Open the Phantty config file", .shortcut = "", .action = .open_config },
    .{ .title = "Decrease Font Size", .detail = "Make terminal text smaller", .shortcut = "", .action = .font_size_decrease },
    .{ .title = "Increase Font Size", .detail = "Make terminal text larger", .shortcut = "", .action = .font_size_increase },
    .{ .title = "Toggle Maximize", .detail = "Maximize or restore the window", .shortcut = "", .action = .toggle_maximize },
    .{ .title = "Copy Remote Key", .detail = "Copy the active Phantty remote session key", .shortcut = "click Remote key", .action = .copy_remote_key },
    .{ .title = "Connect WeChat", .detail = "Scan a QR code to connect WeChat direct control", .shortcut = "", .action = .connect_wechat },
    .{ .title = "WeChat: Start", .detail = "Start polling with the saved WeChat binding", .shortcut = "", .action = .start_wechat },
    .{ .title = "WeChat: Stop", .detail = "Stop polling and keep the saved WeChat binding", .shortcut = "", .action = .stop_wechat },
    .{ .title = "WeChat: Status", .detail = "Show the WeChat direct connection state", .shortcut = "", .action = .wechat_status },
    .{ .title = "WeChat: Unbind", .detail = "Clear the stored WeChat direct binding", .shortcut = "", .action = .unbind_wechat },
    .{ .title = "Export AI Chat Markdown", .detail = "Save the active AI Chat transcript as Markdown", .shortcut = "", .action = .export_ai_chat_markdown },
    .{ .title = "Export AI Chat Markdown Clean", .detail = "Save user prompts and the final AI result without thinking", .shortcut = "", .action = .export_ai_chat_markdown_clean },
    .{ .title = "Version", .detail = "Show Phantty version", .shortcut = app_metadata.version, .action = .show_version },
    .{ .title = "Check for Updates", .detail = "Check GitHub Releases for a newer Phantty version", .shortcut = "", .action = .check_for_updates },
    .{ .title = "Install Update", .detail = "Install the last detected portable update", .shortcut = "", .action = .install_update },
    .{ .title = "Open Latest Release", .detail = "Open the latest Phantty GitHub Release", .shortcut = "", .action = .open_latest_release },
};

pub const CommandPaletteMode = enum {
    commands,
    agent_history,
};

pub const NewAgentLaunchAction = enum {
    open_form,
    connect_default_profile_as_agent,
};

pub const SESSION_LAUNCHER_ROW_COUNT: usize = platform_pty_command.session_launcher_row_count;
pub const SESSION_LAUNCHER_ROW_AI_AGENT: usize = platform_pty_command.session_launcher_ai_agent_row;

pub const State = struct {
    command_palette_visible: bool = false,
    command_palette_selected: usize = 0,
    command_palette_filter_len: usize = 0,
    command_palette_mode: CommandPaletteMode = .commands,
    command_palette_history_selected: usize = 0,
    startup_shortcuts_visible: bool = false,
    session_launcher_visible: bool = false,
    session_launcher_selected: usize = 0,
    ssh_list_visible: bool = false,
    ssh_form_visible: bool = false,
    ai_list_visible: bool = false,
    ai_form_visible: bool = false,
    settings_visible: bool = false,

    pub fn sessionLauncherVisible(self: *const State) bool {
        return self.session_launcher_visible or self.ssh_list_visible or self.ssh_form_visible or self.ai_list_visible or self.ai_form_visible;
    }

    pub fn commandPaletteIsHistoryMode(self: *const State) bool {
        return self.command_palette_mode == .agent_history;
    }

    pub fn commandPaletteSetMode(self: *State, mode: CommandPaletteMode) void {
        self.command_palette_mode = mode;
        if (mode == .commands) self.command_palette_history_selected = 0;
    }

    pub fn commandPaletteOpenWithMode(self: *State, mode: CommandPaletteMode) void {
        self.command_palette_visible = true;
        self.command_palette_selected = 0;
        self.command_palette_filter_len = 0;
        self.commandPaletteSetMode(mode);
        self.command_palette_history_selected = 0;
        self.startup_shortcuts_visible = false;
    }

    pub fn commandPaletteOpen(self: *State) void {
        self.commandPaletteOpenWithMode(.commands);
    }

    pub fn commandPaletteClose(self: *State) void {
        self.command_palette_visible = false;
        self.command_palette_filter_len = 0;
        self.command_palette_selected = 0;
        self.commandPaletteSetMode(.commands);
        self.command_palette_history_selected = 0;
    }

    pub fn commandPaletteOpenAgentHistory(self: *State) void {
        self.commandPaletteOpen();
        self.commandPaletteSetMode(.agent_history);
        self.session_launcher_visible = false;
        self.ssh_list_visible = false;
        self.ssh_form_visible = false;
        self.ai_list_visible = false;
        self.ai_form_visible = false;
    }

    pub fn commandPaletteLeaveAgentHistory(self: *State) void {
        self.commandPaletteSetMode(.commands);
    }

    pub fn commandPaletteShouldRefreshAgentHistory(self: *const State, loaded_revision: u64, latest_revision: u64) bool {
        return self.commandPaletteIsHistoryMode() and loaded_revision != latest_revision;
    }

    pub fn commandPaletteMoveAgentHistory(self: *State, delta: i32, row_count: usize) void {
        if (!self.commandPaletteIsHistoryMode()) return;
        if (row_count == 0) {
            self.command_palette_history_selected = 0;
            return;
        }

        const current: i32 = @intCast(@min(self.command_palette_history_selected, row_count - 1));
        const count_i: i32 = @intCast(row_count);
        var next = current + delta;
        while (next < 0) next += count_i;
        next = @mod(next, count_i);
        self.command_palette_history_selected = @intCast(next);
    }

    pub fn commandPaletteClampAgentHistorySelection(self: *State, row_count: usize) void {
        if (!self.commandPaletteIsHistoryMode() or row_count == 0) {
            self.command_palette_history_selected = 0;
            return;
        }
        self.command_palette_history_selected = @min(self.command_palette_history_selected, row_count - 1);
    }

    pub fn commandPaletteSelectedAgentHistoryIndex(self: *const State, row_count: usize) ?usize {
        if (!self.commandPaletteIsHistoryMode() or row_count == 0) return null;
        return @min(self.command_palette_history_selected, row_count - 1);
    }

    pub fn commandPaletteActivateSelected(self: *const State, row_count: usize) ?usize {
        return self.commandPaletteSelectedAgentHistoryIndex(row_count);
    }

    pub fn commandPaletteActivateHistoryRow(self: *State, row_idx: usize, row_count: usize) ?usize {
        if (!self.commandPaletteIsHistoryMode() or row_idx >= row_count) return null;
        self.command_palette_history_selected = row_idx;
        return row_idx;
    }

    pub fn sessionLauncherOpen(self: *State) void {
        self.session_launcher_visible = true;
        self.session_launcher_selected = 0;
        self.ssh_list_visible = false;
        self.ssh_form_visible = false;
        self.ai_list_visible = false;
        self.ai_form_visible = false;
        self.command_palette_visible = false;
        self.settings_visible = false;
        self.startup_shortcuts_visible = false;
    }

    pub fn sessionLauncherClose(self: *State) void {
        self.session_launcher_visible = false;
        self.ssh_list_visible = false;
        self.ssh_form_visible = false;
        self.ai_list_visible = false;
        self.ai_form_visible = false;
    }

    pub fn settingsPageOpen(self: *State) void {
        self.commandPaletteClose();
        self.sessionLauncherClose();
        self.startup_shortcuts_visible = false;
        self.settings_visible = true;
    }
};

pub fn historyRowsNeedCleanup(previous: State, next: State) bool {
    return previous.commandPaletteIsHistoryMode() and
        (!next.command_palette_visible or next.command_palette_mode != .agent_history);
}

pub fn findCommandAction(title: []const u8) ?CommandAction {
    for (command_entries) |entry| {
        if (std.mem.eql(u8, entry.title, title)) return entry.action;
    }
    return null;
}

pub fn resolveNewAgentLaunch(has_profiles: bool) NewAgentLaunchAction {
    return if (has_profiles) .connect_default_profile_as_agent else .open_form;
}

test "command center includes New Agent action" {
    try std.testing.expectEqual(CommandAction.new_agent, findCommandAction("New Agent"));
}

test "command center includes Select Agent History action" {
    try std.testing.expectEqual(CommandAction.select_agent_history, findCommandAction("Select Agent History"));
}

test "command center includes update check actions" {
    try std.testing.expectEqual(CommandAction.check_for_updates, findCommandAction("Check for Updates"));
    try std.testing.expectEqual(CommandAction.install_update, findCommandAction("Install Update"));
    try std.testing.expectEqual(CommandAction.open_latest_release, findCommandAction("Open Latest Release"));
}

test "command center includes AI Markdown export actions" {
    try std.testing.expectEqual(CommandAction.export_ai_chat_markdown, findCommandAction("Export AI Chat Markdown"));
    try std.testing.expectEqual(CommandAction.export_ai_chat_markdown_clean, findCommandAction("Export AI Chat Markdown Clean"));
}

test "command center includes WeChat direct actions" {
    try std.testing.expectEqual(CommandAction.connect_wechat, findCommandAction("Connect WeChat"));
    try std.testing.expectEqual(CommandAction.start_wechat, findCommandAction("WeChat: Start"));
    try std.testing.expectEqual(CommandAction.stop_wechat, findCommandAction("WeChat: Stop"));
    try std.testing.expectEqual(CommandAction.wechat_status, findCommandAction("WeChat: Status"));
    try std.testing.expectEqual(CommandAction.unbind_wechat, findCommandAction("WeChat: Unbind"));
}

test "command center browser text is backend neutral" {
    comptime {
        @setEvalBranchQuota(10_000);
        for (command_entries) |entry| {
            if (std.mem.indexOf(u8, entry.detail, "Web" ++ "View2") != null) {
                @compileError("command center browser text must not expose the concrete embedded browser backend");
            }
        }
    }
}

test "command center New Agent launch path forces agent mode when profiles exist" {
    try std.testing.expectEqual(
        NewAgentLaunchAction.connect_default_profile_as_agent,
        resolveNewAgentLaunch(true),
    );
}

test "command center New Agent opens the AI form when no profiles exist" {
    try std.testing.expectEqual(
        NewAgentLaunchAction.open_form,
        resolveNewAgentLaunch(false),
    );
}

test "Select Agent History reuses command center open flow and switches to history mode" {
    var state = State{ .startup_shortcuts_visible = true };

    state.commandPaletteOpenAgentHistory();

    try std.testing.expect(state.command_palette_visible);
    try std.testing.expectEqual(@as(usize, 0), state.command_palette_selected);
    try std.testing.expectEqual(@as(usize, 0), state.command_palette_filter_len);
    try std.testing.expect(!state.startup_shortcuts_visible);
    try std.testing.expect(state.commandPaletteIsHistoryMode());
}

test "closing the command center clears history picker mode" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();

    state.commandPaletteClose();

    try std.testing.expect(!state.command_palette_visible);
    try std.testing.expect(!state.commandPaletteIsHistoryMode());
}

test "agent history picker defaults selection to the first row" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();

    try std.testing.expectEqual(@as(?usize, 0), state.commandPaletteSelectedAgentHistoryIndex(2));
}

test "agent history picker keyboard moves selection" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();

    state.commandPaletteMoveAgentHistory(1, 2);

    try std.testing.expectEqual(@as(?usize, 1), state.commandPaletteSelectedAgentHistoryIndex(2));
}

test "agent history picker escape returns to command list mode" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();

    state.commandPaletteLeaveAgentHistory();

    try std.testing.expect(state.command_palette_visible);
    try std.testing.expect(!state.commandPaletteIsHistoryMode());
}

test "agent history picker has no selection when the history list is empty" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();

    try std.testing.expectEqual(@as(?usize, null), state.commandPaletteSelectedAgentHistoryIndex(0));
}

test "opening settings from agent history closes the command center cleanly" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();

    state.settingsPageOpen();

    try std.testing.expect(state.settings_visible);
    try std.testing.expect(!state.command_palette_visible);
    try std.testing.expect(!state.commandPaletteIsHistoryMode());
}

test "state reports when a transition must clean up owned history rows" {
    var previous = State{};
    previous.commandPaletteOpenAgentHistory();

    var next = previous;
    next.settingsPageOpen();

    try std.testing.expect(historyRowsNeedCleanup(previous, next));
}

test "agent history activation returns the selected row index" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();
    state.commandPaletteMoveAgentHistory(1, 2);

    try std.testing.expectEqual(@as(?usize, 1), state.commandPaletteActivateSelected(2));
}

test "clicking an agent history row updates selection and returns that row" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();

    try std.testing.expectEqual(@as(?usize, 2), state.commandPaletteActivateHistoryRow(2, 3));
    try std.testing.expectEqual(@as(?usize, 2), state.commandPaletteSelectedAgentHistoryIndex(3));
}
