const std = @import("std");
const builtin = @import("builtin");
const process_shared = @import("process_shared.zig");
const ssh_connection = @import("../ssh/connection.zig");

pub const CommandLineBuffer = [256]u8;
pub const CwdBuffer = [260]u8;
pub const CwdUnit = u8;
pub const CwdSlice = []const CwdUnit;
pub const CommandLine = [:0]const u8;
pub const Cwd = ?[*:0]const u8;
pub const OwnedCommandLine = [:0]u8;
pub const OwnedCwd = [:0]u8;

/// Coarse launch context used by platform-neutral terminal integrations.
pub const LaunchKind = enum {
    local,
    wsl,
    ssh,
};

pub const SshCommandOptions = struct {
    user: []const u8,
    host: []const u8,
    port: []const u8 = "",
    auth_method: ssh_connection.SshAuthMethod = .credentials,
    identity_file: []const u8 = "",
    password_auth: bool = false,
    legacy_algorithms: bool = false,
    proxy_jump: []const u8 = "",
    remote_command: []const u8 = "",
};

pub fn resolveShellCommandLine(out_buf: *CommandLineBuffer, cmd: []const u8) usize {
    const len = @min(cmd.len, out_buf.len - 1);
    @memcpy(out_buf[0..len], cmd[0..len]);
    out_buf[len] = 0;
    return len;
}

pub fn allocCommandLineFromUtf8(allocator: std.mem.Allocator, command: []const u8) !OwnedCommandLine {
    return allocator.dupeZ(u8, command);
}

pub fn freeCommandLine(allocator: std.mem.Allocator, command: OwnedCommandLine) void {
    allocator.free(command);
}

pub fn commandLineFromOwned(command: OwnedCommandLine) CommandLine {
    return command;
}

pub fn commandLineDisplay(command: CommandLine, out: []u8) []const u8 {
    const len = @min(command.len, out.len);
    @memcpy(out[0..len], command[0..len]);
    return out[0..len];
}

pub fn allocCwdFromUtf8(allocator: std.mem.Allocator, cwd: []const u8) !OwnedCwd {
    return allocator.dupeZ(u8, cwd);
}

pub fn freeCwd(allocator: std.mem.Allocator, cwd: OwnedCwd) void {
    allocator.free(cwd);
}

pub fn cwdFromOwned(cwd: OwnedCwd) Cwd {
    return cwd.ptr;
}

pub fn cwdFromBuffer(cwd_buf: *CwdBuffer, len: usize) Cwd {
    if (len >= cwd_buf.len) return null;
    cwd_buf[len] = 0;
    return @ptrCast(cwd_buf);
}

pub fn cwdFromUtf8(cwd_buf: *CwdBuffer, cwd: []const u8) Cwd {
    const len = @min(cwd.len, cwd_buf.len - 1);
    @memcpy(cwd_buf[0..len], cwd[0..len]);
    return cwdFromBuffer(cwd_buf, len);
}

pub const Command = struct {
    pub const Exit = union(enum) {
        exited: u32,
        unknown,
    };

    /// Child PID populated by the POSIX `Pty.startCommand`. `-1` means "no
    /// child" (not yet spawned, or already reaped).
    pid: std.c.pid_t = -1,

    pub fn wait(self: *const Command, block: bool) !?Exit {
        if (self.pid <= 0) return null;
        // POSIX-only: guarded so this file still compiles under a Windows
        // target build (it is selected only for non-windows hosts).
        if (builtin.os.tag == .windows) return null;

        const options: u32 = if (block) 0 else process_shared.WNOHANG;
        switch (process_shared.reapChild(self.pid, options)) {
            .still_running => return null,
            .no_child => return null,
            .reaped => |code| return Exit{ .exited = code },
            .reaped_unknown => return .unknown,
        }
    }

    pub fn deinit(self: *Command) void {
        // Best-effort non-blocking reap so we don't leak a zombie.
        if (self.pid > 0 and builtin.os.tag != .windows) {
            _ = process_shared.reapChild(self.pid, process_shared.WNOHANG);
            self.pid = -1;
        }
    }

    /// PID usable for an OS cwd query (proc_pidinfo / /proc), or null.
    pub fn cwdQueryId(self: *const Command) ?i32 {
        return if (self.pid > 0) @intCast(self.pid) else null;
    }
};

pub fn cwdToUtf8(out: []u8, cwd: Cwd) ?[]u8 {
    const ptr = cwd orelse return null;
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    if (len > out.len) return null;
    @memcpy(out[0..len], ptr[0..len]);
    return out[0..len];
}

pub fn friendlyShellTitle(title: []const u8) []const u8 {
    return title;
}

pub fn shellCommandLooksLikeConfiguredLocalShell(shell_cmd: CommandLine) bool {
    _ = shell_cmd;
    return false;
}

pub fn configuredLocalShellCommandForShell(shell_cmd: CommandLine) []const u8 {
    _ = shell_cmd;
    return switch (builtin.os.tag) {
        .macos => "zsh",
        else => "sh",
    };
}

/// Always-present shell to fall back to when the preferred local shell cannot
/// be launched (issue #65). Uses absolute paths guaranteed by POSIX.
pub fn guaranteedLocalShellCommand() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "/bin/zsh",
        else => "/bin/sh",
    };
}

pub fn tabCommandForKind(kind: []const u8, current_shell: CommandLine) ![]const u8 {
    _ = kind;
    _ = current_shell;
    return error.InvalidTabKind;
}

pub fn wslAvailable() bool {
    return false;
}

pub fn wslInteractiveCommand(buf: []u8, cwd: ?[]const u8) ?[]const u8 {
    _ = buf;
    _ = cwd;
    return null;
}

pub fn wslShellCommand(buf: []u8, command: []const u8) ?[]const u8 {
    _ = buf;
    _ = command;
    return null;
}

pub fn wslExecArgv(command: []const u8) [5][]const u8 {
    return .{ "sh", "-lc", command, "", "" };
}

fn appendAscii(buf: []u8, pos: *usize, text: []const u8) bool {
    if (pos.* + text.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
    return true;
}

/// Escape `value` for a POSIX single-quoted context WITHOUT writing the
/// surrounding quotes, so callers can splice an unquoted literal (e.g. an env
/// prefix) into the same quoted run.
fn appendPosixSingleQuotedInner(buf: []u8, pos: *usize, value: []const u8) bool {
    for (value) |ch| {
        if (ch == '\'') {
            if (!appendAscii(buf, pos, "'\\''")) return false;
        } else {
            if (pos.* >= buf.len) return false;
            buf[pos.*] = ch;
            pos.* += 1;
        }
    }
    return true;
}

fn appendPosixSingleQuotedArg(buf: []u8, pos: *usize, value: []const u8) bool {
    if (!appendAscii(buf, pos, "'")) return false;
    if (!appendPosixSingleQuotedInner(buf, pos, value)) return false;
    return appendAscii(buf, pos, "'");
}

pub fn localShellInitialCommand(buf: []u8, current_shell: CommandLine, command: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendAscii(buf, &pos, configuredLocalShellCommandForShell(current_shell))) return null;
    if (!appendAscii(buf, &pos, " -lic ")) return null;
    if (!appendPosixSingleQuotedArg(buf, &pos, command)) return null;
    return buf[0..pos];
}

pub fn sshLauncherDetail() []const u8 {
    return "ssh";
}

pub fn wslLauncherDetail() []const u8 {
    return "shell";
}

pub fn sshExecutableName() []const u8 {
    return "ssh";
}

pub fn scpExecutableName() []const u8 {
    return "scp";
}

pub fn sshInteractiveCommand(buf: []u8, options: SshCommandOptions) ?[]const u8 {
    return buildSshCommandLine(buf, options, true);
}

pub fn sshControlCommand(buf: []u8, options: SshCommandOptions) ?[]const u8 {
    // tmux -CC control mode: leave the remote command byte-for-byte so nothing
    // perturbs the control-protocol handshake (no env injection here).
    return buildSshCommandLine(buf, options, false);
}

/// Prepended to an interactive SSH remote command so the remote shell exports a
/// TERM_PROGRAM that TUIs recognize as Kitty-keyboard-capable (#302).
const ssh_remote_env_prefix = "export TERM_PROGRAM=ghostty; ";

fn buildSshCommandLine(buf: []u8, options: SshCommandOptions, export_term_program: bool) ?[]const u8 {
    var pos: usize = 0;
    if (!appendAscii(buf, &pos, "ssh -tt ")) return null;
    if (options.proxy_jump.len > 0) {
        if (!appendAscii(buf, &pos, "-o ProxyJump=")) return null;
        if (!appendAscii(buf, &pos, options.proxy_jump)) return null;
        if (!appendAscii(buf, &pos, " ")) return null;
    }
    const auth_method: ssh_connection.SshAuthMethod = if (options.password_auth) .password else options.auth_method;
    if (auth_method == .key and options.identity_file.len > 0) {
        if (!appendAscii(buf, &pos, "-i ")) return null;
        if (!appendPosixSingleQuotedArg(buf, &pos, options.identity_file)) return null;
        if (!appendAscii(buf, &pos, " ")) return null;
    }
    if (options.port.len > 0) {
        if (!appendAscii(buf, &pos, "-p ")) return null;
        if (!appendAscii(buf, &pos, options.port)) return null;
        if (!appendAscii(buf, &pos, " ")) return null;
    }
    if (!appendAscii(buf, &pos, options.user)) return null;
    if (!appendAscii(buf, &pos, "@")) return null;
    if (!appendAscii(buf, &pos, options.host)) return null;
    if (options.remote_command.len > 0) {
        if (!appendAscii(buf, &pos, " ")) return null;
        if (export_term_program) {
            // Export TERM_PROGRAM on the remote so full-screen TUIs (Claude Code,
            // Codex) enable the Kitty keyboard protocol there too — otherwise
            // Shift+Enter can't be told from Enter. ssh forwards TERM but not
            // TERM_PROGRAM (it's not in the default SendEnv/AcceptEnv set), so we
            // bake it into the remote command rather than relying on -o SetEnv,
            // which the remote sshd would silently drop. Spliced inside the single
            // quotes since the prefix itself is quote-free. See pty_posix.zig.
            if (!appendAscii(buf, &pos, "'" ++ ssh_remote_env_prefix)) return null;
            if (!appendPosixSingleQuotedInner(buf, &pos, options.remote_command)) return null;
            if (!appendAscii(buf, &pos, "'")) return null;
        } else {
            if (!appendPosixSingleQuotedArg(buf, &pos, options.remote_command)) return null;
        }
    }
    return buf[0..pos];
}

pub fn launchKindForCommand(command: CommandLine) LaunchKind {
    if (std.mem.startsWith(u8, command, "ssh ")) return .ssh;
    return .local;
}

test "unsupported backend builds SSH interactive command lines with ProxyJump" {
    var buf: [512]u8 = undefined;

    // No jump host keeps the existing bare invocation shape.
    try std.testing.expectEqualStrings(
        "ssh -tt user@example.test",
        sshInteractiveCommand(&buf, .{ .user = "user", .host = "example.test" }).?,
    );

    // ProxyJump is inserted before the destination, after any port flag.
    try std.testing.expectEqualStrings(
        "ssh -tt -o ProxyJump=admin@jump.test user@example.test",
        sshInteractiveCommand(&buf, .{
            .user = "user",
            .host = "example.test",
            .proxy_jump = "admin@jump.test",
        }).?,
    );

    try std.testing.expectEqualStrings(
        "ssh -tt -o ProxyJump=admin@jump.test:2200 -p 2222 user@example.test",
        sshInteractiveCommand(&buf, .{
            .user = "user",
            .host = "example.test",
            .port = "2222",
            .proxy_jump = "admin@jump.test:2200",
        }).?,
    );
}

test "unsupported backend exports TERM_PROGRAM into the SSH remote command (#302)" {
    var buf: [512]u8 = undefined;

    // A remote command gains the env prefix so the remote Claude Code/Codex sees
    // a Kitty-capable TERM_PROGRAM (ssh doesn't forward the local one). The
    // original command stays intact inside the same single-quoted argument.
    try std.testing.expectEqualStrings(
        "ssh -tt user@example.test 'export TERM_PROGRAM=ghostty; cd '\\''/srv/p'\\'' && claude'",
        sshInteractiveCommand(&buf, .{
            .user = "user",
            .host = "example.test",
            .remote_command = "cd '/srv/p' && claude",
        }).?,
    );

    // No remote command (plain interactive login shell) is left untouched.
    try std.testing.expectEqualStrings(
        "ssh -tt user@example.test",
        sshInteractiveCommand(&buf, .{ .user = "user", .host = "example.test" }).?,
    );
}

test "unsupported backend uses UTF-8 native command and cwd storage" {
    try std.testing.expect(@typeInfo(CommandLineBuffer).array.child == u8);
    try std.testing.expect(@typeInfo(CwdBuffer).array.child == u8);
    try std.testing.expect(CommandLine == [:0]const u8);
    try std.testing.expect(OwnedCommandLine == [:0]u8);
    try std.testing.expect(OwnedCwd == [:0]u8);

    var command_buf: CommandLineBuffer = undefined;
    const command_len = resolveShellCommandLine(&command_buf, "sh");
    try std.testing.expectEqualStrings("sh", command_buf[0..command_len]);

    const command = try allocCommandLineFromUtf8(std.testing.allocator, "sh -lc true");
    defer freeCommandLine(std.testing.allocator, command);
    try std.testing.expectEqualStrings("sh -lc true", commandLineFromOwned(command));

    const cwd = try allocCwdFromUtf8(std.testing.allocator, "/tmp");
    defer freeCwd(std.testing.allocator, cwd);
    var utf8: [32]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp", cwdToUtf8(&utf8, cwdFromOwned(cwd)).?);
}
