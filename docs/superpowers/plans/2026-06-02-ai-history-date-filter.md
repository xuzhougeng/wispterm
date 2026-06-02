# AI History date filter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-day `DATE` navigator to the AI History left column (below the existing CATEGORY navigator) that filters the session list to one `YYYYMMDD` day, AND-combined with the provider category, with cross-filtered counts and mouse-only selection.

**Architecture:** Pure date math lives in `ai_history_types.zig` (testable, libc-free). The `Session` gains a `tz_offset_seconds` field (default `0` = UTC) plus date filter/scroll state and bucket-building methods; it stays in the libc-free fast test suite. A new `ai_history_time.zig` does the one impure libc query for the local UTC offset and is imported only by `appwindow/tab.zig` (outside the fast suite), which injects the offset into each session at creation. The renderer reads the session each frame, draws the DATE rows into a stack buffer, and maps clicks; `AppWindow`/`input.zig` wire clicks and mouse-wheel.

**Tech Stack:** Zig 0.15.2, `std.time.epoch` for civil-date conversion, libc `time.h` (`localtime_r`/`timegm`, Windows `localtime_s`/`_mkgmtime`) for the local offset. Build/tests: `zig build test` (fast, ~2s) and `zig build test-full`.

**Key facts established before writing this plan (do not re-litigate):**
- `fast_test_mod` in `build.zig` (line 570) does NOT link libc, and `ai_history_session.zig` + `ai_history_types.zig` + `renderer/ai_history_renderer.zig` are in the fast suite (`src/test_fast.zig`). Therefore the libc `@cImport` MUST stay out of those three files. The offset is injected from `tab.zig` instead.
- `SessionMeta.last_active_at_ms` is UTC epoch milliseconds (parsed from ISO-8601). Rows are sorted descending by `last_active_at_ms` in `replaceRows`, so all rows of one calendar day are contiguous → consecutive-dedup is correct.
- Verified to compile/run on this host: the `dateKeyFromMs` math, the libc offset shim (returned 28800 = UTC+8), `?u32 == ?u32`, and `expectEqual` on a union with an optional payload.

---

### Task 1: Date types and math in `ai_history_types.zig`

Pure helpers next to the existing `CategoryFilter`/`categoryMatches`. No libc, no allocation.

**Files:**
- Modify: `src/ai_history_types.zig` (add types + 3 functions after the `categoryLabel` block, ~line 35; add tests at end of file)

- [ ] **Step 1: Write the failing tests**

Add at the end of `src/ai_history_types.zig` (after the existing `categoryLabel is stable` test, line 166):

```zig
test "ai_history_types: dateKeyFromMs packs local civil date and handles sentinels" {
    // 2026-06-01 12:00:00 UTC.
    const noon_20260601_ms: i64 = 1780315200 * 1000;
    try std.testing.expectEqual(@as(DateKey, 20260601), dateKeyFromMs(noon_20260601_ms, 0));
    // +14h offset pushes 12:00 to 02:00 the next local day.
    try std.testing.expectEqual(@as(DateKey, 20260602), dateKeyFromMs(noon_20260601_ms, 14 * 3600));
    // 2026-06-01 02:00 UTC with -8h offset falls back to 2026-05-31 18:00 local.
    const early_ms: i64 = (1780315200 - 10 * 3600) * 1000;
    try std.testing.expectEqual(@as(DateKey, 20260531), dateKeyFromMs(early_ms, -8 * 3600));
    // No timestamp -> sentinel 0 (never a bucket).
    try std.testing.expectEqual(@as(DateKey, 0), dateKeyFromMs(0, 0));
    try std.testing.expectEqual(@as(DateKey, 0), dateKeyFromMs(-5, 3600));
}

test "ai_history_types: dateMatches treats null filter as all dates" {
    try std.testing.expect(dateMatches(null, 20260601));
    try std.testing.expect(dateMatches(null, 0));
    try std.testing.expect(dateMatches(20260601, 20260601));
    try std.testing.expect(!dateMatches(20260601, 20260531));
    try std.testing.expect(!dateMatches(20260601, 0));
}

test "ai_history_types: formatDateKey renders a zero-padded YYYYMMDD" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("20260601", formatDateKey(20260601, &buf));
    try std.testing.expectEqualStrings("20260102", formatDateKey(20260102, &buf));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: compile error — `dateKeyFromMs` / `dateMatches` / `formatDateKey` / `DateKey` not defined.

- [ ] **Step 3: Write the implementation**

Insert after the `categoryLabel` function (after line 35, before `pub const MessageRole`) in `src/ai_history_types.zig`:

```zig
/// A calendar day packed as the decimal integer `YYYYMMDD` (e.g. 20260601).
/// `0` is the sentinel for "no / unknown timestamp" and never forms a bucket.
pub const DateKey = u32;

/// One distinct day present in the session list, with how many sessions fall on
/// it under the currently-active provider category and text query.
pub const DateBucket = struct {
    key: DateKey,
    count: usize,
};

/// Convert a UTC epoch-millisecond timestamp to a local-day `DateKey`.
/// `tz_offset_seconds` is the local offset east of UTC (e.g. 28800 for UTC+8);
/// pass 0 to bucket in UTC. Returns 0 when the timestamp is absent (<= 0).
pub fn dateKeyFromMs(ms: i64, tz_offset_seconds: i32) DateKey {
    if (ms <= 0) return 0;
    const total_secs = @divFloor(ms, 1000) + tz_offset_seconds;
    if (total_secs < 0) return 0;
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(total_secs) };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const year: u32 = year_day.year;
    const month: u32 = month_day.month.numeric();
    const day: u32 = @as(u32, month_day.day_index) + 1;
    return year * 10000 + month * 100 + day;
}

/// `null` filter matches every day (the "All dates" selection). Otherwise the
/// row's day must equal the filter; the sentinel key 0 never matches a filter.
pub fn dateMatches(filter: ?DateKey, key: DateKey) bool {
    const want = filter orelse return true;
    return key == want;
}

/// Render `key` as an 8-digit `YYYYMMDD` string into `buf` (needs >= 8 bytes).
pub fn formatDateKey(key: DateKey, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>8}", .{key}) catch buf[0..0];
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS — all fast tests green (the three new tests included).

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_types.zig
git commit -m "feat(ai-history): add DateKey math and bucket type"
```

---

### Task 2: Session date state + visibility + scroll

Add the per-session date filter, scroll offset, and injected timezone offset; fold the date facet into the single `rowVisible` predicate so every consumer filters by it. No libc here — `tz_offset_seconds` defaults to 0.

**Files:**
- Modify: `src/ai_history_session.zig` — fields (~line 157), `replaceRows` reset (~line 256), `rowVisible` (lines 524-526), new `setDateFilter`/`scrollDateBy` (after `cycleCategory`, ~line 563); tests at end of file.

- [ ] **Step 1: Write the failing tests**

Add at the end of `src/ai_history_session.zig` (after the `cycleCategory wraps forward and backward` test, line ~2007):

```zig
test "ai_history_session: rowVisible honors the date filter with category and query" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    // 1780315200000 = 2026-06-01 12:00 UTC; +86400000 = 2026-06-02.
    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 1780315200000 },
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = 1780315200000 + 86400000 },
    };
    try session.replaceRows(&rows);
    try std.testing.expectEqual(@as(usize, 2), session.visibleCount());

    session.setDateFilter(20260601);
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    const sel = session.selectedVisible() orelse return error.ExpectedSelection;
    try std.testing.expectEqualStrings("a", sel.session_id);

    // Date AND category combine.
    session.setCategory(.claude);
    try std.testing.expectEqual(@as(usize, 0), session.visibleCount());
    session.setDateFilter(null);
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
}

test "ai_history_session: setDateFilter resets selection and is a no-op when unchanged" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 1780315200000 },
        .{ .provider = .codex, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 1780315200000 },
    };
    try session.replaceRows(&rows);
    session.selected = 1;
    session.list_offset = 1;
    session.setDateFilter(20260601);
    try std.testing.expectEqual(@as(usize, 0), session.selected);
    try std.testing.expectEqual(@as(usize, 0), session.list_offset);

    // No-op path: setting the same filter again must not move selection.
    session.selected = 1;
    session.setDateFilter(20260601);
    try std.testing.expectEqual(@as(usize, 1), session.selected);
}

test "ai_history_session: scrollDateBy saturates at zero" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.date_offset);
    session.scrollDateBy(-3);
    try std.testing.expectEqual(@as(usize, 0), session.date_offset);
    session.scrollDateBy(4);
    try std.testing.expectEqual(@as(usize, 4), session.date_offset);
    session.scrollDateBy(-1);
    try std.testing.expectEqual(@as(usize, 3), session.date_offset);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: compile error — no `date_offset` field, no `setDateFilter`/`scrollDateBy`.

- [ ] **Step 3a: Add the fields**

In `src/ai_history_session.zig`, after the `category: types.CategoryFilter = .all,` line (line 157), add:

```zig
    /// Active day filter (`null` = all dates). Combines with `category`.
    date_filter: ?types.DateKey = null,
    /// Scroll offset into the DATE navigator's day list. The renderer clamps
    /// this against the visible capacity each frame.
    date_offset: usize = 0,
    /// Local UTC offset (seconds east of UTC) used to bucket rows by local day.
    /// Defaults to 0 (UTC); the app injects the real offset at creation.
    tz_offset_seconds: i32 = 0,
```

- [ ] **Step 3b: Reset date scroll in `replaceRows`**

In `replaceRows`, the block at lines 256-258 currently reads:

```zig
        self.selected = 0;
        self.list_offset = 0;
        self.clearTranscript();
```

Change it to also reset the date scroll (preserve `date_filter` across rescans, but drop a now-stale scroll position):

```zig
        self.selected = 0;
        self.list_offset = 0;
        self.date_offset = 0;
        self.clearTranscript();
```

- [ ] **Step 3c: Extend `rowVisible`**

Replace the `rowVisible` function (lines 524-526):

```zig
    pub fn rowVisible(self: *const Session, row: types.SessionMeta, query: []const u8) bool {
        return types.categoryMatches(self.category, row.provider) and types.metadataMatches(row, query);
    }
```

with:

```zig
    pub fn rowVisible(self: *const Session, row: types.SessionMeta, query: []const u8) bool {
        const key = types.dateKeyFromMs(row.last_active_at_ms, self.tz_offset_seconds);
        return types.categoryMatches(self.category, row.provider) and
            types.dateMatches(self.date_filter, key) and
            types.metadataMatches(row, query);
    }
```

- [ ] **Step 3d: Add `setDateFilter` and `scrollDateBy`**

In `src/ai_history_session.zig`, immediately after the `cycleCategory` function (ends line 563, before `categoryCounts`), add:

```zig
    pub fn setDateFilter(self: *Session, filter: ?types.DateKey) void {
        if (self.date_filter == filter) return;
        self.date_filter = filter;
        self.selected = 0;
        self.list_offset = 0;
        self.clearTranscript();
    }

    pub fn scrollDateBy(self: *Session, delta: isize) void {
        if (delta < 0) {
            self.date_offset -|= @intCast(-delta);
        } else {
            self.date_offset +|= @intCast(delta);
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS — fast suite green including the three new tests.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat(ai-history): session date filter state and visibility"
```

---

### Task 3: Date buckets and cross-filtered counts

Build the descending day list (honoring category + query) and make `categoryCounts` honor the active date so both navigators show faceted counts.

**Files:**
- Modify: `src/ai_history_session.zig` — `categoryCounts` (lines 565-578), new `buildDateBuckets`/`dateAllCount` after it; tests at end of file.

- [ ] **Step 1: Write the failing tests**

Add at the end of `src/ai_history_session.zig`:

```zig
test "ai_history_session: buildDateBuckets groups distinct local days descending" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const day1: i64 = 1780315200000; // 2026-06-01 12:00 UTC
    const day2: i64 = day1 + 86400000; // 2026-06-02
    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = day2 },
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = day1 + 3600000 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = day1 },
        .{ .provider = .codex, .session_id = "d", .title = "D", .source_path = "d.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 0 }, // no timestamp
    };
    try session.replaceRows(&rows);

    var buf: [8]types.DateBucket = undefined;
    const all = session.buildDateBuckets(&buf);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqual(@as(types.DateKey, 20260602), all[0].key);
    try std.testing.expectEqual(@as(usize, 1), all[0].count);
    try std.testing.expectEqual(@as(types.DateKey, 20260601), all[1].key);
    try std.testing.expectEqual(@as(usize, 2), all[1].count); // b + c, no-timestamp d excluded
    try std.testing.expectEqual(@as(usize, 4), session.dateAllCount()); // includes d

    // Cross-filter: with category = Codex, day 20260601 has only c.
    session.setCategory(.codex);
    const codex = session.buildDateBuckets(&buf);
    try std.testing.expectEqual(@as(usize, 2), codex.len);
    try std.testing.expectEqual(@as(types.DateKey, 20260601), codex[1].key);
    try std.testing.expectEqual(@as(usize, 1), codex[1].count);
}

test "ai_history_session: categoryCounts honors the active date filter" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const day1: i64 = 1780315200000;
    const day2: i64 = day1 + 86400000;
    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = day1 },
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = day1 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = day2 },
    };
    try session.replaceRows(&rows);

    const all = session.categoryCounts("");
    try std.testing.expectEqual(@as(usize, 3), all.all);

    session.setDateFilter(20260601);
    const d1 = session.categoryCounts("");
    try std.testing.expectEqual(@as(usize, 2), d1.all);
    try std.testing.expectEqual(@as(usize, 1), d1.codex);
    try std.testing.expectEqual(@as(usize, 1), d1.claude);
}

test "ai_history_session: buildDateBuckets respects the buffer cap" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const base: i64 = 1780315200000;
    var rows: [4]types.SessionMeta = undefined;
    for (&rows, 0..) |*r, i| {
        r.* = .{ .provider = .codex, .session_id = "x", .title = "X", .source_path = "x.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = base + @as(i64, @intCast(i)) * 86400000 };
    }
    try session.replaceRows(&rows);
    var small: [2]types.DateBucket = undefined;
    const capped = session.buildDateBuckets(&small);
    try std.testing.expectEqual(@as(usize, 2), capped.len); // 4 distinct days clipped to 2
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: compile error — no `buildDateBuckets` / `dateAllCount`.

- [ ] **Step 3a: Make `categoryCounts` date-aware**

Replace `categoryCounts` (lines 565-578):

```zig
    pub fn categoryCounts(self: *const Session, query: []const u8) struct { all: usize, codex: usize, claude: usize } {
        var all: usize = 0;
        var codex: usize = 0;
        var claude: usize = 0;
        for (self.rows.items) |row| {
            if (!types.metadataMatches(row, query)) continue;
            all += 1;
            switch (row.provider) {
                .codex => codex += 1,
                .claude => claude += 1,
            }
        }
        return .{ .all = all, .codex = codex, .claude = claude };
    }
```

with:

```zig
    pub fn categoryCounts(self: *const Session, query: []const u8) struct { all: usize, codex: usize, claude: usize } {
        var all: usize = 0;
        var codex: usize = 0;
        var claude: usize = 0;
        for (self.rows.items) |row| {
            if (!types.metadataMatches(row, query)) continue;
            const key = types.dateKeyFromMs(row.last_active_at_ms, self.tz_offset_seconds);
            if (!types.dateMatches(self.date_filter, key)) continue;
            all += 1;
            switch (row.provider) {
                .codex => codex += 1,
                .claude => claude += 1,
            }
        }
        return .{ .all = all, .codex = codex, .claude = claude };
    }
```

- [ ] **Step 3b: Add `buildDateBuckets` and `dateAllCount`**

Immediately after the updated `categoryCounts` (and before the closing `};` of the `Session` struct at line 579), add:

```zig
    /// Fill `buf` with the distinct local days present under the current
    /// category + text query (the date filter itself is NOT applied, so every
    /// day stays selectable), descending by date with per-day counts. Rows are
    /// recency-sorted, so same-day rows are contiguous and a running dedup is
    /// correct. Returns the filled prefix; stops at `buf.len`.
    pub fn buildDateBuckets(self: *const Session, buf: []types.DateBucket) []types.DateBucket {
        const query = self.filter[0..self.filter_len];
        var n: usize = 0;
        var have_last = false;
        for (self.rows.items) |row| {
            if (!types.categoryMatches(self.category, row.provider)) continue;
            if (!types.metadataMatches(row, query)) continue;
            const key = types.dateKeyFromMs(row.last_active_at_ms, self.tz_offset_seconds);
            if (key == 0) continue; // no timestamp -> only under "All dates"
            if (have_last and buf[n - 1].key == key) {
                buf[n - 1].count += 1;
                continue;
            }
            if (n >= buf.len) break;
            buf[n] = .{ .key = key, .count = 1 };
            n += 1;
            have_last = true;
        }
        return buf[0..n];
    }

    /// Count of rows under the current category + query, ignoring the date
    /// filter (the "All dates" navigator total). Includes rows with no
    /// timestamp, which appear only under "All dates".
    pub fn dateAllCount(self: *const Session) usize {
        const query = self.filter[0..self.filter_len];
        var count: usize = 0;
        for (self.rows.items) |row| {
            if (!types.categoryMatches(self.category, row.provider)) continue;
            if (!types.metadataMatches(row, query)) continue;
            count += 1;
        }
        return count;
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS — fast suite green including the three new tests.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat(ai-history): date buckets and faceted category counts"
```

---

### Task 4: Renderer — DATE layout, render, and hit-test

Extend the left-column layout, draw the DATE section, add the `Hit.date` variant, and map clicks. Existing `FakeSession` test stubs must gain the new members because `interactionHitTest` now references them.

**Files:**
- Modify: `src/renderer/ai_history_renderer.zig` — `Hit` (lines 35-41), `LeftColumnLayout` (43-52), `leftColumnLayout` (54-81), new constant + helpers (near `rectContains`, ~line 684), `interactionHitTest` (insert after refresh check ~line 199), `renderLeftColumn` (insert after retry text ~line 309), new `drawDateRow` helper; update existing `FakeSession` stubs (lines 738-746, 847-854); add a hit-test test (~line 879).

- [ ] **Step 1: Write the failing test (and update existing fakes so the suite compiles)**

First, update the two existing `FakeSession` structs so they satisfy the new `interactionHitTest` requirements.

In the test `interaction hit test maps buttons and row offset` (lines 738-746), replace:

```zig
    const FakeSession = struct {
        fn visibleCount(_: @This()) usize {
            return 8;
        }

        fn listWindowStart(_: @This(), _: usize) usize {
            return 3;
        }
    };
```

with:

```zig
    const FakeSession = struct {
        date_offset: usize = 0,
        fn visibleCount(_: @This()) usize {
            return 8;
        }

        fn listWindowStart(_: @This(), _: usize) usize {
            return 3;
        }

        fn buildDateBuckets(_: @This(), buf: []types.DateBucket) []types.DateBucket {
            return buf[0..0];
        }
    };
```

In the test `interaction hit test maps category rows` (lines 847-854), replace:

```zig
    const FakeSession = struct {
        fn visibleCount(_: @This()) usize {
            return 0;
        }
        fn listWindowStart(_: @This(), _: usize) usize {
            return 0;
        }
    };
```

with:

```zig
    const FakeSession = struct {
        date_offset: usize = 0,
        fn visibleCount(_: @This()) usize {
            return 0;
        }
        fn listWindowStart(_: @This(), _: usize) usize {
            return 0;
        }
        fn buildDateBuckets(_: @This(), buf: []types.DateBucket) []types.DateBucket {
            return buf[0..0];
        }
    };
```

Then add the new test at the end of the file:

```zig
test "ai_history_renderer: interaction hit test maps date rows" {
    const FakeSession = struct {
        date_offset: usize = 0,
        fn visibleCount(_: @This()) usize {
            return 0;
        }
        fn listWindowStart(_: @This(), _: usize) usize {
            return 0;
        }
        fn buildDateBuckets(_: @This(), buf: []types.DateBucket) []types.DateBucket {
            buf[0] = .{ .key = 20260602, .count = 3 };
            buf[1] = .{ .key = 20260601, .count = 5 };
            return buf[0..2];
        }
    };

    const session = FakeSession{};
    const layout = computeLayout(0, 1000);
    const cell_h: f32 = 16;
    const top: f32 = 40;
    const lc = leftColumnLayout(top, cell_h);

    // Row 0 is the pinned "All dates" row -> null.
    const all_y = lc.date_rows_top + lc.date_row_h * 0.5;
    try std.testing.expectEqual(
        Hit{ .date = null },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, all_y),
    );

    // Row 1 -> first bucket (20260602).
    const d1_y = lc.date_rows_top + lc.date_row_h * 1.5;
    try std.testing.expectEqual(
        Hit{ .date = @as(?types.DateKey, 20260602) },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, d1_y),
    );

    // Row 2 -> second bucket (20260601).
    const d2_y = lc.date_rows_top + lc.date_row_h * 2.5;
    try std.testing.expectEqual(
        Hit{ .date = @as(?types.DateKey, 20260601) },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, d2_y),
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: compile error — `Hit` has no `date` field / `leftColumnLayout` has no `date_rows_top`.

- [ ] **Step 3a: Add the `Hit.date` variant**

Replace the `Hit` union (lines 35-41):

```zig
pub const Hit = union(enum) {
    none,
    refresh,
    @"resume",
    category: types.CategoryFilter,
    row: usize,
};
```

with:

```zig
pub const Hit = union(enum) {
    none,
    refresh,
    @"resume",
    category: types.CategoryFilter,
    date: ?types.DateKey,
    row: usize,
};
```

- [ ] **Step 3b: Extend `LeftColumnLayout` and `leftColumnLayout`**

Replace the struct + function (lines 43-81) with:

```zig
pub const LeftColumnLayout = struct {
    source_name_top: f32,
    target_top: f32,
    status_label_top: f32,
    status_value_top: f32,
    category_heading_top: f32,
    category_rows_top: f32,
    category_row_h: f32,
    retry_text_top: f32,
    date_heading_top: f32,
    date_rows_top: f32,
    date_row_h: f32,
};

pub fn leftColumnLayout(top: f32, cell_h: f32) LeftColumnLayout {
    var y = top + headerHeight(cell_h) + 18;
    const source_name_top = y;
    y += cell_h + 8;
    const target_top = y;
    y += cell_h + 18;
    const status_label_top = y;
    y += cell_h + 5;
    const status_value_top = y;
    y += cell_h + 18;
    const category_heading_top = y;
    y += cell_h + 8;
    const category_rows_top = y;
    const category_row_h = cell_h + 10;
    y += category_row_h * 3;
    y += 12;
    const retry_text_top = y;
    // DATE navigator: below the Refresh button, filling the rest of the column.
    // `cell_h + 16` clears the retry text plus the refresh button body
    // (buttonHeight = cell_h + BUTTON_EXTRA_H, lifted by BUTTON_PAD_Y).
    y += cell_h + 16;
    const date_heading_top = y;
    y += cell_h + 8;
    const date_rows_top = y;
    const date_row_h = category_row_h;
    return .{
        .source_name_top = source_name_top,
        .target_top = target_top,
        .status_label_top = status_label_top,
        .status_value_top = status_value_top,
        .category_heading_top = category_heading_top,
        .category_rows_top = category_rows_top,
        .category_row_h = category_row_h,
        .retry_text_top = retry_text_top,
        .date_heading_top = date_heading_top,
        .date_rows_top = date_rows_top,
        .date_row_h = date_row_h,
    };
}
```

- [ ] **Step 3c: Add the date-section constant and helpers**

Add the constant next to the other constants at the top of the file (after `const RESUME_BUTTON_W: f32 = 104;`, line 11):

```zig
const MAX_DATE_BUCKETS: usize = 256;
```

Add these two helpers just before `fn rectContains` (line 684):

```zig
/// How many DATE rows (including the pinned "All dates" row) fit between
/// `date_rows_top` and the bottom of the left column, reserving the footer.
pub fn dateVisibleCapacity(window_height: f32, date_rows_top: f32, cell_h: f32) usize {
    const footer_reserve = cell_h + 20; // bottom "Enter resumes  Space previews"
    const bottom_limit = window_height - footer_reserve;
    if (bottom_limit <= date_rows_top) return 0;
    const row_h = cell_h + 10; // == leftColumnLayout(...).date_row_h
    return @intFromFloat(@max(0.0, @floor((bottom_limit - date_rows_top) / row_h)));
}

/// Clamp a stored date scroll offset so the windowed day list never scrolls
/// past its end. `day_slots` is the visible capacity minus the pinned All row.
fn clampDateOffset(offset: usize, bucket_count: usize, day_slots: usize) usize {
    if (bucket_count <= day_slots) return 0;
    return @min(offset, bucket_count - day_slots);
}
```

- [ ] **Step 3d: Map date clicks in `interactionHitTest`**

In `interactionHitTest`, the refresh check ends at line 199 (`return .refresh;` inside the `if`). Immediately after that `if` block (before `const visible_count = session.visibleCount();` at line 201), insert:

```zig
    // DATE navigator rows (below the Refresh button). Row 0 = pinned "All dates"
    // (-> null); rows 1.. map to the windowed day buckets.
    {
        var bucket_buf: [MAX_DATE_BUCKETS]types.DateBucket = undefined;
        const buckets = session.buildDateBuckets(&bucket_buf);
        const cap = dateVisibleCapacity(window_height, lc.date_rows_top, cell_h);
        if (cap > 0) {
            if (rectContains(mx, my, layout.left_x, lc.date_rows_top, layout.left_w, lc.date_row_h)) {
                return .{ .date = null };
            }
            const day_slots = cap - 1;
            const offset = clampDateOffset(session.date_offset, buckets.len, day_slots);
            var j: usize = 0;
            while (j < day_slots and offset + j < buckets.len) : (j += 1) {
                const row_top = lc.date_rows_top + @as(f32, @floatFromInt(j + 1)) * lc.date_row_h;
                if (rectContains(mx, my, layout.left_x, row_top, layout.left_w, lc.date_row_h)) {
                    return .{ .date = buckets[offset + j].key };
                }
            }
        }
    }
```

- [ ] **Step 3e: Add the `drawDateRow` helper**

Add just before `fn renderLeftColumn` (line 256):

```zig
fn drawDateRow(
    draw: DrawContext,
    layout: Layout,
    window_height: f32,
    row_top: f32,
    row_h: f32,
    label: []const u8,
    count: usize,
    active: bool,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    selected_bg: [3]f32,
) void {
    if (active) {
        const row_y = yFromTop(window_height, row_top, row_h);
        draw.fillQuadAlpha(layout.left_x, row_y, layout.left_w, row_h, selected_bg, 0.92);
        draw.fillQuad(layout.left_x, row_y, 3, row_h, accent);
    }
    const text_top = row_top + (row_h - draw.cell_h) / 2;
    const label_color = if (active) fg else muted;
    var num_buf: [16]u8 = undefined;
    const num_text = std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch "";
    const count_w: f32 = 44;
    const count_x = layout.left_x + layout.left_w - PAD_X - count_w;
    const label_x = layout.left_x + PAD_X + 6;
    _ = draw.renderTextLimited(label, label_x, yTextFromTop(draw, window_height, text_top), label_color, @max(0, count_x - label_x - 6));
    _ = draw.renderTextLimited(num_text, count_x, yTextFromTop(draw, window_height, text_top), muted, count_w);
}
```

- [ ] **Step 3f: Render the DATE section in `renderLeftColumn`**

In `renderLeftColumn`, after the retry-text line (line 309: `_ = draw.renderTextLimited("r  Retry scan", ...);`) and before the footer block (line 311), insert:

```zig
    _ = draw.renderTextLimited("DATE", layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.date_heading_top), muted, layout.left_w - PAD_X * 2);
    var bucket_buf: [MAX_DATE_BUCKETS]types.DateBucket = undefined;
    const buckets = session.buildDateBuckets(&bucket_buf);
    const date_cap = dateVisibleCapacity(window_height, lc.date_rows_top, draw.cell_h);
    if (date_cap > 0) {
        drawDateRow(draw, layout, window_height, lc.date_rows_top, lc.date_row_h, "All dates", session.dateAllCount(), session.date_filter == null, fg, muted, accent, selected_bg);
        const day_slots = date_cap - 1;
        const offset = clampDateOffset(session.date_offset, buckets.len, day_slots);
        var j: usize = 0;
        while (j < day_slots and offset + j < buckets.len) : (j += 1) {
            const bucket = buckets[offset + j];
            const row_top = lc.date_rows_top + @as(f32, @floatFromInt(j + 1)) * lc.date_row_h;
            var label_buf: [16]u8 = undefined;
            const label = types.formatDateKey(bucket.key, &label_buf);
            const active = session.date_filter != null and session.date_filter.? == bucket.key;
            drawDateRow(draw, layout, window_height, row_top, lc.date_row_h, label, bucket.count, active, fg, muted, accent, selected_bg);
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS — fast suite green; the new `maps date rows` test and existing layout/category/button hit-tests all pass.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/ai_history_renderer.zig
git commit -m "feat(ai-history): render and hit-test the DATE navigator"
```

---

### Task 5: Timezone shim + inject offset at session creation

The one impure libc query, isolated in its own file, imported only by `tab.zig` (outside the fast suite).

**Files:**
- Create: `src/ai_history_time.zig`
- Modify: `src/appwindow/tab.zig` — import (~line 16) + offset injection (after line 446)

- [ ] **Step 1: Create the timezone shim**

Create `src/ai_history_time.zig` with exactly:

```zig
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cDefine("_DEFAULT_SOURCE", "1");
    @cInclude("time.h");
});

/// Local timezone offset in seconds east of UTC for the current moment, or 0
/// (treat as UTC) on any failure. Computed by reinterpreting the broken-down
/// local time as UTC and subtracting the real UTC instant. Query once and cache
/// on the Session; the value is stable for a session's lifetime in practice.
pub fn localOffsetSeconds() i32 {
    const now: c.time_t = @intCast(std.time.timestamp());
    var local_tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    if (builtin.os.tag == .windows) {
        if (c.localtime_s(&local_tm, &now) != 0) return 0;
        const as_utc = c._mkgmtime(&local_tm);
        if (as_utc == @as(c.time_t, -1)) return 0;
        return @intCast(@as(i64, @intCast(as_utc)) - @as(i64, @intCast(now)));
    } else {
        if (c.localtime_r(&now, &local_tm) == null) return 0;
        const as_utc = c.timegm(&local_tm);
        if (as_utc == @as(c.time_t, -1)) return 0;
        return @intCast(@as(i64, @intCast(as_utc)) - @as(i64, @intCast(now)));
    }
}
```

- [ ] **Step 2: Import it in `tab.zig` and inject the offset**

In `src/appwindow/tab.zig`, after the existing import line 16 (`const ai_history_source = @import("../ai_history_source.zig");`), add:

```zig
const ai_history_time = @import("../ai_history_time.zig");
```

Then in `spawnAiHistoryTab`, the block at lines 443-446 currently reads:

```zig
    session_ptr.* = ai_history_session.Session.initOwned(allocator, source) catch {
        allocator.destroy(session_ptr);
        return false;
    };
```

Change it to inject the local offset right after a successful init:

```zig
    session_ptr.* = ai_history_session.Session.initOwned(allocator, source) catch {
        allocator.destroy(session_ptr);
        return false;
    };
    session_ptr.tz_offset_seconds = ai_history_time.localOffsetSeconds();
```

- [ ] **Step 3: Verify the full graph compiles**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS — full suite green (this is the first build that pulls in `ai_history_time.zig` via `tab.zig`; confirms the libc `@cImport` compiles in the app graph and the fast suite still does not include it).

- [ ] **Step 4: Confirm the fast suite stays libc-free**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS — fast suite still builds and runs (proves `ai_history_time.zig` did not leak into it).

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_time.zig src/appwindow/tab.zig
git commit -m "feat(ai-history): inject local timezone offset into sessions"
```

---

### Task 6: Wire clicks and mouse-wheel

Handle the `.date` hit in `AppWindow`, add the date-list scroll entry point, and route left-column wheel events to it.

**Files:**
- Modify: `src/AppWindow.zig` — `.date` arm in `aiHistoryHandleMousePress` switch (after line 1004), new `aiHistoryScrollDateList` (after `aiHistoryScrollTranscript`, ~line 726)
- Modify: `src/input.zig` — left-column wheel routing in the AI-History wheel branch (lines 3851-3866)

- [ ] **Step 1: Handle the `.date` hit**

In `src/AppWindow.zig`, in the `switch (hit)` of `aiHistoryHandleMousePress`, the `.category` arm ends at line 1004 (`return true;` then `},`). Immediately after the `.category` arm's closing `},` and before the `.row =>` arm (line 1005), insert:

```zig
        .date => |k| {
            session.setDateFilter(k);
            session.ensureSelectionVisible(visible_rows);
            markUiDirty();
            return true;
        },
```

- [ ] **Step 2: Add the scroll entry point**

In `src/AppWindow.zig`, after the `aiHistoryScrollTranscript` function (ends ~line 726), add:

```zig
/// Scroll the DATE navigator's day list by `delta` rows (negative scrolls up).
/// The renderer clamps the offset against the visible capacity each frame.
pub fn aiHistoryScrollDateList(delta: isize) bool {
    const session = activeAiHistory() orelse return false;
    session.mutex.lock();
    session.scrollDateBy(delta);
    session.mutex.unlock();
    markUiDirty();
    return true;
}
```

- [ ] **Step 3: Route left-column wheel to the date list**

In `src/input.zig`, the AI-History wheel branch (lines 3851-3866) currently is:

```zig
    if (AppWindow.activeAiHistory() != null) {
        const win = AppWindow.g_window orelse return;
        const size = clientSize(win);
        const left_f = AppWindow.leftPanelsWidth();
        const right_f = @as(f32, @floatFromInt(size.width)) - AppWindow.rightPanelsWidthForWindow(size.width);
        const content_w = @max(0, right_f - left_f);
        const layout = AppWindow.ai_history_renderer.computeLayout(left_f, content_w);
        const x: f32 = @floatFromInt(ev.xpos);
        if (x >= layout.detail_x and x < layout.detail_x + layout.detail_w) {
            const units: i32 = @intCast(mouseWheelUnits(ev.delta));
            const step = units * 3;
            _ = AppWindow.aiHistoryScrollTranscript(if (ev.delta > 0) -step else step);
            return;
        }
        return;
    }
```

Replace the inner `if (x >= layout.detail_x ...) { ... } return;` (the two statements after `const x`) with a detail-pane branch plus a left-column branch:

```zig
        if (x >= layout.detail_x and x < layout.detail_x + layout.detail_w) {
            const units: i32 = @intCast(mouseWheelUnits(ev.delta));
            const step = units * 3;
            _ = AppWindow.aiHistoryScrollTranscript(if (ev.delta > 0) -step else step);
            return;
        }
        if (x >= layout.left_x and x < layout.left_x + layout.left_w) {
            const units: i32 = @intCast(mouseWheelUnits(ev.delta));
            _ = AppWindow.aiHistoryScrollDateList(if (ev.delta > 0) -units else units);
            return;
        }
        return;
```

- [ ] **Step 4: Verify the full graph compiles and passes**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS — full suite green.

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig src/input.zig
git commit -m "feat(ai-history): wire DATE filter clicks and wheel scroll"
```

---

### Task 7: Final verification

**Files:** none (verification only).

- [ ] **Step 1: Run the fast suite**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS, exit 0.

- [ ] **Step 2: Run the full suite**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS, exit 0 (0 failed; skips allowed per the project baseline).

- [ ] **Step 3: Build the app binary**

Run: `zig build 2>&1 | tail -15`
Expected: builds with no errors.

- [ ] **Step 4: Manual GUI check (record outcome, do not auto-pass)**

Open an AI History tab and confirm:
- The left column shows a `DATE` section below `r  Retry scan` with `All dates` + one row per day (`YYYYMMDD`) and counts.
- Clicking a day filters the middle list to that day; clicking `All dates` clears it.
- Date and provider category combine (pick `Codex` + a day → only that day's Codex sessions); counts in each navigator reflect the other's selection.
- Mouse wheel over the left column scrolls the day list; wheel over the transcript pane still scrolls the transcript.

Note: this repo has no Linux GUI backend; GUI verification is on macOS/Windows and may be deferred (consistent with prior AI History work).

---

## Self-Review

**Spec coverage:**
- Per-day `YYYYMMDD` navigator, `All dates` row, counts → Tasks 3 (buckets/counts) + 4 (render). ✓
- Local timezone, UTC fallback, from `last_active_at_ms` → Tasks 1 (`dateKeyFromMs`) + 5 (offset shim + injection). ✓
- AND combination with provider category → Task 2 (`rowVisible`). ✓
- Cross-filtered counts (DATE honors category; CATEGORY honors date) → Task 3 (`buildDateBuckets`/`dateAllCount` honor category+query; `categoryCounts` honors date). ✓
- DATE below the Refresh button → Task 4 (`leftColumnLayout`). ✓
- Mouse-only selection; `←`/`→` unchanged → Task 6 (click handling only; no key changes). ✓
- Mouse-wheel scrolls the day list → Task 6 (`input.zig`). ✓
- Edge: no-timestamp rows only under All dates → Task 1 (key 0) + Task 3 (`buildDateBuckets` skips key 0, `dateAllCount` includes them), tested in Task 3. ✓
- Edge: 256-day cap → Task 4 (`MAX_DATE_BUCKETS`), tested via buffer-cap test in Task 3. ✓
- Edge: empty combination shows existing empty state → no code needed; `renderList` already routes through `rowVisible`/`visibleCount` (unchanged empty-state path). ✓
- Edge: scroll clamp at draw time → Task 4 (`clampDateOffset`); saturating `scrollDateBy` → Task 2. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows assertions and an exact run command. ✓

**Type consistency:** `DateKey` and `DateBucket` defined in Task 1 (`ai_history_types.zig`) and used unqualified there, `types.DateKey`/`types.DateBucket` in the session and renderer. `Hit.date: ?types.DateKey`. `buildDateBuckets(buf: []types.DateBucket) []types.DateBucket`, `dateAllCount() usize`, `setDateFilter(?types.DateKey)`, `scrollDateBy(isize)`, `aiHistoryScrollDateList(isize)`, `dateVisibleCapacity(f32,f32,f32) usize`, `clampDateOffset(usize,usize,usize) usize`, `localOffsetSeconds() i32`, `tz_offset_seconds: i32`. Names match across tasks. ✓
