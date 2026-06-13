# tmux Agent-Awareness + Feature Parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tmux-backed panes first-class — WispTerm's ctrl+click preview & copy-to-agent work inside them, and each pane shows AI-agent state (idle/working/blocked/done), Claude Code first.

**Architecture:** Two independent phases layered on the working tmux `-CC` integration. Phase A fills metadata gaps on tmux-pane surfaces (`ssh_connection`, per-pane `cwd_path`) so existing features route correctly. Phase B adds a per-`Surface` agent-state field fed by a private `OSC 7748` marker (Claude Code hooks emit it) plus a heuristic fallback, surfaced as a UI dot. Both ride the "every tmux pane is a real `Surface`" invariant — no new render/IO paths.

**Tech Stack:** Zig; ghostty-vt; existing `tmux.Session`/`TmuxBridge`/`PaneMap`; `std.json`. Tests: `zig build test` (fast, pure modules via `src/test_fast.zig`), `zig build test-full` (app binary via `src/test_main.zig`).

**Spec:** `docs/superpowers/specs/2026-06-13-tmux-agent-aware-and-feature-parity-design.md`

**Phase independence:** A and B share only the per-pane `pane_current_path`/`pane_current_command` fetch (built once in Phase A, Task A1–A2). A can merge alone; B depends on A1–A2 + A's threading but is otherwise separable.

**Conventions in this codebase:**
- Pure, Surface-free modules are unit-tested in the fast suite; reconcile/render edits are compile-checked + GUI-verified (see `src/appwindow/tmux_bridge.zig` header).
- Register a new pure module for tests by adding `_ = @import("<name>.zig");` to `src/test_fast.zig`.
- `SshConnection` (`src/ssh_connection.zig:6`) is a fixed-buffer value type with accessor methods (`user()`, `host()`, `port()`, `proxyJump()`, `password()`).
- Commit after each task. Run the fast suite (`zig build test`) on pure changes; run `zig build test-full` before finishing each phase.

---

## File Structure

**Phase A (feature parity):**
- Modify `src/tmux/session.zig` — parse a `list-panes` metadata reply; new `onPaneMeta` event.
- Modify `src/ssh_connection.zig` — add `fromParts` constructor (pure, tested).
- Modify `src/renderer/overlays.zig:2567` — pass SSH params into `startTmuxSession`.
- Modify `src/AppWindow.zig:1695` (`startTmuxSession`) — forward params.
- Modify `src/appwindow/tmux_controller_posix.zig` + `tmux_controller_windows.zig` (`start`) — store params on the controller; build one shared `SshConnection`.
- Modify `src/appwindow/tmux_bridge.zig` — factory attaches `ssh_connection` + `launch_kind`; `onPaneMeta` sets `cwd_path`.
- Modify `src/Surface.zig` — add `setCwdPath` setter.

**Phase B (agent awareness):**
- Create `src/agent_state.zig` (pure) — enums + marker/sentinel parsing + kind-from-command + tab aggregation.
- Create `src/claude_integration.zig` (pure) — Claude Code hooks config generate/merge/remove.
- Modify `src/Surface.zig` — `agent_kind`/`agent_state` fields; recognize `OSC 7748`.
- Modify `src/appwindow/tmux_bridge.zig` — `onPaneMeta` command → `agent_kind`.
- Modify `src/renderer/overlays.zig` (or the tab/pane chrome renderer) — draw the state dot.
- Modify `src/test_fast.zig` — register the two new pure modules.

---

# PHASE A — Feature parity inside tmux panes

### Task A1: Parse per-pane metadata (`list-panes`) in the Session

**Files:**
- Modify: `src/tmux/session.zig`
- Test: in `src/tmux/session.zig` (module has inline tests + an `EventLog` test sink)

- [ ] **Step 1: Read the existing reply-parsing + EventSink pattern**

Read `src/tmux/session.zig`: the `EventSink` struct (`onLayoutChange`/`onWindowRenamed`/`onWindowClose`/`onActiveWindowChanged`/`onActivePaneChanged` + their `no*` defaults), `applyWindowList` (a `%begin … %end` body parser), the `block_end` handler that decides whether a reply body is a window-list, and the `EventLog` test sink at the bottom. Task A1 adds a sibling event + a sibling body parser.

- [ ] **Step 2: Write the failing test**

Add to the tests at the bottom of `src/tmux/session.zig`:

```zig
test "list-panes reply drives onPaneMeta per pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    // Reply to: list-panes -s -F "#{pane_id}\t#{pane_current_path}\t#{pane_current_command}"
    try s.feed(
        "%begin 9 9 0\n" ++
            "%1\t/home/u/proj\tnvim\n" ++
            "%2\t/var/log\ttail\n" ++
            "%end 9 9 0\n",
    );

    try std.testing.expectEqual(@as(usize, 2), log.pane_meta_count);
    try std.testing.expectEqual(@as(?usize, 2), log.last_pane_meta_id);
    try std.testing.expectEqualStrings("/var/log", log.last_pane_meta_path.items);
    try std.testing.expectEqualStrings("tail", log.last_pane_meta_cmd.items);
}
```

Extend the `EventLog` test sink (bottom of file) to capture it:

```zig
    // add fields to EventLog:
    pane_meta_count: usize = 0,
    last_pane_meta_id: ?usize = null,
    last_pane_meta_path: std.ArrayListUnmanaged(u8) = .empty,
    last_pane_meta_cmd: std.ArrayListUnmanaged(u8) = .empty,

    // in EventLog.deinit add:
    //   self.last_pane_meta_path.deinit(self.alloc);
    //   self.last_pane_meta_cmd.deinit(self.alloc);

    // in eventSink() add: .onPaneMeta = onPaneMeta,

    fn onPaneMeta(ctx: *anyopaque, pane_id: usize, path: []const u8, cmd: []const u8) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.pane_meta_count += 1;
        self.last_pane_meta_id = pane_id;
        self.last_pane_meta_path.clearRetainingCapacity();
        self.last_pane_meta_path.appendSlice(self.alloc, path) catch {};
        self.last_pane_meta_cmd.clearRetainingCapacity();
        self.last_pane_meta_cmd.appendSlice(self.alloc, cmd) catch {};
    }
```

- [ ] **Step 3: Run the test, verify it fails to compile/parse**

Run: `zig build test 2>&1 | grep -A3 onPaneMeta`
Expected: FAIL — `onPaneMeta` not a field of `EventSink`; `applyPaneList` undefined.

- [ ] **Step 4: Add the event + body parser + bridge dispatch**

In `EventSink` (session.zig) add the field + default:

```zig
        onPaneMeta: *const fn (ctx: *anyopaque, pane_id: usize, path: []const u8, cmd: []const u8) void = noPaneMeta,
        // ... with the other no* fns:
        fn noPaneMeta(_: *anyopaque, _: usize, _: []const u8, _: []const u8) void {}
```

Add a body parser sibling to `applyWindowList`:

```zig
    /// Parse a `list-panes -s -F "#{pane_id}\t#{pane_current_path}\t#{pane_current_command}"`
    /// reply body. Each line: `%<id>\t<path>\t<cmd>`. Emits onPaneMeta per line.
    /// Returns true if at least one line applied (lets block_end tell it apart).
    fn applyPaneList(self: *Session, body: []const u8) bool {
        var applied = false;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len < 2 or line[0] != '%') continue;
            const t1 = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const id = std.fmt.parseInt(usize, line[1..t1], 10) catch continue;
            const rest = line[t1 + 1 ..];
            const t2 = std.mem.indexOfScalar(u8, rest, '\t') orelse continue;
            const path = rest[0..t2];
            const cmd = rest[t2 + 1 ..];
            self.events.onPaneMeta(self.events.ctx, id, path, cmd);
            applied = true;
        }
        return applied;
    }
```

Wire it into the `block_end` handler **after** the window-list attempt (mirror how `applyWindowList`'s result gates the capture-pane fallback): if `applyWindowList` returned false, try `applyPaneList`; if it applied, the reply is consumed (do not also route it to a capture sink). Match the exact control flow you read in Step 1.

- [ ] **Step 5: Run the test, verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (all session tests green).

- [ ] **Step 6: Commit**

```bash
git add src/tmux/session.zig
git commit -m "feat(tmux): parse list-panes metadata -> onPaneMeta (path + command)"
```

---

### Task A2: Enqueue the `list-panes` metadata query

**Files:**
- Modify: `src/tmux/session.zig` (`start` + a public `refreshPaneMeta`)
- Test: inline

- [ ] **Step 1: Write the failing test**

```zig
test "start enqueues a list-panes metadata query" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    try s.start();
    try std.testing.expect(std.mem.indexOf(u8, s.cmds.items, "list-panes -s -F") != null);
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `zig build test 2>&1 | grep -A2 "list-panes -s"`
Expected: FAIL (assertion: substring not found).

- [ ] **Step 3: Implement**

In `Session.start` (after the existing `list-windows` enqueue) append:

```zig
    try self.cmds.appendSlice(self.alloc, "list-panes -s -F \"#{pane_id}\t#{pane_current_path}\t#{pane_current_command}\"\n");
```

Add a public method to re-query (called from the controller tick on a cadence — wired in A4):

```zig
    pub fn refreshPaneMeta(self: *Session) Allocator.Error!void {
        try self.cmds.appendSlice(self.alloc, "list-panes -s -F \"#{pane_id}\t#{pane_current_path}\t#{pane_current_command}\"\n");
    }
```

- [ ] **Step 4: Run it, verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/session.zig
git commit -m "feat(tmux): enqueue list-panes metadata on start + refreshPaneMeta()"
```

---

### Task A3: `SshConnection.fromParts` constructor

**Files:**
- Modify: `src/ssh_connection.zig`
- Test: inline

- [ ] **Step 1: Write the failing test**

Add at the bottom of `src/ssh_connection.zig`:

```zig
test "fromParts copies fields into the fixed buffers" {
    const c = SshConnection.fromParts(.{
        .user = "alice",
        .host = "10.0.0.5",
        .port = "2222",
        .proxy_jump = "jump.example",
    });
    try std.testing.expectEqualStrings("alice", c.user());
    try std.testing.expectEqualStrings("10.0.0.5", c.host());
    try std.testing.expectEqualStrings("2222", c.port());
    try std.testing.expectEqualStrings("jump.example", c.proxyJump());
}
```

(If `src/ssh_connection.zig` has no `test` blocks yet, also add `const std = @import("std");` if not already imported, and ensure the file is reached by the test suite — `Surface.zig` imports it and is in `test_main.zig`, so `test-full` covers it; for the fast suite add `_ = @import("ssh_connection.zig");` to `src/test_fast.zig`.)

- [ ] **Step 2: Run it, verify it fails**

Run: `zig build test 2>&1 | grep -A2 fromParts`
Expected: FAIL — `fromParts` undefined.

- [ ] **Step 3: Implement**

Add to the `SshConnection` struct (read the exact field names first — `user_buf`/`user_len`/`host_buf`/`host_len`/`port_buf`/`port_len`/`proxy_jump_buf`/`proxy_jump_len`):

```zig
    pub const Parts = struct {
        user: []const u8,
        host: []const u8,
        port: []const u8 = "",
        proxy_jump: []const u8 = "",
    };

    /// Build a connection from already-validated SSH params (caller validated
    /// with isSshTokenSafe/isPortTokenSafe). Truncates to buffer capacity.
    pub fn fromParts(p: Parts) SshConnection {
        var c: SshConnection = .{};
        c.user_len = copyInto(&c.user_buf, p.user);
        c.host_len = copyInto(&c.host_buf, p.host);
        c.port_len = copyInto(&c.port_buf, p.port);
        c.proxy_jump_len = copyInto(&c.proxy_jump_buf, p.proxy_jump);
        return c;
    }

    fn copyInto(buf: []u8, src: []const u8) usize {
        const n = @min(buf.len, src.len);
        @memcpy(buf[0..n], src[0..n]);
        return n;
    }
```

(Confirm the `proxy_jump_len` field name exists; if the struct only declares `proxy_jump_buf`, add the matching `proxy_jump_len: usize = 0` field used by the existing `proxyJump()` accessor.)

- [ ] **Step 4: Run it, verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ssh_connection.zig src/test_fast.zig
git commit -m "feat(ssh): SshConnection.fromParts constructor"
```

---

### Task A4: Thread SSH params from launcher → controller → bridge

**Files:**
- Modify: `src/renderer/overlays.zig:2567` (`connectSshProfileTmux`)
- Modify: `src/AppWindow.zig:1695` (`startTmuxSession`)
- Modify: `src/appwindow/tmux_controller_posix.zig` + `tmux_controller_windows.zig` (`start`, struct fields)
- Modify: `src/appwindow/tmux_bridge.zig` (`TmuxBridge.create` gains the connection)

This task is compile-checked + GUI-verified (no pure unit). Keep each edit small; build between edits with `zig build 2>&1 | tail -20`.

- [ ] **Step 1: Define a params struct on the controller**

In `tmux_controller_posix.zig` add to `TmuxController`:

```zig
    /// SSH endpoint of this session, used to build each pane surface's
    /// ssh_connection for preview/copy-to-agent. Null when launched without a
    /// profile (preview-over-tmux disabled — documented).
    ssh_conn: ?@import("../ssh_connection.zig").SshConnection = null,
```

Mirror the same field in `tmux_controller_windows.zig`.

- [ ] **Step 2: Extend `start` signatures to accept the params**

`tmux_controller_*.zig` `start(...)` currently takes `(alloc, ssh_cmd_utf8, password?, profile_name, cols, rows, scrollback_limit, cursor_style, cursor_blink)` — read the exact list. Add a trailing optional:

```zig
    ssh_conn: ?@import("../ssh_connection.zig").SshConnection,
```

Store it on the controller (`self.* = .{ …, .ssh_conn = ssh_conn }`) and pass it into `TmuxBridge.create` (Step 4).

- [ ] **Step 3: Forward through `AppWindow.startTmuxSession`**

`src/AppWindow.zig:1695`:

```zig
pub fn startTmuxSession(ssh_cmd: []const u8, password: []const u8, profile_name: []const u8, ssh_conn: ?@import("ssh_connection.zig").SshConnection) bool {
    // ... existing body, forward ssh_conn into tmux_controller.start(...)
}
```

- [ ] **Step 4: Build the connection at the launcher and pass it**

`src/renderer/overlays.zig:2598` — `connectSshProfileTmux` already has `ip`/`user`/`port`/`proxy_jump` validated above. Build the connection and pass it:

```zig
    const ssh_conn = ssh_connection.SshConnection.fromParts(.{
        .user = user,
        .host = ip,
        .port = port,
        .proxy_jump = proxy_jump,
    });
    sessionLauncherClose();
    _ = AppWindow.startTmuxSession(cmd, password, name, ssh_conn);
```

(Add `const ssh_connection = @import("../ssh_connection.zig");` to the imports if absent. Also update `connectProfileByNameTmux` and the persisted-session re-attach path — search callers of `startTmuxSession`/`tmux_controller.start` and the `session_persist` re-attach — to pass a connection too: when re-attaching from a stored profile, rebuild it from the stored profile fields; if the stored session has no profile, pass `null`.)

- [ ] **Step 5: `TmuxBridge.create` stores the connection**

`src/appwindow/tmux_bridge.zig` — add `ssh_conn: ?SshConnection` to the struct and a `create` parameter; the controller passes its stored `self.ssh_conn`. (Add `const SshConnection = @import("../ssh_connection.zig").SshConnection;`.)

- [ ] **Step 6: Build the whole app**

Run: `zig build 2>&1 | tail -20`
Expected: builds clean (no behavior change yet — the connection is stored but unused until A5).

- [ ] **Step 7: Commit**

```bash
git add src/renderer/overlays.zig src/AppWindow.zig src/appwindow/tmux_controller_posix.zig src/appwindow/tmux_controller_windows.zig src/appwindow/tmux_bridge.zig
git commit -m "feat(tmux): thread SSH endpoint from launcher to bridge"
```

---

### Task A5: Attach `ssh_connection` + `launch_kind` to each pane surface

**Files:**
- Modify: `src/appwindow/tmux_bridge.zig` (`FactoryCtx.make`, lines ~135-181)
- Modify: `src/Surface.zig` (confirm/expose a setter for `ssh_connection` + `launch_kind`)

Compile-checked + GUI-verified.

- [ ] **Step 1: Confirm how a normal SSH surface gets `ssh_connection`/`launch_kind`**

Read `src/Surface.zig` around the `ssh_connection` field and `launch_kind` (and how `tab.zig` sets them for an SSH-launched surface). **IMPORTANT (confirmed during A4 review):** `surface.ssh_connection` is `?SshConnection` — a **by-value** field (~880B POD), NOT a pointer. So **copy the value** onto the surface; do NOT point it at `&bridge.ssh_conn`. A pointer would dangle: `TmuxBridge.destroy()` frees the bridge but deliberately does NOT free its pane surfaces (they're owned by their tabs/`SplitTree`s), so a surface can outlive the bridge (reachable via `forgetClosedTab` / shutdown). Copying sidesteps the lifetime question entirely — it's a one-time POD copy per pane, and the bridge's stored value never mutates after `create`.

- [ ] **Step 2: Set them in the factory after `Surface.initVirtual`**

In `FactoryCtx.make`, right after `surface.attachRemoteClient(tab.g_remote_client);` (tmux_bridge.zig:167):

```zig
            if (self.ssh_conn) |conn| {
                surface.ssh_connection = conn; // copy the POD value; field is ?SshConnection
                surface.launch_kind = .ssh;
            }
```

(`launch_kind`: read `src/input.zig:3310` `terminalPathClickAction` to confirm which `launch_kind` value selects the `.ssh`/remote branch, and use that exact tag. Confirm how a normal SSH-launched surface sets `ssh_connection`/`launch_kind` in `tab.zig` and mirror it.)

- [ ] **Step 3: Build + GUI verify**

Run: `zig build 2>&1 | tail -10` → clean.
GUI: connect a tmux session to a real SSH host, `ls` a directory, ctrl+click an image / `.txt` / `.html` file → preview opens via scp. Confirm a non-profile tmux session still works (no preview, no crash).

- [ ] **Step 4: Commit**

```bash
git add src/appwindow/tmux_bridge.zig src/Surface.zig
git commit -m "feat(tmux): pane surfaces carry the session ssh_connection (preview/copy work)"
```

---

### Task A6: Feed per-pane cwd from `onPaneMeta`

**Files:**
- Modify: `src/Surface.zig` (add `setCwdPath`)
- Modify: `src/appwindow/tmux_bridge.zig` (implement `onPaneMeta`)
- Modify: `src/appwindow/tmux_controller_*.zig` (call `session.refreshPaneMeta()` on a cadence)

- [ ] **Step 1: Add `Surface.setCwdPath`**

`src/Surface.zig` (near `cwd_path`/`cwd_path_len`, ~line 292; mirror how OSC 7 writes it):

```zig
/// Set the working directory for path resolution (used by the tmux bridge,
/// which gets cwd from `#{pane_current_path}` rather than OSC 7). Truncates to
/// the cwd_path buffer.
pub fn setCwdPath(self: *Surface, path: []const u8) void {
    const n = @min(self.cwd_path.len, path.len);
    @memcpy(self.cwd_path[0..n], path[0..n]);
    self.cwd_path_len = n;
}
```

- [ ] **Step 2: Implement `onPaneMeta` in the bridge**

Add to `eventSink()` (`tmux_bridge.zig:70`): `.onPaneMeta = onPaneMeta,` and:

```zig
    fn onPaneMeta(ctx: *anyopaque, pane_id: usize, path: []const u8, cmd: []const u8) void {
        const self: *TmuxBridge = @ptrCast(@alignCast(ctx));
        const p = self.panes.find(pane_id) orelse return;
        const op = p.surface orelse return;
        const s: *Surface = @ptrCast(@alignCast(op));
        if (path.len > 0) s.setCwdPath(path);
        _ = cmd; // agent_kind is set here in Phase B (Task B3)
    }
```

- [ ] **Step 3: Refresh cadence in the controller tick**

In `tmux_controller_posix.zig` `tick` (and the Windows mirror), after the handshake and command flush, call `self.bridge.session.refreshPaneMeta()` on a throttle (e.g. every ~2s using the existing `last_*`/backoff timing fields — read what time source the tick already uses; reuse it, do not add a new clock). cwd changes are low-frequency, so a coarse cadence is fine.

- [ ] **Step 4: Build + GUI verify**

Run: `zig build 2>&1 | tail -10` → clean.
GUI: in a tmux pane `cd` into a subdir, then ctrl+click a **relative** filename printed by `ls` → preview resolves under the new cwd.

- [ ] **Step 5: Commit**

```bash
git add src/Surface.zig src/appwindow/tmux_bridge.zig src/appwindow/tmux_controller_posix.zig src/appwindow/tmux_controller_windows.zig
git commit -m "feat(tmux): feed per-pane cwd from list-panes into surface path resolution"
```

---

### Task A7: Phase A full-suite gate + GUI checklist

- [ ] **Step 1: Run both suites**

Run: `zig build test 2>&1 | tail -5` → PASS
Run: `zig build test-full 2>&1 | tail -15` → PASS (note any pre-existing failures separately).

- [ ] **Step 2: GUI checklist (record results)**

- tmux pane: ctrl+click preview of image / text / `.html` → opens via scp ✅
- copy-image/file-to-agent from a tmux pane → reaches the agent ✅
- relative-path click resolves under the pane's current cwd ✅
- tmux session started **without** a profile → features inert, no crash ✅
- detach/reattach + app restart still works (no regression to existing persistence) ✅

- [ ] **Step 3: Commit any checklist notes** (if you keep a verification log)

---

# PHASE B — Agent-state awareness (Claude Code first)

### Task B1: `src/agent_state.zig` — pure model + parsing

**Files:**
- Create: `src/agent_state.zig`
- Modify: `src/test_fast.zig` (register)

- [ ] **Step 1: Create the module with tests**

Create `src/agent_state.zig`:

```zig
//! Pure AI-agent state model + marker parsing for tmux/local agent panes.
//! No Surface/GPU deps → unit-tested in the fast suite.

const std = @import("std");

pub const AgentKind = enum { none, claude, codex, gemini, other };
pub const AgentState = enum { idle, working, blocked, done };

/// Our private OSC introducer + tag:
///   OSC 7748 ; wispterm-agent ; state=<s> [; kind=<k>] ST
pub const OSC_NUM: u16 = 7748;
pub const TAG = "wispterm-agent";

pub const Marker = struct {
    state: ?AgentState = null,
    kind: ?AgentKind = null,
};

pub fn parseState(s: []const u8) ?AgentState {
    if (std.mem.eql(u8, s, "idle")) return .idle;
    if (std.mem.eql(u8, s, "working")) return .working;
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "done")) return .done;
    return null;
}

pub fn parseKind(s: []const u8) ?AgentKind {
    if (std.mem.eql(u8, s, "claude")) return .claude;
    if (std.mem.eql(u8, s, "codex")) return .codex;
    if (std.mem.eql(u8, s, "gemini")) return .gemini;
    if (std.mem.eql(u8, s, "other")) return .other;
    return null;
}

/// Parse the OSC 7748 payload (everything after `OSC 7748;`, terminator
/// already stripped): `wispterm-agent;state=working;kind=claude`.
/// Returns null if the tag is absent or no recognized field is present.
pub fn parseMarker(payload: []const u8) ?Marker {
    var it = std.mem.splitScalar(u8, payload, ';');
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " "), TAG)) return null;
    var m: Marker = .{};
    var any = false;
    while (it.next()) |field| {
        const f = std.mem.trim(u8, field, " ");
        if (std.mem.startsWith(u8, f, "state=")) {
            if (parseState(f["state=".len..])) |st| { m.state = st; any = true; }
        } else if (std.mem.startsWith(u8, f, "kind=")) {
            if (parseKind(f["kind=".len..])) |k| { m.kind = k; any = true; }
        }
    }
    return if (any) m else null;
}

/// Identify the agent from a tmux `#{pane_current_command}` (process basename).
pub fn kindFromCommand(cmd: []const u8) AgentKind {
    const base = std.fs.path.basename(std.mem.trim(u8, cmd, " "));
    if (std.mem.eql(u8, base, "claude")) return .claude;
    if (std.mem.eql(u8, base, "codex")) return .codex;
    if (std.mem.eql(u8, base, "gemini")) return .gemini;
    return .none;
}

/// Aggregate pane states to a tab indicator by priority:
/// blocked > working > done > idle. Empty → idle.
pub fn aggregate(states: []const AgentState) AgentState {
    var result: AgentState = .idle;
    for (states) |s| {
        if (rank(s) > rank(result)) result = s;
    }
    return result;
}

fn rank(s: AgentState) u8 {
    return switch (s) { .idle => 0, .done => 1, .working => 2, .blocked => 3 };
}

test "parseMarker reads state and kind" {
    const m = parseMarker("wispterm-agent;state=working;kind=claude").?;
    try std.testing.expectEqual(AgentState.working, m.state.?);
    try std.testing.expectEqual(AgentKind.claude, m.kind.?);
}

test "parseMarker state only" {
    const m = parseMarker("wispterm-agent;state=blocked").?;
    try std.testing.expectEqual(AgentState.blocked, m.state.?);
    try std.testing.expect(m.kind == null);
}

test "parseMarker rejects wrong tag / no fields" {
    try std.testing.expect(parseMarker("other;state=idle") == null);
    try std.testing.expect(parseMarker("wispterm-agent;foo=bar") == null);
    try std.testing.expect(parseMarker("wispterm-agent;state=bogus") == null);
}

test "kindFromCommand maps known agents" {
    try std.testing.expectEqual(AgentKind.claude, kindFromCommand("claude"));
    try std.testing.expectEqual(AgentKind.codex, kindFromCommand("/usr/bin/codex"));
    try std.testing.expectEqual(AgentKind.none, kindFromCommand("bash"));
}

test "aggregate picks the highest-priority state" {
    try std.testing.expectEqual(AgentState.blocked, aggregate(&.{ .idle, .working, .blocked }));
    try std.testing.expectEqual(AgentState.working, aggregate(&.{ .idle, .done, .working }));
    try std.testing.expectEqual(AgentState.idle, aggregate(&.{}));
}
```

- [ ] **Step 2: Register in the fast suite**

Add to `src/test_fast.zig` (in the `comptime` import block with the other pure modules):

```zig
    _ = @import("agent_state.zig");
```

- [ ] **Step 3: Run the tests, verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/agent_state.zig src/test_fast.zig
git commit -m "feat(agent): pure agent-state model + OSC 7748 marker parsing"
```

---

### Task B2: Recognize `OSC 7748` in the Surface OSC parser

**Files:**
- Modify: `src/Surface.zig` (fields + OSC dispatch)

Compile-checked + GUI-verified (Surface needs the GPU backend, so no pure unit here; the parsing logic itself is already unit-tested in B1).

- [ ] **Step 1: Read the OSC completion dispatch**

Read `src/Surface.zig` around the main OSC state machine (`OscParseState`, `osc_num`, `osc_buf`, `osc_buf_len`, the `.osc_num`/`.osc_semi` transitions ~line 1114-1130) and find where a completed OSC is acted on (the OSC 52 / OSC 7 / OSC 9 handling). Note: `osc_num` is a single `u8` today (handles 0/1/2/7/9/52). OSC **7748** is 4 digits — confirm whether the parser accumulates multi-digit OSC numbers into `osc_buf` or only single-byte `osc_num`. If it only supports the small set via `osc_num`, route 7748 through the **multi-digit/number-string** branch (the same place OSC 777 / 7747-image are recognized). The image OSC `7747;WispTermImage=` is matched in `feedVtWithWispTermImageFallback` (line ~934) as a string prefix — that is the proven pattern for a 4-digit private OSC.

- [ ] **Step 2: Add the state fields**

Near the agent/notification fields in `Surface`:

```zig
agent_kind: @import("agent_state.zig").AgentKind = .none,
agent_state: @import("agent_state.zig").AgentState = .idle,
```

Initialize them in `finishInit` (alongside the other explicit field resets, ~line 439): `surface.agent_kind = .none; surface.agent_state = .idle;`

- [ ] **Step 3: Match the marker**

Mirror the `WISPTERM_IMAGE_OSC_PREFIX` approach. Add:

```zig
const WISPTERM_AGENT_OSC_PREFIX = "7748;"; // followed by "wispterm-agent;state=..."
```

In the OSC completion path (where `osc_buf[0..osc_buf_len]` holds the OSC body for the numeric-string OSCs), when the body starts with `WISPTERM_AGENT_OSC_PREFIX`, parse the remainder with `agent_state.parseMarker` and apply:

```zig
const agent_state = @import("agent_state.zig");
// body = osc_buf[0..osc_buf_len]
if (std.mem.startsWith(u8, body, WISPTERM_AGENT_OSC_PREFIX)) {
    if (agent_state.parseMarker(body[WISPTERM_AGENT_OSC_PREFIX.len..])) |m| {
        if (m.state) |st| self.agent_state = st;
        if (m.kind) |k| self.agent_kind = k;
    }
    // consumed: do not pass to the title/other handlers
}
```

If 7748 cannot be matched in the main state machine (because it only carries single-byte `osc_num`), instead add a sibling scanner in `feedVtWithWispTermImageFallback` keyed on `"\x1b]7748;"`, copying the body until BEL/ST, then `parseMarker`. Choose whichever site the existing 4-digit image OSC uses, for consistency.

- [ ] **Step 4: Build + GUI verify**

Run: `zig build 2>&1 | tail -10` → clean.
GUI: in any pane, run `printf '\033]7748;wispterm-agent;state=blocked;kind=claude\007'` → the pane's `agent_state` becomes `blocked` (verified via the dot in B7, or a temporary debug print).

- [ ] **Step 5: Commit**

```bash
git add src/Surface.zig
git commit -m "feat(agent): Surface recognizes OSC 7748 agent-state marker"
```

---

### Task B3: Set `agent_kind` from the pane command

**Files:**
- Modify: `src/appwindow/tmux_bridge.zig` (`onPaneMeta`, extend A6)

- [ ] **Step 1: Use the command in `onPaneMeta`**

Replace the `_ = cmd;` line from A6:

```zig
        const kind = @import("../agent_state.zig").kindFromCommand(cmd);
        if (kind != .none and s.agent_kind == .none) s.agent_kind = kind;
```

(Do not clobber a kind already set by an OSC marker — the marker is authoritative; `kindFromCommand` only seeds it.)

- [ ] **Step 2: Build + GUI verify**

Run: `zig build 2>&1 | tail -10` → clean.
GUI: launch `claude` in a tmux pane → `agent_kind` becomes `.claude` (dot appears once B7 lands).

- [ ] **Step 3: Commit**

```bash
git add src/appwindow/tmux_bridge.zig
git commit -m "feat(agent): seed agent_kind from tmux pane_current_command"
```

---

### Task B4: Heuristic fallback via `agent_detector.zig`

**Files:**
- Modify: `src/Surface.zig` (apply heuristic when no recent marker)
- Read: `src/agent_detector.zig` (reuse existing API)

- [ ] **Step 1: Read `agent_detector.zig`**

Determine its public API and what signal it produces (it is already imported by `test_main.zig`). Identify a function that, given recent terminal output / the surface's grid, classifies working/blocked/idle for a known `agent_kind`.

- [ ] **Step 2: Apply only as fallback**

Add a `marker_seen: bool` (or a timestamp) to `Surface`, set true when an OSC 7748 marker arrives (B2). Where output is processed, if `agent_kind != .none` and no marker has been seen, call the detector to update `agent_state`. Keep this conservative: the marker always wins; the heuristic only fills the gap for un-instrumented agents (Codex/Gemini, or Claude without the integration installed).

- [ ] **Step 3: Build + GUI verify**

Run: `zig build 2>&1 | tail -10` → clean.
GUI: run Codex (no hook) in a tmux pane → state tracks working/idle heuristically.

- [ ] **Step 4: Commit**

```bash
git add src/Surface.zig
git commit -m "feat(agent): heuristic state fallback for un-instrumented agents"
```

---

### Task B5: `src/claude_integration.zig` — Claude Code hooks config (pure)

**Files:**
- Create: `src/claude_integration.zig`
- Modify: `src/test_fast.zig` (register)

- [ ] **Step 1: Create the module with tests**

Create `src/claude_integration.zig`:

```zig
//! Pure generation/merge/removal of Claude Code hook config that makes the
//! agent emit our OSC 7748 state marker. No IO — callers read/write the file.
//! Hooks live under settings `hooks.<Event>[] = { hooks: [{type:"command",
//! command}] }`. Our commands all contain TAG so we can find/skip/remove them.

const std = @import("std");
const agent = @import("agent_state.zig");

const TAG = agent.TAG; // "wispterm-agent" — marks our hook commands

const Hook = struct { event: []const u8, state: []const u8 };
const HOOKS = [_]Hook{
    .{ .event = "UserPromptSubmit", .state = "working" },
    .{ .event = "PreToolUse", .state = "working" },
    .{ .event = "Notification", .state = "blocked" },
    .{ .event = "Stop", .state = "done" },
};

/// The shell command for one hook: emit the OSC marker to the controlling tty.
/// `> /dev/tty` so it reaches the terminal even when the hook's stdout is
/// captured by Claude Code.
pub fn hookCommand(buf: []u8, state: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "printf '\\033]7748;{s};state={s};kind=claude\\007' > /dev/tty 2>/dev/null || true",
        .{ TAG, state },
    ) catch null;
}

/// True if `settings_json` already contains a WispTerm agent hook.
pub fn isInstalled(settings_json: []const u8) bool {
    return std.mem.indexOf(u8, settings_json, TAG) != null;
}

/// Return new settings.json text with our hooks merged in idempotently.
/// `existing` may be empty (treated as `{}`). Caller owns the returned slice.
pub fn install(alloc: std.mem.Allocator, existing: []const u8) ![]u8 {
    var parsed = try parseOrEmpty(alloc, existing);
    defer parsed.deinit();
    const root = parsed.value; // std.json.Value (.object)

    var cmd_buf: [256]u8 = undefined;
    const hooks_obj = try ensureObject(parsed.arena.allocator(), root, "hooks");
    for (HOOKS) |h| {
        const cmd = hookCommand(&cmd_buf, h.state) orelse return error.CommandTooLong;
        try appendHookIfAbsent(parsed.arena.allocator(), hooks_obj, h.event, cmd);
    }
    return try stringify(alloc, root);
}

/// Return new settings.json text with all WispTerm agent hooks removed.
pub fn uninstall(alloc: std.mem.Allocator, existing: []const u8) ![]u8 {
    var parsed = try parseOrEmpty(alloc, existing);
    defer parsed.deinit();
    removeTaggedHooks(parsed.value);
    return try stringify(alloc, parsed.value);
}

// --- helpers (use std.json.Value / ObjectMap / Array; mirror the std.json
//     usage already in src/ai_history_cache.zig). Implement:
//   parseOrEmpty: parse existing or build {}; keep an arena for owned nodes.
//   ensureObject(parent, key): get-or-create a nested object.
//   appendHookIfAbsent(hooks, event, cmd): ensure hooks[event] is an array with
//     a group {hooks:[{type:"command",command:cmd}]}; skip if a command
//     containing TAG already exists under that event.
//   removeTaggedHooks(root): drop any hook command containing TAG, prune empties.
//   stringify(alloc, value): std.json.Stringify to an owned slice (2-space).
// ---

test "install adds all four hooks to empty settings" {
    const out = try install(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(isInstalled(out));
    try std.testing.expect(std.mem.indexOf(u8, out, "Stop") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Notification") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "state=blocked") != null);
}

test "install is idempotent" {
    const once = try install(std.testing.allocator, "");
    defer std.testing.allocator.free(once);
    const twice = try install(std.testing.allocator, once);
    defer std.testing.allocator.free(twice);
    // Count occurrences of our Stop marker — must be exactly one.
    try std.testing.expectEqual(@as(usize, count(twice, "state=done")), count(once, "state=done"));
}

test "install preserves an unrelated existing hook" {
    const existing =
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]}}
    ;
    const out = try install(std.testing.allocator, existing);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep-me") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "state=done") != null);
}

test "uninstall removes only our hooks" {
    const installed = try install(std.testing.allocator,
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]}}
    );
    defer std.testing.allocator.free(installed);
    const out = try uninstall(std.testing.allocator, installed);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep-me") != null);
    try std.testing.expect(!isInstalled(out));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| : (i = pos + needle.len) n += 1;
    return n;
}
```

- [ ] **Step 2: Implement the `std.json` helpers**

Read `src/ai_history_cache.zig` for the project's `std.json` idioms (it uses `parseFromSlice` with `.allocate = .alloc_always`). Implement `parseOrEmpty` / `ensureObject` / `appendHookIfAbsent` / `removeTaggedHooks` / `stringify` against the Zig version in use. Keep nodes in the parse arena so freeing is one `deinit`.

- [ ] **Step 3: Register + run tests**

Add `_ = @import("claude_integration.zig");` to `src/test_fast.zig`.
Run: `zig build test 2>&1 | tail -8`
Expected: PASS (install/idempotent/preserve/uninstall).

- [ ] **Step 4: Commit**

```bash
git add src/claude_integration.zig src/test_fast.zig
git commit -m "feat(agent): pure Claude Code hooks config generator (install/uninstall)"
```

---

### Task B6: Wire the integration installer (IO + a user action)

**Files:**
- Modify: a command-center / settings entry (read `src/command_center_state.zig` + `src/renderer/overlays.zig` for how existing actions are registered)

- [ ] **Step 1: Decide target file + read it**

Claude Code user settings: `~/.claude/settings.json`. The action reads it (empty if absent), calls `claude_integration.install`, writes it back atomically (temp + rename). Add an "Install Claude Code agent integration" entry alongside existing command-center actions; add a matching "Remove…" calling `uninstall`.

- [ ] **Step 2: Implement the read/write glue**

Use the project's existing file read/write helpers (search for how config/state files are written, e.g. `session_persist.zig`). Resolve `~` via the home dir the app already uses. On success toast "Claude Code integration installed".

- [ ] **Step 3: Build + GUI verify**

Run: `zig build 2>&1 | tail -10` → clean.
GUI: trigger the action → `~/.claude/settings.json` gains the four hooks; run Claude Code in a tmux pane and watch state transitions: prompt submit → 🟡, needs-approval → 🔴, finished → 🔵.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(agent): one-action Claude Code integration install/remove"
```

---

### Task B7: Render the per-pane / per-tab state dot

**Files:**
- Modify: the pane-border + tab-strip renderer (read `src/renderer/overlays.zig` for how pane borders + tab titles are drawn)

- [ ] **Step 1: Read the existing pane-border + tab-title draw paths**

Find where pane borders and tab labels are rendered. Decide the dot position (pane: a corner of the border; tab: leading the title).

- [ ] **Step 2: Draw from `Surface.agent_state`**

For each pane with `agent_kind != .none`, draw a colored dot for `agent_state`: 🟢 idle, 🟡 working, 🔴 blocked, 🔵 done. For the tab dot, collect the tab's panes' states and call `agent_state.aggregate(...)`; draw nothing if the tab has no agent pane.

- [ ] **Step 3: Build + GUI verify**

Run: `zig build 2>&1 | tail -10` → clean.
GUI: multi-pane tmux tab with one Claude pane blocked, one working → pane dots correct; tab dot shows blocked (highest priority).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(agent): per-pane + aggregated per-tab agent-state indicator"
```

---

### Task B8: Phase B full-suite gate + GUI checklist

- [ ] **Step 1: Run both suites**

Run: `zig build test 2>&1 | tail -5` → PASS
Run: `zig build test-full 2>&1 | tail -15` → PASS

- [ ] **Step 2: GUI checklist**

- `printf` OSC 7748 in a tmux pane flips the dot ✅
- **Confirm tmux `-CC` relays OSC 7748 via `%output`.** If it does NOT, implement the plaintext-sentinel fallback (a single tagged line scanned + stripped) per the spec's risk note, add a parser test to `agent_state.zig`, and re-verify. ✅
- Claude Code with integration installed: 🟡/🔴/🔵 track real turns ✅
- Codex (no hook): heuristic state tracks ✅
- tab dot aggregates panes by priority ✅

- [ ] **Step 3: Final commit / notes**

---

## Self-Review (completed by plan author)

- **Spec coverage:** Workstream A → Tasks A1–A7 (ssh_connection A3–A5, cwd A1/A2/A6, no-profile limitation A5/A7). Workstream B → B1–B8 (private OSC B1/B2, heuristic B4, Claude integration B5/B6, identification B3, UI + aggregation B7, OSC-relay risk + sentinel fallback B8). Non-goals (no daemon, no graphics passthrough, OSC 133 deferred, Codex heuristic-only) respected — no tasks add them.
- **Placeholders:** Pure modules (A3, B1, B5) carry complete code + tests. Integration edits (A4–A6, B2–B4, B6, B7) are compile/GUI-verified and start with a "read the exact site" step because their literal final code depends on unread spans (OSC dispatch shape, agent_detector API, renderer chrome) — each gives the concrete change + verification, not a vague TODO.
- **Type consistency:** `agent_state.AgentKind`/`AgentState`, `parseMarker`/`kindFromCommand`/`aggregate`, `SshConnection.fromParts`/`.Parts`, `Session.onPaneMeta`/`refreshPaneMeta`, `Surface.setCwdPath`/`agent_kind`/`agent_state` are used consistently across tasks.
