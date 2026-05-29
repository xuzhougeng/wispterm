//! Pure slash-command / skill / composer suggestion parsing, extracted from
//! ai_chat.zig. Text + skill metadata -> suggestion data; no Session state.
const std = @import("std");
const skill_registry = @import("skill_registry.zig");

pub const SlashCommand = enum {
    skills,
    commands,
    reload_skills,
    update_skills,
    reload_commands,
    clear,
    resume_session,
    permission,
    export_markdown,
    unknown,
};

pub const ComposerSuggestionKind = enum {
    slash_command,
    skill,
};

pub const ComposerSuggestion = struct {
    kind: ComposerSuggestionKind,
    text: []const u8,
    description: []const u8,
};

pub const SlashCommandSuggestion = struct {
    command: []const u8,
    description: []const u8,
};

pub const SlashCommandEntry = struct {
    suggestion: SlashCommandSuggestion,
    action: SlashCommand,
};

pub const slash_command_entries = [_]SlashCommandEntry{
    .{
        .suggestion = .{ .command = "/skills", .description = "list available skills" },
        .action = .skills,
    },
    .{
        .suggestion = .{ .command = "/commands", .description = "list slash commands" },
        .action = .commands,
    },
    .{
        .suggestion = .{ .command = "/reload-skills", .description = "rescan skills for future calls" },
        .action = .reload_skills,
    },
    .{
        .suggestion = .{ .command = "/update-skills", .description = "download latest skills from GitHub" },
        .action = .update_skills,
    },
    .{
        .suggestion = .{ .command = "/clear", .description = "clear the conversation context" },
        .action = .clear,
    },
    .{
        .suggestion = .{ .command = "/resume", .description = "resume a saved conversation" },
        .action = .resume_session,
    },
    .{
        .suggestion = .{ .command = "/permission", .description = "view or set agent permission" },
        .action = .permission,
    },
    .{
        .suggestion = .{ .command = "/export", .description = "export conversation as Markdown" },
        .action = .export_markdown,
    },
    .{
        .suggestion = .{ .command = "/reload-commands", .description = "rescan the commands directory" },
        .action = .reload_commands,
    },
};

pub const SkillInvocation = struct {
    skill_name: []const u8,
    prompt: []const u8,
};

pub const ComposerSuggestionPrefix = struct {
    kind: ComposerSuggestionKind,
    prefix: []const u8,
    token_end: usize,
};

pub const ComposerCompletionTrigger = enum {
    tab,
    enter,
};

pub fn parseSlashCommand(input: []const u8) ?SlashCommand {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "/")) return null;
    for (slash_command_entries) |entry| {
        if (std.mem.eql(u8, trimmed, entry.suggestion.command)) return entry.action;
    }
    if (std.mem.indexOfAny(u8, trimmed[1..], "/ \t\r\n") != null) return null;
    if (trimmed.len < "/help".len) return null;
    return .unknown;
}

pub fn exactBuiltinCommand(token: []const u8) ?SlashCommand {
    for (slash_command_entries) |entry| {
        if (std.mem.eql(u8, token, entry.suggestion.command)) return entry.action;
    }
    return null;
}

pub fn matchCustomCommandIndex(input: []const u8, custom: []const SlashCommandSuggestion) ?usize {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "/")) return null;
    const tok_end = slashCommandTokenEnd(trimmed);
    const tok = trimmed[0..tok_end];
    for (custom, 0..) |c, i| if (std.mem.eql(u8, tok, c.command)) return i;
    return null;
}

pub fn composerSuggestionPrefix(input: []const u8, cursor_raw: usize) ?ComposerSuggestionPrefix {
    if (input.len == 0) return null;
    const kind: ComposerSuggestionKind = switch (input[0]) {
        '/' => .slash_command,
        '$' => .skill,
        else => return null,
    };
    const cursor = @min(cursor_raw, input.len);
    if (cursor == 0) return null;
    const token_end = slashCommandTokenEnd(input);
    if (cursor > token_end) return null;
    return .{
        .kind = kind,
        .prefix = input[0..cursor],
        .token_end = token_end,
    };
}

pub fn slashCommandSuggestionPrefix(input: []const u8, cursor_raw: usize) ?[]const u8 {
    const prefix = composerSuggestionPrefix(input, cursor_raw) orelse return null;
    if (prefix.kind != .slash_command) return null;
    return prefix.prefix;
}

pub fn slashCommandTokenEnd(input: []const u8) usize {
    var end: usize = 0;
    while (end < input.len and !isAsciiWhitespace(input[end])) : (end += 1) {}
    return end;
}

pub fn slashCommandSuggestionCountForInput(input: []const u8, cursor: usize, custom: []const SlashCommandSuggestion) usize {
    const prefix = slashCommandSuggestionPrefix(input, cursor) orelse return 0;
    var count: usize = 0;
    for (slash_command_entries) |entry| {
        if (std.mem.startsWith(u8, entry.suggestion.command, prefix)) count += 1;
    }
    for (custom) |c| {
        if (std.mem.startsWith(u8, c.command, prefix)) count += 1;
    }
    return count;
}

pub fn slashCommandSuggestionAtForInput(input: []const u8, cursor: usize, suggestion_index: usize, custom: []const SlashCommandSuggestion) ?SlashCommandSuggestion {
    const prefix = slashCommandSuggestionPrefix(input, cursor) orelse return null;
    var match_index: usize = 0;
    for (slash_command_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.suggestion.command, prefix)) continue;
        if (match_index == suggestion_index) return entry.suggestion;
        match_index += 1;
    }
    for (custom) |c| {
        if (!std.mem.startsWith(u8, c.command, prefix)) continue;
        if (match_index == suggestion_index) return c;
        match_index += 1;
    }
    return null;
}

pub fn composerSuggestionCountForInput(
    input: []const u8,
    cursor: usize,
    skills: []const skill_registry.SkillMeta,
    custom: []const SlashCommandSuggestion,
) usize {
    const prefix = composerSuggestionPrefix(input, cursor) orelse return 0;
    return switch (prefix.kind) {
        .slash_command => slashCommandSuggestionCountForInput(input, cursor, custom),
        .skill => skillSuggestionCountForPrefix(prefix.prefix, skills),
    };
}

pub fn composerSuggestionAtForInput(
    input: []const u8,
    cursor: usize,
    skills: []const skill_registry.SkillMeta,
    custom: []const SlashCommandSuggestion,
    suggestion_index: usize,
) ?ComposerSuggestion {
    const prefix = composerSuggestionPrefix(input, cursor) orelse return null;
    return switch (prefix.kind) {
        .slash_command => if (slashCommandSuggestionAtForInput(input, cursor, suggestion_index, custom)) |suggestion| .{
            .kind = .slash_command,
            .text = suggestion.command,
            .description = suggestion.description,
        } else null,
        .skill => skillSuggestionAtForPrefix(prefix.prefix, skills, suggestion_index),
    };
}

pub fn skillSuggestionCountForPrefix(prefix: []const u8, skills: []const skill_registry.SkillMeta) usize {
    if (prefix.len == 0 or prefix[0] != '$') return 0;
    const skill_prefix = prefix[1..];
    var count: usize = 0;
    for (skills) |meta| {
        if (std.mem.startsWith(u8, meta.name, skill_prefix)) count += 1;
    }
    return count;
}

pub fn skillSuggestionAtForPrefix(
    prefix: []const u8,
    skills: []const skill_registry.SkillMeta,
    suggestion_index: usize,
) ?ComposerSuggestion {
    if (prefix.len == 0 or prefix[0] != '$') return null;
    const skill_prefix = prefix[1..];
    var match_index: usize = 0;
    for (skills) |meta| {
        if (!std.mem.startsWith(u8, meta.name, skill_prefix)) continue;
        if (match_index == suggestion_index) return .{
            .kind = .skill,
            .text = meta.name,
            .description = meta.description,
        };
        match_index += 1;
    }
    return null;
}

pub fn suggestionReplacementText(buf: []u8, suggestion: ComposerSuggestion, suffix: []const u8) ?[]const u8 {
    return switch (suggestion.kind) {
        .slash_command => suggestion.text,
        .skill => blk: {
            const needs_space = suffix.len == 0 or !isAsciiWhitespace(suffix[0]);
            const text = if (needs_space)
                std.fmt.bufPrint(buf, "${s} ", .{suggestion.text}) catch return null
            else
                std.fmt.bufPrint(buf, "${s}", .{suggestion.text}) catch return null;
            break :blk text;
        },
    };
}

pub fn parseSkillInvocation(input: []const u8) ?SkillInvocation {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "$") or trimmed.len < 2) return null;
    if (!(std.ascii.isAlphabetic(trimmed[1]) or trimmed[1] == '_')) return null;

    var end: usize = 1;
    var has_lower = false;
    while (end < trimmed.len) : (end += 1) {
        const ch = trimmed[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) break;
        if (std.ascii.isLower(ch)) has_lower = true;
    }

    if (end == 1) return null;
    if (!has_lower) return null;
    if (end >= trimmed.len or !isAsciiWhitespace(trimmed[end])) return null;
    const rest = std.mem.trim(u8, trimmed[end..], " \t\r\n");
    if (rest.len == 0) return null;
    return .{ .skill_name = trimmed[1..end], .prompt = rest };
}

pub fn isAsciiWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

// SkillMeta has fields: name []u8, description []u8, dir_name []u8, rel_dir []u8.
// Test fixture uses var so we can take mutable slices; string literals are []const u8
// but SkillMeta.name/description are []u8, so we use comptime-mutable arrays.
var test_skill_brainstorm_name = "brainstorm".*;
var test_skill_brainstorm_desc = "explore ideas".*;
var test_skill_brainstorm_dir = "".*;
var test_skill_brainstorm_rel = "".*;
var test_skill_build_name = "build".*;
var test_skill_build_desc = "build something".*;
var test_skill_build_dir = "".*;
var test_skill_build_rel = "".*;
var test_skill_review_name = "review".*;
var test_skill_review_desc = "review code".*;
var test_skill_review_dir = "".*;
var test_skill_review_rel = "".*;

const test_skills = [_]skill_registry.SkillMeta{
    .{ .name = &test_skill_brainstorm_name, .description = &test_skill_brainstorm_desc, .dir_name = &test_skill_brainstorm_dir, .rel_dir = &test_skill_brainstorm_rel },
    .{ .name = &test_skill_build_name, .description = &test_skill_build_desc, .dir_name = &test_skill_build_dir, .rel_dir = &test_skill_build_rel },
    .{ .name = &test_skill_review_name, .description = &test_skill_review_desc, .dir_name = &test_skill_review_dir, .rel_dir = &test_skill_review_rel },
};

test "parseSlashCommand recognizes new lifecycle commands" {
    try std.testing.expectEqual(SlashCommand.clear, parseSlashCommand("/clear").?);
    try std.testing.expectEqual(SlashCommand.resume_session, parseSlashCommand("/resume").?);
    try std.testing.expectEqual(SlashCommand.permission, parseSlashCommand("/permission").?);
    try std.testing.expectEqual(SlashCommand.export_markdown, parseSlashCommand("/export").?);
    try std.testing.expectEqual(SlashCommand.reload_commands, parseSlashCommand("/reload-commands").?);
}

test "parseSlashCommand recognizes exact, unknown, and rejects non-slash" {
    try std.testing.expectEqual(SlashCommand.skills, parseSlashCommand("/skills").?);
    try std.testing.expectEqual(SlashCommand.unknown, parseSlashCommand("/help").?);
    try std.testing.expectEqual(@as(?SlashCommand, null), parseSlashCommand("hello"));
    try std.testing.expectEqual(@as(?SlashCommand, null), parseSlashCommand("/has space"));
}

test "composerSuggestionPrefix distinguishes / and $ and rejects others" {
    try std.testing.expectEqual(ComposerSuggestionKind.slash_command, composerSuggestionPrefix("/sk", 3).?.kind);
    try std.testing.expectEqual(ComposerSuggestionKind.skill, composerSuggestionPrefix("$br", 3).?.kind);
    try std.testing.expectEqual(@as(?ComposerSuggestionPrefix, null), composerSuggestionPrefix("hi", 2));
}

test "slash command suggestions filter by prefix" {
    try std.testing.expectEqual(@as(usize, 1), slashCommandSuggestionCountForInput("/sk", 3, &.{}));
    const s = slashCommandSuggestionAtForInput("/sk", 3, 0, &.{}).?;
    try std.testing.expectEqualStrings("/skills", s.command);
}

test "slash suggestions include custom commands" {
    const custom = [_]SlashCommandSuggestion{.{ .command = "/review", .description = "review diff" }};
    try std.testing.expectEqual(@as(usize, 1), slashCommandSuggestionCountForInput("/rev", 4, &custom));
    try std.testing.expectEqualStrings("/review", slashCommandSuggestionAtForInput("/rev", 4, 0, &custom).?.command);
}

test "skill suggestions filter by prefix against a fixture" {
    try std.testing.expectEqual(@as(usize, 2), skillSuggestionCountForPrefix("$b", &test_skills));
    const sug = skillSuggestionAtForPrefix("$b", &test_skills, 1).?;
    try std.testing.expectEqual(ComposerSuggestionKind.skill, sug.kind);
    try std.testing.expectEqualStrings("build", sug.text);
}

test "parseSkillInvocation splits name and prompt" {
    const inv = parseSkillInvocation("$build make a thing").?;
    try std.testing.expectEqualStrings("build", inv.skill_name);
    try std.testing.expectEqualStrings("make a thing", inv.prompt);
    try std.testing.expectEqual(@as(?@TypeOf(inv), null), parseSkillInvocation("no dollar"));
}

test "suggestionReplacementText adds a space after a skill when needed" {
    var buf: [64]u8 = undefined;
    const sk = ComposerSuggestion{ .kind = .skill, .text = "build", .description = "" };
    try std.testing.expectEqualStrings("$build ", suggestionReplacementText(&buf, sk, "").?);
    try std.testing.expectEqualStrings("$build", suggestionReplacementText(&buf, sk, " x").?);
    const cmd = ComposerSuggestion{ .kind = .slash_command, .text = "/skills", .description = "" };
    try std.testing.expectEqualStrings("/skills", suggestionReplacementText(&buf, cmd, "").?);
}
