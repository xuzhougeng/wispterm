# Enhance Copilot's Claude Code / Codex Capability — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Copilot reliably see and answer Claude Code / Codex confirmation prompts, instead of being blinded by a head-truncated snapshot and blindly guessing keystrokes.

**Architecture:** Three independent pieces — (1) visibility: build the live snapshot tail-biased and truncate keeping the tail; (2) a dedicated `terminal_answer_prompt` tool backed by a pure option-parser module; (3) prompt guidance. Pure logic lives in small testable modules; the tool layer is a thin wrapper over the existing terminal write/snapshot host seam.

**Tech Stack:** Zig, `ghostty-vt` terminal model, existing `ai_chat_tools.zig` tool framework, `agent_detector.zig` app/state detection.

**Spec:** `docs/superpowers/specs/2026-06-09-enhance-copilot-claude-code-codex-design.md`

**Test commands:**
- Fast pure-logic loop: `zig build test`
- Full suite (the gate): `zig build test-full`

---

## Background the worker needs

- The terminal snapshot text is built **oldest scrollback first, live screen last** (`src/remote_snapshot.zig:32-37`). The live interactive prompt is always at the **bottom**.
- Tool results over `settings.output_limit` (default 16 KB) are cut by `truncateOwned` (`src/ai_chat_tools.zig:2317`), which keeps `text[0..limit]` — the **head**. So a long Claude Code session's live prompt at the bottom gets dropped. This is the root bug.
- `agent_detector.detect(title, recent_output)` already classifies a surface as `claude_code`/`codex` and a state (`waiting_approval`, `running`, …) using the exact prompt phrases. The new tool reuses it as a gate.
- Claude Code & Codex approval menus look like:
  ```
  Do you want to make this edit to index.html?
  ❯ 1. Yes
    2. Yes, allow all edits during this session (shift+tab)
    3. No
  ```
  Pressing the option's **digit** selects-and-confirms; `Esc` cancels. Codex sometimes adds `Press enter to confirm or esc to cancel`, which needs a trailing Enter.
- Test host mock pattern: `ReplWaitTestHost` (`src/ai_chat_tools.zig:3258`) implements the `ToolHost` seam (`collectSnapshot`/`surfaceSnapshot`/`writeSurface`) with `settled_text`, `busy_until`, and a write recorder (`all_writes`). Tool tests set `ctx.tool_snapshot` so `resolveSurfaceId` finds the surface without the worker-empty `collectSnapshot`.

---

## Task 1: Tail-keeping truncation helper

**Files:**
- Modify: `src/ai_chat_tools.zig` (add `truncateTailOwned` next to `truncateOwned` at line 2317; add tests in the test section)

- [ ] **Step 1: Write the failing tests**

Add near the other tool tests (e.g. just after the `truncateOwned`-adjacent code or at the end of the test block in `src/ai_chat_tools.zig`):

```zig
test "truncateTailOwned keeps the tail and marks the dropped head" {
    const a = std.testing.allocator;
    const settings = AgentSettings{ .output_limit = 8 };
    const text = try a.dupe(u8, "ABCDEFGHIJKLMNOP"); // 16 bytes, limit 8
    const out = try truncateTailOwned(a, settings, text);
    defer a.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "IJKLMNOP"));
    try std.testing.expect(std.mem.indexOf(u8, out, "older output truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ABCD") == null);
}

test "truncateTailOwned returns short text unchanged" {
    const a = std.testing.allocator;
    const settings = AgentSettings{ .output_limit = 1024 };
    const text = try a.dupe(u8, "small");
    const out = try truncateTailOwned(a, settings, text);
    defer a.free(out);
    try std.testing.expectEqualStrings("small", out);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test-full 2>&1 | grep -A3 truncateTailOwned`
Expected: compile error — `truncateTailOwned` is undefined.

- [ ] **Step 3: Implement `truncateTailOwned`**

Add immediately after `truncateOwned` (after `src/ai_chat_tools.zig:2323`):

```zig
/// Like truncateOwned, but keeps the LAST `limit` bytes (the most recent
/// output) and marks the dropped head. Use for terminal-snapshot-bearing
/// results, where the live interactive screen is at the tail — keeping the head
/// would hide the current prompt.
fn truncateTailOwned(allocator: std.mem.Allocator, settings: AgentSettings, text: []u8) ![]u8 {
    const limit: usize = settings.output_limit;
    if (text.len <= limit) return text;
    const tail = text[text.len - limit ..];
    const truncated = try std.fmt.allocPrint(allocator, "...[older output truncated to {d} bytes]\n{s}", .{ limit, tail });
    allocator.free(text);
    return truncated;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -5`
Expected: build succeeds, suite passes (0 failed).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(agent): add tail-keeping truncation for snapshot results"
```

---

## Task 2: Route snapshot-bearing results through `truncateTailOwned`

**Files:**
- Modify: `src/ai_chat_tools.zig` — four return sites that carry a terminal snapshot:
  - `terminalSnapshotTool` (line 539)
  - `sendControlKey` (line 1112)
  - `plainReplInputTool` non-agent tail (line 1204)
  - `allocAgentAppReplResult` (line 1247)

- [ ] **Step 1: Write the failing test**

This verifies an oversized live screen returned by `terminal_snapshot` keeps the bottom (the prompt), not the top. Add to the test block in `src/ai_chat_tools.zig`:

```zig
test "terminal_snapshot keeps the live screen tail when output exceeds the limit" {
    const a = std.testing.allocator;
    // A long screen whose only prompt marker is at the very bottom.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(a);
    var i: usize = 0;
    while (i < 2000) : (i += 1) try big.appendSlice(a, "old scrollback line\n");
    try big.appendSlice(a, "Do you want to proceed? PROMPT_AT_BOTTOM");

    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 0, .settled_text = big.items };
    var dummy: u8 = 0;

    const surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = @constCast("surface-claude"),
        .title = @constCast("Claude Code"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast(""),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .claude_code,
        .agent_state = .waiting_approval,
        .agent_confidence = 90,
        .ptr = @ptrCast(&host_ctx),
    };
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = ReplWaitTestHost.host(&host_ctx),
        .tool_snapshot = .{ .surfaces = surfaces, .active_tab = 0 },
        .settings = .{ .output_limit = 4096 },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    // Free only the slice we allocated; the surface string fields are literals,
    // so do NOT call snap.deinit (it would free static memory). The tool operates
    // on a clone internally, so the literal-backed originals are never freed.
    defer if (ctx.tool_snapshot) |snap| a.free(snap.surfaces);

    const result = try terminalSnapshotTool(&ctx, @as(?[]const u8, "surface-claude"));
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "PROMPT_AT_BOTTOM") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "older output truncated") != null);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-full 2>&1 | grep -A6 "live screen tail"`
Expected: FAIL — current `truncateOwned` keeps the head, so `PROMPT_AT_BOTTOM` is absent.

- [ ] **Step 3: Swap the four call sites**

In `src/ai_chat_tools.zig`, change `truncateOwned` → `truncateTailOwned` at exactly these four return sites (leave every other `truncateOwned` call — shell/argv output — unchanged):

Line 539 (`terminalSnapshotTool`):
```zig
    return truncateTailOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
```

Line 1112 (`sendControlKey`):
```zig
    return truncateTailOwned(ctx.allocator, ctx.settings, out);
```

Line 1204 (`plainReplInputTool` tail):
```zig
    return truncateTailOwned(ctx.allocator, ctx.settings, latest);
```
> Note: at 1204 `latest` is currently passed directly. Check the surrounding code — it is `const latest = ... ; return truncateOwned(... latest);`. `truncateTailOwned` frees its `text` arg on truncation, but here `latest` is `defer`-freed? Re-read lines 1203-1204: `latest` is NOT deferred (it is returned through truncate, which frees it). So the direct swap is correct and ownership is unchanged.

Line 1247 (`allocAgentAppReplResult`):
```zig
    return truncateTailOwned(allocator, settings, try out.toOwnedSlice(allocator));
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test-full 2>&1 | tail -5`
Expected: build succeeds, suite passes (0 failed).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "fix(agent): keep the live-screen tail in terminal snapshot results"
```

---

## Task 3: Tail-bias the agent snapshot history budget

**Files:**
- Modify: `src/remote_snapshot.zig` (add `agent_max_history_rows`; add a test)
- Modify: `src/AppWindow.zig:4467-4471` (`buildRemoteSurfaceSnapshot` passes the smaller cap)

- [ ] **Step 1: Write the failing test**

Add to `src/remote_snapshot.zig` (after the existing snapshot tests):

```zig
test "agent snapshot caps history to the most recent rows but keeps the active screen" {
    var terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 3,
        .max_scrollback = 4096,
    });
    defer terminal.deinit(std.testing.allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();
    var i: usize = 1;
    while (i <= 13) : (i += 1) {
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "row{d}\r\n", .{i}) catch unreachable;
        stream.nextSlice(line);
    }

    // Cap history to 2 rows: oldest scrollback dropped, active screen kept.
    const snapshot = try allocTerminalSnapshot(std.testing.allocator, &terminal, 2);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "row1\r\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "row13") != null);
}
```

- [ ] **Step 2: Run the test to verify it fails OR passes for the right reason**

Run: `zig build test-full 2>&1 | grep -A4 "caps history"`
Expected: PASS (this validates existing tail-biased history math at a small cap). If it FAILS, the history math regressed — stop and investigate before continuing.

> Rationale: `allocTerminalSnapshot` already keeps the *most recent* `max_history_rows` (`history_start = history_total - history_rows`) and always emits the full active screen. The remaining work is wiring a smaller default for the agent path.

- [ ] **Step 3: Add the agent history constant**

In `src/remote_snapshot.zig`, after line 5 (`pub const default_max_history_rows`):

```zig
/// Smaller history budget for the live agent/Copilot snapshot path. The full
/// active screen is always included; only this many recent scrollback rows are
/// prepended, so the live interactive screen at the bottom is never crowded out
/// or truncated away. WeChat's remote path keeps the larger default.
pub const agent_max_history_rows: usize = 400;
```

- [ ] **Step 4: Point the agent snapshot builder at the smaller cap**

In `src/AppWindow.zig`, `buildRemoteSurfaceSnapshot` (lines 4467-4471):

```zig
    return remote_snapshot.allocTerminalSnapshot(
        allocator,
        &surface.terminal,
        remote_snapshot.agent_max_history_rows,
    );
```

- [ ] **Step 5: Run the suite**

Run: `zig build test-full 2>&1 | tail -5`
Expected: build succeeds, suite passes (0 failed).

- [ ] **Step 6: Commit**

```bash
git add src/remote_snapshot.zig src/AppWindow.zig
git commit -m "fix(agent): bound live snapshot history to recent rows (tail-biased)"
```

---

## Task 4: Pure prompt-option parser module

**Files:**
- Create: `src/agent_prompt_answer.zig`
- Modify: `src/test_main.zig` (register the module ~line 627, beside `agent_detector`)
- Modify: `src/test_fast.zig` (register for the fast loop, beside `web_search` ~line 61)

- [ ] **Step 1: Write the module with parser + tests**

Create `src/agent_prompt_answer.zig`:

```zig
//! Pure parsing/answer logic for Claude Code / Codex approval menus. No I/O.
//! `parsePromptOptions` extracts the numbered options of an approval prompt from
//! the live screen text; `resolveAnswer` (Task 5) maps a semantic answer to the
//! keystroke to send. Sibling of `agent_detector.zig`.
const std = @import("std");

pub const Option = struct {
    number: u8 = 0,
    highlighted: bool = false,
    shortcut: ?u8 = null,
    label: []const u8 = "",
};

/// Parse numbered option lines out of `screen`, writing up to `out.len` of them.
/// Returns the count written. An option line is, after optional leading spaces:
/// an optional selection marker (`>` or `❯`), a digit 1-9, `.` or `)`, then the
/// label (which may carry a trailing single-letter `(x)` shortcut).
pub fn parsePromptOptions(screen: []const u8, out: []Option) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |raw| {
        if (count >= out.len) break;
        const line = std.mem.trimRight(u8, raw, " \t\r");
        const parsed = parseOptionLine(line) orelse continue;
        out[count] = parsed;
        count += 1;
    }
    return count;
}

fn parseOptionLine(line: []const u8) ?Option {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    var highlighted = false;
    if (i < line.len and line[i] == '>') {
        highlighted = true;
        i += 1;
    } else if (i + 3 <= line.len and std.mem.eql(u8, line[i .. i + 3], "\xe2\x9d\xaf")) {
        highlighted = true; // ❯ U+276F
        i += 3;
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    if (i >= line.len or line[i] < '1' or line[i] > '9') return null;
    const number = line[i] - '0';
    i += 1;
    if (i >= line.len or (line[i] != '.' and line[i] != ')')) return null;
    i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const label = line[i..];
    return .{
        .number = number,
        .highlighted = highlighted,
        .shortcut = parseShortcut(label),
        .label = label,
    };
}

/// Capture a trailing single-letter parenthesized shortcut, e.g. "Yes (y)" → 'y'.
/// Multi-character hints like "(shift+tab)" or "(esc)" are ignored.
fn parseShortcut(label: []const u8) ?u8 {
    if (label.len < 3) return null;
    if (label[label.len - 1] != ')') return null;
    if (label[label.len - 3] != '(') return null;
    const c = label[label.len - 2];
    if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) return std.ascii.toLower(c);
    return null;
}

test "parsePromptOptions reads a Claude Code edit-approval menu" {
    const screen =
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0].number);
    try std.testing.expectEqualStrings("Yes", buf[0].label);
    try std.testing.expectEqual(@as(u8, 2), buf[1].number);
    try std.testing.expect(std.mem.indexOf(u8, buf[1].label, "allow all edits") != null);
    try std.testing.expectEqual(@as(u8, 3), buf[2].number);
    try std.testing.expectEqualStrings("No", buf[2].label);
}

test "parsePromptOptions reads a Codex menu with highlight and letter shortcuts" {
    const screen =
        \\Would you like to make the following edits?
        \\> 1. Yes, proceed (y)
        \\  2. Yes, and don't ask again for these files (a)
        \\  3. No, and tell codex what to do differently (esc)
        \\Press enter to confirm or esc to cancel
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(buf[0].highlighted);
    try std.testing.expectEqual(@as(?u8, 'y'), buf[0].shortcut);
    try std.testing.expectEqual(@as(?u8, 'a'), buf[1].shortcut);
    try std.testing.expectEqual(@as(?u8, null), buf[2].shortcut); // "(esc)" is not a single letter
}

test "parsePromptOptions ignores non-option lines" {
    const screen = "just some output\nno menu here\n$ ls -la";
    var buf: [8]Option = undefined;
    try std.testing.expectEqual(@as(usize, 0), parsePromptOptions(screen, &buf));
}
```

- [ ] **Step 2: Register the module in both test roots**

In `src/test_main.zig`, beside line 627 (`_ = @import("agent_detector.zig");`):
```zig
    _ = @import("agent_prompt_answer.zig");
```

In `src/test_fast.zig`, beside the `web_search` import (~line 61):
```zig
    _ = @import("agent_prompt_answer.zig");
```

- [ ] **Step 3: Run the fast suite to verify the parser tests pass**

Run: `zig build test 2>&1 | tail -5`
Expected: build succeeds, tests pass.

- [ ] **Step 4: Run the full suite**

Run: `zig build test-full 2>&1 | tail -5`
Expected: build succeeds, suite passes (0 failed).

- [ ] **Step 5: Commit**

```bash
git add src/agent_prompt_answer.zig src/test_main.zig src/test_fast.zig
git commit -m "feat(agent): add pure Claude Code/Codex prompt-option parser"
```

---

## Task 5: Answer-resolution (intent → keystroke)

**Files:**
- Modify: `src/agent_prompt_answer.zig` (add `Intent`, `Keystroke`, `parseIntent`, `parseOptionNumber`, `resolveAnswer` + helpers + tests)

- [ ] **Step 1: Write the failing tests**

Append to `src/agent_prompt_answer.zig` (after the parser tests):

```zig
test "parseIntent maps answer words and digits" {
    try std.testing.expectEqual(Intent.approve, parseIntent("approve").?);
    try std.testing.expectEqual(Intent.approve, parseIntent("yes").?);
    try std.testing.expectEqual(Intent.approve_all, parseIntent("approve_all").?);
    try std.testing.expectEqual(Intent.reject, parseIntent("reject").?);
    try std.testing.expectEqual(Intent.reject, parseIntent("no").?);
    try std.testing.expectEqual(Intent.esc, parseIntent("esc").?);
    try std.testing.expectEqual(Intent.enter, parseIntent("enter").?);
    try std.testing.expectEqual(Intent.option, parseIntent("2").?);
    try std.testing.expectEqual(@as(?Intent, null), parseIntent("banana"));
    try std.testing.expectEqual(@as(?u8, 2), parseOptionNumber("2"));
}

test "resolveAnswer picks the plain Yes for approve" {
    const screen =
        \\Do you want to make this edit?
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    const k = resolveAnswer(buf[0..n], screen, .approve, 0).?;
    try std.testing.expectEqualStrings("1", k.bytes);
    try std.testing.expect(!k.confirm_enter);
}

test "resolveAnswer picks the allow-all option for approve_all" {
    const screen =
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    const k = resolveAnswer(buf[0..n], screen, .approve_all, 0).?;
    try std.testing.expectEqualStrings("2", k.bytes);
}

test "resolveAnswer rejects with esc" {
    const screen = "  1. Yes\n  3. No";
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    const k = resolveAnswer(buf[0..n], screen, .reject, 0).?;
    try std.testing.expectEqualStrings("\x1b", k.bytes);
}

test "resolveAnswer follows Codex 'press enter to confirm' with a confirm Enter" {
    const screen =
        \\> 1. Yes, proceed (y)
        \\  3. No, and tell codex what to do differently (esc)
        \\Press enter to confirm or esc to cancel
    ;
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    const k = resolveAnswer(buf[0..n], screen, .approve, 0).?;
    try std.testing.expectEqualStrings("1", k.bytes);
    try std.testing.expect(k.confirm_enter);
}

test "resolveAnswer handles an inline [y/N] prompt with no numbered options" {
    const screen = "Overwrite existing file? [y/N]";
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
    const yes = resolveAnswer(buf[0..n], screen, .approve, 0).?;
    try std.testing.expectEqualStrings("y", yes.bytes);
    try std.testing.expect(yes.confirm_enter);
    const no = resolveAnswer(buf[0..n], screen, .reject, 0).?;
    try std.testing.expectEqualStrings("n", no.bytes);
}

test "resolveAnswer returns null when approve has no matching option" {
    const screen = "some text, no menu";
    var buf: [8]Option = undefined;
    const n = parsePromptOptions(screen, &buf);
    try std.testing.expectEqual(@as(?Keystroke, null), resolveAnswer(buf[0..n], screen, .approve, 0));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | grep -iA3 "resolveAnswer\|parseIntent"`
Expected: compile error — `Intent`, `Keystroke`, `resolveAnswer`, `parseIntent`, `parseOptionNumber` undefined.

- [ ] **Step 3: Implement the resolution logic**

Add to `src/agent_prompt_answer.zig` (after the `Option` type / before the tests is fine; keep public types near the top):

```zig
pub const Intent = enum { approve, approve_all, reject, enter, esc, option };

pub const Keystroke = struct {
    bytes: []const u8,
    confirm_enter: bool = false,
};

const digit_keys = "0123456789";

pub fn parseIntent(answer: []const u8) ?Intent {
    const a = std.mem.trim(u8, answer, " \t\r\n");
    if (eqlIgnoreCase(a, "approve") or eqlIgnoreCase(a, "yes") or eqlIgnoreCase(a, "y")) return .approve;
    if (eqlIgnoreCase(a, "approve_all") or eqlIgnoreCase(a, "always") or eqlIgnoreCase(a, "all")) return .approve_all;
    if (eqlIgnoreCase(a, "reject") or eqlIgnoreCase(a, "no") or eqlIgnoreCase(a, "n") or eqlIgnoreCase(a, "deny")) return .reject;
    if (eqlIgnoreCase(a, "enter")) return .enter;
    if (eqlIgnoreCase(a, "esc") or eqlIgnoreCase(a, "escape")) return .esc;
    if (a.len == 1 and a[0] >= '1' and a[0] <= '9') return .option;
    return null;
}

pub fn parseOptionNumber(answer: []const u8) ?u8 {
    const a = std.mem.trim(u8, answer, " \t\r\n");
    if (a.len == 1 and a[0] >= '1' and a[0] <= '9') return a[0] - '0';
    return null;
}

/// Map a semantic answer to the keystroke to send. `option_number` is only used
/// when `intent == .option`. Returns null when the intent cannot be matched to
/// anything on screen (caller should then ask for an explicit option number).
pub fn resolveAnswer(options: []const Option, screen: []const u8, intent: Intent, option_number: u8) ?Keystroke {
    const confirm = containsIgnoreCase(screen, "press enter to confirm");

    if (options.len == 0 and hasInlineYesNo(screen)) {
        return switch (intent) {
            .approve, .approve_all => Keystroke{ .bytes = "y", .confirm_enter = true },
            .reject => Keystroke{ .bytes = "n", .confirm_enter = true },
            .enter => Keystroke{ .bytes = "\r" },
            .esc => Keystroke{ .bytes = "\x1b" },
            .option => null,
        };
    }

    return switch (intent) {
        .enter => Keystroke{ .bytes = "\r" },
        .esc, .reject => Keystroke{ .bytes = "\x1b" },
        .option => digitKeystroke(option_number, confirm),
        .approve => blk: {
            const opt = firstAffirmative(options) orelse break :blk null;
            break :blk digitKeystroke(opt.number, confirm);
        },
        .approve_all => blk: {
            const opt = firstAllowAll(options) orelse break :blk null;
            break :blk digitKeystroke(opt.number, confirm);
        },
    };
}

fn digitKeystroke(number: u8, confirm: bool) ?Keystroke {
    if (number < 1 or number > 9) return null;
    return .{ .bytes = digit_keys[number .. number + 1], .confirm_enter = confirm };
}

fn firstAffirmative(options: []const Option) ?Option {
    for (options) |o| {
        if (startsWithIgnoreCase(o.label, "yes") and !isAllowAllLabel(o.label)) return o;
    }
    for (options) |o| {
        if (o.number == 1 and !isAllowAllLabel(o.label)) return o;
    }
    return null;
}

fn firstAllowAll(options: []const Option) ?Option {
    for (options) |o| {
        if (isAllowAllLabel(o.label)) return o;
    }
    return null;
}

fn isAllowAllLabel(label: []const u8) bool {
    return containsIgnoreCase(label, "all") or
        containsIgnoreCase(label, "don't ask") or
        containsIgnoreCase(label, "dont ask") or
        containsIgnoreCase(label, "this session");
}

fn hasInlineYesNo(screen: []const u8) bool {
    return containsIgnoreCase(screen, "[y/n]") or containsIgnoreCase(screen, "(y/n)");
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: build succeeds, tests pass.

- [ ] **Step 5: Run the full suite**

Run: `zig build test-full 2>&1 | tail -5`
Expected: 0 failed.

- [ ] **Step 6: Commit**

```bash
git add src/agent_prompt_answer.zig
git commit -m "feat(agent): resolve approval answers to keystrokes"
```

---

## Task 6: `terminal_answer_prompt` tool (dispatch + impl + schema)

**Files:**
- Modify: `src/ai_chat_tools.zig` — add import, dispatch branch (~after line 96), tool impl + `allocPromptOptionsHint` helper, and a tool test
- Modify: `src/ai_chat_protocol.zig` — emit the schema in `forEachToolSpec` (after the `terminal_repl_exec` emit at line 667); add a schema test

- [ ] **Step 1: Write the failing tool test**

Add to the test block in `src/ai_chat_tools.zig`:

```zig
test "terminal_answer_prompt sends the Yes digit for an approve answer" {
    const a = std.testing.allocator;
    const screen =
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 0, .settled_text = screen };
    var dummy: u8 = 0;

    const surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = @constCast("surface-claude"),
        .title = @constCast("Claude Code"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast(""),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .claude_code,
        .agent_state = .waiting_approval,
        .agent_confidence = 90,
        .ptr = @ptrCast(&host_ctx),
    };
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = ReplWaitTestHost.host(&host_ctx),
        .tool_snapshot = .{ .surfaces = surfaces, .active_tab = 0 },
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    // Free only the slice we allocated; the surface string fields are literals,
    // so do NOT call snap.deinit (it would free static memory). The tool operates
    // on a clone internally, so the literal-backed originals are never freed.
    defer if (ctx.tool_snapshot) |snap| a.free(snap.surfaces);

    const result = try terminalAnswerPromptTool(&ctx, @as(?[]const u8, "surface-claude"), "approve");
    defer a.free(result);

    try std.testing.expectEqualStrings("1", host_ctx.all_writes[0..host_ctx.all_len]);
    try std.testing.expect(std.mem.indexOf(u8, result, "Answered prompt") != null);
}

test "terminal_answer_prompt sends nothing when no prompt is awaiting" {
    const a = std.testing.allocator;
    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 0, .settled_text = "Claude Code\nthinking… (esc to interrupt)" };
    var dummy: u8 = 0;

    const surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = @constCast("surface-claude"),
        .title = @constCast("Claude Code"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast(""),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .claude_code,
        .agent_state = .running,
        .agent_confidence = 82,
        .ptr = @ptrCast(&host_ctx),
    };
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = ReplWaitTestHost.host(&host_ctx),
        .tool_snapshot = .{ .surfaces = surfaces, .active_tab = 0 },
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    // Free only the slice we allocated; the surface string fields are literals,
    // so do NOT call snap.deinit (it would free static memory). The tool operates
    // on a clone internally, so the literal-backed originals are never freed.
    defer if (ctx.tool_snapshot) |snap| a.free(snap.surfaces);

    const result = try terminalAnswerPromptTool(&ctx, @as(?[]const u8, "surface-claude"), "approve");
    defer a.free(result);

    try std.testing.expectEqual(@as(usize, 0), host_ctx.all_len);
    try std.testing.expect(std.mem.indexOf(u8, result, "awaiting an answer") != null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-full 2>&1 | grep -iA3 "terminalAnswerPromptTool"`
Expected: compile error — `terminalAnswerPromptTool` undefined.

- [ ] **Step 3: Add the import**

In `src/ai_chat_tools.zig`, after line 23 (`const agent_detector = @import("agent_detector.zig");`):
```zig
const agent_prompt_answer = @import("agent_prompt_answer.zig");
```

- [ ] **Step 4: Add the dispatch branch**

In `executeToolCall`, immediately after the `terminal_repl_exec` branch (after line 96):
```zig
    if (std.mem.eql(u8, call.name, "terminal_answer_prompt")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = jsonStringArg(args.value, "surface_id");
        const answer = jsonStringArg(args.value, "answer") orelse return ctx.allocator.dupe(u8, "Missing answer");
        return terminalAnswerPromptTool(ctx, surface_id, answer);
    }
```

- [ ] **Step 5: Implement the tool + hint helper**

Add after `terminalReplExecTool` (after line 1151) in `src/ai_chat_tools.zig`:

```zig
fn allocPromptOptionsHint(allocator: std.mem.Allocator, options: []const agent_prompt_answer.Option, screen: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Could not map that answer to an on-screen option. Options:\n");
    for (options) |o| {
        try out.print(allocator, "  {d}. {s}{s}\n", .{ o.number, o.label, if (o.highlighted) " [highlighted]" else "" });
    }
    try out.appendSlice(allocator, "Pass answer as an explicit digit (e.g. \"1\"), or approve/approve_all/reject.\nLatest snapshot:\n");
    try out.appendSlice(allocator, screen);
    return out.toOwnedSlice(allocator);
}

/// Answer a Claude Code / Codex approval menu: read the live screen, confirm a
/// prompt is awaiting input, map the semantic `answer` to a keystroke, send it,
/// and return the resulting live screen. Never sends a key it cannot justify
/// from the on-screen options.
fn terminalAnswerPromptTool(ctx: *ToolContext, surface_id: ?[]const u8, answer: []const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const intent = agent_prompt_answer.parseIntent(answer) orelse
        return std.fmt.allocPrint(ctx.allocator, "Unknown answer \"{s}\". Use approve, approve_all, reject, enter, esc, or a digit 1-9.", .{answer});
    const option_number: u8 = if (intent == .option) (agent_prompt_answer.parseOptionNumber(answer) orelse 0) else 0;

    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const sid = surface_id orelse "focused";
    const surface = resolveSurfaceId(snapshot, sid, selectedWriteContext(ctx)) orelse return allocNoSurfaceError(ctx.allocator, snapshot, sid);

    // Read the LIVE screen (per-surface, mutex-protected, worker-safe).
    const screen = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch
        return ctx.allocator.dupe(u8, "Failed to read terminal snapshot.");
    defer ctx.allocator.free(screen);

    const detection = agent_detector.detect(surface.title, screen);
    if (detection.app == .none or (detection.state != .waiting_approval and detection.state != .needs_input)) {
        const out = try std.fmt.allocPrint(
            ctx.allocator,
            "No Claude Code/Codex prompt is awaiting an answer (agent={s}:{s}). Nothing sent.\nLatest snapshot:\n{s}",
            .{ detection.app.label(), detection.state.label(), screen },
        );
        return truncateTailOwned(ctx.allocator, ctx.settings, out);
    }

    var options_buf: [12]agent_prompt_answer.Option = undefined;
    const n = agent_prompt_answer.parsePromptOptions(screen, &options_buf);
    const keystroke = agent_prompt_answer.resolveAnswer(options_buf[0..n], screen, intent, option_number) orelse {
        const out = try allocPromptOptionsHint(ctx.allocator, options_buf[0..n], screen);
        return truncateTailOwned(ctx.allocator, ctx.settings, out);
    };

    // Approval gate mirrors terminal_repl_exec: the payload is a single selector
    // key, not a destructive command, so auto runs it and confirm prompts.
    const gate = accessGate(ctx, keystroke.bytes, null);
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        if (!ctx.requestApproval("terminal_answer_prompt", answer, "Answer a Claude Code/Codex approval prompt")) {
            return deniedResult(ctx.allocator, answer, "operator rejected prompt answer");
        }
    }

    // Bind the agent write context to the resolved surface we are answering on
    // (mirrors terminal_select). This is the explicitly-targeted prompt surface,
    // so it is safe — and it avoids ensureWriteContext refusing when nothing is
    // pre-selected (e.g. a non-copilot caller).
    setWriteContext(ctx, surface.id);

    if (!host.writeSurface(host.ctx, surface.ptr, keystroke.bytes)) {
        return ctx.allocator.dupe(u8, "Failed to write to terminal surface.");
    }
    if (keystroke.confirm_enter) {
        std.Thread.sleep(CODEX_SUBMIT_DELAY_MS * std.time.ns_per_ms);
        _ = host.writeSurface(host.ctx, surface.ptr, "\r");
    }

    const deadline = std.time.milliTimestamp() + 400;
    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const latest = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch
        return std.fmt.allocPrint(ctx.allocator, "Answer sent ({s}); failed to read terminal snapshot.", .{answer});
    defer ctx.allocator.free(latest);
    const out = try std.fmt.allocPrint(ctx.allocator, "Answered prompt ({s}).\nLatest snapshot:\n{s}", .{ answer, latest });
    return truncateTailOwned(ctx.allocator, ctx.settings, out);
}
```

- [ ] **Step 6: Add the schema + schema test**

In `src/ai_chat_protocol.zig`, in `forEachToolSpec`, immediately after the `terminal_repl_exec` emit (after line 667):
```zig
    try emit(ctx, "terminal_answer_prompt", "Answer a Claude Code or Codex confirmation/approval prompt in a terminal surface. Reads the on-screen options and sends the correct keystroke. Prefer this over terminal_repl_exec to confirm or reject an agent approval menu. Only acts when a prompt is awaiting input; otherwise it reports the screen and sends nothing.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Optional surface id; defaults to the focused terminal.\"},\"answer\":{\"type\":\"string\",\"description\":\"approve (the plain Yes), approve_all (Yes + allow all / don't ask again), reject (No / cancel), enter, esc, or an explicit option digit 1-9.\"}}");
```

Add a schema test next to the existing ones (after line 1688 in `src/ai_chat_protocol.zig`):
```zig
test "terminal_answer_prompt appears in the tool schema" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, false);
    const json = out.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_answer_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "approve_all") != null);
}
```

- [ ] **Step 7: Run the full suite**

Run: `zig build test-full 2>&1 | tail -5`
Expected: build succeeds, suite passes (0 failed).

- [ ] **Step 8: Commit**

```bash
git add src/ai_chat_tools.zig src/ai_chat_protocol.zig
git commit -m "feat(agent): add terminal_answer_prompt tool for Claude Code/Codex menus"
```

---

## Task 7: Prompt guidance

**Files:**
- Modify: `src/platform/agent_prompt.zig` — add guidance lines in `common_tools_after_wsl` (after line 54); add a test

- [ ] **Step 1: Write the failing test**

Add to `src/platform/agent_prompt.zig` (after the stuck-terminal test at line 146):
```zig
test "platform agent prompt teaches answering Claude Code/Codex prompts" {
    for ([_]std.Target.Os.Tag{ .windows, .linux, .macos }) |os| {
        const p = defaultSystemPromptForOs(os);
        try std.testing.expect(std.mem.indexOf(u8, p, "terminal_answer_prompt") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "bottom") != null);
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-full 2>&1 | grep -A3 "answering Claude Code"`
Expected: FAIL — the strings are not in the prompt yet.

- [ ] **Step 3: Add the guidance lines**

In `src/platform/agent_prompt.zig`, in `common_tools_after_wsl`, immediately after the stuck-terminal line (line 54):
```zig
    \\- A terminal snapshot shows the live interactive screen at the BOTTOM; read the bottom rows for the current prompt/state, and re-read with `terminal_snapshot` if it looks stale or truncated.
    \\- To answer a Claude Code/Codex approval menu, use `terminal_answer_prompt` (answer=approve/approve_all/reject, or an option digit); never blind-press keys when you cannot see the current screen.
```

- [ ] **Step 4: Run the full suite**

Run: `zig build test-full 2>&1 | tail -5`
Expected: build succeeds, suite passes (0 failed).

- [ ] **Step 5: Commit**

```bash
git add src/platform/agent_prompt.zig
git commit -m "docs(agent): teach Copilot to read the live screen and answer prompts"
```

---

## Final verification

- [ ] Run `zig build test` — fast suite green.
- [ ] Run `zig build test-full` — full suite green (0 failed; baseline allows ~4 skipped).
- [ ] Manual GUI smoke (deferred to user; no Linux GUI backend here): with a Claude Code session that has long scrollback, `terminal_snapshot` shows the bottom prompt; "帮我点确认" triggers `terminal_answer_prompt(approve)` and the menu advances.

---

## Self-review notes (for the implementer)

- **Spec coverage:** Component 1A → Task 3; 1B → Tasks 1-2; Component 2 → Task 7; Component 3 (pure module) → Tasks 4-5, (tool) → Task 6. All covered.
- **Type consistency:** `Option`/`Intent`/`Keystroke`/`parsePromptOptions`/`resolveAnswer`/`parseIntent`/`parseOptionNumber` are defined in Task 4-5 and consumed with identical signatures in Task 6. `truncateTailOwned` defined in Task 1, consumed in Tasks 2 and 6.
- **Ownership:** `truncateTailOwned` frees its `text` arg on truncation (same contract as `truncateOwned`); every call site passes an owned slice it does not separately free.
- **No tool-count assertions** exist (schema tests are substring-based), so adding `terminal_answer_prompt` is safe.
