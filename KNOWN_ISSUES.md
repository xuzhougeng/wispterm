# Known Issues

This file tracks current, observable defects and platform limitations. Future
plans belong in [ROADMAP.md](ROADMAP.md); completed changes belong in
`release-notes/`.

## Platform Support Matrix

| Area | Windows | macOS | Linux |
| --- | --- | --- | --- |
| Release status | Primary supported target | Supported build, still stabilizing | Experimental AppImage |
| Default development target | Yes | No | No |
| Terminal host | Win32/ConPTY | AppKit/PTY | SDL3/POSIX PTY, experimental |
| Embedded browser panel | WebView2 | WKWebView | Disabled |
| WispTerm Remote transport | WinHTTP WebSocket | NSURLSession WebSocket | Not implemented |
| Auto-update package matching | Windows portable zip flavors | Architecture-specific DMG matching | x86_64 AppImage matching |

## Version Surfaces

The desktop app version comes from `build.zig.zon` and is exposed by
`wispterm --version` plus the command center `Version` entry.

The Remote web console/relay version is separate and lives under `remote/`
(`remote/package.json`, `remote/package-lock.json`, and
`remote/src/client/version.ts`). A desktop release does not imply a Remote web
console release unless the release explicitly includes `remote/`.

## Windows

- Starting with v1.34.0, the native D3D11 renderer is the Windows `auto`
  default. The separately published `portable-opengl` package is the renderer
  fallback.
- The app does not switch from D3D11 to OpenGL inside the same running process.
  A D3D11 startup/rendering failure requires restarting with the separately
  built OpenGL package.
- D3D11 Phase V environment matrix gaps are accepted known issues where the
  current operators do not have matching machines or sessions available. These
  accepted gaps are not passing test evidence, and should be replaced with
  real `debug\test-d3d11-environment-smoke.ps1` artifacts when the environment
  becomes available.

### Accepted D3D11 Phase V Environment Matrix Gaps

The following matrix classes are explicitly accepted as untested for the
current Phase V closeout because matching hardware, monitor topology, VM, or
RDP session coverage is not available:

- `rdp`
- `virtual-machine`
- `hybrid-gpu`
- `weak-integrated-gpu`
- `single-monitor`
- `multi-monitor-same-dpi`

The current evidence set records `local-physical` and
`multi-monitor-mixed-dpi`; the classes above remain accepted gaps rather than
tested passes.

## macOS

- **macOS 12 Monterey is best-effort.** The app is built for macOS 12.0
  (binary minos and `LSMinimumSystemVersion`), and CI rejects any Objective-C
  API newer than 12.0 that is not wrapped in `@available`. No hosted runner can
  launch macOS 12, and Apple no longer patches it, so behavior on 12 is
  untested: AppKit, WebKit, and Metal differences only show up on a real
  machine. Ghostty supports 13.0 and later.
- **1.40.5 and earlier leak memory on macOS (fixed in 1.40.6).** WispTerm
  does not start through `NSApplicationMain`, so no thread had an outer
  autorelease pool, and AppKit objects autoreleased outside an explicit
  `@autoreleasepool` were never freed. The largest source was
  `-[NSWindow isZoomed]`, polled every frame: about 4 empty `NSMutableArray`s
  per call. One report reached a 4.7 GB footprint after 1.5 days. In an A/B run
  of the same Debug build with continuous terminal output, the arrays grew by
  about 290 per second before the fix and stayed flat after it. The fix has
  three parts. The window loop now opens an autorelease pool per iteration
  (`window_backend.beginLoopIteration`, the same pattern as Ghostty's Metal
  renderer). `isZoomed` is now cached from window-delegate callbacks. Every
  exported `.m` bridge function opens its own pool, and
  `src/source_guards/objc_autorelease_guard.zig` enforces this. Remaining gaps:
  the guard is lexical, so property dot-syntax sends (`obj.prop`) are not
  checked, and no multi-day soak run has been done yet.
- Event buffers in `window_macos_bridge.m` cross the AppKit main thread and the
  render/input worker thread. They are now serialized with `os_unfair_lock`
  (`input_lock`/`message_lock`); the remaining gap is heavy-input stress testing
  rather than an unguarded data race.
- With the native title bar hidden, the window is only reliably draggable via
  traffic-light gaps. Add a drag region to the app-drawn titlebar.
- Window-position persistence stores AppKit bottom-origin coordinates in fields
  named like top-left coordinates, so restored windows can land off-screen on
  unusual multi-monitor layouts.
- WKWebView browser support is built, but still needs broader on-device testing
  with SSH loopback tunnels and Jupyter-style URLs.
- Remote transport uses a native `NSURLSessionWebSocketTask` bridge and is
  compiled/tested on macOS, but full relay interoperability still needs live
  relay smoke coverage before removing the "stabilizing" qualifier.
## Linux

- Embedded browser panel is disabled. `url-open-mode = embedded` falls back to
  the system browser.
- WispTerm Remote transport is not implemented on Linux; `remote-enabled = true`
  cannot connect to the relay there.
- Global hotkeys are not implemented, so Quake mode cannot bind a system-wide
  shortcut.
- Live config reload is not implemented; config changes require restart.
- Font family enumeration is incomplete; exact `font-family` values can work,
  but picker/autocomplete results may be empty.
- The Password Store has no Secret Service (libsecret) integration: its
  encryption key is an owner-only `passwords.key` file next to the vault, so a
  same-user process can decrypt it. macOS (Keychain) and Windows (DPAPI) keep
  the key out of the config directory.
- Off-screen window guards are incomplete.
- Sync cannot create WebDAV folders (`MKCOL` is not available in the std HTTP
  client used on Linux): create the remote folder on the drive by hand before
  the first sync. Synced-folder sync is unaffected.

## Cross-Platform

- Custom post-processing shaders are OpenGL/GLSL-oriented. D3D11 and Metal
  explicitly ignore custom shader paths and render without post-processing until
  they have native shader support or a translation layer.
- Some renderer coordination still uses documented OpenGL-shaped compatibility
  plumbing. It is guarded and shrinking, but not fully backend-neutral yet.
- Sync resolves conflicting edits by each computer's clock (newest wins), so a
  computer with a badly wrong clock can win or lose a conflict it should not.
- Sync updates an Agent conversation that is open in a tab only in the history
  store; the open tab keeps its own copy and saves it again on its next message
  (so the tab's version wins). Reopen the conversation to see the synced one.
- Screen-based agent status (`agent-screen-detection`) first has to know
  *which* agent a tab runs. Local tabs read the PTY's foreground process
  (macOS/Linux) or the shell's descendant processes (Windows). It cannot see
  through `ssh`, so an agent started by hand in an SSH tab is only recognized
  when it is Claude Code (its `✳ …` title) or when the tab was opened from the
  AI History resume action / a tmux pane; the OSC 7748 hook marker remains the
  authoritative source wherever it is installed. On Windows, agents that run
  as a bare `node.exe` / `python.exe` script (e.g. Gemini CLI) are not named
  either, because the process command line is not read. Detection reads only
  the visible viewport and follows herdr's manifests, so an agent UI redesign
  can show `idle` until the manifest is refreshed
  (`src/terminal_agents/manifests/README.md`).
