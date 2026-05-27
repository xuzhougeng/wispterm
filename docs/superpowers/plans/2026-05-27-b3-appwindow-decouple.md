# B3 — Decouple `AppWindow.zig` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Extract the two remaining pure-logic clusters from `src/AppWindow.zig` — the agent-history flush debounce and the IME caret stability/placement — into std-only, unit-tested modules, leaving the frame loop / threads / GL / window_backend untouched.

**Architecture:** Targeted pure-module extraction (B1/B2 pattern). New `src/appwindow/flush_scheduler.zig`; extend existing `src/ime_caret.zig`. `AppWindow.zig` holds one instance of each replacing the scattered globals; behavior byte-identical.

**Tech Stack:** Zig. `zig build test` (root `src/test_fast.zig`); `zig build test-full -Dtarget=x86_64-windows-gnu` (root `src/test_main.zig`, where AppWindow.zig builds/runs). `[config] (warn): ... maybe` lines are expected fixtures; success = exit 0.

**Spec:** `docs/superpowers/specs/2026-05-27-b3-appwindow-decouple-design.md`

---

## Task 1: `appwindow/flush_scheduler.zig` — pure agent-history flush debounce

**Files:** Create `src/appwindow/flush_scheduler.zig`; modify `src/AppWindow.zig`, `src/test_fast.zig`, `src/test_main.zig`.

Current state in `AppWindow.zig`: globals `g_agent_history_dirty: bool` (~289), `g_agent_history_next_flush_ms: i64` (~290), const `AGENT_HISTORY_FLUSH_DEBOUNCE_MS: i64 = 350` (~292), guarded by `g_agent_history_mutex`. Used in `markAgentHistoryDirtyLocked` (~825), `flushAgentHistoryStoreIfDirty` (~833), and reset in `ensureGlobalAgentHistoryStore`/store-init (~789-790). `g_agent_history_revision` stays separate.

- [ ] **Step 1: Create `src/appwindow/flush_scheduler.zig`:**
```zig
//! Pure debounce state machine for the agent-history store flush, extracted
//! from AppWindow.zig. The caller owns the mutex/store/IO; this owns only the
//! "is a write due?" decision over a dirty flag + a debounce deadline.
const std = @import("std");

pub const DEBOUNCE_MS: i64 = 350;

pub const FlushScheduler = struct {
    dirty: bool = false,
    next_flush_ms: i64 = 0,

    /// Mark the store dirty. On the clean→dirty transition, arm the debounce.
    pub fn markDirty(self: *FlushScheduler, now_ms: i64) void {
        if (!self.dirty) {
            self.dirty = true;
            self.next_flush_ms = now_ms + DEBOUNCE_MS;
        }
    }

    /// Whether a flush should run now: dirty AND (forced OR the debounce elapsed).
    pub fn shouldFlush(self: *const FlushScheduler, force: bool, now_ms: i64) bool {
        if (!self.dirty) return false;
        if (!force and now_ms < self.next_flush_ms) return false;
        return true;
    }

    /// A flush is starting and has captured a snapshot: clear the dirty state.
    pub fn beginFlush(self: *FlushScheduler) void {
        self.dirty = false;
        self.next_flush_ms = 0;
    }

    /// A transient error BEFORE the snapshot (snapshot/path build failed): stay
    /// dirty, re-arm the debounce.
    pub fn deferFlush(self: *FlushScheduler, now_ms: i64) void {
        self.next_flush_ms = now_ms + DEBOUNCE_MS;
    }

    /// The flush write failed: re-mark dirty (if cleared) and re-arm.
    pub fn failFlush(self: *FlushScheduler, now_ms: i64) void {
        if (!self.dirty) {
            self.dirty = true;
            self.next_flush_ms = now_ms + DEBOUNCE_MS;
        }
    }

    pub fn reset(self: *FlushScheduler) void {
        self.dirty = false;
        self.next_flush_ms = 0;
    }
};

test "clean scheduler never flushes" {
    var s: FlushScheduler = .{};
    try std.testing.expect(!s.shouldFlush(false, 1000));
    try std.testing.expect(!s.shouldFlush(true, 1000));
}

test "markDirty arms a debounce window" {
    var s: FlushScheduler = .{};
    s.markDirty(1000);
    try std.testing.expect(s.dirty);
    try std.testing.expectEqual(@as(i64, 1000 + DEBOUNCE_MS), s.next_flush_ms);
    try std.testing.expect(!s.shouldFlush(false, 1000)); // before deadline
    try std.testing.expect(s.shouldFlush(true, 1000)); // force ignores debounce
    try std.testing.expect(s.shouldFlush(false, 1000 + DEBOUNCE_MS)); // at deadline
}

test "markDirty does not re-arm while already dirty" {
    var s: FlushScheduler = .{};
    s.markDirty(1000);
    s.markDirty(1200); // already dirty: deadline unchanged
    try std.testing.expectEqual(@as(i64, 1000 + DEBOUNCE_MS), s.next_flush_ms);
}

test "beginFlush clears; failFlush and deferFlush re-arm" {
    var s: FlushScheduler = .{};
    s.markDirty(1000);
    s.beginFlush();
    try std.testing.expect(!s.dirty);
    try std.testing.expect(!s.shouldFlush(true, 5000));
    s.failFlush(2000);
    try std.testing.expect(s.dirty);
    try std.testing.expectEqual(@as(i64, 2000 + DEBOUNCE_MS), s.next_flush_ms);
    s.deferFlush(3000); // stays dirty, re-arms
    try std.testing.expect(s.dirty);
    try std.testing.expectEqual(@as(i64, 3000 + DEBOUNCE_MS), s.next_flush_ms);
}

test "reset clears everything" {
    var s: FlushScheduler = .{};
    s.markDirty(1000);
    s.reset();
    try std.testing.expect(!s.dirty);
    try std.testing.expectEqual(@as(i64, 0), s.next_flush_ms);
}
```

- [ ] **Step 2: Run** — `zig test src/appwindow/flush_scheduler.zig` → all pass.

- [ ] **Step 3: Wire `AppWindow.zig`.** Add import near the other `appwindow/` imports:
```zig
const flush_scheduler = @import("appwindow/flush_scheduler.zig");
```
Replace the two globals `g_agent_history_dirty`/`g_agent_history_next_flush_ms` (keep `g_agent_history_mutex`, `g_agent_history_revision`) with:
```zig
var g_flush_scheduler: flush_scheduler.FlushScheduler = .{};
```
Delete the local `const AGENT_HISTORY_FLUSH_DEBOUNCE_MS` (now `flush_scheduler.DEBOUNCE_MS`). Rewrite the call sites (read the real current bodies first):
- `markAgentHistoryDirtyLocked`:
```zig
fn markAgentHistoryDirtyLocked() void {
    g_flush_scheduler.markDirty(std.time.milliTimestamp());
    g_agent_history_revision +%= 1;
}
```
- `flushAgentHistoryStoreIfDirty`: replace the two early-return checks (`!dirty` and `!force and now < next`) with one `if (!g_flush_scheduler.shouldFlush(force, now)) { g_agent_history_mutex.unlock(); return; }`. Replace the snapshot-fail and path-fail blocks' `g_agent_history_next_flush_ms = now + AGENT_HISTORY_FLUSH_DEBOUNCE_MS;` with `g_flush_scheduler.deferFlush(now);`. Replace the success-before-IO `g_agent_history_dirty = false; g_agent_history_next_flush_ms = 0;` with `g_flush_scheduler.beginFlush();`. Replace the IO-failure re-mark block (`if (!g_agent_history_dirty) { g_agent_history_dirty = true; g_agent_history_next_flush_ms = std.time.milliTimestamp() + ...; }`) with `g_flush_scheduler.failFlush(std.time.milliTimestamp());`.
- Wherever the store init/reset sets `g_agent_history_dirty = false; g_agent_history_next_flush_ms = 0;` (~789-790), replace with `g_flush_scheduler.reset();`.
- grep `src/AppWindow.zig` for any remaining `g_agent_history_dirty` / `g_agent_history_next_flush_ms` / `AGENT_HISTORY_FLUSH_DEBOUNCE_MS` → there must be NONE left.

- [ ] **Step 4: Wire test roots** — add `_ = @import("appwindow/flush_scheduler.zig");` to `src/test_fast.zig`'s `test {}` block and `src/test_main.zig`'s comptime block.

- [ ] **Step 5: Build** — `zig build test` → exit 0; then `zig build test-full -Dtarget=x86_64-windows-gnu` → exit 0, no new failures.

- [ ] **Step 6: Commit:**
```bash
git add src/appwindow/flush_scheduler.zig src/AppWindow.zig src/test_fast.zig src/test_main.zig
git commit -m "refactor(b3): extract pure agent-history flush scheduler from AppWindow.zig

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: extend `ime_caret.zig` — caret pixel placement + two-frame stability

**Files:** Modify `src/ime_caret.zig`, `src/AppWindow.zig`. (`ime_caret.zig` is already in `test_fast.zig`/`test_main.zig` — no wiring change.)

Current state in `AppWindow.zig`: enum `ImeCaretSource { terminal_cursor, visual_inverse }` (~3065), struct `ImeCaret { x: usize, y: usize, source: ImeCaretSource }` (~3070), 6 globals `g_ime_caret_last_sample_{x,y,source}` + `g_ime_caret_committed_{x,y,source}` (~3058-3063), and `syncImeCaretPosition` (~3076) whose commit/placement logic (lines ~3100-3153) is the target. `imeCaretFromSurfaceLocked`/`visualInverseImeCaretLocked` stay in AppWindow (they read `*Surface`/terminal internals); only the post-sample stability decision + pixel math move.

- [ ] **Step 1: Append to `src/ime_caret.zig`** (keep the existing `Point`/`candidateScore`/`isBetterCandidate`):
```zig
pub const Source = enum { terminal_cursor, visual_inverse };

pub const Sample = struct {
    x: i64,
    y: i64,
    source: Source,

    pub fn eql(self: Sample, other: Sample) bool {
        return self.x == other.x and self.y == other.y and self.source == other.source;
    }
};

pub const PixelPos = struct { x: f32, y: f32 };

/// Cell (caret_x, caret_y) -> pixel position, given the surface origin (window
/// or split-rect top-left), cell padding, and cell size. Pure placement math.
pub fn pixelPosition(
    caret_x: usize,
    caret_y: usize,
    origin_x: f32,
    origin_y: f32,
    pad_left: u32,
    pad_top: u32,
    cell_w: f32,
    cell_h: f32,
) PixelPos {
    return .{
        .x = origin_x + @as(f32, @floatFromInt(pad_left)) + @as(f32, @floatFromInt(caret_x)) * cell_w,
        .y = origin_y + @as(f32, @floatFromInt(pad_top)) + @as(f32, @floatFromInt(caret_y)) * cell_h,
    };
}

/// Decides when an IME caret sample is stable enough to push to the OS. A
/// `terminal_cursor` sample must repeat on two consecutive frames at the same
/// position before it commits (skips single-frame transients during TUI status
/// repaints); a `visual_inverse` sample (an app-drawn stable cell) commits
/// immediately. A sample equal to the already-committed one is a no-op.
pub const StabilityTracker = struct {
    last_sample: Sample = .{ .x = -1, .y = -1, .source = .terminal_cursor },
    committed: Sample = .{ .x = -1, .y = -1, .source = .terminal_cursor },

    /// Returns the sample to commit (push to the OS), or null to skip this frame.
    pub fn commit(self: *StabilityTracker, sample: Sample) ?Sample {
        if (sample.source == .terminal_cursor) {
            if (!sample.eql(self.last_sample)) {
                self.last_sample = sample; // first frame at this spot: wait for a second
                return null;
            }
        } else {
            self.last_sample = sample; // visual inverse: accept immediately
        }
        if (sample.eql(self.committed)) return null; // already pushed
        self.committed = sample;
        return sample;
    }
};

test "pixelPosition places cell by origin, padding, and cell size" {
    const p = pixelPosition(2, 3, 100, 30, 5, 7, 10, 20);
    try std.testing.expectEqual(@as(f32, 100 + 5 + 2 * 10), p.x);
    try std.testing.expectEqual(@as(f32, 30 + 7 + 3 * 20), p.y);
}

test "terminal_cursor caret requires two identical frames to commit" {
    var t: StabilityTracker = .{};
    const s: Sample = .{ .x = 4, .y = 9, .source = .terminal_cursor };
    try std.testing.expectEqual(@as(?Sample, null), t.commit(s)); // first frame: wait
    try std.testing.expectEqual(s, t.commit(s).?); // second identical frame: commit
    try std.testing.expectEqual(@as(?Sample, null), t.commit(s)); // same as committed: no-op
}

test "a moved terminal_cursor caret re-arms the two-frame wait" {
    var t: StabilityTracker = .{};
    const a: Sample = .{ .x = 4, .y = 9, .source = .terminal_cursor };
    _ = t.commit(a);
    try std.testing.expectEqual(a, t.commit(a).?); // committed
    const b: Sample = .{ .x = 5, .y = 9, .source = .terminal_cursor };
    try std.testing.expectEqual(@as(?Sample, null), t.commit(b)); // new spot: wait again
    try std.testing.expectEqual(b, t.commit(b).?); // second frame: commit
}

test "visual_inverse caret commits immediately" {
    var t: StabilityTracker = .{};
    const v: Sample = .{ .x = 7, .y = 2, .source = .visual_inverse };
    try std.testing.expectEqual(v, t.commit(v).?); // no two-frame wait
    try std.testing.expectEqual(@as(?Sample, null), t.commit(v)); // same as committed: no-op
}
```

- [ ] **Step 2: Run** — `zig test src/ime_caret.zig` → all pass (existing + new).

- [ ] **Step 3: Rewrite the caret cluster in `AppWindow.zig`.** Read the current `syncImeCaretPosition` (~3076-3154) and the type decls (~3065-3074) first. Changes:
  - Replace the local `ImeCaretSource` enum + `ImeCaret` struct with aliases:
```zig
const ImeCaretSource = ime_caret.Source;
const ImeCaret = struct { x: usize, y: usize, source: ImeCaretSource };
```
  (Keep `ImeCaret` as a local `usize`-based struct because `imeCaretFromSurfaceLocked`/`visualInverseImeCaretLocked` build it with `usize` cell coords. Only the stability/pixel stages use `ime_caret.Sample`/`pixelPosition`.)
  - Replace the 6 `g_ime_caret_*` globals with:
```zig
threadlocal var g_ime_caret_tracker: ime_caret.StabilityTracker = .{};
```
  - In `syncImeCaretPosition`, replace the commit-decision block (the `sx`/`sy` two-frame logic + the committed-dedup, lines ~3105-3128) with:
```zig
const committed = g_ime_caret_tracker.commit(.{
    .x = @intCast(caret.x),
    .y = @intCast(caret.y),
    .source = caret.source,
}) orelse return;
_ = committed; // (caret.x/caret.y are the cell coords used below)
```
  - Replace the pixel computation (lines ~3130-3146) with `ime_caret.pixelPosition`, computing the origin for the two branches:
```zig
const pad = surface.getPadding();
const cell_w = font.cell_width;
const cell_h = font.cell_height;

var origin_x: f32 = titlebar.sidebarWidth();
var origin_y: f32 = currentTitlebarHeight();
if (split_count > 1) {
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (rect.surface == surface) {
            origin_x = @floatFromInt(rect.x);
            origin_y = @floatFromInt(rect.y);
            break;
        }
    }
}
const px = ime_caret.pixelPosition(caret.x, caret.y, origin_x, origin_y, pad.left, pad.top, cell_w, cell_h);
window_backend.setImeCaret(
    win,
    @intFromFloat(@round(px.x)),
    @intFromFloat(@round(px.y)),
    @intFromFloat(@max(1.0, @round(cell_h))),
);
```
  > This preserves behavior exactly: in the non-split branch the original origin was `titlebar.sidebarWidth()` / `currentTitlebarHeight()`; in the split branch it was the matching `rect.x` / `rect.y`. The pad/cell math is unchanged. The `commit()` call reproduces the two-frame/visual-inverse/dedup logic that the inline `g_ime_caret_*` code did.
  - grep `src/AppWindow.zig` for `g_ime_caret_last_sample`, `g_ime_caret_committed` → there must be NONE left.

- [ ] **Step 4: Build** — `zig build test` → exit 0; `zig build test-full -Dtarget=x86_64-windows-gnu` → exit 0, no new failures.

- [ ] **Step 5: Commit:**
```bash
git add src/ime_caret.zig src/AppWindow.zig
git commit -m "refactor(b3): extract IME caret pixel placement + stability tracker from AppWindow.zig

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Cross-target verification

**Files:** none.

- [ ] **Step 1:** `zig build test` → exit 0 (includes the new flush_scheduler + ime_caret tests).
- [ ] **Step 2:** `zig build test-full -Dtarget=x86_64-windows-gnu` → exit 0, no new failures.
- [ ] **Step 3:** macOS compile-check: `zig test src/appwindow/flush_scheduler.zig -target aarch64-macos --test-no-exec` and `zig test src/ime_caret.zig -target aarch64-macos --test-no-exec` → both compile.
- [ ] **Step 4:** Confirm the globals are gone: `grep -nE "g_agent_history_dirty|g_agent_history_next_flush_ms|g_ime_caret_last_sample|g_ime_caret_committed|AGENT_HISTORY_FLUSH_DEBOUNCE_MS" src/AppWindow.zig` → no matches.
- [ ] **Step 5 (if any regression):** Use superpowers:systematic-debugging before changing code.

---

## Self-review notes
- **Spec coverage:** flush debounce → Task 1; IME caret pixel + stability → Task 2; verification → Task 3. Tab/split orchestration is already layered (out of scope, per spec).
- **Type consistency:** `FlushScheduler` method names match between module, spec, and the AppWindow call-site mapping. `ime_caret.Sample`/`Source`/`PixelPos`/`pixelPosition`/`StabilityTracker.commit` names match between the module and the AppWindow rewrite. `pad.left/top` are `u32` (matches `pixelPosition`'s `pad_left: u32`).
- **Behavior preservation:** `StabilityTracker.commit` reproduces the exact two-frame terminal_cursor gate + immediate visual_inverse + committed-dedup; `pixelPosition` is the verbatim placement formula with the origin parameterized; the flush scheduler methods map 1:1 to the current state mutations.
