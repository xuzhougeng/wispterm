# Async AI History Scan & Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the AI History scan and transcript-preview off the main UI thread onto a background worker so the window never freezes, and auto-start the scan when an AI History tab is created.

**Architecture:** Mirror the proven `ai_chat.zig` worker model — a `std.Thread` stored on the session, a `closing` atomic, a `mutex` guarding shared state, and `deinit` that sets `closing` then `join()`s before freeing. The blocking `host.scan` / `host.loadTranscript` run *outside* the lock; only the brief result-publish takes the lock. A monotonic generation counter discards superseded results. The continuous render loop (`runMainLoop` redraws every frame) picks up published state with no explicit wakeup. UAF safety comes purely from `deinit` joining workers before freeing.

**Tech Stack:** Zig, `std.Thread` / `std.Thread.Mutex` / `std.atomic.Value`, existing `ai_history_session` scanner-host abstraction.

---

## Design Reference

Spec: `docs/superpowers/specs/2026-06-02-async-ai-history-scan-design.md`

## Key Facts (verified)

- `src/ai_history_session.zig` is registered in **both** `src/test_fast.zig:54` and `src/test_main.zig:620`, so Session-level tests run under `zig build test` (fast).
- `src/AppWindow.zig` already imports `ai_history_cache`, `ai_history_types`, `overlays` — but **not** `ssh_connection`; Task 4 adds it.
- `g_cells_valid` / `g_force_rebuild` are `threadlocal` (`AppWindow.zig:1653-1654`). **Workers must never call `markUiDirty`.** The continuous render loop reflects state changes.
- `overlays.aiHistorySshConnection(name) ?ssh_connection.SshConnection` is a pure value builder (inline buffers, no threadlocal pointers) — safe to snapshot on the UI thread and copy into a worker job.
- `ai_history_cache.saveDefault(allocator, .{ .records }) !void` is already imported by `ai_history_session.zig` (line 9), so the worker saves the metadata cache itself — no AppWindow dependency.
- Resume (`Enter`) only spawns a PTY (`spawnTabWithCommandAndCwd`) that connects asynchronously; it performs no blocking UI-thread I/O and is **out of scope**.

## File Structure

- `src/ai_history_session.zig` — async state fields, `ScanWork`/`TranscriptWork` interfaces, `scanAsync`/`loadTranscriptAsync`, worker bodies, generation-checked publish helpers, `deinit` join, `pub` on `cloneMetadata`/`freeMetadata`, `joinForTest`. New unit tests.
- `src/AppWindow.zig` — `ssh_connection` import; `AiHistoryTarget` union; `AiHistoryScanJob`/`AiHistoryTranscriptJob` + their `run`/`destroy`; `scanTargetSnapshot`; `startAiHistoryScan`/`startAiHistoryTranscript`; rewrite `aiHistoryScanLocalNow`/`aiHistoryPreviewSelectedTranscript`; lock render + input/mouse dispatch; auto-scan in `spawnAiHistoryTab`; delete `withAiHistoryScannerHost`/`ScanRunner`/`PreviewTranscriptRunner`/`saveAiHistoryMetadataCache`.

## Locking Contract (read before coding)

`Session.mutex` guards: `state`, `status`, `rows`, `selected`, `list_offset`, `transcript`, `transcript_state`, `transcript_status`, `transcript_provider`, and the generation counters. `source` is immutable after init (only freed in `deinit`, which joins first) and needs no lock. `scan_thread`/`transcript_thread` are touched only by the UI thread (`scanAsync`/`loadTranscriptAsync`/`deinit`) and need no lock.

Rules:
- The long `host.scan`/`host.loadTranscript` runs with **no** lock held.
- The worker takes the lock only for the final publish/discard.
- Every UI-thread access to a guarded field holds the lock.
- **No lock nesting:** a UI handler that holds the lock must not call another function that also locks (e.g. `scanAsync`, `loadTranscriptAsync`, `aiHistoryScanLocalNow`). Compute under the lock, release, then dispatch.

---

## Task 1: Session async state + generation-checked publish (synchronous logic)

Adds the shared-state fields and the publish-or-discard logic, tested synchronously (no threads yet).

**Files:**
- Modify: `src/ai_history_session.zig` (struct fields ~133-142; `cloneMetadata`/`freeMetadata` at 843/872)
- Test: `src/ai_history_session.zig` (test block at end of file)

- [ ] **Step 1: Add async fields to `Session`**

In the `Session` struct (after the `transcript: []types.TranscriptMessage = &.{},` field near line 142) add:

```zig
    // Async scan/transcript support. `mutex` guards state/status/rows/selected/
    // list_offset/transcript*/generation fields. Workers run host I/O without the
    // lock and take it only to publish. `closing` + join-on-deinit give UAF safety.
    mutex: std.Thread.Mutex = .{},
    scan_thread: ?std.Thread = null,
    transcript_thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_generation: u64 = 0,
    transcript_generation: u64 = 0,
```

- [ ] **Step 2: Make `cloneMetadata` and `freeMetadata` public**

Change `fn cloneMetadata` (line 843) to `pub fn cloneMetadata` and `fn freeMetadata` (line 872) to `pub fn freeMetadata`.

- [ ] **Step 3: Add the publish-or-discard helpers**

Add these methods to `Session` (place them right after `scanNowReturningResult`, ~line 245). They assume they are called by a worker; they take the lock internally:

```zig
    /// Publish scan rows if `generation` is still current and we are not closing,
    /// otherwise discard. Always frees `result`. Called from the scan worker.
    pub fn publishScanResult(self: *Session, generation: u64, result: ScanResult) void {
        var published = false;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.closing.load(.acquire) and generation == self.scan_generation) {
                if (self.replaceRows(result.rows)) |_| {
                    self.status = if (result.warning_count == 0) "Ready" else "Ready with warnings";
                    published = true;
                } else |_| {
                    self.state = .failed;
                    self.status = "Scan failed";
                }
            }
        }
        if (published and result.cache_update.records.len > 0) {
            ai_history_cache.saveDefault(self.allocator, .{ .records = result.cache_update.records }) catch {};
        }
        freeScanResult(self.allocator, result);
    }

    /// Mark the scan failed if `generation` is still current and not closing.
    pub fn publishScanFailure(self: *Session, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.scan_generation) {
            self.state = .failed;
            self.status = "Scan failed";
        }
    }
```

Note: `replaceRows` clones rows, so freeing `result.rows` afterward (via `freeScanResult`) is correct — it mirrors the existing `defer freeScanResult` in the old sync path.

- [ ] **Step 4: Write the failing tests**

Add to the test section at the end of `src/ai_history_session.zig`:

```zig
test "ai_history_session: publishScanResult applies rows when generation current" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 7;

    const rows = try allocator.alloc(types.SessionMeta, 1);
    rows[0] = .{
        .provider = .codex,
        .session_id = try allocator.dupe(u8, "live"),
        .title = try allocator.dupe(u8, "Live"),
        .source_path = try allocator.dupe(u8, "live.jsonl"),
        .resume_kind = .codex_resume,
    };
    session.publishScanResult(7, .{ .rows = rows, .owns_row_strings = true });

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqual(@as(usize, 1), session.rows.items.len);
    try std.testing.expectEqualStrings("live", session.rows.items[0].session_id);
}

test "ai_history_session: publishScanResult discards stale generation" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 9;

    const rows = try allocator.alloc(types.SessionMeta, 1);
    rows[0] = .{
        .provider = .codex,
        .session_id = try allocator.dupe(u8, "stale"),
        .title = try allocator.dupe(u8, "Stale"),
        .source_path = try allocator.dupe(u8, "stale.jsonl"),
        .resume_kind = .codex_resume,
    };
    // generation 4 != current 9 -> discarded and freed (testing allocator checks no leak)
    session.publishScanResult(4, .{ .rows = rows, .owns_row_strings = true });

    try std.testing.expectEqual(@as(usize, 0), session.rows.items.len);
}
```

- [ ] **Step 5: Run the tests (expect FAIL before, PASS after Steps 1-3 are in)**

Run: `zig build test`
Expected after Steps 1-3: PASS. If you wrote the tests first against an unmodified file, they fail to compile (`publishScanResult` undefined) — that is the intended red state.

- [ ] **Step 6: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat: add generation-checked scan publish to ai history session

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Async scan worker + deinit join

Adds the `ScanWork` interface, `scanAsync`, the worker body, the `deinit` join, and a test helper.

**Files:**
- Modify: `src/ai_history_session.zig` (`deinit` ~159-167; add interface + methods near `scanNowReturningResult`)
- Test: `src/ai_history_session.zig`

- [ ] **Step 1: Add the `ScanWork` interface**

Add near the other top-level public types (after `ScannerHost`, ~line 44):

```zig
/// Owned unit of background scan work. `run` performs the blocking scan; `destroy`
/// frees the context (`ctx`). Both run on the worker thread. `ctx` must own
/// everything `run` needs and contain no pointers into threadlocal UI state.
pub const ScanWork = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, std.mem.Allocator, source_mod.Source) anyerror!ScanResult,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};
```

- [ ] **Step 2: Add `scanAsync`, the worker, and a test-join helper**

Add to `Session` (after the publish helpers from Task 1):

```zig
    /// Start a background scan. UI-thread only. Joins any prior scan worker first
    /// (at most one in flight per session), flips to `.scanning`, bumps the
    /// generation, and spawns the worker. Returns immediately.
    pub fn scanAsync(self: *Session, work: ScanWork) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        self.mutex.lock();
        self.state = .scanning;
        self.status = "Scanning";
        self.scan_generation +%= 1;
        const generation = self.scan_generation;
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, scanWorkerMain, .{ self, work, generation }) catch {
            self.mutex.lock();
            if (generation == self.scan_generation) {
                self.state = .failed;
                self.status = "Scan failed";
            }
            self.mutex.unlock();
            work.destroy(work.ctx, self.allocator);
            return;
        };
        self.scan_thread = thread;
    }

    /// Test-only: wait for in-flight workers to finish so results can be asserted
    /// deterministically. Not called in production (deinit joins instead).
    pub fn joinForTest(self: *Session) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        if (self.transcript_thread) |t| {
            t.join();
            self.transcript_thread = null;
        }
    }
```

And the free worker function (top-level, not a method — place after the `Session` struct, near `scanRemoteFilesystem`):

```zig
fn scanWorkerMain(session: *Session, work: ScanWork, generation: u64) void {
    defer work.destroy(work.ctx, session.allocator);
    const result = work.run(work.ctx, session.allocator, session.source) catch {
        session.publishScanFailure(generation);
        return;
    };
    session.publishScanResult(generation, result);
}
```

- [ ] **Step 3: Add the `deinit` join**

In `Session.deinit` (line 159), make it the first thing — before any frees:

```zig
    pub fn deinit(self: *Session) void {
        self.closing.store(.release, true);
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        if (self.transcript_thread) |t| {
            t.join();
            self.transcript_thread = null;
        }
        self.clearTranscript();
        freeRows(self.allocator, self.rows.items);
        self.rows.deinit(self.allocator);
        if (self.source_owned) {
            freeOwnedSource(self.allocator, &self.source);
        }
        self.* = undefined;
    }
```

Note: `std.atomic.Value(bool).store` signature is `store(self, value, ordering)`, so it is `self.closing.store(true, .release);` — write it that way:

```zig
        self.closing.store(true, .release);
```

- [ ] **Step 4: Write the failing test**

```zig
test "ai_history_session: scanAsync publishes rows then joins clean" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        destroyed: bool = false,
        fn run(ptr: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source) anyerror!ScanResult {
            _ = ptr;
            const rows = try alloc.alloc(types.SessionMeta, 1);
            rows[0] = .{
                .provider = .codex,
                .session_id = try alloc.dupe(u8, "async-id"),
                .title = try alloc.dupe(u8, "Async"),
                .source_path = try alloc.dupe(u8, "async.jsonl"),
                .resume_kind = .codex_resume,
            };
            return .{ .rows = rows, .owns_row_strings = true };
        }
        fn destroy(ptr: *anyopaque, _: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroyed = true;
        }
    };

    var ctx = Ctx{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    session.scanAsync(.{ .ctx = &ctx, .run = Ctx.run, .destroy = Ctx.destroy });
    session.joinForTest();

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqual(@as(usize, 1), session.rows.items.len);
    try std.testing.expectEqualStrings("async-id", session.rows.items[0].session_id);
    try std.testing.expect(ctx.destroyed);
}
```

- [ ] **Step 5: Run the test**

Run: `zig build test`
Expected: PASS (and no leak report from the testing allocator).

- [ ] **Step 6: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat: run ai history scan on a background worker thread

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Async transcript worker + deinit join

**Files:**
- Modify: `src/ai_history_session.zig`
- Test: `src/ai_history_session.zig`

- [ ] **Step 1: Add the `TranscriptWork` interface**

After `ScanWork`:

```zig
/// Owned unit of background transcript-load work. `run` performs the blocking
/// load; `provider` is used to publish; `destroy` frees `ctx` (which owns the
/// selected metadata copy). All run on the worker thread.
pub const TranscriptWork = struct {
    ctx: *anyopaque,
    provider: types.ProviderId,
    run: *const fn (*anyopaque, std.mem.Allocator) anyerror![]types.TranscriptMessage,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};
```

- [ ] **Step 2: Add publish helpers, `loadTranscriptAsync`, and the worker**

Add to `Session` (after `loadSelectedTranscript`, ~line 260):

```zig
    /// Start a background transcript load for the currently-selected row's data,
    /// captured by the caller into `work.ctx`. UI-thread only. Clears any current
    /// transcript, flips to `.loading`, bumps the generation, spawns the worker.
    pub fn loadTranscriptAsync(self: *Session, work: TranscriptWork) void {
        if (self.transcript_thread) |t| {
            t.join();
            self.transcript_thread = null;
        }
        self.mutex.lock();
        self.clearTranscript();
        self.transcript_state = .loading;
        self.transcript_status = "Loading transcript";
        self.transcript_generation +%= 1;
        const generation = self.transcript_generation;
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, transcriptWorkerMain, .{ self, work, generation }) catch {
            self.mutex.lock();
            if (generation == self.transcript_generation) {
                self.transcript_state = .failed;
                self.transcript_status = "Transcript failed";
            }
            self.mutex.unlock();
            work.destroy(work.ctx, self.allocator);
            return;
        };
        self.transcript_thread = thread;
    }

    /// Publish transcript messages if `generation`/`provider` still current and not
    /// closing, otherwise free them. Worker-thread only.
    pub fn publishTranscript(self: *Session, generation: u64, provider: types.ProviderId, messages: []types.TranscriptMessage) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.transcript_generation) {
            self.transcript = messages;
            self.transcript_provider = provider;
            self.transcript_state = .ready;
            self.transcript_status = "Transcript ready";
        } else {
            freeTranscript(self.allocator, provider, messages);
        }
    }

    pub fn publishTranscriptFailure(self: *Session, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.transcript_generation) {
            self.transcript_state = .failed;
            self.transcript_status = "Transcript failed";
        }
    }
```

And the worker (top-level, near `scanWorkerMain`):

```zig
fn transcriptWorkerMain(session: *Session, work: TranscriptWork, generation: u64) void {
    defer work.destroy(work.ctx, session.allocator);
    const messages = work.run(work.ctx, session.allocator) catch {
        session.publishTranscriptFailure(generation);
        return;
    };
    session.publishTranscript(generation, work.provider, messages);
}
```

- [ ] **Step 3: Write the failing test**

```zig
test "ai_history_session: loadTranscriptAsync publishes messages then joins clean" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        fn run(_: *anyopaque, alloc: std.mem.Allocator) anyerror![]types.TranscriptMessage {
            const messages = try alloc.alloc(types.TranscriptMessage, 1);
            errdefer alloc.free(messages);
            messages[0] = .{ .role = .user, .content = try alloc.dupe(u8, "async-hello") };
            return messages;
        }
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var ctx_byte: u8 = 0;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    session.loadTranscriptAsync(.{
        .ctx = &ctx_byte,
        .provider = .codex,
        .run = Ctx.run,
        .destroy = Ctx.destroy,
    });
    session.joinForTest();

    try std.testing.expectEqual(TranscriptState.ready, session.transcript_state);
    try std.testing.expectEqual(@as(usize, 1), session.transcript.len);
    try std.testing.expectEqualStrings("async-hello", session.transcript[0].content);
}

test "ai_history_session: publishTranscript discards stale generation" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.transcript_generation = 3;

    const messages = try allocator.alloc(types.TranscriptMessage, 1);
    messages[0] = .{ .role = .user, .content = try allocator.dupe(u8, "stale") };
    // generation 1 != current 3 -> freed, not published (testing allocator checks no leak)
    session.publishTranscript(1, .codex, messages);

    try std.testing.expectEqual(@as(usize, 0), session.transcript.len);
}
```

- [ ] **Step 4: Run the test**

Run: `zig build test`
Expected: PASS, no leaks.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat: run ai history transcript load on a background worker thread

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: AppWindow async entry points + worker jobs

Wire the new Session API into AppWindow with owned jobs. AppWindow GUI globals are not unit-tested here; verification is compile + full suite green.

**Files:**
- Modify: `src/AppWindow.zig` (imports ~43; `aiHistoryScanLocalNow` 768-772; `aiHistoryPreviewSelectedTranscript` 693-697; `ScanRunner`/`PreviewTranscriptRunner`/`withAiHistoryScannerHost`/`saveAiHistoryMetadataCache` 774-863)

- [ ] **Step 1: Add the `ssh_connection` import**

Near the other `ai_history_*` imports (~line 45):

```zig
const ssh_connection = @import("ssh_connection.zig");
```

- [ ] **Step 2: Add the target snapshot type and job structs**

Add (place near the existing `AiHistoryHostAction` definition, ~line 774, replacing the old runner machinery you will delete in Step 4):

```zig
/// Everything a background AI History worker needs, snapshotted on the UI thread.
/// `ssh` carries a copied `SshConnection` value (inline buffers, no threadlocal
/// pointers). `local`/`wsl` resolve their inputs inside the worker.
const AiHistoryTarget = union(enum) {
    local,
    wsl,
    ssh: ssh_connection.SshConnection,
};

const AiHistoryScanJob = struct {
    target: AiHistoryTarget,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, source: ai_history_source.Source) anyerror!ai_history_session.ScanResult {
        const job: *AiHistoryScanJob = @ptrCast(@alignCast(ctx));
        switch (job.target) {
            .local => {
                const home = try localHomeForAiHistory(allocator);
                defer allocator.free(home);
                var parsed_cache = ai_history_cache.loadDefault(allocator) catch null;
                defer if (parsed_cache) |*cache| cache.deinit();
                var host_state = ai_history_session.LocalScannerHost{
                    .home = home,
                    .cache = if (parsed_cache) |cache| cache.value else null,
                };
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source);
            },
            .wsl => {
                var host_state = ai_history_session.WslScannerHost{};
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source);
            },
            .ssh => |conn| {
                var host_state = ai_history_session.SshScannerHost{ .conn = conn };
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source);
            },
        }
    }

    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *AiHistoryScanJob = @ptrCast(@alignCast(ctx));
        allocator.destroy(job);
    }
};

const AiHistoryTranscriptJob = struct {
    target: AiHistoryTarget,
    meta: ai_history_types.SessionMeta, // owned clone

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]ai_history_types.TranscriptMessage {
        const job: *AiHistoryTranscriptJob = @ptrCast(@alignCast(ctx));
        switch (job.target) {
            .local => {
                var host_state = ai_history_session.LocalScannerHost{ .home = "" };
                const host = host_state.scannerHost();
                return host.loadTranscript(host.ctx, allocator, job.meta);
            },
            .wsl => {
                var host_state = ai_history_session.WslScannerHost{};
                const host = host_state.scannerHost();
                return host.loadTranscript(host.ctx, allocator, job.meta);
            },
            .ssh => |conn| {
                var host_state = ai_history_session.SshScannerHost{ .conn = conn };
                const host = host_state.scannerHost();
                return host.loadTranscript(host.ctx, allocator, job.meta);
            },
        }
    }

    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *AiHistoryTranscriptJob = @ptrCast(@alignCast(ctx));
        ai_history_session.freeMetadata(allocator, job.meta);
        allocator.destroy(job);
    }
};

/// Snapshot the source's target into a worker-safe value (UI thread). Returns
/// null only when an SSH profile cannot be resolved.
fn aiHistoryTargetSnapshot(target: ai_history_source.Target) ?AiHistoryTarget {
    return switch (target) {
        .local => .local,
        .wsl => .wsl,
        .ssh => |ssh| .{ .ssh = overlays.aiHistorySshConnection(ssh.profile_name) orelse return null },
    };
}

/// Kick off an async scan for `session`. UI thread. On setup failure marks the
/// session failed instead of spawning a doomed worker.
fn startAiHistoryScan(allocator: std.mem.Allocator, session: *ai_history_session.Session) void {
    const target = aiHistoryTargetSnapshot(session.source.target) orelse {
        session.mutex.lock();
        session.state = .failed;
        session.status = "SSH profile unavailable";
        session.mutex.unlock();
        return;
    };
    const job = allocator.create(AiHistoryScanJob) catch {
        session.mutex.lock();
        session.state = .failed;
        session.status = "Scan failed";
        session.mutex.unlock();
        return;
    };
    job.* = .{ .target = target };
    session.scanAsync(.{ .ctx = job, .run = AiHistoryScanJob.run, .destroy = AiHistoryScanJob.destroy });
}

/// Kick off an async transcript load for the selected row. UI thread.
fn startAiHistoryTranscript(allocator: std.mem.Allocator, session: *ai_history_session.Session) void {
    session.mutex.lock();
    const selected = session.selectedVisible();
    const meta_clone: ?ai_history_types.SessionMeta = if (selected) |m|
        (ai_history_session.cloneMetadata(allocator, m) catch null)
    else
        null;
    session.mutex.unlock();

    const meta = meta_clone orelse return;

    const target = aiHistoryTargetSnapshot(session.source.target) orelse {
        ai_history_session.freeMetadata(allocator, meta);
        session.mutex.lock();
        session.transcript_state = .failed;
        session.transcript_status = "SSH profile unavailable";
        session.mutex.unlock();
        return;
    };
    const job = allocator.create(AiHistoryTranscriptJob) catch {
        ai_history_session.freeMetadata(allocator, meta);
        return;
    };
    job.* = .{ .target = target, .meta = meta };
    session.loadTranscriptAsync(.{
        .ctx = job,
        .provider = meta.provider,
        .run = AiHistoryTranscriptJob.run,
        .destroy = AiHistoryTranscriptJob.destroy,
    });
}
```

Note: `AiHistoryScanJob.run`'s `source` parameter uses `ai_history_source.Source` (AppWindow already imports the source module as `ai_history_source` at line 47). This is the same type as `ai_history_session`'s private `source_mod.Source` (both `@import("ai_history_source.zig")`), so the `ScanWork.run` function-pointer type matches.

- [ ] **Step 3: Rewrite the two entry points**

Replace `aiHistoryScanLocalNow` (768-772):

```zig
pub fn aiHistoryScanLocalNow() bool {
    const session = activeAiHistory() orelse return false;
    const allocator = g_allocator orelse return false;
    startAiHistoryScan(allocator, session);
    return true;
}
```

Replace `aiHistoryPreviewSelectedTranscript` (693-697):

```zig
pub fn aiHistoryPreviewSelectedTranscript() bool {
    const session = activeAiHistory() orelse return false;
    const allocator = g_allocator orelse return false;
    startAiHistoryTranscript(allocator, session);
    return true;
}
```

- [ ] **Step 4: Delete the obsolete synchronous machinery**

Delete these now-unused items from `src/AppWindow.zig`:
- `const AiHistoryHostAction` and `const AiHistoryHostRunner` (~774-775)
- `const PreviewTranscriptRunner` (~777-789)
- `const ScanRunner` (~791-803)
- `fn withAiHistoryScannerHost` (~805-843)
- `fn saveAiHistoryMetadataCache` (~845-850)
- `fn failAiHistoryHostUnavailable` (~852-863)

Keep `localHomeForAiHistory` (now called by `AiHistoryScanJob.run`).

- [ ] **Step 5: Build and run the full suite**

Run: `zig build test && zig build test-full`
Expected: both exit 0; no references to the deleted symbols remain. If the build reports `withAiHistoryScannerHost`/`ScanRunner`/etc. still referenced, find and update that caller (e.g. the mouse `.refresh` branch already calls `aiHistoryScanLocalNow`, which is unchanged).

- [ ] **Step 6: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat: drive ai history scan/preview through async worker jobs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Lock the render and input/mouse dispatch

Guard every UI-thread access to the session's shared fields. No lock nesting (see Locking Contract).

**Files:**
- Modify: `src/AppWindow.zig` — `renderAiHistoryFrame` (617-636); `aiHistoryInsertCodepoint` (667-676); `aiHistoryBackspaceFilter` (678-683); `aiHistoryMoveSelection` (685-691); `aiHistoryHandleMousePress` (865-904); `resumeAiHistorySelection` (703-709)

- [ ] **Step 1: Lock around the render call**

In `renderAiHistoryFrame`, wrap the `ai_history_renderer.render(...)` call:

```zig
    if (active_tab.ai_history_session) |session| {
        const draw: ai_history_renderer.DrawContext = .{
            .bg = g_theme.background,
            .fg = g_theme.foreground,
            .accent = g_theme.cursor_color,
            .cell_h = font.g_titlebar_cell_height,
            .fillQuad = ui_pipeline.fillQuad,
            .fillQuadAlpha = ui_pipeline.fillQuadAlpha,
            .renderTextLimited = titlebar.renderTextLimited,
        };
        session.mutex.lock();
        defer session.mutex.unlock();
        ai_history_renderer.render(
            draw,
            session,
            @floatFromInt(fb_width),
            @floatFromInt(fb_height),
            titlebar_offset,
            left_panels_w,
            aiHistoryContentWidth(fb_width, left_panels_w, right_panels_w),
        );
    }
```

- [ ] **Step 2: Lock the filter/selection handlers**

`aiHistoryInsertCodepoint` — keep the space-key early return *before* taking the lock (it calls preview, which locks), then lock only around `appendFilterBytes`:

```zig
pub fn aiHistoryInsertCodepoint(codepoint: u21) bool {
    const session = activeAiHistory() orelse return false;
    if (codepoint == ' ') return aiHistoryPreviewSelectedTranscript();
    if (codepoint < 0x20 or codepoint == 0x7f) return false;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return false;
    session.mutex.lock();
    session.appendFilterBytes(buf[0..len]);
    session.mutex.unlock();
    markUiDirty();
    return true;
}
```

`aiHistoryBackspaceFilter`:

```zig
pub fn aiHistoryBackspaceFilter() bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    session.backspaceFilter();
    session.mutex.unlock();
    markUiDirty();
    return true;
}
```

`aiHistoryMoveSelection`:

```zig
pub fn aiHistoryMoveSelection(delta: isize) bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    session.moveSelection(delta);
    session.ensureSelectionVisible(aiHistoryListVisibleRowsForWindow());
    session.mutex.unlock();
    markUiDirty();
    return true;
}
```

Note: `aiHistoryListVisibleRowsForWindow()` reads only window/framebuffer size, not session state, so calling it inside the lock is safe and introduces no nesting.

- [ ] **Step 3: Lock the mouse handler's hit-test, then dispatch unlocked**

Rewrite the body of `aiHistoryHandleMousePress` (865-904) so the lock covers only `interactionHitTest`, then dispatch after releasing:

```zig
pub fn aiHistoryHandleMousePress(xpos: f64, ypos: f64) bool {
    const session = activeAiHistory() orelse return false;
    const win = g_window orelse return true;
    const fb = window_backend.framebufferSize(win);
    const left = leftPanelsWidth();
    const right = rightPanelsWidthForWindow(fb.width);
    const width = @as(f32, @floatFromInt(fb.width)) - left - right;
    const visible_rows = ai_history_renderer.listVisibleCapacity(@floatFromInt(fb.height), currentTitlebarHeight());

    session.mutex.lock();
    const hit = ai_history_renderer.interactionHitTest(
        session,
        @floatFromInt(fb.width),
        @floatFromInt(fb.height),
        currentTitlebarHeight(),
        left,
        width,
        font.g_titlebar_cell_height,
        xpos,
        ypos,
    );
    session.mutex.unlock();

    switch (hit) {
        .none => {},
        .refresh => {
            _ = aiHistoryScanLocalNow();
            return true;
        },
        .@"resume" => {
            _ = resumeAiHistorySelection();
            markUiDirty();
            return true;
        },
        .row => |visible_index| {
            session.mutex.lock();
            session.selectVisibleIndex(visible_index);
            session.ensureSelectionVisible(visible_rows);
            session.mutex.unlock();
            markUiDirty();
            return true;
        },
    }
    markUiDirty();
    return true;
}
```

- [ ] **Step 4: Clone the resume meta under the lock**

Rewrite `resumeAiHistorySelection` (703-709) so the selected metadata is cloned under the lock and freed after the spawn (its strings would otherwise dangle if a concurrent scan replaced rows):

```zig
pub fn resumeAiHistorySelection() bool {
    const active = tab.activeTab() orelse return false;
    if (active.kind != .ai_history) return false;
    const session = active.ai_history_session orelse return false;
    const allocator = g_allocator orelse return false;

    session.mutex.lock();
    const selected = session.selectedVisible();
    const meta_clone: ?ai_history_types.SessionMeta = if (selected) |m|
        (ai_history_session.cloneMetadata(allocator, m) catch null)
    else
        null;
    session.mutex.unlock();

    const meta = meta_clone orelse return false;
    defer ai_history_session.freeMetadata(allocator, meta);
    return spawnResumeTerminal(session.source.target, meta);
}
```

- [ ] **Step 5: Build and run the full suite**

Run: `zig build test && zig build test-full`
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/AppWindow.zig
git commit -m "fix: guard ai history shared state with the session mutex

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Auto-scan on tab create

**Files:**
- Modify: `src/AppWindow.zig` — `spawnAiHistoryTab` (1409-1414)

- [ ] **Step 1: Kick off the scan after creating the tab**

```zig
pub fn spawnAiHistoryTab(source: ai_history_source.Source) bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnAiHistoryTab(allocator, source)) return false;
    clearUiStateOnTabChange();
    if (activeAiHistory()) |session| startAiHistoryScan(allocator, session);
    return true;
}
```

- [ ] **Step 2: Build and run the full suite**

Run: `zig build test && zig build test-full`
Expected: both exit 0.

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat: auto-scan ai history when a new tab is created

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Final verification

- [ ] **Step 1: Full clean test run**

Run: `zig build test && zig build test-full`
Expected: both exit 0; failed count 0 (baseline ~673/677 passed, 4 skipped, 0 failed — count may be higher with the new tests).

- [ ] **Step 2: Confirm no dead references**

Run: `grep -rn "withAiHistoryScannerHost\|ScanRunner\|PreviewTranscriptRunner\|saveAiHistoryMetadataCache\|scanNowReturningResult" src/`
Expected: no matches in `src/AppWindow.zig`. (`scanNow`/`scanNowReturningResult`/`loadSelectedTranscript` may still exist in `ai_history_session.zig` if its own tests use them — that is fine; they are just no longer called from the UI.)

- [ ] **Step 3: Manual GUI verification (record outcome)**

Build and run the app (`zig build run` or the project's run skill). Verify:
1. New AI History tab (WSL): opens showing "Scanning AI history…" immediately, then populates without pressing `r`; the window stays responsive (can switch tabs, type) during the scan.
2. New AI History tab (SSH profile): same — UI never freezes during the (slow) SSH scan.
3. Press `r` on a populated list: re-scans async, no freeze.
4. Select a row and press `space`: transcript preview loads without freezing.
5. Close the AI History tab during a scan: app does not crash (brief pause up to the SSH round-trip is expected and acceptable).

Note: GUI verification is manual — there is no Linux GUI backend in CI; record the result in the commit/PR description.

---

## Self-Review Notes

- **Spec coverage:** scan async (Tasks 1-2, 4), transcript async (Task 3, 4), locking render+input (Task 5), auto-scan on create (Task 6), deinit-join lifetime option A (Task 2/3), cache save moved into worker (Task 1 `publishScanResult`), resume out of scope (not implemented, by design). All covered.
- **Generation/closing:** publish helpers check both; deinit sets closing then joins → UAF-safe by construction.
- **No lock nesting:** verified for the space-key→preview path, the mouse refresh/resume/row paths, and move/backspace/insert handlers.
- **Type consistency:** `AiHistoryTarget`, `AiHistoryScanJob`, `AiHistoryTranscriptJob`, `ScanWork`, `TranscriptWork`, `publishScanResult`, `publishTranscript`, `cloneMetadata`, `freeMetadata`, `joinForTest`, `startAiHistoryScan`, `startAiHistoryTranscript`, `aiHistoryTargetSnapshot` used consistently across tasks.
- **Source type resolved:** AppWindow's job `run` uses `ai_history_source.Source` (AppWindow import at line 47); identical underlying type to the session's private `source_mod.Source`, so the `ScanWork.run` function-pointer type matches.
