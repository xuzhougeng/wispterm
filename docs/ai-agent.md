# AI Chat Sessions

Open the session launcher with `Ctrl+Shift+T` and choose `AI Agent`. Phantty
opens the default AI profile directly in Agent mode. If no AI profile exists
yet, it opens the AI settings form first so you can configure the provider,
model, API key, and agent mode before the first launch.

Manage the default AI profile from Settings. Profile data is stored under
`%APPDATA%\phantty\ai_profiles`, with fields hex encoded on disk.

The first AI Chat implementation targets OpenAI-compatible chat completions.
The built-in defaults are:

- Base URL: `https://api.deepseek.com`
- Model: `deepseek-v4-pro`
- System prompt: embedded from `src/prompt.md`
- Request mode: DeepSeek thinking enabled, `reasoning_effort = high`, non-streaming

The default agent prompt assumes Windows PowerShell for local commands, routes
open SSH/WSL terminals through Phantty's terminal tools, avoids pasting shell
commands into Codex/Claude Code REPLs, and keeps Python environment management
on `uv`. For existing AI profiles, clear the System field to use the current
embedded default prompt on the next launch.

If an AI profile does not include an API key and its base URL points at
DeepSeek, Phantty also checks `DEEPSEEK_API_KEY` in the process environment.
Responses with `reasoning_content` are shown as a muted reasoning block above
the assistant reply. This follows DeepSeek's
[thinking mode guide](https://api-docs.deepseek.com/zh-cn/guides/thinking_mode).
Completed requests show elapsed time in the AI Chat status area, and token usage
when the provider returns OpenAI-compatible `usage` fields.

Agent tool commands run as hidden background child processes where possible, so
local PowerShell/cmd tool calls do not flash a separate console window.

## Agent Skills

Agent chats can load local skills from `skills/<skill-name>/SKILL.md` or
`plugins/skills/<skill-name>/SKILL.md` under `%APPDATA%\phantty`, the current
working directory, or the directory containing `phantty.exe`.
Use `$skill-name your request` to explicitly load a skill for the next request.
The loaded skill is stored as a replayable tool result in the chat history, so
existing conversations stay reproducible even if the skill file changes later.

Local slash commands:

- `/skills` lists discovered local skills without calling the model.
- `/commands` lists local AI chat commands without calling the model.
- `/reload-skills` confirms that future skill calls will read from disk again.

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
