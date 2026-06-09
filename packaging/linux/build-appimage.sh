#!/usr/bin/env bash
#
# Build a portable WispTerm AppImage. Run from anywhere; resolves the repo root.
#
# Requires at build time: zig (0.15.2), and SDL3 + fontconfig dev libs.
# Downloads linuxdeploy + appimagetool (single-file AppImages) into
# zig-out/.appimage-tools on first run. Authoritative build is CI
# (.github/workflows/linux-release.yml); this script is what CI runs.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

ARCH="x86_64"
VERSION="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
APPDIR="$ROOT/zig-out/WispTerm.AppDir"
OUTPUT="WispTerm-${VERSION}-${ARCH}.AppImage"
TOOLS="$ROOT/zig-out/.appimage-tools"

echo "==> Building release executable (v${VERSION}, ${ARCH}-linux-gnu)"
zig build -Dtarget="${ARCH}-linux-gnu" -Doptimize=ReleaseFast

echo "==> Staging AppDir at ${APPDIR}"
rm -rf "$APPDIR"
install -Dm755 "$ROOT/zig-out/bin/wispterm"                          "$APPDIR/usr/bin/wispterm"
install -Dm644 "$HERE/wispterm.desktop"                              "$APPDIR/usr/share/applications/wispterm.desktop"
install -Dm644 "$HERE/com.wispterm.terminal.metainfo.xml"            "$APPDIR/usr/share/metainfo/com.wispterm.terminal.metainfo.xml"
install -Dm644 "$ROOT/assets/wispterm.png"                           "$APPDIR/usr/share/icons/hicolor/256x256/apps/wispterm.png"

echo "==> Fetching linuxdeploy + appimagetool (if absent)"
mkdir -p "$TOOLS"
fetch() { # <url> <dest>
  if [ ! -x "$2" ]; then
    echo "    downloading $(basename "$2")"
    curl -fSL "$1" -o "$2"
    chmod +x "$2"
  fi
}
fetch "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage"   "$TOOLS/linuxdeploy"
fetch "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"    "$TOOLS/appimagetool"

# AppImages mount via FUSE; on hosts without FUSE (e.g. many WSL / CI runners)
# fall back to extracting and running.
export APPIMAGE_EXTRACT_AND_RUN=1
# SDL3 currently installs under /usr/local/lib — make sure linuxdeploy's ldd
# walk can resolve it (CI may instead install SDL3 into a standard prefix).
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib"

echo "==> Bundling shared libraries into the AppDir (linuxdeploy)"
"$TOOLS/linuxdeploy" \
  --appdir "$APPDIR" \
  --executable "$APPDIR/usr/bin/wispterm" \
  --desktop-file "$APPDIR/usr/share/applications/wispterm.desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/wispterm.png"

echo "==> Packaging the AppImage (appimagetool)"
"$TOOLS/appimagetool" "$APPDIR" "$ROOT/zig-out/$OUTPUT"

echo "==> Done: zig-out/${OUTPUT}"
