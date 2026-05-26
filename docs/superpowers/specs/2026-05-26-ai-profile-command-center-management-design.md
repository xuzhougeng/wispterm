# AI Profile Management in Command Center + Default Profile in Settings

Date: 2026-05-26
Status: Approved (design)

## Problem

Phantty supports up to 16 saved AI Chat profiles (`AI_PROFILE_MAX = 16` in
`src/renderer/overlays.zig`), stored in the `ai_profiles` config file as
tab-separated, hex-encoded rows. Each profile holds nine fields: `name`,
`base_url`, `api_key`, `model`, `system_prompt`, `thinking`,
`reasoning_effort`, `stream`, `agent`.

A complete multi-profile management overlay (`openAiList`, with New / Edit /
Delete actions and a profile picker) exists in the code but is **orphaned**.
Commit `e192e42` ("Streamline AI agent session launch") repointed the session
launcher's AI row from `openAiList()` to `openDefaultAiSession()`, leaving
`openAiList` reachable only by recursion from within itself. As a result the
current wired UI can only:

- Create the *first* profile (when zero exist), and
- Edit *profile index 0* via Settings.

There is no UI path to add a second profile, edit/delete non-zero profiles, or
choose which profile is the default. Everywhere a "default" profile is used,
the code hardcodes index `0` (startup auto-open, remote auto-open, the
"New Agent" command).

## Goal

1. Surface AI profile management in the Command Center (Ctrl+Shift+P), matching
   the flat command style used by the WeChat entries: each saved profile is a
   launchable row (quick switch), plus a single "Manage AI Profiles" command
   that opens the revived New / Edit / Delete overlay.
2. Let Settings choose the default AI profile (used by startup auto-open,
   remote auto-open, and "New Agent") and quickly switch among saved profiles.

## Decisions (locked during brainstorming)

- **Command Center layout**: per-profile launch rows + one "Manage AI Profiles"
  entry that opens the existing `openAiList` overlay for create/edit/delete.
- **Launch mode**: launching a profile row respects that profile's own stored
  `agent` field (`agent` profiles open as agents, `chat` profiles as chat).
- **Default storage**: a config key `ai-default-profile` holding the profile
  *name*. Falls back to the first saved profile when empty, unset, or unmatched.
  The `ai_profiles` file order stays stable.
- **Settings switch UX**: a "Default AI" row showing the current default name;
  click/Enter cycles to the next saved profile and writes `ai-default-profile`
  (mirrors the existing `cycle_theme` / `cycle_shell` rows).
- **Settings scope**: Settings handles default selection only. All
  create/edit/delete moves to the Command Center "Manage AI Profiles" overlay.
- **Palette visibility**: profile launch rows surface only when the palette
  filter is non-empty and matches (consistent with how SSH profiles and themes
  already behave). "Manage AI Profiles" is a static, always-listed command.

## Design

### 1. Default profile resolution (config)

- Add config field `@"ai-default-profile": []const u8 = ""` to the `Config`
  struct in `src/config.zig`, plus a parse branch in the key/value applier
  (alongside the other string keys). The value is the profile `name`.
- Add a pure, unit-testable helper in `src/command_center_state.zig`:

  ```zig
  pub fn resolveDefaultIndex(names: []const []const u8, default_name: []const u8) usize
  ```

  Returns the index of the first `names[i]` equal to `default_name`; returns `0`
  when `default_name` is empty or no name matches (and `0` when `names` is empty,
  callers must guard the empty-profile case separately).
- Add `defaultAiProfileIndex()` in `src/renderer/overlays.zig`: calls
  `loadAiProfiles()`, builds the slice of profile names, reads the current
  config value, and returns `resolveDefaultIndex(...)`.
- Replace the hardcoded `0` with `defaultAiProfileIndex()` at these call sites
  in `overlays.zig`:
  - `openDefaultAiSession` → `connectAiProfile(defaultAiProfileIndex())`
  - `openDefaultAgentSessionFromCommandCenter` →
    `connectAiProfileWithAgentOverride(defaultAiProfileIndex(), "true")`
  - `openDefaultAgentSessionForStartup` →
    `spawnAiProfileWithAgentOverride(defaultAiProfileIndex(), "true")`
  - `openDefaultAgentSessionForRemote` →
    `spawnAiProfileWithAgentOverride(defaultAiProfileIndex(), "true")`

  (The agent-mode override behavior of these four sites is unchanged; only the
  index changes.)

### 2. Command Center (Ctrl+Shift+P)

- Extend the palette item union in `overlays.zig`:

  ```zig
  const PaletteItem = union(enum) {
      command: usize,
      ssh_profile: usize,
      ai_profile: usize,   // new
      theme: usize,
  };
  ```

- Add a static command entry to `command_entries` in
  `src/command_center_state.zig`, placed near "New Agent":

  ```zig
  .{ .title = "Manage AI Profiles",
     .detail = "Create, edit, or delete saved AI profiles",
     .shortcut = "", .action = .manage_ai_profiles },
  ```

  Add `manage_ai_profiles` to the `CommandAction` enum.

- In `executeCommand` (`overlays.zig`), handle
  `.manage_ai_profiles => openAiList()`. The palette is already closed by the
  caller (`commandPaletteExecuteSelected` / `commandPaletteExecuteAt` call
  `commandPaletteClose()` before `executePaletteItem`). Opening `openAiList()`
  sets `g_ai_list_visible = true`; because
  `command_center_state.State.sessionLauncherVisible()` returns true when
  `ai_list_visible` is set, the top-level input router dispatches keys to
  `sessionLauncherHandleKey` → `handleAiListKey`, and the overlay renders. No
  new plumbing required.

- In `rebuildPaletteScratch` (`overlays.zig`), after the SSH-profile loop and
  before/around the theme loop, inject AI profile launch rows when the filter is
  non-empty:

  ```zig
  loadAiProfiles();
  for (0..g_ai_profile_count) |idx| {
      if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
      const profile = &g_ai_profiles[idx];
      if (!command_palette_model.aiProfileLabelMatchesFilter(
          aiProfileField(profile, .name), filter)) continue;
      g_palette_scratch[g_palette_scratch_len] = .{ .ai_profile = idx };
      g_palette_scratch_len += 1;
  }
  ```

- Add the matcher to `src/command_palette_model.zig`:

  ```zig
  pub fn aiProfileLabelMatchesFilter(name: []const u8, filter: []const u8) bool
  ```

  Matches when `filter` is empty-guarded by the caller (only called with
  non-empty filter), and `containsIgnoreCase("ai: " ++ name, filter)` is true —
  i.e. typing `ai` lists all profiles, typing part of a name narrows. Add an
  `ai_profile` variant to the model's `ResultGroup` for ranking, ordered after
  `ssh_profile` (or adjacent — exact rank to be set so AI rows group sensibly;
  ranking only affects ordering, not correctness).

- Execute launch rows in `executePaletteItem`:

  ```zig
  .ai_profile => |idx| _ = spawnAiProfileWithAgentOverride(idx, null),
  ```

  `null` means the spawned tab uses the profile's own `agent` field.
  `spawnAiProfileWithAgentOverride` already calls `sessionLauncherClose()`
  internally; that is harmless here since the palette is already closed.

- **Rendering**: extend the palette row renderer to handle the `ai_profile`
  variant. Title = `AI: <name>`. Right-aligned tag = the profile's mode derived
  from its `agent` field (`agent` when truthy, else `chat`), with a `(default)`
  suffix on the profile whose name equals `ai-default-profile` (or the first
  profile when the key is empty). Follow the existing theme-row tag rendering as
  the template.

### 3. Manage overlay (revive `openAiList`)

The overlay's New / Edit / Delete flow and file persistence already work
(`runAiListRow`, `saveAiFormProfile`, `deleteAiProfile`, `saveAiProfiles`). It
becomes reachable again purely via the new command. Two additions:

- `(default)` marker in the manage-list row rendering, consistent with the
  palette rows.
- `deleteAiProfile`: if the deleted profile's name equals the current
  `ai-default-profile` config value, clear the key (write empty) so resolution
  falls back to the first remaining profile.

### 4. Settings page

- Repurpose the existing AI settings row in `overlays.zig`:
  - Add `cycle_default_ai_profile` to `SettingsAction`; remove
    `open_ai_settings`.
  - The row label is "Default AI"; its value shows the current default profile
    name (resolved via `defaultAiProfileIndex()` → profile name), or `(none)`
    when zero profiles exist.
  - Activating the row cycles to the next saved profile name and writes it to
    `ai-default-profile` via `Config.setConfigValue`. No-op when zero profiles
    exist.
- Remove the now-unused `openAiSettings` function and the `.settings`
  `AiFormMode` branch (the only consumer of the settings form mode). This
  simplifies `openAiFormWithMode`, `saveAiFormOnly`, `cancelAiFormOrLauncher`,
  and `runAiFormFocusAction` to a single form mode (session setup). This is the
  one refactor included beyond rewiring, and it is in scope because the Settings
  AI behavior is changing.

### 5. Tests

Per this host's compile-only constraint for the GUI modules, logic that needs
runtime assertions lives in pure modules runnable with `zig test`:

- `src/command_palette_model.zig`:
  - `aiProfileLabelMatchesFilter("DeepSeek", "ai")` is true.
  - `aiProfileLabelMatchesFilter("DeepSeek", "deep")` is true (case-insensitive).
  - `aiProfileLabelMatchesFilter("DeepSeek", "gpt")` is false.
- `src/command_center_state.zig`:
  - "Manage AI Profiles" maps to `CommandAction.manage_ai_profiles`
    (via the existing `findCommandAction` test helper).
  - `resolveDefaultIndex(&.{"a","b","c"}, "b") == 1`.
  - `resolveDefaultIndex(&.{"a","b"}, "") == 0` (empty default).
  - `resolveDefaultIndex(&.{"a","b"}, "missing") == 0` (no match → first).
- `src/config.zig`:
  - Applying `ai-default-profile = GPT-4o` sets the field to `"GPT-4o"`.

GUI wiring in `overlays.zig` (palette injection, rendering, settings row,
overlay revival) is verified by compilation; runtime behavior is confirmed
manually.

## Affected files

- `src/config.zig` — new `ai-default-profile` field + parse branch + test.
- `src/command_center_state.zig` — `manage_ai_profiles` action + command entry;
  `resolveDefaultIndex` helper + tests.
- `src/command_palette_model.zig` — `aiProfileLabelMatchesFilter` + `ResultGroup`
  variant + tests.
- `src/renderer/overlays.zig` — `PaletteItem.ai_profile`, palette injection &
  rendering, `manage_ai_profiles` handler, `defaultAiProfileIndex`, four default
  call-site swaps, `deleteAiProfile` default-clear, Settings row repurpose,
  removal of `open_ai_settings` / `openAiSettings` / `.settings` form mode.

## Out of scope (YAGNI)

- Drag-reorder, import/export, or per-profile keybindings.
- Always-visible (unfiltered) profile rows in the palette — they surface only
  when filtered, consistent with SSH profiles and themes.
- Any change to the profile field set or the `ai_profiles` file format.

## Risks / notes

- `COMMAND_PALETTE_MAX_VISIBLE_ROWS = 14` caps total visible rows; AI profile
  rows share this budget with commands, SSH profiles, and themes. With <=16
  profiles and name-filtering, this is acceptable and matches existing behavior.
- Removing the `.settings` form mode touches several small functions; the change
  is mechanical (collapsing a two-variant enum to one path) but should be done
  carefully to avoid leaving dangling references.
