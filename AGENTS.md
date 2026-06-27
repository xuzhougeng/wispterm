# AGENTS.md

## Overview

WispTerm is a terminal emulator written in Zig, shipping desktop builds for Windows and macOS, plus an experimental Linux AppImage. It uses [libghostty-vt](https://github.com/ghostty-org/ghostty) (Ghostty's VT parser and terminal state machine) for terminal emulation, with its own rendering pipeline (OpenGL/Metal + FreeType, plus DirectWrite/CoreText/fontconfig for font discovery by platform).

Windows is the **primary and default development target** (`x86_64-windows-gnu`), and day-to-day development happens on Windows in PowerShell. Platform-specific code lives behind narrow interfaces in `src/platform/` (per-platform implementations plus `_unsupported`/`_posix` stubs) so macOS and Linux can share the terminal core. macOS is an active supported desktop build that is still stabilizing; Linux is experimental. See `ROADMAP.md` for future work and `KNOWN_ISSUES.md` for current platform limitations.

## Architecture

WispTerm is split into a platform-agnostic **core** (terminal state, IO, rendering) and a per-platform **host** (window, event loop, input) that drives the core through a narrow surface API. The host interface is `src/platform/window_backend.zig`; OS facilities go through capability facades in `src/platform/`. The named contract — what the host implements, what services it supplies, and the invariants that keep the seam intact — is documented in [docs/architecture.md](docs/architecture.md). Read it before touching the platform boundary or starting a port.

## Cohesion and coupling

These are the **primary** architectural criteria. File length is a symptom, not the rule.

A file may be large when it owns one coherent domain object and exposes a clear API. Ghostty-style large terminal-core files are acceptable because their responsibilities are narrow and their state ownership is explicit — Ghostty ships `terminal/PageList.zig` (~14.8k lines), `terminal/Terminal.zig` (~13.3k), `config/Config.zig` (~10.9k), and `terminal/Screen.zig` (~10.5k) with no scattered module globals. The smell we guard against is **responsibility entanglement**: UI presentation mixed with business mutation, input dispatch mixed with rendering, global mutable state scattered across facades, and one file becoming an import hub for unrelated features. WispTerm's largest files are smaller than Ghostty's yet harder to change because they carry all of those at once.

The goal is not small files but code that can be **understood, tested, and changed locally**. Large-but-cohesive is fine; large-but-tangled must be split. New features should prefer focused modules over growing existing hub files. New UI state must live in an explicit state struct or a feature-owned module — never as another top-level `g_*` / `threadlocal` field in `AppWindow.zig`, `input.zig`, or `renderer/overlays.zig`.

### Integration layer vs feature domains

`AppWindow.zig`, `input.zig`, and `renderer/overlays.zig` are an **integration layer**, not terminal "core". They *coordinate* features — AppWindow assembles modules and routes render/input, `input.zig` dispatches events, `overlays.zig` is the overlay facade/registry — but they must **not own feature state**. The **feature domains** own their own state, query/action APIs, and tests: `ai_chat*`, `weixin/*`, the `skill_*` modules, `file_explorer.zig`, the `tmux_*` controllers, and the `remote_*` client/sync code.

When writing new code: feature domains should not depend on `AppWindow` (expose an API, receive context explicitly); `input.zig` only dispatches and returns a `UiEffect` — it must not read a feature's internal `g_*` state; overlays get capabilities through a Host/Context, not by importing `AppWindow.zig`. Prefer explicit context structs, feature-owned query/action APIs, and `UiEffect` returns. **Each time you touch one of these monoliths, lower the matching source-guard ratchet** — that is how the boundary converges. The full layer model and per-edge rules are in [docs/architecture.md](docs/architecture.md#integration-layer-vs-feature-domains) and [docs/decoupling-guide.md §8.5](docs/decoupling-guide.md#85-the-layer-model).

### Boundary guards (`src/source_guards/`)

Structural debt is frozen mechanically by source-scanning ratchet tests (the same `@embedFile`-scan idiom as `input/dirty_guard.zig`). They run in `zig build test` and, because `test-full` is now a superset of `test`, in the pre-merge gate too. Each freezes a count at today's value; the count may only **shrink**. To add a case you must first remove one elsewhere — or, better, use the pattern the guard points you to.

| Guard | Freezes | Today's ceiling | Escape hatch |
|---|---|---|---|
| `file_size_guard` | lines in any `src/**/*.zig` | < **10,000** (also `zig build check-sizes`) | split by responsibility; never raise the limit |
| `global_state_guard` | top-level `g_*` / `threadlocal` in the four monoliths | AppWindow **67**, input **55**, overlays **48**, ai_chat **20** | put new state in a state struct (`appwindow/state.zig`, …) |
| `import_hub_guard` | `pub const X = @import(...)` re-exports in `AppWindow.zig` | **29** | import the real module directly, not via `AppWindow.X` |
| `side_effect_guard` | direct `g_force_rebuild` / `g_cells_valid` writes in the four monoliths | AppWindow **63**, input **81**, overlays **12**, ai_chat **0** | return a `UiEffect`, land it through `AppWindow.applyUiEffect` |

The 10,000-line guard is a **runaway tripwire, not a health metric**: `check-sizes` prevents uncontrolled growth, it does not certify architectural health. A file under it can still be tangled; treat any file over **5,000 lines** as a signal to review responsibility, dependency direction, state ownership, and test boundaries. The four boundary ratchets — not the line count — are the primary enforcement mechanism.

A fifth guard — a **layered-dependency** check (e.g. `renderer/overlays/*` must not import `AppWindow.zig`; `input/*` must not import a concrete renderer) — is the documented next step; it needs per-edge allowlists and lands once the boundaries it asserts have converged. The layer model and the full remediation roadmap (state structs first, then import-hub, then per-domain file splits) live in [docs/decoupling-guide.md](docs/decoupling-guide.md).

## Hard Rules

When changing application **keyboard shortcuts** (bindings in `src/input.zig` and related input paths), **update `README.md`** so the [Keyboard shortcuts](README.md#keyboard-shortcuts) section stays accurate. Also update user-visible shortcut text in `src/renderer/overlays.zig` (startup overlay, command palette entries) when those strings describe the same bindings.

The main render loop is **event-driven** (`src/appwindow/render_gate.zig`): a frame is drawn only when `frameNeedsRender` is true, and `overlays.anyOverlayActive()` deliberately excludes statically-open overlays (command palette / command center, session launcher / new session, settings page) to keep idle CPU low. Therefore, any **overlay or panel key/char handler** in `src/input.zig` (`handleKey`/`handleChar`) that mutates UI state — selection index, filter text, focus — **must request a repaint**, or the change paints only on the next incidental wake (cursor blink ~530ms, mouse move) and navigation visibly lags ("不跟手") identically on Windows and macOS — it is shared logic, not platform code.

The mechanism is the **UI-effect boundary**, not a direct global write. Input dispatch returns a `UiEffect` (`src/appwindow/ui_effect.zig`: `consumed` / `needs_rebuild` / `cells_invalid` / `wake_backend`), and `input.zig` lands it through `requestInputRepaint()` / `requestInputRebuild()` / `applyInputEffect()`, which funnel into the single sink `AppWindow.applyUiEffect` — the only place that touches `g_force_rebuild` / `g_cells_valid` (and `window_backend.postWakeup()` for a worker thread, via `UiEffect{ .wake_backend = true }`). New or converted handlers **must return/route a `UiEffect`** and **must not write `AppWindow.g_force_rebuild` / `AppWindow.g_cells_valid` directly**: `src/input/dirty_guard.zig` enforces this on the converted regions of `input.zig`, and `src/source_guards/side_effect_guard.zig` freezes the remaining direct-write count per monolith so it can only shrink. Legacy direct writes survive only where already counted by that ratchet.

These `input.zig` compiled tests run only in the full app test binary (`zig build test-full`, and `zig build test-macos-ui` on macOS); the fast `zig build test` suite does **not** compile `input.zig` (the source-scan guards `@embedFile` it as text instead). Because `test-full` now also runs the fast suite, those guards gate the pre-merge build.

When publishing a new **desktop app version**, keep the desktop version surfaces synchronized before tagging or releasing: `build.zig.zon`, matching tests, release notes under `release-notes/`, package `version.txt` output, `wispterm.exe --version`, and the command center `Version` entry. The compiled desktop app reads its version from `build.zig.zon` through `build_options.app_version`; do not hard-code a second desktop version constant.

Do **not** change version files under `remote/` (`remote/package.json`, `remote/package-lock.json`, `remote/src/client/version.ts`, or the WispTerm Remote web UI version label) unless the user explicitly says the remote web console is part of the release. When a remote release is explicitly requested, keep those remote version surfaces synchronized, and ensure the web UI renders its release version via `remoteBrandMarkup()`/`webVersionLabel()` on both login and console shells, even when a build-time label is injected.

When working on implementing a plan from the plans directory:
 * never deviate from the plan without asking for clear consent
 * never deem something too big and choosing not to do it in the name of pragmatism
 * always ask if you have trouble because something is too big, we will break it down together and work on it step by step

## Planning

When planning, always compare what we are planning to do with https://github.com/ghostty-org/ghostty.
This is the gold standard, we want to be as close to their implementation as possible.

Use the github cli gh to browse https://github.com/ghostty-org/ghostty and always add descriptions on how ghostty does things. 

Exception: work under `remote/` is WispTerm's own web remote console and relay implementation. Ghostty does not have an equivalent feature, so `remote/` planning and implementation **does not need to compare against or reference Ghostty**. For `remote/`, follow the existing `remote/` architecture, browser platform constraints, and the user-approved design/plan for that feature.

## Build Commands

Develop on Windows in PowerShell with direct `zig` commands (do not assume non-PowerShell tooling). Use `zig build` for development; only use `zig build -Doptimize=ReleaseFast` for final/shipping builds. `build.zig` defaults to `x86_64-windows-gnu`. Full build commands, the required Zig toolchain version, and artifact checks live in [docs/development.md](docs/development.md#building).

Tests have two steps. `zig build test` is the fast inner loop: it builds and runs only platform-independent logic modules (`src/test_fast.zig`) against the native host — sub-second when cached, and it does **not** recompile the heavy `test_main` binary (the full app plus `ghostty-vt`/`xev`). `zig build test-full` runs the complete suite (shared compile checks + the app test binary) and is the pre-merge gate; run it before finishing a change. A single pure module can be run directly with `zig test src/<module>.zig`. When you add a unit-tested, platform-independent module, list it in `src/test_fast.zig`; keep target-coupled tests (which assert Windows behavior) out of the fast suite or guard them with `if (builtin.os.tag != .windows) return error.SkipZigTest;`.

## Frame-latency diagnostics

To quantify input responsiveness — e.g. the overlay arrow-key "feel" gated by the event-driven render loop (see the Hard Rule above) — use the opt-in frame-latency probe. Enable it with `wispterm-debug-render = true` in the config file, or `WISPTERM_RENDER_DIAGNOSTICS=1` **in the app process's own environment**. On macOS, `open Foo.app` launches via launchd and does **not** inherit your shell env, so either use the config key or run the bundle binary directly (`WISPTERM_RENDER_DIAGNOSTICS=1 ./zig-out/bin/WispTerm.app/Contents/MacOS/WispTerm`). The log lands at `%APPDATA%\wispterm\render-diagnostic.log` (Windows) / `~/Library/Application Support/wispterm/render-diagnostic.log` (macOS); `grep frame-latency` it while navigating.

Two line kinds: `frame-latency input->present count=N p50/p95/max=..ms` is genuine same-iteration input→present latency (the CPU pipeline wake → process → layout → draw-submit; it excludes the inherent ~1–2 frame vblank/compositor latency, so healthy is single-digit ms). `frame-latency STALL input->present=..ms iters=K (...)` is an input that painted nothing in its own loop iteration — a no-render key (bare modifier / unfocused), or a handler that forgot to mark the UI dirty — and is kept out of the p50/p95 stats. **A STALL that fires the instant you press a navigation key inside an overlay means a handler is missing its repaint `UiEffect` (the event-driven Hard Rule regression); a sporadic STALL on stray non-navigation keys is harmless.** Pure stats live in `src/appwindow/frame_latency.zig` (unit-tested, in the fast suite); the main-loop wiring + the input→render-gate regression tests are in `src/AppWindow.zig` / `src/input.zig`.

## Windows UI Automation

When debugging UI behavior, automate WispTerm as a real visible Windows app from PowerShell using Win32-driven automation rather than shell-only assumptions. The checked-in scripts and conventions are in [docs/development.md](docs/development.md#windows-ui-automation).

## Windows SSH/SCP Compatibility

When changing SSH/SCP code paths (`src/scp.zig`, SSH clipboard image paste, remote file explorer, or SSH session metadata), test against the real profile in `%APPDATA%\wispterm\ssh_hosts` when available — but never print or commit the password. Two hard rules: do **not** add OpenSSH connection sharing (`ControlMaster`/`ControlPersist`/`ControlPath`) to helper `ssh.exe`/`scp.exe` commands (it breaks SCP on Windows OpenSSH), and keep the underlying OpenSSH stderr visible rather than collapsing it to a generic failure. Test commands and the full rationale are in [docs/development.md](docs/development.md#windows-sshscp-compatibility).

## Windows Development Compatibility

This repository must remain safe to check out and develop on Windows. Before finishing changes that add, remove, rename, or move files, run the Windows path-safety checks — reserved names, illegal characters, case-fold collisions, symlinks, and path length — documented in [docs/development.md](docs/development.md#windows-checkout-safety).

## Project Structure

```
src/                         # Desktop terminal application
├── main.zig                 # Entry point, GLFW window, OpenGL setup, main loop
├── App.zig                  # Application-level state, config reload, remote client lifecycle
├── AppWindow.zig            # Window-level tabs, splits, rendering and input routing
├── Surface.zig              # Per-terminal surface state and PTY integration
├── input.zig                # Keyboard/mouse shortcuts and command dispatch
├── config.zig               # Config loading (file + CLI), theme resolution, key=value parser
├── config_watcher.zig       # Hot-reload via ReadDirectoryChangesW
├── pty.zig                  # App-facing PTY API (re-exports src/platform/pty.zig)
├── remote_client.zig        # Outbound WispTerm Remote relay client
├── file_explorer.zig        # Local/SSH file explorer state and operations
├── themes.zig               # Embedded Ghostty-compatible themes
├── browser/                 # Embedded browser panel, URL helpers, and stubs
├── html/                    # Temporary HTML serving for local/remote browser preview
├── jupyter/                 # Jupyter URL detection and picker state
├── platform/                # Platform abstraction layer: narrow capability
│                            #   interfaces with per-platform impls (_windows) and
│                            #   _unsupported/_posix stubs — PTY/process, window/input
│                            #   backends, font discovery, clipboard, file dialogs,
│                            #   remote transport, embedded browser, updater, etc.
├── appwindow/               # AppWindow decomposition: aggregated state model
│                            #   (state.zig / window_state / remote_state), feature
│                            #   bridges (weixin/agent/remote_sync), control API,
│                            #   surface snapshots, the UiEffect boundary, tab/split
├── input/                   # Input pipeline split out of input.zig: command
│                            #   dispatch, UiEffect helpers, hit-test, preview/path,
│                            #   plus source-scan guards (dirty/overlay effect)
├── apprt/                   # Win32/windowing support code
├── font/                    # Font manager, atlas, embedded fallback, sprite glyphs
├── renderer/                # OpenGL renderer, cell renderer, overlays, titlebar, panels
├── source_guards/           # Cross-cutting architecture ratchets: file-size backstop
│                            #   + global-state / import-hub / side-effect freezes
└── termio/                  # PTY read/write threads and terminal IO mailbox

remote/                      # WispTerm-specific web remote console and relay
├── src/client/              # Browser app: xterm surfaces, layout, virtual keyboard, styles
│   ├── views/               # Login and remote console views
│   └── styles/              # Base, console, responsive, token, and virtual keyboard CSS
├── src/server/              # Node.js relay server for Docker/local hosting
├── src/worker.ts            # Cloudflare Worker + Durable Object relay
├── index.html               # Vite browser entry
├── package.json             # Remote build/dev/typecheck scripts
├── Dockerfile               # Container build for the Node relay
├── docker-compose.yml       # Local/VPS Docker deployment helper
├── nginx.conf.example       # Reverse proxy example for Docker deployment
└── wrangler.toml.example    # Cloudflare deployment template

docs/                        # Static website and generated/project documentation
├── index.html
├── zh.html
├── style.css
├── assets/
└── superpowers/             # Approved design specs and implementation plans

plans/                       # Project planning notes and historical implementation plans
release-notes/               # Versioned release notes
debug/                       # Test/debug scripts, including Windows UI automation
packaging/windows/           # Windows installer and packaging scripts
assets/                      # Application icon and source art
shaders/                     # GLSL shader files
tools/                       # Terminal helper scripts such as imgcat/pdfcat
plugins/                     # Installed plugin root; future skills/MCP assets live here
pkg/                         # Vendored build dependencies (freetype, zlib, libpng, opengl, etc.)
vendor/                      # Vendored source code
```

## Ghostty Reference

WispTerm intentionally follows Ghostty's design and behavior for terminal emulator functionality. When implementing or modifying features in the main Zig terminal app, **cross-reference the Ghostty source** at https://github.com/ghostty-org/ghostty.

This Ghostty reference requirement does **not** apply to `remote/`. The `remote/` directory contains WispTerm-specific web remote console and relay code; develop it from the existing remote codebase, web/mobile UX requirements, and local plans rather than trying to match Ghostty.

Key mapping of WispTerm files to Ghostty counterparts:

| WispTerm | Ghostty Reference | Notes |
|---------|-------------------|-------|
| `src/config.zig` | [`src/config/Config.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/config/Config.zig) | Same `key = value` format, same key names where applicable |
| `src/config_watcher.zig` | Ghostty's config reload mechanism | Hot-reload on file change |
| `src/pty.zig` | [`src/os/ConPty.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/os/ConPty.zig) | Windows ConPTY, Ghostty also has this for Windows |
| `src/themes.zig` | [`src/config/theme.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/config/theme.zig) | Same theme file format, same built-in theme collection |
| `src/font/sprite/` | [`src/font/sprite/`](https://github.com/ghostty-org/ghostty/tree/main/src/font/sprite) | Box drawing, braille — follows Ghostty's sprite approach |
| `src/font/embedded.zig` | Ghostty's embedded Cozette font | Same fallback font |
| `src/main.zig` (rendering) | [`src/renderer/OpenGL.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/renderer/OpenGL.zig) | OpenGL rendering, cell grid, shaders |
| `src/main.zig` (input) | [`src/apprt/glfw.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/apprt/glfw.zig) | GLFW key/mouse handling |
| `src/platform/font_discovery_windows.zig` | [`src/font/discovery.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/font/discovery.zig) | Font discovery (WispTerm uses DirectWrite directly on Windows) |

When adding features:
- Check how Ghostty implements it first
- Match Ghostty's config key names and value formats
- Follow Ghostty's conventions for theme files, color handling, cursor behavior, etc.
- The VT parsing itself comes from Ghostty as a Zig dependency — don't reimplement terminal emulation

## Config System

Config lives at `%APPDATA%\wispterm\config`, is loaded defaults → config file → CLI flags (last wins), and hot-reloads via the file watcher (`Ctrl+,` to edit). Full details — path resolution order, portable profile, and all keys — are in [docs/configuration.md](docs/configuration.md).

## Dependencies

Defined in `build.zig.zon`:
- **ghostty** — libghostty-vt (VT parser + terminal state) from a pinned Ghostty main-branch snapshot. Prefer pinning an exact commit tarball and matching hash over `main.tar.gz`, so builds are reproducible.
- **glfw** — Window management and input
- **z2d** — 2D graphics library
- **freetype** / **zlib** / **libpng** / **opengl** — vendored in `pkg/`

When updating Ghostty, expect API drift. The current main-branch API returns `void` from terminal operations such as `Terminal.vt`, `Stream.nextSlice`, and `Terminal.scrollViewport`; do not add `try` or `catch {}` around those calls unless the dependency version actually returns an error union.
