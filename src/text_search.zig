//! Pure ASCII case-insensitive text matching helpers.
//!
//! Extracted from duplicated local copies (ssh_prompt, ai_history_types,
//! browser_panel, ...). Semantics deliberately match those originals exactly so
//! call-site behavior is unchanged:
//!   * `containsIgnoreCase`: empty needle matches anything (returns true); a
//!     needle longer than the haystack never matches (returns false).
//!   * `startsWithIgnoreCase`: an empty prefix always matches; a prefix longer
//!     than the haystack never matches.
//!
//! ASCII only — no Unicode case folding. Comparisons go through `std.ascii`.

const std = @import("std");

/// Returns true if `needle` appears anywhere in `haystack`, comparing bytes
/// case-insensitively over ASCII A-Z/a-z. An empty `needle` returns true; a
/// `needle` longer than `haystack` returns false.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

/// Returns true if `haystack` begins with `prefix`, comparing bytes
/// case-insensitively over ASCII A-Z/a-z. An empty `prefix` returns true; a
/// `prefix` longer than `haystack` returns false.
pub fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

test "containsIgnoreCase empty needle matches anything" {
    try std.testing.expect(containsIgnoreCase("", ""));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}

test "containsIgnoreCase ascii lower match" {
    try std.testing.expect(containsIgnoreCase("hello world", "world"));
    try std.testing.expect(containsIgnoreCase("password:", "password:"));
}

test "containsIgnoreCase ascii upper match" {
    try std.testing.expect(containsIgnoreCase("HELLO WORLD", "WORLD"));
    try std.testing.expect(containsIgnoreCase("Password:", "password:"));
}

test "containsIgnoreCase mixed case match" {
    try std.testing.expect(containsIgnoreCase("HeLLo WoRLd", "hello"));
    try std.testing.expect(containsIgnoreCase("root@example.com's Password:", "password:"));
}

test "containsIgnoreCase not found" {
    try std.testing.expect(!containsIgnoreCase("hello world", "xyz"));
    try std.testing.expect(!containsIgnoreCase("hi", "hello"));
}

test "containsIgnoreCase needle longer than haystack" {
    try std.testing.expect(!containsIgnoreCase("ab", "abc"));
    try std.testing.expect(!containsIgnoreCase("", "x"));
}

test "startsWithIgnoreCase prefix match" {
    try std.testing.expect(startsWithIgnoreCase("localhost:3000", "localhost"));
    try std.testing.expect(startsWithIgnoreCase("LOCALHOST", "localhost"));
    try std.testing.expect(startsWithIgnoreCase("LocalHost", "LOCAL"));
    try std.testing.expect(startsWithIgnoreCase("anything", ""));
}

test "startsWithIgnoreCase non-match" {
    try std.testing.expect(!startsWithIgnoreCase("example.com", "localhost"));
    try std.testing.expect(!startsWithIgnoreCase("127", "127.0.0.1"));
    try std.testing.expect(!startsWithIgnoreCase("abc", "abcd"));
}
