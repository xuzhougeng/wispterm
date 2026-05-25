# Command Palette SSH Quick Jump Design

## Goal

Make saved SSH servers directly reachable from the `Ctrl+Shift+P` command center. A user should be able to open the command center, type a saved SSH server name, and press Enter to open a new SSH tab for that profile.

## Ghostty Reference

Ghostty's command palette combines static command entries with dynamic jump entries. In `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift`, `commandOptions` appends update commands, terminal commands, and dynamic `jumpOptions` before passing them to the searchable palette view. In `macos/Sources/Features/Command Palette/CommandPalette.swift`, options filter by title and subtitle and run their action directly on submit.

Phantty should follow that shape: keep the command center as one searchable action list, add SSH profiles as dynamic action entries, and execute the selected profile directly rather than adding a second picker step.

## Behavior

The command center continues to open with the existing `Ctrl+Shift+P` binding. When the filter is empty, it shows the existing command entries only, preserving the current default list.

When the filter is non-empty, the result set is:

1. Command title matches.
2. Command detail or shortcut matches.
3. Saved SSH profile name matches.
4. Built-in theme name matches.

SSH matching is case-insensitive and checks only the saved server name. It does not match host/IP, user, password, or port. This keeps the feature focused on "type the saved server name" and avoids noisy or surprising matches.

An SSH result renders as `SSH: <server name>`. The right-side detail shows the existing safe connection target, such as `alice@example.com:2222`, using the same profile fields already shown in the SSH launcher. Passwords are never rendered or matched.

Pressing Enter or clicking an SSH result closes the command center and opens a new SSH tab using the existing profile connection path. If the profile fails validation or the tab cannot be created, the command center still closes, matching current command/theme execution behavior.

## Architecture

The implementation stays in `src/renderer/overlays.zig`, where the command center, theme search, SSH profile storage, and SSH connection actions already live.

`PaletteItem` gains an SSH profile case that stores a profile index. `rebuildPaletteScratch()` loads saved SSH profiles only when the command-center filter is non-empty, then appends matching profile entries after command matches and before theme matches. Existing SSH profile storage remains unchanged.

Execution reuses the existing `connectSshProfile()`/`connectSshProfileReturningSurface()` path, so password scheduling, OpenSSH command construction, legacy algorithm flags, and SSH session metadata stay centralized.

Rendering reuses the existing SSH profile field helpers and target formatting pattern from the session launcher. The command center row layout remains unchanged.

## Testing

Add focused Zig tests in `src/renderer/overlays.zig` for:

- SSH profiles do not appear when the command-center filter is empty.
- A non-empty filter matches saved SSH profile names case-insensitively.
- Host/IP and user values do not match when the server name does not match.
- SSH profile results are ordered after command matches and before theme matches.

Run the focused test target after each red/green step. The current branch baseline has known pre-existing `zig build test` failures in `platform.window_backend` and `updater_core`; final verification should report those separately unless they are fixed in this branch.

## Out Of Scope

This does not change keyboard bindings, so `README.md` shortcut documentation does not need an update.

This does not change SSH profile file format, SSH/SCP helper behavior, OpenSSH options, or the session launcher SSH list behavior.

This does not add host/IP/user matching. The user explicitly chose server-name-only matching.
