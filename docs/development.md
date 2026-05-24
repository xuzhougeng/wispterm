# Development, Architecture, Packaging, and Releases

## Building

```powershell
zig build                         # Debug build for development
zig build -Doptimize=ReleaseFast  # ReleaseFast build for distribution
Remove-Item -Recurse -Force .\zig-out, .\.zig-cache -ErrorAction SilentlyContinue
```

The `Makefile` may still exist as a convenience wrapper, but normal Windows
development should use PowerShell and direct `zig` commands.

## Why The UI Is Custom Drawn

Phantty's main terminal UI is intentionally custom drawn instead of composed
from raw Win32 controls. The terminal surface, tabs, splits, overlays,
background image, shader effects, and theme colors all share one OpenGL
rendering pipeline, so they can stay visually consistent and behave like one
terminal canvas.

Classic Win32 controls such as `SCROLLBAR` provide native behavior, but they do
not blend well with Phantty's dark theme, transparency, background images, and
terminal overlays. They also make layout, DPI, and focus behavior harder to keep
consistent with split panes and custom panels. For the primary terminal
experience, Phantty prefers platform-aware custom controls over embedding
mismatched native widgets directly.

## Resize Benchmark

Use the checked-in resize benchmark when investigating reports that live window
resizing feels slower in one release than another. The script launches a real
Phantty window, enables `PHANTTY_UI_PERF=1`, drives repeated Win32
`SetWindowPos` size changes, and writes JSON plus CSV timing summaries under
`zig-out\resize-bench`.

```powershell
zig build
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\benchmark-resize.ps1
```

To compare two release builds, run the same command against each executable and
compare the generated `ui_perf_csv` files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\benchmark-resize.ps1 `
  -ExePath .\zig-out-v0.28.1\bin\phantty.exe -Label v0.28.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\benchmark-resize.ps1 `
  -ExePath .\zig-out-v0.29.0\bin\phantty.exe -Label v0.29.0
```

Important labels include `appwindow.on_win32_resize`,
`appwindow.resize_compute_split_layout`, `markdown_preview_renderer.render`,
`markdown_preview_renderer.table_layout`, and
`markdown_preview_renderer.table_rows`. If resize is only slow while a CSV/TSV
preview is visible, the table preview labels should move with the regression.
For that scenario, add `-ManualSetupSeconds 15`, open the CSV/TSV preview during
the pause, then let the script run the resize sequence.

## Packaging

Phantty supports three portable Windows packages plus the local installer build:

- `portable` - lightweight portable build, run directly without installation
- `portable-webview2` - portable build with `WebView2Loader.dll` for the embedded browser
- `portable-no-webview` - portable build compiled with embedded WebView2 disabled
- `phantty-setup.exe` - installer build, installs to the current user's profile and creates a Start menu shortcut

Build the artifacts with:

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1
```

Key outputs include:

```text
zig-out\dist\portable\phantty.exe
zig-out\dist\portable\phantty-updater.exe
zig-out\dist\portable\version.txt
zig-out\dist\portable\plugins\...
zig-out\dist\portable-webview2\phantty.exe
zig-out\dist\portable-webview2\phantty-updater.exe
zig-out\dist\portable-webview2\WebView2Loader.dll
zig-out\dist\portable-webview2\version.txt
zig-out\dist\portable-webview2\plugins\...
zig-out\dist\portable-no-webview\phantty.exe
zig-out\dist\portable-no-webview\phantty-updater.exe
zig-out\dist\portable-no-webview\version.txt
zig-out\dist\portable-no-webview\plugins\...
zig-out\dist\installer\phantty-setup.exe
```

The installer does not require administrator rights. It installs Phantty to
`%LOCALAPPDATA%\Programs\Phantty`, adds a Start menu entry, and registers an
uninstall entry for the current user.

## GitHub Releases

The GitHub Actions workflow at `.github/workflows/windows-release.yml`
publishes Windows release assets whenever a tag matching `vX.Y.Z` is pushed.

Each tagged release uploads:

- `phantty-windows-portable-vX.Y.Z.zip`
- `phantty-windows-portable-webview2-vX.Y.Z.zip`
- `phantty-windows-portable-no-webview-vX.Y.Z.zip`

Each portable zip also includes `phantty-updater.exe`, a native helper launched by Phantty to update the current portable directory after the app exits.

The unsigned IExpress installer is not published for now because Windows
Defender can quarantine it as a false positive. Use the portable zip release
asset, the `portable-webview2` zip when using the embedded browser panel, or
the `portable-no-webview` zip when embedded WebView2 should be disabled.

Release notes are checked in under `release-notes/vX.Y.Z.md` when a release
needs curated notes. If a matching file is present, the workflow prepends it to
the GitHub release body; otherwise GitHub generated notes are used with the
asset summary.
