//! Session-level tests for `/btw` child sessions. They live outside
//! session.zig to keep that file under the 10,000-line backstop.

const std = @import("std");
const ai_chat = @import("session.zig");

const Session = ai_chat.Session;

test "btw child session receives a bounded snapshot and inherits agent tools" {
    const allocator = std.testing.allocator;
    const source = try Session.init(
        allocator,
        "Source",
        "https://example.invalid",
        "test-key",
        "test-model",
        "source system prompt",
        "disabled",
        "low",
        "false",
        "true",
    );
    defer source.deinit();
    source.mutex.lock();
    try source.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "original goal"),
    });
    try source.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "working on it"),
    });
    source.setStatusLocked("Running");
    source.mutex.unlock();

    const child = try source.createBtwSession(allocator, "");
    defer child.deinit();

    try std.testing.expectEqualStrings("BTW", child.title());
    try std.testing.expectEqualStrings("test-model", child.model());
    try std.testing.expect(child.agent_enabled);
    try std.testing.expectEqual(@as(usize, 0), child.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, child.systemPrompt(), "Source status: Running") != null);
    try std.testing.expect(std.mem.indexOf(u8, child.systemPrompt(), "User: original goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, child.systemPrompt(), "Assistant: working on it") != null);
    try std.testing.expect(std.mem.indexOf(u8, child.systemPrompt(), "You may use tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, child.systemPrompt(), "Do not execute tools") == null);
    try std.testing.expectEqual(@as(usize, 2), source.messages.items.len);
}

test "btw child session stays chat-only when the source has tools disabled" {
    const allocator = std.testing.allocator;
    const source = try Session.init(
        allocator,
        "Source",
        "https://example.invalid",
        "test-key",
        "test-model",
        "source system prompt",
        "disabled",
        "low",
        "false",
        "false",
    );
    defer source.deinit();

    const child = try source.createBtwSession(allocator, "");
    defer child.deinit();

    try std.testing.expect(!child.agent_enabled);
    try std.testing.expect(std.mem.indexOf(u8, child.systemPrompt(), "Do not execute tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, child.systemPrompt(), "You may use tools") == null);
}
