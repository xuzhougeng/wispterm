# AI History Provider Categories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the AI History left column into a category navigator (All / Codex / Claude Code with counts) that filters the middle session list by provider.

**Architecture:** Add a `CategoryFilter` provider-category type and matching helpers to `ai_history_types.zig`; store the active category on `Session` and route all row-visibility through one predicate; extract the left-column layout math in the renderer into one helper shared by render and hit-test, then add the clickable category rows; wire mouse hits and `←`/`→` keys in `AppWindow.zig` / `input.zig`.

**Tech Stack:** Zig. GPU UI renderer with function-pointer `DrawContext`. Tests are plain Zig `test` blocks. Fast logic suite: `zig build test` (registers `ai_history_types.zig` + `ai_history_session.zig`). Full suite: `zig build test-full` (also registers `renderer/ai_history_renderer.zig` and compiles the app graph incl. `AppWindow.zig` / `input.zig`).

**Spec:** `docs/superpowers/specs/2026-06-02-ai-history-provider-categories-design.md`

**Note on design vs. plan:** the spec said the enum could live in `ai_history_session.zig`; this plan places `CategoryFilter` and its helpers in `ai_history_types.zig` instead, so the renderer and the session share one definition without importing the heavy session module. Behavior is identical to the spec.

---

## File Structure

- `src/ai_history_types.zig` — add `CategoryFilter` enum + `categoryMatches` + `categoryLabel`. Lightweight shared types.
- `src/ai_history_session.zig` — `Session.category` state, `rowVisible`, `setCategory`, `cycleCategory`, `categoryCounts`; route `visibleCount`/`selectedVisible` through `rowVisible`.
- `src/renderer/ai_history_renderer.zig` — extract `leftColumnLayout`; add `Hit.category`; render category rows with counts; filter list + empty-state text by category.
- `src/AppWindow.zig` — handle `.category` mouse hit; add `aiHistoryCycleCategory`.
- `src/input.zig` — map `key_left`/`key_right` to category cycling in the AI History key switch.

---

## Task 1: CategoryFilter type + helpers (types)

**Files:**
- Modify: `src/ai_history_types.zig`
- Test: `src/ai_history_types.zig` (test blocks at end of file)

- [ ] **Step 1: Write the failing tests**

Add these test blocks at the end of `src/ai_history_types.zig`:

```zig
test "ai_history_types: categoryMatches respects provider" {
    try std.testing.expect(categoryMatches(.all, .codex));
    try std.testing.expect(categoryMatches(.all, .claude));
    try std.testing.expect(categoryMatches(.codex, .codex));
    try std.testing.expect(!categoryMatches(.codex, .claude));
    try std.testing.expect(categoryMatches(.claude, .claude));
    try std.testing.expect(!categoryMatches(.claude, .codex));
}

test "ai_history_types: categoryLabel is stable" {
    try std.testing.expectEqualStrings("All", categoryLabel(.all));
    try std.testing.expectEqualStrings("Codex", categoryLabel(.codex));
    try std.testing.expectEqualStrings("Claude Code", categoryLabel(.claude));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: compile error — `error: use of undeclared identifier 'categoryMatches'` (and `categoryLabel`).

- [ ] **Step 3: Add the type and helpers**

In `src/ai_history_types.zig`, immediately after the `ProviderId` enum definition (after its closing `};` near line 13), add:

```zig
pub const CategoryFilter = enum {
    all,
    codex,
    claude,
};

pub fn categoryMatches(category: CategoryFilter, provider: ProviderId) bool {
    return switch (category) {
        .all => true,
        .codex => provider == .codex,
        .claude => provider == .claude,
    };
}

pub fn categoryLabel(category: CategoryFilter) []const u8 {
    return switch (category) {
        .all => "All",
        .codex => "Codex",
        .claude => "Claude Code",
    };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS (full fast suite green).

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_types.zig
git commit -m "feat: add ai history category filter type"
```

---

## Task 2: Session category state + filtering (session)

**Files:**
- Modify: `src/ai_history_session.zig`
- Test: `src/ai_history_session.zig` (test blocks at end of file)

- [ ] **Step 1: Write the failing tests**

Add these test blocks at the end of `src/ai_history_session.zig`:

```zig
test "ai_history_session: category filter limits visible rows" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "cx", .title = "Codex one", .source_path = "a.jsonl", .resume_kind = .codex_resume },
        .{ .provider = .claude, .session_id = "cl", .title = "Claude one", .source_path = "b.jsonl", .resume_kind = .claude_resume },
    };
    try session.replaceRows(&rows);

    try std.testing.expectEqual(@as(usize, 2), session.visibleCount());

    session.setCategory(.codex);
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    const sel = session.selectedVisible() orelse return error.ExpectedSelection;
    try std.testing.expectEqual(types.ProviderId.codex, sel.provider);

    session.setCategory(.claude);
    const sel2 = session.selectedVisible() orelse return error.ExpectedSelection;
    try std.testing.expectEqual(types.ProviderId.claude, sel2.provider);
}

test "ai_history_session: categoryCounts splits by provider and respects query" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "Renderer fix", .source_path = "a.jsonl", .resume_kind = .codex_resume },
        .{ .provider = .codex, .session_id = "b", .title = "Docs", .source_path = "b.jsonl", .resume_kind = .codex_resume },
        .{ .provider = .claude, .session_id = "c", .title = "Renderer test", .source_path = "c.jsonl", .resume_kind = .claude_resume },
    };
    try session.replaceRows(&rows);

    const counts = session.categoryCounts("");
    try std.testing.expectEqual(@as(usize, 3), counts.all);
    try std.testing.expectEqual(@as(usize, 2), counts.codex);
    try std.testing.expectEqual(@as(usize, 1), counts.claude);

    const filtered = session.categoryCounts("renderer");
    try std.testing.expectEqual(@as(usize, 2), filtered.all);
    try std.testing.expectEqual(@as(usize, 1), filtered.codex);
    try std.testing.expectEqual(@as(usize, 1), filtered.claude);
}

test "ai_history_session: setCategory resets selection" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume },
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume },
    };
    try session.replaceRows(&rows);
    session.selected = 1;
    session.list_offset = 1;

    session.setCategory(.codex);
    try std.testing.expectEqual(types.CategoryFilter.codex, session.category);
    try std.testing.expectEqual(@as(usize, 0), session.selected);
    try std.testing.expectEqual(@as(usize, 0), session.list_offset);
}

test "ai_history_session: cycleCategory wraps forward and backward" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    try std.testing.expectEqual(types.CategoryFilter.all, session.category);
    session.cycleCategory(1);
    try std.testing.expectEqual(types.CategoryFilter.codex, session.category);
    session.cycleCategory(1);
    try std.testing.expectEqual(types.CategoryFilter.claude, session.category);
    session.cycleCategory(1);
    try std.testing.expectEqual(types.CategoryFilter.all, session.category);
    session.cycleCategory(-1);
    try std.testing.expectEqual(types.CategoryFilter.claude, session.category);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: compile error — `no field named 'category' in struct` / `no member named 'setCategory'`.

- [ ] **Step 3a: Add the `category` field**

In `src/ai_history_session.zig`, in the `Session` struct field list (after `filter_len: usize = 0,` near line 137), add:

```zig
    category: types.CategoryFilter = .all,
```

- [ ] **Step 3b: Add the visibility predicate and route counts/selection through it**

In `src/ai_history_session.zig`, replace the `visibleCount` and `selectedVisible` methods (currently near lines 354–374) with:

```zig
    pub fn rowVisible(self: *const Session, row: types.SessionMeta, query: []const u8) bool {
        return types.categoryMatches(self.category, row.provider) and types.metadataMatches(row, query);
    }

    pub fn visibleCount(self: *const Session) usize {
        var count: usize = 0;
        const query = self.filter[0..self.filter_len];
        for (self.rows.items) |row| {
            if (self.rowVisible(row, query)) count += 1;
        }
        return count;
    }

    /// Returns a shallow SessionMeta copy. Its string slices are borrowed from
    /// the stored rows and follow the same replacement/deinit lifetime.
    pub fn selectedVisible(self: *const Session) ?types.SessionMeta {
        const query = self.filter[0..self.filter_len];
        var visible_index: usize = 0;
        for (self.rows.items) |row| {
            if (!self.rowVisible(row, query)) continue;
            if (visible_index == self.selected) return row;
            visible_index += 1;
        }
        return null;
    }

    pub fn setCategory(self: *Session, category: types.CategoryFilter) void {
        if (self.category == category) return;
        self.category = category;
        self.selected = 0;
        self.list_offset = 0;
        self.clearTranscript();
    }

    pub fn cycleCategory(self: *Session, delta: isize) void {
        const count: isize = 3;
        const cur: isize = @intFromEnum(self.category);
        const next: usize = @intCast(@mod(cur + delta, count));
        self.setCategory(@enumFromInt(next));
    }

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

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS (full fast suite green; existing session/filter tests unaffected because `.all` is the default).

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_session.zig
git commit -m "feat: filter ai history sessions by provider category"
```

---

## Task 3: Extract left-column layout (renderer refactor, no behavior change)

**Files:**
- Modify: `src/renderer/ai_history_renderer.zig`
- Test: `src/renderer/ai_history_renderer.zig` (test blocks at end of file)

- [ ] **Step 1: Write the failing test**

Add this test block at the end of `src/renderer/ai_history_renderer.zig`:

```zig
test "ai_history_renderer: left column layout is ordered top to bottom" {
    const lc = leftColumnLayout(40, 16);
    try std.testing.expect(lc.source_name_top < lc.target_top);
    try std.testing.expect(lc.target_top < lc.status_label_top);
    try std.testing.expect(lc.status_label_top < lc.status_value_top);
    try std.testing.expect(lc.status_value_top < lc.retry_text_top);
    try std.testing.expectEqual(lc.retry_text_top - BUTTON_PAD_Y, refreshButtonTop(40, 16));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: compile error — `error: use of undeclared identifier 'leftColumnLayout'`.

- [ ] **Step 3a: Add the layout struct and helper**

In `src/renderer/ai_history_renderer.zig`, after the `Layout` struct definition (after its closing `};` near line 29), add:

```zig
pub const LeftColumnLayout = struct {
    source_name_top: f32,
    target_top: f32,
    status_label_top: f32,
    status_value_top: f32,
    retry_text_top: f32,
};

pub fn leftColumnLayout(top: f32, cell_h: f32) LeftColumnLayout {
    var y = top + HEADER_H + 18;
    const source_name_top = y;
    y += cell_h + 8;
    const target_top = y;
    y += cell_h + 18;
    const status_label_top = y;
    y += cell_h + 5;
    const status_value_top = y;
    y += cell_h + 18;
    const retry_text_top = y;
    return .{
        .source_name_top = source_name_top,
        .target_top = target_top,
        .status_label_top = status_label_top,
        .status_value_top = status_value_top,
        .retry_text_top = retry_text_top,
    };
}
```

- [ ] **Step 3b: Point `refreshButtonTop` at the layout helper**

In `src/renderer/ai_history_renderer.zig`, replace the existing `refreshButtonTop` function (currently near lines 432–438) with:

```zig
fn refreshButtonTop(top: f32, cell_h: f32) f32 {
    return leftColumnLayout(top, cell_h).retry_text_top - BUTTON_PAD_Y;
}
```

- [ ] **Step 3c: Rewrite `renderLeftColumn` to consume the layout helper**

In `src/renderer/ai_history_renderer.zig`, replace the body of `renderLeftColumn` (currently lines 171–202; keep the same `fn renderLeftColumn(...) void {` signature) with:

```zig
fn renderLeftColumn(
    draw: DrawContext,
    session: anytype,
    layout: Layout,
    window_height: f32,
    top: f32,
    content_h: f32,
    fg: [3]f32,
    muted: [3]f32,
    accent: [3]f32,
    panel_strong: [3]f32,
    line: [3]f32,
) void {
    draw.fillQuadAlpha(layout.left_x, yFromTop(window_height, top, HEADER_H), layout.left_w, HEADER_H, panel_strong, 0.9);
    draw.fillQuad(layout.left_x, yFromTop(window_height, top + HEADER_H, 1), layout.left_w, 1, line);
    _ = draw.renderTextLimited("AI History", layout.left_x + PAD_X, yTextFromTop(draw, window_height, top + 11), fg, layout.left_w - PAD_X * 2);

    const lc = leftColumnLayout(top, draw.cell_h);
    _ = draw.renderTextLimited(session.source.name, layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.source_name_top), fg, layout.left_w - PAD_X * 2);
    _ = draw.renderTextLimited(targetLabel(session.source.target), layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.target_top), muted, layout.left_w - PAD_X * 2);
    _ = draw.renderTextLimited("Status", layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.status_label_top), muted, layout.left_w - PAD_X * 2);
    _ = draw.renderTextLimited(statusText(session), layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.status_value_top), accent, layout.left_w - PAD_X * 2);
    _ = draw.renderTextLimited("r  Retry scan", layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.retry_text_top), muted, layout.left_w - PAD_X * 2);

    const footer = "Enter resumes  Space previews";
    _ = draw.renderTextLimited(footer, layout.left_x + PAD_X, 12, muted, layout.left_w - PAD_X * 2);
    _ = content_h;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-full`
Expected: PASS — the new ordering test passes and all existing `ai_history_renderer` tests (including "interaction hit test maps buttons and row offset") stay green, because `leftColumnLayout` reproduces the exact previous offsets.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/ai_history_renderer.zig
git commit -m "refactor: extract ai history left column layout helper"
```

---

## Task 4: Render category rows + hit-test + list filter (renderer feature)

**Files:**
- Modify: `src/renderer/ai_history_renderer.zig`
- Test: `src/renderer/ai_history_renderer.zig` (test blocks at end of file)

- [ ] **Step 1: Write the failing test**

Add this test block at the end of `src/renderer/ai_history_renderer.zig`:

```zig
test "ai_history_renderer: interaction hit test maps category rows" {
    const FakeSession = struct {
        fn visibleCount(_: @This()) usize {
            return 0;
        }
        fn listWindowStart(_: @This(), _: usize) usize {
            return 0;
        }
    };

    const session = FakeSession{};
    const layout = computeLayout(0, 1000);
    const cell_h: f32 = 16;
    const top: f32 = 40;
    const lc = leftColumnLayout(top, cell_h);

    const all_y = lc.category_rows_top + lc.category_row_h * 0.5;
    try std.testing.expectEqual(
        Hit{ .category = .all },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, all_y),
    );

    const codex_y = lc.category_rows_top + lc.category_row_h * 1.5;
    try std.testing.expectEqual(
        Hit{ .category = .codex },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, codex_y),
    );

    const claude_y = lc.category_rows_top + lc.category_row_h * 2.5;
    try std.testing.expectEqual(
        Hit{ .category = .claude },
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.left_x + 10, claude_y),
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: compile error — `no field named 'category_rows_top'` / `no field 'category' in union 'Hit'`.

- [ ] **Step 3a: Import the shared types**

In `src/renderer/ai_history_renderer.zig`, change the first line from:

```zig
const std = @import("std");
```

to:

```zig
const std = @import("std");
const types = @import("../ai_history_types.zig");
```

- [ ] **Step 3b: Add the `category` variant to `Hit`**

In `src/renderer/ai_history_renderer.zig`, replace the `Hit` union (currently near lines 31–36) with:

```zig
pub const Hit = union(enum) {
    none,
    refresh,
    @"resume",
    category: types.CategoryFilter,
    row: usize,
};
```

- [ ] **Step 3c: Add category fields to `LeftColumnLayout` and `leftColumnLayout`**

In `src/renderer/ai_history_renderer.zig`, replace the `LeftColumnLayout` struct and `leftColumnLayout` function (added in Task 3) with:

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
};

pub fn leftColumnLayout(top: f32, cell_h: f32) LeftColumnLayout {
    var y = top + HEADER_H + 18;
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
    return .{
        .source_name_top = source_name_top,
        .target_top = target_top,
        .status_label_top = status_label_top,
        .status_value_top = status_value_top,
        .category_heading_top = category_heading_top,
        .category_rows_top = category_rows_top,
        .category_row_h = category_row_h,
        .retry_text_top = retry_text_top,
    };
}
```

- [ ] **Step 3d: Add the category hit-test to `interactionHitTest`**

In `src/renderer/ai_history_renderer.zig`, in `interactionHitTest`, find these lines (near 110–114):

```zig
    const refresh_top = refreshButtonTop(top, cell_h);
    if (rectContains(mx, my, layout.left_x + PAD_X, refresh_top, @max(0, layout.left_w - PAD_X * 2), buttonHeight(cell_h))) {
        return .refresh;
    }
```

and insert, immediately before that block:

```zig
    const lc = leftColumnLayout(top, cell_h);
    const categories = [_]types.CategoryFilter{ .all, .codex, .claude };
    for (categories, 0..) |cat, i| {
        const cat_top = lc.category_rows_top + @as(f32, @floatFromInt(i)) * lc.category_row_h;
        if (rectContains(mx, my, layout.left_x, cat_top, layout.left_w, lc.category_row_h)) {
            return .{ .category = cat };
        }
    }
```

- [ ] **Step 3e: Render the category section in `renderLeftColumn`**

In `src/renderer/ai_history_renderer.zig`, in `renderLeftColumn`, replace this single line (the retry line added in Task 3):

```zig
    _ = draw.renderTextLimited("r  Retry scan", layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.retry_text_top), muted, layout.left_w - PAD_X * 2);
```

with:

```zig
    _ = draw.renderTextLimited("CATEGORY", layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.category_heading_top), muted, layout.left_w - PAD_X * 2);

    const query = session.filter[0..session.filter_len];
    const counts = session.categoryCounts(query);
    const selected_bg = mixColor(draw.bg, accent, 0.18);
    const categories = [_]types.CategoryFilter{ .all, .codex, .claude };
    for (categories, 0..) |cat, i| {
        const row_top = lc.category_rows_top + @as(f32, @floatFromInt(i)) * lc.category_row_h;
        const active = session.category == cat;
        if (active) {
            const row_y = yFromTop(window_height, row_top, lc.category_row_h);
            draw.fillQuadAlpha(layout.left_x, row_y, layout.left_w, lc.category_row_h, selected_bg, 0.92);
            draw.fillQuad(layout.left_x, row_y, 3, lc.category_row_h, accent);
        }
        const text_top = row_top + (lc.category_row_h - draw.cell_h) / 2;
        const label_color = if (active) fg else muted;
        const count = switch (cat) {
            .all => counts.all,
            .codex => counts.codex,
            .claude => counts.claude,
        };
        var num_buf: [16]u8 = undefined;
        const num_text = std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch "";
        const count_w: f32 = 44;
        const count_x = layout.left_x + layout.left_w - PAD_X - count_w;
        const label_x = layout.left_x + PAD_X + 6;
        _ = draw.renderTextLimited(categoryLabelText(cat), label_x, yTextFromTop(draw, window_height, text_top), label_color, @max(0, count_x - label_x - 6));
        _ = draw.renderTextLimited(num_text, count_x, yTextFromTop(draw, window_height, text_top), muted, count_w);
    }

    _ = draw.renderTextLimited("r  Retry scan", layout.left_x + PAD_X, yTextFromTop(draw, window_height, lc.retry_text_top), muted, layout.left_w - PAD_X * 2);
```

- [ ] **Step 3f: Add the `categoryLabelText` wrapper**

In `src/renderer/ai_history_renderer.zig`, next to `targetLabel` (near line 368), add:

```zig
fn categoryLabelText(category: types.CategoryFilter) []const u8 {
    return types.categoryLabel(category);
}
```

- [ ] **Step 3g: Filter the list and empty-state text by category**

In `src/renderer/ai_history_renderer.zig`, in `renderList`, find the loop header (near line 232):

```zig
    for (session.rows.items) |row| {
        if (!metadataMatches(row, query)) continue;
```

and replace those two lines with:

```zig
    for (session.rows.items) |row| {
        if (!types.categoryMatches(session.category, row.provider)) continue;
        if (!metadataMatches(row, query)) continue;
```

Then, still in `renderList`, replace the empty-state block (currently near lines 259–267):

```zig
    if (session.visibleCount() == 0) {
        const empty = if (session.state == .scanning)
            "Scanning AI history..."
        else if (session.rows.items.len == 0)
            "No Codex or Claude Code history found"
        else
            "No sessions match filter";
        _ = draw.renderTextLimited(empty, layout.list_x + PAD_X, yTextFromTop(draw, window_height, row_top + 24), muted, layout.list_w - PAD_X * 2);
    }
```

with:

```zig
    if (session.visibleCount() == 0) {
        const empty = if (session.state == .scanning)
            "Scanning AI history..."
        else if (session.rows.items.len == 0)
            "No Codex or Claude Code history found"
        else switch (session.category) {
            .all => "No sessions match filter",
            .codex => "No Codex sessions",
            .claude => "No Claude Code sessions",
        };
        _ = draw.renderTextLimited(empty, layout.list_x + PAD_X, yTextFromTop(draw, window_height, row_top + 24), muted, layout.list_w - PAD_X * 2);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-full`
Expected: PASS — the new "maps category rows" test passes; the existing "interaction hit test maps buttons and row offset" test stays green (its refresh/resume/row mouse coordinates are derived from `refreshButtonTop`/`resumeButtonTop`, which shift consistently with the inserted rows).

- [ ] **Step 5: Commit**

```bash
git add src/renderer/ai_history_renderer.zig
git commit -m "feat: render ai history provider category column"
```

---

## Task 5: Wire mouse hit + category cycling (AppWindow)

**Files:**
- Modify: `src/AppWindow.zig:884-901` (the `aiHistoryHandleMousePress` switch) and add a new function near `aiHistoryMoveSelection` (near line 685).

No unit test (AppWindow is GUI glue, not in the fast suite); verification is a clean `zig build test-full` compile of the app graph.

- [ ] **Step 1: Handle the `.category` mouse hit**

In `src/AppWindow.zig`, in `aiHistoryHandleMousePress`, find the `switch (hit)` block (near lines 884–901) and add a `.category` arm. Replace:

```zig
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
            session.selectVisibleIndex(visible_index);
            session.ensureSelectionVisible(visible_rows);
            markUiDirty();
            return true;
        },
    }
```

with:

```zig
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
        .category => |category| {
            session.setCategory(category);
            session.ensureSelectionVisible(visible_rows);
            markUiDirty();
            return true;
        },
        .row => |visible_index| {
            session.selectVisibleIndex(visible_index);
            session.ensureSelectionVisible(visible_rows);
            markUiDirty();
            return true;
        },
    }
```

- [ ] **Step 2: Add the `aiHistoryCycleCategory` function**

In `src/AppWindow.zig`, immediately after the `aiHistoryMoveSelection` function (which ends near line 691), add:

```zig
pub fn aiHistoryCycleCategory(delta: isize) bool {
    const session = activeAiHistory() orelse return false;
    session.cycleCategory(delta);
    session.ensureSelectionVisible(aiHistoryListVisibleRowsForWindow());
    markUiDirty();
    return true;
}
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build test-full`
Expected: PASS (the app graph compiles with the new arm and function; `types.CategoryFilter` flows from the renderer `Hit` into `session.setCategory`, both being `ai_history_types.CategoryFilter`).

- [ ] **Step 4: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat: handle ai history category selection in app window"
```

---

## Task 6: Map ← / → keys to category cycling (input)

**Files:**
- Modify: `src/input.zig:1153-1160` (the AI History key switch)

No unit test; verification is a clean `zig build test-full` compile.

- [ ] **Step 1: Add the left/right arms**

In `src/input.zig`, in the AI History key `switch (ev.key_code)` block, find the `key_up` / `key_down` arms (near lines 1153–1160):

```zig
            platform_input.key_up => {
                _ = AppWindow.aiHistoryMoveSelection(-1);
                return;
            },
            platform_input.key_down => {
                _ = AppWindow.aiHistoryMoveSelection(1);
                return;
            },
```

and insert immediately after the `key_down` arm:

```zig
            platform_input.key_left => {
                _ = AppWindow.aiHistoryCycleCategory(-1);
                return;
            },
            platform_input.key_right => {
                _ = AppWindow.aiHistoryCycleCategory(1);
                return;
            },
```

- [ ] **Step 2: Verify it compiles and the full suite passes**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/input.zig
git commit -m "feat: cycle ai history category with arrow keys"
```

---

## Task 7: Final verification

**Files:** none (verification only).

- [ ] **Step 1: Run the fast logic suite**

Run: `zig build test`
Expected: PASS (types + session category tests green).

- [ ] **Step 2: Run the full suite**

Run: `zig build test-full`
Expected: PASS (renderer category tests green; app graph compiles).

- [ ] **Step 3: Build the app binary**

Run: `zig build`
Expected: builds with no errors.

- [ ] **Step 4: Manual GUI check (record outcome, do not auto-pass)**

Launch the app, open an AI History tab, and confirm:
- The left column shows `CATEGORY` with `All` / `Codex` / `Claude Code` and live counts.
- Clicking a category filters the middle list; the active row is highlighted.
- `←` / `→` cycle the category; counts and the list update.
- Typing in the search box narrows within the active category and the counts shrink accordingly.
- Switching category resets the selection to the top and clears the transcript preview.

GUI verification is manual; note the result (pass/fail) rather than assuming success.
```
