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

## How Do I Update the Built-in AI Skills?

Run **Update Skills** from the command center to download the latest bundled
skills from GitHub into your platform config directory. Existing conversations
keep the skill version they originally loaded, so updating does not change past
chats.
