//! Owner binding + inbound message filtering. Ported from poller.ts.
const std = @import("std");
const types = @import("types.zig");

pub const Decision = struct { ok: bool, reason: []const u8 };

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Mirror of shouldHandleWeixinMessage. `owner` is the bound owner ("" if
/// unbound); `account_id` is the bot's own id ("" if unknown).
pub fn shouldHandle(owner: []const u8, account_id: []const u8, msg: types.Message) Decision {
    const from = trim(msg.from_user_id);
    const to = trim(msg.to_user_id);
    if (trim(msg.group_id).len != 0) return .{ .ok = false, .reason = "group_message" };
    if (from.len == 0) return .{ .ok = false, .reason = "missing_sender" };
    if (account_id.len != 0 and std.mem.eql(u8, from, account_id)) return .{ .ok = false, .reason = "bot_echo" };
    if (owner.len != 0 and !std.mem.eql(u8, from, owner)) return .{ .ok = false, .reason = "unexpected_sender" };
    if (account_id.len != 0 and to.len != 0 and !std.mem.eql(u8, to, account_id)) return .{ .ok = false, .reason = "unexpected_recipient" };
    return .{ .ok = true, .reason = "" };
}

/// Mirror of extractWeixinText: text item (type 1), else voice transcript (type 3).
pub fn extractText(msg: types.Message) []const u8 {
    for (msg.item_list) |item| {
        if (item.type == 1) {
            const text = trim(item.text);
            if (text.len != 0) return text;
        }
        if (item.type == 3) {
            const text = trim(item.voice_text);
            if (text.len != 0) return text;
        }
    }
    return "";
}

/// Returns the user_id to persist as owner, or null if no auto-bind should
/// happen (already bound, or an explicit allowed_user is configured).
pub fn ownerForBind(current_owner: []const u8, allowed_user: []const u8, sender: []const u8) ?[]const u8 {
    if (trim(current_owner).len != 0) return null;
    if (trim(allowed_user).len != 0) return null;
    const s = trim(sender);
    return if (s.len == 0) null else s;
}

const t = std.testing;

test "rejects group, empty sender, bot echo, and stranger" {
    try t.expect(!shouldHandle("", "", .{ .from_user_id = "u1", .group_id = "g1" }).ok);
    try t.expect(!shouldHandle("", "", .{ .from_user_id = "" }).ok);
    try t.expect(!shouldHandle("", "bot", .{ .from_user_id = "bot" }).ok);
    try t.expect(!shouldHandle("owner", "", .{ .from_user_id = "stranger" }).ok);
}

test "accepts the owner and an unbound first sender" {
    try t.expect(shouldHandle("owner", "", .{ .from_user_id = "owner" }).ok);
    try t.expect(shouldHandle("", "", .{ .from_user_id = "anybody" }).ok);
}

test "extractText prefers text item then voice transcript" {
    try t.expectEqualStrings("hi", extractText(.{ .item_list = &.{
        .{ .type = 1, .text = "  hi  " },
    } }));
    try t.expectEqualStrings("said", extractText(.{ .item_list = &.{
        .{ .type = 3, .voice_text = "said" },
    } }));
    try t.expectEqualStrings("", extractText(.{ .item_list = &.{} }));
}

test "ownerForBind returns first sender only when unbound and allowed empty" {
    try t.expectEqualStrings("u1", ownerForBind("", "", "u1").?);
    try t.expect(ownerForBind("existing", "", "u1") == null);
    try t.expect(ownerForBind("", "allowed-only", "u1") == null);
}
