# AI History provider categories — design

**Date:** 2026-06-02
**Status:** Approved, pending implementation

## Problem

The AI History view has three columns: a left info column ("AI History":
source name, target, scan status, retry hint), a middle session list (Codex
and Claude Code sessions interleaved by recency, each row prefixed with its
provider label), and a right transcript preview.

There is no way to look at just one agent's history. A user who only wants
Codex sessions, or only Claude Code sessions, must visually skim the mixed
list or type the provider into the search box.

## Goal

Turn the left column into a **category navigator**: keep the info block at the
top, and add a `CATEGORY` section listing `All`, `Codex`, and `Claude Code`.
Selecting a category filters the middle session list to that provider. The
existing text search box stays and stacks on top of the category filter.

Non-goal: persisting the selected category across launches (resets to `All`
each launch — YAGNI).

## UX / interaction

Left column layout:

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
```

- **Default category:** `All` — both providers shown (current behavior).
- **Mouse:** clicking a category row sets the active category; the middle list
  filters to that provider (or all for `All`); list selection resets to the
  top and the transcript preview clears.
- **Keyboard:** `←` / `→` cycle the active category
  (`All → Codex → Claude Code → All` and back). `Up`/`Down`/`Enter`/`Space`/`r`
  keep their current meaning.
- **Search interaction:** the middle-column search box is unchanged and stacks
  *on top of* the category filter — the category narrows by provider first,
  then the typed query narrows further within that provider.
- **Counts:** each category shows the number of rows that match the current
  *search query* for that bucket. With an empty query these are plain totals
  (`All` = both providers); when the user types, the counts update live. `All`
  always equals `Codex + Claude Code`.

## Architecture / changes

### `src/ai_history_session.zig`

- New enum `CategoryFilter = enum { all, codex, claude }`.
- `Session` gains `category: CategoryFilter = .all`.
- Add a single visibility predicate used everywhere a row is filtered:
  `fn rowVisible(self, row, query) bool` = `categoryMatches(self.category,
  row.provider) AND types.metadataMatches(row, query)`.
- Route `visibleCount` and `selectedVisible` through `rowVisible` (they
  currently call `types.metadataMatches` directly).
- `fn setCategory(self, category)` — sets `category`, resets `selected` and
  `list_offset` to 0, clears the transcript (mirrors `setFilter`'s reset).
  No-op early-return if the category is unchanged so the transcript is not
  needlessly cleared.
- `fn cycleCategory(self, delta: isize)` — advances the category by `delta`
  (wrapping) and applies it via `setCategory`.
- `fn categoryCounts(self, query) struct { all: usize, codex: usize,
  claude: usize }` — counts rows matching `query` per provider; `all` is the
  sum. This is search-aware but category-independent.

### `src/ai_history_renderer.zig`

- Replace the fragile hand-duplicated offset math (the `refreshButtonTop`
  formula that re-derives the retry-button position from a chain of
  `cell_h + N` terms) with **one `leftColumnLayout()` helper**. It computes,
  from `top` and `cell_h`, the y-rects for: the info block lines, the three
  category rows, and the retry button. Both `renderLeftColumn` and
  `interactionHitTest` consume it, so render and hit-test cannot drift.
- `Hit` union gains a `category: CategoryFilter` variant.
- `interactionHitTest`:
  - Check the three category-row rects → return `.{ .category = ... }`.
  - Retry-button and resume-button and list-row hit-testing unchanged in
    behavior, but the retry-button rect now comes from `leftColumnLayout`.
- `renderLeftColumn`: draw the `CATEGORY` heading and the three rows, each with
  its label and count (counts pulled from `session.categoryCounts(query)`); the
  active category row gets the selection highlight (accent bar + tinted
  background, matching the list's selected-row treatment).
- `renderList`: filter rows by `session.category` in addition to the query
  (it currently has its own `metadataMatches` loop — add the provider check so
  it stays in sync with `Session.visibleCount`). The empty-state text names the
  active category, e.g. `"No Codex sessions"` / `"No Claude Code sessions"`,
  falling back to the existing messages for `All`.

### `src/AppWindow.zig`

- `aiHistoryHandleMousePress`: handle the new `.category` hit by calling
  `session.setCategory(...)`, then `markUiDirty()`.
- New `aiHistoryCycleCategory(delta: isize) bool` — looks up the active
  history session, calls `session.cycleCategory(delta)`, marks UI dirty.

### `src/input.zig`

- In the AI-History key switch, map `platform_input.key_left` →
  `AppWindow.aiHistoryCycleCategory(-1)` and `platform_input.key_right` →
  `AppWindow.aiHistoryCycleCategory(1)`.

## Data flow

```
click left-col category row ──► interactionHitTest ──► Hit.category
                                                          │
key ← / →  ──► aiHistoryCycleCategory ──► session.cycleCategory ─┤
                                                          ▼
                                              Session.setCategory
                                              (category, reset selection,
                                               clear transcript)
                                                          ▼
            renderList / visibleCount / selectedVisible filter via rowVisible
                                                          ▼
                          middle list shows only the active provider
```

## Error handling / edge cases

- Switching to a category with no matching rows: list shows the category-named
  empty-state text; `selectedVisible` returns null; the resume button shows
  "Resume unavailable" as it already does for an absent selection.
- Cycling category wraps in both directions (`←` from `All` goes to
  `Claude Code`).
- `setCategory` to the already-active category is a no-op (does not clear an
  in-progress transcript preview).
- Counts use the current search query, so an active text filter shrinks the
  per-category counts consistently with what the list shows.

## Testing (TDD)

`ai_history_session.zig`:
- `categoryMatches` / `rowVisible` mapping (codex vs claude vs all).
- `visibleCount` and `selectedVisible` respect the active category.
- `categoryCounts` correct with an empty query (plain totals, `all == codex +
  claude`) and with a query that excludes some rows.
- `setCategory` resets `selected`/`list_offset` and clears the transcript;
  no-op when category is unchanged.
- `cycleCategory` wraps forward and backward through the three categories.

`ai_history_renderer.zig`:
- `leftColumnLayout` rects are ordered top-to-bottom and non-overlapping; the
  retry-button rect matches what `interactionHitTest` uses.
- `interactionHitTest` returns the correct `.category` for a click inside each
  of the three category rows, and still returns `.refresh` / `.resume` /
  `.row` for clicks in those regions.
- Existing layout/hit-test tests stay green.
```
