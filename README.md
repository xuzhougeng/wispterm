# Phantty

A Windows terminal written in Zig, powered by [libghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation.

> [!NOTE]
> This repository is a fork of [arya-s/phantty](https://github.com/arya-s/phantty),
> with additional features layered on top: an embedded WebView2 browser panel,
> a file explorer with Markdown/text/image preview, AI Agent sessions,
> an opt-in remote-access client,
> Kitty Graphics image protocol support, and a configurable background image.

## Features

- **Ghostty's terminal emulation** - uses libghostty-vt for VT parsing and terminal state
- **DirectWrite font discovery** - find system fonts by name, with per-glyph fallback for missing characters
- **FreeType rendering** - high-quality glyph rasterization with Ghostty-style font metrics
- **Sprite rendering** - box drawing, block elements, braille patterns, powerline symbols
- **Theme support** - Ghostty-compatible theme files, 450+ themes built in (default: Poimandres)
- **Background image and shaders** - wallpaper blending plus Ghostty-compatible GLSL post-processing
- **Splits and tabs** - vertical/horizontal splits, tab strip, focus-follows-mouse, equalize sizes
- **File Explorer and previews** - browse local, WSL, and SSH files; preview Markdown/text/images without leaving the terminal
- **Embedded browser panel** - open web URLs in a side WebView2 panel, with SSH loopback tunneling for profile sessions
- **AI Agent sessions** - launch an OpenAI-compatible Agent tab directly and configure profiles in Settings
- **Kitty Graphics protocol** - display inline images and PDFs from remote shells via `imgcat.py` / `pdfcat.py`
- **Opt-in remote access** - share a session key over a Cloudflare-hosted relay (disabled by default)

> [!NOTE]
> Phantty is **Windows-only**. On macOS and Linux, use [Ghostty](https://ghostty.org/) instead.

## Documentation

- [Configuration](docs/configuration.md)
- [File Explorer and previews](docs/file-explorer.md)
- [AI Agent sessions](docs/ai-agent.md)
- [Media, background images, and inline remote images](docs/media.md)
- [Development, architecture, packaging, and releases](docs/development.md)
- [FAQ](docs/faq.md)

## Building

```powershell
zig build                         # Debug build for development
zig build -Doptimize=ReleaseFast  # ReleaseFast build for distribution
Remove-Item -Recurse -Force .\zig-out, .\.zig-cache -ErrorAction SilentlyContinue
```

The `Makefile` may still exist as a convenience wrapper, but normal Windows
development should use PowerShell and direct `zig` commands.

For architecture, packaging, and release details, see [Development, architecture, packaging, and releases](docs/development.md).

## Usage

```bash
phantty.exe [options]

Options:
  --font, -f <name>            Set font (default: embedded fallback)
  --font-style <style>         Font weight (default: regular)
                                Options: thin, extra-light, light, regular,
                                         medium, semi-bold, bold, extra-bold, black
  --cursor-style <style>       Cursor shape (default: block)
                                Options: block, bar, underline, block_hollow
  --cursor-style-blink <bool>  Enable cursor blinking (default: true)
  --theme <path>               Load a Ghostty theme file
  --background-image <path>    Image file to render behind the terminal
  --background-opacity <0..1>  Opacity of theme/cell backgrounds (default: 1.0)
  --background-image-mode <m>  fill | fit | center | tile (default: fill)
  --window-height <rows>       Initial window height in cells (default: 0=auto, min: 4)
  --window-width <cols>        Initial window width in cells (default: 0=auto, min: 10)
  --config <path>              Use this file as the main config
  --config-path <path>         Alias for --config
  --config-file <path>         Include another config file (prefix ? for optional)
  --version, -v                Print the Phantty version and exit
  --show-config-path           Print the resolved main config path
  --list-fonts                 List available system fonts
  --list-themes                List available themes
  --test-font-discovery        Test DirectWrite font discovery
  --help, -h                   Show help
```

Configuration file details are in [Configuration](docs/configuration.md).

## Keyboard shortcuts

Default chords are implemented in [`src/input.zig`](src/input.zig). Some keys are handled first when a modal overlay is open (command center, session launcher, settings, and similar).

To confirm the running desktop version, open the command center with `Ctrl+Shift+P`, type `version`, and press Enter.


| Shortcut                                                                       | Action                                                                             |
| ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| **Ctrl+Shift+P**                                                               | Open command center                                                                |
| **Ctrl+Shift+T**                                                               | New session (session launcher)                                                     |
| **Ctrl+Shift+N**                                                               | New window                                                                         |
| **Ctrl+Shift+B**                                                               | Toggle tab sidebar                                                                 |
| **Ctrl+Shift+O**                                                               | Split to the right                                                                 |
| **Ctrl+Shift+Alt+E**                                                           | Toggle file explorer sidebar                                                       |
| Ctrl-click `.md` / `.txt` / image files in terminal output, or double-click in File Explorer | Preview local, WSL, or SSH Markdown/text/images in the right preview panel        |
| Ctrl+Shift-click file path in SSH terminal output                              | Download the SSH remote file to `%USERPROFILE%\Downloads`                         |
| **Ctrl+Shift+W**                                                               | Close focused panel, tab, or window; press again to confirm closing the last panel |
| **Alt+Enter**                                                                  | Maximize or restore window                                                         |
| **Ctrl++** / **Ctrl+-**                                                        | Increase / decrease font size                                                      |
| **Ctrl+Shift+C**                                                               | Copy terminal selection, or copy AI Chat selection/transcript                     |
| Shift-click terminal text                                                      | Select from the last terminal click anchor                                        |
| Drag AI answer text                                                            | Select part of an AI answer for `Ctrl+C`                                          |
| Shift-drag AI answer text                                                      | Select and copy part of an AI answer                                              |
| **Ctrl+A** in AI Chat                                                          | Select the input text; when the input is empty, select the transcript             |
| **Ctrl+C** in AI Chat                                                          | Copy the selected AI Chat text, or copy the transcript when nothing is selected   |
| **D** / **Delete** in Agent History                                            | Delete the selected saved Agent session                                          |
| Left / Right / Home / End / Delete / Backspace in AI Chat                      | Edit the AI Chat input cursor without clearing the whole draft                    |
| **Esc** in AI Chat while working                                               | Stop the in-flight AI Chat or Agent request                                      |
| Right-click a selection                                                        | Copy selection by default; configurable with `right-click-action`                 |
| **Ctrl+V**                                                                     | Paste text                                                                         |
| **Ctrl+Shift+V**                                                               | Paste clipboard image                                                              |
| **Alt** + arrow keys                                                           | Move focus to adjacent panel (spatial)                                             |
| **Ctrl+Shift+[**                                                               | Focus previous panel (cycle)                                                       |
| **Ctrl+Shift+]**                                                               | Focus next panel (cycle)                                                           |
| **Ctrl+Shift+Z**                                                               | Equalize split sizes                                                               |
| **Ctrl+Tab**                                                                   | Next tab                                                                           |
| **Ctrl+Shift+Tab**                                                             | Previous tab                                                                       |
| **Alt+1**-**9**                                                                | Switch to tab 1-9 (when that tab exists)                                           |
| **Ctrl+,**                                                                     | Open config file in the default editor                                             |

## SSH current directory for downloads and uploads

Phantty can download a relative file path from an SSH terminal output, and upload
dragged files into the interactive SSH shell's current directory, only when the
remote shell reports its current directory with OSC 7. This is the same terminal
convention used by Ghostty shell integration.

If OSC 7 is missing, helper `ssh.exe` / `scp.exe` commands start a fresh SSH
session and usually see the login directory, not the directory you `cd`'d to in
the interactive shell. In that case Phantty shows `SSH cwd unknown; click for
setup` instead of guessing `~/file`.

Add one of these snippets to the remote shell startup file, then start a new
Phantty SSH session.

For Bash, add this to `~/.bashrc`:

```bash
__phantty_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$PWD"
}
PROMPT_COMMAND="__phantty_report_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

For Zsh, add this to `~/.zshrc`:

```zsh
__phantty_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOST:-localhost}" "$PWD"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd __phantty_report_cwd
add-zsh-hook precmd __phantty_report_cwd
```

For Fish, add this to `~/.config/fish/config.fish`:

```fish
function __phantty_report_cwd --on-variable PWD
    printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url $PWD)
end
__phantty_report_cwd
```

## Credits

- Original project: [arya-s/phantty](https://github.com/arya-s/phantty) - the
Zig + libghostty-vt foundation and the Windows terminal core.
- Terminal emulation: [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
via `libghostty-vt`.
- Image decoding: [stb_image](https://github.com/nothings/stb) (vendored
through the ghostty dependency).

## License

MIT
