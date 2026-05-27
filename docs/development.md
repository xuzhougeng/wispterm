# Development, Architecture, Packaging, and Releases

## Building

```powershell
zig build                         # Debug build for development
zig build -Doptimize=ReleaseFast  # ReleaseFast build for distribution
Remove-Item -Recurse -Force .\zig-out, .\.zig-cache -ErrorAction SilentlyContinue
```

The `Makefile` may still exist as a convenience wrapper, but normal Windows
development should use PowerShell and direct `zig` commands. Always use
`zig build` for development; only use `zig build -Doptimize=ReleaseFast` for
final/shipping builds.

### Zig Toolchain

Use Zig 0.15.2 on Windows and make sure `zig.exe` is available on `PATH`. Check
the active version from PowerShell:

```powershell
zig version
```

`build.zig` already defaults to `x86_64-windows-gnu`, so a normal development
build should not need an explicit `-Dtarget`.

After a successful debug build, the expected artifact is:

```powershell
Test-Path .\zig-out\bin\phantty.exe
Get-Item .\zig-out\bin\phantty.exe
```

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

## Windows UI Automation

When debugging UI behavior, automate Phantty as a real visible Windows app from
PowerShell. Prefer Win32-driven automation over shell-only assumptions.

Use the checked-in automation script for File Explorer regressions:

```powershell
zig build
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-file-explorer-ui.ps1
```

The script launches a real Phantty window, sets DPI awareness, fixes the window
position and size, captures before/after screenshots, crops the right panel,
sends `Ctrl+Shift+Alt+E`, performs a region-based pixel check, and writes
screenshots plus JSON metrics under `zig-out\ui-test\`.

When adding more UI automation, follow the same pattern:

- Wait until `MainWindowHandle` is non-zero, call `ShowWindow` and
  `SetForegroundWindow`, then click inside the client area before sending keys.
- Prefer Win32 `keybd_event` or `SendInput` for shortcuts;
  `System.Windows.Forms.SendKeys` can silently miss GLFW/terminal windows when
  focus is not exactly right.
- Capture both full-window and cropped target-region screenshots, and inspect
  the crop when a pixel check fails.
- Always clean up test windows with `CloseMainWindow()`, then `Stop-Process
  -Force` if the process remains.

## macOS UI Smoke Tests

macOS UI debugging is native-target first. Unless a task explicitly asks for
Intel validation, run the native host tests rather than `x86_64-macos`:

```bash
zig build test-macos-ui
```

The step runs in-process AppKit/overlay smoke tests for macOS-only debugging:
`Ctrl+Shift+B` toggles the tab sidebar, the Command Center filters and executes
the `Settings` command, and the Settings page writes to an isolated test config
file. The test intentionally avoids external keyboard/screenshot automation so
it does not depend on macOS Accessibility or Screen Recording permissions.

For the Metal-backend and AppKit-host gotchas surfaced during the macOS port
(deferred MTLBuffer semantics, NSMenu vs. keyDown interception, Zig 0.15
module-path constraints on cross-backend imports, IME swallowing letter keys,
etc.) see [macos-ui-lessons.md](macos-ui-lessons.md). Read this before
touching anything under `src/renderer/gpu/metal/` or `src/platform/*_macos*`.

## Windows Checkout Safety

This repository must remain safe to check out and develop on Windows. Before
finishing changes that add, remove, rename, or move files, check for
Windows-incompatible paths:

```powershell
$paths = git ls-files
$reserved = @('CON', 'PRN', 'AUX', 'NUL') + (1..9 | ForEach-Object { "COM$_"; "LPT$_" })
$violations = [System.Collections.Generic.List[object]]::new()
$collisions = [System.Collections.Generic.List[object]]::new()
$seen = @{}

foreach ($path in $paths) {
    foreach ($part in ($path -split '/')) {
        $stem = ($part -split '\.')[0].ToUpperInvariant()
        $reasons = @()
        if ($part.IndexOfAny([char[]]'<>:"\|?*') -ge 0) { $reasons += 'illegal_char' }
        if ($part.EndsWith(' ') -or $part.EndsWith('.')) { $reasons += 'trailing_space_or_dot' }
        if ($reserved -contains $stem) { $reasons += 'reserved_name' }
        if ($reasons.Count -gt 0) {
            $violations.Add([pscustomobject]@{ Path = $path; Part = $part; Reasons = ($reasons -join ',') })
        }
    }

    $key = $path.ToLowerInvariant()
    if ($seen.ContainsKey($key) -and $seen[$key] -ne $path) {
        $collisions.Add([pscustomobject]@{ A = $seen[$key]; B = $path })
    } else {
        $seen[$key] = $path
    }
}

"tracked_files=$($paths.Count)"
"windows_name_violations=$($violations.Count)"
$violations | ForEach-Object { "violation`t$($_.Path)`t$($_.Part)`t$($_.Reasons)" }
"casefold_collisions=$($collisions.Count)"
$collisions | ForEach-Object { "collision`t$($_.A)`t$($_.B)" }
$longest = $paths | Sort-Object Length -Descending | Select-Object -First 1
"max_path_length=$($longest.Length) $longest"
```

Also check for symlinks, which are often painful on Windows checkouts:

```powershell
git ls-files -s | Select-String '^120000'
```

Rules of thumb:

- Do not introduce files whose names differ only by case. Windows checkout is
  case-insensitive by default.
- Avoid Windows-reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`,
  `LPT1`-`LPT9`) in any path segment, even with extensions.
- Avoid characters illegal on Windows: `< > : " \ | ? *`.
- Avoid trailing spaces or trailing dots in any path segment.
- Keep paths reasonably short. Current longest tracked path is expected to be
  well below Windows path limits.

## Windows SSH/SCP Compatibility

When changing SSH/SCP code paths (`src/scp.zig`, SSH clipboard image paste,
remote file explorer listing/upload/download, or SSH session metadata), test
against the existing real SSH profile in `%APPDATA%\phantty\ssh_hosts` whenever
it is available. The profile fields are hex encoded as
`name, host, user, password, port`; decode them locally for the test, but never
print or commit the password. At minimum, verify:

```powershell
ssh.exe ... user@host pwd
scp.exe ... local-file user@host:/tmp/test-file
ssh.exe -T ... user@host "cat > '/tmp/test-file'"  # only if testing the stream fallback
```

Do **not** add OpenSSH connection sharing (`ControlMaster`, `ControlPersist`,
`ControlPath`) to helper `ssh.exe` or `scp.exe` commands on Windows. Windows
OpenSSH does not provide the Unix-domain socket behavior those options expect
here; it reproduces as `getsockname failed: Not a socket`,
`Read from remote host ...: Unknown error`, `scp.exe: Connection closed`, or
`lost connection`. This broke SCP uploads even though the same profile and
remote service worked without those options.

Keep stderr visible for helper `ssh.exe`/`scp.exe` failures. Do not reduce
failures to a generic "SSH image upload failed"; preserve the underlying
OpenSSH error so regressions can be diagnosed without guessing.

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
zig-out\dist\portable\version.txt
zig-out\dist\portable\plugins\...
zig-out\dist\portable-webview2\phantty.exe
zig-out\dist\portable-webview2\WebView2Loader.dll
zig-out\dist\portable-webview2\version.txt
zig-out\dist\portable-webview2\plugins\...
zig-out\dist\portable-no-webview\phantty.exe
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

When Phantty detects a newer release, it downloads the matching portable zip to your Downloads folder and reveals it in Explorer; unzip it over your existing install to update.

The unsigned IExpress installer is not published for now because Windows
Defender can quarantine it as a false positive. Use the portable zip release
asset, the `portable-webview2` zip when using the embedded browser panel, or
the `portable-no-webview` zip when embedded WebView2 should be disabled.

Release notes are checked in under `release-notes/vX.Y.Z.md` when a release
needs curated notes. If a matching file is present, the workflow prepends it to
the GitHub release body; otherwise GitHub generated notes are used with the
asset summary.
