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

## How do I report a crash or freeze? (Windows debug build)

Every Windows release also ships a **`wispterm-windows-debug-<version>.zip`** on
the [Releases](https://github.com/xuzhougeng/wispterm/releases) page. It is a
console build with extra safety checks that writes a log to
`%APPDATA%\wispterm\wispterm-debug.log` (and a `crash-<timestamp>.txt` if it
crashes). To help diagnose a hard-to-reproduce issue — for example a crash when
opening the WeChat connection, or a freeze when Ctrl+clicking a remote file —
download it, reproduce the problem, then attach `wispterm-debug.log` (and any
`crash-*.txt`) to your report.

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

WispTerm ships for **Windows** and **macOS** today. The **Linux** port is still
in progress — track it in
[`TODO.md`](https://github.com/xuzhougeng/wispterm/blob/main/TODO.md).

---
*See also: [[Configuration]] · [[Remote-Access]] · [[Home]]*
