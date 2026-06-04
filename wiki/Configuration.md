# Configuration

*English · [中文](Configuration-zh)*

> Where the config file lives, how CLI flags interact with it, and the full key reference.

WispTerm uses a Ghostty-compatible config format — plain `key = value` pairs.

## Where the config lives

The main config path is resolved in this order:

1. `--config <path>` or `--config-path <path>`
2. `wispterm.conf` next to the executable (portable profile, Windows only)
3. Platform config directory:
   - **Windows:** `%APPDATA%\wispterm\config`
   - **macOS:** `~/Library/Application Support/wispterm/config`
   - **Linux:** `$XDG_CONFIG_HOME/wispterm/config` (fallback `~/.config/wispterm/config`)

Press `open_config` (`Ctrl+,`, `Cmd+,` on macOS) to open the config in your
editor, or run `wispterm --show-config-path` to print the resolved path.

## CLI vs file

CLI flags override config-file values (last wins). `config-file = extra.conf`
and `--config-file extra.conf` include additional config files (prefix the path
with `?` to make it optional); they do **not** change the main config path.

## Example config

```text
font-family = Cascadia Code
font-style = regular
font-size = 14
cursor-style = bar
cursor-style-blink = true
theme = Poimandres
window-height = 32
window-width = 120
quake-mode = false
keybind = global:ctrl+backquote=toggle_quake
keybind = ctrl+shift+p=toggle_command_palette
scrollback-limit = 10000000
url-open-mode = embedded
custom-shader = path/to/shader.glsl
background-image = C:\Users\me\Pictures\wallpaper.png   # Windows; use /Users/me/Pictures/wallpaper.png on macOS
background-opacity = 0.85
background-image-mode = fill
config-file = extra.conf
auto-update-check = true
focus-follows-mouse = false
remote-enabled = false
```

## Key reference

| Key | Default | Description |
| --- | --- | --- |
| `font-family` | *(none)* | Font family name (falls back to the embedded font if unset) |
| `font-style` | `regular` | Font weight: `thin`, `extra-light`, `light`, `regular`, `medium`, `semi-bold`, `bold`, `extra-bold`, `black` |
| `font-size` | `12` | Font size in points |
| `cursor-style` | `block` | Cursor shape: `block`, `bar`, `underline`, `block_hollow` |
| `cursor-style-blink` | `true` | Enable cursor blinking |
| `theme` | *(none)* | Theme name or absolute path (453 Ghostty themes built in) |
| `custom-shader` | *(none)* | Path to a GLSL post-processing shader |
| `background-image` | *(none)* | Path to an image (PNG/JPG/BMP/GIF/TGA) rendered behind the terminal |
| `background-opacity` | `1.0` | Opacity of the theme tint over the wallpaper (0.0 = image only, 1.0 = image hidden) |
| `background-image-mode` | `fill` | Image scaling: `fill`, `fit`, `center`, `tile` |
| `window-height` | `0` (auto) | Initial height in cells (min 4, 0 = auto 80×24) |
| `window-width` | `0` (auto) | Initial width in cells (min 10, 0 = auto 80×24) |
| `quake-mode` | `false` | Start as a Quake-style drop-down terminal; `toggle_quake` hides/shows it while preserving state |
| `keybind` | defaults | Configure an app-level shortcut (repeatable). Syntax `[global:]modifier+key=action`; `keybind = clear` removes all defaults |
| `scrollback-limit` | `10000000` | Scrollback buffer limit in bytes |
| `focus-follows-mouse` | `false` | Focus the panel under the mouse without clicking |
| `url-open-mode` | `embedded` | Where web URLs open: `embedded` uses the right-side browser panel when available (Windows only); `system-browser` always uses the system default browser. SSH loopback URLs keep local port forwards alive either way |
| `restore-tabs-on-startup` | `false` | Persist tab/split layout (`session.json`) on close and rebuild on next launch. SSH passwords are never persisted; reconnects re-prompt. `--cwd` overrides skip restore |
| `auto-update-check` | `true` | Check GitHub Releases after startup and prompt when a newer version exists |
| `config-file` | *(none)* | Include another config file (prefix `?` to make optional) |
| `remote-enabled` | `false` | Start the shared outbound RemoteClient for this instance — see [[Remote-Access]] |
| `remote-server-url` | *(none)* | Cloudflare relay URL, e.g. `https://remote.example.com` |
| `remote-server-fingerprint` | *(none)* | Expected relay fingerprint for server identity pinning |
| `remote-device-name` | *(none)* | Friendly device name sent with the WispTerm pairing |
| `remote-session-key` | *(none)* | Fixed remote session key base; later concurrent instances use `_1`, `_2`, … |
| `ssh-legacy-algorithms` | `false` | Append compatibility options (ssh-rsa, old KEX, CBC) for legacy SSH servers — see [[SSH-Remote-Development]] |
| `copy-on-select` | `false` | Copy the terminal selection automatically — see [[AI-Copilot]] |
| `right-click-action` | *(none)* | `paste`, or `copy-or-paste` (copy when a selection exists, else paste) |
| `confirm-close-running-program` | `true` | Confirm before closing a panel/tab running a full-screen TUI |

## Hot reload

Many changes apply without restarting: save the config (or hot-reload via
`Ctrl+,`) and WispTerm re-reads it. Clearing a value (e.g. `background-image`)
removes the effect.

---
*See also: [[Themes-Appearance]] · [[Keyboard-Shortcuts]] · [[Remote-Access]]*
