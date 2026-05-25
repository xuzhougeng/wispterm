const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .unsupported,
    };
}

pub fn backend() Backend {
    return backendForOs(builtin.os.tag);
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("pty_command_windows.zig"),
    .unsupported => @import("pty_command_unsupported.zig"),
};

pub const CommandLineBuffer = impl.CommandLineBuffer;
pub const CwdBuffer = impl.CwdBuffer;
pub const CwdUnit = impl.CwdUnit;
pub const CwdSlice = impl.CwdSlice;
pub const CommandLine = impl.CommandLine;
pub const Cwd = impl.Cwd;
pub const OwnedCommandLine = impl.OwnedCommandLine;
pub const OwnedCwd = impl.OwnedCwd;
pub const Command = impl.Command;
pub const LaunchKind = impl.LaunchKind;

pub fn allocCommandLineFromUtf8(allocator: std.mem.Allocator, command: []const u8) !OwnedCommandLine {
    return impl.allocCommandLineFromUtf8(allocator, command);
}

pub fn freeCommandLine(allocator: std.mem.Allocator, command: OwnedCommandLine) void {
    impl.freeCommandLine(allocator, command);
}

pub fn commandLineFromOwned(command: OwnedCommandLine) CommandLine {
    return impl.commandLineFromOwned(command);
}

pub fn allocCwdFromUtf8(allocator: std.mem.Allocator, cwd: []const u8) !OwnedCwd {
    return impl.allocCwdFromUtf8(allocator, cwd);
}

pub fn freeCwd(allocator: std.mem.Allocator, cwd: OwnedCwd) void {
    impl.freeCwd(allocator, cwd);
}

pub fn cwdFromOwned(cwd: OwnedCwd) Cwd {
    return impl.cwdFromOwned(cwd);
}

pub fn cwdFromBuffer(cwd_buf: *CwdBuffer, len: usize) Cwd {
    return impl.cwdFromBuffer(cwd_buf, len);
}

pub fn cwdFromUtf8(cwd_buf: *CwdBuffer, cwd: []const u8) Cwd {
    return impl.cwdFromUtf8(cwd_buf, cwd);
}

pub fn resolveShellCommandLine(out_buf: *CommandLineBuffer, cmd: []const u8) usize {
    return impl.resolveShellCommandLine(out_buf, cmd);
}

pub fn localShellLauncherTitle() []const u8 {
    return local_shell_launcher_title;
}

pub const local_shell_launcher_title = localShellLauncherTitleForOs(builtin.os.tag);

pub fn localShellLauncherTitleForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "PowerShell",
        .unsupported => "Shell",
    };
}

pub fn shellCommandLooksLikeConfiguredLocalShell(shell_cmd: CommandLine) bool {
    return impl.shellCommandLooksLikeConfiguredLocalShell(shell_cmd);
}

pub fn configuredLocalShellCommandForShell(shell_cmd: CommandLine) []const u8 {
    return impl.configuredLocalShellCommandForShell(shell_cmd);
}

pub fn sessionLauncherDetail() []const u8 {
    return session_launcher_detail;
}

pub const session_launcher_detail = sessionLauncherDetailForOs(builtin.os.tag);

pub fn sessionLauncherDetailForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "Choose PowerShell, SSH, WSL, or AI Agent",
        .unsupported => "Choose Shell, SSH, or AI Agent",
    };
}

pub fn sessionLauncherRowCount() usize {
    return session_launcher_row_count;
}

pub const session_launcher_row_count = sessionLauncherRowCountForOs(builtin.os.tag);

pub fn sessionLauncherRowCountForOs(os_tag: std.Target.Os.Tag) usize {
    return switch (backendForOs(os_tag)) {
        .windows => 4,
        .unsupported => 3,
    };
}

pub fn sessionLauncherAiAgentRow() usize {
    return session_launcher_ai_agent_row;
}

pub const session_launcher_ai_agent_row = sessionLauncherAiAgentRowForOs(builtin.os.tag);

pub fn sessionLauncherAiAgentRowForOs(os_tag: std.Target.Os.Tag) usize {
    return switch (backendForOs(os_tag)) {
        .windows => 3,
        .unsupported => 2,
    };
}

pub fn sessionLauncherWslRow() ?usize {
    return sessionLauncherWslRowForOs(builtin.os.tag);
}

pub fn sessionLauncherWslRowForOs(os_tag: std.Target.Os.Tag) ?usize {
    return switch (backendForOs(os_tag)) {
        .windows => 2,
        .unsupported => null,
    };
}

pub fn wslSessionToolsEnabled() bool {
    return wslSessionToolsEnabledForOs(builtin.os.tag);
}

pub fn wslSessionToolsEnabledForOs(os_tag: std.Target.Os.Tag) bool {
    return backendForOs(os_tag) == .windows;
}

pub fn terminalSelectToolDescription() []const u8 {
    return terminalSelectToolDescriptionForOs(builtin.os.tag);
}

pub fn terminalSelectToolDescriptionForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "Select the terminal surface context for subsequent write tools. Call this before ssh_session_exec, wsl_session_exec, or terminal_repl_exec, and call it again when switching to another panel/tab.",
        .unsupported => "Select the terminal surface context for subsequent write tools. Call this before ssh_session_exec or terminal_repl_exec, and call it again when switching to another panel/tab.",
    };
}

pub fn wslSessionToolName() []const u8 {
    return "wsl_session_exec";
}

pub fn wslSessionToolDescription() []const u8 {
    return "Run a POSIX shell command in the selected already-open WSL terminal surface. The surface_id must match the current terminal_select context. Use only when the surface is at a shell prompt; for R, Python, Codex, Claude Code, or other REPLs use terminal_repl_exec.";
}

pub fn wslSessionToolPropertiesJson() []const u8 {
    return "{\"surface_id\":{\"type\":\"string\",\"description\":\"Selected surface id from terminal_select.\"},\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}";
}

pub fn defaultShellName() []const u8 {
    return default_shell_name;
}

pub const default_shell_name = defaultShellNameForOs(builtin.os.tag);

pub fn defaultShellNameForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "cmd",
        .unsupported => "sh",
    };
}

pub fn shellSettingChoicesHint() []const u8 {
    return shell_setting_choices_hint;
}

pub const shell_setting_choices_hint = shellSettingChoicesHintForOs(builtin.os.tag);

pub fn shellSettingChoicesHintForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "cmd / powershell / pwsh / wsl",
        .unsupported => "sh / zsh / fish",
    };
}

pub fn shellSettingComment() []const u8 {
    return shell_setting_comment;
}

pub const shell_setting_comment = shellSettingCommentForOs(builtin.os.tag);

pub fn shellSettingCommentForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "# Shell (cmd, powershell, pwsh, wsl, or a custom path)",
        .unsupported => "# Shell (sh, zsh, fish, or a custom path)",
    };
}

pub fn defaultShellAssignmentComment() []const u8 {
    return default_shell_assignment_comment;
}

pub const default_shell_assignment_comment = defaultShellAssignmentCommentForOs(builtin.os.tag);

pub fn defaultShellAssignmentCommentForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "# shell = cmd",
        .unsupported => "# shell = sh",
    };
}

pub fn nextConfigShell(shell: []const u8) []const u8 {
    return nextConfigShellForOs(builtin.os.tag, shell);
}

pub fn nextConfigShellForOs(os_tag: std.Target.Os.Tag, shell: []const u8) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => {
            if (std.mem.eql(u8, shell, "cmd")) return "powershell";
            if (std.mem.eql(u8, shell, "powershell")) return "pwsh";
            if (std.mem.eql(u8, shell, "pwsh")) return "wsl";
            return "cmd";
        },
        .unsupported => {
            if (std.mem.eql(u8, shell, "sh")) return "zsh";
            if (std.mem.eql(u8, shell, "zsh")) return "fish";
            return "sh";
        },
    };
}

pub fn configProfileExamplePath() []const u8 {
    return config_profile_example_path;
}

pub const config_profile_example_path = configProfileExamplePathForOs(builtin.os.tag);

pub fn configProfileExamplePathForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "profiles\\powershell.conf",
        .unsupported => "profiles/shell.conf",
    };
}

pub fn configReloadTestInitialShell() []const u8 {
    return config_reload_test_initial_shell;
}

pub const config_reload_test_initial_shell = configReloadTestInitialShellForOs(builtin.os.tag);

pub fn configReloadTestInitialShellForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "powershell",
        .unsupported => "zsh",
    };
}

pub fn configReloadTestNextShell() []const u8 {
    return config_reload_test_next_shell;
}

pub const config_reload_test_next_shell = configReloadTestNextShellForOs(builtin.os.tag);

pub fn configReloadTestNextShellForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "pwsh",
        .unsupported => "fish",
    };
}

pub fn tabNewToolDescription() []const u8 {
    return tabNewToolDescriptionForOs(builtin.os.tag);
}

pub fn tabNewToolDescriptionForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "Create a new local terminal tab. Use kind=default, powershell, pwsh, cmd, wsl, or command with an explicit command line.",
        .unsupported => "Create a new local terminal tab. Use kind=default or command with an explicit command line.",
    };
}

pub fn tabNewToolPropertiesJson() []const u8 {
    return tabNewToolPropertiesJsonForOs(builtin.os.tag);
}

pub fn tabNewToolPropertiesJsonForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "{\"kind\":{\"type\":\"string\",\"description\":\"default, powershell, pwsh, cmd, wsl, or command.\"},\"command\":{\"type\":\"string\",\"description\":\"Optional explicit Windows command line; used when kind is command or to override kind.\"}}",
        .unsupported => "{\"kind\":{\"type\":\"string\",\"description\":\"default or command.\"},\"command\":{\"type\":\"string\",\"description\":\"Optional explicit shell command line; used when kind is command or to override kind.\"}}",
    };
}

pub fn tabKindUsage() []const u8 {
    return tabKindUsageForOs(builtin.os.tag);
}

pub fn tabKindUsageForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (backendForOs(os_tag)) {
        .windows => "default, powershell, pwsh, cmd, wsl, or command",
        .unsupported => "default or command",
    };
}

pub fn tabCommandForKind(kind_raw: []const u8, command_raw: ?[]const u8, current_shell: CommandLine) !?[]const u8 {
    if (command_raw) |command| {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }

    const kind = std.mem.trim(u8, kind_raw, " \t\r\n");
    if (kind.len == 0 or std.ascii.eqlIgnoreCase(kind, "default")) return null;
    if (std.ascii.eqlIgnoreCase(kind, "command") or std.ascii.eqlIgnoreCase(kind, "custom")) return error.CommandRequired;

    return try impl.tabCommandForKind(kind, current_shell);
}

pub fn wslInteractiveCommand(buf: []u8, cwd: ?[]const u8) ?[]const u8 {
    return impl.wslInteractiveCommand(buf, cwd);
}

pub fn wslExecArgv(command: []const u8) [5][]const u8 {
    return impl.wslExecArgv(command);
}

pub fn sshLauncherDetail() []const u8 {
    return impl.sshLauncherDetail();
}

pub fn wslLauncherDetail() []const u8 {
    return impl.wslLauncherDetail();
}

pub fn sshExecutableName() []const u8 {
    return impl.sshExecutableName();
}

pub fn scpExecutableName() []const u8 {
    return impl.scpExecutableName();
}

pub const SshCommandOptions = impl.SshCommandOptions;

pub fn sshInteractiveCommand(buf: []u8, options: SshCommandOptions) ?[]const u8 {
    return impl.sshInteractiveCommand(buf, options);
}

pub fn launchKindForCommand(command: CommandLine) LaunchKind {
    return impl.launchKindForCommand(command);
}

pub fn cwdToUtf8(out: []u8, cwd: Cwd) ?[]u8 {
    return impl.cwdToUtf8(out, cwd);
}

pub fn friendlyShellTitle(title: []const u8) []const u8 {
    return impl.friendlyShellTitle(title);
}

fn nativeCommandSliceToUtf8(out: []u8, command: anytype) ![]const u8 {
    const Slice = @TypeOf(command);
    const Unit = @typeInfo(Slice).pointer.child;
    if (Unit == u8) {
        if (command.len > out.len) return error.NoSpaceLeft;
        @memcpy(out[0..command.len], command);
        return out[0..command.len];
    }
    if (Unit == u16) {
        const len = try std.unicode.utf16LeToUtf8(out, command);
        return out[0..len];
    }
    @compileError("unsupported native command line code unit");
}

test "platform pty command exposes command lifecycle API" {
    try std.testing.expect(@hasDecl(@This(), "Command"));

    const CommandType = @This().Command;
    try std.testing.expect(@hasDecl(CommandType, "Exit"));
    try std.testing.expect(!@hasDecl(CommandType, "start"));

    const wait_info = @typeInfo(@TypeOf(CommandType.wait)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), wait_info.params.len);
    try std.testing.expect(wait_info.params[0].type.? == *const CommandType);
    try std.testing.expect(wait_info.params[1].type.? == bool);

    const deinit_info = @typeInfo(@TypeOf(CommandType.deinit)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), deinit_info.params.len);
    try std.testing.expect(deinit_info.params[0].type.? == *CommandType);
}

test "platform pty command resolves shell aliases to native command lines" {
    var out: CommandLineBuffer = undefined;
    var utf8: [256]u8 = undefined;

    const cmd_len = resolveShellCommandLine(&out, "cmd");
    const cmd_utf8 = try nativeCommandSliceToUtf8(&utf8, out[0..cmd_len]);
    const expected_cmd = switch (backendForOs(builtin.os.tag)) {
        .windows => "cmd.exe",
        .unsupported => "cmd",
    };
    try std.testing.expectEqualStrings(expected_cmd, cmd_utf8);

    const powershell_len = resolveShellCommandLine(&out, "powershell");
    const powershell_utf8 = try nativeCommandSliceToUtf8(&utf8, out[0..powershell_len]);
    const expected_powershell = switch (backendForOs(builtin.os.tag)) {
        .windows => "powershell.exe",
        .unsupported => "powershell",
    };
    try std.testing.expectEqualStrings(expected_powershell, powershell_utf8);

    const custom_len = resolveShellCommandLine(&out, "custom-shell --flag");
    const custom_utf8 = try nativeCommandSliceToUtf8(&utf8, out[0..custom_len]);
    try std.testing.expectEqualStrings("custom-shell --flag", custom_utf8);
}

test "platform pty command owns UTF-8 launch string conversion behind facade" {
    const allocator = std.testing.allocator;

    const command = try allocCommandLineFromUtf8(allocator, "cmd.exe");
    defer freeCommandLine(allocator, command);
    try std.testing.expectEqual(LaunchKind.local, launchKindForCommand(commandLineFromOwned(command)));

    const cwd = try allocCwdFromUtf8(allocator, "C:\\Temp");
    defer freeCwd(allocator, cwd);

    var utf8: [64]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\Temp", cwdToUtf8(&utf8, cwdFromOwned(cwd)).?);
}

test "platform pty command copies UTF-8 cwd into native cwd buffers" {
    var cwd_buf: CwdBuffer = undefined;
    const cwd = cwdFromUtf8(&cwd_buf, "/tmp/project") orelse return error.ExpectedCwd;

    var utf8: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/project", cwdToUtf8(&utf8, cwd).?);
}

test "platform pty command detects configured local shell flavor" {
    const allocator = std.testing.allocator;

    const powershell = try allocCommandLineFromUtf8(allocator, "powershell.exe");
    defer freeCommandLine(allocator, powershell);
    const powershell_line = commandLineFromOwned(powershell);
    try std.testing.expect(shellCommandLooksLikeConfiguredLocalShell(powershell_line));
    try std.testing.expectEqualStrings("powershell.exe", configuredLocalShellCommandForShell(powershell_line));

    const quoted_pwsh = try allocCommandLineFromUtf8(allocator, "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo");
    defer freeCommandLine(allocator, quoted_pwsh);
    const quoted_pwsh_line = commandLineFromOwned(quoted_pwsh);
    try std.testing.expect(shellCommandLooksLikeConfiguredLocalShell(quoted_pwsh_line));
    try std.testing.expectEqualStrings("pwsh.exe", configuredLocalShellCommandForShell(quoted_pwsh_line));

    const unquoted_pwsh = try allocCommandLineFromUtf8(allocator, "C:\\Program Files\\PowerShell\\7\\pwsh.exe -NoLogo");
    defer freeCommandLine(allocator, unquoted_pwsh);
    const unquoted_pwsh_line = commandLineFromOwned(unquoted_pwsh);
    try std.testing.expect(shellCommandLooksLikeConfiguredLocalShell(unquoted_pwsh_line));
    try std.testing.expectEqualStrings("pwsh.exe", configuredLocalShellCommandForShell(unquoted_pwsh_line));

    const cmd = try allocCommandLineFromUtf8(allocator, "cmd.exe");
    defer freeCommandLine(allocator, cmd);
    const cmd_line = commandLineFromOwned(cmd);
    try std.testing.expect(!shellCommandLooksLikeConfiguredLocalShell(cmd_line));
    try std.testing.expectEqualStrings("powershell.exe", configuredLocalShellCommandForShell(cmd_line));
}

test "platform pty command maps tab kinds to native command lines" {
    const current_shell_owned = try allocCommandLineFromUtf8(std.testing.allocator, "pwsh.exe");
    defer freeCommandLine(std.testing.allocator, current_shell_owned);
    const current_shell = commandLineFromOwned(current_shell_owned);

    try std.testing.expectEqual(@as(?[]const u8, null), try tabCommandForKind("default", null, current_shell));
    try std.testing.expectEqualStrings("custom.exe --flag", (try tabCommandForKind("default", " custom.exe --flag \r\n", current_shell)).?);
    try std.testing.expectError(error.CommandRequired, tabCommandForKind("command", null, current_shell));
    switch (backendForOs(builtin.os.tag)) {
        .windows => {
            try std.testing.expect((try tabCommandForKind("powershell", null, current_shell)) != null);
            try std.testing.expect((try tabCommandForKind("pwsh", null, current_shell)) != null);
            try std.testing.expect((try tabCommandForKind("cmd", null, current_shell)) != null);
            try std.testing.expect((try tabCommandForKind("wsl", null, current_shell)) != null);
        },
        .unsupported => {
            try std.testing.expectError(error.InvalidTabKind, tabCommandForKind("powershell", null, current_shell));
            try std.testing.expectError(error.InvalidTabKind, tabCommandForKind("pwsh", null, current_shell));
            try std.testing.expectError(error.InvalidTabKind, tabCommandForKind("cmd", null, current_shell));
            try std.testing.expectError(error.InvalidTabKind, tabCommandForKind("wsl", null, current_shell));
        },
    }
    try std.testing.expectError(error.InvalidTabKind, tabCommandForKind("unknown", null, current_shell));
}

test "platform pty command exposes tab_new tool text by target OS" {
    try std.testing.expect(std.mem.indexOf(u8, tabNewToolDescriptionForOs(.windows), "powershell") != null);
    try std.testing.expect(std.mem.indexOf(u8, tabNewToolPropertiesJsonForOs(.windows), "Optional explicit Windows command line") != null);
    try std.testing.expect(std.mem.indexOf(u8, tabKindUsageForOs(.windows), "wsl") != null);

    try std.testing.expect(std.mem.indexOf(u8, tabNewToolDescriptionForOs(.linux), "default or command") != null);
    try std.testing.expect(std.mem.indexOf(u8, tabNewToolDescriptionForOs(.linux), "powershell") == null);
    try std.testing.expect(std.mem.indexOf(u8, tabNewToolPropertiesJsonForOs(.linux), "Windows") == null);
    try std.testing.expect(std.mem.indexOf(u8, tabKindUsageForOs(.macos), "default or command") != null);
    try std.testing.expect(std.mem.indexOf(u8, tabKindUsageForOs(.macos), "cmd") == null);
}

test "platform pty command exposes configured local shell launcher by target OS" {
    try std.testing.expectEqualStrings("PowerShell", localShellLauncherTitleForOs(.windows));
    try std.testing.expectEqualStrings("Shell", localShellLauncherTitleForOs(.linux));
    try std.testing.expectEqualStrings("Shell", localShellLauncherTitleForOs(.macos));

    const current_shell_owned = try allocCommandLineFromUtf8(std.testing.allocator, "pwsh.exe");
    defer freeCommandLine(std.testing.allocator, current_shell_owned);
    const current_shell = commandLineFromOwned(current_shell_owned);

    switch (backendForOs(builtin.os.tag)) {
        .windows => {
            try std.testing.expect(shellCommandLooksLikeConfiguredLocalShell(current_shell));
            try std.testing.expectEqualStrings("pwsh.exe", configuredLocalShellCommandForShell(current_shell));
        },
        .unsupported => {
            try std.testing.expect(!shellCommandLooksLikeConfiguredLocalShell(current_shell));
            try std.testing.expectEqualStrings("sh", configuredLocalShellCommandForShell(current_shell));
        },
    }
}

test "platform pty command exposes shell config defaults by target OS" {
    try std.testing.expectEqualStrings("cmd", defaultShellNameForOs(.windows));
    try std.testing.expectEqualStrings("sh", defaultShellNameForOs(.linux));
    try std.testing.expectEqualStrings("sh", defaultShellNameForOs(.macos));

    try std.testing.expect(std.mem.indexOf(u8, shellSettingChoicesHintForOs(.windows), "powershell") != null);
    try std.testing.expect(std.mem.indexOf(u8, shellSettingChoicesHintForOs(.linux), "powershell") == null);
    try std.testing.expect(std.mem.indexOf(u8, shellSettingCommentForOs(.macos), "custom path") != null);

    try std.testing.expectEqualStrings("powershell", nextConfigShellForOs(.windows, "cmd"));
    try std.testing.expectEqualStrings("pwsh", nextConfigShellForOs(.windows, "powershell"));
    try std.testing.expectEqualStrings("wsl", nextConfigShellForOs(.windows, "pwsh"));
    try std.testing.expectEqualStrings("cmd", nextConfigShellForOs(.windows, "wsl"));
    try std.testing.expectEqualStrings("zsh", nextConfigShellForOs(.linux, "sh"));
    try std.testing.expectEqualStrings("fish", nextConfigShellForOs(.linux, "zsh"));
    try std.testing.expectEqualStrings("sh", nextConfigShellForOs(.linux, "fish"));

    try std.testing.expectEqualStrings("profiles\\powershell.conf", configProfileExamplePathForOs(.windows));
    try std.testing.expectEqualStrings("profiles/shell.conf", configProfileExamplePathForOs(.linux));
    try std.testing.expectEqualStrings("powershell", configReloadTestInitialShellForOs(.windows));
    try std.testing.expectEqualStrings("zsh", configReloadTestInitialShellForOs(.linux));
    try std.testing.expectEqualStrings("pwsh", configReloadTestNextShellForOs(.windows));
    try std.testing.expectEqualStrings("fish", configReloadTestNextShellForOs(.linux));
}

test "platform pty command delegates launch context classification to backend" {
    const allocator = std.testing.allocator;

    const local = try allocCommandLineFromUtf8(allocator, "editor --wait");
    defer freeCommandLine(allocator, local);
    try std.testing.expectEqual(LaunchKind.local, launchKindForCommand(commandLineFromOwned(local)));
}

test "platform pty command maps native shell titles to friendly display labels" {
    try std.testing.expectEqualStrings("nvim", friendlyShellTitle("nvim"));
}

test "platform pty command exposes session launcher layout by target OS" {
    try std.testing.expectEqual(@as(usize, 4), sessionLauncherRowCountForOs(.windows));
    try std.testing.expectEqual(@as(usize, 3), sessionLauncherRowCountForOs(.linux));
    try std.testing.expectEqual(@as(usize, 3), sessionLauncherRowCountForOs(.macos));

    try std.testing.expectEqual(@as(usize, 3), sessionLauncherAiAgentRowForOs(.windows));
    try std.testing.expectEqual(@as(usize, 2), sessionLauncherAiAgentRowForOs(.linux));
    try std.testing.expectEqual(@as(?usize, 2), sessionLauncherWslRowForOs(.windows));
    try std.testing.expectEqual(@as(?usize, null), sessionLauncherWslRowForOs(.linux));

    try std.testing.expect(std.mem.indexOf(u8, sessionLauncherDetailForOs(.windows), "WSL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sessionLauncherDetailForOs(.linux), "WSL") == null);
    try std.testing.expect(std.mem.indexOf(u8, sessionLauncherDetailForOs(.macos), "Shell") != null);

    try std.testing.expect(wslSessionToolsEnabledForOs(.windows));
    try std.testing.expect(!wslSessionToolsEnabledForOs(.linux));
    try std.testing.expect(std.mem.indexOf(u8, terminalSelectToolDescriptionForOs(.windows), wslSessionToolName()) != null);
    try std.testing.expect(std.mem.indexOf(u8, terminalSelectToolDescriptionForOs(.linux), wslSessionToolName()) == null);
}

test "platform pty command exposes OpenSSH helper executable names" {
    try std.testing.expect(sshExecutableName().len > 0);
    try std.testing.expect(scpExecutableName().len > 0);
}

test "platform pty command selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
