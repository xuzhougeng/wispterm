# In-Session Model Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user switch the active AI chat/Copilot session to a different saved AI profile via `/model` or by clicking the header model label, with the new model summarizing the prior transcript in the background into a collapsible "上文摘要" card.

**Architecture:** A new pure module `ai_model_switch.zig` holds the testable logic (slash gate, profile-name match, summary prompt + transcript builder, marker/card-content). The live profile swap is a new `pub` Session method `applyProviderProfile` (private `copy*` setters can't be called from `overlays.zig`). Summarization mirrors the existing background one-shot pattern (`maybeAutoTitle`/`distillThreadMain`): a self-contained `SummaryRequest` runs against the just-swapped (new) profile and, on success, splices the pre-switch messages into a single `.user`-role card flagged `is_context_summary`. The splice runs under `session.mutex`; this is safe because every request worker snapshots its `RequestMessage[]` under the mutex at request start (`buildRequestMessagesLocked` is `*Locked`), so mutating `session.messages` after a request is in flight never races its network IO.

**Tech Stack:** Zig. Tests: pure logic in the fast suite (`zig build test-fast` / `zig test src/<file>.zig`); Session-level logic in the full suite (`zig build test`). UI glue (renderer/overlays/input) verified by build-green + windows-gnu cross-compile + manual GUI (consistent with this project's handling of UI glue).

---

## Key facts (verbatim anchors)

- `SlashCommand` enum + `slash_command_entries` + `parseSlashCommand`/`exactBuiltinCommand`/`memoryCommandAlias`/`slashCommandTokenEnd`: `src/ai_chat_composer.zig` (enum 6-24, entries 66-131, parsers 149-234).
- Slash submit dispatch: `src/ai_chat.zig:1774-1826` (extracts `first_tok`/`arg`, calls `runBuiltinCommandLocked`, then `fireDeferredAction`).
- `BuiltinResult`/`DeferredAction`/`fireDeferredAction`/trigger globals+setters: `src/ai_chat.zig:298-321, 330-379`.
- `runBuiltinCommandLocked`: `src/ai_chat.zig:2109-2164`.
- `Session` struct: `src/ai_chat.zig:564-649`. `Message` struct (incl. `model_context`, `content_collapsed`): `79-110`. Setters `copyBaseUrl/copyApiKey/copyModel/copyReasoningEffort/copySystemPrompt`: `3528-3551`. `deinit` (thread joins): `880-902`. `appendLocalToolMessageLocked`: `1723-1735`. `toggleToolMessageCollapsed`: `1603-1611`. Accessors `baseUrl/apiKey/model/systemPrompt`: `908-925`. `captureHistoryChangeLocked`/`notifyHistoryChange`/`setStatusLocked`: `3492-3510, 3576`. `DEFAULT_NAME`: `43`. `maybeAutoTitle`/`buildTitleRequestLocked`/`applyGeneratedTitle`: `3839-3874, 3786-3830, 3775-3780`. `appendAssistantResult`/`finishStoppedRequest`: `3880-3939, 3759+`. `WebSearchRequest` (wrapper pattern): `211-228`.
- `ChatRequest` struct/deinit: `src/ai_chat.zig:150-191`. `runChatRequestForMessages`: `src/ai_chat_request.zig:441` → `!ApiResult`. `titleThreadMain`/`distillThreadMain`: `src/ai_chat_request.zig:90-130`. `RequestMessage`/`ApiResult`/`Role`/`ApiProtocol.parse`: `src/ai_chat_protocol.zig:140-168, 182-196, 83-94, 22-44`.
- `buildRequestMessagesLocked` (role passthrough, `model_context` append, tool filtering): `src/ai_chat.zig:3152-3210`.
- Overlays picker: `AiListMode` (`1881-1885`), `g_ai_list_*` threadlocals (`1925, 1943-1948`), `openAiList` (`3247-3257`), `runAiListRow` (`3535-3566`), `.enter => runAiListRow` (`3516`), mouse `sessionLauncherExecuteAt`→`.connect_ai_selected => runAiListRow` (`2263-2290`), `spawnAiProfileWithAgentOverride` (`3671-3691`), `aiProfileField`=`profile_codec.aiProfileField`, `hasAiProfiles` (`3276`), `loadAiProfiles` (`3857`), `isHttpUrlish`, `g_ai_profiles`/`g_ai_profile_count`/`AI_PROFILE_MAX=16`, `AiField` (`profile_codec.zig:27-40`).
- Renderer: consts `HEADER_H=54`,`LINE_PAD_X=18`,`PERMISSION_CHIP_W=104`,`PERMISSION_CHIP_H=24`,`MODE_SLOT_W=76`,`STATUS_SLOT_W=280` (`src/renderer/ai_chat_renderer.zig:28-38`); `permissionChipX` (`1119-1125`); model-label draw (`165-181`); `permissionChipHitTest` (`550-568`); `statusActionRect`/`measureText` (`1131-1144`); render dispatch `msg.role == .tool` (`323`); hit-test `msg.role == .tool` (`421-426`); `messageBlockHeight` (`788-793`); `renderToolCard` (`909-956`, `toolSectionMeta` at `1390`). `Rect`/`pointInRect`: `src/ai_chat_layout.zig:14-30`.
- Input click handler: copilot path uses `AppWindow.activeCopilotSessionForInput()` + `ai_sidebar.boundsForWindow` (`src/input.zig:4228-4317`); tab path uses `AppWindow.activeAiChat()` + `leftPanelsWidth()/rightPanelsWidthForWindow()` (`4323+`); `.toggle_tool`/`.toggle_reasoning` dispatch (`4285-4297, 4366-4376`); permission/missing-key hit-test blocks (`4261-4274, 4300-4310, 4340-4353, 4379-4389`).
- AppWindow: `activeAiChat` (`1189-1191`), `spawnAiChatTab` (`4060-4073`), `g_force_rebuild`/`g_cells_valid` (`4451-4452`), trigger registration site (`138-148`).
- i18n: flat `Strings` struct + English block + zh-CN block + `i18n.s()` lookup (`src/i18n.zig`).

---

## Task 1: Add `/model` slash command parsing

**Files:**
- Modify: `src/ai_chat_composer.zig` (enum 6-24, alias helper after 180, entries 66-131)
- Test: `src/ai_chat_composer.zig` (in-file tests)

- [ ] **Step 1: Write the failing test** — append after the existing `parseSlashCommand` tests (near line 420):

```zig
test "parseSlashCommand recognizes model switch and alias" {
    try std.testing.expectEqual(SlashCommand.model_switch, parseSlashCommand("/model").?);
    try std.testing.expectEqual(SlashCommand.model_switch, parseSlashCommand("/模型").?);
    try std.testing.expectEqual(SlashCommand.model_switch, exactBuiltinCommand("/model").?);
    try std.testing.expectEqual(SlashCommand.model_switch, exactBuiltinCommand("/模型").?);
    // "/model GPT-5" is dispatched by exactBuiltinCommand on the first token only:
    try std.testing.expectEqual(SlashCommand.model_switch, exactBuiltinCommand("/model").?);
    // parseSlashCommand on the whole string with an arg must NOT match (has a space):
    try std.testing.expectEqual(@as(?SlashCommand, null), parseSlashCommand("/model GPT-5"));
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig test src/ai_chat_composer.zig`
Expected: FAIL — `model_switch` is not a member of `SlashCommand`.

- [ ] **Step 3: Implement** — add the enum member (after `forget,` at line 22):

```zig
    forget,
    model_switch,
    unknown,
```

Add the alias helper after `memoryCommandAlias` (after line 180):

```zig
pub fn modelCommandAlias(token: []const u8) ?SlashCommand {
    if (std.mem.eql(u8, token, "/模型")) return .model_switch;
    return null;
}
```

Call it inside `parseSlashCommand` (after the `memoryCommandAlias` line at 153) and `exactBuiltinCommand` (after line 164):

```zig
    if (memoryCommandAlias(trimmed)) |c| return c;
    if (modelCommandAlias(trimmed)) |c| return c;
```
```zig
    if (memoryCommandAlias(token)) |c| return c;
    if (modelCommandAlias(token)) |c| return c;
```

Add the dropdown entry to `slash_command_entries` (after the `/forget` entry, line 130):

```zig
    .{
        .suggestion = .{ .command = "/model", .description = "switch the model / AI profile" },
        .action = .model_switch,
    },
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig test src/ai_chat_composer.zig`
Expected: PASS (all composer tests).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_composer.zig
git commit -m "feat(ai-chat): add /model slash command + /模型 alias parsing"
```

---

## Task 2: Pure `ai_model_switch.zig` — gate, name match, summary prompt + transcript builder, marker/card

**Files:**
- Create: `src/ai_model_switch.zig`
- Modify: `src/test_fast.zig` and `src/test_main.zig` (register the new module's tests — see Step 5)

- [ ] **Step 1: Write the failing tests** — create `src/ai_model_switch.zig` with the tests first (implementation stubs added in Step 3):

```zig
//! Pure logic for in-session model switching: the summarization prompt, the
//! transcript-to-prompt builder, the "is there anything to summarize?" gate,
//! case-insensitive profile-name matching for `/model <name>`, and the summary
//! card marker/content formatting. No Session / GL / AppWindow dependency, so it
//! is unit-tested in the fast suite. Threading + Session mutation stay in
//! ai_chat.zig; overlay/input/render glue stays in their files.
const std = @import("std");

pub const Role = @import("ai_chat_protocol.zig").Role;

/// Max bytes taken from each message when rendering the transcript for the
/// summary prompt. Truncated on a UTF-8 boundary.
pub const max_msg_bytes: usize = 2000;

/// Hard cap on the assembled transcript so a very long conversation can't blow
/// the request budget. Truncated on a UTF-8 boundary.
pub const max_transcript_bytes: usize = 24000;

pub const system_prompt =
    \\You are compacting a chat conversation so it can continue seamlessly with a different model.
    \\Summarize the conversation so far: the user's goal, key facts and decisions, the current state,
    \\any pending task or next step, and important details from tool results. Be concise but complete.
    \\Write the summary in the same language the user is using. Output only the summary.
;

pub const TurnMessage = struct {
    role: Role,
    content: []const u8,
};

/// Largest length <= `limit` that does not split a UTF-8 codepoint.
pub fn utf8SafeLen(s: []const u8, limit: usize) usize {
    if (s.len <= limit) return s.len;
    var end = limit;
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return end;
}

/// True only when there is prior user AND assistant content worth summarizing.
/// An empty / greeting-only conversation (no assistant reply yet) returns false,
/// so a switch then just swaps config with no summary call.
pub fn shouldSummarize(turns: []const TurnMessage) bool {
    var has_user = false;
    var has_assistant = false;
    for (turns) |t| {
        switch (t.role) {
            .user => if (t.content.len > 0) {
                has_user = true;
            },
            .assistant => if (t.content.len > 0) {
                has_assistant = true;
            },
            .tool => {},
        }
    }
    return has_user and has_assistant;
}

/// Case-insensitive exact match of `query` against `names`. Returns the index of
/// the first match, or null (empty query also returns null).
pub fn matchProfileByName(names: []const []const u8, query: []const u8) ?usize {
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return null;
    for (names, 0..) |name, i| {
        if (std.ascii.eqlIgnoreCase(name, q)) return i;
    }
    return null;
}

/// Render the transcript into the single user message for the summary request.
/// Each message is labelled by role and capped at `max_msg_bytes`; the whole
/// thing is capped at `max_transcript_bytes`. Both truncations are UTF-8 safe.
pub fn buildSummaryUserContent(allocator: std.mem.Allocator, turns: []const TurnMessage) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (turns) |t| {
        const label = switch (t.role) {
            .user => "User",
            .assistant => "Assistant",
            .tool => "Tool",
        };
        const slice = t.content[0..utf8SafeLen(t.content, max_msg_bytes)];
        try buf.appendSlice(allocator, label);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, slice);
        try buf.appendSlice(allocator, "\n\n");
    }
    const total = utf8SafeLen(buf.items, max_transcript_bytes);
    return allocator.dupe(u8, buf.items[0..total]);
}

/// First line of `summary` shown as the collapsed card's preview, capped.
pub fn cardPreview(summary: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, summary, '\n') orelse summary.len;
    return summary[0..utf8SafeLen(summary[0..nl], 120)];
}

/// The collapsed card body: a marker line naming the source model, then the
/// summary. This whole string is the message content (sent to the model and
/// rendered), so the new model reads the marker as context too.
pub fn composeCardContent(allocator: std.mem.Allocator, from_model: []const u8, summary: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "（已从 {s} 切换；以下为之前对话的摘要 / Summary of the conversation before switching from {s}）\n\n{s}",
        .{ from_model, from_model, summary },
    );
}

test "shouldSummarize requires both user and assistant content" {
    try std.testing.expect(!shouldSummarize(&.{}));
    try std.testing.expect(!shouldSummarize(&.{.{ .role = .user, .content = "hi" }}));
    try std.testing.expect(!shouldSummarize(&.{.{ .role = .assistant, .content = "hello" }}));
    try std.testing.expect(!shouldSummarize(&.{.{ .role = .user, .content = "" }, .{ .role = .assistant, .content = "x" }}));
    try std.testing.expect(shouldSummarize(&.{
        .{ .role = .user, .content = "deploy" },
        .{ .role = .tool, .content = "ran" },
        .{ .role = .assistant, .content = "done" },
    }));
}

test "matchProfileByName is case-insensitive and rejects empty/miss" {
    const names = [_][]const u8{ "Claude", "glm-5.2", "GPT-5" };
    try std.testing.expectEqual(@as(?usize, 0), matchProfileByName(&names, "claude"));
    try std.testing.expectEqual(@as(?usize, 1), matchProfileByName(&names, "GLM-5.2"));
    try std.testing.expectEqual(@as(?usize, 2), matchProfileByName(&names, "  gpt-5 "));
    try std.testing.expectEqual(@as(?usize, null), matchProfileByName(&names, "deepseek"));
    try std.testing.expectEqual(@as(?usize, null), matchProfileByName(&names, "   "));
}

test "buildSummaryUserContent labels roles and is UTF-8 safe" {
    const turns = [_]TurnMessage{
        .{ .role = .user, .content = "goal" },
        .{ .role = .assistant, .content = "answer" },
    };
    const c = try buildSummaryUserContent(std.testing.allocator, &turns);
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "User: goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "Assistant: answer") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c));
}

test "buildSummaryUserContent caps a huge message on a UTF-8 boundary" {
    const big = "一" ** 2000; // 6000 bytes > max_msg_bytes
    const turns = [_]TurnMessage{
        .{ .role = .user, .content = big },
        .{ .role = .assistant, .content = "ok" },
    };
    const c = try buildSummaryUserContent(std.testing.allocator, &turns);
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c));
    try std.testing.expect(c.len <= max_transcript_bytes);
}

test "composeCardContent embeds the source model and summary" {
    const c = try composeCardContent(std.testing.allocator, "glm-5.2", "We did X.");
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "glm-5.2") != null);
    try std.testing.expect(std.mem.endsWith(u8, c, "We did X."));
}
```

- [ ] **Step 2: Run it to verify it fails / is unregistered**

Run: `zig test src/ai_model_switch.zig`
Expected: PASS in isolation (the file is self-contained). Then confirm it is NOT yet in the suites — `grep -n ai_model_switch src/test_fast.zig` returns nothing.

- [ ] **Step 3: Register the module in the fast + full test suites**

In `src/test_fast.zig` and `src/test_main.zig`, add alongside the other `_ = @import("...zig");` reference-imports (match the existing pattern in each file):

```zig
    _ = @import("ai_model_switch.zig");
```

- [ ] **Step 4: Run the fast suite**

Run: `zig build test-fast`
Expected: PASS, including the five `ai_model_switch` tests.

- [ ] **Step 5: Commit**

```bash
git add src/ai_model_switch.zig src/test_fast.zig src/test_main.zig
git commit -m "feat(ai-chat): pure ai_model_switch module (gate, name match, summary prompt/builder)"
```

---

## Task 3: `Message.is_context_summary` flag + collapse toggle

**Files:**
- Modify: `src/ai_chat.zig` (Message struct ~93, `toggleToolMessageCollapsed` 1603-1611)
- Test: `src/ai_chat.zig` (full suite)

- [ ] **Step 1: Write the failing test** — add near the other Session tests in `src/ai_chat.zig`:

```zig
test "is_context_summary messages are collapsible" {
    var session = try Session.initWithVision(std.testing.allocator, "T", "https://x", "k", "m", "chat_completions", "sp", "enabled", "low", "false", "false", "false");
    defer session.deinit();
    const content = try std.testing.allocator.dupe(u8, "summary body");
    try session.messages.append(std.testing.allocator, .{
        .role = .user,
        .content = content,
        .is_context_summary = true,
        .content_collapsed = true,
    });
    try std.testing.expect(session.messages.items[0].content_collapsed);
    session.toggleToolMessageCollapsed(0);
    try std.testing.expect(!session.messages.items[0].content_collapsed);
}
```

> VERIFIED: `Session.init` takes 9 string args (no protocol). The tests use `Session.initWithVision` (allocator + 11 args: name, base_url, api_key, model, **protocol**, system_prompt, thinking, reasoning_effort, stream, agent, **vision**) — `src/ai_chat.zig:777`.

- [ ] **Step 2: Run it to verify it fails**

Run: `zig test src/ai_chat.zig 2>&1 | head -40` (or `zig build test`)
Expected: FAIL — `is_context_summary` is not a field of `Message`, and/or the toggle is gated to `.tool`.

- [ ] **Step 3: Implement** — add the field to `Message` (after `content_auto_expand` at line 94):

```zig
    content_collapsed: bool = false,
    content_auto_expand: bool = false,
    /// Synthetic "上文摘要" card produced by a model switch. Rendered like a
    /// collapsible tool card but sent to the model as a normal user message.
    is_context_summary: bool = false,
```

Relax `toggleToolMessageCollapsed` (line 1608):

```zig
        if (msg.role != .tool and !msg.is_context_summary) return;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS (new test + existing suite).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): Message.is_context_summary flag + collapsible toggle"
```

---

## Task 4: Session summary machinery + `.model_switch` dispatch + trigger

**Files:**
- Modify: `src/ai_chat.zig` (DeferredAction 298-310; trigger globals/setters 330-379; Session fields 564-649; deinit 880-902; `runBuiltinCommandLocked` 2109-2164; new fns near `buildTitleRequestLocked` 3786 and `applyGeneratedTitle` 3775)
- Modify: `src/ai_chat_request.zig` (new `summaryThreadMain` near `titleThreadMain` 90)
- Test: `src/ai_chat.zig` (full suite)

- [ ] **Step 1: Write the failing test** — splice integration test in `src/ai_chat.zig`:

```zig
test "applySummaryResult collapses pre-switch messages into one summary card" {
    var session = try Session.initWithVision(std.testing.allocator, "T", "https://x", "k", "m", "chat_completions", "sp", "enabled", "low", "false", "false", "false");
    defer session.deinit();
    inline for (.{ "u1", "a1", "u2" }) |t| {
        try session.messages.append(std.testing.allocator, .{
            .role = .user,
            .content = try std.testing.allocator.dupe(u8, t),
        });
    }
    // boundary = 2 means: collapse the first 2 messages, preserve message[2..].
    applySummaryResult(session, "SUMMARY", 2, "glm-5.2");
    try std.testing.expectEqual(@as(usize, 2), session.messages.items.len);
    try std.testing.expect(session.messages.items[0].is_context_summary);
    try std.testing.expectEqual(Role.user, session.messages.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, session.messages.items[0].content, "SUMMARY") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.messages.items[0].content, "glm-5.2") != null);
    try std.testing.expectEqualStrings("u2", session.messages.items[1].content);
}

test "applySummaryResult is a no-op when boundary exceeds message count" {
    var session = try Session.initWithVision(std.testing.allocator, "T", "https://x", "k", "m", "chat_completions", "sp", "enabled", "low", "false", "false", "false");
    defer session.deinit();
    try session.messages.append(std.testing.allocator, .{ .role = .user, .content = try std.testing.allocator.dupe(u8, "only") });
    applySummaryResult(session, "S", 5, "X"); // stale boundary (e.g. after /clear)
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqualStrings("only", session.messages.items[0].content);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test`
Expected: FAIL — `applySummaryResult` is undefined.

- [ ] **Step 3a: Add the deferred action + trigger** — extend `DeferredAction` (line 298):

```zig
const DeferredAction = union(enum) {
    none,
    resume_picker,
    model_switch_picker,
    export_markdown: MarkdownExportMode,
};
```

Handle it in `fireDeferredAction` (line 315):

```zig
        .resume_picker => if (g_session_resume_trigger) |t| t(),
        .model_switch_picker => if (g_model_switch_trigger) |t| t(),
        .export_markdown => |mode| if (g_markdown_export_trigger) |t| t(mode),
```

Add the trigger global (near line 330) and setter (near line 371):

```zig
var g_model_switch_trigger: ?*const fn () void = null;
```
```zig
/// Wire the callback that `/model` fires (after unlock) to either switch by the
/// pending name or open the profile picker. Lives in the app layer.
pub fn setModelSwitchTrigger(cb: ?*const fn () void) void {
    g_model_switch_trigger = cb;
}
```

- [ ] **Step 3b: Add Session fields** (after `working_dir_len` ~648):

```zig
    summary_thread: ?std.Thread = null,
    pending_model_switch_name_buf: [128]u8 = undefined,
    pending_model_switch_name_len: usize = 0,
```

Join `summary_thread` in `deinit` (after the `title_thread` join, line 890):

```zig
        if (self.summary_thread) |thread| {
            thread.join();
            self.summary_thread = null;
        }
```

- [ ] **Step 3c: Pending-name accessors** — add `pub` methods (near the other accessors ~920):

```zig
    /// Stash the `/model <name>` argument so the app-layer trigger can read it
    /// after the mutex unlocks. Empty arg => open the picker.
    fn setPendingModelSwitchNameLocked(self: *Session, name: []const u8) void {
        self.pending_model_switch_name_len = @min(name.len, self.pending_model_switch_name_buf.len);
        @memcpy(self.pending_model_switch_name_buf[0..self.pending_model_switch_name_len], name[0..self.pending_model_switch_name_len]);
    }

    /// Read + clear the pending `/model` name. Returns a slice into the buffer
    /// valid until the next mutate; copy if you need to keep it.
    pub fn takePendingModelSwitchName(self: *Session) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = self.pending_model_switch_name_buf[0..self.pending_model_switch_name_len];
        self.pending_model_switch_name_len = 0;
        return out;
    }
```

- [ ] **Step 3d: Dispatch `.model_switch`** — add a case to `runBuiltinCommandLocked` (before `else => {}` at line 2149):

```zig
            .model_switch => {
                self.setPendingModelSwitchNameLocked(arg);
                result.deferred = .model_switch_picker;
                self.clearSubmittedInputLocked();
                self.setStatusLocked("Ready");
                result.suppress_output = true;
            },
```

- [ ] **Step 3e: Public provider-swap + summary kickoff** — add near `buildTitleRequestLocked` (~3786):

```zig
/// Swap the live session to a different provider/model (session-only; does not
/// touch the global default). Then, if there is prior conversation, kick off a
/// background summary against the NEW model. The session's system prompt /
/// persona is intentionally left unchanged.
pub fn applyProviderProfile(
    session: *Session,
    base_url: []const u8,
    api_key: []const u8,
    model_name: []const u8,
    protocol_str: []const u8,
    thinking_str: []const u8,
    reasoning_effort: []const u8,
    max_tokens: u32,
    vision_str: []const u8,
) void {
    var sreq: ?*SummaryRequest = null;
    session.mutex.lock();
    locked: {
        // Capture the OLD model name BEFORE swapping, for the summary card marker.
        var old_model_buf: [128]u8 = undefined;
        const old_model_len = @min(session.model().len, old_model_buf.len);
        @memcpy(old_model_buf[0..old_model_len], session.model()[0..old_model_len]);
        const old_model = old_model_buf[0..old_model_len];

        session.copyBaseUrl(base_url);
        session.copyApiKey(api_key);
        session.copyModel(model_name);
        session.protocol = ApiProtocol.parse(protocol_str);
        session.thinking_enabled = !std.mem.eql(u8, thinking_str, "disabled");
        session.copyReasoningEffort(reasoning_effort);
        session.max_tokens = max_tokens;
        session.vision_enabled = std.mem.eql(u8, vision_str, "on") or std.mem.eql(u8, vision_str, "enabled") or std.mem.eql(u8, vision_str, "true");

        // Build the summary snapshot from the messages that exist now.
        const boundary = session.messages.items.len;
        const turns = session.allocator.alloc(ai_model_switch.TurnMessage, boundary) catch break :locked;
        defer session.allocator.free(turns);
        for (session.messages.items, 0..) |m, i| turns[i] = .{ .role = m.role, .content = m.content };
        if (!ai_model_switch.shouldSummarize(turns)) {
            session.setStatusLocked("Model switched");
            break :locked;
        }
        sreq = buildSummaryRequestLocked(session, turns, boundary, old_model) catch break :locked;
        session.setStatusLocked("Summarizing previous context…");
    }
    session.mutex.unlock();

    const req = sreq orelse return;
    const thread = std.Thread.spawn(.{}, ai_chat_request.summaryThreadMain, .{req}) catch {
        req.deinit();
        session.mutex.lock();
        session.setStatusLocked("Ready");
        session.mutex.unlock();
        return;
    };
    session.mutex.lock();
    session.summary_thread = thread;
    session.mutex.unlock();
}

fn buildSummaryRequestLocked(session: *Session, turns: []const ai_model_switch.TurnMessage, boundary: usize, from_model: []const u8) !*SummaryRequest {
    const allocator = session.allocator;
    const req = try allocator.create(ChatRequest);
    errdefer allocator.destroy(req);

    const base_url = try allocator.dupe(u8, session.baseUrl());
    errdefer allocator.free(base_url);
    const api_key = try allocator.dupe(u8, session.apiKey());
    errdefer allocator.free(api_key);
    const model = try allocator.dupe(u8, session.model());
    errdefer allocator.free(model);
    const system_prompt = try allocator.dupe(u8, ai_model_switch.system_prompt);
    errdefer allocator.free(system_prompt);
    const reasoning_effort = try allocator.dupe(u8, "low");
    errdefer allocator.free(reasoning_effort);

    const user_content = try ai_model_switch.buildSummaryUserContent(allocator, turns);
    errdefer allocator.free(user_content);

    const messages = try allocator.alloc(RequestMessage, 1);
    errdefer allocator.free(messages);
    messages[0] = .{ .role = .user, .content = user_content };

    req.* = .{
        .allocator = allocator,
        .session = session,
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .protocol = session.protocol,
        .system_prompt = system_prompt,
        .messages = messages,
        .thinking_enabled = false,
        .reasoning_effort = reasoning_effort,
        .stream = false,
        .max_tokens = 1024,
        .agent_enabled = false,
        .copilot = false,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };

    const sreq = try allocator.create(SummaryRequest);
    sreq.* = .{ .allocator = allocator, .req = req, .boundary = boundary };
    sreq.setFromModel(from_model);
    return sreq;
}
```

Add the `SummaryRequest` wrapper near `WebSearchRequest` (~211):

```zig
pub const SummaryRequest = struct {
    allocator: std.mem.Allocator,
    req: *ChatRequest,
    boundary: usize,
    from_model_buf: [128]u8 = undefined,
    from_model_len: usize = 0,

    pub fn setFromModel(self: *SummaryRequest, value: []const u8) void {
        self.from_model_len = @min(value.len, self.from_model_buf.len);
        @memcpy(self.from_model_buf[0..self.from_model_len], value[0..self.from_model_len]);
    }
    pub fn fromModel(self: *const SummaryRequest) []const u8 {
        return self.from_model_buf[0..self.from_model_len];
    }
    pub fn deinit(self: *SummaryRequest) void {
        self.req.deinit();
        self.allocator.destroy(self);
    }
};
```

> VERIFIED + FIXED above: the OLD model name is captured as the first statement under the lock in `applyProviderProfile` (before `copyModel`) and threaded into `buildSummaryRequestLocked` as `from_model`, so the card marker names the model you switched *from*.

- [ ] **Step 3f: Apply result + splice** — add near `applyGeneratedTitle` (~3775):

```zig
/// Apply a completed summary: replace messages[0..boundary] with one collapsible
/// "上文摘要" card (role .user, is_context_summary), preserving messages[boundary..].
/// Runs under the mutex; safe even if a request is in flight because each request
/// snapshots its messages under the mutex at start.
pub fn applySummaryResult(session: *Session, summary: []const u8, boundary: usize, from_model: []const u8) void {
    if (session.closing.load(.acquire)) return;
    const allocator = session.allocator;
    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (session.closing.load(.acquire)) return;
    if (boundary > session.messages.items.len) {
        session.setStatusLocked("Ready");
        return; // stale (e.g. /clear happened) — keep raw history
    }
    const content = ai_model_switch.composeCardContent(allocator, from_model, summary) catch {
        session.setStatusLocked("Ready");
        return;
    };
    var new_list: std.ArrayListUnmanaged(Message) = .empty;
    new_list.append(allocator, .{
        .role = .user,
        .content = content,
        .is_context_summary = true,
        .content_collapsed = true,
        .persist_to_history = true,
    }) catch {
        allocator.free(content);
        session.setStatusLocked("Ready");
        return;
    };
    new_list.appendSlice(allocator, session.messages.items[boundary..]) catch {
        // OOM: free the summary we just made, keep raw history intact.
        new_list.items[0].deinit(allocator);
        new_list.deinit(allocator);
        session.setStatusLocked("Ready");
        return;
    };
    // Free only the collapsed pre-switch messages; tail structs were copied by
    // value into new_list (pointer ownership moved).
    for (session.messages.items[0..boundary]) |m| m.deinit(allocator);
    session.messages.deinit(allocator);
    session.messages = new_list;
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Context summarized");
    history_change = session.captureHistoryChangeLocked();
}

/// Summary request failed (e.g. the new model is also overloaded): keep the full
/// raw history, just clear the in-progress status.
pub fn failSummaryResult(session: *Session) void {
    if (session.closing.load(.acquire)) return;
    session.mutex.lock();
    defer session.mutex.unlock();
    session.setStatusLocked("Summary unavailable — kept full history");
}
```

- [ ] **Step 3g: The worker** — add to `src/ai_chat_request.zig` near `titleThreadMain` (~90):

```zig
pub fn summaryThreadMain(sreq: *ai_chat.SummaryRequest) void {
    defer sreq.deinit();
    const session = sreq.req.session;
    const allocator = sreq.req.allocator;
    if (session.closing.load(.acquire)) return;

    const result = runChatRequestForMessages(sreq.req, sreq.req.messages, false) catch {
        ai_chat.failSummaryResult(session);
        return;
    };
    defer result.deinit(allocator);
    if (session.closing.load(.acquire)) return;

    ai_chat.applySummaryResult(session, result.content, sreq.boundary, sreq.fromModel());
}
```

Add `const ai_model_switch = @import("ai_model_switch.zig");` to the imports at the top of `src/ai_chat.zig` if not already present.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS (both splice tests + existing suite).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig src/ai_chat_request.zig
git commit -m "feat(ai-chat): background summary on model switch + /model dispatch + trigger"
```

---

## Task 5: Overlays — switch_model picker mode + in-place apply

**Files:**
- Modify: `src/renderer/overlays.zig` (`AiListMode` 1881-1885, `runAiListRow` 3535-3566, new fns near `spawnAiProfileWithAgentOverride` 3671, threadlocal near 1925)

- [ ] **Step 1: Add the mode + target** — extend `AiListMode` (line 1881):

```zig
const AiListMode = enum {
    manage,
    edit_select,
    delete_select,
    switch_model,
};
```

Add a threadlocal target near `g_ai_list_visible` (~1925):

```zig
threadlocal var g_switch_model_target: ?*AppWindow.ai_chat.Session = null;
```

- [ ] **Step 2: Add the apply + open + by-name functions** — near `spawnAiProfileWithAgentOverride` (~3691):

```zig
/// Apply profile `idx` to the given live session in place (provider/model only)
/// and kick off the background summary. Returns false on an invalid profile.
fn applyProfileToSession(session: *AppWindow.ai_chat.Session, idx: usize) bool {
    if (idx >= g_ai_profile_count) return false;
    const profile = &g_ai_profiles[idx];
    const base_url = aiProfileField(profile, .base_url);
    const api_key = aiProfileField(profile, .api_key);
    const model = aiProfileField(profile, .model);
    const thinking = aiProfileField(profile, .thinking);
    const reasoning_effort = aiProfileField(profile, .reasoning_effort);
    const protocol = aiProfileField(profile, .protocol);
    const max_tokens = std.fmt.parseInt(u32, std.mem.trim(u8, aiProfileField(profile, .max_tokens), " \t"), 10) catch 8192;
    const vision_val = aiProfileField(profile, .vision);
    if (base_url.len == 0 or model.len == 0) return false;
    if (!isHttpUrlish(base_url)) return false;
    session.applyProviderProfile(base_url, api_key, model, protocol, thinking, reasoning_effort, max_tokens, vision_val);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    return true;
}

/// Open the profile picker in switch-model mode, bound to `session`.
pub fn openSwitchModelPicker(session: *AppWindow.ai_chat.Session) void {
    loadAiProfiles();
    if (g_ai_profile_count == 0) {
        session.appendModelSwitchNote(i18n.s().ai_model_no_profiles);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    g_switch_model_target = session;
    openAiList(); // sets visibility flags + mode .manage
    g_ai_list_mode = .switch_model;
    g_ai_list_selected = @min(g_ai_list_selected, aiListRowCount() - 1);
}

/// `/model <name>`: match by name and apply directly; on no match, note the
/// available profiles in the transcript and fall back to opening the picker.
pub fn switchModelByName(session: *AppWindow.ai_chat.Session, name: []const u8) void {
    loadAiProfiles();
    var names: [AI_PROFILE_MAX][]const u8 = undefined;
    for (0..g_ai_profile_count) |i| names[i] = aiProfileField(&g_ai_profiles[i], .name);
    if (ai_model_switch.matchProfileByName(names[0..g_ai_profile_count], name)) |idx| {
        _ = applyProfileToSession(session, idx);
        return;
    }
    session.appendModelSwitchNote(i18n.s().ai_model_unknown_profile);
    openSwitchModelPicker(session);
}
```

> VERIFIED: `overlays.zig` already imports `const ai_chat = @import("../ai_chat.zig");` (line 8) and `const i18n = @import("../i18n.zig");` (line 36). ADD `const ai_model_switch = @import("../ai_model_switch.zig");` near those imports. Use the local `i18n.s()` and `ai_model_switch.*` (NOT `AppWindow.*` — AppWindow does not re-export them). `AppWindow.ai_chat.Session` is fine for the param type (matches the existing `openAiConfigForSession` signature).

Add the `appendModelSwitchNote` `pub` helper to Session in `src/ai_chat.zig` (near `appendLocalToolMessageLocked` ~1735):

```zig
    pub fn appendModelSwitchNote(self: *Session, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.appendLocalToolMessageLocked(text) catch {};
    }
```

- [ ] **Step 3: Route selection** — add the `.switch_model` arm to `runAiListRow` (inside the switch at line 3536):

```zig
        .switch_model => {
            if (row < g_ai_profile_count) {
                if (g_switch_model_target) |session| _ = applyProfileToSession(session, row);
            }
            g_switch_model_target = null;
            sessionLauncherClose();
        },
```

- [ ] **Step 4: Build to verify**

Run: `zig build` (debug)
Expected: compiles. (Overlay rendering is GUI-verified later.)

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays.zig src/ai_chat.zig
git commit -m "feat(ai-chat): switch_model picker mode + in-place profile apply"
```

---

## Task 6: Renderer — summary card rendering + clickable model label

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig` (render dispatch 323; hit-test 421; `messageBlockHeight` 788-793; `renderToolCard` 909-956; new `modelLabelRect`/`modelLabelHitTest` near `permissionChipHitTest` 550)

- [ ] **Step 1: Add the card predicate** — near the top helpers of `ai_chat_renderer.zig`:

```zig
fn rendersAsCard(msg: ai_chat.Message) bool {
    return msg.role == .tool or msg.is_context_summary;
}
```

- [ ] **Step 2: Route height + render + hit-test through it**

`messageBlockHeight` (line 789):

```zig
fn messageBlockHeight(msg: ai_chat.Message, max_w: f32) f32 {
    if (rendersAsCard(msg)) return toolCardHeight(msg, max_w);
    return bubbleHeight(msg.role, msg.content, max_w);
}
```

Render dispatch (line 323): change `if (msg.role == .tool) {` to `if (rendersAsCard(msg)) {`.

Hit-test (line 421): change `if (msg.role == .tool) {` to `if (rendersAsCard(msg)) {`.

- [ ] **Step 3: Card title branch** — in `renderToolCard` replace the `meta` line (915):

```zig
    const meta = if (msg.is_context_summary) ToolSectionMeta{
        .title = i18n.s().ai_summary_card_title,
        .name = "",
        .preview = ai_model_switch.cardPreview(msg.content),
    } else toolSectionMeta(msg.content);
```

> VERIFIED: `ToolSectionMeta` (`src/renderer/ai_chat_renderer.zig:~1384`) has `title/name/preview`, all `[]const u8` (`name`/`preview` default `""`). `ai_chat_renderer.zig` currently imports NEITHER `i18n` NOR `ai_model_switch`. ADD both at the top: `const i18n = @import("../i18n.zig");` and `const ai_model_switch = @import("../ai_model_switch.zig");` (AppWindow's `i18n` is private, so use a local import).

- [ ] **Step 4: Model-label hit-test** — add near `permissionChipHitTest` (~550):

```zig
fn modelLabelRect(session: *ai_chat.Session, x: f32, w: f32, titlebar_offset: f32) ?Rect {
    const chip_x = permissionChipX(x, w);
    const mode_x = @max(x + LINE_PAD_X, chip_x - MODE_SLOT_W - 8);
    const model_x = x + LINE_PAD_X;
    const model_limit = mode_x - model_x - 12;
    if (model_limit <= 24) return null; // label hidden on a too-narrow panel
    const text_w = @min(measureText(session.model()), model_limit);
    return .{ .x = model_x, .top_px = titlebar_offset + 8, .w = @max(1.0, text_w), .h = 32 };
}

pub fn modelLabelHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    titlebar_offset: f32,
    chat_x: f32,
    chat_w: f32,
) bool {
    _ = window_width;
    const x = @round(chat_x);
    const w = @round(@max(1.0, chat_w));
    const rect = modelLabelRect(session, x, w, titlebar_offset) orelse return false;
    return pointInRect(@floatCast(xpos), @floatCast(ypos), rect);
}
```

- [ ] **Step 5: Build to verify**

Run: `zig build`
Expected: compiles.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/ai_chat_renderer.zig
git commit -m "feat(ai-chat): render is_context_summary as a card + clickable model label hit-test"
```

---

## Task 7: Input — wire the model-label click

**Files:**
- Modify: `src/input.zig` (copilot path ~4300; tab path ~4379)

- [ ] **Step 1: Copilot path** — directly BEFORE the copilot `permissionChipHitTest` block (line 4300), add:

```zig
                        if (AppWindow.ai_chat_renderer.modelLabelHitTest(
                            chat,
                            xpos,
                            ypos,
                            @floatFromInt(fb.width),
                            @floatCast(titlebarHeight()),
                            chat_x,
                            chat_w,
                        )) {
                            overlays.openSwitchModelPicker(chat);
                            AppWindow.g_force_rebuild = true;
                            AppWindow.g_cells_valid = false;
                            return;
                        }
```

- [ ] **Step 2: Tab path** — directly BEFORE the tab `permissionChipHitTest` block (line 4379), add (note the inline `chat_x`/`chat_w` form used on this path):

```zig
                if (AppWindow.ai_chat_renderer.modelLabelHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    @as(f32, @floatFromInt(fb.width)) - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidthForWindow(fb.width),
                )) {
                    overlays.openSwitchModelPicker(chat);
                    AppWindow.g_force_rebuild = true;
                    AppWindow.g_cells_valid = false;
                    return;
                }
```

- [ ] **Step 3: Build to verify**

Run: `zig build`
Expected: compiles.

- [ ] **Step 4: Commit**

```bash
git add src/input.zig
git commit -m "feat(ai-chat): click the header model label to open the switch-model picker"
```

---

## Task 8: i18n strings

**Files:**
- Modify: `src/i18n.zig` (struct fields; English block; zh-CN block)

- [ ] **Step 1: Add fields** — in the `Strings` struct, near `sl_ai_profile_name`:

```zig
    ai_summary_card_title: []const u8,
    ai_model_no_profiles: []const u8,
    ai_model_unknown_profile: []const u8,
```

- [ ] **Step 2: English block** (near `.sl_ai_profile_name = "Profile name",`):

```zig
    .ai_summary_card_title = "Conversation summary",
    .ai_model_no_profiles = "No AI profiles configured. Add one in Settings → AI profiles.",
    .ai_model_unknown_profile = "No AI profile by that name; choose one from the list.",
```

- [ ] **Step 3: zh-CN block** (near `.sl_ai_profile_name = "配置名称",`):

```zig
    .ai_summary_card_title = "上文摘要",
    .ai_model_no_profiles = "尚未配置 AI 配置。请在 设置 → AI 配置 中新建。",
    .ai_model_unknown_profile = "没有同名的 AI 配置，请从列表中选择。",
```

- [ ] **Step 4: Build to verify**

Run: `zig build`
Expected: compiles (a missing language-block entry is a compile error in Zig's struct-literal init, which guarantees parity).

- [ ] **Step 5: Commit**

```bash
git add src/i18n.zig
git commit -m "feat(i18n): strings for model-switch summary card + errors (EN + zh-CN)"
```

---

## Task 9: App-layer trigger registration

**Files:**
- Modify: `src/AppWindow.zig` (trigger registration block 138-148)

- [ ] **Step 1: Register the trigger** — after the `setMarkdownExportTrigger` block (line 148):

```zig
    // `/model [name]` switches the active session's profile (and summarizes the
    // prior context with the new model). Empty pending name => open the picker.
    ai_chat.setModelSwitchTrigger(struct {
        fn cb() void {
            const chat = activeAiChat() orelse return;
            const name = chat.takePendingModelSwitchName();
            if (name.len > 0) {
                overlays.switchModelByName(chat, name);
            } else {
                overlays.openSwitchModelPicker(chat);
            }
        }
    }.cb);
```

> `takePendingModelSwitchName` returns a slice into the session buffer; it is consumed immediately here (passed straight into `switchModelByName` before any other session mutation), so no copy is needed. Confirm `overlays` and `activeAiChat` are in scope at this site (they are used elsewhere in the same file).

- [ ] **Step 2: Build to verify**

Run: `zig build`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(ai-chat): register /model trigger to switch profile or open picker"
```

---

## Task 10: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Fast suite**

Run: `zig build test-fast`
Expected: PASS (incl. `ai_model_switch` + composer tests).

- [ ] **Step 2: Full suite**

Run: `zig build test`
Expected: PASS (incl. `applySummaryResult` + toggle tests). Note any pre-existing unrelated failures.

- [ ] **Step 3: Windows cross-compile**

Run: `zig build -Dtarget=x86_64-windows-gnu`
Expected: compiles (this project gates on windows-gnu).

- [ ] **Step 4: Manual GUI checklist** (record results; do not claim success without running):
  - `/model` with no arg opens the profile picker; selecting a profile updates the header model label immediately.
  - `/model <exact profile name>` (case-insensitive) switches directly without the picker; an unknown name shows the "unknown profile" note and opens the picker.
  - Clicking the model label at the top-left of the panel header opens the picker (both Copilot sidebar and a chat tab).
  - After a switch in a conversation with prior turns, the status shows "Summarizing previous context…", typing still works immediately, and shortly the old turns collapse into one "上文摘要" card that toggles open/closed on click.
  - Switching in an empty conversation just swaps the model (status "Model switched"), no card.
  - Forcing a summary failure (e.g. switch to a profile with a bad key) keeps the full raw history and shows "Summary unavailable — kept full history".

- [ ] **Step 5: Final commit (if any checklist fixes were needed)**

```bash
git add -A
git commit -m "fix(ai-chat): model-switch GUI verification follow-ups"
```

---

## Self-review notes

- **Spec coverage:** triggers (`/model` Task 1+4, click Task 6+7); saved-profile-only switch (Task 5); new-model background summary (Task 4); async/non-blocking (status-based, splice-on-completion, Task 4); collapsible "上文摘要" card (Tasks 3+6); `/model <name>` direct + picker fallback (Tasks 4+5+9); failure keeps raw history (Task 4); session-only / persona untouched (Task 4 `applyProviderProfile`). All covered.
- **Simplification vs spec:** the spec's "defer the collapse if a request is in flight" is unnecessary — request workers snapshot their `RequestMessage[]` under the mutex at start, so an immediate under-mutex splice never races network IO. `applySummaryResult` therefore applies unconditionally (guarded by `closing` + the stale-`boundary` check).
- **Summary card representation:** `.user` role + `is_context_summary` flag → included verbatim by `buildRequestMessagesLocked` (role passthrough) and rendered as a collapsible card via `rendersAsCard`. Avoids the standalone-`.tool` Anthropic tool_result hazard.
- **Known v1 limitation:** `is_context_summary` is not persisted by `session_persist`, so after a `/resume` the card re-renders as a normal user message (content + marker preserved; context intact). Persisting the flag is a deliberate out-of-scope follow-up.
- **Verify-before-write reminders embedded as NOTEs:** `Session.init` vs `initWithVision` signature (Task 3); `ToolSectionMeta` fields + import aliases for `ai_model_switch`/`i18n` in renderer & overlays (Tasks 5/6); capture OLD model name before `copyModel` for the card marker (Task 4 Step 3e).
