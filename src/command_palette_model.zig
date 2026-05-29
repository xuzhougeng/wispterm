const std = @import("std");

pub const ResultGroup = enum {
    command_title,
    command_secondary,
    ssh_profile,
    ai_profile,
    theme,
};

pub fn resultGroupRank(group: ResultGroup) u8 {
    return switch (group) {
        .command_title => 0,
        .command_secondary => 1,
        .ssh_profile => 2,
        .ai_profile => 3,
        .theme => 4,
    };
}

fn lowerAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
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

pub fn shouldSearchSshProfiles(filter: []const u8) bool {
    return filter.len > 0;
}

pub fn sshProfileNameMatchesFilter(name: []const u8, filter: []const u8) bool {
    return shouldSearchSshProfiles(filter) and containsIgnoreCase(name, filter);
}

/// Whitelist validator for an OpenSSH `ProxyJump` specification before it is
/// spliced into a spawned `ssh` command line. An empty spec is valid (no jump
/// host). A non-empty spec must consist only of characters that appear in
/// `[user@]host[:port]` hops, optionally comma-separated for multi-hop chains:
/// alphanumerics plus `. - _ @ : ,`. This rejects spaces, quotes, and shell
/// metacharacters that could break out of the argument.
pub fn isProxyJumpSafe(spec: []const u8) bool {
    if (spec.len == 0) return true;
    for (spec) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or
            ch == '.' or ch == '-' or ch == '_' or
            ch == '@' or ch == ':' or ch == ',';
        if (!ok) return false;
    }
    return true;
}

/// True when a non-empty filter should surface an AI profile launch row.
/// Any filter that is a substring of "ai" (i.e. "a", "i", or "ai") lists
/// every profile; otherwise the filter must match part of the name.
pub fn aiProfileLabelMatchesFilter(name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return false;
    return containsIgnoreCase(name, filter) or containsIgnoreCase("ai", filter);
}

/// Index of the profile whose name equals `default_name`. Returns 0 when
/// `default_name` is empty or unmatched (caller guards the empty-list case).
pub fn resolveDefaultIndex(names: []const []const u8, default_name: []const u8) usize {
    if (default_name.len == 0) return 0;
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name, default_name)) return i;
    }
    return 0;
}

test "command palette model matches SSH profile names case-insensitively" {
    try std.testing.expect(sshProfileNameMatchesFilter("LabServer", "labserver"));
}

test "command palette model hides SSH profiles when filter is empty" {
    try std.testing.expect(!shouldSearchSshProfiles(""));
    try std.testing.expect(!sshProfileNameMatchesFilter("LabServer", ""));
}

test "command palette model does not match non-name SSH profile fields" {
    try std.testing.expect(!sshProfileNameMatchesFilter("ProdBox", "needle-host"));
    try std.testing.expect(!sshProfileNameMatchesFilter("ProdBox", "needle-user"));
}

test "proxy jump validator accepts empty and well-formed hop specs" {
    try std.testing.expect(isProxyJumpSafe("")); // optional field
    try std.testing.expect(isProxyJumpSafe("jump.example.test"));
    try std.testing.expect(isProxyJumpSafe("admin@jump.example.test"));
    try std.testing.expect(isProxyJumpSafe("admin@jump.example.test:2200"));
    try std.testing.expect(isProxyJumpSafe("admin@first.test,user@second.test:22"));
}

test "proxy jump validator rejects shell metacharacters and whitespace" {
    try std.testing.expect(!isProxyJumpSafe("jump.test; rm -rf /"));
    try std.testing.expect(!isProxyJumpSafe("jump.test && evil"));
    try std.testing.expect(!isProxyJumpSafe("jump.test $(whoami)"));
    try std.testing.expect(!isProxyJumpSafe("jump.test|cat"));
    try std.testing.expect(!isProxyJumpSafe("two hosts"));
    try std.testing.expect(!isProxyJumpSafe("`backtick`"));
}

test "command palette model orders SSH results after commands and before themes" {
    try std.testing.expect(resultGroupRank(.command_title) < resultGroupRank(.command_secondary));
    try std.testing.expect(resultGroupRank(.command_secondary) < resultGroupRank(.ssh_profile));
    try std.testing.expect(resultGroupRank(.ssh_profile) < resultGroupRank(.theme));
}

test "ai profile label matches the ai token and the name" {
    try std.testing.expect(aiProfileLabelMatchesFilter("DeepSeek", "ai"));
    try std.testing.expect(aiProfileLabelMatchesFilter("DeepSeek", "deep"));
    try std.testing.expect(aiProfileLabelMatchesFilter("DeepSeek", "SEEK"));
}

test "ai profile label does not match unrelated filter and hides on empty" {
    try std.testing.expect(!aiProfileLabelMatchesFilter("DeepSeek", "gpt"));
    try std.testing.expect(!aiProfileLabelMatchesFilter("DeepSeek", ""));
}

test "resolve default index matches by name with fallback to first" {
    const names = [_][]const u8{ "DeepSeek", "GPT-4o", "Local" };
    try std.testing.expectEqual(@as(usize, 1), resolveDefaultIndex(&names, "GPT-4o"));
    try std.testing.expectEqual(@as(usize, 0), resolveDefaultIndex(&names, ""));
    try std.testing.expectEqual(@as(usize, 0), resolveDefaultIndex(&names, "missing"));
}

test "command palette model orders AI profiles between SSH and themes" {
    try std.testing.expect(resultGroupRank(.ssh_profile) < resultGroupRank(.ai_profile));
    try std.testing.expect(resultGroupRank(.ai_profile) < resultGroupRank(.theme));
}
