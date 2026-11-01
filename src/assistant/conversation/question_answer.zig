//! Transcript text for an `ask_user` question: the answered summary card left
//! behind once the question card closes, and the one-row preview of the raw
//! tool call. Pure leaf (fast suite); the Session side that appends the card
//! is session_question_answer.zig.
const std = @import("std");
const types = @import("types.zig");

pub const TOOL_NAME = "ask_user";
pub const ANSWER_MARK = "→ ";

/// "<question>\n→ 2. <label> — <description>" for a picked option, or
/// "<question>\n→ <text>" for a typed answer. Null when nothing was answered.
pub fn allocSummary(
    allocator: std.mem.Allocator,
    question: []const u8,
    options: []const types.QuestionOption,
    result: types.AskResult,
) !?[]u8 {
    const q = std.mem.trim(u8, question, " \t\r\n");
    switch (result) {
        .cancelled => return null,
        .custom => |text| return try std.fmt.allocPrint(allocator, "{s}\n" ++ ANSWER_MARK ++ "{s}", .{ q, std.mem.trim(u8, text, " \t\r\n") }),
        .option_index => |i| {
            if (i >= options.len) return null;
            const opt = options[i];
            if (opt.description.len > 0) {
                return try std.fmt.allocPrint(allocator, "{s}\n" ++ ANSWER_MARK ++ "{d}. {s} — {s}", .{ q, i + 1, opt.label, opt.description });
            }
            return try std.fmt.allocPrint(allocator, "{s}\n" ++ ANSWER_MARK ++ "{d}. {s}", .{ q, i + 1, opt.label });
        },
    }
}

/// The answer line of a summary from `allocSummary`, for the card's collapsed
/// header. Falls back to the whole text when it has no answer line.
pub fn answerLine(summary: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, summary, "\n" ++ ANSWER_MARK) orelse return summary;
    return summary[at + 1 ..];
}

/// The `question` string of an ask_user call's JSON arguments, so its tool
/// row previews the question instead of raw JSON. Escapes stay as written
/// (preview only); null when there is no `"question": "..."` pair.
pub fn callQuestion(arguments: []const u8) ?[]const u8 {
    const key = "\"question\"";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, arguments, from, key)) |key_at| {
        from = key_at + key.len;
        var at = skipSpace(arguments, from);
        if (at >= arguments.len or arguments[at] != ':') continue;
        at = skipSpace(arguments, at + 1);
        if (at >= arguments.len or arguments[at] != '"') continue;
        const start = at + 1;
        var i = start;
        while (i < arguments.len) : (i += 1) {
            switch (arguments[i]) {
                '\\' => i += 1,
                '"' => return arguments[start..i],
                else => {},
            }
        }
        return arguments[start..];
    }
    return null;
}

fn skipSpace(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i;
}

const test_options = [_]types.QuestionOption{
    .{ .label = "SQLite", .description = "single file" },
    .{ .label = "Postgres" },
};

test "summary pairs the question with the picked option" {
    const a = std.testing.allocator;
    const with_desc = (try allocSummary(a, " Which database? ", &test_options, .{ .option_index = 0 })).?;
    defer a.free(with_desc);
    try std.testing.expectEqualStrings("Which database?\n→ 1. SQLite — single file", with_desc);

    const plain = (try allocSummary(a, "Which database?", &test_options, .{ .option_index = 1 })).?;
    defer a.free(plain);
    try std.testing.expectEqualStrings("Which database?\n→ 2. Postgres", plain);
    try std.testing.expectEqualStrings("→ 2. Postgres", answerLine(plain));
}

test "summary keeps a typed answer verbatim" {
    const a = std.testing.allocator;
    const text = (try allocSummary(a, "Which database?", &test_options, .{ .custom = " DuckDB, in memory\n" })).?;
    defer a.free(text);
    try std.testing.expectEqualStrings("Which database?\n→ DuckDB, in memory", text);
    try std.testing.expectEqualStrings("→ DuckDB, in memory", answerLine(text));
}

test "no summary when the question was cancelled or the index is stale" {
    const a = std.testing.allocator;
    try std.testing.expect((try allocSummary(a, "q", &test_options, .cancelled)) == null);
    try std.testing.expect((try allocSummary(a, "q", &test_options, .{ .option_index = 2 })) == null);
}

test "answer line uses the last marker so a question may contain arrows" {
    try std.testing.expectEqualStrings("→ 1. b", answerLine("a\n→ x?\n→ 1. b"));
    try std.testing.expectEqualStrings("plain", answerLine("plain"));
}

test "call question extracts the question value from ask_user arguments" {
    try std.testing.expectEqualStrings(
        "Which database?",
        callQuestion("{\"question\": \"Which database?\", \"options\": [{\"label\": \"SQLite\"}]}").?,
    );
    try std.testing.expectEqualStrings(
        "Say \\\"yes\\\"?",
        callQuestion("{\"options\":[{\"label\":\"question\"}],\"question\":\"Say \\\"yes\\\"?\"}").?,
    );
    try std.testing.expectEqualStrings("cut off", callQuestion("{\"question\":\"cut off").?);
    try std.testing.expect(callQuestion("{\"options\":[]}") == null);
    try std.testing.expect(callQuestion("not json") == null);
}
