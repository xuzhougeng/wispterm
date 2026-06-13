# Multi Preview Panes (per-kind) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Ctrl+click` preview reuse becomes per content Kind (markdown/text/csv/tsv/image each get their own pane, stacked in the right preview column), so opening an image no longer evicts the markdown preview.

**Architecture:** Two new functions in `src/appwindow/tab.zig` (`previewForReuse` — kind-aware lookup; `splitIntoPreviewStacked` — create a pane below the bottom-most preview), then rewire the two open helpers in `src/input.zig`. Close, persistence, swap, and focus are already pane-generic and unchanged. Spec: `docs/superpowers/specs/2026-06-11-multi-preview-panes-design.md`.

**Tech Stack:** Zig 0.15. Worktree `/home/xzg/project/phantty-worktrees/multi-preview-panes`, branch `worktree-feat-multi-preview-panes`. Run everything from the worktree root.

**Project facts you need (zero-context primer):**

- Test suites: `zig build test` (fast, ~1s) and `zig build test-full` (~minutes; compiles + runs the app test binary, includes `src/appwindow/tab.zig` tests). Both must stay green. Format with `zig fmt <files>` before committing.
- The split tree (`src/split_tree.zig`) is **immutable**: every edit builds a new tree and refs each leaf pane. `Pane = union(enum) { terminal: *Surface, preview: *PreviewPane }`.
- **`split(at, direction, ratio, insert)` renumbering rule** (read `split()` at `src/split_tree.zig:517` if in doubt): old nodes keep their indices, EXCEPT the node at `at`, which is **copied to the last index** (`new_len - 1`); the new split node is written at `at`'s old index; the inserted tree's nodes land at `old_len .. old_len + insert.len`. So after a 1-node insert, the moved node is at `old_len + 1` and the new pane at `old_len`.
- `readingOrder(alloc)` (`src/split_tree.zig`) returns leaf handles in visual top-left→bottom-right order.
- tab.zig tests use a **stack-allocated Surface stub** (never deref'd, refcount kept ≥ 1) plus a `g_tabs` save/restore dance — copy the pattern exactly from the existing test `"tab: splitIntoPreview adds a preview leaf and grows the tree by 2 nodes"` (`src/appwindow/tab.zig`).
- `PreviewPane` (`src/preview_pane.zig`) is refcounted; its `kind: markdown_preview.Kind` field defaults to `.markdown` and is freely writable in tests.

---

### Task 1: `tab.previewForReuse` — kind-aware reuse lookup

**Files:**
- Modify: `src/appwindow/tab.zig` (new import + new function next to `firstPreviewForReuse` at ~line 832; tests at end of file)

- [ ] **Step 1: Write the failing tests**

Append at the end of `src/appwindow/tab.zig` (after the last existing test):

```zig
test "tab: previewForReuse matches preview panes by kind" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = try SplitTree.init(gpa, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // No preview pane at all → null for every kind.
    try std.testing.expect(previewForReuse(gpa, t, .markdown) == null);

    // One markdown pane: markdown matches it, image does not.
    const p1 = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;
    p1.kind = .markdown;
    const h_md = previewForReuse(gpa, t, .markdown) orelse return error.NoMarkdownMatch;
    switch (t.tree.nodes[h_md.idx()]) {
        .leaf => |pane| switch (pane) {
            .preview => |p| try std.testing.expectEqual(p1, p),
            .terminal => return error.MatchedTerminal,
        },
        .split => return error.MatchedSplit,
    }
    try std.testing.expect(previewForReuse(gpa, t, .image) == null);

    // Add an image pane: each kind now resolves to its own pane.
    const p2 = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;
    p2.kind = .image;
    const h_img = previewForReuse(gpa, t, .image) orelse return error.NoImageMatch;
    switch (t.tree.nodes[h_img.idx()]) {
        .leaf => |pane| switch (pane) {
            .preview => |p| try std.testing.expectEqual(p2, p),
            .terminal => return error.MatchedTerminal,
        },
        .split => return error.MatchedSplit,
    }
    const h_md2 = previewForReuse(gpa, t, .markdown) orelse return error.NoMarkdownMatch;
    switch (t.tree.nodes[h_md2.idx()]) {
        .leaf => |pane| switch (pane) {
            .preview => |p| try std.testing.expectEqual(p1, p),
            .terminal => return error.MatchedTerminal,
        },
        .split => return error.MatchedSplit,
    }
    // No csv pane exists → null even though other kinds do.
    try std.testing.expect(previewForReuse(gpa, t, .csv) == null);
}

test "tab: previewForReuse prefers the focused same-kind preview" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = try SplitTree.init(gpa, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // Two markdown panes; reading order would pick p1, but focusing p2's leaf
    // must win.
    const p1 = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;
    p1.kind = .markdown;
    const p2 = splitIntoPreview(gpa) orelse return error.SplitIntoPreviewFailed;
    p2.kind = .markdown;

    var h_p2: ?SplitTree.Node.Handle = null;
    for (t.tree.nodes, 0..) |node, i| switch (node) {
        .leaf => |pane| switch (pane) {
            .preview => |p| if (p == p2) {
                h_p2 = @enumFromInt(i);
            },
            .terminal => {},
        },
        .split => {},
    };
    t.focused = h_p2 orelse return error.P2NotInTree;

    const h = previewForReuse(gpa, t, .markdown) orelse return error.NoMatch;
    try std.testing.expectEqual(t.focused, h);
}
```

- [ ] **Step 2: Run the suite to verify the tests fail**

Run: `cd /home/xzg/project/phantty-worktrees/multi-preview-panes && zig build test-full 2>&1 | tail -20`
Expected: compile error `use of undeclared identifier 'previewForReuse'` (×4). A compile error on the new tests IS the red state in Zig.

- [ ] **Step 3: Implement `previewForReuse`**

In `src/appwindow/tab.zig`, add the import next to the `PreviewPane` import at the top (line ~11):

```zig
const markdown_preview = @import("../markdown_preview.zig");
```

Then add directly below `firstPreviewForReuse` (after its closing brace, ~line 858):

```zig
/// Handle of the preview pane to reuse for `kind`: the focused leaf if it is a
/// preview of that kind, else the first same-kind preview in reading order,
/// else null (caller creates a new pane). Per-kind reuse keeps one pane per
/// content type so e.g. an image preview never evicts the markdown preview.
pub fn previewForReuse(gpa: std.mem.Allocator, t: *const TabState, kind: markdown_preview.Kind) ?SplitTree.Node.Handle {
    // Fast path: focused node is a same-kind preview leaf.
    if (t.focused.idx() < t.tree.nodes.len) {
        switch (t.tree.nodes[t.focused.idx()]) {
            .leaf => |pane| switch (pane) {
                .preview => |p| if (p.kind == kind) return t.focused,
                else => {},
            },
            .split => {},
        }
    }

    // Scan in reading order (top-left → bottom-right) for the first
    // same-kind preview.
    const order = t.tree.readingOrder(gpa) catch return null;
    defer gpa.free(order);

    for (order) |h| {
        switch (t.tree.nodes[h.idx()]) {
            .leaf => |pane| switch (pane) {
                .preview => |p| if (p.kind == kind) return h,
                else => {},
            },
            .split => {},
        }
    }
    return null;
}
```

- [ ] **Step 4: Run the suite to verify the tests pass**

Run: `cd /home/xzg/project/phantty-worktrees/multi-preview-panes && zig build test-full --summary all 2>&1 | grep -E "passed|failed"`
Expected: all steps succeed, 0 failed (baseline was 1585 passed / 6 skipped; now +2).

- [ ] **Step 5: Format and commit**

```bash
cd /home/xzg/project/phantty-worktrees/multi-preview-panes
zig fmt src/appwindow/tab.zig
git add src/appwindow/tab.zig
git commit -m "feat(preview): kind-aware previewForReuse lookup"
```

---

### Task 2: `tab.splitIntoPreviewStacked` — stack new panes in the preview column

**Files:**
- Modify: `src/appwindow/tab.zig` (new functions below `splitIntoPreview`, ~line 827; tests at end of file)

- [ ] **Step 1: Write the failing tests**

Append at the end of `src/appwindow/tab.zig`:

```zig
test "tab: splitIntoPreviewStacked stacks below the existing preview column" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = try SplitTree.init(gpa, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // First preview: no preview exists yet → delegates to the right-edge
    // column split. Tree: [0]=split, [1]=preview, [2]=terminal(focused).
    _ = splitIntoPreviewStacked(gpa) orelse return error.StackedFailed;
    try std.testing.expectEqual(@as(usize, 3), t.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), t.focused.idx());

    // Second preview: splits the existing preview (handle 1) downward.
    // split(at=1): node[1] becomes the new VERTICAL split, old preview moves
    // to the last index, the new pane lands at old_len. Terminal focus (2)
    // is not the split target, so it must not move.
    _ = splitIntoPreviewStacked(gpa) orelse return error.StackedFailed;
    try std.testing.expectEqual(@as(usize, 5), t.tree.nodes.len);
    switch (t.tree.nodes[1]) {
        .split => |s| try std.testing.expectEqual(SplitTree.Split.Layout.vertical, s.layout),
        .leaf => return error.ExpectedSplitNode,
    }

    // Both previews exist; the terminal keeps focus.
    var preview_count: usize = 0;
    var it = t.tree.panes();
    while (it.next()) |entry| {
        switch (entry.pane) {
            .preview => preview_count += 1,
            .terminal => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), preview_count);
    try std.testing.expectEqual(@as(usize, 2), t.focused.idx());
    switch (t.tree.nodes[t.focused.idx()]) {
        .leaf => |pane| switch (pane) {
            .terminal => {},
            .preview => return error.FocusedIsPreview,
        },
        .split => return error.FocusedIsSplit,
    }
}

test "tab: splitIntoPreviewStacked remaps focus when the split target is focused" {
    resetTestTabGlobals();
    const gpa = std.testing.allocator;

    var surface: Surface = undefined;
    surface.ref_count = 1;
    surface.ssh_connection = null;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.title_override_len = 0;
    surface.agent_recent_output_len = 0;

    const t = try gpa.create(TabState);
    t.* = .{
        .kind = .terminal,
        .tree = try SplitTree.init(gpa, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .skill_center_session = null,
        .copilot_session = null,
        .copilot_visible = false,
    };
    defer {
        t.deinit(gpa);
        gpa.destroy(t);
        resetTestTabGlobals();
    }

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = t;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // One preview at handle 1; focus it, then stack a second preview. The
    // split target IS the focused node, so focus must follow the original
    // preview to the last index (old_len + 1 = 4).
    const p1 = splitIntoPreviewStacked(gpa) orelse return error.StackedFailed;
    t.focused = @enumFromInt(1);

    _ = splitIntoPreviewStacked(gpa) orelse return error.StackedFailed;
    try std.testing.expectEqual(@as(usize, 4), t.focused.idx());
    switch (t.tree.nodes[t.focused.idx()]) {
        .leaf => |pane| switch (pane) {
            .preview => |p| try std.testing.expectEqual(p1, p),
            .terminal => return error.FocusedIsTerminal,
        },
        .split => return error.FocusedIsSplit,
    }
}
```

- [ ] **Step 2: Run the suite to verify the tests fail**

Run: `cd /home/xzg/project/phantty-worktrees/multi-preview-panes && zig build test-full 2>&1 | tail -20`
Expected: compile error `use of undeclared identifier 'splitIntoPreviewStacked'`.

- [ ] **Step 3: Implement `splitIntoPreviewStacked` + `lastPreviewInReadingOrder`**

Add directly below `splitIntoPreview`'s closing brace in `src/appwindow/tab.zig` (~line 827):

```zig
/// Handle of the bottom-most preview pane in reading order, or null when the
/// tab has no preview pane.
fn lastPreviewInReadingOrder(gpa: std.mem.Allocator, t: *const TabState) ?SplitTree.Node.Handle {
    const order = t.tree.readingOrder(gpa) catch return null;
    defer gpa.free(order);
    var last: ?SplitTree.Node.Handle = null;
    for (order) |h| {
        switch (t.tree.nodes[h.idx()]) {
            .leaf => |pane| switch (pane) {
                .preview => last = h,
                else => {},
            },
            .split => {},
        }
    }
    return last;
}

/// Create a preview pane stacked BELOW the bottom-most existing preview pane,
/// so previews pile up in the right column instead of carving another
/// full-height column off the terminal. Falls back to splitIntoPreview (the
/// right-edge column) when the tab has no preview yet. Does NOT move focus.
/// Returns the new PreviewPane (BORROWED — the tree owns it). The refcount
/// dance mirrors splitIntoPreview.
pub fn splitIntoPreviewStacked(gpa: std.mem.Allocator) ?*PreviewPane {
    const t = activeTab() orelse return null;
    if (t.kind != .terminal) return null;

    const at = lastPreviewInReadingOrder(gpa, t) orelse return splitIntoPreview(gpa);

    const p = PreviewPane.create(gpa) catch return null;
    var insert = SplitTree.initPane(gpa, .{ .preview = p }) catch {
        p.unref(gpa);
        return null;
    };
    defer insert.deinit();

    const old_len = t.tree.nodes.len;
    const old_focused = t.focused;

    const new_tree = t.tree.split(gpa, at, .down, 0.5, &insert) catch {
        p.unref(gpa);
        return null;
    };

    var old_tree = t.tree;
    t.tree = new_tree;
    old_tree.deinit();

    // split(at) copies the node at `at` to the LAST index (old_len + insert
    // count) and writes the new split node at `at`'s old index; every other
    // old handle keeps its index. So only a focus sitting exactly on `at`
    // needs remapping.
    t.focused = if (old_focused == at)
        @enumFromInt(old_len + 1) // = new nodes.len - 1
    else
        old_focused;

    p.unref(gpa);
    return p;
}
```

- [ ] **Step 4: Run the suite to verify the tests pass**

Run: `cd /home/xzg/project/phantty-worktrees/multi-preview-panes && zig build test-full --summary all 2>&1 | grep -E "passed|failed"`
Expected: all steps succeed, 0 failed (+2 tests over Task 1).

- [ ] **Step 5: Format and commit**

```bash
cd /home/xzg/project/phantty-worktrees/multi-preview-panes
zig fmt src/appwindow/tab.zig
git add src/appwindow/tab.zig
git commit -m "feat(preview): splitIntoPreviewStacked stacks panes in the preview column"
```

---

### Task 3: Rewire `input.zig` open helpers

**Files:**
- Modify: `src/input.zig:3221-3259` (`openPreviewAsync`, `openPreviewNew`)

- [ ] **Step 1: Make `openPreviewAsync` kind-aware and `openPreviewNew` stacked**

In `src/input.zig`, `openPreviewAsync` (~line 3221) currently reads:

```zig
    const pane: *PreviewPane = if (tab.firstPreviewForReuse(gpa, t)) |h|
        switch (t.tree.nodes[h.idx()]) {
            .leaf => |pn| switch (pn) {
                .preview => |p| p,
                else => return false,
            },
            .split => return false,
        }
    else
        (tab.splitIntoPreview(gpa) orelse return false);
```

Change the two function calls (per-kind reuse; stacked creation):

```zig
    const pane: *PreviewPane = if (tab.previewForReuse(gpa, t, kind)) |h|
        switch (t.tree.nodes[h.idx()]) {
            .leaf => |pn| switch (pn) {
                .preview => |p| p,
                else => return false,
            },
            .split => return false,
        }
    else
        (tab.splitIntoPreviewStacked(gpa) orelse return false);
```

In `openPreviewNew` (~line 3246), change:

```zig
    const pane = tab.splitIntoPreview(gpa) orelse return false;
```

to:

```zig
    const pane = tab.splitIntoPreviewStacked(gpa) orelse return false;
```

(`tab.splitIntoPreview` remains in use inside `splitIntoPreviewStacked`'s fallback — do not delete it.)

- [ ] **Step 2: Run both suites**

Run: `cd /home/xzg/project/phantty-worktrees/multi-preview-panes && zig build test --summary all 2>&1 | grep -E "passed|failed" && zig build test-full --summary all 2>&1 | grep -E "passed|failed"`
Expected: both green, 0 failed.

- [ ] **Step 3: Format and commit**

```bash
cd /home/xzg/project/phantty-worktrees/multi-preview-panes
zig fmt src/input.zig
git add src/input.zig
git commit -m "feat(preview): per-kind reuse + stacked placement for Ctrl+click previews"
```

---

### Task 4: Sync user docs (embedded docs/ + wiki/, EN + zh)

`docs/file-explorer.md` is `@embedFile`'d into the in-app `wispterm_docs` AI tool, and `wiki/` must stay in sync with `docs/` (project rule — never dedupe). Behavior changed, so both get a short update.

**Files:**
- Modify: `docs/file-explorer.md`
- Modify: `wiki/File-Explorer.md`
- Modify: `wiki/File-Explorer-zh.md`

- [ ] **Step 1: Update `docs/file-explorer.md`**

Replace the sentence ending the first preview paragraph (line ~13):

```
Explorer, to open the right-side preview panel.
```

with:

```
Explorer, to open a preview pane on the right. Each content type (Markdown,
plain text, CSV/TSV, image) keeps its own pane: previewing another file of the
same type replaces that pane's content, while a different type opens a new
pane stacked below the existing previews — a Markdown file, an image, and a
CSV table can stay on screen at the same time.
```

Replace (line ~55):

```
wheel and can be dragged to pan after zooming. `Ctrl+Shift+W` closes the preview
panel before closing a split.
```

with:

```
wheel and can be dragged to pan after zooming. `Ctrl+Shift+W` closes preview
panes one per press (the focused preview first) before closing a split.
```

- [ ] **Step 2: Update `wiki/File-Explorer.md` and `wiki/File-Explorer-zh.md`**

Read each page, find its preview-panel paragraph (it mirrors the docs text), and apply the same two edits. For the zh page use:

```
每种内容类型（Markdown、纯文本、CSV/TSV、图片）各有自己的预览面板：再次预览同
类型文件会替换该面板的内容；预览不同类型的文件则会在现有预览下方堆叠出一个新
面板——Markdown、图片和 CSV 表格可以同时留在屏幕上。
```

and:

```
`Ctrl+Shift+W` 每按一次关闭一个预览面板（优先关闭聚焦的预览），之后才会关闭分屏。
```

- [ ] **Step 3: Validate wiki link/parity rules**

Run: `cd /home/xzg/project/phantty-worktrees/multi-preview-panes && python3 wiki/check_wiki.py`
Expected: passes (no broken links, EN/zh parity intact).

- [ ] **Step 4: Run test-full (docs are embedded — must still compile)**

Run: `cd /home/xzg/project/phantty-worktrees/multi-preview-panes && zig build test-full --summary all 2>&1 | grep -E "passed|failed"`
Expected: green.

- [ ] **Step 5: Commit**

```bash
cd /home/xzg/project/phantty-worktrees/multi-preview-panes
git add docs/file-explorer.md wiki/File-Explorer.md wiki/File-Explorer-zh.md
git commit -m "docs: per-kind stacked preview panes (docs + wiki, en/zh)"
```

---

## Out of scope (per spec)

- HTML stays on the browser panel — no webview pane work.
- No pane-count cap, no new close semantics, no persistence changes.
- GUI verification happens on Windows/macOS after merge (no Linux GUI backend).
