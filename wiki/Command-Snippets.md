# Command Snippets

*English · [中文](Command-Snippets-zh)*

> Define reusable commands once and fire them into any session from the command
> center — local shell, WSL, PowerShell, or SSH.

## What a snippet is

A snippet is a named piece of text you trigger from the command center
(`Ctrl+Shift+P`, `Cmd+Shift+P` on macOS). When you select it, WispTerm sends the
text to the **active session**, whatever it is. This is the WispTerm answer to
the button bars in tools like WindTerm and SecureCRT: keep your fixed commands
in the terminal instead of maintaining the same shell alias on every machine you
SSH into.

## Where snippets live

Each snippet is one Markdown file in a `snippets/` directory next to your
[[config file|Configuration]]:

- **Windows:** `%APPDATA%\wispterm\snippets\`
- **macOS:** `~/Library/Application Support/wispterm/snippets/`
- **Linux:** `$XDG_CONFIG_HOME/wispterm/snippets/` (fallback: `~/.config/wispterm/snippets/`)

Create the `snippets/` folder if it does not exist. The file name does not
matter — `deploy.md`, `gs.md`, anything ending in `.md`.

## File format

The front matter sets the title; the body is the text that gets sent:

```markdown
---
name: deploy
description: build and ship to production
---
make deploy
```

- `name` — required. Shown in the command center and used to filter.
- `description` — optional. Also matched when you type in the filter.
- **body** — everything after the closing `---`. Sent to the session byte for
  byte.

### Run immediately or just insert

The body is sent exactly as written, so the trailing newline is the switch:

- **Ends with a newline** → the command runs immediately on selection (the
  example above). Most editors add a trailing newline on save, so this is the
  default behaviour.
- **No trailing newline** → the text is only inserted at the prompt so you can
  review or edit it, then press Enter yourself.

Snippets are re-read every time the command center opens, so edits appear
without restarting WispTerm.

## Trigger a snippet

1. Focus the session (terminal tab or SSH panel) you want the command to land
   in.
2. Open the command center with `Ctrl+Shift+P` (`Cmd+Shift+P` on macOS).
3. Type part of the snippet's `name` or `description` to filter; snippet rows
   are tagged `send` on the right.
4. Press Enter, or click the row, to send it to the active session.

## Ask the Copilot to make one

You can skip the editor entirely. The [[AI Copilot|AI-Copilot]] has a
`write_file` tool, so just describe what you want:

> Create a WispTerm command snippet named `gs` that runs `git status`. Snippets
> live in `~/Library/Application Support/wispterm/snippets/` as a Markdown file
> with `name:` front matter and the command in the body, ending with a newline
> so it runs on selection.

The Copilot writes the `.md` file; reopen the command center and the snippet is
ready to fire.
