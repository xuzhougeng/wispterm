const std = @import("std");
const text_search = @import("../../text_search.zig");

pub const ProviderId = enum {
    codex,
    claude,
    reasonix,

    pub fn label(self: ProviderId) []const u8 {
        return switch (self) {
            .codex => "Codex",
            .claude => "Claude Code",
            .reasonix => "Reasonix",
        };
    }
};

pub const CategoryFilter = enum {
    all,
    codex,
    claude,
    reasonix,
    subagent,
};

pub const CATEGORY_ORDER = [_]CategoryFilter{ .all, .codex, .claude, .reasonix, .subagent };

pub const CategoryCounts = struct {
    all: usize = 0,
    codex: usize = 0,
    claude: usize = 0,
    reasonix: usize = 0,
    subagent: usize = 0,
};

pub fn isSubagentSession(meta: SessionMeta) bool {
    const title = std.mem.trimLeft(u8, meta.title, " \t\r\n");
    const prefix = "you are";
    return title.len >= prefix.len and std.ascii.eqlIgnoreCase(title[0..prefix.len], prefix);
}

pub fn categoryMatchesMeta(category: CategoryFilter, meta: SessionMeta) bool {
    const subagent = isSubagentSession(meta);
    return switch (category) {
        .all => true,
        .codex => meta.provider == .codex and !subagent,
        .claude => meta.provider == .claude and !subagent,
        .reasonix => meta.provider == .reasonix and !subagent,
        .subagent => subagent,
    };
}

pub fn categoryLabel(category: CategoryFilter) []const u8 {
    return switch (category) {
        .all => "All",
        .codex => "Codex",
        .claude => "Claude Code",
        .reasonix => "Reasonix",
        .subagent => "Subagent",
    };
}

pub fn categoryCount(counts: CategoryCounts, category: CategoryFilter) usize {
    return switch (category) {
        .all => counts.all,
        .codex => counts.codex,
        .claude => counts.claude,
        .reasonix => counts.reasonix,
        .subagent => counts.subagent,
    };
}

/// A calendar day packed as the decimal integer `YYYYMMDD` (e.g. 20260601).
/// `0` is the sentinel for "no / unknown timestamp" and never forms a bucket.
pub const DateKey = u32;

/// One distinct day present in the session list, with how many sessions fall on
/// it under the currently-active provider category and text query.
pub const DateBucket = struct {
    key: DateKey,
    count: usize,
};

/// Convert a UTC epoch-millisecond timestamp to a local-day `DateKey`.
/// `tz_offset_seconds` is the local offset east of UTC (e.g. 28800 for UTC+8);
/// pass 0 to bucket in UTC. Returns 0 when the timestamp is absent (<= 0).
pub fn dateKeyFromMs(ms: i64, tz_offset_seconds: i32) DateKey {
    if (ms <= 0) return 0;
    const total_secs = @divFloor(ms, 1000) + tz_offset_seconds;
    if (total_secs < 0) return 0;
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(total_secs) };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const year: u32 = year_day.year;
    const month: u32 = month_day.month.numeric();
    const day: u32 = @as(u32, month_day.day_index) + 1;
    return year * 10000 + month * 100 + day;
}

/// `null` filter matches every day (the "All dates" selection). Otherwise the
/// row's day must equal the filter; the sentinel key 0 never matches a filter.
pub fn dateMatches(filter: ?DateKey, key: DateKey) bool {
    const want = filter orelse return true;
    return key == want;
}

/// Render `key` as an 8-digit `YYYYMMDD` string into `buf` (needs >= 8 bytes).
pub fn formatDateKey(key: DateKey, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>8}", .{key}) catch buf[0..0];
}

pub const MessageRole = enum { user, assistant, system, tool };
pub const MessageKind = enum { normal, tool_call, tool_result, meta };
pub const ScanStatus = enum { ok, partial, not_found, invalid };
pub const ResumeKind = enum { codex_resume, claude_resume, reasonix_resume, unavailable };

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
    return text_search.containsIgnoreCase(meta.title, query) or
        text_search.containsIgnoreCase(meta.summary, query) or
        text_search.containsIgnoreCase(meta.project_dir, query) or
        text_search.containsIgnoreCase(meta.session_id, query) or
        text_search.containsIgnoreCase(meta.source_path, query);
}

test "ai_history_types: provider labels are stable" {
    try std.testing.expectEqualStrings("Codex", ProviderId.codex.label());
    try std.testing.expectEqualStrings("Claude Code", ProviderId.claude.label());
    try std.testing.expectEqualStrings("Reasonix", ProviderId.reasonix.label());
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

test "ai_history_types: categoryMatchesMeta respects provider" {
    const codex: SessionMeta = .{
        .provider = .codex,
        .session_id = "codex",
        .title = "Codex task",
        .source_path = "codex.jsonl",
        .resume_kind = .codex_resume,
    };
    const claude: SessionMeta = .{
        .provider = .claude,
        .session_id = "claude",
        .title = "Claude task",
        .source_path = "claude.jsonl",
        .resume_kind = .claude_resume,
    };
    const reasonix: SessionMeta = .{
        .provider = .reasonix,
        .session_id = "reasonix",
        .title = "Reasonix task",
        .source_path = "reasonix.jsonl",
        .resume_kind = .reasonix_resume,
    };

    try std.testing.expect(categoryMatchesMeta(.all, codex));
    try std.testing.expect(categoryMatchesMeta(.all, claude));
    try std.testing.expect(categoryMatchesMeta(.codex, codex));
    try std.testing.expect(!categoryMatchesMeta(.codex, claude));
    try std.testing.expect(categoryMatchesMeta(.claude, claude));
    try std.testing.expect(!categoryMatchesMeta(.claude, codex));
    try std.testing.expect(categoryMatchesMeta(.reasonix, reasonix));
    try std.testing.expect(!categoryMatchesMeta(.reasonix, codex));
}

test "ai_history_types: You are titles are classified as subagent metadata" {
    const subagent: SessionMeta = .{
        .provider = .claude,
        .session_id = "subagent",
        .title = "  You Are implementing Task 3 of the plan",
        .source_path = "subagent.jsonl",
        .resume_kind = .claude_resume,
    };
    const lowercase: SessionMeta = .{
        .provider = .codex,
        .session_id = "subagent-lower",
        .title = "you are a code-review subagent",
        .source_path = "subagent-lower.jsonl",
        .resume_kind = .codex_resume,
    };
    const normal: SessionMeta = .{
        .provider = .claude,
        .session_id = "normal",
        .title = "Fix renderer panel",
        .source_path = "normal.jsonl",
        .resume_kind = .claude_resume,
    };

    try std.testing.expect(isSubagentSession(subagent));
    try std.testing.expect(isSubagentSession(lowercase));
    try std.testing.expect(categoryMatchesMeta(.subagent, subagent));
    try std.testing.expect(!categoryMatchesMeta(.claude, subagent));
    try std.testing.expect(!isSubagentSession(normal));
    try std.testing.expect(categoryMatchesMeta(.claude, normal));
    try std.testing.expect(!categoryMatchesMeta(.subagent, normal));
}

test "ai_history_types: categoryLabel is stable" {
    try std.testing.expectEqualStrings("All", categoryLabel(.all));
    try std.testing.expectEqualStrings("Codex", categoryLabel(.codex));
    try std.testing.expectEqualStrings("Claude Code", categoryLabel(.claude));
    try std.testing.expectEqualStrings("Reasonix", categoryLabel(.reasonix));
    try std.testing.expectEqualStrings("Subagent", categoryLabel(.subagent));
}

test "ai_history_types: dateKeyFromMs packs local civil date and handles sentinels" {
    // 2026-06-01 12:00:00 UTC.
    const noon_20260601_ms: i64 = 1780315200 * 1000;
    try std.testing.expectEqual(@as(DateKey, 20260601), dateKeyFromMs(noon_20260601_ms, 0));
    // +14h offset pushes 12:00 to 02:00 the next local day.
    try std.testing.expectEqual(@as(DateKey, 20260602), dateKeyFromMs(noon_20260601_ms, 14 * 3600));
    // 2026-06-01 02:00 UTC with -8h offset falls back to 2026-05-31 18:00 local.
    const early_ms: i64 = (1780315200 - 10 * 3600) * 1000;
    try std.testing.expectEqual(@as(DateKey, 20260531), dateKeyFromMs(early_ms, -8 * 3600));
    // No timestamp -> sentinel 0 (never a bucket).
    try std.testing.expectEqual(@as(DateKey, 0), dateKeyFromMs(0, 0));
    try std.testing.expectEqual(@as(DateKey, 0), dateKeyFromMs(-5, 3600));
}

test "ai_history_types: dateMatches treats null filter as all dates" {
    try std.testing.expect(dateMatches(null, 20260601));
    try std.testing.expect(dateMatches(null, 0));
    try std.testing.expect(dateMatches(20260601, 20260601));
    try std.testing.expect(!dateMatches(20260601, 20260531));
    try std.testing.expect(!dateMatches(20260601, 0));
}

test "ai_history_types: formatDateKey renders a zero-padded YYYYMMDD" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("20260601", formatDateKey(20260601, &buf));
    try std.testing.expectEqualStrings("20260102", formatDateKey(20260102, &buf));
}
