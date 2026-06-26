//! Platform seam for terminating a spawned child. PHASE 1 owns only the
//! *direct* child: kill it and let the caller reap it. Killing the whole
//! process *tree* (grandchildren that inherited the stdout fd, daemonized
//! helpers, etc.) is a documented phase-2 TODO — see `kill_tree` in
//! process_runner.RunOptions.
//!
//! POSIX: a child can be placed in its own process group at spawn time
//! (`setpgid`) and the whole group killed with `killpg`. PHASE 1 does NOT set
//! a new group on the child (std.process.Child gives no pre-exec hook without
//! reaching into the raw fork path), so `killChild` falls back to a direct
//! `kill(pid, SIGTERM)` and `killChildHard` to `SIGKILL`. The group-kill
//! primitives (`killGroup`) are provided so phase 2 can wire setpgid + killpg
//! once the spawn path grows a hook.
//!
//! Windows: a Job Object would let a phase-2 implementation kill the whole
//! tree atomically. PHASE 1 does a direct `TerminateProcess` on the child
//! handle.

const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum { posix, windows };

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .posix,
    };
}

/// Politely ask the direct child to terminate (POSIX SIGTERM / Windows
/// TerminateProcess). Best-effort: never fails, never blocks. The child must
/// still be reaped by the caller afterwards.
pub fn killChild(id: std.process.Child.Id) void {
    switch (builtin.os.tag) {
        .windows => std.os.windows.TerminateProcess(id, 1) catch {},
        else => std.posix.kill(id, std.posix.SIG.TERM) catch {},
    }
}

/// Forcibly terminate the direct child (POSIX SIGKILL / Windows
/// TerminateProcess). Used as the escalation after `killChild` when a child
/// ignores SIGTERM. Best-effort. The child must still be reaped afterwards.
pub fn killChildHard(id: std.process.Child.Id) void {
    switch (builtin.os.tag) {
        .windows => std.os.windows.TerminateProcess(id, 1) catch {},
        else => std.posix.kill(id, std.posix.SIG.KILL) catch {},
    }
}

/// PHASE 2 seam: kill an entire POSIX process group (negative pid → killpg
/// semantics). No-op on Windows (a Job Object is the right tool there). This
/// is only correct once the child has actually been placed in its own group
/// via `setpgid` at spawn time, which phase 1 does not yet do.
pub fn killGroup(pgid: std.process.Child.Id, hard: bool) void {
    if (builtin.os.tag == .windows) return;
    const sig = if (hard) std.posix.SIG.KILL else std.posix.SIG.TERM;
    // killpg(pgid, sig): send to every process in the group.
    std.posix.kill(-pgid, sig) catch {};
}

test "process_group backend selection by OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.posix, backendForOs(.linux));
    try std.testing.expectEqual(Backend.posix, backendForOs(.macos));
}

test "process_group exposes direct-child and group kill seams" {
    const ChildId = std.process.Child.Id;
    try std.testing.expect(@typeInfo(@TypeOf(killChild)).@"fn".params[0].type.? == ChildId);
    try std.testing.expect(@typeInfo(@TypeOf(killChildHard)).@"fn".params[0].type.? == ChildId);
    try std.testing.expect(@typeInfo(@TypeOf(killGroup)).@"fn".params[0].type.? == ChildId);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(killGroup)).@"fn".params.len);
}
