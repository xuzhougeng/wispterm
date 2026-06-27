//! Pure formatting for a file path dropped onto the AI chat composer.
//!
//! No platform/AppWindow imports so it runs in the fast test suite (mirrors
//! assistant/conversation/layout.zig / assistant/sidebar/panel.zig). The drop pipeline
//! (src/input/clipboard.zig) calls this to turn an OS-provided absolute path
//! into the text inserted at the composer cursor.

const std = @import("std");

/// Returns the composer text for a dropped file `raw` path. If `raw` contains
/// ASCII whitespace it is single-quoted (POSIX `'\''` escaping for embedded
/// single quotes); otherwise it is inserted verbatim. A single trailing space
/// is always appended so successive drops / continued typing stay separated.
/// Caller owns the returned slice.
pub fn formatDroppedPath(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (needsQuoting(raw)) {
        try out.append(allocator, '\'');
        for (raw) |ch| {
            if (ch == '\'') {
                try out.appendSlice(allocator, "'\\''");
            } else {
                try out.append(allocator, ch);
            }
        }
        try out.append(allocator, '\'');
    } else {
        try out.appendSlice(allocator, raw);
    }
    try out.append(allocator, ' ');
    return out.toOwnedSlice(allocator);
}

fn needsQuoting(raw: []const u8) bool {
    for (raw) |ch| {
        if (std.ascii.isWhitespace(ch)) return true;
    }
    return false;
}

test "formatDroppedPath leaves a space-free path verbatim with trailing space" {
    const out = try formatDroppedPath(std.testing.allocator, "/home/me/file.txt");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("/home/me/file.txt ", out);
}

test "formatDroppedPath single-quotes a path containing a space" {
    const out = try formatDroppedPath(std.testing.allocator, "/home/me/my file.txt");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("'/home/me/my file.txt' ", out);
}

test "formatDroppedPath escapes embedded single quotes when quoting" {
    const out = try formatDroppedPath(std.testing.allocator, "/home/me/a 'b'.txt");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("'/home/me/a '\\''b'\\''.txt' ", out);
}

test "formatDroppedPath always appends exactly one trailing space" {
    const out = try formatDroppedPath(std.testing.allocator, "plain");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("plain ", out);
}
