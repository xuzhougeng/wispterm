# tmux Control Mode — Phase 3a (Virtual PTY Backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a socketpair-backed *virtual* `Pty` to the POSIX backend so a `Surface` can be driven by the tmux controller instead of an OS pseudo-terminal — same `readOutput`/`writeInput`/`outputAvailable`/`cancelOutputRead`/`getSize` surface, with `setSize` a no-op. This is the transport the Phase 2 `PaneSink` will write into and read keystrokes back from in Phase 3b.

**Architecture:** A virtual `Pty` holds one end of an `AF_UNIX` `socketpair` as its `master` fd; the controller holds the other end (`controller_fd`). Because the existing `readOutput`/`writeInput`/`outputAvailable`/`cancelOutputRead` already drive `master` purely through `poll`/`read`/`write`/`FIONREAD` — all valid on a stream socket — they work unchanged. Only `setSize` (which `ioctl`s `TIOCSWINSZ`, invalid on a socket) needs an `is_virtual` guard. The cancel self-pipe is created exactly as for a real PTY, so blocking reads stay cancellable.

**Tech Stack:** Zig 0.15.2 + libc (the POSIX backend already links `-lc`). New test in the full suite (`zig build test-full`), because `pty_posix.zig` depends on libc and is excluded from the fast suite.

**Reference:** Spec `docs/superpowers/specs/2026-06-03-tmux-control-mode-integration-design.md`. The `Pty` struct lives in `src/platform/pty_posix.zig` (fields `master`/`slave_path`/`size`/`cancel_pipe`).

---

## Phase 3 decomposition (why this is "3a")

Phase 3 (UI integration) is several subsystems with very different blast radii. This plan delivers the **self-contained transport**; the rest get their own plans after studying the large files they touch:

- **3a (this plan):** virtual `Pty` backend. Self-contained, platform-only, testable in isolation.
- **3b:** back `PaneSink` with a virtual-`Pty` `Surface`; route that pane's keystrokes into `Session.sendKeys`; give the no-child `Command` a lifecycle that `wait()` treats as never-exiting. Requires reading `Surface.zig` (init/spawn/threads) and `Command.zig`/`pty_command.zig`.
- **3c:** reconcile the `Session` window/pane model into `split_tree` (panes↔splits) and windows↔tabs. Requires reading `split_tree.zig` and `appwindow/tab.zig`.
- **3d:** launch `ssh … tmux -CC`, run the controller read-loop, wire bootstrap/`capture-pane` history + `refresh-client` resize, parse the `list-windows` reply. Requires reading the SSH launch path and `AppWindow` threading.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/platform/pty_posix.zig` | MODIFY. Add `is_virtual` flag, `openVirtual` (socketpair construction returning the pty + the controller's fd), and an `is_virtual` guard in `setSize`. `startCommand` is intentionally left to 3b (it needs the no-child `Command` lifecycle). |
| `src/platform/pty_virtual_test.zig` | NEW. Posix-only test exercising `openVirtual` round-trips and `setSize` no-op via the facade `pty.zig`. Kept separate from `pty_posix.zig` so it doesn't activate that file's other (currently unregistered) tests. |
| `src/test_main.zig` | MODIFY. Register the new test under an `os.tag != .windows` guard (full suite, libc-linked). |

---

## Task 1: virtual `Pty` construction + `setSize` no-op

**Files:**
- Modify: `src/platform/pty_posix.zig`

- [ ] **Step 1: Declare the libc `socketpair` extern**

In `src/platform/pty_posix.zig`, add to the `extern "c"` block (right after the `extern "c" fn _exit(code: c_int) noreturn;` line near the top):

```zig
extern "c" fn socketpair(domain: c_int, sock_type: c_int, protocol: c_int, sv: *[2]c_int) c_int;
```

- [ ] **Step 2: Add the `is_virtual` field**

In `pub const Pty = struct { ... }`, add a field after `cancel_pipe: [2]fd_t,`:

```zig
    is_virtual: bool,
```

- [ ] **Step 3: Initialize `is_virtual` in `open`**

In `pub fn open(size: winsize) !Pty`, after the line `self.size = size;` (the first assignment in the function), add:

```zig
        self.is_virtual = false;
```

(`open` builds the struct from `undefined`, so the flag must be set explicitly — a struct-level default would not apply.)

- [ ] **Step 4: Add `VirtualPair` + `openVirtual`**

Immediately after the `open` function (before `deinit`), add:

```zig
    pub const VirtualPair = struct {
        pty: Pty,
        /// The controller's end of the socketpair. The caller owns it and must
        /// `std.posix.close` it; `Pty.deinit` only closes the pty's own `master`.
        controller_fd: fd_t,
    };

    /// Create a virtual PTY backed by a socketpair. The returned `pty` reads
    /// what is written to `controller_fd` and vice-versa, so the tmux controller
    /// can feed pane output in and read keystrokes back out. No child process.
    pub fn openVirtual(size: winsize) !VirtualPair {
        var sv: [2]c_int = undefined;
        if (socketpair(
            @intCast(std.posix.AF.UNIX),
            @intCast(std.posix.SOCK.STREAM),
            0,
            &sv,
        ) != 0) return error.SocketPairFailed;
        errdefer {
            _ = c.close(sv[0]);
            _ = c.close(sv[1]);
        }

        var self: Pty = undefined;
        self.master = sv[0];
        self.is_virtual = true;
        self.slave_path = std.mem.zeroes([SLAVE_PATH_MAX]u8);
        self.size = size;
        self.cancel_pipe = try std.posix.pipe();
        return .{ .pty = self, .controller_fd = sv[1] };
    }
```

- [ ] **Step 5: Guard `setSize` for virtual ptys**

Replace the body of `pub fn setSize(self: *Pty, s: winsize) !void { ... }` with:

```zig
    pub fn setSize(self: *Pty, s: winsize) !void {
        if (self.is_virtual) {
            // A socketpair has no window size; the tmux controller owns sizing
            // via refresh-client. Just record it for getSize.
            self.size = s;
            return;
        }
        try setWindowSize(self.master, self.slavePathSlice(), s);
        self.size = s;
    }
```

- [ ] **Step 6: Verify the backend still compiles (no test yet)**

Run: `zig build test-full`
Expected: PASS, exit 0. (No behavior change for real ptys; the new code is unused until Task 2 tests it.)

- [ ] **Step 7: Commit**

```bash
git add src/platform/pty_posix.zig
git commit -m "feat(tmux): virtual PTY backend (socketpair) in the posix Pty"
```

---

## Task 2: virtual PTY test + registration

**Files:**
- Create: `src/platform/pty_virtual_test.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Create `src/platform/pty_virtual_test.zig`**

```zig
//! Posix-only tests for the virtual (socketpair-backed) Pty. Kept out of
//! `pty_posix.zig` so registering it does not pull in that file's other,
//! currently-unregistered tests. Runs in the full suite (libc-linked).

const std = @import("std");
const pty = @import("pty.zig");

test "virtual pty round-trips bytes in both directions" {
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();
    defer std.posix.close(pair.controller_fd);

    // controller -> surface: data written to controller_fd is read via readOutput.
    _ = try std.posix.write(pair.controller_fd, "hi");
    var buf: [16]u8 = undefined;
    const n = try pair.pty.readOutput(&buf);
    try std.testing.expectEqualStrings("hi", buf[0..n]);

    // surface -> controller: writeInput is read from controller_fd.
    try pair.pty.writeInput("yo");
    var buf2: [16]u8 = undefined;
    const m = try std.posix.read(pair.controller_fd, &buf2);
    try std.testing.expectEqualStrings("yo", buf2[0..m]);
}

test "virtual pty setSize is a no-op that still records the size" {
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();
    defer std.posix.close(pair.controller_fd);

    try pair.pty.setSize(.{ .ws_col = 100, .ws_row = 30 });
    try std.testing.expectEqual(@as(u16, 100), pair.pty.getSize().ws_col);
    try std.testing.expectEqual(@as(u16, 30), pair.pty.getSize().ws_row);
}

test "virtual pty outputAvailable reflects pending bytes" {
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();
    defer std.posix.close(pair.controller_fd);

    _ = try std.posix.write(pair.controller_fd, "abc");
    // Give the socket a moment isn't needed: AF_UNIX delivery is synchronous
    // enough that FIONREAD sees the 3 queued bytes on the read end.
    const avail = pair.pty.outputAvailable() orelse 0;
    try std.testing.expect(avail >= 3);
}
```

- [ ] **Step 2: Register it in `src/test_main.zig`**

In the `_ = @import(...)` test block, find the line `_ = @import("platform/pty.zig");` and add directly after it:

```zig
    if (@import("builtin").os.tag != .windows) {
        _ = @import("platform/pty_virtual_test.zig");
    }
```

- [ ] **Step 3: Run the full suite**

Run: `zig build test-full`
Expected: PASS, exit 0. The three new tests run on this Linux host (the `!= .windows` guard keeps `openVirtual`, which only exists on the posix backend, out of a Windows build).

- [ ] **Step 4: Commit**

```bash
git add src/platform/pty_virtual_test.zig src/test_main.zig
git commit -m "test(tmux): virtual PTY round-trip + setSize no-op coverage"
```

---

## Phase 3a Done — What Ships

`Pty.openVirtual` — a socketpair-backed `Pty` indistinguishable from a real one to `readOutput`/`writeInput`/`outputAvailable`/`cancelOutputRead`/`getSize`, with `setSize` a safe no-op, plus the `controller_fd` for the other end. Tested for both directions, sizing, and readable-byte counting. No consumer yet — Phase 3b connects it to `Surface` and the `Session` sink.

## Remaining Phase 3 (separate plans — study required before writing)

These are **not** placeholder tasks; they are deliberately deferred because writing them to the no-placeholder bar requires reading the large files they modify. Each becomes its own plan.

- **3b — Pane as Surface.** Study `Surface.zig` (`init`, `pty`/`command` setup, `io_reader_thread`/writer thread spawn, `queuePtyWrite`) and `Command.zig`/`platform/pty_command.zig`. Add a `Surface` construction path that takes a virtual `Pty` (skipping `startCommand`/with a `Command` whose `wait()` reports "still running"), and a small reader on `controller_fd` that turns pane keystrokes into `Session.sendKeys`. Back `PaneSink.writeFn` with `pair.controller_fd` writes.
- **3c — Layout/tab reconcile.** Study `split_tree.zig` (the `SplitTree`/`Handle` API, split/insert/remove, the `surfaceFromSnap` factory pattern) and `appwindow/tab.zig` (tab create/close/title). Implement `split_tree.reconcileFromTmuxLayout(layout.Node)` (minimal add/remove/move against the current tree) and window→tab create/rename/close from `Session` events.
- **3d — Connection + bootstrap.** Study the SSH launch path (`platform/pty_command.sshInteractiveCommand`, `appwindow/tab.zig` spawn) and `AppWindow` threading. Launch `ssh -tt host -- tmux -CC new -A -s <name>`, run the controller read-loop feeding `Session.feed`, drain `Session.pendingCommands()` to the tmux pipe, and wire `capture-pane` history seeding + `refresh-client -C` on resize + `list-windows` reply parsing.

---

## Self-Review

**1. Spec coverage (Phase 3a slice):** The spec's `platform/pty.zig (+ pty_posix.zig …)` row ("virtual `Pty` backend … POSIX: one end of a `socketpair`; same method surface; `startCommand` is a no-op") is implemented except `startCommand`, which is explicitly deferred to 3b with rationale (it needs the no-child `Command` lifecycle, a Surface-integration concern). The Windows half of that spec row is deferred (the `!= .windows` guard; tmux is unix-only and the Phase-3a consumer doesn't exist on Windows yet). All other spec requirements belong to 3b–3d, enumerated in the roadmap — no silent gaps.

**2. Placeholder scan:** No `TBD`/`TODO`/"handle errors"/"similar to" in the executable tasks. Every step is a complete edit with exact anchor text and full code. The "Remaining Phase 3" section is explicitly a roadmap of future plans, not tasks — it contains no checkboxes and claims no completeness.

**3. Type consistency:** `is_virtual` (Task 1 Step 2) is set in `open` (Step 3), `openVirtual` (Step 4), and read in `setSize` (Step 5). `VirtualPair{pty, controller_fd}` defined in Step 4 and consumed by every test in Task 2 as `pair.pty` / `pair.controller_fd`. `openVirtual`/`getSize`/`readOutput`/`writeInput`/`outputAvailable`/`setSize`/`deinit` signatures match the existing `Pty` API exactly. `fd_t`, `c.close`, `SLAVE_PATH_MAX`, `std.posix.pipe`, `std.posix.AF.UNIX`, `std.posix.SOCK.STREAM` are all already in scope in `pty_posix.zig`. The facade `pty.zig` re-exports `Pty` (so `pty.Pty.openVirtual` resolves), and `VirtualPair` is reached by type inference on the call result — no separate export needed.
