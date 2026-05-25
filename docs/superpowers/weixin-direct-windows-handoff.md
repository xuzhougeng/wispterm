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
- **Blocker for the full loop:** no GUI login entry point exists. The QR-login
  backend (`controller.startLoginAsync()` / `loginSnapshot()`) is done, but
  nothing calls it. `startWeixin` only calls `controller.start()`, which loads a
  *persisted* binding from `weixin.json` and stays idle if there is no token.
  → You must either build the QR panel, or pre-seed `weixin.json` (see Phase 1).

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

## Phase 1 — Login / binding  ⚠️ BLOCKED until a login entry exists

Pick one:

**Option A (recommended) — build the QR panel + "Connect WeChat" action.**
Backend is ready; you only need UI glue:
- On the action, call `controller.startLoginAsync()` (spawns the login thread).
- Each frame, call `controller.loginSnapshot(arena)` → `{status, qr_string, qr_img_base64}`.
  Render `qr_img_base64` (base64 PNG; decode via `src/image_decoder.zig`) or the
  raw `qr_string` as a QR.
- `status` transitions `wait → scaned → confirmed` (or `expired`). On
  `confirmed`, the controller persists `weixin.json` and starts polling
  automatically (`controller.confirmLogin`, `controller.zig:191`).
- Add an "Unbind" action → `controller.unbind()`.

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

---

## Phase 3 — Known gaps (won't work until implemented)

All marked `TODO(weixin-windows)`:

1. **`/term` and `/keys` do nothing** — `wxFindTerminalSurface` returns `null`
   (`AppWindow.zig:2037`). Needs: resolve the active writable terminal surface
   and write to its PTY (mirror the remote path's per-surface `write_fn`).

2. **No AI progress streaming** — `wxTranscript` returns `""`
   (`AppWindow.zig:2055`). Needs: render `activeAiChat()` into the
   `You:/AI:/Status:` label format that `src/weixin/reply_progress.zig` parses,
   then have the poller act on `expect_ai_progress`.

3. **Auto-bind owner not persisted** — without `weixin-allowed-user`, any sender
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
