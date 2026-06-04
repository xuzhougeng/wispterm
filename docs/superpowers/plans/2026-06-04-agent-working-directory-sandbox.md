# Conversation Working Directory + Sandbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind a working directory to the AI conversation (persistent global default + per-conversation override), use it as the default cwd for local command execution, and treat it as a lightweight sandbox where confined non-dangerous commands skip the approval prompt.

**Architecture:** A pure confinement predicate (`workdirConfined`) in the Session-free access guard decides whether a command stays inside the working dir. The local exec tool defaults its cwd to the effective working dir and feeds it to the access gate, which adds confinement to its `skip` set (dangerous/deny-listed always still force a prompt). The effective dir = per-`Session` override ?? a global default loaded from a new config key.

**Tech Stack:** Zig. Tests via `zig build test` (fast, native — pure modules: `ai_agent_access`, `ai_chat_composer`, `config`) and `zig build test-full` (full app graph — `ai_chat`, `ai_chat_tools`). Default cross-compile target is `windows-gnu`, so `builtin.os.tag == .windows` holds under `test-full`.

Spec: `docs/superpowers/specs/2026-06-04-agent-working-directory-sandbox-design.md`

---

## File map

- `src/ai_agent_access.zig` — **add** pure `workdirConfined` + helpers (`isAbsoluteConfinePath`, `normForCompare`, `resolveForConfine`). Reuses existing `expandHome`/`stripQuotes`/`lexicalNormalize`/`matchesRoot`/`pathCandidate`/`isAssignment`.
- `src/ai_chat_types.zig` — **add** `working_dir: ?[]const u8 = null` to `AgentSettings`.
- `src/ai_chat_tools.zig` — extend `accessGate` (confinement → `skip`) and `localCommandExecTool` (default cwd to `settings.working_dir`).
- `src/ai_chat.zig` — global default (`g_default_working_dir_*`, `setDefaultWorkingDir`, `defaultWorkingDir`, merge in `currentAgentSettings`); `Session.working_dir_buf/len`, `workingDirOverride`, `effectiveWorkingDirLocked`, `applyCwdArgLocked`; `.cwd` arms in `runBuiltinCommandLocked` and `slashCommandOutput`; `expandTilde`; `WORKING_DIR_MAX_BYTES`.
- `src/ai_chat_composer.zig` — `/cwd` enum value + entry + `parseCwdArg`.
- `src/ai_chat_request.zig` — overlay session override in `toolContextFromRequest`.
- `src/config.zig` — `ai-agent-working-dir` key (decl + apply + template + help).
- `src/App.zig` — mirror field `ai_agent_working_dir` (init/deinit/reapply, following `font_family`).
- `src/AppWindow.zig` — call `ai_chat.setDefaultWorkingDir(...)` at both `configureAgent` sites.
- `src/platform/process.zig` — mention default-to-working-directory in the local command tool description.

---

## Task 1: Pure `workdirConfined` predicate

**Files:**
- Modify: `src/ai_agent_access.zig` (add `const builtin`, the predicate + helpers, and tests)
- Test: same file (fast suite)

- [ ] **Step 1: Write the failing tests**

Append at the end of `src/ai_agent_access.zig` (before EOF):

```zig
test "workdirConfined: confined writes and no-path commands are confined" {
    const a = std.testing.allocator;
    const wd = "/home/u/proj";
    // download into cwd
    try std.testing.expect(workdirConfined(a, "curl http://x -o out.bin", wd, "/home/u/proj", "/home/u"));
    // clone with no local path arg (only writes into cwd)
    try std.testing.expect(workdirConfined(a, "git clone https://example.com/r.git", wd, "/home/u/proj", "/home/u"));
    // subdir create
    try std.testing.expect(workdirConfined(a, "mkdir sub", wd, "/home/u/proj", "/home/u"));
    // absolute binary path as the verb is skipped, not treated as an escape
    try std.testing.expect(workdirConfined(a, "/usr/bin/curl -O http://x", wd, "/home/u/proj", "/home/u"));
}

test "workdirConfined: escaping paths and out-of-root cwd are not confined" {
    const a = std.testing.allocator;
    const wd = "/home/u/proj";
    // absolute path outside the root
    try std.testing.expect(!workdirConfined(a, "cp /etc/passwd .", wd, "/home/u/proj", "/home/u"));
    // .. escape
    try std.testing.expect(!workdirConfined(a, "cat ../secret.txt", wd, "/home/u/proj", "/home/u"));
    // cwd itself outside the root
    try std.testing.expect(!workdirConfined(a, "ls", wd, "/tmp", "/home/u"));
    // empty working dir is never confined
    try std.testing.expect(!workdirConfined(a, "ls", "", "/home/u/proj", "/home/u"));
}

test "workdirConfined: Windows separators and drive letters" {
    const a = std.testing.allocator;
    const wd = "D:\\proj";
    // backslash + same-drive path stays confined (case matches on every target)
    try std.testing.expect(workdirConfined(a, "curl http://x -o sub\\out.bin", wd, "D:\\proj", "/home/u"));
    // a different drive escapes
    try std.testing.expect(!workdirConfined(a, "type C:\\Windows\\system.ini", wd, "D:\\proj", "/home/u"));
}

test "workdirConfined: case-insensitive match on Windows" {
    if (builtin.os.tag != .windows) return;
    const a = std.testing.allocator;
    try std.testing.expect(workdirConfined(a, "type sub\\f.txt", "D:\\Proj", "d:\\proj", "/home/u"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'workdirConfined'` (and `builtin`).

- [ ] **Step 3: Add the `builtin` import**

At the top of `src/ai_agent_access.zig`, directly after `const std = @import("std");` (line 6):

```zig
const builtin = @import("builtin");
```

- [ ] **Step 4: Implement the predicate and helpers**

Add this block to `src/ai_agent_access.zig` immediately after the `isPathDenied` function (it ends at line 228, before `pub fn isReadOnlyCommand`):

```zig
/// True when a command run with `effective_cwd` as its working directory is
/// fully confined to `working_dir`: the cwd is inside the working dir AND no
/// path-bearing argument escapes it. A command with no escaping path token only
/// writes into its cwd, so it counts as confined (this is the download/clone
/// case). The leading verb is skipped so an absolute binary path
/// (`/usr/bin/curl`) is not mistaken for an escape. Platform-aware: handles
/// Windows `\` separators, drive letters, and (on Windows) case-insensitivity.
/// Pure; `allocator` backs only a scratch arena.
pub fn workdirConfined(
    allocator: std.mem.Allocator,
    command: []const u8,
    working_dir: []const u8,
    effective_cwd: []const u8,
    home: []const u8,
) bool {
    if (working_dir.len == 0) return false;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = normForCompare(a, working_dir) catch return false;
    const cwd_norm = (resolveForConfine(a, effective_cwd, home, root) catch null) orelse return false;
    if (!matchesRoot(cwd_norm, root)) return false;

    var verb_skipped = false;
    var tokens = std.mem.tokenizeAny(u8, command, " \t\r\n|&;<>()");
    while (tokens.next()) |tok| {
        const cand = pathCandidate(tok);
        if (cand.len == 0) continue;
        if (!verb_skipped) {
            if (isAssignment(cand) or std.mem.eql(u8, cand, "sudo") or std.mem.eql(u8, cand, "command")) continue;
            verb_skipped = true;
            continue;
        }
        const resolved = (resolveForConfine(a, cand, home, cwd_norm) catch null) orelse continue;
        if (!matchesRoot(resolved, root)) return false;
    }
    return true;
}

fn isAbsoluteConfinePath(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '/' or p[0] == '\\') return true;
    // Windows drive root: X:\ or X:/ (or bare X: which we treat as a root too).
    if (p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':') return true;
    return false;
}

/// Normalize a path for confinement comparison: convert `\` to `/`, collapse
/// `.`/`..` lexically, and lower-case on Windows (case-insensitive filesystem).
fn normForCompare(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const slashed = try a.dupe(u8, raw);
    for (slashed) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    const normalized = try lexicalNormalize(a, slashed);
    if (builtin.os.tag == .windows) {
        for (normalized) |*c| c.* = std.ascii.toLower(c.*);
    }
    return normalized;
}

/// Resolve a token to a normalized comparison path. Absolute (incl. drive-root)
/// tokens normalize as-is; relative tokens join onto `base` (already normalized).
/// Returns null for empty/option-flag tokens.
fn resolveForConfine(a: std.mem.Allocator, token: []const u8, home: []const u8, base: []const u8) !?[]const u8 {
    const t = stripQuotes(token);
    if (t.len == 0 or t[0] == '-') return null;
    const expanded = try expandHome(a, t, home);
    if (isAbsoluteConfinePath(expanded)) return try normForCompare(a, expanded);
    const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, expanded });
    return try normForCompare(a, joined);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS — all four `workdirConfined` tests pass; no regressions.

- [ ] **Step 6: Commit**

```bash
git add src/ai_agent_access.zig
git commit -m "feat(agent): pure workdirConfined predicate for the working-dir sandbox"
```

---

## Task 2: Settings field + access gate + default cwd

**Files:**
- Modify: `src/ai_chat_types.zig:12-19` (add `working_dir` to `AgentSettings`)
- Modify: `src/ai_chat_tools.zig:457-471` (`accessGate`), `:487-508` (`localCommandExecTool`)
- Test: `src/ai_chat_tools.zig` (full suite)

- [ ] **Step 1: Write the failing test**

Append at the end of `src/ai_chat_tools.zig`:

```zig
test "accessGate: working-dir sandbox skips confined non-dangerous, still forces dangerous/deny" {
    const a = std.testing.allocator;
    var rules = try ai_agent_access.parseRules(a, "", "/home/u");
    defer rules.deinit();
    var dummy: u8 = 0;
    const ctx = types.ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .working_dir = "/home/u/proj", .access_rules = &rules },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    // confined write -> auto-approve
    const g1 = accessGate(&ctx, "curl http://x -o out.bin", "/home/u/proj");
    try std.testing.expect(g1.skip);
    try std.testing.expect(!g1.force);
    try std.testing.expect(!approvalRequiredForGate(.confirm, g1)); // confirm now auto-runs inside the dir
    try std.testing.expect(!approvalRequiredForGate(.auto, g1));
    // confined dangerous -> still forced
    const g2 = accessGate(&ctx, "rm -rf build", "/home/u/proj");
    try std.testing.expect(!g2.skip);
    try std.testing.expect(g2.force);
    try std.testing.expect(approvalRequiredForGate(.confirm, g2));
    try std.testing.expect(approvalRequiredForGate(.auto, g2));
    // escaping write -> not confined, normal gating (no skip, no force)
    const g3 = accessGate(&ctx, "cp /etc/hosts .", "/home/u/proj");
    try std.testing.expect(!g3.skip);
    try std.testing.expect(!g3.force);
    // deny-listed read inside cwd -> forced regardless of sandbox
    const g4 = accessGate(&ctx, "cat /home/u/.ssh/id_rsa", "/home/u/proj");
    try std.testing.expect(g4.force);
    try std.testing.expect(!g4.skip);
}

test "accessGate: no working dir leaves behavior unchanged" {
    const a = std.testing.allocator;
    var rules = try ai_agent_access.parseRules(a, "", "/home/u");
    defer rules.deinit();
    var dummy: u8 = 0;
    const ctx = types.ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .access_rules = &rules }, // working_dir = null
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const g = accessGate(&ctx, "curl http://x -o out.bin", null);
    try std.testing.expect(!g.skip);
    try std.testing.expect(!g.force);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `AgentSettings` has no field `working_dir` (struct-init error).

- [ ] **Step 3: Add the settings field**

In `src/ai_chat_types.zig`, inside `AgentSettings` (after the `access_rules` field at line 18), add:

```zig
    /// Effective working directory for the conversation (borrowed; null = unset).
    /// When set, the local command tool defaults its cwd here and commands
    /// confined to it skip the approval prompt (the sandbox).
    working_dir: ?[]const u8 = null,
```

- [ ] **Step 4: Extend `accessGate` with confinement**

Replace the body of `accessGate` in `src/ai_chat_tools.zig` (lines 457-471) with:

```zig
fn accessGate(ctx: *const ToolContext, command: []const u8, cwd: ?[]const u8) AccessGate {
    const dangerous = isDangerousCommand(command);
    const result = if (ctx.settings.access_rules) |rules|
        ai_agent_access.evaluate(ctx.allocator, rules, command, cwd)
    else
        ai_agent_access.EvalResult{};
    const blacklisted = result.decision == .blacklisted;
    const home = if (ctx.settings.access_rules) |rules| rules.home else "";
    const confined = blk: {
        const wd = ctx.settings.working_dir orelse break :blk false;
        const ec = cwd orelse break :blk false;
        break :blk ai_agent_access.workdirConfined(ctx.allocator, command, wd, ec, home);
    };
    return .{
        .dangerous = dangerous,
        .blacklisted = blacklisted,
        .force = dangerous or blacklisted,
        .skip = (result.decision == .whitelisted_safe or confined) and !dangerous and !blacklisted,
        .matched = result.matched,
    };
}
```

- [ ] **Step 5: Default the exec cwd to the working dir**

In `src/ai_chat_tools.zig` `localCommandExecTool` (line 487), replace lines 489-500 — the whole block from `const gate = accessGate(...)` through the closing `};` of the `runShellCommand ... catch` statement (leave line 488's `isCancelled` check and line 501's `defer ctx.allocator.free(result.stdout);` intact) with:

```zig
    const effective_cwd = cwd orelse ctx.settings.working_dir;
    const gate = accessGate(ctx, command, effective_cwd);
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        const bl_reason = if (gate.blacklisted) allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous) DANGEROUS_COMMAND_APPROVAL_REASON else platform_process.localCommandApprovalLabel();
        if (!ctx.requestApproval(platform_process.localCommandToolName(), command, reason)) {
            return deniedResult(ctx.allocator, command, platform_process.localCommandDeniedReason());
        }
    }
    const result = runShellCommand(ctx.allocator, command, effective_cwd, ctx.settings.output_limit, timeout_ms, ctx) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "{s} failed: {}", .{ platform_process.localCommandFailureLabel(), err });
    };
```

- [ ] **Step 6: Run test to verify it passes**

Run: `zig build test-full`
Expected: PASS — both new `accessGate` tests pass; existing tool tests unaffected.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat_types.zig src/ai_chat_tools.zig
git commit -m "feat(agent): sandbox-aware access gate + default exec cwd to working dir"
```

---

## Task 3: Global default working directory

**Files:**
- Modify: `src/ai_chat.zig` — globals near line 238-241, `currentAgentSettings` (308-314), add `setDefaultWorkingDir`/`defaultWorkingDir`, `WORKING_DIR_MAX_BYTES`
- Test: `src/ai_chat.zig` (full suite)

- [ ] **Step 1: Write the failing test**

Append at the end of `src/ai_chat.zig`:

```zig
test "setDefaultWorkingDir is reflected in currentAgentSettings" {
    setDefaultWorkingDir("/tmp/proj");
    defer setDefaultWorkingDir(""); // reset global state for other tests
    try std.testing.expectEqualStrings("/tmp/proj", currentAgentSettings().working_dir.?);
    setDefaultWorkingDir("");
    try std.testing.expect(currentAgentSettings().working_dir == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `setDefaultWorkingDir` is undefined.

- [ ] **Step 3: Add the constant**

In `src/ai_chat.zig`, after `const SYSTEM_PROMPT_MAX_BYTES: usize = 16 * 1024;` (line 67), add:

```zig
const WORKING_DIR_MAX_BYTES: usize = 1024;
```

- [ ] **Step 4: Add the globals and accessors**

In `src/ai_chat.zig`, after the global declarations (`g_access_rules` at line 241), add:

```zig
var g_default_working_dir_buf: [WORKING_DIR_MAX_BYTES]u8 = undefined;
var g_default_working_dir_len: usize = 0;
```

Then add these two functions immediately after `loadAccessRules` (it ends at line 292):

```zig
/// Set the persistent default working directory (from config). Empty clears it.
/// Copies into a static buffer; oversized paths are truncated.
pub fn setDefaultWorkingDir(path: []const u8) void {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    const n = @min(path.len, g_default_working_dir_buf.len);
    @memcpy(g_default_working_dir_buf[0..n], path[0..n]);
    g_default_working_dir_len = n;
}

fn defaultWorkingDir() ?[]const u8 {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    if (g_default_working_dir_len == 0) return null;
    return g_default_working_dir_buf[0..g_default_working_dir_len];
}
```

- [ ] **Step 5: Merge the default into `currentAgentSettings`**

In `src/ai_chat.zig` `currentAgentSettings` (lines 308-314), add the working-dir line before `return s;`:

```zig
pub fn currentAgentSettings() AgentSettings {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    var s = g_agent_settings;
    s.access_rules = g_access_rules;
    if (g_default_working_dir_len > 0) s.working_dir = g_default_working_dir_buf[0..g_default_working_dir_len];
    return s;
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(agent): persistent default working directory in agent settings"
```

---

## Task 4: `/cwd` slash command + per-conversation override

**Files:**
- Modify: `src/ai_chat_composer.zig:6-19` (enum), `:42-87` (entries), add `parseCwdArg`
- Modify: `src/ai_chat.zig` — `Session` fields, `workingDirOverride`, `effectiveWorkingDirLocked`, `expandTilde`, `applyCwdArgLocked`, `.cwd` arms in `runBuiltinCommandLocked` (1688) and `slashCommandOutput` (349)
- Test: `src/ai_chat_composer.zig` (fast suite)

- [ ] **Step 1: Write the failing test (parser)**

Append at the end of `src/ai_chat_composer.zig`:

```zig
test "parseCwdArg classifies show, reset, and set" {
    try std.testing.expect(parseCwdArg("") == .show);
    try std.testing.expect(parseCwdArg("   ") == .show);
    try std.testing.expect(parseCwdArg("reset") == .reset);
    try std.testing.expect(parseCwdArg("default") == .reset);
    switch (parseCwdArg("  /home/u/proj  ")) {
        .set => |p| try std.testing.expectEqualStrings("/home/u/proj", p),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(exactBuiltinCommand("/cwd") != null);
    try std.testing.expect(exactBuiltinCommand("/cwd").? == .cwd);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `parseCwdArg` undefined and enum has no `.cwd`.

- [ ] **Step 3: Add the enum value, entry, and parser**

In `src/ai_chat_composer.zig`, add `cwd,` to the `SlashCommand` enum (after `permission,` at line 15):

```zig
    permission,
    cwd,
    export_markdown,
```

Add an entry to `slash_command_entries` (after the `/permission` entry block ending at line 74):

```zig
    .{
        .suggestion = .{ .command = "/cwd", .description = "set the conversation working directory" },
        .action = .cwd,
    },
```

Add the parser (place it after the `exactBuiltinCommand` function):

```zig
pub const CwdArg = union(enum) {
    show,
    reset,
    set: []const u8,
};

/// Classify a `/cwd` argument: empty => show current, `reset`/`default`/`clear`
/// => clear the override, anything else => set that path.
pub fn parseCwdArg(arg: []const u8) CwdArg {
    const t = std.mem.trim(u8, arg, " \t\r\n");
    if (t.len == 0) return .show;
    if (std.mem.eql(u8, t, "reset") or std.mem.eql(u8, t, "default") or std.mem.eql(u8, t, "clear")) return .reset;
    return .{ .set = t };
}
```

- [ ] **Step 4: Run parser test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Add the `Session` fields and accessors**

In `src/ai_chat.zig`, add two fields to `Session` (after `bound_surface_id_len: usize = 0,` at line ~456 — any field position is fine):

```zig
    working_dir_buf: [WORKING_DIR_MAX_BYTES]u8 = undefined,
    working_dir_len: usize = 0,
```

Add these methods inside the `Session` struct (next to other small accessors like `reasoningEffort`):

```zig
    /// Per-conversation working-dir override, or null when unset.
    pub fn workingDirOverride(self: *const Session) ?[]const u8 {
        if (self.working_dir_len == 0) return null;
        return self.working_dir_buf[0..self.working_dir_len];
    }

    fn effectiveWorkingDirLocked(self: *Session) ?[]const u8 {
        if (self.working_dir_len > 0) return self.working_dir_buf[0..self.working_dir_len];
        return defaultWorkingDir();
    }
```

- [ ] **Step 6: Add `expandTilde` and `applyCwdArgLocked`**

Add `expandTilde` near `resolveHomeDir` (file-scope helper, after line 302):

```zig
fn expandTilde(allocator: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
    if (path.len >= 1 and path[0] == '~') {
        if (home) |h| {
            if (path.len == 1) return allocator.dupe(u8, h);
            if (path[1] == '/' or path[1] == '\\') return std.fmt.allocPrint(allocator, "{s}{s}", .{ h, path[1..] });
        }
    }
    return allocator.dupe(u8, path);
}
```

Add `applyCwdArgLocked` as a `Session` method (place it right before `runBuiltinCommandLocked` at line 1686):

```zig
    /// Handle `/cwd`. Assumes self.mutex is held. Appends its own tool message
    /// (the caller suppresses the generic slash output).
    fn applyCwdArgLocked(self: *Session, arg: []const u8) void {
        switch (ai_chat_composer.parseCwdArg(arg)) {
            .show => {
                if (self.effectiveWorkingDirLocked()) |w| {
                    const msg = std.fmt.allocPrint(self.allocator, "Working directory: {s}", .{w}) catch return;
                    defer self.allocator.free(msg);
                    self.appendLocalToolMessageLocked(msg) catch {};
                } else {
                    self.appendLocalToolMessageLocked("Working directory: (unset). Use /cwd <path> to set one.") catch {};
                }
            },
            .reset => {
                self.working_dir_len = 0;
                self.appendLocalToolMessageLocked("Working directory override cleared; using the default.") catch {};
            },
            .set => |path| {
                const home = resolveHomeDir(self.allocator);
                defer if (home) |h| self.allocator.free(h);
                const expanded = expandTilde(self.allocator, path, home) catch return;
                defer self.allocator.free(expanded);
                const abs = std.fs.cwd().realpathAlloc(self.allocator, expanded) catch {
                    const m = std.fmt.allocPrint(self.allocator, "No such directory: {s}", .{path}) catch return;
                    defer self.allocator.free(m);
                    self.appendLocalToolMessageLocked(m) catch {};
                    return;
                };
                defer self.allocator.free(abs);
                var dir = std.fs.openDirAbsolute(abs, .{}) catch {
                    const m = std.fmt.allocPrint(self.allocator, "Not a directory: {s}", .{path}) catch return;
                    defer self.allocator.free(m);
                    self.appendLocalToolMessageLocked(m) catch {};
                    return;
                };
                dir.close();
                if (abs.len > self.working_dir_buf.len) {
                    self.appendLocalToolMessageLocked("Path too long for the working directory.") catch {};
                    return;
                }
                @memcpy(self.working_dir_buf[0..abs.len], abs);
                self.working_dir_len = abs.len;
                const m = std.fmt.allocPrint(self.allocator, "Working directory set to {s} for this conversation.", .{abs}) catch return;
                defer self.allocator.free(m);
                self.appendLocalToolMessageLocked(m) catch {};
            },
        }
        self.clearSubmittedInputLocked();
        self.setStatusLocked("Ready");
    }
```

- [ ] **Step 7: Wire the `.cwd` dispatch arm**

In `src/ai_chat.zig` `runBuiltinCommandLocked` switch (after the `.permission` arm at line 1705), add:

```zig
            .cwd => {
                self.applyCwdArgLocked(arg);
                result.suppress_output = true;
            },
```

- [ ] **Step 8: Satisfy the exhaustive `slashCommandOutput` switch**

In `src/ai_chat.zig` `slashCommandOutput` (line 349), add a `.cwd` arm (never reached — `/cwd` suppresses generic output — but the switch is exhaustive). Add after the `.permission` arm (line 357):

```zig
        .cwd => allocator.dupe(u8, "Working directory updated."),
```

- [ ] **Step 9: Run both suites to verify**

Run: `zig build test && zig build test-full`
Expected: PASS — parser test green; both suites compile (exhaustive switches satisfied) and pass.

- [ ] **Step 10: Commit**

```bash
git add src/ai_chat_composer.zig src/ai_chat.zig
git commit -m "feat(agent): /cwd slash command + per-conversation working dir override"
```

---

## Task 5: Overlay the override into the tool context

**Files:**
- Modify: `src/ai_chat_request.zig:504-518` (`toolContextFromRequest`)

- [ ] **Step 1: Apply the overlay**

Replace `toolContextFromRequest` in `src/ai_chat_request.zig` (lines 504-518) with:

```zig
fn toolContextFromRequest(request: *ChatRequest) ai_chat_types.ToolContext {
    var settings = ai_chat.currentAgentSettings();
    // Per-conversation override beats the global default.
    if (request.session.workingDirOverride()) |override| settings.working_dir = override;
    return .{
        .allocator = request.allocator,
        .ctx = request.session,
        .tool_host = request.tool_host,
        .tool_snapshot = request.tool_snapshot,
        .settings = settings,
        .copilot = request.copilot,
        .weixin_reply_context = request.weixin_reply_context,
        .write_context_surface_id = request.write_context_surface_id,
        .write_context_surface_id_len = request.write_context_surface_id_len,
        .approve = toolApprove,
        .cancelled = toolCancelled,
    };
}
```

- [ ] **Step 2: Run the full suite to verify no regression**

Run: `zig build test-full`
Expected: PASS — existing `ai_chat_request` tests unaffected (this only adds the override read). The override path is exercised end-to-end during GUI verification (Task 8).

- [ ] **Step 3: Commit**

```bash
git add src/ai_chat_request.zig
git commit -m "feat(agent): per-conversation working dir overrides the default in tool context"
```

---

## Task 6: Config key `ai-agent-working-dir`

**Files:**
- Modify: `src/config.zig` — decl near 303, apply near 814, template near 1637, help near 1274
- Modify: `src/App.zig` — field (45-area), init (199-area), deinit (25-area), reapply (372-area)
- Modify: `src/AppWindow.zig` — `setDefaultWorkingDir` calls at 159 and 2561
- Test: `src/config.zig` (fast suite)

- [ ] **Step 1: Write the failing test**

Append at the end of `src/config.zig`:

```zig
test "config: ai-agent-working-dir parses from a config line" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(allocator); // dupeString tracks the value in _owned_strings
    cfg.applyKeyValue(allocator, "ai-agent-working-dir", "/home/u/proj", ".");
    try std.testing.expectEqualStrings("/home/u/proj", cfg.@"ai-agent-working-dir");
}
```

(Pattern copied from the existing `test "config: ai agent options parse"`: `applyKeyValue(allocator, key, value, base_dir)` with `base_dir = "."`. The `defer cfg.deinit` is required here because a string value is duped into `_owned_strings`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `Config` has no field `ai-agent-working-dir`.

- [ ] **Step 3: Add the config field**

In `src/config.zig`, after `@"ai-agent-output-limit": u32 = 16 * 1024,` (line 303), add:

```zig
/// Default working directory for the AI agent's local commands (empty = unset).
@"ai-agent-working-dir": []const u8 = "",
```

- [ ] **Step 4: Add the apply branch**

In the key-dispatch chain (after the `ai-agent-output-limit` branch ending at line 815), add:

```zig
    } else if (std.mem.eql(u8, key, "ai-agent-working-dir")) {
        self.@"ai-agent-working-dir" = self.dupeString(allocator, value) orelse return;
```

- [ ] **Step 5: Add template + help text**

In the commented config template (after `# ai-agent-output-limit = 16384` at line 1637), add:

```zig
    \\# ai-agent-working-dir =          # default dir for downloads/clones (empty = unset)
```

In the CLI help block (after the `--ai-agent-output-limit` line at line 1274), add:

```zig
        \\  --ai-agent-working-dir <path> Default working directory for agent local commands
```

- [ ] **Step 6: Run config test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 7: Mirror the field in `App`**

In `src/App.zig`:

- Add the field after `font_family: []const u8,` (line 45) — keep it next to the other `ai_agent_*` fields at line 104 instead, to group them:

```zig
ai_agent_working_dir: []const u8,
```

- In `App.create`'s struct literal, after `.ai_agent_output_limit = cfg.@"ai-agent-output-limit",` (line 241), add:

```zig
        .ai_agent_working_dir = try dupeStr(allocator, cfg.@"ai-agent-working-dir"),
```

- In `App.deinit`, after `self.allocator.free(self.font_family);` (line 25 of deinit), add:

```zig
    self.allocator.free(self.ai_agent_working_dir);
```

- In the reapply function (`updateConfig`), after the `ai_agent_output_limit` reassignment (line 409), add:

```zig
    self.replaceStr(&self.ai_agent_working_dir, cfg.@"ai-agent-working-dir");
```

- [ ] **Step 8: Push the default into the agent at both config sites**

In `src/AppWindow.zig`, after the first `configureAgent` call's closing `});` (line 159), add:

```zig
    ai_chat.setDefaultWorkingDir(app.ai_agent_working_dir);
```

After the second `configureAgent` call's closing `});` in `applyReloadedConfig` (line 2561), add:

```zig
    ai_chat.setDefaultWorkingDir(cfg.@"ai-agent-working-dir");
```

- [ ] **Step 9: Run both suites to verify**

Run: `zig build test && zig build test-full`
Expected: PASS — config test green; App/AppWindow compile.

- [ ] **Step 10: Commit**

```bash
git add src/config.zig src/App.zig src/AppWindow.zig
git commit -m "feat(agent): ai-agent-working-dir config key feeds the default working dir"
```

---

## Task 7: Tell the model about the default cwd

**Files:**
- Modify: `src/platform/process.zig:86-91` (`localCommandToolDescriptionForOs`)
- Test: `src/platform/process.zig`

- [ ] **Step 1: Write the failing test**

Append at the end of `src/platform/process.zig`:

```zig
test "local command tool description mentions the working-directory default" {
    const posix = localCommandToolDescriptionForOs(.linux);
    try std.testing.expect(std.mem.indexOf(u8, posix, "working directory") != null);
    const win = localCommandToolDescriptionForOs(.windows);
    try std.testing.expect(std.mem.indexOf(u8, win, "working directory") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — current descriptions do not contain "working directory".

(If `platform/process.zig` is not in the fast suite, run `zig build test-full` instead — confirm by checking whether the existing `localCommandToolNameForOs` test runs under `zig build test`.)

- [ ] **Step 3: Update the descriptions**

Replace `localCommandToolDescriptionForOs` in `src/platform/process.zig` (lines 86-91) with:

```zig
pub fn localCommandToolDescriptionForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "Run a local PowerShell command on Windows and return stdout, stderr, and exit status. When 'cwd' is omitted, the command runs in the conversation's working directory, so place downloads and clones there by default."
    else
        "Run a local POSIX shell command and return stdout, stderr, and exit status. When 'cwd' is omitted, the command runs in the conversation's working directory, so place downloads and clones there by default.";
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test` (or `zig build test-full` per Step 2)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/platform/process.zig
git commit -m "feat(agent): note working-directory default in the local command tool description"
```

---

## Task 8: Full verification + cross-compile

**Files:** none (verification only)

- [ ] **Step 1: Run both test suites**

Run: `zig build test && zig build test-full`
Expected: PASS — 0 failed in both. Note the full-suite count (baseline was ~673 passed / 4 skipped / 0 failed; new tests raise the passed count).

- [ ] **Step 2: Windows cross-compile**

Run: `zig build -Dtarget=x86_64-windows-gnu`
Expected: builds cleanly (this is the platform the issue targets; confirms the Windows path/code paths compile).

- [ ] **Step 3: GUI verification checklist (manual, record results)**

In a built app:
1. Set `ai-agent-working-dir` in config to an existing dir → start a chat → ask the agent to download a file with no path → file lands in that dir (not C:/home).
2. In `confirm` mode, ask the agent to `git clone` a small repo → it runs without an approval prompt (confined) and lands in the working dir.
3. Ask the agent to `rm` something inside the working dir → it still asks for confirmation.
4. `/cwd` (no arg) shows the effective dir; `/cwd <other-existing-dir>` switches it for that conversation; `/cwd /does/not/exist` reports "No such directory"; `/cwd reset` returns to the default.
5. A second conversation starts from the global default (override is per-conversation).

- [ ] **Step 4: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "test(agent): verify working-directory sandbox end-to-end"
```

---

## Notes for the implementer

- **Zero-regression invariant:** every behavior change is gated on a non-empty effective working dir. With none set, `accessGate` returns the pre-existing result and `localCommandExecTool` passes a null cwd exactly as before.
- **Deny always wins:** `force = dangerous or blacklisted` is unchanged; the `and !blacklisted` guard on `skip` keeps a confined-but-deny-listed read forced.
- **Residual risk (documented, accepted for v1):** a confined command with no local path argument but arbitrary effects (`curl URL | sh`) is treated as confined and auto-runs in `confirm`/`auto`. Mitigations: dangerous commands still confirm, the deny-list still protects secrets, and nothing relaxes until a working directory is explicitly set.
- **Out of scope (per spec):** Settings-page GUI row; persisting the per-conversation override into AI History; extending the default/sandbox to SSH/WSL exec and file-drop; auto-creating a missing `/cwd` target; injecting the live path string into the request system prompt (the static tool-description mention in Task 7 covers "tell the model").
