//! Session side of the question-card text selection (`question_select.zig`).
//! The selection is UI state guarded by `Session.mutex`; the question text it
//! points into is read under `question_mutex` (lock order mutex, then
//! question_mutex, as in `submit`). Kept out of session.zig, which sits near
//! the 10,000-line backstop.
const std = @import("std");
const ai_chat = @import("session.zig");
const question_select = @import("question_select.zig");

const Session = ai_chat.Session;

pub const Release = question_select.Release;

/// Mouse-down on the question card. Replaces any other chat selection.
pub fn begin(session: *Session, generation: u64, at: question_select.Point, option: ?usize) void {
    session.mutex.lock();
    defer session.mutex.unlock();
    session.clearSelectionLocked();
    session.question_select.begin(generation, at, option);
}

/// True while a question-card drag owns the mouse.
pub fn dragging(session: *Session) bool {
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.question_select.dragging;
}

pub fn update(session: *Session, generation: u64, at: question_select.Point) bool {
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.question_select.update(generation, at);
}

/// Mouse-up. `.choose` asks the caller to resolve that option.
pub fn finish(session: *Session) Release {
    session.mutex.lock();
    defer session.mutex.unlock();
    const current = if (session.questionView()) |view| view.generation else null;
    return session.question_select.finish(current);
}

/// Assumes `session.mutex` is held.
pub fn hasSelectionLocked(session: *Session) bool {
    const view = session.questionView() orelse return false;
    return session.question_select.span(view.generation) != null;
}

/// Selected question-card text, or null when nothing on the pending question
/// is selected. Assumes `session.mutex` is held.
pub fn allocTextLocked(session: *Session, allocator: std.mem.Allocator) !?[]u8 {
    if (!session.question_select.active) return null;
    session.question_mutex.lock();
    defer session.question_mutex.unlock();
    if (!session.question_pending or session.question_resolved) return null;
    const view = ai_chat.QuestionView{
        .question = session.question_text,
        .options = session.question_options,
        .generation = session.question_scroll.generation,
    };
    const span = session.question_select.span(view.generation) orelse return null;
    return try question_select.allocText(allocator, view, span);
}

fn initPendingQuestion(session: *Session) !void {
    session.question_text = try std.testing.allocator.dupe(u8, "Which name?");
    session.question_options = try std.testing.allocator.alloc(ai_chat.QuestionOption, 2);
    session.question_options[0] = .{ .label = try std.testing.allocator.dupe(u8, "alpha-service"), .description = "" };
    session.question_options[1] = .{ .label = try std.testing.allocator.dupe(u8, "beta"), .description = "" };
    session.question_scroll.reset();
    session.question_pending = true;
}

test "copy takes the dragged part of an option and keeps the question pending" {
    var session = try Session.init(std.testing.allocator, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();
    try initPendingQuestion(session);
    const generation = session.questionView().?.generation;

    begin(session, generation, .{ .row = 1, .byte = 3 }, 0); // "1. |alpha-service"
    try std.testing.expect(dragging(session));
    try std.testing.expect(update(session, generation, .{ .row = 1, .byte = 8 }));
    try std.testing.expectEqual(Release.selected, finish(session));
    try std.testing.expect(!dragging(session));
    try std.testing.expect(session.hasSelection());

    const text = try session.allocClipboardText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("alpha", text);
    try std.testing.expect(session.questionView() != null);

    session.clearSelection();
    try std.testing.expect(!session.hasSelection());
}

test "a plain click on an option still answers it" {
    var session = try Session.init(std.testing.allocator, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();
    try initPendingQuestion(session);
    const generation = session.questionView().?.generation;

    begin(session, generation, .{ .row = 2, .byte = 1 }, 1);
    try std.testing.expectEqual(Release{ .choose = 1 }, finish(session));
    try std.testing.expect(!session.hasSelection());
}
