# 技能同步异步化 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把技能中心的 transfer / import-scan / deploy-scan 三条同步路径搬到后台线程，根治主线程阻塞导致的鼠标卡死 / 应用无响应；进行中显示「同步中…」；失败时 toast 显示一行 stderr 摘要；并修复 `sshExecCapture` 的管道死锁。

**Architecture:** 复用 `skill_center.Session` 现有的 `scanAsync`/`finishScan` 后台模式，新增并列的「后台 op」机制：后台线程只跑阻塞 IO（ssh/scp/tar），把结构化结果写入 mutex 保护的 `op_pending` 并 `postWakeup()` 唤醒主循环；主循环新增 `pollSkillCenterOp` 在主线程消费结果、更新 overlay/toast/model。由于 `g_force_rebuild`/`showStatusToast` 等全是 `threadlocal`，后台线程绝不直接碰 UI。

**Tech Stack:** Zig 0.15.2；`std.Thread` / `std.Thread.Mutex` / `std.atomic.Value`；`std.process.Child`；现有 `skill_scan` / `skill_transfer` / `remote_file` / `scp` 模块。

参考设计：`docs/superpowers/specs/2026-06-07-skill-sync-async-design.md`

---

## 文件结构

| 文件 | 职责 | 改动 |
|------|------|------|
| `src/child_output.zig` | **新建**。并发 drain 子进程 stdout+stderr 到 EOF，避免管道满死锁。仅依赖 std。 | Create |
| `src/ssh_error.zig` | **新建**。从 ssh/scp stderr 文本提取一行人类可读摘要（纯函数）。 | Create |
| `src/platform/remote_file.zig` | `sshExecCapture` 改用 `child_output` 修死锁；新增 `sshExecCaptureFull` 回传 stdout+stderr+退出状态。 | Modify |
| `src/skill_center.zig` | 新增后台 op 机制：`OpResult`/`OpWork` 类型，`Session` 的 op 字段 + `startOp`/`takePendingOp`/`opThreadMain` + `destroy` join。 | Modify |
| `src/i18n.zig` | 新增「同步中…」「同步进行中…」「同步失败:」文案。 | Modify |
| `src/AppWindow.zig` | `SkillTransferCtx` 错误 side-channel；三个 op Job；三入口改 `startOp`；新增 `pollSkillCenterOp` + 主循环挂载。 | Modify |
| `src/test_fast.zig` | 加 `ssh_error.zig` import（fast 套件覆盖）。 | Modify |
| `src/test_posix.zig` | 加 `child_output.zig` import（posix fork 测试）。 | Modify |

测试命令：
- fast 逻辑单测（含 `skill_center`/`ssh_error`）：`zig build test`
- 需要 fork 的测试（`child_output`）：`zig build test-full`

---

## Task 1: child_output.zig — 并发读子进程两路输出（修死锁基础设施）

**Files:**
- Create: `src/child_output.zig`
- Modify: `src/test_posix.zig`

- [ ] **Step 1: Write the failing test**

创建 `src/child_output.zig`，先只写测试（实现留到 Step 3）：

```zig
//! Concurrently drain a child process's stdout and stderr to EOF so neither
//! pipe can fill and deadlock the other. The classic bug this prevents: read
//! stdout fully *then* stderr — if the child writes >64KB to stderr it blocks
//! on the full stderr pipe, never closes stdout, and the reader waits forever.
//!
//! Stored bytes are capped per stream, but BOTH streams are always read to EOF
//! (excess is discarded) so the child can always make progress and exit.

const std = @import("std");

pub const Captured = struct {
    stdout: []u8, // owned, truncated to stdout_max
    stderr: []u8, // owned, truncated to stderr_max

    pub fn deinit(self: *Captured, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

const Drain = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
    max: usize,
    out: std.ArrayListUnmanaged(u8) = .empty,
    oom: bool = false,
};

fn drain(d: *Drain) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = d.file.read(&buf) catch break;
        if (n == 0) break;
        if (d.out.items.len < d.max) {
            const room = d.max - d.out.items.len;
            const take = @min(room, n);
            d.out.appendSlice(d.allocator, buf[0..take]) catch {
                d.oom = true;
                // keep looping to drain the rest to EOF, just stop storing
            };
        }
        // past the cap (or after OOM): keep reading to EOF, discard bytes
    }
}

/// Read `stdout_file` on the calling thread and `stderr_file` on a worker
/// thread, both to EOF. Caller owns the returned slices. Caller is responsible
/// for `child.wait()` AFTER this returns (both pipes are drained, so wait won't
/// block on a full pipe).
pub fn capture(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    stderr_file: std.fs.File,
    stdout_max: usize,
    stderr_max: usize,
) !Captured {
    var err_d = Drain{ .file = stderr_file, .allocator = allocator, .max = stderr_max };
    const err_thread = try std.Thread.spawn(.{}, drain, .{&err_d});
    var out_d = Drain{ .file = stdout_file, .allocator = allocator, .max = stdout_max };
    drain(&out_d);
    err_thread.join();

    errdefer {
        out_d.out.deinit(allocator);
        err_d.out.deinit(allocator);
    }
    if (out_d.oom or err_d.oom) return error.OutOfMemory;
    return .{
        .stdout = try out_d.out.toOwnedSlice(allocator),
        .stderr = try err_d.out.toOwnedSlice(allocator),
    };
}

test "capture drains both streams without deadlock when stderr is large" {
    const a = std.testing.allocator;
    // Child writes a small stdout and a >64KB stderr. The old "read stdout to
    // EOF then stderr" order would deadlock here; concurrent drain must not.
    const script = "printf hello; printf 'E%.0s' $(seq 1 100000) 1>&2";
    var child = std.process.Child.init(&.{ "sh", "-c", script }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var cap = try capture(a, child.stdout.?, child.stderr.?, 1024 * 1024, 1024 * 1024);
    defer cap.deinit(a);
    _ = try child.wait();
    try std.testing.expectEqualStrings("hello", cap.stdout);
    try std.testing.expectEqual(@as(usize, 100000), cap.stderr.len);
}

test "capture truncates stored bytes to the cap but still reaches EOF" {
    const a = std.testing.allocator;
    const script = "printf 'O%.0s' $(seq 1 5000)"; // 5000 bytes stdout, no stderr
    var child = std.process.Child.init(&.{ "sh", "-c", script }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var cap = try capture(a, child.stdout.?, child.stderr.?, 100, 100);
    defer cap.deinit(a);
    const term = try child.wait();
    try std.testing.expectEqual(@as(usize, 100), cap.stdout.len); // capped
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term); // reached EOF/exit
}
```

Add to `src/test_posix.zig` inside the `comptime` block (after the existing `_ = @import("ai_loop_store.zig");`):

```zig
comptime {
    _ = @import("ai_loop_store.zig");
    _ = @import("child_output.zig");
}
```

- [ ] **Step 2: Confirm the new tests are wired in but not yet passing**

This is a new self-contained module: the impl and its tests are written together (the tests reference types that can't exist separately). To honor TDD intent, first comment out the bodies of `drain`/`capture` (leaving `return error.Unimplemented;` in `capture`), then run:

Run: `zig build test-full`
Expected: FAIL — `child_output` tests error (deadlock test gets `error.Unimplemented`). This proves the tests exercise the code path.

- [ ] **Step 3: Restore the real implementation**

Restore the full bodies of `drain` and `capture` exactly as written in Step 1.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-full`
Expected: PASS (both `child_output` tests green; rest of suite unchanged).

- [ ] **Step 5: Commit**

```bash
git add src/child_output.zig src/test_posix.zig
git commit -m "feat(child-output): concurrent stdout/stderr drain to fix pipe deadlock

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: ssh_error.zig — stderr 摘要提取（纯函数）

**Files:**
- Create: `src/ssh_error.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the file with tests**

Create `src/ssh_error.zig`:

```zig
//! Turn raw ssh/scp stderr into one short, human-readable line for a toast.
//! Best-effort: prefer a known diagnostic phrase if present, else fall back to
//! the last non-empty line, trimmed and length-capped. Returns a slice INTO the
//! input (no allocation); caller copies if it must outlive `stderr`.

const std = @import("std");

/// Max chars we hand to the toast (toast buffer is 160B; keep margin for prefix).
pub const MAX = 120;

const known = [_][]const u8{
    "Permission denied",
    "Connection timed out",
    "Connection refused",
    "Could not resolve hostname",
    "No route to host",
    "Host key verification failed",
    "No such file or directory",
    "Operation timed out",
    "Authentication failed",
};

/// Extract a concise summary from `stderr`. Returns `null` if nothing usable.
pub fn summarize(stderr: []const u8) ?[]const u8 {
    const trimmed_all = std.mem.trim(u8, stderr, " \t\r\n");
    if (trimmed_all.len == 0) return null;

    // 1) Prefer a known diagnostic phrase, returning the line that contains it.
    for (known) |phrase| {
        if (std.mem.indexOf(u8, trimmed_all, phrase)) |idx| {
            const line = lineAround(trimmed_all, idx);
            return cap(line);
        }
    }
    // 2) Fall back to the last non-empty line.
    var it = std.mem.splitBackwardsScalar(u8, trimmed_all, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len > 0) return cap(line);
    }
    return null;
}

fn lineAround(text: []const u8, idx: usize) []const u8 {
    var start = idx;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = idx;
    while (end < text.len and text[end] != '\n') end += 1;
    return std.mem.trim(u8, text[start..end], " \t\r\n");
}

fn cap(line: []const u8) []const u8 {
    return if (line.len > MAX) line[0..MAX] else line;
}

test "summarize prefers a known phrase line" {
    const s =
        \\Warning: Permanently added 'host' (ED25519) to the list of known hosts.
        \\root@host: Permission denied (publickey,password).
    ;
    try std.testing.expectEqualStrings(
        "root@host: Permission denied (publickey,password).",
        summarize(s).?,
    );
}

test "summarize falls back to last non-empty line" {
    const s = "some noise\n\nscp: /tmp/x: No space left on device\n\n";
    try std.testing.expectEqualStrings("scp: /tmp/x: No space left on device", summarize(s).?);
}

test "summarize returns null for blank stderr" {
    try std.testing.expectEqual(@as(?[]const u8, null), summarize("   \n\t\n"));
}

test "summarize caps very long lines" {
    var buf: [400]u8 = undefined;
    @memset(&buf, 'x');
    const out = summarize(&buf).?;
    try std.testing.expectEqual(MAX, out.len);
}
```

Add to `src/test_fast.zig` near the other skill imports (after line 68 `_ = @import("skill_scan.zig");`):

```zig
    _ = @import("ssh_error.zig");
```

- [ ] **Step 2: Run test to verify it passes**

Run: `zig build test`
Expected: PASS (4 new `ssh_error` tests; suite green).

- [ ] **Step 3: Commit**

```bash
git add src/ssh_error.zig src/test_fast.zig
git commit -m "feat(ssh-error): one-line stderr summary extractor for sync toasts

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: remote_file.zig — sshExecCapture 用并发读修死锁 + sshExecCaptureFull 回传 stderr

**Files:**
- Modify: `src/platform/remote_file.zig:116-222` (the `sshExecCapture` body)

- [ ] **Step 1: Add the import**

At the top of `src/platform/remote_file.zig`, after the existing imports (around line 5), add:

```zig
const child_output = @import("../child_output.zig");
```

- [ ] **Step 2: Add `SshCapture` type and `sshExecCaptureFull`, rewrite `sshExecCapture`**

Replace the whole current `pub fn sshExecCapture(...)` body (lines 116-222) with the following. The argv-building block (lines 130-203, from `var destination_buf` through `try child.spawn();`) is **unchanged** — only the output-reading tail (old lines 205-221) changes, and we wrap it in a new `Full` variant.

```zig
/// Result of an ssh exec: owned stdout + stderr, plus whether ssh exited 0.
pub const SshCapture = struct {
    stdout: []u8,
    stderr: []u8,
    exited_ok: bool,

    pub fn deinit(self: *SshCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

/// Like `sshExecCapture` but always returns stdout AND stderr (even on failure)
/// so callers can surface the real ssh error. Reads both pipes concurrently to
/// avoid a full-stderr-pipe deadlock.
pub fn sshExecCaptureFull(allocator: std.mem.Allocator, conn: anytype, command: []const u8) !SshCapture {
    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.password_auth) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return error.SpawnFailed;
        env_map = try std.process.getEnvMap(allocator);
        if (env_map) |*map| {
            try platform_process.putSshAskPassEnv(map, askpass_path.?, conn.password());
        }
    }

    var destination_buf: [272]u8 = undefined;
    const destination = std.fmt.bufPrint(destination_buf[0..], "{s}@{s}", .{ conn.user(), conn.host() }) catch return error.CommandTooLong;

    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = pty_command.sshExecutableName();
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "StrictHostKeyChecking=accept-new";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ConnectTimeout=8";
    argc += 1;
    if (conn.password_auth) {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "PreferredAuthentications=publickey,password,keyboard-interactive";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "NumberOfPasswordPrompts=1";
        argc += 1;
    } else {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "BatchMode=yes";
        argc += 1;
    }
    if (conn.legacy_algorithms) {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "HostkeyAlgorithms=+ssh-rsa,ssh-dss";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "Ciphers=+aes128-cbc,3des-cbc";
        argc += 1;
    }
    var proxy_buf: [272]u8 = undefined;
    if (conn.proxyJump().len > 0) {
        argv_buf[argc] = "-o";
        argc += 1;
        const proxy = std.fmt.bufPrint(proxy_buf[0..], "ProxyJump={s}", .{conn.proxyJump()}) catch return error.CommandTooLong;
        argv_buf[argc] = proxy;
        argc += 1;
    }
    if (conn.port().len > 0) {
        argv_buf[argc] = "-p";
        argc += 1;
        argv_buf[argc] = conn.port();
        argc += 1;
    }
    argv_buf[argc] = destination;
    argc += 1;
    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.create_no_window = true;
    if (env_map) |*map| child.env_map = map;
    try child.spawn();

    const stdout = child.stdout orelse return error.SpawnFailed;
    const stderr = child.stderr orelse return error.SpawnFailed;
    // Drain both pipes concurrently — a full stderr pipe must not deadlock the
    // stdout reader (the old "read stdout to EOF, then stderr" order could).
    var cap = child_output.capture(allocator, stdout, stderr, 2 * 1024 * 1024, 16 * 1024) catch {
        _ = child.wait() catch {};
        return error.RemoteExecFailed;
    };
    errdefer cap.deinit(allocator);

    const term = try child.wait();
    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    return .{ .stdout = cap.stdout, .stderr = cap.stderr, .exited_ok = ok };
}

pub fn sshExecCapture(allocator: std.mem.Allocator, conn: anytype, command: []const u8) ![]u8 {
    var cap = try sshExecCaptureFull(allocator, conn, command);
    if (!cap.exited_ok) {
        logSshFailure(cap.stderr);
        cap.deinit(allocator);
        return error.RemoteExecFailed;
    }
    allocator.free(cap.stderr);
    return cap.stdout; // ownership transferred to caller
}
```

Note: `child_output` is `src/child_output.zig`; from `src/platform/remote_file.zig` the import path is `../child_output.zig` (added in Step 1). `logSshFailure` and the tests below it are unchanged.

- [ ] **Step 3: Verify existing remote_file behavior is preserved**

The 4 existing callers of `sshExecCapture` (`ai_history_session.zig:149`, `AppWindow.zig:1061`, `AppWindow.zig:1088`, `html_server.zig:515`) keep the same signature `(allocator, conn, command) ![]u8`, so no caller changes here.

Run: `zig build test`
Expected: PASS (existing `remote_file` fast-reachable tests unaffected; signature unchanged).

- [ ] **Step 4: Smoke-compile the macOS app graph**

Run: `zig build test-shared -Dtarget=aarch64-macos`
Expected: PASS (shared modules compile with the new import; no link of full app).

- [ ] **Step 5: Commit**

```bash
git add src/platform/remote_file.zig
git commit -m "fix(remote-file): drain ssh stdout/stderr concurrently; add sshExecCaptureFull

Fixes a pipe deadlock where a large stderr could block the stdout reader
forever, hanging the caller. Adds sshExecCaptureFull so callers can read the
real ssh error for user-facing messages.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: skill_center.zig — 后台 op 机制

**Files:**
- Modify: `src/skill_center.zig` (add types after `ScanWork` ~line 251; add fields + methods to `Session` ~lines 256-340)

- [ ] **Step 1: Add `OpResult` and `OpWork` types**

After the `ScanWork` struct (ends ~line 251), add:

```zig
/// Structured result of a background skill-center op, produced on the worker
/// thread and consumed on the UI thread. Owns its strings/rows; `deinit` frees
/// them. The UI thread builds overlays/toasts from this — the worker never
/// touches UI state.
pub const OpResult = union(enum) {
    /// import-scan finished: show the import list built from `rows`.
    import_scan: struct { target: Target, rows: []scan.SkillRow },
    /// deploy-scan finished: UI decides noop/direct/confirm from `rows`.
    deploy_scan: struct { target: Target, name: []u8, src_hash: ?[]u8, rows: []scan.SkillRow },
    /// transfer finished: show success/failure toast.
    transfer: struct { is_import: bool, ok: bool, err_summary: ?[]u8 },
    /// generic failure before work could run (e.g. lost connection).
    failed,

    pub fn deinit(self: *OpResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .import_scan => |*v| {
                v.target.deinit(allocator);
                scan.freeRows(allocator, v.rows);
            },
            .deploy_scan => |*v| {
                v.target.deinit(allocator);
                allocator.free(v.name);
                if (v.src_hash) |h| allocator.free(h);
                scan.freeRows(allocator, v.rows);
            },
            .transfer => |*v| {
                if (v.err_summary) |s| allocator.free(s);
            },
            .failed => {},
        }
        self.* = .failed;
    }
};

/// Owned unit of background op work. `run` returns an `OpResult` (never errors —
/// failures are encoded in the result). `destroy` frees `ctx`.
pub const OpWork = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, std.mem.Allocator) OpResult,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};
```

- [ ] **Step 2: Add op fields to `Session`**

In `pub const Session = struct { ... }`, after `scan_thread: ?std.Thread = null,` (line 262), add:

```zig
    op_thread: ?std.Thread = null,
    op_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    op_pending: ?OpResult = null,
    op_wake: ?*const fn () void = null,
```

- [ ] **Step 3: Join op thread + free pending in `destroy`**

In `pub fn destroy(self: *Session)` (lines 271-282), after the existing `scan_thread` join block (lines 274-277), add:

```zig
        if (self.op_thread) |t| {
            t.join();
            self.op_thread = null;
        }
        if (self.op_pending) |*p| {
            p.deinit(allocator);
            self.op_pending = null;
        }
```

(`allocator` is already bound at the top of `destroy` as `const allocator = self.allocator;`.)

- [ ] **Step 4: Write the failing tests for `startOp` / `takePendingOp`**

Add these tests near the existing `skill_center` tests (e.g. after the `scanAsync`-related test around line 440):

```zig
const OpTestCtx = struct {
    a: std.mem.Allocator,
    result_ok: bool,
    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) OpResult {
        const self: *OpTestCtx = @ptrCast(@alignCast(ctx));
        _ = allocator;
        return .{ .transfer = .{ .is_import = false, .ok = self.result_ok, .err_summary = null } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OpTestCtx = @ptrCast(@alignCast(ctx));
        allocator.destroy(self);
    }
};

fn noopWake() void {}

test "startOp runs work and publishes a pending result" {
    const a = std.testing.allocator;
    const session = try Session.create(a);
    defer session.destroy();

    const ctx = try a.create(OpTestCtx);
    ctx.* = .{ .a = a, .result_ok = true };
    try std.testing.expect(session.startOp(.{ .ctx = ctx, .run = OpTestCtx.run, .destroy = OpTestCtx.destroy }, noopWake, "syncing"));
    session.joinOpForTest();

    var pending = session.takePendingOp() orelse return error.NoPending;
    defer pending.deinit(a);
    try std.testing.expect(pending == .transfer);
    try std.testing.expect(pending.transfer.ok);
    // consumed: a second take is empty
    try std.testing.expectEqual(@as(?OpResult, null), session.takePendingOp());
}

test "startOp rejects a second op while one is in flight" {
    const a = std.testing.allocator;
    const session = try Session.create(a);
    defer session.destroy();

    // Manually mark an op in flight without spawning, to test the busy guard.
    session.op_thread = null;
    session.op_done.store(false, .release);
    session.op_thread = try std.Thread.spawn(.{}, struct {
        fn f() void {}
    }.f, .{});

    const ctx = try a.create(OpTestCtx);
    ctx.* = .{ .a = a, .result_ok = true };
    const accepted = session.startOp(.{ .ctx = ctx, .run = OpTestCtx.run, .destroy = OpTestCtx.destroy }, noopWake, "syncing");
    try std.testing.expect(!accepted); // busy → rejected
    // we own ctx since it was rejected; free it
    ctx.destroy(@ptrCast(ctx), a);
    // let the dummy thread finish + be joinable
    session.op_done.store(true, .release);
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL with "no member named 'startOp'" / "no member named 'takePendingOp'" / "no member named 'joinOpForTest'".

- [ ] **Step 6: Implement `startOp`, `takePendingOp`, `opThreadMain`, `joinOpForTest`**

Add these methods inside `Session` (e.g. after `scanAsync`, around line 310):

```zig
    /// Start a background op. Returns false if an op is already in flight (the
    /// caller still owns `work` and should NOT have its destroy called — we call
    /// it only on the paths we take ownership). UI thread only.
    pub fn startOp(self: *Session, work: OpWork, wake: *const fn () void, busy_msg: []const u8) bool {
        if (self.op_thread != null and !self.op_done.load(.acquire)) {
            return false; // busy — never join-wait a possibly-slow op on the UI thread
        }
        if (self.op_thread) |t| {
            t.join(); // previous op already finished; non-blocking
            self.op_thread = null;
        }
        self.op_wake = wake;
        self.op_done.store(false, .release);

        self.mutex.lock();
        const msg = self.allocator.dupe(u8, busy_msg) catch null;
        if (msg) |m| self.model.setOverlay(.{ .busy = m });
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, opThreadMain, .{ self, work }) catch {
            self.op_done.store(true, .release);
            work.destroy(work.ctx, self.allocator);
            return false;
        };
        self.op_thread = thread;
        return true;
    }

    /// Take the published op result (if any), clearing it. UI thread only.
    pub fn takePendingOp(self: *Session) ?OpResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        const r = self.op_pending;
        self.op_pending = null;
        return r;
    }

    /// Test-only: wait for an in-flight op worker.
    pub fn joinOpForTest(self: *Session) void {
        if (self.op_thread) |t| {
            t.join();
            self.op_thread = null;
        }
    }
```

And add the free function `opThreadMain` near `scanThreadMain` (after line 349):

```zig
fn opThreadMain(session: *Session, work: OpWork) void {
    defer work.destroy(work.ctx, session.allocator);
    var result = work.run(work.ctx, session.allocator);

    session.mutex.lock();
    if (session.closing.load(.acquire)) {
        session.mutex.unlock();
        result.deinit(session.allocator);
    } else {
        if (session.op_pending) |*p| p.deinit(session.allocator); // discard stale (shouldn't happen)
        session.op_pending = result;
        session.mutex.unlock();
    }
    session.op_done.store(true, .release);
    if (session.op_wake) |w| w();
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS (both new op tests green; existing skill_center tests unchanged).

- [ ] **Step 8: Commit**

```bash
git add src/skill_center.zig
git commit -m "feat(skill-center): background op mechanism (startOp/takePendingOp)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: i18n.zig — 新文案

**Files:**
- Modify: `src/i18n.zig` (struct ~line 70; en ~line 249; zh_CN ~line 423)

- [ ] **Step 1: Add fields to the `Strings` struct**

In `pub const Strings = struct { ... }`, next to the other `sc_toast_*` fields (after `sc_toast_sync_failed: []const u8,` ~line 71), add:

```zig
    sc_busy_syncing: []const u8,
    sc_toast_op_busy: []const u8,
    sc_toast_sync_failed_prefix: []const u8,
```

- [ ] **Step 2: Add English values**

In `const en = Strings{ ... }`, after `.sc_toast_sync_failed = "Skill sync failed",` (~line 250), add:

```zig
    .sc_busy_syncing = "Syncing…",
    .sc_toast_op_busy = "A sync is already running",
    .sc_toast_sync_failed_prefix = "Sync failed: ",
```

- [ ] **Step 3: Add Simplified-Chinese values**

In `const zh_CN = Strings{ ... }`, after `.sc_toast_sync_failed = "技能同步失败",` (~line 424), add:

```zig
    .sc_busy_syncing = "同步中…",
    .sc_toast_op_busy = "同步进行中",
    .sc_toast_sync_failed_prefix = "同步失败: ",
```

- [ ] **Step 4: Verify it compiles**

Run: `zig build test`
Expected: PASS (i18n struct has matching fields in all language tables; a missing field in either table is a compile error, so a green build confirms completeness).

- [ ] **Step 5: Commit**

```bash
git add src/i18n.zig
git commit -m "i18n(skill-center): add syncing/busy/failed-prefix strings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: AppWindow.zig — SkillTransferCtx 错误 side-channel

**Files:**
- Modify: `src/AppWindow.zig:1079-1106` (`SkillTransferCtx`)
- Add import near other imports (top of file)

- [ ] **Step 1: Add the ssh_error import**

Near the top of `src/AppWindow.zig` with the other `@import` lines, add:

```zig
const ssh_error = @import("ssh_error.zig");
```

- [ ] **Step 2: Add an error buffer + helpers and capture stderr in `remoteExec`**

Replace the `SkillTransferCtx` struct (lines 1079-1106) with:

```zig
/// Adapts skill_transfer.Ops onto local/ssh/scp. conn null → a local-only target.
/// `err_buf`/`err_len` capture the last ssh error summary for the UI toast.
const SkillTransferCtx = struct {
    conn: ?ssh_connection.SshConnection,
    err_buf: [160]u8 = undefined,
    err_len: usize = 0,

    fn noteErr(self: *SkillTransferCtx, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
    }
    fn lastErr(self: *const SkillTransferCtx) ?[]const u8 {
        return if (self.err_len > 0) self.err_buf[0..self.err_len] else null;
    }

    fn localExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        _ = ctx;
        return remote_file.localPosixExecOk(allocator, command);
    }
    fn remoteExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *SkillTransferCtx = @ptrCast(@alignCast(ctx));
        const c = self.conn orelse return false;
        var cap = remote_file.sshExecCaptureFull(allocator, c, command) catch return false;
        defer cap.deinit(allocator);
        if (!cap.exited_ok) {
            if (ssh_error.summarize(cap.stderr)) |s| self.noteErr(s);
            return false;
        }
        return true;
    }
    fn copy(ctx: *anyopaque, allocator: std.mem.Allocator, dir: skill_transfer.CopyDir, local_tmp: []const u8, remote_tmp: []const u8) bool {
        const self: *SkillTransferCtx = @ptrCast(@alignCast(ctx));
        const c = self.conn orelse return false;
        var buf: [512]u8 = undefined;
        const spec = scp.remoteSpec(&buf, &c, remote_tmp);
        const r = switch (dir) {
            .to_remote => scp.transfer(allocator, &c, local_tmp, spec),
            .to_local => scp.transfer(allocator, &c, spec, local_tmp),
        };
        return r == .ok; // scp summary is best-effort; leave err_buf empty → generic toast
    }
    fn ops(self: *SkillTransferCtx) skill_transfer.Ops {
        return .{ .ctx = self, .localExec = localExec, .remoteExec = remoteExec, .copy = copy };
    }
};
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build test`
Expected: PASS (fast suite reaches `skill_transfer.zig`; `AppWindow.zig` itself is checked via the macOS app graph in Step 4).

- [ ] **Step 4: Smoke-compile macOS app**

Run: `zig build test-shared -Dtarget=aarch64-macos`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(skill-center): capture ssh stderr summary in SkillTransferCtx

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: AppWindow.zig — op Jobs + 三入口改 startOp + pollSkillCenterOp + 主循环挂载

**Files:**
- Modify: `src/AppWindow.zig`
  - `skillCenterOpenImportList` (1229-1249) → start an op
  - `skillCenterDeployDecide` (1305-1332) → start an op
  - `skillCenterRunTransfer` (1252-1278) → start an op
  - add op Job structs + `pollSkillCenterOp` (near `pollSkillUpdate` ~3178)
  - main loop: call `pollSkillCenterOp` (~5738)

- [ ] **Step 1: Add the three op Job structs**

Add near `SkillLibraryScanJob` (after line 1800):

```zig
/// Background op: scan a target, return rows for the UI to build an import list.
const SkillImportScanJob = struct {
    target: skill_center.Target, // owned
    conn: ?ssh_connection.SshConnection,
    root_expr: []u8, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillImportScanJob = @ptrCast(@alignCast(ctx));
        var le = SkillLocExec{ .conn = job.conn };
        var outcome = skill_scan.scanLocation(allocator, job.root_expr, le.host()) catch {
            return .failed;
        };
        const tgt = job.target.clone(allocator) catch {
            outcome.deinit(allocator);
            return .failed;
        };
        // Hand the rows to the result; null them so destroy won't double-free.
        const rows = outcome.rows;
        outcome.rows = &.{};
        return .{ .import_scan = .{ .target = tgt, .rows = rows } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillImportScanJob = @ptrCast(@alignCast(ctx));
        job.target.deinit(allocator);
        allocator.free(job.root_expr);
        allocator.destroy(job);
    }
};

/// Background op: scan a target for deploy, return rows + the skill identity so
/// the UI can decide noop/direct/confirm.
const SkillDeployScanJob = struct {
    target: skill_center.Target, // owned
    conn: ?ssh_connection.SshConnection,
    root_expr: []u8, // owned
    name: []u8, // owned
    src_hash: ?[]u8, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillDeployScanJob = @ptrCast(@alignCast(ctx));
        var le = SkillLocExec{ .conn = job.conn };
        var outcome = skill_scan.scanLocation(allocator, job.root_expr, le.host()) catch {
            return .failed;
        };
        const tgt = job.target.clone(allocator) catch {
            outcome.deinit(allocator);
            return .failed;
        };
        const name = allocator.dupe(u8, job.name) catch {
            outcome.deinit(allocator);
            var t = tgt;
            t.deinit(allocator);
            return .failed;
        };
        var src_hash: ?[]u8 = null;
        if (job.src_hash) |h| {
            src_hash = allocator.dupe(u8, h) catch {
                outcome.deinit(allocator);
                var t = tgt;
                t.deinit(allocator);
                allocator.free(name);
                return .failed;
            };
        }
        const rows = outcome.rows;
        outcome.rows = &.{};
        return .{ .deploy_scan = .{ .target = tgt, .name = name, .src_hash = src_hash, .rows = rows } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillDeployScanJob = @ptrCast(@alignCast(ctx));
        job.target.deinit(allocator);
        allocator.free(job.root_expr);
        allocator.free(job.name);
        if (job.src_hash) |h| allocator.free(h);
        allocator.destroy(job);
    }
};

/// Background op: run a transfer (library ⇆ target), capturing a stderr summary.
const SkillTransferJob = struct {
    is_import: bool,
    conn: ?ssh_connection.SshConnection,
    lib_root: []u8, // owned
    tgt_root: []u8, // owned
    tgt_is_local: bool,
    name: []u8, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillTransferJob = @ptrCast(@alignCast(ctx));
        var tctx = SkillTransferCtx{ .conn = job.conn };
        const lib_ep = skill_transfer.Endpoint{ .root_expr = job.lib_root, .is_local = true };
        const tgt_ep = skill_transfer.Endpoint{ .root_expr = job.tgt_root, .is_local = job.tgt_is_local };
        const from = if (job.is_import) tgt_ep else lib_ep;
        const to = if (job.is_import) lib_ep else tgt_ep;
        const r = skill_transfer.transfer(allocator, tctx.ops(), from, to, job.name);
        const ok = (r == .ok);
        var summary: ?[]u8 = null;
        if (!ok) {
            if (tctx.lastErr()) |s| summary = allocator.dupe(u8, s) catch null;
        }
        return .{ .transfer = .{ .is_import = job.is_import, .ok = ok, .err_summary = summary } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillTransferJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.lib_root);
        allocator.free(job.tgt_root);
        allocator.free(job.name);
        allocator.destroy(job);
    }
};
```

- [ ] **Step 2: Rewrite `skillCenterOpenImportList` to start an op**

Replace lines 1228-1249 (`skillCenterOpenImportList`) with:

```zig
/// Scan a chosen target and open the import list — off the UI thread.
fn skillCenterOpenImportList(allocator: std.mem.Allocator, target: skill_center.Target) void {
    const session = activeSkillCenter() orelse return;
    const conn = skillCenterTargetConn(target);
    if (!target.is_local and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        return;
    }
    const root_expr = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch return;
    // ownership of root_expr moves into the job on success
    const tgt = target.clone(allocator) catch {
        allocator.free(root_expr);
        return;
    };
    const job = allocator.create(SkillImportScanJob) catch {
        allocator.free(root_expr);
        var t = tgt;
        t.deinit(allocator);
        return;
    };
    job.* = .{ .target = tgt, .conn = conn, .root_expr = root_expr };
    if (!session.startOp(.{ .ctx = job, .run = SkillImportScanJob.run, .destroy = SkillImportScanJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_syncing)) {
        SkillImportScanJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}
```

- [ ] **Step 3: Rewrite `skillCenterDeployDecide` to start an op**

Replace lines 1304-1332 (`skillCenterDeployDecide`) with:

```zig
/// Deploy: scan the target off the UI thread; the decision happens in
/// pollSkillCenterOp once rows arrive.
fn skillCenterDeployDecide(allocator: std.mem.Allocator, target: skill_center.Target, name: []const u8, src_hash: ?[]const u8) void {
    const session = activeSkillCenter() orelse return;
    const conn = skillCenterTargetConn(target);
    if (!target.is_local and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        return;
    }
    const root_expr = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch return;
    const tgt = target.clone(allocator) catch {
        allocator.free(root_expr);
        return;
    };
    const name_dup = allocator.dupe(u8, name) catch {
        allocator.free(root_expr);
        var t = tgt;
        t.deinit(allocator);
        return;
    };
    var hash_dup: ?[]u8 = null;
    if (src_hash) |h| {
        hash_dup = allocator.dupe(u8, h) catch {
            allocator.free(root_expr);
            var t = tgt;
            t.deinit(allocator);
            allocator.free(name_dup);
            return;
        };
    }
    const job = allocator.create(SkillDeployScanJob) catch {
        allocator.free(root_expr);
        var t = tgt;
        t.deinit(allocator);
        allocator.free(name_dup);
        if (hash_dup) |h| allocator.free(h);
        return;
    };
    job.* = .{ .target = tgt, .conn = conn, .root_expr = root_expr, .name = name_dup, .src_hash = hash_dup };
    if (!session.startOp(.{ .ctx = job, .run = SkillDeployScanJob.run, .destroy = SkillDeployScanJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_syncing)) {
        SkillDeployScanJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}
```

- [ ] **Step 4: Rewrite `skillCenterRunTransfer` to start an op**

Replace lines 1251-1278 (`skillCenterRunTransfer`) with:

```zig
/// Run a transfer (library ⇆ target) off the UI thread; result handled in
/// pollSkillCenterOp.
fn skillCenterRunTransfer(allocator: std.mem.Allocator, is_import: bool, target: skill_center.Target, name: []const u8) void {
    const session = activeSkillCenter() orelse return;
    const conn = skillCenterTargetConn(target);
    if (!target.is_local and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        return;
    }
    const lib_dir = skillCenterLibraryDir(allocator) orelse return;
    defer allocator.free(lib_dir);
    const lib_root = skill_transfer_cmd.absRootExpr(allocator, lib_dir) catch return;
    const tgt_root = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch {
        allocator.free(lib_root);
        return;
    };
    const name_dup = allocator.dupe(u8, name) catch {
        allocator.free(lib_root);
        allocator.free(tgt_root);
        return;
    };
    const job = allocator.create(SkillTransferJob) catch {
        allocator.free(lib_root);
        allocator.free(tgt_root);
        allocator.free(name_dup);
        return;
    };
    job.* = .{
        .is_import = is_import,
        .conn = conn,
        .lib_root = lib_root,
        .tgt_root = tgt_root,
        .tgt_is_local = target.is_local,
        .name = name_dup,
    };
    if (!session.startOp(.{ .ctx = job, .run = SkillTransferJob.run, .destroy = SkillTransferJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_syncing)) {
        SkillTransferJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}
```

- [ ] **Step 5: Add `pollSkillCenterOp`**

Add right after `pollSkillUpdate` (after line 3194):

```zig
/// UI thread: consume a finished skill-center op result and apply it (open the
/// import list, run the deploy decision, or show a transfer toast).
fn pollSkillCenterOp(session: *skill_center.Session) void {
    const allocator = g_allocator orelse return;
    var result = session.takePendingOp() orelse return;
    defer result.deinit(allocator);

    switch (result) {
        .failed => {
            session.mutex.lock();
            if (session.model.overlay == .busy) session.model.clearOverlay();
            session.mutex.unlock();
            overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        },
        .import_scan => |*v| {
            session.mutex.lock();
            const st = skillCenterMakeImportState(allocator, &session.model, v.rows, v.target) catch {
                session.model.clearOverlay();
                session.mutex.unlock();
                return;
            };
            session.model.setOverlay(.{ .import_list = st });
            session.mutex.unlock();
        },
        .deploy_scan => |*v| {
            var present = false;
            var target_hash: ?[]const u8 = null;
            for (v.rows) |r| {
                if (std.mem.eql(u8, r.name, v.name)) {
                    present = true;
                    target_hash = r.agg_hash;
                }
            }
            // Clear the busy overlay before acting.
            session.mutex.lock();
            if (session.model.overlay == .busy) session.model.clearOverlay();
            session.mutex.unlock();
            switch (skill_center.overwriteDecision(present, target_hash, v.src_hash)) {
                .noop => overlays.showStatusToast(i18n.s().sc_toast_in_sync),
                .direct => skillCenterRunTransfer(allocator, false, v.target, v.name),
                .confirm => skillCenterArmConfirm(allocator, false, v.target, v.name),
            }
        },
        .transfer => |*v| {
            session.mutex.lock();
            if (session.model.overlay == .busy) session.model.clearOverlay();
            session.mutex.unlock();
            if (v.ok) {
                overlays.showStatusToast(if (v.is_import) i18n.s().sc_toast_imported else i18n.s().sc_toast_synced);
                startSkillCenterScan(allocator, session);
            } else if (v.err_summary) |s| {
                var buf: [200]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s}{s}", .{ i18n.s().sc_toast_sync_failed_prefix, s }) catch i18n.s().sc_toast_sync_failed;
                overlays.showStatusToast(msg);
            } else {
                overlays.showStatusToast(i18n.s().sc_toast_sync_failed);
            }
        },
    }
    markUiDirty();
}
```

- [ ] **Step 6: Call `pollSkillCenterOp` from the main loop**

After line 5738 (`pollSkillUpdate(self.app);`), add:

```zig
        if (activeSkillCenter()) |sc_session| pollSkillCenterOp(sc_session);
```

- [ ] **Step 7: Build the macOS app**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: PASS (full app compiles + links).

- [ ] **Step 8: Run the full fast suite**

Run: `zig build test`
Expected: PASS (no regressions).

- [ ] **Step 9: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(skill-center): run transfer/scan off the UI thread (fix ANR)

Transfer, import-scan and deploy-scan now run on a background op thread and
post their result back to the main loop via pollSkillCenterOp, so the UI no
longer freezes during ssh/scp. Shows 'Syncing…' while in flight and a
one-line stderr summary on failure.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: 集成验证（手动）

**Files:** none (manual verification)

- [ ] **Step 1: Run full test suite**

Run: `zig build test-full`
Expected: PASS (fast + posix + shared, including `child_output` deadlock test).

- [ ] **Step 2: Manual smoke test (uses superpowers:verification-before-completion)**

Launch the app from a terminal so stderr is visible:

```bash
zig build macos-app -Dtarget=aarch64-macos
./zig-out/.../WispTerm   # (use the produced .app/Contents/MacOS/WispTerm path)
```

Verify, observing behavior (not just "it built"):
1. Open Skill Center, deploy a skill to an SSH target — during the sync the **mouse moves, terminal is usable, window responds** (no beachball, no "not responding").
2. While syncing, the panel shows **"同步中…"**.
3. On success: **"技能已同步"** toast + library rescans.
4. Point at an unreachable / wrong-auth target — failure toast shows **"同步失败: <reason>"** with the real ssh error (e.g. "Permission denied"), and the full stderr line is also printed in the terminal.
5. Trigger a second sync while one is running → **"同步进行中"** toast, no crash.

- [ ] **Step 3: Final commit (if any fixups)**

```bash
git add -A
git commit -m "test(skill-center): verify async sync end-to-end

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** 后台化三路径 → Task 4+7；「同步中…」→ Task 4 (busy overlay) + Task 5/7；失败摘要 toast → Task 2/3/6/7；管道死锁 → Task 1/3。全部覆盖。
- **类型一致性:** `OpResult`/`OpWork`/`startOp(work, wake, busy_msg)`/`takePendingOp`/`sshExecCaptureFull`/`SshCapture`/`ssh_error.summarize`/`SkillTransferCtx.lastErr` 在定义任务与使用任务中签名一致。
- **内存所有权:** 每个 Job 的 `destroy` 释放其 owned 字段；`OpResult.deinit` 释放结果内 owned 数据；`startOp` 拒绝时调用方负责 `destroy`（已在每个入口处理）；scan rows 通过 `outcome.rows = &.{}` 转移所有权避免 double-free。
- **平台中立:** `skill_center.zig` 不引入平台依赖；唤醒回调 `window_backend.postWakeup` 由 `AppWindow` 注入。
