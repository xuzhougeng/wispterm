# FAQ

## Why Isn't My Default PowerShell Running as Administrator?

WispTerm does not elevate shells on its own. Shells inherit the same privilege
level as the running `wispterm.exe` process. Starting WispTerm normally (for
example double-click or a non-elevated shortcut) gives you a standard token,
even if your account is in the Administrators group (UAC split token).

## How Do I Run an Elevated Administrator Shell?

- **Run WispTerm elevated:** Right-click `wispterm.exe` or its shortcut and choose
  **Run as administrator**. New tabs in that instance inherit the elevated
  token, so the default profile should show Administrator-level access after UAC
  approval.
- **Separate elevated window only:** From any shell,
  `Start-Process pwsh -Verb RunAs` (or `powershell`) starts a new elevated
  process after UAC; it does not replace the current WispTerm tab.

There is no supported way to promote an existing non-elevated shell to elevated
without a new process and UAC consent.

## Why Don't Mouse Wheel and Scrollbars Work in Codex or Claude Code on Windows 10?

Older Windows 10 builds ship an in-box ConPTY console host that does not
forward modern mouse input, so full-screen TUI apps such as Codex and Claude
Code lose wheel scrolling and scrollbar interaction inside the terminal.

Use the `wispterm-windows-portable-compat-*.zip` release package (available
since v1.19.0). It bundles a modern `conpty.dll` + `OpenConsole.exe` next to
`wispterm.exe`, and WispTerm prefers that bundled pair automatically whenever
both files are present (`windows-conpty = auto`, the default). Set
`windows-conpty = system` to force the OS in-box ConPTY instead.

Important: **extract the whole zip to a folder and launch `wispterm.exe` from
there** so `conpty.dll` and `OpenConsole.exe` stay next to it. If you run
`wispterm.exe` straight from inside the zip (Explorer extracts only the exe to a
temporary folder), those two files are left behind, WispTerm silently falls back
to the OS in-box ConPTY, and wheel scrolling/scrollbars stop working again.

## Why Does Selecting Text Interrupt the Program (^C), or "Copy" Not Actually Copy?

If selecting text in the terminal interrupts the running program — a `^C`
appears, a command is cancelled, or you get knocked out of Codex / Claude Code —
or if a copy reports success but pasting returns your *previous* clipboard, the
cause is almost always a **"select-to-translate" / "copy-on-selection" utility**
running in the background. Common culprits: 有道词典 (Youdao Dictionary) 划词翻译,
欧路词典, QTranslate, and some mouse/touchpad drivers or clipboard managers.

These tools watch for a mouse text selection and then synthesize a **Ctrl+C**
keystroke to grab the selected text. In a normal GUI app Ctrl+C means "copy",
but **in a terminal Ctrl+C is the interrupt key (SIGINT)** — so it interrupts
whatever is running. Many of them also restore your old clipboard afterward,
which is why a deliberate copy from the terminal can look like it worked yet
paste nothing.

Why does this hit WispTerm and not conhost / Windows Terminal? Those expose the
terminal's text and selection through **UI Automation (UIA)**, so the utilities
read the selection directly and never send Ctrl+C. WispTerm does not yet provide
a UIA text source, so the utilities fall back to the Ctrl+C method.

Fix: turn off the tool's "copy on selection" / 划词 feature (for 有道词典:
设置 → 取词划词 → disable 划词翻译), add WispTerm to its exclusions, or quit it.
To confirm a background tool is responsible, select text with **Shift + arrow
keys** (keyboard only, no mouse): if that does *not* trigger the interrupt, a
pointing-device/selection utility is the cause.

## How Do I Copy and Paste Inside tmux (or Other Mouse-Mode Programs)?

When tmux runs with `set -g mouse on` (or a full-screen app enables mouse
tracking), WispTerm forwards mouse presses and drags to the program, so a plain
drag drives tmux's own copy mode instead of selecting text in WispTerm. That is
by design — and every part of the normal copy/paste workflow still works:

- **Select: hold Shift while dragging.** Shift bypasses the program's mouse
  mode and makes a normal WispTerm selection, exactly like other terminals.
  Shift-click extends the selection from the previous anchor.
- **Copy: `Ctrl+Shift+C`** (macOS: `Cmd+C`) copies the current selection to the
  system clipboard. `copy-on-select = true` in the config copies automatically
  as soon as you finish selecting.
- **Paste: `Ctrl+V`** (macOS: `Cmd+V`) pastes clipboard text into the terminal,
  tmux included. `Ctrl+Shift+V` pastes an image from the clipboard and falls
  back to a text paste when the clipboard holds no image.
- **Right-click:** set `right-click-action = copy-or-paste` in the config to
  make right-click copy the selection (or paste when nothing is selected).
  Inside tmux with mouse mode on, a plain right-click is forwarded to tmux
  (which shows tmux's own menu); hold **Shift and right-click** to use
  WispTerm's configured action instead.
- **Copy from tmux's own copy mode:** WispTerm applies OSC 52 clipboard writes,
  so text yanked with tmux's internal copy mode can land on the system
  clipboard — put `set -g set-clipboard on` in `.tmux.conf` on the remote host
  (over SSH, the remote `TERM` must advertise clipboard support; tmux ≥ 3.2 with
  `set -as terminal-features ',*:clipboard'` works with any `TERM`).

## Why Is WispTerm Laggy or Black on a Low-Spec PC (Weak Integrated GPU)?

On Windows, WispTerm presents frames through a DXGI flip-model swapchain by
default. On machines with a weak integrated GPU — typically Win11
thin-and-light laptops — that path can be noticeably slow (v1.18.0), and
v1.19.0 could even leave the window black.

Since v1.19.1 WispTerm detects a sustained-slow or broken present path on its
own: the first launch after upgrading may still feel slow once, and from the
next launch onward the app permanently switches to the classic GDI presenter
on that machine — both the lag and the black screen disappear. Running on a
discrete or external GPU avoids the slow path entirely. To opt out manually
at any time, set `wispterm-d3d-present = false`.

## What Should I Do If the First Launch Opens a Black Window?

On weak integrated-GPU machines, the first launch after installing or upgrading
can still hit the DXGI bring-up path before WispTerm has learned that the
machine needs the GDI fallback. Close all WispTerm windows and start it again;
the next launch should use the recorded fallback path.

If it still opens black, disable the DXGI presenter manually. Create or edit
`%APPDATA%\wispterm\config` and add:

```conf
wispterm-d3d-present = false
```

If WispTerm cannot stay open long enough to use `Ctrl+,`, run this from
PowerShell and then reopen WispTerm:

```powershell
New-Item -ItemType Directory -Force "$env:APPDATA\wispterm" | Out-Null
Add-Content -Path "$env:APPDATA\wispterm\config" -Value "wispterm-d3d-present = false"
```

## Which Windows Package Should I Download?

Use `wispterm-windows-portable-*.zip` by default. It uses the OpenGL renderer
and is the recommended Windows package.

Use `wispterm-windows-portable-compat-*.zip` on older Windows 10 machines or
when you want the embedded browser loader and bundled modern ConPTY next to the
exe.

Use `wispterm-windows-portable-native-d3d11-*.zip` only when you want to test
the Windows native D3D11 renderer and send feedback. If it opens a black window,
crashes, misses UI, fails resize, or behaves badly over RDP, VM, hybrid GPU, or
mixed-DPI monitor setups, switch back to the default OpenGL package. Include a
diagnostic report plus GPU/driver, Windows version, RDP/VM status, hybrid-GPU
status, and monitor/DPI topology when reporting the issue.

## Why Does WispTerm Remote Mirror the Local Terminal Size on Phones?

WispTerm Remote mirrors the local WispTerm window because the desktop app is the
source of truth for terminal state. The local PTY, Ghostty VT state, scrollback,
cursor position, and split layout are captured there and sent to the browser as
layout snapshots plus output bytes.

The remote web UI can rearrange how panels are shown, for example focusing one
surface on mobile instead of squeezing every split into the viewport. It does
not currently create a separate mobile-sized terminal grid. Reflowing the
terminal to the phone width would require either resizing the local terminal
itself, which would disturb the desktop session, or adding a separate remote PTY
or viewport model.

## How Do I Find a Command or Feature?

Press `Ctrl+Shift+P` (`Cmd+Shift+P` on macOS) to open the command center. Type
to filter, then run an action — almost every app feature is reachable from here,
so it is the fastest way to discover what WispTerm can do. The command center
also includes a Copilot history picker for resuming past AI sessions.

## How Do I Switch AI Models Without Starting a New Chat?

In an AI Chat tab or Copilot sidebar, type `/model` to open the saved-profile
picker, `/model <name>` to switch directly by profile name, or `/模型` for the
Chinese alias. You can also click the model label in the chat/Copilot header.

The switch only affects the current session. It does not change your global
default profile or overwrite the saved profile. WispTerm asks the new model to
summarize the prior transcript in the background and shows that handoff as a
collapsible **Conversation summary** card; if the summary fails, the full raw
history stays available. Before compacting, WispTerm also saves the original
conversation as a separate history checkpoint, so you can type `/resume` and
reopen the pre-switch conversation even if the summary request fails.

## How Do I Update WispTerm?

By default WispTerm checks GitHub Releases shortly after startup and shows a
clickable prompt when a newer version is available (set `auto-update-check =
false` to disable that startup check). You can also update on demand from the
command center:

- **Check for Updates** — query GitHub Releases for a newer version.
- **Download Update** — download the latest release to your Downloads folder.
- **Open Latest Release** — open the latest WispTerm GitHub Release page in a
  browser.

After upgrading, run **What's New** from the command center (it also pops up
automatically the first time you launch a new version) to see what changed.

## Is There a Linux Build?

Yes, but it is experimental. Releases include a Linux x86_64 AppImage for
community testing. It bundles SDL3 and is useful for early feedback, but the
Linux port is not yet considered stable. Run it from a terminal so startup or
graphics errors are visible.

## How Do I Update the Built-in AI Skills?

Open **Skill Center** from the command center to inventory, install, and sync
your Claude Code / Codex skills across servers — including installing the latest
skills from a GitHub repository. Existing conversations keep the skill version
they originally loaded, so updating does not change past chats.

Skill Center also accepts local executable tools. Tools are imported as skills:
WispTerm stores the binary, keeps a canonical `SKILL.md`, and exposes enabled
tools as AI Agent function tools. If a binary has neither `--skill` nor a
packaged `SKILL.md`, WispTerm can draft one from limited metadata with your
configured AI profile and asks you to review it before enabling the tool.
Imported executable tools keep their existing enable/disable state.
First-party WispTerm Agent tools, including web, terminal, file, docs, and
memory tools, appear in the same inventory with separate state in
`agent_tools.json`. Turning a built-in tool off hides it from newly built AI
request schemas/tool lists, and runtime execution rejects stale or hallucinated
calls for that disabled tool.

## How Do I Generate a Diagnostic Report?

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

## How Do I Report a Crash or Freeze? (Windows Debug Build)

Every Windows release also ships a **`wispterm-windows-debug-<version>.zip`** on
the Releases page. It is a console build with extra safety checks that writes a
log to `%APPDATA%\wispterm\wispterm-debug.log` (and a `crash-<timestamp>.txt` if
it crashes). To help diagnose a hard-to-reproduce issue — for example a crash
when opening the WeChat connection, or a freeze when Ctrl+clicking a remote
file — download it, reproduce the problem, then attach `wispterm-debug.log` (and
any `crash-*.txt`) to your report.

For Ctrl+click preview/browser issues, the debug log also includes copyable
single-line records that begin with `preview-diagnostic`. After reproducing the
problem, paste the nearby `preview-diagnostic` lines into the issue if the full
log is too large. They cover preview path resolution, async file reads, image
decode, HTML server startup, SSH browser tunnels, URL routing, and the embedded
browser panel.
