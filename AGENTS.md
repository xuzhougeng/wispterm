# AGENTS.md

## Overview

Phantty is a terminal emulator written in Zig, currently shipping on Windows. It uses [libghostty-vt](https://github.com/ghostty-org/ghostty) (Ghostty's VT parser and terminal state machine) for terminal emulation, with its own rendering pipeline (OpenGL + FreeType, plus DirectWrite for font discovery on Windows).

Windows is the **primary and default development target** (`x86_64-windows-gnu`), and day-to-day development happens on Windows in PowerShell. Platform-specific code lives behind narrow interfaces in `src/platform/` (per-platform implementations plus `_unsupported`/`_posix` stubs) so that macOS and Linux ports become possible without rewriting the terminal core. Those native ports are not yet implemented; see `TODO.md` for the portability roadmap.

## Architecture

Phantty is split into a platform-agnostic **core** (terminal state, IO, rendering) and a per-platform **host** (window, event loop, input) that drives the core through a narrow surface API. The host interface is `src/platform/window_backend.zig`; OS facilities go through capability facades in `src/platform/`. The named contract — what the host implements, what services it supplies, and the invariants that keep the seam intact — is documented in [docs/architecture.md](docs/architecture.md). Read it before touching the platform boundary or starting a port.

## Hard Rules

When changing application **keyboard shortcuts** (bindings in `src/input.zig` and related input paths), **update `README.md`** so the [Keyboard shortcuts](README.md#keyboard-shortcuts) section stays accurate. Also update user-visible shortcut text in `src/renderer/overlays.zig` (startup overlay, command palette entries) when those strings describe the same bindings.

When publishing a new **version**, keep all version surfaces synchronized before tagging or releasing: `build.zig.zon`, `remote/package.json`, `remote/package-lock.json`, `remote/src/client/version.ts`, matching tests, release notes under `release-notes/`, package `version.txt` output, `phantty.exe --version`, the command center `Version` entry, and the Phantty Remote web UI version label. The compiled desktop app reads its version from `build.zig.zon` through `build_options.app_version`; do not hard-code a second desktop version constant. The web UI must render its release version via `remoteBrandMarkup()`/`webVersionLabel()` on both login and console shells, even when a build-time label is injected.

When working on implementing a plan from the plans directory:
 * never deviate from the plan without asking for clear consent
 * never deem something too big and choosing not to do it in the name of pragmatism
 * always ask if you have trouble because something is too big, we will break it down together and work on it step by step

## Planning

When planning, always compare what we are planning to do with https://github.com/ghostty-org/ghostty.
This is the gold standard, we want to be as close to their implementation as possible.

Use the github cli gh to browse https://github.com/ghostty-org/ghostty and always add descriptions on how ghostty does things. 

Exception: work under `remote/` is Phantty's own web remote console and relay implementation. Ghostty does not have an equivalent feature, so `remote/` planning and implementation **does not need to compare against or reference Ghostty**. For `remote/`, follow the existing `remote/` architecture, browser platform constraints, and the user-approved design/plan for that feature.

## Build Commands

Develop on Windows in PowerShell with direct `zig` commands (do not assume non-PowerShell tooling). Use `zig build` for development; only use `zig build -Doptimize=ReleaseFast` for final/shipping builds. `build.zig` defaults to `x86_64-windows-gnu`. Full build commands, the required Zig toolchain version, and artifact checks live in [docs/development.md](docs/development.md#building).

Tests have two steps. `zig build test` is the fast inner loop: it builds and runs only platform-independent logic modules (`src/test_fast.zig`) against the native host — sub-second when cached, and it does **not** recompile the heavy `test_main` binary (the full app plus `ghostty-vt`/`xev`). `zig build test-full` runs the complete suite (shared compile checks + the app test binary) and is the pre-merge gate; run it before finishing a change. A single pure module can be run directly with `zig test src/<module>.zig`. When you add a unit-tested, platform-independent module, list it in `src/test_fast.zig`; keep target-coupled tests (which assert Windows behavior) out of the fast suite or guard them with `if (builtin.os.tag != .windows) return error.SkipZigTest;`.

## Windows UI Automation

When debugging UI behavior, automate Phantty as a real visible Windows app from PowerShell using Win32-driven automation rather than shell-only assumptions. The checked-in scripts and conventions are in [docs/development.md](docs/development.md#windows-ui-automation).

## Windows SSH/SCP Compatibility

When changing SSH/SCP code paths (`src/scp.zig`, SSH clipboard image paste, remote file explorer, or SSH session metadata), test against the real profile in `%APPDATA%\phantty\ssh_hosts` when available — but never print or commit the password. Two hard rules: do **not** add OpenSSH connection sharing (`ControlMaster`/`ControlPersist`/`ControlPath`) to helper `ssh.exe`/`scp.exe` commands (it breaks SCP on Windows OpenSSH), and keep the underlying OpenSSH stderr visible rather than collapsing it to a generic failure. Test commands and the full rationale are in [docs/development.md](docs/development.md#windows-sshscp-compatibility).

## Windows Development Compatibility

This repository must remain safe to check out and develop on Windows. Before finishing changes that add, remove, rename, or move files, run the Windows path-safety checks — reserved names, illegal characters, case-fold collisions, symlinks, and path length — documented in [docs/development.md](docs/development.md#windows-checkout-safety).

## Project Structure

```
src/                         # Windows desktop terminal application
├── main.zig                 # Entry point, GLFW window, OpenGL setup, main loop
├── App.zig                  # Application-level state, config reload, remote client lifecycle
├── AppWindow.zig            # Window-level tabs, splits, rendering and input routing
├── Surface.zig              # Per-terminal surface state and PTY integration
├── input.zig                # Keyboard/mouse shortcuts and command dispatch
├── config.zig               # Config loading (file + CLI), theme resolution, key=value parser
├── config_watcher.zig       # Hot-reload via ReadDirectoryChangesW
├── pty.zig                  # App-facing PTY API (re-exports src/platform/pty.zig)
├── remote_client.zig        # Outbound Phantty Remote relay client
├── file_explorer.zig        # Local/SSH file explorer state and operations
├── browser_panel.zig        # Embedded browser panel and SSH tunnel handling
├── themes.zig               # Embedded Ghostty-compatible themes
├── platform/                # Platform abstraction layer: narrow capability
│                            #   interfaces with per-platform impls (_windows) and
│                            #   _unsupported/_posix stubs — PTY/process, window/input
│                            #   backends, font discovery, clipboard, file dialogs,
│                            #   remote transport, embedded browser, updater, etc.
├── appwindow/               # Tab and split-tree helpers for AppWindow
├── apprt/                   # Win32/windowing support code
├── font/                    # Font manager, atlas, embedded fallback, sprite glyphs
├── renderer/                # OpenGL renderer, cell renderer, overlays, titlebar, panels
└── termio/                  # PTY read/write threads and terminal IO mailbox

remote/                      # Phantty-specific web remote console and relay
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

Phantty intentionally follows Ghostty's design and behavior for terminal emulator functionality. When implementing or modifying features in the main Zig terminal app, **cross-reference the Ghostty source** at https://github.com/ghostty-org/ghostty.

This Ghostty reference requirement does **not** apply to `remote/`. The `remote/` directory contains Phantty-specific web remote console and relay code; develop it from the existing remote codebase, web/mobile UX requirements, and local plans rather than trying to match Ghostty.

Key mapping of Phantty files to Ghostty counterparts:

| Phantty | Ghostty Reference | Notes |
|---------|-------------------|-------|
| `src/config.zig` | [`src/config/Config.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/config/Config.zig) | Same `key = value` format, same key names where applicable |
| `src/config_watcher.zig` | Ghostty's config reload mechanism | Hot-reload on file change |
| `src/pty.zig` | [`src/os/ConPty.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/os/ConPty.zig) | Windows ConPTY, Ghostty also has this for Windows |
| `src/themes.zig` | [`src/config/theme.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/config/theme.zig) | Same theme file format, same built-in theme collection |
| `src/font/sprite/` | [`src/font/sprite/`](https://github.com/ghostty-org/ghostty/tree/main/src/font/sprite) | Box drawing, braille — follows Ghostty's sprite approach |
| `src/font/embedded.zig` | Ghostty's embedded Cozette font | Same fallback font |
| `src/main.zig` (rendering) | [`src/renderer/OpenGL.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/renderer/OpenGL.zig) | OpenGL rendering, cell grid, shaders |
| `src/main.zig` (input) | [`src/apprt/glfw.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/apprt/glfw.zig) | GLFW key/mouse handling |
| `src/platform/font_discovery_windows.zig` | [`src/font/discovery.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/font/discovery.zig) | Font discovery (Phantty uses DirectWrite directly on Windows) |

When adding features:
- Check how Ghostty implements it first
- Match Ghostty's config key names and value formats
- Follow Ghostty's conventions for theme files, color handling, cursor behavior, etc.
- The VT parsing itself comes from Ghostty as a Zig dependency — don't reimplement terminal emulation

## Config System

Config lives at `%APPDATA%\phantty\config`, is loaded defaults → config file → CLI flags (last wins), and hot-reloads via the file watcher (`Ctrl+,` to edit). Full details — path resolution order, portable profile, and all keys — are in [docs/configuration.md](docs/configuration.md).

## Dependencies

Defined in `build.zig.zon`:
- **ghostty** — libghostty-vt (VT parser + terminal state) from a pinned Ghostty main-branch snapshot. Prefer pinning an exact commit tarball and matching hash over `main.tar.gz`, so builds are reproducible.
- **glfw** — Window management and input
- **z2d** — 2D graphics library
- **freetype** / **zlib** / **libpng** / **opengl** — vendored in `pkg/`

When updating Ghostty, expect API drift. The current main-branch API returns `void` from terminal operations such as `Terminal.vt`, `Stream.nextSlice`, and `Terminal.scrollViewport`; do not add `try` or `catch {}` around those calls unless the dependency version actually returns an error union.
