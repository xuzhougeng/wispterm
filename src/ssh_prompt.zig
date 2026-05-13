const std = @import("std");

fn lowerAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, i| {
            if (lowerAscii(haystack[start + i]) != lowerAscii(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

pub fn containsPasswordPromptText(text: []const u8) bool {
    return containsIgnoreCase(text, "password:");
}

test "ssh prompt detects OpenSSH password prompt" {
    try std.testing.expect(containsPasswordPromptText("root@example.com's password:"));
    try std.testing.expect(containsPasswordPromptText("Password:"));
}

test "ssh prompt ignores non-prompt password text" {
    try std.testing.expect(!containsPasswordPromptText("PreferredAuthentications=password,keyboard-interactive"));
    try std.testing.expect(!containsPasswordPromptText("Permission denied, please try again."));
}
