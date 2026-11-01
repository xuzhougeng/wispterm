# Getting Started

*English · [中文](Getting-Started-zh)*

> First launch, the command center, and how to open shells, tabs, and AI sessions.

## First launch

Start WispTerm and you get a terminal running your default shell. On the **very
first launch**, if you have not configured an AI provider yet, WispTerm shows
the AI setup form so you can fill in the provider, model, API key, and agent
mode before continuing. This prompt is shown only once — after that you manage
AI profiles from Settings (see [[AI-Copilot]]).

## The command center

Press **`Ctrl+Shift+P`** to open the command center (command palette). Type to
filter, then run an action — for example `Toggle Browser`, `Copy Remote Key`,
or `Export Copilot Markdown`. Most app features are reachable from here, which
is the fastest way to discover what WispTerm can do.

## Sessions & tabs

Press **`Ctrl+Shift+T`** to open the session launcher. From it you can:

- open a new shell tab,
- open **Copilot** (the built-in AI agent, see [[AI-Copilot]]),
- open **Sessions** to browse and resume Codex / Claude Code history,
- open a workbench page: **Port Forwarding**, **Memory Center**, or **Settings**.

Open more terminals as **tabs** along the strip, or divide one tab into
**splits** — see [[Tabs-Splits-Panels]] for split and focus controls.

## Discovery flags

Run WispTerm with these flags to inspect your environment:

```bash
wispterm --list-fonts          # available system fonts
wispterm --list-themes         # built-in themes
wispterm --show-config-path    # resolved main config path
wispterm --help                # all command-line options
```

## Next steps

- Arrange your workspace → [[Tabs-Splits-Panels]]
- Customize the look and behavior → [[Configuration]] and [[Themes-Appearance]]
- Put the AI Copilot to work → [[AI-Copilot]]

---
*See also: [[Installation]] · [[Tabs-Splits-Panels]] · [[AI-Copilot]]*
