# Installation

*English · [中文](Installation-zh)*

> Download and run WispTerm on Windows or macOS, or build it from source.

WispTerm ships for **Windows** and **macOS**. The Linux port is still in
progress (see [`TODO.md`](https://github.com/xuzhougeng/wispterm/blob/main/TODO.md)).

## Windows

1. Download the latest Windows release from
   [GitHub Releases](https://github.com/xuzhougeng/wispterm/releases).
2. Unzip it and run **`wispterm.exe`**.

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
  WispTerm.app/Contents/MacOS/wispterm --version
  ```

> Passing command-line options requires the binary path — double-clicking the
> `.app` cannot take flags.

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

After upgrading, **What's New** (in the command center, and shown automatically
the first time you launch a new version) summarizes what changed. **Update
Skills** downloads the latest bundled AI skills from GitHub.

Next: **[[Getting-Started]]**.

---
*See also: [[Getting-Started]] · [[Configuration]]*
