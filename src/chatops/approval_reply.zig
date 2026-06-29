//! Classifies a WeChat reply sent while the copilot is blocked on an approval.
//! Pure (no allocation/IO) so it is unit-tested directly. Whole-message match
//! (trimmed, ASCII-case-insensitive) keeps "我不确定" from matching the "不" deny
//! token.
const std = @import("std");

pub const Decision = enum { approve, deny, unrecognized };

const approve_tokens = [_][]const u8{ "y", "yes", "ok", "同意", "确认", "好", "好的", "可以" };
const deny_tokens = [_][]const u8{ "n", "no", "拒绝", "取消", "不", "不要" };

pub fn classify(text: []const u8) Decision {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return .unrecognized;
    for (approve_tokens) |tok| if (eqWhole(trimmed, tok)) return .approve;
    for (deny_tokens) |tok| if (eqWhole(trimmed, tok)) return .deny;
    return .unrecognized;
}

/// ASCII-case-insensitive whole-string equality. Non-ASCII bytes (the Chinese
/// tokens) compare exactly, which is what we want.
fn eqWhole(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

const t = std.testing;

test "approve tokens, case-insensitive and trimmed" {
    try t.expectEqual(Decision.approve, classify("y"));
    try t.expectEqual(Decision.approve, classify("Y"));
    try t.expectEqual(Decision.approve, classify("  yes \n"));
    try t.expectEqual(Decision.approve, classify("OK"));
    try t.expectEqual(Decision.approve, classify("同意"));
    try t.expectEqual(Decision.approve, classify("确认"));
    try t.expectEqual(Decision.approve, classify("好"));
    try t.expectEqual(Decision.approve, classify("好的"));
    try t.expectEqual(Decision.approve, classify("可以"));
}

test "deny tokens" {
    try t.expectEqual(Decision.deny, classify("n"));
    try t.expectEqual(Decision.deny, classify("NO"));
    try t.expectEqual(Decision.deny, classify("拒绝"));
    try t.expectEqual(Decision.deny, classify("取消"));
    try t.expectEqual(Decision.deny, classify("不"));
    try t.expectEqual(Decision.deny, classify("不要"));
}

test "unrecognized: empty, partial-match, and real instructions" {
    try t.expectEqual(Decision.unrecognized, classify(""));
    try t.expectEqual(Decision.unrecognized, classify("   "));
    try t.expectEqual(Decision.unrecognized, classify("我不确定")); // contains 不 but not whole-match
    try t.expectEqual(Decision.unrecognized, classify("yes please"));
    try t.expectEqual(Decision.unrecognized, classify("先删回收站"));
}
