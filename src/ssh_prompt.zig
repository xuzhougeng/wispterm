const std = @import("std");
const text_search = @import("text_search.zig");

pub fn containsPasswordPromptText(text: []const u8) bool {
    return text_search.containsIgnoreCase(text, "password:");
}

test "ssh prompt detects OpenSSH password prompt" {
    try std.testing.expect(containsPasswordPromptText("root@example.com's password:"));
    try std.testing.expect(containsPasswordPromptText("Password:"));
}

test "ssh prompt ignores non-prompt password text" {
    try std.testing.expect(!containsPasswordPromptText("PreferredAuthentications=password,keyboard-interactive"));
    try std.testing.expect(!containsPasswordPromptText("Permission denied, please try again."));
}
