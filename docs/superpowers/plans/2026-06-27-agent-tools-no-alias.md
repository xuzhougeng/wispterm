# Agent Tools No-Alias Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Agent tool runtime out of `src/ai_chat_tools.zig` without leaving old-path aliases, compatibility wrappers, or fossil public APIs.

**Architecture:** `tools/` owns catalogs/import plumbing, `research/` owns external research connectors and `$websearch` command metadata, and `agent_tools/` will own model tool-call runtime. Existing consumers must import the new owner directly in the same PR that moves a public function.

**Tech Stack:** Zig modules, existing `ToolContext`/`ToolHost` seam in `src/ai_chat_types.zig`, source-scan guards in `src/source_guards/`, `zig build test`, `zig build test-full -Dtarget=native`.

---

## Research Summary

Current `main` already contains:

- `src/tools/{first_party,registry,import,skill_draft}.zig`
- `src/research/{commands,web_search,web_read,web_read_cache,pubmed}.zig`

Current remaining debt:

- `src/ai_chat_tools.zig` is 4650 lines.
- `src/ai_chat_request.zig` imports `ai_chat_tools.zig` for `parseArgs`, `jsonStringArg`, `truncateOwned`, and `executeToolCall`.
- `src/ai_chat.zig` imports `ai_chat_tools.zig` for `findSurface` and `buildCopilotContext`.
- `src/test_main.zig` still imports and embeds `ai_chat_tools.zig`.

Ghostty comparison, checked with `gh` against `ghostty-org/ghostty`:

- Ghostty keeps domain directories such as `src/terminal/`, `src/config/`, and `src/font/` with clear owners.
- Ghostty uses package facades such as `src/terminal/main.zig`, `src/font/main.zig`, and `src/apprt.zig`, but those are real package entrypoints, not old-path compatibility wrappers.
- For WispTerm Agent tools, the matching rule is: a package entrypoint like `src/agent_tools/mod.zig` is acceptable only when it is the real owner; `src/ai_chat_tools.zig` must not remain as a wrapper around it.

## Hard Rules

- No `pub const oldName = new_module.name` to preserve the old API.
- No `src/ai_chat_tools.zig` compatibility wrapper after the final move.
- When a public function moves, every consumer must import the new owner directly in the same PR.
- Do not move `ToolContext` yet; it stays in `src/ai_chat_types.zig` until the runtime modules are stable.
- Do not combine runtime moves with security policy changes, process runner rewrites, or permission behavior changes.

## Target Layout

```text
src/
  agent_tools/
    args.zig
    research.zig
    knowledge.zig
    memory.zig
    terminal.zig
    sessions.zig
    files.zig
    exec.zig
    dynamic.zig
    weixin.zig
    mod.zig
```

`src/agent_tools/mod.zig` is the final dispatcher owner. It should not import `src/ai_chat_tools.zig`.

## PR Sequence

### PR 1: Extract argument parsing with direct consumers

**Commit:** `refactor(agent-tools): move tool argument parsing into agent_tools`

**Files:**

- Create: `src/agent_tools/args.zig`
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/ai_chat_request.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move these functions from `ai_chat_tools.zig` to `agent_tools/args.zig`:
  - `parseArgs`
  - `jsonStringArg`
  - `jsonIntArg`
  - `jsonIndexArg`
  - `jsonBoolArg`
  - `jsonStringArrayArg`
  - `freeStringArray`

- [ ] Rename them in the new file only if all call sites are updated in the same PR. A good direct API is:

```zig
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ?std.json.Parsed(std.json.Value)
pub fn string(root: std.json.Value, name: []const u8) ?[]const u8
pub fn int(root: std.json.Value, name: []const u8) ?u32
pub fn index(root: std.json.Value, name: []const u8) ?usize
pub fn boolean(root: std.json.Value, name: []const u8) ?bool
pub fn stringArray(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]const []const u8
pub fn freeStringArray(allocator: std.mem.Allocator, values: []const []const u8) void
```

- [ ] Update `src/ai_chat_tools.zig` to import `const tool_args = @import("agent_tools/args.zig");` and call `tool_args.parse(...)`, `tool_args.string(...)`, etc. Do not add local aliases.

- [ ] Update `src/ai_chat_request.zig` subagent parsing to import `agent_tools/args.zig` directly.

- [ ] Add tests in `src/agent_tools/args.zig` for empty args, invalid JSON, non-empty string filtering, integer/index bounds, boolean values, and string array allocation/free.

- [ ] Verification:

```bash
rg -n "ai_chat_tools\\.(parseArgs|jsonStringArg)|pub fn parseArgs|pub fn jsonStringArg" src
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected `rg`: no matches.

### PR 2: Move research runtime wrappers

**Commit:** `refactor(agent-tools): move research tool runtime wrappers`

**Files:**

- Create: `src/agent_tools/research.zig`
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move:
  - `webSearchTool`
  - `webReadTool`
  - `pubMedTool`

- [ ] `src/agent_tools/research.zig` imports:

```zig
const web_search = @import("../research/web_search.zig");
const web_read = @import("../research/web_read.zig");
const pubmed = @import("../research/pubmed.zig");
```

- [ ] The dispatcher in `ai_chat_tools.zig` calls `agent_research.webSearch(...)`, `agent_research.webRead(...)`, and `agent_research.pubMed(...)`.

- [ ] Verification:

```bash
rg -n "fn webSearchTool|fn webReadTool|fn pubMedTool" src/ai_chat_tools.zig
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected `rg`: no matches.

### PR 3: Move knowledge tools

**Commit:** `refactor(agent-tools): move knowledge tool runtime wrappers`

**Files:**

- Create: `src/agent_tools/knowledge.zig`
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move:
  - `skillInfoTool`
  - `skillInfoToolFromRoots`
  - `wisptermDocsTool`

- [ ] Move their tests from `ai_chat_tools.zig` into `agent_tools/knowledge.zig`.

- [ ] Update dispatcher calls to `knowledge.skillInfo(...)` and `knowledge.wisptermDocs(...)`.

- [ ] Verification:

```bash
rg -n "skillInfoTool|wisptermDocsTool" src/ai_chat_tools.zig src/agent_tools
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected: only `src/agent_tools/knowledge.zig` contains those names.

### PR 4: Move memory tools

**Commit:** `refactor(agent-tools): move memory tool runtime wrappers`

**Files:**

- Create: `src/agent_tools/memory.zig`
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move `memory_save`, `memory_recall`, and `memory_delete` wrapper logic into functions in `agent_tools/memory.zig`.

- [ ] Keep `src/agent_memory.zig` as the domain owner. `agent_tools/memory.zig` is only the model tool-call adapter.

- [ ] Verification:

```bash
rg -n "memory_save|memory_recall|memory_delete" src/ai_chat_tools.zig src/agent_tools/memory.zig
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected: dispatch names may remain in `ai_chat_tools.zig`; implementation logic lives in `agent_tools/memory.zig`.

### PR 5: Move terminal context helpers and update external consumers

**Commit:** `refactor(agent-tools): move terminal context tools`

**Files:**

- Create: `src/agent_tools/terminal.zig`
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/ai_chat.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move terminal context/list/snapshot/select functions and shared helpers:
  - `terminalContextTool`
  - `terminalListTool`
  - `terminalSnapshotTool`
  - `terminalSelectTool`
  - `collectToolSnapshot`
  - `rememberConnectedSurface`
  - `rememberClosedTab`
  - `findSurface`
  - `resolveSurfaceId`
  - `buildCopilotContext`
  - `setWriteContext`
  - `ensureWriteContext`

- [ ] Update `src/ai_chat.zig` to import `agent_tools/terminal.zig` directly for `findSurface` and `buildCopilotContext`. Do not re-export them from `ai_chat_tools.zig`.

- [ ] Move terminal tests with the functions they cover.

- [ ] Verification:

```bash
rg -n "ai_chat_tools\\.(findSurface|buildCopilotContext)|pub fn findSurface|pub fn buildCopilotContext" src
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected: external calls use `agent_tools/terminal.zig` directly.

### PR 6: Move session and tab tools

**Commit:** `refactor(agent-tools): move session tool runtime wrappers`

**Files:**

- Create: `src/agent_tools/sessions.zig`
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move:
  - `sshProfileSaveApprovalText`
  - `sshProfileSaveTool`
  - `sshProfileConnectTool`
  - `tabNewTool`
  - `tabCloseTool`

- [ ] Verification:

```bash
rg -n "sshProfileSaveTool|sshProfileConnectTool|tabNewTool|tabCloseTool" src/ai_chat_tools.zig src/agent_tools/sessions.zig
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected: implementation names live in `agent_tools/sessions.zig`.

### PR 7: Move file tools

**Commit:** `refactor(agent-tools): move file tool runtime wrappers`

**Files:**

- Create: `src/agent_tools/files.zig`
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move:
  - `readFileTool`
  - `copyFileTool`
  - `writeFileTool`
  - `editFileTool`
  - file target, path resolution, local/remote copy helpers, and read rendering helpers they use

- [ ] Do not change `fileAccessGate`, remote deny behavior, or approval policy in this PR.

- [ ] Verification:

```bash
rg -n "readFileTool|copyFileTool|writeFileTool|editFileTool" src/ai_chat_tools.zig src/agent_tools/files.zig
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected: implementation names live in `agent_tools/files.zig`.

### PR 8: Move execution and REPL tools

**Commit:** `refactor(agent-tools): move terminal execution tools`

**Files:**

- Create: `src/agent_tools/exec.zig`
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move:
  - `localCommandExecTool`
  - `sshSessionExecTool`
  - `wslSessionExecTool`
  - `terminalReplExecTool`
  - `terminalAnswerPromptTool`
  - `runShellCommand`
  - `runArgv`
  - `CaptureOutput`
  - `ShellResult`
  - `UnixSessionKind`
  - REPL prompt/sentinel helpers used by these tools

- [ ] Do not migrate `runArgv` to `process_runner` in this PR. That is a separate behavior-sensitive change.

- [ ] Verification:

```bash
rg -n "localCommandExecTool|sshSessionExecTool|wslSessionExecTool|terminalReplExecTool|terminalAnswerPromptTool|pub fn runArgv|pub fn runShellCommand" src/ai_chat_tools.zig src/agent_tools/exec.zig
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected: implementation names live in `agent_tools/exec.zig`.

### PR 9: Move dynamic and Weixin wrappers

**Commit:** `refactor(agent-tools): move dynamic and weixin tool wrappers`

**Files:**

- Create: `src/agent_tools/dynamic.zig`
- Create: `src/agent_tools/weixin.zig`
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move dynamic binary dispatch helper logic into `agent_tools/dynamic.zig`.

- [ ] Move `weixinSendAttachmentTool` into `agent_tools/weixin.zig`.

- [ ] Verification:

```bash
rg -n "dynamicBinaryTool|weixinSendAttachmentTool" src/ai_chat_tools.zig src/agent_tools
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected: implementation names live under `src/agent_tools/`.

### PR 10: Move dispatcher and delete ai_chat_tools.zig

**Commit:** `refactor(agent-tools): make agent_tools the runtime entrypoint`

**Files:**

- Create: `src/agent_tools/mod.zig`
- Delete: `src/ai_chat_tools.zig`
- Modify: `src/ai_chat_request.zig`
- Modify: `src/ai_chat.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] Move `executeToolCall` into `src/agent_tools/mod.zig`.

- [ ] Update `src/ai_chat_request.zig` to import `agent_tools/mod.zig` for `executeToolCall` and `truncateOwned`.

- [ ] If `truncateOwned` still exists, move it to the smallest real owner:
  - `agent_tools/output.zig` if only tool output truncation uses it
  - `agent_tools/mod.zig` if it is dispatcher-only

- [ ] Update `src/ai_chat.zig` comments that still say tool implementations live in `ai_chat_tools.zig`.

- [ ] Delete `src/ai_chat_tools.zig`; do not leave a wrapper file.

- [ ] Verification:

```bash
rg -n "ai_chat_tools" src docs AGENTS.md
test ! -e src/ai_chat_tools.zig
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected `rg`: no active source imports. Historical plans may mention the old path, but active source must not.

### PR 11: Add no-alias guard

**Commit:** `test(source-guards): prevent old agent tool runtime paths`

**Files:**

- Create: `src/source_guards/agent_tools_guard.zig`
- Modify: `src/test_fast.zig`

- [ ] Add a source guard that scans active sources and fails on:
  - `@import("ai_chat_tools.zig")`
  - `ai_chat_tools.`
  - `pub const .* = @import("agent_tools/`
  - `agent_tools/*` importing `AppWindow.zig`

- [ ] Keep the guard string-based and narrow. Do not build a parser.

- [ ] Verification:

```bash
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Expected: guard passes on the final layout and fails if old-path imports come back.

## Execution Notes

- Each PR must be independently mergeable.
- Each PR should lower `src/ai_chat_tools.zig` line count until PR 10 deletes it.
- If a move requires making many private helpers public, stop and split the helper cluster first; do not export internals only to finish a move.
- Historical docs under `docs/superpowers/plans/` can keep old paths. Active source and AGENTS-facing docs must use current paths.

## Completion Criteria

- `src/ai_chat_tools.zig` no longer exists.
- `src/agent_tools/mod.zig` is the only model tool-call runtime entrypoint.
- `src/ai_chat_request.zig` does not import `ai_chat_tools.zig`.
- `src/ai_chat.zig` does not import `ai_chat_tools.zig`.
- `src/agent_tools/*` does not import `AppWindow.zig`.
- `zig build test` and `zig build test-full -Dtarget=native` pass.
