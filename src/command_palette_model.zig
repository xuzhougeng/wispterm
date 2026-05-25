const std = @import("std");

pub const ResultGroup = enum {
    command_title,
    command_secondary,
    ssh_profile,
    theme,
};

pub fn resultGroupRank(group: ResultGroup) u8 {
    return switch (group) {
        .command_title => 0,
        .command_secondary => 1,
        .ssh_profile => 2,
        .theme => 3,
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

test "command palette model orders SSH results after commands and before themes" {
    try std.testing.expect(resultGroupRank(.command_title) < resultGroupRank(.command_secondary));
    try std.testing.expect(resultGroupRank(.command_secondary) < resultGroupRank(.ssh_profile));
    try std.testing.expect(resultGroupRank(.ssh_profile) < resultGroupRank(.theme));
}
