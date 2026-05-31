//! Pure, platform-independent logic for AI Chat conversation auto-titling.
//!
//! Lives separate from `ai_chat.zig` (which is too heavy for the fast test
//! suite) so this logic can be unit-tested via `zig build test` /
//! `zig test src/ai_chat_title.zig`. The threaded request + Session
//! integration stays in `ai_chat.zig`.

const std = @import("std");

pub const Role = @import("ai_chat_protocol.zig").Role;

/// Max bytes taken from each of the user / assistant sections when building the
/// title prompt. Truncated on a UTF-8 boundary.
pub const max_section_bytes: usize = 1500;

/// Max bytes of a cleaned display title. Matches `Session.title_buf` length so
/// the title never gets hard-cut mid-codepoint by `copyTitle`.
pub const max_title_bytes: usize = 128;

pub const system_prompt =
    \\You are titling a chat conversation. Given the user's first message and the assistant's reply, produce a short, specific title that captures the topic.
    \\Rules: 2-6 words; no surrounding quotes; no trailing punctuation; reply with the title only; write the title in the same language the user is using.
;

/// Largest length <= `limit` that does not split a UTF-8 codepoint.
/// Returns `s.len` when `s` is already within `limit`.
pub fn utf8SafeLen(s: []const u8, limit: usize) usize {
    if (s.len <= limit) return s.len;
    var end = limit;
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return end;
}

test "utf8SafeLen: backs off mid-codepoint" {
    const s = "ab一"; // 'a''b' + U+4E00 (3 bytes) = 5 bytes
    try std.testing.expectEqual(@as(usize, 2), utf8SafeLen(s, 3)); // limit splits 一
    try std.testing.expectEqual(@as(usize, 2), utf8SafeLen(s, 4));
    try std.testing.expectEqual(@as(usize, 5), utf8SafeLen(s, 5));
    try std.testing.expectEqual(@as(usize, 5), utf8SafeLen(s, 99));
}
