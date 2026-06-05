# AI Copilot & Agent

*English · [中文](AI-Copilot-zh)*

> Configure AI providers, run the in-context Copilot, manage permissions and working directories, use skills and slash commands, and resume past sessions.

## Opening Copilot

Open the session launcher with `Ctrl+Shift+T` and choose **Copilot**. WispTerm
opens the default AI profile directly in Agent mode. If no AI profile exists
yet, it opens the AI settings form first so you can configure the provider,
model, API key, and agent mode before the first launch.

## Configuring profiles

Manage the default AI profile from Settings. Profile data is stored under the
platform config directory in `ai_profiles/` (`%APPDATA%\wispterm\ai_profiles` on
Windows, `~/Library/Application Support/wispterm/ai_profiles` on macOS), with
fields hex-encoded on disk.

## Providers & protocols

Copilot can speak OpenAI-compatible **Chat Completions**, the OpenAI
**Responses** API, or the **Anthropic Messages** API. Set the profile Protocol
field to `chat_completions` (default), `responses`, or `anthropic`:

- `responses` profiles use a base URL such as `https://api.openai.com/v1` or a
  full endpoint ending in `/responses`.
- `anthropic` profiles call `<base_url>/v1/messages`, authenticate with
  `x-api-key` + `anthropic-version` (not a Bearer token), and require a
  `Max Tokens` value (profile default `8192`). A base URL containing
  `api.anthropic.com` auto-selects `anthropic`; Anthropic-compatible third
  parties on other hosts (e.g. GLM/Zhipu) must set `anthropic` explicitly.
  Streaming is not yet supported for this protocol.

## Defaults & API keys

The built-in defaults target DeepSeek:

- Base URL `https://api.deepseek.com`, model `deepseek-v4-pro`,
  protocol `chat_completions`.
- DeepSeek thinking enabled, `reasoning_effort = high`, non-streaming.
- A platform-aware system prompt is compiled into the binary; clear the System
  field on an existing profile to pick up the current embedded default.

If a profile has no API key and its base URL points at DeepSeek, WispTerm also
checks `DEEPSEEK_API_KEY` in the environment. Responses with `reasoning_content`
appear as a muted reasoning block above the reply. Completed requests show
elapsed time and, when the provider returns OpenAI-compatible `usage`, token
counts.

## The Copilot sidebar

Press `Ctrl+Shift+A` (`Cmd+Shift+A` on macOS) on a terminal tab to toggle a
right-side AI copilot bound to the focused terminal (terminal tabs only).

- Each terminal tab keeps its **own** conversation; closing the tab discards it.
- Terminal actions default to the current terminal — no tab to pick first. The
  copilot can still operate other terminals when you explicitly ask.
- Every message automatically includes a lightweight snapshot of the bound
  terminal's working directory and recent output, so you don't paste context.
- It shares the default AI profile (same provider, model, key) as Copilot.
- It uses the right panel slot exclusively: opening it hides the browser panel
  and Markdown preview, and vice versa.
- `Esc` stops an in-flight request; pressing `Esc` again while idle hides the
  panel and returns focus to the terminal. Drag the left edge to resize it.

## Pasting images (Vision)

Each AI profile has a **Vision** toggle (off by default). Enable it on a profile
that uses a vision-capable model, then press `Ctrl+Shift+V` (`Cmd+Shift+V` on
macOS) to paste a clipboard image into the chat composer. The image is sent as a
multimodal block and re-sent on each follow-up turn so the model keeps seeing it.
Pasting an image into a non-vision profile is ignored with a log and a toast.

## Dropping files into the chat

Drag a local file onto a visible chat surface — a Copilot tab or the Copilot
sidebar — to insert that file's absolute path into the composer. The path is
quoted automatically when it contains spaces, with a trailing space added so you
can keep typing your request.

## File editing

The AI agent can read and edit files directly:

- **read_file** — read a local or remote text file (returns numbered lines; supports an `offset`/`limit` line range for large files).
- **write_file** — create or overwrite a file with exact content.
- **edit_file** — replace an exact, unique string (or every occurrence with `replace_all`).

To edit a file on a remote SSH server, the agent passes the `surface_id` of an open SSH terminal tab; the operation runs on that host over the existing connection. Local files (no `surface_id`) resolve relative paths against the conversation's working directory. Writes and edits display a diff and, depending on the permission level (confirm / auto / full), may ask you to approve before applying.

## Working directory

Local agent commands run in a default working directory set globally by
`ai-agent-working-dir` (empty = unset). Override it per conversation with the
`/cwd` slash command:

- `/cwd` — show the current working directory.
- `/cwd <path>` — set it for this conversation.
- `/cwd reset` (or `default` / `clear`) — revert to the global default.

## Tool permissions

Control how the agent runs tools with `/permission ask|auto|full` (`confirm` is
an alias for `ask`):

- `ask` — prompt for normal tool use.
- `auto` — run ordinary tools automatically, but still confirm protected-path
  and dangerous commands.
- `full` — skip approval guard prompts entirely.

## Remote approval replies

If WeChat direct control is connected, a pending Copilot approval can also be
sent to WeChat. Reply `Y`/`yes` to approve or `N`/`no` to deny; WispTerm routes
that reply back into the same approval dialog that would otherwise wait in the
desktop UI. The desktop app remains the source of truth, and protected file
paths still use the normal access gate before an approval prompt is emitted.

## Sessions browser & resume

Open the session launcher (`Ctrl+Shift+T`) and choose **Sessions** to browse
Codex, Claude Code, and Reasonix transcripts on a Local, WSL, or SSH target.
WispTerm connects to the target, scans `$HOME/.codex`, `$HOME/.claude`, and
`$HOME/.reasonix` for metadata, and loads a transcript only when you open its
row. **Resume** opens a real terminal tab on the same target in the original
project directory recorded in the history file; if that directory is missing,
resume stops instead of falling back to `$HOME`.

## Slash commands

Built-in commands handled in the panel (not sent to the model):

- `/skills` — list discovered local skills.
- `/commands` — list all available slash commands.
- `/reload-skills` — re-read skill files from disk on next call.
- `/reload-commands` — rescan the custom `commands/` directory.
- `/clear` — clear the conversation context (keeps the tab and profile).
- `/resume` — open the saved-conversation history picker.
- `/permission [ask|auto|full]` — show or change the tool permission.
- `/export [full]` — write the conversation to Markdown (clean by default).
- `/distill [topic]` / `/沉淀 [主题]` — preview a reusable skill from this chat.
- `/cwd [path|reset]` — show or set the conversation working directory.

## Custom slash commands

Drop Markdown files in a `commands/` directory under the platform config
directory (`%APPDATA%\wispterm\commands` on Windows), the current working
directory, or next to the `wispterm` executable. Each `*.md` file is one
command, named by its `name:` frontmatter:

```markdown
---
name: review
description: review the current diff
---
Please review the current git diff for correctness and simplifications.
```

A command with no `action:` uses its body as a prompt template. A command may
instead map to a built-in action with
`action: clear_context | restore_session | set_permission | export_markdown`.
Names that collide with a built-in are ignored. Run `/reload-commands` to pick
up edits without restarting.

## Agent skills

Agent chats load local skills from `skills/<name>/SKILL.md` or
`plugins/skills/<name>/SKILL.md` under the platform config directory, the
current working directory, or the directory containing the executable. Use
`$skill-name your request` to load a skill for the next request. The loaded
skill is stored as a replayable tool result, so existing conversations stay
reproducible even if the skill file changes later.

## Skill distillation

After a useful workflow, run `/distill`, `/distill <topic>`, `/沉淀`, or
`/沉淀 <主题>` to generate a candidate local `SKILL.md`. WispTerm sends a
redacted transcript to your provider and shows a local preview (name,
description, save path, body, source summary). Confirm or discard explicitly:

- `/distill confirm` (or `/沉淀 确认`) writes the skill.
- `/distill cancel` (or `/沉淀 取消`) discards it.

Distilled skills are saved only under `<config>/skills/<slug>/SKILL.md`; existing
skill directories are never overwritten. Before the request and again before
writing, WispTerm scans for API keys, passwords, and tokens — unredacted secrets
block the write.

## Exporting transcripts

From the command center:

- **Export Copilot Markdown** — the full transcript (reasoning, tool details,
  usage metadata).
- **Export Copilot Markdown Clean** — only user prompts and the final answer,
  good for notes or blog drafts.

You can also use `/export` (clean) or `/export full`. WispTerm opens a save
dialog and copies the saved path to the clipboard afterward.

## Clipboard behavior

For Xshell-like terminal clipboard behavior:

```text
copy-on-select = true
right-click-action = paste
```

`right-click-action = copy-or-paste` copies when a selection is active and
pastes when there is none.

## Ask WispTerm about itself

The agent can read WispTerm's own user docs on demand via the `wispterm_docs`
tool. Ask a natural question ("how do I change the font?") and it lists the
available topics (`faq`, `configuration`, `ai-agent`, `file-explorer`, `media`),
reads the relevant one, and answers from it. The docs are embedded in the
binary, so this works offline.

---
*See also: [[Getting-Started]] · [[SSH-Remote-Development]] · [[Configuration]]*
