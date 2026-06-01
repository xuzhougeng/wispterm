---
name: wispterm-notify-setup
description: Use when the user wants to install, repair, or re-apply WispTerm notification reminders (Claude Code Stop + Notification, and Codex turn-complete) in a local WSL/macOS/Linux/PowerShell shell or a saved WispTerm SSH profile, so finishes and confirmation prompts surface inside WispTerm.
---

# WispTerm Notify Setup

## Overview

Install a small notifier that makes Claude Code and Codex surface a WispTerm
notification (OSC 777 toast + terminal bell badge) when a turn finishes or a
confirmation is needed. The notifier is agent-agnostic and the installers are
idempotent — safe to re-run.

## Workflow

1. Determine the target from the user's words and WispTerm state.

   - If the user names an existing WispTerm tab/server/profile (for example
     `CPU3`), call `terminal_list` first and match by `title`/`kind`.
   - If a saved SSH profile is named but no SSH tab is already open, call
     `ssh_profile_connect {"profile_name":"<name>"}` and use the returned
     `surface_id`.
   - Never ask the user to re-provide SSH host/user/port/password when the
     target is an existing saved WispTerm profile. Ask only if the profile is
     missing or authentication fails.

2. Install using the target-specific transfer path.

   - **Local POSIX / macOS / WSL:** copy the bundled POSIX scripts directly to
     the target shell, then run:

     ```bash
     sh ./install-wispterm-notify.sh
     ```

     When targeting an already-open WSL surface, use `wsl_session_exec` to run
     commands in that surface. Do not use `scp` for WSL.

   - **Local Windows PowerShell:** copy the bundled PowerShell scripts directly
     to the Windows profile and run `install-wispterm-notify.ps1` with
     `powershell_exec`:

     ```powershell
     powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-wispterm-notify.ps1
     ```

   - **Remote saved SSH profile:** use `scp`, not pasted heredocs, to transfer
     the bundled POSIX scripts to the remote server, then run the POSIX
     installer in that SSH session. From Windows/WispTerm, prefer the bundled
     profile-aware helper because it reads `%APPDATA%\wispterm\ssh_hosts`,
     decodes the saved profile, supports saved-password profiles via
     `SSH_ASKPASS`, and uses `scp.exe`/`ssh.exe` without connection sharing:

     ```powershell
     powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-wispterm-notify-remote.ps1 -ProfileName "CPU3"
     ```

     If you are already inside the SSH tab, you may run the final installer
     with `ssh_session_exec` after the `scp` upload.

3. Relay what it changed: the notify program path
   (`~/.config/wispterm/wispterm-notify.sh` on POSIX/remote,
   `%APPDATA%\wispterm\wispterm-notify.ps1` on Windows), which Claude Code hooks
   were added vs already present, and whether Codex's `notify` was added,
   already set, or left untouched (a pre-existing different `notify` is never
   overwritten).

4. Verify — run the printed test command and ask the user to confirm they saw a
   bell badge / toast in WispTerm:

   ```bash
   echo '{"hook_event_name":"Notification","title":"WispTerm","message":"setup ok"}' \
     | ~/.config/wispterm/wispterm-notify.sh
   ```

## WeChat forwarding (optional)

In addition to the in-terminal toast/bell, WispTerm can forward each agent
finish / confirmation notification to a WeChat account you've already bound to
WispTerm's built-in iLink direct connection — no third-party relay.

**Prerequisites (all required):**
1. A WispTerm build that includes notification → WeChat forwarding.
2. `weixin-direct-enabled = true` in your WispTerm config.
3. Scan the QR (WispTerm's WeChat panel) to bind your WeChat account.
4. Set `weixin-allowed-user = <your iLink user id>` — forwarding needs a bound
   owner as the push destination. The "auto-bind the first sender as owner" path
   is not yet wired, so the owner must be set explicitly here; while it is empty,
   pushes are silently skipped.
5. `weixin-notify-forward = true` in your WispTerm config.
6. Keep `desktop-notifications = on` (default) — forwarding rides the same
   notification pipeline and is skipped when desktop notifications are off.

**Behavior:** a push is sent only when the notification is from this notifier,
the binding is live with a bound owner, and you are **not** actively viewing
that pane (window unfocused, or a different tab/split). The phone message is
`<title>\n<body>`, e.g. `Claude Code` / `完成，轮到你了`.

**Verify:** run the test command below to trigger one notification while the
WispTerm window is unfocused, and confirm the message arrives in WeChat.

## Notes

- **Where it shows:** only when Claude Code / Codex run *inside* WispTerm. The
  rich OSC 777 toast needs a WispTerm build with OSC 9/777 support; older builds
  still get the bell badge from the BEL.
- **Idempotent:** re-running won't duplicate hooks; existing hooks and a
  pre-existing Codex `notify` are preserved.
- **Backups:** `settings.json.bak` / `config.toml.bak` are written before edits.
- **Dependencies:** the POSIX installer prefers `python3` for the JSON merge,
  falls back to `jq`, then to printing a manual snippet. The PowerShell
  installers use built-in PowerShell JSON/text handling.
- **SSH transfers:** keep OpenSSH stderr visible. Do not add
  `ControlMaster`/`ControlPersist`/`ControlPath` to `ssh.exe`/`scp.exe`.
