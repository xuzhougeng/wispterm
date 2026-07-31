# Tabs, Splits, and Panels

WispTerm arranges terminals as **tabs** (separate sessions in the tab strip) and
**splits** (one tab divided into several side-by-side **panels** that share the
tab). Use tabs to keep unrelated work apart and splits to watch related
terminals together.

> On macOS the app shortcuts below use `Cmd` in place of `Ctrl`, except Quake
> mode, which stays `Ctrl+backquote` on every platform. Any shortcut can be
> remapped with `keybind` lines in the config (see configuration).

## Tabs

- **Open a new tab:** click the `+` button at the end of the tab strip, or press
  `Ctrl+Shift+T` (`new_session`) to open the session launcher and pick a shell,
  Copilot, or a saved SSH profile.
- **Switch tabs:** `Ctrl+Tab` / `Ctrl+Shift+Tab` move to the next / previous tab,
  and `Alt+1` … `Alt+9` (`switch_tab_1` … `switch_tab_9`) jump straight to tab N.
- **Rename a tab:** double-click the tab's title, type a new name, then press
  `Enter` to commit or `Escape` to cancel. The whole title is selected when
  renaming begins, so typing replaces it. Renaming works for both terminal tabs
  and Copilot tabs; the custom name overrides the automatic title.
- **Reorder tabs:** open the tab sidebar with `Ctrl+Shift+B` (`toggle_sidebar`)
  and drag a tab up or down to a new position.
- **Close a tab:** click the `×` button on the tab, middle-click the tab, or
  press `Ctrl+Shift+W` (`Cmd+W` on macOS; `close_panel_or_tab`). When the tab (or focused panel)
  is running a full-screen TUI such as `vim` or `htop`, WispTerm asks for
  confirmation first; turn that off with `confirm-close-running-program = false`.

## Splitting a tab into panels

- **Split the focused panel:** `Ctrl+Shift++` splits to the right (`split_right`)
  and `Ctrl+Shift+-` splits downward (`split_down`), mirroring Windows Terminal.
  The command center also offers `Split Right`, `Split Down`, `Split Left`, and
  `Split Up`.
- **Move focus between panels:** `Alt+←` / `Alt+→` / `Alt+↑` / `Alt+↓`
  (`focus_left` / `focus_right` / `focus_up` / `focus_down`).
- **Cycle focus:** `Ctrl+Shift+[` (`focus_previous`) and `Ctrl+Shift+]`
  (`focus_next`).
- **Focus a panel by number:** `Ctrl+1` … `Ctrl+9` (`focus_panel_1` …
  `focus_panel_9`) jump to the Nth panel, numbered by screen position (row-major,
  top-left to bottom-right). When there is no panel at that index the key falls
  through to the terminal, so apps that use `Ctrl+<digit>` keep working when you
  are not split.
- **Equalize panel sizes:** `Ctrl+Shift+Z` (`equalize_splits`) resets all splits
  in the tab to equal proportions.
- **Maximize the focused panel:** `Alt+Enter` (`toggle_maximize`) zooms it to fill
  the tab; press again to restore.

## Mouse gestures

- **Rename a tab:** double-click its title (see Tabs above).
- **Swap two panels:** hold `Alt` and left-drag one panel onto another to swap
  their contents. The layout stays the same — only the two terminals trade
  places — and the drop target is highlighted while you drag.
- **Resize panels:** drag the divider between two panels.
- **Reorder tabs:** drag a tab in the sidebar (see Tabs above).
- **Focus follows mouse:** set `focus-follows-mouse = true` to focus whichever
  panel the mouse is over without clicking. It is off by default.

## Quake drop-down mode

Quake mode turns WispTerm into a drop-down terminal toggled by a global hotkey.
The `toggle_quake` binding (`Ctrl+backquote`, registered system-wide) hides or
shows the same window while preserving terminal state, and WispTerm remembers the
Quake window's size and position across restarts. Quake mode is off by default;
enable it with `quake-mode = true` in the config or `--quake-mode true` on the
command line.
