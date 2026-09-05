//! grok-build's authoritative ACP updates.jsonl plus sibling summary.json.
//! Validated against the installed ~/.grok/docs/user-guide/17-sessions.md.
const std = @import("std");
const ai = @import("../terminal_agents/sessions/types.zig");

pub const Session = struct {
    session_id: []const u8,
    title: []const u8,
    cwd: []const u8,
    subagent: bool,
    messages: []const ai.TranscriptMessage,
};

/// Arena-owned. Keep streaming chunks as stable cursor units: merging the
/// last assistant message would lose newly appended chunks on the next run.
pub fn parse(arena: std.mem.Allocator, summary: []const u8, updates: []const u8) !Session {
    const meta = try std.json.parseFromSliceLeaky(std.json.Value, arena, summary, .{ .allocate = .alloc_always });
    const info = field(meta, "info");
    const id = string(field(info, "id"));
    if (id.len == 0) return error.InvalidGrokMetadata;
    const subagent = std.mem.startsWith(u8, string(field(meta, "session_kind")), "subagent");
    var messages: std.ArrayListUnmanaged(ai.TranscriptMessage) = .empty;
    if (!subagent) {
        var lines = std.mem.splitScalar(u8, updates, '\n');
        while (lines.next()) |line| {
            const parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch continue;
            defer parsed.deinit();
            const root = parsed.value;
            const params = field(root, "params");
            const update = field(params, "update");
            const kind = string(field(update, "sessionUpdate"));
            var role: ai.MessageRole = .assistant;
            var message_kind: ai.MessageKind = .normal;
            var text: []const u8 = "";
            if (std.mem.eql(u8, kind, "user_message_chunk") or std.mem.eql(u8, kind, "agent_message_chunk")) {
                if (std.mem.eql(u8, kind, "user_message_chunk")) role = .user;
                const content = field(update, "content");
                if (std.mem.eql(u8, string(field(content, "type")), "text")) text = string(field(content, "text"));
            } else if (std.mem.eql(u8, kind, "tool_call")) {
                message_kind = .tool_call;
                text = string(field(update, "title"));
            }
            // Thoughts, hooks, auth, usage and non-text attachments are not
            // conversation text. Whitespace-only stream chunks are retained.
            if (text.len == 0) continue;
            var timestamp = integer(field(field(params, "_meta"), "agentTimestampMs"));
            if (timestamp <= 0) {
                timestamp = integer(field(root, "timestamp"));
                if (timestamp > 0 and timestamp < 1_000_000_000_000) timestamp *= 1000;
            }
            try messages.append(arena, .{ .role = role, .kind = message_kind, .content = try arena.dupe(u8, text), .timestamp_ms = timestamp });
        }
    }
    var title = string(field(meta, "generated_title"));
    if (title.len == 0) title = string(field(meta, "session_summary"));
    if (title.len == 0) title = id;
    return .{ .session_id = id, .title = title, .cwd = string(field(info, "cwd")), .subagent = subagent, .messages = messages.items };
}

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}

fn string(value: std.json.Value) []const u8 {
    return if (value == .string) value.string else "";
}

fn integer(value: std.json.Value) i64 {
    return if (value == .integer) value.integer else 0;
}

test "grok updates retain cursor-stable chunks and timestamps, excluding thoughts and subagents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const updates =
        \\{"timestamp":1788449851,"params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Fix tests"}}}}
        \\{"timestamp":1788449851,"params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"private reasoning"}}}}
        \\{"timestamp":1788449851,"params":{"update":{"sessionUpdate":"tool_call","title":"Run tests"}}}
        \\{"timestamp":1788449851,"params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"All "}},"_meta":{"agentTimestampMs":1788449851999}}}
        \\{"timestamp":1788449852,"params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"passed"}}}}
        \\{"params":
    ;
    const session = try parse(a, "{\"info\":{\"id\":\"g1\",\"cwd\":\"/project\"},\"generated_title\":\"Fix tests\"}", updates);
    try std.testing.expectEqualStrings("/project", session.cwd);
    try std.testing.expectEqual(@as(usize, 4), session.messages.len);
    try std.testing.expectEqual(@as(i64, 1788449851000), session.messages[0].timestamp_ms);
    try std.testing.expectEqual(@as(i64, 1788449851999), session.messages[2].timestamp_ms);
    try std.testing.expectEqualStrings("All ", session.messages[2].content);
    const child = try parse(a, "{\"info\":{\"id\":\"g2\"},\"session_kind\":\"subagent_resume\"}", updates);
    try std.testing.expect(child.subagent);
    try std.testing.expectEqual(@as(usize, 0), child.messages.len);
    try std.testing.expectError(error.InvalidGrokMetadata, parse(a, "{}", updates));
}
