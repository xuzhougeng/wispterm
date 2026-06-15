# Windows debug/diagnostic build + field-bug fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a separate Windows debug artifact (ReleaseSafe + console + on-disk log + crash capture) that field users can run to produce logs/crash reports, and fix the two confirmed field bugs (ctrl+click remote-file freeze; WeChat-connect crash trail).

**Architecture:** A new `-Ddebug-console` build flag forces a console subsystem and turns on a new `src/diag_log.zig` module (a shared, mutex-guarded on-disk log fed by `std.log`, plus a Zig panic handler and a Windows unhandled-exception filter that write crash reports) wired into the root `src/main.zig` behind that flag — the normal release is untouched. The freeze is fixed by a wall-clock watchdog inside `scp.sshExecCappedOpts` that kills a hung SSH child. The WeChat crash is made diagnosable by routing the connect-path diagnostics through `std.log.scoped(.weixin)` (so they reach the file) and logging the currently-silent login catches; the panic handler captures the actual crash. CI gets a `windows-debug.yml` (manual) plus a debug zip auto-attached by `windows-release.yml`, built via a new `-DebugConsole` branch in `package.ps1`.

**Tech Stack:** Zig 0.15.2, GitHub Actions (windows-latest), PowerShell packaging, OpenSSH client.

---

## File Structure

- **Create** `src/diag_log.zig` — on-disk debug log (`std.log` sink) + crash capture (Zig panic + Windows SEH). One responsibility: capture diagnostics to disk. Pure helpers (`formatLine`, `shouldRollover`, `watchdog`-independent) are unit-tested; file/crash I/O is best-effort and manually verified.
- **Create** `.github/workflows/windows-debug.yml` — manual (`workflow_dispatch`) debug-artifact build for any branch/SHA. Mirrors `macos-debug.yml`.
- **Create** `docs/windows-debug-build.md` — short "how to run the debug build and send back logs" note (referenced by CI output and release notes).
- **Modify** `build.zig` — add `-Ddebug-console` option; force console subsystem; embed `build_options.debug_console`.
- **Modify** `src/main.zig` — declare `std_options` + `panic` (gated); init/close the log + install crash handlers.
- **Modify** `src/test_fast.zig`, `src/test_main.zig` — register `diag_log.zig` tests.
- **Modify** `src/scp.zig` — `ExecOpts` + `sshExecCappedOpts` watchdog + `watchdogTimeoutNs`/`killChildRaw`; `sshExecCapped` becomes a thin wrapper; add SSH `ServerAlive*`; bump argv buffers; update `appendSshOptions` tests.
- **Modify** `src/input.zig` — the UI-thread remote probe passes a 5 s timeout.
- **Modify** `src/weixin/controller.zig`, `src/weixin/ilink_client.zig`, `src/weixin/poller.zig` — scoped logging + breadcrumbs on silent catches.
- **Modify** `.github/workflows/windows-release.yml` — build + attach `wispterm-windows-debug-<tag>.zip`.
- **Modify** `packaging/windows/package.ps1` — `-DebugConsole` / `-Optimize` branch producing a compat-style debug bundle.

> **Verification note (Zig):** `zig build test` runs the fast native suite; `zig build test-full` cross-compiles+runs against the default windows-gnu target (the only place the Windows-only code paths are checked). `zig build` builds the native release exe. Run the relevant one(s) at each task's verify step. CI/PowerShell tasks have no unit tests — their verify steps are `zig build` dry-runs and a YAML/PS lint read.

---

## Phase 1 — Build flag

### Task 1: Add `-Ddebug-console` build option

**Files:**
- Modify: `build.zig:535` (option block), `build.zig:578-582` (subsystem), `build.zig:945-949` (`createAppModuleWithRoot` build_options)

- [ ] **Step 1: Add the option next to the existing `webview` option**

In `build.zig`, after the `webview` option (around line 535), add:

```zig
    const debug_console = b.option(
        bool,
        "debug-console",
        "Force a console subsystem and enable on-disk debug logging + crash capture (diagnostic builds).",
    ) orelse false;
```

- [ ] **Step 2: Thread it into the subsystem decision**

Replace `build.zig:578-582`:

```zig
        if (platform.supports_gui_subsystem) {
            // Debug builds use Console subsystem so std.debug.print output is visible.
            // Release builds use Windows GUI subsystem to avoid a background console window.
            exe.subsystem = if (optimize == .Debug) .Console else .Windows;
        }
```

with:

```zig
        if (platform.supports_gui_subsystem) {
            // Debug builds and diagnostic (-Ddebug-console) builds use the Console
            // subsystem so std.debug.print / std.log are visible; normal release
            // uses the Windows GUI subsystem to avoid a background console window.
            exe.subsystem = if (optimize == .Debug or debug_console) .Console else .Windows;
        }
```

- [ ] **Step 3: Pass the flag into the app module and embed it**

Change the `createAppModule` call site (build.zig:561) to pass `debug_console`:

```zig
        const exe_mod = createAppModule(b, target, optimize, app_version, platform, webview, debug_console);
```

Update `createAppModule` (build.zig:~926) and `createAppModuleWithRoot` (build.zig:929) signatures to add a trailing `debug_console: bool` parameter, forward it, and embed it. In `createAppModule`:

```zig
fn createAppModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app_version: []const u8,
    platform: PlatformFeatures,
    webview: bool,
    debug_console: bool,
) *std.Build.Module {
    return createAppModuleWithRoot(b, "src/main.zig", target, optimize, app_version, platform, webview, debug_console);
}
```

Add the same trailing parameter to `createAppModuleWithRoot`, and after `app_options.addOption(bool, "webview", webview);` (build.zig:946) add:

```zig
    app_options.addOption(bool, "debug_console", debug_console);
```

> Any other caller of `createAppModule`/`createAppModuleWithRoot` (e.g. the test-module builders, if they call it) must pass `false`. Grep `grep -n "createAppModule" build.zig` and fix every call.

- [ ] **Step 4: Verify the normal build is unaffected and the flag compiles**

Run: `zig build` — Expected: builds `zig-out/bin/wispterm` with no errors.
Run: `zig build -Ddebug-console=true` — Expected: builds with no errors (subsystem change is a no-op on Linux; the flag just sets `build_options.debug_console`). Step 5 of Task 5 exercises the gated code.

- [ ] **Step 5: Verify guards + fast suite still pass**

Run: `zig build test` — Expected: PASS (no new tests yet; confirms build.zig change didn't break the build-guards comptime check — `debug_console` matches none of `src/build_guards.zig`'s forbidden patterns).

- [ ] **Step 6: Commit**

```bash
git add build.zig
git commit -m "build: add -Ddebug-console flag (console subsystem + diag build_options)"
```

---

## Phase 2 — Diagnostics module

### Task 2: `diag_log.zig` pure helpers + test registration

**Files:**
- Create: `src/diag_log.zig`
- Modify: `src/test_fast.zig:123` area, `src/test_main.zig:666` area

- [ ] **Step 1: Write the failing tests (create the file with helpers + tests)**

Create `src/diag_log.zig` with ONLY the pure helpers and their tests for now:

```zig
//! Opt-in (diagnostic-build) application diagnostics: a shared on-disk log fed
//! by std.log, plus crash capture (Zig panic + Windows unhandled exceptions).
//!
//! Only wired up when built with -Ddebug-console (see src/main.zig). The log is
//! written to <config-dir>/wispterm-debug.log with a single size-based rollover
//! to wispterm-debug.log.1; crash reports go to <config-dir>/crash-<ts>.txt.

const std = @import("std");
const builtin = @import("builtin");

pub const MAX_LOG_BYTES: usize = 8 * 1024 * 1024;

/// Assemble one log line into `buf` (no trailing newline). On overflow the line
/// is truncated to what fits rather than dropped. Format:
/// "[+<elapsed>ms] <LEVEL>(<scope>) <message>".
pub fn formatLine(
    buf: []u8,
    elapsed_ms: i64,
    level: []const u8,
    scope: []const u8,
    message: []const u8,
) []const u8 {
    return std.fmt.bufPrint(buf, "[+{d}ms] {s}({s}) {s}", .{ elapsed_ms, level, scope, message }) catch blk: {
        // Buffer too small for the full line: emit as much of the prefix as fits.
        const head = "[+? ] ";
        const n = @min(buf.len, head.len);
        @memcpy(buf[0..n], head[0..n]);
        break :blk buf[0..n];
    };
}

/// True when writing `incoming` bytes would push the file past `max`, so the
/// caller must roll over first. A first write (written == 0) never rolls over,
/// so a single line larger than `max` still lands (after at most one rollover).
pub fn shouldRollover(written: usize, incoming: usize, max: usize) bool {
    return written != 0 and written + incoming > max;
}

test "diag_log: formatLine assembles prefix, level, scope, message" {
    var buf: [128]u8 = undefined;
    const line = formatLine(&buf, 42, "info", "weixin", "QR login started");
    try std.testing.expectEqualStrings("[+42ms] info(weixin) QR login started", line);
}

test "diag_log: formatLine truncates instead of overflowing a small buffer" {
    var buf: [8]u8 = undefined;
    const line = formatLine(&buf, 42, "info", "weixin", "QR login started");
    try std.testing.expect(line.len <= buf.len);
}

test "diag_log: shouldRollover never fires on the first write" {
    try std.testing.expect(!shouldRollover(0, MAX_LOG_BYTES + 1, MAX_LOG_BYTES));
}

test "diag_log: shouldRollover fires once the cap would be exceeded" {
    try std.testing.expect(!shouldRollover(10, 5, 100));
    try std.testing.expect(shouldRollover(98, 5, 100));
}
```

- [ ] **Step 2: Register the module in the test suites**

In `src/test_fast.zig`, next to `_ = @import("render_diagnostics.zig");` (line 123), add:

```zig
    _ = @import("diag_log.zig");
```

In `src/test_main.zig`, next to `_ = @import("scp.zig");` (line 666), add:

```zig
    _ = @import("diag_log.zig");
```

- [ ] **Step 3: Run the tests**

Run: `zig build test` — Expected: PASS, including the four new `diag_log:` tests.

- [ ] **Step 4: Commit**

```bash
git add src/diag_log.zig src/test_fast.zig src/test_main.zig
git commit -m "diag_log: pure log-line + rollover helpers with tests"
```

### Task 3: `diag_log.zig` file logger (std.log sink)

**Files:**
- Modify: `src/diag_log.zig`

- [ ] **Step 1: Add the file-logging state and functions**

Add to `src/diag_log.zig` (below the helpers, above the tests). It models `render_diagnostics.zig` but uses ONE process-global file guarded by a mutex (the std.log hook is called from many threads):

```zig
const platform_dirs = @import("platform/dirs.zig");
const build_options = @import("build_options");

const LOG_BASENAME = "wispterm-debug.log";
const LOG_BASENAME_PREV = "wispterm-debug.log.1";

var g_mutex: std.Thread.Mutex = .{};
var g_file: ?std.fs.File = null;
var g_written: usize = 0;
var g_start_ms: i64 = 0;
/// Config dir cached at first open so crash handlers (which may run mid-panic)
/// don't need to re-resolve it.
var g_dir: ?[]u8 = null;

/// Open (truncate) the log eagerly so an early crash still has a file. Safe to
/// call when not a diagnostic build — it just opens the file. Best-effort.
pub fn init() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    _ = openLocked() catch {};
}

pub fn close() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_file) |f| {
        f.close();
        g_file = null;
    }
}

/// std.Options.logFn: tee every std.log record to stderr (console build) and the
/// on-disk log. Best-effort: any failure silently degrades to stderr-only.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(level, scope, format, args); // stderr (visible in console build)

    g_mutex.lock();
    defer g_mutex.unlock();

    var msg_buf: [4000]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, format, args) catch msg_buf[0..msg_buf.len];

    const now = std.time.milliTimestamp();
    const elapsed = if (g_start_ms == 0) 0 else now - g_start_ms;
    var line_buf: [4200]u8 = undefined;
    const line = formatLine(&line_buf, elapsed, level.asText(), @tagName(scope), message);

    if (shouldRollover(g_written, line.len + 1, MAX_LOG_BYTES)) rolloverLocked();
    const file = openLocked() catch return;
    appendLocked(file, line);
    appendLocked(file, "\n");
}

fn appendLocked(file: std.fs.File, bytes: []const u8) void {
    file.writeAll(bytes) catch return;
    g_written += bytes.len;
}

/// Caller holds g_mutex. Opens (creating/truncating) the current log file.
fn openLocked() !std.fs.File {
    if (g_file) |f| return f;
    const a = std.heap.page_allocator;
    const dir = try platform_dirs.configDir(a);
    defer a.free(dir);
    if (g_dir == null) g_dir = a.dupe(u8, dir) catch null;
    std.fs.cwd().makePath(dir) catch {};
    const path = try std.fs.path.join(a, &.{ dir, LOG_BASENAME });
    defer a.free(path);
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    g_file = f;
    g_written = 0;
    g_start_ms = std.time.milliTimestamp();
    var hdr: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&hdr, "WispTerm debug log started ts_ms={d} version={s}\n", .{ g_start_ms, build_options.app_version }) catch "";
    f.writeAll(head) catch {};
    g_written += head.len;
    return f;
}

/// Caller holds g_mutex. Rename current -> .1 (keeping one prior generation),
/// then drop the handle so the next openLocked() recreates a fresh file.
fn rolloverLocked() void {
    const a = std.heap.page_allocator;
    if (g_file) |f| {
        f.close();
        g_file = null;
    }
    const dir = g_dir orelse return;
    const cur = std.fs.path.join(a, &.{ dir, LOG_BASENAME }) catch return;
    defer a.free(cur);
    const prev = std.fs.path.join(a, &.{ dir, LOG_BASENAME_PREV }) catch return;
    defer a.free(prev);
    std.fs.cwd().deleteFile(prev) catch {};
    std.fs.cwd().rename(cur, prev) catch {};
    g_written = 0;
}
```

- [ ] **Step 2: Verify it compiles in both suites**

Run: `zig build test` — Expected: PASS (existing diag_log helper tests still pass; new code compiles).
Run: `zig build test-full` — Expected: PASS (compiles for windows-gnu; the file paths resolve via `platform_dirs` which already supports Windows).

- [ ] **Step 3: Commit**

```bash
git add src/diag_log.zig
git commit -m "diag_log: shared on-disk log with std.log sink + size rollover"
```

### Task 4: `diag_log.zig` crash capture (Zig panic + Windows SEH)

**Files:**
- Modify: `src/diag_log.zig`

- [ ] **Step 1: Add crash-report writing, the panic function, and the Windows filter**

Add to `src/diag_log.zig`:

```zig
const win = std.os.windows;

/// std.debug.FullPanic hook: write a crash report, then chain to the default
/// panic so the process still aborts (and prints the trace to the console).
pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    writeCrashReport(msg, first_trace_addr);
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Best-effort crash file at <config-dir>/crash-<ts>.txt. MUST NOT call into
/// logFn (g_mutex is non-reentrant and may already be held by the faulting
/// thread). Uses its own file handle.
pub fn writeCrashReport(msg: []const u8, first_trace_addr: ?usize) void {
    const a = std.heap.page_allocator;
    const dir = g_dir orelse (platform_dirs.configDir(a) catch return);
    // If g_dir was set, it's owned by the module; only free a fresh resolution.
    const owned_dir = g_dir == null;
    defer if (owned_dir) a.free(dir);
    std.fs.cwd().makePath(dir) catch {};

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "crash-{d}.txt", .{std.time.milliTimestamp()}) catch return;
    const path = std.fs.path.join(a, &.{ dir, name }) catch return;
    defer a.free(path);

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();
    var wbuf: [4096]u8 = undefined;
    var w = file.writerStreaming(&wbuf);
    w.interface.print(
        "WispTerm crash\nversion: {s}\nmessage: {s}\n\nstack trace:\n",
        .{ build_options.app_version, msg },
    ) catch {};
    std.debug.dumpCurrentStackTraceToWriter(first_trace_addr, &w.interface) catch {};
    w.interface.flush() catch {};
}

/// Install OS-level crash capture. Currently the Windows unhandled-exception
/// filter for native (non-Zig) faults (D3D / WebView2 / win32 access
/// violations) that never reach Zig's panic. No-op elsewhere.
pub fn installCrashHandlers() void {
    if (builtin.os.tag == .windows) {
        _ = SetUnhandledExceptionFilter(winExceptionFilter);
    }
}

// Declared here (not in std) — mirrors the extern pattern in
// src/platform/clipboard_windows.zig. Only referenced on Windows, so the
// non-Windows build never links kernel32.
extern "kernel32" fn SetUnhandledExceptionFilter(
    filter: ?win.VECTORED_EXCEPTION_HANDLER,
) callconv(.winapi) ?win.VECTORED_EXCEPTION_HANDLER;

fn winExceptionFilter(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    var msg_buf: [64]u8 = undefined;
    const code = info.ExceptionRecord.ExceptionCode;
    const msg = std.fmt.bufPrint(&msg_buf, "native exception 0x{x}", .{code}) catch "native exception";
    writeCrashReport(msg, null);
    return win.EXCEPTION_CONTINUE_SEARCH; // let the OS crash normally
}
```

- [ ] **Step 2: Verify compile on both targets**

Run: `zig build test` — Expected: PASS (the Windows extern/handler are unreferenced on Linux → not linked).
Run: `zig build test-full` — Expected: PASS (Windows path compiles; `SetUnhandledExceptionFilter`/`EXCEPTION_POINTERS`/`EXCEPTION_CONTINUE_SEARCH` resolve).

- [ ] **Step 3: Commit**

```bash
git add src/diag_log.zig
git commit -m "diag_log: crash capture (Zig panic handler + Windows SEH filter)"
```

### Task 5: Wire diagnostics into `src/main.zig` (gated)

**Files:**
- Modify: `src/main.zig:6-17` (imports + root decls), `src/main.zig:108-152` (`main()` early init)

- [ ] **Step 1: Add imports and the gated root declarations**

In `src/main.zig`, after the existing imports (after line 17), add:

```zig
const build_options = @import("build_options");
const diag_log = @import("diag_log.zig");

/// Diagnostic builds (-Ddebug-console) route std.log to the on-disk debug log;
/// normal builds keep std defaults (zero cost).
pub const std_options: std.Options = if (build_options.debug_console)
    .{ .logFn = diag_log.logFn, .log_level = .debug }
else
    .{};

/// Diagnostic builds write a crash report before aborting; normal builds use the
/// default panic.
pub const panic = if (build_options.debug_console)
    std.debug.FullPanic(diag_log.panicFn)
else
    std.debug.FullPanic(std.debug.defaultPanic);
```

- [ ] **Step 2: Initialize the log + crash handlers early in `main()`**

In `src/main.zig`, right before `std.debug.print("WispTerm starting...\n", .{});` (line ~152, after the CLI-command short-circuits return), add:

```zig
    if (build_options.debug_console) {
        diag_log.init();
        diag_log.installCrashHandlers();
        std.log.info("diagnostic build start version={s}", .{app_metadata.app_version_string});
    }
    defer if (build_options.debug_console) diag_log.close();
```

> If `app_metadata` does not expose `app_version_string`, use `build_options.app_version` instead. Verify with `grep -n "app_version" src/app_metadata.zig`.

- [ ] **Step 3: Verify normal build, gated build, and suites**

Run: `zig build` — Expected: builds; behavior unchanged (gated code is comptime-dead).
Run: `zig build -Ddebug-console=true` — Expected: builds; the logFn/panic/init paths are now compiled in.
Run: `zig build test` and `zig build test-full` — Expected: PASS.

- [ ] **Step 4: Manual smoke (Linux dev box — proves the wiring, not the Windows packaging)**

Run:
```bash
zig build -Ddebug-console=true && ./zig-out/bin/wispterm --version
ls -l "${XDG_CONFIG_HOME:-$HOME/.config}/wispterm/wispterm-debug.log"
```
Expected: the `--version` path returns before GUI init, so the log may be empty/absent; instead launch the app briefly (or trust the windows-gnu compile + the GUI verification at the end). The authoritative check is the Windows GUI step in the final task.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "main: install diag log + crash handlers behind -Ddebug-console"
```

---

## Phase 3 — Ctrl+click freeze fix

### Task 6: `watchdogTimeoutNs` pure helper

**Files:**
- Modify: `src/scp.zig` (helpers + tests near the bottom test block)

- [ ] **Step 1: Write the failing test**

Add to the test section of `src/scp.zig`:

```zig
test "watchdogTimeoutNs: 0 disables the watchdog" {
    try std.testing.expectEqual(@as(?u64, null), watchdogTimeoutNs(0));
}

test "watchdogTimeoutNs: converts ms to ns and clamps to the ceiling" {
    try std.testing.expectEqual(@as(?u64, 5_000 * std.time.ns_per_ms), watchdogTimeoutNs(5_000));
    try std.testing.expectEqual(@as(?u64, 120_000 * std.time.ns_per_ms), watchdogTimeoutNs(10_000_000));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test` — Expected: FAIL (`watchdogTimeoutNs` undefined).

- [ ] **Step 3: Implement the helper**

Add near the top of `src/scp.zig` (after the imports/constants). Ensure `const builtin = @import("builtin");` exists at the top — add it if missing.

```zig
/// Convert a caller timeout (ms) into a watchdog wait (ns). null = no watchdog
/// (0 disables it, preserving the historical unbounded behavior). Clamps to a
/// 120 s ceiling so a bad value can't effectively remove the cap.
pub fn watchdogTimeoutNs(timeout_ms: u64) ?u64 {
    if (timeout_ms == 0) return null;
    return @min(timeout_ms, 120_000) * std.time.ns_per_ms;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/scp.zig
git commit -m "scp: watchdogTimeoutNs pure helper"
```

### Task 7: SSH exec watchdog (`ExecOpts` + `sshExecCappedOpts`)

**Files:**
- Modify: `src/scp.zig:340-461` (`sshExec`, `sshExecCapped`)

- [ ] **Step 1: Add the watchdog type and the raw-kill helper**

Add to `src/scp.zig` (near `watchdogTimeoutNs`):

```zig
pub const ExecOpts = struct {
    /// Hard wall-clock cap in ms. 0 = no watchdog (default). On expiry the ssh
    /// child is killed so a post-connect hang becomes a bounded failure.
    timeout_ms: u64 = 0,
};

const ExecWatchdog = struct {
    child: *std.process.Child,
    timeout_ns: u64,
    cancel: std.Thread.ResetEvent = .{},

    fn run(self: *ExecWatchdog) void {
        self.cancel.timedWait(self.timeout_ns) catch {
            // Timed out: kill by raw OS handle so the blocked stdout read sees
            // EOF and child.wait() can reap. (Does NOT touch Child state, so it
            // can't race the main thread's wait()/kill().)
            killChildRaw(self.child);
        };
    }
};

fn killChildRaw(child: *std.process.Child) void {
    switch (builtin.os.tag) {
        .windows => std.os.windows.TerminateProcess(child.id, 1) catch {},
        else => std.posix.kill(child.id, std.posix.SIG.KILL) catch {},
    }
}

/// Stop the watchdog and join it. MUST be called before any child.wait()/kill()
/// so the watchdog cannot fire on an already-reaped (and possibly recycled) pid.
fn disarmWatchdog(wd: *ExecWatchdog, thread: *?std.Thread) void {
    if (thread.*) |t| {
        wd.cancel.set();
        t.join();
        thread.* = null;
    }
}
```

- [ ] **Step 2: Make `sshExecCapped` a wrapper and move the body to `sshExecCappedOpts`**

Replace the current `pub fn sshExecCapped(...) ?[]u8 {` signature/body (scp.zig:352) so the body lives in `sshExecCappedOpts`, and `sshExecCapped` forwards with no watchdog (this preserves the `SshExecCappedFn` function-pointer contract in `src/input/preview_source.zig:145`):

```zig
pub fn sshExecCapped(allocator: std.mem.Allocator, conn: *const SshConnection, command: []const u8, max_stdout_bytes: usize) ?[]u8 {
    return sshExecCappedOpts(allocator, conn, command, max_stdout_bytes, .{});
}

pub fn sshExecCappedOpts(allocator: std.mem.Allocator, conn: *const SshConnection, command: []const u8, max_stdout_bytes: usize, opts: ExecOpts) ?[]u8 {
```

…then keep the entire existing body, with these edits:

(a) Immediately after the `child.spawn() catch ... return null;` block, arm the watchdog:

```zig
    var wd = ExecWatchdog{ .child = &child, .timeout_ns = 0 };
    var wd_thread: ?std.Thread = null;
    if (watchdogTimeoutNs(opts.timeout_ms)) |ns| {
        wd.timeout_ns = ns;
        wd_thread = std.Thread.spawn(.{}, ExecWatchdog.run, .{&wd}) catch null;
    }
    defer disarmWatchdog(&wd, &wd_thread); // safety net; explicit disarms below run first
```

(b) Before EACH `child.wait()` and `child.kill()` in the function, add `disarmWatchdog(&wd, &wd_thread);`. The sites (post-edit line numbers shift) are:
- the `const stdout = child.stdout orelse { ... child.wait() ... }` early return,
- the `const stderr = child.stderr orelse { ... child.wait() ... }` early return,
- the `stderr_thread = ... catch |err| { ... child.kill() ... }` failure,
- the stdout `if (stdout_drain == .exceeded) { ... child.kill() ... }` branch,
- the final `const term = child.wait() catch return null;`.

For the final normal path it looks like:

```zig
    stderr_thread.join();
    if (stderr_ctx.err) |err| {
        std.debug.print("sshExec: stderr drain failed: {}\n", .{err});
    }

    disarmWatchdog(&wd, &wd_thread);
    const term = child.wait() catch return null;
```

(c) In the exceeded branch, disarm before the kill and add a log line:

```zig
    const stdout_drain = drainCapped(stdout, allocator, &output, max_stdout_bytes, true) catch .exceeded;
    if (stdout_drain == .exceeded) {
        std.debug.print("sshExec: stdout exceeded {d} bytes; killing ssh\n", .{max_stdout_bytes});
        disarmWatchdog(&wd, &wd_thread);
        _ = child.kill() catch {};
        stderr_thread.join();
        return null;
    }
```

> The `defer disarmWatchdog(...)` is idempotent (it no-ops once `wd_thread` is null), so the explicit disarms before each wait/kill are the real safety; the defer only covers any path that returns without reaching a wait.

- [ ] **Step 3: Verify both suites build and pass**

Run: `zig build test` — Expected: PASS (existing scp tests unchanged; `sshExecCapped` signature preserved so `preview_source.zig` still compiles).
Run: `zig build test-full` — Expected: PASS (Windows `TerminateProcess` path compiles).

- [ ] **Step 4: Commit**

```bash
git add src/scp.zig
git commit -m "scp: wall-clock watchdog for sshExecCappedOpts (kills hung ssh)"
```

### Task 8: SSH `ServerAlive*` keepalive + buffer headroom

**Files:**
- Modify: `src/scp.zig:835` (appendSshOptions, after ConnectTimeout), `src/scp.zig` argv buffers, `src/scp.zig:1000-1024` (appendSshOptions tests)

- [ ] **Step 1: Update the failing tests first**

In `src/scp.zig`, update the two count assertions to account for the 4 new args (2 `-o` + 2 values), keeping the existing index checks valid by appending ServerAlive at the END of `appendSshOptions`:

```zig
test "appendSshOptions key-based auth" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    conn.port_len = 0;

    var argv_buf: [40][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, null);
    // Strict + ConnectTimeout + BatchMode (6) + ServerAliveInterval/CountMax (4) = 10
    try std.testing.expectEqual(@as(usize, 10), argc);
    try std.testing.expectEqualStrings("BatchMode=yes", argv_buf[5]);
    try std.testing.expectEqualStrings("ServerAliveInterval=5", argv_buf[7]);
    try std.testing.expectEqualStrings("ServerAliveCountMax=2", argv_buf[9]);
}

test "appendSshOptions password auth" {
    var conn: SshConnection = .{};
    conn.password_auth = true;
    conn.port_len = 0;

    var argv_buf: [40][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, null);
    // Strict + ConnectTimeout + Preferred + NumPasswords (8) + ServerAlive (4) = 12
    try std.testing.expectEqual(@as(usize, 12), argc);
    try std.testing.expectEqualStrings("NumberOfPasswordPrompts=1", argv_buf[7]);
}
```

> Also bump the `var argv_buf: [32][]const u8` to `[40][]const u8` in BOTH of these tests, and in the "with ssh port" test below them (read scp.zig:1024+ and update each test's buffer size to 40).

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test` — Expected: FAIL (argc is still 6/8; `ServerAliveInterval` not present).

- [ ] **Step 3: Append the keepalive options**

In `appendSshOptions` (`src/scp.zig`), immediately before `return argc;` (scp.zig:894), add:

```zig
    // Detect a dead post-connect session (ConnectTimeout only covers connect).
    // ~10 s to give up: ServerAliveInterval=5 x ServerAliveCountMax=2.
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ServerAliveInterval=5";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ServerAliveCountMax=2";
    argc += 1;
```

- [ ] **Step 4: Bump the production argv buffers for headroom**

The worst-case option count now approaches 32. In `src/scp.zig`, change every `var argv_buf: [32][]const u8 = undefined;` used by a function that calls `appendSshOptions` to `[40][]const u8`. Grep `grep -n "argv_buf: \[32\]" src/scp.zig` and update all production (non-test) sites (lines ~173, 368, 607, 684, 767, 972). Updating all of them is safe.

- [ ] **Step 5: Run to verify pass**

Run: `zig build test` — Expected: PASS.
Run: `zig build test-full` — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/scp.zig
git commit -m "scp: add ServerAlive keepalive + argv headroom for ssh options"
```

### Task 9: UI-thread probe uses a bounded timeout

**Files:**
- Modify: `src/input.zig:3657` (`remotePathIsDirectoryForDownload`)

- [ ] **Step 1: Switch the probe to the timed variant**

In `src/input.zig`, change the probe call (line 3657) from:

```zig
    const output = scp.sshExecCapped(allocator, conn, cmd, 8) orelse return null;
```

to:

```zig
    // Runs on the UI thread, so bound it: a hung remote `test -d` becomes a
    // ~5 s delay + null result instead of a permanent freeze (see scp watchdog).
    const output = scp.sshExecCappedOpts(allocator, conn, cmd, 8, .{ .timeout_ms = 5_000 }) orelse return null;
```

- [ ] **Step 2: Verify both suites**

Run: `zig build test` — Expected: PASS.
Run: `zig build test-full` — Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/input.zig
git commit -m "input: bound the ctrl+click remote path probe with a 5s timeout"
```

---

## Phase 4 — WeChat connect-crash diagnosability

### Task 10: Scoped logging + breadcrumbs on the connect path

**Files:**
- Modify: `src/weixin/controller.zig`, `src/weixin/ilink_client.zig`, `src/weixin/poller.zig`

- [ ] **Step 1: Add a scoped logger to each file**

At the top of each of the three files (after the existing imports), add:

```zig
const log = std.log.scoped(.weixin);
```

- [ ] **Step 2: Log the currently-silent login catches (the key change)**

In `src/weixin/controller.zig` `loginThreadMain` (lines 157-186), add breadcrumbs to the silent catches so a connect failure leaves a trail in the debug log:

```zig
        const qr = self.beginLogin(qr_arena.allocator()) catch |err| {
            log.warn("login: beginLogin failed: {}", .{err});
            self.setLoginStatus(.expired);
            self.login_active.store(false, .release);
            return;
        };
```

and the poll/confirm catches:

```zig
            const status = self.pollLogin(poll_arena.allocator(), qr.qrcode) catch |err| {
                log.warn("login: pollLogin failed: {}", .{err});
                poll_arena.deinit();
                std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            };
```

```zig
            if (status.status == .confirmed) {
                self.confirmLogin(status) catch |err| log.err("login: confirmLogin failed: {}", .{err});
                poll_arena.deinit();
                break;
            }
```

Add a start breadcrumb in `loginThreadMain` (first line of the function body):

```zig
        log.info("login: thread start", .{});
```

- [ ] **Step 3: Route the connect-path prints to std.log (so they reach the file)**

Convert these `std.debug.print` connect-path diagnostics to `log.*` (file + stderr). In `src/weixin/controller.zig`:
- line 103 `"weixin QR login started\n"` → `log.info("QR login started", .{});`
- line 315 `"weixin QR login confirmed; polling started\n"` → `log.info("QR login confirmed; polling started", .{});`
- line 349 `"weixin direct binding loaded; poller active\n"` → `log.info("direct binding loaded; poller active", .{});`

In `src/weixin/ilink_client.zig` `httpFetch` (line 513), convert the failure print:

```zig
        if (response.status != .ok) {
            log.warn("http endpoint={s} status=failed http_status={} body_excerpt={s}", .{
                endpointForLog(path),
                response.status,
                logSafeResponseExcerpt(arena, response_items),
            });
            return error.IlinkHttpStatus;
        }
```

In `src/weixin/poller.zig` `threadMain` (line 275), convert the poll-error print:

```zig
            self.tickOnce() catch |err| {
                log.warn("poll failed: {}; retrying in {d}ms", .{ err, POLL_ERROR_BACKOFF_MS });
                std.Thread.sleep(POLL_ERROR_BACKOFF_MS * std.time.ns_per_ms);
            };
```

and `start`/`stop` (lines 240, 251): `std.debug.print("weixin poller started\n", .{});` → `log.info("poller started", .{});` and the stopped print likewise.

> Leave the deep per-message `process(...)` trace prints in `poller.zig` as `std.debug.print` (still console-visible in the debug build) — converting all of them is out of scope; the connect path is what diagnoses "opening WeChat crashes".

- [ ] **Step 4: Verify both suites**

Run: `zig build test` — Expected: PASS.
Run: `zig build test-full` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/weixin/controller.zig src/weixin/ilink_client.zig src/weixin/poller.zig
git commit -m "weixin: scoped logging + breadcrumbs on the connect path for diag builds"
```

---

## Phase 5 — CI & packaging

### Task 11: `package.ps1` debug bundle branch

**Files:**
- Modify: `packaging/windows/package.ps1:1-10` (params), `:160` (after `$releaseVersion` is computed)

- [ ] **Step 1: Add the parameters**

In the `param(...)` block of `packaging/windows/package.ps1`, add:

```powershell
    [switch]$DebugConsole,
    [string]$Optimize = 'ReleaseFast',
```

- [ ] **Step 2: Add the early debug branch (reuses the compat helpers)**

In `package.ps1`, immediately after `$releaseVersion = Get-ReleaseVersion -ExplicitVersion $Version` (line ~160) and before `$noWebViewInstallDir = ...`, add a self-contained branch that builds the debug exe and a single compat-style bundle, then exits without touching the release dirs:

```powershell
if ($DebugConsole) {
    Push-Location $repoRoot
    try {
        & zig build "-Doptimize=$Optimize" -Ddebug-console
        if ($LASTEXITCODE -ne 0) { throw "zig build -Doptimize=$Optimize -Ddebug-console failed." }
    } finally {
        Pop-Location
    }

    $debugBinary = Join-Path $repoRoot 'zig-out\bin\wispterm.exe'
    if (-not (Test-Path $debugBinary)) { throw "Debug binary not found: $debugBinary" }

    $debugDir = Join-Path $resolvedOutputDir 'portable-debug'
    Remove-Item -Path $debugDir -Recurse -Force -ErrorAction SilentlyContinue

    # Bundle the compat DLLs so the debug build runs on older Windows 10 too.
    $webView2LoaderPath = Get-WebView2Loader -RepoRoot $repoRoot -Version $WebView2Version
    $conPtyPair = Get-ConPtyPair -RepoRoot $repoRoot -Version $ConPtyVersion
    Copy-PortablePayload -BinaryPath $debugBinary -TargetDir $debugDir -ReleaseVersion $releaseVersion -WebView2LoaderPath $webView2LoaderPath -ConPtyPair $conPtyPair

    Write-Host "Debug build ($Optimize, console): $(Join-Path $debugDir 'wispterm.exe')"
    exit 0
}
```

- [ ] **Step 3: Verify the script parses (PowerShell syntax check)**

Run (on a Windows runner, or locally if `pwsh` is installed):
```bash
pwsh -NoProfile -Command "Get-Command -Syntax -Name ./packaging/windows/package.ps1" 2>/dev/null || echo "pwsh not available locally; rely on CI"
```
Expected: no parse error (or "pwsh not available" — then the CI job in Task 12/13 is the check).

- [ ] **Step 4: Commit**

```bash
git add packaging/windows/package.ps1
git commit -m "package.ps1: -DebugConsole/-Optimize branch builds a compat debug bundle"
```

### Task 12: `windows-debug.yml` (manual dispatch)

**Files:**
- Create: `.github/workflows/windows-debug.yml`
- Create: `docs/windows-debug-build.md`

- [ ] **Step 1: Write the run-instructions doc**

Create `docs/windows-debug-build.md`:

```markdown
# WispTerm Windows diagnostic build

This is a **diagnostic** build of WispTerm: it shows a console window and writes
a debug log and crash reports so we can diagnose hard-to-reproduce issues
(e.g. a crash when opening the WeChat connection, or a freeze when ctrl+clicking
a remote file). It is built with runtime safety checks on (ReleaseSafe) and is
slightly slower than the normal release — use it only to reproduce a problem.

## How to use

1. Unzip `wispterm-windows-debug-<tag>.zip` anywhere and run `wispterm.exe`.
   A console window opens alongside the app — leave it open.
2. Reproduce the problem (open the WeChat connection, ctrl+click the remote
   file, etc.).
3. Send us:
   - `%APPDATA%\wispterm\wispterm-debug.log` (and `wispterm-debug.log.1` if present), and
   - any `%APPDATA%\wispterm\crash-*.txt` files, and
   - the text in the console window if the app crashed.

Open the folder quickly by pasting `%APPDATA%\wispterm` into the Explorer
address bar.
```

- [ ] **Step 2: Write the workflow (mirrors macos-debug.yml)**

Create `.github/workflows/windows-debug.yml`:

```yaml
name: Build Windows Diagnostic

# Manually-triggered diagnostic build: a console-subsystem, ReleaseSafe build
# that writes an on-disk debug log + crash reports. Hand to a user to reproduce
# a hard-to-diagnose crash/freeze. Not for release.

on:
  workflow_dispatch:
    inputs:
      ref:
        description: Branch, tag, or SHA to build
        type: string
        default: main
      optimize:
        description: Optimize mode (ReleaseSafe keeps safety checks; Debug adds richer traces)
        type: choice
        default: ReleaseSafe
        options:
          - ReleaseSafe
          - Debug

permissions:
  contents: read

jobs:
  build-debug:
    name: Build Windows diagnostic (${{ github.event.inputs.optimize }})
    runs-on: windows-latest
    env:
      ZIG_GLOBAL_CACHE_DIR: ${{ github.workspace }}\.zig-global-cache

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          ref: ${{ github.event.inputs.ref }}

      - name: Set up Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.15.2

      - name: Cache Zig packages
        uses: actions/cache@v4
        with:
          path: |
            .zig-cache/p
            .zig-global-cache
          key: ${{ runner.os }}-zig-0.15.2-${{ hashFiles('build.zig', 'build.zig.zon', 'pkg/**/build.zig.zon') }}
          restore-keys: |
            ${{ runner.os }}-zig-0.15.2-

      - name: Build diagnostic bundle
        shell: pwsh
        run: |
          $opt = "${{ github.event.inputs.optimize }}"
          zig build "-Doptimize=$opt" -Ddebug-console --fetch
          powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1 -DebugConsole -Optimize $opt -SkipInstaller

      - name: Package debug zip
        shell: pwsh
        run: |
          $sha = "${{ github.sha }}".Substring(0,8)
          $opt = "${{ github.event.inputs.optimize }}"
          $asset = "wispterm-windows-debug-$opt-$sha.zip"
          if (Test-Path $asset) { Remove-Item $asset -Force }
          Compress-Archive -Path zig-out\dist\portable-debug\* -DestinationPath $asset -Force
          "ASSET_PATH=$asset"  | Out-File -FilePath $env:GITHUB_ENV -Append
          "ASSET_NAME=wispterm-windows-debug-$opt-$sha" | Out-File -FilePath $env:GITHUB_ENV -Append

      - name: Upload diagnostic artifact
        uses: actions/upload-artifact@v4
        with:
          name: ${{ env.ASSET_NAME }}
          path: ${{ env.ASSET_PATH }}
          if-no-files-found: error

      - name: How to run
        shell: pwsh
        run: Get-Content docs\windows-debug-build.md
```

- [ ] **Step 3: Verify YAML + that the build command matches package.ps1**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/windows-debug.yml')); print('yaml ok')"` — Expected: `yaml ok`.
Cross-check the `-DebugConsole -Optimize` flags match the Task 11 param names exactly.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/windows-debug.yml docs/windows-debug-build.md
git commit -m "ci: manual windows-debug workflow + run instructions doc"
```

### Task 13: Auto-attach debug zip to every release

**Files:**
- Modify: `.github/workflows/windows-release.yml` (add a build+zip step after line 176; add the asset to the upload + both `gh release` calls)

- [ ] **Step 1: Build the debug bundle after the release bundles**

In `windows-release.yml`, after the "Validate packaged outputs" step (line 154) and before "Create release assets", add a step:

```yaml
      - name: Build diagnostic (debug-console) bundle
        shell: pwsh
        run: |
          zig build -Doptimize=ReleaseSafe -Ddebug-console
          powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1 -DebugConsole -Optimize ReleaseSafe -SkipInstaller
          if (!(Test-Path "zig-out\dist\portable-debug\wispterm.exe")) {
            throw "Debug bundle not found: zig-out\dist\portable-debug\wispterm.exe"
          }
```

> This runs AFTER the release bundles are already copied into `zig-out\dist\portable*`, and the `-DebugConsole` branch only touches `portable-debug`, so it does not disturb them.

- [ ] **Step 2: Zip it alongside the other assets**

In the "Create release assets" step (after line 176), add:

```powershell
          $debugAsset = "wispterm-windows-debug-$tag.zip"
          if (Test-Path $debugAsset) { Remove-Item $debugAsset -Force }
          Compress-Archive -Path zig-out\dist\portable-debug\* -DestinationPath $debugAsset -Force
```

- [ ] **Step 3: Upload + attach the debug asset**

Add an upload step after the "Upload portable no-WebView artifact" step (line 197):

```yaml
      - name: Upload diagnostic artifact
        uses: actions/upload-artifact@v4
        with:
          name: wispterm-windows-debug-${{ github.ref_name }}
          path: wispterm-windows-debug-${{ github.ref_name }}.zip
          if-no-files-found: error
```

In the "Publish GitHub release" step, add `$debugAsset` to both the `$tag`-existence guard and the asset lists:

```powershell
          $debugAsset = "wispterm-windows-debug-$tag.zip"
```

then include `$debugAsset` in both `gh release upload $tag $portableAsset $portableCompatAsset $portableNoWebViewAsset $debugAsset --repo ... --clobber` and `gh release create $tag $portableAsset $portableCompatAsset $portableNoWebViewAsset $debugAsset ...`, and add a bullet to `$assetNotes`:

```powershell
              "- Diagnostic (debug): console build with on-disk logging + crash reports for troubleshooting (ReleaseSafe). See docs/windows-debug-build.md.",
```

- [ ] **Step 4: Verify YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/windows-release.yml')); print('yaml ok')"` — Expected: `yaml ok`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/windows-release.yml
git commit -m "ci: build and attach a debug-console zip to every Windows release"
```

---

## Final: GUI verification + spec status

### Task 14: Windows GUI verification and close-out

- [ ] **Step 1: Trigger the manual debug build**

Push the branch, then run the `Build Windows Diagnostic` workflow (`workflow_dispatch`) against this branch. Download the artifact.

- [ ] **Step 2: Verify diagnostics on Windows (the authoritative check)**

On a Windows machine:
1. Run `wispterm.exe` from the debug zip — a console window appears.
2. Confirm `%APPDATA%\wispterm\wispterm-debug.log` is created and grows (contains the `diagnostic build start` line + `weixin(...)` lines after touching WeChat).
3. Open the WeChat connection to attempt to reproduce the crash; if it crashes, confirm a `%APPDATA%\wispterm\crash-*.txt` is written with a stack trace.
4. Ctrl+click a remote file on an unreachable/hung host: confirm the UI returns within ~5 s (bounded), not a permanent freeze, and the log shows the ssh exec start + failure.

- [ ] **Step 3: Mark the spec implemented**

Update `docs/superpowers/specs/2026-06-15-windows-debug-logging-build-design.md` `Status:` line to `Implemented (pending GUI sign-off / merge)` and commit.

```bash
git add docs/superpowers/specs/2026-06-15-windows-debug-logging-build-design.md
git commit -m "docs(spec): mark windows debug-logging build implemented"
```

---

## Self-Review

**Spec coverage:**
- Build option & subsystem (spec §A) → Task 1. ✓
- Diagnostics module: log + std_options + panic + Windows SEH (spec §B) → Tasks 2-5. ✓
- Freeze fix: watchdog + ServerAlive + UI-thread cap + logging (spec §C) → Tasks 6-9. ✓
- WeChat capture/hardening (spec §D) → Task 10 (+ crash handler from §B). ✓
- CI & packaging: windows-release attach + windows-debug.yml + package.ps1 (spec §E) → Tasks 11-13. ✓
- Testing (spec §F) → per-task verify steps + Task 14 GUI. ✓
- Out of scope (spec §G: logging-in-release, async probe) → not present. ✓

**Placeholder scan:** No "TBD/TODO/handle edge cases". Every code step shows real code; every verify step shows a command + expected result. The two "verify with grep" notes (createAppModule callers; app_version field name) are explicit guard instructions, not deferred work.

**Type/name consistency:** `debug_console` (option + build_options field) consistent across Tasks 1/5. `diag_log.{init,close,logFn,panicFn,writeCrashReport,installCrashHandlers,formatLine,shouldRollover,MAX_LOG_BYTES}` consistent across Tasks 2-5. `ExecOpts`/`sshExecCappedOpts`/`watchdogTimeoutNs`/`killChildRaw`/`disarmWatchdog` consistent across Tasks 6-9, and `sshExecCapped`'s preserved signature matches `SshExecCappedFn` in `preview_source.zig`. `-DebugConsole`/`-Optimize` package.ps1 params match their use in both workflows (Tasks 11-13). `portable-debug` dist dir name consistent across Tasks 11-13. `wispterm-debug.log` / `crash-*.txt` paths consistent across module, docs, and verification.
