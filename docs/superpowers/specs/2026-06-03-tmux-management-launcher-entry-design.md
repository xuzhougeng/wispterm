# Independent tmux Management via a Launcher Entry — Design

## Context

Phase 3d shipped a working tmux control-mode integration: a `TmuxController`
(`src/appwindow/tmux_controller_posix.zig`) drives an `ssh … tmux -CC` transport,
a `TmuxBridge` reconciles tmux windows/panes into WispTerm tabs/splits, and
native split / close-pane / new-window actions drive tmux (`split-window` /
`kill-pane` / `new-window`). Size-sync forwards the real pane grid to tmux so
output renders cleanly. All GUI-verified against a real server.

The **trigger** so far was a per-profile `tmux` field on the SSH profile
(commit `2cc0d56`): a checkbox baked into each SSH profile. The user wants this
replaced: tmux-remote sessions should be **managed independently from plain SSH**,
mirroring how **AI History** is managed — AI History does not store its own
connections; it has a launcher entry that reuses the existing SSH profile list
via a "select" mode (`openAiHistorySshPicker → openSshProfilePicker(.ai_history_select)`).
The same server should be connectable either as plain SSH or as a tmux session,
chosen at the launcher, not baked into the profile.

## Goal

Distinguish "tmux remote ssh" from "plain ssh" at the **session launcher** level,
reusing the single SSH profile list. Connecting via the tmux entry starts a
control-mode session; connecting via the plain SSH entry is unchanged. Remove the
per-profile `tmux` field.

## Non-Goals

- A separate tmux-session entity / storage (rejected: would duplicate connection
  fields). tmux reuses SSH profiles.
- Changing the in-tmux-tab behavior (split/close/new-window already drive tmux).
- Multi-pane size-sync, capture-pane seeding, detach/reconnect — tracked
  separately in `docs/superpowers/tmux-resume.md`.

## Design

### 1. Launcher entry + select mode (mirrors AI History)

The session launcher's main menu gains one row: **"Connect with tmux (keep alive)"**.
Selecting it opens the existing SSH profile picker in a new
`SshListMode.tmux_connect` mode — the exact shape of `ai_history_select`
(`overlays.zig`: `SshListMode` enum, `openSshProfilePicker(mode)`,
`openAiHistorySshPicker`). Picking a profile in `tmux_connect` mode connects it
in tmux control mode rather than scanning history or connecting plain.

Plain SSH stays on the existing "SSH" entry / picker (`SshListMode.manage` →
`connectSshProfile`), unchanged. The two entries are the user-visible
distinction between plain-ssh and tmux-remote; the same profile works under
either.

### 2. Connect flow + session naming

On picking profile P in `tmux_connect` mode (a sibling of
`connectSshProfileReturningSurfaceWithCommand`):

1. Build `ssh -tt <host> -p <port> [-o …] <user>@<host> -- tmux -CC new -A -s <name>`
   via `platform_pty_command.sshInteractiveCommand(.{… .remote_command = "tmux -CC new -A -s <name>"})`.
2. `name` = a sanitized, profile-derived session name: `wispterm-<profile-name>`
   with any char outside `[A-Za-z0-9_-]` replaced by `_` (tmux session names
   can't contain `.`/`:`/whitespace). This gives each profile its own remote
   session (no cross-profile collisions on a shared host) and stable re-attach
   (`-A` attaches the same name next time).
3. `sessionLauncherClose()`, then `AppWindow.startTmuxSession(cmd, password)`
   (the existing controller entry). No surface is spawned here — the controller
   builds the tabs.

### 3. Remove the per-profile `tmux` field

Revert the `2cc0d56` additions: `SshField.tmux` (back to `SSH_FIELD_COUNT = 6`),
the "Keep alive · tmux" form field, and the field-based connect gate in
`connectSshProfileReturningSurfaceWithCommand`. The launcher entry is the sole
trigger. (The `ssh_hosts` codec already tolerates field-count changes, so existing
7-field lines load fine with the extra field ignored.)

### 4. Kept behaviors (already shipped; unchanged)

- Controller / bridge / size-sync, `split-window`, `kill-pane`, `new-window`
  primitives, per-pane keystroke routing, focus tracking.
- **"+" in a tmux tab → new tmux window.** The sidebar "+" (which today opens
  the launcher) is gated: when the active tab is tmux-backed, it calls
  `AppWindow.requestTmuxNewWindowForActiveTab()` (a new window in the same
  session) instead of opening the launcher. Non-tmux tabs are unchanged.

### 5. Dev/automation hook

`WISPTERM_AUTOCONNECT=<profile>` currently connects a profile plain. Add
`WISPTERM_AUTOCONNECT_TMUX=<profile>` that connects the named profile in tmux
mode at launch — for headless/automation testing only; not a user-facing
feature.

## Components / Files

| File | Change |
|---|---|
| `src/renderer/overlays.zig` | Add the "Connect with tmux" main-menu row + `SessionAction` variant; add `SshListMode.tmux_connect`; add `openTmuxSshPicker` (mirrors `openAiHistorySshPicker`); add `connectSshProfileTmux(idx)` (build tmux cmd + session name + `AppWindow.startTmuxSession`); route the picker's connect-in-tmux-mode. Remove the `tmux` form field + field-based gate. Add `connectProfileByNameTmux` for the dev hook. |
| `src/renderer/overlays/profile_codec.zig` | Revert `SshField.tmux`; `SSH_FIELD_COUNT` back to 6. |
| `src/input.zig` | Gate the sidebar "+" handler: tmux tab → `AppWindow.requestTmuxNewWindowForActiveTab()`, else `sessionLauncherOpen()` (the two plus-button call sites). |
| `src/AppWindow.zig` | `connectProfileByName` dev hook → honor `WISPTERM_AUTOCONNECT_TMUX`. (`startTmuxSession`, `requestTmuxNewWindowForActiveTab` already exist.) |

## Data Flow

- **Launcher → tmux connect:** main menu "Connect with tmux" → SSH picker in
  `tmux_connect` → pick P → `connectSshProfileTmux(P)` → build cmd + name →
  `AppWindow.startTmuxSession` → controller → tabs.
- **In-tmux new tab:** "+" in a tmux tab → `requestTmuxNewWindowForActiveTab` →
  controller `new-window` → `%window-add`/`%layout-change` → bridge new tab.
- Plain SSH and all other launcher entries: unchanged.

## Error Handling / Edge Cases

- Profile validation (host/user/port/proxy-jump safety) reuses the existing
  `isSshTokenSafe`/`isPortTokenSafe` checks before connecting.
- Session-name sanitization guarantees a valid tmux name; empty profile name →
  fall back to `wispterm`.
- "+" gate: if a tmux tab's focused surface is unresolved (focus on a split
  node), fall back to opening the launcher rather than failing silently.
- No tmux on the server / old tmux: out of scope here (the controller's read
  loop surfaces EOF; graceful fallback is the separate lifecycle work #4).

## Testing

- **Unit (headless):** session-name sanitization (pure fn) — profile name →
  tmux-safe name. `SshListMode.tmux_connect` routing is overlay/GUI code
  (compile-checked + GUI-verified, like the rest of the launcher).
- **GUI-verify (real server):** launcher → "Connect with tmux" → pick NGS00 →
  tmux tab appears with the remote shell; plain "SSH" → NGS00 still connects
  plain; "+" in the tmux tab adds a second tmux window/tab; close-pane removes a
  split. Both build targets stay green (`zig build test-full`,
  `zig build macos-app -Dtarget=aarch64-macos`).

## Rollout

Behavior-additive at the launcher; removing the per-profile field is invisible to
users (the field was new and undocumented). Existing `ssh_hosts` files load
unchanged.
