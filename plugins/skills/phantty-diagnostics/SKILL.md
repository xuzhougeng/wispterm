---
name: phantty-diagnostics
description: Use when a user (Windows or macOS) wants to report, troubleshoot, or collect context for a Phantty issue, including startup failures, crashes, rendering/DPI/multi-monitor glitches, high CPU usage, keyboard input bugs, selection/copy/scrolling issues, SSH/SCP problems, file explorer behavior, WebView2/browser panel issues (Windows), updater failures, or remote console behavior.
---

# Phantty Diagnostics

## Overview

Generate a safe, copyable Markdown diagnostic report for users filing Phantty
issues. On **Windows**, use the bundled PowerShell script instead of asking the
user to manually discover Phantty, Windows, OpenSSH, WebView2, GPU, and config
details. For startup crashes on Windows, prefer the automated crash workflow so
users do not have to manually copy Event Viewer XML.

On **macOS**, there is no equivalent script yet — use the manual bash workflow
in the macOS section below.

## Windows Workflow

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

Recommended labels: `startup/crash`, `rendering/DPI`, `high-cpu`,
`keyboard/input`, `selection/copy/scrolling`, `SSH/SCP`, `file explorer`,
`WebView2/browser panel`, `updater`, `remote console`, `other`.

4. For **rendering/DPI/multi-monitor glitch** reports, first check whether
   `render-diagnostic.log` is already present. If not, ask the user to add
   `phantty-debug-render = true` to their config (press `Ctrl+,` to open it),
   restart Phantty, reproduce the glitch, then run the script. The log is
   written to `%APPDATA%\phantty\render-diagnostic.log`.

   For **high-cpu** reports, run the script while Phantty is exhibiting the
   high-CPU behavior so the 3-second CPU sample captures the real usage.

5. For startup/crash reports, run the automated startup probe. It enables
`PHANTTY_RENDER_DIAGNOSTICS=1` only for the probe process, starts Phantty with
auto-update disabled, waits briefly, then closes/kills the process if it did
not crash:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_phantty_diagnostics.ps1 -ProblemType "startup/crash" -StartupProbe
```

6. If the user is willing to reproduce a crash and can share a dump privately,
enable Windows Error Reporting local dumps before the startup probe:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_phantty_diagnostics.ps1 -ProblemType "startup/crash" -StartupProbe -EnableCrashDumps
```

This writes HKCU-only WER settings for `phantty.exe` and reports the dump
folder. Do not ask the user to attach `.dmp` files publicly; dumps may contain
terminal text, environment fragments, tokens, paths, or other process memory.

7. Paste the generated Markdown report back to the user. Ask them to review it
   before posting and to fill in blank human-only fields such as the exact
   description and reproduction steps.

## macOS Workflow

No automated script yet. Collect the following manually using bash and paste
the results into a Markdown report:

```bash
# Phantty version and config path
/Applications/Phantty.app/Contents/MacOS/phantty --version
/Applications/Phantty.app/Contents/MacOS/phantty --show-config-path

# macOS version and hardware
sw_vers
uname -m
sysctl -n machdep.cpu.brand_string
sysctl -n hw.memsize

# GPU and connected monitors (resolution, DPI, color depth)
system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset|VRAM|Vendor|Metal|Resolution|Pixel Depth|Mirror|Color"

# Config file (sanitize API keys / passwords before pasting)
CONF="$HOME/Library/Application Support/phantty/config"
[ -f "$CONF" ] && cat "$CONF" || echo "config not found"

# List files under phantty data dir
ls -la "$HOME/Library/Application Support/phantty/"

# Recent Phantty crash reports (last 7 days)
find "$HOME/Library/Logs/DiagnosticReports" -name "Phantty*" -mtime -7 2>/dev/null

# Render diagnostic log (if present)
# NOTE: the log only exists when phantty-debug-render = true is set in config.
# For rendering/DPI issues: add that key, restart Phantty, reproduce the glitch,
# then collect the log.
LOG="$HOME/Library/Application Support/phantty/render-diagnostic.log"
[ -f "$LOG" ] && tail -80 "$LOG" || echo "render-diagnostic.log not found — add phantty-debug-render = true to config and reproduce the issue first"

# CPU usage sample (run while Phantty is showing high CPU)
pid=$(pgrep -x phantty 2>/dev/null | head -1)
if [ -n "$pid" ]; then
  ps -p "$pid" -o pid,pcpu,pmem,rss,comm
  # macOS: sample over 3 seconds
  top -l 3 -pid "$pid" -stats pid,cpu,mem,time 2>/dev/null | tail -5
else
  echo "phantty not running"
fi
```

Remind the user to review the output before pasting publicly: remove any API
keys, SSH passwords, tokens, or other sensitive values the config may contain.

## What The Report Covers (Windows script)

- Phantty version, executable path, package flavor, `version.txt`, config path,
  and portable config presence.
- Windows edition, display version, build, architecture, locale, PowerShell, and
  current shell process.
- `ssh.exe` / `scp.exe` path and version, plus whether Phantty's `ssh_hosts`
  file exists and how many saved profiles it contains.
- GPU and driver details, connected monitors with resolutions, WebView2
  runtime version, and nearby `WebView2Loader.dll` presence.
- phantty.exe CPU sample (3 seconds) when `-ProblemType "high-cpu"` is used.
- Startup/crash context: recent Windows Application Error / Windows Error
  Reporting entries for `phantty.exe`, sanitized module/exception/offset fields,
  optional startup probe result, WER local dump configuration, and whether dump
  files exist.
- `%APPDATA%\phantty\render-diagnostic.log` presence and a sanitized tail
  excerpt when available.
- Relevant Phantty files under `%APPDATA%\phantty`.
- A sanitized Phantty config excerpt.
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
non-Phantty URLs. Still remind the user to review the final Markdown before
posting.

Never paste raw Event Viewer XML when the script can summarize it; raw XML can
include machine/user identifiers. Never paste `.dmp` crash dumps into a public
issue.

## Validation (Windows script)

When modifying the script, run on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_phantty_diagnostics.ps1 -SelfTest
```

Then run a normal report generation command and a startup/crash report command
without `-EnableCrashDumps`. The script must complete even when Phantty,
OpenSSH, WebView2, Event Viewer records, render diagnostics, or config files are
missing; missing data should be reported as `not found`, `not applicable`, or
`unavailable`.
