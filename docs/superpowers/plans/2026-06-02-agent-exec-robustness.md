# Agent Exec Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the WispTerm agent from misjudging still-running terminal commands as failures, and give it a way to recover a stuck terminal by sending control keys (Ctrl+C etc.).

**Architecture:** The agent runs commands over open SSH/WSL sessions by wrapping them in nonce sentinels and polling the terminal snapshot for completion. The current completion check matches the bare end-marker, which also appears in the shell's *echo* of the wrapped command, so it fires before the command runs and returns garbage. We make completion detection require the real `:<status-digit>` suffix, surface the exit status, add a "previous command still running" guard, replace the terse timeout message with an instructive one, and extend `terminal_repl_exec` to send control-key bytes (`<ctrl-c>`, `<ctrl-d>`, `<ctrl-u>`, `<esc>`, `<enter>`).

**Tech Stack:** Zig. Tests run via `zig build test` (fast suite) and `zig build test-full` (full app graph). `ai_chat_tools.zig` and `platform/agent_prompt.zig` tests run only under `test-full`; `ai_chat_protocol.zig` runs under both.

**Spec:** `docs/superpowers/specs/2026-06-02-agent-exec-robustness-design.md`

---

## File Structure

- `src/ai_chat_tools.zig` — all core logic + unit tests:
  - new `findCompletedEnd` (sentinel completion that ignores the echo)
  - reworked `extractUnixCommandResult` (anchors off the real end, prepends `exit_status=N`)
  - `waitForSentinelResult` uses `findCompletedEnd`; instructive timeout message
  - new `hasPendingAgentCommand` + busy-guard in `unixSessionExecTool`
  - new `controlKeyByte` + `sendControlKey`; `terminalReplExecTool` routes control keys
- `src/ai_chat_protocol.zig` — `terminal_repl_exec` schema documents control keys (+ test)
- `src/platform/agent_prompt.zig` — system-prompt guidance (+ test)

---

## Task 1: Sentinel completion detection + exit status

**Files:**
- Modify: `src/ai_chat_tools.zig` (add `findCompletedEnd`, rework `extractUnixCommandResult` at `:1326`)
- Test: `src/ai_chat_tools.zig` (new tests in the test block)

- [ ] **Step 1: Write the failing tests**

Add these tests near the other tool tests (e.g. after the `test "ai chat detects dangerous shell commands"` block):

```zig
test "agent exec sentinel ignores the echoed command line" {
    const allocator = std.testing.allocator;
    // The shell echoes the whole wrapped command (with literal \n and %s) above
    // the real printf output. Only the real END line ends in `:<digit>`.
    const snapshot =
        "(base) u@h:~$  printf '\\n__WISPTERM_AGENT_START_111__\\n'; { echo hi; } 2>&1;" ++
        " __wispterm_agent_status=$?; printf '\\n__WISPTERM_AGENT_END_111__:%s\\n' \"$s\"\n" ++
        "\n__WISPTERM_AGENT_START_111__\n" ++
        "hi\n" ++
        "\n__WISPTERM_AGENT_END_111__:0\n" ++
        "(base) u@h:~$ ";

    // findCompletedEnd points at the real END (the `:0` one), not the echo.
    const end = findCompletedEnd(snapshot, "__WISPTERM_AGENT_END_111__").?;
    try std.testing.expect(std.mem.startsWith(u8, snapshot[end..], "__WISPTERM_AGENT_END_111__:0"));

    const result = try extractUnixCommandResult(allocator, snapshot, "__WISPTERM_AGENT_START_111__", "__WISPTERM_AGENT_END_111__");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("exit_status=0\nhi", result);
}

test "agent exec sentinel treats echo-only snapshot as not finished" {
    const incomplete =
        "(base) u@h:~$  printf '\\n__WISPTERM_AGENT_END_222__:%s\\n' \"$s\"\n" ++
        "\n__WISPTERM_AGENT_START_222__\n" ++
        "Cloning into 'x'...\n";
    try std.testing.expect(findCompletedEnd(incomplete, "__WISPTERM_AGENT_END_222__") == null);
}

test "agent exec sentinel parses multi-digit exit status" {
    const allocator = std.testing.allocator;
    const snapshot =
        "\n__WISPTERM_AGENT_START_333__\n" ++
        "boom\n" ++
        "\n__WISPTERM_AGENT_END_333__:128\n";
    const result = try extractUnixCommandResult(allocator, snapshot, "__WISPTERM_AGENT_START_333__", "__WISPTERM_AGENT_END_333__");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("exit_status=128\nboom", result);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — `findCompletedEnd` is undefined; `extractUnixCommandResult` returns the echo fragment without `exit_status=`.

- [ ] **Step 3: Add `findCompletedEnd` and rework `extractUnixCommandResult`**

Replace the existing `extractUnixCommandResult` function (currently at `src/ai_chat_tools.zig:1326`) with the following, which adds `findCompletedEnd` just above it:

```zig
/// Find the END sentinel that marks real completion: the first occurrence of
/// `end_marker` immediately followed by `:` and an ASCII digit (the exit
/// status). The shell echoes the wrapped command line, which contains the bare
/// marker followed by `:%s` (or, for R, `:"`); those never satisfy the
/// digit test, so the echo is ignored. Returns the byte index of the marker, or
/// null if the command has not completed yet.
fn findCompletedEnd(text: []const u8, end_marker: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, end_marker)) |idx| {
        const colon = idx + end_marker.len;
        if (colon + 1 < text.len and text[colon] == ':' and std.ascii.isDigit(text[colon + 1])) {
            return idx;
        }
        from = idx + 1;
    }
    return null;
}

fn extractUnixCommandResult(allocator: std.mem.Allocator, text: []const u8, start_marker: []const u8, end_marker: []const u8) ![]u8 {
    const end = findCompletedEnd(text, end_marker) orelse return allocator.dupe(u8, text);

    // Exit status: digits after the matched marker's ':'.
    const status_start = end + end_marker.len + 1;
    var status_end = status_start;
    while (status_end < text.len and std.ascii.isDigit(text[status_end])) : (status_end += 1) {}
    const status = text[status_start..status_end];

    // The real START sits just above the output; the echo's START is further up.
    // Take the last START before the completed END.
    const start = std.mem.lastIndexOf(u8, text[0..end], start_marker) orelse {
        const body = std.mem.trim(u8, text[0..end], " \t\r\n");
        return std.fmt.allocPrint(allocator, "exit_status={s}\n{s}", .{ status, body });
    };
    const body = std.mem.trim(u8, text[start + start_marker.len .. end], " \t\r\n");
    return std.fmt.allocPrint(allocator, "exit_status={s}\n{s}", .{ status, body });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS (all three new tests; suite still 0 failed).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "$(printf 'fix(agent): match completion sentinel by :status, ignore echoed command\n\nThe interactive shell echoes the wrapped command (which contains the bare\nend marker plus :%%s) before it runs, so the old bare-substring match fired\nimmediately and returned an echo fragment. Require :<digit> and surface the\nexit status.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 2: Use `findCompletedEnd` in the wait loop + instructive timeout

**Files:**
- Modify: `src/ai_chat_tools.zig` — `waitForSentinelResult` (currently `:1044`-`:1073`)

- [ ] **Step 1: Write the failing test**

This is a message-shape change. Add a test that the timeout message tells the model the command is still running and not to re-issue it. Because `waitForSentinelResult` needs a `ToolHost`, test the message text via a small extracted helper. Add this helper near `waitForSentinelResult` and a test for it:

```zig
fn allocStillRunningTimeout(allocator: std.mem.Allocator, label: []const u8, elapsed_s: i64, snapshot: ?[]const u8) ![]u8 {
    if (snapshot) |text| {
        return std.fmt.allocPrint(allocator, "The {s} command has not returned after {d}s; it is most likely still running. Do NOT re-issue it. Re-check later with terminal_snapshot, or interrupt with terminal_repl_exec repl=plain code=<ctrl-c>.\nLatest snapshot:\n{s}", .{ label, elapsed_s, text });
    }
    return std.fmt.allocPrint(allocator, "The {s} command has not returned after {d}s; it is most likely still running. Do NOT re-issue it. Re-check later with terminal_snapshot, or interrupt with terminal_repl_exec repl=plain code=<ctrl-c>.", .{ label, elapsed_s });
}
```

Test:

```zig
test "agent exec timeout message says still running, do not re-issue" {
    const allocator = std.testing.allocator;
    const msg = try allocStillRunningTimeout(allocator, "SSH", 60, "Cloning into 'x'...");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "still running") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Do NOT re-issue") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "code=<ctrl-c>") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Cloning into 'x'...") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — `allocStillRunningTimeout` is undefined.

- [ ] **Step 3: Implement — add the helper and rewire `waitForSentinelResult`**

Add `allocStillRunningTimeout` (from Step 1) just above `waitForSentinelResult`, then replace the body of `waitForSentinelResult` (`:1044`-`:1073`) with:

```zig
fn waitForSentinelResult(
    ctx: *const ToolContext,
    host: ToolHost,
    surface: ToolSurface,
    label: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    timeout_ms: u32,
) ![]u8 {
    const started = std.time.milliTimestamp();
    const deadline = started + @as(i64, @intCast(@max(timeout_ms, 1000)));
    var last: ?[]u8 = null;
    defer if (last) |text| ctx.allocator.free(text);

    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        if (last) |old| ctx.allocator.free(old);
        last = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch null;
        if (last) |text| {
            if (findCompletedEnd(text, end_marker) != null) {
                return extractUnixCommandResult(ctx.allocator, text, start_marker, end_marker);
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const elapsed_s = @divFloor(std.time.milliTimestamp() - started, 1000);
    return allocStillRunningTimeout(ctx.allocator, label, elapsed_s, last);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "$(printf 'fix(agent): instructive exec timeout — still running, do not re-issue\n\nReplace the terse sentinel-timeout message with one that tells the model the\ncommand is probably still running, not to re-issue it, and how to re-check or\ninterrupt. Wait loop now uses findCompletedEnd.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 3: "Previous command still running" guard

**Files:**
- Modify: `src/ai_chat_tools.zig` — add `hasPendingAgentCommand`; guard in `unixSessionExecTool` (after `:1014`)

- [ ] **Step 1: Write the failing test**

```zig
test "agent exec detects a still-pending previous command" {
    // Real START present, no completed END -> pending.
    const pending = "__WISPTERM_AGENT_START_222__\nCloning into 'x'...\n";
    try std.testing.expect(hasPendingAgentCommand(pending));

    // Echo end (:%s) only, no real :<digit> -> still pending.
    const echo_only =
        "$  printf '\\n__WISPTERM_AGENT_END_222__:%s\\n'\n__WISPTERM_AGENT_START_222__\nfoo\n";
    try std.testing.expect(hasPendingAgentCommand(echo_only));

    // Completed END present -> not pending.
    const done = "__WISPTERM_AGENT_START_222__\nhi\n__WISPTERM_AGENT_END_222__:0\n$ ";
    try std.testing.expect(!hasPendingAgentCommand(done));

    // No agent markers at all -> not pending.
    try std.testing.expect(!hasPendingAgentCommand("(base) u@h:~$ "));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — `hasPendingAgentCommand` is undefined.

- [ ] **Step 3: Implement `hasPendingAgentCommand`**

Add this helper just above `unixSessionExecTool` (`:992`):

```zig
const AGENT_START_PREFIX = "__WISPTERM_AGENT_START_";

/// Whether the surface's most recent agent command is still running: find the
/// last START marker, read its nonce, and report true if no completed END
/// (`__WISPTERM_AGENT_END_<nonce>__:<digit>`) appears after it. If the start has
/// scrolled out of the snapshot we report false (idle) — an acceptable
/// false-negative; a stale false-positive self-heals via <ctrl-c> + retry.
fn hasPendingAgentCommand(snapshot: []const u8) bool {
    const last_start = std.mem.lastIndexOf(u8, snapshot, AGENT_START_PREFIX) orelse return false;
    const nonce_start = last_start + AGENT_START_PREFIX.len;
    var i = nonce_start;
    while (i < snapshot.len and std.ascii.isDigit(snapshot[i])) : (i += 1) {}
    const nonce = snapshot[nonce_start..i];
    if (nonce.len == 0) return false;

    var buf: [64]u8 = undefined;
    const end_marker = std.fmt.bufPrint(&buf, "__WISPTERM_AGENT_END_{s}__", .{nonce}) catch return false;
    return findCompletedEnd(snapshot[last_start..], end_marker) == null;
}
```

- [ ] **Step 4: Add the guard in `unixSessionExecTool`**

In `unixSessionExecTool`, immediately after the line
`if (try shellExecInteractiveAgentCommandRefusal(ctx.allocator, kind, command)) |message| return message;` (`:1014`) and before `const nonce = std.time.milliTimestamp();`, insert:

```zig
    // Refuse to inject a new command while the previous one is still running:
    // interleaved sentinels confuse parsing and the model tends to re-issue,
    // duplicating side effects (e.g. a second git clone). A fresh snapshot is
    // authoritative; the cached surface snapshot may be stale.
    if (host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch null) |guard_snapshot| {
        defer ctx.allocator.free(guard_snapshot);
        if (hasPendingAgentCommand(guard_snapshot)) {
            return std.fmt.allocPrint(ctx.allocator, "A previous command is still running in this {s} terminal. Do not start another command. Wait and re-check with terminal_snapshot, or interrupt it first with terminal_repl_exec repl=plain code=<ctrl-c>.", .{kind.label()});
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "$(printf 'feat(agent): guard against injecting a command while one is still running\n\nBefore an ssh/wsl session exec, check a fresh snapshot for a pending agent\nsentinel and refuse with guidance, preventing duplicate side effects like the\ndouble git clone.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 4: Control-key tokens in `terminal_repl_exec`

**Files:**
- Modify: `src/ai_chat_tools.zig` — add `controlKeyByte` + `sendControlKey`; route in `terminalReplExecTool` (`:723`)

- [ ] **Step 1: Write the failing test**

```zig
test "agent control-key tokens parse to raw bytes, plain text is unaffected" {
    try std.testing.expectEqual(@as(?u8, 0x03), controlKeyByte("<ctrl-c>"));
    try std.testing.expectEqual(@as(?u8, 0x03), controlKeyByte("  <Ctrl-C> "));
    try std.testing.expectEqual(@as(?u8, 0x04), controlKeyByte("<ctrl-d>"));
    try std.testing.expectEqual(@as(?u8, 0x15), controlKeyByte("<ctrl-u>"));
    try std.testing.expectEqual(@as(?u8, 0x1b), controlKeyByte("<esc>"));
    try std.testing.expectEqual(@as(?u8, 0x0d), controlKeyByte("<enter>"));
    try std.testing.expectEqual(@as(?u8, 0x0d), controlKeyByte("<cr>"));
    // A substring inside real text must NOT be interpreted as a control key.
    try std.testing.expectEqual(@as(?u8, null), controlKeyByte("echo <ctrl-c>"));
    try std.testing.expectEqual(@as(?u8, null), controlKeyByte("ls -la"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — `controlKeyByte` is undefined.

- [ ] **Step 3: Implement `controlKeyByte` and `sendControlKey`**

Add both just above `terminalReplExecTool` (`:723`):

```zig
/// If `code` (trimmed) is exactly one recognized control-key token, return the
/// raw byte to send. Whole-string match only, so ordinary text that merely
/// contains a token is sent verbatim.
fn controlKeyByte(code: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, code, " \t\r\n");
    const Pair = struct { token: []const u8, byte: u8 };
    const pairs = [_]Pair{
        .{ .token = "<ctrl-c>", .byte = 0x03 },
        .{ .token = "<ctrl-d>", .byte = 0x04 },
        .{ .token = "<ctrl-u>", .byte = 0x15 },
        .{ .token = "<esc>", .byte = 0x1b },
        .{ .token = "<enter>", .byte = 0x0d },
        .{ .token = "<cr>", .byte = 0x0d },
    };
    for (pairs) |p| {
        if (std.ascii.eqlIgnoreCase(trimmed, p.token)) return p.byte;
    }
    return null;
}

/// Send a single raw control byte (no submit key appended), wait briefly for the
/// terminal to react, and return a fresh snapshot so the model sees the
/// recovered state.
fn sendControlKey(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, label: []const u8, byte: u8) ![]u8 {
    const bytes = [_]u8{byte};
    if (!host.writeSurface(host.ctx, surface.ptr, &bytes)) {
        return ctx.allocator.dupe(u8, "Failed to write control key to terminal surface.");
    }

    const deadline = std.time.milliTimestamp() + 400;
    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const latest = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch
        return std.fmt.allocPrint(ctx.allocator, "Sent {s}; failed to read terminal snapshot.", .{label});
    defer ctx.allocator.free(latest);
    const out = try std.fmt.allocPrint(ctx.allocator, "Sent {s} to terminal.\nLatest snapshot:\n{s}", .{ label, latest });
    return truncateOwned(ctx.allocator, ctx.settings, out);
}
```

- [ ] **Step 4: Route control keys in `terminalReplExecTool`**

Replace the body of `terminalReplExecTool` (`:723`-`:750`) with:

```zig
fn terminalReplExecTool(ctx: *ToolContext, surface_id: []const u8, repl_name: []const u8, code: []const u8, timeout_ms: u32) ![]u8 {
    const repl = ReplKind.parse(repl_name) orelse return std.fmt.allocPrint(ctx.allocator, "Unsupported repl \"{s}\". Use r, python, codex, claude_code, or plain.", .{repl_name});
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const control = controlKeyByte(code);
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

    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = findSurface(snapshot, surface_id) orelse return ctx.allocator.dupe(u8, "No matching terminal surface.");
    if (try ensureWriteContext(ctx, surface)) |message| return message;

    if (control) |byte| {
        return sendControlKey(ctx, host, surface, std.mem.trim(u8, code, " \t\r\n"), byte);
    }

    return switch (repl) {
        .r => rSessionEvalTool(ctx, host, surface, code, timeout_ms),
        .python => pythonSessionEvalTool(ctx, host, surface, code, timeout_ms),
        .codex, .claude_code => plainReplInputTool(ctx, host, surface, repl, code, timeout_ms),
        .plain => plainReplInputTool(ctx, host, surface, repl, code, timeout_ms),
    };
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "$(printf 'feat(agent): send control keys via terminal_repl_exec to recover stuck terminals\n\nWhen code is exactly <ctrl-c>/<ctrl-d>/<ctrl-u>/<esc>/<enter>, write the raw\nbyte (no submit key) and return a fresh snapshot, so the agent can break out of\ncontinuation prompts and hung commands instead of typing more text.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 5: Tool-schema description + system-prompt guidance

**Files:**
- Modify: `src/ai_chat_protocol.zig` — `terminal_repl_exec` schema (`:555`) + new test
- Modify: `src/platform/agent_prompt.zig` — `common_tools_after_wsl` (`:48`) + new test

- [ ] **Step 1: Write the failing tests**

In `src/ai_chat_protocol.zig`, add after `test "tool schemas include weixin_send_attachment"`:

```zig
test "terminal_repl_exec schema documents control keys" {
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("interrupt it") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(std.testing.allocator, params, &msgs, true);
    defer std.testing.allocator.free(json);
    // Assert on bracket-free substrings so the check is robust to any
    // `<`/`>` escaping the JSON emitter might apply.
    try std.testing.expect(std.mem.indexOf(u8, json, "ctrl-c") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ctrl-u") != null);
}
```

In `src/platform/agent_prompt.zig`, add after `test "platform agent prompt points at the wispterm_docs tool on every OS"`:

```zig
test "platform agent prompt teaches stuck-terminal interrupt recovery" {
    for ([_]std.Target.Os.Tag{ .windows, .linux, .macos }) |os| {
        const p = defaultSystemPromptForOs(os);
        try std.testing.expect(std.mem.indexOf(u8, p, "code=<ctrl-c>") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "still running") != null);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-full 2>&1 | tail -25`
Expected: FAIL — schema lacks `<ctrl-c>`; prompt lacks the guidance lines.

- [ ] **Step 3: Update the `terminal_repl_exec` schema**

In `src/ai_chat_protocol.zig:555`, change the `code` property description from
`\"code\":{\"type\":\"string\",\"description\":\"Code or plain text to submit.\"}`
to:

```
\"code\":{\"type\":\"string\",\"description\":\"Code or plain text to submit. To send a control key instead, set code to exactly one of <ctrl-c>, <ctrl-d>, <ctrl-u>, <esc>, <enter> — e.g. to interrupt a stuck command or leave a `>` continuation prompt.\"}
```

(Only the `description` value changes; leave `surface_id`, `repl`, `timeout_ms` untouched.)

- [ ] **Step 4: Add the system-prompt guidance**

In `src/platform/agent_prompt.zig`, in `const common_tools_after_wsl` (`:48`), after the line
`\\- Do not paste shell commands into Codex or Claude Code; send user-facing text.`
insert two lines:

```
    \\- A long-running session/exec command is usually still running, not broken: do not re-issue it; wait, then re-check with `terminal_snapshot`.
    \\- If a terminal is stuck (a `>` continuation prompt, an unclosed quote, a hung command, or a pager), recover with `terminal_repl_exec repl=plain code=<ctrl-c>` (or `<ctrl-u>`, `<esc>`, `<ctrl-d>`) — do not keep typing commands.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_protocol.zig src/platform/agent_prompt.zig
git commit -m "$(printf 'docs(agent): document control keys and still-running/recovery guidance\n\nterminal_repl_exec schema lists the control-key tokens; system prompt tells the\nagent that long commands are usually still running (do not re-issue) and how to\nrecover a stuck terminal with <ctrl-c>.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Final verification

- [ ] **Run the full suite**

Run: `zig build test 2>&1 | tail -5 && zig build test-full 2>&1 | tail -5`
Expected: both exit 0, 0 failed (baseline ~673/677 passed, 4 skipped, now plus the new tests).

- [ ] **GUI verification (manual, Windows/macOS):** Over an SSH/WSL session, ask the agent to `git clone` a medium repo and confirm it waits for completion (no duplicate clone), reports `exit_status=0`; then deliberately leave the shell in a `cd'` continuation and confirm `terminal_repl_exec repl=plain code=<ctrl-c>` returns it to a clean prompt.

---

## Self-Review notes

- **Spec coverage:** Fix A → Tasks 1–2; Fix B → Task 2; Fix C → Task 3; Fix D → Tasks 4–5. All covered.
- **Type consistency:** `findCompletedEnd` (Task 1) is reused by `extractUnixCommandResult` (Task 1), `waitForSentinelResult` (Task 2), and `hasPendingAgentCommand` (Task 3) with the same `(text, end_marker) -> ?usize` signature. `controlKeyByte`/`sendControlKey` names match between definition and use in Task 4.
- **No placeholders:** every code/step is complete.
