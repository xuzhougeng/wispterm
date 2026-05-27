# B2 — Decouple `ai_chat.zig` (presentation/logic separation)

Phase B, item B2 of the cross-platform portability roadmap
([TODO.md](../../../TODO.md), [decoupling-guide.md](../../decoupling-guide.md) §5).
Follows the B1 pattern ([2026-05-27-b1-input-decouple-design.md](2026-05-27-b1-input-decouple-design.md)).

## Goal

Separate the **conversation/state/protocol logic** in `src/ai_chat.zig` (7,051 ln)
from its UI state by extracting the genuinely-pure clusters into std-only,
unit-testable sibling modules, leaving the `Session` struct + network/thread/tool
machinery in place. Continues the existing pattern (`ai_chat_layout.zig`,
`ai_chat_composer_layout.zig`, `ai_chat_scrollbar_model.zig`).

Approach (chosen, same as B1): **targeted pure-module extraction** — move pure
functions/types into sibling modules, keep `ai_chat.zig` delegating via re-export
aliases so every internal and external call site is unchanged. **No** restructuring
of `Session`, the request threads, tool execution, or the streaming/network paths.

## Current state (the coupling)

`ai_chat.zig` interleaves, in one 7,051-line file: the `Session` struct
(858–2422, conversation + UI state + threads + mutexes), the API wire format
(request-JSON builders + response parsers), composer/slash/skill suggestion
parsing, input-text geometry, markdown export, and the whole tool-execution /
SSH / shell machinery. The pure logic is testable in isolation but currently
can only be exercised through the heavy app graph (`zig build test-full`).

Three pure clusters detach cleanly (verified by reading their signatures — they
take `std` types / slices / `std.json.Value` and a passed allocator, and touch no
`Session`/thread state):

1. **Input-text geometry** (2444–2564): `clampUtf8Boundary`, `previousUtf8Boundary`,
   `nextUtf8Boundary`, `nextUtf8Step`, `visualCursorPosition`, `visualRowAt`,
   `byteOffsetForVisualPosition`, `inputWrappedLineCount`, + `VisualCursor`/`VisualRow`.
2. **Composer suggestion parsing** (422–630): `parseSlashCommand`,
   `composerSuggestionPrefix`, `slashCommandSuggestionPrefix`, `slashCommandTokenEnd`,
   `slashCommandSuggestionCountForInput`, `slashCommandSuggestionAtForInput`,
   `composerSuggestionCountForInput`, `composerSuggestionAtForInput`,
   `skillSuggestionCountForPrefix`, `skillSuggestionAtForPrefix`,
   `suggestionReplacementText`, `parseSkillInvocation`, `isAsciiWhitespace`, + the
   types (`SlashCommand`, `ComposerSuggestionKind`, `ComposerSuggestion`,
   `SlashCommandSuggestion`, `SlashCommandEntry`, `slash_command_entries`,
   `SkillInvocation`, `ComposerSuggestionPrefix`, `ComposerCompletionTrigger`).
   (The filesystem skill-*loading* functions stay in `ai_chat.zig` — they do dir I/O.)
3. **API wire format** — request-JSON building + response parsing + the protocol
   data types. The headline "protocol logic" separation.

## Design — three new modules

### Module 1 — `src/input/../ai_chat_input_text.zig`

Path: `src/ai_chat_input_text.zig` (sibling of `ai_chat.zig`, like the other
`ai_chat_*` modules). Imports only `std`. Holds cluster 1 verbatim. Public API:
all functions `pub` (they are internal helpers today, but exposing them is
harmless and lets the tests live in the module). `ai_chat.zig` adds:
- `pub const inputWrappedLineCount = ai_chat_input_text.inputWrappedLineCount;`
  (the only externally-referenced one — `ai_chat_renderer.zig` calls
  `ai_chat.inputWrappedLineCount`).
- file-local aliases for the rest (`const visualCursorPosition = ai_chat_input_text.visualCursorPosition;`,
  etc.) plus `const VisualCursor = ...` / `const VisualRow = ...`, so all `Session`
  method bodies stay byte-identical.

**Tests:** UTF-8 boundary stepping across multi-byte runes; `visualCursorPosition`
row/col under wrapping + explicit `\n`; `visualRowAt` row span incl. last row;
`byteOffsetForVisualPosition` round-trips with `visualCursorPosition`;
`inputWrappedLineCount` for empty, single line, hard newlines, wrap at `max_cols`.

### Module 2 — `src/ai_chat_composer.zig`

Imports `std` + `skill_registry` (for the `SkillMeta` type only). Holds cluster 2.
The `pub fn`s that `ai_chat_renderer.zig` reaches via `ai_chat.<fn>` get `pub const`
re-exports in `ai_chat.zig` (`slashCommandSuggestionCountForInput`,
`slashCommandSuggestionAtForInput`, `composerSuggestionCountForInput`,
`composerSuggestionAtForInput`); the rest get file-local aliases. The moved types
get re-export aliases too (`const ComposerSuggestion = ai_chat_composer.ComposerSuggestion;`
etc.) so `Session` bodies are unchanged.

**Tests:** `parseSlashCommand` (exact match, unknown, non-slash, embedded space →
null); `composerSuggestionPrefix` for `/` vs `$` vs other, cursor past token → null;
`slashCommandSuggestionCountForInput`/`...AtForInput` prefix filtering;
`skillSuggestion*` against a fixed `[]SkillMeta` fixture; `parseSkillInvocation`
name/prompt split; `suggestionReplacementText` skill spacing.

### Module 3 — `src/ai_chat_protocol.zig`

The API wire format. Imports `std` + the platform tool-description facades
(`platform_pty_command`, `platform_process`) that `appendToolSchemas` already uses.
Holds:
- **Types (moved):** `ApiProtocol`, `Role`, `RequestMessage`, `ToolCall`,
  `ApiResult`, `ApiUsage`. `ai_chat.zig` re-exports each
  (`pub const Role = ai_chat_protocol.Role;`, etc.) so all references — `Session`
  fields, tool code, the existing tests — stay unchanged. (`Message`, the UI-layer
  conversation message, stays in `ai_chat.zig`.)
- **Request building:** a small `RequestParams` value struct
  (`model, system_prompt, protocol, thinking_enabled, reasoning_effort, stream`)
  + `buildRequestJson(allocator, params, messages, include_tools)` and its
  `chat_completions`/`responses` variants, `appendJsonString`, the endpoint
  builders (`apiEndpoint`/`chatEndpoint`/`responsesEndpoint`/`endpointWithSuffix`),
  the tool-schema builders (`appendToolSchemas`/`appendResponseToolSchemas`/
  `toolSchema`/`appendToolSchema`/…), `isDeepSeekBaseUrl`, and the
  `DEFAULT_PROTOCOL`/`TOOL_CALL_REASONING_FALLBACK` constants.
- **Response parsing (pure std):** `parseApiResponse`, `parseApiErrorResult`,
  `parseChatCompletionsResponse`, `parseResponsesResponse`,
  `appendResponsesOutputText`/`appendResponsesContentText`/`appendResponsesReasoningText`,
  `parseApiUsage`, `parseToolCalls`, `parseResponsesToolCalls`, `jsonU64Value`,
  `jsonStringValue`.

`ai_chat.zig` keeps thin `ChatRequest`-based wrappers so the ~15 existing call
sites (incl. the wire tests) are unchanged:
`fn buildRequestJson(allocator, request) = ai_chat_protocol.buildRequestJson(allocator, request.toParams(), request.messages, request.agent_enabled)`,
`fn buildRequestJsonForMessages(allocator, request, messages, include_tools) = ...`,
and `const parseApiResponse = ai_chat_protocol.parseApiResponse;`.

**Explicitly NOT moved (stay in `ai_chat.zig`, they touch `Session`/threads):**
`parseApiStreamResponse`, `applyApiStreamLineToSession`, `runChatRequest*`,
`requestThreadMain`, `executeToolCall` and the tool/SSH/shell functions, and
`buildRequestJson`'s `ChatRequest` type itself.

**Tests:** build a chat_completions request JSON for a fixed `RequestParams` +
`[]RequestMessage` and assert key substrings (model, roles, tool_calls,
thinking/stream flags); same for a `responses` request; `parseApiResponse` on a
canned chat_completions body → content/reasoning/tool_calls; on a `responses`
body → output text; `parseApiUsage`; `parseApiErrorResult`;
`ApiProtocol.parse`/`Role.apiName`; `isDeepSeekBaseUrl`.

## Test wiring & verification

- Modules 1 & 2 are std-only (module 2 also imports `skill_registry` for a type) →
  add to BOTH `src/test_fast.zig` (fast loop) and `src/test_main.zig`.
- Module 3 imports the platform tool-description facades. Add to `test_main.zig`
  always; add to `test_fast.zig` **iff** it compiles in the fast graph (the
  implementer verifies with `zig build test`); otherwise its tests run under
  `test-full` (same as the existing `ai_chat.zig` wire tests).
- Per-target verification (same matrix as B1):
  - `zig build test` (native fast loop)
  - `zig build test-full -Dtarget=x86_64-windows-gnu` (baseline 497/499; this is
    where the existing `ai_chat.zig` request/response tests run — the key
    behavior-preservation guard for module 3)
  - macOS `test-full` is environment-blocked on this host (pre-existing C-dep
    cross-compile failure, see project memory); std-only modules compile-check via
    `zig test <mod> -target aarch64-macos --test-no-exec`.

## Out of scope for B2

- No `Session` restructuring; no change to threads/mutexes/tool execution/network.
- Markdown export (`appendMarkdown*`, `allocUsageFooter`, …) is pure and could be a
  future extraction, but is left for a later pass to keep B2 focused.
- Streaming response handling stays in `ai_chat.zig` (it mutates `Session`).

## Risks & mitigations

- **Wide type move (module 3).** `Role`/`ToolCall`/`ApiResult`/`ApiUsage`/
  `RequestMessage`/`ApiProtocol` are referenced widely. Mitigation: move the
  definition, add a re-export alias in `ai_chat.zig` for each, so unqualified
  references keep resolving; the compiler flags any miss.
- **Behavior drift in the wire format.** Mitigation: all moved functions are
  verbatim; the `ChatRequest`→`RequestParams` change is a pure field copy; the
  existing `ai_chat.zig` request/response tests (run under Windows `test-full`)
  are the regression guard, plus the new module unit tests.
- **Platform facade in the fast graph (module 3).** If importing
  `platform_pty_command`/`platform_process` won't compile in `test_fast.zig`, keep
  module 3 in `test_main.zig` only — no loss of coverage vs. today.

## Ghostty reference

Ghostty keeps its API/wire types and codecs separate from UI/session state; this
mirrors that split for Phantty's agent chat.
