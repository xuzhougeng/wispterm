# Copilot

Open the session launcher with `Ctrl+Shift+T` and choose `Copilot`. WispTerm
opens the default AI profile directly in Agent mode. If no AI profile exists
yet, it opens the AI settings form first so you can configure the provider,
model, API key, and agent mode before the first launch.

Manage the default AI profile from Settings. Profile data is stored under the
platform config directory (`ai_profiles/`) — `%APPDATA%\wispterm\ai_profiles` on
Windows, `~/Library/Application Support/wispterm/ai_profiles` on macOS — with
fields hex encoded on disk.

Copilot can speak OpenAI-compatible Chat Completions, the OpenAI Responses API,
or the Anthropic Messages API. Set the profile Protocol field to
`chat_completions` (default), `responses`, or `anthropic`:

- `responses` profiles should use a base URL such as `https://api.openai.com/v1`
  or a full endpoint ending in `/responses`.
- `anthropic` profiles call `<base_url>/v1/messages`, authenticate with
  `x-api-key` + `anthropic-version` (not a Bearer token), and require a
  `Max Tokens` value (the profile default is `8192`). A base URL containing
  `api.anthropic.com` auto-selects the `anthropic` protocol; Anthropic-compatible
  third parties on other hosts (e.g. GLM/Zhipu) should set `anthropic` explicitly.
  Streaming is not yet supported for this protocol.

The built-in defaults are:

- Base URL: `https://api.deepseek.com`
- Model: `deepseek-v4-pro`
- Protocol: `chat_completions`
- System prompt: a platform-aware default compiled into the binary (defined in `src/platform/agent_prompt.zig`)
- Request mode: DeepSeek thinking enabled, `reasoning_effort = high`, non-streaming

The default agent prompt is platform-aware: on Windows it uses `powershell_exec`
for local commands; on macOS and Linux it uses `shell_exec`. All variants route
open SSH/WSL terminals through WispTerm's terminal tools, avoid pasting shell
commands into Codex/Claude Code REPLs, and keep Python environment management
on `uv`. For existing AI profiles, clear the System field to use the current
embedded default prompt on the next launch.

If an AI profile does not include an API key and its base URL points at
DeepSeek, WispTerm also checks `DEEPSEEK_API_KEY` in the process environment.
Responses with `reasoning_content` are shown as a muted reasoning block above
the assistant reply. This follows DeepSeek's
[thinking mode guide](https://api-docs.deepseek.com/zh-cn/guides/thinking_mode).
Completed requests show elapsed time in the Copilot status area, and token usage
when the provider returns OpenAI-compatible `usage` fields.

## Sessions

Open the session launcher with `Ctrl+Shift+T` and choose `Sessions` to browse
Codex, Claude Code, and Reasonix transcripts stored on a Local, WSL, or SSH
target. WispTerm connects to the selected target, scans `$HOME/.codex`,
`$HOME/.claude`, and `$HOME/.reasonix` for metadata, and loads a transcript
only when you open that row.

Use `Resume` to open a real terminal tab on the same target. WispTerm first
checks the original project directory recorded in the history file; if that
directory is missing, resume stops instead of falling back to `$HOME`.

## In-context Copilot Sidebar

Press `Ctrl+Shift+A` (`Cmd+Shift+A` on macOS) on a terminal tab to toggle a
right-side AI copilot bound to the currently focused terminal. The copilot is
terminal-only — it does not open on a Copilot tab or other non-terminal tabs.

- Each terminal tab keeps its own copilot conversation. The conversation is
  per-tab, and closing the tab discards it.
- Terminal actions default to the current terminal, so there is no tab to pick
  before asking. The copilot can still operate other terminals when you
  explicitly ask it to.
- Every message automatically includes a lightweight snapshot — the bound
  terminal's working directory plus its recent output — so the copilot has
  context without you pasting it.
- The copilot shares the default AI profile (same provider, model, and key) as
  Copilot.
- It occupies the right panel slot exclusively: opening the copilot hides the
  browser panel and the Markdown preview, and opening either of those hides the
  copilot.
- `Esc` stops an in-flight request. Pressing `Esc` again while idle hides the
  panel and returns focus to the terminal.
- Drag the panel's left edge to resize it; the width is shared across terminal
  tabs.

## Pasting Images (Vision)

Each AI profile has a **Vision** toggle (off by default). Enable it for a
profile that uses a vision-capable model, then press `Ctrl+Shift+V`
(`Cmd+Shift+V` on macOS) to paste an image from the clipboard into the chat
composer. The image is sent to the model as a multimodal block and is re-sent
with each follow-up turn so the model keeps seeing it. Pasting an image into a
profile whose model is not vision-capable is ignored with a log message and a
toast.

## Dropping Files into the Chat

Drag a local file onto a visible chat surface — a Copilot tab or the Copilot
sidebar — to insert that file's absolute path into the composer. The path is
quoted automatically when it contains spaces and is followed by a trailing
space, so you can keep typing your request after it.

## Markdown Export

Use the command center to run `Export Copilot Markdown` for the full transcript,
including reasoning, tool details, and usage metadata.

Use `Export Copilot Markdown Clean` when you want a publishing-friendly record:
it writes only user prompts and the final AI answer, without thinking blocks,
tool output, or usage metadata. This is useful for notes, blog drafts, and
WeChat public account posts.

WispTerm opens a save dialog with a Markdown filename so you can choose
the destination path. After saving, the saved path is copied to the clipboard.

Agent tool commands run as hidden background child processes where possible, so
local PowerShell/cmd tool calls do not flash a separate console window.

## Agent Skills

Agent chats can load local skills from `skills/<skill-name>/SKILL.md` or
`plugins/skills/<skill-name>/SKILL.md` under the platform config directory
(`%APPDATA%\wispterm` on Windows, `~/Library/Application Support/wispterm` on
macOS), the current working directory, or the directory containing the
`wispterm` executable.
Use `$skill-name your request` to explicitly load a skill for the next request.
The loaded skill is stored as a replayable tool result in the chat history, so
existing conversations stay reproducible even if the skill file changes later.

Local slash commands (handled in the panel, without calling the model):

- `/skills` lists discovered local skills.
- `/commands` lists all available slash commands.
- `/reload-skills` confirms that future skill calls will read from disk again.
- `/reload-commands` rescans the custom `commands/` directory.
- `/clear` clears the current conversation context (keeps the tab and profile).
- `/resume` opens the saved-conversation history picker.
- `/permission` shows the agent tool permission; `/permission ask`,
  `/permission auto`, or `/permission full` changes it at runtime.
  `ask` prompts for normal tool use, `auto` runs ordinary tools automatically
  while still confirming protected-path and dangerous commands, and `full`
  skips approval guard prompts. `confirm` remains accepted as an alias for
  `ask`.
- `/export` writes the conversation to Markdown (clean by default; `/export full`
  includes reasoning, tool details, and usage).
- `/distill [topic]` or `/沉淀 [主题]` previews a reusable local skill distilled
  from the current conversation.

## Skill Distillation

Use `/distill`, `/distill <topic>`, `/沉淀`, or `/沉淀 <主题>` after a useful AI
Chat, Agent, or Copilot workflow to generate a candidate local `SKILL.md`.
WispTerm sends a redacted transcript to the configured AI provider, then shows a
local preview with the skill name, description, save path, body, and source
summary. The command itself is handled by the panel and is not submitted as a
normal chat prompt.

Automatic suggestions may appear after tool-heavy or clearly reusable tasks:

```text
This task looks reusable. Distill it into a skill?
```

When that suggestion is pending, press Enter on an empty AI Chat input to open
the same preview flow, or press Esc to ignore it. WispTerm never writes a skill
silently from an automatic suggestion.

Confirm or discard the preview explicitly:

- `/distill confirm` or `/沉淀 确认` writes the skill.
- `/distill cancel` or `/沉淀 取消` discards the candidate.

Distilled skills are saved only under the user config skills directory:
`<config>/skills/<slug>/SKILL.md` (`%APPDATA%\wispterm\skills` on Windows).
They are not written to `plugins/skills`, bundled resources, or repository
plugin directories. Existing skill directories are not overwritten; use a more
specific topic or remove the old skill first.

Before the distiller request and again before writing, WispTerm scans for API
keys, passwords, bearer tokens, Weixin context tokens, and common
`*_TOKEN`/`*_KEY` style secrets. Unredacted sensitive content blocks the write
instead of being saved.

## Custom Slash Commands

Add your own slash commands by dropping Markdown files in a `commands/`
directory under the platform config directory (`%APPDATA%\wispterm\commands` on
Windows, `~/Library/Application Support/wispterm/commands` on macOS), the current
working directory, or next to the `wispterm` executable. Each `*.md` file is one
command, named by its `name:` frontmatter field:

```markdown
---
name: review
description: review the current diff
---
Please review the current git diff for correctness and simplifications.
```

A command with no `action:` uses its body as a prompt template (submitted to the
model). A command may instead map to a built-in action with
`action: clear_context` | `restore_session` | `set_permission` | `export_markdown`.
Names that collide with a built-in command are ignored. Run `/reload-commands`
to pick up edits without restarting.

Release packages include `plugins/skills/inspect-computer-config`, which can be
loaded with `$inspect-computer-config` to summarize local OS, CPU, memory, GPU,
disk, and runtime details.

For Xshell-like terminal clipboard behavior, use:

```text
copy-on-select = true
right-click-action = paste
```

`right-click-action = copy-or-paste` copies when a terminal selection is active
and pastes when there is no selection.

## WeChat Direct Control

You can drive a Copilot conversation from WeChat. Run **Connect WeChat** from the
command center and scan the QR code to bind your account; WispTerm then polls
WeChat for incoming messages and feeds them to the bound conversation, replying
back over WeChat. The remaining command-center entries manage that binding:

- **WeChat: Start** — resume polling with the saved binding.
- **WeChat: Stop** — stop polling but keep the saved binding.
- **WeChat: Status** — show the current connection state.
- **WeChat: Unbind** — clear the stored binding.

Because replies are delivered to a phone, the `Export Copilot Markdown Clean`
output (prompts plus the final answer only) is a good fit for forwarding results.

## Asking About WispTerm Itself

The agent can read WispTerm's own user documentation on demand through the
`wispterm_docs` tool. Ask a natural question such as "how do I change the font?"
or "what clipboard options exist?" and the agent first lists the available
topics (`faq`, `configuration`, `tabs-panels`, `ai-agent`, `file-explorer`,
`media`), then reads the relevant one and answers from it.

The docs are embedded in the WispTerm binary, so this works offline and without
the source tree. The system prompt only carries a one-line pointer to the tool;
the documentation text is loaded only when the agent calls `wispterm_docs`.
