# Installation

*English · [中文](Installation-zh)*

> Download and run WispTerm on Windows, macOS, or experimental Linux, or build it from source.

WispTerm ships for **Windows** and **macOS**. A **Linux** x86_64 AppImage is
also published for community testing and remains experimental.

## Windows

1. Download the latest Windows release from
   [GitHub Releases](https://github.com/xuzhougeng/wispterm/releases).
2. Unzip the whole archive to a folder.
3. Run **`wispterm.exe`**, or double-click **`Replace-WispTerm.cmd`** to copy
   this folder over the Start-menu install (or into
   `%LOCALAPPDATA%\Programs\WispTerm` and create that shortcut).

WispTerm does not elevate shells on its own — a normally launched window gives
you a standard token. To run an elevated shell, right-click `wispterm.exe` and
choose **Run as administrator** (see [[FAQ]]).

**Portable profile (Windows only):** put a file named `wispterm.conf` next to
`wispterm.exe` and WispTerm uses it as the config, so the whole setup is
self-contained on a USB stick or shared folder.

## macOS

Requires **macOS 13+**. Download the `.app` for your CPU (Apple Silicon or
Intel) and move it to `/Applications`.

- Launch **`WispTerm.app`** normally, **or**
- Run the binary directly to pass CLI flags:
  ```bash
  WispTerm.app/Contents/MacOS/WispTerm --version
  ```

> Passing command-line options requires the binary path — double-clicking the
> `.app` cannot take flags.

## Linux (experimental)

Download the `WispTerm-*-x86_64.AppImage` release asset, mark it executable, and
run it:

```bash
chmod +x WispTerm-*-x86_64.AppImage
./WispTerm-*-x86_64.AppImage
```

On hosts without FUSE support, add `--appimage-extract-and-run`. The Linux build
bundles SDL3 and is intended for community testing; it is not yet considered
stable.

## Build from source

Requires **Zig 0.15.2**.

Windows (PowerShell):

```powershell
zig build                         # Debug build for development
zig build -Doptimize=ReleaseFast  # ReleaseFast build for distribution
```

macOS:

```bash
zig build macos-app -Dtarget=aarch64-macos   # Apple Silicon (use x86_64-macos on Intel)
open zig-out/bin/WispTerm.app
```

For full build, packaging, and release details see
[`docs/development.md`](https://github.com/xuzhougeng/wispterm/blob/main/docs/development.md).

## Verify the install

```bash
wispterm --version            # print the WispTerm version
wispterm --show-config-path   # print the resolved config path
```

## Staying up to date

By default WispTerm checks [GitHub Releases](https://github.com/xuzhougeng/wispterm/releases)
shortly after startup and shows a clickable prompt when a newer version is
available. Set `auto-update-check = false` to turn that off. You can also update
on demand from the [[command center|Getting-Started]]:

- **Check for Updates** — look for a newer release now.
- **Download Update** — download the latest release into your Downloads folder.
- **Open Latest Release** — open the release page in a browser.

On Windows, unzip the download and double-click **`Replace-WispTerm.cmd`** to
overwrite the Start-menu install.

After upgrading, **What's New** (in the command center, and shown automatically
the first time you launch a new version) summarizes what changed. **Update
Skills** downloads the latest bundled AI skills from GitHub.

Next: **[[Getting-Started]]**.

---
*See also: [[Getting-Started]] · [[Configuration]]*
