# Agent `continue_later` Tool Design

**Date:** 2026-07-03
**Status:** Design approved, pending spec review
**Component:** WispTerm AI Agent / Copilot scheduled prompts

## Summary

Add a first-party Agent tool, `continue_later`, that lets the model schedule
itself to resume a long-running task later. When an SSH/session/REPL command is
still running, the Agent should avoid re-running the command or repeatedly
polling the terminal. Instead, it calls `continue_later` with a delay such as
`30m` and a short follow-up prompt such as:

```json
{"delay":"30m","message":"Continue the previous task. First inspect the terminal with terminal_snapshot, then report progress."}
```

The tool reuses the existing `/watch` one-shot scheduler and session injector:
at the scheduled time, WispTerm submits the follow-up prompt back into the same
AI Chat or Copilot session as if the user typed it.

## Goals

- Let the Agent decide to pause and resume later when a task is still running.
- Reuse the existing `/watch` scheduled-prompt store, persistence, and tick path.
- Avoid duplicate command execution while long-running terminal work is still in
  progress.
- Keep the implementation inside the Agent/scheduler layer; do not touch the
  terminal core, renderer, or input dispatch.
- Keep the behavior testable with small unit tests around parsing,
  registration, schema emission, and dispatch.

## Non-goals

- A new scheduler, worker thread, or background Agent loop.
- Event-driven wakeups based on terminal output, file changes, or process exit.
- A visible task-manager UI beyond the existing `/watch`/`/loop` listing paths.
- Auto-resuming a closed chat tab by creating a new UI session.

## Ghostty Comparison

Ghostty has no equivalent AI Agent, tool-calling runtime, or scheduled prompt
system. Its relevant design lesson is separation of terminal core from host/UI
coordination: terminal emulation and rendering should not own application-level
automation. WispTerm should keep `continue_later` above the platform-neutral
terminal core, in the existing Agent tool and `/watch` scheduler layer.

## User-Facing Behavior

`continue_later` is advertised as a first-party Agent tool.

Arguments:

- `delay`: required interval string, same unit grammar as `/loop`:
  `<positive integer><s|m|h|d>`, for example `30m`, `2h`, or `1d`.
- `message`: optional follow-up prompt. If omitted or empty, WispTerm uses a
  concise default prompt that tells the Agent to continue the previous task and
  inspect the terminal before acting.

Runtime result:

- On success, the tool returns a confirmation with the scheduled task id and
  delay, for example `Scheduled continuation #42 in 30m.`
- On invalid delay, missing scheduler, or allocation failure, it returns a plain
  tool result explaining the failure.

At fire time:

- If the bound session is open and idle, the scheduler submits `message` to that
  session.
- If the session is busy, the task remains due and retries on a later scheduler
  tick. It does not create duplicate prompts.
- If the session is closed, the task remains in the persistent `/watch` store
  and can fire when the session is reopened, matching current `/watch` behavior.

## Architecture

### Scheduler Reuse

Do not introduce a new persistence file or timer. Add a small programmatic
registration helper to `src/assistant/loop/store.zig` that creates a one-shot
watch task from an already-parsed delay:

- compute `next_fire_ms = now_ms + delay_ms`;
- set `kind = .watch`, `daily = false`, `remaining = 1`;
- capture the current `SessionCtx` (`session_id`, `model`, `title`);
- append and persist through the same store path used by `/watch`.

This keeps restart behavior, busy retry, closed-session handling, and
`loop_tasks.json` compatibility in one place.

### Tool Catalog And Schema

Add `continue_later` to:

- `src/tools/first_party.zig` so Skill Center and disabled-tool state know about
  the tool.
- `src/assistant/conversation/protocol.zig` so Chat Completions, Responses, and
  Anthropic requests all expose the same tool schema.
- `builtinToolNameReserved` so imported dynamic tools cannot reuse the name.

The tool belongs to the Agent category, not terminal or file.

### Tool Dispatch

Add an `agent_tools/schedule.zig` leaf module or a focused function in
`agent_tools/mod.zig`. It should:

1. Parse `delay` with the existing `ai_loop_schedule.parseIntervalMs`.
2. Resolve `ai_loop_store.active()`.
3. Build `SessionCtx` from an explicit scheduling context on `ToolContext`.
4. Register the one-shot watch task.
5. Return a short confirmation string.

The dispatch must not import `AppWindow.zig`; the existing scheduler active
store is the boundary.

`ToolContext` does not currently carry session identity, and the leaf tool layer
must not reach back into `Session`. Add a small `ScheduleContext` with borrowed
`session_id`, `model`, and `title` fields to the request/session seam:

- `Session.buildRequestLocked` fills owned/borrowed values on `ChatRequest`;
- the request-to-tool adapter copies those fields into `ToolContext`;
- `continue_later` returns `Scheduler context is not available.` if the context
  is absent.

### Prompt Guidance

Update `src/platform/agent_prompt.zig` so the default Agent prompt says:

- when a terminal command or REPL app is still running, do not re-run it;
- schedule `continue_later` when a sensible waiting period is better than
  immediate polling;
- the follow-up should inspect progress with `terminal_snapshot` first.

Also update `agent_tools/exec.zig` timeout/busy messages so they point at
`continue_later` instead of only saying "re-check later".

## Data Flow

```text
terminal_repl_exec reports "still running"
  -> model calls continue_later(delay="30m", message="Continue ...")
  -> tool registers one-shot watch task bound to this session
  -> existing scheduler tick sees it due later
  -> loopInjector calls session.submitScheduledPrompt(message)
  -> Agent continues from the same conversation context
```

## Error Handling

- Bad or missing `delay`: return `Bad delay. Use a positive interval like 30m,
  2h, or 1d.`
- Scheduler inactive: return `Scheduler is not available.`
- Empty `message`: use the default continuation prompt rather than failing.
- Disabled tool: existing first-party disabled-tool guard returns
  `Tool is disabled: continue_later`.

## Testing

Add focused tests:

- `assistant/loop/store.zig`: programmatic one-shot watch registration stores
  `daily=false`, `remaining=1`, and `next_fire_ms=now+delay`.
- `assistant/conversation/protocol.zig`: full tool schemas include
  `continue_later`, `delay`, and `message`; subagent schemas do not include it.
- `tools/first_party.zig`: active definitions include `continue_later`.
- `agent_tools/mod.zig` or the new schedule leaf module: invalid delay returns a
  clear tool result; successful registration returns the scheduled id.
- `platform/agent_prompt.zig`: prompt guidance mentions `continue_later` and
  still-running terminal work.

Run `zig build test` during implementation and `zig build test-full` before
finishing the change.
