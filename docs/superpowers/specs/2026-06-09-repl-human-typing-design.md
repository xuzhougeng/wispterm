# Human-like REPL execution for the Copilot agent

Date: 2026-06-09
Status: Approved (design)

## Problem

When the Copilot agent runs code in an interactive REPL via the
`terminal_repl_exec` tool, two things go wrong from the user's point of view:

1. **The terminal fills with garbage.** For `repl=python` / `repl=r`, the agent
   does not type the user's code. It types a sentinel-wrapped blob, e.g. (Python):

   ```python
   exec("print(\"\\n__WISPTERM_AGENT_START_1780968464133__\")\n__wispterm_agent_status = 0\n__wispterm_agent_code = ...\ntry:\n    exec(__wispterm_agent_code, globals())\nexcept Exception:\n    __wispterm_agent_status = 1\n    import traceback\n    traceback.print_exc()\nprint(\"\\n__WISPTERM_AGENT_END_...__:%s\" % __wispterm_agent_status)\ndel ...")
   ```

   The REPL echoes whatever is typed, so the user sees this whole blob.

2. **The agent writes verbose, indirect code** (e.g. two labelled `print(...)`
   "方式1 / 方式2" alternatives) instead of just `1+1` or `'1'+'1'`.

### Root cause (both symptoms, one design)

Both symptoms come from the same mechanism. The Python/R paths wrap user code in
`exec(code, globals())` (Python) / `eval(parse(...))` inside a `tryCatch`(R),
bracketed by `__WISPTERM_AGENT_START/END__` sentinel markers. The wrapper exists to:

- know **when** the command finished (a REPL has no exit code to read), and
- capture **whether** it errored (the `:0` / `:1` status suffix).

Consequences:

- The wrapper is **echoed** → terminal garbage (symptom 1).
- `exec(code, globals())` **discards expression values**, so a bare expression
  like `1+1` prints nothing. The agent is therefore forced to wrap everything in
  `print(...)` — which trains the verbose-code behaviour (symptom 2).

## Goal

Make REPL execution behave like a human typing at the prompt:

- Type the code **raw**. `1+1` echoes `2`; an error prints its native traceback.
- Detect completion the way a human does — **the prompt comes back** — rather than
  via injected sentinels.
- **No exact status code.** The agent reads the output (traceback / `Error:`) to
  judge success, exactly like a person. This is an explicit, accepted trade-off.
- **Generalize.** Not Python/R/Node-specific; any line-oriented REPL
  (IPython, Julia, Ruby `irb`, `psql`, …) should work, because the prompt is
  learned dynamically rather than hard-coded.

## Non-goals / out of scope

- **Shell-exec sentinels stay.** `ssh_session_exec` / `wsl_session_exec` (and the
  local shell-exec path) keep their `__WISPTERM_AGENT_*__` sentinel machinery —
  that is a different context and not part of this complaint. Only the REPL paths
  change. The shared helpers `hasPendingAgentCommand`, `extractUnixCommandResult`,
  `findCompletedEnd` remain in use by shell-exec and must not be removed.
- **Codex / Claude Code stay on their existing waiter.** `repl=codex` /
  `repl=claude_code` are full-screen TUI apps, not line REPLs; they keep
  `waitForAgentAppReplResult` with its busy-marker gates (`replSnapshotLooksBusy`).
- **Bracketed paste is not adopted now.** It is not universally supported
  (classic CPython < 3.13 ignores the markers), so it is left as a possible future
  enhancement, not part of this change.

## Design

### 1. One general line-REPL engine

Replace three things with a single engine:

- `pythonSessionEvalTool` (sentinel `exec()` wrapper)
- `rSessionEvalTool` (sentinel `tryCatch`/`eval(parse)` wrapper)
- the crude fixed-wait `.plain` branch in `plainReplInputTool`
  (lines ~1196–1204: it just sleeps up to 5000 ms then snapshots)

New behaviour for `repl` ∈ { `r`, `python`, `plain`, and any other non-TUI REPL }:

1. **Capture the current prompt** before sending: take a surface snapshot and
   extract the trailing prompt — the last non-empty line (trimmed). Examples:
   `>>> `, `> `, `In [3]: `, `julia> `, `dbname=# `.
2. **Send raw input**: write `code` + Enter (`\r`). No wrapper, no markers.
   (Codex's paste-burst special-case in `plainReplInputTool` is preserved as-is.)
3. **Wait for the prompt to return / screen to settle** (new
   `waitForReplPromptReturn`, modelled on `waitForAgentAppReplResult`):
   - Poll the per-surface snapshot (NOT `collectSnapshot` — the tab model is
     thread-local to the UI thread and reads empty on the worker; see the existing
     comment in `waitForAgentAppReplResult`).
   - Settle when the screen has been **unchanged for `quiet_ms`** (~800–1200 ms)
     after a `min_wait_ms` floor, **and** the last line looks like a ready prompt:
     the captured prompt reappeared, or it matches a generic ready-prompt heuristic.
   - Prompt-match only makes it return *faster*; **quiescence is the backstop** so
     exotic/custom prompts still terminate.
   - On `timeout_ms` exceeded → return the latest snapshot with the existing
     "still waiting … treat this as in progress, not a final result" note.
4. **Return the raw snapshot.** No status line, no synthesised success/failure —
   the agent reads the traceback/output itself.

### 2. Pure helpers (TDD targets)

These are pure string functions, unit-testable by feeding snapshot strings — no
terminal required:

- `extractPromptLine(snapshot: []const u8) []const u8` — last non-empty line,
  trimmed; "" if none.
- `looksLikeReadyPrompt(line: []const u8) bool` — generic heuristic: trimmed line
  ends with one of `>`, `:`, `$`, `#`, `)` followed by an optional single space,
  and is short (e.g. ≤ ~64 chars) so it is a prompt, not output. Plus exact-match
  against the captured prompt.
- A settle predicate combining "unchanged for quiet_ms" + ready-prompt, factored so
  it can be tested independently of the polling loop.

### 3. Prompt guidance (fixes verbose code)

The **live** system prompt is `src/platform/agent_prompt.zig` (note: `src/prompt.md`
is NOT the live prompt but is kept in parity). Add guidance near the existing
`terminal_repl_exec` lines, in substance:

- Send code exactly as you would type it at the REPL prompt.
- The REPL echoes the value of the last expression — do **not** wrap results in
  `print(...)` / `cat(...)` just to see them.
- Send the **direct** answer, not multiple alternative solutions or commentary.
- Keep multi-line code compact: no blank lines inside an indented block (a blank
  line can close the block early in a line REPL).

Update `src/prompt.md` to match (parity only; it is not the runtime prompt).

### 4. Multi-line handling

Raw-send only. Correct multi-line formatting (no intra-block blank lines) is carried
by the prompt guidance in §3, the same way a careful human pastes into a REPL. No
language-specific wrapping is reintroduced. (Decision confirmed with user; bracketed
paste deferred — see non-goals.)

## Files touched

- `src/ai_chat_tools.zig`
  - Remove `pythonSessionEvalTool`, `rSessionEvalTool` (sentinel REPL wrappers).
  - Route `.python`, `.r`, `.plain` through the new general engine.
  - Add `waitForReplPromptReturn` + pure helpers (`extractPromptLine`,
    `looksLikeReadyPrompt`, settle predicate).
  - Keep `.codex` / `.claude_code` → `waitForAgentAppReplResult` unchanged.
  - Keep shell-exec sentinel helpers (`hasPendingAgentCommand`,
    `extractUnixCommandResult`, `findCompletedEnd`) — still used by shell exec.
  - Remove now-dead REPL-only helpers if any (`pythonStringLiteral`/`rStringLiteral`
    only if no remaining caller — verify before deleting).
- `src/platform/agent_prompt.zig` — REPL usage guidance (runtime prompt).
- `src/prompt.md` — parity copy of the guidance.
- Tests in `src/ai_chat_tools.zig` (or the posix test file if libc-dependent) for
  the pure helpers.

## Testing

- Unit: `extractPromptLine` (various trailing-prompt shapes, blank lines, empty).
- Unit: `looksLikeReadyPrompt` (true for `>>> `, `> `, `In [3]: `, `julia> `,
  `dbname=# `; false for output lines, long lines, tracebacks).
- Unit: settle predicate (unchanged+ready → settled; changed → not; ready but still
  changing → not).
- `zig build test` and `zig build test-full` both green.
- Manual GUI smoke (deferred to user / later): `repl=python` `code="1+1"` shows
  `>>> 1+1` / `2` and nothing else; an error shows the native traceback; a
  multi-statement snippet still terminates.

## Risks

- **False-early settle** if the REPL pauses mid-computation with a prompt-looking
  line: mitigated by the `quiet_ms` floor + last-line ready-prompt check; same class
  of risk the existing quiescence waiter already accepts.
- **Classic-Python multi-line blank-line breakage**: accepted; mitigated by prompt
  guidance (§3/§4). Worst case the agent sees the error in the snapshot and retries —
  human-like recovery.
- **Loss of exact error status**: accepted by design; the agent reads the traceback.
