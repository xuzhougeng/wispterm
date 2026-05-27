# B3 — Decouple `AppWindow.zig` (presentation/logic separation)

Phase B, item B3 of the cross-platform portability roadmap
([TODO.md](../../../TODO.md)). Follows the B1/B2 pattern.

## Goal

Extract the remaining pure decision/geometry logic out of `src/AppWindow.zig`
(4,045 ln, 47 globals) into std-only, unit-testable modules, leaving the window
orchestration / frame loop / threads / GL untouched.

## Current state (and why B3 is smaller than B1/B2)

`AppWindow.zig` is the window-orchestration hub: the platform event/frame loop,
GL frame rendering, tab/split lifecycle, IME, agent-history persistence, weixin
integration, config reload. Most of it is inherently impure (calls
`window_backend.*`, owns threads/mutexes, drives the renderer).

Crucially, **the "tab/split orchestration" that B3 names is already layered out**
by prior work: `src/appwindow/tab.zig` (49.6 KB) owns tab/split lifecycle,
`src/appwindow/split_layout.zig` owns split geometry, `src/appwindow/thread_message.zig`
owns the thread-message types. Render orchestration is the frame loop (GL/window
calls — not pure). So B3's genuinely-extractable pure logic is narrower than
B1/B2's. Two clean clusters remain:

1. **IME caret** — `syncImeCaretPosition` mixes (a) a pure two-frame *stability /
   commit* decision over 6 `threadlocal` globals (`g_ime_caret_last_sample_*`,
   `g_ime_caret_committed_*`) and (b) the pure *cell→pixel* placement math, with
   the impure `window_backend.setImeCaret` call. The candidate-selection half is
   already extracted (`src/ime_caret.zig`: `candidateScore`/`isBetterCandidate`).
2. **Agent-history flush** — `flushAgentHistoryStoreIfDirty` mixes a pure
   *debounce* decision over `g_agent_history_dirty` / `g_agent_history_next_flush_ms`
   with the mutex + store snapshot + file I/O.

## Design — extend one module, add one

### 1. Extend `src/ime_caret.zig` (std-only; already in `test_fast.zig`)

Add:
- `pub const Source = enum { terminal_cursor, visual_inverse };` (moved from
  AppWindow's private `ImeCaretSource`).
- `pub const Sample = struct { x: i64, y: i64, source: Source };` with an `eql`.
- `pub const PixelPos = struct { x: f32, y: f32 };`
- `pub fn pixelPosition(caret_x: usize, caret_y: usize, origin_x: f32, origin_y: f32, pad_left: u32, pad_top: u32, cell_w: f32, cell_h: f32) PixelPos` —
  the placement math (`origin + pad + cell*cell_size`), parameterized over the
  origin so the split and non-split branches share it.
- `pub const StabilityTracker = struct { last_sample: Sample, committed: Sample, ... }`
  with `pub fn commit(self: *StabilityTracker, sample: Sample) ?Sample` encoding the
  exact current rule: a `terminal_cursor` sample must be observed on **two
  consecutive frames** at the same position before it commits (single-frame
  transients are skipped); a `visual_inverse` sample commits immediately; a sample
  equal to the already-committed one returns `null` (no-op). Initial state matches
  today's global inits (`{ -1, -1, .terminal_cursor }`).

`AppWindow.zig`: replace the 6 `g_ime_caret_*` globals with one
`threadlocal var g_ime_caret_tracker: ime_caret.StabilityTracker = .{}`. The
`ImeCaret`/`ImeCaretSource` locals become `ime_caret.Sample`/`ime_caret.Source`
(or thin aliases). `syncImeCaretPosition` calls `g_ime_caret_tracker.commit(sample)`
(returns the position to push, or null to skip), computes the origin
(non-split: `titlebar.sidebarWidth()`, `currentTitlebarHeight()`; split: the
matching `split_layout` rect), calls `ime_caret.pixelPosition(...)`, then
`window_backend.setImeCaret(...)`. Behavior byte-identical.

### 2. New `src/appwindow/flush_scheduler.zig` (std-only)

A pure debounce state machine for the agent-history store flush:
```zig
pub const DEBOUNCE_MS: i64 = 350;
pub const FlushScheduler = struct {
    dirty: bool = false,
    next_flush_ms: i64 = 0,
    pub fn markDirty(self: *FlushScheduler, now_ms: i64) void; // 0->1 arms debounce
    pub fn shouldFlush(self: *const FlushScheduler, force: bool, now_ms: i64) bool; // dirty AND (force OR elapsed)
    pub fn beginFlush(self: *FlushScheduler) void; // dirty=false, next=0
    pub fn deferFlush(self: *FlushScheduler, now_ms: i64) void; // transient pre-flush error: re-arm debounce, stay dirty
    pub fn failFlush(self: *FlushScheduler, now_ms: i64) void; // IO failure: re-mark dirty if not already
    pub fn reset(self: *FlushScheduler) void;
};
```
`AppWindow.zig`: replace `g_agent_history_dirty` + `g_agent_history_next_flush_ms`
with `var g_flush_scheduler: flush_scheduler.FlushScheduler = .{}` (still guarded by
the existing `g_agent_history_mutex`; `g_agent_history_revision` stays separate).
Map the call sites:
- `markAgentHistoryDirtyLocked` → `g_flush_scheduler.markDirty(now); g_agent_history_revision +%= 1;`
- `flushAgentHistoryStoreIfDirty` early checks → `if (!g_flush_scheduler.shouldFlush(force, now)) { unlock; return; }`; snapshot/path errors → `g_flush_scheduler.deferFlush(now)`; success-before-IO → `g_flush_scheduler.beginFlush()`; IO failure → `g_flush_scheduler.failFlush(now2)`.
- store init/reset → `g_flush_scheduler.reset()`.

## Tests
- `ime_caret.zig`: `pixelPosition` math (origin/pad/cell); `StabilityTracker.commit`
  — terminal_cursor requires two identical frames; visual_inverse commits
  immediately; re-committing the same position is a no-op; a changed position
  re-arms the two-frame wait.
- `flush_scheduler.zig`: not-dirty → no flush; markDirty arms debounce; before
  debounce elapses → no flush unless `force`; after elapse → flush; beginFlush
  clears; deferFlush/failFlush re-arm; reset clears.

## Test wiring & verification
- `ime_caret.zig` is already in `test_fast.zig`; add `flush_scheduler.zig` to
  `test_fast.zig` + `test_main.zig`.
- `zig build test` (native) + `zig build test-full -Dtarget=x86_64-windows-gnu`
  (the AppWindow code compiles + runs there) + macOS compile-check of the two
  std-only modules (`zig test <mod> -target aarch64-macos --test-no-exec`).

## Out of scope
- No change to the frame loop / GL / window_backend dispatch / threads.
- Tab/split orchestration is already layered (`appwindow/tab.zig`,
  `split_layout.zig`) — not re-done here.
- Frame-geometry diagnostic gating (`g_diag_*`) is pure-ish but diagnostics-only
  and touches `gpu.c` GL types; left as-is.

## Risks & mitigations
- **IME stability semantics drift.** The `StabilityTracker.commit` rule must
  exactly reproduce the two-frame terminal_cursor gate + immediate visual_inverse
  + committed-dedup. Mitigation: transcribe the branch logic precisely; unit-test
  each branch; the initial state matches the global inits.
- **Flush debounce drift.** Mitigation: map each of the 5 current state mutations
  to a named scheduler method (above); unit-test the decision table.
