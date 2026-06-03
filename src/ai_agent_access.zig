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
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var allow: List = .empty;
    var deny: List = .empty;
    var names: List = .empty;

    // All arena allocations must happen *before* the struct literal so the
    // arena's buffer_list is fully populated when the struct value is copied
    // into the caller. Struct fields evaluate in declaration order, so an
    // inline `try a.dupe(...)` in a later field allocates only *after*
    // `.arena = arena` has already copied the (then-empty) arena — leaving the
    // returned struct's arena with a stale buffer_list and leaking the buffer.
    const home_copy = try a.dupe(u8, home);

    for (BUILTIN_DENY) |entry| {
        try addDenyEntry(a, &deny, &names, entry, home_copy);
    }

    var lines = std.mem.tokenizeAny(u8, contents, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (parseKeyword(line, "allow")) |rest| {
            // Skip a bare `allow` with no path: it would normalize to "." and
            // silently whitelist the whole cwd once evaluate() consults it.
            if (rest.len != 0) {
                const norm = try normalizeEntry(a, rest, home_copy);
                if (norm.len != 0) try allow.append(a, norm);
            }
        } else if (parseKeyword(line, "deny")) |rest| {
            try addDenyEntry(a, &deny, &names, rest, home_copy);
        } else {
            std.log.warn("agent-access: ignoring malformed rule line: {s}", .{line});
        }
    }

    // Finalize the slices before the struct literal copies the arena, so that
    // every allocation (including any toOwnedSlice node) lands in the arena
    // state captured by `.arena = arena` — see the buffer_list note above.
    const allow_slice = try allow.toOwnedSlice(a);
    const deny_slice = try deny.toOwnedSlice(a);
    const names_slice = try names.toOwnedSlice(a);
    return .{
        .arena = arena,
        .home = home_copy,
        .allow_roots = allow_slice,
        .deny_roots = deny_slice,
        .deny_names = names_slice,
    };
}

fn parseKeyword(line: []const u8, kw: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, kw)) return null;
    if (line.len == kw.len) return "";
    if (line[kw.len] != ' ' and line[kw.len] != '\t') return null;
    return std.mem.trim(u8, line[kw.len..], " \t");
}

fn addDenyEntry(a: std.mem.Allocator, deny: *List, names: *List, entry: []const u8, home: []const u8) !void {
    const e = std.mem.trim(u8, entry, " \t");
    if (e.len == 0) return;
    if (std.mem.indexOfScalar(u8, e, '/') == null and e[0] != '~') {
        try names.append(a, try a.dupe(u8, e));
    } else {
        const norm = try normalizeEntry(a, e, home);
        if (norm.len != 0) try deny.append(a, norm);
    }
}

fn normalizeEntry(a: std.mem.Allocator, raw: []const u8, home: []const u8) ![]const u8 {
    const expanded = try expandHome(a, raw, home);
    return lexicalNormalize(a, expanded);
}

pub fn loadRules(allocator: std.mem.Allocator, file_path: []const u8, home: []const u8) !AccessRules {
    // Any failure to read the private file (missing, is-a-dir, permission, I/O)
    // falls back to the built-in deny defaults so deny protection is never
    // silently disabled. A missing file is the normal case (no warning); other
    // errors warn but still degrade to built-ins.
    const contents = std.fs.cwd().readFileAlloc(allocator, file_path, MAX_RULES_BYTES) catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("agent-access: cannot read {s} ({s}); using built-in deny defaults only", .{ file_path, @errorName(err) });
        }
        return parseRules(allocator, "", home);
    };
    defer allocator.free(contents);
    return parseRules(allocator, contents, home);
}

pub fn evaluate(allocator: std.mem.Allocator, rules: *const AccessRules, command: []const u8, cwd: ?[]const u8) EvalResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Deny pass: generous, first hit wins. Inspects the path-bearing substring
    // of each token, including paths glued into option flags (`--file=/etc/x`,
    // `-f/etc/x`), so deny is not bypassed by flag syntax.
    var tokens = std.mem.tokenizeAny(u8, command, " \t\r\n|&;<>()");
    while (tokens.next()) |tok| {
        const cand = pathCandidate(tok);
        if (cand.len == 0) continue;
        const base = std.fs.path.basename(cand);
        for (rules.deny_names) |pat| {
            if (globMatch(pat, base)) return .{ .decision = .blacklisted, .matched = tok };
        }
        if (looksLikePath(cand)) {
            const resolved = (resolveToken(a, cand, rules.home, cwd) catch null) orelse continue;
            for (rules.deny_roots) |root| {
                if (matchesRoot(resolved, root)) return .{ .decision = .blacklisted, .matched = tok };
            }
        }
    }

    // Allow pass: strict. Read-only, >=1 path token, and EVERY path token
    // confined to an allow root. A single out-of-root path — including one
    // embedded in an option flag — makes the whole command neutral, so deny
    // continues to beat allow here.
    if (!isReadOnlyCommand(command)) return .{};
    var any_path = false;
    var verb_skipped = false;
    var toks2 = std.mem.tokenizeAny(u8, command, " \t\r\n|&;<>()");
    while (toks2.next()) |tok| {
        const cand = pathCandidate(tok);
        if (cand.len == 0) continue;
        // Skip the command's leading verb (and any env-assignment / `sudo`
        // prefix before it) so e.g. `/usr/bin/cat <file>` isn't rejected on the
        // binary's own path. Only the first verb is skipped; later pipeline
        // verbs are harmlessly re-checked as (confined) path candidates.
        if (!verb_skipped) {
            if (isAssignment(cand) or std.mem.eql(u8, cand, "sudo") or std.mem.eql(u8, cand, "command")) continue;
            verb_skipped = true;
            continue;
        }
        if (!looksLikePath(cand)) {
            if (cand[0] == '-') continue; // pure option flag, no embedded path
            if (cwd == null) continue; // bare name with no cwd to anchor it
        }
        const resolved = (resolveToken(a, cand, rules.home, cwd) catch null) orelse continue;
        any_path = true;
        var confined = false;
        for (rules.allow_roots) |root| {
            if (matchesRoot(resolved, root)) {
                confined = true;
                break;
            }
        }
        if (!confined) return .{};
    }
    if (any_path) return .{ .decision = .whitelisted_safe };
    return .{};
}

pub fn isReadOnlyCommand(command: []const u8) bool {
    if (std.mem.indexOfScalar(u8, command, '>') != null) return false; // output redirect
    if (std.mem.indexOf(u8, command, "$(") != null) return false; // command substitution
    if (std.mem.indexOfScalar(u8, command, '`') != null) return false; // command substitution
    // find(1) action predicates run commands or delete files, turning an
    // otherwise read-only verb destructive. Substring scan over-triggers
    // safely (worst case is one extra approval prompt).
    if (std.mem.indexOf(u8, command, "-exec") != null) return false;
    if (std.mem.indexOf(u8, command, "-delete") != null) return false;
    var segs = std.mem.tokenizeAny(u8, command, ";|&");
    var any = false;
    while (segs.next()) |seg| {
        const verb = firstVerb(seg) orelse return false;
        any = true;
        if (!isReadVerb(verb)) return false;
    }
    return any;
}

fn firstVerb(seg: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, seg, " \t");
    while (words.next()) |w| {
        if (isAssignment(w)) continue;
        if (std.mem.eql(u8, w, "sudo") or std.mem.eql(u8, w, "command") or std.mem.eql(u8, w, "\\")) continue;
        if (w[0] == '(' or w[0] == '{') {
            if (w.len == 1) continue;
            return std.fs.path.basename(w[1..]);
        }
        return std.fs.path.basename(w);
    }
    return null;
}

fn isAssignment(w: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, w, '=') orelse return false;
    const slash = std.mem.indexOfScalar(u8, w, '/') orelse w.len;
    return eq > 0 and eq < slash;
}

fn isReadVerb(verb: []const u8) bool {
    for (READ_ONLY_VERBS) |v| {
        if (std.mem.eql(u8, v, verb)) return true;
    }
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

/// The path-bearing substring of a shell token: the token itself, the value
/// after `=` in an option flag (`--file=/etc/x`), or the path glued onto a
/// short flag (`-f/etc/x`). Returned slice is a sub-slice of `tok` (after
/// stripping surrounding quotes), so callers may still report it via `matched`.
fn pathCandidate(tok: []const u8) []const u8 {
    var t = stripQuotes(tok);
    if (t.len != 0 and t[0] == '-') {
        if (std.mem.indexOfScalar(u8, t, '=')) |eq| {
            t = t[eq + 1 ..];
        } else if (std.mem.indexOfScalar(u8, t, '/')) |slash| {
            t = t[slash..];
        }
    }
    return t;
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
    // deny_roots is populated by BUILTIN_DENY defaults (path-shaped entries)
    try std.testing.expect(rules.deny_roots.len > 0);
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

test "parseRules loads built-in deny defaults" {
    var rules = try parseRules(std.testing.allocator, "", "/home/u");
    defer rules.deinit();
    var found_ssh = false;
    for (rules.deny_roots) |r| {
        if (std.mem.eql(u8, r, "/home/u/.ssh")) found_ssh = true;
    }
    try std.testing.expect(found_ssh);
    var found_pem = false;
    for (rules.deny_names) |n| {
        if (std.mem.eql(u8, n, "*.pem")) found_pem = true;
    }
    try std.testing.expect(found_pem);
}

test "parseRules reads allow/deny lines and ignores comments" {
    const contents =
        \\# private rules
        \\allow ~/project
        \\deny  ~/secrets
        \\deny  *.key
        \\garbage line
        \\
    ;
    var rules = try parseRules(std.testing.allocator, contents, "/home/u");
    defer rules.deinit();
    var found_allow = false;
    for (rules.allow_roots) |r| {
        if (std.mem.eql(u8, r, "/home/u/project")) found_allow = true;
    }
    try std.testing.expect(found_allow);
    var found_secrets = false;
    for (rules.deny_roots) |r| {
        if (std.mem.eql(u8, r, "/home/u/secrets")) found_secrets = true;
    }
    try std.testing.expect(found_secrets);
    var found_key = false;
    for (rules.deny_names) |n| {
        if (std.mem.eql(u8, n, "*.key")) found_key = true;
    }
    try std.testing.expect(found_key);
}

test "parseRules ignores a bare allow with no path" {
    var rules = try parseRules(std.testing.allocator, "allow\nallow   \n", "/home/u");
    defer rules.deinit();
    try std.testing.expectEqual(@as(usize, 0), rules.allow_roots.len);
}

test "isReadOnlyCommand accepts read verbs and pipelines" {
    try std.testing.expect(isReadOnlyCommand("cat foo.txt"));
    try std.testing.expect(isReadOnlyCommand("cat a | grep b"));
    try std.testing.expect(isReadOnlyCommand("FOO=1 ls -la"));
    try std.testing.expect(isReadOnlyCommand("/bin/cat foo"));
    try std.testing.expect(isReadOnlyCommand("grep x a && head b"));
}

test "isReadOnlyCommand rejects writes and unknown verbs" {
    try std.testing.expect(!isReadOnlyCommand("rm foo"));
    try std.testing.expect(!isReadOnlyCommand("cat foo > bar"));
    try std.testing.expect(!isReadOnlyCommand("cat a | tee b"));
    try std.testing.expect(!isReadOnlyCommand("echo `cat secret`"));
    try std.testing.expect(!isReadOnlyCommand("cat $(find / -name id_rsa)"));
    try std.testing.expect(!isReadOnlyCommand(""));
}

test "isReadOnlyCommand rejects find with side-effecting predicates" {
    try std.testing.expect(!isReadOnlyCommand("find / -exec rm {} +"));
    try std.testing.expect(!isReadOnlyCommand("find . -exec cp {} /dst \\;"));
    try std.testing.expect(!isReadOnlyCommand("find . -delete"));
    try std.testing.expect(isReadOnlyCommand("find . -name '*.zig'"));
}

test "evaluate flags reads of denied paths (generous)" {
    const a = std.testing.allocator;
    var rules = try parseRules(a, "", "/home/u");
    defer rules.deinit();
    try std.testing.expectEqual(Decision.blacklisted, evaluate(a, &rules, "cat ~/.ssh/id_rsa", null).decision);
    try std.testing.expectEqual(Decision.blacklisted, evaluate(a, &rules, "cat \"$HOME/.ssh/config\"", null).decision);
    try std.testing.expectEqual(Decision.blacklisted, evaluate(a, &rules, "cat /home/u/.ssh/id_rsa", null).decision);
    try std.testing.expectEqual(Decision.blacklisted, evaluate(a, &rules, "cat ../.ssh/id_rsa", "/home/u/project").decision);
    try std.testing.expectEqual(Decision.blacklisted, evaluate(a, &rules, "cat server.pem", "/work").decision);
    try std.testing.expectEqual(Decision.blacklisted, evaluate(a, &rules, "cat < .env", "/work").decision);
}

test "evaluate leaves unrelated reads neutral" {
    const a = std.testing.allocator;
    var rules = try parseRules(a, "", "/home/u");
    defer rules.deinit();
    try std.testing.expectEqual(Decision.neutral, evaluate(a, &rules, "cat /work/readme.txt", null).decision);
    try std.testing.expectEqual(Decision.neutral, evaluate(a, &rules, "ls -la", null).decision);
}

test "evaluate matched names the triggering token" {
    const a = std.testing.allocator;
    var rules = try parseRules(a, "", "/home/u");
    defer rules.deinit();
    const r = evaluate(a, &rules, "cat ~/.ssh/id_rsa", null);
    try std.testing.expectEqualStrings("~/.ssh/id_rsa", r.matched);
}

test "evaluate auto-approves read-only commands confined to allow roots" {
    const a = std.testing.allocator;
    var rules = try parseRules(a, "allow ~/project\n", "/home/u");
    defer rules.deinit();
    try std.testing.expectEqual(Decision.whitelisted_safe, evaluate(a, &rules, "cat ~/project/readme.md", null).decision);
    try std.testing.expectEqual(Decision.whitelisted_safe, evaluate(a, &rules, "cat a.txt", "/home/u/project").decision);
    // A path outside the allow root → not safe.
    try std.testing.expectEqual(Decision.neutral, evaluate(a, &rules, "cat ~/project/a /etc/hosts", null).decision);
    // Not read-only → not safe.
    try std.testing.expectEqual(Decision.neutral, evaluate(a, &rules, "rm ~/project/a", null).decision);
    // No path argument → not safe (avoid blanket auto-approve).
    try std.testing.expectEqual(Decision.neutral, evaluate(a, &rules, "ls", "/home/u/project").decision);
}

test "evaluate: deny beats allow even when nested" {
    const a = std.testing.allocator;
    var rules = try parseRules(a, "allow ~/project\ndeny ~/project/.git\n", "/home/u");
    defer rules.deinit();
    try std.testing.expectEqual(Decision.blacklisted, evaluate(a, &rules, "cat ~/project/.git/config", null).decision);
}

test "evaluate handles paths embedded in option flags" {
    const a = std.testing.allocator;
    var rules = try parseRules(a, "allow ~/project\n", "/home/u");
    defer rules.deinit();
    // Deny still fires for a protected path glued into a flag value.
    try std.testing.expectEqual(Decision.blacklisted, evaluate(a, &rules, "grep --file=$HOME/.ssh/known_hosts x ~/project/a", null).decision);
    // An out-of-root flag path must NOT be auto-approved (no silent skip).
    try std.testing.expectEqual(Decision.neutral, evaluate(a, &rules, "grep --file=/etc/passwd x ~/project/a", null).decision);
    try std.testing.expectEqual(Decision.neutral, evaluate(a, &rules, "grep -f/etc/passwd ~/project/a", null).decision);
    // A flag path inside the allow root stays safe.
    try std.testing.expectEqual(Decision.whitelisted_safe, evaluate(a, &rules, "grep --file=~/project/patterns ~/project/a", null).decision);
}

test "loadRules reads a private file and merges built-ins" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "agent-access.local", .data = "allow ~/project\ndeny ~/private\n" });
    const path = try tmp.dir.realpathAlloc(a, "agent-access.local");
    defer a.free(path);

    var rules = try loadRules(a, path, "/home/u");
    defer rules.deinit();

    var found_allow = false;
    for (rules.allow_roots) |r| if (std.mem.eql(u8, r, "/home/u/project")) {
        found_allow = true;
    };
    try std.testing.expect(found_allow);
    var found_private = false;
    var found_builtin = false;
    for (rules.deny_roots) |r| {
        if (std.mem.eql(u8, r, "/home/u/private")) found_private = true;
        if (std.mem.eql(u8, r, "/home/u/.ssh")) found_builtin = true;
    }
    try std.testing.expect(found_private);
    try std.testing.expect(found_builtin);
}

test "loadRules with a missing file falls back to built-ins" {
    const a = std.testing.allocator;
    var rules = try loadRules(a, "/nonexistent/path/agent-access.local", "/home/u");
    defer rules.deinit();
    var found_builtin = false;
    for (rules.deny_roots) |r| if (std.mem.eql(u8, r, "/home/u/.ssh")) {
        found_builtin = true;
    };
    try std.testing.expect(found_builtin);
}

test "loadRules with an unreadable path still keeps built-in deny defaults" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A directory where a file is expected → readFileAlloc errors; must not
    // disable the built-in deny protection.
    try tmp.dir.makeDir("agent-access.local");
    const path = try tmp.dir.realpathAlloc(a, "agent-access.local");
    defer a.free(path);
    var rules = try loadRules(a, path, "/home/u");
    defer rules.deinit();
    var found_builtin = false;
    for (rules.deny_roots) |r| if (std.mem.eql(u8, r, "/home/u/.ssh")) {
        found_builtin = true;
    };
    try std.testing.expect(found_builtin);
}
