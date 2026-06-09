# Human-like REPL execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `terminal_repl_exec` type code into Python/R/Node/any line REPL exactly as a human would (raw input, prompt-return detection) instead of injecting an `exec()`+sentinel wrapper, and fix the prompt guidance that forced verbose `print()`-wrapped code.

**Architecture:** Replace the Python/R sentinel-wrapper eval tools and the crude `.plain` fixed-wait with one general engine: capture the REPL's current prompt, write the raw code + Enter, then poll the live per-surface snapshot until the screen quiesces *and* a ready prompt has returned (the captured prompt reappears, or a generic prompt heuristic matches). Codex/Claude Code TUIs and the shell-exec (`ssh`/`wsl`) sentinels are untouched.

**Tech Stack:** Zig 0.15.2; single file `src/ai_chat_tools.zig`; inline `test "..."` blocks run under `zig build test-full`. Prompt files `src/platform/agent_prompt.zig` (runtime) + `src/prompt.md` (parity).

---

## File Structure

- `src/ai_chat_tools.zig` — all mechanism + tests:
  - **Add** pure helpers: `extractPromptLine`, `looksLikeReadyPrompt`, `promptReturned`.
  - **Add** `waitForReplPromptReturn` (poll loop) and `lineReplEvalTool` (capture → write raw → wait).
  - **Reroute** the `terminalReplExecTool` switch so `.r`/`.python`/`.plain` use `lineReplEvalTool`.
  - **Simplify** `plainReplInputTool` to its now-only callers (`.codex`/`.claude_code`).
  - **Remove** `pythonSessionEvalTool`, `rSessionEvalTool`, `pythonStringLiteral`, `rStringLiteral`, `doubleQuotedStringLiteral`, and their two now-obsolete tests.
- `src/platform/agent_prompt.zig` — REPL usage guidance (runtime prompt).
- `src/prompt.md` — parity copy of the guidance.

**Untouched (do NOT remove):** `hasPendingAgentCommand`, `extractUnixCommandResult`, `findCompletedEnd`, `AGENT_START_PREFIX` (used by shell-exec); `waitForAgentAppReplResult`, `replSnapshotLooksBusy`, `allocAgentAppReplResult` (codex/claude_code); `allocPlainReplInput`, `plainReplSubmitKey` (reused by the new engine).

---

## Task 1: Pure helper `extractPromptLine`

**Files:**
- Modify: `src/ai_chat_tools.zig` (add function near the other REPL helpers, e.g. just above `const AGENT_START_PREFIX`, around line 1396; add test in the test region near line 2898)

- [ ] **Step 1: Write the failing test**

Add this test next to `test "ai chat REPL kind parses..."` (~line 2898):

```zig
test "extractPromptLine returns the trailing non-empty prompt line" {
    try std.testing.expectEqualStrings(">>>", extractPromptLine("hello\nworld\n>>> "));
    try std.testing.expectEqualStrings("In [3]:", extractPromptLine("Out[2]: 5\n\nIn [3]: "));
    try std.testing.expectEqualStrings("julia>", extractPromptLine("julia> "));
    try std.testing.expectEqualStrings("", extractPromptLine("\n  \n"));
    try std.testing.expectEqualStrings("", extractPromptLine(""));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: compile error — `use of undeclared identifier 'extractPromptLine'`.

- [ ] **Step 3: Write minimal implementation**

Add above `const AGENT_START_PREFIX = ...` (~line 1396):

```zig
/// The trailing prompt of a terminal snapshot: the last non-empty line, trimmed
/// of surrounding whitespace. Returns "" when no non-empty line exists. Used to
/// learn a REPL's prompt dynamically so completion detection is language-agnostic.
fn extractPromptLine(snapshot: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, snapshot, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return "";
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-full`
Expected: PASS (no failures).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(repl): add extractPromptLine helper for prompt-return detection"
```

---

## Task 2: Pure helper `looksLikeReadyPrompt`

**Files:**
- Modify: `src/ai_chat_tools.zig` (add function directly below `extractPromptLine`; add test below the Task 1 test)

- [ ] **Step 1: Write the failing test**

```zig
test "looksLikeReadyPrompt accepts prompts and rejects output" {
    try std.testing.expect(looksLikeReadyPrompt(">>>"));
    try std.testing.expect(looksLikeReadyPrompt(">"));
    try std.testing.expect(looksLikeReadyPrompt("In [3]:"));
    try std.testing.expect(looksLikeReadyPrompt("julia>"));
    try std.testing.expect(looksLikeReadyPrompt("dbname=#"));
    try std.testing.expect(looksLikeReadyPrompt("$"));
    // Output / results are not prompts.
    try std.testing.expect(!looksLikeReadyPrompt(""));
    try std.testing.expect(!looksLikeReadyPrompt("2"));
    try std.testing.expect(!looksLikeReadyPrompt("TypeError: unsupported operand"));
    // Too long to be a prompt line.
    try std.testing.expect(!looksLikeReadyPrompt("this is a very long line of output that should not be treated as a prompt at all"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: compile error — `use of undeclared identifier 'looksLikeReadyPrompt'`.

- [ ] **Step 3: Write minimal implementation**

Add directly below `extractPromptLine`:

```zig
/// Heuristic: does a trailing line look like an interactive REPL prompt waiting
/// for input? True for `>>>`, `>`, `In [3]:`, `julia>`, `dbname=#`, `$`, ... .
/// Conservative on length so long output lines are not mistaken for a prompt.
/// This is only the *fallback* signal; an exact match against the prompt captured
/// before typing (see `promptReturned`) is the primary, precise signal.
fn looksLikeReadyPrompt(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 64) return false;
    return switch (trimmed[trimmed.len - 1]) {
        '>', ':', '$', '#' => true,
        else => false,
    };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(repl): add looksLikeReadyPrompt heuristic"
```

---

## Task 3: Pure helper `promptReturned`

**Files:**
- Modify: `src/ai_chat_tools.zig` (add function directly below `looksLikeReadyPrompt`; add test below the Task 2 test)

- [ ] **Step 1: Write the failing test**

```zig
test "promptReturned matches the captured prompt or a generic prompt" {
    // Prompt unchanged: exact captured-prompt match.
    try std.testing.expect(promptReturned("foo\n>>> ", ">>>"));
    // Prompt changed (e.g. just launched python): generic heuristic catches >>>.
    try std.testing.expect(promptReturned("$ python\nPython 3.12\n>>> ", "$"));
    // Still running: last line is output, not a prompt.
    try std.testing.expect(!promptReturned("computing...\n42", ">>>"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: compile error — `use of undeclared identifier 'promptReturned'`.

- [ ] **Step 3: Write minimal implementation**

Add directly below `looksLikeReadyPrompt`:

```zig
/// True when the snapshot's trailing line shows the REPL is back at a ready
/// prompt: it equals the prompt captured before we typed, or it matches the
/// generic ready-prompt heuristic. The exact match handles prompts that stayed
/// the same; the heuristic handles prompts that changed (e.g. `$ ` -> `>>> `).
fn promptReturned(snapshot: []const u8, captured_prompt: []const u8) bool {
    const line = extractPromptLine(snapshot);
    if (captured_prompt.len != 0 and std.mem.eql(u8, line, captured_prompt)) return true;
    return looksLikeReadyPrompt(line);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(repl): add promptReturned settle predicate"
```

---

## Task 4: General `lineReplEvalTool` + `waitForReplPromptReturn`, reroute the switch

**Files:**
- Modify: `src/ai_chat_tools.zig`
  - Add `lineReplEvalTool` + `waitForReplPromptReturn` (place them just above `fn rSessionEvalTool`, ~line 1318).
  - Reroute the switch in `terminalReplExecTool` (~lines 1145-1150).
  - Simplify `plainReplInputTool` tail (~lines 1192-1205).
  - Add an integration test near the existing REPL-wait tests (~line 2970).

- [ ] **Step 1: Write the failing integration test**

Add next to the codex repl test (~line 2970):

```zig
test "line REPL eval types raw code and settles on the returned prompt" {
    const allocator = std.testing.allocator;
    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 2, .settled_text = ">>> 1+1\n2\n>>> " };
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = ReplWaitTestHost.host(&host_ctx),
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const surface = ToolSurface{
        .id = @constCast("surface-py"),
        .title = @constCast("python"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast(">>> "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrCast(&host_ctx),
    };

    const result = try lineReplEvalTool(&ctx, ReplWaitTestHost.host(&host_ctx), surface, .python, "1+1", 5000);
    defer allocator.free(result);

    // Raw code typed (code + Enter), NOT an exec()-wrapped sentinel blob.
    try std.testing.expectEqualStrings("1+1\r", host_ctx.all_writes[0..host_ctx.all_len]);
    try std.testing.expect(std.mem.indexOf(u8, result, "__WISPTERM_AGENT_START_") == null);
    // The REPL's own output is handed back for the model to read.
    try std.testing.expect(std.mem.indexOf(u8, result, "2") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: compile error — `use of undeclared identifier 'lineReplEvalTool'`.

- [ ] **Step 3: Add `lineReplEvalTool` and `waitForReplPromptReturn`**

Insert just above `fn rSessionEvalTool(...)` (~line 1318):

```zig
/// Run code in a line-oriented REPL (Python, R, Node, IPython, Julia, psql, ...)
/// the way a human does: capture the current prompt, type the raw code + Enter,
/// then wait until the screen settles back at a ready prompt. No sentinel wrapper
/// is injected, so the REPL echoes the user's code verbatim and the value of a
/// bare expression (e.g. `1+1`) is displayed normally. Errors appear as the REPL's
/// native traceback in the returned snapshot; there is no synthetic status code.
fn lineReplEvalTool(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, repl: ReplKind, code: []const u8, timeout_ms: u32) ![]u8 {
    // Learn the prompt currently shown so we can recognise its return. Read the
    // live per-surface snapshot (collectSnapshot is empty on the worker thread).
    const before = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch
        try ctx.allocator.dupe(u8, surface.snapshot);
    defer ctx.allocator.free(before);
    const captured_prompt = try ctx.allocator.dupe(u8, extractPromptLine(before));
    defer ctx.allocator.free(captured_prompt);

    const input = try allocPlainReplInput(ctx.allocator, repl, surface, code);
    defer ctx.allocator.free(input);
    if (!host.writeSurface(host.ctx, surface.ptr, input)) {
        return ctx.allocator.dupe(u8, "Failed to write to terminal surface.");
    }

    return waitForReplPromptReturn(ctx, host, surface, repl, captured_prompt, timeout_ms);
}

/// Poll the live per-surface snapshot until the screen has been unchanged for
/// `quiet_ms` (after a `min_wait_ms` floor) AND a ready prompt has returned, then
/// hand back the screen. On timeout, return the latest screen tagged as still in
/// progress so the model does not treat a partial result as final.
fn waitForReplPromptReturn(
    ctx: *const ToolContext,
    host: ToolHost,
    surface: ToolSurface,
    repl: ReplKind,
    captured_prompt: []const u8,
    timeout_ms: u32,
) ![]u8 {
    const wait_ms = @max(timeout_ms, 1000);
    const quiet_ms: i64 = 1000;
    const min_wait_ms: i64 = 500;
    const started = std.time.milliTimestamp();
    const deadline = started + @as(i64, @intCast(wait_ms));

    var last_text = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch
        try ctx.allocator.dupe(u8, surface.snapshot);
    defer ctx.allocator.free(last_text);
    var last_change_ms = started;

    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(150 * std.time.ns_per_ms);
        const now = std.time.milliTimestamp();

        const text = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch continue;
        if (std.mem.eql(u8, last_text, text)) {
            ctx.allocator.free(text);
        } else {
            ctx.allocator.free(last_text);
            last_text = text;
            last_change_ms = now;
        }

        const quiesced = now - started >= min_wait_ms and now - last_change_ms >= quiet_ms;
        if (quiesced and promptReturned(last_text, captured_prompt)) {
            return truncateOwned(ctx.allocator, ctx.settings, try ctx.allocator.dupe(u8, last_text));
        }
    }

    const note = try std.fmt.allocPrint(
        ctx.allocator,
        "\n[{s} REPL still busy after {d} ms; treat this as in progress, not a final result]",
        .{ repl.label(), wait_ms },
    );
    defer ctx.allocator.free(note);
    const combined = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ last_text, note });
    return truncateOwned(ctx.allocator, ctx.settings, combined);
}
```

- [ ] **Step 4: Reroute the `terminalReplExecTool` switch**

Replace the switch at ~lines 1145-1150:

```zig
    return switch (repl) {
        .r => rSessionEvalTool(ctx, host, surface, code, timeout_ms),
        .python => pythonSessionEvalTool(ctx, host, surface, code, timeout_ms),
        .codex, .claude_code => plainReplInputTool(ctx, host, surface, repl, code, timeout_ms),
        .plain => plainReplInputTool(ctx, host, surface, repl, code, timeout_ms),
    };
```

with:

```zig
    return switch (repl) {
        .r, .python, .plain => lineReplEvalTool(ctx, host, surface, repl, code, timeout_ms),
        .codex, .claude_code => plainReplInputTool(ctx, host, surface, repl, code, timeout_ms),
    };
```

- [ ] **Step 5: Simplify `plainReplInputTool` tail (now only codex/claude_code reach it)**

Replace the tail of `plainReplInputTool` — everything from the `if (repl == .codex or repl == .claude_code)` line through the end of the function (~lines 1192-1205):

```zig
    if (repl == .codex or repl == .claude_code) {
        return waitForAgentAppReplResult(ctx, host, surface, repl, timeout_ms);
    }

    const wait_ms = @min(@max(timeout_ms, 500), 5000);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(wait_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const latest = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch return ctx.allocator.dupe(u8, "Input sent; failed to read terminal snapshot.");
    return truncateOwned(ctx.allocator, ctx.settings, latest);
}
```

with:

```zig
    // Only Codex / Claude Code reach this tool now (line REPLs use
    // lineReplEvalTool); both settle on the busy-marker-aware waiter.
    return waitForAgentAppReplResult(ctx, host, surface, repl, timeout_ms);
}
```

- [ ] **Step 6: Run the integration test + full build**

Run: `zig build test-full`
Expected: PASS, including `line REPL eval types raw code and settles on the returned prompt`. The build must compile (the switch is now exhaustive without a separate `.plain` arm; `pythonSessionEvalTool`/`rSessionEvalTool` are still referenced — they are removed in Task 5).

Note: this task still references `rSessionEvalTool`/`pythonSessionEvalTool` only via the *old* switch text you just deleted, so they are now unused but still defined — that is fine until Task 5 removes them.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(repl): general human-typing line-REPL engine with prompt-return detection"
```

---

## Task 5: Remove the sentinel REPL wrappers and dead string-literal helpers

**Files:**
- Modify: `src/ai_chat_tools.zig`
  - Delete `rSessionEvalTool` (~lines 1318-1339) and `pythonSessionEvalTool` (~lines 1341-1367).
  - Delete `rStringLiteral`, `pythonStringLiteral`, `doubleQuotedStringLiteral` (~lines 1369-1394).
  - Delete the two obsolete tests: `"ai chat R string literal escapes code for REPL eval"` (~line 2890) and `"ai chat Python string literal escapes code for REPL eval"` (~line 2972).

- [ ] **Step 1: Delete the two sentinel eval tools**

Remove the entire `fn rSessionEvalTool(...) { ... }` and `fn pythonSessionEvalTool(...) { ... }` bodies. (They are no longer referenced after Task 4's reroute.)

- [ ] **Step 2: Delete the now-dead string-literal helpers**

Remove `pub fn rStringLiteral`, `pub fn pythonStringLiteral`, and `fn doubleQuotedStringLiteral`. Verify no remaining references first:

Run: `grep -n "StringLiteral\|pythonSessionEvalTool\|rSessionEvalTool" src/ai_chat_tools.zig`
Expected after deletion: only matches are inside the two test bodies you remove in Step 3 (or none).

- [ ] **Step 3: Delete the two obsolete tests**

Remove:
- `test "ai chat R string literal escapes code for REPL eval" { ... }`
- `test "ai chat Python string literal escapes code for REPL eval" { ... }`

Keep `test "ai chat REPL kind parses Python Codex and Claude Code aliases"` and the codex tests.

- [ ] **Step 4: Verify no dangling references and the suite is green**

Run: `grep -rn "StringLiteral\|pythonSessionEvalTool\|rSessionEvalTool\|doubleQuotedStringLiteral" src/`
Expected: no matches.

Run: `zig build test-full`
Expected: PASS (compiles cleanly; the removed-test count is gone, no unused-function errors).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "refactor(repl): drop exec()+sentinel Python/R wrappers and dead string-literal helpers"
```

---

## Task 6: Prompt guidance — write direct, REPL-native code

**Files:**
- Modify: `src/platform/agent_prompt.zig` (runtime prompt; near the `terminal_repl_exec` lines ~49-54)
- Modify: `src/prompt.md` (parity; near line 13)

- [ ] **Step 1: Update the runtime prompt**

In `src/platform/agent_prompt.zig`, just after the existing line (~50):

```zig
    \\- Start Codex/Claude Code/REPLs (Python/R/Node) via `terminal_repl_exec repl=plain`; never shell-exec them.
```

add these lines (match the file's `\\- ` bullet style and indentation exactly):

```zig
    \\- In a REPL, send code exactly as you would type it at the prompt. The REPL echoes the value of the last expression, so do NOT wrap results in `print(...)`/`cat(...)` just to see them — e.g. send `1+1`, not `print("result", 1+1)`.
    \\- Send the direct answer, not multiple alternative solutions or explanatory scaffolding. Keep multi-line code compact: no blank lines inside an indented block (a blank line can end the block early in a line REPL).
```

- [ ] **Step 2: Update the parity doc**

In `src/prompt.md`, after line 13 (`- If the target terminal is Codex, Claude Code, Python, R, or another app/REPL, use \`terminal_repl_exec\`.`), add:

```markdown
- In a REPL, send code exactly as you would type it at the prompt. The REPL echoes the value of the last expression, so do not wrap results in `print(...)`/`cat(...)` just to see them — e.g. send `1+1`, not `print("result", 1+1)`.
- Send the direct answer, not multiple alternative solutions or scaffolding. Keep multi-line code compact: no blank lines inside an indented block.
```

- [ ] **Step 3: Verify the prompt still builds**

Run: `zig build test-full`
Expected: PASS (the prompt is a compile-time string; a malformed `\\` multiline literal would fail to compile).

- [ ] **Step 4: Commit**

```bash
git add src/platform/agent_prompt.zig src/prompt.md
git commit -m "feat(repl): prompt guidance to send direct REPL-native code, no print wrappers"
```

---

## Task 7: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the fast suite**

Run: `zig build test`
Expected: PASS, 0 failed.

- [ ] **Step 2: Run the full suite**

Run: `zig build test-full`
Expected: PASS, 0 failed (4 pre-existing skips are fine; see project memory baseline).

- [ ] **Step 3: Confirm the sentinel wrapper is gone from the REPL path only**

Run: `grep -n "__WISPTERM_AGENT_START_" src/ai_chat_tools.zig`
Expected: matches remain ONLY in the shell-exec wrapper (`extractUnixCommandResult` path, the `setopt hist_ignore_space ...` line) and its tests — NOT in any Python/R REPL path.

- [ ] **Step 4: Manual GUI smoke (deferred / user-run)**

In a running build, open a Python REPL tab, ask the Copilot agent to "解决下报错" for `1+'1'`. Confirm:
- The terminal shows `>>> '1'+'1'` (or `1+1`) and its result — no `exec("...__WISPTERM_AGENT_START_...")` blob.
- An error shows the native traceback and the agent reads it.
- Repeat for R (`> `) and Node (`> `).

---

## Self-Review Notes

- **Spec coverage:** §1 general engine → Tasks 4-5; §2 pure helpers → Tasks 1-3; §3 prompt guidance → Task 6; §4 multi-line (raw-send + guidance) → Task 6 guidance; non-goals (keep shell sentinels, codex/claude_code waiter, no bracketed paste) → preserved in Task 4/5 scope and Task 7 Step 3 check.
- **Type/name consistency:** `extractPromptLine`, `looksLikeReadyPrompt`, `promptReturned`, `lineReplEvalTool`, `waitForReplPromptReturn` used consistently across tasks; reuses existing `allocPlainReplInput`, `plainReplSubmitKey`, `truncateOwned`, `ToolHost.surfaceSnapshot`, `ReplKind`, `ReplWaitTestHost`.
- **No placeholders:** every code/edit step shows the actual code or exact old→new text.
