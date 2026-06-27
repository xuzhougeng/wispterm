const std = @import("std");
const text_search = @import("text_search.zig");

pub const ResultGroup = enum {
    command_title,
    command_secondary,
    ssh_profile,
    tmux_profile,
    ai_profile,
    theme,
};

pub fn resultGroupRank(group: ResultGroup) u8 {
    return switch (group) {
        .command_title => 0,
        .command_secondary => 1,
        .ssh_profile => 2,
        .tmux_profile => 3,
        .ai_profile => 4,
        .theme => 5,
    };
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return text_search.containsIgnoreCase(haystack, needle);
}

pub fn shouldSearchSshProfiles(filter: []const u8) bool {
    return filter.len > 0;
}

pub fn sshProfileNameMatchesFilter(name: []const u8, filter: []const u8) bool {
    return shouldSearchSshProfiles(filter) and containsIgnoreCase(name, filter);
}

pub fn tmuxProfileMatchesFilter(name: []const u8, filter: []const u8) bool {
    return shouldSearchSshProfiles(filter) and
        (containsIgnoreCase(name, filter) or std.ascii.eqlIgnoreCase(filter, "tmux"));
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

/// Index reached by stepping `delta` positions from `current` among `count`
/// items, wrapping in both directions. `delta` is typically +1 (next) or -1
/// (previous). Returns 0 when `count` is 0 (caller guards the empty-list case).
pub fn cycleIndex(current: usize, count: usize, delta: i64) usize {
    if (count == 0) return 0;
    const n: i64 = @intCast(count);
    const cur: i64 = @intCast(current % count);
    return @intCast(@mod(cur + delta, n));
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

test "command palette model matches tmux profiles by name or tmux token" {
    try std.testing.expect(tmuxProfileMatchesFilter("CPU2", "cpu"));
    try std.testing.expect(tmuxProfileMatchesFilter("CPU2", "TMUX"));
    try std.testing.expect(!tmuxProfileMatchesFilter("CPU2", "ssh"));
    try std.testing.expect(!tmuxProfileMatchesFilter("CPU2", ""));
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
    try std.testing.expect(resultGroupRank(.ssh_profile) < resultGroupRank(.tmux_profile));
    try std.testing.expect(resultGroupRank(.tmux_profile) < resultGroupRank(.theme));
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

test "cycle index steps forward and backward with wrap-around" {
    // Forward (next) advances and wraps past the end.
    try std.testing.expectEqual(@as(usize, 1), cycleIndex(0, 3, 1));
    try std.testing.expectEqual(@as(usize, 0), cycleIndex(2, 3, 1));
    // Backward (previous) retreats and wraps below the start.
    try std.testing.expectEqual(@as(usize, 2), cycleIndex(0, 3, -1));
    try std.testing.expectEqual(@as(usize, 1), cycleIndex(2, 3, -1));
    // Single element stays put in either direction.
    try std.testing.expectEqual(@as(usize, 0), cycleIndex(0, 1, 1));
    try std.testing.expectEqual(@as(usize, 0), cycleIndex(0, 1, -1));
    // Empty list is guarded.
    try std.testing.expectEqual(@as(usize, 0), cycleIndex(0, 0, 1));
}

test "command palette model orders AI profiles between SSH and themes" {
    try std.testing.expect(resultGroupRank(.tmux_profile) < resultGroupRank(.ai_profile));
    try std.testing.expect(resultGroupRank(.ai_profile) < resultGroupRank(.theme));
}
