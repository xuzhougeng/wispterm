# `ask_user` — agent-consults-user tool (Copilot card + WeChat prompt)

**Date:** 2026-06-18
**Status:** Implemented (2026-06-19) — `zig build test`, `test-full` (native + windows-gnu under wine), and the windows-gnu cross-compile all green. GUI / WeChat (Windows-only) smoke verification pending.
**Branch:** `ask-user-consult-tool`

## Implementation notes (as built)

A few details settled during implementation, deviating slightly from the design above:

- **WeChat push rides the transcript snapshot, not a poller vtable accessor.** A
  pending question is emitted as a `Question:` section in `allocRemoteSnapshot`
  (sibling of `Approval:`), `reply_progress` detects it (`needs_question` +
  `question_text`), and the poller wraps it with the Chinese prompt and pushes
  once via a second `ApprovalAnnouncer`. So `question_reply.formatPrompt` was not
  needed and was dropped; `question_reply.classify(text, n)` (digit→option, else
  custom, empty→ignore) is the only pure piece, used by the inbound router.
- **Vtable gained two entries** (across all 7 implementers): `ai_question_option_count`
  (0 = none pending; the router needs the count to classify) and
  `resolve_ai_question(types.QuestionReply)`. `aiQuestionPending()` = count > 0.
- **Copilot answer = composer submit**, classified identically to WeChat (a digit
  in range → option, else custom) via an inlined `digitOption` in `ai_chat.zig`
  (no weixin dependency). Plus click on an option row (`HitTarget.question_option`).
  The card caps visible options at `MAX_VISIBLE_QUESTION_OPTIONS = 6`; extra
  options stay answerable by typing the number. Arrow-key row navigation deferred.
- **AskResult is `{ option_index, custom, cancelled }`**; the executor maps
  `option_index` back to its own parsed `options[i]` for the result label, so the
  Session need not retain option labels past the blocking call.

## Problem

The Copilot agent (and any AI-chat session) can read, run, and write, but it has
no first-class way to **stop and ask the user a multiple-choice question**. Today
the only mid-turn user interaction is the binary tool-**approval** prompt
(approve/deny). When the agent hits a genuine fork — "which database?", "which of
these three files did you mean?", "deploy to staging or prod?" — it must either
guess, or dump the choices into prose and hope the user answers in free text on
the next turn (losing the blocking, structured nature of the decision).

Claude Code solves this with `AskUserQuestion`: the agent presents a question +
labelled options, the UI pops up a selectable card, and the chosen answer is fed
back as the tool result. This spec brings the same capability to WispTerm's
Copilot, **and** routes it over the WeChat bridge so a remote user (away from the
machine) can answer the same question — the "微信要注意类似的提示" the user
flagged.

## Goal

Add an agent tool `ask_user` that:

1. Presents one question plus 2–N options, each with a `label` and optional
   one-line `description`.
2. **Blocks the agent** until the user answers (mirrors the approval flow — the
   agent needs the answer to proceed), then returns the chosen answer as the tool
   result.
3. In the **Copilot** chat panel: renders a selectable card (click a row, press a
   digit `1–9`, or arrow+Enter); the chat composer's next submit is accepted as a
   **free-text custom answer**.
4. Over **WeChat**: pushes the question + numbered options once, and accepts a
   reply that is either a digit (`1..N` → that option) or any other text (→ a
   custom free-text answer).

## Decisions (locked with the user)

| Question | Decision |
|---|---|
| Answer model (v1) | **One question, single-select, N options + free-text custom answer.** No multi-question batches, no multi-select. |
| Option shape | **`{label, description}`** — label plus an optional one-line description (richer, self-explaining options, like Claude Code). |
| Does it block the agent? | **Yes** — synchronous, mirroring `requestApproval`. The worker thread waits for the answer (or cancellation). |
| Copilot UI surface | **A selectable card in the chat panel**, same visual family as the approval card — *not* a new centered full-window modal. Avoids the `anyBlockingOverlayVisible` plumbing and keeps the UX consistent. |
| Copilot free-text mechanism | **The chat composer's next submit** becomes the custom answer while a question is pending. No separate inline text field. |
| WeChat reply parsing | Digit `1..N` → that option; exact whole-string (trimmed, ASCII-case-insensitive) match to a label → that option; **anything else → custom free-text answer** (consultation, unlike binary approve/deny). |
| Tool name | **`ask_user`** (snake_case, consistent with `terminal_list` / `read_file`). |

### Explicit non-goals (YAGNI)

- No multiple questions per call, no multi-select. (Full Claude-Code parity was
  considered and rejected for v1.)
- No persistent state across restarts — a pending question lives only for the
  blocked worker call.
- Not available to the **subagent** — a subagent has no user channel and is
  already documented as unable to ask questions.
- No change to the `wisptermctl` / web-remote input paths beyond a graceful
  "no interactive user" result when there is no answer channel.
- No timeout/auto-pick — it blocks until answered or the agent is stopped, exactly
  like approval.

## Key architectural facts (verified against current code)

- **Approval is the exact template.** `Session.requestApproval(tool, command,
  reason)` (`ai_chat.zig:1739`) copies the prompt under `approval_mutex`, sets
  `approval_pending`, then blocks on `approval_cond.wait` until `approval_resolved`
  (or `closing`/`stop_requested`). `approvalView()` (`:1703`) exposes the pending
  prompt to the UI; `resolveApprovalExternal(approve)` (`:1735`) unblocks it. The
  question flow is a structural copy with an N-option payload and an
  index-or-text resolution.
- **Tool schemas** are emitted in `ai_chat_protocol.zig` via
  `Filtered.emitTool(ctx, opts, name, description, properties_json)` (`:690+`),
  and `input_schema` reuses the same JSON-Schema object as the OpenAI
  `parameters` (`:771`).
- **Subagent gating** is centralized: `subagent_allowed_tools`
  (`ai_chat_protocol.zig:658`) + `subagentToolAllowed()` (`:664`) gate both schema
  emission and execution. `ask_user` is simply **not added** to that list.
- **Tool execution** dispatches in `ai_chat_tools.zig` `executeToolCall`
  (`:46`); the executor is wired to the `Session` through the `ToolContext`
  vtable used by `ai_chat_request.zig` (`toolApprove`/`toolCancelled`/`toolNote`
  at `:747+`).
- **WeChat reply routing chokepoint:** in `weixin/agent.zig:206`, an inbound
  message first checks `ctrl.aiApprovalPending()`; if pending it runs
  `approval_reply.classify(text)` → `resolveAiApproval(bool)`, otherwise the text
  flows on as a normal prompt. The question check slots in right here as a
  sibling branch.
- **WeChat push** is built in `poller.zig` `allocProgressText` (`:691`) from a
  progress struct carrying `needs_approval` + `approval_command`/`approval_tool`,
  and announced exactly once per episode by `ApprovalAnnouncer.due()` (`:775`).
- **The `Control` vtable has many implementers.** `resolve_ai_approval` /
  `ai_approval_pending` appear in: the real poller control, **three fake/test
  controls in `poller.zig`** (~`:974`, ~`:1346`, ~`:1453`), the `Noop` control in
  `control.zig` (~`:176`), and the `agent.zig` test fake (~`:410`). Every new
  vtable entry must be added to **all** of them or `zig build test-full` breaks
  (the bare `test` build misses some). This was the main footgun of the
  `/list`+`/switch` work.

## Architecture

Four layers, mirroring the approval flow end-to-end.

### 1. Blocking state & API on `Session` (`ai_chat.zig`)

A parallel slot to the approval one. Because a question carries a variable-length
option list, it is stored as an owned, allocator-backed structure rather than
fixed buffers:

```zig
pub const QuestionOption = struct { label: []const u8, description: []const u8 };

// pending question payload (owned by Session, freed on resolve)
question_pending: bool = false,
question_resolved: bool = false,
question_text: []const u8 = "",          // owned
question_options: []QuestionOption = &.{}, // owned (labels+descriptions owned)
question_answer: ?[]const u8 = null,       // owned; null until resolved/cancelled
question_answer_is_custom: bool = false,
// reuses approval_mutex/approval_cond? No — separate question_mutex/question_cond
// to keep the two independent and avoid accidental cross-wakeups.
```

New methods:

- `askUser(question, options) -> AskResult` — copies the payload under
  `question_mutex`, sets `question_pending`, blocks on `question_cond.wait` until
  `question_resolved` / `closing` / `stop_requested`, then returns:
  - `.{ .option_index = i }` when an option was chosen,
  - `.{ .custom = "<text>" }` when a free-text answer was given,
  - `.cancelled` when stopped/closed without an answer.
- `questionView() -> ?QuestionView` — `{ question, options }` for the UI
  (parallel to `approvalView`).
- `resolveQuestionOption(index) bool` / `resolveQuestionCustom(text) bool` —
  external resolvers (UI click/key, WeChat) that store the answer and signal the
  cond. Out-of-range index → no-op returns false.
- Cancellation: `closing`/`stop_requested` already break the wait loop; the
  existing cancel paths need no new logic beyond signalling `question_cond`
  alongside `approval_cond` where they currently broadcast.

The tool result string returned to the model:

- option → `User selected option N: "<label>"` (+ `— <description>` if present).
- custom → `User answered (custom): "<text>"`.
- cancelled → `User did not answer (request cancelled).`

### 2. Tool schema & executor

- **Schema** (`ai_chat_protocol.zig`, new `emitTool` call):

  ```
  ask_user — "Ask the user a single multiple-choice question and block until they
  answer. Use when you hit a genuine decision you should not guess (which target,
  which of several matches, a risky direction). Provide 2+ options; the user can
  also type a custom answer. Returns the user's choice."
  properties:
    question:  {type:string}
    options:   {type:array, items:{type:object,
                 properties:{label:{type:string}, description:{type:string}},
                 required:[label]}}
  ```
  Not added to `subagent_allowed_tools`.

- **Executor** (`ai_chat_tools.zig`): `askUserTool(ctx, args)` parses
  `question` + `options` (reusing `parseArgs`/`jsonStringArg` helpers), validates
  `options.len >= 2` (else returns an error string telling the model to supply ≥2
  options), then calls through a new `ToolContext` hook to `Session.askUser`,
  and formats the `AskResult` into the tool-result string above. The hook is added
  to the `ToolContext` vtable in `ai_chat_request.zig` next to
  `toolApprove`/`toolCancelled`/`toolNote`.

### 3. Copilot UI (`ai_chat_layout.zig` + `AppWindow.zig`)

- **Pure layout helper** `questionLayout(cell_h, n_options, has_descriptions)` in
  `ai_chat_layout.zig`, alongside `approvalLayout`, unit-tested the same way
  (rows never overlap as the UI font grows; bottom row always within the card).
- The card renders in the chat panel: the question, then one selectable row per
  option (`N) label — description`), then a hint line ("点选项，或在下方直接输入你的
  答案 / click an option or type your own answer below").
- Because options carry descriptions the card can be tall → apply the
  **row-capacity clamp + selection-follow scroll** pattern established by the
  short-window overlay fixes (#233/#238) so the last option is always reachable in
  short windows.
- Resolution channels in `AppWindow.zig`:
  - **Click** a row → `resolveQuestionOption(i)`.
  - **Digit `1–9`** / **arrow+Enter** while the card is focused → same.
  - **Composer submit** while `questionView()` is non-null → intercept the
    submission and route it to `resolveQuestionCustom(text)` instead of starting a
    new user turn. (One guarded branch at the composer-submit site.)
  - **Esc / stop** → cancel (existing stop path).

### 4. WeChat flow (`weixin/question_reply.zig`, `agent.zig`, `poller.zig`, vtable)

- **New pure module `weixin/question_reply.zig`** (sibling of `approval_reply.zig`),
  fully unit-tested:
  - The reply type is defined **once** in `weixin/types.zig` (which `control.zig`
    and `agent.zig` already import) and reused everywhere — no duplicate union:
    `pub const QuestionReply = union(enum) { option: usize, custom: []const u8, ignore };`
  - `pub fn classify(text, n_options) QuestionReply` — empty/whitespace-only →
    `.ignore` (leave the question pending, exactly as `approval_reply` returns
    `unrecognized` for empty); trimmed digit in `1..n` → `.{ .option = d-1 }`;
    otherwise `.{ .custom = trimmed }`. (Label matching is done by the resolver,
    which has the labels; the pure parser only needs `n`.)
  - `pub fn formatPrompt(writer, question, options) !void` — emits
    `请选择：<question>\n1. <label> — <description>\n…\n回复序号，或直接输入你的答案`.
    Pure/streamed so it is testable without a Session.
- **Reply routing** (`agent.zig`, mirroring the approval branch at `:206`): add a
  sibling check `if (ctrl.aiQuestionPending()) { ... }` that pulls the option
  count, runs `question_reply.classify`, and — unless the result is `.ignore`
  (empty reply, leave pending) — calls `resolveAiQuestion(reply)`. Order relative
  to the approval check is immaterial (the two states are mutually exclusive — the
  worker blocks on one at a time), but the question branch is placed first for
  clarity.
- **Push** (`poller.zig`): extend the progress struct with `needs_question` +
  a preformatted `question_text` (built via `question_reply.formatPrompt` from the
  Session's pending question), and a `QuestionAnnouncer` (or a generalized
  announcer) so it is pushed exactly once per episode, exactly like
  `ApprovalAnnouncer`.
- **Control vtable** (`control.zig`): two new entries + wrapper methods —
  - `ai_question_pending: *const fn (ctx) bool`
  - `resolve_ai_question: *const fn (ctx, reply: types.QuestionReply) bool`
    using the single `types.QuestionReply` union defined in `weixin/types.zig`
    (the `.ignore` variant never reaches the vtable — the router drops it).
  Added to **every** implementer: real poller control, the three fake pollers, the
  `Noop` control, and `agent.zig`'s test fake.
- **GUI marshaling** (`AppWindow.zig`): two new `WeixinRequest` ops
  `ai_question_pending` / `resolve_ai_question`, resolved against the same
  pin-aware `weixinActiveAiTabIndex()` target the approval ops use, calling the new
  `Session` methods. For `resolve_ai_question` with a `.custom` reply, the bytes
  are copied into the request buffer (bounded, like the existing command buffer).

## Data flow

```
Agent decides to ask:
  worker → ask_user executor → Session.askUser(question, options)  [BLOCKS]

Answer via Copilot:
  click/digit/arrow → AppWindow → Session.resolveQuestionOption(i)  → cond signal
  composer submit   → AppWindow → Session.resolveQuestionCustom(t)  → cond signal
  → askUser returns → executor formats result → tool result → model continues

Answer via WeChat:
  poller tick: progress.needs_question → QuestionAnnouncer.due → formatPrompt
            → push numbered question once
  inbound reply: agent.route → ctrl.aiQuestionPending()? yes
            → question_reply.classify(text, n) → ctrl.resolveAiQuestion(reply)
            → weixinDispatch(resolve_ai_question) [UI thread]
            → Session.resolveQuestionOption / resolveQuestionCustom → cond signal
  → askUser returns → model continues; bridge resumes normal transcript polling
```

## Reply / card formats (illustrative)

Copilot card:

```
❓ Which database should I target?
 1) Postgres — prod default, JSONB support
 2) SQLite — zero-config, local dev
 3) MySQL — legacy compatibility
点选项，或在下方直接输入你的答案
```

WeChat push:

```
请选择：Which database should I target?
1. Postgres — prod default, JSONB support
2. SQLite — zero-config, local dev
3. MySQL — legacy compatibility
回复序号，或直接输入你的答案
```

WeChat replies: `2` → selects SQLite; `用 DuckDB` → custom answer "用 DuckDB".

## Error handling & edge cases

- **< 2 options:** executor returns an error string ("ask_user needs at least 2
  options") to the model rather than presenting a degenerate question.
- **Agent stopped / session closing while pending:** the wait loop breaks;
  `askUser` returns `.cancelled`; the model gets "User did not answer (request
  cancelled)." and can decide how to proceed.
- **No interactive channel** (e.g. invoked in a context with neither a visible
  Copilot card nor a WeChat reply path): there is always a UI card for a Copilot/
  AI-chat session, so this is effectively the cancellation case if the user never
  answers; no special hang. `wisptermctl`-style headless paths are out of scope.
- **Out-of-range digit on WeChat** (e.g. `9` when 3 options): classified as a
  custom answer (it is not a valid option index), so the model receives `"9"` as
  a free-text answer rather than silently mis-selecting. Acceptable and honest.
- **Empty / whitespace-only WeChat reply while pending:** classified `.ignore`;
  the router does nothing and the question stays pending (no accidental empty
  custom answer).
- **Composer submit when no question pending:** unchanged — starts a normal user
  turn (the guard only diverts while `questionView()` is non-null).
- **Question + approval cannot both be pending:** the worker blocks on one tool
  call at a time, so the two states are mutually exclusive; the WeChat router and
  the UI handle each independently.

## Testing (TDD)

- **`weixin/question_reply.zig`** unit tests: digit selection (`1`, `  3 \n`),
  out-of-range digit → custom, non-numeric → custom, empty/whitespace → `.ignore`,
  CJK custom answers; `formatPrompt` output (numbering, `—` description join,
  no-description case, trailing hint).
- **`ai_chat_layout.zig`**: `questionLayout` rows never overlap as `cell_h` grows;
  card height honors the row-capacity clamp for many options.
- **`ai_chat.zig`**: `askUser` blocks then returns the resolved option / custom /
  cancelled; `resolveQuestionOption` out-of-range returns false; `questionView`
  reflects pending state and clears on resolve; ownership/free correctness (no
  leak on resolve or cancel).
- **`ai_chat_protocol.zig`**: `ask_user` appears in the full toolset schema and is
  **absent** from the subagent toolset; `subagentToolAllowed("ask_user") == false`.
- **`weixin/agent.zig`**: route test — with `aiQuestionPending` true, a `2` reply
  calls `resolveAiQuestion(.{.option=1})` and a free-text reply calls
  `resolveAiQuestion(.{.custom=...})`; with it false, text flows as a normal
  prompt. Extend the `FakeControl` with the two new vtable entries.
- **`control.zig`**: Noop control gains the two methods (compile coverage).
- `zig build test` + `zig build test-full` + windows-gnu cross-compile all green.
  WeChat bridge GUI smoke is Windows-only and verified separately.

## Files touched (anticipated)

- **New:** `src/weixin/question_reply.zig` (pure parser + prompt formatter +
  tests).
- `src/ai_chat.zig` — question blocking state, `askUser` / `questionView` /
  `resolveQuestionOption` / `resolveQuestionCustom`, cancel-path cond signal.
- `src/ai_chat_types.zig` — `QuestionOption` / `QuestionView` / `AskResult` types
  (alongside `ApprovalView`).
- `src/ai_chat_tools.zig` — `ask_user` executor + arg parsing/validation.
- `src/ai_chat_request.zig` — `ToolContext` hook to `Session.askUser`.
- `src/ai_chat_protocol.zig` — `ask_user` schema emission (full toolset only).
- `src/ai_chat_layout.zig` — `questionLayout` pure helper + tests.
- `src/AppWindow.zig` — card render/click/keys, composer-submit-as-answer guard,
  two new `WeixinRequest` ops + handlers + vtable wrappers.
- `src/weixin/control.zig` — `QuestionReply` type, two vtable entries + wrappers,
  Noop control update.
- `src/weixin/agent.zig` — question reply-routing branch, `FakeControl` update,
  `/help` mention if warranted.
- `src/weixin/poller.zig` — progress `needs_question`/`question_text`,
  `QuestionAnnouncer`, all three fake-control updates.
