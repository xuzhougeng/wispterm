//! Skill transfer runner: upload (local hub -> server) and download
//! (server -> local hub) of one skill, via a temp-file tar dance over existing
//! primitives. The three operations are injected so this stays platform-neutral
//! and unit-testable:
//!   - localExec(cmd): run a POSIX command locally, return ok
//!   - remoteExec(cmd): run a POSIX command on the server, return ok
//!   - copy(direction, local_path, remote_path): scp the temp tarball
const std = @import("std");
const cmd = @import("skill_transfer_cmd.zig");

pub const Result = enum { ok, failed };
pub const Direction = enum { upload, download };

pub const Ops = struct {
    ctx: *anyopaque,
    /// Run `command` locally; return true on success.
    localExec: *const fn (*anyopaque, std.mem.Allocator, []const u8) bool,
    /// Run `command` on the server; return true on success.
    remoteExec: *const fn (*anyopaque, std.mem.Allocator, []const u8) bool,
    /// Copy the tarball. `dir == .upload`: local_tmp -> remote_tmp.
    /// `dir == .download`: remote_tmp -> local_tmp. Return true on success.
    copy: *const fn (*anyopaque, std.mem.Allocator, Direction, []const u8, []const u8) bool,
};

// Staging tarball path. Same string on purpose — it names a file on two
// *different* filesystems (the local host and the remote server), so the values
// being equal is incidental, not a copy-paste bug. Fixed paths are fine: each
// transfer truncates the tarball, and a failed transfer leaves at most this one
// stale temp (in /tmp) which the next run overwrites.
const LOCAL_TMP = "/tmp/.wispterm-skill.tgz";
const REMOTE_TMP = "/tmp/.wispterm-skill.tgz";

/// Upload the skill at `rel_path` from the local hub to the server.
pub fn upload(allocator: std.mem.Allocator, ops: Ops, rel_path: []const u8) Result {
    const sp = cmd.splitSkillPath(rel_path) orelse return .failed;
    const make = cmd.tarCreateCmd(allocator, sp.root_rel, sp.item, LOCAL_TMP) catch return .failed;
    defer allocator.free(make);
    if (!ops.localExec(ops.ctx, allocator, make)) return .failed;

    if (!ops.copy(ops.ctx, allocator, .upload, LOCAL_TMP, REMOTE_TMP)) return .failed;

    const extract = cmd.tarExtractCmd(allocator, sp.root_rel, sp.item, REMOTE_TMP) catch return .failed;
    defer allocator.free(extract);
    const cleanup = std.fmt.allocPrint(allocator, "{s}; rm -f '{s}'", .{ extract, REMOTE_TMP }) catch return .failed;
    defer allocator.free(cleanup);
    if (!ops.remoteExec(ops.ctx, allocator, cleanup)) return .failed;

    _ = ops.localExec(ops.ctx, allocator, "rm -f '" ++ LOCAL_TMP ++ "'");
    return .ok;
}

/// Download the skill at `rel_path` from the server into the local hub.
pub fn download(allocator: std.mem.Allocator, ops: Ops, rel_path: []const u8) Result {
    const sp = cmd.splitSkillPath(rel_path) orelse return .failed;
    const make = cmd.tarCreateCmd(allocator, sp.root_rel, sp.item, REMOTE_TMP) catch return .failed;
    defer allocator.free(make);
    if (!ops.remoteExec(ops.ctx, allocator, make)) return .failed;

    if (!ops.copy(ops.ctx, allocator, .download, LOCAL_TMP, REMOTE_TMP)) return .failed;

    const extract = cmd.tarExtractCmd(allocator, sp.root_rel, sp.item, LOCAL_TMP) catch return .failed;
    defer allocator.free(extract);
    if (!ops.localExec(ops.ctx, allocator, extract)) return .failed;

    _ = ops.localExec(ops.ctx, allocator, "rm -f '" ++ LOCAL_TMP ++ "'");
    _ = ops.remoteExec(ops.ctx, allocator, "rm -f '" ++ REMOTE_TMP ++ "'");
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
    fn copy(ctx: *anyopaque, _: std.mem.Allocator, _: Direction, _: []const u8, _: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.fail_copy) return false;
        self.copies += 1;
        return true;
    }
    fn ops(self: *Recorder) Ops {
        return .{ .ctx = self, .localExec = localExec, .remoteExec = remoteExec, .copy = copy };
    }
};

test "skill_transfer: upload runs tar-create local, copy, extract remote" {
    const allocator = std.testing.allocator;
    var rec = Recorder{ .allocator = allocator };
    defer rec.deinit();
    try std.testing.expectEqual(Result.ok, upload(allocator, rec.ops(), ".claude/skills/pdf/SKILL.md"));
    try std.testing.expectEqual(@as(usize, 1), rec.copies);
    try std.testing.expect(std.mem.startsWith(u8, rec.local_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.remote_cmds.items[0], "tar -xzf") != null);
}

test "skill_transfer: download runs tar-create remote, copy, extract local" {
    const allocator = std.testing.allocator;
    var rec = Recorder{ .allocator = allocator };
    defer rec.deinit();
    try std.testing.expectEqual(Result.ok, download(allocator, rec.ops(), ".codex/prompts/foo.md"));
    try std.testing.expect(std.mem.startsWith(u8, rec.remote_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.local_cmds.items[0], "tar -xzf") != null);
}

test "skill_transfer: copy failure aborts with failed" {
    const allocator = std.testing.allocator;
    var rec = Recorder{ .allocator = allocator, .fail_copy = true };
    defer rec.deinit();
    try std.testing.expectEqual(Result.failed, upload(allocator, rec.ops(), ".claude/skills/pdf/SKILL.md"));
}
