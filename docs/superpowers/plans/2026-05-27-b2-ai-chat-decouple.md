# B2 — Decouple `ai_chat.zig` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract three pure logic clusters out of `src/ai_chat.zig` (7,051 ln) into std-only, unit-tested sibling modules — input-text geometry, composer suggestion parsing, and the API wire format — leaving `Session`, threads, tooling, and network paths untouched.

**Architecture:** Targeted pure-module extraction (the B1 pattern). Move functions/types verbatim into `ai_chat_input_text.zig`, `ai_chat_composer.zig`, `ai_chat_protocol.zig`; in `ai_chat.zig` add `pub const` re-exports (for symbols external code reaches via `ai_chat.<name>`) and file-local `const` aliases (for internal `Session`-body references) so NO call site changes. Regression-lock each module in `test_fast.zig` (fast loop) and/or `test_main.zig`.

**Tech Stack:** Zig. `zig build test` = fast loop (`src/test_fast.zig`); `zig build test-full -Dtarget=x86_64-windows-gnu` = full graph (`src/test_main.zig`), where the existing `ai_chat.zig` request/response tests run.

**Spec:** `docs/superpowers/specs/2026-05-27-b2-ai-chat-decouple-design.md`

**Conventions for every task:** "move verbatim" = cut the exact current source (the line ranges are given) into the new file unchanged except where a signature change is explicitly stated. After moving, the symbol no longer exists in `ai_chat.zig`, so add the stated alias/re-export. `[config] (warn): ... maybe` lines during `zig build test` are expected fixtures — success = exit 0.

---

## File structure

| File | Responsibility |
|------|----------------|
| `src/ai_chat_input_text.zig` (NEW) | Pure UTF-8 boundary stepping + visual-cursor/wrapped-line geometry. |
| `src/ai_chat_composer.zig` (NEW) | Pure slash-command / skill / composer suggestion parsing. |
| `src/ai_chat_protocol.zig` (NEW) | API wire format: protocol types + request-JSON building + response parsing. |
| `src/ai_chat.zig` (MODIFY) | Delegates via re-export aliases + thin `ChatRequest` wrappers; `Session`/threads/tooling unchanged. |
| `src/test_fast.zig`, `src/test_main.zig` (MODIFY) | Regression-lock imports. |

---

## Task 1: `ai_chat_input_text.zig` — pure input-text geometry

**Files:** Create `src/ai_chat_input_text.zig`; modify `src/ai_chat.zig`, `src/test_fast.zig`, `src/test_main.zig`.

Move verbatim from `src/ai_chat.zig` (current lines **2444–2564**): the types `VisualCursor`, `VisualRow` and the functions `clampUtf8Boundary`, `previousUtf8Boundary`, `nextUtf8Boundary`, `nextUtf8Step`, `visualCursorPosition`, `visualRowAt`, `byteOffsetForVisualPosition`, `inputWrappedLineCount`. Make all of them `pub` in the new file (add `pub ` in front of each `fn`/`const`; bodies unchanged).

- [ ] **Step 1: Create `src/ai_chat_input_text.zig`** with a header doc comment, `const std = @import("std");`, then the 8 functions + 2 types (moved verbatim, each made `pub`), then this test block appended:

```zig
test "utf8 boundaries step across multi-byte runes" {
    const s = "a\u{00e9}b"; // 'a', 'é' (2 bytes), 'b'
    try std.testing.expectEqual(@as(usize, 1), nextUtf8Boundary(s, 0));
    try std.testing.expectEqual(@as(usize, 3), nextUtf8Boundary(s, 1)); // skip é continuation
    try std.testing.expectEqual(@as(usize, 1), previousUtf8Boundary(s, 3));
    try std.testing.expectEqual(@as(usize, 1), clampUtf8Boundary(s, 2)); // mid-é clamps back
}

test "visualCursorPosition wraps and honors newlines" {
    try std.testing.expectEqual(VisualCursor{ .row = 0, .col = 3 }, visualCursorPosition("abc", 3, 10));
    try std.testing.expectEqual(VisualCursor{ .row = 1, .col = 1 }, visualCursorPosition("ab\nc", 4, 10));
    // wrap at max_cols = 2: "abcd", cursor at end -> row 1, col 2
    try std.testing.expectEqual(VisualCursor{ .row = 1, .col = 2 }, visualCursorPosition("abcd", 4, 2));
}

test "visualRowAt spans rows including the last" {
    const s = "ab\ncd";
    try std.testing.expectEqual(VisualRow{ .start = 0, .end = 2 }, visualRowAt(s, 0, 10).?);
    try std.testing.expectEqual(VisualRow{ .start = 3, .end = 5 }, visualRowAt(s, 1, 10).?);
    try std.testing.expectEqual(@as(?VisualRow, null), visualRowAt(s, 2, 10));
}

test "byteOffsetForVisualPosition round-trips with visualCursorPosition" {
    const s = "hello\nworld";
    const cur = visualCursorPosition(s, 8, 10); // inside "world" at col 2 -> offset 8
    try std.testing.expectEqual(@as(?usize, 8), byteOffsetForVisualPosition(s, cur.row, cur.col, 10));
}

test "inputWrappedLineCount: empty, newlines, wrap" {
    try std.testing.expectEqual(@as(usize, 1), inputWrappedLineCount("", 10));
    try std.testing.expectEqual(@as(usize, 1), inputWrappedLineCount("abc", 10));
    try std.testing.expectEqual(@as(usize, 2), inputWrappedLineCount("a\nb", 10));
    try std.testing.expectEqual(@as(usize, 2), inputWrappedLineCount("abcd", 2)); // wrap
}
```

- [ ] **Step 2: Run module tests** — `zig test src/ai_chat_input_text.zig` → all pass.

- [ ] **Step 3: In `src/ai_chat.zig`, delete the moved block (2444–2564) and add the import + aliases.** Add near the top imports:
```zig
const ai_chat_input_text = @import("ai_chat_input_text.zig");
```
Add these aliases (place where the deleted functions were, so the rest of the file reads naturally):
```zig
const VisualCursor = ai_chat_input_text.VisualCursor;
const VisualRow = ai_chat_input_text.VisualRow;
const clampUtf8Boundary = ai_chat_input_text.clampUtf8Boundary;
const previousUtf8Boundary = ai_chat_input_text.previousUtf8Boundary;
const nextUtf8Boundary = ai_chat_input_text.nextUtf8Boundary;
const nextUtf8Step = ai_chat_input_text.nextUtf8Step;
const visualCursorPosition = ai_chat_input_text.visualCursorPosition;
const visualRowAt = ai_chat_input_text.visualRowAt;
const byteOffsetForVisualPosition = ai_chat_input_text.byteOffsetForVisualPosition;
pub const inputWrappedLineCount = ai_chat_input_text.inputWrappedLineCount;
```
(`inputWrappedLineCount` is `pub` because `ai_chat_renderer.zig` calls `ai_chat.inputWrappedLineCount`. The rest are internal-only.)

- [ ] **Step 4: Wire into both test roots.** In `src/test_fast.zig`'s `test {}` block add `_ = @import("ai_chat_input_text.zig");`. In `src/test_main.zig`'s comptime block add `_ = @import("ai_chat_input_text.zig");` (alphabetical, near the other `ai_chat_*` entries).

- [ ] **Step 5: Build** — `zig build test` → exit 0.

- [ ] **Step 6: Commit:**
```bash
git add src/ai_chat_input_text.zig src/ai_chat.zig src/test_fast.zig src/test_main.zig
git commit -m "refactor(b2): extract pure input-text geometry from ai_chat.zig

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `ai_chat_composer.zig` — pure suggestion parsing

**Files:** Create `src/ai_chat_composer.zig`; modify `src/ai_chat.zig`, `src/test_fast.zig`, `src/test_main.zig`.

Move verbatim from `src/ai_chat.zig` (current lines **422–630**): the types `SlashCommand`, `ComposerSuggestionKind`, `ComposerSuggestion`, `SlashCommandSuggestion`, `SlashCommandEntry`, `slash_command_entries`, `SkillInvocation`, `ComposerSuggestionPrefix`, `ComposerCompletionTrigger`; and the functions `parseSlashCommand`, `composerSuggestionPrefix`, `slashCommandSuggestionPrefix`, `slashCommandTokenEnd`, `slashCommandSuggestionCountForInput`, `slashCommandSuggestionAtForInput`, `composerSuggestionCountForInput`, `composerSuggestionAtForInput`, `skillSuggestionCountForPrefix`, `skillSuggestionAtForPrefix`, `suggestionReplacementText`, `parseSkillInvocation`, `isAsciiWhitespace`. Keep their existing `pub`/non-`pub` qualifiers. (Verify the exact span by reading from `const SlashCommand = enum` through the end of `parseSkillInvocation`; `isAsciiWhitespace` is just past line 627 — include it.)

> Note: the filesystem skill-*loading* functions (`slashCommandOutput`, `listSkillsForDisplay*`, `loadSkillSuggestionListFromRoots`, `openSkillRoot`, `defaultSkillRootPaths`, …) do dir I/O and must STAY in `ai_chat.zig`. Only move the pure parsing functions/types listed above. If a stayed-behind function references a moved type/fn, the alias added in Step 3 keeps it compiling.

- [ ] **Step 1: Create `src/ai_chat_composer.zig`** with a header doc comment, then:
```zig
const std = @import("std");
const skill_registry = @import("skill_registry.zig");
```
then the moved types + functions (verbatim), then this test block:

```zig
const test_skills = [_]skill_registry.SkillMeta{
    .{ .name = "brainstorm", .description = "explore ideas" },
    .{ .name = "build", .description = "build something" },
    .{ .name = "review", .description = "review code" },
};

test "parseSlashCommand recognizes exact, unknown, and rejects non-slash" {
    try std.testing.expectEqual(SlashCommand.skills, parseSlashCommand("/skills").?);
    try std.testing.expectEqual(SlashCommand.unknown, parseSlashCommand("/help").?);
    try std.testing.expectEqual(@as(?SlashCommand, null), parseSlashCommand("hello"));
    try std.testing.expectEqual(@as(?SlashCommand, null), parseSlashCommand("/has space"));
}

test "composerSuggestionPrefix distinguishes / and $ and rejects others" {
    try std.testing.expectEqual(ComposerSuggestionKind.slash_command, composerSuggestionPrefix("/sk", 3).?.kind);
    try std.testing.expectEqual(ComposerSuggestionKind.skill, composerSuggestionPrefix("$br", 3).?.kind);
    try std.testing.expectEqual(@as(?ComposerSuggestionPrefix, null), composerSuggestionPrefix("hi", 2));
}

test "slash command suggestions filter by prefix" {
    try std.testing.expectEqual(@as(usize, 1), slashCommandSuggestionCountForInput("/sk", 3)); // /skills
    const s = slashCommandSuggestionAtForInput("/sk", 3, 0).?;
    try std.testing.expectEqualStrings("/skills", s.command);
}

test "skill suggestions filter by prefix against a fixture" {
    try std.testing.expectEqual(@as(usize, 2), skillSuggestionCountForPrefix("$b", &test_skills)); // brainstorm, build
    const sug = skillSuggestionAtForPrefix("$b", &test_skills, 1).?;
    try std.testing.expectEqual(ComposerSuggestionKind.skill, sug.kind);
    try std.testing.expectEqualStrings("build", sug.text);
}

test "parseSkillInvocation splits name and prompt" {
    const inv = parseSkillInvocation("$build make a thing").?;
    try std.testing.expectEqualStrings("build", inv.skill_name);
    try std.testing.expectEqualStrings("make a thing", inv.prompt);
    try std.testing.expectEqual(@as(?@TypeOf(inv), null), parseSkillInvocation("no dollar"));
}

test "suggestionReplacementText adds a space after a skill when needed" {
    var buf: [64]u8 = undefined;
    const sk = ComposerSuggestion{ .kind = .skill, .text = "build", .description = "" };
    try std.testing.expectEqualStrings("$build ", suggestionReplacementText(&buf, sk, "").?);
    try std.testing.expectEqualStrings("$build", suggestionReplacementText(&buf, sk, " x").?);
    const cmd = ComposerSuggestion{ .kind = .slash_command, .text = "/skills", .description = "" };
    try std.testing.expectEqualStrings("/skills", suggestionReplacementText(&buf, cmd, "").?);
}
```
> If `skill_registry.SkillMeta` has required fields beyond `name`/`description`, read its definition and fill the `test_skills` fixture accordingly.

- [ ] **Step 2: Run module tests** — `zig test src/ai_chat_composer.zig` → all pass.

- [ ] **Step 3: In `src/ai_chat.zig`, delete the moved block and add the import + aliases.** Add import:
```zig
const ai_chat_composer = @import("ai_chat_composer.zig");
```
Add aliases where the deleted code was. Types:
```zig
const SlashCommand = ai_chat_composer.SlashCommand;
const SkillInvocation = ai_chat_composer.SkillInvocation;
const ComposerSuggestionPrefix = ai_chat_composer.ComposerSuggestionPrefix;
const ComposerCompletionTrigger = ai_chat_composer.ComposerCompletionTrigger;
pub const ComposerSuggestionKind = ai_chat_composer.ComposerSuggestionKind;
pub const ComposerSuggestion = ai_chat_composer.ComposerSuggestion;
pub const SlashCommandSuggestion = ai_chat_composer.SlashCommandSuggestion;
```
Functions — `pub` re-exports for the ones `ai_chat_renderer.zig` reaches via `ai_chat.<fn>`, file-local aliases for the rest:
```zig
const parseSlashCommand = ai_chat_composer.parseSlashCommand;
const composerSuggestionPrefix = ai_chat_composer.composerSuggestionPrefix;
const slashCommandSuggestionPrefix = ai_chat_composer.slashCommandSuggestionPrefix;
const slashCommandTokenEnd = ai_chat_composer.slashCommandTokenEnd;
const skillSuggestionCountForPrefix = ai_chat_composer.skillSuggestionCountForPrefix;
const skillSuggestionAtForPrefix = ai_chat_composer.skillSuggestionAtForPrefix;
const suggestionReplacementText = ai_chat_composer.suggestionReplacementText;
const parseSkillInvocation = ai_chat_composer.parseSkillInvocation;
const isAsciiWhitespace = ai_chat_composer.isAsciiWhitespace;
pub const slashCommandSuggestionCountForInput = ai_chat_composer.slashCommandSuggestionCountForInput;
pub const slashCommandSuggestionAtForInput = ai_chat_composer.slashCommandSuggestionAtForInput;
pub const composerSuggestionCountForInput = ai_chat_composer.composerSuggestionCountForInput;
pub const composerSuggestionAtForInput = ai_chat_composer.composerSuggestionAtForInput;
```
> Some of the type/fn `pub`-ness above is a best guess. Rule: if a symbol is referenced as `ai_chat.<name>` anywhere outside `ai_chat.zig` (grep `src` for it), it must be `pub const`; otherwise plain `const`. Reconcile any compile error about a missing/duplicate symbol by checking the grep.

- [ ] **Step 4: Wire into both test roots** — add `_ = @import("ai_chat_composer.zig");` to `src/test_fast.zig`'s `test {}` block and `src/test_main.zig`'s comptime block.

- [ ] **Step 5: Build** — `zig build test` → exit 0.

- [ ] **Step 6: Commit:**
```bash
git add src/ai_chat_composer.zig src/ai_chat.zig src/test_fast.zig src/test_main.zig
git commit -m "refactor(b2): extract pure composer suggestion parsing from ai_chat.zig

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `ai_chat_protocol.zig` — API wire format

**Files:** Create `src/ai_chat_protocol.zig`; modify `src/ai_chat.zig`, `src/test_fast.zig`/`src/test_main.zig`.

This is the largest task; do the ordered sub-steps and run `zig build test` after each so a break is localized. **Do not move** the `Session`-coupled functions (`parseApiStreamResponse`, `applyApiStreamLineToSession`, `runChatRequest*`, `requestThreadMain`, `executeToolCall` + tool/SSH/shell fns) or the `ChatRequest` type — they stay in `ai_chat.zig`.

- [ ] **Step 1: Create `src/ai_chat_protocol.zig` skeleton** with header doc comment and imports:
```zig
//! API wire format for the agent chat: protocol data types, request-JSON
//! building, and response parsing. Pure with respect to Session/threads — it
//! takes plain data + an allocator. (Imports the platform tool-description
//! facades that the tool-schema builders already used.)
const std = @import("std");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");

pub const DEFAULT_PROTOCOL = "chat_completions";
pub const TOOL_CALL_REASONING_FALLBACK = "Tool call is required before answering.";
```

- [ ] **Step 2: Move the protocol types** from `ai_chat.zig` into `ai_chat_protocol.zig` (verbatim, made `pub`): `ApiProtocol` (36–57), `Role` (59–79), `RequestMessage` (133–149), `ToolCall` (151–161), `ApiResult` (339–353), `ApiUsage` (355–369). Delete `DEFAULT_PROTOCOL`/`TOOL_CALL_REASONING_FALLBACK` from `ai_chat.zig` (now in the new file). In `ai_chat.zig` add the import and re-export aliases:
```zig
const ai_chat_protocol = @import("ai_chat_protocol.zig");
pub const ApiProtocol = ai_chat_protocol.ApiProtocol;
pub const Role = ai_chat_protocol.Role;
const RequestMessage = ai_chat_protocol.RequestMessage;
const ToolCall = ai_chat_protocol.ToolCall;
const ApiResult = ai_chat_protocol.ApiResult;
pub const ApiUsage = ai_chat_protocol.ApiUsage;
pub const DEFAULT_PROTOCOL = ai_chat_protocol.DEFAULT_PROTOCOL;
const TOOL_CALL_REASONING_FALLBACK = ai_chat_protocol.TOOL_CALL_REASONING_FALLBACK;
```
> `ApiProtocol`/`Role`/`ApiUsage` are `pub` today (grep to confirm; keep whatever is referenced as `ai_chat.<name>` externally as `pub`). `RequestMessage`/`ToolCall`/`ApiResult` are file-private today → plain `const`. Then `zig build test` → exit 0 (types resolve through aliases). Fix any "ambiguous reference"/"not found" by adjusting an alias.

- [ ] **Step 3: Move request building.** Move verbatim into `ai_chat_protocol.zig`: `appendJsonString` (5171), `isDeepSeekBaseUrl` (5215), the endpoint builders `apiEndpoint`/`chatEndpoint`/`responsesEndpoint`/`endpointWithSuffix` (3388–3414), the tool-schema builders `appendToolSchemas`/`appendResponseToolSchemas`/`toolSchema`/`responseToolSchema`/`appendToolSchema`/`appendResponseToolSchema` (3595–3732), the response-item helpers `appendResponseMessage`/`appendResponseFunctionCall`/`appendResponseFunctionCallOutput` (3564–3594), and the builders `buildChatCompletionsRequestJsonForMessages`/`buildResponsesRequestJsonForMessages` (3431–3562) — but **change the builders' first data arg** from `request: *const ChatRequest` to `params: RequestParams`, replacing every `request.<field>` with `params.<field>` (the builders only read `model`, `system_prompt`, `protocol`, `thinking_enabled`, `reasoning_effort`, `stream`). Make `appendJsonString` and the two `build*ForMessages` `pub`. Add the param struct + a public dispatcher at the top of the new file's request section:
```zig
pub const RequestParams = struct {
    model: []const u8,
    system_prompt: []const u8,
    protocol: ApiProtocol,
    thinking_enabled: bool,
    reasoning_effort: []const u8,
    stream: bool,
};

pub fn buildRequestJson(allocator: std.mem.Allocator, params: RequestParams, messages: []const RequestMessage, include_tools: bool) ![]u8 {
    return switch (params.protocol) {
        .chat_completions => buildChatCompletionsRequestJsonForMessages(allocator, params, messages, include_tools),
        .responses => buildResponsesRequestJsonForMessages(allocator, params, messages, include_tools),
    };
}
```
In `ai_chat.zig`, REPLACE the old `buildRequestJson`/`buildRequestJsonForMessages` (3415–3429) with thin wrappers, and give `ChatRequest` a `toParams()` method:
```zig
// inside the ChatRequest struct:
fn toParams(self: *const ChatRequest) ai_chat_protocol.RequestParams {
    return .{
        .model = self.model,
        .system_prompt = self.system_prompt,
        .protocol = self.protocol,
        .thinking_enabled = self.thinking_enabled,
        .reasoning_effort = self.reasoning_effort,
        .stream = self.stream,
    };
}
```
```zig
fn buildRequestJson(allocator: std.mem.Allocator, request: *const ChatRequest) ![]u8 {
    return ai_chat_protocol.buildRequestJson(allocator, request.toParams(), request.messages, request.agent_enabled);
}

fn buildRequestJsonForMessages(allocator: std.mem.Allocator, request: *const ChatRequest, messages: []const RequestMessage, include_tools: bool) ![]u8 {
    return ai_chat_protocol.buildRequestJson(allocator, request.toParams(), messages, include_tools);
}
```
Also add file-local aliases in `ai_chat.zig` for any moved helper still called there (grep each moved name; e.g. `appendJsonString` may be used by stayed-behind streaming code — if so add `const appendJsonString = ai_chat_protocol.appendJsonString;`; same for `isDeepSeekBaseUrl`, endpoint builders if referenced). Then `zig build test` → exit 0, and `zig build test-full -Dtarget=x86_64-windows-gnu` → no new failures (the existing request-building tests at ai_chat.zig:5809+ run here).

- [ ] **Step 4: Move response parsing.** Move verbatim into `ai_chat_protocol.zig`: `parseApiResponse` (4699), `parseApiErrorResult` (4717), `parseChatCompletionsResponse` (4732), `parseResponsesResponse` (4760), `appendResponsesOutputText`/`appendResponsesContentText`/`appendResponsesReasoningText` (4801–4870), `parseApiUsage` (4871), `jsonU64Value` (4909), `jsonStringValue` (4918), `parseToolCalls` (4923), `parseResponsesToolCalls` (4962). Make `parseApiResponse` and `parseApiUsage` `pub` (others can stay private in the new file). In `ai_chat.zig` add aliases for the names still called by stayed-behind code:
```zig
const parseApiResponse = ai_chat_protocol.parseApiResponse;
const parseApiUsage = ai_chat_protocol.parseApiUsage;
```
> `parseApiStreamResponse` (4996) and `applyApiStreamLineToSession` (5087) STAY in `ai_chat.zig`. If they call any moved parser (e.g. `parseApiUsage`, `parseToolCalls`, `jsonStringValue`), add a file-local alias for each such name (grep to find which). Then `zig build test` → exit 0; `zig build test-full -Dtarget=x86_64-windows-gnu` → no new failures (the existing response-parse tests run here).

- [ ] **Step 5: Add unit tests to `ai_chat_protocol.zig`:**
```zig
test "ApiProtocol.parse and Role.apiName" {
    try std.testing.expectEqual(ApiProtocol.responses, ApiProtocol.parse("responses"));
    try std.testing.expectEqual(ApiProtocol.chat_completions, ApiProtocol.parse(""));
    try std.testing.expectEqualStrings("assistant", Role.assistant.apiName());
}

test "buildRequestJson chat_completions emits model, roles, flags" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m1", .system_prompt = "sys", .protocol = .chat_completions, .thinking_enabled = true, .reasoning_effort = "high", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"m1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stream\":false") != null);
}

test "buildRequestJson responses uses input + instructions" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m1", .system_prompt = "sys", .protocol = .responses, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"instructions\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input\":[") != null);
}

test "parseApiResponse reads chat_completions content + usage" {
    const a = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8}}
    ;
    var result = try parseApiResponse(a, body);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("hello", result.content);
    try std.testing.expectEqual(@as(u64, 8), result.usage.?.total_tokens);
}

test "parseApiResponse surfaces an error object as content" {
    const a = std.testing.allocator;
    const body =
        \\{"error":{"message":"boom"}}
    ;
    var result = try parseApiResponse(a, body);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("boom", result.content);
}

test "isDeepSeekBaseUrl" {
    try std.testing.expect(isDeepSeekBaseUrl("https://api.deepseek.com/v1"));
    try std.testing.expect(!isDeepSeekBaseUrl("https://api.openai.com/v1"));
}
```
> If `RequestMessage.content` is `[]u8` (mutable), the `@constCast` on the literal is required as shown. If a test references a private helper that wasn't made `pub`, either make it `pub` or drop that assertion — keep the public-surface tests above.

- [ ] **Step 6: Wire test roots.** Always add `_ = @import("ai_chat_protocol.zig");` to `src/test_main.zig`. Then TRY adding it to `src/test_fast.zig`'s `test {}` block and run `zig build test`: if it compiles and passes, keep it there (fast loop); if the `platform/process.zig`+`platform/pty_command.zig` imports fail to compile in the fast graph, REMOVE it from `test_fast.zig` (it stays in `test_main.zig` only) and note that in the commit message.

- [ ] **Step 7: Verify** — `zig build test` exit 0; `zig build test-full -Dtarget=x86_64-windows-gnu` → baseline 497/499, no NEW failures (this runs the existing ai_chat request/response tests against the refactored wire layer — the key guard).

- [ ] **Step 8: Commit:**
```bash
git add src/ai_chat_protocol.zig src/ai_chat.zig src/test_fast.zig src/test_main.zig
git commit -m "refactor(b2): extract API wire format (types/request/response) from ai_chat.zig

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Cross-target verification

**Files:** none.

- [ ] **Step 1:** `zig build test` → exit 0 (includes the new modules' tests).
- [ ] **Step 2:** `zig build test-full -Dtarget=x86_64-windows-gnu` → baseline 497/499, no new failures.
- [ ] **Step 3:** macOS compile-check of the std-only modules:
  `zig test src/ai_chat_input_text.zig -target aarch64-macos --test-no-exec` and the same for `ai_chat_composer.zig` → both compile. (`ai_chat_protocol.zig` and the parent-importing modules can't run standalone cross-compile due to the `@import` module-root quirk and platform facades — covered by `test_main`/`test-full` instead; macOS `test-full` is env-blocked, pre-existing.)
- [ ] **Step 4:** Confirm the moved symbols are gone from `ai_chat.zig` as standalone definitions: `grep -nE "^fn (visualCursorPosition|parseSlashCommand|buildChatCompletionsRequestJsonForMessages|parseChatCompletionsResponse)\b" src/ai_chat.zig` → no matches (they're aliases now, not `fn` definitions).
- [ ] **Step 5 (if any regression):** Use superpowers:systematic-debugging before changing code.

---

## Self-review notes

- **Spec coverage:** input-text geometry → Task 1; composer parsing → Task 2; wire format (types+request+response) → Task 3; test wiring + verification → every task's wiring step + Task 4. Markdown export + streaming explicitly deferred (spec "out of scope").
- **Type consistency:** `RequestParams` fields match the `ChatRequest` fields they copy in `toParams()`; `buildRequestJson(allocator, params, messages, include_tools)` signature is identical in the new file's dispatcher, the `ai_chat.zig` wrappers, and the Task-3 test. Re-export alias names match the moved symbol names exactly.
- **Behavior preservation:** all moved bodies are verbatim; the only signature change is `*const ChatRequest` → `RequestParams` in the two builders, a pure field copy via `toParams()`; the existing `ai_chat.zig` request/response tests (Windows `test-full`) guard the wire layer end-to-end.
