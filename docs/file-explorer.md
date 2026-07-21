# File Explorer and Preview Panel

Press `Ctrl+Shift+Alt+E` to open the left-side File Explorer. It follows the
active environment:

- Windows shells browse local Windows paths.
- WSL sessions browse the default WSL distro through `wsl.exe`.
- WispTerm SSH profile sessions browse the remote host through OpenSSH helpers.

Hold `Ctrl` (`Cmd` on macOS) and click a `.md`, `.txt`, `.csv`, `.tsv`, a
source-code or script file (including R scripts `.r` / `.R`), a supported
image file, or a `.pdf` in terminal output, or double-click a supported file in
the File Explorer, to open a preview pane on the right. Each content type
(Markdown, plain text, CSV/TSV, image, PDF) keeps its own pane: previewing
another file of the same type replaces that pane's content, while a different
type opens a new pane stacked below the existing previews — a Markdown file, an
image, and a CSV table can stay on screen at the same time.
Markdown previews render headings, lists, blockquotes, code blocks, inline code,
links, and horizontal rules. Text, source-code, and script files (such as `.r`,
`.R`, `.py`, `.zig`, `.sh`, `.json`) are shown as plain text. CSV and TSV
files are shown as a grid table. Image previews decode PNG, JPEG, GIF, BMP, and
WebP bytes directly into the panel. With an image or PDF preview focused,
`Left` / `Right` open the previous or next supported image/PDF in the same
directory.

PDF previews rasterize one page at a time with the operating system's own
PDF engine: `Windows.Data.Pdf` on Windows 10+, CoreGraphics on macOS, and the
`poppler-utils` tools (`pdfinfo` / `pdftoppm`) on Linux — install them with
your package manager (for example `sudo apt install poppler-utils`) if the
preview reports they are missing. With the PDF preview focused, `PageUp` /
`PageDown` switch pages inside the current PDF; the footer shows the current
page as `N/M` next to the
`PDF` badge. Zoom and pan work like image previews. Encrypted PDFs are not
supported.

Hold `Ctrl` (`Cmd` on macOS) and **right-click** a file path in a local terminal
to open it in your operating system's default application for that file type
(`xdg-open` on Linux, `open` on macOS, the registered handler on Windows). This
works for local terminals only — SSH and WSL paths cannot be opened by a local
app, so there `Ctrl`-right-click falls through to the configured
`right-click-action` (copy/paste). A plain right-click without `Ctrl` always
performs the configured `right-click-action`.

In SSH profile sessions, hold `Ctrl+Shift` (`Cmd+Shift` on macOS) over a file
path in terminal output to underline it, then click to download that remote file to
`%USERPROFILE%\Downloads`. Downloads run in the background.

Open the command center with `Ctrl+Shift+P` and run `Toggle Browser` to open
the embedded browser panel when the platform backend is available.
`Ctrl`-clicking (`Cmd`-click on macOS) an `http://` or `https://` URL in terminal
output opens it in the same right-side panel when available; builds without an
embedded browser backend, or without a usable runtime, open URLs in the system
default browser instead. Set `url-open-mode = system-browser` to always open
web URLs in the system default browser, including when an embedded browser
backend is available. In SSH profile sessions, loopback URLs such as
`http://127.0.0.1:4232` and
`http://localhost:43455` are opened through automatic local SSH tunnels.
Tunnels are shared by the embedded panel and the system browser, so setting
`url-open-mode = system-browser` lets the remote web app open in your normal
browser. Each remote port keeps its own forward; WispTerm prefers the
same local port and only increments when that port is already occupied.

Non-loopback URLs such as `https://10.10.x.x` or public websites open directly.
Click the browser panel's URL bar to type a new address; press `Enter` to
navigate. Drag the browser panel's left edge to resize it.

The left File Explorer and right-side preview/browser panels can be resized by
dragging their inner edges. Markdown, text, CSV, and TSV previews scroll with
the mouse wheel; CSV and TSV cells show a larger hover popup when their content
does not fit in the visible cell. Image and PDF previews zoom in and out with
the mouse wheel and can be dragged to pan after zooming. `Ctrl+Shift+W` (`Cmd+W`
on macOS) closes
the focused pane — click a preview pane (or press `Ctrl+1-9`) to select it, then
close it like any other split.

SSH previews require WispTerm's SSH profile metadata, so sessions launched from
the built-in SSH launcher are supported. Manually typing `ssh user@host` inside
a local shell is still treated as that local shell and cannot use remote file
preview yet.

## SSH Current Directory for Drag-and-Drop Uploads

Drag-and-drop uploads in WispTerm SSH profile sessions use the active remote
working directory when the shell reports it with OSC 7. This matches the
terminal convention used by Ghostty shell integration. If the remote shell does
not report OSC 7, WispTerm falls back to running `pwd` through a fresh
`ssh.exe` helper, which usually returns the SSH login directory instead of the
directory you `cd`'d to in the interactive shell. In that case WispTerm shows a
clickable setup prompt.

Add one of these snippets to the remote shell startup file, then start a new
WispTerm SSH session.

For Bash, add this to `~/.bashrc`:

```bash
__wispterm_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$PWD"
}
PROMPT_COMMAND="__wispterm_report_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

For Zsh, add this to `~/.zshrc`:

```zsh
__wispterm_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOST:-localhost}" "$PWD"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd __wispterm_report_cwd
add-zsh-hook precmd __wispterm_report_cwd
```

For Fish, add this to `~/.config/fish/config.fish`:

```fish
function __wispterm_report_cwd --on-variable PWD
    printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url $PWD)
end
__wispterm_report_cwd
```

For old bastions or servers that still require disabled OpenSSH algorithms, set
`ssh-legacy-algorithms = true`. This appends compatibility options for
`ssh-rsa`, `ssh-dss`, older Diffie-Hellman KEX, and CBC ciphers to WispTerm's SSH
profile launches and helper `ssh.exe` / `scp.exe` commands.
