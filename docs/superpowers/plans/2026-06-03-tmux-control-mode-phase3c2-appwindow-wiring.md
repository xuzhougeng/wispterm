# tmux Control Mode — Phase 3c-2 (AppWindow/tab wiring) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Phase 1–3c-1 tmux pieces into the running app — back `SplitTree.fromTmuxLayout`'s factory with live virtual-PTY `Surface`s, swap the reconciled tree into the live `TabState`, and map tmux window/pane events onto WispTerm tabs and split focus.

**Architecture:** The realized stack keeps `tmux/session.zig` (the model) and `tmux/pane.zig` (the fd bridge) **Surface-agnostic** so they stay unit-testable. Phase 3c-2 adds the **UI bridge**: a new `src/appwindow/tmux_bridge.zig` that owns a `Session` + `PaneMap`, implements a new `Session.EventSink` (the mirror of the existing `PaneSink`), supplies the per-pane `Surface` factory, and drives tab create/rename/close + split focus. `Session` stays pure (it only emits typed events to an optional sink); all `Surface`/`TabState` mutation lives in the bridge.

**Tech Stack:** Zig 0.15.2. New seam types are `std`-only (`EventSink` references `tmux/layout.Node`, already a pure import). The bridge is POSIX-only (it creates virtual PTYs via `Pty.openVirtual`) and is referenced only from posix-target builds.

**Reference:**
- Spec: `docs/superpowers/specs/2026-06-03-tmux-control-mode-integration-design.md`
- Resume guide: `docs/superpowers/tmux-resume.md` (the 5-step 3c-2 sketch)
- Prior phase plan: `docs/superpowers/plans/2026-06-03-tmux-control-mode-phase3c1-layout-to-splittree.md` (the "Remaining 3c-2" roadmap)

---

## Scope Check

Phase 3c-2 is the single cohesive "tmux model → WispTerm UI" bridge. It is one plan, but its tasks split by **test strategy**, which the codebase forces:

- **Tasks 1–3 (headless-TDD):** `Session.EventSink` (fast suite), `PaneMap` surface methods (posix suite), `TabState` tmux fields + `getTitle` (app suite). Pure logic, no real `Surface` — full TDD.
- **Tasks 4–5 (compile-checked + GUI-verified):** the `TmuxBridge` reconcile + event handlers. A real `Surface` **cannot be constructed in a headless test** (its `Renderer` needs the GPU backend — see resume guide finding 3), so the reconcile path is verified by the macOS app compile plus GUI runs in Phase 3d. The bridge's *non-Surface* helpers (`findTabIndexByWindowId`, `findLeaf`, `layoutHasPane`) are still unit-tested.

This plan does **not** add the ssh connection or the controller read-loop — that is **Phase 3d**. 3c-2's output is a `TmuxBridge` that 3d instantiates and feeds.

---

## Ownership & refcount contract (read before implementing)

This is the subtle part. `SplitTree` is **immutable, ref-counted, binary**. `SplitTree.fromTmuxLayout`'s factory transfers **exactly one ref per leaf** to the new tree (it does *not* `.ref()` itself; see `src/split_tree.zig:1080`). The reconcile must preserve this:

| Pane fate on a `%layout-change` | Factory does | Refs after `fromTmuxLayout` | After `old_tree.deinit()` |
|---|---|---|---|
| **Reused** (id in old tree *and* new layout) | `existing_surface.ref()` | old tree (1) + new tree (1) = 2 | new tree (1) — **survives**, scrollback intact |
| **New** (id only in new layout) | `Surface.initVirtual` → ref 1 | new tree (1) | new tree (1) |
| **Vanished** (id only in old tree) | not called | old tree (1) | 0 → **destroyed** |

Therefore the reconcile order is:

1. `fromTmuxLayout(... factory)` — reused panes get a 2nd ref; new panes are created + registered in `PaneMap`.
2. Snapshot the **old** window's pane ids (reverse-lookup each old-tree leaf `*Surface` in the `PaneMap`).
3. `old = t.tree; t.tree = new; old.deinit();` — releases the old tree's refs (reused → 1, vanished → 0/destroyed).
4. `PaneMap.removePane(id)` for every old id **not** in the new layout — closes its `controller_fd` (the surface is already destroyed by step 3; `removePane` never touches the surface pointer, only the fd + the entry).

`PaneMap.Pane.surface` is a **borrowed** pointer (the tree owns the ref). Storing it as `?*anyopaque` keeps `pane.zig` Surface-free so its posix unit tests still build. `removePane`/`deinit` must **never** unref it.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/tmux/session.zig` | MODIFY. Add `pub const EventSink` (mirror of `PaneSink`) + an `events: EventSink = .{}` field; emit typed events from `handle`/`applyLayout`. Stays `std`+`layout`-only and in the **fast** suite. Add emission tests. |
| `src/tmux/pane.zig` | MODIFY. Add `surface: ?*anyopaque = null` to `Pane` (borrowed); add `setSurface` + `findIdBySurface`. `addPane` signature unchanged (so `pane_io_test.zig`'s 7 call sites are untouched). Posix suite. |
| `src/appwindow/tab.zig` | MODIFY. Add `tmux_window_id: ?usize`, `tmux_name_buf`, `tmux_name_len` to `TabState`; have `getTitle` return the tmux window name when set. App suite. |
| `src/appwindow/tmux_bridge.zig` | CREATE. `TmuxBridge` struct owning `Session` + `PaneMap`; `EventSink` impl (`onLayoutChange` reconcile, `onWindowRenamed`, `onWindowClose`, `onActivePaneChanged`); the per-pane `Surface` factory; pure helpers. POSIX-only; compile-checked on macOS, GUI-verified in 3d. |
| `src/test_main.zig` | MODIFY. Register `appwindow/tmux_bridge.zig` under the existing `!= .windows` guard so the app test binary compiles + runs its (Surface-free) tests on a posix target. |

---

## Verification commands (what each suite covers here)

- `zig build test` — fast native suite. Covers Task 1 (`session.zig` lives in `test_fast.zig`).
- `zig build test-full` — adds the native posix test (`wispterm-posix-test`) + the app test binary built for the **default windows** target (compiled, run skipped as foreign). Covers Task 2 (`pane.zig` via `test_posix.zig`) and compile-checks Tasks 3–5 on windows (where the bridge is **excluded** by the `!= .windows` guard, so the windows build never needs `Pty.openVirtual`).
- `zig build test-full -Dtarget=aarch64-macos` — builds **and runs** the app test binary natively on macOS (Metal linked via the Apple SDK). This is the only path that **runs** Task 3's `tab.zig` test and **compiles + runs** Task 4–5's Surface-free bridge tests. Requires Xcode Command Line Tools.
- `zig build macos-app -Dtarget=aarch64-macos` — full macOS app compile (Intel: `x86_64-macos`). Final compile gate for the bridge.

---

## Task 1: `Session.EventSink` — emit model events

**Files:**
- Modify: `src/tmux/session.zig` (add `EventSink`, `events` field, emission, tests)

- [ ] **Step 1: Write the failing tests**

In `src/tmux/session.zig`, add a collector beside the existing `Collector` (after line ~226) and four tests at the end of the file (after the last test, ~line 371):

```zig
const EventLog = struct {
    alloc: Allocator,
    layout_window: ?usize = null,
    layout_panes: usize = 0,
    renamed_window: ?usize = null,
    renamed_name: std.ArrayListUnmanaged(u8) = .empty,
    closed_window: ?usize = null,
    active_pane: ?usize = null,

    fn eventSink(self: *EventLog) Session.EventSink {
        return .{
            .ctx = self,
            .onLayoutChange = onLayout,
            .onWindowRenamed = onRenamed,
            .onWindowClose = onClose,
            .onActivePaneChanged = onActive,
        };
    }

    fn onLayout(ctx: *anyopaque, window_id: usize, root: *const layout.Node) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.layout_window = window_id;
        var n: usize = 0;
        countLeaves(root, &n);
        self.layout_panes = n;
    }
    fn onRenamed(ctx: *anyopaque, window_id: usize, name: []const u8) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.renamed_window = window_id;
        self.renamed_name.clearRetainingCapacity();
        self.renamed_name.appendSlice(self.alloc, name) catch {};
    }
    fn onClose(ctx: *anyopaque, window_id: usize) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.closed_window = window_id;
    }
    fn onActive(ctx: *anyopaque, pane_id: usize) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.active_pane = pane_id;
    }
    fn countLeaves(node: *const layout.Node, out: *usize) void {
        switch (node.*) {
            .leaf => out.* += 1,
            .split => |s| for (s.children) |*c| countLeaves(c, out),
        }
    }
    fn deinit(self: *EventLog) void {
        self.renamed_name.deinit(self.alloc);
    }
};

test "EventSink fires onLayoutChange with the parsed root" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%layout-change @4 bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n");
    try std.testing.expectEqual(@as(?usize, 4), log.layout_window);
    try std.testing.expectEqual(@as(usize, 2), log.layout_panes);
}

test "EventSink fires onWindowRenamed with the name" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%window-renamed @7 build\n");
    try std.testing.expectEqual(@as(?usize, 7), log.renamed_window);
    try std.testing.expectEqualStrings("build", log.renamed_name.items);
}

test "EventSink fires onWindowClose before the window is dropped" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%window-add @3\n");
    try s.feed("%window-close @3\n");
    try std.testing.expectEqual(@as(?usize, 3), log.closed_window);
    try std.testing.expect(s.findWindow(3) == null);
}

test "EventSink fires onActivePaneChanged" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%window-pane-changed @1 %9\n");
    try std.testing.expectEqual(@as(?usize, 9), log.active_pane);
}

test "EventSink default is a silent no-op" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    // No events sink set; these must not crash.
    try s.feed("%window-renamed @1 x\n");
    try s.feed("%window-pane-changed @1 %2\n");
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — compile error, `Session.EventSink` is not declared.

- [ ] **Step 3: Add `EventSink` + the `events` field**

In `src/tmux/session.zig`, add immediately after the `PaneSink` struct (after its closing `};`, ~line 22):

```zig
/// High-level model events for the UI bridge (Phase 3c-2). The mirror of
/// `PaneSink`: the controller is Surface-agnostic, so it pushes typed events to
/// a sink the bridge backs with tab/Surface side effects. All callbacks are
/// best-effort (`void`) — the bridge handles its own allocation failures, like
/// `PaneSink.write`. `root`/`name` are only valid for the duration of the call.
/// The default sink ignores everything (headless/unit use).
pub const EventSink = struct {
    ctx: *anyopaque = undefined,
    onLayoutChange: *const fn (ctx: *anyopaque, window_id: usize, root: *const layout.Node) void = noLayout,
    onWindowRenamed: *const fn (ctx: *anyopaque, window_id: usize, name: []const u8) void = noRename,
    onWindowClose: *const fn (ctx: *anyopaque, window_id: usize) void = noClose,
    onActivePaneChanged: *const fn (ctx: *anyopaque, pane_id: usize) void = noActive,

    fn noLayout(_: *anyopaque, _: usize, _: *const layout.Node) void {}
    fn noRename(_: *anyopaque, _: usize, _: []const u8) void {}
    fn noClose(_: *anyopaque, _: usize) void {}
    fn noActive(_: *anyopaque, _: usize) void {}
};
```

Then add the field to the `Session` struct. Find (line ~34):

```zig
    active_pane: ?usize = null,
    exited: bool = false,
```

Replace with:

```zig
    active_pane: ?usize = null,
    exited: bool = false,
    events: EventSink = .{},
```

- [ ] **Step 4: Emit the events**

In `src/tmux/session.zig`, replace the `handle` body's relevant arms. Find (line ~90):

```zig
            .layout_change => |lc| try self.applyLayout(lc.window_id, lc.layout),
            .window_add => |w| _ = try self.ensureWindow(w.window_id),
            .window_renamed => |w| try self.renameWindow(w.window_id, w.name),
            .window_close => |w| self.removeWindow(w.window_id),
            .window_pane_changed => |w| self.active_pane = w.pane_id,
```

Replace with:

```zig
            .layout_change => |lc| try self.applyLayout(lc.window_id, lc.layout),
            .window_add => |w| _ = try self.ensureWindow(w.window_id),
            .window_renamed => |w| {
                try self.renameWindow(w.window_id, w.name);
                self.events.onWindowRenamed(self.events.ctx, w.window_id, w.name);
            },
            .window_close => |w| {
                self.events.onWindowClose(self.events.ctx, w.window_id);
                self.removeWindow(w.window_id);
            },
            .window_pane_changed => |w| {
                self.active_pane = w.pane_id;
                self.events.onActivePaneChanged(self.events.ctx, w.pane_id);
            },
```

Then in `applyLayout`, emit after the model is updated. Find (line ~130):

```zig
    fn applyLayout(self: *Session, window_id: usize, layout_str: []const u8) Allocator.Error!void {
        var tree = layout.parse(self.alloc, layout_str) catch return; // ignore malformed layouts
        defer tree.deinit();
        const w = try self.ensureWindow(window_id);
        w.panes.clearRetainingCapacity();
        try collectPanes(self.alloc, &w.panes, tree.root);
    }
```

Replace with:

```zig
    fn applyLayout(self: *Session, window_id: usize, layout_str: []const u8) Allocator.Error!void {
        var tree = layout.parse(self.alloc, layout_str) catch return; // ignore malformed layouts
        defer tree.deinit();
        const w = try self.ensureWindow(window_id);
        w.panes.clearRetainingCapacity();
        try collectPanes(self.alloc, &w.panes, tree.root);
        // `tree` is still alive (its `deinit` runs at scope exit); the bridge
        // consumes `root` synchronously inside this call.
        self.events.onLayoutChange(self.events.ctx, window_id, &tree.root);
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0. The five EventSink tests pass; the existing session tests are unaffected (default sink is the silent no-op).

- [ ] **Step 6: Commit**

```bash
git add src/tmux/session.zig
git commit -m "feat(tmux): Session.EventSink — emit layout/window/pane events to a sink"
```

---

## Task 2: `PaneMap` borrowed-surface field + lookups

**Files:**
- Modify: `src/tmux/pane.zig` (add `surface` field + `setSurface`/`findIdBySurface`; add tests)

- [ ] **Step 1: Write the failing tests**

In `src/tmux/pane.zig`, add at the end of the file (after the last existing item; the tests live in `pane_io_test.zig` but these are pure pointer-bookkeeping tests, so put them inline in `pane.zig` to run in both the fast-registered `session`-style sense and the posix binary — actually `pane.zig` itself has no `test` blocks today, so add a `// ----- tests -----` section):

```zig
// ----- tests -----

test "setSurface stores a borrowed pointer and findIdBySurface reverses it" {
    var sentinels: [4]u8 = undefined;
    const a: *anyopaque = @ptrCast(&sentinels[0]);
    const b: *anyopaque = @ptrCast(&sentinels[1]);

    var map = PaneMap.init(std.testing.allocator);
    defer map.deinit();

    // Fake fds: -1 is never read/closed in this test path. deinit/removePane
    // would close them, so use the real close-safe value by skipping removal.
    try map.panes.append(map.alloc, .{ .id = 1, .controller_fd = -1 });
    try map.panes.append(map.alloc, .{ .id = 2, .controller_fd = -1 });

    map.setSurface(1, a);
    map.setSurface(2, b);

    try std.testing.expectEqual(@as(?usize, 1), map.findIdBySurface(a));
    try std.testing.expectEqual(@as(?usize, 2), map.findIdBySurface(b));
    try std.testing.expectEqual(a, map.find(1).?.surface.?);

    const c: *anyopaque = @ptrCast(&sentinels[2]);
    try std.testing.expectEqual(@as(?usize, null), map.findIdBySurface(c));
}
```

Register `pane.zig`'s tests in the posix aggregator. In `src/test_posix.zig`, find:

```zig
test {
    _ = @import("platform/pty_virtual_test.zig");
    _ = @import("tmux/pane_io_test.zig");
}
```

Replace with:

```zig
test {
    _ = @import("platform/pty_virtual_test.zig");
    _ = @import("tmux/pane.zig");
    _ = @import("tmux/pane_io_test.zig");
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `wispterm-posix-test` reports a compile error: no field or member `setSurface`/`findIdBySurface`, and `Pane` has no field `surface`.

- [ ] **Step 3: Add the field + methods**

In `src/tmux/pane.zig`, change the `Pane` struct. Find (line ~26):

```zig
    pub const Pane = struct {
        id: usize,
        controller_fd: std.posix.fd_t,
    };
```

Replace with:

```zig
    pub const Pane = struct {
        id: usize,
        controller_fd: std.posix.fd_t,
        /// Borrowed pointer to this pane's `*Surface` (owned by the SplitTree
        /// that holds it; the bridge sets it via `setSurface`). Stored as an
        /// opaque pointer so `pane.zig` stays Surface-free and posix-testable.
        /// `removePane`/`deinit` never touch it — the tree owns the ref.
        surface: ?*anyopaque = null,
    };
```

Then add the two methods immediately after `find` (after line ~51, before `removePane`):

```zig
    /// Attach a borrowed `*Surface` (as an opaque pointer) to a registered
    /// pane. No-op if the pane is unknown. The bridge owns the lifecycle; this
    /// map never refs/unrefs/frees it.
    pub fn setSurface(self: *PaneMap, id: usize, surface: *anyopaque) void {
        if (self.find(id)) |p| p.surface = surface;
    }

    /// Reverse lookup: the pane id whose borrowed surface pointer matches.
    pub fn findIdBySurface(self: *PaneMap, surface: *anyopaque) ?usize {
        for (self.panes.items) |p| {
            if (p.surface) |s| if (s == surface) return p.id;
        }
        return null;
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test-full`
Expected: PASS, exit 0. `wispterm-posix-test` runs the new test; `pane_io_test.zig`'s 7 `addPane(id, fd)` call sites are unchanged (the new field defaults to `null`).

- [ ] **Step 5: Commit**

```bash
git add src/tmux/pane.zig src/test_posix.zig
git commit -m "feat(tmux): PaneMap borrowed-surface field + setSurface/findIdBySurface"
```

---

## Task 3: `TabState` tmux fields + `getTitle`

**Files:**
- Modify: `src/appwindow/tab.zig` (add 3 fields; `getTitle` honors the tmux window name; add a test)

- [ ] **Step 1: Write the failing test**

In `src/appwindow/tab.zig`, add at the very end of the file:

```zig
test "TabState.getTitle returns the tmux window name when set" {
    var t: TabState = .{ .tree = .empty };
    t.kind = .terminal;
    t.tmux_window_id = 2;
    const name = "build";
    @memcpy(t.tmux_name_buf[0..name.len], name);
    t.tmux_name_len = name.len;

    // Empty tree => no focused surface; the tmux-name branch must win first.
    try std.testing.expectEqualStrings("build", t.getTitle());

    // With no tmux name, an empty terminal tab falls back to the default.
    t.tmux_name_len = 0;
    try std.testing.expectEqualStrings("wispterm", t.getTitle());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-full -Dtarget=aarch64-macos`
Expected: FAIL — compile error: `TabState` has no field `tmux_window_id`/`tmux_name_buf`/`tmux_name_len`.
(On the default `zig build test-full`, the app binary is built for windows and the run is skipped, so use the macOS target to actually execute this test.)

- [ ] **Step 3: Add the fields**

In `src/appwindow/tab.zig`, change the `TabState` struct. Find (line ~50):

```zig
    /// Copilot conversation for a terminal tab (Issue #98). Distinct from
    /// `ai_chat_session`, which backs a dedicated AI-chat tab. Lazily created
    /// the first time the copilot sidebar is opened on this tab.
    copilot_session: ?*ai_chat.Session = null,

    pub const Kind = enum {
```

Replace with:

```zig
    /// Copilot conversation for a terminal tab (Issue #98). Distinct from
    /// `ai_chat_session`, which backs a dedicated AI-chat tab. Lazily created
    /// the first time the copilot sidebar is opened on this tab.
    copilot_session: ?*ai_chat.Session = null,

    /// tmux control-mode window id this tab mirrors (Phase 3c-2), or null for a
    /// normal local tab. Set by `tmux_bridge`. `tmux_name_buf`/`tmux_name_len`
    /// hold the tmux window name (`%window-renamed`), used by `getTitle`.
    tmux_window_id: ?usize = null,
    tmux_name_buf: [256]u8 = undefined,
    tmux_name_len: usize = 0,

    pub const Kind = enum {
```

- [ ] **Step 4: Teach `getTitle` the tmux name**

In `src/appwindow/tab.zig`, change `getTitle`. Find (line ~73):

```zig
    pub fn getTitle(self: *const TabState) []const u8 {
        if (g_forced_title) |forced| {
            return forced;
        }
        if (self.kind == .ai_chat) {
```

Replace with:

```zig
    pub fn getTitle(self: *const TabState) []const u8 {
        if (g_forced_title) |forced| {
            return forced;
        }
        // A tmux-backed terminal tab shows the tmux window name (if any) before
        // falling back to the focused surface's title.
        if (self.kind == .terminal and self.tmux_name_len > 0) {
            return self.tmux_name_buf[0..self.tmux_name_len];
        }
        if (self.kind == .ai_chat) {
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `zig build test-full -Dtarget=aarch64-macos`
Expected: PASS, exit 0. Also run `zig build test-full` and confirm it still compiles (the field additions are platform-neutral; the test compiles for windows and the run is skipped).

- [ ] **Step 6: Commit**

```bash
git add src/appwindow/tab.zig
git commit -m "feat(tmux): TabState tmux window id/name fields; getTitle shows the window name"
```

---

## Task 4: `TmuxBridge` — struct, factory, reconcile + helpers

**Files:**
- Create: `src/appwindow/tmux_bridge.zig`
- Modify: `src/test_main.zig` (register the new module under the `!= .windows` guard)

- [ ] **Step 1: Create the bridge with the reconcile path + Surface-free helper tests**

Create `src/appwindow/tmux_bridge.zig`:

```zig
//! UI bridge for tmux control mode (Phase 3c-2). Sits between the pure
//! `tmux.Session` model and WispTerm's tab/Surface UI. Owns the `Session` and
//! `PaneMap`, implements `Session.EventSink` to drive tabs/splits, and supplies
//! the per-pane `Surface` factory for `SplitTree.fromTmuxLayout`.
//!
//! POSIX-only: it materializes panes via `Pty.openVirtual` (socketpair). It is
//! referenced only from posix-target builds (registered in `test_main.zig`
//! under the `!= .windows` guard; wired into `AppWindow` by Phase 3d). A real
//! `Surface` cannot be built in a headless test (its `Renderer` needs the GPU
//! backend), so the reconcile path is compile-checked here and GUI-verified in
//! 3d; only the Surface-free helpers are unit-tested.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");
const Config = @import("../config.zig");
const Pty = @import("../platform/pty.zig").Pty;
const session_mod = @import("../tmux/session.zig");
const pane_mod = @import("../tmux/pane.zig");
const layout = @import("../tmux/layout.zig");
const tab = @import("tab.zig");
const active_tab_state = @import("active_tab.zig");

const Session = session_mod.Session;
const PaneMap = pane_mod.PaneMap;
const TabState = tab.TabState;

pub const TmuxBridge = struct {
    alloc: Allocator,
    session: Session,
    panes: PaneMap,
    // Config snapshot used when materializing a pane's Surface.
    scrollback_limit: u32,
    cursor_style: Config.CursorStyle,
    cursor_blink: bool,

    /// Heap-allocate + wire the bridge. The bridge is self-referential (its
    /// `PaneSink`/`EventSink` close over `&self.panes` / `self`), so it must be
    /// pinned — always use `create`/`destroy`, never move a `TmuxBridge`.
    pub fn create(
        alloc: Allocator,
        cols: u16,
        rows: u16,
        scrollback_limit: u32,
        cursor_style: Config.CursorStyle,
        cursor_blink: bool,
    ) Allocator.Error!*TmuxBridge {
        const self = try alloc.create(TmuxBridge);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.panes = PaneMap.init(alloc);
        self.scrollback_limit = scrollback_limit;
        self.cursor_style = cursor_style;
        self.cursor_blink = cursor_blink;
        self.session = Session.init(alloc, self.panes.sink(), cols, rows);
        self.session.events = self.eventSink();
        return self;
    }

    /// Tear down the controller side. Closes every pane's `controller_fd`
    /// (giving each Surface an EOF) and frees the Session. Does NOT destroy the
    /// tab Surfaces — those are owned by their tabs/`SplitTree`s and are torn
    /// down by the AppWindow's tab lifecycle.
    pub fn destroy(self: *TmuxBridge) void {
        self.session.deinit();
        self.panes.deinit();
        self.alloc.destroy(self);
    }

    fn eventSink(self: *TmuxBridge) Session.EventSink {
        return .{
            .ctx = self,
            .onLayoutChange = onLayoutChange,
            .onWindowRenamed = onWindowRenamed,
            .onWindowClose = onWindowClose,
            .onActivePaneChanged = onActivePaneChanged,
        };
    }

    // ----- EventSink: layout reconcile -----

    fn onLayoutChange(ctx: *anyopaque, window_id: usize, root: *const layout.Node) void {
        const self: *TmuxBridge = @ptrCast(@alignCast(ctx));
        self.reconcileWindow(window_id, root) catch |err| {
            std.debug.print("tmux: reconcile window @{d} failed: {}\n", .{ window_id, err });
        };
    }

    fn reconcileWindow(self: *TmuxBridge, window_id: usize, root: *const layout.Node) !void {
        const t = self.findOrCreateTab(window_id) orelse return error.NoTabSlot;

        // 1. Build the new tree. The factory reuses surfaces by pane id (ref'd
        //    for the new tree) or creates new virtual-PTY panes.
        var fctx = FactoryCtx{ .bridge = self, .root = root };
        const new_tree = try SplitTree.fromTmuxLayout(self.alloc, root, &fctx, FactoryCtx.make);

        // 2. Snapshot the old window's pane ids (reverse-lookup each old leaf).
        var old_ids: std.ArrayListUnmanaged(usize) = .empty;
        defer old_ids.deinit(self.alloc);
        {
            var it = t.tree.iterator();
            while (it.next()) |entry| {
                if (self.panes.findIdBySurface(entry.surface)) |id| {
                    try old_ids.append(self.alloc, id);
                }
            }
        }

        // 3. Swap. The old tree's deinit unrefs vanished surfaces to
        //    destruction; reused surfaces survive (the new tree holds a ref).
        var old_tree = t.tree;
        t.tree = new_tree;
        old_tree.deinit();

        // 4. Drop panes gone from the new layout (closes their controller_fd).
        for (old_ids.items) |id| {
            if (findLeaf(root, id) == null) self.panes.removePane(id);
        }

        // 5. Resolve focus to the active pane's leaf, if in this tab.
        self.refocusActivePane(t);
    }

    /// Per-pane Surface factory for `SplitTree.fromTmuxLayout`. Reuse → `ref()`;
    /// new → open a virtual PTY + `Surface.initVirtual` + register in PaneMap.
    /// Returns one ref transferred to the new tree, or null on failure (the
    /// reconcile aborts and keeps the old tree).
    const FactoryCtx = struct {
        bridge: *TmuxBridge,
        root: *const layout.Node,

        fn make(ctx: *anyopaque, pane_id: usize) ?*Surface {
            const fc: *FactoryCtx = @ptrCast(@alignCast(ctx));
            const self = fc.bridge;

            // Reuse: hand the new tree a fresh ref to the existing surface.
            if (self.panes.find(pane_id)) |p| {
                if (p.surface) |op| {
                    const s: *Surface = @ptrCast(@alignCast(op));
                    return s.ref();
                }
            }

            // New pane: cell size comes from the layout leaf.
            const leaf = findLeaf(fc.root, pane_id) orelse return null;
            const cols: u16 = @intCast(@max(@as(u32, 1), leaf.w));
            const rows: u16 = @intCast(@max(@as(u32, 1), leaf.h));

            const pair = Pty.openVirtual(.{ .ws_col = cols, .ws_row = rows }) catch return null;
            // On `initVirtual` failure, its errdefer deinits the adopted pty
            // (master + cancel pipe); we still own and must close controller_fd.
            const surface = Surface.initVirtual(
                self.alloc,
                cols,
                rows,
                pair.pty,
                self.scrollback_limit,
                self.cursor_style,
                self.cursor_blink,
            ) catch {
                std.posix.close(pair.controller_fd);
                return null;
            };
            surface.attachRemoteClient(tab.g_remote_client);

            self.panes.addPane(pane_id, pair.controller_fd) catch {
                surface.unref(self.alloc); // ref 1 -> 0: destroys it (deinits pty)
                std.posix.close(pair.controller_fd);
                return null;
            };
            self.panes.setSurface(pane_id, surface);
            return surface; // ref 1, transferred to the tree
        }
    };

    fn refocusActivePane(self: *TmuxBridge, t: *TabState) void {
        const active = self.session.active_pane orelse return;
        const p = self.panes.find(active) orelse return;
        const op = p.surface orelse return;
        const target: *Surface = @ptrCast(@alignCast(op));
        var it = t.tree.iterator();
        while (it.next()) |entry| {
            if (entry.surface == target) {
                t.focused = entry.handle;
                return;
            }
        }
    }

    // ----- EventSink: window events -----

    fn onWindowRenamed(_: *anyopaque, window_id: usize, name: []const u8) void {
        const idx = findTabIndexByWindowId(window_id) orelse return;
        const t = tab.g_tabs[idx] orelse return;
        const n = @min(name.len, t.tmux_name_buf.len);
        @memcpy(t.tmux_name_buf[0..n], name[0..n]);
        t.tmux_name_len = n;
    }

    fn onWindowClose(ctx: *anyopaque, window_id: usize) void {
        const self: *TmuxBridge = @ptrCast(@alignCast(ctx));
        const idx = findTabIndexByWindowId(window_id) orelse return;
        const t = tab.g_tabs[idx] orelse return;
        // Drop this window's panes from the PaneMap (closes their fds) before
        // closeTab destroys the surfaces. removePane never touches the surface.
        var it = t.tree.iterator();
        while (it.next()) |entry| {
            if (self.panes.findIdBySurface(entry.surface)) |id| self.panes.removePane(id);
        }
        // closeTab no-ops when this is the last tab; whole-connection teardown
        // for that case is a Phase 3d concern.
        tab.closeTab(idx, self.alloc);
    }

    fn onActivePaneChanged(ctx: *anyopaque, pane_id: usize) void {
        const self: *TmuxBridge = @ptrCast(@alignCast(ctx));
        const p = self.panes.find(pane_id) orelse return;
        const op = p.surface orelse return;
        const target: *Surface = @ptrCast(@alignCast(op));
        // Focus the owning tab's leaf; do NOT switch the active tab (tmux pane
        // focus is not the user's tab choice).
        var ti: usize = 0;
        while (ti < tab.g_tab_count) : (ti += 1) {
            const t = tab.g_tabs[ti] orelse continue;
            if (t.kind != .terminal) continue;
            var it = t.tree.iterator();
            while (it.next()) |entry| {
                if (entry.surface == target) {
                    t.focused = entry.handle;
                    return;
                }
            }
        }
    }

    // ----- tab lookup / creation -----

    fn findOrCreateTab(self: *TmuxBridge, window_id: usize) ?*TabState {
        if (findTabIndexByWindowId(window_id)) |idx| return tab.g_tabs[idx];
        if (tab.g_tab_count >= tab.MAX_TABS) return null;
        const t = self.alloc.create(TabState) catch return null;
        t.kind = .terminal;
        t.tree = .empty;
        t.focused = .root;
        t.ai_chat_session = null;
        t.ai_history_session = null;
        t.copilot_session = null;
        t.tmux_window_id = window_id;
        t.tmux_name_len = 0;
        tab.g_tabs[tab.g_tab_count] = t;
        active_tab_state.g_active_tab = tab.g_tab_count;
        tab.g_tab_count += 1;
        return t;
    }
};

/// Index of the tab mirroring this tmux window id, or null. Pure helper over the
/// thread-local tab model — unit-tested without any Surface.
fn findTabIndexByWindowId(window_id: usize) ?usize {
    var i: usize = 0;
    while (i < tab.g_tab_count) : (i += 1) {
        if (tab.g_tabs[i]) |t| {
            if (t.tmux_window_id == window_id) return i;
        }
    }
    return null;
}

/// The leaf for `pane_id` anywhere in a parsed layout tree, or null. Pure.
fn findLeaf(node: *const layout.Node, pane_id: usize) ?layout.Node.Leaf {
    switch (node.*) {
        .leaf => |l| return if (l.pane_id == pane_id) l else null,
        .split => |s| {
            for (s.children) |*child| {
                if (findLeaf(child, pane_id)) |found| return found;
            }
            return null;
        },
    }
}

// ----- tests (Surface-free only) -----

test "findLeaf locates a pane and reads its cell size" {
    var parsed = try layout.parse(std.testing.allocator, "80x24,0,0{40x24,0,0,1,39x24,41,0,2}");
    defer parsed.deinit();

    const l2 = findLeaf(&parsed.root, 2) orelse return error.NotFound;
    try std.testing.expectEqual(@as(u32, 39), l2.w);
    try std.testing.expectEqual(@as(u32, 24), l2.h);
    try std.testing.expect(findLeaf(&parsed.root, 99) == null);
}

test "findTabIndexByWindowId matches on tmux_window_id" {
    // Save/restore the thread-local tab model so the test is self-contained.
    const saved_tabs = tab.g_tabs;
    const saved_count = tab.g_tab_count;
    defer {
        tab.g_tabs = saved_tabs;
        tab.g_tab_count = saved_count;
    }

    var t0: TabState = .{ .tree = .empty };
    t0.kind = .terminal;
    t0.tmux_window_id = 5;
    var t1: TabState = .{ .tree = .empty };
    t1.kind = .terminal;
    t1.tmux_window_id = 9;

    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tabs[0] = &t0;
    tab.g_tabs[1] = &t1;
    tab.g_tab_count = 2;

    try std.testing.expectEqual(@as(?usize, 1), findTabIndexByWindowId(9));
    try std.testing.expectEqual(@as(?usize, 0), findTabIndexByWindowId(5));
    try std.testing.expectEqual(@as(?usize, null), findTabIndexByWindowId(7));
}
```

- [ ] **Step 2: Register the module for compilation**

In `src/test_main.zig`, find (line ~678):

```zig
    if (@import("builtin").os.tag != .windows) {
        _ = @import("platform/pty_virtual_test.zig");
        _ = @import("tmux/pane_io_test.zig");
    }
```

Replace with:

```zig
    if (@import("builtin").os.tag != .windows) {
        _ = @import("platform/pty_virtual_test.zig");
        _ = @import("tmux/pane_io_test.zig");
        _ = @import("appwindow/tmux_bridge.zig");
    }
```

- [ ] **Step 3: Compile-check on windows (bridge excluded) and macOS (bridge compiled + helpers run)**

Run: `zig build test-full`
Expected: PASS — the windows-target app binary compiles with the bridge excluded by the guard (so it never needs `Pty.openVirtual` on windows); the native posix + fast suites pass.

Run: `zig build test-full -Dtarget=aarch64-macos`
Expected: PASS — the bridge compiles against the real `Surface`/`SplitTree`/`tab` types and the two Surface-free helper tests run (`findLeaf`, `findTabIndexByWindowId`). (Requires Xcode Command Line Tools.)

- [ ] **Step 4: Full macOS app compile gate**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: build succeeds (the app `.app` is produced). This confirms the bridge and all modified files compile in the real app graph. The bridge has no runtime caller yet (Phase 3d), so app behavior is unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/tmux_bridge.zig src/test_main.zig
git commit -m "feat(tmux): TmuxBridge — reconcile %layout-change into tabs/splits, map window events"
```

---

## Task 5: Self-review pass + GUI-verify deferral note

**Files:**
- Modify: `docs/superpowers/tmux-resume.md` (status table + NEXT pointer)

- [ ] **Step 1: Re-read the ownership contract against the code**

Confirm by inspection (no code change) that `reconcileWindow` matches the refcount table:
- reused pane: factory `s.ref()` (new tree +1); `old_tree.deinit()` (-1) ⇒ survives.
- new pane: factory ref 1 ⇒ new tree owns it.
- vanished pane: not in `findLeaf(root, id)` ⇒ `old_tree.deinit()` destroys it, then `removePane` closes its fd.

Confirm `PaneMap.removePane`/`deinit` never read `Pane.surface` (they only `close(controller_fd)` + drop the entry).

- [ ] **Step 2: Update the resume guide**

In `docs/superpowers/tmux-resume.md`, add a `P3c-2` row to the status table (after the `P3c-1` row) and repoint the NEXT section at Phase 3d. Find the table row:

```
| P3c-1 | `SplitTree.fromTmuxLayout` — tmux layout → binary split tree (N-ary fold + ratios) | `ff41e9b` `3a29677` |
```

Add immediately below:

```
| P3c-2 | `Session.EventSink`; `PaneMap` borrowed-surface + reverse lookup; `TabState` tmux fields; `src/appwindow/tmux_bridge.zig` (reconcile + window/pane→tab mapping) | _this branch_ |
```

Then change the `## NEXT: Phase 3c-2 ...` heading to `## NEXT: Phase 3d (connection + controller read-loop)` and replace its body with a short pointer: launch `ssh -tt host -- tmux -CC new -A -s <name>`, instantiate `TmuxBridge.create(...)`, run the read-loop (poll the ssh fd + every `controller_fd`; route ssh→`bridge.session.feed`, drain `bridge.session.pendingCommands()`→ssh pipe, call `bridge.panes.pumpKeystrokes(&bridge.session)`), and wire `list-windows` / `capture-pane -p -e -J` / `refresh-client -C`. Note the AppWindow seam must reach the posix-only bridge through a platform-dispatched indirection (no `os.tag` in `AppWindow.zig`; see its line-297 self-check) — e.g. a `platform/`-style module that is the bridge on posix and a no-op stub on windows.

- [ ] **Step 3: Run both suites once more**

Run: `zig build test` then `zig build test-full`
Expected: both PASS. (Docs-only change in this task; this is the regression gate.)

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/tmux-resume.md
git commit -m "docs(tmux): record Phase 3c-2; point NEXT at Phase 3d"
```

---

## Phase 3c-2 Done — What Ships

A `TmuxBridge` that turns the pure `tmux.Session` model into live WispTerm UI:
- `Session.EventSink` emits `layout-change`/`window-renamed`/`window-close`/`active-pane` events (default no-op; fast-suite tested).
- `PaneMap` carries a **borrowed** `?*anyopaque` surface per pane with set/reverse-lookup (posix-suite tested).
- `TabState` gains a tmux window id + window-name title (app-suite tested).
- `tmux_bridge.zig` reconciles each `%layout-change` into a rebuilt `SplitTree` (reusing surfaces by pane id, creating virtual-PTY panes for new ones, dropping vanished panes), maps window events to tab create/rename/close, and resolves split focus from the active pane — compile-checked on macOS, GUI-verified with 3d.

**Still dead code** until Phase 3d gives it an ssh connection + read-loop and an AppWindow seam.

## Self-Review

**1. Spec coverage (3c-2 slice).** The spec's `appwindow/tab.zig` row ("Bridge controller window/pane events to tab create/rename/close and active-pane focus") is realized by `TmuxBridge`'s `EventSink` handlers (Task 4). The `split_tree.zig` "reconcile" row is realized as build-from-layout + reuse-by-pane-id (3c-1's `fromTmuxLayout` + Task 4's `reconcileWindow`), the same observable result (same surfaces, new topology, scrollback intact) without an in-place diff. The Data-Flow "Layout" line (`%layout-change` → parse → reconcile → swap) is now complete across 3c-1 (parse→tree) and 3c-2 (swap into the live tab). Connection/bootstrap/resize remain Phase 3d (spec items 5–8), explicitly out of scope here. The close-confirm-before-`kill-window` gating (spec UX) is a 3d concern (it needs the connection-level close path) — noted, not silently dropped.

**2. Placeholder scan.** No `TBD`/`TODO`/"handle errors"/"similar to" in executable steps. Every code step carries full code with exact anchor text. The one deliberate runtime-error log (`reconcile ... failed`) is real fail-open behavior (keep the old tree), not a placeholder. The last-tab `closeTab` no-op and the AppWindow platform seam are named limitations with an explicit 3d owner, not gaps.

**3. Type consistency.** `Session.EventSink{ ctx, onLayoutChange(*anyopaque,usize,*const layout.Node), onWindowRenamed(*anyopaque,usize,[]const u8), onWindowClose(*anyopaque,usize), onActivePaneChanged(*anyopaque,usize) }` is defined in Task 1 and consumed identically by `EventLog` (Task 1 test) and `TmuxBridge.eventSink` (Task 4). `PaneMap.setSurface(usize,*anyopaque)`/`findIdBySurface(*anyopaque) ?usize` and `Pane.surface: ?*anyopaque` (Task 2) are used identically in `make`/`reconcileWindow`/`onWindowClose`/`refocusActivePane`. `TabState.tmux_window_id/tmux_name_buf/tmux_name_len` (Task 3) match `findOrCreateTab`/`onWindowRenamed`/`getTitle`. `SplitTree.fromTmuxLayout(gpa, *const layout.Node, *anyopaque, *const fn(*anyopaque,usize) ?*Surface)` (3c-1, already shipped) matches `FactoryCtx.make`'s signature and the call in `reconcileWindow`. `Pty.openVirtual(winsize) !VirtualPair{ pty, controller_fd }` and `Surface.initVirtual(alloc,cols,rows,Pty,scrollback,CursorStyle,bool)` match their definitions in `pty_posix.zig`/`Surface.zig`. `SplitTree.Iterator.next` yields `SurfaceEntry{ handle, surface }`, used by all four tree walks. `tab.g_tabs`/`g_tab_count`/`MAX_TABS`/`closeTab`/`g_remote_client` and `active_tab_state.g_active_tab` are existing public symbols.

## Remaining (Phase 3d — separate plan)

Connection + bootstrap + pump loop: launch `ssh … tmux -CC`, `TmuxBridge.create`, the poll/read-loop (ssh fd + all `controller_fd`s; ssh→`session.feed`, `session.pendingCommands()`→ssh, `panes.pumpKeystrokes`), `list-windows`/`capture-pane`/`refresh-client -C`, the AppWindow posix-dispatched seam, detach/reconnect overlay, close-confirm-before-`kill-window`, and `session_persist` re-attach. Plus the native-split/new-tab/resize actions that emit `split-window`/`new-window`/`refresh-client` (the inbound direction; 3c-2 handles the echoed `%layout-change`).
