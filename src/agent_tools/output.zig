//! Agent tool output truncation helpers.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");

const AgentSettings = types.AgentSettings;

pub fn truncateOwned(allocator: std.mem.Allocator, settings: AgentSettings, text: []u8) ![]u8 {
    const limit = settings.output_limit;
    if (text.len <= limit) return text;
    errdefer allocator.free(text); // owned: must not leak when allocPrint fails
    const truncated = try std.fmt.allocPrint(allocator, "{s}\n...[truncated to {d} bytes]", .{ text[0..limit], limit });
    allocator.free(text);
    return truncated;
}

/// Like truncateOwned, but keeps the LAST `limit` bytes (the most recent
/// output) and marks the dropped head. Use for terminal-snapshot-bearing
/// results, where the live interactive screen is at the tail — keeping the head
/// would hide the current prompt.
pub fn truncateTailOwned(allocator: std.mem.Allocator, settings: AgentSettings, text: []u8) ![]u8 {
    const limit: usize = settings.output_limit;
    if (text.len <= limit) return text;
    errdefer allocator.free(text); // owned: must not leak when allocPrint fails
    const tail = text[text.len - limit ..];
    const truncated = try std.fmt.allocPrint(allocator, "...[older output truncated to {d} bytes]\n{s}", .{ limit, tail });
    allocator.free(text);
    return truncated;
}

pub fn deniedResult(allocator: std.mem.Allocator, command: []const u8, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "DENIED by operator (reason: {s})\ncommand: {s}", .{ reason, command });
}

test "truncateTailOwned keeps the tail and marks the dropped head" {
    const a = std.testing.allocator;
    const settings = AgentSettings{ .output_limit = 8 };
    const text = try a.dupe(u8, "ABCDEFGHIJKLMNOP"); // 16 bytes, limit 8
    const out = try truncateTailOwned(a, settings, text);
    defer a.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "IJKLMNOP"));
    try std.testing.expect(std.mem.indexOf(u8, out, "older output truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ABCD") == null);
}

test "truncateTailOwned returns short text unchanged" {
    const a = std.testing.allocator;
    const settings = AgentSettings{ .output_limit = 1024 };
    const text = try a.dupe(u8, "small");
    const out = try truncateTailOwned(a, settings, text);
    defer a.free(out);
    try std.testing.expectEqualStrings("small", out);
}

test "truncate helpers free the owned input when the truncation alloc fails" {
    // Both helpers take ownership of `text`; if the replacement allocPrint
    // hits OOM they must free it. std.testing.allocator's leak check is the
    // assertion here (allocation #0 = the input dupe, #1 = the failing
    // allocPrint).
    const settings = AgentSettings{ .output_limit = 4 };

    var failing_tail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const tail_alloc = failing_tail.allocator();
    const tail_text = try tail_alloc.dupe(u8, "0123456789");
    try std.testing.expectError(error.OutOfMemory, truncateTailOwned(tail_alloc, settings, tail_text));

    var failing_head = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const head_alloc = failing_head.allocator();
    const head_text = try head_alloc.dupe(u8, "0123456789");
    try std.testing.expectError(error.OutOfMemory, truncateOwned(head_alloc, settings, head_text));
}
