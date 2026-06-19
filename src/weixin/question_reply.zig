//! Classifies a WeChat reply sent while the copilot is blocked on an `ask_user`
//! question, and formats the question for the WeChat push. Pure (the formatter
//! takes an explicit allocator-backed buffer, the classifier allocates nothing)
//! so both are unit-tested directly. Sibling of `approval_reply.zig`, but a
//! question is a *consultation*: any reply that is not a valid option digit is a
//! free-text custom answer rather than being rejected.
const std = @import("std");
const types = @import("types.zig");

pub const QuestionReply = types.QuestionReply;

/// One option as rendered into the WeChat push. Kept local to this module so the
/// pure parser/formatter never depends on the AI-chat types (the weixin layer
/// reaches the Session only through the Control vtable).
pub const PromptOption = struct {
    label: []const u8,
    description: []const u8 = "",
};

/// Classify an inbound reply against a pending question with `n_options` options.
///   - empty / whitespace-only      → `.ignore` (leave the question pending)
///   - a trimmed digit in `1..=n`   → `.{ .option = digit - 1 }`
///   - anything else (incl. an out-of-range or multi-token digit string)
///                                  → `.{ .custom = trimmed }`
pub fn classify(text: []const u8, n_options: usize) QuestionReply {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return .ignore;
    if (isAllDigits(trimmed)) {
        if (std.fmt.parseInt(usize, trimmed, 10)) |n| {
            if (n >= 1 and n <= n_options) return .{ .option = n - 1 };
        } else |_| {}
    }
    return .{ .custom = trimmed };
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Append the WeChat push for `question` + `options` to `out`. Emits
///   请选择：<question>
///   1. <label> — <description>
///   …
///   回复序号，或直接输入你的答案
/// joining the description with " — " only when it is non-empty.
pub fn formatPrompt(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    question: []const u8,
    options: []const PromptOption,
) !void {
    try out.appendSlice(allocator, "请选择：");
    try out.appendSlice(allocator, question);
    for (options, 0..) |opt, i| {
        try out.writer(allocator).print("\n{d}. {s}", .{ i + 1, opt.label });
        if (opt.description.len != 0) {
            try out.appendSlice(allocator, " — ");
            try out.appendSlice(allocator, opt.description);
        }
    }
    try out.appendSlice(allocator, "\n回复序号，或直接输入你的答案");
}

const t = std.testing;

fn expectOption(expected: usize, reply: QuestionReply) !void {
    try t.expect(reply == .option);
    try t.expectEqual(expected, reply.option);
}

fn expectCustom(expected: []const u8, reply: QuestionReply) !void {
    try t.expect(reply == .custom);
    try t.expectEqualStrings(expected, reply.custom);
}

test "classify: a digit in range selects that option (zero-based, trimmed)" {
    try expectOption(0, classify("1", 3));
    try expectOption(1, classify("2", 3));
    try expectOption(2, classify("  3 \n", 3));
}

test "classify: out-of-range or multi-token digit is a custom answer" {
    try expectCustom("9", classify("9", 3)); // beyond the 3 options
    try expectCustom("0", classify("0", 3)); // 1-based, so 0 is not an option
    try expectCustom("12", classify("12", 3)); // two digits, out of range
}

test "classify: non-numeric text is a custom answer (trimmed, CJK ok)" {
    try expectCustom("用 DuckDB", classify("用 DuckDB", 3));
    try expectCustom("用 DuckDB", classify("  用 DuckDB \n", 3));
    try expectCustom("yes please", classify("yes please", 2));
}

test "classify: empty or whitespace-only is ignored (question stays pending)" {
    try t.expect(classify("", 3) == .ignore);
    try t.expect(classify("   \n\t", 3) == .ignore);
}

test "formatPrompt: numbers options, joins descriptions, ends with the hint" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(t.allocator);
    try formatPrompt(t.allocator, &out, "Which database should I target?", &.{
        .{ .label = "Postgres", .description = "prod default, JSONB support" },
        .{ .label = "SQLite", .description = "zero-config, local dev" },
        .{ .label = "MySQL", .description = "legacy compatibility" },
    });
    try t.expectEqualStrings(
        "请选择：Which database should I target?\n" ++
            "1. Postgres — prod default, JSONB support\n" ++
            "2. SQLite — zero-config, local dev\n" ++
            "3. MySQL — legacy compatibility\n" ++
            "回复序号，或直接输入你的答案",
        out.items,
    );
}

test "formatPrompt: an option without a description omits the em-dash" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(t.allocator);
    try formatPrompt(t.allocator, &out, "Keep going?", &.{
        .{ .label = "Yes" },
        .{ .label = "No", .description = "stop here" },
    });
    try t.expectEqualStrings(
        "请选择：Keep going?\n" ++
            "1. Yes\n" ++
            "2. No — stop here\n" ++
            "回复序号，或直接输入你的答案",
        out.items,
    );
}
