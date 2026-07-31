# cli_agent 工具实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增第一方工具 `cli_agent`：把自包含任务委派给外部 CLI agent（首个后端 codex），流式进度进聊天卡片，返回最终答复。

**Architecture:** 新叶子模块 `src/agent_tools/cli_agent.zig` 持有 Backend 数据表（key/exe/base_args/parseEvent）和共享 `run()`（审批→spawn→行流式→25ms 轮询→超时/取消→结果格式化）。`ToolContext` 增加 `progress` 钩子接到 `appendProgressMessage`。注册走现有四件套（protocol.zig schema+reserved、first_party.zig、mod.zig 分发）。

**Tech Stack:** Zig（std.process.Child、std.Thread、std.json），无新依赖。

Spec: `docs/superpowers/specs/2026-07-10-cli-agent-tool-design.md`

## Global Constraints

- 分支 `feat/cli-agent-tool`（已存在，spec 已提交）。
- `agent_tools/**` 是叶子模块：**禁止** import `AppWindow.zig`（source guard 强制）；cli_agent.zig 只 import `../assistant/conversation/types.zig`、`../platform/process.zig`、`exec.zig`、`output.zig`。
- 每次提交前必跑 `zig fmt build.zig src`（CI 有 fmt gate，本地 test 不含）。
- 快测命令：`zig build test -Dtarget=aarch64-macos`（agent_tools/types 的测试在这里跑）。protocol.zig 的测试只在 `zig build test-full -Dtarget=aarch64-macos` 运行（约 2300 个用例，已知 flaky："skill center tool import" FileNotFound 与本改动无关）。
- 用 `/bin/sh` 的测试须以 `if (builtin.os.tag == .windows) return error.SkipZigTest;` 开头（跟 mod.zig 现有 MCP dispatch 测试同模式）。
- 工具名固定 `cli_agent`；codex 命令行固定为 `codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -- <task>`。
- 超时常量：`DEFAULT_TIMEOUT_MS = 600_000`，`MAX_TIMEOUT_MS = 3_600_000`。

---

### Task 1: ToolContext 增加 progress 钩子并在 request.zig 接线

**Files:**
- Modify: `src/assistant/conversation/types.zig`（ToolContext，约 354-402 行）
- Modify: `src/assistant/conversation/request.zig`（toolNote 附近约 865 行；toolContextFromRequest 约 915 行）

**Interfaces:**
- Produces: `ToolContext.progress: *const fn (ctx: *anyopaque, text: []const u8) void = noopProgress` 字段；`ToolContext.emitProgress(text: []const u8) void` 方法。Task 3 的 `run()` 调 `ctx.emitProgress(...)`，测试用自定义 hook 捕获。

- [ ] **Step 1: types.zig 加默认 no-op 与字段**

在 `fn noopNote` 旁（约 348 行）加：

```zig
fn noopProgress(_: *anyopaque, _: []const u8) void {}
```

在 ToolContext 的 `note` 字段之后加字段：

```zig
    /// Post an ephemeral progress line to the chat card while a tool runs
    /// (persist_to_history=false; never enters LLM context). Defaults to a
    /// no-op so test contexts need not wire it.
    progress: *const fn (ctx: *anyopaque, text: []const u8) void = noopProgress,
```

在 `emitNote` 方法之后加方法：

```zig
    pub fn emitProgress(self: *const ToolContext, text: []const u8) void {
        self.progress(self.ctx, text);
    }
```

- [ ] **Step 2: request.zig 接线**

在 `toolNote`（865 行）之后加：

```zig
fn toolProgress(ctx: *anyopaque, text: []const u8) void {
    const session: *Session = @ptrCast(@alignCast(ctx));
    ai_chat.appendProgressMessage(session, text) catch {};
}
```

`toolContextFromRequest` 返回值里 `.note = toolNote,` 之后加一行：

```zig
        .progress = toolProgress,
```

- [ ] **Step 3: 验证编译与既有测试**

Run: `zig fmt build.zig src && zig build test -Dtarget=aarch64-macos`
Expected: 全部通过（字段带默认值，既有 ToolContext 构造点不需要改）。

- [ ] **Step 4: Commit**

```bash
git add src/assistant/conversation/types.zig src/assistant/conversation/request.zig
git commit -m "Add ToolContext progress hook wired to appendProgressMessage"
```

---

### Task 2: cli_agent.zig 骨架 —— Backend 表、find、codex 事件解析器

**Files:**
- Create: `src/agent_tools/cli_agent.zig`
- Modify: `src/test_fast.zig`（约 307-323 行 agent_tools 段）

**Interfaces:**
- Consumes: 无（纯数据+解析，本 task 不用 Task 1 的钩子）。
- Produces（Task 3/4 依赖，签名精确）：
  - `pub const Event = struct { progress: ?[]u8 = null, final: ?[]u8 = null };`（字段为 owned 内存）
  - `pub const Backend = struct { key, display, exe: []const u8, base_args: []const []const u8, parseEvent: *const fn (std.mem.Allocator, []const u8) ?Event };`
  - `pub const backends: [1]Backend`、`pub fn find(key: []const u8) ?*const Backend`
  - `pub const available_keys: []const u8`（comptime 拼出 `"codex"`）
  - `pub const DEFAULT_TIMEOUT_MS: u32 = 600_000;`、`pub const MAX_TIMEOUT_MS: u32 = 3_600_000;`
  - 私有 `codexParseEvent`（经 backend.parseEvent 间接测试与调用）

- [ ] **Step 1: 写失败测试（文件同时含最小声明骨架才能编译，Zig 测试与实现同文件；先写测试段）**

创建 `src/agent_tools/cli_agent.zig`，先只写测试将引用的最小骨架 + 完整测试（TDD 红：先让 `codexParseEvent` 恒 return null、`find` 恒 return null，跑测试确认失败）：

```zig
//! Unified CLI agent delegation tool (`cli_agent`): hand one self-contained
//! task to an external CLI agent (first backend: Codex), stream its progress
//! into the chat card, and return its final report. Leaf module — depends on
//! ai_chat_types, platform process helpers, and sibling exec/output adapters;
//! never on session.zig or AppWindow.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../assistant/conversation/types.zig");

const ToolContext = types.ToolContext;

pub const DEFAULT_TIMEOUT_MS: u32 = 600_000;
pub const MAX_TIMEOUT_MS: u32 = 3_600_000;

/// One parsed stdout line from a backend. Set fields are owned by the
/// caller-provided allocator; the caller frees them.
pub const Event = struct {
    progress: ?[]u8 = null,
    final: ?[]u8 = null,
};

pub const Backend = struct {
    key: []const u8, // value of the tool's `agent` argument
    display: []const u8,
    exe: []const u8, // executable name resolved via PATH
    base_args: []const []const u8, // fixed args between exe and task
    parseEvent: *const fn (allocator: std.mem.Allocator, line: []const u8) ?Event,
};

const codex_backend = Backend{
    .key = "codex",
    .display = "Codex",
    .exe = "codex",
    .base_args = &.{ "exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "--" },
    .parseEvent = codexParseEvent,
};

pub const backends = [_]Backend{codex_backend};

/// Comma-joined backend keys for error messages and docs; stays correct as
/// the table grows.
pub const available_keys = blk: {
    var s: []const u8 = "";
    for (backends, 0..) |b, i| s = s ++ (if (i == 0) "" else ", ") ++ b.key;
    break :blk s;
};

pub fn find(key: []const u8) ?*const Backend {
    _ = key;
    return null; // TDD: red
}

fn codexParseEvent(allocator: std.mem.Allocator, line: []const u8) ?Event {
    _ = allocator;
    _ = line;
    return null; // TDD: red
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "find resolves codex and rejects unknown keys" {
    const backend = find("codex") orelse return error.TestExpectedBackend;
    try std.testing.expectEqualStrings("codex", backend.exe);
    try std.testing.expect(find("oh-my-pi") == null);
    try std.testing.expectEqualStrings("codex", available_keys);
}

test "codexParseEvent extracts progress from item.started command_execution" {
    const a = std.testing.allocator;
    const line = "{\"type\":\"item.started\",\"item\":{\"id\":\"item_1\",\"item_type\":\"command_execution\",\"command\":\"bash -lc 'ls'\",\"status\":\"in_progress\"}}";
    const event = codexParseEvent(a, line) orelse return error.TestExpectedEvent;
    defer if (event.progress) |p| a.free(p);
    defer if (event.final) |f| a.free(f);
    try std.testing.expect(event.final == null);
    try std.testing.expectEqualStrings("codex: $ bash -lc 'ls'", event.progress.?);
}

test "codexParseEvent extracts final from item.completed agent_message" {
    const a = std.testing.allocator;
    const line = "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_9\",\"item_type\":\"agent_message\",\"text\":\"All tests pass.\"}}";
    const event = codexParseEvent(a, line) orelse return error.TestExpectedEvent;
    defer if (event.progress) |p| a.free(p);
    defer if (event.final) |f| a.free(f);
    try std.testing.expect(event.progress == null);
    try std.testing.expectEqualStrings("All tests pass.", event.final.?);
}

test "codexParseEvent ignores unknown events, other item phases, and non-JSON lines" {
    const a = std.testing.allocator;
    try std.testing.expect(codexParseEvent(a, "[2026-07-10] plain human output") == null);
    try std.testing.expect(codexParseEvent(a, "") == null);
    try std.testing.expect(codexParseEvent(a, "{not json") == null);
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"thread.started\",\"thread_id\":\"t1\"}") == null);
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"reasoning\",\"text\":\"hmm\"}}") == null);
    // command_execution progress only fires on item.started, not completed (no dupes)
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"command_execution\",\"command\":\"ls\",\"status\":\"completed\"}}") == null);
    // agent_message only counts when completed
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"item.started\",\"item\":{\"item_type\":\"agent_message\",\"text\":\"partial\"}}") == null);
}
```

同时在 `src/test_fast.zig` 的 `_ = @import("agent_tools/args.zig");` 之后加一行：

```zig
    _ = @import("agent_tools/cli_agent.zig");
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtarget=aarch64-macos 2>&1 | grep -A2 "cli_agent\|codexParse\|find resolves"`
Expected: FAIL（`TestExpectedBackend` / `TestExpectedEvent`）。

- [ ] **Step 3: 写最小实现**

替换两个 red 桩：

```zig
pub fn find(key: []const u8) ?*const Backend {
    for (&backends) |*backend| {
        if (std.mem.eql(u8, backend.key, key)) return backend;
    }
    return null;
}

fn objectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Parse one line of `codex exec --json` output. Tolerant by design: any
/// line that is not JSON or not a recognized event returns null; when no
/// agent_message is ever seen, run() falls back to the raw stdout tail, so
/// codex JSON-format drift degrades gracefully instead of failing.
fn codexParseEvent(allocator: std.mem.Allocator, line: []const u8) ?Event {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const event_type = objectString(parsed.value, "type") orelse return null;
    const item = parsed.value.object.get("item") orelse return null;
    const item_type = objectString(item, "item_type") orelse return null;
    if (std.mem.eql(u8, event_type, "item.completed") and std.mem.eql(u8, item_type, "agent_message")) {
        const text = objectString(item, "text") orelse return null;
        const owned = allocator.dupe(u8, text) catch return null;
        return .{ .final = owned };
    }
    if (std.mem.eql(u8, event_type, "item.started") and std.mem.eql(u8, item_type, "command_execution")) {
        const command = objectString(item, "command") orelse return null;
        const owned = std.fmt.allocPrint(allocator, "codex: $ {s}", .{command}) catch return null;
        return .{ .progress = owned };
    }
    return null;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig fmt build.zig src && zig build test -Dtarget=aarch64-macos`
Expected: PASS（含全部既有测试）。

- [ ] **Step 5: Commit**

```bash
git add src/agent_tools/cli_agent.zig src/test_fast.zig
git commit -m "Add cli_agent backend table and codex JSONL event parser"
```

---

### Task 3: cli_agent.run() —— spawn、行流式、轮询、结果格式化

**Files:**
- Modify: `src/agent_tools/cli_agent.zig`

**Interfaces:**
- Consumes: Task 1 的 `ctx.emitProgress(text)`；Task 2 的 `Backend`/`Event`；`agent_exec.CaptureOutput` + `agent_exec.captureOutputThread`（exec.zig 已 pub）；`platform_process.childExited(id, timeout_ms)`；`tool_output.deniedResult` / `tool_output.truncateOwned`。
- Produces（Task 4 依赖）：`pub fn run(ctx: *ToolContext, backend: *const Backend, task: []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8`

- [ ] **Step 1: 写失败测试**

在 cli_agent.zig 测试段追加（fake hooks 跟 mod.zig 同模式）：

```zig
fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}
fn fakeDeny(ctx: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    const called: *bool = @ptrCast(@alignCast(ctx));
    called.* = true;
    return false;
}
fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

const ProgressCapture = struct {
    count: usize = 0,
    last: [256]u8 = undefined,
    last_len: usize = 0,

    fn hook(ctx: *anyopaque, text: []const u8) void {
        const self: *ProgressCapture = @ptrCast(@alignCast(ctx));
        self.count += 1;
        const n = @min(text.len, self.last.len);
        @memcpy(self.last[0..n], text[0..n]);
        self.last_len = n;
    }
};

test "run streams progress and returns the final agent message" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const script =
        "printf '%s\\n' " ++
        "'{\"type\":\"item.started\",\"item\":{\"item_type\":\"command_execution\",\"command\":\"ls\"}}' " ++
        "'{\"type\":\"item.completed\",\"item\":{\"item_type\":\"agent_message\",\"text\":\"first\"}}' " ++
        "'{\"type\":\"item.completed\",\"item\":{\"item_type\":\"agent_message\",\"text\":\"all done\"}}'";
    const args = [_][]const u8{ "-c", script };
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "/bin/sh",
        .base_args = args[0..],
        .parseEvent = codexParseEvent,
    };
    var progress = ProgressCapture{};
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &progress,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
        .progress = ProgressCapture.hook,
    };
    const out = try run(&ctx, &fake, "do the thing", null, 30_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "agent=fake") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exit_code=0") != null);
    // last agent_message wins
    try std.testing.expect(std.mem.indexOf(u8, out, "all done") != null);
    try std.testing.expectEqual(@as(usize, 1), progress.count);
    try std.testing.expectEqualStrings("codex: $ ls", progress.last[0..progress.last_len]);
}

test "run falls back to the raw stdout tail when no final message parses" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const args = [_][]const u8{ "-c", "printf '%s\\n' 'plain line one' 'plain line two'" };
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "/bin/sh",
        .base_args = args[0..],
        .parseEvent = codexParseEvent,
    };
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try run(&ctx, &fake, "task", null, 30_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No final message parsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "plain line two") != null);
}

test "run requires approval outside full permission and reports denial" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const args = [_][]const u8{ "-c", "true" };
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "/bin/sh",
        .base_args = args[0..],
        .parseEvent = codexParseEvent,
    };
    var approve_called = false;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &approve_called,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .auto },
        .approve = fakeDeny,
        .cancelled = fakeCancelled,
    };
    const out = try run(&ctx, &fake, "risky task", null, 30_000);
    defer a.free(out);
    try std.testing.expect(approve_called);
    try std.testing.expect(std.mem.indexOf(u8, out, "DENIED") != null);
}

test "run reports a missing executable clearly" {
    const a = std.testing.allocator;
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "definitely-missing-cli-agent-binary",
        .base_args = &.{},
        .parseEvent = codexParseEvent,
    };
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try run(&ctx, &fake, "task", null, 30_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "not found or failed to start") != null);
}

test "run kills the child on timeout and marks the result" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const args = [_][]const u8{ "-c", "sleep 30" };
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "/bin/sh",
        .base_args = args[0..],
        .parseEvent = codexParseEvent,
    };
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try run(&ctx, &fake, "task", null, 100);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "timed_out=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exit_code=124") != null);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtarget=aarch64-macos 2>&1 | tail -20`
Expected: 编译错误 `run` 未定义（红）。

- [ ] **Step 3: 实现 LineStream 与 run()**

在 cli_agent.zig 顶部补 import：

```zig
const platform_process = @import("../platform/process.zig");
const agent_exec = @import("exec.zig");
const tool_output = @import("output.zig");
```

实现段（放在 find 之后、Tests 注释之前）：

```zig
// ---------------------------------------------------------------------------
// Line-streaming child runner
// ---------------------------------------------------------------------------

/// Reader-thread line collector. The thread only does I/O and line splitting;
/// parsed events and all session calls stay on the tool worker thread
/// (markUiDirty is threadlocal — cross-thread UI calls are a known trap).
const LineStream = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    mutex: std.Thread.Mutex = .{},
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    partial: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *LineStream) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.partial.deinit(self.allocator);
    }

    fn readThread(self: *LineStream) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.file.read(&buf) catch break;
            if (n == 0) break;
            self.push(buf[0..n]);
        }
        self.flushPartial();
    }

    // ponytail: `partial` is unbounded for a single line with no newline;
    // codex event lines are bounded in practice — cap it if a backend ever
    // streams raw unbounded output.
    fn push(self: *LineStream, chunk: []const u8) void {
        var rest = chunk;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const line = std.mem.concat(self.allocator, u8, &.{ self.partial.items, rest[0..nl] }) catch return;
            self.partial.clearRetainingCapacity();
            self.appendLine(line);
            rest = rest[nl + 1 ..];
        }
        self.partial.appendSlice(self.allocator, rest) catch {};
    }

    fn flushPartial(self: *LineStream) void {
        if (self.partial.items.len == 0) return;
        const line = self.allocator.dupe(u8, self.partial.items) catch return;
        self.partial.clearRetainingCapacity();
        self.appendLine(line);
    }

    fn appendLine(self: *LineStream, line: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.lines.append(self.allocator, line) catch self.allocator.free(line);
    }

    /// Move all pending lines to `out`; caller owns and frees each line.
    fn drain(self: *LineStream, out: *std.ArrayListUnmanaged([]u8)) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        out.appendSlice(self.allocator, self.lines.items) catch return;
        self.lines.clearRetainingCapacity();
    }
};

/// Keep a bounded raw-stdout tail for the no-final-message fallback (the
/// useful part of a stream is at the end).
fn appendTail(allocator: std.mem.Allocator, tail: *std.ArrayListUnmanaged(u8), line: []const u8, limit: u32) void {
    tail.appendSlice(allocator, line) catch return;
    tail.append(allocator, '\n') catch return;
    const max: usize = @max(@as(usize, limit), 1);
    if (tail.items.len > 2 * max) {
        // no overlap: only triggered when len > 2*max
        std.mem.copyForwards(u8, tail.items[0..max], tail.items[tail.items.len - max ..]);
        tail.shrinkRetainingCapacity(max);
    }
}

fn drainAndParse(ctx: *ToolContext, backend: *const Backend, stream: *LineStream, final_message: *?[]u8, tail: *std.ArrayListUnmanaged(u8)) void {
    const allocator = ctx.allocator;
    var drained: std.ArrayListUnmanaged([]u8) = .empty;
    defer drained.deinit(allocator);
    stream.drain(&drained);
    for (drained.items) |line| {
        defer allocator.free(line);
        appendTail(allocator, tail, line, ctx.settings.output_limit);
        const event = backend.parseEvent(allocator, line) orelse continue;
        if (event.progress) |p| {
            defer allocator.free(p);
            ctx.emitProgress(p);
        }
        if (event.final) |f| {
            if (final_message.*) |old| allocator.free(old);
            final_message.* = f;
        }
    }
}

pub fn run(ctx: *ToolContext, backend: *const Backend, task: []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8 {
    const allocator = ctx.allocator;
    if (ctx.isCancelled()) return allocator.dupe(u8, "Canceled.");
    const trimmed_task = std.mem.trim(u8, task, " \t\r\n");
    if (trimmed_task.len == 0) return allocator.dupe(u8, "Missing task");

    // The backend runs with full access and cannot prompt mid-run, so both
    // confirm AND auto permission modes gate the whole delegation up front.
    if (ctx.settings.permission != .full) {
        const reason = try std.fmt.allocPrint(allocator, "Delegate task to {s} with full access", .{backend.display});
        defer allocator.free(reason);
        if (!ctx.requestApproval("cli_agent", trimmed_task, reason)) {
            return tool_output.deniedResult(allocator, trimmed_task, "cli_agent delegation not approved");
        }
    }

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, backend.exe);
    try argv.appendSlice(allocator, backend.base_args);
    try argv.append(allocator, trimmed_task);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd orelse ctx.settings.working_dir;
    child.create_no_window = true;
    child.spawn() catch |err| {
        return std.fmt.allocPrint(allocator, "{s} CLI ({s}) not found or failed to start: {}", .{ backend.display, backend.exe, err });
    };

    var stream = LineStream{ .allocator = allocator, .file = child.stdout.? };
    defer stream.deinit();
    var stderr_capture = agent_exec.CaptureOutput{
        .allocator = allocator,
        .file = child.stderr.?,
        .max_bytes = ctx.settings.output_limit,
    };
    defer allocator.free(stderr_capture.data);

    const stdout_thread = try std.Thread.spawn(.{}, LineStream.readThread, .{&stream});
    const stderr_thread = try std.Thread.spawn(.{}, agent_exec.captureOutputThread, .{&stderr_capture});

    var final_message: ?[]u8 = null;
    defer if (final_message) |f| allocator.free(f);
    var tail: std.ArrayListUnmanaged(u8) = .empty;
    defer tail.deinit(allocator);

    const wait_ms = @max(@min(timeout_ms, MAX_TIMEOUT_MS), 1);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(wait_ms));
    var timed_out = false;
    var canceled = false;
    while (true) {
        drainAndParse(ctx, backend, &stream, &final_message, &tail);
        switch (platform_process.childExited(child.id, 25)) {
            .running => {},
            .exited => |code| {
                // Same trap as exec.runArgv: on POSIX childExited() already
                // reaped the zombie; pre-set term so child.wait() skips its
                // second waitpid (ECHILD aborts). Windows keeps the handle.
                if (builtin.os.tag != .windows) child.term = .{ .Exited = @intCast(code) };
                break;
            },
            .gone => {
                if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
                break;
            },
        }
        if (ctx.isCancelled()) {
            canceled = true;
            _ = child.kill() catch {};
            break;
        }
        if (std.time.milliTimestamp() >= deadline) {
            timed_out = true;
            _ = child.kill() catch {};
            break;
        }
    }

    stdout_thread.join();
    stderr_thread.join();
    // Lines that arrived between the last in-loop drain and thread exit.
    drainAndParse(ctx, backend, &stream, &final_message, &tail);

    const exit_code: i32 = if (timed_out or canceled) 124 else blk: {
        const term = try child.wait();
        break :blk switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| -@as(i32, @intCast(sig)),
            .Stopped => |sig| -@as(i32, @intCast(sig)),
            .Unknown => |code| @intCast(code),
        };
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (timed_out) try out.appendSlice(allocator, "timed_out=true\n");
    if (canceled) try out.appendSlice(allocator, "canceled=true\n");
    try out.print(allocator, "agent={s} exit_code={d}\n", .{ backend.key, exit_code });
    if (final_message) |f| {
        try out.appendSlice(allocator, f);
    } else {
        try out.appendSlice(allocator, "No final message parsed; raw output tail:\n");
        try out.appendSlice(allocator, tail.items);
    }
    if (exit_code != 0 and stderr_capture.data.len > 0) {
        try out.print(allocator, "\nstderr:\n{s}", .{stderr_capture.data});
    }
    return tool_output.truncateOwned(allocator, ctx.settings, try out.toOwnedSlice(allocator));
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig fmt build.zig src && zig build test -Dtarget=aarch64-macos`
Expected: PASS（timeout 测试约 100ms，整体不明显变慢）。

- [ ] **Step 5: Commit**

```bash
git add src/agent_tools/cli_agent.zig
git commit -m "Implement cli_agent run(): spawn, line streaming, progress, timeout"
```

---

### Task 4: mod.zig 分发

**Files:**
- Modify: `src/agent_tools/mod.zig`（import 段约 32 行；dispatch 链 `memory_search` 块之后、`agent_dynamic.find` 之前，约 296 行）

**Interfaces:**
- Consumes: Task 2/3 的 `find`、`run`、`DEFAULT_TIMEOUT_MS`、`available_keys`。
- Produces: 工具名 `"cli_agent"` 经 `executeToolCall` 可达（Task 5 的 schema 对应此名）。

- [ ] **Step 1: 写失败测试**

mod.zig 测试段追加：

```zig
test "executeToolCall cli_agent validates agent and task arguments" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const missing_agent = try executeToolCall(&ctx, .{
        .id = @constCast("c1"),
        .name = @constCast("cli_agent"),
        .arguments = @constCast("{\"task\":\"do something\"}"),
    });
    defer a.free(missing_agent);
    try std.testing.expect(std.mem.indexOf(u8, missing_agent, "Missing agent") != null);

    const unknown_agent = try executeToolCall(&ctx, .{
        .id = @constCast("c2"),
        .name = @constCast("cli_agent"),
        .arguments = @constCast("{\"agent\":\"oh-my-pi\",\"task\":\"x\"}"),
    });
    defer a.free(unknown_agent);
    try std.testing.expect(std.mem.indexOf(u8, unknown_agent, "Unknown agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, unknown_agent, "codex") != null);

    const missing_task = try executeToolCall(&ctx, .{
        .id = @constCast("c3"),
        .name = @constCast("cli_agent"),
        .arguments = @constCast("{\"agent\":\"codex\"}"),
    });
    defer a.free(missing_task);
    try std.testing.expect(std.mem.indexOf(u8, missing_task, "Missing task") != null);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtarget=aarch64-macos 2>&1 | tail -10`
Expected: FAIL —— 返回 "Unknown tool: cli_agent"，三个 expect 均不满足。

- [ ] **Step 3: 实现分发**

import 段（`agent_dynamic` 之前）加：

```zig
const agent_cli_agent = @import("cli_agent.zig");
```

`memory_search` 分支之后加：

```zig
    if (std.mem.eql(u8, call.name, "cli_agent")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const agent_key = tool_args.string(args.value, "agent") orelse return ctx.allocator.dupe(u8, "Missing agent");
        const backend = agent_cli_agent.find(agent_key) orelse
            return std.fmt.allocPrint(ctx.allocator, "Unknown agent \"{s}\". Available: {s}", .{ agent_key, agent_cli_agent.available_keys });
        const task = tool_args.string(args.value, "task") orelse return ctx.allocator.dupe(u8, "Missing task");
        const cwd = tool_args.string(args.value, "cwd");
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse agent_cli_agent.DEFAULT_TIMEOUT_MS;
        return agent_cli_agent.run(ctx, backend, task, cwd, timeout_ms);
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig fmt build.zig src && zig build test -Dtarget=aarch64-macos`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/agent_tools/mod.zig
git commit -m "Dispatch cli_agent tool calls to the backend runner"
```

---

### Task 5: 注册 —— protocol.zig schema + reserved、first_party.zig 目录

**Files:**
- Modify: `src/assistant/conversation/protocol.zig`（`forEachToolSpec` 内 subagent 的 emitTool 之后约 809 行；`builtinToolNameReserved` 约 725 行；测试段约 2215 行）
- Modify: `src/tools/first_party.zig`（`static_definitions`，subagent 行之后约 57 行）

**Interfaces:**
- Consumes: Task 4 使 `"cli_agent"` 名字可分发。
- Produces: 模型能看到 `cli_agent` schema（required: agent, task）；工具管理 UI 能禁用它；名字保留防动态工具撞名。

- [ ] **Step 1: 写失败测试**

protocol.zig 测试段（`"full toolset includes the subagent tool"` 附近）追加：

```zig
test "full toolset includes cli_agent and subagent toolset excludes it" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = false });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"cli_agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"agent\"") != null);

    var sub: std.ArrayListUnmanaged(u8) = .empty;
    defer sub.deinit(a);
    try appendToolSchemas(a, &sub, .{ .include_memory = false, .toolset = .subagent });
    try std.testing.expect(std.mem.indexOf(u8, sub.items, "\"cli_agent\"") == null);
    try std.testing.expect(builtinToolNameReserved("cli_agent"));
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | grep -B2 -A6 "cli_agent"`
Expected: FAIL（schema 里没有 cli_agent）。

- [ ] **Step 3: 实现注册**

protocol.zig `forEachToolSpec` 里 subagent 的 emitTool（809 行）之后加：

```zig
    try Filtered.emitToolWithRequired(ctx, opts, "cli_agent", "Delegate one self-contained coding or analysis task to an external CLI agent that works autonomously in the working directory with its own shell and file tools and full access. Available agents: codex. It cannot see this conversation or ask questions: put every needed detail (goal, files, constraints, expected output format) into task. Command progress streams into this chat; the tool returns the agent's final report. Prefer this over driving an interactive codex terminal when the task is self-contained.", "{\"agent\":{\"type\":\"string\",\"description\":\"Which CLI agent to run. Available: codex.\"},\"task\":{\"type\":\"string\",\"description\":\"Complete self-contained task description with all needed context.\"},\"cwd\":{\"type\":\"string\",\"description\":\"Optional working directory; defaults to the agent working directory.\"},\"timeout_ms\":{\"type\":\"integer\",\"description\":\"Optional timeout in milliseconds; default 600000, max 3600000.\"}}", &.{ "agent", "task" });
```

`builtinToolNameReserved` 数组 `"subagent",` 之后加：

```zig
        "cli_agent",
```

first_party.zig `static_definitions` subagent 行之后加：

```zig
    .{ .name = "cli_agent", .label = "cli_agent", .description = "Delegate a self-contained task to an external CLI agent (codex).", .category = .agent },
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig fmt build.zig src && zig build test -Dtarget=aarch64-macos && zig build test-full -Dtarget=aarch64-macos`
Expected: 两个套件 PASS（test-full 约 2300 用例；已知 flaky "skill center tool import" FileNotFound 与本改动无关，重跑即过）。

- [ ] **Step 5: Commit**

```bash
git add src/assistant/conversation/protocol.zig src/tools/first_party.zig
git commit -m "Register cli_agent as a first-party tool (schema, reserved name, catalog)"
```

---

### Task 6: 端到端验证

**Files:**
- 无代码改动（验证任务；发现问题回上面对应 task 修）。

**Interfaces:**
- Consumes: 全部前置 task。

- [ ] **Step 1: 修复本机 codex 安装**

Run: `npm i -g @openai/codex && codex exec --help | head -20`
Expected: 用法输出含 `--json`、`--dangerously-bypass-approvals-and-sandbox`、`--skip-git-repo-check`。若 flag 名与 spec 不符，回 Task 2 修 `codex_backend.base_args` 与测试。

- [ ] **Step 2: 构建并安装 macOS app**

Run: `zig build macos-app -Dtarget=aarch64-macos`（按仓库惯例重建；注意 zig-out 与 /Applications 多副本坑，验证前确认跑的是新二进制）

- [ ] **Step 3: 真机验证**

启动 WispTerm，在 AI 面板发：「用 cli_agent 委派 codex 一个任务：在当前目录写一个 hello.txt，内容 hello from codex，然后报告结果」。
Expected: 聊天卡片出现 "codex: $ ..." 进度行；结束后返回 codex 最终报告；hello.txt 存在。再验一次非 full 权限模式下会先弹审批。

- [ ] **Step 4: 清理验证产物并收尾**

删除 hello.txt。跑最后一遍 `zig fmt build.zig src && zig build test -Dtarget=aarch64-macos`，然后按用户指示推分支/开 PR（PR 引用 issue #533 与 spec/plan 文档）。
