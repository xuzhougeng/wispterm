# Agent Exec Robustness: False-Failure Fix + Interrupt Recovery

Date: 2026-06-02
Status: Approved design, pre-implementation

## Problem

The WispTerm AI agent has two field-reported failure modes when driving terminals:

1. **Long-running tasks misjudged as broken.** A user asked the agent to
   `git clone` a repo over an open SSH/WSL session. The clone succeeded, but the
   agent concluded the terminal had "reconnected", re-issued the clone, and
   produced a duplicate run (second attempt: `destination path 'dotPlotly'
   already exists … exit 128`).

2. **Stuck in an input mode with no way out.** The agent typed text that left the
   shell in a continuation state (unclosed quote → `cd'` with `>` prompts), or a
   hung interactive command / pager. It had no capability to send Ctrl+C, so it
   kept typing more text, making things worse. The user had to close and reopen
   the terminal.

## Root Cause

### Issue 1 — echoed command line matches the completion sentinel

`unixSessionExecTool` (`src/ai_chat_tools.zig`) wraps each command with
time-nonce sentinels:

```
 setopt hist_ignore_space …; printf '\n__WISPTERM_AGENT_START_<nonce>__\n';
 { <command>; } 2>&1; __wispterm_agent_status=$?;
 printf '\n__WISPTERM_AGENT_END_<nonce>__:%s\n' "$__wispterm_agent_status"
```

`waitForSentinelResult` decides the command finished with:

```zig
if (std.mem.indexOf(u8, text, end_marker) != null) { … }   // end_marker = "__WISPTERM_AGENT_END_<nonce>__"
```

The interactive shell **echoes the whole wrapped command line** into the
scrollback before it runs. That echoed line literally contains
`__WISPTERM_AGENT_END_<nonce>__:%s`, so the bare-substring match fires
**before the command even starts**. The tool returns near-instantly with a
fragment sliced out of the echoed command (also true of
`extractUnixCommandResult`, which takes the first start/end occurrences — both in
the echo). The model sees no real output, assumes the session is broken, and
retries — causing the duplicate side effect.

Decisive disambiguator: the **real** completion line ends in `:<status-digit>`
(e.g. `:0`, `:128`), printed on its own line at column 0 (won't wrap at normal
widths). The **echo** ends in `:%s` (or, for R, `:"`). Requiring the marker to be
followed by `:` and a digit cleanly separates real output from echo across the
shell, R, and Python wrappers.

### Issue 2 — no interrupt capability

The agent's tool set (`executeToolCall`) has no way to emit Ctrl+C or any control
key. Once a terminal is in a continuation/hung state, `terminal_repl_exec
repl=plain` can only append more text, which cannot recover the prompt.

## Scope (agreed)

In scope:
- Fix A: robust sentinel completion matching + surface the exit status.
- Fix B: instructive timeout message (still-running, do not re-issue).
- Fix C: "previous command still running" guard before injecting a new command.
- Fix D: control-key tokens via `terminal_repl_exec` + prompt/description guidance.

Out of scope (explicitly deferred):
- Asynchronous / background job execution with progress polling.
- A separate dedicated `terminal_interrupt` tool (we extend the existing
  `terminal_repl_exec` instead).

## Files Touched

- `src/ai_chat_tools.zig` — core logic + unit tests.
- `src/ai_chat_protocol.zig` — `terminal_repl_exec` tool-schema description.
- `src/platform/agent_prompt.zig` — system-prompt guidance.

## Design

### Fix A — sentinel completion matching + exit status

New helper:

```
fn findCompletedEnd(text, end_marker) -> ?usize
```

Scans every occurrence of `end_marker` in `text`; returns the index of the first
occurrence immediately followed by `:` and at least one ASCII digit. Returns
`null` if none qualifies (command not finished yet — only the echo is present).

- `waitForSentinelResult` uses `findCompletedEnd` instead of the bare
  `indexOf(end_marker)` check.
- `extractUnixCommandResult` is reworked to anchor off the completed end:
  1. `end_pos = findCompletedEnd(text, end_marker)`; if `null`, treat as
     incomplete (caller keeps polling / reports still-running).
  2. `start_pos` = the **last** `start_marker` occurrence strictly before
     `end_pos` (the real start sits just above the output; the echo's start is
     further up).
  3. body = `trim(text[start_pos + start_marker.len .. end_pos])`.
  4. Parse the integer status after `end_pos`'s `:`; prepend a single header line
     `exit_status=N\n` to the returned result so the model sees success/failure
     directly and stops misjudging.

Applies uniformly to the shell (ssh/wsl), R, and Python sentinel paths, all of
which route through `waitForSentinelResult`. Their echoes end in `:%s` / `:"`,
which fail the `:`+digit test, so they are ignored.

Known limitation: if a real marker line wrapped (it won't at normal widths since
it is printed at column 0 on its own line), the `:`+digit check could miss it —
same wrap exposure the current code already has; not addressed here.

### Fix B — instructive timeout message

When `waitForSentinelResult` reaches the deadline with no completed end, replace
the terse "Timed out waiting for … sentinel" with a message that:
- states the command is **likely still running** (include elapsed seconds),
- tells the model **not to re-issue** it,
- suggests re-checking later with `terminal_snapshot`, or interrupting with
  `terminal_repl_exec repl=plain code=<ctrl-c>`,
- still appends the latest snapshot.

### Fix C — "previous command still running" guard

New helper:

```
fn hasPendingAgentCommand(snapshot) -> bool
```

Find the last `__WISPTERM_AGENT_START_<n>__` in the snapshot, extract its nonce,
and return `true` if no matching `__WISPTERM_AGENT_END_<n>__:` + digit exists
after it.

`unixSessionExecTool`, before writing the wrapped command, reads a **fresh**
surface snapshot (`host.surfaceSnapshot`) and, if `hasPendingAgentCommand` is
true, refuses with:

> A previous command is still running in this terminal. Do not start another.
> Wait and re-check with `terminal_snapshot`, or send
> `terminal_repl_exec repl=plain code=<ctrl-c>` to interrupt it first.

Notes:
- Scoped to the ssh/wsl shell-exec path (where the duplicate side effect bites).
- False negative (markers scrolled off → treated as idle): acceptable.
- False positive (idle but a stale dangling start is still on screen): the model
  can send `<ctrl-c>` (harmless when idle) and retry; the new command carries a
  fresh nonce.

### Fix D — control-key tokens in `terminal_repl_exec`

When `code`, after trimming, is **exactly** one recognized token (whole-string
match, never a substring, to avoid mangling normal text), it is sent as a raw
control byte with **no submit key appended**:

| token             | byte | purpose                              |
|-------------------|------|--------------------------------------|
| `<ctrl-c>`        | 0x03 | interrupt / abort current line       |
| `<ctrl-d>`        | 0x04 | EOF                                  |
| `<esc>`           | 0x1b | leave modes / dismiss               |
| `<enter>` / `<cr>`| 0x0d | submit a pending line / dismiss      |
| `<ctrl-u>`        | 0x15 | kill line (e.g. clear an unclosed `cd'`) |

After writing the control byte, take a fresh snapshot of the surface and return
it so the model sees the recovered prompt. Approval handling is unchanged
(`isDangerousCommand` is false for these tokens; restricted-permission modes
still prompt, with a clear reason).

`ai_chat_protocol.zig`: extend the `terminal_repl_exec` `code` property
description to document the control-key tokens.

`agent_prompt.zig`: add two guidance lines (POSIX/macOS/Windows variants as
appropriate):
- A long-running session-exec command is probably still running — do **not**
  re-issue it; wait and re-check with `terminal_snapshot`.
- If a terminal is stuck (continuation `>` prompt, unclosed quote, hung
  interactive command, or pager), recover by sending
  `terminal_repl_exec repl=plain code=<ctrl-c>` (or `<ctrl-u>`/`<esc>`/`<ctrl-d>`)
  — do not keep typing commands.

## Testing

Unit tests in `src/ai_chat_tools.zig` (run under `zig build test` /
`zig build test-full`):

- **Echo skip + extraction:** snapshot containing the echoed wrapped line plus
  real output → `extractUnixCommandResult` returns the real body and
  `exit_status=N`, ignoring the echo.
- **Incomplete:** snapshot with only the echo (no `:`+digit end) →
  `findCompletedEnd` returns `null` (treated as still-running).
- **Multi-digit status:** `:128` parses correctly.
- **Pending detection:** dangling start → `hasPendingAgentCommand` true;
  matching completed end → false; no markers → false.
- **Control-key parsing:** `code == "<ctrl-c>"` → byte 0x03, no submit key;
  normal text containing `<ctrl-c>` as a substring is sent verbatim with the
  usual submit key.

## Risks

- Behavior change to a shared exec path: mitigated by the uniform `:`+digit rule
  and unit tests across shell/R/Python echo shapes.
- Busy-guard false positives: bounded and self-healing via `<ctrl-c>` + retry.
