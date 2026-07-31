# MCP Server Config UI — Design

Date: 2026-07-01
Branch: `feat/mcp-client-v0`

## Problem

MCP v0 reads external servers from `<config-dir>/mcp.json`, which the user must
hand-edit. There is no in-app way to add, edit, enable/disable, remove, or test
an MCP server. `mcp.json` should become a file the app *writes* after the user
configures servers through a UI — not something they craft by hand.

## Goals

1. A dedicated in-app panel to **list / add / edit / enable-disable / remove**
   MCP servers, mirroring the existing SSH Profiles overlay.
2. **Form-based editing** (name, command, args, enabled) — no JSON knowledge
   required.
3. A **read-only JSON preview** showing exactly what will be written to
   `mcp.json`, so power users can see the result.
4. A **Test** action per server that runs the real discovery handshake
   (`initialize` + `tools/list`) in the background and shows **success/failure
   plus the discovered tool names**.
5. **Save writes `mcp.json` and reloads** so changes take effect without a
   restart.

## Non-goals (v1)

- Editable multi-line JSON (the JSON view is read-only preview; the form is the
  editor).
- Per-arg list UI — `args` is one space-separated field (complex args: use the
  JSON preview to confirm, or edit the file directly).
- Remote/HTTP/OAuth server fields — stdio only, matching MCP v0.
- Per-tool enable/deny, approval overrides, secret management.

## Design

Four pieces, each independently testable.

### 1. Persistence — `tools/mcp_registry.zig`

Already has `parseServersConfig(json) -> []ServerConfig` (read). Add the write
side + config-file helpers so the overlay never touches file paths or JSON:

- `writeServersConfig(allocator, servers: []const ServerConfig) ![]u8` —
  serialize a server list to canonical `mcp.json` text (`{"mcpServers":{...}}`),
  emitting `enabled` only when false (keeps the common file clean). Round-trips
  with `parseServersConfig`.
- `loadConfigFile(allocator) ![]ServerConfig` — read `<config-dir>/mcp.json` via
  `platform_dirs.pathInConfigDir`, parse. Missing file → empty list.
- `saveConfigFile(allocator, servers) !void` — `writeServersConfig` →
  atomic write (`platform.atomic_file`) to `<config-dir>/mcp.json`.

`ServerConfig` gains no new fields; the UI only edits name/command/args/enabled.

### 2. Overlay state — `renderer/overlays/mcp_servers.zig`

Mirrors `ssh_profiles.zig`: a fixed-size, heap-free `State` added to
`OverlayState` as `mcp: mcp_servers.State`.

```
pub const MCP_SERVER_MAX = 32;         // fixed array, like SSH_PROFILE_MAX
pub const Field = enum { name, command, args };  // enabled is a bool toggle

pub const View = enum { list, form, json_preview };

pub const State = struct {
    visible: bool = false,
    view: View = .list,
    servers: [MCP_SERVER_MAX]Server,    // name/command/args buffers + enabled bool
    count: usize = 0,
    list_selected: usize = 0,
    editing_index: ?usize = null,       // null in .form => adding a new server
    form: FormBuffers,                  // fixed char buffers per Field
    probe: ProbeState,
    // ... open()/close(), setFormField/formField, add/remove/toggle, etc.
};
```

`args` is stored/edited as a single string; split on whitespace when building
the `ServerConfig` for save/preview/probe.

**Load on open:** `open()` calls `mcp_registry.loadConfigFile`, copies into the
fixed `servers` array (truncating past `MCP_SERVER_MAX`, logged).

**JSON preview (read-only):** `.json_preview` renders
`mcp_registry.writeServersConfig(currentServers)` — the exact bytes Save will
write. No editing; it is a confirmation view.

### 3. Async probe — mirrors `assistant/quick_verify.zig`

Testing a server must not block the UI, so it runs off-thread exactly like the
AI-profile connection verify:

```
pub const PROBE_TOOL_MAX = 24;
pub const ProbeStatus = enum { idle, running, ok, failed };
pub const ProbeState = struct {
    status: ProbeStatus = .idle,
    target_index: usize = 0,
    message: [256]u8 = undefined,      // error reason (len tracked); "" on success
    message_len: usize = 0,
    tools: [PROBE_TOOL_MAX][64]u8 = undefined,  // discovered tool names, capped
    tool_count: usize = 0,
};
```

`startProbe(index)` spawns a worker (`std.Thread.spawn`) that runs
`mcp_client.Connection.spawn → initialize → listTools` against that server's
command/args, copies the tool names (or the error) into `ProbeState`, then
`postWakeup()`s the UI thread to re-render (threadlocal `markUiDirty` is not
enough — see the event-driven-wakeup convention). The worker owns a snapshot of
the command/args so it never reads `State` concurrently.

Result shows as `✓ 3 tools: echo, add, longRunningOperation` or
`✗ failed: <reason>`.

### 4. Save → reload

Save builds a `ServerConfig` list from `State`, calls
`mcp_registry.saveConfigFile`, then `ai_chat.reloadMcpTools(allocator)` (existing
v0 entrypoint). The Copilot picks up the change on its next request — no restart.

### 5. Wiring

- **Open:** add a `manage_mcp_servers` action to `command/center_state.zig`
  (`{ .title = "MCP Servers", .detail = "Add, edit, test, or remove MCP tool
  servers", .action = .manage_mcp_servers }`) and dispatch it to `state.mcp.open()`
  where other overlay actions are handled.
- **Input:** an overlay key handler (list nav ↑/↓, Enter=edit, `a`=add,
  `d`=delete, space=toggle enabled, `t`=test, Tab=cycle view, Ctrl-S=save, Esc=close).
  It MUST set `g_force_rebuild` so arrow-nav is responsive (per the overlay
  force_rebuild convention).
- **Render:** an overlay renderer draws the list (name / enabled / last probe),
  the form, the JSON preview, and the probe result line — following the SSH
  Profiles overlay layout.

## Error handling

- Invalid/missing `mcp.json` on load → empty list (not fatal).
- Save failure (disk) → a toast; state kept so the user can retry.
- Probe failure → `✗` + reason in the panel; never crashes, never blocks.
- A duplicate/empty server name is rejected in the form with an inline message
  (name is the `mcpServers` key and must be unique + non-empty).

## Testing

- **`mcp_registry`** (fast suite): `writeServersConfig` round-trips with
  `parseServersConfig`; `enabled:false` emitted, `true` omitted; empty list →
  `{"mcpServers":{}}`.
- **`mcp_servers.State`** (fast suite): add/edit/remove/toggle; `args`
  split/join; form ⇄ ServerConfig; JSON-preview equals what Save writes;
  `MCP_SERVER_MAX` truncation.
- **Probe** (fast suite): worker against a canned stdio server (the `/bin/sh`
  fixture already used in `mcp_client`/`mcp_registry` tests) fills `ProbeState`
  with the tool names; a bad command fills `failed` + reason.
- **E2E** (`tests/macos_e2e`): extend the harness to open the panel via the
  command palette and confirm it lists a pre-seeded server; Save path is covered
  by the existing `test_mcp_discovery` (write config → reload → handshake).

## v1 boundaries (marked with `ponytail:` in code)

- JSON view is read-only; the form is the only editor.
- `args` is a single whitespace-split field.
- stdio servers only; no HTTP/OAuth/env/secret fields.
- Probe spawns per test (no connection reuse) and has no timeout — a hung server
  leaves the probe in `running` until the app exits (bounded worker; upgrade to a
  deadline if it bites).
