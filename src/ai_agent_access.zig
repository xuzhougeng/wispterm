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

fn expandHome(a: std.mem.Allocator, raw: []const u8, home: []const u8) ![]const u8 {
    if (std.mem.eql(u8, raw, "~")) return a.dupe(u8, home);
    if (std.mem.startsWith(u8, raw, "~/")) return std.fmt.allocPrint(a, "{s}{s}", .{ home, raw[1..] });
    if (std.mem.eql(u8, raw, "$HOME")) return a.dupe(u8, home);
    if (std.mem.startsWith(u8, raw, "$HOME/")) return std.fmt.allocPrint(a, "{s}{s}", .{ home, raw[5..] });
    if (std.mem.eql(u8, raw, "${HOME}")) return a.dupe(u8, home);
    if (std.mem.startsWith(u8, raw, "${HOME}/")) return std.fmt.allocPrint(a, "{s}{s}", .{ home, raw[7..] });
    return a.dupe(u8, raw);
}

fn lexicalNormalize(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const absolute = path.len > 0 and path[0] == '/';
    var stack: List = .empty;
    defer stack.deinit(a);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (stack.items.len > 0 and !std.mem.eql(u8, stack.items[stack.items.len - 1], "..")) {
                _ = stack.pop();
            } else if (!absolute) {
                try stack.append(a, "..");
            }
            continue;
        }
        try stack.append(a, comp);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    if (absolute) try out.append(a, '/');
    for (stack.items, 0..) |comp, i| {
        if (i != 0) try out.append(a, '/');
        try out.appendSlice(a, comp);
    }
    if (out.items.len == 0) try out.append(a, '.');
    return out.toOwnedSlice(a);
}

fn stripQuotes(token: []const u8) []const u8 {
    if (token.len >= 2 and (token[0] == '"' or token[0] == '\'') and token[token.len - 1] == token[0]) {
        return token[1 .. token.len - 1];
    }
    return token;
}

/// Resolve a command-line token to a normalized absolute (or cwd-relative)
/// path, or null for non-path tokens (empty / option flags). `a` MUST be an
/// arena: the returned string and its intermediates (`expanded`, `joined`) all
/// come from `a` and are not freed individually. Every caller (parseRules,
/// evaluate) passes a scratch arena.
fn resolveToken(a: std.mem.Allocator, token: []const u8, home: []const u8, cwd: ?[]const u8) !?[]const u8 {
    const t = stripQuotes(token);
    if (t.len == 0 or t[0] == '-') return null;
    const expanded = try expandHome(a, t, home);
    if (expanded.len > 0 and expanded[0] == '/') return try lexicalNormalize(a, expanded);
    if (cwd) |c| {
        const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ c, expanded });
        return try lexicalNormalize(a, joined);
    }
    return try lexicalNormalize(a, expanded);
}

fn matchesRoot(path: []const u8, root: []const u8) bool {
    if (root.len == 0) return false;
    if (std.mem.eql(u8, path, root)) return true;
    if (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/') return true;
    return false;
}

fn looksLikePath(token: []const u8) bool {
    const t = stripQuotes(token);
    if (t.len == 0 or t[0] == '-') return false;
    if (std.mem.indexOfScalar(u8, t, '/') != null) return true;
    if (t[0] == '~' or t[0] == '.' or t[0] == '/') return true;
    if (std.mem.startsWith(u8, t, "$HOME") or std.mem.startsWith(u8, t, "${HOME}")) return true;
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

test "expandHome expands ~ and $HOME prefixes" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = arena.allocator();
    try std.testing.expectEqualStrings("/home/u/.ssh", try expandHome(z, "~/.ssh", "/home/u"));
    try std.testing.expectEqualStrings("/home/u", try expandHome(z, "~", "/home/u"));
    try std.testing.expectEqualStrings("/home/u/.aws", try expandHome(z, "$HOME/.aws", "/home/u"));
    try std.testing.expectEqualStrings("/home/u/x", try expandHome(z, "${HOME}/x", "/home/u"));
    try std.testing.expectEqualStrings("/etc/passwd", try expandHome(z, "/etc/passwd", "/home/u"));
}

test "lexicalNormalize collapses . and .. and trailing slashes" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = arena.allocator();
    try std.testing.expectEqualStrings("/home/u/.ssh", try lexicalNormalize(z, "/home/u/./.ssh/"));
    try std.testing.expectEqualStrings("/home/.ssh", try lexicalNormalize(z, "/home/u/../.ssh"));
    try std.testing.expectEqualStrings("/", try lexicalNormalize(z, "/"));
    try std.testing.expectEqualStrings("a/b", try lexicalNormalize(z, "a/./b"));
}

test "resolveToken expands, strips quotes, and resolves against cwd" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = arena.allocator();
    try std.testing.expectEqualStrings("/home/u/.ssh/id_rsa", (try resolveToken(z, "~/.ssh/id_rsa", "/home/u", null)).?);
    try std.testing.expectEqualStrings("/home/u/.ssh/cfg", (try resolveToken(z, "\"$HOME/.ssh/cfg\"", "/home/u", "/tmp")).?);
    try std.testing.expectEqualStrings("/work/a.txt", (try resolveToken(z, "a.txt", "/home/u", "/work")).?);
    try std.testing.expect((try resolveToken(z, "-rf", "/home/u", "/work")) == null);
}

test "matchesRoot is a path-component prefix match" {
    try std.testing.expect(matchesRoot("/home/u/.ssh", "/home/u/.ssh"));
    try std.testing.expect(matchesRoot("/home/u/.ssh/id_rsa", "/home/u/.ssh"));
    try std.testing.expect(!matchesRoot("/home/u/.sshconfig", "/home/u/.ssh"));
    try std.testing.expect(!matchesRoot("/home/u", "/home/u/.ssh"));
}

test "looksLikePath recognizes path-shaped tokens" {
    try std.testing.expect(looksLikePath("~/.ssh"));
    try std.testing.expect(looksLikePath("/etc/passwd"));
    try std.testing.expect(looksLikePath("./rel"));
    try std.testing.expect(looksLikePath("a/b"));
    try std.testing.expect(looksLikePath(".env"));
    try std.testing.expect(!looksLikePath("grep"));
    try std.testing.expect(!looksLikePath("-rf"));
}
