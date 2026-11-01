# Windows Explorer context menu

WispTerm can add **Open in WispTerm** / **在 WispTerm 中打开** to the
Windows 11 context menu for a single filesystem folder or the background of an
open folder. The command opens a new WispTerm window with that directory via
`--working-directory`; explicit directory launches skip session restore. Drive
roots work through the background menu after opening the drive. Files, virtual
folders, archives, and multiple selections are not offered this command.

The integration supports x64 Windows 10 2004 and later. Windows 11 uses its
modern context menu; Windows 10 uses its classic menu. This is an independent
WispTerm command, not a replacement for Windows Terminal's entry.

## Enable and remove

Extract the entire Windows zip to a stable local installation directory. A
**trusted signed identity package** is required for normal installation. The
ordinary unsigned desktop executable alone cannot register this modern menu.
Unsigned developer bundles contain the integration payload but their
`Add-Context-Menu.cmd` reports that a signed release is required.

- Run `Add-Context-Menu.cmd` to enable the menu for the current Windows user.
- Run `Remove-Context-Menu.cmd` to remove it.
- To inspect registration, run `powershell -NoProfile -File .\context-menu.ps1 -Action Status`.
- `Replace-WispTerm.cmd` refreshes registration if that installation already
  owns it. To opt in during first installation, run
  `powershell -NoProfile -File .\replace-install.ps1 -EnableContextMenu`.
- `Uninstall-WispTerm.cmd` unregisters the menu before removing application
  payloads, preserving user configuration, plugins and unrelated files.

Close that WispTerm installation before changing an existing registration;
registration scripts do not terminate terminal sessions. Reopen Explorer after
registration. If Windows caches the previous menu, sign out and back in. The
scripts do not restart Explorer, elevate, import certificates, or enable
Developer Mode.

When moving a portable installation, run `Add-Context-Menu.cmd` from the new
location. This rebinds the current user's registration. Running the removal
script from an old copy does not remove the new copy's menu. Unregister before
manually deleting the active installation directory.

## Packaging and signing

`zig build` builds the standalone `wispterm-shell-extension.dll` alongside the
Windows desktop app. `zig build shell-extension` builds only that DLL.
`packaging/windows/package.ps1` packages it with every Windows bundle.

The Windows SDK's `MakeAppx.exe` and `mt.exe` are needed for packaging;
`SignTool.exe` is also needed when signing. The scripts discover the x64 SDK
tools automatically. The identity package version comes from `build.zig.zon`,
using `major.minor.patch.0`, independently of a descriptive zip filename.

To sign, install the release signing certificate, including its private key,
in the build account's `Cert:\CurrentUser\My` store and set
`WISPTERM_WINDOWS_SIGN_THUMBPRINT` to its thumbprint. The package publisher and
the embedded executable identity are generated from that certificate's subject.
The identity package is timestamped when signed. Without a signing certificate,
packaging produces an explicitly unsigned developer identity package; it does
not create or trust a self-signed certificate automatically.

`WINDOWS_SIGNING_PFX_BASE64` and `WINDOWS_SIGNING_PFX_PASSWORD` are deprecated.
The tag workflow still imports them when they are set, uses that certificate
only for this identity package, and removes it from the runner afterward. Those
secrets do not Authenticode-sign `wispterm.exe`. Tag releases sign
`wispterm.exe`, `wispterm-ssh-askpass.exe`, and `wispterm-shell-extension.dll`
with SSL.com eSigner before the portable zips are created. CodeSignTool does
not sign the `.msix`, so an end-user context menu still needs this deprecated
PFX (or a local `WISPTERM_WINDOWS_SIGN_THUMBPRINT`) until the package publisher
is taken from the eSigner certificate. No Windows release certificate or eSigner
secret is checked in. See `docs/development.md` for the eSigner secret names,
the RFC3161 timestamp, and SmartScreen reputation.

Each package registers `IExplorerCommand` using `windows.comServer` and
`windows.fileExplorerContextMenus`. A sparse identity package points to the
existing EXE installation through `Add-AppxPackage -ExternalLocation`, preserving
the portable distribution. The identity explicitly disables registry/AppData
write virtualization so the terminal continues using its existing user configuration and state paths.
Extension DLLs and their MSIX/manifest are stored in
immutable version/content directories so updates don't overwrite Explorer's
loaded DLL. The installer retains prior directories for registration rollback;
uninstall removes them after unregistration, with a notice if Windows still
holds a file open. A failed re-registration attempts to restore the previous
package and retains its ownership record.

## Verification

```powershell
zig build shell-extension-test
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-shell-integration.ps1
```

This builds an unsigned test identity package and tests the DLL through actual
COM interfaces, including folder/background selection, object lifetime,
non-folder and multi-selection rejection, direct process creation, Unicode and
space-containing paths, and Windows argv quoting (UNC and trailing root slash).
It uses a small launch recorder in an isolated temporary directory and does not
register a package or modify certificate trust.

For full registration tests on a disposable Windows account, configure an
already trusted signing certificate as above and add `-RegisterPackage`. These
checks install and activate packaged COM, test idempotence and relocation, and
remove the package afterward. CI performs this on its disposable runner with a
short-lived test certificate; test certificates are never distributed.

For loose-manifest debugging on a machine where **you have explicitly enabled
Developer Mode**, run `context-menu.ps1 -Action Install -Development` from a
packaged developer installation. Remove it with the normal removal script.
This is a development path, not an end-user installation method.

Also verify Explorer visually on Windows 11: folder right-click, folder
background, drive-root background, Chinese and English display languages,
correct initial shell directory, and disappearance after removal. COM tests
exercise the actual registered command but do not assert Explorer's visual
placement.

## Reference design

Ghostty keeps directory-opening integration in the OS host: its
[Dolphin service](https://github.com/ghostty-org/ghostty/blob/main/dist/linux/ghostty_dolphin.desktop)
passes `--working-directory`, and its
[macOS services](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/Services/ServiceProvider.swift)
pass the selected directory to window/tab creation. WispTerm uses that same
boundary. Its Windows adapter follows
[Windows Terminal's OpenTerminalHere](https://github.com/microsoft/terminal/blob/main/src/cascadia/ShellExtension/OpenTerminalHere.cpp)
for selection/site folder resolution and direct `CreateProcessW` launch.

See Microsoft's [Explorer extension documentation](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer)
and [external-location identity packaging documentation](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps)
for the registration, manifest and signing requirements.
