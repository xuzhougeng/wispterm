# AI History Incremental Scan — Phase 1 (Streaming) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the AI History list fill progressively (most-recent-first) as the background scan parses sessions — "扫到 N 个就先显示 N 个" — instead of staying blank until the whole scan finishes.

**Architecture:** Add an optional `ScanSink` callback that the scan worker calls with small batches of rows. `Session.appendScanRows` appends them under `session.mutex`; the already-continuous render loop displays them on the next frame (no wakeup needed). When a sink is present the scan streams and returns an empty, non-authoritative `ScanResult`; `finishScan` then just sorts in place. When no sink is present (sync `scanNow`, tests) behavior is unchanged. Local rows stream in mtime order; remote streams in discovery order (final sort fixes ordering).

**Tech Stack:** Zig, single-process GUI terminal. Tests via `zig build test` (fast suite, includes `ai_history_session.zig`, ~2s) and `zig build test-full`.

**Spec:** `docs/superpowers/specs/2026-06-02-ai-history-incremental-scan-design.md` (Phase 1 = §1.1–§1.6). Phase 2 (instant-reopen + remote caching) is a separate plan written after this lands.

**Naming note:** The spec names the finalize `finishScan`; this plan renames the existing `Session.publishScanResult` to `finishScan` (same role, broadened to handle the streaming case). `publishScanFailure` is unchanged.

---

## File Structure

- `src/ai_history_session.zig` — all core changes: `ScanSink`, `ScanResult.authoritative`, `Session.appendScanRows`, `finishScan` (renamed), `replaceRows`/`sortRowsInPlacePreservingSelection`/`visibleIndexOfSessionId` selection preservation, `RowEmitter`, sink params on `ScanWork.run` & `ScannerHost.scan`, `scanThreadMain`/`StreamCtx`, `scanLocalFilesystemWithCacheSink`, `scanRemoteFilesystemSink`, `scanningStatusLabel`. Tests live in this same file.
- `src/AppWindow.zig` — add the `?ScanSink` parameter to `AiHistoryScanJob.run`.
- `src/renderer/ai_history_renderer.zig` — show the live "Scanning… N" count.

---

## Task 1: `ScanSink`, `ScanResult.authoritative`, and `Session.appendScanRows`

Introduces the streaming primitive and its tests. No existing caller uses it yet, so the tree stays green.

**Files:**
- Modify: `src/ai_history_session.zig` (`ScanResult` near line 33; add `ScanSink` after it; add `appendScanRows` as a `Session` method near the existing `publishScanResult`; tests at end of file)

- [ ] **Step 1: Add the `authoritative` field to `ScanResult`**

In `src/ai_history_session.zig`, change `ScanResult` (currently lines 33-38) to:

```zig
pub const ScanResult = struct {
    rows: []types.SessionMeta,
    /// true  = `rows` is the complete, canonical set (sync / non-streaming);
    ///         the finalize REPLACES the session's rows with it.
    /// false = rows were streamed to the sink already and `rows` is empty;
    ///         the finalize only sorts what is already in the session.
    authoritative: bool = true,
    warning_count: u32 = 0,
    owns_row_strings: bool = false,
    cache_update: CacheUpdate = .{},
};
```

- [ ] **Step 2: Add the `ScanSink` type**

Immediately after the `ScanResult` definition, add:

```zig
/// Streaming seam: the scan worker hands batches of freshly-scanned rows to the
/// sink for live display. The sink takes ownership of `rows` (slice + row string
/// fields) regardless of the return value. Returns false when this scan
/// generation is stale or the session is closing — the worker should stop early.
pub const ScanSink = struct {
    ctx: *anyopaque,
    publish: *const fn (ctx: *anyopaque, rows: []types.SessionMeta) bool,
};
```

- [ ] **Step 3: Write the failing tests for `appendScanRows`**

Add at the end of `src/ai_history_session.zig` (the helper `freeRows` and `cloneMetadata` already exist in this file):

```zig
fn testMakeRow(allocator: std.mem.Allocator, id: []const u8) !types.SessionMeta {
    return .{
        .provider = .codex,
        .session_id = try allocator.dupe(u8, id),
        .title = try allocator.dupe(u8, id),
        .source_path = try allocator.dupe(u8, id),
        .resume_kind = .codex_resume,
    };
}

test "ai_history_session: appendScanRows appends for current generation" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 3;

    const rows = try allocator.alloc(types.SessionMeta, 2);
    rows[0] = try testMakeRow(allocator, "a");
    rows[1] = try testMakeRow(allocator, "b");

    try std.testing.expect(session.appendScanRows(3, rows));
    try std.testing.expectEqual(@as(usize, 2), session.rows.items.len);
    try std.testing.expectEqual(LoadState.scanning, session.state);
}

test "ai_history_session: appendScanRows discards stale generation" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 9;

    const rows = try allocator.alloc(types.SessionMeta, 1);
    rows[0] = try testMakeRow(allocator, "stale");
    // generation 4 != current 9 -> freed, not appended (testing allocator checks no leak)
    try std.testing.expect(!session.appendScanRows(4, rows));
    try std.testing.expectEqual(@as(usize, 0), session.rows.items.len);
}

test "ai_history_session: appendScanRows discards when closing" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 1;
    session.closing.store(true, .release);

    const rows = try allocator.alloc(types.SessionMeta, 1);
    rows[0] = try testMakeRow(allocator, "x");
    try std.testing.expect(!session.appendScanRows(1, rows));
    try std.testing.expectEqual(@as(usize, 0), session.rows.items.len);
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `appendScanRows` is not defined (compile error / no member named 'appendScanRows').

- [ ] **Step 5: Implement `appendScanRows`**

In the `Session` struct, immediately after `publishScanResult` (currently ends at line 294), add:

```zig
/// Worker-thread entry for streaming. If `generation` is current and we are not
/// closing, move `rows` into `self.rows` (the row structs are copied; their
/// strings — allocated with `self.allocator` — live on, now owned by `self.rows`)
/// and return true; the next frame shows them. Otherwise free `rows` and return
/// false so the worker can stop early. Does not touch `self.selected`.
pub fn appendScanRows(self: *Session, generation: u64, rows: []types.SessionMeta) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.closing.load(.acquire) or generation != self.scan_generation) {
        freeRows(self.allocator, rows);
        self.allocator.free(rows);
        return false;
    }
    self.rows.appendSlice(self.allocator, rows) catch {
        // Out of memory: drop this batch but keep scanning (not stale).
        freeRows(self.allocator, rows);
        self.allocator.free(rows);
        return true;
    };
    self.allocator.free(rows); // structs moved into self.rows; free only the slice array
    self.state = .scanning;
    self.status = "Scanning";
    return true;
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS (all three new tests plus the existing suite).

- [ ] **Step 7: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat(ai-history): add ScanSink seam and Session.appendScanRows"
```

---

## Task 2: `finishScan` with the `authoritative` branch + selection preservation

Renames `publishScanResult` to `finishScan`, adds the streaming branch, and makes row replacement preserve the selected session across re-sorts.

**Files:**
- Modify: `src/ai_history_session.zig` (`replaceRows` ~236-258; `publishScanResult` ~275-294 → `finishScan`; add `visibleIndexOfSessionId` + `sortRowsInPlacePreservingSelection`; `scanThreadMain` ~530-537; rename 3 test call sites + titles)

- [ ] **Step 1: Write the failing tests**

Add at the end of `src/ai_history_session.zig`:

```zig
test "ai_history_session: finishScan non-authoritative sorts streamed rows in place" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 1;

    // Simulate streamed rows already appended out of order.
    const r = try allocator.alloc(types.SessionMeta, 2);
    r[0] = try testMakeRow(allocator, "old");
    r[0].last_active_at_ms = 100;
    r[1] = try testMakeRow(allocator, "new");
    r[1].last_active_at_ms = 200;
    try std.testing.expect(session.appendScanRows(1, r));

    const empty = try allocator.alloc(types.SessionMeta, 0);
    session.finishScan(1, .{ .rows = empty, .authoritative = false, .owns_row_strings = true });

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqual(@as(usize, 2), session.rows.items.len);
    try std.testing.expectEqualStrings("new", session.rows.items[0].session_id); // desc by last_active
    try std.testing.expectEqualStrings("old", session.rows.items[1].session_id);
}

test "ai_history_session: replaceRows preserves selection by session id" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const first = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a", .resume_kind = .codex_resume, .last_active_at_ms = 300 },
        .{ .provider = .codex, .session_id = "b", .title = "B", .source_path = "b", .resume_kind = .codex_resume, .last_active_at_ms = 200 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c", .resume_kind = .codex_resume, .last_active_at_ms = 100 },
    };
    try session.replaceRows(&first);
    session.selected = 0; // "a" (most-recent in `first`, index 0)

    // Replace with a reordered set; "b" jumps to most-recent so "a" moves to index 1.
    const second = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "b", .title = "B", .source_path = "b", .resume_kind = .codex_resume, .last_active_at_ms = 900 },
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a", .resume_kind = .codex_resume, .last_active_at_ms = 300 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c", .resume_kind = .codex_resume, .last_active_at_ms = 100 },
    };
    try session.replaceRows(&second);
    // New behavior follows "a" to index 1; old reset-to-0 behavior would give 0.
    try std.testing.expectEqual(@as(usize, 1), session.selected);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `finishScan` not defined (compile error). After the rename compiles, the selection test would also fail under the old `replaceRows` (asserts `selected == 1`, old behavior resets to 0).

- [ ] **Step 3: Add `visibleIndexOfSessionId` and `sortRowsInPlacePreservingSelection`**

In the `Session` struct, just before `selectedVisible` (currently line 518), add:

```zig
/// Visible index (filter-aware) of the row whose session_id == id, or null.
fn visibleIndexOfSessionId(self: *const Session, id: []const u8) ?usize {
    const query = self.filter[0..self.filter_len];
    var visible_index: usize = 0;
    for (self.rows.items) |row| {
        if (!types.metadataMatches(row, query)) continue;
        if (std.mem.eql(u8, row.session_id, id)) return visible_index;
        visible_index += 1;
    }
    return null;
}

/// Sort rows by recency in place, keeping the current selection on the same
/// session id. Used by the streaming finalize (rows are already in self.rows).
fn sortRowsInPlacePreservingSelection(self: *Session) void {
    var selected_id_buf: ?[]u8 = null;
    defer if (selected_id_buf) |b| self.allocator.free(b);
    if (self.selectedVisible()) |sel| {
        selected_id_buf = self.allocator.dupe(u8, sel.session_id) catch null;
    }
    std.mem.sort(types.SessionMeta, self.rows.items, {}, types.lessRecent);
    if (selected_id_buf) |b| {
        self.selected = self.visibleIndexOfSessionId(b) orelse self.selected;
    }
}
```

- [ ] **Step 4: Make `replaceRows` preserve selection**

Replace the body of `replaceRows` (currently lines 236-258) with:

```zig
pub fn replaceRows(self: *Session, rows: []const types.SessionMeta) !void {
    var next: std.ArrayListUnmanaged(types.SessionMeta) = .empty;
    errdefer {
        freeRows(self.allocator, next.items);
        next.deinit(self.allocator);
    }

    try next.ensureTotalCapacity(self.allocator, rows.len);
    for (rows) |row| {
        next.appendAssumeCapacity(try cloneMetadata(self.allocator, row));
    }
    std.mem.sort(types.SessionMeta, next.items, {}, types.lessRecent);

    // Capture the selected session id (duped) before we free the old rows.
    var selected_id_buf: ?[]u8 = null;
    defer if (selected_id_buf) |b| self.allocator.free(b);
    if (self.selectedVisible()) |sel| {
        selected_id_buf = self.allocator.dupe(u8, sel.session_id) catch null;
    }

    freeRows(self.allocator, self.rows.items);
    self.rows.deinit(self.allocator);
    self.rows = next;
    self.list_offset = 0;
    self.clearTranscript();
    self.transcript_generation +%= 1;
    self.state = .ready;
    self.status = "Ready";
    self.selected = if (selected_id_buf) |b| (self.visibleIndexOfSessionId(b) orelse 0) else 0;
}
```

- [ ] **Step 5: Rename `publishScanResult` to `finishScan` and add the branch**

Replace `publishScanResult` (currently lines 275-294) with:

```zig
/// Finalize a scan. `authoritative` results replace the row set (sync / warm
/// path); non-authoritative results were streamed already, so we only sort. If
/// `generation` is stale or we are closing, the result is discarded. Always frees
/// `result`. Called from the scan worker.
pub fn finishScan(self: *Session, generation: u64, result: ScanResult) void {
    var published = false;
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.scan_generation) {
            if (result.authoritative) {
                if (self.replaceRows(result.rows)) |_| {
                    self.status = if (result.warning_count == 0) "Ready" else "Ready with warnings";
                    published = true;
                } else |_| {
                    self.state = .failed;
                    self.status = "Scan failed";
                }
            } else {
                self.sortRowsInPlacePreservingSelection();
                self.state = .ready;
                self.status = if (result.warning_count == 0) "Ready" else "Ready with warnings";
                published = true;
            }
        }
    }
    if (published and result.cache_update.records.len > 0) {
        ai_history_cache.saveDefault(self.allocator, .{ .records = result.cache_update.records }) catch {};
    }
    freeScanResult(self.allocator, result);
}
```

- [ ] **Step 6: Update `scanThreadMain` to call `finishScan`**

In `scanThreadMain` (currently line 536), change `session.publishScanResult(generation, result);` to:

```zig
    session.finishScan(generation, result);
```

- [ ] **Step 7: Rename the three existing `publishScanResult` test call sites + titles**

Update these (test bodies otherwise unchanged):
- Line ~1881 title `"... publishScanResult applies rows when generation current"` → `"... finishScan applies rows when generation current"`; its call `session.publishScanResult(7, .{ .rows = rows, .owns_row_strings = true });` → `session.finishScan(7, .{ .rows = rows, .owns_row_strings = true });`
- Line ~1903 title `"... publishScanResult discards stale generation"` → `"... finishScan discards stale generation"`; call `session.publishScanResult(4, ...)` → `session.finishScan(4, ...)`
- Line ~2046 title `"... publishScanResult discards when closing"` → `"... finishScan discards when closing"`; call `session.publishScanResult(2, ...)` → `session.finishScan(2, ...)`

(These pass no `authoritative` field, so it defaults to `true` → `replaceRows` branch → same behavior as before.)

- [ ] **Step 8: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS (new tests + renamed tests + existing suite).

- [ ] **Step 9: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat(ai-history): finishScan streaming branch + selection-preserving replaceRows"
```

---

## Task 3: Thread `?ScanSink` through the scan seam (sink ignored)

Pure signature plumbing in one atomic commit: the two function-pointer types gain a `?ScanSink` parameter, every implementer and caller is updated, and `scanThreadMain` builds and passes a real sink. The scan bodies still ignore the sink, so behavior is identical and the suite stays green.

**Files:**
- Modify: `src/ai_history_session.zig` (`ScannerHost.scan` type line 42; `ScanWork.run` type line 51; host `scan` fns lines 82/106/133; `scanNow` ~266; `scanThreadMain` ~530; add `StreamCtx`; test scan/run fns at lines 1139, 1536, 1568, 1596, 1629, 1664, 1724, 1928, 1963, 2072 and the inline `ScannerHost` fake at 1742)
- Modify: `src/AppWindow.zig` (`AiHistoryScanJob.run` line 808)

- [ ] **Step 1: Change the two function-pointer types**

In `ScannerHost` (line 42), change the `scan` field to:

```zig
    scan: *const fn (*anyopaque, std.mem.Allocator, source_mod.Source, ?ScanSink) anyerror!ScanResult,
```

In `ScanWork` (line 51), change the `run` field to:

```zig
    run: *const fn (*anyopaque, std.mem.Allocator, source_mod.Source, ?ScanSink) anyerror!ScanResult,
```

- [ ] **Step 2: Update the three production scanner-host `scan` fns (accept + ignore the sink)**

`LocalScannerHost.scan` (line 82):
```zig
    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, _: ?ScanSink) !ScanResult {
        const self: *LocalScannerHost = @ptrCast(@alignCast(ctx));
        if (self.cache) |cache| return try scanLocalFilesystemWithCache(allocator, source, self.home, .{}, cache);
        return try scanLocalFilesystem(allocator, source, self.home);
    }
```

`WslScannerHost.scan` (line 106):
```zig
    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, _: ?ScanSink) !ScanResult {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try scanRemoteFilesystem(allocator, source, host);
    }
```

`SshScannerHost.scan` (line 133):
```zig
    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, _: ?ScanSink) !ScanResult {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try scanRemoteFilesystem(allocator, source, host);
    }
```

- [ ] **Step 3: Update `scanNow` to pass `null`**

In `scanNow` (currently line 266), change `const result = try host.scan(host.ctx, self.allocator, self.source);` to:

```zig
    const result = try host.scan(host.ctx, self.allocator, self.source, null);
```

- [ ] **Step 4: Add `StreamCtx` and update `scanThreadMain`**

Replace `scanThreadMain` (currently lines 530-537) with:

```zig
const StreamCtx = struct {
    session: *Session,
    generation: u64,
    fn publish(ctx: *anyopaque, rows: []types.SessionMeta) bool {
        const self: *StreamCtx = @ptrCast(@alignCast(ctx));
        return self.session.appendScanRows(self.generation, rows);
    }
};

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

- [ ] **Step 5: Update `AiHistoryScanJob.run` in AppWindow.zig**

In `src/AppWindow.zig` (line 808), change the signature to accept and ignore the sink:

```zig
    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, source: ai_history_source.Source, _: ?ai_history_session.ScanSink) anyerror!ai_history_session.ScanResult {
```

(The body is unchanged; it calls `host.scan(host.ctx, allocator, source)` today — update those three calls to pass `null` as the 4th argument: `host.scan(host.ctx, allocator, source, null)` in each of the `.local`, `.wsl`, `.ssh` branches.)

- [ ] **Step 6: Update every test `scan`/`run` fn signature in `ai_history_session.zig`**

Add a 4th parameter `_: ?ScanSink` to each of these `scan`/`run` fns (the scan-shaped ones returning `ScanResult`). For the inline `ScannerHost` literal at line ~1742 (`.scan = @TypeOf(fake).scan`), the fake's `scan` fn at line 1724 must also gain the param.

- Line 1139 `fn scan(_: *anyopaque, allocator: std.mem.Allocator, _: source_mod.Source) !ScanResult` → add `, _: ?ScanSink` before `)`.
- Lines 1536, 1568, 1596, 1629, 1664, 1724 — same edit (`fn scan(..., _: source_mod.Source, _: ?ScanSink) !ScanResult`).
- Lines 1928, 2072 `fn run(ptr: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source) anyerror!ScanResult` → add `, _: ?ScanSink`.
- Line 1963 `fn run(_: *anyopaque, _: std.mem.Allocator, _: source_mod.Source) anyerror!ScanResult` → add `, _: ?ScanSink`.

Leave the two transcript `run` fns (lines 1984, 2015, signature `(_, alloc) anyerror![]types.TranscriptMessage`) unchanged.

- [ ] **Step 7: Build and run the full fast suite**

Run: `zig build test`
Expected: PASS — behavior is unchanged (sink ignored; scans still return authoritative results).

- [ ] **Step 8: Verify the app target still compiles**

Run: `zig build test-full`
Expected: PASS (this compiles `AppWindow.zig` via the app test binary).

- [ ] **Step 9: Commit**

```bash
git add src/ai_history_session.zig src/AppWindow.zig
git commit -m "refactor(ai-history): thread optional ScanSink through the scan seam"
```

---

## Task 4: `RowEmitter` + local streaming (`scanLocalFilesystemWithCacheSink`)

Wires real streaming into the local scan: rows are emitted in batches in mtime order; with a sink the result is empty + non-authoritative, without a sink it accumulates as today.

**Files:**
- Modify: `src/ai_history_session.zig` (add `RowEmitter`; `scanLocalFilesystemWithCache` ~572-633 → delegate to new `...Sink`; `LocalScan` struct ~736-918; `LocalScannerHost.scan` ~82; tests at end)

- [ ] **Step 1: Write the failing test**

Add at the end of `src/ai_history_session.zig`:

```zig
const TestCollectSink = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,

    fn sink(self: *TestCollectSink) ScanSink {
        return .{ .ctx = self, .publish = publish };
    }
    fn publish(ctx: *anyopaque, rows: []types.SessionMeta) bool {
        const self: *TestCollectSink = @ptrCast(@alignCast(ctx));
        self.rows.appendSlice(self.allocator, rows) catch {
            freeRows(self.allocator, rows);
            self.allocator.free(rows);
            return true;
        };
        self.allocator.free(rows); // structs moved in
        return true;
    }
    fn deinit(self: *TestCollectSink) void {
        freeRows(self.allocator, self.rows.items);
        self.rows.deinit(self.allocator);
    }
};

test "ai_history_session: local scan with sink streams rows and returns empty non-authoritative result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".codex/sessions");
    try tmp.dir.writeFile(.{
        .sub_path = ".codex/sessions/one.jsonl",
        .data =
        \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-one","cwd":"/tmp/project"}}
        \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}
        \\
        ,
    });

    var collect = TestCollectSink{ .allocator = allocator };
    defer collect.deinit();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_buf);
    const result = try scanLocalFilesystemWithCacheSink(allocator, .{
        .id = "local",
        .name = "Local",
        .target = .local,
        .providers = .{ .codex = true, .claude = false },
    }, home, .{}, null, collect.sink());
    defer freeScanResult(allocator, result);

    try std.testing.expect(!result.authoritative);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), collect.rows.items.len);
    try std.testing.expectEqualStrings("codex-one", collect.rows.items[0].session_id);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: FAIL — `scanLocalFilesystemWithCacheSink` not defined.

- [ ] **Step 3: Add the `RowEmitter` helper**

Add near the other file-level scan helpers (e.g. just above `const LocalScan = struct {` at line 736):

```zig
/// Collects scanned rows. With a sink it flushes batches for live display
/// (streaming mode); without a sink it accumulates into `rows` for the final
/// ScanResult. Takes ownership of each emitted row (frees it on its own error).
const RowEmitter = struct {
    allocator: std.mem.Allocator,
    sink: ?ScanSink,
    rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,
    pending: std.ArrayListUnmanaged(types.SessionMeta) = .empty,
    aborted: bool = false,
    const BATCH = 12;

    fn emit(self: *RowEmitter, row: types.SessionMeta) !void {
        if (self.sink == null) {
            self.rows.append(self.allocator, row) catch |e| {
                freeMetadata(self.allocator, row);
                return e;
            };
            return;
        }
        self.pending.append(self.allocator, row) catch |e| {
            freeMetadata(self.allocator, row);
            return e;
        };
        if (self.pending.items.len >= BATCH) try self.flush();
    }

    fn flush(self: *RowEmitter) !void {
        if (self.pending.items.len == 0) return;
        const batch = try self.pending.toOwnedSlice(self.allocator);
        const sink = self.sink.?;
        if (!sink.publish(sink.ctx, batch)) self.aborted = true;
    }

    fn deinit(self: *RowEmitter) void {
        freeRows(self.allocator, self.rows.items);
        self.rows.deinit(self.allocator);
        freeRows(self.allocator, self.pending.items);
        self.pending.deinit(self.allocator);
    }
};
```

- [ ] **Step 4: Convert `LocalScan` to use the emitter**

In the `LocalScan` struct (line 736):

(a) Replace the field `rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,` (line 748) with:
```zig
    emitter: RowEmitter,
```

(b) In `deinit` (lines 753-759), replace the two `rows` lines:
```zig
        freeRows(self.allocator, self.rows.items);
        self.rows.deinit(self.allocator);
```
with:
```zig
        self.emitter.deinit();
```

(c) In `scanCandidate`, replace the cache-hit block (currently lines 858-865) with this order (cache record cloned from `record.meta` first, then row handed to the emitter which owns it):
```zig
        if (self.cache) |cache| {
            if (ai_history_cache.findRecord(cache, self.source.id, candidate.provider, candidate.path, stamp)) |record| {
                const cached_meta = try cloneMetadata(self.allocator, record.meta);
                {
                    errdefer freeMetadata(self.allocator, cached_meta);
                    try self.appendCacheRecord(candidate, record.meta);
                }
                try self.emitter.emit(cached_meta);
                return;
            }
        }
```

(d) In `scanCandidate`, replace the tail (currently lines 891-894):
```zig
        errdefer freeMetadata(self.allocator, meta);

        try self.appendCacheRecord(candidate, meta);
        try self.rows.append(self.allocator, meta);
```
with:
```zig
        {
            errdefer freeMetadata(self.allocator, meta);
            try self.appendCacheRecord(candidate, meta);
        }
        try self.emitter.emit(meta);
```

(e) In `processCandidates` (lines 833-854), add an early-abort check inside the loop. Change the loop body so that after `try self.scanCandidate(candidate);` it checks:
```zig
            try self.scanCandidate(candidate);
            parsed_files += 1;
            parsed_bytes += candidate.size;
            if (self.emitter.aborted) break;
```

- [ ] **Step 5: Split `scanLocalFilesystemWithCache` into a shim + `...Sink`**

Replace `scanLocalFilesystemWithCache` (currently lines 572-633) with:

```zig
pub fn scanLocalFilesystemWithCache(
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    home: []const u8,
    budget: ScanBudget,
    cache: ?ai_history_cache.CacheFile,
) !ScanResult {
    return scanLocalFilesystemWithCacheSink(allocator, source, home, budget, cache, null);
}

pub fn scanLocalFilesystemWithCacheSink(
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    home: []const u8,
    budget: ScanBudget,
    cache: ?ai_history_cache.CacheFile,
    sink: ?ScanSink,
) !ScanResult {
    var scanner = LocalScan{
        .allocator = allocator,
        .source = source,
        .budget = budget,
        .cache = cache,
        .emitter = .{ .allocator = allocator, .sink = sink },
    };
    errdefer scanner.deinit();

    if (source.providers.codex) {
        if (source.codex_root_override) |root| {
            try scanner.scanProviderRoot(.codex, root);
        } else {
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (source_mod.defaultRoot(.codex, home, &root_buf)) |root| {
                try scanner.scanProviderRoot(.codex, root);
            } else {
                scanner.warning_count += 1;
            }
        }
    }
    if (source.providers.claude) {
        if (source.claude_root_override) |root| {
            try scanner.scanProviderRoot(.claude, root);
        } else {
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (source_mod.defaultRoot(.claude, home, &root_buf)) |root| {
                try scanner.scanProviderRoot(.claude, root);
            } else {
                scanner.warning_count += 1;
            }
        }
    }
    for (source.extra_roots) |root| {
        if (!providerEnabled(source, root.provider)) continue;
        try scanner.scanProviderRoot(root.provider, root.path);
    }
    try scanner.processCandidates();
    try scanner.emitter.flush();

    const rows = if (sink == null)
        try scanner.emitter.rows.toOwnedSlice(allocator)
    else
        try allocator.alloc(types.SessionMeta, 0);
    errdefer {
        freeRows(allocator, rows);
        allocator.free(rows);
    }
    const cache_update = try scanner.cache_records.toOwnedSlice(allocator);
    scanner.freeCandidates();
    return .{
        .rows = rows,
        .authoritative = (sink == null),
        .warning_count = scanner.warning_count,
        .owns_row_strings = true,
        .cache_update = .{
            .records = cache_update,
            .owns_record_strings = true,
        },
    };
}
```

- [ ] **Step 6: Route `LocalScannerHost.scan` through the sink**

Replace `LocalScannerHost.scan` (line 82, updated in Task 3) with:

```zig
    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, sink: ?ScanSink) !ScanResult {
        const self: *LocalScannerHost = @ptrCast(@alignCast(ctx));
        return try scanLocalFilesystemWithCacheSink(allocator, source, self.home, .{}, self.cache, sink);
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS — the new streaming test passes; existing `scanLocalFilesystem*` tests (which call the shims with no sink) still pass with `authoritative = true` results.

- [ ] **Step 8: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat(ai-history): stream local scan rows in batches via RowEmitter"
```

---

## Task 5: Remote streaming (`scanRemoteFilesystemSink`)

Streams the WSL/SSH scan in discovery order (Phase 1; recency ordering + caching come in Phase 2). Keeps the existing `scanRemoteFilesystem` arity for tests.

**Files:**
- Modify: `src/ai_history_session.zig` (`scanRemoteFilesystem` ~662-709 → shim + `...Sink`; `RemoteScan` struct ~933-1001; `WslScannerHost.scan` ~106; `SshScannerHost.scan` ~133; test at end)

- [ ] **Step 1: Write the failing test**

The existing `FakeRemoteHost` (around line 1167) already simulates `find` + `cat`. Add at the end of `src/ai_history_session.zig` a test that drives a sink through it. First locate the existing remote test to copy its `FakeRemoteHost` setup style, then add:

```zig
test "ai_history_session: remote scan with sink streams rows and returns empty non-authoritative result" {
    const allocator = std.testing.allocator;

    // Minimal fake remote host: `find` lists one path, `cat` returns its bytes.
    const Fake = struct {
        fn exec(_: *anyopaque, alloc: std.mem.Allocator, command: []const u8) anyerror![]u8 {
            if (std.mem.indexOf(u8, command, "pwd") != null or std.mem.indexOf(u8, command, "HOME") != null) {
                return try alloc.dupe(u8, "/home/me\n");
            }
            if (std.mem.startsWith(u8, command, "find")) {
                return try alloc.dupe(u8, "/home/me/.codex/sessions/one.jsonl\n");
            }
            // cat
            return try alloc.dupe(u8,
                \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-remote","cwd":"/tmp/p"}}
                \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}
                \\
            );
        }
    };
    var fake_byte: u8 = 0;
    const host = RemoteExecHost{ .ctx = &fake_byte, .exec = Fake.exec };

    var collect = TestCollectSink{ .allocator = allocator };
    defer collect.deinit();

    const result = try scanRemoteFilesystemSink(allocator, .{
        .id = "wsl",
        .name = "WSL",
        .target = .{ .wsl = .{} },
        .providers = .{ .codex = true, .claude = false },
    }, host, collect.sink());
    defer freeScanResult(allocator, result);

    try std.testing.expect(!result.authoritative);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), collect.rows.items.len);
    try std.testing.expectEqualStrings("codex-remote", collect.rows.items[0].session_id);
}
```

> Note for the implementer: if the existing remote tests use a richer `FakeRemoteHost` with command routing, reuse that type instead of this inline `Fake` to match the established `wslHomeCommand` / `providerFindCommand` / `remoteCatCommand` strings. Verify the home command branch matches `remote_file.wslHomeCommand()`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: FAIL — `scanRemoteFilesystemSink` not defined.

- [ ] **Step 3: Convert `RemoteScan` to use the emitter**

In the `RemoteScan` struct (line 933):

(a) Replace `rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,` with `emitter: RowEmitter,`.

(b) In `deinit`, replace the two `rows` lines with `self.emitter.deinit();`.

(c) In `scanProviderRoot`, after the `while (lines.next())` loop processes a path, add an abort check. Change the loop to:
```zig
        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line_raw| {
            const path = std.mem.trim(u8, line_raw, " \t\r\n");
            if (path.len == 0) continue;
            try self.scanPath(provider, path);
            if (self.emitter.aborted) break;
        }
```

(d) In `scanPath`, replace the tail (currently lines 997-999):
```zig
        errdefer freeMetadata(self.allocator, meta);

        try self.rows.append(self.allocator, meta);
```
with:
```zig
        try self.emitter.emit(meta);
```
(The emitter owns `meta` and frees it on its own error, so the `errdefer` is removed.)

- [ ] **Step 4: Split `scanRemoteFilesystem` into a shim + `...Sink`**

Replace `scanRemoteFilesystem` (currently lines 662-709) with:

```zig
pub fn scanRemoteFilesystem(allocator: std.mem.Allocator, source: source_mod.Source, host: RemoteExecHost) !ScanResult {
    return scanRemoteFilesystemSink(allocator, source, host, null);
}

pub fn scanRemoteFilesystemSink(allocator: std.mem.Allocator, source: source_mod.Source, host: RemoteExecHost, sink: ?ScanSink) !ScanResult {
    const home_raw = try host.exec(host.ctx, allocator, remote_file.wslHomeCommand());
    defer allocator.free(home_raw);
    const home = std.mem.trim(u8, home_raw, " \t\r\n");
    if (home.len == 0) return error.NoHomeDirectory;

    var scanner = RemoteScan{
        .allocator = allocator,
        .host = host,
        .emitter = .{ .allocator = allocator, .sink = sink },
    };
    errdefer scanner.deinit();

    if (source.providers.codex) {
        if (source.codex_root_override) |root| {
            try scanner.scanProviderRoot(.codex, root);
        } else {
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (source_mod.defaultRoot(.codex, home, &root_buf)) |root| {
                try scanner.scanProviderRoot(.codex, root);
            } else {
                scanner.warning_count += 1;
            }
        }
    }
    if (source.providers.claude) {
        if (source.claude_root_override) |root| {
            try scanner.scanProviderRoot(.claude, root);
        } else {
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (source_mod.defaultRoot(.claude, home, &root_buf)) |root| {
                try scanner.scanProviderRoot(.claude, root);
            } else {
                scanner.warning_count += 1;
            }
        }
    }
    for (source.extra_roots) |root| {
        if (!providerEnabled(source, root.provider)) continue;
        try scanner.scanProviderRoot(root.provider, root.path);
    }
    try scanner.emitter.flush();

    const rows = if (sink == null)
        try scanner.emitter.rows.toOwnedSlice(allocator)
    else
        try allocator.alloc(types.SessionMeta, 0);
    return .{
        .rows = rows,
        .authoritative = (sink == null),
        .warning_count = scanner.warning_count,
        .owns_row_strings = true,
    };
}
```

- [ ] **Step 5: Route the WSL/SSH hosts through the sink**

`WslScannerHost.scan` (line 106):
```zig
    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, sink: ?ScanSink) !ScanResult {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try scanRemoteFilesystemSink(allocator, source, host, sink);
    }
```

`SshScannerHost.scan` (line 133):
```zig
    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, sink: ?ScanSink) !ScanResult {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try scanRemoteFilesystemSink(allocator, source, host, sink);
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS — new remote streaming test passes; existing remote tests (calling `scanRemoteFilesystem` shim) still pass.

- [ ] **Step 7: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat(ai-history): stream remote scan rows via RowEmitter"
```

---

## Task 6: Live "Scanning… N" status in the renderer

Shows the running count while scanning, via a pure helper that lives (and is unit-tested) in `ai_history_session.zig`.

**Files:**
- Modify: `src/ai_history_session.zig` (add `scanningStatusLabel` + test)
- Modify: `src/renderer/ai_history_renderer.zig` (import session module; use the helper at the status render site, ~line 227)

- [ ] **Step 1: Write the failing test**

Add at the end of `src/ai_history_session.zig`:

```zig
test "ai_history_session: scanningStatusLabel formats count" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Scanning…", scanningStatusLabel(&buf, 0));
    try std.testing.expectEqualStrings("Scanning… 7", scanningStatusLabel(&buf, 7));
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: FAIL — `scanningStatusLabel` not defined.

- [ ] **Step 3: Implement the helper**

Add as a file-level public function in `src/ai_history_session.zig` (e.g. just after the `Session` struct closes at line 528):

```zig
/// Renders the scanning status label into `buf`. Returns "Scanning…" for zero,
/// "Scanning… N" otherwise. `buf` should be at least 32 bytes; on overflow falls
/// back to the plain label.
pub fn scanningStatusLabel(buf: []u8, count: usize) []const u8 {
    if (count == 0) return "Scanning…";
    return std.fmt.bufPrint(buf, "Scanning… {d}", .{count}) catch "Scanning…";
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Use the helper in the renderer**

In `src/renderer/ai_history_renderer.zig`, add the import near the top (after `const std = @import("std");`, line 1):

```zig
const ai_history_session = @import("../ai_history_session.zig");
```

Then at the status render site (line 227):
```zig
    _ = draw.renderTextLimited(statusText(session), layout.left_x + PAD_X, yTextFromTop(draw, window_height, y), accent, layout.left_w - PAD_X * 2);
```
replace with:
```zig
    var status_buf: [48]u8 = undefined;
    const status_label = if (session.state == .scanning)
        ai_history_session.scanningStatusLabel(&status_buf, session.rows.items.len)
    else
        statusText(session);
    _ = draw.renderTextLimited(status_label, layout.left_x + PAD_X, yTextFromTop(draw, window_height, y), accent, layout.left_w - PAD_X * 2);
```

> Note: the render functions take `session: anytype`; the added import is only used for the free function `scanningStatusLabel`, so it does not break the duck-typed test stubs in this file. If a renderer unit test constructs a fake session, ensure it exposes `state` and `rows.items.len` (the real fakes already expose `state`; add a minimal `rows` if a stub lacks it).

- [ ] **Step 6: Build the full app to confirm the renderer compiles**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/ai_history_session.zig src/renderer/ai_history_renderer.zig
git commit -m "feat(ai-history): show live Scanning… N count while streaming"
```

---

## Task 7: End-to-end streaming integration test + full suite

Proves the whole path: `scanAsync` → worker `run` streams via the sink → `appendScanRows` → `finishScan` (non-authoritative) → sorted, ready.

**Files:**
- Modify: `src/ai_history_session.zig` (test at end)

- [ ] **Step 1: Write the integration test**

Add at the end of `src/ai_history_session.zig`:

```zig
test "ai_history_session: scanAsync streams batches via sink then finalizes ready and sorted" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        fn run(_: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, sink: ?ScanSink) anyerror!ScanResult {
            const s = sink.?;
            {
                const b = try alloc.alloc(types.SessionMeta, 1);
                b[0] = .{ .provider = .codex, .session_id = try alloc.dupe(u8, "s1"), .title = try alloc.dupe(u8, "One"), .source_path = try alloc.dupe(u8, "1.jsonl"), .resume_kind = .codex_resume, .last_active_at_ms = 100 };
                _ = s.publish(s.ctx, b);
            }
            {
                const b = try alloc.alloc(types.SessionMeta, 1);
                b[0] = .{ .provider = .codex, .session_id = try alloc.dupe(u8, "s2"), .title = try alloc.dupe(u8, "Two"), .source_path = try alloc.dupe(u8, "2.jsonl"), .resume_kind = .codex_resume, .last_active_at_ms = 200 };
                _ = s.publish(s.ctx, b);
            }
            const rows = try alloc.alloc(types.SessionMeta, 0);
            return .{ .rows = rows, .authoritative = false, .owns_row_strings = true };
        }
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var ctx_byte: u8 = 0;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    session.scanAsync(.{ .ctx = &ctx_byte, .run = Ctx.run, .destroy = Ctx.destroy });
    session.joinForTest();

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqual(@as(usize, 2), session.rows.items.len);
    try std.testing.expectEqualStrings("s2", session.rows.items[0].session_id); // sorted desc by last_active
    try std.testing.expectEqualStrings("s1", session.rows.items[1].session_id);
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Run the full suite**

Run: `zig build test-full`
Expected: PASS (0 failed; the suite count grows by the tests added in this plan).

- [ ] **Step 4: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "test(ai-history): end-to-end streaming scan integration test"
```

---

## Self-Review

**Spec coverage (Phase 1 = §1.1–§1.6):**
- §1.1 `ScanSink` → Task 1. §1.2 `appendScanRows` (ownership/concurrency) → Task 1. §1.3 sink threading + `sink == null` unchanged → Task 3. §1.4 `RowEmitter` batching → Tasks 4 (local) & 5 (remote). §1.5 `finishScan` `authoritative` branch + selection-preserving `replaceRows` → Task 2. §1.6 live count → Task 6. Phase-1 "remote streams in discovery order, final sort fixes it" → Task 5 (discovery order) + Task 2 (`finishScan` sorts). Covered.

**Placeholder scan:** No TBD/TODO; every code step shows full code; every command has an expected result. The two "Note to implementer" callouts (reuse existing `FakeRemoteHost`; renderer stub `rows`) are guidance on matching existing code, not deferred work.

**Type consistency:** `ScanSink{ ctx, publish }`, `ScanResult.authoritative: bool = true`, `appendScanRows(generation, rows) bool`, `finishScan(generation, result)`, `scanLocalFilesystemWithCacheSink(allocator, source, home, budget, cache, sink)`, `scanRemoteFilesystemSink(allocator, source, host, sink)`, `RowEmitter{ allocator, sink, rows, pending, aborted }`, `scanningStatusLabel(buf, count)`, `visibleIndexOfSessionId`, `sortRowsInPlacePreservingSelection` — names/signatures match across tasks. The `scan`/`run` function-pointer types and every implementer carry the same 4th param `?ScanSink`.

**Integration note — AI History category navigator:** A separate in-flight change adds an All/Codex/Claude-Code category filter to the left column with a single `rowVisible` predicate (and may route `selectedVisible`/`visibleCount` through it instead of bare `metadataMatches`). This plan's new `visibleIndexOfSessionId` deliberately mirrors the current `selectedVisible` "visible" definition (`metadataMatches(row, query)`). If that change has merged before this executes, make `visibleIndexOfSessionId` use the same `rowVisible` predicate as `selectedVisible` so selection preservation stays consistent with what the list shows. No other task is affected.

**Note on the `replaceRows` selection test (Task 2 Step 2):** the test sets `selected = 1` then asserts it follows "b" to index 0 — this fails before the Step 4 change (old `replaceRows` resets to 0, which coincidentally is also 0 here). The `finishScan` compile error is the primary red in Step 2; after Step 4 the selection-follow behavior is what the test meaningfully exercises (consider also asserting a case where the preserved index is non-zero — e.g. select "a", whose new index is 1 — if you want a stricter guard).
