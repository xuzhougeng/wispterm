---
name: phantty-diagnostics
description: Use when a Windows user wants to report, troubleshoot, or collect context for a Phantty issue, including startup failures, crashes, keyboard input bugs, selection/copy/scrolling issues, SSH/SCP problems, file explorer behavior, WebView2/browser panel issues, updater failures, or remote console behavior.
---

# Phantty Diagnostics

## Overview

Generate a safe, copyable Markdown diagnostic report for ordinary Windows users
filing Phantty issues. Use the bundled PowerShell script instead of asking the
user to manually discover Phantty, Windows, OpenSSH, WebView2, GPU, and config
details.

## Workflow

1. If the user already described the problem, infer `-ProblemType` from it.
   Otherwise use an empty problem type.
2. Run the script from this skill directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_phantty_diagnostics.ps1
```

Use `pwsh` instead of `powershell` only if Windows PowerShell is unavailable.

3. For a known issue type, pass one of these labels:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_phantty_diagnostics.ps1 -ProblemType "SSH/SCP"
```

Recommended labels: `startup/crash`, `keyboard/input`, `selection/copy/scrolling`,
`SSH/SCP`, `file explorer`, `WebView2/browser panel`, `updater`,
`remote console`, `other`.

4. Paste the generated Markdown report back to the user. Ask them to review it
   before posting and to fill in blank human-only fields such as the exact
   description and reproduction steps.

## What The Report Covers

- Phantty version, executable path, package flavor, `version.txt`, config path,
  and portable config presence.
- Windows edition, display version, build, architecture, locale, PowerShell, and
  current shell process.
- `ssh.exe` / `scp.exe` path and version, plus whether Phantty's `ssh_hosts`
  file exists and how many saved profiles it contains.
- GPU and driver details, WebView2 runtime version, and nearby
  `WebView2Loader.dll` presence.
- Relevant Phantty files under `%APPDATA%\phantty`.
- A sanitized Phantty config excerpt.
- Failed diagnostic commands.

## Privacy Rules

The script is intended to be safe to paste into a public GitHub issue. Do not
add collection of public IP addresses, Wi-Fi passwords, SSH passwords, decoded
SSH profile fields, SSH private keys, tokens, remote session keys, full
environment variable dumps, browser data, process inventories, license keys,
serial numbers, or unique hardware IDs.

The script redacts sensitive config values by default. Still remind the user to
review the final Markdown before posting.

## Validation

When modifying the script, run on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_phantty_diagnostics.ps1 -SelfTest
```

Then run a normal report generation command. The script must complete even when
Phantty, OpenSSH, WebView2, or config files are missing; missing data should be
reported as `not found`, `not applicable`, or `unavailable`.
