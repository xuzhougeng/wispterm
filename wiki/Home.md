# WispTerm Wiki

*English · [中文](Home-zh)*

> WispTerm is a cross-platform terminal workspace for remote development and AI agent workflows. This wiki is the hands-on usage guide.

WispTerm (formerly **Phantty**) is written in Zig and powered by
[libghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation.
It bundles a fast terminal, tabs and splits, hundreds of themes, a file
explorer with previews, an embedded browser panel, and a built-in AI Copilot —
with first-class support for SSH and remote development.

## Platforms

WispTerm ships for **Windows** and **macOS** (Apple Silicon and Intel). The
**Linux** port is still in progress, so a few features below are Windows- or
macOS-only — those are called out where relevant.

## Features at a glance

- **Terminal emulation** — libghostty-vt VT parsing, FreeType glyph rendering, sprite/box-drawing.
- **Themes & appearance** — 450+ built-in Ghostty themes, custom fonts, background images, GLSL shaders → [[Themes-Appearance]]
- **Tabs, splits & panels** — vertical/horizontal splits, focus navigation, panel swap, Quake drop-down → [[Tabs-Splits-Panels]]
- **File Explorer & previews** — browse local, WSL, and SSH files; preview Markdown/text/tables/images → [[File-Explorer]]
- **SSH & remote development** — profile sessions, remote file download, automatic loopback port forwarding → [[SSH-Remote-Development]]
- **AI Copilot & Agent** — OpenAI-/Anthropic-compatible profiles, per-tab copilot sidebar, skills, history & resume → [[AI-Copilot]]
- **Browser & Jupyter panel** — open URLs in a side WebView panel (Windows) → [[Browser-Jupyter-Panel]]
- **Inline images** — Kitty Graphics protocol; show images and PDFs from remote shells → [[Inline-Images]]
- **Opt-in remote access** — share a session over a Cloudflare relay, disabled by default → [[Remote-Access]]

## Start here

1. **[[Installation]]** — download and run WispTerm on Windows or macOS.
2. **[[Getting-Started]]** — first launch, the command center, tabs and sessions.
3. **[[Configuration]]** — where the config lives and the keys you can set.

Having trouble? Check the **[[FAQ]]**.

---
*See also: [[Installation]] · [[Getting-Started]]*
