const std = @import("std");
const types = @import("types.zig");

pub const ExportOptions = struct {};

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
