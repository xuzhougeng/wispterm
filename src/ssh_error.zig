//! Turn raw ssh/scp stderr into one short, human-readable line for a toast.
//! Best-effort: prefer a known diagnostic phrase if present, else fall back to
//! the last non-empty line, trimmed and length-capped. Returns a slice INTO the
//! input (no allocation); caller copies if it must outlive `stderr`.

const std = @import("std");

/// Max chars we hand to the toast (toast buffer is 160B; keep margin for prefix).
pub const MAX = 120;

// Order matters: first match wins. More specific / user-visible phrases first.
const known = [_][]const u8{
    "Permission denied",
    "Connection timed out",
    "Connection refused",
    "Could not resolve hostname",
    "No route to host",
    "Host key verification failed",
    "No such file or directory",
    "Operation timed out",
    "Authentication failed",
};

/// Extract a concise summary from `stderr`. Returns `null` if nothing usable.
pub fn summarize(stderr: []const u8) ?[]const u8 {
    const trimmed_all = std.mem.trim(u8, stderr, " \t\r\n");
    if (trimmed_all.len == 0) return null;

    // 1) Prefer a known diagnostic phrase, returning the line that contains it.
    for (known) |phrase| {
        if (std.mem.indexOf(u8, trimmed_all, phrase)) |idx| {
            const line = lineAround(trimmed_all, idx);
            return cap(line);
        }
    }
    // 2) Fall back to the last non-empty line.
    var it = std.mem.splitBackwardsScalar(u8, trimmed_all, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len > 0) return cap(line);
    }
    return null;
}

fn lineAround(text: []const u8, idx: usize) []const u8 {
    var start = idx;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = idx;
    while (end < text.len and text[end] != '\n') end += 1;
    return std.mem.trim(u8, text[start..end], " \t\r\n");
}

/// Byte-level cap; may split a multibyte UTF-8 char, acceptable for toast use.
fn cap(line: []const u8) []const u8 {
    return if (line.len > MAX) line[0..MAX] else line;
}

test "summarize prefers a known phrase line" {
    const s =
        \\Warning: Permanently added 'host' (ED25519) to the list of known hosts.
        \\root@host: Permission denied (publickey,password).
    ;
    try std.testing.expectEqualStrings(
        "root@host: Permission denied (publickey,password).",
        summarize(s).?,
    );
}

test "summarize falls back to last non-empty line" {
    const s = "some noise\n\nscp: /tmp/x: No space left on device\n\n";
    try std.testing.expectEqualStrings("scp: /tmp/x: No space left on device", summarize(s).?);
}

test "summarize returns null for blank stderr" {
    try std.testing.expectEqual(@as(?[]const u8, null), summarize("   \n\t\n"));
}

test "summarize caps very long lines" {
    var buf: [400]u8 = undefined;
    @memset(&buf, 'x');
    const out = summarize(&buf).?;
    try std.testing.expectEqual(MAX, out.len);
}
