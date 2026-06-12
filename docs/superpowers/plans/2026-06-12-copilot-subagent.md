# Copilot Subagent Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Worktree hazard:** ALL work happens in `/home/xzg/project/phantty/.claude/worktrees/copilot-repeat-problem` (branch `worktree-copilot-repeat-problem`). Dispatched subagents MUST `cd` there first and verify with `git branch --show-current` — past sessions have polluted the main repo.

**Goal:** A `subagent` agent tool that runs a nested research agent loop (own transcript, read-only toolset, optional `ai-subagent-profile` model override) and returns only a final report to the main conversation, keeping the main context small.

**Architecture:** Intercept `subagent` in `ai_chat_request.zig`'s `executeToolCall`; run `runSubagentTaskWithModel` (same loop shape as `runAgentRequest`, model call injectable for tests). Toolset gating lives in `ai_chat_protocol.zig`'s single-source `forEachToolSpec` via a `Toolset` enum + `subagentToolAllowed` allow-list that drives BOTH schema emission and dispatch. Profile override resolves on the UI thread (`renderer/overlays.zig` owns `g_ai_profiles`) through a resolver callback registered into `ai_chat.zig`, and travels into the worker as owned strings on `ChatRequest`.

**Tech Stack:** Zig (this repo), no new dependencies. Spec: `docs/superpowers/specs/2026-06-12-copilot-subagent-design.md`.

**Test commands:** fast suite `zig build test` (covers `ai_chat_protocol.zig`); full suite `zig build test-full` (covers `ai_chat.zig`, `ai_chat_request.zig`, `ai_chat_tools.zig`, `config.zig`). App compile check: `zig build`.

---

### Task 1: Toolset enum, allow-list, filtered schema emission, `subagent` schema

**Files:**
- Modify: `src/ai_chat_protocol.zig` (RequestParams ~line 218, buildRequestJson tool emission ~line 395, `appendAnthropicTools` ~line 556, `forEachToolSpec` ~line 652, `appendToolSchemas`/`appendResponseToolSchemas` ~lines 745-759, direct-call tests ~lines 1676-1712)

- [ ] **Step 1: Write the failing tests** (append near the existing schema tests at the bottom of `src/ai_chat_protocol.zig`)

```zig
test "subagentToolAllowed accepts exactly the research tools" {
    const allowed = [_][]const u8{
        "terminal_list", "terminal_snapshot", "read_file",
        "websearch",     "webread",          "pubmed",
        "wispterm_docs",
    };
    for (allowed) |name| try std.testing.expect(subagentToolAllowed(name));
    const denied = [_][]const u8{
        "subagent",   "memory_save", "ssh_session_exec", "write_file",
        "edit_file",  "tab_new",     "tab_close",        "terminal_select",
        "terminal_repl_exec",
    };
    for (denied) |name| try std.testing.expect(!subagentToolAllowed(name));
}

test "subagent toolset restricts tool schemas to research tools" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = true, .toolset = .subagent });
    const json = out.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"websearch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"webread\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pubmed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"wispterm_docs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"subagent\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"memory_save\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_session_exec\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"write_file\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tab_new\"") == null);
}

test "full toolset includes the subagent tool" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out, .{ .include_memory = false });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"subagent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"task\"") != null);
}

test "subagent toolset gating applies to all three protocol emitters" {
    const a = std.testing.allocator;
    var responses_out: std.ArrayListUnmanaged(u8) = .empty;
    defer responses_out.deinit(a);
    try appendResponseToolSchemas(a, &responses_out, .{ .include_memory = true, .toolset = .subagent });
    try std.testing.expect(std.mem.indexOf(u8, responses_out.items, "\"websearch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses_out.items, "\"name\":\"subagent\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, responses_out.items, "\"write_file\"") == null);

    var anthropic_out: std.ArrayListUnmanaged(u8) = .empty;
    defer anthropic_out.deinit(a);
    try appendAnthropicTools(a, &anthropic_out, .{ .include_memory = true, .toolset = .subagent });
    try std.testing.expect(std.mem.indexOf(u8, anthropic_out.items, "\"websearch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_out.items, "\"name\":\"subagent\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_out.items, "\"write_file\"") == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test`
Expected: compile error — `subagentToolAllowed` not defined, `appendToolSchemas` takes a bool not a struct.

- [ ] **Step 3: Implement**

3a. Add near the top of the tool-spec section (above `forEachToolSpec`, ~line 645):

```zig
/// Tool visibility for one request. `.subagent` = the nested research
/// subagent's restricted read-only set; gates BOTH schema emission
/// (forEachToolSpec) and dispatch (runSubagentTaskWithModel).
pub const Toolset = enum { full, subagent };

pub const ToolSpecOpts = struct {
    include_memory: bool,
    toolset: Toolset = .full,
};

/// Single source of truth for what a subagent may call. Every listed tool is
/// read-only and approval-free.
pub const subagent_allowed_tools = [_][]const u8{
    "terminal_list", "terminal_snapshot", "read_file",
    "websearch",     "webread",          "pubmed",
    "wispterm_docs",
};

pub fn subagentToolAllowed(name: []const u8) bool {
    for (subagent_allowed_tools) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return true;
    }
    return false;
}
```

3b. Rework `forEachToolSpec` (~line 652): change the signature's anonymous opts struct to `ToolSpecOpts`, and route every emission through a filtering wrapper. The nested struct may reference the comptime params `Ctx` and `emit`:

```zig
fn forEachToolSpec(
    comptime Ctx: type,
    ctx: Ctx,
    opts: ToolSpecOpts,
    comptime emit: fn (Ctx, []const u8, []const u8, []const u8) anyerror!void,
) !void {
    const Filtered = struct {
        fn emitTool(c: Ctx, o: ToolSpecOpts, name: []const u8, description: []const u8, properties: []const u8) anyerror!void {
            if (o.toolset == .subagent and !subagentToolAllowed(name)) return;
            try emit(c, name, description, properties);
        }
    };
    try Filtered.emitTool(ctx, opts, "terminal_list", "List WispTerm terminal surfaces visible to the agent, including the current agent-selected write context. Before any terminal write, use terminal_select to choose the intended surface_id; use focused=true only as a default hint.", "{}");
    ...
```

Mechanically replace EVERY existing `try emit(ctx, ` in the function body with `try Filtered.emitTool(ctx, opts, ` (descriptions/properties text unchanged; the `if (platform_pty_command.wslSessionToolsEnabled())` and `if (opts.include_memory)` guards stay as they are). `subagentToolAllowed` filters the memory tools and `subagent` itself in subagent mode, so no extra conditions are needed.

3c. Add the `subagent` tool emission after the `pubmed` line and before `weixin_send_attachment`:

```zig
    try Filtered.emitTool(ctx, opts, "subagent", "Delegate a self-contained research or reading task to a background subagent with its own separate context window. The subagent can use websearch, webread, pubmed, read_file, terminal_list, terminal_snapshot, and wispterm_docs, then returns one final report; its intermediate tool output never enters this conversation. Use it whenever a task would pull large content here (full web pages, PDFs, multi-query searches). It cannot see this conversation or ask questions: put every needed detail (URLs, paths, constraints) and the expected report format into task.", "{\"task\":{\"type\":\"string\",\"description\":\"Complete self-contained task description: what to investigate or read, all needed context (URLs, paths, constraints), and what the final report must contain.\"}}");
```

3d. Update the three emitter entry points to take `ToolSpecOpts`:

```zig
fn appendToolSchemas(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), opts: ToolSpecOpts) !void {
    try out.appendSlice(allocator, ",\"tools\":[");
    var ctx = ToolSchemaEmitter{ .allocator = allocator, .out = out };
    try forEachToolSpec(*ToolSchemaEmitter, &ctx, opts, ToolSchemaEmitter.emit);
    try out.append(allocator, ']');
    try out.appendSlice(allocator, ",\"tool_choice\":\"auto\"");
}
```

Same change for `appendResponseToolSchemas` and `appendAnthropicTools` (the latter drops its `include_memory: bool` param for `opts: ToolSpecOpts`).

3e. Add `toolset: Toolset = .full` to `RequestParams` (~line 226, after `memory_enabled`).

3f. Update every call site. Find them: `grep -n "appendToolSchemas(\|appendResponseToolSchemas(\|appendAnthropicTools(" src/ai_chat_protocol.zig`. Production sites pass `.{ .include_memory = params.memory_enabled, .toolset = params.toolset }`; the existing direct-call tests (`appendToolSchemas(a, &out, false)` at ~1676/1688/1701 and any others the grep finds) become `appendToolSchemas(a, &out, .{ .include_memory = false })`.

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS (all three new tests + existing schema tests).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_protocol.zig
git commit -m "feat(agent): subagent tool schema + Toolset gating in forEachToolSpec"
```

---

### Task 2: Researcher system prompt + main-prompt delegation guidance

**Files:**
- Modify: `src/platform/agent_prompt.zig` (add `subagentSystemPrompt`; extend `common_tools_after_wsl`)
- Modify: `src/ai_chat.zig` (prompt guard test ~line 5176)

- [ ] **Step 1: Write the failing tests** (in `src/ai_chat.zig`, next to the existing prompt test at ~5176; that test asserts `DEFAULT_SYSTEM_PROMPT.len < 3200` and mentions `wispterm_docs`)

```zig
test "default system prompt mentions subagent delegation" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "`subagent`") != null);
}

test "subagent system prompt is self-contained researcher guidance" {
    const prompt = platform_agent_prompt.subagentSystemPrompt;
    try std.testing.expect(std.mem.indexOf(u8, prompt, "research subagent") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "final report") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "websearch") != null);
    try std.testing.expect(prompt.len < 1200);
}
```

(`platform_agent_prompt` is already imported in `ai_chat.zig` — verify with `grep -n "platform_agent_prompt" src/ai_chat.zig`.)

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-full`
Expected: compile error — `subagentSystemPrompt` not defined.

- [ ] **Step 3: Implement** (in `src/platform/agent_prompt.zig`)

3a. Add the researcher prompt as a new pub const next to `defaultSystemPrompt`/`copilotSystemPrompt`:

```zig
/// System prompt for the nested research subagent (the `subagent` tool).
/// OS-independent: the subagent has no exec/write tools.
pub const subagentSystemPrompt =
    \\You are a WispTerm research subagent. You receive ONE self-contained task
    \\and must complete it using only your read-only tools: websearch, webread,
    \\pubmed, read_file, terminal_list, terminal_snapshot, wispterm_docs.
    \\
    \\Rules:
    \\- You cannot ask the user questions. If the task is ambiguous, choose the
    \\  most reasonable interpretation and state the assumption in your report.
    \\- Gather what you need with tools, then STOP calling tools and write one
    \\  final report.
    \\- The report must be self-contained: key findings, relevant short quotes,
    \\  and the source URLs or file paths for every claim.
    \\- Be concise; no padding. Write the report in the language of the task.
;
```

3b. Add one delegation bullet to `common_tools_after_wsl` (right after the `pubmed` bullet):

```zig
    \\- Delegate heavy research/reading (full web pages, PDFs, multi-query searches) to `subagent` with one complete task description; only its final report enters this conversation.
```

3c. If the `DEFAULT_SYSTEM_PROMPT.len < 3200` assertion at `src/ai_chat.zig:5176` now fails, bump it to `< 3400` (precedent: this guard has been bumped for pubmed and REPL guidance before; keep the cushion minimal).

- [ ] **Step 4: Run tests**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/platform/agent_prompt.zig src/ai_chat.zig
git commit -m "feat(agent): subagent researcher prompt + delegation guidance in main prompt"
```

---

### Task 3: ChatRequest plumbing + profile-override seam in ai_chat.zig

**Files:**
- Modify: `src/ai_chat.zig` (ChatRequest struct ~line 150, globals/seams section ~line 316-450, `buildRequestLocked` ~line 3250-3359)
- Modify: `src/ai_chat_tools.zig` (make three helpers pub)

- [ ] **Step 1: Write the failing tests** (in `src/ai_chat.zig`, near the other ChatRequest tests ~line 4600)

```zig
fn testSubagentResolver(allocator: std.mem.Allocator) ?SubagentProfileOverride {
    const base_url = allocator.dupe(u8, "https://sub.example") catch return null;
    const api_key = allocator.dupe(u8, "sub-key") catch {
        allocator.free(base_url);
        return null;
    };
    const model = allocator.dupe(u8, "sub-model") catch {
        allocator.free(base_url);
        allocator.free(api_key);
        return null;
    };
    const reasoning_effort = allocator.dupe(u8, "low") catch {
        allocator.free(base_url);
        allocator.free(api_key);
        allocator.free(model);
        return null;
    };
    return .{
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = reasoning_effort,
        .max_tokens = 4096,
    };
}

test "resolveSubagentProfileForRequest gates on resolver and agent flag" {
    const a = std.testing.allocator;
    setSubagentProfileResolver(null);
    try std.testing.expect(resolveSubagentProfileForRequest(a, true) == null);

    setSubagentProfileResolver(testSubagentResolver);
    defer setSubagentProfileResolver(null);
    try std.testing.expect(resolveSubagentProfileForRequest(a, false) == null);

    const override = resolveSubagentProfileForRequest(a, true) orelse return error.TestUnexpectedResult;
    defer override.deinit(a);
    try std.testing.expectEqualStrings("https://sub.example", override.base_url);
    try std.testing.expectEqualStrings("sub-model", override.model);
}

test "ChatRequest deinit frees the subagent profile override" {
    const a = std.testing.allocator;
    var session = try Session.init(a, "test", "https://api.example", "key", "model", "prompt", "enabled", "medium", "false", "true");
    defer session.deinit();

    const request = try a.create(ChatRequest);
    request.* = .{
        .allocator = a,
        .session = session,
        .base_url = try a.dupe(u8, "https://api.example"),
        .api_key = try a.dupe(u8, "key"),
        .model = try a.dupe(u8, "model"),
        .system_prompt = try a.dupe(u8, "prompt"),
        .messages = &.{},
        .thinking_enabled = false,
        .reasoning_effort = try a.dupe(u8, "medium"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
        .subagent_profile = testSubagentResolver(a),
    };
    request.deinit();
    // std.testing.allocator fails the test on leak — nothing else to assert.
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-full`
Expected: compile error — `SubagentProfileOverride`, `setSubagentProfileResolver`, `resolveSubagentProfileForRequest`, `.subagent_profile` not defined.

- [ ] **Step 3: Implement**

3a. In `src/ai_chat.zig`, ensure the protocol alias is pub (check `grep -n "ApiProtocol" src/ai_chat.zig | head -3`; if the existing alias is `const ApiProtocol = ...`, make it `pub const ApiProtocol = ai_chat_protocol.ApiProtocol;`).

3b. Add the override type + resolver seam next to the other trigger seams (~line 340, near `setSkillUpdateTrigger`):

```zig
/// Resolved credentials for the `ai-subagent-profile` config key. Owned
/// strings; freed by ChatRequest.deinit.
pub const SubagentProfileOverride = struct {
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    protocol: ApiProtocol,
    thinking_enabled: bool,
    reasoning_effort: []u8,
    max_tokens: u32,

    pub fn deinit(self: SubagentProfileOverride, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.reasoning_effort);
    }
};

pub const SubagentProfileResolver = *const fn (allocator: std.mem.Allocator) ?SubagentProfileOverride;
var g_subagent_profile_resolver: ?SubagentProfileResolver = null;

/// Wire the UI-thread resolver that maps the `ai-subagent-profile` config key
/// to concrete profile credentials. Registered at startup by the app layer
/// (mirrors setSkillUpdateTrigger). Resolution happens in buildRequestLocked
/// on the UI thread; the worker only reads the owned copy on its ChatRequest.
pub fn setSubagentProfileResolver(cb: ?SubagentProfileResolver) void {
    g_subagent_profile_resolver = cb;
}

fn resolveSubagentProfileForRequest(allocator: std.mem.Allocator, agent_enabled: bool) ?SubagentProfileOverride {
    if (!agent_enabled) return null;
    const resolve = g_subagent_profile_resolver orelse return null;
    return resolve(allocator);
}
```

3c. Extend `ChatRequest` (~line 150). Add after `write_context_surface_id_len`:

```zig
    toolset: ai_chat_protocol.Toolset = .full,
    subagent_profile: ?SubagentProfileOverride = null,
    /// Usage burned by nested subagent runs; merged into the agent loop's
    /// total when the final answer returns.
    subagent_usage: ai_chat_protocol.ApiUsage = .{},
    subagent_usage_present: bool = false,
```

In `ChatRequest.deinit`, before `self.allocator.destroy(self)`:

```zig
        if (self.subagent_profile) |profile| profile.deinit(self.allocator);
```

In `toParams()`, add:

```zig
            .toolset = self.toolset,
```

3d. In `buildRequestLocked` (~line 3320, after the `reasoning_effort` dupe), resolve and hand over, mirroring the `weixin_ctx` ownership pattern:

```zig
        var subagent_profile = resolveSubagentProfileForRequest(self.allocator, agent_enabled);
        errdefer if (subagent_profile) |profile| profile.deinit(self.allocator);
```

Add `.subagent_profile = subagent_profile,` to the `req.* = .{ ... }` literal, and after the literal (next to `weixin_ctx = null;`) add `subagent_profile = null;`.

3e. In `src/ai_chat_tools.zig`, make three existing helpers pub (the request layer needs them in Task 4): `parseArgs` (~line 272), `jsonStringArg` (~line 278), `truncateOwned` (~line 2475) — prepend `pub` to each `fn`.

- [ ] **Step 4: Run tests**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig src/ai_chat_tools.zig
git commit -m "feat(agent): ChatRequest subagent plumbing + profile-override resolver seam"
```

---

### Task 4: Nested loop `runSubagentTaskWithModel` + interception + usage merge

**Files:**
- Modify: `src/ai_chat_request.zig` (`runAgentRequest` ~line 235, `executeToolCall` ~line 632, new subagent section + tests)

- [ ] **Step 1: Write the failing tests** (append to `src/ai_chat_request.zig`; `Session` is already aliased at the top of the file)

```zig
// --- Subagent loop tests -----------------------------------------------------

const SubagentStubModel = struct {
    step: usize = 0,
    saw_base_url: [128]u8 = undefined,
    saw_base_url_len: usize = 0,
    saw_toolset: ai_chat_protocol.Toolset = .full,
    saw_memory_enabled: bool = true,
    saw_subagent_prompt: bool = false,

    fn call(ctx: ?*anyopaque, request: *const ChatRequest, messages: []const RequestMessage) anyerror!ApiResult {
        _ = messages;
        const self: *SubagentStubModel = @ptrCast(@alignCast(ctx.?));
        const a = request.allocator;
        const n = @min(request.base_url.len, self.saw_base_url.len);
        @memcpy(self.saw_base_url[0..n], request.base_url[0..n]);
        self.saw_base_url_len = n;
        self.saw_toolset = request.toolset;
        self.saw_memory_enabled = request.memory_enabled;
        self.saw_subagent_prompt = std.mem.eql(u8, request.system_prompt, @import("platform/agent_prompt.zig").subagentSystemPrompt);
        defer self.step += 1;
        if (self.step == 0) {
            const calls = try a.alloc(ToolCall, 1);
            calls[0] = .{
                .id = try a.dupe(u8, "c1"),
                .name = try a.dupe(u8, "write_file"),
                .arguments = try a.dupe(u8, "{}"),
            };
            return .{
                .content = try a.dupe(u8, ""),
                .tool_calls = calls,
                .usage = .{ .prompt_tokens = 8, .completion_tokens = 2, .total_tokens = 10 },
            };
        }
        return .{
            .content = try a.dupe(u8, "FINAL REPORT"),
            .usage = .{ .prompt_tokens = 4, .completion_tokens = 1, .total_tokens = 5 },
        };
    }
};

fn testSessionAndRequest(a: std.mem.Allocator) !struct { session: *Session, request: *ChatRequest } {
    const session = try Session.init(a, "test", "https://api.example", "key", "model", "prompt", "enabled", "medium", "false", "true");
    errdefer session.deinit();
    const request = try a.create(ChatRequest);
    request.* = .{
        .allocator = a,
        .session = session,
        .base_url = try a.dupe(u8, "https://api.example"),
        .api_key = try a.dupe(u8, "key"),
        .model = try a.dupe(u8, "model"),
        .system_prompt = try a.dupe(u8, "prompt"),
        .messages = &.{},
        .thinking_enabled = false,
        .reasoning_effort = try a.dupe(u8, "medium"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    return .{ .session = session, .request = request };
}

test "subagent loop rejects disallowed tools, returns the final report, accumulates usage" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();

    var stub = SubagentStubModel{};
    const report = try runSubagentTaskWithModel(env.request, "find the answer", .{ .ctx = &stub, .call = SubagentStubModel.call });
    defer a.free(report);

    try std.testing.expectEqualStrings("FINAL REPORT", report);
    try std.testing.expect(env.request.subagent_usage_present);
    try std.testing.expectEqual(@as(u64, 15), env.request.subagent_usage.total_tokens);
    try std.testing.expectEqual(ai_chat_protocol.Toolset.subagent, stub.saw_toolset);
    try std.testing.expect(!stub.saw_memory_enabled);
    try std.testing.expect(stub.saw_subagent_prompt);

    // Progress lines landed in the session as .tool messages: the rejected
    // write_file round plus the done line with rounds + tokens.
    env.session.mutex.lock();
    defer env.session.mutex.unlock();
    var saw_running = false;
    var saw_done = false;
    for (env.session.messages.items) |msg| {
        if (msg.role != .tool) continue;
        if (std.mem.indexOf(u8, msg.content, "subagent: running write_file") != null) saw_running = true;
        if (std.mem.indexOf(u8, msg.content, "subagent: done (2 rounds, 15 tokens)") != null) saw_done = true;
    }
    try std.testing.expect(saw_running);
    try std.testing.expect(saw_done);
}

test "subagent loop applies the profile override to the sub-request" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();
    env.request.subagent_profile = .{
        .base_url = try a.dupe(u8, "https://override.example"),
        .api_key = try a.dupe(u8, "ok"),
        .model = try a.dupe(u8, "om"),
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = try a.dupe(u8, "low"),
        .max_tokens = 2048,
    };

    var stub = SubagentStubModel{ .step = 1 }; // first call already returns the final answer
    const report = try runSubagentTaskWithModel(env.request, "task", .{ .ctx = &stub, .call = SubagentStubModel.call });
    defer a.free(report);
    try std.testing.expectEqualStrings("https://override.example", stub.saw_base_url[0..stub.saw_base_url_len]);
}

test "subagent loop honors cancellation" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();
    env.session.stop_requested.store(true, .release);

    var stub = SubagentStubModel{};
    try std.testing.expectError(error.Canceled, runSubagentTaskWithModel(env.request, "task", .{ .ctx = &stub, .call = SubagentStubModel.call }));
}

test "subagent tool call requires a task argument" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();

    var call = ToolCall{
        .id = try a.dupe(u8, "c1"),
        .name = try a.dupe(u8, "subagent"),
        .arguments = try a.dupe(u8, "{}"),
    };
    defer call.deinit(a);
    const out = try executeToolCall(env.request, call);
    defer a.free(out);
    try std.testing.expectEqualStrings("Missing task", out);
}

test "applySubagentUsage merges into the loop total" {
    const a = std.testing.allocator;
    const env = try testSessionAndRequest(a);
    defer env.session.deinit();
    defer env.request.deinit();
    env.request.subagent_usage = .{ .prompt_tokens = 100, .completion_tokens = 20, .total_tokens = 120 };
    env.request.subagent_usage_present = true;

    var total: ApiUsage = .{ .total_tokens = 7 };
    var has_usage = false;
    applySubagentUsage(env.request, &total, &has_usage);
    try std.testing.expect(has_usage);
    try std.testing.expectEqual(@as(u64, 127), total.total_tokens);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-full`
Expected: compile error — `runSubagentTaskWithModel`, `applySubagentUsage` not defined.

- [ ] **Step 3: Implement** (new section in `src/ai_chat_request.zig`, after `runAgentRequest`; add `const platform_agent_prompt = @import("platform/agent_prompt.zig");` to the imports)

```zig
// ---------------------------------------------------------------------------
// Subagent: nested research agent loop (the `subagent` tool)
// ---------------------------------------------------------------------------

/// Model-call seam so tests can stub the network round-trip.
pub const SubagentModel = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, request: *const ChatRequest, messages: []const RequestMessage) anyerror!ApiResult,
};

fn realSubagentModelCall(_: ?*anyopaque, request: *const ChatRequest, messages: []const RequestMessage) anyerror!ApiResult {
    return runChatRequestForMessages(request, messages, true);
}

fn subagentToolCall(request: *ChatRequest, call: ToolCall) ![]u8 {
    const args = ai_chat_tools.parseArgs(request.allocator, call.arguments) orelse
        return request.allocator.dupe(u8, "Invalid tool arguments");
    defer args.deinit();
    const task = ai_chat_tools.jsonStringArg(args.value, "task") orelse
        return request.allocator.dupe(u8, "Missing task");
    if (std.mem.trim(u8, task, " \t\r\n").len == 0)
        return request.allocator.dupe(u8, "Missing task");
    return runSubagentTaskWithModel(request, task, .{ .call = realSubagentModelCall });
}

pub fn runSubagentTaskWithModel(request: *ChatRequest, task: []const u8, model: SubagentModel) ![]u8 {
    const allocator = request.allocator;

    // Stack-local derived request: shares the parent's session (cancellation),
    // tool host/snapshot, and settings; overrides prompt/toolset/credentials.
    // Never deinit it — every pointer is borrowed from the parent or static.
    var sub_request = request.*;
    sub_request.system_prompt = @constCast(platform_agent_prompt.subagentSystemPrompt);
    sub_request.stream = false;
    sub_request.memory_enabled = false;
    sub_request.copilot = false;
    sub_request.toolset = .subagent;
    if (request.subagent_profile) |profile| {
        sub_request.base_url = profile.base_url;
        sub_request.api_key = profile.api_key;
        sub_request.model = profile.model;
        sub_request.protocol = profile.protocol;
        sub_request.thinking_enabled = profile.thinking_enabled;
        sub_request.reasoning_effort = profile.reasoning_effort;
        sub_request.max_tokens = profile.max_tokens;
    }

    var transcript: std.ArrayListUnmanaged(RequestMessage) = .empty;
    defer {
        for (transcript.items) |msg| msg.deinit(allocator);
        transcript.deinit(allocator);
    }
    {
        var user_msg = try requestMessageWithClonedFields(allocator, .user, task, null, null, null, null);
        var owned = true;
        errdefer if (owned) user_msg.deinit(allocator);
        try transcript.append(allocator, user_msg);
        owned = false;
    }

    var sub_usage: ApiUsage = .{};
    var has_sub_usage = false;
    var rounds: usize = 0;
    while (true) {
        if (ai_chat.requestCancelled(request)) return error.Canceled;
        const result = try model.call(model.ctx, &sub_request, transcript.items);
        rounds += 1;
        if (ai_chat.requestCancelled(request)) {
            result.deinit(allocator);
            return error.Canceled;
        }
        if (result.usage) |usage| {
            sub_usage.add(usage);
            has_sub_usage = true;
        }
        if (result.tool_calls == null or result.tool_calls.?.len == 0) {
            if (result.reasoning) |reasoning| allocator.free(reasoning);
            if (result.tool_calls) |calls| allocator.free(calls);
            if (has_sub_usage) {
                request.subagent_usage.add(sub_usage);
                request.subagent_usage_present = true;
            }
            const done = std.fmt.allocPrint(allocator, "subagent: done ({d} rounds, {d} tokens)", .{ rounds, sub_usage.total_tokens }) catch null;
            if (done) |text| {
                defer allocator.free(text);
                ai_chat.appendProgressMessage(request.session, text) catch {};
            }
            return ai_chat_tools.truncateOwned(allocator, ai_chat.currentAgentSettings(), result.content);
        }
        errdefer result.deinit(allocator);

        var assistant_msg = try assistantToolCallMessage(allocator, result.content, result.reasoning, result.tool_calls.?);
        var assistant_msg_owned = true;
        errdefer if (assistant_msg_owned) assistant_msg.deinit(allocator);
        try transcript.append(allocator, assistant_msg);
        assistant_msg_owned = false;

        for (result.tool_calls.?) |call| {
            if (ai_chat.requestCancelled(request)) return error.Canceled;
            const progress = try std.fmt.allocPrint(allocator, "subagent: running {s} {s}", .{ call.name, call.arguments });
            defer allocator.free(progress);
            ai_chat.appendProgressMessage(request.session, progress) catch {};

            // Allow-list first: a nested `subagent` (or any exec/write tool)
            // never reaches the dispatcher.
            const tool_result = if (!ai_chat_protocol.subagentToolAllowed(call.name))
                try allocator.dupe(u8, "Tool not available in subagent.")
            else
                try executeToolCall(request, call);
            defer allocator.free(tool_result);
            if (ai_chat.requestCancelled(request)) return error.Canceled;

            var tool_msg = try requestMessageWithClonedFields(allocator, .tool, tool_result, null, call.id, null, null);
            var tool_msg_owned = true;
            errdefer if (tool_msg_owned) tool_msg.deinit(allocator);
            try transcript.append(allocator, tool_msg);
            tool_msg_owned = false;
        }
        result.deinit(allocator);
    }
}

fn applySubagentUsage(request: *const ChatRequest, total_usage: *ApiUsage, has_usage: *bool) void {
    if (!request.subagent_usage_present) return;
    total_usage.add(request.subagent_usage);
    has_usage.* = true;
}
```

3b. Intercept in `executeToolCall` (~line 632) — first line of the body:

```zig
pub fn executeToolCall(request: *ChatRequest, call: ToolCall) ![]u8 {
    if (std.mem.eql(u8, call.name, "subagent")) return subagentToolCall(request, call);
    var tool_ctx = toolContextFromRequest(request);
    ...
```

3c. Merge subagent usage in `runAgentRequest`'s final-answer branch (~line 263):

```zig
        if (result.tool_calls == null or result.tool_calls.?.len == 0) {
            applySubagentUsage(request, &total_usage, &has_usage);
            var final = result;
            if (has_usage) final.usage = total_usage;
            return final;
        }
```

- [ ] **Step 4: Run tests**

Run: `zig build test-full`
Expected: PASS (all five new tests).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_request.zig
git commit -m "feat(agent): nested subagent research loop with injectable model seam"
```

---

### Task 5: `ai-subagent-profile` config key + App/AppWindow/overlays wiring

**Files:**
- Modify: `src/config.zig` (field ~line 329, applyKeyValue ~line 863, preserved-keys list ~line 1586, tests ~line 2082)
- Modify: `src/App.zig` (mirror `jina_api_key` at every occurrence)
- Modify: `src/AppWindow.zig` (init ~line 195, applyReloadedConfig ~line 4084)
- Modify: `src/renderer/overlays.zig` (name storage + resolver, near `aiDefaultProfileName` ~line 3351)

- [ ] **Step 1: Write the failing test** (in `src/config.zig`, next to the `ai-default-profile` test at ~2082)

```zig
test "config: ai-subagent-profile parses" {
    const allocator = std.testing.allocator;
    var cfg = Config{};
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("", cfg.@"ai-subagent-profile");
    cfg.applyKeyValue(allocator, "ai-subagent-profile", "cheap-fast", ".");
    try std.testing.expectEqualStrings("cheap-fast", cfg.@"ai-subagent-profile");
}
```

(Match the exact shape of the `ai-default-profile` test at line 2082 — if it constructs/loads the config differently, mirror that.)

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-full`
Expected: compile error — no field `ai-subagent-profile`.

- [ ] **Step 3: Implement config key**

Run `grep -n "ai-default-profile" src/config.zig` and mirror EVERY hit for `ai-subagent-profile`:

- field declaration (after `ai-default-profile` ~line 329):

```zig
/// Name of the saved AI profile the Copilot `subagent` tool runs on. Empty =
/// the subagent uses the main conversation's profile.
@"ai-subagent-profile": []const u8 = "",
```

- `applyKeyValue` branch (~line 863):

```zig
    } else if (std.mem.eql(u8, key, "ai-subagent-profile")) {
        self.@"ai-subagent-profile" = self.dupeString(allocator, value) orelse return;
```

- preserved-keys list (~line 1586): add `"ai-subagent-profile",` next to `"ai-default-profile",`.
- any deinit/free site the grep reveals for `ai-default-profile`: mirror it.

- [ ] **Step 4: Implement App field**

Run `grep -n "jina_api_key" src/App.zig` and mirror every hit for a new `ai_subagent_profile` field (declaration ~line 109, dupe at create ~line 202, struct literal ~line 255, `updateConfig` ~line 450 via `replaceStr`, and the matching free in `deinit`), sourced from `cfg.@"ai-subagent-profile"`.

- [ ] **Step 5: Implement overlays name storage + resolver** (in `src/renderer/overlays.zig`, below `invalidateAiDefaultName` ~line 3374)

```zig
threadlocal var g_subagent_profile_name_buf: [256]u8 = undefined;
threadlocal var g_subagent_profile_name_len: usize = 0;

/// Cache of the `ai-subagent-profile` config key, pushed by the app layer at
/// startup and on config reload (no file IO on the resolve path).
pub fn setSubagentProfileName(name: []const u8) void {
    const len = @min(name.len, g_subagent_profile_name_buf.len);
    @memcpy(g_subagent_profile_name_buf[0..len], name[0..len]);
    g_subagent_profile_name_len = len;
}

/// ai_chat.SubagentProfileResolver: map the configured profile name to owned
/// credentials. Any miss (unset key, unknown name, invalid profile) returns
/// null — the subagent then falls back to the main conversation's profile.
pub fn resolveSubagentProfileOverride(allocator: std.mem.Allocator) ?ai_chat.SubagentProfileOverride {
    const name = g_subagent_profile_name_buf[0..g_subagent_profile_name_len];
    if (name.len == 0) return null;
    loadAiProfiles();
    var found: ?usize = null;
    for (0..g_ai_profile_count) |i| {
        if (std.mem.eql(u8, aiProfileField(&g_ai_profiles[i], .name), name)) {
            found = i;
            break;
        }
    }
    const idx = found orelse return null;
    const profile = &g_ai_profiles[idx];
    const base_url = aiProfileField(profile, .base_url);
    const model = aiProfileField(profile, .model);
    if (base_url.len == 0 or model.len == 0) return null;
    if (!isHttpUrlish(base_url)) return null;

    const base_url_copy = allocator.dupe(u8, base_url) catch return null;
    const api_key_copy = allocator.dupe(u8, aiProfileField(profile, .api_key)) catch {
        allocator.free(base_url_copy);
        return null;
    };
    const model_copy = allocator.dupe(u8, model) catch {
        allocator.free(base_url_copy);
        allocator.free(api_key_copy);
        return null;
    };
    const reasoning_copy = allocator.dupe(u8, aiProfileField(profile, .reasoning_effort)) catch {
        allocator.free(base_url_copy);
        allocator.free(api_key_copy);
        allocator.free(model_copy);
        return null;
    };
    return .{
        .base_url = base_url_copy,
        .api_key = api_key_copy,
        .model = model_copy,
        .protocol = ai_chat.ApiProtocol.parse(aiProfileField(profile, .protocol)),
        .thinking_enabled = !std.mem.eql(u8, aiProfileField(profile, .thinking), "disabled"),
        .reasoning_effort = reasoning_copy,
        .max_tokens = std.fmt.parseInt(u32, std.mem.trim(u8, aiProfileField(profile, .max_tokens), " \t"), 10) catch 8192,
    };
}
```

- [ ] **Step 6: Wire AppWindow**

In `src/AppWindow.zig` init, after `ai_chat.setDefaultWorkingDir(app.ai_agent_working_dir);` (~line 194):

```zig
    overlays.setSubagentProfileName(app.ai_subagent_profile);
    ai_chat.setSubagentProfileResolver(overlays.resolveSubagentProfileOverride);
```

In `applyReloadedConfig`, after `ai_chat.setDefaultWorkingDir(cfg.@"ai-agent-working-dir");` (~line 4083):

```zig
    overlays.setSubagentProfileName(cfg.@"ai-subagent-profile");
```

- [ ] **Step 7: Run tests and build**

Run: `zig build test-full && zig build test && zig build`
Expected: all PASS, app compiles.

- [ ] **Step 8: Commit**

```bash
git add src/config.zig src/App.zig src/AppWindow.zig src/renderer/overlays.zig
git commit -m "feat(agent): ai-subagent-profile config key resolves subagent credentials"
```

---

### Task 6: Final verification

- [ ] **Step 1: Full suites + app build from a clean state**

Run: `zig build test && zig build test-full && zig build`
Expected: all green.

- [ ] **Step 2: Sanity-check the schema end to end**

Run: `zig build test 2>&1 | tail -3` then verify by grep that no stray full-set tool leaks into subagent mode:

```bash
grep -n "subagentToolAllowed" src/ai_chat_protocol.zig src/ai_chat_request.zig
```

Expected: exactly two production uses — the `Filtered.emitTool` filter and the nested-loop dispatch guard.

- [ ] **Step 3: Update the spec status line**

In `docs/superpowers/specs/2026-06-12-copilot-subagent-design.md` change `**Status:** Approved (ready for implementation plan)` to `**Status:** Implemented (suites green; GUI verify pending)`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-12-copilot-subagent-design.md
git commit -m "docs: mark copilot subagent spec implemented"
```

---

## Notes for the implementer

- **GUI verification stays pending** after this plan: launch WispTerm, set `ai-subagent-profile`, ask the Copilot a research-heavy question, and watch the `subagent: …` progress lines. Not automatable here.
- **Threading invariant:** the resolver runs on the UI thread inside `buildRequestLocked`; the request worker must only ever touch `request.subagent_profile` (owned copies). Never read `g_ai_profiles` from the worker.
- **Weixin-originated requests** may build on a non-UI thread where the threadlocal profile-name cache is empty; the resolver then returns null and the subagent silently uses the main credentials. Accepted v1 degradation (spec: fallback is never an error).
- If `zig build test-full` reports the pre-existing `web_read_cache` failure seen on some hosts, confirm it also fails on `main` before blaming this work.
