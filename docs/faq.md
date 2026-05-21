# FAQ

## Why Isn't My Default PowerShell Running as Administrator?

Phantty does not elevate shells on its own. Shells inherit the same privilege
level as the running `phantty.exe` process. Starting Phantty normally (for
example double-click or a non-elevated shortcut) gives you a standard token,
even if your account is in the Administrators group (UAC split token).

## How Do I Run an Elevated Administrator Shell?

- **Run Phantty elevated:** Right-click `phantty.exe` or its shortcut and choose
  **Run as administrator**. New tabs in that instance inherit the elevated
  token, so the default profile should show Administrator-level access after UAC
  approval.
- **Separate elevated window only:** From any shell,
  `Start-Process pwsh -Verb RunAs` (or `powershell`) starts a new elevated
  process after UAC; it does not replace the current Phantty tab.

There is no supported way to promote an existing non-elevated shell to elevated
without a new process and UAC consent.

## Why Does Phantty Remote Mirror the Local Terminal Size on Phones?

Phantty Remote mirrors the local Phantty window because the desktop app is the
source of truth for terminal state. The local PTY, Ghostty VT state, scrollback,
cursor position, and split layout are captured there and sent to the browser as
layout snapshots plus output bytes.

The remote web UI can rearrange how panels are shown, for example focusing one
surface on mobile instead of squeezing every split into the viewport. It does
not currently create a separate mobile-sized terminal grid. Reflowing the
terminal to the phone width would require either resizing the local terminal
itself, which would disturb the desktop session, or adding a separate remote PTY
or viewport model.
