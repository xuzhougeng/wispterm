# In-session model switching with context handoff

**Date:** 2026-06-16
**Status:** Design approved, pending spec review
**Branch:** `slash-change-model`

## Problem

The model an AI chat session uses is fixed at creation time, read from a saved
AI profile (`AiProfile`: name + base_url + api_key + model + protocol + …). When
the active model errors or is overloaded mid-conversation — e.g. the screenshot
showing `glm-5.2` returning an `overloaded error` (code 1305) — the user has no
way to switch to another provider/model without losing the conversation. They
must open a new chat tab with a different profile and re-establish context by
hand.

## Goal

Let the user switch the active session to a different **saved AI profile**
without leaving the conversation, via two triggers:

1. A `/model` slash command in the composer.
2. A click on the model label at the top-left of the AI panel header (the
   `glm-5.2` text rendered at `ai_chat_renderer.zig:179`).

After switching, the **new model** reads the prior transcript and produces a
summary in the background; the old multi-turn history then collapses into a
single "上文摘要" card so the conversation continues seamlessly and future turns
stay cheap.

## Decisions (locked with the user)

| Question | Decision |
|---|---|
| What does "switch model" select from? | Saved AI profiles only (no free-text model entry). |
| How is prior context handed to the new model? | The **new** model reads the raw transcript and generates a summary, then continues. (Robust when the old model is the one that's overloaded/erroring.) |
| Is summarization blocking? | **No** — background/async. The user can keep typing immediately. |
| How is the old transcript shown after the summary lands? | Collapsed into a single collapsible **"上文摘要" card** (reusing the existing collapsible tool-message UI). |
| Does `/model <name>` switch directly? | Yes. `/model` with no arg opens the picker; `/model <profile-name>` (case-insensitive match) switches directly. |

### Explicit non-goals (YAGNI)

- No arbitrary/free-text model name entry — saved profiles only.
- Switching is **session-only**; it does **not** modify the global
  `ai-default-profile` config key (that remains the existing Settings cycler's
  job, governing only newly-opened sessions).
- The session's **system prompt / persona is not changed** by a switch — only
  the provider/model fields are swapped, so a Copilot stays a Copilot and a chat
  tab keeps its profile's persona.
- No cycle-on-click (each click → next profile). Click opens the picker, which
  scales to many profiles.

## Architecture

Reuses three established patterns in the codebase:

- **Slash command:** `SlashCommand` enum + `slash_command_entries` table in
  `ai_chat_composer.zig`, dispatched in `runBuiltinCommandLocked`
  (`ai_chat.zig`). Same shape as `/cwd`, `/permission`.
- **Header click target:** `permissionChipHitTest` (`ai_chat_renderer.zig`) +
  its handler in `input.zig` (`toggleAiAgentPermission`). A new
  `modelLabelHitTest` follows the identical structure.
- **Background one-shot model call:** `maybeAutoTitle` / `distillThreadMain`
  (`ai_chat.zig` / `ai_chat_request.zig`) — build a `ChatRequest` off the
  session config, spawn a worker thread, apply the result back under
  `session.mutex` with `closing`/cancellation guards.

### Components

#### 1. `src/ai_model_switch.zig` (new, pure, fast-suite tested)

Pure logic, no Session/GL/AppWindow dependency, unit-tested in the fast suite
(per the standing preference to extract UI glue into tested modules):

- `summarySystemPrompt() []const u8` — the compaction instruction.
- `buildSummaryUserContent(allocator, turns, caps) ![]u8` — render the snapshot
  transcript into a single user message, with per-message byte caps to bound
  tokens (mirrors `ai_chat_title.buildUserContent` + the limited-section helper).
- `shouldSummarize(turns) bool` — gate: true only when there is prior user +
  assistant content worth summarizing (empty/greeting-only conversation → swap
  config, skip the summary call).
- `matchProfileByName(names, query) ?usize` — case-insensitive exact match for
  `/model <name>` (returns null → caller opens the picker / reports unknown).
- `spliceSummary(allocator, messages, boundary, summary_text) ![]Message-ish` —
  given the message list, the recorded boundary, and the summary, produce the
  new list: messages `[0..boundary]` replaced by **one summary card message**;
  messages `[boundary..]` (anything typed after the switch) preserved. Returns
  the data needed; actual `Session.messages` mutation stays in `ai_chat.zig`.

**Summary card representation (provider-safe).** The collapsed card is a single
message with role **`.user`** and a new `is_context_summary: bool` flag, content
prefixed with a marker (e.g. *"（以下是切换模型前的对话摘要）\n<summary>"*). Using
`.user` — not `.tool` — keeps request-building valid on every provider (a
standalone `.tool`/tool_result message without a preceding `tool_use` is
rejected by the Anthropic protocol). Request-building includes the card verbatim
as ordinary user content; the renderer draws it as the collapsible "上文摘要"
card. This requires a small, bounded extension of the existing collapse
affordance (today tool-message-only via `content_collapsed`) to also honor
`is_context_summary`.

`SlashCommand.model_switch` and its `/model` (+ `/模型` alias) entry are added to
`ai_chat_composer.zig` with parser tests there.

#### 2. Live profile swap — `applyProfileToActiveChat(idx)` (overlays.zig)

Mirrors `spawnAiProfileWithAgentOverride`'s profile-field reading, but instead of
spawning a new tab it mutates `AppWindow.activeAiChat()` in place:

- Validate `base_url` is http(s) and `model` non-empty (same guards as spawn).
- `copyBaseUrl`, `copyApiKey`, `copyModel`; set `session.protocol`,
  `session.max_tokens`, and the thinking/reasoning/vision fields.
- Leave `system_prompt` and `copilot`/`agent_enabled` untouched.
- Trigger the summarization handoff (below).
- Mark the renderer dirty so the header model label refreshes immediately.

A new `AiListMode.switch_model` makes the existing profile picker overlay call
this on selection rather than spawning a tab. The picker is opened from the
`/model` (no-arg) path and the header click.

#### 3. Slash dispatch (`ai_chat.zig`)

In `runBuiltinCommandLocked`, `.model_switch`:
- No arg → request the picker (deferred action, opened after unlock, like
  `/resume`'s `resume_picker`).
- With arg → resolve via `matchProfileByName`; on hit, apply the profile + start
  the handoff; on miss, append a tool message listing available profile names.

#### 4. Header click target (`ai_chat_renderer.zig` + `input.zig`)

- `modelLabelRect` / `modelLabelHitTest` covering the model-label region at the
  top-left of the header (only when the label is actually drawn — it is hidden
  when the panel is too narrow, per the existing `model_limit > 24` guard).
- In `input.zig`, next to the `permissionChipHitTest` block, route a click on the
  label to open the `switch_model` picker for the active chat. A subtle hover
  affordance (cursor / underline) is optional polish.

#### 5. Background summarization + collapse (`ai_chat.zig` / `ai_chat_request.zig`)

State added to `Session`:
- `summary_boundary: usize` — message count captured at switch time.
- `summary_thread: ?std.Thread` (joined in `deinit`, like `title_thread`).
- `pending_summary: ?[]u8` — summary text awaiting a safe apply point.
- `summary_from_model_buf` — the previous model name, for the card label.

Flow:
1. On switch with prior history (`shouldSummarize`): record `summary_boundary`,
   snapshot `messages[0..boundary]`, append a visible status marker
   *"已切换到 `<model>`，正在汇总上文…"*, spawn `summaryThreadMain`.
2. `summaryThreadMain` builds a `ChatRequest` against the **new** profile
   (non-streaming, modest `max_tokens`, reasoning low) with
   `summarySystemPrompt()` + `buildSummaryUserContent(snapshot)`, runs it, and
   on success applies the result.
3. **Apply rule:** under `session.mutex`, if `!request_inflight`, splice the
   summary in now (collapse `[0..boundary]` into one collapsible "上文摘要" card,
   preserve `[boundary..]`). If a request is in flight, store `pending_summary`
   and apply it at the request-completion boundary (`appendAssistantResult` /
   `finishStoppedRequest`).
4. **Failure / cancellation:** silently keep the full raw history (no context
   lost); clear the status marker. Guard `session.closing` throughout.

The collapsed card is the single `.user`-role, `is_context_summary`-flagged
message described above; its content is the summary, its label notes the source
model (e.g. *"上文摘要 · 切换自 glm-5.2"*). It is collapsible and is sent verbatim
in subsequent requests as the leading user-context message.

### Context-correctness while async

- Turns sent **before** the summary lands carry the **raw history** → the new
  model has full context immediately; switching never drops information.
- Once the summary lands, the raw pre-switch turns collapse → future turns send
  the compact summary, saving tokens and keeping the transcript portable across
  providers.

## Data flow

```
click model label ─┐
/model (no arg) ────┤→ open profile picker (AiListMode.switch_model)
                    │        └─ select idx ─┐
/model <name> ──────┴→ matchProfileByName ──┤
                                            ▼
                              applyProfileToActiveChat(idx)
                                 • swap base_url/api_key/model/protocol/…
                                 • header label updates
                                 • shouldSummarize? ──no──► done (config-only swap)
                                            │yes
                                            ▼
                          record boundary + snapshot; append status marker;
                          spawn summaryThreadMain (runs on NEW profile)
                                            │
                          success ──────────┼────────── failure/cancel
                                            ▼                     ▼
                       apply when !inflight (else defer):   keep raw history,
                       collapse [0..boundary] → "上文摘要"    clear marker
                       card; preserve [boundary..]
```

## Error handling

- Invalid target profile (no model / non-http base_url): switch rejected, status
  message; session unchanged.
- `/model <unknown-name>`: tool message listing available profile names; no
  switch.
- Summary request error / network failure / new model also overloaded: keep raw
  history; the conversation is fully usable, just not compacted.
- Session closing mid-summary: worker exits via `closing` guard; thread joined in
  `deinit`.
- No saved profiles: `/model` and the click report "no AI profiles configured"
  (same condition `hasAiProfiles()` already handles elsewhere).

## Testing

Fast suite (`ai_model_switch.zig`, `ai_chat_composer.zig`):
- `parseSlashCommand("/model")` / `"/模型"` → `.model_switch`; `/model` with
  trailing text is treated as the direct-switch arg path (not `unknown`).
- `shouldSummarize`: false for empty / single-user-message / greeting-only;
  true once a user+assistant turn exists.
- `buildSummaryUserContent`: includes both roles, respects per-message caps,
  UTF-8-safe truncation.
- `matchProfileByName`: case-insensitive exact match; miss returns null; empty
  query returns null.
- `spliceSummary`: `[0..boundary]` replaced by exactly one card; `[boundary..]`
  preserved in order; boundary == len (no post-switch turns) and boundary <
  len (user continued) both covered; boundary == 0 (nothing to summarize) is a
  no-op the gate already prevents.

Full suite + cross-compile: build green on Linux suites and windows-gnu, as per
the project's standard pre-PR checks. GUI verification (click target, picker,
live header update, summary card) deferred to manual testing on macOS/Windows.

## Files touched

- `src/ai_model_switch.zig` — **new**, pure logic + tests.
- `src/ai_chat_composer.zig` — `/model` enum + entry + parser tests.
- `src/ai_chat.zig` — `.model_switch` dispatch; summary state, `summaryThreadMain`
  spawn, apply/splice, deferred-apply hook, `deinit` join.
- `src/ai_chat_request.zig` — `summaryThreadMain` worker (one-shot call).
- `src/renderer/overlays.zig` — `AiListMode.switch_model`,
  `applyProfileToActiveChat`, picker open path.
- `src/renderer/ai_chat_renderer.zig` — `modelLabelRect` / `modelLabelHitTest`.
- `src/input.zig` — route model-label click to the picker.
- `src/i18n.zig` — strings for the status marker, summary card label, "no
  profiles" / "unknown profile" messages (EN + zh-CN).
```
