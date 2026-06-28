//! Pure slash-command / skill / composer suggestion parsing, extracted from
//! session.zig. Text + skill metadata -> suggestion data; no Session state.
const std = @import("std");
const skill_registry = @import("../../skill/registry.zig");
const input_text = @import("input_text.zig");
const research_commands = @import("../../research/commands.zig");

/// Max bytes the composer input buffer can hold. Mirrors
/// `ai_chat.INPUT_PROMPT_MAX_BYTES` exactly so the editable buffer semantics
/// (truncation on overflow) are identical when Session delegates here.
pub const INPUT_PROMPT_MAX_BYTES: usize = 64 * 1024;

/// The editable text + cursor of the AI chat input box, with the PURE editing
/// operations (no mutex, no scroll/suggestion/selection/history side effects —
/// those stay in `ai_chat.Session`). The byte-level logic here is a faithful
/// copy of Session's `insertInputBytesLocked` / boundary deletes / cursor moves
/// so routing Session through these helpers preserves behavior exactly.
///
/// The buffer is a fixed array (no allocation), matching Session's
/// `input_buf: [INPUT_PROMPT_MAX_BYTES]u8`. All ops are UTF-8 aware where the
/// current Session code is.
pub const Composer = struct {
    buf: [INPUT_PROMPT_MAX_BYTES]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    /// The current editable text (const view into the buffer).
    pub fn text(self: *const Composer) []const u8 {
        return self.buf[0..self.len];
    }

    /// True when the trimmed text is non-empty, i.e. a submit would do work.
    /// Mirrors the `prompt_raw.len == 0` early-return guard in Session.submit.
    pub fn canSubmit(self: *const Composer) bool {
        return std.mem.trim(u8, self.text(), " \t\r\n").len != 0;
    }

    /// Clamp the cursor onto a UTF-8 boundary within [0, len]. Mirrors
    /// Session.clampInputCursorLocked.
    pub fn clampCursor(self: *Composer) void {
        if (self.cursor > self.len) self.cursor = self.len;
        while (self.cursor > 0 and self.cursor < self.len and (self.buf[self.cursor] & 0xC0) == 0x80) {
            self.cursor -= 1;
        }
    }

    /// Insert `bytes` at the cursor, truncating to fit the buffer and to a
    /// UTF-8 boundary. Mirrors Session.insertInputBytesLocked (sans the
    /// scroll/suggestion side effects). Cursor advances past the inserted run.
    pub fn insertText(self: *Composer, bytes: []const u8) void {
        self.clampCursor();
        var n = @min(bytes.len, self.buf.len - self.len);
        while (n > 0 and n < bytes.len and (bytes[n] & 0xC0) == 0x80) {
            n -= 1;
        }
        if (n == 0) return;
        if (self.cursor < self.len) {
            std.mem.copyBackwards(
                u8,
                self.buf[self.cursor + n .. self.len + n],
                self.buf[self.cursor..self.len],
            );
        }
        @memcpy(self.buf[self.cursor..][0..n], bytes[0..n]);
        self.len += n;
        self.cursor += n;
    }

    /// Delete the UTF-8 codepoint before the cursor. Mirrors the
    /// non-select-all path of Session.backspaceInput.
    pub fn backspace(self: *Composer) void {
        self.clampCursor();
        if (self.cursor == 0) return;
        const start = input_text.previousUtf8Boundary(self.text(), self.cursor);
        self.deleteRange(start, self.cursor);
        self.cursor = start;
    }

    /// Delete the UTF-8 codepoint after the cursor. Mirrors the
    /// non-select-all path of Session.deleteInput.
    pub fn deleteForward(self: *Composer) void {
        self.clampCursor();
        if (self.cursor >= self.len) return;
        const end = input_text.nextUtf8Boundary(self.text(), self.cursor);
        self.deleteRange(self.cursor, end);
    }

    /// Move the cursor one UTF-8 codepoint left. Mirrors the cursor math in
    /// Session.moveInputCursorLeft.
    pub fn moveLeft(self: *Composer) void {
        self.cursor = cursorLeft(self.text(), self.cursor);
    }

    /// Move the cursor one UTF-8 codepoint right. Mirrors the cursor math in
    /// Session.moveInputCursorRight.
    pub fn moveRight(self: *Composer) void {
        self.cursor = cursorRight(self.text(), self.cursor);
    }

    /// Empty the buffer and reset the cursor. Mirrors the buffer/cursor part of
    /// Session.clearSubmittedInputLocked.
    pub fn clear(self: *Composer) void {
        self.len = 0;
        self.cursor = 0;
    }

    /// Replace the whole input and leave the cursor at the end.
    pub fn replaceText(self: *Composer, bytes: []const u8) void {
        self.clear();
        self.insertText(bytes);
    }

    /// Replace bytes before `prefix_end` with `replacement`, preserving the
    /// suffix after `prefix_end`. Used by completion acceptance.
    pub fn replacePrefix(self: *Composer, prefix_end: usize, replacement: []const u8) bool {
        self.clampCursor();
        if (prefix_end > self.len) return false;
        const suffix_len = self.len - prefix_end;
        if (replacement.len + suffix_len > self.buf.len) return false;

        if (replacement.len > prefix_end) {
            std.mem.copyBackwards(
                u8,
                self.buf[replacement.len .. replacement.len + suffix_len],
                self.buf[prefix_end..self.len],
            );
        } else if (replacement.len < prefix_end) {
            std.mem.copyForwards(
                u8,
                self.buf[replacement.len .. replacement.len + suffix_len],
                self.buf[prefix_end..self.len],
            );
        }
        @memcpy(self.buf[0..replacement.len], replacement);
        self.len = replacement.len + suffix_len;
        self.cursor = replacement.len;
        return true;
    }

    /// Delete bytes in [start, end) from the buffer, shifting the tail down.
    /// Mirrors Session.deleteInputRangeLocked.
    fn deleteRange(self: *Composer, start: usize, end: usize) void {
        if (start >= end or end > self.len) return;
        const removed = end - start;
        if (end < self.len) {
            std.mem.copyForwards(
                u8,
                self.buf[start .. self.len - removed],
                self.buf[end..self.len],
            );
        }
        self.len -= removed;
        if (self.cursor > self.len) self.cursor = self.len;
    }
};

/// Pure cursor-left primitive: previous UTF-8 boundary. Shared by
/// Composer.moveLeft and Session.moveInputCursorLeft.
pub fn cursorLeft(text_bytes: []const u8, cursor: usize) usize {
    return input_text.previousUtf8Boundary(text_bytes, cursor);
}

/// Pure cursor-right primitive: next UTF-8 boundary. Shared by
/// Composer.moveRight and Session.moveInputCursorRight.
pub fn cursorRight(text_bytes: []const u8, cursor: usize) usize {
    return input_text.nextUtf8Boundary(text_bytes, cursor);
}

pub const SlashCommand = enum {
    skills,
    commands,
    reload_skills,
    reload_commands,
    clear,
    rewind_picker,
    resume_session,
    permission,
    cwd,
    export_markdown,
    distill,
    loop,
    watch,
    remember,
    memory,
    forget,
    model_switch,
    btw,
    unknown,
};

pub const WebCommand = research_commands.Command;

/// Reserved `$`-prefixed commands shown in the same dropdown as skills.
pub const ReservedWebCommand = research_commands.Entry;
pub const reserved_web_commands = research_commands.entries;

/// Match the first whitespace-delimited token against a reserved `$` command.
/// `token` is e.g. "$websearch" (the value of `first_tok` in Session.submit).
pub fn parseWebCommand(token: []const u8) ?WebCommand {
    return research_commands.parseToken(token);
}

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
        .suggestion = .{ .command = "/clear", .description = "clear the conversation context" },
        .action = .clear,
    },
    .{
        .suggestion = .{ .command = "/rewind", .description = "choose an earlier user prompt to edit" },
        .action = .rewind_picker,
    },
    .{
        .suggestion = .{ .command = "/resume", .description = "resume a saved Copilot conversation or CLI session" },
        .action = .resume_session,
    },
    .{
        .suggestion = .{ .command = "/permission", .description = "view or set agent permission" },
        .action = .permission,
    },
    .{
        .suggestion = .{ .command = "/cwd", .description = "set the conversation working directory" },
        .action = .cwd,
    },
    .{
        .suggestion = .{ .command = "/export", .description = "export conversation as Markdown" },
        .action = .export_markdown,
    },
    .{
        .suggestion = .{ .command = "/distill", .description = "distill this conversation into a reusable skill" },
        .action = .distill,
    },
    .{
        .suggestion = .{ .command = "/reload-commands", .description = "rescan the commands directory" },
        .action = .reload_commands,
    },
    .{
        .suggestion = .{ .command = "/loop", .description = "repeat, list, or stop interval prompts" },
        .action = .loop,
    },
    .{
        .suggestion = .{ .command = "/watch", .description = "schedule, list, or stop timed prompts" },
        .action = .watch,
    },
    .{
        .suggestion = .{ .command = "/remember", .description = "remember a fact long-term" },
        .action = .remember,
    },
    .{
        .suggestion = .{ .command = "/memory", .description = "list remembered facts" },
        .action = .memory,
    },
    .{
        .suggestion = .{ .command = "/forget", .description = "delete a remembered fact by name" },
        .action = .forget,
    },
    .{
        .suggestion = .{ .command = "/model", .description = "switch the model / AI profile" },
        .action = .model_switch,
    },
    .{
        .suggestion = .{ .command = "/btw", .description = "show current progress without adding context" },
        .action = .btw,
    },
    .{
        .suggestion = .{ .command = "/verbos", .description = "show detailed current progress" },
        .action = .btw,
    },
    .{
        .suggestion = .{ .command = "/verbose", .description = "show detailed current progress" },
        .action = .btw,
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
    if (isDistillAlias(trimmed)) return .distill;
    if (memoryCommandAlias(trimmed)) |c| return c;
    if (modelCommandAlias(trimmed)) |c| return c;
    for (slash_command_entries) |entry| {
        if (std.mem.eql(u8, trimmed, entry.suggestion.command)) return entry.action;
    }
    if (std.mem.indexOfAny(u8, trimmed[1..], "/ \t\r\n") != null) return null;
    if (trimmed.len < "/help".len) return null;
    return .unknown;
}

pub fn exactBuiltinCommand(token: []const u8) ?SlashCommand {
    if (isDistillAlias(token)) return .distill;
    if (memoryCommandAlias(token)) |c| return c;
    if (modelCommandAlias(token)) |c| return c;
    for (slash_command_entries) |entry| {
        if (std.mem.eql(u8, token, entry.suggestion.command)) return entry.action;
    }
    return null;
}

pub fn isDistillAlias(token: []const u8) bool {
    return std.mem.eql(u8, token, "/distill") or std.mem.eql(u8, token, "/沉淀");
}

pub fn memoryCommandAlias(token: []const u8) ?SlashCommand {
    if (std.mem.eql(u8, token, "/记住")) return .remember;
    if (std.mem.eql(u8, token, "/记忆")) return .memory;
    if (std.mem.eql(u8, token, "/忘记")) return .forget;
    return null;
}

pub fn modelCommandAlias(token: []const u8) ?SlashCommand {
    if (std.mem.eql(u8, token, "/模型")) return .model_switch;
    return null;
}

pub const CwdArg = union(enum) {
    show,
    reset,
    set: []const u8,
};

/// Classify a `/cwd` argument: empty => show current, `reset`/`default`/`clear`
/// => clear the override, anything else => set that path.
pub fn parseCwdArg(arg: []const u8) CwdArg {
    const t = std.mem.trim(u8, arg, " \t\r\n");
    if (t.len == 0) return .show;
    if (std.mem.eql(u8, t, "reset") or std.mem.eql(u8, t, "default") or std.mem.eql(u8, t, "clear")) return .reset;
    return .{ .set = t };
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
    for (reserved_web_commands) |rc| {
        if (std.mem.startsWith(u8, rc.name, skill_prefix)) count += 1;
    }
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
    for (reserved_web_commands) |rc| {
        if (!std.mem.startsWith(u8, rc.name, skill_prefix)) continue;
        if (match_index == suggestion_index) return .{
            .kind = .skill,
            .text = rc.name,
            .description = rc.description,
        };
        match_index += 1;
    }
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

test "parseSlashCommand recognizes loop and watch" {
    try std.testing.expectEqual(SlashCommand.loop, parseSlashCommand("/loop").?);
    try std.testing.expectEqual(SlashCommand.watch, parseSlashCommand("/watch").?);
    try std.testing.expectEqual(SlashCommand.loop, exactBuiltinCommand("/loop").?);
    try std.testing.expectEqual(SlashCommand.watch, exactBuiltinCommand("/watch").?);
}

test "parseSlashCommand recognizes new lifecycle commands" {
    try std.testing.expectEqual(SlashCommand.clear, parseSlashCommand("/clear").?);
    try std.testing.expectEqual(SlashCommand.resume_session, parseSlashCommand("/resume").?);
    try std.testing.expectEqual(SlashCommand.permission, parseSlashCommand("/permission").?);
    try std.testing.expectEqual(SlashCommand.export_markdown, parseSlashCommand("/export").?);
    try std.testing.expectEqual(SlashCommand.reload_commands, parseSlashCommand("/reload-commands").?);
    try std.testing.expectEqual(SlashCommand.distill, parseSlashCommand("/distill").?);
    try std.testing.expectEqual(SlashCommand.distill, parseSlashCommand("/沉淀").?);
    try std.testing.expectEqual(SlashCommand.distill, exactBuiltinCommand("/沉淀").?);
    try std.testing.expectEqual(@as(?SlashCommand, null), parseSlashCommand("/沉淀 主题"));
}

test "parseSlashCommand recognizes model switch and alias" {
    try std.testing.expectEqual(SlashCommand.model_switch, parseSlashCommand("/model").?);
    try std.testing.expectEqual(SlashCommand.model_switch, parseSlashCommand("/模型").?);
    try std.testing.expectEqual(SlashCommand.model_switch, exactBuiltinCommand("/model").?);
    try std.testing.expectEqual(SlashCommand.model_switch, exactBuiltinCommand("/模型").?);
    // "/model GPT-5" is dispatched by exactBuiltinCommand on the first token only:
    try std.testing.expectEqual(SlashCommand.model_switch, exactBuiltinCommand("/model").?);
    // parseSlashCommand on the whole string with an arg must NOT match (has a space):
    try std.testing.expectEqual(@as(?SlashCommand, null), parseSlashCommand("/model GPT-5"));
}

test "parseSlashCommand recognizes exact, unknown, and rejects non-slash" {
    try std.testing.expectEqual(SlashCommand.skills, parseSlashCommand("/skills").?);
    try std.testing.expectEqual(SlashCommand.btw, parseSlashCommand("/btw").?);
    try std.testing.expectEqual(SlashCommand.btw, parseSlashCommand("/verbos").?);
    try std.testing.expectEqual(SlashCommand.btw, parseSlashCommand("/verbose").?);
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
    try std.testing.expectEqual(slash_command_entries.len, slashCommandSuggestionCountForInput("/", 1, &.{}));
    try std.testing.expectEqual(@as(usize, 1), slashCommandSuggestionCountForInput("/di", 3, &.{}));
    try std.testing.expectEqualStrings("/distill", slashCommandSuggestionAtForInput("/di", 3, 0, &.{}).?.command);
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

test "parseWebCommand matches only the $websearch token" {
    try std.testing.expectEqual(WebCommand.websearch, parseWebCommand("$websearch").?);
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("$websearchx"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("$web"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("/websearch"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("websearch"));
}

test "reserved $websearch appears in the $ suggestion dropdown" {
    try std.testing.expectEqual(@as(usize, 2), skillSuggestionCountForPrefix("$web", &.{}));
    const s = skillSuggestionAtForPrefix("$web", &.{}, 0).?;
    try std.testing.expectEqual(ComposerSuggestionKind.skill, s.kind);
    try std.testing.expectEqualStrings("websearch", s.text);
}

test "parseWebCommand matches $webread and still matches $websearch" {
    try std.testing.expectEqual(WebCommand.webread, parseWebCommand("$webread").?);
    try std.testing.expectEqual(WebCommand.websearch, parseWebCommand("$websearch").?);
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("$webreadx"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("/webread"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("webread"));
}

test "parseWebCommand matches $pubmed" {
    try std.testing.expectEqual(WebCommand.pubmed, parseWebCommand("$pubmed").?);
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("$pubmedx"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("pubmed"));
}

test "reserved $pubmed appears in reserved web commands" {
    var found = false;
    for (reserved_web_commands) |rc| {
        if (std.mem.eql(u8, rc.name, "pubmed")) found = true;
    }
    try std.testing.expect(found);
}

test "parseSlashCommand recognizes memory commands and aliases" {
    try std.testing.expectEqual(SlashCommand.remember, parseSlashCommand("/remember").?);
    try std.testing.expectEqual(SlashCommand.remember, parseSlashCommand("/记住").?);
    try std.testing.expectEqual(SlashCommand.memory, parseSlashCommand("/memory").?);
    try std.testing.expectEqual(SlashCommand.memory, parseSlashCommand("/记忆").?);
    try std.testing.expectEqual(SlashCommand.forget, parseSlashCommand("/forget").?);
    try std.testing.expectEqual(SlashCommand.forget, parseSlashCommand("/忘记").?);
}

test "exactBuiltinCommand resolves memory aliases for arg-bearing commands" {
    try std.testing.expectEqual(SlashCommand.remember, exactBuiltinCommand("/记住").?);
    try std.testing.expectEqual(SlashCommand.forget, exactBuiltinCommand("/忘记").?);
}

test "parseCwdArg classifies show, reset, and set" {
    try std.testing.expect(parseCwdArg("") == .show);
    try std.testing.expect(parseCwdArg("   ") == .show);
    try std.testing.expect(parseCwdArg("reset") == .reset);
    try std.testing.expect(parseCwdArg("default") == .reset);
    switch (parseCwdArg("  /home/u/proj  ")) {
        .set => |p| try std.testing.expectEqualStrings("/home/u/proj", p),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(exactBuiltinCommand("/cwd") != null);
    try std.testing.expect(exactBuiltinCommand("/cwd").? == .cwd);
}

test "Composer inserts ascii at the cursor and advances" {
    var c: Composer = .{};
    c.insertText("hello");
    try std.testing.expectEqualStrings("hello", c.text());
    try std.testing.expectEqual(@as(usize, 5), c.cursor);
    // Insert in the middle.
    c.cursor = 2;
    c.insertText("XY");
    try std.testing.expectEqualStrings("heXYllo", c.text());
    try std.testing.expectEqual(@as(usize, 4), c.cursor);
}

test "Composer inserts utf-8 without splitting a codepoint" {
    var c: Composer = .{};
    c.insertText("a\u{00e9}b"); // 'a', 'é' (2 bytes), 'b'
    try std.testing.expectEqualStrings("a\u{00e9}b", c.text());
    try std.testing.expectEqual(@as(usize, 4), c.len);
    try std.testing.expectEqual(@as(usize, 4), c.cursor);
}

test "Composer backspace deletes a whole utf-8 codepoint" {
    var c: Composer = .{};
    c.insertText("a\u{00e9}"); // 'a' + 'é'
    c.backspace();
    try std.testing.expectEqualStrings("a", c.text());
    try std.testing.expectEqual(@as(usize, 1), c.cursor);
    c.backspace();
    try std.testing.expectEqualStrings("", c.text());
    try std.testing.expectEqual(@as(usize, 0), c.cursor);
    // Backspace at the start is a no-op.
    c.backspace();
    try std.testing.expectEqual(@as(usize, 0), c.len);
}

test "Composer deleteForward removes the codepoint after the cursor" {
    var c: Composer = .{};
    c.insertText("a\u{00e9}b");
    c.cursor = 1; // before 'é'
    c.deleteForward();
    try std.testing.expectEqualStrings("ab", c.text());
    try std.testing.expectEqual(@as(usize, 1), c.cursor);
    // At end is a no-op.
    c.cursor = c.len;
    c.deleteForward();
    try std.testing.expectEqualStrings("ab", c.text());
}

test "Composer cursor left/right step over multi-byte runes" {
    var c: Composer = .{};
    c.insertText("a\u{00e9}b"); // cursor at 4 (end)
    c.moveLeft();
    try std.testing.expectEqual(@as(usize, 3), c.cursor); // before 'b'
    c.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), c.cursor); // before 'é' (skips its 2 bytes)
    c.moveLeft();
    try std.testing.expectEqual(@as(usize, 0), c.cursor);
    c.moveLeft(); // clamp at 0
    try std.testing.expectEqual(@as(usize, 0), c.cursor);
    c.moveRight();
    try std.testing.expectEqual(@as(usize, 1), c.cursor);
    c.moveRight();
    try std.testing.expectEqual(@as(usize, 3), c.cursor); // past 'é'
    c.moveRight();
    try std.testing.expectEqual(@as(usize, 4), c.cursor);
    c.moveRight(); // clamp at len
    try std.testing.expectEqual(@as(usize, 4), c.cursor);
}

test "Composer clear empties buffer and resets cursor" {
    var c: Composer = .{};
    c.insertText("some text");
    c.clear();
    try std.testing.expectEqualStrings("", c.text());
    try std.testing.expectEqual(@as(usize, 0), c.len);
    try std.testing.expectEqual(@as(usize, 0), c.cursor);
}

test "Composer canSubmit is false for empty / whitespace-only input" {
    var c: Composer = .{};
    try std.testing.expect(!c.canSubmit());
    c.insertText("   \t\n");
    try std.testing.expect(!c.canSubmit());
    c.insertText("hi");
    try std.testing.expect(c.canSubmit());
}

test "Composer insertText truncates at the buffer boundary without splitting utf-8" {
    var c: Composer = .{};
    // Fill the buffer one byte short of full, then try to insert a 2-byte rune.
    c.len = INPUT_PROMPT_MAX_BYTES - 1;
    c.cursor = c.len;
    @memset(c.buf[0..c.len], 'x');
    c.insertText("\u{00e9}"); // would split the codepoint -> rejected entirely
    try std.testing.expectEqual(@as(usize, INPUT_PROMPT_MAX_BYTES - 1), c.len);
    // A single ascii byte fits exactly.
    c.insertText("z");
    try std.testing.expectEqual(@as(usize, INPUT_PROMPT_MAX_BYTES), c.len);
    try std.testing.expectEqual(@as(u8, 'z'), c.buf[INPUT_PROMPT_MAX_BYTES - 1]);
}

test "Composer replaceText replaces the whole buffer" {
    var c: Composer = .{};
    c.insertText("draft");
    c.moveLeft();
    c.replaceText("new text");
    try std.testing.expectEqualStrings("new text", c.text());
    try std.testing.expectEqual(@as(usize, "new text".len), c.cursor);
}

test "Composer replacePrefix keeps the suffix and moves cursor after replacement" {
    var c: Composer = .{};
    c.insertText("/sk trailing");
    try std.testing.expect(c.replacePrefix("/sk".len, "$skill "));
    try std.testing.expectEqualStrings("$skill  trailing", c.text());
    try std.testing.expectEqual(@as(usize, "$skill ".len), c.cursor);
}

test "ai chat Session owns editable input through Composer" {
    const source = @embedFile("session.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "composer: ai_chat_composer.Composer") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "input_buf: [INPUT_PROMPT_MAX_BYTES]u8") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "input_len: usize") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "input_cursor: usize") == null);
}
