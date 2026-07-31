//! Skill transfer runner: copy a skill from one endpoint to another via a
//! temp-file tar dance over injected primitives. The library side is always
//! local; at most one of from/to is remote.
//!
//! The three operations are injected so this stays platform-neutral and
//! unit-testable:
//!   - localExec(cmd): run a POSIX command locally, return ok
//!   - remoteExec(cmd): run a POSIX command on the server, return ok
//!   - copy(dir, local_path, remote_path): scp the temp tarball
const std = @import("std");
const cmd = @import("transfer_cmd.zig");

pub const Result = enum { ok, failed };
pub const CopyDir = enum { to_remote, to_local };

pub const Endpoint = struct {
    root_expr: []const u8, // shell root expression on its host
    is_local: bool, // true → localExec; false → remoteExec + scp
};

pub const Ops = struct {
    ctx: *anyopaque,
    /// Run `command` locally; return true on success.
    localExec: *const fn (*anyopaque, std.mem.Allocator, []const u8) bool,
    /// Run `command` on the server; return true on success.
    remoteExec: *const fn (*anyopaque, std.mem.Allocator, []const u8) bool,
    /// Copy the tarball. dir = .to_remote: local_tmp → remote_tmp; .to_local: remote_tmp → local_tmp.
    copy: *const fn (*anyopaque, std.mem.Allocator, CopyDir, []const u8, []const u8) bool,
};

// Staging tarball path. Same string on purpose — it names a file on two
// *different* filesystems (the local host and the remote server), so the values
// being equal is incidental, not a copy-paste bug. Fixed paths are fine: each
// transfer truncates the tarball, and a failed transfer leaves at most this one
// stale temp (in /tmp) which the next run overwrites.
const LOCAL_TMP = "/tmp/.wispterm-skill.tgz";
const REMOTE_TMP = "/tmp/.wispterm-skill.tgz";

/// Copy skill `name` from `from` to `to`. The library side is always local;
/// at most one of from/to is remote. .ok only if every step succeeds.
pub fn transfer(allocator: std.mem.Allocator, ops: Ops, from: Endpoint, to: Endpoint, name: []const u8) Result {
    const src_tmp = if (from.is_local) LOCAL_TMP else REMOTE_TMP;
    const make = cmd.tarCreateCmd(allocator, from.root_expr, name, src_tmp) catch return .failed;
    defer allocator.free(make);
    const make_ok = if (from.is_local) ops.localExec(ops.ctx, allocator, make) else ops.remoteExec(ops.ctx, allocator, make);
    if (!make_ok) return .failed;

    const dst_tmp = if (to.is_local) LOCAL_TMP else REMOTE_TMP;
    if (from.is_local != to.is_local) {
        const copy_ok = if (to.is_local)
            ops.copy(ops.ctx, allocator, .to_local, LOCAL_TMP, REMOTE_TMP)
        else
            ops.copy(ops.ctx, allocator, .to_remote, LOCAL_TMP, REMOTE_TMP);
        if (!copy_ok) return .failed;
    }

    const extract = cmd.tarExtractCmd(allocator, to.root_expr, name, dst_tmp) catch return .failed;
    defer allocator.free(extract);
    const extract_ok = if (to.is_local) ops.localExec(ops.ctx, allocator, extract) else ops.remoteExec(ops.ctx, allocator, extract);
    if (!extract_ok) return .failed;

    _ = ops.localExec(ops.ctx, allocator, "rm -f '" ++ LOCAL_TMP ++ "'");
    if (!from.is_local or !to.is_local) _ = ops.remoteExec(ops.ctx, allocator, "rm -f '" ++ REMOTE_TMP ++ "'");
    return .ok;
}

// --- Tests ---

const Recorder = struct {
    local_cmds: std.ArrayListUnmanaged([]u8) = .empty,
    remote_cmds: std.ArrayListUnmanaged([]u8) = .empty,
    copies: usize = 0,
    fail_copy: bool = false,
    allocator: std.mem.Allocator,

    fn deinit(self: *Recorder) void {
        for (self.local_cmds.items) |c| self.allocator.free(c);
        for (self.remote_cmds.items) |c| self.allocator.free(c);
        self.local_cmds.deinit(self.allocator);
        self.remote_cmds.deinit(self.allocator);
    }
    fn localExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.local_cmds.append(allocator, allocator.dupe(u8, command) catch return false) catch return false;
        return true;
    }
    fn remoteExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.remote_cmds.append(allocator, allocator.dupe(u8, command) catch return false) catch return false;
        return true;
    }
    fn copy(ctx: *anyopaque, _: std.mem.Allocator, _: CopyDir, _: []const u8, _: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.fail_copy) return false;
        self.copies += 1;
        return true;
    }
    fn ops(self: *Recorder) Ops {
        return .{ .ctx = self, .localExec = localExec, .remoteExec = remoteExec, .copy = copy };
    }
};

test "skill_transfer: local→local deploy does tar+extract, no copy" {
    const a = std.testing.allocator;
    var rec = Recorder{ .allocator = a };
    defer rec.deinit();
    const from = Endpoint{ .root_expr = "'/cfg/skills'", .is_local = true };
    const to = Endpoint{ .root_expr = "\"$HOME\"/'.claude/skills'", .is_local = true };
    try std.testing.expectEqual(Result.ok, transfer(a, rec.ops(), from, to, "pdf"));
    try std.testing.expectEqual(@as(usize, 0), rec.copies);
    try std.testing.expect(std.mem.startsWith(u8, rec.local_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.local_cmds.items[1], "tar -xzf") != null);
}

test "skill_transfer: local→remote deploy does create-local, copy, extract-remote" {
    const a = std.testing.allocator;
    var rec = Recorder{ .allocator = a };
    defer rec.deinit();
    const from = Endpoint{ .root_expr = "'/cfg/skills'", .is_local = true };
    const to = Endpoint{ .root_expr = "\"$HOME\"/'.codex/skills'", .is_local = false };
    try std.testing.expectEqual(Result.ok, transfer(a, rec.ops(), from, to, "pdf"));
    try std.testing.expectEqual(@as(usize, 1), rec.copies);
    try std.testing.expect(std.mem.startsWith(u8, rec.local_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.remote_cmds.items[0], "tar -xzf") != null);
}

test "skill_transfer: remote→remote (WSL) tars and extracts without a host copy" {
    // The WSL deploy path treats BOTH endpoints as remote (reachable from one
    // `wsl.exe` shell): the library under /mnt/<drive> and the target under
    // $HOME. With from.is_local == to.is_local, transfer must skip the copy
    // primitive entirely and run tar-create + extract over remoteExec.
    const a = std.testing.allocator;
    var rec = Recorder{ .allocator = a };
    defer rec.deinit();
    const from = Endpoint{ .root_expr = "'/mnt/c/lib/skills'", .is_local = false };
    const to = Endpoint{ .root_expr = "\"$HOME\"/'.claude/skills'", .is_local = false };
    try std.testing.expectEqual(Result.ok, transfer(a, rec.ops(), from, to, "pdf"));
    try std.testing.expectEqual(@as(usize, 0), rec.copies);
    try std.testing.expect(std.mem.startsWith(u8, rec.remote_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.remote_cmds.items[1], "tar -xzf") != null);
    // The staged tarball is cleaned up on the remote (WSL /tmp).
    try std.testing.expect(std.mem.indexOf(u8, rec.remote_cmds.items[2], "rm -f") != null);
}

test "skill_transfer: remote→local import does create-remote, copy, extract-local" {
    const a = std.testing.allocator;
    var rec = Recorder{ .allocator = a };
    defer rec.deinit();
    const from = Endpoint{ .root_expr = "\"$HOME\"/'.claude/skills'", .is_local = false };
    const to = Endpoint{ .root_expr = "'/cfg/skills'", .is_local = true };
    try std.testing.expectEqual(Result.ok, transfer(a, rec.ops(), from, to, "pdf"));
    try std.testing.expectEqual(@as(usize, 1), rec.copies);
    try std.testing.expect(std.mem.startsWith(u8, rec.remote_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.local_cmds.items[0], "tar -xzf") != null);
}
