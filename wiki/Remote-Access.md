# Remote Access (Sharing a Session)

*English · [中文](Remote-Access-zh)*

> Optionally share a WispTerm session to a browser over a Cloudflare-hosted relay. Disabled by default.

## What it is

Remote access lets you view and drive a running WispTerm session from a browser
(for example, your phone) through a Cloudflare-hosted relay. It is an **opt-in**
feature and is **disabled by default** — nothing leaves your machine until you
enable it.

When enabled, WispTerm creates one shared outbound RemoteClient for the running
instance. All tabs and splits publish their PTY output through that client.

Remote access works on **Windows and macOS** (the macOS transport was added in
v1.23.0). Linux support is still in progress.

## Enabling it

Set these keys in the [[config|Configuration]]:

```text
remote-enabled = true
remote-server-url = https://remote.example.com
remote-server-fingerprint = sha256:...     # optional: pin the relay identity
remote-device-name = Workstation           # optional: friendly name
```

- `remote-enabled` — start the RemoteClient.
- `remote-server-url` — the Cloudflare relay URL.
- `remote-server-fingerprint` — expected relay fingerprint for identity pinning.
- `remote-device-name` — friendly device name sent with pairing.

## Session keys

By default the session key is random for every process. The generated key is
printed in the debug console and shown in the in-window remote status pill.
**Click the status pill to copy** the active session key, or run **Copy Remote
Key** from the command center.

Set `remote-session-key = mypass` to use predictable keys across multiple
concurrent local instances: the first process gets `mypass`, the next `mypass_1`,
then `mypass_2`, and so on. This only chooses the relay session key the browser
enters — it is separate from the relay's own web-admin login password.

## Phone mirroring

WispTerm Remote **mirrors the local window** because the desktop app is the
source of truth: the local PTY, VT state, scrollback, cursor, and split layout
are captured there and streamed to the browser. The mobile UI can refocus a
single surface instead of squeezing every split onto a small screen, but it does
not create a separate phone-sized terminal grid (see [[FAQ]]).

## WeChat direct control

WispTerm can also be driven from WeChat, independently of the relay above. Run
**Connect WeChat** from the command center and scan the QR code to bind your
account; WispTerm then polls WeChat for incoming messages and feeds them to a
bound [[Copilot conversation|AI-Copilot]], replying back over WeChat. Manage the
binding with the other command-center entries: **WeChat: Start** and **WeChat:
Stop** pause or resume polling without losing the binding, **WeChat: Status**
shows the connection state, and **WeChat: Unbind** clears the saved binding.

When Copilot is waiting for a tool approval, WispTerm can push that approval
prompt to WeChat too. Reply `Y`/`yes` to approve or `N`/`no` to deny, and the
reply is applied to the active desktop approval flow.

---
*See also: [[Configuration]] · [[AI-Copilot]] · [[FAQ]]*
