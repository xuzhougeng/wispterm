const std = @import("std");
const types = @import("types.zig");

pub const ExportOptions = struct {};

pub const ContextResult = struct {
    markdown: []u8,
    truncated: bool,

    pub fn deinit(self: *ContextResult, allocator: std.mem.Allocator) void {
        allocator.free(self.markdown);
        self.truncated = false;
    }
};

pub fn allocMarkdownExport(
    allocator: std.mem.Allocator,
    meta: types.SessionMeta,
    messages: []const types.TranscriptMessage,
    _: ExportOptions,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendHeader(allocator, &out, meta);

    var wrote_message = false;
    for (messages) |msg| {
        if (std.mem.trim(u8, msg.content, " \t\r\n").len == 0) continue;
        try appendMessage(allocator, &out, msg.role, msg.content);
        wrote_message = true;
    }
    if (!wrote_message) try out.appendSlice(allocator, "_No transcript messages._\n");

    return out.toOwnedSlice(allocator);
}

pub fn allocCopilotContext(
    allocator: std.mem.Allocator,
    meta: types.SessionMeta,
    messages: []const types.TranscriptMessage,
    max_bytes: usize,
) !ContextResult {
    const full = try allocMarkdownExport(allocator, meta, messages, .{});
    if (full.len <= max_bytes) {
        return .{ .markdown = full, .truncated = false };
    }
    allocator.free(full);

    var best_start = messages.len;
    var start = messages.len;
    while (start > 0) {
        start -= 1;
        const candidate = try allocMarkdownExportWithNotice(allocator, meta, messages[start..], true);
        const fits = candidate.len <= max_bytes;
        allocator.free(candidate);
        if (!fits) break;
        best_start = start;
    }

    const markdown = try allocMarkdownExportWithNotice(allocator, meta, messages[best_start..], true);
    if (markdown.len > max_bytes) {
        allocator.free(markdown);
        return .{ .markdown = try allocBoundedTruncationFallback(allocator, max_bytes), .truncated = true };
    }
    return .{ .markdown = markdown, .truncated = true };
}

fn allocBoundedTruncationFallback(allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    const notice = "_Transcript truncated._\n";
    const len = @min(max_bytes, notice.len);
    const out = try allocator.alloc(u8, len);
    @memcpy(out, notice[0..len]);
    return out;
}

fn allocMarkdownExportWithNotice(
    allocator: std.mem.Allocator,
    meta: types.SessionMeta,
    messages: []const types.TranscriptMessage,
    truncated: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendHeader(allocator, &out, meta);
    if (truncated) try out.appendSlice(allocator, "_Transcript truncated; showing the most recent messages._\n\n");

    var wrote_message = false;
    for (messages) |msg| {
        if (std.mem.trim(u8, msg.content, " \t\r\n").len == 0) continue;
        try appendMessage(allocator, &out, msg.role, msg.content);
        wrote_message = true;
    }
    if (!wrote_message) try out.appendSlice(allocator, "_No transcript messages._\n");

    return out.toOwnedSlice(allocator);
}

fn appendHeader(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), meta: types.SessionMeta) !void {
    try out.appendSlice(allocator, "# AI History Export\n\n");
    try out.writer(allocator).print("- Provider: {s}\n", .{meta.provider.label()});
    try appendMetadataBullet(allocator, out, "Session", meta.session_id);
    if (meta.title.len > 0) try appendMetadataBullet(allocator, out, "Title", meta.title);
    if (meta.project_dir.len > 0) try appendMetadataBullet(allocator, out, "Project", meta.project_dir);
    try appendMetadataBullet(allocator, out, "Source", meta.source_path);
    if (meta.created_at_ms > 0) try out.writer(allocator).print("- Created: {d}\n", .{meta.created_at_ms});
    if (meta.last_active_at_ms > 0) try out.writer(allocator).print("- Updated: {d}\n", .{meta.last_active_at_ms});
    try out.appendSlice(allocator, "\n");
}

fn appendMetadataBullet(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    label: []const u8,
    value: []const u8,
) !void {
    try out.writer(allocator).print("- {s}: ", .{label});
    var in_break = false;
    for (value) |ch| {
        switch (ch) {
            '\r', '\n', '\t' => {
                if (!in_break) try out.append(allocator, ' ');
                in_break = true;
            },
            else => {
                try out.append(allocator, ch);
                in_break = false;
            },
        }
    }
    try out.append(allocator, '\n');
}

fn appendMessage(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    role: types.MessageRole,
    body: []const u8,
) !void {
    try out.writer(allocator).print("## {s}\n\n", .{roleHeading(role)});
    try out.appendSlice(allocator, body);
    if (!std.mem.endsWith(u8, body, "\n")) try out.append(allocator, '\n');
    try out.append(allocator, '\n');
}

fn roleHeading(role: types.MessageRole) []const u8 {
    return switch (role) {
        .user => "User",
        .assistant => "Assistant",
        .system => "System",
        .tool => "Tool",
    };
}

pub fn rawDownloadFilename(meta: types.SessionMeta, out: []u8) []const u8 {
    const provider = sanitizedProviderLabel(meta.provider);
    const base = std.fs.path.basename(meta.source_path);
    var n: usize = 0;
    var last_dash = false;
    appendSanitizedFilenamePart(provider, out, &n, &last_dash);
    appendSanitizedFilenamePart("-", out, &n, &last_dash);
    appendSanitizedFilenamePart(meta.session_id, out, &n, &last_dash);
    appendSanitizedFilenamePart("-", out, &n, &last_dash);
    appendSanitizedFilenamePart(base, out, &n, &last_dash);
    while (n > 0 and out[n - 1] == '-') n -= 1;
    return out[0..n];
}

fn sanitizedProviderLabel(provider: types.ProviderId) []const u8 {
    return switch (provider) {
        .codex => "codex",
        .claude => "claude-code",
        .reasonix => "reasonix",
    };
}

fn appendSanitizedFilenamePart(raw: []const u8, out: []u8, n: *usize, last_dash: *bool) void {
    for (raw) |ch| {
        if (n.* >= out.len) break;
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-';
        const next = if (ok) std.ascii.toLower(ch) else '-';
        if (next == '-' and last_dash.*) continue;
        out[n.*] = next;
        n.* += 1;
        last_dash.* = next == '-';
    }
}

test "ai history markdown export includes metadata and role sections" {
    const allocator = std.testing.allocator;
    const meta = types.SessionMeta{
        .provider = .codex,
        .session_id = "sess-1",
        .title = "Fix renderer",
        .project_dir = "/work/wispterm",
        .source_path = "/home/me/.codex/sessions/sess-1.jsonl",
        .resume_kind = .codex_resume,
        .created_at_ms = 1000,
        .last_active_at_ms = 2000,
    };
    const messages = [_]types.TranscriptMessage{
        .{ .role = .user, .content = "status?", .timestamp_ms = 1100 },
        .{ .role = .assistant, .content = "ready", .timestamp_ms = 1200 },
        .{ .role = .tool, .content = "tool output", .timestamp_ms = 1300 },
    };

    const markdown = try allocMarkdownExport(allocator, meta, &messages, .{});
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "# AI History Export") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Provider: Codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Session: sess-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Project: /work/wispterm") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## User") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "status?") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Tool") != null);
}

test "ai history markdown export skips empty message bodies" {
    const allocator = std.testing.allocator;
    const meta = types.SessionMeta{
        .provider = .claude,
        .session_id = "sess-2",
        .title = "Empty turn",
        .source_path = "/home/me/.claude/projects/sess-2.jsonl",
        .resume_kind = .claude_resume,
    };
    const messages = [_]types.TranscriptMessage{
        .{ .role = .system, .content = "" },
        .{ .role = .assistant, .content = "answer" },
    };

    const markdown = try allocMarkdownExport(allocator, meta, &messages, .{});
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "## System") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "answer") != null);
}

test "ai history markdown export preserves non-empty message whitespace" {
    const allocator = std.testing.allocator;
    const meta = types.SessionMeta{
        .provider = .codex,
        .session_id = "sess-3",
        .title = "Whitespace",
        .source_path = "/home/me/.codex/sessions/sess-3.jsonl",
        .resume_kind = .codex_resume,
    };
    const messages = [_]types.TranscriptMessage{
        .{ .role = .assistant, .content = "  indented\n\tline  \n" },
    };

    const markdown = try allocMarkdownExport(allocator, meta, &messages, .{});
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "  indented\n\tline  \n\n") != null);
}

test "ai history markdown export collapses metadata whitespace to one line" {
    const allocator = std.testing.allocator;
    const meta = types.SessionMeta{
        .provider = .codex,
        .session_id = "sess-\n4",
        .title = "Fix\n\tmetadata\rheading",
        .project_dir = "/work/\nwispterm",
        .source_path = "/home/me/.codex/sessions/\rsess-4.jsonl",
        .resume_kind = .codex_resume,
    };
    const messages = [_]types.TranscriptMessage{};

    const markdown = try allocMarkdownExport(allocator, meta, &messages, .{});
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Session: sess- 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Title: Fix metadata heading\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Project: /work/ wispterm\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Source: /home/me/.codex/sessions/ sess-4.jsonl\n") != null);
}

test "ai history copilot context truncates oversized transcripts from the front" {
    const allocator = std.testing.allocator;
    const meta = types.SessionMeta{
        .provider = .reasonix,
        .session_id = "sess-3",
        .title = "Long chat",
        .source_path = "/home/me/.reasonix/sessions/events.jsonl",
        .resume_kind = .reasonix_resume,
    };
    const messages = [_]types.TranscriptMessage{
        .{ .role = .user, .content = "old prompt that should drop" },
        .{ .role = .assistant, .content = "old answer that should drop" },
        .{ .role = .user, .content = "recent prompt" },
        .{ .role = .assistant, .content = "recent answer" },
    };

    var result = try allocCopilotContext(allocator, meta, &messages, 260);
    defer result.deinit(allocator);

    try std.testing.expect(result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "Transcript truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "recent prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "recent answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "old prompt that should drop") == null);
}

test "ai history copilot context stays bounded when metadata alone is too large" {
    const allocator = std.testing.allocator;
    const meta = types.SessionMeta{
        .provider = .reasonix,
        .session_id = "sess-" ++ ("x" ** 140),
        .title = "Long " ++ ("y" ** 140),
        .source_path = "/home/me/.reasonix/sessions/" ++ ("z" ** 140) ++ ".jsonl",
        .resume_kind = .reasonix_resume,
    };
    const messages = [_]types.TranscriptMessage{
        .{ .role = .assistant, .content = "recent answer" },
    };

    var result = try allocCopilotContext(allocator, meta, &messages, 32);
    defer result.deinit(allocator);

    try std.testing.expect(result.truncated);
    try std.testing.expect(result.markdown.len <= 32);
}

test "ai history raw download filename sanitizes provider session and basename" {
    var buf: [160]u8 = undefined;
    const meta = types.SessionMeta{
        .provider = .claude,
        .session_id = "session:bad/id",
        .title = "Ignored",
        .source_path = "/home/me/.claude/projects/original file.jsonl",
        .resume_kind = .claude_resume,
    };

    const name = rawDownloadFilename(meta, &buf);
    try std.testing.expectEqualStrings("claude-code-session-bad-id-original-file.jsonl", name);
}

test "ai history raw download filename preserves long session and basename" {
    var buf: [512]u8 = undefined;
    const meta = types.SessionMeta{
        .provider = .reasonix,
        .session_id = "session:" ++ ("A" ** 220) ++ "/tail",
        .title = "Ignored",
        .source_path = "/home/me/.reasonix/sessions/original " ++ ("B" ** 80) ++ ".jsonl",
        .resume_kind = .reasonix_resume,
    };

    const name = rawDownloadFilename(meta, &buf);
    try std.testing.expect(std.mem.startsWith(u8, name, "reasonix-session-"));
    try std.testing.expect(std.mem.indexOf(u8, name, "tail-original") != null);
    try std.testing.expect(std.mem.endsWith(u8, name, ".jsonl"));
}
