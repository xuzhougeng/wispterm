# Phantty Docs Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `phantty_docs` agent tool that lists and reads Phantty's own user-facing docs on demand, with only a one-line pointer added to the system prompt.

**Architecture:** Five user-facing `docs/*.md` files are embedded into the binary via build.zig named embed imports (because `@embedFile` cannot escape `src/`). A new `src/phantty_docs.zig` module exposes `listTopics` / `readTopic` over those embeds. A new tool `phantty_docs` is declared in both protocol schema builders and dispatched in `ai_chat.zig`. The per-OS system prompt gains one hint line.

**Tech Stack:** Zig 0.15.2, the existing Phantty AI-chat tool framework (`ai_chat.zig`, `ai_chat_protocol.zig`, `platform/agent_prompt.zig`).

---

## Background facts (verified, do not re-derive)

- `@embedFile("../docs/x.md")` from a file in `src/` FAILS: `error: embed of file outside package path`. The working mechanism (verified with a standalone Zig 0.15.2 build) is `module.addAnonymousImport("name", .{ .root_source_file = b.path("docs/x.md") })` in build.zig, then `@embedFile("name")` in code.
- `build.zig` builds both the exe and the full test binary through `createAppModuleWithRoot` (exe root `src/main.zig`, full-test root `src/test_main.zig`). Adding the embed imports there covers both.
- Test split: `zig build test` runs ONLY the fast suite (`src/test_fast.zig`), which deliberately excludes `ai_chat.zig` and the app graph. The new module and all new tests run under **`zig build test-full`** (root `src/test_main.zig`). The fast suite never imports `phantty_docs.zig`, so it is unaffected.
- `ArrayListUnmanaged(u8)` in this codebase supports `.empty`, `.appendSlice(allocator, s)`, `.append(allocator, c)`, `.print(allocator, fmt, args)`, `.toOwnedSlice(allocator)`, `.deinit(allocator)` (see `terminalListTool` / `listSkillsForDisplay`).
- `jsonStringArg` returns `null` for a missing key AND for an empty-string value, so an empty `topic` naturally falls through to "list topics".
- The Windows prompt is currently **1543** chars; the existing test asserts `DEFAULT_SYSTEM_PROMPT.len < 1600`. Adding the hint (~118 chars) pushes it over, so the cap is bumped to `< 1800` in Task 4.

---

## File structure

- **Create** `src/phantty_docs.zig` — embedded-doc registry: `Topic`, `topics`, `listTopics`, `readTopic`. One clear responsibility: own the embedded docs and present them.
- **Modify** `build.zig` (`createAppModuleWithRoot`) — register the five docs as named embed imports.
- **Modify** `src/test_main.zig` — register `phantty_docs.zig` in the full-suite import list.
- **Modify** `src/ai_chat_protocol.zig` — declare `phantty_docs` in `appendToolSchemas` (Chat Completions) and `appendResponseToolSchemas` (Responses) + a schema test.
- **Modify** `src/ai_chat.zig` — import the module, add the dispatch branch, add `phanttyDocsTool` helper + tests.
- **Modify** `src/platform/agent_prompt.zig` — add the one-line hint to the shared section + a test.
- **Modify** `src/prompt.md` — mirror the hint line (doc copy of the prompt).
- **Modify** `docs/ai-agent.md` — document the new capability.

---

## Task 1: Embedded docs module

**Files:**
- Create: `src/phantty_docs.zig`
- Modify: `build.zig` (inside `fn createAppModuleWithRoot`, just after `app_mod.addOptions("build_options", app_options);`)
- Modify: `src/test_main.zig:588` (the `comptime { _ = @import(...) }` list)

- [ ] **Step 1: Wire the embed imports in build.zig**

In `build.zig`, find this line inside `createAppModuleWithRoot`:

```zig
    app_mod.addOptions("build_options", app_options);
```

Immediately after it, add:

```zig
    // Embed user-facing docs so the phantty_docs agent tool can read them at
    // runtime. @embedFile cannot escape src/, so docs/ files are wired in here
    // as named embed imports consumed by src/phantty_docs.zig.
    app_mod.addAnonymousImport("phantty_doc_faq", .{ .root_source_file = b.path("docs/faq.md") });
    app_mod.addAnonymousImport("phantty_doc_configuration", .{ .root_source_file = b.path("docs/configuration.md") });
    app_mod.addAnonymousImport("phantty_doc_ai_agent", .{ .root_source_file = b.path("docs/ai-agent.md") });
    app_mod.addAnonymousImport("phantty_doc_file_explorer", .{ .root_source_file = b.path("docs/file-explorer.md") });
    app_mod.addAnonymousImport("phantty_doc_media", .{ .root_source_file = b.path("docs/media.md") });
```

- [ ] **Step 2: Create the module with its tests**

Create `src/phantty_docs.zig`:

```zig
//! Built-in Phantty documentation, embedded at build time.
//!
//! The agent reads these on demand through the `phantty_docs` tool so the
//! system prompt only needs a one-line pointer instead of the full text.
//! Doc files live under `docs/` and are wired in as named embed imports by
//! build.zig (`createAppModuleWithRoot`). The import names below MUST match
//! the names registered there.

const std = @import("std");

pub const Topic = struct {
    name: []const u8,
    summary: []const u8,
    content: []const u8,
};

pub const topics = [_]Topic{
    .{
        .name = "faq",
        .summary = "Frequently asked questions and troubleshooting.",
        .content = @embedFile("phantty_doc_faq"),
    },
    .{
        .name = "configuration",
        .summary = "Config file location, options, keybindings, and clipboard behavior.",
        .content = @embedFile("phantty_doc_configuration"),
    },
    .{
        .name = "ai-agent",
        .summary = "AI chat and agent usage: profiles, providers, skills, and exports.",
        .content = @embedFile("phantty_doc_ai_agent"),
    },
    .{
        .name = "file-explorer",
        .summary = "Using the built-in file explorer and preview panel.",
        .content = @embedFile("phantty_doc_file_explorer"),
    },
    .{
        .name = "media",
        .summary = "Showing images, background images, and inline remote images.",
        .content = @embedFile("phantty_doc_media"),
    },
};

/// Returns the embedded markdown for an exact topic name, or null if unknown.
pub fn readTopic(name: []const u8) ?[]const u8 {
    for (topics) |topic| {
        if (std.mem.eql(u8, topic.name, name)) return topic.content;
    }
    return null;
}

/// Builds a model-readable list of topics: one `name — summary` line each,
/// plus a trailing hint. Caller owns the returned slice.
pub fn listTopics(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Phantty documentation topics:\n");
    for (topics) |topic| {
        try out.print(allocator, "- {s} — {s}\n", .{ topic.name, topic.summary });
    }
    try out.appendSlice(allocator, "\nCall phantty_docs again with one topic name to read its full text.");
    return out.toOwnedSlice(allocator);
}

test "phantty_docs: every topic has non-empty name, summary, and content" {
    for (topics) |topic| {
        try std.testing.expect(topic.name.len > 0);
        try std.testing.expect(topic.summary.len > 0);
        try std.testing.expect(topic.content.len > 0);
    }
}

test "phantty_docs: readTopic returns content for known topics and null otherwise" {
    try std.testing.expect(readTopic("faq") != null);
    try std.testing.expect(readTopic("configuration") != null);
    try std.testing.expect(readTopic("ai-agent") != null);
    try std.testing.expect(readTopic("file-explorer") != null);
    try std.testing.expect(readTopic("media") != null);
    try std.testing.expect(readTopic("nope") == null);
}

test "phantty_docs: listTopics lists every topic name and the read hint" {
    const text = try listTopics(std.testing.allocator);
    defer std.testing.allocator.free(text);
    for (topics) |topic| {
        try std.testing.expect(std.mem.indexOf(u8, text, topic.name) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "phantty_docs") != null);
}
```

- [ ] **Step 3: Register the module in the full test suite**

In `src/test_main.zig`, find this line (in the `comptime { ... }` import block, near line 588):

```zig
    _ = @import("memory_debug.zig");
```

Add immediately after it:

```zig
    _ = @import("phantty_docs.zig");
```

- [ ] **Step 4: Run the tests — expect PASS**

Run: `zig build test-full`
Expected: builds and passes. The three `phantty_docs:` tests are included. (Standalone `zig test src/phantty_docs.zig` will NOT work — the embed imports are only defined by build.zig.)

- [ ] **Step 5: Commit**

```bash
git add src/phantty_docs.zig build.zig src/test_main.zig
git commit -m "$(cat <<'EOF'
Add embedded phantty_docs module

Embeds the five user-facing docs via build.zig named embed imports and
exposes listTopics/readTopic for the upcoming phantty_docs agent tool.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Declare the `phantty_docs` tool schema

**Files:**
- Modify: `src/ai_chat_protocol.zig` (`appendToolSchemas` ~line 432, `appendResponseToolSchemas` ~line 487)
- Test: `src/ai_chat_protocol.zig` (new test alongside the existing `buildRequestJson` tests)

- [ ] **Step 1: Write the failing test**

Add this test in `src/ai_chat_protocol.zig` after the test `"buildRequestJson chat_completions emits tool_calls when present"` (~line 888):

```zig
test "buildRequestJson includes phantty_docs tool for both protocols" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};

    const chat = RequestParams{ .model = "m", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const chat_json = try buildRequestJson(a, chat, &msgs, true);
    defer a.free(chat_json);
    try std.testing.expect(std.mem.indexOf(u8, chat_json, "\"phantty_docs\"") != null);

    const resp = RequestParams{ .model = "m", .system_prompt = "", .protocol = .responses, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const resp_json = try buildRequestJson(a, resp, &msgs, true);
    defer a.free(resp_json);
    try std.testing.expect(std.mem.indexOf(u8, resp_json, "\"phantty_docs\"") != null);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-full`
Expected: FAIL — the new test's `indexOf` assertions fail because `phantty_docs` is not yet in the schema.

- [ ] **Step 3: Add the tool to the Chat Completions schema**

In `appendToolSchemas`, find the `skill_info` line (~432):

```zig
    try out.appendSlice(allocator, toolSchema("skill_info", "Load a Phantty skill by stable name. Use when the user explicitly names a skill or asks for specialized skill instructions.", "{\"skill_name\":{\"type\":\"string\",\"description\":\"Skill name or skill directory name.\"}}"));
    try out.append(allocator, ']');
```

Insert the `phantty_docs` tool between those two lines:

```zig
    try out.appendSlice(allocator, toolSchema("skill_info", "Load a Phantty skill by stable name. Use when the user explicitly names a skill or asks for specialized skill instructions.", "{\"skill_name\":{\"type\":\"string\",\"description\":\"Skill name or skill directory name.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("phantty_docs", "Read Phantty's own documentation (features, configuration, shortcuts, AI agent, file explorer, media). Call with no topic to list available topics, then call again with a topic to read its full text.", "{\"topic\":{\"type\":\"string\",\"description\":\"Topic name from the list. Omit to list available topics.\"}}"));
    try out.append(allocator, ']');
```

- [ ] **Step 4: Add the tool to the Responses schema**

In `appendResponseToolSchemas`, find the `skill_info` line (~487):

```zig
    try out.appendSlice(allocator, responseToolSchema("skill_info", "Load a Phantty skill by stable name. Use when the user explicitly names a skill or asks for specialized skill instructions.", "{\"skill_name\":{\"type\":\"string\",\"description\":\"Skill name or skill directory name.\"}}"));
    try out.append(allocator, ']');
```

Insert the `phantty_docs` tool between those two lines:

```zig
    try out.appendSlice(allocator, responseToolSchema("skill_info", "Load a Phantty skill by stable name. Use when the user explicitly names a skill or asks for specialized skill instructions.", "{\"skill_name\":{\"type\":\"string\",\"description\":\"Skill name or skill directory name.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, responseToolSchema("phantty_docs", "Read Phantty's own documentation (features, configuration, shortcuts, AI agent, file explorer, media). Call with no topic to list available topics, then call again with a topic to read its full text.", "{\"topic\":{\"type\":\"string\",\"description\":\"Topic name from the list. Omit to list available topics.\"}}"));
    try out.append(allocator, ']');
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `zig build test-full`
Expected: PASS — including `"buildRequestJson includes phantty_docs tool for both protocols"`.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_protocol.zig
git commit -m "$(cat <<'EOF'
Declare phantty_docs tool in both protocol schemas

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Dispatch the `phantty_docs` tool

**Files:**
- Modify: `src/ai_chat.zig` (imports near top; `executeToolCall` ~line 3117; new helper after `skillInfoToolFromRoots` ~line 3175)
- Test: `src/ai_chat.zig` (new tests with the other ai_chat tests)

- [ ] **Step 1: Write the failing tests**

Add these tests in `src/ai_chat.zig` near the other tool tests (e.g. just before the existing `test "ai chat skill_info loads from explicit root paths"` at ~line 4360):

```zig
test "phantty_docs tool lists topics when no topic is given" {
    const a = std.testing.allocator;
    const text = try phanttyDocsTool(a, null);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "faq") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "configuration") != null);
}

test "phantty_docs tool returns content for a known topic" {
    const a = std.testing.allocator;
    const text = try phanttyDocsTool(a, "faq");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "FAQ") != null);
}

test "phantty_docs tool reports unknown topic with the topic list" {
    const a = std.testing.allocator;
    const text = try phanttyDocsTool(a, "does-not-exist");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Unknown topic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "faq") != null);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test-full`
Expected: FAIL — compile error `use of undeclared identifier 'phanttyDocsTool'`.

- [ ] **Step 3: Import the module**

In `src/ai_chat.zig`, find the existing import of the skill registry near the top:

```zig
const skill_registry = @import("skill_registry.zig");
```

Add immediately after it:

```zig
const phantty_docs = @import("phantty_docs.zig");
```

(If `skill_registry` is imported with a different surrounding style, place `phantty_docs` alongside the other top-of-file `@import` declarations.)

- [ ] **Step 4: Add the helper function**

In `src/ai_chat.zig`, add this function right after `skillInfoToolFromRoots` (which ends at ~line 3175, just before `fn toolSurfaceKind`):

```zig
fn phanttyDocsTool(allocator: std.mem.Allocator, topic: ?[]const u8) ![]u8 {
    if (topic) |name| {
        if (phantty_docs.readTopic(name)) |content| {
            return allocator.dupe(u8, content);
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.print(allocator, "Unknown topic \"{s}\". Available topics:", .{name});
        for (phantty_docs.topics) |t| {
            try out.print(allocator, " {s}", .{t.name});
        }
        return out.toOwnedSlice(allocator);
    }
    return phantty_docs.listTopics(allocator);
}
```

- [ ] **Step 5: Add the dispatch branch**

In `executeToolCall`, find the `skill_info` branch followed by the unknown-tool fallthrough (~line 3117-3123):

```zig
    if (std.mem.eql(u8, call.name, "skill_info")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const skill_name = jsonStringArg(args.value, "skill_name") orelse return request.allocator.dupe(u8, "Missing skill_name");
        return skillInfoTool(request.allocator, skill_name);
    }
    return std.fmt.allocPrint(request.allocator, "Unknown tool: {s}", .{call.name});
```

Insert the `phantty_docs` branch between the `skill_info` block and the `return std.fmt.allocPrint(...)` line:

```zig
    if (std.mem.eql(u8, call.name, "skill_info")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const skill_name = jsonStringArg(args.value, "skill_name") orelse return request.allocator.dupe(u8, "Missing skill_name");
        return skillInfoTool(request.allocator, skill_name);
    }
    if (std.mem.eql(u8, call.name, "phantty_docs")) {
        const args = parseArgs(request.allocator, call.arguments);
        defer if (args) |parsed| parsed.deinit();
        const topic = if (args) |parsed| jsonStringArg(parsed.value, "topic") else null;
        return phanttyDocsTool(request.allocator, topic);
    }
    return std.fmt.allocPrint(request.allocator, "Unknown tool: {s}", .{call.name});
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test-full`
Expected: PASS — including the three `phantty_docs tool ...` tests.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat.zig
git commit -m "$(cat <<'EOF'
Dispatch phantty_docs tool to embedded docs

No-topic calls list topics; a topic returns its embedded markdown; an
unknown topic returns an error naming the valid topics.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: System-prompt hint

**Files:**
- Modify: `src/platform/agent_prompt.zig` (`common_tools_after_wsl`)
- Test: `src/platform/agent_prompt.zig` (new test) and `src/ai_chat.zig` (bump length cap, add hint assertion)
- Modify: `src/prompt.md` (mirror the line)

- [ ] **Step 1: Write the failing prompt test**

In `src/platform/agent_prompt.zig`, add this test after the existing `"platform agent prompt has macOS-specific shell wording"` test (~line 104):

```zig
test "platform agent prompt points at the phantty_docs tool on every OS" {
    for ([_]std.Target.Os.Tag{ .windows, .linux, .macos }) |os| {
        const p = defaultSystemPromptForOs(os);
        try std.testing.expect(std.mem.indexOf(u8, p, "phantty_docs") != null);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full`
Expected: FAIL — the prompt does not yet mention `phantty_docs`. (The existing `DEFAULT_SYSTEM_PROMPT.len < 1600` test still passes at this point.)

- [ ] **Step 3: Add the hint line to the shared prompt section**

In `src/platform/agent_prompt.zig`, find this in `common_tools_after_wsl`:

```zig
    \\- Open a new local terminal with `tab_new` only when no suitable terminal exists.
    \\
    \\Python:
```

Insert the hint line after the `tab_new` line:

```zig
    \\- Open a new local terminal with `tab_new` only when no suitable terminal exists.
    \\- For questions about Phantty itself (features, config, shortcuts), call `phantty_docs` to list and read the built-in docs.
    \\
    \\Python:
```

- [ ] **Step 4: Bump the prompt length cap**

In `src/ai_chat.zig`, find this assertion in the test `"ai chat default system prompt comes from platform agent prompt"` (~line 4705):

```zig
    try std.testing.expect(DEFAULT_SYSTEM_PROMPT.len < 1600);
```

Replace it with a bumped cap plus an assertion that the hint is present:

```zig
    try std.testing.expect(DEFAULT_SYSTEM_PROMPT.len < 1800);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "phantty_docs") != null);
```

- [ ] **Step 5: Run to verify it passes**

Run: `zig build test-full`
Expected: PASS — the new prompt test and the bumped/extended default-prompt test both pass.

- [ ] **Step 6: Mirror the line into prompt.md**

In `src/prompt.md`, find:

```text
- Open a new local terminal with `tab_new` only when no suitable terminal exists.
```

Add immediately after it:

```text
- For questions about Phantty itself (features, config, shortcuts), call `phantty_docs` to list and read the built-in docs.
```

- [ ] **Step 7: Commit**

```bash
git add src/platform/agent_prompt.zig src/ai_chat.zig src/prompt.md
git commit -m "$(cat <<'EOF'
Point the agent prompt at the phantty_docs tool

Adds a one-line hint to the shared prompt section and bumps the prompt
length cap to accommodate it.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Document the capability

**Files:**
- Modify: `docs/ai-agent.md`

- [ ] **Step 1: Add a section to docs/ai-agent.md**

In `docs/ai-agent.md`, after the closing paragraph of the `## Agent Skills` section (after the `right-click-action = copy-or-paste ...` paragraph at the end of the file), append:

```markdown

## Asking About Phantty Itself

The agent can read Phantty's own user documentation on demand through the
`phantty_docs` tool. Ask a natural question such as "how do I change the font?"
or "what clipboard options exist?" and the agent first lists the available
topics (`faq`, `configuration`, `ai-agent`, `file-explorer`, `media`), then
reads the relevant one and answers from it.

The docs are embedded in the Phantty binary, so this works offline and without
the source tree. The system prompt only carries a one-line pointer to the tool;
the documentation text is loaded only when the agent calls `phantty_docs`.
```

- [ ] **Step 2: Verify the docs still embed cleanly**

Run: `zig build test-full`
Expected: PASS. (Editing `docs/ai-agent.md` changes the embedded `ai-agent` topic content; the `phantty_docs:` content tests assert only non-emptiness, so they still pass.)

- [ ] **Step 3: Commit**

```bash
git add docs/ai-agent.md
git commit -m "$(cat <<'EOF'
Document the phantty_docs agent capability

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] Run the full suite once more: `zig build test-full` — expect PASS.
- [ ] Build the app to confirm the exe compiles with the new embeds: `zig build` — expect success.

---

## Self-review notes (author)

- **Spec coverage:** module (`phantty_docs.zig`) → Task 1; embed-in-binary delivery → Task 1 (build.zig); tool in both protocols → Task 2; dispatch list/read/unknown → Task 3; one-line prompt hint + prompt.md mirror + length-cap bump → Task 4; tests for module/schema/dispatch/prompt → Tasks 1-4; docs note → Task 5. All spec sections covered.
- **Type consistency:** `phanttyDocsTool(allocator, ?[]const u8)`, `phantty_docs.readTopic([]const u8) ?[]const u8`, `phantty_docs.listTopics(allocator) ![]u8`, and `phantty_docs.topics` are referenced identically across Tasks 1 and 3. Embed import names (`phantty_doc_*`) match between build.zig (Task 1 Step 1) and `phantty_docs.zig` (Task 1 Step 2).
- **No placeholders:** every code/edit step shows complete content and an exact anchor.
