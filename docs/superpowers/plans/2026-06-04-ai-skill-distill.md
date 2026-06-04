# AI Skill Distillation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add controlled AI skill accumulation through `/distill` and `/沉淀`, plus an automatic post-task suggestion that can preview and confirm a generated local `SKILL.md`.

**Architecture:** Keep distillation as an AI Chat workflow layered on existing skills and slash commands. A new pure module `src/ai_skill_distill.zig` owns command-argument parsing, slugging, redaction, candidate JSON parsing, Markdown rendering, context shaping, and suggestion heuristics. `src/ai_chat_composer.zig` exposes `/distill` with `/沉淀` as an alias. `src/ai_chat.zig` owns per-session pending suggestion and pending candidate state, starts the distiller request, previews candidates as non-persisted local tool messages, confirms or cancels writes, and refreshes skill suggestions. `src/ai_chat_request.zig` runs a tool-free distiller request using the existing provider serialization path. `src/ai_chat_skills.zig` exposes the writable user skills root and performs the safe `SKILL.md` write.

**Tech Stack:** Zig 0.15.2, WispTerm AI Chat modules, existing OpenAI-compatible/Responses/Anthropic request serialization, `platform/dirs.zig`, `skill_registry.zig`, `std.fs` atomic file creation.

---

## Ghostty Comparison

Ghostty has no AI Agent, skill registry, memory accumulation, or web remote equivalent. The relevant Ghostty principle is command entry consistency: `ghostty-org/ghostty/src/input/command.zig` treats commands as normal named actions rather than a second command interpreter. This implementation follows the same shape inside WispTerm by adding `/distill` to the existing AI Chat slash-command path instead of adding a separate parser or terminal-mode behavior. No VT, input escape, rendering, shell integration, or PTY behavior changes are part of this plan.

---

## File Structure

- **Create** `src/ai_skill_distill.zig` — pure distillation helpers and unit tests.
- **Modify** `src/test_fast.zig` — register `ai_skill_distill.zig` in the fast pure-module test suite.
- **Modify** `src/ai_chat_composer.zig` — add `SlashCommand.distill`, `/distill` suggestions, and `/沉淀` alias parsing.
- **Modify** `src/ai_chat_skills.zig` — expose the writable user skill root and write confirmed candidates to `<config>/skills/<slug>/SKILL.md`.
- **Modify** `src/ai_chat.zig` — add pending suggestion/candidate state, manual command handling, auto suggestion handling, preview/confirm/cancel outputs, and skill suggestion refresh.
- **Modify** `src/ai_chat_request.zig` — add a distiller worker entry point that reuses provider request serialization without tools.
- **Modify** `docs/ai-agent.md` — document skill distillation usage and safety behavior.
- **Modify** `README.md` — mention skill distillation in the AI Agent capability summary. Do not change keyboard shortcut tables.

---

## Task 1: Add Pure Distillation Helpers

**Files:**
- Create: `src/ai_skill_distill.zig`
- Modify: `src/test_fast.zig`

- [x] **Step 1: Create owned candidate and command argument types**

Create `src/ai_skill_distill.zig` with only `std` and `skill_registry.zig` imports. Keep it independent of `ai_chat.zig` so it can remain in `test_fast`.

```zig
//! Pure helpers for turning an AI Chat transcript into a candidate SKILL.md.
const std = @import("std");
const skill_registry = @import("skill_registry.zig");

pub const CommandAction = enum {
    start,
    confirm,
    cancel,
};

pub const CommandArgs = struct {
    action: CommandAction,
    topic: []const u8 = "",
};

pub const DistillRole = enum {
    user,
    assistant,
    tool,
};

pub const DistillTurn = struct {
    role: DistillRole,
    content: []const u8,
    replay_to_model: bool = false,
};

pub const Candidate = struct {
    name: []u8,
    description: []u8,
    body: []u8,
    source_summary: []u8,

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.body);
        allocator.free(self.source_summary);
        self.* = undefined;
    }
};
```

- [x] **Step 2: Implement `/distill` argument parsing**

Add `parseCommandArgs(arg: []const u8) CommandArgs`. It accepts English and Chinese confirmation words independent of the slash alias.

Rules:

- Empty arg returns `.start` with empty topic.
- `confirm` and `确认` return `.confirm`.
- `cancel`, `取消`, and `放弃` return `.cancel`.
- Any other non-empty text returns `.start` with `topic` set to the trimmed text.

Tests:

- `parseCommandArgs("")` returns `.start`.
- `parseCommandArgs("ssh troubleshooting")` keeps the topic.
- `parseCommandArgs("confirm")` and `parseCommandArgs("确认")` return `.confirm`.
- `parseCommandArgs("cancel")`, `parseCommandArgs("取消")`, and `parseCommandArgs("放弃")` return `.cancel`.

- [x] **Step 3: Implement slug normalization**

Add `normalizeSlug(allocator, suggested_name, fallback_topic) ![]u8` and `isValidSlug(slug) bool`.

Rules:

- Lowercase ASCII letters and digits pass through.
- ASCII whitespace, punctuation, underscores, and repeated separators become one `-`.
- Non-ASCII bytes are separators.
- Leading and trailing `-` are stripped.
- Length is capped at 63 bytes.
- Empty result falls back to `fallback_topic`, then to `skill`, then to a deterministic suffix `skill-1` only when needed by the caller.
- A valid slug matches `[a-z0-9][a-z0-9-]{0,62}`.

Tests:

- `"SSH File Transfer Troubleshooting"` becomes `ssh-file-transfer-troubleshooting`.
- `"  a__b---c  "` becomes `a-b-c`.
- Chinese-only input with fallback `"remote ssh"` becomes `remote-ssh`.
- Empty suggested name and empty fallback becomes `skill`.
- Output is never longer than 63 bytes and never starts or ends with `-`.

- [x] **Step 4: Implement sensitive material redaction and blocking**

Add:

```zig
pub fn redactSensitive(allocator: std.mem.Allocator, text: []const u8) ![]u8;
pub fn containsSensitiveMaterial(text: []const u8) bool;
```

Patterns to cover in the first implementation:

- `api_key`, `apikey`, `profile_key`, `password`, `passwd`, `pwd`, `token`, `context_token`, `weixin_token`.
- Environment-style names ending in `_TOKEN`, `_KEY`, `_SECRET`, `_PASSWORD`.
- Bearer tokens after `Authorization: Bearer`.
- Common OpenAI-like key prefix `sk-` followed by at least 16 alphanumeric or `-` or `_` bytes.

Redaction replaces the value portion with `<redacted>` and keeps enough surrounding text to remain understandable. `containsSensitiveMaterial` returns true for unredacted high-risk patterns so confirm can block writes if the generated candidate still contains them.

Tests:

- `api_key = "sk-abcdefghijklmnopqrstuvwxyz"` redacts the value.
- `Authorization: Bearer abcdefghijklmnop` redacts the bearer value.
- `WEIXIN_CONTEXT_TOKEN=secret-value` redacts the value.
- A sentence containing `keyboard shortcut` does not trigger redaction.
- Redacted output does not contain the original secret bytes.

- [x] **Step 5: Implement candidate JSON parsing and Markdown rendering**

Add:

```zig
pub fn parseCandidateJson(allocator: std.mem.Allocator, json_text: []const u8, topic: []const u8) !Candidate;
pub fn renderSkillMarkdown(allocator: std.mem.Allocator, candidate: Candidate) ![]u8;
pub fn renderPreviewMarkdown(allocator: std.mem.Allocator, candidate: Candidate, save_path: []const u8) ![]u8;
```

Parsing rules:

- JSON root must be an object.
- `name`, `description`, `body`, and `source_summary` must be strings.
- `name` is normalized through `normalizeSlug`.
- `description` and `body` are trimmed.
- Empty `description` or `body` returns `error.InvalidCandidate`.
- Rendered `SKILL.md` size must be less than or equal to `skill_registry.MAX_SKILL_MD_BYTES`.
- If candidate body already contains frontmatter, strip it and render one canonical frontmatter block.
- Candidate text is checked with `containsSensitiveMaterial`; unredacted sensitive content returns `error.SensitiveCandidate`.

Canonical `SKILL.md` rendering:

```markdown
---
name: example-skill
description: Example description.
---

# Example Skill

Body text.
```

Preview rendering includes the save path and source summary, but `source_summary` is not included in the saved Markdown.

Tests:

- Valid JSON renders frontmatter and body with a final newline.
- Missing `body` returns `error.InvalidCandidate`.
- Non-string `name` returns `error.InvalidCandidate`.
- Existing frontmatter in `body` is not duplicated.
- Sensitive candidate body returns `error.SensitiveCandidate`.

- [x] **Step 6: Implement context shaping and distiller prompt**

Add:

```zig
pub const distiller_system_prompt =
    \\You distill one WispTerm AI Chat transcript into one reusable Codex skill.
    \\Return only compact JSON with string fields: name, description, body, source_summary.
    \\Do not include secrets, tokens, passwords, API keys, private host credentials, or one-off machine paths as requirements.
    \\Prefer reusable procedures with sections: When To Use, Preconditions, Steps, Verification, Pitfalls.
;

pub fn buildDistillUserPrompt(
    allocator: std.mem.Allocator,
    topic: []const u8,
    turns: []const DistillTurn,
) ![]u8;
```

Context rules:

- Include at most the latest 32 turns.
- Include user and assistant messages.
- Include tool messages only when `replay_to_model` is true or the content begins with `running `.
- Apply `redactSensitive` before returning the prompt.
- If there is no user or assistant content after filtering, return `error.NotEnoughContext`.
- Include the topic only as guidance, never as a command to ignore the transcript.

Tests:

- Simple empty transcript returns `error.NotEnoughContext`.
- Tool progress with `running exec` is included.
- Non-replayable local slash output is excluded.
- Prompt output redacts secrets before returning.

- [x] **Step 7: Implement automatic suggestion heuristic**

Add:

```zig
pub const SuggestionInput = struct {
    turns: []const DistillTurn,
    pending_candidate: bool,
    suggestion_pending: bool,
    last_suggested_turn_count: usize = 0,
};

pub fn shouldSuggest(input: SuggestionInput) bool;
```

Rules:

- Return false when `pending_candidate` or `suggestion_pending` is true.
- Return false when `turns.len <= last_suggested_turn_count`.
- Return true if at least two recent tool messages begin with `running `.
- Return true if recent user text contains `以后还会用`, `记住这个流程`, `下次直接用`, `distill this`, `save this workflow`, or `remember this workflow`.
- Return true if recent assistant text mentions reusable steps after a tool-heavy interaction.
- Return false for simple user and assistant Q&A with no tool activity.

Tests:

- Two `running ` tool messages suggest.
- Strong user intent suggests.
- Pending candidate suppresses.
- Already suggested turn count suppresses.
- Local slash output alone does not suggest.

- [x] **Step 8: Register the module in fast tests**

Modify `src/test_fast.zig`:

```zig
    _ = @import("ai_skill_distill.zig");
```

Run:

```powershell
zig build test
```

Expected result: all fast tests pass, including the new `ai_skill_distill.zig` tests.

---

## Task 2: Add Slash Command and Alias Parsing

**Files:**
- Modify: `src/ai_chat_composer.zig`

- [x] **Step 1: Add the enum value and visible command entry**

Add `distill` to `SlashCommand` before `unknown`.

Add a visible slash command entry:

```zig
.{
    .suggestion = .{ .command = "/distill", .description = "distill this conversation into a reusable skill" },
    .action = .distill,
},
```

Only `/distill` appears in suggestions and `/commands`. `/沉淀` is an accepted alias but does not need to appear in the default suggestion list.

- [x] **Step 2: Add alias-aware exact matching**

Add:

```zig
pub fn isDistillAlias(token: []const u8) bool {
    return std.mem.eql(u8, token, "/distill") or std.mem.eql(u8, token, "/沉淀");
}
```

Update `parseSlashCommand` and `exactBuiltinCommand` so both `/distill` and `/沉淀` return `.distill`.

Keep unknown slash behavior unchanged: `/help` without args still maps to `.unknown`; `/usr/bin path` still falls through as prompt text.

- [x] **Step 3: Update composer tests**

Adjust tests in `ai_chat_composer.zig`:

- Slash suggestion count increases from 10 to 11.
- `/distill` parses as `.distill`.
- `/沉淀` parses as `.distill`.
- `exactBuiltinCommand("/沉淀")` returns `.distill`.
- `/沉淀 主题` does not parse through `parseSlashCommand`, because `submit()` handles first-token command plus args.

Run:

```powershell
zig build test
```

Expected result: composer tests pass through the fast test aggregate.

---

## Task 3: Add Writable User Skill Save Path

**Files:**
- Modify: `src/ai_chat_skills.zig`

- [x] **Step 1: Expose only the user-config skills root**

Add:

```zig
pub fn defaultWritableSkillRootPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.skillsDir(allocator);
}
```

This helper must not return `platform_dirs.pluginSkillsDir`, repository `skills`, repository `plugins/skills`, executable-adjacent paths, or bundle resource paths.

- [x] **Step 2: Add confirmed candidate write helper**

Import `ai_skill_distill.zig` and add:

```zig
pub const DistilledSkillSaveResult = struct {
    skill_name: []u8,
    skill_path: []u8,

    pub fn deinit(self: *DistilledSkillSaveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.skill_path);
        self.* = undefined;
    }
};

pub fn saveDistilledCandidate(
    allocator: std.mem.Allocator,
    candidate: ai_skill_distill.Candidate,
) !DistilledSkillSaveResult;
```

Behavior:

- Get root from `defaultWritableSkillRootPath`.
- Create root if missing.
- Create `<root>/<candidate.name>` using exclusive directory creation.
- Return `error.SkillAlreadyExists` if the directory already exists.
- Render Markdown with `ai_skill_distill.renderSkillMarkdown`.
- Refuse to write if rendered content exceeds `skill_registry.MAX_SKILL_MD_BYTES`.
- Write `<root>/<candidate.name>/SKILL.md` through `std.fs.Dir.atomicFile` and `finish`.
- Return owned `skill_name` and owned absolute or platform path for `SKILL.md`.

The caller owns and deinitializes the candidate separately; this helper does not take candidate ownership.

- [x] **Step 3: Add path and overwrite tests**

Use `platform_dirs.setTestConfigDirForCurrentThread()` in tests so no real config directory is touched.

Tests:

- `defaultWritableSkillRootPath` resolves to `<test-config>/skills`.
- `saveDistilledCandidate` creates `<test-config>/skills/<slug>/SKILL.md`.
- A second save with the same slug returns `error.SkillAlreadyExists`.
- The saved Markdown contains canonical frontmatter.
- The saved Markdown does not contain `source_summary`.

Run:

```powershell
zig build test
```

Expected result: fast tests pass if the module remains in the fast-safe dependency graph. If `ai_chat_skills.zig` is not in `test_fast`, run `zig build test-full` for these tests.

---

## Task 4: Add Session State and Manual `/distill` Flow

**Files:**
- Modify: `src/ai_chat.zig`

- [x] **Step 1: Import distillation helpers and add session fields**

Add:

```zig
const ai_skill_distill = @import("ai_skill_distill.zig");
```

Add fields to `Session`:

```zig
distill_candidate: ?ai_skill_distill.Candidate = null,
distill_suggestion_pending: bool = false,
distill_last_suggested_turn_count: usize = 0,
distill_inflight: bool = false,
```

`distill_inflight` is a local discriminator for the shared `request_thread` and `request_inflight` machinery. It prevents normal assistant completion code from interpreting a distiller request as a chat reply.

Update `Session.deinit()`:

```zig
if (self.distill_candidate) |*candidate| candidate.deinit(self.allocator);
```

- [x] **Step 2: Add local message helpers**

Add locked helpers:

```zig
fn appendLocalToolMessageLocked(self: *Session, text: []const u8) !void {
    const content = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(content);
    try self.messages.append(self.allocator, .{
        .role = .tool,
        .content = content,
        .replay_to_model = false,
        .persist_to_history = false,
        .content_collapsed = false,
        .content_auto_expand = false,
    });
    self.scroll_px = 1_000_000;
}

fn clearDistillCandidateLocked(self: *Session) void {
    if (self.distill_candidate) |*candidate| candidate.deinit(self.allocator);
    self.distill_candidate = null;
}
```

Then update `runBuiltinCommandLocked()` to use `appendLocalToolMessageLocked()` for existing local slash outputs. Keep existing behavior identical for all non-distill commands.

- [x] **Step 3: Special-case `/distill` before generic built-in handling**

In `submit()`, after `first_tok` and `arg` are computed and before the generic built-in command branch, add a distill branch:

```zig
if (ai_chat_composer.exactBuiltinCommand(first_tok)) |command| {
    if (command == .distill) {
        self.mutex.unlock();
        self.submitDistillCommand(arg);
        return;
    }
}
```

`submitDistillCommand()` owns its own locking so it can unlock during disk writes or thread spawning without reusing a stale lock state.

- [x] **Step 4: Implement `submitDistillCommand()`**

Add:

```zig
fn submitDistillCommand(self: *Session, arg: []const u8) void {
    const parsed = ai_skill_distill.parseCommandArgs(arg);
    switch (parsed.action) {
        .start => self.startDistillRequest(parsed.topic),
        .confirm => self.confirmDistillCandidate(),
        .cancel => self.cancelDistillCandidate(),
    }
}
```

Implementation rules:

- `.start` requires an API key and enough reusable context.
- `.confirm` and `.cancel` do not require an API key.
- Manual `/distill` clears `distill_suggestion_pending`.
- Local outputs are non-persisted tool messages and are not replayed to the model.

- [x] **Step 5: Implement confirm and cancel**

`cancelDistillCandidate()`:

- Lock session.
- Clear pending candidate and pending suggestion.
- Clear submitted input.
- Append `Distill candidate discarded.` as a local tool message.
- Set status to `Ready`.

`confirmDistillCandidate()`:

- Lock session.
- If no candidate exists, clear input, append `No distill candidate is waiting for confirmation.`, set status to `Ready`, unlock, return.
- Move the candidate out of `self.distill_candidate`.
- Clear pending suggestion and input.
- Unlock.
- Call `ai_chat_skills.saveDistilledCandidate(self.allocator, candidate)`.
- Relock.
- On success, append:

```text
Distilled skill: $<name>
Saved to: <path>
```

- On `error.SkillAlreadyExists`, append:

```text
A skill named $<name> already exists. Use /distill with a more specific topic or remove the old skill first.
```

- On other errors, append `Could not save distilled skill: <error>`.
- On success, call `self.freeSkillSuggestions()` so `$<name>` is available on next skill suggestion load.
- Candidate ownership is always released exactly once.

- [x] **Step 6: Implement distill request construction**

Add `buildDistillRequestLocked(topic: []const u8) !*ChatRequest`.

Behavior:

- Convert `self.messages.items` to `[]ai_skill_distill.DistillTurn`.
- Call `ai_skill_distill.buildDistillUserPrompt`.
- Build a `ChatRequest` with:

```zig
.system_prompt = try self.allocator.dupe(u8, ai_skill_distill.distiller_system_prompt),
.messages = one user RequestMessage containing the distill prompt,
.stream = false,
.agent_enabled = false,
.copilot = false,
.tool_host = null,
.tool_snapshot = null,
.weixin_reply_context = null,
.started_ms = std.time.milliTimestamp(),
```

- Reuse `base_url`, `api_key`, `model`, `protocol`, `thinking_enabled`, `reasoning_effort`, and `max_tokens` from the session.
- Do not include tools in the distiller request.
- Do not mutate normal conversation history.

- [x] **Step 7: Implement request start**

`startDistillRequest(topic)`:

- Join an old completed `request_thread` using the same pattern as `submit()`.
- If a request is already inflight, append `Wait for the current AI request to finish before distilling.` and return.
- If API key is missing, set the existing missing-key status and return.
- Clear any old candidate.
- Build the distill request.
- Clear submitted input.
- Set `request_inflight = true`, `request_stopping = false`, `distill_inflight = true`, `distill_suggestion_pending = false`.
- Append `Distilling a reusable skill candidate.` as a local tool message.
- Set status to `Distilling skill.`.
- Spawn `ai_chat_request.distillThreadMain`.
- On spawn failure, deinit the request, reset inflight flags, append `Failed to start distill request thread.`, and set status to `Ready`.

Run:

```powershell
zig build test-full
```

Expected result: existing AI Chat tests and compile checks pass.

---

## Task 5: Add Distiller Request Worker

**Files:**
- Modify: `src/ai_chat_request.zig`
- Modify: `src/ai_chat.zig`

- [x] **Step 1: Add a worker entry point**

In `ai_chat_request.zig`, import `ai_skill_distill.zig` and add:

```zig
pub fn distillThreadMain(request: *ChatRequest) void {
    const allocator = request.allocator;
    defer request.deinit();

    const result = runChatRequestForMessages(request, request.messages, false) catch |err| {
        if (ai_chat.requestCancelled(request)) {
            ai_chat.finishStoppedRequest(request.session);
            return;
        }
        ai_chat.failDistillRequest(request.session, err);
        return;
    };
    defer result.deinit(allocator);

    if (ai_chat.requestCancelled(request)) {
        ai_chat.finishStoppedRequest(request.session);
        return;
    }

    var candidate = ai_skill_distill.parseCandidateJson(allocator, result.content, "") catch |err| {
        ai_chat.failDistillRequest(request.session, err);
        return;
    };
    ai_chat.applyDistillCandidate(request.session, &candidate);
}
```

The candidate is transferred to the session in `applyDistillCandidate`; the worker must not deinit it after a successful transfer.

- [x] **Step 2: Add session completion helpers**

In `ai_chat.zig`, add public helpers:

```zig
pub fn applyDistillCandidate(session: *Session, candidate: *ai_skill_distill.Candidate) void;
pub fn failDistillRequest(session: *Session, err: anyerror) void;
```

`applyDistillCandidate`:

- Lock session.
- Verify the session is not closing or stopped.
- Clear any existing pending candidate.
- Move the candidate into `session.distill_candidate`.
- Compute the eventual save path using `ai_chat_skills.defaultWritableSkillRootPath`.
- Render preview via `ai_skill_distill.renderPreviewMarkdown`.
- Append preview as a non-persisted local tool message.
- Append clear instructions inside the preview:

```text
Confirm with /distill confirm or /沉淀 确认.
Cancel with /distill cancel or /沉淀 取消.
```

- Set `request_inflight = false`, `request_stopping = false`, `distill_inflight = false`.
- Set status to `Distill preview ready`.

`failDistillRequest`:

- Lock session.
- Reset request and distill flags.
- Clear pending candidate.
- Append `Could not distill this conversation: <error>.` as a local tool message.
- Set status to `Ready`.

- [x] **Step 3: Keep normal assistant completion separated**

In `appendAssistantResult()` and `finishAssistantStream()`, assert by behavior that `distill_inflight` is false before normal assistant messages are appended. Do not route distiller output through assistant history.

Run:

```powershell
zig build test-full
```

Expected result: distiller worker compiles without changing normal request behavior.

---

## Task 6: Add Automatic Suggestion and Keyboard Handling

**Files:**
- Modify: `src/ai_chat.zig`

- [x] **Step 1: Convert current session messages to distill turns**

Add locked helper:

```zig
fn allocDistillTurnsLocked(self: *Session) ![]ai_skill_distill.DistillTurn;
```

The returned slice borrows message content and is freed as a slice only. It maps roles to `ai_skill_distill.DistillRole` and copies `replay_to_model`.

- [x] **Step 2: Append pending suggestion after assistant completion**

Add locked helper:

```zig
fn maybeAppendDistillSuggestionLocked(self: *Session) void;
```

Behavior:

- Build borrowed distill turns.
- Call `ai_skill_distill.shouldSuggest`.
- If false, return.
- Append local tool message:

```text
This task looks reusable. Distill it into a skill?
Press Enter to preview /distill, or Esc to ignore.
```

- Set `distill_suggestion_pending = true`.
- Set `distill_last_suggested_turn_count = turns.len`.

Call this helper in:

- `appendAssistantResult()` after the assistant message is appended and before `history_change = session.captureHistoryChangeLocked()`.
- `finishAssistantStream()` after usage footer/status updates and before unlock.

The suggestion message is non-persisted, so it does not change history snapshots.

- [x] **Step 3: Accept or dismiss the pending suggestion from keyboard**

Add:

```zig
fn acceptDistillSuggestion(self: *Session) bool;
fn dismissDistillSuggestion(self: *Session) bool;
```

Rules:

- Only act when `distill_suggestion_pending` is true.
- Only act when the composer input is empty and there is no active transcript or input selection.
- Enter starts `startDistillRequest("")`.
- Escape clears `distill_suggestion_pending`, appends `Distill suggestion ignored.` as a local tool message, sets status to `Ready`, and returns true so it does not trigger double-ESC rewind.

Update `handleKeyWithWrapCols()`:

- Before the double-ESC rewind block, call `dismissDistillSuggestion()` for `.escape`.
- In the `.enter` branch, before composer completion and submit, call `acceptDistillSuggestion()` when `ev.shift` is false.

- [x] **Step 4: Add session-level tests where available**

Add tests near existing `ai_chat.zig` tests if the existing test graph supports them:

- Tool-heavy transcript appends one suggestion after assistant completion.
- A second assistant completion without new turns does not append a duplicate suggestion.
- Escape dismisses a pending suggestion and does not open rewind.
- Enter on a pending suggestion with empty input attempts to start distillation; use a missing API key case to assert no request thread is spawned and status reports missing key.

Run:

```powershell
zig build test-full
```

Expected result: no regression in rewind, slash commands, streaming completion, or local tool message rendering.

---

## Task 7: Documentation

**Files:**
- Modify: `docs/ai-agent.md`
- Modify: `README.md`

- [x] **Step 1: Document usage in `docs/ai-agent.md`**

Add a section named `Skill Distillation` with:

- Manual commands: `/distill`, `/distill <topic>`, `/沉淀`, `/沉淀 <主题>`.
- Preview and confirmation flow: `/distill confirm`, `/沉淀 确认`, `/distill cancel`, `/沉淀 取消`.
- Automatic suggestion behavior: Enter previews, Esc ignores.
- Safety behavior: no silent writes, redaction before model call, redaction before write, no plugin directory writes, no overwrite.
- Save location: user config `skills/<slug>/SKILL.md`.

- [x] **Step 2: Mention capability in `README.md`**

Add one short AI Agent capability sentence. Do not edit the keyboard shortcuts section because this feature does not change application keyboard shortcuts.

Run:

```powershell
zig build test
```

Expected result: documentation changes do not affect tests.

---

## Task 8: Final Verification

**Files:**
- All changed files

- [x] **Step 1: Run fast tests**

```powershell
zig build test
```

Expected result: all fast tests pass.

- [x] **Step 2: Run full test suite**

```powershell
zig build test-full
```

Expected result: all full tests and compile checks pass.

- [x] **Step 3: Run Windows checkout safety checks**

Because this feature adds `src/ai_skill_distill.zig` and documentation, run the path-safety checks from `docs/development.md#windows-checkout-safety`.

Use the documented PowerShell script for reserved names, illegal characters, case-fold collisions, and path length. Then run:

```powershell
git ls-files -s | Select-String '^120000'
```

Expected result: zero violations, zero case-fold collisions, no symlink entries introduced by this change.

- [ ] **Step 4: Manual smoke test**

Run the app with an AI profile that has an API key.

Manual checks:

- `/distill` on an empty or trivial chat shows `Not enough reusable context to distill yet.` and does not call the model.
- A tool-heavy agent task produces the automatic suggestion.
- Enter on the suggestion starts preview generation.
- Esc on the suggestion dismisses it and does not open rewind.
- `/distill <topic>` produces a preview block with name, description, save path, body, source summary, and confirm/cancel instructions.
- `/distill cancel` discards the candidate.
- `/distill confirm` writes `<config>/skills/<slug>/SKILL.md`.
- `$<slug>` appears in skill suggestions after confirmation.
- A repeated confirmation for an existing slug refuses to overwrite.
- Generated `SKILL.md` contains no source summary and no unredacted secret patterns.

- [x] **Step 5: Confirm untouched areas**

Verify:

- No files under `remote/` changed.
- No desktop version surfaces changed.
- No terminal VT, PTY, renderer, or platform window behavior changed.
- No writes target repository `plugins/skills` or config `plugins/skills`.

Run:

```powershell
git status --short
```

Expected result: only planned source and documentation files changed.

---

## Implementation Notes

- Use the existing shared `request_thread` and `request_inflight` fields for distiller requests, with `distill_inflight` as the discriminator. This keeps cancellation and shutdown behavior aligned with normal AI requests.
- Do not persist preview, suggestion, confirm, cancel, or distill progress local tool messages to agent history.
- Do not replay distillation local tool messages to the model.
- Do not auto-write a skill from the automatic suggestion. The automatic path only starts the same preview flow as manual `/distill`.
- Do not overwrite existing skill directories in the first implementation.
- Do not write to `plugins/skills`; that directory is for installed plugin/bundled skills, not user-distilled skills.
