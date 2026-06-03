# tmux Control Mode — Phase 2 (Headless Controller) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `src/tmux/session.zig` — the headless tmux control-mode controller that consumes the Phase 1 parsers, demultiplexes `%output` to panes through a sink seam, maintains a window/pane model from pushed notifications, and emits the outbound tmux commands (`refresh-client`, `list-windows`, `send-keys -H`, `split-window`, `new-window`, `kill-window`) — all unit-tested with a scripted byte stream, no GUI and no real PTYs.

**Architecture:** `Session` owns a `control.Parser`, a queued command buffer, and a list of `Window`s (each with a pane-id list derived from `layout.parse`). `feed(bytes)` drives the parser and updates the model; pane output is delivered through a `PaneSink` (a `ctx`+`writeFn` pair) so the controller never touches a `Surface` or an fd. Tests supply a collector sink and assert model state + queued commands. Phase 3 will back the sink with a virtual PTY + `Surface` and drive input into `sendKeys`.

**Tech Stack:** Zig 0.15.2, `std`-only plus the Phase 1 `src/tmux/control.zig` and `src/tmux/layout.zig` modules. In-file `test { ... }` blocks registered in `src/test_fast.zig`, run by `zig build test`.

**Reference:** Design spec `docs/superpowers/specs/2026-06-03-tmux-control-mode-integration-design.md`. Phase 1 plan `docs/superpowers/plans/2026-06-03-tmux-control-mode-phase1.md` (already implemented: commits `af5a956`, `3efb3a3`, `2492458`).

**Re-slice note (deviation from the spec's suggested order):** The spec listed "virtual PTY" as Phase 2 step 1. It is platform/fd code whose only consumer is the Surface wiring, and per the `phantty-test-inclusion-wiring` rule its tests need explicit platform wiring. Moving it into Phase 3 (next to the Surface/tab integration that uses it) keeps Phase 2 pure, fast-suite, and consumer-driven. No spec requirement is dropped — only resequenced.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/tmux/session.zig` | NEW. `Session` controller + `PaneSink` seam. Consumes `control`/`layout`; owns the command queue and window/pane model. The only Phase-2 file. Imports `std`, `control.zig`, `layout.zig`. |
| `src/test_fast.zig` | MODIFY. Register `_ = @import("tmux/session.zig");`. |

Boundary: `session.zig` may import both `control` and `layout` (it is the controller); they still must not import each other or `session`. `session.zig` has **no** dependency on `Surface`, `Pty`, tabs, or any fd — pane delivery and key input cross the `PaneSink` / `sendKeys` seam only.

---

## Task 1: Session scaffold + PaneSink seam

**Files:**
- Create: `src/tmux/session.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Create `src/tmux/session.zig`**

```zig
//! Headless tmux control-mode controller. Consumes the Phase 1 parsers
//! (`control`, `layout`), maintains a window/pane model from pushed
//! notifications, queues outbound tmux commands, and delivers pane output
//! through a `PaneSink`. No Surface / PTY / fd dependency — Phase 3 wires those
//! across the sink and `sendKeys` seams.

const std = @import("std");
const Allocator = std.mem.Allocator;
const control = @import("control.zig");
const layout = @import("layout.zig");

/// Receives unescaped pane output bytes. Phase 3 backs this with a virtual PTY
/// feeding a Surface; tests back it with a per-pane collector. `bytes` is only
/// valid for the duration of the call.
pub const PaneSink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, pane_id: usize, bytes: []const u8) void,

    pub fn write(self: PaneSink, pane_id: usize, bytes: []const u8) void {
        self.writeFn(self.ctx, pane_id, bytes);
    }
};

pub const Session = struct {
    alloc: Allocator,
    parser: control.Parser,
    sink: PaneSink,
    cols: u16,
    rows: u16,
    cmds: std.ArrayListUnmanaged(u8) = .empty,
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    windows: std.ArrayListUnmanaged(Window) = .empty,
    active_pane: ?usize = null,
    exited: bool = false,

    pub const Window = struct {
        id: usize,
        name: std.ArrayListUnmanaged(u8) = .empty,
        panes: std.ArrayListUnmanaged(usize) = .empty,

        fn deinit(self: *Window, alloc: Allocator) void {
            self.name.deinit(alloc);
            self.panes.deinit(alloc);
        }
    };

    pub fn init(alloc: Allocator, sink: PaneSink, cols: u16, rows: u16) Session {
        return .{
            .alloc = alloc,
            .parser = control.Parser.init(alloc),
            .sink = sink,
            .cols = cols,
            .rows = rows,
        };
    }

    pub fn deinit(self: *Session) void {
        self.parser.deinit();
        self.cmds.deinit(self.alloc);
        self.scratch.deinit(self.alloc);
        for (self.windows.items) |*w| w.deinit(self.alloc);
        self.windows.deinit(self.alloc);
    }

    pub fn windowCount(self: *const Session) usize {
        return self.windows.items.len;
    }

    pub fn pendingCommands(self: *const Session) []const u8 {
        return self.cmds.items;
    }

    pub fn clearCommands(self: *Session) void {
        self.cmds.clearRetainingCapacity();
    }
};

// ----- test helpers -----

const Collector = struct {
    alloc: Allocator,
    last_pane: usize = 0,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn sink(self: *Collector) PaneSink {
        return .{ .ctx = self, .writeFn = writeImpl };
    }

    fn writeImpl(ctx: *anyopaque, pane_id: usize, bytes: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.last_pane = pane_id;
        self.buf.appendSlice(self.alloc, bytes) catch {};
    }

    fn deinit(self: *Collector) void {
        self.buf.deinit(self.alloc);
    }
};

test "session initializes empty" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.windowCount());
    try std.testing.expectEqual(@as(usize, 0), s.pendingCommands().len);
}
```

Then register it in `src/test_fast.zig` — add inside the `test { ... }` block, after the existing tmux imports:

```zig
    _ = @import("tmux/session.zig");
```

- [ ] **Step 2: Run the suite**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 3: Commit**

```bash
git add src/tmux/session.zig src/test_fast.zig
git commit -m "feat(tmux): headless controller scaffold + PaneSink seam"
```

---

## Task 2: feed + `%output` demux to the sink

**Files:**
- Modify: `src/tmux/session.zig`

- [ ] **Step 1: Add the failing test**

```zig
test "feed routes unescaped %output to the sink for the right pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    // \033 octal-escapes to ESC (0x1b).
    try s.feed("%output %7 ab\\033c\n");
    try std.testing.expectEqual(@as(usize, 7), col.last_pane);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 0x1b, 'c' }, col.buf.items);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL — `feed` is not defined (compile error: no member named `feed`).

- [ ] **Step 3: Implement `feed` + `handle` + the `%output` branch**

Add these methods inside `pub const Session = struct { ... }` (after `clearCommands`):

```zig
    pub fn feed(self: *Session, bytes: []const u8) Allocator.Error!void {
        for (bytes) |b| {
            if (try self.parser.put(b)) |n| try self.handle(n);
        }
    }

    fn handle(self: *Session, n: control.Notification) Allocator.Error!void {
        switch (n) {
            .output => |o| {
                self.scratch.clearRetainingCapacity();
                try control.unescape(self.alloc, &self.scratch, o.data);
                self.sink.write(o.pane_id, self.scratch.items);
            },
            else => {},
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/session.zig
git commit -m "feat(tmux): demux %output to the pane sink (unescaped)"
```

---

## Task 3: window model from window notifications

**Files:**
- Modify: `src/tmux/session.zig`

- [ ] **Step 1: Add the failing tests**

```zig
test "window-add/renamed/close maintain the window list" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.feed("%window-add @3\n");
    try s.feed("%window-add @5\n");
    try std.testing.expectEqual(@as(usize, 2), s.windowCount());

    try s.feed("%window-renamed @3 build\n");
    try std.testing.expectEqualStrings("build", s.findWindow(3).?.name.items);

    try s.feed("%window-close @3\n");
    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    try std.testing.expect(s.findWindow(3) == null);
}

test "window-pane-changed sets the active pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.feed("%window-pane-changed @1 %9\n");
    try std.testing.expectEqual(@as(?usize, 9), s.active_pane);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test`
Expected: FAIL — `findWindow` is not defined and the window notifications are ignored.

- [ ] **Step 3: Implement window handling + accessors**

Add the new branches to `handle`'s `switch` (replace the existing `else => {}` line with these cases plus a final `else`):

```zig
            .window_add => |w| _ = try self.ensureWindow(w.window_id),
            .window_renamed => |w| try self.renameWindow(w.window_id, w.name),
            .window_close => |w| self.removeWindow(w.window_id),
            .window_pane_changed => |w| self.active_pane = w.pane_id,
            .exit => self.exited = true,
            else => {},
```

Add these methods inside `Session`:

```zig
    pub fn findWindow(self: *Session, id: usize) ?*Window {
        for (self.windows.items) |*w| {
            if (w.id == id) return w;
        }
        return null;
    }

    fn ensureWindow(self: *Session, id: usize) Allocator.Error!*Window {
        if (self.findWindow(id)) |w| return w;
        try self.windows.append(self.alloc, .{ .id = id });
        return &self.windows.items[self.windows.items.len - 1];
    }

    fn renameWindow(self: *Session, id: usize, name: []const u8) Allocator.Error!void {
        const w = try self.ensureWindow(id);
        w.name.clearRetainingCapacity();
        try w.name.appendSlice(self.alloc, name);
    }

    fn removeWindow(self: *Session, id: usize) void {
        var i: usize = 0;
        while (i < self.windows.items.len) : (i += 1) {
            if (self.windows.items[i].id == id) {
                self.windows.items[i].deinit(self.alloc);
                _ = self.windows.orderedRemove(i);
                return;
            }
        }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/session.zig
git commit -m "feat(tmux): maintain window model from window notifications"
```

---

## Task 4: `%layout-change` → pane list

**Files:**
- Modify: `src/tmux/session.zig`

- [ ] **Step 1: Add the failing test**

```zig
test "layout-change populates a window's pane list in layout order" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.feed("%layout-change @1 bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n");
    const panes = s.findWindow(1).?.panes.items;
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, panes);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL — `%layout-change` is currently ignored; the window has no panes (slice mismatch).

- [ ] **Step 3: Implement layout handling**

Add the `layout_change` case to `handle`'s `switch` (before the final `else`):

```zig
            .layout_change => |lc| try self.applyLayout(lc.window_id, lc.layout),
```

Add these methods inside `Session`:

```zig
    fn applyLayout(self: *Session, window_id: usize, layout_str: []const u8) Allocator.Error!void {
        var tree = layout.parse(self.alloc, layout_str) catch return; // ignore malformed layouts
        defer tree.deinit();
        const w = try self.ensureWindow(window_id);
        w.panes.clearRetainingCapacity();
        try collectPanes(self.alloc, &w.panes, tree.root);
    }
```

And add this free function at file scope (after the `Session` struct, before the test helpers):

```zig
fn collectPanes(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(usize),
    node: layout.Node,
) Allocator.Error!void {
    switch (node) {
        .leaf => |l| try out.append(alloc, l.pane_id),
        .split => |s| {
            for (s.children) |child| try collectPanes(alloc, out, child);
        },
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/session.zig
git commit -m "feat(tmux): derive window pane list from layout-change"
```

---

## Task 5: bootstrap (`start`) + `resizeClient`

**Files:**
- Modify: `src/tmux/session.zig`

- [ ] **Step 1: Add the failing tests**

```zig
test "start enqueues the attach bootstrap commands" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 120, 40);
    defer s.deinit();

    try s.start();
    const cmds = s.pendingCommands();
    try std.testing.expect(std.mem.indexOf(u8, cmds, "refresh-client -C 120x40\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmds, "list-windows") != null);
}

test "resizeClient updates size and queues a refresh" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.resizeClient(100, 30);
    try std.testing.expectEqual(@as(u16, 100), s.cols);
    try std.testing.expect(std.mem.indexOf(u8, s.pendingCommands(), "refresh-client -C 100x30\n") != null);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test`
Expected: FAIL — `start` and `resizeClient` are not defined.

- [ ] **Step 3: Implement bootstrap and resize**

Add these methods inside `Session`:

```zig
    /// Enqueue the attach bootstrap: tell tmux our client size and ask for the
    /// window list. (Parsing the list-windows reply for complete initial
    /// enumeration is Phase 3; the live model is built from pushed
    /// notifications.)
    pub fn start(self: *Session) Allocator.Error!void {
        try self.enqueueResize();
        try self.cmds.appendSlice(self.alloc, "list-windows -F \"#{window_id} #{window_layout}\"\n");
    }

    pub fn resizeClient(self: *Session, cols: u16, rows: u16) Allocator.Error!void {
        self.cols = cols;
        self.rows = rows;
        try self.enqueueResize();
    }

    fn enqueueResize(self: *Session) Allocator.Error!void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "refresh-client -C {d}x{d}\n", .{ self.cols, self.rows }) catch unreachable;
        try self.cmds.appendSlice(self.alloc, s);
    }
```

(The `bufPrint` cannot overflow: the format is at most `refresh-client -C 65535x65535\n` = 31 bytes, well under 64, so `catch unreachable` is sound.)

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/session.zig
git commit -m "feat(tmux): bootstrap (refresh-client + list-windows) and resize"
```

---

## Task 6: `sendKeys` (hex-encoded)

**Files:**
- Modify: `src/tmux/session.zig`

- [ ] **Step 1: Add the failing test**

```zig
test "sendKeys hex-encodes raw bytes for a pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.sendKeys(4, "ls\n"); // l=0x6c s=0x73 \n=0x0a
    try std.testing.expectEqualStrings("send-keys -t %4 -H 6c 73 0a\n", s.pendingCommands());
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL — `sendKeys` is not defined.

- [ ] **Step 3: Implement `sendKeys`**

Add inside `Session`:

```zig
    /// Queue raw key bytes for a pane as a hex `send-keys` command.
    pub fn sendKeys(self: *Session, pane_id: usize, raw: []const u8) Allocator.Error!void {
        var head: [48]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "send-keys -t %{d} -H", .{pane_id}) catch unreachable;
        try self.cmds.appendSlice(self.alloc, h);
        for (raw) |byte| {
            var hb: [8]u8 = undefined;
            const hs = std.fmt.bufPrint(&hb, " {x:0>2}", .{byte}) catch unreachable;
            try self.cmds.appendSlice(self.alloc, hs);
        }
        try self.cmds.append(self.alloc, '\n');
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/session.zig
git commit -m "feat(tmux): sendKeys hex-encodes pane input for tmux"
```

---

## Task 7: `splitPane` / `newWindow` / `killWindow`

**Files:**
- Modify: `src/tmux/session.zig`

- [ ] **Step 1: Add the failing tests**

```zig
test "splitPane emits split-window with the right orientation flag" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.splitPane(2, .horizontal);
    try std.testing.expectEqualStrings("split-window -h -t %2\n", s.pendingCommands());
    s.clearCommands();
    try s.splitPane(2, .vertical);
    try std.testing.expectEqualStrings("split-window -v -t %2\n", s.pendingCommands());
}

test "newWindow and killWindow emit their commands" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.newWindow();
    try std.testing.expectEqualStrings("new-window\n", s.pendingCommands());
    s.clearCommands();
    try s.killWindow(6);
    try std.testing.expectEqualStrings("kill-window -t @6\n", s.pendingCommands());
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test`
Expected: FAIL — `splitPane`/`newWindow`/`killWindow` are not defined.

- [ ] **Step 3: Implement the command emitters**

Add inside `Session`:

```zig
    pub fn splitPane(self: *Session, pane_id: usize, dir: layout.Dir) Allocator.Error!void {
        const flag = switch (dir) {
            .horizontal => "-h",
            .vertical => "-v",
        };
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "split-window {s} -t %{d}\n", .{ flag, pane_id }) catch unreachable;
        try self.cmds.appendSlice(self.alloc, s);
    }

    pub fn newWindow(self: *Session) Allocator.Error!void {
        try self.cmds.appendSlice(self.alloc, "new-window\n");
    }

    pub fn killWindow(self: *Session, id: usize) Allocator.Error!void {
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "kill-window -t @{d}\n", .{id}) catch unreachable;
        try self.cmds.appendSlice(self.alloc, s);
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/session.zig
git commit -m "feat(tmux): emit split-window/new-window/kill-window commands"
```

---

## Task 8: end-to-end stream test + `%exit`

**Files:**
- Modify: `src/tmux/session.zig`

- [ ] **Step 1: Add the failing test**

```zig
test "a realistic notification stream builds the full model" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    // Attach: one window, a single pane, then it splits into two, output flows,
    // focus moves, and finally tmux exits.
    try s.feed("%window-add @0\n");
    try s.feed("%window-renamed @0 main\n");
    try s.feed("%layout-change @0 bd1b,80x24,0,0,1 bd1b,80x24,0,0,1 *\n");
    try s.feed("%layout-change @0 e2f1,80x24,0,0{40x24,0,0,1,39x24,41,0,2} e2f1,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n");
    try s.feed("%window-pane-changed @0 %2\n");
    try s.feed("%output %2 done\n");
    try s.feed("%exit\n");

    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    const w = s.findWindow(0).?;
    try std.testing.expectEqualStrings("main", w.name.items);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, w.panes.items);
    try std.testing.expectEqual(@as(?usize, 2), s.active_pane);
    try std.testing.expectEqual(@as(usize, 2), col.last_pane);
    try std.testing.expectEqualSlices(u8, "done", col.buf.items);
    try std.testing.expect(s.exited);
}
```

- [ ] **Step 2: Run to verify it passes**

Run: `zig build test`
Expected: PASS, exit 0. (All the behavior this exercises was implemented in Tasks 2–7; `%exit` handling was added in Task 3's `switch`. This task is the integration assertion that they compose.)

- [ ] **Step 3: Run the full suite as a regression gate**

Run: `zig build test-full`
Expected: PASS, exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/tmux/session.zig
git commit -m "test(tmux): end-to-end controller stream builds the full model"
```

---

## Phase 2 Done — What Ships

`src/tmux/session.zig`: a fully-tested headless controller that turns a tmux control-mode byte stream into a window/pane model + a sink-delivered output stream, and turns app intents (`start`, `resizeClient`, `sendKeys`, `splitPane`, `newWindow`, `killWindow`) into queued tmux commands. No GUI, no PTY, no fds — pure logic behind the `PaneSink` / `sendKeys` seams. Still dead code until Phase 3 connects it.

## Roadmap (remaining phases — separate plans)

- **Phase 3 — Virtual PTY + UI integration.** Add the socketpair-backed virtual `Pty` backend (`platform/pty_posix.zig`: `openVirtual` + `is_virtual` guard on `setSize`/`startCommand`, tests wired into `test_main.zig`). Back `PaneSink` with a virtual PTY feeding a `Surface`; route each pane's keystrokes from its virtual PTY into `Session.sendKeys`; reconcile the pane model into `split_tree` and windows into tabs; seed scrollback via `capture-pane`; parse the `list-windows` reply for complete initial enumeration.
- **Phase 4 — Resilience + UX.** Detach/reconnect overlay with backoff and re-bootstrap; `session_persist` re-attach; per-profile toggle + session-name field; DCS 1000p auto-detect hook; GUI verify.

---

## Self-Review

**1. Spec coverage (Phase 2 slice):** The spec's Architecture row for `src/tmux/session.zig` ("controller — pumps bytes → control.Parser → notifications; demuxes %output; reconciles layout; manages windows; emits commands; bootstrap") is covered: demux (Task 2), window model (Task 3), layout→panes (Task 4), bootstrap (Task 5), send-keys (Task 6), split/new/kill (Task 7), integration (Task 8). The "fake control server" testing approach in the spec's Testing section is realized as scripted `feed(...)` byte strings asserted against model + `pendingCommands()`. Deferred-with-rationale: virtual PTY, Surface/tab/split_tree wiring, capture-pane history, list-windows reply parsing, reconnect → Phase 3/4 (Roadmap), matching the spec's staged order (re-sequenced per the header note). `refresh-client -C WxH` uses the tmux ≥3.2 form; the spec's min-version note (≥3.0) is a Phase 4 fallback concern.

**2. Placeholder scan:** No `TBD`/`TODO`/"handle errors"/"similar to" placeholders. Every code step is complete and compilable; every `catch unreachable` is justified inline by a buffer-size argument. The `else => {}` in `handle` deliberately ignores `block_end`/`block_err`/`session_changed`/`sessions_changed`/`enter` (not needed for the Phase 2 model) — that is intentional scoping, not an omission.

**3. Type consistency:** `PaneSink{ctx, writeFn}` and its `write` defined in Task 1, used unchanged by `Collector` and `handle`. `Session` field names (`cmds`, `scratch`, `windows`, `active_pane`, `exited`, `cols`, `rows`) defined in Task 1 and used unchanged thereafter. `Window{id, name, panes}` defined in Task 1; `findWindow`/`ensureWindow`/`renameWindow`/`removeWindow` (Task 3) and `applyLayout`/`collectPanes` (Task 4) all use those names. `pendingCommands`/`clearCommands` (Task 1) used by Tasks 5–8. Command emitters use `self.cmds.appendSlice(self.alloc, ...)` consistently. `layout.Node`/`.leaf`/`.split`/`.children`/`.pane_id` and `layout.Dir.{horizontal,vertical}` match the Phase 1 definitions. `control.Notification` tags (`output`/`layout_change`/`window_add`/`window_renamed`/`window_close`/`window_pane_changed`/`exit`) match Phase 1's union.

One executor note: `handle`'s `switch` is built up across Tasks 2–4. Task 2 introduces it with `output` + `else`; Task 3 says to replace the lone `else => {}` with the window cases + `exit` + a trailing `else`; Task 4 inserts `layout_change` before that trailing `else`. Apply them in order.
