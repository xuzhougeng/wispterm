# SP6 — Linux packaging & desktop integration

Sub-project 6 of the Linux port roadmap
([2026-06-08-linux-port-design.md](2026-06-08-linux-port-design.md)). Produces
the Linux distribution artifacts, mirroring the existing `packaging/windows/`
and `packaging/macos/` pattern.

## Goal

Ship the Linux build: an **AppImage** (single-file, portable) as the primary
artifact, plus desktop integration (`.desktop`, icon, AppStream metainfo), a
**Flatpak** manifest, and a CI workflow — so a user can download and run it.

## Verifiability note

AppImage tooling (`linuxdeploy`/`appimagetool`) and `flatpak-builder` are not
installed in the dev sandbox, and running an AppImage needs FUSE (often absent
on WSL). So: the packaging **files/scripts are the deliverable** (correct,
CI-ready); I attempt a local AppImage build to validate the script, but the
authoritative build is the CI workflow, and "runs on a clean distro" is verified
by CI / the user. The Linux exe itself already builds (`zig build
-Dtarget=x86_64-linux-gnu`).

## Deliverables

### Desktop integration — `packaging/linux/`
- **`wispterm.desktop`** — `[Desktop Entry]` `Name=WispTerm`, `Exec=wispterm`,
  `Icon=wispterm`, `Type=Application`, `Categories=System;TerminalEmulator;`,
  `Terminal=false`, `Comment=...`.
- **`com.wispterm.terminal.metainfo.xml`** — AppStream metainfo (id
  `com.wispterm.terminal`, name, summary, the `wispterm.desktop` launchable,
  a screenshot slot, the project URL, an OARS content-rating + a `<releases>`
  entry for `1.15.0`). Required by Flathub / GNOME Software.
- Icon: reuse `assets/wispterm.png` installed as
  `share/icons/hicolor/<size>/apps/wispterm.png` (256×256 source; AppImage/CI
  places it).

### AppImage — `packaging/linux/build-appimage.sh`
A POSIX script that:
1. Builds the release exe (`zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast`).
2. Lays out an `AppDir`: `usr/bin/wispterm`, the `.desktop`, the icon, and the
   AppStream metainfo at the standard paths.
3. Runs `linuxdeploy` (downloaded in CI) to bundle the dynamic deps (libSDL3,
   libfontconfig, libfreetype, … via `ldd`) + `appimagetool` to produce
   `WispTerm-<version>-x86_64.AppImage`.
- Document that SDL3 currently lives in `/usr/local/lib`, so `linuxdeploy` needs
  that on its library search path (or the libs are pre-staged into the AppDir).

### Flatpak — `packaging/linux/com.wispterm.terminal.yaml`
A flatpak-builder manifest: `app-id: com.wispterm.terminal`, a `org.freedesktop`
runtime/sdk, finish-args (`--socket=wayland`, `--socket=fallback-x11`,
`--device=dri`, `--talk-name=org.freedesktop.Notifications`,
`--filesystem=host` for the terminal's cwd/ssh use), and build modules for Zig +
the app (or a prebuilt-binary module). Mark it best-effort (Flathub submission
is out of scope; the manifest is the deliverable).

### CI — `.github/workflows/linux-release.yml`
GitHub Actions (ubuntu-latest): install Zig + SDL3 + fontconfig dev, build the
exe, run `build-appimage.sh`, upload the AppImage artifact. Mirror the structure
of `windows-release.yml`/`macos-release.yml`.

### Docs — `packaging/linux/README.md`
How to build the AppImage locally + the deps required (matching
`packaging/macos/README.md`'s style).

## Out of scope / follow-ups

- `.deb`/`.rpm` (nfpm) — a later add; AppImage + Flatpak cover the common cases.
- In-app auto-update on Linux — delegate to the distribution channel (AppImage
  is self-contained; Flatpak/pkg-manager update themselves). The existing
  `update_*` flow stays Windows/macOS-only (already gated).
- SDL3 bundling polish (it's in `/usr/local`; for a reproducible CI build,
  pin/stage a known SDL3) — note in the script.

## Acceptance

1. `wispterm.desktop` validates (`desktop-file-validate` if available) and the
   metainfo is well-formed XML (`xmllint` if available).
2. `build-appimage.sh` is syntactically sound (`sh -n`) and lays out a correct
   AppDir; a local AppImage build is attempted and its outcome recorded.
3. The CI workflow + Flatpak manifest are committed (authoritative build is CI).
4. No change to the app build for other platforms.
