pub const DetachedSpawnOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    create_no_window: bool = false,
};

pub const WaitForPidDiagnostic = struct {
    operation: []const u8,
    code: u32,
    wait_result: ?u32 = null,
};

pub const PipeWriteError = error{ BrokenPipe, WriteFailed };

const std = @import("std");
const builtin = @import("builtin");

pub const WaitResult = union(enum) {
    /// Child reaped via a normal exit: `code` is the exit status.
    reaped: u32,
    /// Child reaped, but not via a normal exit (killed by a signal, etc.).
    reaped_unknown,
    /// `WNOHANG`: the child is still running.
    still_running,
    /// No such child (already reaped, or never ours) — treat as done.
    no_child,
};

pub const WNOHANG: u32 = 1;

/// Result of polling a child for exit (used by ai_chat's local-command tool).
pub const ChildExit = union(enum) {
    /// Still running when the poll timeout elapsed.
    running,
    /// Exited; `code` is the exit status. On POSIX the zombie has been reaped
    /// by this call, so callers must NOT waitpid() it again (set Child.term to
    /// take std's cleanup-only fast path instead).
    exited: u32,
    /// No such child / reaped by a signal — treat as finished, code unknown.
    gone,
};

/// Non-blocking-or-blocking child reap that works WITHOUT libc on Linux (raw
/// `wait4` syscall) and via libc `waitpid` elsewhere. This matters because the
/// fast native test build does not link libc, yet pulls in the POSIX process
/// helpers transitively.
pub fn reapChild(pid: i32, options: u32) WaitResult {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var status: u32 = 0;
        const rc = linux.syscall4(
            .wait4,
            @as(usize, @bitCast(@as(isize, pid))),
            @intFromPtr(&status),
            options,
            0,
        );
        const signed: isize = @bitCast(rc);
        if (signed < 0) return .no_child; // ECHILD / ESRCH / EINVAL
        if (signed == 0) return .still_running;
        if (linux.W.IFEXITED(status)) return .{ .reaped = linux.W.EXITSTATUS(status) };
        return .reaped_unknown;
    } else {
        var status: c_int = 0;
        const r = std.c.waitpid(pid, &status, @intCast(options));
        if (r < 0) return .no_child;
        if (r == 0) return .still_running;
        if ((status & 0x7f) == 0) return .{ .reaped = @intCast((status & 0xff00) >> 8) };
        return .reaped_unknown;
    }
}
