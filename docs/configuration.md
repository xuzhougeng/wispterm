# Configuration

WispTerm uses a Ghostty-compatible config file format (`key = value` pairs). The
main config path is resolved in this order:

1. `--config <path>` or `--config-path <path>`
2. `wispterm.conf` next to the executable (portable profile, Windows only)
3. Platform config directory:
   - **Windows:** `%APPDATA%\wispterm\config`
   - **macOS:** `~/Library/Application Support/wispterm/config`
   - **Linux:** `$XDG_CONFIG_HOME/wispterm/config` (fallback: `~/.config/wispterm/config`)

Press the configured `open_config` shortcut (default `Ctrl+,`, `Cmd+,` on macOS) to open the
config file in your default editor, or run `wispterm --show-config-path` to
print the resolved path.

CLI flags override config file values (last wins). `config-file = extra.conf`
and `--config-file extra.conf` include additional config files; they do not
change the main config path.

## Example Config

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
background-image = C:\Users\me\Pictures\wallpaper.png   # Windows example; use /Users/me/Pictures/wallpaper.png on macOS
background-opacity = 0.85
background-image-mode = fill
config-file = extra.conf
auto-update-check = true
focus-follows-mouse = false
remote-enabled = false
remote-server-url = https://remote.example.com
remote-server-fingerprint = sha256:...
remote-device-name = Workstation
remote-session-key = Workstation
```

## Available Keys

| Key                         | Default    | Description                                                                                                                                                                                                             |
| --------------------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `font-family`               | *(none)*   | Font family name (falls back to embedded font if unset)                                                                                                                                                                 |
| `font-style`                | `regular`  | Font weight: `thin`, `extra-light`, `light`, `regular`, `medium`, `semi-bold`, `bold`, `extra-bold`, `black`                                                                                                            |
| `font-size`                 | `12`       | Font size in points                                                                                                                                                                                                     |
| `cursor-style`              | `block`    | Cursor shape: `block`, `bar`, `underline`, `block_hollow`                                                                                                                                                               |
| `cursor-style-blink`        | `true`     | Enable cursor blinking                                                                                                                                                                                                  |
| `theme`                     | *(none)*   | Theme name or absolute path (453 Ghostty themes built-in)                                                                                                                                                               |
| `custom-shader`             | *(none)*   | Path to a GLSL post-processing shader                                                                                                                                                                                   |
| `background-image`          | *(none)*   | Path to an image (PNG/JPG/BMP/GIF/TGA) rendered behind the terminal                                                                                                                                                     |
| `background-opacity`        | `1.0`      | Opacity of the theme tint over the wallpaper (0.0 = image only, 1.0 = image hidden)                                                                                                                                     |
| `background-image-mode`     | `fill`     | Image scaling: `fill`, `fit`, `center`, or `tile`                                                                                                                                                                       |
| `window-height`             | `0` (auto) | Initial height in cells (min: 4, 0 = auto 80x24)                                                                                                                                                                        |
| `window-width`              | `0` (auto) | Initial width in cells (min: 10, 0 = auto 80x24)                                                                                                                                                                        |
| `quake-mode`                | `false`    | Start as a Quake-style drop-down terminal. The `toggle_quake` keybind hides or shows the same window while preserving terminal state, and the Quake window's size and position are remembered across restarts.            |
| `keybind`                   | defaults   | Configure an app-level shortcut. Can be repeated. Syntax: `keybind = [global:]modifier+key=action`; use `keybind = clear` before custom bindings to remove all defaults.                                                 |
| `scrollback-limit`          | `10000000` | Scrollback buffer limit in bytes                                                                                                                                                                                        |
| `url-open-mode`             | `embedded` | Where web URLs open: `embedded` uses the right-side browser panel when available (Windows only), while `system-browser` always opens the system default browser. SSH loopback URLs keep local port forwards alive for either mode. |
| `restore-tabs-on-startup`   | `false`    | Persist tab/split layout to the platform config directory (`session.json`) on close and rebuild it on next launch. SSH passwords are never persisted; reconnects re-prompt. CLI overrides (`--cwd`) take precedence and skip restore. |
| `auto-update-check`         | `true`     | Check GitHub Releases after startup and show a clickable prompt when a newer version is available. Set to `false` to disable startup checks.                                                                             |
| `config-file`               | *(none)*   | Include another config file (prefix with `?` to make optional)                                                                                                                                                          |
| `remote-enabled`            | `false`    | Start the shared outbound RemoteClient for this WispTerm instance                                                                                                                                                        |
| `remote-server-url`         | *(none)*   | Cloudflare relay URL, for example `https://remote.example.com`                                                                                                                                                          |
| `remote-server-fingerprint` | *(none)*   | Expected relay fingerprint for server identity pinning                                                                                                                                                                  |
| `remote-device-name`        | *(none)*   | Friendly device name sent with the WispTerm WebSocket pairing                                                                                                                                                            |
| `remote-session-key`        | *(none)*   | Fixed remote session key base. The first local WispTerm instance uses it directly; later concurrently running instances use `_1`, `_2`, `_3`, and so on.                                                                  |
| `focus-follows-mouse`       | `false`    | Focus whichever split panel the mouse is over, without clicking.                                                                                                                                                        |
| `confirm-close-running-program` | `true` | Ask for confirmation before closing a panel or tab that is running a full-screen TUI (anything on the alternate screen, such as `vim` or `htop`).                                                                        |
| `right-click-action`        | *(none)*   | Right-click behavior in the terminal: `paste`, or `copy-or-paste` (copy when a selection exists, otherwise paste).                                                                                                      |
| `copy-on-select`            | `false`    | Copy the terminal selection to the clipboard automatically as soon as you select it.                                                                                                                                    |
| `ssh-legacy-algorithms`     | `false`    | Append compatibility options (`ssh-rsa`, old Diffie-Hellman KEX, CBC ciphers) for legacy SSH servers and bastions.                                                                                                      |

When `remote-enabled = true`, WispTerm creates one RemoteClient for the running
instance. All tabs and splits publish PTY output through that shared client, and
the generated session key is printed in the debug console and shown in the
in-window remote status pill. Click the remote status pill to copy the active
session key, or use `Copy Remote Key` from the command center.

By default the session key is random for every process. Set
`remote-session-key = mypass` to use predictable keys for multiple concurrent
local WispTerm instances: the first process gets `mypass`, the next gets
`mypass_1`, then `mypass_2`, `mypass_3`, and so on. This only chooses the relay
session key that the remote browser enters; it is separate from the web admin
login password configured on the relay server.

## Settings page

You do not have to edit the config file by hand. Open the command center
(`Ctrl+Shift+P`, `Cmd+Shift+P` on macOS) and run **Settings** to open an in-app
settings page that edits the most common options: font size, theme, cursor style
and blink, focus-follows-mouse, restore-tabs-on-startup, the default shell, the
default AI profile, WeChat direct control, and the interface language. The page
also has an **Open raw config** button for the advanced keys above, and changes
are written back to the same config file. Some options (such as language) take
effect after a restart.

The **Restore default settings** row resets the settings the page manages back
to their defaults after a confirmation dialog. It only clears the keys exposed on
the settings page; it leaves Quake mode, your saved AI profiles, and custom
`keybind` lines untouched.

## Keyboard Shortcuts

WispTerm follows Ghostty's `keybind = trigger=action` style for app-level
shortcuts. Prefix a binding with `global:` when the shortcut should be
registered system-wide (Win32 hotkey on Windows, CGEventTap on macOS); the
first global use case is Quake mode.

```text
keybind = alt+f10=toggle_command_palette
keybind = ctrl+shift+t=new_session
keybind = global:ctrl+backquote=toggle_quake
```

Supported modifiers are `ctrl`, `shift`, `alt`, and `win` (Windows) / `cmd` (macOS). Common key names
include letters, digits, `f1`-`f24`, `backquote`, `comma`, `plus`, `minus`,
`bracket_left`, `bracket_right`, `enter`, `tab`, `escape`, and arrow keys.

Current app-level actions include `toggle_command_palette`, `toggle_quake`,
`new_session`, `new_window`, `split_right`, `toggle_file_explorer`,
`toggle_sidebar`, `toggle_ai_copilot`, `close_panel_or_tab`, `toggle_maximize`,
`font_size_increase`, `font_size_decrease`, `copy`, `paste`, `paste_image`,
`focus_left`, `focus_right`, `focus_up`, `focus_down`, `focus_previous`,
`focus_next`, `equalize_splits`, `next_tab`, `previous_tab`, `switch_tab_1`
through `switch_tab_9`, `focus_panel_1` through `focus_panel_9`, and
`open_config`.
