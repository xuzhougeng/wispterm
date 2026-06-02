# AI History date filter — design

**Date:** 2026-06-02
**Status:** Approved, pending implementation

## Problem

The AI History left column is now a **category navigator**: an info block at the
top, a `CATEGORY` section (`All` / `Codex` / `Claude Code`) that filters the
middle session list by provider, and a Refresh button. The middle list mixes
sessions from many days, ordered by recency.

There is no way to focus on a single day. A user who remembers "I was working on
this on the 1st" must scroll the recency-ordered list and eyeball it, or guess a
search term. Sessions already carry a `last_active_at_ms` timestamp — it is just
not surfaced.

## Goal

Add a second navigator facet under the existing CATEGORY section: a **`DATE`
section** listing each distinct day present in the data as `YYYYMMDD`
(e.g. `20260601`) with a count, plus an `All dates` row. Selecting a day filters
the middle list to sessions last active on that day. The date facet and the
provider category **combine with AND**, and both stack on top of the existing
text search.

Dates are computed from each session's **last-active timestamp**, formatted in
the user's **local timezone** (UTC fallback).

Non-goals (YAGNI):
- Persisting the selected date across launches (resets to `All dates`).
- Keyboard selection of dates — date picking is mouse-only this round; `←`/`→`
  keep cycling the provider category.
- Date *ranges* or grouping by week/month — a single specific day only.

## UX / interaction

Left column layout (DATE sits **below** the Refresh button, filling the rest of
the column; the CATEGORY block and Refresh button are unchanged):

```
AI History
──────────────
WSL                ← source name
WSL                ← target label
Status: Ready

CATEGORY
▸ All          24
  Codex        11
  Claude Code  13

r  Retry scan

DATE
▸ All dates    24
  20260602      6
  20260601     12
  20260531      4
  20260530      2
  ...                ← scrolls when more days than fit
```

- **Default:** `All dates` — every day shown (current behavior).
- **Mouse:** clicking a day row sets the active date filter; the middle list
  narrows to sessions last active that day; list selection resets to the top and
  the transcript preview clears. Clicking `All dates` clears the date filter.
- **Mouse wheel** over the left column scrolls the day list (wheel over the
  detail pane still scrolls the transcript preview, unchanged).
- **Keyboard:** unchanged. `←`/`→` cycle the provider category; `Up`/`Down`/
  `Enter`/`Space`/`r` keep their meaning. There is no key binding for dates.
- **AND combination:** the active provider category and active date both apply,
  then the text query narrows further. Example: Category = `Codex` and Date =
  `20260601` shows only Codex sessions last active on 2026-06-01.
- **Cross-filtered (faceted) counts:**
  - DATE row counts reflect the currently-selected **category** + text query.
    (Category = `Codex` ⇒ each day shows its Codex-only count; `All dates`
    equals the Codex total.)
  - CATEGORY row counts reflect the currently-selected **date** + text query.
  - A count can therefore be `0` for a category/day combination with no
    sessions; that is expected and informative.

## Architecture / changes

### `src/ai_history_types.zig` (pure, fully testable)

Date logic lives next to the existing `CategoryFilter` / `categoryMatches`
helpers (which live here, not in the session module).

- `DateKey = u32` — packed `YYYYMMDD` (e.g. `20260601`). `0` is the sentinel for
  "unknown / no timestamp".
- `fn dateKeyFromMs(ms: i64, tz_offset_seconds: i32) DateKey` — returns `0` when
  `ms <= 0`; otherwise converts `(@divFloor(ms, 1000) + tz_offset_seconds)`
  seconds-since-epoch to a civil `(year, month, day)` via `std.time.epoch` and
  packs it as `year*10000 + month*100 + day`. Pure: the timezone offset is an
  explicit argument.
- `fn dateMatches(filter: ?DateKey, key: DateKey) bool` — `null ⇒ true`
  (All dates); otherwise `key == filter`.
- `fn formatDateKey(key: DateKey, buf: []u8) []const u8` — writes the 8-digit
  `YYYYMMDD` string for a non-zero key.

### Local timezone offset (impure, isolated)

- A small helper `fn localOffsetSeconds() i32` queries the system once for the
  local UTC offset. POSIX: `localtime_r` + `timegm` (offset =
  `timegm(localBrokenDown) - now`); Windows: the `localtime_s` / `_mkgmtime`
  equivalents. Any failure returns `0` (UTC fallback). libc is already linked
  (`build.zig`). This is the *only* impure part; all date math stays in the pure
  `types` helpers above so it can be unit-tested with explicit offsets.

### `src/ai_history_session.zig`

- `Session` gains:
  - `date_filter: ?DateKey = null` — active day (`null` = all dates).
  - `date_offset: usize = 0` — scroll offset of the day list.
  - `tz_offset_seconds: i32` — captured once at session init via
    `localOffsetSeconds()`.
- `rowVisible(self, row, query)` becomes
  `categoryMatches(self.category, row.provider) AND
   dateMatches(self.date_filter, dateKeyFromMs(row.last_active_at_ms, tz)) AND
   metadataMatches(row, query)`. `visibleCount` / `selectedVisible` /
  `renderList` already route through `rowVisible`, so the date facet applies
  everywhere automatically.
- `const DateBucket = struct { key: DateKey, count: usize };`
- `fn buildDateBuckets(self, buf: []DateBucket) []DateBucket` — fills the
  caller-provided buffer with the distinct non-zero days, **descending by date**,
  counting only rows that match the current **category + query** (the
  cross-filter; the date filter itself is *not* applied, so every day stays
  visible in the navigator). Rows are recency-sorted, so all rows of a given day
  are contiguous → a consecutive-key dedup is correct and O(n). Stops at
  `buf.len`; the renderer passes a fixed stack buffer (cap e.g. 256 days).
- `fn dateAllCount(self) usize` — the `All dates` count: rows matching the
  current category + query (date filter ignored).
- `categoryCounts` is extended to **also honor `date_filter`** (it currently
  honors only the query) so provider counts reflect the selected day.
- `fn setDateFilter(self, filter: ?DateKey)` — no-op early-return if unchanged;
  otherwise set it, reset `selected` and `list_offset` to 0, clear the
  transcript (mirrors `setCategory`).
- `fn scrollDateBy(self, delta: isize)` — adjusts `date_offset` saturating at 0;
  the upper clamp is applied by the renderer against the visible capacity (same
  pattern as the list/transcript scroll, which clamp at draw time).

### `src/renderer/ai_history_renderer.zig`

- `Hit` union gains `date: ?DateKey` (`All dates` → `null`, a day → its key).
- `LeftColumnLayout` / `leftColumnLayout()` gain a date-section origin:
  `date_heading_top` and `date_rows_top` computed from the existing
  `retry_text_top` (i.e. below the Refresh button). The CATEGORY rows and the
  Refresh button keep their current rects, so existing layout/hit-test tests
  stay valid.
- `fn dateVisibleCapacity(window_height, date_rows_top, cell_h) usize` — how
  many day rows fit between `date_rows_top` and the column bottom (the `All
  dates` row is row 0 of the windowed list).
- `renderLeftColumn` draws the `DATE` heading, then the windowed rows
  (`All dates` + day rows from `buildDateBuckets`, offset by `date_offset`
  clamped to capacity). Each row shows its label (`formatDateKey` /
  `"All dates"`) and count; the active row (matching `session.date_filter`) gets
  the same accent-bar + tinted-background highlight as the active category row.
- `interactionHitTest` checks the visible date-row rects (after the category and
  Refresh/resume/list checks) and returns `.{ .date = ... }`.

### `src/AppWindow.zig`

- `aiHistoryHandleMousePress` switch gains
  `.date => |k| { session.setDateFilter(k); session.ensureSelectionVisible(...);
   markUiDirty(); }`.
- New `fn aiHistoryScrollDateList(delta: isize) bool` — looks up the active
  history session, calls `session.scrollDateBy(delta)` under the mutex, marks UI
  dirty.

### `src/input.zig`

- In the AI-History mouse-wheel branch (currently routes wheel-over-detail to
  `aiHistoryScrollTranscript` and returns), add: if the cursor x is within the
  left column (`< layout.list_x`), call
  `AppWindow.aiHistoryScrollDateList(...)` instead. Transcript scrolling over the
  detail pane is unchanged.

## Data flow

```
click left-col DATE row ──► interactionHitTest ──► Hit.date (?DateKey)
                                                       │
                                                       ▼
                                          Session.setDateFilter
                                          (date_filter, reset selection,
                                           clear transcript)
                                                       ▼
   rowVisible = categoryMatches AND dateMatches AND metadataMatches
                                                       ▼
              middle list shows only the active provider × day

wheel over left column ──► aiHistoryScrollDateList ──► Session.scrollDateBy
                                                       ▼ (renderer clamps)
                            DATE navigator scrolls through the day list
```

## Error handling / edge cases

- **No timestamp** (`last_active_at_ms <= 0`): `dateKeyFromMs` returns `0`; such
  rows never form a bucket (no bogus `19700101`) and match only `All dates`.
- **Empty combination:** selecting a day then switching to a category with no
  sessions that day yields an empty list → existing category-named empty-state
  text; `selectedVisible` returns null; resume shows "unavailable" as today. The
  date stays selected; clicking `All dates` clears it.
- **More days than the bucket cap (256):** older days beyond the cap are omitted
  from the navigator (they remain reachable via `All dates` + text search). 256
  distinct active days is far beyond realistic local history.
- **Scroll clamp:** `date_offset` saturates at 0 on the low end; the renderer
  clamps the high end to `bucket_count + 1 − capacity` at draw time, so a stale
  offset after the day list shrinks is harmless.
- **DST / offset captured once:** `tz_offset_seconds` is read at session init; a
  DST change mid-session could shift a near-midnight bucket by an hour. Negligible
  for a history browser and avoids per-row libc calls.

## Testing (TDD)

`ai_history_types.zig`:
- `dateKeyFromMs`: `ms == 0 → 0`; a known UTC ms with `offset == 0` → expected
  `YYYYMMDD`; a positive offset that pushes the time past local midnight yields
  the next day; a negative offset that pulls it before midnight yields the
  previous day.
- `dateMatches`: `null` filter matches any key; a set filter matches only its
  key; the `0` key never matches a non-null filter.
- `formatDateKey`: `20260601 → "20260601"` (zero-padded month/day).

`ai_history_session.zig`:
- `rowVisible` honors the date filter together with category and query.
- `buildDateBuckets`: distinct days, descending order, correct per-day counts;
  honors the active category (Codex-only counts when category = Codex) and the
  text query; rows with `ms <= 0` excluded; respects `buf.len` cap.
- `dateAllCount` equals the sum of bucket counts for the current category/query.
- `categoryCounts` reflects the active `date_filter`.
- `setDateFilter` resets `selected` / `list_offset` and clears the transcript;
  no-op when unchanged.
- `scrollDateBy` saturates at 0 and increases the offset.

`ai_history_renderer.zig`:
- `leftColumnLayout` date-section rects sit below the Refresh button and are
  ordered top-to-bottom; existing category/refresh rects are unchanged.
- `interactionHitTest` returns the correct `.date` for a click inside the
  `All dates` row and a day row, and still returns `.category` / `.refresh` /
  `.resume` / `.row` for clicks in those regions.
- Existing layout/hit-test tests stay green.
