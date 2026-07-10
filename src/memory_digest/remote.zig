//! Remote source collection (spec §6, M3): same incremental collect/cursor
//! contract as collector.zig's collectLocal, but files are listed and read
//! over an exec host (ssh/wsl) instead of the local filesystem. Shares the
//! "bytes -> CollectedSession" pipeline with collector.zig via
//! ingestJsonlBytes so parse/subagent-filter/new-message-slice semantics
//! stay identical between local and remote.
const std = @import("std");
const ai_session = @import("../terminal_agents/sessions/session.zig");
const collector = @import("collector.zig");
const cursors_mod = @import("cursors.zig");
const remote_file = @import("../platform/remote_file.zig");
const types = @import("types.zig");

/// sshExecCapture (platform/remote_file.zig) caps captured stdout at 2MB with
/// silent truncation (no error) -- a file whose cat output would be truncated
/// must never be cat'd at all, or it would ingest corrupt/truncated JSONL.
/// 4KB headroom for the cat command's own framing. This is the real ceiling;
/// session.zig's `providerFindCommand -size -2048k` find-side filter would
/// have enforced roughly the same thing, but this module intentionally does
/// NOT reuse that command (see findCommandNoSizeFilter below) so it can see
/// (and count) oversize files instead of having `find` silently drop them.
const REMOTE_CAT_LIMIT: u64 = 2 * 1024 * 1024 - 4096;

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

/// Result of a `collectRemote` call: sessions collected plus how many
/// candidate files were skipped for exceeding REMOTE_CAT_LIMIT.
pub const CollectResult = struct {
    count: u32 = 0,
    oversize_skipped: u32 = 0,
    /// Per-provider candidate file counts plus any diagnostic notes (BSD
    /// find/no-stamps), e.g. "claude: 12 files; codex: 0 files" or
    /// "claude: no-stamps(BSD?)" (spec §13 diagnostics). Allocated from the
    /// `arena` passed into `collectRemote`.
    detail: []const u8 = "",
};

/// Collects new sessions from one remote source (ssh/wsl) into `out`,
/// advancing nothing but reading `cur` to decide what changed.
pub fn collectRemote(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(types.CollectedSession),
    source_id: []const u8,
    host: ExecHost,
    cur: *cursors_mod.Set,
    min_mtime_ns: i128,
    roots: RemoteRootsSpec,
) !CollectResult {
    const home_raw = host.exec(host.ctx, gpa, "printf %s \"$HOME\"") catch return error.RemoteHomeFailed;
    defer gpa.free(home_raw);
    const home = std.mem.trim(u8, home_raw, " \t\r\n");
    if (home.len == 0) return error.RemoteHomeFailed;

    var result: CollectResult = .{};
    var detail_parts: std.ArrayListUnmanaged(u8) = .empty;
    if (roots.claude) {
        const root = try std.fmt.allocPrint(gpa, "{s}/.claude/projects", .{home});
        defer gpa.free(root);
        const r = try collectProvider(gpa, arena, out, source_id, host, cur, min_mtime_ns, .claude, root);
        result.count += r.count;
        result.oversize_skipped += r.oversize_skipped;
        try appendProviderDetail(arena, &detail_parts, "claude", r);
    }
    if (roots.codex) {
        const root = try std.fmt.allocPrint(gpa, "{s}/.codex/sessions", .{home});
        defer gpa.free(root);
        const r = try collectProvider(gpa, arena, out, source_id, host, cur, min_mtime_ns, .codex, root);
        result.count += r.count;
        result.oversize_skipped += r.oversize_skipped;
        try appendProviderDetail(arena, &detail_parts, "codex", r);
    }
    result.detail = detail_parts.items;
    return result;
}

fn appendProviderDetail(arena: std.mem.Allocator, parts: *std.ArrayListUnmanaged(u8), provider_name: []const u8, r: ProviderResult) !void {
    if (parts.items.len > 0) try parts.appendSlice(arena, "; ");
    if (r.no_stamps) {
        try parts.writer(arena).print("{s}: no-stamps(BSD?)", .{provider_name});
    } else {
        try parts.writer(arena).print("{s}: {d} files", .{ provider_name, r.files_seen });
    }
}

/// Extends CollectResult with per-provider diagnostics that only make sense
/// scoped to a single provider (collectRemote folds these into its combined
/// `detail` string via appendProviderDetail).
const ProviderResult = struct {
    count: u32 = 0,
    oversize_skipped: u32 = 0,
    /// Candidate files this provider's `find` produced (parseable lines,
    /// including ones later skipped for backfill/oversize/transient
    /// reasons) — this is what the "{provider}: N files" detail text means.
    files_seen: u32 = 0,
    /// True once a BSD-style (tab-less) find line was seen for this
    /// provider. Non-fatal: that line is skipped and collection continues.
    no_stamps: bool = false,
};

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
) !ProviderResult {
    var cmd_buf: [2048]u8 = undefined;
    const find_cmd = try findCommandNoSizeFilter(root, &cmd_buf);
    const find_out = try host.exec(host.ctx, gpa, find_cmd);
    defer gpa.free(find_out);

    var result: ProviderResult = .{};
    var lines = std.mem.splitScalar(u8, find_out, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var cand = parseFindLine(line, provider) catch {
            // BSD find (no tabs): unsupported shape, but must not abort the
            // other providers/sources (spec §13) — record and skip the line.
            if (!result.no_stamps) {
                std.log.warn("memory_digest: remote find output for {s} has no stamps (BSD find?) - recorded in detail", .{@tagName(provider)});
                result.no_stamps = true;
            }
            continue;
        };
        result.files_seen += 1;
        // find_out (and thus cand.path, which borrows from it) is freed when
        // this function returns; CollectedSession.source_file must outlive
        // that, so dupe into the output arena now (mirrors collector.zig's
        // local path, which is already arena-allocated by its caller).
        cand.path = try arena.dupe(u8, cand.path);

        if (cand.mtime_ns < min_mtime_ns) continue; // backfill window (spec §6), no cursor created
        const start = cur.pendingFrom(source_id, provider, cand.path, cand.size, cand.mtime_ns) orelse continue;

        if (cand.size > REMOTE_CAT_LIMIT) {
            // Would be silently truncated by sshExecCapture's 2MB stdout cap;
            // never cat it. Stamp the cursor so it isn't retried every run.
            try cur.update(source_id, provider, cand.path, cand.size, cand.mtime_ns, 0);
            result.oversize_skipped += 1;
            continue;
        }

        var cmd_buf2: [2048]u8 = undefined;
        const cat_cmd = ai_session.remoteCatCommand(cand.path, &cmd_buf2) catch continue;
        const bytes = host.exec(host.ctx, gpa, cat_cmd) catch continue; // transient: retry next run, cursor untouched
        defer gpa.free(bytes);

        const before = out.items.len;
        try collector.ingestJsonlBytes(gpa, arena, out, cur, provider, source_id, cand.path, cand.size, cand.mtime_ns, bytes, start);
        result.count += @intCast(out.items.len - before);
    }
    return result;
}

/// Same shape as session.zig's providerFindCommand ("mtime<TAB>size<TAB>path",
/// newest first, capped at 500) but WITHOUT the `-size -2048k` filter: this
/// module needs to see oversize candidates (to count and skip them) rather
/// than have `find` drop them silently. Only used for claude/codex roots
/// (this module's RemoteRootsSpec has no reasonix support), so no reasonix
/// name filter is needed here.
fn findCommandNoSizeFilter(root: []const u8, out: []u8) ![]const u8 {
    var quoted_buf: [1024]u8 = undefined;
    const quoted = remote_file.shellQuote(&quoted_buf, root) orelse return error.CommandTooLong;
    return std.fmt.bufPrint(out, "find {s} -type f -name '*.jsonl' -printf '%T@\\t%s\\t%p\\n' 2>/dev/null | sort -rn | head -500", .{quoted}) catch error.CommandTooLong;
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
fn parseFindLine(line: []const u8, _: types.DigestProvider) !FindCandidate {
    var it = std.mem.splitScalar(u8, line, '\t');
    const first = it.next().?;
    const second = it.next() orelse {
        return error.RemoteFindUnsupported;
    };
    const third = it.next() orelse {
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

const CODEX_JSONL =
    \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-abc","cwd":"/home/me/codex-project"}}
    \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix remote Codex parsing"}]}}
    \\
;

const FakeHost = struct {
    home: []const u8 = "/home/me",
    fail_home: bool = false,
    find_output: []const u8 = "",
    codex_find_output: []const u8 = "",
    cat_files: std.StringHashMapUnmanaged([]const u8) = .empty,
    cat_calls: u32 = 0,

    fn exec(ctx: *anyopaque, gpa: std.mem.Allocator, command: []const u8) anyerror![]u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, command, "printf %s \"$HOME\"")) {
            if (self.fail_home) return error.ExecFailed;
            return gpa.dupe(u8, self.home);
        }
        if (std.mem.startsWith(u8, command, "find ")) {
            // Tests can serve Claude and Codex roots independently; empty
            // output is a valid "nothing found".
            if (std.mem.indexOf(u8, command, "/.claude/projects") != null) {
                return gpa.dupe(u8, self.find_output);
            }
            if (std.mem.indexOf(u8, command, "/.codex/sessions") != null) {
                return gpa.dupe(u8, self.codex_find_output);
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

    const r = try collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, 0, .{});
    try std.testing.expectEqual(@as(u32, 2), r.count);
    try std.testing.expectEqual(@as(u32, 0), r.oversize_skipped);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(u32, 2), host.cat_calls);
    try std.testing.expect(std.mem.indexOf(u8, r.detail, "claude:") != null);
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
    const r2 = try collectRemote(allocator, arena_state.allocator(), &out2, "ssh:box", host.execHost(), &cur, 0, .{});
    try std.testing.expectEqual(@as(u32, 0), r2.count);
    try std.testing.expectEqual(@as(u32, 2), host.cat_calls); // unchanged: no new cats
}

test "memory_digest_remote: collects claude and codex from one remote source" {
    const allocator = std.testing.allocator;
    var host: FakeHost = .{
        .find_output = "1780300860.0\t200\t/home/me/.claude/projects/proj-a/claude-abc.jsonl\n",
        .codex_find_output = "1780300861.0\t180\t/home/me/.codex/sessions/2026/05/codex-abc.jsonl\n",
    };
    defer host.cat_files.deinit(allocator);
    try host.cat_files.put(allocator, "/home/me/.claude/projects/proj-a/claude-abc.jsonl", CLAUDE_JSONL);
    try host.cat_files.put(allocator, "/home/me/.codex/sessions/2026/05/codex-abc.jsonl", CODEX_JSONL);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var out: std.ArrayListUnmanaged(types.CollectedSession) = .empty;

    const r = try collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, 0, .{});
    try std.testing.expectEqual(@as(u32, 2), r.count);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(u32, 2), host.cat_calls);

    var found_claude = false;
    var found_codex = false;
    for (out.items) |s| {
        if (s.provider == .claude and std.mem.eql(u8, s.session_id, "claude-abc")) found_claude = true;
        if (s.provider == .codex and std.mem.eql(u8, s.session_id, "codex-abc")) {
            try std.testing.expectEqualStrings("/home/me/codex-project", s.project_path);
            found_codex = true;
        }
    }
    try std.testing.expect(found_claude);
    try std.testing.expect(found_codex);
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
    const r2 = try collectRemote(allocator, arena_state.allocator(), &out2, "ssh:box", host.execHost(), &cur, 0, .{});
    try std.testing.expectEqual(@as(u32, 1), r2.count);
    try std.testing.expectEqual(@as(usize, 1), out2.items.len);
    try std.testing.expectEqual(@as(usize, 1), out2.items[0].new_messages.len);
    try std.testing.expectEqualStrings("And lint", out2.items[0].new_messages[0].content);
    try std.testing.expectEqual(@as(u32, 3), host.cat_calls); // one more cat only
}

test "memory_digest_remote: BSD find output (no tabs) is recorded in detail, not fatal" {
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
    const r = try collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, 0, .{});
    try std.testing.expectEqual(@as(u32, 0), r.count);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(std.mem.indexOf(u8, r.detail, "no-stamps") != null);
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

    const r = try collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, std.math.maxInt(i128), .{});
    try std.testing.expectEqual(@as(u32, 0), r.count);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expectEqual(@as(usize, 0), cur.entries.items.len);
    try std.testing.expectEqual(@as(u32, 0), host.cat_calls);
}

test "memory_digest_remote: oversize file (>REMOTE_CAT_LIMIT) is skipped, not cat'd, and stamped" {
    const allocator = std.testing.allocator;
    const oversize: u64 = 3 * 1024 * 1024; // 3MB > REMOTE_CAT_LIMIT (~2MB - 4KB)
    var buf: [256]u8 = undefined;
    const find_line = std.fmt.bufPrint(&buf, "1780300860.0\t{d}\t/home/me/.claude/projects/proj-a/claude-abc.jsonl\n", .{oversize}) catch unreachable;
    var host: FakeHost = .{ .find_output = find_line };
    defer host.cat_files.deinit(allocator);
    // Deliberately no cat_files entry: if collectProvider ever cats this path,
    // the fake host returns error.CatFailed, which would be silently
    // swallowed by `catch continue` -- so the real assertion is cat_calls==0.

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var out: std.ArrayListUnmanaged(types.CollectedSession) = .empty;

    const r = try collectRemote(allocator, arena_state.allocator(), &out, "ssh:box", host.execHost(), &cur, 0, .{});
    try std.testing.expectEqual(@as(u32, 0), r.count);
    try std.testing.expectEqual(@as(u32, 1), r.oversize_skipped);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expectEqual(@as(u32, 0), host.cat_calls);

    // Cursor stamped (processed=0) so the hot path doesn't retry every run.
    try std.testing.expectEqual(@as(usize, 1), cur.entries.items.len);
    try std.testing.expectEqual(@as(u32, 0), cur.entries.items[0].processed_messages);
    try std.testing.expectEqual(oversize, cur.entries.items[0].size);
}
