//! Session-scoped reasoning effort. `/effort` and the conversation header chip
//! pick one of the levels the connected Magpie model lists. The choice applies
//! from this session's next request and is never written to `ai_profiles`,
//! the native config, or `magpie.json`. Kept out of session.zig, which sits
//! near the 10,000-line backstop.
const std = @import("std");
const ai_chat = @import("session.zig");
const effort_levels = @import("effort_levels.zig");

const Session = ai_chat.Session;

/// Switch to `level` when this session lists it. Assumes `session.mutex` is held.
pub fn selectLocked(session: *Session, level: []const u8) bool {
    if (!session.effort_levels.contains(level)) return false;
    session.copyReasoningEffort(level);
    return true;
}

/// Header chip click: advance to the next listed level.
pub fn cycle(session: *Session) void {
    defer session.markUiDirty();
    session.mutex.lock();
    defer session.mutex.unlock();
    const levels = &session.effort_levels;
    const level = levels.next(session.reasoningEffort()) orelse return;
    _ = selectLocked(session, level);
    if (session.request_inflight) return;
    var buf: [96]u8 = undefined;
    const status = if (levels.count == 1)
        std.fmt.bufPrint(&buf, "Reasoning effort: {s} (only level for this model)", .{level})
    else
        std.fmt.bufPrint(&buf, "Reasoning effort: {s}", .{level});
    session.setStatusLocked(status catch "Reasoning effort changed");
}

/// `/effort [level]`: show the current and available levels, or switch this
/// session to `level`. Assumes `session.mutex` is held. Always handles its own
/// transcript message, so the caller suppresses the generic output.
pub fn runCommandLocked(session: *Session, arg: []const u8) bool {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    var lower_buf: [effort_levels.LEVEL_MAX]u8 = undefined;
    const level = if (trimmed.len <= lower_buf.len) std.ascii.lowerString(&lower_buf, trimmed) else trimmed;
    var levels_buf: [256]u8 = undefined;
    const levels = session.effort_levels.join(&levels_buf);
    var msg_buf: [512]u8 = undefined;
    const msg = if (session.effort_levels.count == 0)
        "This session has no switchable reasoning levels. Magpie sessions list their model's levels unless thinking is off; personal profiles set effort in the profile form."
    else if (level.len == 0)
        std.fmt.bufPrint(&msg_buf, "Reasoning effort: {s}. Available for this model: {s}. Use /effort <level> to switch this session.", .{ session.reasoningEffort(), levels }) catch "Reasoning effort"
    else if (selectLocked(session, level))
        std.fmt.bufPrint(&msg_buf, "Reasoning effort set to {s} for this session.", .{level}) catch "Reasoning effort set."
    else
        std.fmt.bufPrint(&msg_buf, "{s} is not available for this model. Available: {s}.", .{ level, levels }) catch "Reasoning effort not available.";
    session.appendLocalToolMessageLocked(msg) catch {
        session.setStatusLocked("Out of memory");
        return true;
    };
    session.clearSubmittedInputLocked();
    if (!session.request_inflight) session.setStatusLocked("Ready");
    return true;
}

const magpie = @import("../profile/magpie.zig");
const codec = @import("../../renderer/overlays/profile_codec.zig");
const ai_chat_request = @import("request.zig");

fn testMagpieSession(allocator: std.mem.Allocator, protocol: []const u8) !*Session {
    const json = try std.fmt.allocPrint(allocator,
        \\{{"baseURL":"http://127.0.0.1:3425/v1","apiKey":"fixture","model":"p/reasoner","protocol":"{s}","agent":false,"modelInfo":{{"id":"p/reasoner","context":400000,"output":128000,"efforts":["low","medium","high"]}}}}
    , .{protocol});
    defer allocator.free(json);
    const profile = magpie.parse(allocator, json) orelse return error.ExpectedProfile;
    const field = codec.aiProfileField;
    const session = try Session.initWithVision(
        allocator,
        field(&profile, .name),
        field(&profile, .base_url),
        field(&profile, .api_key),
        field(&profile, .model),
        field(&profile, .protocol),
        field(&profile, .system_prompt),
        field(&profile, .thinking),
        field(&profile, .reasoning_effort),
        field(&profile, .stream),
        field(&profile, .agent),
        field(&profile, .vision),
    );
    session.effort_levels = profile.efforts;
    return session;
}

fn testRequestJson(allocator: std.mem.Allocator, session: *Session) ![]u8 {
    session.mutex.lock();
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "hello") });
    const request = session.buildRequestLocked() catch |err| {
        session.mutex.unlock();
        return err;
    };
    session.mutex.unlock();
    defer request.deinit();
    return ai_chat_request.buildRequestJson(allocator, request);
}

test "the effort chosen for a Magpie session is sent to the gateway" {
    const a = std.testing.allocator;
    for ([_]struct { protocol: []const u8, level: []const u8, wire: []const u8 }{
        .{ .protocol = "chat_completions", .level = "high", .wire = "\"reasoning_effort\":\"high\"" },
        .{ .protocol = "responses", .level = "low", .wire = "\"reasoning\":{\"effort\":\"low\"}" },
    }) |case| {
        const session = try testMagpieSession(a, case.protocol);
        defer session.deinit();
        try std.testing.expectEqualStrings("medium", session.reasoningEffort());
        session.mutex.lock();
        try std.testing.expect(selectLocked(session, case.level));
        try std.testing.expect(!selectLocked(session, "max"));
        session.mutex.unlock();
        const json = try testRequestJson(a, session);
        defer a.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, case.wire) != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"medium\"") == null);
    }
}

test "/effort lists, switches, and refuses levels the model does not list" {
    const a = std.testing.allocator;
    const session = try testMagpieSession(a, "chat_completions");
    defer session.deinit();
    session.mutex.lock();
    defer session.mutex.unlock();
    for ([_]struct { arg: []const u8, message: []const u8, effort: []const u8 }{
        .{ .arg = "", .message = "Reasoning effort: medium. Available for this model: low, medium, high. Use /effort <level> to switch this session.", .effort = "medium" },
        .{ .arg = " HIGH ", .message = "Reasoning effort set to high for this session.", .effort = "high" },
        .{ .arg = "xhigh", .message = "xhigh is not available for this model. Available: low, medium, high.", .effort = "high" },
        .{ .arg = "a-level-longer-than-the-buffer", .message = "a-level-longer-than-the-buffer is not available for this model. Available: low, medium, high.", .effort = "high" },
    }) |case| {
        session.setInputTextLocked("/effort");
        try std.testing.expect(runCommandLocked(session, case.arg));
        const last = session.messages.items[session.messages.items.len - 1];
        try std.testing.expectEqualStrings(case.message, last.content);
        try std.testing.expect(!last.replay_to_model);
        try std.testing.expectEqualStrings(case.effort, session.reasoningEffort());
        try std.testing.expectEqualStrings("", session.input());
    }
}

test "/effort reaches the session through the composer" {
    const a = std.testing.allocator;
    const session = try testMagpieSession(a, "chat_completions");
    defer session.deinit();
    session.mutex.lock();
    session.setInputTextLocked("/effort low");
    session.mutex.unlock();
    session.submit();
    try std.testing.expectEqualStrings("low", session.reasoningEffort());
    try std.testing.expect(!session.request_inflight);
}

test "the header chip cycles through the model's levels only" {
    const a = std.testing.allocator;
    const session = try testMagpieSession(a, "chat_completions");
    defer session.deinit();
    for ([_][]const u8{ "high", "low", "medium" }) |expected| {
        cycle(session);
        try std.testing.expectEqualStrings(expected, session.reasoningEffort());
    }
    try std.testing.expectEqualStrings("Reasoning effort: medium", session.status());

    session.effort_levels = .{};
    session.effort_levels.append("auto");
    cycle(session);
    try std.testing.expectEqualStrings("auto", session.reasoningEffort());
    try std.testing.expectEqualStrings("Reasoning effort: auto (only level for this model)", session.status());
}

test "personal sessions without levels keep their profile effort" {
    const a = std.testing.allocator;
    const session = try Session.init(a, "Personal", "https://example.invalid", "k", "m", "", "enabled", "high", "false", "false");
    defer session.deinit();
    cycle(session);
    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(!selectLocked(session, "low"));
    try std.testing.expect(runCommandLocked(session, "low"));
    try std.testing.expectEqualStrings("high", session.reasoningEffort());
}
