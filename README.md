English | [简体中文](README.zh-CN.md)

# WispTerm

**WispTerm**, formerly Phantty, is a cross-platform terminal workspace for remote development and AI agent workflows. It is written in Zig and powered by [libghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation.

> [!NOTE]
> WispTerm ships for **Windows** and **macOS** (Apple Silicon and Intel). The
> **Linux** port is still in progress (see [TODO.md](TODO.md)).

## Features

- **Ghostty's terminal emulation** - uses libghostty-vt for VT parsing and terminal state
- **DirectWrite font discovery** - find system fonts by name, with per-glyph fallback for missing characters
- **FreeType rendering** - high-quality glyph rasterization with Ghostty-style font metrics
- **Sprite rendering** - box drawing, block elements, braille patterns, powerline symbols
- **Theme support** - Ghostty-compatible theme files, 450+ themes built in (default: Poimandres)
- **Background image and shaders** - wallpaper blending plus Ghostty-compatible GLSL post-processing
- **Splits and tabs** - vertical/horizontal splits, tab strip, focus-follows-mouse, equalize sizes
- **File Explorer and previews** - browse local, WSL, and SSH files; preview Markdown/text/tables/images without leaving the terminal
- **Embedded browser panel** - open web URLs in a side WebView2 panel or the default browser, with persistent SSH loopback port forwarding for profile sessions
- **AI Agent sessions** - launch OpenAI-compatible Agent tabs, configure profiles, restore history, and export full or clean Markdown transcripts
- **AI history browser** - browse local, WSL, and SSH Codex / Claude Code / Reasonix history and resume sessions from their original project directories
- **Kitty Graphics protocol** - display inline images and PDFs from remote shells via `imgcat.py` / `pdfcat.py`
- **Opt-in remote access** - share a session key over a Cloudflare-hosted relay (disabled by default)

## Documentation

- [Configuration](docs/configuration.md)
- [File Explorer and previews](docs/file-explorer.md)
- [AI Agent sessions](docs/ai-agent.md)
- [Media, background images, and inline remote images](docs/media.md)
- [Development, architecture, packaging, and releases](docs/development.md)
- [FAQ](docs/faq.md)

## Building

Windows (PowerShell):

```powershell
zig build                         # Debug build for development
zig build -Doptimize=ReleaseFast  # ReleaseFast build for distribution
Remove-Item -Recurse -Force .\zig-out, .\.zig-cache -ErrorAction SilentlyContinue
```

macOS (requires macOS 13+ and Zig 0.15.2):

```bash
zig build macos-app -Dtarget=aarch64-macos   # Apple Silicon .app bundle (use x86_64-macos on Intel)
open zig-out/bin/WispTerm.app                  # launch the built app
```

The `Makefile` may still exist as a convenience wrapper, but normal Windows
development should use PowerShell and direct `zig` commands.

For architecture, packaging, and release details, see [Development, architecture, packaging, and releases](docs/development.md).

## Usage

On Windows run `wispterm.exe`; on macOS run `WispTerm.app/Contents/MacOS/wispterm` (or launch `WispTerm.app` directly — passing CLI flags requires the binary path).

```bash
wispterm [options]

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
  --quake-mode <bool>          Enable Quake-style drop-down mode (default: true)
  --keybind <binding>          Configure a shortcut, e.g. global:ctrl+backquote=toggle_quake
  --config <path>              Use this file as the main config
  --config-path <path>         Alias for --config
  --config-file <path>         Include another config file (prefix ? for optional)
  --version, -v                Print the WispTerm version and exit
  --show-config-path           Print the resolved main config path
  --list-fonts                 List available system fonts
  --list-themes                List available themes
  --test-font-discovery        Test DirectWrite font discovery
  --help, -h                   Show help
```

Configuration file details are in [Configuration](docs/configuration.md).

## Keyboard shortcuts

Default app-level chords are defined in [`src/keybind.zig`](src/keybind.zig) and can be remapped with repeated `keybind = ...` lines in the config file. Some modal/editor-local keys are still handled by the focused overlay first (command center navigation, session launcher editing, AI Chat input, and similar).

Example remaps:

```text
keybind = alt+f10=toggle_command_palette
keybind = global:ctrl+backquote=toggle_quake
```

Use `keybind = clear` before custom bindings if you want to remove all defaults and rebuild the table from scratch. To confirm the running desktop version, open the command center (`Ctrl+Shift+P` on Windows, `Cmd+Shift+P` on macOS), type `version`, and press Enter.

> **macOS modifier mapping:** most shortcuts use **Cmd** in place of Ctrl and **Opt** in place of Alt. Two exceptions keep Ctrl to avoid colliding with system shortcuts: **Ctrl+`** (Quake — `Cmd+`` is the system window cycler) and **Ctrl+Tab** / **Ctrl+Shift+Tab** (tab switching — `Cmd+Tab` is the system app switcher).

| Action | Windows / Linux | macOS |
| ------ | --------------- | ----- |
| Show/hide Quake drop-down | **Ctrl+`** | **Ctrl+`** |
| Open command center | **Ctrl+Shift+P** | **Cmd+Shift+P** |
| New session (session launcher) | **Ctrl+Shift+T** | **Cmd+Shift+T** |
| New window | **Ctrl+Shift+N** | **Cmd+Shift+N** |
| Toggle tab sidebar | **Ctrl+Shift+B** | **Cmd+Shift+B** |
| Split to the right | **Ctrl+Shift+O** | **Cmd+Shift+O** |
| Toggle file explorer sidebar | **Ctrl+Shift+Alt+E** | **Cmd+Shift+Opt+E** |
| Toggle AI Copilot sidebar (current terminal) | **Ctrl+Shift+A** | **Cmd+Shift+A** |
| Preview files (Ctrl/Cmd-click in terminal, or double-click in File Explorer) | Ctrl-click | Cmd-click |
| Download SSH remote file | Ctrl+Shift-click path in SSH output | Cmd+Shift-click path in SSH output |
| Close focused panel, tab, or window | **Ctrl+Shift+W** | **Cmd+Shift+W** |
| Maximize or restore window | **Alt+Enter** | **Opt+Enter** |
| Increase / decrease font size | **Ctrl++** / **Ctrl+-** | **Cmd++** / **Cmd+-** |
| Copy terminal selection or AI Chat selection/transcript | **Ctrl+Shift+C** | **Cmd+Shift+C** |
| Select from the last terminal click anchor | Shift-click terminal text | Shift-click terminal text |
| Select part of an AI answer | Drag AI answer text | Drag AI answer text |
| Select and copy part of an AI answer | Shift-drag AI answer text | Shift-drag AI answer text |
| Select AI Chat input; select transcript when input is empty | **Ctrl+A** in AI Chat | **Cmd+A** in AI Chat |
| Copy AI Chat selection or full transcript | **Ctrl+C** in AI Chat | **Cmd+C** in AI Chat |
| Delete the selected saved Agent session | **D** / **Delete** in Agent History | **D** / **Delete** in Agent History |
| Edit AI History filter | Type / Backspace in AI History | Type / Backspace in AI History |
| Move selected AI History session | Up / Down in AI History | Up / Down in AI History |
| Resume selected AI History session | Enter in AI History | Enter in AI History |
| Preview selected AI History transcript | Space in AI History | Space in AI History |
| Refresh local AI History scan | **R** in local AI History | **R** in local AI History |
| Edit AI Chat input cursor | Left/Right/Home/End/Delete/Backspace | Left/Right/Home/End/Delete/Backspace |
| Stop in-flight AI Chat or Agent request | **Esc** in AI Chat while working | **Esc** in AI Chat while working |
| Copy selection (right-click) | Right-click a selection | Right-click a selection |
| Paste text | **Ctrl+V** | **Cmd+V** |
| Paste clipboard image | **Ctrl+Shift+V** | **Cmd+Shift+V** |
| Move focus to adjacent panel | **Alt** + arrow keys | **Opt** + arrow keys |
| Focus panel 1–9 by number | **Ctrl+1**–**9** | **Cmd+1**–**9** |
| Focus previous panel (cycle) | **Ctrl+Shift+[** | **Cmd+Shift+[** |
| Focus next panel (cycle) | **Ctrl+Shift+]** | **Cmd+Shift+]** |
| Equalize split sizes | **Ctrl+Shift+Z** | **Cmd+Shift+Z** |
| Next tab | **Ctrl+Tab** | **Ctrl+Tab** |
| Previous tab | **Ctrl+Shift+Tab** | **Ctrl+Shift+Tab** |
| Switch to tab 1–9 | **Alt+1**–**9** | **Opt+1**–**9** |
| Open config file | **Ctrl+,** | **Cmd+,** |

## AI Chat Markdown export

In an active AI Chat or Agent tab, open the command center with `Ctrl+Shift+P`
and run:

- `Export AI Chat Markdown` to save the full transcript, including thinking,
  tool details, and usage metadata.
- `Export AI Chat Markdown Clean` to save a publishing-friendly Markdown file
  with only the user inputs and the final AI answer.

WispTerm opens a save dialog with a `.md` filename. After saving, the
saved path is copied to the clipboard.

## SSH current directory for downloads and uploads

WispTerm can download a relative file path from an SSH terminal output, and upload
dragged files into the interactive SSH shell's current directory, only when the
remote shell reports its current directory with OSC 7. This is the same terminal
convention used by Ghostty shell integration.

If OSC 7 is missing, helper `ssh.exe` / `scp.exe` commands start a fresh SSH
session and usually see the login directory, not the directory you `cd`'d to in
the interactive shell. In that case WispTerm shows `SSH cwd unknown; click for
setup` instead of guessing `~/file`.

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

## Credits

- Original project: [arya-s/phantty](https://github.com/arya-s/phantty) - the
Zig + libghostty-vt foundation and the Windows terminal core. WispTerm builds on
that base and layers additional features on top: an embedded WebView2 browser
panel, a file explorer with Markdown/text/table/image preview, AI Agent sessions
with Markdown export, an opt-in remote-access client, Kitty Graphics image
protocol support, and a configurable background image.
- Terminal emulation: [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
via `libghostty-vt`.
- Image decoding: [stb_image](https://github.com/nothings/stb) (vendored
through the ghostty dependency).

## License

MIT

## Star History

<a href="https://star-history.com/#xuzhougeng/wispterm&Date">
  <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=xuzhougeng/wispterm&type=Date" />
</a>
