//! Text-level secret masking before chat content reaches the LLM (spec §7).
//! Structural exclusion (wispterm api_key field) already happens in
//! provider_wispterm; this pass catches secrets pasted into message text.
const std = @import("std");

pub const MASK = "[REDACTED]";

const KEY_PREFIXES = [_][]const u8{ "sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA" };
const KV_KEYS = [_][]const u8{ "password", "passwd", "api_key", "apikey", "token", "secret" };

pub fn redact(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const boundary_ok = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
        if (boundary_ok) {
            if (matchAt(text, i)) |m| {
                try out.appendSlice(alloc, text[i .. i + m.keep]);
                try out.appendSlice(alloc, MASK);
                i += m.len;
                continue;
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

const Match = struct {
    /// Total input bytes consumed.
    len: usize,
    /// Leading bytes to keep verbatim (e.g. "password=" before the mask).
    keep: usize = 0,
};

fn matchAt(text: []const u8, i: usize) ?Match {
    const rest = text[i..];
    for (KEY_PREFIXES) |prefix| {
        if (std.ascii.startsWithIgnoreCase(rest, prefix)) {
            const tail = tokenLen(rest[prefix.len..], 0);
            if (tail >= 8) return .{ .len = prefix.len + tail };
        }
    }
    if (std.ascii.startsWithIgnoreCase(rest, "bearer ")) {
        const tail = nonSpaceLen(rest["bearer ".len..]);
        if (tail >= 8) return .{ .len = "bearer ".len + tail, .keep = "bearer ".len };
    }
    for (KV_KEYS) |key| {
        if (std.ascii.startsWithIgnoreCase(rest, key)) {
            var j = key.len;
            if (j >= rest.len or (rest[j] != '=' and rest[j] != ':')) continue;
            j += 1;
            if (j < rest.len and rest[j] == ' ') j += 1;
            const tail = nonSpaceLen(rest[j..]);
            if (tail >= 4) return .{ .len = j + tail, .keep = j };
        }
    }
    // Long hex run (>=64) — sha256-style tokens; 40-hex git SHAs pass through.
    const hex = hexLen(rest);
    if (hex >= 64) return .{ .len = hex };
    // Long mixed-case base64-ish run (>=40) with upper+lower+digit.
    const b64 = base64Len(rest);
    if (b64 >= 40 and hasMixedClasses(rest[0..b64])) return .{ .len = b64 };
    return null;
}

fn tokenLen(s: []const u8, start: usize) usize {
    var n = start;
    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or s[n] == '_' or s[n] == '-')) n += 1;
    return n;
}

fn nonSpaceLen(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and !std.ascii.isWhitespace(s[n]) and s[n] != '"' and s[n] != '\'') n += 1;
    return n;
}

fn hexLen(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and std.ascii.isHex(s[n])) n += 1;
    return n;
}

fn base64Len(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or
        s[n] == '+' or s[n] == '/' or s[n] == '=' or s[n] == '_' or s[n] == '-')) n += 1;
    return n;
}

fn hasMixedClasses(s: []const u8) bool {
    var upper = false;
    var lower = false;
    var digit = false;
    for (s) |c| {
        if (std.ascii.isUpper(c)) upper = true;
        if (std.ascii.isLower(c)) lower = true;
        if (std.ascii.isDigit(c)) digit = true;
    }
    return upper and lower and digit;
}

const Case = struct { in: []const u8, expect_masked: bool };

test "memory_digest_redact: table-driven positive and negative cases" {
    const cases = [_]Case{
        .{ .in = "key is sk-abc12345678 ok", .expect_masked = true },
        .{ .in = "ghp_0123456789abcdef pushed", .expect_masked = true },
        .{ .in = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload", .expect_masked = true },
        .{ .in = "password=hunter22 login", .expect_masked = true },
        .{ .in = "token: ZXhhbXBsZQ== done", .expect_masked = true },
        .{ .in = "hash 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef end", .expect_masked = true },
        .{ .in = "jwt AbC1dEf2GhI3jKl4MnO5pQr6StU7vWx8Yz90AbC1 sig", .expect_masked = true },
        // Negatives:
        .{ .in = "the task-brief file", .expect_masked = false }, // sk- not at boundary
        .{ .in = "sk-short", .expect_masked = false }, // tail < 8
        .{ .in = "commit 74707cdfd1b3f4b21c9a8e5d6f7a8b9c0d1e2f3a fixed it", .expect_masked = false }, // 40-hex git SHA
        .{ .in = "the token was expired", .expect_masked = false }, // no = or :
        .{ .in = "password= ", .expect_masked = false }, // empty value
        .{ .in = "plain text with nothing", .expect_masked = false },
    };
    for (cases) |case| {
        const out = try redact(std.testing.allocator, case.in);
        defer std.testing.allocator.free(out);
        const masked = std.mem.indexOf(u8, out, MASK) != null;
        if (masked != case.expect_masked) {
            std.debug.print("case failed: '{s}' -> '{s}'\n", .{ case.in, out });
            return error.TestUnexpectedResult;
        }
    }
}

test "memory_digest_redact: keeps key prefix and masks value" {
    const out = try redact(std.testing.allocator, "password=hunter22 rest");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("password=" ++ MASK ++ " rest", out);
}

test "memory_digest_redact: masks whole prefixed key" {
    const out = try redact(std.testing.allocator, "use sk-abc12345678 now");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("use " ++ MASK ++ " now", out);
}
