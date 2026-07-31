# Browser & Jupyter Panel

*English · [中文](Browser-Jupyter-Panel-zh)*

> Open web URLs in a side panel without leaving the terminal.

## Embedded browser panel

On builds with an embedded browser backend (WebView2 on Windows, WKWebView on
macOS), WispTerm can show web pages in a right-side panel:

- Open the command center (`Ctrl+Shift+P`) and run **Toggle Browser**.
- `Ctrl`-click (`Cmd`-click on macOS) an `http://` or `https://` URL in terminal
  output to open it in the panel.
- Click the panel's URL bar to type a new address and press `Enter`.
- Drag the panel's left edge to resize it.

Builds without embedded browser support, or without a usable browser runtime,
open URLs in the system default browser instead. The embedded panel shares the
right slot with the Copilot sidebar and Markdown preview, so opening one hides
the others.

## Where URLs open

`url-open-mode` controls where web URLs open:

- `embedded` (default) — use the right-side browser panel when available.
- `system-browser` — always open in the system default browser.

In SSH profile sessions, loopback URLs are opened through automatic local SSH
tunnels shared by both modes — see [[SSH-Remote-Development]].

## Jupyter

Connecting to a remote Jupyter notebook from a dedicated panel is **in progress**
and not part of a released build yet. For now, open a Jupyter URL the same way
as any other web app: start Jupyter on the remote host, then `Ctrl`/`Cmd`-click
the printed `http://localhost:<port>/?token=...` URL — WispTerm forwards the
loopback port over SSH automatically (see [[SSH-Remote-Development]]).

---
*See also: [[SSH-Remote-Development]] · [[File-Explorer]]*
