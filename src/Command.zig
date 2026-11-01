//! App-facing PTY command wrapper.
//!
//! The OS-specific launch implementation lives in `platform/pty_command.zig`.
//! This keeps Surface-level terminal logic from owning platform process
//! lifecycle details.

const platform_command = @import("platform/pty_command.zig");
const Pty = @import("pty.zig").Pty;
const std = @import("std");

const Command = @This();

pub const Exit = platform_command.Command.Exit;

impl: platform_command.Command = .{},

pub fn start(self: *Command, pty: *Pty, command: platform_command.CommandLine, cwd: platform_command.Cwd, advertise_terminal_capabilities: bool) !void {
    return pty.startCommand(&self.impl, command, cwd, advertise_terminal_capabilities);
}

pub fn wait(self: *Command, block: bool) !?Exit {
    return self.impl.wait(block);
}

/// After PTY EOF/EIO the child is usually already a zombie, but a single
/// WNOHANG can lose that race and leave a defunct pid under the emulator.
/// Retry until reaped or `timeout_ms` elapses. Does not block forever so a
/// process that closed the slave and kept running cannot hang the reader.
pub fn waitUntilReaped(self: *Command, timeout_ms: u64) ?Exit {
    return self.impl.waitUntilReaped(timeout_ms);
}

pub fn deinit(self: *Command) void {
    self.impl.deinit();
}

/// Best-effort termination of the child process (ACP `terminal/kill`). Does
/// not reap — the IO reader/writer threads observe EOF/broken-pipe and call
/// `Surface.markExited` as usual.
pub fn kill(self: *Command) void {
    self.impl.kill();
}

/// PID usable for an OS cwd query (proc_pidinfo / /proc), or null.
pub fn cwdQueryId(self: *const Command) ?i32 {
    return self.impl.cwdQueryId();
}

test "Command delegates lifecycle API to platform implementation" {
    const start_info = @typeInfo(@TypeOf(start)).@"fn";
    try std.testing.expectEqual(@as(usize, 5), start_info.params.len);
    try std.testing.expect(start_info.params[1].type.? == *Pty);
    try std.testing.expect(start_info.params[2].type.? == platform_command.CommandLine);
    try std.testing.expect(start_info.params[3].type.? == platform_command.Cwd);
    try std.testing.expect(start_info.params[4].type.? == bool);

    const wait_info = @typeInfo(@TypeOf(wait)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), wait_info.params.len);
    try std.testing.expect(wait_info.params[0].type.? == *Command);

    const reap_info = @typeInfo(@TypeOf(waitUntilReaped)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), reap_info.params.len);
    try std.testing.expect(reap_info.params[0].type.? == *Command);

    const deinit_info = @typeInfo(@TypeOf(deinit)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), deinit_info.params.len);
    try std.testing.expect(deinit_info.params[0].type.? == *Command);
}
