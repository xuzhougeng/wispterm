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

// Design: probe a bounded window first, decide whether to mask from that
// window alone, and only walk to the run's true end once we've committed to
// masking. The probe (<=128 bytes) is what keeps ordinary text linear —
// hyphenated paths/stack traces never hit the mask threshold and never pay
// the extension walk. There is no cap on the extension itself: every byte
// the walk visits belongs to a run that ends in a consumed match, so each
// input byte is examined by at most one such walk overall (amortized O(n)),
// and the whole secret gets masked instead of leaking a partial tail.
//
// Longest threshold below is 64 (hex); 128 bytes is ample headroom for the
// probe to reach it.
// ponytail: fixed cap, not derived from thresholds; revisit if a longer
// secret pattern is added.
const PROBE_CAP = 128;

fn matchAt(text: []const u8, i: usize) ?Match {
    const rest = text[i..];
    for (KEY_PREFIXES) |prefix| {
        if (std.ascii.startsWithIgnoreCase(rest, prefix)) {
            const tail = tokenLen(rest[prefix.len..]);
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
            // Tolerate the key name's own closing quote, e.g. `"password":`
            // — the opening quote before `password` is outside `rest` and
            // already satisfied the boundary check in `redact`.
            if (j < rest.len and (rest[j] == '"' or rest[j] == '\'')) j += 1;
            if (j >= rest.len or (rest[j] != '=' and rest[j] != ':')) continue;
            j += 1;
            if (j < rest.len and rest[j] == ' ') j += 1;
            if (j < rest.len and (rest[j] == '"' or rest[j] == '\'')) {
                const quote = rest[j];
                const keep = j + 1; // include the opening quote verbatim
                const close_rel = std.mem.indexOfScalarPos(u8, rest, keep, quote) orelse continue;
                const inner_len = close_rel - keep;
                if (inner_len >= 4) return .{ .len = close_rel, .keep = keep };
                continue;
            }
            const tail = nonSpaceLen(rest[j..]);
            if (tail >= 4) return .{ .len = j + tail, .keep = j };
        }
    }
    // Long hex run (>=64) — sha256-style tokens; 40-hex git SHAs pass through.
    const probe = rest[0..@min(rest.len, PROBE_CAP)];
    const hex_probe = hexLen(probe);
    if (hex_probe >= 64) {
        // Genuine hex run: walk to its true end. Amortized-safe: the walk
        // always ends in a consumed match, so each byte is visited once.
        var end = hex_probe;
        while (end < rest.len and std.ascii.isHex(rest[end])) end += 1;
        return .{ .len = end };
    }
    // Long mixed-case base64-ish run (>=40) with upper+lower+digit. The
    // mixed-class check runs on the PROBE WINDOW BEFORE extending: ordinary
    // hyphenated lowercase text (the O(n^2) pathology) fails here and never
    // pays the extension walk. Extension only happens when we will mask, so
    // it is amortized O(n) overall — and the WHOLE run gets masked, no
    // partial-mask tail leak.
    //
    // Deliberate semantic: a 40+ base64 run whose first 128 bytes lack an
    // upper/lower/digit mix is not masked even if the mix appears later.
    // Conservative — token-like secrets mix classes early.
    const b64_probe = base64Len(probe);
    if (b64_probe >= 40 and hasMixedClasses(probe[0..b64_probe])) {
        var end = b64_probe;
        while (end < rest.len and isBase64Char(rest[end])) end += 1;
        return .{ .len = end };
    }
    return null;
}

fn tokenLen(s: []const u8) usize {
    var n: usize = 0;
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
    while (n < s.len and isBase64Char(s[n])) n += 1;
    return n;
}

fn isBase64Char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=' or c == '_' or c == '-';
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
        .{ .in = "password=\"hunter22\"", .expect_masked = true },
        .{ .in = "\"password\": \"hunter22\"", .expect_masked = true },
        .{ .in = "\"token\": \"abcd1234\"", .expect_masked = true },
        .{ .in = "token: 'abcd1234'", .expect_masked = true },
        .{ .in = "hash 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef end", .expect_masked = true },
        .{ .in = "jwt AbC1dEf2GhI3jKl4MnO5pQr6StU7vWx8Yz90AbC1 sig", .expect_masked = true },
        // Negatives:
        .{ .in = "the task-brief file", .expect_masked = false }, // sk- not at boundary
        .{ .in = "sk-short", .expect_masked = false }, // tail < 8
        .{ .in = "commit 74707cdfd1b3f4b21c9a8e5d6f7a8b9c0d1e2f3a fixed it", .expect_masked = false }, // 40-hex git SHA
        .{ .in = "the token was expired", .expect_masked = false }, // no = or :
        .{ .in = "password= ", .expect_masked = false }, // empty value
        .{ .in = "password=\"\"", .expect_masked = false }, // empty quoted value
        .{ .in = "\"note\": \"hi\"", .expect_masked = false }, // not a KV key
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

test "memory_digest_redact: quoted KV value keeps quotes, masks only the inner value" {
    const out = try redact(std.testing.allocator, "password=\"hunter22\" x");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("password=\"" ++ MASK ++ "\" x", out);
}

test "memory_digest_redact: masks whole prefixed key" {
    const out = try redact(std.testing.allocator, "use sk-abc12345678 now");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("use " ++ MASK ++ " now", out);
}

test "memory_digest_redact: pathological hyphenated input stays bounded (no quadratic hang)" {
    const alloc = std.testing.allocator;
    const unit = "ab-cd-ef-gh-";
    const target_len = 128 * 1024;
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    while (input.items.len < target_len) try input.appendSlice(alloc, unit);

    const out = try redact(alloc, input.items);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(input.items, out);
}

test "memory_digest_redact: long hex run past probe cap is fully masked" {
    const run = "0123456789abcdef" ** 13; // 208 hex chars, well past PROBE_CAP
    const input = "hash " ++ run ++ " end";
    const out = try redact(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hash " ++ MASK ++ " end", out);
}

test "memory_digest_redact: 5000-byte hex secret is fully masked, no partial tail leak" {
    const alloc = std.testing.allocator;
    var run: std.ArrayListUnmanaged(u8) = .empty;
    defer run.deinit(alloc);
    while (run.items.len < 5000) try run.appendSlice(alloc, "0123456789abcdef");

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try input.appendSlice(alloc, "hash ");
    try input.appendSlice(alloc, run.items);
    try input.appendSlice(alloc, " end");

    const out = try redact(alloc, input.items);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hash " ++ MASK ++ " end", out);
}
