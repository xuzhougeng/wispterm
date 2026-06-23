# Design: pane-aware Claude Code / Codex integration install

- **Date:** 2026-06-23
- **Branch:** `feat/pane-aware-agent-integration`
- **Status:** Design - awaiting user review before plan

## Context

The Command Center exposes AI integration actions such as `Install Claude Code
Integration`, and recent app builds also show `Install Codex Integration`.
Users naturally read these commands as "install the integration for the current
terminal pane." In a multi-environment terminal this means the focused pane's
machine: local shell, WSL distro, or SSH server.

The current implementation does not honor that model. `Install Claude Code
Integration` reads and writes `~/.claude/settings.json` through
`platform_dirs.agentHookSettingsPath()` in the WispTerm host process
(`src/renderer/overlays.zig`, `src/claude_integration.zig`). If WispTerm is
running on Windows and the focused pane is an SSH session, the action changes
the Windows user's Claude Code settings, not the remote server's settings.

WispTerm already has most of the required building blocks:

- `Surface` records the focused pane's launch kind (`local`, `wsl`, `ssh`) and
  an `SshConnection` for SSH surfaces.
- Skill Center already routes work across local POSIX, WSL, and SSH profile
  targets (`SkillLocExec`, `SkillTransferCtx`, `wslSkillTransfer`) without
  pasting commands into the foreground terminal.
- `claude_integration.zig` currently contains the unpublished Claude Code
  lifecycle state hook implementation. The new installer can replace that
  behavior directly because it has not shipped.
- `agent_detector.parseMarker()` currently accepts only OSC 7748 markers with a
  recognized `state=` field. Session identity markers need an explicit parser
  extension.
- `plugins/skills/wispterm-notify-setup` contains a working notifier and
  installer model for Claude Code notifications and Codex `notify`.

## Goals

- Command Center integration install actions target the **focused terminal
  pane's machine** by default, without changing the visible command titles.
- A single `Install Claude Code Integration` action installs WispTerm's
  recommended Claude Code integration bundle:
  - a Herdr-style `SessionStart` identity hook that reports Claude's
    `session_id`, optional transcript path, and start source to WispTerm;
  - notification hooks that emit OSC 777 + BEL via the WispTerm notifier.
- A single `Install Codex Integration` action installs WispTerm's recommended
  Codex integration bundle:
  - a Herdr-style `SessionStart` identity hook in `~/.codex/hooks.json`;
  - `[features] hooks = true` in Codex `config.toml`;
  - Codex top-level `notify = [...]` that calls the WispTerm notifier;
  - no hook-driven Codex lifecycle state in this increment.
- Support local POSIX, Windows-local, WSL, and saved-profile SSH targets.
- Preserve existing user hooks/config. Installs are idempotent and do not
  overwrite an existing different Codex `notify`.
- Keep the terminal protocol boundary simple: agents report session metadata or
  notifications by writing terminal control sequences to their own tty.
- Keep Claude/Codex lifecycle state heuristic-driven for now. The new hooks
  improve session identity and history association, not the running/done state
  machine.

## Non-goals

- No Command Center wording changes for this increment.
- No interactive paste into the current pane.
- No background daemon on local or remote machines.
- No broad shell integration like Ghostty's shell startup resource injection.
- No Claude/Codex hook-driven lifecycle state mapping such as
  `UserPromptSubmit -> running` or `Stop -> done` in this increment.
- No Codex/Gemini state hook until their hook contracts make lifecycle state
  reliable enough to specify.
- No forced overwrite of existing Codex `notify`.

## Ghostty comparison

Ghostty's relevant model is shell integration, not AI-agent integration. In
`src/termio/shell_integration.zig`, Ghostty detects the shell and adjusts the
launched shell command/environment so shell scripts can emit terminal protocol
markers. The shell-integration README describes per-shell loading paths for
bash, zsh, fish, elvish, and nushell.

This feature follows the same architectural principle: WispTerm should receive
agent signals through terminal output/control sequences, not through an
out-of-band daemon. The difference is scope. Ghostty injects general shell
features at shell launch; WispTerm installs AI-agent hooks into Claude Code /
Codex config files on the selected machine. WispTerm's private OSC 7748 and
notification OSC 777 still ride the normal pane output stream, so local, WSL,
SSH, and tmux surfaces share the same receiver.

## Herdr hook reference

Herdr is the closest reference for AI-agent hook configuration. Its public
integration docs describe Claude Code and Codex installs as native integrations
that update the agent's config directory and write bundled hook scripts. The
current Herdr source does three details that should shape WispTerm's design:

- **Claude Code:** use `~/.claude` or `CLAUDE_CONFIG_DIR`, write
  `hooks/herdr-agent-state.sh` / `.ps1`, update `settings.json`, remove old
  Herdr-managed lifecycle hooks, then add only a `SessionStart` hook with
  matcher `"*"`, command `bash '<hook>' session` (or PowerShell on Windows),
  and timeout `10`.
- **Codex:** use `~/.codex` or `CODEX_HOME`, write `herdr-agent-state.sh` /
  `.ps1`, update `hooks.json`, remove old Herdr-managed lifecycle hooks, add a
  `SessionStart` hook with command `bash '<hook>' session` and timeout `10`,
  and ensure top-level `[features] hooks = true` in `config.toml` while removing
  the deprecated top-level `codex_hooks` key.
- **Hook payload:** the Claude/Codex hook scripts read JSON from stdin, extract
  `session_id`, optional `transcript_path` for Claude, and `source`, then report
  session identity. They deliberately do not report durable lifecycle state for
  Claude/Codex; Herdr fills state through process/screen detection.

WispTerm should follow that split. Because WispTerm does not have Herdr's local
socket API and must work through SSH/WSL/tmux without forwarding a daemon
socket, the hook output should stay in-band: emit a private OSC 7748 **session
metadata** marker to the pane's tty. This is not an authoritative `state=`
marker and must not suppress heuristic detection.

One deliberate WispTerm difference: Herdr fails when the agent config directory
does not exist. WispTerm may create missing config directories/files, matching
the current WispTerm notify installer, but it must never replace malformed
existing user config.

## User model

The command acts on the focused pane:

- Focused local shell: install on the host machine running the shell.
- Focused WSL shell: install inside the default WSL distro reached through
  `wsl.exe --exec sh -lc`.
- Focused SSH shell: install on that SSH server using the `SshConnection`
  already attached to the focused `Surface`.
- No focused terminal surface: show a failure toast.

The command title remains unchanged. Success/failure toasts should name the
actual target, for example "Claude Code integration installed on SSH CPU3" or
"Codex integration conflict: existing notify left untouched".

## Integration bundle

### Shared marker model

WispTerm keeps OSC 7748 but splits it into two marker kinds:

- **State marker:** existing authoritative form:

  ```text
  OSC 7748 ; wispterm-agent ; state=<state> ; app=<app> BEL
  ```

  This continues to set `Surface.agent_osc_active = true` and suppresses the
  heuristic detector for that surface.

- **Session marker:** new metadata-only form:

  ```text
  OSC 7748 ; wispterm-agent ; event=session ; app=<app> ; data=<base64url-json> BEL
  ```

  This updates session metadata for the surface but does **not** set
  `agent_osc_active`, does **not** replace `agent_detection.state`, and does
  **not** bypass the heuristic detector. The immediate UI state remains the
  existing screen/process heuristic result.

`data` is unpadded URL-safe base64 of a compact JSON object. The JSON object
contains `session_id` and may contain `session_path` and
`session_start_source`. Decoded JSON larger than 4 KiB, invalid UTF-8, or string
values containing control bytes should be rejected by the parser. This keeps
`;`, BEL, ESC, and other control bytes out of the OSC grammar.

### Claude Code

The Claude bundle combines two independent hook groups:

1. **Session identity hook.**
   Install a WispTerm-managed hook script at:

   ```text
   ~/.claude/hooks/wispterm-agent-session.sh
   %USERPROFILE%\.claude\hooks\wispterm-agent-session.ps1
   ```

   Honor `CLAUDE_CONFIG_DIR` when it is present in the installer process
   environment; otherwise use `~/.claude`. The installer may create the config
   directory and an empty `settings.json` when missing. If a malformed
   `settings.json` exists, report `parse_error` rather than overwriting it.

   Merge `settings.json` so it contains a single WispTerm-managed
   `SessionStart` entry:

   ```json
   {
     "hooks": {
       "SessionStart": [
         {
           "matcher": "*",
           "hooks": [
             {
               "type": "command",
               "command": "bash '<hook_path>' session",
               "timeout": 10
             }
           ]
         }
       ]
     }
   }
   ```

   On Windows, use the PowerShell equivalent:

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<hook_path>" session
   ```

   The hook reads the Claude hook JSON from stdin, ignores subagent events, and
   extracts `session_id`, `transcript_path`, and SessionStart `source`. If a
   valid `session_id` exists, it emits a session marker for `app=claude_code` to
   the controlling tty.

2. **Notification hooks.**
   Install `wispterm-notify.sh` / `wispterm-notify.ps1` under the target
   WispTerm config directory and add Claude Code `Stop` / `Notification`
   command hooks that call the notifier. These hooks emit OSC 777 + BEL only;
   they must not emit OSC 7748 state.

The installer must merge both groups into the same target `settings.json`
without dropping unrelated hooks. Existing WispTerm-managed entries are detected
by command contents and not duplicated.

### Codex

The Codex bundle combines three pieces:

1. **Session identity hook.**
   Install a WispTerm-managed hook script at:

   ```text
   ~/.codex/wispterm-agent-session.sh
   %USERPROFILE%\.codex\wispterm-agent-session.ps1
   ```

   Honor `CODEX_HOME` when it is present in the installer process environment;
   otherwise use `~/.codex`. The installer may create the config directory and
   empty `hooks.json` / `config.toml` files when missing. If existing JSON/TOML
   is malformed, report `parse_error` rather than overwriting it.

   Merge `~/.codex/hooks.json` so it contains a single WispTerm-managed
   `SessionStart` command hook:

   ```json
   {
     "hooks": {
       "SessionStart": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "bash '<hook_path>' session",
               "timeout": 10
             }
           ]
         }
       ]
     }
   }
   ```

   On Windows, use the same PowerShell command shape as Claude. The hook reads
   Codex hook JSON from stdin, ignores non-`SessionStart` events, extracts
   `session_id` and `source`, and emits a session marker for `app=codex` when a
   valid session exists.

2. **Codex hook enablement.**
   Ensure top-level `[features] hooks = true` in `config.toml`. If a top-level
   `[features] codex_hooks = ...` key exists, remove it as deprecated. Do not
   modify `[profiles.*.features]` or other nested tables.

3. **Notification command.**
   Install the WispTerm notifier and add a top-level `notify` array to
   `config.toml`.

Rules:

- If there is no top-level `notify`, prepend one so it is not accidentally
  bound to a later TOML table.
- If top-level `notify` already calls `wispterm-notify`, report already
  installed.
- If top-level `notify` exists and is different, leave it untouched and report
  a conflict.

Codex agent state continues to use WispTerm's existing heuristic detection in
this increment. `hooks.json` is used for session identity, not lifecycle state.

## Architecture

Create a pane-aware install layer in `src/agent_integration_install.zig`. It
should be split into pure config transforms and impure target execution:

- **Pure transforms**
  - Build or merge Claude Code `settings.json` for the SessionStart identity
    hook and notification hooks.
  - Build or merge Codex `hooks.json` for the SessionStart identity hook.
  - Build or merge Codex `config.toml` top-level `[features] hooks = true`,
    remove top-level deprecated `codex_hooks`, and add top-level `notify`
    without clobbering a different existing value.
  - Encode/decode OSC 7748 session metadata.
  - Detect installed / already-present / conflict states.
  - Unit tests run in the fast suite where platform independent.

- **Target execution**
  - Resolve the focused `Surface` to a target descriptor:
    `local_windows`, `local_posix`, `wsl`, or `ssh`.
  - Execute a small installer script or shell command on that target.
  - Copy the notifier script to the target where needed.
  - Return a compact result for toast/logging.

The Command Center actions should start a background job, not run IO on the UI
thread. The job result is polled in the same style as Skill Center background
ops and update jobs. Completion marks the UI dirty and shows a status toast.

`agent_detector.zig` should expose two parsing paths:

- `parseMarker()` or equivalent for existing authoritative `state=` markers.
- `parseSessionMarker()` or a tagged union parser for metadata-only
  `event=session` markers.

`Surface.handleWispTermAgentOsc()` should apply the parser result by kind. State
markers keep the current behavior. Session markers update a new surface-level
agent session field and leave `agent_osc_active` unchanged.

## Target data flow

### Local POSIX

Use local shell execution when `remote_file.localPosixExecSupported()` is true.
Install under:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/wispterm/wispterm-notify.sh
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/wispterm-agent-session.sh
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
${CODEX_HOME:-$HOME/.codex}/wispterm-agent-session.sh
${CODEX_HOME:-$HOME/.codex}/hooks.json
${CODEX_HOME:-$HOME/.codex}/config.toml
```

The POSIX installer may create missing config directories/files, matching the
current WispTerm notify installer behavior. It must fail with `parse_error` for
malformed existing JSON/TOML rather than replacing user data.

### Local Windows

Use native file IO for host-local Windows config paths. The same pure config
transforms used by POSIX targets should produce the Windows `settings.json` and
`config.toml` content; only the notifier command differs. Install under:

```text
%APPDATA%\wispterm\wispterm-notify.ps1
%USERPROFILE%\.claude\hooks\wispterm-agent-session.ps1
%USERPROFILE%\.claude\settings.json
%USERPROFILE%\.codex\wispterm-agent-session.ps1
%USERPROFILE%\.codex\hooks.json
%USERPROFILE%\.codex\config.toml
```

Claude/Codex identity hooks and Codex `notify` must call PowerShell with
explicit arguments, matching the existing `install-wispterm-notify.ps1` command
style.

### WSL

Use `remote_file.wslExec()` and the default distro. Do not use `scp` for WSL.
Write embedded POSIX installer content to a temporary path inside WSL, execute
it with `sh`, then remove the temporary file.

### SSH

Use the `SshConnection` on the focused surface. Keep the existing SSH/SCP rules:

- use `scp` for file transfer;
- do not add `ControlMaster`, `ControlPersist`, or `ControlPath`;
- keep underlying OpenSSH stderr visible enough for diagnostic summaries;
- support saved-password profiles through existing askpass plumbing.

Upload embedded POSIX scripts to `~/.config/wispterm/integration-setup/` and run
the remote installer with `ssh`. Use absolute remote paths resolved through a
prior `ssh` command; do not depend on remote `~` expansion inside `scp`.

## Error handling

Installer results should distinguish:

- `installed`
- `already_installed`
- `partial`
- `conflict_existing_codex_notify`
- `identity_installed_notify_conflict`
- `target_unavailable`
- `auth_or_transport_failed`
- `parse_error`
- `write_failed`

Command Center toasts should be concise. Logs may include full stderr summaries
but must not print saved passwords.

If session identity hooks install but notification hooks fail or conflict,
report partial success rather than rolling back unrelated successful changes.
Each install is idempotent, so the user can rerun after fixing the failure.

## Remove actions

`Remove Claude Code Integration` should also become pane-aware for symmetry.
It removes only WispTerm-managed Claude Code hook groups from the focused target:
the `SessionStart` identity hook entry, the WispTerm hook script, and the
WispTerm notification hook entries. It should not remove the notifier file
unless the implementation can prove no remaining Codex/Claude hook references
it.

Codex remove can be deferred unless the running app already exposes a
corresponding `Remove Codex Integration` action. If implemented, it should
remove only the WispTerm-managed `SessionStart` entry from `hooks.json`, delete
the WispTerm Codex identity hook script, and remove a top-level `notify` value
only when it exactly matches WispTerm's notifier command. It should leave
`[features] hooks = true` in place, matching Herdr's uninstall behavior, because
other Codex hooks may rely on it.

## Testing

Fast tests:

- Claude `settings.json` merge preserves unrelated hooks and is idempotent.
- Codex `hooks.json` merge adds one WispTerm `SessionStart` hook and is
  idempotent.
- Codex config merge ensures top-level `[features] hooks = true`.
- Codex config merge removes only top-level deprecated `codex_hooks`.
- Codex config merge does not modify `[profiles.*.features]`.
- Codex TOML merge prepends top-level `notify`.
- Codex TOML merge detects indented top-level `notify`.
- Codex TOML merge leaves existing different `notify` untouched.
- OSC 7748 state marker parsing remains authoritative.
- OSC 7748 session marker parsing accepts valid encoded metadata and rejects
  malformed or control-byte-breaking payloads.
- Applying a session marker updates surface session metadata without setting
  `agent_osc_active`.
- Target resolution maps `Surface.launch_kind` / SSH connection presence to
  local, WSL, or SSH descriptors.

Full/app tests:

- Command Center actions dispatch background jobs.
- Overlay key handling dirties UI after command execution where needed.
- Toast mapping covers success, partial, and conflict outcomes.

Manual verification:

- Local POSIX: install Claude/Codex, run a notifier dry-run, trigger Claude
  hooks, verify OSC 7748 `event=session` metadata and OSC 777/BEL notification.
- WSL: install from a WSL pane and verify target `~/.claude` / `~/.codex`
  changed inside WSL, not Windows.
- SSH saved profile: install from an SSH pane and verify remote files changed;
  confirm no password is printed.
- Existing Codex `notify`: verify the command reports conflict and preserves it.
## Open implementation notes

- The current checkout exposes `Install Claude Code Integration` in
  `src/command_center_state.zig`; the user's running app screenshot also shows
  `Install Codex Integration`. The implementation plan must first reconcile
  that source/runtime mismatch and add or preserve the Codex action as needed.
- The implementation plan should verify the current Codex hook file schema
  against the installed Codex version or official Codex docs before coding the
  `hooks.json` transform, because this surface can change independently of
  WispTerm.
- `src/claude_integration.zig` is currently named around the older Claude-only
  state hook behavior. New install logic belongs in
  `agent_integration_install.zig`; any remaining `claude_integration.zig`
  surface should be a thin compatibility wrapper only.
- Embedding installer scripts at compile time is preferred so release builds do
  not depend on a repo-relative `plugins/` directory.
- Reuse Skill Center's target-routing patterns rather than creating a second
  SSH/WSL execution abstraction from scratch.

## References

- Herdr integration docs:
  `https://github.com/ogulcancelik/herdr/blob/master/website/src/content/docs/integrations.mdx`
- Herdr installer implementation:
  `https://github.com/ogulcancelik/herdr/blob/master/src/integration/mod.rs`
- Herdr Claude hook asset:
  `https://github.com/ogulcancelik/herdr/blob/master/src/integration/assets/claude/herdr-agent-state.sh`
- Herdr Codex hook asset:
  `https://github.com/ogulcancelik/herdr/blob/master/src/integration/assets/codex/herdr-agent-state.sh`
