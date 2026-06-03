//! Private file-access guard for the AI agent. Pure + Session-free so it lives
//! in the fast test suite. Reads ride on arbitrary shell commands, so this is a
//! heuristic command-string gate (bias: over-trigger deny, under-trigger allow),
//! not an OS sandbox.
//! Spec: docs/superpowers/specs/2026-06-03-agent-file-access-guard-design.md
const std = @import("std");

const MAX_RULES_BYTES = 64 * 1024;
const List = std.ArrayListUnmanaged([]const u8);

pub const Decision = enum { neutral, blacklisted, whitelisted_safe };

pub const EvalResult = struct {
    decision: Decision = .neutral,
    /// Borrowed slice into the input command: the token that tripped the deny list.
    matched: []const u8 = "",
};

/// Compiled-in secure-by-default deny entries. Entries containing '/' (or a
/// leading '~') are directory/file path prefixes; bare names are basename globs.
pub const BUILTIN_DENY = [_][]const u8{
    "~/.ssh",
    "~/.aws",
    "~/.gnupg",
    "~/.config/gh",
    "~/.config/wispterm",
    "~/.kube",
    "~/.netrc",
    "~/.docker/config.json",
    "*.pem",
    "*.key",
    ".env",
};

const READ_ONLY_VERBS = [_][]const u8{
    "cat",      "bat",  "head",   "tail",     "less",     "more", "grep",
    "egrep",    "fgrep", "rg",    "ag",       "ls",       "ll",   "find",
    "stat",     "file", "wc",     "nl",       "od",       "xxd",  "hexdump",
    "strings",  "cut",  "sort",   "uniq",     "diff",     "tree", "readlink",
    "realpath", "dirname", "basename", "pwd",
};

pub const AccessRules = struct {
    arena: std.heap.ArenaAllocator,
    home: []const u8,
    allow_roots: [][]const u8,
    deny_roots: [][]const u8,
    deny_names: [][]const u8,

    pub fn deinit(self: *AccessRules) void {
        self.arena.deinit();
    }
};

pub fn parseRules(allocator: std.mem.Allocator, contents: []const u8, home: []const u8) !AccessRules {
    _ = contents;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    // All arena allocations must happen *before* the struct literal so the
    // arena's buffer_list is fully populated when the struct value is copied
    // into the caller. Struct fields evaluate in declaration order, so an
    // inline `try a.dupe(...)` in a later field allocates only *after*
    // `.arena = arena` has already copied the (then-empty) arena — leaving the
    // returned struct's arena with a stale buffer_list and leaking the buffer.
    const home_copy = try a.dupe(u8, home);
    return .{
        .arena = arena,
        .home = home_copy,
        .allow_roots = &.{},
        .deny_roots = &.{},
        .deny_names = &.{},
    };
}

pub fn loadRules(allocator: std.mem.Allocator, file_path: []const u8, home: []const u8) !AccessRules {
    _ = file_path;
    return parseRules(allocator, "", home);
}

pub fn evaluate(allocator: std.mem.Allocator, rules: *const AccessRules, command: []const u8, cwd: ?[]const u8) EvalResult {
    _ = allocator;
    _ = rules;
    _ = command;
    _ = cwd;
    return .{};
}

pub fn isReadOnlyCommand(command: []const u8) bool {
    _ = command;
    return false;
}

fn globMatch(pat: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;
    while (si < str.len) {
        if (pi < pat.len and (pat[pi] == '?' or pat[pi] == str[si])) {
            pi += 1;
            si += 1;
        } else if (pi < pat.len and pat[pi] == '*') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_si += 1;
            si = star_si;
        } else return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

test "module scaffold compiles and parseRules yields a valid struct" {
    var rules = try parseRules(std.testing.allocator, "", "/home/u");
    defer rules.deinit();
    try std.testing.expectEqualStrings("/home/u", rules.home);
    try std.testing.expectEqual(@as(usize, 0), rules.deny_roots.len);
}

test "globMatch handles wildcards and exact names" {
    try std.testing.expect(globMatch("*.pem", "server.pem"));
    try std.testing.expect(globMatch(".env", ".env"));
    try std.testing.expect(globMatch("id_*", "id_rsa"));
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(!globMatch("*.pem", "notes.txt"));
    try std.testing.expect(!globMatch(".env", "env"));
    try std.testing.expect(!globMatch("a?c", "ac"));
    try std.testing.expect(globMatch("a?c", "abc"));
}
