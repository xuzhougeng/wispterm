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

/// Minimal view of a chat message for first-turn extraction.
pub const TurnMessage = struct {
    role: Role,
    content: []const u8,
};

pub const FirstTurn = struct {
    user: []const u8,
    assistant: []const u8,
};

/// Return the first user message and the first assistant message, skipping all
/// tool messages (agent-mode tool-call progress / tool results). Returns null
/// if either a user or an assistant message is missing.
pub fn extractFirstTurn(messages: []const TurnMessage) ?FirstTurn {
    var user: ?[]const u8 = null;
    var assistant: ?[]const u8 = null;
    for (messages) |m| {
        switch (m.role) {
            .user => if (user == null) {
                user = m.content;
            },
            .assistant => if (assistant == null) {
                assistant = m.content;
            },
            .tool => {},
        }
    }
    if (user == null or assistant == null) return null;
    return .{ .user = user.?, .assistant = assistant.? };
}

test "extractFirstTurn: first user + first assistant, skipping tool messages" {
    const msgs = [_]TurnMessage{
        .{ .role = .user, .content = "deploy the app" },
        .{ .role = .tool, .content = "running build" },
        .{ .role = .tool, .content = "build ok" },
        .{ .role = .assistant, .content = "Deployed successfully." },
        .{ .role = .assistant, .content = "second answer" },
    };
    const turn = extractFirstTurn(&msgs).?;
    try std.testing.expectEqualStrings("deploy the app", turn.user);
    try std.testing.expectEqualStrings("Deployed successfully.", turn.assistant);
}

test "extractFirstTurn: null when assistant missing" {
    const msgs = [_]TurnMessage{
        .{ .role = .user, .content = "hi" },
        .{ .role = .tool, .content = "x" },
    };
    try std.testing.expect(extractFirstTurn(&msgs) == null);
}

test "extractFirstTurn: null when empty" {
    const msgs = [_]TurnMessage{};
    try std.testing.expect(extractFirstTurn(&msgs) == null);
}

test "extractFirstTurn: null when user missing" {
    const msgs = [_]TurnMessage{
        .{ .role = .assistant, .content = "hello" },
        .{ .role = .tool, .content = "x" },
    };
    try std.testing.expect(extractFirstTurn(&msgs) == null);
}

pub const TitleGate = struct {
    attempted: bool,
    has_api_key: bool,
    title: []const u8,
    default_name: []const u8,
};

/// Auto-title fires only when: not attempted yet, an API key is configured, the
/// title is still the default (user has not renamed), and a first turn exists.
pub fn shouldAutoTitle(gate: TitleGate, turn: ?FirstTurn) bool {
    if (gate.attempted) return false;
    if (!gate.has_api_key) return false;
    if (!std.mem.eql(u8, gate.title, gate.default_name)) return false;
    return turn != null;
}

test "shouldAutoTitle: fires on first turn with default title and key" {
    const turn = FirstTurn{ .user = "u", .assistant = "a" };
    try std.testing.expect(shouldAutoTitle(.{
        .attempted = false,
        .has_api_key = true,
        .title = "DeepSeek",
        .default_name = "DeepSeek",
    }, turn));
}

test "shouldAutoTitle: blocked when title not default" {
    const turn = FirstTurn{ .user = "u", .assistant = "a" };
    try std.testing.expect(!shouldAutoTitle(.{
        .attempted = false,
        .has_api_key = true,
        .title = "My chat",
        .default_name = "DeepSeek",
    }, turn));
}

test "shouldAutoTitle: blocked when attempted / no key / no turn" {
    const turn = FirstTurn{ .user = "u", .assistant = "a" };
    const base = TitleGate{
        .attempted = false,
        .has_api_key = true,
        .title = "DeepSeek",
        .default_name = "DeepSeek",
    };
    try std.testing.expect(!shouldAutoTitle(.{
        .attempted = true,
        .has_api_key = base.has_api_key,
        .title = base.title,
        .default_name = base.default_name,
    }, turn));
    try std.testing.expect(!shouldAutoTitle(.{
        .attempted = base.attempted,
        .has_api_key = false,
        .title = base.title,
        .default_name = base.default_name,
    }, turn));
    try std.testing.expect(!shouldAutoTitle(base, null));
}

fn isTitleSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

const quote_pairs = [_]struct { open: []const u8, close: []const u8 }{
    .{ .open = "\"", .close = "\"" },
    .{ .open = "'", .close = "'" },
    .{ .open = "`", .close = "`" },
    .{ .open = "\u{201C}", .close = "\u{201D}" },
    .{ .open = "\u{300C}", .close = "\u{300D}" },
    .{ .open = "\u{300E}", .close = "\u{300F}" },
    .{ .open = "\u{300A}", .close = "\u{300B}" },
};

fn stripSurroundingQuotes(s: []const u8) []const u8 {
    for (quote_pairs) |pair| {
        if (s.len >= pair.open.len + pair.close.len and
            std.mem.startsWith(u8, s, pair.open) and
            std.mem.endsWith(u8, s, pair.close))
        {
            return s[pair.open.len .. s.len - pair.close.len];
        }
    }
    return s;
}

const cjk_trailing_puncts = [_][]const u8{ "\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{FF0C}", "\u{3001}", "\u{FF1B}", "\u{FF1A}" };

fn stripTrailingNoise(s: []const u8) []const u8 {
    var end = s.len;
    outer: while (end > 0) {
        const c = s[end - 1];
        if (isTitleSpace(c) or c == '.' or c == ',' or c == '!' or
            c == '?' or c == ';' or c == ':')
        {
            end -= 1;
            continue;
        }
        for (cjk_trailing_puncts) |p| {
            if (end >= p.len and std.mem.eql(u8, s[end - p.len .. end], p)) {
                end -= p.len;
                continue :outer;
            }
        }
        break;
    }
    return s[0..end];
}

/// Drop a trailing partial UTF-8 sequence (if `s` was byte-cut mid-codepoint).
fn trimIncompleteUtf8(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if ((s[i] & 0xC0) != 0x80) break; // found a leading byte
    }
    const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[0..i];
    if (i + cp_len <= s.len) return s; // complete
    return s[0..i]; // incomplete tail
}

fn looksLikeApiErrorJson(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "{") and
        std.mem.indexOf(u8, trimmed, "\"error\"") != null;
}

/// Clean a raw model response into a display title written into `out`
/// (must be >= `max_title_bytes`). Returns the populated slice, or null if the
/// cleaned title is empty.
/// Steps: take first line, trim, strip a single pair of surrounding quotes,
/// collapse internal whitespace to single spaces (clamped to max_title_bytes on
/// a UTF-8 boundary), then strip trailing whitespace / sentence punctuation.
pub fn cleanTitle(raw: []const u8, out: []u8) ?[]const u8 {
    std.debug.assert(out.len >= max_title_bytes);
    const trimmed_raw = std.mem.trim(u8, raw, " \t\r\n");
    if (looksLikeApiErrorJson(trimmed_raw)) return null;

    var line = trimmed_raw;
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
    line = std.mem.trim(u8, line, " \t\r\n");
    line = stripSurroundingQuotes(line);
    line = std.mem.trim(u8, line, " \t\r\n");

    var w: usize = 0;
    var pending_space = false;
    for (line) |c| {
        if (isTitleSpace(c)) {
            if (w > 0) pending_space = true;
            continue;
        }
        if (pending_space) {
            if (w >= max_title_bytes) break;
            out[w] = ' ';
            w += 1;
            pending_space = false;
        }
        if (w >= max_title_bytes) break;
        out[w] = c;
        w += 1;
    }

    var cleaned = trimIncompleteUtf8(out[0..w]);
    cleaned = stripTrailingNoise(cleaned);
    if (cleaned.len == 0) return null;
    return cleaned;
}

test "cleanTitle: first line, strip quotes, collapse spaces" {
    var buf: [max_title_bytes]u8 = undefined;
    const t = cleanTitle("  \"Deploy   the   App\"\nextra line ", &buf).?;
    try std.testing.expectEqualStrings("Deploy the App", t);
}

test "cleanTitle: strip trailing punctuation (ascii + cjk)" {
    var buf: [max_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Set up titles", cleanTitle("Set up titles.", &buf).?);
    try std.testing.expectEqualStrings("配置自动命名", cleanTitle("配置自动命名。", &buf).?);
}

test "cleanTitle: strip CJK corner-bracket quotes" {
    var buf: [max_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("部署应用", cleanTitle("「部署应用」", &buf).?);
}

test "cleanTitle: empty / whitespace returns null" {
    var buf: [max_title_bytes]u8 = undefined;
    try std.testing.expect(cleanTitle("   \n  ", &buf) == null);
    try std.testing.expect(cleanTitle("", &buf) == null);
}

test "cleanTitle: rejects raw API error JSON" {
    var buf: [max_title_bytes]u8 = undefined;
    try std.testing.expect(cleanTitle(
        "{\"error\":{\"message\":\"thinking options type cannot be disabled when reasoning_effort is set\"}}",
        &buf,
    ) == null);
}

test "cleanTitle: clamps to max_title_bytes on UTF-8 boundary" {
    var buf: [max_title_bytes]u8 = undefined;
    const long = "一" ** 50; // 150 bytes of U+4E00 (3 bytes each)
    const t = cleanTitle(long, &buf).?;
    try std.testing.expect(t.len <= max_title_bytes);
    try std.testing.expect(t.len % 3 == 0); // never split a codepoint
    try std.testing.expect(std.unicode.utf8ValidateSlice(t));
}

/// Truncate `s` to at most `max_section_bytes` on a UTF-8 boundary.
fn truncateSection(s: []const u8) []const u8 {
    return s[0..utf8SafeLen(s, max_section_bytes)];
}

/// Build the user-content message ("User: ...\n\nAssistant: ...") for the title
/// request. Each section is truncated to `max_section_bytes` on a UTF-8 boundary.
pub fn buildUserContent(allocator: std.mem.Allocator, turn: FirstTurn) ![]u8 {
    return std.fmt.allocPrint(allocator, "User: {s}\n\nAssistant: {s}", .{
        truncateSection(turn.user),
        truncateSection(turn.assistant),
    });
}

test "buildUserContent: formats user + assistant sections" {
    const turn = FirstTurn{ .user = "hello", .assistant = "world" };
    const c = try buildUserContent(std.testing.allocator, turn);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("User: hello\n\nAssistant: world", c);
}

test "buildUserContent: truncates each section on UTF-8 boundary" {
    const big = "一" ** 1000; // 3000 bytes, exceeds max_section_bytes (1500)
    const turn = FirstTurn{ .user = big, .assistant = "ok" };
    const c = try buildUserContent(std.testing.allocator, turn);
    defer std.testing.allocator.free(c);
    // "User: " + truncated + "\n\nAssistant: ok"
    try std.testing.expect(std.mem.startsWith(u8, c, "User: "));
    try std.testing.expect(std.mem.endsWith(u8, c, "\n\nAssistant: ok"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(c));
    // user section bytes <= max_section_bytes
    const after_prefix = c["User: ".len..];
    const user_section = after_prefix[0..std.mem.indexOf(u8, after_prefix, "\n\n").?];
    try std.testing.expect(user_section.len <= max_section_bytes);
}

test "buildUserContent: truncates assistant section on UTF-8 boundary" {
    const big = "一" ** 1000; // 3000 bytes > max_section_bytes
    const turn = FirstTurn{ .user = "ok", .assistant = big };
    const c = try buildUserContent(std.testing.allocator, turn);
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.mem.startsWith(u8, c, "User: ok\n\nAssistant: "));
    try std.testing.expect(std.unicode.utf8ValidateSlice(c));
    const marker = "\n\nAssistant: ";
    const assistant_section = c[std.mem.indexOf(u8, c, marker).? + marker.len ..];
    try std.testing.expect(assistant_section.len <= max_section_bytes);
}
