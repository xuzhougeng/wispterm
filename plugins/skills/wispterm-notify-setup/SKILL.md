---
name: wispterm-notify-setup
description: Use when the user wants to install, repair, or re-apply WispTerm notification reminders (Claude Code Stop + Notification, and Codex turn-complete) on this Unix machine, so finishes and confirmation prompts surface inside WispTerm. Linux/WSL + macOS only.
---

# WispTerm Notify Setup

## Overview

Install a small notifier that makes Claude Code and Codex surface a WispTerm
notification (OSC 777 toast + terminal bell badge) when a turn finishes or a
confirmation is needed. The notifier is agent-agnostic and the installer is
idempotent — safe to re-run. Unix only (Linux/WSL + macOS); Windows is not yet
supported.

## Workflow

1. Run the bundled installer:

   ```bash
   sh "$(dirname "$0")/scripts/install-wispterm-notify.sh"
   ```

   (Invoke the `scripts/install-wispterm-notify.sh` that ships with this skill —
   under `~/.claude/skills/wispterm-notify-setup/` or
   `~/.codex/skills/wispterm-notify-setup/`.)

2. Relay what it changed: the notify program path (`~/.config/wispterm/wispterm-notify.sh`),
   which Claude Code hooks were added vs already present, and whether Codex's
   `notify` was added, already set, or left untouched (a pre-existing different
   `notify` is never overwritten).

3. Verify — run the printed test command and ask the user to confirm they saw a
   bell badge / toast in WispTerm:

   ```bash
   echo '{"hook_event_name":"Notification","title":"WispTerm","message":"setup ok"}' \
     | ~/.config/wispterm/wispterm-notify.sh
   ```

## Notes

- **Where it shows:** only when Claude Code / Codex run *inside* WispTerm. The
  rich OSC 777 toast needs a WispTerm build with OSC 9/777 support; older builds
  still get the bell badge from the BEL.
- **Idempotent:** re-running won't duplicate hooks; existing hooks and a
  pre-existing Codex `notify` are preserved.
- **Backups:** `settings.json.bak` / `config.toml.bak` are written before edits.
- **Dependencies:** prefers `python3` for the JSON merge, falls back to `jq`,
  then to printing a manual snippet.
