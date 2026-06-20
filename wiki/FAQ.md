# FAQ & Troubleshooting

*English · [中文](FAQ-zh)*

> Common questions about elevation, remote access, configuration, and platform support.

## Why isn't my shell running as Administrator? (Windows)

WispTerm does not elevate shells on its own. Shells inherit the same privilege
level as the running `wispterm.exe` process. Starting WispTerm normally (a
double-click or non-elevated shortcut) gives you a standard token, even if your
account is in the Administrators group (UAC split token).

## How do I run an elevated shell? (Windows)

- **Run WispTerm elevated:** right-click `wispterm.exe` or its shortcut and
  choose **Run as administrator**. New tabs inherit the elevated token after UAC
  approval.
- **Separate elevated window only:** from any shell, run
  `Start-Process pwsh -Verb RunAs` (or `powershell`). This starts a new elevated
  process after UAC; it does not replace the current tab.

There is no supported way to promote an existing non-elevated shell to elevated
without a new process and UAC consent.

## Mouse wheel / scrollbars don't work in Codex or Claude Code (Windows 10)

Older Windows 10 builds ship an in-box ConPTY console host that does not
forward modern mouse input, so full-screen TUI apps such as **Codex** and
**Claude Code** lose wheel scrolling and scrollbar interaction inside the
terminal.

Fix: use the **`wispterm-windows-portable-compat-*.zip`** release package
(available since v1.19.0). It bundles a modern `conpty.dll` +
`OpenConsole.exe` next to `wispterm.exe`, and WispTerm prefers that bundled
pair automatically whenever both files are present (`windows-conpty = auto`,
the default). To force the OS in-box ConPTY instead, set
`windows-conpty = system` — see [[Configuration]].

Important: **extract the whole zip to a folder and launch `wispterm.exe` from
there** so `conpty.dll` and `OpenConsole.exe` stay next to it. Running
`wispterm.exe` straight from inside the zip (Explorer extracts only the exe to a
temp folder) leaves those files behind, WispTerm silently falls back to the OS
in-box ConPTY, and wheel scrolling/scrollbars break again.

## Selecting text interrupts the program (^C), or copy doesn't actually copy

If selecting text in the terminal interrupts the running program (a `^C`
appears, a command is cancelled, or you drop out of **Codex** / **Claude
Code**), or a copy reports success but pasting returns your *previous*
clipboard, the cause is almost always a **"select-to-translate" /
"copy-on-selection" utility** running in the background — e.g. 有道词典 (Youdao
Dictionary) 划词翻译, 欧路词典, QTranslate, or some mouse/touchpad drivers and
clipboard managers.

These tools detect a mouse text selection and synthesize a **Ctrl+C** keystroke
to grab the text. In a normal GUI app Ctrl+C means "copy", but **in a terminal
Ctrl+C is the interrupt key (SIGINT)**, so it interrupts whatever is running.
Many of them also restore your old clipboard afterward, so a deliberate copy
from the terminal can appear to succeed yet paste nothing.

Why WispTerm and not conhost / Windows Terminal? Those expose the terminal's
text and selection through **UI Automation (UIA)**, so the utilities read the
selection directly without sending Ctrl+C. WispTerm has no UIA text source yet,
so they fall back to the Ctrl+C method.

Fix: disable the tool's "copy on selection" / 划词 feature (for 有道词典:
设置 → 取词划词 → turn off 划词翻译), exclude WispTerm, or quit it. To confirm a
background tool is responsible, select text with **Shift + arrow keys**
(keyboard only): if that does not trigger the interrupt, a pointing-device /
selection utility is the cause.

## WispTerm is laggy or turns black on a low-spec PC (weak integrated GPU)

On Windows, WispTerm presents frames through a DXGI flip-model swapchain by
default. On machines with a weak integrated GPU — typically Win11
thin-and-light laptops — that path can be noticeably slow (v1.18.0), and
v1.19.0 could even leave the window black.

Since **v1.19.1** WispTerm detects a sustained-slow or broken present path on
its own: the first launch after upgrading may still feel slow once, and from
the **next** launch onward the app permanently switches to the classic GDI
presenter on that machine — both the lag and the black screen disappear.
Running on a discrete or external GPU avoids the slow path entirely.

To opt out manually at any time, set `wispterm-d3d-present = false` — see
[[Configuration]].

## How do I switch AI models without starting a new chat?

In an AI Chat tab or Copilot sidebar, type `/model` to open the saved-profile
picker, `/model <name>` to switch directly by profile name, or `/模型` for the
Chinese alias. You can also click the model label in the chat/Copilot header.

The switch only affects the current session. It does not change your global
default profile or overwrite the saved profile. WispTerm asks the new model to
summarize the prior transcript in the background and shows that handoff as a
collapsible **Conversation summary** card; if the summary fails, the full raw
history stays available.

## How do I generate a diagnostic report?

Windows release packages include the `wispterm-diagnostics` skill. For normal
bug reports, open a WispTerm AI Chat tab or Copilot sidebar and ask the bundled
skill to collect the environment, analyze the issue, and draft a GitHub issue
body:

If the skill is missing or outdated, open **Skill Center** and download/update
the latest skills from GitHub first.

```text
$wispterm-diagnostics
Problem type: ssh-disconnect
Symptom: SSH Profile disconnects after 5-10 minutes idle with "Connection reset".
Repro steps: connect to the saved SSH profile, leave it idle, then run ls.
What I already tried: external ssh.exe with ServerAliveInterval works.
```

Use a more specific problem type when it matches your issue:

- `ssh-image-preview` — SSH image preview fails while Markdown/text preview works.
- `html-preview` — local/WSL/SSH `.html` preview or the browser panel fails.
- `ssh-disconnect` — SSH drops with errors such as `ssh_packet_write_poll`,
  `eother`, or idle-time `Connection reset`.
- `startup/crash`, `rendering/DPI`, `high-cpu`, `keyboard/input`,
  `selection/copy/scrolling`, `SSH/SCP`, `file explorer`,
  `WebView2/browser panel`, `updater`, or `remote console`.

The skill generates a Markdown report with WispTerm version, package files,
Windows/OpenSSH/WebView2/GPU details, sanitized config, relevant logs, your
symptom/repro steps, and issue-specific next steps. Paste that Markdown into the
GitHub issue after reviewing it; do not include passwords, private keys, tokens,
or crash dumps in a public issue.

Fallback: if WispTerm cannot start, or the AI Agent is unavailable, run the
collector manually from the installed/extracted WispTerm folder that contains
`plugins\skills\wispterm-diagnostics`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\plugins\skills\wispterm-diagnostics\scripts\collect_wispterm_diagnostics.ps1 -ProblemType "other"
```

## How do I report a crash or freeze? (Windows debug build)

Every Windows release also ships a **`wispterm-windows-debug-<version>.zip`** on
the [Releases](https://github.com/xuzhougeng/wispterm/releases) page. It is a
console build with extra safety checks that writes a log to
`%APPDATA%\wispterm\wispterm-debug.log` (and a `crash-<timestamp>.txt` if it
crashes). To help diagnose a hard-to-reproduce issue — for example a crash when
opening the WeChat connection, or a freeze when Ctrl+clicking a remote file —
download it, reproduce the problem, then attach `wispterm-debug.log` (and any
`crash-*.txt`) to your report.

For Ctrl+click preview/browser issues, the debug log also includes copyable
single-line records that begin with `preview-diagnostic`. After reproducing the
problem, paste the nearby `preview-diagnostic` lines into the issue if the full
log is too large. They cover preview path resolution, async file reads, image
decode, HTML server startup, SSH browser tunnels, URL routing, and the embedded
browser panel.

## Why does remote mirror the local terminal size on phones?

WispTerm Remote mirrors the local window because the desktop app is the source
of truth for terminal state — the local PTY, VT state, scrollback, cursor, and
split layout are captured there and streamed to the browser. The mobile UI can
refocus a single surface, but it does not currently create a separate
phone-sized terminal grid. See [[Remote-Access]].

## Where is my config, and how do I hot-reload it?

Run `wispterm --show-config-path` to print the resolved path, or press `Ctrl+,`
(`Cmd+,` on macOS) to open it in your editor. Saving the file applies most
changes without a restart. Full details and the key reference are in
[[Configuration]].

## Is there a Linux build?

Yes, but it is experimental. Releases include a Linux x86_64 AppImage for
community testing. It bundles SDL3 and is useful for early feedback, but the
Linux port is not yet considered stable. Run it from a terminal so startup or
graphics errors are visible.

---
*See also: [[Configuration]] · [[Remote-Access]] · [[Home]]*
