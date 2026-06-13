# Design: tmux-backed sessions — agent-state awareness + WispTerm feature parity

- **Date:** 2026-06-13
- **Branch:** `worktree-feat-remote-perssitance` (continues on top of the existing, feature-complete tmux `-CC` integration)
- **Status:** Design — awaiting user review before plan

## Context

The tmux control-mode (`-CC`) integration on this branch is functionally
complete: a `TmuxController` runs `ssh … tmux -CC …` in a transport PTY, a pure
`tmux.Session` parses control mode, and `TmuxBridge` mirrors tmux
windows/panes into WispTerm tabs/splits. Each tmux pane is materialized as a
**real `Surface`** via `Pty.openVirtual` + `Surface.initVirtual`
(`src/appwindow/tmux_bridge.zig:135-181`). tmux gives us the session
persistence we want (detach/reattach survives disconnect and app restart) and
is a stable, ubiquitous dependency — we keep it rather than build our own
persistent-PTY daemon.

Two gaps remain for tmux-backed sessions to be first-class:

1. **WispTerm's signature features don't fully work inside a tmux pane.** A
   tmux-pane `Surface` is built by `initVirtual`, so it has `ssh_connection =
   null` and no per-pane working directory. WispTerm's ctrl+click preview
   (image / text / HTML) and "copy image/file to the agent" feature route over
   `surface.ssh_connection` (`src/input.zig:3373`) and resolve paths against
   the surface cwd. Inside tmux those are unset, so the features misfire.

2. **No agent-state awareness.** Running multiple AI coding agents (Claude
   Code, Codex, …) in tmux panes, there is no signal of which pane is idle /
   working / blocked-on-approval / done — the kind of state Herdr surfaces with
   🔴🟡🔵🟢 indicators.

This design adds **two layers on top of the working integration**. It does NOT
rewrite the integration, build a daemon, or touch tmux's persistence.

## Goals

- Inside a tmux-backed pane, ctrl+click **preview** (image / text / HTML) and
  **copy-image/file-to-agent** work exactly as they do in a normal SSH surface.
- Per-`Surface` **agent state** (idle / working / blocked / done) + **agent
  kind**, surfaced in the UI as a per-pane / per-tab indicator.
- **Claude Code** is the first agent with a reliable, hook-driven state feed,
  installable with one action.
- Other agents (Codex, Gemini, …) degrade gracefully to heuristic detection.

## Non-goals (v1)

- ❌ No own persistent-PTY daemon — tmux stays the persistence engine.
- ❌ No tmux **graphics passthrough** work (inline SIXEL / Kitty / iTerm2
  images in the pane). None of the required features need it.
- ❌ No **OSC 133** generic prompt-mark feeder in v1 (interface left open for a
  later increment).
- ❌ Codex / Gemini hook integrations — heuristic-only in v1.
- ❌ tmux sessions started **without an SSH profile** (local tmux, ad-hoc ssh
  command) get no scp-based preview — documented limitation.

## North-star principle: everything is a `Surface`

Every tmux pane is already a real `Surface` with a real VT parser, cell grid,
OSC state machine, and the `ssh_connection` / `launch_kind` / `cwd_path` fields
(`src/Surface.zig`). Therefore **both layers are metadata + a state field, not
new rendering or new I/O paths.** Features must keep reading the `Surface`
abstraction; the work is to (A) fill the metadata gaps on tmux-pane surfaces
and (B) add a semantic-state field fed by a backing-agnostic signal. This keeps
local, SSH, and tmux surfaces uniform.

The audit rule that follows from this: any feature that breaks under tmux is
one that bypasses the `Surface` abstraction and reaches into the raw PTY/byte
stream. The required features (preview, copy-to-agent) read the grid / cwd /
ssh_connection, so they are in-scope and cheap; nothing here requires escape
sequences to survive tmux untouched.

---

## Workstream A — feature parity inside tmux panes

### Gap

- `Surface.initVirtual` leaves `ssh_connection = null` and `launch_kind` not
  `.ssh`. Preview's click router keys off both
  (`src/input.zig:3310` selects the action by `launch_kind` + whether
  `ssh_connection != null`; `src/input.zig:3373` hands `surface.ssh_connection`
  to the scp path).
- No per-pane cwd. `Surface` derives cwd from **OSC 7** (`cwd_path`,
  `src/Surface.zig:~292`), but tmux consumes OSC 7 to maintain its own
  `pane_current_path` and does not forward it in `%output`, so relative-path
  resolution inside a tmux pane has no anchor.

### Change

All wiring lives in the bridge's per-pane factory `FactoryCtx.make`
(`src/appwindow/tmux_bridge.zig:135-181`), right after `Surface.initVirtual`:

1. **Attach an `SshConnection` to each tmux-pane surface.** The controller is
   started from an `ssh_cmd` string **and** a `profile_name`
   (`tmux_controller_posix.start(alloc, ssh_cmd_utf8, profile_name, …)`); there
   is no `SshConnection` object today. Resolve `profile_name` →
   `SshConnection` via `src/ssh_profile_store.zig` (the tmux launcher already
   reuses the SSH profile list, so the profile exists), build/borrow a
   connection, set it on the surface, and set `launch_kind = .ssh`.
   - Lifetime: the connection is owned per-controller (one shared
     `SshConnection` for all panes of a session), created when the controller
     starts and freed when it closes (`closeFromRemoteExit` / `destroy`). Pane
     surfaces borrow it; teardown order must drop pane surfaces' borrowed
     pointer before the controller frees the connection.
   - If `profile_name` is empty → leave `ssh_connection = null` (the documented
     limitation): preview/copy-to-agent stay disabled for that session, same as
     today.
2. **Feed per-pane cwd from tmux, not OSC 7.** Fetch `#{pane_current_path}` per
   pane and write it into `surface.cwd_path`. Mechanism (decided in plan):
   preferred is a control-mode **format subscription**
   (`refresh-client -B …`, tmux ≥ 3.2) so cwd updates are pushed; fallback is
   periodic `list-panes -F '#{pane_id} #{pane_current_path}
   #{pane_current_command}'` polling on the controller tick. Either way the
   `Session` parses it and routes it to the pane via a new `PaneSink`-adjacent
   callback (cwd is metadata, not `%output`, so it must not go through
   `writeOutput`).

### Result

ctrl+click preview (image / text / HTML) and copy-image/file-to-agent run the
**same** `src/input.zig` code as a normal SSH surface; only the inputs
(`ssh_connection`, `cwd_path`) are now populated for tmux panes. No new preview
or scp code.

---

## Workstream B — agent-state awareness (private-OSC + heuristic, Claude Code first)

### Surface state

Add two fields to `Surface` (`src/Surface.zig`):

- `agent_kind: AgentKind` — `none | claude | codex | gemini | other`
- `agent_state: AgentState` — `idle | working | blocked | done`

Both default to `none` / `idle` and are read by the renderer. They are set by
the feeders below, in descending reliability.

### Feeder 1 — private agent OSC (primary, new)

Mirror the existing private-image OSC mechanism
(`WISPTERM_IMAGE_OSC_PREFIX = "7747;WispTermImage="`, `src/Surface.zig:65`,
parsed in the surface OSC state machine). Add a sibling:

```
OSC 7748 ; wispterm-agent ; state=<idle|working|blocked|done> [; kind=<claude|…>] BEL
```

Parsed in the same OSC state machine → sets `agent_state` (and `agent_kind` if
present). The payload parse is a pure function in a new module (below).

**Why it is backing-agnostic:** the marker rides the pane's normal output
stream. Inside tmux it arrives as `%output` bytes → `PaneMap.writeImpl` →
`controller.writeOutput` → the pane's Surface VT/OSC parser
(`src/appwindow/tmux/pane.zig:110`). On a local or plain-SSH surface it is
parsed the same way. One parser, all backings.

**Risk + fallback (verify in GUI):** confirm tmux `-CC` relays a private OSC in
`%output`. `-CC` carries the pane program's output bytes, so it should; if it
is filtered, fall back to a **plaintext tagged sentinel line** that `%output`
definitely carries (e.g. a unique single-line token), scanned and stripped from
display. Primary path stays the invisible OSC.

### Feeder 2 — heuristic fallback (reuse existing)

For agents without an installed hook, reuse WispTerm's existing snapshot /
done-detector machinery (already used by the Copilot remote-snapshot path) to
infer working / blocked / done from pane content (spinner, "esc to interrupt",
approval menu, prompt return). Lower confidence; only applied when no OSC
marker has set state recently.

### Agent identification

Which pane runs which agent:

- tmux panes: `#{pane_current_command}` (same fetch as the cwd subscription /
  poll in Workstream A).
- local / SSH surfaces: launch command + heuristic on output.

Sets `agent_kind`, which gates whether an indicator is shown and which
heuristic profile applies.

### Claude Code integration (first-class, installable)

A one-action installer writes Claude Code hook configuration so the agent
reports state out-of-the-box:

- `Stop` → `done` (then `idle`)
- `Notification` (needs permission / attention) → `blocked`
- `UserPromptSubmit` / `PreToolUse` → `working`

Each hook is a tiny command that `printf`s the OSC 7748 marker to its tty. The
installer's config generation/merge/uninstall is pure and idempotent (does not
clobber unrelated hooks). Without the integration installed, Claude Code falls
back to Feeder 2.

### UI

Render the state as a colored dot on the pane border and the owning tab,
reusing existing tab/pane chrome. Color map: 🟢 idle, 🟡 working, 🔴 blocked,
🔵 done. A pane shows its own `agent_state`; a tab aggregates its panes by
**priority** — `blocked` > `working` > `done` > `idle` — so the tab dot
reflects the most attention-worthy pane. A pane with `agent_kind = none` shows
no dot.

---

## New modules & boundaries

Following this branch's convention — pure, Surface-free helpers are unit-tested;
reconcile / render paths are compile-checked and GUI-verified
(`src/appwindow/tmux_bridge.zig` header):

- **`src/agent_state.zig` (new, pure):** `AgentKind` / `AgentState` enums; the
  OSC 7748 payload parser (`"state=…;kind=…"` → enums); the plaintext-sentinel
  parser (fallback). Unit-tested.
- **`src/claude_integration.zig` (new, pure):** generate / merge / remove the
  Claude Code hook config (which JSON, idempotent). Unit-tested.
- **`src/Surface.zig` (edit):** add `agent_kind` / `agent_state`; recognize OSC
  7748 in the OSC state machine; set `cwd_path` from an external setter (used by
  the tmux cwd feed, not OSC 7).
- **`src/appwindow/tmux_bridge.zig` (edit):** factory attaches resolved
  `SshConnection` + `launch_kind`; wire the per-pane cwd / `pane_current_command`
  feed.
- **`src/tmux/session.zig` (edit):** parse the format subscription / `list-panes`
  reply; expose per-pane `current_path` / `current_command` via a metadata
  callback (separate from `PaneSink.writeOutput`).
- **`src/ssh_profile_store.zig` (read/extend):** resolve `profile_name` →
  `SshConnection`.
- **renderer / tab chrome (edit):** draw the state dot from `Surface.agent_state`.

## Implementation phasing

Workstream A and Workstream B are **independent** — A touches
`ssh_connection` / `cwd_path` wiring; B touches the OSC parser / a new state
field / UI. They share only the per-pane `pane_current_path` /
`pane_current_command` fetch (A needs the path, B needs the command), so that
fetch is built once and consumed by both. Suggested order: A first (it makes
existing features correct and is lower-risk), then B. Either can land/merge on
its own.

## Data flow

```
Workstream A (preview/cwd):
  tmux  --%output-->  Session.feed  --writeImpl-->  controller.writeOutput
                                                          |
                                                    pane Surface (grid)
  tmux  --subscription/list-panes--> Session metadata cb --> surface.cwd_path
  controller.profile_name --ssh_profile_store--> SshConnection --> surface.ssh_connection
  ctrl+click --> input.zig (reads surface.ssh_connection + cwd_path) --> scp preview

Workstream B (agent state):
  Claude Code hook --printf OSC 7748--> pane stdout --%output--> Session.feed
        --> controller.writeOutput --> pane Surface OSC parser
        --> agent_state.parse --> Surface.agent_state --> renderer dot
  (fallback) snapshot/done-detector --> Surface.agent_state
```

## Error & edge handling

- **No profile / empty `profile_name`:** `ssh_connection` stays null; preview &
  copy-to-agent disabled for that session (documented), everything else works.
- **`profile_name` no longer resolvable** (profile deleted): treat as no
  profile; do not crash.
- **OSC 7748 filtered by tmux:** switch to plaintext-sentinel fallback (decided
  during GUI verification); state detection still functions.
- **Stale state:** a pane that emits `working` then the agent dies — heuristic
  fallback / prompt-return detection clears it to `idle`; no indefinite spinner.
- **Connection lifetime:** pane surfaces borrow the controller's
  `SshConnection`; on `closeFromRemoteExit` / `destroy`, drop pane surfaces
  before freeing the connection (mirrors the existing PaneMap teardown order).
- **Hook config merge:** installer must be idempotent and must not remove the
  user's existing Claude Code hooks; uninstall removes only WispTerm's entries.

## Testing strategy

- **Pure unit tests:** OSC 7748 payload parser (valid / partial / unknown
  state); plaintext-sentinel parser; Claude hook config generate / merge /
  idempotent re-install / uninstall; `profile_name → SshConnection` resolution
  (incl. empty / missing).
- **GUI verification:** inside a tmux pane — ctrl+click preview of image / text
  / HTML; copy-image/file-to-agent; run real Claude Code and observe
  🔴🟡🔵🟢 transitions; confirm whether `%output` carries OSC 7748 (decides
  whether the plaintext-sentinel fallback ships).

## Risks / things to confirm during planning & GUI

1. tmux `-CC` relays a private OSC in `%output` (else use plaintext sentinel).
2. Cleanest per-pane cwd/command feed: control-mode format subscription
   (`refresh-client -B`, tmux ≥ 3.2) vs `list-panes -F` polling.
3. `SshConnection` shape from a profile name — is there an existing constructor
   that yields a connection usable by the scp/preview path, or must one be
   adapted.
4. Borrowed-`SshConnection` teardown ordering vs the existing controller
   close paths (`closeFromRemoteExit`, `destroy`, reconnect).
