//! Local filesystem collection (spec §6): enumerate provider logs, compare
//! against cursors, parse only changed files, and return sessions carrying
//! just their new messages. Remote sources (wsl/ssh) arrive in M3 via the
//! existing ScannerHost abstraction.
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");
const provider_claude = @import("../terminal_agents/sessions/provider_claude.zig");
const provider_codex = @import("../terminal_agents/sessions/provider_codex.zig");
const provider_wispterm = @import("provider_wispterm.zig");
const cursors_mod = @import("cursors.zig");
const types = @import("types.zig");

pub const SOURCE_LOCAL = "local";
const MAX_FILE_BYTES = 64 * 1024 * 1024;

pub const LocalRoots = struct {
    /// e.g. <home>/.claude/projects
    claude_projects_dir: ?[]const u8 = null,
    /// e.g. <home>/.codex/sessions
    codex_sessions_dir: ?[]const u8 = null,
    /// e.g. <config>/agent-history/sessions
    wispterm_sessions_dir: ?[]const u8 = null,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    sessions: []types.CollectedSession = &.{},

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Ctx = struct {
    gpa: std.mem.Allocator,
    alloc: std.mem.Allocator, // result arena
    list: *std.ArrayListUnmanaged(types.CollectedSession),
    cur: *cursors_mod.Set,
    min_mtime_ns: i128,
};

pub fn collectLocal(gpa: std.mem.Allocator, roots: LocalRoots, cur: *cursors_mod.Set, min_mtime_ns: i128) !Result {
    var result: Result = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer result.deinit();
    var list: std.ArrayListUnmanaged(types.CollectedSession) = .empty;
    var ctx: Ctx = .{
        .gpa = gpa,
        .alloc = result.arena.allocator(),
        .list = &list,
        .cur = cur,
        .min_mtime_ns = min_mtime_ns,
    };

    if (roots.claude_projects_dir) |root| try collectClaude(&ctx, root);
    if (roots.codex_sessions_dir) |root| try collectCodex(&ctx, root);
    if (roots.wispterm_sessions_dir) |root| try collectWispterm(&ctx, root);

    result.sessions = try list.toOwnedSlice(ctx.alloc);
    return result;
}

fn collectClaude(ctx: *Ctx, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |proj| {
        if (proj.kind != .directory) continue;
        var pdir = dir.openDir(proj.name, .{ .iterate = true }) catch continue;
        defer pdir.close();
        var fit = pdir.iterate();
        while (try fit.next()) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".jsonl")) continue;
            const path = try std.fs.path.join(ctx.alloc, &.{ root, proj.name, ent.name });
            try collectJsonlFile(ctx, .claude, path, pdir, ent.name);
        }
    }
}

fn collectCodex(ctx: *Ctx, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(ctx.gpa);
    defer walker.deinit();
    while (true) {
        const ent = (walker.next() catch break) orelse break;
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.basename, ".jsonl")) continue;
        const path = try std.fs.path.join(ctx.alloc, &.{ root, ent.path });
        try collectJsonlFile(ctx, .codex, path, ent.dir, ent.basename);
    }
}

fn collectJsonlFile(ctx: *Ctx, provider: types.DigestProvider, path: []const u8, dir: std.fs.Dir, name: []const u8) !void {
    const stat = dir.statFile(name) catch return; // transient: retry next run
    if (stat.mtime < ctx.min_mtime_ns) return; // backfill window (spec §6)
    const start = ctx.cur.pendingFrom(SOURCE_LOCAL, provider, path, stat.size, stat.mtime) orelse return;
    const bytes = dir.readFileAlloc(ctx.gpa, name, MAX_FILE_BYTES) catch |err| switch (err) {
        error.FileTooBig => {
            // Remember the stamp so the oversize file is not retried hot.
            try ctx.cur.update(SOURCE_LOCAL, provider, path, stat.size, stat.mtime, 0);
            return;
        },
        else => return,
    };
    defer ctx.gpa.free(bytes);

    const meta = switch (provider) {
        .claude => try provider_claude.parseMetadata(ctx.gpa, path, bytes),
        .codex => try provider_codex.parseMetadata(ctx.gpa, path, bytes),
        else => unreachable,
    };
    defer switch (provider) {
        .claude => provider_claude.freeMetadata(ctx.gpa, meta),
        .codex => provider_codex.freeMetadata(ctx.gpa, meta),
        else => unreachable,
    };
    if (ai_types.isSubagentSession(meta)) {
        try ctx.cur.update(SOURCE_LOCAL, provider, path, stat.size, stat.mtime, 0);
        return;
    }

    const transcript = switch (provider) {
        .claude => try provider_claude.parseTranscript(ctx.gpa, bytes),
        .codex => try provider_codex.parseTranscript(ctx.gpa, bytes),
        else => unreachable,
    };
    defer switch (provider) {
        .claude => provider_claude.freeTranscript(ctx.gpa, transcript),
        .codex => provider_codex.freeTranscript(ctx.gpa, transcript),
        else => unreachable,
    };

    try emit(ctx, provider, path, stat, .{
        .session_id = meta.session_id,
        .title = meta.title,
        .project_path = meta.project_dir,
        .started_at_ms = meta.created_at_ms,
        .ended_at_ms = meta.last_active_at_ms,
    }, transcript, start);
}

fn collectWispterm(ctx: *Ctx, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".json")) continue;
        const path = try std.fs.path.join(ctx.alloc, &.{ root, ent.name });
        const stat = dir.statFile(ent.name) catch continue;
        if (stat.mtime < ctx.min_mtime_ns) continue;
        const start = ctx.cur.pendingFrom(SOURCE_LOCAL, .wispterm, path, stat.size, stat.mtime) orelse continue;
        const bytes = dir.readFileAlloc(ctx.gpa, ent.name, provider_wispterm.MAX_SESSION_BYTES) catch continue;
        defer ctx.gpa.free(bytes);

        var parse_arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer parse_arena.deinit();
        const sess = provider_wispterm.parse(parse_arena.allocator(), bytes) catch {
            // Unparseable file: stamp it so we do not retry hot.
            try ctx.cur.update(SOURCE_LOCAL, .wispterm, path, stat.size, stat.mtime, 0);
            continue;
        };
        try emit(ctx, .wispterm, path, stat, .{
            .session_id = sess.session_id,
            .title = sess.title,
            .project_path = "", // no cwd on disk until spec §10/M4
            .started_at_ms = sess.created_at_ms,
            .ended_at_ms = sess.updated_at_ms,
        }, sess.messages, start);
    }
}

const EmitMeta = struct {
    session_id: []const u8,
    title: []const u8,
    project_path: []const u8,
    started_at_ms: i64,
    ended_at_ms: i64,
};

fn emit(ctx: *Ctx, provider: types.DigestProvider, path: []const u8, stat: std.fs.File.Stat, meta: EmitMeta, transcript: []const ai_types.TranscriptMessage, start: u32) !void {
    const total: u32 = @intCast(transcript.len);
    // Rewritten/truncated file: message count went backwards → reprocess all.
    // ponytail: a revived old session floods once with its full history;
    // acceptable until per-message day slicing lands in M2.
    const from: u32 = if (total < start) 0 else start;
    if (from >= total) {
        try ctx.cur.update(SOURCE_LOCAL, provider, path, stat.size, stat.mtime, total);
        return;
    }
    const fresh = transcript[from..];
    const new_messages = try ctx.alloc.alloc(ai_types.TranscriptMessage, fresh.len);
    for (fresh, 0..) |m, i| new_messages[i] = .{
        .role = m.role,
        .kind = m.kind,
        .content = try ctx.alloc.dupe(u8, m.content),
        .timestamp_ms = m.timestamp_ms,
    };
    try ctx.list.append(ctx.alloc, .{
        .provider = provider,
        .source_id = SOURCE_LOCAL,
        .session_id = try ctx.alloc.dupe(u8, meta.session_id),
        .title = try ctx.alloc.dupe(u8, meta.title),
        .project_path = try ctx.alloc.dupe(u8, meta.project_path),
        .started_at_ms = meta.started_at_ms,
        .ended_at_ms = meta.ended_at_ms,
        .total_messages = total,
        .new_messages = new_messages,
        .source_file = path,
    });
    try ctx.cur.update(SOURCE_LOCAL, provider, path, stat.size, stat.mtime, total);
}

const CLAUDE_JSONL =
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"Fix tests"}}
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the failure."}]}}
    \\
;

const CLAUDE_EXTRA_LINE =
    \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:02:00.000Z","type":"user","message":{"role":"user","content":"And lint"}}
    \\
;

const CODEX_JSONL =
    \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-abc","cwd":"/home/me/project"}}
    \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the renderer crash"}]}}
    \\
;

const WISPTERM_JSON =
    \\{"session_id":"session-1-1","title":"Copilot","api_key":"sk-SECRET","created_at":1782311875112,"updated_at":1782311885976,
    \\ "messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}
;

fn writeTestFile(dir: std.fs.Dir, sub: []const u8, name: []const u8, content: []const u8) !void {
    try dir.makePath(sub);
    var d = try dir.openDir(sub, .{});
    defer d.close();
    try d.writeFile(.{ .sub_path = name, .data = content });
}

test "memory_digest_collector: first run collects all three providers, second run collects none" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try writeTestFile(tmp.dir, "claude/proj-a", "claude-abc.jsonl", CLAUDE_JSONL);
    try writeTestFile(tmp.dir, "codex/2026/05/31", "rollout-x.jsonl", CODEX_JSONL);
    try writeTestFile(tmp.dir, "wisp", "session-1-1.json", WISPTERM_JSON);

    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const codex_root = try std.fs.path.join(allocator, &.{ root, "codex" });
    defer allocator.free(codex_root);
    const wisp_root = try std.fs.path.join(allocator, &.{ root, "wisp" });
    defer allocator.free(wisp_root);
    const roots: LocalRoots = .{
        .claude_projects_dir = claude_root,
        .codex_sessions_dir = codex_root,
        .wispterm_sessions_dir = wisp_root,
    };

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();

    var first = try collectLocal(allocator, roots, &cur, 0);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 3), first.sessions.len);

    var again = try collectLocal(allocator, roots, &cur, 0);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 0), again.sessions.len);
}

test "memory_digest_collector: appended lines yield only new messages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try writeTestFile(tmp.dir, "claude/proj-a", "claude-abc.jsonl", CLAUDE_JSONL);
    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);
    const roots: LocalRoots = .{ .claude_projects_dir = claude_root };

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var first = try collectLocal(allocator, roots, &cur, 0);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.sessions[0].new_messages.len);

    const appended = try std.mem.concat(allocator, u8, &.{ CLAUDE_JSONL, CLAUDE_EXTRA_LINE });
    defer allocator.free(appended);
    try writeTestFile(tmp.dir, "claude/proj-a", "claude-abc.jsonl", appended);

    var second = try collectLocal(allocator, roots, &cur, 0);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), second.sessions[0].new_messages.len);
    try std.testing.expectEqualStrings("And lint", second.sessions[0].new_messages[0].content);
    try std.testing.expectEqualStrings("/home/me/project", second.sessions[0].project_path);
}

test "memory_digest_collector: min_mtime skips old files entirely" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try writeTestFile(tmp.dir, "claude/proj-a", "claude-abc.jsonl", CLAUDE_JSONL);
    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var res = try collectLocal(allocator, .{ .claude_projects_dir = claude_root }, &cur, std.math.maxInt(i128));
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 0), res.sessions.len);
    try std.testing.expectEqual(@as(usize, 0), cur.entries.items.len);
}

test "memory_digest_collector: subagent sessions are stamped and skipped" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const subagent_jsonl =
        \\{"sessionId":"claude-sub","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"You are a search agent. Find X."}}
        \\
    ;
    try writeTestFile(tmp.dir, "claude/proj-a", "claude-sub.jsonl", subagent_jsonl);
    const claude_root = try std.fs.path.join(allocator, &.{ root, "claude" });
    defer allocator.free(claude_root);

    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var res = try collectLocal(allocator, .{ .claude_projects_dir = claude_root }, &cur, 0);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 0), res.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), cur.entries.items.len); // stamped
}

test "memory_digest_collector: missing roots are fine" {
    const allocator = std.testing.allocator;
    var cur = cursors_mod.Set.init(allocator);
    defer cur.deinit();
    var res = try collectLocal(allocator, .{
        .claude_projects_dir = "/nonexistent/claude",
        .codex_sessions_dir = "/nonexistent/codex",
        .wispterm_sessions_dir = "/nonexistent/wisp",
    }, &cur, 0);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 0), res.sessions.len);
}
