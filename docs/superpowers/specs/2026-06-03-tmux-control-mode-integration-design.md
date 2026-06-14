# tmux Control Mode Integration Design

## Context

WispTerm connects to remote servers by spawning `ssh -tt user@host` inside a PTY-backed `Surface` (`platform/pty_command.zig` `sshInteractiveCommand`, `surface.is_ssh = true`). Today's "persistence" (`session_persist.zig`) only re-runs the ssh command and `cd`s back to the saved cwd on next launch — it recreates the *workspace shape*, not in-flight state. If the user accidentally closes the app, drops wifi, or closes the laptop, every remote shell, running job, and scrollback is lost.

The user wants iTerm2-style **tmux integration**: tmux runs on the server, WispTerm speaks tmux's control-mode protocol (`tmux -CC`), tmux *windows* become WispTerm *tabs*, and tmux *panes* become WispTerm native *splits*. The server keeps everything alive; closing WispTerm or dropping the connection just detaches. Reconnecting re-attaches with layout and recent scrollback restored. The tmux status bar and prefix key are invisible — it feels native.

Only the **server** needs tmux installed. The local side never shells out to a local tmux; WispTerm *is* the tmux client, implemented in our own code.

## Goals

- Remote sessions survive app close, network drop, and reboot of the *client*. Reconnect re-attaches to the same session with layout + recent scrollback intact.
- tmux windows ↔ WispTerm tabs; tmux panes ↔ WispTerm native splits. No visible tmux chrome, no prefix key.
- Native split/new-tab/resize/close actions drive tmux; tmux is the single source of truth for layout.
- Each tmux pane is a normal `Surface`, so selection, search, copy, link handling, and AI-agent detection work identically to local panes.
- Opt-in and fail-open: nothing changes for users who do not enable it; any tmux failure falls back to plain ssh.

## Non-Goals (v1)

- Forwarding mouse events into remote pane apps (e.g. clicking inside remote `vim`). v1 does native selection only; mouse-to-tmux forwarding is a follow-up.
- tmux copy-mode integration. We use each `Surface`'s own native scrollback plus an initial `capture-pane` seed; we never enter tmux copy-mode.
- Independent per-window views of one session for multiple WispTerm windows. v1 mirrors (standard tmux multi-client behavior). Grouped/independent sessions are v2.
- Lazy backfill of unbounded tmux history. v1 seeds N recent lines per pane on attach.
- Reusing ghostty-vt's bundled tmux engine (see Background — we hand-roll instead).
- Windows-host parity is best-effort; the remote is unix (tmux is unix-only). The local virtual-pane transport must work cross-platform (see Architecture).

## Confirmed Scope (decisions made during brainstorming)

1. **Full control-mode integration** (`tmux -CC`), not a passthrough `tmux attach`.
2. **Full mapping in v1**: windows↔tabs *and* panes↔splits (not panes-only).
3. **Trigger = per-profile toggle + auto-detect.** A "Keep session alive (tmux)" switch on the SSH profile (default off) connects via `tmux -CC new-session -A -s <name>`. Independently, the VT output stream is watched for tmux's `DCS 1000p` handshake so a manually-typed `tmux -CC` is also adopted.
4. **Strategy: hand-roll the parser in WispTerm** (no oniguruma C dependency, no dependency fork). See Background.

Operator-facing defaults (confirmed):

- Session name defaults to `wispterm`, editable per profile. Same host ⇒ one shared persistent workspace.
- Closing a single tab = `kill-window` (explicitly destroys that window's remote processes); gated by the existing close-confirm modal when a full-screen TUI is running. Quitting the app / closing the whole connection = **detach** (keep everything alive).
- No tmux or tmux `< 3.0` on the server ⇒ detect and fall back to plain ssh.
- Backpressure relies on natural ssh/tmux flow control in v1 (`%pause`/`%continue` deferred).

## Background / Prior Art

Ghostty is building exactly this feature. WispTerm's pinned `ghostty-vt` dependency (`build.zig.zon`: commit `4dcb09a`, `ghostty-1.3.2-dev`) already contains a tmux control-mode implementation under `src/terminal/tmux/`:

- `control.zig` — protocol parser, `put(byte) -> ?Notification` with variants `output{pane_id,data}`, `layout_change{window_id,layout,…}`, `window_add`, `window_renamed`, `window_pane_changed`, `begin/end`, `exit`.
- `layout.zig` — layout-string parser (`80x24,0,0{40x24,0,0,%1,…}`).
- `viewer.zig` (2283 lines) — window/pane state machine, bootstrap command sequencing, and `capture-pane` history retrieval. Owns a full `Terminal` per pane.
- `dcs.zig` — already detects the `DCS 1000p` control-mode entry and emits a `tmux.enter`.

Ghostty's own note (1.3.0 release): *"significantly more tmux control mode parsing, but not hooked up to the GUI yet."* Their GUI integration is targeted for 1.4 (≈Sep 2026) and is in active development (discussion #12038 adds `send-keys`/`split-window`/`resize-pane`).

**Why we do not reuse it.** The redistributable `ghostty-vt` *module* hardcodes the parser off:

```zig
// src/build/GhosttyZig.zig:72
// We presently don't allow Oniguruma in our Zig module at all.
// We should expose this as a build option in the future ...
vt_options.oniguruma = false;
```

`tmux_control_mode = oniguruma` (`terminal/build_options.zig:75`), and the parser depends on oniguruma (a C regex library). So `ghostty-vt.tmux` compiles to an empty `struct {}` for us. Enabling it would require forking/patching the pinned dependency (re-applied on every ghostty bump) *and* introducing oniguruma — WispTerm links no regex C library today. Additionally, ghostty's `Viewer` owns a `Terminal` per pane, which competes with WispTerm's `Surface` model; we want panes to *be* `Surface`s to inherit selection/search/AI features for free, so we would not use the `Viewer` anyway. The control protocol is simple, line-oriented, and stable; the only fiddly part is the layout string (a small recursive parse). Hand-rolling is the lower-cost, lower-coupling path. ghostty's files remain a useful reference for the bootstrap command sequence.

## Architecture

Three new pure/IO modules plus thin, precedented edits to existing seams. Parsing is side-effect-free and unit-testable; only the controller touches UI state.

| Module | Status | Responsibility |
|---|---|---|
| `src/tmux/control.zig` | new | Pure line parser. `Parser.put(byte) Allocator.Error!?Notification`. `Notification` union mirrors the events we consume (`output`, `layout_change`, `window_add`, `window_renamed`, `window_pane_changed`, `begin`/`block_end`/`block_err`, `session_changed`, `exit`). Handles `%begin/%end` blocks and **octal unescaping** of `%output` data. Imports only `std`. |
| `src/tmux/layout.zig` | new | Pure recursive parser for tmux layout strings → a tree of `{x,y,w,h,pane_id}` nodes (plus checksum verify). Inverse helper to read split orientation/ratios. Imports only `std`. |
| `src/tmux/session.zig` | new | The controller — the only module that mutates UI state. Owns the `ssh + tmux -CC` PTY; pumps bytes → `control.Parser` → notifications; demuxes `%output` to per-pane virtual PTYs; reconciles `layout.zig` output into `split_tree`; manages windows↔tabs; emits commands (`send-keys -H`, `split-window`, `new-window`, `kill-window`, `resize-pane`, `refresh-client -C`); runs the bootstrap sequence; handles detach/reconnect. |
| `src/platform/pty.zig` (+ `pty_posix.zig` and the Windows PTY backend) | modified | Add a **virtual `Pty` backend** so a `Surface` can be fed by the controller instead of an OS PTY. POSIX: one end of a `socketpair`; Windows: a loopback socket or anonymous pipe pair. Same method surface (`readOutput`/`writeInput`/`outputAvailable`/`cancelOutputRead`/`setSize`/`deinit`); `startCommand` is a no-op (no child). |
| `src/termio/ReadThread.zig` / `src/Surface.zig` | modified | Add a `DCS 1000p` detection hook on the output stream, beside the existing `remote_client.sendOutput(...)` tap (precedent that this is a clean interception point). On detection, hand the surface to a `tmux.session` controller. |
| `src/ssh_connection.zig` + profile codec (`renderer/overlays/profile_codec.zig`) | modified | Add `tmux: bool` and `session_name: []const u8` (default `"wispterm"`). Forward-compatible: missing fields ⇒ tmux off. |
| `src/config.zig` / SSH profile UI | modified | Surface the "Keep session alive (tmux)" toggle + session-name field in the profile form. |
| `src/session_persist.zig` | modified | Persist that a leaf is a tmux session (host + session_name). On restore, re-attach (`tmux -CC new -A -s <name>`) instead of re-running bare ssh. |
| `src/split_tree.zig` | modified | Add a `reconcileFromTmuxLayout(layout_tree)` entry that diffs the desired pane set/geometry against the current tree and applies minimal add/remove/move/resize ops, coexisting with manual splits. |
| `src/appwindow/tab.zig` | modified | Bridge controller window/pane events to tab create/rename/close and active-pane focus. Reuse close-confirm before `kill-window` when a TUI is running. |
| `src/test_fast.zig` / `src/test_main.zig` | modified | `_ = @import(...)` the new modules so their unit tests run. |

**Boundaries.** `control.zig`/`layout.zig` import only `std`, return data, and never touch a `Surface`. `session.zig` is the sole owner of the mapping (pane_id↔`Surface`, window_id↔tab) and the only writer of UI state. A `Surface` is almost unaware it is a tmux pane — it reads/writes its `Pty` exactly as today.

## UX Contract

- **Enable:** profile toggle (default off) ⇒ connect with `ssh -tt <host> -- tmux -CC new-session -A -s wispterm`. Auto-adopt on `DCS 1000p` from any session.
- **Use:** windows↔tabs, panes↔splits; no tmux status bar / prefix. Native split ⇒ `split-window`; new tab ⇒ `new-window`; close pane ⇒ `kill-pane`. tmux echoes `%layout-change`, which drives the redraw.
- **Survive:** close app / drop wifi / sleep ⇒ session keeps running. Reopen/reconnect ⇒ auto re-attach, layout restored, recent scrollback re-seeded. Disconnect shows a lightweight "Disconnected — reconnecting…" overlay with auto-retry + a manual reconnect control. Closing a tmux tab detaches (keeps remote alive); a separate "End remote session" action truly kills.
- **Fall back:** no/old tmux ⇒ message + plain ssh (today's behavior).

## Data Flow

- **Output:** ssh+`tmux -CC` stdout → controller read loop → `control.put()` → `%output{pane_id,data}` (octal-unescaped) → write to pane's virtual-PTY write end → that `Surface`'s `ReadThread` reads and renders. Unchanged Surface/render path.
- **Input:** `Surface` keystrokes → virtual PTY → controller → hex-encode raw bytes → `send-keys -t %id -H <hex>`. Each `Surface` writes to its own pane id, so routing is per-pane and does not depend on global focus.
- **Layout:** `%layout-change @win <layout>` → `layout.zig` parse → `split_tree.reconcileFromTmuxLayout` (minimal diff). Native split does **not** optimistically mutate locally; it sends `split-window -h/-v -t %id` and waits for tmux's `%layout-change` to materialize the new `Surface`. Divider drag ⇒ `resize-pane`, corrected by the echoed layout.
- **Windows:** `%window-add` ⇒ new tab; `%window-renamed` ⇒ tab title; window disappearance ⇒ close tab; `%window-pane-changed` ⇒ set active pane. New tab ⇒ `new-window`.
- **Resize:** WispTerm size change ⇒ `refresh-client -C <WxH>` (client cell size) ⇒ tmux re-lays-out ⇒ `%layout-change` ⇒ reconcile. Per-pane exact cell size comes from the layout string.
- **Bootstrap on attach** (modeled on ghostty's `viewer.zig` sequence): `refresh-client -C` → `list-windows` (create tabs) → per window build the split tree + a `Surface` per pane → per pane `capture-pane -p -e -J` to seed recent history → rely on control mode to stream subsequent `%output`/`%layout-change`.

## Error Handling & Edge Cases

- **No / old tmux:** no `DCS 1000p` within a timeout, or `version < 3.0` from `display-message -p '#{version}'` ⇒ message + fall back to plain ssh.
- **Connection drop:** controller read hits EOF/error ⇒ mark all panes detached, freeze input, show overlay; `Surface`s are **not** destroyed. Retry with backoff: re-spawn ssh + `tmux -CC new -A -s <name>` → re-bootstrap → reconcile any server-side layout change → resume.
- **App quit:** clean detach (close ssh; tmux keeps running). `session_persist` records the tmux leaf for re-attach next launch.
- **Pane process exit:** tmux drops the pane ⇒ `%layout-change` without it ⇒ reconcile removes the `Surface`/split; empty window ⇒ tab closes.
- **Close tab = `kill-window`:** confirm via the existing close-confirm modal if a TUI is running. Full-connection quit is detach, not kill.
- **Escape/binary safety:** octal-unescape inbound `%output`; hex-encode outbound `send-keys`; never interpolate raw user bytes into command strings.
- **Backpressure:** rely on natural ssh/tmux flow control in v1; `%pause`/`%continue` deferred.
- **Multi-client:** two WispTerm windows on the same profile mirror (standard tmux). Documented v1 behavior.

## Testing

- **Unit (TDD, pure):** `control.zig` (protocol fixtures → `Notification`s, incl. `%begin/%end`, octal unescape), `layout.zig` (layout strings → trees, checksum), `split_tree` reconcile (layout diff → ops), hex-encode for `send-keys`, command-string escaping.
- **Integration:** a **fake tmux control server** — a scripted byte stream fed to `session.zig` — asserting resulting tabs/splits/`Surface`s/active-pane. No real tmux in CI. Covers bootstrap, split, new-window, pane-exit, resize, detach, reconnect/re-bootstrap.
- **Manual GUI (the usual WispTerm GUI-verify step):** the WispTerm client (macOS/Windows) against a real Linux server running `tmux -CC` — split/new-window/resize/detach/close-app/reconnect/drop-wifi, plus old-tmux and no-tmux fallback. (This repo has no Linux GUI backend, so GUI verification runs on macOS/Windows hosts.)

## Rollout

Entirely behind the per-profile opt-in toggle (default off) plus auto-detect. Zero impact on existing users until enabled. Both suites (`zig build test`, `zig build test-full`) must stay green; GUI verify follows the project's standard pending-verify convention.

## Suggested Implementation Order (for the plan)

1. `tmux/control.zig` + `tmux/layout.zig` (pure, TDD).
2. Virtual `Pty` backend (POSIX socketpair; Windows pipe/socket pair) with tests.
3. `tmux/session.zig` controller against the fake control server (TDD): bootstrap, demux, command emission.
4. Wire controller → tabs / `split_tree` / `Surface` (windows↔tabs, panes↔splits, active pane).
5. Bootstrap history seeding (`capture-pane`) + resize (`refresh-client -C`).
6. Detach / reconnect (overlay, backoff, re-bootstrap) + `session_persist` re-attach.
7. Profile toggle + session-name field + `DCS 1000p` auto-detect hook.
8. GUI verify on a real server.

## Open Questions / Future (v2)

- Mouse-event forwarding into remote pane apps.
- Independent per-window session views (grouped sessions) for multi-window.
- Lazy backfill of full tmux history beyond the initial seed.
- `%pause`/`%continue` flow control for very high-throughput panes.
- Optional convergence with ghostty 1.4's tmux engine once it ships and exposes the build option.
