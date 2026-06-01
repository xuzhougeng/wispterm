# ai_chat.zig Module Split — Design

Date: 2026-06-01
Branch: `feat-refactor-ai-chat`
Status: Approved design (pending spec review)

Continuation of the `2026-05-27-b2-ai-chat-decouple-design.md` decoupling effort.

## Problem

`src/ai_chat.zig` has grown to **8283 lines**. It mixes the `Session` state
machine with the agent tool layer, the network request / streaming loop, skill
loading, markdown export, API stream parsing, and ~3000 lines of tests. This
hurts:

- **Navigability** — locating code, reading, and giving an AI a coherent slice
  of the file are all expensive.
- **Decoupling / testability** — the tool layer in particular can only be
  exercised through the full `Session` + request machinery, not in isolation.
- **Compile time** — minor in Zig (see caveat), but the file is in the
  `test-full` hot path.

### Compile-time caveat (expectation setting)

In Zig, splitting files buys far less clean-build speedup than in C/C++: the
compiler builds the whole module graph regardless; there is no per-file object
cache. The real compile-time lever is keeping **`test_fast.zig`'s import set
minimal** so the inner dev loop stays fast (ai_chat tests already run only under
`test-full`). Compile-time is therefore treated as a *minor* gain;
**navigability + decoupling/testability** drive the cut-lines.

## Goals

1. Shrink `ai_chat.zig` to a coherent core (public types + globals + `Session` +
   thin glue) of roughly ~3000 lines.
2. Extract self-contained concerns into focused modules following the existing
   `ai_chat_*.zig` leaf-module convention.
3. Make the **tool layer** independently unit-testable via a narrow seam.
4. Every step independently compiles and passes both `zig build test` and
   `zig build test-full`.

## Non-goals

- **Do NOT crack open the `Session` struct** (lines ~751–2783, ~2030 lines). It
  stays in `ai_chat.zig` as the core. (Explicit user decision: 稳健分层.)
- No behavior changes. This is relocation + one narrow interface seam, nothing
  more. No new features, no logic rewrites.
- No unrelated refactoring.

## Target decomposition

`Session` and the public type surface (`Message`, `ChatRequest`, `ToolSurface`,
`ToolSnapshot`, `ToolHost`, `AgentSettings`, history hooks, etc.) and the global
agent state remain in `ai_chat.zig`.

| New / target module | Moves in | Coupling to `Session` | Strategy |
|---|---|---|---|
| `ai_chat_skills.zig` | skill/command root-path loading + slash-command output helpers (`slashCommandOutput`, `listSkillsForDisplay*`, `loadSkill*`, `SkillRoot`, root-path helpers) + their tests | ~none (leaf) | true leaf |
| `ai_chat_tools.zig` | `executeToolCall` + every `*Tool` fn (terminal/shell/ssh/wsl/repl/R/python/weixin/ssh-profile/tab) + shell/argv runners (`ShellResult`, `runShellCommand`, `runArgv`, `captureOutputThread`) + `UnixSessionKind`/`ReplKind` + dangerous-command detection + write/copilot-context helpers + their tests | **narrow** (`requestApproval` + cancel flag) | **`ToolContext` seam** (true leaf, fake-testable) |
| `ai_chat_request.zig` | request thread (`requestThreadMain`), agent loop (`runAgentRequest`), streaming (`runChatRequestStreaming`, stream-apply), auto-title (`buildTitleRequestLocked`, `titleThreadMain`, `maybeAutoTitle`, `applyGeneratedTitle`), clone helpers, and the `*Session` append/stream helpers (`appendAssistantResult`, `beginAssistantStream`, …) + their tests | **deep** (mutates message internals) | **mutual import** (intrinsic coupling) |
| `ai_chat_protocol.zig` (existing) | fold in API **stream-response parsing** (`parseApiStreamResponse`, `applyApiStreamLineToSession` — the pure parsing parts) | none | extend existing protocol home |
| `ai_chat_markdown.zig` (new, small) | transcript→markdown export helpers (`appendMarkdown*`, `appendClipboardSection`, `longestBacktickRun`, `latestAssistantContent`) + their tests | references `Message` only | leaf |

Result: `ai_chat.zig` ≈ public types + globals + `Session` + glue +
Session-specific tests ≈ **~3000 lines**.

## The `ToolContext` seam (Step 2 detail)

Today the tool functions thread a `*ChatRequest` and reach
`request.session.requestApproval(...)`, `sessionCancelled(request.session)`,
`request.tool_host`, `request.tool_snapshot`, `request.allocator`, plus the
globals `currentAgentSettings()` / `currentToolHost()`.

To make `ai_chat_tools.zig` a true leaf (no `Session`, no back-import of
`ai_chat.zig`), introduce a narrow context the caller fills in:

```zig
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    tool_host: ?ToolHost,            // types live in ai_chat_types (see below) or are passed through
    tool_snapshot: ?ToolSnapshot,
    settings: AgentSettings,         // snapshot of currentAgentSettings()
    weixin_reply_context: ?WeixinReplyContext,
    write_context_surface_id: ...,   // the [64]u8 buffer + len, or a small slice helper

    // seams replacing direct Session reach-through:
    approve: *const fn (*anyopaque, tool: []const u8, command: []const u8, reason: []const u8) bool,
    cancelled: *const fn (*anyopaque) bool,
    ctx: *anyopaque,                 // opaque Session pointer the callbacks close over
};
```

`ai_chat.zig` builds a `ToolContext` from its `ChatRequest`/`Session` and passes
it to `ai_chat_tools.executeToolCall(ctx, call)`. Tool unit tests construct a
`ToolContext` with fake `approve`/`cancelled` callbacks and a fake `ToolHost`,
exercising tools with zero `Session`.

**Shared types:** `ToolHost`, `ToolSurface`, `ToolSnapshot`, `ToolClosedTab`,
`SshProfileSaveArgs`, `SavedSshProfile`, `WeixinReplyContext`, `AgentSettings`,
`ApprovalView` are needed by both `ai_chat.zig` and `ai_chat_tools.zig`. To keep
`ai_chat_tools.zig` a leaf, these move to a tiny **`ai_chat_types.zig`** that
both import. (`ai_chat.zig` re-exports them as `pub const X = ai_chat_types.X;`
so external consumers — `App.zig`, `AppWindow.zig`, `config.zig` — see no API
change.)

## Dependency direction

- `ai_chat_types.zig` — leaf, imported by everyone.
- `ai_chat_skills.zig`, `ai_chat_markdown.zig` — leaf.
- `ai_chat_tools.zig` — imports `ai_chat_types.zig` only (true leaf; no
  `ai_chat.zig` back-import).
- `ai_chat_request.zig` — **mutual import** with `ai_chat.zig` (needs `Session`
  + `ChatRequest`; coupling is intrinsic to the request/streaming lifecycle).
  Legal in Zig because the references are pointer-based (`*Session`,
  `*const ChatRequest`), not by-value struct layout. `requestApproval` and the
  append/stream helpers become `pub` as needed.
- `ai_chat.zig` — imports all of the above; keeps `Session` + globals + glue.

## Sequencing (4 green steps, one branch)

Each step compiles and passes `zig build test` **and** `zig build test-full`
before the next, and is its own commit on `feat-refactor-ai-chat`.

1. **`ai_chat_skills.zig`** — leaf, lowest risk; proves the extraction pattern
   and the test-travels-with-code approach. Wire into `test_main.zig` (and
   `test_fast.zig` only if leaf-safe and desired).
2. **`ai_chat_types.zig` + `ai_chat_tools.zig` with the `ToolContext` seam** —
   the biggest win and the decoupling payoff. Add fake-context unit tests for at
   least the dangerous-command and one exec path to prove isolation.
3. **`ai_chat_request.zig`** via mutual import — relocate the request/stream/
   title machinery; make the needed `Session` surface `pub`.
4. **Fold stream-parsing → `ai_chat_protocol.zig`** and **markdown export →
   `ai_chat_markdown.zig`**; final cleanup of `ai_chat.zig`.

## Test strategy

- **Tests travel with the code they cover.** Zig tests reach private decls, so a
  single test-only file would force a large `pub` surface. Instead, each
  extracted module carries its relevant `test` blocks; Session-specific tests
  stay in `ai_chat.zig`.
- New modules are registered in `test_main.zig` (`_ = @import("…");`). Add to
  `test_fast.zig` only for genuinely leaf, fast modules.
- **`test_main.zig` compile-guards:** several guards `@embedFile("ai_chat.zig")`
  and scan its source text (e.g. for `powershellExecTool`, tab-kind strings,
  `localShellFallback`). When the scanned code moves, update each guard to
  `@embedFile` the new module so the guard still fires on the relocated text.
- Baseline to preserve: `test` + `test-full` both exit 0; full suite green
  (~673+/677, 0 failed, per project baseline).

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Zig "dependency loop" on mutual import | references are pointer-based; if a loop appears, push the shared type into `ai_chat_types.zig`. |
| Widening `pub` surface leaks internals | only promote the exact decls the request layer needs; keep tool layer behind `ToolContext` (no promotion). |
| `test_main.zig` source-scan guards silently stop firing | update each guard's `@embedFile` target in the same step the code moves; verify a guard still trips with a temporary edit. |
| Hidden coupling discovered mid-extraction | steps are independently green + committed → easy bisect/revert; stop and reassess rather than forcing. |
| Behavior drift | pure relocation; rely on the existing 119 tests + `test-full` as the regression net at every step. |

## Success criteria

- `ai_chat.zig` ≈ ~3000 lines; `Session` intact and unchanged.
- `ai_chat_tools.zig` is a true leaf with at least one fake-`ToolContext` unit
  test proving `Session`-free testability.
- No API change visible to `App.zig` / `AppWindow.zig` / `config.zig`.
- `zig build test` and `zig build test-full` both green at every commit.
