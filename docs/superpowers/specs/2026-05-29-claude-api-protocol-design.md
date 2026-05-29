# Claude API (Anthropic Messages) Protocol Support — Design

**Date:** 2026-05-29
**Status:** Approved (design), pending implementation plan
**Issue:** xuzhougeng/wispterm#91 (需求3, Claude-API subset only)

## Goal

Let the AI Chat panel talk to the Anthropic **Messages API** (`/v1/messages`) directly,
as a third `ApiProtocol` alongside the existing OpenAI-compatible `chat_completions` and
`responses`. This is the reasonable, in-scope half of 需求3.

Out of scope (YAGNI):
- **Local Ollama** — already works via the OpenAI-compatible `chat_completions` path; no
  new code needed.
- **"Claude Code as a first-class kernel"** — deferred. Bundling Claude Code (~200MB) is
  not viable; the intended direction is to detect and invoke a user-installed `claude`,
  and a full agentic-kernel embedding conflicts with WispTerm owning the agent loop.
- **Streaming** — v1 is non-streaming. The panel's `stream` setting defaults to `false`
  (`ai_chat.zig:626`), so non-streaming is the existing default path. Anthropic SSE
  (`message_start` / `content_block_delta` / …) is a later follow-up.

## Current state (anchors)

- `src/ai_chat_protocol.zig:18` — `ApiProtocol` enum (`chat_completions`, `responses`).
- `:23` `parse`, `:34` `name`.
- `:130` `RequestParams { model, system_prompt, protocol, thinking_enabled, reasoning_effort, stream }`.
- `:137` `buildRequestJsonForMessages` switch over protocol.
- `:187` `isDeepSeekBaseUrl` — auto-detect precedent.
- `:191` `apiEndpoint`; `:198` `chatEndpoint`, `:202` `responsesEndpoint`, `:206` `endpointWithSuffix`.
- `parseApiResponse` — protocol-aware response parsing (tests at `:909+`).
- `src/ai_chat.zig:245-248` — Session holds `base_url`, `api_key`, `protocol` (default `.chat_completions`).
- `src/ai_chat.zig:730` — auto-detect precedent: empty key + DeepSeek base_url.
- `src/ai_chat.zig` http send (`runChatRequestForMessages`, ~`:2914-2980`) — sets
  `Authorization: Bearer <key>`.

## B1. Protocol enum + parse

Add `ApiProtocol.anthropic`.
- `name()` → `"anthropic"`.
- `parse()` also accepts `"anthropic"`, `"claude"`, `"messages"` (case-insensitive).

## B2. Endpoint

`apiEndpoint` gains an anthropic branch → `endpointWithSuffix(base_url, "/v1/messages")`.
Default base_url for anthropic = `https://api.anthropic.com`.

## B3. Request JSON (`buildRequestJsonForMessages` anthropic branch)

`RequestParams` gains `max_tokens: u32` (used by anthropic; optional/ignored for OpenAI).

Top-level object:
- `model`, `max_tokens` (required by Anthropic; default 8192, see B6).
- `system`: the system prompt as a **top-level string** (extracted out of `messages`,
  not a system-role message).
- `messages`: array of user/assistant turns (see content-block mapping).
- `tools`: same tool set as today, but each tool emitted as
  `{ name, description, input_schema: <JSON Schema> }` — remap OpenAI `parameters` →
  Anthropic `input_schema` (same schema shape).
- Optional `thinking` block when `thinking_enabled` (extended thinking) — mirror existing
  reasoning handling; minimal in v1.

Content-block mapping (internal `RequestMessage` → Anthropic blocks):
- system role → collected into top-level `system` (concatenate if multiple).
- user → `{ role: "user", content: "<text>" }`.
- assistant **with tool_calls** → `{ role:"assistant", content: [ {type:"text",text} (if
  non-empty), {type:"tool_use", id, name, input:<args parsed to object>} … ] }`.
- tool result (internal `.tool` role, has `tool_call_id`) → a **user** message containing
  `{type:"tool_result", tool_use_id:<id>, content:<result>}`. **Consecutive tool results
  for the same assistant turn must be grouped into one user message** with multiple
  `tool_result` blocks (Anthropic requirement).
- `tool_use.input` must be a JSON object: parse the internally-stored arguments string;
  on parse failure, send `{}` and log.

## B4. Response parse (`parseApiResponse` anthropic branch)

Anthropic response:
- `content`: array of blocks. Concatenate `text` blocks → `content`. Each `tool_use`
  block → internal `ToolCall { id, name, arguments = JSON.stringify(input) }`.
- `stop_reason` (`tool_use` means more tool calls follow — drives the existing agent loop
  in `runAgentRequest`, `ai_chat.zig:2508`).
- `usage.input_tokens` / `usage.output_tokens` → `ApiUsage` (map onto existing
  prompt/completion fields).

## B5. Auth headers

The http send branches on protocol:
- OpenAI (`chat_completions`/`responses`): unchanged — `Authorization: Bearer <key>`.
- `anthropic`: `x-api-key: <key>` **and** `anthropic-version: 2023-06-01` (no
  `Authorization`).

## B6. Settings UI, auto-detect, max_tokens

- AI panel settings: add `anthropic` as a third protocol option (alongside
  chat_completions / responses).
- Auto-detect: if `base_url` contains `api.anthropic.com`, default protocol to
  `anthropic` (mirror the DeepSeek auto-detect at `ai_chat.zig:730`).
- **`max_tokens`**: a per-session setting like `model`/`stream` (surfaced in the AI
  settings panel, persisted in the history record), **default 8192**. Required in the
  anthropic request; for OpenAI it may be sent as `max_tokens` or omitted (keep current
  OpenAI behavior unless trivially additive).

## Error handling

- Missing api_key for anthropic → same "needs key" path as today (`ai_chat.zig:1401`).
- Non-2xx from `/v1/messages` → surface Anthropic error JSON message in the transcript,
  mirroring existing OpenAI error handling.
- Malformed tool_use input / missing content blocks → degrade gracefully (empty content
  / `{}` args), log, never crash.

## Testing

- `ai_chat_protocol.zig`:
  - `ApiProtocol.parse`/`name` round-trip for `anthropic` (+ aliases).
  - `apiEndpoint` anthropic → `…/v1/messages`.
  - `buildRequestJsonForMessages` anthropic: system extracted top-level; user/assistant
    turns; tool present as `input_schema`; `max_tokens` included; tool_use + grouped
    tool_result mapping.
  - `parseApiResponse` anthropic: text concatenation, tool_use → ToolCall, usage mapping.
- Auth header selection unit (anthropic → `x-api-key` + `anthropic-version`).
- Auto-detect: `api.anthropic.com` base_url → protocol defaults to anthropic.
- Test wiring: ensure touched files remain registered in `test_fast.zig` /
  `test_main.zig`.
