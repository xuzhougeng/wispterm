# Agent Terminal Control API (`wisptermctl`)

WispTerm can expose a small **local** control API so external agents — Claude
Code, Codex CLI, or your own scripts — can list panes, read terminal output, and
send input to any terminal running inside WispTerm. This lets one agent in pane A
drive a build/test in pane B and read the result, i.e. several agents
collaborating in one workspace.

It is the same low-level capability the built-in Copilot uses internally, opened
through a local door. The built-in Copilot does **not** need `wisptermctl`.

## Enabling

Off by default. In your WispTerm config:

```
agent-control-enabled = true
# agent-control-port = 0   # optional; 0 = let the OS pick a free loopback port
```

Restart WispTerm. On start it:

- binds a **127.0.0.1**-only TCP listener (never a public interface), and
- writes a random auth token + the chosen port to
  `<config-dir>/agent-control.json` with `0600` permissions.

`<config-dir>` is `$XDG_CONFIG_HOME/wispterm` (Linux), `~/.config/wispterm`
(Linux fallback), `~/Library/Application Support/wispterm` (macOS), or
`%APPDATA%\wispterm` (Windows). The `wisptermctl` client reads this file to find
and authenticate to the running instance automatically — you never pass a token
or port by hand.

## The `wisptermctl` client

`wisptermctl` is shipped as a **separate** binary (it is not part of the WispTerm
app bundle). Build it with:

```
zig build wisptermctl        # → zig-out/bin/wisptermctl
```

### Commands

```
wisptermctl panes
    List tabs/panes as JSON: surface id, title, cwd, cols/rows, cursor,
    focus, agent detection, and split geometry.

wisptermctl get-text -t <surface-id> [--recent N]
    Print a surface's terminal text. Without --recent you get a recent window
    (~1000 rows); --recent N prepends up to N scrollback rows.

wisptermctl send-text -t <surface-id> "<text>"
    Send input to a surface. C-style escapes are decoded: \n \r \t \0 \\ \xNN.
    To run a command, include a trailing newline, e.g. "cargo test\n".

wisptermctl wait-for -t <surface-id> "<pattern>" [--regex] [--lines N] [--timeout SECONDS]
    Poll get-text until the output contains <pattern> (default 60s). With
    --regex the pattern is matched against each line (the same regex dialect
    the agent detection manifests use); --lines N searches only the last N
    lines so old output cannot satisfy the wait. Exit 0 on match, 2 on timeout.

wisptermctl spawn [--cwd DIR] [--kind AGENT] [--split right|down] [--wait-ready]
                  [--timeout SECONDS] [-- program args...]
    Open a NEW tab (no separate window), or with --split a new pane next to
    the active tab's focused one, and print {"surfaceId":"..."} once the UI
    thread has created it. --cwd sets the working directory (default: the
    active tab's cwd). Everything after `--` is the command to run (default:
    your configured shell). --kind names a supported agent (claude, codex,
    gemini, copilot, cursor, kimi, opencode, pi, qwen, grok, ...): its
    launcher is run with the args after `--` and the pane is tagged with that
    identity for screen detection. --wait-ready (needs --kind) blocks until
    the agent is at its prompt; if it stopped on a decision first (a trust
    or permission dialog) the id is still printed and the exit code is 5
    (agent_not_ready). Default --timeout for --wait-ready is 30s.

wisptermctl agent-state -t <surface-id>
    Print the surface's agent and lifecycle state as JSON: agentApp,
    agentState (idle | running | waiting_approval | needs_input | done |
    halted | failed | none), agentBadge, agentConfidence. The state comes from
    the agent's hook marker when one is installed, else from screen detection
    (`agent-screen-detection`).

wisptermctl wait-agent -t <surface-id> [--until STATE]... [--timeout SECONDS]
    Wait until the agent's state is one of the --until values and print it.
    Default: ready (idle, done, waiting_approval, needs_input). STATE accepts
    the state names plus ready, blocked (waiting_approval + needs_input) and
    run. Returns at once when the state already matches. Exit 0, or 2 on
    timeout (default 60s).

wisptermctl prompt -t <surface-id> "<text>" [--wait] [--until STATE]... [--timeout SECONDS]
    Type <text> into the agent and press Enter after a short delay. If the
    agent is already waiting for a decision nothing is sent and the exit code
    is 3 (agent_blocked): read the screen and answer it with send-text first.
    With --wait, the command then waits like wait-agent (default: ready). If
    the agent was not already working and no working or blocked state appears
    within 5s, the exit code is 4 (prompt_stalled); read the agent before
    retrying so the prompt is not submitted twice. Escapes are decoded as in
    send-text; keep the prompt to one line.
```

Surface ids come from `wisptermctl panes` (the `id` field). Exit codes: 0 ok,
1 request failed / surface gone, 2 timeout, 3 agent_blocked, 4 prompt_stalled,
5 agent_not_ready.

### Example: start a helper agent, hand it work, wait for it

```sh
pane=$(wisptermctl spawn --kind codex --split right --wait-ready -- -m gpt-5.4 | jq -r .surfaceId)
wisptermctl prompt -t "$pane" "Review the current diff" --wait --timeout 300
wisptermctl get-text -t "$pane" --recent 120
```

### Example: wait for the agent to need you, look, then answer

```sh
wisptermctl wait-agent -t "$pane" --until blocked --timeout 120
wisptermctl get-text -t "$pane"
wisptermctl send-text -t "$pane" "1\r"     # or "\x1b" to cancel
```

### Example: jump to a saved session in its own tab

```sh
wisptermctl spawn --cwd "F:\1_Bio-analysis" -- claude -r 1b42b2ea   # the issue's use case
wisptermctl spawn --cwd /home/me/code                              # just a shell in that dir
wisptermctl spawn                                                  # new tab, active tab's cwd
```

### Example: run a test in another pane and read the result

```sh
id=$(wisptermctl panes | jq -r '.tabs[0].surfaces[0].id')
wisptermctl send-text -t "$id" "cargo test\n"
wisptermctl wait-for  -t "$id" "test result:" --timeout 120
wisptermctl get-text  -t "$id" --recent 200
```

## Security

- Listener is bound to `127.0.0.1` only — not reachable off the machine.
- Every request must carry the token from the `0600` discovery file; the token
  is compared in constant time. A wrong/absent token is rejected as
  `unauthorized`.
- The API is disabled unless you opt in with `agent-control-enabled = true`.

## Cross-platform notes

Works on Linux, macOS, and Windows. Reads/writes pin the target surface through
the same process-wide liveness guard the built-in agent uses, so they are safe
from any thread without relying on the Win32 message bus (which does not exist on
Linux/SDL).

## Limitations

- No per-command exit-status / "last activity" metadata.
- No named special-key syntax yet (use `\xNN` escapes in `send-text`, e.g.
  `\x03` for Ctrl-C, `\x1b` for Esc).
- No remote (off-machine) mode — local loopback only.
- One request per connection; `wait-for`, `wait-agent` and `prompt --wait`
  reconnect each poll (every 500 ms for text, 100 ms for agent state).
- `prompt` sends the text as typed input without bracketed-paste markers, so
  a multi-line prompt would submit at its first newline.
- Agent state is only as good as its source: with no hook marker it follows
  screen detection, so an agent WispTerm cannot identify (see
  [KNOWN_ISSUES.md](../KNOWN_ISSUES.md)) reports `none` and `wait-agent`
  times out. `spawn --kind` tags the pane itself, so agents started that way
  are always identified.
- Full-screen agents (Claude Code, OpenCode) draw their conversation on the
  alternate screen; `get-text` returns the visible screen plus the main
  screen's scrollback, not the agent's earlier replies.
