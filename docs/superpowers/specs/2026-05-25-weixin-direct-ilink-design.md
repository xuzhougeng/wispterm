# WeChat Direct (Embedded ilink) Design

## Goal

Add a second, independent WeChat path that embeds the ilink protocol client
**inside the Phantty desktop process** (Zig). When `weixin-direct-enabled = true`,
Phantty long-polls `https://ilinkai.weixin.qq.com` directly, routes inbound
WeChat messages into the local AI-chat / terminal surfaces, and replies over
ilink. No Cloudflare Worker, no `wss` relay, and no web login are involved.

This path is **mutually exclusive** with the existing remote (Worker) path:
exactly one of them may drive a given WeChat bot, because a single `bot_token`
can have only one active `getUpdates` consumer.

## Relationship to the existing remote bridge

The existing bridge (`docs/superpowers/specs/2026-05-14-remote-weixin-ilink-bridge-design.md`,
implemented in `remote/src/server/bridge/weixin/`) runs the ilink poller and all
routing intelligence **on the Cloudflare Worker**. In that model
`src/remote_client.zig` is a dumb relay: a surface registry plus `input-bytes`
and `open-ai-agent` frames. The routing brains (command parsing, target
resolution, AI-reply progress streaming) live in the TypeScript worker
(`agent.ts`, `poller.ts`).

The direct path has no worker, so that intelligence is **ported into Zig**. The
TypeScript modules are the reference implementation; their unit tests
(`remote/test/server/weixin_*.test.ts`) are the source of truth for behavior we
must preserve.

## Decisions

These were settled during brainstorming and are fixed for v1:

- **Placement:** native embed in the Phantty Zig process (no extra process, no
  relay).
- **Platform:** cross-platform via `std.http.Client` (its bundled TLS), not the
  Windows-only WinHTTP transport used by `remote_transport_windows.zig`.
- **Feature scope:** full parity with the current WeChat experience, adapted to
  a single local app — `/ai`, `/term`, `/keys`, `/stop`, `/ping`, `/status`,
  `/help`, default-text→AI, and AI-reply progress streaming. `/sessions` and
  `/use` are dropped (there is only one local app).
- **Login UX:** an in-app QR panel/window.
- **Coexistence:** mutually exclusive with `remote-enabled`. If both are enabled,
  **remote wins** and the direct path is disabled with a warning.
- **Authorization:** the first 1:1 sender after login is auto-bound as the owner
  and persisted; afterward only that `user_id` is accepted. A configured
  `weixin-allowed-user` overrides auto-bind.
- **Internal structure (Approach 1):** factor a shared in-process `LocalControl`
  view out of `App`/`remote_client` that both the remote client and the new
  weixin controller consume, so routing/AI-open/transcript logic does not drift.

## Architecture

### Module layout — `src/weixin/`

| File | Responsibility | TS reference |
|------|----------------|--------------|
| `ilink_client.zig` | HTTP over `std.http.Client`: `getBotQrcode`, `pollQrStatus`, `getUpdates` (≈35s long-poll), `sendMessage`, `sendTyping`. JSON encode/decode of ilink envelopes. | `client.ts` |
| `poller.zig` | Poll loop with `generation`/staleness cancellation, sync-buf handling, session-expired (errcode −14) → disable. | `poller.ts` |
| `agent.zig` | Command routing (`/ai /term /keys /stop /ping /status /help`) + default-text→AI + target resolution. `/sessions` `/use` removed. | `agent.ts` |
| `reply_progress.zig` | AI-reply progress streaming: transcript section parsing, diffing against a baseline, and 10/30/60/120s checkpoints. | `poller.ts` (`aiReplyProgress`, `startAiFollowup`) |
| `binding.zig` | Owner auto-bind, message filtering (`shouldHandleWeixinMessage`), text extraction (text item type 1 + voice-transcript item type 3). | `poller.ts`, `binding.ts` |
| `state_store.zig` | Persist/load `bot_token`, bound `owner_user_id`, and `sync_buf` to a `0600` state file. | `binding.ts` store |
| `controller.zig` | Owns the background thread; wires poller → agent → `LocalControl`; lifecycle (start / stop / login / unbind). | (worker glue) |

### Shared in-process control core (the Approach-1 refactor)

Define a `LocalControl` abstraction over the surface registry that `App` already
holds and `remote_client` already borrows. Both `remote_client` and
`weixin/controller` consume it.

Already present (reused as-is):
- `sendInput(surface_id, bytes)` — the existing sink `write_fn` path
  (`remote_client.zig:189` `registerSurface`, dispatch at `remote_client.zig:290`).
- `openAiAgent(request_id) → status` — existing `registerAiAgentOpener`
  (`remote_client.zig:213`).

New accessors to add (additive; this is the only change to existing code):
- `findAiChatSurface() → ?{ id: [16]u8, title }` — query over the surface
  registry.
- `latestAiChatTranscript() → []const u8` — reads `ai_chat.zig`'s in-memory
  transcript. The worker had to reconstruct this from published output frames;
  locally it is read directly.
- `onLayout(listener)` — fires on surface add/remove and AI transcript change,
  used by `reply_progress.zig`.

### Login / QR flow

1. User triggers **"Connect WeChat"** (command-palette action; optional keybind).
2. `ilink_client.getBotQrcode(bot_type = 3)` → QR image bytes / URL.
3. The **QR panel** (see UI section) renders the QR and live status;
   `pollQrStatus` loops `wait → scanned → confirmed`.
4. On `confirmed`: persist `bot_token` via `state_store`, dismiss the panel, start
   the poll loop.
5. On expiry or cancel: close the panel and offer retry.

### Data flow (steady state)

```
ilink getUpdates ──▶ binding filter ──▶ agent route ──┬─▶ openAiAgent / sendInput(ai, text\r)
   (poller thread)      (owner check)   (cmd parse)    ├─▶ sendInput(terminal, ...)   [/term /keys]
        ▲                                              └─▶ immediate reply (sendMessage)
        │                                                          │
   sync_buf persist                          reply_progress: diff transcript at
                                             checkpoints ──▶ sendMessage(progress / final)
```

Target resolution in v1 routes to the **focused window's** AI-chat surface,
opening one via `openAiAgent` if absent. Multi-tab/multi-window routing is out of
scope.

## Configuration & persistence

New keys in `src/config.zig`, alongside the existing `remote-*` keys:

- `weixin-direct-enabled: bool = false`
- `weixin-base-url: ?[]const u8 = null` (defaults to `https://ilinkai.weixin.qq.com`)
- `weixin-reply-timeout-ms: u32 = 120000` (clamped to `[5000, 180000]`, matching the TS bridge)
- `weixin-allowed-user: ?[]const u8 = null` (empty ⇒ first-messenger auto-bind)

**Secrets are never stored in config.** `bot_token`, `owner_user_id`, and
`sync_buf` live in a `0600` state file in the app data/state directory, using the
same directory resolution `session_persist.zig` uses for session files.

**Mutual exclusion:** at startup, if both `remote-enabled` and
`weixin-direct-enabled` are true, log a warning and **disable the direct path**
(remote wins). This guarantees one bot is never double-polled. The decision is
surfaced in `/status`.

## Authorization & security

- The first 1:1 sender after login is persisted as `owner_user_id`; afterward
  only that id is accepted.
- `weixin-allowed-user`, when set, overrides auto-bind.
- Group messages and bot self-echo are rejected (carried from
  `shouldHandleWeixinMessage`).
- `bot_token` is never logged; the state file is `0600`.
- Trust caveat (same as remote): an authorized WeChat sender obtains terminal and
  AI control. This is documented and gated behind the explicit toggle plus owner
  binding.
- An **"Unbind / disconnect"** action clears `owner_user_id` and stops the loop.

## QR panel UI

A lightweight in-app panel, a sibling to `markdown_preview_panel.zig` /
`browser_panel.zig`, that:

- decodes the QR image via `image_decoder.zig` and renders it,
- shows status text (`等待扫码 / 已扫码 / 已确认 / 已过期`),
- auto-closes on `confirmed` and offers retry on expiry.

It reuses the existing panel and image-decoder machinery rather than a new
OS-native modal window.

## Threading

The poller runs on its own background thread, mirroring `remote_client`'s thread
+ queue + heartbeat patterns. All `sendInput` / `openAiAgent` calls marshal onto
the app thread via the existing threading/mailbox mechanism (`threading.zig`,
xev-mailbox pattern). `generation` counters cancel in-flight work on stop/disable
(direct port of the TS staleness logic in `poller.ts`).

## Error handling

- Network/HTTP errors → backoff-and-retry (5s), matching `poller.ts`.
- ilink errcode −14 (session expired) → persist disabled, stop loop, status
  message.
- Long-poll timeout → immediate re-poll, clamped by `longpolling_timeout_ms`.
- QR expiry → panel retry.
- App data dir unwritable → login fails loudly (token cannot persist); the failure
  is surfaced in status.

## Testing

Per the `phantty-test-execution-env` note, tests are compile-only on this host
except pure modules run via `zig test`.

- **Pure-logic unit tests (`zig test`):** `agent.zig` command parsing,
  `binding.zig` filtering + auto-bind, `reply_progress.zig` transcript diffing +
  checkpoints, and ilink JSON encode/decode. These mirror the assertions in
  `remote/test/server/weixin_*.test.ts` — port them.
- **`ilink_client.zig` / `poller.zig`:** thread/network code stays compile-only on
  this host. Structure with an injected client + scheduler (like the TS
  `WeixinPollerOptions`) so the loop logic is unit-testable without sockets.

## Execution phases

1. **Refactor:** extract `LocalControl` + new read accessors; both
   `remote_client` and a stub weixin controller compile against it.
2. **ilink_client + state_store + login/QR panel:** reach a persisted
   `bot_token`.
3. **poller + binding + agent (core commands + default→AI):** end-to-end control.
4. **reply_progress:** AI-reply streaming.
5. **Config wiring + mutual-exclusion guard + status surfacing.**

## Non-goals (v1)

- Media send/receive (images, files) over ilink CDN with AES — text and
  voice-transcript only, matching the current bridge.
- Multi-tab/multi-window routing (`/sessions`, `/use`).
- Running both remote and direct paths against the same bot simultaneously.
