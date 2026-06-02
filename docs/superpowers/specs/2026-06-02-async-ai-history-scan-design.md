# Async AI History Scan & Preview Design

## Goal

Stop the AI History browser from freezing the UI. Today, scanning a source
(local/WSL/SSH) and loading a transcript preview both run **synchronously on the
main render+input thread**. For WSL and SSH sources these perform blocking
subprocess / network I/O, so the entire window stops responding until the work
completes.

Move the blocking work to a background worker thread, following the existing
`ai_chat.zig` worker model, and auto-start the scan when an AI History tab is
created so the user never has to press `r` to populate it.

## Problem (Root Cause)

The blocking call chain on the UI thread:

- `r` key (`input.zig:1170`) or refresh click (`AppWindow.zig:887`)
  → `aiHistoryScanLocalNow` → `withAiHistoryScannerHost` → `ScanRunner.run`
  → `Session.scanNowReturningResult` → `host.scan` → `scanRemoteFilesystem`.
- WSL: `wslExec` spawns `wsl.exe` and drains stdout to completion (blocking).
- SSH: `sshExecCapture` spawns `ssh` with `ConnectTimeout=8`, **once per remote
  round-trip**. A scan does a home lookup plus per-provider-root listing plus a
  metadata read per file, so a single scan can be dozens of blocking SSH
  handshakes → tens of seconds of frozen render+input.
- Transcript preview (`space` → `aiHistoryPreviewSelectedTranscript`
  → `loadSelectedTranscript` → `host.loadTranscript`) hits the same blocking
  remote I/O path.

The main loop (`runMainLoop`) renders continuously via non-blocking
`window_backend.pollEvents`, redrawing every frame. So a background worker only
needs to update shared `Session` state under a lock; the next frame reflects it.
This is the same mechanism that lets `ai_chat` streaming updates appear.

## Scope

In scope (the operations that actually block the UI thread):

- **Scan** — `Session.scanNowReturningResult` / `aiHistoryScanLocalNow`.
- **Transcript preview** — `Session.loadSelectedTranscript` /
  `aiHistoryPreviewSelectedTranscript`.

Out of scope:

- **Resume (`Enter`)** — `spawnResumeTerminal` only builds command strings and
  calls `spawnTabWithCommandAndCwd`, which spawns a PTY child (ssh/wsl/shell)
  that connects asynchronously in its own reader thread. It does **no**
  synchronous network I/O on the UI thread, so it is already non-blocking.
  Adding async machinery here would be a no-op; leave it as is.

## Reference Pattern

`ai_chat.zig` already solves the "blocking work off the UI thread" problem:

- `request_thread: ?std.Thread` stored on the session.
- `closing: std.atomic.Value(bool)` set in `deinit`.
- `deinit` does `closing.store(true)` then `thread.join()` before freeing.
- The worker periodically checks `closing.load(.acquire)` and bails early.

The AI History fix mirrors this exactly.

## Design

### 1. Session async state (`ai_history_session.zig`)

Add to `Session`:

- `mutex: std.Thread.Mutex = .{}` — guards the worker-shared fields: `state`,
  `status`, `rows`, `selected`, `list_offset`, and the `transcript*` fields.
- `scan_thread: ?std.Thread = null`
- `transcript_thread: ?std.Thread = null`
- `closing: std.atomic.Value(bool) = .init(false)`
- `scan_generation: u64 = 0`
- `transcript_generation: u64 = 0`

The generation counters let a newer request supersede an older in-flight one:
a re-scan, or selecting a different transcript before the previous load
finished. When a worker finishes it compares the generation it was launched
with against the current value under the lock; if they differ (or `closing` is
set) it discards its result instead of writing it.

### 2. Worker job context

Blocking work must not read threadlocal UI state. Each worker gets a
heap-allocated, owned job:

```
ScanJob = struct {
    session: *Session,
    generation: u64,
    target: TargetSnapshot,   // local | wsl | ssh(SshConnection value)
};
TranscriptJob = struct {
    session: *Session,
    generation: u64,
    target: TargetSnapshot,
    meta: SessionMeta,        // owned copy of the selected row
};
```

`TargetSnapshot` carries everything the blocking call needs:

- **local** — nothing; the worker resolves `home` (env `USERPROFILE`/`HOME`,
  process-global) and loads the metadata cache from disk inside the worker.
- **wsl** — nothing; `WslScannerHost` is stateless.
- **ssh** — a **snapshotted `SshConnection` value**. `aiHistorySshConnection`
  is a pure builder that copies profile fields into a self-contained struct with
  inline buffers (no pointers into threadlocal `g_ssh_profiles`), so the value is
  safe to copy to the worker. The snapshot is taken on the UI thread at spawn
  time.

The job is allocated with the app allocator and freed by the worker when it
exits.

### 3. UI entry points become non-blocking (`AppWindow.zig`)

- `aiHistoryScanLocalNow`: under the session lock, set `state = .scanning`,
  `status = "Scanning"`, bump `scan_generation`; build the `TargetSnapshot`
  (snapshot SSH conn on the UI thread); join any prior `scan_thread`; spawn the
  scan worker; return immediately.
- `aiHistoryPreviewSelectedTranscript`: same shape with `transcript_state`,
  `transcript_generation`, an owned copy of the selected `SessionMeta`, and the
  transcript worker.

Joining the prior thread of the *same kind* before spawning a new one keeps at
most one scan worker and one transcript worker per session, and bounds thread
lifetime. (A fresh request's blocking predecessor is rare; if it happens the
join waits for the predecessor's current round-trip, same bound as close.)

### 4. Worker bodies

```
scanWorkerMain(job):
    result = run host.scan(...)   // long, blocking, NO lock held
    lock session.mutex
        if session.closing or job.generation != session.scan_generation:
            unlock; free result; free job; return
        replaceRows(result.rows)      // swaps rows, resets selected/offset, state=.ready
        status = warning ? "Ready with warnings" : "Ready"
    unlock
    saveAiHistoryMetadataCache(result.cache_update)   // disk I/O, off UI thread
    free result; free job
on error: lock; if current generation && !closing -> state=.failed, status set; unlock
```

`transcriptWorkerMain` is the analogue for `host.loadTranscript`, writing
`transcript`, `transcript_provider`, `transcript_state`.

The long `host.scan` / `host.loadTranscript` call runs **outside** the lock.
Only the brief final swap takes the lock.

### 5. Render + input take the lock

`ai_history_renderer.render` and the AI-history key/mouse handlers read/mutate
the shared fields, so they must hold `session.mutex` while doing so. These are
short (per-frame render; occasional input), and the worker holds the lock only
for the brief swap, so contention is negligible. Selection/filter mutations
(UI-thread-only) are also wrapped because `replaceRows` (worker) resets
`selected`/`list_offset`.

Implementation note: wrap the render and the input dispatch for AI-history at a
single coarse point each, rather than sprinkling locks through every helper, to
keep the locking obvious and avoid double-lock/recursion.

### 6. Auto-scan on create

The `AppWindow.spawnAiHistoryTab` wrapper (UI thread) snapshots the SSH conn (if
the source is SSH) and kicks off the async scan immediately after the tab is
created, so the tab shows "Scanning AI history…" and then populates without the
user pressing `r`. Manual `r` / refresh re-scan still works (async).

### 7. Lifetime on tab close — option (A), join on deinit

`Session.deinit` (called when the tab closes):

```
closing.store(true, .release)
if scan_thread: join; scan_thread = null
if transcript_thread: join; transcript_thread = null
... existing free of rows/transcript/source ...
```

This mirrors `ai_chat` exactly and eliminates use-after-free: the worker's
`*Session` stays valid because `deinit` waits for the worker to return before
freeing. Accepted tradeoff: closing a tab *during* an in-flight SSH scan blocks
the UI for up to the current round-trip (≤ ~8s connect timeout) until the worker
returns. The window for this is small (close must land mid-scan) and the worker
bails as soon as the current `exec` returns, so the cost is bounded and matches
the proven `ai_chat` model. Option (B) (detach + orphan) was rejected for the
extra refcounting / UAF surface.

## Error Handling

- Worker scan/transcript failure → under lock, if still current and not closing,
  set `state=.failed` / `transcript_state=.failed` with a status string; the
  renderer already shows the failed states.
- Host unavailable (SSH profile gone, home unresolvable) is detected on the UI
  thread before spawning (or in the worker for local home) and sets the failed
  state without spawning a doomed worker where possible.
- Stale results (superseded generation or `closing`) are silently discarded and
  freed.

## Testing

`ai_history_session.zig` already has unit tests using fake scanner hosts
(`scan` fns returning canned `ScanResult`). Add tests for:

- A scan worker writes rows and flips `.scanning` → `.ready` (drive the worker
  function directly, or `join` the spawned thread, then assert state/rows).
- A superseded generation result is discarded (bump generation before the worker
  swaps; assert rows unchanged).
- `closing` set before swap discards the result and frees cleanly (no leak under
  the testing allocator).
- `deinit` while a worker is "in flight" joins without UAF/leak (use a fake host
  whose `scan` blocks on a signal the test releases).
- Transcript worker analogues for the above.

Full suite: `zig build test` (fast) and `zig build test-full` must stay green
(current baseline ~673/677 passed, 4 skipped, 0 failed).

## Files Touched

- `src/ai_history_session.zig` — async state, worker bodies, generation/closing
  logic, `deinit` join, locking helpers, tests.
- `src/AppWindow.zig` — non-blocking entry points, `TargetSnapshot` build + SSH
  snapshot, auto-scan on create, lock around render/input dispatch, move cache
  save into worker.
- `src/renderer/ai_history_renderer.zig` — read under lock (or via a locked
  snapshot helper).
- `src/input.zig` — AI-history input dispatch under lock (coarse).
- Possibly `src/appwindow/tab.zig` — auto-scan hook point if `spawnAiHistoryTab`
  is the chosen kickoff site.
