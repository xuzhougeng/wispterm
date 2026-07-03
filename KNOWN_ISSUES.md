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
| Auto-update package matching | Windows portable zip flavors | Generic DMG matcher; release-asset naming needs review | Not implemented |

## Version Surfaces

The desktop app version comes from `build.zig.zon` and is exposed by
`wispterm --version` plus the command center `Version` entry.

The Remote web console/relay version is separate and lives under `remote/`
(`remote/package.json`, `remote/package-lock.json`, and
`remote/src/client/version.ts`). A desktop release does not imply a Remote web
console release unless the release explicitly includes `remote/`.

## Windows

- The native D3D11 renderer on `windows-native-render` is still opt-in and is
  not the Windows `auto` default. Phase VI is blocked until the evidence and
  rollback checklist in
  [windows-native-d3d11-default-gate.md](docs/windows-native-d3d11-default-gate.md)
  is satisfied.
- D3D11 fallback is next-launch/future-auto policy only. The app does not switch
  from D3D11 to OpenGL inside the same running process.
- RDP, virtual-machine, hybrid-GPU, weak-integrated-GPU, and multi-monitor
  mixed-DPI evidence is still tracked as matrix evidence rather than a fully
  closed release claim.

## macOS

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
- The macOS update checker currently matches a generic `wispterm-macos-{tag}.dmg`
  name while release workflows publish arch-qualified DMG assets. Align the
  matcher before relying on in-app macOS update downloads.

## Linux

- Embedded browser panel is disabled. `url-open-mode = embedded` falls back to
  the system browser.
- WispTerm Remote transport is not implemented on Linux; `remote-enabled = true`
  cannot connect to the relay there.
- Global hotkeys are not implemented, so Quake mode cannot bind a system-wide
  shortcut.
- Live config reload is not implemented; config changes require restart.
- Update asset detection does not match Linux AppImage assets yet.
- Font family enumeration is incomplete; exact `font-family` values can work,
  but picker/autocomplete results may be empty.
- Off-screen window guards are incomplete.

## Cross-Platform

- Custom post-processing shaders are OpenGL/GLSL-oriented. D3D11 and Metal
  explicitly ignore custom shader paths and render without post-processing until
  they have native shader support or a translation layer.
- Some renderer coordination still uses documented OpenGL-shaped compatibility
  plumbing. It is guarded and shrinking, but not fully backend-neutral yet.
