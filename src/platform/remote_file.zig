const std = @import("std");
const builtin = @import("builtin");
const pty_command = @import("pty_command.zig");
const platform_wsl = @import("wsl.zig");
const platform_process = @import("process.zig");
const process_runner = @import("../process_runner.zig");

const DEFAULT_CAPTURE_MAX_BYTES: usize = 4 * 1024 * 1024;
const SSH_STDERR_MAX_BYTES: usize = 16 * 1024;

fn exitedOk(term: process_runner.Termination) bool {
    return switch (term) {
        .exited => |code| code == 0,
        .killed => false,
    };
}

/// Run a POSIX-shell command on the LOCAL host (`sh -c <command>`) and capture
/// stdout, capped at `max_bytes`. On non-POSIX hosts (Windows native) there is
/// no POSIX shell, so this returns `error.Unreachable`. Centralizing the OS
/// switch here keeps AppWindow platform-neutral.
/// TODO: Windows-native local POSIX support (e.g. via WSL fallback).
pub fn localPosixExec(allocator: std.mem.Allocator, command: []const u8, max_bytes: usize) ![]u8 {
    if (builtin.os.tag == .windows) return error.Unreachable;
    const argv = [_][]const u8{ "sh", "-c", command };
    const result = try process_runner.runCapture(allocator, &argv, .{
        .max_stdout_bytes = max_bytes,
        .max_stderr_bytes = SSH_STDERR_MAX_BYTES,
    });
    allocator.free(result.stderr);
    return result.stdout;
}

/// True if the local host can run POSIX shell commands (false on Windows
/// native). Lets platform-neutral callers decide whether the "local" source is
/// reachable without touching `builtin.os.tag` themselves.
pub fn localPosixExecSupported() bool {
    return builtin.os.tag != .windows;
}

/// Run a POSIX-shell command on the LOCAL host and return whether it exited 0,
/// discarding stdout. Returns false on a non-POSIX host, spawn failure, or a
/// non-zero exit. Use this when only success/failure matters (e.g. a local
/// `tar` extract) — unlike `localPosixExec`, which returns stdout WITHOUT
/// checking the exit status and so would mask a failed command.
pub fn localPosixExecOk(allocator: std.mem.Allocator, command: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    const argv = [_][]const u8{ "sh", "-c", command };
    var result = process_runner.runCapture(allocator, &argv, .{
        .max_stdout_bytes = DEFAULT_CAPTURE_MAX_BYTES,
        .max_stderr_bytes = SSH_STDERR_MAX_BYTES,
    }) catch return false;
    defer result.deinit(allocator);
    return exitedOk(result.termination);
}

pub fn wslHomeCommand() []const u8 {
    return "printf %s \"$HOME\"";
}

/// Run a command inside the default WSL distro and capture stdout.
pub fn wslExec(allocator: std.mem.Allocator, command: []const u8) ?[]u8 {
    const argv = pty_command.wslExecArgv(command);
    var result = process_runner.runCapture(allocator, &argv, .{
        .max_stdout_bytes = DEFAULT_CAPTURE_MAX_BYTES,
        .max_stderr_bytes = SSH_STDERR_MAX_BYTES,
    }) catch return null;
    if (!exitedOk(result.termination)) {
        result.deinit(allocator);
        return null;
    }
    allocator.free(result.stderr);
    return result.stdout;
}

/// Result of an ssh exec: owned stdout + stderr, plus whether ssh exited 0.
pub const SshCapture = struct {
    stdout: []u8,
    stderr: []u8,
    exited_ok: bool,

    pub fn deinit(self: *SshCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

/// Like `sshExecCapture` but always returns stdout AND stderr (even on failure)
/// so callers can surface the real ssh error. Reads both pipes concurrently to
/// avoid a full-stderr-pipe deadlock.
pub fn sshExecCaptureFull(allocator: std.mem.Allocator, conn: anytype, command: []const u8) !SshCapture {
    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.usesPasswordAuth()) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return error.SpawnFailed;
        env_map = try std.process.getEnvMap(allocator);
        if (env_map) |*map| {
            try platform_process.putSshAskPassEnv(map, askpass_path.?, conn.password());
        }
    }

    var destination_buf: [272]u8 = undefined;
    const destination = std.fmt.bufPrint(destination_buf[0..], "{s}@{s}", .{ conn.user(), conn.host() }) catch return error.CommandTooLong;

    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = pty_command.sshExecutableName();
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "StrictHostKeyChecking=accept-new";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ConnectTimeout=8";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ServerAliveInterval=5";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ServerAliveCountMax=2";
    argc += 1;
    if (conn.usesPasswordAuth()) {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "PreferredAuthentications=publickey,password,keyboard-interactive";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "NumberOfPasswordPrompts=1";
        argc += 1;
    } else {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "BatchMode=yes";
        argc += 1;
    }
    if (conn.usesIdentityFile()) {
        argv_buf[argc] = "-i";
        argc += 1;
        argv_buf[argc] = conn.identityFile();
        argc += 1;
    }
    if (conn.legacy_algorithms) {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "HostkeyAlgorithms=+ssh-rsa,ssh-dss";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "Ciphers=+aes128-cbc,3des-cbc";
        argc += 1;
    }
    var proxy_buf: [272]u8 = undefined;
    if (conn.proxyJump().len > 0) {
        argv_buf[argc] = "-o";
        argc += 1;
        const proxy = std.fmt.bufPrint(proxy_buf[0..], "ProxyJump={s}", .{conn.proxyJump()}) catch return error.CommandTooLong;
        argv_buf[argc] = proxy;
        argc += 1;
    }
    if (conn.port().len > 0) {
        argv_buf[argc] = "-p";
        argc += 1;
        argv_buf[argc] = conn.port();
        argc += 1;
    }
    argv_buf[argc] = destination;
    argc += 1;
    argv_buf[argc] = command;
    argc += 1;

    const result = try process_runner.runCapture(allocator, argv_buf[0..argc], .{
        .env_map = if (env_map) |*map| map else null,
        .max_stdout_bytes = 2 * 1024 * 1024,
        .max_stderr_bytes = SSH_STDERR_MAX_BYTES,
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exited_ok = exitedOk(result.termination),
    };
}

pub fn sshExecCapture(allocator: std.mem.Allocator, conn: anytype, command: []const u8) ![]u8 {
    var cap = try sshExecCaptureFull(allocator, conn, command);
    if (!cap.exited_ok) {
        logSshFailure(cap.stderr);
        cap.deinit(allocator);
        return error.RemoteExecFailed;
    }
    allocator.free(cap.stderr);
    return cap.stdout; // ownership transferred to caller
}

pub fn wslPathExpr(buf: *[1024]u8, path: []const u8) ?[]const u8 {
    return shellPathExpr(buf, path);
}

pub fn shellPathExpr(buf: *[1024]u8, path: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (std.mem.eql(u8, path, "~")) {
        if (!appendLiteral(buf, &pos, "\"$HOME\"")) return null;
        return buf[0..pos];
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        if (!appendLiteral(buf, &pos, "\"$HOME\"/")) return null;
        if (!appendShellQuoted(buf, &pos, path[2..])) return null;
        return buf[0..pos];
    }
    if (!appendShellQuoted(buf, &pos, path)) return null;
    return buf[0..pos];
}

pub fn shellQuote(buf: *[1024]u8, arg: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendShellQuoted(buf, &pos, arg)) return null;
    return buf[0..pos];
}

pub fn localPathForTerminalPaste(
    allocator: std.mem.Allocator,
    launch_kind: pty_command.LaunchKind,
    local_path: []const u8,
) ?[]u8 {
    switch (launch_kind) {
        .wsl => if (platform_wsl.hostPathToGuestPathAlloc(allocator, local_path) catch null) |guest_path| return guest_path,
        .local, .ssh => {},
    }
    return allocator.dupe(u8, local_path) catch null;
}

fn appendLiteral(buf: *[1024]u8, pos: *usize, text: []const u8) bool {
    if (pos.* + text.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
    return true;
}

fn appendShellQuoted(buf: *[1024]u8, pos: *usize, arg: []const u8) bool {
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;

    for (arg) |ch| {
        if (ch == '\'') {
            const escaped = "'\\''";
            if (!appendLiteral(buf, pos, escaped)) return false;
        } else {
            if (pos.* >= buf.len) return false;
            buf[pos.*] = ch;
            pos.* += 1;
        }
    }

    if (pos.* >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;
    return true;
}

fn logSshFailure(stderr_output: ?[]const u8) void {
    if (stderr_output) |stderr| {
        const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
        if (trimmed.len > 0) {
            std.debug.print("SSH command failed: {s}\n", .{trimmed});
            return;
        }
    }
    std.debug.print("SSH command failed\n", .{});
}

test "platform remote file shell paths keep home expandable and quote literals" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("\"$HOME\"", shellPathExpr(&buf, "~").?);
    try std.testing.expectEqualStrings("\"$HOME\"/'README.md'", shellPathExpr(&buf, "~/README.md").?);
    try std.testing.expectEqualStrings("'/home/me/README.md'", shellPathExpr(&buf, "/home/me/README.md").?);
    try std.testing.expectEqualStrings("'/tmp/it'\\''s here'", shellQuote(&buf, "/tmp/it's here").?);
}

test "platform remote file exposes WSL command helpers" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("\"$HOME\"", wslPathExpr(&buf, "~").?);
    try std.testing.expectEqualStrings("printf %s \"$HOME\"", wslHomeCommand());

    const exec_info = @typeInfo(@TypeOf(wslExec)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), exec_info.params.len);
    try std.testing.expect(exec_info.params[0].type.? == std.mem.Allocator);
    try std.testing.expect(exec_info.params[1].type.? == []const u8);
    try std.testing.expect(exec_info.return_type.? == ?[]u8);
}

test "platform remote file adapts local paste paths by terminal launch kind" {
    const allocator = std.testing.allocator;

    const wsl_path = localPathForTerminalPaste(allocator, .wsl, "C:\\Users\\me\\image.png").?;
    defer allocator.free(wsl_path);
    try std.testing.expectEqualStrings("/mnt/c/Users/me/image.png", wsl_path);

    const local_path = localPathForTerminalPaste(allocator, .local, "C:\\Users\\me\\image.png").?;
    defer allocator.free(local_path);
    try std.testing.expectEqualStrings("C:\\Users\\me\\image.png", local_path);
}
