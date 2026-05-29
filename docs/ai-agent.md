# AI Chat Sessions

Open the session launcher with `Ctrl+Shift+T` and choose `AI Agent`. WispTerm
opens the default AI profile directly in Agent mode. If no AI profile exists
yet, it opens the AI settings form first so you can configure the provider,
model, API key, and agent mode before the first launch.

Manage the default AI profile from Settings. Profile data is stored under the
platform config directory (`ai_profiles/`) — `%APPDATA%\wispterm\ai_profiles` on
Windows, `~/Library/Application Support/wispterm/ai_profiles` on macOS — with
fields hex encoded on disk.

AI Chat can speak OpenAI-compatible Chat Completions, the OpenAI Responses API,
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
Completed requests show elapsed time in the AI Chat status area, and token usage
when the provider returns OpenAI-compatible `usage` fields.

## Markdown Export

Use the command center to run `Export AI Chat Markdown` for the full transcript,
including reasoning, tool details, and usage metadata.

Use `Export AI Chat Markdown Clean` when you want a publishing-friendly record:
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
- `/permission` shows the agent tool permission; `/permission confirm` or
  `/permission full` changes it at runtime.
- `/export` writes the conversation to Markdown (clean by default; `/export full`
  includes reasoning, tool details, and usage).

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

## Asking About WispTerm Itself

The agent can read WispTerm's own user documentation on demand through the
`wispterm_docs` tool. Ask a natural question such as "how do I change the font?"
or "what clipboard options exist?" and the agent first lists the available
topics (`faq`, `configuration`, `ai-agent`, `file-explorer`, `media`), then
reads the relevant one and answers from it.

The docs are embedded in the WispTerm binary, so this works offline and without
the source tree. The system prompt only carries a one-line pointer to the tool;
the documentation text is loaded only when the agent calls `wispterm_docs`.
