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
- `claude_integration.zig` can idempotently merge/remove WispTerm agent-state
  hooks into Claude Code JSON.
- `plugins/skills/wispterm-notify-setup` contains a working notifier and
  installer model for Claude Code notifications and Codex `notify`.

## Goals

- Command Center integration install actions target the **focused terminal
  pane's machine** by default, without changing the visible command titles.
- A single `Install Claude Code Integration` action installs WispTerm's
  recommended Claude Code integration bundle:
  - agent-state hooks that emit WispTerm's private OSC 7748 marker;
  - notification hooks that emit OSC 777 + BEL via the WispTerm notifier.
- A single `Install Codex Integration` action installs WispTerm's recommended
  Codex integration bundle:
  - Codex top-level `notify = [...]` that calls the WispTerm notifier;
  - no first-class Codex OSC 7748 state hook in this increment.
- Support local POSIX, Windows-local, WSL, and saved-profile SSH targets.
- Preserve existing user hooks/config. Installs are idempotent and do not
  overwrite an existing different Codex `notify`.
- Keep the terminal protocol boundary simple: agents report state or
  notifications by writing terminal control sequences to their own tty.

## Non-goals

- No Command Center wording changes for this increment.
- No interactive paste into the current pane.
- No background daemon on local or remote machines.
- No broad shell integration like Ghostty's shell startup resource injection.
- No Codex/Gemini agent-state hook until their current hook contracts make that
  reliable enough to specify.
- No forced overwrite of existing Codex `notify`.

## Ghostty comparison

Ghostty's relevant model is shell integration, not AI-agent integration. In
`src/termio/shell_integration.zig`, Ghostty detects the shell and adjusts the
launched shell command/environment so shell scripts can emit terminal protocol
markers. The shell-integration README describes per-shell loading paths for
bash, zsh, fish, elvish, and nushell.

This feature follows the same architectural principle: WispTerm should receive
state through terminal output/control sequences, not through an out-of-band
daemon. The difference is scope. Ghostty injects general shell features at
shell launch; WispTerm installs AI-agent hooks into Claude Code / Codex config
files on the selected machine. WispTerm's private OSC 7748 and notification OSC
777 still ride the normal pane output stream, so local, WSL, SSH, and tmux
surfaces share the same receiver.

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

### Claude Code

The Claude bundle combines two pieces:

1. **Agent-state hooks** from `src/claude_integration.zig`.
   These emit:

   ```sh
   printf '\033]7748;wispterm-agent;state=<state>;app=claude_code\007' > /dev/tty 2>/dev/null || true
   ```

   Event mapping stays:

   - `UserPromptSubmit` -> `running`
   - `PreToolUse` -> `running`
   - `Notification` -> `waiting_approval`
   - `Stop` -> `done`

2. **Notification hooks** equivalent to `wispterm-notify-setup`.
   These install `wispterm-notify.sh` / `wispterm-notify.ps1` under the target
   WispTerm config directory and add Claude Code `Stop` / `Notification`
   command hooks that call the notifier.

The installer must merge both sets into the same target `~/.claude/settings.json`
without dropping unrelated hooks. Existing WispTerm-managed entries are detected
by their command contents and not duplicated.

### Codex

The Codex bundle installs the WispTerm notifier and adds a top-level `notify`
array to the target `~/.codex/config.toml`.

Rules:

- If there is no top-level `notify`, prepend one so it is not accidentally
  bound to a later TOML table.
- If top-level `notify` already calls `wispterm-notify`, report already
  installed.
- If top-level `notify` exists and is different, leave it untouched and report
  a conflict.

Codex agent state continues to use WispTerm's existing heuristic detection in
this increment.

## Architecture

Create a pane-aware install layer in `src/agent_integration_install.zig`. It
should be split into pure config transforms and impure target execution:

- **Pure transforms**
  - Build or merge Claude Code settings JSON for the bundle.
  - Build or merge Codex `config.toml` top-level `notify`.
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

## Target data flow

### Local POSIX

Use local shell execution when `remote_file.localPosixExecSupported()` is true.
Install under:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/wispterm/wispterm-notify.sh
~/.claude/settings.json
~/.codex/config.toml
```

### Local Windows

Use native file IO for host-local Windows config paths. The same pure config
transforms used by POSIX targets should produce the Windows `settings.json` and
`config.toml` content; only the notifier command differs. Install under:

```text
%APPDATA%\wispterm\wispterm-notify.ps1
%USERPROFILE%\.claude\settings.json
%USERPROFILE%\.codex\config.toml
```

Codex `notify` must call PowerShell with explicit arguments, matching the
existing `install-wispterm-notify.ps1` script.

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

Upload embedded POSIX scripts to `~/.config/wispterm/notify-setup/` and run the
remote installer with `ssh`. Use absolute remote paths resolved through a prior
`ssh` command; do not depend on remote `~` expansion inside `scp`.

## Error handling

Installer results should distinguish:

- `installed`
- `already_installed`
- `partial`
- `conflict_existing_codex_notify`
- `target_unavailable`
- `auth_or_transport_failed`
- `parse_error`
- `write_failed`

Command Center toasts should be concise. Logs may include full stderr summaries
but must not print saved passwords.

If Claude state hooks install but notification hooks fail, report partial
success rather than rolling back unrelated successful changes. Each install is
idempotent, so the user can rerun after fixing the failure.

## Remove actions

`Remove Claude Code Integration` should also become pane-aware for symmetry.
It removes only WispTerm-managed Claude Code hook groups from the focused
target. It should not remove the notifier file unless the implementation can
prove no remaining Codex/Claude hook references it.

Codex remove can be deferred unless the running app already exposes a
corresponding `Remove Codex Integration` action. If implemented, it should
remove only a top-level `notify` value that exactly matches WispTerm's notifier
command and leave all other `notify` values untouched.

## Testing

Fast tests:

- Claude bundle merge preserves unrelated hooks and is idempotent.
- Codex TOML merge prepends top-level `notify`.
- Codex TOML merge detects indented top-level `notify`.
- Codex TOML merge leaves existing different `notify` untouched.
- Target resolution maps `Surface.launch_kind` / SSH connection presence to
  local, WSL, or SSH descriptors.

Full/app tests:

- Command Center actions dispatch background jobs.
- Overlay key handling dirties UI after command execution where needed.
- Toast mapping covers success, partial, and conflict outcomes.

Manual verification:

- Local POSIX: install Claude/Codex, run a notifier dry-run, trigger Claude
  hooks, verify OSC 7748 state and OSC 777/BEL notification.
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
- Embedding installer scripts at compile time is preferred so release builds do
  not depend on a repo-relative `plugins/` directory.
- Reuse Skill Center's target-routing patterns rather than creating a second
  SSH/WSL execution abstraction from scratch.
