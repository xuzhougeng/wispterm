//! Pure logic for in-session model switching: the summarization prompt, the
//! transcript-to-prompt builder, the "is there anything to summarize?" gate,
//! case-insensitive profile-name matching for `/model <name>`, and the summary
//! card marker/content formatting. No Session / GL / AppWindow dependency, so it
//! is unit-tested in the fast suite. Threading + Session mutation stay in
//! ai_chat.zig; overlay/input/render glue stays in their files.
const std = @import("std");

pub const Role = @import("protocol.zig").Role;

/// Max bytes taken from each message when rendering the transcript for the
/// summary prompt. Truncated on a UTF-8 boundary.
pub const max_msg_bytes: usize = 2000;

/// Hard cap on the assembled transcript so a very long conversation can't blow
/// the request budget. Truncated on a UTF-8 boundary.
pub const max_transcript_bytes: usize = 24000;

pub const system_prompt =
    \\You are compacting a chat conversation so it can continue seamlessly with a different model.
    \\Summarize the conversation so far: the user's goal, key facts and decisions, the current state,
    \\any pending task or next step, and important details from tool results. Be concise but complete.
    \\Write the summary in the same language the user is using. Output only the summary.
;

pub const TurnMessage = struct {
    role: Role,
    content: []const u8,
};

/// Largest length <= `limit` that does not split a UTF-8 codepoint.
pub fn utf8SafeLen(s: []const u8, limit: usize) usize {
    if (s.len <= limit) return s.len;
    var end = limit;
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return end;
}

/// True only when there is prior user AND assistant content worth summarizing.
/// An empty / greeting-only conversation (no assistant reply yet) returns false,
/// so a switch then just swaps config with no summary call.
pub fn shouldSummarize(turns: []const TurnMessage) bool {
    var has_user = false;
    var has_assistant = false;
    for (turns) |t| {
        switch (t.role) {
            .user => if (t.content.len > 0) {
                has_user = true;
            },
            .assistant => if (t.content.len > 0) {
                has_assistant = true;
            },
            .tool => {},
        }
    }
    return has_user and has_assistant;
}

/// Case-insensitive exact match of `query` against `names`. Returns the index of
/// the first match, or null (empty query also returns null).
pub fn matchProfileByName(names: []const []const u8, query: []const u8) ?usize {
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return null;
    for (names, 0..) |name, i| {
        if (std.ascii.eqlIgnoreCase(name, q)) return i;
    }
    return null;
}

/// Render the transcript into the single user message for the summary request.
/// Each message is labelled by role and capped at `max_msg_bytes`; the whole
/// thing is capped at `max_transcript_bytes`. Both truncations are UTF-8 safe.
pub fn buildSummaryUserContent(allocator: std.mem.Allocator, turns: []const TurnMessage) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (turns) |t| {
        const label = switch (t.role) {
            .user => "User",
            .assistant => "Assistant",
            .tool => "Tool",
        };
        const slice = t.content[0..utf8SafeLen(t.content, max_msg_bytes)];
        try buf.appendSlice(allocator, label);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, slice);
        try buf.appendSlice(allocator, "\n\n");
    }
    const total = utf8SafeLen(buf.items, max_transcript_bytes);
    return allocator.dupe(u8, buf.items[0..total]);
}

/// First line of `summary` shown as the collapsed card's preview, capped.
pub fn cardPreview(summary: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, summary, '\n') orelse summary.len;
    return summary[0..utf8SafeLen(summary[0..nl], 120)];
}

/// The collapsed card body: a marker line naming the source model, then the
/// summary. This whole string is the message content (sent to the model and
/// rendered), so the new model reads the marker as context too.
pub fn composeCardContent(allocator: std.mem.Allocator, from_model: []const u8, summary: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "（已从 {s} 切换；以下为之前对话的摘要 / Summary of the conversation before switching from {s}）\n\n{s}",
        .{ from_model, from_model, summary },
    );
}

test "shouldSummarize requires both user and assistant content" {
    try std.testing.expect(!shouldSummarize(&.{}));
    try std.testing.expect(!shouldSummarize(&.{.{ .role = .user, .content = "hi" }}));
    try std.testing.expect(!shouldSummarize(&.{.{ .role = .assistant, .content = "hello" }}));
    try std.testing.expect(!shouldSummarize(&.{ .{ .role = .user, .content = "" }, .{ .role = .assistant, .content = "x" } }));
    try std.testing.expect(shouldSummarize(&.{
        .{ .role = .user, .content = "deploy" },
        .{ .role = .tool, .content = "ran" },
        .{ .role = .assistant, .content = "done" },
    }));
}

test "matchProfileByName is case-insensitive and rejects empty/miss" {
    const names = [_][]const u8{ "Claude", "glm-5.2", "GPT-5" };
    try std.testing.expectEqual(@as(?usize, 0), matchProfileByName(&names, "claude"));
    try std.testing.expectEqual(@as(?usize, 1), matchProfileByName(&names, "GLM-5.2"));
    try std.testing.expectEqual(@as(?usize, 2), matchProfileByName(&names, "  gpt-5 "));
    try std.testing.expectEqual(@as(?usize, null), matchProfileByName(&names, "deepseek"));
    try std.testing.expectEqual(@as(?usize, null), matchProfileByName(&names, "   "));
}

test "buildSummaryUserContent labels roles and is UTF-8 safe" {
    const turns = [_]TurnMessage{
        .{ .role = .user, .content = "goal" },
        .{ .role = .assistant, .content = "answer" },
    };
    const c = try buildSummaryUserContent(std.testing.allocator, &turns);
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "User: goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "Assistant: answer") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c));
}

test "buildSummaryUserContent caps a huge message on a UTF-8 boundary" {
    const big = "一" ** 2000; // 6000 bytes > max_msg_bytes
    const turns = [_]TurnMessage{
        .{ .role = .user, .content = big },
        .{ .role = .assistant, .content = "ok" },
    };
    const c = try buildSummaryUserContent(std.testing.allocator, &turns);
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c));
    try std.testing.expect(c.len <= max_transcript_bytes);
}

test "composeCardContent embeds the source model and summary" {
    const c = try composeCardContent(std.testing.allocator, "glm-5.2", "We did X.");
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "glm-5.2") != null);
    try std.testing.expect(std.mem.endsWith(u8, c, "We did X."));
}
