# Agent Terminal Control

*English · [中文](Agent-Terminal-Control-zh)*

> `wisptermctl` is an opt-in local control CLI for scripts and external agents. It can list panes, read terminal text, send input, wait for output, and open new tabs in the running WispTerm instance.

## Enabling

Add this to the WispTerm config, then restart:

```text
agent-control-enabled = true
# agent-control-port = 0   # optional; 0 = let the OS choose a free loopback port
```

WispTerm binds a `127.0.0.1` listener and writes a random token plus port to
`agent-control.json` under the platform config directory. `wisptermctl` reads
that file automatically; you do not pass the token or port by hand.

## The `wisptermctl` client

`wisptermctl` ships as a separate binary. For a local build:

```sh
zig build wisptermctl
```

### Commands

```sh
wisptermctl panes
wisptermctl get-text -t <surface-id> [--recent N]
wisptermctl send-text -t <surface-id> "<text>"
wisptermctl wait-for -t <surface-id> "<substring>" [--timeout SECONDS]
wisptermctl spawn [--cwd DIR] [-- program args...]
```

Surface ids come from `wisptermctl panes`. `send-text` decodes C-style escapes
such as `\n`, `\r`, `\t`, `\\`, and `\xNN`.

### Spawn examples

`spawn` opens a new tab in the running instance, not a separate window:

```sh
wisptermctl spawn --cwd "F:\1_Bio-analysis" -- claude -r 1b42b2ea   # the issue's use case
wisptermctl spawn --cwd /home/me/code                              # just a shell in that dir
wisptermctl spawn                                                  # new tab, active tab's cwd
```

When `--cwd` is omitted, the new tab uses the active tab's cwd. When the command
after `--` is omitted, WispTerm starts the configured shell.

### Pane automation example

```sh
id=$(wisptermctl panes | jq -r '.tabs[0].surfaces[0].id')
wisptermctl send-text -t "$id" "cargo test\n"
wisptermctl wait-for  -t "$id" "test result:" --timeout 120
wisptermctl get-text  -t "$id" --recent 200
```

## Security

- The API is off unless `agent-control-enabled = true`.
- The listener is loopback-only (`127.0.0.1`), not public.
- Every request must carry the token from the discovery file.

## Limitations

- `wait-for` matches a literal substring, not a regex.
- There is no per-command exit-status API yet.
- Special keys are sent with byte escapes such as `\x03` for Ctrl-C.
- There is no off-machine mode; this is local loopback only.
