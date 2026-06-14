# tmux Control Mode — Phase 3c-1 (tmux layout → SplitTree) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `SplitTree.fromTmuxLayout` — build a WispTerm `SplitTree` from a parsed tmux `layout.Node` tree, folding tmux's N-ary rows/columns into WispTerm's binary splits with geometry-derived ratios, materializing one `*Surface` per pane via a caller-supplied `pane_id` factory.

**Architecture:** A direct sibling of the existing `SplitTree.fromSnapshot` (session-restore) constructor: a pre-order builder writes nodes into an arena-backed `nodes` array and returns a `SplitTree`. The only new wrinkle is folding an N-child tmux split (`{a,b,c}` / `[a,b,c]`) into a right-leaning chain of binary `Split` nodes whose ratios come from each child's cell width/height, so geometry is preserved. The factory (`fn(ctx, pane_id) ?*Surface`) transfers exactly one ref per leaf to the new tree (identical ownership contract to `fromSnapshot`) — Phase 3c-2 backs it with `PaneMap` (reuse an existing pane's surface via `surface.ref()`, or create a `Surface.initVirtual` for a new pane).

**Tech Stack:** Zig 0.15.2. Pure tree logic — no libc, no real `Surface`. Tested in `split_tree.zig` with sentinel-pointer factories (exactly like the existing `fromSnapshot` tests) and real `layout.parse` output, run by `zig build test-full` (the app test binary, where `split_tree.zig` is registered).

**Reference:** Spec `docs/superpowers/specs/2026-06-03-tmux-control-mode-integration-design.md` (the `split_tree.zig` row: "Add a `reconcileFromTmuxLayout(layout_tree)` entry"). Templates: `src/split_tree.zig` `fromSnapshot` (line ~1006) + its two tests (line ~1118). Layout types: `src/tmux/layout.zig` (`Node`, `Node.Leaf{x,y,w,h,pane_id}`, `Node.Split{dir,x,y,w,h,children}`, `Dir{horizontal,vertical}`, `parse`).

---

## Phase 3c decomposition (Scope Check)

Phase 3c ("reconcile pane model → `split_tree` + windows → tabs") spans two independent subsystems with very different blast radii and testability. Per the writing-plans Scope Check they become separate plans:

- **3c-1 (this plan):** `SplitTree.fromTmuxLayout` — the pure layout→tree builder + N-ary→binary folding + ratios. Self-contained; unit-testable with sentinel factories; no AppWindow, no real `Surface`.
- **3c-2 (next plan):** AppWindow/tab wiring — back the factory with `PaneMap` (add a `?*Surface` to `PaneMap.Pane`; reuse-or-create), swap the reconciled tree into the live `TabState` (the `old=t.tree; t.tree=new; old.deinit()` idiom), `PaneMap.removePane` for vanished panes, map `Session` window events → tab create/rename/close, and resolve `focused`/active-pane from `Session.active_pane`. Integration-heavy and GUI-verified, like 3b's `initVirtual`.
- **3d (later plan):** connection + controller read-loop + bootstrap (`list-windows`/`capture-pane`/`refresh-client`).

This plan delivers 3c-1 only.

---

## Why this mirrors `fromSnapshot` (read before implementing)

`SplitTree` (`src/split_tree.zig`) is an **immutable, ref-counted, binary** tree. `nodes: []const Node` (node 0 = root), `Node = union{ leaf: *Surface, split: Split }`, `Split{ layout: {horizontal,vertical}, ratio: f16, left: Handle, right: Handle }`. `Handle` is a `u16` index (`Backing`).

`fromSnapshot(gpa, snap, factory)` is the established "build a whole tree from an external description" path:
- Pre-counts nodes, allocates an arena + exact `nodes` array.
- A recursive `writeNode` reserves the current node's index (`idx++`) **before** recursing into children (pre-order: parent index < child indices), then fills the node.
- For a leaf it calls `factory(...) orelse return error.SurfaceCreationFailed` and stores the returned `*Surface` **without** calling `.ref()` — i.e. the new tree assumes ownership of one ref. (`init`/`split`/`clone` ref because they share existing trees; `fromSnapshot` does not because the factory hands it a fresh ref.)
- On factory failure, surfaces already created leak (documented; the caller treats it as fatal).

`fromTmuxLayout` is the same shape. The one new piece is the **N-ary fold**: a tmux `Split` has `children: []Node` (≥2). WispTerm splits are binary, so `{a,b,c}` becomes `split(a, split(b,c))`, and the ratio at each level is the first child's size over the remaining total — preserving geometry. tmux `Dir.horizontal` (`{…}`, left-to-right) maps to `Split.Layout.horizontal`; `Dir.vertical` (`[…]`, top-to-bottom) to `.vertical`.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/split_tree.zig` | MODIFY. Add `pub fn fromTmuxLayout(gpa, root: *const tmux_layout.Node, ctx, factory) !SplitTree` plus two private helpers (`countLayoutNodes`, `tmuxSizeAlong`), as a sibling of `fromSnapshot`. Add tests alongside the existing `fromSnapshot` tests. `@import("tmux/layout.zig")` lazily inside the function (matching how `fromSnapshot` does `@import("session_persist.zig")`). No new test registration needed — `split_tree.zig` is already in `test_main.zig`. |

---

## Task 1: `fromTmuxLayout` — leaf + binary splits

**Files:**
- Modify: `src/split_tree.zig` (add `fromTmuxLayout` + helpers; add tests)

- [ ] **Step 1: Write the failing tests**

In `src/split_tree.zig`, add these tests at the end of the file (after the `"SplitTree: fromSnapshot clamps ratios"` test):

```zig
test "fromTmuxLayout: single leaf becomes a one-node tree" {
    const layout = @import("tmux/layout.zig");
    var parsed = try layout.parse(std.testing.allocator, "bd1b,80x24,0,0,5");
    defer parsed.deinit();

    const Stub = struct {
        var sentinels: [8]usize = undefined;
        fn make(_: *anyopaque, pane_id: usize) ?*Surface {
            return @ptrCast(@alignCast(&sentinels[pane_id]));
        }
    };

    var tree = try fromTmuxLayout(std.testing.allocator, &parsed.root, undefined, Stub.make);
    defer {
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    try std.testing.expectEqual(@as(usize, 1), tree.nodes.len);
    try std.testing.expect(tree.nodes[0] == .leaf);
    const sentinel_5: *Surface = @ptrCast(@alignCast(&Stub.sentinels[5]));
    try std.testing.expectEqual(sentinel_5, tree.nodes[0].leaf);
}

test "fromTmuxLayout: two-pane horizontal row -> binary split with width ratio" {
    const layout = @import("tmux/layout.zig");
    // Two 40-wide panes in an 80-wide window: ratio 40/80 = 0.5.
    var parsed = try layout.parse(std.testing.allocator, "bd1b,80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    defer parsed.deinit();

    const Stub = struct {
        var sentinels: [8]usize = undefined;
        fn make(_: *anyopaque, pane_id: usize) ?*Surface {
            return @ptrCast(@alignCast(&sentinels[pane_id]));
        }
    };

    var tree = try fromTmuxLayout(std.testing.allocator, &parsed.root, undefined, Stub.make);
    defer {
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    // Pre-order: [split, leaf%1, leaf%2].
    try std.testing.expectEqual(@as(usize, 3), tree.nodes.len);
    try std.testing.expect(tree.nodes[0] == .split);
    try std.testing.expectEqual(SplitTree.Split.Layout.horizontal, tree.nodes[0].split.layout);
    try std.testing.expectApproxEqAbs(@as(f16, 0.5), tree.nodes[0].split.ratio, 0.01);
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 1), @intFromEnum(tree.nodes[0].split.left));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 2), @intFromEnum(tree.nodes[0].split.right));
    const s1: *Surface = @ptrCast(@alignCast(&Stub.sentinels[1]));
    const s2: *Surface = @ptrCast(@alignCast(&Stub.sentinels[2]));
    try std.testing.expectEqual(s1, tree.nodes[1].leaf);
    try std.testing.expectEqual(s2, tree.nodes[2].leaf);
}

test "fromTmuxLayout: two-pane vertical column maps to vertical layout" {
    const layout = @import("tmux/layout.zig");
    var parsed = try layout.parse(std.testing.allocator, "80x24,0,0[80x18,0,0,1,80x6,0,18,2]");
    defer parsed.deinit();

    const Stub = struct {
        var sentinels: [8]usize = undefined;
        fn make(_: *anyopaque, pane_id: usize) ?*Surface {
            return @ptrCast(@alignCast(&sentinels[pane_id]));
        }
    };

    var tree = try fromTmuxLayout(std.testing.allocator, &parsed.root, undefined, Stub.make);
    defer {
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    try std.testing.expectEqual(SplitTree.Split.Layout.vertical, tree.nodes[0].split.layout);
    // Top pane is 18 of 24 rows: ratio 0.75.
    try std.testing.expectApproxEqAbs(@as(f16, 0.75), tree.nodes[0].split.ratio, 0.01);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test-full`
Expected: FAIL — compile error, `fromTmuxLayout` is not declared (`error: use of undeclared identifier 'fromTmuxLayout'`).

- [ ] **Step 3: Implement `fromTmuxLayout` + helpers (binary only for now)**

In `src/split_tree.zig`, add immediately after the `countSnapNodes` function (just before the `// ===== Tests =====` divider near line 1080):

```zig
/// Build a SplitTree from a parsed tmux `layout.Node` tree (`%layout-change`).
/// The factory materializes one `*Surface` per pane id; the new tree assumes
/// ownership of exactly one ref per returned surface (it does NOT call `.ref()`
/// itself), identical to `fromSnapshot`. Returning null aborts with
/// error.SurfaceCreationFailed, leaking any surfaces already produced (the
/// caller — Phase 3c-2 — treats this as fatal).
///
/// tmux splits are N-ary; WispTerm splits are binary, so an N-child row/column
/// is folded into a right-leaning chain of binary splits whose ratios come from
/// each child's cell width (horizontal) or height (vertical), preserving
/// geometry. `zoomed` is null; the caller resolves focus/active-pane.
pub fn fromTmuxLayout(
    gpa: Allocator,
    root: *const @import("tmux/layout.zig").Node,
    ctx: *anyopaque,
    factory: *const fn (ctx: *anyopaque, pane_id: usize) ?*Surface,
) !SplitTree {
    const tmux_layout = @import("tmux/layout.zig");
    const total = countLayoutNodes(root);
    if (total > std.math.maxInt(Node.Handle.Backing)) return error.OutOfMemory;

    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const nodes = try alloc.alloc(Node, total);

    const Ctx = struct {
        nodes: []Node,
        idx: usize = 0,
        ctx: *anyopaque,
        factory: *const fn (ctx: *anyopaque, pane_id: usize) ?*Surface,

        fn build(self: *@This(), n: *const tmux_layout.Node) !Node.Handle {
            switch (n.*) {
                .leaf => |leaf| {
                    const handle: Node.Handle = @enumFromInt(@as(Node.Handle.Backing, @intCast(self.idx)));
                    self.idx += 1;
                    const surface = self.factory(self.ctx, leaf.pane_id) orelse return error.SurfaceCreationFailed;
                    self.nodes[handle.idx()] = .{ .leaf = surface };
                    return handle;
                },
                .split => |sp| return self.buildChain(sp.children, sp.dir),
            }
        }

        fn buildChain(self: *@This(), children: []const tmux_layout.Node, dir: tmux_layout.Dir) !Node.Handle {
            // A tmux split always has >= 2 children; a lone child is just that child.
            if (children.len == 1) return self.build(&children[0]);
            // Phase 3c-1 Task 1 handles only the binary case; Task 2 generalizes.
            if (children.len != 2) return error.UnsupportedLayout;

            // Reserve this split's index before its children (pre-order).
            const handle: Node.Handle = @enumFromInt(@as(Node.Handle.Backing, @intCast(self.idx)));
            self.idx += 1;

            const left = try self.build(&children[0]);
            const right = try self.build(&children[1]);

            const first = tmuxSizeAlong(children[0], dir);
            const total_size = first + tmuxSizeAlong(children[1], dir);
            const ratio: f16 = if (total_size == 0)
                0.5
            else
                @as(f16, @floatFromInt(first)) / @as(f16, @floatFromInt(total_size));

            self.nodes[handle.idx()] = .{ .split = .{
                .layout = switch (dir) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = ratio,
                .left = left,
                .right = right,
            } };
            return handle;
        }
    };

    var c = Ctx{ .nodes = nodes, .ctx = ctx, .factory = factory };
    _ = try c.build(root);

    return .{
        .arena = arena,
        .nodes = nodes,
        .zoomed = null,
    };
}

/// Number of SplitTree nodes a tmux layout tree expands to: each leaf is one
/// node, and an N-child split contributes its children's nodes plus (N-1)
/// binary split nodes.
fn countLayoutNodes(n: *const @import("tmux/layout.zig").Node) usize {
    return switch (n.*) {
        .leaf => 1,
        .split => |s| blk: {
            var sum: usize = 0;
            for (s.children) |*child| sum += countLayoutNodes(child);
            break :blk sum + (s.children.len - 1);
        },
    };
}

/// Size of a layout node along the split axis: width for a horizontal row,
/// height for a vertical column.
fn tmuxSizeAlong(n: @import("tmux/layout.zig").Node, dir: @import("tmux/layout.zig").Dir) u32 {
    const w: u32, const h: u32 = switch (n) {
        .leaf => |l| .{ l.w, l.h },
        .split => |s| .{ s.w, s.h },
    };
    return switch (dir) {
        .horizontal => w,
        .vertical => h,
    };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test-full`
Expected: PASS, exit 0. The three Task-1 tests pass (single leaf, 2-pane horizontal ratio + node order, 2-pane vertical layout/ratio). The N-ary path is still `error.UnsupportedLayout` — Task 2 covers it.

- [ ] **Step 5: Commit**

```bash
git add src/split_tree.zig
git commit -m "feat(tmux): SplitTree.fromTmuxLayout — build a binary split tree from a tmux layout"
```

---

## Task 2: N-ary fold + nested + failure path

**Files:**
- Modify: `src/split_tree.zig` (generalize `buildChain`; add tests)

- [ ] **Step 1: Write the failing test (3-pane row)**

In `src/split_tree.zig`, add after the Task-1 tests:

```zig
test "fromTmuxLayout: three-pane row folds into nested binary splits with geometry ratios" {
    const layout = @import("tmux/layout.zig");
    // Widths 20, 40, 20 across an 80-wide window.
    var parsed = try layout.parse(std.testing.allocator, "80x24,0,0{20x24,0,0,1,40x24,20,0,2,20x24,60,0,3}");
    defer parsed.deinit();

    const Stub = struct {
        var sentinels: [8]usize = undefined;
        fn make(_: *anyopaque, pane_id: usize) ?*Surface {
            return @ptrCast(@alignCast(&sentinels[pane_id]));
        }
    };

    var tree = try fromTmuxLayout(std.testing.allocator, &parsed.root, undefined, Stub.make);
    defer {
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    // {a,b,c} -> split(a, split(b,c)). Pre-order:
    // [outer_split, leaf%1, inner_split, leaf%2, leaf%3]  => 5 nodes.
    try std.testing.expectEqual(@as(usize, 5), tree.nodes.len);

    const outer = tree.nodes[0].split;
    try std.testing.expectEqual(SplitTree.Split.Layout.horizontal, outer.layout);
    // Pane %1 is 20 of 80: ratio 0.25.
    try std.testing.expectApproxEqAbs(@as(f16, 0.25), outer.ratio, 0.01);
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 1), @intFromEnum(outer.left));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 2), @intFromEnum(outer.right));

    const inner = tree.nodes[2].split;
    try std.testing.expectEqual(SplitTree.Split.Layout.horizontal, inner.layout);
    // Inner separates 40 from 20: ratio 40/60 = 0.667.
    try std.testing.expectApproxEqAbs(@as(f16, 0.667), inner.ratio, 0.01);

    const s1: *Surface = @ptrCast(@alignCast(&Stub.sentinels[1]));
    const s2: *Surface = @ptrCast(@alignCast(&Stub.sentinels[2]));
    const s3: *Surface = @ptrCast(@alignCast(&Stub.sentinels[3]));
    try std.testing.expectEqual(s1, tree.nodes[1].leaf);
    try std.testing.expectEqual(s2, tree.nodes[3].leaf);
    try std.testing.expectEqual(s3, tree.nodes[4].leaf);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-full`
Expected: FAIL — the test returns `error.UnsupportedLayout` from the 3-child split (the run reports the test erroring, not a compile error).

- [ ] **Step 3: Generalize `buildChain` to fold N children**

In `src/split_tree.zig`, replace the body of `buildChain` (the `fn buildChain(...)` inside `fromTmuxLayout`'s `Ctx`) with the recursive first-vs-rest fold:

```zig
        fn buildChain(self: *@This(), children: []const tmux_layout.Node, dir: tmux_layout.Dir) !Node.Handle {
            // A tmux split always has >= 2 children; a lone child is just that child.
            if (children.len == 1) return self.build(&children[0]);

            // Reserve this split's index before its children (pre-order).
            const handle: Node.Handle = @enumFromInt(@as(Node.Handle.Backing, @intCast(self.idx)));
            self.idx += 1;

            // Fold right: this split separates children[0] from the rest.
            const left = try self.build(&children[0]);
            const right = if (children.len == 2)
                try self.build(&children[1])
            else
                try self.buildChain(children[1..], dir);

            const first = tmuxSizeAlong(children[0], dir);
            var total_size: u32 = 0;
            for (children) |child| total_size += tmuxSizeAlong(child, dir);
            const ratio: f16 = if (total_size == 0)
                0.5
            else
                @as(f16, @floatFromInt(first)) / @as(f16, @floatFromInt(total_size));

            self.nodes[handle.idx()] = .{ .split = .{
                .layout = switch (dir) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = ratio,
                .left = left,
                .right = right,
            } };
            return handle;
        }
```

(The `error.UnsupportedLayout` branch is gone; the `total_size` is now the sum over all remaining children so each level's ratio is "first child over the rest of this chain".)

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test-full`
Expected: PASS, exit 0. The 3-pane fold produces `split(%1, split(%2,%3))` with ratios 0.25 and 0.667.

- [ ] **Step 5: Add nested + failure-path coverage**

In `src/split_tree.zig`, add after the 3-pane test:

```zig
test "fromTmuxLayout: a column nested inside a row preserves nesting and per-axis ratios" {
    const layout = @import("tmux/layout.zig");
    // Left pane %1 (40 wide); right is a vertical stack of %2 (18 high) over %3 (6 high).
    var parsed = try layout.parse(std.testing.allocator, "80x24,0,0{40x24,0,0,1,40x24,40,0[40x18,40,0,2,40x6,40,18,3]}");
    defer parsed.deinit();

    const Stub = struct {
        var sentinels: [8]usize = undefined;
        fn make(_: *anyopaque, pane_id: usize) ?*Surface {
            return @ptrCast(@alignCast(&sentinels[pane_id]));
        }
    };

    var tree = try fromTmuxLayout(std.testing.allocator, &parsed.root, undefined, Stub.make);
    defer {
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    // Pre-order: [outer(horizontal), leaf%1, inner(vertical), leaf%2, leaf%3].
    try std.testing.expectEqual(@as(usize, 5), tree.nodes.len);
    try std.testing.expectEqual(SplitTree.Split.Layout.horizontal, tree.nodes[0].split.layout);
    try std.testing.expectApproxEqAbs(@as(f16, 0.5), tree.nodes[0].split.ratio, 0.01);
    const inner = tree.nodes[tree.nodes[0].split.right.idx()].split;
    try std.testing.expectEqual(SplitTree.Split.Layout.vertical, inner.layout);
    // Vertical inner: top %2 is 18 of 24 -> 0.75.
    try std.testing.expectApproxEqAbs(@as(f16, 0.75), inner.ratio, 0.01);
}

test "fromTmuxLayout: a null from the factory aborts with SurfaceCreationFailed" {
    const layout = @import("tmux/layout.zig");
    var parsed = try layout.parse(std.testing.allocator, "80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    defer parsed.deinit();

    const Stub = struct {
        fn make(_: *anyopaque, _: usize) ?*Surface {
            return null;
        }
    };

    try std.testing.expectError(
        error.SurfaceCreationFailed,
        fromTmuxLayout(std.testing.allocator, &parsed.root, undefined, Stub.make),
    );
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test-full`
Expected: PASS, exit 0. Nested row/column ratios are correct per-axis, and a null factory result surfaces as `error.SurfaceCreationFailed`.

- [ ] **Step 7: Commit**

```bash
git add src/split_tree.zig
git commit -m "feat(tmux): fold N-ary tmux rows/columns into binary SplitTree splits"
```

---

## Phase 3c-1 Done — What Ships

`SplitTree.fromTmuxLayout(gpa, root, ctx, factory)` — converts a parsed tmux `layout.Node` tree into a WispTerm `SplitTree`: N-ary rows/columns folded into geometry-preserving binary splits, one `*Surface` per pane via the factory (one-ref ownership transfer, matching `fromSnapshot`), `error.SurfaceCreationFailed` on a null factory result. Fully unit-tested (leaf, binary H/V with width/height ratios, 3-pane fold, nested row-in-column, failure path) — no real `Surface`, no AppWindow. No consumer yet.

## Remaining Phase 3c / 3d (separate plans — study required)

- **3c-2 — AppWindow/tab wiring (GUI-integrated).** Give `PaneMap.Pane` a `surface: ?*Surface`. Build a reconcile entry that, on a `Session` `%layout-change` for a window: calls `fromTmuxLayout` with a factory that, per `pane_id`, returns `paneMap.find(id).?.surface.?.ref()` if the pane exists, else opens a `Pty.openVirtual`, builds a `Surface.initVirtual`, `paneMap.addPane(id, controller_fd)` + stores the surface, and returns it (ref 1). Then swap into the tab via the standard idiom (`var old = t.tree; t.tree = new; old.deinit();`) and `paneMap.removePane(id)` for every pane in the old set but not the new layout (the old tree's `deinit` unrefs their surfaces to destruction). Map `Session` window events (`%window-add`/`%window-renamed`/`%window-close`/`%window-pane-changed`) → `tab.zig` create/rename/close + `t.focused`. Study `appwindow/tab.zig` (`spawnTabWithCommandAndCwd`, `closeTab`, the `splitFocusedSurfaceWithCommand` tree-swap at lines ~712–730) and `AppWindow` threading. GUI-verified (can't build a real `Surface` headlessly — see [[wispterm-tmux-control-mode-integration]] finding (b)).
- **3d — Connection + bootstrap + pump loop.** Launch `ssh … tmux -CC`, run the controller read-loop (poll ssh fd + all `controller_fd`s; route ssh→`Session.feed`, drain `Session.pendingCommands()`→ssh pipe, `PaneMap.pumpKeystrokes`), and wire `list-windows`/`capture-pane`/`refresh-client -C`.

---

## Self-Review

**1. Spec coverage (3c-1 slice).** The spec's `split_tree.zig` row ("Add a `reconcileFromTmuxLayout(layout_tree)` entry that diffs the desired pane set/geometry against the current tree and applies minimal add/remove/move/resize ops, coexisting with manual splits") is realized as a **build-from-layout** (`fromTmuxLayout`) rather than an in-place minimal diff: tmux emits the full `window_layout` on every change, and reusing existing surfaces by `pane_id` in the factory (3c-2) preserves surface state across rebuilds — the same observable result (same surfaces, new topology, no lost scrollback) without a fiddly diff. The "coexisting with manual splits" / windows→tabs / focus / removal concerns are explicitly 3c-2 (enumerated in the roadmap). The Data-Flow "Layout" line (`%layout-change` → parse → reconcile) is split across 3c-1 (parse→tree) and 3c-2 (swap into the live tab). No silent gaps for the 3c-1 slice.

**2. Placeholder scan.** No `TBD`/`TODO`/"handle errors"/"similar to" in the executable steps. Every step has exact anchor text and full code. `error.UnsupportedLayout` is an explicit, named Task-1 scaffold removed in Task 2 Step 3 (not a placeholder — it has a real branch and a real failing test that drives its removal). The "Remaining" section is a roadmap (no checkboxes).

**3. Type consistency.** `fromTmuxLayout(gpa, root: *const tmux_layout.Node, ctx: *anyopaque, factory: *const fn(*anyopaque, usize) ?*Surface) !SplitTree` is used identically in all six tests (`fromTmuxLayout(alloc, &parsed.root, undefined, Stub.make)`), and every `Stub.make` matches the factory signature `fn(_: *anyopaque, pane_id: usize) ?*Surface`. `countLayoutNodes(*const Node)` and `tmuxSizeAlong(Node, Dir)` are defined in Task 1 and only consumed within `fromTmuxLayout`. `Node`/`Node.Handle`/`Node.Handle.Backing`/`Split.Layout`/`ArenaAllocator`/`Allocator`/`Surface` are all already in scope in `split_tree.zig`; `tmux_layout` is bound via `@import("tmux/layout.zig")` inside the function. The arena/`nodes`/`zoomed` construction and the sentinel-pointer + `tree.arena.deinit()` test-teardown match the existing `fromSnapshot` tests exactly. The pre-order index assignment (reserve `idx` before recursing) matches `fromSnapshot.writeNode`, so handles point parent→child correctly.
