# Copilot subagent tool — design

**Date:** 2026-06-12
**Worktree:** `copilot-repeat-problem`
**Status:** Implemented (suites green; GUI verify pending)

## Goal

Keep the main Copilot conversation context small by letting the model delegate
self-contained research tasks to a **subagent**: a nested agent loop with its
own transcript, a restricted read-only toolset, and (optionally) its own model
profile. Only the subagent's final report returns to the main transcript as the
tool result; all intermediate tool output (webread full text, dozens of search
results) stays in the subagent's private transcript and is freed when it ends.

### Motivation

A field incident showed the agent loop accumulating ~320k input tokens in one
conversation (every tool result stays in the transcript forever and is re-sent
each round — `runAgentRequest` in `src/ai_chat_request.zig`). Near the context
limit the model produced degenerate repetition (the whole answer emitted
twice). The dominant contributors were research-type tool outputs: `webread`
full text and many `websearch`/`pubmed` rounds. Delegating those to a subagent
removes them from the main context entirely.

Transcript compaction / a global context budget for the main loop is
complementary future work, explicitly out of scope here.

## Key decisions (from brainstorming)

1. **Read-only research toolset** for the subagent: `terminal_list`,
   `terminal_snapshot`, `read_file`, `websearch`, `webread`, `pubmed`,
   `wispterm_docs`. No exec, no file writes, no tabs, no memory tools, and no
   `subagent` itself (recursion depth 1). Every allowed tool is approval-free,
   so a subagent never raises approval prompts.
2. **Progress is forwarded** to the main chat as `.tool`-role progress
   messages (`subagent: running websearch …`), reusing
   `appendProgressMessage`. Progress messages do not enter the request
   context.
3. **Configurable model profile**: new config key `ai-subagent-profile` names
   an existing saved AI profile to run the subagent on (e.g. a cheaper/faster
   model). Unset or unresolvable → fall back to the main conversation's
   credentials. Never an error.
4. **Implementation route A — nested loop**: intercept the `subagent` tool
   call in `ai_chat_request.zig`'s `executeToolCall` wrapper and run a nested
   mini agent loop (`runSubagentTask`) synchronously on the same worker
   thread. No hidden Session, no UI machinery, reuse
   `runChatRequestForMessages` for the network layer.
5. **Sequential v1**: multiple `subagent` calls in one assistant turn run one
   after another in the existing tool-call order. No parallelism.

## Tool definition

New entry in `forEachToolSpec` (`src/ai_chat_protocol.zig`):

- **name**: `subagent`
- **args**: `task` (string, required) — a complete, self-contained task
  description: what to research/read, and what the report must contain.
- **description** (essence): "Delegate a self-contained research or
  reading task to a background subagent with its own context window. The
  subagent can search the web, read pages/files/PDFs, query PubMed, and read
  terminal snapshots, then returns only a final report. Use it for any task
  that would pull large tool output (full-page reads, many searches) into this
  conversation. The subagent cannot see this conversation: include all needed
  context in `task`."

### Toolset gating

`forEachToolSpec`'s `opts` grows from `{ include_memory: bool }` to
`{ include_memory: bool, toolset: enum { full, subagent } }`:

- `full` (main agent requests): all existing tools + `subagent`.
- `subagent` (nested requests): only the seven research tools listed above.
  No `subagent`, no memory tools regardless of `include_memory`.

`RequestParams` gains a `toolset` field, passed through `buildRequestJson` to
all three protocol emitters (chat-completions / responses / anthropic), which
already share `forEachToolSpec` as the single schema source.

Defense in depth: the nested loop's dispatcher also checks
`subagentToolAllowed(name)` (pure allow-list) before executing, so a
hallucinated tool name outside the restricted set is rejected with a plain
"tool not available in subagent" tool result.

## Nested loop: `runSubagentTask` (src/ai_chat_request.zig)

Interception: in `executeToolCall(request, call)` — the wrapper that already
bridges `ChatRequest` → `ai_chat_tools.executeToolCall` — a `call.name ==
"subagent"` branch parses `task` and calls `runSubagentTask` instead of
entering `ai_chat_tools` (the leaf tool module stays free of network/loop
dependencies).

`runSubagentTask(request, task)`:

1. Builds a fresh transcript: one user message containing `task`.
2. Builds a stack-local `ChatRequest` derived from the parent:
   - shares `session` (cancellation checks), `tool_host`, `tool_snapshot`,
     settings, `write_context_surface_id`;
   - overrides `base_url`/`api_key`/`model`/`protocol`/`thinking_enabled`/
     `reasoning_effort`/`max_tokens` from the resolved subagent profile when
     present (see below), else keeps the parent's;
   - `system_prompt` = dedicated researcher prompt, a new constant in
     `platform/agent_prompt.zig` (NOT `prompt.md`, which is not the live
     prompt): you are a research subagent; finish the task with the available
     tools; you cannot ask questions back; return one final self-contained
     report including sources (URLs/paths); stop calling tools when done.
   - `memory_enabled` = false; toolset = `.subagent`; `stream` = false.
3. Runs the same loop shape as `runAgentRequest`: call
   `runChatRequestForMessages(sub_request, transcript, true)`; empty
   `tool_calls` → that content is the final report.
4. Per tool call: forward a progress line, check `subagentToolAllowed`, then
   dispatch through the same `ToolContext` as the parent.
5. Returns `{ report, usage, rounds }`. The report becomes the `subagent` tool
   result in the main transcript; `usage` is added into the main loop's
   `total_usage` so the displayed totals reflect real cost.

## Profile resolution (`ai-subagent-profile`)

- New config key `ai-subagent-profile` ([]const u8, default `""`), handled
  exactly like `ai-default-profile`: `applyKeyValue`, the preserved-keys list,
  and **startup load** (lesson from websearch: runtime config keys must load
  at startup via an App field, not only on config reload).
- AI profiles live in `renderer/overlays.zig` (`g_ai_profiles`, UI-thread
  state); the request worker must not touch them. Mirror the
  `setGlobalAgentSettings` seam: the overlays/profile layer resolves the named
  profile and pushes its fields into
  `ai_chat.setGlobalSubagentProfile(?SubagentProfile)` at startup, on profile
  save, and on config reload.
- `buildRequestLocked` (UI thread) dupes the resolved fields into
  `ChatRequest.subagent_profile: ?SubagentProfileOverride` (owned strings,
  freed in `ChatRequest.deinit`). The worker thread only ever reads its own
  request.
- Fields taken from the profile: `base_url`, `api_key`, `model`, `protocol`,
  `thinking`, `reasoning_effort`, `max_tokens`. The profile's own
  `system_prompt`, `stream`, `agent`, and `vision` fields are ignored.
- Fallback chain: key unset → profile name not found → any resolution failure
  ⇒ `subagent_profile = null` ⇒ nested loop uses the parent request's
  credentials. Never an error, never a user-visible warning.

## UI / progress

Reuses `appendProgressMessage` (`.tool` role; styled distinctly; excluded from
request context):

- start: the main loop's existing `running subagent {"task":…}` progress line
  already announces the launch — no extra start line.
- each tool round inside the subagent: `subagent: running <tool> <args>`
- end: `subagent: done (<N> rounds, <M> tokens)`

No new renderer work.

## Limits and error handling

- **No round cap**: the subagent decides when it is done, exactly like the
  main loop — the loop ends when the model returns no tool calls. The manual
  escape is the same as today: the user's stop action cancels the request
  (and with it the nested loop).
- **Report size**: final report passes through the existing `truncateOwned`
  (head-keeping, `settings.output_limit`) before returning.
- **Sub-model API/HTTP errors**: the error text becomes the report (existing
  `ApiResult.content` error-shaping), returned to the main model to decide how
  to proceed. The main loop is never aborted by a subagent failure.
- **Cancellation**: the nested loop checks `requestCancelled` before every
  model call and every tool call; `error.Canceled` propagates up the existing
  path (sub and main loop die together).
- **Bad args**: missing/empty `task` → tool result "Missing task".
- **Intermediate bloat inside the subagent** is bounded by the existing
  per-tool truncation; a sub-transcript budget is YAGNI for v1.

## Testing (TDD)

- **Schema tests** (pattern of existing `"agent request json includes tool
  schemas"`): full toolset includes `subagent`; subagent toolset includes
  exactly the seven research tools and excludes `subagent`, memory tools, and
  all exec/write tools — across all three protocols.
- **Pure helpers**: `subagentToolAllowed` allow-list; `task` argument parsing;
  report truncation; profile fallback resolution (set/unset/not-found).
- **Loop behavior**: `runSubagentTask` takes the model call as an injectable
  function (test seam, same spirit as existing tool-host seams) so tests can
  stub responses and cover: two-round happy path, cancellation mid-loop,
  disallowed-tool rejection, usage accumulation.
- Suites: `zig build test` and `zig build test-full` green; no network in
  tests.
