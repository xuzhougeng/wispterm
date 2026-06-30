# Roadmap

This file tracks future work for the desktop app and the platform ports. It is
not a completion log. Completed work should move to release notes or remain in
git history.

## Platform Direction

WispTerm currently ships desktop builds for Windows and macOS, plus an
experimental Linux AppImage. Windows remains the primary development target and
the default `zig build` target (`x86_64-windows-gnu`).

The portability goal is to keep terminal core behavior platform-neutral while
platform-specific hosts and services live behind the facades in `src/platform/`.
The core/host contract is documented in [docs/architecture.md](docs/architecture.md).

## macOS Stabilization

- Add locking or atomics to the AppKit-to-render-thread event buffers in
  `window_macos_bridge.m`; the producer and consumer are now on different
  threads.
- Add a draggable region for the app-drawn titlebar outside the traffic-light
  controls.
- Fix macOS window-position persistence by translating AppKit coordinates into
  WispTerm's top-left window-state semantics and validating the whole frame
  against visible displays.
- Continue on-device validation for file explorer previews, Markdown/image/PDF
  preview chrome, WKWebView browser panel behavior, and remote transport against
  a live relay.
- Revisit the macOS updater story. Current releases ship signed/notarized DMGs;
  a full unattended updater should follow a Sparkle-style approach.
- Add runtime validation and localization for the native macOS app menu.

## Linux Port

The Linux build is experimental. The remaining work is to make the Linux host
feel first-class rather than just compile:

- Stabilize the SDL3 host/event loop and verify the OpenGL renderer on common
  desktop environments.
- Finish Linux platform services: global hotkeys, config watcher, process
  memory diagnostics, display/off-screen guards, release package detection, and
  session locking.
- Add Linux remote transport or explicitly keep WispTerm Remote unavailable on
  Linux until a maintained WebSocket/TLS path exists.
- Decide whether to add WebKitGTK for the embedded browser panel or keep Linux
  URL handling on the system browser.
- Improve fontconfig discovery/fallback and publish distro-specific runtime
  dependency notes.

## Renderer And GPU Work

- Make Windows a native GPU target by adding a real Direct3D 11 backend behind
  the existing renderer backend abstraction. The long-term target matrix is
  Windows = D3D11/DXGI, macOS = Metal, Linux = OpenGL, with the current
  OpenGL + DXGI flip-present path retained as the Windows fallback during the
  migration. See [docs/windows-native-d3d11-roadmap.md](docs/windows-native-d3d11-roadmap.md).
- Finish the custom-shader path on Metal by adding a GLSL-to-MSL translation
  layer and then wiring FBO render-target switching where it has a working
  consumer.
- Continue shrinking the documented `gpu.glTable()` residue by moving GL-shaped
  render plumbing into backend-neutral GPU primitives.
- Consider converging Metal blend behavior toward Ghostty's premultiplied-alpha
  model once the current variant-based pipeline is stable.

## Codebase Decomposition

Several large files still combine UI presentation, input routing, and state
logic. Future feature work should keep extracting testable modules as it touches
these areas:

- `src/assistant/conversation/session.zig`
- `src/input.zig`
- `src/AppWindow.zig`
- `src/renderer/overlays.zig`

Prefer narrow, behavior-preserving extractions tied to active work over broad
standalone rewrites.

## Remote Web Console

The `remote/` web console and relay are versioned and released independently
from the desktop app. Work under `remote/` should follow its own architecture,
tests, and release process; it does not need Ghostty comparison.
