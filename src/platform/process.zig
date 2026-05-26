const std = @import("std");
const builtin = @import("builtin");
const platform_dirs = @import("dirs.zig");
const shared = @import("process_shared.zig");

pub const Backend = enum {
    windows,
    posix,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .posix,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("process_windows.zig"),
    .posix => @import("process_posix.zig"),
};

pub const DetachedSpawnOptions = shared.DetachedSpawnOptions;

const LocalShell = enum {
    posix_shell,
    pwsh,
    legacy_powershell,
    command_prompt,
};

pub const LocalShellArgv = struct {
    argv: [4][]const u8,
    len: usize,

    pub fn slice(self: *const LocalShellArgv) []const []const u8 {
        return self.argv[0..self.len];
    }
};

fn localShellCommandArgvForOs(os_tag: std.Target.Os.Tag, shell: LocalShell, command: []const u8) LocalShellArgv {
    return switch (shell) {
        .posix_shell => .{ .argv = .{ "sh", "-lc", command, "" }, .len = 3 },
        .pwsh => .{ .argv = .{ if (os_tag == .windows) "pwsh.exe" else "pwsh", "-NoProfile", "-Command", command }, .len = 4 },
        .legacy_powershell => .{ .argv = .{ if (os_tag == .windows) "powershell.exe" else "powershell", "-NoProfile", "-Command", command }, .len = 4 },
        .command_prompt => .{ .argv = .{ "cmd.exe", "/C", command, "" }, .len = 3 },
    };
}

fn localShellFallbackForOs(os_tag: std.Target.Os.Tag, index: usize) ?LocalShell {
    return switch (os_tag) {
        .windows => switch (index) {
            0 => .pwsh,
            1 => .legacy_powershell,
            2 => .command_prompt,
            else => null,
        },
        else => switch (index) {
            0 => .posix_shell,
            else => null,
        },
    };
}

pub fn localShellFallbackCommandArgv(index: usize, command: []const u8) ?LocalShellArgv {
    return localShellFallbackCommandArgvForOs(builtin.os.tag, index, command);
}

pub fn localShellFallbackCommandArgvForOs(os_tag: std.Target.Os.Tag, index: usize, command: []const u8) ?LocalShellArgv {
    const shell = localShellFallbackForOs(os_tag, index) orelse return null;
    return localShellCommandArgvForOs(os_tag, shell, command);
}

pub fn localCommandToolName() []const u8 {
    return localCommandToolNameForOs(builtin.os.tag);
}

pub fn localCommandToolNameForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) "powershell_exec" else "shell_exec";
}

pub fn localCommandToolDescription() []const u8 {
    return localCommandToolDescriptionForOs(builtin.os.tag);
}

pub fn localCommandToolDescriptionForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "Run a local PowerShell command on Windows and return stdout, stderr, and exit status."
    else
        "Run a local POSIX shell command and return stdout, stderr, and exit status.";
}

pub fn localCommandApprovalLabel() []const u8 {
    return localCommandApprovalLabelForOs(builtin.os.tag);
}

pub fn localCommandApprovalLabelForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) "Run local PowerShell command" else "Run local shell command";
}

pub fn localCommandDeniedReason() []const u8 {
    return localCommandDeniedReasonForOs(builtin.os.tag);
}

pub fn localCommandDeniedReasonForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) "operator rejected local PowerShell command" else "operator rejected local shell command";
}

pub fn localCommandFailureLabel() []const u8 {
    return localCommandFailureLabelForOs(builtin.os.tag);
}

pub fn localCommandFailureLabelForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) "PowerShell" else "shell";
}

pub const WaitForPidDiagnostic = shared.WaitForPidDiagnostic;

pub fn currentProcessId() u32 {
    return impl.currentProcessId();
}

pub fn waitForPid(pid: u32, timeout_ms: u32, diagnostic: ?*WaitForPidDiagnostic) !void {
    return impl.waitForPid(pid, timeout_ms, diagnostic);
}

test "platform process exposes current process id" {
    try std.testing.expectEqual(u32, @typeInfo(@TypeOf(currentProcessId)).@"fn".return_type.?);
}

pub fn childExited(id: std.process.Child.Id, timeout_ms: u32) bool {
    return impl.childExited(id, timeout_ms);
}

pub fn terminateChild(id: std.process.Child.Id) void {
    impl.terminateChild(id);
}

pub const PipeWriteError = shared.PipeWriteError;

pub fn writeAllToPipe(file: std.fs.File, data: []const u8) PipeWriteError!void {
    return impl.writeAllToPipe(file, data);
}

pub fn sshAskPassScriptBodyForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "@echo off\r\n" ++
            "powershell.exe -NoLogo -NoProfile -Command \"[Console]::Out.Write($env:PHANTTY_SSH_PASSWORD)\"\r\n",
        else => "#!/bin/sh\n" ++
            "printf %s \"$PHANTTY_SSH_PASSWORD\"\n",
    };
}

pub fn sshAskPassScriptPath(allocator: std.mem.Allocator) ?[]const u8 {
    const temp = platform_dirs.tempDir(allocator) catch return null;
    defer allocator.free(temp);
    return sshAskPassScriptPathFromTempDirForOs(allocator, builtin.os.tag, temp) catch null;
}

pub fn sshAskPassScriptPathFromTempDirForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    temp_dir: []const u8,
) ![]const u8 {
    const basename = switch (os_tag) {
        .windows => "phantty-ssh-askpass.cmd",
        else => "phantty-ssh-askpass.sh",
    };
    return std.fs.path.join(allocator, &.{ temp_dir, basename });
}

pub fn ensureSshAskPassScript(allocator: std.mem.Allocator) ?[]const u8 {
    const path = sshAskPassScriptPath(allocator) orelse return null;
    errdefer allocator.free(path);

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return null;
    defer file.close();

    file.writeAll(sshAskPassScriptBodyForOs(builtin.os.tag)) catch return null;
    return path;
}

test "platform process exposes wait-by-pid diagnostics API" {
    const diagnostic: WaitForPidDiagnostic = .{ .operation = "none", .code = 0 };

    try std.testing.expectEqualStrings("none", diagnostic.operation);
    try std.testing.expectEqual(@as(u32, 0), diagnostic.code);
    try std.testing.expectEqual(@as(?u32, null), diagnostic.wait_result);
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(@TypeOf(waitForPid)).@"fn".params.len);
}

pub fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    return spawnDetachedWithOptions(allocator, .{ .argv = argv });
}

pub fn spawnDetachedWithOptions(allocator: std.mem.Allocator, options: DetachedSpawnOptions) !void {
    return impl.spawnDetachedWithOptions(allocator, options);
}

test "platform process exposes typed detached spawn options" {
    const options = DetachedSpawnOptions{
        .argv = &.{ "phantty.exe", "--detached" },
        .cwd = "C:/Phantty",
        .create_no_window = true,
    };

    try std.testing.expectEqualStrings("phantty.exe", options.argv[0]);
    try std.testing.expectEqualStrings("C:/Phantty", options.cwd.?);
    try std.testing.expect(options.create_no_window);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(spawnDetachedWithOptions)).@"fn".params.len);
}

test "platform process wait exposes a child exit poll API" {
    const ChildId = std.process.Child.Id;
    try std.testing.expect(@typeInfo(@TypeOf(childExited)).@"fn".params[0].type.? == ChildId);
    try std.testing.expect(@typeInfo(@TypeOf(childExited)).@"fn".params[1].type.? == u32);
    try std.testing.expect(@typeInfo(@TypeOf(childExited)).@"fn".return_type.? == bool);
}

test "platform process exposes SSH askpass script helpers" {
    const script = sshAskPassScriptBodyForOs(.windows);
    try std.testing.expect(std.mem.indexOf(u8, script, "PHANTTY_SSH_PASSWORD") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "powershell.exe") != null);

    const path = try sshAskPassScriptPathFromTempDirForOs(std.testing.allocator, .windows, "C:/Temp");
    defer std.testing.allocator.free(path);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ "C:/Temp", "phantty-ssh-askpass.cmd" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "platform process owns child termination and pipe writes" {
    const ChildId = std.process.Child.Id;
    try std.testing.expect(@typeInfo(@TypeOf(terminateChild)).@"fn".params[0].type.? == ChildId);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(writeAllToPipe)).@"fn".params.len);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("pipe-write.txt", .{ .read = true });
    defer file.close();

    try writeAllToPipe(file, "abc");
    try file.seekTo(0);

    var buf: [3]u8 = undefined;
    const read_len = try file.readAll(&buf);
    try std.testing.expectEqual(@as(usize, 3), read_len);
    try std.testing.expectEqualStrings("abc", &buf);
}

test "platform process builds local shell command argv fallbacks" {
    const command = "Get-Location";

    const pwsh = localShellCommandArgvForOs(.windows, .pwsh, command);
    try std.testing.expectEqual(@as(usize, 4), pwsh.slice().len);
    try std.testing.expectEqualStrings("pwsh.exe", pwsh.slice()[0]);
    try std.testing.expectEqualStrings("-NoProfile", pwsh.slice()[1]);
    try std.testing.expectEqualStrings("-Command", pwsh.slice()[2]);
    try std.testing.expectEqualStrings(command, pwsh.slice()[3]);

    const legacy = localShellCommandArgvForOs(.windows, .legacy_powershell, command);
    try std.testing.expectEqual(@as(usize, 4), legacy.slice().len);
    try std.testing.expectEqualStrings("powershell.exe", legacy.slice()[0]);
    try std.testing.expectEqualStrings("-NoProfile", legacy.slice()[1]);
    try std.testing.expectEqualStrings("-Command", legacy.slice()[2]);
    try std.testing.expectEqualStrings(command, legacy.slice()[3]);

    const prompt = localShellCommandArgvForOs(.windows, .command_prompt, command);
    try std.testing.expectEqual(@as(usize, 3), prompt.slice().len);
    try std.testing.expectEqualStrings("cmd.exe", prompt.slice()[0]);
    try std.testing.expectEqualStrings("/C", prompt.slice()[1]);
    try std.testing.expectEqualStrings(command, prompt.slice()[2]);

    const shell = localShellCommandArgvForOs(.linux, .posix_shell, "pwd");
    try std.testing.expectEqual(@as(usize, 3), shell.slice().len);
    try std.testing.expectEqualStrings("sh", shell.slice()[0]);
    try std.testing.expectEqualStrings("-lc", shell.slice()[1]);
    try std.testing.expectEqualStrings("pwd", shell.slice()[2]);
}

test "platform process selects local command tools and shell fallbacks by target OS" {
    try std.testing.expectEqualStrings("powershell_exec", localCommandToolNameForOs(.windows));
    try std.testing.expectEqualStrings("shell_exec", localCommandToolNameForOs(.linux));
    try std.testing.expectEqual(LocalShell.pwsh, localShellFallbackForOs(.windows, 0).?);
    try std.testing.expectEqual(LocalShell.legacy_powershell, localShellFallbackForOs(.windows, 1).?);
    try std.testing.expectEqual(LocalShell.posix_shell, localShellFallbackForOs(.linux, 0).?);

    const posix = localShellFallbackCommandArgvForOs(.linux, 0, "pwd").?;
    try std.testing.expectEqual(@as(usize, 3), posix.slice().len);
    try std.testing.expectEqualStrings("sh", posix.slice()[0]);
    try std.testing.expectEqualStrings("-lc", posix.slice()[1]);
    try std.testing.expectEqualStrings("pwd", posix.slice()[2]);

    const cmd = localShellFallbackCommandArgvForOs(.windows, 2, "echo ok").?;
    try std.testing.expectEqual(@as(usize, 3), cmd.slice().len);
    try std.testing.expectEqualStrings("cmd.exe", cmd.slice()[0]);
    try std.testing.expectEqualStrings("/C", cmd.slice()[1]);
    try std.testing.expectEqualStrings("echo ok", cmd.slice()[2]);

    try std.testing.expectEqual(@as(?LocalShellArgv, null), localShellFallbackCommandArgvForOs(.windows, 3, "echo ok"));
}

test "platform process exposes detached spawn API" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(spawnDetached)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(spawnDetached)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(spawnDetached)).@"fn".params[1].type.? == []const []const u8);
}

test "platform process selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.posix, backendForOs(.linux));
    try std.testing.expectEqual(Backend.posix, backendForOs(.macos));
}
