//! Composer editing for a conversation `Session`: the input buffer, its
//! cursor and scroll row, prompt-history recall, and suggestion completion.
//!
//! The buffer and cursor are `Session` fields guarded by `Session.mutex`;
//! functions ending in `Locked` expect the caller to hold it. The pure text
//! geometry (wrapping, visual rows, UTF-8 boundaries) lives in input_text.zig
//! and the suggestion model in composer.zig. Key dispatch stays in
//! session.zig (`handleKeyWithWrapCols`), which calls into this file.
const std = @import("std");
const ai_chat = @import("session.zig");
const ai_chat_input_text = @import("input_text.zig");
const ai_chat_composer = @import("composer.zig");
const input_key = @import("../../input/key.zig");

const Session = ai_chat.Session;

const inputWrappedLineCount = ai_chat_input_text.inputWrappedLineCount;
const visualCursorPosition = ai_chat_input_text.visualCursorPosition;
const byteOffsetForVisualPosition = ai_chat_input_text.byteOffsetForVisualPosition;
const ComposerCompletionTrigger = ai_chat_composer.ComposerCompletionTrigger;
const composerSuggestionPrefix = ai_chat_composer.composerSuggestionPrefix;
const suggestionReplacementText = ai_chat_composer.suggestionReplacementText;
const composerSuggestionCountForInput = ai_chat_composer.composerSuggestionCountForInput;
const composerSuggestionAtForInput = ai_chat_composer.composerSuggestionAtForInput;

pub fn inputScrollRow(self: *Session) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.input_scroll_row;
}

pub fn scrollInputRows(self: *Session, delta_rows: i32, max_cols_raw: usize, visible_rows_raw: usize) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    const before = self.input_scroll_row;
    const max_row = maxInputScrollRowLocked(self, max_cols_raw, visible_rows_raw);
    var next = @min(self.input_scroll_row, max_row);
    if (delta_rows < 0) {
        const amount: usize = @intCast(-delta_rows);
        next -|= amount;
    } else if (delta_rows > 0) {
        const amount: usize = @intCast(delta_rows);
        next = @min(max_row, next +| amount);
    }
    self.input_scroll_row = next;
    if (before != next) self.input_scroll_follow_cursor = false;
    return before != next;
}

pub fn setInputScrollRow(self: *Session, row: usize, max_cols_raw: usize, visible_rows_raw: usize) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    const before = self.input_scroll_row;
    const max_row = maxInputScrollRowLocked(self, max_cols_raw, visible_rows_raw);
    self.input_scroll_row = @min(row, max_row);
    if (max_row > 0) self.input_scroll_follow_cursor = false;
    return before != self.input_scroll_row;
}

pub fn backspaceInput(self: *Session) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    clearComposerHistoryNavigationLocked(self);
    if (self.input_select_all) {
        self.composer.clear();
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
        self.clearSelectionLocked();
        return;
    }
    self.transcript_select_all = false;
    self.transcript_selection = null;
    const old_len = self.composer.len;
    const old_cursor = self.composer.cursor;
    self.composer.backspace();
    if (self.composer.len == old_len and self.composer.cursor == old_cursor) return;
    self.input_scroll_follow_cursor = true;
}

pub fn deleteInput(self: *Session) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    clearComposerHistoryNavigationLocked(self);
    if (self.input_select_all) {
        self.composer.clear();
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
        self.clearSelectionLocked();
        return;
    }
    self.transcript_select_all = false;
    self.transcript_selection = null;
    const old_len = self.composer.len;
    const old_cursor = self.composer.cursor;
    self.composer.deleteForward();
    if (self.composer.len == old_len and self.composer.cursor == old_cursor) return;
    self.input_scroll_follow_cursor = true;
}

pub fn moveInputCursorLeft(self: *Session) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.clearSelectionLocked();
    self.composer.moveLeft();
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
}

pub fn moveInputCursorRight(self: *Session) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.clearSelectionLocked();
    self.composer.moveRight();
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
}

pub fn moveInputCursorHome(self: *Session) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.clearSelectionLocked();
    self.composer.cursor = 0;
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
}

pub fn moveInputCursorEnd(self: *Session) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.clearSelectionLocked();
    self.composer.cursor = self.composer.len;
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
}

/// Place the caret at `offset` (clamped to a UTF-8 boundary), e.g. from a
/// mouse click in the composer.
pub fn setInputCursor(self: *Session, offset: usize) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.clearSelectionLocked();
    self.composer.cursor = offset;
    clampInputCursorLocked(self);
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
}

pub fn moveInputCursorVertical(self: *Session, max_cols_raw: usize, delta: i32) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.clearSelectionLocked();
    clampInputCursorLocked(self);

    const text = self.input();
    const max_cols = @max(@as(usize, 1), max_cols_raw);
    const current = visualCursorPosition(text, self.composer.cursor, max_cols);
    if (delta < 0 and current.row == 0) return;
    const target_row = if (delta < 0) current.row - 1 else current.row + 1;
    self.composer.cursor = byteOffsetForVisualPosition(text, target_row, current.col, max_cols) orelse return;
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
}

pub fn navigateComposerHistory(self: *Session, max_cols_raw: usize, delta: i32) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    const prompt_count = composerHistoryPromptCountLocked(self);
    if (prompt_count == 0 or delta == 0) return false;
    clampInputCursorLocked(self);

    const max_cols = @max(@as(usize, 1), max_cols_raw);
    const text = self.input();
    const current = visualCursorPosition(text, self.composer.cursor, max_cols);
    const rows = inputWrappedLineCount(text, max_cols);

    if (delta < 0) {
        if (current.row != 0) return false;
        if (!self.composer_history_active) {
            saveComposerHistoryDraftLocked(self);
            self.composer_history_active = true;
            self.composer_history_selected = prompt_count - 1;
        } else if (self.composer_history_selected > 0) {
            self.composer_history_selected -= 1;
        }
        return restoreComposerHistoryPromptLocked(self, self.composer_history_selected);
    }

    if (current.row + 1 < rows or !self.composer_history_active) return false;
    if (self.composer_history_selected + 1 < prompt_count) {
        self.composer_history_selected += 1;
        return restoreComposerHistoryPromptLocked(self, self.composer_history_selected);
    }

    restoreComposerHistoryDraftLocked(self);
    clearComposerHistoryNavigationLocked(self);
    return true;
}

pub fn moveComposerSuggestionSelection(self: *Session, delta: i32) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.ensureSkillSuggestionsForInputLocked();

    const count = composerSuggestionCountForInput(self.input(), self.composer.cursor, self.skill_suggestions, self.customCommandSuggestions());
    if (count == 0) return false;
    const current = @min(self.suggestion_selected, count - 1);
    self.suggestion_selected = if (delta < 0)
        if (current == 0) count - 1 else current - 1
    else if (delta > 0)
        (current + 1) % count
    else
        current;
    self.clearSelectionLocked();
    return true;
}

pub fn completeComposerSuggestion(self: *Session, trigger: ComposerCompletionTrigger) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.ensureSkillSuggestionsForInputLocked();

    const prefix = composerSuggestionPrefix(self.input(), self.composer.cursor) orelse return false;
    const count = composerSuggestionCountForInput(self.input(), self.composer.cursor, self.skill_suggestions, self.customCommandSuggestions());
    if (count == 0) return false;
    const selected = @min(self.suggestion_selected, count - 1);
    const suggestion = composerSuggestionAtForInput(self.input(), self.composer.cursor, self.skill_suggestions, self.customCommandSuggestions(), selected) orelse return false;
    if (trigger == .enter and suggestion.kind == .slash_command and std.mem.eql(u8, prefix.prefix, suggestion.text)) {
        return false;
    }

    var replacement_buf: [256]u8 = undefined;
    const replacement = suggestionReplacementText(&replacement_buf, suggestion, self.input()[prefix.token_end..]) orelse return false;
    clearComposerHistoryNavigationLocked(self);
    if (!self.composer.replacePrefix(prefix.token_end, replacement)) return false;
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
    self.clearSelectionLocked();
    return true;
}

pub fn insertInputBytesLocked(self: *Session, text: []const u8) void {
    const old_len = self.composer.len;
    const old_cursor = self.composer.cursor;
    self.composer.insertText(text);
    if (self.composer.len == old_len and self.composer.cursor == old_cursor) return;
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
}

fn clampInputCursorLocked(self: *Session) void {
    self.composer.clampCursor();
}

fn maxInputScrollRowLocked(self: *Session, max_cols_raw: usize, visible_rows_raw: usize) usize {
    const rows = inputWrappedLineCount(self.input(), max_cols_raw);
    const visible_rows = @max(@as(usize, 1), visible_rows_raw);
    return if (rows > visible_rows) rows - visible_rows else 0;
}

pub fn clearSubmittedInputLocked(self: *Session) void {
    clearComposerHistoryNavigationLocked(self);
    self.composer.clear();
    self.input_scroll_row = 0;
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
    self.clearSelectionLocked();
}

/// 用 text 覆盖输入框内容，光标置于末尾。纯缓冲区操作、无 IO。
pub fn setInputTextLocked(self: *Session, text: []const u8) void {
    clearComposerHistoryNavigationLocked(self);
    replaceInputTextLocked(self, text);
}

fn replaceInputTextLocked(self: *Session, text: []const u8) void {
    self.composer.replaceText(text);
    self.input_scroll_row = 0;
    self.input_scroll_follow_cursor = true;
    self.suggestion_selected = 0;
    self.clearSelectionLocked();
}

pub fn clearComposerHistoryNavigationLocked(self: *Session) void {
    self.composer_history_active = false;
    self.composer_history_selected = 0;
    self.composer_history_draft_len = 0;
    self.composer_history_draft_cursor = 0;
}

fn saveComposerHistoryDraftLocked(self: *Session) void {
    const len = @min(self.composer.len, self.composer_history_draft_buf.len);
    if (len > 0) @memcpy(self.composer_history_draft_buf[0..len], self.composer.buf[0..len]);
    self.composer_history_draft_len = len;
    self.composer_history_draft_cursor = @min(self.composer.cursor, len);
}

fn restoreComposerHistoryDraftLocked(self: *Session) void {
    const draft = self.composer_history_draft_buf[0..self.composer_history_draft_len];
    const cursor = self.composer_history_draft_cursor;
    replaceInputTextLocked(self, draft);
    self.composer.cursor = @min(cursor, self.composer.len);
    self.composer.clampCursor();
    self.input_scroll_follow_cursor = true;
}

fn composerHistoryPromptCountLocked(self: *Session) usize {
    var n: usize = 0;
    for (self.messages.items) |msg| {
        if (msg.role == .user) n += 1;
    }
    return n;
}

fn composerHistoryPromptMessageIndexLocked(self: *Session, n: usize) usize {
    var seen: usize = 0;
    for (self.messages.items, 0..) |msg, i| {
        if (msg.role == .user) {
            if (seen == n) return i;
            seen += 1;
        }
    }
    return self.messages.items.len;
}

fn restoreComposerHistoryPromptLocked(self: *Session, selected: usize) bool {
    const idx = composerHistoryPromptMessageIndexLocked(self, selected);
    if (idx >= self.messages.items.len) return false;
    replaceInputTextLocked(self, self.messages.items[idx].content);
    return true;
}

test "ai chat input cursor supports insertion and deletion in the middle" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("hello");
    try std.testing.expectEqual(@as(usize, 5), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.arrow_left });
    session.handleKey(.{ .key = input_key.Key.arrow_left });
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());

    session.handleChar('X');
    try std.testing.expectEqualStrings("helXlo", session.input());
    try std.testing.expectEqual(@as(usize, 4), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.backspace });
    try std.testing.expectEqualStrings("hello", session.input());
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.delete });
    try std.testing.expectEqualStrings("helo", session.input());
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());
}

test "ai chat input handles platform-neutral key events" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("hello");

    session.handleKey(.{ .key = input_key.Key.arrow_left });
    session.handleKey(.{ .key = input_key.Key.backspace });

    try std.testing.expectEqualStrings("helo", session.input());
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());
}

test "ai chat input accepts prompts longer than the old 8 KiB limit" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };

    const prompt = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(prompt);
    @memset(prompt, 'a');

    session.appendInputText(prompt);

    try std.testing.expectEqual(prompt.len, session.input().len);
    try std.testing.expectEqualStrings(prompt, session.input());
    try std.testing.expectEqual(prompt.len, session.inputCursor());
}

test "ai chat input cursor moves by utf8 codepoint boundaries" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("你a");
    session.handleKey(.{ .key = input_key.Key.arrow_left });
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());
    session.handleKey(.{ .key = input_key.Key.backspace });
    try std.testing.expectEqualStrings("a", session.input());
    try std.testing.expectEqual(@as(usize, 0), session.inputCursor());
}

test "ai chat input cursor moves vertically across explicit lines" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("abc\ndefg\nhi");

    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKey(.{ .key = input_key.Key.arrow_down });
    try std.testing.expectEqual(@as(usize, 4), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.arrow_right });
    session.handleKey(.{ .key = input_key.Key.arrow_right });
    try std.testing.expectEqual(@as(usize, 6), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.arrow_down });
    try std.testing.expectEqual(@as(usize, 11), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.arrow_up });
    try std.testing.expectEqual(@as(usize, 6), session.inputCursor());
}

test "ai chat input cursor moves vertically across wrapped rows" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("abcdefghijkl");
    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 5);
    try std.testing.expectEqual(@as(usize, 5), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_right }, 5);
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_right }, 5);
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 5);
    try std.testing.expectEqual(@as(usize, 12), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 5);
    try std.testing.expectEqual(@as(usize, 7), session.inputCursor());
}

test "ai chat composer history recalls prompts at visual boundaries" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "first prompt") });
    try session.messages.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "first reply") });
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "second prompt") });

    session.appendInputText("draft");
    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("second prompt", session.input());
    try std.testing.expectEqual(@as(usize, "second prompt".len), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("first prompt", session.input());
    try std.testing.expectEqual(@as(usize, "first prompt".len), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 80);
    try std.testing.expectEqualStrings("second prompt", session.input());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 80);
    try std.testing.expectEqualStrings("draft", session.input());
    try std.testing.expectEqual(@as(usize, 0), session.inputCursor());
}

test "ai chat composer history preserves multiline vertical editing" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "previous prompt") });

    session.appendInputText("abc\ndefg\nhi");
    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKey(.{ .key = input_key.Key.arrow_down });
    try std.testing.expectEqual(@as(usize, 4), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("abc\ndefg\nhi", session.input());
    try std.testing.expectEqual(@as(usize, 0), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("previous prompt", session.input());
}

test "ai chat composer history exits after editing recalled prompt" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "old prompt") });

    session.appendInputText("draft");
    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("old prompt", session.input());

    session.handleChar('!');
    try std.testing.expectEqualStrings("old prompt!", session.input());

    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 80);
    try std.testing.expectEqualStrings("old prompt!", session.input());
}

test "ai chat composer wrapped row count grows with explicit lines and wrapping" {
    try std.testing.expectEqual(@as(usize, 1), inputWrappedLineCount("", 12));
    try std.testing.expectEqual(@as(usize, 2), inputWrappedLineCount("hello\nworld", 12));
    try std.testing.expectEqual(@as(usize, 3), inputWrappedLineCount("abcdefghijkl", 5));
}

test "ai chat input scroll clamps to wrapped rows" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        ai_chat.DEFAULT_BASE_URL,
        "key",
        ai_chat.DEFAULT_MODEL,
        ai_chat.DEFAULT_SYSTEM_PROMPT,
        ai_chat.DEFAULT_THINKING,
        ai_chat.DEFAULT_REASONING_EFFORT,
        ai_chat.DEFAULT_STREAM,
        "false",
    );
    defer session.deinit();

    session.appendInputText("abcdefghijkl");

    try std.testing.expect(session.scrollInputRows(10, 5, 1));
    try std.testing.expectEqual(@as(usize, 2), session.inputScrollRow());

    try std.testing.expect(session.scrollInputRows(-1, 5, 1));
    try std.testing.expectEqual(@as(usize, 1), session.inputScrollRow());

    try std.testing.expect(session.scrollInputRows(10, 5, 3));
    try std.testing.expectEqual(@as(usize, 0), session.inputScrollRow());
    try std.testing.expect(!session.scrollInputRows(10, 5, 3));
}

test "ai chat manual input scroll pauses cursor following until cursor moves" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        ai_chat.DEFAULT_BASE_URL,
        "key",
        ai_chat.DEFAULT_MODEL,
        ai_chat.DEFAULT_SYSTEM_PROMPT,
        ai_chat.DEFAULT_THINKING,
        ai_chat.DEFAULT_REASONING_EFFORT,
        ai_chat.DEFAULT_STREAM,
        "false",
    );
    defer session.deinit();

    session.appendInputText("abcdefghijkl");
    try std.testing.expect(session.input_scroll_follow_cursor);

    _ = session.scrollInputRows(1, 5, 1);
    try std.testing.expect(!session.input_scroll_follow_cursor);

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_right }, 5);
    try std.testing.expect(session.input_scroll_follow_cursor);
}
