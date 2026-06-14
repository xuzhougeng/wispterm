# tmux Management via a Launcher Entry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a session-launcher entry "Connect with tmux (keep alive)" that reuses the existing SSH profile list (a new `SshListMode.tmux_connect` mirroring `ai_history_select`) to start a tmux control-mode session, and remove the per-profile `tmux` field — so tmux-remote and plain-ssh are distinguished at the launcher.

**Architecture:** Mirror the AI-History pattern: a top-level launcher row → SSH profile picker in a select mode → on pick, connect via the existing `AppWindow.startTmuxSession`. Adds a cross-platform main-menu row to the launcher row model; threads a new `SshListMode` arm through the launcher's switch sites; derives the tmux session name from the profile name.

**Tech Stack:** Zig 0.15.2. Launcher UI lives in `src/renderer/overlays.zig` (GUI-verified); the launcher row model + its tests are pure (`src/platform/pty_command.zig`); session-name sanitization is a pure, unit-tested helper.

**Reference:** Spec `docs/superpowers/specs/2026-06-03-tmux-management-launcher-entry-design.md`. Template: the AI-History flow — `openAiHistorySshPicker → openSshProfilePicker(.ai_history_select)`, `runSshListRow`'s `.ai_history_select` arm (`overlays.zig:2333`), and the `ai_history` main-menu row.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/platform/pty_command.zig` | Launcher row model: add a `tmux` row after `ssh`; bump `session_launcher_row_count`; add `session_launcher_tmux_row`; shift `ai_agent`/`ai_history` (and keep `wsl`); update the subtitle strings + the `*ForOs` row-index tests. |
| `src/command_center_state.zig` | Re-export `SESSION_LAUNCHER_ROW_TMUX` from the platform constant. |
| `src/renderer/overlays.zig` | `SessionAction.tmux` + dispatch; `sessionHitTest` + render of the tmux row; `SshListMode.tmux_connect` + every switch arm; `openTmuxSshPicker`; `connectSshProfileTmux` + `tmuxSessionName` (sanitizer, unit-tested); remove the `tmux` form field + the field-based connect gate; `connectProfileByNameTmux` for the dev hook. |
| `src/renderer/overlays/profile_codec.zig` | Revert `SshField.tmux`; `SSH_FIELD_COUNT` back to `6`. |
| `src/input.zig` | Gate the sidebar "+" (two sites): tmux tab → `AppWindow.requestTmuxNewWindowForActiveTab()`, else `sessionLauncherOpen()`. |
| `src/AppWindow.zig` | Startup dev hook: honor `WISPTERM_AUTOCONNECT_TMUX` (→ `overlays.connectProfileByNameTmux`). |

**Verification commands:** `zig test src/renderer/overlays/profile_codec.zig` is not standalone; use the suites. Pure helper tests run via `zig build test-full -Dtarget=aarch64-macos` (native run). Cross-platform compile: `zig build test-full` (windows). Final GUI gate: `zig build macos-app -Dtarget=aarch64-macos` + run `WISPTERM_AUTOCONNECT_TMUX=NGS00 zig-out/bin/WispTerm.app/Contents/MacOS/WispTerm`.

---

## Task 1: Revert the per-profile `tmux` field

**Files:** Modify `src/renderer/overlays/profile_codec.zig`, `src/renderer/overlays.zig`

- [ ] **Step 1: profile_codec — back to 6 fields**

In `src/renderer/overlays/profile_codec.zig`, change:

```zig
pub const SSH_FIELD_COUNT = 7;
```
to
```zig
pub const SSH_FIELD_COUNT = 6;
```
and remove the `tmux = 6,` entry (and its comment) from `pub const SshField = enum(usize) { … }`, leaving fields `name…proxy_jump` (0–5).

- [ ] **Step 2: overlays — remove the tmux form field**

In `src/renderer/overlays.zig`, delete the line added for the form field:

```zig
    renderSessionField(layout, window_height, @intFromEnum(SshField.tmux), "Keep alive · tmux (1=on)", sshField(.tmux), false);
```

- [ ] **Step 3: overlays — remove the field-based connect gate**

In `connectSshProfileReturningSurfaceWithCommand`, delete the gate block:

```zig
    // Phase 3d: tmux control-mode gate. … Returns null (no surface) …
    const tmux_field = profileField(profile, .tmux);
    const tmux_enabled = tmux_field.len > 0 and tmux_field[0] == '1';
    if (tmux_enabled) {
        var tmux_buf: [8192]u8 = undefined;
        const tmux_cmd = platform_pty_command.sshInteractiveCommand(tmux_buf[0..], .{
            .user = user, .host = ip, .port = port,
            .password_auth = password.len > 0,
            .legacy_algorithms = AppWindow.g_ssh_legacy_algorithms,
            .proxy_jump = proxy_jump,
            .remote_command = "tmux -CC new -A -s wispterm",
        }) orelse return null;
        sessionLauncherClose();
        _ = AppWindow.startTmuxSession(tmux_cmd, password);
        return null;
    }
```
(Leave the rest of `connectSshProfileReturningSurfaceWithCommand` — the plain-ssh path — intact.)

- [ ] **Step 4: Compile-check both targets**

Run: `zig build test-full` → EXIT 0 (windows; codec back to 6 fields). Then `zig build macos-app -Dtarget=aarch64-macos` → EXIT 0.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays/profile_codec.zig src/renderer/overlays.zig
git commit -m "revert(tmux): drop per-profile tmux field (replaced by launcher entry)"
```

---

## Task 2: `tmuxSessionName` sanitizer (pure, TDD)

**Files:** Modify `src/renderer/overlays.zig` (add fn + test)

- [ ] **Step 1: Write the failing test**

Add to the test section of `src/renderer/overlays.zig` (near other overlay tests):

```zig
test "tmuxSessionName sanitizes a profile name to a tmux-safe session name" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("wispterm-NGS00", tmuxSessionName(&buf, "NGS00"));
    try std.testing.expectEqualStrings("wispterm-prod_db_1", tmuxSessionName(&buf, "prod.db:1"));
    try std.testing.expectEqualStrings("wispterm-a_b_c", tmuxSessionName(&buf, "a b\tc"));
    try std.testing.expectEqualStrings("wispterm", tmuxSessionName(&buf, ""));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full -Dtarget=aarch64-macos`
Expected: FAIL — `tmuxSessionName` undeclared.

- [ ] **Step 3: Implement**

Add near the other SSH helpers in `src/renderer/overlays.zig`:

```zig
/// Derive a tmux-safe session name from a profile name: `wispterm-<name>` with
/// every char outside [A-Za-z0-9_-] replaced by '_'. Empty name → "wispterm".
/// `buf` must be at least 9 + name.len bytes.
fn tmuxSessionName(buf: []u8, profile_name: []const u8) []const u8 {
    const prefix = "wispterm";
    if (profile_name.len == 0) {
        @memcpy(buf[0..prefix.len], prefix);
        return buf[0..prefix.len];
    }
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '-';
    var n: usize = prefix.len + 1;
    for (profile_name) |c| {
        if (n >= buf.len) break;
        buf[n] = if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') c else '_';
        n += 1;
    }
    return buf[0..n];
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-full -Dtarget=aarch64-macos` → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "feat(tmux): tmuxSessionName — derive a tmux-safe session name from a profile"
```

---

## Task 3: `tmux_connect` SSH-picker mode + connect

**Files:** Modify `src/renderer/overlays.zig`

- [ ] **Step 1: Add the mode**

In `SshListMode` add `tmux_connect`:

```zig
const SshListMode = enum {
    manage,
    edit_select,
    delete_select,
    ai_history_select,
    tmux_connect,
};
```

- [ ] **Step 2: Thread it through every `SshListMode` switch (mirror `ai_history_select`)**

Add a `.tmux_connect` arm everywhere `.ai_history_select` appears:

- `overlays.zig:~1799` — `if (g_ssh_list_visible and g_ssh_list_mode == .ai_history_select)` → `… (g_ssh_list_mode == .ai_history_select or g_ssh_list_mode == .tmux_connect))`.
- `~2024` (`openSshProfilePicker` empty guard) — `if (g_ssh_profile_count == 0 and mode != .ai_history_select and mode != .tmux_connect) return;`.
- `~2085` (row count) — add `.tmux_connect` beside `.edit_select, .delete_select, .ai_history_select => sshVisibleProfileCount() + 1`.
- `~3278` (title) — add `.tmux_connect => "tmux SSH Profile",`.
- `~3303` (subtitle) — add `.tmux_connect => if (has_filter) "Filter profiles" else "Choose a profile or go back",`.
- `~3396` and `~3711` (render arms) — add `.tmux_connect => { … }` blocks identical to the adjacent `.ai_history_select` block at each site.

- [ ] **Step 3: Add the `tmux_connect` action in `runSshListRow`**

In `runSshListRow` (`overlays.zig:2301` switch), add:

```zig
        .tmux_connect => {
            if (row < visible_profile_count) {
                const profile_idx = sshVisibleProfileIndexAt(row) orelse return;
                connectSshProfileTmux(profile_idx);
            } else {
                sessionLauncherClose();
            }
        },
```

- [ ] **Step 4: Add `openTmuxSshPicker` + `connectSshProfileTmux`**

Add near `openAiHistorySshPicker` / `connectSshProfile`:

```zig
fn openTmuxSshPicker() void {
    openSshProfilePicker(.tmux_connect);
}

fn connectSshProfileTmux(idx: usize) void {
    if (idx >= g_ssh_profile_count) return;
    const profile = &g_ssh_profiles[idx];
    const ip = profileField(profile, .ip);
    const user = profileField(profile, .user);
    const port = profileField(profile, .port);
    const password = profileField(profile, .password);
    const proxy_jump = profileField(profile, .proxy_jump);
    const name = profileField(profile, .name);
    if (ip.len == 0 or user.len == 0) return;
    if (!isSshTokenSafe(ip) or !isSshTokenSafe(user)) return;
    if (port.len > 0 and !isPortTokenSafe(port)) return;
    if (!command_palette_model.isProxyJumpSafe(proxy_jump)) return;

    var name_buf: [96]u8 = undefined;
    const session_name = tmuxSessionName(&name_buf, name);
    var remote_buf: [128]u8 = undefined;
    const remote = std.fmt.bufPrint(&remote_buf, "tmux -CC new -A -s {s}", .{session_name}) catch return;

    var cmd_buf: [8192]u8 = undefined;
    const cmd = platform_pty_command.sshInteractiveCommand(cmd_buf[0..], .{
        .user = user,
        .host = ip,
        .port = port,
        .password_auth = password.len > 0,
        .legacy_algorithms = AppWindow.g_ssh_legacy_algorithms,
        .proxy_jump = proxy_jump,
        .remote_command = remote,
    }) orelse return;

    sessionLauncherClose();
    _ = AppWindow.startTmuxSession(cmd, password);
}

/// Connect a profile by name in tmux mode (dev/automation hook).
pub fn connectProfileByNameTmux(name: []const u8) bool {
    loadSshProfiles();
    var idx: usize = 0;
    while (idx < g_ssh_profile_count) : (idx += 1) {
        if (std.mem.eql(u8, profileField(&g_ssh_profiles[idx], .name), name)) {
            connectSshProfileTmux(idx);
            return true;
        }
    }
    return false;
}
```

- [ ] **Step 5: Compile-check**

Run: `zig build macos-app -Dtarget=aarch64-macos` → EXIT 0 (all `SshListMode` switches exhaustive). `zig build test-full` → EXIT 0.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "feat(tmux): SSH-picker tmux_connect mode + connectSshProfileTmux"
```

---

## Task 4: Main-menu "Connect with tmux" row

**Files:** Modify `src/platform/pty_command.zig`, `src/command_center_state.zig`, `src/renderer/overlays.zig`

- [ ] **Step 1: Row model — insert tmux after ssh**

In `src/platform/pty_command.zig`, update the launcher row model to insert a `tmux` row at index 2 (after ssh), shifting the rest:

```zig
pub fn sessionLauncherRowCountForOs(os_tag: std.Target.Os.Tag) usize {
    return switch (backendForOs(os_tag)) {
        .windows => 6,
        .unsupported => 5,
    };
}

pub const session_launcher_tmux_row = sessionLauncherTmuxRowForOs(builtin.os.tag);
pub fn sessionLauncherTmuxRow() usize {
    return session_launcher_tmux_row;
}
pub fn sessionLauncherTmuxRowForOs(os_tag: std.Target.Os.Tag) usize {
    return switch (backendForOs(os_tag)) {
        .windows => 3, // powershell0 ssh1 wsl2 tmux3
        .unsupported => 2, // shell0 ssh1 tmux2
    };
}

pub fn sessionLauncherAiAgentRowForOs(os_tag: std.Target.Os.Tag) usize {
    return switch (backendForOs(os_tag)) {
        .windows => 4,
        .unsupported => 3,
    };
}

pub fn sessionLauncherAiHistoryRowForOs(os_tag: std.Target.Os.Tag) usize {
    return switch (backendForOs(os_tag)) {
        .windows => 5,
        .unsupported => 4,
    };
}
```
Also extend the subtitle strings (`sessionLauncherSubtitleForOs` ~line 104): `"… SSH, tmux, WSL, AI Agent, …"` / `"… SSH, tmux, AI Agent, …"`.

- [ ] **Step 2: Update the row-model tests**

Run `grep -nE "sessionLauncherAiAgentRowForOs|sessionLauncherAiHistoryRowForOs|sessionLauncherRowCountForOs|sessionLauncherWslRowForOs" src/platform/pty_command.zig` to find the `test` blocks and update the expected constants to the new values: macOS/unsupported count=5, tmux=2, ai_agent=3, ai_history=4; windows count=6, wsl=2, tmux=3, ai_agent=4, ai_history=5. Add an assertion for `sessionLauncherTmuxRowForOs(.macos)==2` and `(.windows)==3`.

- [ ] **Step 3: command_center_state re-export**

In `src/command_center_state.zig`, after the AI-history row const, add:

```zig
pub const SESSION_LAUNCHER_ROW_TMUX: usize = platform_pty_command.session_launcher_tmux_row;
```

- [ ] **Step 4: overlays — SessionAction + dispatch + hit-test + render**

In `src/renderer/overlays.zig`:
- Add `tmux,` to the `SessionAction` enum.
- In `sessionLauncherExecuteAt`'s switch add: `.tmux => openTmuxSshPicker(),`.
- In `sessionHitTest` main-menu block (after the `ssh` row, ~3505) add: `if (row == command_center_state.SESSION_LAUNCHER_ROW_TMUX) return .tmux;`.
- In the main-menu render block (~3720, after the SSH `renderSessionRow` / before WSL) add:

```zig
        renderSessionRow(layout, window_height, command_center_state.SESSION_LAUNCHER_ROW_TMUX, "Connect with tmux", "Keep session alive (tmux -CC)", g_session_launcher_selected == command_center_state.SESSION_LAUNCHER_ROW_TMUX);
```
(Render it by its constant index, like the AI rows — do NOT use the running `row` counter, which is only used for local/ssh/wsl.)

- [ ] **Step 5: Compile + GUI check**

Run: `zig build test-full` → EXIT 0; `zig build macos-app -Dtarget=aarch64-macos` → EXIT 0. Launch and confirm the launcher shows a "Connect with tmux" row between SSH and AI Agent; selecting it lists profiles; picking NGS00 opens a tmux tab.

- [ ] **Step 6: Commit**

```bash
git add src/platform/pty_command.zig src/command_center_state.zig src/renderer/overlays.zig
git commit -m "feat(tmux): launcher row 'Connect with tmux' (reuses the SSH profile list)"
```

---

## Task 5: "+" in a tmux tab → new tmux window

**Files:** Modify `src/input.zig`

- [ ] **Step 1: Gate both sidebar-"+" call sites**

In `src/input.zig`, at the two sites where the sidebar plus button calls `overlays.sessionLauncherOpen()` (the `hitTestSidebarPlusButton` handlers, ~2079 and ~3335), replace:

```zig
        overlays.sessionLauncherOpen();
```
with:

```zig
        if (!AppWindow.requestTmuxNewWindowForActiveTab()) overlays.sessionLauncherOpen();
```
(Do NOT touch the `.new_session => overlays.sessionLauncherOpen()` command arm — that's the explicit "open launcher" shortcut.)

- [ ] **Step 2: Compile + GUI check**

Run: `zig build macos-app -Dtarget=aarch64-macos` → EXIT 0. In a tmux tab, "+" adds a second tmux window/tab; in a non-tmux tab, "+" still opens the launcher.

- [ ] **Step 3: Commit**

```bash
git add src/input.zig
git commit -m "feat(tmux): sidebar + adds a tmux window when the active tab is tmux"
```

---

## Task 6: Dev hook `WISPTERM_AUTOCONNECT_TMUX`

**Files:** Modify `src/AppWindow.zig`

- [ ] **Step 1: Honor the tmux autoconnect env**

In `src/AppWindow.zig`, beside the existing `WISPTERM_AUTOCONNECT` block, add:

```zig
        if (std.process.getEnvVarOwned(allocator, "WISPTERM_AUTOCONNECT_TMUX")) |p| {
            defer allocator.free(p);
            if (p.len > 0) {
                std.debug.print("tmux: auto-connecting profile '{s}' (tmux)\n", .{p});
                _ = overlays.connectProfileByNameTmux(p);
            }
        } else |_| {}
```

- [ ] **Step 2: Compile + GUI verify end-to-end**

Run: `zig build macos-app -Dtarget=aarch64-macos` → EXIT 0. Run `WISPTERM_AUTOCONNECT_TMUX=NGS00 zig-out/bin/WispTerm.app/Contents/MacOS/WispTerm`; confirm a tmux tab appears (session `wispterm-NGS00`), plain SSH still works via the launcher's SSH row, and "+" in the tmux tab adds a window.

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(tmux): WISPTERM_AUTOCONNECT_TMUX dev hook"
```

---

## Self-Review

**1. Spec coverage.** Launcher entry + `tmux_connect` mode (Task 3+4) ✓; reuse SSH list ✓; profile-derived session name (Task 2) ✓; remove per-profile field (Task 1) ✓; keep controller/split/close/new-window ✓ (untouched); "+"→new-window (Task 5) ✓; dev hook (Task 6) ✓. No gaps.

**2. Placeholder scan.** The only "find then edit" step is Task 4 Step 2 (row-model tests) — it gives the exact new constant values, so it's a mechanical update, not a placeholder. Every code block is complete.

**3. Type consistency.** `SshListMode.tmux_connect` used consistently across all switch arms + `openSshProfilePicker(.tmux_connect)`. `tmuxSessionName(buf: []u8, name: []const u8) []const u8` matches its test + `connectSshProfileTmux` call. `SessionAction.tmux` → `openTmuxSshPicker` → `connectSshProfileTmux`. `session_launcher_tmux_row` / `SESSION_LAUNCHER_ROW_TMUX` consistent. `AppWindow.startTmuxSession`, `requestTmuxNewWindowForActiveTab`, `overlays.connectProfileByNameTmux` match their definitions.
