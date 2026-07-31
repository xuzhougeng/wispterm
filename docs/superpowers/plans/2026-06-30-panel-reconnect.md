# Panel Reconnect / Re-run on Exit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user press Enter in a panel whose process has exited (SSH closed, shell `exit`) to re-run that panel's original command in place, keeping scrollback.

**Architecture:** Store the panel's launch command+cwd on the `Surface` at init. On exit the panel already stays open and prints `[WispTerm] Process exited…`; we append `Press Enter to reconnect.` and intercept plain Enter in the key path to call a new `Surface.respawn()`. `respawn()` tears down the dead IO subsystem (both IO threads, mailbox, thread-state, pty, command) and brings up a fresh one transactionally — acquire the new resources into locals first, swap only on success — while retaining the `terminal` (scrollback) and `vt_stream`.

**Tech Stack:** Zig, ghostty-vt, the repo's two-thread (reader+writer) per-surface IO model.

## Global Constraints

- **Cross-platform compile.** Default `zig build` targets Windows; ALL code and tests must compile for Windows too. `CommandLine`/`Cwd` are `[:0]const u8`/`?[*:0]const u8` on POSIX and `[:0]const u16`/`?[*:0]const u16` on Windows — never assume `u8`. Build cross-platform `CommandLine` values in tests via `platform_pty_command.allocCommandLineFromUtf8`, never a bare `"..."` literal.
- **Run native tests on macOS.** `Surface` tests live in the app test binary; bare `zig build test-full` only compile-checks it. Use `zig build test-full -Dtarget=aarch64-macos` to actually RUN them. The `skill center tool import` test is known-flaky (FileNotFound) and unrelated.
- **UI copy style.** Terminal status messages use the existing `\r\n[WispTerm] … \r\n` form; keep it.
- **No double-free.** Tearing a resource down twice corrupts the heap (issue #65). `respawn()` must leave every field deinit-safe on every failure path.

## File Structure

- `src/Surface.zig` — add `respawn_command`/`respawn_cwd` fields + `setRespawnTarget`/`freeRespawnTarget` helpers; wire into `init`/`finishInit`/`deinit`; extract `formatIoStatusMessage` from `paintIoStatus` and add the reconnect hint; add `isExited` + `respawn` + `respawnFailed`.
- `src/input.zig` — intercept plain Enter on an exited focused surface in `dispatchKey` and call `respawn()`.

All work is in these two files. Tests are added inline in `src/Surface.zig` (alongside the existing `ioStateHarness`-style tests).

---

### Task 1: Store the panel's launch command + cwd on `Surface`

**Files:**
- Modify: `src/Surface.zig` (core-state fields ~245; `init` 466–469; `finishInit` ~489; `deinit` ~702–705; new helpers + test)

**Interfaces:**
- Produces:
  - Fields `respawn_command: ?platform_pty_command.OwnedCommandLine = null`, `respawn_cwd: ?platform_pty_command.OwnedCwd = null`.
  - `fn setRespawnTarget(self: *Surface, allocator: std.mem.Allocator, cmd: platform_pty_command.CommandLine, cwd: platform_pty_command.Cwd) void`
  - `fn freeRespawnTarget(self: *Surface, allocator: std.mem.Allocator) void`
- Consumes: `platform_pty_command` (already imported at `Surface.zig:26`): `OwnedCommandLine`, `OwnedCwd`, `CwdUnit`, `CommandLine`, `Cwd`, `freeCommandLine`, `freeCwd`, `allocCommandLineFromUtf8`, `commandLineFromOwned`, `commandLineDisplay`.

- [ ] **Step 1: Write the failing test**

Add at the end of `src/Surface.zig` (after the last test, ~line 1851):

```zig
test "Surface respawn target stores command and frees it without leaking" {
    var surface: Surface = undefined;
    surface.respawn_command = null;
    surface.respawn_cwd = null;

    // Build a platform CommandLine from utf8 so this compiles on Windows too.
    const owned = try platform_pty_command.allocCommandLineFromUtf8(
        std.testing.allocator,
        "ssh demo@host",
    );
    defer platform_pty_command.freeCommandLine(std.testing.allocator, owned);
    const cmd = platform_pty_command.commandLineFromOwned(owned);

    surface.setRespawnTarget(std.testing.allocator, cmd, null);
    try std.testing.expect(surface.respawn_command != null);
    try std.testing.expect(surface.respawn_cwd == null);

    var disp: [64]u8 = undefined;
    const got = platform_pty_command.commandLineDisplay(
        platform_pty_command.commandLineFromOwned(surface.respawn_command.?),
        &disp,
    );
    try std.testing.expectEqualStrings("ssh demo@host", got);

    // testing.allocator fails the test if freeRespawnTarget leaks or
    // double-frees.
    surface.freeRespawnTarget(std.testing.allocator);
    try std.testing.expect(surface.respawn_command == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | grep -A3 "respawn target stores"`
Expected: FAIL/compile error — `respawn_command`/`setRespawnTarget`/`freeRespawnTarget` don't exist yet.

- [ ] **Step 3: Add the fields**

In the core-state block of `src/Surface.zig`, right after the `remote_id: [16]u8,` field (~line 245):

```zig
remote_id: [16]u8,

/// The command + cwd this surface was launched with, owned copies kept so the
/// panel can be re-run in place after its process exits (Enter-to-reconnect).
/// Null for virtual/tmux panes (no child) and if the dup ever fails.
respawn_command: ?platform_pty_command.OwnedCommandLine = null,
respawn_cwd: ?platform_pty_command.OwnedCwd = null,
```

- [ ] **Step 4: Add the helpers**

Add after `captureInitialCwd` (~line 1175 in `src/Surface.zig`):

```zig
/// Store owned copies of the launch command/cwd for Enter-to-reconnect.
/// `CommandLine`/`Cwd` are platform-native (`u8` POSIX / `u16` Windows); we
/// dup with the element unit so this is cross-platform. Best-effort: on dup
/// failure the field stays null and reconnect is simply unavailable.
fn setRespawnTarget(
    self: *Surface,
    allocator: std.mem.Allocator,
    cmd: platform_pty_command.CommandLine,
    cwd: platform_pty_command.Cwd,
) void {
    const CmdUnit = std.meta.Child(platform_pty_command.CommandLine);
    self.respawn_command = allocator.dupeZ(CmdUnit, cmd) catch null;
    self.respawn_cwd = if (cwd) |c|
        (allocator.dupeZ(platform_pty_command.CwdUnit, std.mem.span(c)) catch null)
    else
        null;
}

fn freeRespawnTarget(self: *Surface, allocator: std.mem.Allocator) void {
    if (self.respawn_command) |c| platform_pty_command.freeCommandLine(allocator, c);
    if (self.respawn_cwd) |c| platform_pty_command.freeCwd(allocator, c);
    self.respawn_command = null;
    self.respawn_cwd = null;
}
```

- [ ] **Step 5: Initialize the fields in `finishInit` (so the virtual path is null)**

In `finishInit`, next to the other null-defaults (after `surface.ssh_connection = null;`, ~line 489):

```zig
    surface.ssh_connection = null;
    surface.respawn_command = null;
    surface.respawn_cwd = null;
```

- [ ] **Step 6: Populate the fields in `init` (real-child path only)**

Change the tail of `init` (line 469) from:

```zig
    return finishInit(surface, allocator, cols, rows, platform_pty_command.launchKindForCommand(shell_cmd), cwd);
```

to:

```zig
    const ready = try finishInit(surface, allocator, cols, rows, platform_pty_command.launchKindForCommand(shell_cmd), cwd);
    ready.setRespawnTarget(allocator, shell_cmd, cwd);
    return ready;
```

- [ ] **Step 7: Free the fields in `deinit`**

In `deinit`, in the "safe to tear down" section, right after the clipboard-pending free (~line 705, before `self.wispterm_image_osc_buf.deinit(allocator);`):

```zig
    self.freeRespawnTarget(allocator);
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | grep -A3 "respawn target stores"`
Expected: PASS (no leak reported).

- [ ] **Step 9: Commit**

```bash
git add src/Surface.zig
git commit -m "feat(surface): store launch command/cwd for reconnect"
```

---

### Task 2: Append "Press Enter to reconnect." to the exit message

**Files:**
- Modify: `src/Surface.zig` (`paintIoStatus` 869–899; new `formatIoStatusMessage` + test)

**Interfaces:**
- Produces: `fn formatIoStatusMessage(buf: []u8, state: IoState, show_reconnect_hint: bool) ?[]const u8` — pure formatter returning the status string or null for non-terminal states.
- Consumes: `respawn_command` field from Task 1 (gates the hint).

- [ ] **Step 1: Write the failing test**

Add at the end of `src/Surface.zig`:

```zig
test "exit status message shows the reconnect hint only when asked" {
    var buf: [256]u8 = undefined;
    const state: IoState = .{ .exited = .{
        .reason = .eof,
        .status = .{ .exited = 0 },
        .timestamp_ms = 0,
    } };

    const with_hint = formatIoStatusMessage(&buf, state, true).?;
    try std.testing.expect(std.mem.indexOf(u8, with_hint, "Process exited with code 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_hint, "Press Enter to reconnect") != null);

    var buf2: [256]u8 = undefined;
    const no_hint = formatIoStatusMessage(&buf2, state, false).?;
    try std.testing.expect(std.mem.indexOf(u8, no_hint, "Press Enter to reconnect") == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | grep -A3 "reconnect hint only"`
Expected: FAIL/compile error — `formatIoStatusMessage` doesn't exist.

- [ ] **Step 3: Extract the formatter**

Add immediately above `paintIoStatus` (~line 869) in `src/Surface.zig`:

```zig
/// Build the terminal status line printed when IO ends. Pure (no terminal
/// access) so it is unit-testable. `show_reconnect_hint` appends the
/// Enter-to-reconnect prompt to a normal exit message.
fn formatIoStatusMessage(buf: []u8, state: IoState, show_reconnect_hint: bool) ?[]const u8 {
    const hint = if (show_reconnect_hint) " Press Enter to reconnect." else "";
    return switch (state) {
        .failed => |failure| std.fmt.bufPrint(
            buf,
            "\r\n[WispTerm] Terminal IO failed during {s}: {s}\r\n",
            .{ @tagName(failure.operation), @errorName(failure.error_code) },
        ) catch null,
        .exited => |info| exited: {
            if (info.status) |status| switch (status) {
                .exited => |code| break :exited std.fmt.bufPrint(
                    buf,
                    "\r\n[WispTerm] Process exited with code {d}.{s}\r\n",
                    .{ code, hint },
                ) catch null,
                .unknown => {},
            };
            break :exited std.fmt.bufPrint(
                buf,
                "\r\n[WispTerm] Process exited.{s}\r\n",
                .{hint},
            ) catch null;
        },
        else => null,
    };
}
```

- [ ] **Step 4: Call the formatter from `paintIoStatus`**

Replace the message-building block inside `paintIoStatus` (the `var buf` + `const message = switch (state) {…}` at lines 873–892) with:

```zig
    var buf: [256]u8 = undefined;
    // Only a panel with a stored command can actually reconnect (virtual/tmux
    // panes and dup failures leave respawn_command null), so gate the hint.
    const message = formatIoStatusMessage(&buf, state, self.respawn_command != null) orelse return;
```

(Leave the `self.terminal.printString(message)` / `clearSynchronizedOutputLocked()` tail unchanged.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | grep -A3 "reconnect hint only"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/Surface.zig
git commit -m "feat(surface): show reconnect hint on the exit message"
```

---

### Task 3: `Surface.respawn()` — tear down the dead IO subsystem and bring up a fresh one

**Files:**
- Modify: `src/Surface.zig` (new `isExited`, `respawn`, `respawnFailed` after `paintIoStatus` ~line 900; new guard test)

**Interfaces:**
- Consumes: `respawn_command`/`respawn_cwd` (Task 1); `currentIoState`/`setIoRunning`/`failIo`/`clearSynchronizedOutputLocked`; `Pty.open`, `Command.start`, `termio.Mailbox.init`, `termio.Thread.init/threadMain`, `termio.ReadThread.threadMain`, `threading.surface_thread_spawn_config`, `self.terminal.resize`.
- Produces:
  - `pub fn isExited(self: *Surface) bool`
  - `pub fn respawn(self: *Surface) void`

- [ ] **Step 1: Write the failing test (guards only; the live fork path is E2E)**

Add at the end of `src/Surface.zig`. `ioStateHarness` (defined ~line 1783) builds a Surface with `io_thread_state`/threads null, so the guard paths never touch real IO:

```zig
test "respawn is a no-op unless the surface has exited with a stored command" {
    var surface: Surface = undefined;
    try ioStateHarness(&surface);
    defer ioStateHarnessDeinit(&surface);
    surface.respawn_command = null;
    surface.respawn_cwd = null;

    // .running (harness default): guard returns immediately, state unchanged.
    try std.testing.expect(!surface.isExited());
    surface.respawn();
    try std.testing.expect(surface.acceptsInput());

    // .exited but no stored command: returns at the command guard, before any
    // pty/thread work (which would crash on the null-threaded harness).
    surface.markExited(.eof, .{ .exited = 0 });
    try std.testing.expect(surface.isExited());
    surface.respawn();
    try std.testing.expect(surface.isExited());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | grep -A3 "respawn is a no-op"`
Expected: FAIL/compile error — `isExited`/`respawn` don't exist.

- [ ] **Step 3: Add `isExited`**

Add next to `acceptsInput` (~line 764) in `src/Surface.zig`:

```zig
pub fn isExited(self: *Surface) bool {
    return switch (self.currentIoState()) {
        .exited => true,
        else => false,
    };
}
```

- [ ] **Step 4: Add `respawn` + `respawnFailed`**

Add after `paintIoStatus` (~line 900) in `src/Surface.zig`:

```zig
/// Re-run this panel's original command in place after its process exited
/// (Enter-to-reconnect). Keeps the terminal/scrollback; replaces the whole IO
/// subsystem. Main-thread only (spawns threads, touches the mailbox). No-op
/// unless the panel has cleanly exited and has a stored command.
pub fn respawn(self: *Surface) void {
    switch (self.currentIoState()) {
        .exited => {},
        else => return,
    }
    const owned_cmd = self.respawn_command orelse {
        io_log.warn("respawn requested but no stored command", .{});
        return;
    };
    const cmd = platform_pty_command.commandLineFromOwned(owned_cmd);
    const cwd: platform_pty_command.Cwd =
        if (self.respawn_cwd) |c| platform_pty_command.cwdFromOwned(c) else null;
    const cols = self.size.grid.cols;
    const rows = self.size.grid.rows;

    // Both IO threads already returned (reader on EOF, writer on the stop
    // notify markExited sent) but were never joined. Collect them before
    // anything new starts.
    if (self.io_thread_state) |state| state.stop.notify() catch {};
    self.pty.cancelOutputRead();
    if (self.io_writer_thread) |t| {
        t.join();
        self.io_writer_thread = null;
    }
    if (self.io_reader_thread) |t| {
        t.join();
        self.io_reader_thread = null;
    }

    // Acquire the new IO subsystem into locals FIRST. On any failure the OLD
    // pty/command/mailbox/thread_state are still the surface's fields and stay
    // deinit-safe — we just report failure and the old "exited" state holds.
    var new_pty = Pty.open(.{ .ws_col = cols, .ws_row = rows }) catch |err|
        return self.respawnFailed(err);
    var new_command: Command = .{};
    new_command.start(&new_pty, cmd, cwd) catch |err| {
        new_pty.deinit();
        return self.respawnFailed(err);
    };
    var new_mailbox = termio.Mailbox.init() catch |err| {
        new_command.deinit();
        new_pty.deinit();
        return self.respawnFailed(err);
    };
    const new_state = self.allocator.create(termio.Thread) catch |err| {
        new_mailbox.deinit();
        new_command.deinit();
        new_pty.deinit();
        return self.respawnFailed(err);
    };
    new_state.* = termio.Thread.init() catch |err| {
        self.allocator.destroy(new_state);
        new_mailbox.deinit();
        new_command.deinit();
        new_pty.deinit();
        return self.respawnFailed(err);
    };

    // Commit: tear down the OLD subsystem, swap in the new one.
    if (self.io_thread_state) |state| {
        state.deinit();
        self.allocator.destroy(state);
    }
    self.mailbox.deinit();
    self.command.deinit();
    self.pty.deinit();
    self.pty = new_pty;
    self.command = new_command;
    self.mailbox = new_mailbox;
    self.io_thread_state = new_state;

    // Sync the retained grid to the (possibly resized-while-exited) pane size
    // and drop a separator into the existing scrollback.
    {
        self.render_state.mutex.lock();
        defer self.render_state.mutex.unlock();
        self.terminal.resize(self.allocator, cols, rows) catch {};
        self.terminal.printString("\r\n[WispTerm] Reconnecting...\r\n") catch {};
        self.clearSynchronizedOutputLocked();
    }

    // The reader loops on `!exited`; clear it and reset lifecycle BEFORE spawn.
    self.exited.store(false, .release);
    self.io_state_mutex.lock();
    self.io_state = .starting;
    self.io_state_mutex.unlock();

    // ponytail: thread-spawn failure after the swap marks the surface failed
    // with the NEW resources owned (still deinit-safe); we don't unwind the
    // swap. Same residual exposure finishInit already has. Make spawn pre-swap
    // only if this ever actually bites.
    self.io_writer_thread = std.Thread.spawn(
        threading.surface_thread_spawn_config,
        termio.Thread.threadMain,
        .{ new_state, self },
    ) catch |err| {
        self.failIo(.thread_spawn, err);
        return;
    };
    self.io_reader_thread = std.Thread.spawn(
        threading.surface_thread_spawn_config,
        termio.ReadThread.threadMain,
        .{self},
    ) catch |err| {
        self.failIo(.thread_spawn, err);
        return;
    };

    self.setIoRunning();
    self.dirty.store(true, .release);
    window_backend.postWakeup();
}

/// Reconnect could not open a fresh PTY/command. The old (exited) resources are
/// untouched and remain owned by the surface; surface a failure message.
fn respawnFailed(self: *Surface, err: anyerror) void {
    io_log.warn("respawn failed: {s}", .{@errorName(err)});
    self.failIo(.thread_spawn, err);
}
```

- [ ] **Step 5: Run the guard test to verify it passes**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | grep -A3 "respawn is a no-op"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/Surface.zig
git commit -m "feat(surface): add in-place respawn for an exited panel"
```

---

### Task 4: Intercept plain Enter on an exited panel and reconnect

**Files:**
- Modify: `src/input.zig` (`dispatchKey`, right after the focused-surface bind at line 3516)

**Interfaces:**
- Consumes: `Surface.isExited`, `Surface.respawn` (Task 3); `platform_input.key_enter` (`= 0x0D`); `input_effects.repaint()`; `AppWindow.activeSurface()`.

- [ ] **Step 1: Add the interception**

In `src/input.zig`, immediately after line 3516 (`const surface = AppWindow.activeSurface() orelse return .none;`) and before the `var wrote_to_pty = false;` comment block, insert:

```zig
    // A cleanly-exited panel (SSH closed, shell `exit`) stays open showing
    // "Press Enter to reconnect". Plain Enter re-runs the panel's original
    // command in place. Other keys fall through, so e.g. Shift+PageUp still
    // scrolls the scrollback before reconnecting.
    if (surface.isExited() and
        ev.key_code == platform_input.key_enter and
        !ev.ctrl and !ev.alt and !ev.super and !ev.shift)
    {
        surface.respawn();
        return input_effects.repaint();
    }
```

- [ ] **Step 2: Build the app test binary to verify it compiles (both default + macOS)**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | tail -5`
Expected: builds; all new tests pass (ignore the known-flaky `skill center tool import`).
Run: `zig build 2>&1 | tail -5`
Expected: the default (Windows) target still compiles — confirms cross-platform.

- [ ] **Step 3: Commit**

```bash
git add src/input.zig
git commit -m "feat(input): reconnect an exited panel on Enter"
```

- [ ] **Step 4: Manual E2E (the live fork/rebuild path, not covered by unit tests)**

```bash
zig build macos-app
```

Then, in the launched app:
1. Open a panel and run a short-lived remote-ish command, e.g. `ssh -o ConnectTimeout=2 localhost` then exit it, OR simply `sleep 1; exit` in the shell, OR `cat` then Ctrl-D.
2. Confirm the panel stays open and the last line reads `… Press Enter to reconnect.`
3. Press **Enter**. Expect a `[WispTerm] Reconnecting...` line, then the original command runs again in the SAME panel with prior scrollback retained above.
4. Scroll up with **Shift+PageUp** while exited — confirm it still scrolls (not swallowed).
5. Let it exit again and reconnect a second time — confirm the loop works.

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-06-30-panel-reconnect-design.md`):
- ① store command+cwd → Task 1. ② respawn rebuilds IO (reader+writer+mailbox+thread_state, not just reader — corrected from the spec's simplification) → Task 3. ③ exit-message hint → Task 2. ④ Enter interception, other keys fall through → Task 4. Keep scrollback / no clear → Task 3 retains `terminal`, prints a separator only. Reconnect-failure retry loop → a failed child re-enters `.exited` and re-prompts (Task 3 + Task 2). YAGNI items (no auto-reconnect, no keybind, no env recapture) → not implemented, as specified.

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `respawn_command: ?OwnedCommandLine` / `respawn_cwd: ?OwnedCwd` used identically in Task 1 (store/free), Task 2 (`!= null` gate), Task 3 (`commandLineFromOwned`/`cwdFromOwned`). `isExited`/`respawn`/`formatIoStatusMessage`/`setRespawnTarget`/`freeRespawnTarget` signatures match across definition and call sites. `formatIoStatusMessage`'s `.failed` arm intentionally omits the hint (a hard IO failure is not the Enter-reconnect path).
