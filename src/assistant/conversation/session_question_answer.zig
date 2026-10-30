//! Session side of an answered `ask_user` question: once the question card
//! closes, the choice stays in the transcript as its own summary card
//! (text from question_answer.zig). Kept out of session.zig, which sits near
//! the 10,000-line backstop.
const std = @import("std");
const ai_chat = @import("session.zig");
const question_answer = @import("question_answer.zig");
const types = @import("types.zig");

const Session = ai_chat.Session;

/// Append the answered summary card. Best effort: a cancelled question, a
/// stopped request, or OOM posts nothing (the model still receives the answer
/// as the tool result). Masks secrets like any other tool note.
pub fn appendSummary(session: *Session, question: []const u8, options: []const types.QuestionOption, result: types.AskResult) void {
    const allocator = session.allocator;
    const raw = (question_answer.allocSummary(allocator, question, options, result) catch return) orelse return;
    defer allocator.free(raw);
    const content = session.secret_filter.redactAlloc(allocator, raw) catch return;
    var content_owned = true;
    defer if (content_owned) allocator.free(content);

    defer session.markUiDirty();
    session.mutex.lock();
    defer session.mutex.unlock();
    if (ai_chat.sessionCancelled(session)) return;
    session.messages.append(allocator, .{
        .role = .tool,
        .content = content,
        .persist_to_history = false,
        .is_question_answer = true,
        .ts_ms = std.time.milliTimestamp(),
    }) catch return;
    content_owned = false;
    session.scroll_px = 1_000_000;
}

fn freeMessages(session: *Session, a: std.mem.Allocator) void {
    for (session.messages.items) |msg| msg.deinit(a);
    session.messages.deinit(a);
}

test "answered summary lands as its own card outside activity groups" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running exec one"), .content_collapsed = true });
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running ask_user {}"), .content_collapsed = true });

    const options = [_]types.QuestionOption{ .{ .label = "SQLite" }, .{ .label = "Postgres" } };
    appendSummary(&session, "Which database?", &options, .{ .option_index = 1 });
    appendSummary(&session, "Which database?", &options, .cancelled);

    const msgs = session.messages.items;
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expect(msgs[2].is_question_answer);
    try std.testing.expect(!msgs[2].groupableTool());
    try std.testing.expect(!msgs[2].content_collapsed);
    try std.testing.expect(!msgs[2].persist_to_history);
    try std.testing.expect(!msgs[2].replay_to_model);
    try std.testing.expectEqualStrings("Which database?\n→ 2. Postgres", msgs[2].content);
    // The answer splits the run: the two calls before it still group.
    try std.testing.expectEqual(@as(usize, 0), ai_chat.toolRunStart(msgs, 1));
}

test "agent reply footer and status leave out the answer wait" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);

    // 40s on the wall clock, 35s of it spent on the question card.
    ai_chat.appendAssistantResult(&session, .{
        .content = @constCast("done"),
        .usage = .{ .completion_tokens = 10, .total_tokens = 10 },
        .user_wait_ms = 35_000,
    }, std.time.milliTimestamp() - 40_000);

    const footer = session.messages.items[0].usage_footer.?;
    try std.testing.expect(std.mem.startsWith(u8, footer, "time 5."));
    try std.testing.expect(std.mem.indexOf(u8, footer, "answer wait 35.0s") != null);
    try std.testing.expect(std.mem.startsWith(u8, session.status(), "Done in 5."));
}
