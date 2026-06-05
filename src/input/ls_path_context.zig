//! Smart path context for ctrl+click: infer a directory prefix from a nearby
//! `ls <dir>/` command line so bare-filename clicks resolve to the right file.
//! Pure logic only — no terminal/Surface dependency — so it is unit-testable.

const std = @import("std");

/// Command names whose single trailing-`/` argument we treat as a path prefix.
const ls_commands = [_][]const u8{ "ls", "ll", "la", "l", "dir" };

fn isLsCommand(tok: []const u8) bool {
    for (ls_commands) |cmd| {
        if (std.mem.eql(u8, tok, cmd)) return true;
    }
    return false;
}

/// If `line` is an `ls`-family command with exactly one directory argument
/// (a non-flag token ending in `/`), return that directory (a slice into
/// `line`). Returns null for zero args, multiple non-flag args, a sole
/// argument not ending in `/`, or a non-ls command. The command token may be
/// preceded by an arbitrary prompt prefix.
pub fn parseLsDirArg(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");

    var found_cmd = false;
    while (it.next()) |tok| {
        if (isLsCommand(tok)) {
            found_cmd = true;
            break;
        }
    }
    if (!found_cmd) return null;

    var dir: ?[]const u8 = null;
    while (it.next()) |tok| {
        if (tok.len > 0 and tok[0] == '-') continue; // flag
        if (dir != null) return null; // >1 non-flag arg → ambiguous
        dir = tok;
    }

    const d = dir orelse return null; // ls of CWD, no dir arg
    if (d.len == 0 or d[d.len - 1] != '/') return null; // must be a directory
    return d;
}

test "parseLsDirArg: ls with a trailing-slash dir" {
    try std.testing.expectEqualStrings("Ath/Ph_SE/", parseLsDirArg("ls Ath/Ph_SE/").?);
}

test "parseLsDirArg: tolerates a prompt prefix" {
    try std.testing.expectEqualStrings("Ath/Ph_SE/", parseLsDirArg("$ ls Ath/Ph_SE/").?);
    try std.testing.expectEqualStrings("data/", parseLsDirArg("me@box:~/proj$ ls data/").?);
}

test "parseLsDirArg: skips flags" {
    try std.testing.expectEqualStrings("Ath/", parseLsDirArg("ls -la Ath/").?);
    try std.testing.expectEqualStrings("Ath/", parseLsDirArg("ls --color=auto Ath/").?);
}

test "parseLsDirArg: accepts ls-family aliases" {
    try std.testing.expectEqualStrings("d/", parseLsDirArg("ll d/").?);
    try std.testing.expectEqualStrings("d/", parseLsDirArg("la d/").?);
    try std.testing.expectEqualStrings("d/", parseLsDirArg("l d/").?);
    try std.testing.expectEqualStrings("d/", parseLsDirArg("dir d/").?);
}

test "parseLsDirArg: rejects non-ls and lookalike commands" {
    try std.testing.expect(parseLsDirArg("lsblk d/") == null);
    try std.testing.expect(parseLsDirArg("cat foo.txt") == null);
    try std.testing.expect(parseLsDirArg("~/tools/ls d/") == null);
}

test "parseLsDirArg: rejects zero, multiple, and non-dir args" {
    try std.testing.expect(parseLsDirArg("ls") == null);
    try std.testing.expect(parseLsDirArg("ls -la") == null);
    try std.testing.expect(parseLsDirArg("ls A/ B/") == null);
    try std.testing.expect(parseLsDirArg("ls foo.txt") == null);
    try std.testing.expect(parseLsDirArg("ls Ath") == null);
}
