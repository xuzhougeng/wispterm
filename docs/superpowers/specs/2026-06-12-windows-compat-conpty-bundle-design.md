# Windows compat release: bundled ConPTY for old machines

**Date:** 2026-06-12
**Branch:** `worktree-fix-powerhell-codex-no-bar`
**Status:** Approved

## Problem

On some Windows machines, running Codex CLI (and other crossterm-based TUIs)
inside PowerShell in wispterm shows no scrollbar and mouse-wheel scrolling is
dead. Root cause: wispterm creates its pseudo console with the inbox
`kernel32!CreatePseudoConsole`, so the OS-shipped conhost services the PTY.
Windows 10's inbox conhost (frozen ~2020) lacks two ConPTY translations that
modern conhost (OpenConsole, since the Windows Terminal 1.9 era, 2021) has:

1. Outbound: client `SetConsoleMode(ENABLE_MOUSE_INPUT)` (how crossterm
   requests mouse capture on Windows — it never writes DECSET itself) is
   passed through to the hosting terminal as `?1003h`/`?1006h`
   (microsoft/terminal PR #9970).
2. Alt-screen passthrough and SGR-mouse-input → `MOUSE_EVENT` INPUT_RECORD
   translation.

Without (1), wispterm's `terminal.flags.mouse_event` stays `.none`, so wheel
events are never encoded as mouse reports (`src/input.zig:5075`); without
alt-screen passthrough the alternate-scroll fallback never triggers either,
and the viewport-scroll fallback has no scrollback to move. Codex never
receives wheel events, never scrolls, and never draws its scrollbar.
Windows 11's newer inbox conhost has both translations, which is why only
"some machines" are affected. wispterm's own mouse-reporting, wheel routing,
and scrollbar code were audited and are correct.

## Fix

Bundle the matched, MIT-licensed redistributable pair `conpty.dll` +
`OpenConsole.exe` (official NuGet package `Microsoft.Windows.Console.ConPTY`,
supported on Windows 10 1809+) next to `wispterm.exe`, and prefer it over the
inbox ConPTY when present. This is the same approach WezTerm uses. Ship it in
a new release zip that replaces the `portable-webview2` variant.

## Goals

- Codex/crossterm mouse + scrollbar work in wispterm on Windows 10.
- New full-featured release zip for old machines:
  `wispterm-windows-portable-compat-<tag>.zip` containing `wispterm.exe`,
  `wispterm-ssh-askpass.exe`, `plugins/`, `version.txt`,
  `WebView2Loader.dll`, `conpty.dll`, `OpenConsole.exe`.
- Drop the `wispterm-windows-portable-webview2-<tag>.zip` variant; existing
  webview2-flavor installs auto-update into the compat zip (a superset, so
  behavior only gains).
- Field escape hatch: config `windows-conpty = auto | system` (default
  `auto`).

## Non-goals

- No change to the plain `portable` and `portable-no-webview` zips (no conpty
  pair bundled there; the binary still picks it up if a user drops the two
  files next to the exe manually).
- No win32-input-mode (`?9001h`) keyboard encoding support in wispterm; the
  modern conhost accepts plain VT input.
- No arm64/x86 packaging; x64 only, like the rest of the matrix.
- IExpress installer staging stays as-is (not published anyway).

## Design

### 1. Runtime ConPTY backend (`src/platform/`)

New module `src/platform/conpty_backend.zig` (windows-only counterpart wired
through `pty_windows.zig`):

- A backend table `{ create, resize, close }` with two implementations:
  - `system`: the existing `kernel32` externs
    (`CreatePseudoConsole`/`ResizePseudoConsole`/`ClosePseudoConsole`).
  - `bundled`: resolved from `<exe dir>\conpty.dll` via
    `LoadLibraryW` + `GetProcAddress` of `ConptyCreatePseudoConsole`,
    `ConptyResizePseudoConsole`, `ConptyClosePseudoConsole` (verified against
    `inc/conpty.h` in the nupkg).
- Lazy one-time resolution at first `Pty.open`:
  - Pick `bundled` only when config is `auto` AND both `conpty.dll` and
    `OpenConsole.exe` exist in the exe directory AND load/symbol resolution
    succeeds. Otherwise `system`.
  - The choice given (config, dll_present, openconsole_present) is a pure
    function with tests; the LoadLibrary side effects live behind it.
- Each `Pty` stores the backend pointer that created its handle; `setSize`
  and `deinit` go through that stored backend so a handle is never serviced
  by the other implementation.
- Runtime guard (lesson from the DXGI #189 field regressions): if the bundled
  `create` call fails, log, sticky-downgrade the global choice to `system`,
  and retry the open with the system backend once.
- One log line on first resolution stating which backend is in use and why.
- `pty_command_windows.zig` is unchanged:
  `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` + `UpdateProcThreadAttribute` work
  identically with the redistributable's HPCON.

### 2. Config key

`windows-conpty = auto | system`, default `auto`. Loaded at startup like
other runtime config keys (note the known trap: key must be read at startup
via an App field, not only in `applyReloadedConfig`). `system` forces the
inbox ConPTY — the pre-change behavior — as a field rollback/diagnosis lever.

### 3. Packaging (`packaging/windows/package.ps1`)

- New `Get-ConPty` mirroring `Get-WebView2Loader`: download NuGet package
  `Microsoft.Windows.Console.ConPTY` (pinned `$ConPtyVersion =
  '1.24.260512001'`), cache under `.zig-cache\conpty`, return paths to
  `runtimes/win-x64/native/conpty.dll` and
  `build/native/runtimes/x64/OpenConsole.exe` (layout verified against the
  published nupkg).
- Remove the `portable-webview2` staging dir.
- Add `portable-compat` staging dir: the standard portable payload plus
  `WebView2Loader.dll`, `conpty.dll`, `OpenConsole.exe`
  (`Copy-PortablePayload` gains an optional conpty-pair parameter).
- Rename `-SkipWebView2Bundle` to `-SkipCompatBundle` (it now gates the
  loader fetch + conpty fetch + compat dir).

### 4. CI (`.github/workflows/windows-release.yml`)

- Validation step: replace the three `portable-webview2` checks with
  `portable-compat` checks for `wispterm.exe`, `version.txt`,
  `WebView2Loader.dll`, `conpty.dll`, `OpenConsole.exe`, and
  `plugins/skills`.
- Asset creation/upload/publish: `wispterm-windows-portable-compat-<tag>.zip`
  replaces the webview2 zip everywhere.
- Release-notes asset blurb: describe compat as the zip for older Windows 10
  machines — bundles the embedded-browser loader and a modern ConPTY so TUI
  apps (Codex, Claude Code) get mouse scrolling and scrollbars.

### 5. Updater flavor migration

Layering constraint: `test_main.zig` source guards forbid WebView2/ConPTY/
asset-name strings in shared modules; concrete names live only in
`platform/update_package_windows.zig` (and the pty platform files).

- `src/release_package.zig`: rename flavor
  `with_required_embedded_browser_payload` → `compat` (platform-neutral
  name). `requiresEmbeddedBrowserPayload()` returns true for `.compat`.
- `src/platform/update_package_windows.zig`:
  - Asset prefix for `.compat` is `wispterm-windows-portable-compat-`.
  - `runtimeFlavor` / `currentPackage`: webview disabled →
    `.without_embedded_browser_payload`; else if `conpty.dll` **or**
    `WebView2Loader.dll` sits next to the exe → `.compat`; else `.baseline`.
    The "or" is the migration path: a v1.18.0 webview2 install (loader only)
    resolves to `.compat` and its next auto-update fetches the compat zip,
    after which the conpty pair is present too.
- Update-install payload validation: required-file lists stay behind
  `platform/update_package_windows.zig`; the compat package requires the
  loader and the conpty pair to be present after extraction.
- docs/wiki: if the Updates topic (or any other doc) names the webview2
  asset, update both `docs/` and `wiki/` copies (embedded-docs sync rule).

## Testing

- TDD pure tests: backend-choice function (config × file presence matrix);
  `runtimeFlavor` matrix including the loader-only migration case;
  `assetName`/`matchesAssetName` for the compat prefix; existing `test_main`
  source guards must stay green (no banned strings introduced into shared
  modules).
- Suites: `zig build test`, `zig build test-full`, and the windows-gnu
  cross-compile must all pass.
- Manual (user): on a Windows 10 machine, run Codex in PowerShell from the
  compat zip — wheel scrolls and the scrollbar appears; `windows-conpty =
  system` restores today's behavior; auto-update from a webview2-flavor
  install picks the compat asset.

## Risks

- Bundled OpenConsole behavior differences vs inbox conhost (rendering,
  input edge cases) on machines that worked fine before — mitigated by the
  config escape hatch, the sticky runtime downgrade on create failure, and
  by NOT bundling the pair into the plain portable zip (only compat users
  opt in).
- conpty.dll/OpenConsole.exe flagged by AV as unsigned-adjacent binaries —
  they are Microsoft-signed from the official NuGet, so lower risk than our
  own exe.
- NuGet download flakiness in CI — same retry wrapper already used for zig
  fetch applies; the package is cached by version like WebView2.
