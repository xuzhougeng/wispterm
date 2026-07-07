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
        const body = std.mem.trim(u8, msg.content, " \t\r\n");
        if (body.len == 0) continue;
        try appendMessage(allocator, &out, msg.role, body);
        wrote_message = true;
    }
    if (!wrote_message) try out.appendSlice(allocator, "_No transcript messages._\n");

    return out.toOwnedSlice(allocator);
}

fn appendHeader(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), meta: types.SessionMeta) !void {
    try out.appendSlice(allocator, "# AI History Export\n\n");
    try out.writer(allocator).print("- Provider: {s}\n", .{meta.provider.label()});
    try out.writer(allocator).print("- Session: {s}\n", .{meta.session_id});
    if (meta.title.len > 0) try out.writer(allocator).print("- Title: {s}\n", .{meta.title});
    if (meta.project_dir.len > 0) try out.writer(allocator).print("- Project: {s}\n", .{meta.project_dir});
    try out.writer(allocator).print("- Source: {s}\n", .{meta.source_path});
    if (meta.created_at_ms > 0) try out.writer(allocator).print("- Created: {d}\n", .{meta.created_at_ms});
    if (meta.last_active_at_ms > 0) try out.writer(allocator).print("- Updated: {d}\n", .{meta.last_active_at_ms});
    try out.appendSlice(allocator, "\n");
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
