//! Remote source collection (spec §6, M3): same incremental collect/cursor
//! contract as collector.zig's collectLocal, but files are listed and read
//! over an exec host (ssh/wsl) instead of the local filesystem. Shares the
//! "bytes -> CollectedSession" pipeline with collector.zig via
//! ingestJsonlBytes so parse/subagent-filter/new-message-slice semantics
//! stay identical between local and remote.
const std = @import("std");
const ai_session = @import("../terminal_agents/sessions/session.zig");
const ai_types = @import("../terminal_agents/sessions/types.zig");
const collector = @import("collector.zig");
const cursors_mod = @import("cursors.zig");
const types = @import("types.zig");

const MAX_FILE_BYTES = 64 * 1024 * 1024;

/// Same shape as session.zig's RemoteExecHost, redeclared here so this
/// module does not import the UI-coupled scanning layer — only the pure
/// pub fns (providerFindCommand/remoteCatCommand) are reused from there.
pub const ExecHost = struct {
    ctx: *anyopaque,
    exec: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, command: []const u8) anyerror![]u8,
};

pub const RemoteRootsSpec = struct {
    claude: bool = true,
    codex: bool = true,
};

/// Collects new sessions from one remote source (ssh/wsl) into `out`,
/// advancing nothing but reading `cur` to decide what changed. Returns the
/// number of sessions collected from this source.
pub fn collectRemote(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(types.CollectedSession),
    source_id: []const u8,
    host: ExecHost,
    cur: *cursors_mod.Set,
    min_mtime_ns: i128,
    roots: RemoteRootsSpec,
) !u32 {
    const home_raw = host.exec(host.ctx, gpa, "printf %s \"$HOME\"") catch return error.RemoteHomeFailed;
    defer gpa.free(home_raw);
    const home = std.mem.trim(u8, home_raw, " \t\r\n");
    if (home.len == 0) return error.RemoteHomeFailed;

    var count: u32 = 0;
    if (roots.claude) {
        const root = try std.fmt.allocPrint(gpa, "{s}/.claude/projects", .{home});
        defer gpa.free(root);
        count += try collectProvider(gpa, arena, out, source_id, host, cur, min_mtime_ns, .claude, root);
    }
    if (roots.codex) {
        const root = try std.fmt.allocPrint(gpa, "{s}/.codex/sessions", .{home});
        defer gpa.free(root);
        count += try collectProvider(gpa, arena, out, source_id, host, cur, min_mtime_ns, .codex, root);
    }
    return count;
}

fn digestToAiProvider(provider: types.DigestProvider) ai_types.ProviderId {
    return switch (provider) {
        .claude => .claude,
        .codex => .codex,
        .reasonix => .reasonix,
        .wispterm => unreachable, // wispterm is local-only (no remote root)
    };
}

fn collectProvider(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(types.CollectedSession),
    source_id: []const u8,
    host: ExecHost,
    cur: *cursors_mod.Set,
    min_mtime_ns: i128,
    provider: types.DigestProvider,
    root: []const u8,
) !u32 {
    var cmd_buf: [2048]u8 = undefined;
    const find_cmd = try ai_session.providerFindCommand(digestToAiProvider(provider), root, &cmd_buf);
    const find_out = try host.exec(host.ctx, gpa, find_cmd);
    defer gpa.free(find_out);

    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, find_out, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var cand = try parseFindLine(line, provider);
        // find_out (and thus cand.path, which borrows from it) is freed when
        // this function returns; CollectedSession.source_file must outlive
        // that, so dupe into the output arena now (mirrors collector.zig's
        // local path, which is already arena-allocated by its caller).
        cand.path = try arena.dupe(u8, cand.path);

        if (cand.mtime_ns < min_mtime_ns) continue; // backfill window (spec §6), no cursor created
        const start = cur.pendingFrom(source_id, provider, cand.path, cand.size, cand.mtime_ns) orelse continue;

        var cmd_buf2: [2048]u8 = undefined;
        const cat_cmd = ai_session.remoteCatCommand(cand.path, &cmd_buf2) catch continue;
        const bytes = host.exec(host.ctx, gpa, cat_cmd) catch continue; // transient: retry next run, cursor untouched
        defer gpa.free(bytes);

        if (bytes.len > MAX_FILE_BYTES) {
            // Remember the stamp so the oversize file is not retried hot.
            try cur.update(source_id, provider, cand.path, cand.size, cand.mtime_ns, 0);
            continue;
        }

        const before = out.items.len;
        try collector.ingestJsonlBytes(gpa, arena, out, cur, provider, source_id, cand.path, cand.size, cand.mtime_ns, bytes, start);
        count += @intCast(out.items.len - before);
    }
    return count;
}

const FindCandidate = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i128,
};

/// Parses one `find -printf '%T@\t%s\t%p'` output line. mtime is seconds
/// (possibly fractional); truncated to whole seconds then converted to ns.
/// A line with no tab is the BSD `find` fallback shape (path-only, no
/// stamps) which this module does not support yet (ponytail: M3 targets GNU
/// find on Linux remotes only; BSD/macOS remote support needs the
/// providerFindCommandPlain two-pass fallback session.zig already has for
/// the UI scanner — wire that in when a real BSD remote shows up).
fn parseFindLine(line: []const u8, provider: types.DigestProvider) !FindCandidate {
    var it = std.mem.splitScalar(u8, line, '\t');
    const first = it.next().?;
    const second = it.next() orelse {
        std.log.warn("memory_digest: remote find output for {s} has no stamps (BSD find?) - unsupported", .{@tagName(provider)});
        return error.RemoteFindUnsupported;
    };
    const third = it.next() orelse {
        std.log.warn("memory_digest: remote find output for {s} has no stamps (BSD find?) - unsupported", .{@tagName(provider)});
        return error.RemoteFindUnsupported;
    };
    const secs_str = std.mem.sliceTo(first, '.');
    const secs = std.fmt.parseInt(i128, secs_str, 10) catch 0;
    const size = std.fmt.parseInt(u64, std.mem.trim(u8, second, " "), 10) catch 0;
    return .{
        .path = std.mem.trim(u8, third, " \t\r\n"),
        .size = size,
        .mtime_ns = secs * std.time.ns_per_s,
    };
}

// ---- tests ----

const CLAUDE_JSONL =
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"Fix tests"}}
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the failure."}]}}
    \\
;

const CLAUDE_JSONL_2 =
    \\{"sessionId":"claude-def","cwd":"/home/me/other","timestamp":"2026-05-31T11:00:00.000Z","type":"user","message":{"role":"user","content":"Second session"}}
    \\
;

const FakeHost = struct {
    home: []const u8 = "/home/me",
    fail_home: bool = false,
    find_output: []const u8 = "",
    cat_files: std.StringHashMapUnmanaged([]const u8) = .empty,
    cat_calls: u32 = 0,

    fn exec(ctx: *anyopaque, gpa: std.mem.Allocator, command: []const u8) anyerror![]u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, command, "printf %s \"$HOME\"")) {
            if (self.fail_home) return error.ExecFailed;
            return gpa.dupe(u8, self.home);
        }
        if (std.mem.startsWith(u8, command, "find ")) {
            // Only serve claude root queries in these tests (codex root query
            // returns empty = no files, which is a valid "nothing found").
            if (std.mem.indexOf(u8, command, "/.claude/projects") != null) {
                return gpa.dupe(u8, self.find_output);
            }
            return gpa.dupe(u8, "");
        }
        if (std.mem.startsWith(u8, command, "cat ")) {
            self.cat_calls += 1;
            // Extract the quoted path back out: cat '<path>'
            const start = std.mem.indexOfScalar(u8, command, '\'') orelse return error.BadCommand;
            const rest = command[start + 1 ..];
            const end = std.mem.indexOfScalar(u8, rest, '\'') orelse return error.BadCommand;
            const path = rest[0..end];
            if (self.cat_files.get(path)) |bytes| return gpa.dupe(u8, bytes);
            return error.CatFailed;
        }
        return error.UnknownCommand;
    }

    fn execHost(self: *FakeHost) ExecHost {
        return .{ .ctx = @ptrCast(self), .exec = exec };
    }
};

test "memory_digest_remote: first run collects, second run collects nothing and does not cat" {
    const allocator = std.testing.allocator;
    var host: FakeHost = .{
        .find_output = "1780300860.0\t200\t/home/me/.claude/projects/proj-a/claude-abc.jsonl\n" ++
            "1780300860.0\t100\t/home/me/.claude/projects/proj-b/claude-def.jsonl\n",
    };
    defer host.cat_files.deinit(allocator);
    try host.cat_files.put(allocator, "/home/me/.claude/projects/proj-a/claude-abc.jsonl", CLAUDE_JSONL);
    try host.cat_files.put(allocator, "/home/me/.claude/projects/proj-b/claude-def.jsonl", CLAUDE_JSONL_2);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var out: std.ArrayListUnmanaged(types.CollectedSession) = .empty;

    const n = try collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, 0, .{});
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(u32, 2), host.cat_calls);
    // project_path threaded through correctly for one of the sessions.
    var found_proj_a = false;
    for (out.items) |s| {
        if (std.mem.eql(u8, s.session_id, "claude-abc")) {
            try std.testing.expectEqualStrings("/home/me/project", s.project_path);
            found_proj_a = true;
        }
    }
    try std.testing.expect(found_proj_a);

    // Simulate run.zig's post-processing cursor advancement.
    for (out.items) |s| {
        try cur.update("ssh:box", s.provider, s.source_file, s.file_size, s.file_mtime_ns, s.total_messages);
    }

    var out2: std.ArrayListUnmanaged(types.CollectedSession) = .empty;
    const n2 = try collectRemote(allocator, arena_state.allocator(), &out2, "ssh:box", host.execHost(), &cur, 0, .{});
    try std.testing.expectEqual(@as(u32, 0), n2);
    try std.testing.expectEqual(@as(u32, 2), host.cat_calls); // unchanged: no new cats
}

test "memory_digest_remote: only the changed file is cat'd" {
    const allocator = std.testing.allocator;
    var host: FakeHost = .{
        .find_output = "1780300860.0\t200\t/home/me/.claude/projects/proj-a/claude-abc.jsonl\n" ++
            "1780300860.0\t100\t/home/me/.claude/projects/proj-b/claude-def.jsonl\n",
    };
    defer host.cat_files.deinit(allocator);
    try host.cat_files.put(allocator, "/home/me/.claude/projects/proj-a/claude-abc.jsonl", CLAUDE_JSONL);
    try host.cat_files.put(allocator, "/home/me/.claude/projects/proj-b/claude-def.jsonl", CLAUDE_JSONL_2);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var out: std.ArrayListUnmanaged(types.CollectedSession) = .empty;
    _ = try collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, 0, .{});
    for (out.items) |s| {
        try cur.update("ssh:box", s.provider, s.source_file, s.file_size, s.file_mtime_ns, s.total_messages);
    }
    try std.testing.expectEqual(@as(u32, 2), host.cat_calls);

    // Only proj-a's stamp changes (size bump) and its content grew an appended line.
    host.find_output = "1780300861.0\t250\t/home/me/.claude/projects/proj-a/claude-abc.jsonl\n" ++
        "1780300860.0\t100\t/home/me/.claude/projects/proj-b/claude-def.jsonl\n";
    const appended = CLAUDE_JSONL ++
        \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:02:00.000Z","type":"user","message":{"role":"user","content":"And lint"}}
        \\
    ;
    try host.cat_files.put(allocator, "/home/me/.claude/projects/proj-a/claude-abc.jsonl", appended);

    var out2: std.ArrayListUnmanaged(types.CollectedSession) = .empty;
    const n2 = try collectRemote(allocator, arena_state.allocator(), &out2, "ssh:box", host.execHost(), &cur, 0, .{});
    try std.testing.expectEqual(@as(u32, 1), n2);
    try std.testing.expectEqual(@as(usize, 1), out2.items.len);
    try std.testing.expectEqual(@as(usize, 1), out2.items[0].new_messages.len);
    try std.testing.expectEqualStrings("And lint", out2.items[0].new_messages[0].content);
    try std.testing.expectEqual(@as(u32, 3), host.cat_calls); // one more cat only
}

test "memory_digest_remote: BSD find output (no tabs) errors" {
    const allocator = std.testing.allocator;
    var host: FakeHost = .{
        .find_output = "/home/me/.claude/projects/proj-a/claude-abc.jsonl\n",
    };
    defer host.cat_files.deinit(allocator);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var out: std.ArrayListUnmanaged(types.CollectedSession) = .empty;
    try std.testing.expectError(error.RemoteFindUnsupported, collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, 0, .{}));
}

test "memory_digest_remote: home exec failure errors" {
    const allocator = std.testing.allocator;
    var host: FakeHost = .{ .fail_home = true };
    defer host.cat_files.deinit(allocator);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var out: std.ArrayListUnmanaged(types.CollectedSession) = .empty;
    try std.testing.expectError(error.RemoteHomeFailed, collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, 0, .{}));
}

test "memory_digest_remote: min_mtime filters out old files without creating cursors" {
    const allocator = std.testing.allocator;
    var host: FakeHost = .{
        .find_output = "1780300860.0\t200\t/home/me/.claude/projects/proj-a/claude-abc.jsonl\n",
    };
    defer host.cat_files.deinit(allocator);
    try host.cat_files.put(allocator, "/home/me/.claude/projects/proj-a/claude-abc.jsonl", CLAUDE_JSONL);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var out: std.ArrayListUnmanaged(types.CollectedSession) = .empty;

    const n = try collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, std.math.maxInt(i128), .{});
    try std.testing.expectEqual(@as(u32, 0), n);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expectEqual(@as(usize, 0), cur.entries.items.len);
    try std.testing.expectEqual(@as(u32, 0), host.cat_calls);
}
