# Extensible Slash Commands + Conversation Lifecycle Commands — Design

**Date:** 2026-05-29
**Status:** Approved (design), pending implementation plan
**Issue:** xuzhougeng/wispterm#91 (需求1 + 需求2)

## Goal

Two related additions to the AI Chat panel, sharing one slash-command dispatch path:

1. **需求1 — User-extensible slash commands.** Today the panel's slash commands are a
   compile-time array; users cannot add their own. Add a `commands/` directory whose
   Markdown files register as slash commands at runtime — no recompile.
2. **需求2 — Conversation lifecycle commands.** Add built-in `/clear`, `/resume`,
   `/permission`, `/export`, each wired to capability that already exists in the
   codebase (only the slash-command entry point is missing).

Out of scope (YAGNI):
- Custom command → arbitrary shell script execution (deferred to a later phase; the
  capability model is designed to accommodate it but v1 ships action + prompt-template
  only).
- A full plugin system / config-key (`[custom_commands]`) form. Config is Ghostty-style
  `key = value`, not TOML, so the issue's `[custom_commands]` table syntax does not
  apply; the `commands/` directory is the chosen form (mirrors `skills/` and Claude
  Code's own slash commands).

## Current state (anchors)

- `src/ai_chat_composer.zig:6` — `SlashCommand` enum (fixed): `skills, commands, reload_skills, update_skills, unknown`.
- `src/ai_chat_composer.zig:29` — `slash_command_entries` compile-time array.
- `src/ai_chat_composer.zig:64` — `parseSlashCommand(input) ?SlashCommand` (pure).
- `src/ai_chat_composer.zig:105/114` — suggestion count / at-index (pure; take `input`+`cursor`).
- `src/ai_chat.zig:1370` — dispatch site: `if (parseSlashCommand(prompt_raw)) |command| { ... }`.
- `src/ai_chat.zig:363` — `slashCommandOutput(allocator, command)` produces transcript text.
- `src/ai_chat.zig:962` — `Session.allocMarkdownExport(allocator, mode)` (full/clean) — exists.
- `src/AppWindow.zig:581` — `exportActiveAiChatMarkdown(mode)` — renders → choose path → write file → copy path → toast. **Reuse for `/export`.**
- `src/ai_chat.zig:97` — `AgentPermission { confirm, full }` + `parse`/`name`; `configureAgent` / `currentAgentSettings` at `:326/:336`. **Reuse for `/permission`.**
- `src/ai_chat.zig:739` — `Session.initFromHistoryRecord` exists; an "agent history picker" UI already exists (`command_center_state.zig`). **Reuse for `/resume`.**
- `src/ai_chat.zig:317` — `g_skill_update_trigger` + `setSkillUpdateTrigger(cb)`: the established "set once at startup" cross-layer callback pattern. **Mirror for `/resume` and `/export`.**
- `src/skill_registry.zig` — directory-scan pattern (`openSkillsDir`, iterate dirs, parse `SKILL.md`). **Mirror for `command_registry.zig`.**

## Command model

A command is `{ name, description, kind }`:

- `kind = .builtin(action)` — `action` is an enum of built-in lifecycle actions.
- `kind = .prompt_template(body)` — expands to a model request using `body` as the prompt.
- (Phase 2, not in v1: `kind = .shell(script)` behind the permission model.)

Built-in action enum (replaces/extends today's `SlashCommand`):
`skills, commands, reload_skills, reload_commands, update_skills, clear_context,
restore_session, set_permission, export_markdown`.

The four 需求2 commands map to: `clear_context`, `restore_session`, `set_permission`,
`export_markdown`. Custom commands either reference one of these action names (via
frontmatter `action:`) or omit it (→ prompt template).

## A1. Slash registry: compile-time array → runtime-extensible

Keep `ai_chat_composer.zig` pure. Generalize the pure functions to take the command
list as a parameter, exactly as the skill functions already take `skills: []const SkillMeta`:

- `parseSlashCommand(input, commands) ?ParsedCommand` where `ParsedCommand` is either a
  built-in action or an index into `commands` (custom).
- `slashCommandSuggestionCountForInput(input, cursor, commands)` and
  `…SuggestionAtForInput(…, commands)` consult the merged list.
- The static built-in seed array stays in the composer module; the Session owns the
  **merged** list (built-ins ++ loaded custom commands) and passes it in.

Suggestion entries gain enough info to render description; dispatch resolves a custom
command to its `kind`.

## A2. `commands/` directory loading — new module `src/command_registry.zig`

Peer to `skill_registry.zig`, single responsibility, independently testable, pure
parsing (no networking).

- Roots: same resolution as skills (mirror `appendSkillRootPath`), but `commands/`
  (e.g. `<config>/commands`, plugin command dirs).
- Each `*.md` = one command. Frontmatter:
  - `name` (required) — the slash trigger (stored/used as `/name`).
  - `description` (optional) — shown in suggestions.
  - `action` (optional) — one of the built-in action names above. If present, the
    command invokes that action. If absent, the file **body** is the prompt template.
- Output: `[]CustomCommand` with owned strings; Session merges with built-ins.
- Validation: unknown `action` value → command skipped with a logged warning (do not
  crash); duplicate name → built-ins win, first-loaded custom wins over later (logged).
- Loaded at session/app startup; rescanned by `/reload-commands` (see A3).

## A3. 需求2 built-in commands

- **`/clear`** → new `Session.clearContext`: clears `messages` / transcript and resets
  scroll, **keeps** tab, `base_url`/`api_key`/`model`/`protocol`/`system_prompt`. Emits
  a short confirmation line.
- **`/export [full|clean]`** → fires the export callback → `AppWindow.exportActiveAiChatMarkdown(mode)`.
  **Default mode = clean.** `/export full` selects full. Reuses existing path-choose /
  write / toast behavior.
- **`/permission [confirm|full]`** → no arg: print current permission; with arg:
  `AgentPermission.parse` → `configureAgent`, print new value. Transcript output only.
- **`/resume`** → fires the resume callback → opens the existing agent history picker.
- **`/reload-commands`** → rescans the `commands/` directory and rebuilds the merged
  list (independent command, peer to `/reload-skills`; per user decision not folded into
  reload-skills).

## A4. Dispatch & cross-layer hooks

Extend the dispatch at `ai_chat.zig:1370`:

- Built-in action with local output (`commands`, `permission` status, `clear`
  confirmation) → produce transcript text via `slashCommandOutput`.
- Built-in action that drives the app layer (`/resume`, `/export`) → invoke a global
  callback registered once at startup, mirroring `setSkillUpdateTrigger`
  (`ai_chat.zig:317`). New: `setSessionResumeTrigger(cb)` and
  `setMarkdownExportTrigger(cb: fn(MarkdownExportMode) void)`. Wired in the app layer
  next to the existing `setSkillUpdateTrigger` call site.
- Custom `prompt_template` command → expand `body` into a normal user prompt and submit
  it to the model (not a local output). Reuses the existing submit path.

## Error handling

- Missing/empty `commands/` dir → zero custom commands, no error (mirror skills).
- Malformed command file (no `name`, unknown `action`) → skip + warn, never crash.
- `/export` / `/resume` callbacks unset (e.g. headless/tests) → no-op with a logged
  warning; transcript shows a brief "unavailable" note.
- `/permission badvalue` → print usage + current value; no state change.

## Testing

- `command_registry.zig`: parse valid command (action / prompt-template), missing name,
  unknown action, empty dir, duplicate names — pure unit tests.
- `ai_chat_composer.zig`: `parseSlashCommand` and suggestion functions over a merged
  list including custom commands (parametrized list); existing tests updated to pass the
  built-in list.
- `ai_chat.zig`: `/clear` empties messages and keeps settings; `/permission full` flips
  `g_agent_settings`; `/export`/`/resume` invoke their registered callback (capture
  hook, like existing `TestHistoryHookCapture`); prompt-template command submits its body.
- Test wiring: new modules must be `_ = @import`ed in `test_fast.zig` / `test_main.zig`
  to register their tests (per repo test-inclusion rule).
