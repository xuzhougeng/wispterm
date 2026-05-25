# TODO

## Cross-Platform Portability

Goal: ship native macOS and Linux ports without rewriting the terminal core.
The architecture is split into a platform-agnostic **core** (terminal state,
rendering pipeline, surface logic) and a per-platform **host** (window, event
loop, input, native UI integration) that drives the core through a narrow
surface API.

Ghostty reference: Ghostty keeps terminal core behavior separate from platform
runtimes. Its macOS app uses a native Swift/AppKit host with an embedded Zig
runtime surface API, CoreText fonts, POSIX PTYs, and Metal rendering. Phantty
follows the same core/host split.

Scope note: platform boundary checks apply to the desktop app/build/shared Zig
code. Do not include the Phantty-specific `remote/` web console or packaged
`plugins/` content in these platform-leakage checks.

### Architecture principle: core vs. host

- The **core** never imports a platform runtime. It exposes a surface API; the
  host calls into it and supplies platform services through narrow interfaces.
- Each platform service lives in `src/platform/` as `<cap>.zig` (the interface)
  plus `<cap>_windows.zig` / `<cap>_posix.zig` / `<cap>_unsupported.zig` impls.
- The host owns the OS event loop (Win32 message loop today; AppKit and GTK own
  their own loops) and pumps the core from there.

- [x] Define and document the core↔host surface API boundary explicitly, so the
      seam is a named contract rather than an implicit convention. App logic
      already routes through `src/platform/`; this item is about formalizing the
      surface API the host implements. Documented in
      [docs/architecture.md](docs/architecture.md): the host interface is
      `src/platform/window_backend.zig`, the platform-service capabilities are
      the `src/platform/<cap>.zig` facades, and the boundary invariants (plus
      the guards enforcing them) are listed there. AGENTS.md links to it.

### Phase 1 — Platform boundaries (largely complete)

These extract platform coupling behind interfaces so a port is *possible*. They
do not add new OS implementations.

- [x] Split platform APIs behind narrow interfaces instead of importing
      `src/apprt/win32.zig` and `std.os.windows` from app logic.
      App logic now goes through `src/platform/`.
- [x] Introduce a PTY/process abstraction (Windows ConPTY + `CreateProcessW`
      implemented; POSIX process layer present, POSIX PTY impl is Phase 2).
- [x] Separate window/event/input backends from `AppWindow.zig` behind a host
      interface (Windows backend implemented; macOS/Linux hosts are Phase 2).
- [x] Abstract font discovery and fallback (DirectWrite implemented;
      CoreText/fontconfig are Phase 2).
- [x] Keep the terminal rendering core independent from the presentation
      backend. `src/renderer/` has no win32/DirectWrite/WebView2 leakage. The
      renderer must support multiple GPU backends (OpenGL on Windows, Metal on
      macOS) behind one interface — the Metal backend itself is Phase 2.
- [x] Provide remote client networking behind one transport API
      (`src/platform/remote_transport*.zig`), not WinHTTP-specific app code.
- [x] Split embedded browser integration by platform behind an
      `EmbeddedBrowserBackend` build gate (WebView2 implemented; others gated
      off until a backend exists).
- [x] Isolate updater and release-asset logic so platform packaging does not
      leak into app runtime code.
- [x] Add build target selection and platform feature gates in `build.zig`,
      keeping Windows as the default development target until a port starts.
- [x] Add compile-only checks for shared modules on non-Windows targets.
- [x] Abstract clipboard, file picker, file drop, open-url, notifications,
      global hotkeys, DPI/content-scale, and config/theme directories.
      Notifications now live in `src/platform/notifications*.zig` (bell +
      window attention) behind the same facade pattern as the other
      capabilities; the bell/attention logic no longer rides on the window
      backend.

### Phase 2 — Native host implementations (not started)

This is the actual port work. Each platform needs a native host plus the
platform-service impls behind the Phase 1 interfaces.

Cross-cutting (both platforms):
- [ ] POSIX PTY/process backend: `openpty`/`fork`/`exec` + `ioctl(TIOCSWINSZ)`.
- [ ] Input/IME/keymap handling per platform (keycodes, modifiers, dead keys,
      IME composition) behind the input interface — the seam most likely to
      diverge across hosts.
- [ ] Renderer backend selection wired to the host's surface/event loop.

macOS (native, Metal):
- [ ] AppKit host: window, native menus, event loop ownership, input routing.
- [ ] Metal renderer backend (no OpenGL fallback — macOS is Metal-only).
- [ ] CoreText font discovery and fallback.
- [ ] WKWebView embedded browser backend.
- [ ] Clipboard, file picker/drop, open-url, notifications, global hotkeys,
      DPI/content-scale via AppKit; config/theme dirs under `~/Library`.
- [ ] Packaging: `.app` bundle / `.dmg`, updater story.

Linux (native):
- [ ] Host decision (GTK/libadwaita vs. another native toolkit) and impl.
- [ ] Renderer backend decision (OpenGL vs. Vulkan) and impl.
- [ ] fontconfig font discovery and fallback.
- [ ] WebKitGTK embedded browser, or keep disabled until viable.
- [ ] Clipboard, portals/file picker, open-url, notifications, global hotkeys,
      DPI/content-scale; config/theme dirs under XDG paths.
- [ ] Packaging: chosen distribution format + updater story.

### Invariants to maintain

- [x] Keep the `build.zig` `@compileError` guards that forbid leaking target
      OS booleans / Windows-specific names into app modules, so the core/host
      boundary cannot be quietly re-broken over time. The guard patterns now
      live in `src/build_guards.zig` (`firstLeak`); `build.zig` runs them over
      its own source at comptime on every build, and `test_main.zig` imports the
      module so the guard logic is covered by unit tests instead of relying on
      `build.zig`'s own never-executed `test` blocks.
- [x] Remove the remaining direct win32 reference in `src/test_main.zig` so no
      shared/test code outside `src/platform/` depends on a platform runtime.
      The `apprt/win32.zig` API-surface leak checks now live in
      `src/platform/apprt_win32_guard.zig`; `test_main.zig` imports that guard
      instead of embedding the Windows runtime source itself.
