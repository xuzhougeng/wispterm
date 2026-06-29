# Development, Architecture, Packaging, and Releases

## Version Sources

The desktop app version has one source of truth: `build.zig.zon`. Build options
export that value as `build_options.app_version`, and it drives
`wispterm --version`, package `version.txt` output, release notes, and the
command center `Version` entry.

The WispTerm Remote web console/relay under `remote/` is a separate package with
its own version surfaces (`remote/package.json`, `remote/package-lock.json`,
`remote/src/client/version.ts`, and the rendered web label). Do not bump Remote
versions for a desktop-only release.

## Building

### Windows (PowerShell)

```powershell
zig build                         # Debug build for development
zig build -Doptimize=ReleaseFast  # ReleaseFast build for distribution
Remove-Item -Recurse -Force .\zig-out, .\.zig-cache -ErrorAction SilentlyContinue
```

The `Makefile` may still exist as a convenience wrapper, but normal Windows
development should use PowerShell and direct `zig` commands. Always use
`zig build` for development; only use `zig build -Doptimize=ReleaseFast` for
final/shipping builds.

### macOS

```bash
zig build macos-app -Dtarget=aarch64-macos   # Apple Silicon .app bundle
zig build macos-app -Dtarget=x86_64-macos    # Intel .app bundle
open zig-out/bin/WispTerm.app                 # launch the built app
```

Requires macOS 13+ and Zig 0.15.2. The build produces a `.app` bundle at
`zig-out/bin/WispTerm.app`. For distribution, run the packaging script
(`packaging/macos/package.sh`) which signs and creates a `.dmg`.

### Zig Toolchain

Use Zig 0.15.2 and make sure `zig` (or `zig.exe` on Windows) is available on
`PATH`. Check the active version:

```bash
zig version
```

On Windows, `build.zig` defaults to `x86_64-windows-gnu`, so a normal
development build does not need an explicit `-Dtarget`. On macOS, pass
`-Dtarget=aarch64-macos` (Apple Silicon) or `-Dtarget=x86_64-macos` (Intel)
explicitly.

After a successful Windows debug build, the expected artifact is:

```powershell
Test-Path .\zig-out\bin\wispterm.exe
Get-Item .\zig-out\bin\wispterm.exe
```

### Tests and structural guards

```bash
zig build test         # fast inner loop: platform-independent logic (src/test_fast.zig)
zig build test-full    # complete pre-merge gate; a SUPERSET of `zig build test`
zig build check-sizes  # the file-size backstop on its own
```

`zig build test` is sub-second when cached and does not recompile the heavy app
binary; `zig build test-full` is the gate to run before finishing a change and
now also runs the fast suite.

Architecture is enforced by source-scan ratchet tests under `src/source_guards/`
(file size, top-level `g_*` globals, `AppWindow` import-hub re-exports, and
direct UI dirty-writes). Each freezes today's count so it can only **shrink** —
adding a new occurrence fails the gate. The cohesion/coupling rationale and the
frozen ceilings are in [`../AGENTS.md`](../AGENTS.md) and
[decoupling-guide.md §8](decoupling-guide.md#8-structural-debt-governance-axis-b-in-practice).

## Why The UI Is Custom Drawn

WispTerm's main terminal UI is intentionally custom drawn instead of composed
from raw Win32 controls. The terminal surface, tabs, splits, overlays,
background image, shader effects, and theme colors all share one OpenGL
rendering pipeline, so they can stay visually consistent and behave like one
terminal canvas.

Classic Win32 controls such as `SCROLLBAR` provide native behavior, but they do
not blend well with WispTerm's dark theme, transparency, background images, and
terminal overlays. They also make layout, DPI, and focus behavior harder to keep
consistent with split panes and custom panels. For the primary terminal
experience, WispTerm prefers platform-aware custom controls over embedding
mismatched native widgets directly.

## Resize Benchmark

Use the checked-in resize benchmark when investigating reports that live window
resizing feels slower in one release than another. The script launches a real
WispTerm window, enables `WISPTERM_UI_PERF=1`, drives repeated Win32
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
  -ExePath .\zig-out-v0.28.1\bin\wispterm.exe -Label v0.28.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\benchmark-resize.ps1 `
  -ExePath .\zig-out-v0.29.0\bin\wispterm.exe -Label v0.29.0
```

Important labels include `appwindow.on_win32_resize`,
`appwindow.resize_compute_split_layout`, `markdown_preview_renderer.render`,
`markdown_preview_renderer.table_layout`, and
`markdown_preview_renderer.table_rows`. If resize is only slow while a CSV/TSV
preview is visible, the table preview labels should move with the regression.
For that scenario, add `-ManualSetupSeconds 15`, open the CSV/TSV preview during
the pause, then let the script run the resize sequence.

## Windows UI Automation

When debugging UI behavior, automate WispTerm as a real visible Windows app from
PowerShell. Prefer Win32-driven automation over shell-only assumptions.

Use the checked-in automation script for File Explorer regressions:

```powershell
zig build
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-file-explorer-ui.ps1
```

The script launches a real WispTerm window, sets DPI awareness, fixes the window
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

When changing SSH/SCP code paths (`src/ssh/scp.zig`, SSH clipboard image paste,
remote file explorer listing/upload/download, or SSH session metadata), test
against the existing real SSH profile in `%APPDATA%\wispterm\ssh_hosts` whenever
it is available. The profile fields are hex encoded as
`name, host, user, password, port, proxy_jump, auth_method, identity_file`;
decode them locally for the test, but never print or commit passwords or private
key material. At minimum, verify:

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

### Windows

WispTerm supports three portable Windows packages plus the local installer build:

- `portable` - lightweight portable build, run directly without installation
- `portable-compat` - full-featured portable build for older Windows 10 machines: `WebView2Loader.dll` for the embedded browser plus a bundled modern ConPTY (`conpty.dll` + `OpenConsole.exe`) so TUI apps like Codex get mouse scrolling and scrollbars on old inbox conhosts
- `portable-no-webview` - portable build compiled with embedded WebView2 disabled
- `wispterm-setup.exe` - installer build, installs to the current user's profile and creates a Start menu shortcut

Build the artifacts with:

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1
```

Key outputs include:

```text
zig-out\dist\portable\wispterm.exe
zig-out\dist\portable\version.txt
zig-out\dist\portable\plugins\...
zig-out\dist\portable-compat\wispterm.exe
zig-out\dist\portable-compat\WebView2Loader.dll
zig-out\dist\portable-compat\conpty.dll
zig-out\dist\portable-compat\OpenConsole.exe
zig-out\dist\portable-compat\version.txt
zig-out\dist\portable-compat\plugins\...
zig-out\dist\portable-no-webview\wispterm.exe
zig-out\dist\portable-no-webview\version.txt
zig-out\dist\portable-no-webview\plugins\...
zig-out\dist\installer\wispterm-setup.exe
```

The installer does not require administrator rights. It installs WispTerm to
`%LOCALAPPDATA%\Programs\WispTerm`, adds a Start menu entry, and registers an
uninstall entry for the current user.

### macOS

Build a signed `.dmg` image locally (ad-hoc signing) with:

```bash
zig build macos-dist -Dtarget=aarch64-macos   # Apple Silicon
zig build macos-dist -Dtarget=x86_64-macos    # Intel
```

Key output:

```text
zig-out/dist/macos/wispterm-macos-vX.Y.Z.dmg
```

For release signing and notarization, set `WISPTERM_MACOS_SIGN_IDENTITY` and
`WISPTERM_MACOS_NOTARY_PROFILE` before running the same command. See
`packaging/macos/README.md` for full signing and notarization instructions.

## GitHub Releases

Several GitHub Actions workflows publish release assets whenever a tag matching
`vX.Y.Z` is pushed:

- `.github/workflows/windows-release.yml` — Windows packages and the diagnostic build
- `.github/workflows/macos-release.yml` — Apple Silicon macOS DMG (signed and notarized)
- `.github/workflows/macos-release-x86_64.yml` — Intel macOS DMG, triggered automatically after the Apple Silicon release workflow succeeds
- `.github/workflows/linux-release.yml` — experimental Linux x86_64 AppImage
- `.github/workflows/wisptermctl-release.yml` — standalone `wisptermctl` CLI bundle for all desktop platforms

**Windows assets** (per tagged release):

- `wispterm-windows-portable-vX.Y.Z.zip`
- `wispterm-windows-portable-compat-vX.Y.Z.zip`
- `wispterm-windows-portable-no-webview-vX.Y.Z.zip`
- `wispterm-windows-debug-vX.Y.Z.zip`

When WispTerm detects a newer release on Windows, it downloads the matching
portable zip to the Downloads folder and reveals it in Explorer; unzip it over
your existing install to update.

The unsigned IExpress installer is not published for now because Windows
Defender can quarantine it as a false positive. Use the portable zip release
asset; the `portable-compat` zip when using the embedded browser panel or on
older Windows 10 machines (its bundled ConPTY restores TUI mouse support); or
the `portable-no-webview` zip when embedded WebView2 should be disabled. The
bundled ConPTY is preferred automatically when its files sit next to
`wispterm.exe`; set `windows-conpty = system` in the config to force the OS
inbox ConPTY.

**macOS assets** (per tagged release):

- `wispterm-macos-aarch64-vX.Y.Z.dmg` — Apple Silicon
- `wispterm-macos-x86_64-vX.Y.Z.dmg` — Intel

Both DMGs are signed with a Developer ID Application certificate and notarized
by Apple. Open the DMG and drag `WispTerm.app` to Applications to install.

**Linux asset** (per tagged release):

- `WispTerm-X.Y.Z-x86_64.AppImage` — experimental x86_64 Linux build that
  bundles SDL3. It is published for community testing and is not yet considered
  stable.

**CLI asset** (per tagged release):

- `wisptermctl-vX.Y.Z.zip` — standalone agent terminal-control CLI builds for
  Linux x86_64/aarch64, macOS Intel/Apple Silicon, and Windows x86_64.

Release notes are checked in under `release-notes/vX.Y.Z.md` when a release
needs curated notes. If a matching file is present, the workflow prepends it to
the GitHub release body; otherwise GitHub generated notes are used with the
asset summary.
