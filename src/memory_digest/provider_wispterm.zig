//! Parses WispTerm's own copilot chat history (agent-history/sessions/*.json,
//! written by src/agent/history.zig) into TranscriptMessage form for the
//! memory digest. Secret-bearing fields (api_key, base_url) are never mapped
//! out (spec §7): RawSession simply does not declare them.
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");

pub const MAX_SESSION_BYTES = 32 * 1024 * 1024; // mirrors agent/history.zig

const RawMessage = struct {
    role: []const u8 = "user",
    content: []const u8 = "",
    ts: i64 = 0,
};

const RawSession = struct {
    session_id: []const u8 = "",
    title: []const u8 = "",
    created_at: i64 = 0,
    updated_at: i64 = 0,
    cwd: []const u8 = "",
    messages: []const RawMessage = &.{},
};

pub const Session = struct {
    session_id: []const u8,
    title: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    cwd: []const u8,
    messages: []ai_types.TranscriptMessage,
};

/// All output memory comes from `alloc`; hand in an arena and free wholesale.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Session {
    const parsed = try std.json.parseFromSlice(RawSession, alloc, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const raw = parsed.value;

    const messages = try alloc.alloc(ai_types.TranscriptMessage, raw.messages.len);
    for (raw.messages, 0..) |m, i| {
        const is_tool = std.mem.eql(u8, m.role, "tool");
        messages[i] = .{
            .role = if (is_tool) .tool else if (std.mem.eql(u8, m.role, "assistant")) .assistant else .user,
            .kind = if (is_tool) .tool_result else .normal,
            .content = try alloc.dupe(u8, m.content),
            // Real per-message timestamp when present (spec §10/M4); falls
            // back to the session's updated_at for records written before
            // this field existed.
            .timestamp_ms = if (m.ts > 0) m.ts else raw.updated_at,
        };
    }
    return .{
        .session_id = try alloc.dupe(u8, raw.session_id),
        .title = try alloc.dupe(u8, raw.title),
        .created_at_ms = raw.created_at,
        .updated_at_ms = raw.updated_at,
        .cwd = try alloc.dupe(u8, raw.cwd),
        .messages = messages,
    };
}

test "memory_digest_provider_wispterm: parses session and ignores secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"session_id":"session-1-1","title":"Copilot","base_url":"https://x.example","api_key":"sk-SECRET",
        \\ "model":"m","protocol":"chat_completions","system_prompt":"","thinking_enabled":false,
        \\ "reasoning_effort":"","stream":true,"agent_enabled":false,"created_at":1782311875112,
        \\ "updated_at":1782311885976,
        \\ "messages":[
        \\   {"role":"user","content":"hi","reasoning":null},
        \\   {"role":"assistant","content":"hello","usage_footer":"1 token"},
        \\   {"role":"tool","content":"ls output","tool_name":"run"}
        \\ ]}
    ;
    const sess = try parse(arena.allocator(), json);
    try std.testing.expectEqualStrings("session-1-1", sess.session_id);
    try std.testing.expectEqual(@as(i64, 1782311875112), sess.created_at_ms);
    try std.testing.expectEqual(@as(usize, 3), sess.messages.len);
    try std.testing.expectEqual(ai_types.MessageRole.user, sess.messages[0].role);
    try std.testing.expectEqual(ai_types.MessageRole.assistant, sess.messages[1].role);
    try std.testing.expectEqual(ai_types.MessageRole.tool, sess.messages[2].role);
    try std.testing.expectEqual(ai_types.MessageKind.tool_result, sess.messages[2].kind);
    try std.testing.expectEqual(@as(i64, 1782311885976), sess.messages[0].timestamp_ms);
}

test "memory_digest_provider_wispterm: uses cwd and per-message ts when present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"session_id":"session-2","title":"Copilot","created_at":100,"updated_at":900,
        \\ "cwd":"/home/me/project",
        \\ "messages":[
        \\   {"role":"user","content":"hi","ts":200},
        \\   {"role":"assistant","content":"hello","ts":300},
        \\   {"role":"tool","content":"ls output","ts":0}
        \\ ]}
    ;
    const sess = try parse(arena.allocator(), json);
    try std.testing.expectEqualStrings("/home/me/project", sess.cwd);
    try std.testing.expectEqual(@as(i64, 200), sess.messages[0].timestamp_ms);
    try std.testing.expectEqual(@as(i64, 300), sess.messages[1].timestamp_ms);
    // ts==0 (unset) falls back to the session updated_at.
    try std.testing.expectEqual(@as(i64, 900), sess.messages[2].timestamp_ms);
}

test "memory_digest_provider_wispterm: empty and unknown fields tolerated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sess = try parse(arena.allocator(), "{\"future_field\":123}");
    try std.testing.expectEqual(@as(usize, 0), sess.messages.len);
    try std.testing.expectEqualStrings("", sess.session_id);
}
