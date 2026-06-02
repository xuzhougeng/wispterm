# AI History Incremental Scan — Phase 2 (Instant-Reopen + Remote Cache) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reopening AI History shows the previous results instantly (from the on-disk cache) and then reconciles in the background; the remote (WSL/SSH) scan gains a cache so warm rescans skip the per-file `cat`, stream most-recent-first, and also reopen instantly.

**Architecture:** Before walking the filesystem, the scan emits the source's cached rows as a provisional "batch 0" through the existing `ScanSink` (instant display). A shared helper `emitProvisionalBatch` decides **warm** (cache has rows → publish provisional, then accumulate the authoritative set and `replaceRows` at finalize) vs **cold** (no cached rows → Phase 1 per-row streaming). The remote `find` is extended to emit `mtime\tsize\tpath` (sorted, with a plain-`find` fallback) so `RemoteScan` can match the cache and skip `cat` on unchanged files. Builds on Phase 1's `ScanSink`/`appendScanRows`/`finishScan`/`RowEmitter`.

**Tech Stack:** Zig. Tests via `zig build test` (fast suite, includes `ai_history_session.zig`) and `zig build test-full` (full app graph, compiles `AppWindow.zig`).

**Spec:** `docs/superpowers/specs/2026-06-02-ai-history-incremental-scan-design.md` (Phase 2 = §2.1 local instant-reopen, §2.2 remote cache).

**Branch:** `feat/ai-history-phase2-instant-reopen` (off `main` @ `d74e656`, which already has Phase 1 + the category navigator from PR #121).

**Prerequisite note:** Task 1 fixes a Phase-1 wiring regression (`AiHistoryScanJob.run` drops the sink), without which neither streaming nor instant-reopen reaches the running app.

---

## File Structure

- `src/AppWindow.zig` — `AiHistoryScanJob.run` forwards the sink (Task 1); loads + threads a cache into the remote (WSL/SSH) jobs (Task 5).
- `src/ai_history_session.zig` — `rowsForSource` + `emitProvisionalBatch` helpers; warm/cold wiring in `scanLocalFilesystemWithCacheSink` (Task 3); remote `find` command (mtime/size/sort + fallback) and parsing (Task 4); `RemoteScan` cache support + `scanRemoteFilesystemSink` cache param + WSL/SSH host cache fields (Task 5). Tests live in this file.

No new files — Phase 2 extends existing units.

---

## Task 1: Forward the sink in `AiHistoryScanJob.run` (Phase 1 regression fix)

`AiHistoryScanJob.run` receives the worker's sink but ignores it (`_: ?ScanSink`) and passes `null` to `host.scan`, so the app never streams. Forward it. This is not unit-testable (the job reads real `$HOME`/cache and isn't isolated), so it is verified by `zig build test-full` compiling and by GUI smoke.

**Files:**
- Modify: `src/AppWindow.zig` (`AiHistoryScanJob.run`, ~lines 828-853)

- [ ] **Step 1: Forward the sink on all three branches**

In `src/AppWindow.zig`, replace the `run` function of `AiHistoryScanJob` (currently lines 828-854) with:

```zig
    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, source: ai_history_source.Source, sink: ?ai_history_session.ScanSink) anyerror!ai_history_session.ScanResult {
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
                return host.scan(host.ctx, allocator, source, sink);
            },
            .wsl => {
                var host_state = ai_history_session.WslScannerHost{};
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source, sink);
            },
            .ssh => |conn| {
                var host_state = ai_history_session.SshScannerHost{ .conn = conn };
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source, sink);
            },
        }
    }
```

(The only changes: `_: ?ai_history_session.ScanSink` → `sink: ?ai_history_session.ScanSink`, and the three `host.scan(..., null)` → `host.scan(..., sink)`.)

- [ ] **Step 2: Verify the full app compiles**

Run: `zig build test-full`
Expected: EXIT 0.

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "fix(ai-history): forward scan sink in AiHistoryScanJob.run so the app actually streams"
```

---

## Task 2: `rowsForSource` — read cached rows for a source

A helper that clones every cached `SessionMeta` belonging to a `source_id`. This is the data source for instant-reopen (local + remote).

**Files:**
- Modify: `src/ai_history_session.zig` (add `rowsForSource` near the other scan helpers, e.g. just after `freeTranscript` ~line 913; tests at end)

- [ ] **Step 1: Write the failing test**

Add at the END of `src/ai_history_session.zig`:

```zig
test "ai_history_session: rowsForSource clones only matching source rows" {
    const allocator = std.testing.allocator;
    const meta_a: types.SessionMeta = .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 10 };
    const meta_b: types.SessionMeta = .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = 20 };
    var records = [_]ai_history_cache.CacheRecord{
        .{ .source_id = "local", .provider = .codex, .root_path = "/r", .source_path = "a.jsonl", .stamp = .{ .size = 1, .mtime_ns = 1 }, .meta = meta_a },
        .{ .source_id = "wsl", .provider = .claude, .root_path = "/r", .source_path = "b.jsonl", .stamp = .{ .size = 1, .mtime_ns = 1 }, .meta = meta_b },
    };
    const cache: ai_history_cache.CacheFile = .{ .records = &records };

    const rows = try rowsForSource(allocator, cache, "local");
    defer {
        freeRows(allocator, rows);
        allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("a", rows[0].session_id);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: FAIL — `rowsForSource` not defined.

- [ ] **Step 3: Implement `rowsForSource`**

Add at file scope in `src/ai_history_session.zig`, immediately after the `freeTranscript` function (~line 913):

```zig
/// Clone every cached SessionMeta belonging to `source_id`. Caller owns the
/// returned slice (free with `freeRows` + `allocator.free`). Used to show the
/// previous scan instantly on reopen before the filesystem walk runs.
pub fn rowsForSource(allocator: std.mem.Allocator, cache: ai_history_cache.CacheFile, source_id: []const u8) ![]types.SessionMeta {
    var list: std.ArrayListUnmanaged(types.SessionMeta) = .empty;
    errdefer {
        freeRows(allocator, list.items);
        list.deinit(allocator);
    }
    for (cache.records) |record| {
        if (!std.mem.eql(u8, record.source_id, source_id)) continue;
        try list.append(allocator, try cloneMetadata(allocator, record.meta));
    }
    return list.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat(ai-history): rowsForSource — clone cached rows for a source"
```

---

## Task 3: Local instant-reopen (`emitProvisionalBatch` + warm/cold wiring)

Add the shared `emitProvisionalBatch` helper and wire it into `scanLocalFilesystemWithCacheSink`. Warm (cache has rows) → publish provisional batch 0 + accumulate authoritative set (`authoritative = true`); cold → Phase 1 streaming (`authoritative = false`).

**Files:**
- Modify: `src/ai_history_session.zig` (add `ProvisionalScan` + `emitProvisionalBatch` after `rowsForSource`; rewrite `scanLocalFilesystemWithCacheSink` ~lines 734-802; tests at end)

- [ ] **Step 1: Write the failing test**

Add at the END of `src/ai_history_session.zig` (`TestCollectSink` already exists from Phase 1):

```zig
test "ai_history_session: local scan warm cache publishes provisional batch then authoritative result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One real on-disk codex session (the authoritative walk will find this).
    try tmp.dir.makePath(".codex/sessions");
    try tmp.dir.writeFile(.{
        .sub_path = ".codex/sessions/real.jsonl",
        .data =
        \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-real","cwd":"/tmp/project"}}
        \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}
        \\
        ,
    });

    // A cache that knows about a (now stale) prior row for this source.
    const cached_meta: types.SessionMeta = .{ .provider = .codex, .session_id = "codex-prior", .title = "Prior", .source_path = "/old/prior.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 5 };
    var records = [_]ai_history_cache.CacheRecord{
        .{ .source_id = "local", .provider = .codex, .root_path = "/old", .source_path = "/old/prior.jsonl", .stamp = .{ .size = 1, .mtime_ns = 1 }, .meta = cached_meta },
    };
    const cache: ai_history_cache.CacheFile = .{ .records = &records };

    var collect = TestCollectSink{ .allocator = allocator };
    defer collect.deinit();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_buf);
    const result = try scanLocalFilesystemWithCacheSink(allocator, .{
        .id = "local",
        .name = "Local",
        .target = .local,
        .providers = .{ .codex = true, .claude = false },
    }, home, .{}, cache, collect.sink());
    defer freeScanResult(allocator, result);

    // Warm: provisional batch 0 streamed the cached "prior" row...
    try std.testing.expectEqual(@as(usize, 1), collect.rows.items.len);
    try std.testing.expectEqualStrings("codex-prior", collect.rows.items[0].session_id);
    // ...and the authoritative result is the real on-disk row, to be swapped in by finishScan.
    try std.testing.expect(result.authoritative);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("codex-real", result.rows[0].session_id);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: FAIL — `emitProvisionalBatch` not defined / result is not authoritative (cold path streams).

- [ ] **Step 3: Add `ProvisionalScan` + `emitProvisionalBatch`**

Add at file scope in `src/ai_history_session.zig`, immediately after `rowsForSource`:

```zig
/// Outcome of the provisional (instant-reopen) phase, consumed by the local and
/// remote scanners.
const ProvisionalScan = struct {
    /// true when cached rows existed and were published as batch 0; the scan
    /// should then accumulate the authoritative set and `replaceRows` at finalize.
    warm: bool,
    /// The sink the row emitter should use: the real sink in cold streaming mode,
    /// or null in warm/sync mode (accumulate the authoritative set instead).
    emitter_sink: ?ScanSink,
    /// true when the provisional publish reported a stale/closing scan.
    aborted: bool,
};

/// Instant-reopen: if a sink and cache are present and the cache has rows for
/// `source_id`, publish them (sorted, most-recent-first) as a provisional batch 0
/// for instant display, and signal warm mode. Otherwise signal cold/sync mode.
/// Takes ownership of the cached rows by handing them to `sink.publish`.
fn emitProvisionalBatch(allocator: std.mem.Allocator, cache: ?ai_history_cache.CacheFile, source_id: []const u8, sink: ?ScanSink) !ProvisionalScan {
    const real_sink = sink orelse return .{ .warm = false, .emitter_sink = null, .aborted = false };
    const c = cache orelse return .{ .warm = false, .emitter_sink = real_sink, .aborted = false };
    const cached = try rowsForSource(allocator, c, source_id);
    if (cached.len == 0) {
        allocator.free(cached);
        return .{ .warm = false, .emitter_sink = real_sink, .aborted = false };
    }
    std.mem.sort(types.SessionMeta, cached, {}, types.lessRecent);
    const keep = real_sink.publish(real_sink.ctx, cached); // sink takes ownership
    return .{ .warm = true, .emitter_sink = null, .aborted = !keep };
}
```

- [ ] **Step 4: Wire it into `scanLocalFilesystemWithCacheSink`**

Replace the body of `scanLocalFilesystemWithCacheSink` (currently lines 734-802) with the version below. Only the start (provisional phase + emitter sink), the `authoritative` computation, and the `rows`/return change; the provider-root walking block is unchanged:

```zig
pub fn scanLocalFilesystemWithCacheSink(
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    home: []const u8,
    budget: ScanBudget,
    cache: ?ai_history_cache.CacheFile,
    sink: ?ScanSink,
) !ScanResult {
    const prov = try emitProvisionalBatch(allocator, cache, source.id, sink);

    var scanner = LocalScan{
        .allocator = allocator,
        .source = source,
        .budget = budget,
        .cache = cache,
        .emitter = .{ .allocator = allocator, .sink = prov.emitter_sink },
    };
    if (prov.aborted) scanner.emitter.aborted = true;
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

    const authoritative = (sink == null) or prov.warm;
    const rows = if (authoritative)
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
        .authoritative = authoritative,
        .warning_count = scanner.warning_count,
        .owns_row_strings = true,
        .cache_update = .{
            .records = cache_update,
            .owns_record_strings = true,
        },
    };
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS — the warm test passes; the Phase 1 cold streaming test (`local scan with sink streams rows and returns empty non-authoritative result`, which passes `null` cache) still passes because `emitProvisionalBatch` returns cold mode when `cache == null`. Watch for testing-allocator leak reports.

- [ ] **Step 6: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat(ai-history): instant-reopen — provisional cached batch then authoritative reconcile (local)"
```

---

## Task 4: Remote `find` with mtime+size, sorted, with fallback + parsing

Make the remote scan list `mtime\tsize\tpath` (sorted most-recent-first), with a plain-`find` fallback, and parse those fields so `RemoteScan` knows each file's stamp. This task still `cat`s every file (caching comes in Task 5); it adds ordering + the data needed for caching.

**Files:**
- Modify: `src/ai_history_session.zig` (`providerFindCommand` ~818; add `providerFindCommandPlain` + `parseRemoteStamp`; `RemoteScan.scanProviderRoot` ~1166 and `scanPath` ~1190; tests at end)

- [ ] **Step 1: Write the failing tests**

Add at the END of `src/ai_history_session.zig`:

```zig
test "ai_history_session: providerFindCommand emits sorted mtime/size/path" {
    var buf: [2048]u8 = undefined;
    const cmd = try providerFindCommand(.codex, "/home/me/.codex", &buf);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "-printf '%T@\\t%s\\t%p\\n'") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "sort -rn") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "'/home/me/.codex'") != null);
}

test "ai_history_session: parseRemoteStamp parses tab fields and tolerates plain paths" {
    const a = parseRemoteStamp("1717300000.5\t2048\t/p/a.jsonl");
    try std.testing.expectEqualStrings("/p/a.jsonl", a.path);
    try std.testing.expectEqual(@as(u64, 2048), a.stamp.size);
    try std.testing.expectEqual(@as(i128, 1717300000 * std.time.ns_per_s), a.stamp.mtime_ns);

    const b = parseRemoteStamp("/p/b.jsonl"); // fallback (plain find, no tabs)
    try std.testing.expectEqualStrings("/p/b.jsonl", b.path);
    try std.testing.expectEqual(@as(u64, 0), b.stamp.size);
    try std.testing.expectEqual(@as(i128, 0), b.stamp.mtime_ns);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `parseRemoteStamp` not defined; `providerFindCommand` lacks `-printf`/`sort`.

- [ ] **Step 3: Rewrite `providerFindCommand` and add `providerFindCommandPlain`**

Replace `providerFindCommand` (currently lines 818-823) with both functions:

```zig
pub fn providerFindCommand(provider: types.ProviderId, root: []const u8, out: []u8) ![]const u8 {
    _ = provider;
    var quoted_buf: [1024]u8 = undefined;
    const quoted = remote_file.shellQuote(&quoted_buf, root) orelse return error.CommandTooLong;
    // GNU find: emit "mtime<TAB>size<TAB>path", newest first, capped. The \t and \n
    // are literal escapes for find -printf (single-quoted so the shell preserves them).
    return std.fmt.bufPrint(out, "find {s} -type f -name '*.jsonl' -size -2048k -printf '%T@\\t%s\\t%p\\n' 2>/dev/null | sort -rn | head -500", .{quoted}) catch error.CommandTooLong;
}

/// Fallback for environments without GNU `find -printf` (e.g. BSD): path-only,
/// no stamps. Used when the primary command returns nothing.
pub fn providerFindCommandPlain(provider: types.ProviderId, root: []const u8, out: []u8) ![]const u8 {
    _ = provider;
    var quoted_buf: [1024]u8 = undefined;
    const quoted = remote_file.shellQuote(&quoted_buf, root) orelse return error.CommandTooLong;
    return std.fmt.bufPrint(out, "find {s} -type f -name '*.jsonl' -size -2048k | head -500", .{quoted}) catch error.CommandTooLong;
}
```

- [ ] **Step 4: Add `parseRemoteStamp`**

Add at file scope, just below `providerFindCommandPlain`:

```zig
const RemoteCandidate = struct {
    path: []const u8,
    stamp: ai_history_cache.FileStamp,
};

/// Parse one `find` output line. Primary form is "<mtime>\t<size>\t<path>"
/// (mtime is `%T@` seconds, possibly fractional). Fallback form (plain find) is
/// just "<path>" → stamp zeroed. `path` borrows from `line`.
fn parseRemoteStamp(line: []const u8) RemoteCandidate {
    var it = std.mem.splitScalar(u8, line, '\t');
    const first = it.next() orelse return .{ .path = line, .stamp = .{ .size = 0, .mtime_ns = 0 } };
    const second = it.next();
    const third = it.next();
    if (second == null or third == null) {
        // Plain path (no tabs) → fallback stamp.
        return .{ .path = std.mem.trim(u8, line, " \t\r\n"), .stamp = .{ .size = 0, .mtime_ns = 0 } };
    }
    const secs_str = std.mem.sliceTo(first, '.'); // integer seconds, drop fraction
    const secs = std.fmt.parseInt(i128, secs_str, 10) catch 0;
    const size = std.fmt.parseInt(u64, std.mem.trim(u8, second.?, " "), 10) catch 0;
    return .{
        .path = std.mem.trim(u8, third.?, " \t\r\n"),
        .stamp = .{ .size = size, .mtime_ns = secs * std.time.ns_per_s },
    };
}
```

- [ ] **Step 5: Use the parsed stamp in `RemoteScan`**

Change `RemoteScan.scanProviderRoot` (currently lines 1166-1188) to try the primary command, fall back to plain on empty output, and pass the parsed stamp to `scanPath`:

```zig
    fn scanProviderRoot(self: *RemoteScan, provider: types.ProviderId, root: []const u8) !void {
        var find_buf: [2048]u8 = undefined;
        const find_cmd = providerFindCommand(provider, root, find_buf[0..]) catch {
            self.warning_count += 1;
            return;
        };
        var listing = self.host.exec(self.host.ctx, self.allocator, find_cmd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.warning_count += 1;
                return;
            },
        };
        if (std.mem.trim(u8, listing, " \t\r\n").len == 0) {
            // Primary (GNU -printf) produced nothing; retry path-only.
            self.allocator.free(listing);
            var plain_buf: [2048]u8 = undefined;
            const plain_cmd = providerFindCommandPlain(provider, root, plain_buf[0..]) catch {
                self.warning_count += 1;
                return;
            };
            listing = self.host.exec(self.host.ctx, self.allocator, plain_cmd) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    self.warning_count += 1;
                    return;
                },
            };
        }
        defer self.allocator.free(listing);

        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line_raw| {
            const trimmed = std.mem.trim(u8, line_raw, " \t\r\n");
            if (trimmed.len == 0) continue;
            const candidate = parseRemoteStamp(line_raw);
            if (candidate.path.len == 0) continue;
            try self.scanPath(provider, candidate.path, candidate.stamp);
            if (self.emitter.aborted) break;
        }
    }
```

Change `scanPath`'s signature (currently line 1190) to accept the stamp; the body is otherwise unchanged for now (Task 5 uses the stamp). Replace the signature line:

```zig
    fn scanPath(self: *RemoteScan, provider: types.ProviderId, path: []const u8, stamp: ai_history_cache.FileStamp) !void {
```

and add, as the first line of its body, a discard so the unused parameter compiles cleanly in this task:

```zig
        _ = stamp; // used in Task 5 (cache lookup)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS — the two new tests pass; the Phase 1 remote streaming test still passes (its `FakeRemoteHost` returns plain paths, which `parseRemoteStamp` handles via the fallback branch, and the empty-listing retry simply re-runs `find` returning the same paths).

- [ ] **Step 7: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat(ai-history): remote find emits sorted mtime/size/path with plain fallback"
```

---

## Task 5: Remote cache (skip `cat` on hit) + remote instant-reopen

Thread a cache into `RemoteScan` so unchanged files skip the `cat`, produce a `cache_update` so remote scans get written to the cache, and reuse `emitProvisionalBatch` so remote reopens are instant. Wire the cache through the WSL/SSH hosts and the AppWindow job.

**Files:**
- Modify: `src/ai_history_session.zig` (`RemoteScan` struct ~1156; `scanPath` ~1190; `scanRemoteFilesystemSink` ~835 + `scanRemoteFilesystem` shim ~831; `WslScannerHost`/`SshScannerHost` ~94-150; tests at end)
- Modify: `src/AppWindow.zig` (`AiHistoryScanJob.run` `.wsl`/`.ssh` branches load + pass a cache)

- [ ] **Step 1: Write the failing test**

Add at the END of `src/ai_history_session.zig`. `FakeRemoteHost` (from Phase 1) returns the codex listing as a plain path and a fixed body; this test gives the cache a matching record (with the fallback stamp `{0,0}` that `parseRemoteStamp` yields for plain paths) so the `cat` is skipped:

```zig
test "ai_history_session: remote scan skips cat on cache hit" {
    const allocator = std.testing.allocator;

    // Host that fails (returns error) if asked to cat — proving the cache hit skipped it.
    const Host = struct {
        fn exec(_: *anyopaque, alloc: std.mem.Allocator, command: []const u8) anyerror![]u8 {
            if (std.mem.eql(u8, command, remote_file.wslHomeCommand())) return try alloc.dupe(u8, "/home/me\n");
            if (std.mem.startsWith(u8, command, "find")) {
                if (std.mem.indexOf(u8, command, "/home/me/.codex") != null)
                    return try alloc.dupe(u8, "/home/me/.codex/sessions/c.jsonl\n");
                return try alloc.dupe(u8, "");
            }
            return error.UnexpectedCat; // cat must NOT be called
        }
    };
    var host_byte: u8 = 0;
    const host = RemoteExecHost{ .ctx = &host_byte, .exec = Host.exec };

    const cached_meta: types.SessionMeta = .{ .provider = .codex, .session_id = "codex-cached", .title = "Cached", .source_path = "/home/me/.codex/sessions/c.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 9 };
    var records = [_]ai_history_cache.CacheRecord{
        .{ .source_id = "wsl", .provider = .codex, .root_path = "/home/me/.codex", .source_path = "/home/me/.codex/sessions/c.jsonl", .stamp = .{ .size = 0, .mtime_ns = 0 }, .meta = cached_meta },
    };
    const cache: ai_history_cache.CacheFile = .{ .records = &records };

    // sink == null so the scan accumulates the authoritative set into result.rows.
    const result = try scanRemoteFilesystemSink(allocator, .{
        .id = "wsl",
        .name = "WSL",
        .target = .{ .wsl = .{} },
        .providers = .{ .codex = true, .claude = false },
    }, host, cache, null);
    defer freeScanResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("codex-cached", result.rows[0].session_id);
    try std.testing.expectEqual(@as(usize, 1), result.cache_update.records.len);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: FAIL — `scanRemoteFilesystemSink` takes 4 args, not 5 (no cache param), and `RemoteScan` has no cache support (the test would hit `error.UnexpectedCat`).

- [ ] **Step 3: Add cache + records to `RemoteScan` and use them in `scanPath`**

Replace the `RemoteScan` struct (currently lines 1156-1223) with:

```zig
const RemoteScan = struct {
    allocator: std.mem.Allocator,
    host: RemoteExecHost,
    source: source_mod.Source,
    cache: ?ai_history_cache.CacheFile = null,
    emitter: RowEmitter,
    cache_records: std.ArrayListUnmanaged(ai_history_cache.CacheRecord) = .empty,
    warning_count: u32 = 0,

    fn deinit(self: *RemoteScan) void {
        ai_history_cache.freeRecords(self.allocator, self.cache_records.items);
        self.cache_records.deinit(self.allocator);
        self.emitter.deinit();
    }

    fn scanProviderRoot(self: *RemoteScan, provider: types.ProviderId, root: []const u8) !void {
        var find_buf: [2048]u8 = undefined;
        const find_cmd = providerFindCommand(provider, root, find_buf[0..]) catch {
            self.warning_count += 1;
            return;
        };
        var listing = self.host.exec(self.host.ctx, self.allocator, find_cmd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.warning_count += 1;
                return;
            },
        };
        if (std.mem.trim(u8, listing, " \t\r\n").len == 0) {
            self.allocator.free(listing);
            var plain_buf: [2048]u8 = undefined;
            const plain_cmd = providerFindCommandPlain(provider, root, plain_buf[0..]) catch {
                self.warning_count += 1;
                return;
            };
            listing = self.host.exec(self.host.ctx, self.allocator, plain_cmd) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    self.warning_count += 1;
                    return;
                },
            };
        }
        defer self.allocator.free(listing);

        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line_raw| {
            const trimmed = std.mem.trim(u8, line_raw, " \t\r\n");
            if (trimmed.len == 0) continue;
            const candidate = parseRemoteStamp(line_raw);
            if (candidate.path.len == 0) continue;
            try self.scanPath(provider, candidate.path, candidate.stamp);
            if (self.emitter.aborted) break;
        }
    }

    fn scanPath(self: *RemoteScan, provider: types.ProviderId, path: []const u8, stamp: ai_history_cache.FileStamp) !void {
        if (self.cache) |cache| {
            if (ai_history_cache.findRecord(cache, self.source.id, provider, path, stamp)) |record| {
                const cached_meta = try cloneMetadata(self.allocator, record.meta);
                {
                    errdefer freeMetadata(self.allocator, cached_meta);
                    try self.appendCacheRecord(provider, path, stamp, record.meta);
                }
                try self.emitter.emit(cached_meta);
                return; // skipped the cat
            }
        }

        var cat_buf: [2048]u8 = undefined;
        const cat_cmd = remoteCatCommand(path, cat_buf[0..]) catch {
            self.warning_count += 1;
            return;
        };
        const bytes = self.host.exec(self.host.ctx, self.allocator, cat_cmd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.warning_count += 1;
                return;
            },
        };
        defer self.allocator.free(bytes);
        if (bytes.len > MAX_METADATA_FILE_BYTES) {
            self.warning_count += 1;
            return;
        }

        const meta = (switch (provider) {
            .codex => codex_provider.parseMetadata(self.allocator, path, bytes),
            .claude => claude_provider.parseMetadata(self.allocator, path, bytes),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (!metadataHasUsableSignal(meta)) {
            freeMetadata(self.allocator, meta);
            self.warning_count += 1;
            return;
        }
        {
            errdefer freeMetadata(self.allocator, meta);
            try self.appendCacheRecord(provider, path, stamp, meta);
        }
        try self.emitter.emit(meta);
    }

    fn appendCacheRecord(self: *RemoteScan, provider: types.ProviderId, path: []const u8, stamp: ai_history_cache.FileStamp, meta: types.SessionMeta) !void {
        const root_path = providerRootForPath(self.source, provider, path);
        const record: ai_history_cache.CacheRecord = .{
            .source_id = self.source.id,
            .provider = provider,
            .root_path = root_path,
            .source_path = path,
            .stamp = stamp,
            .meta = meta,
        };
        const cloned = try ai_history_cache.cloneRecord(self.allocator, record);
        errdefer {
            var mutable = cloned;
            ai_history_cache.freeRecord(self.allocator, &mutable);
        }
        try self.cache_records.append(self.allocator, cloned);
    }
};
```

- [ ] **Step 4: Add the cache param + provisional batch to `scanRemoteFilesystemSink`**

Replace the `scanRemoteFilesystem` shim and `scanRemoteFilesystemSink` (currently lines 831-888) with:

```zig
pub fn scanRemoteFilesystem(allocator: std.mem.Allocator, source: source_mod.Source, host: RemoteExecHost) !ScanResult {
    return scanRemoteFilesystemSink(allocator, source, host, null, null);
}

pub fn scanRemoteFilesystemSink(allocator: std.mem.Allocator, source: source_mod.Source, host: RemoteExecHost, cache: ?ai_history_cache.CacheFile, sink: ?ScanSink) !ScanResult {
    const home_raw = try host.exec(host.ctx, allocator, remote_file.wslHomeCommand());
    defer allocator.free(home_raw);
    const home = std.mem.trim(u8, home_raw, " \t\r\n");
    if (home.len == 0) return error.NoHomeDirectory;

    const prov = try emitProvisionalBatch(allocator, cache, source.id, sink);

    var scanner = RemoteScan{
        .allocator = allocator,
        .host = host,
        .source = source,
        .cache = cache,
        .emitter = .{ .allocator = allocator, .sink = prov.emitter_sink },
    };
    if (prov.aborted) scanner.emitter.aborted = true;
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

    const authoritative = (sink == null) or prov.warm;
    const rows = if (authoritative)
        try scanner.emitter.rows.toOwnedSlice(allocator)
    else
        try allocator.alloc(types.SessionMeta, 0);
    errdefer {
        freeRows(allocator, rows);
        allocator.free(rows);
    }
    const cache_update = try scanner.cache_records.toOwnedSlice(allocator);
    return .{
        .rows = rows,
        .authoritative = authoritative,
        .warning_count = scanner.warning_count,
        .owns_row_strings = true,
        .cache_update = .{
            .records = cache_update,
            .owns_record_strings = true,
        },
    };
}
```

- [ ] **Step 4b: Update the existing Phase 1 remote-streaming test call**

Adding the `cache` parameter (4th, before `sink`) breaks the Phase 1 test `"ai_history_session: remote scan with sink streams rows and returns empty non-authoritative result"`, which currently calls `scanRemoteFilesystemSink(allocator, .{ ... }, host, collect.sink())`. Update that one call to pass `null` for the new cache parameter:

```zig
    const result = try scanRemoteFilesystemSink(allocator, .{
        .id = "wsl",
        .name = "WSL",
        .target = .{ .wsl = .{} },
        .providers = .{ .codex = true, .claude = false },
    }, host, null, collect.sink());
```

(Run `grep -n "scanRemoteFilesystemSink(" src/ai_history_session.zig` and confirm every call passes 5 args: the shim `scanRemoteFilesystem` → `(..., null, null)`, the two host `scan` fns → `(..., self.cache, sink)`, and both tests → `(..., null, sink)` / `(..., cache, null)`.)

- [ ] **Step 5: Add a `cache` field to the WSL/SSH hosts and pass it through**

In `WslScannerHost` (struct currently has no data fields), add a field and pass it in `scan`:

```zig
pub const WslScannerHost = struct {
    cache: ?ai_history_cache.CacheFile = null,

    pub fn scannerHost(self: *WslScannerHost) ScannerHost {
        return .{
            .ctx = self,
            .scan = scan,
            .loadTranscript = loadTranscript,
        };
    }

    fn exec(_: *anyopaque, allocator: std.mem.Allocator, command: []const u8) ![]u8 {
        return remote_file.wslExec(allocator, command) orelse error.RemoteExecFailed;
    }

    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, sink: ?ScanSink) !ScanResult {
        const self: *WslScannerHost = @ptrCast(@alignCast(ctx));
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try scanRemoteFilesystemSink(allocator, source, host, self.cache, sink);
    }

    fn loadTranscript(ctx: *anyopaque, allocator: std.mem.Allocator, meta: types.SessionMeta) ![]types.TranscriptMessage {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try loadRemoteTranscript(allocator, host, meta);
    }
};
```

(Verify the existing `exec`/`loadTranscript` bodies match before replacing — only `scan` gains the cache forwarding and the `self` cast.)

In `SshScannerHost` (already has a `conn` field), add `cache` and forward it the same way:

```zig
pub const SshScannerHost = struct {
    conn: ssh_connection.SshConnection,
    cache: ?ai_history_cache.CacheFile = null,

    pub fn scannerHost(self: *SshScannerHost) ScannerHost {
        return .{
            .ctx = self,
            .scan = scan,
            .loadTranscript = loadTranscript,
        };
    }

    fn exec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) ![]u8 {
        const self: *SshScannerHost = @ptrCast(@alignCast(ctx));
        return try remote_file.sshExecCapture(allocator, self.conn, command);
    }

    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, sink: ?ScanSink) !ScanResult {
        const self: *SshScannerHost = @ptrCast(@alignCast(ctx));
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try scanRemoteFilesystemSink(allocator, source, host, self.cache, sink);
    }

    fn loadTranscript(ctx: *anyopaque, allocator: std.mem.Allocator, meta: types.SessionMeta) ![]types.TranscriptMessage {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try loadRemoteTranscript(allocator, host, meta);
    }
};
```

- [ ] **Step 6: Load + pass the cache in the AppWindow remote jobs**

In `src/AppWindow.zig`, `AiHistoryScanJob.run`, change the `.wsl` and `.ssh` branches to load the cache (like `.local` already does) and set it on the host:

```zig
            .wsl => {
                var parsed_cache = ai_history_cache.loadDefault(allocator) catch null;
                defer if (parsed_cache) |*cache| cache.deinit();
                var host_state = ai_history_session.WslScannerHost{
                    .cache = if (parsed_cache) |cache| cache.value else null,
                };
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source, sink);
            },
            .ssh => |conn| {
                var parsed_cache = ai_history_cache.loadDefault(allocator) catch null;
                defer if (parsed_cache) |*cache| cache.deinit();
                var host_state = ai_history_session.SshScannerHost{
                    .conn = conn,
                    .cache = if (parsed_cache) |cache| cache.value else null,
                };
                const host = host_state.scannerHost();
                return host.scan(host.ctx, allocator, source, sink);
            },
```

- [ ] **Step 7: Run the tests**

Run: `zig build test`
Expected: PASS — the cache-hit test passes (no `cat`, `cache_update` produced). The Phase 1 remote streaming test still passes (it calls `scanRemoteFilesystemSink(..., null cache, sink)` → cold mode, cats normally). If a leak is reported, re-check `RemoteScan.deinit` frees `cache_records`.

Then run: `zig build test-full`
Expected: PASS (compiles the AppWindow remote-job changes).

- [ ] **Step 8: Commit**

```bash
git add src/ai_history_session.zig src/AppWindow.zig
git commit -m "feat(ai-history): remote cache — skip cat on hit, write cache_update, instant-reopen"
```

---

## Task 6: Integration test + full suite

End-to-end: a warm streaming scan via `scanAsync` shows the provisional cached row immediately and finalizes to the authoritative set.

**Files:**
- Modify: `src/ai_history_session.zig` (test at end)

- [ ] **Step 1: Write the integration test**

Add at the END of `src/ai_history_session.zig`:

```zig
test "ai_history_session: scanAsync warm path shows provisional rows then authoritative finalize" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        fn run(_: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, sink: ?ScanSink) anyerror!ScanResult {
            const s = sink.?;
            // Provisional batch 0 (instant-reopen): one cached row.
            const prov = try alloc.alloc(types.SessionMeta, 1);
            prov[0] = .{ .provider = .codex, .session_id = try alloc.dupe(u8, "prior"), .title = try alloc.dupe(u8, "Prior"), .source_path = try alloc.dupe(u8, "p.jsonl"), .resume_kind = .codex_resume, .last_active_at_ms = 5 };
            _ = s.publish(s.ctx, prov);
            // Authoritative set (warm): the real current row.
            const rows = try alloc.alloc(types.SessionMeta, 1);
            rows[0] = .{ .provider = .codex, .session_id = try alloc.dupe(u8, "current"), .title = try alloc.dupe(u8, "Current"), .source_path = try alloc.dupe(u8, "c.jsonl"), .resume_kind = .codex_resume, .last_active_at_ms = 20 };
            return .{ .rows = rows, .authoritative = true, .owns_row_strings = true };
        }
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var ctx_byte: u8 = 0;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    session.scanAsync(.{ .ctx = &ctx_byte, .run = Ctx.run, .destroy = Ctx.destroy });
    session.joinForTest();

    try std.testing.expectEqual(LoadState.ready, session.state);
    // finishScan replaced the provisional "prior" with the authoritative "current".
    try std.testing.expectEqual(@as(usize, 1), session.rows.items.len);
    try std.testing.expectEqualStrings("current", session.rows.items[0].session_id);
}
```

- [ ] **Step 2: Run the test**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Run the full suite**

Run: `zig build test-full`
Expected: PASS (0 failed).

- [ ] **Step 4: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "test(ai-history): warm instant-reopen end-to-end scanAsync integration"
```

---

## Self-Review

**Spec coverage (Phase 2 = §2.1, §2.2):**
- §2.1 local instant-reopen via cache (provisional batch 0; warm accumulate→replace; cold streams) → Tasks 2 (`rowsForSource`) + 3 (`emitProvisionalBatch`, warm/cold wiring). The "same `finishScan` branch covers both" requirement holds: `authoritative = (sink == null) or prov.warm` drives `replaceRows` vs sort, exactly as the Phase 1 `finishScan` expects.
- §2.2 remote cache (mtime-sorted `find` + fallback; skip `cat` on `(size,mtime)` hit; produce `cache_update`; instant-reopen) → Tasks 4 (find/parse) + 5 (cache + provisional + host/job wiring).
- Regression that blocked *any* of this from reaching the app → Task 1.

**Placeholder scan:** No TBD/TODO. Every code step is complete. The one `_ = stamp;` discard in Task 4 is intentional (the parameter is consumed in Task 5, where that line is removed by the struct replacement); called out explicitly.

**Type consistency:** `ProvisionalScan{ warm, emitter_sink, aborted }`, `emitProvisionalBatch(allocator, ?CacheFile, source_id, ?ScanSink) !ProvisionalScan`, `rowsForSource(allocator, CacheFile, source_id) ![]SessionMeta`, `RemoteCandidate{ path, stamp }`, `parseRemoteStamp(line) RemoteCandidate`, `providerFindCommand`/`providerFindCommandPlain(provider, root, out)`, `scanRemoteFilesystemSink(allocator, source, host, ?CacheFile, ?ScanSink)`, `RemoteScan{ allocator, host, source, cache, emitter, cache_records, warning_count }` with `scanPath(provider, path, stamp)` and `appendCacheRecord(provider, path, stamp, meta)`, `WslScannerHost.cache`/`SshScannerHost.cache`. Names and signatures are consistent across tasks. `authoritative = (sink == null) or prov.warm` and `emitter.sink = prov.emitter_sink` are used identically in the local and remote scanners.

**Ownership notes verified:** `emitProvisionalBatch` hands the cached slice to `sink.publish` (sink owns it, frees on stale) — matches the `appendScanRows`/`TestCollectSink` contract. Warm mode accumulates the authoritative set in `emitter.rows` (emitter sink is null), returned as `result.rows`; cold mode streams and returns an empty `alloc(0)` slice. `RemoteScan.deinit` now also frees `cache_records`. `scanPath` cache-hit reorders cache-record-append before `emit` (which takes ownership), mirroring `LocalScan.scanCandidate`.

**Note — remote stamp precision:** `parseRemoteStamp` uses integer `%T@` seconds (drops the sub-second fraction) so cache hits are deterministic without float rounding. A file modified twice within the same second keeps a stale cache entry until its whole-second mtime advances — acceptable; size is also part of the stamp.

**Note — AI History category navigator (PR #121, merged):** none of these tasks touch the renderer or the `rowVisible`/category code, so there is no interaction. Provisional and authoritative rows flow through `appendScanRows`/`replaceRows`, which the category filter already handles.
