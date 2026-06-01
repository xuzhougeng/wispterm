const std = @import("std");

pub const ProviderId = enum {
    codex,
    claude,

    pub fn label(self: ProviderId) []const u8 {
        return switch (self) {
            .codex => "Codex",
            .claude => "Claude Code",
        };
    }
};

pub const MessageRole = enum { user, assistant, system, tool };
pub const MessageKind = enum { normal, tool_call, tool_result, meta };
pub const ScanStatus = enum { ok, partial, not_found, invalid };
pub const ResumeKind = enum { codex_resume, claude_resume, unavailable };

pub const SessionMeta = struct {
    provider: ProviderId,
    session_id: []const u8,
    title: []const u8,
    summary: []const u8 = "",
    project_dir: []const u8 = "",
    created_at_ms: i64 = 0,
    last_active_at_ms: i64 = 0,
    source_path: []const u8,
    resume_kind: ResumeKind,
    message_count: u32 = 0,
    scan_status: ScanStatus = .ok,
};

pub const TranscriptMessage = struct {
    role: MessageRole,
    kind: MessageKind = .normal,
    content: []const u8,
    timestamp_ms: i64 = 0,
};

pub const SortDirection = enum { descending, ascending };

pub fn lessRecent(_: void, lhs: SessionMeta, rhs: SessionMeta) bool {
    if (lhs.last_active_at_ms == rhs.last_active_at_ms) {
        return std.mem.lessThan(u8, lhs.session_id, rhs.session_id);
    }
    return lhs.last_active_at_ms > rhs.last_active_at_ms;
}

pub fn metadataMatches(meta: SessionMeta, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsIgnoreCase(meta.title, query) or
        containsIgnoreCase(meta.summary, query) or
        containsIgnoreCase(meta.project_dir, query) or
        containsIgnoreCase(meta.session_id, query) or
        containsIgnoreCase(meta.source_path, query);
}

fn containsIgnoreCase(haystack: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > haystack.len) return false;
    var i: usize = 0;
    while (i + query.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (query, 0..) |qch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(qch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

test "ai_history_types: provider labels are stable" {
    try std.testing.expectEqualStrings("Codex", ProviderId.codex.label());
    try std.testing.expectEqualStrings("Claude Code", ProviderId.claude.label());
}

test "ai_history_types: metadata search covers title summary project session and path" {
    const meta: SessionMeta = .{
        .provider = .codex,
        .session_id = "sess-123",
        .title = "Fix renderer crash",
        .summary = "OpenGL startup failure",
        .project_dir = "/home/me/wispterm",
        .source_path = "/home/me/.codex/sessions/one.jsonl",
        .resume_kind = .codex_resume,
    };

    try std.testing.expect(metadataMatches(meta, "renderer"));
    try std.testing.expect(metadataMatches(meta, "OPENGL"));
    try std.testing.expect(metadataMatches(meta, "wispterm"));
    try std.testing.expect(metadataMatches(meta, "sess-123"));
    try std.testing.expect(metadataMatches(meta, "sessions/one"));
    try std.testing.expect(!metadataMatches(meta, "missing"));
}

test "ai_history_types: metadata search considers the full query" {
    var title_buf: [257]u8 = undefined;
    var query_buf: [257]u8 = undefined;
    @memset(title_buf[0..256], 'a');
    @memset(query_buf[0..256], 'a');
    title_buf[256] = 'c';
    query_buf[256] = 'b';

    const meta: SessionMeta = .{
        .provider = .codex,
        .session_id = "sess-long",
        .title = title_buf[0..],
        .source_path = "long.jsonl",
        .resume_kind = .codex_resume,
    };

    try std.testing.expect(!metadataMatches(meta, query_buf[0..]));
}

test "ai_history_types: recent sort is descending with session id tie break" {
    var rows = [_]SessionMeta{
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = 10 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 20 },
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 10 },
    };
    std.mem.sort(SessionMeta, &rows, {}, lessRecent);
    try std.testing.expectEqualStrings("c", rows[0].session_id);
    try std.testing.expectEqualStrings("a", rows[1].session_id);
    try std.testing.expectEqualStrings("b", rows[2].session_id);
}
