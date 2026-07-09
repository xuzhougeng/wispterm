//! SSH/WSL remote source enumeration (spec §6, M3 Task 3): turns the app's
//! saved ssh_hosts profiles into `run.RemoteSource` values the scheduler and
//! dev CLI can both pass into `run.Options.remote_sources`. Reuses the same
//! ssh_hosts codec the SSH settings page/port-forwarding form already use
//! (src/ssh/profile_store.zig) rather than the UI-only threadlocal test seam
//! in AppWindow.zig.
const std = @import("std");
const builtin = @import("builtin");
const profile_codec = @import("../renderer/overlays/profile_codec.zig");
const remote_file = @import("../platform/remote_file.zig");
const run = @import("run.zig");
const ssh_connection = @import("../ssh/connection.zig");
const ssh_profile_store = @import("../ssh/profile_store.zig");

const MAX_SSH_PROFILES = 32;

/// One arena-allocated SshConnection per profile, boxed so `RemoteSource`'s
/// exec closure has a stable address to `@ptrCast` through — `SshConnection`
/// is a fixed-buffer value type, not something ExecHost's `ctx: *anyopaque`
/// can point at directly without a home.
const SshCtx = struct {
    conn: ssh_connection.SshConnection,
};

/// Same 2MB stdout cap and error semantics as remote_file.sshExecCapture
/// (non-zero exit -> error.RemoteExecFailed, stdout ownership transferred to
/// caller on success), but goes through sshExecCaptureFullCapped directly so
/// this call site can log a stderr summary on failure (spec §13 diagnostics)
/// instead of only remote_file's own std.debug.print.
fn sshExec(ctx: *anyopaque, gpa: std.mem.Allocator, command: []const u8) anyerror![]u8 {
    const self: *SshCtx = @ptrCast(@alignCast(ctx));
    var cap = try remote_file.sshExecCaptureFullCapped(gpa, &self.conn, command, 2 * 1024 * 1024);
    if (!cap.exited_ok) {
        std.log.warn("memory_digest: remote exec failed exited_ok={} stderr={s}", .{ cap.exited_ok, cap.stderr[0..@min(cap.stderr.len, 200)] });
        cap.deinit(gpa);
        return error.RemoteExecFailed;
    }
    gpa.free(cap.stderr);
    return cap.stdout; // ownership transferred to caller
}

/// Reads the app's ssh_hosts file and returns one `run.RemoteSource` per
/// decodable profile, source_id `"ssh:{profile_name}"`. Missing/empty
/// ssh_hosts -> empty list (not an error): remote scanning is opt-in and a
/// fresh install has no SSH profiles yet.
pub fn loadSshSources(gpa: std.mem.Allocator, arena: std.mem.Allocator) ![]run.RemoteSource {
    const path = try ssh_profile_store.profilesPath(gpa);
    defer gpa.free(path);
    const content = std.fs.cwd().readFileAlloc(gpa, path, 1024 * 1024) catch return &.{};
    defer gpa.free(content);
    return loadSshSourcesFromContent(arena, content);
}

/// Pure decode: same content shape `ssh_profile_store.loadProfilesFromContent`
/// reads. Split out so the scheduler/CLI's real ssh_hosts path is exercised
/// only at runtime while this decode logic gets a real (fake-content) test.
pub fn loadSshSourcesFromContent(arena: std.mem.Allocator, content: []const u8) ![]run.RemoteSource {
    var profiles: [MAX_SSH_PROFILES]profile_codec.SshProfile = undefined;
    const count = ssh_profile_store.loadProfilesFromContent(content, &profiles);
    if (count == 0) return &.{};

    var out: std.ArrayListUnmanaged(run.RemoteSource) = .empty;
    for (profiles[0..count]) |*profile| {
        const conn = ssh_profile_store.connectionFromProfile(profile, false) orelse continue;
        const name = profile_codec.profileField(profile, .name);
        if (name.len == 0) continue;

        const ctx = try arena.create(SshCtx);
        ctx.* = .{ .conn = conn };
        const source_id = try std.fmt.allocPrint(arena, "ssh:{s}", .{name});
        try out.append(arena, .{
            .source_id = source_id,
            .host = .{ .ctx = @ptrCast(ctx), .exec = sshExec },
        });
    }
    return out.items;
}

fn wslExecHost(_: *anyopaque, gpa: std.mem.Allocator, command: []const u8) anyerror![]u8 {
    return remote_file.wslExec(gpa, command) orelse error.RemoteExecFailed;
}

var g_wsl_ctx: u8 = 0;

/// WSL is Windows-only (spec M3 Task 3). On macOS/Linux this always returns
/// an empty list — there is no WSL to scan. On Windows it returns a single
/// "wsl:default" source wrapping `remote_file.wslExec`.
/// ponytail: not verified on a real Windows machine (no such box in this
/// dev environment); compiles and follows the same wslExec wrapping every
/// other WSL call site in this codebase already uses (file_backend.zig,
/// skill_center_actions.zig, session.zig).
pub fn loadWslSources(arena: std.mem.Allocator) ![]run.RemoteSource {
    if (builtin.os.tag != .windows) return &.{};
    return arena.dupe(run.RemoteSource, &.{.{
        .source_id = "wsl:default",
        .host = .{ .ctx = @ptrCast(&g_wsl_ctx), .exec = wslExecHost },
    }});
}

// ---- tests ----

fn appendEncodedProfileForTest(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fields: []const []const u8) !void {
    for (fields, 0..) |field, idx| {
        if (idx > 0) try out.append(allocator, '\t');
        const hex = "0123456789ABCDEF";
        for (field) |ch| {
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
    try out.append(allocator, '\n');
}

test "memory_digest_sources: loadSshSourcesFromContent decodes profiles into ssh:-prefixed sources" {
    const allocator = std.testing.allocator;
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    try appendEncodedProfileForTest(allocator, &content, &.{ "devbox", "10.0.0.9", "alice", "secret", "2222", "" });
    try appendEncodedProfileForTest(allocator, &content, &.{ "prod", "10.0.0.3", "bob", "", "22", "" });

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const sources = try loadSshSourcesFromContent(arena_state.allocator(), content.items);
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("ssh:devbox", sources[0].source_id);
    try std.testing.expectEqualStrings("ssh:prod", sources[1].source_id);
}

test "memory_digest_sources: loadSshSourcesFromContent skips unsafe/unnamed profiles" {
    const allocator = std.testing.allocator;
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    // Unsafe host (command injection attempt) -> connectionFromProfile rejects it.
    try appendEncodedProfileForTest(allocator, &content, &.{ "bad", "host;rm -rf /", "alice", "", "22", "" });
    try appendEncodedProfileForTest(allocator, &content, &.{ "ok", "10.0.0.1", "alice", "", "22", "" });

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const sources = try loadSshSourcesFromContent(arena_state.allocator(), content.items);
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqualStrings("ssh:ok", sources[0].source_id);
}

test "memory_digest_sources: loadSshSourcesFromContent on empty/comment-only content returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const sources = try loadSshSourcesFromContent(arena_state.allocator(), "# only comments\n");
    try std.testing.expectEqual(@as(usize, 0), sources.len);
}

test "memory_digest_sources: loadWslSources is empty on non-Windows" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const sources = try loadWslSources(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 0), sources.len);
}
