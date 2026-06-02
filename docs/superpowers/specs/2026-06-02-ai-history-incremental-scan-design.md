# AI History Incremental Scan — Design

Date: 2026-06-02
Status: Approved (design); ready for implementation planning
Related: `2026-06-02-async-ai-history-scan-design.md` (PR #120, made the scan async), `2026-06-01-ai-history-session-design.md`

## Problem

Scanning Claude Code / Codex agent history takes a long time, and the AI History
list shows nothing but "Scanning AI history…" until the *entire* scan finishes.
Users want results to appear progressively — "扫到 10 个就先显示 10 个" — and want
reopening the panel to show the previous results instantly instead of re-scanning
from a blank list every time.

## Current behavior (root cause)

The scan is already async (background worker, PR #120) so the UI no longer
freezes, but it is still "all or nothing":

| Stage | Local | Remote (WSL/SSH) |
|---|---|---|
| Collect candidate files | walk + `statFile` (fast) | one `find` exec (fast) |
| Parse each file's metadata | open + read + parse, **cached** (slow) | **one `cat` round-trip per file**, **no cache** (slowest) |
| Display | `publishScanResult` once at the very end | same |

Key facts established while exploring:

- **The render loop is continuous.** `AppWindow.zig` uses `pollEvents` (not
  `waitEvents`) and calls `renderAiHistoryFrame` + `swapBuffers` every iteration
  when the active tab is `.ai_history`. The renderer reads `session.rows` under
  `session.mutex` each frame. **Therefore, if the worker appends rows under the
  mutex, the next frame displays them — no wakeup/dirty signal is needed.**
- **Nothing is persisted between opens.** `AiHistorySnap` stores only the source
  identity (`source_id`, `target_kind`, `target_name`); each open re-scans. The
  on-disk `ai_history_cache` avoids *re-parsing* unchanged files but the walk +
  stat + clone still runs every time.
- **The cache already holds everything for instant-reopen.** `CacheRecord`
  stores the full `SessionMeta` keyed by `source_id`/`provider`/`source_path`.
- **The remote path is the slowest and has no cache.** `RemoteScan.scanPath`
  runs a separate `cat` per file, files arrive in `find` order (not recency).

## Goals

1. **Streaming**: rows appear progressively, most-recent-first, as the scan
   parses them, with a live count in the status line.
2. **Instant-reopen**: reopening AI History shows the previous results instantly,
   then refreshes/reconciles in the background.

## Non-goals

- Changing the transcript-load path (already async, untouched).
- A new persistence file: instant-reopen reuses the existing `ai_history_cache`.
- Streaming individual *transcript* messages (this is about the session list).

## Approach

Approach A (chosen), delivered in two phases:

- **Phase 1 — Streaming** (local + remote): a row-sink seam lets the worker
  publish rows in batches; the continuous render loop displays them live.
- **Phase 2 — Instant-reopen**: emit cached rows as a provisional "batch 0"
  before walking; extend caching to the remote path (which also fixes remote's
  no-cache / N-round-trips / unsorted weaknesses).

Two phases because Phase 1 delivers the headline behavior and is independently
shippable and verifiable; Phase 2 layers on top using the same finalize seam.

---

## Phase 1 — Streaming

### 1.1 The `ScanSink` seam

In `ai_history_session.zig`:

```zig
pub const ScanSink = struct {
    ctx: *anyopaque,
    /// Deliver a batch of freshly-scanned rows for live display. The sink takes
    /// ownership of `rows` (slice + row string fields) regardless of return
    /// value. Returns false when this scan generation is stale or the session is
    /// closing — the worker should stop early and free remaining work.
    publish: *const fn (ctx: *anyopaque, rows: []types.SessionMeta) bool,
};
```

### 1.2 `Session.appendScanRows`

```zig
/// Worker-thread entry. If `generation` is still current and we are not closing,
/// move `rows` into `self.rows` (no re-clone) so the next frame shows them and
/// return true. Otherwise free `rows` and return false (stop early).
pub fn appendScanRows(self: *Session, generation: u64, rows: []types.SessionMeta) bool;
```

Ownership / concurrency contract:

- Batch row strings are allocated with `session.allocator` (the same allocator
  `scanThreadMain` passes to `run` and that `self.rows` uses). So the sink
  **moves** the row structs into `self.rows` (`appendSlice`) and frees only the
  batch's backing slice array (`allocator.free(rows)`); the strings live on,
  now owned via `self.rows`.
- On stale/closing (or OOM on append): `freeRows(allocator, rows)` + `free(rows)`.
- Runs entirely under `session.mutex`; critical section is one `appendSlice` per
  batch. `scan_generation` / `closing` reuse the existing async mechanism.
- Does **not** reset `self.selected` (append-only in recency order keeps earlier
  visible indices — and thus the selection — stable). `selected` starts at 0 so
  the most-recent row is selected once the first batch lands.

### 1.3 Threading the sink through the seam

- Add `sink: ?ScanSink` to both function-pointer signatures:
  - `ScanWork.run: fn(*anyopaque, Allocator, Source, ?ScanSink) anyerror!ScanResult`
  - `ScannerHost.scan: fn(*anyopaque, Allocator, Source, ?ScanSink) anyerror!ScanResult`
- `scanThreadMain` builds a sink from `session` + `generation`, passes it to
  `run`, and on return calls `finishScan` (see 1.5):

  ```zig
  fn scanThreadMain(session: *Session, work: ScanWork, generation: u64) void {
      defer work.destroy(work.ctx, session.allocator);
      var stream = StreamCtx{ .session = session, .generation = generation };
      const sink = ScanSink{ .ctx = &stream, .publish = StreamCtx.publish };
      const result = work.run(work.ctx, session.allocator, session.source, sink) catch {
          session.publishScanFailure(generation);
          return;
      };
      session.finishScan(generation, result);
  }
  ```

  `StreamCtx.publish` calls `session.appendScanRows(generation, rows)`.
- **`sink == null`** path (`scanNow`, all existing tests) behaves exactly as
  today: accumulate all rows, return a full `ScanResult`. Existing tests need
  only a mechanical `null` argument added to their `run`/`scan` calls.

### 1.4 Scan-loop batching (`RowEmitter`)

A small helper shared by `LocalScan` and `RemoteScan`:

- With a sink: append parsed rows to a `pending` buffer; when it reaches the
  batch size (~12) or at end-of-scan, `toOwnedSlice` it and call `sink.publish`.
  If `publish` returns false, set `aborted` so the scan loops `break` early. In
  this streaming-cold mode the scanner returns `ScanResult{ .rows = &.{},
  .authoritative = false, ... }` (rows already went to the sink).
- Without a sink (sync/test): append to `scanner.rows` as today; return them with
  `authoritative = true`.

Local candidates are already sorted mtime-descending and parsed in that order, so
streaming is naturally most-recent-first. `cache_update` is still produced in
both modes (so the cache keeps getting written for warm rescans / Phase 2).

`ScanResult` gains `authoritative: bool = true`. The default keeps existing
behavior for sync callers and tests that build a `ScanResult` directly; only the
streaming-cold scanner sets it `false`.

### 1.5 `finishScan` (one branch covers both phases, streaming and sync)

```zig
pub fn finishScan(self: *Session, generation: u64, result: ScanResult) void {
    // under self.mutex:
    //   stale/closing -> freeScanResult(result); return;
    //   if (result.authoritative) replaceRows(result.rows);            // sync/test/warm: full set
    //   else                      sortRowsInPlacePreservingSelection(); // streaming-cold: rows already present
    //   state = .ready; status = countStatus(self.rows.items.len, warnings);
    //   save cache if result.cache_update.records.len > 0
    //   freeScanResult(result);
}
```

- Branch on `result.authoritative`, **not** on `result.rows.len`. The
  authoritative branch (`replaceRows`) handles the empty case correctly — e.g.
  warm cache where every file is now deleted yields an authoritative empty set
  that must *clear* the provisional rows, not keep them.
- Streaming-cold (`authoritative == false`): everything was streamed into
  `self.rows`; we only do a final `lessRecent` sort. Empty cold scan → empty +
  ready (shows "No history").
- `replaceRows` must **preserve selection by `session_id`** (capture the
  selected row's id before swap, restore its visible index after; fall back to
  0). This replaces the current unconditional `selected = 0`. (Keep `replaceRows`
  cloning semantics so the sync path and tests that pass static rows still work.)
- This is the existing `publishScanResult` evolved; it is the only finalize the
  async worker calls.

### 1.6 Renderer — live count

When `session.state == .scanning`, compose `"Scanning… {N}"` (N =
`session.rows.items.len`) into a stack buffer in the render function and pass it
to `renderTextLimited`. No new field on `Session`. Keep the empty-state text for
the zero-rows-while-scanning case.

### Phase 1 explicitly excludes

Instant-reopen (provisional batch 0), remote caching, and remote mtime-sorted
`find`. In Phase 1 the remote path streams in discovery order and `finishScan`'s
final sort puts it in recency order on completion.

---

## Phase 2 — Instant-reopen + remote cache

### 2.1 Local instant-reopen via the cache

- New `ai_history_cache.rowsForSource(allocator, cache, source_id) ![]SessionMeta`
  clones the cached `meta` of every record matching `source_id`.
- In `scanLocalFilesystemWithCache`, when a sink and a cache are present, emit the
  source's cached rows as a provisional **batch 0** *before* walking → instant
  display on reopen. Then choose behavior by cache state:

| State | During scan | `ScanResult` | `finishScan` |
|---|---|---|---|
| **Warm** (cache has rows for this source) | provisional batch 0 shows instantly; walk **accumulates** the authoritative set into `scanner.rows` (cache-hit files are not re-read) | `authoritative = true`, full set | `replaceRows` — seamless swap; prunes deleted files, adds new ones, preserves selection by id (empty set correctly clears provisional rows) |
| **Cold** (first scan / no cached rows) | Phase 1 per-row streaming | `authoritative = false`, rows empty | in-place sort |

The **same** `finishScan` branch (`result.authoritative ? replace : sort`)
covers both, so no dedup logic is needed: cold streams + sorts; warm shows
provisional rows then replaces with the authoritative set. In the warm case, rows
discovered during the walk are not streamed individually (the cache already shows
everything); they appear when `finishScan` swaps in the authoritative set.

### 2.2 Remote caching (fixes three remote weaknesses at once)

- Thread a cache into `RemoteScan` (loaded on the UI thread and passed via the
  job, like local does).
- Extend the `find` command to emit mtime + size + path in one shot, sorted by
  mtime descending, with a plain-`find` fallback for environments without GNU
  `find -printf` (e.g. BSD):

  ```sh
  find R -type f -name '*.jsonl' -size -2048k -printf '%T@\t%s\t%p\n' 2>/dev/null \
    | sort -rn | head -500
  # if empty -> retry: find R -type f -name '*.jsonl' -size -2048k | head -500
  ```

- `RemoteScan` parses each line as `(mtime, size, path)` split on `\t`; a line
  with no tab is treated as a path with mtime 0 (fallback output).
- Benefits: **(1)** rows stream most-recent-first; **(2)** files whose
  `(size, mtime)` match the cache **skip the `cat`** (warm remote rescans avoid
  almost all round-trips); **(3)** `cache_update` is produced so remote also gets
  instant-reopen.

---

## Concurrency contract (summary)

- `session.mutex` guards `rows`, `selected`, `state`, `status`, `scan_generation`,
  `closing` (existing contract). Worker holds it only briefly per batch and at
  `finishScan`; the render loop holds it per frame. Critical sections stay short.
- Every new scan bumps `scan_generation`. `appendScanRows` and `finishScan` check
  `generation` + `closing`; a stale/closing call frees its payload and (for the
  sink) returns false so the worker aborts early — superseding an in-flight scan
  cleanly (consistent with `ba2cd53`).
- `deinit` continues to set `closing` and join the worker.

## Testing

- **`appendScanRows`**: current generation → appended + visible; stale generation
  → freed + returns false; closing → freed + returns false.
- **`finishScan` both branches**: non-empty `result.rows` → `replaceRows` (incl.
  deleted-file pruning); empty → in-place sort + `ready`.
- **Streaming integration (cold)**: a pumpable fake sink delivering 3 batches →
  assert `rows` grows across batches and the end state is `ready` and sorted.
- **Selection preservation**: select id X, `replaceRows` with a reordered set →
  still selected X.
- **Local scanner with sink, cold cache**: `result.rows` empty; the session
  received streamed rows in recency order.
- **Instant-reopen (warm)**: cache has rows → provisional batch 0 emitted before
  the walk; `finishScan` replaces with the authoritative set (deleted pruned, new
  added).
- **Remote**: `find` command builder (mtime sort + fallback); `\t` parsing;
  cache-hit skips `cat`; cache round-trip.
- **Signature migration**: existing `run`/`scan` tests pass `null` sink and keep
  their current assertions.

## Files touched (anticipated)

- `src/ai_history_session.zig` — `ScanSink`, `appendScanRows`, `finishScan`,
  `RowEmitter`, sink params on `ScanWork.run` / `ScannerHost.scan`,
  `scanThreadMain`, `replaceRows` selection preservation; Phase 2 provisional
  batch 0 + `RemoteScan` cache + find command.
- `src/ai_history_cache.zig` — `rowsForSource`.
- `src/AppWindow.zig` — `AiHistoryScanJob.run` sink param; pass a cache into the
  remote job (Phase 2).
- `src/renderer/ai_history_renderer.zig` — live "Scanning… N" status.
- Tests alongside the above.
```