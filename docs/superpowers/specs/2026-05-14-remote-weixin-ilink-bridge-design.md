# Remote Weixin iLink Bridge Design

Date: 2026-05-14
Status: Draft

## Goal

Add a Weixin iLink Bot entry point to Phantty Remote so a user can scan a
Weixin authorization QR code, bind the bot to the Remote web backend, and send
messages from Weixin as another way to drive Phantty's remote AI Agent and
terminal sessions.

The first version lives under `remote/`. It should not put iLink protocol,
polling, QR binding, or token storage into the Zig terminal core.

## Context

Phantty already has two relevant pieces:

- `remote/src/server/index.ts` is an independent Node relay backend. It serves
  the web console, authenticates the admin, holds in-memory Remote sessions,
  and relays WebSocket messages between browser clients and Phantty.
- The Zig RemoteClient connects outbound to `/ws/phantty?session=<key>`.
  Phantty sends layout snapshots, terminal output, and AI-chat snapshots. It
  receives `input-bytes` routed to a terminal surface or to an AI-chat surface.

The existing AI chat tab is already represented as a remote surface with
`kind: "ai_chat"`. The web console can send text to it through the same
`input-bytes` protocol. That means the Weixin bridge can reuse the remote
session and AI-chat input path instead of inventing a second AI agent runtime.

## Ghostty Comparison

Ghostty does not implement a web remote console or IM bridge. The relevant
Ghostty design principle is separation of concerns: terminal surfaces,
rendering, input, and app runtime stay separate.

For Phantty this means:

- Keep iLink Bot protocol handling outside VT, PTY, renderer, and normal input
  paths.
- Use the existing Remote relay boundary for cross-device control.
- Keep the Zig terminal side responsible for terminal and AI-chat execution;
  let the Remote web backend own QR binding, token persistence, and polling.

This feature is in `remote/`, which is Phantty-specific and has no direct
Ghostty equivalent.

## Non-Goals

- Do not implement iLink binding inside the Zig app in v1.
- Do not create a second AI agent engine in the Remote server.
- Do not expose unauthenticated admin APIs for binding or settings.
- Do not require a browser client to stay connected for Weixin messages to
  reach Phantty.
- Do not support Cloudflare Worker deployment in the first implementation
  pass. The Node server is the source of truth for v1.
- Do not add group-chat support in v1. Only the bound Weixin user is allowed.

## Approaches Considered

### Recommended: Remote Node Bridge

Implement the iLink bridge in `remote/src/server/bridge/weixin/`, store binding
state on disk, and route Weixin input through the existing `RemoteSession`
object.

This matches the current architecture: `remote/` is already the web backend,
Node has straightforward HTTP, crypto, file IO, timers, and testing support,
and Phantty's Zig client already treats Remote as the network boundary.

### Alternative: Zig Bridge

Implement `src/bridge/weixin` in the Windows Zig app. This would keep all
control local to the terminal process, but it requires adding HTTP client
flows, QR management, token storage, polling, and a web management surface to
the terminal app. It also couples an IM protocol to the terminal core.

### Alternative: Worker Bridge

Implement iLink binding in the Cloudflare Worker deployment. This is attractive
for always-on hosting, but durable polling, token persistence, and timed retry
behavior would need Worker-specific storage and scheduling. It is out of scope
for v1 and should be specified separately after the Node bridge is working.

## Architecture

Add these Node server modules:

```text
remote/src/server/bridge/weixin/
├── client.ts      # iLink Bot HTTP API wrapper
├── types.ts       # iLink request/response and stored binding types
├── binding.ts     # file-backed binding and settings store
├── poller.ts      # long-poll loop and session-expiry handling
├── agent.ts       # Weixin text -> Remote session action
└── routes.ts      # authenticated management API routes
```

`remote/src/server/index.ts` should shrink by extracting reusable route and
session helpers where needed, but the bridge should not require a full server
framework.

The `RemoteSession` class gains methods that are useful beyond Weixin:

- `sendInput(surfaceId: string, text: string): boolean`
- `findAiChatSurface(): { id: string; title: string } | null`
- `findDefaultWritableSurface(): { id: string; title: string } | null`
- `latestAiChatTranscript(): string`
- `sendNotice(message: string): void`

These wrap current in-memory `lastLayout`, `phantty`, and browser broadcast
state, keeping Weixin routing out of low-level WebSocket event handlers.

## Binding Flow

The management API is available only to an authenticated Remote admin:

- `POST /api/weixin/bind/start`
- `GET /api/weixin/bind/status?qrcode=<session>`
- `DELETE /api/weixin/bind`
- `GET /api/weixin/settings`
- `PUT /api/weixin/settings`

Flow:

1. Admin opens the Remote web console settings page.
2. Admin clicks "Bind Weixin".
3. Server calls iLink `get_bot_qrcode`.
4. Server returns QR session id, QR content, and a rendered data URL.
5. Browser polls `bind/status`.
6. On iLink `confirmed`, server saves `bot_token`, `base_url`, `ilink_user_id`,
   `ilink_bot_id`, and `bound_at`.
7. Server starts or restarts the Weixin poller.

The server should never return `bot_token` to the browser.

## Polling Flow

The poller starts when all of these are true:

- Weixin bridge is enabled.
- A valid binding exists.
- At least one Remote session key is configured for Weixin routing.

The poller stores iLink `get_updates_buf` so restarts do not replay old
messages unnecessarily.

For each incoming message:

1. Reject group messages.
2. Reject bot echoes.
3. Reject any sender other than the bound Weixin user when `ilink_user_id` is
   present.
4. Extract text from a text item or recognized voice text.
5. Dispatch via the Weixin agent router.
6. Send a text reply through iLink.

If iLink returns the known session-expired code, disable the Weixin bridge and
require the admin to rebind.

## Weixin Agent Router

The first implementation should keep command semantics predictable:

| Input | Behavior |
|---|---|
| `/help` | Return Weixin command help. |
| `/status` | Return binding state, target Remote session, Phantty connection state, AI-chat availability. |
| `/sessions` | List active Remote session keys in masked form. |
| `/use <session>` | Select the configured target session for this Weixin binding. |
| `/ai <text>` | Send text to the target session's AI-chat surface. |
| plain text | Same as `/ai <text>` by default. |
| `/term <text>` | Send text plus Enter to the default writable terminal surface. |
| `/keys <text>` | Send raw text without appending Enter to the default writable terminal surface. |

The default route should be AI chat because it is safer than writing directly
to a terminal. Direct terminal input must require an explicit command.

When no AI-chat surface exists, the router replies with a short instruction:
open an AI Chat tab in Phantty or use `/term` for explicit terminal input.

## AI Agent Integration

The Remote server does not call an LLM in v1. It sends Weixin text to Phantty's
existing AI-chat surface:

```json
{
  "type": "input-bytes",
  "surfaceId": "aichat0000000000",
  "encoding": "hex",
  "data": "<utf8 text plus carriage return>"
}
```

Phantty remains responsible for:

- Model provider configuration.
- Agent tool permissions.
- Terminal snapshots.
- Tool execution.
- AI-chat transcript rendering.

To reply to Weixin, the server reads `latestAiChatTranscript()` from the latest
layout snapshot and sends back the newest assistant response if it can detect
one. If no new assistant response is visible within a configurable timeout, the
server sends "已发送给 Phantty AI Agent，等待结果中。"

This keeps v1 robust even if the AI-chat snapshot format changes modestly; the
bridge can still confirm dispatch.

## Storage

Add a server-side data directory under `remote/` runtime storage, defaulting to
`./data` for Node deployments and overridable with `REMOTE_DATA_DIR`:

```text
data/
└── weixin/
    ├── binding.json
    ├── settings.json
    └── sync_buf
```

`binding.json` stores the iLink token and binding identifiers. File mode should
be owner-readable where the platform supports it. The token is not logged.

`settings.json` stores:

```json
{
  "enabled": false,
  "target_session": "",
  "reply_timeout_ms": 120000
}
```

If `target_session` is empty and exactly one Remote session is active, the
server uses that session. If zero or multiple sessions are active, `/status`
and plain Weixin input ask the user to choose one with `/use <session>`.

## Web UI

Add a compact Weixin section to the Remote web console drawer or a settings
panel:

- Bridge enabled toggle.
- Binding summary.
- "Bind / Rebind" button.
- QR code panel.
- "Unbind" button.
- Target Remote session selector.

The UI must reuse the existing login session. It must not show the iLink token.

## Security

- Admin APIs require the existing Remote login cookie.
- Weixin messages are accepted only from the bound user id when available.
- Direct terminal writes are explicit (`/term` or `/keys`), never the default.
- Bot token and sync buffer are server-side only.
- Logs should include message ids, message type, and high-level status, not full
  private message bodies by default.
- If the target session is disconnected, Weixin replies with a clear status
  instead of queuing terminal input indefinitely.

## Error Handling

- QR API failure: return a user-facing error to the web UI.
- QR expired: show expired state and allow generating a new QR code.
- Missing binding: poller stays idle.
- Binding changed: restart poller with the new token and clear `sync_buf` so a
  new account does not inherit the previous account's update cursor.
- iLink session expired: disable bridge, preserve binding summary, and require
  rebind.
- No target session: reply with setup instructions.
- No Phantty connection: reply that Phantty is offline for the selected session.
- Send failure: preserve iLink error detail in logs and return a concise failure
  reply when possible.

## Testing

Node tests:

- iLink client builds the expected QR, status, getupdates, and sendmessage
  requests.
- Binding store persists and hides tokens from public summaries.
- Poller ignores group messages, bot echoes, and unexpected users.
- Router sends plain text to AI chat, `/term` to terminal, and rejects missing
  sessions cleanly.
- Session expiry disables the bridge.

Remote client tests:

- Existing web console typecheck and build still pass.
- Weixin settings UI renders authenticated states and handles QR polling.

Manual checks:

- Bind from the Remote web console using a phone scan.
- Send plain text from Weixin and see it arrive in Phantty AI Chat.
- Send `/term pwd` or equivalent to an active shell and confirm explicit
  terminal routing.
- Disconnect Phantty and confirm Weixin returns an offline status.
- Rebind after token expiry.

## Acceptance Criteria

- Admin can bind Weixin from the Remote web UI by scanning a QR code.
- The Node Remote server persists the iLink binding and restarts polling after a
  process restart.
- A bound Weixin user can send plain text and have it routed to the selected
  Remote session's AI-chat surface.
- Explicit terminal commands can route input to a writable terminal surface.
- Unexpected Weixin users, group messages, and bot echoes are ignored.
- iLink session expiry disables the bridge and surfaces a clear rebind state.
- Existing browser Remote console behavior remains compatible.
