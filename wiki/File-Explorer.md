# File Explorer & Previews

*English · [中文](File-Explorer-zh)*

> Browse local, WSL, and SSH files in a side panel, and preview Markdown, text, tables, and images without leaving the terminal.

## Opening the explorer

Press `Ctrl+Shift+Alt+E` to open the left-side File Explorer. It follows the
active environment:

- Windows shells browse local Windows paths.
- WSL sessions browse the default WSL distro through `wsl.exe`.
- WispTerm SSH profile sessions browse the remote host through OpenSSH helpers.

## Previewing files

Open a preview pane on the right in either of two ways:

- Hold `Ctrl` (`Cmd` on macOS) and click a `.md`, `.txt`, `.csv`, `.tsv`, a
  source-code or script file (including R scripts `.r` / `.R`), or a supported
  image file in terminal output, **or**
- double-click a supported file in the File Explorer.

Each content type (Markdown, plain text, CSV/TSV, image) keeps its own pane:
previewing another file of the same type replaces that pane's content, while a
different type opens a new pane stacked below the existing previews — a
Markdown file, an image, and a CSV table can stay on screen at the same time.

What each type renders:

- **Markdown** — headings, lists, blockquotes, code blocks, inline code, links,
  and horizontal rules.
- **Text / code / scripts** — shown as plain text (`.r`, `.R`, `.py`, `.zig`,
  `.sh`, `.json`, and similar).
- **CSV / TSV** — shown as a grid table.
- **Images** — PNG, JPEG, GIF, BMP, and WebP are decoded directly into the panel.

## Terminal path detection

Path clicks are resolved from terminal output, not only from files in the
explorer. WispTerm keeps soft-wrapped paths together, follows path continuations
across terminal line breaks, and can infer the directory prefix from nearby
commands such as `ls src/input`. That means a bare filename listed by `ls <dir>`
can preview as `<dir>/<file>` when the prefix is unambiguous.

## Opening a file in your default app

Hold `Ctrl` (`Cmd` on macOS) and **right-click** a file path in a **local**
terminal to open it in your operating system's default application for that file
type (`xdg-open` on Linux, `open` on macOS, the registered handler on Windows).

This works for local terminals only — SSH and WSL paths cannot be opened by a
local app, so there `Ctrl`-right-click falls through to the configured
`right-click-action` (copy/paste); see [[Configuration]]. A plain right-click
without `Ctrl` always performs the configured `right-click-action`.

## Resizing, scrolling & zooming

- Drag the inner edges of the explorer and preview panels to resize them.
- Markdown, text, CSV, and TSV previews scroll with the mouse wheel; CSV/TSV
  cells show a larger hover popup when content does not fit.
- Image previews zoom with the mouse wheel and can be dragged to pan once zoomed.
- `Ctrl+Shift+W` closes the focused pane — click a preview pane (or press
  `Ctrl+1-9`) to select it, then close it like any other split.

## Downloading remote files

In SSH profile sessions, hold `Ctrl+Shift` (`Cmd+Shift` on macOS) over a file
path in terminal output to underline it, then click to download that remote
file to `%USERPROFILE%\Downloads`. Downloads run in the background.

## SSH metadata requirement

Remote preview and download require WispTerm's SSH profile metadata, so only
sessions launched from the built-in SSH launcher are supported. Manually typing
`ssh user@host` inside a local shell is still treated as that local shell and
cannot use remote file preview — see [[SSH-Remote-Development]].

---
*See also: [[SSH-Remote-Development]] · [[Browser-Jupyter-Panel]]*
