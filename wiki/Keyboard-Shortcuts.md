# Keyboard Shortcuts

*English · [中文](Keyboard-Shortcuts-zh)*

> The default app-level shortcuts, how to remap them, and the full action list.

## How keybinds work

WispTerm uses Ghostty's `keybind = trigger=action` style. Add repeated
`keybind = ...` lines to the [[config file|Configuration]]:

```text
keybind = ctrl+shift+p=toggle_command_palette
keybind = ctrl+shift+t=new_session
keybind = global:ctrl+backquote=toggle_quake
```

- **Trigger syntax:** `[global:]modifier+key=action`.
- **`global:` prefix** registers a system-wide hotkey (Win32 hotkey on Windows,
  CGEventTap on macOS) — used by Quake mode so it works even when WispTerm is
  not focused.
- **Modifiers:** `ctrl`, `shift`, `alt`, and `win` (Windows) / `cmd` (macOS).
- **Common keys:** letters, digits, `f1`–`f24`, `backquote`, `comma`, `plus`,
  `minus`, `bracket_left`, `bracket_right`, `enter`, `tab`, `escape`, arrows.
- Put `keybind = clear` **before** your custom bindings to drop all defaults.

> **macOS:** the default app chords below migrate `Ctrl` → `Cmd` (e.g. the
> command palette is `Cmd+Shift+P`). Quake stays `Ctrl+backquote` on every
> platform, since `Cmd+backquote` is the macOS window cycler.

## Default shortcuts

| Shortcut (Windows/Linux) | Action | What it does |
| --- | --- | --- |
| `Ctrl+backquote` (global) | `toggle_quake` | Show/hide the Quake drop-down window |
| `Ctrl+Shift+P` | `toggle_command_palette` | Open the command center |
| `Ctrl+Shift+T` | `new_session` | Open the session launcher (shell / Copilot / Sessions) |
| `Ctrl+Shift+N` | `new_window` | Open a new window |
| `Ctrl+Shift++` | `split_right` | Split the focused panel to the right |
| `Ctrl+Shift+-` | `split_down` | Split the focused panel downward |
| `Ctrl+Shift+B` | `toggle_sidebar` | Toggle the sidebar |
| `Ctrl+Shift+A` | `toggle_ai_copilot` | Toggle the Copilot sidebar on a terminal |
| `Ctrl+Shift+Alt+E` | `toggle_file_explorer` | Toggle the File Explorer |
| `Ctrl+Shift+W` | `close_panel_or_tab` | Close the focused panel/tab |
| `Alt+Enter` | `toggle_maximize` | Maximize/restore the focused panel |
| `Ctrl++` (press without Shift) | `font_size_increase` | Increase font size |
| `Ctrl+-` | `font_size_decrease` | Decrease font size |
| `Ctrl+Shift+C` | `copy` | Copy the selection |
| `Ctrl+V` | `paste` | Paste |
| `Ctrl+Shift+V` | `paste_image` | Paste a clipboard image (into Copilot) |
| `Alt+←/→/↑/↓` | `focus_left/right/up/down` | Move focus between split panels |
| `Ctrl+Shift+[` / `Ctrl+Shift+]` | `focus_previous` / `focus_next` | Cycle panel focus |
| `Ctrl+Shift+Z` | `equalize_splits` | Reset splits to equal sizes |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | `next_tab` / `previous_tab` | Switch tabs |
| `Alt+1` … `Alt+9` | `switch_tab_1` … `switch_tab_9` | Jump to tab N |
| `Ctrl+1` … `Ctrl+9` | `focus_panel_1` … `focus_panel_9` | Focus split panel N |
| `Ctrl+,` | `open_config` | Open the config file in your editor |

## Mouse & gestures

Some actions are mouse-only and are not bound through `keybind`:

- **Rename a tab:** double-click the tab title, type a new name, then `Enter` to
  commit or `Escape` to cancel.
- **Swap two panels:** hold `Alt` and left-drag one panel onto another to trade
  their contents.
- **Preview / open a file path:** hold `Ctrl` (`Cmd` on macOS) and left-click a
  file path to preview it, or right-click it to open it in your default app
  (local terminals only). With a PDF preview focused, `PageUp` / `PageDown`
  turn pages. See [[File-Explorer]].
- **Resize panels:** drag the divider between two panels.
- **Reorder tabs:** drag a tab up or down in the sidebar (`Ctrl+Shift+B`).
- **New / close a tab:** click the `+` button to add one; click a tab's `×` or
  middle-click the tab to close it.

## Full action list

Every app-level action you can bind:

`toggle_quake`, `toggle_command_palette`, `new_window`, `new_session`,
`split_right`, `split_down`, `toggle_file_explorer`, `toggle_sidebar`, `toggle_ai_copilot`,
`close_panel_or_tab`, `toggle_maximize`, `font_size_increase`,
`font_size_decrease`, `copy`, `paste`, `paste_image`, `focus_left`,
`focus_right`, `focus_up`, `focus_down`, `focus_previous`, `focus_next`,
`equalize_splits`, `next_tab`, `previous_tab`, `switch_tab_1` … `switch_tab_9`,
`focus_panel_1` … `focus_panel_9`, `open_config`.

## Remapping examples

```text
keybind = clear                              # drop all defaults first
keybind = alt+f10=toggle_command_palette
keybind = ctrl+shift+t=new_session
keybind = global:ctrl+backquote=toggle_quake
```

## Overlay-local keys

Some keys are handled first by whatever overlay is focused — the command center,
the session launcher, and the Copilot input box each take their own navigation
and editing keys before the app-level bindings apply. Those modal keys are not
remappable through `keybind`.

---
*See also: [[Configuration]] · [[Tabs-Splits-Panels]]*
