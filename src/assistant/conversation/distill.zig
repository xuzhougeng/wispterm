//! Pure helpers for turning an AI Chat transcript into a candidate SKILL.md.
const std = @import("std");
const skill_registry = @import("../../skill/registry.zig");
const text_search = @import("../../text_search.zig");

pub const CommandAction = enum {
    start,
    confirm,
    cancel,
};

pub const CommandArgs = struct {
    action: CommandAction,
    topic: []const u8 = "",
};

pub const DistillRole = enum {
    user,
    assistant,
    tool,
};

pub const DistillTurn = struct {
    role: DistillRole,
    content: []const u8,
    replay_to_model: bool = false,
};

pub const Candidate = struct {
    name: []u8,
    description: []u8,
    body: []u8,
    source_summary: []u8,

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.body);
        allocator.free(self.source_summary);
        self.* = undefined;
    }
};

pub const SuggestionInput = struct {
    turns: []const DistillTurn,
    pending_candidate: bool,
    suggestion_pending: bool,
    last_suggested_turn_count: usize = 0,
};

pub const distiller_system_prompt =
    \\You distill one WispTerm AI Chat transcript into one reusable Codex skill.
    \\Return only compact JSON with string fields: name, description, body, source_summary.
    \\Do not include secrets, tokens, passwords, API keys, private host credentials, or one-off machine paths as requirements.
    \\Prefer reusable procedures with sections: When To Use, Preconditions, Steps, Verification, Pitfalls.
;

pub fn parseCommandArgs(arg: []const u8) CommandArgs {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    if (trimmed.len == 0) return .{ .action = .start };
    if (std.ascii.eqlIgnoreCase(trimmed, "confirm") or std.mem.eql(u8, trimmed, "确认")) return .{ .action = .confirm };
    if (std.ascii.eqlIgnoreCase(trimmed, "cancel") or
        std.mem.eql(u8, trimmed, "取消") or
        std.mem.eql(u8, trimmed, "放弃"))
    {
        return .{ .action = .cancel };
    }
    return .{ .action = .start, .topic = trimmed };
}

pub fn isValidSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 63) return false;
    if (!std.ascii.isAlphanumeric(slug[0]) or std.ascii.isUpper(slug[0])) return false;
    for (slug) |ch| {
        if (std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-') continue;
        return false;
    }
    return true;
}

pub fn normalizeSlug(allocator: std.mem.Allocator, suggested_name: []const u8, fallback_topic: []const u8) ![]u8 {
    if (try normalizeSlugOnce(allocator, suggested_name)) |slug| return slug;
    if (try normalizeSlugOnce(allocator, fallback_topic)) |slug| return slug;
    return allocator.dupe(u8, "skill");
}

fn normalizeSlugOnce(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_sep = false;
    for (text) |ch| {
        if (out.items.len >= 63) break;
        if (std.ascii.isAlphanumeric(ch)) {
            if (pending_sep and out.items.len > 0 and out.items[out.items.len - 1] != '-' and out.items.len < 63) {
                try out.append(allocator, '-');
            }
            if (out.items.len >= 63) break;
            try out.append(allocator, std.ascii.toLower(ch));
            pending_sep = false;
        } else {
            pending_sep = out.items.len > 0;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

pub fn redactSensitive(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var line_redacted: std.ArrayListUnmanaged(u8) = .empty;
    errdefer line_redacted.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse text.len;
        const line = text[cursor..line_end];
        try appendRedactedLine(allocator, &line_redacted, line);
        if (line_end < text.len) try line_redacted.append(allocator, '\n');
        cursor = if (line_end < text.len) line_end + 1 else line_end;
    }

    const with_lines = try line_redacted.toOwnedSlice(allocator);
    defer allocator.free(with_lines);
    return redactSkTokens(allocator, with_lines);
}

pub fn containsSensitiveMaterial(text: []const u8) bool {
    if (findSkTokenEnd(text, 0) != null) return true;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse text.len;
        const line = text[cursor..line_end];
        if (lineHasBearerSecret(line) or lineHasSensitiveAssignment(line)) return true;
        cursor = if (line_end < text.len) line_end + 1 else line_end;
    }
    return false;
}

pub fn parseCandidateJson(allocator: std.mem.Allocator, json_text: []const u8, topic: []const u8) !Candidate {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return error.InvalidCandidate;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidCandidate;
    const object = parsed.value.object;
    const name_raw = jsonStringField(object, "name") orelse return error.InvalidCandidate;
    const description_raw = jsonStringField(object, "description") orelse return error.InvalidCandidate;
    const body_raw = jsonStringField(object, "body") orelse return error.InvalidCandidate;
    const source_raw = jsonStringField(object, "source_summary") orelse return error.InvalidCandidate;

    const name = try normalizeSlug(allocator, name_raw, topic);
    errdefer allocator.free(name);
    const description_trimmed = std.mem.trim(u8, description_raw, " \t\r\n");
    const body_trimmed = stripFrontmatter(std.mem.trim(u8, body_raw, " \t\r\n"));
    const source_trimmed = std.mem.trim(u8, source_raw, " \t\r\n");
    if (description_trimmed.len == 0 or body_trimmed.len == 0) return error.InvalidCandidate;
    if (containsSensitiveMaterial(name) or
        containsSensitiveMaterial(description_trimmed) or
        containsSensitiveMaterial(body_trimmed) or
        containsSensitiveMaterial(source_trimmed))
    {
        return error.SensitiveCandidate;
    }

    const description = try allocator.dupe(u8, description_trimmed);
    errdefer allocator.free(description);
    const body = try allocator.dupe(u8, body_trimmed);
    errdefer allocator.free(body);
    const source_summary = try allocator.dupe(u8, source_trimmed);
    errdefer allocator.free(source_summary);

    var candidate = Candidate{
        .name = name,
        .description = description,
        .body = body,
        .source_summary = source_summary,
    };
    errdefer candidate.deinit(allocator);
    const rendered = try renderSkillMarkdown(allocator, candidate);
    defer allocator.free(rendered);
    if (rendered.len > skill_registry.MAX_SKILL_MD_BYTES) return error.SkillTooLarge;
    return candidate;
}

pub fn renderSkillMarkdown(allocator: std.mem.Allocator, candidate: Candidate) ![]u8 {
    const description = try sanitizeFrontmatterLine(allocator, candidate.description);
    defer allocator.free(description);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator,
        \\---
        \\name: {s}
        \\description: {s}
        \\---
        \\
        \\# {s}
        \\
        \\{s}
        \\
    , .{ candidate.name, description, candidate.name, std.mem.trim(u8, candidate.body, " \t\r\n") });
    if (out.items.len > skill_registry.MAX_SKILL_MD_BYTES) return error.SkillTooLarge;
    return out.toOwnedSlice(allocator);
}

pub fn renderPreviewMarkdown(allocator: std.mem.Allocator, candidate: Candidate, save_path: []const u8) ![]u8 {
    const markdown = try renderSkillMarkdown(allocator, candidate);
    defer allocator.free(markdown);
    return std.fmt.allocPrint(allocator,
        \\Distill preview
        \\
        \\Skill: ${s}
        \\Description: {s}
        \\Save path: {s}
        \\
        \\Source summary:
        \\{s}
        \\
        \\SKILL.md preview:
        \\```markdown
        \\{s}```
        \\
        \\Confirm with /distill confirm or /沉淀 确认.
        \\Cancel with /distill cancel or /沉淀 取消.
        \\
    , .{ candidate.name, candidate.description, save_path, candidate.source_summary, markdown });
}

pub fn buildDistillUserPrompt(
    allocator: std.mem.Allocator,
    topic: []const u8,
    turns: []const DistillTurn,
) ![]u8 {
    if (turns.len == 0) return error.NotEnoughContext;
    const start = if (turns.len > 32) turns.len - 32 else 0;
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    errdefer raw.deinit(allocator);
    try raw.appendSlice(allocator, "Distill the following WispTerm AI Chat transcript into one reusable skill candidate.\n");
    const topic_trimmed = std.mem.trim(u8, topic, " \t\r\n");
    if (topic_trimmed.len > 0) try raw.print(allocator, "Topic guidance: {s}\n", .{topic_trimmed});
    try raw.appendSlice(allocator, "\nTranscript:\n");

    var useful_turns: usize = 0;
    for (turns[start..]) |turn| {
        if (!includeTurnInPrompt(turn)) continue;
        if (turn.role == .user or turn.role == .assistant) useful_turns += 1;
        try raw.print(allocator, "\n[{s}]\n{s}\n", .{ roleLabel(turn.role), turn.content });
    }
    if (useful_turns == 0) return error.NotEnoughContext;
    const raw_slice = try raw.toOwnedSlice(allocator);
    defer allocator.free(raw_slice);
    return redactSensitive(allocator, raw_slice);
}

pub fn shouldSuggest(input: SuggestionInput) bool {
    if (input.pending_candidate or input.suggestion_pending) return false;
    if (input.turns.len == 0 or input.turns.len <= input.last_suggested_turn_count) return false;

    const start = if (input.turns.len > 16) input.turns.len - 16 else 0;
    var running_tools: usize = 0;
    var saw_tool_activity = false;
    for (input.turns[start..]) |turn| {
        if (turn.role == .tool and std.mem.startsWith(u8, std.mem.trimLeft(u8, turn.content, " \t\r\n"), "running ")) {
            running_tools += 1;
            saw_tool_activity = true;
        }
        if (turn.role == .user and hasStrongDistillIntent(turn.content)) return true;
    }
    if (running_tools >= 2) return true;
    if (saw_tool_activity) {
        for (input.turns[start..]) |turn| {
            if (turn.role == .assistant and mentionsReusableSteps(turn.content)) return true;
        }
    }
    return false;
}

fn appendRedactedLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    line: []const u8,
) !void {
    if (lineBearerValueStart(line)) |value_start| {
        try out.appendSlice(allocator, line[0..value_start]);
        try out.appendSlice(allocator, "<redacted>");
        return;
    }
    if (sensitiveAssignmentValueStart(line)) |value_start| {
        try out.appendSlice(allocator, line[0..value_start]);
        try out.appendSlice(allocator, "<redacted>");
        return;
    }
    try out.appendSlice(allocator, line);
}

fn redactSkTokens(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < text.len) {
        const next = std.mem.indexOfPos(u8, text, cursor, "sk-") orelse {
            try out.appendSlice(allocator, text[cursor..]);
            break;
        };
        if (findSkTokenEnd(text, next)) |end| {
            try out.appendSlice(allocator, text[cursor..next]);
            try out.appendSlice(allocator, "<redacted>");
            cursor = end;
        } else {
            try out.appendSlice(allocator, text[cursor .. next + 3]);
            cursor = next + 3;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn findSkTokenEnd(text: []const u8, start_pos: usize) ?usize {
    var pos = std.mem.indexOfPos(u8, text, start_pos, "sk-") orelse return null;
    while (pos < text.len) {
        var end = pos + 3;
        while (end < text.len and isSecretTokenByte(text[end])) : (end += 1) {}
        if (end - pos >= 19) return end;
        pos = std.mem.indexOfPos(u8, text, pos + 3, "sk-") orelse return null;
    }
    return null;
}

fn isSecretTokenByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_';
}

fn lineHasBearerSecret(line: []const u8) bool {
    const start = lineBearerValueStart(line) orelse return false;
    const value = std.mem.trim(u8, line[start..], " \t\r\n\"'");
    return value.len >= 8 and !std.mem.startsWith(u8, value, "<redacted>");
}

fn lineBearerValueStart(line: []const u8) ?usize {
    var i: usize = 0;
    while (i + "bearer".len <= line.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(line[i .. i + "bearer".len], "bearer")) continue;
        var value_start = i + "bearer".len;
        while (value_start < line.len and (line[value_start] == ' ' or line[value_start] == '\t')) : (value_start += 1) {}
        if (value_start < line.len) return value_start;
    }
    return null;
}

fn lineHasSensitiveAssignment(line: []const u8) bool {
    const start = sensitiveAssignmentValueStart(line) orelse return false;
    const value = std.mem.trim(u8, line[start..], " \t\r\n\"'");
    return value.len > 0 and !std.mem.startsWith(u8, value, "<redacted>");
}

fn sensitiveAssignmentValueStart(line: []const u8) ?usize {
    const sep = std.mem.indexOfAny(u8, line, "=:") orelse return null;
    const key = std.mem.trim(u8, line[0..sep], " \t\r\n\"'`");
    if (!isSensitiveKey(key)) return null;
    var value_start = sep + 1;
    while (value_start < line.len and (line[value_start] == ' ' or line[value_start] == '\t')) : (value_start += 1) {}
    return value_start;
}

fn isSensitiveKey(key: []const u8) bool {
    if (key.len == 0) return false;
    const tokens = [_][]const u8{
        "api_key",
        "apikey",
        "profile_key",
        "password",
        "passwd",
        "pwd",
        "token",
        "context_token",
        "weixin_token",
    };
    for (tokens) |token| {
        if (containsIgnoreCase(key, token)) return true;
    }
    const suffixes = [_][]const u8{ "_TOKEN", "_KEY", "_SECRET", "_PASSWORD" };
    for (suffixes) |suffix| {
        if (key.len >= suffix.len and std.ascii.eqlIgnoreCase(key[key.len - suffix.len ..], suffix)) return true;
    }
    return false;
}

fn jsonStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn stripFrontmatter(body: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, body, "---")) return body;
    var cursor = std.mem.indexOfScalar(u8, body, '\n') orelse return body;
    cursor += 1;
    while (cursor <= body.len) {
        const line_end = std.mem.indexOfScalarPos(u8, body, cursor, '\n') orelse body.len;
        const line = std.mem.trim(u8, body[cursor..line_end], " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            const after = if (line_end < body.len) line_end + 1 else line_end;
            return std.mem.trim(u8, body[after..], " \t\r\n");
        }
        if (line_end == body.len) break;
        cursor = line_end + 1;
    }
    return body;
}

fn sanitizeFrontmatterLine(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (std.mem.trim(u8, text, " \t\r\n")) |ch| {
        try out.append(allocator, if (ch == '\r' or ch == '\n') ' ' else ch);
    }
    return out.toOwnedSlice(allocator);
}

fn includeTurnInPrompt(turn: DistillTurn) bool {
    return switch (turn.role) {
        .user, .assistant => turn.content.len > 0,
        .tool => turn.replay_to_model or std.mem.startsWith(u8, std.mem.trimLeft(u8, turn.content, " \t\r\n"), "running "),
    };
}

fn roleLabel(role: DistillRole) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn hasStrongDistillIntent(text: []const u8) bool {
    const needles = [_][]const u8{
        "以后还会用",
        "记住这个流程",
        "下次直接用",
        "distill this",
        "save this workflow",
        "remember this workflow",
    };
    for (needles) |needle| {
        if (containsIgnoreCase(text, needle)) return true;
    }
    return false;
}

fn mentionsReusableSteps(text: []const u8) bool {
    const needles = [_][]const u8{
        "reusable",
        "steps",
        "workflow",
        "流程",
        "步骤",
        "复用",
    };
    for (needles) |needle| {
        if (containsIgnoreCase(text, needle)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return text_search.containsIgnoreCase(haystack, needle);
}

test "parse distill command args" {
    try std.testing.expectEqual(CommandAction.start, parseCommandArgs("").action);
    try std.testing.expectEqualStrings("ssh troubleshooting", parseCommandArgs("  ssh troubleshooting  ").topic);
    try std.testing.expectEqual(CommandAction.confirm, parseCommandArgs("confirm").action);
    try std.testing.expectEqual(CommandAction.confirm, parseCommandArgs("确认").action);
    try std.testing.expectEqual(CommandAction.cancel, parseCommandArgs("cancel").action);
    try std.testing.expectEqual(CommandAction.cancel, parseCommandArgs("取消").action);
    try std.testing.expectEqual(CommandAction.cancel, parseCommandArgs("放弃").action);
}

test "normalize skill slug" {
    const allocator = std.testing.allocator;

    const a = try normalizeSlug(allocator, "SSH File Transfer Troubleshooting", "");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("ssh-file-transfer-troubleshooting", a);

    const b = try normalizeSlug(allocator, "  a__b---c  ", "");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("a-b-c", b);

    const c = try normalizeSlug(allocator, "远程上传", "remote ssh");
    defer allocator.free(c);
    try std.testing.expectEqualStrings("remote-ssh", c);

    const d = try normalizeSlug(allocator, "", "");
    defer allocator.free(d);
    try std.testing.expectEqualStrings("skill", d);

    const e = try normalizeSlug(allocator, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-long-tail", "");
    defer allocator.free(e);
    try std.testing.expect(e.len <= 63);
    try std.testing.expect(isValidSlug(e));
}

test "redact sensitive material" {
    const allocator = std.testing.allocator;
    const text =
        \\api_key = "sk-abcdefghijklmnopqrstuvwxyz"
        \\Authorization: Bearer abcdefghijklmnop
        \\WEIXIN_CONTEXT_TOKEN=secret-value
        \\keyboard shortcut stays readable
    ;
    const redacted = try redactSensitive(allocator, text);
    defer allocator.free(redacted);
    try std.testing.expect(!std.mem.containsAtLeast(u8, redacted, 1, "sk-abcdefghijklmnopqrstuvwxyz"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, redacted, 1, "abcdefghijklmnop"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, redacted, 1, "secret-value"));
    try std.testing.expect(std.mem.containsAtLeast(u8, redacted, 1, "<redacted>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, redacted, 1, "keyboard shortcut"));
    try std.testing.expect(!containsSensitiveMaterial("keyboard shortcut stays readable"));
}

test "parse candidate JSON and render markdown" {
    const allocator = std.testing.allocator;
    var candidate = try parseCandidateJson(allocator,
        \\{
        \\  "name": "SSH File Transfer Troubleshooting",
        \\  "description": "Diagnose WispTerm SSH transfer failures.",
        \\  "body": "---\nname: old\n---\n\n# Steps\n\nRun checks.",
        \\  "source_summary": "Derived from a transfer debugging session."
        \\}
    , "ssh transfer");
    defer candidate.deinit(allocator);

    try std.testing.expectEqualStrings("ssh-file-transfer-troubleshooting", candidate.name);

    const markdown = try renderSkillMarkdown(allocator, candidate);
    defer allocator.free(markdown);
    try std.testing.expect(std.mem.startsWith(u8, markdown,
        \\---
        \\name: ssh-file-transfer-troubleshooting
        \\description: Diagnose WispTerm SSH transfer failures.
        \\---
        \\
    ));
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "# Steps"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, markdown, 1, "source_summary"));
    try std.testing.expect(markdown.len <= skill_registry.MAX_SKILL_MD_BYTES);
    try std.testing.expect(markdown[markdown.len - 1] == '\n');
}

test "reject invalid or sensitive candidate JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidCandidate, parseCandidateJson(allocator,
        \\{"name":"x","description":"desc","source_summary":"src"}
    , ""));
    try std.testing.expectError(error.InvalidCandidate, parseCandidateJson(allocator,
        \\{"name":123,"description":"desc","body":"body","source_summary":"src"}
    , ""));
    try std.testing.expectError(error.SensitiveCandidate, parseCandidateJson(allocator,
        \\{"name":"x","description":"desc","body":"api_key = sk-abcdefghijklmnopqrstuvwxyz","source_summary":"src"}
    , ""));
}

test "build distill prompt from reusable context" {
    const allocator = std.testing.allocator;
    const turns = [_]DistillTurn{
        .{ .role = .tool, .content = "Available commands:", .replay_to_model = false },
        .{ .role = .user, .content = "Please debug this, api_key=sk-abcdefghijklmnopqrstuvwxyz" },
        .{ .role = .tool, .content = "running exec {\"cmd\":\"zig build test\"}" },
        .{ .role = .assistant, .content = "The reusable steps are inspect, test, and verify." },
    };
    const prompt = try buildDistillUserPrompt(allocator, "zig workflow", &turns);
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "zig workflow"));
    try std.testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "running exec"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, prompt, 1, "Available commands:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, prompt, 1, "sk-abcdefghijklmnopqrstuvwxyz"));
    try std.testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "<redacted>"));

    try std.testing.expectError(error.NotEnoughContext, buildDistillUserPrompt(allocator, "", &.{}));
}

test "automatic suggestion heuristic" {
    const tool_heavy = [_]DistillTurn{
        .{ .role = .user, .content = "fix this" },
        .{ .role = .tool, .content = "running exec one" },
        .{ .role = .tool, .content = "running exec two" },
        .{ .role = .assistant, .content = "done" },
    };
    try std.testing.expect(shouldSuggest(.{ .turns = &tool_heavy, .pending_candidate = false, .suggestion_pending = false }));
    try std.testing.expect(!shouldSuggest(.{ .turns = &tool_heavy, .pending_candidate = true, .suggestion_pending = false }));
    try std.testing.expect(!shouldSuggest(.{ .turns = &tool_heavy, .pending_candidate = false, .suggestion_pending = true }));
    try std.testing.expect(!shouldSuggest(.{ .turns = &tool_heavy, .pending_candidate = false, .suggestion_pending = false, .last_suggested_turn_count = tool_heavy.len }));

    const intent = [_]DistillTurn{
        .{ .role = .user, .content = "记住这个流程，下次直接用" },
        .{ .role = .assistant, .content = "可以" },
    };
    try std.testing.expect(shouldSuggest(.{ .turns = &intent, .pending_candidate = false, .suggestion_pending = false }));

    const simple = [_]DistillTurn{
        .{ .role = .user, .content = "what is two plus two" },
        .{ .role = .assistant, .content = "four" },
    };
    try std.testing.expect(!shouldSuggest(.{ .turns = &simple, .pending_candidate = false, .suggestion_pending = false }));
}
