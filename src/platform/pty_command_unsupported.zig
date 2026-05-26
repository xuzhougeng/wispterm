const std = @import("std");
const builtin = @import("builtin");
const process_shared = @import("process_shared.zig");

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
    password_auth: bool = false,
    legacy_algorithms: bool = false,
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
    return "sh";
}

pub fn tabCommandForKind(kind: []const u8, current_shell: CommandLine) ![]const u8 {
    _ = kind;
    _ = current_shell;
    return error.InvalidTabKind;
}

pub fn wslInteractiveCommand(buf: []u8, cwd: ?[]const u8) ?[]const u8 {
    _ = buf;
    _ = cwd;
    return null;
}

pub fn wslExecArgv(command: []const u8) [5][]const u8 {
    return .{ "sh", "-lc", command, "", "" };
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
    return if (options.port.len > 0)
        std.fmt.bufPrint(buf, "ssh -tt -p {s} {s}@{s}", .{ options.port, options.user, options.host }) catch null
    else
        std.fmt.bufPrint(buf, "ssh -tt {s}@{s}", .{ options.user, options.host }) catch null;
}

pub fn launchKindForCommand(command: CommandLine) LaunchKind {
    if (std.mem.startsWith(u8, command, "ssh ")) return .ssh;
    return .local;
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
