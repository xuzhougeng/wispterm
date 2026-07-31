# Agent `continue_later` Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-party Agent tool, `continue_later`, so the model can schedule itself to resume a long-running terminal task through the existing `/watch` scheduler.

**Architecture:** Reuse `assistant/loop/store.zig` as the only scheduler and persistence owner. Pass explicit session identity through the existing `ChatRequest` -> `ToolContext` seam so `agent_tools/schedule.zig` remains a leaf module and never imports `Session` or `AppWindow`. Advertise the tool through the existing first-party catalog and shared protocol schema.

**Tech Stack:** Zig 0.15.2, existing `assistant/loop/*` schedule engine, first-party tool catalog, `ToolContext` seam, source guards, `zig build test`, `zig build test-full`.

**Spec:** `docs/superpowers/specs/2026-07-03-agent-continue-later-tool-design.md`

---

## Global Constraints

- Do not import `AppWindow.zig` or `assistant/conversation/session.zig` from `src/agent_tools/**`; source guards enforce this.
- Do not add a new scheduler file, timer thread, or persistence file. Reuse `src/assistant/loop/store.zig` and its `loop_tasks.json`.
- Keep the new tool disableable through the existing first-party disabled-tool path.
- Keep subagents from seeing `continue_later`; it is a main-agent tool only.
- Run `zig fmt src build.zig` before each code commit.
- Because this work adds `src/agent_tools/schedule.zig`, run the Windows checkout-safety checks from `docs/development.md` before finishing.
- Ghostty comparison from the spec stands: Ghostty has no AI scheduler; do not modify terminal core, rendering, or platform host code for this feature.

## File Structure

- Modify `src/assistant/loop/store.zig` — add programmatic one-shot continuation registration on top of watch tasks.
- Modify `src/assistant/conversation/types.zig` — add `ScheduleContext` and attach it to `ToolContext`.
- Modify `src/assistant/conversation/session.zig` — capture owned scheduling identity on `ChatRequest` during request construction.
- Modify `src/assistant/conversation/request.zig` — copy scheduling identity into `ToolContext`.
- Create `src/agent_tools/schedule.zig` — parse `continue_later` args and register a continuation.
- Modify `src/agent_tools/mod.zig` — dispatch `continue_later`.
- Modify `src/tools/first_party.zig` — catalog the tool for Skill Center and disabled-tool state.
- Modify `src/assistant/conversation/protocol.zig` — advertise schema and reserve the name.
- Modify `src/platform/agent_prompt.zig` and `src/agent_tools/exec.zig` — teach the Agent to use the tool for still-running work.
- Modify `docs/ai-agent.md` — document the behavior for users and `wispterm_docs`.
- Modify `src/test_fast.zig` and `src/test_main.zig` — import the new leaf module so its tests run.

---

### Task 1: Add Scheduler Registration For One-Shot Continuations

**Files:**
- Modify: `src/assistant/loop/store.zig`

**Interface:**
- Add `pub fn registerContinuation(self: *Store, delay_ms: i64, prompt: []const u8, ctx: SessionCtx, now_ms: i64) error{OutOfMemory}!RegisterInfo`
- It creates a `.watch` task with `daily=false`, `remaining=1`, and `next_fire_ms=now_ms + delay_ms`.

- [ ] **Step 1: Write the failing test**

Add near the existing store tests:

```zig
test "registerContinuation schedules a one-shot watch task after delay" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = Store.init(a, path);
    defer store.deinit();

    const now_ms: i64 = 10_000;
    const delay_ms: i64 = 30 * std.time.ms_per_min;
    const info = try store.registerContinuation(
        delay_ms,
        "Continue the previous task. First inspect the terminal with terminal_snapshot.",
        .{ .session_id = "session-continue", .model = "deepseek", .title = "Build" },
        now_ms,
    );

    try std.testing.expectEqual(TaskKind.watch, info.kind);
    try std.testing.expect(!info.daily);
    try std.testing.expectEqual(now_ms + delay_ms, info.next_fire_ms);

    const snap = try store.snapshotForSession(a, "session-continue", .watch);
    defer freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expect(!snap[0].daily);
    try std.testing.expectEqual(@as(u32, 1), snap[0].remaining);
    try std.testing.expectEqual(now_ms + delay_ms, snap[0].next_fire_ms);
    try std.testing.expectEqualStrings("deepseek", snap[0].model);
    try std.testing.expectEqualStrings("Build", snap[0].title);
    try std.testing.expectEqualStrings(
        "Continue the previous task. First inspect the terminal with terminal_snapshot.",
        snap[0].prompt,
    );
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
zig build test 2>&1 | rg -n "registerContinuation|one-shot watch"
```

Expected: compile failure mentioning `no field or member function named 'registerContinuation'`.

- [ ] **Step 3: Implement the minimal helper**

Add after `registerWatch`:

```zig
    pub fn registerContinuation(
        self: *Store,
        delay_ms: i64,
        prompt: []const u8,
        ctx: SessionCtx,
        now_ms: i64,
    ) error{OutOfMemory}!RegisterInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        const next_fire_ms = now_ms + delay_ms;
        const id = try self.appendOwned(.{
            .kind = .watch,
            .session_id = ctx.session_id,
            .model = ctx.model,
            .title = ctx.title,
            .prompt = prompt,
            .daily = false,
            .remaining = 1,
            .next_fire_ms = next_fire_ms,
            .created_ms = now_ms,
        });
        self.saveLocked();
        return .{ .id = id, .kind = .watch, .daily = false, .next_fire_ms = next_fire_ms };
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
zig build test
```

Expected: fast suite passes.

- [ ] **Step 5: Commit**

```bash
zig fmt src/assistant/loop/store.zig
git add src/assistant/loop/store.zig
git commit -m "feat(agent): add scheduler helper for continuations"
```

---

### Task 2: Carry Scheduling Identity Through `ChatRequest` And `ToolContext`

**Files:**
- Modify: `src/assistant/conversation/types.zig`
- Modify: `src/assistant/conversation/session.zig`
- Modify: `src/assistant/conversation/request.zig`

**Interface:**
- `ToolContext` gains `schedule_context: ?ScheduleContext`.
- `ChatRequest` owns `schedule_session_id` and `schedule_title`; it reuses its owned `model`.

- [ ] **Step 1: Write the failing request-seam test**

Add to `src/assistant/conversation/request.zig` after `testSessionAndRequest`:

```zig
test "toolContextFromRequest exposes scheduling identity" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();

    env.request.schedule_session_id = try a.dupe(u8, "session-abc");
    env.request.schedule_title = try a.dupe(u8, "Long Build");

    const ctx = toolContextFromRequest(env.request);
    const schedule = ctx.schedule_context orelse return error.MissingScheduleContext;
    try std.testing.expectEqualStrings("session-abc", schedule.session_id);
    try std.testing.expectEqualStrings("model", schedule.model);
    try std.testing.expectEqualStrings("Long Build", schedule.title);
}
```

- [ ] **Step 2: Write the failing session-construction test**

Add to `src/assistant/conversation/session.zig` near the `buildRequestLocked` tests:

```zig
test "buildRequestLocked captures schedule identity for agent tools" {
    const a = std.testing.allocator;
    const session = try Session.init(a, "Long Build", "", "", "model-x", "", "", "", "", "true");
    defer session.deinit();
    session.copySessionId("session-build");

    session.mutex.lock();
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();
    defer mcp_registry.reloadCacheFromServersForTest(a, &.{});

    try std.testing.expectEqualStrings("session-build", request.schedule_session_id);
    try std.testing.expectEqualStrings("Long Build", request.schedule_title);
    try std.testing.expectEqualStrings("model-x", request.model);
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
zig build test 2>&1 | rg -n "schedule_context|schedule_session_id|ScheduleContext"
```

Expected: compile failures for missing fields/types.

- [ ] **Step 4: Add the shared type and `ToolContext` field**

In `src/assistant/conversation/types.zig`, add near `McpTool`:

```zig
pub const ScheduleContext = struct {
    session_id: []const u8,
    model: []const u8,
    title: []const u8,
};
```

Then add to `ToolContext`:

```zig
    schedule_context: ?ScheduleContext = null,
```

- [ ] **Step 5: Add owned fields to `ChatRequest`**

In `src/assistant/conversation/session.zig`, add fields to `ChatRequest`:

```zig
    schedule_session_id: []u8 = &.{},
    schedule_title: []u8 = &.{},
```

In `ChatRequest.deinit`, after freeing `disabled_first_party_tools`:

```zig
        if (self.schedule_session_id.len > 0) self.allocator.free(self.schedule_session_id);
        if (self.schedule_title.len > 0) self.allocator.free(self.schedule_title);
```

- [ ] **Step 6: Populate the fields in `buildRequestLocked`**

Before `req.* = .{`:

```zig
        const schedule_session_id = try self.allocator.dupe(u8, self.sessionId());
        var schedule_session_id_owned = true;
        errdefer if (schedule_session_id_owned) self.allocator.free(schedule_session_id);
        const schedule_title = try self.allocator.dupe(u8, self.title());
        var schedule_title_owned = true;
        errdefer if (schedule_title_owned) self.allocator.free(schedule_title);
```

Inside `req.* = .{ ... }`:

```zig
            .schedule_session_id = schedule_session_id,
            .schedule_title = schedule_title,
```

After ownership flags already set false:

```zig
        schedule_session_id_owned = false;
        schedule_title_owned = false;
```

- [ ] **Step 7: Copy the identity into `ToolContext`**

In `src/assistant/conversation/request.zig`, inside `toolContextFromRequest` return value:

```zig
        .schedule_context = if (request.schedule_session_id.len > 0) .{
            .session_id = request.schedule_session_id,
            .model = request.model,
            .title = request.schedule_title,
        } else null,
```

- [ ] **Step 8: Run tests to verify they pass**

Run:

```bash
zig build test
```

Expected: fast suite passes.

- [ ] **Step 9: Commit**

```bash
zig fmt src/assistant/conversation/types.zig src/assistant/conversation/session.zig src/assistant/conversation/request.zig
git add src/assistant/conversation/types.zig src/assistant/conversation/session.zig src/assistant/conversation/request.zig
git commit -m "feat(agent): pass schedule context to tool runtime"
```

---

### Task 3: Implement `agent_tools/schedule.zig` And Dispatch `continue_later`

**Files:**
- Create: `src/agent_tools/schedule.zig`
- Modify: `src/agent_tools/mod.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

**Interface:**
- `pub fn run(ctx: *ToolContext, arguments: []const u8) ![]u8`
- Uses active scheduler store and `ToolContext.schedule_context`.

- [ ] **Step 1: Write the failing leaf-module tests**

Create `src/agent_tools/schedule.zig` with imports and tests only:

```zig
//! Agent scheduling tools.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const ai_loop_store = @import("../assistant/loop/store.zig");

const ToolContext = types.ToolContext;

var test_dummy_ctx: u8 = 0;

fn approve(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}

fn cancelled(_: *anyopaque) bool {
    return false;
}

fn testContext(schedule: ?types.ScheduleContext) ToolContext {
    return .{
        .allocator = std.testing.allocator,
        .ctx = &test_dummy_ctx,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .schedule_context = schedule,
        .approve = approve,
        .cancelled = cancelled,
    };
}

test "continue_later rejects invalid delay before touching scheduler" {
    var ctx = testContext(.{ .session_id = "s", .model = "m", .title = "t" });
    const out = try run(&ctx, "{\"delay\":\"soon\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Bad delay. Use a positive interval like 30m, 2h, or 1d.", out);
}

test "continue_later requires schedule context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = ai_loop_store.Store.init(a, path);
    defer store.deinit();
    ai_loop_store.setActive(&store);
    defer ai_loop_store.clearActive();

    var ctx = testContext(null);
    const out = try run(&ctx, "{\"delay\":\"30m\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings("Scheduler context is not available.", out);
}

test "continue_later registers a one-shot watch task" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = ai_loop_store.Store.init(a, path);
    defer store.deinit();
    ai_loop_store.setActive(&store);
    defer ai_loop_store.clearActive();

    var ctx = testContext(.{ .session_id = "session-tool", .model = "m", .title = "Tool Session" });
    const out = try run(&ctx, "{\"delay\":\"30m\",\"message\":\"check progress\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Scheduled continuation #") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "in 30m") != null);

    const snap = try store.snapshotForSession(a, "session-tool", .watch);
    defer ai_loop_store.freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("check progress", snap[0].prompt);
}
```

- [ ] **Step 2: Register the new module in test aggregators**

Add `_ = @import("agent_tools/schedule.zig");` next to the other `agent_tools` imports in both:

```zig
// src/test_fast.zig
_ = @import("agent_tools/schedule.zig");

// src/test_main.zig
_ = @import("agent_tools/schedule.zig");
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
zig build test 2>&1 | rg -n "run\\(|continue_later|schedule.zig"
```

Expected: compile failure because `run` is undefined.

- [ ] **Step 4: Implement the leaf module**

Replace the top of `src/agent_tools/schedule.zig` with the implementation, keeping the tests:

```zig
//! Agent scheduling tools.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const tool_args = @import("args.zig");
const ai_loop_schedule = @import("../assistant/loop/schedule.zig");
const ai_loop_store = @import("../assistant/loop/store.zig");

const ToolContext = types.ToolContext;

const DEFAULT_CONTINUATION_MESSAGE =
    "Continue the previous task. First inspect the terminal with terminal_snapshot, then report progress.";

pub fn run(ctx: *ToolContext, arguments: []const u8) ![]u8 {
    const parsed = tool_args.parse(ctx.allocator, arguments) orelse
        return ctx.allocator.dupe(u8, "Invalid tool arguments");
    defer parsed.deinit();

    const delay_text = tool_args.string(parsed.value, "delay") orelse
        return ctx.allocator.dupe(u8, "Bad delay. Use a positive interval like 30m, 2h, or 1d.");
    const delay_ms = ai_loop_schedule.parseIntervalMs(delay_text) catch
        return ctx.allocator.dupe(u8, "Bad delay. Use a positive interval like 30m, 2h, or 1d.");

    const store = ai_loop_store.active() orelse
        return ctx.allocator.dupe(u8, "Scheduler is not available.");
    const schedule = ctx.schedule_context orelse
        return ctx.allocator.dupe(u8, "Scheduler context is not available.");
    const message = tool_args.string(parsed.value, "message") orelse DEFAULT_CONTINUATION_MESSAGE;

    const info = try store.registerContinuation(
        delay_ms,
        message,
        .{ .session_id = schedule.session_id, .model = schedule.model, .title = schedule.title },
        std.time.milliTimestamp(),
    );
    const display = ai_loop_schedule.formatInterval(delay_ms);
    return std.fmt.allocPrint(ctx.allocator, "Scheduled continuation #{d} in {d}{c}.", .{
        info.id,
        display.value,
        display.unit,
    });
}
```

Keep the test helpers below the implementation.

- [ ] **Step 5: Dispatch from `agent_tools/mod.zig`**

Add import:

```zig
const agent_schedule = @import("schedule.zig");
```

Add a dispatch branch after `ask_user` or before session/file tools:

```zig
    if (std.mem.eql(u8, call.name, "continue_later")) {
        return agent_schedule.run(ctx, call.arguments);
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
zig build test
```

Expected: fast suite passes.

- [ ] **Step 7: Commit**

```bash
zig fmt src/agent_tools/schedule.zig src/agent_tools/mod.zig src/test_fast.zig src/test_main.zig
git add src/agent_tools/schedule.zig src/agent_tools/mod.zig src/test_fast.zig src/test_main.zig
git commit -m "feat(agent): add continue_later tool runtime"
```

---

### Task 4: Advertise And Reserve The First-Party Tool

**Files:**
- Modify: `src/tools/first_party.zig`
- Modify: `src/assistant/conversation/protocol.zig`

- [ ] **Step 1: Add failing first-party catalog test**

In `src/tools/first_party.zig`, extend `test "first_party_tools: active definitions include webread and the local command tool"`:

```zig
    try std.testing.expect(catalogContains(defs, "continue_later"));
```

- [ ] **Step 2: Add failing protocol schema tests**

In `src/assistant/conversation/protocol.zig`, add near the other tool schema tests:

```zig
test "continue_later appears in the full tool schema" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = false });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"continue_later\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"delay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"message\"") != null);
}
```

Also update the `denied` list in `test "subagent toolset restricts tool schemas to research tools"`:

```zig
        "continue_later",
```

And update `builtinToolNameReserved` coverage by adding to an existing reserved-name test if present, or add:

```zig
test "continue_later is a reserved builtin tool name" {
    try std.testing.expect(builtinToolNameReserved("continue_later"));
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
zig build test 2>&1 | rg -n "continue_later|reserved builtin"
```

Expected: failures because the catalog/schema/name reservation do not include the tool.

- [ ] **Step 4: Add the first-party catalog entry**

In `static_definitions`, add after `ask_user`:

```zig
    .{ .name = "continue_later", .label = "continue_later", .description = "Schedule this Agent session to continue a long-running task later.", .category = .agent },
```

- [ ] **Step 5: Reserve and emit the protocol schema**

In `builtinToolNameReserved`, add:

```zig
        "continue_later",
```

In `forEachToolSpec`, add after `ask_user`:

```zig
    try Filtered.emitTool(ctx, opts, "continue_later", "Schedule this same Agent or Copilot session to continue later. Use when a terminal command, SSH command, Codex/Claude Code run, or REPL task is still running and immediate polling would waste tokens or risk duplicate side effects. At wake time WispTerm submits message back into this session; the message should inspect progress with terminal_snapshot before acting.", "{\"delay\":{\"type\":\"string\",\"description\":\"Required positive interval: integer plus s, m, h, or d, e.g. 30m, 2h, 1d.\"},\"message\":{\"type\":\"string\",\"description\":\"Optional follow-up prompt. Defaults to continuing the previous task and checking terminal_snapshot first.\"}}");
```

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
zig build test
```

Expected: fast suite passes.

- [ ] **Step 7: Commit**

```bash
zig fmt src/tools/first_party.zig src/assistant/conversation/protocol.zig
git add src/tools/first_party.zig src/assistant/conversation/protocol.zig
git commit -m "feat(agent): advertise continue_later tool"
```

---

### Task 5: Teach The Agent When To Use `continue_later`

**Files:**
- Modify: `src/platform/agent_prompt.zig`
- Modify: `src/agent_tools/exec.zig`
- Modify: `docs/ai-agent.md`

- [ ] **Step 1: Write failing prompt guidance test**

In `src/platform/agent_prompt.zig`, add:

```zig
test "platform agent prompt teaches continue_later for long-running work" {
    for ([_]std.Target.Os.Tag{ .windows, .linux, .macos }) |os| {
        const p = defaultSystemPromptForOs(os);
        try std.testing.expect(std.mem.indexOf(u8, p, "continue_later") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "terminal_snapshot") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "Do not re-run") != null);
    }
}
```

- [ ] **Step 2: Write failing exec-message test**

In `src/agent_tools/exec.zig`, extend `test "agent exec timeout message says still running, do not re-issue"`:

```zig
    try std.testing.expect(std.mem.indexOf(u8, msg, "continue_later") != null);
```

Add a focused test for the busy-guard message:

```zig
test "agent exec busy guard message points at continue_later" {
    const allocator = std.testing.allocator;
    const msg = try allocStillRunningBusyGuard(allocator, "SSH");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "previous command is still running") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "continue_later") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "terminal_snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "code=<ctrl-c>") != null);
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
zig build test 2>&1 | rg -n "continue_later|agent prompt|timeout message"
```

Expected: tests fail because prompt/messages do not mention `continue_later`.

- [ ] **Step 4: Update the default Agent prompt**

In `common_tools_after_wsl`, replace the slow-command line:

```zig
    \\- A slow session/exec command is usually still running; wait, then re-check with `terminal_snapshot`.
```

with:

```zig
    \\- A slow session/exec command is usually still running. Do not re-run it. If waiting is better than immediate polling, call `continue_later` with a delay such as 30m and a message that checks `terminal_snapshot` first.
```

- [ ] **Step 5: Update still-running tool messages**

In `src/agent_tools/exec.zig`, add this helper near `allocStillRunningTimeout`:

```zig
fn allocStillRunningBusyGuard(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "A previous command is still running in this {s} terminal. Do not start another command. Use continue_later to re-check with terminal_snapshot after a sensible delay, or interrupt it first with terminal_repl_exec repl=plain code=<ctrl-c>.", .{label});
}
```

Replace the busy guard result with:

```zig
            return allocStillRunningBusyGuard(ctx.allocator, kind.label());
```

Replace `allocStillRunningTimeout` body with:

```zig
fn allocStillRunningTimeout(allocator: std.mem.Allocator, label: []const u8, elapsed_s: i64, snapshot: ?[]const u8) ![]u8 {
    if (snapshot) |text| {
        return std.fmt.allocPrint(allocator, "The {s} command has not returned after {d}s; it is most likely still running. Do NOT re-issue it. Use continue_later to re-check with terminal_snapshot after a sensible delay, or interrupt with terminal_repl_exec repl=plain code=<ctrl-c>.\nLatest snapshot:\n{s}", .{ label, elapsed_s, text });
    }
    return std.fmt.allocPrint(allocator, "The {s} command has not returned after {d}s; it is most likely still running. Do NOT re-issue it. Use continue_later to re-check with terminal_snapshot after a sensible delay, or interrupt with terminal_repl_exec repl=plain code=<ctrl-c>.", .{ label, elapsed_s });
}
```

- [ ] **Step 6: Update user docs**

In `docs/ai-agent.md`, after the `/watch` bullet block, add:

```markdown
- The Agent can also call `continue_later` when a terminal, SSH, Codex, Claude
  Code, or REPL task is still running. It schedules a one-shot continuation
  through the same `/watch` store, then resumes this session later and checks
  progress with `terminal_snapshot` before acting.
```

- [ ] **Step 7: Run tests to verify they pass**

Run:

```bash
zig build test
```

Expected: fast suite passes.

- [ ] **Step 8: Commit**

```bash
zig fmt src/platform/agent_prompt.zig src/agent_tools/exec.zig
git add src/platform/agent_prompt.zig src/agent_tools/exec.zig docs/ai-agent.md
git commit -m "docs(agent): teach continue_later for long-running tasks"
```

---

### Task 6: Final Verification

**Files:**
- No code changes unless verification finds a bug.

- [ ] **Step 1: Run formatting**

Run:

```bash
zig fmt src build.zig
```

Expected: no output and exit code 0.

- [ ] **Step 2: Run fast tests**

Run:

```bash
zig build test
```

Expected: pass.

- [ ] **Step 3: Run full pre-merge tests**

Run:

```bash
zig build test-full
```

Expected: pass. If this is too slow for the current machine, run it anyway before final handoff unless the user explicitly agrees to defer it.

- [ ] **Step 4: Run Windows checkout-safety checks**

If running in PowerShell, use the exact commands from `docs/development.md#Windows Checkout Safety`. Minimum required output:

```text
windows_name_violations=0
casefold_collisions=0
```

Also run:

```powershell
git ls-files -s | Select-String '^120000'
```

Expected: no output.

If PowerShell is unavailable in the current environment, report that the checkout-safety PowerShell check was not run and list the added paths:

```text
src/agent_tools/schedule.zig
docs/superpowers/plans/2026-07-03-agent-continue-later-tool.md
```

- [ ] **Step 5: Inspect source-guard-sensitive imports**

Run:

```bash
rg -n "AppWindow.zig|assistant/conversation/session.zig" src/agent_tools
```

Expected: no matches.

- [ ] **Step 6: Inspect final diff**

Run:

```bash
git status --short
git diff --stat HEAD
```

Expected: only intended implementation files are changed; unrelated `.claude/` remains untouched if still untracked.

- [ ] **Step 7: Final commit if verification changed files**

If Task 6 produced fixes:

```bash
git add <fixed-files>
git commit -m "fix(agent): finalize continue_later verification"
```

Expected: working tree has only unrelated user-owned files left.
