# tmux Control Mode — Phase 3b (Pane as Surface) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a tmux pane behave as a normal WispTerm `Surface` driven by the Phase 2 `Session`: add `Surface.initVirtual` (build a `Surface` around a pre-opened virtual `Pty`, no child process) and a Surface-agnostic `tmux/pane.zig` `PaneMap` that backs the `Session.PaneSink` (pane `%output` → the pane's `controller_fd`) and drains pane keystrokes (`controller_fd` → `Session.sendKeys`).

**Architecture:** Each pane is one `Pty.openVirtual` socketpair (Phase 3a). The `pty` end feeds a `Surface` via the new `Surface.initVirtual`, which reuses the *entire* `init` tail but skips `Pty.open`/`command.start`, leaving `command = .{}` — a posix `Command` with `pid = -1`, whose `wait()` already returns `null` ("still running") and whose `deinit()` is a safe no-op, so no new command type is needed. The `controller_fd` end is owned by a `PaneMap`, the testable seam: `sink()` writes unescaped `%output` into each pane's `controller_fd` (read by that `Surface`'s existing `ReadThread` — render path unchanged), and `pumpKeystrokes()` non-blocking-drains the keystrokes the `Surface` wrote into its virtual PTY and forwards them as `Session.sendKeys`. No `Surface` is constructed in tests: `Pty.openVirtual`'s `pty` end stands in for the `Surface`, exactly as in the Phase 3a virtual-PTY test.

**Tech Stack:** Zig 0.15.2; `std.posix` fd I/O (`read`/`write`/`poll`/`close`) + libc-linked `Pty.openVirtual`. New tests run in the full suite (`zig build test-full`) under an `os.tag != .windows` guard, like Phase 3a (the posix backend is excluded from the fast suite). `tmux/control.zig`/`layout.zig`/`session.zig` remain pure and stay in the fast suite.

**Reference:** Spec `docs/superpowers/specs/2026-06-03-tmux-control-mode-integration-design.md`; Phase 3a plan `docs/superpowers/plans/2026-06-03-tmux-control-mode-phase3a-virtual-pty.md`. Phase 2 controller: `src/tmux/session.zig` (`PaneSink`, `Session.feed`/`sendKeys`/`pendingCommands`). Phase 3a transport: `src/platform/pty_posix.zig` (`Pty.openVirtual` → `VirtualPair{ pty, controller_fd }`).

---

## Phase 3 decomposition (where 3b sits)

Phase 3 (UI integration) is several subsystems with different blast radii. 3a delivered the transport; 3b delivers the **pane I/O bridge + the no-child Surface constructor** — still no full-screen wiring, so it stays unit-testable without a GPU/window.

- **3a (done):** virtual `Pty` backend (`Pty.openVirtual`, socketpair). `47c5d70` / `c8c11a5`.
- **3b (this plan):** `Surface.initVirtual` (no-child pane surface) + `tmux/pane.zig` `PaneMap` (backs `Session.PaneSink`, pumps keystrokes → `Session.sendKeys`). Self-contained and testable with `Pty.openVirtual` socketpairs.
- **3c (next plan):** create a `VirtualPair` per pane, build the `Surface` with `Surface.initVirtual`, register it in `PaneMap`, place the `*Surface` into `split_tree` (panes↔splits) and map windows↔tabs. Requires reading `split_tree.zig` (note its `TestSurface`/`fromSnapshot` pattern) and `appwindow/tab.zig`.
- **3d (next plan):** launch `ssh … tmux -CC`, run the controller read-loop (poll the ssh fd **and** all `controller_fd`s, route ssh→`Session.feed`, drain `Session.pendingCommands()` to the ssh pipe, call `PaneMap.pumpKeystrokes`), wire `capture-pane` history seeding + `refresh-client -C` on resize + `list-windows` reply parsing. Requires reading the SSH launch path and `AppWindow` threading.

### Why a Surface cannot be constructed in a test (so 3b's logic must be Surface-agnostic)

`Surface.init` builds a per-surface `Renderer` (`src/renderer/Renderer.zig`, `const c = AppWindow.gpu.c;` — owns GPU/FBO handles) and spawns two IO threads. No existing test constructs a `Surface` (the 20 tests in `appwindow/tab.zig` exercise persistence/reorder logic, never `Surface.init`). This repo has no Linux GUI backend. Therefore `Surface.initVirtual` is **compile-checked + signature-guarded** here and GUI-verified later (exactly how Phase 3a deferred its Windows half), while all *runtime-tested* 3b logic lives in `tmux/pane.zig`, which touches only fds + the `Session`.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/Surface.zig` | MODIFY. Extract the post-`pty`/`command` tail of `init` into a private `finishInit(surface, allocator, cols, rows, launch_kind, cwd)`; add `pub fn initVirtual(...)` that adopts a pre-opened virtual `Pty`, leaves `command = .{}`, and calls `finishInit(..., .ssh, null)`. Add one test that forces analysis of `init`/`initVirtual` and guards `initVirtual`'s signature. |
| `src/tmux/pane.zig` | NEW. `PaneMap`: owns each pane's `controller_fd`; `sink()` returns a `session.PaneSink` that writes pane output to the matching fd; `pumpKeystrokes(*Session)` non-blocking-drains keystrokes → `Session.sendKeys`. `addPane`/`find`/`removePane`/`deinit`. Imports only `std` + `session.zig` — no `Surface`, no `Pty`. |
| `src/tmux/pane_io_test.zig` | NEW. Posix-only tests using real `Pty.openVirtual` socketpairs (the `pty` end plays the `Surface`). Kept separate so `pane.zig` stays portable (`std` + `session`) and the libc/socketpair dependency lives only in the test, like `pty_virtual_test.zig`. |
| `src/test_main.zig` | MODIFY. Register `_ = @import("Surface.zig")` (so the new signature test runs) and `_ = @import("tmux/pane_io_test.zig")` under the existing `os.tag != .windows` guard. |

---

## Task 1: `Surface.initVirtual` + shared `finishInit`

**Files:**
- Modify: `src/Surface.zig` (refactor `init`; add `finishInit`, `initVirtual`, one test)
- Modify: `src/test_main.zig` (register `Surface.zig`)

- [ ] **Step 1: Register `Surface.zig` and write the failing signature test**

In `src/test_main.zig`, find the line `    _ = @import("App.zig");` (currently line 623) and add directly before it:

```zig
    _ = @import("Surface.zig");
```

Then in `src/Surface.zig`, append at the very end of the file (after `updateTitle` / the final `}`):

```zig

test "Surface exposes init and initVirtual (forces analysis of the shared finishInit refactor)" {
    // Address-of forces full semantic analysis + codegen of both constructors,
    // and therefore of the shared finishInit they call. Without this, an unused
    // initVirtual could carry a refactor bug that the headless suite never sees.
    _ = &init;
    _ = &initVirtual;

    const info = @typeInfo(@TypeOf(initVirtual)).@"fn";
    // allocator, cols, rows, pty, scrollback_limit, cursor_style, cursor_blink
    try std.testing.expectEqual(@as(usize, 7), info.params.len);
    try std.testing.expect(info.params[3].type.? == Pty);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-full`
Expected: FAIL — compile error, `initVirtual` is not declared in `Surface.zig` (`error: no member named 'initVirtual'`).

- [ ] **Step 3: Extract `finishInit` from `init`**

In `src/Surface.zig`, in `pub fn init(...)`, **replace the entire block** from the `// Init remaining fields` comment through the final `return surface;` (currently lines 373–481, i.e. everything after `errdefer surface.command.deinit();`) with this single line:

```zig
    return finishInit(surface, allocator, cols, rows, platform_pty_command.launchKindForCommand(shell_cmd), cwd);
```

Then add the extracted body as a new private function immediately after `init`'s closing brace (before `pub fn deinit`). It is the moved block verbatim, with exactly two lines changed: the `launch_kind` assignment now uses the parameter, and `captureInitialCwd` uses the parameter:

```zig
fn finishInit(
    surface: *Surface,
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    launch_kind: LaunchKind,
    cwd: platform_pty_command.Cwd,
) !*Surface {
    // Init remaining fields
    surface.allocator = allocator;
    surface.selection = .{};
    surface.render_state = renderer.State.init(&surface.terminal);
    surface.launch_kind = launch_kind;
    surface.ssh_connection = null;
    surface.remote_client = null;
    remote.nextSurfaceId(&surface.remote_id);
    surface.vt_stream = surface.initVtStream();
    errdefer surface.vt_stream.deinit();
    surface.dirty = std.atomic.Value(bool).init(true);
    surface.sync_output_state = .{};
    surface.exited = std.atomic.Value(bool).init(false);
    surface.resize_in_progress = std.atomic.Value(bool).init(false);

    // Desktop-notification state. `allocator.create` returns undefined memory
    // and this constructor initializes every field explicitly (struct-default
    // values are NOT applied here), so these must be set or notif_queue's mutex
    // is garbage — the first handleNotification()/Queue.pop() lock then aborts
    // with os_unfair_lock corruption (SIGKILL on the first frame).
    surface.notif_queue = .{};
    surface.last_notif_hash = 0;
    surface.last_notif_time = 0;

    // OSC 52 clipboard write state. Same caveat as notif_queue above: the mutex
    // must be explicitly initialized or its first lock corrupts on garbage memory.
    surface.clipboard_write_pending = null;
    surface.clipboard_write_mutex = .{};

    // Initialize mailbox for main thread → IO writer communication
    surface.mailbox = try termio.Mailbox.init();
    errdefer surface.mailbox.deinit();
    surface.io_thread_state = null;
    surface.io_writer_thread = null;
    surface.io_reader_thread = null;

    // Initialize grid size to match terminal dimensions.
    // This prevents spurious resize on first render when computeSplitLayout
    // calls setScreenSize - without this, the default 80x24 would differ from
    // the actual terminal dimensions, triggering a resize that can corrupt
    // terminal state if the shell has already output content.
    surface.size.grid.cols = cols;
    surface.size.grid.rows = rows;

    // Initialize per-surface renderer (Ghostty architecture)
    surface.surface_renderer = Renderer.init(surface);
    surface.renderer_thread = RendererThread.init(&surface.surface_renderer, surface);

    // Init OSC state
    surface.window_title_len = 0;
    surface.title_override_len = 0;
    surface.osc_state = .ground;
    surface.osc_is_title = false;
    surface.osc_num = 0;
    surface.osc_buf_len = 0;
    surface.osc7_title_len = 0;
    surface.got_osc7_this_batch = false;
    surface.wispterm_image_osc_state = .ground;
    surface.wispterm_image_osc_buf = .empty;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.agent_detection = .{};
    surface.agent_recent_output_len = 0;
    surface.captureInitialCwd(cwd);

    // Init bell state
    surface.bell_pending = std.atomic.Value(bool).init(false);
    surface.last_bell_time = 0;
    surface.bell_opacity = 0;
    surface.bell_indicator = false;
    surface.bell_indicator_time = 0;

    // Init scrollbar state
    surface.scrollbar_opacity = 0;
    surface.scrollbar_show_time = 0;

    // Init ref count (for split tree ownership)
    surface.ref_count = 1;

    // Initialize IO writer thread state (xev loop, async handles)
    const thread_state = try allocator.create(termio.Thread);
    errdefer allocator.destroy(thread_state);
    thread_state.* = try termio.Thread.init();
    errdefer thread_state.deinit();
    surface.io_thread_state = thread_state;

    // Spawn IO writer thread (xev event loop — handles resize, future messages)
    surface.io_writer_thread = std.Thread.spawn(threading.surface_thread_spawn_config, termio.Thread.threadMain, .{ thread_state, surface }) catch |err| {
        std.debug.print("Failed to spawn IO writer thread: {}\n", .{err});
        return err;
    };
    errdefer {
        // Stop the writer thread before any deeper cleanup runs.
        if (surface.io_thread_state) |st| st.stop.notify() catch {};
        if (surface.io_writer_thread) |t| t.join();
    }

    // Spawn IO reader thread (blocking PTY output loop)
    surface.io_reader_thread = std.Thread.spawn(threading.surface_thread_spawn_config, termio.ReadThread.threadMain, .{surface}) catch |err| {
        std.debug.print("Failed to spawn IO reader thread: {}\n", .{err});
        return err;
    };

    // The renderer thread is kept as a future integration point, but the actual
    // snapshot/rebuild path still runs on the main thread today. Starting it now
    // only adds an idle per-surface thread and stack without moving work off the
    // main render loop.

    return surface;
}
```

The outer `errdefer`s for `surface`/`terminal`/`pty`/`command` stay in `init`; they fire correctly if `finishInit` returns an error (an `errdefer` in `init` runs when `init` returns an error, including one bubbled up from `finishInit`). `finishInit`'s own `errdefer`s (vt_stream, mailbox, thread_state, writer thread) move with the block and protect only the resources it creates.

- [ ] **Step 4: Add `initVirtual`**

In `src/Surface.zig`, immediately after the new `finishInit` function, add:

```zig
/// Build a Surface around a pre-opened *virtual* PTY (`Pty.openVirtual`).
/// Used for tmux control-mode panes: there is no child process — the Phase 2
/// controller feeds pane output into the PTY and reads keystrokes back across
/// the pair's `controller_fd`. The caller retains `controller_fd` (typically
/// in a `tmux/pane.zig` PaneMap); this Surface owns only the `pty` end.
///
/// `command` is left as `.{}` (pid -1): its `wait()` reports "still running"
/// and its `deinit()` is a no-op, so the no-child pane never looks "exited"
/// until its `controller_fd` is closed (which gives the reader an EOF).
pub fn initVirtual(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pty: Pty,
    scrollback_limit: u32,
    cursor_style: Config.CursorStyle,
    cursor_blink: bool,
) !*Surface {
    const surface = try allocator.create(Surface);
    errdefer allocator.destroy(surface);

    surface.terminal = ghostty_vt.Terminal.init(allocator, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = scrollback_limit,
        .default_modes = .{ .grapheme_cluster = true },
        .kitty_image_storage_limit = 50 * 1024 * 1024,
        .kitty_image_loading_limits = .all,
    }) catch |err| {
        return err;
    };
    errdefer surface.terminal.deinit(allocator);

    surface.terminal.screens.active.cursor.cursor_style = switch (cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    surface.terminal.modes.set(.cursor_blinking, cursor_blink);

    // Adopt the caller's virtual PTY; no child process is launched.
    surface.pty = pty;
    errdefer surface.pty.deinit();
    surface.command = .{};
    errdefer surface.command.deinit();

    return finishInit(surface, allocator, cols, rows, .ssh, null);
}
```

`LaunchKind` (re-exported at the top of `Surface.zig` as `pub const LaunchKind = platform_pty_command.LaunchKind;`) is in scope, so `.ssh` resolves. `platform_pty_command.Cwd` is `?[*:0]const u8`, so `null` is valid; `captureInitialCwd(null)` falls back to the local cwd, which only seeds the path-paste fallback and is later superseded by the remote shell's OSC 7 — acceptable for v1.

- [ ] **Step 5: Run the test to verify it passes**

Run: `zig build test-full`
Expected: PASS, exit 0. The new `Surface` test runs (`_ = &init; _ = &initVirtual;` forces the refactor to compile; the signature assertions hold). No behavioral change for real surfaces — `init` produces exactly the same surface as before, now via `finishInit`.

- [ ] **Step 6: Commit**

```bash
git add src/Surface.zig src/test_main.zig
git commit -m "feat(tmux): Surface.initVirtual — build a no-child pane Surface on a virtual PTY"
```

---

## Task 2: `tmux/pane.zig` `PaneMap` — registry + output sink

**Files:**
- Create: `src/tmux/pane_io_test.zig`
- Create: `src/tmux/pane.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write the failing tests + register them**

Create `src/tmux/pane_io_test.zig`:

```zig
//! Posix-only tests for the tmux pane I/O bridge (`pane.zig`).
//!
//! Uses real `Pty.openVirtual` socketpairs: the `pty` end stands in for a
//! pane's Surface (it reads rendered `%output` and writes keystrokes), while
//! the `controller_fd` is owned by the PaneMap under test. Kept out of
//! `pane.zig` so that module stays portable (std + session only); the
//! libc/socketpair dependency lives here, like `platform/pty_virtual_test.zig`.

const std = @import("std");
const pane = @import("pane.zig");
const session = @import("session.zig");
const pty = @import("../platform/pty.zig"); // facade lives in src/platform/

/// A PaneSink that ignores output — for keystroke-only tests.
fn nullSink() session.PaneSink {
    return .{
        .ctx = undefined,
        .writeFn = struct {
            fn f(_: *anyopaque, _: usize, _: []const u8) void {}
        }.f,
    };
}

test "PaneMap.sink delivers %output to the matching pane's controller fd" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit(); // the Surface end

    var map = pane.PaneMap.init(alloc);
    defer map.deinit(); // closes controller_fd
    try map.addPane(7, pair.controller_fd);

    map.sink().write(7, "hello");

    var buf: [16]u8 = undefined;
    const n = try pair.pty.readOutput(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "PaneMap.sink drops output for an unknown pane" {
    const alloc = std.testing.allocator;
    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    // No panes registered: must be a safe no-op, not a crash.
    map.sink().write(3, "ignored");
}

test "Session %output flows through PaneMap.sink, unescaped, to the pane" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    try map.addPane(2, pair.controller_fd);

    var s = session.Session.init(alloc, map.sink(), 80, 24);
    defer s.deinit();
    // \033 octal-escapes to ESC (0x1b); session unescapes before the sink.
    try s.feed("%output %2 ab\\033c\n");

    var buf: [16]u8 = undefined;
    const n = try pair.pty.readOutput(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 0x1b, 'c' }, buf[0..n]);
}

test "PaneMap.removePane unregisters the pane and closes its fd" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit(); // pane already gone; must not double-close
    try map.addPane(5, pair.controller_fd);

    map.removePane(5);
    try std.testing.expect(map.find(5) == null);
    // Output to a removed pane is dropped (no crash).
    map.sink().write(5, "gone");
}
```

In `src/test_main.zig`, find the existing posix guard block:

```zig
    if (@import("builtin").os.tag != .windows) {
        _ = @import("platform/pty_virtual_test.zig");
    }
```

and add the new import inside it:

```zig
    if (@import("builtin").os.tag != .windows) {
        _ = @import("platform/pty_virtual_test.zig");
        _ = @import("tmux/pane_io_test.zig");
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test-full`
Expected: FAIL — compile error, `tmux/pane.zig` does not exist (`error: unable to load 'src/tmux/pane.zig'`).

- [ ] **Step 3: Create `src/tmux/pane.zig` with `PaneMap` + sink**

```zig
//! tmux pane I/O bridge.
//!
//! Owns the controller-side fd of each pane's virtual PTY (the other end of a
//! `Pty.openVirtual` socketpair, whose `pty` end feeds a `Surface.initVirtual`
//! surface). Backs the Phase 2 `session.PaneSink` — pane `%output` is written
//! to the matching `controller_fd`, where the pane's Surface reads it via its
//! normal `ReadThread` (render path unchanged) — and drains pane keystrokes
//! (`controller_fd` → `Session.sendKeys`).
//!
//! Surface-agnostic: it touches only fds and the `Session`, so it is
//! unit-testable with bare `Pty.openVirtual` socketpairs (see
//! `pane_io_test.zig`). Phase 3c/3d pair each `controller_fd`'s other end with
//! a real Surface and poll all fds alongside the ssh stream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const session = @import("session.zig");

pub const PaneMap = struct {
    alloc: Allocator,
    panes: std.ArrayListUnmanaged(Pane) = .empty,
    /// Drain scratch for pumpKeystrokes. The pump is single-threaded (the
    /// controller loop), so one shared buffer is safe.
    read_buf: [4096]u8 = undefined,

    pub const Pane = struct {
        id: usize,
        controller_fd: std.posix.fd_t,
    };

    pub fn init(alloc: Allocator) PaneMap {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *PaneMap) void {
        for (self.panes.items) |p| std.posix.close(p.controller_fd);
        self.panes.deinit(self.alloc);
    }

    /// Register a pane and take ownership of its controller-side fd.
    /// `removePane`/`deinit` close it, which gives the pane's Surface an EOF.
    pub fn addPane(self: *PaneMap, id: usize, controller_fd: std.posix.fd_t) Allocator.Error!void {
        try self.panes.append(self.alloc, .{ .id = id, .controller_fd = controller_fd });
    }

    pub fn find(self: *PaneMap, id: usize) ?*Pane {
        for (self.panes.items) |*p| {
            if (p.id == id) return p;
        }
        return null;
    }

    /// Drop a pane and close its `controller_fd`. Closing the controller end
    /// gives the pane's Surface an EOF on its next read, so its ReadThread
    /// marks the surface exited. No-op if the pane is unknown.
    pub fn removePane(self: *PaneMap, id: usize) void {
        var i: usize = 0;
        while (i < self.panes.items.len) : (i += 1) {
            if (self.panes.items[i].id == id) {
                std.posix.close(self.panes.items[i].controller_fd);
                _ = self.panes.orderedRemove(i);
                return;
            }
        }
    }

    /// A `session.PaneSink` that delivers `%output` bytes to each pane's
    /// `controller_fd`. Output for an unknown pane is dropped.
    pub fn sink(self: *PaneMap) session.PaneSink {
        return .{ .ctx = self, .writeFn = writeImpl };
    }

    fn writeImpl(ctx: *anyopaque, pane_id: usize, bytes: []const u8) void {
        const self: *PaneMap = @ptrCast(@alignCast(ctx));
        const pane = self.find(pane_id) orelse return;
        writeAll(pane.controller_fd, bytes);
    }
};

/// Best-effort write of all bytes; partial writes are retried, errors dropped
/// (matches Surface's PTY write path, which also swallows write errors).
fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.posix.write(fd, bytes[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test-full`
Expected: PASS, exit 0. The four `pane_io_test.zig` sink/registry tests pass on this Linux host (`Pty.openVirtual` exists on the posix backend; the `!= .windows` guard keeps it out of a Windows build).

- [ ] **Step 5: Commit**

```bash
git add src/tmux/pane.zig src/tmux/pane_io_test.zig src/test_main.zig
git commit -m "feat(tmux): PaneMap backs the Session PaneSink (pane output -> virtual PTY)"
```

---

## Task 3: `PaneMap.pumpKeystrokes` — pane keystrokes → `Session.sendKeys`

**Files:**
- Modify: `src/tmux/pane_io_test.zig` (add tests)
- Modify: `src/tmux/pane.zig` (add `pumpKeystrokes` + `readable`)

- [ ] **Step 1: Write the failing tests**

Append to `src/tmux/pane_io_test.zig`:

```zig
test "pumpKeystrokes forwards a pane's keystrokes as a hex send-keys" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    try map.addPane(4, pair.controller_fd);

    var s = session.Session.init(alloc, nullSink(), 80, 24);
    defer s.deinit();

    // The Surface writes keystrokes into its pty; the bytes surface on the
    // controller_fd, which the pump turns into a hex send-keys for pane %4.
    try pair.pty.writeInput("ls\n"); // l=6c s=73 \n=0a
    try map.pumpKeystrokes(&s);
    try std.testing.expectEqualStrings("send-keys -t %4 -H 6c 73 0a\n", s.pendingCommands());
}

test "pumpKeystrokes routes each pane to its own pane id" {
    const alloc = std.testing.allocator;
    var a = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer a.pty.deinit();
    var b = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer b.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    try map.addPane(1, a.controller_fd);
    try map.addPane(2, b.controller_fd);

    var s = session.Session.init(alloc, nullSink(), 80, 24);
    defer s.deinit();

    try a.pty.writeInput("x"); // x=78
    try b.pty.writeInput("y"); // y=79
    try map.pumpKeystrokes(&s);

    const cmds = s.pendingCommands();
    try std.testing.expect(std.mem.indexOf(u8, cmds, "send-keys -t %1 -H 78\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmds, "send-keys -t %2 -H 79\n") != null);
}

test "pumpKeystrokes is a no-op when no keystrokes are pending" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    try map.addPane(9, pair.controller_fd);

    var s = session.Session.init(alloc, nullSink(), 80, 24);
    defer s.deinit();

    try map.pumpKeystrokes(&s); // nothing written → nothing queued
    try std.testing.expectEqual(@as(usize, 0), s.pendingCommands().len);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test-full`
Expected: FAIL — compile error, `PaneMap` has no member `pumpKeystrokes` (`error: no member named 'pumpKeystrokes'`).

- [ ] **Step 3: Add `pumpKeystrokes` + the `readable` helper**

In `src/tmux/pane.zig`, add this method to `PaneMap` immediately after `sink` (before `writeImpl`):

```zig
    /// Non-blocking drain: forward any keystrokes the panes' Surfaces have
    /// written into their virtual PTYs as hex `send-keys` on the Session's
    /// command queue. Intended to be called from the controller loop after a
    /// poll; safe to call when nothing is pending. A `read` of 0 (the Surface
    /// closed its end) stops draining that pane — its removal is driven by the
    /// layout reconcile, not here.
    pub fn pumpKeystrokes(self: *PaneMap, s: *session.Session) Allocator.Error!void {
        for (self.panes.items) |p| {
            while (readable(p.controller_fd)) {
                const n = std.posix.read(p.controller_fd, &self.read_buf) catch break;
                if (n == 0) break;
                try s.sendKeys(p.id, self.read_buf[0..n]);
            }
        }
    }
```

And add this file-scope helper next to `writeAll`:

```zig
/// True if `fd` has bytes ready to read right now (poll, zero timeout).
/// POLLHUP-without-data (the Surface closed its end) reads as not-readable, so
/// pumpKeystrokes never spins on a dead pane.
fn readable(fd: std.posix.fd_t) bool {
    var fds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, 0) catch return false;
    if (ready == 0) return false;
    return fds[0].revents & std.posix.POLL.IN != 0;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test-full`
Expected: PASS, exit 0. All `pane_io_test.zig` tests pass; the rest of the suite is unaffected.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/pane.zig src/tmux/pane_io_test.zig
git commit -m "feat(tmux): PaneMap.pumpKeystrokes routes pane input to Session.sendKeys"
```

---

## Phase 3b Done — What Ships

- `Surface.initVirtual(allocator, cols, rows, pty, scrollback, cursor_style, cursor_blink)` — a `Surface` driven by a pre-opened virtual `Pty` with no child process (`command = .{}`, `pid -1`: `wait()` → "still running", `deinit()` → no-op). Built from the same `finishInit` tail as `init`, so render/selection/search/OSC/AI all work identically. Compile-/signature-checked headlessly; runtime path GUI-verified in 3c/3d.
- `tmux/pane.zig` `PaneMap` — owns each pane's `controller_fd`; `sink()` backs `Session.PaneSink` (unescaped `%output` → the pane's fd → its Surface's ReadThread); `pumpKeystrokes(*Session)` forwards Surface-written keystrokes as `send-keys -H`; `addPane`/`find`/`removePane`/`deinit` with fd ownership. Fully unit-tested over real socketpairs.

Still **no user-facing behavior**: nothing constructs a pane Surface or runs a controller yet. The two ends meet in 3c (split tree / tabs) and 3d (connection + read loop).

## Remaining Phase 3 (separate plans — study required before writing)

These are deliberately deferred; each becomes its own plan after reading the large files it touches. Not placeholder tasks.

- **3c — Layout/tab reconcile + pane lifecycle.** Study `split_tree.zig` (the `SplitTree`/`Handle` API, `split`/`remove`/`resizeInPlace`, and its `TestSurface`/`fromSnapshot` pattern) and `appwindow/tab.zig` (`spawnTab*`, `closeTab`, split via `Surface.init`). For each tmux pane: `Pty.openVirtual` → `Surface.initVirtual` → `PaneMap.addPane(pane_id, controller_fd)` and place the `*Surface` into the window's `split_tree`. Implement `split_tree.reconcileFromTmuxLayout(layout.Node)` (minimal add/remove/move vs. the current tree) and window→tab create/rename/close from `Session` events; remove a pane's Surface + `PaneMap.removePane` when it leaves the layout. (Likely give `PaneMap.Pane` an optional `*Surface` so reconcile can find the surface for a pane id.)
- **3d — Connection + bootstrap + the pump loop.** Study the SSH launch path (`platform/pty_command.sshInteractiveCommand`, `appwindow/tab.zig` spawn) and `AppWindow` threading. Launch `ssh -tt host -- tmux -CC new -A -s <name>`; run a controller read-loop that polls the ssh fd **and** every `PaneMap` `controller_fd` in one set, routes ssh output → `Session.feed`, drains `Session.pendingCommands()` → the ssh pipe (then `clearCommands`), and calls `PaneMap.pumpKeystrokes`; wire `Session.start` bootstrap + `capture-pane -p -e -J` history seeding + `refresh-client -C` on resize + `list-windows` reply parsing. (3d may replace `pumpKeystrokes`' per-pane `poll(0)` with the unified poll set for efficiency — the per-pane drain stays correct regardless.)

---

## Self-Review

**1. Spec coverage (3b slice).** The spec's `src/platform/pty.zig … virtual Pty backend` row was 3a. The 3b slice covers two spec elements: (a) the **Data Flow → Input** path ("`Surface` keystrokes → virtual PTY → controller → hex-encode → `send-keys -t %id -H`") is realized by `pumpKeystrokes` over the controller_fd into `Session.sendKeys` (the hex encoding already lives in Phase 2 `session.sendKeys`); (b) the **Data Flow → Output** path ("`%output` … → write to pane's virtual-PTY write end → that `Surface`'s `ReadThread` reads and renders") is realized by `PaneMap.sink()` writing to `controller_fd`. The spec's Architecture line "Each tmux pane is a normal `Surface` … reads/writes its `Pty` exactly as today" is realized by `Surface.initVirtual` reusing `finishInit` unchanged. Everything else in the spec (split_tree reconcile, windows↔tabs, bootstrap/`capture-pane`, `refresh-client` resize, connection/read-loop, detach/reconnect, profile toggle, DCS auto-detect) is explicitly 3c/3d/Phase 4 and listed in the roadmap — no silent gaps.

**2. Placeholder scan.** No `TBD`/`TODO`/"handle errors"/"similar to" in the executable steps. Every step is a complete edit with exact anchor text and full code; `finishInit` is reproduced verbatim (a move with exactly two changed lines, both shown) rather than referenced. The "Remaining Phase 3" section is a roadmap (no checkboxes), not tasks.

**3. Type consistency.** `PaneMap` (Task 2) is constructed `init(alloc)`, mutated via `addPane(id, controller_fd)`, queried via `find(id) ?*Pane`, torn down via `deinit()`, and `removePane(id)`; `pane_io_test.zig` and `pumpKeystrokes` (Task 3) use exactly those names and the `Pane{ id, controller_fd }` shape. `sink()` returns a `session.PaneSink{ ctx, writeFn }` matching `session.zig`'s definition (`writeFn: *const fn (*anyopaque, usize, []const u8) void`); `writeImpl`'s signature matches. `pumpKeystrokes(self, s: *session.Session)` calls `s.sendKeys(id, bytes)` and the tests read `s.pendingCommands()` — both match Phase 2's `Session` API verbatim, and the expected `"send-keys -t %4 -H 6c 73 0a\n"` matches Phase 2's own `sendKeys` test. `Pty.openVirtual`/`readOutput`/`writeInput`/`deinit` and `VirtualPair{ pty, controller_fd }` match Phase 3a exactly. `initVirtual`'s 7-param signature (asserted in the Task 1 test) matches its definition, and `Pty`/`Config.CursorStyle`/`LaunchKind`/`platform_pty_command.Cwd`/`ghostty_vt`/`renderer`/`termio`/`Renderer`/`RendererThread`/`threading`/`remote` are all already imported in `Surface.zig`.
