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

## Performance Benchmarking

`wispterm-bench` is the CPU-side benchmark CLI (Ghostty-aligned: mirrors
`ghostty-bench`'s `--duration` case-runner shape). It links ghostty-vt and
drives a synthetic VT byte stream through the same parser the shipped app uses,
so the number is directly comparable across branches and machines. Build and
run it with:

```powershell
zig build -Demit-bench -Doptimize=ReleaseFast
.\zig-out\bin\wispterm-bench.exe --list
.\zig-out\bin\wispterm-bench.exe --case terminal-stream --duration 1000
```

Always pass `-Doptimize=ReleaseFast` for benchmarks — a debug build is not
representative of real performance. Use `--duration <ms>` to set the per-case
window (default 1000ms) and `--case <name>` to run a single case.

The CLI writes a machine-readable `benchmark-report-<timestamp>.json` and a
paste-ready `benchmark-report-<timestamp>.md` into the WispTerm config dir
(`%APPDATA%\wispterm\` on Windows, `~/Library/Application Support/wispterm/` on
macOS), and prints the Markdown to stdout. Paste that Markdown block into a
**Performance Report** issue (or a Discussion) so we can compare results across
hardware and renderer backends. The JSON is for tooling/regression tracking.

The bench module's own tests (which link ghostty-vt and so cannot run in the
lean fast suite) have their own step:

```powershell
zig build test-bench
```

An in-app GPU-side benchmark (`wispterm --benchmark`) measures per-frame render
latency through the real renderer. It spawns a no-shell virtual surface, drives a
synthetic VT stream from the UI thread with vsync off, and records the
rebuild+draw+present pipeline time per frame as `latency_ns` (p50/p95/max), then
writes the same JSON + Markdown report shape as the CLI. The renderer backend is
fixed at build time (`-Dgpu-backend`), so a D3D11-vs-OpenGL comparison is two
builds of the same machine:

```powershell
zig build -Dgpu-backend=opengl -Doptimize=ReleaseFast
.\zig-out\bin\wispterm.exe --benchmark
zig build -Dgpu-backend=d3d11  -Doptimize=ReleaseFast
.\zig-out\bin\wispterm.exe --benchmark
```

Each run writes `benchmark-report-<timestamp>.{json,md}` to the config dir and
prints the Markdown to stdout; diff the two reports' `scroll-flood` /
`unicode-heavy` rows to see the per-backend render delta. The report carries the
GPU adapter name + PCI ids, window/DPI/grid size, and `runner: in-app` so it is
distinguishable from a CLI report.

When publishing a desktop release, run `wispterm-bench --case terminal-stream
--duration 1000` on the release machine and attach the Markdown report to the
release notes as a regression baseline for that version.

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

For Windows-native D3D11 Phase IV parity, use the normal-session smoke script
against an explicitly built D3D11 executable:

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1
```

The script launches a real visible WispTerm window with an isolated `%APPDATA%`,
enables render diagnostics plus the D3D11 UI/offscreen probes, switches between
two visible tabs, checks tab text, the `+` icon, active/inactive row states, and
the close-hover affordance, then toggles the tab sidebar, file explorer, and
command palette. It also generates a high-contrast background image, verifies it
through the initial D3D11 screenshot, opens Markdown and image preview panes
from a temporary File Explorer fixture, opens the Copilot assistant sidebar with
a temporary AI profile, opens the startup shortcuts overlay from the Command
Center, opens the Settings page from the titlebar gear, and opens the Skill
Center from the Command Center. It captures
screenshots, writes JSON metrics under
`zig-out\d3d11-normal-session-smoke\`, and verifies that
`render-diagnostic.log` contains `gpu-backend=d3d11 present=dxgi`, D3D11 init
details for swap effect / adapter / fallback reason / healthy policy state, a
D3D11 environment line for adapter description, vendor/device/subsystem,
revision, memory sizes, output count, feature level, and swap effect, a Win32
environment line for remote session, session id, monitor count, mixed-DPI state,
primary DPI, and system DPI, a
successful `d3d11-ui-smoke` probe, an offscreen round-trip marker, and no D3D11
recovery request in the healthy path. It is a Phase IV and Phase V
diagnostics/policy/recovery-coordination evidence tool only; it does not change
the Windows default renderer.

Use `debug\test-d3d11-environment-smoke.ps1` after a D3D11 build to wrap the
normal-session smoke into a matrix evidence package:

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-environment-smoke.ps1
```

The collector writes `zig-out\d3d11-env-smoke\<timestamp>\environment.json`, a
redacted `matrix-summary.md` review artifact, a `normal-session\` result
directory, copied screenshots under `screenshots\`, and the original render
diagnostics path. It records adapter/session/monitor facts and smoke health,
plus a record-only `matrix` section when `-MatrixClass` is provided. Use classes
such as `local-physical`, `rdp`, `virtual-machine`, `hybrid-gpu`,
`weak-integrated-gpu`, `single-monitor`, `multi-monitor-same-dpi`, and
`multi-monitor-mixed-dpi`; add `-RequireMatrixClass` only when the class can be
proven from collected facts. The collector does not block environments and does
not change fallback policy. The durable ledger format is documented in
[windows-native-d3d11-environment-matrix.md](windows-native-d3d11-environment-matrix.md).
After collecting one or more environment packages, run
`debug\summarize-d3d11-environment-matrix.ps1` to emit a consolidated
`matrix-ledger.md` / `matrix-ledger.json` plus a
`matrix-collection-plan.md` / `matrix-collection-plan.json` for PR or issue
review. The collection plan lists remaining non-recorded classes and the exact
collector command to run in each matching environment; it is not evidence and
does not accept missing classes.
To audit the collected Phase V artifacts against the default-migration gate
without rerunning smokes, use `debug\audit-d3d11-default-gate.ps1`; it emits
`default-gate-audit.md` / `default-gate-audit.json` and keeps missing evidence
as missing rather than treating it as a pass. If unavailable environment
classes are explicitly accepted under `KNOWN_ISSUES.md` heading
`Accepted D3D11 Phase V Environment Matrix Gaps`, the audit marks those matrix
rows and the environment-ledger gate as `accepted` while preserving the original
ledger status.
If a shorter soak is explicitly operator-accepted, keep its summary under
`zig-out\d3d11-accepted-soak\`; the audit marks that gate as `accepted` so it is
visible and distinct from a completed 20-minute automated soak.

To exercise the controlled Phase V device-recreate path, run the same smoke
with `-RecreateSmoke` after building the D3D11 executable:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -RecreateSmoke
```

This sets `WISPTERM_D3D11_RECREATE_SMOKE=1`, asks the backend to latch one
recreate-class recovery request, and verifies that diagnostics record the
recreate request, a successful single-shot device/swapchain recreate attempt,
and restored feature resources. It still leaves automatic fallback and the
Windows default backend unchanged.

To exercise the failed-recreate escalation path, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -RecreateFailureSmoke
```

This sets `WISPTERM_D3D11_RECREATE_FAILURE_SMOKE=1`, asks the backend to latch
one recreate-class recovery request, injects a synthetic failed recreate, and
verifies that diagnostics escalate it to a `recreate_failed` fallback candidate
exactly once. The smoke also verifies a version+adapter-scoped
`d3d11-fallback` marker is written to the isolated smoke profile state file,
that feature resources are not reported as restored after the forced failure,
and that automatic fallback plus the Windows default backend remain unchanged.

To add rapid resize stress evidence to the same D3D11 session smoke, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -RapidResizeSmoke
```

This drives a burst of real Win32 `SetWindowPos` changes, restores the window
to the baseline smoke size, captures a post-resize screenshot, and verifies that
the session remains nonblank with D3D11 resize diagnostics and no present/resize
failure lines. It is Phase V hardening evidence only; it does not change the
Windows default backend or fallback policy.

To exercise Win32 window-state transitions on D3D11, run:

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -WindowStateSmoke
```

This drives maximize, restore, minimize, and restore-from-minimize through real
Win32 window state APIs, captures screenshots after the visible states, verifies
the session returns to the baseline window size, and checks that D3D11 resize
diagnostics were emitted without present/resize failure lines. It is a Phase V
window-state sub-slice only.

To exercise fullscreen startup on D3D11, run:

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -FullscreenStartupSmoke
```

This writes `fullscreen = true` into the isolated smoke config, launches through
the real startup fullscreen path, captures a fullscreen screenshot, uses
Alt+Enter to exit fullscreen, restores the baseline window rectangle, and
verifies both visible states are nonblank with D3D11 fullscreen/resize
diagnostics and no present/resize failure lines.

To add a D3D11 long-run soak loop to the normal-session smoke, run:

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -SoakMinutes 20
```

The soak mode keeps the real window active after the initial terminal capture,
sends a shell output burst when the shell is recognized, loops tab switches and
small Win32 resize/restore cycles for the requested duration, captures periodic
screenshots plus a final restored-size screenshot, and verifies the process
survives with nonblank frames, D3D11 resize diagnostics, and no present/resize
failure lines. It is Phase V reliability evidence only; it does not change the
Windows default backend or fallback policy.

The Phase VI default migration gate is documented in
[windows-native-d3d11-default-gate.md](windows-native-d3d11-default-gate.md).
Use it as the checklist for collecting evidence, recording matrix gaps, and
keeping the eventual Windows `auto` default change small and revertible.

D3D11 fallback is a next-launch policy while the renderer backend remains a
comptime selection. Do not implement same-process D3D11-to-OpenGL switching
without first changing the backend architecture. The `d3d11-fallback` state-file
marker is separate from the older OpenGL+DXGI present `d3d-bringup` fuse,
scoped by app version and adapter identity, and currently feeds only tests and
future-auto dry-run decisions. Explicit `d3d11` must ignore a matching marker
except for diagnostics; current Windows `auto` still resolves to OpenGL.

To exercise the marker path without changing selection, run:

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -FallbackMarkerSmoke
```

This sets `WISPTERM_D3D11_FALLBACK_MARKER_SMOKE=1`, writes a synthetic
version+adapter-scoped `d3d11-fallback` marker into the smoke profile's isolated
state file, verifies explicit `d3d11` still wins with a warning-class decision,
verifies current Windows `auto` remains OpenGL, and verifies a future-auto
dry-run would select OpenGL from the marker. It does not enable live failure
writes or automatic fallback.

To record the future-auto selector dry-run surface without writing a marker,
run:

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -AutoDryRunSmoke
```

This sets `WISPTERM_D3D11_AUTO_DRY_RUN_SMOKE=1` and verifies diagnostics for
current Windows `auto` staying OpenGL, future Windows `auto` selecting D3D11
when eligible, future-auto selecting OpenGL from a matching marker, explicit
`d3d11` ignoring a matching marker with warning semantics, explicit `opengl`
remaining OpenGL, and stale markers being ignored. It does not change the
Windows default backend, write a fallback marker, or trigger automatic fallback.

To prove the Windows OpenGL fallback path still runs the same normal-session UI
subset on the native-render branch, build the default backend and run:

```powershell
zig build
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1 -Backend opengl
```

This reuses the normal-session screenshot workflow for tab chrome, sidebar,
file explorer, Markdown/image previews, assistant panel, command palette,
startup shortcuts, Settings, Skill Center, and background image rendering, but
expects `gpu-backend=opengl` diagnostics instead of D3D11 probes. It also
verifies that no D3D11 recovery, fallback-marker, UI-probe, or offscreen-smoke
markers fire in the OpenGL fallback session.

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

- `portable` - default OpenGL portable build, run directly without installation
- `portable-compat` - OpenGL portable build for older Windows 10 machines: `WebView2Loader.dll` for the embedded browser plus a bundled modern ConPTY (`conpty.dll` + `OpenConsole.exe`) so TUI apps like Codex get mouse scrolling and scrollbars on old inbox conhosts
- `portable-native-d3d11` - Windows native D3D11 feedback build; use the default `portable` package if it shows rendering issues
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
zig-out\dist\portable-native-d3d11\wispterm.exe
zig-out\dist\portable-native-d3d11\version.txt
zig-out\dist\portable-native-d3d11\plugins\...
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
- `wispterm-windows-portable-native-d3d11-vX.Y.Z.zip`
- `wispterm-windows-debug-vX.Y.Z.zip`

When WispTerm detects a newer release on Windows, it downloads the matching
portable zip to the Downloads folder and reveals it in Explorer; unzip it over
your existing install to update.

The unsigned IExpress installer is not published for now because Windows
Defender can quarantine it as a false positive. Use the default portable zip
release asset; the `portable-compat` zip when using the embedded browser panel
or on older Windows 10 machines (its bundled ConPTY restores TUI mouse support);
or the `portable-native-d3d11` zip when intentionally testing the Windows native
D3D11 renderer. If the native D3D11 package shows a black window, crash, missing
UI, resize failure, RDP issue, or multi-monitor/DPI issue, switch back to the
default portable package and include diagnostics in the bug report. The bundled
ConPTY is preferred automatically when its files sit next to `wispterm.exe`; set
`windows-conpty = system` in the config to force the OS inbox ConPTY.

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
