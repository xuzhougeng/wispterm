# WeChat direct-connect (ilink) — Windows handoff & test checklist

Status as of merge of `weixin-direct-ilink` into `main` (PR #42).

The transport + all pure logic compile and pass `zig test` on Linux. Everything
below needs a **Windows runtime** to validate, because the desktop GUI only
builds for Windows (`build.zig`: `uses_windows_backend = os_tag == .windows`).

---

## TL;DR — what state the feature is in

- Ships **off by default**: `weixin-direct-enabled = false`.
- Backend is wired: config → `App.startWeixin` → `weixin.Controller` →
  `ilink.Client` + `poller.Poller`, with Control marshalled to the UI thread.
- GUI login/control entries now exist: Command Center → **Connect WeChat**
  starts `controller.startLoginAsync()` and renders the QR login panel. Command
  Center → **WeChat: Start** starts polling from the saved binding,
  **WeChat: Stop** stops polling while keeping the binding,
  **WeChat: Status** shows the current state, and **WeChat: Unbind** clears the
  stored binding.
- `/term` and `/keys` now resolve the active terminal surface and write through
  the same queued PTY input boundary used by remote input.
- AI follow-up sends are wired: after the ACK, the poller compares AI transcript
  snapshots against the baseline and sends progress/final replies back through
  iLink. This still needs live Windows/WeChat smoke testing across slow tool
  calls and final replies.
- Live Windows fixes applied after initial smoke:
  - QR panel renders the ilink QR payload directly instead of trying to decode
    it as a PNG.
  - Config hot-reload only reacts to the actual config file mtime, so WeChat
    state writes no longer spam config reloads.
  - Inline config comments after values are stripped, so
    `background-image-mode fill   # fill | fit | center | tile` parses as
    `fill`.
  - App shutdown uses a bounded WeChat process-exit path. It asks Windows to
    cancel synchronous I/O on the poll/login/follow-up threads, waits briefly,
    and only detaches/leaks the controller if a long-poll refuses to return
    before process exit.

---

## Phase 0 — Build & launch sanity (no WeChat account needed)

1. On Windows, build the GUI exe:
   ```
   zig build -Doptimize=ReleaseFast
   ```
   Confirm it links (Windows system libs in `build.zig:14`) and runs.

2. Enable the direct path. Either via the config file
   `%APPDATA%\phantty\config` or CLI flags:
   ```
   weixin-direct-enabled true
   # optional:
   weixin-base-url <override>          # default https://ilinkai.weixin.qq.com
   weixin-reply-timeout-ms 120000      # clamped [5000,180000]
   weixin-allowed-user <wechat-uid>    # pin owner; empty = auto-bind first sender
   ```
   CLI equivalents: `--weixin-direct-enabled <bool>` etc. (`src/config.zig:1204`).

3. **Mutual-exclusion check:** also set `remote-enabled true` and relaunch.
   Expect the stderr line and the weixin path staying off:
   `weixin-direct disabled: remote-enabled takes precedence`
   (`src/App.zig:296`). Then turn remote back off for the real tests.

4. **Idle check:** with `weixin-direct-enabled true` and no `weixin.json`,
   launch should NOT crash and should NOT poll (no token → `controller.start()`
   returns early, `src/weixin/controller.zig:152`).

---

## Phase 1 — Login / binding

Pick one:

**Option A (recommended) — use the QR panel + "Connect WeChat" action.**
- On the action, call `controller.startLoginAsync()` (spawns the login thread).
- Each frame, call `controller.loginSnapshot(arena)` → `{status, qr_string, qr_content}`.
  `qrcode_img_content` is a QR payload string, not an inline PNG; `src/weixin/qr_panel.zig`
  encodes it with `src/weixin/qr_code.zig`, and
  `src/renderer/weixin_qr_renderer.zig` renders the QR matrix directly.
- `status` transitions `wait → scaned → confirmed` (or `expired`). On
  `confirmed`, the controller persists `weixin.json` and starts polling
  automatically (`controller.confirmLogin`, `controller.zig:191`).
- Add an "Unbind" action → `controller.unbind()`.
- Command Center also exposes "Start", "Stop", and "Status" actions for the
  saved binding, so you can pause/resume polling without clearing the token.

**Option B (quick smoke without UI) — pre-seed the state file.**
If you already have a bot token, drop a `weixin.json` at
`%APPDATA%\phantty\weixin.json`:
```json
{ "bot_token": "<token>", "base_url": "https://ilinkai.weixin.qq.com",
  "owner_user_id": "", "bot_id": "<bot id>", "sync_buf": "" }
```
(schema = `types.Binding`, written/read by `src/weixin/state_store.zig`).
Relaunch; `controller.start()` will load it and begin polling.

**Verify after login:**
- `weixin.json` is created/updated and survives a restart (sync cursor advances).
- Owner binds: if `weixin-allowed-user` is empty, the first 1:1 sender is
  accepted for the session. ⚠️ Note the gap below: that auto-bind is NOT yet
  persisted, so it re-opens each launch.

---

## Phase 2 — Inbound message → command routing (needs Phase 1)

From the bound WeChat, send to the bot and verify replies:

| Send        | Expect |
|-------------|--------|
| `/ping`     | pong / liveness reply |
| `/help`     | command list |
| `/status`   | connection + surface status |
| `/ai <txt>` | opens/uses the AI agent tab, routes text in |
| any text    | routed to AI as default |
| `/stop`     | cancels the in-flight AI turn |

What this exercises: `wxIsConnected`, `wxFindAiSurface`, `wxOpenAiAgent`,
`wxSendInput` (all in `AppWindow.zig:2027+`), marshalled to the UI thread via the
synchronous `.weixin_control` message; routing in `src/weixin/agent.zig`.

Expected logs while testing:
- `weixin poll received N message(s)` when iLink delivers inbound messages.
- `weixin reply sent: N bytes` for the immediate ACK/command reply.
- `weixin AI followup started` then `weixin AI followup final sent: N bytes`
  when the AI transcript produces a final answer.
- `warning(stream): unimplemented mode: 9001` can appear from terminal VT input
  and is unrelated to WeChat.

If replies feel delayed, distinguish the paths:
- Inbound message delivery depends on iLink long-poll waking. The local poller
  is not intentionally sleeping 5 seconds after successful polls.
- The AI final reply is transcript-driven and checked once per second after the
  immediate ACK.
- Repeated `Config file changed, reloading...` after WeChat messages should no
  longer happen; if it does, inspect `%APPDATA%\phantty` writes and
  `src/config_watcher.zig`.

Shutdown smoke:
- Close the window after WeChat direct is connected and idle. The process should
  exit without needing Ctrl+C and without a post-close segfault.
- Repeat while a message is being handled or while an AI follow-up is waiting.
  A shutdown timeout log is acceptable only if iLink is still blocking, but the
  process should still terminate promptly.

---

## Phase 3 — Known gaps

Current gaps:

1. **Auto-bind owner not persisted** — without `weixin-allowed-user`, any sender
   is accepted within a session but the owner isn't written back to
   `weixin.json`. Needs a bind-callback from the poller to `controller.persist`.
   (Security note: until then, set `weixin-allowed-user` explicitly for any
   non-throwaway test.)

---

## Debugging tips

- Startup decisions print to **stderr** (`std.debug.print` in `App.startWeixin`).
- State file: `%APPDATA%\phantty\weixin.json` (`platform/dirs.zig`,
  `app_dir_name = "phantty"`).
- ilink endpoints/headers live in `src/weixin/ilink_client.zig` +
  `ilink_codec.zig`; `errcode == -14` means the session expired
  (`poller.SESSION_EXPIRED_ERRCODE`).
- Poll loop + stop/generation handling: `src/weixin/poller.zig`.

## Suggested order on Windows

Phase 0 (build + flags + mutual exclusion) → Option A or B for login → Phase 2
command smoke → then close the Phase 3 gaps as needed.
