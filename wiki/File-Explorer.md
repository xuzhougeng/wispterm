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

Open the right-side preview panel in either of two ways:

- Hold `Ctrl` (`Cmd` on macOS) and click a `.md`, `.txt`, `.csv`, `.tsv`, or
  supported image file in terminal output, **or**
- double-click a supported file in the File Explorer.

What each type renders:

- **Markdown** — headings, lists, blockquotes, code blocks, inline code, links,
  and horizontal rules.
- **Text** — shown as plain text.
- **CSV / TSV** — shown as a grid table.
- **Images** — PNG, JPEG, GIF, BMP, and WebP are decoded directly into the panel.

## Resizing, scrolling & zooming

- Drag the inner edges of the explorer and preview panels to resize them.
- Markdown, text, CSV, and TSV previews scroll with the mouse wheel; CSV/TSV
  cells show a larger hover popup when content does not fit.
- Image previews zoom with the mouse wheel and can be dragged to pan once zoomed.
- `Ctrl+Shift+W` closes the preview panel before it closes a split.

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
