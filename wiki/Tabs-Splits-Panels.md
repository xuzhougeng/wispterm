# Tabs, Splits & Panels

*English · [中文](Tabs-Splits-Panels-zh)*

> Arrange multiple terminals with tabs and splits, move focus between panels, and use Quake drop-down mode.

> On macOS, the app chords below use **`Cmd`** in place of `Ctrl` (Quake stays
> `Ctrl+backquote` on every platform). See [[Keyboard-Shortcuts]] to remap any of them.

## Tabs vs splits

A **tab** is a separate session in the tab strip. A **split** divides one tab
into multiple terminal panels that share the same tab. Use tabs to keep
unrelated work apart, and splits to see related terminals side by side.

## Creating & focusing splits

- **Split the current panel:** `Ctrl+Shift+O` (`split_right`).
- **Move focus between panels:** `Alt+←` / `Alt+→` / `Alt+↑` / `Alt+↓`.
- **Cycle focus:** `Ctrl+Shift+[` (previous) and `Ctrl+Shift+]` (next).
- **Equalize sizes:** `Ctrl+Shift+Z` (`equalize_splits`) resets all splits in
  the tab to equal proportions.
- **Maximize the focused panel:** `Alt+Enter` (`toggle_maximize`) zooms it to
  fill the tab; press again to restore.

Drag a split's divider to resize the panels on either side.

## Focus a panel by number

Press `Ctrl+1` … `Ctrl+9` to jump straight to the **Nth split panel** in the
active tab. Panels are numbered by screen position — row-major, top-left to
bottom-right. If there is no panel at that index, the key falls through to the
terminal, so apps that use `Ctrl+<digit>` keep working when you are not split.

## Swap panels

Hold **`Alt`** and **left-drag** one panel onto another to swap their contents.
The layout topology stays the same — only the two panels' terminals trade
places. The drop target is highlighted with an accent border while you drag.

## Focus follows mouse

Set `focus-follows-mouse = true` in the config to focus whichever panel the
mouse is over, without clicking. It is **off** by default.

## Quake drop-down mode

Quake mode turns WispTerm into a drop-down terminal toggled with a global
hotkey. The `toggle_quake` binding (`Ctrl+backquote`, the `` ` `` key, registered
system-wide) hides or shows the same window while preserving terminal state, and WispTerm remembers
the Quake window's size and position across restarts.

Quake mode is **off by default**. Enable it with `quake-mode = true` in the
config, or `--quake-mode true` on the command line.

## Closing tabs & splits

`Ctrl+Shift+W` (`close_panel_or_tab`) closes the focused panel, or the tab when
it is the last panel. When a panel is running a full-screen TUI (anything that
switched to the alternate screen, like `vim` or `htop`), WispTerm asks for
confirmation first. Turn this off with `confirm-close-running-program = false`
(it is on by default).

---
*See also: [[Keyboard-Shortcuts]] · [[Getting-Started]]*
