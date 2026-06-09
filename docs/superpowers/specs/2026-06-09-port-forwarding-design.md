# Port Forwarding Design

## Summary

Add a silent SSH port-forwarding manager to WispTerm. The feature opens as a
dedicated non-terminal tab, similar to Skill Center, and manages a global list of
rules bound to saved SSH profiles. Rules run in the background even when the
management tab is closed.

The primary use case is reverse forwarding a local proxy/VPN endpoint to a
server:

```text
Reverse (-R): server 127.0.0.1:7890 -> local 127.0.0.1:7890
```

The secondary use case is regular local forwarding for remote development
services:

```text
Local (-L): local 127.0.0.1:8888 -> server 127.0.0.1:8888
```

## Context

Issue #177 asks for tunnel and port-forwarding support in both directions:

- Remote service -> local browser or local service.
- Local VPN/proxy -> remote server, so the server can use a local port such as
  `127.0.0.1:7890`.

WispTerm already has automatic local loopback forwarding in `src/ssh_tunnel.zig`
for URLs clicked/opened from SSH profile sessions. That path is URL-driven and
only creates `ssh -L` tunnels. It is intentionally separate from this design:
existing URL click behavior should not change.

Ghostty comparison: Ghostty does not provide a port-forwarding management page.
Its SSH integration wraps OpenSSH through `ghostty +ssh` for shell integration,
environment forwarding, and terminfo installation. WispTerm should follow the
same general principle here: use OpenSSH helper processes for forwarding rather
than implementing the SSH protocol in the terminal core.

## Goals

- Provide a dedicated `Port Forwarding` tab opened from the Command Center.
- Keep forwarding silent and background-driven.
- Store forwarding rules separately from SSH profiles.
- Do not change the existing SSH profile configuration page.
- Support both `local` (`ssh -L`) and `reverse` (`ssh -R`) rules.
- Allow `enabled && auto_start` rules to start when WispTerm starts.
- Reuse saved SSH profile metadata, including password auth and ProxyJump.
- Keep Windows OpenSSH compatibility: no ControlMaster/ControlPersist/ControlPath.
- Keep OpenSSH stderr useful for diagnosis.

## Non-Goals

- No `0.0.0.0` or non-loopback listener support in v1.
- No automatic reconnect loop in v1.
- No traffic counters or bandwidth graphs.
- No changes to `remote/` web console.
- No changes to existing SSH profile form fields or `ssh_hosts` schema.
- No changes to URL-click automatic `-L` forwarding.

## Rule Model

Rules are stored in a new file under the platform config directory:

```text
<config>/port_forwards
```

Each rule owns:

```text
name
profile_name
direction = local | reverse
local_host
local_port
remote_host
remote_port
enabled
auto_start
```

Direction semantics:

```text
local   (-L): local_host:local_port   -> remote_host:remote_port
reverse (-R): remote_host:remote_port -> local_host:local_port
```

Default new rule values should bias toward the issue #177 proxy use case:

```text
direction = reverse
remote_host = 127.0.0.1
remote_port = 7890
local_host = 127.0.0.1
local_port = 7890
enabled = true
auto_start = true
```

Validation:

- `profile_name` must resolve to a saved SSH profile at start time.
- `direction` must be `local` or `reverse`.
- Ports must be `1..65535`.
- Hosts must be `127.0.0.1` or `localhost` in v1.
- Rule names may be empty; the UI can synthesize a display label from direction
  and ports.

The storage codec should be a pure, unit-tested module. The exact on-disk format
can be either line-oriented key/value blocks or tab-separated encoded fields,
but it must be independent from `ssh_hosts`.

## User Interface

Add a Command Center entry:

```text
Port Forwarding
Manage SSH port forwarding rules
```

Opening it creates/selects a dedicated non-terminal tab, similar to Skill
Center. It should have its own tab kind, model, renderer, and input branch.

The main view is a compact table:

```text
Status   Dir       Profile   Listen                 Target                  Auto   Name
Running  Reverse   devbox    remote 127.0.0.1:7890  local 127.0.0.1:7890   On     Local proxy
Stopped  Local     lab       local 127.0.0.1:8888   remote 127.0.0.1:8888  Off    Jupyter
Error    Reverse   gpu       remote 127.0.0.1:7890  local 127.0.0.1:7890   On     Proxy
```

Keyboard behavior:

```text
Up/Down   Move selection
n         New rule
e         Edit selected rule
d         Delete selected rule, with confirmation
Space     Start/stop selected rule
r         Restart selected rule
a         Toggle auto_start
Esc       Close tab, or cancel the active form/confirmation
```

New/edit uses an in-tab form or overlay, not the SSH profile page. The form
fields are:

- Profile
- Direction
- Local host
- Local port
- Remote host
- Remote port
- Auto start
- Name

The profile picker reads existing SSH profiles as references only. It must not
modify profile data.

## Runtime

Add a `port_forward_manager` that owns loaded rules and active helper children.
It is process-global app state, not per terminal surface state. The management
tab displays and mutates the manager state, but closing the tab does not stop
active rules.

Application startup:

```text
load port_forwards
for each enabled && auto_start rule:
  start silently
  if start fails, record status; do not block startup
```

Application shutdown:

```text
stop all active forwarding helper children
```

Command shapes:

```text
Local:
ssh -N -T -L local_host:local_port:remote_host:remote_port user@host

Reverse:
ssh -N -T -R remote_host:remote_port:local_host:local_port user@host
```

OpenSSH options should match existing tunnel practice:

```text
-o ExitOnForwardFailure=yes
-o StrictHostKeyChecking=accept-new
-o ConnectTimeout=8
-o ServerAliveInterval=60
-o ServerAliveCountMax=3
```

Authentication:

- Password profiles reuse the existing askpass helper path.
- Key-based profiles use batch mode.
- ProxyJump is forwarded from the saved SSH profile.
- Existing legacy algorithm settings are respected.

Compatibility:

- Do not add ControlMaster, ControlPersist, or ControlPath.
- Keep helper stderr available and parse/summarize it for the management UI.

## Status Model

Each rule has a runtime state independent from its persisted fields:

```text
stopped
starting
running
error(reason)
missing_profile
```

The manager should prune/check active children during the app loop or via the
same polling style used by other app-level background state. If a child exits,
the state becomes `error(exited)` or a more specific parsed reason.

v1 does not auto-reconnect. `auto_start` only means "start this rule when the app
starts." Users can manually start or restart from the tab.

## Error Handling

Silent behavior is the default:

- Startup failures update rule state without blocking the app.
- The tab shows `Error` plus a short reason.
- Manual start/restart failures may also show a non-blocking toast.

Examples of useful reasons:

```text
profile missing
local port unavailable
remote bind failed
ssh authentication failed
ssh exited
```

Raw stderr should remain visible in debug output or be retained in the rule's
detail view so users can diagnose real OpenSSH failures.

## Implementation Shape

Expected modules:

- `src/port_forward_rule.zig`: pure rule model, validation, storage codec, argv
  spec helpers.
- `src/port_forward_manager.zig`: active rule state, child lifecycle, start/stop,
  profile resolution callbacks.
- `src/renderer/port_forwarding_renderer.zig`: table/form renderer.
- `AppWindow.zig`: app-global manager lifecycle, startup auto-start, polling,
  tab spawning, command center action.
- `appwindow/tab.zig`: new tab kind/session storage for Port Forwarding.
- `input.zig`: key routing for the Port Forwarding tab, including render dirty
  flags after consumed UI mutations.
- `command_center_state.zig` and `i18n.zig`: command center entry and labels.

The Skill Center pattern is the preferred local reference for tab/model/renderer
separation. The existing `ssh_tunnel.zig` helper is the preferred reference for
OpenSSH child options, askpass handling, ProxyJump handling, and child cleanup.

## Testing

Fast tests:

- Rule parse/serialize round trips.
- Validation accepts only loopback hosts and valid ports.
- Local `-L` argv spec is correct.
- Reverse `-R` argv spec is correct.
- ProxyJump and profile port are included.
- Password mode includes askpass behavior; key mode uses batch behavior.
- No ControlMaster/ControlPersist/ControlPath strings appear in helper argv.
- Status transitions for start success, spawn failure, child exit, missing
  profile.

Full app tests:

- Command Center includes `Port Forwarding`.
- `spawnPortForwardingTab()` creates/selects the new non-terminal tab kind.
- Port Forwarding input handlers dirty the UI after navigation, form edits,
  start/stop, restart, auto-toggle, and confirmation changes.
- Existing SSH profile codec/page behavior is unchanged.
- Existing URL-click SSH tunnel behavior is unchanged.

Manual Windows verification:

- Reverse rule: server `127.0.0.1:7890` reaches local `127.0.0.1:7890`.
- Local rule: local browser reaches a remote loopback HTTP/Jupyter service.
- Password profile works without printing the password.
- ProxyJump profile works.
- OpenSSH stderr remains useful on failure.
- No OpenSSH connection sharing options are used.

## Approved Constraints

- Forwarding is silent.
- Management lives in a dedicated tab similar to Skill Center.
- Existing SSH profile configuration page is not changed.
- Rules are global and bind to saved SSH profiles.
- Auto-start rules do not require an interactive SSH terminal tab to be open.
- v1 supports both local and reverse directions.
