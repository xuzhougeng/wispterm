# TODO

## Cross-Platform Portability Prep

Goal: make future macOS and Linux ports possible without rewriting the terminal
core. This is not a commitment to ship those ports immediately; it is the
architectural groundwork needed before a native port can be planned safely.

Ghostty reference: Ghostty keeps terminal core behavior separate from platform
runtimes. Its macOS app uses a native Swift/AppKit host with an embedded Zig
runtime surface API, CoreText fonts, POSIX PTYs, and Metal rendering. Phantty
should move toward similarly explicit boundaries before attempting macOS or
Linux support.

Scope note: platform boundary checks apply to the desktop app/build/shared Zig
code. Do not include the Phantty-specific `remote/` web console or packaged
`plugins/` content in these platform-leakage checks.

- [x] Split platform APIs behind narrow interfaces instead of importing
      `src/apprt/win32.zig` and `std.os.windows` from app logic.
      App logic now goes through `src/platform/`; only `src/test_main.zig`
      still references win32 directly.
- [x] Introduce a PTY/process abstraction:
      - Windows: ConPTY plus `CreateProcessW`. (done)
      - macOS/Linux: POSIX `openpty`/`fork`/`exec` plus `ioctl(TIOCSWINSZ)`.
        (abstraction + posix process in place; native POSIX PTY impl pending
        the port phase)
- [x] Separate window/event/input backends from `AppWindow.zig`:
      - Windows: current Win32 backend. (done)
      - macOS: native AppKit host, following Ghostty/cmux style.
      - Linux: GTK/libadwaita, GLFW, or another explicit native host decision.
      (backend abstraction done; native macOS/Linux hosts pending the port phase)
- [x] Abstract font discovery and fallback:
      - Windows: DirectWrite. (done)
      - macOS: CoreText.
      - Linux: fontconfig.
      (backend abstraction done; CoreText/fontconfig impls pending the port phase)
- [x] Keep terminal rendering core independent from the presentation backend.
      Decide later whether macOS should keep OpenGL temporarily or move directly
      to Metal like Ghostty.
      `src/renderer/` has no win32/DirectWrite/WebView2 leakage.
- [ ] Abstract clipboard, file picker, file drop, open-url, notifications,
      global hotkeys, DPI/content-scale, and config/theme directories.
      All abstracted except notifications, which still has no platform module.
- [x] Replace Windows-only remote client networking (`WinHTTP`) with a portable
      WebSocket transport, or provide per-platform transports behind one API.
      Satisfied via per-platform transports behind one API
      (`src/platform/remote_transport*.zig`).
- [x] Split embedded browser integration by platform:
      - Windows: WebView2. (done)
      - macOS: WKWebView.
      - Linux: WebKitGTK or disable until a supported backend exists.
      (abstraction + `EmbeddedBrowserBackend` build gate done; non-Windows
      currently disabled, as allowed)
- [x] Isolate updater and release asset logic so platform-specific packaging
      does not leak into app runtime code.
- [x] Add build target selection and platform feature gates in `build.zig`,
      keeping Windows as the default development target until a port starts.
- [x] Add compile-only checks for shared modules on non-Windows targets once
      the first layer of platform boundaries exists.
