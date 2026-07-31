# First-Party Agent Tool Disable Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Skill Center display WispTerm first-party AI Agent tools and let users turn them off with both schema-level hiding and runtime dispatch rejection.

**Architecture:** Add a focused first-party tool catalog/state module, feed its disabled-tool snapshot into AI request schema generation and runtime dispatch, then add first-party rows to the existing Skill Center mixed entry model. Imported binary tool manifests remain independent; first-party state is persisted in one config-directory JSON file.

**Tech Stack:** Zig 0.15, WispTerm Skill Center model/renderer, AI Agent protocol builders, `platform/dirs.zig`, `platform/atomic_file.zig`, `zig build test`, `zig build test-full`.

---

## File Structure

- Create `src/first_party_tools.zig`: first-party tool catalog, disabled-state parsing, atomic state writes, and pure tests.
- Modify `src/test_fast.zig` and `src/test_main.zig`: import `first_party_tools.zig` so its tests run in both suites.
- Modify `src/ai_chat_protocol.zig`: add disabled first-party tool filtering to all tool schema emitters and add drift tests against the catalog.
- Modify `src/ai_chat_types.zig`: carry a disabled first-party tool name snapshot in `AgentSettings`.
- Modify `src/ai_chat.zig`: own/reload global disabled first-party state, clone it into `ChatRequest`, and pass it into request params/tool contexts.
- Modify `src/ai_chat_request.zig`: pass disabled first-party state into leaf tool contexts and block disabled `subagent` before its special handler runs.
- Modify `src/ai_chat_tools.zig`: reject disabled first-party tool calls before any tool-specific side effect.
- Modify `src/skill_center.zig`: add first-party tool row data and model tests.
- Modify `src/AppWindow.zig`: merge first-party rows into Skill Center scan results, toggle persisted state, reload AI state, and render built-in row metadata.
- Modify `src/i18n.zig`: change Skill Center legend/status text from "enable" to "toggle" in English and Chinese.
- Modify `docs/ai-agent.md`, `docs/ai.html`, and `docs/faq.md`: document first-party tool enable/disable behavior.

---

### Task 1: First-Party Tool Catalog And State File

**Files:**
- Create: `src/first_party_tools.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write failing tests for catalog and state parsing**

Create `src/first_party_tools.zig` with only imports, type declarations, and these tests. The referenced functions are intentionally missing in this step.

```zig
const std = @import("std");

test "first_party_tools: active definitions include webread and the local command tool" {
    const a = std.testing.allocator;
    const defs = try activeDefinitions(a);
    defer freeDefinitions(a, defs);

    try std.testing.expect(isKnownActive(defs, "webread"));
    try std.testing.expect(isKnown(platformLocalCommandNameForTest()));
}

test "first_party_tools: disabled state json filters unknown and duplicate names" {
    const a = std.testing.allocator;
    var disabled = try parseDisabledToolsJson(
        a,
        \\{"disabled":["webread","missing_tool","webread","pubmed"]}
    );
    defer disabled.deinit(a);

    try std.testing.expect(disabled.contains("webread"));
    try std.testing.expect(disabled.contains("pubmed"));
    try std.testing.expect(!disabled.contains("missing_tool"));
    try std.testing.expectEqual(@as(usize, 2), disabled.names.len);
}

test "first_party_tools: malformed state falls back to empty when loaded from path" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "agent_tools.json", .data = "not json" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "agent_tools.json" });
    defer a.free(path);

    var disabled = loadDisabledToolsFromPath(a, path) catch DisabledTools.empty();
    defer disabled.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), disabled.names.len);
}

test "first_party_tools: toggled state writes and reads atomically" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "agent_tools.json" });
    defer a.free(path);

    var current = DisabledTools.empty();
    var next = try toggledDisabledTools(a, current, "webread");
    defer next.deinit(a);
    try writeDisabledToolsToPath(a, path, next);

    var loaded = try loadDisabledToolsFromPath(a, path);
    defer loaded.deinit(a);
    try std.testing.expect(loaded.contains("webread"));

    var enabled_again = try toggledDisabledTools(a, loaded, "webread");
    defer enabled_again.deinit(a);
    try std.testing.expect(!enabled_again.contains("webread"));
}
```

- [ ] **Step 2: Import the new module in test aggregators**

Add this line to the import block in both `src/test_fast.zig` and `src/test_main.zig`:

```zig
    _ = @import("first_party_tools.zig");
```

- [ ] **Step 3: Run the fast test and verify it fails for missing symbols**

Run:

```powershell
zig build test
```

Expected: FAIL with errors naming missing declarations such as `activeDefinitions`, `DisabledTools`, or `parseDisabledToolsJson`.

- [ ] **Step 4: Implement the catalog and disabled-state helpers**

Replace `src/first_party_tools.zig` with the tests from Step 1 plus this implementation above the tests:

```zig
const std = @import("std");
const platform_atomic_file = @import("platform/atomic_file.zig");
const platform_dirs = @import("platform/dirs.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");

const MAX_STATE_BYTES: usize = 64 * 1024;
const STATE_BASENAME = "agent_tools.json";

pub const Category = enum {
    terminal,
    file,
    web,
    docs,
    memory,
    integration,
    session,
    agent,
};

pub const Definition = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    category: Category,
    disableable: bool = true,
};

const static_definitions = [_]Definition{
    .{ .name = "terminal_list", .label = "terminal_list", .description = "List WispTerm terminal surfaces visible to the agent.", .category = .terminal },
    .{ .name = "terminal_context", .label = "terminal_context", .description = "Report the current selected terminal write context.", .category = .terminal },
    .{ .name = "terminal_snapshot", .label = "terminal_snapshot", .description = "Read a bounded text snapshot from terminal surfaces.", .category = .terminal },
    .{ .name = "terminal_select", .label = "terminal_select", .description = "Select the terminal surface used for subsequent write tools.", .category = .terminal },
    .{ .name = "ssh_session_exec", .label = "ssh_session_exec", .description = "Run a shell command in an already-open SSH terminal surface.", .category = .terminal },
    .{ .name = "terminal_repl_exec", .label = "terminal_repl_exec", .description = "Send text to an already-open interactive REPL or agent app.", .category = .terminal },
    .{ .name = "terminal_answer_prompt", .label = "terminal_answer_prompt", .description = "Answer an approval prompt in an agent terminal surface.", .category = .terminal },
    .{ .name = "ask_user", .label = "ask_user", .description = "Ask the user a blocking multiple-choice question.", .category = .agent },
    .{ .name = "read_file", .label = "read_file", .description = "Read a local or remote text file.", .category = .file },
    .{ .name = "copy_file", .label = "copy_file", .description = "Copy a file between local, WSL, and SSH contexts.", .category = .file },
    .{ .name = "write_file", .label = "write_file", .description = "Create or overwrite a local or remote text file.", .category = .file },
    .{ .name = "edit_file", .label = "edit_file", .description = "Replace exact text in a local or remote text file.", .category = .file },
    .{ .name = "ssh_profile_save", .label = "ssh_profile_save", .description = "Create or update a saved WispTerm SSH profile.", .category = .session },
    .{ .name = "ssh_profile_connect", .label = "ssh_profile_connect", .description = "Open a new tab from a saved WispTerm SSH profile.", .category = .session },
    .{ .name = "tab_new", .label = "tab_new", .description = "Open a new WispTerm terminal tab.", .category = .session },
    .{ .name = "tab_close", .label = "tab_close", .description = "Close a selected terminal tab.", .category = .session },
    .{ .name = "skill_info", .label = "skill_info", .description = "Load a WispTerm skill by stable name.", .category = .agent },
    .{ .name = "wispterm_docs", .label = "wispterm_docs", .description = "Read WispTerm's own documentation.", .category = .docs },
    .{ .name = "websearch", .label = "websearch", .description = "Search the web for current information via Jina.", .category = .web },
    .{ .name = "webread", .label = "webread", .description = "Read a web page or local document into markdown via Jina Reader.", .category = .web },
    .{ .name = "pubmed", .label = "pubmed", .description = "Search PubMed biomedical literature.", .category = .web },
    .{ .name = "subagent", .label = "subagent", .description = "Delegate a self-contained research task to a background subagent.", .category = .agent },
    .{ .name = "weixin_send_attachment", .label = "weixin_send_attachment", .description = "Send a local file back to the active Weixin conversation.", .category = .integration },
    .{ .name = "memory_save", .label = "memory_save", .description = "Save a durable long-term memory.", .category = .memory },
    .{ .name = "memory_recall", .label = "memory_recall", .description = "Read a durable long-term memory.", .category = .memory },
    .{ .name = "memory_delete", .label = "memory_delete", .description = "Delete a durable long-term memory.", .category = .memory },
};

pub const DisabledTools = struct {
    names: [][]u8,

    pub fn empty() DisabledTools {
        return .{ .names = &.{} };
    }

    pub fn deinit(self: *DisabledTools, allocator: std.mem.Allocator) void {
        for (self.names) |name| allocator.free(name);
        if (self.names.len > 0) allocator.free(self.names);
        self.* = empty();
    }

    pub fn contains(self: DisabledTools, name: []const u8) bool {
        return isDisabledName(self.names, name);
    }
};

pub fn platformLocalCommandNameForTest() []const u8 {
    return platform_process.localCommandToolName();
}

pub fn activeDefinitions(allocator: std.mem.Allocator) ![]Definition {
    var list: std.ArrayListUnmanaged(Definition) = .empty;
    errdefer list.deinit(allocator);

    const local_name = platform_process.localCommandToolName();
    try list.append(allocator, .{
        .name = local_name,
        .label = local_name,
        .description = platform_process.localCommandToolDescription(),
        .category = .terminal,
    });

    for (static_definitions) |definition| try list.append(allocator, definition);

    if (platform_pty_command.wslSessionToolsEnabled()) {
        const wsl_name = platform_pty_command.wslSessionToolName();
        try list.append(allocator, .{
            .name = wsl_name,
            .label = wsl_name,
            .description = platform_pty_command.wslSessionToolDescription(),
            .category = .terminal,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeDefinitions(allocator: std.mem.Allocator, defs: []Definition) void {
    allocator.free(defs);
}

pub fn isKnown(name: []const u8) bool {
    if (std.mem.eql(u8, name, platform_process.localCommandToolName())) return true;
    if (platform_pty_command.wslSessionToolsEnabled() and std.mem.eql(u8, name, platform_pty_command.wslSessionToolName())) return true;
    for (static_definitions) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return true;
    }
    return false;
}

pub fn isKnownActive(defs: []const Definition, name: []const u8) bool {
    for (defs) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return true;
    }
    return false;
}

pub fn isDisabledName(disabled_names: []const []const u8, name: []const u8) bool {
    for (disabled_names) |disabled| {
        if (std.mem.eql(u8, disabled, name)) return true;
    }
    return false;
}

pub fn parseDisabledToolsJson(allocator: std.mem.Allocator, bytes: []const u8) !DisabledTools {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAgentToolsState;

    const disabled_value = parsed.value.object.get("disabled") orelse return DisabledTools.empty();
    if (disabled_value != .array) return error.InvalidAgentToolsState;

    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (list.items) |name| allocator.free(name);
        list.deinit(allocator);
    }

    for (disabled_value.array.items) |item| {
        if (item != .string) continue;
        if (!isKnown(item.string)) continue;
        if (isDisabledName(list.items, item.string)) continue;
        try list.append(allocator, try allocator.dupe(u8, item.string));
    }

    return .{ .names = try list.toOwnedSlice(allocator) };
}

pub fn loadDisabledToolsFromPath(allocator: std.mem.Allocator, path: []const u8) !DisabledTools {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_STATE_BYTES) catch |err| switch (err) {
        error.FileNotFound => return DisabledTools.empty(),
        else => return err,
    };
    defer allocator.free(bytes);
    return parseDisabledToolsJson(allocator, bytes) catch DisabledTools.empty();
}

pub fn loadDisabledTools(allocator: std.mem.Allocator) !DisabledTools {
    const path = platform_dirs.pathInConfigDir(allocator, STATE_BASENAME) catch return DisabledTools.empty();
    defer allocator.free(path);
    return loadDisabledToolsFromPath(allocator, path) catch DisabledTools.empty();
}

pub fn disabledToolsJson(allocator: std.mem.Allocator, disabled: DisabledTools) ![]u8 {
    const State = struct {
        disabled: []const []const u8,
    };
    return std.json.Stringify.valueAlloc(allocator, State{ .disabled = disabled.names }, .{ .whitespace = .indent_2 });
}

pub fn writeDisabledToolsToPath(allocator: std.mem.Allocator, path: []const u8, disabled: DisabledTools) !void {
    const json = try disabledToolsJson(allocator, disabled);
    defer allocator.free(json);
    try platform_atomic_file.writeFileReplaceSafe(path, json);
}

pub fn writeDisabledTools(allocator: std.mem.Allocator, disabled: DisabledTools) !void {
    const config_dir = try platform_dirs.configDir(allocator);
    defer allocator.free(config_dir);
    try std.fs.cwd().makePath(config_dir);
    const path = try std.fs.path.join(allocator, &.{ config_dir, STATE_BASENAME });
    defer allocator.free(path);
    try writeDisabledToolsToPath(allocator, path, disabled);
}

pub fn toggledDisabledTools(allocator: std.mem.Allocator, current: DisabledTools, name: []const u8) !DisabledTools {
    if (!isKnown(name)) return error.UnknownFirstPartyTool;
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (list.items) |owned| allocator.free(owned);
        list.deinit(allocator);
    }

    var removed = false;
    for (current.names) |existing| {
        if (std.mem.eql(u8, existing, name)) {
            removed = true;
            continue;
        }
        try list.append(allocator, try allocator.dupe(u8, existing));
    }

    if (!removed) try list.append(allocator, try allocator.dupe(u8, name));
    return .{ .names = try list.toOwnedSlice(allocator) };
}
```

- [ ] **Step 5: Run the fast test and commit**

Run:

```powershell
zig build test
```

Expected: PASS.

Commit:

```bash
git add src/first_party_tools.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: add first-party tool state registry"
```

---

### Task 2: Filter Disabled First-Party Tools From Request Schemas

**Files:**
- Modify: `src/ai_chat_protocol.zig`

- [ ] **Step 1: Write failing schema filtering tests**

Add these tests near the existing agent tool schema tests in `src/ai_chat_protocol.zig`:

```zig
test "disabled first-party tools are omitted from every protocol schema" {
    const a = std.testing.allocator;
    const disabled = [_][]const u8{"webread"};
    const params = RequestParams{
        .model = "m",
        .system_prompt = "s",
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .disabled_first_party_tools = disabled[0..],
    };

    const chat = try buildRequestJson(a, params, &.{}, true);
    defer a.free(chat);
    try std.testing.expect(std.mem.indexOf(u8, chat, "\"name\":\"webread\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, chat, "\"name\":\"websearch\"") != null);

    var responses_params = params;
    responses_params.protocol = .responses;
    const responses = try buildRequestJson(a, responses_params, &.{}, true);
    defer a.free(responses);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"name\":\"webread\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"name\":\"websearch\"") != null);

    var anthropic_params = params;
    anthropic_params.protocol = .anthropic;
    const anthropic = try buildRequestJson(a, anthropic_params, &.{}, true);
    defer a.free(anthropic);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"name\":\"webread\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"name\":\"websearch\"") != null);
}

test "subagent schema also inherits disabled first-party tools" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    const disabled = [_][]const u8{"webread"};

    try appendToolSchemas(a, &out, .{
        .include_memory = true,
        .toolset = .subagent,
        .disabled_first_party_tools = disabled[0..],
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"webread\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"websearch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"terminal_snapshot\"") != null);
}

test "first-party catalog covers every emitted built-in schema tool name" {
    const a = std.testing.allocator;
    const names = try collectBuiltinToolNamesForTesting(a, .{ .include_memory = true });
    defer freeCollectedToolNamesForTesting(a, names);

    for (names) |name| {
        try std.testing.expect(first_party_tools.isKnown(name));
    }
}
```

- [ ] **Step 2: Run the fast test and verify it fails for missing fields/helpers**

Run:

```powershell
zig build test
```

Expected: FAIL because `RequestParams.disabled_first_party_tools`, `ToolSpecOpts.disabled_first_party_tools`, and the collect/free helpers do not exist.

- [ ] **Step 3: Implement schema filtering**

At the top of `src/ai_chat_protocol.zig`, add:

```zig
const first_party_tools = @import("first_party_tools.zig");
```

Extend `RequestParams`:

```zig
    disabled_first_party_tools: []const []const u8 = &.{},
```

When calling schema appenders in `buildChatCompletionsRequestJsonForMessages`, `buildResponsesRequestJsonForMessages`, and `buildAnthropicRequestJsonForMessages`, pass the new field:

```zig
.{ .include_memory = params.memory_enabled, .toolset = params.toolset, .dynamic_tools = params.dynamic_tools, .disabled_first_party_tools = params.disabled_first_party_tools }
```

Extend `ToolSpecOpts`:

```zig
    disabled_first_party_tools: []const []const u8 = &.{},
```

In `forEachToolSpec`, change `Filtered.emitTool` to:

```zig
        fn emitTool(c: Ctx, o: ToolSpecOpts, name: []const u8, description: []const u8, properties: []const u8) anyerror!void {
            if (o.toolset == .subagent and !subagentToolAllowed(name)) return;
            if (first_party_tools.isDisabledName(o.disabled_first_party_tools, name)) return;
            try emit(c, name, description, properties);
        }
```

Add these helpers below `dynamicToolNameSeenBefore`:

```zig
pub fn collectBuiltinToolNamesForTesting(allocator: std.mem.Allocator, opts: ToolSpecOpts) ![][]u8 {
    const Collector = struct {
        allocator: std.mem.Allocator,
        names: std.ArrayListUnmanaged([]u8) = .empty,

        fn emit(self: *@This(), name: []const u8, _: []const u8, _: []const u8) !void {
            try self.names.append(self.allocator, try self.allocator.dupe(u8, name));
        }
    };

    var collector = Collector{ .allocator = allocator };
    errdefer freeCollectedToolNamesForTesting(allocator, collector.names.items);
    var no_dynamic = opts;
    no_dynamic.dynamic_tools = &.{};
    try forEachToolSpec(*Collector, &collector, no_dynamic, Collector.emit);
    return collector.names.toOwnedSlice(allocator);
}

pub fn freeCollectedToolNamesForTesting(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}
```

- [ ] **Step 4: Run the fast test and commit**

Run:

```powershell
zig build test
```

Expected: PASS.

Commit:

```bash
git add src/ai_chat_protocol.zig
git commit -m "feat: filter disabled first-party tool schemas"
```

---

### Task 3: Carry Disabled First-Party Tool State Through Agent Requests

**Files:**
- Modify: `src/ai_chat_types.zig`
- Modify: `src/ai_chat.zig`
- Modify: `src/ai_chat_request.zig`
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Write failing snapshot ownership test**

Add this test near the dynamic tool snapshot tests in `src/ai_chat.zig`:

```zig
test "ai chat session request owns first-party disabled tool snapshot" {
    const a = std.testing.allocator;
    const saved_settings = g_agent_settings;
    const saved_disabled = g_first_party_disabled_tools;
    const saved_disabled_owned = g_first_party_disabled_tools_owned;
    defer {
        configureAgent(saved_settings);
        g_first_party_disabled_tools = saved_disabled;
        g_first_party_disabled_tools_owned = saved_disabled_owned;
    }

    g_first_party_disabled_tools = try cloneStringList(a, &[_][]const u8{"webread"});
    g_first_party_disabled_tools_owned = true;

    var session = try Session.initWithVision(
        a,
        "Disabled snapshot",
        "https://api.example.test",
        "key",
        "model",
        ai_chat_protocol.DEFAULT_PROTOCOL,
        "",
        "disabled",
        "",
        "false",
        "true",
        DEFAULT_VISION,
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hello") });
    const req = try session.buildRequestLocked();
    session.mutex.unlock();
    defer req.deinit();

    try std.testing.expectEqual(@as(usize, 1), req.disabled_first_party_tools.len);
    try std.testing.expectEqualStrings("webread", req.disabled_first_party_tools[0]);

    @memcpy(g_first_party_disabled_tools[0], "pubmed");
    try std.testing.expectEqualStrings("webread", req.disabled_first_party_tools[0]);
}
```

- [ ] **Step 2: Run the fast test and verify it fails**

Run:

```powershell
zig build test
```

Expected: FAIL because `g_first_party_disabled_tools`, `cloneStringList`, and `ChatRequest.disabled_first_party_tools` do not exist.

- [ ] **Step 3: Add disabled tool state to AgentSettings and ChatRequest**

In `src/ai_chat_types.zig`, extend `AgentSettings`:

```zig
    disabled_first_party_tools: []const []const u8 = &.{},
```

In `src/ai_chat.zig`, import the catalog:

```zig
const first_party_tools = @import("first_party_tools.zig");
```

Near the dynamic tool globals, add:

```zig
threadlocal var g_first_party_disabled_tools: [][]u8 = &.{};
threadlocal var g_first_party_disabled_tools_owned: bool = false;
```

Add these helpers near the existing dynamic tool clone/free helpers:

```zig
fn cloneStringList(allocator: std.mem.Allocator, names: []const []const u8) ![][]u8 {
    if (names.len == 0) return &.{};
    const out = try allocator.alloc([]u8, names.len);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |name| allocator.free(name);
        allocator.free(out);
    }
    for (names) |name| {
        out[written] = try allocator.dupe(u8, name);
        written += 1;
    }
    return out;
}

fn freeOwnedStringList(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    if (names.len > 0) allocator.free(names);
}

fn freeFirstPartyDisabledTools(allocator: std.mem.Allocator) void {
    if (!g_first_party_disabled_tools_owned) return;
    freeOwnedStringList(allocator, g_first_party_disabled_tools);
    g_first_party_disabled_tools = &.{};
    g_first_party_disabled_tools_owned = false;
}

pub fn reloadFirstPartyToolState(allocator: std.mem.Allocator) void {
    freeFirstPartyDisabledTools(allocator);
    var disabled = first_party_tools.loadDisabledTools(allocator) catch {
        g_first_party_disabled_tools = &.{};
        g_first_party_disabled_tools_owned = false;
        return;
    };
    g_first_party_disabled_tools = disabled.names;
    g_first_party_disabled_tools_owned = g_first_party_disabled_tools.len != 0;
    disabled.names = &.{};
}
```

Extend `ChatRequest`:

```zig
    disabled_first_party_tools: []const []const u8 = &.{},
```

In `ChatRequest.deinit`, add:

```zig
        freeOwnedStringList(self.allocator, self.disabled_first_party_tools);
```

In `ChatRequest.toParams`, add:

```zig
            .disabled_first_party_tools = self.disabled_first_party_tools,
```

In `currentAgentSettings`, add:

```zig
    s.disabled_first_party_tools = g_first_party_disabled_tools;
```

In `Session.buildRequestLocked`, clone the disabled list after cloning dynamic tools:

```zig
        const disabled_first_party_tools = try cloneStringList(self.allocator, settings.disabled_first_party_tools);
        var disabled_first_party_tools_owned = true;
        errdefer if (disabled_first_party_tools_owned) freeOwnedStringList(self.allocator, disabled_first_party_tools);
```

Then set the request field:

```zig
            .disabled_first_party_tools = disabled_first_party_tools,
```

After request construction succeeds, add:

```zig
        disabled_first_party_tools_owned = false;
```

In `src/ai_chat_request.zig`, update `toolContextFromRequest`:

```zig
    settings.disabled_first_party_tools = request.disabled_first_party_tools;
```

- [ ] **Step 4: Reload first-party state during app config application**

In `src/AppWindow.zig`, after each existing `ai_chat.configureAgent(...)` call in `AppWindow.init` and `applyReloadedConfig`, add:

```zig
    ai_chat.reloadFirstPartyToolState(allocator);
```

- [ ] **Step 5: Run the fast test and commit**

Run:

```powershell
zig build test
```

Expected: PASS.

Commit:

```bash
git add src/ai_chat_types.zig src/ai_chat.zig src/ai_chat_request.zig src/AppWindow.zig
git commit -m "feat: snapshot disabled first-party tools"
```

---

### Task 4: Reject Disabled First-Party Calls At Runtime

**Files:**
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/ai_chat_request.zig`

- [ ] **Step 1: Write failing leaf dispatch test**

Add this test near the existing `executeToolCall` tests in `src/ai_chat_tools.zig`:

```zig
fn testApproveDisabled(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return false;
}

fn testCancelledDisabled(_: *anyopaque) bool {
    return false;
}

test "executeToolCall rejects disabled first-party tool before dispatch" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const disabled = [_][]const u8{"webread"};
    var ctx = ToolContext{
        .allocator = a,
        .ctx = @ptrCast(&dummy),
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .disabled_first_party_tools = disabled[0..] },
        .approve = testApproveDisabled,
        .cancelled = testCancelledDisabled,
    };

    var call = ToolCall{
        .id = @constCast("call-1"),
        .name = @constCast("webread"),
        .arguments = @constCast("{\"url\":\"https://example.com\"}"),
    };

    const result = try executeToolCall(&ctx, call);
    defer a.free(result);
    try std.testing.expectEqualStrings("Tool is disabled: webread", result);
}
```

- [ ] **Step 2: Write failing subagent special-case test**

Add this test in `src/ai_chat_request.zig` near the subagent tests:

```zig
test "executeToolCall rejects disabled subagent before special handler" {
    const a = std.testing.allocator;
    var session = try Session.initWithVision(
        a,
        "Disabled subagent",
        "https://api.example.test",
        "key",
        "model",
        ai_chat_protocol.DEFAULT_PROTOCOL,
        "",
        "disabled",
        "",
        "false",
        "true",
        ai_chat.DEFAULT_VISION,
    );
    defer session.deinit();

    const disabled = try ai_chat.cloneStringList(a, &[_][]const u8{"subagent"});
    defer ai_chat.freeOwnedStringList(a, disabled);

    var req = ai_chat.ChatRequest{
        .allocator = a,
        .session = &session,
        .base_url = @constCast(""),
        .api_key = @constCast(""),
        .model = @constCast(""),
        .system_prompt = @constCast(""),
        .messages = &.{},
        .thinking_enabled = false,
        .reasoning_effort = @constCast(""),
        .stream = false,
        .agent_enabled = true,
        .memory_enabled = false,
        .disabled_first_party_tools = disabled,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };

    var call = ToolCall{
        .id = @constCast("call-subagent"),
        .name = @constCast("subagent"),
        .arguments = @constCast("{\"task\":\"read this\"}"),
    };
    const result = try executeToolCall(&req, call);
    defer a.free(result);
    try std.testing.expectEqualStrings("Tool is disabled: subagent", result);
}
```

If `cloneStringList` and `freeOwnedStringList` are still private after Task 3, make them `pub fn` in `src/ai_chat.zig` in this task so the test can own the request field safely.

- [ ] **Step 3: Run the fast test and verify runtime checks are missing**

Run:

```powershell
zig build test
```

Expected: FAIL because disabled first-party calls still execute their existing branches.

- [ ] **Step 4: Implement runtime checks**

In `src/ai_chat_tools.zig`, add:

```zig
const first_party_tools = @import("first_party_tools.zig");
```

At the top of `executeToolCall`, immediately after cancellation:

```zig
    if (first_party_tools.isDisabledName(ctx.settings.disabled_first_party_tools, call.name)) {
        return std.fmt.allocPrint(ctx.allocator, "Tool is disabled: {s}", .{call.name});
    }
```

In `src/ai_chat_request.zig`, import the catalog:

```zig
const first_party_tools = @import("first_party_tools.zig");
```

At the top of its `executeToolCall` wrapper, before the `subagent` special case:

```zig
    if (first_party_tools.isDisabledName(request.disabled_first_party_tools, call.name)) {
        return std.fmt.allocPrint(request.allocator, "Tool is disabled: {s}", .{call.name});
    }
```

- [ ] **Step 5: Run the fast test and commit**

Run:

```powershell
zig build test
```

Expected: PASS.

Commit:

```bash
git add src/ai_chat_tools.zig src/ai_chat_request.zig src/ai_chat.zig
git commit -m "feat: reject disabled first-party tool calls"
```

---

### Task 5: Show And Toggle First-Party Tools In Skill Center

**Files:**
- Modify: `src/skill_center.zig`
- Modify: `src/AppWindow.zig`
- Modify: `src/input.zig`
- Modify: `src/i18n.zig`

- [ ] **Step 1: Write failing Skill Center model test**

Add this test in `src/skill_center.zig` near the existing mixed entry tests:

```zig
test "skill_center: setEntries accepts first-party tool rows" {
    const a = std.testing.allocator;
    var model = PanelModel.init(a);
    defer model.deinit();

    const entries = try a.alloc(LibraryEntry, 2);
    entries[0] = .{ .first_party_tool = .{
        .name = try a.dupe(u8, "webread"),
        .description = try a.dupe(u8, "Read web pages"),
        .enabled = true,
        .disableable = true,
    } };
    entries[1] = .{ .prompt = .{
        .name = try a.dupe(u8, "pdf"),
        .rel_path = try a.dupe(u8, "pdf/SKILL.md"),
        .agg_hash = null,
    } };

    model.setEntries(entries);
    try std.testing.expectEqual(@as(usize, 2), model.entryCount());
    try std.testing.expectEqualStrings("webread", model.selectedEntry().?.name());
}
```

- [ ] **Step 2: Write failing AppWindow toggle test**

Add this test in `src/AppWindow.zig` near the existing Skill Center tool toggle tests:

```zig
test "AppWindow: skill center toggles first-party tool state file" {
    const allocator = std.testing.allocator;
    const previous_allocator = g_allocator;
    const previous_tabs = tab.g_tabs;
    const previous_count = tab.g_tab_count;
    const previous_active = active_tab_state.g_active_tab;
    defer {
        g_allocator = previous_allocator;
        tab.g_tabs = previous_tabs;
        tab.g_tab_count = previous_count;
        active_tab_state.g_active_tab = previous_active;
        platform_dirs.clearTestConfigDirForCurrentThread();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    platform_dirs.setTestConfigDirForCurrentThread(root);

    g_allocator = allocator;
    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
    if (!tab.spawnSkillCenterTab(allocator)) return error.SkipZigTest;
    defer {
        while (tab.g_tab_count > 0) {
            const idx = tab.g_tab_count - 1;
            if (tab.g_tabs[idx]) |t| {
                t.deinit(allocator);
                allocator.destroy(t);
                tab.g_tabs[idx] = null;
            }
            tab.g_tab_count -= 1;
        }
    }

    const session = activeSkillCenter() orelse return error.ExpectedSkillCenterTab;
    const entries = try allocator.alloc(skill_center.LibraryEntry, 1);
    entries[0] = .{ .first_party_tool = .{
        .name = try allocator.dupe(u8, "webread"),
        .description = try allocator.dupe(u8, "Read web pages"),
        .enabled = true,
        .disableable = true,
    } };

    session.mutex.lock();
    session.model.setEntries(entries);
    session.mutex.unlock();

    try std.testing.expect(skillCenterToggleToolEnabled());

    const bytes = try tmp.dir.readFileAlloc(allocator, "agent_tools.json", 4096);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"webread\"") != null);

    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.selectedEntry().?) {
        .first_party_tool => |tool| try std.testing.expect(!tool.enabled),
        else => return error.ExpectedFirstPartyTool,
    }
}
```

- [ ] **Step 3: Run the full test and verify first-party rows are missing**

Run:

```powershell
zig build test-full
```

Expected: FAIL because `LibraryEntry.first_party_tool` and toggle support do not exist.

- [ ] **Step 4: Add first-party row type to Skill Center model**

In `src/skill_center.zig`, import the catalog if needed by tests:

```zig
const first_party_tools = @import("first_party_tools.zig");
```

Add this type after `ToolSkill`:

```zig
pub const FirstPartyToolSkill = struct {
    name: []u8,
    description: []u8,
    enabled: bool,
    disableable: bool = true,

    pub fn clone(self: FirstPartyToolSkill, allocator: std.mem.Allocator) !FirstPartyToolSkill {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, self.description);
        return .{
            .name = name,
            .description = description,
            .enabled = self.enabled,
            .disableable = self.disableable,
        };
    }

    pub fn deinit(self: *FirstPartyToolSkill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        self.* = undefined;
    }
};
```

Extend `LibraryEntry`:

```zig
    first_party_tool: FirstPartyToolSkill,
```

Update `LibraryEntry.deinit`, `LibraryEntry.clone`, and `LibraryEntry.name` with `.first_party_tool` branches:

```zig
            .first_party_tool => |*t| t.deinit(allocator),
```

```zig
            .first_party_tool => |t| .{ .first_party_tool = try t.clone(allocator) },
```

```zig
            .first_party_tool => |t| t.name,
```

- [ ] **Step 5: Merge first-party definitions into Skill Center scan results**

In `src/AppWindow.zig`, add:

```zig
const first_party_tools = @import("first_party_tools.zig");
```

In `SkillLibraryScanJob.run`, after scanning imported tools, load definitions and disabled state:

```zig
        const first_party_defs = try first_party_tools.activeDefinitions(allocator);
        defer first_party_tools.freeDefinitions(allocator, first_party_defs);
        var disabled_first_party = try first_party_tools.loadDisabledTools(allocator);
        defer disabled_first_party.deinit(allocator);
```

Change the entry allocation count:

```zig
        const entries = try allocator.alloc(skill_center.LibraryEntry, prompt_entries.len + tools.len + first_party_defs.len);
```

After appending imported tools, append first-party rows:

```zig
        for (first_party_defs) |definition| {
            entries[filled] = try skillCenterEntryFromFirstPartyTool(allocator, definition, disabled_first_party);
            filled += 1;
        }
```

Add this helper near `skillCenterEntryFromInstalledTool`:

```zig
fn skillCenterEntryFromFirstPartyTool(
    allocator: std.mem.Allocator,
    definition: first_party_tools.Definition,
    disabled: first_party_tools.DisabledTools,
) !skill_center.LibraryEntry {
    const name = try allocator.dupe(u8, definition.name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, definition.description);
    return .{ .first_party_tool = .{
        .name = name,
        .description = description,
        .enabled = !disabled.contains(definition.name),
        .disableable = definition.disableable,
    } };
}
```

Update `scEntryItemAt`:

```zig
        .first_party_tool => |t| .{
            .label = t.name,
            .marker = "",
            .kind = "built-in",
            .enabled = if (t.enabled) "on" else "off",
            .marker_color = if (t.enabled) .{ 0.3, 0.85, 0.45 } else .{ 0.85, 0.45, 0.35 },
        },
```

- [ ] **Step 6: Implement first-party toggling**

Add this helper near `skillCenterApplyToolEnabledByManifestPath`:

```zig
fn skillCenterApplyFirstPartyEnabledByName(
    entries: []skill_center.LibraryEntry,
    name: []const u8,
    enabled: bool,
) bool {
    for (entries) |*entry| {
        switch (entry.*) {
            .first_party_tool => |*tool| {
                if (std.mem.eql(u8, tool.name, name)) {
                    tool.enabled = enabled;
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}
```

In `skillCenterToggleToolEnabled`, add state for first-party name before the lock block:

```zig
    var first_party_name: ?[]u8 = null;
```

Inside the selected-entry switch, add:

```zig
            .first_party_tool => |tool| {
                if (!tool.disableable) return false;
                first_party_name = allocator.dupe(u8, tool.name) catch return false;
            },
```

After the lock block and before imported manifest handling, add:

```zig
    if (first_party_name) |name| {
        defer allocator.free(name);
        var current = first_party_tools.loadDisabledTools(allocator) catch first_party_tools.DisabledTools.empty();
        defer current.deinit(allocator);
        const new_enabled = current.contains(name);
        var next = first_party_tools.toggledDisabledTools(allocator, current, name) catch {
            session.mutex.lock();
            skillCenterSetStatusLocked(session, i18n.s().sc_tool_toggle_failed);
            session.mutex.unlock();
            markUiDirty();
            return true;
        };
        defer next.deinit(allocator);
        first_party_tools.writeDisabledTools(allocator, next) catch {
            session.mutex.lock();
            skillCenterSetStatusLocked(session, i18n.s().sc_tool_toggle_failed);
            session.mutex.unlock();
            markUiDirty();
            return true;
        };

        ai_chat.reloadFirstPartyToolState(allocator);
        session.mutex.lock();
        if (session.model.entries) |entries| {
            _ = skillCenterApplyFirstPartyEnabledByName(entries, name, new_enabled);
        }
        skillCenterSetStatusLocked(session, if (new_enabled) i18n.s().sc_tool_enabled else i18n.s().sc_tool_disabled);
        session.mutex.unlock();
        markUiDirty();
        return true;
    }
```

In `skillCenterToolManifestPath` and imported-tool-only helpers, leave `.first_party_tool` out of path logic so first-party rows cannot accidentally use fake manifests.

- [ ] **Step 7: Update input test expectation and legend strings**

In `src/i18n.zig`, change English:

```zig
    .sc_legend_v2 = "[space] preview   [↵] deploy   [i] import   [t] import tool   [e] toggle   [g] get   [r] rescan",
```

Change Chinese:

```zig
    .sc_legend_v2 = "[space] 预览   [↵] 部署   [i] 导入   [t] 导入工具   [e] 开关   [g] 获取   [r] 重新扫描",
```

No `README.md` keyboard shortcut update is needed because the binding remains `E`; only the action label changes from enable to toggle.

- [ ] **Step 8: Run the full test and commit**

Run:

```powershell
zig build test-full
```

Expected: PASS.

Commit:

```bash
git add src/skill_center.zig src/AppWindow.zig src/input.zig src/i18n.zig
git commit -m "feat: manage first-party tools in skill center"
```

---

### Task 6: Documentation Updates

**Files:**
- Modify: `docs/ai-agent.md`
- Modify: `docs/ai.html`
- Modify: `docs/faq.md`

- [ ] **Step 1: Update markdown docs**

In `docs/ai-agent.md`, update the Skill Center paragraph to include first-party tools:

```markdown
Open **Skill Center** to inspect prompt skills, imported executable tools, and
first-party WispTerm Agent tools. Imported executable tools and first-party tools
can be toggled on or off. Off tools stay installed and visible, but WispTerm
does not advertise them to new Agent requests and rejects stale calls before
running them.
```

In `docs/faq.md`, update the Skill Center entry to include the same behavior:

```markdown
Skill Center also manages Agent tools. Imported executable tools and first-party
WispTerm tools appear in the same inventory; press `E` to toggle supported tools
on or off. Disabled tools remain visible but are hidden from new AI requests and
blocked at runtime if an old conversation tries to call them.
```

- [ ] **Step 2: Update website copy**

In `docs/ai.html`, replace the Skill Center tool paragraph with:

```html
            <p>Skill Center also manages Agent tools. Imported executable tools are stored under the WispTerm config directory with a canonical <code>SKILL.md</code>, while first-party WispTerm tools such as <code>webread</code> and <code>websearch</code> appear in the same inventory. Enabled tools are advertised to AI Agent sessions; disabled tools remain visible but are hidden from new requests and blocked if a stale tool call arrives.</p>
```

- [ ] **Step 3: Run docs-neutral tests and commit**

Run:

```powershell
zig build test
```

Expected: PASS.

Commit:

```bash
git add docs/ai-agent.md docs/ai.html docs/faq.md
git commit -m "docs: explain first-party agent tool toggles"
```

---

### Task 7: Final Verification And Windows Path Safety

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run fast tests**

Run:

```powershell
zig build test
```

Expected: PASS.

- [ ] **Step 2: Run full tests**

Run:

```powershell
zig build test-full
```

Expected: PASS.

- [ ] **Step 3: Run Windows checkout safety checks**

In PowerShell from the repository root, run:

```powershell
$paths = git ls-files
$reserved = @('CON', 'PRN', 'AUX', 'NUL') + (1..9 | ForEach-Object { "COM$_"; "LPT$_" })
$violations = [System.Collections.Generic.List[object]]::new()
$collisions = [System.Collections.Generic.List[object]]::new()
$seen = @{}

foreach ($path in $paths) {
    foreach ($part in ($path -split '/')) {
        $stem = ($part -split '\.')[0].ToUpperInvariant()
        $reasons = @()
        if ($part.IndexOfAny([char[]]'<>:"\|?*') -ge 0) { $reasons += 'illegal_char' }
        if ($part.EndsWith(' ') -or $part.EndsWith('.')) { $reasons += 'trailing_space_or_dot' }
        if ($reserved -contains $stem) { $reasons += 'reserved_name' }
        if ($reasons.Count -gt 0) {
            $violations.Add([pscustomobject]@{ Path = $path; Part = $part; Reasons = ($reasons -join ',') })
        }
    }

    $key = $path.ToLowerInvariant()
    if ($seen.ContainsKey($key) -and $seen[$key] -ne $path) {
        $collisions.Add([pscustomobject]@{ A = $seen[$key]; B = $path })
    } else {
        $seen[$key] = $path
    }
}

"tracked_files=$($paths.Count)"
"windows_name_violations=$($violations.Count)"
$violations | ForEach-Object { "violation`t$($_.Path)`t$($_.Part)`t$($_.Reasons)" }
"casefold_collisions=$($collisions.Count)"
$collisions | ForEach-Object { "collision`t$($_.A)`t$($_.B)" }
$longest = $paths | Sort-Object Length -Descending | Select-Object -First 1
"max_path_length=$($longest.Length) $longest"
```

Expected output includes:

```text
windows_name_violations=0
casefold_collisions=0
```

Then run:

```powershell
git ls-files -s | Select-String '^120000'
```

Expected: no output.

- [ ] **Step 4: Inspect final diff**

Run:

```bash
git status --short
git log --oneline -5
```

Expected: only intentional commits are present; no untracked implementation files remain.
