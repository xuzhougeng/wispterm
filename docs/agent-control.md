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

wisptermctl wait-for -t <surface-id> "<substring>" [--timeout SECONDS]
    Poll get-text until the output contains <substring> (default 60s).
    Exit 0 on match, 2 on timeout.
```

Surface ids come from `wisptermctl panes` (the `id` field).

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

## Limitations (MVP)

- `wait-for` matches a **literal substring** (not a regex).
- No per-command exit-status / "last activity" metadata.
- No named special-key syntax yet (use `\xNN` escapes in `send-text`, e.g.
  `\x03` for Ctrl-C, `\x1b` for Esc).
- No remote (off-machine) mode — local loopback only.
- One request per connection; `wait-for` reconnects each poll.
