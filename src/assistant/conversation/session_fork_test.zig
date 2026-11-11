//! Session-level tests for the rewind-picker fork trigger (`f`). They live
//! outside session.zig to keep that file under the 10,000-line backstop;
//! struct fields are accessible cross-file, so the tests drive the same public
//! surface input.zig uses (handleChar / openRewindPicker) plus the fork
//! trigger hook AppWindow registers.

const std = @import("std");
const ai_chat = @import("session.zig");

const Session = ai_chat.Session;

const ForkHook = struct {
    var fired: bool = false;
    var target: ?*Session = null;
    var user_point: usize = 0;

    fn reset() void {
        fired = false;
        target = null;
        user_point = 0;
    }

    fn cb(session: *Session, n: usize) void {
        fired = true;
        target = session;
        user_point = n;
    }
};

fn freeMessages(session: *Session, a: std.mem.Allocator) void {
    for (session.messages.items) |msg| msg.deinit(a);
    session.messages.deinit(a);
}

test "rewind fork key fires the deferred fork trigger with the persisted user-point index" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);

    // A non-persisted user message sits between two persisted ones: the record
    // ordinal must skip it (records only carry persist_to_history messages).
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "first") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "r1") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "scratch"), .persist_to_history = false });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "second") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "r2") });

    ForkHook.reset();
    ai_chat.setForkAtRewindTrigger(ForkHook.cb);
    defer ai_chat.setForkAtRewindTrigger(null);

    session.openRewindPicker(); // 3 rewind points; selection defaults to the newest ("second")
    try std.testing.expect(session.rewind_open);

    session.handleChar('f');

    try std.testing.expect(ForkHook.fired);
    try std.testing.expectEqual(&session, ForkHook.target.?);
    // Before "second" only "first" is persisted -> the fork keeps 1 user message.
    try std.testing.expectEqual(@as(usize, 1), ForkHook.user_point);
    try std.testing.expect(!session.rewind_open);
    // A fork never mutates the source session.
    try std.testing.expectEqual(@as(usize, 5), session.messages.items.len);
}

test "rewind fork key on the oldest rewind point yields user point zero" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);

    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "one") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "r1") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "two") });

    ForkHook.reset();
    ai_chat.setForkAtRewindTrigger(ForkHook.cb);
    defer ai_chat.setForkAtRewindTrigger(null);

    session.openRewindPicker(); // selected = 1 (newest)
    session.moveRewindSelection(-1); // oldest point "one"
    session.handleChar('F'); // uppercase works too

    try std.testing.expect(ForkHook.fired);
    try std.testing.expectEqual(@as(usize, 0), ForkHook.user_point);
    try std.testing.expect(!session.rewind_open);
    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
}

test "rewind fork key is inert while a request is in flight" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);

    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "one") });

    ForkHook.reset();
    ai_chat.setForkAtRewindTrigger(ForkHook.cb);
    defer ai_chat.setForkAtRewindTrigger(null);

    session.openRewindPicker();
    try std.testing.expect(session.rewind_open);
    session.request_inflight = true; // a request started after the picker opened

    session.handleChar('f');

    try std.testing.expect(!ForkHook.fired);
    try std.testing.expect(session.rewind_open); // picker stays up, like confirmRewind's idle gate
}

test "plain f without an open rewind picker still types into the composer" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);

    ForkHook.reset();
    ai_chat.setForkAtRewindTrigger(ForkHook.cb);
    defer ai_chat.setForkAtRewindTrigger(null);

    session.handleChar('f');

    try std.testing.expect(!ForkHook.fired);
    try std.testing.expectEqualStrings("f", session.input());
}

const agent_history = @import("../../agent/history.zig");
const api_key_resolver = @import("api_key_resolver.zig");

const KeyResolverFake = struct {
    fn cb(base_url: []const u8, model: []const u8, out: []u8) ?[]const u8 {
        if (!std.mem.eql(u8, base_url, "https://api.example.test/v1") or !std.mem.eql(u8, model, "m1")) return null;
        const key = "key-from-profile";
        @memcpy(out[0..key.len], key);
        return out[0..key.len];
    }
};

fn keylessRecord(base_url: []const u8) agent_history.SessionRecord {
    return .{
        .session_id = "restored-1",
        .title = "Restored",
        .base_url = base_url,
        .api_key = "",
        .model = "m1",
        .system_prompt = "system",
        .thinking_enabled = false,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = false,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{},
    };
}

test "a session restored from history gets its API key from the saved profiles" {
    const a = std.testing.allocator;
    api_key_resolver.set(KeyResolverFake.cb);
    defer api_key_resolver.set(null);

    // History no longer stores the key, so the record arrives without one.
    const restored = try Session.initFromHistoryRecord(a, keylessRecord("https://api.example.test/v1"));
    defer restored.deinit();
    try std.testing.expectEqualStrings("key-from-profile", restored.apiKey());

    // No matching profile: the session comes back without a key rather than failing.
    const unknown = try Session.initFromHistoryRecord(a, keylessRecord("https://other.example.test"));
    defer unknown.deinit();
    try std.testing.expectEqualStrings("", unknown.apiKey());
}

test "a legacy history record that still carries a key keeps using it" {
    const a = std.testing.allocator;
    api_key_resolver.set(KeyResolverFake.cb);
    defer api_key_resolver.set(null);

    var record = keylessRecord("https://api.example.test/v1");
    record.api_key = "legacy-key";
    const restored = try Session.initFromHistoryRecord(a, record);
    defer restored.deinit();
    try std.testing.expectEqualStrings("legacy-key", restored.apiKey());
}
