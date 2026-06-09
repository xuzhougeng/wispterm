# Linux packaging

Artifacts for distributing WispTerm on Linux. The **AppImage** is the primary,
verified path; the Flatpak manifest is a template for a future Flathub
submission.

## Files

| File | Purpose |
|------|---------|
| `wispterm.desktop` | Desktop entry (`Categories=TerminalEmulator`, `Icon=wispterm`). |
| `com.wispterm.terminal.metainfo.xml` | AppStream metainfo (Flathub / GNOME Software). |
| `build-appimage.sh` | Builds `WispTerm-<version>-x86_64.AppImage`. |
| `com.wispterm.terminal.yaml` | Flatpak manifest (**template — not yet built/tested**). |
| `../../.github/workflows/linux-release.yml` | CI: builds SDL3 + the AppImage on tag push. |

Icon source: `assets/wispterm.png` (256×256), installed to
`hicolor/256x256/apps/wispterm.png`.

## Build the AppImage

Requires `zig` 0.15.2 and, at build time, **SDL3** + **fontconfig** dev libs.
SDL3 is not yet in most distro repos — build it from source (the CI workflow
does this) or install it under `/usr/local` (the script adds `/usr/local/lib` to
the search path).

```sh
./packaging/linux/build-appimage.sh
# → zig-out/WispTerm-<version>-x86_64.AppImage
```

The script downloads `linuxdeploy` + `appimagetool` into `zig-out/.appimage-tools`
on first run, lays out an `AppDir`, bundles the shared libraries (`libSDL3`,
`libfontconfig`, `libfreetype`, …), and packages the AppImage. On hosts without
FUSE it falls back to extract-and-run (`APPIMAGE_EXTRACT_AND_RUN=1`); the
produced AppImage likewise runs with `./WispTerm-*.AppImage --appimage-extract-and-run`
where FUSE is unavailable.

## Runtime notes

- **Notifications / file dialog** use `notify-send` (libnotify-bin) and `zenity`
  if present; they degrade to no-ops otherwise. Bundle or recommend them for a
  full desktop experience.
- **Auto-update** is delegated to the distribution channel (the AppImage is
  self-contained; package managers / Flatpak update themselves). The in-app
  updater stays Windows/macOS-only.

## Flatpak (template)

`com.wispterm.terminal.yaml` has the correct app-id, command, and finish-args
(Wayland + X11 fallback, DRI, network for SSH/AI, notifications, host files).
The build modules (Zig toolchain + an SDL3 module) still need validation with
`flatpak-builder`, and a real screenshot must be added to the metainfo before a
Flathub submission.
