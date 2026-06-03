# Agent File-Access Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a private, machine-local allow/deny file-access guard so WispTerm's AI agent forces per-command approval before reading protected paths (even in full-permission mode) and auto-approves safe reads confined to trusted folders.

**Architecture:** A new pure, Session-free leaf module `src/ai_agent_access.zig` parses a private rules file and lexically classifies each exec command's path references into `neutral | blacklisted | whitelisted_safe`. The verdict is folded into the existing approval gate (`isDangerousCommand` → `ctx.requestApproval`) in all three exec tools (`localCommandExecTool`, `unixSessionExecTool`, `terminalReplExecTool`) via one shared `accessGate` helper. Rules are loaded once at startup and reach the tool layer as a `?*const AccessRules` pointer stamped into `AgentSettings`.

**Tech Stack:** Zig (0.15 idioms: `std.ArrayListUnmanaged(T) = .empty`, `std.heap.ArenaAllocator`, `std.mem.tokenizeAny`). Tests: `zig build test` (fast native suite) for the pure module; `zig build test-full` for the tool-layer wiring.

**Spec:** `docs/superpowers/specs/2026-06-03-agent-file-access-guard-design.md`

---

## Precedence (the rule every task serves)

`deny > allow > base permission mode`. For each exec command:

| Condition | Result |
|---|---|
| References a **deny** path/name | `blacklisted` → force approval even in `full` mode |
| Else read-only command, ≥1 path token, **all** under an **allow** root, no deny hit | `whitelisted_safe` → auto-approve even in `confirm` mode |
| Else | `neutral` → existing behavior |

Deny matching is **generous** (over-trigger = safe). Allow auto-approve is **strict** (any uncertainty → not safe).

---

## Fixed public interface (defined in Task 1, used everywhere — do not rename)

```zig
pub const Decision = enum { neutral, blacklisted, whitelisted_safe };
pub const EvalResult = struct { decision: Decision = .neutral, matched: []const u8 = "" };
pub const AccessRules = struct {
    arena: std.heap.ArenaAllocator,
    home: []const u8,
    allow_roots: [][]const u8,
    deny_roots: [][]const u8,
    deny_names: [][]const u8,
    pub fn deinit(self: *AccessRules) void { self.arena.deinit(); }
};
pub fn parseRules(allocator: std.mem.Allocator, contents: []const u8, home: []const u8) !AccessRules;
pub fn loadRules(allocator: std.mem.Allocator, file_path: []const u8, home: []const u8) !AccessRules;
pub fn evaluate(allocator: std.mem.Allocator, rules: *const AccessRules, command: []const u8, cwd: ?[]const u8) EvalResult;
pub fn isReadOnlyCommand(command: []const u8) bool;
```

---

### Task 1: Scaffold the module + register it in both test suites

**Files:**
- Create: `src/ai_agent_access.zig`
- Modify: `src/test_fast.zig` (after line 39 `_ = @import("ai_agent_config.zig");`)
- Modify: `src/test_main.zig` (near the other `ai_*` imports, e.g. after line 608 `_ = @import("ai_chat_types.zig");`)

- [ ] **Step 1: Create the module with the fixed interface + safe stubs**

```zig
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
    return .{
        .arena = arena,
        .home = try a.dupe(u8, home),
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

test "module scaffold compiles and parseRules yields a valid struct" {
    var rules = try parseRules(std.testing.allocator, "", "/home/u");
    defer rules.deinit();
    try std.testing.expectEqualStrings("/home/u", rules.home);
    try std.testing.expectEqual(@as(usize, 0), rules.deny_roots.len);
}
```

- [ ] **Step 2: Register in the fast suite**

In `src/test_fast.zig`, immediately after the line `_ = @import("ai_agent_config.zig");` add:

```zig
    _ = @import("ai_agent_access.zig");
```

- [ ] **Step 3: Register in the full suite**

In `src/test_main.zig`, immediately after the line `_ = @import("ai_chat_types.zig");` add:

```zig
    _ = @import("ai_agent_access.zig");
```

- [ ] **Step 4: Run the fast suite**

Run: `zig build test`
Expected: build succeeds, no test failures (the scaffold test passes).

- [ ] **Step 5: Commit**

```bash
git add src/ai_agent_access.zig src/test_fast.zig src/test_main.zig
git commit -m "feat(agent-access): scaffold file-access guard module"
```

---

### Task 2: Glob matcher (`globMatch`)

**Files:**
- Modify: `src/ai_agent_access.zig`

- [ ] **Step 1: Write the failing test** (append to the test section)

```zig
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `globMatch` is not defined.

- [ ] **Step 3: Implement `globMatch`** (add above the test section)

```zig
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_agent_access.zig
git commit -m "feat(agent-access): add glob matcher"
```

---

### Task 3: Path helpers (`expandHome`, `lexicalNormalize`, `resolveToken`, `matchesRoot`, `looksLikePath`)

**Files:**
- Modify: `src/ai_agent_access.zig`

- [ ] **Step 1: Write the failing tests**

```zig
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL — helper functions not defined.

- [ ] **Step 3: Implement the helpers** (add above the test section)

```zig
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_agent_access.zig
git commit -m "feat(agent-access): add path normalization helpers"
```

---

### Task 4: Real `parseRules` (built-ins + private-file lines)

**Files:**
- Modify: `src/ai_agent_access.zig`

- [ ] **Step 1: Write the failing tests**

```zig
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL — current `parseRules` returns empty lists.

- [ ] **Step 3: Replace `parseRules` and add its helpers**

Replace the entire `parseRules` stub with:

```zig
pub fn parseRules(allocator: std.mem.Allocator, contents: []const u8, home: []const u8) !AccessRules {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var allow: List = .empty;
    var deny: List = .empty;
    var names: List = .empty;

    const home_copy = try a.dupe(u8, home);

    for (BUILTIN_DENY) |entry| {
        try addDenyEntry(a, &deny, &names, entry, home_copy);
    }

    var lines = std.mem.tokenizeAny(u8, contents, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (parseKeyword(line, "allow")) |rest| {
            const norm = try normalizeEntry(a, rest, home_copy);
            if (norm.len != 0) try allow.append(a, norm);
        } else if (parseKeyword(line, "deny")) |rest| {
            try addDenyEntry(a, &deny, &names, rest, home_copy);
        } else {
            std.log.warn("agent-access: ignoring malformed rule line: {s}", .{line});
        }
    }

    return .{
        .arena = arena,
        .home = home_copy,
        .allow_roots = try allow.toOwnedSlice(a),
        .deny_roots = try deny.toOwnedSlice(a),
        .deny_names = try names.toOwnedSlice(a),
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_agent_access.zig
git commit -m "feat(agent-access): parse built-in and private allow/deny rules"
```

---

### Task 5: Real `isReadOnlyCommand`

**Files:**
- Modify: `src/ai_agent_access.zig`

- [ ] **Step 1: Write the failing tests**

```zig
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL — current `isReadOnlyCommand` always returns false.

- [ ] **Step 3: Replace the stub and add helpers**

Replace the `isReadOnlyCommand` stub with:

```zig
pub fn isReadOnlyCommand(command: []const u8) bool {
    if (std.mem.indexOfScalar(u8, command, '>') != null) return false; // output redirect
    if (std.mem.indexOf(u8, command, "$(") != null) return false; // command substitution
    if (std.mem.indexOfScalar(u8, command, '`') != null) return false; // command substitution
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_agent_access.zig
git commit -m "feat(agent-access): classify read-only commands"
```

---

### Task 6: `evaluate` — deny pass

**Files:**
- Modify: `src/ai_agent_access.zig`

- [ ] **Step 1: Write the failing tests**

```zig
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL — current `evaluate` returns neutral.

- [ ] **Step 3: Replace `evaluate` with the deny pass**

```zig
pub fn evaluate(allocator: std.mem.Allocator, rules: *const AccessRules, command: []const u8, cwd: ?[]const u8) EvalResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Deny pass: generous, first hit wins.
    var tokens = std.mem.tokenizeAny(u8, command, " \t\r\n|&;<>()");
    while (tokens.next()) |tok| {
        const t = stripQuotes(tok);
        if (t.len == 0) continue;
        const base = std.fs.path.basename(t);
        for (rules.deny_names) |pat| {
            if (globMatch(pat, base)) return .{ .decision = .blacklisted, .matched = tok };
        }
        if (looksLikePath(tok)) {
            const resolved = (resolveToken(a, tok, rules.home, cwd) catch null) orelse continue;
            for (rules.deny_roots) |root| {
                if (matchesRoot(resolved, root)) return .{ .decision = .blacklisted, .matched = tok };
            }
        }
    }
    return .{};
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_agent_access.zig
git commit -m "feat(agent-access): evaluate deny list against commands"
```

---

### Task 7: `evaluate` — allow (whitelist) pass

**Files:**
- Modify: `src/ai_agent_access.zig`

- [ ] **Step 1: Write the failing tests**

```zig
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `evaluate` never returns `whitelisted_safe`.

- [ ] **Step 3: Extend `evaluate` with the allow pass**

In `evaluate`, replace the final `return .{};` with:

```zig
    // Allow pass: strict. Read-only, ≥1 path token, every path token confined.
    if (!isReadOnlyCommand(command)) return .{};
    var any_path = false;
    var toks2 = std.mem.tokenizeAny(u8, command, " \t\r\n|&;<>()");
    while (toks2.next()) |tok| {
        if (!looksLikePath(tok)) continue;
        const resolved = (resolveToken(a, tok, rules.home, cwd) catch null) orelse continue;
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS (including the deny-beats-allow test, since the deny pass returns before the allow pass runs).

- [ ] **Step 5: Commit**

```bash
git add src/ai_agent_access.zig
git commit -m "feat(agent-access): auto-approve reads confined to allow roots"
```

---

### Task 8: Real `loadRules` (read the private file, merge with built-ins)

**Files:**
- Modify: `src/ai_agent_access.zig`

- [ ] **Step 1: Write the failing tests**

```zig
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL — current `loadRules` ignores the file (always parses `""`), so the allow/deny-from-file assertions fail.

- [ ] **Step 3: Replace the `loadRules` stub**

```zig
pub fn loadRules(allocator: std.mem.Allocator, file_path: []const u8, home: []const u8) !AccessRules {
    const contents = std.fs.cwd().readFileAlloc(allocator, file_path, MAX_RULES_BYTES) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return parseRules(allocator, "", home),
        else => return err,
    };
    defer allocator.free(contents);
    return parseRules(allocator, contents, home);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_agent_access.zig
git commit -m "feat(agent-access): load rules from the private file"
```

---

### Task 9: Wire `AccessRules` into settings and load at startup

**Files:**
- Modify: `src/ai_chat_types.zig` (add import + `access_rules` field on `AgentSettings`)
- Modify: `src/ai_chat.zig` (rules global, setter, loader, stamp into `currentAgentSettings`)
- Modify: `src/main.zig` (call the loader once at startup)

- [ ] **Step 1: Add the `access_rules` field to `AgentSettings`**

In `src/ai_chat_types.zig`, after the existing imports (around line 6, after `const agent_detector = @import("agent_detector.zig");`) add:

```zig
const ai_agent_access = @import("ai_agent_access.zig");
```

Then change the `AgentSettings` struct (lines 11-16) to:

```zig
pub const AgentSettings = struct {
    enabled: bool = false,
    permission: AgentPermission = .confirm,
    command_timeout_ms: u32 = DEFAULT_AGENT_TIMEOUT_MS,
    output_limit: u32 = DEFAULT_AGENT_OUTPUT_LIMIT,
    /// Private file-access rules (owned by the app layer; null = guard inactive).
    access_rules: ?*const ai_agent_access.AccessRules = null,
};
```

- [ ] **Step 2: Add the rules global, setter, loader, and stamping in `ai_chat.zig`**

In `src/ai_chat.zig`, ensure these imports exist near the top (add any that are missing — check with `grep -n 'ai_agent_access\|platform/dirs' src/ai_chat.zig`):

```zig
const ai_agent_access = @import("ai_agent_access.zig");
const platform_dirs = @import("platform/dirs.zig");
```

After the line `var g_agent_settings: AgentSettings = .{};` (line 236) add:

```zig
var g_access_rules_storage: ?ai_agent_access.AccessRules = null;
var g_access_rules: ?*const ai_agent_access.AccessRules = null;

/// Load the private agent-access rules once at startup. Safe to call repeatedly
/// (loads only the first time). Never fails the app: on any error the guard
/// simply stays inactive (built-ins still apply once rules load successfully).
pub fn loadAccessRules(allocator: std.mem.Allocator) void {
    g_agent_mutex.lock();
    const already = g_access_rules_storage != null;
    g_agent_mutex.unlock();
    if (already) return;

    const home = resolveHomeDir(allocator) orelse "";
    defer if (home.len != 0) allocator.free(home);
    const path = platform_dirs.pathInConfigDir(allocator, "agent-access.local") catch return;
    defer allocator.free(path);
    const rules = ai_agent_access.loadRules(allocator, path, home) catch return;

    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    g_access_rules_storage = rules;
    g_access_rules = &g_access_rules_storage.?;
}

fn resolveHomeDir(allocator: std.mem.Allocator) ?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "HOME")) |v| {
        return v;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |v| {
        return v;
    } else |_| {}
    return null;
}
```

Then change `currentAgentSettings` (lines 272-275) to stamp the rules pointer:

```zig
pub fn currentAgentSettings() AgentSettings {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    var s = g_agent_settings;
    s.access_rules = g_access_rules;
    return s;
}
```

- [ ] **Step 3: Call the loader at startup**

In `src/main.zig`, confirm `ai_chat` is imported (add `const ai_chat = @import("ai_chat.zig");` near the other imports if `grep -n 'ai_chat' src/main.zig` finds none). Then, immediately after `var app = try App.init(allocator, cfg);` (line 171) add:

```zig
    ai_chat.loadAccessRules(allocator);
```

- [ ] **Step 4: Build the app and run the full suite**

Run: `zig build test-full`
Expected: build succeeds, no test failures (existing `AgentSettings`-related tests still pass; the new field has a default).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_types.zig src/ai_chat.zig src/main.zig
git commit -m "feat(agent-access): wire access rules into agent settings + startup load"
```

---

### Task 10: Enforce the guard in the three exec gates

**Files:**
- Modify: `src/ai_chat_tools.zig` (import, `accessGate` helper, refactor `localCommandExecTool`, `unixSessionExecTool`, `terminalReplExecTool`, add tests)

- [ ] **Step 1: Write the failing tests** (append to the existing test section near the bottom of the file)

```zig
test "accessGate forces approval for denied paths and skips safe allowed reads" {
    const a = std.testing.allocator;
    var rules = try ai_agent_access.parseRules(a, "allow /work/ok\n", "/home/u");
    defer rules.deinit();

    var session_dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &session_dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = &rules },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    // Denied path → force approval even in full mode.
    const denied = accessGate(&ctx, "cat ~/.ssh/id_rsa", null);
    try std.testing.expect(denied.force);
    try std.testing.expect(denied.blacklisted);

    // Safe read confined to an allow root → skip even in confirm mode.
    ctx.settings.permission = .confirm;
    const safe = accessGate(&ctx, "cat /work/ok/readme.md", null);
    try std.testing.expect(safe.skip);
    try std.testing.expect(!safe.force);

    // Unrelated read → neutral (no force, no skip).
    const neutral = accessGate(&ctx, "cat /work/other.txt", null);
    try std.testing.expect(!neutral.force);
    try std.testing.expect(!neutral.skip);
}

test "accessGate with no rules degrades to dangerous-only behavior" {
    const a = std.testing.allocator;
    var session_dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &session_dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    try std.testing.expect(!accessGate(&ctx, "cat foo.txt", null).force);
    try std.testing.expect(accessGate(&ctx, "rm foo.txt", null).force); // dangerous still forces
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-full`
Expected: FAIL — `accessGate` and `ai_agent_access` are not yet referenced in this file.

- [ ] **Step 3: Add the import and the `accessGate` helper**

In `src/ai_chat_tools.zig`, add near the top imports:

```zig
const ai_agent_access = @import("ai_agent_access.zig");
```

Add this helper just above `localCommandExecTool` (around line 405):

```zig
const AccessGate = struct {
    dangerous: bool,
    blacklisted: bool,
    force: bool,
    skip: bool,
    matched: []const u8,
};

/// Combine the destructive-command check with the private file-access guard.
/// `force` => must prompt even in full mode; `skip` => may run without a prompt
/// even in confirm mode.
fn accessGate(ctx: *const ToolContext, command: []const u8, cwd: ?[]const u8) AccessGate {
    const dangerous = isDangerousCommand(command);
    const result = if (ctx.settings.access_rules) |rules|
        ai_agent_access.evaluate(ctx.allocator, rules, command, cwd)
    else
        ai_agent_access.EvalResult{};
    const blacklisted = result.decision == .blacklisted;
    return .{
        .dangerous = dangerous,
        .blacklisted = blacklisted,
        .force = dangerous or blacklisted,
        .skip = result.decision == .whitelisted_safe and !dangerous,
        .matched = result.matched,
    };
}

/// Allocate a human-readable approval reason naming the protected path. Returns
/// null on OOM (callers fall back to a static reason).
fn allocBlacklistReason(allocator: std.mem.Allocator, matched: []const u8) ?[]u8 {
    return std.fmt.allocPrint(allocator, "Reads protected path \"{s}\" — confirm to allow", .{matched}) catch null;
}
```

- [ ] **Step 4: Refactor `localCommandExecTool`**

Replace the gate block (current lines 408-414):

```zig
    const dangerous = isDangerousCommand(command);
    if (ctx.settings.permission != .full or dangerous) {
        const reason = if (dangerous) DANGEROUS_COMMAND_APPROVAL_REASON else platform_process.localCommandApprovalLabel();
        if (!ctx.requestApproval(platform_process.localCommandToolName(), command, reason)) {
            return deniedResult(ctx.allocator, command, platform_process.localCommandDeniedReason());
        }
    }
```

with:

```zig
    const gate = accessGate(ctx, command, cwd);
    if (gate.force or (ctx.settings.permission != .full and !gate.skip)) {
        const bl_reason = if (gate.blacklisted) allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous) DANGEROUS_COMMAND_APPROVAL_REASON else platform_process.localCommandApprovalLabel();
        if (!ctx.requestApproval(platform_process.localCommandToolName(), command, reason)) {
            return deniedResult(ctx.allocator, command, platform_process.localCommandDeniedReason());
        }
    }
```

- [ ] **Step 5: Refactor `unixSessionExecTool`**

Replace its gate block (current lines 1063-1073):

```zig
    const dangerous = isDangerousCommand(command);
    if (ctx.settings.permission != .full or dangerous) {
        var reason_buf: [64]u8 = undefined;
        const reason = if (dangerous)
            DANGEROUS_COMMAND_APPROVAL_REASON
        else
            std.fmt.bufPrint(&reason_buf, "Type command into opened {s} terminal", .{kind.label()}) catch "Type command into terminal";
        if (!ctx.requestApproval(kind.toolName(), command, reason)) {
            return deniedResult(ctx.allocator, command, if (kind == .ssh) "operator rejected SSH PTY command" else "operator rejected WSL PTY command");
        }
    }
```

with:

```zig
    const gate = accessGate(ctx, command, null);
    if (gate.force or (ctx.settings.permission != .full and !gate.skip)) {
        var reason_buf: [64]u8 = undefined;
        const bl_reason = if (gate.blacklisted) allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous)
            DANGEROUS_COMMAND_APPROVAL_REASON
        else
            std.fmt.bufPrint(&reason_buf, "Type command into opened {s} terminal", .{kind.label()}) catch "Type command into terminal";
        if (!ctx.requestApproval(kind.toolName(), command, reason)) {
            return deniedResult(ctx.allocator, command, if (kind == .ssh) "operator rejected SSH PTY command" else "operator rejected WSL PTY command");
        }
    }
```

- [ ] **Step 6: Refactor `terminalReplExecTool`**

Replace its gate block (current lines 769-781):

```zig
    const dangerous = isDangerousCommand(code);
    if (ctx.settings.permission != .full or dangerous) {
        var reason_buf: [96]u8 = undefined;
        const reason = if (dangerous)
            DANGEROUS_COMMAND_APPROVAL_REASON
        else if (control != null)
            std.fmt.bufPrint(&reason_buf, "Send control key {s} to terminal", .{std.mem.trim(u8, code, " \t\r\n")}) catch "Send control key to terminal"
        else
            std.fmt.bufPrint(&reason_buf, "Type input into opened {s} REPL/app terminal", .{repl.label()}) catch "Type input into terminal";
        if (!ctx.requestApproval("terminal_repl_exec", code, reason)) {
            return deniedResult(ctx.allocator, code, "operator rejected REPL terminal input");
        }
    }
```

with:

```zig
    const gate = accessGate(ctx, code, null);
    if (gate.force or (ctx.settings.permission != .full and !gate.skip)) {
        var reason_buf: [96]u8 = undefined;
        const bl_reason = if (gate.blacklisted) allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous)
            DANGEROUS_COMMAND_APPROVAL_REASON
        else if (control != null)
            std.fmt.bufPrint(&reason_buf, "Send control key {s} to terminal", .{std.mem.trim(u8, code, " \t\r\n")}) catch "Send control key to terminal"
        else
            std.fmt.bufPrint(&reason_buf, "Type input into opened {s} REPL/app terminal", .{repl.label()}) catch "Type input into terminal";
        if (!ctx.requestApproval("terminal_repl_exec", code, reason)) {
            return deniedResult(ctx.allocator, code, "operator rejected REPL terminal input");
        }
    }
```

- [ ] **Step 7: Run the full suite to verify it passes**

Run: `zig build test-full`
Expected: PASS (new `accessGate` tests pass; existing dangerous-command tests still pass).

- [ ] **Step 8: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(agent-access): enforce file-access guard in all exec gates"
```

---

### Task 11: Final verification + ship the example rules file

**Files:**
- Create: `docs/agent-access.local.example` (a copy-paste starting point for users)

- [ ] **Step 1: Write the example file**

```
# WispTerm agent file-access rules (private, machine-local).
# Copy to ~/.config/wispterm/agent-access.local and edit.
#
#   allow <path>   folders the agent may read freely (read-only commands skip the prompt)
#   deny  <path>   paths/files the agent must never read without your per-command approval
#
# '~' and $HOME expand. An entry without '/' is a basename glob (e.g. *.pem, .env).
# Built-in deny defaults are ALWAYS on (~/.ssh, ~/.aws, ~/.gnupg, ~/.config/gh,
# ~/.config/wispterm, ~/.kube, ~/.netrc, ~/.docker/config.json, *.pem, *.key, .env);
# the lines below extend them. deny always wins over allow.

# allow ~/project
# allow ~/work

# deny ~/Documents/finance
# deny *.kdbx
```

- [ ] **Step 2: Run both test suites**

Run: `zig build test && zig build test-full`
Expected: both succeed with no failures.

- [ ] **Step 3: Confirm the app builds**

Run: `zig build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add docs/agent-access.local.example
git commit -m "docs(agent-access): add example private rules file"
```

---

## Self-Review

**Spec coverage:**
- New leaf module `ai_agent_access.zig` (pure, fast-suite) → Tasks 1-8. ✓
- Private file `~/.config/wispterm/agent-access.local`, `allow`/`deny`, `~`/`$HOME`, dir-prefix vs basename/glob, comments, absent-file → built-ins → Tasks 4, 8, 9 (path via `platform_dirs.pathInConfigDir`). ✓
- Built-in secure-by-default deny list, always on → `BUILTIN_DENY` (Task 1) merged in `parseRules` (Task 4). ✓
- Precedence deny > allow > base mode; deny forces approval even in full; allow auto-approves read-only confined reads even in confirm → `evaluate` (Tasks 6-7) + `accessGate` (Task 10). ✓
- Generous deny matching / strict allow matching → Tasks 6, 7. ✓
- All three exec paths gated via one shared helper → Task 10. ✓
- Rules loaded once, owned by app layer, threaded via `AgentSettings`/`ToolContext` → Task 9. ✓
- Tests: pure parser/matcher in fast suite (Tasks 2-7), loader (Task 8), gate wiring (Task 10). ✓
- Error handling: missing file → built-ins; malformed line → warn+skip; load failure → guard inactive → Tasks 4, 8, 9. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `Decision`, `EvalResult{ decision, matched }`, `AccessRules{ arena, home, allow_roots, deny_roots, deny_names }`, and the signatures of `parseRules`/`loadRules`/`evaluate`/`isReadOnlyCommand` are fixed in Task 1 and used unchanged thereafter. `accessGate`/`AccessGate{ dangerous, blacklisted, force, skip, matched }` introduced and consumed only in Task 10. ✓

## Known limitations (documented, accepted in the spec)

- Heuristic command-string gate, not an OS sandbox: deliberate obfuscation (runtime-constructed paths, base64 decode-then-read) can evade the deny scan.
- For SSH/WSL/REPL the matcher runs with `cwd = null`, so cwd-relative *remote* paths won't prefix-match deny roots; `~`/`$HOME`/absolute/basename-glob matches still fire. Whitelist auto-approve therefore rarely triggers on remote (safe default: more prompts, never fewer).
```
