---
name: wispterm-diagnostics
description: Use when a user wants to report, troubleshoot, or collect context for a WispTerm issue, including crashes, rendering/DPI glitches, high CPU, keyboard/input bugs, selection/copy/scrolling, SSH/SCP failures, SSH image preview failures, HTML preview/browser panel failures, SSH disconnects such as ssh_packet_write_poll/eother, file explorer behavior, updater failures, or remote console behavior.
---

# WispTerm Diagnostics

## Overview

Generate a safe, copyable Markdown diagnostic report for users filing WispTerm
issues. On **Windows**, installed WispTerm release packages include this plugin,
so the preferred user-facing path is to ask the user to invoke
`$wispterm-diagnostics` from WispTerm's AI Chat or Copilot and include their
symptoms/reproduction steps. The skill then uses the bundled PowerShell script
to collect WispTerm, Windows, OpenSSH, WebView2, bundled ConPTY, GPU, logs, and
config details. Do not ask Windows users to find a source checkout first.

On **macOS**, there is no equivalent script yet — use the manual bash workflow
in the macOS section below.

## Windows Workflow

1. If a user needs instructions, tell them to open a WispTerm AI Chat tab or
   Copilot sidebar and send a request like:

```text
$wispterm-diagnostics
Problem type: ssh-disconnect
Symptom: SSH Profile disconnects after 5-10 minutes idle with "Connection reset".
Repro steps: connect to the saved SSH profile, leave it idle, then run ls.
What I already tried: external ssh.exe with ServerAliveInterval works.
```

2. Infer `-ProblemType` from the user's text. If it is unclear, use `other` and
   keep the user's symptom/repro text in the generated issue draft.
3. Run the script from this skill directory as the implementation detail:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_wispterm_diagnostics.ps1 -ProblemType "other"
```

Use `pwsh` instead of `powershell` only if Windows PowerShell is unavailable.

Recommended labels: `startup/crash`, `rendering/DPI`, `high-cpu`,
`keyboard/input`, `selection/copy/scrolling`, `SSH/SCP`,
`ssh-image-preview`, `html-preview`, `ssh-disconnect`, `file explorer`,
`WebView2/browser panel`, `updater`, `remote console`, `other`.

4. For **rendering/DPI/multi-monitor glitch** reports, first check whether
   `render-diagnostic.log` is already present. If not, ask the user to add
   `wispterm-debug-render = true` to their config (press `Ctrl+,` to open it),
   restart WispTerm, reproduce the glitch, then run the script. The log is
   written to `%APPDATA%\wispterm\render-diagnostic.log`.

   For **high-cpu** reports, run the script while WispTerm is exhibiting the
   high-CPU behavior so the 3-second CPU sample captures the real usage.

5. For startup/crash reports, run the automated startup probe. It enables
`WISPTERM_RENDER_DIAGNOSTICS=1` only for the probe process, starts WispTerm with
auto-update disabled, waits briefly, then closes/kills the process if it did
not crash:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_wispterm_diagnostics.ps1 -ProblemType "startup/crash" -StartupProbe
```

6. If the user is willing to reproduce a crash and can share a dump privately,
enable Windows Error Reporting local dumps before the startup probe:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_wispterm_diagnostics.ps1 -ProblemType "startup/crash" -StartupProbe -EnableCrashDumps
```

This writes HKCU-only WER settings for `wispterm.exe` and reports the dump
folder. Do not ask the user to attach `.dmp` files publicly; dumps may contain
terminal text, environment fragments, tokens, paths, or other process memory.

7. Return a GitHub-ready Markdown issue body. Include the user's symptom,
   reproduction steps, expected behavior, diagnostic report, and issue-specific
   next steps. Ask them to review it before posting publicly and remove secrets.

If WispTerm cannot start or the AI Agent is unavailable, use the script command
above from the installed/extracted WispTerm folder that contains
`plugins\skills\wispterm-diagnostics`. That is a fallback, not the normal FAQ
path.

## High-Signal Issue Workflows

Use these on top of the Windows report. The script intentionally avoids logging
into remote hosts; ask the user to run the remote commands manually and paste
only non-secret output.

### SSH image preview fails, Markdown preview works

1. Use the skill with this context:

```text
$wispterm-diagnostics
Problem type: ssh-image-preview
Symptom: SSH image preview fails, but Markdown/text preview works.
Repro steps: ...
```

2. Ask the user to confirm the SSH tab was opened from WispTerm's built-in SSH
   profile launcher. Remote previews require WispTerm SSH metadata; a tab where
   the user typed `ssh user@host` inside a local shell is treated as local and
   cannot use remote preview helpers.
3. Ask for the file extension, approximate size, path shape (absolute,
   relative, contains spaces/CJK), and whether both Ctrl-click and File Explorer
   double-click fail.
4. Ask them to Ctrl+Shift-click the same remote image to download it. If
   download also fails, investigate SSH/SCP/path metadata. If download works but
   preview fails, investigate image decode/rendering.

### HTML preview fails

1. Use the skill with this context:

```text
$wispterm-diagnostics
Problem type: html-preview
Symptom: HTML preview or browser panel fails.
Repro steps: ...
```

2. Identify the environment: local Windows, WSL, or SSH. For SSH, confirm it is
   a WispTerm SSH profile session, not a manually typed SSH tab.
3. HTML preview serves the file's directory over HTTP so relative CSS/JS/images
   work. Ask the user to run this in the target environment:

```bash
command -v python3 python node npx
python3 --version 2>/dev/null || true
python --version 2>/dev/null || true
node --version 2>/dev/null || true
npx --version 2>/dev/null || true
```

4. Ask for the visible toast/error text, especially `HTML server not reachable`
   or `HTML SSH tunnel failed`. For SSH HTML, also ask whether normal loopback
   URLs printed by the remote host open through WispTerm.

### SSH disconnects (`ssh_packet_write_poll`, `eother`, idle reset)

1. Use the skill with this context:

```text
$wispterm-diagnostics
Problem type: ssh-disconnect
Symptom: SSH drops with ssh_packet_write_poll/eother or idle-time Connection reset.
Repro steps: ...
```

2. Treat `client_loop: ssh_packet_write_poll ... eother` as a Windows OpenSSH
   network-write failure until evidence says otherwise. Do not anchor on
   unrelated VT warnings such as `CSI t` or `mode 9001`.
3. If the disconnect happens only after 5-10 minutes idle with
   `client_loop: send disconnect: Connection reset`, test it as an
   idle-timeout/keepalive case. WispTerm SSH profile sessions are expected to
   launch OpenSSH with `ServerAliveInterval=60` and `ServerAliveCountMax=3`;
   collect the exact WispTerm version/package and compare external OpenSSH
   with and without those options.
4. Ask for these comparisons:

```powershell
# Outside WispTerm, without keepalive:
ssh.exe -tt user@host

# Outside WispTerm, from Windows Terminal / cmd / PowerShell:
ssh.exe -vvv -tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 user@host

# In WispTerm config, then fully restart and retest:
windows-conpty = system

# If available:
wsl -- ssh -vvv -tt user@host
```

If Windows `ssh.exe` fails outside WispTerm, focus on Win32-OpenSSH, network,
or server logs. If only bundled ConPTY fails, compare `windows-conpty = system`.
If WispTerm fails with both ConPTY modes but external `ssh.exe` does not, then
investigate WispTerm PTY input/output.

## macOS Workflow

No automated script yet. Collect the following manually using bash and paste
the results into a Markdown report:

```bash
# WispTerm version and config path
/Applications/WispTerm.app/Contents/MacOS/wispterm --version
/Applications/WispTerm.app/Contents/MacOS/wispterm --show-config-path

# macOS version and hardware
sw_vers
uname -m
sysctl -n machdep.cpu.brand_string
sysctl -n hw.memsize

# GPU and connected monitors (resolution, DPI, color depth)
system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset|VRAM|Vendor|Metal|Resolution|Pixel Depth|Mirror|Color"

# Config file (sanitize API keys / passwords before pasting)
CONF="$HOME/Library/Application Support/wispterm/config"
[ -f "$CONF" ] && cat "$CONF" || echo "config not found"

# List files under wispterm data dir
ls -la "$HOME/Library/Application Support/wispterm/"

# Recent WispTerm crash reports (last 7 days)
find "$HOME/Library/Logs/DiagnosticReports" -name "WispTerm*" -mtime -7 2>/dev/null

# Render diagnostic log (if present)
# NOTE: the log only exists when wispterm-debug-render = true is set in config.
# For rendering/DPI issues: add that key, restart WispTerm, reproduce the glitch,
# then collect the log.
LOG="$HOME/Library/Application Support/wispterm/render-diagnostic.log"
[ -f "$LOG" ] && tail -80 "$LOG" || echo "render-diagnostic.log not found — add wispterm-debug-render = true to config and reproduce the issue first"

# CPU usage sample (run while WispTerm is showing high CPU)
pid=$(pgrep -x wispterm 2>/dev/null | head -1)
if [ -n "$pid" ]; then
  ps -p "$pid" -o pid,pcpu,pmem,rss,comm
  # macOS: sample over 3 seconds
  top -l 3 -pid "$pid" -stats pid,cpu,mem,time 2>/dev/null | tail -5
else
  echo "wispterm not running"
fi
```

Remind the user to review the output before pasting publicly: remove any API
keys, SSH passwords, tokens, or other sensitive values the config may contain.

## What The Report Covers (Windows script)

- WispTerm version, executable path, package flavor, `version.txt`, config path,
  portable config presence, WebView2Loader.dll, bundled `conpty.dll`, and
  bundled `OpenConsole.exe`.
- Windows edition, display version, build, architecture, locale, PowerShell, and
  current shell process.
- `ssh.exe` / `scp.exe` path and version, plus whether WispTerm's `ssh_hosts`
  file exists and how many saved profiles it contains.
- GPU and driver details, connected monitors with resolutions, WebView2
  runtime version, and nearby `WebView2Loader.dll` presence.
- wispterm.exe CPU sample (3 seconds) when `-ProblemType "high-cpu"` is used.
- Startup/crash context: recent Windows Application Error / Windows Error
  Reporting entries for `wispterm.exe`, sanitized module/exception/offset fields,
  optional startup probe result, WER local dump configuration, and whether dump
  files exist.
- `%APPDATA%\wispterm\wispterm-debug.log` and `render-diagnostic.log` presence
  and sanitized tail excerpts when available.
- Relevant WispTerm files under `%APPDATA%\wispterm`.
- A sanitized WispTerm config excerpt.
- Failed diagnostic commands.

## Privacy Rules

The script is intended to be safe to paste into a public GitHub issue. Do not
add collection of public IP addresses, Wi-Fi passwords, SSH passwords, decoded
SSH profile fields, SSH private keys, tokens, remote session keys, full
environment variable dumps, browser data, process inventories, license keys,
serial numbers, or unique hardware IDs.

The script redacts sensitive config values by default. It also redacts common
local paths (`%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%`, `%TEMP%`), computer
name, Windows SIDs, remote session keys, token/password-like output, and
non-WispTerm URLs. Still remind the user to review the final Markdown before
posting.

Never paste raw Event Viewer XML when the script can summarize it; raw XML can
include machine/user identifiers. Never paste `.dmp` crash dumps into a public
issue.

## Validation (Windows script)

When modifying the script, run on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_wispterm_diagnostics.ps1 -SelfTest
```

Then run a normal report generation command and a startup/crash report command
without `-EnableCrashDumps`. The script must complete even when WispTerm,
OpenSSH, WebView2, Event Viewer records, render diagnostics, or config files are
missing; missing data should be reported as `not found`, `not applicable`, or
`unavailable`.
