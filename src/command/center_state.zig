const app_metadata = @import("../app_metadata.zig");
const platform_pty_command = @import("../platform/pty_command.zig");
const std = @import("std");
const command_palette_history_view = @import("palette_history_view.zig");

pub const CommandAction = enum {
    new_tab,
    load_openssh_config,
    new_agent,
    toggle_ai_copilot,
    manage_ai_profiles,
    manage_mcp_servers,
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
    open_jupyter_panel,
    toggle_quake,
    open_settings,
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
    configure_feishu,
    quick_configure_ai,
    export_ai_chat_markdown,
    export_ai_chat_markdown_clean,
    show_version,
    check_for_updates,
    download_update,
    install_update,
    open_latest_release,
    show_whats_new,
    show_integration_prompt,
    open_memory_center,
    open_skill_center,
    open_port_forwarding,
    split_preview,
    run_memory_digest_now,
    star_repo,
};

pub const CommandEntry = struct {
    title: []const u8,
    detail: []const u8,
    shortcut: []const u8,
    action: CommandAction,
};

pub const command_entries = [_]CommandEntry{
    .{ .title = "New Session", .detail = platform_pty_command.session_launcher_detail, .shortcut = "", .action = .new_tab },
    .{ .title = "New Copilot", .detail = "Open a new Copilot tab with the default AI config", .shortcut = "", .action = .new_agent },
    .{ .title = "Toggle Copilot", .detail = "Open or close the Copilot sidebar on the current terminal", .shortcut = "", .action = .toggle_ai_copilot },
    .{ .title = "Manage AI Profiles", .detail = "Create, edit, or delete saved AI profiles", .shortcut = "", .action = .manage_ai_profiles },
    .{ .title = "MCP Servers", .detail = "Add, edit, test, or remove MCP tool servers", .shortcut = "", .action = .manage_mcp_servers },
    .{ .title = "Copilot History", .detail = "Open the command-center Copilot history picker", .shortcut = "", .action = .select_agent_history },
    .{ .title = "Skill Center", .detail = "Manage Claude Code / Codex skills and local executable tools", .shortcut = "", .action = .open_skill_center },
    .{ .title = "Split Right", .detail = "Create a panel to the right", .shortcut = "", .action = .split_right },
    .{ .title = "Split Down", .detail = "Create a panel below", .shortcut = "", .action = .split_down },
    .{ .title = "Split Left", .detail = "Create a panel to the left", .shortcut = "", .action = .split_left },
    .{ .title = "Split Up", .detail = "Create a panel above", .shortcut = "", .action = .split_up },
    // Previous/Next Panel removed from the palette (declutter); the Shift+Cmd+[ / ]
    // keybinds in keybind.zig still work — focus_previous/focus_next stay in the enum.
    .{ .title = "Equalize Panels", .detail = "Reset split sizes in the current tab", .shortcut = "", .action = .equalize_splits },
    .{ .title = "Close Panel / Tab", .detail = "Close focused panel or tab; press again for the last panel", .shortcut = "", .action = .close_split_or_tab },
    .{ .title = "Toggle Sidebar", .detail = "Show or hide the tab sidebar", .shortcut = "", .action = .toggle_sidebar },
    .{ .title = "Toggle File Explorer", .detail = "Show or hide the left-side file explorer", .shortcut = "", .action = .toggle_file_explorer },
    .{ .title = "Toggle Browser", .detail = "Open the configured browser for local or SSH URLs", .shortcut = "", .action = .toggle_browser_panel },
    .{ .title = "Open Jupyter", .detail = "Open the panel and paste a running Jupyter URL (local or SSH)", .shortcut = "", .action = .open_jupyter_panel },
    .{ .title = "Toggle Quake Window", .detail = "Show or hide the drop-down terminal window", .shortcut = "", .action = .toggle_quake },
    .{ .title = "Settings", .detail = "Open the settings page", .shortcut = "", .action = .open_settings },
    .{ .title = "Keyboard Shortcuts", .detail = "Show the shortcut reference overlay", .shortcut = "", .action = .show_shortcuts },
    .{ .title = "Open Config", .detail = "Open the WispTerm config file", .shortcut = "", .action = .open_config },
    .{ .title = "Load OpenSSH Config", .detail = "Import ~/.ssh/config into SSH profiles", .shortcut = "", .action = .load_openssh_config },
    .{ .title = "Decrease Font Size", .detail = "Make terminal text smaller", .shortcut = "", .action = .font_size_decrease },
    .{ .title = "Increase Font Size", .detail = "Make terminal text larger", .shortcut = "", .action = .font_size_increase },
    .{ .title = "Toggle Maximize", .detail = "Maximize or restore the window", .shortcut = "", .action = .toggle_maximize },
    .{ .title = "Copy Remote Key", .detail = "Copy the active WispTerm remote session key", .shortcut = "click Remote key", .action = .copy_remote_key },
    .{ .title = "Connect WeChat", .detail = "Scan a QR code to connect WeChat direct control", .shortcut = "", .action = .connect_wechat },
    .{ .title = "WeChat: Start", .detail = "Start polling with the saved WeChat binding", .shortcut = "", .action = .start_wechat },
    .{ .title = "WeChat: Stop", .detail = "Stop polling and keep the saved WeChat binding", .shortcut = "", .action = .stop_wechat },
    .{ .title = "WeChat: Status", .detail = "Show the WeChat direct connection state", .shortcut = "", .action = .wechat_status },
    .{ .title = "WeChat: Unbind", .detail = "Clear the stored WeChat direct binding", .shortcut = "", .action = .unbind_wechat },
    .{ .title = "Feishu: Configure", .detail = "Enter App ID and App Secret for the Feishu bot", .shortcut = "", .action = .configure_feishu },
    .{ .title = "Settings: Quick Configure AI", .detail = "Paste one DeepSeek API key to set up the main + subagent models", .shortcut = "", .action = .quick_configure_ai },
    .{ .title = "Export Copilot Markdown", .detail = "Save the active Copilot transcript as Markdown", .shortcut = "", .action = .export_ai_chat_markdown },
    .{ .title = "Export Copilot Markdown Clean", .detail = "Save user prompts and the final AI result without thinking", .shortcut = "", .action = .export_ai_chat_markdown_clean },
    .{ .title = "Version", .detail = "Show WispTerm version", .shortcut = app_metadata.version, .action = .show_version },
    .{ .title = "Check for Updates", .detail = "Check GitHub Releases for a newer WispTerm version", .shortcut = "", .action = .check_for_updates },
    .{ .title = "Download Update", .detail = "Download the latest update to your Downloads folder", .shortcut = "", .action = .download_update },
    .{ .title = "Install Update", .detail = "Install the downloaded update and relaunch (macOS)", .shortcut = "", .action = .install_update },
    .{ .title = "Open Latest Release", .detail = "Open the latest WispTerm GitHub Release", .shortcut = "", .action = .open_latest_release },
    .{ .title = "What's New", .detail = "Show what changed in this version of WispTerm", .shortcut = app_metadata.version, .action = .show_whats_new },
    .{ .title = "Install Integration", .detail = "Show the prompt for Codex, Claude Code, or another agent to generate its own WispTerm hook", .shortcut = "", .action = .show_integration_prompt },
    .{ .title = "Memory Center", .detail = "View AI-remembered facts and Memory Digest summaries", .shortcut = "", .action = .open_memory_center },
    .{ .title = "Port Forwarding", .detail = "Manage SSH port forwarding rules", .shortcut = "", .action = .open_port_forwarding },
    .{ .title = "Split Preview", .detail = "Open a preview panel on the right", .shortcut = "", .action = .split_preview },
    .{ .title = "Run Memory Digest Now", .detail = "Scan AI chat logs and generate today's digest", .shortcut = "", .action = .run_memory_digest_now },
    .{ .title = "Star Me", .detail = "Open the WispTerm GitHub repo to give it a star", .shortcut = "", .action = .star_repo },
};

test "command center exposes generic integration prompt action only" {
    var found_generic = false;
    for (command_entries) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.title, "Install Claude Code Integration"));
        try std.testing.expect(!std.mem.eql(u8, entry.title, "Remove Claude Code Integration"));
        if (std.mem.eql(u8, entry.title, "Install Integration")) {
            found_generic = true;
            try std.testing.expectEqual(CommandAction.show_integration_prompt, entry.action);
            try std.testing.expect(std.mem.indexOf(u8, entry.detail, "prompt") != null);
        }
    }
    try std.testing.expect(found_generic);
}

pub const CommandPaletteMode = enum {
    commands,
    agent_history,
};

pub const NewAgentLaunchAction = enum {
    open_form,
    connect_default_profile_as_agent,
};

pub const SESSION_LAUNCHER_ROW_COUNT: usize = platform_pty_command.session_launcher_row_count;
pub const SESSION_LAUNCHER_ROW_TMUX: usize = platform_pty_command.session_launcher_tmux_row;
pub const SESSION_LAUNCHER_ROW_AI_AGENT: usize = platform_pty_command.session_launcher_ai_agent_row;
pub const SESSION_LAUNCHER_ROW_AI_HISTORY: usize = platform_pty_command.session_launcher_ai_history_row;

pub const State = struct {
    command_palette_visible: bool = false,
    command_palette_selected: usize = 0,
    command_palette_filter_len: usize = 0,
    command_palette_mode: CommandPaletteMode = .commands,
    command_palette_history_selected: usize = 0,
    command_palette_history_source: command_palette_history_view.SourceFilter = .all,
    startup_shortcuts_visible: bool = false,
    session_launcher_visible: bool = false,
    session_launcher_selected: usize = 0,
    session_launcher_return_to_command_palette: bool = false,
    ssh_list_visible: bool = false,
    ssh_form_visible: bool = false,
    ai_list_visible: bool = false,
    ai_form_visible: bool = false,
    ai_history_source_visible: bool = false,
    settings_visible: bool = false,

    pub fn sessionLauncherVisible(self: *const State) bool {
        return self.session_launcher_visible or self.ssh_list_visible or self.ssh_form_visible or self.ai_list_visible or self.ai_form_visible or self.ai_history_source_visible;
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
        self.session_launcher_return_to_command_palette = false;
        self.startup_shortcuts_visible = false;
    }

    pub fn commandPaletteOpen(self: *State) void {
        self.commandPaletteOpenWithMode(.commands);
    }

    pub fn commandPaletteClose(self: *State) void {
        // Only flip visibility: filter/selection/mode are kept so the render
        // side can draw the fade-out frames with the last visible contents.
        // commandPaletteOpenWithMode fully resets them on the next open.
        self.command_palette_visible = false;
        self.session_launcher_return_to_command_palette = false;
    }

    pub fn commandPaletteOpenAgentHistory(self: *State) void {
        self.commandPaletteOpen();
        self.commandPaletteSetMode(.agent_history);
        self.session_launcher_visible = false;
        self.ssh_list_visible = false;
        self.ssh_form_visible = false;
        self.ai_list_visible = false;
        self.ai_form_visible = false;
        self.ai_history_source_visible = false;
        self.command_palette_history_source = .all;
        self.command_palette_history_selected = 0;
        self.command_palette_filter_len = 0;
    }

    pub fn commandPaletteLeaveAgentHistory(self: *State) void {
        self.commandPaletteSetMode(.commands);
    }

    pub fn commandPaletteCycleHistorySource(self: *State) void {
        self.command_palette_history_source = switch (self.command_palette_history_source) {
            .all => .sidebar,
            .sidebar => .tab,
            .tab => .all,
        };
        self.command_palette_history_selected = 0;
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
        self.ai_history_source_visible = false;
        self.command_palette_visible = false;
        self.session_launcher_return_to_command_palette = false;
        self.settings_visible = false;
        self.startup_shortcuts_visible = false;
    }

    pub fn sessionLauncherOpenFromCommandPalette(self: *State) void {
        self.sessionLauncherOpen();
        self.session_launcher_return_to_command_palette = true;
    }

    pub fn sessionLauncherClose(self: *State) void {
        self.session_launcher_visible = false;
        self.ssh_list_visible = false;
        self.ssh_form_visible = false;
        self.ai_list_visible = false;
        self.ai_form_visible = false;
        self.ai_history_source_visible = false;
        self.session_launcher_return_to_command_palette = false;
    }

    pub fn sessionLauncherBackToCommandPalette(self: *State) bool {
        if (!self.session_launcher_return_to_command_palette) return false;
        self.sessionLauncherClose();
        self.commandPaletteOpen();
        return true;
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

pub fn resolveNewAgentLaunch(has_profiles: bool) NewAgentLaunchAction {
    return if (has_profiles) .connect_default_profile_as_agent else .open_form;
}

fn expectCommandEntry(title: []const u8, action: CommandAction) !void {
    for (command_entries) |entry| {
        if (std.mem.eql(u8, entry.title, title)) {
            try std.testing.expectEqual(action, entry.action);
            return;
        }
    }
    return error.CommandEntryNotFound;
}

fn expectNoCommandEntry(title: []const u8) !void {
    for (command_entries) |entry| {
        if (std.mem.eql(u8, entry.title, title)) return error.UnexpectedCommandEntry;
    }
}

test "command center includes New Copilot action" {
    try expectCommandEntry("New Copilot", .new_agent);
}

test "command center exposes Toggle Copilot" {
    try expectCommandEntry("Toggle Copilot", .toggle_ai_copilot);
}

test "command center includes Manage AI Profiles action" {
    try expectCommandEntry("Manage AI Profiles", .manage_ai_profiles);
}

test "command center includes MCP Servers action" {
    try expectCommandEntry("MCP Servers", .manage_mcp_servers);
}

test "command center includes Copilot History action" {
    try expectCommandEntry("Copilot History", .select_agent_history);
}

test "command catalog no longer has a Load Copilot Conversation entry" {
    try expectNoCommandEntry("Load Copilot Conversation");
}

test "command center includes update check actions" {
    try expectCommandEntry("Check for Updates", .check_for_updates);
    try expectCommandEntry("Download Update", .download_update);
    try expectCommandEntry("Open Latest Release", .open_latest_release);
}

test "command center includes What's New action" {
    try expectCommandEntry("What's New", .show_whats_new);
}

test "command center includes Skill Center action" {
    try expectCommandEntry("Skill Center", .open_skill_center);
    for (command_entries) |entry| {
        if (entry.action == .open_skill_center) {
            try std.testing.expect(std.mem.indexOf(u8, entry.detail, "tools") != null or std.mem.indexOf(u8, entry.detail, "Tools") != null);
            return;
        }
    }
    return error.MissingSkillCenterCommand;
}

test "Skill Center is on the default first command center page" {
    const default_first_page_rows: usize = 14;
    for (command_entries, 0..) |entry, idx| {
        if (entry.action == .open_skill_center) {
            try std.testing.expect(idx < default_first_page_rows);
            return;
        }
    }
    return error.MissingSkillCenterCommand;
}

test "command center includes Port Forwarding action" {
    try expectCommandEntry("Port Forwarding", .open_port_forwarding);
}

test "command center includes Open Jupyter action" {
    try expectCommandEntry("Open Jupyter", .open_jupyter_panel);
}

test "command center includes Load OpenSSH Config action" {
    try expectCommandEntry("Load OpenSSH Config", .load_openssh_config);
}

test "Load OpenSSH Config is not on the default first command center page" {
    const default_first_page_rows: usize = 14;
    for (command_entries, 0..) |entry, idx| {
        if (entry.action == .load_openssh_config) {
            try std.testing.expect(idx >= default_first_page_rows);
            return;
        }
    }
    return error.MissingLoadOpenSshConfigCommand;
}

test "command center includes Copilot Markdown export actions" {
    try expectCommandEntry("Export Copilot Markdown", .export_ai_chat_markdown);
    try expectCommandEntry("Export Copilot Markdown Clean", .export_ai_chat_markdown_clean);
}

test "command center includes WeChat direct actions" {
    try expectCommandEntry("Connect WeChat", .connect_wechat);
    try expectCommandEntry("WeChat: Start", .start_wechat);
    try expectCommandEntry("WeChat: Stop", .stop_wechat);
    try expectCommandEntry("WeChat: Status", .wechat_status);
    try expectCommandEntry("WeChat: Unbind", .unbind_wechat);
}

test "command center includes Feishu direct actions" {
    try expectCommandEntry("Feishu: Configure", .configure_feishu);
}

test "command center includes quick configure AI" {
    try expectCommandEntry("Settings: Quick Configure AI", .quick_configure_ai);
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

test "command center exposes settings as a command" {
    for (command_entries) |entry| {
        if (entry.action == .open_settings) {
            try std.testing.expectEqualStrings("Settings", entry.title);
            return;
        }
    }
    return error.MissingSettingsCommand;
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

test "closing the command center keeps contents until the next open resets them" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();

    state.commandPaletteClose();

    try std.testing.expect(!state.command_palette_visible);
    // Mode/filter/selection survive close for fade-out rendering.
    try std.testing.expect(state.commandPaletteIsHistoryMode());
    state.commandPaletteOpen();
    try std.testing.expect(state.command_palette_visible);
    try std.testing.expect(!state.commandPaletteIsHistoryMode());
    try std.testing.expectEqual(@as(usize, 0), state.command_palette_selected);
    try std.testing.expectEqual(@as(usize, 0), state.command_palette_filter_len);
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

test "session launcher opened from command center escapes back to command list" {
    var state = State{};
    state.commandPaletteOpen();

    state.sessionLauncherOpenFromCommandPalette();
    try std.testing.expect(!state.command_palette_visible);
    try std.testing.expect(state.sessionLauncherVisible());
    try std.testing.expect(state.session_launcher_return_to_command_palette);

    try std.testing.expect(state.sessionLauncherBackToCommandPalette());
    try std.testing.expect(state.command_palette_visible);
    try std.testing.expect(!state.sessionLauncherVisible());
    try std.testing.expect(!state.session_launcher_return_to_command_palette);
}

test "standalone session launcher escape still closes" {
    var state = State{};
    state.sessionLauncherOpen();

    try std.testing.expect(!state.sessionLauncherBackToCommandPalette());
    state.sessionLauncherClose();

    try std.testing.expect(!state.command_palette_visible);
    try std.testing.expect(!state.sessionLauncherVisible());
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
    // Mode survives close so the fade-out can render the last contents; the
    // next open resets it.
    try std.testing.expect(state.commandPaletteIsHistoryMode());
    state.commandPaletteOpen();
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

test "command palette: history source cycles and resets on open" {
    var state = State{};
    state.commandPaletteOpenAgentHistory();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.all, state.command_palette_history_source);
    state.commandPaletteCycleHistorySource();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.sidebar, state.command_palette_history_source);
    state.commandPaletteCycleHistorySource();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.tab, state.command_palette_history_source);
    state.commandPaletteCycleHistorySource();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.all, state.command_palette_history_source);
    state.command_palette_history_source = .tab;
    state.command_palette_history_selected = 5;
    state.command_palette_filter_len = 3;
    state.commandPaletteOpenAgentHistory();
    try std.testing.expectEqual(command_palette_history_view.SourceFilter.all, state.command_palette_history_source);
    try std.testing.expectEqual(@as(usize, 0), state.command_palette_history_selected);
    try std.testing.expectEqual(@as(usize, 0), state.command_palette_filter_len);
}
